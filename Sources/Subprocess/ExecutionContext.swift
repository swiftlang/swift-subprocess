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

/// A snapshot of the inputs and resolved values associated with a
/// `SubprocessError`.
///
/// `ExecutionContext` records two families of values:
///
/// - The values configured by the caller: ``executable``, ``arguments``,
/// ``environment``, and ``workingDirectory``, reflecting the inputs exactly
/// as supplied. For example, if ``Environment/inherit`` was used,
/// ``environment`` is `.inherit`, not the parent's variables.
/// - The values the library resolved at spawn time: ``resolvedExecutable``,
/// ``resolvedEnvironment``, and ``resolvedWorkingDirectory``. Each is
/// best-effort and may be `nil` when the value was unavailable, such as for
/// an error thrown before the process spawned.
///
/// `ExecutionContext` is attached to every ``SubprocessError`` that propagates
/// out of a `run()` call, including errors originating inside a custom `body`
/// closure (from ``StandardInputWriter``, ``SubprocessOutputSequence``, or a
/// collected output type). ``SubprocessError/executionContext`` is `nil` for
/// errors observed outside of a `run()` call.
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
    /// The path used to launch the executable, or `nil` if undetermined.
    ///
    /// For ``Executable/path(_:)`` this is the caller-provided path. For
    /// ``Executable/name(_:)`` this is the candidate that launched successfully
    /// after searching `PATH`. This is normally absolute; it may not be
    /// absolute when it is found relative to the working directory. On Windows
    /// it may be `nil` for a name-based executable, because `CreateProcessW()`
    /// searches internally without reporting the path it used.
    public let resolvedExecutable: FilePath?
    /// The environment the child process was given, or `nil` if unavailable.
    ///
    /// This is `nil` for errors thrown before the process spawned, and for
    /// environments configured with raw bytes, which have no faithful `String`
    /// representation. On Windows, this may include a `PATH` entry that
    /// `Subprocess` added so the child can locate its DLLs, even when the
    /// caller did not supply one.
    public let resolvedEnvironment: [Environment.Key: String]?
    /// The child's working directory.
    ///
    /// When the caller passed `nil`, this is the parent's working directory
    /// captured at spawn, or `nil` if undetermined.
    public let resolvedWorkingDirectory: FilePath?

    internal init(
        _ configuration: Configuration,
        resolvedExecutable: FilePath? = nil,
        resolvedEnvironment: [Environment.Key: String]? = nil,
        resolvedWorkingDirectory: FilePath? = nil
    ) {
        self.executable = configuration.executable
        self.arguments = configuration.arguments
        self.environment = configuration.environment
        self.workingDirectory = configuration.workingDirectory
        self.resolvedExecutable = resolvedExecutable
        self.resolvedEnvironment = resolvedEnvironment
        self.resolvedWorkingDirectory = resolvedWorkingDirectory
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
                workingDirectory: \(self.workingDirectory?.string ?? ""),
                resolvedExecutable: \(self.resolvedExecutable?.string ?? "nil"),
                resolvedWorkingDirectory: \(self.resolvedWorkingDirectory?.string ?? "nil"),
                resolvedEnvironment: \(self.resolvedEnvironment.map { "\($0.count) variable\($0.count > 1 ? "s" : "")" } ?? "nil")
            )
            """
    }

    /// A debug-oriented textual representation of this execution context.
    public var debugDescription: String {
        return description
    }
}
