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
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
/// - Returns: An ``ExecutionRecord`` that contains the result of the run.
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
) async throws -> ExecutionRecord<Output, Error> {
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
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: A span to write to the subprocess's standard input.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
/// - Returns: An ``ExecutionRecord`` that contains the result of the run.
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
) async throws -> ExecutionRecord<Output, Error> {
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

/// Runs an executable with given parameters and a custom closure
/// to manage the running subprocess’s lifetime.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - output: How to manage executable standard output.
///   - error: How to manage executable standard error.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
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
    input: Input = .none,
    output: Output = .discarded,
    error: Error = .discarded,
    body: (_ execution: Execution) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Error.OutputType == Void {
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

/// Runs an executable with given parameters and a custom closure to manage the
/// running subprocess's lifetime and stream its standard output.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - error: How to manage executable standard error.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard output stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - outputSequence: The standard output as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result, Input: InputProtocol, Error: ErrorOutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    error: Error = .discarded,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ outputSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Error.OutputType == Void {
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
        error: error,
        preferredBufferSize: preferredBufferSize,
        body: body
    )
}

/// Runs an executable with given parameters and a custom closure to manage the
/// running subprocess's lifetime and stream its standard error.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - output: How to manage executable standard output.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - errorSequence: The standard error as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result, Input: InputProtocol, Output: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: Output,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ errorSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Output.OutputType == Void {
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
        preferredBufferSize: preferredBufferSize,
        body: body
    )
}

/// Runs an executable with given parameters and a custom closure to manage the
/// running subprocess's lifetime and stream its standard output and error.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - errorSequence: The standard error as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result, Input: InputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ outputSequence: AsyncBufferSequence,
        _ errorSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> {
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
        preferredBufferSize: preferredBufferSize,
        body: body
    )
}

/// Runs an executable with given parameters and a custom closure to manage the
/// running subprocess's lifetime, write to its standard input, and stream its standard output.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - error: How to manage executable standard error.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard output stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - inputWriter: A writer for the subprocess's standard input.
///     - outputSequence: The standard output as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result, Error: ErrorOutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    error: Error = .discarded,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ inputWriter: StandardInputWriter,
        _ outputSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Error.OutputType == Void {
    let configuration = Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    return try await run(
        configuration,
        error: error,
        preferredBufferSize: preferredBufferSize,
        body: body
    )
}

/// Runs an executable with given parameters and a custom closure to manage the
/// running subprocess's lifetime, write to its standard input, and stream its standard error.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - output: How to manage executable standard output.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - inputWriter: A writer for the subprocess's standard input.
///     - errorSequence: The standard error as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result, Output: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    output: Output,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ inputWriter: StandardInputWriter,
        _ errorSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Output.OutputType == Void {
    let configuration = Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    return try await run(
        configuration,
        output: output,
        preferredBufferSize: preferredBufferSize,
        body: body
    )
}

/// Runs an executable with given parameters and a custom closure
/// to manage the running subprocess’s lifetime, write to its
/// standard input, and stream its standard output and standard error.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard output and error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - inputWriter: A writer for the subprocess's standard input.
///     - outputSequence: The standard output as an asynchronous sequence of buffers.
///     - errorSequence: The standard error as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ inputWriter: StandardInputWriter,
        _ outputSequence: AsyncBufferSequence,
        _ errorSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> {
    let configuration = Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    return try await run(
        configuration,
        preferredBufferSize: preferredBufferSize,
        body: body
    )
}

// MARK: - Configuration Based

/// Runs a configuration asynchronously and returns
/// an ``ExecutionRecord`` that contains the output of the child process.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: A span to write to the subprocess's standard input.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
/// - Returns: An ``ExecutionRecord`` that contains the result of the run.
public func run<
    InputElement: BitwiseCopyable,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ configuration: Configuration,
    input: borrowing Span<InputElement>,
    output: Output,
    error: Error = .discarded
) async throws -> ExecutionRecord<Output, Error> {
    typealias RunResult = (
        processIdentifier: ProcessIdentifier,
        standardOutput: Output.OutputType,
        standardError: Error.OutputType
    )

    let customInput = CustomWriteInput()

    let result = try await configuration.run(
        input: try customInput.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe(),
    ) { execution, inputIO, outputIO, errorIO in
        var inputIOBox: IOChannel? = consume inputIO
        var outputIOBox: IOChannel? = consume outputIO
        var errorIOBox: IOChannel? = consume errorIO

        // Write input, capture output and error in parallel
        async let stdout = try output.captureOutput(from: outputIOBox.take())
        async let stderr = try error.captureOutput(from: errorIOBox.take())
        // Write span at the same isolation
        if let writeFd = inputIOBox.take() {
            let writer = StandardInputWriter(diskIO: writeFd)
            _ = try await writer.write(input._bytes)
            try await writer.finish()
        }

        return (
            processIdentifier: execution.processIdentifier,
            standardOutput: try await stdout,
            standardError: try await stderr
        )
    }

    return ExecutionRecord(
        processIdentifier: result.value.processIdentifier,
        terminationStatus: result.terminationStatus,
        standardOutput: result.value.standardOutput,
        standardError: result.value.standardError
    )
}

/// Runs a ``Configuration`` asynchronously and returns
/// an ``ExecutionRecord`` that contains the output of the child process.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting standard output.
///   - error: The method to use for redirecting standard error.
/// - Returns: An ``ExecutionRecord`` that contains the result of the run.
public func run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ configuration: Configuration,
    input: Input = .none,
    output: Output,
    error: Error = .discarded
) async throws -> ExecutionRecord<Output, Error> {
    typealias RunResult = (
        processIdentifier: ProcessIdentifier,
        standardOutput: Output.OutputType,
        standardError: Error.OutputType
    )
    let inputPipe = try input.createPipe()
    let outputPipe = try output.createPipe()
    let errorPipe = try error.createPipe(from: outputPipe)

    let result = try await configuration.run(
        input: inputPipe,
        output: outputPipe,
        error: errorPipe
    ) { execution, inputIO, outputIO, errorIO in
        // Write input, capture output and error in parallel
        var inputIOBox: IOChannel? = consume inputIO
        var outputIOBox: IOChannel? = consume outputIO
        var errorIOBox: IOChannel? = consume errorIO
        return try await withThrowingTaskGroup(
            of: OutputCapturingState<Output.OutputType, Error.OutputType>?.self,
            returning: RunResult.self
        ) { group in
            var inputIOContainer: IOChannel? = inputIOBox.take()
            var outputIOContainer: IOChannel? = outputIOBox.take()
            var errorIOContainer: IOChannel? = errorIOBox.take()
            group.addTask {
                if let writeFd = inputIOContainer.take() {
                    let writer = StandardInputWriter(diskIO: writeFd)
                    try await input.write(with: writer)
                    try await writer.finish()
                }
                return nil
            }
            group.addTask {
                let stdout = try await output.captureOutput(
                    from: outputIOContainer.take()
                )
                return .standardOutputCaptured(stdout)
            }
            group.addTask {
                let stderr = try await error.captureOutput(
                    from: errorIOContainer.take()
                )
                return .standardErrorCaptured(stderr)
            }

            do {
                var stdout: Output.OutputType!
                var stderror: Error.OutputType!
                while let state = try await group.next() {
                    switch state {
                    case .standardOutputCaptured(let output):
                        stdout = output
                    case .standardErrorCaptured(let error):
                        stderror = error
                    case .none:
                        continue
                    }
                }

                return (
                    processIdentifier: execution.processIdentifier,
                    standardOutput: stdout,
                    standardError: stderror
                )
            } catch {
                if let underlying = error as? SubprocessError.UnderlyingError {
                    throw SubprocessError.asyncIOFailed(
                        reason: "Failed to capture output",
                        underlyingError: underlying
                    )
                }
                throw error
            }
        }
    }

    return ExecutionRecord(
        processIdentifier: result.value.processIdentifier,
        terminationStatus: result.terminationStatus,
        standardOutput: result.value.standardOutput,
        standardError: result.value.standardError
    )
}

/// Runs an executable with a given ``Configuration`` and a custom closure
/// to manage the running subprocess's lifetime.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - output: How to manage executable standard output.
///   - error: How to manage executable standard error.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<
    Result,
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ configuration: Configuration,
    input: Input = .none,
    output: Output = .discarded,
    error: Error = .discarded,
    body: (_ execution: Execution) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Error.OutputType == Void {
    let inputPipe = try input.createPipe()
    let outputPipe = try output.createPipe()
    let errorPipe = try error.createPipe(from: outputPipe)

    return try await configuration.run(
        input: inputPipe,
        output: outputPipe,
        error: errorPipe
    ) { execution, inputIO, outputIO, errorIO in
        var inputIOBox: IOChannel? = consume inputIO
        return try await withThrowingTaskGroup(
            of: Void.self,
            returning: Result.self
        ) { group in
            var inputIOContainer: IOChannel? = inputIOBox.take()
            group.addTask {
                if let inputIO = inputIOContainer.take() {
                    let writer = StandardInputWriter(diskIO: inputIO)
                    try await input.write(with: writer)
                    try await writer.finish()
                }
            }

            // Body runs in the same isolation
            let result = try await body(execution)
            try await group.waitForAll()
            return result
        }
    }
}

/// Runs an executable with a given ``Configuration`` and a custom closure
/// to manage the running subprocess's lifetime and stream its standard output.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - error: How to manage executable standard error.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard output stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - outputSequence: The standard output as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<
    Result,
    Input: InputProtocol,
    Error: ErrorOutputProtocol
>(
    _ configuration: Configuration,
    input: Input = .none,
    error: Error = .discarded,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ outputSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Error.OutputType == Void {
    let output = SequenceOutput()
    let inputPipe = try input.createPipe()
    let outputPipe = try output.createPipe()
    let errorPipe = try error.createPipe(from: outputPipe)

    return try await configuration.run(
        input: inputPipe,
        output: outputPipe,
        error: errorPipe
    ) { execution, inputIO, outputIO, errorIO in
        var inputIOBox: IOChannel? = consume inputIO
        var outputIOBox: IOChannel? = consume outputIO

        return try await withThrowingTaskGroup(
            of: Void.self,
            returning: Result.self
        ) { group in
            var inputIOContainer: IOChannel? = inputIOBox.take()
            group.addTask {
                if let inputIO = inputIOContainer.take() {
                    let writer = StandardInputWriter(diskIO: inputIO)
                    try await input.write(with: writer)
                    try await writer.finish()
                }
            }

            // Body runs in the same isolation
            let outputSequence = AsyncBufferSequence(
                diskIO: outputIOBox.take()!.consumeIOChannel(),
                preferredBufferSize: preferredBufferSize
            )

            let result = try await body(execution, outputSequence)
            try await group.waitForAll()
            return result
        }
    }
}

/// Runs an executable with a given ``Configuration`` and a custom closure
/// to manage the running subprocess's lifetime and stream its standard error.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - output: How to manage executable standard output.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - errorSequence: The standard error as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result, Input: InputProtocol, Output: OutputProtocol>(
    _ configuration: Configuration,
    input: Input = .none,
    output: Output,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ errorSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Output.OutputType == Void {
    let error = SequenceOutput()

    return try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe(),
    ) { execution, inputIO, outputIO, errorIO in
        var inputIOBox: IOChannel? = consume inputIO
        var errorIOBox: IOChannel? = consume errorIO

        return try await withThrowingTaskGroup(
            of: Void.self,
            returning: Result.self
        ) { group in
            var inputIOContainer: IOChannel? = inputIOBox.take()
            group.addTask {
                if let inputIO = inputIOContainer.take() {
                    let writer = StandardInputWriter(diskIO: inputIO)
                    try await input.write(with: writer)
                    try await writer.finish()
                }
            }

            // Body runs in the same isolation
            let errorSequence = AsyncBufferSequence(
                diskIO: errorIOBox.take()!.consumeIOChannel(),
                preferredBufferSize: preferredBufferSize
            )

            let result = try await body(execution, errorSequence)
            try await group.waitForAll()
            return result
        }
    }
}

/// Runs an executable with a given ``Configuration`` and a custom closure
/// to manage the running subprocess's lifetime and stream its standard output and error.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - output: How to manage executable standard output.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - outputSequence: The standard output an asynchronous sequence of buffers.
///     - errorSequence: The standard error as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result, Input: InputProtocol>(
    _ configuration: Configuration,
    input: Input = .none,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ outputSequence: AsyncBufferSequence,
        _ errorSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> {
    let output = SequenceOutput()
    let error = SequenceOutput()

    return try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe(),
    ) { execution, inputIO, outputIO, errorIO in
        var inputIOBox: IOChannel? = consume inputIO
        var outputIOBox: IOChannel? = consume outputIO
        var errorIOBox: IOChannel? = consume errorIO

        return try await withThrowingTaskGroup(
            of: Void.self,
            returning: Result.self
        ) { group in
            var inputIOContainer: IOChannel? = inputIOBox.take()
            group.addTask {
                if let inputIO = inputIOContainer.take() {
                    let writer = StandardInputWriter(diskIO: inputIO)
                    try await input.write(with: writer)
                    try await writer.finish()
                }
            }

            // Body runs in the same isolation
            let outputSequence = AsyncBufferSequence(
                diskIO: outputIOBox.take()!.consumeIOChannel(),
                preferredBufferSize: preferredBufferSize
            )

            let errorSequence = AsyncBufferSequence(
                diskIO: errorIOBox.take()!.consumeIOChannel(),
                preferredBufferSize: preferredBufferSize
            )

            let result = try await body(execution, outputSequence, errorSequence)
            try await group.waitForAll()
            return result
        }
    }
}

/// Runs an executable with a given ``Configuration`` and a custom closure
/// to manage the running subprocess's lifetime, write to its
/// standard input, and stream its standard output.
/// - Parameters:
///   - configuration: The configuration to run.
///   - error: How to manage executable standard error.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard output stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - inputWriter: A writer for the subprocess's standard input.
///     - outputSequence: The standard output as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result, Error: ErrorOutputProtocol>(
    _ configuration: Configuration,
    error: Error = .discarded,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ inputWriter: StandardInputWriter,
        _ outputSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Error.OutputType == Void {
    let input = CustomWriteInput()
    let output = SequenceOutput()
    let inputPipe = try input.createPipe()
    let outputPipe = try output.createPipe()
    let errorPipe = try error.createPipe(from: outputPipe)

    return try await configuration.run(
        input: inputPipe,
        output: outputPipe,
        error: errorPipe
    ) { execution, inputIO, outputIO, errorIO in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let outputSequence = AsyncBufferSequence(
            diskIO: outputIO!.consumeIOChannel(),
            preferredBufferSize: preferredBufferSize
        )

        return try await body(execution, writer, outputSequence)
    }
}

/// Runs an executable with a given ``Configuration`` and a custom closure
/// to manage the running subprocess's lifetime, write to its
/// standard input, and stream its standard error.
/// - Parameters:
///   - configuration: The configuration to run.
///   - output: How to manage executable standard output.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - inputWriter: A writer for the subprocess's standard input.
///     - errorSequence: The standard error as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result, Output: OutputProtocol>(
    _ configuration: Configuration,
    output: Output,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ inputWriter: StandardInputWriter,
        _ errorSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> where Output.OutputType == Void {
    let input = CustomWriteInput()
    let error = SequenceOutput()

    return try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe(),
    ) { execution, inputIO, outputIO, errorIO in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let errorSequence = AsyncBufferSequence(
            diskIO: errorIO!.consumeIOChannel(),
            preferredBufferSize: preferredBufferSize
        )
        return try await body(execution, writer, errorSequence)
    }
}

/// Runs an executable with a given ``Configuration``
/// and a custom closure to manage the running subprocess's lifetime, write to its
/// standard input, and stream its standard output and standard error.
/// - Parameters:
///   - configuration: The configuration to run.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard output and error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: The isolation context to run the body closure.
///   - body: A closure to manage the running process.
///     All arguments passed to this closure are valid only for
///     the duration of the closure's execution and must not be escaped.
///     - execution: The running subprocess.
///     - inputWriter: A writer for the subprocess's standard input.
///     - outputSequence: The standard output as an asynchronous sequence of buffers.
///     - errorSequence: The standard error as an asynchronous sequence of buffers.
/// - Returns: An ``ExecutionOutcome`` that contains the closure's return value.
public func run<Result>(
    _ configuration: Configuration,
    preferredBufferSize: Int? = nil,
    body: (
        _ execution: Execution,
        _ inputWriter: StandardInputWriter,
        _ outputSequence: AsyncBufferSequence,
        _ errorSequence: AsyncBufferSequence
    ) async throws -> Result
) async throws -> ExecutionOutcome<Result> {
    let input = CustomWriteInput()
    let output = SequenceOutput()
    let error = SequenceOutput()

    return try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { execution, inputIO, outputIO, errorIO in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let outputSequence = AsyncBufferSequence(
            diskIO: outputIO!.consumeIOChannel(),
            preferredBufferSize: preferredBufferSize
        )
        let errorSequence = AsyncBufferSequence(
            diskIO: errorIO!.consumeIOChannel(),
            preferredBufferSize: preferredBufferSize
        )
        return try await body(execution, writer, outputSequence, errorSequence)
    }
}
