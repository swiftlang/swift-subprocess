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
#endif

/// An output type that collects the subprocess's output as `Data`.
public struct DataOutput: OutputProtocol, ErrorOutputProtocol {
    /// The output type for this output option.
    public typealias OutputType = Data
    /// The maximum number of bytes to collect.
    public let maxSize: Int64

    /// Creates data from a raw span.
    public func output(from span: RawSpan) throws(SubprocessError) -> Data {
        return Data(span)
    }

    internal init(byteLimit: Int64) {
        self.maxSize = byteLimit
    }
}

extension OutputProtocol where Self == DataOutput {
    /// Creates a subprocess output that collects output as `Data`,
    /// up to `byteLimit` bytes.
    ///
    /// The subprocess throws an error if the child process
    /// produces more bytes than `byteLimit`.
    public static func data(byteLimit: Int64) -> Self {
        return .init(byteLimit: byteLimit)
    }
}

extension Data {
    /// Creates a `Data` value from a buffer.
    /// - Parameter buffer: The buffer to copy from.
    public init(buffer: SubprocessOutputSequence.Buffer) {
        self = Data(buffer.data)
    }
}

#endif // SubprocessFoundation
