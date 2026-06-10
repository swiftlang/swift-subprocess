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

/// Linux AsyncIO implementation based on epoll.

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
private let _registration: Mutex<Registration> = Mutex(Registration())

final class AsyncIO: Sendable {

    typealias OutputStream = AsyncThrowingStream<SubprocessOutputSequence.Buffer, any Error>

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
        // Create the main epoll fd.
        let epollFileDescriptor = epoll_create1(CInt(EPOLL_CLOEXEC))
        guard epollFileDescriptor >= 0 else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "epoll_create1 failed",
                underlyingError: Errno(rawValue: errno)
            )
            self.state = .failure(error)
            return
        }
        // Create the shutdown file descriptor.
        let shutdownFileDescriptor = eventfd(0, CInt(EFD_NONBLOCK | EFD_CLOEXEC))
        guard shutdownFileDescriptor >= 0 else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "eventfd failed",
                underlyingError: Errno(rawValue: errno)
            )
            self.state = .failure(error)
            return
        }

        // Register the shutdown file descriptor with epoll.
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

        // Create the thread context.
        let context = MonitorThreadContext(
            epollFileDescriptor: epollFileDescriptor,
            shutdownFileDescriptor: shutdownFileDescriptor
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

                var events: [epoll_event] = Array(
                    repeating: epoll_event(events: 0, data: epoll_data(fd: 0)),
                    count: _epollEventSize
                )

                // Enter the monitor loop.
                monitorLoop: while true {
                    let eventCount = epoll_wait(
                        context.epollFileDescriptor,
                        &events,
                        CInt(events.count),
                        -1
                    )
                    if eventCount < 0 {
                        if errno == EINTR || errno == EAGAIN {
                            continue // Interrupted by a signal; try again.
                        }
                        // Report other errors.
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
                        // Break out of the monitor loop on a shutdown signal
                        // from `shutdownFileDescriptor`.
                        if targetFileDescriptor == context.shutdownFileDescriptor {
                            var buf: UInt64 = 0
                            withUnsafeMutableBytes(of: &buf) { ptr in
                                _ = try? FileDescriptor(
                                    rawValue: context.shutdownFileDescriptor
                                ).read(into: ptr, retryOnInterrupt: true)
                            }
                            break monitorLoop
                        }

                        // Notify the continuation.
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
            // This `AsyncIO` was already shut down.
            return
        }
        var one: UInt64 = 1
        // Wake the monitor thread so it can exit.
        let shutdownFd = FileDescriptor(rawValue: currentState.shutdownFileDescriptor)
        let epollFd = FileDescriptor(rawValue: currentState.epollFileDescriptor)
        withUnsafeBytes(of: &one) { ptr in
            _ = try? shutdownFd.write(ptr)
        }
        // Clean up the monitor thread.
        pthread_join(currentState.monitorThread, nil)

        var closeError: SubprocessError? = nil
        do {
            try _safelyClose(.fileDescriptor(epollFd))
        } catch {
            closeError = error
        }
        do {
            try _safelyClose(.fileDescriptor(shutdownFd))
        } catch {
            closeError = error
        }

        if let closeError {
            fatalError("Failed to close epollfd: \(closeError)")
        }
    }

    internal func registerFileDescriptor(
        _ fileDescriptor: FileDescriptor,
        processIdentifier: ProcessIdentifier,
        for event: Event
    ) -> SignalStream {
        return SignalStream { (continuation: SignalStream.Continuation) -> () in
            // Nothing to do if setup failed.
            switch self.state {
            case .success(let state):
                // Set the file descriptor to non-blocking.
                if let nonBlockingFdError = self.setNonblocking(for: fileDescriptor) {
                    continuation.finish(throwing: nonBlockingFdError)
                    return
                }
                // Pick the event to register.
                let targetEvent: EPOLL_EVENTS
                switch event {
                case .read:
                    targetEvent = EPOLL_EVENTS(EPOLLIN)
                case .write:
                    targetEvent = EPOLL_EVENTS(EPOLLOUT)
                }

                // Hold the lock across both the map insert and `epoll_ctl` so
                // a concurrent `cancelAsyncIO` either runs entirely before
                // (in which case `register` returns `false`) or entirely
                // after (in which case it sees the descriptor in the map
                // and in epoll). Without this, a cancellation could observe
                // the map entry between `storage.register` and
                // `epoll_ctl(EPOLL_CTL_ADD)` and try to delete a descriptor
                // that isn't yet in the epoll set.
                let outcome: RegistrationOutcome = _registration.withLock { storage in
                    guard
                        storage.register(
                            fileDescriptor: fileDescriptor.rawValue,
                            continuation: continuation,
                            processIdentifier: processIdentifier
                        )
                    else {
                        return .alreadyCancelled
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
                        let capturedError = errno
                        _ = storage.removeRegistration(for: fileDescriptor.rawValue)
                        let error: SubprocessError = .asyncIOFailed(
                            reason: "failed to add \(fileDescriptor.rawValue) to epoll list",
                            underlyingError: Errno(rawValue: capturedError)
                        )
                        return .failed(error)
                    }
                    return .registered
                }

                switch outcome {
                case .registered:
                    break
                case .alreadyCancelled:
                    continuation.finish()
                case .failed(let error):
                    continuation.finish(throwing: error)
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
            let c = try _registration.withLock { store throws(SubprocessError) -> SignalStream.Continuation? in
                guard
                    let continuation = store.removeRegistration(
                        for: fileDescriptor.rawValue
                    )
                else {
                    return nil
                }

                let rc = epoll_ctl(
                    state.epollFileDescriptor,
                    EPOLL_CTL_DEL,
                    fileDescriptor.rawValue,
                    nil
                )

                if rc != 0 {
                    throw SubprocessError.asyncIOFailed(
                        reason: "failed to remove \(fileDescriptor.rawValue) from epoll list",
                        underlyingError: Errno(rawValue: errno)
                    )
                }
                return continuation
            }
            c?.finish()
        case .failure(let error):
            throw error
        }
    }

    internal func cancelAsyncIO(for processIdentifier: ProcessIdentifier) throws(SubprocessError) {
        switch self.state {
        case .success(let state):
            let cancelledContinuations = try _registration.withLock { storage throws(SubprocessError) -> [SignalStream.Continuation] in
                let previousRegistrations = storage.cancel(processIdentifier: processIdentifier)
                guard !previousRegistrations.isEmpty else {
                    return []
                }
                var toBeCancelled: [SignalStream.Continuation] = []
                for registration in previousRegistrations {
                    toBeCancelled.append(registration.continuation)

                    let rc = epoll_ctl(
                        state.epollFileDescriptor,
                        EPOLL_CTL_DEL,
                        registration.fileDescriptor,
                        nil
                    )
                    if rc != 0 && errno != ENOENT {
                        throw SubprocessError.asyncIOFailed(
                            reason: "failed to remove \(registration.fileDescriptor) from epoll list",
                            underlyingError: Errno(rawValue: errno)
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

#endif // canImport(Glibc) || canImport(Android) || canImport(Musl)
