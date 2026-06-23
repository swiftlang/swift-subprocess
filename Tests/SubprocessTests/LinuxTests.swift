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

#if os(Linux) || os(Android)

#if canImport(Android)
import Android
import Foundation
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(System)
import System
#else
import SystemPackage
#endif

import FoundationEssentials
import _SubprocessCShims

import Testing
@testable import Subprocess

// MARK: PlatformOption Tests
@Suite(.serialized)
struct SubprocessLinuxTests {
    init() {
        _ = globallyIgnoredSIGPIPE
    }

    @Test func testUniqueProcessIdentifier() async throws {
        _ = try await Subprocess.run(
            .path("/bin/echo"),
            input: .none,
            output: .discarded,
            error: .discarded
        ) { subprocess in
            if subprocess.processIdentifier.processDescriptor != .invalidDescriptor {
                var statinfo = stat()
                try #require(fstat(subprocess.processIdentifier.processDescriptor, &statinfo) == 0)

                // In kernel 6.9+, st_ino globally uniquely identifies the process
                #expect(statinfo.st_ino > 0)
            }
        }
    }
}

// MARK: FileDescriptor Leak Tests
#if os(Linux)
extension SubprocessLinuxTests {
    /// A `clone3()`/`fork()` that succeeds and then fails at `execve()` used to
    /// leak the process descriptor (the `clone3(CLONE_PIDFD)` fd, or its
    /// `pidfd_open()` fallback) on the non-retried spawn-error branch. This
    /// runs many spawns that fail at `execve()` with `ENOEXEC` and asserts the
    /// open `pidfd` count does not grow.
    ///
    /// Run inside an exit test so the count is unaffected by subprocesses that
    /// other suites spawn concurrently in the shared test process; isolation is
    /// what lets the assertion be exact rather than a sampled threshold (see
    /// `testConcurrentRun()`).
    ///
    /// Linux only: exit tests are unavailable on Android and the `pidfd` marker
    /// is read from `/proc`. On kernels predating pidfd support (< 5.3), the
    /// spawn creates no descriptor and this passes vacuously.
    @Test(.timeLimit(.minutes(1)))
    func testProcessDescriptorNotLeakedOnExecFailure() async {
        await #expect(processExitsWith: .success) {
            // A mode-0755 file whose contents are neither `ELF` nor a `#!`
            // script. `execve(2)` rejects it with `ENOEXEC`, which is outside
            // `{ENOENT, EACCES, ENOTDIR}` and therefore reaches the leaking
            // branch, after the child has already been created.
            var pathBuffer = Array("/tmp/subprocess-noexec-XXXXXX\u{0}".utf8).map { CChar(bitPattern: $0) }
            let fd = pathBuffer.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
            try #require(fd >= 0, "mkstemp failed: \(errno)")

            let executablePath = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            defer { _ = unlink(executablePath) }
            try #require(fchmod(fd, 0o755) == 0, "fchmod failed: \(errno)")

            let contents = Array("not an executable\n".utf8)
            let written = contents.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            try #require(written == contents.count, "write failed: \(errno)")
            try #require(close(fd) == 0, "close failed: \(errno)")

            // Confirm the counter recognizes a pidfd on this kernel before
            // relying on it; otherwise a link-format change (as in the 6.9
            // pidfs move) makes the leak assertion silently vacuous. Skip when
            // pidfds are unsupported (pre-5.3), where the spawn path creates
            // none and there is no leak to detect.
            let probe = _pidfd_open(getpid())
            if probe >= 0 {
                try #require(
                    countOpenProcessDescriptors() >= 1,
                    "process-descriptor counter did not recognize a live pidfd on this kernel"
                )
                _ = close(probe)
            }

            let iterations = 64
            let before = countOpenProcessDescriptors()
            for _ in 0..<iterations {
                let spawnError: SubprocessError?
                do {
                    _ = try await Subprocess.run(
                        .path(FilePath(executablePath)),
                        output: .discarded,
                        error: .discarded
                    )
                    spawnError = nil
                } catch let error as SubprocessError {
                    spawnError = error
                }
                // A non-executable cannot exec, so a failure is mandatory.
                // `ENOENT`/`EACCES`/`ENOTDIR` take the `continue` path, which
                // already closes the descriptor.
                let error = try #require(
                    spawnError, "spawn unexpectedly succeeded for a non-executable file"
                )
                try #require(error.code == .spawnFailed)
                try #require(error.underlyingError == Errno(rawValue: ENOEXEC))
            }
            let after = countOpenProcessDescriptors()
            try #require(
                after == before,
                "leaked \(after - before) process descriptor(s) across \(iterations) failed spawns"
            )
        }
    }
}

/// Counts the open process descriptors in the current process by scanning
/// `/proc/self/fd` for symlinks that point at a pidfd.
///
/// The link target differs by kernel: pre-6.9 backs pidfds with `anon_inode`
/// (`"anon_inode:[pidfd]"`); 6.9+ moved them to pidfs, whose target carries a
/// per-fd inode. Both contain `"pidfd"`, and no other descriptor this process
/// holds would contain that, so a substring match identifies them across
/// kernels.
private func countOpenProcessDescriptors() -> Int {
    guard let dir = opendir("/proc/self/fd") else { return 0 }
    defer { closedir(dir) }
    var count = 0
    while let entry = readdir(dir) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if name == "." || name == ".." { continue }
        var linkBuffer = [CChar](repeating: 0, count: 256)
        let length = ("/proc/self/fd/" + name).withCString { path in
            readlink(path, &linkBuffer, linkBuffer.count - 1)
        }
        guard length > 0 else { continue }
        linkBuffer[length] = 0
        let target = linkBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if target.contains("pidfd") {
            count += 1
        }
    }
    return count
}
#endif

#endif // canImport(Glibc) || canImport(Bionic) || canImport(Musl)
