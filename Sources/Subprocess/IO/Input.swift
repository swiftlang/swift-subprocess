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

#if SubprocessFoundation

#if canImport(Darwin)
// On Darwin always prefer system Foundation
import Foundation
#else
// On other platforms prefer FoundationEssentials
import FoundationEssentials
#endif

#endif // SubprocessFoundation

// MARK: - Input

/// A type that serves as the input source for a subprocess.
///
/// Conform to this protocol and implement ``write(with:)``
/// to provide a custom input source.
public protocol InputProtocol: Sendable, ~Copyable {
    /// Writes the input to the subprocess asynchronously.
    func write(with writer: StandardInputWriter) async throws
}

/// An input type that provides no input to the subprocess.
///
/// On Unix-like systems, ``NoInput`` redirects standard input to `/dev/null`.
/// On Windows, it redirects to `NUL`.
public struct NoInput: InputProtocol {
    internal func createPipe() throws(SubprocessError) -> CreatedPipe {
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

    /// Writes the input to the subprocess asynchronously.
    public func write(with writer: StandardInputWriter) async throws {
        fatalError("Unexpected call to \(#function)")
    }

    internal init() {}
}

/// An input type that reads from a specified file descriptor.
///
/// You can choose to have the subprocess automatically close
/// the file descriptor after it spawns.
public struct FileDescriptorInput: InputProtocol {
    private let fileDescriptor: FileDescriptor
    private let closeAfterSpawningProcess: Bool

    internal func createPipe() throws(SubprocessError) -> CreatedPipe {
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

    /// Writes the input to the subprocess asynchronously.
    public func write(with writer: StandardInputWriter) async throws {
        fatalError("Unexpected call to \(#function)")
    }

    internal init(
        fileDescriptor: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) {
        self.fileDescriptor = fileDescriptor
        self.closeAfterSpawningProcess = closeAfterSpawningProcess
    }
}

/// An input type that reads from a string.
///
/// Specify the encoding to use when converting the string
/// to bytes. The default encoding is UTF-8.
public struct StringInput<
    InputString: StringProtocol & Sendable,
    Encoding: Unicode.Encoding
>: InputProtocol {
    private let string: InputString

    /// Writes the input to the subprocess asynchronously.
    public func write(with writer: StandardInputWriter) async throws {
        guard let array = self.string.byteArray(using: Encoding.self) else {
            return
        }
        _ = try await writer.write(array)
    }

    internal init(string: InputString, encoding: Encoding.Type) {
        self.string = string
    }
}

/// An input type that reads from a `[UInt8]` array.
public struct ArrayInput: InputProtocol {
    private let array: [UInt8]

    /// Writes the input to the subprocess asynchronously.
    public func write(with writer: StandardInputWriter) async throws {
        _ = try await writer.write(self.array)
    }

    internal init(array: [UInt8]) {
        self.array = array
    }
}

/// A concrete input type that the run closure uses to write custom input
/// into the subprocess.
internal struct CustomWriteInput: InputProtocol {
    /// Asynchronously write the input to the subprocess using the
    /// write file descriptor.
    public func write(with writer: StandardInputWriter) async throws {
        fatalError("Unexpected call to \(#function)")
    }

    internal init() {}
}

extension InputProtocol where Self == NoInput {
    /// Creates a subprocess input that provides no input.
    public static var none: Self { .init() }
}

extension InputProtocol where Self == FileDescriptorInput {
    /// Creates a subprocess input from a file descriptor.
    ///
    /// Set `closeAfterSpawningProcess` to `true` to close the file
    /// descriptor after the subprocess spawns.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> Self {
        return .init(
            fileDescriptor: fd,
            closeAfterSpawningProcess: closeAfterSpawningProcess
        )
    }

    /// Creates a subprocess input that reads from the current process's standard input.
    ///
    /// The file descriptor isn't closed afterward.
    public static var standardInput: Self {
        return Self.fileDescriptor(
            .standardInput,
            closeAfterSpawningProcess: false
        )
    }
}

extension InputProtocol {
    /// Creates a subprocess input from an array of bytes.
    public static func array(
        _ array: [UInt8]
    ) -> Self where Self == ArrayInput {
        return ArrayInput(array: array)
    }

    /// Creates a subprocess input from a string.
    public static func string<
        InputString: StringProtocol & Sendable
    >(
        _ string: InputString
    ) -> Self where Self == StringInput<InputString, UTF8> {
        return .init(string: string, encoding: UTF8.self)
    }

    /// Creates a subprocess input from a string.
    public static func string<
        InputString: StringProtocol & Sendable,
        Encoding: Unicode.Encoding
    >(
        _ string: InputString,
        using encoding: Encoding.Type
    ) -> Self where Self == StringInput<InputString, Encoding> {
        return .init(string: string, encoding: encoding)
    }
}

extension InputProtocol {
    internal func createPipe() throws(SubprocessError) -> CreatedPipe {
        if let noInput = self as? NoInput {
            return try noInput.createPipe()
        } else if let fdInput = self as? FileDescriptorInput {
            return try fdInput.createPipe()
        }
        // Base implementation
        return try CreatedPipe(closeWhenDone: true, purpose: .input)
    }
}

// MARK: - StandardInputWriter

/// A writer that sends data to the standard input of a subprocess.
public final actor StandardInputWriter: Sendable {

    internal var diskIO: IOChannel

    init(diskIO: consuming IOChannel) {
        self.diskIO = diskIO
    }

    /// Writes an array of bytes to the subprocess's standard input.
    /// - Parameter array: The bytes to write.
    /// - Throws: `SubprocessError` with error code `.failedToWriteToSubprocess`.
    ///     See ``underlyingError`` for more details.
    /// - Returns: The number of bytes written.
    public func write(
        _ array: [UInt8]
    ) async throws(SubprocessError) -> Int {
        return try await AsyncIO.shared.write(array, to: self.diskIO)
    }

    /// Writes a raw span to the subprocess's standard input.
    ///
    /// - Parameter span: The span to write.
    /// - Throws: `SubprocessError` with error code `.failedToWriteToSubprocess`.
    ///     See ``underlyingError`` for more details.
    /// - Returns: The number of bytes written.
    public func write(_ span: borrowing RawSpan) async throws(SubprocessError) -> Int {
        return try await AsyncIO.shared.write(span, to: self.diskIO)
    }

    /// Writes a string to the subprocess's standard input.
    /// - Parameters:
    ///   - string: The string to write.
    ///   - encoding: The encoding to use when converting the string to bytes.
    /// - Throws: `SubprocessError` with error code `.failedToWriteToSubprocess`.
    ///     See ``underlyingError`` for more details.
    /// - Returns: The number of bytes written.
    public func write<Encoding: Unicode.Encoding>(
        _ string: some StringProtocol,
        using encoding: Encoding.Type = UTF8.self
    ) async throws(SubprocessError) -> Int {
        if let array = string.byteArray(using: encoding) {
            return try await self.write(array)
        }
        return 0
    }

    /// Signals that all writes are finished.
    /// - Throws: `SubprocessError` with error code `.asyncIOFailed`.
    ///     See ``underlyingError`` for more details.
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
