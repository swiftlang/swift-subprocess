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

#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl)

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import Testing
@testable import Subprocess

#if canImport(System)
import System
#else
import SystemPackage
#endif

@Suite(.serialized)
struct ProcessControlTests {
    init() {
        _ = globallyIgnoredSIGPIPE
    }

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
}

// MARK: - Utilities
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

#endif // canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl)
