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

// MARK: - Output

/// `OutputProtocol` specifies the set of methods that a type
/// must implement to serve as the output target for a subprocess.
/// Instead of developing custom implementations of `OutputProtocol`,
/// it is recommended to utilize the default implementations provided
/// by the `Subprocess` library to specify the output handling requirements.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
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

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension OutputProtocol {
    /// The max amount of data to collect for this output.
    public var maxSize: Int { 128 * 1024 }
}

/// A concrete `Output` type for subprocesses that indicates that
/// the `Subprocess` should not collect or redirect output
/// from the child process. On Unix-like systems, `DiscardedOutput`
/// redirects the standard output of the subprocess to `/dev/null`,
/// while on Windows, it does not bind any file handle to the
/// subprocess standard output handle.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public struct DiscardedOutput: OutputProtocol {
    public typealias OutputType = Void

    internal func createPipe() throws -> CreatedPipe {
        #if os(Windows)
        // On Windows, instead of binding to dev null,
        // we don't set the input handle in the `STARTUPINFOW`
        // to signal no output
        return CreatedPipe(
            readFileDescriptor: nil,
            writeFileDescriptor: nil
        )
        #else
        let devnull: FileDescriptor = try .openDevNull(withAcessMode: .readOnly)
        return CreatedPipe(
            readFileDescriptor: nil,
            writeFileDescriptor: .init(devnull, closeWhenDone: true)
        )
        #endif
    }

    internal init() {}
}

/// A concrete `Output` type for subprocesses that
/// writes output to a specified `FileDescriptor`.
/// Developers have the option to instruct the `Subprocess` to
/// automatically close the provided `FileDescriptor`
/// after the subprocess is spawned.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public struct FileDescriptorOutput: OutputProtocol {
    public typealias OutputType = Void

    private let closeAfterSpawningProcess: Bool
    private let fileDescriptor: FileDescriptor

    internal func createPipe() throws -> CreatedPipe {
        return CreatedPipe(
            readFileDescriptor: nil,
            writeFileDescriptor: .init(
                self.fileDescriptor,
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
/// This option must be used with he `run()` method that
/// returns a `CollectedResult`.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public struct StringOutput<Encoding: Unicode.Encoding>: OutputProtocol {
    public typealias OutputType = String?
    public let maxSize: Int

    #if SubprocessSpan
    public func output(from span: RawSpan) throws -> String? {
        // FIXME: Span to String
        var array: [UInt8] = []
        for index in 0..<span.byteCount {
            array.append(span.unsafeLoad(fromByteOffset: index, as: UInt8.self))
        }
        return String(decodingBytes: array, as: Encoding.self)
    }
    #else
    public func output(from buffer: some Sequence<UInt8>) throws -> String? {
        // FIXME: Span to String
        let array = Array(buffer)
        return String(decodingBytes: array, as: Encoding.self)
    }
    #endif

    internal init(limit: Int, encoding: Encoding.Type) {
        self.maxSize = limit
    }
}

/// A concrete `Output` type for subprocesses that collects output
/// from the subprocess as `[UInt8]`. This option must be used with
/// the `run()` method that returns a `CollectedResult`
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
public struct BytesOutput: OutputProtocol {
    public typealias OutputType = [UInt8]
    public let maxSize: Int

    internal func captureOutput(
        from diskIO: consuming TrackedPlatformDiskIO?
    ) async throws -> [UInt8] {
        guard let diskIO = diskIO else {
            // Show not happen due to type system constraints
            fatalError("Trying to capture output without file descriptor")
        }
        #if os(Windows)
        return try await diskIO.fileDescriptor.read(upToLength: self.maxSize) ?? []
        #else
        let result = try await diskIO.dispatchIO.read(upToLength: self.maxSize)
        return result?.array() ?? []
        #endif
    }

    #if SubprocessSpan
    public func output(from span: RawSpan) throws -> [UInt8] {
        fatalError("Not implemented")
    }
    #else
    public func output(from buffer: some Sequence<UInt8>) throws -> [UInt8] {
        fatalError("Not implemented")
    }
    #endif

    internal init(limit: Int) {
        self.maxSize = limit
    }
}

/// A concrete `Output` type for subprocesses that redirects
/// the child output to the `.standardOutput` (a sequence) or `.standardError`
/// property of `Execution`. This output type is
/// only applicable to the `run()` family that takes a custom closure.
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
internal struct SequenceOutput: OutputProtocol {
    public typealias OutputType = Void

    internal init() {}
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension OutputProtocol where Self == DiscardedOutput {
    /// Create a Subprocess output that discards the output
    public static var discarded: Self { .init() }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension OutputProtocol where Self == FileDescriptorOutput {
    /// Create a Subprocess output that writes output to a `FileDescriptor`
    /// and optionally close the `FileDescriptor` once process spawned.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> Self {
        return .init(fileDescriptor: fd, closeAfterSpawningProcess: closeAfterSpawningProcess)
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension OutputProtocol where Self == StringOutput<UTF8> {
    /// Create a `Subprocess` output that collects output as
    /// UTF8 String with 128kb limit.
    public static var string: Self {
        .init(limit: 128 * 1024, encoding: UTF8.self)
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension OutputProtocol {
    /// Create a `Subprocess` output that collects output as
    /// `String` using the given encoding up to limit it bytes.
    public static func string<Encoding: Unicode.Encoding>(
        limit: Int,
        encoding: Encoding.Type
    ) -> Self where Self == StringOutput<Encoding> {
        return .init(limit: limit, encoding: encoding)
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension OutputProtocol where Self == BytesOutput {
    /// Create a `Subprocess` output that collects output as
    /// `Buffer` with 128kb limit.
    public static var bytes: Self { .init(limit: 128 * 1024) }

    /// Create a `Subprocess` output that collects output as
    /// `Buffer` up to limit it bytes.
    public static func bytes(limit: Int) -> Self {
        return .init(limit: limit)
    }
}

// MARK: - Span Default Implementations
#if SubprocessSpan
@available(SubprocessSpan, *)
extension OutputProtocol {
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
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension OutputProtocol {
    @_disfavoredOverload
    internal func createPipe() throws -> CreatedPipe {
        if let discard = self as? DiscardedOutput {
            return try discard.createPipe()
        } else if let fdOutput = self as? FileDescriptorOutput {
            return try fdOutput.createPipe()
        }
        // Base pipe based implementation for everything else
        return try CreatedPipe(closeWhenDone: true)
    }

    /// Capture the output from the subprocess up to maxSize
    @_disfavoredOverload
    internal func captureOutput(
        from diskIO: consuming TrackedPlatformDiskIO?
    ) async throws -> OutputType {
        if let bytesOutput = self as? BytesOutput {
            return try await bytesOutput.captureOutput(from: diskIO) as! Self.OutputType
        }

        if OutputType.self == Void.self {
            return () as! OutputType
        }

        guard let diskIO = diskIO else {
            // Show not happen due to type system constraints
            fatalError("Trying to capture output without file descriptor")
        }

        #if os(Windows)
        let result = try await diskIO.fileDescriptor.read(upToLength: self.maxSize)
        return try self.output(from: result ?? [])
        #else
        let result = try await diskIO.dispatchIO.read(upToLength: self.maxSize)
        return try self.output(from: result ?? .empty)
        #endif
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension OutputProtocol where OutputType == Void {
    internal func captureOutput(from fileDescriptor: consuming TrackedPlatformDiskIO?) async throws {}

    #if SubprocessSpan
    /// Convert the output from Data to expected output type
    public func output(from span: RawSpan) throws {
        // noop
    }
    #else
    public func output(from buffer: some Sequence<UInt8>) throws {
        // noop
    }
    #endif  // SubprocessSpan
}

#if SubprocessSpan
@available(SubprocessSpan, *)
extension OutputProtocol {
    #if os(Windows)
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
    #else
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
    #endif // os(Windows)
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
