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
import WinSDK
#endif

internal import Dispatch

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
        _ body: ((Execution, consuming TrackedPlatformDiskIO?, consuming TrackedPlatformDiskIO?, consuming TrackedPlatformDiskIO?) async throws -> Result)
    ) async throws -> ExecutionResult<Result> {
        let spawnResults = try self.spawn(
            withInput: input,
            outputPipe: output,
            errorPipe: error
        )
        let pid = spawnResults.execution.processIdentifier

        var spawnResultBox: SpawnResult?? = consume spawnResults

        return try await withAsyncTaskCleanupHandler {
            var _spawnResult = spawnResultBox!.take()!
            let inputIO = _spawnResult.inputWriteEnd()
            let outputIO = _spawnResult.outputReadEnd()
            let errorIO = _spawnResult.errorReadEnd()
            let processIdentifier = _spawnResult.execution.processIdentifier

            async let terminationStatus = try monitorProcessTermination(
                forProcessWithIdentifier: processIdentifier
            )
            // Body runs in the same isolation
            let result = try await body(_spawnResult.execution, inputIO, outputIO, errorIO)
            return ExecutionResult(
                terminationStatus: try await terminationStatus,
                value: result
            )
        } onCleanup: {
            // Attempt to terminate the child process
            await Execution.runTeardownSequence(
                self.platformOptions.teardownSequence,
                on: pid
            )
        }
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
        inputRead: consuming TrackedFileDescriptor?,
        inputWrite: consuming TrackedFileDescriptor?,
        outputRead: consuming TrackedFileDescriptor?,
        outputWrite: consuming TrackedFileDescriptor?,
        errorRead: consuming TrackedFileDescriptor?,
        errorWrite: consuming TrackedFileDescriptor?
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
public enum TerminationStatus: Sendable, Hashable, Codable {
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
        var _inputWriteEnd: TrackedPlatformDiskIO?
        var _outputReadEnd: TrackedPlatformDiskIO?
        var _errorReadEnd: TrackedPlatformDiskIO?

        init(
            execution: Execution,
            inputWriteEnd: consuming TrackedPlatformDiskIO?,
            outputReadEnd: consuming TrackedPlatformDiskIO?,
            errorReadEnd: consuming TrackedPlatformDiskIO?
        ) {
            self.execution = execution
            self._inputWriteEnd = consume inputWriteEnd
            self._outputReadEnd = consume outputReadEnd
            self._errorReadEnd = consume errorReadEnd
        }

        mutating func inputWriteEnd() -> TrackedPlatformDiskIO? {
            return self._inputWriteEnd.take()
        }

        mutating func outputReadEnd() -> TrackedPlatformDiskIO? {
            return self._outputReadEnd.take()
        }

        mutating func errorReadEnd() -> TrackedPlatformDiskIO? {
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
            return strdup(string)
        case .rawBytes(let rawBytes):
            return strdup(rawBytes)
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

/// A wrapped `FileDescriptor` and whether it should be closed
/// automatically when done.
internal struct TrackedFileDescriptor: ~Copyable {
    internal var closeWhenDone: Bool
    internal let fileDescriptor: FileDescriptor

    internal init(
        _ fileDescriptor: FileDescriptor,
        closeWhenDone: Bool
    ) {
        self.fileDescriptor = fileDescriptor
        self.closeWhenDone = closeWhenDone
    }

    #if os(Windows)
    consuming func consumeDiskIO() -> FileDescriptor {
        let result = self.fileDescriptor
        // Transfer the ownership out and therefor
        // don't perform close on deinit
        self.closeWhenDone = false
        return result
    }
    #endif

    internal mutating func safelyClose() throws {
        guard self.closeWhenDone else {
            return
        }
        closeWhenDone = false

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
    }

    deinit {
        guard self.closeWhenDone else {
            return
        }

        fatalError("FileDescriptor \(self.fileDescriptor.rawValue) was not closed")
    }

    internal func platformDescriptor() -> PlatformFileDescriptor {
        return self.fileDescriptor.platformDescriptor
    }
}

#if !os(Windows)
/// A wrapped `DispatchIO` and whether it should be closed
/// automatically when done.
internal struct TrackedDispatchIO: ~Copyable {
    internal var closeWhenDone: Bool
    internal var dispatchIO: DispatchIO

    internal init(
        _ dispatchIO: DispatchIO,
        closeWhenDone: Bool
    ) {
        self.dispatchIO = dispatchIO
        self.closeWhenDone = closeWhenDone
    }

    consuming func consumeDiskIO() -> DispatchIO {
        let result = self.dispatchIO
        // Transfer the ownership out and therefor
        // don't perform close on deinit
        self.closeWhenDone = false
        return result
    }

    internal mutating func safelyClose() throws {
        guard self.closeWhenDone else {
            return
        }
        closeWhenDone = false
        dispatchIO.close()
    }

    deinit {
        guard self.closeWhenDone else {
            return
        }

        fatalError("DispatchIO \(self.dispatchIO) was not closed")
    }
}
#endif

internal struct CreatedPipe: ~Copyable {
    internal var _readFileDescriptor: TrackedFileDescriptor?
    internal var _writeFileDescriptor: TrackedFileDescriptor?

    internal init(
        readFileDescriptor: consuming TrackedFileDescriptor?,
        writeFileDescriptor: consuming TrackedFileDescriptor?
    ) {
        self._readFileDescriptor = readFileDescriptor
        self._writeFileDescriptor = writeFileDescriptor
    }

    mutating func readFileDescriptor() -> TrackedFileDescriptor? {
        return self._readFileDescriptor.take()
    }

    mutating func writeFileDescriptor() -> TrackedFileDescriptor? {
        return self._writeFileDescriptor.take()
    }

    internal init(closeWhenDone: Bool) throws {
        let pipe = try FileDescriptor.ssp_pipe()
        self._readFileDescriptor = .init(
            pipe.readEnd,
            closeWhenDone: closeWhenDone
        )
        self._writeFileDescriptor = .init(
            pipe.writeEnd,
            closeWhenDone: closeWhenDone
        )
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

internal func withAsyncTaskCleanupHandler<Success>(
    _ body: () async throws -> Success,
    onCleanup handler: @Sendable @escaping () async -> Void,
    isolation: isolated (any Actor)? = #isolation
) async rethrows -> Success {
    let runCancellationHandlerPromise = Promise<Bool, Never>()
    return try await withThrowingTaskGroup(
        of: Void.self,
        returning: Success.self
    ) { group in
        group.addTask {
            // Keep this task sleep indefinitely until the parent task is cancelled.
            // `Task.sleep` throws `CancellationError` when the task is canceled
            // before the time ends. We then run the cancel handler.
            do { while true { try await Task.sleep(nanoseconds: 1_000_000_000) } } catch {}
            // Run task cancel handler
            runCancellationHandlerPromise.fulfill(with: true)
        }

        group.addTask {
            if await runCancellationHandlerPromise.value {
                await handler()
            }
        }

        defer {
            group.cancelAll()
        }

        do {
            let result = try await body()
            runCancellationHandlerPromise.fulfill(with: false)
            return result
        } catch {
            runCancellationHandlerPromise.fulfill(with: true)
            throw error
        }
    }
}

#if canImport(Darwin)
import os
#else
import Synchronization
#endif

/// Represents a placeholder for a value which will be provided by synchronous code running in another execution context.
internal final class Promise<Success: Sendable, Failure: Swift.Error>: Sendable {
    private struct State {
        var waiters: [CheckedContinuation<Success, Failure>] = []
        var value: Result<Success, Failure>?
    }

    #if canImport(Darwin)
    private let state: OSAllocatedUnfairLock<State>
    #else
    private let state: Mutex<State>
    #endif

    /// Creates a new promise in the unfulfilled state.
    public init() {
        #if canImport(Darwin)
        state = OSAllocatedUnfairLock(initialState: State(value: nil))
        #else
        state = Mutex(State(value: nil))
        #endif
    }

    deinit {
        state.withLock { state in
            precondition(state.waiters.isEmpty, "Deallocated with remaining waiters")
        }
    }

    /// Fulfills the promise with the specified result.
    ///
    /// - returns: Whether the promise was already fulfilled.
    @discardableResult
    public func fulfill(with result: Result<Success, Failure>) -> Bool {
        let (waiters, alreadyFulfilled): ([CheckedContinuation<Success, Failure>], Bool) = state.withLock { state in
            if state.value != nil {
                return ([], true)
            }
            state.value = result
            let waiters = state.waiters
            state.waiters.removeAll()
            return (waiters, false)
        }

        // Resume the continuations outside the lock to avoid potential deadlock if invoked in a cancellation handler.
        for waiter in waiters {
            waiter.resume(with: result)
        }

        return alreadyFulfilled
    }

    /// Fulfills the promise with the specified value.
    ///
    /// - returns: Whether the promise was already fulfilled.
    @discardableResult
    public func fulfill(with value: Success) -> Bool {
        fulfill(with: .success(value))
    }

    /// Fulfills the promise with the specified error.
    ///
    /// - returns: Whether the promise was already fulfilled.
    @discardableResult
    public func fail(throwing error: Failure) -> Bool {
        fulfill(with: .failure(error))
    }
}

extension Promise where Success == Void {
    /// Fulfills the promise.
    ///
    /// - returns: Whether the promise was already fulfilled.
    @discardableResult
    internal func fulfill() -> Bool {
        fulfill(with: ())
    }
}

extension Promise where Failure == Never {
    /// Suspends if the promise is not yet fulfilled, and returns the value once it is.
    internal var value: Success {
        get async {
            await withCheckedContinuation { continuation in
                let value: Result<Success, Never>? = state.withLock { state in
                    if let value = state.value {
                        return value
                    } else {
                        state.waiters.append(continuation)
                        return nil
                    }
                }

                // Resume the continuations outside the lock to avoid potential deadlock if invoked in a cancellation handler.
                if let value {
                    continuation.resume(with: value)
                }
            }
        }
    }

    /// Suspends if the promise is not yet fulfilled, and returns the result once it is.
    internal var result: Result<Success, Failure> {
        get async {
            await .success(value)
        }
    }
}
