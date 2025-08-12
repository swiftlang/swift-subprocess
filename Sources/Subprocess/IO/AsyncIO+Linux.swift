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

#if canImport(Glibc) || canImport(Android) || canImport(Musl)

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
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

private typealias SignalStream = AsyncThrowingStream<Bool, any Error>
private let _epollEventSize = 256
private let _registration: Mutex<
    [PlatformFileDescriptor : SignalStream.Continuation]
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

    private enum Event {
        case read
        case write
    }

    private struct State {
        let epollFileDescriptor: CInt
        let shutdownFileDescriptor: CInt
        let monitorThread: pthread_t
    }

    static let shared: AsyncIO = AsyncIO()

    private let state: Result<State, SubprocessError>

    private init() {
        // Create main epoll fd
        let epollFileDescriptor = epoll_create1(CInt(EPOLL_CLOEXEC))
        guard epollFileDescriptor >= 0 else {
            let error = SubprocessError(
                code: .init(.asyncIOFailed("epoll_create1 failed")),
                underlyingError: .init(rawValue: errno)
            )
            self.state = .failure(error)
            return
        }
        // Create shutdownFileDescriptor
        let shutdownFileDescriptor = eventfd(0, CInt(EFD_NONBLOCK | EFD_CLOEXEC))
        guard shutdownFileDescriptor >= 0 else {
            let error = SubprocessError(
                code: .init(.asyncIOFailed("eventfd failed")),
                underlyingError: .init(rawValue: errno)
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
            let error = SubprocessError(
                code: .init(.asyncIOFailed(
                    "failed to add shutdown fd \(shutdownFileDescriptor) to epoll list")
                ),
                underlyingError: .init(rawValue: errno)
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
        do {
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
                        let error = SubprocessError(
                            code: .init(.asyncIOFailed(
                                "epoll_wait failed")
                            ),
                            underlyingError: .init(rawValue: errno)
                        )
                        reportError(error)
                        break monitorLoop
                    }

                    for index in 0 ..< Int(eventCount) {
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
        } catch let underlyingError {
            let error = SubprocessError(
                code: .init(.asyncIOFailed("Failed to create monitor thread")),
                underlyingError: underlyingError
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

    private func shutdown() {
        guard case .success(let currentState) = self.state else {
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


    private func registerFileDescriptor(
        _ fileDescriptor: FileDescriptor,
        for event: Event
    ) -> SignalStream {
        return SignalStream { (continuation: SignalStream.Continuation) -> () in
            // If setup failed, nothing much we can do
            switch self.state {
            case .success(let state):
                // Set file descriptor to be non blocking
                let flags = fcntl(fileDescriptor.rawValue, F_GETFD)
                guard flags != -1 else {
                    let error = SubprocessError(
                        code: .init(.asyncIOFailed(
                            "failed to get flags for \(fileDescriptor.rawValue)")
                        ),
                        underlyingError: .init(rawValue: errno)
                    )
                    continuation.finish(throwing: error)
                    return
                }
                guard fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK) != -1 else {
                    let error = SubprocessError(
                        code: .init(.asyncIOFailed(
                            "failed to set \(fileDescriptor.rawValue) to be non-blocking")
                        ),
                        underlyingError: .init(rawValue: errno)
                    )
                    continuation.finish(throwing: error)
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
                    let error = SubprocessError(
                        code: .init(.asyncIOFailed(
                            "failed to add \(fileDescriptor.rawValue) to epoll list")
                        ),
                        underlyingError: .init(rawValue: errno)
                    )
                    continuation.finish(throwing: error)
                    return
                }
                // Now save the continuation
                _registration.withLock { storage in
                    storage[fileDescriptor.rawValue] = continuation
                }
            case .failure(let setupError):
                continuation.finish(throwing: setupError)
                return
            }
        }
    }

    private func removeRegistration(for fileDescriptor: FileDescriptor) throws {
        switch self.state {
        case .success(let state):
            let rc = epoll_ctl(
                state.epollFileDescriptor,
                EPOLL_CTL_DEL,
                fileDescriptor.rawValue,
                nil
            )
            guard rc == 0 else {
                throw SubprocessError(
                    code: .init(.asyncIOFailed(
                        "failed to remove \(fileDescriptor.rawValue) to epoll list")
                    ),
                    underlyingError: .init(rawValue: errno)
                )
            }
            _registration.withLock { store in
                _ = store.removeValue(forKey: fileDescriptor.rawValue)
            }
        case .failure(let setupFailure):
            throw setupFailure
        }
    }
}

extension AsyncIO {

    protocol _ContiguousBytes {
        var count: Int { get }

        func withUnsafeBytes<ResultType>(
            _ body: (UnsafeRawBufferPointer) throws -> ResultType
        ) rethrows -> ResultType
    }

    func read(
        from diskIO: borrowing IOChannel,
        upTo maxLength: Int
    ) async throws -> [UInt8]? {
        return try await self.read(from: diskIO.channel, upTo: maxLength)
    }

    func read(
        from fileDescriptor: FileDescriptor,
        upTo maxLength: Int
    ) async throws -> [UInt8]? {
        // If we are reading until EOF, start with readBufferSize
        // and gradually increase buffer size
        let bufferLength = maxLength == .max ? readBufferSize : maxLength

        var resultBuffer: [UInt8] = Array(
            repeating: 0, count: bufferLength
        )
        var readLength: Int = 0
        let signalStream = self.registerFileDescriptor(fileDescriptor, for: .read)
        /// Outer loop: every iteration signals we are ready to read more data
        for try await _ in signalStream {
            /// Inner loop: repeatedly call `.read()` and read more data until:
            /// 1. We reached EOF (read length is 0), in which case return the result
            /// 2. We read `maxLength` bytes, in which case return the result
            /// 3. `read()` returns -1 and sets `errno` to `EAGAIN` or `EWOULDBLOCK`. In
            ///     this case we `break` out of the inner loop and wait `.read()` to be
            ///     ready by `await`ing the next signal in the outer loop.
            while true {
                let bytesRead = resultBuffer.withUnsafeMutableBufferPointer { bufferPointer in
                    // Get a pointer to the memory at the specified offset
                    let targetCount = bufferPointer.count - readLength

                    let offsetAddress = bufferPointer.baseAddress!.advanced(by: readLength)

                    // Read directly into the buffer at the offset
                    return _subprocess_read(fileDescriptor.rawValue, offsetAddress, targetCount)
                }
                if bytesRead > 0 {
                    // Read some data
                    readLength += bytesRead
                    if maxLength == .max {
                        // Grow resultBuffer if needed
                        guard Double(readLength) > 0.8 * Double(resultBuffer.count) else {
                            continue
                        }
                        resultBuffer.append(
                            contentsOf: Array(repeating: 0, count: resultBuffer.count)
                        )
                    } else if readLength >= maxLength {
                        // When we reached maxLength, return!
                        try self.removeRegistration(for: fileDescriptor)
                        return resultBuffer
                    }
                } else if bytesRead == 0 {
                    // We reached EOF. Return whatever's left
                    try self.removeRegistration(for: fileDescriptor)
                    guard readLength > 0 else {
                        return nil
                    }
                    resultBuffer.removeLast(resultBuffer.count - readLength)
                    return resultBuffer
                } else {
                    if self.shouldWaitForNextSignal(with: errno) {
                        // No more data for now wait for the next signal
                        break
                    } else {
                        // Throw all other errors
                        try self.removeRegistration(for: fileDescriptor)
                        throw SubprocessError.UnderlyingError(rawValue: errno)
                    }
                }
            }
        }
        return resultBuffer
    }

    func write(
        _ array: [UInt8],
        to diskIO: borrowing IOChannel
    ) async throws -> Int {
        return try await self._write(array, to: diskIO)
    }

    func _write<Bytes: _ContiguousBytes>(
        _ bytes: Bytes,
        to diskIO: borrowing IOChannel
    ) async throws -> Int {
        let fileDescriptor = diskIO.channel
        let signalStream = self.registerFileDescriptor(fileDescriptor, for: .write)
        var writtenLength: Int = 0
        /// Outer loop: every iteration signals we are ready to read more data
        for try await _ in signalStream {
            /// Inner loop: repeatedly call `.write()` and write more data until:
            /// 1. We've written bytes.count bytes.
            /// 3. `.write()` returns -1 and sets `errno` to `EAGAIN` or `EWOULDBLOCK`. In
            ///     this case we `break` out of the inner loop and wait `.write()` to be
            ///     ready by `await`ing the next signal in the outer loop.
            while true {
                let written = bytes.withUnsafeBytes { ptr in
                    let remainingLength = ptr.count - writtenLength
                    let startPtr = ptr.baseAddress!.advanced(by: writtenLength)
                    return _subprocess_write(fileDescriptor.rawValue, startPtr, remainingLength)
                }
                if written > 0 {
                    writtenLength += written
                    if writtenLength >= bytes.count {
                        // Wrote all data
                        try self.removeRegistration(for: fileDescriptor)
                        return writtenLength
                    }
                } else {
                    if self.shouldWaitForNextSignal(with: errno) {
                        // No more data for now wait for the next signal
                        break
                    } else {
                        // Throw all other errors
                        try self.removeRegistration(for: fileDescriptor)
                        throw SubprocessError.UnderlyingError(rawValue: errno)
                    }
                }
            }
        }
        return 0
    }

#if SubprocessSpan
    func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing IOChannel
    ) async throws -> Int {
        let fileDescriptor = diskIO.channel
        let signalStream = self.registerFileDescriptor(fileDescriptor, for: .write)
        var writtenLength: Int = 0
        /// Outer loop: every iteration signals we are ready to read more data
        for try await _ in signalStream {
            /// Inner loop: repeatedly call `.write()` and write more data until:
            /// 1. We've written bytes.count bytes.
            /// 3. `.write()` returns -1 and sets `errno` to `EAGAIN` or `EWOULDBLOCK`. In
            ///     this case we `break` out of the inner loop and wait `.write()` to be
            ///     ready by `await`ing the next signal in the outer loop.
            while true {
                let written = span.withUnsafeBytes { ptr in
                    let remainingLength = ptr.count - writtenLength
                    let startPtr = ptr.baseAddress!.advanced(by: writtenLength)
                    return _subprocess_write(fileDescriptor.rawValue, startPtr, remainingLength)
                }
                if written > 0 {
                    writtenLength += written
                    if writtenLength >= span.byteCount {
                        // Wrote all data
                        try self.removeRegistration(for: fileDescriptor)
                        return writtenLength
                    }
                } else {
                    if self.shouldWaitForNextSignal(with: errno) {
                        // No more data for now wait for the next signal
                        break
                    } else {
                        // Throw all other errors
                        try self.removeRegistration(for: fileDescriptor)
                        throw SubprocessError.UnderlyingError(rawValue: errno)
                    }
                }
            }
        }
        return 0
    }
#endif

    @inline(__always)
    private func shouldWaitForNextSignal(with error: CInt) -> Bool {
        return error == EAGAIN || error == EWOULDBLOCK || error == EINTR
    }
}

extension Array : AsyncIO._ContiguousBytes where Element == UInt8 {}

#endif // canImport(Glibc) || canImport(Android) || canImport(Musl)
