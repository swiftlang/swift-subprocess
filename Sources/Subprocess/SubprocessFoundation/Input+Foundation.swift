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
public import Foundation
#else
// On other platforms prefer FoundationEssentials
public import FoundationEssentials
#endif // canImport(Darwin)

#if canImport(System)
import System
#else
import SystemPackage
#endif

internal import Dispatch

/// An input type that reads from a `Data` value.
public struct DataInput: InputProtocol {
    private let data: Data

    /// Asynchronously write the input to the subprocess using the
    /// write file descriptor.
    public func write(with writer: StandardInputWriter) async throws(SubprocessError) {
        _ = try await writer.write(self.data)
    }

    internal init(data: Data) {
        self.data = data
    }
}

/// An input type that reads from a sequence of `Data` values.
public struct DataSequenceInput<
    InputSequence: Sequence & Sendable
>: InputProtocol where InputSequence.Element == Data {
    private let sequence: InputSequence

    /// Asynchronously write the input to the subprocess using the
    /// write file descriptor.
    public func write(with writer: StandardInputWriter) async throws(SubprocessError) {
        var buffer = Data()
        for chunk in self.sequence {
            buffer.append(chunk)
        }
        _ = try await writer.write(buffer)
    }

    internal init(underlying: InputSequence) {
        self.sequence = underlying
    }
}

/// An input type that reads from an asynchronous sequence of `Data` values.
public struct DataAsyncSequenceInput<
    InputSequence: AsyncSequence & Sendable
>: InputProtocol where InputSequence.Element == Data {
    private let sequence: InputSequence

    private func writeChunk(_ chunk: Data, with writer: StandardInputWriter) async throws(SubprocessError) {
        _ = try await writer.write(chunk)
    }

    /// Asynchronously write the input to the subprocess using the
    /// write file descriptor.
    public func write(with writer: StandardInputWriter) async throws(SubprocessError) {
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

    internal init(underlying: InputSequence) {
        self.sequence = underlying
    }
}

extension InputProtocol {
    /// Creates a subprocess input from a `Data` value.
    public static func data(_ data: Data) -> Self where Self == DataInput {
        return DataInput(data: data)
    }

    /// Creates a subprocess input from a sequence of `Data` values.
    public static func sequence<InputSequence: Sequence & Sendable>(
        _ sequence: InputSequence
    ) -> Self where Self == DataSequenceInput<InputSequence> {
        return .init(underlying: sequence)
    }

    /// Creates a subprocess input from an asynchronous sequence of `Data` values.
    public static func sequence<InputSequence: AsyncSequence & Sendable>(
        _ asyncSequence: InputSequence
    ) -> Self where Self == DataAsyncSequenceInput<InputSequence> {
        return .init(underlying: asyncSequence)
    }
}

extension StandardInputWriter {
    /// Writes a `Data` value to the subprocess's standard input.
    /// - Parameter data: The data to write.
    /// - Returns: The number of bytes written.
    public func write(
        _ data: Data
    ) async throws(SubprocessError) -> Int {
        return try await AsyncIO.shared.write(data, to: self.diskIO)
    }

    /// Writes an asynchronous sequence of `Data` to the subprocess's standard input.
    /// - Parameter asyncSequence: The sequence of data to write.
    /// - Returns: The number of bytes written.
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
