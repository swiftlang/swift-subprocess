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

#if canImport(Glibc) || canImport(Android) || canImport(Musl)

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#endif

internal import Dispatch

import Synchronization
import _SubprocessCShims

// Linux specific implementations
extension Configuration {
    #if SubprocessSpan
    @available(SubprocessSpan, *)
    #endif
    internal func spawn(
        withInput inputPipe: consuming CreatedPipe,
        outputPipe: consuming CreatedPipe,
        errorPipe: consuming CreatedPipe
    ) throws -> SpawnResult {
        _setupMonitorSignalHandler()

        // Instead of checking if every possible executable path
        // is valid, spawn each directly and catch ENOENT
        let possiblePaths = self.executable.possibleExecutablePaths(
            withPathValue: self.environment.pathValue()
        )
        var inputPipeBox: CreatedPipe? = consume inputPipe
        var outputPipeBox: CreatedPipe? = consume outputPipe
        var errorPipeBox: CreatedPipe? = consume errorPipe

        return try self.preSpawn { args throws -> SpawnResult in
            let (env, uidPtr, gidPtr, supplementaryGroups) = args

            var _inputPipe = inputPipeBox.take()!
            var _outputPipe = outputPipeBox.take()!
            var _errorPipe = errorPipeBox.take()!

            let inputReadFileDescriptor: TrackedFileDescriptor? = _inputPipe.readFileDescriptor()
            let inputWriteFileDescriptor: TrackedFileDescriptor? = _inputPipe.writeFileDescriptor()
            let outputReadFileDescriptor: TrackedFileDescriptor? = _outputPipe.readFileDescriptor()
            let outputWriteFileDescriptor: TrackedFileDescriptor? = _outputPipe.writeFileDescriptor()
            let errorReadFileDescriptor: TrackedFileDescriptor? = _errorPipe.readFileDescriptor()
            let errorWriteFileDescriptor: TrackedFileDescriptor? = _errorPipe.writeFileDescriptor()

            for possibleExecutablePath in possiblePaths {
                var processGroupIDPtr: UnsafeMutablePointer<gid_t>? = nil
                if let processGroupID = self.platformOptions.processGroupID {
                    processGroupIDPtr = .allocate(capacity: 1)
                    processGroupIDPtr?.pointee = gid_t(processGroupID)
                }
                // Setup Arguments
                let argv: [UnsafeMutablePointer<CChar>?] = self.arguments.createArgs(
                    withExecutablePath: possibleExecutablePath
                )
                defer {
                    for ptr in argv { ptr?.deallocate() }
                }
                // Setup input
                let fileDescriptors: [CInt] = [
                    inputReadFileDescriptor?.platformDescriptor() ?? -1,
                    inputWriteFileDescriptor?.platformDescriptor() ?? -1,
                    outputWriteFileDescriptor?.platformDescriptor() ?? -1,
                    outputReadFileDescriptor?.platformDescriptor() ?? -1,
                    errorWriteFileDescriptor?.platformDescriptor() ?? -1,
                    errorWriteFileDescriptor?.platformDescriptor() ?? -1,
                ]

                let workingDirectory: String = self.workingDirectory.string
                // Spawn
                var pid: pid_t = 0
                let spawnError: CInt = possibleExecutablePath.withCString { exePath in
                    return workingDirectory.withCString { workingDir in
                        return supplementaryGroups.withOptionalUnsafeBufferPointer { sgroups in
                            return fileDescriptors.withUnsafeBufferPointer { fds in
                                return _subprocess_fork_exec(
                                    &pid,
                                    exePath,
                                    workingDir,
                                    fds.baseAddress!,
                                    argv,
                                    env,
                                    uidPtr,
                                    gidPtr,
                                    processGroupIDPtr,
                                    CInt(supplementaryGroups?.count ?? 0),
                                    sgroups?.baseAddress,
                                    self.platformOptions.createSession ? 1 : 0,
                                    self.platformOptions.preSpawnProcessConfigurator
                                )
                            }
                        }
                    }
                }
                // Spawn error
                if spawnError != 0 {
                    if spawnError == ENOENT || spawnError == EACCES {
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
                        underlyingError: .init(rawValue: spawnError)
                    )
                }
                func captureError(_ work: () throws -> Void) -> (any Swift.Error)? {
                    do {
                        try work()
                        return nil
                    } catch {
                        return error
                    }
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
                    inputWriteEnd: inputWriteFileDescriptor?.createPlatformDiskIO(),
                    outputReadEnd: outputReadFileDescriptor?.createPlatformDiskIO(),
                    errorReadEnd: errorReadFileDescriptor?.createPlatformDiskIO()
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
            let workingDirectory = self.workingDirectory.string
            guard Configuration.pathAccessible(workingDirectory, mode: F_OK) else {
                throw SubprocessError(
                    code: .init(.failedToChangeWorkingDirectory(workingDirectory)),
                    underlyingError: .init(rawValue: ENOENT)
                )
            }
            throw SubprocessError(
                code: .init(.executableNotFound(self.executable.description)),
                underlyingError: .init(rawValue: ENOENT)
            )
        }
    }
}

// MARK: - Platform Specific Options

/// The collection of platform-specific settings
/// to configure the subprocess when running
public struct PlatformOptions: Sendable {
    // Set user ID for the subprocess
    public var userID: uid_t? = nil
    /// Set the real and effective group ID and the saved
    /// set-group-ID of the subprocess, equivalent to calling
    /// `setgid()` on the child process.
    /// Group ID is used to control permissions, particularly
    /// for file access.
    public var groupID: gid_t? = nil
    // Set list of supplementary group IDs for the subprocess
    public var supplementaryGroups: [gid_t]? = nil
    /// Set the process group for the subprocess, equivalent to
    /// calling `setpgid()` on the child process.
    /// Process group ID is used to group related processes for
    /// controlling signals.
    public var processGroupID: pid_t? = nil
    // Creates a session and sets the process group ID
    // i.e. Detach from the terminal.
    public var createSession: Bool = false
    /// An ordered list of steps in order to tear down the child
    /// process in case the parent task is cancelled before
    /// the child proces terminates.
    /// Always ends in sending a `.kill` signal at the end.
    public var teardownSequence: [TeardownStep] = []
    /// A closure to configure platform-specific
    /// spawning constructs. This closure enables direct
    /// configuration or override of underlying platform-specific
    /// spawn settings that `Subprocess` utilizes internally,
    /// in cases where Subprocess does not provide higher-level
    /// APIs for such modifications.
    ///
    /// On Linux, Subprocess uses `fork/exec` as the
    /// underlying spawning mechanism. This closure is called
    /// after `fork()` but before `exec()`. You may use it to
    /// call any necessary process setup functions.
    public var preSpawnProcessConfigurator: (@convention(c) @Sendable () -> Void)? = nil

    public init() {}
}

extension PlatformOptions: CustomStringConvertible, CustomDebugStringConvertible {
    internal func description(withIndent indent: Int) -> String {
        let indent = String(repeating: " ", count: indent * 4)
        return """
            PlatformOptions(
            \(indent)    userID: \(String(describing: userID)),
            \(indent)    groupID: \(String(describing: groupID)),
            \(indent)    supplementaryGroups: \(String(describing: supplementaryGroups)),
            \(indent)    processGroupID: \(String(describing: processGroupID)),
            \(indent)    createSession: \(createSession),
            \(indent)    preSpawnProcessConfigurator: \(self.preSpawnProcessConfigurator == nil ? "not set" : "set")
            \(indent))
            """
    }

    public var description: String {
        return self.description(withIndent: 0)
    }

    public var debugDescription: String {
        return self.description(withIndent: 0)
    }
}

// Special keys used in Error's user dictionary
extension String {
    static let debugDescriptionErrorKey = "DebugDescription"
}

// MARK: - Process Monitoring
@Sendable
internal func monitorProcessTermination(
    forProcessWithIdentifier pid: ProcessIdentifier
) async throws -> TerminationStatus {
    return try await withCheckedThrowingContinuation { continuation in
        _childProcessContinuations.withLock { continuations in
            if let existing = continuations.removeValue(forKey: pid.value),
                case .status(let existingStatus) = existing
            {
                // We already have existing status to report
                continuation.resume(returning: existingStatus)
            } else {
                // Save the continuation for handler
                continuations[pid.value] = .continuation(continuation)
            }
        }
    }
}

private enum ContinuationOrStatus {
    case continuation(CheckedContinuation<TerminationStatus, any Error>)
    case status(TerminationStatus)
}

private let _childProcessContinuations:
    Mutex<
        [pid_t: ContinuationOrStatus]
    > = Mutex([:])

private let signalSource: SendableSourceSignal = SendableSourceSignal()

private extension siginfo_t {
    var si_status: Int32 {
        #if canImport(Glibc)
        return _sifields._sigchld.si_status
        #elseif canImport(Musl)
        return __si_fields.__si_common.__second.__sigchld.si_status
        #elseif canImport(Bionic)
        return _sifields._sigchld._status
        #endif
    }

    var si_pid: pid_t {
        #if canImport(Glibc)
        return _sifields._sigchld.si_pid
        #elseif canImport(Musl)
        return __si_fields.__si_common.__first.__piduid.si_pid
        #elseif canImport(Bionic)
        return _sifields._kill._pid
        #endif
    }
}

private let setup: () = {
    signalSource.setEventHandler {
        while true {
            var siginfo = siginfo_t()
            guard waitid(P_ALL, id_t(0), &siginfo, WEXITED) == 0 || errno == EINTR else {
                return
            }
            var status: TerminationStatus? = nil
            switch siginfo.si_code {
            case .init(CLD_EXITED):
                status = .exited(siginfo.si_status)
            case .init(CLD_KILLED), .init(CLD_DUMPED):
                status = .unhandledException(siginfo.si_status)
            case .init(CLD_TRAPPED), .init(CLD_STOPPED), .init(CLD_CONTINUED):
                // Ignore these signals because they are not related to
                // process exiting
                break
            default:
                fatalError("Unexpected exit status: \(siginfo.si_code)")
            }
            if let status = status {
                _childProcessContinuations.withLock { continuations in
                    let pid = siginfo.si_pid
                    if let existing = continuations.removeValue(forKey: pid),
                        case .continuation(let c) = existing
                    {
                        c.resume(returning: status)
                    } else {
                        // We don't have continuation yet, just state status
                        continuations[pid] = .status(status)
                    }
                }
            }
        }
    }
    signalSource.resume()
}()

/// Unchecked Sendable here since this class is only explicitly
/// initialized once during the lifetime of the process
final class SendableSourceSignal: @unchecked Sendable {
    private let signalSource: DispatchSourceSignal

    func setEventHandler(handler: @escaping DispatchSourceHandler) {
        self.signalSource.setEventHandler(handler: handler)
    }

    func resume() {
        self.signalSource.resume()
    }

    init() {
        self.signalSource = DispatchSource.makeSignalSource(
            signal: SIGCHLD,
            queue: .global()
        )
    }
}

private func _setupMonitorSignalHandler() {
    // Only executed once
    setup
}

#endif  // canImport(Glibc) || canImport(Android) || canImport(Musl)
