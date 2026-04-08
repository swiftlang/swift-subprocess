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
#endif

/// A concrete `Output` type for subprocesses that collects output
/// from the subprocess as data.
internal struct DataOutput: OutputProtocol {
    /// The output type for this output option
    typealias OutputType = Data
    /// The maximum number of bytes to collect.
    let maxSize: Int

    #if SubprocessSpan
    /// Create data from a raw span.
    func output(from span: RawSpan) throws(SubprocessError) -> Data {
        return Data(span)
    }
    #else
    /// Create a data from sequence of 8-bit unsigned integers.
    func output(from buffer: some Sequence<UInt8>) throws(SubprocessError) -> Data {
        return Data(buffer)
    }
    #endif

    init(limit: Int) {
        self.maxSize = limit
    }
}

extension OutputMethod where T == Data {
    /// Create a `Subprocess` output that collects output as `Data`
    /// with given buffer limit in bytes. Subprocess throws an error
    /// if the child process emits more bytes than the limit.
    public static func data(limit: Int) -> OutputMethod<Data> {
        let inner = DataOutput(limit: limit)
        return OutputMethod<Data>(
            maxSize: limit,
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .output) },
            captureOutput: { diskIO in
                try await inner.captureOutput(from: diskIO)
            }
        )
    }
}

extension ErrorOutputMethod where T == Data {
    /// Create a `Subprocess` error output that collects error output as `Data`
    /// with given buffer limit in bytes. Subprocess throws an error
    /// if the child process emits more bytes than the limit.
    public static func data(limit: Int) -> ErrorOutputMethod<Data> {
        let inner = DataOutput(limit: limit)
        return ErrorOutputMethod<Data>(
            maxSize: limit,
            createPipe: { _ in try CreatedPipe(closeWhenDone: true, purpose: .output) },
            captureOutput: { diskIO in
                try await inner.captureOutput(from: diskIO)
            }
        )
    }
}

extension Data {
    /// Create a `Data` from `Buffer`
    /// - Parameter buffer: buffer to copy from
    public init(buffer: AsyncBufferSequence.Buffer) {
        self = Data(buffer.data)
    }
}

#endif // SubprocessFoundation
