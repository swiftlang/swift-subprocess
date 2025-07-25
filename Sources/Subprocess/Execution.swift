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
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
@preconcurrency import WinSDK
#endif

/// An object that represents a subprocess that has been
/// executed. You can use this object to send signals to the
/// child process as well as stream its output and error.
public struct Execution: Sendable {
    /// The process identifier of the current execution
    public let processIdentifier: ProcessIdentifier

    init(
        processIdentifier: ProcessIdentifier
    ) {
        self.processIdentifier = processIdentifier
    }
}

// MARK: - Output Capture
internal enum OutputCapturingState<Output: Sendable, Error: Sendable>: Sendable {
    case standardOutputCaptured(Output)
    case standardErrorCaptured(Error)
}
