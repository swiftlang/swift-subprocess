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

#if SubprocessSpan

@_unsafeNonescapableResult
@inlinable @inline(__always)
@lifetime(borrow source)
public func _overrideLifetime<
    T: ~Copyable & ~Escapable,
    U: ~Copyable & ~Escapable
>(
    of dependent: consuming T,
    to source: borrowing U
) -> T {
    dependent
}

@_unsafeNonescapableResult
@inlinable @inline(__always)
@lifetime(copy source)
public func _overrideLifetime<
    T: ~Copyable & ~Escapable,
    U: ~Copyable & ~Escapable
>(
    of dependent: consuming T,
    copyingFrom source: consuming U
) -> T {
    dependent
}

extension Span where Element: BitwiseCopyable {

    internal var _bytes: RawSpan {
        @lifetime(copy self)
        @_alwaysEmitIntoClient
        get {
            let rawSpan = RawSpan(_elements: self)
            return _overrideLifetime(of: rawSpan, copyingFrom: self)
        }
    }
}

#if canImport(Glibc) || canImport(Bionic) || canImport(Musl)
internal import Dispatch

extension DispatchData {
    var bytes: RawSpan {
        _read {
            if self.count == 0 {
                let empty = UnsafeRawBufferPointer(start: nil, count: 0)
                let span = RawSpan(_unsafeBytes: empty)
                yield _overrideLifetime(of: span, to: self)
            } else {
                // FIXME: We cannot get a stable ptr out of DispatchData.
                // For now revert back to copy
                let array = Array(self)
                let ptr = array.withUnsafeBytes { return $0 }
                let span = RawSpan(_unsafeBytes: ptr)
                yield _overrideLifetime(of: span, to: self)
            }
        }
    }
}
#endif  // canImport(Glibc) || canImport(Bionic) || canImport(Musl)

#endif  // SubprocessSpan
