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
import System
#else
import SystemPackage
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

/// A running subprocess.
///
/// Use this type to send signals to the child process, write to its standard
/// input, and stream its standard output and standard error.
///
/// The three generic parameters determine which streaming properties are
/// available. The ``standardInputWriter`` property is available when `Input`
/// is ``CustomWriteInput``, the ``standardOutput`` property is available
/// when `Output` is ``SequenceOutput``, and the ``standardError`` property
/// is available when `Error` is ``SequenceOutput``.
///
/// You receive an `Execution` value from the body closure of a `run`
/// function. The value is valid only for the duration of the closure.
/// Don't let the execution value escape the closure.
public struct Execution<Input: InputProtocol, Output: OutputProtocol, Error: OutputProtocol>: Sendable {
    /// The process identifier of this subprocess.
    public let processIdentifier: ProcessIdentifier

    private let inputWriter: StandardInputWriter?
    private let outputStream: AsyncBufferSequence?
    private let errorStream: AsyncBufferSequence?

    init(
        processIdentifier: ProcessIdentifier,
        inputWriter: StandardInputWriter?,
        outputStream: AsyncBufferSequence?,
        errorStream: AsyncBufferSequence?
    ) {
        self.processIdentifier = processIdentifier
        self.inputWriter = inputWriter
        self.outputStream = outputStream
        self.errorStream = errorStream
    }
}

extension Execution where Input == CustomWriteInput {
    /// A writer that sends data to the subprocess's standard input.
    ///
    /// Call ``StandardInputWriter/finish()`` after the last write so the
    /// subprocess sees end-of-file on its standard input.
    public var standardInputWriter: StandardInputWriter {
        return self.inputWriter!
    }
}

extension Execution where Output == SequenceOutput {
    /// The standard output of the subprocess as an asynchronous sequence of
    /// buffers.
    public var standardOutput: AsyncBufferSequence {
        return self.outputStream!
    }
}

extension Execution where Error == SequenceOutput {
    /// The standard error of the subprocess as an asynchronous sequence of
    /// buffers.
    public var standardError: AsyncBufferSequence {
        return self.errorStream!
    }
}

extension Execution {
    @available(*, unavailable, message: "this property requires that the input is .standardInput")
    public var standardInputWriter: StandardInputWriter {
        fatalError()
    }

    @available(*, unavailable, message: "this property requires that the output is .sequence")
    public var standardOutput: AsyncBufferSequence {
        fatalError()
    }

    @available(*, unavailable, message: "this property requires that the error is .sequence")
    public var standardError: AsyncBufferSequence {
        fatalError()
    }
}

// MARK: - Output Capture
internal enum OutputCapturingState<Output: Sendable, Error: Sendable>: Sendable {
    case standardOutputCaptured(Output)
    case standardErrorCaptured(Error)
}
