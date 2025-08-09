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
struct SubprocessAsyncIOTests { }

// MARK: - Basic Functionality Tests
extension SubprocessAsyncIOTests {
    @Test func testBasicReadWrite() async throws {
        let testData = randomData(count: 1024)
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try await readIO.read(from: readTestBed.ioChannel, upTo: .max)
            #expect(Array(readData!) == testData)
        } writer: { writeIO, writeTestBed in
            _ = try await writeIO.write(testData, to: writeTestBed.ioChannel)
            try await writeTestBed.finish()
        }
    }

    @Test func testMultipleSequentialReadWrite() async throws {
        var _chunks: [[UInt8]] = []
        for _ in 0 ..< 10 {
            // Generate some that's short
            _chunks.append(randomData(count: Int.random(in: 1 ..< 512)))
        }
        for _ in 0 ..< 10 {
            // Generate some that are longer than buffer size
            _chunks.append(randomData(count: Int.random(in: Subprocess.readBufferSize ..< Subprocess.readBufferSize * 3)))
        }
        _chunks.shuffle()
        let chunks = _chunks
        try await runReadWriteTest { readIO, readTestBed in
            for expectedChunk in chunks {
                let readData = try await readIO.read(from: readTestBed.ioChannel, upTo: expectedChunk.count)
                #expect(readData != nil)
                #expect(Array(readData!) == expectedChunk)
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
            let readData = try await readIO.read(from: readTestBed.ioChannel, upTo: .max)
            #expect(Array(readData!) == testData)
        } writer: { writeIO, writeTestBed in
            _ = try await writeIO.write(testData, to: writeTestBed.ioChannel)
            try await writeTestBed.finish()
        }
    }
}


// MARK: - Error Handling Tests
extension SubprocessAsyncIOTests {
    @Test func testWriteToClosedPipe() async throws {
        var pipe = try CreatedPipe(closeWhenDone: true, purpose: .input)
        var writeChannel = pipe.writeFileDescriptor()!.createIOChannel()
        var readChannel = pipe.readFileDescriptor()!.createIOChannel()
        defer {
            try? readChannel.safelyClose()
        }

        try writeChannel.safelyClose()

        do {
            _ = try await AsyncIO.shared.write([100], to: writeChannel)
            Issue.record("Expected write to closed pipe to throw an error")
        } catch {
            guard let subprocessError = error as? SubprocessError else {
                Issue.record("Expecting SubprocessError, but got \(error)")
                return
            }
            #if canImport(Darwin)
            #expect(subprocessError.underlyingError == .init(rawValue: ECANCELED))
            #elseif os(Linux)
            #expect(subprocessError.underlyingError == .init(rawValue: EBADF))
            #endif
        }
    }

    @Test func testReadFromClosedPipe() async throws {
        var pipe = try CreatedPipe(closeWhenDone: true, purpose: .input)
        var writeChannel = pipe.writeFileDescriptor()!.createIOChannel()
        var readChannel = pipe.readFileDescriptor()!.createIOChannel()
        defer {
            try? writeChannel.safelyClose()
        }

        try readChannel.safelyClose()

        do {
            _ = try await AsyncIO.shared.read(from: readChannel, upTo: .max)
            Issue.record("Expected write to closed pipe to throw an error")
        } catch {
            guard let subprocessError = error as? SubprocessError else {
                Issue.record("Expecting SubprocessError, but got \(error)")
                return
            }
            #if canImport(Darwin)
            #expect(subprocessError.underlyingError == .init(rawValue: ECANCELED))
            #elseif os(Linux)
            #expect(subprocessError.underlyingError == .init(rawValue: EBADF))
            #endif
        }
    }

    @Test func testBinaryDataWithNullBytes() async throws {
        let binaryData: [UInt8] = [0x00, 0x01, 0x02, 0x00, 0xFF, 0x00, 0xFE, 0xFD]
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try await readIO.read(from: readTestBed.ioChannel, upTo: .max)
            #expect(readData != nil)
            #expect(Array(readData!) == binaryData)
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
                let readTestBed = TestBed(ioChannel: readIOContainer.take()!)
                try await reader(readIO, readTestBed)
            }
            group.addTask {
                var writeIOContainer: IOChannel? = writeBox.take()
                let writeTestBed = TestBed(ioChannel: writeIOContainer.take()!)
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
#if canImport(WinSDK)
        try _safelyClose(.handle(self.ioChannel.channel))
#elseif canImport(Darwin)
        try _safelyClose(.dispatchIO(self.ioChannel.channel))
#else
        try _safelyClose(.fileDescriptor(self.ioChannel.channel))
#endif
    }

    func delay(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
