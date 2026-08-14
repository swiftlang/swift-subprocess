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

#if !os(Windows)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#endif

import Testing
import _SubprocessCShims

@testable import Subprocess

#if canImport(System)
import System
#else
import SystemPackage
#endif

@Suite(.serialized)
struct SpawnPathTests {
    /// The two close-all mechanisms are mutually exclusive, and a decoded
    /// bitmask round-trips.
    @Test func testCapabilityBitmaskDecoding() {
        let none = SpawnCapabilities(bitmask: 0)
        #expect(none.closeAllViaSpawn == .unavailable)
        #expect(!none.hasChdirAction)
        #expect(!none.hasSetsidFlag)

        let cloexec = SpawnCapabilities(bitmask: 1 << 0)
        #expect(cloexec.closeAllViaSpawn == .cloexecDefault)

        let closefrom = SpawnCapabilities(bitmask: 1 << 1)
        #expect(closefrom.closeAllViaSpawn == .closefromAction)

        // `CLOEXEC_DEFAULT` wins when a platform somehow reports both, since it
        // needs no file action and so cannot fail mid-append.
        let both = SpawnCapabilities(bitmask: (1 << 0) | (1 << 1))
        #expect(both.closeAllViaSpawn == .cloexecDefault)

        let all = SpawnCapabilities(bitmask: 0b1111)
        #expect(all.hasChdirAction)
        #expect(all.hasSetsidFlag)
    }

    /// The probe is resolved once and cached, so repeated reads agree.
    @Test func testCapabilitiesAreStable() {
        let first = SpawnCapabilities.current
        let second = SpawnCapabilities.current
        #expect(first.closeAllViaSpawn == second.closeAllViaSpawn)
        #expect(first.hasChdirAction == second.hasChdirAction)
        #expect(first.hasSetsidFlag == second.hasSetsidFlag)
    }

    /// What the host platform must report. The Linux case is deliberately an
    /// invariant rather than an equality: CI spans glibc 2.26 through 2.39 and
    /// musl, which land in different buckets.
    @Test func testCapabilitiesMatchHostPlatform() {
        let capabilities = SpawnCapabilities.current
        #if canImport(Darwin)
        #expect(capabilities.closeAllViaSpawn == .cloexecDefault)
        #expect(capabilities.hasChdirAction)
        #expect(capabilities.hasSetsidFlag)
        #elseif os(OpenBSD)
        // OpenBSD has no closefrom file action, no chdir action and no SETSID
        // flag, so it can never use posix_spawn.
        #expect(capabilities.closeAllViaSpawn == .unavailable)
        #expect(!capabilities.hasChdirAction)
        #expect(!capabilities.hasSetsidFlag)
        #elseif os(FreeBSD)
        // addclosefrom_np and the chdir actions all arrived in FreeBSD 13.1,
        // which is below the oldest version this package supports. SETSID has
        // no FreeBSD equivalent.
        #expect(capabilities.closeAllViaSpawn == .closefromAction)
        #expect(capabilities.hasChdirAction)
        #expect(!capabilities.hasSetsidFlag)
        #elseif os(Linux) || os(Android)
        // No Linux libc offers a closefrom action without also offering the
        // chdir actions: glibc added chdir at 2.29 and closefrom at 2.34.
        if capabilities.closeAllViaSpawn == .closefromAction {
            #expect(capabilities.hasChdirAction)
        }
        // Only Bionic exposes CLOEXEC_DEFAULT.
        #if !os(Android)
        #expect(capabilities.closeAllViaSpawn != .cloexecDefault)
        #endif
        #endif
    }

    /// The shim spawns on every Unix platform and reports a process descriptor
    /// where the platform has one.
    ///
    /// The file actions and attributes are built with the same shim entry points
    /// production uses, rather than by declaring `posix_spawn_file_actions_t` and
    /// `posix_spawnattr_t` values here. That is both what this test means to
    /// cover and the only portable spelling: the libcs differ on whether Swift
    /// imports these `init` functions as taking a pointer to an optional, so a
    /// value declared in Swift compiles on some platforms and not others.
    @Test func testSubprocessSpawnShimRunsAProcess() throws {
        var fileActionsError: CInt = 0
        let fileActions = try #require(
            _subprocess_spawn_file_actions_create(&fileActionsError)
        )
        #expect(fileActionsError == 0)
        defer { _subprocess_spawn_file_actions_free(fileActions) }

        var attributesError: CInt = 0
        let attributes = try #require(_subprocess_spawnattr_create(&attributesError))
        #expect(attributesError == 0)
        defer { _subprocess_spawnattr_free(attributes) }

        // `sh -c 'exit 7'` so the exit code proves the child really ran the
        // program rather than dying some other way.
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"), strdup("-c"), strdup("exit 7"), nil,
        ]
        defer { for pointer in argv { free(pointer) } }
        let environment: [UnsafeMutablePointer<CChar>?] = [nil]

        var pid: pid_t = 0
        var processDescriptor: CInt = 0
        let rc = _subprocess_spawn(
            &pid,
            &processDescriptor,
            "/bin/sh",
            fileActions,
            attributes,
            argv,
            environment
        )
        #expect(rc == 0)
        #expect(pid > 0)

        #if os(Linux) || os(Android)
        // pidfd_open is available from kernel 5.3. Below that the shim reports
        // -1 and SIGCHLD monitoring takes over, so both are acceptable; what
        // must not happen is some other value.
        #expect(processDescriptor >= 0 || processDescriptor == -1)
        #else
        #expect(processDescriptor == -1)
        #endif
        if processDescriptor >= 0 {
            #expect(close(processDescriptor) == 0)
        }

        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED) == -1 && errno == EINTR {}
        #expect(info.si_status == 7)
    }

    private func configuration(
        workingDirectory: FilePath? = nil,
        userID: uid_t? = nil,
        groupID: gid_t? = nil,
        processGroupID: pid_t? = nil,
        createSession: Bool = false
    ) -> Configuration {
        var options = PlatformOptions()
        options.userID = userID
        options.groupID = groupID
        options.processGroupID = processGroupID
        options.createSession = createSession
        return Configuration(
            executable: .path("/bin/sh"),
            workingDirectory: workingDirectory,
            platformOptions: options
        )
    }

    /// Capabilities of a platform where posix_spawn can express everything:
    /// modern glibc, or Darwin.
    private static let fullyCapable = SpawnCapabilities(bitmask: 0b1111)

    @Test func testPosixSpawnIsUsedWhenNothingBlocksIt() {
        let configuration = self.configuration()
        #expect(
            !configuration.requiresFallbackSpawnPath(
                supplementaryGroups: nil,
                capabilities: Self.fullyCapable
            )
        )
    }

    /// Rule 1: no platform has a posix_spawn attribute for setuid, setgid or
    /// setgroups.
    @Test func testPrivilegeChangesRequireTheFallbackPath() {
        for configuration in [
            self.configuration(userID: 501),
            self.configuration(groupID: 20),
        ] {
            #expect(
                configuration.requiresFallbackSpawnPath(
                    supplementaryGroups: nil,
                    capabilities: Self.fullyCapable
                )
            )
        }
        #expect(
            self.configuration().requiresFallbackSpawnPath(
                supplementaryGroups: [20],
                capabilities: Self.fullyCapable
            )
        )
        // An empty array is not a request to change anything.
        #expect(
            !self.configuration().requiresFallbackSpawnPath(
                supplementaryGroups: [],
                capabilities: Self.fullyCapable
            )
        )
    }

    /// Rule 2: with no libc close-all mechanism, descriptors could only be
    /// closed by enumerating them in the parent, which races with other threads
    /// opening descriptors.
    @Test func testNoCloseAllMechanismRequiresTheFallbackPath() {
        let capabilities = SpawnCapabilities(bitmask: 0b1100) // chdir + setsid only
        #expect(capabilities.closeAllViaSpawn == .unavailable)
        #expect(
            self.configuration().requiresFallbackSpawnPath(
                supplementaryGroups: nil,
                capabilities: capabilities
            )
        )
    }

    /// Rule 3: FreeBSD and OpenBSD have no POSIX_SPAWN_SETSID.
    @Test func testCreateSessionWithoutSetsidFlagRequiresTheFallbackPath() {
        let capabilities = SpawnCapabilities(bitmask: 0b0110) // closefrom + chdir, no setsid
        #expect(!capabilities.hasSetsidFlag)
        #expect(
            self.configuration(createSession: true).requiresFallbackSpawnPath(
                supplementaryGroups: nil,
                capabilities: capabilities
            )
        )
        // Without createSession the missing flag is irrelevant.
        #expect(
            !self.configuration().requiresFallbackSpawnPath(
                supplementaryGroups: nil,
                capabilities: capabilities
            )
        )
    }

    /// Rule 4: the libcs disagree on whether setsid or setpgid runs first, and
    /// the wrong order makes setsid fail with EPERM. The fallback path controls
    /// the order explicitly.
    @Test func testCreateSessionWithProcessGroupRequiresTheFallbackPath() {
        #expect(
            self.configuration(processGroupID: 0, createSession: true)
                .requiresFallbackSpawnPath(
                    supplementaryGroups: nil,
                    capabilities: Self.fullyCapable
                )
        )
        // Either one alone is fine.
        #expect(
            !self.configuration(processGroupID: 0).requiresFallbackSpawnPath(
                supplementaryGroups: nil,
                capabilities: Self.fullyCapable
            )
        )
        #expect(
            !self.configuration(createSession: true).requiresFallbackSpawnPath(
                supplementaryGroups: nil,
                capabilities: Self.fullyCapable
            )
        )
    }

    /// Rule 5: OpenBSD has no chdir action, and Android gained one only at API 34.
    @Test func testWorkingDirectoryWithoutChdirActionRequiresTheFallbackPath() {
        let capabilities = SpawnCapabilities(bitmask: 0b1010) // closefrom + setsid, no chdir
        #expect(!capabilities.hasChdirAction)
        #expect(
            self.configuration(workingDirectory: "/tmp").requiresFallbackSpawnPath(
                supplementaryGroups: nil,
                capabilities: capabilities
            )
        )
        #expect(
            !self.configuration().requiresFallbackSpawnPath(
                supplementaryGroups: nil,
                capabilities: capabilities
            )
        )
    }

    /// The test override forces the fallback path even when posix_spawn could
    /// express everything, and is scoped to the task that set it.
    @Test func testForceFallbackPathOverride() {
        #expect(
            SpawnCapabilities.forceFallbackPathOverride.withValue(true) {
                self.configuration().requiresFallbackSpawnPath(
                    supplementaryGroups: nil,
                    capabilities: Self.fullyCapable
                )
            }
        )
        // Outside the scope the override is gone again.
        #expect(
            !self.configuration().requiresFallbackSpawnPath(
                supplementaryGroups: nil,
                capabilities: Self.fullyCapable
            )
        )
    }

    /// Both spawn paths run a program, wire up stdout, and report the exit
    /// status the same way.
    ///
    /// The tally is what makes this meaningful: it asserts the override actually
    /// reached path selection, rather than the two cases silently taking the same
    /// path.
    ///
    /// The expectation is derived from `requiresFallbackSpawnPath` rather than
    /// from `forceFallback` alone, because the unforced case legitimately takes
    /// the fallback wherever this platform's `posix_spawn` cannot express the
    /// request -- glibc below 2.34 and Android below API 34 have no way to close
    /// every inherited descriptor, for instance. Computed outside the override's
    /// scope so the task-local does not feed back into the rules.
    @Test(arguments: [false, true])
    func testBothSpawnPathsProduceTheSameResult(forceFallback: Bool) async throws {
        let expectsFallback =
            forceFallback
            || self.configuration().requiresFallbackSpawnPath(supplementaryGroups: nil)
        let tally = SpawnPathTally()
        let result = try await SpawnCapabilities.forceFallbackPathOverride.withValue(forceFallback) {
            try await SpawnCapabilities.spawnPathTallyOverride.withValue(tally) {
                try await Subprocess.run(
                    .path("/bin/sh"),
                    arguments: ["-c", "printf hello; exit 3"],
                    output: .string(limit: 16)
                )
            }
        }
        #expect(result.terminationStatus == .exited(3))
        #expect(result.standardOutput == "hello")
        #expect(tally.fallback == (expectsFallback ? 1 : 0))
        #expect(tally.posixSpawn == (expectsFallback ? 0 : 1))
    }

    #if !os(Android) // Exit tests are not supported on Android.
    /// A child's standard streams survive even when the parent's ends of the
    /// pipes land on descriptors 0, 1 and 2.
    ///
    /// `posix_spawn` runs file actions in the order they were appended, so an
    /// `addclose` of a parent end that happens to be numbered 0, 1 or 2 must be
    /// appended *before* the `adddup2` that binds a child end to the same
    /// number. Appended after, it closes the stream the dup2 just created and
    /// the child loses it — silently, since nothing else in the suite runs with
    /// a standard descriptor closed.
    ///
    /// The parent's ends only take those numbers when the calling process has a
    /// low descriptor free, which is why this closes them deliberately. All
    /// eight combinations are covered: which parent end lands on which number
    /// depends on the order the pipes are created in and on how many are closed,
    /// so no single combination exercises every pairing.
    ///
    /// Runs inside an exit test because closing 0, 1 or 2 is process-wide state.
    /// Suites run concurrently with each other, so doing this in-process would
    /// let a sibling suite's pipe be allocated onto the closed number and then
    /// be clobbered by the restoring `dup2`. Isolation also means a mistake here
    /// cannot leave the rest of the suite running with a closed stderr.
    ///
    /// Both spawn paths are covered by a loop *inside* the exit test rather than
    /// by `@Test(arguments:)`: passing a value into the body would need a capture
    /// clause, which `#expect(processExitsWith:)` rejects on Swift 6.2.
    @Test func testStandardStreamsSurviveLowParentDescriptors() async {
        await #expect(processExitsWith: .success) {
            // Spawn once before closing anything, so that any descriptor the
            // spawning machinery opens for the lifetime of the process (the
            // kqueue or epoll descriptor, the monitoring pipe) is already
            // allocated and cannot land on a number this test later restores.
            _ = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "exit 0"],
                output: .discarded,
                error: .discarded
            )

            for forceFallback in [false, true] {
                // Derived from the same rule the implementation consults, not
                // from `forceFallback` alone: where this platform's `posix_spawn`
                // cannot express the request, the unforced case takes the
                // fallback too. Built inline rather than through the suite's
                // helper because an exit test body cannot capture `self`.
                let expectsFallback =
                    forceFallback
                    || Configuration(executable: .path("/bin/sh"))
                        .requiresFallbackSpawnPath(supplementaryGroups: nil)

                for closedMask in 0..<8 {
                    // Take a copy of each descriptor about to be closed, and put
                    // it back before the next iteration.
                    var saved: [(target: CInt, copy: CInt)] = []
                    for target in CInt(0)...CInt(2) where closedMask & (1 << Int(target)) != 0 {
                        let copy = dup(target)
                        // A standard descriptor the test runner did not give us is
                        // nothing this test can close and restore; skip it rather
                        // than closing a descriptor it cannot put back.
                        guard copy >= 0 else { continue }
                        guard close(target) == 0 else {
                            close(copy)
                            continue
                        }
                        saved.append((target, copy))
                    }
                    defer {
                        for (target, copy) in saved {
                            _ = dup2(copy, target)
                            _ = close(copy)
                        }
                    }

                    // Exercises all three streams at once: standard input has to
                    // arrive for the child to echo it, and both of the child's
                    // output streams have to reach the parent.
                    let tally = SpawnPathTally()
                    let result = try await SpawnCapabilities.forceFallbackPathOverride
                        .withValue(forceFallback) {
                            try await SpawnCapabilities.spawnPathTallyOverride.withValue(tally) {
                                try await Subprocess.run(
                                    .path("/bin/sh"),
                                    arguments: [
                                        "-c", #"read line; printf "IN=%s" "$line"; printf ERR 1>&2"#,
                                    ],
                                    input: .string("ping\n"),
                                    output: .string(limit: 64),
                                    error: .string(limit: 64)
                                )
                            }
                        }

                    let context =
                        "with descriptors \(saved.map(\.target)) closed, forceFallback \(forceFallback)"
                    // A child that lost a standard stream fails on the
                    // redirection rather than exiting cleanly, so the status is
                    // as much a symptom as the missing output.
                    #expect(result.terminationStatus == .exited(0), "\(context)")
                    #expect(result.standardOutput == "IN=ping", "\(context)")
                    #expect(result.standardError == "ERR", "\(context)")
                    #expect(tally.fallback == (expectsFallback ? 1 : 0), "\(context)")
                    #expect(tally.posixSpawn == (expectsFallback ? 0 : 1), "\(context)")
                }
            }
        }
    }
    #endif // !os(Android)
}
#endif // !os(Windows)
