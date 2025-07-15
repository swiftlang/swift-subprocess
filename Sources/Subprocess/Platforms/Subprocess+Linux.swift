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
                var processFileDescriptor: PlatformFileDescriptor = -1
                let spawnError: CInt = possibleExecutablePath.withCString { exePath in
                    return (self.workingDirectory?.string).withOptionalCString { workingDir in
                        return supplementaryGroups.withOptionalUnsafeBufferPointer { sgroups in
                            return fileDescriptors.withUnsafeBufferPointer { fds in
                                return _subprocess_fork_exec(
                                    &pid,
                                    &processFileDescriptor,
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
                    processIdentifier: .init(
                        value: pid,
                        processFileDescriptor: processFileDescriptor
                    )
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

// MARK:  - ProcesIdentifier

/// A platform independent identifier for a Subprocess.
public struct ProcessIdentifier: Sendable, Hashable {
    /// The platform specific process identifier value
    public let value: pid_t
    internal let processFileDescriptor: PlatformFileDescriptor

    internal init(value: pid_t, processFileDescriptor: PlatformFileDescriptor) {
        self.value = value
        self.processFileDescriptor = processFileDescriptor
    }

    internal func close() {
        _SubprocessCShims.close(self.processFileDescriptor)
    }
}

extension ProcessIdentifier: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "\(self.value)" }

    public var debugDescription: String { "\(self.value)" }
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
    for processIdentifier: ProcessIdentifier
) async throws -> TerminationStatus {
    return try await withCheckedThrowingContinuation { continuation in
        _processMonitorState.withLock { state in
            switch state {
            case .notStarted:
                continuation.resume(throwing: SubprocessError(
                    code: .init(.failedToMonitorProcess),
                    underlyingError: nil)
                )
            case .failed(let error):
                continuation.resume(throwing: error)
            case .started(let storage):
                // Register processFileDescriptor with epoll
                var event = epoll_event(
                    events: EPOLLIN.rawValue,
                    data: epoll_data(fd: processIdentifier.processFileDescriptor)
                )
                let rc = epoll_ctl(
                    storage.epollFileDescriptor,
                    EPOLL_CTL_ADD,
                    processIdentifier.processFileDescriptor,
                    &event
                )
                if rc != 0 {
                    let error = SubprocessError(
                        code: .init(.failedToMonitorProcess),
                        underlyingError: .init(rawValue: errno)
                    )
                    continuation.resume(throwing: error)
                    return
                }
                // Now save the registration
                var newState = storage
                newState.continuations[processIdentifier.processFileDescriptor] = continuation
                state = .started(newState)
            }
        }
    }
}

private enum ProcessMonitorState {
    struct Storage {
        let epollFileDescriptor: CInt
        let shutdownFileDescriptor: CInt
        let monitorThread: pthread_t
        var continuations: [PlatformFileDescriptor : CheckedContinuation<TerminationStatus, any Error>]
    }

    case notStarted
    case started(Storage)
    case failed(SubprocessError)
}

private final class MonitorThreadContext {
    let epollFileDescriptor: CInt
    let shutdownFileDescriptor: CInt

    init(epollFileDescriptor: CInt, shutdownFileDescriptor: CInt) {
        self.epollFileDescriptor = epollFileDescriptor
        self.shutdownFileDescriptor = shutdownFileDescriptor
    }
}

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

private let _processMonitorState: Mutex<ProcessMonitorState> = .init(.notStarted)

private func shutdown() {
    let state = _processMonitorState.withLock { state -> (shutdownFileDescriptor: CInt, monitorThread: pthread_t)? in
        switch state {
        case .failed(_), .notStarted:
            return nil
        case .started(let storage):
            return (storage.shutdownFileDescriptor, storage.monitorThread)
        }
    }

    guard let state = state else {
        return
    }

    var one: UInt64 = 1
    // Wake up the thread for shutdown
    _ = _SubprocessCShims.write(state.shutdownFileDescriptor, &one, MemoryLayout<UInt64>.stride)
    // Cleanup the monitor thread
    pthread_join(state.monitorThread, nil)
}

private let setup: () = {
    // Create the epollfd for monitoring
    let epollFileDescriptor = epoll_create1(CInt(EPOLL_CLOEXEC))
    guard epollFileDescriptor >= 0 else {
        let error = SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: .init(rawValue: errno)
        )
        _processMonitorState.withLock { state in
            guard case .started(let storage) = state else {
                return
            }
            for continuation in storage.continuations.values {
                continuation.resume(throwing: error)
            }
        }
        return
    }
    // Create shutdownFileDescriptor
    let shutdownFileDescriptor = eventfd(0, CInt(EFD_NONBLOCK | EFD_CLOEXEC))
    guard shutdownFileDescriptor >= 0 else {
        let error = SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: .init(rawValue: errno)
        )
        _processMonitorState.withLock { storage in
            storage = .failed(error)
        }
        return
    }

    // Register shutdownFileDescriptor with epoll
    var event = epoll_event(
        events: EPOLLIN.rawValue,
        data: epoll_data(fd: shutdownFileDescriptor)
    )
    var rc = epoll_ctl(
        epollFileDescriptor,
        EPOLL_CTL_ADD,
        shutdownFileDescriptor,
        &event
    )
    guard rc == 0 else {
        let error = SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: .init(rawValue: errno)
        )
        _processMonitorState.withLock { storage in
            storage = .failed(error)
        }
        return
    }

    // Create thread data
    let context = MonitorThreadContext(
        epollFileDescriptor: epollFileDescriptor,
        shutdownFileDescriptor: shutdownFileDescriptor
    )
    let threadContext = Unmanaged.passRetained(context)
    // Create the thread. It will run immediately; because it runs in an infinite
    // loop, we aren't worried about detaching or joining it.
    var thread = pthread_t()
    rc = pthread_create(&thread, nil, { args in
        func reportError(_ error: SubprocessError) {
            _processMonitorState.withLock { state in
                guard case .started(let storage) = state else {
                    return
                }
                for continuation in storage.continuations.values {
                    continuation.resume(throwing: error)
                }
            }
        }

        let unmanaged = Unmanaged<MonitorThreadContext>.fromOpaque(args!)
        let context = unmanaged.takeRetainedValue()

        var events: [epoll_event] = Array(
            repeating: epoll_event(events: 0, data: epoll_data(fd: 0)),
            count: 256
        )

        // Enter the monitor loop
        monitorLoop: while true {
            let eventCount = epoll_wait(
                context.epollFileDescriptor,
                &events,
                CInt(events.count),
                -1
            )
            if eventCount < 0 {
                if errno == EINTR || errno == EAGAIN {
                    continue // interrupted by signal; try again
                }
                // Report other errors
                let error = SubprocessError(
                    code: .init(.failedToMonitorProcess),
                    underlyingError: .init(rawValue: errno)
                )
                reportError(error)
                break monitorLoop
            }

            for index in 0 ..< Int(eventCount) {
                let event = events[index]
                let targetFileDescriptor = event.data.fd
                // Breakout the monitor loop if we received shutdown
                // from the shutdownFD
                if targetFileDescriptor == context.shutdownFileDescriptor {
                    var buf: UInt64 = 0
                    _ = _SubprocessCShims.read(context.shutdownFileDescriptor, &buf, MemoryLayout<UInt64>.size)
                    break monitorLoop
                }

                var terminationStatus: Result<TerminationStatus, SubprocessError>

                var siginfo = siginfo_t()
                if 0 == waitid(P_PIDFD, id_t(targetFileDescriptor), &siginfo, WEXITED) {
                    switch siginfo.si_code {
                    case .init(CLD_EXITED):
                        terminationStatus = .success(.exited(siginfo.si_status))
                    case .init(CLD_KILLED), .init(CLD_DUMPED):
                        terminationStatus = .success(.unhandledException(siginfo.si_status))
                    default:
                        fatalError("Unexpected exit status: \(siginfo.si_code)")
                    }
                } else {
                    terminationStatus = .failure(SubprocessError(
                        code: .init(.failedToMonitorProcess),
                        underlyingError: .init(rawValue: errno))
                    )
                }

                // Remove this pidfd from epoll to prevent further notifications
                let rc = epoll_ctl(
                    context.epollFileDescriptor,
                    EPOLL_CTL_DEL,
                    targetFileDescriptor,
                    nil
                )
                if rc != 0 {
                    terminationStatus = .failure(SubprocessError(
                        code: .init(.failedToMonitorProcess),
                        underlyingError: .init(rawValue: errno)
                    ))
                }

                // Notify the continuation
                _processMonitorState.withLock { state in
                    guard case .started(let storage) = state,
                          let continuation = storage.continuations[targetFileDescriptor] else {
                        return
                    }
                    switch terminationStatus {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                    // Remove registration
                    var newStorage = storage
                    newStorage.continuations.removeValue(forKey: targetFileDescriptor)
                    state = .started(newStorage)
                }
            }
        }

        return nil
    },threadContext.toOpaque())
    guard rc == 0 else {
        let error = SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: .init(rawValue: rc)
        )
        _processMonitorState.withLock { storage in
            storage = .failed(error)
        }
        return
    }
    _processMonitorState.withLock { state in
        let storage = ProcessMonitorState.Storage(
            epollFileDescriptor: epollFileDescriptor,
            shutdownFileDescriptor: shutdownFileDescriptor,
            monitorThread: thread,
            continuations: [:]
        )
        state = .started(storage)
    }

    atexit {
        shutdown()
    }
}()


private func _setupMonitorSignalHandler() {
    // Only executed once
    setup
}

#endif  // canImport(Glibc) || canImport(Android) || canImport(Musl)
