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
import System
#else
import SystemPackage
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

import Testing
import Foundation
import TestResources
import _SubprocessCShims
@testable import Subprocess

@Suite("Subprocess Process Monitoring Unit Tests", .serialized)
struct SubprocessProcessMonitoringTests {

    init() {
        _ = globallyIgnoredSIGPIPE
        #if !os(Windows)
        _setupMonitorSignalHandler()
        #endif
    }

    private func immediateExitProcess(withExitCode code: Int) -> Configuration {
        #if os(Windows)
        return Configuration(
            executable: .name("cmd.exe"),
            arguments: ["/c", "exit \(code)"]
        )
        #else
        return Configuration(
            executable: .path("/bin/sh"),
            arguments: ["-c", "exit \(code)"]
        )
        #endif
    }

    private func longRunningProcess(withTimeOutSeconds timeout: Double? = nil) -> Configuration {
        #if os(Windows)
        let waitTime = timeout ?? 99999
        return Configuration(
            executable: .name("powershell.exe"),
            arguments: ["-Command", "Start-Sleep -Seconds \(waitTime)"]
        )
        #else
        let waitTime = timeout.map { "\($0)" } ?? "infinite"
        return Configuration(
            executable: .path("/bin/sleep"),
            arguments: [waitTime]
        )
        #endif
    }

    private func devNullInputPipe() throws -> CreatedPipe {
        #if os(Windows)
        let devnullFd: FileDescriptor = try .openDevNull(withAccessMode: .writeOnly)
        let devnull = try #require(HANDLE(bitPattern: _get_osfhandle(devnullFd.rawValue)))
        #else
        let devnull: FileDescriptor = try .openDevNull(withAccessMode: .readOnly)
        #endif
        return CreatedPipe(
            readFileDescriptor: .init(devnull, closeWhenDone: true),
            writeFileDescriptor: nil
        )
    }

    private func devNullOutputPipe() throws -> CreatedPipe {
        #if os(Windows)
        let devnullFd: FileDescriptor = try .openDevNull(withAccessMode: .writeOnly)
        let devnull = try #require(HANDLE(bitPattern: _get_osfhandle(devnullFd.rawValue)))
        #else
        let devnull: FileDescriptor = try .openDevNull(withAccessMode: .writeOnly)
        #endif
        return CreatedPipe(
            readFileDescriptor: nil,
            writeFileDescriptor: .init(devnull, closeWhenDone: true)
        )
    }

    private func withSpawnedExecution(
        config: Configuration,
        _ body: (Execution<NoInput, DiscardedOutput, DiscardedOutput>) async throws -> Void
    ) async throws {
        let spawnResult = try await config.spawn(
            withInput: self.devNullInputPipe(),
            outputPipe: self.devNullOutputPipe(),
            errorPipe: self.devNullOutputPipe()
        )
        defer {
            spawnResult.processIdentifier.close()
        }
        let execution = Execution<NoInput, DiscardedOutput, DiscardedOutput>(
            processIdentifier: spawnResult.processIdentifier,
            inputWriter: nil,
            outputStream: nil,
            errorStream: nil
        )
        try await body(execution)
    }
}

// MARK: - Basic Functionality Tests
extension SubprocessProcessMonitoringTests {
    @Test func testNormalExit() async throws {
        let config = self.immediateExitProcess(withExitCode: 0)
        try await withSpawnedExecution(config: config) { execution in
            let (monitorResult, _) = try await monitorProcessTermination(
                for: execution.processIdentifier
            )
            #expect(monitorResult.isSuccess)
        }
    }

    @Test func testExitCode() async throws {
        let config = self.immediateExitProcess(withExitCode: 42)
        try await withSpawnedExecution(config: config) { execution in
            let (monitorResult, _) = try await monitorProcessTermination(
                for: execution.processIdentifier
            )
            #expect(monitorResult == .exited(42))
        }
    }

    #if !os(Windows)
    @Test func testExitViaSignal() async throws {
        let config = Configuration(
            executable: .name("tail"),
            arguments: ["-f", "/dev/null"]
        )
        try await withSpawnedExecution(config: config) { execution in
            // Send signal to process
            try execution.send(signal: .terminate)

            let (result, _) = try await monitorProcessTermination(
                for: execution.processIdentifier
            )
            #expect(result == .signaled(SIGTERM))
        }
    }
    #endif
}

// MARK: - Edge Cases
extension SubprocessProcessMonitoringTests {
    @Test func testAlreadyTerminatedProcess() async throws {
        let config = self.immediateExitProcess(withExitCode: 0)
        try await withSpawnedExecution(config: config) { execution in
            // Manually wait for the process to make sure it exits
            #if os(Windows)
            WaitForSingleObject(
                execution.processIdentifier.processDescriptor,
                INFINITE
            )
            #else
            var siginfo = siginfo_t()
            waitid(
                P_PID,
                id_t(execution.processIdentifier.value),
                &siginfo,
                WEXITED | WNOWAIT
            )
            #endif
            // Now make sure monitorProcessTermination() can still get the correct result
            let (monitorResult, _) = try await monitorProcessTermination(
                for: execution.processIdentifier
            )
            #expect(monitorResult == TerminationStatus.exited(0))
        }
    }

    @Test func testCanMonitorLongRunningProcess() async throws {
        let config = self.longRunningProcess(withTimeOutSeconds: 1)
        try await withSpawnedExecution(config: config) { execution in
            let (monitorResult, _) = try await monitorProcessTermination(
                for: execution.processIdentifier
            )
            #expect(monitorResult.isSuccess)
        }
    }

    @Test func testInvalidProcessIdentifier() async throws {
        #if os(Windows)
        let underlying = SubprocessError.WindowsError(win32Error: DWORD(ERROR_INVALID_PARAMETER))
        let processIdentifier = ProcessIdentifier(
            value: .max,
            processDescriptor: INVALID_HANDLE_VALUE,
            threadHandle: INVALID_HANDLE_VALUE,
            jobHandle: INVALID_HANDLE_VALUE
        )
        #elseif os(Linux) || os(Android) || os(FreeBSD) || os(OpenBSD)
        let underlying = Errno(rawValue: ECHILD)
        let processIdentifier = ProcessIdentifier(
            value: .max, processDescriptor: -1
        )
        #else
        let underlying = Errno(rawValue: ECHILD)
        let processIdentifier = ProcessIdentifier(value: .max)
        #endif

        let expectedError: SubprocessError = .failedToMonitor(withUnderlyingError: underlying)

        await #expect(throws: expectedError) {
            _ = try await monitorProcessTermination(for: processIdentifier)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testDoesNotReapUnrelatedChildProcess() async throws {
        // Make sure we don't reap child exit status that we didn't spawn
        let child1 = self.immediateExitProcess(withExitCode: 0)
        let child2 = self.immediateExitProcess(withExitCode: 0)
        try await withSpawnedExecution(config: child1) { child1Execution in
            try await withSpawnedExecution(config: child2) { child2Execution in
                // Monitor child2, but make sure we don't reap child1's status
                let (status, _) = try await monitorProcessTermination(
                    for: child2Execution.processIdentifier
                )
                #expect(status.isSuccess)
                // Make sure we can still fetch child 1
                #if os(Windows)
                let rc = WaitForSingleObject(
                    child1Execution.processIdentifier.processDescriptor,
                    INFINITE
                )
                #expect(rc == WAIT_OBJECT_0)
                var child1Status: DWORD = 0
                let rc2 = GetExitCodeProcess(
                    child1Execution.processIdentifier.processDescriptor,
                    &child1Status
                )
                #expect(rc2 == true)
                #expect(child1Status == 0)
                #else
                var siginfo = siginfo_t()
                let rc = waitid(
                    P_PID,
                    id_t(child1Execution.processIdentifier.value),
                    &siginfo,
                    WEXITED
                )
                #expect(rc == 0)
                #expect(siginfo.si_code == CLD_EXITED)
                #expect(siginfo.si_status == 0)
                #endif
            }
        }
    }
}

// MARK: Concurrency Tests
extension SubprocessProcessMonitoringTests {
    @Test func testCanMonitorProcessConcurrently() async throws {
        let testCount = 100
        try await withThrowingTaskGroup { group in
            for _ in 0..<testCount {
                group.addTask {
                    // Sleep for different random time intervals
                    let config = self.longRunningProcess(
                        withTimeOutSeconds: Double.random(in: 0..<1.0)
                    )

                    try await withSpawnedExecution(config: config) { execution in
                        let (monitorResult, _) = try await monitorProcessTermination(
                            for: execution.processIdentifier
                        )
                        #expect(monitorResult.isSuccess)
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    @Test func testCanMonitorSameProcessConcurrently() async throws {
        // Multiple tasks waiting on the *same* process must all observe its
        // termination. This is the idempotency contract of
        // waitForProcessTermination: registering the same process for
        // monitoring more than once concurrently must succeed on every
        // platform. (On Linux >= 5.4 this specifically guards against
        // double-registering the pidfd with epoll, which fails with EEXIST.)
        let waiterCount = 10
        // Keep the child alive long enough that every waiter registers
        // before it exits, so the concurrent-registration path is exercised.
        let config = self.longRunningProcess(withTimeOutSeconds: 1)
        try await withSpawnedExecution(config: config) { execution in
            try await withThrowingTaskGroup { group in
                for _ in 0..<waiterCount {
                    group.addTask {
                        // Call the monitoring primitive directly instead of
                        // monitorProcessTermination: the zombie must be reaped
                        // exactly once, so we reap only after every waiter has
                        // observed termination.
                        try await waitForProcessTermination(
                            for: execution.processIdentifier
                        )
                    }
                }

                try await group.waitForAll()
            }
            // Every waiter resumed without error; reap the process once.
            let (status, _) = try reapProcess(with: execution.processIdentifier)
            #expect(status.isSuccess)
        }
    }

    @Test func testExitSignalCoalescing() async throws {
        // Spawn many immediately exit processes in a row to trigger
        // signal coalescing. Make sure we can handle this
        let testCount = 100
        var spawnedProcesses: [ProcessIdentifier] = []

        defer {
            for pid in spawnedProcesses {
                pid.close()
            }
        }

        for _ in 0..<testCount {
            let config = self.immediateExitProcess(withExitCode: 0)
            let spawnResult = try await config.spawn(
                withInput: self.devNullInputPipe(),
                outputPipe: self.devNullOutputPipe(),
                errorPipe: self.devNullOutputPipe()
            )
            spawnedProcesses.append(spawnResult.processIdentifier)
        }

        try await withThrowingTaskGroup { group in
            for pid in spawnedProcesses {
                group.addTask {
                    let (status, _) = try await monitorProcessTermination(for: pid)
                    #expect(status.isSuccess)
                }
            }

            try await group.waitForAll()
        }
    }
}

// MARK: - Resource Usage Tests

/// Bounds here are deliberately loose. The failure mode worth catching is a
/// platform that wires `ResourceUsage` up structurally but reports zeros, so
/// these assert orders of magnitude rather than values.
extension SubprocessProcessMonitoringTests {
    /// Burns CPU in-process so `userTime` has something to report.
    private func cpuBoundProcess() -> Configuration {
        #if os(Windows)
        return Configuration(
            executable: .name("powershell.exe"),
            arguments: ["-Command", "$i = 0; while ($i -lt 3000000) { $i++ }"]
        )
        #else
        return Configuration(
            executable: .path("/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done"]
        )
        #endif
    }

    /// Allocates a buffer of `bytes` by asking `dd` for it as a single block.
    /// The byte count is spelled out because `dd` suffix syntax isn't portable.
    private func allocatingProcess(bytes: Int) -> Configuration {
        return Configuration(
            executable: .path("/bin/dd"),
            arguments: ["if=/dev/zero", "of=/dev/null", "bs=\(bytes)", "count=1"]
        )
    }

    @Test func testResourceUsageReportsCPUTime() async throws {
        let result = try await run(self.cpuBoundProcess(), output: .discarded)
        #expect(result.terminationStatus.isSuccess)
        // A few hundred thousand shell loop iterations cannot cost zero.
        #expect(result.resourceUsage.userTime > .zero)
        #expect(result.resourceUsage.systemTime >= .zero)
        #expect(result.resourceUsage.maxRSS > 0)
    }

    @Test func testResourceUsageChargesOnlyCPUTimeNotWallTime() async throws {
        let result = try await run(self.longRunningProcess(withTimeOutSeconds: 1), output: .discarded)
        #expect(result.terminationStatus.isSuccess)
        #expect(result.resourceUsage.maxRSS > 0)
        #if !os(Windows)
        // The child slept for a second; almost none of that is its own CPU.
        //
        // Not asserted on Windows, where the only sleeper available without
        // adding a test helper is powershell.exe. Its interpreter startup costs
        // seconds of CPU on its own -- measured at 2.75s against a 1s sleep --
        // so the quantity this is checking isn't observable through it.
        // `testResourceUsageReportsCPUTime` still covers Windows CPU accounting.
        let cpuTime = result.resourceUsage.userTime + result.resourceUsage.systemTime
        #expect(cpuTime < .milliseconds(500))
        #endif
    }

    #if !os(Windows)
    @Test func testResourceUsageMaxRSSScalesWithAllocation() async throws {
        let allocation = 32 * 1024 * 1024
        let small = try await run(self.allocatingProcess(bytes: 1024), output: .discarded)
        let large = try await run(self.allocatingProcess(bytes: allocation), output: .discarded)
        #expect(small.terminationStatus.isSuccess)
        #expect(large.terminationStatus.isSuccess)
        // `maxRSS` is documented in bytes on every platform. If a platform's
        // KiB-to-bytes scaling were wrong, this would be off by 1024x.
        #expect(large.resourceUsage.maxRSS > allocation / 2)
        #expect(large.resourceUsage.maxRSS > small.resourceUsage.maxRSS)
    }

    @Test func testResourceUsageIsReportedForSignaledProcess() async throws {
        // The signal is sent from here rather than via `sh -c 'kill -TERM $$'`,
        // because whether a shell dies from the signal or traps it and exits
        // 128+signum is shell-specific: Android's mksh reports exited(143).
        let config = Configuration(
            executable: .name("tail"),
            arguments: ["-f", "/dev/null"]
        )
        try await withSpawnedExecution(config: config) { execution in
            try execution.send(signal: .terminate)
            let (status, usage) = try await monitorProcessTermination(
                for: execution.processIdentifier
            )
            #expect(status == .signaled(SIGTERM))
            // A child that died on a signal is still accounted for.
            #expect(usage.maxRSS > 0)
        }
    }

    @Test func testResourceUsageMatchesUnderlyingRusage() async throws {
        let result = try await run(self.cpuBoundProcess(), output: .discarded)
        let usage = result.resourceUsage
        let expectedUserTime =
            Duration.seconds(usage.rusage.ru_utime.tv_sec) + .microseconds(usage.rusage.ru_utime.tv_usec)
        let expectedSystemTime =
            Duration.seconds(usage.rusage.ru_stime.tv_sec) + .microseconds(usage.rusage.ru_stime.tv_usec)
        #expect(usage.userTime == expectedUserTime)
        #expect(usage.systemTime == expectedSystemTime)
    }
    #endif

    @Test func testResourceUsageEqualityIgnoresRawRusagePadding() async throws {
        let result = try await run(self.immediateExitProcess(withExitCode: 0), output: .discarded)
        let usage = result.resourceUsage
        // Equality and hashing are defined over the interpreted fields, so a
        // value always matches itself regardless of the raw C struct's bytes.
        #expect(usage == usage)
        #expect(Set([usage, usage]).count == 1)
    }
}

internal func monitorProcessTermination(for processIdentifier: ProcessIdentifier) async throws -> (TerminationStatus, ResourceUsage) {
    try await waitForProcessTermination(for: processIdentifier)
    return try reapProcess(with: processIdentifier)
}
