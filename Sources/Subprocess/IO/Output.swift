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
public import System
#else
public import SystemPackage
#endif

#if canImport(WinSDK)
@preconcurrency import WinSDK
#endif

// MARK: - Output

/// A type that serves as the output target for a subprocess.
public protocol OutputProtocol: Sendable, ~Copyable {
    /// The Swift value this output type produces after collecting subprocess output.
    associatedtype OutputType: Sendable

    /// Converts the bytes collected from the subprocess's output stream into
    /// ``OutputType``.
    ///
    /// - Parameter span: The collected output bytes, valid only for the
    ///   duration of the call.
    /// - Returns: The converted output value.
    /// - Throws: An error if the conversion fails.
    func output(from span: RawSpan) throws -> OutputType

    /// The maximum number of bytes to collect from the subprocess's output
    /// stream.
    ///
    /// If the subprocess produces more than this many bytes, `Subprocess`
    /// throws ``SubprocessError`` with the code
    /// ``SubprocessError/Code/outputLimitExceeded``.
    var maxSize: Int { get }
}

extension OutputProtocol {
    /// The default maximum number of bytes to collect: 128 KB.
    public var maxSize: Int { 128 * 1024 }
}

/// An output type that discards output from the subprocess.
///
/// On Unix-like systems, ``DiscardedOutput`` redirects standard output
/// to `/dev/null`. On Windows, it redirects to `NUL`.
public struct DiscardedOutput: OutputProtocol, ErrorOutputProtocol {
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
/// the file descriptor after it launches.
public struct FileDescriptorOutput: OutputProtocol, ErrorOutputProtocol {
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

/// An output type that collects the subprocess's output as decoded text using the encoding you provide.
public struct StringOutput<Encoding: Unicode.Encoding>: OutputProtocol, ErrorOutputProtocol {
    public typealias OutputType = String?
    public let maxSize: Int

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

/// An output type that collects the subprocess's output as a byte array.
public struct BytesOutput: OutputProtocol, ErrorOutputProtocol {
    public typealias OutputType = [UInt8]
    public let maxSize: Int

    internal func captureOutput(
        from diskIO: consuming IODescriptor,
        for processIdentifier: ProcessIdentifier
    ) async throws(SubprocessError) -> [UInt8] {
        var result: [UInt8] = []
        do {
            var maxLength = self.maxSize
            if maxLength != .max {
                // Read one extra byte to detect output that exceeds the
                // limit.
                maxLength += 1
                // Reserve capacity to avoid reallocations.
                result.reserveCapacity(maxLength)
            }
            let bufferSize = AsyncIO.queryPipeBufferSize(for: diskIO.descriptor())

            while result.count < maxLength {
                let remaining = maxLength - result.count
                guard
                    let chunk = try await AsyncIO.shared.read(
                        from: diskIO,
                        for: processIdentifier,
                        upTo: min(bufferSize, remaining)
                    )
                else {
                    break
                }
                result.append(contentsOf: chunk)
            }
        } catch {
            try diskIO.safelyClose()
            throw error
        }
        try diskIO.safelyClose()

        if result.count > self.maxSize {
            throw .outputLimitExceeded(limit: self.maxSize)
        }
        return result
    }

    public func output(from span: RawSpan) throws -> [UInt8] {
        span.withUnsafeBytes { Array($0) }
    }

    internal init(limit: Int) {
        self.maxSize = limit
    }
}

/// An output type that streams the subprocess's output through the body
/// closure as an asynchronous sequence of buffers.
///
/// Use ``OutputProtocol/sequence`` to create a value of this type when you
/// call a `run` function that takes a body closure. The closure reads the
/// output by iterating ``Execution/standardOutput`` or
/// ``Execution/standardError``.
public struct SequenceOutput: OutputProtocol, ErrorOutputProtocol {
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
    /// descriptor after the subprocess launches.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> Self {
        return .init(fileDescriptor: fd, closeAfterSpawningProcess: closeAfterSpawningProcess)
    }

    /// Creates a subprocess output that writes to the current process's standard output.
    ///
    /// The file descriptor isn't closed afterward.
    public static var currentStandardOutput: Self {
        return Self.fileDescriptor(
            .standardOutput,
            closeAfterSpawningProcess: false
        )
    }

    // TODO: remove for 1.0
    @available(*, deprecated, renamed: "currentStandardOutput")
    public static var standardOutput: Self {
        return currentStandardOutput
    }

    /// Creates a subprocess output that writes to the current process's standard error.
    ///
    /// The file descriptor isn't closed afterward.
    public static var currentStandardError: Self {
        return Self.fileDescriptor(
            .standardError,
            closeAfterSpawningProcess: false
        )
    }

    // TODO: remove for 1.0
    @available(*, deprecated, renamed: "currentStandardError")
    public static var standardError: Self {
        return currentStandardError
    }
}

extension OutputProtocol where Self == StringOutput<UTF8> {
    /// Creates a subprocess output that collects output as a UTF-8 string.
    ///
    /// The subprocess throws an error if the process
    /// produces more bytes than `limit`.
    public static func string(limit: Int) -> Self {
        return .init(limit: limit, encoding: UTF8.self)
    }
}

extension OutputProtocol {
    /// Creates a subprocess output that collects output as
    /// a string using the encoding you provide, up to `limit` bytes.
    ///
    /// The subprocess throws an error if the process
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
    /// The subprocess throws an error if the process
    /// produces more bytes than `limit`.
    public static func bytes(limit: Int) -> Self {
        return .init(limit: limit)
    }
}

extension OutputProtocol where Self == SequenceOutput {
    /// Creates a subprocess output that a body closure reads as an asynchronous sequence of buffers.
    ///
    /// Use this output with a `run` overload that takes a body closure.
    public static var sequence: Self {
        return SequenceOutput()
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
/// standard output and standard error from the subprocess are merged into a
/// single output stream. This is equivalent to using shell redirection like `2>&1`.
///
/// This output type is useful when you want to capture or redirect both output
/// streams together, making it possible to process all subprocess output as a unified
/// stream rather than handling standard output and standard error separately.
public struct CombinedErrorOutput: ErrorOutputProtocol {
    public typealias OutputType = Void

    internal init() {}
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
    /// the subprocess are merged into a single output stream. This is equivalent
    /// to using shell redirection like `2>&1`.
    ///
    /// This is useful when you want to capture or redirect both output streams
    /// together, making it possible to process all subprocess output as a unified
    /// stream rather than handling standard output and standard error separately.
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

    /// Captures the output from the subprocess, up to `maxSize` bytes.
    @_disfavoredOverload
    internal func captureOutput(
        from diskIO: consuming IODescriptor?,
        for processIdentifier: ProcessIdentifier
    ) async throws -> OutputType {
        if OutputType.self == Void.self {
            try diskIO?.safelyClose()
            return () as! OutputType
        }
        // `diskIO` is only `nil` for types that conform to `OutputProtocol`
        // and have `Void` as `OutputType` (such as `DiscardedOutput`). The
        // line above already returned for the `Void` case, so `diskIO`
        // must not be `nil` here; otherwise the call site is a programmer
        // error.
        guard var diskIO else {
            fatalError(
                "Internal Inconsistency Error: diskIO must not be nil when OutputType is not Void"
            )
        }

        if let bytesOutput = self as? BytesOutput {
            return try await bytesOutput.captureOutput(
                from: diskIO, for: processIdentifier
            ) as! Self.OutputType
        }

        var result: [UInt8] = []
        do {
            var maxLength = self.maxSize
            if maxLength != .max {
                // Read one extra byte to detect output that exceeds the
                // limit.
                maxLength += 1
                result.reserveCapacity(maxLength)
            }
            let bufferSize = AsyncIO.queryPipeBufferSize(for: diskIO.descriptor())

            while result.count < maxLength {
                let remaining = maxLength - result.count
                guard
                    let chunk = try await AsyncIO.shared.read(
                        from: diskIO,
                        for: processIdentifier,
                        upTo: min(bufferSize, remaining)
                    )
                else {
                    break
                }
                result.append(contentsOf: chunk)
            }
        } catch {
            try diskIO.safelyClose()
            throw error
        }

        try diskIO.safelyClose()
        if result.count > self.maxSize {
            throw SubprocessError.outputLimitExceeded(limit: self.maxSize)
        }

        return try self.output(from: result)
    }
}

extension OutputProtocol where OutputType == Void {
    internal func captureOutput(
        from fileDescriptor: consuming IODescriptor?,
        for processIdentifier: ProcessIdentifier
    ) async throws {}

    /// Produces no output value, because ``OutputType`` is `Void`.
    ///
    /// - Parameter span: Ignored; a `Void` output type has no value to
    ///   produce.
    public func output(from span: RawSpan) throws {
        // When OutputType is Void, there is no output to process,
        // So this is effectively a no-op.
    }
}

extension OutputProtocol {
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
