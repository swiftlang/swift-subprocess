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

/// Windows AsyncIO based on IO Completion Ports and Overlapped

#if os(Windows)

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

import _SubprocessCShims
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
        /// Microsoft documentation for `CreateThread` states:
        /// > A thread in an executable that calls the C run-time library (CRT)
        /// > should use the _beginthreadex and _endthreadex functions for
        /// > thread management rather than CreateThread and ExitThread
        let threadHandleValue = _beginthreadex(nil, 0, { args in
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
                let continuation = _registration.withLock { store -> SignalStream.Continuation? in
                    if let continuation = store[targetFileDescriptor] {
                        return continuation
                    }
                    return nil
                }
                continuation?.yield(bytesTransferred)
            }
            return 0
        }, threadContextPtr.toOpaque(), 0, nil)
        guard threadHandleValue > 0,
            let threadHandle = HANDLE(bitPattern: threadHandleValue) else {
            // _beginthreadex uses errno instead of GetLastError()
            let capturedError = _subprocess_windows_get_errno()
            let error = SubprocessError(
                code: .init(.asyncIOFailed("_beginthreadex failed")),
                underlyingError: .init(rawValue: capturedError)
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
            ioPort,         // CompletionPort
            0,              // Number of bytes transferred.
            shutdownPort,   // Completion key to post status
            nil             // Overlapped
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
            // We use an empty `_OVERLAPPED()` here because `ReadFile` below
            // only reads non-seekable files, aka pipes.
            var overlapped = _OVERLAPPED()
            let succeed = try resultBuffer.withUnsafeMutableBufferPointer { bufferPointer in
                // Get a pointer to the memory at the specified offset
                // Windows ReadFile uses DWORD for target count, which means we can only
                // read up to DWORD (aka UInt32) max.
                let targetCount: DWORD = self.calculateRemainingCount(
                    totalCount: bufferPointer.count,
                    readCount: readLength
                )

                let offsetAddress = bufferPointer.baseAddress!.advanced(by: readLength)
                // Read directly into the buffer at the offset
                return ReadFile(
                    handle,
                    offsetAddress,
                    targetCount,
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
                readLength += Int(truncatingIfNeeded: bytesRead)
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
            // We use an empty `_OVERLAPPED()` here because `WriteFile` below
            // only writes to non-seekable files, aka pipes.
            var overlapped = _OVERLAPPED()
            let succeed = try span.withUnsafeBytes { ptr in
                // Windows WriteFile uses DWORD for target count
                // which means we can only write up to DWORD max
                let remainingLength: DWORD = self.calculateRemainingCount(
                    totalCount: ptr.count,
                    readCount: writtenLength
                )

                let startPtr = ptr.baseAddress!.advanced(by: writtenLength)
                return WriteFile(
                    handle,
                    startPtr,
                    remainingLength,
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

            writtenLength += Int(truncatingIfNeeded: bytesWritten)
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
            // We use an empty `_OVERLAPPED()` here because `WriteFile` below
            // only writes to non-seekable files, aka pipes.
            var overlapped = _OVERLAPPED()
            let succeed = try bytes.withUnsafeBytes { ptr in
                // Windows WriteFile uses DWORD for target count
                // which means we can only write up to DWORD max
                let remainingLength: DWORD = self.calculateRemainingCount(
                    totalCount: ptr.count,
                    readCount: writtenLength
                )
                let startPtr = ptr.baseAddress!.advanced(by: writtenLength)
                return WriteFile(
                    handle,
                    startPtr,
                    remainingLength,
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
            writtenLength += Int(truncatingIfNeeded: bytesWritten)
            if writtenLength >= bytes.count {
                return writtenLength
            }
        }
    }

    // Windows ReadFile uses DWORD for target count, which means we can only
    // read up to DWORD (aka UInt32) max.
    private func calculateRemainingCount(totalCount: Int, readCount: Int) -> DWORD {
        // We support both 32bit and 64bit systems for Windows
        if MemoryLayout<Int>.size == MemoryLayout<Int32>.size {
            // On 32 bit systems we don't have to worry about overflowing
            return DWORD(truncatingIfNeeded: totalCount - readCount)
        } else {
            // On 64 bit systems we need to cap the count at DWORD max
            return DWORD(truncatingIfNeeded: min(totalCount - readCount, Int(DWORD.max)))
        }
    }
}

extension Array : AsyncIO._ContiguousBytes where Element == UInt8 {}

#endif

