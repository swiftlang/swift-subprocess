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

#if canImport(Synchronization)
import Synchronization
#else

#if canImport(os)
internal import os
#if canImport(C.os.lock)
internal import C.os.lock
#endif
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif  // canImport(os)

#endif  // canImport(Synchronization)

internal protocol AtomicBoxProtocol: ~Copyable, Sendable {
    borrowing func bitwiseXor(
        _ operand: OutputConsumptionState
    ) -> OutputConsumptionState

    init(_ initialValue: OutputConsumptionState)
}

internal struct AtomicBox<Wrapped: AtomicBoxProtocol & ~Copyable>: ~Copyable, Sendable {

    private let storage: Wrapped

    internal init(_ storage: consuming Wrapped) {
        self.storage = storage
    }

    borrowing internal func bitwiseXor(
        _ operand: OutputConsumptionState
    ) -> OutputConsumptionState {
        return self.storage.bitwiseXor(operand)
    }
}

#if canImport(Synchronization)
@available(macOS 15, *)
extension Atomic: AtomicBoxProtocol where Value == UInt8 {
    borrowing func bitwiseXor(
        _ operand: OutputConsumptionState
    ) -> OutputConsumptionState {
        let newState = self.bitwiseXor(
            operand.rawValue,
            ordering: .relaxed
        ).newValue
        return OutputConsumptionState(rawValue: newState)
    }

    init(_ initialValue: OutputConsumptionState) {
        self = Atomic(initialValue.rawValue)
    }
}
#else
// Fallback to LockedState if `Synchronization` is not available
extension LockedState: AtomicBoxProtocol where State == OutputConsumptionState {
    init(_ initialValue: OutputConsumptionState) {
        self.init(initialState: initialValue)
    }

    func bitwiseXor(
        _ operand: OutputConsumptionState
    ) -> OutputConsumptionState {
        return self.withLock { state in
            state = OutputConsumptionState(rawValue: state.rawValue ^ operand.rawValue)
            return state
        }
    }
}

// MARK: - LockState
internal struct LockedState<State>: ~Copyable {

    // Internal implementation for a cheap lock to aid sharing code across platforms
    private struct _Lock {
        #if canImport(os)
        typealias Primitive = os_unfair_lock
        #elseif os(FreeBSD) || os(OpenBSD)
        typealias Primitive = pthread_mutex_t?
        #elseif canImport(Bionic) || canImport(Glibc) || canImport(Musl)
        typealias Primitive = pthread_mutex_t
        #elseif canImport(WinSDK)
        typealias Primitive = SRWLOCK
        #elseif os(WASI)
        // WASI is single-threaded, so we don't need a lock.
        typealias Primitive = Void
        #endif

        typealias PlatformLock = UnsafeMutablePointer<Primitive>
        var _platformLock: PlatformLock

        fileprivate static func initialize(_ platformLock: PlatformLock) {
            #if canImport(os)
            platformLock.initialize(to: os_unfair_lock())
            #elseif canImport(Bionic) || canImport(Glibc) || canImport(Musl)
            pthread_mutex_init(platformLock, nil)
            #elseif canImport(WinSDK)
            InitializeSRWLock(platformLock)
            #elseif os(WASI)
            // no-op
            #else
            #error("LockedState._Lock.initialize is unimplemented on this platform")
            #endif
        }

        fileprivate static func deinitialize(_ platformLock: PlatformLock) {
            #if canImport(Bionic) || canImport(Glibc) || canImport(Musl)
            pthread_mutex_destroy(platformLock)
            #endif
            platformLock.deinitialize(count: 1)
        }

        static fileprivate func lock(_ platformLock: PlatformLock) {
            #if canImport(os)
            os_unfair_lock_lock(platformLock)
            #elseif canImport(Bionic) || canImport(Glibc) || canImport(Musl)
            pthread_mutex_lock(platformLock)
            #elseif canImport(WinSDK)
            AcquireSRWLockExclusive(platformLock)
            #elseif os(WASI)
            // no-op
            #else
            #error("LockedState._Lock.lock is unimplemented on this platform")
            #endif
        }

        static fileprivate func unlock(_ platformLock: PlatformLock) {
            #if canImport(os)
            os_unfair_lock_unlock(platformLock)
            #elseif canImport(Bionic) || canImport(Glibc) || canImport(Musl)
            pthread_mutex_unlock(platformLock)
            #elseif canImport(WinSDK)
            ReleaseSRWLockExclusive(platformLock)
            #elseif os(WASI)
            // no-op
            #else
            #error("LockedState._Lock.unlock is unimplemented on this platform")
            #endif
        }
    }

    private class _Buffer: ManagedBuffer<State, _Lock.Primitive> {
        deinit {
            withUnsafeMutablePointerToElements {
                _Lock.deinitialize($0)
            }
        }
    }

    private let _buffer: ManagedBuffer<State, _Lock.Primitive>

    package init(initialState: State) {
        _buffer = _Buffer.create(
            minimumCapacity: 1,
            makingHeaderWith: { buf in
                buf.withUnsafeMutablePointerToElements {
                    _Lock.initialize($0)
                }
                return initialState
            }
        )
    }

    package func withLock<T>(_ body: @Sendable (inout State) throws -> T) rethrows -> T {
        try withLockUnchecked(body)
    }

    package func withLockUnchecked<T>(_ body: (inout State) throws -> T) rethrows -> T {
        try _buffer.withUnsafeMutablePointers { state, lock in
            _Lock.lock(lock)
            defer { _Lock.unlock(lock) }
            return try body(&state.pointee)
        }
    }

    // Ensures the managed state outlives the locked scope.
    package func withLockExtendingLifetimeOfState<T>(_ body: @Sendable (inout State) throws -> T) rethrows -> T {
        try _buffer.withUnsafeMutablePointers { state, lock in
            _Lock.lock(lock)
            return try withExtendedLifetime(state.pointee) {
                defer { _Lock.unlock(lock) }
                return try body(&state.pointee)
            }
        }
    }
}

extension LockedState where State == Void {
    internal init() {
        self.init(initialState: ())
    }

    internal func withLock<R: Sendable>(_ body: @Sendable () throws -> R) rethrows -> R {
        return try withLock { _ in
            try body()
        }
    }

    internal func lock() {
        _buffer.withUnsafeMutablePointerToElements { lock in
            _Lock.lock(lock)
        }
    }

    internal func unlock() {
        _buffer.withUnsafeMutablePointerToElements { lock in
            _Lock.unlock(lock)
        }
    }
}

extension LockedState: @unchecked Sendable where State: Sendable {}

#endif
