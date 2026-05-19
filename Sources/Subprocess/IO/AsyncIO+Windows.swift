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
                underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
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
                                underlyingError: SubprocessError.WindowsError(rawValue: lastError)
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
    ) -> SignalStream {
        return SignalStream { (continuation: SignalStream.Continuation) in
            switch self.ioCompletionPort {
            case .success(let ioPort):
                // Make sure thread setup also succeeded.
                if case .failure(let error) = monitorThread {
                    continuation.finish(throwing: error)
                    return
                }
                let completionKey = UInt64(UInt(bitPattern: handle))

                // Hold the lock across both the map insert and
                // `CreateIoCompletionPort` so a concurrent `cancelAsyncIO`
                // cannot mark the process cancelled between the two steps
                // and leave behind a HANDLE that's bound to the IOCP but
                // missing the cancellation marker.
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
                        // The handle was already attached to the IOCP by a
                        // previous read or write; the new continuation
                        // replaces the previous one in the map.
                        return .registered
                    case .registered:
                        // Per the Windows documentation, the function
                        // returns the handle of the existing I/O completion
                        // port on success.
                        guard
                            CreateIoCompletionPort(
                                handle, ioPort, completionKey, 0
                            ) == ioPort
                        else {
                            let capturedError = GetLastError()
                            // Roll back the registration so a future
                            // attempt (such as the next read on this
                            // handle) gets a clean slate rather than
                            // seeing a stale entry.
                            _ = storage.removeRegistration(for: completionKey)
                            let error: SubprocessError = .asyncIOFailed(
                                reason: "CreateIoCompletionPort failed",
                                underlyingError: SubprocessError.WindowsError(rawValue: capturedError)
                            )
                            return .failed(error)
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
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
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

        var resultBuffer: [UInt8] = Array(
            repeating: 0, count: bufferLength
        )
        var signalStream = self.registerHandle(
            handle,
            processIdentifier: processIdentifier
        ).makeAsyncIterator()

        // Use an empty `_OVERLAPPED()` here because `ReadFile` below only
        // reads non-seekable files (pipes).
        var overlapped = _OVERLAPPED()
        let succeed = resultBuffer.withUnsafeMutableBufferPointer { bufferPointer in
            // Get a pointer to the memory at the specified offset.
            // Windows `ReadFile` uses `DWORD` for target count, which means
            // the call can read at most `DWORD.max` (`UInt32.max`) bytes.
            let targetCount: DWORD = self.calculateRemainingCount(
                totalCount: bufferPointer.count,
                readCount: 0
            )

            // Read directly into the buffer at the offset.
            return ReadFile(
                handle,
                bufferPointer.baseAddress!,
                targetCount,
                nil,
                &overlapped
            )
        }

        if !succeed {
            // `ReadFile` is expected to return `false` in async mode.
            // Confirm the call returned `ERROR_IO_PENDING` or
            // `ERROR_BROKEN_PIPE`.
            let lastError = GetLastError()
            if lastError == ERROR_BROKEN_PIPE {
                // Reached end of file before any data was read.
                return nil
            }
            guard lastError == ERROR_IO_PENDING else {
                let error: SubprocessError = .failedToReadFromProcess(
                    withUnderlyingError: SubprocessError.WindowsError(rawValue: lastError)
                )
                throw error
            }

        }
        // Wait for the read to finish.
        let bytesRead: DWORD
        do {
            guard let next = try await signalStream.next() else {
                // The signal stream finished without delivering data. This
                // happens when `cancelAsyncIO` ran (typically because the
                // child exited) and the IOCP delivered an
                // `ERROR_OPERATION_ABORTED` completion. By the time the
                // monitor thread finishes the stream, the kernel has
                // released its references to `resultBuffer` and
                // `overlapped`, so it's safe to return.
                return nil
            }
            bytesRead = next
        } catch {
            if let subprocessError = error as? SubprocessError {
                throw subprocessError
            }
            throw SubprocessError.failedToReadFromProcess(
                withUnderlyingError: error as? SubprocessError.UnderlyingError
            )
        }

        if bytesRead == 0 {
            // End of file.
            return nil
        }

        // Got data — return immediately so the caller can process it
        // without waiting for the buffer to fill.
        resultBuffer.removeLast(resultBuffer.count - Int(truncatingIfNeeded: bytesRead))
        return resultBuffer
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
        var signalStream = self.registerHandle(
            handle,
            processIdentifier: processIdentifier
        ).makeAsyncIterator()
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
                        withUnderlyingError: SubprocessError.WindowsError(rawValue: lastError)
                    )
                    throw error
                }

            }
            // Wait for the write to finish.
            let bytesWritten: DWORD

            do {
                guard let next = try await signalStream.next() else {
                    // The signal stream finished while data remained to
                    // write — typically because `cancelAsyncIO` ran after
                    // the child exited. Return whatever bytes the call
                    // already pushed so the caller observes a partial
                    // write rather than misreading silence as a successful
                    // zero-byte write.
                    return writtenLength
                }
                bytesWritten = next
            } catch {
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
