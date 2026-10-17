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
            let monitorResult = try await monitorProcessTermination(
                for: execution.processIdentifier
            )

            #expect(monitorResult.isSuccess)
        }
    }

    @Test func testExitCode() async throws {
        let config = self.immediateExitProcess(withExitCode: 42)
        try await withSpawnedExecution(config: config) { execution in
            let monitorResult = try await monitorProcessTermination(
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

            let result = try await monitorProcessTermination(
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
            let monitorResult = try await monitorProcessTermination(
                for: execution.processIdentifier
            )
            #expect(monitorResult == TerminationStatus.exited(0))
        }
    }

    @Test func testCanMonitorLongRunningProcess() async throws {
        let config = self.longRunningProcess(withTimeOutSeconds: 1)
        try await withSpawnedExecution(config: config) { execution in
            let monitorResult = try await monitorProcessTermination(
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
                let status = try await monitorProcessTermination(
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

#if !os(Windows)
// MARK: - Stopped Child Tests
//
// Darwin's `waitid` reports a stopped child even to queries that only ask for
// `WEXITED`. A stop notification must never be mistaken for the child's
// termination.
extension SubprocessProcessMonitoringTests {
    @Test(.timeLimit(.minutes(1)))
    func testStoppedChildIsNotReportedAsExited() async throws {
        var config = self.longRunningProcess(withTimeOutSeconds: 30)
        config.platformOptions.createSession = true
        try await withSpawnedExecution(config: config) { execution in
            let pid = execution.processIdentifier.value
            // This fixture owns the unreaped child until this scope ends.
            defer { self.killAndReap(pid) }
            try execution.send(signal: .suspend)
            try await self.waitUntilStopped(pid)
            #expect(
                try !execution.processIdentifier.peekIfExited(),
                "A stop notification is not a terminal exit")
            // Observing an exit must not consume another observer's stop event.
            var pending = siginfo_t()
            try #require(waitid(P_PID, id_t(pid), &pending, WSTOPPED | WNOHANG | WNOWAIT) == 0)
            #expect(pending.si_code == CLD_STOPPED)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testMonitoringStoppedChildWaitsForItsFinalExit() async throws {
        let config = self.selfStoppingProcess(thenRun: "exit 42")
        try await withSpawnedExecution(config: config) { execution in
            let pid = execution.processIdentifier.value
            var reaped = false
            defer { if !reaped { self.killAndReap(pid) } }
            try await self.waitUntilStopped(pid)
            // The monitor must stay pending until the explicit resume allows exit.
            let start = ContinuousClock.now
            let resume = Task {
                try await Task.sleep(for: .milliseconds(100))
                try execution.send(signal: .resume)
            }
            defer { resume.cancel() }
            try await waitForProcessTermination(for: execution.processIdentifier)
            #expect(ContinuousClock.now - start >= .milliseconds(100), "Monitoring ended before the resume")
            let result = try reapProcess(with: execution.processIdentifier)
            reaped = true
            try await resume.value
            #expect(result == .exited(42))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testTeardownKillsStoppedChild() async throws {
        // A stopped child can't run its SIGTERM handler, so only the final
        // SIGKILL ends it. Teardown must not mistake the stop for an exit and
        // skip that step.
        let config = self.selfStoppingProcess(setup: "trap 'exit 0' TERM", thenRun: "exit 42")
        try await withSpawnedExecution(config: config) { execution in
            let pid = execution.processIdentifier.value
            var reaped = false
            defer { if !reaped { self.killAndReap(pid) } }
            try await self.waitUntilStopped(pid)
            await execution.teardown(using: [
                .gracefulShutDown(allowedDurationToNextStep: .milliseconds(200))
            ])
            // Poll with a deadline: if teardown skipped the SIGKILL, a blocking
            // reap would hang on the stopped child.
            let status = try await self.reapUntilTerminated(execution.processIdentifier)
            reaped = true
            #expect(status == .signaled(SIGKILL))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testReapWaitsForStoppedChildToExit() async throws {
        let config = self.selfStoppingProcess(thenRun: "exit 42")
        try await withSpawnedExecution(config: config) { execution in
            let pid = execution.processIdentifier.value
            var reaped = false
            defer { if !reaped { self.killAndReap(pid) } }
            try await self.waitUntilStopped(pid)
            #expect(
                try execution.processIdentifier.reap() == nil,
                "A stop notification is not a terminal exit")
            // Darwin can lose a SIGCONT sent right as the child stops.
            try await Task.sleep(for: .milliseconds(10))
            try execution.send(signal: .resume)
            let status = try await self.reapUntilTerminated(execution.processIdentifier)
            reaped = true
            #expect(status == .exited(42))
            // The zombie was consumed, so the status is reported only once.
            #expect(throws: Errno(rawValue: ECHILD)) {
                _ = try execution.processIdentifier.reap()
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testBlockingReapWaitsForStoppedChildToTerminate() async throws {
        var config = self.longRunningProcess(withTimeOutSeconds: 30)
        config.platformOptions.createSession = true
        try await withSpawnedExecution(config: config) { execution in
            let pid = execution.processIdentifier.value
            var reaped = false
            defer { if !reaped { self.killAndReap(pid) } }
            try execution.send(signal: .suspend)
            try await self.waitUntilStopped(pid)
            // The blocking reap must skip the pending stop notification and
            // wait until the kill terminates the child.
            let killer = self.onSeparateThread {
                usleep(100_000)
                if !Thread.current.isCancelled { try? execution.send(signal: .kill) }
            }
            defer { self.cancelAndJoin(killer) }
            let status = try reapProcess(with: execution.processIdentifier)
            reaped = true
            #expect(status == .signaled(SIGKILL))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testBlockingReapDoesNotSpinOnRepeatedStops() async throws {
        var config = self.longRunningProcess(withTimeOutSeconds: 30)
        config.platformOptions.createSession = true
        try await withSpawnedExecution(config: config) { execution in
            let pid = execution.processIdentifier.value
            var reaped = false
            defer { if !reaped { self.killAndReap(pid) } }
            // On Darwin, each stop is reported and consumed once, so the reap
            // loop runs once per stop and otherwise blocks in the kernel.
            let signaler = self.onSeparateThread {
                for _ in 0..<10 where !Thread.current.isCancelled {
                    try? execution.send(signal: .suspend)
                    usleep(20_000)
                    try? execution.send(signal: .resume)
                    usleep(20_000)
                }
                if !Thread.current.isCancelled { try? execution.send(signal: .kill) }
            }
            defer { self.cancelAndJoin(signaler) }
            let start = ContinuousClock.now
            let cpuStart = self.currentThreadCPUTime()
            let status = try reapProcess(with: execution.processIdentifier)
            let cpuUsed = self.currentThreadCPUTime() - cpuStart
            let elapsed = ContinuousClock.now - start
            reaped = true
            #expect(status == .signaled(SIGKILL))
            // A loop that kept seeing the same stop would spin for the whole wait.
            #expect(cpuUsed < elapsed / 4, "Used \(cpuUsed) of CPU while waiting \(elapsed)")
        }
    }

    /// A child that runs `setup`, stops itself with SIGSTOP, and runs
    /// `command` once resumed.
    private func selfStoppingProcess(setup: String? = nil, thenRun command: String) -> Configuration {
        let script = [setup, "kill -STOP $$", command].compactMap { $0 }.joined(separator: "; ")
        var config = Configuration(
            executable: .path("/bin/sh"),
            arguments: ["-c", script]
        )
        // A stopped process left in the test runner's process group would get
        // SIGHUP+SIGCONT, along with this test process, if that group were
        // orphaned. Isolate the child in its own session.
        config.platformOptions.createSession = true
        return config
    }

    private func killAndReap(_ pid: pid_t) {
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    private func waitUntilStopped(_ pid: pid_t) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            var info = siginfo_t()
            try #require(waitid(P_PID, id_t(pid), &info, WSTOPPED | WNOHANG | WNOWAIT) == 0)
            if info.si_code == CLD_STOPPED { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The fixture did not stop before testing exit observation")
        throw Errno.timedOut
    }

    /// Polls the non-blocking `reap()` until the child terminates.
    private func reapUntilTerminated(
        _ processIdentifier: ProcessIdentifier
    ) async throws -> TerminationStatus {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let status = try processIdentifier.reap() {
                return status
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The fixture did not terminate before the deadline")
        throw Errno.timedOut
    }

    /// Runs `body` on its own thread. A test blocked in `reapProcess` holds a
    /// concurrency thread, so a task meant to signal the child might never run.
    private func onSeparateThread(_ body: @escaping @Sendable () -> Void) -> Thread {
        let thread = Thread(block: body)
        thread.start()
        return thread
    }

    /// Stops `thread` and waits for it to finish, so it can't signal a child
    /// that was already reaped.
    private func cancelAndJoin(_ thread: Thread) {
        thread.cancel()
        while !thread.isFinished {
            usleep(1_000)
        }
    }

    private func currentThreadCPUTime() -> Duration {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }
}
#endif

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
                        let monitorResult = try await monitorProcessTermination(
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
            let status = try reapProcess(with: execution.processIdentifier)
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
                    let status = try await monitorProcessTermination(for: pid)
                    #expect(status.isSuccess)
                }
            }

            try await group.waitForAll()
        }
    }
}

internal func monitorProcessTermination(for processIdentifier: ProcessIdentifier) async throws -> TerminationStatus {
    try await waitForProcessTermination(for: processIdentifier)
    return try reapProcess(with: processIdentifier)
}
