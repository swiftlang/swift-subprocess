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

/// Run an executable with given parameters asynchronously and returns
/// a `CollectedResult` containing the output of the child process.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns a CollectedResult containing the result of the run.
public func run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: OutputProtocol
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: Output,
    error: Error = .discarded
) async throws -> CollectedResult<Output, Error> {
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

/// Run an executable with given parameters asynchronously and returns
/// a `CollectedResult` containing the output of the child process.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: span to write to subprocess' standard input.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns a CollectedResult containing the result of the run.
#if SubprocessSpan
public func run<
    InputElement: BitwiseCopyable,
    Output: OutputProtocol,
    Error: OutputProtocol
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: borrowing Span<InputElement>,
    output: Output,
    error: Error = .discarded
) async throws -> CollectedResult<Output, Error> {
    typealias RunResult = (
        processIdentifier: ProcessIdentifier,
        standardOutput: Output.OutputType,
        standardError: Error.OutputType
    )

    let customInput = CustomWriteInput()
    let result = try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    ).run(
        input: try customInput.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
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

    return CollectedResult(
        processIdentifier: result.value.processIdentifier,
        terminationStatus: result.terminationStatus,
        standardOutput: result.value.standardOutput,
        standardError: result.value.standardError
    )
}
#endif  // SubprocessSpan


// MARK: - Custom Execution Body

/// Run an executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and stream its standard output.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: The input to send to the executable.
///   - output: How to manager executable standard output.
///   - error: How to manager executable standard error.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result, Input: InputProtocol, Output: OutputProtocol, Error: OutputProtocol>(
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
) async throws -> ExecutionResult<Result> where Error.OutputType == Void {
    return try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    ).run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
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

/// Run an executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and stream its standard output.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: The input to send to the executable.
///   - error: How to manager executable standard error.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result, Input: InputProtocol, Error: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    error: Error = .discarded,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionResult<Result> where Error.OutputType == Void {
    let output = SequenceOutput()
    return try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    ).run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
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
            let outputSequence = AsyncBufferSequence(diskIO: outputIOBox.take()!.consumeIOChannel())
            let result = try await body(execution, outputSequence)
            try await group.waitForAll()
            return result
        }
    }
}

/// Run an executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and stream its standard error.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: The input to send to the executable.
///   - output: How to manager executable standard output.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result, Input: InputProtocol, Output: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: Output,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionResult<Result> where Output.OutputType == Void {
    let error = SequenceOutput()
    return try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    ).run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
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
            let errorSequence = AsyncBufferSequence(diskIO: errorIOBox.take()!.consumeIOChannel())
            let result = try await body(execution, errorSequence)
            try await group.waitForAll()
            return result
        }
    }
}

/// Run an executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime, write to its
/// standard input, and stream its standard output.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - error: How to manager executable standard error.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result, Error: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    error: Error = .discarded,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionResult<Result> where Error.OutputType == Void {
    let input = CustomWriteInput()
    let output = SequenceOutput()
    return try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    .run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { execution, inputIO, outputIO, errorIO in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let outputSequence = AsyncBufferSequence(diskIO: outputIO!.consumeIOChannel())
        return try await body(execution, writer, outputSequence)
    }
}

/// Run an executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime, write to its
/// standard input, and stream its standard error.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - output: How to manager executable standard output.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result, Output: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    output: Output,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionResult<Result> where Output.OutputType == Void {
    let input = CustomWriteInput()
    let error = SequenceOutput()
    return try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    .run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { execution, inputIO, outputIO, errorIO in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let errorSequence = AsyncBufferSequence(diskIO: errorIO!.consumeIOChannel())
        return try await body(execution, writer, errorSequence)
    }
}

/// Run an executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime, write to its
/// standard input, and stream its standard output and standard error.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    isolation: isolated (any Actor)? = #isolation,
    body: (
        (
            Execution,
            StandardInputWriter,
            AsyncBufferSequence,
            AsyncBufferSequence
        ) async throws -> Result
    )
) async throws -> ExecutionResult<Result> {
    let configuration = Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    let input = CustomWriteInput()
    let output = SequenceOutput()
    let error = SequenceOutput()

    return try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { execution, inputIO, outputIO, errorIO in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let outputSequence = AsyncBufferSequence(diskIO: outputIO!.consumeIOChannel())
        let errorSequence = AsyncBufferSequence(diskIO: errorIO!.consumeIOChannel())
        return try await body(execution, writer, outputSequence, errorSequence)
    }
}

// MARK: - Configuration Based

/// Run a `Configuration` asynchronously and returns
/// a `CollectedResult` containing the output of the child process.
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns a CollectedResult containing the result of the run.
public func run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: OutputProtocol
>(
    _ configuration: Configuration,
    input: Input = .none,
    output: Output,
    error: Error = .discarded
) async throws -> CollectedResult<Output, Error> {
    typealias RunResult = (
        processIdentifier: ProcessIdentifier,
        standardOutput: Output.OutputType,
        standardError: Error.OutputType
    )
    let result = try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { (execution, inputIO, outputIO, errorIO) -> RunResult in
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

    return CollectedResult(
        processIdentifier: result.value.processIdentifier,
        terminationStatus: result.terminationStatus,
        standardOutput: result.value.standardOutput,
        standardError: result.value.standardError
    )
}

/// Run an executable with given parameters specified by a `Configuration`
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom configuration body to manually control
///       the running process, write to its standard input, stream
///       its standard output and standard error.
/// - Returns an executableResult type containing the return value
///     of the closure.
public func run<Result>(
    _ configuration: Configuration,
    isolation: isolated (any Actor)? = #isolation,
    body: ((Execution, StandardInputWriter, AsyncBufferSequence, AsyncBufferSequence) async throws -> Result)
) async throws -> ExecutionResult<Result> {
    let input = CustomWriteInput()
    let output = SequenceOutput()
    let error = SequenceOutput()
    return try await configuration.run(
        input: try input.createPipe(),
        output: try output.createPipe(),
        error: try error.createPipe()
    ) { execution, inputIO, outputIO, errorIO in
        let writer = StandardInputWriter(diskIO: inputIO!)
        let outputSequence = AsyncBufferSequence(diskIO: outputIO!.consumeIOChannel())
        let errorSequence = AsyncBufferSequence(diskIO: errorIO!.consumeIOChannel())
        return try await body(execution, writer, outputSequence, errorSequence)
    }
}
