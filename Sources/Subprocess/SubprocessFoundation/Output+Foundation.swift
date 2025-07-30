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
/// from the subprocess as `Data`. This option must be used with
/// the `run()` method that returns a `CollectedResult`
public struct DataOutput: OutputProtocol {
    public typealias OutputType = Data
    public let maxSize: Int

    #if SubprocessSpan
    public func output(from span: RawSpan) throws -> Data {
        return Data(span)
    }
    #else
    public func output(from buffer: some Sequence<UInt8>) throws -> Data {
        return Data(buffer)
    }
    #endif

    internal init(limit: Int) {
        self.maxSize = limit
    }
}

extension OutputProtocol where Self == DataOutput {
    /// Create a `Subprocess` output that collects output as `Data`
    /// with given buffer limit in bytes. Subprocess throws an error
    /// if the child process emits more bytes than the limit.
    public static func data(limit: Int) -> Self {
        return .init(limit: limit)
    }
}

extension Data {
    /// Create a `Data` from `Buffer`
    /// - Parameter buffer: buffer to copy from
    public init(buffer: AsyncBufferSequence.Buffer) {
        self = Data(buffer.data)
    }
}

#endif  // SubprocessFoundation
