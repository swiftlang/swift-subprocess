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
let _subprocess_read = Glibc.read
let _subprocess_write = Glibc.write
let _subprocess_close = Glibc.close
#elseif canImport(Android)
import Android
let _subprocess_read = Android.read
let _subprocess_write = Android.write
let _subprocess_close = Android.close
#elseif canImport(Musl)
import Musl
let _subprocess_read = Musl.read
let _subprocess_write = Musl.write
let _subprocess_close = Musl.close
#endif

internal import Dispatch

import Synchronization
import _SubprocessCShims

// Linux specific implementations
#if canImport(Glibc)
extension EPOLL_EVENTS {
    init(_ other: EPOLL_EVENTS) {
        self = other
    }
}
#elseif canImport(Bionic)
typealias EPOLL_EVENTS = CInt

extension UInt32 {
    // for EPOLLIN/EPOLLOUT
    var rawValue: UInt32 {
        self
    }
}

extension Int32 {
    var rawValue: UInt32 {
        UInt32(bitPattern: self)
    }
}
#elseif canImport(Musl)
extension EPOLL_EVENTS {
    init(_ rawValue: Int32) {
        self.init(UInt32(bitPattern: rawValue))
    }
}

extension Int32 {
    // for EPOLLIN/EPOLLOUT
    var rawValue: UInt32 {
        UInt32(bitPattern: self)
    }
}
#endif

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
                var processDescriptor: PlatformFileDescriptor = -1
                let spawnError: CInt = possibleExecutablePath.withCString { exePath in
                    return (self.workingDirectory?.string).withOptionalCString { workingDir in
                        return supplementaryGroups.withOptionalUnsafeBufferPointer { sgroups in
                            return fileDescriptors.withUnsafeBufferPointer { fds in
                                return _subprocess_fork_exec(
                                    &pid,
                                    &processDescriptor,
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
                                    self.platformOptions.preExecProcessAction
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
                        processDescriptor: processDescriptor
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

// MARK:  - ProcessIdentifier

/// A platform independent identifier for a Subprocess.
public struct ProcessIdentifier: Sendable, Hashable {
    /// The platform specific process identifier value
    public let value: pid_t
    public let processDescriptor: CInt

    internal init(value: pid_t, processDescriptor: PlatformFileDescriptor) {
        self.value = value
        self.processDescriptor = processDescriptor
    }

    internal func close() {
        if self.processDescriptor > 0 {
            _ = _subprocess_close(self.processDescriptor)
        }
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
    /// On Linux, Subprocess uses `fork/exec` as the
    /// underlying spawning mechanism. This closure is called
    /// after `fork()` but before `exec()`. You may use it to
    /// call any necessary process setup functions.
    ///
    /// - warning: You may ONLY call [async-signal-safe functions](https://pubs.opengroup.org/onlinepubs/9799919799/functions/V2_chap02.html) within this closure (note _"The following table defines a set of functions and function-like macros that shall be async-signal-safe."_).
    public var preExecProcessAction: (@convention(c) @Sendable () -> Void)? = nil

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
            \(indent)    preExecProcessAction: \(self.preExecProcessAction == nil ? "not set" : "set")
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
        let status = _processMonitorState.withLock { state -> Result<TerminationStatus, SubprocessError>? in
            switch state {
            case .notStarted:
                let error = SubprocessError(
                    code: .init(.failedToMonitorProcess),
                    underlyingError: nil
                )
                return .failure(error)
            case .failed(let error):
                return .failure(error)
            case .started(let storage):
                // pidfd is only supported on Linux kernel 5.4 and above
                // On older releases, use signalfd so we do not need
                // to register anything with epoll
                if processIdentifier.processDescriptor > 0 {
                    // Register processDescriptor with epoll
                    var event = epoll_event(
                        events: EPOLLIN.rawValue,
                        data: epoll_data(fd: processIdentifier.processDescriptor)
                    )
                    let rc = epoll_ctl(
                        storage.epollFileDescriptor,
                        EPOLL_CTL_ADD,
                        processIdentifier.processDescriptor,
                        &event
                    )
                    if rc != 0 {
                        let epollErrno = errno
                        let error = SubprocessError(
                            code: .init(.failedToMonitorProcess),
                            underlyingError: .init(rawValue: epollErrno)
                        )
                        return .failure(error)
                    }
                    // Now save the registration
                    var newState = storage
                    newState.continuations[processIdentifier.processDescriptor] = continuation
                    state = .started(newState)
                    // No state to resume
                    return nil
                } else {
                    // Fallback to using signal handler directly on older Linux kernels
                    // Since Linux coalesce signals, it's possible by the time we request
                    // monitoring the process has already exited. Check to make sure that
                    // is not the case and only save continuation then.
                    var siginfo = siginfo_t()
                    // Use NOHANG here because the child process might still be running
                    if 0 == waitid(P_PID, id_t(processIdentifier.value), &siginfo, WEXITED | WNOHANG) {
                        // If si_pid and si_signo are both 0, the child is still running since we used WNOHANG
                        if siginfo.si_pid == 0 && siginfo.si_signo == 0 {
                            // Save this continuation to be called by signal hander
                            var newState = storage
                            newState.continuations[processIdentifier.processDescriptor] = continuation
                            state = .started(newState)
                            return nil
                        }

                        switch siginfo.si_code {
                        case .init(CLD_EXITED):
                            return .success(.exited(siginfo.si_status))
                        case .init(CLD_KILLED), .init(CLD_DUMPED):
                            return .success(.unhandledException(siginfo.si_status))
                        default:
                            fatalError("Unexpected exit status: \(siginfo.si_code)")
                        }
                    } else {
                        let waitidError = errno
                        let error = SubprocessError(
                            code: .init(.failedToMonitorProcess),
                            underlyingError: .init(rawValue: waitidError)
                        )
                        return .failure(error)
                    }
                }
            }
        }

        if let status {
            continuation.resume(with: status)
        }
    }
}

#if canImport(Musl)
extension pthread_t: @retroactive @unchecked Sendable { }
#endif

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

private struct MonitorThreadContext: Sendable {
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

// Okay to be unlocked global mutable because this value is only set once like dispatch_once
private nonisolated(unsafe) var _signalPipe: (readEnd: CInt, writeEnd: CInt) = (readEnd: -1, writeEnd: -1)
// Okay to be unlocked global mutable because this value is only set once like dispatch_once
private nonisolated(unsafe) var _waitprocessDescriptorSupported = false
private let _processMonitorState: Mutex<ProcessMonitorState> = .init(.notStarted)

private func shutdown() {
    let storage = _processMonitorState.withLock { state -> ProcessMonitorState.Storage? in
        switch state {
        case .failed(_), .notStarted:
            return nil
        case .started(let storage):
            return storage
        }
    }

    guard let storage else {
        return
    }

    var one: UInt64 = 1
    // Wake up the thread for shutdown
    _ = _subprocess_write(storage.shutdownFileDescriptor, &one, MemoryLayout<UInt64>.size)
    // Cleanup the monitor thread
    pthread_join(storage.monitorThread, nil)
}


/// See the following page for the complete list of `async-signal-safe` functions
/// https://man7.org/linux/man-pages/man7/signal-safety.7.html
/// Only these functions can be used in the signal handler below
private func signalHandler(
    _ signalNumber: CInt,
    _ signalInfo: UnsafeMutablePointer<siginfo_t>?,
    _ context: UnsafeMutableRawPointer?
) {
    let savedErrno = errno
    var one: UInt8 = 1
    _ = _subprocess_write(_signalPipe.writeEnd, &one, 1)
    errno = savedErrno
}

private func monitorThreadFunc(context: MonitorThreadContext) {
    var events: [epoll_event] = Array(
        repeating: epoll_event(events: 0, data: epoll_data(fd: 0)),
        count: 256
    )
    var waitMask = sigset_t();
    sigemptyset(&waitMask);
    sigaddset(&waitMask, SIGCHLD);
    // Enter the monitor loop
    monitorLoop: while true {
        let eventCount = epoll_pwait(
            context.epollFileDescriptor,
            &events,
            CInt(events.count),
            -1,
            &waitMask
        )
        if eventCount < 0 {
            let pwaitErrno = errno
            if pwaitErrno == EINTR || pwaitErrno == EAGAIN {
                continue // interrupted by signal; try again
            }
            // Report other errors
            let error = SubprocessError(
                code: .init(.failedToMonitorProcess),
                underlyingError: .init(rawValue: pwaitErrno)
            )
            let continuations = _processMonitorState.withLock { state -> [CheckedContinuation<TerminationStatus, any Error>] in
                let result: [CheckedContinuation<TerminationStatus, any Error>]
                if case .started(let storage) = state {
                    result = Array(storage.continuations.values)
                } else {
                    result = []
                }
                state = .failed(error)
                return result
            }
            // Report error to all existing continuations
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
            break monitorLoop
        }

        for index in 0 ..< Int(eventCount) {
            let event = events[index]
            let targetFileDescriptor = event.data.fd

            // Breakout the monitor loop if we received shutdown
            // from the shutdownFD
            if targetFileDescriptor == context.shutdownFileDescriptor {
                var buf: UInt64 = 0
                _ = _subprocess_read(context.shutdownFileDescriptor, &buf, MemoryLayout<UInt64>.size)
                break monitorLoop
            }

            // P_PIDFD requires Linux Kernel 5.4 and above
            if _waitprocessDescriptorSupported {
                _blockAndWaitForprocessDescriptor(targetFileDescriptor, context: context)
            } else {
                _reapAllKnownChildProcesses(targetFileDescriptor, context: context)
            }
        }
    }
}

private let setup: () = {
    func _reportFailureWithErrno(_ number: CInt) {
        let error = SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: .init(rawValue: number)
        )
        _processMonitorState.withLock { state in
            state = .failed(error)
        }
    }

    // Create the epollfd for monitoring
    let epollFileDescriptor = epoll_create1(CInt(EPOLL_CLOEXEC))
    guard epollFileDescriptor >= 0 else {
        _reportFailureWithErrno(errno)
        return
    }
    // Create shutdownFileDescriptor
    let shutdownFileDescriptor = eventfd(0, CInt(EFD_NONBLOCK | EFD_CLOEXEC))
    guard shutdownFileDescriptor >= 0 else {
        _reportFailureWithErrno(errno)
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
        _reportFailureWithErrno(errno)
        return
    }

    // If the current kernel does not support pidfd, fallback to signal handler
    // Create the self-pipe that signal handler writes to
    if !_isWaitprocessDescriptorSupported() {
        var pipeCreationError: SubprocessError? = nil
        do {
            let (readEnd, writeEnd) = try FileDescriptor.pipe()
            _signalPipe = (readEnd.rawValue, writeEnd.rawValue)
        } catch {
            var underlying: SubprocessError.UnderlyingError? = nil
            if let err = error as? Errno {
                underlying = .init(rawValue: err.rawValue)
            }
            pipeCreationError = SubprocessError(
                code: .init(.failedToMonitorProcess),
                underlyingError: underlying
            )
        }
        if let pipeCreationError {
            _processMonitorState.withLock { state in
                state = .failed(pipeCreationError)
            }
            return
        }
        // Register the read end with epoll so we can get updates
        // about it. The write end is written by the signal hander
        var event = epoll_event(
            events: EPOLLIN.rawValue,
            data: epoll_data(fd: _signalPipe.readEnd)
        )
        rc = epoll_ctl(
            epollFileDescriptor,
            EPOLL_CTL_ADD,
            _signalPipe.readEnd,
            &event
        )
        guard rc == 0 else {
            _reportFailureWithErrno(errno)
            return
        }
    } else {
        // Mark waitid(P_PIDFD) as supported
        _waitprocessDescriptorSupported = true
    }
    let monitorThreadContext = MonitorThreadContext(
        epollFileDescriptor: epollFileDescriptor,
        shutdownFileDescriptor: shutdownFileDescriptor
    )
    // Create the monitor thread
    let thread: pthread_t
    switch Result(catching: { () throws(SubprocessError.UnderlyingError) -> pthread_t in
        try pthread_create {
            monitorThreadFunc(context: monitorThreadContext)
        }
    }) {
    case let .success(t):
        thread = t
    case let .failure(error):
        _processMonitorState.withLock { state in
            state = .failed(SubprocessError(
                code: .init(.failedToMonitorProcess),
                underlyingError: error
            ))
        }
        return
    }

    let storage = ProcessMonitorState.Storage(
        epollFileDescriptor: epollFileDescriptor,
        shutdownFileDescriptor: shutdownFileDescriptor,
        monitorThread: thread,
        continuations: [:]
    )

    _processMonitorState.withLock { state in
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

private func _blockAndWaitForprocessDescriptor(_ pidfd: CInt, context: MonitorThreadContext) {
    var terminationStatus: Result<TerminationStatus, SubprocessError>

    var siginfo = siginfo_t()
    if 0 == waitid(idtype_t(UInt32(P_PIDFD)), id_t(pidfd), &siginfo, WEXITED) {
        switch siginfo.si_code {
        case .init(CLD_EXITED):
            terminationStatus = .success(.exited(siginfo.si_status))
        case .init(CLD_KILLED), .init(CLD_DUMPED):
            terminationStatus = .success(.unhandledException(siginfo.si_status))
        default:
            fatalError("Unexpected exit status: \(siginfo.si_code)")
        }
    } else {
        let waitidErrno = errno
        terminationStatus = .failure(SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: .init(rawValue: waitidErrno))
        )
    }

    // Remove this pidfd from epoll to prevent further notifications
    let rc = epoll_ctl(
        context.epollFileDescriptor,
        EPOLL_CTL_DEL,
        pidfd,
        nil
    )
    if rc != 0 {
        let epollErrno = errno
        terminationStatus = .failure(SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: .init(rawValue: epollErrno)
        ))
    }
    // Notify the continuation
    let continuation = _processMonitorState.withLock { state -> CheckedContinuation<TerminationStatus, any Error>? in
        guard case .started(let storage) = state,
              let continuation = storage.continuations[pidfd] else {
            return nil
        }
        // Remove registration
        var newStorage = storage
        newStorage.continuations.removeValue(forKey: pidfd)
        state = .started(newStorage)
        return continuation
    }
    continuation?.resume(with: terminationStatus)
}

// On older kernel, fallback to using signal handlers
private typealias ResultContinuation = (
    result: Result<TerminationStatus, SubprocessError>,
    continuation: CheckedContinuation<TerminationStatus, any Error>
)
private func _reapAllKnownChildProcesses(_ signalFd: CInt, context: MonitorThreadContext) {
    guard signalFd == _signalPipe.readEnd else {
        return
    }

    // Drain the signalFd
    var buffer: UInt8 = 0
    while _subprocess_read(signalFd, &buffer, 1) > 0 { /* noop, drain the pipe  */ }

    let resumingContinuations: [ResultContinuation] = _processMonitorState.withLock { state in
        guard case .started(let storage) = state else {
            return []
        }
        var updatedContinuations = storage.continuations
        var results: [ResultContinuation] = []
        // Since Linux coalesce signals, we need to loop through all known child process
        // to check if they exited.
        for knownChildPID in storage.continuations.keys {
            let terminationStatus: Result<TerminationStatus, SubprocessError>
            var siginfo = siginfo_t()
            // Use `WNOHANG` here so waitid isn't blocking because we expect some
            // child processes might be still running
            if 0 == waitid(P_PID, id_t(knownChildPID), &siginfo, WEXITED | WNOHANG) {
                // If si_pid and si_signo, the child is still running since we used WNOHANG
                if siginfo.si_pid == 0 && siginfo.si_signo == 0 {
                    // Move on to the next child
                    continue
                }

                switch siginfo.si_code {
                case .init(CLD_EXITED):
                    terminationStatus = .success(.exited(siginfo.si_status))
                case .init(CLD_KILLED), .init(CLD_DUMPED):
                    terminationStatus = .success(.unhandledException(siginfo.si_status))
                default:
                    fatalError("Unexpected exit status: \(siginfo.si_code)")
                }
            } else {
                let waitidErrno = errno
                terminationStatus = .failure(SubprocessError(
                    code: .init(.failedToMonitorProcess),
                    underlyingError: .init(rawValue: waitidErrno))
                )
            }
            results.append((result: terminationStatus, continuation: storage.continuations[knownChildPID]!))
            // Now we have the exit code, remove saved continuations
            updatedContinuations.removeValue(forKey: knownChildPID)
        }
        var updatedStorage = storage
        updatedStorage.continuations = updatedContinuations
        state = .started(updatedStorage)

        return results
    }
    // Resume continuations
    for c in resumingContinuations {
        c.continuation.resume(with: c.result)
    }
}

internal func _isWaitprocessDescriptorSupported() -> Bool {
    // waitid(P_PIDFD) is only supported on Linux kernel 5.4 and above
    // Prob whether the current system supports it by calling it with self pidfd
    // and checking for EINVAL (waitid sets errno to EINVAL if it does not
    // recognize the id type).
    var siginfo = siginfo_t()
    let selfPidfd = _pidfd_open(getpid())
    if selfPidfd < 0 {
        // If we can not retrieve pidfd, the system does not support waitid(P_PIDFD)
        return false
    }
    /// The following call will fail either with
    /// - ECHILD: in this case we know P_PIDFD is supported and waitid correctly
    ///     reported that we don't have a child with the same selfPidfd;
    /// - EINVAL: in this case we know P_PIDFD is not supported because it does not
    ///     recognize the `P_PIDFD` type
    waitid(idtype_t(UInt32(P_PIDFD)), id_t(selfPidfd), &siginfo, WEXITED | WNOWAIT)
    return errno == ECHILD
}

internal func pthread_create(_ body: @Sendable @escaping () -> ()) throws(SubprocessError.UnderlyingError) -> pthread_t {
    final class Context {
        let body: @Sendable () -> ()
        init(body: @Sendable @escaping () -> Void) {
            self.body = body
        }
    }
    #if canImport(Glibc) || canImport(Musl)
    func proc(_ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        (Unmanaged<AnyObject>.fromOpaque(context!).takeRetainedValue() as! Context).body()
        return nil
    }
    #elseif canImport(Bionic)
    func proc(_ context: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        (Unmanaged<AnyObject>.fromOpaque(context).takeRetainedValue() as! Context).body()
        return context
    }
    #endif
    #if canImport(Glibc) || canImport(Bionic)
    var thread = pthread_t()
    #else
    var thread: pthread_t?
    #endif
    let rc = pthread_create(
        &thread,
        nil,
        proc,
        Unmanaged.passRetained(Context(body: body)).toOpaque()
    )
    if rc != 0 {
        throw SubprocessError.UnderlyingError(rawValue: rc)
    }
    #if canImport(Glibc) || canImport(Bionic)
    return thread
    #else
    return thread!
    #endif
}

#endif  // canImport(Glibc) || canImport(Android) || canImport(Musl)
