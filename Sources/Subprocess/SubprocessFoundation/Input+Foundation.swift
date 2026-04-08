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

#if SubprocessFoundation

#if canImport(Darwin)
// On Darwin always prefer system Foundation
import Foundation
#else
// On other platforms prefer FoundationEssentials
import FoundationEssentials
#endif // canImport(Darwin)

#if canImport(System)
import System
#else
import SystemPackage
#endif

internal import Dispatch

/// A concrete input type for subprocesses that reads input from data.
internal struct DataInput: Sendable {
    private let data: Data

    func write(with writer: StandardInputWriter) async throws(SubprocessError) {
        _ = try await writer.write(self.data)
    }

    init(data: Data) {
        self.data = data
    }
}

/// A concrete input type for subprocesses that accepts input from
/// a specified sequence of data.
internal struct DataSequenceInput<
    InputSequence: Sequence & Sendable
>: Sendable where InputSequence.Element == Data {
    private let sequence: InputSequence

    func write(with writer: StandardInputWriter) async throws(SubprocessError) {
        var buffer = Data()
        for chunk in self.sequence {
            buffer.append(chunk)
        }
        _ = try await writer.write(buffer)
    }

    init(underlying: InputSequence) {
        self.sequence = underlying
    }
}

/// A concrete `Input` type for subprocesses that reads input
/// from a given async sequence of `Data`.
internal struct DataAsyncSequenceInput<
    InputSequence: AsyncSequence & Sendable
>: Sendable where InputSequence.Element == Data {
    private let sequence: InputSequence

    private func writeChunk(_ chunk: Data, with writer: StandardInputWriter) async throws(SubprocessError) {
        _ = try await writer.write(chunk)
    }

    func write(with writer: StandardInputWriter) async throws(SubprocessError) {
        do {
            for try await chunk in self.sequence {
                try await self.writeChunk(chunk, with: writer)
            }
        } catch {
            if let subprocessError = error as? SubprocessError {
                throw subprocessError
            }
            throw .failedToWriteToProcess(
                withUnderlyingError: error as? SubprocessError.UnderlyingError
            )
        }
    }

    init(underlying: InputSequence) {
        self.sequence = underlying
    }
}

extension InputMethod {
    /// Create a Subprocess input from a `Data`
    public static func data(_ data: Data) -> InputMethod {
        let inner = DataInput(data: data)
        return InputMethod(
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .input) },
            write: { writer in try await inner.write(with: writer) }
        )
    }

    /// Create a Subprocess input from a `Sequence` of `Data`.
    public static func sequence<InputSequence: Sequence & Sendable>(
        _ sequence: InputSequence
    ) -> InputMethod where InputSequence.Element == Data {
        let inner = DataSequenceInput(underlying: sequence)
        return InputMethod(
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .input) },
            write: { writer in try await inner.write(with: writer) }
        )
    }

    /// Create a Subprocess input from a `AsyncSequence` of `Data`.
    public static func sequence<InputSequence: AsyncSequence & Sendable>(
        _ asyncSequence: InputSequence
    ) -> InputMethod where InputSequence.Element == Data {
        let inner = DataAsyncSequenceInput(underlying: asyncSequence)
        return InputMethod(
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .input) },
            write: { writer in try await inner.write(with: writer) }
        )
    }
}

extension StandardInputWriter {
    /// Write a `Data` to the standard input of the subprocess.
    /// - Parameter data: The sequence of bytes to write.
    /// - Returns number of bytes written.
    public func write(
        _ data: Data
    ) async throws(SubprocessError) -> Int {
        return try await AsyncIO.shared.write(data, to: self.diskIO)
    }

    /// Write a AsyncSequence of Data to the standard input of the subprocess.
    /// - Parameter asyncSequence: The sequence of bytes to write.
    /// - Returns number of bytes written.
    public func write<AsyncSendableSequence: AsyncSequence & Sendable>(
        _ asyncSequence: AsyncSendableSequence
    ) async throws(SubprocessError) -> Int where AsyncSendableSequence.Element == Data {
        do {
            var buffer = Data()
            for try await data in asyncSequence {
                buffer.append(data)
            }
            return try await self.write(buffer)
        } catch {
            if let subprocessError = error as? SubprocessError {
                throw subprocessError
            }
            throw .failedToWriteToProcess(
                withUnderlyingError: error as? SubprocessError.UnderlyingError
            )
        }
    }
}

#if SUBPROCESS_ASYNCIO_DISPATCH
extension AsyncIO {
    internal func write(
        _ data: Data,
        to diskIO: borrowing IOChannel
    ) async throws(SubprocessError) -> Int {
        try await _castError {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
                let dispatchData = data.withUnsafeBytes {
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
    }
}
#else
extension Data: AsyncIO._ContiguousBytes {}

extension AsyncIO {
    internal func write(
        _ data: Data,
        to diskIO: borrowing IOChannel
    ) async throws(SubprocessError) -> Int {
        return try await self._write(data, to: diskIO)
    }
}
#endif // SUBPROCESS_ASYNCIO_DISPATCH

#endif // SubprocessFoundation
