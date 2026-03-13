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
@preconcurrency import WinSDK
#endif

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

/// Error thrown from Subprocess. `SubprocessError` may wrap an
/// `underlyingError` to represent what caused this error
public struct SubprocessError: Swift.Error, Sendable, Hashable {
    /// The error code of this error
    public let code: SubprocessError.Code
    /// The underlying error that caused this error
    public let underlyingError: UnderlyingError?

    /// Context associated with this error for better error message
    private let context: [Code: Context]
}

// MARK: - Error Codes
extension SubprocessError {
    /// A SubprocessError Code
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
    /// Error code indicating process spawning failed
    public static var spawnFailed: Self { .init(.spawnFailed) }
    /// Error code indicating target executable is not found
    public static var executableNotFound: Self { .init(.executableNotFound) }
    /// Error code indicating working directory is not valid or subprocess
    /// failed to change working directory when spawning child process
    public static var failedToChangeWorkingDirectory: Self { .init(.failedToChangeWorkingDirectory) }
    /// Error code indicating subprocess has failed to monitor the exit status of child process.
    public static var failedToMonitorProcess: Self { .init(.failedToMonitorProcess) }

    /// Error code indicating subprocess failed to read data from the child process
    public static var failedToReadFromSubprocess: Self { .init(.failedToReadFromSubprocess) }
    /// Error code indicating subprocess failed to write data to the child process
    public static var failedToWriteToSubprocess: Self { .init(.failedToWriteToSubprocess) }
    /// Error code indicating child process output has exceeded the set limit
    public static var outputLimitExceeded: Self { .init(.outputLimitExceeded) }
    /// Error code indicating platform specific AsyncIO failed
    public static var asyncIOFailed: Self { .init(.asyncIOFailed) }

    /// Error code indicating subprocess failed to control the child process such as
    /// sending signal and terminating process
    public static var processControlFailed: Self { .init(.processControlFailed) }
}

// MARK: - Underlying types
extension SubprocessError {
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
            var message = ["Failed to spawn the new process."]

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
                return "Failed to monitor the child process exit status with underlying error: \(underlying)"
            } else {
                return "Failed to monitor the child process exit status."
            }

        case .failedToReadFromSubprocess:
            if let underlying = self.underlyingError {
                return "Failed to read bytes from the child process with underlying error: \(underlying)"
            } else {
                return "Failed to read bytes from the child process."
            }
        case .failedToWriteToSubprocess:
            if let underlying = self.underlyingError {
                return "Failed to write bytes to the child process with underlying error: \(underlying)"
            } else {
                return "Failed to write bytes to the child process."
            }
        case .outputLimitExceeded:
            if let context = self.context[self.code],
                case .int(let limit) = context
            {
                return "Child process output exceeded the limit of \(limit) bytes."
            } else {
                return "Child process output exceeded the limit."
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
                    return "Failed to send signal \(signal) to child process"
                case .terminate:
                    return "Failed to terminate child process."
                case .suspend:
                    return "Failed to suspend child process."
                case .resume:
                    return "Failed to resume child process."
                }
            } else {
                return "Failed to control child process state"
            }
        }
    }

    /// A debug-oriented textual representation of this subprocess error.
    public var debugDescription: String { self.description }
}

#if os(Windows)

extension SubprocessError {
    /// An error that represents a Windows error code returned by `GetLastError`
    public struct WindowsError: Error, RawRepresentable, Hashable {
        public let rawValue: DWORD

        public init(rawValue: DWORD) {
            self.rawValue = rawValue
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
            context: [.executableNotFound: .string(executable)]
        )
    }

    internal static func failedToMonitor(withUnderlyingError underlyingError: UnderlyingError?) -> Self {
        return SubprocessError(
            code: .failedToMonitorProcess,
            underlyingError: underlyingError,
            context: [:]
        )
    }

    internal static func processControlFailed(_ operation: ProcessControlOperation, underlyingError: UnderlyingError?) -> Self {
        return SubprocessError(
            code: .processControlFailed,
            underlyingError: underlyingError,
            context: [.processControlFailed: .processControlOperation(operation)]
        )
    }

    internal static var spawnFailed: Self {
        return SubprocessError(
            code: .spawnFailed,
            underlyingError: nil,
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
            context: context
        )
    }

    internal static func outputLimitExceeded(limit: Int) -> Self {
        return SubprocessError(
            code: .outputLimitExceeded,
            underlyingError: nil,
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
            context: [.asyncIOFailed: .string(reason)]
        )
    }

    internal static func failedToReadFromProcess(
        withUnderlyingError underlyingError: UnderlyingError?
    ) -> Self {
        return SubprocessError(
            code: .failedToReadFromSubprocess,
            underlyingError: underlyingError,
            context: [:]
        )
    }

    internal static func failedToWriteToProcess(
        withUnderlyingError underlyingError: UnderlyingError?
    ) -> Self {
        return SubprocessError(
            code: .failedToWriteToSubprocess,
            underlyingError: underlyingError,
            context: [:]
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
            context: context
        )
    }
}
