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

/// Darwin AsyncIO implementation based on DispatchIO

// MARK: - macOS (DispatchIO)
#if SUBPROCESS_ASYNCIO_DISPATCH

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if canImport(os)
import os
#endif

@preconcurrency internal import Dispatch
import Synchronization

private typealias Registration = (
    continuation: SignalStream.Continuation,
    source: any DispatchSourceProtocol
)

#if canImport(Darwin)
// We can't unconditionally use Mutex on macOS because we want to
// support macOS 13.
private typealias _Mutex = OSAllocatedUnfairLock
#else
private typealias _Mutex = Synchronization.Mutex
#endif

private let _registration:
    _Mutex<
        [PlatformFileDescriptor: Registration]
    > = _Mutex([:])

final class AsyncIO: Sendable {
    static let shared: AsyncIO = AsyncIO()

    internal init() {}

    internal func shutdown() { /* noop on Darwin */  }

    internal func registerFileDescriptor(
        _ fileDescriptor: FileDescriptor,
        for event: Event
    ) -> SignalStream {
        return SignalStream { (continuation: SignalStream.Continuation) -> () in
            // Set file descriptor to be non blocking
            if let nonBlockingFdError = self.setNonblocking(for: fileDescriptor) {
                continuation.finish(throwing: nonBlockingFdError)
                return
            }
            // Register source
            let source: any DispatchSourceProtocol
            switch event {
            case .read:
                source = DispatchSource.makeReadSource(
                    fileDescriptor: fileDescriptor.rawValue
                )
            case .write:
                source = DispatchSource.makeWriteSource(
                    fileDescriptor: fileDescriptor.rawValue
                )
            }

            source.setEventHandler {
                // We are ready to read more data
                continuation.yield(true)
            }

            source.resume()

            // Save the continuation and source
            _registration.withLock { storage in
                storage[fileDescriptor.rawValue] = (continuation, source)
            }
        }
    }

    internal func removeRegistration(for fileDescriptor: FileDescriptor) throws(SubprocessError) {
        let registration = _registration.withLock { storage in
            return storage.removeValue(forKey: fileDescriptor.rawValue)
        }
        guard let registration else {
            return
        }
        registration.source.cancel()
        registration.continuation.finish()
    }
}

#if canImport(Darwin)
extension OSAllocatedUnfairLock where State: Sendable {
    init(_ initialValue: State) {
        self.init(initialState: initialValue)
    }
}
#endif

#endif // SUBPROCESS_ASYNCIO_DISPATCH
