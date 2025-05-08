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
import WinSDK
#endif

internal import Dispatch

/// An object that repersents a subprocess that has been
/// executed. You can use this object to send signals to the
/// child process as well as stream its output and error.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public final class Execution<
    Output: OutputProtocol,
    Error: OutputProtocol
>: Sendable {
    /// The process identifier of the current execution
    public let processIdentifier: ProcessIdentifier

    internal let output: Output
    internal let error: Error
    internal let inputPipe: InputPipe
    internal let outputPipe: OutputPipe
    internal let errorPipe: OutputPipe
    internal let outputConsumptionState: AtomicBox

    #if os(Windows)
    internal let consoleBehavior: PlatformOptions.ConsoleBehavior

    init(
        processIdentifier: ProcessIdentifier,
        output: Output,
        error: Error,
        inputPipe: InputPipe,
        outputPipe: OutputPipe,
        errorPipe: OutputPipe,
        consoleBehavior: PlatformOptions.ConsoleBehavior
    ) {
        self.processIdentifier = processIdentifier
        self.output = output
        self.error = error
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.outputConsumptionState = AtomicBox()
        self.consoleBehavior = consoleBehavior
    }
    #else
    init(
        processIdentifier: ProcessIdentifier,
        output: Output,
        error: Error,
        inputPipe: InputPipe,
        outputPipe: OutputPipe,
        errorPipe: OutputPipe
    ) {
        self.processIdentifier = processIdentifier
        self.output = output
        self.error = error
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.outputConsumptionState = AtomicBox()
    }
    #endif  // os(Windows)
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension Execution where Output == SequenceOutput {
    /// The standard output of the subprocess.
    ///
    /// Accessing this property will **fatalError** if this property was
    /// accessed multiple times. Subprocess communicates with parent process
    /// via pipe under the hood and each pipe can only be consumed once.
    public var standardOutput: AsyncBufferSequence {
        let consumptionState = self.outputConsumptionState.bitwiseXor(
            OutputConsumptionState.standardOutputConsumed
        )

        guard consumptionState.contains(.standardOutputConsumed),
            let readFd = self.outputPipe.readEnd
        else {
            fatalError("The standard output has already been consumed")
        }

        if let lowWater = output.lowWater {
            readFd.dispatchIO.setLimit(lowWater: lowWater)
        }

        if let highWater = output.highWater {
            readFd.dispatchIO.setLimit(highWater: highWater)
        }

        return AsyncBufferSequence(diskIO: readFd, bufferSize: output.bufferSize)
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension Execution where Error == SequenceOutput {
    /// The standard error of the subprocess.
    ///
    /// Accessing this property will **fatalError** if this property was
    /// accessed multiple times. Subprocess communicates with parent process
    /// via pipe under the hood and each pipe can only be consumed once.
    public var standardError: AsyncBufferSequence {
        let consumptionState = self.outputConsumptionState.bitwiseXor(
            OutputConsumptionState.standardErrorConsumed
        )

        guard consumptionState.contains(.standardErrorConsumed),
            let readFd = self.errorPipe.readEnd
        else {
            fatalError("The standard output has already been consumed")
        }

        if let lowWater = error.lowWater {
            readFd.dispatchIO.setLimit(lowWater: lowWater)
        }

        if let highWater = error.highWater {
            readFd.dispatchIO.setLimit(highWater: highWater)
        }

        return AsyncBufferSequence(diskIO: readFd, bufferSize: error.bufferSize)
    }
}

// MARK: - Output Capture
internal enum OutputCapturingState<Output: Sendable, Error: Sendable>: Sendable {
    case standardOutputCaptured(Output)
    case standardErrorCaptured(Error)
}

internal struct OutputConsumptionState: OptionSet {
    typealias RawValue = UInt8

    internal let rawValue: UInt8

    internal init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let standardOutputConsumed: Self = .init(rawValue: 0b0001)
    static let standardErrorConsumed: Self = .init(rawValue: 0b0010)
}

internal typealias CapturedIOs<
    Output: Sendable,
    Error: Sendable
> = (standardOutput: Output, standardError: Error)

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension Execution {
    internal func captureIOs() async throws -> CapturedIOs<
        Output.OutputType, Error.OutputType
    > {
        return try await withThrowingTaskGroup(
            of: OutputCapturingState<Output.OutputType, Error.OutputType>.self
        ) { group in
            group.addTask {
                let stdout = try await self.output.captureOutput(
                    from: self.outputPipe.readEnd
                )
                return .standardOutputCaptured(stdout)
            }
            group.addTask {
                let stderr = try await self.error.captureOutput(
                    from: self.errorPipe.readEnd
                )
                return .standardErrorCaptured(stderr)
            }

            var stdout: Output.OutputType!
            var stderror: Error.OutputType!
            while let state = try await group.next() {
                switch state {
                case .standardOutputCaptured(let output):
                    stdout = output
                case .standardErrorCaptured(let error):
                    stderror = error
                }
            }
            return (
                standardOutput: stdout,
                standardError: stderror
            )
        }
    }
}
