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

internal import Dispatch

// MARK: - Process Monitoring
@Sendable
internal func monitorProcessTermination(
    for processIdentifier: ProcessIdentifier
) async throws -> TerminationStatus {
    switch Result(catching: { () throws(SubprocessError.UnderlyingError) -> TerminationStatus? in try processIdentifier.reap() }) {
    case let .success(status?):
        return status
    case .success(nil):
        break
    case let .failure(error):
        throw SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: error
        )
    }
    return try await withCheckedThrowingContinuation { continuation in
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier.value,
            eventMask: [.exit],
            queue: .global()
        )
        source.setEventHandler {
            source.cancel()
            continuation.resume(with: Result(catching: { () throws(SubprocessError.UnderlyingError) -> TerminationStatus in
                // NOTE_EXIT may be delivered slightly before the process becomes reapable,
                // so we must call waitid without WNOHANG to avoid a narrow possibility of a race condition.
                // If waitid does block, it won't do so for very long at all.
                try processIdentifier.blockingReap()
            }).mapError { underlyingError in
                SubprocessError(    
                    code: .init(.failedToMonitorProcess),
                    underlyingError: underlyingError
                )
            })
        }
        source.resume()
    }
}

#endif
