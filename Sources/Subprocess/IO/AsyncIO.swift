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

    static let shared: AsyncIO = AsyncIO()

    typealias OutputStream = AsyncThrowingStream<AsyncBufferSequence.Buffer, any Error>

    private enum Event {
        case read
        case write
    }

    private let epollFileDescriptor: CInt
    private let shutdownFileDescriptor: CInt
    private let setupError: SubprocessError?

    private let monitorThread: pthread_t

    private init() {
        var maybeSetupError: SubprocessError? = nil
        // Create main epoll fd
        self.epollFileDescriptor = epoll_create1(CInt(EPOLL_CLOEXEC))
        if self.epollFileDescriptor < 0 {
            maybeSetupError = SubprocessError(
                code: .init(.asyncIOFailed("epoll_create1 failed")),
                underlyingError: .init(rawValue: errno)
            )
        }
        // Create shutdownFileDescriptor
        self.shutdownFileDescriptor = eventfd(0, CInt(EFD_NONBLOCK | EFD_CLOEXEC))
        if self.shutdownFileDescriptor < 0 {
            maybeSetupError = SubprocessError(
                code: .init(.asyncIOFailed("eventfd failed")),
                underlyingError: .init(rawValue: errno)
            )
        } else {
            // Register shutdownFileDescriptor with epoll
            var event = epoll_event(
                events: EPOLLIN.rawValue,
                data: epoll_data(fd: self.shutdownFileDescriptor)
            )
            let rc = epoll_ctl(
                self.epollFileDescriptor,
                EPOLL_CTL_ADD,
                self.shutdownFileDescriptor,
                &event
            )
            if rc != 0 {
                maybeSetupError = SubprocessError(
                    code: .init(.asyncIOFailed(
                        "failed to add shutdown fd \(self.shutdownFileDescriptor) to epoll list")
                    ),
                    underlyingError: .init(rawValue: errno)
                )
            }
        }

        // Create thread data
        let context = MonitorThreadContext(
            epollFileDescriptor: self.epollFileDescriptor,
            shutdownFileDescriptor: self.shutdownFileDescriptor
        )
        let threadContext = Unmanaged.passRetained(context)
        #if os(macOS) || os(FreeBSD) || os(OpenBSD)
        var thread: pthread_t? = nil
        #else
        var thread: pthread_t = pthread_t()
        #endif
        let rc = pthread_create(&thread, nil, { args in
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
        #if os(macOS) || os(FreeBSD) || os(OpenBSD)
        self.monitorThread = thread!
        #else
        self.monitorThread = thread
        #endif
        if rc != 0 {
            maybeSetupError = SubprocessError(
                code: .init(.asyncIOFailed("Failed to create monitor thread")),
                underlyingError: .init(rawValue: rc)
            )
        }

        self.setupError = maybeSetupError
        atexit {
            AsyncIO.shared.shutdown()
        }
    }

    private func shutdown() {
        var one: UInt64 = 1
        // Wake up the thread for shutdown
        _ = _SubprocessCShims.write(self.shutdownFileDescriptor, &one, MemoryLayout<UInt64>.size)
        // Cleanup the monitor thread
        pthread_join(self.monitorThread, nil)
    }


    private func registerFileDescriptor(
        _ fileDescriptor: FileDescriptor,
        for event: Event
    ) -> SignalStream {
        return SignalStream { continuation in
            // If setup failed, nothing much we can do
            if let setupError = self.setupError {
                continuation.finish(throwing: setupError)
                return
            }
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
                self.epollFileDescriptor,
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
        }
    }

    private func removeRegistration(for fileDescriptor: FileDescriptor) throws {
        let rc = epoll_ctl(
            self.epollFileDescriptor,
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
    }
}

extension AsyncIO {

    protocol _ContiguousBytes {
        var count: Int { get }

        func withUnsafeBytes<ResultType>(
            _ body: (UnsafeRawBufferPointer
        ) throws -> ResultType) rethrows -> ResultType
    }

    func read(
        from diskIO: borrowing TrackedPlatformDiskIO,
        upTo maxLength: Int
    ) async throws -> [UInt8]? {
        return try await self.read(from: diskIO.fileDescriptor, upTo: maxLength)
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
        for try await _ in signalStream {
            // Every iteration signals we are ready to read more data
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
        to diskIO: borrowing TrackedPlatformDiskIO
    ) async throws -> Int {
        return try await self._write(array, to: diskIO)
    }

    func _write<Bytes: _ContiguousBytes>(
        _ bytes: Bytes,
        to diskIO: borrowing TrackedPlatformDiskIO
    ) async throws -> Int {
        let fileDescriptor = diskIO.fileDescriptor
        let signalStream = self.registerFileDescriptor(fileDescriptor, for: .write)
        var writtenLength: Int = 0
        for try await _ in signalStream {
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
    @available(SubprocessSpan, *)
    func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing TrackedPlatformDiskIO
    ) async throws -> Int {
        let fileDescriptor = diskIO.fileDescriptor
        let signalStream = self.registerFileDescriptor(fileDescriptor, for: .write)
        var writtenLength: Int = 0
        for try await _ in signalStream {
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
        from diskIO: borrowing TrackedPlatformDiskIO,
        upTo maxLength: Int
    ) async throws -> DispatchData? {
        return try await self.read(
            from: diskIO.dispatchIO,
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
    @available(SubprocessSpan, *)
    internal func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing TrackedPlatformDiskIO
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
        to diskIO: borrowing TrackedPlatformDiskIO
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
        to diskIO: borrowing TrackedPlatformDiskIO,
        queue: DispatchQueue = .global(),
        completion: @escaping (Int, Error?) -> Void
    ) {
        diskIO.dispatchIO.write(
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

// MARK: - Windows (I/O Completion Ports) TODO
#if os(Windows)

internal import Dispatch
import WinSDK

final class AsyncIO: Sendable {

    protocol _ContiguousBytes: Sendable {
        var count: Int { get }

        func withUnsafeBytes<ResultType>(
            _ body: (UnsafeRawBufferPointer
            ) throws -> ResultType) rethrows -> ResultType
    }

    static let shared = AsyncIO()

    private init() {}

    func read(
        from diskIO: borrowing TrackedPlatformDiskIO,
        upTo maxLength: Int
    ) async throws -> [UInt8]? {
        return try await self.read(from: diskIO.fileDescriptor, upTo: maxLength)
    }

    func read(
        from fileDescriptor: FileDescriptor,
        upTo maxLength: Int
    ) async throws -> [UInt8]? {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var totalBytesRead: Int = 0
                var lastError: DWORD? = nil
                let values = [UInt8](
                    unsafeUninitializedCapacity: maxLength
                ) { buffer, initializedCount in
                    while true {
                        guard let baseAddress = buffer.baseAddress else {
                            initializedCount = 0
                            break
                        }
                        let bufferPtr = baseAddress.advanced(by: totalBytesRead)
                        var bytesRead: DWORD = 0
                        let readSucceed = ReadFile(
                            fileDescriptor.platformDescriptor,
                            UnsafeMutableRawPointer(mutating: bufferPtr),
                            DWORD(maxLength - totalBytesRead),
                            &bytesRead,
                            nil
                        )
                        if !readSucceed {
                            // Windows throws ERROR_BROKEN_PIPE when the pipe is closed
                            let error = GetLastError()
                            if error == ERROR_BROKEN_PIPE {
                                // We are done reading
                                initializedCount = totalBytesRead
                            } else {
                                // We got some error
                                lastError = error
                                initializedCount = 0
                            }
                            break
                        } else {
                            // We successfully read the current round
                            totalBytesRead += Int(bytesRead)
                        }

                        if totalBytesRead >= maxLength {
                            initializedCount = min(maxLength, totalBytesRead)
                            break
                        }
                    }
                }
                if let lastError = lastError {
                    let windowsError = SubprocessError(
                        code: .init(.failedToReadFromSubprocess),
                        underlyingError: .init(rawValue: lastError)
                    )
                    continuation.resume(throwing: windowsError)
                } else {
                    continuation.resume(returning: values)
                }
            }
        }
    }

    func write(
        _ array: [UInt8],
        to diskIO: borrowing TrackedPlatformDiskIO
    ) async throws -> Int {
        return try await self._write(array, to: diskIO)
    }

    #if SubprocessSpan
    @available(SubprocessSpan, *)
    func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing TrackedPlatformDiskIO
    ) async throws -> Int {
        // TODO: Remove this hack with I/O Completion Ports rewrite
        struct _Box: @unchecked Sendable {
            let ptr: UnsafeRawBufferPointer
        }
        let fileDescriptor = diskIO.fileDescriptor
        return try await withCheckedThrowingContinuation { continuation in
            span.withUnsafeBytes { ptr in
                let box = _Box(ptr: ptr)
                DispatchQueue.global().async {
                    let handle = HANDLE(bitPattern: _get_osfhandle(fileDescriptor.rawValue))!
                    var writtenBytes: DWORD = 0
                    let writeSucceed = WriteFile(
                        handle,
                        box.ptr.baseAddress,
                        DWORD(box.ptr.count),
                        &writtenBytes,
                        nil
                    )
                    if !writeSucceed {
                        let error = SubprocessError(
                            code: .init(.failedToWriteToSubprocess),
                            underlyingError: .init(rawValue: GetLastError())
                        )
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: Int(writtenBytes))
                    }
                }
            }
        }
    }
    #endif // SubprocessSpan

    func _write<Bytes: _ContiguousBytes>(
        _ bytes: Bytes,
        to diskIO: borrowing TrackedPlatformDiskIO
    ) async throws -> Int {
        let fileDescriptor = diskIO.fileDescriptor
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let handle = HANDLE(bitPattern: _get_osfhandle(fileDescriptor.rawValue))!
                var writtenBytes: DWORD = 0
                let writeSucceed = bytes.withUnsafeBytes { ptr in
                    return WriteFile(
                        handle,
                        ptr.baseAddress,
                        DWORD(ptr.count),
                        &writtenBytes,
                        nil
                    )
                }
                if !writeSucceed {
                    let error = SubprocessError(
                        code: .init(.failedToWriteToSubprocess),
                        underlyingError: .init(rawValue: GetLastError())
                    )
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: Int(writtenBytes))
                }
            }
        }
    }
}

extension Array : AsyncIO._ContiguousBytes where Element == UInt8 {}

#endif

