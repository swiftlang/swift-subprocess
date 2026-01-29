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

@preconcurrency import WinSDK
internal import Dispatch
#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
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
        // Spawn differently depending on whether
        // we need to spawn as a user
        guard let userCredentials = self.platformOptions.userCredentials else {
            return try await self.spawnDirect(
                withInput: inputPipe,
                outputPipe: outputPipe,
                errorPipe: errorPipe
            )
        }
        return try await self.spawnAsUser(
            withInput: inputPipe,
            outputPipe: outputPipe,
            errorPipe: errorPipe,
            userCredentials: userCredentials
        )
    }

    internal func spawnDirect(
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

            let (created, processInfo, windowsError) = try await self.withStartupInfoEx(
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

                // Spawn!
                let spawnContext = SpawnContext(
                    startupInfo: startupInfo,
                    createProcessFlags: createProcessFlags
                )
                return try await runOnBackgroundThread { () throws(SubprocessError) in
                    return try applicationName.withOptionalNTPathRepresentation { applicationNameW throws(SubprocessError) in
                        try commandAndArgs._withCString(
                            encodedAs: UTF16.self
                        ) { commandAndArgsW throws(SubprocessError) in
                            try environment._withCString(
                                encodedAs: UTF16.self
                            ) { environmentW throws(SubprocessError) in
                                try intendedWorkingDir.withOptionalNTPathRepresentation { intendedWorkingDirW throws(SubprocessError) in
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
                                    return (result, processInfo, GetLastError())
                                }
                            }
                        }
                    }
                }
            }

            guard created else {
                if windowsError == ERROR_FILE_NOT_FOUND || windowsError == ERROR_PATH_NOT_FOUND {
                    // This execution path is not it. Try the next one
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
                    throw SubprocessError(
                        code: .init(.failedToChangeWorkingDirectory(self.workingDirectory?.string ?? "")),
                        underlyingError: SubprocessError.WindowsError(rawValue: windowsError)
                    )
                }

                throw SubprocessError(
                    code: .init(.spawnFailed),
                    underlyingError: SubprocessError.WindowsError(rawValue: windowsError)
                )
            }

            let pid = ProcessIdentifier(
                value: processInfo.dwProcessId,
                processDescriptor: processInfo.hProcess,
                threadHandle: processInfo.hThread
            )
            let execution = Execution(
                processIdentifier: pid
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
                execution: execution,
                inputWriteEnd: inputWriteFileDescriptor?.createIOChannel(),
                outputReadEnd: outputReadFileDescriptor?.createIOChannel(),
                errorReadEnd: errorReadFileDescriptor?.createIOChannel()
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
        throw SubprocessError(
            code: .init(.executableNotFound(self.executable.description)),
            underlyingError: SubprocessError.WindowsError(rawValue: DWORD(ERROR_FILE_NOT_FOUND))
        )
    }

    internal func spawnAsUser(
        withInput inputPipe: consuming CreatedPipe,
        outputPipe: consuming CreatedPipe,
        errorPipe: consuming CreatedPipe,
        userCredentials: PlatformOptions.UserCredentials
    ) async throws(SubprocessError) -> SpawnResult {
        var inputPipeBox: CreatedPipe? = consume inputPipe
        var outputPipeBox: CreatedPipe? = consume outputPipe
        var errorPipeBox: CreatedPipe? = consume errorPipe

        var _inputPipe = inputPipeBox.take()!
        var _outputPipe = outputPipeBox.take()!
        var _errorPipe = errorPipeBox.take()!

        let inputReadFileDescriptor: IODescriptor? = _inputPipe.readFileDescriptor()
        let inputWriteFileDescriptor: IODescriptor? = _inputPipe.writeFileDescriptor()
        let outputReadFileDescriptor: IODescriptor? = _outputPipe.readFileDescriptor()
        let outputWriteFileDescriptor: IODescriptor? = _outputPipe.writeFileDescriptor()
        let errorReadFileDescriptor: IODescriptor? = _errorPipe.readFileDescriptor()
        let errorWriteFileDescriptor: IODescriptor? = _errorPipe.writeFileDescriptor()

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
            let (
                applicationName,
                commandAndArgs,
                environment,
                intendedWorkingDir
            ): (String?, String, String, String?)
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

            let (created, processInfo, windowsError) = try await self.withStartupInfoEx(
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

                let spawnContext = SpawnContext(
                    startupInfo: startupInfo,
                    createProcessFlags: createProcessFlags
                )
                // Spawn (featuring pyramid!)
                return try await runOnBackgroundThread { () throws(SubprocessError) in
                    return try userCredentials.username._withCString(
                        encodedAs: UTF16.self
                    ) { usernameW throws(SubprocessError) in
                        try userCredentials.password._withCString(
                            encodedAs: UTF16.self
                        ) { passwordW throws(SubprocessError) in
                            try userCredentials.domain.withOptionalCString(
                                encodedAs: UTF16.self
                            ) { domainW throws(SubprocessError) in
                                try applicationName.withOptionalNTPathRepresentation { applicationNameW throws(SubprocessError) in
                                    try commandAndArgs._withCString(
                                        encodedAs: UTF16.self
                                    ) { commandAndArgsW throws(SubprocessError) in
                                        try environment._withCString(
                                            encodedAs: UTF16.self
                                        ) { environmentW throws(SubprocessError) in
                                            try intendedWorkingDir.withOptionalNTPathRepresentation { intendedWorkingDirW throws(SubprocessError) in
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
                                                return (created, processInfo, GetLastError())
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
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
                    throw SubprocessError(
                        code: .init(.failedToChangeWorkingDirectory(self.workingDirectory?.string ?? "")),
                        underlyingError: SubprocessError.WindowsError(rawValue: windowsError)
                    )
                }

                throw SubprocessError(
                    code: .init(.spawnFailed),
                    underlyingError: SubprocessError.WindowsError(rawValue: windowsError)
                )
            }

            let pid = ProcessIdentifier(
                value: processInfo.dwProcessId,
                processDescriptor: processInfo.hProcess,
                threadHandle: processInfo.hThread
            )
            let execution = Execution(
                processIdentifier: pid
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
                execution: execution,
                inputWriteEnd: inputWriteFileDescriptor?.createIOChannel(),
                outputReadEnd: outputReadFileDescriptor?.createIOChannel(),
                errorReadEnd: errorReadFileDescriptor?.createIOChannel()
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
        throw SubprocessError(
            code: .init(.executableNotFound(self.executable.description)),
            underlyingError: SubprocessError.WindowsError(rawValue: DWORD(ERROR_FILE_NOT_FOUND))
        )
    }
}

// MARK: - Platform Specific Options

/// The collection of platform-specific settings
/// to configure the subprocess when running
public struct PlatformOptions: Sendable {
    /// A `UserCredentials` to use spawning the subprocess
    /// as a different user
    public struct UserCredentials: Sendable, Hashable {
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

    /// `ConsoleBehavior` defines how should the console appear
    /// when spawning a new process
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

    /// `WindowStyle` defines how should the window appear
    /// when spawning a new process
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

        /// Activates and displays a window of normal size
        public static let normal: Self = .init(.normal)
        /// Does not activate a new window
        public static let hidden: Self = .init(.hidden)
        /// Activates the window and displays it as a maximized window.
        public static let maximized: Self = .init(.maximized)
        /// Activates the window and displays it as a minimized window.
        public static let minimized: Self = .init(.minimized)
    }

    /// Sets user credentials when starting the process as another user
    public var userCredentials: UserCredentials? = nil
    /// The console behavior of the new process,
    /// default to inheriting the console from parent process
    public var consoleBehavior: ConsoleBehavior = .inherit
    /// Window style to use when the process is started
    public var windowStyle: WindowStyle = .normal
    /// Whether to create a new process group for the new
    /// process. The process group includes all processes
    /// that are descendants of this root process.
    /// The process identifier of the new process group
    /// is the same as the process identifier.
    public var createProcessGroup: Bool = false
    /// An ordered list of steps in order to tear down the child
    /// process in case the parent task is cancelled before
    /// the child process terminates.
    /// Always ends in forcefully terminate at the end.
    public var teardownSequence: [TeardownStep] = []
    /// A closure to configure platform-specific
    /// spawning constructs. This closure enables direct
    /// configuration or override of underlying platform-specific
    /// spawn settings that `Subprocess` utilizes internally,
    /// in cases where Subprocess does not provide higher-level
    /// APIs for such modifications.
    ///
    /// On Windows, Subprocess uses `CreateProcessW()` as the
    /// underlying spawning mechanism. This closure allows
    /// modification of the `dwCreationFlags` creation flag
    /// and startup info `STARTUPINFOW` before
    /// they are sent to `CreateProcessW()`.
    public var preSpawnProcessConfigurator:
        (
            @Sendable
            (
                inout DWORD,
                inout STARTUPINFOW
            ) throws(SubprocessError) -> Void
        )? = nil

    /// Create platform options with the default values.
    public init() {}
}

extension PlatformOptions: CustomStringConvertible, CustomDebugStringConvertible {
    internal func description(withIndent indent: Int) -> String {
        let indent = String(repeating: " ", count: indent * 4)
        return """
            PlatformOptions(
            \(indent)    userCredentials: \(String(describing: self.userCredentials)),
            \(indent)    consoleBehavior: \(String(describing: self.consoleBehavior)),
            \(indent)    windowStyle: \(String(describing: self.windowStyle)),
            \(indent)    createProcessGroup: \(self.createProcessGroup),
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
internal func monitorProcessTermination(
    for processIdentifier: ProcessIdentifier
) async throws(SubprocessError) -> TerminationStatus {
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
                continuation.resume(
                    throwing: SubprocessError(
                        code: .init(.failedToMonitorProcess),
                        underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
                    )
                )
                return
            }
        }
    }

    var status: DWORD = 0
    guard GetExitCodeProcess(processIdentifier.processDescriptor, &status) else {
        // The child process terminated but we couldn't get its status back.
        // Assume generic failure.
        return .exited(1)
    }
    let exitCodeValue = CInt(bitPattern: .init(status))
    guard exitCodeValue >= 0 else {
        return .unhandledException(status)
    }
    return .exited(status)
}

// MARK: - Subprocess Control

extension Execution {
    /// Terminate the current subprocess with the given exit code
    /// - Parameter exitCode: The exit code to use for the subprocess.
    public func terminate(withExitCode exitCode: DWORD) throws(SubprocessError) {
        guard TerminateProcess(self.processIdentifier.processDescriptor, exitCode) else {
            throw SubprocessError(
                code: .init(.failedToTerminate),
                underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
            )
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
            throw SubprocessError(
                code: .init(.failedToSuspend),
                underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
            )
        }
        guard NTSuspendProcess(self.processIdentifier.processDescriptor) >= 0 else {
            throw SubprocessError(
                code: .init(.failedToSuspend),
                underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
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
            throw SubprocessError(
                code: .init(.failedToResume),
                underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
            )
        }
        guard NTResumeProcess(self.processIdentifier.processDescriptor) >= 0 else {
            throw SubprocessError(
                code: .init(.failedToResume),
                underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
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
                        throw SubprocessError(
                            code: .init(.executableNotFound(executableName)),
                            underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
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
                initialSize: directorySize >= 0 ? directorySize : DWORD(MAX_PATH),
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
                initialSize: systemDirectorySize >= 0 ? systemDirectorySize : DWORD(MAX_PATH),
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
                initialSize: windowsDirectorySize >= 0 ? windowsDirectorySize : DWORD(MAX_PATH),
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
    /// Windows specific process identifier value
    public let value: DWORD
    /// Process handle for current execution.
    public nonisolated(unsafe) let processDescriptor: HANDLE
    /// Main thread handle for current execution.
    public nonisolated(unsafe) let threadHandle: HANDLE

    internal init(value: DWORD, processDescriptor: HANDLE, threadHandle: HANDLE) {
        self.value = value
        self.processDescriptor = processDescriptor
        self.threadHandle = threadHandle
    }

    internal func close() {
        guard CloseHandle(self.threadHandle) else {
            fatalError("Failed to close thread HANDLE: \(SubprocessError.WindowsError(rawValue: GetLastError()))")
        }
        guard CloseHandle(self.processDescriptor) else {
            fatalError("Failed to close process HANDLE: \(SubprocessError.WindowsError(rawValue: GetLastError()))")
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
        // Omit applicationName (and therefore rely on commandAndArgs
        // for executable path) if we don't need to override arg0
        return (
            applicationName: self.arguments.executablePathOverride == nil ? nil : applicationName,
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
            throw SubprocessError(
                code: .init(.spawnFailed),
                underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
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
        var args = self.arguments.storage.map {
            guard case .string(let stringValue) = $0 else {
                // We should never get here since the API
                // is guarded off
                fatalError("Windows does not support non unicode String as arguments")
            }
            return stringValue
        }

        if case .string(let overrideName) = self.arguments.executablePathOverride {
            // Use the override as argument0 and set applicationName
            args.insert(overrideName, at: 0)
        } else {
            // Set argument[0] to be executableNameOrPath
            args.insert(executablePath, at: 0)
        }
        return (
            applicationName: executablePath,
            commandAndArgs: self.quoteWindowsCommandLine(args)
        )
    }

    // Taken from SCF
    private func quoteWindowsCommandLine(_ commandLine: [String]) -> String {
        func quoteWindowsCommandArg(arg: String) -> String {
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
        return commandLine.map(quoteWindowsCommandArg).joined(separator: " ")
    }

    private static func pathAccessible(_ path: String) -> Bool {
        return path.withCString(encodedAs: UTF16.self) {
            let attrs = GetFileAttributesW($0)
            return attrs != INVALID_FILE_ATTRIBUTES
        }
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
        var saAttributes: SECURITY_ATTRIBUTES = SECURITY_ATTRIBUTES()
        saAttributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        saAttributes.bInheritHandle = true
        saAttributes.lpSecurityDescriptor = nil

        var readHandle: HANDLE? = nil
        var writeHandle: HANDLE? = nil
        guard CreatePipe(&readHandle, &writeHandle, &saAttributes, 0),
            readHandle != INVALID_HANDLE_VALUE,
            writeHandle != INVALID_HANDLE_VALUE,
            let readHandle: HANDLE = readHandle,
            let writeHandle: HANDLE = writeHandle
        else {
            throw SubprocessError(
                code: .init(.failedToCreatePipe),
                underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
            )
        }
        let readFd = _open_osfhandle(
            intptr_t(bitPattern: readHandle),
            FileDescriptor.AccessMode.readOnly.rawValue
        )
        let writeFd = _open_osfhandle(
            intptr_t(bitPattern: writeHandle),
            FileDescriptor.AccessMode.writeOnly.rawValue
        )

        return (
            readEnd: FileDescriptor(rawValue: readFd),
            writeEnd: FileDescriptor(rawValue: writeFd)
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
            throw SubprocessError(
                code: .init(.invalidWindowsPath(self)),
                underlyingError: nil
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
                        throw SubprocessError(
                            code: .init(.invalidWindowsPath(self)),
                            underlyingError: SubprocessError.WindowsError(rawValue: GetLastError())
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
                    throw SubprocessError(
                        code: .init(.invalidWindowsPath(self)),
                        underlyingError: SubprocessError.WindowsError(rawValue: WIN32_FROM_HRESULT(result))
                    )
                }
            }
        }
    }

    internal func hasExtension() -> Bool {
        let components = self.split(separator: ".")
        return components.count > 1 && components.last?.count == 3
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
                        throw SubprocessError.WindowsError(rawValue: GetLastError())
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
            throw error as! SubprocessError.WindowsError
        }
    }
    throw SubprocessError.WindowsError(rawValue: DWORD(ERROR_INSUFFICIENT_BUFFER))
}

#endif // canImport(WinSDK)
