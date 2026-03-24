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

/// The outcome of a subprocess execution, containing the closure's return value and the termination status of the child process.
public struct ExecutionOutcome<Result: Sendable>: Sendable {
    /// The termination status of the child process.
    public let terminationStatus: TerminationStatus
    /// The value returned by the closure passed to the `run` method.
    public let value: Result

    internal init(terminationStatus: TerminationStatus, value: Result) {
        self.terminationStatus = terminationStatus
        self.value = value
    }
}

/// The result of running a subprocess, including collected standard output and standard error.
public struct ExecutionRecord<
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

    internal init(
        processIdentifier: ProcessIdentifier,
        terminationStatus: TerminationStatus,
        standardOutput: Output.OutputType,
        standardError: Error.OutputType
    ) {
        self.processIdentifier = processIdentifier
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

// MARK: - ExecutionRecord Conformances

extension ExecutionRecord: Equatable where Output.OutputType: Equatable, Error.OutputType: Equatable {}

extension ExecutionRecord: Hashable where Output.OutputType: Hashable, Error.OutputType: Hashable {}

extension ExecutionRecord: CustomStringConvertible
where Output.OutputType: CustomStringConvertible, Error.OutputType: CustomStringConvertible {
    /// A textual representation of the collected result.
    public var description: String {
        return """
            ExecutionRecord(
                processIdentifier: \(self.processIdentifier),
                terminationStatus: \(self.terminationStatus.description),
                standardOutput: \(self.standardOutput.description)
                standardError: \(self.standardError.description)
            )
            """
    }
}

extension ExecutionRecord: CustomDebugStringConvertible
where Output.OutputType: CustomDebugStringConvertible, Error.OutputType: CustomDebugStringConvertible {
    /// A debug-oriented textual representation of the collected result.
    public var debugDescription: String {
        return """
            ExecutionRecord(
                processIdentifier: \(self.processIdentifier),
                terminationStatus: \(self.terminationStatus.description),
                standardOutput: \(self.standardOutput.debugDescription)
                standardError: \(self.standardError.debugDescription)
            )
            """
    }
}

// MARK: - ExecutionOutcome Conformances
extension ExecutionOutcome: Equatable where Result: Equatable {}

extension ExecutionOutcome: Hashable where Result: Hashable {}

extension ExecutionOutcome: CustomStringConvertible where Result: CustomStringConvertible {
    /// A textual representation of the execution result.
    public var description: String {
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
    public var debugDescription: String {
        return """
            ExecutionOutcome(
                terminationStatus: \(self.terminationStatus.debugDescription),
                value: \(self.value.debugDescription)
            )
            """
    }
}

// MARK: - Deprecated
@available(
    *, deprecated,
    renamed: "ExecutionOutcome",
    message: "ExecutionResult has been renamed to ExecutionOutcome. ExecutionResult will be removed in 1.0"
)
public typealias ExecutionResult = ExecutionOutcome

@available(
    *, deprecated,
    renamed: "ExecutionRecord",
    message: "CollectedResult has been renamed to ExecutionRecord. CollectedResult will be removed in 1.0"
)
public typealias CollectedResult = ExecutionRecord
