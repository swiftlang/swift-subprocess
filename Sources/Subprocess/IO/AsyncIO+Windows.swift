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

/// Windows AsyncIO implementation based on I/O completion ports and overlapped I/O.

#if os(Windows)

#if canImport(System)
import System
#else
import SystemPackage
#endif

import _SubprocessCShims
import Synchronization
@preconcurrency import WinSDK

private typealias SignalStream = AsyncThrowingStream<DWORD, any Error>
private let shutdownPort: UInt64 = .max
private let _registration: Mutex<Registration> = Mutex(Registration())

final class AsyncIO: @unchecked Sendable {

    protocol _ContiguousBytes: Sendable {
        var count: Int { get }

        func withUnsafeBytes<ResultType>(
            _ body: (
                UnsafeRawBufferPointer
            ) throws -> ResultType
        ) rethrows -> ResultType
    }

    private struct MonitorThreadContext: @unchecked Sendable {
        let ioCompletionPort: HANDLE

        init(ioCompletionPort: HANDLE) {
            self.ioCompletionPort = ioCompletionPort
        }
    }

    static let shared = AsyncIO()

    private let ioCompletionPort: Result<HANDLE, SubprocessError>
    private let monitorThread: Result<HANDLE, SubprocessError>
    private let shutdownFlag: Atomic<UInt8> = Atomic(0)

    internal init() {
        // Create the completion port
        guard
            let ioCompletionPort = CreateIoCompletionPort(
                INVALID_HANDLE_VALUE, nil, 0, 0
            ), ioCompletionPort != INVALID_HANDLE_VALUE
        else {
            let error: SubprocessError = .asyncIOFailed(
                reason: "CreateIoCompletionPort failed",
                underlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
            )
            self.ioCompletionPort = .failure(error)
            self.monitorThread = .failure(error)
            return
        }
        self.ioCompletionPort = .success(ioCompletionPort)
        // Create monitor thread
        let context = MonitorThreadContext(ioCompletionPort: ioCompletionPort)
        let threadHandle: HANDLE
        do {
            threadHandle = try begin_thread_x {
                func reportError(_ error: SubprocessError) {
                    let continuations = _registration.withLock { store in
                        return store.allContinuations()
                    }
                    for continuation in continuations {
                        continuation.finish(throwing: error)
                    }
                }

                // Monitor loop.
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
                        // `ERROR_BROKEN_PIPE`: end of file.
                        // `ERROR_OPERATION_ABORTED`: the I/O was cancelled by
                        // `CancelIoEx`, typically because `cancelAsyncIO` ran
                        // when the child exited. In both cases finish the
                        // per-handle stream so the awaiting read or write
                        // returns to its caller. Leave the registration in
                        // `store` because Windows can't remove a HANDLE from
                        // the IOCP, so the entry doubles as a marker that the
                        // handle is registered until it's closed.
                        if lastError == ERROR_BROKEN_PIPE || lastError == ERROR_OPERATION_ABORTED {
                            let continuation = _registration.withLock { store -> SignalStream.Continuation? in
                                return store.continuation(for: targetFileDescriptor)
                            }
                            continuation?.finish()
                            continue
                        } else {
                            let error: SubprocessError = .asyncIOFailed(
                                reason: "GetQueuedCompletionStatus failed",
                                underlyingError: SubprocessError.WindowsError(win32Error: lastError)
                            )
                            reportError(error)
                            break
                        }
                    }

                    // Break out of the monitor loop on a shutdown signal.
                    if targetFileDescriptor == shutdownPort {
                        break
                    }
                    // Notify the continuation.
                    let continuation = _registration.withLock { store -> SignalStream.Continuation? in
                        return store.continuation(for: targetFileDescriptor)
                    }
                    continuation?.yield(bytesTransferred)
                }

                return 0
            }
        } catch let underlyingError {
            let error: SubprocessError = .asyncIOFailed(
                reason: "Failed to create monitor thread",
                underlyingError: underlyingError
            )
            self.monitorThread = .failure(error)
            return
        }
        self.monitorThread = .success(threadHandle)

        atexit {
            AsyncIO.shared.shutdown()
        }
    }

    internal func shutdown() {
        guard case .success(let ioPort) = ioCompletionPort,
            case .success(let monitorThreadHandle) = monitorThread
        else {
            return
        }
        // Don't shut down the same instance twice.
        guard self.shutdownFlag.add(1, ordering: .relaxed).newValue == 1 else {
            return
        }
        // Post a status to the shutdown HANDLE.
        // swift-format-ignore
        PostQueuedCompletionStatus(
            ioPort,       // CompletionPort
            0,            // Number of bytes transferred.
            shutdownPort, // Completion key to post status
            nil           // Overlapped
        )
        // Wait for the monitor thread to exit.
        WaitForSingleObject(monitorThreadHandle, INFINITE)
        CloseHandle(ioPort)
        CloseHandle(monitorThreadHandle)
    }

    private func registerHandle(
        _ handle: HANDLE,
        processIdentifier: ProcessIdentifier
    ) -> (stream: SignalStream, outcome: RegistrationOutcome) {
        let (stream, continuation) = SignalStream.makeStream()

        let ioPort: HANDLE
        switch self.ioCompletionPort {
        case .success(let port):
            ioPort = port
        case .failure(let error):
            continuation.finish(throwing: error)
            return (stream, .failed(error))
        }
        // Make sure thread setup also succeeded.
        if case .failure(let error) = self.monitorThread {
            continuation.finish(throwing: error)
            return (stream, .failed(error))
        }

        let completionKey = UInt64(UInt(bitPattern: handle))

        // Hold the lock across both the map insert and `CreateIoCompletionPort`
        // so a concurrent `cancelAsyncIO` cannot mark the process cancelled
        // between the two steps and leave behind a HANDLE that's bound to the
        // IOCP but missing the cancellation marker.
        let outcome: RegistrationOutcome = _registration.withLock { storage in
            let result = storage.register(
                completionKey: completionKey,
                continuation: continuation,
                processIdentifier: processIdentifier
            )
            switch result {
            case .alreadyCancelled:
                return .alreadyCancelled
            case .updated:
                // The handle was already attached to the IOCP by a previous
                // read or write; the new continuation replaces the previous
                // one in the map.
                return .registered
            case .registered:
                // Per the Windows documentation, the function returns the
                // handle of the existing I/O completion port on success.
                guard
                    CreateIoCompletionPort(
                        handle, ioPort, completionKey, 0
                    ) == ioPort
                else {
                    let capturedError = GetLastError()
                    // Roll back the registration so a future attempt (such as
                    // the next read on this handle) gets a clean slate rather
                    // than seeing a stale entry.
                    _ = storage.removeRegistration(for: completionKey)
                    return .failed(
                        .asyncIOFailed(
                            reason: "CreateIoCompletionPort failed",
                            underlyingError: SubprocessError.WindowsError(win32Error: capturedError)
                        ))
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

    private enum OverlappedReadOutcome {
        /// The read placed `count` bytes at the front of the buffer.
        case read(Int)
        /// The signal stream finished before delivering data: EOF, a broken
        /// pipe, or an operation aborted by cancellation.
        case finished
    }

    /// Issues a single overlapped `ReadFile` on `handle` and awaits its
    /// completion through `stream`. The caller must already hold a
    /// `.registered` outcome for `handle`.
    private func issueAndAwaitRead(
        on handle: HANDLE,
        stream: SignalStream,
        into resultBuffer: inout [UInt8]
    ) async throws(SubprocessError) -> OverlappedReadOutcome {
        var iterator = stream.makeAsyncIterator()

        // Empty `_OVERLAPPED()` because `ReadFile` only reads pipes here.
        var overlapped = _OVERLAPPED()
        let succeed = resultBuffer.withUnsafeMutableBufferPointer { bufferPointer in
            let targetCount: DWORD = self.calculateRemainingCount(
                totalCount: bufferPointer.count,
                readCount: 0
            )
            return ReadFile(handle, bufferPointer.baseAddress!, targetCount, nil, &overlapped)
        }

        if !succeed {
            let lastError = GetLastError()
            if lastError == ERROR_BROKEN_PIPE {
                return .finished
            }
            guard lastError == ERROR_IO_PENDING else {
                throw SubprocessError.failedToReadFromProcess(
                    withUnderlyingError: SubprocessError.WindowsError(win32Error: lastError)
                )
            }
        }

        let bytesRead: DWORD
        do {
            guard let next = try await iterator.next() else {
                // `next()` resolved to `nil` because `group.cancelAll()` on
                // subprocess termination cancelled the read, not because it
                // failed. A `ReadFile` issued above may have already completed,
                // with its bytes sitting in `resultBuffer`. Those bytes have been
                // pulled out of the pipe, so the post-cancellation drain cannot
                // recover them: dropping them here loses exactly one buffer.
                //
                // Settle the operation and surface any recovered bytes. On a
                // byte-mode pipe, a cancelled pending read almost always
                // reports zero, so the `.read` arm fires only when bytes land
                // in the narrow window between issue and cancel.
                let transferred = self.settlePendingOverlapped(
                    handle: handle,
                    overlapped: &overlapped
                )
                return transferred > 0
                    ? .read(Int(truncatingIfNeeded: transferred))
                    : .finished
            }
            bytesRead = next
        } catch {
            // The signal stream threw, which happens only when the IOCP
            // monitor hits a fatal `GetQueuedCompletionStatus` error and
            // finishes every continuation. A `ReadFile` issued above may still
            // be pending against `resultBuffer`; settle it before the buffer
            // goes out of scope. Recovered bytes are discarded: this path
            // rethrows the monitor's failure and returns no output, so nothing
            // would consume them.
            self.settlePendingOverlapped(handle: handle, overlapped: &overlapped)
            if let subprocessError = error as? SubprocessError {
                throw subprocessError
            }
            throw SubprocessError.failedToReadFromProcess(
                withUnderlyingError: error as? SubprocessError.UnderlyingError
            )
        }

        if bytesRead == 0 {
            return .finished
        }
        return .read(Int(truncatingIfNeeded: bytesRead))
    }

    /// Drives an overlapped operation to a terminal state and reports the
    /// bytes it transferred.
    ///
    /// This is called when the signal stream stops delivering this operation's
    /// completion, either because `group.cancelAll()` on child termination
    /// cancelled the awaiting task, or because the IOCP monitor finished every
    /// continuation while reporting a fatal error. The `ReadFile`/`WriteFile`
    /// being reconciled is then in one of three states:
    ///
    /// - Already completed: `GetOverlappedResult` reports the outcome
    ///   immediately, and the returned count reflects what it transferred.
    /// - Still pending: the kernel is mid-operation against the caller's buffer
    ///   and `overlapped`. Returning now would let both go out of scope while
    ///   the kernel still holds them (use-after-free), so this cancels the
    ///   specific operation and blocks until it has fully unwound.
    /// - Any other terminal status: the operation is already done and nothing
    ///   was recovered, so the returned count is zero.
    ///
    /// The blocking wait uses a `NULL` `hEvent`, so `GetOverlappedResult` falls
    /// back to signaling on `handle` itself. Microsoft discourages that only
    /// because a handle carrying several concurrent overlapped operations can't
    /// disambiguate which one completed. These handles never do that: stdout
    /// and stderr are read-only, and their reads are strictly sequential (the
    /// capture loop awaits each read before issuing the next); stdin is
    /// write-only, and its writes are serialized by `StandardInputWriter`. At
    /// most one operation is ever in flight per handle, and
    /// `ReadFile`/`WriteFile` reset the handle to nonsignaled at issue, so no
    /// earlier operation's signal can satisfy this wait early.
    ///
    /// The handle's own signal driving the wait keeps this correct when the
    /// trigger is monitor death rather than cancellation. A fatal
    /// `GetQueuedCompletionStatus` failure breaks the monitor loop and drives
    /// the `reportError` that finishes this operation's continuation, so the
    /// monitor is gone by the time this runs. The kernel still sets the file
    /// handle's signal on completion independently of any IOCP dequeue, so the
    /// wait resolves without it; the completion port stays open (only
    /// `shutdown()` closes it), so when the operation is still pending the
    /// packet the abort enqueues is never dequeued, producing a one-packet
    /// leak on an already-failed subsystem.
    ///
    /// - Important: `overlapped` must reference the same storage passed to the
    ///   originating `ReadFile`/`WriteFile`, and the buffer from which that
    ///   call read or wrote into must remain alive until this returns. On the
    ///   pending path this blocks until the cancelled operation has fully
    ///   unwound, guaranteeing the kernel is done with both before they're freed.
    /// - Returns: The bytes the operation transferred, as confirmed through
    ///   `GetOverlappedResult`. Callers that recover data (the read path)
    ///   surface this count; lifetime-only callers (the write path) discard it.
    @discardableResult
    private func settlePendingOverlapped(
        handle: HANDLE,
        overlapped: inout _OVERLAPPED
    ) -> DWORD {
        var transferred: DWORD = 0
        if GetOverlappedResult(handle, &overlapped, &transferred, false) {
            return transferred
        }
        guard GetLastError() == ERROR_IO_INCOMPLETE else {
            return 0
        }
        _ = CancelIoEx(handle, &overlapped)
        if GetOverlappedResult(handle, &overlapped, &transferred, true) {
            return transferred
        }
        return 0
    }

    /// Reads bytes already buffered in the pipe after the owning process has
    /// been cancelled, without routing through the completion port.
    ///
    /// Bytes the subprocess already wrote remain in the pipe and must not be
    /// dropped, but a fresh read awaited through the monitor could hang: a
    /// surviving launched process can hold the write end open, so EOF may never
    /// arrive. `PeekNamedPipe` neither consumes data nor blocks, so it gates
    /// the read; `ReadFile` is issued only when bytes are present, which
    /// then completes promptly.
    ///
    /// The read is overlapped (the handle is `FILE_FLAG_OVERLAPPED`), so it's
    /// synchronized on a private event rather than the completion port. The low
    /// bit of `OVERLAPPED.hEvent` is set so that, on a handle a prior read
    /// already bound to the port, this completion is not enqueued there for the
    /// monitor to pick up against an `OVERLAPPED` this call has freed. The wait
    /// is bounded since `PeekNamedPipe` has already confirmed the bytes are
    /// present.
    ///
    /// Returns the drained bytes, or `nil` once the buffer is empty or the pipe
    /// has reached EOF. The caller drives repeated calls to drain successive
    /// chunks.
    private func drainBufferedDataAfterCancellation(
        from handle: HANDLE,
        capacity: Int
    ) throws(SubprocessError) -> [UInt8]? {
        func readFailed(_ error: DWORD) -> SubprocessError {
            .failedToReadFromProcess(
                withUnderlyingError: SubprocessError.WindowsError(win32Error: error)
            )
        }

        var bytesAvailable: DWORD = 0
        guard PeekNamedPipe(handle, nil, 0, nil, &bytesAvailable, nil) else {
            let lastError = GetLastError()
            // Empty pipe, write end closed: EOF, nothing left to drain.
            if lastError == ERROR_BROKEN_PIPE { return nil }
            throw readFailed(lastError)
        }
        guard bytesAvailable > 0 else {
            // Buffer empty. Don't issue a read: with the process cancelled,
            // nothing guarantees the write end ever closes, so a pending read
            // could hang indefinitely.
            return nil
        }

        // The `OVERLAPPED` gets a copy with the low bit set to keep the
        // completion off the IOCP.
        guard let event = CreateEventW(nil, true, false, nil) else {
            throw readFailed(GetLastError())
        }
        defer { CloseHandle(event) }

        var resultBuffer = [UInt8](repeating: 0, count: capacity)
        var overlapped = _OVERLAPPED()
        overlapped.hEvent = HANDLE(bitPattern: UInt(bitPattern: event) | 1)

        let started = resultBuffer.withUnsafeMutableBufferPointer { bufferPointer in
            let targetCount = self.calculateRemainingCount(
                totalCount: bufferPointer.count,
                readCount: 0
            )
            return ReadFile(handle, bufferPointer.baseAddress!, targetCount, nil, &overlapped)
        }
        if !started {
            let lastError = GetLastError()
            if lastError == ERROR_BROKEN_PIPE { return nil }
            guard lastError == ERROR_IO_PENDING else {
                throw readFailed(lastError)
            }
            // `PeekNamedPipe` already saw the bytes, so this returns promptly.
            WaitForSingleObject(event, INFINITE)
        }

        var bytesRead: DWORD = 0
        guard GetOverlappedResult(handle, &overlapped, &bytesRead, false) else {
            let lastError = GetLastError()
            if lastError == ERROR_BROKEN_PIPE { return nil }
            throw readFailed(lastError)
        }
        guard bytesRead > 0 else { return nil }
        resultBuffer.removeLast(resultBuffer.count - Int(truncatingIfNeeded: bytesRead))
        return resultBuffer
    }

    internal func removeRegistration(for handle: HANDLE) {
        let completionKey = UInt64(UInt(bitPattern: handle))
        _registration.withLock { storage in
            _ = storage.removeRegistration(for: completionKey)
        }
    }

    internal func cancelAsyncIO(for processIdentifier: ProcessIdentifier) throws(SubprocessError) {
        try _registration.withLock { storage throws(SubprocessError) in
            let completionKeys = storage.cancel(processIdentifier: processIdentifier)

            for key in completionKeys {
                guard let handle = HANDLE(bitPattern: UInt(truncatingIfNeeded: key)) else {
                    continue
                }
                // `CancelIoEx` with a `NULL` overlapped cancels every pending
                // I/O on the handle.
                let result = CancelIoEx(handle, nil)
                // ERROR_NOT_FOUND with lpOverlapped == nil specifically means:
                // the handle is valid, but at the moment of the call there are no
                // cancellable pending I/O requests on it issued by the current process.
                // This is most likely due to all pending IOs have finished. Treat
                // `ERROR_NOT_FOUND` as success, which is sementatically correct:
                // nothing to cancel is successfully cancelled.
                if !result && GetLastError() != ERROR_NOT_FOUND {
                    throw SubprocessError.asyncIOFailed(reason: "Failed to cancel AsyncIO for \(handle)")
                }
            }
        }
    }

    internal func cleanup(processIdentifier: ProcessIdentifier) {
        _registration.withLock { storage in
            storage.remove(processIdentifier: processIdentifier)
        }
    }

    func read(
        from diskIO: borrowing IODescriptor,
        for processIdentifier: ProcessIdentifier,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> [UInt8]? {
        return try await self.read(
            from: diskIO.descriptor(),
            for: processIdentifier,
            upTo: maxLength
        )
    }

    func read(
        from handle: HANDLE,
        for processIdentifier: ProcessIdentifier,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> [UInt8]? {
        guard maxLength > 0 else {
            return nil
        }
        let bufferLength: Int
        if maxLength == .max {
            // Prevent OOM allocation
            bufferLength = Self.queryPipeBufferSize(for: handle)
        } else {
            bufferLength = maxLength
        }

        let (stream, outcome) = self.registerHandle(
            handle,
            processIdentifier: processIdentifier
        )

        switch outcome {
        case .registered:
            break
        case .failed(let error):
            throw SubprocessError.failedToReadFromProcess(
                withUnderlyingError: error.underlyingError
            )
        case .alreadyCancelled:
            // Cancelled before this read began. Surface buffered bytes rather
            // than reporting an empty stream.
            return try self.drainBufferedDataAfterCancellation(
                from: handle, capacity: bufferLength
            )
        }

        var resultBuffer = [UInt8](repeating: 0, count: bufferLength)
        switch try await self.issueAndAwaitRead(
            on: handle,
            stream: stream,
            into: &resultBuffer
        ) {
        case .read(let count):
            resultBuffer.removeLast(resultBuffer.count - count)
            return resultBuffer
        case .finished:
            // EOF, or the read was aborted in flight. If a write landed in the
            // buffer with no read pending to receive it, drain it now.
            return try self.drainBufferedDataAfterCancellation(
                from: handle, capacity: bufferLength
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
        let handle = diskIO.descriptor()
        let (stream, outcome) = self.registerHandle(handle, processIdentifier: processIdentifier)
        var signalStream = stream.makeAsyncIterator()

        switch outcome {
        case .registered:
            break
        case .failed(let error):
            throw SubprocessError.failedToWriteToProcess(withUnderlyingError: error.underlyingError)
        case .alreadyCancelled:
            // The subprocess has exited; its stdin no longer has a reader.
            // Report a zero-length write instead of issuing a fire-and-forget
            // `WriteFile` whose completion nothing would await.
            return 0
        }

        var writtenLength: Int = 0
        while true {
            // Use an empty `_OVERLAPPED()` here because `WriteFile` below
            // only writes to non-seekable files (pipes).
            var overlapped = _OVERLAPPED()
            let succeed = span.withUnsafeBytes { ptr in
                // Windows `WriteFile` uses `DWORD` for target count, which
                // means the call can write at most `DWORD.max` bytes.
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
                // `WriteFile` is expected to return `false` in async mode.
                // Confirm the call returned `ERROR_IO_PENDING`.
                let lastError = GetLastError()
                guard lastError == ERROR_IO_PENDING else {
                    let error: SubprocessError = .failedToWriteToProcess(
                        withUnderlyingError: SubprocessError.WindowsError(win32Error: lastError)
                    )
                    throw error
                }

            }
            // Wait for the write to finish.
            let bytesWritten: DWORD

            do {
                guard let next = try await signalStream.next() else {
                    // `next()` resolved to `nil` because the owning task was
                    // cancelled on subprocess termination, not because the
                    // write failed. A `WriteFile` issued above may still be
                    // pending, with the kernel reading from `span`'s storage
                    // and poised to write into `overlapped`; both release once
                    // this call returns and the borrow on `span` ends.
                    //
                    // Settle it first so neither is freed while the kernel is
                    // still using it, then return the bytes confirmed through
                    // the completion port. Bytes the settlement observes as
                    // transferred are intentionally not folded in; the pipe's
                    // only reader (the subprocess) has terminated, so nothing
                    // will consume them.
                    self.settlePendingOverlapped(
                        handle: handle,
                        overlapped: &overlapped
                    )
                    return writtenLength
                }
                bytesWritten = next
            } catch {
                // The signal stream threw, which happens only when the IOCP
                // monitor hits a fatal `GetQueuedCompletionStatus` error and
                // finishes every continuation. A `WriteFile` issued above may
                // still be pending against `span`'s storage and `overlapped`;
                // settle it before the borrow is released.
                self.settlePendingOverlapped(handle: handle, overlapped: &overlapped)
                if let subprocessError = error as? SubprocessError {
                    throw subprocessError
                }
                throw SubprocessError.failedToWriteToProcess(
                    withUnderlyingError: error as? SubprocessError.UnderlyingError
                )
            }

            writtenLength += Int(truncatingIfNeeded: bytesWritten)
            if writtenLength >= span.byteCount {
                return writtenLength
            }
        }
    }

    // Windows `ReadFile` uses `DWORD` for target count, which means the
    // call can read at most `DWORD.max` (`UInt32.max`) bytes.
    private func calculateRemainingCount(totalCount: Int, readCount: Int) -> DWORD {
        // Subprocess supports both 32-bit and 64-bit Windows.
        if MemoryLayout<Int>.size == MemoryLayout<Int32>.size {
            // 32-bit systems can't overflow the count.
            return DWORD(truncatingIfNeeded: totalCount - readCount)
        } else {
            // On 64-bit systems, cap the count at `DWORD.max`.
            return DWORD(truncatingIfNeeded: min(totalCount - readCount, Int(DWORD.max)))
        }
    }

    static func queryPipeBufferSize(for fileDescriptor: IODescriptor.Descriptor) -> Int {
        // Windows does not provide an API to query pipe buffer size.
        // Node's `getDefaultHighWaterMark` uses 16 KB.
        return 16 * 1024
    }
}

extension Array: AsyncIO._ContiguousBytes where Element == UInt8 {}

/// A bookkeeping structure that maps IOCP completion keys to their pending
/// I/O continuations and groups those keys by the process that owns them.
///
/// `AsyncIO+Windows` uses this type to find the continuation for a handle
/// when the IOCP reports a completion, and to identify which handles
/// belong to a process when the process exits and the I/O for it must be
/// cancelled with `CancelIoEx`.
private struct Registration {
    typealias CompletionKey = UInt64
    typealias Record = (continuation: SignalStream.Continuation, processIdentifier: ProcessIdentifier)

    private var handleMap: [CompletionKey: Record]
    private var processIdentifierMap: [ProcessIdentifier: Set<CompletionKey>]

    /// The set of processes whose I/O has already been cancelled.
    ///
    /// `register` consults this set and rejects new registrations for any
    /// process that appears in it. This prevents a registration that
    /// races with `cancel` from establishing a stream that nothing will
    /// ever cancel.
    private var cancelledProcesses: Set<ProcessIdentifier>

    init() {
        self.handleMap = [:]
        self.processIdentifierMap = [:]
        self.cancelledProcesses = Set()
    }

    /// The result of a single attempt to register a handle.
    enum RegisterResult {
        /// The first time this completion key was seen. The caller still
        /// needs to attach the handle to the IOCP via
        /// `CreateIoCompletionPort`.
        case registered
        /// The completion key was already present. Windows can't
        /// unregister from an IOCP, so the existing attachment is reused
        /// and only the continuation is updated.
        case updated
        /// The owning process is already cancelled. The caller finishes
        /// the supplied continuation immediately and skips the IOCP
        /// setup.
        case alreadyCancelled
    }

    /// Records a completion key as part of a process's pending I/O.
    ///
    /// - Parameters:
    ///   - completionKey: The IOCP completion key to track.
    ///   - continuation: The continuation to resume when the IOCP reports
    ///     a completion or the I/O is cancelled.
    ///   - processIdentifier: The process that owns the handle.
    /// - Returns: A `RegisterResult` describing what the caller must do
    ///   next.
    mutating func register(
        completionKey: CompletionKey,
        continuation: SignalStream.Continuation,
        processIdentifier: ProcessIdentifier
    ) -> RegisterResult {
        if self.cancelledProcesses.contains(processIdentifier) {
            return .alreadyCancelled
        }

        var isNew = true
        if let oldRecord = self.handleMap.removeValue(forKey: completionKey) {
            oldRecord.continuation.finish()
            isNew = false
        }

        self.handleMap[completionKey] = (continuation, processIdentifier)
        if isNew {
            var set = self.processIdentifierMap[processIdentifier] ?? Set()
            set.insert(completionKey)
            self.processIdentifierMap[processIdentifier] = set
        }
        return isNew ? .registered : .updated
    }

    /// Removes the registration for `completionKey`.
    ///
    /// - Parameter completionKey: The completion key whose registration
    ///   to drop.
    /// - Returns: The continuation associated with the key, or `nil` if
    ///   no registration exists.
    mutating func removeRegistration(
        for completionKey: CompletionKey
    ) -> SignalStream.Continuation? {
        guard let record = self.handleMap.removeValue(forKey: completionKey) else {
            return nil
        }
        if var set = self.processIdentifierMap[record.processIdentifier] {
            set.remove(completionKey)
            if set.isEmpty {
                self.processIdentifierMap.removeValue(forKey: record.processIdentifier)
            } else {
                self.processIdentifierMap[record.processIdentifier] = set
            }
        }
        return record.continuation
    }

    /// Marks `processIdentifier` as cancelled and returns the completion
    /// keys whose pending I/O the caller must abort.
    ///
    /// The continuations remain in `handleMap` so the IOCP completion
    /// that follows `CancelIoEx` can be routed back to the right
    /// awaiting task. Entries are removed from `handleMap` later, when
    /// each handle is closed via `_safelyClose`.
    ///
    /// - Parameter processIdentifier: The process whose I/O to cancel.
    /// - Returns: The completion keys to pass to `CancelIoEx`.
    mutating func cancel(processIdentifier: ProcessIdentifier) -> Set<CompletionKey> {
        self.cancelledProcesses.insert(processIdentifier)
        return self.processIdentifierMap.removeValue(forKey: processIdentifier) ?? []
    }

    /// Drops the cancellation marker for `processIdentifier`.
    ///
    /// Call this after the process has fully exited and no further I/O
    /// for it can occur, to keep `cancelledProcesses` from growing
    /// without bound.
    ///
    /// - Parameter processIdentifier: The process to forget.
    mutating func remove(processIdentifier: ProcessIdentifier) {
        self.cancelledProcesses.remove(processIdentifier)
    }

    /// Returns the continuation registered for `completionKey`, or `nil`
    /// if none exists.
    func continuation(for completionKey: CompletionKey) -> SignalStream.Continuation? {
        return self.handleMap[completionKey]?.continuation
    }

    /// Returns every currently registered continuation.
    ///
    /// The monitor thread calls this when it fails and needs to surface
    /// the error to every awaiting reader and writer.
    func allContinuations() -> [SignalStream.Continuation] {
        return self.handleMap.values.map { $0.continuation }
    }
}

/// The result of a single attempt to register a handle with the IOCP.
private enum RegistrationOutcome {
    /// The handle was added successfully.
    case registered
    /// The owning process has already been cancelled, so the registration
    /// was rejected. The caller finishes the continuation without further
    /// setup.
    case alreadyCancelled
    /// `CreateIoCompletionPort` reported an error. The caller finishes
    /// the continuation by throwing this error.
    case failed(SubprocessError)
}

#endif
