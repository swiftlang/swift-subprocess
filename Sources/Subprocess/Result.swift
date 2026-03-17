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
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
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
            self.userTime = Self.duration(from: userFileTime)
            self.systemTime = Self.duration(from: kernelTime)
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

    private static func duration(from ft: FILETIME) -> Duration {
        let hundredNanos = UInt64(ft.dwHighDateTime) << 32 | UInt64(ft.dwLowDateTime)
        let seconds = Int64(hundredNanos / 10_000_000)
        let remainder = Int64(hundredNanos % 10_000_000)
        return Duration(
            secondsComponent: seconds,
            attosecondsComponent: remainder * 100_000_000_000
        )
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
        #else
        self.maxRSS = Int(usage.ru_maxrss) * 1024 // KiB to bytes (Linux, FreeBSD, OpenBSD, NetBSD)
        #endif
        self.rusage = usage
    }
    #endif
}

// MARK: - ExecutionResult Protocol

/// Protocol providing common properties for subprocess execution results.
public protocol ExecutionResult: Sendable {
    /// The termination status of the child process.
    var terminationStatus: TerminationStatus { get }
    /// The resource usage of the terminated child process.
    var resourceUsage: ResourceUsage { get }
}

// MARK: - Result

/// A simple wrapper around the generic result returned by the
/// `run` closure with the corresponding termination status of
/// the child process.
public struct ExecutionOutcome<Result: Sendable>: Sendable {
    /// The termination status of the child process
    public let terminationStatus: TerminationStatus
    /// The result returned by the closure passed to `.run` methods
    public let value: Result
    /// The resource usage of the terminated child process.
    public let resourceUsage: ResourceUsage

    internal init(terminationStatus: TerminationStatus, resourceUsage: ResourceUsage, value: Result) {
        self.terminationStatus = terminationStatus
        self.resourceUsage = resourceUsage
        self.value = value
    }
}

/// The result of a subprocess execution with its collected
/// standard output and standard error.
public struct ExecutionRecord<
    Output: OutputProtocol,
    Error: OutputProtocol
>: Sendable {
    /// The process identifier for the executed subprocess
    public let processIdentifier: ProcessIdentifier
    /// The termination status of the executed subprocess
    public let terminationStatus: TerminationStatus
    /// The captured standard output of the executed subprocess.
    public let standardOutput: Output.OutputType
    /// The captured standard error of the executed subprocess.
    public let standardError: Error.OutputType
    /// The resource usage of the terminated child process.
    public let resourceUsage: ResourceUsage

    internal init(
        processIdentifier: ProcessIdentifier,
        terminationStatus: TerminationStatus,
        resourceUsage: ResourceUsage,
        standardOutput: Output.OutputType,
        standardError: Error.OutputType
    ) {
        self.processIdentifier = processIdentifier
        self.terminationStatus = terminationStatus
        self.resourceUsage = resourceUsage
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

// MARK: - ExecutionResult Conformances

extension ExecutionOutcome: ExecutionResult {}
extension ExecutionRecord: ExecutionResult {}

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
                resourceUsage: \(self.resourceUsage),
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
                resourceUsage: \(self.resourceUsage),
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
                resourceUsage: \(self.resourceUsage),
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
                resourceUsage: \(self.resourceUsage),
                value: \(self.value.debugDescription)
            )
            """
    }
}
