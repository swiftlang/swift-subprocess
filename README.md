# Subprocess

Subprocess is a cross-platform Swift package for spawning child processes, built from the ground up with Swift concurrency.

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fswiftlang%2Fswift-subprocess%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/swiftlang/swift-subprocess) [![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fswiftlang%2Fswift-subprocess%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/swiftlang/swift-subprocess)


## Getting Started

To use `Subprocess` in a [SwiftPM](https://swift.org/package-manager/) project, add it as a package dependency in your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/swiftlang/swift-subprocess.git",
        .upToNextMinor(from: "0.4.0")
    )
]
```

Then add the `Subprocess` module to your target dependencies:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "Subprocess", package: "swift-subprocess")
    ]
)
```

`Subprocess` offers one [package trait](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md), `SubprocessFoundation`, which adds a dependency on `Foundation` and provides extensions on Foundation types like `Data`. This trait is enabled by default.


### Swift Versions

We'd like this package to quickly embrace Swift language and toolchain improvements that are relevant to its mandate. Accordingly, from time to time, new versions of this package require clients to upgrade to a more recent Swift toolchain release. Patch (i.e., bugfix) releases will not increase the required toolchain version, but any minor (i.e., new feature) release may do so.

The following table maps package releases to their minimum required Swift toolchain:

| Package version        | Swift version | Xcode release |
| ---------------------- | ------------- | ------------- |
| swift-subprocess 0.1.x | >= Swift 6.1  | >= Xcode 16.3 |
| swift-subprocess 0.2.x | >= Swift 6.1  | >= Xcode 16.3 |
| swift-subprocess 0.3.x | >= Swift 6.1  | >= Xcode 16.3 |
| swift-subprocess 0.4.x | >= Swift 6.1  | >= Xcode 16.3 |
| main                   | >= Swift 6.2  | >= Xcode 26   |


## Feature Overview

### Run and Collect Output

The simplest way to use `Subprocess` is to run a process and collect its output:

```swift
import Subprocess

let result = try await run(.name("ls"), output: .string(limit: 4096))

print(result.processIdentifier) // e.g. 1234
print(result.terminationStatus) // e.g. exited(0)
print(result.standardOutput)    // e.g. Optional("LICENSE\nPackage.swift\n...")
```

This returns an `ExecutionRecord` containing the process identifier, termination status, and collected standard output and standard error.


### Run with a Custom Closure

For more control, pass a closure that runs while the child process is active. The closure receives an `Execution` handle and, depending on the variant, streams for standard output, standard error, and a writer for standard input.

> [!CAUTION]
> All closure arguments,`Execution`, `AsyncBufferSequence`, and `StandardInputWriter`, are valid only for the duration of the closure's execution and must not be escaped.


Stream standard output line by line:

```swift
import Subprocess

let outcome = try await run(
    .path("/usr/bin/tail"),
    arguments: ["-f", "/path/to/nginx.log"]
) { execution, outputSequence in
    for try await line in outputSequence.lines() {
        if line.contains("500") {
            // Oh no, 500 error
        }
    }
}
```

Write to standard input and read from standard output:

```swift
let outcome = try await run(.name("cat")) { execution, inputWriter, outputSequence in
    try await inputWriter.write("Hello, Subprocess!\n")
    try await inputWriter.finish()
    for try await line in outputSequence.lines() {
        print(line) // "Hello, Subprocess!"
    }
}
```

The closure-based `run` returns an `ExecutionOutcome` containing both the closure's return value and the termination status.

`Subprocess` provides several closure variants depending on which streams you need:

* Manage the runnning process without streaming
```swift
run(.path("/my/app")) { execution in
    ...
}
```

* Manage the running process and stream standard output or standard error
```swift
run(.path("/my/app"), error: .discarded) { execution, outputStream in
    for try await item in outputStream { ... }
}

run(.path("/my/app"), output: .discarded) { execution, errorStream in
    for try await item in errorStream { ... }
}
```


* Write to standard input and stream standard output or standard error
```swift
run(.path("/my/app"), output: .discarded) { execution, inputWriter, outputStream in
    try await withThrowingTaskGroup { group in
        group.addTask { for try await item in outputStream { ... } }
        group.addTask {
            _ = try await inputWriter.write("Hello Subprocess")
            try await inputWriter.finish()
        }
        try await group.waitForAll()
    }
}


run(.path("/my/app"), error: .discarded) { execution, inputWriter, errorStream in
    try await withThrowingTaskGroup { group in
        group.addTask { for try await item in errorStream { ... } }
        group.addTask {
            _ = try await inputWriter.write("Hello Subprocess")
            try await inputWriter.finish()
        }
        try await group.waitForAll()
    }
}
```

* Write to standard input and stream both standard output and standard error
```swift
run(.path("/my/app")) { execution, inputWriter, outputStream, errorStream in
    try await withThrowingTaskGroup { group in
        group.addTask { for try await item in outputStream { ... } }
        group.addTask { for try await item in errorStream { ... } }
        group.addTask {
            _ = try await inputWriter.write("Hello Subprocess")
            try await inputWriter.finish()
        }
        try await group.waitForAll()
    }
}
```

In the closure-based API, output streams are delivered as an `AsyncBufferSequence` — an asynchronous sequence of `Buffer` values. Each `Buffer` provides access to its bytes via `withUnsafeBytes(_:)` or the `bytes` property (a `RawSpan`).

The preferred method to convert `Buffer` to `String` is to read output line by line using `.lines()`. You can optionally specify an encoding and buffering policy:

```swift
for try await line in outputSequence.lines(
    encoding: UTF16.self,
    bufferingPolicy: .maxLineLength(1024)
) {
    // ...
}
```

`StandardInputWriter` supports writing `[UInt8]`, `String`, `RawSpan`, and (with the `SubprocessFoundation` trait) `Data`. Call `finish()` when done writing.


### Customizable Execution

Configure arguments, environment variables, and the working directory:

```swift
import Subprocess

let result = try await run(
    .path("/bin/ls"),
    arguments: ["-a"],
    // Inherit environment values from the parent process
    // and add NewKey=NewValue
    environment: .inherit.updating(["NewKey": "NewValue"]),
    workingDirectory: "/Users/",
    output: .string(limit: 4096)
)
```

For reusable configurations, construct a `Configuration` value directly:

```swift
let config = Configuration(
    .name("my-tool"),
    arguments: ["--verbose"],
    environment: .inherit
)
let result = try await run(config, output: .string(limit: 4096))
```


Use it by setting `.string(_:)` or `.string(_:using:)` for `input`.
### Input and Output Options

By default, `Subprocess`:
- Provides no input to the child process
- Discards the child process's standard error

For the collected-result API, you must specify how to capture standard output.

**Input options:**

| Usage | Description |
| --- | --- |
| `.none` | No input (default) |
| `.fileDescriptor(_:closeAfterSpawningProcess:)` | Read from a file descriptor |
| `.standardInput` | Read from the parent process's standard input |
| `.string(_:)` or `.string(_:using:)` | Read from a string with optional encoding |
| `.array(_:)` | Read from a `[UInt8]` array |
| `Span<BitwiseCopyable>` | Read from a span (passed directly as the `input` parameter) |
| `.data(_:)` | Read from `Data` (requires `SubprocessFoundation`) |
| `.sequence(_:)` | Read from a `Sequence<Data>` or `AsyncSequence<Data>` (requires `SubprocessFoundation`) |


**Output options:**

| Usage | Description |
| --- | --- |
| `.discarded` | Discard output |
| `.fileDescriptor(_:closeAfterSpawningProcess:)` | Write to a file descriptor |
| `.currentStandardOutput` or `.currentStandardError` | Write to the parent process's standard output or standard error |
| `.string(limit:)` or `.string(limit:encoding:)` | Collect as `String?` |
| `.bytes(limit:)` | Collect as `[UInt8]` |
| `.data(limit:)` | Collect as `Data` (requires `SubprocessFoundation`) |
| `.combinedWithOutput` | Merge standard error into the standard output stream (error parameter only) |

The `limit` parameter specifies the maximum number of bytes to collect. `Subprocess` throws an error if the child process produces more output than the limit allows.

Use `.combinedWithOutput` for the `error` parameter to merge standard output and standard error into a single stream, equivalent to the shell redirection `2>&1`:

```swift
let result = try await run(
    .name("my-tool"),
    output: .string(limit: 4096),
    error: .combinedWithOutput
)
// result.standardOutput contains both standard output and standard error
```


### Graceful Teardown

When a parent task is cancelled, `Subprocess` can perform a configurable teardown sequence before forcefully terminating the child process. Set this up via `PlatformOptions.teardownSequence`:

```swift
let serverTask = Task {
    var platformOptions = PlatformOptions()
    platformOptions.teardownSequence = [
        .gracefulShutDown(allowedDurationToNextStep: .seconds(5))
    ]

    let outcome = try await run(
        .name("server"),
        platformOptions: platformOptions,
        output: .string(limit: 1024)
    )
}

// If serverTask is cancelled, Subprocess will:
// 1. Attempt a graceful shutdown (SIGTERM on Unix)
// 2. Wait up to 5 seconds for the process to exit
// 3. Send SIGKILL if the process hasn't exited
serverTask.cancel()
```

On Unix, you can also send specific signals as teardown steps:

```swift
platformOptions.teardownSequence = [
    .send(signal: .interrupt, allowedDurationToNextStep: .seconds(2)),
    .gracefulShutDown(allowedDurationToNextStep: .seconds(5))
]
```

The teardown sequence always concludes by sending a kill signal.

You can also trigger a teardown manually from within the closure via `execution.teardown(using:)`, or send individual signals on Unix with `execution.send(signal:)`.


### Platform-Specific Options and Escape Hatches

`PlatformOptions` provides platform-specific settings for the child process:

- **Unix:** `userID`, `groupID`, `supplementaryGroups`, `processGroupID`, `createSession`
- **macOS:** All Unix options, plus `qualityOfService` and `preSpawnProcessConfigurator`
- **Windows:** user credentials for starting the process as another user, console behavior, and window style

On macOS, `preSpawnProcessConfigurator` provides direct access to the underlying `posix_spawn` attributes and file actions:

```swift
import Darwin
import Subprocess

var platformOptions = PlatformOptions()
platformOptions.preSpawnProcessConfigurator = { spawnAttr, fileAttr in
    var flags: Int16 = 0
    posix_spawnattr_getflags(&spawnAttr, &flags)
    posix_spawnattr_setflags(&spawnAttr, flags | Int16(POSIX_SPAWN_SETSID))
}
let result = try await run(.path(...), platformOptions: platformOptions)
```

On Windows, `preSpawnProcessConfigurator` provides direct access to the underlying creation flags and startup info `STARTUPINFOW` used to call `CreateProcessW`:

```swift
import Darwin
import WinSDK

var platformOptions = PlatformOptions()
platformOptions.preSpawnProcessConfigurator = { creationFlags, startupInfo in
    creationFlags |= DWORD(CREATE_NEW_CONSOLE)
}
let result = try await run(.path(...), platformOptions: platformOptions)
```

See the `PlatformOptions` documentation for a complete list of configurable parameters on each platform.


### Cross-Platform Support

`Subprocess` works on macOS, Linux, and Windows, with feature parity across all platforms as well as platform-specific options for each.

| **Platform**                       | **Support Status** |
| ---------------------------------- | ------------------ |
| **macOS**                          | Supported          |
| **Ubuntu 20.04**                   | Supported          |
| **Ubuntu 22.04**                   | Supported          |
| **Ubuntu 24.04**                   | Supported          |
| **Red Hat Universal Base Image 9** | Supported          |
| **Debian 12**                      | Supported          |
| **Amazon Linux 2**                 | Supported          |
| **Windows 11**                     | Supported          |


## Documentation

The latest API documentation can be viewed by running the following command:

```
swift package --disable-sandbox preview-documentation --target Subprocess
```


## Contributing to Subprocess

Subprocess is part of the Foundation project. Discussion and evolution take place on the [Swift Foundation Forum](https://forums.swift.org/c/related-projects/foundation/99).

If you find something that looks like a bug, please open a [Bug Report][bugreport]! Fill out as many details as you can.

[bugreport]: https://github.com/swiftlang/swift-subprocess/issues/new?assignees=&labels=bug&template=bug_report.md


## Code of Conduct

Like all Swift.org projects, we would like the Subprocess project to foster a diverse and friendly community. We expect contributors to adhere to the [Swift.org Code of Conduct](https://swift.org/code-of-conduct/).


## Contact Information

The Foundation Workgroup communicates with the broader Swift community using the [forum](https://forums.swift.org/c/related-projects/foundation/99) for general discussions.

The workgroup can also be contacted privately by messaging [@foundation-workgroup](https://forums.swift.org/new-message?groupname=foundation-workgroup) on the Swift Forums.
