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

#if os(Linux) || os(Android) || SUBPROCESS_ASYNCIO_DISPATCH

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if canImport(Darwin)
import Darwin

let _subprocess_read = Darwin.read
let _subprocess_write = Darwin.write
let _subprocess_close = Darwin.close
#elseif canImport(Glibc)
import Glibc

let _subprocess_read = Glibc.read
let _subprocess_write = Glibc.write
let _subprocess_close = Glibc.close
// https://github.com/torvalds/linux/blob/master/include/uapi/linux/fcntl.h
// Complex macro that can't be directly imported in Swift
private let F_GETPIPE_SZ: CInt = 1032
#elseif canImport(Android)
import Android
import posix_filesystem.sys_epoll

let _subprocess_read = Android.read
let _subprocess_write = Android.write
let _subprocess_close = Android.close
// https://github.com/torvalds/linux/blob/master/include/uapi/linux/fcntl.h
// Complex macro that can't be directly imported in Swift
private let F_GETPIPE_SZ: CInt = 1032
#elseif canImport(Musl)
import Musl

let _subprocess_read = Musl.read
let _subprocess_write = Musl.write
let _subprocess_close = Musl.close
#endif

import _SubprocessCShims

internal typealias SignalStream = AsyncThrowingStream<Bool, any Error>

extension AsyncIO {
    internal enum Event {
        case read
        case write
    }

    protocol _ContiguousBytes {
        var count: Int { get }

        func withUnsafeBytes<ResultType>(
            _ body: (UnsafeRawBufferPointer) throws -> ResultType
        ) rethrows -> ResultType
    }

    internal func setNonblocking(for fileDescriptor: FileDescriptor) -> SubprocessError? {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags != -1 else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "failed to get flags for \(fileDescriptor.rawValue)",
                underlyingError: Errno(rawValue: errno)
            )
            return error
        }
        guard fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK) != -1 else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "failed to set \(fileDescriptor.rawValue) to be non-blocking",
                underlyingError: Errno(rawValue: errno)
            )
            return error
        }
        return nil
    }

    func read(
        from diskIO: borrowing IODescriptor,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> [UInt8]? {
        return try await self.read(from: diskIO.descriptor(), upTo: maxLength)
    }

    func read(
        from fileDescriptor: FileDescriptor,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> [UInt8]? {
        guard maxLength > 0 else {
            return nil
        }
        let bufferLength: Int
        if maxLength == .max {
            // Prevent OOM allocation
            bufferLength = Self.queryPipeBufferSize(for: fileDescriptor)
        } else {
            bufferLength = maxLength
        }

        var resultBuffer: [UInt8] = Array(
            repeating: 0, count: bufferLength
        )
        let signalStream = self.registerFileDescriptor(fileDescriptor, for: .read)

        do {
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
                        // Read directly into the buffer at the offset
                        return _subprocess_read(
                            fileDescriptor.rawValue,
                            bufferPointer.baseAddress!,
                            bufferPointer.count
                        )
                    }
                    let capturedErrno = errno
                    if bytesRead > 0 {
                        // Read some data
                        // Return immediately so the caller can
                        // process it without waiting for the buffer to fill.
                        try self.removeRegistration(for: fileDescriptor)
                        resultBuffer.removeLast(resultBuffer.count - bytesRead)
                        return resultBuffer
                    } else if bytesRead == 0 {
                        // We reached EOF.
                        try self.removeRegistration(for: fileDescriptor)
                        return nil
                    } else {
                        if self.shouldWaitForNextSignal(with: capturedErrno) {
                            // No more data for now wait for the next signal
                            break
                        } else {
                            // Throw all other errors
                            try self.removeRegistration(for: fileDescriptor)
                            throw SubprocessError.failedToReadFromProcess(
                                withUnderlyingError: Errno(rawValue: capturedErrno)
                            )
                        }
                    }
                }
            }
        } catch {
            try self.removeRegistration(for: fileDescriptor)
            // Reset error code to .failedToRead to match other platforms
            guard let originalError = error as? SubprocessError else {
                throw SubprocessError.failedToReadFromProcess(
                    withUnderlyingError: nil
                )
            }
            throw SubprocessError.failedToReadFromProcess(
                withUnderlyingError: originalError.underlyingError
            )
        }
        return nil
    }

    func write(
        _ array: [UInt8],
        to diskIO: borrowing IODescriptor
    ) async throws(SubprocessError) -> Int {
        return try await self._write(array, to: diskIO)
    }

    func _write<Bytes: _ContiguousBytes>(
        _ bytes: Bytes,
        to diskIO: borrowing IODescriptor
    ) async throws(SubprocessError) -> Int {
        guard bytes.count > 0 else {
            return 0
        }
        let fileDescriptor = diskIO.descriptor()
        let signalStream = self.registerFileDescriptor(fileDescriptor, for: .write)
        var writtenLength: Int = 0
        do {
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
                    let capturedErrno = errno
                    if written > 0 {
                        writtenLength += written
                        if writtenLength >= bytes.count {
                            // Wrote all data
                            try self.removeRegistration(for: fileDescriptor)
                            return writtenLength
                        }
                    } else {
                        if self.shouldWaitForNextSignal(with: capturedErrno) {
                            // No more data for now wait for the next signal
                            break
                        } else {
                            // Throw all other errors
                            try self.removeRegistration(for: fileDescriptor)
                            throw SubprocessError.failedToWriteToProcess(
                                withUnderlyingError: Errno(rawValue: capturedErrno)
                            )
                        }
                    }
                }
            }
        } catch {
            // Reset error code to .failedToWrite to match other platforms
            guard let originalError = error as? SubprocessError else {
                throw SubprocessError.failedToWriteToProcess(
                    withUnderlyingError: error as? SubprocessError.UnderlyingError
                )
            }
            throw SubprocessError.failedToWriteToProcess(
                withUnderlyingError: originalError.underlyingError
            )
        }
        return 0
    }

    func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing IODescriptor
    ) async throws(SubprocessError) -> Int {
        guard span.byteCount > 0 else {
            return 0
        }
        let fileDescriptor = diskIO.descriptor()
        let signalStream = self.registerFileDescriptor(fileDescriptor, for: .write)
        var writtenLength: Int = 0
        do {
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
                    let capturedErrno = errno
                    if written > 0 {
                        writtenLength += written
                        if writtenLength >= span.byteCount {
                            // Wrote all data
                            try self.removeRegistration(for: fileDescriptor)
                            return writtenLength
                        }
                    } else {
                        if self.shouldWaitForNextSignal(with: capturedErrno) {
                            // No more data for now wait for the next signal
                            break
                        } else {
                            // Throw all other errors
                            try self.removeRegistration(for: fileDescriptor)
                            throw SubprocessError.failedToWriteToProcess(
                                withUnderlyingError: Errno(rawValue: capturedErrno)
                            )
                        }
                    }
                }
            }
        } catch {
            // Reset error code to .failedToWrite to match other platforms
            guard let originalError = error as? SubprocessError else {
                throw SubprocessError.failedToWriteToProcess(
                    withUnderlyingError: error as? SubprocessError.UnderlyingError
                )
            }
            throw SubprocessError.failedToWriteToProcess(
                withUnderlyingError: originalError.underlyingError
            )
        }
        return 0
    }

    @inline(__always)
    private func shouldWaitForNextSignal(with error: CInt) -> Bool {
        return error == EAGAIN || error == EWOULDBLOCK || error == EINTR
    }

    static func queryPipeBufferSize(for fileDescriptor: IODescriptor.Descriptor) -> Int {
        #if os(Linux) || os(Android)

        // Works on glibc, musl, and Bionic since kernel 2.6.35
        let sz = fcntl(fileDescriptor.rawValue, F_GETPIPE_SZ)
        // Fall back to page size
        return sz > 0 ? Int(sz) : systemPageSize
        #elseif canImport(Darwin) || os(OpenBSD)
        // XNU and OpenBSD both set st_blksize to the pipe's current capacity
        // in pipe_stat(). Undocumented on Darwin but stable; verify with a unit test.
        var st = stat()
        guard
            fstat(
                fileDescriptor.rawValue, &st
            ) == 0, st.st_blksize > 0
        else {
            // Fall back to page size
            return systemPageSize
        }
        return Int(st.st_blksize)
        #else
        // FreeBSD does not have `st.st_blksize` equivelent.
        // pipe_stat() hardcodes st.st_blksize = PAGE_SIZE
        // Use 64kb like other platforms
        return 64 * 1024
        #endif
    }
}

extension Array: AsyncIO._ContiguousBytes where Element == UInt8 {}

#endif
