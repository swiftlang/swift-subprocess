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

#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl)
@preconcurrency internal import Dispatch
#endif


extension AsyncBufferSequence {
    /// A immutable collection of bytes
    public struct Buffer: Sendable {
        #if canImport(Darwin)
        // We need to keep the backingData alive while Slice is alive
        internal let backingData: DispatchData
        internal let data: DispatchData.Region

        internal init(data: DispatchData.Region, backingData: DispatchData) {
            self.data = data
            self.backingData = backingData
        }

        internal static func createFrom(_ data: DispatchData) -> [Buffer] {
            let slices = data.regions
            // In most (all?) cases data should only have one slice
            if _fastPath(slices.count == 1) {
                return [.init(data: slices[0], backingData: data)]
            }
            return slices.map{ .init(data: $0, backingData: data) }
        }
        #else
        internal let data: [UInt8]

        internal init(data: [UInt8]) {
            self.data = data
        }

        internal static func createFrom(_ data: [UInt8]) -> [Buffer] {
            return [.init(data: data)]
        }
        #endif // canImport(Darwin)
    }
}

// MARK: - Properties
extension AsyncBufferSequence.Buffer {
    /// Number of bytes stored in the buffer
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
    /// Access the raw bytes stored in this buffer
    /// - Parameter body: A closure with an `UnsafeRawBufferPointer` parameter that
    ///   points to the contiguous storage for the type. If no such storage exists,
    ///   the method creates it. If body has a return value, this method also returns
    ///   that value. The argument is valid only for the duration of the
    ///   closure’s SequenceOutput.
    /// - Returns: The return value, if any, of the body closure parameter.
    public func withUnsafeBytes<ResultType>(
        _ body: (UnsafeRawBufferPointer) throws -> ResultType
    ) rethrows -> ResultType {
        return try self.data.withUnsafeBytes(body)
    }

    #if SubprocessSpan
    // Access the storage backing this Buffer
    public var bytes: RawSpan {
        @lifetime(borrow self)
        borrowing get {
            let ptr = self.data.withUnsafeBytes { $0 }
            let bytes = RawSpan(_unsafeBytes: ptr)
            return _overrideLifetime(of: bytes, to: self)
        }
    }
    #endif  // SubprocessSpan
}

// MARK: - Hashable, Equatable
extension AsyncBufferSequence.Buffer: Equatable, Hashable {
    #if canImport(Darwin)
    public static func == (lhs: AsyncBufferSequence.Buffer, rhs: AsyncBufferSequence.Buffer) -> Bool {
        return lhs.data == rhs.data
    }

    public func hash(into hasher: inout Hasher) {
        return self.data.hash(into: &hasher)
    }
    #endif
    // else Compiler generated conformances
}

#if canImport(Darwin)
extension DispatchData.Region {
    static func == (lhs: DispatchData.Region, rhs: DispatchData.Region) -> Bool {
        return lhs.withUnsafeBytes { lhsBytes in
            return rhs.withUnsafeBytes { rhsBytes in
                return lhsBytes.elementsEqual(rhsBytes)
            }
        }
    }

    internal func hash(into hasher: inout Hasher) {
        return self.withUnsafeBytes { ptr in
            return hasher.combine(bytes: ptr)
        }
    }
}
#endif

