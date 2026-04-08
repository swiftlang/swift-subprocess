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

/// A simple wrapper around the generic result returned by the
/// `run` closure with the corresponding termination status of
/// the child process.
public struct ExecutionOutcome<Result: Sendable>: Sendable {
    /// The termination status of the child process
    public let terminationStatus: TerminationStatus
    /// The result returned by the closure passed to `.run` methods
    public let value: Result

    internal init(terminationStatus: TerminationStatus, value: Result) {
        self.terminationStatus = terminationStatus
        self.value = value
    }
}

/// The result of a subprocess execution with its collected
/// standard output and standard error.
public struct ExecutionRecord<
    Output: Sendable,
    Error: Sendable
>: Sendable {
    /// The process identifier for the executed subprocess
    public let processIdentifier: ProcessIdentifier
    /// The termination status of the executed subprocess
    public let terminationStatus: TerminationStatus
    /// The captured standard output of the executed subprocess.
    public let standardOutput: Output
    /// The captured standard error of the executed subprocess.
    public let standardError: Error

    internal init(
        processIdentifier: ProcessIdentifier,
        terminationStatus: TerminationStatus,
        standardOutput: Output,
        standardError: Error
    ) {
        self.processIdentifier = processIdentifier
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

// MARK: - ExecutionRecord Conformances

extension ExecutionRecord: Equatable where Output: Equatable, Error: Equatable {}

extension ExecutionRecord: Hashable where Output: Hashable, Error: Hashable {}

extension ExecutionRecord: CustomStringConvertible
where Output: CustomStringConvertible, Error: CustomStringConvertible {
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
where Output: CustomDebugStringConvertible, Error: CustomDebugStringConvertible {
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
