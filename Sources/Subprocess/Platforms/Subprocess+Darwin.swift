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
internal import Dispatch
#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

import _SubprocessCShims

#if SubprocessFoundation

#if canImport(Darwin)
// On Darwin always prefer system Foundation
import Foundation
#else
// On other platforms prefer FoundationEssentials
import FoundationEssentials
#endif

#endif // SubprocessFoundation

// MARK: - PlatformOptions

/// The collection of platform-specific settings
/// to configure the subprocess when running
public struct PlatformOptions: Sendable {
    /// Constants that indicate the nature and importance of work to the system.
    public var qualityOfService: QualityOfService = .default
    /// Set user ID for the subprocess
    public var userID: uid_t? = nil
    /// Set the real and effective group ID and the saved
    /// set-group-ID of the subprocess, equivalent to calling
    /// `setgid()` on the child process.
    /// Group ID is used to control permissions, particularly
    /// for file access.
    public var groupID: gid_t? = nil
    /// Set list of supplementary group IDs for the subprocess
    public var supplementaryGroups: [gid_t]? = nil
    /// Set the process group for the subprocess, equivalent to
    /// calling `setpgid()` on the child process.
    /// Process group ID is used to group related processes for
    /// controlling signals.
    public var processGroupID: pid_t? = nil
    /// Creates a session and sets the process group ID
    /// i.e. Detach from the terminal.
    public var createSession: Bool = false
    /// An ordered list of steps in order to tear down the child
    /// process in case the parent task is cancelled before
    /// the child process terminates.
    /// Always ends in sending a `.kill` signal at the end.
    public var teardownSequence: [TeardownStep] = []
    /// A closure to configure platform-specific
    /// spawning constructs. This closure enables direct
    /// configuration or override of underlying platform-specific
    /// spawn settings that `Subprocess` utilizes internally,
    /// in cases where Subprocess does not provide higher-level
    /// APIs for such modifications.
    ///
    /// On Darwin, Subprocess uses `posix_spawn()` as the
    /// underlying spawning mechanism. This closure allows
    /// modification of the `posix_spawnattr_t` spawn attribute
    /// and file actions `posix_spawn_file_actions_t` before
    /// they are sent to `posix_spawn()`.
    public var preSpawnProcessConfigurator:
        (
            @Sendable
            (
                inout posix_spawnattr_t?,
                inout posix_spawn_file_actions_t?
            ) throws(SubprocessError) -> Void
        )? = nil

    /// Create platform options with the default values.
    public init() {}
}

extension PlatformOptions {
    #if SubprocessFoundation
    /// Constants that indicate the nature and importance of work to the system.
    public typealias QualityOfService = Foundation.QualityOfService
    #else
    /// Constants that indicate the nature and importance of work to the system.
    ///
    /// Work with higher quality of service classes receive more resources
    /// than work with lower quality of service classes whenever
    /// there’s resource contention.
    public enum QualityOfService: Int, Sendable {
        /// Used for work directly involved in providing an
        /// interactive UI. For example, processing control
        /// events or drawing to the screen.
        case userInteractive = 0x21
        /// Used for performing work that has been explicitly requested
        /// by the user, and for which results must be immediately
        /// presented in order to allow for further user interaction.
        /// For example, loading an email after a user has selected
        /// it in a message list.
        case userInitiated = 0x19
        /// Used for performing work which the user is unlikely to be
        /// immediately waiting for the results. This work may have been
        /// requested by the user or initiated automatically, and often
        /// operates at user-visible timescales using a non-modal
        /// progress indicator. For example, periodic content updates
        /// or bulk file operations, such as media import.
        case utility = 0x11
        /// Used for work that is not user initiated or visible.
        /// In general, a user is unaware that this work is even happening.
        /// For example, pre-fetching content, search indexing, backups,
        /// or syncing of data with external systems.
        case background = 0x09
        /// Indicates no explicit quality of service information.
        /// Whenever possible, an appropriate quality of service is determined
        /// from available sources. Otherwise, some quality of service level
        /// between `.userInteractive` and `.utility` is used.
        case `default` = -1
    }
    #endif
}

extension PlatformOptions: CustomStringConvertible, CustomDebugStringConvertible {
    internal func description(withIndent indent: Int) -> String {
        if #available(macOS 15.0, *) {
            let indent = String(repeating: " ", count: indent * 4)
            return """
                PlatformOptions(
                \(indent)    qualityOfService: \(self.qualityOfService),
                \(indent)    userID: \(String(describing: userID)),
                \(indent)    groupID: \(String(describing: groupID)),
                \(indent)    supplementaryGroups: \(String(describing: supplementaryGroups)),
                \(indent)    processGroupID: \(String(describing: processGroupID)),
                \(indent)    createSession: \(createSession),
                \(indent)    preSpawnProcessConfigurator: \(self.preSpawnProcessConfigurator == nil ? "not set" : "set")
                \(indent))
                """
        } else {
            let indent = String(repeating: " ", count: indent * 4)
            return """
                PlatformOptions(
                \(indent)    qualityOfService: \(self.qualityOfService),
                \(indent)    userID: \(String(describing: userID)),
                \(indent)    groupID: \(String(describing: groupID)),
                \(indent)    supplementaryGroups: \(String(describing: supplementaryGroups)),
                \(indent)    processGroupID: \(String(describing: processGroupID)),
                \(indent)    createSession: \(createSession)
                \(indent))
                """
        }
    }

    /// A textual representation of the platform options.
    public var description: String {
        return self.description(withIndent: 0)
    }

    /// A debug oriented textual representation of the platform options.
    public var debugDescription: String {
        return self.description(withIndent: 0)
    }
}

// MARK: - Spawn
extension Configuration {
    // @unchecked Sendable because we need to capture UnsafePointers
    // to send to another thread. While UnsafePointers are not
    // Sendable, we are not mutating them -- we only need these type
    // for C interface.
    internal struct SpawnContext: @unchecked Sendable {
        let fileActions: posix_spawn_file_actions_t?
        let spawnAttributes: posix_spawnattr_t?
        let argv: [UnsafeMutablePointer<CChar>?]
        let env: [UnsafeMutablePointer<CChar>?]
        let uidPtr: UnsafeMutablePointer<uid_t>?
        let gidPtr: UnsafeMutablePointer<gid_t>?
    }

    internal func spawn(
        withInput inputPipe: consuming CreatedPipe,
        outputPipe: consuming CreatedPipe,
        errorPipe: consuming CreatedPipe
    ) async throws(SubprocessError) -> SpawnResult {
        // Instead of checking if every possible executable path
        // is valid, spawn each directly and catch ENOENT
        let possiblePaths = self.executable.possibleExecutablePaths(
            withPathValue: self.environment.pathValue()
        )
        var inputPipeBox: CreatedPipe? = consume inputPipe
        var outputPipeBox: CreatedPipe? = consume outputPipe
        var errorPipeBox: CreatedPipe? = consume errorPipe

        return try await self.preSpawn { args throws(SubprocessError) -> SpawnResult in
            let (env, uidPtr, gidPtr, supplementaryGroups) = args
            var _inputPipe = inputPipeBox.take()!
            var _outputPipe = outputPipeBox.take()!
            var _errorPipe = errorPipeBox.take()!

            let inputReadFileDescriptor: IODescriptor? = _inputPipe.readFileDescriptor()
            let inputWriteFileDescriptor: IODescriptor? = _inputPipe.writeFileDescriptor()
            let outputReadFileDescriptor: IODescriptor? = _outputPipe.readFileDescriptor()
            let outputWriteFileDescriptor: IODescriptor? = _outputPipe.writeFileDescriptor()
            let errorReadFileDescriptor: IODescriptor? = _errorPipe.readFileDescriptor()
            let errorWriteFileDescriptor: IODescriptor? = _errorPipe.writeFileDescriptor()

            for possibleExecutablePath in possiblePaths {
                // Setup Arguments
                let argv: [UnsafeMutablePointer<CChar>?] = self.arguments.createArgs(
                    withExecutablePath: possibleExecutablePath
                )
                defer {
                    for ptr in argv { ptr?.deallocate() }
                }

                // Setup file actions and spawn attributes
                var fileActions: posix_spawn_file_actions_t? = nil
                var spawnAttributes: posix_spawnattr_t? = nil
                // Setup stdin, stdout, and stderr
                posix_spawn_file_actions_init(&fileActions)
                defer {
                    posix_spawn_file_actions_destroy(&fileActions)
                }

                // Input
                var result: Int32 = -1
                if inputReadFileDescriptor != nil {
                    result = posix_spawn_file_actions_adddup2(
                        &fileActions, inputReadFileDescriptor!.platformDescriptor(), 0)
                    guard result == 0 else {
                        try self.safelyCloseMultiple(
                            inputRead: inputReadFileDescriptor,
                            inputWrite: inputWriteFileDescriptor,
                            outputRead: outputReadFileDescriptor,
                            outputWrite: outputWriteFileDescriptor,
                            errorRead: errorReadFileDescriptor,
                            errorWrite: errorWriteFileDescriptor
                        )
                        throw SubprocessError(
                            code: .init(.spawnFailed),
                            underlyingError: Errno(rawValue: result)
                        )
                    }
                }
                if inputWriteFileDescriptor != nil {
                    // Close parent side
                    result = posix_spawn_file_actions_addclose(
                        &fileActions, inputWriteFileDescriptor!.platformDescriptor()
                    )
                    guard result == 0 else {
                        try self.safelyCloseMultiple(
                            inputRead: inputReadFileDescriptor,
                            inputWrite: inputWriteFileDescriptor,
                            outputRead: outputReadFileDescriptor,
                            outputWrite: outputWriteFileDescriptor,
                            errorRead: errorReadFileDescriptor,
                            errorWrite: errorWriteFileDescriptor
                        )
                        throw SubprocessError(
                            code: .init(.spawnFailed),
                            underlyingError: Errno(rawValue: result)
                        )
                    }
                }
                // Output
                if outputWriteFileDescriptor != nil {
                    result = posix_spawn_file_actions_adddup2(
                        &fileActions, outputWriteFileDescriptor!.platformDescriptor(), 1
                    )
                    guard result == 0 else {
                        try self.safelyCloseMultiple(
                            inputRead: inputReadFileDescriptor,
                            inputWrite: inputWriteFileDescriptor,
                            outputRead: outputReadFileDescriptor,
                            outputWrite: outputWriteFileDescriptor,
                            errorRead: errorReadFileDescriptor,
                            errorWrite: errorWriteFileDescriptor
                        )
                        throw SubprocessError(
                            code: .init(.spawnFailed),
                            underlyingError: Errno(rawValue: result)
                        )
                    }
                }
                if outputReadFileDescriptor != nil {
                    // Close parent side
                    result = posix_spawn_file_actions_addclose(
                        &fileActions, outputReadFileDescriptor!.platformDescriptor()
                    )
                    guard result == 0 else {
                        try self.safelyCloseMultiple(
                            inputRead: inputReadFileDescriptor,
                            inputWrite: inputWriteFileDescriptor,
                            outputRead: outputReadFileDescriptor,
                            outputWrite: outputWriteFileDescriptor,
                            errorRead: errorReadFileDescriptor,
                            errorWrite: errorWriteFileDescriptor
                        )
                        throw SubprocessError(
                            code: .init(.spawnFailed),
                            underlyingError: Errno(rawValue: result)
                        )
                    }
                }
                // Error
                if errorWriteFileDescriptor != nil {
                    result = posix_spawn_file_actions_adddup2(
                        &fileActions, errorWriteFileDescriptor!.platformDescriptor(), 2
                    )
                    guard result == 0 else {
                        try self.safelyCloseMultiple(
                            inputRead: inputReadFileDescriptor,
                            inputWrite: inputWriteFileDescriptor,
                            outputRead: outputReadFileDescriptor,
                            outputWrite: outputWriteFileDescriptor,
                            errorRead: errorReadFileDescriptor,
                            errorWrite: errorWriteFileDescriptor
                        )
                        throw SubprocessError(
                            code: .init(.spawnFailed),
                            underlyingError: Errno(rawValue: result)
                        )
                    }
                }
                if errorReadFileDescriptor != nil {
                    // Close parent side
                    result = posix_spawn_file_actions_addclose(
                        &fileActions, errorReadFileDescriptor!.platformDescriptor()
                    )
                    guard result == 0 else {
                        try self.safelyCloseMultiple(
                            inputRead: inputReadFileDescriptor,
                            inputWrite: inputWriteFileDescriptor,
                            outputRead: outputReadFileDescriptor,
                            outputWrite: outputWriteFileDescriptor,
                            errorRead: errorReadFileDescriptor,
                            errorWrite: errorWriteFileDescriptor
                        )
                        throw SubprocessError(
                            code: .init(.spawnFailed),
                            underlyingError: Errno(rawValue: result)
                        )
                    }
                }
                // Setup spawnAttributes
                posix_spawnattr_init(&spawnAttributes)
                defer {
                    posix_spawnattr_destroy(&spawnAttributes)
                }
                var noSignals = sigset_t()
                var allSignals = sigset_t()
                sigemptyset(&noSignals)
                sigfillset(&allSignals)
                posix_spawnattr_setsigmask(&spawnAttributes, &noSignals)
                posix_spawnattr_setsigdefault(&spawnAttributes, &allSignals)
                // Configure spawnattr
                var spawnAttributeError: Int32 = 0
                var flags: Int32 = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                if let pgid = self.platformOptions.processGroupID {
                    flags |= POSIX_SPAWN_SETPGROUP
                    spawnAttributeError = posix_spawnattr_setpgroup(&spawnAttributes, pid_t(pgid))
                }
                spawnAttributeError = posix_spawnattr_setflags(&spawnAttributes, Int16(flags))
                // Set QualityOfService
                // spanattr_qos seems to only accept `QOS_CLASS_UTILITY` or `QOS_CLASS_BACKGROUND`
                // and returns an error of `EINVAL` if anything else is provided
                if spawnAttributeError == 0 && self.platformOptions.qualityOfService == .utility {
                    spawnAttributeError = posix_spawnattr_set_qos_class_np(&spawnAttributes, QOS_CLASS_UTILITY)
                } else if spawnAttributeError == 0 && self.platformOptions.qualityOfService == .background {
                    spawnAttributeError = posix_spawnattr_set_qos_class_np(&spawnAttributes, QOS_CLASS_BACKGROUND)
                }

                // Setup cwd
                let chdirError: Int32
                if let intendedWorkingDir = self.workingDirectory?.string {
                    chdirError = intendedWorkingDir.withPlatformString { workDir in
                        return posix_spawn_file_actions_addchdir_np(&fileActions, workDir)
                    }
                } else {
                    chdirError = 0
                }

                // Error handling
                if chdirError != 0 || spawnAttributeError != 0 {
                    try self.safelyCloseMultiple(
                        inputRead: inputReadFileDescriptor,
                        inputWrite: inputWriteFileDescriptor,
                        outputRead: outputReadFileDescriptor,
                        outputWrite: outputWriteFileDescriptor,
                        errorRead: errorReadFileDescriptor,
                        errorWrite: errorWriteFileDescriptor
                    )

                    let error: SubprocessError
                    if spawnAttributeError != 0 {
                        error = SubprocessError(
                            code: .init(.spawnFailed),
                            underlyingError: Errno(rawValue: spawnAttributeError)
                        )
                    } else {
                        error = SubprocessError(
                            code: .init(.failedToChangeWorkingDirectory(self.workingDirectory?.string ?? "unknown")),
                            underlyingError: Errno(rawValue: chdirError)
                        )
                    }
                    throw error
                }
                // Run additional config
                if let spawnConfig = self.platformOptions.preSpawnProcessConfigurator {
                    try spawnConfig(&spawnAttributes, &fileActions)
                }

                // Spawn
                let spawnContext = SpawnContext(
                    fileActions: fileActions,
                    spawnAttributes: spawnAttributes,
                    argv: argv,
                    env: env,
                    uidPtr: uidPtr,
                    gidPtr: gidPtr
                )
                let (spawnError, pid) = try await runOnBackgroundThread {
                    return possibleExecutablePath._withCString { exePath in
                        return supplementaryGroups.withOptionalUnsafeBufferPointer { sgroups in
                            var pid: pid_t = 0
                            var _fileActions = spawnContext.fileActions
                            var _spawnAttributes = spawnContext.spawnAttributes
                            let rc = _subprocess_spawn(
                                &pid,
                                exePath,
                                &_fileActions,
                                &_spawnAttributes,
                                spawnContext.argv,
                                spawnContext.env,
                                spawnContext.uidPtr,
                                spawnContext.gidPtr,
                                Int32(supplementaryGroups?.count ?? 0),
                                sgroups?.baseAddress,
                                self.platformOptions.createSession ? 1 : 0
                            )
                            return (rc, pid)
                        }
                    }
                }
                // Spawn error
                if spawnError != 0 {
                    if [ENOENT, EACCES, ENOTDIR].contains(spawnError) {
                        // Move on to another possible path
                        continue
                    }
                    // Throw all other errors
                    try self.safelyCloseMultiple(
                        inputRead: inputReadFileDescriptor,
                        inputWrite: inputWriteFileDescriptor,
                        outputRead: outputReadFileDescriptor,
                        outputWrite: outputWriteFileDescriptor,
                        errorRead: errorReadFileDescriptor,
                        errorWrite: errorWriteFileDescriptor
                    )
                    throw SubprocessError(
                        code: .init(.spawnFailed),
                        underlyingError: Errno(rawValue: spawnError)
                    )
                }

                // After spawn finishes, close all child side fds
                try self.safelyCloseMultiple(
                    inputRead: inputReadFileDescriptor,
                    inputWrite: nil,
                    outputRead: nil,
                    outputWrite: outputWriteFileDescriptor,
                    errorRead: nil,
                    errorWrite: errorWriteFileDescriptor
                )

                let execution = Execution(
                    processIdentifier: .init(value: pid)
                )
                return SpawnResult(
                    execution: execution,
                    inputWriteEnd: inputWriteFileDescriptor?.createIOChannel(),
                    outputReadEnd: outputReadFileDescriptor?.createIOChannel(),
                    errorReadEnd: errorReadFileDescriptor?.createIOChannel()
                )
            }

            // If we reach this point, it means either the executable path
            // or working directory is not valid. Since posix_spawn does not
            // provide which one is not valid, here we make a best effort guess
            // by checking whether the working directory is valid. This technically
            // still causes TOUTOC issue, but it's the best we can do for error recovery.
            try self.safelyCloseMultiple(
                inputRead: inputReadFileDescriptor,
                inputWrite: inputWriteFileDescriptor,
                outputRead: outputReadFileDescriptor,
                outputWrite: outputWriteFileDescriptor,
                errorRead: errorReadFileDescriptor,
                errorWrite: errorWriteFileDescriptor
            )
            if let workingDirectory = self.workingDirectory?.string {
                guard Configuration.pathAccessible(workingDirectory, mode: F_OK) else {
                    throw SubprocessError(
                        code: .init(.failedToChangeWorkingDirectory(workingDirectory)),
                        underlyingError: Errno(rawValue: ENOENT)
                    )
                }
            }
            throw SubprocessError(
                code: .init(.executableNotFound(self.executable.description)),
                underlyingError: Errno(rawValue: ENOENT)
            )
        }
    }
}

// MARK: - ProcessIdentifier

/// A platform-independent identifier for a Subprocess.
public struct ProcessIdentifier: Sendable, Hashable {
    /// The platform specific process identifier value
    public let value: pid_t

    /// Initialize a process identifier with the value you provide.
    public init(value: pid_t) {
        self.value = value
    }

    internal func close() { /* No-op on Darwin */  }
}

extension ProcessIdentifier: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual representation of the process identifier.
    public var description: String { "\(self.value)" }
    /// A debug-oriented textual representation of the process identifier.
    public var debugDescription: String { "\(self.value)" }
}

#endif // canImport(Darwin)
