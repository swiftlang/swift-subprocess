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
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import _SubprocessCShims
import Testing
@testable import Subprocess

import TestResources

#if canImport(System)
import System
#else
import SystemPackage
#endif

@Suite(.serialized)
struct SubprocessUnixTests {
    init() {
        _ = globallyIgnoredSIGPIPE
    }
}

// MARK: - PlatformOption Tests
extension SubprocessUnixTests {
    // Run this test with sudo
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsUserID() async throws {
        let expectedUserID = uid_t(Int.random(in: 1000...2000))
        var platformOptions = PlatformOptions()
        platformOptions.userID = expectedUserID
        try await self.assertID(
            withArgument: "-u",
            platformOptions: platformOptions,
            isEqualTo: expectedUserID
        )
    }

    // Run this test with sudo
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsGroupID() async throws {
        let expectedGroupID = gid_t(Int.random(in: 1000...2000))
        var platformOptions = PlatformOptions()
        platformOptions.groupID = expectedGroupID
        try await self.assertID(
            withArgument: "-g",
            platformOptions: platformOptions,
            isEqualTo: expectedGroupID
        )
    }

    // Run this test with sudo
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsUserAndGroupID() async throws {
        // setuid() before setgid() clears CAP_SETGID on Linux (and the
        // saved-set-id privilege on Darwin/BSD), so the following setgid()
        // fails with EPERM and the spawn fails outright.
        let expectedUserID = uid_t(Int.random(in: 1000...2000))
        let expectedGroupID = gid_t(Int.random(in: 2001...3000))
        var platformOptions = PlatformOptions()
        platformOptions.userID = expectedUserID
        platformOptions.groupID = expectedGroupID
        try await self.assertID(
            withArgument: "-u",
            platformOptions: platformOptions,
            isEqualTo: expectedUserID
        )
        try await self.assertID(
            withArgument: "-g",
            platformOptions: platformOptions,
            isEqualTo: expectedGroupID
        )
    }

    // Run this test with sudo
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsSupplementaryGroups() async throws {
        var expectedGroups: Set<gid_t> = Set()
        for _ in 0..<Int.random(in: 5...10) {
            expectedGroups.insert(gid_t(Int.random(in: 1000...2000)))
        }
        var platformOptions = PlatformOptions()
        platformOptions.supplementaryGroups = Array(expectedGroups)
        // Use /usr/bin/id instead of `swift` to avoid dynamic linker
        // issues: setgroups() replaces all supplementary groups, which
        // can prevent the dynamic linker from finding libswiftCore.so
        // on systems where library paths require specific group access.
        let idResult = try await Subprocess.run(
            .path("/usr/bin/id"),
            arguments: ["-G"],
            platformOptions: platformOptions,
            output: .string(limit: .max),
            error: .string(limit: .max),
        )
        #expect(idResult.terminationStatus.isSuccess, Comment(rawValue: idResult.standardError))
        let ids =
            try idResult
            .standardOutput.split(separator: " ")
            .map { try #require(gid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))) }
        // id -G includes the effective GID (0 for root) along with
        // supplementary groups, so filter to just the expected range
        let actualGroups = Set(ids.filter { expectedGroups.contains($0) })
        #expect(actualGroups == expectedGroups, Comment(rawValue: idResult.standardError))
    }

    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        ),
        .enabled(
            "This test requires ps (install procps package on Debian or RedHat Linux distros)",
            {
                (try? await Executable.name("ps").resolveExecutablePath(in: .inherit)) != nil
            }
        ),
        arguments: [false, true]
    )
    func testSubprocessPlatformOptionsProcessGroupID(forceFallback: Bool) async throws {
        var platformOptions = PlatformOptions()
        // Sets the process group ID to 0, which creates a new session
        platformOptions.processGroupID = 0
        let expectsFallback = self.expectsFallbackPath(
            forceFallback: forceFallback, platformOptions: platformOptions
        )
        let tally = SpawnPathTally()
        let psResult = try await self.withSpawnPath(forceFallback: forceFallback, tally: tally) {
            try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "ps -o pid,pgid -p $$"],
                platformOptions: platformOptions,
                output: .string(limit: .max)
            )
        }
        self.expect(tally, tookFallbackPath: expectsFallback)
        #expect(psResult.terminationStatus.isSuccess)
        let resultValue = psResult.standardOutput
        let match = try #require(try #/\s*PID\s*PGID\s*(?<pid>[\-]?[0-9]+)\s*(?<pgid>[\-]?[0-9]+)\s*/#.wholeMatch(in: resultValue), "ps output was in an unexpected format:\n\n\(resultValue)")
        // PGID should == PID
        #expect(match.output.pid == match.output.pgid)
    }

    @Test(
        .enabled(
            "This test requires ps (install procps package on Debian or RedHat Linux distros)",
            {
                (try? await Executable.name("ps").resolveExecutablePath(in: .inherit)) != nil
            }
        ),
        arguments: [false, true]
    )
    func testSubprocessPlatformOptionsCreateSession(forceFallback: Bool) async throws {
        // platformOptions.createSession implies calls to setsid
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        let expectsFallback = self.expectsFallbackPath(
            forceFallback: forceFallback, platformOptions: platformOptions
        )
        let tally = SpawnPathTally()
        #if os(Android)
        // Android's `ps` doesn't support `-o pid,pgid,tpgid`. Read the shell's
        // session fields directly from /proc instead. `$$` is the shell's own
        // pid, which is the session and group leader after setsid; reading
        // /proc/self/stat would observe `cat`, which is not the leader.
        let statResult = try await self.withSpawnPath(forceFallback: forceFallback, tally: tally) {
            try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "cat /proc/$$/stat"],
                platformOptions: platformOptions,
                output: .string(limit: .max)
            )
        }
        self.expect(tally, tookFallbackPath: expectsFallback)
        try assertNewSessionCreated(fromProcStat: statResult)
        #else
        // Check the process ID (pid), process group ID (pgid), and
        // controlling terminal's process group ID (tpgid)
        let psResult = try await self.withSpawnPath(forceFallback: forceFallback, tally: tally) {
            try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
                platformOptions: platformOptions,
                output: .string(limit: .max)
            )
        }
        self.expect(tally, tookFallbackPath: expectsFallback)
        try assertNewSessionCreated(with: psResult)
        #endif
    }

    @Test(.requiresBash) func testTeardownSequence() async throws {
        let result = try await Subprocess.run(
            .name("bash"),
            arguments: [
                "-c",
                """
                trap 'echo saw SIGQUIT' QUIT
                trap 'echo saw SIGTERM' TERM
                trap 'echo saw SIGINT; exit 42' INT
                echo ready
                # A trapped signal interrupts `wait` immediately, so the handler runs
                # without waiting for a sleep interval to elapse, unlike a foreground
                # `sleep`, whose completion (and the trap deferred behind it) can slip
                # past the teardown window under load. The backgrounded sleep is short
                # so a signal landing as bash enters the wait is still serviced within
                # one interval rather than stranding on a long-lived child.
                while true; do
                    sleep 0.2 &
                    wait $!
                done
                """,
            ],
            input: .none,
            output: .sequence,
            error: .discarded
        ) { subprocess in
            return try await withThrowingTaskGroup(of: Void.self) { group in
                // Gate the teardown task on bash having actually installed
                // its signal traps. The reader signals readiness when it
                // sees the `ready` marker the script prints once its traps are
                // installed, just before it begins waiting.
                let (readyStream, readyContinuation) = AsyncStream.makeStream(of: Void.self)

                group.addTask {
                    var readyIterator = readyStream.makeAsyncIterator()
                    _ = await readyIterator.next()
                    // Send the teardown signal sequence.
                    await subprocess.teardown(using: [
                        .send(signal: .quit, allowedDurationToNextStep: .milliseconds(500)),
                        .send(signal: .terminate, allowedDurationToNextStep: .milliseconds(500)),
                        .send(signal: .interrupt, allowedDurationToNextStep: .milliseconds(1000)),
                    ])
                }
                group.addTask {
                    var outputs: [String] = []
                    for try await line in subprocess.standardOutput.strings() {
                        let trimmed = line.trimmingCharacters(in: .newlines)
                        if trimmed == "ready" {
                            readyContinuation.yield()
                            readyContinuation.finish()
                            continue
                        }
                        outputs.append(trimmed)
                    }
                    #expect(outputs == ["saw SIGQUIT", "saw SIGTERM", "saw SIGINT"])
                }
                try await group.waitForAll()
            }
        }
        #expect(result.terminationStatus == .exited(42))
    }
}

// MARK: - Teardown Timing
extension SubprocessUnixTests {
    /// Spawns a child that prints `ready` and then blocks in `sleep`, waits
    /// for that marker so the child is known to be running, then cancels the
    /// run to trigger teardown and returns how long the teardown took.
    private func measureCancelledTeardown(
        using teardownSequence: [TeardownStep]
    ) async -> Duration {
        let (readyStream, readyContinuation) = AsyncStream.makeStream(of: Void.self)
        return await withTaskGroup(
            of: Void.self,
            returning: Duration.self
        ) { group in
            group.addTask {
                var platformOptions = PlatformOptions()
                // Isolate the child in its own session so teardown can't reach
                // anything but the process we spawned.
                platformOptions.createSession = true
                platformOptions.teardownSequence = teardownSequence
                let configuration = Configuration(
                    executable: .path("/bin/sh"),
                    // `exec` so the monitored child becomes `sleep` itself,
                    // which dies instantly on SIGTERM/SIGKILL.
                    arguments: ["-c", "echo ready; exec sleep 10"],
                    platformOptions: platformOptions
                )
                _ = try? await Subprocess.run(
                    configuration,
                    input: .none,
                    output: .sequence,
                    error: .discarded
                ) { execution in
                    for try await line in execution.standardOutput.strings() {
                        if line.trimmingCharacters(in: .whitespacesAndNewlines) == "ready" {
                            readyContinuation.finish()
                        }
                    }
                }
            }
            // Block until the child confirms it is running.
            for await _ in readyStream {}
            // Time only the teardown triggered by cancellation.
            return await ContinuousClock().measure {
                group.cancelAll()
                await group.waitForAll()
            }
        }
    }

    @Test func testKillTeardownReturnsAsSoonAsProcessExits() async {
        let elapsed = await self.measureCancelledTeardown(using: [
            .send(signal: .kill, allowedDurationToNextStep: .seconds(5))
        ])
        #expect(elapsed < .seconds(5), "SIGKILL is uncatchable; teardown should not wait")
    }

    @Test func testTerminateTeardownReturnsAsSoonAsProcessExits() async {
        let elapsed = await self.measureCancelledTeardown(using: [
            .send(signal: .terminate, allowedDurationToNextStep: .seconds(3)),
            .send(signal: .kill, allowedDurationToNextStep: .seconds(5)),
        ])
        #expect(elapsed < .seconds(5), "sleep dies on SIGTERM instantly; teardown should not wait")
    }
}

// MARK: - PATH Resolution Tests
extension SubprocessUnixTests {
    @Test func testExecutablePathsPreserveOrder() throws {
        let executable = Executable.name("test-bin")
        let pathValue = "/first/path:/second/path:/third/path"

        let paths = try executable.possibleExecutablePaths(withPathValue: pathValue)
        let pathsArray = Array(paths)

        #expect(
            pathsArray == [
                "/first/path/test-bin",
                "/second/path/test-bin",
                "/third/path/test-bin",
            ])
    }

    @Test func testNoDuplicatedExecutablePaths() throws {
        let executable = Executable.name("test-bin")
        let duplicatePath = "/first/path:/first/path:/second/path"
        let duplicatePaths = try executable.possibleExecutablePaths(withPathValue: duplicatePath)

        #expect(Array(duplicatePaths).count == Set(duplicatePaths).count)
    }

    /// The system's standard directories are a last resort for a `PATH`-less
    /// environment, not an addition to a `PATH` that exists.
    @Test func testPossibleExecutablePathsWithNilPATH() throws {
        let executable = Executable.name("test-bin")
        let paths = try executable.possibleExecutablePaths(withPathValue: nil)

        #expect(
            Array(paths) == Executable.defaultSearchPaths.map { "\($0)/test-bin" }
        )
    }

    /// That last resort is queried from the system rather than hard-coded, so it
    /// is whatever this platform considers standard — and it is filtered the way
    /// a `PATH` value is.
    @Test func testDefaultSearchPathsComeFromTheSystem() throws {
        let defaultSearchPaths = Executable.defaultSearchPaths
        #expect(!defaultSearchPaths.isEmpty)
        for directory in defaultSearchPaths {
            #expect(FilePath(directory).isAbsolute, "\(directory) is not absolute")
        }
    }

    /// The standard directories are the ones `confstr(_CS_PATH)` reports, which
    /// is what `getconf PATH` prints and what `execvp(3)` searches when `PATH`
    /// is unset.
    @Test(
        .enabled(
            if: FileManager.default.isExecutableFile(atPath: "/usr/bin/getconf"),
            "This test requires getconf"
        )
    )
    func testDefaultSearchPathsMatchTheSystemStandardPath() async throws {
        let result = try await Subprocess.run(
            .path("/usr/bin/getconf"),
            arguments: ["PATH"],
            output: .string(limit: 4096)
        )
        try #require(result.terminationStatus.isSuccess)
        let systemStandardPath = result.standardOutput.trimmingNewLineAndQuotes()
        #expect(
            Executable.defaultSearchPaths == systemStandardPath.split(separator: ":").map(String.init)
        )
    }

    /// An empty `PATH` is a `PATH` that lists no directories, so nothing is
    /// searched — the built-in directories do not come back.
    @Test func testPossibleExecutablePathsWithEmptyPATH() throws {
        let executable = Executable.name("test-bin")
        #expect(Array(try executable.possibleExecutablePaths(withPathValue: "")).isEmpty)
    }

    /// Empty entries, which a leading, trailing, or doubled `:` introduces, and
    /// relative entries are both a search of a current working directory, and
    /// are skipped.
    @Test func testExecutablePathsSkipEmptyAndRelativeEntries() throws {
        let executable = Executable.name("test-bin")
        let paths = try executable.possibleExecutablePaths(
            withPathValue: ":/first/path::relative/path:.:..:/second/path:"
        )

        #expect(
            Array(paths) == [
                "/first/path/test-bin",
                "/second/path/test-bin",
            ])
    }

    /// A name containing a path separator is a path, and is rejected rather
    /// than resolved against some current directory.
    @Test func testNameWithPathSeparatorIsRejected() async throws {
        for name in ["bin/test-bin", "./test-bin", "/usr/bin/test-bin", "../test-bin"] {
            #expect(throws: SubprocessError.self) {
                _ = try Executable.name(name).possibleExecutablePaths(withPathValue: "/usr/bin")
            }
            let error = await #expect(throws: SubprocessError.self) {
                _ = try await Executable.name(name).resolveExecutablePath(in: .inherit)
            }
            #expect(error?.code == .spawnFailed)
            // The same name is rejected at spawn time, not just when resolving.
            let spawnError = await #expect(throws: SubprocessError.self) {
                _ = try await Subprocess.run(.name(name), output: .discarded)
            }
            #expect(spawnError?.code == .spawnFailed)
        }
    }

    /// An existing executable named without a separator still resolves through
    /// `PATH` only, so the name of a real binary that happens to sit in the
    /// current directory is not enough to run it.
    #if !os(Android) // Exit tests are not supported on Android
    @Test func testCurrentWorkingDirectoryIsNotSearched() async throws {
        await #expect(processExitsWith: .success) {
            // Runs in an isolated process because it changes the current
            // working directory, which is process-wide state that sibling
            // suites in the same process would otherwise see.
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("cwd-probe-\(UUID().uuidString)")
            let searchDirectory = fixture.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: searchDirectory, withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: fixture) }

            // The executable exists *only* in the current directory, and the
            // current directory is not on PATH.
            let name = "test-executable-\(UUID().uuidString)"
            let executable = fixture.appendingPathComponent(name)
            try """
            #!/bin/sh
            echo "CWD"
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable._fileSystemPath
            )
            #expect(FileManager.default.changeCurrentDirectoryPath(fixture._fileSystemPath))

            let environment = Environment.custom(["PATH": searchDirectory._fileSystemPath])
            let resolveError = await #expect(throws: SubprocessError.self) {
                _ = try await Executable.name(name).resolveExecutablePath(in: environment)
            }
            #expect(resolveError?.code == .executableNotFound)

            let spawnError = await #expect(throws: SubprocessError.self) {
                _ = try await Subprocess.run(
                    .name(name),
                    environment: environment,
                    output: .discarded
                )
            }
            #expect(spawnError?.code == .executableNotFound)
        }
    }
    #endif // !os(Android)

    /// The working directory handed to `run` is where the subprocess starts,
    /// not a directory the executable is looked for in. Resolution happens in
    /// the parent, before the child changes directory, so the two agree.
    @Test func testWorkingDirectoryIsNotSearched() async throws {
        try await withExecutableSearchFixture { fixture in
            let binDirectory = fixture.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true
            )
            let name = "test-executable-\(UUID().uuidString)"
            // The executable exists only in the working directory, which is
            // not on PATH.
            try Self.writeExecutableScript(
                at: fixture.appendingPathComponent(name), echoing: "WORKING-DIRECTORY"
            )

            let spawnError = await #expect(throws: SubprocessError.self) {
                _ = try await Subprocess.run(
                    .name(name),
                    environment: .custom(["PATH": binDirectory._fileSystemPath]),
                    workingDirectory: FilePath(fixture._fileSystemPath),
                    output: .discarded
                )
            }
            #expect(spawnError?.code == .executableNotFound)
        }
    }

    /// The `PATH` the subprocess receives is what a name resolves against, so
    /// the executable that resolution picks is the one that runs.
    @Test func testResolutionUsesTheSubprocessPathValue() async throws {
        try await withExecutableSearchFixture { fixture in
            let childDirectory = fixture.appendingPathComponent("child")
            try FileManager.default.createDirectory(
                at: childDirectory, withIntermediateDirectories: true
            )
            let name = "test-executable-\(UUID().uuidString)"
            let executable = childDirectory.appendingPathComponent(name)
            try Self.writeExecutableScript(at: executable, echoing: "CHILD")

            // The directory is reachable only through the environment passed to
            // the subprocess; it is on neither the current process's PATH nor
            // the built-in list.
            let environment = Environment.custom(["PATH": childDirectory._fileSystemPath])
            let resolved = try await Executable.name(name).resolveExecutablePath(in: environment)
            #expect(resolved.string == executable._fileSystemPath)

            let result = try await Subprocess.run(
                .name(name),
                environment: environment,
                output: .string(limit: 32)
            )
            #expect(result.standardOutput.trimmingNewLineAndQuotes() == "CHILD")
        }
    }

    /// When the environment passed to the subprocess sets no `PATH` of its own,
    /// the current process's value is what gets searched.
    @Test func testPathValueFallsBackToCurrentProcess() throws {
        let currentPathValue = try #require(ProcessInfo.processInfo.environment["PATH"])

        // A PATH for the subprocess is preferred, however it is expressed.
        #expect(Environment.custom(["PATH": "/child/bin"]).pathValue() == "/child/bin")
        #expect(Environment.inherit.updating(["PATH": "/child/bin"]).pathValue() == "/child/bin")
        #expect(Environment.custom([Array("PATH=/child/bin".utf8)]).pathValue() == "/child/bin")

        // Without one, the current process's value is used — including when the
        // subprocess environment explicitly unsets `PATH`.
        #expect(Environment.custom(["MARKER": "no-path-here"]).pathValue() == currentPathValue)
        #expect(Environment.custom([Array("MARKER=no-path-here".utf8)]).pathValue() == currentPathValue)
        #expect(Environment.inherit.updating(["PATH": nil]).pathValue() == currentPathValue)
        #expect(Environment.inherit.pathValue() == currentPathValue)
    }

    /// A `PATH` entry that contains a *directory* whose name matches the
    /// executable must be skipped: the execute bit on a directory only means
    /// "searchable", not "runnable".
    @Test func testNameResolutionSkipsDirectoryInPathEntry() async throws {
        try await withExecutableSearchFixture { fixture in
            let shadowDirectory = fixture.appendingPathComponent("shadow")
            let binDirectory = fixture.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: shadowDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true
            )
            let name = "test-executable-\(UUID().uuidString)"
            // A directory that shares the executable's name, earlier on PATH
            try FileManager.default.createDirectory(
                at: shadowDirectory.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
            let executable = binDirectory.appendingPathComponent(name)
            try Self.writeExecutableScript(at: executable, echoing: "REAL")

            let environment = Environment.inherit.updating([
                "PATH": "\(shadowDirectory._fileSystemPath):\(binDirectory._fileSystemPath)"
            ])

            // Eager resolution
            let resolved = try await Executable.name(name).resolveExecutablePath(in: environment)
            #expect(resolved.string == executable._fileSystemPath)

            // Spawn-time resolution
            let result = try await Subprocess.run(
                .name(name),
                environment: environment,
                output: .string(limit: 16)
            )
            #expect(result.terminationStatus.isSuccess)
            #expect(result.standardOutput.trimmingNewLineAndQuotes() == "REAL")
        }
    }

    /// The regular-file requirement must not weaken the permission check: a
    /// non-executable file that shares the name is still skipped.
    @Test func testNameResolutionSkipsNonExecutableRegularFile() async throws {
        try await withExecutableSearchFixture { fixture in
            let shadowDirectory = fixture.appendingPathComponent("shadow")
            let binDirectory = fixture.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: shadowDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true
            )
            let name = "test-executable-\(UUID().uuidString)"
            // A regular file that shares the executable's name but is not
            // executable, earlier on PATH
            let shadow = shadowDirectory.appendingPathComponent(name)
            try Data("not executable".utf8).write(to: shadow)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: shadow._fileSystemPath
            )
            let executable = binDirectory.appendingPathComponent(name)
            try Self.writeExecutableScript(at: executable, echoing: "REAL")

            let resolved = try await Executable.name(name).resolveExecutablePath(
                in: .inherit.updating([
                    "PATH": "\(shadowDirectory._fileSystemPath):\(binDirectory._fileSystemPath)"
                ])
            )
            #expect(resolved.string == executable._fileSystemPath)
        }
    }

    /// Only a *regular* file can be executed. A FIFO with the execute bit set
    /// satisfies `access(_, X_OK)` and is not a directory, yet `execve` rejects
    /// it with `EACCES`, so it must not shadow the real executable either.
    @Test(.requiresFIFOCreation)
    func testNameResolutionSkipsNonRegularFile() async throws {
        try await withExecutableSearchFixture { fixture in
            let shadowDirectory = fixture.appendingPathComponent("shadow")
            let binDirectory = fixture.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: shadowDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true
            )
            let name = "test-executable-\(UUID().uuidString)"
            let fifo = shadowDirectory.appendingPathComponent(name)
            let result = fifo._fileSystemPath.withCString { mkfifo($0, 0o755) }
            try #require(result == 0, "mkfifo failed: \(Errno(rawValue: errno))")
            // `mkfifo` honors the umask, so set the execute bits explicitly.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fifo._fileSystemPath
            )
            let executable = binDirectory.appendingPathComponent(name)
            try Self.writeExecutableScript(at: executable, echoing: "REAL")

            let resolved = try await Executable.name(name).resolveExecutablePath(
                in: .inherit.updating([
                    "PATH": "\(shadowDirectory._fileSystemPath):\(binDirectory._fileSystemPath)"
                ])
            )
            #expect(resolved.string == executable._fileSystemPath)
        }
    }

    /// Symlinks are resolved, not rejected: the check follows the link with
    /// `stat` rather than inspecting the link itself, so a symlink to an
    /// executable on `PATH` still resolves and runs.
    @Test func testNameResolutionFollowsSymlinkToExecutable() async throws {
        try await withExecutableSearchFixture { fixture in
            let binDirectory = fixture.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true
            )
            let target = fixture.appendingPathComponent("target-\(UUID().uuidString)")
            try Self.writeExecutableScript(at: target, echoing: "LINKED")
            let name = "test-executable-\(UUID().uuidString)"
            let link = binDirectory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let environment = Environment.inherit.updating([
                "PATH": binDirectory._fileSystemPath
            ])
            let resolved = try await Executable.name(name).resolveExecutablePath(in: environment)
            #expect(resolved.string == link._fileSystemPath)

            let result = try await Subprocess.run(
                .name(name),
                environment: environment,
                output: .string(limit: 16)
            )
            #expect(result.standardOutput.trimmingNewLineAndQuotes() == "LINKED")
        }
    }

    /// A symlink that points at a *directory* is still a directory, and must be
    /// skipped like any other.
    @Test func testNameResolutionSkipsSymlinkToDirectory() async throws {
        try await withExecutableSearchFixture { fixture in
            let shadowDirectory = fixture.appendingPathComponent("shadow")
            let binDirectory = fixture.appendingPathComponent("bin")
            let target = fixture.appendingPathComponent("target-directory")
            for directory in [shadowDirectory, binDirectory, target] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            }
            let name = "test-executable-\(UUID().uuidString)"
            try FileManager.default.createSymbolicLink(
                at: shadowDirectory.appendingPathComponent(name),
                withDestinationURL: target
            )
            let executable = binDirectory.appendingPathComponent(name)
            try Self.writeExecutableScript(at: executable, echoing: "REAL")

            let resolved = try await Executable.name(name).resolveExecutablePath(
                in: .inherit.updating([
                    "PATH": "\(shadowDirectory._fileSystemPath):\(binDirectory._fileSystemPath)"
                ])
            )
            #expect(resolved.string == executable._fileSystemPath)
        }
    }

    // MARK: Fixture helpers

    /// Creates a unique temporary directory, passes it to `body`, and removes
    /// it afterwards.
    private func withExecutableSearchFixture(
        _ body: (URL) async throws -> Void
    ) async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("executable-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try await body(fixture)
    }

    private static func writeExecutableScript(at url: URL, echoing marker: String) throws {
        try """
        #!/bin/sh
        echo "\(marker)"
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url._fileSystemPath
        )
    }
}

// MARK: - Misc
extension SubprocessUnixTests {
    @Test(.timeLimit(.minutes(1)))
    func testSuspendResumeProcess() async throws {
        // Set up pipes manually so the test owns both ends. This lets us bound
        // how long we wait for output. Standard sequence/iterator-based outputs
        // use non-Sendable iterators that can't be moved into a child task.
        let inputPipe = try FileDescriptor.pipe()
        let outputPipe = try FileDescriptor.pipe()

        // Make the read end non-blocking so readLine() can poll with a
        // deadline instead of blocking indefinitely.
        let flags = fcntl(outputPipe.readEnd.rawValue, F_GETFL)
        try #require(fcntl(outputPipe.readEnd.rawValue, F_SETFL, flags | O_NONBLOCK) == 0)

        // Isolate cat in its own session: the SIGSTOP below would otherwise
        // leave a stopped process in the test runner's process group, and a
        // concurrent child exit that orphans that group makes the kernel
        // deliver SIGHUP+SIGCONT to every member of the group, including this
        // test process, killing the run.
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true

        try await outputPipe.readEnd.closeAfter {
            try await inputPipe.writeEnd.closeAfter {
                _ = try await Subprocess.run(
                    .path("/bin/cat"),
                    platformOptions: platformOptions,
                    // cat reads from inputPipe.readEnd. The parent keeps writeEnd to feed it.
                    input: .fileDescriptor(inputPipe.readEnd, closeAfterSpawningProcess: true),
                    // cat writes to outputPipe.writeEnd. The parent keeps readEnd to drain it.
                    output: .fileDescriptor(outputPipe.writeEnd, closeAfterSpawningProcess: true),
                    error: .discarded
                ) { subprocess in
                    // Confirm cat is running and echoing before manipulating its state.
                    try inputPipe.writeEnd.writeLine("ready")
                    try #require(try await outputPipe.readEnd.readLine(timeout: .seconds(2)) == "ready")

                    // Suspend cat, then write two lines it must not echo back. If
                    // SIGSTOP took effect, no amount of waiting produces output,
                    // and the lines accumulate in the pipe buffer until SIGCONT.
                    try subprocess.send(signal: .suspend)
                    try inputPipe.writeEnd.writeLine("first")
                    try inputPipe.writeEnd.writeLine("second")

                    // Give cat 200ms to (incorrectly) produce output. If the suspend
                    // didn't work, cat already echoed and the pipe has bytes ready.
                    let leaked = try await outputPipe.readEnd.readLine(timeout: .milliseconds(200))
                    try #require(leaked == nil, "cat produced output while suspended: \(leaked ?? "")")

                    // Resume cat. Both buffered lines must emerge in order, proving
                    // the process accumulated state while stopped and released it
                    // on SIGCONT.
                    try subprocess.send(signal: .resume)
                    try #require(try await outputPipe.readEnd.readLine(timeout: .seconds(2)) == "first")
                    try #require(try await outputPipe.readEnd.readLine(timeout: .seconds(2)) == "second")

                    // Tear down. SIGTERM makes cat exit; closeAfter closes the
                    // parent's write end as cleanup once run() returns.
                    try subprocess.send(signal: .terminate)
                }
            }
        }
    }

    @Test func testExitSignal() async throws {
        let signalsToTest: [CInt] = [SIGKILL, SIGTERM, SIGINT]
        for signal in signalsToTest {
            let result = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "kill -\(signal) $$"],
                output: .discarded
            )
            #if os(Android) || os(OpenBSD)
            // When terminated by a catchable signal, /bin/sh on Android (mksh)
            // and OpenBSD (oksh) — both pdksh-derived — exits normally with a
            // status of 128+n instead of re-raising the signal. SIGKILL is
            // uncatchable and still produces a signal-based termination.
            // https://www.gnu.org/software/autoconf/manual/autoconf-2.69/html_node/Signal-Handling.html
            let expected: TerminationStatus =
                signal == SIGKILL
                ? .signaled(signal)
                : .exited(128 + signal)
            #expect(result.terminationStatus == expected)
            #else
            #expect(result.terminationStatus == .signaled(signal))
            #endif
        }
    }

    @Test func testCanReliablyKillProcessesEvenWithSigmask() async throws {
        let result = try await withThrowingTaskGroup(
            of: TerminationStatus?.self,
            returning: TerminationStatus.self
        ) { group in
            group.addTask {
                return try await Subprocess.run(
                    .path("/bin/sh"),
                    arguments: ["-c", "trap 'echo no' TERM; while true; do sleep 1; done"],
                    output: .string(limit: .max)
                ).terminationStatus
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return nil
            }
            while let result = try await group.next() {
                group.cancelAll()
                if let result = result {
                    return result
                }
            }
            preconditionFailure("Task should have returned a result")
        }
        #expect(result == .signaled(SIGKILL))
    }

    @Test(.requiresBash)
    func testRunawayProcess() async throws {
        do {
            try await withThrowingTaskGroup { group in
                let (readyStream, readyContinuation) = AsyncStream.makeStream(of: Void.self)

                group.addTask {
                    var platformOptions = PlatformOptions()
                    platformOptions.teardownSequence = [
                        // SIGTERM for the child to catch (paired with the poll
                        // loop in the script). The grace period must comfortably
                        // exceed the poll interval so the trap is serviced
                        // before escalation. The grace period is a ceiling;
                        // teardown returns as soon as the child exits.
                        .send(signal: .terminate, allowedDurationToNextStep: .seconds(1))
                    ]
                    let result = try await Subprocess.run(
                        .name("bash"),
                        arguments: [
                            "-c",
                            """
                            set -e
                            # The following /usr/bin/yes is the runaway grand child.
                            # It runs in the background forever until this script kills it
                            /usr/bin/yes "Runaway process from \(#function), please file a SwiftSubprocess bug." > /dev/null &
                            child_pid=$! # Retrieve the grand child yes pid
                            # When SIGTERM is sent to the script, kill grand child now
                            trap "echo >&2 'child: received signal, killing grand child ($child_pid)'; kill -s KILL $child_pid; exit 0" TERM
                            echo "$child_pid" # communicate the child pid to our parent
                            echo "child: waiting for grand child, pid: $child_pid" >&2
                            # Poll rather than `wait "$child_pid"`. A blocking wait on a child that never
                            # exits leaves bash no point at which to service a deferred trap, so a signal
                            # landing in the window just before waitpid blocks is recorded but never run,
                            # and teardown escalates to SIGKILL. A short sleep loop returns to a
                            # trap-checking safe point each iteration, bounding trap latency.
                            while kill -0 "$child_pid" 2>/dev/null; do
                                sleep 0.05
                            done
                            """,
                        ],
                        platformOptions: platformOptions,
                        input: .none,
                        output: .sequence,
                        error: .fileDescriptor(.standardError, closeAfterSpawningProcess: false)
                    ) { execution in
                        // Read stdout incrementally. Once we see the PID line,
                        // we know the trap is set up and it's safe to send SIGTERM.
                        var grandChildPid: pid_t?
                        for try await line in execution.standardOutput.strings() {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let pid = pid_t(trimmed) {
                                grandChildPid = pid
                                readyContinuation.finish()
                            }
                        }
                        return grandChildPid
                    }
                    #expect(result.terminationStatus.isSuccess)
                    // Make sure the grand child `/usr/bin/yes` actually exited
                    // This is unfortunately racy because the pid isn't immediately invalided
                    // once `kill` returns. Allow a few failures and delay to counter this
                    let grandChildPid = try #require(result.closureResult)
                    for _ in 0..<10 {
                        let rc = kill(grandChildPid, 0)
                        if rc == 0 {
                            // Wait for a small delay
                            try await Task.sleep(for: .milliseconds(100))
                        } else {
                            break
                        }
                    }
                    let finalRC = kill(grandChildPid, 0)
                    let capturedError = errno
                    #expect(finalRC != 0)
                    #expect(capturedError == ESRCH)
                }
                group.addTask {
                    // Wait until bash has echoed the PID (trap is set up)
                    for await _ in readyStream {
                    }
                }
                // Wait for the ready signal
                _ = try await group.next()
                // Cancel child process to trigger teardown
                group.cancelAll()
                try await group.waitForAll()
            }
        } catch {
            if error is CancellationError {
                // We intentionally cancelled the task
                return
            }
            throw error
        }
    }

    @Test(.requiresBash)
    func testTeardownSignalsProcessGroup() async throws {
        do {
            try await withThrowingTaskGroup { group in
                let (readyStream, readyContinuation) = AsyncStream.makeStream(of: Void.self)

                group.addTask {
                    var platformOptions = PlatformOptions()
                    // Creating a new session puts the shell (and its descendants,
                    // absent further setsid calls) in their own process group, so
                    // the teardown signal reaches everything spawned from the shell.
                    platformOptions.createSession = true
                    platformOptions.teardownSequence = [
                        .send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .milliseconds(200))
                    ]
                    let result = try await Subprocess.run(
                        .name("bash"),
                        arguments: [
                            "-c",
                            """
                            set -e
                            # Spawn a grandchild that would otherwise outlive the shell.
                            # Deliberately install NO trap: we want to verify that the
                            # teardown signal reaches the grandchild directly via the
                            # process group, not that bash cooperatively cleans up.
                            /usr/bin/yes "Runaway process from \(#function), please file a SwiftSubprocess bug." > /dev/null &
                            child_pid=$!
                            echo "$child_pid"
                            wait $child_pid
                            """,
                        ],
                        platformOptions: platformOptions,
                        input: .none,
                        output: .sequence,
                        error: .fileDescriptor(.standardError, closeAfterSpawningProcess: false)
                    ) { execution in
                        var grandChildPid: pid_t?
                        for try await line in execution.standardOutput.strings() {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let pid = pid_t(trimmed) {
                                grandChildPid = pid
                                readyContinuation.finish()
                            }
                        }
                        return grandChildPid
                    }
                    #expect(result.terminationStatus == .signaled(SIGTERM))
                    let grandChildPid = try #require(result.closureResult)
                    // Grandchild should have been signalled via the process group.
                    // Allow a few iterations for signal propagation and reaping.
                    for _ in 0..<10 {
                        if kill(grandChildPid, 0) != 0 { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let finalRC = kill(grandChildPid, 0)
                    let capturedError = errno
                    #expect(finalRC != 0)
                    #expect(capturedError == ESRCH)
                }
                group.addTask {
                    for await _ in readyStream {}
                }
                // Wait for the ready signal
                _ = try await group.next()
                // Cancel child process to trigger teardown
                group.cancelAll()
                try await group.waitForAll()
            }
        } catch {
            if error is CancellationError {
                // We intentionally cancelled the task
                return
            }
            throw error
        }
    }

    @Test(arguments: [false, true])
    func testSubprocessDoesNotInheritVeryHighFileDescriptors(forceFallback: Bool) async throws {
        var openedFileDescriptors: [CInt] = []
        // Open /dev/null to use as source for duplication
        let devnull: FileDescriptor = try .openDevNull(withAccessMode: .readOnly)
        defer {
            let closeResult = close(devnull.rawValue)
            #expect(closeResult == 0)
        }
        // Duplicate devnull to higher file descriptors
        for candidate in sequence(
            first: CInt(1),
            next: { $0 <= CInt.max / 2 ? $0 * 2 : nil }
        ) {
            // Use fcntl with F_DUPFD to find next available FD >= candidate
            let fd = fcntl(devnull.rawValue, F_DUPFD, candidate)
            if fd < 0 {
                // Failed to allocate this candidate, try the next one
                continue
            }
            openedFileDescriptors.append(fd)
        }
        defer {
            for fd in openedFileDescriptors {
                let closeResult = close(fd)
                #expect(closeResult == 0)
            }
        }
        // Probe each fd via dup2 in a forked external command (true(1)).
        // Avoids the [-e /dev/fd/N] / [-e /proc/self/fd/N] oracle, which
        // gives false positives on OpenBSD (static character-device nodes
        // /dev/fd/0..63 exist regardless of which fds are open) and requires
        // /proc on Linux / fdescfs on FreeBSD.
        //
        // Why /usr/bin/true and not the builtin? When bash applies `>&N` to
        // a builtin, it first saves the original fd via fcntl(F_DUPFD, 10)
        // so it can restore it after the builtin returns. While the builtin
        // is running, fd 10 (or whichever low fd >= 10 is free) is held open
        // as bash's saved fd, so a probe of fd 10 falsely succeeds. Forking
        // an external command sidesteps this: bash applies the redirection
        // in the forked child without saving (the child is about to exec
        // away), so dup2 only succeeds when the fd was genuinely open.
        //
        // The subshell wrapper isolates the redirection failure: dash treats
        // a redirection failure in the current shell as fatal to the
        // non-interactive script, but a failure in a subshell only exits
        // the subshell.
        let shellScript =
            """
            for fd in "$@"; do
                if (/usr/bin/true <&"$fd") 2>/dev/null; then
                    echo "$fd:OPEN"
                else
                    echo "$fd:CLOSED"
                fi
            done
            """
        // POSIX `sh -c command_string [command_name [argument...]]` always
        // takes the next argv as $0. Do not pass `--`: OpenBSD's ksh-derived
        // /bin/sh does not honor it as an option terminator and would assign
        // it to $0 (while FreeBSD's ash-derived /bin/sh consumes it and
        // shifts $0 onto the next arg) — keep things deterministic by
        // passing a single explicit placeholder.
        var arguments = ["-c", shellScript, "subprocess-fd-test"]
        arguments.append(contentsOf: openedFileDescriptors.map { "\($0)" })

        let tally = SpawnPathTally()
        let result = try await self.withSpawnPath(forceFallback: forceFallback, tally: tally) {
            try await Subprocess.run(
                .path("/bin/sh"),
                arguments: .init(arguments),
                output: .string(limit: .max),
                error: .string(limit: .max)
            )
        }
        self.expect(tally, tookFallbackPath: self.expectsFallbackPath(forceFallback: forceFallback))
        #expect(result.terminationStatus.isSuccess)
        #expect(result.standardError.trimmingNewLineAndQuotes().isEmpty == true)
        var checklist = Set(openedFileDescriptors)
        let closeResult = result.standardOutput
            .trimmingNewLineAndQuotes()
            .split(separator: "\n")
        #expect(checklist.count == closeResult.count)

        for resultString in closeResult {
            let components = resultString.split(separator: ":")
            #expect(components.count == 2)
            guard let fd = CInt(components[0]) else {
                continue
            }
            #expect(checklist.remove(fd) != nil)
            #expect(components[1] == "CLOSED")
        }
        // Make sure all fds are closed
        #expect(checklist.isEmpty)
    }

    @Test(.requiresBash) func testSubprocessDoesNotInheritRandomFileDescriptors() async throws {
        let pipe = try FileDescriptor.ssp_pipe()
        // Move write end to a high fd to avoid interaction with library-internal fds
        // that may share the same fd number on some platforms
        let testWriteEnd = try pipe.writeEnd.duplicate(as: FileDescriptor(rawValue: 1000))
        try pipe.writeEnd.close()

        try await pipe.readEnd.closeAfter {
            let result = try await testWriteEnd.closeAfter {
                // Spawn bash and then attempt to write to the write end
                try await Subprocess.run(
                    .name("bash"),
                    arguments: [
                        "-c",
                        """
                        echo this string should be discarded >&\(testWriteEnd.rawValue);
                        echo wrote into \(testWriteEnd.rawValue), echo exit code $?;
                        """,
                    ],
                    input: .none,
                    output: .string(limit: 64),
                    error: .discarded
                )
            }
            #expect(result.terminationStatus.isSuccess)
            // Make sure nothing is written to the pipe
            var readBytes: [UInt8] = Array(repeating: 0, count: 1024)
            let readCount = try readBytes.withUnsafeMutableBytes { ptr in
                return try FileDescriptor(rawValue: pipe.readEnd.rawValue)
                    .read(into: ptr, retryOnInterrupt: true)
            }
            #expect(readCount == 0)
            #expect(
                result.standardOutput.trimmingNewLineAndQuotes() == "wrote into \(testWriteEnd.rawValue), echo exit code 1"
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testConcurrentSlowExitsDoNotHang() async throws {
        // When many concurrent `Subprocess.run` calls have their children exit
        // in a tight burst, the SIGCHLD-coalescing reaper must drain every
        // ready child per wakeup. 16 children that each sleep ~1s will exit
        // within a few milliseconds of each other and flood the reaper; the
        // body-less runs keep all 16 monitors blocked on termination for the
        // full second, so the exits land while every monitor is waiting. No
        // signal or trap is involved: the reaper keys on child exit (SIGCHLD),
        // which is identical whether a child exits on a timer or a signal, so
        // a timed exit reproduces the same stress without relying on bash.
        let count = 16
        try await withThrowingTaskGroup(of: TerminationStatus.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try await Subprocess.run(
                        .path("/bin/sleep"),
                        arguments: ["1"],
                        output: .discarded
                    ).terminationStatus
                }
            }
            for try await status in group {
                #expect(status == .exited(0))
            }
        }
    }

    @Test func testRejectInvalidEnvironment() async throws {
        func _runTest(withEnvironment environment: Environment, errorReason: String) async {
            let expectedError: SubprocessError = .spawnFailed(
                withUnderlyingError: nil,
                reason: errorReason
            )

            await #expect(throws: expectedError) {
                _ = try await Subprocess.run(
                    .path("/bin/echo"),
                    environment: environment,
                    output: .discarded
                )
            }
        }

        await _runTest(
            withEnvironment: .inherit.updating(["key=": "value"]),
            errorReason: "Environment key 'key=' must not contain '=' or null bytes."
        )

        await _runTest(
            withEnvironment: .inherit.updating(["key\0": "value"]),
            errorReason: "Environment key 'key\0' must not contain '=' or null bytes."
        )

        await _runTest(
            withEnvironment: .inherit.updating(["0key": "value"]),
            errorReason: "Environment key '0key' must not begin with a digit."
        )

        await _runTest(
            withEnvironment: .inherit.updating(["key": "value\0"]),
            errorReason: "Environment value 'value\0' must not contain null bytes."
        )

        // Raw bytes: a trailing null terminator is allowed, but an embedded
        // null byte must be rejected since `strdup` would silently truncate it.
        await _runTest(
            withEnvironment: .custom([Array("key=va\0lue".utf8)]),
            errorReason: "Environment entry 'key=va\0lue' must not contain null bytes."
        )

        await _runTest(
            withEnvironment: .custom([Array("keyvalue\0".utf8)]),
            errorReason: "Environment entry 'keyvalue' must contain '='."
        )

        await _runTest(
            withEnvironment: .custom([Array("0key=value\0".utf8)]),
            errorReason: "Environment key '0key' must not begin with a digit."
        )
    }
}

// MARK: - Spawn Path Tests
extension SubprocessUnixTests {
    /// Standard input reaches the child on both spawn paths, and a stream
    /// requested as `.none` yields end of file rather than the parent's own
    /// input.
    ///
    /// The written-input case is what makes this sensitive: it fails outright
    /// if the descriptor never reaches the child's file descriptor 0. A `.none`
    /// probe alone would not, because `/bin/sh` opens a descriptor of its own
    /// when it starts with 0 closed, so "the child could read nothing" is true
    /// whether the stream was wired to the null device or lost entirely.
    @Test(arguments: [false, true])
    func testStandardInputIsWiredOnBothSpawnPaths(forceFallback: Bool) async throws {
        let content = "spawn-path-stdin-\(randomString(length: 16, lettersOnly: true))"

        let writtenTally = SpawnPathTally()
        let written = try await withSpawnPath(forceFallback: forceFallback, tally: writtenTally) {
            try await Subprocess.run(
                .path("/bin/cat"),
                input: .string(content),
                output: .string(limit: 128)
            )
        }
        #expect(written.terminationStatus.isSuccess)
        #expect(written.standardOutput == content)
        expect(writtenTally, tookFallbackPath: self.expectsFallbackPath(forceFallback: forceFallback))

        let noneTally = SpawnPathTally()
        let none = try await withSpawnPath(forceFallback: forceFallback, tally: noneTally) {
            try await Subprocess.run(
                .path("/bin/cat"),
                input: .none,
                output: .string(limit: 128)
            )
        }
        #expect(none.terminationStatus.isSuccess)
        #expect(none.standardOutput == "")
        expect(noneTally, tookFallbackPath: self.expectsFallbackPath(forceFallback: forceFallback))
    }

    /// A working directory that cannot be changed to is reported as such, with
    /// the `errno` that explains why, rather than as a spawn failure or a
    /// missing executable.
    ///
    /// Both paths resolve the directory in the parent, so both report the same
    /// error: the fallback path would otherwise be unable to tell a child's
    /// failed `chdir` from a failed `exec`.
    @Test(arguments: [false, true])
    func testWorkingDirectoryErrorIsPrecise(forceFallback: Bool) async throws {
        let missingTally = SpawnPathTally()
        let missingError = await #expect(throws: SubprocessError.self) {
            try await withSpawnPath(forceFallback: forceFallback, tally: missingTally) {
                try await Subprocess.run(
                    .path("/bin/sh"),
                    arguments: ["-c", "exit 0"],
                    workingDirectory: "/definitely/does/not/exist",
                    output: .discarded
                )
            }
        }
        #expect(missingError?.code == .failedToChangeWorkingDirectory)
        #expect(missingError?.underlyingError == Errno(rawValue: ENOENT))
        // The failure happens before any spawn, so neither path ran. Asserting
        // that is what proves the error came from the parent's resolution step
        // and not from a child that was allowed to start.
        #expect(missingTally.fallback == 0)
        #expect(missingTally.posixSpawn == 0)

        // A path whose parent component is a regular file is ENOTDIR, not
        // ENOENT: the distinction is exactly what the old "does the directory
        // exist?" guess could not make.
        let notDirectoryTally = SpawnPathTally()
        let notDirectoryError = await #expect(throws: SubprocessError.self) {
            try await withSpawnPath(forceFallback: forceFallback, tally: notDirectoryTally) {
                try await Subprocess.run(
                    .path("/bin/sh"),
                    arguments: ["-c", "exit 0"],
                    workingDirectory: "/bin/sh/nope",
                    output: .discarded
                )
            }
        }
        #expect(notDirectoryError?.code == .failedToChangeWorkingDirectory)
        #expect(notDirectoryError?.underlyingError == Errno(rawValue: ENOTDIR))
        #expect(notDirectoryTally.fallback == 0)
        #expect(notDirectoryTally.posixSpawn == 0)
    }

    /// A valid working directory is honored identically by both paths: the
    /// `posix_spawn` path applies it as an `fchdir` file action against a
    /// descriptor the parent opened, the fallback path `chdir`s in the child.
    @Test(arguments: [false, true])
    func testWorkingDirectoryIsAppliedOnBothPaths(forceFallback: Bool) async throws {
        let directoryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("subprocess-spawn-path-\(randomString(length: 12, lettersOnly: true))")
            ._fileSystemPath
        try FileManager.default.createDirectory(
            atPath: directoryPath,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directoryPath) }

        let tally = SpawnPathTally()
        let result = try await withSpawnPath(forceFallback: forceFallback, tally: tally) {
            try await Subprocess.run(
                .path("/bin/sh"),
                // `pwd -P` rather than `$PWD`: the latter is inherited from the
                // environment and would report the parent's directory even if
                // the child never moved.
                arguments: ["-c", "pwd -P"],
                workingDirectory: FilePath(directoryPath),
                output: .string(limit: 4096)
            )
        }
        #expect(result.terminationStatus.isSuccess)
        let reported = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        // `pwd -P` reports the physical path, so the expected value has to be
        // resolved too: on Darwin the temporary directory lives under a
        // `/var` -> `/private/var` symlink.
        let resolvedPath = try #require(
            directoryPath.withCString { path in
                realpath(path, nil).map { resolved -> String in
                    defer { free(resolved) }
                    return String(cString: resolved)
                }
            }
        )
        #expect(reported == resolvedPath)
        expect(
            tally,
            tookFallbackPath: self.expectsFallbackPath(
                forceFallback: forceFallback, workingDirectory: FilePath(directoryPath)
            )
        )
    }

    /// `createSession` combined with `processGroupID` must take the fallback
    /// path, which controls the order of `setsid` and `setpgid` itself: glibc
    /// and Bionic order them differently, and setpgid-then-setsid makes setsid
    /// fail with EPERM.
    ///
    /// Asserted twice: once against the rule, and once against a real spawn, so
    /// that a rule that stopped being consulted would still be caught.
    @Test func testCreateSessionWithProcessGroupUsesTheFallbackPath() async throws {
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.processGroupID = 0
        let configuration = Configuration(
            executable: .path("/bin/sh"),
            platformOptions: platformOptions
        )
        #expect(configuration.requiresFallbackSpawnPath(supplementaryGroups: nil))

        let tally = SpawnPathTally()
        _ = try await SpawnCapabilities.spawnPathTallyOverride.withValue(tally) {
            // The termination status is deliberately not asserted: a child that
            // both leads a new session and joins a new process group is
            // detached from the test runner's terminal, and some platforms
            // deliver it a signal for that. What matters here is which path
            // spawned it.
            try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "exit 0"],
                platformOptions: platformOptions,
                output: .discarded
            )
        }
        #expect(tally.fallback == 1)
        #expect(tally.posixSpawn == 0)
    }

    /// Changing the user or group has no `posix_spawn` attribute anywhere, so
    /// such a configuration routes to the fallback path even when nothing is
    /// forcing it.
    ///
    /// Rule-level only: actually spawning with a different user needs root,
    /// which `testSubprocessPlatformOptionsUserID` already covers where it is
    /// available.
    @Test func testPrivilegeChangesUseTheFallbackPath() throws {
        var platformOptions = PlatformOptions()
        platformOptions.userID = 501
        let configuration = Configuration(
            executable: .path("/bin/sh"),
            platformOptions: platformOptions
        )
        #expect(configuration.requiresFallbackSpawnPath(supplementaryGroups: nil))
        // Supplementary groups are resolved separately from the options, so
        // they are passed in rather than read from the configuration.
        #expect(
            Configuration(executable: .path("/bin/sh"))
                .requiresFallbackSpawnPath(supplementaryGroups: [20])
        )
    }

    #if !canImport(Darwin)
    /// The `preSpawnProcessConfigurator` closure reaches the real
    /// `posix_spawnattr_t` and `posix_spawn_file_actions_t`, and what it does to
    /// them takes effect in the child.
    ///
    /// This is the only exercise of the `assumingMemoryBound` rebind that turns
    /// the opaque handles the spawn path carries back into the platform's own
    /// pointer types, so it is the only thing that would catch that rebind
    /// naming the wrong type. Darwin has its own equivalents in
    /// `SubprocessDarwinTests`, against a configurator whose signature predates
    /// ``PlatformSpawnAttributes``.
    ///
    /// Only the `posix_spawn` path is covered, and only where the host can take
    /// it: off Darwin the `fork`/`exec` fallback does its child-side setup
    /// itself and so never builds the attributes or file actions a configurator
    /// would be handed. That rules the test out entirely on OpenBSD and on a
    /// libc with no close-all mechanism, hence the condition.
    @Test(
        .enabled(
            if: !Configuration(executable: .path("/bin/sh"))
                .requiresFallbackSpawnPath(supplementaryGroups: nil),
            "This platform's posix_spawn cannot express any request, so no spawn builds file actions"
        )
    )
    func testPreSpawnProcessConfiguratorIsAppliedOnThePosixSpawnPath() async throws {
        let redirectPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("configurator-\(randomString(length: 12, lettersOnly: true))")
            ._fileSystemPath
        defer { try? FileManager.default.removeItem(atPath: redirectPath) }

        // Recorded by the configurator and read after the run, so a configurator
        // that is never called fails on a nil value rather than passing by an
        // absent side effect. A class because the closure is `@Sendable`;
        // unchecked because it is written from the spawning task and read only
        // after that task has finished.
        final class FlagsBox: @unchecked Sendable {
            var flags: Int16?
        }
        let flagsSeen = FlagsBox()

        var platformOptions = PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = { attributes, fileActions in
            // The attributes are the ones the spawn path already populated, so
            // the flags it set are visible here.
            var flags: Int16 = 0
            _ = posix_spawnattr_getflags(attributes, &flags)
            flagsSeen.flags = flags

            // Appended after the library's own actions, so this open replaces
            // the child's standard output: whatever the child writes lands in
            // the file instead of in the pipe.
            _ = redirectPath.withCString { path in
                posix_spawn_file_actions_addopen(
                    fileActions, 1, path, O_WRONLY | O_CREAT | O_TRUNC, 0o644
                )
            }
        }

        let tally = SpawnPathTally()
        let result = try await self.withSpawnPath(forceFallback: false, tally: tally) {
            try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "echo redirected"],
                platformOptions: platformOptions,
                output: .string(limit: 128)
            )
        }
        self.expect(tally, tookFallbackPath: false)
        #expect(result.terminationStatus.isSuccess)

        // The configurator ran, and saw the attributes the spawn path had
        // already set rather than a freshly initialized set.
        let flags = try #require(flagsSeen.flags)
        #expect(flags & Int16(POSIX_SPAWN_SETSIGDEF) != 0)
        #expect(flags & Int16(POSIX_SPAWN_SETSIGMASK) != 0)

        // Its file action took effect: the child's output went to the file, so
        // nothing reached the pipe.
        #expect(result.standardOutput.isEmpty)
        let redirected = try String(contentsOfFile: redirectPath, encoding: .utf8)
        #expect(redirected.trimmingCharacters(in: .whitespacesAndNewlines) == "redirected")
    }
    #endif // !canImport(Darwin)

    #if os(FreeBSD)
    /// FreeBSD has no way to obtain a process descriptor from `posix_spawn`
    /// before 15.1, so the descriptor is present only on the fallback path,
    /// which uses `pdfork`.
    ///
    /// Linux is excluded because `pidfd_open` gives the `posix_spawn` path a
    /// descriptor too, so there is no difference between the paths to assert.
    ///
    /// This asserts the *absence* of a descriptor on the `posix_spawn` path, so
    /// it inverts into a failure the moment that stops being true. When the
    /// `posix_spawnattr_setprocdescp_np` FIXME in `process_shims.c` lands and
    /// FreeBSD gains a descriptor on both paths, this test should assert a
    /// descriptor on both rather than be read as a regression.
    @Test(arguments: [false, true])
    func testProcessDescriptorAvailabilityByPath(forceFallback: Bool) async throws {
        let tally = SpawnPathTally()
        let result = try await withSpawnPath(forceFallback: forceFallback, tally: tally) {
            try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "exit 0"],
                input: .none,
                output: .discarded,
                error: .discarded
            ) { execution in
                return execution.processIdentifier.processDescriptor
            }
        }
        expect(tally, tookFallbackPath: self.expectsFallbackPath(forceFallback: forceFallback))
        if forceFallback {
            #expect(result.closureResult != -1)
        } else {
            #expect(result.closureResult == -1)
        }
    }
    #endif // os(FreeBSD)
}

// MARK: - Utils
extension SubprocessUnixTests {
    /// Runs `body` with the spawn path forced, if `forceFallback`, and with
    /// `tally` recording the path each spawn inside it took.
    ///
    /// The override is a task-local rather than a global, so this must wrap the
    /// spawning work rather than being set before it: Swift Testing runs other
    /// suites concurrently with this one, and a global would steer their spawns
    /// too.
    fileprivate func withSpawnPath<Result>(
        forceFallback: Bool,
        tally: SpawnPathTally,
        _ body: () async throws -> Result
    ) async rethrows -> Result {
        return try await SpawnCapabilities.forceFallbackPathOverride.withValue(forceFallback) {
            try await SpawnCapabilities.spawnPathTallyOverride.withValue(tally) {
                try await body()
            }
        }
    }

    /// Asserts that exactly one spawn happened, on the path `tookFallbackPath`
    /// names.
    ///
    /// This is what makes a two-case parameterized test meaningful: without it,
    /// both cases could take the same path and agree for the wrong reason.
    fileprivate func expect(
        _ tally: SpawnPathTally,
        tookFallbackPath: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(tally.fallback == (tookFallbackPath ? 1 : 0), sourceLocation: sourceLocation)
        #expect(tally.posixSpawn == (tookFallbackPath ? 0 : 1), sourceLocation: sourceLocation)
    }

    /// Which path a spawn of this configuration is expected to take.
    ///
    /// Not simply `forceFallback`: on a platform whose `posix_spawn` cannot
    /// express the request — OpenBSD and musl for any request at all, Android
    /// below API 34 for a working directory — the unforced case legitimately
    /// takes the fallback too, and asserting `posix_spawn` there would fail for
    /// a reason that is not a bug. Deriving the expectation from the same rules
    /// the implementation consults keeps these tests strict everywhere
    /// `posix_spawn` is genuinely usable without making them wrong where it is
    /// not.
    ///
    /// What this defends, precisely: calling the real
    /// `requiresFallbackSpawnPath` as the oracle means a wrong *rule* is
    /// mirrored here and cancels out, so these assertions cannot catch one. What
    /// they do catch is the rules being *bypassed* — a spawn that ignores them
    /// and takes a path they did not choose. Rule content is covered instead by
    /// the cases in `SpawnPathTests` that pass explicit `SpawnCapabilities`
    /// values rather than consulting the host's, which is why those fixed-
    /// capability cases must not be folded into this helper.
    ///
    /// Called outside any `withSpawnPath` scope, so the task-local override does
    /// not feed back into the rules; `forceFallback` is applied here instead.
    fileprivate func expectsFallbackPath(
        forceFallback: Bool,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        supplementaryGroups: [gid_t]? = nil
    ) -> Bool {
        if forceFallback {
            return true
        }
        return Configuration(
            executable: .path("/bin/sh"),
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        ).requiresFallbackSpawnPath(supplementaryGroups: supplementaryGroups)
    }
}

extension SubprocessUnixTests {
    private func assertID(
        withArgument argument: String,
        platformOptions: PlatformOptions,
        isEqualTo expected: gid_t
    ) async throws {
        let idResult = try await Subprocess.run(
            .path("/usr/bin/id"),
            arguments: [argument],
            platformOptions: platformOptions,
            output: .string(limit: 32)
        )
        #expect(idResult.terminationStatus.isSuccess)
        let id = idResult.standardOutput
        #expect(
            id.trimmingCharacters(in: .whitespacesAndNewlines) == "\(expected)"
        )
    }
}

internal func assertNewSessionCreated<Output: OutputProtocol>(
    with result: ExecutionResult<
        Void,
        StringOutput<UTF8>,
        Output
    >
) throws {
    try assertNewSessionCreated(
        terminationStatus: result.terminationStatus,
        output: result.standardOutput
    )
}

internal func assertNewSessionCreated(
    terminationStatus: TerminationStatus,
    output psValue: String
) throws {
    #expect(terminationStatus.isSuccess)

    let match = try #require(try #/\s*PID\s*PGID\s*TPGID\s*(?<pid>[\-]?[0-9]+)\s*(?<pgid>[\-]?[0-9]+)\s*(?<tpgid>[\-]?[0-9]+)\s*/#.wholeMatch(in: psValue), "ps output was in an unexpected format:\n\n\(psValue)")
    // If setsid() has been called successfully, we should observe:
    // - pid == pgid
    // - tpgid <= 0
    let pid = try #require(Int(match.output.pid))
    let pgid = try #require(Int(match.output.pgid))
    let tpgid = try #require(Int(match.output.tpgid))
    #expect(pid == pgid)
    #expect(tpgid <= 0)
}

#if os(Android)
internal func assertNewSessionCreated<Output: OutputProtocol>(
    fromProcStat result: ExecutionResult<Void, StringOutput<UTF8>, Output>
) throws {
    #expect(result.terminationStatus.isSuccess)
    let statLine = result.standardOutput
    // `comm` can contain spaces and parentheses, so bracket it by the first
    // '(' and the last ')' rather than splitting the whole line on whitespace.
    let openParen = try #require(
        statLine.firstIndex(of: "("),
        "/proc stat was in an unexpected format:\n\n\(statLine)"
    )
    let closeParen = try #require(
        statLine.lastIndex(of: ")"),
        "/proc stat was in an unexpected format:\n\n\(statLine)"
    )
    let pid = try #require(Int(statLine[..<openParen].trimmingCharacters(in: .whitespaces)))
    // Fields after `comm`: [0] state, [1] ppid, [2] pgrp, [3] session, [4] tty_nr, [5] tpgid
    let fields = statLine[statLine.index(after: closeParen)...].split(separator: " ")
    try #require(fields.count >= 6, "/proc stat was in an unexpected format:\n\n\(statLine)")
    let pgid = try #require(Int(fields[2]))
    let session = try #require(Int(fields[3]))
    let tpgid = try #require(Int(fields[5]))
    #expect(pid == pgid)
    #expect(pid == session)
    #expect(tpgid <= 0)
}
#endif

extension FileDescriptor {
    /// Writes a line plus newline to the file descriptor.
    fileprivate func writeLine(_ line: String) throws {
        let bytes = Array("\(line)\n".utf8)
        try bytes.withUnsafeBufferPointer { ptr in
            _ = try self.write(UnsafeRawBufferPointer(ptr))
        }
    }

    /// Reads a single line (up to and excluding the next `\n`) from a
    /// non-blocking file descriptor, returning `nil` if no line arrives
    /// within `timeout`.
    fileprivate func readLine(timeout: Duration) async throws -> String? {
        let deadline = ContinuousClock.now + timeout
        var accumulated: [UInt8] = []

        while ContinuousClock.now < deadline {
            var byte: UInt8 = 0
            let n = withUnsafeMutablePointer(to: &byte) { ptr in
                #if canImport(Darwin)
                return Darwin.read(self.rawValue, ptr, 1)
                #elseif canImport(Android)
                return Android.read(self.rawValue, ptr, 1)
                #elseif canImport(Glibc)
                return Glibc.read(self.rawValue, ptr, 1)
                #elseif canImport(Musl)
                return Musl.read(self.rawValue, ptr, 1)
                #endif
            }

            if n == 1 {
                if byte == 0x0A {
                    return String(decoding: accumulated, as: UTF8.self)
                }
                accumulated.append(byte)
            } else if n == 0 {
                return accumulated.isEmpty ? nil : String(decoding: accumulated, as: UTF8.self)
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                try await Task.sleep(for: .milliseconds(5))
            } else if errno == EINTR {
                continue
            } else {
                throw Errno(rawValue: errno)
            }
        }
        return nil
    }
}

// MARK: - Performance Tests
extension SubprocessUnixTests {
    #if SubprocessFoundation && !os(Android)
    @Test(.requiresBash) func testConcurrentRun() async throws {
        /// This test runs inside an exit test for two reasons:
        ///
        /// 1) Isolated process means no sibling test suites share its fd/handle table. That makes the
        /// resource count deterministic and lets us assert a strict threshold
        /// instead of relying on sampling/timing heuristics.
        ///
        /// 2) IODescriptor deinit now `fatalError`s if the descriptor is not closed. An exit test will
        /// help us catch fd leaks without crashing the whole test suite.
        await #expect(processExitsWith: .success) {
            // Read the soft fd limit via a C shim: RLIMIT_NOFILE's Swift type
            // varies across platforms and Swift versions, so calling getrlimit
            // directly from Swift is not reliably portable.
            // Cap at 4096: Docker containers can report limits like 2^20.
            let softLimit = Int(min(_subprocess_nofile_soft_limit(), UInt64(4096)))

            // Account for the fds already open in this (now isolated) process
            // so the concurrent burst stays within RLIMIT_NOFILE. /proc/self/fd
            // lists every open descriptor; subtracting it plus a small margin
            // gives the true available headroom. In the isolated child this
            // count is stable, so the budget is reproducible run to run.
            #if os(Linux) || os(Android)
            let currentFds = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd"))?.count ?? 50
            let available = max(32, softLimit - currentFds - 50)
            #else
            let available = softLimit
            #endif
            // Each concurrent spawn holds both ends of the stdout and stderr pipes
            // plus a temporary exec-error notification pipe while the child's
            // exec() completes — roughly 6–8 fds per in-flight spawn.  Divide by
            // 8 to leave headroom and avoid EMFILE under high concurrency.
            let maxConcurrent = available / 8
            try await withThrowingTaskGroup(of: Void.self) { group in
                var running = 0
                let byteCount = 1000
                for _ in 0..<maxConcurrent {
                    group.addTask {
                        // Catch errors so a single spawn/monitor failure doesn't
                        // cascade-cancel sibling tasks (which would SIGKILL their
                        // live subprocesses and flood the log with false failures).
                        do {
                            // This invocation specifically requires bash semantics; sh (on FreeBSD at least) does not consistently support -s in this way
                            let r = try await Subprocess.run(
                                .name("bash"),
                                arguments: [
                                    "-sc", #"echo "$1" && echo "$1" >&2"#, "--", String(repeating: "X", count: byteCount),
                                ],
                                output: .data(limit: .max),
                                error: .data(limit: .max)
                            )
                            guard r.terminationStatus.isSuccess else {
                                Issue.record("Unexpected exit \(r.terminationStatus) from \(r.processIdentifier)")
                                return
                            }
                            #expect(r.standardOutput.count == byteCount + 1, "\(r.standardOutput)")
                            #expect(r.standardError.count == byteCount + 1, "\(r.standardError)")
                        } catch {
                            Issue.record("Subprocess.run threw: \(error)")
                        }
                    }
                    running += 1
                    // Throttle to maxConcurrent/8 live subprocesses at a time
                    // (rather than /4) to reduce peak memory pressure on
                    // memory-constrained kernel-testing VMs (e.g. QEMU + 5.10).
                    if running >= maxConcurrent / 8 {
                        try await group.next()
                    }
                }
                try await group.waitForAll()
            }
        }
    }
    #endif
}

// MARK: - Standard Input Inheritance
extension SubprocessUnixTests {
    @Test func testInheritStandardInput() async throws {
        // Exercises the public `InputProtocol.standardInput`: the child inherits
        // the parent's own standard input (fd 0). We temporarily point fd 0 at a
        // pipe we control, feed it a line, and confirm the child reads it back.
        //
        // Not ported to Windows: the equivalent would require swapping the test
        // host's own `STD_INPUT_HANDLE` / CRT fd 0 — global console state that
        // can't be changed safely or verified from here.
        let savedStdin = dup(STDIN_FILENO)
        try #require(savedStdin >= 0, "dup(STDIN_FILENO) failed: \(errno)")
        defer {
            _ = dup2(savedStdin, STDIN_FILENO)
            _ = close(savedStdin)
        }

        let pipe = try FileDescriptor.pipe()
        // Point our own stdin at the pipe's read end so the child inherits it.
        try #require(
            dup2(pipe.readEnd.rawValue, STDIN_FILENO) >= 0,
            "dup2 onto STDIN_FILENO failed: \(errno)"
        )

        // Send one line and close the write end so the child sees EOF.
        try pipe.writeEnd.writeLine("hello from parent stdin")
        try pipe.writeEnd.close()

        let result = try await Subprocess.run(
            .path("/bin/cat"),
            arguments: [],
            input: .currentStandardInput,
            output: .string(limit: 256),
            error: .discarded
        )
        try pipe.readEnd.close()

        #expect(result.terminationStatus.isSuccess)
        #expect(result.standardOutput.trimmingNewLineAndQuotes() == "hello from parent stdin")
    }
}

// MARK: - Pseudo-Terminal Input
extension SubprocessUnixTests {
    @Test func testInheritStdinFromPseudoTerminal() async throws {
        // Hand the child a pseudo-terminal replica as its standard input,
        // proving an arbitrary inherited file descriptor (not a regular file or
        // ordinary pipe) works as input.
        //
        // Not ported to Windows: there is no `openpty`/`termios` equivalent; the
        // Windows pseudo-console (ConPTY) is an unrelated API.
        var primaryFD: CInt = -1
        var replicaFD: CInt = -1
        try #require(
            openpty(&primaryFD, &replicaFD, nil, nil, nil) == 0,
            "openpty failed: \(errno)"
        )
        let primary = FileDescriptor(rawValue: primaryFD)
        let replica = FileDescriptor(rawValue: replicaFD)

        // Raw mode so bytes pass through verbatim (no echo or line editing).
        var settings = termios()
        try #require(tcgetattr(replicaFD, &settings) == 0, "tcgetattr failed: \(errno)")
        cfmakeraw(&settings)
        try #require(tcsetattr(replicaFD, TCSANOW, &settings) == 0, "tcsetattr failed: \(errno)")

        let payload = "pty stdin works"
        // Pre-fill the pty buffer with a single newline-terminated line; the
        // child reads that line and then exits, closing its inherited replica.
        // `cfmakeraw` cleared `ICRNL`, so the newline arrives verbatim.
        try Array("\(payload)\n".utf8).withUnsafeBytes { buffer in
            _ = try primary.write(buffer)
        }

        let result = try await Subprocess.run(
            .name("head"),
            // A line count rather than a byte count because OpenBSD's `head`
            // implements only `-n`.
            arguments: ["-n", "1"],
            // The replica is owned by Subprocess (closed after spawn); we keep
            // and close the primary ourselves.
            input: .fileDescriptor(replica, closeAfterSpawningProcess: true),
            output: .string(limit: 256),
            error: .discarded
        )
        try primary.close()

        #expect(result.terminationStatus.isSuccess)
        #expect(result.standardOutput.trimmingNewLineAndQuotes() == payload)
    }
}

extension Trait where Self == ConditionTrait {
    /// Creating a FIFO is not permitted everywhere: on Android `mkfifo` fails
    /// in the temporary directory, and a sandbox can deny it anywhere.
    static var requiresFIFOCreation: Self {
        enabled(
            "This test requires creating a FIFO in the temporary directory",
            {
                let path = FileManager.default.temporaryDirectory
                    .appendingPathComponent("fifo-probe-\(UUID().uuidString)")
                    ._fileSystemPath
                guard path.withCString({ mkfifo($0, 0o600) }) == 0 else {
                    return false
                }
                try? FileManager.default.removeItem(atPath: path)
                return true
            }
        )
    }
}

#endif // !os(Windows)
