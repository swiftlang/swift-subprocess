# ``Subprocess``

A cross-platform Swift package for launching subprocesses, built from the 
ground up with Swift concurrency.

## Overview

Subprocess centers on a set of `run` functions. Each launches an executable, 
waits for it to terminate, and returns an ``ExecutionResult``. The result 
carries the process identifier, the ``TerminationStatus``, and whatever output 
you asked it to collect. The simplest form runs a command and collects its 
standard output:

```swift
import Subprocess

let result = try await run(.name("ls"), output: .string(limit: 4096))

print(result.processIdentifier) // e.g. 1234
print(result.terminationStatus) // e.g. exited(0)
print(result.standardOutput)    // e.g. Optional("LICENSE\nPackage.swift\n...")
```

You can run an executable directly, supplying its ``Arguments``, ``Environment``, 
and working directory inline, or build a reusable ``Configuration`` to run repeatedly.

To get more detail on how to `run` to invoke a command, wait for it to finish, then provide everything it produced, read <doc:GettingStarted>.
If you're invoking a long running command, a command produces more output than fits into memory, or you want to process what that command produces while it's still running, read <doc:StreamingAndInput>.

Subprocess also handles the concerns that surround a running process:

- **Graceful teardown.** When the task running a subprocess is canceled, 
  Subprocess can run a configurable teardown sequence — for example, a graceful 
  shutdown followed by a forced termination — before the call returns. You 
  describe it with ``TeardownStep`` values.
- **Platform options.** Platform-specific settings live on ``PlatformOptions``: 
  user, group, and session behavior on Unix, quality of service on Darwin, and 
  console and window behavior on Windows.
- **Foundation integration.** The `SubprocessFoundation` trait, enabled by 
  default, adds `Data`-based input and output. It imports Foundation — the 
  system Foundation on Darwin, and swift-foundation's `FoundationEssentials` 
  elsewhere. Disable the trait to build without that dependency.

## Topics

### Running a subprocess

- <doc:GettingStarted>
- <doc:StreamingAndInput>
- ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:)-(_,_,_,_,_,Input,_,_)``
- ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:)-(_,_,_,_,_,Span<InputElement>,_,_)``
- ``run(_:arguments:environment:workingDirectory:platformOptions:input:output:error:body:)``
- ``Executable``
- ``Arguments``
- ``Environment``
- ``PlatformOptions``

### Configuring and running a subprocess

- ``run(_:input:output:error:)-(_,Input,_,_)``
- ``run(_:input:output:error:)-(_,Span<InputElement>,_,_)``
- ``run(_:input:output:error:body:)``
- ``Configuration``

### Collecting output

- ``OutputProtocol``
- ``DiscardedOutput``
- ``StringOutput``
- ``BytesOutput``
- ``FileDescriptorOutput``
- ``DataOutput``

### Streaming output

- ``SequenceOutput``
- ``SubprocessOutputSequence``

### Redirecting standard error

- ``ErrorOutputProtocol``
- ``CombinedErrorOutput``

### Providing input

- ``InputProtocol``
- ``NoInput``
- ``StringInput``
- ``ArrayInput``
- ``FileDescriptorInput``
- ``CustomWriteInput``
- ``DataInput``
- ``DataSequenceInput``
- ``DataAsyncSequenceInput``

### Interacting with a running subprocess

- ``Execution``
- ``StandardInputWriter``

### Inspecting results

- ``ExecutionResult``
- ``TerminationStatus``
- ``ProcessIdentifier``

### Terminating a subprocess

- ``TeardownStep``
- ``Signal``

### Handling errors

- ``SubprocessError``
