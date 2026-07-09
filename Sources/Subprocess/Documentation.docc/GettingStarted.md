# Getting started with Subprocess

Run a command, collect its output, and see how input, output,
and process lifetime fit together.

## Overview

Running a subprocess takes the input you provide, and you control how its output and error are collected or streamed.
Depending on the command, a subprocess might produce output, error output, both, or neither.
Subprocess lets you handle each of these cases independently.

You can either collect or stream the output.
Collecting waits for the subprocess to finish and hands you the result.
Streaming lets you read output while the subprocess is still running.

Subprocess encloses the lifetime of the process you run within the `run` call.
When `run` returns, the process is complete and cleaned up.

### Run a command and read its output

Import the package, identify what to run and possibly its arguments,
specify how to collect its output, and await the result:

```swift
import Subprocess

let result = try await run(
    .name("ls"),
    arguments: ["-la"],
    output: .string(limit: 4096)
)
print(result.standardOutput)
```

The preceding example uses ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:)-(_,_,_,_,_,Input,_,_)``:

- The `output` parameter is required.
  The example uses `.string(limit:)` to collect standard output as a string (`String`) no longer than 4096 bytes.
- The `limit` parameter is a byte count, not a character count, and Subprocess applies it before decoding.
  There's no default limit — you always specify one, because a reasonable ceiling depends entirely on the command you run, anywhere from a few bytes to many megabytes.
  Treat the limit as a ceiling, not a truncation: output that fits today can grow past it tomorrow, and when it does, `run` throws ``SubprocessError`` rather than silently handing you a partial result you might mistake for the whole.
- The `input` parameter defaults to `.none` and the `error` parameter defaults to `.discarded`.

### Name the command and its arguments

The first parameter is an ``Executable`` that you can specify in one of two ways:

- ``Executable/name(_:)`` — `.name("ls")` looks the command up using the `PATH`
  environment variable, the way a shell finds it.
- ``Executable/path(_:)`` — `.path("/bin/ls")` runs the command at an exact
  location and skips the search.

Arguments are a separate ``Arguments`` value that you can write as an array literal.
Each element is one argument, passed to the command exactly as written:

```swift
let result = try await run(
    .name("git"),
    arguments: ["commit", "-m", "a message with spaces"],
    output: .string(limit: 16 * 1024)
)
```

Subprocess doesn't run a shell, so there's no quoting to get right and no
shell expansion or injection to guard against.
The string `"a message with spaces"` arrives as a single argument, with spaces.

### Set input, output, and error independently

Each of the `input`, `output`, and `error` parameters is independent, and each has its own type.
Input conforms to ``InputProtocol``, and output and error conform to ``OutputProtocol``.
In the following example, `run` collects standard output as a large string and standard error as a smaller one:

```swift
let result = try await run(
    .name("swift"),
    arguments: ["build"],
    output: .string(limit: 2 * 1024 * 1024),
    error: .string(limit: 512 * 1024)
)
```

To keep the output and error together instead — the equivalent of using `2>&1` in a shell — pass ``ErrorOutputProtocol/combinedWithOutput`` as the error.
This merges standard error into standard output.
Only the `error:` line changes:

```swift
let result = try await run(
    .name("swift"),
    arguments: ["build"],
    output: .string(limit: 2 * 1024 * 1024),
    error: .combinedWithOutput
)
```

The examples in this article wait for the process to complete and collect the output.
This approach fits a short-lived subprocess whose output fits in memory, when you want the result after it exits.

The alternative, when a subprocess is long-running or its output is large or open-ended, and you want to act on output before it exits, is to use ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:body:)``.
This `run` takes a trailing closure in which you iterate over the output as it arrives.
For more detail on how to use streaming output, see <doc:StreamingAndInput>.

### Read what you get back

A collecting `run` returns an ``ExecutionResult``, which includes:

- `standardOutput` and `standardError`, typed by the choices you made — a
  `String` for `.string(limit:)`, a `[UInt8]` for `.bytes(limit:)`, and so on.
- ``TerminationStatus`` — how the process ended.
- ``ProcessIdentifier`` — the process's identifier.

A command that ran and failed is a normal result, not an error.
`run` doesn't throw when a command exits with a non-zero code.
Use the termination status to understand how the process completed:

```swift
switch result.terminationStatus {
case .exited(0):
    print("succeeded")
case .exited(let code):
    print("exited with code \(code)")
case .signaled(let signal):
    print("stopped by signal \(signal)")
}
```

For a simple pass-or-fail check, ``TerminationStatus/isSuccess`` collapses that
to a Boolean. The `signaled` case exists only on platforms that report
signals; on Windows, every command ends as `exited`.

`run` does throw when provided a command that can't start,
for example, when ``Executable/name(_:)`` finds nothing in `PATH`.
As mentioned earlier, `run` also throws ``SubprocessError`` if the output exceeds a limit.

### Understand the process lifetime

A subprocess is scoped to its `run` call.
`run` returns only after the process has exited and its output is collected,
so by the time you hold an ``ExecutionResult``, no live process remains.

Processing streaming input and output, as described in <doc:StreamingAndInput>, keeps this guarantee.
Its trailing closure runs while the process is alive, and `run` returns only after the process exits.
