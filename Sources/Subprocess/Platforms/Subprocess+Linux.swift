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
    internal func spawn(
        withInput inputPipe: consuming CreatedPipe,
        outputPipe: consuming CreatedPipe,
        errorPipe: consuming CreatedPipe
    ) throws -> SpawnResult {
        // Ensure the waiter thread is running.
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

            let inputReadFileDescriptor: IODescriptor? = _inputPipe.readFileDescriptor()
            let inputWriteFileDescriptor: IODescriptor? = _inputPipe.writeFileDescriptor()
            let outputReadFileDescriptor: IODescriptor? = _outputPipe.readFileDescriptor()
            let outputWriteFileDescriptor: IODescriptor? = _outputPipe.writeFileDescriptor()
            let errorReadFileDescriptor: IODescriptor? = _errorPipe.readFileDescriptor()
            let errorWriteFileDescriptor: IODescriptor? = _errorPipe.writeFileDescriptor()

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
                    errorReadFileDescriptor?.platformDescriptor() ?? -1,
                ]

                // Spawn
                var pid: pid_t = 0
                let spawnError: CInt = possibleExecutablePath.withCString { exePath in
                    return (self.workingDirectory?.string).withOptionalCString { workingDir in
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
                        underlyingError: .init(rawValue: ENOENT)
                    )
                }
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
    forExecution execution: Execution
) async throws -> TerminationStatus {
    try await withCheckedThrowingContinuation { continuation in
        _childProcessContinuations.withLock { continuations in
            // We don't need to worry about a race condition here because waitid()
            // does not clear the wait/zombie state of the child process. If it sees
            // the child process has terminated and manages to acquire the lock before
            // we add this continuation to the dictionary, then it will simply loop
            // and report the status again.
            let oldContinuation = continuations.updateValue(continuation, forKey: execution.processIdentifier.value)
            precondition(oldContinuation == nil)

            // Wake up the waiter thread if it is waiting for more child processes.
            _ = pthread_cond_signal(_waitThreadNoChildrenCondition)
        }
    }
}

// Small helper to provide thread-safe access to the child process to continuations map as well as a condition variable to suspend the calling thread when there are no subprocesses to wait for. Note that Mutex cannot be used here because we need the semantics of pthread_cond_wait, which requires passing the pthread_mutex_t instance as a parameter, something the Mutex API does not provide access to.
private final class ChildProcessContinuations: Sendable {
    #if os(FreeBSD) || os(OpenBSD)
    typealias MutexType = pthread_mutex_t?
    #else
    typealias MutexType = pthread_mutex_t
    #endif

    private nonisolated(unsafe) var continuations = [pid_t: CheckedContinuation<TerminationStatus, any Error>]()
    private nonisolated(unsafe) let mutex = UnsafeMutablePointer<MutexType>.allocate(capacity: 1)

    init() {
        pthread_mutex_init(mutex, nil)
    }

    func withLock<R>(_ body: (inout [pid_t: CheckedContinuation<TerminationStatus, any Error>]) throws -> R) rethrows -> R {
        try withUnsafeUnderlyingLock { _, continuations in
            try body(&continuations)
        }
    }

    func withUnsafeUnderlyingLock<R>(_ body: (UnsafeMutablePointer<MutexType>, inout [pid_t: CheckedContinuation<TerminationStatus, any Error>]) throws -> R) rethrows -> R {
        pthread_mutex_lock(mutex)
        defer {
            pthread_mutex_unlock(mutex)
        }
        return try body(mutex, &continuations)
    }
}

private let _childProcessContinuations = ChildProcessContinuations()

private nonisolated(unsafe) let _waitThreadNoChildrenCondition = {
    #if os(FreeBSD) || os(OpenBSD)
    let result = UnsafeMutablePointer<pthread_cond_t?>.allocate(capacity: 1)
    #else
    let result = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    #endif
    _ = pthread_cond_init(result, nil)
    return result
}()

#if !os(FreeBSD) && !os(OpenBSD)
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
#endif

private let setup: () = {
    // Create the thread. It will run immediately; because it runs in an infinite
    // loop, we aren't worried about detaching or joining it.
    #if os(FreeBSD) || os(OpenBSD)
    var thread: pthread_t?
    #else
    var thread = pthread_t()
    #endif
    _ = pthread_create(
        &thread,
        nil,
        { _ -> UnsafeMutableRawPointer? in
            // Run an infinite loop that waits for child processes to terminate and
            // captures their exit statuses.
            while true {
                // Listen for child process exit events. WNOWAIT means we don't perturb the
                // state of a terminated (zombie) child process, allowing us to fetch the
                // continuation (if available) before reaping.
                var siginfo = siginfo_t()
                errno = 0
                if waitid(P_ALL, id_t(0), &siginfo, WEXITED | WNOWAIT) == 0 {
                    let pid = siginfo.si_pid

                    // If we had a continuation for this PID, allow the process to be reaped
                    // and pass the resulting exit condition back to the calling task. If
                    // there is no continuation, then either it hasn't been stored yet or
                    // this child process is not tracked by the waiter thread.
                    guard pid != 0, let c = _childProcessContinuations.withLock({ $0.removeValue(forKey: pid) }) else {
                        continue
                    }

                    c.resume(with: Result {
                        // Here waitid should not block because `pid` has already terminated at this point.
                        while true {
                            var siginfo = siginfo_t()
                            errno = 0
                            if waitid(P_PID, numericCast(pid), &siginfo, WEXITED) == 0 {
                                var status: TerminationStatus? = nil
                                switch siginfo.si_code {
                                case .init(CLD_EXITED):
                                    return .exited(siginfo.si_status)
                                case .init(CLD_KILLED), .init(CLD_DUMPED):
                                    return .unhandledException(siginfo.si_status)
                                default:
                                    fatalError("Unexpected exit status: \(siginfo.si_code)")
                                }
                            } else if errno != EINTR {
                                throw SubprocessError.UnderlyingError(rawValue: errno)
                            }
                        }
                    })
                } else if errno == ECHILD {
                    // We got ECHILD. If there are no continuations added right now, we should
                    // suspend this thread on the no-children condition until it's awoken by a
                    // newly-scheduled waiter process. (If this condition is spuriously
                    // woken, we'll just loop again, which is fine.) Note that we read errno
                    // outside the lock in case acquiring the lock perturbs it.
                    _childProcessContinuations.withUnsafeUnderlyingLock { lock, childProcessContinuations in
                        if childProcessContinuations.isEmpty {
                            _ = pthread_cond_wait(_waitThreadNoChildrenCondition, lock)
                        }
                    }
                }
            }
        },
        nil
    )
}()

private func _setupMonitorSignalHandler() {
    // Only executed once
    setup
}

#endif  // canImport(Glibc) || canImport(Android) || canImport(Musl)
