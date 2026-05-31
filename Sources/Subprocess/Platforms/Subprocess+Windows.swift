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

#if canImport(WinSDK)

@preconcurrency public import WinSDK
#if canImport(System)
import System
#else
import SystemPackage
#endif

import _SubprocessCShims

// Windows-specific implementation
extension Configuration {
    // @unchecked Sendable because we need to capture UnsafePointers
    // to send to another thread. While UnsafePointers are not
    // Sendable, we are not mutating them -- we only need these type
    // for C interface.
    internal struct SpawnContext: @unchecked Sendable {
        let startupInfo: UnsafeMutablePointer<STARTUPINFOEXW>
        let createProcessFlags: DWORD
    }

    internal func spawn(
        withInput inputPipe: consuming CreatedPipe,
        outputPipe: consuming CreatedPipe,
        errorPipe: consuming CreatedPipe
    ) async throws(SubprocessError) -> SpawnResult {
        let inputReadFileDescriptor: IODescriptor? = inputPipe.readFileDescriptor()
        let inputWriteFileDescriptor: IODescriptor? = inputPipe.writeFileDescriptor()
        let outputReadFileDescriptor: IODescriptor? = outputPipe.readFileDescriptor()
        let outputWriteFileDescriptor: IODescriptor? = outputPipe.writeFileDescriptor()
        let errorReadFileDescriptor: IODescriptor? = errorPipe.readFileDescriptor()
        let errorWriteFileDescriptor: IODescriptor? = errorPipe.writeFileDescriptor()

        // Create the Job Object up front. It persists across all candidate path
        // attempts, and is owned by this function until ownership transfers to
        // the `ProcessIdentifier` on the success path.
        let jobHandle: HANDLE? =
            self.platformOptions.jobObjectAssignment.createsJob
            ? try Self.createJobObject()
            : nil
        var jobHandleOwned: Bool = jobHandle != nil
        defer {
            if jobHandleOwned, let jobHandle {
                _ = CloseHandle(jobHandle)
            }
        }

        // CreateProcessW supports using `lpApplicationName` as well as `lpCommandLine` to
        // specify executable path. However, only `lpCommandLine` supports PATH looking up,
        // whereas `lpApplicationName` does not. In general we should rely on `lpCommandLine`'s
        // automatic PATH lookup so we only need to call `CreateProcessW` once. However, if
        // user wants to override executable path in arguments, we have to use `lpApplicationName`
        // to specify the executable path. In this case, manually loop over all possible paths.
        let possibleExecutablePaths: _OrderedSet<String>
        if _fastPath(self.arguments.executablePathOverride == nil) {
            // Fast path: we can rely on `CreateProcessW`'s built in Path searching
            switch self.executable.storage {
            case .executable(let executable):
                possibleExecutablePaths = _OrderedSet([executable])
            case .path(let path):
                possibleExecutablePaths = _OrderedSet([path.string])
            }
        } else {
            // Slow path: user requested arg0 override, therefore we must manually
            // traverse through all possible executable paths
            possibleExecutablePaths = self.executable.possibleExecutablePaths(
                withPathValue: self.environment.pathValue()
            )
        }

        for executablePath in possibleExecutablePaths {
            let applicationName: String?
            let commandAndArgs: String
            let environment: String
            let intendedWorkingDir: String?
            do {
                (
                    applicationName,
                    commandAndArgs,
                    environment,
                    intendedWorkingDir
                ) = try self.preSpawn(withPossibleExecutablePath: executablePath)
            } catch {
                try self.safelyCloseMultiple(
                    inputRead: inputReadFileDescriptor,
                    inputWrite: inputWriteFileDescriptor,
                    outputRead: outputReadFileDescriptor,
                    outputWrite: outputWriteFileDescriptor,
                    errorRead: errorReadFileDescriptor,
                    errorWrite: errorWriteFileDescriptor
                )
                throw error
            }

            var createProcessFlags = self.generateCreateProcessFlag()

            let (created, processInfo, windowsError, userManagesResume): (Bool, PROCESS_INFORMATION, DWORD, Bool)
            do {
                (created, processInfo, windowsError, userManagesResume) = try await self.withStartupInfoEx(
                    inputRead: inputReadFileDescriptor,
                    inputWrite: inputWriteFileDescriptor,
                    outputRead: outputReadFileDescriptor,
                    outputWrite: outputWriteFileDescriptor,
                    errorRead: errorReadFileDescriptor,
                    errorWrite: errorWriteFileDescriptor
                ) { startupInfo throws(SubprocessError) in
                    // Give calling process a chance to modify flag and startup info
                    if let configurator = self.platformOptions.preSpawnProcessConfigurator {
                        try configurator(&createProcessFlags, &startupInfo.pointer(to: \.StartupInfo)!.pointee)
                    }

                    // If the configurator set `CREATE_SUSPENDED`, the user has
                    // explicitly opted into managing the child's initial
                    // resume themselves. Otherwise, Subprocess resumes the
                    // child after assigning it to the Job Object.
                    let userManagesResume = (createProcessFlags & DWORD(CREATE_SUSPENDED)) != 0

                    // CREATE_SUSPENDED makes Job Object assignment atomic, so it's
                    // forced on whenever a job will be created. With `.never` there's
                    // no assignment to protect, so the child isn't force-suspended.
                    if self.platformOptions.jobObjectAssignment.createsJob {
                        createProcessFlags |= DWORD(CREATE_SUSPENDED)
                    }

                    let spawnContext = SpawnContext(
                        startupInfo: startupInfo,
                        createProcessFlags: createProcessFlags
                    )
                    // Spawn (featuring pyramid!)
                    return try await runOnBackgroundThread { () throws(SubprocessError) in
                        try applicationName.withOptionalNTPathRepresentation { applicationNameW throws(SubprocessError) in
                            try commandAndArgs._withCString(
                                encodedAs: UTF16.self
                            ) { commandAndArgsW throws(SubprocessError) in
                                try environment._withCString(
                                    encodedAs: UTF16.self
                                ) { environmentW throws(SubprocessError) in
                                    try intendedWorkingDir.withOptionalNTPathRepresentation { intendedWorkingDirW throws(SubprocessError) in
                                        // Spawn differently depending on whether
                                        // we need to spawn as a user
                                        if let userCredentials = self.platformOptions.userCredentials {
                                            return try userCredentials.username._withCString(
                                                encodedAs: UTF16.self
                                            ) { usernameW throws(SubprocessError) in
                                                try userCredentials.password._withCString(
                                                    encodedAs: UTF16.self
                                                ) { passwordW throws(SubprocessError) in
                                                    try userCredentials.domain.withOptionalCString(
                                                        encodedAs: UTF16.self
                                                    ) { domainW throws(SubprocessError) in
                                                        var processInfo = PROCESS_INFORMATION()
                                                        let created = CreateProcessWithLogonW(
                                                            usernameW,
                                                            domainW,
                                                            passwordW,
                                                            DWORD(LOGON_WITH_PROFILE),
                                                            applicationNameW,
                                                            UnsafeMutablePointer<WCHAR>(mutating: commandAndArgsW),
                                                            spawnContext.createProcessFlags,
                                                            UnsafeMutableRawPointer(mutating: environmentW),
                                                            intendedWorkingDirW,
                                                            spawnContext.startupInfo.pointer(to: \.StartupInfo)!,
                                                            &processInfo
                                                        )
                                                        return (created, processInfo, GetLastError(), userManagesResume)
                                                    }
                                                }
                                            }
                                        }

                                        var processInfo = PROCESS_INFORMATION()
                                        let result = CreateProcessW(
                                            applicationNameW,
                                            UnsafeMutablePointer<WCHAR>(mutating: commandAndArgsW),
                                            nil, // lpProcessAttributes
                                            nil, // lpThreadAttributes
                                            true, // bInheritHandles
                                            spawnContext.createProcessFlags,
                                            UnsafeMutableRawPointer(mutating: environmentW),
                                            intendedWorkingDirW,
                                            spawnContext.startupInfo.pointer(to: \.StartupInfo)!,
                                            &processInfo
                                        )
                                        return (result, processInfo, GetLastError(), userManagesResume)
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                try self.safelyCloseMultiple(
                    inputRead: inputReadFileDescriptor,
                    inputWrite: inputWriteFileDescriptor,
                    outputRead: outputReadFileDescriptor,
                    outputWrite: outputWriteFileDescriptor,
                    errorRead: errorReadFileDescriptor,
                    errorWrite: errorWriteFileDescriptor
                )
                throw error
            }

            guard created else {
                if windowsError == ERROR_FILE_NOT_FOUND || windowsError == ERROR_PATH_NOT_FOUND {
                    // This executable path is not it. Try the next one
                    continue
                }

                try self.safelyCloseMultiple(
                    inputRead: inputReadFileDescriptor,
                    inputWrite: inputWriteFileDescriptor,
                    outputRead: outputReadFileDescriptor,
                    outputWrite: outputWriteFileDescriptor,
                    errorRead: errorReadFileDescriptor,
                    errorWrite: errorWriteFileDescriptor
                )

                // Match Darwin and Linux behavior and throw
                // .failedToChangeWorkingDirectory instead of .spawnFailed
                if windowsError == ERROR_DIRECTORY {
                    throw SubprocessError.failedToChangeWorkingDirectory(
                        self.workingDirectory?.string,
                        underlyingError: SubprocessError.WindowsError(win32Error: windowsError)
                    )
                }

                throw SubprocessError.spawnFailed(
                    withUnderlyingError: SubprocessError.WindowsError(win32Error: windowsError)
                )
            }

            let assignedJobHandle: HANDLE?
            do {
                assignedJobHandle = try Self.assignChildToJobObjectAndResume(
                    jobHandle: jobHandle,
                    processInfo: processInfo,
                    assignment: self.platformOptions.jobObjectAssignment,
                    resumeThread: self.platformOptions.jobObjectAssignment.createsJob && !userManagesResume
                )
            } catch {
                try self.safelyCloseMultiple(
                    inputRead: inputReadFileDescriptor,
                    inputWrite: inputWriteFileDescriptor,
                    outputRead: outputReadFileDescriptor,
                    outputWrite: outputWriteFileDescriptor,
                    errorRead: errorReadFileDescriptor,
                    errorWrite: errorWriteFileDescriptor
                )
                throw error
            }

            // Ownership of the job (if the child is in one) transfers to
            // ProcessIdentifier. If a job was created but the child isn't in
            // it (`.bestEffort` failure), the original handle stays owned here
            // and is closed by `defer`.
            jobHandleOwned = assignedJobHandle == nil && jobHandle != nil

            let pid = ProcessIdentifier(
                value: processInfo.dwProcessId,
                processDescriptor: processInfo.hProcess,
                threadHandle: processInfo.hThread,
                jobHandle: assignedJobHandle
            )

            do {
                // After spawn finishes, close all child side fds
                try self.safelyCloseMultiple(
                    inputRead: inputReadFileDescriptor,
                    inputWrite: nil,
                    outputRead: nil,
                    outputWrite: outputWriteFileDescriptor,
                    errorRead: nil,
                    errorWrite: errorWriteFileDescriptor
                )
            } catch {
                // If spawn() throws, monitorProcessTermination
                // won't have an opportunity to call release, so do it here to avoid leaking the handles.
                pid.close()
                throw error
            }

            return SpawnResult(
                processIdentifier: pid,
                inputWriteEnd: inputWriteFileDescriptor,
                outputReadEnd: outputReadFileDescriptor,
                errorReadEnd: errorReadFileDescriptor
            )
        }

        try self.safelyCloseMultiple(
            inputRead: inputReadFileDescriptor,
            inputWrite: inputWriteFileDescriptor,
            outputRead: outputReadFileDescriptor,
            outputWrite: outputWriteFileDescriptor,
            errorRead: errorReadFileDescriptor,
            errorWrite: errorWriteFileDescriptor
        )

        // If we reached this point, all possible executable paths have failed
        throw SubprocessError.executableNotFound(
            self.executable.description,
            underlyingError: SubprocessError.WindowsError(win32Error: DWORD(ERROR_FILE_NOT_FOUND))
        )
    }
}

// MARK: - Platform Specific Options

/// The collection of platform-specific settings
/// to configure the subprocess when running.
public struct PlatformOptions: Sendable {
    /// The credentials to use when spawning the subprocess
    /// as a different user.
    internal struct UserCredentials: Sendable, Hashable {
        /// The name of the user.
        ///
        /// This is the name of the user account to run as.
        public var username: String
        /// The clear-text password for the account.
        public var password: String
        /// The name of the domain or server whose account database
        /// contains the account.
        public var domain: String?
    }

    /// `ConsoleBehavior` describes how the console appears
    /// when spawning a new process.
    public struct ConsoleBehavior: Sendable, Hashable {
        internal enum Storage: Sendable, Hashable {
            case createNew
            case detach
            case inherit
        }

        internal let storage: Storage

        private init(_ storage: Storage) {
            self.storage = storage
        }

        /// The subprocess has a new console, instead of
        /// inheriting its parent's console (the default).
        public static let createNew: Self = .init(.createNew)
        /// For console processes, the new process does not
        /// inherit its parent's console (the default).
        /// The new process can call the `AllocConsole`
        /// function at a later time to create a console.
        public static let detach: Self = .init(.detach)
        /// The subprocess inherits its parent's console.
        public static let inherit: Self = .init(.inherit)
    }

    /// `WindowStyle` describes how the window appears
    /// when spawning a new process.
    public struct WindowStyle: Sendable, Hashable {
        internal enum Storage: Sendable, Hashable {
            case normal
            case hidden
            case maximized
            case minimized
        }

        internal let storage: Storage

        internal var platformStyle: WORD {
            switch self.storage {
            case .hidden: return WORD(SW_HIDE)
            case .maximized: return WORD(SW_SHOWMAXIMIZED)
            case .minimized: return WORD(SW_SHOWMINIMIZED)
            default: return WORD(SW_SHOWNORMAL)
            }
        }

        private init(_ storage: Storage) {
            self.storage = storage
        }

        /// Activates and displays a window of normal size.
        public static let normal: Self = .init(.normal)
        /// Doesn't activate a new window.
        public static let hidden: Self = .init(.hidden)
        /// Activates the window and displays it as a maximized window.
        public static let maximized: Self = .init(.maximized)
        /// Activates the window and displays it as a minimized window.
        public static let minimized: Self = .init(.minimized)
    }

    /// Describes how Job Object assignment is handled.
    public struct JobObjectAssignment: Sendable, Hashable {
        internal enum Storage: Sendable, Hashable {
            case always
            case bestEffort
            case never
        }

        internal let storage: Storage

        /// Always assign the child to a Job Object, and throw
        /// ``SubprocessError/spawnFailed`` if assignment fails.
        ///
        /// This is the default behavior.
        public static let always: Self = .init(storage: .always)

        /// Attempt to assign the child to a Job Object, and proceed
        /// without one if assignment fails.
        ///
        /// Descendant tracking and targeting the descendant-group
        /// teardown are unavailable for subprocesses for which
        /// assignment fails.
        public static let bestEffort: Self = .init(storage: .bestEffort)

        /// Never assign the child to a Job Object.
        ///
        /// Use this when manually handling job management, or when
        /// descendant-group teardown is not necessary.
        public static let never: Self = .init(storage: .never)
    }

    /// The user credentials for starting the process as another user.
    internal var userCredentials: UserCredentials? = nil
    /// The console behavior of the new process.
    ///
    /// Defaults to inheriting the console from the parent process.
    public var consoleBehavior: ConsoleBehavior = .inherit
    /// The window style to use when the process starts.
    public var windowStyle: WindowStyle = .normal
    /// A Boolean value that indicates whether to create a new process
    /// group for the new process.
    ///
    /// The process group includes all processes
    /// that are descendants of this root process.
    /// The process identifier of the new process group
    /// is the same as the process identifier.
    public var createProcessGroup: Bool = false
    /// Describes how Job Object assignment is handled.
    ///
    /// Defaults to always assigning the child to a Job Object, and throwing
    /// ``SubprocessError/spawnFailed`` if assignment fails.
    public var jobObjectAssignment: JobObjectAssignment = .always
    /// An ordered list of steps to tear down the child
    /// process if the parent task is canceled before
    /// the child process terminates.
    ///
    /// The sequence always ends by forcefully terminating the process.
    public var teardownSequence: [TeardownStep] = []
    /// A closure that configures platform-specific
    /// spawning constructs.
    ///
    /// Use this closure to directly configure or override
    /// the underlying platform-specific spawn settings that the
    /// library uses internally, when higher-level APIs aren't
    /// available for such modifications.
    ///
    /// On Windows, Subprocess uses `CreateProcessW()` as the
    /// underlying spawning mechanism. This closure allows
    /// modification of the `dwCreationFlags` creation flag
    /// and startup info `STARTUPINFOW` before
    /// they are sent to `CreateProcessW()`.
    ///
    /// - Important: When `jobObjectAssignment` is `.always` or `.bestEffort`,
    /// Subprocess assigns the spawned child to an internal Job Object before
    /// any user code runs in the child, so teardown sequences targeting the
    /// process group can terminate the child and all of its descendants
    /// together. (See ``JobObjectAssignment`` for how `.bestEffort` behaves
    /// when assignment fails.) To make the assignment atomic, Subprocess
    /// spawns such children with `CREATE_SUSPENDED` set in `dwCreationFlags`,
    /// regardless of the value the configurator leaves there, and by default
    /// resumes the child once assignment completes. If user code separately
    /// assigns the child to its own Job Object after spawn, that user-supplied
    /// job is nested inside Subprocess's job. When `jobObjectAssignment` is
    /// `.never`, Subprocess creates no Job Object and does not force
    /// `CREATE_SUSPENDED`; the configurator's `dwCreationFlags` are used as-is.
    /// Regardless of `jobObjectAssignment`, if the configurator sets
    /// `CREATE_SUSPENDED` in `dwCreationFlags`, Subprocess treats this as a
    /// signal that user code will resume the child explicitly and skips its
    /// internal `ResumeThread` call. The caller is then responsible for
    /// calling `ResumeThread` on the thread handle exposed through
    /// `Execution.processIdentifier.threadHandle`; otherwise the child remains
    /// suspended indefinitely.
    public var preSpawnProcessConfigurator:
        (
            @Sendable (
                inout DWORD,
                inout STARTUPINFOW
            ) throws(SubprocessError) -> Void
        )? = nil

    /// Creates platform options with default values.
    public init() {}
}

extension PlatformOptions.ConsoleBehavior: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual representation of how the console appears when spawning a
    /// new process.
    public var description: String {
        switch self.storage {
        case .createNew:
            return "createNew"
        case .detach:
            return "detach"
        case .inherit:
            return "inherit"
        }
    }

    /// A debug-oriented textual representation of how the console appears when
    /// spawning a new process.
    public var debugDescription: String {
        return self.description
    }
}

extension PlatformOptions.WindowStyle: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual representation of how the window appears when spawning a
    /// new process.
    public var description: String {
        switch self.storage {
        case .normal:
            return "normal"
        case .hidden:
            return "hidden"
        case .maximized:
            return "maximized"
        case .minimized:
            return "minimized"
        }
    }

    /// A debug-oriented textual representation of how the window appears when
    /// spawning a new process.
    public var debugDescription: String {
        return self.description
    }
}

extension PlatformOptions.JobObjectAssignment {
    /// Whether this mode creates and attempts to assign a Job Object.
    internal var createsJob: Bool {
        switch self.storage {
        case .always, .bestEffort: return true
        case .never: return false
        }
    }
}

extension PlatformOptions.JobObjectAssignment: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual representation of the Job Object assignment mode.
    public var description: String {
        switch self.storage {
        case .always:
            return "always"
        case .bestEffort:
            return "bestEffort"
        case .never:
            return "never"
        }
    }

    /// A debug-oriented textual representation of the Job Object assignment mode.
    public var debugDescription: String {
        return self.description
    }
}

extension PlatformOptions: CustomStringConvertible, CustomDebugStringConvertible {
    internal func description(withIndent indent: Int) -> String {
        let indent = String(repeating: " ", count: indent * 4)
        return """
            PlatformOptions(
            \(indent)    userCredentials: \(String(describing: self.userCredentials)),
            \(indent)    consoleBehavior: \(self.consoleBehavior),
            \(indent)    windowStyle: \(self.windowStyle),
            \(indent)    createProcessGroup: \(self.createProcessGroup),
            \(indent)    jobObjectAssignment: \(self.jobObjectAssignment),
            \(indent)    preSpawnProcessConfigurator: \(self.preSpawnProcessConfigurator == nil ? "not set" : "set")
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

// MARK: - Process Monitoring
@Sendable
internal func waitForProcessTermination(
    for processIdentifier: ProcessIdentifier
) async throws(SubprocessError) {
    // Once the continuation resumes, it will need to unregister the wait, so
    // yield the wait handle back to the calling scope.
    var waitHandle: HANDLE?
    defer {
        if let waitHandle {
            _ = UnregisterWait(waitHandle)
        }
    }

    try await _castError {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // Set up a callback that immediately resumes the continuation and does no
            // other work.
            let context = Unmanaged.passRetained(continuation as AnyObject).toOpaque()
            let callback: WAITORTIMERCALLBACK = { context, _ in
                let continuation =
                    Unmanaged<AnyObject>.fromOpaque(context!).takeRetainedValue() as! CheckedContinuation<Void, any Error>
                continuation.resume()
            }

            // We only want the callback to fire once (and not be rescheduled.) Waiting
            // may take an arbitrarily long time, so let the thread pool know that too.
            let flags = ULONG(WT_EXECUTEONLYONCE | WT_EXECUTELONGFUNCTION)
            guard
                RegisterWaitForSingleObject(
                    &waitHandle,
                    processIdentifier.processDescriptor,
                    callback,
                    context,
                    INFINITE,
                    flags
                )
            else {
                let error: SubprocessError = .failedToMonitor(
                    withUnderlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
                )
                continuation.resume(
                    throwing: error
                )
                return
            }
        }
    }
}

@Sendable
internal func reapProcess(
    with processIdentifier: ProcessIdentifier
) throws(SubprocessError) -> TerminationStatus {
    // Windows keeps the exit code reachable through the process HANDLE
    // until the HANDLE is closed, so there is no zombie to reap. We just
    // need to read the exit code via `GetExitCodeProcess`.
    var status: DWORD = 0
    guard GetExitCodeProcess(processIdentifier.processDescriptor, &status) else {
        throw SubprocessError.failedToMonitor(
            withUnderlyingError: .init(win32Error: GetLastError())
        )
    }

    return .exited(status)
}

// MARK: - Subprocess Control

extension Execution {
    /// Terminate the current subprocess with the given exit code
    /// - Parameters:
    ///   - exitCode: The exit code to use for the subprocess.
    ///   - toProcessGroup: When `true`, terminates the subprocess and any
    ///   descendants by terminating the Job Object that contains them. The
    ///   exit code is propagated to every process in the job. When `false`
    ///   (the default), terminates only the immediate child process, leaving
    ///   descendants unaffected.
    /// - Throws: `SubprocessError` with error code `.processControlFailed`.
    /// Passing `toProcessGroup: true` throws when the subprocess isn't assigned
    /// to a Job Object (`jobObjectAssignment` was `.never`, or `.bestEffort`
    /// and assignment failed).
    public func terminate(
        withExitCode exitCode: DWORD,
        toProcessGroup: Bool = false
    ) throws(SubprocessError) {
        if toProcessGroup {
            guard let jobHandle = self.processIdentifier.jobHandle else {
                // No Job Object assigned, so there's no descendant group to
                // terminate. Throw rather than silently degrading to per-process.
                throw SubprocessError.processControlFailed(
                    .terminate,
                    reason: "The subprocess is not assigned to a Job Object. Set PlatformOptions.jobObjectAssignment to .always or .bestEffort to enable process-group termination.",
                    underlyingError: nil
                )
            }
            guard TerminateJobObject(jobHandle, exitCode) else {
                throw SubprocessError.processControlFailed(
                    .terminate,
                    underlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
                )
            }
        } else {
            guard TerminateProcess(self.processIdentifier.processDescriptor, exitCode) else {
                throw SubprocessError.processControlFailed(
                    .terminate,
                    underlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
                )
            }
        }
    }

    /// Suspend the current subprocess
    public func suspend() throws(SubprocessError) {
        let NTSuspendProcess: (@convention(c) (HANDLE) -> LONG)? =
            unsafeBitCast(
                GetProcAddress(
                    GetModuleHandleA("ntdll.dll"),
                    "NtSuspendProcess"
                ),
                to: Optional<(@convention(c) (HANDLE) -> LONG)>.self
            )
        guard let NTSuspendProcess = NTSuspendProcess else {
            throw SubprocessError.processControlFailed(
                .suspend,
                underlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
            )
        }
        guard NTSuspendProcess(self.processIdentifier.processDescriptor) >= 0 else {
            throw SubprocessError.processControlFailed(
                .suspend,
                underlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
            )
        }
    }

    /// Resume the current subprocess after suspension
    public func resume() throws(SubprocessError) {
        let NTResumeProcess: (@convention(c) (HANDLE) -> LONG)? =
            unsafeBitCast(
                GetProcAddress(
                    GetModuleHandleA("ntdll.dll"),
                    "NtResumeProcess"
                ),
                to: Optional<(@convention(c) (HANDLE) -> LONG)>.self
            )
        guard let NTResumeProcess = NTResumeProcess else {
            throw SubprocessError.processControlFailed(
                .resume,
                underlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
            )
        }
        guard NTResumeProcess(self.processIdentifier.processDescriptor) >= 0 else {
            throw SubprocessError.processControlFailed(
                .resume,
                underlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
            )
        }
    }
}

// MARK: - Executable Searching
extension Executable {
    // Technically not needed for CreateProcess since
    // it takes process name. It's here to support
    // Executable.resolveExecutablePath
    internal func resolveExecutablePath(withPathValue pathValue: String?) throws(SubprocessError) -> String {
        switch self.storage {
        case .executable(let executableName):
            return try executableName._withCString(
                encodedAs: UTF16.self
            ) { exeName throws(SubprocessError) -> String in
                return try pathValue.withOptionalCString(
                    encodedAs: UTF16.self
                ) { path throws(SubprocessError) -> String in
                    let pathLength = SearchPathW(
                        path,
                        exeName,
                        nil,
                        0,
                        nil,
                        nil
                    )
                    guard pathLength > 0 else {
                        throw SubprocessError.executableNotFound(
                            executableName,
                            underlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
                        )
                    }
                    return withUnsafeTemporaryAllocation(
                        of: WCHAR.self,
                        capacity: Int(pathLength) + 1
                    ) {
                        _ = SearchPathW(
                            path,
                            exeName,
                            nil,
                            pathLength + 1,
                            $0.baseAddress,
                            nil
                        )
                        return String(decodingCString: $0.baseAddress!, as: UTF16.self)
                    }
                }
            }
        case .path(let executablePath):
            // Use path directly
            return executablePath.string
        }
    }

    /// `CreateProcessW` allows users to specify the executable path via
    /// `lpApplicationName` or via `lpCommandLine`. However, only `lpCommandLine` supports
    /// path searching, whereas `lpApplicationName` does not. In order to support the
    /// "argument 0 override" feature, Subprocess must use `lpApplicationName` instead of
    /// relying on `lpCommandLine` (so we can potentially set a different value for `lpCommandLine`).
    ///
    /// This method replicates the executable searching behavior of `CreateProcessW`'s
    /// `lpCommandLine`. Specifically, it follows the steps listed in `CreateProcessW`'s documentation:
    ///
    /// 1. The directory from which the application loaded.
    /// 2. The current directory for the parent process.
    /// 3. The 32-bit Windows system directory.
    /// 4. The 16-bit Windows system directory.
    /// 5. The Windows directory.
    /// 6. The directories that are listed in the PATH environment variable.
    ///
    /// For more info:
    /// https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
    internal func possibleExecutablePaths(
        withPathValue pathValue: String?
    ) -> _OrderedSet<String> {
        func insertExecutableAddingExtension(
            _ name: String,
            currentPath: String,
            pathExtensions: _OrderedSet<String>,
            storage: inout _OrderedSet<String>
        ) {
            let fullPath = FilePath(currentPath).appending(name)
            if !name.hasExtension() {
                for ext in pathExtensions {
                    var path = fullPath
                    path.extension = ext
                    storage.insert(path.string)
                }
            } else {
                storage.insert(fullPath.string)
            }
        }

        switch self.storage {
        case .executable(let name):
            var possiblePaths: _OrderedSet<String> = .init()
            let currentEnvironmentValues = Environment.currentEnvironmentValues()
            // If `name` does not include extensions, we need to try these extensions
            var pathExtensions: _OrderedSet<String> = _OrderedSet(["com", "exe", "bat", "cmd"])
            if let extensionList = currentEnvironmentValues["PATHEXT"] {
                for var ext in extensionList.split(separator: ";") {
                    ext.removeFirst(1)
                    pathExtensions.insert(String(ext).lowercased())
                }
            }
            // 1. The directory from which the application loaded.
            let applicationDirectory = try? fillNullTerminatedWideStringBuffer(
                initialSize: DWORD(MAX_PATH), maxSize: DWORD(Int16.max)
            ) {
                return GetModuleFileNameW(nil, $0.baseAddress, DWORD($0.count))
            }
            if let applicationDirectory {
                insertExecutableAddingExtension(
                    name,
                    currentPath: FilePath(applicationDirectory).removingLastComponent().string,
                    pathExtensions: pathExtensions,
                    storage: &possiblePaths
                )
            }
            // 2. Current directory
            let directorySize = GetCurrentDirectoryW(0, nil)
            let currentDirectory = try? fillNullTerminatedWideStringBuffer(
                initialSize: directorySize,
                maxSize: DWORD(Int16.max)
            ) {
                return GetCurrentDirectoryW(DWORD($0.count), $0.baseAddress)
            }
            if let currentDirectory {
                insertExecutableAddingExtension(
                    name,
                    currentPath: currentDirectory,
                    pathExtensions: pathExtensions,
                    storage: &possiblePaths
                )
            }
            // 3. System directory (System32)
            let systemDirectorySize = GetSystemDirectoryW(nil, 0)
            let systemDirectory = try? fillNullTerminatedWideStringBuffer(
                initialSize: systemDirectorySize,
                maxSize: DWORD(Int16.max)
            ) {
                return GetSystemDirectoryW($0.baseAddress, DWORD($0.count))
            }
            if let systemDirectory {
                insertExecutableAddingExtension(
                    name,
                    currentPath: systemDirectory,
                    pathExtensions: pathExtensions,
                    storage: &possiblePaths
                )
            }
            // 4. The Windows directory
            let windowsDirectorySize = GetWindowsDirectoryW(nil, 0)
            let windowsDirectory = try? fillNullTerminatedWideStringBuffer(
                initialSize: windowsDirectorySize,
                maxSize: DWORD(Int16.max)
            ) {
                return GetWindowsDirectoryW($0.baseAddress, DWORD($0.count))
            }
            if let windowsDirectory {
                insertExecutableAddingExtension(
                    name,
                    currentPath: windowsDirectory,
                    pathExtensions: pathExtensions,
                    storage: &possiblePaths
                )

                // 5. 16 bit Systen Directory
                // Windows documentation stats that "No such standard function
                // (similar to GetSystemDirectory) exists for the 16-bit system folder".
                // Use "\(windowsDirectory)\System" instead
                let systemDirectory16 = FilePath(windowsDirectory).appending("System")
                insertExecutableAddingExtension(
                    name,
                    currentPath: systemDirectory16.string,
                    pathExtensions: pathExtensions,
                    storage: &possiblePaths
                )
            }
            // 6. The directories that are listed in the PATH environment variable
            if let pathValue {
                let searchPaths = pathValue.split(separator: ";").map { String($0) }
                for possiblePath in searchPaths {
                    insertExecutableAddingExtension(
                        name,
                        currentPath: possiblePath,
                        pathExtensions: pathExtensions,
                        storage: &possiblePaths
                    )
                }
            }
            return possiblePaths
        case .path(let path):
            return _OrderedSet([path.string])
        }
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
        }
    }

    internal static func withCopiedEnv<R>(_ body: ([UnsafeMutablePointer<CChar>]) -> R) -> R {
        var values: [UnsafeMutablePointer<CChar>] = []
        guard let pwszEnvironmentBlock = GetEnvironmentStringsW() else {
            return body([])
        }
        defer { FreeEnvironmentStringsW(pwszEnvironmentBlock) }

        var pwszEnvironmentEntry: LPWCH? = pwszEnvironmentBlock
        while let value = pwszEnvironmentEntry {
            let entry = String(decodingCString: value, as: UTF16.self)
            if entry.isEmpty { break }
            values.append(entry.withCString { _strdup($0)! })
            pwszEnvironmentEntry = pwszEnvironmentEntry?.advanced(by: wcslen(value) + 1)
        }
        defer { values.forEach { free($0) } }
        return body(values)
    }
}

// MARK: - ProcessIdentifier

/// A platform-independent identifier for a subprocess.
public struct ProcessIdentifier: Sendable, Hashable {
    /// The Windows-specific process identifier value.
    public let value: DWORD
    /// The process handle for this execution.
    public nonisolated(unsafe) let processDescriptor: HANDLE
    /// The main thread handle for this execution.
    public nonisolated(unsafe) let threadHandle: HANDLE
    /// The Job Object handle that contains this process and any descendants,
    /// or `nil` if the process isn't assigned to a Job Object, either because
    /// `PlatformOptions.jobObjectAssignment` was `.never`, or because it was
    /// `.bestEffort` and assignment failed.
    internal nonisolated(unsafe) let jobHandle: HANDLE?

    internal init(
        value: DWORD,
        processDescriptor: HANDLE,
        threadHandle: HANDLE,
        jobHandle: HANDLE?
    ) {
        self.value = value
        self.processDescriptor = processDescriptor
        self.threadHandle = threadHandle
        self.jobHandle = jobHandle
    }

    internal func close() {
        guard CloseHandle(self.threadHandle) else {
            fatalError("Failed to close thread HANDLE: \(SubprocessError.WindowsError(win32Error: GetLastError()))")
        }
        guard CloseHandle(self.processDescriptor) else {
            fatalError("Failed to close process HANDLE: \(SubprocessError.WindowsError(win32Error: GetLastError()))")
        }
        if let jobHandle = self.jobHandle {
            guard CloseHandle(jobHandle) else {
                fatalError("Failed to close job HANDLE: \(SubprocessError.WindowsError(win32Error: GetLastError()))")
            }
        }
    }
}

extension ProcessIdentifier: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual representation of the process identifier.
    public var description: String {
        return "(processID: \(self.value))"
    }

    /// A debug-oriented textual representation of the process identifier.
    public var debugDescription: String {
        return description
    }
}

// MARK: - Private Utils
extension Configuration {
    private func preSpawn(withPossibleExecutablePath executablePath: String) throws(SubprocessError) -> (
        applicationName: String?,
        commandAndArgs: String,
        environment: String,
        intendedWorkingDir: String?
    ) {
        // Prepare environment
        var env: [Environment.Key: String] = [:]
        switch self.environment.config {
        case .custom(let customValues):
            // Use the custom values directly
            env = customValues
        case .inherit(let updateValues):
            // Combine current environment
            env = Environment.currentEnvironmentValues()
            for (key, value) in updateValues {
                if let value {
                    // Update env with ew value
                    env.updateValue(value, forKey: key)
                } else {
                    // If `value` is `nil`, unset this value from env
                    env.removeValue(forKey: key)
                }
            }
        }
        // On Windows, the PATH is required in order to locate dlls needed by
        // the process so we should also pass that to the child
        if env[.path] == nil,
            let parentPath = Environment.currentEnvironmentValues()[.path]
        {
            env[.path] = parentPath
        }
        // The environment string must be terminated by a double
        // null-terminator.  Otherwise, CreateProcess will fail with
        // INVALID_PARMETER.
        let environmentString =
            env.map {
                $0.key.rawValue + "=" + $0.value
            }.joined(separator: "\0") + "\0\0"

        // Prepare arguments
        let (
            applicationName,
            commandAndArgs
        ) = try self.generateWindowsCommandAndArguments(
            withPossibleExecutablePath: executablePath
        )
        // `generateWindowsCommandAndArguments` already decided whether to
        // omit `applicationName` (and rely on `commandAndArgs` for the
        // executable path), so pass its result through unchanged.
        return (
            applicationName: applicationName,
            commandAndArgs: commandAndArgs,
            environment: environmentString,
            intendedWorkingDir: self.workingDirectory?.string
        )
    }

    private func generateCreateProcessFlag() -> DWORD {
        var flags = CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT
        switch self.platformOptions.consoleBehavior.storage {
        case .createNew:
            flags |= CREATE_NEW_CONSOLE
        case .detach:
            flags |= DETACHED_PROCESS
        case .inherit:
            break
        }
        if self.platformOptions.createProcessGroup {
            flags |= CREATE_NEW_PROCESS_GROUP
        }
        return DWORD(flags)
    }

    private func withStartupInfoEx<Result>(
        inputRead inputReadFileDescriptor: borrowing IODescriptor?,
        inputWrite inputWriteFileDescriptor: borrowing IODescriptor?,
        outputRead outputReadFileDescriptor: borrowing IODescriptor?,
        outputWrite outputWriteFileDescriptor: borrowing IODescriptor?,
        errorRead errorReadFileDescriptor: borrowing IODescriptor?,
        errorWrite errorWriteFileDescriptor: borrowing IODescriptor?,
        _ body: (UnsafeMutablePointer<STARTUPINFOEXW>) async throws(SubprocessError) -> Result
    ) async throws(SubprocessError) -> Result {
        var info: STARTUPINFOEXW = STARTUPINFOEXW()
        info.StartupInfo.cb = DWORD(MemoryLayout.size(ofValue: info))
        info.StartupInfo.dwFlags |= DWORD(STARTF_USESTDHANDLES)

        if self.platformOptions.windowStyle.storage != .normal {
            info.StartupInfo.wShowWindow = self.platformOptions.windowStyle.platformStyle
            info.StartupInfo.dwFlags |= DWORD(STARTF_USESHOWWINDOW)
        }
        // Bind IOs
        // Keep track of the explicitly list HANDLE to be inherited by the child process
        // This emulate `posix_spawn`'s `POSIX_SPAWN_CLOEXEC_DEFAULT`
        var inheritedHandles: Set<HANDLE> = Set()
        // Input
        if inputReadFileDescriptor != nil {
            let inputHandle = inputReadFileDescriptor!.platformDescriptor()
            SetHandleInformation(inputHandle, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT))
            info.StartupInfo.hStdInput = inputHandle
            inheritedHandles.insert(inputHandle)
        }
        if inputWriteFileDescriptor != nil {
            // Set parent side to be uninheritable
            SetHandleInformation(
                inputWriteFileDescriptor!.platformDescriptor(),
                DWORD(HANDLE_FLAG_INHERIT),
                0
            )
        }
        // Output
        if outputWriteFileDescriptor != nil {
            let outputHandle = outputWriteFileDescriptor!.platformDescriptor()
            SetHandleInformation(outputHandle, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT))
            info.StartupInfo.hStdOutput = outputHandle
            inheritedHandles.insert(outputHandle)
        }
        if outputReadFileDescriptor != nil {
            // Set parent side to be uninheritable
            SetHandleInformation(
                outputReadFileDescriptor!.platformDescriptor(),
                DWORD(HANDLE_FLAG_INHERIT),
                0
            )
        }
        // Error
        if errorWriteFileDescriptor != nil {
            let errorHandle = errorWriteFileDescriptor!.platformDescriptor()
            SetHandleInformation(errorHandle, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT))
            info.StartupInfo.hStdError = errorHandle
            inheritedHandles.insert(errorHandle)
        }
        if errorReadFileDescriptor != nil {
            // Set parent side to be uninheritable
            SetHandleInformation(
                errorReadFileDescriptor!.platformDescriptor(),
                DWORD(HANDLE_FLAG_INHERIT),
                0
            )
        }
        // Initialize an attribute list of sufficient size for the specified number of
        // attributes. Alignment is a problem because LPPROC_THREAD_ATTRIBUTE_LIST is
        // an opaque pointer and we don't know the alignment of the underlying data.
        // We *should* use the alignment of C's max_align_t, but it is defined using a
        // C++ using statement on Windows and isn't imported into Swift. So, 16 it is.
        let alignment = 16
        var attributeListByteCount = SIZE_T(0)
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeListByteCount)
        // We can't use withUnsafeTemporaryAllocation here because body is async
        let attributeListPtr: UnsafeMutableRawBufferPointer = .allocate(
            byteCount: Int(attributeListByteCount),
            alignment: alignment
        )
        defer {
            attributeListPtr.deallocate()
        }

        let attributeList = LPPROC_THREAD_ATTRIBUTE_LIST(attributeListPtr.baseAddress!)
        guard InitializeProcThreadAttributeList(attributeList, 1, 0, &attributeListByteCount) else {
            throw SubprocessError.spawnFailed(
                withUnderlyingError: SubprocessError.WindowsError(win32Error: GetLastError())
            )
        }
        defer {
            DeleteProcThreadAttributeList(attributeList)
        }

        let handles = Array(inheritedHandles)

        // Manually allocate an array instead of using withUnsafeMutableBufferPointer, since the
        // UpdateProcThreadAttribute documentation states that the lpValue pointer must persist
        // until the attribute list is destroyed using DeleteProcThreadAttributeList.
        let handlesPointer = UnsafeMutablePointer<HANDLE>.allocate(capacity: handles.count)
        defer {
            handlesPointer.deinitialize(count: handles.count)
            handlesPointer.deallocate()
        }
        handlesPointer.initialize(from: handles, count: handles.count)
        let inheritedHandlesPtr = UnsafeMutableBufferPointer(start: handlesPointer, count: handles.count)

        do {
            _ = UpdateProcThreadAttribute(
                attributeList,
                0,
                _subprocess_PROC_THREAD_ATTRIBUTE_HANDLE_LIST(),
                inheritedHandlesPtr.baseAddress!,
                SIZE_T(MemoryLayout<HANDLE>.stride * inheritedHandlesPtr.count),
                nil,
                nil
            )

            info.lpAttributeList = attributeList
        }
        return try await body(&info)
    }

    /// Creates a Job Object that will contain a spawned child process and
    /// any descendants.
    ///
    /// - Important: The handle is created with default security attributes,
    /// which makes it non-inheritable. Descendants must not receive a duplicate
    /// of the handle, so the parent can retain exclusive control over the job's
    /// lifetime.
    private static func createJobObject() throws(SubprocessError) -> HANDLE {
        guard let jobHandle = CreateJobObjectW(nil, nil),
            jobHandle != INVALID_HANDLE_VALUE
        else {
            throw SubprocessError.spawnFailed(
                withUnderlyingError: SubprocessError.WindowsError(win32Error: GetLastError()),
                reason: "Failed to create Job Object"
            )
        }
        return jobHandle
    }

    /// Assigns the child process to the Job Object as specified by `assignment`
    /// and, if requested, resumes the child process thread.
    ///
    /// When `resumeThread` is `false`, the caller is responsible for resuming
    /// the child using `ResumeThread` on the thread handle exposed through
    /// `Execution.processIdentifier.threadHandle`. The child remains
    /// suspended until then.
    ///
    /// The returned handle will be `nil` if `assignment` is `.never`, or if it
    /// is `.bestEffort` and assignment failed.
    private static func assignChildToJobObjectAndResume(
        jobHandle: HANDLE?,
        processInfo: PROCESS_INFORMATION,
        assignment: PlatformOptions.JobObjectAssignment,
        resumeThread: Bool
    ) throws(SubprocessError) -> HANDLE? {
        var assignedJob: HANDLE? = nil

        // A job handle exists only if assignment is `.always` or `.bestEffort`.
        if let jobHandle {
            if AssignProcessToJobObject(jobHandle, processInfo.hProcess) {
                assignedJob = jobHandle
            } else if case .always = assignment.storage {
                let assignError = SubprocessError.WindowsError(win32Error: GetLastError())
                _ = TerminateProcess(processInfo.hProcess, 1)
                _ = CloseHandle(processInfo.hThread)
                _ = CloseHandle(processInfo.hProcess)

                // Detect the most common cause of assignment failure: the parent
                // process itself is in a non-nestable Job Object.
                var isParentInJob: WindowsBool = false
                var reason = "Failed to assign child process to Job Object"
                if IsProcessInJob(GetCurrentProcess(), nil, &isParentInJob),
                    isParentInJob.boolValue
                {
                    reason += " (likely because the parent process is in a Job Object that does not allow nesting)"
                }

                throw SubprocessError.spawnFailed(
                    withUnderlyingError: assignError,
                    reason: reason
                )
            }
            // `.bestEffort` failure: proceed without a job; fall through to resume.
        }

        if resumeThread {
            guard ResumeThread(processInfo.hThread) != DWORD(bitPattern: -1) else {
                let resumeError = SubprocessError.WindowsError(win32Error: GetLastError())
                _ = TerminateProcess(processInfo.hProcess, 1)
                _ = CloseHandle(processInfo.hThread)
                _ = CloseHandle(processInfo.hProcess)
                throw SubprocessError.spawnFailed(
                    withUnderlyingError: resumeError,
                    reason: "Failed to resume child process thread after Job Object assignment"
                )
            }
        }

        return assignedJob
    }

    private func generateWindowsCommandAndArguments(
        withPossibleExecutablePath executablePath: String
    ) throws(SubprocessError) -> (
        applicationName: String?,
        commandAndArgs: String
    ) {
        // CreateProcessW behavior:
        // - lpApplicationName: The actual executable path to run (can be NULL)
        // - lpCommandLine: The command line string passed to the process
        //
        // If both are specified:
        // - Windows runs the exe from lpApplicationName
        // - The new process receives lpCommandLine as-is via GetCommandLine()
        // - argv[0] is parsed from lpCommandLine, NOT from lpApplicationName
        //
        // For Unix-style argv[0] override (where argv[0] differs from actual exe):
        // Set lpApplicationName = "C:\\path\\to\\real.exe"
        // Set lpCommandLine = "fake_name.exe arg1 arg2"
        let args = self.arguments.storage.map {
            guard case .string(let stringValue) = $0 else {
                // We should never get here since the API
                // is guarded off
                fatalError("Windows does not support non unicode String as arguments")
            }
            return stringValue
        }

        // When the target is a batch file (`.bat`/`.cmd`), `CreateProcessW`
        // runs it by implicitly spawning `cmd.exe /c <command line>`. Because
        // `cmd.exe` parses its command line differently from
        // `CommandLineToArgvW`, the step 1 quoting in `quoteWindowsCommandLine`
        // is not sufficient on its own. A metacharacter such as `&` in an
        // argument would be interpreted by `cmd.exe` as a command separator,
        // enabling command injection. This is the "BatBadBut" class of
        // vulnerabilities (e.g. CVE-2024-24576, CVE-2024-43402). Invoke
        // `cmd.exe` explicitly with controlled flags and additionally escape
        // each argument for `cmd.exe` (Colascione's "step 2").
        let targetsBatchFile = executablePath.isWindowsBatchFile

        if targetsBatchFile {
            // The argv[0] override is not applicable to a batch file: `cmd.exe`
            // sets %0 to the script path, so it is intentionally not applied.
            //
            // Resolve `cmd.exe` from the system directory so a directory earlier
            // on PATH can't substitute a different interpreter.
            let commandPrompt = try Self.resolveCommandPromptPath()
            let commandAndArgs = try Self.makeBatchFileCommandLine(
                scriptPath: executablePath,
                arguments: args
            )
            return (applicationName: commandPrompt, commandAndArgs: commandAndArgs)
        }

        var commandLineArguments = args
        if case .string(let overrideName) = self.arguments.executablePathOverride {
            // Use the override as argument0 and set applicationName
            commandLineArguments.insert(overrideName, at: 0)
        } else {
            // Set argument[0] to be executableNameOrPath
            commandLineArguments.insert(executablePath, at: 0)
        }
        return (
            // Omit applicationName (and therefore rely on commandAndArgs for
            // executable path) when we don't need to override arg0.
            applicationName: self.arguments.executablePathOverride == nil ? nil : executablePath,
            commandAndArgs: Self.quoteWindowsCommandLine(commandLineArguments)
        )
    }

    /// Resolves the absolute path to `cmd.exe` from the Windows system directory.
    private static func resolveCommandPromptPath() throws(SubprocessError) -> String {
        do throws(SubprocessError.WindowsError) {
            let systemDirectorySize = GetSystemDirectoryW(nil, 0)
            let systemDirectory = try fillNullTerminatedWideStringBuffer(
                initialSize: systemDirectorySize,
                maxSize: DWORD(Int16.max)
            ) {
                return GetSystemDirectoryW($0.baseAddress, DWORD($0.count))
            }
            return FilePath(systemDirectory).appending("cmd.exe").string
        } catch {
            throw SubprocessError.asyncIOFailed(
                reason: "Failed to resolve system directory",
                underlyingError: error
            )
        }
    }

    /// Builds a `cmd.exe` command line that runs a batch file with arguments
    /// escaped to survive both `cmd.exe` and `CommandLineToArgvW` parsing.
    ///
    /// This logic was taken from Rust standard library's `make_bat_command_line`, which hardened these after
    /// CVE-2024-24576 / CVE-2024-43402.
    /// https://github.com/rust-lang/rust/blob/master/library/std/src/sys/args/windows.rs
    ///
    /// `/d` skips AutoRun, `/e:ON` keeps command extensions, `/v:OFF` disables
    /// delayed `!` expansion.
    internal static func makeBatchFileCommandLine(
        scriptPath: String,
        arguments: [String]
    ) throws(SubprocessError) -> String {
        // `cmd.exe` identifies the script by its quoted token, so the path must
        // not contain a quote or end with a backslash (which would escape the
        // closing quote).
        guard !scriptPath.contains("\""), scriptPath.last != "\\" else {
            throw SubprocessError.spawnFailed(
                withUnderlyingError: nil,
                reason:
                    "Cannot safely run batch file \"\(scriptPath)\": its path must not contain '\"' or end with '\\'."
            )
        }
        guard !scriptPath.containsCommandLineControlCharacters() else {
            throw SubprocessError.spawnFailed(
                withUnderlyingError: nil,
                reason:
                    "Cannot safely run batch file \"\(scriptPath)\": its path must not contain \r \n or null byte."
            )
        }
        var commandLine = "cmd.exe /d /e:ON /v:OFF /c \""
        commandLine += "\"\(scriptPath)\""
        for argument in arguments {
            commandLine += " "
            commandLine += try Self.escapeBatchFileArgument(argument)
        }
        commandLine += "\""
        return commandLine
    }

    /// Escapes a single argument destined for a batch file run through
    /// `cmd.exe`. Applies the `CommandLineToArgvW` quoting ("step 1"), then
    /// prefixes every `cmd.exe` metacharacter,  including the quotes step 1
    /// added,  with `^` ("step 2"). After `cmd.exe` consumes the carets, the
    /// child program decodes exactly the original argument.
    ///
    /// Both steps are from Daniel Colascione's "Everyone quotes command line
    /// arguments the wrong way":
    /// https://learn.microsoft.com/en-us/archive/blogs/twistylittlepassagesallalike/everyone-quotes-command-line-arguments-the-wrong-way
    internal static func escapeBatchFileArgument(_ argument: String) throws(SubprocessError) -> String {
        // A NUL truncates the command-line string and CR/LF can split it
        // into multiple commands. None can be safely escaped for `cmd.exe`,
        // so reject them rather than silently truncate (matching the
        // fail-closed behavior other runtimes adopted).
        guard !argument.containsCommandLineControlCharacters() else {
            throw SubprocessError.spawnFailed(
                withUnderlyingError: nil,
                reason:
                    "Cannot pass argument to batch file: arguments may not contain NUL, carriage return, or newline characters."
            )
        }
        // Step 1: quote for `CommandLineToArgvW`. An empty argument must be
        // force-quoted, otherwise it would vanish from the command line.
        let quoted = argument.isEmpty ? "\"\"" : Self.quoteWindowsCommandArgument(argument)
        // Step 2: escape `cmd.exe` metacharacters with `^`.
        var escaped = ""
        escaped.reserveCapacity(quoted.count)
        for character in quoted {
            if Self.cmdMetacharacters.contains(character) {
                escaped.append("^")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// The characters that trigger `cmd.exe`'s textual transformations and so
    /// must be escaped with `^` when they appear in an argument.
    ///
    /// `%` is included per the reference algorithm, but note `cmd.exe`'s
    /// environment-variable expansion has edge cases `^` cannot fully suppress;
    /// `%` is not a command-injection vector, however. `!` is additionally
    /// neutralized by the `/v:OFF` flag set in `makeBatchFileCommandLine`.
    private static let cmdMetacharacters: Set<Character> = [
        "(", ")", "%", "!", "^", "\"", "<", ">", "&", "|",
    ]

    // Taken from SCF
    private static func quoteWindowsCommandLine(_ commandLine: [String]) -> String {
        return commandLine.map(Self.quoteWindowsCommandArgument).joined(separator: " ")
    }

    /// Quotes a single argument so the `CommandLineToArgvW` / C runtime parser
    /// in the child decodes it back to the original string (Colascione's
    /// "step 1"). Taken from SCF.
    /// See https://learn.microsoft.com/en-us/archive/blogs/twistylittlepassagesallalike/everyone-quotes-command-line-arguments-the-wrong-way
    private static func quoteWindowsCommandArgument(_ arg: String) -> String {
        // Windows escaping, adapted from Daniel Colascione's "Everyone quotes
        // command line arguments the wrong way" - Microsoft Developer Blog
        if !arg.contains(where: { " \t\n\"".contains($0) }) {
            return arg
        }

        // To escape the command line, we surround the argument with quotes. However
        // the complication comes due to how the Windows command line parser treats
        // backslashes (\) and quotes (")
        //
        // - \ is normally treated as a literal backslash
        //     - e.g. foo\bar\baz => foo\bar\baz
        // - However, the sequence \" is treated as a literal "
        //     - e.g. foo\"bar => foo"bar
        //
        // But then what if we are given a path that ends with a \? Surrounding
        // foo\bar\ with " would be "foo\bar\" which would be an unterminated string

        // since it ends on a literal quote. To allow this case the parser treats:
        //
        // - \\" as \ followed by the " metachar
        // - \\\" as \ followed by a literal "
        // - In general:
        //     - 2n \ followed by " => n \ followed by the " metachar
        //     - 2n+1 \ followed by " => n \ followed by a literal "
        var quoted = "\""
        var unquoted = arg.unicodeScalars

        while !unquoted.isEmpty {
            guard let firstNonBackslash = unquoted.firstIndex(where: { $0 != "\\" }) else {
                // String ends with a backslash e.g. foo\bar\, escape all the backslashes
                // then add the metachar " below
                let backslashCount = unquoted.count
                quoted.append(String(repeating: "\\", count: backslashCount * 2))
                break
            }
            let backslashCount = unquoted.distance(from: unquoted.startIndex, to: firstNonBackslash)
            if unquoted[firstNonBackslash] == "\"" {
                // This is  a string of \ followed by a " e.g. foo\"bar. Escape the
                // backslashes and the quote
                quoted.append(String(repeating: "\\", count: backslashCount * 2 + 1))
                quoted.append(String(unquoted[firstNonBackslash]))
            } else {
                // These are just literal backslashes
                quoted.append(String(repeating: "\\", count: backslashCount))
                quoted.append(String(unquoted[firstNonBackslash]))
            }
            // Drop the backslashes and the following character
            unquoted.removeFirst(backslashCount + 1)
        }
        quoted.append("\"")
        return quoted
    }

    private static func pathAccessible(_ path: String) -> Bool {
        return path.withCString(encodedAs: UTF16.self) {
            let attrs = GetFileAttributesW($0)
            return attrs != INVALID_FILE_ATTRIBUTES
        }
    }
}

private extension String {
    // A NUL truncates the command-line string and CR/LF can split it
    // into multiple commands. None can be safely escaped for `cmd.exe`,
    // so reject them rather than silently truncate (matching the
    // fail-closed behavior other runtimes adopted).
    func containsCommandLineControlCharacters() -> Bool {
        for scalar in self.unicodeScalars {
            if scalar == "\u{0}" || scalar == "\r" || scalar == "\n" {
                return true
            }
        }
        return false
    }
}

// MARK: - Type alias
internal typealias PlatformFileDescriptor = HANDLE

// MARK: - Pipe Support
extension FileDescriptor {
    // NOTE: Not the same as SwiftSystem's FileDescriptor.pipe, which has different behavior,
    // because it passes _O_NOINHERIT through the _pipe interface (https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/pipe),
    // which ends up setting bInheritHandle to false in the SECURITY_ATTRIBUTES (see ucrt/conio/pipe.cpp in the ucrt sources).
    internal static func ssp_pipe() throws(SubprocessError) -> (
        readEnd: FileDescriptor,
        writeEnd: FileDescriptor
    ) {
        var fds: [2 of CInt] = [-1, -1]
        var span = fds.mutableSpan
        try span.withUnsafeMutableBufferPointer { fds throws(SubprocessError) in
            guard 0 == _pipe(fds.baseAddress!, 0, _O_BINARY) else {
                throw SubprocessError.asyncIOFailed(
                    reason: "Failed to create pipe",
                    underlyingError: SubprocessError.WindowsError(
                        cRuntimeError: _subprocess_windows_get_errno()
                    )
                )
            }
        }
        return (
            readEnd: FileDescriptor(rawValue: fds[0]),
            writeEnd: FileDescriptor(rawValue: fds[1])
        )
    }

    var platformDescriptor: PlatformFileDescriptor {
        return HANDLE(bitPattern: _get_osfhandle(self.rawValue))!
    }
}

extension Optional where Wrapped == String {
    fileprivate func withOptionalCString<Result, Encoding>(
        encodedAs targetEncoding: Encoding.Type,
        _ body: (UnsafePointer<Encoding.CodeUnit>?) throws(SubprocessError) -> Result
    ) throws(SubprocessError) -> Result where Encoding: _UnicodeEncoding {
        switch self {
        case .none:
            return try body(nil)
        case .some(let value):
            return try value._withCString(encodedAs: targetEncoding, body)
        }
    }

    fileprivate func withOptionalNTPathRepresentation<Result: Sendable>(
        _ body: (UnsafePointer<WCHAR>?) throws(SubprocessError) -> Result
    ) throws(SubprocessError) -> Result {
        switch self {
        case .none:
            return try body(nil)
        case .some(let value):
            return try value.withNTPathRepresentation(body)
        }
    }
}

extension String {
    /// Invokes `body` with a resolved and potentially `\\?\`-prefixed version of the pointee,
    /// to ensure long paths greater than MAX_PATH (260) characters are handled correctly.
    ///
    /// - parameter relative: Returns the original path without transforming through GetFullPathNameW + PathCchCanonicalizeEx, if the path is relative.
    /// - seealso: https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
    internal func withNTPathRepresentation<Result: Sendable>(
        _ body: (UnsafePointer<WCHAR>) throws(SubprocessError) -> Result
    ) throws(SubprocessError) -> Result {
        guard !isEmpty else {
            throw SubprocessError.spawnFailed(
                withUnderlyingError: nil,
                reason: "Invalid Windows path"
            )
        }

        var iter = self.utf8.makeIterator()
        let bLeadingSlash =
            if [._slash, ._backslash].contains(iter.next()), iter.next()?.isLetter ?? false, iter.next() == ._colon {
                true
            } else { false }

        // Strip the leading `/` on a RFC8089 path (`/[drive-letter]:/...` ).  A
        // leading slash indicates a rooted path on the drive for the current
        // working directory.
        return try Substring(self.utf8.dropFirst(bLeadingSlash ? 1 : 0))._withCString(
            encodedAs: UTF16.self
        ) {
            pwszPath throws(SubprocessError) in
            // 1. Normalize the path first.
            // Contrary to the documentation, this works on long paths independently
            // of the registry or process setting to enable long paths (but it will also
            // not add the \\?\ prefix required by other functions under these conditions).
            let dwLength: DWORD = GetFullPathNameW(pwszPath, 0, nil, nil)
            return try _castError {
                return try withUnsafeTemporaryAllocation(of: WCHAR.self, capacity: Int(dwLength)) { pwszFullPath in
                    guard (1..<dwLength).contains(GetFullPathNameW(pwszPath, DWORD(pwszFullPath.count), pwszFullPath.baseAddress, nil)) else {
                        throw SubprocessError.spawnFailed(
                            withUnderlyingError: SubprocessError.WindowsError(win32Error: GetLastError()),
                            reason: "Invalid Windows Path"
                        )
                    }

                    // 1.5 Leave \\.\ prefixed paths alone since device paths are already an exact representation and PathCchCanonicalizeEx will mangle these.
                    if let base = pwszFullPath.baseAddress,
                        base[0] == UInt16(UInt8._backslash),
                        base[1] == UInt16(UInt8._backslash),
                        base[2] == UInt16(UInt8._period),
                        base[3] == UInt16(UInt8._backslash)
                    {
                        return try body(base)
                    }

                    // 2. Canonicalize the path.
                    // This will add the \\?\ prefix if needed based on the path's length.
                    var pwszCanonicalPath: LPWSTR?
                    let flags: ULONG = numericCast(PATHCCH_ALLOW_LONG_PATHS.rawValue)
                    let result = PathAllocCanonicalize(pwszFullPath.baseAddress, flags, &pwszCanonicalPath)
                    if let pwszCanonicalPath {
                        defer { LocalFree(pwszCanonicalPath) }
                        if result == S_OK {
                            // 3. Perform the operation on the normalized path.
                            return try body(pwszCanonicalPath)
                        }
                    }

                    throw SubprocessError.spawnFailed(
                        withUnderlyingError: SubprocessError.WindowsError(
                            hresult: result
                        ),
                        reason: "Invalid Windows Path"
                    )
                }
            }
        }
    }

    internal func hasExtension() -> Bool {
        let components = self.split(separator: ".")
        return components.count > 1 && components.last?.count == 3
    }

    /// Returns `true` if this path names a Windows batch file (`.bat` or
    /// `.cmd`), which `CreateProcessW` executes by spawning `cmd.exe`.
    ///
    /// Trailing spaces and dots are ignored first, because Windows strips them
    /// when resolving a path: `deploy.bat. .` still runs as a batch file. Not
    /// accounting for this was the bypass behind CVE-2024-43402:
    /// https://blog.rust-lang.org/2024/09/04/cve-2024-43402/
    internal var isWindowsBatchFile: Bool {
        var end = self[...]
        while let last = end.last, last == " " || last == "." {
            end = end.dropLast()
        }
        let lowercased = end.lowercased()
        return lowercased.hasSuffix(".bat") || lowercased.hasSuffix(".cmd")
    }
}

@inline(__always)
fileprivate func HRESULT_CODE(_ hr: HRESULT) -> DWORD {
    DWORD(hr) & 0xffff
}

@inline(__always)
fileprivate func HRESULT_FACILITY(_ hr: HRESULT) -> DWORD {
    DWORD(hr << 16) & 0x1fff
}

@inline(__always)
fileprivate func SUCCEEDED(_ hr: HRESULT) -> Bool {
    hr >= 0
}

// This is a non-standard extension to the Windows SDK that allows us to convert an
// HRESULT to a Win32 error code.
@inline(__always)
fileprivate func WIN32_FROM_HRESULT(_ hr: HRESULT) -> DWORD {
    if SUCCEEDED(hr) { return DWORD(ERROR_SUCCESS) }
    if HRESULT_FACILITY(hr) == FACILITY_WIN32 {
        return HRESULT_CODE(hr)
    }
    return DWORD(hr)
}

extension UInt8 {
    static var _slash: UInt8 { UInt8(ascii: "/") }
    static var _backslash: UInt8 { UInt8(ascii: "\\") }
    static var _colon: UInt8 { UInt8(ascii: ":") }
    static var _period: UInt8 { UInt8(ascii: ".") }

    var isLetter: Bool? {
        return (0x41...0x5a) ~= self || (0x61...0x7a) ~= self
    }
}

/// Calls a Win32 API function that fills a (potentially long path) null-terminated string buffer by continually attempting to allocate more memory up until the true max path is reached.
/// This is especially useful for protecting against race conditions like with GetCurrentDirectoryW where the measured length may no longer be valid on subsequent calls.
/// - parameter initialSize: Initial size of the buffer (including the null terminator) to allocate to hold the returned string.
/// - parameter maxSize: Maximum size of the buffer (including the null terminator) to allocate to hold the returned string.
/// - parameter body: Closure to call the Win32 API function to populate the provided buffer.
/// Should return the number of UTF-16 code units (not including the null terminator) copied, 0 to indicate an error.
/// If the buffer is not of sufficient size, should return a value greater than or equal to the size of the buffer.
internal func fillNullTerminatedWideStringBuffer(
    initialSize: DWORD,
    maxSize: DWORD,
    _ body: (UnsafeMutableBufferPointer<WCHAR>) throws(SubprocessError.WindowsError) -> DWORD
) throws(SubprocessError.WindowsError) -> String {
    var bufferCount = max(1, min(initialSize, maxSize))
    while bufferCount <= maxSize {
        do {
            if let result = try withUnsafeTemporaryAllocation(
                of: WCHAR.self, capacity: Int(bufferCount),
                { buffer throws(SubprocessError.WindowsError) in
                    let count = try body(buffer)
                    switch count {
                    case 0:
                        throw SubprocessError.WindowsError(win32Error: GetLastError())
                    case 1..<DWORD(buffer.count):
                        let result = String(decodingCString: buffer.baseAddress!, as: UTF16.self)
                        assert(result.utf16.count == count, "Parsed UTF-16 count \(result.utf16.count) != reported UTF-16 count \(count)")
                        return result
                    default:
                        bufferCount *= 2
                        return nil
                    }
                })
            {
                return result
            }
        } catch {
            #if swift(>=6.3)
            throw error
            #else
            throw error as! SubprocessError.WindowsError
            #endif
        }
    }
    throw SubprocessError.WindowsError(win32Error: DWORD(ERROR_INSUFFICIENT_BUFFER))
}

#endif // canImport(WinSDK)
