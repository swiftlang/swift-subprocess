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

import Testing
import Dispatch
import Foundation
@testable import Subprocess

@Suite("AsyncBufferSequence.StreamingBehavior Tests", .serialized)
struct StreamingBehaviorTests {}

// MARK: - StreamingBehavior Enum Tests
extension StreamingBehaviorTests {
    @Test func testStreamingBehaviorEquality() {
        // Test that all three streaming behavior values are distinct
        let throughput: AsyncBufferSequence.StreamingBehavior = .throughput
        let balanced: AsyncBufferSequence.StreamingBehavior = .balanced
        let latency: AsyncBufferSequence.StreamingBehavior = .latency

        // Each value should be equal to itself
        #expect(throughput == .throughput)
        #expect(balanced == .balanced)
        #expect(latency == .latency)

        // Each value should be different from the others
        #expect(throughput != balanced)
        #expect(throughput != latency)
        #expect(balanced != latency)
    }

    @Test func testStreamingBehaviorHashable() {
        // Test that streaming behaviors can be used in sets and dictionaries
        let behaviors: Set<AsyncBufferSequence.StreamingBehavior> = [
            .throughput, .balanced, .latency
        ]
        #expect(behaviors.count == 3)
        #expect(behaviors.contains(.throughput))
        #expect(behaviors.contains(.balanced))
        #expect(behaviors.contains(.latency))
    }
}

// MARK: - Throughput Mode Tests
extension StreamingBehaviorTests {
    /// Test that throughput mode successfully streams output from a subprocess.
    @Test func testThroughputModeBasicFunctionality() async throws {
        let expected = "Hello from throughput mode"
        #if os(Windows)
        let result = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", "echo \(expected)"],
            error: .discarded,
            streamingBehavior: .throughput
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }
        #else
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "echo '\(expected)'"],
            error: .discarded,
            streamingBehavior: .throughput
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }
        #endif

        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }

    /// Test that throughput mode can handle larger amounts of data.
    @Test func testThroughputModeWithLargeOutput() async throws {
        let lineCount = 1000
        #if os(Windows)
        let script = (1...lineCount).map { "echo Line \($0)" }.joined(separator: " & ")
        let result = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", script],
            error: .discarded,
            streamingBehavior: .throughput
        ) { execution, standardOutput in
            var count = 0
            for try await _ in standardOutput.lines() {
                count += 1
            }
            return count
        }
        #else
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "for i in $(seq 1 \(lineCount)); do echo \"Line $i\"; done"],
            error: .discarded,
            streamingBehavior: .throughput
        ) { execution, standardOutput in
            var count = 0
            for try await _ in standardOutput.lines() {
                count += 1
            }
            return count
        }
        #endif

        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == lineCount)
    }
}

// MARK: - Balanced Mode Tests
extension StreamingBehaviorTests {
    /// Test that balanced mode successfully streams output from a subprocess.
    @Test func testBalancedModeBasicFunctionality() async throws {
        let expected = "Hello from balanced mode"
        #if os(Windows)
        let result = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", "echo \(expected)"],
            error: .discarded,
            streamingBehavior: .balanced
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }
        #else
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "echo '\(expected)'"],
            error: .discarded,
            streamingBehavior: .balanced
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }
        #endif

        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }

    /// Test that balanced mode can handle larger amounts of data.
    @Test func testBalancedModeWithLargeOutput() async throws {
        let lineCount = 1000
        #if os(Windows)
        let script = (1...lineCount).map { "echo Line \($0)" }.joined(separator: " & ")
        let result = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", script],
            error: .discarded,
            streamingBehavior: .balanced
        ) { execution, standardOutput in
            var count = 0
            for try await _ in standardOutput.lines() {
                count += 1
            }
            return count
        }
        #else
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "for i in $(seq 1 \(lineCount)); do echo \"Line $i\"; done"],
            error: .discarded,
            streamingBehavior: .balanced
        ) { execution, standardOutput in
            var count = 0
            for try await _ in standardOutput.lines() {
                count += 1
            }
            return count
        }
        #endif

        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == lineCount)
    }

    /// Test that balanced mode can handle multiple lines of data that arrive with delays.
    @Test func testBalancedModeWithDelayedOutput() async throws {
        #if os(Windows)
        let result = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", "echo Line1 & timeout /t 1 >nul & echo Line2"],
            error: .discarded,
            streamingBehavior: .balanced
        ) { execution, standardOutput in
            var lines: [String] = []
            for try await line in standardOutput.lines() {
                lines.append(line.trimmingNewLineAndQuotes())
            }
            return lines
        }
        #else
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: [
                "-c",
                """
                echo "Line1"
                sleep 0.1
                echo "Line2"
                sleep 0.1
                echo "Line3"
                """,
            ],
            error: .discarded,
            streamingBehavior: .balanced
        ) { execution, standardOutput in
            var lines: [String] = []
            for try await line in standardOutput.lines() {
                lines.append(line.trimmingNewLineAndQuotes())
            }
            return lines
        }
        #endif

        #expect(result.terminationStatus.isSuccess)
        #if os(Windows)
        #expect(result.value.contains("Line1"))
        #expect(result.value.contains("Line2"))
        #else
        #expect(result.value.count == 3, "Expected 3 lines, got \(result.value.count): \(result.value)")
        #expect(result.value[0] == "Line1")
        #expect(result.value[1] == "Line2")
        #expect(result.value[2] == "Line3")
        #endif
    }
}

// MARK: - Latency Mode Tests
extension StreamingBehaviorTests {
    /// Test that latency mode successfully streams output from a subprocess.
    @Test func testLatencyModeBasicFunctionality() async throws {
        let expected = "Hello from latency mode"
        #if os(Windows)
        let result = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", "echo \(expected)"],
            error: .discarded,
            streamingBehavior: .latency
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }
        #else
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "echo '\(expected)'"],
            error: .discarded,
            streamingBehavior: .latency
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }
        #endif

        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }

    /// Test that latency mode can handle multiple lines of data that arrive with delays.
    /// This test is more representative of interactive use cases where latency mode shines.
    @Test func testLatencyModeWithDelayedOutput() async throws {
        #if os(Windows)
        // On Windows, use a simpler approach
        let result = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", "echo Line1 & timeout /t 1 >nul & echo Line2"],
            error: .discarded,
            streamingBehavior: .latency
        ) { execution, standardOutput in
            var lines: [String] = []
            for try await line in standardOutput.lines() {
                lines.append(line.trimmingNewLineAndQuotes())
            }
            return lines
        }
        #else
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: [
                "-c",
                """
                echo "Line1"
                sleep 0.1
                echo "Line2"
                sleep 0.1
                echo "Line3"
                """,
            ],
            error: .discarded,
            preferredBufferSize: 1,
            streamingBehavior: .latency
        ) { execution, standardOutput in
            var lines: [String] = []
            for try await line in standardOutput.lines() {
                lines.append(line.trimmingNewLineAndQuotes())
            }
            return lines
        }
        #endif

        #expect(result.terminationStatus.isSuccess)
        #if os(Windows)
        #expect(result.value.contains("Line1"))
        #expect(result.value.contains("Line2"))
        #else
        #expect(result.value.count == 3, "Expected 3 lines, got \(result.value.count): \(result.value)")
        #expect(result.value[0] == "Line1")
        #expect(result.value[1] == "Line2")
        #expect(result.value[2] == "Line3")
        #endif
    }

    #if !os(Windows)
    /// Test that latency mode delivers the first line before a long sleep completes.
    /// This simulates a script that outputs a line, sleeps, then outputs a final line.
    /// With latency mode, the first line must arrive well before the sleep ends —
    /// not buffered until process exit.
    @Test func testLatencyModeFirstLineArrivesBeforeLongDelay() async throws {
        let start = Date()
        var firstLineTimestamp: Date? = nil

        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: [
                "-c",
                """
                echo "first"
                sleep 1
                echo "last"
                """,
            ],
            error: .discarded,
            streamingBehavior: .latency
        ) { execution, standardOutput in
            var lines: [String] = []
            for try await line in standardOutput.lines() {
                if firstLineTimestamp == nil {
                    firstLineTimestamp = Date()
                }
                lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return lines
        }

        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == ["first", "last"])

        // The first line must arrive well before the 1-second sleep completes.
        // If output were buffered until process exit, it would arrive after ~1s.
        if let firstLineTimestamp {
            let elapsed = firstLineTimestamp.timeIntervalSince(start)
            #expect(
                elapsed < 0.5,
                "First line should arrive within 0.5s, but took \(elapsed)s. Output may be buffered until process exit."
            )
        } else {
            Issue.record("No lines were received")
        }
    }

    /// Test that latency mode delivers data quickly for interactive use cases.
    /// This test verifies that when a subprocess outputs data incrementally,
    /// latency mode receives it without waiting for a full buffer.
    @Test func testLatencyModeDeliversDataQuickly() async throws {
        // This test outputs a single small line and then waits.
        // With latency mode, we should receive the data quickly without
        // waiting for the buffer to fill.
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: [
                "-c",
                """
                echo "first"
                sleep 0.5
                echo "second"
                """,
            ],
            error: .discarded,
            preferredBufferSize: 1,
            streamingBehavior: .latency
        ) { execution, standardOutput in
            var lines: [String] = []
            var timestamps: [Date] = []

            for try await line in standardOutput.lines() {
                lines.append(line.trimmingNewLineAndQuotes())
                timestamps.append(Date())
            }

            return (lines: lines, timestamps: timestamps)
        }

        #expect(result.terminationStatus.isSuccess)
        #expect(result.value.lines.count == 2)
        #expect(result.value.lines[0] == "first")
        #expect(result.value.lines[1] == "second")

        // Verify that we received the lines at different times
        // (the second line should come ~0.5 seconds after the first)
        if result.value.timestamps.count == 2 {
            let timeDiff = result.value.timestamps[1].timeIntervalSince(result.value.timestamps[0])
            // The time difference should be around 0.5 seconds (allowing some tolerance)
            #expect(timeDiff >= 0.3, "Second line should arrive after a delay")
        }
    }

    /// Test that latency mode receives all subsequent chunks after the first chunk.
    /// This test reproduces a bug where subsequent chunks arriving after the first
    /// chunk has been returned are ignored (the handler sets hasResumed=true and
    /// ignores later data).
    /// 
    /// The bug occurs when DispatchIO calls the handler multiple times for a single
    /// read() call. With latency mode and returnOnFirstData=true, the first chunk
    /// causes an early return and sets hasResumed=true. If DispatchIO calls the handler
    /// again with more data (with done=false) for that same read() operation, that
    /// data is lost because hasResumed is already true and the guard at line 62-65
    /// causes the handler to return early, ignoring the data.
    /// 
    /// This test outputs data slowly to allow DispatchIO's interval-based handler
    /// to be called multiple times with partial data. With latency mode's strictInterval
    /// and lowWater=0, the handler should be called at each interval with whatever
    /// data is available. After returning the first chunk, subsequent handler calls
    /// should not be ignored.
    @Test func testLatencyModeReceivesAllSubsequentChunks() async throws {
        // Output data slowly with small writes to trigger DispatchIO's interval-based
        // handler calls. With latency mode's 250ms interval and lowWater=0, the handler
        // should be called multiple times as data arrives, even for a single read() call.
        let result = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: [
                "-c",
                """
                printf "A"
                sleep 0.05
                printf "B"
                sleep 0.05
                printf "C"
                sleep 0.05
                printf "D"
                sleep 0.05
                printf "E"
                """,
            ],
            error: .discarded,
            preferredBufferSize: 100, // Large enough buffer to read all data in one call
            streamingBehavior: .latency
        ) { execution, standardOutput in
            var allData = Data()
            var chunkCount = 0
            for try await buffer in standardOutput {
                chunkCount += 1
                allData.append(contentsOf: buffer.data)
            }
            let receivedString = String(decoding: allData, as: UTF8.self)
            return (data: receivedString, chunkCount: chunkCount)
        }

        #expect(result.terminationStatus.isSuccess)
        
        // Verify we received all the data. If the bug exists, we might only receive
        // the first chunk ("A") and lose subsequent chunks that arrive in handler
        // calls after the first chunk was returned.
        let expectedOutput = "ABCDE"
        #expect(
            result.value.data == expectedOutput,
            "Expected '\(expectedOutput)', got '\(result.value.data)'. This indicates subsequent chunks after the first were ignored. Received \(result.value.chunkCount) chunks. The bug causes handler calls after the first chunk to be ignored when hasResumed=true."
        )
        
        // Verify we received at least one chunk
        #expect(
            result.value.chunkCount > 0,
            "Should receive at least one chunk, got \(result.value.chunkCount)"
        )
    }
    #endif
}

// MARK: - Comparison Tests
extension StreamingBehaviorTests {
    /// Test that all streaming behaviors produce the same output for the same input.
    @Test func testAllBehaviorsProduceSameOutput() async throws {
        let expected = "Test output content"

        #if os(Windows)
        let executable: Subprocess.Executable = .name("cmd.exe")
        let arguments: Subprocess.Arguments = ["/c", "echo \(expected)"]
        #else
        let executable: Subprocess.Executable = .path("/bin/sh")
        let arguments: Subprocess.Arguments = ["-c", "echo '\(expected)'"]
        #endif

        // Run with throughput mode
        let throughputResult = try await Subprocess.run(
            executable,
            arguments: arguments,
            error: .discarded,
            streamingBehavior: .throughput
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }

        // Run with balanced mode
        let balancedResult = try await Subprocess.run(
            executable,
            arguments: arguments,
            error: .discarded,
            streamingBehavior: .balanced
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }

        // Run with latency mode
        let latencyResult = try await Subprocess.run(
            executable,
            arguments: arguments,
            error: .discarded,
            streamingBehavior: .latency
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }

        // All modes should produce the same output
        #expect(throughputResult.terminationStatus.isSuccess)
        #expect(balancedResult.terminationStatus.isSuccess)
        #expect(latencyResult.terminationStatus.isSuccess)

        #expect(throughputResult.value == expected)
        #expect(balancedResult.value == expected)
        #expect(latencyResult.value == expected)
    }

    /// Test streaming behavior with binary data.
    @Test func testStreamingBehaviorWithBinaryData() async throws {
        let behaviors: [AsyncBufferSequence.StreamingBehavior] = [.throughput, .balanced, .latency]

        for behavior in behaviors {
            #if os(Windows)
            // Windows: Use PowerShell to output binary bytes
            let result = try await Subprocess.run(
                .name("powershell.exe"),
                arguments: [
                    "-Command",
                    "[byte[]]@(0x48,0x65,0x6C,0x6C,0x6F) | ForEach-Object { [Console]::OpenStandardOutput().WriteByte($_) }",
                ],
                error: .discarded,
                streamingBehavior: behavior
            ) { execution, standardOutput in
                var bytes: [UInt8] = []
                for try await buffer in standardOutput {
                    buffer.withUnsafeBytes { ptr in
                        bytes.append(contentsOf: ptr)
                    }
                }
                return bytes
            }
            #else
            // Unix: Output "Hello" as bytes using printf
            let result = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "printf 'Hello'"],
                error: .discarded,
                streamingBehavior: behavior
            ) { execution, standardOutput in
                var bytes: [UInt8] = []
                for try await buffer in standardOutput {
                    buffer.withUnsafeBytes { ptr in
                        bytes.append(contentsOf: ptr)
                    }
                }
                return bytes
            }
            #endif

            #expect(result.terminationStatus.isSuccess, "Behavior \(behavior) should succeed")
            #expect(result.value == Array("Hello".utf8), "Behavior \(behavior) should produce correct output")
        }
    }
}

// MARK: - Edge Cases
extension StreamingBehaviorTests {
    /// Test streaming behavior with empty output.
    @Test func testStreamingBehaviorWithEmptyOutput() async throws {
        let behaviors: [AsyncBufferSequence.StreamingBehavior] = [.throughput, .balanced, .latency]

        for behavior in behaviors {
            #if os(Windows)
            let result = try await Subprocess.run(
                .name("cmd.exe"),
                arguments: ["/c", ""],
                error: .discarded,
                streamingBehavior: behavior
            ) { execution, standardOutput in
                var output = ""
                for try await line in standardOutput.lines() {
                    output += line
                }
                return output
            }
            #else
            let result = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", ""],
                error: .discarded,
                streamingBehavior: behavior
            ) { execution, standardOutput in
                var output = ""
                for try await line in standardOutput.lines() {
                    output += line
                }
                return output
            }
            #endif

            #expect(result.terminationStatus.isSuccess, "Behavior \(behavior) should succeed with empty output")
            #expect(result.value.isEmpty, "Behavior \(behavior) should produce empty output")
        }
    }

    /// Test streaming behavior with both stdout and stderr.
    @Test func testStreamingBehaviorWithBothStreams() async throws {
        let behaviors: [AsyncBufferSequence.StreamingBehavior] = [.throughput, .balanced, .latency]

        for behavior in behaviors {
            #if os(Windows)
            let result = try await Subprocess.run(
                .name("cmd.exe"),
                arguments: ["/c", "echo stdout & echo stderr 1>&2"],
                streamingBehavior: behavior
            ) { execution, inputWriter, standardOutput, standardError in
                try await inputWriter.finish()

                async let stdoutTask: String = {
                    var output = ""
                    for try await line in standardOutput.lines() {
                        output += line
                    }
                    return output.trimmingNewLineAndQuotes()
                }()

                async let stderrTask: String = {
                    var output = ""
                    for try await line in standardError.lines() {
                        output += line
                    }
                    return output.trimmingNewLineAndQuotes()
                }()

                return (stdout: try await stdoutTask, stderr: try await stderrTask)
            }
            #else
            let result = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "echo stdout; echo stderr 1>&2"],
                streamingBehavior: behavior
            ) { execution, inputWriter, standardOutput, standardError in
                try await inputWriter.finish()

                async let stdoutTask: String = {
                    var output = ""
                    for try await line in standardOutput.lines() {
                        output += line
                    }
                    return output.trimmingNewLineAndQuotes()
                }()

                async let stderrTask: String = {
                    var output = ""
                    for try await line in standardError.lines() {
                        output += line
                    }
                    return output.trimmingNewLineAndQuotes()
                }()

                return (stdout: try await stdoutTask, stderr: try await stderrTask)
            }
            #endif

            #expect(result.terminationStatus.isSuccess, "Behavior \(behavior) should succeed")
            #expect(result.value.stdout == "stdout", "Behavior \(behavior) should capture stdout")
            #expect(result.value.stderr == "stderr", "Behavior \(behavior) should capture stderr")
        }
    }

    /// Test streaming behavior with a process that terminates quickly.
    @Test func testStreamingBehaviorWithQuickTermination() async throws {
        let behaviors: [AsyncBufferSequence.StreamingBehavior] = [.throughput, .balanced, .latency]

        for behavior in behaviors {
            #if os(Windows)
            let result = try await Subprocess.run(
                .name("cmd.exe"),
                arguments: ["/c", "exit 0"],
                error: .discarded,
                streamingBehavior: behavior
            ) { execution, standardOutput in
                var hasOutput = false
                for try await _ in standardOutput {
                    hasOutput = true
                }
                return hasOutput
            }
            #else
            let result = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", "exit 0"],
                error: .discarded,
                streamingBehavior: behavior
            ) { execution, standardOutput in
                var hasOutput = false
                for try await _ in standardOutput {
                    hasOutput = true
                }
                return hasOutput
            }
            #endif

            #expect(result.terminationStatus.isSuccess, "Behavior \(behavior) should succeed")
            #expect(!result.value, "Behavior \(behavior) should produce no output")
        }
    }
}

// MARK: - Default Behavior Tests
extension StreamingBehaviorTests {
    /// Test that the default streaming behavior is .throughput.
    @Test func testDefaultStreamingBehaviorIsThroughput() async throws {
        let expected = "Default behavior test"

        #if os(Windows)
        // Run without specifying streamingBehavior (should use default)
        let defaultResult = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", "echo \(expected)"],
            error: .discarded
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }

        // Run with explicit .throughput
        let explicitResult = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", "echo \(expected)"],
            error: .discarded,
            streamingBehavior: .throughput
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }
        #else
        // Run without specifying streamingBehavior (should use default)
        let defaultResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "echo '\(expected)'"],
            error: .discarded
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }

        // Run with explicit .throughput
        let explicitResult = try await Subprocess.run(
            .path("/bin/sh"),
            arguments: ["-c", "echo '\(expected)'"],
            error: .discarded,
            streamingBehavior: .throughput
        ) { execution, standardOutput in
            var output = ""
            for try await line in standardOutput.lines() {
                output += line
            }
            return output.trimmingNewLineAndQuotes()
        }
        #endif

        // Both should succeed and produce the same output
        #expect(defaultResult.terminationStatus.isSuccess)
        #expect(explicitResult.terminationStatus.isSuccess)
        #expect(defaultResult.value == expected)
        #expect(explicitResult.value == expected)
    }
}

