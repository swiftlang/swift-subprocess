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

#if canImport(WinSDK)
@preconcurrency import WinSDK
#endif

internal import Dispatch

// MARK: - OutputMethod

/// Specifies how a subprocess should handle its standard output.
///
/// Use the provided static factory methods (`.discarded`, `.string(limit:)`,
/// `.bytes(limit:)`, `.fileDescriptor(_:closeAfterSpawningProcess:)`) to create
/// output configurations. Custom implementations are not supported.
public struct OutputMethod<T: Sendable>: Sendable {
    internal let maxSize: Int
    internal let _createPipe: @Sendable () throws -> CreatedPipe
    internal let _captureOutput: @Sendable (consuming IOChannel?) async throws -> T

    internal init(
        maxSize: Int,
        createPipe: @escaping @Sendable () throws -> CreatedPipe,
        captureOutput: @escaping @Sendable (consuming IOChannel?) async throws -> T
    ) {
        self.maxSize = maxSize
        self._createPipe = createPipe
        self._captureOutput = captureOutput
    }
}

extension OutputMethod where T == Void {
    /// Create a Subprocess output that discards the output.
    ///
    /// On Unix-like systems, this redirects the standard output of the
    /// subprocess to `/dev/null`, while on Windows, redirects to `NUL`.
    public static var discarded: OutputMethod<Void> {
        let inner = DiscardedOutput()
        return OutputMethod<Void>(
            maxSize: 0,
            createPipe: { try inner.createPipe() },
            captureOutput: { _ in }
        )
    }

    /// Create a Subprocess output that writes output to a `FileDescriptor`
    /// and optionally close the `FileDescriptor` once process spawned.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> OutputMethod<Void> {
        let inner = FileDescriptorOutput(
            fileDescriptor: fd,
            closeAfterSpawningProcess: closeAfterSpawningProcess
        )
        return OutputMethod<Void>(
            maxSize: 0,
            createPipe: { try inner.createPipe() },
            captureOutput: { _ in }
        )
    }

    /// Create a Subprocess output that writes output to the standard output of
    /// current process.
    ///
    /// The file descriptor isn't closed afterwards.
    public static var standardOutput: OutputMethod<Void> {
        return .fileDescriptor(
            .standardOutput,
            closeAfterSpawningProcess: false
        )
    }

    /// Create a Subprocess output that writes output to the standard error of
    /// current process.
    ///
    /// The file descriptor isn't closed afterwards.
    public static var standardError: OutputMethod<Void> {
        return .fileDescriptor(
            .standardError,
            closeAfterSpawningProcess: false
        )
    }

    /// Internal: creates a pipe for streaming output via `AsyncBufferSequence`.
    internal static var _sequence: OutputMethod<Void> {
        return OutputMethod<Void>(
            maxSize: 0,
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .output) },
            captureOutput: { _ in }
        )
    }
}

extension OutputMethod where T == String? {
    /// Create a `Subprocess` output that collects output as UTF8 String
    /// with a buffer limit in bytes. Subprocess throws an error if the
    /// child process emits more bytes than the limit.
    public static func string(limit: Int) -> OutputMethod<String?> {
        let inner = StringOutput(limit: limit, encoding: UTF8.self)
        return OutputMethod<String?>(
            maxSize: limit,
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .output) },
            captureOutput: { diskIO in
                try await inner.captureOutput(from: diskIO)
            }
        )
    }
}

extension OutputMethod {
    /// Create a `Subprocess` output that collects output as
    /// `String` using the given encoding up to limit in bytes.
    /// Subprocess throws an error if the child process emits
    /// more bytes than the limit.
    public static func string<Encoding: Unicode.Encoding>(
        limit: Int,
        encoding: Encoding.Type
    ) -> OutputMethod<String?> where T == String? {
        let inner = StringOutput(limit: limit, encoding: encoding)
        return OutputMethod<String?>(
            maxSize: limit,
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .output) },
            captureOutput: { diskIO in
                try await inner.captureOutput(from: diskIO)
            }
        )
    }
}

extension OutputMethod where T == [UInt8] {
    /// Create a `Subprocess` output that collects output as
    /// `[UInt8]` with a buffer limit in bytes. Subprocess throws
    /// an error if the child process emits more bytes than the limit.
    public static func bytes(limit: Int) -> OutputMethod<[UInt8]> {
        let inner = BytesOutput(limit: limit)
        return OutputMethod<[UInt8]>(
            maxSize: limit,
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .output) },
            captureOutput: { diskIO in
                guard let diskIO else { return [] }
                return try await inner.captureOutput(from: diskIO)
            }
        )
    }
}

// MARK: - ErrorOutputMethod

/// Specifies how a subprocess should handle its standard error output.
///
/// Use the provided static factory methods (`.discarded`, `.string(limit:)`,
/// `.bytes(limit:)`, `.combineWithOutput`, etc.) to create error output
/// configurations. Custom implementations are not supported.
public struct ErrorOutputMethod<T: Sendable>: Sendable {
    internal let maxSize: Int
    internal let _createPipe: @Sendable (borrowing CreatedPipe) throws -> CreatedPipe
    internal let _captureOutput: @Sendable (consuming IOChannel?) async throws -> T

    internal init(
        maxSize: Int,
        createPipe: @escaping @Sendable (borrowing CreatedPipe) throws -> CreatedPipe,
        captureOutput: @escaping @Sendable (consuming IOChannel?) async throws -> T
    ) {
        self.maxSize = maxSize
        self._createPipe = createPipe
        self._captureOutput = captureOutput
    }
}

extension ErrorOutputMethod where T == Void {
    /// Create a Subprocess error output that discards the error output.
    public static var discarded: ErrorOutputMethod<Void> {
        let inner = DiscardedOutput()
        return ErrorOutputMethod<Void>(
            maxSize: 0,
            createPipe: { _ in try inner.createPipe() },
            captureOutput: { _ in }
        )
    }

    /// Creates an error output that combines standard error with standard output.
    ///
    /// When using `combineWithOutput`, both standard output and standard error from
    /// the child process are merged into a single output stream. This is equivalent
    /// to using shell redirection like `2>&1`.
    ///
    /// This is useful when you want to capture or redirect both output streams
    /// together, making it possible to process all subprocess output as a unified
    /// stream rather than handling standard output and standard error separately.
    ///
    /// - Returns: An `ErrorOutputMethod` that merges standard error
    ///   with standard output.
    public static var combineWithOutput: ErrorOutputMethod<Void> {
        return ErrorOutputMethod<Void>(
            maxSize: 0,
            createPipe: { outputPipe in
                try CreatedPipe(duplicating: outputPipe)
            },
            captureOutput: { _ in }
        )
    }

    /// Create a Subprocess error output that writes to a `FileDescriptor`
    /// and optionally close the `FileDescriptor` once process spawned.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> ErrorOutputMethod<Void> {
        let inner = FileDescriptorOutput(
            fileDescriptor: fd,
            closeAfterSpawningProcess: closeAfterSpawningProcess
        )
        return ErrorOutputMethod<Void>(
            maxSize: 0,
            createPipe: { _ in try inner.createPipe() },
            captureOutput: { _ in }
        )
    }

    /// Create a Subprocess error output that writes to the standard error of
    /// current process.
    ///
    /// The file descriptor isn't closed afterwards.
    public static var standardError: ErrorOutputMethod<Void> {
        return .fileDescriptor(
            .standardError,
            closeAfterSpawningProcess: false
        )
    }
}

extension ErrorOutputMethod where T == String? {
    /// Create a `Subprocess` error output that collects error output as UTF8 String
    /// with a buffer limit in bytes. Subprocess throws an error if the
    /// child process emits more bytes than the limit.
    public static func string(limit: Int) -> ErrorOutputMethod<String?> {
        let inner = StringOutput(limit: limit, encoding: UTF8.self)
        return ErrorOutputMethod<String?>(
            maxSize: limit,
            createPipe: { _ in try CreatedPipe(closeWhenDone: true, purpose: .output) },
            captureOutput: { diskIO in
                try await inner.captureOutput(from: diskIO)
            }
        )
    }
}

extension ErrorOutputMethod {
    /// Create a `Subprocess` error output that collects error output as
    /// `String` using the given encoding up to limit in bytes.
    /// Subprocess throws an error if the child process emits
    /// more bytes than the limit.
    public static func string<Encoding: Unicode.Encoding>(
        limit: Int,
        encoding: Encoding.Type
    ) -> ErrorOutputMethod<String?> where T == String? {
        let inner = StringOutput(limit: limit, encoding: encoding)
        return ErrorOutputMethod<String?>(
            maxSize: limit,
            createPipe: { _ in try CreatedPipe(closeWhenDone: true, purpose: .output) },
            captureOutput: { diskIO in
                try await inner.captureOutput(from: diskIO)
            }
        )
    }
}

extension ErrorOutputMethod where T == [UInt8] {
    /// Create a `Subprocess` error output that collects error output as
    /// `[UInt8]` with a buffer limit in bytes. Subprocess throws
    /// an error if the child process emits more bytes than the limit.
    public static func bytes(limit: Int) -> ErrorOutputMethod<[UInt8]> {
        let inner = BytesOutput(limit: limit)
        return ErrorOutputMethod<[UInt8]>(
            maxSize: limit,
            createPipe: { _ in try CreatedPipe(closeWhenDone: true, purpose: .output) },
            captureOutput: { diskIO in
                guard let diskIO else { return [] }
                return try await inner.captureOutput(from: diskIO)
            }
        )
    }
}

// MARK: - Internal Output Protocol

/// Internal protocol used by the concrete output type implementations.
internal protocol OutputProtocol: Sendable, ~Copyable {
    associatedtype OutputType: Sendable

    #if SubprocessSpan
    /// Convert the output from span to expected output type
    func output(from span: RawSpan) throws -> OutputType
    #endif

    /// Convert the output from buffer to expected output type
    func output(from buffer: some Sequence<UInt8>) throws -> OutputType

    /// The max amount of data to collect for this output.
    var maxSize: Int { get }
}

extension OutputProtocol {
    /// The max amount of data to collect for this output.
    internal var maxSize: Int { 128 * 1024 }
}

// MARK: - Internal Concrete Output Types

internal struct DiscardedOutput: OutputProtocol {
    typealias OutputType = Void

    func createPipe() throws(SubprocessError) -> CreatedPipe {
        #if os(Windows)
        let devnullFd: FileDescriptor = try .openDevNull(withAccessMode: .writeOnly)
        let devnull = HANDLE(bitPattern: _get_osfhandle(devnullFd.rawValue))!
        #else
        let devnull: FileDescriptor = try .openDevNull(withAccessMode: .writeOnly)
        #endif
        return CreatedPipe(
            readFileDescriptor: nil,
            writeFileDescriptor: .init(devnull, closeWhenDone: true)
        )
    }

    init() {}
}

internal struct FileDescriptorOutput: OutputProtocol {
    typealias OutputType = Void

    private let closeAfterSpawningProcess: Bool
    private let fileDescriptor: FileDescriptor

    func createPipe() throws(SubprocessError) -> CreatedPipe {
        #if canImport(WinSDK)
        let writeFd = HANDLE(bitPattern: _get_osfhandle(self.fileDescriptor.rawValue))!
        #else
        let writeFd = self.fileDescriptor
        #endif
        return CreatedPipe(
            readFileDescriptor: nil,
            writeFileDescriptor: .init(
                writeFd,
                closeWhenDone: self.closeAfterSpawningProcess
            )
        )
    }

    init(
        fileDescriptor: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) {
        self.fileDescriptor = fileDescriptor
        self.closeAfterSpawningProcess = closeAfterSpawningProcess
    }
}

internal struct StringOutput<Encoding: Unicode.Encoding>: OutputProtocol {
    typealias OutputType = String?
    let maxSize: Int

    #if SubprocessSpan
    func output(from span: RawSpan) throws -> String? {
        // FIXME: Span to String
        var array: [UInt8] = []
        for index in 0..<span.byteCount {
            array.append(span.unsafeLoad(fromByteOffset: index, as: UInt8.self))
        }
        return String(decodingBytes: array, as: Encoding.self)
    }
    #endif

    func output(from buffer: some Sequence<UInt8>) throws -> String? {
        // FIXME: Span to String
        let array = Array(buffer)
        return String(decodingBytes: array, as: Encoding.self)
    }

    init(limit: Int, encoding: Encoding.Type) {
        self.maxSize = limit
    }
}

internal struct BytesOutput: OutputProtocol {
    typealias OutputType = [UInt8]
    let maxSize: Int

    func captureOutput(
        from diskIO: consuming IOChannel
    ) async throws(SubprocessError) -> [UInt8] {
        #if SUBPROCESS_ASYNCIO_DISPATCH
        var result: DispatchData? = nil
        #else
        var result: [UInt8]? = nil
        #endif
        do {
            var maxLength = self.maxSize
            if maxLength != .max {
                // If we actually have a max length, attempt to read one
                // more byte to determine whether output exceeds the limit
                maxLength += 1
            }
            result = try await AsyncIO.shared.read(from: diskIO, upTo: maxLength)
        } catch {
            try diskIO.safelyClose()
            throw error
        }
        try diskIO.safelyClose()

        if let result, result.count > self.maxSize {
            throw .outputLimitExceeded(limit: self.maxSize)
        }
        #if SUBPROCESS_ASYNCIO_DISPATCH
        return result?.array() ?? []
        #else
        return result ?? []
        #endif
    }

    #if SubprocessSpan
    func output(from span: RawSpan) throws -> [UInt8] {
        fatalError("Not implemented")
    }
    #endif

    func output(from buffer: some Sequence<UInt8>) throws -> [UInt8] {
        fatalError("Not implemented")
    }

    init(limit: Int) {
        self.maxSize = limit
    }
}

internal struct SequenceOutput: OutputProtocol {
    typealias OutputType = Void
    init() {}
}

// MARK: - Span Default Implementations
#if SubprocessSpan
extension OutputProtocol {
    func output(from buffer: some Sequence<UInt8>) throws -> OutputType {
        guard let rawBytes: UnsafeRawBufferPointer = buffer as? UnsafeRawBufferPointer else {
            fatalError("Unexpected input type passed: \(type(of: buffer))")
        }
        let span = RawSpan(_unsafeBytes: rawBytes)
        return try self.output(from: span)
    }
}
#endif

// MARK: - Default Capture Implementation

extension OutputProtocol {
    /// Capture the output from the subprocess up to maxSize
    internal func captureOutput(
        from diskIO: consuming IOChannel?
    ) async throws -> OutputType {
        if OutputType.self == Void.self {
            try diskIO?.safelyClose()
            return () as! OutputType
        }
        guard var diskIO else {
            fatalError(
                "Internal Inconsistency Error: diskIO must not be nil when OutputType is not Void"
            )
        }

        #if SUBPROCESS_ASYNCIO_DISPATCH
        var result: DispatchData? = nil
        #else
        var result: [UInt8]? = nil
        #endif
        do {
            var maxLength = self.maxSize
            if maxLength != .max {
                maxLength += 1
            }
            result = try await AsyncIO.shared.read(from: diskIO, upTo: maxLength)
        } catch {
            try diskIO.safelyClose()
            throw error
        }

        try diskIO.safelyClose()
        if let result, result.count > self.maxSize {
            throw SubprocessError.outputLimitExceeded(limit: self.maxSize)
        }

        #if SUBPROCESS_ASYNCIO_DISPATCH
        return try self.output(from: result ?? .empty)
        #else
        return try self.output(from: result ?? [])
        #endif
    }
}

extension OutputProtocol where OutputType == Void {
    #if SubprocessSpan
    func output(from span: RawSpan) throws {
        fatalError("Unexpected call to \(#function)")
    }
    #endif

    func output(from buffer: some Sequence<UInt8>) throws {
        fatalError("Unexpected call to \(#function)")
    }
}

#if SubprocessSpan
extension OutputProtocol {
    #if SUBPROCESS_ASYNCIO_DISPATCH
    internal func output(from data: DispatchData) throws -> OutputType {
        guard !data.isEmpty else {
            let empty = UnsafeRawBufferPointer(start: nil, count: 0)
            let span = RawSpan(_unsafeBytes: empty)
            return try self.output(from: span)
        }

        return try data.withUnsafeBytes { ptr in
            let bufferPtr = UnsafeRawBufferPointer(start: ptr, count: data.count)
            let span = RawSpan(_unsafeBytes: bufferPtr)
            return try self.output(from: span)
        }
    }
    #else
    internal func output(from data: [UInt8]) throws -> OutputType {
        guard !data.isEmpty else {
            let empty = UnsafeRawBufferPointer(start: nil, count: 0)
            let span = RawSpan(_unsafeBytes: empty)
            return try self.output(from: span)
        }

        return try data.withUnsafeBufferPointer { ptr in
            let span = RawSpan(_unsafeBytes: UnsafeRawBufferPointer(ptr))
            return try self.output(from: span)
        }
    }
    #endif // SUBPROCESS_ASYNCIO_DISPATCH
}
#endif

// MARK: - Utilities

extension DispatchData {
    internal func array() -> [UInt8] {
        var result: [UInt8]?
        self.enumerateBytes { buffer, byteIndex, stop in
            let currentChunk = Array(UnsafeRawBufferPointer(buffer))
            if result == nil {
                result = currentChunk
            } else {
                result?.append(contentsOf: currentChunk)
            }
        }
        return result ?? []
    }
}

extension FileDescriptor {
    internal static func openDevNull(
        withAccessMode mode: FileDescriptor.AccessMode
    ) throws(SubprocessError) -> FileDescriptor {
        do {
            #if os(Windows)
            let devnull: FileDescriptor = try .open("NUL", mode)
            #else
            let devnull: FileDescriptor = try .open("/dev/null", mode)
            #endif
            return devnull
        } catch {
            throw .asyncIOFailed(
                reason: "Failed to open /dev/null",
                underlyingError: error as? SubprocessError.UnderlyingError
            )
        }
    }
}
