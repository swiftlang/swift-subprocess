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

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#endif

import Synchronization
import _SubprocessCShims

#if canImport(Glibc)
extension EPOLL_EVENTS {
    init(_ other: EPOLL_EVENTS) {
        self = other
    }
}
#elseif canImport(Bionic)
typealias EPOLL_EVENTS = CInt

extension UInt32 {
    // for EPOLLIN/EPOLLOUT
    var rawValue: UInt32 {
        self
    }
}

extension Int32 {
    var rawValue: UInt32 {
        UInt32(bitPattern: self)
    }
}
#elseif canImport(Musl)
extension EPOLL_EVENTS {
    init(_ rawValue: Int32) {
        self.init(UInt32(bitPattern: rawValue))
    }
}

extension Int32 {
    // for EPOLLIN/EPOLLOUT
    var rawValue: UInt32 {
        UInt32(bitPattern: self)
    }
}
#endif

// MARK: - Process Monitoring
@Sendable
internal func waitForProcessTermination(
    for processIdentifier: ProcessIdentifier
) async throws(SubprocessError) {
    return try await _castError {
        return try await withCheckedThrowingContinuation { continuation in
            let status = _processMonitorState.withLock { state -> Result<Bool, SubprocessError>? in
                switch state {
                case .notStarted:
                    let error: SubprocessError = .failedToMonitor(withUnderlyingError: nil)
                    return .failure(error)
                case .failed(let error):
                    return .failure(error)
                case .started(let storage):
                    // pidfd is only supported on Linux kernel 5.4 and above
                    // On older releases, use signalfd so we do not need
                    // to register anything with epoll
                    if processIdentifier.processDescriptor != .invalidDescriptor {
                        var newState = storage
                        // epoll rejects duplicate EPOLL_CTL_ADD for the same fd
                        // with EEXIST, so only register the pidfd the first
                        // time we see it. Subsequent waiters share the
                        // existing registration via the continuation list.
                        if newState.continuations[processIdentifier.processDescriptor] == nil {
                            var event = epoll_event(
                                events: EPOLLIN.rawValue,
                                data: epoll_data(fd: processIdentifier.processDescriptor)
                            )
                            let rc = epoll_ctl(
                                storage.epollFileDescriptor,
                                EPOLL_CTL_ADD,
                                processIdentifier.processDescriptor,
                                &event
                            )
                            if rc != 0 {
                                let epollErrno = errno
                                let error: SubprocessError = .failedToMonitor(
                                    withUnderlyingError: Errno(rawValue: epollErrno)
                                )
                                return .failure(error)
                            }
                        }
                        // Now save the registration
                        var list = newState.continuations[processIdentifier.processDescriptor] ?? []
                        list.append(continuation)
                        newState.continuations[processIdentifier.processDescriptor] = list
                        state = .started(newState)
                        // No state to resume
                        return nil
                    } else {
                        // Fallback to using signal handler directly on older Linux kernels
                        // Since Linux coalesce signals, it's possible by the time we request
                        // monitoring the process has already exited. Check to make sure that
                        // is not the case and only save continuation then.
                        switch Result(catching: { () throws(Errno) -> Bool in try processIdentifier.peekIfExited() }) {
                        case let .success(processExited):
                            if !processExited {
                                // Save this continuation to be called by signal handler
                                var newState = storage
                                var list = newState.continuations[processIdentifier.value] ?? []
                                list.append(continuation)
                                newState.continuations[processIdentifier.value] = list
                                state = .started(newState)
                            }
                            return .success(processExited)
                        case let .failure(underlyingError):
                            let error: SubprocessError = .failedToMonitor(
                                withUnderlyingError: underlyingError
                            )
                            return .failure(error)
                        }
                    }
                }
            }

            if let status {
                switch status {
                case .success(let processExisted):
                    if processExisted {
                        // Resume the continuation now that the process has exited
                        continuation.resume()
                    }
                case .failure(let failure):
                    continuation.resume(throwing: failure)
                }
            }
        }
    }
}

private enum ProcessMonitorState: Sendable {
    struct Storage: Sendable {
        let epollFileDescriptor: CInt
        let shutdownFileDescriptor: CInt
        // `pthread_t` is a non-`Sendable` pointer on musl but a `Sendable`
        // integer on glibc/Bionic; scope the opt-out to musl so it isn't
        // flagged as unnecessary on the integer platforms.
        #if canImport(Musl)
        nonisolated(unsafe) let monitorThread: pthread_t
        #else
        let monitorThread: pthread_t
        #endif
        var continuations: [PlatformFileDescriptor: [CheckedContinuation<Void, any Error>]]
    }

    case notStarted
    case started(Storage)
    case failed(SubprocessError)
}

private struct MonitorThreadContext: Sendable {
    let epollFileDescriptor: CInt
    let shutdownFileDescriptor: CInt

    init(epollFileDescriptor: CInt, shutdownFileDescriptor: CInt) {
        self.epollFileDescriptor = epollFileDescriptor
        self.shutdownFileDescriptor = shutdownFileDescriptor
    }
}

// Okay to be unlocked global mutable state because this value is only set once, like dispatch_once
private nonisolated(unsafe) var _signalPipe: (readEnd: CInt, writeEnd: CInt) = (readEnd: -1, writeEnd: -1)
// Okay to be unlocked global mutable state because this value is only set once, like dispatch_once
private nonisolated(unsafe) var _waitProcessDescriptorSupported = false
private let _processMonitorState: Mutex<ProcessMonitorState> = .init(.notStarted)

private func shutdown() {
    let storage = _processMonitorState.withLock { state -> ProcessMonitorState.Storage? in
        switch state {
        case .failed(_), .notStarted:
            return nil
        case .started(let storage):
            return storage
        }
    }

    guard let storage else {
        return
    }

    var one: UInt64 = 1
    // Wake up the thread for shutdown
    withUnsafeBytes(of: &one) { ptr in
        _ = try? FileDescriptor(rawValue: storage.shutdownFileDescriptor)
            .write(ptr, retryOnInterrupt: true)
    }
    // Cleanup the monitor thread
    pthread_join(storage.monitorThread, nil)
}

/// See the following page for the complete list of async-signal-safe functions:
/// https://man7.org/linux/man-pages/man7/signal-safety.7.html
/// Only these functions can be used in the signal handler below.
private func signalHandler(_ signalNumber: CInt) {
    let savedErrno = errno
    var one: UInt8 = 1
    withUnsafeBytes(of: &one) { ptr in
        _ = try? FileDescriptor(rawValue: _signalPipe.writeEnd)
            .write(ptr, retryOnInterrupt: true)
    }
    errno = savedErrno
}

private func monitorThreadFunc(context: MonitorThreadContext) {
    var events: [epoll_event] = Array(
        repeating: epoll_event(events: 0, data: epoll_data(fd: 0)),
        count: 256
    )
    var waitMask = sigset_t()
    sigemptyset(&waitMask)
    // Enter the monitor loop
    monitorLoop: while true {
        let eventCount = epoll_pwait(
            context.epollFileDescriptor,
            &events,
            CInt(events.count),
            -1,
            &waitMask
        )
        if eventCount < 0 {
            let pwaitErrno = errno
            if pwaitErrno == EINTR || pwaitErrno == EAGAIN {
                continue // interrupted by signal; try again
            }
            // Report other errors
            let error: SubprocessError = .failedToMonitor(
                withUnderlyingError: Errno(rawValue: pwaitErrno)
            )
            let continuations = _processMonitorState.withLock { state -> [CheckedContinuation<Void, any Error>] in
                let result: [CheckedContinuation<Void, any Error>]
                if case .started(let storage) = state {
                    result = storage.continuations.values.flatMap { $0 }
                } else {
                    result = []
                }
                state = .failed(error)
                return result
            }
            // Report error to all existing continuations
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
            break monitorLoop
        }

        for index in 0..<Int(eventCount) {
            let event = events[index]
            let targetFileDescriptor = event.data.fd

            // Breakout the monitor loop if we received shutdown
            // from the shutdownFD
            if targetFileDescriptor == context.shutdownFileDescriptor {
                var buf: UInt64 = 0
                withUnsafeMutableBytes(of: &buf) { ptr in
                    _ = try? FileDescriptor(
                        rawValue: context.shutdownFileDescriptor
                    ).read(into: ptr, retryOnInterrupt: true)
                }
                break monitorLoop
            }

            // P_PIDFD requires Linux Kernel 5.4 and above
            if _waitProcessDescriptorSupported {
                _unregisterProcessDescriptorAndNotify(targetFileDescriptor, context: context)
            } else {
                _notifyAllKnownChildProcesses(targetFileDescriptor, context: context)
            }
        }
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

    // Create the epollfd for monitoring
    let epollFileDescriptor = epoll_create1(CInt(EPOLL_CLOEXEC))
    guard epollFileDescriptor >= 0 else {
        _reportFailureWithErrno(errno)
        return
    }
    // Create shutdownFileDescriptor
    let shutdownFileDescriptor = eventfd(0, CInt(EFD_NONBLOCK | EFD_CLOEXEC))
    guard shutdownFileDescriptor >= 0 else {
        _reportFailureWithErrno(errno)
        return
    }

    // Register shutdownFileDescriptor with epoll
    var event = epoll_event(
        events: EPOLLIN.rawValue,
        data: epoll_data(fd: shutdownFileDescriptor)
    )
    var rc = epoll_ctl(
        epollFileDescriptor,
        EPOLL_CTL_ADD,
        shutdownFileDescriptor,
        &event
    )
    guard rc == 0 else {
        _reportFailureWithErrno(errno)
        return
    }

    // If the current kernel does not support pidfd, fallback to signal handler
    // Create the self-pipe that signal handler writes to
    if !_isWaitprocessDescriptorSupported() {
        var pipeCreationError: SubprocessError? = nil
        do {
            let (readEnd, writeEnd) = try FileDescriptor.pipe()
            _signalPipe = (readEnd.rawValue, writeEnd.rawValue)
            // Make the pipe non-blocking. The read end MUST be non-blocking
            // so the drain loop in _notifyAllKnownChildProcesses exits cleanly
            // with EAGAIN once the pipe is empty.
            for fd in [readEnd.rawValue, writeEnd.rawValue] {
                let existing = fcntl(fd, F_GETFL)
                if existing < 0 {
                    throw Errno(rawValue: errno)
                }
                if fcntl(fd, F_SETFL, existing | O_NONBLOCK) < 0 {
                    throw Errno(rawValue: errno)
                }
            }
        } catch {
            var underlying: Errno? = nil
            if let err = error as? Errno {
                underlying = err
            }
            pipeCreationError = .failedToMonitor(
                withUnderlyingError: underlying
            )
        }
        if let pipeCreationError {
            _processMonitorState.withLock { state in
                state = .failed(pipeCreationError)
            }
            return
        }
        // Register the read end with epoll so we can get updates
        // about it. The write end is written by the signal handler
        var event = epoll_event(
            events: EPOLLIN.rawValue,
            data: epoll_data(fd: _signalPipe.readEnd)
        )
        rc = epoll_ctl(
            epollFileDescriptor,
            EPOLL_CTL_ADD,
            _signalPipe.readEnd,
            &event
        )
        guard rc == 0 else {
            _reportFailureWithErrno(errno)
            return
        }
        // Install the SIGCHLD handler
        guard _subprocess_install_sigchld_handler(signalHandler) == 0 else {
            _reportFailureWithErrno(errno)
            return
        }
    } else {
        // Mark waitid(P_PIDFD) as supported
        _waitProcessDescriptorSupported = true
    }
    let monitorThreadContext = MonitorThreadContext(
        epollFileDescriptor: epollFileDescriptor,
        shutdownFileDescriptor: shutdownFileDescriptor
    )
    // Create the monitor thread
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
        epollFileDescriptor: epollFileDescriptor,
        shutdownFileDescriptor: shutdownFileDescriptor,
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
    // Only executed once
    setup
}

private func _unregisterProcessDescriptorAndNotify(_ pidfd: CInt, context: MonitorThreadContext) {
    // Remove the continuation
    let result = _processMonitorState.withLock { state -> (continuations: [CheckedContinuation<Void, any Error>], error: SubprocessError?)? in
        guard case .started(let storage) = state,
            let continuationList = storage.continuations[pidfd]
        else {
            return nil
        }
        // Remove registration
        var newStorage = storage
        newStorage.continuations.removeValue(forKey: pidfd)
        state = .started(newStorage)

        // Remove this pidfd from epoll to prevent further notifications.
        // The return value is intentionally not propagated to the continuation:
        // epoll firing this event means the process has already exited, so
        // monitoring succeeded regardless of cleanup outcome.
        //
        // ENOENT is silently ignored: it means the fd is not (or is no longer)
        // in the epoll instance, which is harmless — this occurs on concurrent
        // removals and on older 5.x kernels where epoll_ctl(DEL) incorrectly
        // reports ENOENT for pidfds after process exit.  The fd is removed from
        // epoll automatically by the kernel when processIdentifier.close() closes
        // it anyway, so a failed DEL is never permanent.
        //
        // Any other error (EBADF, EINVAL, …) would indicate a programming error
        // in fd lifecycle management — e.g. the pidfd was closed prematurely —
        // and is surfaced as an assertion failure in debug builds.
        let delRC = epoll_ctl(
            context.epollFileDescriptor,
            EPOLL_CTL_DEL,
            pidfd,
            nil
        )

        // The pidfd is intentionally left open here.  It is owned by
        // ProcessIdentifier and will be closed by processIdentifier.close()
        // in the defer in Configuration.swift once monitoring is fully done.
        // Closing it here would free the fd number and allow it to be recycled
        // before that defer runs, causing a close-the-wrong-fd race.

        if delRC != 0 && errno != ENOENT {
            let error = SubprocessError.failedToMonitor(
                withUnderlyingError: Errno(rawValue: errno)
            )
            return (continuationList, error)
        }

        return (continuationList, nil)
    }

    guard let result else {
        return
    }

    if let error = result.error {
        for c in result.continuations {
            c.resume(throwing: error)
        }
    } else {
        for c in result.continuations {
            c.resume()
        }
    }
}

// On older kernels, fall back to using signal handlers
private typealias ResultContinuations = (
    failure: SubprocessError?,
    continuations: [CheckedContinuation<Void, any Error>]
)
private func _notifyAllKnownChildProcesses(_ signalFd: CInt, context: MonitorThreadContext) {
    guard signalFd == _signalPipe.readEnd else {
        return
    }

    // Drain the signalFd
    var buffer: UInt8 = 0
    withUnsafeMutableBytes(of: &buffer) { ptr in
        while (try? FileDescriptor(rawValue: signalFd).read(into: ptr) > 0) ?? false {
            /* noop, drain the pipe  */
        }
    }

    let resumingContinuations: [ResultContinuations] = _processMonitorState.withLock { state in
        guard case .started(let storage) = state else {
            return []
        }
        var updatedContinuations = storage.continuations
        var results: [ResultContinuations] = []
        // Since Linux coalesce signals, we need to loop through all known child process
        // to check if they exited.
        loop: for (knownChildPID, continuations) in storage.continuations {
            switch Result(catching: { () throws(Errno) -> Bool in try _peekIfExited(pid: knownChildPID) }) {
            case let .success(processExisted):
                if processExisted {
                    results.append((failure: nil, continuations: continuations))
                } else {
                    // The process is still running, move on to the next one
                    continue loop
                }
            case let .failure(error):
                results.append((failure: SubprocessError.failedToMonitor(withUnderlyingError: error), continuations: continuations))
            }
            // Now we have the exit code, remove saved continuations
            updatedContinuations.removeValue(forKey: knownChildPID)
        }
        var updatedStorage = storage
        updatedStorage.continuations = updatedContinuations
        state = .started(updatedStorage)

        return results
    }
    // Resume continuations
    for resumingContinuation in resumingContinuations {
        if let error = resumingContinuation.failure {
            for c in resumingContinuation.continuations {
                c.resume(throwing: error)
            }
        } else {
            for c in resumingContinuation.continuations {
                c.resume()
            }
        }
    }
}

internal func _isWaitprocessDescriptorSupported() -> Bool {
    // waitid(P_PIDFD) is only supported on Linux kernel 5.4 and above
    // Probe whether the current system supports it by calling it with self pidfd
    // and checking for EINVAL (waitid sets errno to EINVAL if it does not
    // recognize the id type).
    var siginfo = siginfo_t()
    let selfPidfd = _pidfd_open(getpid())
    if selfPidfd < 0 {
        // If we can not retrieve pidfd, the system does not support waitid(P_PIDFD)
        return false
    }
    defer { try? _safelyClose(.fileDescriptor(FileDescriptor(rawValue: selfPidfd))) }
    /// The following call will fail either with
    /// - ECHILD: in this case we know P_PIDFD is supported and waitid correctly
    ///     reported that we don't have a child with the same selfPidfd;
    /// - EINVAL: in this case we know P_PIDFD is not supported because it does not
    ///     recognize the `P_PIDFD` type
    errno = 0
    waitid(idtype_t(UInt32(P_PIDFD)), id_t(selfPidfd), &siginfo, WEXITED | WNOWAIT)
    return errno == ECHILD
}

#endif // canImport(Glibc) || canImport(Android) || canImport(Musl)
