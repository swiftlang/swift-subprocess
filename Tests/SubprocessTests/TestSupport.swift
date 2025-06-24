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

#if canImport(Darwin)
// On Darwin always prefer system Foundation
import Foundation
#else
// On other platforms prefer FoundationEssentials
import FoundationEssentials
#endif

import Testing
import Subprocess

internal func randomString(length: Int, lettersOnly: Bool = false) -> String {
    let letters: String
    if lettersOnly {
        letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    } else {
        letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    }
    return String((0..<length).map { _ in letters.randomElement()! })
}

internal func directory(_ lhs: String, isSameAs rhs: String) -> Bool {
    guard lhs != rhs else {
        return true
    }
    var canonicalLhs: String = (try? FileManager.default.destinationOfSymbolicLink(atPath: lhs)) ?? lhs
    var canonicalRhs: String = (try? FileManager.default.destinationOfSymbolicLink(atPath: rhs)) ?? rhs
    if !canonicalLhs.starts(with: "/") {
        canonicalLhs = "/\(canonicalLhs)"
    }
    if !canonicalRhs.starts(with: "/") {
        canonicalRhs = "/\(canonicalRhs)"
    }

    return canonicalLhs == canonicalRhs
}

extension Trait where Self == ConditionTrait {
    public static var requiresBash: Self {
        enabled(
            if: (try? Executable.name("bash").resolveExecutablePath(in: .inherit)) != nil,
            "This test requires bash (install `bash` package on Linux/BSD)"
        )
    }
}
