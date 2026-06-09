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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

import Testing
import Foundation
import TestResources
import _SubprocessCShims
@testable import Subprocess

@Suite("Subprocess.AsyncIO Unit Tests", .serialized)
struct SubprocessAsyncIOTests {
    init() {
        _ = globallyIgnoredSIGPIPE
    }
}

// MARK: - Basic Functionality Tests
extension SubprocessAsyncIOTests {
    @Test func testBasicReadWrite() async throws {
        let testData = randomData(count: 1024)
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try await readUntilEOF(
                from: readTestBed.ioDescriptor, with: readIO
            )
            #expect(Array(readData) == testData)
        } writer: { writeIO, writeTestBed in
            _ = try await writeIO.write(testData, to: writeTestBed.ioDescriptor)
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
            _chunks.append(randomData(count: Int.random(in: Subprocess.systemPageSize..<Subprocess.systemPageSize * 3)))
        }
        _chunks.shuffle()
        let chunks = _chunks
        try await runReadWriteTest { readIO, readTestBed in
            // `read` returns after each underlying read, so accumulate
            // until we have the expected chunk's worth of bytes.
            for expectedChunk in chunks {
                var readData: [UInt8] = []
                while readData.count < expectedChunk.count {
                    let chunk = try await read(
                        until: expectedChunk.count - readData.count,
                        from: readTestBed.ioDescriptor,
                        with: readIO
                    )
                    readData.append(contentsOf: chunk)
                }
                #expect(readData == expectedChunk)
            }

            // Final read should return nil
            let finalRead = try await readIO.read(from: readTestBed.ioDescriptor, upTo: 1024)
            #expect(finalRead == nil)
        } writer: { writeIO, writeTestBed in
            for chunk in chunks {
                _ = try await writeIO.write(chunk, to: writeTestBed.ioDescriptor)
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
            let readData = try await readIO.read(from: readTestBed.ioDescriptor, upTo: 1024)
            #expect(readData == nil)
        } writer: { writeIO, writeTestBed in
            // Close write end immediately without writing any data
            try await writeTestBed.finish()
        }
    }

    @Test func testZeroLengthRead() async throws {
        let testData = randomData(count: 64)
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try await readIO.read(from: readTestBed.ioDescriptor, upTo: 0)
            #expect(readData == nil)
        } writer: { writeIO, writeTestBed in
            _ = try await writeIO.write(testData, to: writeTestBed.ioDescriptor)
            try await writeTestBed.finish()
        }
    }

    @Test func testZeroLengthWrite() async throws {
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try await readIO.read(from: readTestBed.ioDescriptor, upTo: 1024)
            #expect(readData == nil)
        } writer: { writeIO, writeTestBed in
            let written = try await writeIO.write([], to: writeTestBed.ioDescriptor)
            #expect(written == 0)
            try await writeTestBed.finish()
        }
    }

    @Test func testLargeReadWrite() async throws {
        let testData = randomData(count: 1024 * 1024)
        try await runReadWriteTest { readIO, readTestBed in
            // `read` returns after each underlying read, so accumulate
            // until EOF.
            let readData = try await readUntilEOF(
                from: readTestBed.ioDescriptor, with: readIO
            )
            #expect(readData == testData)
        } writer: { writeIO, writeTestBed in
            _ = try await writeIO.write(testData, to: writeTestBed.ioDescriptor)
            try await writeTestBed.finish()
        }
    }
}

// MARK: - Error Handling Tests
extension SubprocessAsyncIOTests {
    @Test(.disabled("Cannot safely write to a closed fd without risking it being reused"))
    func testWriteToClosedPipe() async throws {
        var pipe = try CreatedPipe(closeWhenDone: true, purpose: .input)
        var writeChannel = try _require(pipe.writeFileDescriptor())
        var readChannel = try _require(pipe.readFileDescriptor())
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
            #expect(subprocessError.underlyingError == SubprocessError.WindowsError(win32Error: DWORD(ERROR_INVALID_HANDLE)))
            #elseif canImport(Darwin) || os(FreeBSD) || os(OpenBSD)
            #expect(subprocessError.underlyingError == Errno(rawValue: ECANCELED))
            #else
            // On Linux, depending on timing, either epoll_ctl or write
            // could throw error first
            #expect(
                subprocessError.underlyingError == Errno(rawValue: EBADF) || subprocessError.underlyingError == Errno(rawValue: EINVAL) || subprocessError.underlyingError == Errno(rawValue: EPERM)
            )
            #endif
            return true
        }

    }

    @Test(.disabled("Cannot safely read from a closed fd without risking it being reused"))
    func testReadFromClosedPipe() async throws {
        var pipe = try CreatedPipe(closeWhenDone: true, purpose: .input)
        var writeChannel = try _require(pipe.writeFileDescriptor())
        var readChannel = try _require(pipe.readFileDescriptor())
        defer {
            try? writeChannel.safelyClose()
        }

        try readChannel.safelyClose()

        await #expect {
            _ = try await AsyncIO.shared.read(from: readChannel, upTo: 1024)
        } throws: { error in
            guard let subprocessError = error as? SubprocessError else {
                return false
            }
            guard subprocessError.code == .init(.failedToReadFromSubprocess) else {
                return false
            }

            #if os(Windows)
            #expect(
                subprocessError.underlyingError == SubprocessError.WindowsError(win32Error: DWORD(ERROR_INVALID_HANDLE)))
            #elseif canImport(Darwin) || os(FreeBSD) || os(OpenBSD)
            #expect(
                subprocessError.underlyingError == Errno(rawValue: ECANCELED)
            )
            #else
            // On Linux, depending on timing, either epoll_ctl or read
            // could throw error first
            #expect(
                subprocessError.underlyingError == Errno(rawValue: EBADF) || subprocessError.underlyingError == Errno(rawValue: EINVAL) || subprocessError.underlyingError == Errno(rawValue: EPERM)
            )
            #endif
            return true
        }
    }

    @Test func testBinaryDataWithNullBytes() async throws {
        let binaryData: [UInt8] = [0x00, 0x01, 0x02, 0x00, 0xFF, 0x00, 0xFE, 0xFD]
        try await runReadWriteTest { readIO, readTestBed in
            let readData = try await readUntilEOF(
                from: readTestBed.ioDescriptor, with: readIO
            )
            #expect(Array(readData) == binaryData)
        } writer: { writeIO, writeTestBed in
            let written = try await writeIO.write(binaryData, to: writeTestBed.ioDescriptor)
            #expect(written == binaryData.count)
            try await writeTestBed.finish()
        }
    }
}

// MARK: - Cancellation Tests
extension SubprocessAsyncIOTests {
    @Test(.timeLimit(.minutes(1)))
    func testReadDrainsBufferedDataAfterCancellation() async throws {
        let payload = randomData(count: 1024)
        let io = AsyncIO.shared
        defer {
            io.cleanup(processIdentifier: _currentPID)
        }

        var pipe = try CreatedPipe(closeWhenDone: true, purpose: .input)
        let readTestBed = try TestBed(ioDescriptor: _require(pipe.readFileDescriptor()))
        let writeTestBed = try TestBed(ioDescriptor: _require(pipe.writeFileDescriptor()))

        // Buffer the payload with no read pending. It fits comfortably within
        // the pipe capacity, so the write completes without a reader.
        let written = try await io.write(payload, to: writeTestBed.ioDescriptor)
        #expect(written == payload.count)

        // Stand in for the termination monitor: the child has exited, so the
        // run cancels its I/O while bytes are still buffered.
        try io.cancelAsyncIO(for: _currentPID)

        let drained = try await io.read(
            from: readTestBed.ioDescriptor,
            upTo: payload.count
        )

        // Close promptly to bound any dangling-I/O window on a backend that
        // issues a read on the cancelled path without awaiting completion.
        try await readTestBed.finish()
        try await writeTestBed.finish()

        let bytes = try #require(
            drained,
            "read returned nil while \(payload.count) bytes were buffered: the cancelled path dropped them instead of draining"
        )
        #expect(bytes == payload)
    }

    @Test(.timeLimit(.minutes(1)))
    func testReadDrainsBufferedDataAfterCancellationOnAttachedHandle() async throws {
        let firstChunk = randomData(count: 1024)
        let secondChunk = randomData(count: 1024)
        let io = AsyncIO.shared
        defer {
            io.cleanup(processIdentifier: _currentPID)
        }

        var pipe = try CreatedPipe(closeWhenDone: true, purpose: .input)
        let readTestBed = try TestBed(ioDescriptor: _require(pipe.readFileDescriptor()))
        let writeTestBed = try TestBed(ioDescriptor: _require(pipe.writeFileDescriptor()))

        // Both chunks sit in the pipe buffer together.
        let written = try await io.write(firstChunk + secondChunk, to: writeTestBed.ioDescriptor)
        #expect(written == firstChunk.count + secondChunk.count)

        // A first, uncancelled read attaches the descriptor and consumes the
        // first chunk.
        let first = try await io.read(from: readTestBed.ioDescriptor, upTo: firstChunk.count)
        #expect(first == firstChunk)

        // Cancel while the second chunk is still buffered.
        try io.cancelAsyncIO(for: _currentPID)

        // The cancelled read must drain the second chunk from the now-cancelled,
        // already-attached descriptor.
        let second = try await io.read(from: readTestBed.ioDescriptor, upTo: secondChunk.count)

        try await readTestBed.finish()
        try await writeTestBed.finish()

        let drained = try #require(
            second,
            "read returned nil while \(secondChunk.count) buffered bytes remained on an already-attached descriptor: the cancelled path dropped them"
        )
        #expect(drained == secondChunk)
    }
}

// MARK: - Utils
extension SubprocessAsyncIOTests {
    final class TestBed: Sendable {
        let ioDescriptor: Subprocess.IODescriptor

        init(ioDescriptor: consuming Subprocess.IODescriptor) {
            var updated = consume ioDescriptor
            // TestBed.finish calls `_safelyClose()` directly
            updated.closeWhenDone = false
            self.ioDescriptor = updated
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

            var readDescriptor: IODescriptor? = pipe.readFileDescriptor()
            var writeDescriptor: IODescriptor? = pipe.writeFileDescriptor()

            let readIO = AsyncIO.shared
            let writeIO = AsyncIO()

            // Create TestBeds in outer scope so both pipe endpoints
            // stay alive until both tasks complete
            let readTestBed = try TestBed(ioDescriptor: _require(readDescriptor.take()))
            let writeTestBed = try TestBed(ioDescriptor: _require(writeDescriptor.take()))

            group.addTask {
                try await reader(readIO, readTestBed)
            }
            group.addTask {
                try await writer(writeIO, writeTestBed)
            }

            try await group.waitForAll()
            // Keep both pipe endpoints alive until both tasks complete,
            // preventing the cleanup handler from closing
            // a pipe fd while the other task is still using it.
            withExtendedLifetime((readTestBed, writeTestBed)) {}
            // Teardown
            // readIO shutdown is done via `atexit`.
            writeIO.shutdown()
        }
    }

    func readUntilEOF(
        from ioDescriptor: borrowing IODescriptor,
        with asyncIO: AsyncIO
    ) async throws -> [UInt8] {
        var result: [UInt8] = []
        let bufferSize = AsyncIO.queryPipeBufferSize(
            for: ioDescriptor.descriptor()
        )
        while let chunk = try await asyncIO.read(from: ioDescriptor, upTo: bufferSize) {
            result.append(contentsOf: chunk)
        }
        return result
    }

    func read(
        until readLength: Int,
        from ioDescriptor: borrowing IODescriptor,
        with asyncIO: AsyncIO
    ) async throws -> [UInt8] {
        guard readLength < .max else {
            fatalError("Use readUntilEOF instead")
        }
        var result: [UInt8] = []
        result.reserveCapacity(readLength)
        let bufferSize = AsyncIO.queryPipeBufferSize(
            for: ioDescriptor.descriptor()
        )
        while result.count < readLength {
            let targetLength = min(bufferSize, readLength - result.count)
            guard
                let chunk = try await asyncIO.read(
                    from: ioDescriptor, upTo: targetLength
                )
            else {
                break
            }
            result.append(contentsOf: chunk)
        }
        return result
    }
}

extension SubprocessAsyncIOTests.TestBed {
    consuming func finish() async throws {
        #if canImport(WinSDK)
        try _safelyClose(.handle(self.ioDescriptor.descriptor()))
        #else
        try _safelyClose(.fileDescriptor(self.ioDescriptor.descriptor()))
        #endif
    }

    func delay(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// A `ProcessIdentifier` for the current test process.
///
/// The AsyncIO-only tests below never spawn a child, so they have no
/// real `ProcessIdentifier` to pass. The tests only call `read` and
/// `write` (never `cancelAsyncIO`), so this stand-in is sufficient.
private var _currentPID: ProcessIdentifier {
    #if os(Windows)
    return ProcessIdentifier(
        value: GetCurrentProcessId(),
        processDescriptor: GetCurrentProcess(),
        threadHandle: GetCurrentThread(),
        jobHandle: INVALID_HANDLE_VALUE
    )
    #elseif canImport(Darwin)
    return ProcessIdentifier(value: getpid())
    #else
    return ProcessIdentifier(
        value: getpid(),
        processDescriptor: 0 // Not used in these tests.
    )
    #endif
}

extension AsyncIO {
    func write(
        _ array: [UInt8],
        to diskIO: borrowing IODescriptor
    ) async throws(SubprocessError) -> Int {
        return try await self.write(array._bytes, to: diskIO, for: _currentPID)
    }

    func read(
        from diskIO: borrowing IODescriptor,
        upTo maxLength: Int
    ) async throws(SubprocessError) -> [UInt8]? {
        return try await self.read(from: diskIO, for: _currentPID, upTo: maxLength)
    }
}
