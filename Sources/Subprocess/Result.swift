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

#if canImport(Darwin)
public import Darwin
#elseif canImport(Glibc)
public import Glibc
#elseif canImport(Musl)
public import Musl
#elseif canImport(Android)
public import Android
#endif

// Don't import `_SubprocessCShims` into this file. On some platforms that makes
// it, rather than the platform libc overlay, the module `rusage` is attributed
// to, and `ResourceUsage.rusage` can then no longer be public. The conversions
// that need C struct members in scope live in Subprocess+Unix.swift and
// Subprocess+Windows.swift instead.

// MARK: - ResourceUsage

/// Resource usage information for a terminated subprocess.
///
/// Equality and hashing consider only ``userTime``, ``systemTime``, and
/// ``maxRSS``. Where the platform exposes it, `rusage` takes no part in them, so
/// two values agreeing on those three are equal even if their raw structs differ.
public struct ResourceUsage: Sendable, Hashable {
    /// The total amount of time spent executing in user mode.
    public let userTime: Duration
    /// The total amount of time spent executing in kernel mode.
    public let systemTime: Duration
    /// The peak resident set size (maximum memory used), in bytes.
    public let maxRSS: Int

    #if !os(Windows)
    /// The underlying POSIX resource usage information.
    public let rusage: rusage
    #endif

    #if os(Windows)
    internal init(userTime: Duration, systemTime: Duration, maxRSS: Int) {
        self.userTime = userTime
        self.systemTime = systemTime
        self.maxRSS = maxRSS
    }
    #else
    internal init(userTime: Duration, systemTime: Duration, maxRSS: Int, rusage: rusage) {
        self.userTime = userTime
        self.systemTime = systemTime
        self.maxRSS = maxRSS
        self.rusage = rusage
    }
    #endif

    // Written by hand rather than synthesized: `rusage` is a C struct that
    // conforms to neither protocol, and conforming a type this package doesn't
    // own -- retroactively and publicly -- would collide with anyone else who
    // does the same.
    public static func == (lhs: ResourceUsage, rhs: ResourceUsage) -> Bool {
        lhs.userTime == rhs.userTime && lhs.systemTime == rhs.systemTime && lhs.maxRSS == rhs.maxRSS
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.userTime)
        hasher.combine(self.systemTime)
        hasher.combine(self.maxRSS)
    }
}

// MARK: - Result

/// The result of running a subprocess, including the closure's return value,
/// collected standard output, and collected standard error.
///
/// The `ClosureResult` generic parameter is `Void` when you call a `run(...)`
/// overload that doesn't take a `body` closure. It's the closure's return type
/// otherwise. You access the closure's return value with ``closureResult``.
///
/// The ``standardOutput`` and ``standardError`` properties are available when
/// the corresponding output type produces a non-`Void` value. They're
/// unavailable for output types such as ``DiscardedOutput``, ``SequenceOutput``,
/// and ``FileDescriptorOutput``.
public struct ExecutionResult<
    ClosureResult: Sendable & ~Copyable,
    Output: OutputProtocol,
    Error: OutputProtocol
>: Sendable, ~Copyable {
    /// The process identifier of the subprocess.
    public let processIdentifier: ProcessIdentifier
    /// The termination status of the subprocess.
    public let terminationStatus: TerminationStatus

    /// The collected standard output of the subprocess.
    public let standardOutput: Output.OutputType
    /// The collected standard error of the subprocess.
    public let standardError: Error.OutputType
    /// The resource usage of the terminated child process.
    public let resourceUsage: ResourceUsage

    /// The value returned by the body closure passed to `run`.
    public let closureResult: ClosureResult

    internal init(
        processIdentifier: ProcessIdentifier,
        terminationStatus: TerminationStatus,
        resourceUsage: ResourceUsage,
        closureResult: consuming ClosureResult,
        standardOutput: Output.OutputType,
        standardError: Error.OutputType
    ) {
        self.processIdentifier = processIdentifier
        self.terminationStatus = terminationStatus
        self.resourceUsage = resourceUsage
        self.closureResult = closureResult
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

extension ExecutionResult where ClosureResult: ~Copyable {
    /// Consumes this result and returns the value produced by the `run` body closure.
    public consuming func takeClosureResult() -> ClosureResult {
        return self.closureResult
    }
}

// MARK: - ExecutionResult Conformances

extension ExecutionResult: Copyable where ClosureResult: Copyable {}

extension ExecutionResult: Equatable where Output.OutputType: Equatable, Error.OutputType: Equatable, ClosureResult: Equatable {}

extension ExecutionResult: Hashable where Output.OutputType: Hashable, Error.OutputType: Hashable, ClosureResult: Hashable {}

extension ExecutionResult: CustomStringConvertible where Output.OutputType: CustomStringConvertible, Error.OutputType: CustomStringConvertible {
    /// A textual representation of the collected result.
    public var description: String {
        return """
            ExecutionResult(
                processIdentifier: \(self.processIdentifier),
                terminationStatus: \(self.terminationStatus.description),
                resourceUsage: \(self.resourceUsage),
                closureResult: \(String(describing: self.closureResult)),
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
                resourceUsage: \(self.resourceUsage),
                closureResult: \(String(describing: self.closureResult)),
                standardOutput: \(self.standardOutput.debugDescription)
                standardError: \(self.standardError.debugDescription)
            )
            """
    }
}

// MARK: - ExecutionOutcome

/// The outcome of a subprocess execution, containing the closure's return
/// value and the termination status of the subprocess.
internal struct ExecutionOutcome<Result: Sendable & ~Copyable>: Sendable, ~Copyable {
    /// The termination status of the subprocess.
    internal let terminationStatus: TerminationStatus
    /// The resource usage of the terminated child process.
    internal let resourceUsage: ResourceUsage
    /// The value returned by the closure passed to the `run` method.
    internal let value: Result

    internal init(terminationStatus: TerminationStatus, resourceUsage: ResourceUsage, value: consuming Result) {
        self.terminationStatus = terminationStatus
        self.resourceUsage = resourceUsage
        self.value = value
    }
}

extension ExecutionOutcome: Copyable where Result: Copyable {}

extension ExecutionOutcome: Equatable where Result: Equatable {}

extension ExecutionOutcome: Hashable where Result: Hashable {}

extension ExecutionOutcome: CustomStringConvertible where Result: CustomStringConvertible {
    /// A textual representation of the execution result.
    var description: String {
        return """
            ExecutionOutcome(
                terminationStatus: \(self.terminationStatus.description),
                resourceUsage: \(self.resourceUsage),
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
                resourceUsage: \(self.resourceUsage),
                value: \(self.value.debugDescription)
            )
            """
    }
}
