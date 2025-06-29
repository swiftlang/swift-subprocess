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

@testable import Subprocess

#if canImport(Darwin)
import Darwin
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

/// This file defines protocols for platform-specific structs
/// and adds retroactive conformances to them to ensure they all
/// conform to a uniform shape. We opted to keep these protocols
/// in the test target as opposed to making them public APIs
/// because we don't directly use them in public APIs.

protocol ProcessIdentifierProtocol: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    #if os(Windows)
    var value: DWORD { get }
    #else
    var value: pid_t { get }
    #endif

    #if os(Linux) || os(Android)
    var processDescriptor: PlatformFileDescriptor { get }
    #endif

    #if os(Windows)
    nonisolated(unsafe) var processDescriptor: PlatformFileDescriptor { get }
    nonisolated(unsafe) var threadHandle: PlatformFileDescriptor { get }
    #endif
}

extension ProcessIdentifier : ProcessIdentifierProtocol {}
