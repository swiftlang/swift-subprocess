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

// MARK: - ResourceUsage

/// The CPU time and memory a terminated subprocess consumed, as accounted by
/// the operating system.
///
/// A property is `nil` when the platform doesn't report that measurement, or
/// when querying it failed. Zero is a real measurement, never a placeholder.
///
/// | Property | Darwin, Linux, Android, FreeBSD, OpenBSD | Windows |
/// |---|---|---|
/// | ``userTime``, ``systemTime`` | Always | Unless the query fails |
/// | ``peakMemoryUsage`` | Always | Unless the query fails |
/// | Page faults, context switches | Always | `nil` |
///
/// On Unix, the kernel generally also charges a child with the usage of any
/// descendants that child waited for. On Windows, only the child process
/// itself is counted.
///
/// Measurements are sampled by the kernel, so a process that exits almost
/// immediately can report zero for any of them. For example, FreeBSD samples
/// resident memory on clock ticks.
public struct ResourceUsage: Sendable {
    /// The total time the process spent executing in user mode.
    public var userTime: Duration?

    /// The total time the process spent executing in kernel mode.
    public var systemTime: Duration?

    /// The most memory the process had resident at any one time, in bytes.
    ///
    /// This is the peak resident set size on Unix, and the peak working set
    /// size on Windows.
    public var peakMemoryUsage: Int?

    /// The number of page faults serviced without any I/O, such as by
    /// reclaiming a page that was still in memory.
    public var minorPageFaults: Int?

    /// The number of page faults that required I/O.
    public var majorPageFaults: Int?

    /// The number of times the process gave up the CPU before its time slice
    /// ended, usually to wait for a resource.
    public var voluntaryContextSwitches: Int?

    /// The number of times the process was preempted, because its time slice
    /// ended or a higher-priority thread became runnable.
    public var involuntaryContextSwitches: Int?

    /// Creates a resource usage value, for example to stand in for a real
    /// measurement in tests.
    public init(
        userTime: Duration? = nil,
        systemTime: Duration? = nil,
        peakMemoryUsage: Int? = nil,
        minorPageFaults: Int? = nil,
        majorPageFaults: Int? = nil,
        voluntaryContextSwitches: Int? = nil,
        involuntaryContextSwitches: Int? = nil
    ) {
        self.userTime = userTime
        self.systemTime = systemTime
        self.peakMemoryUsage = peakMemoryUsage
        self.minorPageFaults = minorPageFaults
        self.majorPageFaults = majorPageFaults
        self.voluntaryContextSwitches = voluntaryContextSwitches
        self.involuntaryContextSwitches = involuntaryContextSwitches
    }
}

// MARK: - _ExcludedFromEquality

/// Stores a value alongside a type's data without taking part in that type's
/// equality or hashing.
///
/// `ExecutionResult` synthesizes `Equatable` and `Hashable`, which requires
/// every stored property to conform. Wrapping a measurement in this type lets
/// it be stored there without conforming itself. Every instance compares equal
/// and hashes identically, which satisfies both protocols' requirements.
internal struct _ExcludedFromEquality<Value: Sendable>: Sendable, Hashable {
    internal var value: Value

    internal init(_ value: Value) {
        self.value = value
    }

    internal static func == (lhs: Self, rhs: Self) -> Bool {
        true
    }

    internal func hash(into hasher: inout Hasher) {}
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
///
/// Equality and hashing don't consider ``resourceUsage``. It measures how the
/// execution ran rather than what it produced, and no two runs measure alike.
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
    /// The CPU time and memory the subprocess consumed.
    ///
    /// Not considered by `==` or `hash(into:)`.
    public var resourceUsage: ResourceUsage { self._resourceUsage.value }
    internal let _resourceUsage: _ExcludedFromEquality<ResourceUsage>

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
        self._resourceUsage = _ExcludedFromEquality(resourceUsage)
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
    /// The CPU time and memory the subprocess consumed. Not considered by `==`
    /// or `hash(into:)`, for the same reason as on `ExecutionResult`.
    internal var resourceUsage: ResourceUsage { self._resourceUsage.value }
    private let _resourceUsage: _ExcludedFromEquality<ResourceUsage>
    /// The value returned by the closure passed to the `run` method.
    internal let value: Result

    internal init(terminationStatus: TerminationStatus, resourceUsage: ResourceUsage, value: consuming Result) {
        self.terminationStatus = terminationStatus
        self._resourceUsage = _ExcludedFromEquality(resourceUsage)
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
