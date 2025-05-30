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
        private var buffer: [Buffer]

        internal init(diskIO: DiskIO) {
            self.diskIO = diskIO
            self.buffer = []
        }

        public mutating func next() async throws -> Buffer? {
            // If we have more left in buffer, use that
            guard self.buffer.isEmpty else {
                return self.buffer.removeFirst()
            }
            // Read more data
            let data = try await self.diskIO.read(
                upToLength: readBufferSize
            )
            guard let data = data else {
                // We finished reading. Close the file descriptor now
                #if os(Windows)
                try self.diskIO.close()
                #else
                self.diskIO.close()
                #endif
                return nil
            }
            let createdBuffers = Buffer.createFrom(data)
            // Most (all?) cases there should be only one buffer
            // because DispatchData are motsly contiguous
            if _fastPath(createdBuffers.count == 1) {
                // No need to push to the stack
                return createdBuffers[0]
            }
            self.buffer = createdBuffers
            return self.buffer.removeFirst()
        }
    }

    private let diskIO: DiskIO

    internal init(diskIO: DiskIO) {
        self.diskIO = diskIO
    }

    public func makeAsyncIterator() -> Iterator {
        return Iterator(diskIO: self.diskIO)
    }

    public func lines<Encoding: _UnicodeEncoding>(
        encoding: Encoding.Type = UTF8.self,
        bufferingPolicy: LineSequence<Encoding>.BufferingPolicy = .unbounded
    ) -> LineSequence<Encoding> {
        return LineSequence(underlying: self, encoding: encoding, bufferingPolicy: bufferingPolicy)
    }
}

// MARK: - LineSequence
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension AsyncBufferSequence {
    public struct LineSequence<Encoding: _UnicodeEncoding>: AsyncSequence, Sendable {
        public typealias Element = String

        private let base: AsyncBufferSequence
        private let bufferingPolicy: BufferingPolicy

        public struct AsyncIterator: AsyncIteratorProtocol {
            public typealias Element = String

            private var source: AsyncBufferSequence.AsyncIterator
            private var buffer: [Encoding.CodeUnit]
            private var eofReached: Bool
            private var startIndex: Int
            private let bufferingPolicy: BufferingPolicy

            internal init(
                underlyingIterator: AsyncBufferSequence.AsyncIterator,
                bufferingPolicy: BufferingPolicy
            ) {
                self.source = underlyingIterator
                self.buffer = []
                self.eofReached = false
                self.startIndex = 0
                self.bufferingPolicy = bufferingPolicy
            }

            public mutating func next() async throws -> String? {

                func loadBuffer() async throws -> [Encoding.CodeUnit]? {
                    guard !self.eofReached else {
                        return nil
                    }

                    guard let buffer = try await self.source.next() else {
                        self.eofReached = true
                        return nil
                    }
                    #if os(Windows)
                    // Cast data to CodeUnit type
                    let result = buffer.withUnsafeBytes { ptr in
                        return Array(
                            UnsafeBufferPointer<Encoding.CodeUnit>(
                                start: ptr.bindMemory(to: Encoding.CodeUnit.self).baseAddress!,
                                count: ptr.count / MemoryLayout<Encoding.CodeUnit>.size
                            )
                        )
                    }
                    #else
                    // Unfortunitely here we _have to_ copy the bytes out because
                    // DisptachIO (rightfully) reuses buffer, which means `buffer.data`
                    // has the same address on all iterations, therefore we can't directly
                    // create the result array from buffer.data
                    let temporary = UnsafeMutableBufferPointer<Encoding.CodeUnit>.allocate(
                        capacity: buffer.data.count
                    )
                    defer { temporary.deallocate() }
                    let actualBytesCopied = buffer.data.copyBytes(
                        to: temporary,
                        count: buffer.data.count
                    )

                    // Calculate how many CodePoint elements we have
                    let elementCount = actualBytesCopied / MemoryLayout<Encoding.CodeUnit>.stride

                    // Create array by copying from the buffer reinterpreted as CodePoint
                    let result: Array<Encoding.CodeUnit> = Array(
                        UnsafeBufferPointer(start: temporary.baseAddress, count: elementCount)
                    )
                    #endif
                    return result.isEmpty ? nil : result
                }

                func yield(at endIndex: Int) -> String? {
                    defer {
                        self.buffer.removeFirst(endIndex)
                        self.startIndex = 0
                    }
                    if self.buffer.isEmpty {
                        return nil
                    }
                    return String(decoding: self.buffer[0 ..< endIndex], as: Encoding.self)
                }

                // https://en.wikipedia.org/wiki/Newline#Unicode
                let lineFeed            = Encoding.CodeUnit(0x0A)
                /// let verticalTab     = Encoding.CodeUnit(0x0B)
                /// let formFeed        = Encoding.CodeUnit(0x0C)
                let carriageReturn      = Encoding.CodeUnit(0x0D)
                // carriageReturn + lineFeed
                let newLine: Encoding.CodeUnit
                let lineSeparator: Encoding.CodeUnit
                let paragraphSeparator: Encoding.CodeUnit
                switch Encoding.CodeUnit.self {
                case is UInt8.Type:
                    newLine             = Encoding.CodeUnit(0xC2) // 0xC2 0x85
                    lineSeparator       = Encoding.CodeUnit(0xE2) // 0xE2 0x80 0xA8
                    paragraphSeparator  = Encoding.CodeUnit(0xE2) // 0xE2 0x80 0xA9
                case is UInt16.Type, is UInt32.Type:
                    newLine             = Encoding.CodeUnit(0x0085)
                    lineSeparator       = Encoding.CodeUnit(0x2028)
                    paragraphSeparator  = Encoding.CodeUnit(0x2029)
                default:
                    fatalError("Unknown encoding type \(Encoding.self)")
                }

                while true {
                    // Step 1: Load more buffer if needed
                    if self.startIndex >= self.buffer.count {
                        guard let nextBuffer = try await loadBuffer() else {
                            // We have no more data
                            // Return the remaining data
                            return yield(at: self.buffer.count)
                        }
                        self.buffer += nextBuffer
                    }
                    // Step 2: Iterate through buffer to find next line
                    var currentIndex: Int = self.startIndex
                    for index in self.startIndex ..< self.buffer.count {
                        currentIndex = index
                        // Early return if we exceed max line length
                        if case .maxLineLength(let maxLength) = self.bufferingPolicy,
                           currentIndex >= maxLength {
                            return yield(at: currentIndex)
                        }
                        let byte = self.buffer[currentIndex]
                        switch byte {
                        case carriageReturn:
                            // Swallow any subsequent lineFeed if there is one
                            var targetIndex = currentIndex
                            if (currentIndex + 1) < self.buffer.count, self.buffer[currentIndex + 1] == lineFeed {
                                targetIndex = currentIndex + 1
                            }
                            guard let result = yield(at: targetIndex + 1) else {
                                continue
                            }
                            return result
                        case lineFeed ..< carriageReturn:
                            guard let result = yield(at: currentIndex + 1) else {
                                continue
                            }
                            return result
                        case newLine:
                            var targetIndex = currentIndex
                            if Encoding.CodeUnit.self is UInt8.Type {
                                // For UTF8, look for the next 0x85 byte
                                guard (targetIndex + 1) < self.buffer.count,
                                      self.buffer[targetIndex + 1] == Encoding.CodeUnit(0x85) else {
                                    // Not a valid new ine. Keep looking
                                    continue
                                }
                                // Swallow 0x85 byte
                                targetIndex += 1
                            }
                            guard let result = yield(at: targetIndex + 1) else {
                                continue
                            }
                            return result
                        case lineSeparator, paragraphSeparator:
                            var targetIndex = currentIndex
                            if Encoding.CodeUnit.self is UInt8.Type {
                                // For UTF8, look for the next 0x80 byte
                                guard (targetIndex + 1) < self.buffer.count,
                                      self.buffer[targetIndex + 1] == Encoding.CodeUnit(0x80) else {
                                    // Not a valid new ine. Keep looking
                                    continue
                                }
                                // Swallow 0x80 byte
                                targetIndex += 1
                                // Look for the final 0xA8 (lineSeparator) or 0xA9 (paragraphSeparator)
                                guard (targetIndex + 1) < self.buffer.count,
                                      (self.buffer[targetIndex + 1] == Encoding.CodeUnit(0xA8) ||
                                       self.buffer[targetIndex + 1] == Encoding.CodeUnit(0xA9)) else {
                                    // Not a valid new ine. Keep looking
                                    continue
                                }
                                // Swallow 0xA8 (or 0xA9) byte
                                targetIndex += 1
                            }
                            guard let result = yield(at: targetIndex + 1) else {
                                continue
                            }
                            return result
                        default:
                            // Keep searching
                            continue
                        }
                    }
                    // There is no new line in the buffer. Load more buffer and try again
                    self.startIndex = currentIndex + 1
                }
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            return AsyncIterator(
                underlyingIterator: self.base.makeAsyncIterator(),
                bufferingPolicy: self.bufferingPolicy
            )
        }

        internal init(
            underlying: AsyncBufferSequence,
            encoding: Encoding.Type,
            bufferingPolicy: BufferingPolicy
        ) {
            self.base = underlying
            self.bufferingPolicy = bufferingPolicy
        }
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension AsyncBufferSequence.LineSequence {
    public enum BufferingPolicy: Sendable {
        /// Continue to add to the buffer, without imposing a limit
        /// on the number of buffered elements (line length).
        case unbounded
        /// Impose a max buffer size (line length) limit.
        /// When using this policy, `LineSequence` will return a line if:
        /// - A newline character is encountered (standard behavior)
        /// - The current line in the buffer reaches or exceeds the specified maximum length
        case maxLineLength(Int)
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
