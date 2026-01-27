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

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

import FoundationEssentials

import Testing
import _SubprocessCShims
@testable import Subprocess

// MARK: PlatformOption Tests
@Suite(.serialized)
struct SubprocessLinuxTests {
    @Test func testSuspendResumeProcess() async throws {
        func blockAndWaitForStatus(
            pid: pid_t,
            waitThread: inout pthread_t?,
            targetSignal: Int32,
            _ handler: @Sendable @escaping (Int32) -> Void
        ) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                do {
                    waitThread = try pthread_create {
                        var suspendedStatus: Int32 = 0
                        let rc = waitpid(pid, &suspendedStatus, targetSignal)
                        if rc == -1 {
                            continuation.resume(throwing: Errno(rawValue: errno))
                            return
                        }
                        handler(suspendedStatus)
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        _ = try await Subprocess.run(
            // This will intentionally hang
            .path("/usr/bin/sleep"),
            arguments: ["infinity"],
            error: .discarded
        ) { subprocess, standardOutput in
            // First suspend the process
            try subprocess.send(signal: .suspend)
            var thread1: pthread_t? = nil
            try await blockAndWaitForStatus(
                pid: subprocess.processIdentifier.value,
                waitThread: &thread1,
                targetSignal: WSTOPPED
            ) { status in
                #expect(_was_process_suspended(status) > 0)
            }
            // Now resume the process
            try subprocess.send(signal: .resume)
            var thread2: pthread_t? = nil
            try await blockAndWaitForStatus(
                pid: subprocess.processIdentifier.value,
                waitThread: &thread2,
                targetSignal: WCONTINUED
            ) { status in
                #expect(_was_process_suspended(status) == 0)
            }

            // Now kill the process
            try subprocess.send(signal: .terminate)
            for try await _ in standardOutput {}

            if let thread1 {
                pthread_join(thread1, nil)
            }
            if let thread2 {
                pthread_join(thread2, nil)
            }
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
#endif // canImport(Glibc) || canImport(Bionic) || canImport(Musl)
