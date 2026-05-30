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
@testable import Subprocess

@Suite("ExecutionContext Unit Tests", .serialized)
struct ExecutionContextTests {}

// MARK: - General
extension ExecutionContextTests {
    /// Once an error has an `ExecutionContext` attached, a subsequent attempt
    /// to attach a different context must be a no-op. This guarantees that the
    /// inner I/O wraps (which have the most specific information) win over the
    /// outer wrap in `Configuration.run(input:output:error:_:)`.
    @Test func testWithExecutionContextIsIdempotent() {
        let firstConfig = Configuration(
            executable: .name("first"),
            arguments: ["a"],
            environment: .custom(["K": "1"]),
            workingDirectory: FilePath("/tmp/first")
        )
        let secondConfig = Configuration(
            executable: .name("second"),
            arguments: ["b"],
            environment: .custom(["K": "2"]),
            workingDirectory: FilePath("/tmp/second")
        )

        let firstContext = ExecutionContext(firstConfig)
        let secondContext = ExecutionContext(secondConfig)

        let baseError: SubprocessError = .spawnFailed
        #expect(baseError.executionContext == nil)

        let firstAttach = baseError.withExecutionContext(firstContext)
        #expect(firstAttach.executionContext == firstContext)

        let secondAttach = firstAttach.withExecutionContext(secondContext)
        #expect(secondAttach.executionContext == firstContext)
    }

    /// Attaching `nil` must never overwrite an existing context, and
    /// must leave a context-less error context-less.
    @Test func testWithExecutionContextNilIsNoOp() {
        let config = Configuration(executable: .name("test"))
        let context = ExecutionContext(config)

        let baseError: SubprocessError = .spawnFailed
        let attached = baseError.withExecutionContext(context)

        #expect(baseError.withExecutionContext(nil).executionContext == nil)
        #expect(attached.withExecutionContext(nil).executionContext == context)
    }

    @Test func testExecutionContextRoundTripsConfigurationFields() {
        let config = Configuration(
            executable: .path("/usr/bin/example"),
            arguments: ["--flag", "value"],
            environment: .custom(["FOO": "bar"]),
            workingDirectory: FilePath("/var/tmp")
        )

        let context = ExecutionContext(config)

        #expect(context.executable == config.executable)
        #expect(context.arguments == config.arguments)
        #expect(context.environment == config.environment)
        #expect(context.workingDirectory == config.workingDirectory)
    }

    @Test func testExecutionContextResolvedValuesDefaultToNil() {
        let context = ExecutionContext(Configuration(executable: .name("x")))
        #expect(context.resolvedExecutable == nil)
        #expect(context.resolvedEnvironment == nil)
        #expect(context.resolvedWorkingDirectory == nil)
    }

    @Test func testExecutionContextStoresResolvedValues() {
        let config = Configuration(
            executable: .path("/usr/bin/example"),
            arguments: ["--flag"],
            environment: .custom(["FOO": "bar"]),
            workingDirectory: FilePath("/var/tmp")
        )
        let context = ExecutionContext(
            config,
            resolvedExecutable: FilePath("/usr/bin/example"),
            resolvedEnvironment: ["FOO": "bar"],
            resolvedWorkingDirectory: FilePath("/var/tmp")
        )
        #expect(context.resolvedExecutable == FilePath("/usr/bin/example"))
        #expect(context.resolvedEnvironment == ["FOO": "bar"])
        #expect(context.resolvedWorkingDirectory == FilePath("/var/tmp"))
    }

    @Test func testExecutionContextEqualityIncludesResolvedValues() {
        let config = Configuration(executable: .name("x"))
        let a = ExecutionContext(config, resolvedExecutable: FilePath("/a"))
        let b = ExecutionContext(config, resolvedExecutable: FilePath("/b"))
        #expect(a != b)
    }
}

// MARK: - resolvedValues()
extension ExecutionContextTests {
    @Test func testResolvedValuesForCustomEnvironment() {
        // `PATH` is included so the Windows injection is a no-op and the
        // result is identical across platforms.
        let values: [Environment.Key: String] = ["A": "1", "PATH": "/custom"]
        #expect(Environment.custom(values).resolvedValues() == values)
    }

    @Test func testResolvedValuesForInheritedEnvironment() {
        #expect(Environment.inherit.resolvedValues() == Environment.currentEnvironmentValues())
    }

    @Test func testResolvedValuesAppliesInheritOverrides() throws {
        let current = Environment.currentEnvironmentValues()
        let addedKey: Environment.Key = "SUBPROCESS_RESOLVED_VALUES_ADDED"
        try #require(current[addedKey] == nil)
        // Avoid `PATH` so the Windows injection doesn't interfere with removal.
        let existingKey = try #require(current.keys.first { $0 != .path })

        let updated = Environment.inherit.updating([
            addedKey: "added",
            existingKey: "overridden",
        ])
        let resolved = try #require(updated.resolvedValues())
        #expect(resolved[addedKey] == "added")
        #expect(resolved[existingKey] == "overridden")

        let removed = Environment.inherit.updating([existingKey: nil])
        let resolvedAfterRemoval = try #require(removed.resolvedValues())
        #expect(resolvedAfterRemoval[existingKey] == nil)
        #expect(resolvedAfterRemoval.count == current.count - 1)
    }

    #if !os(Windows)
    @Test func testResolvedValuesForRawBytesEnvironmentIsNil() {
        #expect(Environment.custom([Array("A=1".utf8)]).resolvedValues() == nil)
    }
    #endif

    #if os(Windows)
    @Test func testResolvedValuesInjectsPathOnWindows() throws {
        let resolved = try #require(Environment.custom(["A": "1"]).resolvedValues())
        #expect(resolved["A"] == "1")
        let parentPath = try #require(Environment.currentEnvironmentValues()[.path])
        #expect(resolved[.path] == parentPath)
    }
    #endif
}

// MARK: - currentWorkingDirectory()
extension ExecutionContextTests {
    @Test func testCurrentWorkingDirectoryIsAbsolute() throws {
        let cwd = try #require(currentWorkingDirectory())
        #expect(cwd.isAbsolute)
    }
}
