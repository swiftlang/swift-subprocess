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

import Testing
@testable import Subprocess

private func enableLintingTest() -> Bool {
    guard CommandLine.arguments.first(where: { $0.contains("/.build/") }) != nil else {
        return false
    }
    #if os(macOS)
    // Use xcrun
    do {
        _ = try Executable.path("/usr/bin/xcrun")
            .resolveExecutablePath(in: .inherit)
        return true
    } catch {
        return false
    }
    #else
    // Use swift-format directly
    do {
        _ = try Executable.name("swift-format")
            .resolveExecutablePath(in: .inherit)
        return true
    } catch {
        return false
    }
    #endif
}

struct SubprocessLintingTest {
    @Test(
        .enabled(
            if: false/* enableLintingTest() */,
            "Skipped until we decide on the rules"
        )
    )
    func runLinter() async throws {
        // META: Use Subprocess to run `swift-format` on self
        // to make sure it's properly linted
        guard
            let maybePath = CommandLine.arguments.first(
                where: { $0.contains("/.build/") }
            )
        else {
            return
        }
        let sourcePath = String(
            maybePath.prefix(upTo: maybePath.range(of: "/.build")!.lowerBound)
        )
        print("Linting \(sourcePath)")
        #if os(macOS)
        let configuration = Configuration(
            executable: .path("/usr/bin/xcrun"),
            arguments: ["swift-format", "lint", "-s", "--recursive", sourcePath]
        )
        #else
        let configuration = Configuration(
            executable: .name("swift-format"),
            arguments: ["lint", "-s", "--recursive", sourcePath]
        )
        #endif
        let lintResult = try await Subprocess.run(
            configuration,
            output: .discarded,
            error: .string(limit: .max)
        )
        #expect(
            lintResult.terminationStatus.isSuccess,
            "❌ `swift-format lint --recursive \(sourcePath)` failed"
        )
        if let error = lintResult.standardError?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !error.isEmpty {
            print("\(error)\n")
        } else {
            print("✅ Linting passed")
        }
    }
}
