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

#if canImport(Darwin)
internal func runOnBackgroundThread<Result>(
    _ body: @Sendable @escaping () throws -> Result
) async throws -> Result {
    let result = try await withCheckedThrowingContinuation { continuation in
        // On Darwin, use DispatchQueue directly
        DispatchQueue.global().async {
            do {
                let result = try body()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    return result
}
#else

#if canImport(WinSDK)
private typealias MutexType = CRITICAL_SECTION
private typealias ConditionType = CONDITION_VARIABLE
private typealias ThreadType = HANDLE
#else
private typealias MutexType = pthread_mutex_t
private typealias ConditionType = pthread_cond_t
private typealias ThreadType = pthread_t
#endif

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

    func withLock<R>(_ body: (inout [BackgroundWorkItem]) throws -> R) rethrows -> R {
        try withUnsafeUnderlyingLock { _, queue in
            try body(&queue)
        }
    }

    private func withUnsafeUnderlyingLock<R>(
        _ body: (UnsafeMutablePointer<MutexType>, inout [BackgroundWorkItem]) throws -> R
    ) rethrows -> R {
        #if canImport(WinSDK)
        EnterCriticalSection(self.mutex)
        defer {
            LeaveCriticalSection(self.mutex);
        }
        #else
        pthread_mutex_lock(self.mutex)
        defer {
            pthread_mutex_unlock(mutex)
        }
        #endif
        return try body(mutex, &queue)
    }

    // Only called in worker thread. Sleeps the thread if there's no more item
    func dequeue() -> BackgroundWorkItem? {
        return self.withUnsafeUnderlyingLock { mutex, queue in
            if queue.isEmpty {
                // Sleep the worker thread if there's no more work
                #if canImport(WinSDK)
                SleepConditionVariableCS(self.waitCondition, mutex, INFINITE)
                #else
                pthread_cond_wait(self.waitCondition, mutex)
                #endif
            }
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
            WakeConditionVariable(self.waitCondition);
            #else
            pthread_cond_signal(self.waitCondition)
            #endif
        }
    }

    func shutdown() {
        self.withLock { queue in
            queue.removeAll()
            #if canImport(WinSDK)
            WakeConditionVariable(self.waitCondition);
            #else
            pthread_cond_signal(self.waitCondition)
            #endif
        }
    }
}

private let _workQueue = WorkQueue()
private let _workQueueShutdownFlag: Atomic<UInt8> = Atomic(0)

// Okay to be unlocked global mutable because this value is only set once like dispatch_once
private nonisolated(unsafe) var _workerThread: Result<ThreadType, any Error> = .failure(SubprocessError(code: .init(.spawnFailed), underlyingError: nil))

private let setupWorkerThread: () = {
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
        _workerThread = .failure(error)
    }

    atexit {
        _shutdownWorkerThread()
    }
}()

private func _shutdownWorkerThread() {
    guard case .success(let thread) = _workerThread else {
        return
    }
    guard _workQueueShutdownFlag.add(1, ordering: .sequentiallyConsistent).newValue == 1 else {
        // We already shutdown this thread
        return
    }
    _workQueue.shutdown()
    #if canImport(WinSDK)
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
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

internal func runOnBackgroundThread<Result>(
    _ body: @Sendable @escaping () throws -> Result
) async throws -> Result {
    // Only executed once
    setupWorkerThread

    let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, any Error>) in
        let workItem = BackgroundWorkItem(body, continuation: continuation)
        _workQueue.enqueue(workItem)
    }
    return result
}

#endif

// MARK: - Thread Creation Primitives
#if canImport(Glibc) || canImport(Bionic) || canImport(Musl)
internal func pthread_create(
    _ body: @Sendable @escaping () -> ()
) throws(SubprocessError.UnderlyingError) -> pthread_t {
    final class Context {
        let body: @Sendable () -> ()
        init(body: @Sendable @escaping () -> Void) {
            self.body = body
        }
    }
    #if canImport(Glibc) || canImport(Musl)
    func proc(_ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        (Unmanaged<AnyObject>.fromOpaque(context!).takeRetainedValue() as! Context).body()
        return nil
    }
    #elseif canImport(Bionic)
    func proc(_ context: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        (Unmanaged<AnyObject>.fromOpaque(context).takeRetainedValue() as! Context).body()
        return context
    }
    #endif
    #if canImport(Glibc) || canImport(Bionic)
    var thread = pthread_t()
    #else
    var thread: pthread_t?
    #endif
    let rc = pthread_create(
        &thread,
        nil,
        proc,
        Unmanaged.passRetained(Context(body: body)).toOpaque()
    )
    if rc != 0 {
        throw SubprocessError.UnderlyingError(rawValue: rc)
    }
    #if canImport(Glibc) || canImport(Bionic)
    return thread
    #else
    return thread!
    #endif
}

#elseif canImport(WinSDK)
/// Microsoft documentation for `CreateThread` states:
/// > A thread in an executable that calls the C run-time library (CRT)
/// > should use the _beginthreadex and _endthreadex functions for
/// > thread management rather than CreateThread and ExitThread
internal func begin_thread_x(
    _ body: @Sendable @escaping () -> UInt32
) throws(SubprocessError.UnderlyingError) -> HANDLE {
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
          let threadHandle = HANDLE(bitPattern: threadHandleValue) else {
        // _beginthreadex uses errno instead of GetLastError()
        let capturedError = _subprocess_windows_get_errno()
        throw SubprocessError.UnderlyingError(rawValue: DWORD(capturedError))
    }

    return threadHandle
}
#endif

