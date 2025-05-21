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

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public struct AsyncBufferSequence: AsyncSequence, Sendable {
    public typealias Failure = any Swift.Error
    public typealias Element = SequenceOutput.Buffer

    @_nonSendable
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = SequenceOutput.Buffer
        internal typealias Stream = AsyncThrowingStream<TrackedPlatformDiskIO.StreamStatus, Swift.Error>

        private let diskIO: TrackedPlatformDiskIO
        private var buffer: [UInt8]
        private var currentPosition: Int
        private var finished: Bool
        private var streamIterator: Stream.AsyncIterator
        private let continuation: Stream.Continuation
        private var needsNextChunk: Bool

        internal init(diskIO: TrackedPlatformDiskIO) {
            self.diskIO = diskIO
            self.buffer = []
            self.currentPosition = 0
            self.finished = false
            let (stream, continuation) = AsyncThrowingStream<TrackedPlatformDiskIO.StreamStatus, Swift.Error>.makeStream()
            self.streamIterator = stream.makeAsyncIterator()
            self.continuation = continuation
            self.needsNextChunk = true
        }

        public mutating func next() async throws -> SequenceOutput.Buffer? {

            if needsNextChunk {
                diskIO.readChunk(upToLength: readBufferSize, continuation: continuation)
                needsNextChunk = false
            }

            if let status = try await streamIterator.next() {
                switch status {
                case .data(let data):
                    return data

                case .endOfChunk(let data):
                    needsNextChunk = true
                    return data

                case .endOfFile:
                    try self.diskIO.safelyClose()
                    return nil
                }
            } else {
                try self.diskIO.safelyClose()
                return nil
            }
        }
    }

    private let diskIO: TrackedPlatformDiskIO

    internal init(diskIO: TrackedPlatformDiskIO) {
        self.diskIO = diskIO
    }

    public func makeAsyncIterator() -> Iterator {
        return Iterator(diskIO: self.diskIO)
    }
}

extension TrackedPlatformDiskIO {
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
    internal enum StreamStatus {
        case data(SequenceOutput.Buffer)
        case endOfChunk(SequenceOutput.Buffer)
        case endOfFile
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
