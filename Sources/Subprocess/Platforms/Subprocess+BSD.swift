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
    return try await _castError {
        try await withCheckedThrowingContinuation { continuation in
            // Guard against double-resume: the event handler and the backup
            // peekIfExited() check below can both fire for the same exit.
            let alreadyResumed = AtomicCounter()
            let source = DispatchSource.makeProcessSource(
                identifier: processIdentifier.value,
                eventMask: [.exit],
                queue: .global()
            )
            source.setEventHandler {
                if alreadyResumed.addOne() == 1 {
                    source.cancel()
                    continuation.resume()
                }
            }
            // Register the source BEFORE checking peekIfExited() to eliminate
            // the TOCTOU race: if the process exits between the peek and resume()
            // the NOTE_EXIT event would be lost and the continuation would hang.
            source.resume()
            // Backup: if the process already exited before we registered the
            // source above, kqueue may not fire NOTE_EXIT retroactively.
            // Uses WNOWAIT so it doesn't reap the zombie (that's done elsewhere).
            do throws(Errno) {
                if try processIdentifier.peekIfExited() {
                    if alreadyResumed.addOne() == 1 {
                        source.cancel()
                        continuation.resume()
                    }
                }
            } catch {
                if alreadyResumed.addOne() == 1 {
                    source.cancel()
                    continuation.resume(
                        throwing: SubprocessError.failedToMonitor(withUnderlyingError: error)
                    )
                }
            }
        }
    }
}

#endif
