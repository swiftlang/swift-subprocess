# ``Subprocess``

Subprocess is a cross-platform Swift package for spawning child processes, 
built from the ground up with Swift concurrency.

## Overview

Subprocess centers on a family of `run` functions. Each spawns an executable, 
waits for it to terminate, and returns an ``ExecutionResult`` carrying the 
process identifier, the ``TerminationStatus``, and whatever output you asked it 
to collect. The simplest form runs a command and collects its standard output:

```swift
import Subprocess

let result = try await run(.name("ls"), output: .string(limit: 4096))

print(result.processIdentifier) // e.g. 1234
print(result.terminationStatus) // e.g. exited(0)
print(result.standardOutput)    // e.g. Optional("LICENSE\nPackage.swift\n...")
```

You can run an executable directly, supplying its ``Arguments``, ``Environment``, 
and working directory inline, or build a reusable ``Configuration`` and run that. 
When you need to interact with the process while it runs, use the overloads that 
take a trailing closure: the closure receives an ``Execution`` value you use to 
write to standard input, stream standard output and standard error, and signal 
or tear down the process.

There are three independent parameters for input, output, and errors, so a 
single call can mix collecting and streaming. Input, output, and errors conform 
to ``InputProtocol``, ``OutputProtocol``, or ``ErrorOutputProtocol``, 
respectively.

You can read input from a string, an array, a file descriptor, or, in the 
closure-based API, from the body itself through ``StandardInputWriter``. You 
can collect output as a `String`, a `[UInt8]` array, or `Data`, send it to a 
file descriptor, or stream it. Passing ``CombinedErrorOutput`` for the error 
parameter merges standard error into standard output, the equivalent of the 
shell's `2>&1`.

Streamed output arrives as a ``SubprocessOutputSequence``, an asynchronous 
sequence of buffers you can iterate directly or read line by line. The 
``Execution``, ``SubprocessOutputSequence``, and ``StandardInputWriter`` values 
are valid only for the duration of the body closure; don't let them escape it.

If the task running a subprocess is canceled, Subprocess can run a configurable 
teardown sequence (for example, a graceful shutdown followed by a forced kill) 
before the call returns. You describe that sequence with ``TeardownStep`` values, 
and you can trigger one yourself from the body closure.

Platform-specific settings live on ``PlatformOptions``: user and group 
identifiers and session behavior on Unix, quality of service on Darwin, and 
console and window behavior on Windows. The `SubprocessFoundation` trait is 
enabled by default and adds the `Data`-based input and output types, which 
import Foundation (the system Foundation on Darwin and swift-foundation's 
`FoundationEssentials` elsewhere). Disable the trait to build without that 
dependency.

## Topics

### Running a Subprocess

- ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:)-(_,_,_,_,_,Input,_,_)``
- ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:)-(_,_,_,_,_,Span<InputElement>,_,_)``
- ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:body:)``
- ``run(_:input:output:error:)-(_,Input,_,_)``
- ``run(_:input:output:error:)-(_,Span<InputElement>,_,_)``
- ``run(_:input:output:error:body:)``

### Configuring a Subprocess

- ``Configuration``
- ``Executable``
- ``Arguments``
- ``Environment``
- ``PlatformOptions``

### Providing Input

- ``InputProtocol``
- ``NoInput``
- ``StringInput``
- ``ArrayInput``
- ``FileDescriptorInput``
- ``CustomWriteInput``
- ``StandardInputWriter``
- ``DataInput``
- ``DataSequenceInput``
- ``DataAsyncSequenceInput``

### Collecting Output

- ``OutputProtocol``
- ``DiscardedOutput``
- ``StringOutput``
- ``BytesOutput``
- ``FileDescriptorOutput``
- ``DataOutput``

### Streaming Output

- ``SequenceOutput``
- ``SubprocessOutputSequence``

### Redirecting Standard Error

- ``ErrorOutputProtocol``
- ``CombinedErrorOutput``

### Interacting with a Running Subprocess

- ``Execution``

### Inspecting Results

- ``ExecutionResult``
- ``TerminationStatus``
- ``ProcessIdentifier``

### Terminating a Subprocess

- ``TeardownStep``
- ``Signal``

### Handling Errors

- ``SubprocessError``
