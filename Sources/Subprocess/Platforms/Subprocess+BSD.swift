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

#if os(macOS) || os(FreeBSD) || os(OpenBSD)

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(System)
import System
#else
import SystemPackage
#endif

internal import Dispatch

// MARK: - Process Monitoring
@Sendable
internal func waitForProcessTermination(
    for processIdentifier: ProcessIdentifier
) async throws(SubprocessError) {
    // Use blocking waitid(WNOWAIT) dispatched on a global queue rather than
    // DispatchSource NOTE_EXIT. On FreeBSD (and macOS), kqueue does not
    // retroactively deliver NOTE_EXIT if the process exits before the
    // EVFILT_PROC filter is registered, and libdispatch registers that filter
    // asynchronously — leaving an unavoidable TOCTOU window. Blocking waitid
    // with WNOWAIT is race-free: the kernel holds the call until the process
    // exits and the zombie is left intact for reapProcess. DispatchQueue.global
    // is used instead of runOnBackgroundThread so concurrent subprocess waits
    // are not serialised on the single worker thread.
    return try await _castError {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                do throws(Errno) {
                    _ = try _waitid(
                        idtype: P_PID,
                        id: id_t(processIdentifier.value),
                        flags: WEXITED | WNOWAIT
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(
                        throwing: SubprocessError.failedToMonitor(withUnderlyingError: error)
                    )
                }
            }
        }
    }
}

#endif
