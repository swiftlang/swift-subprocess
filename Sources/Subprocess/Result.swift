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
#elseif canImport(WinSDK)
import WinSDK
#endif

// MARK: - ResourceUsage

/// Resource usage information for a terminated subprocess.
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
}

extension ResourceUsage {
    #if os(Windows)
    internal init(processHandle: HANDLE) {
        var creationTime = FILETIME()
        var exitTime = FILETIME()
        var kernelTime = FILETIME()
        var userFileTime = FILETIME()

        if GetProcessTimes(
            processHandle,
            &creationTime,
            &exitTime,
            &kernelTime,
            &userFileTime
        ) {
            self.userTime = Duration(userFileTime)
            self.systemTime = Duration(kernelTime)
        } else {
            self.userTime = .zero
            self.systemTime = .zero
        }

        var memInfo = PROCESS_MEMORY_COUNTERS()
        memInfo.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        if K32GetProcessMemoryInfo(
            processHandle,
            &memInfo,
            DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        ) {
            self.maxRSS = Int(memInfo.PeakWorkingSetSize)
        } else {
            self.maxRSS = 0
        }
    }
    #else
    internal init(_ usage: rusage) {
        self.userTime = Duration(
            secondsComponent: Int64(usage.ru_utime.tv_sec),
            attosecondsComponent: Int64(usage.ru_utime.tv_usec) * 1_000_000_000_000
        )
        self.systemTime = Duration(
            secondsComponent: Int64(usage.ru_stime.tv_sec),
            attosecondsComponent: Int64(usage.ru_stime.tv_usec) * 1_000_000_000_000
        )
        #if canImport(Darwin)
        self.maxRSS = Int(usage.ru_maxrss) // bytes on Darwin
        #elseif os(Linux) || os(Android) || os(FreeBSD) || os(OpenBSD)
        self.maxRSS = Int(usage.ru_maxrss) * 1024 // KiB to bytes (Linux, FreeBSD, OpenBSD, NetBSD)
        #else
        #error("ru_maxrss unit scaling not defined for this platform")
        #endif
        self.rusage = usage
    }
    #endif
}

#if os(Windows)
extension Duration {
    fileprivate init(_ ft: FILETIME) {
        let hundredNanos = UInt64(ft.dwHighDateTime) << 32 | UInt64(ft.dwLowDateTime)
        let seconds = Int64(hundredNanos / 10_000_000)
        let remainder = Int64(hundredNanos % 10_000_000)
        self = Duration(
            secondsComponent: seconds,
            attosecondsComponent: remainder * 100_000_000_000
        )
    }
}
#endif

// MARK: - ExecutionSummary Protocol

/// Protocol providing common properties for subprocess execution results.
public protocol ExecutionSummary: Sendable {
    /// The termination status of the child process.
    var terminationStatus: TerminationStatus { get }
    /// The resource usage of the terminated child process.
    var resourceUsage: ResourceUsage { get }
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

// MARK: - rusage Conformances
#if !os(Windows)
extension rusage: @retroactive Equatable {
    public static func == (lhs: rusage, rhs: rusage) -> Bool {
        withUnsafeBytes(of: lhs) { lhsBytes in
            withUnsafeBytes(of: rhs) { rhsBytes in
                lhsBytes.elementsEqual(rhsBytes)
            }
        }
    }
}

extension rusage: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        withUnsafeBytes(of: self) { bytes in
            hasher.combine(bytes: bytes)
        }
    }
}
#endif

// MARK: - ExecutionResult Conformances

extension ExecutionResult: Copyable where ClosureResult: Copyable {}

extension ExecutionResult: ExecutionSummary {}

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
/// value and the termination status of the child process.
internal struct ExecutionOutcome<Result: Sendable & ~Copyable>: Sendable, ~Copyable {
    /// The termination status of the child process.
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
