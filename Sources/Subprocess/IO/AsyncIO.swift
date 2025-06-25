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

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

/// Platform specific asynchronous read/write implementation

// MARK: - Linux (epoll)
#if canImport(Glibc) || canImport(Android) || canImport(Musl)

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
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

    private final class MonitorThreadContext {
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
        var rc = epoll_ctl(
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
        let threadContext = Unmanaged.passRetained(context)
        #if os(FreeBSD) || os(OpenBSD)
        var thread: pthread_t? = nil
        #else
        var thread: pthread_t = pthread_t()
        #endif
        rc = pthread_create(&thread, nil, { args in
            func reportError(_ error: SubprocessError) {
                _registration.withLock { store in
                    for continuation in store.values {
                        continuation.finish(throwing: error)
                    }
                }
            }

            let unmanaged = Unmanaged<MonitorThreadContext>.fromOpaque(args!)
            let context = unmanaged.takeRetainedValue()

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
                        _ = _SubprocessCShims.read(context.shutdownFileDescriptor, &buf, MemoryLayout<UInt64>.size)
                        break monitorLoop
                    }

                    // Notify the continuation
                    _registration.withLock { store in
                        if let continuation = store[targetFileDescriptor] {
                            continuation.yield(true)
                        }
                    }
                }
            }

            return nil
        }, threadContext.toOpaque())
        guard rc == 0 else {
            let error = SubprocessError(
                code: .init(.asyncIOFailed("Failed to create monitor thread")),
                underlyingError: .init(rawValue: rc)
            )
            self.state = .failure(error)
            return
        }

        #if os(FreeBSD) || os(OpenBSD)
        let monitorThread = thread!
        #else
        let monitorThread = thread
        #endif

        let state = State(
            epollFileDescriptor: epollFileDescriptor,
            shutdownFileDescriptor: shutdownFileDescriptor,
            monitorThread: monitorThread
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
        _ = _SubprocessCShims.write(currentState.shutdownFileDescriptor, &one, MemoryLayout<UInt64>.stride)
        // Cleanup the monitor thread
        pthread_join(currentState.monitorThread, nil)
    }


    private func registerFileDescriptor(
        _ fileDescriptor: FileDescriptor,
        for event: Event
    ) -> SignalStream {
        return SignalStream { continuation in
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
                    targetEvent = EPOLLIN
                case .write:
                    targetEvent = EPOLLOUT
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
                    return _SubprocessCShims.read(fileDescriptor.rawValue, offsetAddress, targetCount)
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
                    if errno == EAGAIN || errno == EWOULDBLOCK {
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
                    return _SubprocessCShims.write(fileDescriptor.rawValue, startPtr, remainingLength)
                }
                if written > 0 {
                    writtenLength += written
                    if writtenLength >= bytes.count {
                        // Wrote all data
                        try self.removeRegistration(for: fileDescriptor)
                        return writtenLength
                    }
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
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
                    return _SubprocessCShims.write(fileDescriptor.rawValue, startPtr, remainingLength)
                }
                if written > 0 {
                    writtenLength += written
                    if writtenLength >= span.byteCount {
                        // Wrote all data
                        try self.removeRegistration(for: fileDescriptor)
                        return writtenLength
                    }
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
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
}

extension Array : AsyncIO._ContiguousBytes where Element == UInt8 {}

#endif // canImport(Glibc) || canImport(Android) || canImport(Musl)

// MARK: - macOS (DispatchIO)
#if canImport(Darwin)

internal import Dispatch


final class AsyncIO: Sendable {
    static let shared: AsyncIO = AsyncIO()

    private init() {}

    internal func read(
        from diskIO: borrowing IOChannel,
        upTo maxLength: Int
    ) async throws -> DispatchData? {
        return try await self.read(
            from: diskIO.channel,
            upTo: maxLength,
        )
    }

    internal func read(
        from dispatchIO: DispatchIO,
        upTo maxLength: Int
    ) async throws -> DispatchData? {
        return try await withCheckedThrowingContinuation { continuation in
            var buffer: DispatchData = .empty
            dispatchIO.read(
                offset: 0,
                length: maxLength,
                queue: .global()
            ) { done, data, error in
                if error != 0 {
                    continuation.resume(
                        throwing: SubprocessError(
                            code: .init(.failedToReadFromSubprocess),
                            underlyingError: .init(rawValue: error)
                        )
                    )
                    return
                }
                if let data = data {
                    if buffer.isEmpty {
                        buffer = data
                    } else {
                        buffer.append(data)
                    }
                }
                if done {
                    if !buffer.isEmpty {
                        continuation.resume(returning: buffer)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    #if SubprocessSpan
    internal func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing IOChannel
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
            let dispatchData = span.withUnsafeBytes {
                return DispatchData(
                    bytesNoCopy: $0,
                    deallocator: .custom(
                        nil,
                        {
                            // noop
                        }
                    )
                )
            }
            self.write(dispatchData, to: diskIO) { writtenLength, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: writtenLength)
                }
            }
        }
    }
    #endif  // SubprocessSpan

    internal func write(
        _ array: [UInt8],
        to diskIO: borrowing IOChannel
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
            let dispatchData = array.withUnsafeBytes {
                return DispatchData(
                    bytesNoCopy: $0,
                    deallocator: .custom(
                        nil,
                        {
                            // noop
                        }
                    )
                )
            }
            self.write(dispatchData, to: diskIO) { writtenLength, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: writtenLength)
                }
            }
        }
    }

    internal func write(
        _ dispatchData: DispatchData,
        to diskIO: borrowing IOChannel,
        queue: DispatchQueue = .global(),
        completion: @escaping (Int, Error?) -> Void
    ) {
        diskIO.channel.write(
            offset: 0,
            data: dispatchData,
            queue: queue
        ) { done, unwritten, error in
            guard done else {
                // Wait until we are done writing or encountered some error
                return
            }

            let unwrittenLength = unwritten?.count ?? 0
            let writtenLength = dispatchData.count - unwrittenLength
            guard error != 0 else {
                completion(writtenLength, nil)
                return
            }
            completion(
                writtenLength,
                SubprocessError(
                    code: .init(.failedToWriteToSubprocess),
                    underlyingError: .init(rawValue: error)
                )
            )
        }
    }
}

#endif

// MARK: - Windows (I/O Completion Ports)
#if os(Windows)

import Synchronization
internal import Dispatch
@preconcurrency import WinSDK

private typealias SignalStream = AsyncThrowingStream<DWORD, any Error>
private let shutdownPort: UInt64 = .max
private let _registration: Mutex<
    [UInt64 : SignalStream.Continuation]
> = Mutex([:])

final class AsyncIO: @unchecked Sendable {

    protocol _ContiguousBytes: Sendable {
        var count: Int { get }

        func withUnsafeBytes<ResultType>(
            _ body: (UnsafeRawBufferPointer
            ) throws -> ResultType) rethrows -> ResultType
    }

    private final class MonitorThreadContext {
        let ioCompletionPort: HANDLE

        init(ioCompletionPort: HANDLE) {
            self.ioCompletionPort = ioCompletionPort
        }
    }

    static let shared = AsyncIO()

    private let ioCompletionPort: Result<HANDLE, SubprocessError>

    private let monitorThread: Result<HANDLE, SubprocessError>

    private init() {
        var maybeSetupError: SubprocessError? = nil
        // Create the the completion port
        guard let port = CreateIoCompletionPort(
            INVALID_HANDLE_VALUE, nil, 0, 0
        ), port != INVALID_HANDLE_VALUE else {
            let error = SubprocessError(
                code: .init(.asyncIOFailed("CreateIoCompletionPort failed")),
                underlyingError: .init(rawValue: GetLastError())
            )
            self.ioCompletionPort = .failure(error)
            self.monitorThread = .failure(error)
            return
        }
        self.ioCompletionPort = .success(port)
        // Create monitor thread
        let threadContext = MonitorThreadContext(ioCompletionPort: port)
        let threadContextPtr = Unmanaged.passRetained(threadContext)
        let threadHandle = CreateThread(nil, 0, { args in
            func reportError(_ error: SubprocessError) {
                _registration.withLock { store in
                    for continuation in store.values {
                        continuation.finish(throwing: error)
                    }
                }
            }

            let unmanaged = Unmanaged<MonitorThreadContext>.fromOpaque(args!)
            let context = unmanaged.takeRetainedValue()

            // Monitor loop
            while true {
                var bytesTransferred: DWORD = 0
                var targetFileDescriptor: UInt64 = 0
                var overlapped: LPOVERLAPPED? = nil

                let monitorResult = GetQueuedCompletionStatus(
                    context.ioCompletionPort,
                    &bytesTransferred,
                    &targetFileDescriptor,
                    &overlapped,
                    INFINITE
                )
                if !monitorResult {
                    let lastError = GetLastError()
                    if lastError == ERROR_BROKEN_PIPE {
                        // We finished reading the handle. Signal EOF by
                        // finishing the stream.
                        // NOTE: here we deliberately leave now unused continuation
                        // in the store. Windows does not offer an API to remove a
                        // HANDLE from an IOCP port, therefore we leave the registration
                        // to signify the HANDLE has already been resisted.
                        _registration.withLock { store in
                            if let continuation = store[targetFileDescriptor] {
                                continuation.finish()
                            }
                        }
                        continue
                    } else {
                        let error = SubprocessError(
                            code: .init(.asyncIOFailed("GetQueuedCompletionStatus failed")),
                            underlyingError: .init(rawValue: lastError)
                        )
                        reportError(error)
                        break
                    }
                }

                // Breakout the monitor loop if we received shutdown from the shutdownFD
                if targetFileDescriptor == shutdownPort {
                    break
                }
                // Notify the continuations
                _registration.withLock { store in
                    if let continuation = store[targetFileDescriptor] {
                        continuation.yield(bytesTransferred)
                    }
                }
            }
            return 0
        }, threadContextPtr.toOpaque(), 0, nil)
        guard let threadHandle = threadHandle else {
            let error = SubprocessError(
                code: .init(.asyncIOFailed("CreateThread failed")),
                underlyingError: .init(rawValue: GetLastError())
            )
            self.monitorThread = .failure(error)
            return
        }
        self.monitorThread = .success(threadHandle)

        atexit {
            AsyncIO.shared.shutdown()
        }
    }

    private func shutdown() {
        // Post status to shutdown HANDLE
        guard case .success(let ioPort) = ioCompletionPort,
              case .success(let monitorThreadHandle) = monitorThread else {
            return
        }
        PostQueuedCompletionStatus(
            ioPort,
            0,
            shutdownPort,
            nil
        )
        // Wait for monitor thread to exit
        WaitForSingleObject(monitorThreadHandle, INFINITE)
        CloseHandle(ioPort)
        CloseHandle(monitorThreadHandle)
    }

    private func registerHandle(_ handle: HANDLE) -> SignalStream {
        return SignalStream { continuation in
            switch self.ioCompletionPort {
            case .success(let ioPort):
                // Make sure thread setup also succeed
                if case .failure(let error) = monitorThread {
                    continuation.finish(throwing: error)
                    return
                }
                let completionKey = UInt64(UInt(bitPattern: handle))
                // Windows does not offer an API to remove a handle
                // from given ioCompletionPort. If this handle has already
                // been registered we simply need to update the continuation
                let registrationFound = _registration.withLock { storage in
                    if storage[completionKey] != nil {
                        // Old registration found. This means this handle has
                        // already been registered. We simply need to update
                        // the continuation saved
                        storage[completionKey] = continuation
                        return true
                    } else {
                        return false
                    }
                }
                if registrationFound {
                    return
                }

                // Windows Documentation: The function returns the handle
                // of the existing I/O completion port if successful
                guard CreateIoCompletionPort(
                    handle, ioPort, completionKey, 0
                ) == ioPort else {
                    let error = SubprocessError(
                        code: .init(.asyncIOFailed("CreateIoCompletionPort failed")),
                        underlyingError: .init(rawValue: GetLastError())
                    )
                    continuation.finish(throwing: error)
                    return
                }
                // Now save the continuation
                _registration.withLock { storage in
                    storage[completionKey] = continuation
                }
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    internal func removeRegistration(for handle: HANDLE) {
        let completionKey = UInt64(UInt(bitPattern: handle))
        _registration.withLock { storage in
            storage.removeValue(forKey: completionKey)
        }
    }

    func read(
        from diskIO: borrowing IOChannel,
        upTo maxLength: Int
    ) async throws -> [UInt8]? {
        return try await self.read(from: diskIO.channel, upTo: maxLength)
    }

    func read(
        from handle: HANDLE,
        upTo maxLength: Int
    ) async throws -> [UInt8]? {
        // If we are reading until EOF, start with readBufferSize
        // and gradually increase buffer size
        let bufferLength = maxLength == .max ? readBufferSize : maxLength

        var resultBuffer: [UInt8] = Array(
            repeating: 0, count: bufferLength
        )
        var readLength: Int = 0
        var signalStream = self.registerHandle(handle).makeAsyncIterator()

        while true {
            var overlapped = _OVERLAPPED()
            let succeed = try resultBuffer.withUnsafeMutableBufferPointer { bufferPointer in
                // Get a pointer to the memory at the specified offset
                // Windows ReadFile uses DWORD for target count, which means we can only
                // read up to DWORD (aka UInt32) max.
                let targetCount: DWORD
                if MemoryLayout<Int>.size == MemoryLayout<Int32>.size {
                    // On 32 bit systems we don't have to worry about overflowing
                    targetCount = DWORD(truncatingIfNeeded: bufferPointer.count - readLength)
                } else {
                    // On 64 bit systems we need to cap the count at DWORD max
                    targetCount = DWORD(truncatingIfNeeded: min(bufferPointer.count - readLength, Int(UInt32.max)))
                }

                let offsetAddress = bufferPointer.baseAddress!.advanced(by: readLength)
                // Read directly into the buffer at the offset
                return ReadFile(
                    handle,
                    offsetAddress,
                    DWORD(truncatingIfNeeded: targetCount),
                    nil,
                    &overlapped
                )
            }

            if !succeed {
                // It is expected `ReadFile` to return `false` in async mode.
                // Make sure we only get `ERROR_IO_PENDING` or `ERROR_BROKEN_PIPE`
                let lastError = GetLastError()
                if lastError == ERROR_BROKEN_PIPE {
                    // We reached EOF
                    return nil
                }
                guard lastError == ERROR_IO_PENDING else {
                    let error = SubprocessError(
                        code: .init(.failedToReadFromSubprocess),
                        underlyingError: .init(rawValue: lastError)
                    )
                    throw error
                }

            }
            // Now wait for read to finish
            let bytesRead = try await signalStream.next() ?? 0

            if bytesRead == 0 {
                // We reached EOF. Return whatever's left
                guard readLength > 0 else {
                    return nil
                }
                resultBuffer.removeLast(resultBuffer.count - readLength)
                return resultBuffer
            } else {
                // Read some data
                readLength += Int(bytesRead)
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
                    return resultBuffer
                }
            }
        }
    }

    func write(
        _ array: [UInt8],
        to diskIO: borrowing IOChannel
    ) async throws -> Int {
        return try await self._write(array, to: diskIO)
    }

    #if SubprocessSpan
    func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing IOChannel
    ) async throws -> Int {
        let handle = diskIO.channel
        var signalStream = self.registerHandle(diskIO.channel).makeAsyncIterator()
        var writtenLength: Int = 0
        while true {
            var overlapped = _OVERLAPPED()
            let succeed = try span.withUnsafeBytes { ptr in
                // Windows WriteFile uses DWORD for target count
                // which means we can only write up to DWORD max
                let remainingLength: DWORD
                if MemoryLayout<Int>.size == MemoryLayout<Int32>.size {
                    // On 32 bit systems we don't have to worry about overflowing
                    remainingLength = DWORD(truncatingIfNeeded: ptr.count - writtenLength)
                } else {
                    // On 64 bit systems we need to cap the count at DWORD max
                    remainingLength = DWORD(truncatingIfNeeded: min(ptr.count - writtenLength, Int(DWORD.max)))
                }

                let startPtr = ptr.baseAddress!.advanced(by: writtenLength)
                return WriteFile(
                    handle,
                    startPtr,
                    DWORD(truncatingIfNeeded: remainingLength),
                    nil,
                    &overlapped
                )
            }
            if !succeed {
                // It is expected `WriteFile` to return `false` in async mode.
                // Make sure we only get `ERROR_IO_PENDING`
                let lastError = GetLastError()
                guard lastError == ERROR_IO_PENDING else {
                    let error = SubprocessError(
                        code: .init(.failedToWriteToSubprocess),
                        underlyingError: .init(rawValue: lastError)
                    )
                    throw error
                }

            }
            // Now wait for read to finish
            let bytesWritten: DWORD = try await signalStream.next() ?? 0

            writtenLength += Int(bytesWritten)
            if writtenLength >= span.byteCount {
                return writtenLength
            }
        }
    }
    #endif // SubprocessSpan

    func _write<Bytes: _ContiguousBytes>(
        _ bytes: Bytes,
        to diskIO: borrowing IOChannel
    ) async throws -> Int {
        let handle = diskIO.channel
        var signalStream = self.registerHandle(diskIO.channel).makeAsyncIterator()
        var writtenLength: Int = 0
        while true {
            var overlapped = _OVERLAPPED()
            let succeed = try bytes.withUnsafeBytes { ptr in
                // Windows WriteFile uses DWORD for target count
                // which means we can only write up to DWORD max
                let remainingLength: DWORD
                if MemoryLayout<Int>.size == MemoryLayout<Int32>.size {
                    // On 32 bit systems we don't have to worry about overflowing
                    remainingLength = DWORD(truncatingIfNeeded: ptr.count - writtenLength)
                } else {
                    // On 64 bit systems we need to cap the count at DWORD max
                    remainingLength = DWORD(truncatingIfNeeded: min(ptr.count - writtenLength, Int(DWORD.max)))
                }
                let startPtr = ptr.baseAddress!.advanced(by: writtenLength)
                return WriteFile(
                    handle,
                    startPtr,
                    DWORD(truncatingIfNeeded: remainingLength),
                    nil,
                    &overlapped
                )
            }

            if !succeed {
                // It is expected `WriteFile` to return `false` in async mode.
                // Make sure we only get `ERROR_IO_PENDING`
                let lastError = GetLastError()
                guard lastError == ERROR_IO_PENDING else {
                    let error = SubprocessError(
                        code: .init(.failedToWriteToSubprocess),
                        underlyingError: .init(rawValue: lastError)
                    )
                    throw error
                }
            }
            // Now wait for read to finish
            let bytesWritten: DWORD = try await signalStream.next() ?? 0
            writtenLength += Int(bytesWritten)
            if writtenLength >= bytes.count {
                return writtenLength
            }
        }
    }
}

extension Array : AsyncIO._ContiguousBytes where Element == UInt8 {}

#endif

