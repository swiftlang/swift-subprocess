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

/// Darwin AsyncIO implementation based on DispatchIO

// MARK: - macOS (DispatchIO)
#if SUBPROCESS_ASYNCIO_DISPATCH

#if canImport(System)
import System
#else
import SystemPackage
#endif

internal import Dispatch

/// Accumulates data that arrives from DispatchIO handler calls after the
/// continuation has already been resumed (in latency/returnOnFirstData mode).
/// Shared between successive `read()` calls on the same iterator.
///
/// When `returnOnFirstData` is true, the DispatchIO handler may be called
/// multiple times for a single `read()` operation. After the first chunk
/// resumes the continuation, subsequent chunks are stashed here. A follow-up
/// `read()` call will wait (via `asyncTakeData()`) for either new data to
/// arrive or for the DispatchIO operation to complete.
/// Tracks the state of a DispatchIO read operation that was resumed early
/// due to `returnOnFirstData`. After the continuation returns the first
/// chunk, the DispatchIO handler may still deliver more data for the same
/// `read()` call. This class accumulates that data so subsequent iterator
/// `next()` calls can retrieve it without starting an overlapping read.
final class PendingReadState: @unchecked Sendable {
    private let lock = DispatchQueue(label: "PendingReadState")
    private var _data: DispatchData = .empty
    /// True once DispatchIO calls the handler with `done=true` for the
    /// current read operation (meaning this particular read is finished,
    /// NOT necessarily EOF).
    private var _operationDone: Bool = false
    /// True after `returnOnFirstData` resumes the continuation early,
    /// until the DispatchIO operation completes and pending data is drained.
    private var _draining: Bool = false
    /// Non-nil when a consumer is waiting for data or the done signal.
    private var _waiter: CheckedContinuation<(DispatchData, Bool)?, Never>?

    var isDraining: Bool {
        lock.sync { _draining }
    }

    func beginDraining() {
        lock.sync { _draining = true }
    }

    func append(_ newData: DispatchData) {
        lock.sync {
            if let waiter = _waiter {
                _waiter = nil
                waiter.resume(returning: (newData, false))
            } else {
                if _data.isEmpty {
                    _data = newData
                } else {
                    _data.append(newData)
                }
            }
        }
    }

    /// Signal that the DispatchIO read operation is complete.
    func markOperationDone() {
        lock.sync {
            _operationDone = true
            if let waiter = _waiter {
                _waiter = nil
                if _data.isEmpty {
                    // No more data from this operation; signal the consumer
                    // to start a new read.
                    waiter.resume(returning: nil)
                } else {
                    let result = _data
                    _data = .empty
                    waiter.resume(returning: (result, true))
                }
            }
        }
    }

    func reset() {
        lock.sync {
            _data = .empty
            _operationDone = false
            _draining = false
            _waiter = nil
        }
    }

    /// Waits for either new data from the DispatchIO handler, or for the
    /// operation to complete. Returns `nil` when the operation is done and
    /// no more data is available (caller should issue a new read).
    func asyncTakeData() async -> DispatchData? {
        let result: (DispatchData, Bool)? = await withCheckedContinuation { continuation in
            lock.sync {
                if !_data.isEmpty {
                    let d = _data
                    _data = .empty
                    continuation.resume(returning: (d, _operationDone))
                } else if _operationDone {
                    continuation.resume(returning: nil)
                } else {
                    _waiter = continuation
                }
            }
        }

        guard let (data, operationDone) = result else {
            // Operation done, no more pending data. Stop draining so the
            // next read() starts a fresh DispatchIO read.
            lock.sync { _draining = false }
            return nil
        }

        if operationDone {
            lock.sync { _draining = false }
        }
        return data
    }
}

final class AsyncIO: Sendable {
    static let shared: AsyncIO = AsyncIO()

    internal init() {}

    internal func shutdown() { /* noop on Darwin */  }

    internal func read(
        from diskIO: borrowing IOChannel,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> DispatchData? {
        return try await self.read(
            from: diskIO.channel,
            upTo: maxLength,
        )
    }

    internal func read(
        from dispatchIO: DispatchIO,
        upTo maxLength: Int,
        returnOnFirstData: Bool = false,
        pendingState: PendingReadState? = nil
    ) async throws(SubprocessError) -> DispatchData? {
        // If a prior DispatchIO read is still delivering data (because we
        // returned early on the first chunk), drain from the pending state
        // instead of starting a new overlapping read.
        if let pendingState, pendingState.isDraining {
            if let data = await pendingState.asyncTakeData() {
                return data
            }
            // The previous operation completed with no more pending data.
            // Fall through to start a fresh read.
        }

        pendingState?.reset()

        // https://github.com/swiftlang/swift/issues/87810
        return try await _castError {
            return try await withCheckedThrowingContinuation { continuation in
                var buffer: DispatchData = .empty
                var hasResumed = false

                dispatchIO.read(
                    offset: 0,
                    length: maxLength,
                    queue: DispatchQueue(label: "SubprocessReadQueue")
                ) { done, data, error in
                    if let data, !data.isEmpty {
                        if hasResumed, let pendingState {
                            pendingState.append(data)
                        } else {
                            if buffer.isEmpty {
                                buffer = data
                            } else {
                                buffer.append(data)
                            }
                        }
                    }

                    if done, hasResumed {
                        pendingState?.markOperationDone()
                        return
                    }

                    guard !hasResumed else {
                        return
                    }

                    if error != 0 {
                        hasResumed = true
                        continuation.resume(
                            throwing: SubprocessError
                                .failedToReadFromProcess(
                                    withUnderlyingError: Errno(rawValue: error)
                                )
                        )
                        return
                    }

                    if returnOnFirstData && !buffer.isEmpty {
                        hasResumed = true
                        pendingState?.beginDraining()
                        if done {
                            pendingState?.markOperationDone()
                        }
                        continuation.resume(returning: buffer)
                        return
                    }

                    if done {
                        hasResumed = true
                        if !buffer.isEmpty {
                            continuation.resume(returning: buffer)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }
        }
    }

    #if SubprocessSpan
    internal func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing IOChannel
    ) async throws(SubprocessError) -> Int {
        // https://github.com/swiftlang/swift/issues/87810
        return try await _castError {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
                span.withUnsafeBytes {
                    let dispatchData = DispatchData(
                        bytesNoCopy: $0,
                        deallocator: .custom(
                            nil,
                            {
                                // noop
                            }
                        )
                    )

                    self.write(dispatchData, to: diskIO) { writtenLength, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: writtenLength)
                        }
                    }
                }
            }
        }
    }
    #endif // SubprocessSpan

    internal func write(
        _ array: [UInt8],
        to diskIO: borrowing IOChannel
    ) async throws(SubprocessError) -> Int {
        // https://github.com/swiftlang/swift/issues/87810
        return try await _castError {
            return try await withCheckedThrowingContinuation { continuation in
                array.withUnsafeBytes {
                    let dispatchData = DispatchData(
                        bytesNoCopy: $0,
                        deallocator: .custom(
                            nil,
                            {
                                // noop
                            }
                        )
                    )

                    self.write(dispatchData, to: diskIO) { writtenLength, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: writtenLength)
                        }
                    }
                }
            }
        }
    }

    internal func write(
        _ dispatchData: DispatchData,
        to diskIO: borrowing IOChannel,
        queue: DispatchQueue = .global(),
        completion: @escaping (Int, SubprocessError?) -> Void
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
                .failedToWriteToProcess(withUnderlyingError: Errno(rawValue: error))
            )
        }
    }
}

#if canImport(Darwin)
// Dispatch has a -user-module-version of 54 in the macOS 15.3 SDK
#if canImport(Dispatch, _version: "54")
// DispatchData is annotated as Sendable
#else
// Retroactively conform DispatchData to Sendable
extension DispatchData: @retroactive @unchecked Sendable {}
#endif // canImport(Dispatch, _version: "54")
#else
extension DispatchData: @retroactive @unchecked Sendable {}
#endif // canImport(Darwin)

#endif // SUBPROCESS_ASYNCIO_DISPATCH
