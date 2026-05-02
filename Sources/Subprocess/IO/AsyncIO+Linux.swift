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

/// Linux AsyncIO implementation based on epoll

#if os(Linux) || os(Android)

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
import posix_filesystem.sys_epoll
#elseif canImport(Musl)
import Musl
#endif

import _SubprocessCShims
import Synchronization

private let _epollEventSize = 256
private let _registration:
    Mutex<
        [PlatformFileDescriptor: SignalStream.Continuation]
    > = Mutex([:])

final class AsyncIO: Sendable {

    typealias OutputStream = AsyncThrowingStream<AsyncBufferSequence.Buffer, any Error>

    private struct MonitorThreadContext: Sendable {
        let epollFileDescriptor: CInt
        let shutdownFileDescriptor: CInt

        init(
            epollFileDescriptor: CInt,
            shutdownFileDescriptor: CInt
        ) {
            self.epollFileDescriptor = epollFileDescriptor
            self.shutdownFileDescriptor = shutdownFileDescriptor
        }
    }

    private struct State {
        let epollFileDescriptor: CInt
        let shutdownFileDescriptor: CInt
        let monitorThread: pthread_t
    }

    static let shared: AsyncIO = AsyncIO()

    private let state: Result<State, SubprocessError>
    private let shutdownFlag: Atomic<UInt8> = Atomic(0)

    internal init() {
        // Create main epoll fd
        let epollFileDescriptor = epoll_create1(CInt(EPOLL_CLOEXEC))
        guard epollFileDescriptor >= 0 else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "epoll_create1 failed",
                underlyingError: Errno(rawValue: errno)
            )
            self.state = .failure(error)
            return
        }
        // Create shutdownFileDescriptor
        let shutdownFileDescriptor = eventfd(0, CInt(EFD_NONBLOCK | EFD_CLOEXEC))
        guard shutdownFileDescriptor >= 0 else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "eventfd failed",
                underlyingError: Errno(rawValue: errno)
            )
            self.state = .failure(error)
            return
        }

        // Register shutdownFileDescriptor with epoll
        var event = epoll_event(
            events: EPOLLIN.rawValue,
            data: epoll_data(fd: shutdownFileDescriptor)
        )
        let rc = epoll_ctl(
            epollFileDescriptor,
            EPOLL_CTL_ADD,
            shutdownFileDescriptor,
            &event
        )
        guard rc == 0 else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "failed to add shutdown fd \(shutdownFileDescriptor) to epoll list",
                underlyingError: Errno(rawValue: errno)
            )
            self.state = .failure(error)
            return
        }

        // Create thread data
        let context = MonitorThreadContext(
            epollFileDescriptor: epollFileDescriptor,
            shutdownFileDescriptor: shutdownFileDescriptor
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

                var events: [epoll_event] = Array(
                    repeating: epoll_event(events: 0, data: epoll_data(fd: 0)),
                    count: _epollEventSize
                )

                // Enter the monitor loop
                monitorLoop: while true {
                    let eventCount = epoll_wait(
                        context.epollFileDescriptor,
                        &events,
                        CInt(events.count),
                        -1
                    )
                    if eventCount < 0 {
                        if errno == EINTR || errno == EAGAIN {
                            continue // interrupted by signal; try again
                        }
                        // Report other errors
                        let error: SubprocessError = .asyncIOFailed(
                            reason: "epoll_wait failed",
                            underlyingError: Errno(rawValue: errno)
                        )
                        reportError(error)
                        break monitorLoop
                    }

                    for index in 0..<Int(eventCount) {
                        let event = events[index]
                        let targetFileDescriptor = event.data.fd
                        // Breakout the monitor loop if we received shutdown
                        // from the shutdownFD
                        if targetFileDescriptor == context.shutdownFileDescriptor {
                            var buf: UInt64 = 0
                            _ = _subprocess_read(context.shutdownFileDescriptor, &buf, MemoryLayout<UInt64>.size)
                            break monitorLoop
                        }

                        // Notify the continuation
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
            epollFileDescriptor: epollFileDescriptor,
            shutdownFileDescriptor: shutdownFileDescriptor,
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

        guard self.shutdownFlag.add(1, ordering: .sequentiallyConsistent).newValue == 1 else {
            // We already closed this AsyncIO
            return
        }
        var one: UInt64 = 1
        // Wake up the thread for shutdown
        _ = _subprocess_write(currentState.shutdownFileDescriptor, &one, MemoryLayout<UInt64>.stride)
        // Cleanup the monitor thread
        pthread_join(currentState.monitorThread, nil)
        var closeError: CInt = 0
        if _subprocess_close(currentState.epollFileDescriptor) != 0 {
            closeError = errno
        }
        if _subprocess_close(currentState.shutdownFileDescriptor) != 0 {
            closeError = errno
        }
        if closeError != 0 {
            fatalError("Failed to close epollfd: \(String(cString: strerror(closeError)))")
        }
    }

    internal func registerFileDescriptor(
        _ fileDescriptor: FileDescriptor,
        for event: Event
    ) -> SignalStream {
        return SignalStream { (continuation: SignalStream.Continuation) -> () in
            // If setup failed, nothing much we can do
            switch self.state {
            case .success(let state):
                // Set file descriptor to be non blocking
                if let nonBlockingFdError = self.setNonblocking(for: fileDescriptor) {
                    continuation.finish(throwing: nonBlockingFdError)
                    return
                }
                // Register event
                let targetEvent: EPOLL_EVENTS
                switch event {
                case .read:
                    targetEvent = EPOLL_EVENTS(EPOLLIN)
                case .write:
                    targetEvent = EPOLL_EVENTS(EPOLLOUT)
                }

                // Save the continuation (before calling epoll_ctl, so we don't miss any data)
                _registration.withLock { storage in
                    storage[fileDescriptor.rawValue] = continuation
                }

                var event = epoll_event(
                    events: targetEvent.rawValue,
                    data: epoll_data(fd: fileDescriptor.rawValue)
                )
                let rc = epoll_ctl(
                    state.epollFileDescriptor,
                    EPOLL_CTL_ADD,
                    fileDescriptor.rawValue,
                    &event
                )
                if rc != 0 {
                    _registration.withLock { storage in
                        _ = storage.removeValue(forKey: fileDescriptor.rawValue)
                    }

                    let capturedError = errno
                    let error: SubprocessError = .asyncIOFailed(
                        reason: "failed to add \(fileDescriptor.rawValue) to epoll list",
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
            let rc = epoll_ctl(
                state.epollFileDescriptor,
                EPOLL_CTL_DEL,
                fileDescriptor.rawValue,
                nil
            )
            guard rc == 0 else {
                throw SubprocessError.asyncIOFailed(
                    reason: "failed to remove \(fileDescriptor.rawValue) from epoll list",
                    underlyingError: Errno(rawValue: errno)
                )
            }
        case .failure(let setupFailure):
            throw setupFailure
        }
    }
}

#endif // canImport(Glibc) || canImport(Android) || canImport(Musl)
