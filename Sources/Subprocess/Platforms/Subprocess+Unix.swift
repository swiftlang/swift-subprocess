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

#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl)

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

import _SubprocessCShims

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@preconcurrency internal import Dispatch

// MARK: - Signals

/// Signals are standardized messages sent to a running program to
/// trigger specific behavior, such as quitting or error handling.
public struct Signal: Hashable, Sendable {
    /// The underlying platform specific value for the signal
    public let rawValue: Int32

    private init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// The `.interrupt` signal is sent to a process by its
    /// controlling terminal when a user wishes to interrupt
    /// the process.
    public static var interrupt: Self { .init(rawValue: SIGINT) }
    /// The `.terminate` signal is sent to a process to request its
    /// termination. Unlike the `.kill` signal, it can be caught
    /// and interpreted or ignored by the process. This allows
    /// the process to perform nice termination releasing resources
    /// and saving state if appropriate. `.interrupt` is nearly
    /// identical to `.terminate`.
    public static var terminate: Self { .init(rawValue: SIGTERM) }
    /// The `.suspend` signal instructs the operating system
    /// to stop a process for later resumption.
    public static var suspend: Self { .init(rawValue: SIGSTOP) }
    /// The `resume` signal instructs the operating system to
    /// continue (restart) a process previously paused by the
    /// `.suspend` signal.
    public static var resume: Self { .init(rawValue: SIGCONT) }
    /// The `.kill` signal is sent to a process to cause it to
    /// terminate immediately (kill). In contrast to `.terminate`
    /// and `.interrupt`, this signal cannot be caught or ignored,
    /// and the receiving process cannot perform any
    /// clean-up upon receiving this signal.
    public static var kill: Self { .init(rawValue: SIGKILL) }
    /// The `.terminalClosed` signal is sent to a process when
    /// its controlling terminal is closed. In modern systems,
    /// this signal usually means that the controlling pseudo
    /// or virtual terminal has been closed.
    public static var terminalClosed: Self { .init(rawValue: SIGHUP) }
    /// The `.quit` signal is sent to a process by its controlling
    /// terminal when the user requests that the process quit
    /// and perform a core dump.
    public static var quit: Self { .init(rawValue: SIGQUIT) }
    /// The `.userDefinedOne` signal is sent to a process to indicate
    /// user-defined conditions.
    public static var userDefinedOne: Self { .init(rawValue: SIGUSR1) }
    /// The `.userDefinedTwo` signal is sent to a process to indicate
    /// user-defined conditions.
    public static var userDefinedTwo: Self { .init(rawValue: SIGUSR2) }
    /// The `.alarm` signal is sent to a process when the corresponding
    /// time limit is reached.
    public static var alarm: Self { .init(rawValue: SIGALRM) }
    /// The `.windowSizeChange` signal is sent to a process when
    /// its controlling terminal changes its size (a window change).
    public static var windowSizeChange: Self { .init(rawValue: SIGWINCH) }
}

extension Execution {
    /// Send the given signal to the child process.
    /// - Parameters:
    ///   - signal: The signal to send.
    ///   - shouldSendToProcessGroup: Whether this signal should be sent to
    ///     the entire process group.
    public func send(
        signal: Signal,
        toProcessGroup shouldSendToProcessGroup: Bool = false
    ) throws(SubprocessError) {
        func _kill(_ pid: pid_t, signal: Signal) throws(SubprocessError) {
            guard kill(pid, signal.rawValue) == 0 else {
                throw SubprocessError(
                    code: .init(.failedToSendSignal(signal.rawValue)),
                    underlyingError: Errno(rawValue: errno)
                )
            }
        }
        let pid = shouldSendToProcessGroup ? -(processIdentifier.value) : processIdentifier.value

        #if os(Linux) || os(Android) || os(FreeBSD)
        // On platforms with process descriptors, use _subprocess_pdkill if possible
        if shouldSendToProcessGroup || self.processIdentifier.processDescriptor < 0 {
            // _subprocess_pdkill does not support sending signal to process group
            try _kill(pid, signal: signal)
        } else {
            let rc = _subprocess_pdkill(
                processIdentifier.processDescriptor,
                signal.rawValue
            )
            let capturedErrno = errno
            if rc == 0 {
                // _pidfd_send_signal succeeded
                return
            }
            if capturedErrno == ENOSYS {
                // _pidfd_send_signal is not implemented. Fallback to kill
                try _kill(pid, signal: signal)
                return
            }

            // Throw all other errors
            throw SubprocessError(
                code: .init(.failedToSendSignal(signal.rawValue)),
                underlyingError: Errno(rawValue: capturedErrno)
            )
        }
        #else
        try _kill(pid, signal: signal)
        #endif
    }
}

// MARK: - Environment Resolution
extension Environment {
    internal func pathValue() -> String? {
        switch self.config {
        case .inherit(let overrides):
            // If PATH value exists in overrides, use it
            if let value = overrides[.path] {
                return value
            }
            // Fall back to current process
            return Self.currentEnvironmentValues()[.path]
        case .custom(let fullEnvironment):
            if let value = fullEnvironment[.path] {
                return value
            }
            return nil
        case .rawBytes(let rawBytesArray):
            let needle: [UInt8] = Array("\(Key.path.rawValue)=".utf8)
            for row in rawBytesArray {
                guard row.starts(with: needle) else {
                    continue
                }
                // Attempt to
                let pathValue = row.dropFirst(needle.count)
                return String(decoding: pathValue, as: UTF8.self)
            }
            return nil
        }
    }

    // This method follows the standard "create" rule: `env` needs to be
    // manually deallocated
    internal func createEnv() -> [UnsafeMutablePointer<CChar>?] {
        func createFullCString(
            fromKey keyContainer: StringOrRawBytes,
            value valueContainer: StringOrRawBytes
        ) -> UnsafeMutablePointer<CChar> {
            let rawByteKey: UnsafeMutablePointer<CChar> = keyContainer.createRawBytes()
            let rawByteValue: UnsafeMutablePointer<CChar> = valueContainer.createRawBytes()
            defer {
                rawByteKey.deallocate()
                rawByteValue.deallocate()
            }
            /// length = `key` + `=` + `value` + `\null`
            let totalLength = keyContainer.count + 1 + valueContainer.count + 1
            let fullString: UnsafeMutablePointer<CChar> = .allocate(capacity: totalLength)
            #if os(OpenBSD) || os(Linux) || os(Android)
            _ = _shims_snprintf(fullString, CInt(totalLength), "%s=%s", rawByteKey, rawByteValue)
            #else
            _ = snprintf(ptr: fullString, totalLength, "%s=%s", rawByteKey, rawByteValue)
            #endif
            return fullString
        }

        var env: [UnsafeMutablePointer<CChar>?] = []
        switch self.config {
        case .inherit(let updates):
            var current = Self.currentEnvironmentValues()
            for (key, value) in updates {
                // Remove the value from current to override it
                // If the `value` is nil, we effectively "unset"
                // this value from current
                current.removeValue(forKey: key)
                if let value {
                    let fullString = "\(key)=\(value)"
                    env.append(strdup(fullString))
                }
            }
            // Add the rest of `current` to env
            for (key, value) in current {
                let fullString = "\(key)=\(value)"
                env.append(strdup(fullString))
            }
        case .custom(let customValues):
            for (key, value) in customValues {
                let fullString = "\(key)=\(value)"
                env.append(strdup(fullString))
            }
        case .rawBytes(let rawBytesArray):
            for rawBytes in rawBytesArray {
                env.append(strdup(rawBytes))
            }
        }
        env.append(nil)
        return env
    }

    internal static func withCopiedEnv<R>(_ body: ([UnsafeMutablePointer<CChar>]) -> R) -> R {
        var values: [UnsafeMutablePointer<CChar>] = []
        // This lock is taken by calls to getenv, so we want as few callouts to other code as possible here.
        _subprocess_lock_environ()
        guard
            let environments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> =
                _subprocess_get_environ()
        else {
            _subprocess_unlock_environ()
            return body([])
        }
        var curr = environments
        while let value = curr.pointee {
            values.append(strdup(value))
            curr = curr.advanced(by: 1)
        }
        _subprocess_unlock_environ()
        defer { values.forEach { free($0) } }
        return body(values)
    }
}

// MARK: Args Creation
extension Arguments {
    // This method follows the standard "create" rule: `args` needs to be
    // manually deallocated
    internal func createArgs(withExecutablePath executablePath: String) -> [UnsafeMutablePointer<CChar>?] {
        var argv: [UnsafeMutablePointer<CChar>?] = self.storage.map { $0.createRawBytes() }
        // argv[0] = executable path
        if let override = self.executablePathOverride {
            argv.insert(override.createRawBytes(), at: 0)
        } else {
            argv.insert(strdup(executablePath), at: 0)
        }
        argv.append(nil)
        return argv
    }
}

// MARK: -  Executable Searching
extension Executable {
    internal static let defaultSearchPaths = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/usr/local/bin",
    ]

    internal func resolveExecutablePath(withPathValue pathValue: String?) throws(SubprocessError) -> String {
        switch self.storage {
        case .executable(let executableName):
            // If the executableName in is already a full path, return it directly
            if Configuration.pathAccessible(executableName, mode: X_OK) {
                return executableName
            }
            let firstAccessibleExecutable = possibleExecutablePaths(withPathValue: pathValue)
                .first { Configuration.pathAccessible($0, mode: X_OK) }
            if let firstAccessibleExecutable {
                return firstAccessibleExecutable
            }
            throw SubprocessError(
                code: .init(.executableNotFound(executableName)),
                underlyingError: nil
            )
        case .path(let executablePath):
            // Use path directly
            return executablePath.string
        }
    }

    internal func possibleExecutablePaths(
        withPathValue pathValue: String?
    ) -> _OrderedSet<String> {
        switch self.storage {
        case .executable(let executableName):
            var results: _OrderedSet<String> = .init()
            // executableName could be a full path
            results.insert(executableName)
            // Get $PATH from environment
            let searchPaths =
                if let pathValue = pathValue {
                    pathValue.split(separator: ":").map { String($0) } + Self.defaultSearchPaths
                } else {
                    Self.defaultSearchPaths
                }
            for path in searchPaths {
                results.insert(
                    FilePath(path).appending(executableName).string
                )
            }
            return results
        case .path(let executablePath):
            return _OrderedSet([executablePath.string])
        }
    }
}

// MARK: - PreSpawn
extension Configuration {
    internal typealias PreSpawnArgs = (
        env: [UnsafeMutablePointer<CChar>?],
        uidPtr: UnsafeMutablePointer<uid_t>?,
        gidPtr: UnsafeMutablePointer<gid_t>?,
        supplementaryGroups: [gid_t]?
    )

    internal func preSpawn<Result: ~Copyable>(
        _ work: (PreSpawnArgs) async throws(SubprocessError) -> Result
    ) async throws(SubprocessError) -> Result {
        // Prepare environment
        let env = self.environment.createEnv()
        defer {
            for ptr in env { ptr?.deallocate() }
        }

        var uidPtr: UnsafeMutablePointer<uid_t>? = nil
        if let userID = self.platformOptions.userID {
            uidPtr = .allocate(capacity: 1)
            uidPtr?.pointee = userID
        }
        defer {
            uidPtr?.deallocate()
        }
        var gidPtr: UnsafeMutablePointer<gid_t>? = nil
        if let groupID = self.platformOptions.groupID {
            gidPtr = .allocate(capacity: 1)
            gidPtr?.pointee = groupID
        }
        defer {
            gidPtr?.deallocate()
        }
        var supplementaryGroups: [gid_t]?
        if let groupsValue = self.platformOptions.supplementaryGroups {
            supplementaryGroups = groupsValue
        }
        return try await work(
            (
                env: env,
                uidPtr: uidPtr,
                gidPtr: gidPtr,
                supplementaryGroups: supplementaryGroups
            )
        )
    }

    internal static func pathAccessible(_ path: String, mode: Int32) -> Bool {
        return path.withCString {
            return access($0, mode) == 0
        }
    }
}

// MARK: - FileDescriptor extensions
extension FileDescriptor {
    internal static func ssp_pipe() throws(SubprocessError) -> (
        readEnd: FileDescriptor,
        writeEnd: FileDescriptor
    ) {
        do {
            return try pipe()
        } catch {
            let errorCode = SubprocessError.Code(.failedToCreatePipe)
            throw SubprocessError(code: errorCode, underlyingError: error)
        }
    }

    internal var platformDescriptor: PlatformFileDescriptor {
        return self.rawValue
    }
}

internal typealias PlatformFileDescriptor = CInt

// MARK: - Spawning

#if !canImport(Darwin)
extension Configuration {

    // @unchecked Sendable because we need to capture UnsafePointers
    // to send to another thread. While UnsafePointers are not
    // Sendable, we are not mutating them -- we only need these type
    // for C interface.
    internal struct SpawnContext: @unchecked Sendable {
        let argv: [UnsafeMutablePointer<CChar>?]
        let env: [UnsafeMutablePointer<CChar>?]
        let uidPtr: UnsafeMutablePointer<uid_t>?
        let gidPtr: UnsafeMutablePointer<gid_t>?
        let processGroupIDPtr: UnsafeMutablePointer<gid_t>?
    }

    internal func spawn(
        withInput inputPipe: consuming CreatedPipe,
        outputPipe: consuming CreatedPipe,
        errorPipe: consuming CreatedPipe
    ) async throws(SubprocessError) -> SpawnResult {
        // Ensure the waiter thread is running.
        #if os(Linux) || os(Android)
        _setupMonitorSignalHandler()
        #endif

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
                let spawnContext = SpawnContext(
                    argv: argv, env: env, uidPtr: uidPtr, gidPtr: gidPtr, processGroupIDPtr: processGroupIDPtr
                )
                let (pid, processDescriptor, spawnError) = try await runOnBackgroundThread { () throws(SubprocessError) in
                    return try possibleExecutablePath._withCString { exePath throws(SubprocessError) in
                        return try (self.workingDirectory?.string).withOptionalCString { workingDir in
                            return supplementaryGroups.withOptionalUnsafeBufferPointer { sgroups in
                                return fileDescriptors.withUnsafeBufferPointer { fds in
                                    var pid: pid_t = 0
                                    var processDescriptor: PlatformFileDescriptor = -1

                                    let rc = _subprocess_fork_exec(
                                        &pid,
                                        &processDescriptor,
                                        exePath,
                                        workingDir,
                                        fds.baseAddress!,
                                        spawnContext.argv,
                                        spawnContext.env,
                                        spawnContext.uidPtr,
                                        spawnContext.gidPtr,
                                        spawnContext.processGroupIDPtr,
                                        CInt(supplementaryGroups?.count ?? 0),
                                        sgroups?.baseAddress,
                                        self.platformOptions.createSession ? 1 : 0
                                    )
                                    return (pid, processDescriptor, rc)
                                }
                            }
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

// MARK:  - ProcessIdentifier

/// A platform-independent identifier for a subprocess.
public struct ProcessIdentifier: Sendable, Hashable {
    /// The platform specific process identifier value
    public let value: pid_t

    #if os(Linux) || os(Android) || os(FreeBSD)
    /// The process file descriptor (pidfd) for the running execution.
    public let processDescriptor: CInt
    #else
    internal let processDescriptor: CInt // not used on other platforms
    #endif

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
    /// A textual representation of the process identifier.
    public var description: String { "\(self.value)" }
    /// A debug-oriented textual representation of the process identifier.
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
    /// Create platform options with the default values.
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
            \(indent)    createSession: \(createSession)
            \(indent))
            """
    }

    /// A textual representation of the platform options.
    public var description: String {
        return self.description(withIndent: 0)
    }

    /// A debug-oriented textual representation of the platform options.
    public var debugDescription: String {
        return self.description(withIndent: 0)
    }
}
#endif // !canImport(Darwin)

extension ProcessIdentifier {
    /// Reaps the zombie for the exited process. This function may block.
    @available(*, noasync)
    internal func blockingReap() throws(Errno) -> TerminationStatus {
        try _blockingReap(pid: value)
    }

    /// Reaps the zombie for the exited process, or returns `nil` if the process is still running. This function will not block.
    internal func reap() throws(Errno) -> TerminationStatus? {
        try _reap(pid: value)
    }
}

@available(*, noasync)
internal func _blockingReap(pid: pid_t) throws(Errno) -> TerminationStatus {
    let siginfo = try _waitid(idtype: P_PID, id: id_t(pid), flags: WEXITED)
    return TerminationStatus(siginfo)
}

internal func _reap(pid: pid_t) throws(Errno) -> TerminationStatus? {
    let siginfo = try _waitid(idtype: P_PID, id: id_t(pid), flags: WEXITED | WNOHANG)
    // If si_pid and si_signo are both 0, the child is still running since we used WNOHANG
    if siginfo.si_pid == 0 && siginfo.si_signo == 0 {
        return nil
    }
    return TerminationStatus(siginfo)
}

internal func _waitid(idtype: idtype_t, id: id_t, flags: Int32) throws(Errno) -> siginfo_t {
    while true {
        var siginfo = siginfo_t()
        if waitid(idtype, id, &siginfo, flags) != -1 {
            return siginfo
        } else if errno != EINTR {
            throw Errno(rawValue: errno)
        }
    }
}

internal extension TerminationStatus {
    init(_ siginfo: siginfo_t) {
        switch siginfo.si_code {
        case .init(CLD_EXITED):
            self = .exited(siginfo.si_status)
        case .init(CLD_KILLED), .init(CLD_DUMPED):
            self = .unhandledException(siginfo.si_status)
        default:
            fatalError("Unexpected exit status: \(siginfo.si_code)")
        }
    }
}

#if os(OpenBSD) || os(Linux) || os(Android)
internal extension siginfo_t {
    var si_status: Int32 {
        #if os(OpenBSD)
        return _data._proc._pdata._cld._status
        #elseif canImport(Glibc)
        return _sifields._sigchld.si_status
        #elseif canImport(Musl)
        return __si_fields.__si_common.__second.__sigchld.si_status
        #elseif canImport(Bionic)
        return _sifields._sigchld._status
        #endif
    }

    var si_pid: pid_t {
        #if os(OpenBSD)
        return _data._proc._pid
        #elseif canImport(Glibc)
        return _sifields._sigchld.si_pid
        #elseif canImport(Musl)
        return __si_fields.__si_common.__first.__piduid.si_pid
        #elseif canImport(Bionic)
        return _sifields._kill._pid
        #endif
    }
}
#endif

#endif // canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl)
