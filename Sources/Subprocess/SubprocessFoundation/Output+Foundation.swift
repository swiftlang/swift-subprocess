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
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
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

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension OutputProtocol where Self == DataOutput {
    /// Create a `Subprocess` output that collects output as `Data`
    /// up to 128kb.
    public static var data: Self {
        return .data(limit: 128 * 1024)
    }

    /// Create a `Subprocess` output that collects output as `Data`
    /// with given max number of bytes to collect.
    public static func data(limit: Int) -> Self {
        return .init(limit: limit)
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension Data {
    /// Create a `Data` from `Buffer`
    /// - Parameter buffer: buffer to copy from
    public init(buffer: AsyncBufferSequence.Buffer) {
        self = Data(buffer.data)
    }
}

// MARK: - Workarounds
#if SubprocessSpan
@available(SubprocessSpan, *)
extension OutputProtocol {
    @_disfavoredOverload
    public func output(from data: some DataProtocol) throws -> OutputType {
        // FIXME: remove workaround for
        // rdar://143992296
        // https://github.com/swiftlang/swift-subprocess/issues/3
        return try self.output(from: data.bytes)
    }
}
#endif

#endif  // SubprocessFoundation
