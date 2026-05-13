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
public import System
#else
public import SystemPackage
#endif

// MARK: - Collected Result

/// Runs an executable asynchronously and returns the collected output
/// of the child process.
///
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
/// - Returns: An ``ExecutionResult`` that contains the result of the run.
public func run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: Output,
    error: Error = .discarded
) async throws -> ExecutionResult<Void, Output, Error> {
    let configuration = Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    return try await run(
        configuration,
        input: input,
        output: output,
        error: error
    )
}

/// Runs an executable asynchronously and returns the collected output
/// of the child process.
///
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: A span to write to the subprocess's standard input.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
/// - Returns: An ``ExecutionResult`` that contains the result of the run.
public func run<
    InputElement: BitwiseCopyable,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: borrowing Span<InputElement>,
    output: Output,
    error: Error = .discarded
) async throws -> ExecutionResult<Void, Output, Error> {
    let configuration = Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    return try await run(
        configuration,
        input: input,
        output: output,
        error: error
    )
}

// MARK: - Custom Execution Body

/// Runs an executable asynchronously and lets a closure manage the running subprocess.
///
/// Use this overload when you need to interact with the subprocess while it runs,
/// such as streaming its standard output, writing to its standard input, or sending
/// signals. The closure runs concurrently with the subprocess and receives an
/// ``Execution`` value you can use to access these capabilities.
///
/// The subprocess must terminate before this method returns.
///
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
///   - body: A closure that manages the running subprocess. The closure receives
///     an ``Execution`` value that's valid only for the duration of the call.
///     Don't let the execution value escape the closure.
/// - Returns: An ``ExecutionResult`` that contains the closure's return value and
///   the termination status of the child process.
public func run<
    Result,
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input,
    output: Output,
    error: Error,
    body: (
        Execution<Input, Output, Error>
    ) async throws -> Result
) async throws -> ExecutionResult<Result, Output, Error> {
    let configuration = Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    return try await run(
        configuration,
        input: input,
        output: output,
        error: error,
        body: body
    )
}

// MARK: - Configuration Based

/// Runs a configuration asynchronously and returns an ``ExecutionResult`` that
/// contains the output of the child process.
///
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: A span to write to the subprocess's standard input.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
/// - Returns: An ``ExecutionResult`` that contains the result of the run.
public func run<
    InputElement: BitwiseCopyable,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ configuration: Configuration,
    input: borrowing Span<InputElement>,
    output: Output,
    error: Error = .discarded
) async throws -> ExecutionResult<Void, Output, Error> {
    let inputMethod = CustomWriteInput()
    return try await run(
        configuration,
        input: inputMethod,
        output: output,
        error: error
    ) { execution in
        _ = try await execution.standardInputWriter.write(input._bytes)
        try await execution.standardInputWriter.finish()
    }
}

/// Runs a ``Configuration`` asynchronously and returns
/// an ``ExecutionResult`` that contains the output of the child process.
///
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
/// - Returns: An ``ExecutionResult`` that contains the result of the run.
public func run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ configuration: Configuration,
    input: Input = .none,
    output: Output,
    error: Error = .discarded
) async throws -> ExecutionResult<Void, Output, Error> {
    return try await run(configuration, input: input, output: output, error: error) { _ in
        return () as Void
    }
}

/// Runs a ``Configuration`` asynchronously and lets a closure manage the running
/// subprocess.
///
/// Use this overload when you need to interact with the subprocess while it runs,
/// such as streaming its standard output, writing to its standard input, or sending
/// signals. The closure runs concurrently with the subprocess and receives an
/// ``Execution`` value you can use to access these capabilities.
///
/// The subprocess must terminate before this method returns.
///
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
///   - body: A closure that manages the running subprocess. The closure receives
///     an ``Execution`` value that's valid only for the duration of the call.
///     Don't let the execution value escape the closure.
/// - Returns: An ``ExecutionResult`` that contains the closure's return value and
///   the termination status of the child process.
public func run<
    Result,
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ configuration: Configuration,
    input: Input,
    output: Output,
    error: Error,
    body: (
        Execution<Input, Output, Error>
    ) async throws -> Result
) async throws -> ExecutionResult<Result, Output, Error> {
    typealias RunResult = (
        processIdentifier: ProcessIdentifier,
        closureResult: Result,
        output: Output.OutputType,
        error: Error.OutputType
    )

    let outputPipe = try output.createPipe()
    let errorPipe = try error.createPipe(from: outputPipe)
    let result: ExecutionOutcome<RunResult> = try await configuration.run(
        input: try input.createPipe(),
        as: Input.self,
        output: outputPipe,
        as: Output.self,
        error: errorPipe,
        as: Error.self
    ) { processIdentifier, inputIO, outputIO, errorIO in
        var inputIOBox = consume inputIO
        var outputIOBox = consume outputIO
        var errorIOBox = consume errorIO

        return try await withThrowingTaskGroup(of: _RunGroupResult<Output, Error>.self) { group in
            var writer: StandardInputWriter?
            if inputIOBox != nil {
                let inputWriter = StandardInputWriter(diskIO: inputIOBox.take()!)
                writer = inputWriter

                if Input.self != CustomWriteInput.self {
                    // Write non-custom inputs in a parallel task.
                    group.addTask {
                        try await input.write(with: inputWriter)
                        try await inputWriter.finish()
                        return .inputWritten
                    }
                }
            }

            var outputSequence: AsyncBufferSequence? = nil
            var errorSequence: AsyncBufferSequence? = nil
            // Capture output and error in parallel
            if Output.self == SequenceOutput.self {
                var diskIO = outputIOBox.take()
                outputSequence = AsyncBufferSequence(
                    diskIO: diskIO!.consumeDescriptor()
                )
            } else if Output.OutputType.self == Void.self {
                // No need to capture output
                var diskIO = outputIOBox.take()
                try diskIO?.safelyClose()
            } else {
                var diskIO = outputIOBox.take()
                group.addTask {
                    let result = try await output.captureOutput(from: diskIO.take())
                    return .standardOutputCaptured(result)
                }
            }

            if Error.self == SequenceOutput.self {
                var diskIO = errorIOBox.take()
                errorSequence = AsyncBufferSequence(
                    diskIO: diskIO!.consumeDescriptor()
                )
            } else if Error.OutputType.self == Void.self {
                // No need to capture error
                var diskIO = errorIOBox.take()
                try diskIO?.safelyClose()
            } else {
                var diskIO = errorIOBox.take()
                group.addTask {
                    let result = try await error.captureOutput(from: diskIO.take())
                    return .standardErrorCaptured(result)
                }
            }

            let execution = Execution<Input, Output, Error>(
                processIdentifier: processIdentifier,
                inputWriter: writer,
                outputStream: outputSequence,
                errorStream: errorSequence
            )
            let result: Result
            do {
                result = try await body(execution)
            } catch {
                if Input.self == CustomWriteInput.self {
                    try await writer?.finish()
                }
                throw error
            }
            if Input.self == CustomWriteInput.self {
                try await writer?.finish()
            }

            var capturedOutput: Output.OutputType?
            var capturedError: Error.OutputType?
            while let groupResult = try await group.next() {
                switch groupResult {
                case .inputWritten:
                    continue
                case .standardOutputCaptured(let output):
                    capturedOutput = output
                case .standardErrorCaptured(let error):
                    capturedError = error
                }
            }
            if Output.OutputType.self == Void.self {
                capturedOutput = (() as Any) as? Output.OutputType
            }
            if Error.OutputType.self == Void.self {
                capturedError = (() as Any) as? Error.OutputType
            }
            return (processIdentifier, result, capturedOutput!, capturedError!)
        }
    }

    return ExecutionResult(
        processIdentifier: result.value.processIdentifier,
        terminationStatus: result.terminationStatus,
        closureOutput: result.value.closureResult,
        standardOutput: result.value.output,
        standardError: result.value.error
    )
}

private enum _RunGroupResult<Output: OutputProtocol, Error: OutputProtocol> {
    case standardOutputCaptured(Output.OutputType)
    case standardErrorCaptured(Error.OutputType)
    case inputWritten
}
