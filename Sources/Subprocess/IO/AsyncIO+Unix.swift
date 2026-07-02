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
        // Register the descriptor with the kqueue/epoll. It stays registered across reads
        // and is only detached when the caller closes it (or on EOF/error/cancellation),
        // so sustained streaming costs one `epoll_ctl`/`kevent` registration per descriptor
        // instead of one per buffer.
        let (signalStream, outcome) = self.registerFileDescriptor(
            fileDescriptor,
            processIdentifier: processIdentifier,
            for: .read
        )
        switch outcome {
        case .registered, .alreadyCancelled:
            // `.alreadyCancelled` still drains: the loop below reads whatever
            // is already buffered without awaiting, since the signal stream is
            // already finished.
            break
        case .failed(let error):
            throw SubprocessError.failedToReadFromProcess(
                withUnderlyingError: error.underlyingError
            )
        }
        var iterator = signalStream.makeAsyncIterator()

        // Each iteration first attempts a non-blocking read, draining bytes
        // that are already buffered, and only awaits a readiness signal when
        // the read reports `EAGAIN`. Because the descriptor is registered edge-triggered,
        // this "try first" step is what keeps a persistent registration correct:
        // we never park while data is buffered, so a missed edge can't strand bytes.
        readLoop: while true {
            do {
                let bytesRead = try resultBuffer.withUnsafeMutableBytes { bufferPointer in
                    // Read directly into the buffer.
                    return try fileDescriptor.read(
                        into: bufferPointer,
                        retryOnInterrupt: true
                    )
                }
                if bytesRead > 0 {
                    // Read some data. Return immediately so the caller can
                    // process it without waiting for the buffer to fill. The
                    // descriptor stays registered for the next read.
                    resultBuffer.removeLast(resultBuffer.count - bytesRead)
                    return resultBuffer
                } else {
                    // EOF: no more data will ever arrive. Detach now.
                    self.removeRegistration(for: fileDescriptor)
                    return nil
                }
            } catch {
                // FileDescriptor.read only throws Errno
                let _errno = error as! Errno
                guard self.shouldWaitForNextSignal(with: _errno.rawValue) else {
                    // Throw all other errors.
                    self.removeRegistration(for: fileDescriptor)
                    throw SubprocessError.failedToReadFromProcess(
                        withUnderlyingError: _errno
                    )
                }
                // No data available right now. Fall through to await the next signal
            }

            do {
                if try await iterator.next() == nil {
                    // The signal stream finished without delivering more data.
                    // This happens when `cancelAsyncIO` runs because the child
                    // has exited and we want to stop waiting for an EOF that may
                    // never come (the pipe could be held open by an inherited
                    // grandchild). Fall through to a final drain.
                    break readLoop
                }
            } catch {
                self.removeRegistration(for: fileDescriptor)
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

        // Cancellation drain: `cancelAsyncIO` already removed the registration,
        // so try one last non-blocking read to surface bytes that were in the
        // kernel buffer when cancellation arrived.
        let drainedLength = resultBuffer.withUnsafeMutableBytes { bufferPtr -> Int in
            // The descriptor was set to non-blocking in `setNonblocking`, so
            // this `read` returns immediately even if no data is ready.
            do {
                return try fileDescriptor.read(
                    into: bufferPtr,
                    retryOnInterrupt: true
                )
            } catch {
                // EAGAIN, EWOULDBLOCK, or another error: no more data right now.
                return 0
            }
        }
        if drainedLength > 0 {
            resultBuffer.removeLast(resultBuffer.count - drainedLength)
            return resultBuffer
        }
        return nil
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
        // Register the descriptor once. It stays registered for reuse across
        // writes and is detached when stdin is closed, or on error/cancellation.
        let (signalStream, outcome) = self.registerFileDescriptor(
            fileDescriptor,
            processIdentifier: processIdentifier,
            for: .write
        )
        switch outcome {
        case .registered:
            break
        case .alreadyCancelled:
            // The subprocess has exited and its stdin no longer has a reader.
            // Report a zero-length write rather than pushing bytes that nothing will consume.
            return 0
        case .failed(let error):
            throw SubprocessError.failedToWriteToProcess(
                withUnderlyingError: error.underlyingError
            )
        }
        var iterator = signalStream.makeAsyncIterator()

        var writtenLength: Int = 0
        // Each iteration first attempts a non-blocking write and only awaits a
        // writability signal when the pipe is full (`EAGAIN`). The descriptor
        // is registered edge-triggered, so we must never park while the pipe
        // still has space.
        writeLoop: while true {
            do {
                let written = try span.extracting(
                    last: span.byteCount - writtenLength
                ).withUnsafeBytes {
                    return try fileDescriptor.write(
                        $0,
                        retryOnInterrupt: true
                    )
                }
                writtenLength += written
                if writtenLength >= span.byteCount {
                    // Wrote all data. The descriptor stays registered for reuse.
                    return writtenLength
                }
                // Wrote a partial chunk: the pipe is full now. Retry, which
                // either writes more or reports `EAGAIN` and waits below.
                continue writeLoop
            } catch {
                // FileDescriptor.write only throws Errno
                let _errno = error as! Errno
                guard self.shouldWaitForNextSignal(with: _errno.rawValue) else {
                    // Throw all other errors.
                    self.removeRegistration(for: fileDescriptor)
                    throw SubprocessError.failedToWriteToProcess(
                        withUnderlyingError: _errno
                    )
                }
                // The pipe is full right now. Fall through to await the next ready signal.
            }

            do {
                if try await iterator.next() == nil {
                    // The signal stream finished while data remained to write
                    // (typically because `cancelAsyncIO` ran after the child
                    // exited). Return whatever bytes the call already pushed so
                    // the caller observes a partial write rather than misreading
                    // silence as a successful zero-byte write.
                    return writtenLength
                }
            } catch {
                self.removeRegistration(for: fileDescriptor)
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

    /// The result of a single attempt to register a file descriptor.
    enum RegisterResult {
        /// The first time this descriptor was seen.
        ///
        /// The caller must still
        /// attach it to the epoll / kqueue (`epoll_ctl(ADD)` / `kevent(EV_ADD)`).
        case registered
        /// The descriptor was already attached by a previous read or write;
        /// the existing attachment is reused and only the continuation is
        /// replaced, so the caller skips the registration syscall.
        case updated
        /// The owning process is already cancelled.
        ///
        /// The caller finishes the
        /// supplied continuation immediately and skips the setup.
        case alreadyCancelled
    }

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
    /// - Returns: A ``RegisterResult`` describing what the caller must do next.
    ///   When the result is ``RegisterResult/registered``, the caller attaches
    ///   the descriptor to the multiplexer; for ``RegisterResult/updated``, the
    ///   attachment already exists and is reused. For
    ///   ``RegisterResult/alreadyCancelled``, the caller finishes the supplied
    ///   continuation immediately and performs no further setup.
    mutating func register(
        fileDescriptor: PlatformFileDescriptor,
        continuation: SignalStream.Continuation,
        processIdentifier: ProcessIdentifier
    ) -> RegisterResult {
        if self.cancelledProcesses.contains(processIdentifier) {
            return .alreadyCancelled
        }

        if let existing = self.fileDescriptorMap.updateValue(
            (continuation, processIdentifier),
            forKey: fileDescriptor
        ) {
            // The descriptor is already attached to the multiplexer. Finish the
            // previous continuation so any stale awaiter unblocks, then replace
            // it and reuse the existing attachment.
            existing.continuation.finish()
            return .updated
        }

        self.processIdentifierMap[processIdentifier, default: Set()].insert(fileDescriptor)

        return .registered
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
    /// for that process return `.alreadyCancelled` until `remove(processIdentifier:)`
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
    /// was rejected.
    ///
    /// The caller finishes the continuation without further
    /// setup.
    case alreadyCancelled
    /// The platform syscall (such as `epoll_ctl` or `kevent`) reported an error.
    ///
    /// The caller finishes the continuation by throwing this error.
    case failed(SubprocessError)
}

extension Array: AsyncIO._ContiguousBytes where Element == UInt8 {}

#endif
