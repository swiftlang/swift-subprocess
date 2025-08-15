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

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
@preconcurrency import WinSDK
#endif

internal import Dispatch

import Synchronization

/// A collection of configurations parameters to use when
/// spawning a subprocess.
public struct Configuration: Sendable {
    /// The executable to run.
    public var executable: Executable
    /// The arguments to pass to the executable.
    public var arguments: Arguments
    /// The environment to use when running the executable.
    public var environment: Environment
    /// The working directory to use when running the executable.
    /// If this property is `nil`, the subprocess will inherit the working directory from the parent process.
    public var workingDirectory: FilePath?
    /// The platform specific options to use when
    /// running the subprocess.
    public var platformOptions: PlatformOptions

    public init(
        executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions()
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.platformOptions = platformOptions
    }

    internal func run<Result>(
        input: consuming CreatedPipe,
        output: consuming CreatedPipe,
        error: consuming CreatedPipe,
        isolation: isolated (any Actor)? = #isolation,
        _ body: ((Execution, consuming IOChannel?, consuming IOChannel?, consuming IOChannel?) async throws -> Result)
    ) async throws -> ExecutionResult<Result> {
        let spawnResults = try self.spawn(
            withInput: input,
            outputPipe: output,
            errorPipe: error
        )

        var spawnResultBox: SpawnResult?? = consume spawnResults
        var _spawnResult = spawnResultBox!.take()!

        let execution = _spawnResult.execution

        let result: Swift.Result<Result, Error>
        do {
            result = try await .success(withAsyncTaskCleanupHandler {
                let inputIO = _spawnResult.inputWriteEnd()
                let outputIO = _spawnResult.outputReadEnd()
                let errorIO = _spawnResult.errorReadEnd()

                // Body runs in the same isolation
                return try await body(_spawnResult.execution, inputIO, outputIO, errorIO)
            } onCleanup: {
                // Attempt to terminate the child process
                await execution.runTeardownSequence(
                    self.platformOptions.teardownSequence
                )
            })
        } catch {
            result = .failure(error)
        }

        // Ensure that we begin monitoring process termination after `body` runs
        // and regardless of whether `body` throws, so that the pid gets reaped
        // even if `body` throws, and we are not leaving zombie processes in the
        // process table which will cause the process termination monitoring thread
        // to effectively hang due to the pid never being awaited
        let terminationStatus = try await Subprocess.monitorProcessTermination(
            for: execution.processIdentifier
        )

        // Close process file descriptor now we finished monitoring
        execution.processIdentifier.close()

        return try ExecutionResult(terminationStatus: terminationStatus, value: result.get())
    }
}

extension Configuration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return """
            Configuration(
                executable: \(self.executable.description),
                arguments: \(self.arguments.description),
                environment: \(self.environment.description),
                workingDirectory: \(self.workingDirectory?.string ?? ""),
                platformOptions: \(self.platformOptions.description(withIndent: 1))
            )
            """
    }

    public var debugDescription: String {
        return """
            Configuration(
                executable: \(self.executable.debugDescription),
                arguments: \(self.arguments.debugDescription),
                environment: \(self.environment.debugDescription),
                workingDirectory: \(self.workingDirectory?.string ?? ""),
                platformOptions: \(self.platformOptions.description(withIndent: 1))
            )
            """
    }

}

// MARK: - Cleanup
extension Configuration {
    /// Close each input individually, and throw the first error if there's multiple errors thrown
    @Sendable
    internal func safelyCloseMultiple(
        inputRead: consuming IODescriptor?,
        inputWrite: consuming IODescriptor?,
        outputRead: consuming IODescriptor?,
        outputWrite: consuming IODescriptor?,
        errorRead: consuming IODescriptor?,
        errorWrite: consuming IODescriptor?
    ) throws {
        var possibleError: (any Swift.Error)? = nil

        do {
            try inputRead?.safelyClose()
        } catch {
            possibleError = error
        }
        do {
            try inputWrite?.safelyClose()
        } catch {
            possibleError = error
        }
        do {
            try outputRead?.safelyClose()
        } catch {
            possibleError = error
        }
        do {
            try outputWrite?.safelyClose()
        } catch {
            possibleError = error
        }
        do {
            try errorRead?.safelyClose()
        } catch {
            possibleError = error
        }
        do {
            try errorWrite?.safelyClose()
        } catch {
            possibleError = error
        }

        if let actualError = possibleError {
            throw actualError
        }
    }
}

// MARK: - Executable

/// `Executable` defines how the executable should
/// be looked up for execution.
public struct Executable: Sendable, Hashable {
    internal enum Storage: Sendable, Hashable {
        case executable(String)
        case path(FilePath)
    }

    internal let storage: Storage

    private init(_config: Storage) {
        self.storage = _config
    }

    /// Locate the executable by its name.
    /// `Subprocess` will use `PATH` value to
    /// determine the full path to the executable.
    public static func name(_ executableName: String) -> Self {
        return .init(_config: .executable(executableName))
    }
    /// Locate the executable by its full path.
    /// `Subprocess` will use this path directly.
    public static func path(_ filePath: FilePath) -> Self {
        return .init(_config: .path(filePath))
    }
    /// Returns the full executable path given the environment value.
    public func resolveExecutablePath(in environment: Environment) throws -> FilePath {
        let path = try self.resolveExecutablePath(withPathValue: environment.pathValue())
        return FilePath(path)
    }
}

extension Executable: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch storage {
        case .executable(let executableName):
            return executableName
        case .path(let filePath):
            return filePath.string
        }
    }

    public var debugDescription: String {
        switch storage {
        case .executable(let string):
            return "executable(\(string))"
        case .path(let filePath):
            return "path(\(filePath.string))"
        }
    }
}

extension Executable {
    internal func possibleExecutablePaths(
        withPathValue pathValue: String?
    ) -> Set<String> {
        switch self.storage {
        case .executable(let executableName):
            #if os(Windows)
            // Windows CreateProcessW accepts executable name directly
            return Set([executableName])
            #else
            var results: Set<String> = []
            // executableName could be a full path
            results.insert(executableName)
            // Get $PATH from environment
            let searchPaths: Set<String>
            if let pathValue = pathValue {
                let localSearchPaths = pathValue.split(separator: ":").map { String($0) }
                searchPaths = Set(localSearchPaths).union(Self.defaultSearchPaths)
            } else {
                searchPaths = Self.defaultSearchPaths
            }
            for path in searchPaths {
                results.insert(
                    FilePath(path).appending(executableName).string
                )
            }
            return results
            #endif
        case .path(let executablePath):
            return Set([executablePath.string])
        }
    }
}

// MARK: - Arguments

/// A collection of arguments to pass to the subprocess.
public struct Arguments: Sendable, ExpressibleByArrayLiteral, Hashable {
    public typealias ArrayLiteralElement = String

    internal let storage: [StringOrRawBytes]
    internal let executablePathOverride: StringOrRawBytes?

    /// Create an Arguments object using the given literal values
    public init(arrayLiteral elements: String...) {
        self.storage = elements.map { .string($0) }
        self.executablePathOverride = nil
    }
    /// Create an Arguments object using the given array
    public init(_ array: [String]) {
        self.storage = array.map { .string($0) }
        self.executablePathOverride = nil
    }

    #if !os(Windows)  // Windows does NOT support arg0 override
    /// Create an `Argument` object using the given values, but
    /// override the first Argument value to `executablePathOverride`.
    /// If `executablePathOverride` is nil,
    /// `Arguments` will automatically use the executable path
    /// as the first argument.
    /// - Parameters:
    ///   - executablePathOverride: the value to override the first argument.
    ///   - remainingValues: the rest of the argument value
    public init(executablePathOverride: String?, remainingValues: [String]) {
        self.storage = remainingValues.map { .string($0) }
        if let executablePathOverride = executablePathOverride {
            self.executablePathOverride = .string(executablePathOverride)
        } else {
            self.executablePathOverride = nil
        }
    }

    /// Create an `Argument` object using the given values, but
    /// override the first Argument value to `executablePathOverride`.
    /// If `executablePathOverride` is nil,
    /// `Arguments` will automatically use the executable path
    /// as the first argument.
    /// - Parameters:
    ///   - executablePathOverride: the value to override the first argument.
    ///   - remainingValues: the rest of the argument value
    public init(executablePathOverride: [UInt8]?, remainingValues: [[UInt8]]) {
        self.storage = remainingValues.map { .rawBytes($0) }
        if let override = executablePathOverride {
            self.executablePathOverride = .rawBytes(override)
        } else {
            self.executablePathOverride = nil
        }
    }

    public init(_ array: [[UInt8]]) {
        self.storage = array.map { .rawBytes($0) }
        self.executablePathOverride = nil
    }
    #endif
}

extension Arguments: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        var result: [String] = self.storage.map(\.description)

        if let override = self.executablePathOverride {
            result.insert("override\(override.description)", at: 0)
        }
        return result.description
    }

    public var debugDescription: String { return self.description }
}

// MARK: - Environment

/// A set of environment variables to use when executing the subprocess.
public struct Environment: Sendable, Hashable {
    internal enum Configuration: Sendable, Hashable {
        case inherit([String: String])
        case custom([String: String])
        #if !os(Windows)
        case rawBytes([[UInt8]])
        #endif
    }

    internal let config: Configuration

    init(config: Configuration) {
        self.config = config
    }
    /// Child process should inherit the same environment
    /// values from its parent process.
    public static var inherit: Self {
        return .init(config: .inherit([:]))
    }
    /// Override the provided `newValue` in the existing `Environment`
    public func updating(_ newValue: [String: String]) -> Self {
        return .init(config: .inherit(newValue))
    }
    /// Use custom environment variables
    public static func custom(_ newValue: [String: String]) -> Self {
        return .init(config: .custom(newValue))
    }

    #if !os(Windows)
    /// Use custom environment variables of raw bytes
    public static func custom(_ newValue: [[UInt8]]) -> Self {
        return .init(config: .rawBytes(newValue))
    }
    #endif
}

extension Environment: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self.config {
        case .custom(let customDictionary):
            return """
                Custom environment:
                \(customDictionary)
                """
        case .inherit(let updateValue):
            return """
                Inheriting current environment with updates:
                \(updateValue)
                """
        #if !os(Windows)
        case .rawBytes(let rawBytes):
            return """
                Raw bytes:
                \(rawBytes)
                """
        #endif
        }
    }

    public var debugDescription: String {
        return self.description
    }

    internal static func currentEnvironmentValues() -> [String: String] {
        return self.withCopiedEnv { environments in
            var results: [String: String] = [:]
            for env in environments {
                let environmentString = String(cString: env)

                #if os(Windows)
                // Windows GetEnvironmentStringsW API can return
                // magic environment variables set by the cmd shell
                // that starts with `=`
                // We should exclude these values
                if environmentString.utf8.first == Character("=").utf8.first {
                    continue
                }
                #endif  // os(Windows)

                guard let delimiter = environmentString.firstIndex(of: "=") else {
                    continue
                }

                let key = String(environmentString[environmentString.startIndex..<delimiter])
                let value = String(
                    environmentString[environmentString.index(after: delimiter)..<environmentString.endIndex]
                )
                results[key] = value
            }
            return results
        }
    }
}

// MARK: - TerminationStatus

/// An exit status of a subprocess.
@frozen
public enum TerminationStatus: Sendable, Hashable {
    #if canImport(WinSDK)
    public typealias Code = DWORD
    #else
    public typealias Code = CInt
    #endif

    /// The subprocess was existed with the given code
    case exited(Code)
    /// The subprocess was signaled with given exception value
    case unhandledException(Code)
    /// Whether the current TerminationStatus is successful.
    public var isSuccess: Bool {
        switch self {
        case .exited(let exitCode):
            return exitCode == 0
        case .unhandledException(_):
            return false
        }
    }
}

extension TerminationStatus: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .exited(let code):
            return "exited(\(code))"
        case .unhandledException(let code):
            return "unhandledException(\(code))"
        }
    }

    public var debugDescription: String {
        return self.description
    }
}

// MARK: - Internal

extension Configuration {
    /// After Spawn finishes, child side file descriptors
    /// (input read, output write, error write) will be closed
    /// by `spawn()`. It returns the parent side file descriptors
    /// via `SpawnResult` to perform actual reads
    internal struct SpawnResult: ~Copyable {
        let execution: Execution
        var _inputWriteEnd: IOChannel?
        var _outputReadEnd: IOChannel?
        var _errorReadEnd: IOChannel?

        init(
            execution: Execution,
            inputWriteEnd: consuming IOChannel?,
            outputReadEnd: consuming IOChannel?,
            errorReadEnd: consuming IOChannel?
        ) {
            self.execution = execution
            self._inputWriteEnd = consume inputWriteEnd
            self._outputReadEnd = consume outputReadEnd
            self._errorReadEnd = consume errorReadEnd
        }

        mutating func inputWriteEnd() -> IOChannel? {
            return self._inputWriteEnd.take()
        }

        mutating func outputReadEnd() -> IOChannel? {
            return self._outputReadEnd.take()
        }

        mutating func errorReadEnd() -> IOChannel? {
            return self._errorReadEnd.take()
        }
    }
}

internal enum StringOrRawBytes: Sendable, Hashable {
    case string(String)
    case rawBytes([UInt8])

    // Return value needs to be deallocated manually by callee
    func createRawBytes() -> UnsafeMutablePointer<CChar> {
        switch self {
        case .string(let string):
#if os(Windows)
            return _strdup(string)
#else
            return strdup(string)
#endif
        case .rawBytes(let rawBytes):
#if os(Windows)
            return _strdup(rawBytes)
#else
            return strdup(rawBytes)
#endif
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let string):
            return string
        case .rawBytes(let rawBytes):
            return String(decoding: rawBytes, as: UTF8.self)
        }
    }

    var description: String {
        switch self {
        case .string(let string):
            return string
        case .rawBytes(let bytes):
            return bytes.description
        }
    }

    var count: Int {
        switch self {
        case .string(let string):
            return string.count
        case .rawBytes(let rawBytes):
            return strnlen(rawBytes, Int.max)
        }
    }

    func hash(into hasher: inout Hasher) {
        // If Raw bytes is valid UTF8, hash it as so
        switch self {
        case .string(let string):
            hasher.combine(string)
        case .rawBytes(let bytes):
            if let stringValue = self.stringValue {
                hasher.combine(stringValue)
            } else {
                hasher.combine(bytes)
            }
        }
    }
}

internal enum _CloseTarget {
    #if canImport(WinSDK)
    case handle(HANDLE)
    #endif
    case fileDescriptor(FileDescriptor)
    case dispatchIO(DispatchIO)
}

internal func _safelyClose(_ target: _CloseTarget) throws {
    switch target {
    #if canImport(WinSDK)
    case .handle(let handle):
        /// Windows does not provide a “deregistration” API (the reverse of
        /// `CreateIoCompletionPort`) for handles and it reuses HANDLE
        /// values once they are closed. Since we rely on the handle value
        /// as the completion key for `CreateIoCompletionPort`, we should
        /// remove the registration when the handle is closed to allow
        /// new registration to proceed if the handle is reused.
        AsyncIO.shared.removeRegistration(for: handle)
        guard CloseHandle(handle) else {
            let error = GetLastError()
            // Getting `ERROR_INVALID_HANDLE` suggests that the file descriptor
            // might have been closed unexpectedly. This can pose security risks
            // if another part of the code inadvertently reuses the same HANDLE.
            // We use `fatalError` upon receiving `ERROR_INVALID_HANDLE`
            // to prevent accidentally closing a different HANDLE.
            guard error != ERROR_INVALID_HANDLE else {
                fatalError(
                    "HANDLE \(handle) is already closed"
                )
            }
            let subprocessError = SubprocessError(
                code: .init(.asyncIOFailed("Failed to close HANDLE")),
                underlyingError: .init(rawValue: error)
            )
            throw subprocessError
        }
    #endif
    case .fileDescriptor(let fileDescriptor):
        do {
            try fileDescriptor.close()
        } catch {
            guard let errno: Errno = error as? Errno else {
                throw error
            }
            // Getting `.badFileDescriptor` suggests that the file descriptor
            // might have been closed unexpectedly. This can pose security risks
            // if another part of the code inadvertently reuses the same file descriptor
            // number. This problem is especially concerning on Unix systems due to POSIX’s
            // guarantee of using the lowest available file descriptor number, making reuse
            // more probable. We use `fatalError` upon receiving `.badFileDescriptor`
            // to prevent accidentally closing a different file descriptor.
            guard errno != .badFileDescriptor else {
                fatalError(
                    "FileDescriptor \(fileDescriptor.rawValue) is already closed"
                )
            }
            // Throw other kinds of errors to allow user to catch them
            throw error
        }
    case .dispatchIO(let dispatchIO):
        dispatchIO.close()
    }
}

/// `IODescriptor` wraps platform-specific `FileDescriptor`,
/// which is used to establish a connection to the standard input/output (IO)
/// system during the process of spawning a child process. Unlike `IODescriptor`,
/// the `IODescriptor` does not support data read/write operations;
/// its primary function is to facilitate the spawning of child processes
/// by providing a platform-specific file descriptor.
internal struct IODescriptor: ~Copyable {
    #if canImport(WinSDK)
    typealias Descriptor = HANDLE
    #else
    typealias Descriptor = FileDescriptor
    #endif

    internal var closeWhenDone: Bool
    internal let descriptor: Descriptor

    internal init(
        _ descriptor: Descriptor,
        closeWhenDone: Bool
    ) {
        self.descriptor = descriptor
        self.closeWhenDone = closeWhenDone
    }

    consuming func createIOChannel() -> IOChannel {
        let shouldClose = self.closeWhenDone
        self.closeWhenDone = false
        #if canImport(Darwin)
        // Transferring out the ownership of fileDescriptor means we don't have go close here
        let closeFd = self.descriptor
        let dispatchIO: DispatchIO = DispatchIO(
            type: .stream,
            fileDescriptor: self.platformDescriptor(),
            queue: .global(),
            cleanupHandler: { @Sendable error in
                // Close the file descriptor
                if shouldClose {
                    try? closeFd.close()
                }
            }
        )
        return IOChannel(dispatchIO, closeWhenDone: shouldClose)
        #else
        return IOChannel(self.descriptor, closeWhenDone: shouldClose)
        #endif
    }

    internal mutating func safelyClose() throws {
        guard self.closeWhenDone else {
            return
        }
        closeWhenDone = false

        #if canImport(WinSDK)
        try _safelyClose(.handle(self.descriptor))
        #else
        try _safelyClose(.fileDescriptor(self.descriptor))
        #endif
    }

    deinit {
        guard self.closeWhenDone else {
            return
        }

        fatalError("FileDescriptor \(self.descriptor) was not closed")
    }

    internal func platformDescriptor() -> PlatformFileDescriptor {
        #if canImport(WinSDK)
        return self.descriptor
        #else
        return self.descriptor.platformDescriptor
        #endif
    }
}

internal struct IOChannel: ~Copyable, @unchecked Sendable {
    #if canImport(WinSDK)
    typealias Channel = HANDLE
    #elseif canImport(Darwin)
    typealias Channel = DispatchIO
    #else
    typealias Channel = FileDescriptor
    #endif

    internal var closeWhenDone: Bool
    internal let channel: Channel

    internal init(
        _ channel: Channel,
        closeWhenDone: Bool
    ) {
        self.channel = channel
        self.closeWhenDone = closeWhenDone
    }

    internal mutating func safelyClose() throws {
        guard self.closeWhenDone else {
            return
        }
        closeWhenDone = false

        #if canImport(WinSDK)
        try _safelyClose(.handle(self.channel))
        #elseif canImport(Darwin)
        try _safelyClose(.dispatchIO(self.channel))
        #else
        try _safelyClose(.fileDescriptor(self.channel))
        #endif
    }

    internal consuming func consumeIOChannel() -> Channel {
        let result = self.channel
        // Transfer the ownership out and therefor
        // don't perform close on deinit
        self.closeWhenDone = false
        return result
    }
}

#if canImport(WinSDK)
internal enum PipeNameCounter {
    private static let value = Atomic<UInt64>(0)

    internal static func nextValue() -> UInt64 {
        return self.value.add(1, ordering: .relaxed).newValue
    }
}
#endif

internal struct CreatedPipe: ~Copyable {
    internal enum Purpose: CustomStringConvertible {
        /// This pipe is used for standard input. This option maps to
        /// `PIPE_ACCESS_OUTBOUND` on Windows where child only reads,
        /// parent only writes.
        case input
        /// This pipe is used for standard output and standard error.
        /// This option maps to `PIPE_ACCESS_INBOUND` on Windows where
        /// child only writes, parent only reads.
        case output

        var description: String {
            switch self {
            case .input:
                return "input"
            case .output:
                return "output"
            }
        }
    }

    internal var _readFileDescriptor: IODescriptor?
    internal var _writeFileDescriptor: IODescriptor?

    internal init(
        readFileDescriptor: consuming IODescriptor?,
        writeFileDescriptor: consuming IODescriptor?
    ) {
        self._readFileDescriptor = readFileDescriptor
        self._writeFileDescriptor = writeFileDescriptor
    }

    mutating func readFileDescriptor() -> IODescriptor? {
        return self._readFileDescriptor.take()
    }

    mutating func writeFileDescriptor() -> IODescriptor? {
        return self._writeFileDescriptor.take()
    }

    internal init(closeWhenDone: Bool, purpose: Purpose) throws {
        #if canImport(WinSDK)
        /// On Windows, we need to create a named pipe.
        /// According to Microsoft documentation:
        /// > Asynchronous (overlapped) read and write operations are
        /// > not supported by anonymous pipes.
        /// See https://learn.microsoft.com/en-us/windows/win32/ipc/anonymous-pipe-operations
        while true {
            /// Windows named pipes are system wide. To avoid creating two pipes with the same
            /// name, create the pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE` such that it will
            /// return error `ERROR_ACCESS_DENIED` if we try to create another pipe with the same name.
            let pipeName = "\\\\.\\pipe\\LOCAL\\subprocess-\(purpose)-\(PipeNameCounter.nextValue())"
            var saAttributes: SECURITY_ATTRIBUTES = SECURITY_ATTRIBUTES()
            saAttributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
            saAttributes.bInheritHandle = true
            saAttributes.lpSecurityDescriptor = nil

            let parentEnd = pipeName.withCString(
                encodedAs: UTF16.self
            ) { pipeNameW in
                // Use OVERLAPPED for async IO
                var openMode: DWORD = DWORD(FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE)
                switch purpose {
                case .input:
                    openMode |= DWORD(PIPE_ACCESS_OUTBOUND)
                case .output:
                    openMode |= DWORD(PIPE_ACCESS_INBOUND)
                }

                return CreateNamedPipeW(
                    pipeNameW,
                    openMode,
                    DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS),
                    1, // Max instance,
                    DWORD(readBufferSize),
                    DWORD(readBufferSize),
                    0,
                    &saAttributes
                )
            }
            guard let parentEnd, parentEnd != INVALID_HANDLE_VALUE else {
                // Since we created the pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE`,
                // if there's already a pipe with the same name, GetLastError()
                // will be set to ERROR_ACCESS_DENIED. In this case,
                // try again with a different name.
                let errorCode = GetLastError()
                guard errorCode != ERROR_ACCESS_DENIED else {
                    continue
                }
                // Throw all other errors
                throw SubprocessError(
                    code: .init(.asyncIOFailed("CreateNamedPipeW failed")),
                    underlyingError: .init(rawValue: GetLastError())
                )
            }

            let childEnd = pipeName.withCString(
                encodedAs: UTF16.self
            ) { pipeNameW in
                var targetAccess: DWORD = 0
                switch purpose {
                case .input:
                    targetAccess = DWORD(GENERIC_READ)
                case .output:
                    targetAccess = DWORD(GENERIC_WRITE)
                }

                return CreateFileW(
                    pipeNameW,
                    targetAccess,
                    0,
                    &saAttributes,
                    DWORD(OPEN_EXISTING),
                    DWORD(FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED),
                    nil
                )
            }
            guard let childEnd, childEnd != INVALID_HANDLE_VALUE else {
                throw SubprocessError(
                    code: .init(.asyncIOFailed("CreateFileW failed")),
                    underlyingError: .init(rawValue: GetLastError())
                )
            }
            switch purpose {
            case .input:
                self._readFileDescriptor = .init(childEnd, closeWhenDone: closeWhenDone)
                self._writeFileDescriptor = .init(parentEnd, closeWhenDone: closeWhenDone)
            case .output:
                self._readFileDescriptor = .init(parentEnd, closeWhenDone: closeWhenDone)
                self._writeFileDescriptor = .init(childEnd, closeWhenDone: closeWhenDone)
            }
            return
        }
        #else
        let pipe = try FileDescriptor.pipe()
        self._readFileDescriptor = .init(
            pipe.readEnd,
            closeWhenDone: closeWhenDone
        )
        self._writeFileDescriptor = .init(
            pipe.writeEnd,
            closeWhenDone: closeWhenDone
        )
        #endif
    }
}

extension Optional where Wrapped: Collection {
    func withOptionalUnsafeBufferPointer<Result>(
        _ body: ((UnsafeBufferPointer<Wrapped.Element>)?) throws -> Result
    ) rethrows -> Result {
        switch self {
        case .some(let wrapped):
            guard let array: [Wrapped.Element] = wrapped as? Array else {
                return try body(nil)
            }
            return try array.withUnsafeBufferPointer { ptr in
                return try body(ptr)
            }
        case .none:
            return try body(nil)
        }
    }
}

extension Optional where Wrapped == String {
    func withOptionalCString<Result>(
        _ body: ((UnsafePointer<Int8>)?) throws -> Result
    ) rethrows -> Result {
        switch self {
        case .none:
            return try body(nil)
        case .some(let wrapped):
            return try wrapped.withCString {
                return try body($0)
            }
        }
    }

    var stringValue: String {
        return self ?? "nil"
    }
}

/// Runs `body`, and then runs `onCleanup` if body throws an error, or if the parent task is cancelled. In the latter case, `onCleanup` may be run concurrently with `body`. `body` is guaranteed to run exactly once. `onCleanup` is guaranteed to run only once, or not at all.
internal func withAsyncTaskCleanupHandler<Result>(
    _ body: () async throws -> Result,
    onCleanup handler: @Sendable @escaping () async -> Void,
    isolation: isolated (any Actor)? = #isolation
) async rethrows -> Result {
    let (runCancellationHandlerStream, runCancellationHandlerContinuation) = AsyncThrowingStream.makeStream(of: Void.self)
    return try await withThrowingTaskGroup(
        of: Void.self,
        returning: Result.self
    ) { group in
        group.addTask {
            // Keep this task sleep indefinitely until the parent task is cancelled.
            // `Task.sleep` throws `CancellationError` when the task is canceled
            // before the time ends. We then run the cancel handler.
            do { while true { try await Task.sleep(nanoseconds: 1_000_000_000) } } catch {}
            // Run task cancel handler
            runCancellationHandlerContinuation.finish(throwing: CancellationError())
        }

        group.addTask {
            // Enumerate the async stream until it completes or throws an error.
            // Since we signal completion of the stream from cancellation or the
            // parent task or the body throwing, this ensures that we run the
            // cleanup handler exactly once in any failure scenario, and also do
            // so _immediately_ if the failure scenario is due to parent task
            // cancellation. We do so in a detached Task to prevent cancellation
            // of the parent task from interrupting enumeration of the stream itself.
            await withUncancelledTask {
                do {
                    var iterator = runCancellationHandlerStream.makeAsyncIterator()
                    while let _ = try await iterator.next() {
                    }
                } catch {
                    await handler()
                }
            }
        }

        defer {
            group.cancelAll()
        }

        do {
            let result = try await body()
            runCancellationHandlerContinuation.finish()
            return result
        } catch {
            runCancellationHandlerContinuation.finish(throwing: error)
            throw error
        }
    }
}
