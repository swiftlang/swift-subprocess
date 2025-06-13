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

#if canImport(Glibc) || canImport(Bionic) || canImport(Musl)

#if canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import FoundationEssentials

import Testing
@testable import Subprocess

// MARK: PlatformOption Tests
@Suite(.serialized)
struct SubprocessLinuxTests {
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsPreSpawnProcessConfigurator() async throws {
        var platformOptions = PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = {
            guard setgid(4321) == 0 else {
                // Returns EPERM when:
                //   The calling process is not privileged (does not have the
                //   CAP_SETGID capability in its user namespace), and gid does
                //   not match the real group ID or saved set-group-ID of the
                //   calling process.
                perror("setgid")
                abort()
            }
        }
        let idResult = try await Subprocess.run(
            .path("/usr/bin/id"),
            arguments: ["-g"],
            platformOptions: platformOptions,
            output: .string,
            error: .string
        )
        let error = try #require(idResult.standardError)
        try #require(error == "")
        #expect(idResult.terminationStatus.isSuccess)
        let id = try #require(idResult.standardOutput)
        #expect(
            id.trimmingCharacters(in: .whitespacesAndNewlines) == "\(4321)"
        )
    }

    @Test func testSuspendResumeProcess() async throws {
        _ = try await Subprocess.run(
            // This will intentionally hang
            .path("/usr/bin/sleep"),
            arguments: ["infinity"],
            error: .discarded
        ) { subprocess, standardOutput in
            try await tryFinally {
                // First suspend the process
                try subprocess.send(signal: .suspend)
                try await waitForCondition(timeout: .seconds(30)) {
                    let state = try subprocess.state()
                    return state == .stopped
                }
                // Now resume the process
                try subprocess.send(signal: .resume)
                try await waitForCondition(timeout: .seconds(30)) {
                    let state = try subprocess.state()
                    return state == .running
                }
            } finally: { error in
                // Now kill the process
                try subprocess.send(signal: error != nil ? .kill : .terminate)
                for try await _ in standardOutput {}
            }
        }
    }
}

fileprivate enum ProcessState: String {
    case running = "R"
    case sleeping = "S"
    case uninterruptibleWait = "D"
    case zombie = "Z"
    case stopped = "T"
}

extension Execution {
    fileprivate func state() throws -> ProcessState {
        let processStatusFile = "/proc/\(processIdentifier.value)/status"
        let processStatusData = try Data(
            contentsOf: URL(filePath: processStatusFile)
        )
        let stateMatches = try String(decoding: processStatusData, as: UTF8.self)
            .split(separator: "\n")
            .compactMap({ line in
                return try #/^State:\s+(?<status>[A-Z])\s+.*/#.wholeMatch(in: line)
            })
        guard let status = stateMatches.first, stateMatches.count == 1, let processState = ProcessState(rawValue: String(status.output.status)) else {
            struct ProcStatusParseError: Error, CustomStringConvertible {
                let filePath: String
                let contents: Data
                var description: String {
                    "Could not parse \(filePath):\n\(String(decoding: contents, as: UTF8.self))"
                }
            }
            throw ProcStatusParseError(filePath: processStatusFile, contents: processStatusData)
        }
        return processState
    }
}

func waitForCondition(timeout: Duration, _ evaluateCondition: () throws -> Bool) async throws {
    var currentCondition = try evaluateCondition()
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if currentCondition {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
        currentCondition = try evaluateCondition()
    }
    struct TimeoutError: Error, CustomStringConvertible {
        var description: String {
            "Timed out waiting for condition to be true"
        }
    }
    throw TimeoutError()
}

func tryFinally(_ work: () async throws -> (), finally: (Error?) async throws -> ()) async throws {
    let error: Error?
    do {
        try await work()
        error = nil
    } catch let e {
        error = e
    }
    try await finally(error)
    if let error {
        throw error
    }
}

#endif  // canImport(Glibc) || canImport(Bionic) || canImport(Musl)
