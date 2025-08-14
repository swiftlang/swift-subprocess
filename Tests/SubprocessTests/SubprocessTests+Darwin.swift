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

#if canImport(Darwin)

import Foundation

import _SubprocessCShims
import Testing

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif
@testable import Subprocess

// MARK: PlatformOptions Tests
@Suite(.serialized)
struct SubprocessDarwinTests {
    @Test func testSubprocessPlatformOptionsPreExecProcessAction() async throws {
        var platformOptions = PlatformOptions()
        platformOptions.preExecProcessAction = {
            exit(1234567)
        }
        let idResult = try await Subprocess.run(
            .path("/bin/pwd"),
            platformOptions: platformOptions,
            output: .discarded
        )
        #expect(idResult.terminationStatus == .exited(1234567))
    }

    @Test func testSubprocessPlatformOptionsPreExecProcessActionAndProcessConfigurator() async throws {
        let (readFD, writeFD) = try FileDescriptor.pipe()
        try await readFD.closeAfter {
            let childPID = try await writeFD.closeAfter {
                // Allocate some constant high-numbered FD that's unlikely to be used.
                let specialFD = try writeFD.duplicate(as: FileDescriptor(rawValue: 9000))
                return try await specialFD.closeAfter {
                    // Make the fd non-blocking just to avoid the test hanging if it fails
                    let opts = fcntl(specialFD.rawValue, F_GETFD)
                    #expect(opts >= 0)
                    #expect(fcntl(specialFD.rawValue, F_SETFD, opts | O_NONBLOCK) >= 0)

                    var platformOptions = PlatformOptions()
                    platformOptions.preExecProcessAction = {
                        var pid: Int32 = getpid()
                        if write(9000, &pid, 4) != 4 {
                            exit(EXIT_FAILURE)
                        }
                    }
                    platformOptions.preSpawnProcessConfigurator = { spawnAttr, _ in
                        // Set POSIX_SPAWN_SETSID flag, which implies calls
                        // to setsid
                        var flags: Int16 = 0
                        posix_spawnattr_getflags(&spawnAttr, &flags)
                        posix_spawnattr_setflags(&spawnAttr, flags | Int16(POSIX_SPAWN_SETSID))
                    }
                    // Check the process ID (pid), process group ID (pgid), and
                    // controlling terminal's process group ID (tpgid)
                    let psResult = try await Subprocess.run(
                        .path("/bin/bash"),
                        arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
                        platformOptions: platformOptions,
                        input: .none,
                        error: .discarded
                    ) { execution, standardOutput in
                        var buffer = Data()
                        for try await chunk in standardOutput {
                            let currentChunk = chunk.withUnsafeBytes { Data($0) }
                            buffer += currentChunk
                        }
                        return (pid: execution.processIdentifier.value, standardOutput: buffer)
                    }
                    try assertNewSessionCreated(terminationStatus: psResult.terminationStatus, output: String(decoding: psResult.value.standardOutput, as: UTF8.self))
                    return psResult.value.pid
                }
            }

            let bytes = try await readFD.readUntilEOF(upToLength: 4)
            var pid: Int32 = -1
            _ = withUnsafeMutableBytes(of: &pid) { ptr in
                bytes.copyBytes(to: ptr)
            }
            #expect(pid == childPID)
        }
    }

    @Test func testSubprocessPlatformOptionsProcessConfiguratorUpdateSpawnAttr() async throws {
        var platformOptions = PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = { spawnAttr, _ in
            // Set POSIX_SPAWN_SETSID flag, which implies calls
            // to setsid
            var flags: Int16 = 0
            posix_spawnattr_getflags(&spawnAttr, &flags)
            posix_spawnattr_setflags(&spawnAttr, flags | Int16(POSIX_SPAWN_SETSID))
        }
        // Check the process ID (pid), process group ID (pgid), and
        // controlling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        try assertNewSessionCreated(with: psResult)
    }

    @Test func testSubprocessPlatformOptionsProcessConfiguratorUpdateFileAction() async throws {
        let intendedWorkingDir = FileManager.default.temporaryDirectory.path()
        var platformOptions = PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = { _, fileAttr in
            // Change the working directory
            intendedWorkingDir.withCString { path in
                _ = posix_spawn_file_actions_addchdir_np(&fileAttr, path)
            }
        }
        let pwdResult = try await Subprocess.run(
            .path("/bin/pwd"),
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        #expect(pwdResult.terminationStatus.isSuccess)
        let currentDir = try #require(
            pwdResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // On Darwin, /var is linked to /private/var; /tmp is linked /private/tmp
        var expected = FilePath(intendedWorkingDir)
        if expected.starts(with: "/var") || expected.starts(with: "/tmp") {
            expected = FilePath("/private").appending(expected.components)
        }
        #expect(FilePath(currentDir) == expected)
    }

    @Test func testSuspendResumeProcess() async throws {
        _ = try await Subprocess.run(
            // This will intentionally hang
            .path("/bin/cat"),
            error: .discarded
        ) { subprocess, standardOutput in
            // First suspend the process
            try subprocess.send(signal: .suspend)
            var suspendedStatus: Int32 = 0
            waitpid(subprocess.processIdentifier.value, &suspendedStatus, WNOHANG | WUNTRACED)
            #expect(_was_process_suspended(suspendedStatus) > 0)
            // Now resume the process
            try subprocess.send(signal: .resume)
            var resumedStatus: Int32 = 0
            waitpid(subprocess.processIdentifier.value, &resumedStatus, WNOHANG | WUNTRACED)
            #expect(_was_process_suspended(resumedStatus) == 0)

            // Now kill the process
            try subprocess.send(signal: .terminate)
            for try await _ in standardOutput {}
        }
    }
}

#endif  // canImport(Darwin)
