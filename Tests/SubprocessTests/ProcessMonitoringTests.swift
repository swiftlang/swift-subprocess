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
import Dispatch
import Foundation
import TestResources
import _SubprocessCShims
@testable import Subprocess

@Suite("Subprocess Process Monitoring Unit Tests", .serialized)
struct SubprocessProcessMonitoringTests {

    init() {
        #if os(Linux) || os(Android)
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
        _ body: (Execution) async throws -> Void
    ) async throws {
        let spawnResult = try await config.spawn(
            withInput: self.devNullInputPipe(),
            outputPipe: self.devNullOutputPipe(),
            errorPipe: self.devNullOutputPipe()
        )
        defer {
            spawnResult.execution.processIdentifier.close()
        }
        try await body(spawnResult.execution)
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
            executable: .path("/usr/bin/tail"),
            arguments: ["-f", "/dev/null"]
        )
        try await withSpawnedExecution(config: config) { execution in
            // Send signal to process
            try execution.send(signal: .terminate)

            let result = try await monitorProcessTermination(
                for: execution.processIdentifier
            )
            #expect(result == .unhandledException(SIGTERM))
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
        let expectedError = SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: SubprocessError.WindowsError(rawValue: DWORD(ERROR_INVALID_PARAMETER))
        )
        let processIdentifier = ProcessIdentifier(
            value: .max, processDescriptor: INVALID_HANDLE_VALUE, threadHandle: INVALID_HANDLE_VALUE
        )
        #elseif os(Linux) || os(Android) || os(FreeBSD)
        let expectedError = SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: Errno(rawValue: ECHILD)
        )
        let processIdentifier = ProcessIdentifier(
            value: .max, processDescriptor: -1
        )
        #else
        let expectedError = SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: Errno(rawValue: ECHILD)
        )
        let processIdentifier = ProcessIdentifier(value: .max)
        #endif
        await #expect(throws: expectedError) {
            _ = try await monitorProcessTermination(for: processIdentifier)
        }
    }

    @Test func testDoesNotReapUnrelatedChildProcess() async throws {
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
            spawnedProcesses.append(spawnResult.execution.processIdentifier)
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
