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

/// An output type that collects the subprocess's output as binary data.
public struct DataOutput: OutputProtocol, ErrorOutputProtocol {
    public typealias OutputType = Data
    public let maxSize: Int

    public func output(from span: RawSpan) throws(SubprocessError) -> Data {
        return Data(span)
    }

    internal init(limit: Int) {
        self.maxSize = limit
    }
}

extension OutputProtocol where Self == DataOutput {
    /// Creates a subprocess output that collects the process's binary output, up to the specified byte limit.
    ///
    /// The subprocess throws an error if the process
    /// produces more bytes than `limit`.
    public static func data(limit: Int) -> Self {
        return .init(limit: limit)
    }
}

extension Data {
    /// Creates a binary data value from a subprocess output buffer.
    /// - Parameter buffer: The buffer to copy from.
    public init(buffer: SubprocessOutputSequence.Buffer) {
        self = Data(buffer.data)
    }
}

#endif // SubprocessFoundation
