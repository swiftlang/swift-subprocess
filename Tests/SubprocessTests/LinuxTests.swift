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

#if os(Linux) || os(Android)

#if canImport(Android)
import Android
import Foundation
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
    func testSubprocessPlatformOptionsPreExecProcessAction() async throws {
        var platformOptions = PlatformOptions()
        platformOptions.preExecProcessAction = {
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
            output: .string(limit: 32),
            error: .string(limit: 32)
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
        let result = try await Subprocess.run(
            // This will intentionally hang
            .path("/usr/bin/sleep"),
            arguments: ["infinity"],
            output: .discarded,
            error: .discarded
        ) { subprocess -> Error? in
            do {
                try await tryFinally {
                    // First suspend the process
                    try subprocess.send(signal: .suspend)
                    try await waitForCondition(timeout: .seconds(30), comment: "Process did not transition from running to stopped state after $$") {
                        let state = try subprocess.state()
                        switch state {
                        case .running:
                            return false
                        case .zombie:
                            throw ProcessStateError(expectedState: .stopped, actualState: state)
                        case .stopped, .sleeping, .uninterruptibleWait:
                            return true
                        }
                    }
                    // Now resume the process
                    try subprocess.send(signal: .resume)
                    try await waitForCondition(timeout: .seconds(30), comment: "Process did not transition from stopped to running state after $$") {
                        let state = try subprocess.state()
                        switch state {
                        case .running, .sleeping, .uninterruptibleWait:
                            return true
                        case .zombie:
                            throw ProcessStateError(expectedState: .running, actualState: state)
                        case .stopped:
                            return false
                        }
                    }
                } finally: { error in
                    // Now kill the process
                    try subprocess.send(signal: error != nil ? .kill : .terminate)
                }
                return nil
            } catch {
                return error
            }
        }
        if let error = result.value {
            #expect(result.terminationStatus == .unhandledException(SIGKILL))
            throw error
        } else {
            #expect(result.terminationStatus == .unhandledException(SIGTERM))
        }
    }

    @Test func testUniqueProcessIdentifier() async throws {
        _ = try await Subprocess.run(
            .path("/bin/echo"),
            output: .discarded,
            error: .discarded
        ) { subprocess in
            if subprocess.processIdentifier.processDescriptor > 0 {
                var statinfo = stat()
                try #require(fstat(subprocess.processIdentifier.processDescriptor, &statinfo) == 0)
                
                // In kernel 6.9+, st_ino globally uniquely identifies the process
                #expect(statinfo.st_ino > 0)
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

fileprivate struct ProcessStateError: Error, CustomStringConvertible {
    let expectedState: ProcessState
    let actualState: ProcessState

    var description: String {
        "Process did not transition to \(expectedState) state, but was actually \(actualState)"
    }
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

func waitForCondition(timeout: Duration, comment: Comment, _ evaluateCondition: () throws -> Bool) async throws {
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
        let timeout: Duration
        let comment: Comment
        var description: String {
            comment.description.replacingOccurrences(of: "$$", with: "\(timeout)")
        }
    }
    throw TimeoutError(timeout: timeout, comment: comment)
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
