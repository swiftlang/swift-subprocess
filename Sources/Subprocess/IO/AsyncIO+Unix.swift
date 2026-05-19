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

#if os(Linux) || os(Android) || SUBPROCESS_ASYNCIO_KQUEUE

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if canImport(Darwin)
import Darwin

#elseif canImport(Glibc)
import Glibc

// https://github.com/torvalds/linux/blob/master/include/uapi/linux/fcntl.h
// Complex macro that can't be directly imported in Swift
private let F_GETPIPE_SZ: CInt = 1032
#elseif canImport(Android)
import Android
import posix_filesystem.sys_epoll

// https://github.com/torvalds/linux/blob/master/include/uapi/linux/fcntl.h
// Complex macro that can't be directly imported in Swift
private let F_GETPIPE_SZ: CInt = 1032
#elseif canImport(Musl)
import Musl
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
        for processIdentifier: ProcessIdentifier,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> [UInt8]? {
        return try await self.read(from: diskIO.descriptor(), for: processIdentifier, upTo: maxLength)
    }

    func read(
        from fileDescriptor: FileDescriptor,
        for processIdentifier: ProcessIdentifier,
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
        let signalStream = self.registerFileDescriptor(
            fileDescriptor,
            processIdentifier: processIdentifier,
            for: .read
        )

        do {
            /// Outer loop: every iteration signals that the descriptor is ready
            /// for more data.
            for try await _ in signalStream {
                /// Inner loop: repeatedly call `read()` and read more data until:
                /// 1. We reach EOF (read length is 0), in which case return the result.
                /// 2. We read `maxLength` bytes, in which case return the result.
                /// 3. `read()` returns -1 and sets `errno` to `EAGAIN` or `EWOULDBLOCK`.
                ///    In this case `break` out of the inner loop and `await` the next
                ///    signal in the outer loop.
                while true {
                    let bytesRead: Int
                    do {
                        bytesRead = try resultBuffer.withUnsafeMutableBytes { bufferPointer in
                            // Read directly into the buffer at the offset.
                            return try fileDescriptor.read(
                                into: bufferPointer,
                                retryOnInterrupt: true
                            )
                        }
                    } catch {
                        // FileDescriptor.read only throws Errno
                        let _errno = error as! Errno

                        if self.shouldWaitForNextSignal(with: _errno.rawValue) {
                            // No data available right now; wait for the next signal.
                            break
                        } else {
                            // Throw all other errors.
                            try self.removeRegistration(for: fileDescriptor)
                            throw SubprocessError.failedToReadFromProcess(
                                withUnderlyingError: _errno
                            )
                        }
                    }

                    if bytesRead > 0 {
                        // Read some data. Return immediately so the caller can
                        // process it without waiting for the buffer to fill.
                        try self.removeRegistration(for: fileDescriptor)
                        resultBuffer.removeLast(resultBuffer.count - bytesRead)
                        return resultBuffer
                    } else if bytesRead == 0 {
                        // We reached EOF.
                        try self.removeRegistration(for: fileDescriptor)
                        return nil
                    } else {
                        // This branch is unreachable in practice.
                        throw SubprocessError.failedToReadFromProcess(
                            withUnderlyingError: nil
                        )
                    }
                }
            }

            // The signal stream finished without delivering more data. This
            // happens when `cancelAsyncIO` runs because the child has exited
            // and we want to stop waiting for an EOF that may never come (the
            // pipe could be held open by an inherited grandchild). Try a final
            // non-blocking read so we don't drop bytes that were already in
            // the kernel buffer when cancellation arrived; subsequent calls
            // keep draining one chunk at a time and then return EOF.
            try self.removeRegistration(for: fileDescriptor)
            let drainedLength = resultBuffer.withUnsafeMutableBytes { bufferPtr in
                // The descriptor was set to non-blocking in `setNonblocking`,
                // so this `read` returns immediately even if no data is ready.
                do {
                    return try fileDescriptor.read(
                        into: bufferPtr,
                        retryOnInterrupt: true
                    )
                } catch {
                    // EAGAIN, EWOULDBLOCK, or another error: no more data
                    // is available right now.
                    return 0
                }
            }
            if drainedLength > 0 {
                resultBuffer.removeLast(resultBuffer.count - drainedLength)
                return resultBuffer
            }

            return nil
        } catch {
            try self.removeRegistration(for: fileDescriptor)
            // Reset the error code to `.failedToRead` to match other platforms.
            guard let originalError = error as? SubprocessError else {
                throw SubprocessError.failedToReadFromProcess(
                    withUnderlyingError: nil
                )
            }
            throw SubprocessError.failedToReadFromProcess(
                withUnderlyingError: originalError.underlyingError
            )
        }
    }

    func write(
        _ array: [UInt8],
        to diskIO: borrowing IODescriptor,
        for processIdentifier: ProcessIdentifier
    ) async throws(SubprocessError) -> Int {
        return try await self.write(array._bytes, to: diskIO, for: processIdentifier)
    }

    func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing IODescriptor,
        for processIdentifier: ProcessIdentifier
    ) async throws(SubprocessError) -> Int {
        guard span.byteCount > 0 else {
            return 0
        }
        let fileDescriptor = diskIO.descriptor()
        let signalStream = self.registerFileDescriptor(
            fileDescriptor,
            processIdentifier: processIdentifier,
            for: .write
        )
        var writtenLength: Int = 0
        do {
            /// Outer loop: every iteration signals that the descriptor is ready
            /// for more data.
            for try await _ in signalStream {
                /// Inner loop: repeatedly call `write()` and write more data until:
                /// 1. We've written `span.byteCount` bytes.
                /// 2. `FileDescriptor.write()` throws `Errno` with `EAGAIN` or
                ///    `EWOULDBLOCK`. In this case `break` out of the inner loop and
                ///    `await` the next signal in the outer loop.
                while true {
                    let written: Int
                    do {
                        written = try span.extracting(
                            last: span.byteCount - writtenLength
                        ).withUnsafeBytes {
                            return try fileDescriptor.write(
                                $0,
                                retryOnInterrupt: true
                            )
                        }
                    } catch {
                        // FileDescriptor.write only throws Errno
                        let _errno = error as! Errno

                        if self.shouldWaitForNextSignal(with: _errno.rawValue) {
                            // The pipe is full right now; wait for the next signal.
                            break
                        } else {
                            // Throw all other errors.
                            try self.removeRegistration(for: fileDescriptor)
                            throw SubprocessError.failedToWriteToProcess(
                                withUnderlyingError: _errno
                            )
                        }
                    }

                    writtenLength += written
                    if writtenLength >= span.byteCount {
                        // Wrote all data.
                        try self.removeRegistration(for: fileDescriptor)
                        return writtenLength
                    }
                }
            }

            // The signal stream finished while data remained to write
            // (typically because `cancelAsyncIO` ran after the child exited).
            // Return whatever bytes the call already pushed so the caller
            // observes a partial write rather than misreading silence as a
            // successful zero-byte write.
            try self.removeRegistration(for: fileDescriptor)
            return writtenLength
        } catch {
            // Reset the error code to `.failedToWrite` to match other platforms.
            guard let originalError = error as? SubprocessError else {
                throw SubprocessError.failedToWriteToProcess(
                    withUnderlyingError: error as? SubprocessError.UnderlyingError
                )
            }
            throw SubprocessError.failedToWriteToProcess(
                withUnderlyingError: originalError.underlyingError
            )
        }
    }

    @inline(__always)
    private func shouldWaitForNextSignal(with error: CInt) -> Bool {
        return error == EAGAIN || error == EWOULDBLOCK
    }

    static func queryPipeBufferSize(for fileDescriptor: IODescriptor.Descriptor) -> Int {
        #if os(Linux) || os(Android)

        // Works on glibc, musl, and Bionic since kernel 2.6.35.
        let sz = fcntl(fileDescriptor.rawValue, F_GETPIPE_SZ)
        // Fall back to the page size.
        return sz > 0 ? Int(sz) : systemPageSize
        #elseif canImport(Darwin) || os(OpenBSD)
        // XNU and OpenBSD both set `st_blksize` to the pipe's current capacity
        // in `pipe_stat()`. Undocumented on Darwin but stable; verify with a
        // unit test.
        var st = stat()
        guard
            fstat(
                fileDescriptor.rawValue, &st
            ) == 0, st.st_blksize > 0
        else {
            // Fall back to the page size.
            return systemPageSize
        }
        return Int(st.st_blksize)
        #else
        // FreeBSD does not have an `st.st_blksize` equivalent.
        // `pipe_stat()` hardcodes `st.st_blksize = PAGE_SIZE`, so use 64 KB
        // like other platforms.
        return 64 * 1024
        #endif
    }
}

/// A bookkeeping structure that maps file descriptors to their pending I/O
/// continuations and groups those descriptors by the process that owns them.
///
/// The platform-specific `AsyncIO` backends use this type to find the
/// continuation for a descriptor when the kernel reports activity, and to
/// identify which descriptors belong to a process when the process exits and
/// the I/O for it must be cancelled.
internal struct Registration {
    typealias Record = (continuation: SignalStream.Continuation, processIdentifier: ProcessIdentifier)
    typealias CancelledContinuation = (continuation: SignalStream.Continuation, fileDescriptor: PlatformFileDescriptor)

    private var fileDescriptorMap: [PlatformFileDescriptor: Record]
    private var processIdentifierMap: [ProcessIdentifier: Set<PlatformFileDescriptor>]

    /// The set of processes whose I/O has already been cancelled.
    ///
    /// `register` consults this set and rejects new registrations for any
    /// process that appears in it. This prevents a registration that races
    /// with `cancel` from establishing a stream that nothing will ever
    /// cancel. Call `remove(processIdentifier:)` once the process is fully
    /// reaped to keep this set bounded.
    private var cancelledProcesses: Set<ProcessIdentifier>

    init() {
        self.fileDescriptorMap = [:]
        self.processIdentifierMap = [:]
        self.cancelledProcesses = Set()
    }

    /// Records a file descriptor as part of a process's pending I/O.
    ///
    /// - Parameters:
    ///   - fileDescriptor: The descriptor to track.
    ///   - continuation: The continuation to resume when the descriptor
    ///     becomes ready or the I/O is cancelled.
    ///   - processIdentifier: The process that owns the descriptor.
    /// - Returns: `true` if the registration was added; `false` if the
    ///   process has already been cancelled. When the function returns
    ///   `false`, the caller must finish the supplied continuation
    ///   immediately and skip any further setup such as attaching the
    ///   descriptor to `epoll` or `kqueue`.
    mutating func register(
        fileDescriptor: PlatformFileDescriptor,
        continuation: SignalStream.Continuation,
        processIdentifier: ProcessIdentifier
    ) -> Bool {
        if self.cancelledProcesses.contains(processIdentifier) {
            return false
        }
        self.fileDescriptorMap[fileDescriptor] = (continuation, processIdentifier)
        var fileDescriptorSet = self.processIdentifierMap[processIdentifier] ?? Set()
        fileDescriptorSet.insert(fileDescriptor)
        self.processIdentifierMap[processIdentifier] = fileDescriptorSet
        return true
    }

    /// Removes the registration for `fileDescriptor`.
    ///
    /// - Parameter fileDescriptor: The descriptor whose registration to drop.
    /// - Returns: The continuation associated with the descriptor, or `nil`
    ///   if no registration exists.
    mutating func removeRegistration(
        for fileDescriptor: PlatformFileDescriptor
    ) -> SignalStream.Continuation? {
        guard let content = self.fileDescriptorMap.removeValue(forKey: fileDescriptor) else {
            return nil
        }
        if var fileDescriptorSet = self.processIdentifierMap[content.processIdentifier] {
            fileDescriptorSet.remove(fileDescriptor)
            self.processIdentifierMap[content.processIdentifier] = fileDescriptorSet
        }
        return content.continuation
    }

    /// Marks `processIdentifier` as cancelled and returns the descriptor
    /// registrations to abort.
    ///
    /// Once a process is marked cancelled, subsequent calls to `register`
    /// for that process return `false` until `remove(processIdentifier:)`
    /// drops the marker.
    ///
    /// - Parameter processIdentifier: The process whose I/O to cancel.
    /// - Returns: The registrations that the caller must finish. The
    ///   array is empty when the process has no pending I/O.
    mutating func cancel(
        processIdentifier: ProcessIdentifier
    ) -> [CancelledContinuation] {
        self.cancelledProcesses.insert(processIdentifier)

        guard
            let existing = self.processIdentifierMap.removeValue(
                forKey: processIdentifier
            )
        else {
            return []
        }

        return existing.compactMap { fd in
            guard let content = self.fileDescriptorMap.removeValue(forKey: fd) else {
                return nil
            }
            return (content.continuation, fd)
        }
    }

    /// Drops the cancellation marker for `processIdentifier`.
    ///
    /// Call this after the process is fully reaped and no further I/O for
    /// it can occur, to keep `cancelledProcesses` from growing without
    /// bound.
    ///
    /// - Parameter processIdentifier: The process to forget.
    mutating func remove(processIdentifier: ProcessIdentifier) {
        self.cancelledProcesses.remove(processIdentifier)
    }

    /// Returns the continuation registered for `fileDescriptor`, or `nil`
    /// if none exists.
    func continuation(for fileDescriptor: PlatformFileDescriptor) -> SignalStream.Continuation? {
        return self.fileDescriptorMap[fileDescriptor]?.continuation
    }

    /// Returns every currently registered continuation.
    ///
    /// The platform backends call this when the monitor thread fails and
    /// they need to surface the error to every awaiting reader and writer.
    func allContinuations() -> [SignalStream.Continuation] {
        return self.fileDescriptorMap.values.map { $0.continuation }
    }
}

/// The result of a single attempt to register a file descriptor with the
/// platform's I/O multiplexer.
internal enum RegistrationOutcome {
    /// The descriptor was added successfully.
    case registered
    /// The owning process has already been cancelled, so the registration
    /// was rejected. The caller finishes the continuation without further
    /// setup.
    case alreadyCancelled
    /// The platform syscall (such as `epoll_ctl` or `kevent`) reported an
    /// error. The caller finishes the continuation by throwing this error.
    case failed(SubprocessError)
}

extension Array: AsyncIO._ContiguousBytes where Element == UInt8 {}

#endif
