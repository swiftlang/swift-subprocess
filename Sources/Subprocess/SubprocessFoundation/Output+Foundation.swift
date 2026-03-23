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

/// An output type that collects the subprocess's output as `Data`.
public struct DataOutput: OutputProtocol, ErrorOutputProtocol {
    /// The output type for this output option.
    public typealias OutputType = Data
    /// The maximum number of bytes to collect.
    public let maxSize: Int

    #if SubprocessSpan
    /// Creates data from a raw span.
    public func output(from span: RawSpan) throws(SubprocessError) -> Data {
        return Data(span)
    }
    #else
    /// Creates data from a sequence of bytes.
    public func output(from buffer: some Sequence<UInt8>) throws(SubprocessError) -> Data {
        return Data(buffer)
    }
    #endif

    internal init(limit: Int) {
        self.maxSize = limit
    }
}

extension OutputProtocol where Self == DataOutput {
    /// Creates a subprocess output that collects output as `Data`,
    /// up to `limit` bytes.
    ///
    /// The subprocess throws an error if the child process
    /// produces more bytes than `limit`.
    public static func data(limit: Int) -> Self {
        return .init(limit: limit)
    }
}

extension Data {
    /// Creates a `Data` value from a buffer.
    /// - Parameter buffer: The buffer to copy from.
    public init(buffer: AsyncBufferSequence.Buffer) {
        self = Data(buffer.data)
    }
}

#endif // SubprocessFoundation
