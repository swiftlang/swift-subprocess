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
/// - Returns: a `CollectedResult` containing the result of the run.
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
) async throws(SubprocessError) -> CollectedResult<Output, Error> {
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
/// - Returns: a CollectedResult containing the result of the run.
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
) async throws(SubprocessError) -> CollectedResult<Output, Error> {
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
/// to manage the running subprocess’ lifetime.
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
public func run<Result, Input: InputProtocol, Output: OutputProtocol, Error: ErrorOutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: Output = .discarded,
    error: Error = .discarded,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Error.OutputType == Void {
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
public func run<Result, Input: InputProtocol, Error: ErrorOutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    error: Error = .discarded,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Error.OutputType == Void {
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
public func run<Result, Input: InputProtocol, Output: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: Output,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Output.OutputType == Void {
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
public func run<Result, Error: ErrorOutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    error: Error = .discarded,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Error.OutputType == Void {
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
public func run<Result, Output: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    output: Output,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Output.OutputType == Void {
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
/// to manage the running subprocess’ lifetime, write to its
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
) async throws(SubprocessError) -> ExecutionResult<Result> {
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
/// a `CollectedResult` containing the output of the child process.
/// - Parameters:
///   - configuration: The configuration to run.
///   - input: span to write to subprocess' standard input.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns a CollectedResult containing the result of the run.
public func run<
    InputElement: BitwiseCopyable,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ configuration: Configuration,
    input: borrowing Span<InputElement>,
    output: Output,
    error: Error = .discarded
) async throws(SubprocessError) -> CollectedResult<Output, Error> {
    typealias RunResult = (
        processIdentifier: ProcessIdentifier,
        standardOutput: Output.OutputType,
        standardError: Error.OutputType
    )

    let customInput = CustomWriteInput()
    let result = try await configuration.run(
        input: try customInput.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { (execution, inputIO, outputIO, errorIO) throws(SubprocessError) in
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

        do {
            let capturedOutput = try await stdout
            let capturedError = try await stderr

            return (
                processIdentifier: execution.processIdentifier,
                standardOutput: capturedOutput,
                standardError: capturedError
            )
        } catch {
            // https://github.com/swiftlang/swift/issues/76169
            // Async let does not preserve typed throw
            throw error as! SubprocessError
        }

    }

    return CollectedResult(
        processIdentifier: result.value.processIdentifier,
        terminationStatus: result.terminationStatus,
        standardOutput: result.value.standardOutput,
        standardError: result.value.standardError
    )
}
#endif

/// Run a `Configuration` asynchronously and returns
/// a `CollectedResult` containing the output of the child process.
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns: a `CollectedResult` containing the result of the run.
public func run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: ErrorOutputProtocol
>(
    _ configuration: Configuration,
    input: Input = .none,
    output: Output,
    error: Error = .discarded
) async throws(SubprocessError) -> CollectedResult<Output, Error> {
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
    ) { (execution, inputIO, outputIO, errorIO) throws(SubprocessError) -> RunResult in
        // Write input, capture output and error in parallel
        var inputIOBox: IOChannel? = consume inputIO
        var outputIOBox: IOChannel? = consume outputIO
        var errorIOBox: IOChannel? = consume errorIO
        return try await _castError {
            return try await withThrowingTaskGroup(
                of: OutputCapturingState<Output.OutputType, Error.OutputType>?.self,
                returning: RunResult.self
            ) { group throws in
                var inputIOContainer: IOChannel? = inputIOBox.take()
                var outputIOContainer: IOChannel? = outputIOBox.take()
                var errorIOContainer: IOChannel? = errorIOBox.take()
                group.addTask { () throws(SubprocessError) -> OutputCapturingState<Output.OutputType, Error.OutputType>? in
                    if let writeFd = inputIOContainer.take() {
                        let writer = StandardInputWriter(diskIO: writeFd)
                        try await input.write(with: writer)
                        try await writer.finish()
                    }
                    return nil
                }
                group.addTask { () throws(SubprocessError) -> OutputCapturingState<Output.OutputType, Error.OutputType>? in
                    let stdout = try await output.captureOutput(
                        from: outputIOContainer.take()
                    )
                    return .standardOutputCaptured(stdout)
                }
                group.addTask { () throws(SubprocessError) -> OutputCapturingState<Output.OutputType, Error.OutputType>? in
                    let stderr = try await error.captureOutput(
                        from: errorIOContainer.take()
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
                    case .none:
                        continue
                    }
                }

                return (
                    processIdentifier: execution.processIdentifier,
                    standardOutput: stdout,
                    standardError: stderror
                )
            }
        }
    }

    return CollectedResult(
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
public func run<Result, Input: InputProtocol, Output: OutputProtocol, Error: ErrorOutputProtocol>(
    _ configuration: Configuration,
    input: Input = .none,
    output: Output = .discarded,
    error: Error = .discarded,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Error.OutputType == Void {
    let inputPipe = try input.createPipe()
    let outputPipe = try output.createPipe()
    let errorPipe = try error.createPipe(from: outputPipe)
    return try await configuration.run(
        input: inputPipe,
        output: outputPipe,
        error: errorPipe
    ) { (execution, inputIO, outputIO, errorIO) throws(SubprocessError) in
        var inputIOBox: IOChannel? = consume inputIO
        return try await _castError {
            return try await withThrowingTaskGroup(
                of: Void.self,
                returning: Result.self
            ) { group throws(SubprocessError) in
                var inputIOContainer: IOChannel? = inputIOBox.take()
                group.addTask {
                    if let inputIO = inputIOContainer.take() {
                        let writer = StandardInputWriter(diskIO: inputIO)
                        try await input.write(with: writer)
                        try await writer.finish()
                    }
                }

                // Body runs in the same isolation
                do {
                    let result = try await body(execution)
                    try await group.waitForAll()
                    return result
                } catch {
                    throw SubprocessError(
                        code: .init(.executionBodyThrewError),
                        underlyingError: error
                    )
                }
            }
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
public func run<Result, Input: InputProtocol, Error: ErrorOutputProtocol>(
    _ configuration: Configuration,
    input: Input = .none,
    error: Error = .discarded,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Error.OutputType == Void {
    let output = SequenceOutput()
    let inputPipe = try input.createPipe()
    let outputPipe = try output.createPipe()
    let errorPipe = try error.createPipe(from: outputPipe)
    return try await configuration.run(
        input: inputPipe,
        output: outputPipe,
        error: errorPipe
    ) { (execution, inputIO, outputIO, errorIO) throws(SubprocessError) in
        var inputIOBox: IOChannel? = consume inputIO
        var outputIOBox: IOChannel? = consume outputIO
        return try await _castError {
            return try await withThrowingTaskGroup(
                of: Void.self,
                returning: Result.self
            ) { group throws(SubprocessError) in
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
                do {
                    let result = try await body(execution, outputSequence)
                    try await group.waitForAll()
                    return result
                } catch {
                    throw SubprocessError(
                        code: .init(.executionBodyThrewError),
                        underlyingError: error
                    )
                }
            }
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
public func run<Result, Input: InputProtocol, Output: OutputProtocol>(
    _ configuration: Configuration,
    input: Input = .none,
    output: Output,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Output.OutputType == Void {
    let error = SequenceOutput()
    return try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { (execution, inputIO, outputIO, errorIO) throws(SubprocessError) in
        var inputIOBox: IOChannel? = consume inputIO
        var errorIOBox: IOChannel? = consume errorIO
        return try await _castError {
            return try await withThrowingTaskGroup(
                of: Void.self,
                returning: Result.self
            ) { group throws(SubprocessError) in
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
                do {
                    let result = try await body(execution, errorSequence)
                    try await group.waitForAll()
                    return result
                } catch {
                    throw SubprocessError(
                        code: .init(.executionBodyThrewError),
                        underlyingError: error
                    )
                }
            }
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
public func run<Result, Error: ErrorOutputProtocol>(
    _ configuration: Configuration,
    error: Error = .discarded,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Error.OutputType == Void {
    let input = CustomWriteInput()
    let output = SequenceOutput()
    let inputPipe = try input.createPipe()
    let outputPipe = try output.createPipe()
    let errorPipe = try error.createPipe(from: outputPipe)
    return try await configuration.run(
        input: inputPipe,
        output: outputPipe,
        error: errorPipe
    ) { (execution, inputIO, outputIO, errorIO) throws(SubprocessError) in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let outputSequence = AsyncBufferSequence(
            diskIO: outputIO!.consumeIOChannel(),
            preferredBufferSize: preferredBufferSize
        )
        do {
            return try await body(execution, writer, outputSequence)
        } catch {
            throw SubprocessError(
                code: .init(.executionBodyThrewError),
                underlyingError: error
            )
        }
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
public func run<Result, Output: OutputProtocol>(
    _ configuration: Configuration,
    output: Output,
    preferredBufferSize: Int? = nil,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> where Output.OutputType == Void {
    let input = CustomWriteInput()
    let error = SequenceOutput()
    return try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { (execution, inputIO, outputIO, errorIO) throws(SubprocessError) in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let errorSequence = AsyncBufferSequence(
            diskIO: errorIO!.consumeIOChannel(),
            preferredBufferSize: preferredBufferSize
        )
        do {
            return try await body(execution, writer, errorSequence)
        } catch {
            throw SubprocessError(
                code: .init(.executionBodyThrewError),
                underlyingError: error
            )
        }
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
    body: ((Execution, StandardInputWriter, AsyncBufferSequence, AsyncBufferSequence) async throws -> Result)
) async throws(SubprocessError) -> ExecutionResult<Result> {
    let input = CustomWriteInput()
    let output = SequenceOutput()
    let error = SequenceOutput()
    return try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { (execution, inputIO, outputIO, errorIO) throws(SubprocessError) in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let outputSequence = AsyncBufferSequence(
            diskIO: outputIO!.consumeIOChannel(),
            preferredBufferSize: preferredBufferSize
        )
        let errorSequence = AsyncBufferSequence(
            diskIO: errorIO!.consumeIOChannel(),
            preferredBufferSize: preferredBufferSize
        )
        do {
            return try await body(execution, writer, outputSequence, errorSequence)
        } catch {
            throw SubprocessError(
                code: .init(.executionBodyThrewError),
                underlyingError: error
            )
        }
    }
}
