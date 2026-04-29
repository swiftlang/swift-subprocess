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
internal import Foundation
#else
// On other platforms prefer FoundationEssentials
internal import FoundationEssentials
#endif

#endif

extension AsyncBufferSequence {
    /// An immutable collection of bytes.
    public struct Buffer: Sendable {
        internal let data: [UInt8]

        internal init(data: [UInt8]) {
            self.data = data
        }
    }
}

// MARK: - Properties
extension AsyncBufferSequence.Buffer {
    /// The number of bytes in the buffer.
    public var count: Int {
        return self.data.count
    }

    /// A Boolean value indicating whether the collection is empty.
    public var isEmpty: Bool {
        return self.data.isEmpty
    }
}

// MARK: - Accessors
extension AsyncBufferSequence.Buffer {
    /// Accesses the raw bytes stored in this buffer.
    /// - Parameter body: A closure with an `UnsafeRawBufferPointer` parameter that
    ///   points to the contiguous storage for the buffer. If no such storage exists,
    ///   the method creates it. The argument is valid only for the duration of the
    ///   closure's execution.
    /// - Returns: The return value of the body closure.
    public func withUnsafeBytes<ResultType, Error: Swift.Error>(
        _ body: (UnsafeRawBufferPointer) throws(Error) -> ResultType
    ) throws(Error) -> ResultType {
        do {
            return try self.data.withUnsafeBytes(body)
        } catch {
            throw error as! Error
        }
    }

    // swift-format-ignore
    // Access the storage backing this Buffer
    public var bytes: RawSpan {
        @_lifetime(borrow self)
        borrowing get {
            let ptr = self.data.withUnsafeBytes { $0 }
            let bytes = RawSpan(_unsafeBytes: ptr)
            return _overrideLifetime(of: bytes, to: self)
        }
    }
}
