<a id="readme-top"></a>

# Subprocess

Subprocess is a cross-platform package for spawning processes in Swift.


## Getting Started

To use `Subprocess` in a [SwiftPM](https://swift.org/package-manager/) project, add it as a package dependency to your `Package.swift`:


```swift
dependencies: [
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", branch: "main")
]
```
Then, adding the `Subprocess` module to your target dependencies:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "Subprocess", package: "swift-subprocess")
    ]
)
```

`Subprocess` offers two [package traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md):

- `SubprocessFoundation`: includes a dependency on `Foundation` and adds extensions on Foundation types like `Data`. This trait is enabled by default.
- `SubprocessSpan`: makes Subprocess’ API, mainly `OutputProtocol`, `RawSpan` based. This trait is enabled whenever `RawSpan` is available and should only be disabled when `RawSpan` is not available.

Please find the API proposal [here](https://github.com/swiftlang/swift-foundation/blob/main/Proposals/0007-swift-subprocess.md).

### Swift Versions

The minimal supported Swift version is **Swift 6.1**.

To experiment with the `SubprocessSpan` trait, Swift 6.2 is required. Currently, you can download the Swift 6.2 toolchain (`main` development snapshot) [here](https://www.swift.org/install/macos/#development-snapshots).


## Feature Overview

### Run and Asynchonously Collect Output

The easiest way to spawn a process with `Subprocess` is to simply run it and await its `CollectedResult`:

```swift
import Subprocess

let result = try await run(.name("ls"))

print(result.processIdentifier) // prints 1234
print(result.terminationStatus) // prints exited(0)

print(result.standardOutput) // prints LICENSE Package.swift ...
```

### Run with Custom Closure

To have more precise control over input and output, you can provide a custom closure that executes while the child process is active. Inside this closure, you have the ability to manage the subprocess’s state (like suspending or terminating it) and stream its standard output and standard error as an `AsyncSequence`:

```swift
import Subprocess

// Monitor Nginx log via `tail -f`
async let monitorResult = run(
    .path("/usr/bin/tail"),
    arguments: ["-f", "/path/to/nginx.log"]
) { execution, standardOutput in
    for try await line in standardOutput.lines(encoding: UTF8.self) {
        // Parse the log text
        if line.contains("500") {
            // Oh no, 500 error
        }
    }
}
```

### Customizable Execution

You can set various parameters when running the child process, such as `Arguments`, `Environment`, and working directory:

```swift
import Subprocess

let result = try await run(
    .path("/bin/ls"),
    arguments: ["-a"],
    // Inherit the environment values from parent process and
    // add `NewKey=NewValue` 
    environment: .inherit.updating(["NewKey": "NewValue"]),
    workingDirectory: "/Users/",
)
```

### Platform Specific Options and “Escape Hatches”

`Subprocess` provides **platform-specific** configuration options, like setting `uid` and `gid` on Unix and adjusting window style on Windows, through the `PlatformOptions` struct. Check out the `PlatformOptions` documentation for a complete list of configurable parameters across different platforms.

`PlatformOptions` also allows access to platform-specific spawning constructs and customizations via a closure.

```swift
import Darwin
import Subprocess

var platformOptions = PlatformOptions()
let intendedWorkingDir = "/path/to/directory"
platformOptions.preSpawnProcessConfigurator = { spawnAttr, fileAttr in
    // Set POSIX_SPAWN_SETSID flag, which implies calls
    // to setsid
    var flags: Int16 = 0
    posix_spawnattr_getflags(&spawnAttr, &flags)
    posix_spawnattr_setflags(&spawnAttr, flags | Int16(POSIX_SPAWN_SETSID))

    // Change the working directory
    intendedWorkingDir.withCString { path in
        _ = posix_spawn_file_actions_addchdir_np(&fileAttr, path)
    }
}

let result = try await run(.path("/bin/exe"), platformOptions: platformOptions)
```


### Flexible Input and Output Configurations

By default, `Subprocess`:
- Doesn’t send any input to the child process’s standard input
- Asks the user how to capture the output
- Ignores the child process’s standard error

You can tailor how `Subprocess` handles the standard input, standard output, and standard error by setting the `input`, `output`, and `error` parameters:

```swift
let content = "Hello Subprocess"

// Send "Hello Subprocess" to the standard input of `cat`
let result = try await run(.name("cat"), input: .string(content, using: UTF8.self))

// Collect both standard error and standard output as Data
let result = try await run(.name("cat"), output: .data, error: .data)
```

`Subprocess` supports these input options:

#### `NoInput`

This option means no input is sent to the subprocess.

Use it by setting `.none` for `input`.

#### `FileDescriptorInput`

This option reads input from a specified `FileDescriptor`. If `closeAfterSpawningProcess` is set to `true`, the subprocess will close the file descriptor after spawning. If `false`, you are responsible for closing it, even if the subprocess fails to spawn.

Use it by setting `.fileDescriptor(closeAfterSpawningProcess:)` for `input`.

#### `StringInput`

This option reads input from a type conforming to `StringProtocol` using the specified encoding.

Use it by setting `.string(using:)` for `input`.

#### `ArrayInput`

This option reads input from an array of `UInt8`.

Use it by setting `.array` for `input`.

#### `DataInput` (available with `SubprocessFoundation` trait)

This option reads input from a given `Data`.

Use it by setting `.data` for `input`.

#### `DataSequenceInput` (available with `SubprocessFoundation` trait)

This option reads input from a sequence of `Data`.

Use it by setting `.sequence` for `input`.

#### `DataAsyncSequenceInput` (available with `SubprocessFoundation` trait)

This option reads input from an async sequence of `Data`.

Use it by setting `.asyncSequence` for `input`.

---

`Subprocess` also supports these output options:

#### `DiscardedOutput`

This option means the `Subprocess` won’t collect or redirect output from the child process.

Use it by setting `.discarded` for `output` or `error`.

#### `FileDescriptorOutput`

This option writes output to a specified `FileDescriptor`. You can choose to have the `Subprocess` close the file descriptor after spawning.

Use it by setting `.fileDescriptor(closeAfterSpawningProcess:)` for `output` or `error`.

#### `StringOutput`

This option collects output as a `String` with the given encoding.

Use it by setting `.string(limit:encoding:)` for `output` or `error`.

#### `BytesOutput`

This option collects output as `[UInt8]`.

Use it by setting`.bytes(limit:)` for `output` or `error`.


### Cross-platform support

`Subprocess` works on macOS, Linux, and Windows, with feature parity on all platforms as well as platform-specific options for each.

The table below describes the current level of support that Subprocess has for various platforms:

| **Platform**                       | **Support Status** |
| ---------------------------------- | ------------------ |
| **macOS**                          | Supported          |
| **iOS**                            | Not supported      |
| **watchOS**                        | Not supported      |
| **tvOS**                           | Not supported      |
| **visionOS**                       | Not supported      |
| **Ubuntu 20.04**                   | Supported          |
| **Ubuntu 22.04**                   | Supported          |
| **Ubuntu 24.04**                   | Supported          |
| **Red Hat Universal Base Image 9** | Supported          |
| **Debian 12**                      | Supported          |
| **Amazon Linux 2**                 | Supported          |
| **Windows**                        | Supported          |

<p align="right">(<a href="#readme-top">back to top</a>)</p>


## Documentation

The latest API documentation can be viewed by running the following command:

```
swift package --disable-sandbox preview-documentation --target Subprocess
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>


## Contributing to Subprocess

Subprocess is part of the Foundation project. Discussion and evolution take place on [Swift Foundation Forum](https://forums.swift.org/c/related-projects/foundation/99).

If you find something that looks like a bug, please open a [Bug Report][bugreport]! Fill out as many details as you can.

[bugreport]: https://github.com/swiftlang/swift-subprocess/issues/new?assignees=&labels=bug&template=bug_report.md

<p align="right">(<a href="#readme-top">back to top</a>)</p>


## Code of Conduct

Like all Swift.org projects, we would like the Subprocess project to foster a diverse and friendly community. We expect contributors to adhere to the [Swift.org Code of Conduct](https://swift.org/code-of-conduct/).


<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Contact information

The Foundation Workgroup communicates with the broader Swift community using the [forum](https://forums.swift.org/c/related-projects/foundation/99) for general discussions.

The workgroup can also be contacted privately by messaging [@foundation-workgroup](https://forums.swift.org/new-message?groupname=foundation-workgroup) on the Swift Forums.


<p align="right">(<a href="#readme-top">back to top</a>)</p>
