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
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

internal import Dispatch

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
        upTo maxLength: Int
    ) async throws(SubprocessError) -> DispatchData? {
        return try await _castError {
            return try await withCheckedThrowingContinuation { continuation in
                var buffer: DispatchData = .empty
                dispatchIO.read(
                    offset: 0,
                    length: maxLength,
                    queue: DispatchQueue(label: "SubprocessReadQueue")
                ) { done, data, error in
                    if error != 0 {
                        continuation.resume(
                            throwing: SubprocessError(
                                code: .init(.failedToReadFromSubprocess),
                                underlyingError: Errno(rawValue: error)
                            )
                        )
                        return
                    }
                    if let data {
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
    }

    #if SubprocessSpan
    internal func write(
        _ span: borrowing RawSpan,
        to diskIO: borrowing IOChannel
    ) async throws(SubprocessError) -> Int {
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
                SubprocessError(
                    code: .init(.failedToWriteToSubprocess),
                    underlyingError: Errno(rawValue: error)
                )
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
