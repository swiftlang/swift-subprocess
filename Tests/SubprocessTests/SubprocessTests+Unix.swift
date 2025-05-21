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

#if canImport(Darwin) || canImport(Glibc)

#if canImport(Darwin)
// On Darwin always prefer system Foundation
import Foundation
#else
// On other platforms prefer FoundationEssentials
import FoundationEssentials
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Musl)
import Musl
#endif

import _SubprocessCShims
import Testing
@testable import Subprocess

import TestResources

import Dispatch
#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

@Suite(.serialized)
struct SubprocessUnixTests {}

// MARK: - Executable test
extension SubprocessUnixTests {

    @Test func testExecutableNamed() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // Simple test to make sure we can find a common utility
        let message = "Hello, world!"
        let result = try await Subprocess.run(
            .name("echo"),
            arguments: [message]
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == message)
    }

    @Test func testExecutableNamedCannotResolve() async {
        guard #available(SubprocessSpan , *) else {
            return
        }
        do {
            _ = try await Subprocess.run(.name("do-not-exist"))
            Issue.record("Expected to throw")
        } catch {
            guard let subprocessError: SubprocessError = error as? SubprocessError else {
                Issue.record("Expected SubprocessError, got \(error)")
                return
            }
            #expect(subprocessError.code == .init(.executableNotFound("do-not-exist")))
        }
    }

    @Test func testExecutableAtPath() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let expected = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(.path("/bin/pwd"), output: .string)
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let maybePath = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = try #require(maybePath)
        #expect(directory(path, isSameAs: expected))
    }

    @Test func testExecutableAtPathCannotResolve() async {
        guard #available(SubprocessSpan , *) else {
            return
        }
        do {
            _ = try await Subprocess.run(.path("/usr/bin/do-not-exist"))
            Issue.record("Expected to throw SubprocessError")
        } catch {
            guard let subprocessError: SubprocessError = error as? SubprocessError else {
                Issue.record("Expected SubprocessError, got \(error)")
                return
            }
            #expect(subprocessError.code == .init(.executableNotFound("/usr/bin/do-not-exist")))
        }
    }
}

// MARK: - Arguments Tests
extension SubprocessUnixTests {
    @Test func testArgunementsArrayLitereal() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "echo Hello World!"],
            output: .string
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output == "Hello World!"
        )
    }

    @Test func testArgumentsOverride() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: .init(
                executablePathOverride: "apple",
                remainingValues: ["-c", "echo $0"]
            ),
            output: .string
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output == "apple"
        )
    }

    @Test func testArgumemtsFromArray() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let arguments: [UInt8] = Array("Data Content\0".utf8)
        let result = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: .init(
                executablePathOverride: nil,
                remainingValues: [arguments]
            ),
            output: .string
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output == "Data Content"
        )
    }
}

// MARK: - Environment Tests
extension SubprocessUnixTests {
    @Test func testEnvironmentInherit() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "printenv PATH"],
            environment: .inherit,
            output: .string
        )
        #expect(result.terminationStatus.isSuccess)
        // As a sanity check, make sure there's `/bin` in PATH
        // since we inherited the environment variables
        // rdar://138670128
        let maybeOutput = result.standardOutput
        let pathValue = try #require(maybeOutput)
        #expect(pathValue.contains("/bin"))
    }

    @Test func testEnvironmentInheritOverride() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "printenv HOME"],
            environment: .inherit.updating([
                "HOME": "/my/new/home"
            ]),
            output: .string
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output == "/my/new/home"
        )
    }

    @Test func testEnvironmentCustom() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let result = try await Subprocess.run(
            .path("/usr/bin/printenv"),
            environment: .custom([
                "PATH": "/bin:/usr/bin"
            ]),
            output: .string
        )
        #expect(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output == "PATH=/bin:/usr/bin"
        )
    }
}

// MARK: - Working Directory Tests
extension SubprocessUnixTests {
    @Test func testWorkingDirectoryDefaultValue() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // By default we should use the working directory of the parent process
        let workingDirectory = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(
            .path("/bin/pwd"),
            workingDirectory: nil,
            output: .string
        )
        #expect(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = try #require(output)
        #expect(directory(path, isSameAs: workingDirectory))
    }

    @Test func testWorkingDirectoryCustomValue() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let workingDirectory = FilePath(
            FileManager.default.temporaryDirectory.path()
        )
        let result = try await Subprocess.run(
            .path("/bin/pwd"),
            workingDirectory: workingDirectory,
            output: .string
        )
        #expect(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        let resultPath = result.standardOutput!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(Darwin)
        // On Darwin, /var is linked to /private/var; /tmp is linked to /private/tmp
        var expected = workingDirectory
        if expected.starts(with: "/var") || expected.starts(with: "/tmp") {
            expected = FilePath("/private").appending(expected.components)
        }
        #expect(
            FilePath(resultPath) == expected
        )
        #else
        #expect(
            FilePath(resultPath) == workingDirectory
        )
        #endif
    }
}

// MARK: - Input Tests
extension SubprocessUnixTests {
    @Test func testInputNoInput() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .none,
            output: .string
        )
        #expect(catResult.terminationStatus.isSuccess)
        // We should have read exactly 0 bytes
        #expect(catResult.standardOutput == "")
    }

    @Test func testStringInput() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let content = randomString(length: 64)
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .string(content, using: UTF8.self)
        )
        #expect(catResult.terminationStatus.isSuccess)
        // We should have read exactly 0 bytes
        #expect(catResult.standardOutput == content)
    }

    @Test func testInputFileDescriptor() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // Make sure we can read long text from standard input
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let text: FileDescriptor = try .open(
            theMysteriousIsland,
            .readOnly
        )
        let cat = try await Subprocess.run(
            .path("/bin/cat"),
            input: .fileDescriptor(text, closeAfterSpawningProcess: true),
            output: .data(limit: 2048 * 1024)
        )
        #expect(cat.terminationStatus.isSuccess)
        // Make sure we read all bytes
        #expect(cat.standardOutput == expected)
    }

    @Test func testInputSequence() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .data(expected),
            output: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardOutput.count == expected.count)
        #expect(Array(catResult.standardOutput) == Array(expected))
    }

    #if SubprocessSpan
    @Test func testInputSpan() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let ptr = expected.withUnsafeBytes { return $0 }
        let span: Span<UInt8> = Span(_unsafeBytes: ptr)
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: span,
            output: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardOutput.count == expected.count)
        #expect(Array(catResult.standardOutput) == Array(expected))
    }
    #endif

    @Test func testInputAsyncSequence() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // Maeks ure we can read long text as AsyncSequence
        let fd: FileDescriptor = try .open(theMysteriousIsland, .readOnly)
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let channel = DispatchIO(type: .stream, fileDescriptor: fd.rawValue, queue: .main) { error in
            try? fd.close()
        }
        let stream: AsyncStream<Data> = AsyncStream { continuation in
            channel.read(offset: 0, length: .max, queue: .main) { done, data, error in
                if done {
                    continuation.finish()
                }
                guard let data = data else {
                    return
                }
                continuation.yield(Data(data))
            }
        }
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .sequence(stream),
            output: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardOutput == expected)
    }

    @Test func testInputSequenceCustomExecutionBody() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let result = try await Subprocess.run(
            .path("/bin/cat"),
            input: .data(expected),
            error: .discarded
        ) { execution, standardOutput in
            var buffer = Data()
            for try await chunk in standardOutput {
                let currentChunk = chunk._withUnsafeBytes { Data($0) }
                buffer += currentChunk
            }
            return buffer
        }
        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }

    @Test func testInputAsyncSequenceCustomExecutionBody() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // Maeks ure we can read long text as AsyncSequence
        let fd: FileDescriptor = try .open(theMysteriousIsland, .readOnly)
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let channel = DispatchIO(type: .stream, fileDescriptor: fd.rawValue, queue: .main) { error in
            try? fd.close()
        }
        let stream: AsyncStream<Data> = AsyncStream { continuation in
            channel.read(offset: 0, length: .max, queue: .main) { done, data, error in
                if done {
                    continuation.finish()
                }
                guard let data = data else {
                    return
                }
                continuation.yield(Data(data))
            }
        }
        let result = try await Subprocess.run(
            .path("/bin/cat"),
            input: .sequence(stream),
            error: .discarded
        ) { execution, standardOutput in
            var buffer = Data()
            for try await chunk in standardOutput {
                let currentChunk = chunk._withUnsafeBytes { Data($0) }
                buffer += currentChunk
            }
            return buffer
        }
        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }
}

// MARK: - Output Tests
extension SubprocessUnixTests {
    #if false  // This test needs "death test" support
    @Test func testOutputDiscarded() async throws {
        let echoResult = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: ["Some garbage text"],
            output: .discard
        )
        #expect(echoResult.terminationStatus.isSuccess)
        _ = echoResult.standardOutput  // this line shold fatalError
    }
    #endif

    @Test func testCollectedOutput() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: [expected],
            output: .string
        )
        #expect(echoResult.terminationStatus.isSuccess)
        let output = try #require(
            echoResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == expected)
    }

    @Test func testCollectedOutputWithLimit() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let limit = 4
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: [expected],
            output: .string(limit: limit, encoding: UTF8.self)
        )
        #expect(echoResult.terminationStatus.isSuccess)
        let output = try #require(
            echoResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRange = expected.startIndex..<expected.index(expected.startIndex, offsetBy: limit)
        #expect(String(expected[targetRange]) == output)
    }

    @Test func testCollectedOutputFileDesriptor() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let outputFilePath = FilePath(FileManager.default.temporaryDirectory.path())
            .appending("Test.out")
        if FileManager.default.fileExists(atPath: outputFilePath.string) {
            try FileManager.default.removeItem(atPath: outputFilePath.string)
        }
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: [expected],
            output: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: false
            )
        )
        #expect(echoResult.terminationStatus.isSuccess)
        try outputFile.close()
        let outputData: Data = try Data(
            contentsOf: URL(filePath: outputFilePath.string)
        )
        let output = try #require(
            String(data: outputData, encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(echoResult.terminationStatus.isSuccess)
        #expect(output == expected)
    }

    @Test func testCollectedOutputFileDescriptorAutoClose() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let outputFilePath = FilePath(FileManager.default.temporaryDirectory.path())
            .appending("Test.out")
        if FileManager.default.fileExists(atPath: outputFilePath.string) {
            try FileManager.default.removeItem(atPath: outputFilePath.string)
        }
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let echoResult = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: ["Hello world"],
            output: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: true
            )
        )
        #expect(echoResult.terminationStatus.isSuccess)
        // Make sure the file descriptor is already closed
        do {
            try outputFile.close()
            Issue.record("Output file descriptor should be closed automatically")
        } catch {
            guard let typedError = error as? Errno else {
                Issue.record("Wrong type of error thrown")
                return
            }
            #expect(typedError == .badFileDescriptor)
        }
    }

    @Test func testRedirectedOutputRedirectToSequence() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // Make ure we can read long text redirected to AsyncSequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            arguments: [theMysteriousIsland.string],
            error: .discarded
        ) { execution, standardOutput in
            var buffer = Data()
            for try await chunk in standardOutput {
                let currentChunk = chunk._withUnsafeBytes { Data($0) }
                buffer += currentChunk
            }
            return buffer
        }
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.value == expected)
    }

    @Test func testBufferOutput() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let inputFd: FileDescriptor = try .open(theMysteriousIsland, .readOnly)
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .fileDescriptor(inputFd, closeAfterSpawningProcess: true),
            output: .bytes(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(expected.elementsEqual(catResult.standardOutput))
    }

    @Test func testCollectedError() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // Make ure we can capture long text on standard error
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "cat \(theMysteriousIsland.string) 1>&2"],
            error: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardError == expected)
    }

    @Test func testSlowDripRedirectedOutputRedirectToSequence() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let threshold: Double = 0.5

        let script = """
        echo "DONE"
        sleep \(threshold)
        """

        var platformOptions = PlatformOptions()
        platformOptions.streamOptions = .init(minimumBufferSize: 0)

        let start = ContinuousClock().now

        let catResult = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", script],
            platformOptions: platformOptions,
            error: .discarded,
            body: { (execution, standardOutput) in
                for try await chunk in standardOutput {
                    let string = chunk._withUnsafeBytes { String(decoding: $0, as: UTF8.self) }

                    if string.hasPrefix("DONE") {
                        let end = ContinuousClock().now

                        if (end - start) > .seconds(threshold) {
                            return "Failure"

                        } else {
                            return "Success"
                        }
                    }
                }

                return "Failure"
            }
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.value == "Success")
    }
}

// MARK: - PlatformOption Tests
extension SubprocessUnixTests {
    // Run this test with sudo
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsUserID() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let expectedUserID = uid_t(Int.random(in: 1000...2000))
        var platformOptions = PlatformOptions()
        platformOptions.userID = expectedUserID
        try await self.assertID(
            withArgument: "-u",
            platformOptions: platformOptions,
            isEqualTo: expectedUserID
        )
    }

    // Run this test with sudo
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsGroupID() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let expectedGroupID = gid_t(Int.random(in: 1000...2000))
        var platformOptions = PlatformOptions()
        platformOptions.groupID = expectedGroupID
        try await self.assertID(
            withArgument: "-g",
            platformOptions: platformOptions,
            isEqualTo: expectedGroupID
        )
    }

    // Run this test with sudo
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocssPlatformOptionsSuplimentaryGroups() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        var expectedGroups: Set<gid_t> = Set()
        for _ in 0..<Int.random(in: 5...10) {
            expectedGroups.insert(gid_t(Int.random(in: 1000...2000)))
        }
        var platformOptions = PlatformOptions()
        platformOptions.supplementaryGroups = Array(expectedGroups)
        let idResult = try await Subprocess.run(
            .path("/usr/bin/swift"),
            arguments: [getgroupsSwift.string],
            platformOptions: platformOptions,
            output: .string
        )
        #expect(idResult.terminationStatus.isSuccess)
        let ids = try #require(
            idResult.standardOutput
        ).split(separator: ",")
            .map { gid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))! }
        #expect(Set(ids) == expectedGroups)
    }

    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        ),
        .enabled(
            if: (try? Executable.name("ps").resolveExecutablePath(in: .inherit)) != nil,
            "This test requires ps (install procps package on Debian or RedHat Linux distros)"
        )
    )
    func testSubprocessPlatformOptionsProcessGroupID() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        var platformOptions = PlatformOptions()
        // Sets the process group ID to 0, which creates a new session
        platformOptions.processGroupID = 0
        let psResult = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid -p $$"],
            platformOptions: platformOptions,
            output: .string
        )
        #expect(psResult.terminationStatus.isSuccess)
        let resultValue = try #require(
            psResult.standardOutput
        )
        let match = try #require(try #/\s*PID\s*PGID\s*(?<pid>[\-]?[0-9]+)\s*(?<pgid>[\-]?[0-9]+)\s*/#.wholeMatch(in: resultValue), "ps output was in an unexpected format:\n\n\(resultValue)")
        // PGID should == PID
        #expect(match.output.pid == match.output.pgid)
    }

    @Test(
        .enabled(
            if: (try? Executable.name("ps").resolveExecutablePath(in: .inherit)) != nil,
            "This test requires ps (install procps package on Debian or RedHat Linux distros)"
        )
    )
    func testSubprocessPlatformOptionsCreateSession() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // platformOptions.createSession implies calls to setsid
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        // Check the proces ID (pid), pross group ID (pgid), and
        // controling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions,
            output: .string
        )
        try assertNewSessionCreated(with: psResult)
    }

    @Test func testTeardownSequence() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: [
                "-c",
                """
                set -e
                trap 'echo saw SIGQUIT;' SIGQUIT
                trap 'echo saw SIGTERM;' TERM
                trap 'echo saw SIGINT; exit 42;' INT
                while true; do sleep 1; done
                exit 2
                """,
            ],
            input: .none,
            error: .discarded
        ) { subprocess, standardOutput in
            return try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .milliseconds(200))
                    // Send shut down signal
                    await subprocess.teardown(using: [
                        .send(signal: .quit, allowedDurationToNextStep: .milliseconds(500)),
                        .send(signal: .terminate, allowedDurationToNextStep: .milliseconds(500)),
                        .send(signal: .interrupt, allowedDurationToNextStep: .milliseconds(1000)),
                    ])
                }
                group.addTask {
                    var outputs: [String] = []
                    for try await bit in standardOutput {
                        let bitString = bit._withUnsafeBytes { ptr in
                            return String(decoding: ptr, as: UTF8.self)
                        }.trimmingCharacters(in: .whitespacesAndNewlines)
                        if bitString.contains("\n") {
                            outputs.append(contentsOf: bitString.split(separator: "\n").map { String($0) })
                        } else {
                            outputs.append(bitString)
                        }
                    }
                    #expect(outputs == ["saw SIGQUIT", "saw SIGTERM", "saw SIGINT"])
                }
                try await group.waitForAll()
            }
        }
        #expect(result.terminationStatus == .exited(42))
    }
}

// MARK: - Misc
extension SubprocessUnixTests {
    @Test func testRunDetached() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let (readFd, writeFd) = try FileDescriptor.pipe()
        let pid = try runDetached(
            .path("/bin/bash"),
            arguments: ["-c", "echo $$"],
            output: writeFd
        )
        var status: Int32 = 0
        waitpid(pid.value, &status, 0)
        #expect(_was_process_exited(status) > 0)
        try writeFd.close()
        let data = try await readFd.readUntilEOF(upToLength: 10)
        let resultPID = try #require(
            String(data: Data(data), encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect("\(pid.value)" == resultPID)
        try readFd.close()
    }

    @Test func testTerminateProcess() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let stuckResult = try await Subprocess.run(
            // This will intentionally hang
            .path("/bin/cat"),
            error: .discarded
        ) { subprocess, standardOutput in
            // Make sure we can send signals to terminate the process
            try subprocess.send(signal: .terminate)
            for try await _ in standardOutput {}
        }
        guard case .unhandledException(let exception) = stuckResult.terminationStatus else {
            Issue.record("Wrong termination status repored: \(stuckResult.terminationStatus)")
            return
        }
        #expect(exception == Signal.terminate.rawValue)
    }

    @Test func testExitSignal() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }

        let signalsToTest: [CInt] = [SIGKILL, SIGTERM, SIGINT]
        for signal in signalsToTest {
            let result = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "kill -\(signal) $$"]
            )
            #expect(result.terminationStatus == .unhandledException(signal))
        }
    }

    @Test func testCanReliablyKillProcessesEvenWithSigmask() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        let result = try await withThrowingTaskGroup(
            of: TerminationStatus?.self,
            returning: TerminationStatus.self
        ) { group in
            group.addTask {
                return try await Subprocess.run(
                    .path("/bin/sh"),
                    arguments: ["-c", "trap 'echo no' TERM; while true; do sleep 1; done"]
                ).terminationStatus
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return nil
            }
            while let result = try await group.next() {
                group.cancelAll()
                if let result = result {
                    return result
                }
            }
            preconditionFailure("Task shold have returned a result")
        }
        #expect(result == .unhandledException(SIGKILL))
    }
}

// MARK: - Utils
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension SubprocessUnixTests {
    private func assertID(
        withArgument argument: String,
        platformOptions: PlatformOptions,
        isEqualTo expected: gid_t
    ) async throws {
        let idResult = try await Subprocess.run(
            .path("/usr/bin/id"),
            arguments: [argument],
            platformOptions: platformOptions,
            output: .string
        )
        #expect(idResult.terminationStatus.isSuccess)
        let id = try #require(idResult.standardOutput)
        #expect(
            id.trimmingCharacters(in: .whitespacesAndNewlines) == "\(expected)"
        )
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
internal func assertNewSessionCreated<Output: OutputProtocol>(
    with result: CollectedResult<
        StringOutput<UTF8>,
        Output
    >
) throws {
    #expect(result.terminationStatus.isSuccess)
    let psValue = try #require(
        result.standardOutput
    )
    let match = try #require(try #/\s*PID\s*PGID\s*TPGID\s*(?<pid>[\-]?[0-9]+)\s*(?<pgid>[\-]?[0-9]+)\s*(?<tpgid>[\-]?[0-9]+)\s*/#.wholeMatch(in: psValue), "ps output was in an unexpected format:\n\n\(psValue)")
    // If setsid() has been called successfully, we shold observe:
    // - pid == pgid
    // - tpgid <= 0
    let pid = try #require(Int(match.output.pid))
    let pgid = try #require(Int(match.output.pgid))
    let tpgid = try #require(Int(match.output.tpgid))
    #expect(pid == pgid)
    #expect(tpgid <= 0)
}

extension FileDescriptor {
    internal func readUntilEOF(upToLength maxLength: Int) async throws -> Data {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let dispatchIO = DispatchIO(
                type: .stream,
                fileDescriptor: self.rawValue,
                queue: .global()
            ) { error in
                if error != 0 {
                    continuation.resume(throwing: POSIXError(.init(rawValue: error) ?? .ENODEV))
                }
            }
            var buffer: Data = Data()
            dispatchIO.read(
                offset: 0,
                length: maxLength,
                queue: .global()
            ) { done, data, error in
                guard error == 0 else {
                    continuation.resume(throwing: POSIXError(.init(rawValue: error) ?? .ENODEV))
                    return
                }
                if let data = data {
                    buffer += Data(data)
                }
                if done {
                    dispatchIO.close()
                    continuation.resume(returning: buffer)
                }
            }
        }
    }
}

// MARK: - Performance Tests
extension SubprocessUnixTests {
    @Test func testConcurrentRun() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        // Launch as many processes as we can
        // Figure out the max open file limit
        let limitResult = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "ulimit -n"],
            output: .string
        )
        guard
            let limitString = limitResult
                .standardOutput?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let ulimit = Int(limitString)
        else {
            Issue.record("Failed to run  ulimit -n")
            return
        }
        // Constrain to an ultimate upper limit of 4096, since Docker containers can have limits like 2^20 which is a bit too high for this test.
        // Common defaults are 2560 for macOS and 1024 for Linux.
        let limit = min(ulimit, 4096)
        // Since we open two pipes per `run`, launch
        // limit / 4 subprocesses should reveal any
        // file descriptor leaks
        let maxConcurrent = limit / 4
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            let byteCount = 1000
            for _ in 0..<maxConcurrent {
                group.addTask {
                    let r = try await Subprocess.run(
                        .path("/bin/bash"),
                        arguments: [
                            "-sc", #"echo "$1" && echo "$1" >&2"#, "--", String(repeating: "X", count: byteCount),
                        ],
                        output: .data,
                        error: .data
                    )
                    guard r.terminationStatus.isSuccess else {
                        Issue.record("Unexpected exit \(r.terminationStatus) from \(r.processIdentifier)")
                        return
                    }
                    #expect(r.standardOutput.count == byteCount + 1, "\(r.standardOutput)")
                    #expect(r.standardError.count == byteCount + 1, "\(r.standardError)")
                }
                running += 1
                if running >= maxConcurrent / 4 {
                    try await group.next()
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func testCaptureLongStandardOutputAndError() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for _ in 0..<10 {
                group.addTask {
                    let r = try await Subprocess.run(
                        .path("/bin/bash"),
                        arguments: [
                            "-sc", #"echo "$1" && echo "$1" >&2"#, "--", String(repeating: "X", count: 100_000),
                        ],
                        output: .data,
                        error: .data
                    )
                    #expect(r.terminationStatus == .exited(0))
                    #expect(r.standardOutput.count == 100_001, "Standard output actual \(r.standardOutput)")
                    #expect(r.standardError.count == 100_001, "Standard error actual \(r.standardError)")
                }
                running += 1
                if running >= 1000 {
                    try await group.next()
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func testCancelProcessVeryEarlyOnStressTest() async throws {
        guard #available(SubprocessSpan , *) else {
            return
        }

        for i in 0..<100 {
            let terminationStatus = try await withThrowingTaskGroup(
                of: TerminationStatus?.self,
                returning: TerminationStatus.self
            ) { group in
                group.addTask {
                    return try await Subprocess.run(
                        .path("/bin/sleep"),
                        arguments: ["100000"]
                    ).terminationStatus
                }
                group.addTask {
                    let waitNS = UInt64.random(in: 0..<10_000_000)
                    try? await Task.sleep(nanoseconds: waitNS)
                    return nil
                }

                while let result = try await group.next() {
                    group.cancelAll()
                    if let result = result {
                        return result
                    }
                }
                preconditionFailure("this should be impossible, task should've returned a result")
            }
            #expect(terminationStatus == .unhandledException(SIGKILL), "iteration \(i)")
        }
    }
}

#endif  // canImport(Darwin) || canImport(Glibc)
