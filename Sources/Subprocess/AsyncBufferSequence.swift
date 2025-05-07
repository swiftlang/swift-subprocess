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

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

#if !os(Windows)
internal import Dispatch
#endif

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public struct AsyncBufferSequence: AsyncSequence, Sendable {
    public typealias Failure = any Swift.Error
    public typealias Element = Buffer

    #if os(Windows)
    internal typealias DiskIO = FileDescriptor
    #else
    internal typealias DiskIO = DispatchIO
    #endif

    @_nonSendable
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = Buffer

        private let diskIO: DiskIO
        private var buffer: [UInt8]
        private var currentPosition: Int
        private var finished: Bool

        internal init(diskIO: DiskIO) {
            self.diskIO = diskIO
            self.buffer = []
            self.currentPosition = 0
            self.finished = false
        }

        public func next() async throws -> Buffer? {
            let data = try await self.diskIO.readChunk(
                upToLength: readBufferSize
            )
            if data == nil {
                // We finished reading. Close the file descriptor now
                #if os(Windows)
                try self.diskIO.close()
                #else
                self.diskIO.close()
                #endif
                return nil
            }
            return data
        }
    }

    private let diskIO: DiskIO

    internal init(diskIO: DiskIO) {
        self.diskIO = diskIO
    }

    public func makeAsyncIterator() -> Iterator {
        return Iterator(diskIO: self.diskIO)
    }
}

// MARK: - Page Size
import _SubprocessCShims

#if canImport(Darwin)
import Darwin
internal import MachO.dyld

private let _pageSize: Int = {
    Int(_subprocess_vm_size())
}()
#elseif canImport(WinSDK)
import WinSDK
private let _pageSize: Int = {
    var sysInfo: SYSTEM_INFO = SYSTEM_INFO()
    GetSystemInfo(&sysInfo)
    return Int(sysInfo.dwPageSize)
}()
#elseif os(WASI)
// WebAssembly defines a fixed page size
private let _pageSize: Int = 65_536
#elseif canImport(Android)
@preconcurrency import Android
private let _pageSize: Int = Int(getpagesize())
#elseif canImport(Glibc)
@preconcurrency import Glibc
private let _pageSize: Int = Int(getpagesize())
#elseif canImport(Musl)
@preconcurrency import Musl
private let _pageSize: Int = Int(getpagesize())
#elseif canImport(C)
private let _pageSize: Int = Int(getpagesize())
#endif  // canImport(Darwin)

@inline(__always)
internal var readBufferSize: Int {
    return _pageSize
}
