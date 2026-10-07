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

#if canImport(Darwin)
import Darwin
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
@preconcurrency public import WinSDK
#endif

#if os(Windows)
// Windows does not use Errno in public type
#if canImport(System)
import System
#else
import SystemPackage
#endif
#else
#if canImport(System)
public import System
#else
public import SystemPackage
#endif
#endif

/// An error thrown by a subprocess operation.
///
/// `SubprocessError` can wrap an ``underlyingError`` to indicate the root cause.
public struct SubprocessError: Swift.Error, Sendable, Hashable {
    /// The error code for this error.
    public let code: SubprocessError.Code
    /// The underlying error that caused this error.
    public let underlyingError: UnderlyingError?
    /// A snapshot of the inputs and resolved values for the subprocess that
    /// produced this error.
    ///
    /// This is populated for errors that propagate out of a `run()` call, and
    /// is `nil` for errors observed outside of a `run()` call.
    public let executionContext: ExecutionContext?

    /// Context associated with this error for better error messages.
    private let context: [Code: Context]
}

// MARK: - Error Codes
extension SubprocessError {
    /// An error code that identifies the type of failure.
    public struct Code: Hashable, Sendable {
        internal enum Storage: Int, Hashable, Sendable {
            // Spawn
            case spawnFailed
            case executableNotFound
            case failedToChangeWorkingDirectory
            case failedToMonitorProcess

            // IO
            case failedToReadFromSubprocess
            case failedToWriteToSubprocess
            case outputLimitExceeded
            case asyncIOFailed

            // Process Control
            case processControlFailed
        }

        internal let storage: Storage

        internal init(_ storage: Storage) {
            self.storage = storage
        }
    }
}

extension SubprocessError.Code {
    /// The process failed to launch.
    public static var spawnFailed: Self { .init(.spawnFailed) }
    /// The executable couldn't be found or run.
    public static var executableNotFound: Self { .init(.executableNotFound) }
    /// The working directory couldn't be set because it's invalid or inaccessible.
    public static var failedToChangeWorkingDirectory: Self { .init(.failedToChangeWorkingDirectory) }
    /// Subprocess couldn't monitor the process's exit status.
    public static var failedToMonitorProcess: Self { .init(.failedToMonitorProcess) }

    /// Subprocess couldn't read the process's output.
    public static var failedToReadFromSubprocess: Self { .init(.failedToReadFromSubprocess) }
    /// Subprocess couldn't write to the process's standard input.
    public static var failedToWriteToSubprocess: Self { .init(.failedToWriteToSubprocess) }
    /// The process produced more output than the configured limit allows.
    public static var outputLimitExceeded: Self { .init(.outputLimitExceeded) }
    /// A platform-specific asynchronous I/O operation failed.
    public static var asyncIOFailed: Self { .init(.asyncIOFailed) }

    /// Subprocess couldn't control the process, for example by sending a signal or terminating it.
    public static var processControlFailed: Self { .init(.processControlFailed) }
}

// MARK: - Underlying types
extension SubprocessError {
    /// The platform-specific error type for low-level subprocess failures.
    #if os(Windows)
    public typealias UnderlyingError = WindowsError
    #else
    public typealias UnderlyingError = Errno
    #endif

    private enum Context: Sendable, Hashable {
        case string(String)
        case int(Int)
        case processControlOperation(ProcessControlOperation)
    }

    internal enum ProcessControlOperation: Sendable, Hashable {
        case sendSignal(Int32) // Unix
        case terminate // Windows
        case suspend // Windows
        case resume // Windows
    }
}

// MARK: - Description
extension SubprocessError: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual representation of this subprocess error.
    public var description: String {
        switch self.code.storage {
        case .spawnFailed:
            var message = ["Failed to launch the new process."]

            if let context = self.context[self.code],
                case .string(let reason) = context
            {
                message.append("Reason: \(reason)")
            }

            if let underlying = self.underlyingError {
                message.append("Underlying error: \(underlying)")
            }

            return message.joined(separator: " ")
        case .executableNotFound:
            if let context = self.context[self.code],
                case .string(let executableName) = context
            {
                return "Executable \"\(executableName)\" is not found or cannot be executed."
            } else {
                return "Executable is not found or cannot be executed."
            }
        case .failedToChangeWorkingDirectory:
            if let context = self.context[self.code],
                case .string(let directory) = context
            {
                return "Failed to set working directory to \"\(directory)\"."
            } else {
                return "Failed to change working directory."
            }
        case .failedToMonitorProcess:
            if let underlying = self.underlyingError {
                return "Failed to monitor the process's exit status with underlying error: \(underlying)"
            } else {
                return "Failed to monitor the process's exit status."
            }

        case .failedToReadFromSubprocess:
            if let underlying = self.underlyingError {
                return "Failed to read bytes from the process with underlying error: \(underlying)"
            } else {
                return "Failed to read bytes from the process."
            }
        case .failedToWriteToSubprocess:
            if let context = self.context[self.code],
                case .string(let reason) = context
            {
                if let underlying = self.underlyingError {
                    return "Failed to write bytes to the process: \(reason) Underlying error: \(underlying)"
                }
                return "Failed to write bytes to the process: \(reason)"
            }
            if let underlying = self.underlyingError {
                return "Failed to write bytes to the process with underlying error: \(underlying)"
            } else {
                return "Failed to write bytes to the process."
            }
        case .outputLimitExceeded:
            if let context = self.context[self.code],
                case .int(let limit) = context
            {
                return "The process's output exceeded the limit of \(limit) bytes."
            } else {
                return "The process's output exceeded the limit."
            }
        case .asyncIOFailed:
            let context = self.context[self.code]
            switch (self.underlyingError, context) {
            case (.none, .string(let reason)):
                return "An error occurred within the AsyncIO subsystem: \(reason)."
            case (.some(let underlying), .string(let reason)):
                return "An error occurred within the AsyncIO subsystem: \(reason). Underlying error: \(underlying)"
            case (.some(let underlying), .none):
                return "An error occurred within the AsyncIO subsystem. Underlying error: \(underlying)"
            default:
                return "An error occurred within the AsyncIO subsystem."
            }

        case .processControlFailed:
            if let context = self.context[self.code],
                case .processControlOperation(let operation) = context
            {
                switch operation {
                case .sendSignal(let signal):
                    return "Failed to send signal \(signal) to the process."
                case .terminate:
                    return "Failed to terminate the process."
                case .suspend:
                    return "Failed to suspend the process."
                case .resume:
                    return "Failed to resume the process."
                }
            } else {
                return "Failed to control the process state."
            }
        }
    }

    /// A debug-oriented textual representation of this subprocess error.
    public var debugDescription: String { self.description }
}

#if os(Windows)

extension SubprocessError {
    /// Represents an error originating from one of the underlying Windows subsystems.
    public enum WindowsError: Error, Hashable {

        /// An error returned by the Windows NT kernel or Native API.
        ///
        /// `NTSTATUS` values are typically returned by low-level system functions
        /// prefixed with `Nt` or `Zw`.
        case ntStatus(NTSTATUS)

        /// A Win32 subsystem error.
        ///
        /// These are the standard `DWORD` error codes typically retrieved by calling
        /// `GetLastError()` immediately after a Win32 API function fails.
        case win32(DWORD)

        /// A Component Object Model (COM) or Windows Runtime (WinRT) error.
        ///
        /// `HRESULT` values encode the severity, facility, and error code. A negative
        /// value generally indicates a failure.
        case hresult(HRESULT)

        /// A C Runtime (CRT) or POSIX-style error.
        ///
        /// These are typically retrieved from the thread-local `errno` variable after
        /// a standard C library function fails.
        case cRuntime(errno_t)

        public init(ntStatus: NTSTATUS) {
            self = .ntStatus(ntStatus)
        }

        public init(win32Error: DWORD) {
            self = .win32(win32Error)
        }

        public init(hresult: HRESULT) {
            self = .hresult(hresult)
        }

        public init(cRuntimeError: errno_t) {
            self = .cRuntime(cRuntimeError)
        }
    }
}

#endif

// MARK: - Internal Initializers
extension SubprocessError {
    internal static func executableNotFound(_ executable: String, underlyingError: UnderlyingError?) -> Self {
        return SubprocessError(
            code: .executableNotFound,
            underlyingError: underlyingError,
            executionContext: nil,
            context: [.executableNotFound: .string(executable)]
        )
    }

    internal static func failedToMonitor(withUnderlyingError underlyingError: UnderlyingError?) -> Self {
        return SubprocessError(
            code: .failedToMonitorProcess,
            underlyingError: underlyingError,
            executionContext: nil,
            context: [:]
        )
    }

    internal static func processControlFailed(_ operation: ProcessControlOperation, underlyingError: UnderlyingError?) -> Self {
        return SubprocessError(
            code: .processControlFailed,
            underlyingError: underlyingError,
            executionContext: nil,
            context: [.processControlFailed: .processControlOperation(operation)]
        )
    }

    internal static var spawnFailed: Self {
        return SubprocessError(
            code: .spawnFailed,
            underlyingError: nil,
            executionContext: nil,
            context: [:]
        )
    }

    internal static func spawnFailed(
        withUnderlyingError underlyingError: UnderlyingError?,
        reason: String? = nil
    ) -> Self {
        var context: [SubprocessError.Code: SubprocessError.Context] = [:]
        if let reason = reason {
            context[.spawnFailed] = .string(reason)
        }
        return SubprocessError(
            code: .spawnFailed,
            underlyingError: underlyingError,
            executionContext: nil,
            context: context
        )
    }

    internal static func outputLimitExceeded(limit: Int) -> Self {
        return SubprocessError(
            code: .outputLimitExceeded,
            underlyingError: nil,
            executionContext: nil,
            context: [
                .outputLimitExceeded: .int(limit)
            ]
        )
    }

    internal static func asyncIOFailed(
        reason: String,
        underlyingError: UnderlyingError? = nil
    ) -> Self {
        return SubprocessError(
            code: .asyncIOFailed,
            underlyingError: underlyingError,
            executionContext: nil,
            context: [.asyncIOFailed: .string(reason)]
        )
    }

    internal static func failedToReadFromProcess(
        withUnderlyingError underlyingError: UnderlyingError?
    ) -> Self {
        return SubprocessError(
            code: .failedToReadFromSubprocess,
            underlyingError: underlyingError,
            executionContext: nil,
            context: [:]
        )
    }

    internal static func failedToWriteToProcess(
        withUnderlyingError underlyingError: UnderlyingError?,
        reason: String? = nil
    ) -> Self {
        var context: [SubprocessError.Code: SubprocessError.Context] = [:]
        if let reason = reason {
            context[.failedToWriteToSubprocess] = .string(reason)
        }
        return SubprocessError(
            code: .failedToWriteToSubprocess,
            underlyingError: underlyingError,
            executionContext: nil,
            context: context
        )
    }

    /// The standard input writer was used after it finished.
    ///
    /// The writer is only valid inside the `run(_:)` body closure; `run()` closes
    /// standard input automatically when the body returns, so it must not be stored
    /// or used afterward.
    internal static var standardInputWriterFinished: Self {
        return .failedToWriteToProcess(
            withUnderlyingError: nil,
            reason: """
                the standard input writer has already finished. The writer is only valid
                inside the run(_:) body closure, which closes standard input automatically
                when it returns; don't store the writer or use it after the closure returns.
                """
        )
    }

    internal static func failedToChangeWorkingDirectory(
        _ target: String?,
        underlyingError: UnderlyingError?
    ) -> Self {
        var context: [SubprocessError.Code: SubprocessError.Context] = [:]
        if let targetPath = target {
            context[.failedToChangeWorkingDirectory] = .string(targetPath)
        }
        return SubprocessError(
            code: .failedToChangeWorkingDirectory,
            underlyingError: underlyingError,
            executionContext: nil,
            context: context
        )
    }
}

// MARK: - Execution Context
extension SubprocessError {
    /// Returns a copy of this error with `executionContext` attached.
    ///
    /// Attachment is idempotent: if the error already carries an
    /// `ExecutionContext`, or if `executionContext` is `nil`, the error is
    /// returned unchanged.
    internal func withExecutionContext(
        _ executionContext: ExecutionContext?
    ) -> SubprocessError {
        guard self.executionContext == nil, let executionContext else {
            return self
        }
        return SubprocessError(
            code: self.code,
            underlyingError: self.underlyingError,
            executionContext: executionContext,
            context: self.context
        )
    }
}
