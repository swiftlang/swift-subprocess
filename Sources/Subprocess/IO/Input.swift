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

#if SubprocessFoundation

#if canImport(Darwin)
// On Darwin always prefer system Foundation
import Foundation
#else
// On other platforms prefer FoundationEssentials
import FoundationEssentials
#endif

#endif // SubprocessFoundation

// MARK: - InputMethod

/// Specifies how a subprocess should receive its standard input.
///
/// Use the provided static factory methods (`.none`, `.string(_:)`,
/// `.array(_:)`, `.fileDescriptor(_:closeAfterSpawningProcess:)`) to create
/// input configurations.
public struct InputMethod: Sendable {
    internal let _createPipe: @Sendable () throws -> CreatedPipe
    internal let _write: @Sendable (StandardInputWriter) async throws -> Void

    internal init(
        createPipe: @escaping @Sendable () throws -> CreatedPipe,
        write: @escaping @Sendable (StandardInputWriter) async throws -> Void
    ) {
        self._createPipe = createPipe
        self._write = write
    }
}

extension InputMethod {
    /// Create a Subprocess input that specifies there is no input.
    ///
    /// On Unix-like systems, this redirects the standard input of the subprocess
    /// to `/dev/null`, while on Windows, it redirects to `NUL`.
    public static var none: InputMethod {
        let inner = NoInput()
        return InputMethod(
            createPipe: { try inner.createPipe() },
            write: { _ in }
        )
    }

    /// Create a Subprocess input from a `FileDescriptor` and
    /// specify whether the `FileDescriptor` should be closed
    /// after the process is spawned.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> InputMethod {
        let inner = FileDescriptorInput(
            fileDescriptor: fd,
            closeAfterSpawningProcess: closeAfterSpawningProcess
        )
        return InputMethod(
            createPipe: { try inner.createPipe() },
            write: { _ in }
        )
    }

    /// Create a Subprocess input that reads from the standard input of
    /// current process.
    ///
    /// The file descriptor isn't closed afterwards.
    public static var standardInput: InputMethod {
        return .fileDescriptor(
            .standardInput,
            closeAfterSpawningProcess: false
        )
    }

    /// Create a Subprocess input from a type that conforms to `StringProtocol`.
    public static func string(
        _ string: some StringProtocol & Sendable
    ) -> InputMethod {
        let inner = StringInput(string: string, encoding: UTF8.self)
        return InputMethod(
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .input) },
            write: { writer in try await inner.write(with: writer) }
        )
    }

    /// Create a Subprocess input from a type that conforms to `StringProtocol`
    /// with a specified encoding.
    public static func string<Encoding: Unicode.Encoding>(
        _ string: some StringProtocol & Sendable,
        using encoding: Encoding.Type
    ) -> InputMethod {
        let inner = StringInput(string: string, encoding: encoding)
        return InputMethod(
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .input) },
            write: { writer in try await inner.write(with: writer) }
        )
    }

    /// Create a Subprocess input from an `Array` of `UInt8`.
    public static func array(_ array: [UInt8]) -> InputMethod {
        let inner = ArrayInput(array: array)
        return InputMethod(
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .input) },
            write: { writer in try await inner.write(with: writer) }
        )
    }

    /// Internal: creates a pipe for custom write (body-closure and Span overloads).
    internal static var _customWrite: InputMethod {
        return InputMethod(
            createPipe: { try CreatedPipe(closeWhenDone: true, purpose: .input) },
            write: { _ in }
        )
    }
}

// MARK: - Internal Concrete Input Types

internal struct NoInput {
    func createPipe() throws(SubprocessError) -> CreatedPipe {
        #if os(Windows)
        let devnullFd: FileDescriptor = try .openDevNull(withAccessMode: .writeOnly)
        let devnull = HANDLE(bitPattern: _get_osfhandle(devnullFd.rawValue))!
        #else
        let devnull: FileDescriptor = try .openDevNull(withAccessMode: .readOnly)
        #endif
        return CreatedPipe(
            readFileDescriptor: .init(devnull, closeWhenDone: true),
            writeFileDescriptor: nil
        )
    }

    init() {}
}

internal struct FileDescriptorInput {
    private let fileDescriptor: FileDescriptor
    private let closeAfterSpawningProcess: Bool

    func createPipe() throws(SubprocessError) -> CreatedPipe {
        #if canImport(WinSDK)
        let readFd = HANDLE(bitPattern: _get_osfhandle(self.fileDescriptor.rawValue))!
        #else
        let readFd = self.fileDescriptor
        #endif
        return CreatedPipe(
            readFileDescriptor: .init(
                readFd,
                closeWhenDone: self.closeAfterSpawningProcess
            ),
            writeFileDescriptor: nil
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

internal struct StringInput<
    InputString: StringProtocol & Sendable,
    Encoding: Unicode.Encoding
>: Sendable {
    private let string: InputString

    func write(with writer: StandardInputWriter) async throws {
        guard let array = self.string.byteArray(using: Encoding.self) else {
            return
        }
        _ = try await writer.write(array)
    }

    init(string: InputString, encoding: Encoding.Type) {
        self.string = string
    }
}

internal struct ArrayInput: Sendable {
    private let array: [UInt8]

    func write(with writer: StandardInputWriter) async throws {
        _ = try await writer.write(self.array)
    }

    init(array: [UInt8]) {
        self.array = array
    }
}

// MARK: - StandardInputWriter

/// A writer that writes to the standard input of the subprocess.
public final actor StandardInputWriter: Sendable {

    internal var diskIO: IOChannel

    init(diskIO: consuming IOChannel) {
        self.diskIO = diskIO
    }

    /// Write an array of 8-bit unsigned integers to the standard input of the subprocess.
    /// - Parameter array: The sequence of bytes to write.
    /// - Throws: `SubprocessError` with error code `.failedToWriteToSubprocess`.
    ///     See `.underlyingError` for more details.
    /// - Returns: the number of bytes written.
    public func write(
        _ array: [UInt8]
    ) async throws(SubprocessError) -> Int {
        return try await AsyncIO.shared.write(array, to: self.diskIO)
    }

    #if SubprocessSpan
    /// Write a raw span to the standard input of the subprocess.
    ///
    /// - Parameter `span`: The span to write.
    /// - Throws: `SubprocessError` with error code `.failedToWriteToSubprocess`.
    ///     See `.underlyingError` for more details.
    /// - Returns: the number of bytes written.
    public func write(_ span: borrowing RawSpan) async throws(SubprocessError) -> Int {
        return try await AsyncIO.shared.write(span, to: self.diskIO)
    }
    #endif

    /// Write a type that conforms to StringProtocol to the standard input of the subprocess.
    /// - Parameters:
    ///   - string: The string to write.
    ///   - encoding: The encoding to use when converting string to bytes
    /// - Throws: `SubprocessError` with error code `.failedToWriteToSubprocess`.
    ///     See `.underlyingError` for more details.
    /// - Returns: number of bytes written.
    public func write<Encoding: Unicode.Encoding>(
        _ string: some StringProtocol,
        using encoding: Encoding.Type = UTF8.self
    ) async throws(SubprocessError) -> Int {
        if let array = string.byteArray(using: encoding) {
            return try await self.write(array)
        }
        return 0
    }

    /// Signal all writes are finished
    /// - Throws: `SubprocessError` with error code `.asyncIOFailed`.
    ///     See `.underlyingError` for more detail.
    public func finish() async throws(SubprocessError) {
        try self.diskIO.safelyClose()
    }
}

extension StringProtocol {
    #if SubprocessFoundation
    private func convertEncoding<Encoding: Unicode.Encoding>(
        _ encoding: Encoding.Type
    ) -> String.Encoding? {
        switch encoding {
        case is UTF8.Type:
            return .utf8
        case is UTF16.Type:
            return .utf16
        case is UTF32.Type:
            return .utf32
        default:
            return nil
        }
    }
    #endif
    package func byteArray<Encoding: Unicode.Encoding>(using encoding: Encoding.Type) -> [UInt8]? {
        if Encoding.self == Unicode.ASCII.self {
            let isASCII = self.utf8.allSatisfy {
                return Character(Unicode.Scalar($0)).isASCII
            }

            guard isASCII else {
                return nil
            }
            return Array(self.utf8)
        }
        if Encoding.self == UTF8.self {
            return Array(self.utf8)
        }
        if Encoding.self == UTF16.self {
            return Array(self.utf16).flatMap { input in
                var uint16: UInt16 = input
                return withUnsafeBytes(of: &uint16) { ptr in
                    Array(ptr)
                }
            }
        }
        #if SubprocessFoundation
        if let stringEncoding = self.convertEncoding(encoding),
            let encoded = self.data(using: stringEncoding)
        {
            return Array(encoded)
        }
        return nil
        #else
        return nil
        #endif
    }
}

extension String {
    package init<T: FixedWidthInteger, Encoding: Unicode.Encoding>(
        decodingBytes bytes: [T],
        as encoding: Encoding.Type
    ) {
        self = bytes.withUnsafeBytes { raw in
            String(
                decoding: raw.bindMemory(to: Encoding.CodeUnit.self).lazy.map { $0 },
                as: encoding
            )
        }
    }
}
