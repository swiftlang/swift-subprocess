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
struct ExecutionContextTests {
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

    /// Every field of `ExecutionContext` must round-trip from the
    /// originating `Configuration`.
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
}
