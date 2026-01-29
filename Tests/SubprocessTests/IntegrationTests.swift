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

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

import Testing
import Dispatch
import Foundation
import TestResources
import _SubprocessCShims
@testable import Subprocess

@Suite("Subprocess Integration (End to End) Tests", .serialized)
struct SubprocessIntegrationTests {}

// MARK: - Executable Tests
extension SubprocessIntegrationTests {
    @Test func testExecutableNamed() async throws {
        let message = "Hello, world!"
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: .init(["/c", "echo", message])
        )
        #else
        let setup = TestSetup(
            executable: .name("echo"),
            arguments: .init([message])
        )
        #endif

        // Simple test to make sure we can find a common utility
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 32),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        // https://github.com/swiftlang/swift/issues/77235
        let output = result.standardOutput?
            .trimmingNewLineAndQuotes()
        // Windows echo includes quotes
        #expect(output == message)
    }

    @Test func testExecutableNamedCannotResolve() async {
        #if os(Windows)
        let expectedError = SubprocessError(
            code: .init(.executableNotFound("do-not-exist")),
            underlyingError: SubprocessError.WindowsError(rawValue: DWORD(ERROR_FILE_NOT_FOUND))
        )
        #else
        let expectedError = SubprocessError(
            code: .init(.executableNotFound("do-not-exist")),
            underlyingError: Errno(rawValue: ENOENT)
        )
        #endif

        await #expect(throws: expectedError) {
            _ = try await Subprocess.run(.name("do-not-exist"), output: .discarded)
        }
    }

    @Test func testExecutableAtPath() async throws {
        #if os(Windows)
        let cmdExe = ProcessInfo.processInfo.environment["COMSPEC"] ?? ProcessInfo.processInfo.environment["ComSpec"] ?? ProcessInfo.processInfo.environment["comspec"]

        let setup = TestSetup(
            executable: .path(FilePath(try #require(cmdExe))),
            arguments: .init(["/c", "cd"])
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/pwd"),
            arguments: .init()
        )
        #endif
        let expected = FileManager.default.currentDirectoryPath
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: .max),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        // https://github.com/swiftlang/swift/issues/77235
        let maybePath = result.standardOutput?
            .trimmingNewLineAndQuotes()
        let path = try #require(maybePath)
        #expect(directory(path, isSameAs: expected))
    }

    @Test func testExecutableAtPathCannotResolve() async {
        #if os(Windows)
        let fakePath = FilePath("D:\\does\\not\\exist")
        let expectedError = SubprocessError(
            code: .init(.executableNotFound("D:\\does\\not\\exist")),
            underlyingError: SubprocessError.WindowsError(rawValue: DWORD(ERROR_FILE_NOT_FOUND))
        )
        #else
        let fakePath = FilePath("/usr/bin/do-not-exist")
        let expectedError = SubprocessError(
            code: .init(.executableNotFound("/usr/bin/do-not-exist")),
            underlyingError: Errno(rawValue: ENOENT)
        )
        #endif

        await #expect(throws: expectedError) {
            _ = try await Subprocess.run(.path(fakePath), output: .discarded)
        }
    }

    #if !os(Windows)
    /// Integration test verifying that subprocess execution respects PATH ordering.
    @Test func testPathOrderingIsRespected() async throws {
        // Create temporary directories to simulate a PATH with multiple executables.
        let tempDir = FileManager.default.temporaryDirectory
        let firstDir = tempDir.appendingPathComponent("path-test-first-\(UUID().uuidString)")
        let secondDir = tempDir.appendingPathComponent("path-test-second-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: firstDir)
            try? FileManager.default.removeItem(at: secondDir)
        }

        // Create two different "test-executable" scripts that output different values.
        let executableName = "test-executable-\(UUID().uuidString)"

        // First
        let firstExecutable = firstDir.appendingPathComponent(executableName)
        try """
        #!/bin/sh
        echo "FIRST"
        """.write(to: firstExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstExecutable.path())

        // Second
        let secondExecutable = secondDir.appendingPathComponent(executableName)
        try """
        #!/bin/sh
        echo "SECOND"
        """.write(to: secondExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secondExecutable.path())

        // Run repeatedly to increase chance of catching any ordering issues.
        for _ in 0..<10 {
            let first = try await Subprocess.run(
                .name(executableName),
                environment: .inherit.updating([
                    "PATH": "\(firstDir.path()):\(secondDir.path())"
                ]),
                output: .string(limit: 8)
            )
            #expect(first.terminationStatus.isSuccess)
            #expect(first.standardOutput?.trimmingNewLineAndQuotes() == "FIRST")

            let second = try await Subprocess.run(
                .name(executableName),
                environment: .inherit.updating([
                    "PATH": "\(secondDir.path()):\(firstDir.path())"
                ]),
                output: .string(limit: 8)
            )
            #expect(second.terminationStatus.isSuccess)
            #expect(second.standardOutput?.trimmingNewLineAndQuotes() == "SECOND")
        }
    }
    #endif
}

// MARK: - Argument Tests
extension SubprocessIntegrationTests {
    @Test func testArgumentsArrayLiteral() async throws {
        let message = "Hello World!"
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo", message]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo \(message)"]
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 32),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        // https://github.com/swiftlang/swift/issues/77235
        let output = result.standardOutput?
            .trimmingNewLineAndQuotes()
        #expect(
            output == message
        )
    }

    @Test func testArgumentsOverride() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("powershell.exe"),
            arguments: .init(
                executablePathOverride: "apple",
                remainingValues: ["-Command", "[Environment]::GetCommandLineArgs()[0]"]
            )
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: .init(
                executablePathOverride: "apple",
                remainingValues: ["-c", "echo $0"]
            )
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 16),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        // https://github.com/swiftlang/swift/issues/77235
        let output = result.standardOutput?
            .trimmingNewLineAndQuotes()
        #expect(
            output == "apple"
        )
    }

    #if !os(Windows)
    // Windows does not support byte array arguments
    // This test will not compile on Windows
    @Test func testArgumentsFromBytes() async throws {
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
        // https://github.com/swiftlang/swift/issues/77235
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output == "Data Content"
        )
    }
    #endif
}

// MARK: - Environment Tests
extension SubprocessIntegrationTests {
    @Test func testEnvironmentInherit() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo %Path%"],
            environment: .inherit
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "printenv PATH"],
            environment: .inherit
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: .max),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        let pathValue = try #require(result.standardOutput)
        #if os(Windows)
        let expectedPathValue = ProcessInfo.processInfo.environment["Path"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ProcessInfo.processInfo.environment["path"]
        let expected = try #require(expectedPathValue)
        #else
        let expected = try #require(ProcessInfo.processInfo.environment["PATH"])
        #endif

        let pathList = Set(
            pathValue.split(separator: ":")
                .map { String($0).trimmingNewLineAndQuotes() }
        )
        let expectedList = Set(
            expected.split(separator: ":")
                .map { String($0).trimmingNewLineAndQuotes() }
        )
        // rdar://138670128
        // https://github.com/swiftlang/swift/issues/77235
        #expect(
            pathList == expectedList
        )
    }

    @Test func testEnvironmentInheritOverride() async throws {
        #if os(Windows)
        let path = "C:\\My\\New\\Home"
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo %HOMEPATH%"],
            environment: .inherit.updating([
                "HOMEPATH": path
            ])
        )
        #else
        let path = "/my/new/home"
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "printenv HOMEPATH"],
            environment: .inherit.updating([
                "HOMEPATH": path
            ])
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 32),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        // https://github.com/swiftlang/swift/issues/77235
        let output = result.standardOutput?
            .trimmingNewLineAndQuotes()
        #expect(
            output == path
        )
    }

    @Test func testEnvironmentInheritOverrideUnsetValue() async throws {
        #if os(Windows)
        // First insert our dummy environment variable
        "SubprocessTest".withCString(encodedAs: UTF16.self) { keyW in
            "value".withCString(encodedAs: UTF16.self) { valueW in
                SetEnvironmentVariableW(keyW, valueW)
            }
        }
        defer {
            "SubprocessTest".withCString(encodedAs: UTF16.self) { keyW in
                SetEnvironmentVariableW(keyW, nil)
            }
        }

        var setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo %SubprocessTest%"],
            environment: .inherit
        )
        #else
        // First insert our dummy environment variable
        setenv("SubprocessTest", "value", 1);
        defer {
            unsetenv("SubprocessTest")
        }

        var setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "printenv SubprocessTest"],
            environment: .inherit
        )
        #endif
        // First make sure child process actually inherited SubprocessTest
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 32),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        // https://github.com/swiftlang/swift/issues/77235
        let output = result.standardOutput?
            .trimmingNewLineAndQuotes()
        #expect(output == "value")

        // Now make sure we can remove `SubprocessTest`
        #if os(Windows)
        setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo %SubprocessTest%"],
            environment: .inherit
                .updating(["SubprocessTest": nil])
        )
        #else
        setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "printenv SubprocessTest"],
            environment: .inherit
                .updating(["SubprocessTest": nil])
        )
        #endif
        let result2 = try await _run(
            setup,
            input: .none,
            output: .string(limit: 32),
            error: .discarded
        )
        // The new echo/printenv should not find `SubprocessTest`
        #if os(Windows)
        #expect(result2.standardOutput?.trimmingNewLineAndQuotes() == "%SubprocessTest%")
        #else
        #expect(result2.terminationStatus == .exited(1))
        #endif
    }

    @Test(
        // Make sure we don't accidentally have this dummy value
        .enabled(if: ProcessInfo.processInfo.environment["SystemRoot"] != nil)
    )
    func testEnvironmentCustom() async throws {
        #if os(Windows)
        let pathValue = ProcessInfo.processInfo.environment["Path"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ProcessInfo.processInfo.environment["path"]
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "set"],
            environment: .custom([
                "Path": try #require(pathValue),
                "ComSpec": try #require(ProcessInfo.processInfo.environment["ComSpec"]),
            ])
        )
        #else
        let setup = TestSetup(
            executable: .path("/usr/bin/printenv"),
            arguments: [],
            environment: .custom([
                "PATH": "/bin:/usr/bin"
            ])
        )
        #endif

        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: .max),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        let output = try #require(
            result.standardOutput
        ).trimmingNewLineAndQuotes()
        #if os(Windows)
        // Make sure the newly launched process does
        // NOT have `SystemRoot` in environment
        #expect(!output.contains("SystemRoot"))
        #else
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        // rdar://138670128
        // https://github.com/swiftlang/swift/issues/77235
        #expect(
            output == "PATH=/bin:/usr/bin"
        )
        #endif
    }

    @Test func testEnvironmentCustomUpdating() async throws {
        #if os(Windows)
        let pathValue = ProcessInfo.processInfo.environment["Path"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ProcessInfo.processInfo.environment["path"]
        let customPath = "C:\\Custom\\Path"
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo %CUSTOMPATH%"],
            environment: .custom([
                "Path": try #require(pathValue),
                "ComSpec": try #require(ProcessInfo.processInfo.environment["ComSpec"]),
            ]).updating([
                "CUSTOMPATH": customPath
            ])
        )
        #else
        let customPath = "/custom/path"
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "printenv CUSTOMPATH"],
            environment: .custom([
                "PATH": "/bin:/usr/bin"
            ]).updating([
                "CUSTOMPATH": customPath
            ])
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 32),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        let output = result.standardOutput?
            .trimmingNewLineAndQuotes()
        #expect(
            output == customPath
        )
    }

    @Test func testEnvironmentCustomUpdatingUnsetValue() async throws {
        #if os(Windows)
        let pathValue = ProcessInfo.processInfo.environment["Path"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ProcessInfo.processInfo.environment["path"]
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo %REMOVEME%"],
            environment: .custom([
                "Path": try #require(pathValue),
                "ComSpec": try #require(ProcessInfo.processInfo.environment["ComSpec"]),
                "REMOVEME": "value",
            ]).updating([
                "REMOVEME": nil
            ])
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "printenv REMOVEME"],
            environment: .custom([
                "PATH": "/bin:/usr/bin",
                "REMOVEME": "value",
            ]).updating([
                "REMOVEME": nil
            ])
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 32),
            error: .discarded
        )
        #if os(Windows)
        #expect(result.standardOutput?.trimmingNewLineAndQuotes() == "%REMOVEME%")
        #else
        #expect(result.terminationStatus == .exited(1))
        #endif
    }

    #if !os(Windows)
    @Test func testEnvironmentRawBytesUpdating() async throws {
        let customValue = "rawbytes_value"
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "printenv CUSTOMVAR"],
            environment: .custom([
                Array("PATH=/bin:/usr/bin\0".utf8)
            ]).updating([
                "CUSTOMVAR": customValue
            ])
        )
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 32),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        let output = result.standardOutput?
            .trimmingNewLineAndQuotes()
        #expect(
            output == customValue
        )
    }

    @Test func testEnvironmentRawBytesUpdatingUnsetValue() async throws {
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "printenv REMOVEME"],
            environment: .custom([
                Array("PATH=/bin:/usr/bin\0".utf8),
                Array("REMOVEME=value\0".utf8),
            ]).updating([
                "REMOVEME": nil
            ])
        )
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 32),
            error: .discarded
        )
        #expect(result.terminationStatus == .exited(1))
    }

    @Test func testEnvironmentPathWithNonDirectoryPaths() async throws {
        // This test makes sure we can handle environment path value like
        // PATH="$PATH:$HOME/Desktop/.DS_Store"
        // posix_spawn returns ENOTDIR in this case because `.DS_Store` is a valid
        // file, but not a directory so it can't append the executable name.
        let setup = TestSetup(
            executable: .name("echo"),
            arguments: ["testEnvironmentPathWithNonDirectoryPaths"],
            environment: .inherit.updating([
                // /bin/ls is a valid file, but not directory
                "PATH": "/bin/ls"
            ])
        )

        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 64),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        #expect(result.standardOutput?.trimmingNewLineAndQuotes() == "testEnvironmentPathWithNonDirectoryPaths")
    }
    #endif
}

// MARK: - Working Directory Tests
extension SubprocessIntegrationTests {
    @Test func testWorkingDirectoryDefaultValue() async throws {
        // By default we should use the working directory of the parent process
        let workingDirectory = FileManager.default.currentDirectoryPath
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "cd"],
            workingDirectory: nil
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/pwd"),
            arguments: [],
            workingDirectory: nil
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: .max),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        // rdar://138670128
        // https://github.com/swiftlang/swift/issues/77235
        let output = result.standardOutput?
            .trimmingNewLineAndQuotes()
        let path = try #require(output)
        #expect(directory(path, isSameAs: workingDirectory))
    }

    @Test func testWorkingDirectoryCustomValue() async throws {
        let workingDirectory = FilePath(
            FileManager.default.temporaryDirectory._fileSystemPath
        )
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "cd"],
            workingDirectory: workingDirectory
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/pwd"),
            arguments: [],
            workingDirectory: workingDirectory
        )
        #endif

        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: .max),
            error: .discarded
        )
        #expect(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        let resultPath = try #require(result.standardOutput)
            .trimmingNewLineAndQuotes()
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

    @Test func testWorkingDirectoryInvalidValue() async throws {
        #if os(Windows)
        let invalidPath: FilePath = FilePath(#"X:\Does\Not\Exist"#)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "cd"],
            workingDirectory: invalidPath
        )
        let expectedError = SubprocessError(
            code: .init(.failedToChangeWorkingDirectory(#"X:\Does\Not\Exist"#)),
            underlyingError: SubprocessError.WindowsError(rawValue: DWORD(ERROR_DIRECTORY))
        )
        #else
        let invalidPath: FilePath = FilePath("/does/not/exist")
        let setup = TestSetup(
            executable: .path("/bin/pwd"),
            arguments: [],
            workingDirectory: invalidPath
        )
        let expectedError = SubprocessError(
            code: .init(.failedToChangeWorkingDirectory("/does/not/exist")),
            underlyingError: Errno(rawValue: ENOENT)
        )
        #endif

        await #expect(throws: expectedError) {
            _ = try await _run(setup, input: .none, output: .string(limit: .max), error: .discarded)
        }
    }
}

// MARK: - Input Tests
extension SubprocessIntegrationTests {
    @Test func testNoInput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "more"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        let catResult = try await _run(
            setup,
            input: .none,
            output: .string(limit: 16),
            error: .discarded
        )
        #expect(catResult.terminationStatus.isSuccess)
        // We should have read exactly 0 bytes
        #expect(catResult.standardOutput == "")
    }

    @Test func testStringInput() async throws {
        let content = randomString(length: 100_000)
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("powershell.exe"),
            arguments: [
                "-Command",
                "while (($c = [Console]::In.Read()) -ne -1) { [Console]::Out.Write([char]$c);  [Console]::Out.Flush() }",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        let catResult = try await _run(
            setup,
            input: .string(content, using: UTF8.self),
            output: .string(limit: .max),
            error: .discarded
        )
        #expect(catResult.terminationStatus.isSuccess)
        // Output should match the input content
        #expect(
            catResult.standardOutput?.trimmingNewLineAndQuotes() == content
        )
    }

    @Test func testArrayInput() async throws {
        let content = randomString(length: 64)
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "more"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        let catResult = try await _run(
            setup,
            input: .array(Array(content.utf8)),
            output: .string(limit: .max),
            error: .discarded
        )
        #expect(catResult.terminationStatus.isSuccess)
        // Output should match the input content
        #expect(
            catResult.standardOutput?.trimmingNewLineAndQuotes() == content.trimmingNewLineAndQuotes()
        )
    }

    #if SubprocessFoundation
    @Test func testFileDescriptorInput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        // Make sure we can read long text from standard input
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let text: FileDescriptor = try .open(
            theMysteriousIsland,
            .readOnly
        )
        let cat = try await _run(
            setup,
            input: .fileDescriptor(text, closeAfterSpawningProcess: true),
            output: .data(limit: 2048 * 1024),
            error: .discarded
        )
        #expect(cat.terminationStatus.isSuccess)
        // Make sure we read all bytes
        #expect(cat.standardOutput == expected)
    }
    #endif

    #if SubprocessFoundation
    @Test func testDataInput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await _run(
            setup,
            input: .data(expected),
            output: .data(limit: 2048 * 1024),
            error: .discarded
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardOutput.count == expected.count)
        #expect(Array(catResult.standardOutput) == Array(expected))
    }
    #endif

    #if SubprocessSpan
    @Test func testSpanInput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let ptr = expected.withUnsafeBytes { return $0 }
        let span: Span<UInt8> = Span(_unsafeBytes: ptr)
        let catResult = try await _run(
            setup,
            input: span,
            output: .data(limit: 2048 * 1024),
            error: .discarded
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardOutput.count == expected.count)
        #expect(Array(catResult.standardOutput) == Array(expected))
    }
    #endif

    #if SubprocessFoundation
    @Test func testAsyncSequenceInput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        let chunkSize = 4096
        // Make sure we can read long text as AsyncSequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let stream: AsyncStream<Data> = AsyncStream { continuation in
            DispatchQueue.global().async {
                var currentStart = 0
                while currentStart + chunkSize < expected.count {
                    continuation.yield(expected[currentStart..<currentStart + chunkSize])
                    currentStart += chunkSize
                }
                if expected.count - currentStart > 0 {
                    continuation.yield(expected[currentStart..<expected.count])
                }
                continuation.finish()
            }
        }
        let catResult = try await _run(
            setup,
            input: .sequence(stream),
            output: .data(limit: 2048 * 1024),
            error: .discarded
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardOutput == expected)
    }
    #endif

    @Test func testStandardInputWriterInput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let result = try await _run(
            setup,
            error: .discarded
        ) { execution, standardInputWriter, standardOutput in
            async let buffer = {
                var _buffer = Data()
                for try await chunk in standardOutput {
                    let currentChunk = chunk.withUnsafeBytes { Data($0) }
                    _buffer += currentChunk
                }
                return _buffer
            }()

            _ = try await standardInputWriter.write(Array(expected))
            try await standardInputWriter.finish()

            return try await buffer
        }
        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }

    @Test func testNoInputTriggersEOF() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("powershell.exe"),
            arguments: [
                "-Command",
                """
                $in = [Console]::In
                while (($line = $in.ReadLine()) -ne $null) {
                    Write-Output "unexpected input $line"
                }
                exit 0
                """,
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: [
                "-c",
                """
                set -eu
                while read -r line; do
                    echo "unexpected input $line"
                done
                exit 0
                """,
            ]
        )
        #endif

        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: .max),
            error: .string(limit: .max)
        )
        #expect(result.terminationStatus.isSuccess)
        #expect(result.standardOutput?.trimmingNewLineAndQuotes().isEmpty == true)
        #if !os(Windows)
        // cmd.exe emits an error
        #expect(result.standardError?.trimmingNewLineAndQuotes().isEmpty == true)
        #endif
    }
}

// MARK: - Output Tests
extension SubprocessIntegrationTests {
    @Test func testDiscardedOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo hello world"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo hello world"]
        )
        #endif
        let echoResult = try await _run(
            setup,
            input: .none,
            output: .discarded,
            error: .discarded
        )
        #expect(echoResult.terminationStatus.isSuccess)
    }

    #if SubprocessFoundation
    @Test func testStringOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await _run(
            setup,
            input: .data(expected),
            output: .string(limit: 2048 * 1024, encoding: UTF8.self),
            error: .discarded
        )
        let output = try #require(
            catResult.standardOutput?.trimmingNewLineAndQuotes()
        )
        #expect(
            output
                == String(
                    decoding: expected,
                    as: Unicode.UTF8.self
                ).trimmingNewLineAndQuotes()
        )
    }
    #endif

    @Test func testStringOutputExceedsLimit() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
                theMysteriousIsland.string,
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: [theMysteriousIsland.string]
        )
        #endif

        let expectedError = SubprocessError(
            code: .init(.outputBufferLimitExceeded(16)),
            underlyingError: nil
        )

        await #expect(throws: expectedError) {
            _ = try await _run(
                setup,
                input: .none,
                output: .string(limit: 16),
                error: .discarded
            )
        }
    }

    #if SubprocessFoundation
    @Test func testBytesOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await _run(
            setup,
            input: .data(expected),
            output: .bytes(limit: 2048 * 1024),
            error: .discarded
        )
        #expect(
            catResult.standardOutput == Array(expected)
        )
    }
    #endif

    @Test func testBytesOutputExceedsLimit() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
                theMysteriousIsland.string,
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: [theMysteriousIsland.string]
        )
        #endif

        let expectedError = SubprocessError(
            code: .init(.outputBufferLimitExceeded(16)),
            underlyingError: nil
        )

        await #expect(throws: expectedError) {
            _ = try await _run(
                setup,
                input: .none,
                output: .bytes(limit: 16),
                error: .discarded
            )
        }
    }

    @Test func testFileDescriptorOutput() async throws {
        let expected = randomString(length: 32)
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo \(expected)"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo \(expected)"]
        )
        #endif

        let outputFilePath = FilePath(FileManager.default.temporaryDirectory._fileSystemPath)
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
        let echoResult = try await outputFile.closeAfter {
            let echoResult = try await _run(
                setup,
                input: .none,
                output: .fileDescriptor(
                    outputFile,
                    closeAfterSpawningProcess: false
                ),
                error: .discarded
            )
            #expect(echoResult.terminationStatus.isSuccess)
            return echoResult
        }
        let outputData: Data = try Data(
            contentsOf: URL(filePath: outputFilePath.string)
        )
        let output = try #require(
            String(data: outputData, encoding: .utf8)
        ).trimmingNewLineAndQuotes()
        #expect(echoResult.terminationStatus.isSuccess)
        #expect(output == expected)
    }

    @Test(.disabled("Cannot ever safely call unbalanced close() on the same fd")) func testFileDescriptorOutputAutoClose() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo Hello World"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo Hello World"]
        )
        #endif
        let outputFilePath = FilePath(FileManager.default.temporaryDirectory._fileSystemPath)
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
        let echoResult = try await _run(
            setup,
            input: .none,
            output: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: true
            ),
            error: .discarded
        )
        #expect(echoResult.terminationStatus.isSuccess)
        // Make sure the file descriptor is already closed
        #expect(throws: Errno.badFileDescriptor) {
            try outputFile.close()
        }
    }

    #if SubprocessFoundation
    @Test func testDataOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: []
        )
        #endif
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await _run(
            setup,
            input: .data(expected),
            output: .data(limit: 2048 * 1024),
            error: .discarded
        )
        #expect(
            catResult.standardOutput == expected
        )
    }

    @Test func testDataOutputExceedsLimit() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x*",
                theMysteriousIsland.string,
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: [theMysteriousIsland.string]
        )
        #endif

        let expectedError = SubprocessError(
            code: .init(.outputBufferLimitExceeded(16)),
            underlyingError: nil
        )

        await #expect(throws: expectedError) {
            _ = try await _run(
                setup,
                input: .none,
                output: .data(limit: 16),
                error: .discarded
            )
        }
    }
    #endif

    #if SubprocessFoundation
    @Test func testStringErrorOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x* 1>&2",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "cat 1>&2"]
        )
        #endif
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await _run(
            setup,
            input: .data(expected),
            output: .discarded,
            error: .string(limit: 2048 * 1024, encoding: UTF8.self)
        )
        let output = try #require(
            catResult.standardError?.trimmingNewLineAndQuotes()
        )
        #expect(
            output
                == String(
                    decoding: expected,
                    as: Unicode.UTF8.self
                ).trimmingNewLineAndQuotes()
        )
    }
    #endif

    @Test func testStringErrorOutputExceedsLimit() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x* \(theMysteriousIsland.string) 1>&2",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "cat \(theMysteriousIsland.string) 1>&2"]
        )
        #endif

        let expectedError = SubprocessError(
            code: .init(.outputBufferLimitExceeded(16)),
            underlyingError: nil
        )

        await #expect(throws: expectedError) {
            _ = try await _run(
                setup,
                input: .none,
                output: .discarded,
                error: .string(limit: 16)
            )
        }
    }

    #if SubprocessFoundation
    @Test func testBytesErrorOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x* 1>&2",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "cat 1>&2"]
        )
        #endif
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await _run(
            setup,
            input: .data(expected),
            output: .discarded,
            error: .bytes(limit: 2048 * 1024)
        )
        #expect(
            catResult.standardError == Array(expected)
        )
    }
    #endif

    @Test func testBytesErrorOutputExceedsLimit() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x* \(theMysteriousIsland.string) 1>&2",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "cat \(theMysteriousIsland.string) 1>&2"]
        )
        #endif

        let expectedError = SubprocessError(
            code: .init(.outputBufferLimitExceeded(16)),
            underlyingError: nil
        )

        await #expect(throws: expectedError) {
            _ = try await _run(
                setup,
                input: .none,
                output: .discarded,
                error: .bytes(limit: 16)
            )
        }
    }

    @Test func testFileDescriptorErrorOutput() async throws {
        let expected = randomString(length: 32)
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo \(expected) 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo \(expected) 1>&2"]
        )
        #endif

        let outputFilePath = FilePath(FileManager.default.temporaryDirectory._fileSystemPath)
            .appending("TestError.out")
        if FileManager.default.fileExists(atPath: outputFilePath.string) {
            try FileManager.default.removeItem(atPath: outputFilePath.string)
        }
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let echoResult = try await outputFile.closeAfter {
            let echoResult = try await _run(
                setup,
                input: .none,
                output: .discarded,
                error: .fileDescriptor(
                    outputFile,
                    closeAfterSpawningProcess: false
                )
            )
            #expect(echoResult.terminationStatus.isSuccess)
            return echoResult
        }
        let outputData: Data = try Data(
            contentsOf: URL(filePath: outputFilePath.string)
        )
        let output = try #require(
            String(data: outputData, encoding: .utf8)
        ).trimmingNewLineAndQuotes()
        #expect(echoResult.terminationStatus.isSuccess)
        #expect(output == expected)
    }

    @Test(.disabled("Cannot ever safely call unbalanced close() on the same fd")) func testFileDescriptorErrorOutputAutoClose() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo Hello World", "1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo Hello World", "1>&2"]
        )
        #endif
        let outputFilePath = FilePath(FileManager.default.temporaryDirectory._fileSystemPath)
            .appending("TestError.out")
        if FileManager.default.fileExists(atPath: outputFilePath.string) {
            try FileManager.default.removeItem(atPath: outputFilePath.string)
        }
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let echoResult = try await _run(
            setup,
            input: .none,
            output: .discarded,
            error: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: true
            )
        )
        #expect(echoResult.terminationStatus.isSuccess)
        // Make sure the file descriptor is already closed
        #expect(throws: Errno.badFileDescriptor) {
            try outputFile.close()
        }
    }

    @Test func testFileDescriptorOutputErrorToSameFile() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo Hello Stdout & echo Hello Stderr 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo Hello Stdout; echo Hello Stderr 1>&2"]
        )
        #endif

        let outputFilePath = FilePath(FileManager.default.temporaryDirectory._fileSystemPath)
            .appending("TestOutputErrorCombined.out")
        if FileManager.default.fileExists(atPath: outputFilePath.string) {
            try FileManager.default.removeItem(atPath: outputFilePath.string)
        }
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let echoResult = try await _run(
            setup,
            input: .none,
            output: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: true
            ),
            error: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: true
            )
        )
        #expect(echoResult.terminationStatus.isSuccess)
        let outputData: Data = try Data(
            contentsOf: URL(filePath: outputFilePath.string)
        )
        let output = try #require(
            String(data: outputData, encoding: .utf8)
        ).trimmingNewLineAndQuotes()
        #expect(echoResult.terminationStatus.isSuccess)
        #expect(output.contains("Hello Stdout"))
        #expect(output.contains("Hello Stderr"))
    }

    #if SubprocessFoundation
    @Test func testDataErrorOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x* 1>&2",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "cat 1>&2"]
        )
        #endif
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await _run(
            setup,
            input: .data(expected),
            output: .discarded,
            error: .data(limit: 2048 * 1024)
        )
        #expect(
            catResult.standardError == expected
        )
    }

    @Test func testDataErrorOutputExceedsLimit() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x* \(theMysteriousIsland.string) 1>&2",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "cat \(theMysteriousIsland.string) 1>&2"]
        )
        #endif

        let expectedError = SubprocessError(
            code: .init(.outputBufferLimitExceeded(16)),
            underlyingError: nil
        )

        await #expect(throws: expectedError) {
            _ = try await _run(
                setup,
                input: .none,
                output: .discarded,
                error: .data(limit: 16)
            )
        }
    }
    #endif

    @Test func testStreamingErrorOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x* 1>&2",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "cat 1>&2"]
        )
        #endif
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let result = try await _run(
            setup,
            output: .discarded
        ) { execution, standardInputWriter, standardError in
            async let buffer = {
                var _buffer = Data()
                for try await chunk in standardError {
                    let currentChunk = chunk.withUnsafeBytes { Data($0) }
                    _buffer += currentChunk
                }
                return _buffer
            }()

            _ = try await standardInputWriter.write(Array(expected))
            try await standardInputWriter.finish()

            return try await buffer
        }
        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }

    @Test func stressTestWithLittleOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo x & echo y 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo x; echo y 1>&2;"]
        )
        #endif

        for _ in 0..<128 {
            let result = try await _run(
                setup,
                input: .none,
                output: .string(limit: 4),
                error: .string(limit: 4)
            )
            #expect(result.terminationStatus.isSuccess)
            #expect(result.standardOutput?.trimmingNewLineAndQuotes() == "x")
            #expect(result.standardError?.trimmingNewLineAndQuotes() == "y")
        }
    }

    @Test func stressTestWithLongOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo x & echo y 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo x; echo y 1>&2;"]
        )
        #endif

        for _ in 0..<128 {
            let result = try await _run(
                setup,
                input: .none,
                output: .string(limit: 4),
                error: .string(limit: 4)
            )
            #expect(result.terminationStatus.isSuccess)
            #expect(result.standardOutput?.trimmingNewLineAndQuotes() == "x")
            #expect(result.standardError?.trimmingNewLineAndQuotes() == "y")
        }
    }

    @Test func testInheritingOutputAndError() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo Standard Output Testing & echo Standard Error Testing 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo Standard Output Testing; echo Standard Error Testing 1>&2;"]
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .fileDescriptor(.standardOutput, closeAfterSpawningProcess: false),
            error: .fileDescriptor(.standardError, closeAfterSpawningProcess: false)
        )
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func stressTestDiscardedOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("powershell.exe"),
            arguments: [
                "-Command",
                """
                $size = 1MB
                $data = New-Object byte[] $size
                [Console]::OpenStandardOutput().Write($data, 0, $data.Length)
                [Console]::OpenStandardError().Write($data, 0, $data.Length)
                """,
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: [
                "-c",
                "/bin/dd if=/dev/zero bs=\(1024*1024) count=1; /bin/dd >&2 if=/dev/zero bs=\(1024*1024) count=1;",
            ]
        )
        #endif
        let result = try await _run(setup, input: .none, output: .discarded, error: .discarded)
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testCaptureEmptyOutputError() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", ""]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", ""]
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: .max),
            error: .string(limit: .max)
        )
        #expect(result.terminationStatus.isSuccess)
        #expect(result.standardOutput?.trimmingNewLineAndQuotes() == "")
        #expect(result.standardError?.trimmingNewLineAndQuotes() == "")
    }

    @Test func testCustomStreamingBufferSize() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                """
                @echo off
                echo one
                :loop
                timeout /t 1 >nul
                goto loop
                """,
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: [
                "-c",
                """
                echo one;
                while true; do sleep 1; done
                """,
            ]
        )
        #endif
        _ = try await _run(
            setup,
            input: .none,
            error: .discarded,
            preferredBufferSize: 1
        ) { execution, standardOutput in
            for try await line in standardOutput.lines() {
                // If we use default buffer size this test will hang
                // because Subprocess is stuck on waiting 16k worth of
                // output when there are only 3.
                #expect(line.trimmingNewLineAndQuotes() == "one")
                // Kill the child process since it intentionally hang
                #if os(Windows)
                try execution.terminate(withExitCode: 0)
                #else
                try execution.send(signal: .terminate)
                #endif
            }
        }
    }

    @Test func testCombinedStringOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo Hello Stdout & echo Hello Stderr 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo Hello Stdout; echo Hello Stderr 1>&2"]
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .string(limit: 64),
            error: .combineWithOutput
        )
        #expect(result.terminationStatus.isSuccess)
        let output = try #require(result.standardOutput)
        #expect(output.contains("Hello Stdout"))
        #expect(output.contains("Hello Stderr"))
    }

    @Test func testCombinedBytesOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo Hello Stdout & echo Hello Stderr 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo Hello Stdout; echo Hello Stderr 1>&2"]
        )
        #endif
        let result = try await _run(
            setup,
            input: .none,
            output: .bytes(limit: 64),
            error: .combineWithOutput
        )
        #expect(result.terminationStatus.isSuccess)
        #expect(
            result.standardOutput.contains(
                "Hello Stdout".byteArray(using: UTF8.self).unsafelyUnwrapped
            )
        )
        #expect(
            result.standardOutput.contains(
                "Hello Stderr".byteArray(using: UTF8.self).unsafelyUnwrapped
            )
        )
    }

    @Test func testCombinedFileDescriptorOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo Hello Stdout & echo Hello Stderr 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo Hello Stdout; echo Hello Stderr 1>&2"]
        )
        #endif

        let outputFilePath = FilePath(FileManager.default.temporaryDirectory._fileSystemPath)
            .appending("CombinedTest.out")
        defer {
            try? FileManager.default.removeItem(atPath: outputFilePath.string)
        }
        if FileManager.default.fileExists(atPath: outputFilePath.string) {
            try FileManager.default.removeItem(atPath: outputFilePath.string)
        }
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let echoResult = try await outputFile.closeAfter {
            let echoResult = try await _run(
                setup,
                input: .none,
                output: .fileDescriptor(
                    outputFile,
                    closeAfterSpawningProcess: false
                ),
                error: .combineWithOutput
            )
            #expect(echoResult.terminationStatus.isSuccess)
            return echoResult
        }
        let outputData: Data = try Data(
            contentsOf: URL(filePath: outputFilePath.string)
        )
        let output = try #require(
            String(data: outputData, encoding: .utf8)
        ).trimmingNewLineAndQuotes()
        #expect(echoResult.terminationStatus.isSuccess)
        #expect(output.contains("Hello Stdout"))
        #expect(output.contains("Hello Stderr"))
    }

    #if SubprocessFoundation
    @Test func testCombinedDataOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo Hello Stdout & echo Hello Stderr 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo Hello Stdout; echo Hello Stderr 1>&2"]
        )
        #endif
        let catResult = try await _run(
            setup,
            input: .none,
            output: .data(limit: 64),
            error: .combineWithOutput
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(
            catResult.standardOutput.contains("Hello Stdout".data(using: .utf8).unsafelyUnwrapped)
        )
        #expect(
            catResult.standardOutput.contains("Hello Stderr".data(using: .utf8).unsafelyUnwrapped)
        )
    }
    #endif // SubprocessFoundation

    @Test func testCombinedStreamingOutput() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "echo Hello Stdout & echo Hello Stderr 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "echo Hello Stdout; echo Hello Stderr 1>&2"]
        )
        #endif

        _ = try await _run(
            setup,
            input: .none,
            error: .combineWithOutput
        ) { execution, standardOutput in
            var output: String = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            #expect(output.contains("Hello Stdout"))
            #expect(output.contains("Hello Stderr"))
        }
    }
}

// MARK: - Other Tests
extension SubprocessIntegrationTests {
    @Test func testTerminateProcess() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("powershell.exe"),
            arguments: ["-Command", "Start-Sleep -Seconds 9999"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/usr/bin/tail"),
            arguments: ["-f", "/dev/null"]
        )
        #endif
        let stuckResult = try await _run(
            // This will intentionally hang
            setup,
            input: .none,
            error: .discarded
        ) { subprocess, standardOutput in
            // Make sure we can send signals to terminate the process
            #if os(Windows)
            try subprocess.terminate(withExitCode: 99)
            #else
            try subprocess.send(signal: .terminate)
            #endif
            for try await _ in standardOutput {}
        }

        #if os(Windows)
        guard case .exited(let exitCode) = stuckResult.terminationStatus else {
            Issue.record("Wrong termination status reported: \(stuckResult.terminationStatus)")
            return
        }
        #expect(exitCode == 99)
        #else
        guard case .unhandledException(let exception) = stuckResult.terminationStatus else {
            Issue.record("Wrong termination status reported: \(stuckResult.terminationStatus)")
            return
        }
        #expect(exception == Signal.terminate.rawValue)
        #endif
    }

    @Test func testLineSequence() async throws {
        typealias TestCase = (value: String, count: Int, newLine: String)
        enum TestCaseSize: CaseIterable {
            case large // (1.0 ~ 2.0) * buffer size
            case medium // (0.2 ~ 1.0) * buffer size
            case small // Less than 16 characters
        }

        let newLineCharacters: [[UInt8]] = [
            [0x0A], // Line feed
            [0x0B], // Vertical tab
            [0x0C], // Form feed
            [0x0D], // Carriage return
            [0x0D, 0x0A], // Carriage return + Line feed
            [0xC2, 0x85], // New line
            [0xE2, 0x80, 0xA8], // Line Separator
            [0xE2, 0x80, 0xA9], // Paragraph separator
        ]

        // Generate test cases
        func generateString(size: TestCaseSize) -> [UInt8] {
            // Basic Latin has the range U+0020 ... U+007E
            let range: ClosedRange<UInt8> = 0x20...0x7E

            let length: Int
            switch size {
            case .large:
                length = Int(Double.random(in: 1.0..<2.0) * Double(readBufferSize)) + 1
            case .medium:
                length = Int(Double.random(in: 0.2..<1.0) * Double(readBufferSize)) + 1
            case .small:
                length = Int.random(in: 1..<16)
            }

            var buffer: [UInt8] = Array(repeating: 0, count: length)
            for index in 0..<length {
                buffer[index] = UInt8.random(in: range)
            }
            // Buffer cannot be empty or a line with a \r ending followed by an empty one with a \n ending would be indistinguishable.
            // This matters for any line ending sequences where one line ending sequence is the prefix of another. \r and \r\n are the
            // only two which meet this criteria.
            precondition(!buffer.isEmpty)
            return buffer
        }

        // Generate at least 2 long lines that is longer than buffer size
        func generateTestCases(count: Int) throws -> [TestCase] {
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
                let newLine = try #require(newLineCharacters.randomElement())
                let string = String(decoding: components + newLine, as: UTF8.self)
                testCases.append(
                    (
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
                fileHadle.write(Data(testCase.value.utf8))
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
        let testCases = try generateTestCases(count: testCaseCount)
        try writeTestCasesToFile(testCases, at: testFilePath)

        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: [
                "/c",
                "findstr x* \(testFilePath._fileSystemPath)",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/cat"),
            arguments: [testFilePath._fileSystemPath]
        )
        #endif

        _ = try await _run(
            setup,
            input: .none,
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

    #if SubprocessFoundation
    @Test func testCaptureLongStandardOutputAndError() async throws {
        let string = String(repeating: "X", count: 100_000)
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("powershell.exe"),
            arguments: [
                "-Command",
                "while (($c = [Console]::In.Read()) -ne -1) { [Console]::Out.Write([char]$c); [Console]::Error.Write([char]$c); [Console]::Out.Flush(); [Console]::Error.Flush() }",
            ]
        )
        #else
        let setup = TestSetup(
            executable: .path("/usr/bin/tee"),
            arguments: ["/dev/stderr"]
        )
        #endif
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let r = try await _run(
                        setup,
                        input: .string(string),
                        output: .data(limit: .max),
                        error: .data(limit: .max)
                    )
                    #expect(r.terminationStatus == .exited(0))
                    #expect(r.standardOutput.count == 100_000, "Standard output actual \(r.standardOutput.count)")
                    #expect(r.standardError.count == 100_000, "Standard error actual \(r.standardError.count)")
                }
                try await group.next()
            }
            try await group.waitForAll()
        }
    }
    #endif

    @Test func stressTestCancelProcessVeryEarlyOn() async throws {

        #if os(Windows)
        let setup = TestSetup(
            executable: .name("powershell.exe"),
            arguments: ["-Command", "Start-Sleep -Seconds 9999"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/usr/bin/tail"),
            arguments: ["-f", "/dev/null"]
        )
        #endif
        for i in 0..<100 {
            let terminationStatus = try await withThrowingTaskGroup(
                of: TerminationStatus?.self,
                returning: TerminationStatus.self
            ) { group in
                group.addTask {
                    var platformOptions = PlatformOptions()
                    platformOptions.teardownSequence = []

                    return try await _run(
                        setup,
                        platformOptions: platformOptions,
                        input: .none,
                        output: .discarded,
                        error: .discarded
                    ).terminationStatus
                }
                group.addTask {
                    let waitNS = UInt64.random(in: 0..<10_000_000)
                    try? await Task.sleep(nanoseconds: waitNS)
                    return nil
                }

                while let result = try await group.next() {
                    if let result = result {
                        return result
                    } else {
                        group.cancelAll()
                    }
                }
                preconditionFailure("this should be impossible, task should've returned a result")
            }
            #if !os(Windows)
            #expect(
                terminationStatus == .unhandledException(SIGKILL) || terminationStatus == .exited(SIGKILL),
                "iteration \(i)"
            )
            #endif
        }
    }

    @Test func testExitCode() async throws {
        for exitCode in UInt8.min..<UInt8.max {
            #if os(Windows)
            let setup = TestSetup(
                executable: .name("cmd.exe"),
                arguments: ["/c", "exit \(exitCode)"]
            )
            #else
            let setup = TestSetup(
                executable: .path("/bin/sh"),
                arguments: ["-c", "exit \(exitCode)"]
            )
            #endif

            let result = try await _run(setup, input: .none, output: .discarded, error: .discarded)
            #expect(result.terminationStatus == .exited(TerminationStatus.Code(exitCode)))
        }
    }

    @Test func testInteractiveShell() async throws {
        enum OutputCaptureState {
            case standardOutputCaptured(String)
            case standardErrorCaptured(String)
        }

        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/Q", "/D"],
            environment: .inherit.updating(["PROMPT": "\"\""])
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: []
        )
        #endif

        let result = try await _run(setup) { execution, standardInputWriter, standardOutput, standardError in
            return try await withThrowingTaskGroup(of: OutputCaptureState?.self) { group in
                group.addTask {
                    #if os(Windows)
                    _ = try await standardInputWriter.write("echo off\n")
                    #endif
                    _ = try await standardInputWriter.write("echo hello stdout\n")
                    _ = try await standardInputWriter.write("echo >&2 hello stderr\n")
                    _ = try await standardInputWriter.write("exit 0\n")
                    try await standardInputWriter.finish()
                    return nil
                }
                group.addTask {
                    var result = ""
                    for try await line in standardOutput.lines() {
                        result += line
                    }
                    return .standardOutputCaptured(result.trimmingNewLineAndQuotes())
                }
                group.addTask {
                    var result = ""
                    for try await line in standardError.lines() {
                        result += line
                    }
                    return .standardErrorCaptured(result.trimmingNewLineAndQuotes())
                }

                var output: String = ""
                var error: String = ""
                while let state = try await group.next() {
                    switch state {
                    case .some(.standardOutputCaptured(let string)):
                        output = string
                    case .some(.standardErrorCaptured(let string)):
                        error = string
                    case .none:
                        continue
                    }
                }

                return (output: output, error: error)
            }
        }

        #expect(result.terminationStatus.isSuccess)
        #if os(Windows)
        // cmd.exe interactive mode prints more info
        #expect(result.value.output.contains("hello stdout"))
        #else
        #expect(result.value.output == "hello stdout")
        #endif
        #expect(result.value.error == "hello stderr")
    }

    @Test func testSubprocessPipeChain() async throws {
        struct Pipe: @unchecked Sendable {
            #if os(Windows)
            let readEnd: HANDLE
            let writeEnd: HANDLE
            #else
            let readEnd: FileDescriptor
            let writeEnd: FileDescriptor
            #endif
        }

        // This is NOT the final piping API that we want
        // This test only makes sure it's possible to create
        // a chain of subprocess
        #if os(Windows)
        // On Windows we need to set inheritability of each end
        // differently for each process
        var readHandle: HANDLE? = nil
        var writeHandle: HANDLE? = nil
        guard CreatePipe(&readHandle, &writeHandle, nil, 0),
            readHandle != INVALID_HANDLE_VALUE,
            writeHandle != INVALID_HANDLE_VALUE,
            let readHandle: HANDLE = readHandle,
            let writeHandle: HANDLE = writeHandle
        else {
            throw SubprocessError(
                code: .init(.failedToCreatePipe),
                underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
            )
        }
        SetHandleInformation(readHandle, HANDLE_FLAG_INHERIT, 0)
        SetHandleInformation(writeHandle, HANDLE_FLAG_INHERIT, 0)
        let pipe = Pipe(readEnd: readHandle, writeEnd: writeHandle)
        #else
        let _pipe = try FileDescriptor.pipe()
        let pipe: Pipe = Pipe(readEnd: _pipe.readEnd, writeEnd: _pipe.writeEnd)
        #endif
        try await withThrowingTaskGroup { group in
            group.addTask {
                #if os(Windows)
                let setup = TestSetup(
                    executable: .name("cmd.exe"),
                    arguments: ["/c", "echo apple"]
                )
                // Set write handle to be inheritable only
                var writeEndHandle: HANDLE? = nil
                guard
                    DuplicateHandle(
                        GetCurrentProcess(),
                        pipe.writeEnd,
                        GetCurrentProcess(),
                        &writeEndHandle,
                        0, true, DWORD(DUPLICATE_SAME_ACCESS)
                    )
                else {
                    throw SubprocessError(
                        code: .init(.failedToCreatePipe),
                        underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
                    )
                }
                guard let writeEndHandle else {
                    throw SubprocessError(
                        code: .init(.failedToCreatePipe),
                        underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
                    )
                }
                CloseHandle(pipe.writeEnd) // No longer need the original
                // Allow Subprocess to inherit writeEnd
                SetHandleInformation(writeEndHandle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)
                let writeEndFd = _open_osfhandle(
                    intptr_t(bitPattern: writeEndHandle),
                    FileDescriptor.AccessMode.writeOnly.rawValue
                )
                let writeEnd = FileDescriptor(rawValue: writeEndFd)
                #else
                let setup = TestSetup(
                    executable: .path("/bin/sh"),
                    arguments: ["-c", "echo apple"]
                )
                let writeEnd = pipe.writeEnd
                #endif
                _ = try await _run(
                    setup,
                    input: .none,
                    output: .fileDescriptor(
                        writeEnd,
                        closeAfterSpawningProcess: true
                    ),
                    error: .discarded
                )
            }
            group.addTask {
                #if os(Windows)
                let setup = TestSetup(
                    executable: .name("powershell.exe"),
                    arguments: ["-Command", "[Console]::In.ReadToEnd().ToUpper()"]
                )
                // Set read handle to be inheritable only
                var readEndHandle: HANDLE? = nil
                guard
                    DuplicateHandle(
                        GetCurrentProcess(),
                        pipe.readEnd,
                        GetCurrentProcess(),
                        &readEndHandle,
                        0, true, DWORD(DUPLICATE_SAME_ACCESS)
                    )
                else {
                    throw SubprocessError(
                        code: .init(.failedToCreatePipe),
                        underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
                    )
                }
                guard let readEndHandle else {
                    throw SubprocessError(
                        code: .init(.failedToCreatePipe),
                        underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
                    )
                }
                CloseHandle(pipe.readEnd) // No longer need the original
                // Allow Subprocess to inherit writeEnd
                SetHandleInformation(readEndHandle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)
                let readEndFd = _open_osfhandle(
                    intptr_t(bitPattern: readEndHandle),
                    FileDescriptor.AccessMode.writeOnly.rawValue
                )
                let readEnd = FileDescriptor(rawValue: readEndFd)
                #else
                let setup = TestSetup(
                    executable: .path("/usr/bin/tr"),
                    arguments: ["[:lower:]", "[:upper:]"]
                )
                let readEnd = pipe.readEnd
                #endif
                let result = try await _run(
                    setup,
                    input: .fileDescriptor(readEnd, closeAfterSpawningProcess: true),
                    output: .string(limit: 32),
                    error: .discarded
                )

                #expect(result.terminationStatus.isSuccess)
                #expect(result.standardOutput?.trimmingNewLineAndQuotes() == "APPLE")
            }

            try await group.waitForAll()
        }
    }

    @Test func testLineSequenceNoNewLines() async throws {
        #if os(Windows)
        let setup = TestSetup(
            executable: .name("cmd.exe"),
            arguments: ["/c", "<nul set /p=x & <nul set /p=y 1>&2"]
        )
        #else
        let setup = TestSetup(
            executable: .path("/bin/sh"),
            arguments: ["-c", "/bin/echo -n x; /bin/echo >&2 -n y"]
        )
        #endif
        _ = try await _run(setup) { execution, inputWriter, standardOutput, standardError in
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await inputWriter.finish()
                }

                group.addTask {
                    var result = ""
                    for try await line in standardOutput.lines() {
                        result += line
                    }
                    #expect(result.trimmingNewLineAndQuotes() == "x")
                }

                group.addTask {
                    var result = ""
                    for try await line in standardError.lines() {
                        result += line
                    }
                    #expect(result.trimmingNewLineAndQuotes() == "y")
                }
                try await group.waitForAll()
            }
        }
    }
}

// MARK: - Utilities
extension String {
    func trimmingNewLineAndQuotes() -> String {
        var characterSet = CharacterSet.whitespacesAndNewlines
        characterSet.insert(charactersIn: "\"")
        return self.trimmingCharacters(in: characterSet)
    }
}

// Easier to support platform differences
struct TestSetup {
    let executable: Subprocess.Executable
    let arguments: Subprocess.Arguments
    let environment: Subprocess.Environment
    let workingDirectory: FilePath?

    init(
        executable: Subprocess.Executable,
        arguments: Subprocess.Arguments,
        environment: Subprocess.Environment = .inherit,
        workingDirectory: FilePath? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

func _run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ testSetup: TestSetup,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input,
    output: Output,
    error: Error
) async throws -> CollectedResult<Output, Error> {
    return try await Subprocess.run(
        testSetup.executable,
        arguments: testSetup.arguments,
        environment: testSetup.environment,
        workingDirectory: testSetup.workingDirectory,
        platformOptions: platformOptions,
        input: input,
        output: output,
        error: error
    )
}

#if SubprocessSpan
func _run<
    InputElement: BitwiseCopyable,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ testSetup: TestSetup,
    input: borrowing Span<InputElement>,
    output: Output,
    error: Error
) async throws -> CollectedResult<Output, Error> {
    return try await Subprocess.run(
        testSetup.executable,
        arguments: testSetup.arguments,
        environment: testSetup.environment,
        workingDirectory: testSetup.workingDirectory,
        input: input,
        output: output,
        error: error
    )
}
#endif

func _run<
    Result,
    Input: InputProtocol,
    Error: ErrorOutputProtocol
>(
    _ setup: TestSetup,
    input: Input,
    error: Error,
    preferredBufferSize: Int? = nil,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionResult<Result> where Error.OutputType == Void {
    return try await Subprocess.run(
        setup.executable,
        arguments: setup.arguments,
        environment: setup.environment,
        workingDirectory: setup.workingDirectory,
        input: input,
        error: error,
        preferredBufferSize: preferredBufferSize,
        body: body
    )
}

func _run<
    Result,
    Error: ErrorOutputProtocol
>(
    _ setup: TestSetup,
    error: Error,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionResult<Result> where Error.OutputType == Void {
    return try await Subprocess.run(
        setup.executable,
        arguments: setup.arguments,
        environment: setup.environment,
        workingDirectory: setup.workingDirectory,
        error: error,
        body: body
    )
}

func _run<
    Result,
    Output: OutputProtocol
>(
    _ setup: TestSetup,
    output: Output,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionResult<Result> where Output.OutputType == Void {
    return try await Subprocess.run(
        setup.executable,
        arguments: setup.arguments,
        environment: setup.environment,
        workingDirectory: setup.workingDirectory,
        output: output,
        body: body
    )
}

func _run<Result>(
    _ setup: TestSetup,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionResult<Result> {
    return try await Subprocess.run(
        setup.executable,
        arguments: setup.arguments,
        environment: setup.environment,
        workingDirectory: setup.workingDirectory,
        body: body
    )
}

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
