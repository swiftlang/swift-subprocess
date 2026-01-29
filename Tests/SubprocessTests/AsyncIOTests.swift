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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

import Testing
import Dispatch
import Foundation
import TestResources
import _SubprocessCShims
@testable import Subprocess

@Suite("Subprocess.AsyncIO Unit Tests", .serialized)
struct SubprocessAsyncIOTests {}

// MARK: - Basic Functionality Tests
extension SubprocessAsyncIOTests {
    @Test func testBasicReadWrite() async throws {
        let testData = randomData(count: 1024)
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try #require(
                try await readIO.read(from: readTestBed.ioChannel, upTo: .max)
            )
            #expect(Array(readData) == testData)
        } writer: { writeIO, writeTestBed in
            _ = try await writeIO.write(testData, to: writeTestBed.ioChannel)
            try await writeTestBed.finish()
        }
    }

    @Test func testMultipleSequentialReadWrite() async throws {
        var _chunks: [[UInt8]] = []
        for _ in 0..<10 {
            // Generate some that's short
            _chunks.append(randomData(count: Int.random(in: 1..<512)))
        }
        for _ in 0..<10 {
            // Generate some that are longer than buffer size
            _chunks.append(randomData(count: Int.random(in: Subprocess.readBufferSize..<Subprocess.readBufferSize * 3)))
        }
        _chunks.shuffle()
        let chunks = _chunks
        try await runReadWriteTest { readIO, readTestBed in
            for expectedChunk in chunks {
                let readData = try #require(
                    try await readIO.read(from: readTestBed.ioChannel, upTo: expectedChunk.count)
                )
                #expect(Array(readData) == expectedChunk)
            }

            // Final read should return nil
            let finalRead = try await readIO.read(from: readTestBed.ioChannel, upTo: .max)
            #expect(finalRead == nil)
        } writer: { writeIO, writeTestBed in
            for chunk in chunks {
                _ = try await writeIO.write(chunk, to: writeTestBed.ioChannel)
                try await writeTestBed.delay(.milliseconds(10))
            }
            try await writeTestBed.finish()
        }
    }
}

// MARK: - Edge Case Tests
extension SubprocessAsyncIOTests {
    @Test func testReadFromEmptyPipe() async throws {
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try await readIO.read(from: readTestBed.ioChannel, upTo: .max)
            #expect(readData == nil)
        } writer: { writeIO, writeTestBed in
            // Close write end immediately without writing any data
            try await writeTestBed.finish()
        }
    }

    @Test func testZeroLengthRead() async throws {
        let testData = randomData(count: 64)
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try await readIO.read(from: readTestBed.ioChannel, upTo: 0)
            #expect(readData == nil)
        } writer: { writeIO, writeTestBed in
            _ = try await writeIO.write(testData, to: writeTestBed.ioChannel)
            try await writeTestBed.finish()
        }
    }

    @Test func testZeroLengthWrite() async throws {
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try await readIO.read(from: readTestBed.ioChannel, upTo: .max)
            #expect(readData == nil)
        } writer: { writeIO, writeTestBed in
            let written = try await writeIO.write([], to: writeTestBed.ioChannel)
            #expect(written == 0)
            try await writeTestBed.finish()
        }
    }

    @Test func testLargeReadWrite() async throws {
        let testData = randomData(count: 1024 * 1024)
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try #require(
                try await readIO.read(from: readTestBed.ioChannel, upTo: .max)
            )
            #expect(Array(readData) == testData)
        } writer: { writeIO, writeTestBed in
            _ = try await writeIO.write(testData, to: writeTestBed.ioChannel)
            try await writeTestBed.finish()
        }
    }
}

// MARK: - Error Handling Tests
extension SubprocessAsyncIOTests {
    @Test(.disabled("Cannot safely write to a closed fd without risking it being reused"))
    func testWriteToClosedPipe() async throws {
        var pipe = try CreatedPipe(closeWhenDone: true, purpose: .input)
        var writeChannel = try _require(pipe.writeFileDescriptor()).createIOChannel()
        var readChannel = try _require(pipe.readFileDescriptor()).createIOChannel()
        defer {
            try? readChannel.safelyClose()
        }

        try writeChannel.safelyClose()

        await #expect {
            _ = try await AsyncIO.shared.write([100], to: writeChannel)
        } throws: { error in
            guard let subprocessError = error as? SubprocessError else {
                return false
            }
            guard subprocessError.code == .init(.failedToWriteToSubprocess) else {
                return false
            }

            #if os(Windows)
            #expect(subprocessError.underlyingError as! SubprocessError.WindowsError == SubprocessError.WindowsError(rawValue: DWORD(ERROR_INVALID_HANDLE)))
            #elseif canImport(Darwin) || os(FreeBSD) || os(OpenBSD)
            #expect(subprocessError.underlyingError as? Errno == Errno(rawValue: ECANCELED))
            #else
            // On Linux, depending on timing, either epoll_ctl or write
            // could throw error first
            #expect(
                subprocessError.underlyingError as? Errno == Errno(rawValue: EBADF) || subprocessError.underlyingError as? Errno == Errno(rawValue: EINVAL) || subprocessError.underlyingError as? Errno == Errno(rawValue: EPERM)
            )
            #endif
            return true
        }

    }

    @Test(.disabled("Cannot safely read from a closed fd without risking it being reused"))
    func testReadFromClosedPipe() async throws {
        var pipe = try CreatedPipe(closeWhenDone: true, purpose: .input)
        var writeChannel = try _require(pipe.writeFileDescriptor()).createIOChannel()
        var readChannel = try _require(pipe.readFileDescriptor()).createIOChannel()
        defer {
            try? writeChannel.safelyClose()
        }

        try readChannel.safelyClose()

        await #expect {
            _ = try await AsyncIO.shared.read(from: readChannel, upTo: .max)
        } throws: { error in
            guard let subprocessError = error as? SubprocessError else {
                return false
            }
            guard subprocessError.code == .init(.failedToReadFromSubprocess) else {
                return false
            }

            #if os(Windows)
            #expect(
                subprocessError.underlyingError as! SubprocessError.WindowsError == SubprocessError.WindowsError(rawValue: DWORD(ERROR_INVALID_HANDLE)))
            #elseif canImport(Darwin) || os(FreeBSD) || os(OpenBSD)
            #expect(
                subprocessError.underlyingError as? Errno == Errno(rawValue: ECANCELED)
            )
            #else
            // On Linux, depending on timing, either epoll_ctl or read
            // could throw error first
            #expect(
                subprocessError.underlyingError as? Errno == Errno(rawValue: EBADF) || subprocessError.underlyingError as? Errno == Errno(rawValue: EINVAL) || subprocessError.underlyingError as? Errno == Errno(rawValue: EPERM)
            )
            #endif
            return true
        }
    }

    @Test func testBinaryDataWithNullBytes() async throws {
        let binaryData: [UInt8] = [0x00, 0x01, 0x02, 0x00, 0xFF, 0x00, 0xFE, 0xFD]
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try #require(
                try await readIO.read(from: readTestBed.ioChannel, upTo: .max)
            )
            #expect(Array(readData) == binaryData)
        } writer: { writeIO, writeTestBed in
            let written = try await writeIO.write(binaryData, to: writeTestBed.ioChannel)
            #expect(written == binaryData.count)
            try await writeTestBed.finish()
        }
    }
}

// MARK: - Utils
extension SubprocessAsyncIOTests {
    final class TestBed {
        let ioChannel: Subprocess.IOChannel

        init(ioChannel: consuming Subprocess.IOChannel) {
            self.ioChannel = ioChannel
        }
    }
}

extension SubprocessAsyncIOTests {
    func runReadWriteTest(
        reader: @escaping @Sendable (AsyncIO, consuming SubprocessAsyncIOTests.TestBed) async throws -> Void,
        writer: @escaping @Sendable (AsyncIO, consuming SubprocessAsyncIOTests.TestBed) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup { group in
            // First create the pipe
            var pipe = try CreatedPipe(closeWhenDone: true, purpose: .input)

            let readChannel: IOChannel? = pipe.readFileDescriptor()?.createIOChannel()
            let writeChannel: IOChannel? = pipe.writeFileDescriptor()?.createIOChannel()

            var readBox: IOChannel? = consume readChannel
            var writeBox: IOChannel? = consume writeChannel

            let readIO = AsyncIO.shared
            let writeIO = AsyncIO()

            group.addTask {
                var readIOContainer: IOChannel? = readBox.take()
                let readTestBed = try TestBed(ioChannel: _require(readIOContainer.take()))
                try await reader(readIO, readTestBed)
            }
            group.addTask {
                var writeIOContainer: IOChannel? = writeBox.take()
                let writeTestBed = try TestBed(ioChannel: _require(writeIOContainer.take()))
                try await writer(writeIO, writeTestBed)
            }

            try await group.waitForAll()
            // Teardown
            // readIO shutdown is done via `atexit`.
            writeIO.shutdown()
        }
    }
}

extension SubprocessAsyncIOTests.TestBed {
    consuming func finish() async throws {
        #if SUBPROCESS_ASYNCIO_DISPATCH
        try _safelyClose(.dispatchIO(self.ioChannel.channel))
        #elseif canImport(WinSDK)
        try _safelyClose(.handle(self.ioChannel.channel))
        #else
        try _safelyClose(.fileDescriptor(self.ioChannel.channel))
        #endif
    }

    func delay(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
