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

internal import Dispatch

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public struct AsyncBufferSequence: AsyncSequence, Sendable {
    public typealias Failure = any Swift.Error
    public typealias Element = SequenceOutput.Buffer

    @_nonSendable
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = SequenceOutput.Buffer

        private let diskIO: TrackedPlatformDiskIO
        private let bufferSize: Int
        private var buffer: [UInt8]
        private var currentPosition: Int
        private var finished: Bool
        private var streamIterator: AsyncThrowingStream<StreamStatus, Swift.Error>.AsyncIterator

        internal init(diskIO: TrackedPlatformDiskIO, bufferSize: Int) {
            self.diskIO = diskIO
            self.bufferSize = bufferSize
            self.buffer = []
            self.currentPosition = 0
            self.finished = false
            self.streamIterator = Self.createDataStream(with: diskIO.dispatchIO, bufferSize: bufferSize).makeAsyncIterator()
        }

        public mutating func next() async throws -> SequenceOutput.Buffer? {
            if let status = try await streamIterator.next() {
                switch status {
                case .data(let data):
                    return data

                case .endOfStream(let data):
                    streamIterator = Self.createDataStream(with: diskIO.dispatchIO, bufferSize: bufferSize).makeAsyncIterator()
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

        private enum StreamStatus {
            case data(SequenceOutput.Buffer)
            case endOfStream(SequenceOutput.Buffer)
            case endOfFile
        }

        private static func createDataStream(with dispatchIO: DispatchIO, bufferSize: Int) -> AsyncThrowingStream<StreamStatus, Swift.Error> {
            return AsyncThrowingStream<StreamStatus, Swift.Error> { continuation in
                dispatchIO.read(
                    offset: 0,
                    length: bufferSize,
                    queue: .global()
                ) { done, data, error in
                    if error != 0 {
                        continuation.finish(throwing: SubprocessError(
                            code: .init(.failedToReadFromSubprocess),
                            underlyingError: .init(rawValue: error)
                        ))
                        return
                    }

                    // Treat empty data and nil as the same
                    let buffer = data.map { $0.isEmpty ? nil : $0 } ?? nil
                    let status: StreamStatus

                    switch (buffer, done) {
                    case (.some(let data), false):
                        status = .data(SequenceOutput.Buffer(data: data))

                    case (.some(let data), true):
                        status = .endOfStream(SequenceOutput.Buffer(data: data))

                    case (nil, false):
                        return

                    case (nil, true):
                        status = .endOfFile
                    }

                    continuation.yield(status)

                    if done {
                        continuation.finish()
                    }
                }
            }
        }
    }

    private let diskIO: TrackedPlatformDiskIO
    private let bufferSize: Int

    internal init(diskIO: TrackedPlatformDiskIO, bufferSize: Int) {
        self.diskIO = diskIO
        self.bufferSize = bufferSize
    }

    public func makeAsyncIterator() -> Iterator {
        return Iterator(diskIO: self.diskIO, bufferSize: bufferSize)
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
