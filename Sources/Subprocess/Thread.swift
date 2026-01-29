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

#if canImport(Darwin)
import Darwin
import os
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

internal import Dispatch
import _SubprocessCShims

#if canImport(Synchronization)
import Synchronization
#endif

#if canImport(WinSDK)
private typealias MutexType = CRITICAL_SECTION
private typealias ConditionType = CONDITION_VARIABLE
private typealias ThreadType = HANDLE
#else
private typealias MutexType = pthread_mutex_t
private typealias ConditionType = pthread_cond_t
private typealias ThreadType = pthread_t
#endif

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

internal func runOnBackgroundThread<Result: Sendable>(
    _ body: @Sendable @escaping () throws(SubprocessError) -> Result
) async throws(SubprocessError) -> Result {
    // Only executed once
    _setupWorkerThread

    return try await _castError {
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, any Error>) in
            let workItem = BackgroundWorkItem(body, continuation: continuation)
            _workQueue.enqueue(workItem)
        }
        return result
    }
}

private struct BackgroundWorkItem {
    private let work: @Sendable () -> Void

    init<Result>(
        _ body: @Sendable @escaping () throws -> Result,
        continuation: CheckedContinuation<Result, Error>
    ) {
        self.work = {
            do {
                let result = try body()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func run() {
        self.work()
    }
}

// We can't use Mutex directly here because we need the underlying `pthread_mutex_t` to be
// exposed so we can use it with `pthread_cond_wait`.
private final class WorkQueue: Sendable {
    private nonisolated(unsafe) var queue: [BackgroundWorkItem]
    internal nonisolated(unsafe) let mutex: UnsafeMutablePointer<MutexType>
    internal nonisolated(unsafe) let waitCondition: UnsafeMutablePointer<ConditionType>

    init() {
        self.queue = []
        self.mutex = UnsafeMutablePointer<MutexType>.allocate(capacity: 1)
        self.waitCondition = UnsafeMutablePointer<ConditionType>.allocate(capacity: 1)
        #if canImport(WinSDK)
        InitializeCriticalSection(self.mutex)
        InitializeConditionVariable(self.waitCondition)
        #else
        pthread_mutex_init(self.mutex, nil)
        pthread_cond_init(self.waitCondition, nil)
        #endif
    }

    func withLock<R>(_ body: (inout [BackgroundWorkItem]) -> R) -> R {
        withUnsafeUnderlyingLock { _, queue in
            body(&queue)
        }
    }

    private func withUnsafeUnderlyingLock<R>(
        condition: (inout [BackgroundWorkItem]) -> Bool = { _ in false },
        body: (UnsafeMutablePointer<MutexType>, inout [BackgroundWorkItem]) -> R
    ) -> R {
        #if canImport(WinSDK)
        EnterCriticalSection(self.mutex)
        defer {
            LeaveCriticalSection(self.mutex)
        }
        #else
        pthread_mutex_lock(self.mutex)
        defer {
            pthread_mutex_unlock(mutex)
        }
        #endif
        if condition(&queue) {
            #if canImport(WinSDK)
            SleepConditionVariableCS(self.waitCondition, mutex, INFINITE)
            #else
            pthread_cond_wait(self.waitCondition, mutex)
            #endif
        }
        return body(mutex, &queue)
    }

    // Only called in worker thread. Sleeps the thread if there's no more item
    func dequeue() -> BackgroundWorkItem? {
        return self.withUnsafeUnderlyingLock { queue in
            // Sleep the worker thread if there's no more work
            queue.isEmpty
        } body: { mutex, queue in
            guard !queue.isEmpty else {
                return nil
            }
            return queue.removeFirst()
        }
    }

    // Only called in parent thread. Signals wait condition to wake up worker thread
    func enqueue(_ workItem: BackgroundWorkItem) {
        self.withLock { queue in
            queue.append(workItem)
            #if canImport(WinSDK)
            WakeConditionVariable(self.waitCondition)
            #else
            pthread_cond_signal(self.waitCondition)
            #endif
        }
    }

    func shutdown() {
        self.withLock { queue in
            queue.removeAll()
            #if canImport(WinSDK)
            WakeConditionVariable(self.waitCondition)
            #else
            pthread_cond_signal(self.waitCondition)
            #endif
        }
    }
}

private let _workQueue = WorkQueue()
private let _workQueueShutdownFlag = AtomicCounter()

// Okay to be unlocked global mutable because this value is only set once like dispatch_once
private nonisolated(unsafe) var _workerThread: Result<ThreadType, SubprocessError> = .failure(SubprocessError(code: .init(.spawnFailed), underlyingError: nil))

private let _setupWorkerThread: () = {
    do {
        #if canImport(WinSDK)
        let workerThread = try begin_thread_x {
            while true {
                // This dequeue call will suspend the thread if there's no more work left
                guard let workItem = _workQueue.dequeue() else {
                    break
                }
                workItem.run()
            }
            return 0
        }
        #else
        let workerThread = try pthread_create {
            while true {
                // This dequeue call will suspend the thread if there's no more work left
                guard let workItem = _workQueue.dequeue() else {
                    break
                }
                workItem.run()
            }
        }
        #endif
        _workerThread = .success(workerThread)
    } catch {
        let subprocessError = SubprocessError(code: .init(.spawnFailed), underlyingError: error)
        _workerThread = .failure(subprocessError)
    }

    atexit {
        _shutdownWorkerThread()
    }
}()

private func _shutdownWorkerThread() {
    guard case .success(let thread) = _workerThread else {
        return
    }
    guard _workQueueShutdownFlag.addOne() == 1 else {
        // We already shutdown this thread
        return
    }
    _workQueue.shutdown()
    #if canImport(WinSDK)
    WaitForSingleObject(thread, INFINITE)
    CloseHandle(thread)
    DeleteCriticalSection(_workQueue.mutex)
    // We do not need to destroy CONDITION_VARIABLE
    #else
    pthread_join(thread, nil)
    pthread_mutex_destroy(_workQueue.mutex)
    pthread_cond_destroy(_workQueue.waitCondition)
    #endif
    _workQueue.mutex.deallocate()
    _workQueue.waitCondition.deallocate()
}

// MARK: - AtomicCounter

#if canImport(Darwin)
// Unfortunately on Darwin we cannot unconditionally use Atomic since it requires macOS 15
internal struct AtomicCounter: ~Copyable {
    private let storage: OSAllocatedUnfairLock<UInt8>

    internal init() {
        self.storage = .init(initialState: 0)
    }

    internal func addOne() -> UInt8 {
        return self.storage.withLock {
            $0 += 1
            return $0
        }
    }
}
#else
internal struct AtomicCounter: ~Copyable {

    private let storage: Atomic<UInt8>

    internal init() {
        self.storage = Atomic(0)
    }

    internal func addOne() -> UInt8 {
        return self.storage.add(1, ordering: .sequentiallyConsistent).newValue
    }
}
#endif

// MARK: - Thread Creation Primitives
#if canImport(WinSDK)
/// Microsoft documentation for `CreateThread` states:
/// > A thread in an executable that calls the C run-time library (CRT)
/// > should use the _beginthreadex and _endthreadex functions for
/// > thread management rather than CreateThread and ExitThread
internal func begin_thread_x(
    _ body: @Sendable @escaping () -> UInt32
) throws(SubprocessError.WindowsError) -> HANDLE {
    final class Context {
        let body: @Sendable () -> UInt32
        init(body: @Sendable @escaping () -> UInt32) {
            self.body = body
        }
    }

    func proc(_ context: UnsafeMutableRawPointer?) -> UInt32 {
        return Unmanaged<Context>.fromOpaque(context!).takeRetainedValue().body()
    }

    let threadHandleValue = _beginthreadex(
        nil,
        0,
        proc,
        Unmanaged.passRetained(Context(body: body)).toOpaque(),
        0,
        nil
    )
    guard threadHandleValue != 0,
        let threadHandle = HANDLE(bitPattern: threadHandleValue)
    else {
        // _beginthreadex uses errno instead of GetLastError()
        let capturedError = _subprocess_windows_get_errno()
        throw SubprocessError.WindowsError(rawValue: DWORD(capturedError))
    }

    return threadHandle
}
#else

internal func pthread_create(
    _ body: @Sendable @escaping () -> ()
) throws(Errno) -> pthread_t {
    final class Context {
        let body: @Sendable () -> ()
        init(body: @Sendable @escaping () -> Void) {
            self.body = body
        }
    }
    func proc(_ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        (Unmanaged<AnyObject>.fromOpaque(context!).takeRetainedValue() as! Context).body()
        return context
    }
    #if canImport(Glibc) || canImport(Bionic)
    var thread = pthread_t()
    #else
    var thread: pthread_t?
    #endif
    let rc = _subprocess_pthread_create(
        &thread,
        nil,
        proc,
        Unmanaged.passRetained(Context(body: body)).toOpaque()
    )
    if rc != 0 {
        throw Errno(rawValue: rc)
    }
    #if canImport(Glibc) || canImport(Bionic)
    return thread
    #else
    return thread!
    #endif
}

#endif // canImport(WinSDK)
