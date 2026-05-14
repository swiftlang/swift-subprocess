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
public import System
#else
public import SystemPackage
#endif

/// A snapshot of the inputs that produced a `SubprocessError`.
///
/// `ExecutionContext` records the ``Executable``, ``Arguments``, ``Environment``,
/// and working directory that were configured for a subprocess at the time
/// an error was thrown. The values are inputs supplied by the caller. For
/// example, if ``Environment/inherit`` was used, then ``environment``
/// reflects `.inherit`, not a snapshot of the parent process's environment
/// variables.
///
/// `ExecutionContext` is populated on every ``SubprocessError`` that propagates
/// out of a `run()` call, including errors thrown from within a custom `body`
/// closure that uses ``StandardInputWriter``, ``AsyncBufferSequence``, or a
/// collected output type. This may be `nil` for errors observed from outside
/// of a `run()` call.
public struct ExecutionContext: Sendable, Hashable {
    /// The executable that was configured to run.
    public let executable: Executable
    /// The arguments that were configured to be passed to the executable.
    public let arguments: Arguments
    /// The environment that was configured for the executable.
    public let environment: Environment
    /// The working directory that was configured for the executable, or `nil`
    /// if the subprocess was configured to inherit the parent process's
    /// working directory.
    public let workingDirectory: FilePath?

    internal init(_ configuration: Configuration) {
        self.executable = configuration.executable
        self.arguments = configuration.arguments
        self.environment = configuration.environment
        self.workingDirectory = configuration.workingDirectory
    }
}

extension ExecutionContext: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual representation of this execution context.
    public var description: String {
        return """
            ExecutionContext(
                executable: \(self.executable.description),
                arguments: \(self.arguments.description),
                environment: \(self.environment.description),
                workingDirectory: \(self.workingDirectory?.string ?? "")
            )
            """
    }

    /// A debug-oriented textual representation of this execution context.
    public var debugDescription: String {
        return """
            ExecutionContext(
                executable: \(self.executable.debugDescription),
                arguments: \(self.arguments.debugDescription),
                environment: \(self.environment.debugDescription),
                workingDirectory: \(self.workingDirectory?.string ?? "")
            )
            """
    }
}
