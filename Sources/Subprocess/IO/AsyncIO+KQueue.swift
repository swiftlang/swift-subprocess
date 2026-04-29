//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

/// AsyncIO implementation based on kqueue

#if SUBPROCESS_ASYNCIO_KQUEUE

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(os)
import os
#endif

import _SubprocessCShims
import Synchronization

#if canImport(Darwin)
private typealias _Mutex = OSAllocatedUnfairLock
#else
private typealias _Mutex = Synchronization.Mutex
#endif

// The kevent() C function and the kevent struct share the same name.
// Swift can disambiguate when given an explicit function type.
private let _kevent:
    @convention(c) (
        Int32,
        UnsafePointer<kevent>?,
        Int32,
        UnsafeMutablePointer<kevent>?,
        Int32,
        UnsafePointer<timespec>?
    ) -> Int32 = kevent

private let _kqueueEventSize = 256
private let _registration:
    _Mutex<
        [PlatformFileDescriptor: SignalStream.Continuation]
    > = _Mutex([:])

private func _makeKevent(
    ident: UInt,
    filter: Int16,
    flags: UInt16
) -> kevent {
    #if canImport(Darwin)
    return kevent(
        ident: ident,
        filter: filter,
        flags: flags,
        fflags: 0,
        data: 0,
        udata: nil
    )
    #else
    return kevent(
        ident: ident,
        filter: filter,
        flags: flags,
        fflags: 0,
        data: 0,
        udata: nil,
        ext: (0, 0, 0, 0)
    )
    #endif
}

final class AsyncIO: Sendable {

    typealias OutputStream = AsyncThrowingStream<AsyncBufferSequence.Buffer, any Error>

    private struct MonitorThreadContext: Sendable {
        let kqueueFileDescriptor: CInt
        let shutdownReadFileDescriptor: CInt
    }

    private struct State: Sendable {
        let kqueueFileDescriptor: CInt
        let shutdownReadFileDescriptor: CInt
        let shutdownWriteFileDescriptor: CInt
        nonisolated(unsafe) let monitorThread: pthread_t
    }

    static let shared: AsyncIO = AsyncIO()

    private let state: Result<State, SubprocessError>
    #if canImport(Darwin)
    private let shutdownFlag: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: false)
    #else
    private let shutdownFlag: Atomic<UInt8> = Atomic(0)
    #endif

    internal init() {
        #if os(FreeBSD) || os(OpenBSD)
        let kqueueFileDescriptor = kqueue1(O_CLOEXEC)
        #else
        let kqueueFileDescriptor = kqueue()
        #endif
        guard kqueueFileDescriptor >= 0 else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "kqueue failed",
                underlyingError: Errno(rawValue: errno)
            )
            self.state = .failure(error)
            return
        }
        let shutdownPipe: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
        do {
            shutdownPipe = try FileDescriptor.pipe()
        } catch {
            let error: SubprocessError = .asyncIOFailed(
                reason: "pipe failed for shutdown signaling",
                underlyingError: error as? Errno
            )
            self.state = .failure(error)
            return
        }
        let shutdownReadFd = shutdownPipe.readEnd.rawValue
        let shutdownWriteFd = shutdownPipe.writeEnd.rawValue

        var shutdownEvent = _makeKevent(
            ident: UInt(shutdownReadFd),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE)
        )
        let rc = _kevent(
            kqueueFileDescriptor,
            &shutdownEvent,
            1,
            nil,
            0,
            nil
        )
        guard rc == 0 else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "failed to add shutdown fd to kqueue",
                underlyingError: Errno(rawValue: errno)
            )
            self.state = .failure(error)
            return
        }

        let context = MonitorThreadContext(
            kqueueFileDescriptor: kqueueFileDescriptor,
            shutdownReadFileDescriptor: shutdownReadFd
        )
        let thread: pthread_t
        do throws(Errno) {
            thread = try pthread_create {
                func reportError(_ error: SubprocessError) {
                    _registration.withLock { store in
                        for continuation in store.values {
                            continuation.finish(throwing: error)
                        }
                    }
                }

                var events: [kevent] = Array(
                    repeating: _makeKevent(ident: 0, filter: 0, flags: 0),
                    count: _kqueueEventSize
                )

                monitorLoop: while true {
                    let eventCount = _kevent(
                        context.kqueueFileDescriptor,
                        nil,
                        0,
                        &events,
                        Int32(events.count),
                        nil
                    )
                    if eventCount < 0 {
                        if errno == EINTR || errno == EAGAIN {
                            continue
                        }
                        let error: SubprocessError = .asyncIOFailed(
                            reason: "kevent wait failed",
                            underlyingError: Errno(rawValue: errno)
                        )
                        reportError(error)
                        break monitorLoop
                    }

                    for index in 0..<Int(eventCount) {
                        let event = events[index]
                        let targetFileDescriptor = Int32(event.ident)
                        if targetFileDescriptor == context.shutdownReadFileDescriptor {
                            var buf: UInt8 = 0
                            withUnsafeMutableBytes(of: &buf) { ptr in
                                _ = try? FileDescriptor(
                                    rawValue: context.shutdownReadFileDescriptor
                                ).read(into: ptr, retryOnInterrupt: true)
                            }
                            break monitorLoop
                        }

                        let continuation = _registration.withLock { store -> SignalStream.Continuation? in
                            if let continuation = store[targetFileDescriptor] {
                                return continuation
                            }
                            return nil
                        }
                        continuation?.yield(true)
                    }
                }
            }
        } catch let errno {
            let error: SubprocessError = .asyncIOFailed(
                reason: "Failed to create monitor thread",
                underlyingError: errno
            )
            self.state = .failure(error)
            return
        }

        let state = State(
            kqueueFileDescriptor: kqueueFileDescriptor,
            shutdownReadFileDescriptor: shutdownReadFd,
            shutdownWriteFileDescriptor: shutdownWriteFd,
            monitorThread: thread
        )
        self.state = .success(state)

        atexit {
            AsyncIO.shared.shutdown()
        }
    }

    internal func shutdown() {
        guard case .success(let currentState) = self.state else {
            return
        }

        #if canImport(Darwin)
        let alreadyShutdown = self.shutdownFlag.withLock { flag -> Bool in
            if flag { return true }
            flag = true
            return false
        }
        guard !alreadyShutdown else { return }
        #else
        guard self.shutdownFlag.add(1, ordering: .sequentiallyConsistent).newValue == 1 else {
            return
        }
        #endif
        var one: UInt8 = 1
        let kqueueFd = FileDescriptor(rawValue: currentState.kqueueFileDescriptor)
        let shutdownWriteFd = FileDescriptor(rawValue: currentState.shutdownWriteFileDescriptor)
        let shutdownReadFd = FileDescriptor(rawValue: currentState.shutdownReadFileDescriptor)
        withUnsafeBytes(of: &one) { ptr in
            _ = try? shutdownWriteFd.write(ptr)
        }

        pthread_join(currentState.monitorThread, nil)
        var closeError: Errno? = nil
        do {
            try kqueueFd.close()
        } catch {
            closeError = error as? Errno
        }
        do {
            try shutdownReadFd.close()
        } catch {
            closeError = error as? Errno
        }
        do {
            try shutdownWriteFd.close()
        } catch {
            closeError = error as? Errno
        }

        if let closeError {
            fatalError("Failed to close kqueue fds: \(closeError)")
        }
    }

    internal func registerFileDescriptor(
        _ fileDescriptor: FileDescriptor,
        for event: Event
    ) -> SignalStream {
        return SignalStream { (continuation: SignalStream.Continuation) -> () in
            switch self.state {
            case .success(let state):
                if let nonBlockingFdError = self.setNonblocking(for: fileDescriptor) {
                    continuation.finish(throwing: nonBlockingFdError)
                    return
                }
                let filter: Int16
                switch event {
                case .read:
                    filter = Int16(EVFILT_READ)
                case .write:
                    filter = Int16(EVFILT_WRITE)
                }

                _registration.withLock { storage in
                    storage[fileDescriptor.rawValue] = continuation
                }

                var kev = _makeKevent(
                    ident: UInt(fileDescriptor.rawValue),
                    filter: filter,
                    flags: UInt16(EV_ADD | EV_ENABLE)
                )
                let rc = _kevent(
                    state.kqueueFileDescriptor,
                    &kev,
                    1,
                    nil,
                    0,
                    nil
                )
                if rc != 0 {
                    _registration.withLock { storage in
                        _ = storage.removeValue(forKey: fileDescriptor.rawValue)
                    }
                    let capturedError = errno
                    let error: SubprocessError = .asyncIOFailed(
                        reason: "failed to add \(fileDescriptor.rawValue) to kqueue",
                        underlyingError: Errno(rawValue: capturedError)
                    )
                    continuation.finish(throwing: error)
                    return
                }
            case .failure(let setupError):
                continuation.finish(throwing: setupError)
                return
            }
        }
    }

    internal func removeRegistration(for fileDescriptor: FileDescriptor) throws(SubprocessError) {
        switch self.state {
        case .success(let state):
            let registration = _registration.withLock { store in
                return store.removeValue(forKey: fileDescriptor.rawValue)
            }
            guard let registration else {
                return
            }
            registration.finish()
            var kev = _makeKevent(
                ident: UInt(fileDescriptor.rawValue),
                filter: Int16(EVFILT_READ),
                flags: UInt16(EV_DELETE)
            )
            _ = _kevent(
                state.kqueueFileDescriptor,
                &kev,
                1,
                nil,
                0,
                nil
            )
            kev.filter = Int16(EVFILT_WRITE)
            _ = _kevent(
                state.kqueueFileDescriptor,
                &kev,
                1,
                nil,
                0,
                nil
            )
        case .failure(let setupFailure):
            throw setupFailure
        }
    }
}

#if canImport(Darwin)
extension OSAllocatedUnfairLock where State: Sendable {
    fileprivate init(_ initialValue: State) {
        self.init(initialState: initialValue)
    }
}
#endif

#endif // SUBPROCESS_ASYNCIO_KQUEUE
