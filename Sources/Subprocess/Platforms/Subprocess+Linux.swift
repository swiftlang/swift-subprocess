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

#if canImport(Glibc)
import Glibc
let _subprocess_read = Glibc.read
let _subprocess_write = Glibc.write
let _subprocess_close = Glibc.close
#elseif canImport(Android)
import Android
let _subprocess_read = Android.read
let _subprocess_write = Android.write
let _subprocess_close = Android.close
#elseif canImport(Musl)
import Musl
let _subprocess_read = Musl.read
let _subprocess_write = Musl.write
let _subprocess_close = Musl.close
#endif

#if os(Linux) || os(Android)

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

internal import Dispatch

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
internal func monitorProcessTermination(
    for processIdentifier: ProcessIdentifier
) async throws(SubprocessError) -> TerminationStatus {
    return try await _castError {
        return try await withCheckedThrowingContinuation { continuation in
            let status = _processMonitorState.withLock { state -> Result<TerminationStatus, SubprocessError>? in
                switch state {
                case .notStarted:
                    let error = SubprocessError(
                        code: .init(.failedToMonitorProcess),
                        underlyingError: nil
                    )
                    return .failure(error)
                case .failed(let error):
                    return .failure(error)
                case .started(let storage):
                    // pidfd is only supported on Linux kernel 5.4 and above
                    // On older releases, use signalfd so we do not need
                    // to register anything with epoll
                    if processIdentifier.processDescriptor > 0 {
                        // Register processDescriptor with epoll
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
                            let error = SubprocessError(
                                code: .init(.failedToMonitorProcess),
                                underlyingError: Errno(rawValue: epollErrno)
                            )
                            return .failure(error)
                        }
                        // Now save the registration
                        var newState = storage
                        newState.continuations[processIdentifier.processDescriptor] = continuation
                        state = .started(newState)
                        // No state to resume
                        return nil
                    } else {
                        // Fallback to using signal handler directly on older Linux kernels
                        // Since Linux coalesce signals, it's possible by the time we request
                        // monitoring the process has already exited. Check to make sure that
                        // is not the case and only save continuation then.
                        switch Result(catching: { () throws(Errno) -> TerminationStatus? in try processIdentifier.reap() }) {
                        case let .success(status?):
                            return .success(status)
                        case .success(nil):
                            // Save this continuation to be called by signal handler
                            var newState = storage
                            newState.continuations[processIdentifier.value] = continuation
                            state = .started(newState)
                            return nil
                        case let .failure(underlyingError):
                            let error = SubprocessError(
                                code: .init(.failedToMonitorProcess),
                                underlyingError: underlyingError
                            )
                            return .failure(error)
                        }
                    }
                }
            }

            if let status {
                continuation.resume(with: status)
            }
        }
    }
}

#if canImport(Musl)
extension pthread_t: @retroactive @unchecked Sendable {}
#endif

private enum ProcessMonitorState {
    struct Storage {
        let epollFileDescriptor: CInt
        let shutdownFileDescriptor: CInt
        let monitorThread: pthread_t
        var continuations: [PlatformFileDescriptor: CheckedContinuation<TerminationStatus, any Error>]
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
    _ = _subprocess_write(storage.shutdownFileDescriptor, &one, MemoryLayout<UInt64>.size)
    // Cleanup the monitor thread
    pthread_join(storage.monitorThread, nil)
}

/// See the following page for the complete list of `async-signal-safe` functions
/// https://man7.org/linux/man-pages/man7/signal-safety.7.html
/// Only these functions can be used in the signal handler below
private func signalHandler(
    _ signalNumber: CInt,
    _ signalInfo: UnsafeMutablePointer<siginfo_t>?,
    _ context: UnsafeMutableRawPointer?
) {
    let savedErrno = errno
    var one: UInt8 = 1
    _ = _subprocess_write(_signalPipe.writeEnd, &one, 1)
    errno = savedErrno
}

private func monitorThreadFunc(context: MonitorThreadContext) {
    var events: [epoll_event] = Array(
        repeating: epoll_event(events: 0, data: epoll_data(fd: 0)),
        count: 256
    )
    var waitMask = sigset_t()
    sigemptyset(&waitMask)
    sigaddset(&waitMask, SIGCHLD)
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
            let error = SubprocessError(
                code: .init(.failedToMonitorProcess),
                underlyingError: Errno(rawValue: pwaitErrno)
            )
            let continuations = _processMonitorState.withLock { state -> [CheckedContinuation<TerminationStatus, any Error>] in
                let result: [CheckedContinuation<TerminationStatus, any Error>]
                if case .started(let storage) = state {
                    result = Array(storage.continuations.values)
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
                _ = _subprocess_read(context.shutdownFileDescriptor, &buf, MemoryLayout<UInt64>.size)
                break monitorLoop
            }

            // P_PIDFD requires Linux Kernel 5.4 and above
            if _waitProcessDescriptorSupported {
                _blockAndWaitForProcessDescriptor(targetFileDescriptor, context: context)
            } else {
                _reapAllKnownChildProcesses(targetFileDescriptor, context: context)
            }
        }
    }
}

private let setup: () = {
    func _reportFailureWithErrno(_ number: CInt) {
        let error = SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: Errno(rawValue: number)
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
        } catch {
            var underlying: Errno? = nil
            if let err = error as? Errno {
                underlying = err
            }
            pipeCreationError = SubprocessError(
                code: .init(.failedToMonitorProcess),
                underlyingError: underlying
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
                SubprocessError(
                    code: .init(.failedToMonitorProcess),
                    underlyingError: error
                ))
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

private func _blockAndWaitForProcessDescriptor(_ pidfd: CInt, context: MonitorThreadContext) {
    var terminationStatus = Result(catching: { () throws(Errno) in
        try TerminationStatus(_waitid(idtype: idtype_t(UInt32(P_PIDFD)), id: id_t(pidfd), flags: WEXITED))
    }).mapError { underlyingError in
        SubprocessError(
            code: .init(.failedToMonitorProcess),
            underlyingError: underlyingError
        )
    }

    // Remove this pidfd from epoll to prevent further notifications
    let rc = epoll_ctl(
        context.epollFileDescriptor,
        EPOLL_CTL_DEL,
        pidfd,
        nil
    )
    if rc != 0 {
        let epollErrno = errno
        terminationStatus = .failure(
            SubprocessError(
                code: .init(.failedToMonitorProcess),
                underlyingError: Errno(rawValue: epollErrno)
            ))
    }
    // Notify the continuation
    let continuation = _processMonitorState.withLock { state -> CheckedContinuation<TerminationStatus, any Error>? in
        guard case .started(let storage) = state,
            let continuation = storage.continuations[pidfd]
        else {
            return nil
        }
        // Remove registration
        var newStorage = storage
        newStorage.continuations.removeValue(forKey: pidfd)
        state = .started(newStorage)
        return continuation
    }
    continuation?.resume(with: terminationStatus)
}

// On older kernels, fall back to using signal handlers
private typealias ResultContinuation = (
    result: Result<TerminationStatus, SubprocessError>,
    continuation: CheckedContinuation<TerminationStatus, any Error>
)
private func _reapAllKnownChildProcesses(_ signalFd: CInt, context: MonitorThreadContext) {
    guard signalFd == _signalPipe.readEnd else {
        return
    }

    // Drain the signalFd
    var buffer: UInt8 = 0
    while _subprocess_read(signalFd, &buffer, 1) > 0 { /* noop, drain the pipe  */  }

    let resumingContinuations: [ResultContinuation] = _processMonitorState.withLock { state in
        guard case .started(let storage) = state else {
            return []
        }
        var updatedContinuations = storage.continuations
        var results: [ResultContinuation] = []
        // Since Linux coalesce signals, we need to loop through all known child process
        // to check if they exited.
        loop: for (knownChildPID, continuation) in storage.continuations {
            let terminationStatus: Result<TerminationStatus, SubprocessError>
            switch Result(catching: { () throws(Errno) -> TerminationStatus? in try _reap(pid: knownChildPID) }) {
            case let .success(status?):
                terminationStatus = .success(status)
            case .success(nil):
                // Move on to the next child
                continue loop
            case let .failure(error):
                terminationStatus = .failure(
                    SubprocessError(
                        code: .init(.failedToMonitorProcess),
                        underlyingError: error
                    ))
            }
            results.append((result: terminationStatus, continuation: continuation))
            // Now we have the exit code, remove saved continuations
            updatedContinuations.removeValue(forKey: knownChildPID)
        }
        var updatedStorage = storage
        updatedStorage.continuations = updatedContinuations
        state = .started(updatedStorage)

        return results
    }
    // Resume continuations
    for c in resumingContinuations {
        c.continuation.resume(with: c.result)
    }
}

internal func _isWaitprocessDescriptorSupported() -> Bool {
    // waitid(P_PIDFD) is only supported on Linux kernel 5.4 and above
    // Prob whether the current system supports it by calling it with self pidfd
    // and checking for EINVAL (waitid sets errno to EINVAL if it does not
    // recognize the id type).
    var siginfo = siginfo_t()
    let selfPidfd = _pidfd_open(getpid())
    if selfPidfd < 0 {
        // If we can not retrieve pidfd, the system does not support waitid(P_PIDFD)
        return false
    }
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
