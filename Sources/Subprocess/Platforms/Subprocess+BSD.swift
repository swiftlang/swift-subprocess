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

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(os)
import os
#endif

import Synchronization

#if canImport(Darwin)
private typealias _Mutex = OSAllocatedUnfairLock
#else
private typealias _Mutex = Synchronization.Mutex
#endif

// Selects the kqueue filter and identifier used to watch a child for exit.
//
// macOS and OpenBSD spawn ordinary children, monitored by PID with
// `EVFILT_PROC`. FreeBSD spawns children with `pdfork()` and monitors the
// resulting process descriptor with `EVFILT_PROCDESC`. If `pdfork()` was
// unavailable and the spawn fell back to `fork()` (so there is no descriptor),
// it monitors by PID just like the other platforms.
private func _monitorTarget(
    for processIdentifier: ProcessIdentifier
) -> (filter: Int16, identifier: CInt) {
    #if os(FreeBSD)
    if processIdentifier.processDescriptor != .invalidDescriptor {
        return (Int16(EVFILT_PROCDESC), processIdentifier.processDescriptor)
    }
    #endif
    return (Int16(EVFILT_PROC), processIdentifier.value)
}

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
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let status = _processMonitorState.withLock { state -> Result<Void, SubprocessError>? in
                switch state {
                case .notStarted:
                    let error: SubprocessError = .failedToMonitor(withUnderlyingError: nil)
                    return .failure(error)
                case .failed(let error):
                    return .failure(error)
                case .started(let storage):
                    let (filter, identifier) = _monitorTarget(for: processIdentifier)

                    // A valid PID or process descriptor is always >= 0; if it
                    // somehow is not, there is nothing to monitor.
                    guard identifier >= 0 else {
                        let error: SubprocessError = .failedToMonitor(withUnderlyingError: nil)
                        return .failure(error)
                    }
                    var newState = storage
                    // Only register with kqueue the first time we see this
                    // identifier. Additional waiters (for example, a concurrent
                    // teardown) share the existing registration through the
                    // continuation list, which keeps the call idempotent.
                    if newState.continuations[identifier] == nil {
                        // `EV_ONESHOT` tells the kernel to delete the knote as
                        // soon as it delivers `NOTE_EXIT`. A process exits
                        // exactly once, so the monitor thread never needs to
                        // unregister explicitly.
                        var event = _makeKevent(
                            ident: UInt(identifier),
                            filter: filter,
                            flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(truncatingIfNeeded: NOTE_EXIT)
                        )
                        let rc = _kevent(
                            storage.kqueueFileDescriptor,
                            &event,
                            1,
                            nil,
                            0,
                            nil
                        )
                        if rc != 0 {
                            let capturedErrno = errno
                            // `EVFILT_PROC` registration races with the child's
                            // exit: if the process has already gone the kernel
                            // reports ESRCH. Its zombie keeps the PID reserved
                            // for the imminent reap, so treat this as a normal
                            // termination and resume right away. (FreeBSD's
                            // descriptor stays valid until closed, so it never
                            // takes this path.)
                            if filter == Int16(EVFILT_PROC) && capturedErrno == ESRCH {
                                return .success(())
                            }
                            let error: SubprocessError = .failedToMonitor(
                                withUnderlyingError: Errno(rawValue: capturedErrno)
                            )
                            return .failure(error)
                        }
                    }
                    // Save the registration.
                    var list = newState.continuations[identifier] ?? []
                    list.append(continuation)
                    newState.continuations[identifier] = list
                    state = .started(newState)
                    // No state to resume; the monitor thread will resume the
                    // continuation when `NOTE_EXIT` is delivered.
                    return nil
                }
            }

            if let status {
                switch status {
                case .success:
                    continuation.resume()
                case .failure(let failure):
                    continuation.resume(throwing: failure)
                }
            }
        }
    }
}

// The kevent() C function and the kevent struct share the same name.
// Swift can disambiguate when given an explicit function type.
internal let _kevent:
    @convention(c) (
        Int32,
        UnsafePointer<kevent>?,
        Int32,
        UnsafeMutablePointer<kevent>?,
        Int32,
        UnsafePointer<timespec>?
    ) -> Int32 = kevent

internal func _makeKevent(
    ident: UInt,
    filter: Int16,
    flags: UInt16,
    fflags: UInt32 = 0
) -> kevent {
    #if canImport(Darwin)
    return kevent(
        ident: ident,
        filter: filter,
        flags: flags,
        fflags: fflags,
        data: 0,
        udata: nil
    )
    #else
    return kevent(
        ident: ident,
        filter: filter,
        flags: flags,
        fflags: fflags,
        data: 0,
        udata: nil,
        ext: (0, 0, 0, 0)
    )
    #endif
}
internal let _kqueueEventSize = 256

private enum ProcessMonitorState: Sendable {
    struct Storage: Sendable {
        let kqueueFileDescriptor: CInt
        let shutdownReadFileDescriptor: CInt
        let shutdownWriteFileDescriptor: CInt
        nonisolated(unsafe) let monitorThread: pthread_t
        var continuations: [CInt: [CheckedContinuation<Void, any Error>]]
    }

    case notStarted
    case started(Storage)
    case failed(SubprocessError)
}

private struct MonitorThreadContext: Sendable {
    let kqueueFileDescriptor: CInt
    let shutdownReadFileDescriptor: CInt
}

private let _processMonitorState: _Mutex<ProcessMonitorState> = _Mutex(.notStarted)

private func shutdown() {
    let storage = _processMonitorState.withLock { state -> ProcessMonitorState.Storage? in
        switch state {
        case .failed, .notStarted:
            return nil
        case .started(let storage):
            return storage
        }
    }

    guard let storage else {
        return
    }

    var one: UInt8 = 1
    // Wake the monitor thread so it can break out of its wait loop.
    withUnsafeBytes(of: &one) { ptr in
        _ = try? FileDescriptor(rawValue: storage.shutdownWriteFileDescriptor)
            .write(ptr)
    }
    pthread_join(storage.monitorThread, nil)
}

private func monitorThreadFunc(context: MonitorThreadContext) {
    var events: [kevent] = Array(
        repeating: _makeKevent(ident: 0, filter: 0, flags: 0, fflags: 0),
        count: _kqueueEventSize
    )

    monitorLoop: while true {
        let eventCount = _kevent(
            context.kqueueFileDescriptor,
            nil,
            0,
            &events,
            Int32(events.count),
            nil
        )
        if eventCount < 0 {
            if errno == EINTR || errno == EAGAIN {
                continue // interrupted; try again
            }
            // Report all other errors to every pending waiter.
            let error: SubprocessError = .failedToMonitor(
                withUnderlyingError: Errno(rawValue: errno)
            )
            let continuations = _processMonitorState.withLock {
                state -> [CheckedContinuation<Void, any Error>] in
                let result: [CheckedContinuation<Void, any Error>]
                if case .started(let storage) = state {
                    result = storage.continuations.values.flatMap { $0 }
                } else {
                    result = []
                }
                state = .failed(error)
                return result
            }
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
            break monitorLoop
        }

        for index in 0..<Int(eventCount) {
            let event = events[index]

            // The shutdown pipe and a process can share a numeric identifier
            // (a PID and a file descriptor live in different namespaces), so
            // distinguish the shutdown event by its filter as well.
            if event.filter == Int16(EVFILT_READ),
                Int32(event.ident) == context.shutdownReadFileDescriptor
            {
                var buf: UInt8 = 0
                withUnsafeMutableBytes(of: &buf) { ptr in
                    _ = try? FileDescriptor(
                        rawValue: context.shutdownReadFileDescriptor
                    ).read(into: ptr, retryOnInterrupt: true)
                }
                break monitorLoop
            }

            // Otherwise this is an `EVFILT_PROC`/`EVFILT_PROCDESC` `NOTE_EXIT`:
            // the child identified by `event.ident` has terminated.
            _notifyWaiters(Int32(event.ident))
        }
    }
}

private func _notifyWaiters(_ identifier: CInt) {
    let continuations = _processMonitorState.withLock {
        state -> [CheckedContinuation<Void, any Error>] in
        guard case .started(let storage) = state,
            let continuationList = storage.continuations[identifier]
        else {
            return []
        }
        var newStorage = storage
        newStorage.continuations.removeValue(forKey: identifier)
        state = .started(newStorage)

        return continuationList
    }

    for continuation in continuations {
        continuation.resume()
    }
}

private let setup: () = {
    func _reportFailureWithErrno(_ number: CInt) {
        let error: SubprocessError = .failedToMonitor(
            withUnderlyingError: Errno(rawValue: number)
        )
        _processMonitorState.withLock { state in
            state = .failed(error)
        }
    }

    #if os(FreeBSD) || os(OpenBSD)
    let kqueueFileDescriptor = kqueue1(O_CLOEXEC)
    #else
    let kqueueFileDescriptor = kqueue()
    #endif
    guard kqueueFileDescriptor >= 0 else {
        _reportFailureWithErrno(errno)
        return
    }

    // Create the shutdown pipe used to wake the monitor thread at exit.
    let shutdownPipe: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
    do {
        shutdownPipe = try FileDescriptor.pipe()
    } catch {
        _reportFailureWithErrno((error as? Errno)?.rawValue ?? EBADF)
        return
    }
    let shutdownReadFd = shutdownPipe.readEnd.rawValue
    let shutdownWriteFd = shutdownPipe.writeEnd.rawValue

    // Register the read end of the shutdown pipe with kqueue.
    var shutdownEvent = _makeKevent(
        ident: UInt(shutdownReadFd),
        filter: Int16(EVFILT_READ),
        flags: UInt16(EV_ADD | EV_ENABLE),
        fflags: 0
    )
    guard _kevent(kqueueFileDescriptor, &shutdownEvent, 1, nil, 0, nil) == 0 else {
        _reportFailureWithErrno(errno)
        return
    }

    let monitorThreadContext = MonitorThreadContext(
        kqueueFileDescriptor: kqueueFileDescriptor,
        shutdownReadFileDescriptor: shutdownReadFd
    )
    // Create the monitor thread.
    let thread: pthread_t
    switch Result(catching: { () throws(Errno) -> pthread_t in
        try pthread_create {
            monitorThreadFunc(context: monitorThreadContext)
        }
    }) {
    case let .success(t):
        thread = t
    case let .failure(error):
        _processMonitorState.withLock { state in
            state = .failed(
                SubprocessError.failedToMonitor(withUnderlyingError: error)
            )
        }
        return
    }

    let storage = ProcessMonitorState.Storage(
        kqueueFileDescriptor: kqueueFileDescriptor,
        shutdownReadFileDescriptor: shutdownReadFd,
        shutdownWriteFileDescriptor: shutdownWriteFd,
        monitorThread: thread,
        continuations: [:]
    )

    _processMonitorState.withLock { state in
        state = .started(storage)
    }

    atexit {
        shutdown()
    }
}()

internal func _setupMonitorSignalHandler() {
    // Only executed once.
    setup
}

#if canImport(Darwin)
extension OSAllocatedUnfairLock where State: Sendable {
    fileprivate init(_ initialValue: State) {
        self.init(initialState: initialValue)
    }
}
#endif

#endif // os(macOS) || os(FreeBSD) || os(OpenBSD)
