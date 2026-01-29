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

/// Error thrown from Subprocess
public struct SubprocessError: Swift.Error, Sendable, Equatable {
    /// The error code of this error
    public let code: SubprocessError.Code
    /// The underlying error that caused this error, if any
    public let underlyingError: (any Error)?

    public static func == (lhs: SubprocessError, rhs: SubprocessError) -> Bool {
        guard lhs.code == rhs.code else {
            return false
        }

        switch (lhs.underlyingError, rhs.underlyingError) {
        case (.none, .none):
            return true
        case (let lhsErrno as Errno, let rhsErrno as Errno):
            return lhsErrno == rhsErrno
        case (let lhsSubError as SubprocessError, let rhsSubError as SubprocessError):
            return lhsSubError == rhsSubError
        #if os(Windows)
        case (let lhsWindowsError as WindowsError, let rhsWindowsError as WindowsError):
            return lhsWindowsError == rhsWindowsError
        #endif
        default:
            return false
        }
    }
}

// MARK: - Error Codes
extension SubprocessError {
    /// A SubprocessError Code
    public struct Code: Hashable, Sendable {
        internal enum Storage: Hashable, Sendable {
            case spawnFailed
            case executableNotFound(String)
            case failedToChangeWorkingDirectory(String)
            case failedToReadFromSubprocess
            case failedToWriteToSubprocess
            case failedToMonitorProcess
            case streamOutputExceedsLimit(Int)
            case asyncIOFailed(String)
            case outputBufferLimitExceeded(Int)
            // Signal
            case failedToSendSignal(Int32)
            // Windows Only
            case failedToTerminate
            case failedToSuspend
            case failedToResume
            case failedToCreatePipe
            case invalidWindowsPath(String)

            case executionBodyThrewError
        }

        /// The numeric value of this code.
        public var value: Int {
            switch self.storage {
            case .spawnFailed:
                return 0
            case .executableNotFound(_):
                return 1
            case .failedToChangeWorkingDirectory(_):
                return 2
            case .failedToReadFromSubprocess:
                return 3
            case .failedToWriteToSubprocess:
                return 4
            case .failedToMonitorProcess:
                return 5
            case .streamOutputExceedsLimit(_):
                return 6
            case .asyncIOFailed(_):
                return 7
            case .outputBufferLimitExceeded(_):
                return 8
            case .failedToSendSignal(_):
                return 9
            case .failedToTerminate:
                return 10
            case .failedToSuspend:
                return 11
            case .failedToResume:
                return 12
            case .failedToCreatePipe:
                return 13
            case .invalidWindowsPath(_):
                return 14
            case .executionBodyThrewError:
                return 15
            }
        }

        internal let storage: Storage

        internal init(_ storage: Storage) {
            self.storage = storage
        }
    }
}

// MARK: - Description
extension SubprocessError: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual representation of this subprocess error.
    public var description: String {
        switch self.code.storage {
        case .spawnFailed:
            return "Failed to spawn the new process with underlying error: \(self.underlyingError!)"
        case .executableNotFound(let executableName):
            return "Executable \"\(executableName)\" is not found or cannot be executed."
        case .failedToChangeWorkingDirectory(let workingDirectory):
            return "Failed to set working directory to \"\(workingDirectory)\"."
        case .failedToReadFromSubprocess:
            return "Failed to read bytes from the child process with underlying error: \(self.underlyingError!)"
        case .failedToWriteToSubprocess:
            return "Failed to write bytes to the child process."
        case .failedToMonitorProcess:
            return "Failed to monitor the state of child process with underlying error: \(self.underlyingError.map { "\($0)" } ?? "nil")"
        case .streamOutputExceedsLimit(let limit):
            return "Failed to create output from current buffer because the output limit (\(limit)) was reached."
        case .asyncIOFailed(let reason):
            return "An error occurred within the AsyncIO subsystem: \(reason). Underlying error: \(self.underlyingError!)"
        case .outputBufferLimitExceeded(let limit):
            return "Output exceeds the limit of \(limit) bytes."
        case .failedToSendSignal(let signal):
            return "Failed to send signal \(signal) to the child process."
        case .failedToTerminate:
            return "Failed to terminate the child process."
        case .failedToSuspend:
            return "Failed to suspend the child process."
        case .failedToResume:
            return "Failed to resume the child process."
        case .failedToCreatePipe:
            return "Failed to create a pipe to communicate to child process."
        case .invalidWindowsPath(let badPath):
            return "\"\(badPath)\" is not a valid Windows path."
        case .executionBodyThrewError:
            if let error = self.underlyingError {
                return "Execution body threw an error: \(error)"
            } else {
                return "Execution body threw an error."
            }
        }
    }

    /// A debug-oriented textual representation of this subprocess error.
    public var debugDescription: String { self.description }
}

#if os(Windows)

extension SubprocessError {
    /// An error that represents a Windows error code returned by `GetLastError`
    public struct WindowsError: Error, RawRepresentable {
        public let rawValue: DWORD

        public init(rawValue: DWORD) {
            self.rawValue = rawValue
        }
    }
}

#endif
