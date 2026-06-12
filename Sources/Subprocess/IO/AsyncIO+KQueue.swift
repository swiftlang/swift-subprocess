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

/// AsyncIO implementation based on kqueue.

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

private let _registration: _Mutex<Registration> = _Mutex(Registration())

final class AsyncIO: Sendable {

    typealias OutputStream = AsyncThrowingStream<SubprocessOutputSequence.Buffer, any Error>

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
                    let continuations = _registration.withLock { store in
                        return store.allContinuations()
                    }
                    for continuation in continuations {
                        continuation.finish(throwing: error)
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
                            return store.continuation(for: targetFileDescriptor)
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
        var closeError: SubprocessError? = nil
        do {
            try _safelyClose(.fileDescriptor(kqueueFd))
        } catch {
            closeError = error
        }
        do {
            try _safelyClose(.fileDescriptor(shutdownReadFd))
        } catch {
            closeError = error
        }
        do {
            try _safelyClose(.fileDescriptor(shutdownWriteFd))
        } catch {
            closeError = error
        }

        if let closeError {
            fatalError("Failed to close kqueue fds: \(closeError)")
        }
    }

    internal func registerFileDescriptor(
        _ fileDescriptor: FileDescriptor,
        processIdentifier: ProcessIdentifier,
        for event: Event
    ) -> (stream: SignalStream, outcome: RegistrationOutcome) {
        // `.bufferingNewest(1)` latches a readiness edge that fires while no
        // consumer is awaiting, so a wakeup is never dropped between a read's
        // `EAGAIN` and its `await`.
        let (stream, continuation) = SignalStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        switch self.state {
        case .failure(let setupError):
            continuation.finish(throwing: setupError)
            return (stream, .failed(setupError))
        case .success(let state):
            if let nonBlockingFdError = self.setNonblocking(for: fileDescriptor) {
                continuation.finish(throwing: nonBlockingFdError)
                return (stream, .failed(nonBlockingFdError))
            }
            let filter: Int16
            switch event {
            case .read:
                filter = Int16(EVFILT_READ)
            case .write:
                filter = Int16(EVFILT_WRITE)
            }

            // Hold the lock across the map insert and `kevent` so a
            // concurrent `cancelAsyncIO` cannot slip in between the
            // two steps and observe a half-registered descriptor.
            let outcome: RegistrationOutcome = _registration.withLock { storage in
                switch storage.register(
                    fileDescriptor: fileDescriptor.rawValue,
                    continuation: continuation,
                    processIdentifier: processIdentifier
                ) {
                case .alreadyCancelled:
                    return .alreadyCancelled
                case .updated:
                    // Already attached to kqueue by a previous read or write;
                    // reuse the existing registration and skip the syscall.
                    return .registered
                case .registered:
                    // `EV_CLEAR` makes the filter edge-triggered: an event is
                    // delivered only when new data arrives, so a persistent
                    // registration doesn't spin the monitor thread while
                    // buffered bytes sit unread between reads.
                    var kev = _makeKevent(
                        ident: UInt(fileDescriptor.rawValue),
                        filter: filter,
                        flags: UInt16(EV_ADD | EV_CLEAR)
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
                        let capturedError = errno
                        _ = storage.removeRegistration(for: fileDescriptor.rawValue)
                        let error: SubprocessError = .asyncIOFailed(
                            reason: "failed to add \(fileDescriptor.rawValue) to kqueue",
                            underlyingError: Errno(rawValue: capturedError)
                        )
                        return .failed(error)
                    }
                    return .registered
                }
            }

            switch outcome {
            case .registered:
                break
            case .alreadyCancelled:
                continuation.finish()
            case .failed(let error):
                continuation.finish(throwing: error)
            }
            return (stream, outcome)
        }
    }

    internal func removeRegistration(for fileDescriptor: FileDescriptor) {
        let continuation = _registration.withLock { store -> SignalStream.Continuation? in
            guard
                let continuation = store.removeRegistration(
                    for: fileDescriptor.rawValue
                )
            else {
                return nil
            }

            if case .success(let state) = self.state {
                for filter in [EVFILT_READ, EVFILT_WRITE] {
                    var kev = _makeKevent(
                        ident: UInt(fileDescriptor.rawValue),
                        filter: Int16(filter),
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
                }
            }
            return continuation
        }
        continuation?.finish()
    }

    internal func cancelAsyncIO(for processIdentifier: ProcessIdentifier) throws(SubprocessError) {
        switch self.state {
        case .success(let state):
            let cancelledContinuations: [SignalStream.Continuation] = _registration.withLock { storage in
                let previousRegistrations = storage.cancel(processIdentifier: processIdentifier)
                guard !previousRegistrations.isEmpty else {
                    return []
                }
                var toBeCancelled: [SignalStream.Continuation] = []
                for registration in previousRegistrations {
                    toBeCancelled.append(registration.continuation)

                    for filter in [EVFILT_READ, EVFILT_WRITE] {
                        var kev = _makeKevent(
                            ident: UInt(registration.fileDescriptor),
                            filter: Int16(filter),
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
                    }
                }

                return toBeCancelled
            }

            for c in cancelledContinuations {
                c.finish()
            }
        case .failure(let error):
            throw error
        }
    }

    internal func cleanup(processIdentifier: ProcessIdentifier) {
        _registration.withLock { storage in
            storage.remove(processIdentifier: processIdentifier)
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
