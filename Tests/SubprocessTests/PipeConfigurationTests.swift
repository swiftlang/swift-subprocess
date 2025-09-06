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

import Foundation
import Testing
@testable import Subprocess

@Suite(.serialized)
struct PipeConfigurationTests {

    // MARK: - Basic PipeConfiguration Tests

    @Test func testBasicPipeConfiguration() async throws {
        let config = pipe(
            executable: .name("echo"),
            arguments: ["Hello World"]
        ).finally(
            input: NoInput(),
            output: .string(limit: .max),
            error: .discarded
        )

        let result = try await config.run()
        #expect(result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello World")
        #expect(result.terminationStatus.isSuccess)
    }

    // FIXME - these function tests are hanging on Linux
    #if os(macOS)
    @Test func testBasicSwiftFunctionBeginning() async throws {
        let config =
            pipe { input, output, error in
                var foundHello = false
                for try await line in input.lines() {
                    if line.hasPrefix("Hello") {
                        foundHello = true
                    }
                }

                guard foundHello else {
                    return 1
                }

                let written = try await output.write("Hello World")
                guard written == "Hello World".utf8.count else {
                    return 1
                }
                return 0
            } | .name("cat")
            |> (
                input: .string("Hello"),
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        let result = try await config.run()
        #expect(result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello World")
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testBasicSwiftFunctionMiddle() async throws {
        let config =
            pipe(
                executable: .name("echo"),
                arguments: ["Hello"]
            ) | { input, output, error in
                var foundHello = false
                for try await line in input.lines() {
                    if line.hasPrefix("Hello") {
                        foundHello = true
                    }
                }

                guard foundHello else {
                    return 1
                }

                let written = try await output.write("Hello World")
                guard written == "Hello World".utf8.count else {
                    return 1
                }
                return 0
            } | .name("cat")
            |> (
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        let result = try await config.run()
        #expect(result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello World")
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testBasicSwiftFunctionEnd() async throws {
        let config =
            pipe(
                executable: .name("echo"),
                arguments: ["Hello"]
            ) | { input, output, error in
                var foundHello = false
                for try await line in input.lines() {
                    if line.hasPrefix("Hello") {
                        foundHello = true
                    }
                }

                guard foundHello else {
                    return 1
                }

                let written = try await output.write("Hello World")
                guard written == "Hello World".utf8.count else {
                    return 1
                }
                return 0
            } |> .string(limit: .max)

        let result = try await config.run()
        #expect(result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello World")
        #expect(result.terminationStatus.isSuccess)
    }
    #endif

    @Test func testPipeConfigurationWithConfiguration() async throws {
        let configuration = Configuration(
            executable: .name("echo"),
            arguments: ["Test Message"]
        )

        let processConfig =
            pipe(
                configuration: configuration
            ) |> .string(limit: .max)

        let result = try await processConfig.run()
        #expect(result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) == "Test Message")
        #expect(result.terminationStatus.isSuccess)
    }

    // MARK: - Pipe Method Tests

    @Test func testPipeMethod() async throws {
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["line1\nline2\nline3"]
            )
            | process(
                executable: .name("wc"),
                arguments: ["-l"]
            ) |> .string(limit: .max)

        let result = try await pipeline.run()
        let lineCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(lineCount == "3")
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testPipeMethodWithConfiguration() async throws {
        let wcConfig = Configuration(
            executable: .name("wc"),
            arguments: ["-l"]
        )

        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["apple\nbanana\ncherry"]
            ) | wcConfig |> .string(limit: .max)

        let result = try await pipeline.run()
        let lineCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(lineCount == "3")
        #expect(result.terminationStatus.isSuccess)
    }

    // MARK: - Pipe Operator Tests

    @Test func testBasicPipeOperator() async throws {
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["Hello\nWorld\nTest"]
            ) | .name("wc")
            | .name("cat")
            |> .string(limit: .max)

        let result = try await pipeline.run()
        // wc output should contain line count
        #expect(result.standardOutput?.contains("3") == true)
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testPipeOperatorWithExecutableOnly() async throws {
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["single line"]
            ) | .name("cat") // Simple pass-through
            | process(
                executable: .name("wc"),
                arguments: ["-c"] // Count characters
            ) |> .string(limit: .max)

        let result = try await pipeline.run()
        // Should count characters in "single line\n" (12 characters)
        let charCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(charCount == "12")
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testPipeOperatorWithConfiguration() async throws {
        let catConfig = Configuration(executable: .name("cat"))

        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["test data"]
            ) | catConfig
            | process(
                executable: .name("wc"),
                arguments: ["-w"] // Count words
            ) |> .string(limit: .max)

        let result = try await pipeline.run()
        let wordCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(wordCount == "2") // "test data" = 2 words
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testPipeOperatorWithProcessHelper() async throws {
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["apple\nbanana\ncherry\ndate"]
            )
            | process(
                executable: .name("head"),
                arguments: ["-3"] // Take first 3 lines
            )
            | process(
                executable: .name("wc"),
                arguments: ["-l"]
            ) |> .string(limit: .max)

        let result = try await pipeline.run()
        let lineCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(lineCount == "3")
        #expect(result.terminationStatus.isSuccess)
    }

    // MARK: - Complex Pipeline Tests

    @Test func testComplexPipeline() async throws {
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["zebra\napple\nbanana\ncherry"]
            )
            | process(
                executable: .name("sort") // Sort alphabetically
            ) | .name("head") // Take first few lines (default)
            | process(
                executable: .name("wc"),
                arguments: ["-l"]
            ) |> .string(limit: .max)

        let result = try await pipeline.run()
        // Should have some lines (exact count depends on head default)
        let lineCount = Int(result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        #expect(lineCount > 0)
        #expect(result.terminationStatus.isSuccess)
    }

    // MARK: - Input Type Tests

    @Test func testPipelineWithStringInput() async throws {
        let pipeline =
            pipe(
                executable: .name("cat")
            )
            | process(
                executable: .name("wc"),
                arguments: ["-w"] // Count words
            ) |> (
                input: .string("Hello world from string input"),
                output: .string(limit: .max),
                error: .discarded
            )

        let result = try await pipeline.run()
        let wordCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(wordCount == "5") // "Hello world from string input" = 5 words
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testPipelineWithStringInputAndSwiftFunction() async throws {
        let pipeline =
            pipe(
                swiftFunction: { input, output, err in
                    var wordCount = 0
                    for try await line in input.lines() {
                        let words = line.split(separator: " ")
                        wordCount += words.count
                    }

                    let countString = "Word count: \(wordCount)"
                    let written = try await output.write(countString)
                    return written > 0 ? 0 : 1
                }
            ) | .name("cat")
            |> (
                input: .string("Swift functions can process string input efficiently"),
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        let result = try await pipeline.run()
        #expect(result.standardOutput?.contains("Word count: 7") == true)
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testSwiftFunctionAsFirstStageWithStringInput() async throws {
        let pipeline =
            pipe(
                swiftFunction: { input, output, err in
                    // Convert input to uppercase and add line numbers
                    var lineNumber = 1
                    for try await line in input.lines() {
                        let uppercaseLine = "\(lineNumber): \(line.uppercased())\n"
                        _ = try await output.write(uppercaseLine)
                        lineNumber += 1
                    }
                    return 0
                }
            ) | .name("cat") // Use cat instead of head to see all output
            |> (
                input: .string("first line\nsecond line\nthird line"),
                output: .string(limit: .max),
                error: .discarded
            )

        let result = try await pipeline.run()
        let output = result.standardOutput ?? ""
        #expect(output.contains("1: FIRST LINE"))
        #expect(output.contains("2: SECOND LINE"))
        #expect(output.contains("3: THIRD LINE"))
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testProcessStageWithFileDescriptorInput() async throws {
        // Create a temporary file with test content
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("pipe_test_\(UUID().uuidString).txt")
        let testContent = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
        try testContent.write(to: tempURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Open file descriptor for reading
        let fileDescriptor = try FileDescriptor.open(tempURL.path, .readOnly)
        defer {
            try? fileDescriptor.close()
        }

        let pipeline =
            pipe(
                executable: .name("head"),
                arguments: ["-3"]
            )
            | process(
                executable: .name("wc"),
                arguments: ["-l"]
            ) |> (
                input: .fileDescriptor(fileDescriptor, closeAfterSpawningProcess: false),
                output: .string(limit: .max),
                error: .discarded
            )

        let result = try await pipeline.run()
        let lineCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(lineCount == "3") // head -3 should give us 3 lines
        #expect(result.terminationStatus.isSuccess)
    }

    // FIXME - These tests are hanging on Linux
    #if os(macOS)
    @Test func testSwiftFunctionWithFileDescriptorInput() async throws {
        // Create a temporary file with JSON content
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("json_test_\(UUID().uuidString).json")
        let jsonContent = #"{"name": "Alice", "age": 30, "city": "New York"}"#
        try jsonContent.write(to: tempURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Open file descriptor for reading
        let fileDescriptor = try FileDescriptor.open(tempURL.path, .readOnly)
        defer {
            try? fileDescriptor.close()
        }

        struct Person: Codable {
            let name: String
            let age: Int
            let city: String
        }

        let pipeline =
            pipe(
                swiftFunction: { input, output, err in
                    var jsonData = Data()
                    for try await chunk in input.lines() {
                        jsonData.append(contentsOf: chunk.utf8)
                    }

                    do {
                        let decoder = JSONDecoder()
                        let person = try decoder.decode(Person.self, from: jsonData)
                        let summary = "Person: \(person.name), Age: \(person.age), Location: \(person.city)"
                        let written = try await output.write(summary)
                        return written > 0 ? 0 : 1
                    } catch {
                        try await err.write("JSON parsing failed: \(error)")
                        return 1
                    }
                }
            ) | .name("cat") // Add second stage to make it a valid pipeline
            |> (
                input: .fileDescriptor(fileDescriptor, closeAfterSpawningProcess: false),
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        let result = try await pipeline.run()
        #expect(result.standardOutput?.contains("Person: Alice, Age: 30, Location: New York") == true)
        #expect(result.terminationStatus.isSuccess)
    }
    #endif

    @Test func testComplexPipelineWithStringInputAndSwiftFunction() async throws {
        let csvData = "name,score,grade\nAlice,95,A\nBob,87,B\nCharlie,92,A\nDave,78,C"

        let pipeline =
            pipe(
                swiftFunction: { input, output, err in
                    // Parse CSV and filter for A grades
                    var lineCount = 0
                    for try await line in input.lines() {
                        lineCount += 1
                        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

                        // Skip header line
                        if lineCount == 1 {
                            continue
                        }

                        let components = trimmedLine.split(separator: ",").map { String($0) }
                        if components.count >= 3 && components[2] == "A" {
                            let name = components[0]
                            let score = components[1]
                            _ = try await output.write("\(name): \(score)\n")
                        }
                    }
                    return 0
                }
            ) | .name("cat")
            |> (
                input: .string(csvData),
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        let result = try await pipeline.run()
        let output = result.standardOutput ?? ""
        #expect(output.contains("Alice: 95"))
        #expect(output.contains("Charlie: 92"))
        #expect(!output.contains("Bob")) // Bob has grade B, should be filtered out
        #expect(!output.contains("Dave")) // Dave has grade C, should be filtered out
        #expect(result.terminationStatus.isSuccess)
    }

    // FIXME - this test is hanging on Linux
    #if os(macOS)
    @Test func testMultiStageSwiftFunctionPipelineWithStringInput() async throws {
        let numbers = "10\n25\n7\n42\n13\n8\n99"

        let pipeline =
            pipe(
                swiftFunction: { input, output, err in
                    // First Swift function: filter for numbers > 10
                    for try await line in input.lines() {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty, let number = Int(trimmed), number > 10 {
                            _ = try await output.write("\(number)\n")
                        }
                    }
                    return 0
                }
            ) | { input, output, err in
                // Second Swift function: double the numbers
                for try await line in input.lines() {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let number = Int(trimmed) {
                        let doubled = number * 2
                        _ = try await output.write("\(doubled)\n")
                    }
                }
                return 0
            }
            | process(
                executable: .name("cat")
            ) |> (
                input: .string(numbers),
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        let result = try await pipeline.run()
        let output = result.standardOutput ?? ""
        let lines = output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Int(trimmed)
        }

        // Input: 10, 25, 7, 42, 13, 8, 99
        // After filter (> 10): 25, 42, 13, 99
        // After doubling: 50, 84, 26, 198
        #expect(lines.contains(50)) // 25 * 2
        #expect(lines.contains(84)) // 42 * 2
        #expect(lines.contains(26)) // 13 * 2
        #expect(lines.contains(198)) // 99 * 2

        // These should NOT be present (filtered out)
        #expect(!lines.contains(20)) // 10 * 2 (10 not > 10)
        #expect(!lines.contains(14)) // 7 * 2 (7 <= 10)
        #expect(!lines.contains(16)) // 8 * 2 (8 <= 10)

        #expect(result.terminationStatus.isSuccess)
    }
    #endif

    // MARK: - Shared Error Handling Tests

    @Test func testSharedErrorHandlingInPipeline() async throws {
        let pipeline =
            pipe(
                executable: .name("sh"),
                arguments: ["-c", "echo 'first stdout'; echo 'first stderr' >&2"]
            )
            | process(
                executable: .name("sh"),
                arguments: ["-c", "echo 'second stdout'; echo 'second stderr' >&2"]
            ) |> (
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        let result = try await pipeline.run()
        let errorOutput = result.standardError ?? ""

        // Both stages should contribute to shared stderr
        #expect(errorOutput.contains("first stderr"))
        #expect(errorOutput.contains("second stderr"))
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testSharedErrorHandlingWithSwiftFunction() async throws {
        let pipeline =
            pipe(
                swiftFunction: { input, output, err in
                    _ = try await output.write("Swift function output\n")
                    _ = try await err.write("Swift function error\n")
                    return 0
                }
            )
            | process(
                executable: .name("sh"),
                arguments: ["-c", "echo 'shell stdout'; echo 'shell stderr' >&2"]
            ) |> (
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        let result = try await pipeline.run()
        let errorOutput = result.standardError ?? ""

        // Both Swift function and shell process should contribute to stderr
        #expect(errorOutput.contains("Swift function error"))
        #expect(errorOutput.contains("shell stderr"))
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testSharedErrorRespectingMaxSize() async throws {
        let longErrorMessage = String(repeating: "error", count: 100) // 500 characters

        let pipeline =
            pipe(
                executable: .name("sh"),
                arguments: ["-c", "echo '\(longErrorMessage)' >&2"]
            )
            | process(
                executable: .name("sh"),
                arguments: ["-c", "echo '\(longErrorMessage)' >&2"]
            ) |> (
                output: .string(limit: .max),
                error: .string(limit: 100) // Limit error to 100 bytes
            )

        await #expect(throws: SubprocessError.self) {
            try await pipeline.run()
        }
    }

    // MARK: - Error Redirection Tests

    @Test func testSeparateErrorRedirection() async throws {
        // Default behavior - separate stdout and stderr
        let config = pipe(
            executable: .name("sh"),
            arguments: ["-c", "echo 'stdout'; echo 'stderr' >&2"],
            options: .default // Same as .separate
        ).finally(
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        let result = try await config.run()
        #expect(result.standardOutput?.contains("stdout") == true)
        #expect(result.standardError?.contains("stderr") == true)
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testReplaceStdoutErrorRedirection() async throws {
        // Redirect stderr to stdout, discard original stdout
        let config = pipe(
            executable: .name("sh"),
            arguments: ["-c", "echo 'stdout'; echo 'stderr' >&2"],
            options: .stderrToStdout
        ).finally(
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        let result = try await config.run()
        // With replaceStdout, the stderr content should appear as stdout
        #expect(result.standardOutput?.contains("stderr") == true)
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testMergeErrorRedirection() async throws {
        // Merge stderr with stdout
        let config = pipe(
            executable: .name("sh"),
            arguments: ["-c", "echo 'stdout'; echo 'stderr' >&2"],
            options: .mergeErrors
        ).finally(
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        let result = try await config.run()
        // With merge, both stdout and stderr content should appear in the output stream
        // Since both streams are directed to the same destination (.output),
        // the merged content should appear in standardOutput
        #expect(result.standardOutput?.contains("stdout") == true)
        #expect(result.standardOutput?.contains("stderr") == true)
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testErrorRedirectionWithPipeOperators() async throws {
        let pipeline =
            pipe(
                executable: .name("sh"),
                arguments: ["-c", "echo 'line1'; echo 'error1' >&2"],
                options: .mergeErrors // Merge stderr into stdout
            )
            | process(
                executable: .name("grep"),
                arguments: ["error"], // This should find 'error1' now in stdout
                options: .default
            )
            | process(
                executable: .name("wc"),
                arguments: ["-l"],
            ) |> (
                output: .string(limit: .max),
                error: .discarded
            )

        let result = try await pipeline.run()
        // Should find the error line that was merged into stdout
        let lineCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(lineCount == "1")
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testProcessHelperWithErrorRedirection() async throws {
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["data"]
            )
            | process(
                executable: .name("cat") // Simple passthrough, no error redirection needed
            )
            | process(
                executable: .name("wc"),
                arguments: ["-c"]
            ) |> .string(limit: .max)

        let result = try await pipeline.run()
        // Should count characters in "data\n" (5 characters)
        let charCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(charCount == "5")
        #expect(result.terminationStatus.isSuccess)
    }

    // MARK: - Error Handling Tests

    @Test func testPipelineErrorHandling() async throws {
        // Create a pipeline where one command will fail
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["test"]
            ) | .name("nonexistent-command") // This should fail
            | .name("cat") |> .string(limit: .max)

        await #expect(throws: (any Error).self) {
            _ = try await pipeline.run()
        }
    }

    // MARK: - String Interpolation and Description Tests

    @Test func testPipeConfigurationDescription() {
        let config = pipe(
            executable: .name("echo"),
            arguments: ["test"]
        ).finally(
            output: .string(limit: .max)
        )

        let description = config.description
        #expect(description.contains("PipeConfiguration"))
        #expect(description.contains("echo"))
    }

    @Test func testPipelineDescription() {
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["test"]
            ) | .name("cat")
            | .name("wc") |> .string(limit: .max)

        let description = pipeline.description
        #expect(description.contains("Pipeline with"))
        #expect(description.contains("stages"))
    }

    // MARK: - Helper Function Tests

    @Test func testFinallyHelper() async throws {
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["helper test"]
            ) | .name("cat") |> .string(limit: .max)

        let result = try await pipeline.run()
        #expect(result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) == "helper test")
        #expect(result.terminationStatus.isSuccess)
    }

    @Test func testProcessHelper() async throws {
        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: ["process helper test"]
            )
            | process(
                executable: .name("cat")
            )
            | process(
                executable: .name("wc"),
                arguments: ["-c"]
            ) |> .string(limit: .max)

        let result = try await pipeline.run()
        // "process helper test\n" should be 20 characters
        let charCount = result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(charCount == "20")
        #expect(result.terminationStatus.isSuccess)
    }

    // MARK: - Swift Lambda Tests (Compilation Only)

    // Note: Full Swift lambda execution tests are omitted for now due to generic type inference complexity
    // The Swift lambda functionality is implemented and working, as demonstrated by the successful
    // testMergeErrorRedirection test which uses Swift lambda internally for cross-platform error merging

    // MARK: - Swift Function Tests (Compilation Only)

    // Note: These tests verify that the Swift function APIs compile correctly
    // Full execution tests are complex due to buffer handling and are omitted for now

    // MARK: - JSON Processing with Swift Functions

    @Test func testJSONEncodingPipeline() async throws {
        struct Person: Codable {
            let name: String
            let age: Int
        }

        let people = [
            Person(name: "Alice", age: 30),
            Person(name: "Bob", age: 25),
            Person(name: "Charlie", age: 35),
        ]

        let pipeline =
            pipe(
                swiftFunction: { input, output, err in
                    // Encode array of Person objects to JSON
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted

                    do {
                        let jsonData = try encoder.encode(people)
                        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
                        let written = try await output.write(jsonString)
                        return written > 0 ? 0 : 1
                    } catch {
                        try await err.write("JSON encoding failed: \(error)")
                        return 1
                    }
                }
            )
            | process(
                executable: .name("jq"),
                arguments: [".[] | select(.age > 28)"] // Filter people over 28
            ) |> (
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        // This test is for compilation only - would need jq installed to run
        #expect(pipeline.stages.count == 2)
    }

    @Test func testJSONDecodingPipeline() async throws {
        struct User: Codable {
            let id: Int
            let username: String
            let email: String
        }

        let usersJson = #"[{"id": 1, "username": "alice", "email": "alice@example.com"}, {"id": 2, "username": "bob", "email": "bob@example.com"}, {"id": 3, "username": "charlie", "email": "charlie@example.com"}, {"id": 6, "username": "dave", "email": "dave@example.com"}]"#

        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: [usersJson]
            ) | { input, output, err in
                // Read JSON and decode to User objects
                var jsonData = Data()

                for try await chunk in input.lines() {
                    jsonData.append(contentsOf: chunk.utf8)
                }

                do {
                    let decoder = JSONDecoder()
                    let users = try decoder.decode([User].self, from: jsonData)

                    // Filter and transform users
                    let filteredUsers = users.filter { $0.id <= 5 }
                    let usernames = filteredUsers.map { $0.username }.joined(separator: "\n")

                    let written = try await output.write(usernames)
                    return written > 0 ? 0 : 1
                } catch {
                    try await err.write("JSON decoding failed: \(error)")
                    return 1
                }
            } | .name("sort")
            |> (
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        // This test is for compilation only
        #expect(pipeline.stages.count == 3)
    }

    @Test func testJSONTransformationPipeline() async throws {
        struct InputData: Codable {
            let items: [String]
            let metadata: [String: String]
        }

        struct OutputData: Codable {
            let processedItems: [String]
            let itemCount: Int
            let processingDate: String
        }

        let pipeline =
            pipe(
                executable: .name("echo"),
                arguments: [#"{"items": ["apple", "banana", "cherry"], "metadata": {"source": "test"}}"#]
            ) | { input, output, err in
                // Transform JSON structure
                var jsonData = Data()

                for try await chunk in input.lines() {
                    jsonData.append(contentsOf: chunk.utf8)
                }

                do {
                    let decoder = JSONDecoder()
                    let inputData = try decoder.decode(InputData.self, from: jsonData)

                    let outputData = OutputData(
                        processedItems: inputData.items.map { $0.uppercased() },
                        itemCount: inputData.items.count,
                        processingDate: ISO8601DateFormatter().string(from: Date())
                    )

                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    let outputJson = try encoder.encode(outputData)
                    let jsonString = String(data: outputJson, encoding: .utf8) ?? ""

                    let written = try await output.write(jsonString)
                    return written > 0 ? 0 : 1
                } catch {
                    try await err.write("JSON transformation failed: \(error)")
                    return 1
                }
            } |> (
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        // This test is for compilation only
        #expect(pipeline.stages.count == 2)
    }

    @Test func testJSONStreamProcessing() async throws {
        struct LogEntry: Codable {
            let timestamp: String
            let level: String
            let message: String
        }

        let pipeline =
            pipe(
                executable: .name("tail"),
                arguments: ["-f", "/var/log/app.log"]
            ) | { input, output, error in
                // Process JSON log entries line by line
                for try await line in input.lines() {
                    guard !line.isEmpty else { continue }

                    do {
                        let decoder = JSONDecoder()
                        let logEntry = try decoder.decode(LogEntry.self, from: line.data(using: .utf8) ?? Data())

                        // Filter for error/warning logs and format output
                        if ["ERROR", "WARN"].contains(logEntry.level) {
                            let formatted = "[\(logEntry.timestamp)] \(logEntry.level): \(logEntry.message)"
                            _ = try await output.write(formatted + "\n")
                        }
                    } catch {
                        // Skip malformed JSON lines
                        continue
                    }
                }
                return 0
            }
            | process(
                executable: .name("head"),
                arguments: ["-20"] // Limit to first 20 error/warning entries
            ) |> (
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        // This test is for compilation only
        #expect(pipeline.stages.count == 3)
    }

    @Test func testJSONAggregationPipeline() async throws {
        struct SalesRecord: Codable {
            let product: String
            let amount: Double
            let date: String
        }

        struct SalesSummary: Codable {
            let totalSales: Double
            let productCounts: [String: Int]
            let averageSale: Double
        }

        let pipeline =
            pipe(
                executable: .name("cat"),
                arguments: ["sales_data.jsonl"] // JSON Lines format
            ) | { input, output, err in
                // Aggregate JSON sales data
                var totalSales: Double = 0
                var productCounts: [String: Int] = [:]
                var recordCount = 0

                for try await line in input.lines() {
                    guard !line.isEmpty else { continue }

                    do {
                        let decoder = JSONDecoder()
                        let record = try decoder.decode(SalesRecord.self, from: line.data(using: .utf8) ?? Data())

                        totalSales += record.amount
                        productCounts[record.product, default: 0] += 1
                        recordCount += 1
                    } catch {
                        // Log parsing errors but continue
                        try await err.write("Failed to parse line: \(line)\n")
                    }
                }

                let summary = SalesSummary(
                    totalSales: totalSales,
                    productCounts: productCounts,
                    averageSale: recordCount > 0 ? totalSales / Double(recordCount) : 0
                )

                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    let summaryJson = try encoder.encode(summary)
                    let jsonString = String(data: summaryJson, encoding: .utf8) ?? ""

                    let written = try await output.write(jsonString)
                    return written > 0 ? 0 : 1
                } catch {
                    try await err.write("Failed to encode summary: \(error)")
                    return 1
                }
            } |> (
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        // This test is for compilation only
        #expect(pipeline.stages.count == 2)
    }

    @Test func testJSONValidationPipeline() async throws {
        struct Config: Codable {
            let version: String
            let settings: [String: String]
            let enabled: Bool
        }

        let pipeline =
            pipe(
                executable: .name("find"),
                arguments: ["/etc/configs", "-name", "*.json"]
            )
            | process(
                executable: .name("xargs"),
                arguments: ["cat"]
            ) | { input, output, err in
                // Validate JSON configurations
                var validConfigs = 0
                var invalidConfigs = 0
                var currentJson = ""

                for try await line in input.lines() {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        // End of JSON object, try to validate
                        if !currentJson.isEmpty {
                            do {
                                let decoder = JSONDecoder()
                                let config = try decoder.decode(Config.self, from: currentJson.data(using: .utf8) ?? Data())

                                // Additional validation
                                if !config.version.isEmpty && config.enabled {
                                    validConfigs += 1
                                    _ = try await output.write("VALID: \(config.version)\n")
                                } else {
                                    invalidConfigs += 1
                                    _ = try await err.write("INVALID: Missing version or disabled\n")
                                }
                            } catch {
                                invalidConfigs += 1
                                _ = try await err.write("PARSE_ERROR: \(error)\n")
                            }
                            currentJson = ""
                        }
                    } else {
                        currentJson += line + "\n"
                    }
                }

                // Process any remaining JSON
                if !currentJson.isEmpty {
                    do {
                        let decoder = JSONDecoder()
                        let config = try decoder.decode(Config.self, from: currentJson.data(using: .utf8) ?? Data())
                        if !config.version.isEmpty && config.enabled {
                            validConfigs += 1
                            _ = try await output.write("VALID: \(config.version)\n")
                        }
                    } catch {
                        invalidConfigs += 1
                        _ = try await err.write("PARSE_ERROR: \(error)\n")
                    }
                }

                // Summary
                _ = try await output.write("\nSUMMARY: \(validConfigs) valid, \(invalidConfigs) invalid\n")
                return invalidConfigs > 0 ? 1 : 0
            } |> (
                output: .string(limit: .max),
                error: .string(limit: .max)
            )

        // This test is for compilation only
        #expect(pipeline.stages.count == 3)
    }
}

// MARK: - Compilation Tests (no execution)

extension PipeConfigurationTests {

    @Test func testCompilationOfVariousPatterns() {
        // These tests just verify that various patterns compile correctly
        // They don't execute to avoid platform dependencies

        // Basic pattern with error redirection
        let _ = pipe(
            executable: .name("sh"),
            arguments: ["-c", "echo test >&2"],
            options: .stderrToStdout
        ).finally(
            output: .string(limit: .max),
            error: .string(limit: .max)
        )

        // Pipe pattern
        let _ =
            pipe(
                executable: .name("echo")
            ) | .name("cat")
            | .name("wc") |> .string(limit: .max)

        // Pipe pattern with error redirection
        let _ =
            pipe(
                executable: .name("echo")
            )
            | withOptions(
                configuration: Configuration(executable: .name("cat")),
                options: .mergeErrors
            ) | .name("wc") |> .string(limit: .max)

        // Complex pipeline pattern with process helper and error redirection
        let _ =
            pipe(
                executable: .name("find"),
                arguments: ["/tmp"]
            ) | process(executable: .name("head"), arguments: ["-10"], options: .stderrToStdout)
            | .name("sort")
            | process(executable: .name("tail"), arguments: ["-5"]) |> .string(limit: .max)

        // Configuration-based pattern with error redirection
        let config = Configuration(executable: .name("ls"))
        let _ =
            pipe(
                configuration: config,
                options: .mergeErrors
            ) | .name("wc")
            | .name("cat") |> .string(limit: .max)

        // Swift function patterns (compilation only)
        let _ = pipe(
            swiftFunction: { input, output, error in
                // Compilation test - no execution needed
                return 0
            }
        ).finally(
            output: .string(limit: .max)
        )

        let _ = pipe(
            swiftFunction: { input, output, error in
                // Compilation test - no execution needed
                return 0
            }
        ).finally(
            input: .string("test"),
            output: .string(limit: .max),
            error: .discarded
        )

        // Mixed pipeline with Swift functions (compilation only)
        let _ =
            pipe(
                executable: .name("echo"),
                arguments: ["start"]
            ) | { input, output, error in
                // This is a compilation test - the function body doesn't need to be executable
                return 0
            } | { input, output, error in
                // This is a compilation test - the function body doesn't need to be executable
                return 0
            } | { input, output, error in
                return 0
            } |> (
                output: .string(limit: .max),
                error: .discarded
            )

        // Swift function with finally helper
        let _ =
            pipe(
                executable: .name("echo")
            ) | { input, output, error in
                return 0
            } |> (
                output: .string(limit: .max),
                error: .discarded
            )

        #expect(Bool(true)) // All patterns compiled successfully
    }
}
