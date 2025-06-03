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

#if canImport(Glibc) || canImport(Bionic) || canImport(Musl)

#if canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import FoundationEssentials

import Testing
@testable import Subprocess

// MARK: PlatformOption Tests
@Suite(.serialized)
struct SubprocessLinuxTests {
    @Test func testSubprocessPlatformOptionsPreSpawnProcessConfigurator() async throws {
        var platformOptions = PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = {
            setgid(4321)
        }
        let idResult = try await Subprocess.run(
            .path("/usr/bin/id"),
            arguments: ["-g"],
            platformOptions: platformOptions,
            output: .string
        )
        #expect(idResult.terminationStatus.isSuccess)
        let id = try #require(idResult.standardOutput)
        #expect(
            id.trimmingCharacters(in: .whitespacesAndNewlines) == "\(4321)"
        )
    }

    @Test func testSuspendResumeProcess() async throws {
        func isProcessSuspended(_ pid: pid_t) throws -> Bool {
            let status = try Data(
                contentsOf: URL(filePath: "/proc/\(pid)/status")
            )
            let statusString = try #require(
                String(data: status, encoding: .utf8)
            )
            // Parse the status string
            let stats = statusString.split(separator: "\n")
            if let index = stats.firstIndex(
                where: { $0.hasPrefix("State:") }
            ) {
                let processState = stats[index].split(
                    separator: ":"
                ).map {
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                }

                return processState[1].hasPrefix("T")
            }
            return false
        }

        _ = try await Subprocess.run(
            // This will intentionally hang
            .path("/usr/bin/sleep"),
            arguments: ["infinity"],
            error: .discarded
        ) { subprocess, standardOutput in
            // First suspend the process
            try subprocess.send(signal: .suspend)
            #expect(
                try isProcessSuspended(subprocess.processIdentifier.value)
            )
            // Now resume the process
            try subprocess.send(signal: .resume)
            #expect(
                try isProcessSuspended(subprocess.processIdentifier.value) == false
            )
            // Now kill the process
            try subprocess.send(signal: .terminate)
            for try await _ in standardOutput {}
        }
    }
}

#endif  // canImport(Glibc) || canImport(Bionic) || canImport(Musl)
