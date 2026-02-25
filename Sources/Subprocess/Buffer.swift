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

// swift-format-ignore-file

#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl)
@preconcurrency internal import Dispatch
#endif

extension AsyncBufferSequence {
    /// A immutable collection of bytes
    public struct Buffer: Sendable {
        #if SUBPROCESS_ASYNCIO_DISPATCH
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
            return slices.map { .init(data: $0, backingData: data) }
        }
        #else
        internal let data: [UInt8]

        internal init(data: [UInt8]) {
            self.data = data
        }

        internal static func createFrom(_ data: [UInt8]) -> [Buffer] {
            return [.init(data: data)]
        }
        #endif // SUBPROCESS_ASYNCIO_DISPATCH
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

    #if SubprocessSpan
    // swift-format-ignore
    // Access the storage backing this Buffer
    public var bytes: RawSpan {
        @lifetime(borrow self)
        borrowing get {
            let ptr = self.data.withUnsafeBytes { $0 }
            let bytes = RawSpan(_unsafeBytes: ptr)
            return _overrideLifetime(of: bytes, to: self)
        }
    }
    #endif // SubprocessSpan
}

// MARK: - Hashable, Equatable
extension AsyncBufferSequence.Buffer: Equatable, Hashable {
    #if SUBPROCESS_ASYNCIO_DISPATCH
    /// Returns a Boolean value that indicates whether two buffers are equal.
    public static func == (lhs: AsyncBufferSequence.Buffer, rhs: AsyncBufferSequence.Buffer) -> Bool {
        return lhs.data == rhs.data
    }

    /// Hashes the essential components of this value by feeding them into the given hasher.
    public func hash(into hasher: inout Hasher) {
        return self.data.hash(into: &hasher)
    }
    #endif
    // else Compiler generated conformances
}

#if SUBPROCESS_ASYNCIO_DISPATCH
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
#if !canImport(Darwin) || !SubprocessFoundation
/// `DispatchData.Region` is defined in Foundation, but we can't depend on Foundation when the SubprocessFoundation trait is disabled.
extension DispatchData {
    typealias Region = _ContiguousBufferView

    var regions: [Region] {
        contiguousBufferViews
    }

    internal struct _ContiguousBufferView: @unchecked Sendable, RandomAccessCollection {
        typealias Element = UInt8

        internal let bytes: UnsafeBufferPointer<UInt8>

        internal var startIndex: Int { self.bytes.startIndex }
        internal var endIndex: Int { self.bytes.endIndex }

        internal init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
        }

        internal func withUnsafeBytes<ResultType>(_ body: (UnsafeRawBufferPointer) throws -> ResultType) rethrows -> ResultType {
            return try body(UnsafeRawBufferPointer(self.bytes))
        }

        subscript(position: Int) -> UInt8 {
            _read {
                yield self.bytes[position]
            }
        }
    }

    internal var contiguousBufferViews: [_ContiguousBufferView] {
        var slices = [_ContiguousBufferView]()
        enumerateBytes { (bytes, index, stop) in
            slices.append(_ContiguousBufferView(bytes: bytes))
        }
        return slices
    }
}
#endif
#endif
