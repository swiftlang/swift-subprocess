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

final class AsyncIO: Sendable {
    static let shared: AsyncIO = AsyncIO()

    internal init() {}

    internal func shutdown() { /* noop on Darwin */  }

    internal func read(
        from diskIO: borrowing IOChannel,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> DispatchData? {
        if maxLength == .max {
            return try await self.readAll(from: diskIO, upTo: maxLength)
        }
        return try await self.readChunk(
            fd: diskIO.channel.rawValue,
            maxLength: maxLength,
        )
    }

    internal func read(
        from fileDescriptor: FileDescriptor,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> DispatchData? {
        if maxLength == .max {
            return try await self.readAll(
                fd: fileDescriptor.rawValue,
                upTo: maxLength
            )
        }
        return try await self.readChunk(
            fd: fileDescriptor.rawValue,
            maxLength: maxLength,
        )
    }

    internal func readAll(
        from diskIO: borrowing IOChannel,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> DispatchData? {
        return try await self.readAll(
            fd: diskIO.channel.rawValue,
            upTo: maxLength
        )
    }

    private func readAll(
        fd: Int32,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> DispatchData? {
        var accumulated: DispatchData = .empty
        while accumulated.count < maxLength {
            if Task.isCancelled {
                throw SubprocessError.asyncIOFailed(
                    reason: "Cancelled",
                    underlyingError: nil
                )
            }
            let remaining = maxLength == .max ? .max : maxLength - accumulated.count
            let chunk: DispatchData? = try await self.readChunk(fd: fd, maxLength: remaining)
            guard let chunk else { break }
            accumulated.append(chunk)
        }
        return accumulated.isEmpty ? nil : accumulated
    }

    private func readChunk(
        fd: Int32,
        maxLength: Int
    ) async throws(SubprocessError) -> DispatchData? {
        // https://github.com/swiftlang/swift/issues/87810
        return try await _castError {
            return try await withCheckedThrowingContinuation { continuation in
                DispatchIO.read(
                    fromFileDescriptor: fd,
                    maxLength: maxLength,
                    runningHandlerOn: .global()
                ) { data, error in
                    if error != 0 {
                        continuation.resume(
                            throwing: SubprocessError.failedToReadFromProcess(
                                withUnderlyingError: Errno(rawValue: error)
                            ))
                        return
                    }
                    continuation.resume(returning: data.isEmpty ? nil : data)
                }
            }
        }
    }

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
        let fd = diskIO.channel.rawValue
        var totalWritten = 0
        func writeRemaining(_ data: DispatchData) {
            DispatchIO.write(
                toFileDescriptor: fd,
                data: data,
                runningHandlerOn: queue
            ) { unwritten, error in
                let unwrittenLength = unwritten?.count ?? 0
                totalWritten += data.count - unwrittenLength
                if error != 0 {
                    completion(
                        totalWritten,
                        .failedToWriteToProcess(withUnderlyingError: Errno(rawValue: error))
                    )
                    return
                }
                if let unwritten, !unwritten.isEmpty {
                    writeRemaining(unwritten)
                } else {
                    completion(totalWritten, nil)
                }
            }
        }
        writeRemaining(dispatchData)
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
