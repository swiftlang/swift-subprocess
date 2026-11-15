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
import System
#else
import SystemPackage
#endif

import Testing
import Subprocess

@Suite("Configuration Introspection Tests")
struct ConfigurationIntrospectionTests {}

// MARK: - Arguments
extension ConfigurationIntrospectionTests {
    @Test func testArgumentsArrayLiteralIsIterable() {
        let arguments: Arguments = ["--foo", "bar", "--baz"]

        #expect(arguments.count == 3)
        #expect(arguments[0] == .string("--foo"))
        #expect(arguments[1] == .string("bar"))
        #expect(arguments[2] == .string("--baz"))
        #expect(Array(arguments) == [.string("--foo"), .string("bar"), .string("--baz")])
    }

    @Test func testArgumentsFromStringArrayIsIterable() {
        let arguments = Arguments(["a", "b", "c"])

        #expect(arguments.count == 3)
        #expect(arguments.first == .string("a"))
        #expect(arguments.last == .string("c"))
    }

    @Test func testArgumentsEmpty() {
        let arguments: Arguments = []

        #expect(arguments.isEmpty)
        #expect(arguments.count == 0)
        #expect(arguments.executablePathOverride == nil)
    }

    @Test func testArgumentsExecutablePathOverrideNil() {
        let arguments = Arguments(["a", "b"])

        #expect(arguments.executablePathOverride == nil)
    }

    @Test func testArgumentsExecutablePathOverrideString() {
        let arguments = Arguments(
            executablePathOverride: "argv0-override",
            remainingValues: ["a", "b"]
        )

        #expect(arguments.executablePathOverride == .string("argv0-override"))
        #expect(arguments.count == 2)
        #expect(Array(arguments) == [.string("a"), .string("b")])
    }

    @Test func testArgumentsExecutablePathOverrideExplicitlyNil() {
        let arguments = Arguments(
            executablePathOverride: nil,
            remainingValues: ["a", "b"]
        )

        #expect(arguments.executablePathOverride == nil)
        #expect(arguments.count == 2)
        #expect(Array(arguments) == [.string("a"), .string("b")])
    }

    #if !os(Windows)
    @Test func testArgumentsFromRawBytesIsIterable() {
        let arguments = Arguments([
            Array("first".utf8),
            Array("second".utf8),
        ])

        #expect(arguments.count == 2)
        #expect(arguments[0] == .rawBytes(Array("first".utf8)))
        #expect(arguments[1] == .rawBytes(Array("second".utf8)))
    }

    @Test func testArgumentsRawBytesExecutablePathOverride() {
        let arguments = Arguments(
            executablePathOverride: Array("argv0".utf8),
            remainingValues: [Array("a".utf8), Array("b".utf8)]
        )

        #expect(arguments.executablePathOverride == .rawBytes(Array("argv0".utf8)))
        #expect(arguments.count == 2)
        #expect(arguments[0] == .rawBytes(Array("a".utf8)))
        #expect(arguments[1] == .rawBytes(Array("b".utf8)))
    }
    #endif // !os(Windows)
}

// MARK: - Environment
extension ConfigurationIntrospectionTests {
    @Test func testEnvironmentInheritDefault() {
        let environment: Environment = .inherit

        #expect(environment.representation == .inherited(updates: [:]))
    }

    @Test func testEnvironmentInheritWithUpdates() {
        let updates: [Environment.Key: String?] = [
            .path: "/custom/path",
            "FOO": "foo-value",
        ]

        let environment: Environment = .inherit.updating(updates)
        let expected: Environment.Representation = .inherited(updates: updates)

        #expect(environment.representation == expected)
    }

    @Test func testEnvironmentInheritWithUnsetDirective() {
        // A `nil` value in updates means "unset relative to inherited
        // environment", distinct from "absent from updates".
        let updates: [Environment.Key: String?] = [
            "FOO": "foo-value",
            "REMOVE_ME": nil,
        ]

        let environment: Environment = .inherit.updating(updates)
        let expected: Environment.Representation = .inherited(updates: updates)

        #expect(environment.representation == expected)
    }

    @Test func testEnvironmentCustom() {
        let updates: [Environment.Key: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/home/user",
        ]

        let environment: Environment = .custom(updates)
        let expected: Environment.Representation = .custom(updates)

        #expect(environment.representation == expected)
    }

    @Test func testEnvironmentCustomUpdating() {
        let environment: Environment = .custom([
            "PATH": "/usr/bin:/bin"
        ]).updating([
            "EXTRA": "value"
        ])

        let expected: Environment.Representation = .custom([
            "PATH": "/usr/bin:/bin",
            "EXTRA": "value",
        ])

        #expect(environment.representation == expected)
    }

    #if !os(Windows)
    @Test func testEnvironmentRawBytes() {
        let entries: [[UInt8]] = [
            Array("PATH=/usr/bin:/bin\0".utf8),
            Array("HOME=/home/user\0".utf8),
        ]

        let environment: Environment = .custom(entries)

        #expect(environment.representation == .rawBytes(entries))
    }
    #endif // !os(Windows)
}

// MARK: - Executable
extension ConfigurationIntrospectionTests {
    @Test func testExecutableName() {
        let executable: Executable = .name("git")

        #expect(executable.representation == .name("git"))
    }

    @Test func testExecutablePath() {
        let path: FilePath = "/usr/bin/git"
        let executable: Executable = .path(path)

        #expect(executable.representation == .path(path))
    }
}
