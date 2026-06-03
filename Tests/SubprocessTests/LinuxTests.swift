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

#if os(Linux) || os(Android)

#if canImport(Android)
import Android
import Foundation
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(System)
import System
#else
import SystemPackage
#endif

import FoundationEssentials

import Testing
@testable import Subprocess

// MARK: PlatformOption Tests
@Suite(.serialized)
struct SubprocessLinuxTests {
    init() {
        _ = globallyIgnoredSIGPIPE
    }

    @Test func testUniqueProcessIdentifier() async throws {
        _ = try await Subprocess.run(
            .path("/bin/echo"),
            input: .none,
            output: .discarded,
            error: .discarded
        ) { subprocess in
            if subprocess.processIdentifier.processDescriptor != .invalidDescriptor {
                var statinfo = stat()
                try #require(fstat(subprocess.processIdentifier.processDescriptor, &statinfo) == 0)

                // In kernel 6.9+, st_ino globally uniquely identifies the process
                #expect(statinfo.st_ino > 0)
            }
        }
    }
}
#endif // canImport(Glibc) || canImport(Bionic) || canImport(Musl)
