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

// MARK: - Collected Result

/// Run an executable with given parameters asynchronously and return a
/// collected result that contains the output of the child process.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns: a `ExecutionRecord` containing the result of the run.
public func run<
    Input: InputProtocol,
    Output: Sendable,
    Error: Sendable
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: OutputMethod<Output>,
    error: ErrorOutputMethod<Error> = .discarded
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

#if SubprocessSpan
/// Run an executable with given parameters asynchronously and return a
/// collected result that contains the output of the child process.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: span to write to subprocess' standard input.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns: a ExecutionRecord containing the result of the run.
public func run<
    InputElement: BitwiseCopyable,
    Output: Sendable,
    Error: Sendable
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: borrowing Span<InputElement>,
    output: OutputMethod<Output>,
    error: ErrorOutputMethod<Error> = .discarded
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
#endif // SubprocessSpan

// MARK: - Custom Execution Body

/// Run an executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - output: How to manage executable standard output.
///   - error: How to manage executable standard error.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns: an `ExecutableResult` type containing the return value of the closure.
public func run<
    Result,
    Input: InputProtocol
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: OutputMethod<Void> = .discarded,
    error: ErrorOutputMethod<Void> = .discarded,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution) async throws -> Result)
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
        output: output,
        error: error,
        isolation: isolation,
        body: body
    )
}

/// Run an executable with given parameters and a custom closure to manage the
/// running subprocess' lifetime and stream its standard output.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform-specific options to use when running the executable.
///   - input: The input to send to the executable.
///   - error: How to manage executable standard error.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process.
/// - Returns: an `ExecutableResult` type containing the return value of the closure.
public func run<Result, Input: InputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    error: ErrorOutputMethod<Void> = .discarded,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
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
        error: error,
        preferredBufferSize: preferredBufferSize,
        isolation: isolation,
        body: body
    )
}

/// Run an executable with given parameters and a custom closure to manage the
/// running subprocess' lifetime and stream its standard error.
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
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns: an `ExecutableResult` type containing the return value of the closure.
public func run<Result, Input: InputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: OutputMethod<Void>,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
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
        output: output,
        preferredBufferSize: preferredBufferSize,
        isolation: isolation,
        body: body
    )
}

/// Run an executable with given parameters and a custom closure to manage the
/// running subprocess' lifetime, write to its standard input, and stream its standard output.
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
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns: An `ExecutableResult` type containing the return value of the closure.
public func run<Result>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    error: ErrorOutputMethod<Void> = .discarded,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
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
        error: error,
        preferredBufferSize: preferredBufferSize,
        isolation: isolation,
        body: body
    )
}

/// Run an executable with given parameters and a custom closure to manage the
/// running subprocess' lifetime, write to its standard input, and stream its standard error.
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
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns: An `ExecutableResult` type containing the return value of the closure.
public func run<Result>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    output: OutputMethod<Void>,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
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
        output: output,
        preferredBufferSize: preferredBufferSize,
        isolation: isolation,
        body: body
    )
}

/// Run an executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime, write to its
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
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns: an `ExecutableResult` type containing the return value of the closure.
public func run<Result>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: (
        (
            Execution,
            StandardInputWriter,
            AsyncBufferSequence,
            AsyncBufferSequence
        ) async throws -> Result
    )
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
        isolation: isolation,
        body: body
    )
}

// MARK: - Configuration Based

#if SubprocessSpan
/// Run an executable with given configuration asynchronously and returns
/// a `ExecutionRecord` containing the output of the child process.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: span to write to subprocess' standard input.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns a ExecutionRecord containing the result of the run.
public func run<
    InputElement: BitwiseCopyable,
    Output: Sendable,
    Error: Sendable
>(
    _ configuration: Configuration,
    input: borrowing Span<InputElement>,
    output: OutputMethod<Output>,
    error: ErrorOutputMethod<Error> = .discarded
) async throws -> ExecutionRecord<Output, Error> {
    typealias RunResult = (
        processIdentifier: ProcessIdentifier,
        standardOutput: Output,
        standardError: Error
    )

    let customInput = CustomWriteInput()
    let outputPipe = try output._createPipe()
    let errorPipe = try error._createPipe(outputPipe)

    let result = try await configuration.run(
        input: try customInput.createPipe(),
        output: outputPipe,
        error: errorPipe,
    ) { execution, inputIO, outputIO, errorIO in
        var inputIOBox: IOChannel? = consume inputIO
        var outputIOBox: IOChannel? = consume outputIO
        var errorIOBox: IOChannel? = consume errorIO

        // Write input, capture output and error in parallel
        async let stdout = try output._captureOutput(outputIOBox.take())
        async let stderr = try error._captureOutput(errorIOBox.take())
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
#endif

/// Run a `Configuration` asynchronously and returns
/// a `ExecutionRecord` containing the output of the child process.
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns: a `ExecutionRecord` containing the result of the run.
public func run<
    Input: InputProtocol,
    Output: Sendable,
    Error: Sendable
>(
    _ configuration: Configuration,
    input: Input = .none,
    output: OutputMethod<Output>,
    error: ErrorOutputMethod<Error> = .discarded
) async throws -> ExecutionRecord<Output, Error> {
    typealias RunResult = (
        processIdentifier: ProcessIdentifier,
        standardOutput: Output,
        standardError: Error
    )
    let inputPipe = try input.createPipe()
    let outputPipe = try output._createPipe()
    let errorPipe = try error._createPipe(outputPipe)

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
            of: OutputCapturingState<Output, Error>?.self,
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
                let stdout = try await output._captureOutput(
                    outputIOContainer.take()
                )
                return .standardOutputCaptured(stdout)
            }
            group.addTask {
                let stderr = try await error._captureOutput(
                    errorIOContainer.take()
                )
                return .standardErrorCaptured(stderr)
            }

            do {
                var stdout: Output!
                var stderror: Error!
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

/// Run an executable with given `Configuration` and a custom closure
/// to manage the running subprocess' lifetime.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - output: How to manager executable standard output.
///   - error: How to manager executable standard error.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<
    Result,
    Input: InputProtocol
>(
    _ configuration: Configuration,
    input: Input = .none,
    output: OutputMethod<Void> = .discarded,
    error: ErrorOutputMethod<Void> = .discarded,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution) async throws -> Result)
) async throws -> ExecutionOutcome<Result> {
    let inputPipe = try input.createPipe()
    let outputPipe = try output._createPipe()
    let errorPipe = try error._createPipe(outputPipe)

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

/// Run an executable with given `Configuration` and a custom closure
/// to manage the running subprocess' lifetime and stream its standard output.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - error: How to manager executable standard error.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard output stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<
    Result,
    Input: InputProtocol
>(
    _ configuration: Configuration,
    input: Input = .none,
    error: ErrorOutputMethod<Void> = .discarded,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionOutcome<Result> {
    let outputPipe = try CreatedPipe(closeWhenDone: true, purpose: .output)
    let inputPipe = try input.createPipe()
    let errorPipe = try error._createPipe(outputPipe)

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

/// Run an executable with given `Configuration` and a custom closure
/// to manage the running subprocess' lifetime and stream its standard error.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: The input to send to the executable.
///   - output: How to manager executable standard output.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result, Input: InputProtocol>(
    _ configuration: Configuration,
    input: Input = .none,
    output: OutputMethod<Void>,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionOutcome<Result> {
    let outputPipe = try output._createPipe()
    let errorPipe = try CreatedPipe(closeWhenDone: true, purpose: .output)

    return try await configuration.run(
        input: try input.createPipe(),
        output: outputPipe,
        error: errorPipe,
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

/// Run an executable with given `Configuration` and a custom closure
/// to manage the running subprocess' lifetime, write to its
/// standard input, and stream its standard output.
/// - Parameters:
///   - configuration: The `Configuration` to run.
///   - error: How to manager executable standard error.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard output stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result>(
    _ configuration: Configuration,
    error: ErrorOutputMethod<Void> = .discarded,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionOutcome<Result> {
    let input = CustomWriteInput()
    let outputPipe = try CreatedPipe(closeWhenDone: true, purpose: .output)
    let inputPipe = try input.createPipe()
    let errorPipe = try error._createPipe(outputPipe)

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

/// Run an executable with given `Configuration` and a custom closure
/// to manage the running subprocess' lifetime, write to its
/// standard input, and stream its standard error.
/// - Parameters:
///   - configuration: The `Configuration` to run.
///   - output: How to manager executable standard output.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result>(
    _ configuration: Configuration,
    output: OutputMethod<Void>,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionOutcome<Result> {
    let input = CustomWriteInput()
    let errorPipe = try CreatedPipe(closeWhenDone: true, purpose: .output)

    return try await configuration.run(
        input: try input.createPipe(),
        output: try output._createPipe(),
        error: errorPipe,
    ) { execution, inputIO, outputIO, errorIO in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let errorSequence = AsyncBufferSequence(
            diskIO: errorIO!.consumeIOChannel(),
            preferredBufferSize: preferredBufferSize
        )
        return try await body(execution, writer, errorSequence)
    }
}

/// Run an executable with given parameters specified by a `Configuration`
/// and a custom closure to manage the running subprocess' lifetime, write to its
/// standard input, and stream its standard output and standard error.
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - preferredBufferSize: The preferred size in bytes for the buffer used when reading
///     from the subprocess's standard output and error stream. If `nil`, uses the system page size
///     as the default buffer size. Larger buffer sizes may improve performance for
///     subprocesses that produce large amounts of output, while smaller buffer sizes
///     may reduce memory usage and improve responsiveness for interactive applications.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom configuration body to manually control
///       the running process, write to its standard input, stream
///       the standard output and standard error.
/// - Returns: an `ExecutableResult` type containing the return value of the closure.
public func run<Result>(
    _ configuration: Configuration,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: (
        (
            Execution,
            StandardInputWriter,
            _ output: AsyncBufferSequence,
            _ error: AsyncBufferSequence
        ) async throws -> Result
    )
) async throws -> ExecutionOutcome<Result> {
    let input = CustomWriteInput()
    let outputPipe = try CreatedPipe(closeWhenDone: true, purpose: .output)
    let errorPipe = try CreatedPipe(closeWhenDone: true, purpose: .output)

    return try await configuration.run(
        input: try input.createPipe(),
        output: outputPipe,
        error: errorPipe
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
