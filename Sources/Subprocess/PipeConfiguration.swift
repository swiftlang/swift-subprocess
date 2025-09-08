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

#if canImport(Foundation)
import Foundation
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
@preconcurrency import WinSDK
#endif

internal import Dispatch

// MARK: - Custom Operators

/// Final pipe operator - pipes to the last process in a pipeline and specifies output
infix operator |> : AdditionPrecedence

// MARK: - Error Redirection Options

/// Options for redirecting standard error in process pipelines
public enum ErrorRedirection: Sendable {
    /// Keep stderr separate (default behavior)
    case separate
    /// Redirect stderr to stdout, replacing stdout entirely (stdout -> /dev/null)
    case replaceStdout
    /// Merge stderr into stdout (both go to the same destination)
    case mergeWithStdout
}

/// Configuration for error redirection in process stages
public struct ProcessStageOptions: Sendable {
    /// How to handle standard error redirection
    public let errorRedirection: ErrorRedirection

    /// Initialize with error redirection option
    public init(errorRedirection: ErrorRedirection = .separate) {
        self.errorRedirection = errorRedirection
    }

    /// Default options (no redirection)
    public static let `default` = ProcessStageOptions()

    /// Redirect stderr to stdout, discarding original stdout
    public static let stderrToStdout = ProcessStageOptions(errorRedirection: .replaceStdout)

    /// Merge stderr with stdout
    public static let mergeErrors = ProcessStageOptions(errorRedirection: .mergeWithStdout)
}

// MARK: - PipeStage (Public API)

/// A single stage in a process pipeline
public struct PipeStage: Sendable {
    enum StageType: Sendable {
        case process(configuration: Configuration, options: ProcessStageOptions)
        case swiftFunction(@Sendable (AsyncBufferSequence, StandardInputWriter, StandardInputWriter) async throws -> UInt32)
    }

    let stageType: StageType

    /// Create a PipeStage from a process configuration
    public init(
        configuration: Configuration,
        options: ProcessStageOptions = .default
    ) {
        self.stageType = .process(configuration: configuration, options: options)
    }

    /// Create a PipeStage from executable parameters
    public init(
        executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        options: ProcessStageOptions = .default
    ) {
        let configuration = Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        self.stageType = .process(configuration: configuration, options: options)
    }

    /// Create a PipeStage from a Swift function
    public init(
        swiftFunction: @escaping @Sendable (AsyncBufferSequence, StandardInputWriter, StandardInputWriter) async throws -> UInt32
    ) {
        self.stageType = .swiftFunction(swiftFunction)
    }

    // Convenience accessors
    var configuration: Configuration? {
        switch stageType {
        case .process(let configuration, _):
            return configuration
        case .swiftFunction:
            return nil
        }
    }

    var options: ProcessStageOptions {
        switch stageType {
        case .process(_, let options):
            return options
        case .swiftFunction:
            return .default
        }
    }
}

/// A struct that encapsulates one or more pipe stages in a pipeline
/// with overall I/O specification for input, output and errors.
/// A pipe stage can be either a process with options for reconfiguring
/// standard output and standard error, or a Swift function that can
/// stream standard input, output, and error with an exit code.
public struct PipeConfiguration<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: OutputProtocol
>: Sendable, CustomStringConvertible {
    /// Array of process stages in the pipeline
    internal var stages: [PipeStage]

    /// Input configuration for the first stage
    internal var input: Input

    /// Output configuration for the last stage
    internal var output: Output

    /// Error configuration for the last stage
    internal var error: Error

    /// Initialize a PipeConfiguration with a base Configuration
    /// Internal initializer - users should use convenience initializers
    internal init(
        configuration: Configuration,
        input: Input,
        output: Output,
        error: Error,
        options: ProcessStageOptions = .default
    ) {
        self.stages = [PipeStage(configuration: configuration, options: options)]
        self.input = input
        self.output = output
        self.error = error
    }

    /// Internal initializer for creating from stages and I/O
    internal init(
        stages: [PipeStage],
        input: Input,
        output: Output,
        error: Error
    ) {
        self.stages = stages
        self.input = input
        self.output = output
        self.error = error
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        if stages.count == 1 {
            let stage = stages[0]
            switch stage.stageType {
            case .process(let configuration, _):
                return "PipeConfiguration(\(configuration.executable))"
            case .swiftFunction:
                return "PipeConfiguration(swiftFunction)"
            }
        } else {
            return "Pipeline with \(stages.count) stages"
        }
    }
}

// MARK: - Public Initializers (Default to Discarded I/O)

extension PipeConfiguration where Input == NoInput, Output == DiscardedOutput, Error == DiscardedOutput {
    /// Initialize a PipeConfiguration with executable and arguments
    /// I/O defaults to discarded until finalized with `finally`
    public init(
        executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        options: ProcessStageOptions = .default
    ) {
        let configuration = Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        self.stages = [PipeStage(configuration: configuration, options: options)]
        self.input = NoInput()
        self.output = DiscardedOutput()
        self.error = DiscardedOutput()
    }

    /// Initialize a PipeConfiguration with a Configuration
    /// I/O defaults to discarded until finalized with `finally`
    public init(
        configuration: Configuration,
        options: ProcessStageOptions = .default
    ) {
        self.stages = [PipeStage(configuration: configuration, options: options)]
        self.input = NoInput()
        self.output = DiscardedOutput()
        self.error = DiscardedOutput()
    }

    /// Initialize a PipeConfiguration with a Swift function
    /// I/O defaults to discarded until finalized with `finally`
    public init(
        swiftFunction: @escaping @Sendable (AsyncBufferSequence, StandardInputWriter, StandardInputWriter) async throws -> UInt32
    ) {
        self.stages = [PipeStage(swiftFunction: swiftFunction)]
        self.input = NoInput()
        self.output = DiscardedOutput()
        self.error = DiscardedOutput()
    }
}

/// Helper enum for pipeline task results
internal enum PipelineTaskResult: Sendable {
    case success(Int, SendableCollectedResult)
    case failure(Int, Swift.Error)
}

/// Sendable wrapper for CollectedResult
internal struct SendableCollectedResult: @unchecked Sendable {
    let processIdentifier: ProcessIdentifier
    let terminationStatus: TerminationStatus
    let standardOutput: Any
    let standardError: Any

    init<Output: OutputProtocol, Error: OutputProtocol>(_ result: CollectedResult<Output, Error>) {
        self.processIdentifier = result.processIdentifier
        self.terminationStatus = result.terminationStatus
        self.standardOutput = result.standardOutput
        self.standardError = result.standardError
    }
}

private func currentProcessIdentifier() -> ProcessIdentifier {
    #if os(macOS)
    return .init(value: ProcessInfo.processInfo.processIdentifier)
    #elseif canImport(Glibc) || canImport(Android) || canImport(Musl)
    return .init(value: ProcessInfo.processInfo.processIdentifier, processDescriptor: -1)
    #elseif os(Windows)
    return .init(value: UInt32(ProcessInfo.processInfo.processIdentifier), processDescriptor: INVALID_HANDLE_VALUE, threadHandle: INVALID_HANDLE_VALUE)
    #endif
}

private func createIODescriptor(from fd: FileDescriptor, closeWhenDone: Bool) -> IODescriptor {
    #if canImport(WinSDK)
    return IODescriptor(HANDLE(bitPattern: _get_osfhandle(fd.rawValue))!, closeWhenDone: closeWhenDone)
    #else
    return IODescriptor(fd, closeWhenDone: closeWhenDone)
    #endif
}

private func createTerminationStatus(_ exitCode: UInt32) -> TerminationStatus {
    #if canImport(WinSDK)
    return .exited(exitCode)
    #else
    return .exited(Int32(exitCode))
    #endif
}

private func createPipe() throws -> (readEnd: FileDescriptor, writeEnd: FileDescriptor) {
    var createdPipe = try CreatedPipe(closeWhenDone: false, purpose: .output)

    #if canImport(WinSDK)
    let readHandle = createdPipe.readFileDescriptor()!.platformDescriptor()
    let writeHandle = createdPipe.writeFileDescriptor()!.platformDescriptor()
    let readFd = _open_osfhandle(
        intptr_t(bitPattern: readHandle),
        FileDescriptor.AccessMode.readOnly.rawValue
    )
    let writeFd = _open_osfhandle(
        intptr_t(bitPattern: writeHandle),
        FileDescriptor.AccessMode.writeOnly.rawValue
    )
    #else
    let readFd = createdPipe.readFileDescriptor()!.platformDescriptor()
    let writeFd = createdPipe.writeFileDescriptor()!.platformDescriptor()
    #endif

    return (readEnd: FileDescriptor(rawValue: readFd), writeEnd: FileDescriptor(rawValue: writeFd))
}

// MARK: - Internal Functions

extension PipeConfiguration {
    public func run() async throws -> CollectedResult<Output, Error> {
        if stages.count == 1 {
            let stage = stages[0]

            switch stage.stageType {
            case .process(let configuration, let options):
                // Single process - run directly with error redirection
                switch options.errorRedirection {
                case .separate:
                    // No redirection - use original configuration
                    return try await Subprocess.run(
                        configuration,
                        input: self.input,
                        output: self.output,
                        error: self.error
                    )

                case .replaceStdout:
                    // Redirect stderr to stdout, discard original stdout
                    let result = try await Subprocess.run(
                        configuration,
                        input: self.input,
                        output: .discarded,
                        error: self.output
                    )

                    let emptyError: Error.OutputType =
                        if Error.OutputType.self == Void.self {
                            () as! Error.OutputType
                        } else if Error.OutputType.self == String?.self {
                            String?.none as! Error.OutputType
                        } else if Error.OutputType.self == [UInt8]?.self {
                            [UInt8]?.none as! Error.OutputType
                        } else {
                            fatalError()
                        }

                    // Create a new result with the error output as the standard output
                    return CollectedResult(
                        processIdentifier: result.processIdentifier,
                        terminationStatus: result.terminationStatus,
                        standardOutput: result.standardError,
                        standardError: emptyError
                    )

                case .mergeWithStdout:
                    // Redirect stderr to stdout, merge both streams
                    let finalResult = try await Subprocess.run(
                        configuration,
                        input: self.input,
                        output: self.output,
                        error: self.output
                    )

                    let emptyError: Error.OutputType =
                        if Error.OutputType.self == Void.self {
                            () as! Error.OutputType
                        } else if Error.OutputType.self == String?.self {
                            String?.none as! Error.OutputType
                        } else if Error.OutputType.self == [UInt8]?.self {
                            [UInt8]?.none as! Error.OutputType
                        } else {
                            fatalError()
                        }

                    // Merge the different kinds of output types (string, fd, etc.)
                    if Output.OutputType.self == Void.self {
                        return CollectedResult<Output, Error>(
                            processIdentifier: finalResult.processIdentifier,
                            terminationStatus: finalResult.terminationStatus,
                            standardOutput: () as! Output.OutputType,
                            standardError: finalResult.standardOutput as! Error.OutputType
                        )
                    } else if Output.OutputType.self == String?.self {
                        let out: String? = finalResult.standardOutput as! String?
                        let err: String? = finalResult.standardError as! String?

                        let finalOutput = (out ?? "") + (err ?? "")
                        // FIXME reduce the final output to the output.maxSize number of bytes

                        return CollectedResult<Output, Error>(
                            processIdentifier: finalResult.processIdentifier,
                            terminationStatus: finalResult.terminationStatus,
                            standardOutput: finalOutput as! Output.OutputType,
                            standardError: emptyError
                        )
                    } else if Output.OutputType.self == [UInt8].self {
                        let out: [UInt8]? = finalResult.standardOutput as! [UInt8]?
                        let err: [UInt8]? = finalResult.standardError as! [UInt8]?

                        var finalOutput = (out ?? []) + (err ?? [])
                        if finalOutput.count > self.output.maxSize {
                            finalOutput = [UInt8](finalOutput[...self.output.maxSize])
                        }

                        return CollectedResult<Output, Error>(
                            processIdentifier: finalResult.processIdentifier,
                            terminationStatus: finalResult.terminationStatus,
                            standardOutput: finalOutput as! Output.OutputType,
                            standardError: emptyError
                        )
                    } else {
                        fatalError()
                    }
                }

            case .swiftFunction:
                fatalError("Trivial pipeline with only a single swift function isn't supported")
            }
        } else {
            // Pipeline - run with task group
            return try await runPipeline()
        }
    }

    enum CollectedPipeResult {
        case stderr(Error.OutputType)
        case collectedResult(CollectedResult<Output, DiscardedOutput>)
    }

    /// Run the pipeline using withTaskGroup
    private func runPipeline() async throws -> CollectedResult<Output, Error> {
        // Create a pipe for standard error
        let sharedErrorPipe = try createPipe()
        // FIXME: Use _safelyClose() to fully close each end of the pipe on all platforms

        return try await withThrowingTaskGroup(of: CollectedPipeResult.self, returning: CollectedResult<Output, Error>.self) { group in
            // Collect error output from all stages
            group.addTask {
                let errorReadFileDescriptor = createIODescriptor(from: sharedErrorPipe.readEnd, closeWhenDone: true)
                let errorReadEnd = errorReadFileDescriptor.createIOChannel()

                let stderr = try await self.error.captureOutput(from: errorReadEnd)

                return .stderr(stderr)
            }

            // Perform the main task of assembling the pipeline, I/O and exit code
            group.addTask {
                // Create pipes between stages
                var pipes: [(readEnd: FileDescriptor, writeEnd: FileDescriptor)] = []
                for _ in 0..<(stages.count - 1) {
                    try pipes.append(createPipe())
                    // FIXME: Use _safelyClose() to fully close each end of the pipe on all platforms
                }

                let pipeResult = try await withThrowingTaskGroup(of: PipelineTaskResult.self, returning: CollectedResult<Output, DiscardedOutput>.self) { group in
                    // First process
                    let firstStage = stages[0]
                    if stages.count > 1 {
                        let writeEnd = pipes[0].writeEnd
                        group.addTask {
                            do {
                                switch firstStage.stageType {
                                case .process(let configuration, let options):
                                    var taskResult: PipelineTaskResult

                                    switch options.errorRedirection {
                                    case .separate:
                                        let originalResult = try await Subprocess.run(
                                            configuration,
                                            input: self.input,
                                            output: .fileDescriptor(writeEnd, closeAfterSpawningProcess: true),
                                            error: FileDescriptorOutput(fileDescriptor: sharedErrorPipe.writeEnd, closeAfterSpawningProcess: false)
                                        )

                                        taskResult = PipelineTaskResult.success(
                                            0,
                                            SendableCollectedResult(
                                                CollectedResult<FileDescriptorOutput, DiscardedOutput>(
                                                    processIdentifier: originalResult.processIdentifier,
                                                    terminationStatus: originalResult.terminationStatus,
                                                    standardOutput: (),
                                                    standardError: ()
                                                )))
                                    case .replaceStdout:
                                        let originalResult = try await Subprocess.run(
                                            configuration,
                                            input: self.input,
                                            output: .discarded,
                                            error: .fileDescriptor(writeEnd, closeAfterSpawningProcess: true)
                                        )

                                        taskResult = PipelineTaskResult.success(
                                            0,
                                            SendableCollectedResult(
                                                CollectedResult<FileDescriptorOutput, DiscardedOutput>(
                                                    processIdentifier: originalResult.processIdentifier,
                                                    terminationStatus: originalResult.terminationStatus,
                                                    standardOutput: (),
                                                    standardError: ()
                                                )))
                                    case .mergeWithStdout:
                                        let originalResult = try await Subprocess.run(
                                            configuration,
                                            input: self.input,
                                            output: .fileDescriptor(writeEnd, closeAfterSpawningProcess: false),
                                            error: .fileDescriptor(writeEnd, closeAfterSpawningProcess: false)
                                        )

                                        try writeEnd.close()

                                        taskResult = PipelineTaskResult.success(
                                            0,
                                            SendableCollectedResult(
                                                CollectedResult<FileDescriptorOutput, DiscardedOutput>(
                                                    processIdentifier: originalResult.processIdentifier,
                                                    terminationStatus: originalResult.terminationStatus,
                                                    standardOutput: (),
                                                    standardError: ()
                                                )))
                                    }

                                    return taskResult
                                case .swiftFunction(let function):
                                    var inputPipe: CreatedPipe = try self.input.createPipe()

                                    let inputReadFileDescriptor: IODescriptor? = inputPipe.readFileDescriptor()
                                    var inputWriteFileDescriptor: IODescriptor? = inputPipe.writeFileDescriptor()

                                    var inputReadEnd = inputReadFileDescriptor?.createIOChannel()
                                    var inputWriteEnd: IOChannel? = inputWriteFileDescriptor.take()?.createIOChannel()

                                    let outputWriteFileDescriptor = createIODescriptor(from: writeEnd, closeWhenDone: true)
                                    var outputWriteEnd: IOChannel? = outputWriteFileDescriptor.createIOChannel()

                                    // Use shared error pipe instead of discarded
                                    let errorWriteFileDescriptor = createIODescriptor(from: sharedErrorPipe.writeEnd, closeWhenDone: false)
                                    var errorWriteEnd: IOChannel? = errorWriteFileDescriptor.createIOChannel()

                                    let result = try await withThrowingTaskGroup(of: UInt32.self) { group in
                                        let inputReadEnd = inputReadEnd.take()!
                                        let outputWriteEnd = outputWriteEnd.take()!
                                        let errorWriteEnd = errorWriteEnd.take()!

                                        // FIXME figure out how to propagate a preferred buffer size to this sequence
                                        let inSequence = AsyncBufferSequence(diskIO: inputReadEnd.consumeIOChannel(), preferredBufferSize: nil)
                                        let outWriter = StandardInputWriter(diskIO: outputWriteEnd)
                                        let errWriter = StandardInputWriter(diskIO: errorWriteEnd)

                                        if let inputWriteEnd = inputWriteEnd.take() {
                                            let writer = StandardInputWriter(diskIO: inputWriteEnd)
                                            group.addTask {
                                                try await self.input.write(with: writer)
                                                try await writer.finish()
                                                return 0
                                            }
                                        }

                                        group.addTask {
                                            do {
                                                let retVal = try await function(inSequence, outWriter, errWriter)

                                                // Close outputs in case the function did not
                                                try await outWriter.finish()
                                                try await errWriter.finish()

                                                return retVal
                                            } catch {
                                                // Close outputs in case the function did not
                                                try await outWriter.finish()
                                                try await errWriter.finish()
                                                throw error
                                            }
                                        }

                                        for try await t in group {
                                            if t != 0 {
                                                return t
                                            }
                                        }

                                        return 0
                                    }

                                    return PipelineTaskResult.success(
                                        0,
                                        SendableCollectedResult(
                                            CollectedResult<FileDescriptorOutput, DiscardedOutput>(
                                                processIdentifier: currentProcessIdentifier(),
                                                terminationStatus: createTerminationStatus(result),
                                                standardOutput: (),
                                                standardError: ()
                                            )))
                                }
                            } catch {
                                return PipelineTaskResult.failure(0, error)
                            }
                        }
                    }

                    // Middle processes
                    for i in 1..<(stages.count - 1) {
                        let stage = stages[i]
                        let readEnd = pipes[i - 1].readEnd
                        let writeEnd = pipes[i].writeEnd
                        group.addTask {
                            do {
                                switch stage.stageType {
                                case .process(let configuration, let options):
                                    var taskResult: PipelineTaskResult
                                    switch options.errorRedirection {
                                    case .separate:
                                        let originalResult = try await Subprocess.run(
                                            configuration,
                                            input: .fileDescriptor(readEnd, closeAfterSpawningProcess: true),
                                            output: .fileDescriptor(writeEnd, closeAfterSpawningProcess: true),
                                            error: FileDescriptorOutput(fileDescriptor: sharedErrorPipe.writeEnd, closeAfterSpawningProcess: false)
                                        )

                                        taskResult = PipelineTaskResult.success(
                                            i,
                                            SendableCollectedResult(
                                                CollectedResult<FileDescriptorOutput, DiscardedOutput>(
                                                    processIdentifier: originalResult.processIdentifier,
                                                    terminationStatus: originalResult.terminationStatus,
                                                    standardOutput: (),
                                                    standardError: ()
                                                )))
                                    case .replaceStdout:
                                        let originalResult = try await Subprocess.run(
                                            configuration,
                                            input: .fileDescriptor(readEnd, closeAfterSpawningProcess: true),
                                            output: .discarded,
                                            error: .fileDescriptor(writeEnd, closeAfterSpawningProcess: true)
                                        )

                                        taskResult = PipelineTaskResult.success(
                                            i,
                                            SendableCollectedResult(
                                                CollectedResult<FileDescriptorOutput, DiscardedOutput>(
                                                    processIdentifier: originalResult.processIdentifier,
                                                    terminationStatus: originalResult.terminationStatus,
                                                    standardOutput: (),
                                                    standardError: ()
                                                )))
                                    case .mergeWithStdout:
                                        let originalResult = try await Subprocess.run(
                                            configuration,
                                            input: .fileDescriptor(readEnd, closeAfterSpawningProcess: true),
                                            output: .fileDescriptor(writeEnd, closeAfterSpawningProcess: false),
                                            error: .fileDescriptor(writeEnd, closeAfterSpawningProcess: false)
                                        )

                                        try writeEnd.close()

                                        taskResult = PipelineTaskResult.success(
                                            i,
                                            SendableCollectedResult(
                                                CollectedResult<FileDescriptorOutput, DiscardedOutput>(
                                                    processIdentifier: originalResult.processIdentifier,
                                                    terminationStatus: originalResult.terminationStatus,
                                                    standardOutput: (),
                                                    standardError: ()
                                                )))
                                    }

                                    return taskResult
                                case .swiftFunction(let function):
                                    let inputReadFileDescriptor = createIODescriptor(from: readEnd, closeWhenDone: true)
                                    var inputReadEnd: IOChannel? = inputReadFileDescriptor.createIOChannel()

                                    let outputWriteFileDescriptor = createIODescriptor(from: writeEnd, closeWhenDone: true)
                                    var outputWriteEnd: IOChannel? = outputWriteFileDescriptor.createIOChannel()

                                    // Use shared error pipe instead of discarded
                                    let errorWriteFileDescriptor: IODescriptor = createIODescriptor(from: sharedErrorPipe.writeEnd, closeWhenDone: false)
                                    var errorWriteEnd: IOChannel? = errorWriteFileDescriptor.createIOChannel()

                                    let result = try await withThrowingTaskGroup(of: UInt32.self) { group in
                                        // FIXME figure out how to propagate a preferred buffer size to this sequence
                                        let inSequence = AsyncBufferSequence(diskIO: inputReadEnd.take()!.consumeIOChannel(), preferredBufferSize: nil)
                                        let outWriter = StandardInputWriter(diskIO: outputWriteEnd.take()!)
                                        let errWriter = StandardInputWriter(diskIO: errorWriteEnd.take()!)

                                        group.addTask {
                                            do {
                                                let result = try await function(inSequence, outWriter, errWriter)

                                                // Close outputs in case the function did not
                                                try await outWriter.finish()
                                                try await errWriter.finish()

                                                return result
                                            } catch {
                                                // Close outputs in case the function did not
                                                try await outWriter.finish()
                                                try await errWriter.finish()
                                                throw error
                                            }
                                        }

                                        for try await t in group {
                                            if t != 0 {
                                                return t
                                            }
                                        }

                                        return 0
                                    }

                                    return PipelineTaskResult.success(
                                        i,
                                        SendableCollectedResult(
                                            CollectedResult<FileDescriptorOutput, DiscardedOutput>(
                                                processIdentifier: currentProcessIdentifier(),
                                                terminationStatus: createTerminationStatus(result),
                                                standardOutput: (),
                                                standardError: ()
                                            )))
                                }
                            } catch {
                                return PipelineTaskResult.failure(i, error)
                            }
                        }
                    }

                    // Last process (if there are multiple stages)
                    if stages.count > 1 {
                        let lastIndex = stages.count - 1
                        let lastStage = stages[lastIndex]
                        let readEnd = pipes[lastIndex - 1].readEnd
                        group.addTask {
                            do {
                                switch lastStage.stageType {
                                case .process(let configuration, let options):
                                    switch options.errorRedirection {
                                    case .separate:
                                        let finalResult = try await Subprocess.run(
                                            configuration,
                                            input: .fileDescriptor(readEnd, closeAfterSpawningProcess: true),
                                            output: self.output,
                                            error: FileDescriptorOutput(fileDescriptor: sharedErrorPipe.writeEnd, closeAfterSpawningProcess: false)
                                        )
                                        return PipelineTaskResult.success(lastIndex, SendableCollectedResult(finalResult))
                                    case .replaceStdout:
                                        let finalResult = try await Subprocess.run(
                                            configuration,
                                            input: .fileDescriptor(readEnd, closeAfterSpawningProcess: true),
                                            output: .discarded,
                                            error: self.output
                                        )

                                        let emptyError: Error.OutputType =
                                            if Error.OutputType.self == Void.self {
                                                () as! Error.OutputType
                                            } else if Error.OutputType.self == String?.self {
                                                String?.none as! Error.OutputType
                                            } else if Error.OutputType.self == [UInt8]?.self {
                                                [UInt8]?.none as! Error.OutputType
                                            } else {
                                                fatalError()
                                            }

                                        return PipelineTaskResult.success(
                                            lastIndex,
                                            SendableCollectedResult(
                                                CollectedResult<Output, Error>(
                                                    processIdentifier: finalResult.processIdentifier,
                                                    terminationStatus: finalResult.terminationStatus,
                                                    standardOutput: finalResult.standardError,
                                                    standardError: emptyError
                                                )))
                                    case .mergeWithStdout:
                                        let finalResult = try await Subprocess.run(
                                            configuration,
                                            input: .fileDescriptor(readEnd, closeAfterSpawningProcess: true),
                                            output: self.output,
                                            error: self.output
                                        )

                                        let emptyError: Error.OutputType =
                                            if Error.OutputType.self == Void.self {
                                                () as! Error.OutputType
                                            } else if Error.OutputType.self == String?.self {
                                                String?.none as! Error.OutputType
                                            } else if Error.OutputType.self == [UInt8]?.self {
                                                [UInt8]?.none as! Error.OutputType
                                            } else {
                                                fatalError()
                                            }

                                        // Merge the different kinds of output types (string, fd, etc.)
                                        if Output.OutputType.self == Void.self {
                                            return PipelineTaskResult.success(
                                                lastIndex,
                                                SendableCollectedResult(
                                                    CollectedResult<Output, Error>(
                                                        processIdentifier: finalResult.processIdentifier,
                                                        terminationStatus: finalResult.terminationStatus,
                                                        standardOutput: () as! Output.OutputType,
                                                        standardError: finalResult.standardOutput as! Error.OutputType
                                                    )))
                                        } else if Output.OutputType.self == String?.self {
                                            let out: String? = finalResult.standardOutput as! String?
                                            let err: String? = finalResult.standardError as! String?

                                            let finalOutput = (out ?? "") + (err ?? "")
                                            // FIXME reduce the final output to the output.maxSize number of bytes

                                            return PipelineTaskResult.success(
                                                lastIndex,
                                                SendableCollectedResult(
                                                    CollectedResult<Output, Error>(
                                                        processIdentifier: finalResult.processIdentifier,
                                                        terminationStatus: finalResult.terminationStatus,
                                                        standardOutput: finalOutput as! Output.OutputType,
                                                        standardError: emptyError
                                                    )))
                                        } else if Output.OutputType.self == [UInt8].self {
                                            let out: [UInt8]? = finalResult.standardOutput as! [UInt8]?
                                            let err: [UInt8]? = finalResult.standardError as! [UInt8]?

                                            var finalOutput = (out ?? []) + (err ?? [])
                                            if finalOutput.count > self.output.maxSize {
                                                finalOutput = [UInt8](finalOutput[...self.output.maxSize])
                                            }

                                            return PipelineTaskResult.success(
                                                lastIndex,
                                                SendableCollectedResult(
                                                    CollectedResult<Output, Error>(
                                                        processIdentifier: finalResult.processIdentifier,
                                                        terminationStatus: finalResult.terminationStatus,
                                                        standardOutput: finalOutput as! Output.OutputType,
                                                        standardError: emptyError
                                                    )))
                                        } else {
                                            fatalError()
                                        }
                                    }
                                case .swiftFunction(let function):
                                    let inputReadFileDescriptor = createIODescriptor(from: readEnd, closeWhenDone: true)
                                    var inputReadEnd: IOChannel? = inputReadFileDescriptor.createIOChannel()

                                    var outputPipe = try self.output.createPipe()
                                    let outputWriteFileDescriptor = outputPipe.writeFileDescriptor()
                                    var outputWriteEnd: IOChannel? = outputWriteFileDescriptor?.createIOChannel()

                                    // Use shared error pipe instead of discarded
                                    let errorWriteFileDescriptor = createIODescriptor(from: sharedErrorPipe.writeEnd, closeWhenDone: false)
                                    var errorWriteEnd: IOChannel? = errorWriteFileDescriptor.createIOChannel()

                                    let result: (UInt32, Output.OutputType) = try await withThrowingTaskGroup(of: (UInt32, OutputCapturingState<Output.OutputType, ()>?).self) { group in
                                        // FIXME figure out how to propagate a preferred buffer size to this sequence
                                        let inSequence = AsyncBufferSequence(diskIO: inputReadEnd.take()!.consumeIOChannel(), preferredBufferSize: nil)
                                        let outWriter = StandardInputWriter(diskIO: outputWriteEnd.take()!)
                                        let errWriter = StandardInputWriter(diskIO: errorWriteEnd.take()!)

                                        let outputReadFileDescriptor = outputPipe.readFileDescriptor()
                                        var outputReadEnd = outputReadFileDescriptor?.createIOChannel()
                                        group.addTask {
                                            let readEnd = outputReadEnd.take()
                                            let stdout = try await self.output.captureOutput(from: readEnd)
                                            return (0, .standardOutputCaptured(stdout))
                                        }

                                        group.addTask {
                                            do {
                                                let retVal = try await function(inSequence, outWriter, errWriter)
                                                try await outWriter.finish()
                                                try await errWriter.finish()
                                                return (retVal, .none)
                                            } catch {
                                                try await outWriter.finish()
                                                try await errWriter.finish()
                                                throw error
                                            }
                                        }

                                        var exitCode: UInt32 = 0
                                        var output: Output.OutputType? = nil
                                        for try await r in group {
                                            if r.0 != 0 {
                                                exitCode = r.0
                                            }

                                            if case (_, .standardOutputCaptured(let stdout)) = r {
                                                output = stdout
                                            }
                                        }

                                        return (exitCode, output!)
                                    }

                                    return PipelineTaskResult.success(
                                        lastIndex,
                                        SendableCollectedResult(
                                            CollectedResult<Output, DiscardedOutput>(
                                                processIdentifier: currentProcessIdentifier(),
                                                terminationStatus: createTerminationStatus(result.0),
                                                standardOutput: result.1,
                                                standardError: ()
                                            )))
                                }
                            } catch {
                                return PipelineTaskResult.failure(lastIndex, error)
                            }
                        }
                    }

                    // Collect all results
                    var errors: [Swift.Error] = []
                    var lastStageResult: SendableCollectedResult?

                    for try await result in group {
                        switch result {
                        case .success(let index, let collectedResult):
                            if index == stages.count - 1 {
                                // This is the final stage result we want to return
                                lastStageResult = collectedResult
                            }
                        case .failure(_, let error):
                            errors.append(error)
                        }
                    }

                    // Close the shared error pipe now that all processes have finished so that
                    // the standard error can be collected.
                    try sharedErrorPipe.writeEnd.close()

                    if !errors.isEmpty {
                        throw errors[0] // Throw the first error
                    }

                    guard let lastResult = lastStageResult else {
                        throw SubprocessError(code: .init(.asyncIOFailed("Pipeline execution failed")), underlyingError: nil)
                    }

                    // Create a properly typed CollectedResult from the SendableCollectedResult with shared error
                    return CollectedResult(
                        processIdentifier: lastResult.processIdentifier,
                        terminationStatus: lastResult.terminationStatus,
                        standardOutput: lastResult.standardOutput as! Output.OutputType,
                        standardError: ()
                    )
                }

                return .collectedResult(pipeResult)
            }

            var stderr: Error.OutputType?
            var collectedResult: CollectedResult<Output, DiscardedOutput>?

            for try await result in group {
                switch result {
                case .collectedResult(let pipeResult):
                    collectedResult = pipeResult
                case .stderr(let err):
                    stderr = err
                }
            }

            return CollectedResult<Output, Error>(
                processIdentifier: collectedResult!.processIdentifier,
                terminationStatus: collectedResult!.terminationStatus,
                standardOutput: collectedResult!.standardOutput,
                standardError: stderr!
            )
        }
    }
}

// MARK: - Top-Level Pipe Functions (Return Stage Arrays)

/// Create a single-stage pipeline with an executable
public func pipe(
    executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    options: ProcessStageOptions = .default
) -> [PipeStage] {
    return [
        PipeStage(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions,
            options: options
        )
    ]
}

/// Create a single-stage pipeline with a Configuration
public func pipe(
    _ configuration: Configuration,
    options: ProcessStageOptions = .default
) -> [PipeStage] {
    return [PipeStage(configuration: configuration, options: options)]
}

/// Create a single-stage pipeline with a Swift function
public func pipe(
    swiftFunction: @escaping @Sendable (AsyncBufferSequence, StandardInputWriter, StandardInputWriter) async throws -> UInt32
) -> [PipeStage] {
    return [PipeStage(swiftFunction: swiftFunction)]
}

// MARK: - Stage Array Operators

/// Pipe operator for stage arrays - adds a process stage
public func | (
    left: [PipeStage],
    right: PipeStage
) -> [PipeStage] {
    return left + [right]
}

/// Pipe operator for stage arrays with Configuration
public func | (
    left: [PipeStage],
    right: Configuration
) -> [PipeStage] {
    return left + [PipeStage(configuration: right, options: .default)]
}

/// Pipe operator for stage arrays with simple executable
public func | (
    left: [PipeStage],
    right: Executable
) -> [PipeStage] {
    let configuration = Configuration(executable: right)
    return left + [PipeStage(configuration: configuration, options: .default)]
}

/// Pipe operator for stage arrays with Swift function
public func | (
    left: [PipeStage],
    right: @escaping @Sendable (AsyncBufferSequence, StandardInputWriter, StandardInputWriter) async throws -> UInt32
) -> [PipeStage] {
    return left + [PipeStage(swiftFunction: right)]
}

/// Pipe operator for stage arrays with process helper
public func | (
    left: [PipeStage],
    right: (configuration: Configuration, options: ProcessStageOptions)
) -> [PipeStage] {
    return left + [PipeStage(configuration: right.configuration, options: right.options)]
}

// MARK: - Finally Methods for Stage Arrays (Extension)

extension Array where Element == PipeStage {
    /// Create a PipeConfiguration from stages with specific input, output, and error types
    public func finally<FinalInput: InputProtocol, FinalOutput: OutputProtocol, FinalError: OutputProtocol>(
        input: FinalInput,
        output: FinalOutput,
        error: FinalError
    ) -> PipeConfiguration<FinalInput, FinalOutput, FinalError> {
        return PipeConfiguration<FinalInput, FinalOutput, FinalError>(
            stages: self,
            input: input,
            output: output,
            error: error
        )
    }

    /// Create a PipeConfiguration from stages with no input and specific output and error types
    public func finally<FinalOutput: OutputProtocol, FinalError: OutputProtocol>(
        output: FinalOutput,
        error: FinalError
    ) -> PipeConfiguration<NoInput, FinalOutput, FinalError> {
        return self.finally(input: NoInput(), output: output, error: error)
    }

    /// Create a PipeConfiguration from stages with no input, specific output, and discarded error
    public func finally<FinalOutput: OutputProtocol>(
        output: FinalOutput
    ) -> PipeConfiguration<NoInput, FinalOutput, DiscardedOutput> {
        return self.finally(input: NoInput(), output: output, error: DiscardedOutput())
    }
}

/// Final pipe operator for stage arrays with specific input, output and error types
public func |> <FinalInput: InputProtocol, FinalOutput: OutputProtocol, FinalError: OutputProtocol>(
    left: [PipeStage],
    right: (input: FinalInput, output: FinalOutput, error: FinalError)
) -> PipeConfiguration<FinalInput, FinalOutput, FinalError> {
    return left.finally(input: right.input, output: right.output, error: right.error)
}

/// Final pipe operator for stage arrays with specific output and error types
public func |> <FinalOutput: OutputProtocol, FinalError: OutputProtocol>(
    left: [PipeStage],
    right: (output: FinalOutput, error: FinalError)
) -> PipeConfiguration<NoInput, FinalOutput, FinalError> {
    return left.finally(output: right.output, error: right.error)
}

/// Final pipe operator for stage arrays with specific output only (discarded error)
public func |> <FinalOutput: OutputProtocol>(
    left: [PipeStage],
    right: FinalOutput
) -> PipeConfiguration<NoInput, FinalOutput, DiscardedOutput> {
    return left.finally(output: right)
}

// MARK: - Helper Functions

/// Helper function to create a process stage for piping
public func process(
    executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    options: ProcessStageOptions = .default
) -> PipeStage {
    return PipeStage(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions,
        options: options
    )
}

/// Helper function to create a configuration with options for piping
public func withOptions(
    configuration: Configuration,
    options: ProcessStageOptions
) -> PipeStage {
    return PipeStage(configuration: configuration, options: options)
}

/// Helper function to create a Swift function wrapper for readability
public func swiftFunction(_ function: @escaping @Sendable (AsyncBufferSequence, StandardInputWriter, StandardInputWriter) async throws -> Int32) -> @Sendable (AsyncBufferSequence, StandardInputWriter, StandardInputWriter) async throws -> Int32 {
    return function
}
