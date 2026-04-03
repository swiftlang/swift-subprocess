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
import System
#else
import SystemPackage
#endif

#if !os(Windows)
internal import Dispatch
#endif

/// An asynchronous sequence of buffers that streams output from a subprocess.
public struct AsyncBufferSequence: AsyncSequence, @unchecked Sendable {
    /// The failure type for the asynchronous sequence.
    public typealias Failure = any Swift.Error
    /// The element type for the asynchronous sequence.
    public typealias Element = Buffer

    #if SUBPROCESS_ASYNCIO_DISPATCH
    internal typealias DiskIO = DispatchIO
    #elseif canImport(WinSDK)
    internal typealias DiskIO = HANDLE
    #else
    internal typealias DiskIO = FileDescriptor
    #endif

    /// An iterator for ``AsyncBufferSequence``.
    public struct Iterator: AsyncIteratorProtocol {
        /// The element type for the iterator.
        public typealias Element = Buffer

        private let diskIO: DiskIO
        private let preferredBufferSize: Int
        private var buffer: [Buffer]

        internal init(diskIO: DiskIO, preferredBufferSize: Int?) {
            self.diskIO = diskIO
            self.buffer = []
            self.preferredBufferSize = preferredBufferSize ?? readBufferSize
        }

        /// Retrieves the next buffer in the sequence, or `nil` if the sequence ended.
        public mutating func next() async throws -> Buffer? {
            // If we have more left in buffer, use that
            guard self.buffer.isEmpty else {
                return self.buffer.removeFirst()
            }
            // Read more data
            let data = try await AsyncIO.shared.read(
                from: self.diskIO,
                upTo: self.preferredBufferSize
            )
            guard let data else {
                // We finished reading. Close the file descriptor now
                #if SUBPROCESS_ASYNCIO_DISPATCH
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
    private let preferredBufferSize: Int?

    internal init(diskIO: DiskIO, preferredBufferSize: Int?) {
        self.diskIO = diskIO
        self.preferredBufferSize = preferredBufferSize
    }

    /// Creates an iterator for this asynchronous sequence.
    public func makeAsyncIterator() -> Iterator {
        return Iterator(
            diskIO: self.diskIO,
            preferredBufferSize: self.preferredBufferSize
        )
    }

    /// Splits the buffer into strings using the specified separator.
    ///
    /// - Parameters:
    ///   - separator: The delimiter to split on. The default
    ///     value is `.lineBreaks`.
    ///   - bufferingPolicy: The strategy for handling
    ///     back-pressure. The default value is
    ///     `.maxLineLength(128 * 1024)`.
    /// - Returns: A ``StringSequence`` that iterates through
    ///   the buffer contents as strings.
    public func strings(
        separator: StringSequence<UTF8>.Separator = .lineBreaks,
        bufferingPolicy: StringSequence<UTF8>.BufferingPolicy = .maxLineLength(128 * 1024),
    ) -> StringSequence<UTF8> {
        return StringSequence(
            underlying: self,
            encoding: UTF8.self,
            bufferingPolicy: bufferingPolicy,
            separator: separator
        )
    }

    /// Splits the buffer into strings with the given encoding
    /// and separator.
    ///
    /// - Parameters:
    ///   - separator: The delimiter to split on. The default
    ///     value is `.lineBreaks`.
    ///   - bufferingPolicy: The strategy for handling
    ///     back-pressure. The default value is
    ///     `.maxLineLength(128 * 1024)`.
    ///   - encoding: The Unicode encoding to decode with.
    /// - Returns: A ``StringSequence`` that iterates through
    ///   the buffer contents as strings.
    public func strings<Encoding: _UnicodeEncoding>(
        separator: StringSequence<Encoding>.Separator = .lineBreaks,
        bufferingPolicy: StringSequence<Encoding>.BufferingPolicy = .maxLineLength(128 * 1024),
        as encoding: Encoding.Type,
    ) -> StringSequence<Encoding> {
        return StringSequence(
            underlying: self,
            encoding: encoding,
            bufferingPolicy: bufferingPolicy,
            separator: separator
        )
    }
}

@available(*, unavailable)
extension AsyncBufferSequence.Iterator: Sendable {}

// MARK: - StringSequence
extension AsyncBufferSequence {
    /// An asynchronous sequence of strings parsed from a buffer
    /// sequence.
    ///
    /// By default, the sequence splits on Unicode line break
    /// characters. You can supply a custom separator with the
    /// ``Separator/unicodeScalars(_:)`` factory method.
    ///
    /// The following Unicode characters are recognized as line
    /// breaks:
    /// ```
    /// LF:    Line Feed, U+000A
    /// VT:    Vertical Tab, U+000B
    /// FF:    Form Feed, U+000C
    /// CR:    Carriage Return, U+000D
    /// CR+LF: CR (U+000D) followed by LF (U+000A)
    /// NEL:   Next Line, U+0085
    /// LS:    Line Separator, U+2028
    /// PS:    Paragraph Separator, U+2029
    /// ```
    ///
    /// The separator characters aren't included in the returned
    /// strings, similar to how `.split(separator:)` works.
    ///
    /// When you use a custom separator created with
    /// ``Separator/unicodeScalars(_:)``, the sequence performs a
    /// code-unit-level comparison without Unicode normalization.
    /// See ``Separator/unicodeScalars(_:)`` for details.
    public struct StringSequence<Encoding: _UnicodeEncoding>: AsyncSequence, Sendable {
        /// The element type for the asynchronous sequence.
        public typealias Element = String

        private let base: AsyncBufferSequence
        private let bufferingPolicy: BufferingPolicy
        private let separator: Separator

        /// An iterator for ``StringSequence``.
        public struct AsyncIterator: AsyncIteratorProtocol {
            /// The element type for this Iterator.
            public typealias Element = String

            private var source: AsyncBufferSequence.AsyncIterator
            private var buffer: [Encoding.CodeUnit]
            private var underlyingBuffer: [Encoding.CodeUnit]
            private var underlyingBufferIndex: Array<Encoding.CodeUnit>.Index
            private var leftover: Encoding.CodeUnit?
            private var eofReached: Bool
            private let bufferingPolicy: BufferingPolicy
            private let separator: Separator
            private let separatorCodeUnits: [Encoding.CodeUnit]

            internal init(
                underlyingIterator: AsyncBufferSequence.AsyncIterator,
                bufferingPolicy: BufferingPolicy,
                separator: Separator
            ) {
                self.source = underlyingIterator
                self.buffer = []
                self.underlyingBuffer = []
                self.underlyingBufferIndex = self.underlyingBuffer.startIndex
                self.leftover = nil
                self.eofReached = false
                self.bufferingPolicy = bufferingPolicy
                self.separator = separator
                // Pre-compute separator code unit sequences for
                // .characters and .unicodeScalars cases.
                // Both use the same buffer-tail matching algorithm:
                // encode each separator into its code unit representation,
                // then suffix-match against the buffer on each incoming
                // code unit. This is correct because UTF-8 and UTF-16
                // are self-synchronizing encodings: a valid encoded
                // sequence can never appear as a sub-alignment of
                // another sequence.
                switch separator.storage {
                case .lineBreaks:
                    // Line breaks uses builtin separators
                    self.separatorCodeUnits = []
                case .unicodeScalars(let customScalars):
                    var result: [Encoding.CodeUnit] = []
                    for scalar in customScalars {
                        if let encoded = Encoding.encode(scalar) {
                            result.append(contentsOf: encoded)
                        }
                    }
                    self.separatorCodeUnits = result
                }
            }

            /// Retrieves the next line, or `nil` if the sequence ended.
            public mutating func next() async throws -> String? {

                func loadBuffer() async throws -> [Encoding.CodeUnit]? {
                    guard !self.eofReached else {
                        return nil
                    }

                    guard let buffer = try await self.source.next() else {
                        self.eofReached = true
                        return nil
                    }
                    #if SUBPROCESS_ASYNCIO_DISPATCH
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
                        return ""
                    }
                    return String(decoding: self.buffer, as: Encoding.self)
                }

                func nextFromSource() async throws -> Encoding.CodeUnit? {
                    if underlyingBufferIndex >= underlyingBuffer.count {
                        guard let buf = try await loadBuffer() else {
                            return nil
                        }
                        underlyingBuffer = buf
                        underlyingBufferIndex = buf.startIndex
                    }
                    let result = underlyingBuffer[underlyingBufferIndex]
                    underlyingBufferIndex = underlyingBufferIndex.advanced(by: 1)
                    return result
                }

                func nextCodeUnit() async throws -> Encoding.CodeUnit? {
                    defer { leftover = nil }
                    if let leftover = leftover {
                        return leftover
                    }
                    return try await nextFromSource()
                }

                // https://en.wikipedia.org/wiki/Newline#Unicode
                let lineFeed = Encoding.CodeUnit(0x0A)
                /// let verticalTab     = Encoding.CodeUnit(0x0B)
                /// let formFeed        = Encoding.CodeUnit(0x0C)
                let carriageReturn = Encoding.CodeUnit(0x0D)
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
                    newLine1 = Encoding.CodeUnit(0xC2)
                    newLine2 = Encoding.CodeUnit(0x85)

                    lineSeparator1 = Encoding.CodeUnit(0xE2)
                    lineSeparator2 = Encoding.CodeUnit(0x80)
                    lineSeparator3 = Encoding.CodeUnit(0xA8)

                    paragraphSeparator1 = Encoding.CodeUnit(0xE2)
                    paragraphSeparator2 = Encoding.CodeUnit(0x80)
                    paragraphSeparator3 = Encoding.CodeUnit(0xA9)
                case is UInt16.Type, is UInt32.Type:
                    // UTF16 and UTF32 use one byte for all
                    newLine1 = Encoding.CodeUnit(0x0085)
                    newLine2 = Encoding.CodeUnit(0x0085)

                    lineSeparator1 = Encoding.CodeUnit(0x2028)
                    lineSeparator2 = Encoding.CodeUnit(0x2028)
                    lineSeparator3 = Encoding.CodeUnit(0x2028)

                    paragraphSeparator1 = Encoding.CodeUnit(0x2029)
                    paragraphSeparator2 = Encoding.CodeUnit(0x2029)
                    paragraphSeparator3 = Encoding.CodeUnit(0x2029)
                default:
                    fatalError("Unknown encoding type \(Encoding.self)")
                }

                while let first = try await nextCodeUnit() {
                    // Throw if we exceed max line length
                    if case .maxLineLength(let maxLength) = self.bufferingPolicy, buffer.count >= maxLength {
                        throw SubprocessError.outputLimitExceeded(limit: maxLength)
                    }

                    switch self.separator.storage {
                    case .lineBreaks:
                        switch first {
                        case carriageReturn:
                            // Swallow up any subsequent LF
                            guard let next = try await nextFromSource() else {
                                return yield() // if we ran out of bytes, the last byte was a CR
                            }
                            guard next == lineFeed else {
                                // if the next character was not an LF, save it for the next iteration and still return a line
                                leftover = next
                                return yield()
                            }
                            return yield()
                        case newLine1 where Encoding.CodeUnit.self is UInt8.Type: // this may be used to compose other UTF8 characters
                            guard let next = try await nextFromSource() else {
                                // technically invalid UTF8 but it should be repaired to "\u{FFFD}"
                                return yield()
                            }
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
                            guard next == lineSeparator2 || next == paragraphSeparator2 else {
                                continue
                            }
                            guard let fin = try await nextFromSource() else {
                                return yield()
                            }
                            guard fin == lineSeparator3 || fin == paragraphSeparator3 else {
                                continue
                            }
                            return yield()
                        case lineFeed..<carriageReturn, newLine1, lineSeparator1, paragraphSeparator1:
                            return yield()
                        default:
                            buffer.append(first)
                            continue
                        }
                    case .unicodeScalars:
                        // Suffix match against the precomputed separator code units
                        buffer.append(first)
                        guard buffer.count >= self.separatorCodeUnits.count else {
                            continue
                        }
                        if buffer.suffix(
                            self.separatorCodeUnits.count
                        ).elementsEqual(self.separatorCodeUnits) {
                            buffer.removeLast(self.separatorCodeUnits.count)
                            return yield()
                        }
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

        /// Creates an iterator for this string sequence.
        public func makeAsyncIterator() -> AsyncIterator {
            return AsyncIterator(
                underlyingIterator: self.base.makeAsyncIterator(),
                bufferingPolicy: self.bufferingPolicy,
                separator: self.separator
            )
        }

        internal init(
            underlying: AsyncBufferSequence,
            encoding: Encoding.Type,
            bufferingPolicy: BufferingPolicy,
            separator: Separator
        ) {
            self.base = underlying
            self.bufferingPolicy = bufferingPolicy
            self.separator = separator
        }
    }
}

@available(*, unavailable)
extension AsyncBufferSequence.StringSequence.AsyncIterator: Sendable {}

extension AsyncBufferSequence.StringSequence {
    /// A strategy for handling buffer capacity.
    public enum BufferingPolicy: Sendable {
        /// Adds to the buffer without imposing a limit on line length.
        case unbounded
        /// Imposes a maximum line length limit.
        ///
        /// The subprocess throws an error if a line exceeds this limit.
        case maxLineLength(Int)
    }

    /// A delimiter that determines where a ``StringSequence``
    /// splits its input.
    public struct Separator: Sendable, Hashable {
        internal enum Storage: Sendable, Hashable {
            case lineBreaks
            case unicodeScalars(Array<Unicode.Scalar>)
        }

        internal let storage: Storage

        internal init(_ storage: Storage) {
            self.storage = storage
        }

        /// Splits on Unicode line break characters.
        /// The following Unicode characters are recognized as line
        /// breaks:
        /// ```
        /// LF:    Line Feed, U+000A
        /// VT:    Vertical Tab, U+000B
        /// FF:    Form Feed, U+000C
        /// CR:    Carriage Return, U+000D
        /// CR+LF: CR (U+000D) followed by LF (U+000A)
        /// NEL:   Next Line, U+0085
        /// LS:    Line Separator, U+2028
        /// PS:    Paragraph Separator, U+2029
        /// ```
        public static var lineBreaks: Self { .init(.lineBreaks) }

        /// Splits on a custom sequence of Unicode scalars.
        ///
        /// ``StringSequence`` encodes the scalars into their code unit
        /// representation and matches against the raw bytes in the
        /// buffer. Unlike `String` comparison, this match doesn't
        /// apply Unicode normalization. For example, "é" encoded
        /// as U+00E9 (precomposed) doesn't match "é" encoded as
        /// U+0065 U+0301 (decomposed). Make sure the separator
        /// scalars use the same representation as the input data.
        ///
        /// - Parameter separators: The scalars that form
        ///   the delimiter.
        /// - Returns: A separator that matches the given
        ///   scalar sequence.
        public static func unicodeScalars(
            _ separators: some Collection<Unicode.Scalar>
        ) -> Self {
            if let array = separators as? Array<Unicode.Scalar> {
                return .init(.unicodeScalars(array))
            }
            return .init(.unicodeScalars(Array(separators)))
        }
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
#endif // canImport(Darwin)

@inline(__always)
internal var readBufferSize: Int {
    return _pageSize
}
