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

// MARK: - Output

/// A type that serves as the output target for a subprocess.
public protocol OutputProtocol: Sendable, ~Copyable {
    associatedtype OutputType: Sendable

    /// Converts the output from a span to the expected output type.
    func output(from span: RawSpan) throws -> OutputType

    /// The maximum number of bytes to collect.
    var maxSize: Int { get }
}

extension OutputProtocol {
    /// The maximum number of bytes to collect.
    public var maxSize: Int { 128 * 1024 }
}

/// An output type that discards output from the child process.
///
/// On Unix-like systems, ``DiscardedOutput`` redirects standard output
/// to `/dev/null`. On Windows, it redirects to `NUL`.
public struct DiscardedOutput: OutputProtocol, ErrorOutputProtocol {
    /// The type for the output.
    public typealias OutputType = Void

    internal func createPipe() throws(SubprocessError) -> CreatedPipe {

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

    internal init() {}
}

/// An output type that writes to a specified file descriptor.
///
/// You can choose to have the subprocess automatically close
/// the file descriptor after it spawns.
public struct FileDescriptorOutput: OutputProtocol, ErrorOutputProtocol {
    /// The type for this output.
    public typealias OutputType = Void

    private let closeAfterSpawningProcess: Bool
    private let fileDescriptor: FileDescriptor

    internal func createPipe() throws(SubprocessError) -> CreatedPipe {
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

    internal init(
        fileDescriptor: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) {
        self.fileDescriptor = fileDescriptor
        self.closeAfterSpawningProcess = closeAfterSpawningProcess
    }
}

/// An output type that collects the subprocess's output as a `String` with the given encoding.
public struct StringOutput<Encoding: Unicode.Encoding>: OutputProtocol, ErrorOutputProtocol {
    /// The type for this output.
    public typealias OutputType = String?
    /// The maximum number of bytes to collect.
    public let maxSize: Int

    /// Creates a string from a raw span.
    public func output(from span: RawSpan) throws -> String? {
        span.withUnsafeBytes { ptr in
            let array = Array(ptr)
            return String(decodingBytes: array, as: Encoding.self)
        }
    }

    internal init(limit: Int, encoding: Encoding.Type) {
        self.maxSize = limit
    }
}

/// An output type that collects the subprocess's output as a `[UInt8]` array.
public struct BytesOutput: OutputProtocol, ErrorOutputProtocol {
    /// The output type for this output option.
    public typealias OutputType = [UInt8]
    /// The maximum number of bytes to collect.
    public let maxSize: Int

    internal func captureOutput(
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

    /// Creates an array from a ``RawSpan``.
    public func output(from span: RawSpan) throws -> [UInt8] {
        span.withUnsafeBytes { Array($0) }
    }

    internal init(limit: Int) {
        self.maxSize = limit
    }
}

/// A concrete `Output` type for subprocesses that redirects the child output to
/// the `.currentStandardOutput` (a sequence) or `.currentStandardError` property of
/// `Execution`. This output type is only applicable to the `run()` family that
/// takes a custom closure.
internal struct SequenceOutput: OutputProtocol {
    /// The output type for this output option.
    public typealias OutputType = Void

    internal init() {}
}

extension OutputProtocol where Self == DiscardedOutput {
    /// Creates a subprocess output that discards output.
    public static var discarded: Self { .init() }
}

extension OutputProtocol where Self == FileDescriptorOutput {
    /// Creates a subprocess output that writes to a file descriptor.
    ///
    /// Set `closeAfterSpawningProcess` to `true` to close the file
    /// descriptor after the subprocess spawns.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> Self {
        return .init(fileDescriptor: fd, closeAfterSpawningProcess: closeAfterSpawningProcess)
    }

    /// Creates a subprocess output that writes to the current process's standard output.
    ///
    /// The file descriptor isn't closed afterwards.
    public static var currentStandardOutput: Self {
        return Self.fileDescriptor(
            .standardOutput,
            closeAfterSpawningProcess: false
        )
    }

    /// Creates a subprocess output that writes to the current process's standard error.
    ///
    /// The file descriptor isn't closed afterwards.
    public static var currentStandardError: Self {
        return Self.fileDescriptor(
            .standardError,
            closeAfterSpawningProcess: false
        )
    }
}

extension OutputProtocol where Self == StringOutput<UTF8> {
    /// Creates a subprocess output that collects output as a UTF-8 string.
    ///
    /// The subprocess throws an error if the child process
    /// produces more bytes than `limit`.
    public static func string(limit: Int) -> Self {
        return .init(limit: limit, encoding: UTF8.self)
    }
}

extension OutputProtocol {
    /// Creates a subprocess output that collects output as
    /// a string using the given encoding, up to `limit` bytes.
    ///
    /// The subprocess throws an error if the child process
    /// produces more bytes than `limit`.
    public static func string<Encoding: Unicode.Encoding>(
        limit: Int,
        encoding: Encoding.Type
    ) -> Self where Self == StringOutput<Encoding> {
        return .init(limit: limit, encoding: encoding)
    }
}

extension OutputProtocol where Self == BytesOutput {
    /// Creates a subprocess output that collects output as bytes,
    /// up to `limit` bytes.
    ///
    /// The subprocess throws an error if the child process
    /// produces more bytes than `limit`.
    public static func bytes(limit: Int) -> Self {
        return .init(limit: limit)
    }
}

// MARK: - ErrorOutputProtocol

/// A type that serves as the standard error output target for a subprocess.
///
/// Instead of creating custom implementations of ``ErrorOutputProtocol``, use the
/// built-in implementations provided by the `Subprocess` library.
public protocol ErrorOutputProtocol: OutputProtocol {}

/// A concrete error output type for subprocesses that combines the standard error
/// output with the standard output stream.
///
/// When `CombinedErrorOutput` is used as the error output for a subprocess, both
/// standard output and standard error from the child process are merged into a
/// single output stream. This is equivalent to using shell redirection like `2>&1`.
///
/// This output type is useful when you want to capture or redirect both output
/// streams together, making it possible to process all subprocess output as a unified
/// stream rather than handling standard output and standard error separately.
public struct CombinedErrorOutput: ErrorOutputProtocol {
    public typealias OutputType = Void
}

extension ErrorOutputProtocol {
    internal func createPipe(from outputPipe: borrowing CreatedPipe) throws(SubprocessError) -> CreatedPipe {
        if self is CombinedErrorOutput {
            return try CreatedPipe(duplicating: outputPipe)
        }
        return try createPipe()
    }
}

extension ErrorOutputProtocol where Self == CombinedErrorOutput {
    /// Creates an error output that combines standard error with standard output.
    ///
    /// When using `combinedWithOutput`, both standard output and standard error from
    /// the child process are merged into a single output stream. This is equivalent
    /// to using shell redirection like `2>&1`.
    ///
    /// This is useful when you want to capture or redirect both output streams
    /// together, making it possible to process all subprocess output as a unified
    /// stream rather than handling standard output and standard error separately
    ///
    /// - Returns: A `CombinedErrorOutput` instance that merges standard error
    ///   with standard output.
    public static var combinedWithOutput: Self {
        return CombinedErrorOutput()
    }
}

// MARK: - Default Implementations
extension OutputProtocol {
    @_disfavoredOverload
    internal func createPipe() throws(SubprocessError) -> CreatedPipe {
        if let discard = self as? DiscardedOutput {
            return try discard.createPipe()
        } else if let fdOutput = self as? FileDescriptorOutput {
            return try fdOutput.createPipe()
        }
        // Base pipe based implementation for everything else
        return try CreatedPipe(closeWhenDone: true, purpose: .output)
    }

    /// Capture the output from the subprocess up to maxSize
    @_disfavoredOverload
    internal func captureOutput(
        from diskIO: consuming IOChannel?
    ) async throws -> OutputType {
        if OutputType.self == Void.self {
            try diskIO?.safelyClose()
            return () as! OutputType
        }
        // `diskIO` is only `nil` for any types that conform to `OutputProtocol`
        // and have `Void` as ``OutputType` (i.e. `DiscardedOutput`). Since we
        // made sure `OutputType` is not `Void` on the line above, `diskIO`
        // must not be nil; otherwise, this is a programmer error.
        guard var diskIO else {
            fatalError(
                "Internal Inconsistency Error: diskIO must not be nil when OutputType is not Void"
            )
        }

        if let bytesOutput = self as? BytesOutput {
            return try await bytesOutput.captureOutput(from: diskIO) as! Self.OutputType
        }

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
    internal func captureOutput(from fileDescriptor: consuming IOChannel?) async throws {}

    /// Converts the output from a raw span to the expected output type.
    public func output(from span: RawSpan) throws {
        // When OutputType is Void, there is no output to process,
        // So this is effectively a no-op.
    }
}

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
