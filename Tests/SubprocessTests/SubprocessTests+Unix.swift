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
        // Simple test to make sure we can find a common utility
        let message = "Hello, world!"
        let result = try await Subprocess.run(
            .name("echo"),
            arguments: [message],
            output: .string(limit: 32)
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == message)
    }

    @Test func testExecutableNamedCannotResolve() async {
        do {
            _ = try await Subprocess.run(.name("do-not-exist"), output: .discarded)
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
        let expected = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(.path("/bin/pwd"), output: .string(limit: .max))
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let maybePath = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = try #require(maybePath)
        #expect(directory(path, isSameAs: expected))
    }

    @Test func testExecutableAtPathCannotResolve() async {
        do {
            _ = try await Subprocess.run(.path("/usr/bin/do-not-exist"), output: .discarded)
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
    @Test func testArgumentsArrayLiteral() async throws {
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "echo Hello World!"],
            output: .string(limit: 32)
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
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: .init(
                executablePathOverride: "apple",
                remainingValues: ["-c", "echo $0"]
            ),
            output: .string(limit: 32)
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output == "apple"
        )
    }

    @Test func testArgumentsFromArray() async throws {
        let arguments: [UInt8] = Array("Data Content\0".utf8)
        let result = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: .init(
                executablePathOverride: nil,
                remainingValues: [arguments]
            ),
            output: .string(limit: 32)
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
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "printenv PATH"],
            environment: .inherit,
            output: .string(limit: .max)
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
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "printenv HOME"],
            environment: .inherit.updating([
                "HOME": "/my/new/home"
            ]),
            output: .string(limit: 32)
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
        let result = try await Subprocess.run(
            .path("/usr/bin/printenv"),
            environment: .custom([
                "PATH": "/bin:/usr/bin"
            ]),
            output: .string(limit: 32)
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
        // By default we should use the working directory of the parent process
        let workingDirectory = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(
            .path("/bin/pwd"),
            workingDirectory: nil,
            output: .string(limit: .max)
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
        let workingDirectory = FilePath(
            FileManager.default.temporaryDirectory.path()
        )
        let result = try await Subprocess.run(
            .path("/bin/pwd"),
            workingDirectory: workingDirectory,
            output: .string(limit: .max)
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
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .none,
            output: .string(limit: 16)
        )
        #expect(catResult.terminationStatus.isSuccess)
        // We should have read exactly 0 bytes
        #expect(catResult.standardOutput == "")
    }

    @Test func testStringInput() async throws {
        let content = randomString(length: 64)
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .string(content, using: UTF8.self),
            output: .string(limit: 64)
        )
        #expect(catResult.terminationStatus.isSuccess)
        // Output should match the input content
        #expect(catResult.standardOutput == content)
    }

    @Test func testInputFileDescriptor() async throws {
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
        // Make sure we can read long text as AsyncSequence
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
                let currentChunk = chunk.withUnsafeBytes { Data($0) }
                buffer += currentChunk
            }
            return buffer
        }
        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }

    @Test func testInputAsyncSequenceCustomExecutionBody() async throws {
        // Make sure we can read long text as AsyncSequence
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
                let currentChunk = chunk.withUnsafeBytes { Data($0) }
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
        _ = echoResult.standardOutput  // this line should fatalError
    }
    #endif

    @Test func testCollectedOutput() async throws {
        let expected = try Data(contentsOf: URL(filePath: theMysteriousIsland.string))
        let echoResult = try await Subprocess.run(
            .path("/bin/cat"),
            arguments: [theMysteriousIsland.string],
            output: .data(limit: .max)
        )
        #expect(echoResult.terminationStatus.isSuccess)
        #expect(echoResult.standardOutput == expected)
    }

    @Test func testCollectedOutputExceedsLimit() async throws {
        do {
            _ = try await Subprocess.run(
                .path("/bin/cat"),
                arguments: [theMysteriousIsland.string],
                output: .string(limit: 16),
            )
            Issue.record("Expected to throw")
        } catch {
            guard let subprocessError = error as? SubprocessError else {
                Issue.record("Expected SubprocessError, got \(error)")
                return
            }
            #expect(subprocessError.code == .init(.outputBufferLimitExceeded(16)))
        }
    }

    @Test func testCollectedOutputFileDescriptor() async throws {
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

    @Test func testRedirectedOutputWithUnsafeBytes() async throws {
        // Make sure we can read long text redirected to AsyncSequence
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
                let currentChunk = chunk.withUnsafeBytes { Data($0) }
                buffer += currentChunk
            }
            return buffer
        }
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.value == expected)
    }

    #if SubprocessSpan
    @Test func testRedirectedOutputBytes() async throws {
        // Make sure we can read long text redirected to AsyncSequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            arguments: [theMysteriousIsland.string]
        ) { (execution: Execution, standardOutput: AsyncBufferSequence) -> Data in
            var buffer: Data = Data()
            for try await chunk in standardOutput {
                buffer += chunk.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: chunk.count) }
            }
            return buffer
        }
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.value == expected)
    }
    #endif

    @Test func testBufferOutput() async throws {
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
        // Make sure we can capture long text on standard error
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "cat \(theMysteriousIsland.string) 1>&2"],
            output: .discarded,
            error: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardError == expected)
    }
}

#if SubprocessSpan
extension Data {
    init(bytes: borrowing RawSpan) {
        let data = bytes.withUnsafeBytes {
            return Data(bytes: $0.baseAddress!, count: $0.count)
        }
        self = data
    }
}
#endif

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
    func testSubprocessPlatformOptionsSupplementaryGroups() async throws {
        var expectedGroups: Set<gid_t> = Set()
        for _ in 0..<Int.random(in: 5...10) {
            expectedGroups.insert(gid_t(Int.random(in: 1000...2000)))
        }
        var platformOptions = PlatformOptions()
        platformOptions.supplementaryGroups = Array(expectedGroups)
        let idResult = try await Subprocess.run(
            .name("swift"),
            arguments: [getgroupsSwift.string],
            platformOptions: platformOptions,
            output: .string(limit: .max),
            error: .string(limit: .max),
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
        var platformOptions = PlatformOptions()
        // Sets the process group ID to 0, which creates a new session
        platformOptions.processGroupID = 0
        let psResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "ps -o pid,pgid -p $$"],
            platformOptions: platformOptions,
            output: .string(limit: .max)
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
        // platformOptions.createSession implies calls to setsid
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        // Check the process ID (pid), process group ID (pgid), and
        // controlling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        try assertNewSessionCreated(with: psResult)
    }

    @Test(.requiresBash) func testTeardownSequence() async throws {
        let result = try await Subprocess.run(
            .name("bash"),
            arguments: [
                "-c",
                """
                set -e
                trap 'echo saw SIGQUIT;' QUIT
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
                    for try await line in standardOutput.lines() {
                        outputs.append(line.trimmingCharacters(in: .newlines))
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
    @Test func testTerminateProcess() async throws {
        let stuckResult = try await Subprocess.run(
            // This will intentionally hang
            .path("/bin/sleep"),
            arguments: ["infinity"],
            output: .discarded,
            error: .discarded
        ) { subprocess in
            // Make sure we can send signals to terminate the process
            try subprocess.send(signal: .terminate)
        }
        guard case .unhandledException(let exception) = stuckResult.terminationStatus else {
            Issue.record("Wrong termination status reported: \(stuckResult.terminationStatus)")
            return
        }
        #expect(exception == Signal.terminate.rawValue)
    }

    @Test func testExitSignal() async throws {
        let signalsToTest: [CInt] = [SIGKILL, SIGTERM, SIGINT]
        for signal in signalsToTest {
            let result = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "kill -\(signal) $$"],
                output: .discarded
            )
            #expect(result.terminationStatus == .unhandledException(signal))
        }
    }

    @Test func testCanReliablyKillProcessesEvenWithSigmask() async throws {
        let result = try await withThrowingTaskGroup(
            of: TerminationStatus?.self,
            returning: TerminationStatus.self
        ) { group in
            group.addTask {
                return try await Subprocess.run(
                    .path("/bin/sh"),
                    arguments: ["-c", "trap 'echo no' TERM; while true; do sleep 1; done"],
                    output: .string(limit: .max)
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
            preconditionFailure("Task should have returned a result")
        }
        #expect(result == .unhandledException(SIGKILL))
    }

    @Test func testLineSequence() async throws {
        typealias TestCase = (value: String, count: Int, newLine: String)
        enum TestCaseSize: CaseIterable {
            case large      // (1.0 ~ 2.0) * buffer size
            case medium     // (0.2 ~ 1.0) * buffer size
            case small      // Less than 16 characters
        }

        let newLineCharacters: [[UInt8]] = [
            [0x0A],             // Line feed
            [0x0B],             // Vertical tab
            [0x0C],             // Form feed
            [0x0D],             // Carriage return
            [0x0D, 0x0A],       // Carriage return + Line feed
            [0xC2, 0x85],       // New line
            [0xE2, 0x80, 0xA8], // Line Separator
            [0xE2, 0x80, 0xA9]  // Paragraph separator
        ]

        // Generate test cases
        func generateString(size: TestCaseSize) -> [UInt8] {
            // Basic Latin has the range U+0020 ... U+007E
            let range: ClosedRange<UInt8> = 0x20 ... 0x7E

            let length: Int
            switch size {
            case .large:
                length = Int(Double.random(in: 1.0 ..< 2.0) * Double(readBufferSize)) + 1
            case .medium:
                length = Int(Double.random(in: 0.2 ..< 1.0) * Double(readBufferSize)) + 1
            case .small:
                length = Int.random(in: 1 ..< 16)
            }

            var buffer: [UInt8] = Array(repeating: 0, count: length)
            for index in 0 ..< length {
                buffer[index] = UInt8.random(in: range)
            }
            // Buffer cannot be empty or a line with a \r ending followed by an empty one with a \n ending would be indistinguishable.
            // This matters for any line ending sequences where one line ending sequence is the prefix of another. \r and \r\n are the
            // only two which meet this criteria.
            precondition(!buffer.isEmpty)
            return buffer
        }

        // Generate at least 2 long lines that is longer than buffer size
        func generateTestCases(count: Int) -> [TestCase] {
            var targetSizes: [TestCaseSize] = TestCaseSize.allCases.flatMap {
                Array(repeating: $0, count: count / 3)
            }
            // Fill the remainder
            let remaining = count - targetSizes.count
            let rest = TestCaseSize.allCases.shuffled().prefix(remaining)
            targetSizes.append(contentsOf: rest)
            // Do a final shuffle to achieve random order
            targetSizes.shuffle()
            // Now generate test cases based on sizes
            var testCases: [TestCase] = []
            for size in targetSizes {
                let components = generateString(size: size)
                // Choose a random new line
                let newLine = newLineCharacters.randomElement()!
                let string = String(decoding: components + newLine, as: UTF8.self)
                testCases.append((
                    value: string,
                    count: components.count + newLine.count,
                    newLine: String(decoding: newLine, as: UTF8.self)
                ))
            }
            return testCases
        }

        func writeTestCasesToFile(_ testCases: [TestCase], at url: URL) throws {
            #if canImport(Darwin)
            FileManager.default.createFile(atPath: url.path(), contents: nil, attributes: nil)
            let fileHadle = try FileHandle(forWritingTo: url)
            for testCase in testCases {
                fileHadle.write(testCase.value.data(using: .utf8)!)
            }
            try fileHadle.close()
            #else
            var result = ""
            for testCase in testCases {
                result += testCase.value
            }
            try result.write(to: url, atomically: true, encoding: .utf8)
            #endif
        }

        let testCaseCount = 60
        let testFilePath = URL.temporaryDirectory.appending(path: "NewLines-\(UUID().uuidString).txt")
        if FileManager.default.fileExists(atPath: testFilePath.path()) {
            try FileManager.default.removeItem(at: testFilePath)
        }
        let testCases = generateTestCases(count: testCaseCount)
        try writeTestCasesToFile(testCases, at: testFilePath)

        _ = try await Subprocess.run(
            .path("/bin/cat"),
            arguments: [testFilePath.path()],
            error: .discarded
        ) { execution, standardOutput in
            var index = 0
            for try await line in standardOutput.lines(encoding: UTF8.self) {
                defer { index += 1 }
                try #require(index < testCases.count, "Received more lines than expected")
                #expect(
                    line == testCases[index].value,
                    """
                    Found mismatching line at index \(index)
                    Expected: [\(testCases[index].value)]
                      Actual: [\(line)]
                    Line Ending \(Array(testCases[index].newLine.utf8))
                    """
                )
            }
        }
        try FileManager.default.removeItem(at: testFilePath)
    }
}

// MARK: - Utils
extension FileDescriptor {
    /// Runs a closure and then closes the FileDescriptor, even if an error occurs.
    ///
    /// - Parameter body: The closure to run.
    ///   If the closure throws an error,
    ///   this method closes the file descriptor before it rethrows that error.
    ///
    /// - Returns: The value returned by the closure.
    ///
    /// If `body` throws an error
    /// or an error occurs while closing the file descriptor,
    /// this method rethrows that error.
    public func closeAfter<R>(_ body: () async throws -> R) async throws -> R {
        // No underscore helper, since the closure's throw isn't necessarily typed.
        let result: R
        do {
            result = try await body()
        } catch {
            _ = try? self.close() // Squash close error and throw closure's
            throw error
        }
        try self.close()
        return result
    }
}

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
            output: .string(limit: 32)
        )
        #expect(idResult.terminationStatus.isSuccess)
        let id = try #require(idResult.standardOutput)
        #expect(
            id.trimmingCharacters(in: .whitespacesAndNewlines) == "\(expected)"
        )
    }
}

internal func assertNewSessionCreated<Output: OutputProtocol>(
    with result: CollectedResult<
        StringOutput<UTF8>,
        Output
    >
) throws {
    try assertNewSessionCreated(
        terminationStatus: result.terminationStatus,
        output: #require(result.standardOutput)
    )
}

internal func assertNewSessionCreated(
    terminationStatus: TerminationStatus,
    output psValue: String
) throws {
    #expect(terminationStatus.isSuccess)

    let match = try #require(try #/\s*PID\s*PGID\s*TPGID\s*(?<pid>[\-]?[0-9]+)\s*(?<pgid>[\-]?[0-9]+)\s*(?<tpgid>[\-]?[0-9]+)\s*/#.wholeMatch(in: psValue), "ps output was in an unexpected format:\n\n\(psValue)")
    // If setsid() has been called successfully, we should observe:
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
    @Test(.requiresBash) func testConcurrentRun() async throws {
        // Launch as many processes as we can
        // Figure out the max open file limit
        let limitResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "ulimit -n"],
            output: .string(limit: 32)
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
                    // This invocation specifically requires bash semantics; sh (on FreeBSD at least) does not consistently support -s in this way
                    let r = try await Subprocess.run(
                        .name("bash"),
                        arguments: [
                            "-sc", #"echo "$1" && echo "$1" >&2"#, "--", String(repeating: "X", count: byteCount),
                        ],
                        output: .data(limit: .max),
                        error: .data(limit: .max)
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

    @Test(.requiresBash) func testCaptureLongStandardOutputAndError() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for _ in 0..<10 {
                group.addTask {
                    // This invocation specifically requires bash semantics; sh (on FreeBSD at least) does not consistently support -s in this way
                    let r = try await Subprocess.run(
                        .name("bash"),
                        arguments: [
                            "-sc", #"echo "$1" && echo "$1" >&2"#, "--", String(repeating: "X", count: 100_000),
                        ],
                        output: .data(limit: .max),
                        error: .data(limit: .max)
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
        for i in 0..<100 {
            let terminationStatus = try await withThrowingTaskGroup(
                of: TerminationStatus?.self,
                returning: TerminationStatus.self
            ) { group in
                group.addTask {
                    return try await Subprocess.run(
                        .path("/bin/sleep"),
                        arguments: ["100000"],
                        output: .string(limit: .max)
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
