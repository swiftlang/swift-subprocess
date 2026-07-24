# Streaming output and providing input

Stream the output of a subprocess as it arrives and feed it input, while following
the one rule that keeps pipes from deadlocking.

## Overview

The function that launches a subprocess, `run`, comes in two forms.
The collecting form waits for the subprocess to exit and hands you all its output at once.
The streaming form takes a trailing closure so you can process output while the subprocess runs.
You choose whether you stream or collect results by passing the appropriate options to the `output` and `error` parameters.
This article covers the streaming form; for collecting, see <doc:GettingStarted>.

Reach for streaming when, for example:

- Reading each line of a long-running subprocess as it becomes available.
- Handling output that's too large to hold in memory.
- Providing input to the subprocess while it runs.

The streaming API gives you live streams, which come with one rule: **don't block pipes.**

> Warning: A subprocess can't finish while a pipe it depends on is stuck.
>
> Drain every output stream you open — concurrently, when you open more than one — and close standard input once you're done writing to it.

### Stream output as it arrives

To stream, pass ``SequenceOutput/sequence`` as the output with ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:body:)``.

Inside the trailing closure, the
``Execution`` value provides the output as an asynchronous sequence.
The following example illustrates reading the output line by line:

```swift
import Subprocess

_ = try await run(
    .name("swift"),
    arguments: ["build"],
    input: .none,
    output: .sequence,
    error: .discarded
) { execution in
    for try await line in execution.standardOutput.strings() {
        print(line)
    }
}
```

The preceding example has no default parameters.
Unlike the collecting `run`, this streaming form requires you to state `input`, `output`, and `error` on every call.
The ``SubprocessOutputSequence/strings(separatedBy:bufferingPolicy:)`` method yields one `String` per line,
with the line separator removed.
It recognizes the common separators, so you get text without splitting bytes yourself.
This call opens a single output stream and drains it in the loop, while the input pipe is `.none` and the error pipe is ``OutputProtocol/discarded``, so it follows the rule to drain every output pipe.

### Understand the closure scope

The trailing closure on `run` is how the library guarantees that the subprocess lives only
as long as the `run` call.
The closure runs concurrently with the live subprocess: while your code reads output inside the body, the process is still running.
The function `run` returns only after the body returns and the process exits.
Because of that, the `execution` value, its streams, and the input writer are valid only inside the body.

### Drain every stream, concurrently

Standard output and standard error are separate pipes.
A process writes to both, and each pipe holds only so much data before a write to it blocks — on Linux, for example, about 64 KB.
If you read one pipe to completion while never reading the other, the process eventually blocks
writing to the pipe you ignored — so it never exits, and `run` never returns.
This isn't a rare edge case: a command whose output fits the buffer today can cross it as that output grows, and then it hangs with no change to your code.
Reading the two pipes one after another has the same problem, because “after” never arrives when the first pipe blocks.

Read both streams concurrently by giving each its own child task
so neither waits on the other:

```swift
_ = try await run(
    .name("swift"),
    arguments: ["build"],
    input: .none,
    output: .sequence,
    error: .sequence
) { execution in
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for try await line in execution.standardOutput.strings() {
                print("out:", line)
            }
        }
        group.addTask {
            for try await line in execution.standardError.strings() {
                print("err:", line)
            }
        }
        try await group.waitForAll()
    }
}
```

If you've used Python's `subprocess` and `communicate()` after a program
hung on `wait()` with `PIPE`, this is the same kind of issue and the same shape of fix:
consume every pipe concurrently instead of in sequence.

### Provide input

Input has three tiers of choices; reach for the simplest one that does the job:

- For no input, ``InputProtocol/none`` (the default) points standard input at the null device.
- For a value you already have, pass ``InputProtocol/string(_:)``, ``InputProtocol/array(_:)``, or ``InputProtocol/data(_:)``.
- For input you produce over time, pass ``InputProtocol/inputWriter`` and write from the closure.

When the input is a value in hand, pass it directly and use the collected form.
No closure is needed, and the `error` parameter defaults to `.discarded`.
Use ``InputProtocol/string(_:)``, ``InputProtocol/array(_:)`` for `[UInt8]`, or ``InputProtocol/data(_:)`` for Foundation `Data`.
The following example provides a static string as input:

```swift
let result = try await run(
    .name("wc"),
    arguments: ["-l"],
    input: .string("one\ntwo\n"),
    output: .string(limit: 4096)
)
print(result.standardOutput)   // the line count
```

To write input as the process runs, pass
``InputProtocol/inputWriter`` and use the closure form of `run`: ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:body:)``.
The ``Execution`` that the closure provides gives you a ``StandardInputWriter``.
Each `write` sends its bytes immediately, and the return value is the number of bytes written.
You can discard the count with `_ =` if you don't need it:

```swift
let result = try await run(
    .name("cat"),
    input: .inputWriter,
    output: .string(limit: 4096),
    error: .discarded
) { execution in
    let writer = execution.standardInputWriter
    _ = try await writer.write("one\ntwo\nthree\n")
    try await writer.finish()
}
print(result.standardOutput)
```

When you use this form to write input, call ``StandardInputWriter/finish()`` after your last write.

Calling `finish` closes the input stream so the subprocess sees end-of-file.
Many programs don't produce their final output — or exit at all — until they do.
A missing `finish()` may show up as a hung process.
`run` calls it for you when the body closure returns,
or call it yourself when you need to close the input stream sooner,
such as when you await the process's full output inside the body.

Don't hold on to the writer past the body.
Once the closure returns, `run` finishes it, and a later write throws a ``SubprocessError``.

### Write and read at the same time

Some programs interleave both input and output, such as the encoding tool `base64`.
They read some input, emit some output, and repeat.

Writing all the input before you start reading can fill the output pipe and block the subprocess mid-write, causing a deadlock.
To avoid that, write and read with concurrent tasks:

```swift
_ = try await run(
    .name("base64"),
    input: .inputWriter,
    output: .sequence,
    error: .discarded
) { execution in
    let writer = execution.standardInputWriter
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            _ = try await writer.write("Hello, world.\n")
            try await writer.finish()
        }
        group.addTask {
            for try await line in execution.standardOutput.strings() {
                print(line)
            }
        }
        try await group.waitForAll()
    }
}
```

The same structure can chain two subprocesses, sending the stream of output from one subprocess to the input of another.
This is the equivalent of `ls | sort` in a shell.
To chain together the subprocesses, invoke the second subprocess with `run` using a closure, and inside it run the first,
forwarding each output buffer's bytes to the second's writer while a sibling task drains
the second's output:

```swift
_ = try await run(
    .name("sort"),
    input: .inputWriter,
    output: .sequence,
    error: .discarded
) { sort in
    let writer = sort.standardInputWriter
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            _ = try await run(
                .name("ls"),
                input: .none,
                output: .sequence,
                error: .discarded
            ) { ls in
                for try await chunk in ls.standardOutput {
                    _ = try await writer.write(chunk.bytes)
                }
            }
            try await writer.finish()
        }
        group.addTask {
            for try await line in sort.standardOutput.strings() {
                print(line)
            }
        }
        try await group.waitForAll()
    }
}
```

Iterating `standardOutput` yields ``SubprocessOutputSequence/Buffer`` values rather than decoded text.
Passing each buffer's ``SubprocessOutputSequence/Buffer/bytes`` — a `RawSpan` view — to the writer forwards the data with no intermediate array copy.

Both subprocesses are alive at once — the outer `run` for `sort` doesn't return
until its body does — and every pipe has a task draining it.

### Use files and inherited standard I/O

Not every stream has to flow through your process.
You can point the input or output of a subprocess at a file descriptor directly with
``FileDescriptorInput/fileDescriptor(_:closeAfterSpawningProcess:)`` and
``FileDescriptorOutput/fileDescriptor(_:closeAfterSpawningProcess:)``,
which is efficient for large amounts of data.
When you use a file descriptor, the bytes never pass through your code.

You can also let the subprocess share your process's own terminal, for example:

```swift
_ = try await run(
    .name("less"),
    arguments: ["Package.swift"],
    input: .currentStandardInput,
    output: .currentStandardOutput,
    error: .currentStandardError
)
```
