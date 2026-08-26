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

#if os(OpenBSD)
// FIXME: Why is this necessary only on OpenBSD?
public import _SubprocessCShims
#else
import _SubprocessCShims
#endif

// Non-public: this file declares no public API, and since the spawn attributes
// and file actions are held as opaque handles it names no libc type either.
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if SubprocessFoundation

#if canImport(Darwin)
// `PlatformOptions.QualityOfService` is `Foundation.QualityOfService` here, so
// its cases need Foundation in scope.
import Foundation
#else
import FoundationEssentials
#endif

#endif // SubprocessFoundation

// MARK: - SpawnCapabilities

/// The `posix_spawn` features the host libc actually provides.
///
/// Resolved once per process by the C shim and cached there; this is a decoded
/// view of that bitmask.
internal struct SpawnCapabilities: Sendable {
    /// How, if at all, `posix_spawn` can be asked to close every inherited
    /// file descriptor.
    internal enum CloseAllMechanism: Sendable, Hashable {
        /// A `POSIX_SPAWN_CLOEXEC_DEFAULT` attribute flag. Darwin's form closes
        /// descriptors 0, 1 and 2 as well; Bionic's spares them.
        case cloexecDefault
        /// A `posix_spawn_file_actions_addclosefrom_np` file action.
        case closefromAction
        /// Neither, so `posix_spawn` cannot be used at all.
        case unavailable
    }

    internal let closeAllViaSpawn: CloseAllMechanism
    /// Whether an `fchdir` file action is available.
    internal let hasChdirAction: Bool
    /// Whether `POSIX_SPAWN_SETSID` is honoured.
    internal let hasSetsidFlag: Bool

    internal init(bitmask: UInt32) {
        if bitmask & UInt32(_SUBPROCESS_SPAWN_CAP_CLOEXEC_DEFAULT) != 0 {
            // Preferred when a platform reports both: an attribute flag cannot
            // fail partway through a sequence of file-action appends.
            self.closeAllViaSpawn = .cloexecDefault
        } else if bitmask & UInt32(_SUBPROCESS_SPAWN_CAP_CLOSEFROM_ACTION) != 0 {
            self.closeAllViaSpawn = .closefromAction
        } else {
            self.closeAllViaSpawn = .unavailable
        }
        self.hasChdirAction = bitmask & UInt32(_SUBPROCESS_SPAWN_CAP_CHDIR_ACTION) != 0
        self.hasSetsidFlag = bitmask & UInt32(_SUBPROCESS_SPAWN_CAP_SETSID_FLAG) != 0
    }

    /// The host's capabilities.
    internal static let current = SpawnCapabilities(
        bitmask: _subprocess_spawn_capabilities()
    )
}

extension SpawnCapabilities {
    /// Forces every spawn onto the fallback path, for tests.
    ///
    /// The fallback path can express everything `posix_spawn` can — the rules in
    /// ``Configuration/requiresFallbackSpawnPath(supplementaryGroups:capabilities:)``
    /// only ever move work *towards* it — so forcing it is always safe. That is
    /// what lets every disinheritance, stdio, working-directory and signal test
    /// run under both paths on every platform, instead of macOS never
    /// exercising `fork` and modern glibc never exercising `fork`/`exec`.
    ///
    /// There is deliberately no switch forcing `posix_spawn`: it cannot express
    /// the configurations the rules route away from it.
    ///
    /// A task-local, not a global: `.serialized` serializes a suite's own tests
    /// but Swift Testing still runs other suites concurrently, so a global would
    /// steer their spawns too. The value is read from spawn setup, which runs in
    /// the caller's task tree, so a task-local confines the override to the test
    /// that set it. Never set outside tests.
    ///
    /// Spelled as an explicit `TaskLocal` rather than with the `@TaskLocal` macro
    /// because the CMake build passes no macro plugin flags and so cannot expand
    /// it. Tests use
    /// `SpawnCapabilities.forceFallbackPathOverride.withValue(true) { … }`.
    internal static let forceFallbackPathOverride = TaskLocal<Bool>(wrappedValue: false)

    /// Whether the current task has forced the fallback path. See
    /// ``forceFallbackPathOverride``.
    internal static var forceFallbackPathForTesting: Bool {
        Self.forceFallbackPathOverride.get()
    }

    /// Records which path each spawn actually took, for tests that assert
    /// routing rather than merely setting the override.
    ///
    /// Task-local, and mutated only from the spawning task, so it neither races
    /// with nor counts the spawns of tests running concurrently in other suites.
    internal static let spawnPathTallyOverride = TaskLocal<SpawnPathTally?>(wrappedValue: nil)

    /// The tally the current task installed, if any. See
    /// ``spawnPathTallyOverride``.
    internal static var spawnPathTallyForTesting: SpawnPathTally? {
        Self.spawnPathTallyOverride.get()
    }
}

/// A count of the spawns each path performed. See
/// ``SpawnCapabilities/spawnPathTallyForTesting``.
///
/// `@unchecked Sendable` because it is a task-local reference mutated only from
/// the single task that installed it, so its mutable state cannot be reached
/// concurrently.
internal final class SpawnPathTally: @unchecked Sendable {
    internal private(set) var posixSpawn = 0
    internal private(set) var fallback = 0

    internal init() {}

    internal func recordPosixSpawn() {
        self.posixSpawn += 1
    }

    internal func recordFallback() {
        self.fallback += 1
    }
}

// MARK: - Path selection

extension Configuration {
    /// Whether this configuration must be spawned with `fork`/`exec` — or, on
    /// Darwin, pre-fork plus `posix_spawn(POSIX_SPAWN_SETEXEC)` — because
    /// `posix_spawn` alone cannot express it.
    ///
    /// - Parameters:
    ///   - supplementaryGroups: The resolved supplementary groups, as
    ///     ``preSpawn(_:)`` produced them.
    ///   - capabilities: The `posix_spawn` features to assume. Defaults to the
    ///     host's; tests pass explicit values.
    internal func requiresFallbackSpawnPath(
        supplementaryGroups: [gid_t]?,
        capabilities: SpawnCapabilities = .current
    ) -> Bool {
        if SpawnCapabilities.forceFallbackPathForTesting {
            return true
        }

        // 1. setuid, setgid and setgroups have no posix_spawn attribute on any
        //    platform.
        if self.platformOptions.userID != nil
            || self.platformOptions.groupID != nil
            || (supplementaryGroups?.count ?? 0) > 0
        {
            return true
        }

        // 2. Without a libc mechanism for "close everything", the only
        //    alternative would be to enumerate this process's descriptors and
        //    emit one addclose each, which would leak any descriptor another
        //    thread opens between the enumeration and the spawn.
        if capabilities.closeAllViaSpawn == .unavailable {
            return true
        }

        // 3. No POSIX_SPAWN_SETSID (FreeBSD, OpenBSD).
        if self.platformOptions.createSession && !capabilities.hasSetsidFlag {
            return true
        }

        // 4. The libcs disagree on the order of setsid and setpgid: glibc calls
        //    setsid first, Bionic calls setpgid first, which makes the following
        //    setsid fail with EPERM because the child already leads a process
        //    group. The fallback path controls the order itself.
        if self.platformOptions.createSession && self.platformOptions.processGroupID != nil {
            return true
        }

        // 5. No chdir file action (OpenBSD; Android below API 34), or no way to
        //    open a descriptor for it.
        //
        //    Both halves are required because they are established differently:
        //    `hasChdirAction` is probed at runtime with `dlsym`, while whether a
        //    directory can be opened for search at all is decided by which of
        //    `O_SEARCH`/`O_PATH` the headers define. No supported platform has the
        //    action without one of those macros, so today the second test never
        //    changes the answer -- but if one ever did, `resolveWorkingDirectory`
        //    would hand back `.invalidDescriptor`, no `fchdir` action would be
        //    appended, and the child would run in the parent's directory with no
        //    error reported anywhere. Silently ignoring a working directory is the
        //    worst available outcome, so it is worth one redundant test to make it
        //    unreachable.
        if self.workingDirectory != nil
            && (!capabilities.hasChdirAction || _subprocess_can_open_directory_for_search() == 0)
        {
            return true
        }

        return false
    }
}

// MARK: - Spawning

/// Whether the fallback path also needs `posix_spawn` file actions and
/// attributes.
///
/// Darwin's fallback forks and then execs through
/// `posix_spawn(POSIX_SPAWN_SETEXEC)`, so it applies the same file actions and
/// attributes as the plain `posix_spawn` path. Every other platform's fallback
/// does its child-side setup itself and needs neither.
///
/// Spelled as a `let` rather than a `#if` at the use site so that the branch it
/// selects against does not become unreachable code, which warns.
#if canImport(Darwin)
private let fallbackPathUsesSpawnAttributes = true
#else
private let fallbackPathUsesSpawnAttributes = false
#endif

extension Configuration {
    /// The descriptors a spawn wires to the child's standard streams, as plain
    /// platform descriptors.
    ///
    /// The child's ends (`inputRead`, `outputWrite`, `errorWrite`) are duplicated
    /// onto 0, 1 and 2; the parent's ends are closed in the child.
    ///
    /// The three child-side fields are never `nil` in practice, and the spawn
    /// path relies on that: a stream requested as `.none` is `/dev/null`, not an
    /// absent descriptor. ``NoInput/createPipe()`` and the discard outputs all
    /// open `/dev/null` for the child's end, and every other input and output
    /// type creates a real pipe or takes a caller-supplied descriptor. So the
    /// child always ends up with something on 0, 1 and 2, and nothing here ever
    /// has to close a standard descriptor outright. The parent-side fields are
    /// genuinely optional: `/dev/null` and caller-supplied descriptors have no
    /// parent end.
    internal struct StdioDescriptors: Sendable {
        let inputRead: PlatformFileDescriptor?
        let inputWrite: PlatformFileDescriptor?
        let outputWrite: PlatformFileDescriptor?
        let outputRead: PlatformFileDescriptor?
        let errorWrite: PlatformFileDescriptor?
        let errorRead: PlatformFileDescriptor?

        /// The layout `_subprocess_fork_exec` expects.
        var forkExecArray: [CInt] {
            [
                self.inputRead ?? -1,
                self.inputWrite ?? -1,
                self.outputWrite ?? -1,
                self.outputRead ?? -1,
                self.errorWrite ?? -1,
                self.errorRead ?? -1,
            ]
        }
    }

    /// What one spawn attempt produced.
    ///
    /// `error` is 0 on success. `processDescriptor` is `.invalidDescriptor` when
    /// the platform has none, when the kernel is too old to provide one, or when
    /// the attempt failed before one was created.
    internal struct SpawnOutcome: Sendable {
        let pid: pid_t
        let processDescriptor: PlatformFileDescriptor
        let error: CInt
    }

    // @unchecked Sendable because we need to capture UnsafePointers to send to
    // another thread. While UnsafePointers are not Sendable, we are not mutating
    // them -- we only need these type for C interface.
    internal struct SpawnContext: @unchecked Sendable {
        let argv: [UnsafeMutablePointer<CChar>?]
        let env: [UnsafeMutablePointer<CChar>?]
        let uidPtr: UnsafeMutablePointer<uid_t>?
        let gidPtr: UnsafeMutablePointer<gid_t>?
        let processGroupIDPtr: UnsafeMutablePointer<gid_t>?
        /// Opaque handles from `_subprocess_spawn_file_actions_create` and
        /// `_subprocess_spawnattr_create`, or `nil` when the path being used
        /// needs neither. Untyped for the reason given in `process_shims.h`.
        let fileActions: UnsafeMutableRawPointer?
        let spawnAttributes: UnsafeMutableRawPointer?
    }
}

extension Configuration {
    /// Builds the `posix_spawn` file actions and attributes, hands them to
    /// `body`, and tears them down afterwards.
    ///
    /// - Parameters:
    ///   - stdio: The descriptors to wire to the child's standard streams.
    ///   - workingDirectoryDescriptor: A descriptor for the requested working
    ///     directory, or `.invalidDescriptor` when none was requested.
    ///   - capabilities: The `posix_spawn` features to use.
    ///   - usesFallbackPath: Whether the caller will spawn through the fallback
    ///     path. On Darwin the fallback still runs `posix_spawn` with
    ///     `POSIX_SPAWN_SETEXEC`, so it needs these same actions — but it calls
    ///     `setsid()` itself, so `POSIX_SPAWN_SETSID` must not also be set or the
    ///     inner spawn would fail with `EPERM` on an already-session-leading
    ///     child.
    private func withSpawnAttributes<Result>(
        stdio: StdioDescriptors,
        workingDirectoryDescriptor: PlatformFileDescriptor,
        capabilities: SpawnCapabilities,
        usesFallbackPath: Bool,
        _ body: (UnsafeMutableRawPointer, UnsafeMutableRawPointer) async throws -> Result
    ) async throws -> Result {
        func spawnFailure(_ code: CInt) -> SubprocessError {
            SubprocessError.spawnFailed(withUnderlyingError: Errno(rawValue: code))
        }

        // Opaque handles rather than Swift-declared `posix_spawn_file_actions_t`
        // and `posix_spawnattr_t` values: no single Swift spelling can call the
        // libc functions on every platform this package supports. See the
        // "Opaque posix_spawn file actions and attributes" note in
        // `process_shims.h`.
        var fileActionsError: CInt = 0
        guard let fileActions = _subprocess_spawn_file_actions_create(&fileActionsError) else {
            throw spawnFailure(fileActionsError)
        }
        defer { _subprocess_spawn_file_actions_free(fileActions) }

        var attributesError: CInt = 0
        guard let spawnAttributes = _subprocess_spawnattr_create(&attributesError) else {
            throw spawnFailure(attributesError)
        }
        defer { _subprocess_spawnattr_free(spawnAttributes) }

        // 1. Change directory, first.
        //
        //    Before the dup2s below, because those target 0, 1 and 2 and this
        //    descriptor can *be* 0, 1 or 2: it is opened after the pipes, so it
        //    takes the lowest number still free, and a caller whose standard
        //    descriptors are closed leaves low numbers free. A dup2 onto that
        //    number replaces the directory before `fchdir` reaches it, and the
        //    child then either fails with ENOTDIR -- reported as
        //    `executableNotFound`, since ENOTDIR is a try-the-next-candidate
        //    errno -- or, if the replacement happens to be a directory, silently
        //    runs in the wrong one.
        //
        //    Ordering it first is safe in every other direction: the descriptor
        //    is distinct from all six stdio descriptors, since all of them are
        //    open at once, so no close or dup2 below can be aimed at it. And it
        //    must precede any close-all action, which would close it outright.
        //
        //    Darwin resolves an `addfchdir_np` descriptor against the parent's
        //    table rather than the child's, so it is immune; glibc, Bionic and
        //    FreeBSD run the actions as a literal sequence of syscalls in the
        //    child, which is what POSIX specifies and what this ordering assumes
        //    throughout.
        if workingDirectoryDescriptor != .invalidDescriptor {
            let result = _subprocess_spawn_addfchdir(fileActions, workingDirectoryDescriptor)
            guard result == 0 else {
                throw SubprocessError.failedToChangeWorkingDirectory(
                    self.workingDirectory?.string,
                    underlyingError: Errno(rawValue: result)
                )
            }
        }

        // 2. Close the parent's ends of the pipes.
        //
        //    Strictly before the dup2s below, because `posix_spawn` runs file
        //    actions in the order they were appended. A parent end can occupy 0,
        //    1 or 2 whenever the calling process has a low descriptor free, and a
        //    close of such a descriptor appended *after* the dup2 that claimed
        //    the same number would close the child's standard stream instead of
        //    the parent end.
        //
        //    Closing first is safe in the other direction: each dup2 below names
        //    a child end, and no child end is ever also a parent end.
        //
        //    Skipping the close for descriptors 0/1/2 would not do, either: where
        //    the close-all mechanism is `closefrom(3)` it never reaches those
        //    numbers, so the parent end would stay open in the child.
        for descriptor in [stdio.inputWrite, stdio.outputRead, stdio.errorRead] {
            guard let descriptor else { continue }
            let result = _subprocess_spawn_file_actions_addclose(fileActions, descriptor)
            guard result == 0 else { throw spawnFailure(result) }
        }

        // 3. Bind the child's ends to 0/1/2.
        //
        //    A dup2 whose source already equals its target is emitted too: that
        //    is the documented way to clear FD_CLOEXEC on the descriptor
        //    (Austin Group issue #411), and every libc this package supports
        //    special-cases it.
        for (descriptor, target) in [
            (stdio.inputRead, CInt(0)),
            (stdio.outputWrite, CInt(1)),
            (stdio.errorWrite, CInt(2)),
        ] {
            guard let descriptor else { continue }
            let result = _subprocess_spawn_file_actions_adddup2(fileActions, descriptor, target)
            guard result == 0 else { throw spawnFailure(result) }
        }

        // 4. Close everything else, last: this must run after the dup2 and
        //    fchdir actions, or it would close the descriptors they need.
        if capabilities.closeAllViaSpawn == .closefromAction {
            let result = _subprocess_spawn_addclosefrom(fileActions, 3)
            guard result == 0 else { throw spawnFailure(result) }
        }

        // Reset the child's signal disposition, matching the fallback path.
        let signalsResult = _subprocess_spawnattr_reset_signals(spawnAttributes)
        guard signalsResult == 0 else { throw spawnFailure(signalsResult) }

        // Every flag value comes from a C helper, so that the conversion to the
        // `short` the libc takes happens where the macro is defined rather than
        // in a Swift `Int16(_:)` that would trap on a platform defining one
        // above `Int16.max`.
        var flags: Int16 = _subprocess_spawn_flags_reset_signals()
        if capabilities.closeAllViaSpawn == .cloexecDefault {
            flags |= _subprocess_spawn_flag_cloexec_default()
        }
        if let processGroupID = self.platformOptions.processGroupID {
            flags |= _subprocess_spawn_flag_setpgroup()
            let result = _subprocess_spawnattr_setpgroup(spawnAttributes, pid_t(processGroupID))
            guard result == 0 else { throw spawnFailure(result) }
        }
        if self.platformOptions.createSession && !usesFallbackPath {
            flags |= _subprocess_spawn_flag_setsid()
        }
        let flagsResult = _subprocess_spawnattr_setflags(spawnAttributes, flags)
        guard flagsResult == 0 else { throw spawnFailure(flagsResult) }

        #if canImport(Darwin)
        // The shim accepts only QOS_CLASS_UTILITY or QOS_CLASS_BACKGROUND, and
        // returns EINVAL for anything else.
        if self.platformOptions.qualityOfService == .utility {
            let result = _subprocess_spawnattr_set_qos_class(
                spawnAttributes, CInt(QOS_CLASS_UTILITY.rawValue)
            )
            guard result == 0 else { throw spawnFailure(result) }
        } else if self.platformOptions.qualityOfService == .background {
            let result = _subprocess_spawnattr_set_qos_class(
                spawnAttributes, CInt(QOS_CLASS_BACKGROUND.rawValue)
            )
            guard result == 0 else { throw spawnFailure(result) }
        }
        #endif

        // Last, so a caller can override anything set above. The handles are
        // rebound to the platform's own spelling here, at the single point where
        // the public API needs a typed pointer.
        if let configurator = self.platformOptions.preSpawnProcessConfigurator {
            #if canImport(Darwin)
            // Darwin's signature predates this refactor and is unchanged.
            let attributesPointer = spawnAttributes.assumingMemoryBound(
                to: posix_spawnattr_t?.self
            )
            let actionsPointer = fileActions.assumingMemoryBound(
                to: posix_spawn_file_actions_t?.self
            )
            try configurator(&attributesPointer.pointee, &actionsPointer.pointee)
            #else
            try configurator(
                spawnAttributes.assumingMemoryBound(to: PlatformSpawnAttributes.Pointee.self),
                fileActions.assumingMemoryBound(to: PlatformSpawnFileActions.Pointee.self)
            )
            #endif
        }

        return try await body(fileActions, spawnAttributes)
    }
}

extension Configuration {
    /// Spawns with `posix_spawn`, retrying a transient failure.
    ///
    /// `EAGAIN` here is the libc's internal fork failing with no child created,
    /// which is the clean, retryable case.
    private func spawnViaPosixSpawn(
        executablePath: String,
        spawnContext: SpawnContext
    ) async throws(SubprocessError) -> SpawnOutcome {
        SpawnCapabilities.spawnPathTallyForTesting?.recordPosixSpawn()
        return try await self.runSpawnAttemptsRetryingTransientFailure {
            () async throws(SubprocessError) -> SpawnOutcome in
            return try await runOnBackgroundThread {
                return executablePath._withCString { exePath in
                    var pid: pid_t = 0
                    var processDescriptor: PlatformFileDescriptor = .invalidDescriptor
                    let rc = _subprocess_spawn(
                        &pid,
                        &processDescriptor,
                        exePath,
                        spawnContext.fileActions,
                        spawnContext.spawnAttributes,
                        spawnContext.argv,
                        spawnContext.env
                    )
                    return SpawnOutcome(pid: pid, processDescriptor: processDescriptor, error: rc)
                }
            }
        } shouldRetryTransientFailure: { outcome in
            return outcome.error == EAGAIN
        }
    }

    /// Spawns without `posix_spawn` alone: `fork`/`exec`, or on Darwin a `fork`
    /// followed by `posix_spawn(POSIX_SPAWN_SETEXEC)` so Darwin never reaches a
    /// raw `execve`.
    ///
    /// The backoff runs here, in the async context between worker-thread
    /// invocations, not inside the shim: the shim holds a process-wide fork lock
    /// with signals blocked and the worker is a single shared executor, so
    /// sleeping in either would stall every other spawn.
    private func spawnViaFallbackPath(
        executablePath: String,
        spawnContext: SpawnContext,
        stdio: StdioDescriptors,
        supplementaryGroups: [gid_t]?
    ) async throws(SubprocessError) -> SpawnOutcome {
        SpawnCapabilities.spawnPathTallyForTesting?.recordFallback()
        let fileDescriptors = stdio.forkExecArray
        return try await self.runSpawnAttemptsRetryingTransientFailure {
            () async throws(SubprocessError) -> SpawnOutcome in
            return try await runOnBackgroundThread { () throws(SubprocessError) in
                return try executablePath._withCString { exePath throws(SubprocessError) in
                    #if canImport(Darwin)
                    // Unlike `posix_spawn`, the pre-fork path needs real
                    // attributes to add `POSIX_SPAWN_SETEXEC` to. Darwin always
                    // builds them (`fallbackPathUsesSpawnAttributes`), so this is
                    // never nil; report `EINVAL` rather than trapping if that
                    // ever changes.
                    guard let spawnAttributes = spawnContext.spawnAttributes else {
                        return SpawnOutcome(
                            pid: 0,
                            processDescriptor: .invalidDescriptor,
                            error: EINVAL
                        )
                    }
                    return supplementaryGroups.withOptionalUnsafeBufferPointer { sgroups in
                        var pid: pid_t = 0
                        let rc = _subprocess_spawn_prefork(
                            &pid,
                            exePath,
                            spawnContext.fileActions,
                            spawnAttributes,
                            spawnContext.argv,
                            spawnContext.env,
                            spawnContext.uidPtr,
                            spawnContext.gidPtr,
                            CInt(supplementaryGroups?.count ?? 0),
                            sgroups?.baseAddress,
                            self.platformOptions.createSession ? 1 : 0
                        )
                        // Darwin has no process descriptors.
                        return SpawnOutcome(
                            pid: pid,
                            processDescriptor: .invalidDescriptor,
                            error: rc
                        )
                    }
                    #else
                    // `withOptionalCString` is the outermost of the three
                    // because it is the only one of them that can throw, and
                    // the other two take non-throwing closures.
                    return try (self.workingDirectory?.string).withOptionalCString { workingDir in
                        return supplementaryGroups.withOptionalUnsafeBufferPointer { sgroups in
                            return fileDescriptors.withUnsafeBufferPointer { fds in
                                var pid: pid_t = 0
                                var processDescriptor: PlatformFileDescriptor = .invalidDescriptor
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
                                return SpawnOutcome(
                                    pid: pid,
                                    processDescriptor: processDescriptor,
                                    error: rc
                                )
                            }
                        }
                    }
                    #endif
                }
            }
        } shouldRetryTransientFailure: { outcome in
            // Retry only a transient fork-side EAGAIN. `.invalidDescriptor`
            // means the kernel created nothing, so re-attempting is clean; an
            // exec-side failure carries a descriptor for a child the shim has
            // already reaped, and is left for the caller to handle.
            //
            // On Darwin there is never a descriptor, and the pre-fork path can
            // carry a child on failure, so nothing is retried there.
            #if canImport(Darwin)
            return false
            #else
            return outcome.error == EAGAIN && outcome.processDescriptor == .invalidDescriptor
            #endif
        }
    }
}

extension Configuration {
    /// Resolves the requested working directory in the parent.
    ///
    /// A chdir file action needs a directory descriptor, and obtaining it here —
    /// or, where the platform cannot obtain a suitable one, checking the
    /// directory here — is what turns a bad working directory into a precise
    /// error rather than an indistinguishable spawn failure. It happens on the
    /// fallback path too, which applies the directory itself in the child and so
    /// needs no descriptor: without this the child's `chdir` errno is
    /// indistinguishable from a failed `exec`, and a bad directory would be
    /// reported as a missing executable.
    ///
    /// - Returns: A descriptor for an `fchdir` file action, or
    ///   `.invalidDescriptor` when none was requested or this platform validated
    ///   the directory without opening it; and the `errno` the caller must report
    ///   as ``SubprocessError/failedToChangeWorkingDirectory(_:underlyingError:)``,
    ///   or 0 on success. A nonzero `errno` is always paired with
    ///   `.invalidDescriptor`.
    private func resolveWorkingDirectory() -> (PlatformFileDescriptor, CInt) {
        guard let workingDirectory = self.workingDirectory?.string else {
            return (.invalidDescriptor, 0)
        }

        // Both branches capture `errno` inside the closure, before
        // `withPlatformString` tears its buffer down, so nothing between the
        // failed call and the read can clobber it.
        if _subprocess_can_open_directory_for_search() != 0 {
            // The flags include `O_CLOEXEC`, which is safe: the descriptor is
            // still live while file actions run, which was measured under
            // CLOEXEC_DEFAULT on Darwin.
            return workingDirectory.withPlatformString {
                (path) -> (PlatformFileDescriptor, CInt) in
                let descriptor = open(path, _subprocess_open_directory_flags())
                guard descriptor != .invalidDescriptor else {
                    return (.invalidDescriptor, errno)
                }
                // The open alone does not prove the directory is searchable.
                // Only a real `O_SEARCH` (Darwin, FreeBSD) checks execute
                // permission; where the flags fall back to `O_PATH` (glibc,
                // musl, Bionic) the kernel zeroes `acc_mode` and checks nothing
                // about the target, so a directory with no execute permission
                // opens successfully and the `fchdir` action then fails EACCES
                // in the child. That errno is one of the try-the-next-candidate
                // set, so it would be reported as `executableNotFound` -- the
                // very misdiagnosis opening the directory here is meant to
                // remove.
                //
                // Checked against the descriptor rather than the path, so it
                // cannot be a different object than the one `fchdir` will use,
                // and with the effective-IDs flag where the platform has one, so
                // a set-uid host is judged by the IDs the child is judged by. Run
                // on every platform: it is one syscall, and where the open
                // already enforced this it simply succeeds.
                guard
                    faccessat(descriptor, ".", X_OK, _subprocess_faccessat_eaccess_flag()) == 0
                else {
                    let permissionError = errno
                    _ = close(descriptor)
                    return (.invalidDescriptor, permissionError)
                }
                return (descriptor, 0)
            }
        }

        // This platform can only open a directory for reading, which `chdir` does
        // not require, so opening it would reject a directory that works
        // perfectly well as a working directory. It also has no `fchdir` file
        // action, so rule 5 of `requiresFallbackSpawnPath` always routes a
        // working directory to the fallback path, where the child `chdir`s itself
        // and no descriptor is ever needed. Check the directory instead of
        // opening it.
        //
        // This check is advisory only, and must not be mistaken for a permission
        // check. The child's `chdir` stays authoritative and its failure is still
        // reported, so the TOCTOU window between here and that `chdir` is
        // acceptable: the check exists purely to turn the common case into a
        // precise error instead of `executableNotFound`.
        let validationError = workingDirectory.withPlatformString { (path) -> CInt in
            var status = stat()
            // 1. Absent, or reached through a path component that is not a
            //    directory.
            guard stat(path, &status) == 0 else {
                return errno
            }
            // 2. Present, but not a directory. An executable-permission check
            //    alone would accept an executable regular file.
            guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                return ENOTDIR
            }
            // 3. A directory, but not searchable. `faccessat` with the
            //    effective-IDs flag rather than `access`, so the check uses the
            //    IDs the child's `chdir` will be judged by: a set-uid host process
            //    would otherwise reject a directory `chdir` accepts.
            guard faccessat(AT_FDCWD, path, X_OK, _subprocess_faccessat_eaccess_flag()) == 0 else {
                return errno
            }
            return 0
        }
        return (.invalidDescriptor, validationError)
    }
}

extension Configuration {
    internal func spawn(
        withInput inputPipe: consuming CreatedPipe,
        outputPipe: consuming CreatedPipe,
        errorPipe: consuming CreatedPipe
    ) async throws -> SpawnResult {
        // Ensure the waiter thread is running.
        _setupMonitorSignalHandler()

        var inputPipeBox: CreatedPipe? = consume inputPipe
        var outputPipeBox: CreatedPipe? = consume outputPipe
        var errorPipeBox: CreatedPipe? = consume errorPipe

        func spawnFunc(_ args: PreSpawnArgs) async throws -> SpawnResult {
            let (env, uidPtr, gidPtr, supplementaryGroups) = args

            // Resolve before taking the pipes out of their boxes, so that a
            // rejected executable name leaves them for the caller's `catch`
            // below to close.
            //
            // Instead of checking if every possible executable path
            // is valid, spawn each directly and catch ENOENT
            let possiblePaths = try self.executable.possibleExecutablePaths(
                withPathValue: self.environment.pathValue()
            )

            let capabilities = SpawnCapabilities.current
            let usesFallbackPath = self.requiresFallbackSpawnPath(
                supplementaryGroups: supplementaryGroups,
                capabilities: capabilities
            )
            // On Darwin the fallback path execs through
            // posix_spawn(POSIX_SPAWN_SETEXEC), so it needs file actions and
            // attributes too. Elsewhere the fallback does its own child-side
            // setup and needs neither.
            let buildsSpawnAttributes = fallbackPathUsesSpawnAttributes || !usesFallbackPath

            var _inputPipe = inputPipeBox.take()!
            var _outputPipe = outputPipeBox.take()!
            var _errorPipe = errorPipeBox.take()!

            let inputReadFileDescriptor: IODescriptor? = _inputPipe.readFileDescriptor()
            let inputWriteFileDescriptor: IODescriptor? = _inputPipe.writeFileDescriptor()
            let outputReadFileDescriptor: IODescriptor? = _outputPipe.readFileDescriptor()
            let outputWriteFileDescriptor: IODescriptor? = _outputPipe.writeFileDescriptor()
            let errorReadFileDescriptor: IODescriptor? = _errorPipe.readFileDescriptor()
            let errorWriteFileDescriptor: IODescriptor? = _errorPipe.writeFileDescriptor()

            let stdio = StdioDescriptors(
                inputRead: inputReadFileDescriptor?.platformDescriptor(),
                inputWrite: inputWriteFileDescriptor?.platformDescriptor(),
                outputWrite: outputWriteFileDescriptor?.platformDescriptor(),
                outputRead: outputReadFileDescriptor?.platformDescriptor(),
                errorWrite: errorWriteFileDescriptor?.platformDescriptor(),
                errorRead: errorReadFileDescriptor?.platformDescriptor()
            )

            // Resolving the working directory in the parent is what makes a bad
            // one a precise error instead of an indistinguishable spawn failure,
            // and it replaces the old "guess whether exec or chdir failed"
            // recovery. The six descriptors are closed here, at the call site,
            // so `resolveWorkingDirectory()` stays free of their ownership.
            let (workingDirectoryDescriptor, workingDirectoryError) =
                self.resolveWorkingDirectory()
            defer {
                if workingDirectoryDescriptor != .invalidDescriptor {
                    try? _safelyClose(
                        .fileDescriptor(FileDescriptor(rawValue: workingDirectoryDescriptor))
                    )
                }
            }
            if workingDirectoryError != 0 {
                try self.safelyCloseMultiple(
                    inputRead: inputReadFileDescriptor,
                    inputWrite: inputWriteFileDescriptor,
                    outputRead: outputReadFileDescriptor,
                    outputWrite: outputWriteFileDescriptor,
                    errorRead: errorReadFileDescriptor,
                    errorWrite: errorWriteFileDescriptor
                )
                throw SubprocessError.failedToChangeWorkingDirectory(
                    self.workingDirectory?.string,
                    underlyingError: Errno(rawValue: workingDirectoryError)
                )
            }

            for possibleExecutablePath in possiblePaths {
                var processGroupIDPtr: UnsafeMutablePointer<gid_t>? = nil
                if let processGroupID = self.platformOptions.processGroupID {
                    processGroupIDPtr = .allocate(capacity: 1)
                    processGroupIDPtr?.pointee = gid_t(processGroupID)
                }
                defer { processGroupIDPtr?.deallocate() }

                // Setup Arguments
                let argv: [UnsafeMutablePointer<CChar>?] = self.arguments.createArgs(
                    withExecutablePath: possibleExecutablePath
                )
                defer {
                    for ptr in argv { ptr?.deallocate() }
                }

                let outcome: SpawnOutcome
                do {
                    // `nonisolated(nonsending)` so this inherits the caller's
                    // isolation instead of hopping to the global executor. Without
                    // it, Swift 6.2 treats a nested `async` function as
                    // `@concurrent` and rejects the call: `argv`, `env` and the
                    // uid/gid/file-action pointers it captures are not `Sendable`,
                    // so reaching a `@concurrent` callee would mean sending them.
                    // Nothing here needs its own executor -- it only forwards to
                    // one of the two spawn paths.
                    nonisolated(nonsending) func runSpawn(
                        fileActions: UnsafeMutableRawPointer?,
                        spawnAttributes: UnsafeMutableRawPointer?
                    ) async throws -> SpawnOutcome {
                        let spawnContext = SpawnContext(
                            argv: argv,
                            env: env,
                            uidPtr: uidPtr,
                            gidPtr: gidPtr,
                            processGroupIDPtr: processGroupIDPtr,
                            fileActions: fileActions,
                            spawnAttributes: spawnAttributes
                        )
                        if usesFallbackPath {
                            return try await self.spawnViaFallbackPath(
                                executablePath: possibleExecutablePath,
                                spawnContext: spawnContext,
                                stdio: stdio,
                                supplementaryGroups: supplementaryGroups
                            )
                        }
                        return try await self.spawnViaPosixSpawn(
                            executablePath: possibleExecutablePath,
                            spawnContext: spawnContext
                        )
                    }

                    if buildsSpawnAttributes {
                        outcome = try await self.withSpawnAttributes(
                            stdio: stdio,
                            workingDirectoryDescriptor: workingDirectoryDescriptor,
                            capabilities: capabilities,
                            usesFallbackPath: usesFallbackPath
                        ) { fileActions, spawnAttributes in
                            try await runSpawn(
                                fileActions: fileActions,
                                spawnAttributes: spawnAttributes
                            )
                        }
                    } else {
                        outcome = try await runSpawn(fileActions: nil, spawnAttributes: nil)
                    }
                } catch {
                    // Building the file actions or attributes failed, or the
                    // caller's configurator threw. Nothing was spawned.
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

                if outcome.error != 0 {
                    if [ENOENT, EACCES, ENOTDIR].contains(outcome.error) {
                        // clone3(CLONE_PIDFD) and pdfork() allocate a process
                        // descriptor before exec runs, so a failed exec can
                        // leave one behind. Close it before trying the next
                        // candidate path rather than leaking it across retries.
                        // Only the fallback path can reach this: on the
                        // posix_spawn path the descriptor is opened only after
                        // the spawn has already succeeded.
                        if outcome.processDescriptor != .invalidDescriptor {
                            do throws(SubprocessError) {
                                try _safelyClose(
                                    .fileDescriptor(
                                        FileDescriptor(rawValue: outcome.processDescriptor)
                                    )
                                )
                            } catch {
                                // Leaving here without closing the six stdio
                                // descriptors would fatal-error in their
                                // `deinit`, and the outer handler cannot help:
                                // the pipe boxes have already been emptied.
                                try self.safelyCloseMultiple(
                                    inputRead: inputReadFileDescriptor,
                                    inputWrite: inputWriteFileDescriptor,
                                    outputRead: outputReadFileDescriptor,
                                    outputWrite: outputWriteFileDescriptor,
                                    errorRead: errorReadFileDescriptor,
                                    errorWrite: errorWriteFileDescriptor
                                )
                                throw SubprocessError.spawnFailed(
                                    withUnderlyingError: error.underlyingError
                                )
                            }
                        }
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
                    // A fork/clone3 that succeeded but failed to execve still
                    // produced a process descriptor. The retry discriminator has
                    // already run on this outcome, so closing it here cannot
                    // make the exec-side failure look fork-side. Unlike the
                    // branch above, close best-effort (mirroring
                    // ProcessIdentifier.close()) so the spawn error remains as
                    // the thrown error. This comes after the safelyCloseMultiple
                    // call, since if that throws, the worst case here is one
                    // process descriptor leaking; otherwise, if this came first
                    // and threw, the worst case would be six fds never closing
                    // and their deinit methods fatal-erroring.
                    if outcome.processDescriptor != .invalidDescriptor {
                        try? _safelyClose(
                            .fileDescriptor(FileDescriptor(rawValue: outcome.processDescriptor))
                        )
                    }
                    throw SubprocessError.spawnFailed(
                        withUnderlyingError: Errno(rawValue: outcome.error)
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

                return SpawnResult(
                    processIdentifier: ProcessIdentifier(
                        value: outcome.pid,
                        processDescriptor: outcome.processDescriptor
                    ),
                    inputWriteEnd: inputWriteFileDescriptor,
                    outputReadEnd: outputReadFileDescriptor,
                    errorReadEnd: errorReadFileDescriptor
                )
            }

            // Every candidate path failed with ENOENT, EACCES or ENOTDIR. The
            // working directory has already been checked above — by opening it,
            // or, where no search-only open is available, by `stat` and
            // `faccessat` — so the remaining explanation is that the executable
            // does not exist.
            try self.safelyCloseMultiple(
                inputRead: inputReadFileDescriptor,
                inputWrite: inputWriteFileDescriptor,
                outputRead: outputReadFileDescriptor,
                outputWrite: outputWriteFileDescriptor,
                errorRead: errorReadFileDescriptor,
                errorWrite: errorWriteFileDescriptor
            )
            throw SubprocessError.executableNotFound(
                self.executable.description,
                underlyingError: Errno(rawValue: ENOENT)
            )
        }

        do {
            return try await self.preSpawn(spawnFunc)
        } catch {
            var _inputPipe = inputPipeBox.take()
            var _outputPipe = outputPipeBox.take()
            var _errorPipe = errorPipeBox.take()
            // If any part of spawning failed, make sure we clean up pipes
            try? self.safelyCloseMultiple(
                inputRead: _inputPipe?.readFileDescriptor(),
                inputWrite: _inputPipe?.writeFileDescriptor(),
                outputRead: _outputPipe?.readFileDescriptor(),
                outputWrite: _outputPipe?.writeFileDescriptor(),
                errorRead: _errorPipe?.readFileDescriptor(),
                errorWrite: _errorPipe?.writeFileDescriptor()
            )

            throw error
        }
    }
}

#endif // canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl)
