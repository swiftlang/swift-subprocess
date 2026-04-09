//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import Testing
import Subprocess

#if canImport(Darwin)
import Foundation
#else
import FoundationEssentials
#endif

@Suite(.serialized)
struct ProtocolConformanceTests {

    @Test func customOutputJSON() async throws {
        struct JSONOutput<T: Decodable & Sendable>: OutputProtocol {
            typealias OutputType = T

            func output(from span: RawSpan) throws -> T {
                try span.withUnsafeBytes { buffer in
                    let data = Data(bytes: buffer.baseAddress!, count: buffer.count)
                    return try JSONDecoder().decode(T.self, from: data)
                }
            }
        }

        struct Item: Codable, Sendable, Equatable {
            let title: String
        }

        let json = #"{"title":"Hello from Subprocess"}"#

        #if os(Windows)
        let result = try await Subprocess.run(
            .name("cmd.exe"),
            arguments: ["/c", "echo", json],
            output: JSONOutput<Item>(),
            error: .discarded
        )
        #else
        let result = try await Subprocess.run(
            .name("echo"),
            arguments: [json],
            output: JSONOutput<Item>(),
            error: .discarded
        )
        #endif

        #expect(result.terminationStatus.isSuccess)
        #expect(result.standardOutput == Item(title: "Hello from Subprocess"))
        #expect(result.standardOutput.title == "Hello from Subprocess")
    }

}
