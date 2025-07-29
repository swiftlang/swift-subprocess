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

public struct AsyncBufferSequence: AsyncSequence, @unchecked Sendable {
    public typealias Failure = any Swift.Error
    public typealias Element = Buffer

    #if canImport(Darwin)
    internal typealias DiskIO = DispatchIO
    #elseif canImport(WinSDK)
    internal typealias DiskIO = HANDLE
    #else
    internal typealias DiskIO = FileDescriptor
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
            let data = try await AsyncIO.shared.read(
                from: self.diskIO,
                upTo: readBufferSize
            )
            guard let data else {
                // We finished reading. Close the file descriptor now
                #if canImport(Darwin)
                try _safelyClose(.dispatchIO(self.diskIO))
                #elseif canImport(WinSDK)
                try _safelyClose(.handle(self.diskIO))
                #else
                try _safelyClose(.fileDescriptor(self.diskIO))
                #endif
                return nil
            }
            let createdBuffers = Buffer.createFrom(data)
            // Most (all?) cases there should be only one buffer
            // because DispatchData are mostly contiguous
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

    // [New API: 0.0.1]
    public func lines<Encoding: _UnicodeEncoding>(
        encoding: Encoding.Type = UTF8.self,
        bufferingPolicy: LineSequence<Encoding>.BufferingPolicy = .maxLineLength(128 * 1024)
    ) -> LineSequence<Encoding> {
        return LineSequence(underlying: self, encoding: encoding, bufferingPolicy: bufferingPolicy)
    }
}

// MARK: - LineSequence
extension AsyncBufferSequence {
    // [New API: 0.0.1]
    public struct LineSequence<Encoding: _UnicodeEncoding>: AsyncSequence, Sendable {
        public typealias Element = String

        private let base: AsyncBufferSequence
        private let bufferingPolicy: BufferingPolicy

        public struct AsyncIterator: AsyncIteratorProtocol {
            public typealias Element = String

            private var source: AsyncBufferSequence.AsyncIterator
            private var buffer: [Encoding.CodeUnit]
            private var underlyingBuffer: [Encoding.CodeUnit]
            private var leftover: Encoding.CodeUnit?
            private var eofReached: Bool
            private let bufferingPolicy: BufferingPolicy

            internal init(
                underlyingIterator: AsyncBufferSequence.AsyncIterator,
                bufferingPolicy: BufferingPolicy
            ) {
                self.source = underlyingIterator
                self.buffer = []
                self.underlyingBuffer = []
                self.leftover = nil
                self.eofReached = false
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
                    #if canImport(Darwin)
                    // Unfortunately here we _have to_ copy the bytes out because
                    // DispatchIO (rightfully) reuses buffer, which means `buffer.data`
                    // has the same address on all iterations, therefore we can't directly
                    // create the result array from buffer.data

                    // Calculate how many CodePoint elements we have
                    let elementCount = buffer.data.count / MemoryLayout<Encoding.CodeUnit>.stride

                    // Create array by copying from the buffer reinterpreted as CodePoint
                    let result: Array<Encoding.CodeUnit> = buffer.data.withUnsafeBytes { ptr -> Array<Encoding.CodeUnit> in
                        return Array(
                            UnsafeBufferPointer(start: ptr.baseAddress?.assumingMemoryBound(to: Encoding.CodeUnit.self), count: elementCount)
                        )
                    }
                    #else
                    // Cast data to CodeUnit type
                    let result = buffer.withUnsafeBytes { ptr in
                        return ptr.withMemoryRebound(to: Encoding.CodeUnit.self) { codeUnitPtr in
                            return Array(codeUnitPtr)
                        }
                    }
                    #endif
                    return result.isEmpty ? nil : result
                }

                func yield() -> String? {
                    defer {
                        self.buffer.removeAll(keepingCapacity: true)
                    }
                    if self.buffer.isEmpty {
                        return nil
                    }
                    return String(decoding: self.buffer, as: Encoding.self)
                }

                func nextFromSource() async throws -> Encoding.CodeUnit? {
                    if underlyingBuffer.isEmpty {
                        guard let buf = try await loadBuffer() else {
                            return nil
                        }
                        underlyingBuffer = buf
                    }
                    return underlyingBuffer.removeFirst()
                }

                func nextCodeUnit() async throws -> Encoding.CodeUnit? {
                    defer { leftover = nil }
                    if let leftover = leftover {
                        return leftover
                    }
                    return try await nextFromSource()
                }

                // https://en.wikipedia.org/wiki/Newline#Unicode
                let lineFeed            = Encoding.CodeUnit(0x0A)
                /// let verticalTab     = Encoding.CodeUnit(0x0B)
                /// let formFeed        = Encoding.CodeUnit(0x0C)
                let carriageReturn      = Encoding.CodeUnit(0x0D)
                // carriageReturn + lineFeed
                let newLine1: Encoding.CodeUnit
                let newLine2: Encoding.CodeUnit
                let lineSeparator1: Encoding.CodeUnit
                let lineSeparator2: Encoding.CodeUnit
                let lineSeparator3: Encoding.CodeUnit
                let paragraphSeparator1: Encoding.CodeUnit
                let paragraphSeparator2: Encoding.CodeUnit
                let paragraphSeparator3: Encoding.CodeUnit
                switch Encoding.CodeUnit.self {
                case is UInt8.Type:
                    newLine1            = Encoding.CodeUnit(0xC2)
                    newLine2            = Encoding.CodeUnit(0x85)

                    lineSeparator1      = Encoding.CodeUnit(0xE2)
                    lineSeparator2      = Encoding.CodeUnit(0x80)
                    lineSeparator3      = Encoding.CodeUnit(0xA8)

                    paragraphSeparator1 = Encoding.CodeUnit(0xE2)
                    paragraphSeparator2 = Encoding.CodeUnit(0x80)
                    paragraphSeparator3 = Encoding.CodeUnit(0xA9)
                case is UInt16.Type, is UInt32.Type:
                    // UTF16 and UTF32 use one byte for all
                    newLine1            = Encoding.CodeUnit(0x0085)
                    newLine2            = Encoding.CodeUnit(0x0085)

                    lineSeparator1      = Encoding.CodeUnit(0x2028)
                    lineSeparator2      = Encoding.CodeUnit(0x2028)
                    lineSeparator3      = Encoding.CodeUnit(0x2028)

                    paragraphSeparator1 = Encoding.CodeUnit(0x2029)
                    paragraphSeparator2 = Encoding.CodeUnit(0x2029)
                    paragraphSeparator3 = Encoding.CodeUnit(0x2029)
                default:
                    fatalError("Unknown encoding type \(Encoding.self)")
                }

                while let first = try await nextCodeUnit() {
                    // Throw if we exceed max line length
                    if case .maxLineLength(let maxLength) = self.bufferingPolicy, buffer.count >= maxLength {
                        throw SubprocessError(
                            code: .init(.streamOutputExceedsLimit(maxLength)),
                            underlyingError: nil
                        )
                    }

                    buffer.append(first)
                    switch first {
                    case carriageReturn:
                        // Swallow up any subsequent LF
                        guard let next = try await nextFromSource() else {
                            return yield() // if we ran out of bytes, the last byte was a CR
                        }
                        buffer.append(next)
                        guard next == lineFeed else {
                            // if the next character was not an LF, save it for the next iteration and still return a line
                            leftover = buffer.removeLast()
                            return yield()
                        }
                        return yield()
                    case newLine1 where Encoding.CodeUnit.self is UInt8.Type: // this may be used to compose other UTF8 characters
                        guard let next = try await nextFromSource() else {
                            // technically invalid UTF8 but it should be repaired to "\u{FFFD}"
                            return yield()
                        }
                        buffer.append(next)
                        guard next == newLine2 else {
                            continue
                        }
                        return yield()
                    case lineSeparator1 where Encoding.CodeUnit.self is UInt8.Type,
                        paragraphSeparator1 where Encoding.CodeUnit.self is UInt8.Type:
                        // Try to read: 80 [A8 | A9].
                        // If we can't, then we put the byte in the buffer for error correction
                        guard let next = try await nextFromSource() else {
                            return yield()
                        }
                        buffer.append(next)
                        guard next == lineSeparator2 || next == paragraphSeparator2 else {
                            continue
                        }
                        guard let fin = try await nextFromSource() else {
                            return yield()
                        }
                        buffer.append(fin)
                        guard fin == lineSeparator3 || fin == paragraphSeparator3 else {
                            continue
                        }
                        return yield()
                    case lineFeed ..< carriageReturn, newLine1, lineSeparator1, paragraphSeparator1:
                        return yield()
                    default:
                        continue
                    }
                }

                // Don't emit an empty newline when there is no more content (e.g. end of file)
                if !buffer.isEmpty {
                    return yield()
                }
                return nil
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

extension AsyncBufferSequence.LineSequence {
    public enum BufferingPolicy: Sendable {
        /// Continue to add to the buffer, without imposing a limit
        /// on the number of buffered elements (line length).
        case unbounded
        /// Impose a max buffer size (line length) limit.
        /// Subprocess **will throw an error** if the number of buffered
        /// elements (line length) exceeds the limit
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
@preconcurrency import WinSDK
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
