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

// MARK: - Result

/// The result of running a subprocess, including the closure's return value,
/// collected standard output, and collected standard error.
///
/// The `ClosureResult` generic parameter is `Void` when you call a `run(...)`
/// overload that doesn't take a `body` closure. It's the closure's return type
/// otherwise. You access the closure's return value with ``closureOutput``.
///
/// The ``standardOutput`` and ``standardError`` properties are available when
/// the corresponding output type produces a non-`Void` value. They're
/// unavailable for output types such as ``DiscardedOutput``, ``SequenceOutput``,
/// and ``FileDescriptorOutput``.
public struct ExecutionResult<
    ClosureResult: Sendable,
    Output: OutputProtocol,
    Error: OutputProtocol
>: Sendable {
    /// The process identifier of the subprocess.
    public let processIdentifier: ProcessIdentifier
    /// The termination status of the subprocess.
    public let terminationStatus: TerminationStatus

    /// The collected standard output of the subprocess.
    public let standardOutput: Output.OutputType
    /// The collected standard error of the subprocess.
    public let standardError: Error.OutputType

    /// The value returned by the body closure passed to `run`.
    public let closureOutput: ClosureResult

    internal init(
        processIdentifier: ProcessIdentifier,
        terminationStatus: TerminationStatus,
        closureOutput: ClosureResult,
        standardOutput: Output.OutputType,
        standardError: Error.OutputType
    ) {
        self.processIdentifier = processIdentifier
        self.terminationStatus = terminationStatus
        self.closureOutput = closureOutput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

// MARK: - ExecutionResult Conformances

extension ExecutionResult: Equatable where Output.OutputType: Equatable, Error.OutputType: Equatable, ClosureResult: Equatable {}

extension ExecutionResult: Hashable where Output.OutputType: Hashable, Error.OutputType: Hashable, ClosureResult: Hashable {}

extension ExecutionResult: CustomStringConvertible where Output.OutputType: CustomStringConvertible, Error.OutputType: CustomStringConvertible {
    /// A textual representation of the collected result.
    public var description: String {
        return """
            ExecutionResult(
                processIdentifier: \(self.processIdentifier),
                terminationStatus: \(self.terminationStatus.description),
                closureOutput: \(String(describing: self.closureOutput)),
                standardOutput: \(self.standardOutput.description)
                standardError: \(self.standardError.description)
            )
            """
    }
}

extension ExecutionResult: CustomDebugStringConvertible
where Output.OutputType: CustomDebugStringConvertible, Error.OutputType: CustomDebugStringConvertible {
    /// A debug-oriented textual representation of the collected result.
    public var debugDescription: String {
        return """
            ExecutionResult(
                processIdentifier: \(self.processIdentifier),
                terminationStatus: \(self.terminationStatus.debugDescription),
                closureOutput: \(String(describing: self.closureOutput)),
                standardOutput: \(self.standardOutput.debugDescription)
                standardError: \(self.standardError.debugDescription)
            )
            """
    }
}

// MARK: - ExecutionOutcome

/// The outcome of a subprocess execution, containing the closure's return
/// value and the termination status of the child process.
internal struct ExecutionOutcome<Result: Sendable>: Sendable {
    /// The termination status of the child process.
    internal let terminationStatus: TerminationStatus
    /// The value returned by the closure passed to the `run` method.
    internal let value: Result

    internal init(terminationStatus: TerminationStatus, value: Result) {
        self.terminationStatus = terminationStatus
        self.value = value
    }
}

extension ExecutionOutcome: Equatable where Result: Equatable {}

extension ExecutionOutcome: Hashable where Result: Hashable {}

extension ExecutionOutcome: CustomStringConvertible where Result: CustomStringConvertible {
    /// A textual representation of the execution result.
    var description: String {
        return """
            ExecutionOutcome(
                terminationStatus: \(self.terminationStatus.description),
                value: \(self.value.description)
            )
            """
    }
}

extension ExecutionOutcome: CustomDebugStringConvertible where Result: CustomDebugStringConvertible {
    /// A debug-oriented textual representation of this execution result.
    var debugDescription: String {
        return """
            ExecutionOutcome(
                terminationStatus: \(self.terminationStatus.debugDescription),
                value: \(self.value.debugDescription)
            )
            """
    }
}
