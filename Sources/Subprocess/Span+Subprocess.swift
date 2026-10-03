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

@_unsafeNonescapableResult
@inlinable @inline(__always)
@_lifetime(borrow source)
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
@_lifetime(copy source)
public func _overrideLifetime<
    T: ~Copyable & ~Escapable,
    U: ~Copyable & ~Escapable
>(
    of dependent: consuming T,
    copyingFrom source: consuming U
) -> T {
    dependent
}

extension Array where Element: BitwiseCopyable {
    // swift-format-ignore
    // Access the storage backing this Buffer
    internal var _bytes: RawSpan {
        // `Array.span` (SE-0456) is gated to macOS 26 and does not back-deploy,
        // but Subprocess deploys to macOS 13, so hand-roll the `RawSpan`. There
        // is no back-deployed `Array.span`. Replace with `self.span.bytes` once
        // the deployment floor reaches macOS 26.
        @_lifetime(borrow self)
        borrowing get {
            let ptr = self.withUnsafeBytes { $0 }
            let bytes = RawSpan(_unsafeBytes: ptr)
            return _overrideLifetime(of: bytes, to: self)
        }
    }
}

