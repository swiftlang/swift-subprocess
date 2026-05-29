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
        #expect(idResult.terminationStatus.isSuccess, Comment(rawValue: idResult.standardError ?? ""))
        let ids = try #require(
            idResult.standardOutput
        ).split(separator: " ")
            .map { try #require(gid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))) }
        // id -G includes the effective GID (0 for root) along with
        // supplementary groups, so filter to just the expected range
        let actualGroups = Set(ids.filter { expectedGroups.contains($0) })
        #expect(actualGroups == expectedGroups, Comment(rawValue: idResult.standardError ?? ""))
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
        )
    )
    func testSubprocessPlatformOptionsProcessGroupID() async throws {
        var platformOptions = PlatformOptions()
        // Sets the process group ID to 0, which creates a new session
        platformOptions.processGroupID = 0
        let psResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "ps -o pid,pgid -p $$"],
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        #expect(psResult.terminationStatus.isSuccess)
        let resultValue = try #require(
            psResult.standardOutput
        )
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
        )
    )
    func testSubprocessPlatformOptionsCreateSession() async throws {
        // platformOptions.createSession implies calls to setsid
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        #if os(Android)
        // Android's `ps` doesn't support `-o pid,pgid,tpgid`. Read the shell's
        // session fields directly from /proc instead. `$$` is the shell's own
        // pid, which is the session and group leader after setsid; reading
        // /proc/self/stat would observe `cat`, which is not the leader.
        let statResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "cat /proc/$$/stat"],
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        try assertNewSessionCreated(fromProcStat: statResult)
        #else
        // Check the process ID (pid), process group ID (pgid), and
        // controlling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        try assertNewSessionCreated(with: psResult)
        #endif
    }

    @Test(.requiresBash) func testTeardownSequence() async throws {
        let result = try await Subprocess.run(
            .name("bash"),
            arguments: [
                "-c",
                """
                set -e
                trap 'echo saw SIGQUIT;' QUIT
                trap 'echo saw SIGTERM;' TERM
                trap 'echo saw SIGINT; exit 42;' INT
                echo ready
                while true; do sleep 0.1; done
                exit 2
                """,
            ],
            input: .none,
            output: .sequence,
            error: .discarded
        ) { subprocess in
            return try await withThrowingTaskGroup(of: Void.self) { group in
                // Gate the teardown task on bash having actually installed
                // its signal traps. The reader signals readiness when it
                // sees the `ready` marker the script prints after the
                // `trap` lines.
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

// MARK: - PATH Resolution Tests
extension SubprocessUnixTests {
    @Test func testExecutablePathsPreserveOrder() throws {
        let executable = Executable.name("test-bin")
        let pathValue = "/first/path:/second/path:/third/path"

        let paths = executable.possibleExecutablePaths(withPathValue: pathValue)
        let pathsArray = Array(paths)

        #expect(
            pathsArray == [
                "test-bin",
                "/first/path/test-bin",
                "/second/path/test-bin",
                "/third/path/test-bin",

                // Default search paths
                "/usr/bin/test-bin",
                "/bin/test-bin",
                "/usr/sbin/test-bin",
                "/sbin/test-bin",
                "/usr/local/bin/test-bin",
            ])
    }

    @Test func testNoDuplicatedExecutablePaths() throws {
        let executable = Executable.name("test-bin")
        let duplicatePath = "/first/path:/first/path:/second/path"
        let duplicatePaths = executable.possibleExecutablePaths(withPathValue: duplicatePath)

        #expect(Array(duplicatePaths).count == Set(duplicatePaths).count)
    }

    @Test func testPossibleExecutablePathsWithNilPATH() throws {
        let executable = Executable.name("test-bin")
        let paths = executable.possibleExecutablePaths(withPathValue: nil)
        let pathsArray = Array(paths)

        #expect(
            pathsArray == [
                "test-bin",

                // Default search paths
                "/usr/bin/test-bin",
                "/bin/test-bin",
                "/usr/sbin/test-bin",
                "/sbin/test-bin",
                "/usr/local/bin/test-bin",
            ])
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

        try await outputPipe.readEnd.closeAfter {
            try await inputPipe.writeEnd.closeAfter {
                _ = try await Subprocess.run(
                    .path("/bin/cat"),
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
            #if os(Android)
            // When terminated by a catchable signal, Android's /bin/sh exits
            // normally with a status of 128+n instead of dying by the signal.
            // SIGKILL is uncatchable and still produces a signal-based termination.
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
                        // Send SIGINT for child to catch
                        .send(signal: .interrupt, allowedDurationToNextStep: .milliseconds(100))
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
                            # When SIGINT is sent to the script, kill grand child now
                            trap "echo >&2 'child: received signal, killing grand child ($child_pid)'; kill -s KILL $child_pid; exit 0" INT
                            echo "$child_pid" # communicate the child pid to our parent
                            echo "child: waiting for grand child, pid: $child_pid" >&2
                            wait $child_pid # wait for runaway child to exit
                            """,
                        ],
                        platformOptions: platformOptions,
                        input: .none,
                        output: .sequence,
                        error: .fileDescriptor(.standardError, closeAfterSpawningProcess: false)
                    ) { execution in
                        // Read stdout incrementally. Once we see the PID line,
                        // we know the trap is set up and it's safe to send SIGINT.
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
                    let grandChildPid = try #require(result.closureOutput)
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
                    let grandChildPid = try #require(result.closureOutput)
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

    @Test func testSubprocessDoesNotInheritVeryHighFileDescriptors() async throws {
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
        let shellScript =
            """
            for fd in "$@"; do
                if [ -e "/proc/self/fd/$fd" ] || [ -e "/dev/fd/$fd" ]; then
                    echo "$fd:OPEN"
                else
                    echo "$fd:CLOSED"
                fi
            done
            """
        var arguments = ["-c", shellScript, "--"]
        #if os(FreeBSD)
        arguments.append("") // FreeBSD /bin/sh interprets the first argument as the script name
        #endif
        arguments.append(contentsOf: openedFileDescriptors.map { "\($0)" })

        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: .init(arguments),
            output: .string(limit: .max),
            error: .string(limit: .max)
        )
        #expect(result.terminationStatus.isSuccess)
        #expect(result.standardError?.trimmingNewLineAndQuotes().isEmpty == true)
        var checklist = Set(openedFileDescriptors)
        let closeResult = try #require(result.standardOutput)
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
                result.standardOutput?.trimmingNewLineAndQuotes() == "wrote into \(testWriteEnd.rawValue), echo exit code 1"
            )
        }
    }

    // Ensure Subprocess does not hang on Linux when several concurrent
    // `Subprocess.run` calls saw their children exit in a tight burst.
    //
    // Spawns 16 `bash` children, each with a SIGTERM trap that sleeps one second
    // before exiting. Every body closure sends SIGTERM at roughly the same instant,
    // so all 16 children finish their trap and become zombies inside a single small.
    @Test(.requiresBash) func testConcurrentSlowExitsDoNotHang() async throws {
        // 16 concurrent slow-to-exit children is enough to flood the
        // monitor and trigger the burst on Linux.
        let count = 16
        // Trap SIGTERM, sleep 1 s in the handler, then exit. bash (not
        // POSIX sh) is required: `sh -c 'trap ...; sleep 300'` would defer
        // the trap until `sleep 300` completes, while bash interrupts
        // `wait` immediately on signal.
        let script = "trap 'sleep 1; exit 0' TERM; sleep 300 & wait"

        try await withThrowingTaskGroup(of: TerminationStatus.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let result = try await Subprocess.run(
                        .name("bash"),
                        arguments: ["-c", script],
                        input: .none,
                        output: .discarded,
                        error: .discarded
                    ) { execution in
                        // Let all N processes install their traps before
                        // we signal them, so the kills land in a tight
                        // burst and the children exit ~simultaneously.
                        try await Task.sleep(for: .milliseconds(100))
                        try execution.send(signal: .terminate)
                    }
                    return result.terminationStatus
                }
            }
            for try await status in group {
                #expect(status == .exited(0))
            }
        }
    }
}

// MARK: - Utils
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
        let id = try #require(idResult.standardOutput)
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
        output: #require(result.standardOutput)
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
    let statLine = try #require(result.standardOutput)
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
    #if SubprocessFoundation
    @Test(.requiresBash) func testConcurrentRun() async throws {
        // Launch as many processes as we can
        // Figure out the max open file limit
        let limitResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "ulimit -n"],
            output: .string(limit: 32)
        )
        guard
            let limitString = limitResult
                .standardOutput?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let ulimit = Int(limitString)
        else {
            Issue.record("Failed to run  ulimit -n")
            return
        }
        // Constrain to an ultimate upper limit of 4096, since Docker containers can have limits like 2^20 which is a bit too high for this test.
        // Common defaults are 2560 for macOS and 1024 for Linux.
        let limit = min(ulimit, 4096)
        // Since we open two pipes per `run`, launch
        // limit / 4 subprocesses should reveal any
        // file descriptor leaks
        let maxConcurrent = limit / 4
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            let byteCount = 1000
            for _ in 0..<maxConcurrent {
                group.addTask {
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
                }
                running += 1
                if running >= maxConcurrent / 4 {
                    try await group.next()
                }
            }
            try await group.waitForAll()
        }
    }
    #endif
}

#endif // !os(Windows)
