# Getting started with Subprocess

Run a command, collect its output, and see how input, output,
and process lifetime fit together.

## Overview

Running a subprocess takes the input you provide, and you control how its output and error are collected or streamed.
Depending on the command, a subprocess might produce output, error output, both, or neither.
Subprocess lets you handle each of these cases independently.

The function that launches a subprocess, `run`, comes in two forms:
* The *collecting* form waits for the subprocess to finish and provides the result.
* The *streaming* form lets you read output while the subprocess runs.

You choose between them depending on whether you pass a trailing closure.
This article covers the collecting form; for streaming, see <doc:StreamingAndInput>.

Subprocess encloses the lifetime of the process you run within the `run` call.
When `run` returns, the process is complete and cleaned up.

### Run a command and read its output

To run a subprocess, import the `Subprocess` framework and call a flavor of the `run` function, identifying what to run, any arguments to use, and how to handle its output.
You `await` this call, which means that the subprocess execution is finished when the code resumes.
The following snippet shows an example of executing the `ls -la` command as a subprocess:

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

Take note of the following behaviors in this example:

Take note of the following behaviors in this example:

- The `output` parameter is required.
  The example uses `.string(limit:)` to collect standard output as a string (`String`) no longer than 4096 bytes.
- The `limit` parameter is a byte count, not a character count, and Subprocess applies it before decoding.
  There's no default limit — you always specify one, because a reasonable ceiling depends entirely on the command you run, anywhere from a few bytes to many megabytes.
  Treat the limit as a ceiling, not a truncation: output that fits today can grow past it tomorrow, and when it does, `run` throws ``SubprocessError`` rather than silently handing you a partial result you might mistake for the whole.
- The `input` parameter defaults to `.none` and the `error` parameter defaults to `.discarded`.

### Name the command and its arguments

The first parameter to `run` is an ``Executable`` that you can specify in one of two ways:

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

A collecting `run` returns an ``ExecutionResult`` that carries everything the finished process produced:

| Property | Type | What it holds |
| --- | --- | --- |
| `standardOutput` | Matches your `output:` choice | The collected standard output |
| `standardError` | Matches your `error:` choice | The collected standard error |
| `terminationStatus` | ``TerminationStatus`` | How the process ended |
| `processIdentifier` | ``ProcessIdentifier`` | The identifier of the process that ran |

The types of `standardOutput` and `standardError` follow the collection method you chose for each stream:

| Collection method | Result type |
| --- | --- |
| `.string(limit:)` | `String` |
| `.bytes(limit:)` | `[UInt8]` |
| ``OutputProtocol/discarded`` | `Void` (nothing collected) |

Both `.string(limit:)` and `.bytes(limit:)` take a required `limit` — a byte count with no default, applied before decoding.
Use `.bytes(limit:)` when the output isn't text, such as an image or an archive.

In the common case, a command runs, succeeds, and hands you its output, which you read from the result:

```swift
let result = try await run(
    .name("git"),
    arguments: ["rev-parse", "HEAD"],
    output: .string(limit: 4096)
)
print(result.standardOutput)   // the commit hash
```

### Detect failure

Around a subprocess, the word “error” pulls in three directions.
Keeping them apart is the difference between handling a real problem and misreading a healthy result as a broken one.
Throughout the Subprocess documentation:

- A **Swift error** is a value thrown out of `run` that you handle with `do`/`catch`. Subprocess reserves this for problems it can't express as a result: a broken setup or environment, or a body closure of your own that throws.
- A **command failure** is a subprocess that ran to completion but exited with a non-zero code. This is reported by the ``ExecutionResult/terminationStatus`` of the ``ExecutionResult``, not a Swift error.
- **Standard error output** is bytes the command wrote to its standard error stream. Many programs write progress or diagnostics there while succeeding, so it's ordinary output you collect through the `error:` parameter — not a signal that anything went wrong.

`run` doesn't throw a Swift error when a command exits with a non-zero code.
A command that ran and failed is a normal result; inspect its ``TerminationStatus`` to see how it ended:

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

For a simple pass-or-fail check, ``TerminationStatus/isSuccess`` collapses that to a Boolean.
The `signaled` case exists only on platforms that report signals; on Windows, every command ends as `exited`.

`run` throws a Swift error in only two situations:

- It throws a ``SubprocessError`` for a problem with the setup or environment — for example, when ``Executable/name(_:)`` finds nothing in `PATH`, or when the collected output exceeds the `limit` you specified.
- It rethrows any error your own body closure throws, in the streaming form described in <doc:StreamingAndInput>.

Because a command failure isn't a Swift error, you handle the two concerns in different places — `do`/`catch` for a process that couldn't run, and ``TerminationStatus/isSuccess`` for one that ran and failed:

```swift
do {
    let result = try await run(
        .name("git"),
        arguments: ["status"],
        output: .string(limit: 64 * 1024)
    )
    if result.terminationStatus.isSuccess {
        print(result.standardOutput)
    } else {
        print("git reported failure")
    }
} catch {
    // A Swift error: git wasn't found, or the output exceeded the limit.
    print("couldn't run git: \(error)")
}
```

> Note: A non-zero exit never surfaces as a Swift error, and neither does output on standard error. 
> To run a `catch` block when a command “fails,” check ``TerminationStatus/isSuccess`` yourself and throw from your own code.

### Understand the process lifetime

A subprocess is scoped to its `run` call.
`run` returns only after the process has exited and its output is collected,
so by the time you hold an ``ExecutionResult``, no live process remains.

Processing streaming input and output, as described in <doc:StreamingAndInput>, keeps this guarantee.
Its trailing closure runs while the process is alive, and `run` returns only after the process exits.
