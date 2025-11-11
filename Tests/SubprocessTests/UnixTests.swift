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

#if canImport(Darwin) || canImport(Glibc)

#if canImport(Darwin)
// On Darwin always prefer system Foundation
import Foundation
#else
// On other platforms prefer FoundationEssentials
import FoundationEssentials
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Musl)
import Musl
#endif

import _SubprocessCShims
import Testing
@testable import Subprocess

import TestResources

import Dispatch
#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

@Suite(.serialized)
struct SubprocessUnixTests {}

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
        let idResult = try await Subprocess.run(
            .name("swift"),
            arguments: [getgroupsSwift.string],
            platformOptions: platformOptions,
            output: .string(limit: .max),
            error: .string(limit: .max),
        )
        #expect(idResult.terminationStatus.isSuccess)
        let ids = try #require(
            idResult.standardOutput
        ).split(separator: ",")
            .map { try #require(gid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))) }
        #expect(Set(ids) == expectedGroups)
    }

    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        ),
        .enabled(
            if: (try? Executable.name("ps").resolveExecutablePath(in: .inherit)) != nil,
            "This test requires ps (install procps package on Debian or RedHat Linux distros)"
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
            if: (try? Executable.name("ps").resolveExecutablePath(in: .inherit)) != nil,
            "This test requires ps (install procps package on Debian or RedHat Linux distros)"
        )
    )
    func testSubprocessPlatformOptionsCreateSession() async throws {
        // platformOptions.createSession implies calls to setsid
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        // Check the process ID (pid), process group ID (pgid), and
        // controlling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        try assertNewSessionCreated(with: psResult)
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
                while true; do sleep 1; done
                exit 2
                """,
            ],
            input: .none,
            error: .discarded
        ) { subprocess, standardOutput in
            return try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .milliseconds(200))
                    // Send shut down signal
                    await subprocess.teardown(using: [
                        .send(signal: .quit, allowedDurationToNextStep: .milliseconds(500)),
                        .send(signal: .terminate, allowedDurationToNextStep: .milliseconds(500)),
                        .send(signal: .interrupt, allowedDurationToNextStep: .milliseconds(1000)),
                    ])
                }
                group.addTask {
                    var outputs: [String] = []
                    for try await line in standardOutput.lines() {
                        outputs.append(line.trimmingCharacters(in: .newlines))
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
    @Test func testExitSignal() async throws {
        let signalsToTest: [CInt] = [SIGKILL, SIGTERM, SIGINT]
        for signal in signalsToTest {
            let result = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "kill -\(signal) $$"],
                output: .discarded
            )
            #expect(result.terminationStatus == .unhandledException(signal))
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
        #expect(result == .unhandledException(SIGKILL))
    }

    @Test(.requiresBash)
    func testRunawayProcess() async throws {
        do {
            try await withThrowingTaskGroup { group in
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
                        output: .string(limit: .max),
                        error: .fileDescriptor(.standardError, closeAfterSpawningProcess: false)
                    )
                    #expect(result.terminationStatus.isSuccess)
                    let output = try #require(result.standardOutput).trimmingNewLineAndQuotes()
                    let grandChildPid = try #require(pid_t(output))
                    // Make sure the grand child `/usr/bin/yes` actually exited
                    // This is unfortunately racy because the pid isn't immediately invalided
                    // once `kill` returns. Allow a few failures and delay to counter this
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
                    // Give the script some times to run
                    try await Task.sleep(for: .milliseconds(100))
                }
                // Wait for the sleep task to finish
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
        try await pipe.readEnd.closeAfter {
            let result = try await pipe.writeEnd.closeAfter {
                // Spawn bash and then attempt to write to the write end
                try await Subprocess.run(
                    .name("bash"),
                    arguments: [
                        "-c",
                        """
                        echo this string should be discarded >&\(pipe.writeEnd.rawValue);
                        echo wrote into \(pipe.writeEnd.rawValue), echo exit code $?;
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
                result.standardOutput?.trimmingNewLineAndQuotes() == "wrote into \(pipe.writeEnd.rawValue), echo exit code 1"
            )
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
    with result: CollectedResult<
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

#endif // canImport(Darwin) || canImport(Glibc)
