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

/// Run a executable with given parameters asynchrously and returns
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
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
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
    output: Output = .string,
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

/// Run a executable with given parameters asynchrously and returns
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
@available(SubprocessSpan, *)
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
    output: Output = .string,
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
        var inputIOBox: TrackedPlatformDiskIO? = consume inputIO
        var outputIOBox: TrackedPlatformDiskIO? = consume outputIO
        var errorIOBox: TrackedPlatformDiskIO? = consume errorIO

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

/// Run a executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and its IOs.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: The input to send to the executable.
///   - output: How to manage the executable standard ouput.
///   - error: How to manager executable standard error.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns a ExecutableResult type containing the return value
///     of the closure.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
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
        var inputIOBox: TrackedPlatformDiskIO? = consume inputIO
        var outputIOBox: TrackedPlatformDiskIO? = consume outputIO
        return try await withThrowingTaskGroup(
            of: Void.self,
            returning: Result.self
        ) { group in
            var inputIOContainer: TrackedPlatformDiskIO? = inputIOBox.take()
            group.addTask {
                if let inputIO = inputIOContainer.take() {
                    let writer = StandardInputWriter(diskIO: inputIO)
                    try await input.write(with: writer)
                    try await writer.finish()
                }
            }

            // Body runs in the same isolation
            let outputSequence = AsyncBufferSequence(diskIO: outputIOBox.take()!.consumeDiskIO())
            let result = try await body(execution, outputSequence)
            try await group.waitForAll()
            return result
        }
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
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
        var inputIOBox: TrackedPlatformDiskIO? = consume inputIO
        var errorIOBox: TrackedPlatformDiskIO? = consume errorIO
        return try await withThrowingTaskGroup(
            of: Void.self,
            returning: Result.self
        ) { group in
            var inputIOContainer: TrackedPlatformDiskIO? = inputIOBox.take()
            group.addTask {
                if let inputIO = inputIOContainer.take() {
                    let writer = StandardInputWriter(diskIO: inputIO)
                    try await input.write(with: writer)
                    try await writer.finish()
                }
            }

            // Body runs in the same isolation
            let errorSequence = AsyncBufferSequence(diskIO: errorIOBox.take()!.consumeDiskIO())
            let result = try await body(execution, errorSequence)
            try await group.waitForAll()
            return result
        }
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
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
        let outputSequence = AsyncBufferSequence(diskIO: outputIO!.consumeDiskIO())
        return try await body(execution, writer, outputSequence)
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
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
        let errorSequence = AsyncBufferSequence(diskIO: errorIO!.consumeDiskIO())
        return try await body(execution, writer, errorSequence)
    }
}

/// Run a executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and write to its
/// standard input via `StandardInputWriter`
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - output:How to handle executable's standard output
///   - error: How to handle executable's standard error
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns a ExecutableResult type containing the return value
///     of the closure.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
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
        let outputSequence = AsyncBufferSequence(diskIO: outputIO!.consumeDiskIO())
        let errorSequence = AsyncBufferSequence(diskIO: errorIO!.consumeDiskIO())
        return try await body(execution, writer, outputSequence, errorSequence)
    }
}

// MARK: - Configuration Based

/// Run a `Configuration` asynchrously and returns
/// a `CollectedResult` containing the output of the child process.
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns a CollectedResult containing the result of the run.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public func run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: OutputProtocol
>(
    _ configuration: Configuration,
    input: Input = .none,
    output: Output = .string,
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
        var inputIOBox: TrackedPlatformDiskIO? = consume inputIO
        var outputIOBox: TrackedPlatformDiskIO? = consume outputIO
        var errorIOBox: TrackedPlatformDiskIO? = consume errorIO
        return try await withThrowingTaskGroup(
            of: OutputCapturingState<Output.OutputType, Error.OutputType>?.self,
            returning: RunResult.self
        ) { group in
            var inputIOContainer: TrackedPlatformDiskIO? = inputIOBox.take()
            var outputIOContainer: TrackedPlatformDiskIO? = outputIOBox.take()
            var errorIOContainer: TrackedPlatformDiskIO? = errorIOBox.take()
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

/// Run a executable with given parameters specified by a `Configuration`
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom configuration body to manually control
///       the running process and write to its standard input.
/// - Returns a ExecutableResult type containing the return value
///     of the closure.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
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
        let outputSequence = AsyncBufferSequence(diskIO: outputIO!.consumeDiskIO())
        let errorSequence = AsyncBufferSequence(diskIO: errorIO!.consumeDiskIO())
        return try await body(execution, writer, outputSequence, errorSequence)
    }
}

// MARK: - Detached

/// Run a executable with given parameters and return its process
/// identifier immediately without monitoring the state of the
/// subprocess nor waiting until it exits.
///
/// This method is useful for launching subprocesses that outlive their
/// parents (for example, daemons and trampolines).
///
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment to use for the process.
///   - workingDirectory: The working directory for the process.
///   - platformOptions: The platform specific options to use for the process.
///   - input: A file descriptor to bind to the subprocess' standard input.
///   - output: A file descriptor to bind to the subprocess' standard output.
///   - error: A file descriptor to bind to the subprocess' standard error.
/// - Returns: the process identifier for the subprocess.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public func runDetached(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: FileDescriptor? = nil,
    output: FileDescriptor? = nil,
    error: FileDescriptor? = nil
) throws -> ProcessIdentifier {
    let config: Configuration = Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    return try runDetached(config, input: input, output: output, error: error)
}

/// Run a executable with given configuration and return its process
/// identifier immediately without monitoring the state of the
/// subprocess nor waiting until it exits.
///
/// This method is useful for launching subprocesses that outlive their
/// parents (for example, daemons and trampolines).
///
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - input: A file descriptor to bind to the subprocess' standard input.
///   - output: A file descriptor to bind to the subprocess' standard output.
///   - error: A file descriptor to bind to the subprocess' standard error.
/// - Returns: the process identifier for the subprocess.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public func runDetached(
    _ configuration: Configuration,
    input: FileDescriptor? = nil,
    output: FileDescriptor? = nil,
    error: FileDescriptor? = nil
) throws -> ProcessIdentifier {
    switch (input, output, error) {
    case (.none, .none, .none):
        let processInput = NoInput()
        let processOutput = DiscardedOutput()
        let processError = DiscardedOutput()
        return try configuration.spawn(
            withInput: try processInput.createPipe(),
            outputPipe: try processOutput.createPipe(),
            errorPipe: try processError.createPipe()
        ).execution.processIdentifier
    case (.none, .none, .some(let errorFd)):
        let processInput = NoInput()
        let processOutput = DiscardedOutput()
        let processError = FileDescriptorOutput(
            fileDescriptor: errorFd,
            closeAfterSpawningProcess: false
        )
        return try configuration.spawn(
            withInput: try processInput.createPipe(),
            outputPipe: try processOutput.createPipe(),
            errorPipe: try processError.createPipe()
        ).execution.processIdentifier
    case (.none, .some(let outputFd), .none):
        let processInput = NoInput()
        let processOutput = FileDescriptorOutput(
            fileDescriptor: outputFd, closeAfterSpawningProcess: false
        )
        let processError = DiscardedOutput()
        return try configuration.spawn(
            withInput: try processInput.createPipe(),
            outputPipe: try processOutput.createPipe(),
            errorPipe: try processError.createPipe()
        ).execution.processIdentifier
    case (.none, .some(let outputFd), .some(let errorFd)):
        let processInput = NoInput()
        let processOutput = FileDescriptorOutput(
            fileDescriptor: outputFd,
            closeAfterSpawningProcess: false
        )
        let processError = FileDescriptorOutput(
            fileDescriptor: errorFd,
            closeAfterSpawningProcess: false
        )
        return try configuration.spawn(
            withInput: try processInput.createPipe(),
            outputPipe: try processOutput.createPipe(),
            errorPipe: try processError.createPipe()
        ).execution.processIdentifier
    case (.some(let inputFd), .none, .none):
        let processInput = FileDescriptorInput(
            fileDescriptor: inputFd,
            closeAfterSpawningProcess: false
        )
        let processOutput = DiscardedOutput()
        let processError = DiscardedOutput()
        return try configuration.spawn(
            withInput: try processInput.createPipe(),
            outputPipe: try processOutput.createPipe(),
            errorPipe: try processError.createPipe()
        ).execution.processIdentifier
    case (.some(let inputFd), .none, .some(let errorFd)):
        let processInput = FileDescriptorInput(
            fileDescriptor: inputFd, closeAfterSpawningProcess: false
        )
        let processOutput = DiscardedOutput()
        let processError = FileDescriptorOutput(
            fileDescriptor: errorFd,
            closeAfterSpawningProcess: false
        )
        return try configuration.spawn(
            withInput: try processInput.createPipe(),
            outputPipe: try processOutput.createPipe(),
            errorPipe: try processError.createPipe()
        ).execution.processIdentifier
    case (.some(let inputFd), .some(let outputFd), .none):
        let processInput = FileDescriptorInput(
            fileDescriptor: inputFd,
            closeAfterSpawningProcess: false
        )
        let processOutput = FileDescriptorOutput(
            fileDescriptor: outputFd,
            closeAfterSpawningProcess: false
        )
        let processError = DiscardedOutput()
        return try configuration.spawn(
            withInput: try processInput.createPipe(),
            outputPipe: try processOutput.createPipe(),
            errorPipe: try processError.createPipe()
        ).execution.processIdentifier
    case (.some(let inputFd), .some(let outputFd), .some(let errorFd)):
        let processInput = FileDescriptorInput(
            fileDescriptor: inputFd,
            closeAfterSpawningProcess: false
        )
        let processOutput = FileDescriptorOutput(
            fileDescriptor: outputFd,
            closeAfterSpawningProcess: false
        )
        let processError = FileDescriptorOutput(
            fileDescriptor: errorFd,
            closeAfterSpawningProcess: false
        )
        return try configuration.spawn(
            withInput: try processInput.createPipe(),
            outputPipe: try processOutput.createPipe(),
            errorPipe: try processError.createPipe()
        ).execution.processIdentifier
    }
}

