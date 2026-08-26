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
import System
#else
import SystemPackage
#endif

#if canImport(Darwin)
// Internal is enough here: Darwin declares no `PlatformSpawnAttributes` or
// `PlatformSpawnFileActions` -- its `preSpawnProcessConfigurator` predates them
// and keeps its own signature -- so nothing public in this file names a type
// this module owns.
import _SubprocessCShims
#else
// `public` because the `PlatformSpawnAttributes` and `PlatformSpawnFileActions`
// typealiases below are public, and on every platform whose C library declares
// `posix_spawnattr_t` and `posix_spawn_file_actions_t` as structs, Swift resolves
// those types through this module rather than through the libc overlay -- even
// where that overlay is itself imported publicly. An internal import would make
// them internal types, and a public typealias may not name one.
public import _SubprocessCShims
#endif

#if canImport(Darwin)
// `public` because `ProcessIdentifier.value` below is public and typed `pid_t`.
// `Subprocess+Darwin.swift` imports Darwin publicly for the same reason.
public import Darwin
#elseif canImport(Android)
public import Android
#elseif canImport(Glibc)
public import Glibc
#elseif canImport(Musl)
public import Musl
#endif

// MARK: - Signals

/// Signals are standardized messages sent to a running program to
/// trigger specific behavior, such as quitting or error handling.
public struct Signal: Hashable, Sendable {
    /// The underlying platform-specific value for the signal.
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// The `.interrupt` signal is sent to a process by its
    /// controlling terminal when a user wishes to interrupt
    /// the process.
    public static var interrupt: Self { .init(rawValue: SIGINT) }
    /// The `.terminate` signal is sent to a process to request its
    /// termination.
    ///
    /// Unlike the `.kill` signal, it can be caught
    /// and interpreted or ignored by the process. This allows
    /// the process to perform graceful termination releasing resources
    /// and saving state if appropriate. `.interrupt` is nearly
    /// identical to `.terminate`.
    public static var terminate: Self { .init(rawValue: SIGTERM) }
    /// The `.suspend` signal instructs the operating system
    /// to stop a process for later resumption.
    public static var suspend: Self { .init(rawValue: SIGSTOP) }
    /// The `.resume` signal instructs the operating system to
    /// continue (restart) a process previously paused by the
    /// `.suspend` signal.
    public static var resume: Self { .init(rawValue: SIGCONT) }
    /// The `.kill` signal is sent to a process to cause it to
    /// terminate immediately.
    ///
    /// In contrast to `.terminate`
    /// and `.interrupt`, this signal cannot be caught or ignored,
    /// and the receiving process cannot perform any
    /// clean-up upon receiving this signal.
    public static var kill: Self { .init(rawValue: SIGKILL) }
    /// The `.terminalClosed` signal is sent to a process when
    /// its controlling terminal is closed.
    ///
    /// In modern systems,
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
    /// Sends the signal you provide to the subprocess.
    /// - Parameters:
    ///   - signal: The signal to send.
    ///   - shouldSendToProcessGroup: A Boolean value that indicates whether this signal should be sent to
    ///     the entire process group.
    /// - Throws: ``SubprocessError`` with error code ``SubprocessError/Code/processControlFailed``.
    ///     See ``SubprocessError/underlyingError`` for more details.
    public func send(
        signal: Signal,
        toProcessGroup shouldSendToProcessGroup: Bool = false
    ) throws(SubprocessError) {
        func _kill(_ pid: pid_t, signal: Signal) throws(SubprocessError) {
            guard kill(pid, signal.rawValue) == 0 else {
                throw SubprocessError.processControlFailed(
                    .sendSignal(signal.rawValue),
                    underlyingError: Errno(rawValue: errno)
                )
            }
        }
        let pid = shouldSendToProcessGroup ? -(processIdentifier.value) : processIdentifier.value

        #if os(Linux) || os(Android) || os(FreeBSD)
        // On platforms with process descriptors, use _subprocess_pdkill if possible
        if shouldSendToProcessGroup || self.processIdentifier.processDescriptor == .invalidDescriptor {
            // _subprocess_pdkill does not support sending signal to process group
            try _kill(pid, signal: signal)
        } else {
            let rc = _subprocess_pdkill(
                processIdentifier.processDescriptor,
                signal.rawValue
            )
            if rc == 0 {
                // _pidfd_send_signal succeeded
                return
            }
            if errno == ENOSYS {
                // _pidfd_send_signal is not implemented. Fallback to kill
                try _kill(pid, signal: signal)
                return
            }

            // Throw all other errors
            throw SubprocessError.processControlFailed(
                .sendSignal(signal.rawValue),
                underlyingError: Errno(rawValue: errno)
            )
        }
        #else
        try _kill(pid, signal: signal)
        #endif
    }
}

// MARK: - Environment Resolution and Validation
extension Environment {
    /// The `PATH` value to resolve ``Executable/name(_:)`` against.
    ///
    /// The value the subprocess receives wins, so a name resolves in the
    /// environment it will run in. When that environment carries no `PATH`,
    /// this process's own value is used; `nil` means neither defines one.
    internal func pathValue() -> String? {
        switch self.config {
        case .inherit(let overrides):
            // If PATH value exists in overrides, use it. An override maps to
            // `nil` to unset the value, which falls through to this process.
            if let overridden = overrides[.path], let overridden {
                return overridden
            }
            // Fall back to current process
            return Self.currentEnvironmentValues()[.path]
        case .custom(let fullEnvironment):
            if let value = fullEnvironment[.path] {
                return value
            }
            return Self.currentEnvironmentValues()[.path]
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
            return Self.currentEnvironmentValues()[.path]
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

    /// POSIX standard imposes restrictions on environment keys and values:
    /// 1. Names shall not contain the character '='.
    /// 2. Names shall not begin with a digit.
    /// 3. Names and values shall be composed of characters from the portable character set except NUL
    /// See https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html
    internal func validate() throws(SubprocessError) {
        let equals = UInt8(ascii: "=")
        let nul = UInt8(ascii: "\0")
        let digit0 = UInt8(ascii: "0")
        let digit9 = UInt8(ascii: "9")

        func _validateError(_ reason: String) -> SubprocessError {
            return .spawnFailed(withUnderlyingError: nil, reason: reason)
        }

        func _validate(_ dict: [Key: String?]) throws(SubprocessError) {
            for (key, value) in dict {
                let keyBytes = key.rawValue.utf8
                // Rule 1/3: key shall not contain = nor null bytes
                let ruleOneViolation = keyBytes.contains {
                    $0 == equals || $0 == nul
                }
                if ruleOneViolation {
                    throw _validateError("Environment key '\(key)' must not contain '=' or null bytes.")
                }
                // Rule 2: key shall not begin with a digit
                if let first = keyBytes.first, (digit0...digit9).contains(first) {
                    throw _validateError("Environment key '\(key)' must not begin with a digit.")
                }
                // Rule 3: value shall not contain null bytes
                if let value, value.utf8.contains(nul) {
                    throw _validateError("Environment value '\(value)' must not contain null bytes.")
                }
            }
        }

        func _validate(rawBytes rawBytesArray: [[UInt8]]) throws(SubprocessError) {
            for rawBytes in rawBytesArray {
                // Each entry is passed to `strdup` in `createEnv()`, which stops
                // at the first null byte. A single trailing null terminator is
                // allowed, but reject any earlier null byte since it would
                // silently truncate the entry.
                var bytes = rawBytes
                if bytes.last == nul {
                    bytes = bytes.dropLast()
                }
                // Rule 1/3: entry shall not contain null bytes
                if bytes.contains(nul) {
                    throw _validateError(
                        "Environment entry '\(String(decoding: bytes, as: UTF8.self))' must not contain null bytes."
                    )
                }
                // Each entry is a key and value pair joined by '='
                guard let equalsIndex = bytes.firstIndex(of: equals) else {
                    throw _validateError(
                        "Environment entry '\(String(decoding: bytes, as: UTF8.self))' must contain '='."
                    )
                }
                // Rule 2: key shall not begin with a digit
                let keyBytes = bytes[bytes.startIndex..<equalsIndex]
                if let first = keyBytes.first, (digit0...digit9).contains(first) {
                    throw _validateError(
                        "Environment key '\(String(decoding: keyBytes, as: UTF8.self))' must not begin with a digit."
                    )
                }
            }
        }

        switch self.config {
        case .inherit(let updates):
            try _validate(updates)
        case .custom(let custom):
            try _validate(custom.mapValues { Optional($0) })
        case .rawBytes(let rawBytesArray):
            try _validate(rawBytes: rawBytesArray)
        }
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
    /// The directories searched when neither the environment passed to the
    /// subprocess nor the current process defines `PATH`. This is the system's own
    /// standard path,`confstr(_CS_PATH)`, falling back to the `<paths.h>` macro fixed
    /// at compile time.
    ///
    /// The list is filtered like a `PATH` value, so a relative or empty entry in
    /// the system's answer is skipped too. If the system reports nothing usable,
    /// the historical hard-coded list stands in as a last resort.
    internal static let defaultSearchPaths: [String] = {
        guard let systemPathValue = Self.systemStandardPathValue() else {
            return Self.fallbackSearchPaths
        }
        let searchPaths = systemPathValue.split(separator: Self.pathValueSeparator)
            .map(String.init)
            .filter { FilePath($0).isAbsolute }
        return searchPaths.isEmpty ? Self.fallbackSearchPaths : searchPaths
    }()

    /// The directories to search when the system reports no standard path.
    private static let fallbackSearchPaths = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/usr/local/bin",
    ]

    /// Asks the system for its standard `PATH` value, or returns `nil` when it
    /// reports none.
    private static func systemStandardPathValue() -> String? {
        // Two-call `confstr` protocol: size the buffer, then fill it. A second
        // call that needs more room than the first reported means the value
        // changed underneath us, which cannot happen for a system constant, so
        // a short answer is simply used as-is.
        let size = _subprocess_default_search_path(nil, 0)
        guard size > 1 else {
            return nil
        }
        let pathValue = withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(size)) { buffer in
            guard _subprocess_default_search_path(buffer.baseAddress, size) > 0 else {
                return ""
            }
            return String(cString: buffer.baseAddress!)
        }
        return pathValue.isEmpty ? nil : pathValue
    }

    internal func resolveExecutablePath(withPathValue pathValue: String?) throws(SubprocessError) -> String {
        switch self.storage {
        case .executable(let executableName):
            let firstAccessibleExecutable = try possibleExecutablePaths(withPathValue: pathValue)
                .first { Configuration.executableAccessible($0) }
            if let firstAccessibleExecutable {
                return firstAccessibleExecutable
            }
            throw SubprocessError.executableNotFound(executableName, underlyingError: nil)
        case .path(let executablePath):
            // Use path directly
            return executablePath.string
        }
    }

    /// The paths to try, in order, for this executable.
    ///
    /// A name is joined to each directory returned by
    /// `Executable.searchPaths(withPathValue:)`; the name itself is never a
    /// candidate, so `execvp`-style resolution against a current working
    /// directory cannot happen. A path is its own only candidate.
    internal func possibleExecutablePaths(
        withPathValue pathValue: String?
    ) throws(SubprocessError) -> _OrderedSet<String> {
        switch self.storage {
        case .executable(let executableName):
            try Self.validate(name: executableName)
            var results: _OrderedSet<String> = .init()
            for path in Self.searchPaths(withPathValue: pathValue) {
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
        _ work: (PreSpawnArgs) async throws -> Result
    ) async throws -> Result {
        // Prepare environment
        try self.environment.validate()

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

    /// Returns whether `path` refers to a regular file this process may execute.
    ///
    /// `access(_:X_OK)` alone is not enough: on a directory the execute bit
    /// means "searchable", so a directory would otherwise be reported as a
    /// runnable executable.
    internal static func executableAccessible(_ path: String) -> Bool {
        guard Self.pathAccessible(path, mode: X_OK) else {
            return false
        }
        var status = stat()
        guard path.withCString({ stat($0, &status) == 0 }) else {
            return false
        }
        return (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
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
            throw SubprocessError.asyncIOFailed(
                reason: "Failed to create pipe",
                underlyingError: error as? SubprocessError.UnderlyingError
            )
        }
    }

    internal var platformDescriptor: PlatformFileDescriptor {
        return self.rawValue
    }
}

internal typealias PlatformFileDescriptor = CInt

internal extension PlatformFileDescriptor {
    static var invalidDescriptor: Self { -1 }
}

// MARK:  - ProcessIdentifier

/// A platform-independent identifier for a subprocess.
public struct ProcessIdentifier: Sendable, Hashable {
    /// The platform-specific process identifier value.
    public let value: pid_t

    #if os(Linux) || os(Android) || os(FreeBSD)
    /// The process file descriptor (pidfd) for the running execution.
    ///
    /// `-1` when this platform provides no way to obtain one for how the process
    /// was launched. On FreeBSD that is the case for any process launched with
    /// `posix_spawn`, which is the common path: a process descriptor is
    /// available there only from `pdfork`, which only the `fork`/`exec` fallback
    /// path uses.
    public let processDescriptor: CInt
    #else
    internal let processDescriptor: CInt // not used on other platforms
    #endif

    internal init(value: pid_t, processDescriptor: PlatformFileDescriptor) {
        self.value = value
        self.processDescriptor = processDescriptor
    }

    internal func close() {
        if self.processDescriptor != .invalidDescriptor {
            try? _safelyClose(.fileDescriptor(FileDescriptor(rawValue: self.processDescriptor)))
        }
    }
}

extension ProcessIdentifier: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual representation of the process identifier.
    public var description: String { "\(self.value)" }
    /// A debug-oriented textual representation of the process identifier.
    public var debugDescription: String { "\(self.value)" }
}

// MARK: - Platform Types

#if !canImport(Darwin)

#if canImport(Android)
public typealias pid_t = Android.pid_t
public typealias uid_t = Android.uid_t
public typealias gid_t = Android.gid_t
#elseif canImport(Glibc)
public typealias pid_t = Glibc.pid_t
public typealias uid_t = Glibc.uid_t
public typealias gid_t = Glibc.gid_t
#elseif canImport(Musl)
public typealias pid_t = Musl.pid_t
public typealias uid_t = Musl.uid_t
public typealias gid_t = Musl.gid_t
#endif

// MARK: - Platform spawn attribute pointers

// Swift imports `posix_spawnattr_init` and `posix_spawn_file_actions_init` as
// taking a pointer to an *optional* on FreeBSD and OpenBSD, and a pointer to a
// non-optional everywhere else, so the two spellings below are not
// interchangeable and there is no single one that works.
//
// The discriminator is not the typedef shape. glibc and musl typedef a struct,
// which is never imported as optional. Bionic, FreeBSD and OpenBSD all typedef a
// pointer — but Bionic's `<spawn.h>` is nullability-audited
// (`posix_spawn_file_actions_t _Nonnull * _Nonnull`), so its pointee imports as
// non-optional too, while the two BSDs leave theirs unannotated and so get the
// implicitly-optional import. That leaves exactly FreeBSD and OpenBSD on one
// side. `_assertPlatformSpawnTypesMatchLibc` below turns a mistake here into a
// compile error rather than a broken public API.
#if os(FreeBSD) || os(OpenBSD)

/// A pointer to the platform's `posix_spawn` attributes, in the form this
/// platform's C library accepts.
///
/// The exact type varies by platform, because the C libraries do not agree on
/// how `posix_spawnattr_t` is declared and Swift imports the differences: it is
/// `UnsafeMutablePointer<posix_spawnattr_t?>` on FreeBSD and OpenBSD, whose
/// headers leave the pointee's nullability unannotated, and
/// `UnsafeMutablePointer<posix_spawnattr_t>` everywhere else. Naming this
/// typealias rather than either spelling compiles on every platform that
/// declares it.
///
/// Darwin does not. Its ``PlatformOptions/preSpawnProcessConfigurator`` predates
/// these typealiases and keeps its original signature, which takes the attributes
/// and file actions `inout` rather than as pointers, so code that configures the
/// spawn on Darwin *and* elsewhere still needs to branch on
/// `#if canImport(Darwin)` -- in the closure's body as well as its signature.
public typealias PlatformSpawnAttributes = UnsafeMutablePointer<posix_spawnattr_t?>
/// A pointer to the platform's `posix_spawn` file actions, in the form this
/// platform's C library accepts.
///
/// The exact type varies by platform, for the reason given on
/// ``PlatformSpawnAttributes``: it is
/// `UnsafeMutablePointer<posix_spawn_file_actions_t?>` on FreeBSD and OpenBSD
/// and `UnsafeMutablePointer<posix_spawn_file_actions_t>` everywhere else.
public typealias PlatformSpawnFileActions = UnsafeMutablePointer<posix_spawn_file_actions_t?>

#else

/// A pointer to the platform's `posix_spawn` attributes, in the form this
/// platform's C library accepts.
///
/// The exact type varies by platform, because the C libraries do not agree on
/// how `posix_spawnattr_t` is declared and Swift imports the differences: it is
/// `UnsafeMutablePointer<posix_spawnattr_t?>` on FreeBSD and OpenBSD, whose
/// headers leave the pointee's nullability unannotated, and
/// `UnsafeMutablePointer<posix_spawnattr_t>` everywhere else. Naming this
/// typealias rather than either spelling compiles on every platform that
/// declares it.
///
/// Darwin does not. Its ``PlatformOptions/preSpawnProcessConfigurator`` predates
/// these typealiases and keeps its original signature, which takes the attributes
/// and file actions `inout` rather than as pointers, so code that configures the
/// spawn on Darwin *and* elsewhere still needs to branch on
/// `#if canImport(Darwin)` -- in the closure's body as well as its signature.
public typealias PlatformSpawnAttributes = UnsafeMutablePointer<posix_spawnattr_t>
/// A pointer to the platform's `posix_spawn` file actions, in the form this
/// platform's C library accepts.
///
/// The exact type varies by platform, for the reason given on
/// ``PlatformSpawnAttributes``: it is
/// `UnsafeMutablePointer<posix_spawn_file_actions_t?>` on FreeBSD and OpenBSD
/// and `UnsafeMutablePointer<posix_spawn_file_actions_t>` everywhere else.
public typealias PlatformSpawnFileActions = UnsafeMutablePointer<posix_spawn_file_actions_t>

#endif

/// Compile-time proof that the two typealiases above name exactly the types this
/// platform's C library takes.
///
/// Never called; it exists so that getting the condition above wrong is a build
/// failure on the affected platform instead of a public API nobody can use.
///
/// It deliberately probes mutating entry points rather than the `init`s. Bionic
/// annotates only its `init`s `_Nullable` — they are out-parameters — and
/// everything else `_Nonnull`, so the two import differently there and `init` is
/// the unrepresentative one. These are the calls a configurator actually makes.
@available(*, unavailable)
private func _assertPlatformSpawnTypesMatchLibc(
    _ fileActions: PlatformSpawnFileActions,
    _ spawnAttributes: PlatformSpawnAttributes
) {
    _ = posix_spawn_file_actions_adddup2(fileActions, 0, 0)
    _ = posix_spawnattr_setflags(spawnAttributes, 0)
}

// MARK: - Platform Specific Options

/// The collection of platform-specific settings
/// to configure the subprocess when running.
public struct PlatformOptions: Sendable {
    /// The user ID for the subprocess.
    public var userID: uid_t? = nil
    /// The real, effective, and saved set-group-ID for the subprocess.
    ///
    /// Setting this value is equivalent to calling `setgid()` on the subprocess.
    /// The group ID controls permissions, particularly for file access.
    public var groupID: gid_t? = nil
    /// The list of supplementary group IDs for the subprocess.
    public var supplementaryGroups: [gid_t]? = nil
    /// The process group for the subprocess.
    ///
    /// Equivalent to calling `setpgid()` on the subprocess.
    /// The process group ID groups related processes for controlling signals.
    ///
    /// Whether a `setpgid` failure is reported depends on how the subprocess is
    /// launched. Where the C library applies it, as part of `posix_spawn`, a
    /// failure fails the launch and is thrown. Where this package applies it
    /// itself, in a forked child, it is currently ignored and the subprocess
    /// launches in the parent's process group instead -- which is the case
    /// whenever ``userID``, ``groupID`` or ``supplementaryGroups`` is also set,
    /// when this is combined with ``createSession``, or on a platform whose
    /// `posix_spawn` cannot express the request.
    public var processGroupID: pid_t? = nil
    /// A Boolean value that indicates whether to create a session
    /// and detach from the terminal.
    public var createSession: Bool = false
    /// An ordered list of steps to tear down the subprocess
    /// if the calling task is canceled before
    /// the subprocess terminates.
    ///
    /// The sequence always ends by sending a `.kill` signal.
    public var teardownSequence: [TeardownStep] = []
    /// A closure that configures platform-specific
    /// process-launching constructs.
    ///
    /// Use this closure to directly configure or override
    /// the underlying platform-specific launch settings that the
    /// library uses internally, when higher-level APIs aren't
    /// available for such modifications.
    ///
    /// This closure allows modification of the `posix_spawnattr_t` attribute
    /// and file actions `posix_spawn_file_actions_t` before they are sent to
    /// `posix_spawn()`.
    ///
    /// This is best-effort: it may not be called when a configuration cannot be
    /// expressed with `posix_spawn` and must be launched with `fork` and `exec`
    /// instead. That happens when ``userID``, ``groupID`` or
    /// ``supplementaryGroups`` is set, when ``createSession`` is combined with
    /// ``processGroupID``, or when this platform's C library cannot close
    /// inherited file descriptors, change directory, or create a session
    /// through `posix_spawn`.
    public var preSpawnProcessConfigurator:
        (
            @Sendable (
                PlatformSpawnAttributes,
                PlatformSpawnFileActions
            ) throws -> Void
        )? = nil
    /// Creates platform options with default values.
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

@Sendable
internal func reapProcess(
    with processIdentifier: ProcessIdentifier
) throws(SubprocessError) -> TerminationStatus {
    do throws(Errno) {
        // On some platforms, the process exit notification (in particular NOTE_EXIT from kqueue)
        // may be delivered slightly before the process becomes reapable,
        // so we must call waitid without WNOHANG to avoid a narrow possibility of a race condition.
        // If waitid does block, it won't do so for very long at all.
        let status = try processIdentifier.blockingReap()
        return status
    } catch {
        let subprocessError: SubprocessError = .failedToMonitor(withUnderlyingError: error)
        throw subprocessError
    }
}

extension ProcessIdentifier {
    /// Reaps the zombie for the exited process.
    ///
    /// This function may block.
    @available(*, noasync)
    internal func blockingReap() throws(Errno) -> TerminationStatus {
        try _blockingReap(pid: value)
    }

    /// Reaps the zombie for the exited process, or returns `nil` if the process is still running.
    ///
    /// This function does not block.
    internal func reap() throws(Errno) -> TerminationStatus? {
        try _reap(pid: value)
    }

    /// Checks whether the process has already exited without consuming the
    /// zombie.
    ///
    /// Returns `true` if a child has exited (or stopped/continued in a
    /// way `waitid` reports), `false` if the child is still running.
    /// The zombie remains available for a subsequent call to `blockingReap()`.
    internal func peekIfExited() throws(Errno) -> Bool {
        try _peekIfExited(pid: value)
    }
}

// FIXME: once FreeBSD 15.1 can be required, reap a descriptor-backed child with
// pdwait(2) rather than waitid(P_PID, ...), so the child is reaped through its
// process descriptor instead of by pid. pdwait fills in a `struct __siginfo`,
// which is what `TerminationStatus.init(_ siginfo:)` already consumes, so the
// change is confined to `_blockingReap`, `_reap` and `_peekIfExited`. Added to
// FreeBSD as syscall 601 in January 2026, with a pdwait.2 manual page and an
// entry in lib/libsys/Makefile.sys, so it is a first-class userspace wrapper:
// present in stable/15, absent from releng/15.0.
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

internal func _peekIfExited(pid: pid_t) throws(Errno) -> Bool {
    // WNOWAIT leaves the zombie in the process table so a subsequent
    // `_blockingReap` (or `_reap`) can still consume it.
    let siginfo = try _waitid(idtype: P_PID, id: id_t(pid), flags: WEXITED | WNOHANG | WNOWAIT)
    return !(siginfo.si_pid == 0 && siginfo.si_signo == 0)
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
            self = .signaled(siginfo.si_status)
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
