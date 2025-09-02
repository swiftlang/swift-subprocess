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

#if canImport(WinSDK)
@preconcurrency import WinSDK
#endif

internal import Dispatch

// MARK: - Output

/// Output protocol specifies the set of methods that a type must implement to
/// serve as the output target for a subprocess.
///
/// Instead of developing custom implementations of `OutputProtocol`, use the
/// default implementations provided by the `Subprocess` library to specify the
/// output handling requirements.
public protocol OutputProtocol: Sendable, ~Copyable {
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
    public var maxSize: Int { 128 * 1024 }
}

/// A concrete output type for subprocesses that indicates that the
/// subprocess should not collect or redirect output from the child
/// process.
///
/// On Unix-like systems, `DiscardedOutput` redirects the
/// standard output of the subprocess to `/dev/null`, while on Windows,
/// redirects the output to `NUL`.
public struct DiscardedOutput: OutputProtocol {
    /// The type for the output.
    public typealias OutputType = Void

    internal func createPipe() throws -> CreatedPipe {

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

/// A concrete output type for subprocesses that writes output
/// to a specified file descriptor.
///
/// Developers have the option to instruct the `Subprocess` to automatically
/// close the related `FileDescriptor` after the subprocess is spawned.
public struct FileDescriptorOutput: OutputProtocol {
    /// The type for this output.
    public typealias OutputType = Void

    private let closeAfterSpawningProcess: Bool
    private let fileDescriptor: FileDescriptor

    internal func createPipe() throws -> CreatedPipe {
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

/// A concrete `Output` type for subprocesses that collects output
/// from the subprocess as `String` with the given encoding.
public struct StringOutput<Encoding: Unicode.Encoding>: OutputProtocol {
    /// The type for this output.
    public typealias OutputType = String?
    /// The max number of bytes to collect.
    public let maxSize: Int

    #if SubprocessSpan
    /// Create a string from a raw span.
    public func output(from span: RawSpan) throws -> String? {
        // FIXME: Span to String
        var array: [UInt8] = []
        for index in 0..<span.byteCount {
            array.append(span.unsafeLoad(fromByteOffset: index, as: UInt8.self))
        }
        return String(decodingBytes: array, as: Encoding.self)
    }
    #endif

    /// Create a String from a sequence of 8-bit unsigned integers.
    public func output(from buffer: some Sequence<UInt8>) throws -> String? {
        // FIXME: Span to String
        let array = Array(buffer)
        return String(decodingBytes: array, as: Encoding.self)
    }

    internal init(limit: Int, encoding: Encoding.Type) {
        self.maxSize = limit
    }
}

/// A concrete `Output` type for subprocesses that collects output from
/// the subprocess as `[UInt8]`.
public struct BytesOutput: OutputProtocol {
    /// The output type for this output option
    public typealias OutputType = [UInt8]
    /// The max number of bytes to collect
    public let maxSize: Int

    internal func captureOutput(
        from diskIO: consuming IOChannel
    ) async throws -> [UInt8] {
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
            throw SubprocessError(
                code: .init(.outputBufferLimitExceeded(self.maxSize)),
                underlyingError: nil
            )
        }
        #if SUBPROCESS_ASYNCIO_DISPATCH
        return result?.array() ?? []
        #else
        return result ?? []
        #endif
    }

    #if SubprocessSpan
    /// Create an Array from `RawSpawn`.
    /// Not implemented
    public func output(from span: RawSpan) throws -> [UInt8] {
        fatalError("Not implemented")
    }
    #endif
    /// Create an Array from `Sequence<UInt8>`.
    /// Not implemented
    public func output(from buffer: some Sequence<UInt8>) throws -> [UInt8] {
        fatalError("Not implemented")
    }

    internal init(limit: Int) {
        self.maxSize = limit
    }
}

/// A concrete `Output` type for subprocesses that redirects the child output to
/// the `.standardOutput` (a sequence) or `.standardError` property of
/// `Execution`. This output type is only applicable to the `run()` family that
/// takes a custom closure.
internal struct SequenceOutput: OutputProtocol {
    /// The output type for this output option
    public typealias OutputType = Void

    internal init() {}
}

extension OutputProtocol where Self == DiscardedOutput {
    /// Create a Subprocess output that discards the output
    public static var discarded: Self { .init() }
}

extension OutputProtocol where Self == FileDescriptorOutput {
    /// Create a Subprocess output that writes output to a `FileDescriptor`
    /// and optionally close the `FileDescriptor` once process spawned.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> Self {
        return .init(fileDescriptor: fd, closeAfterSpawningProcess: closeAfterSpawningProcess)
    }

    /// Create a Subprocess output that writes output to the standard output of
    /// current process.
    ///
    /// The file descriptor isn't closed afterwards.
    public static var standardOutput: Self {
        return Self.fileDescriptor(
            .standardOutput,
            closeAfterSpawningProcess: false
        )
    }

    /// Create a Subprocess output that write output to the standard error of
    /// current process.
    ///
    /// The file descriptor isn't closed afterwards.
    public static var standardError: Self {
        return Self.fileDescriptor(
            .standardError,
            closeAfterSpawningProcess: false
        )
    }
}

extension OutputProtocol where Self == StringOutput<UTF8> {
    /// Create a `Subprocess` output that collects output as UTF8 String
    /// with a buffer limit in bytes. Subprocess throws an error if the
    /// child process emits more bytes than the limit.
    public static func string(limit: Int) -> Self {
        return .init(limit: limit, encoding: UTF8.self)
    }
}

extension OutputProtocol {
    /// Create a `Subprocess` output that collects output as
    /// `String` using the given encoding up to limit in bytes.
    /// Subprocess throws an error if the child process emits
    /// more bytes than the limit.
    public static func string<Encoding: Unicode.Encoding>(
        limit: Int,
        encoding: Encoding.Type
    ) -> Self where Self == StringOutput<Encoding> {
        return .init(limit: limit, encoding: encoding)
    }
}

extension OutputProtocol where Self == BytesOutput {
    /// Create a `Subprocess` output that collects output as
    /// `Buffer` with a buffer limit in bytes. Subprocess throws
    /// an error if the child process emits more bytes than the limit.
    public static func bytes(limit: Int) -> Self {
        return .init(limit: limit)
    }
}

// MARK: - Span Default Implementations
#if SubprocessSpan
extension OutputProtocol {
    /// Create an Array from `Sequence<UInt8>`.
    public func output(from buffer: some Sequence<UInt8>) throws -> OutputType {
        guard let rawBytes: UnsafeRawBufferPointer = buffer as? UnsafeRawBufferPointer else {
            fatalError("Unexpected input type passed: \(type(of: buffer))")
        }
        let span = RawSpan(_unsafeBytes: rawBytes)
        return try self.output(from: span)
    }
}
#endif

// MARK: - Default Implementations
extension OutputProtocol {
    @_disfavoredOverload
    internal func createPipe() throws -> CreatedPipe {
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
            throw SubprocessError(
                code: .init(.outputBufferLimitExceeded(self.maxSize)),
                underlyingError: nil
            )
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

    #if SubprocessSpan
    /// Convert the output from raw span to expected output type
    public func output(from span: RawSpan) throws {
        fatalError("Unexpected call to \(#function)")
    }
    #endif
    /// Convert the output from a sequence of 8-bit unsigned integers to expected output type.
    public func output(from buffer: some Sequence<UInt8>) throws {
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
    ) throws -> FileDescriptor {
        #if os(Windows)
        let devnull: FileDescriptor = try .open("NUL", mode)
        #else
        let devnull: FileDescriptor = try .open("/dev/null", mode)
        #endif
        return devnull
    }
}
