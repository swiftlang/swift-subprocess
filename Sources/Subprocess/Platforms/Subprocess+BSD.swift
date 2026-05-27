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
    // Fast path: if the process is already a zombie, return immediately.
    // Using WNOWAIT leaves the zombie in place for the eventual `reapProcess`.
    do throws(Errno) {
        if try processIdentifier.peekIfExited() {
            return
        }
    } catch {
        throw .failedToMonitor(withUnderlyingError: error)
    }

    return try await _castError {
        try await withCheckedThrowingContinuation { continuation in
            let source = DispatchSource.makeProcessSource(
                identifier: processIdentifier.value,
                eventMask: [.exit],
                queue: .global()
            )
            source.setEventHandler {
                source.cancel()
                continuation.resume()
            }
            source.resume()
        }
    }
}

#endif
