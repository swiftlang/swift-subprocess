//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
internal struct AsyncBufferSequence: AsyncSequence, Sendable {
    internal typealias Failure = any Swift.Error

    internal typealias Element = SequenceOutput.Buffer

    @_nonSendable
    internal struct Iterator: AsyncIteratorProtocol {
        internal typealias Element = SequenceOutput.Buffer

        private let fileDescriptor: TrackedFileDescriptor
        private var buffer: [UInt8]
        private var currentPosition: Int
        private var finished: Bool

        internal init(fileDescriptor: TrackedFileDescriptor) {
            self.fileDescriptor = fileDescriptor
            self.buffer = []
            self.currentPosition = 0
            self.finished = false
        }

        internal mutating func next() async throws -> SequenceOutput.Buffer? {
            let data = try await self.fileDescriptor.wrapped.readChunk(
                upToLength: readBufferSize
            )
            if data == nil {
                // We finished reading. Close the file descriptor now
                try self.fileDescriptor.safelyClose()
                return nil
            }
            return data
        }
    }

    private let fileDescriptor: TrackedFileDescriptor

    init(fileDescriptor: TrackedFileDescriptor) {
        self.fileDescriptor = fileDescriptor
    }

    internal func makeAsyncIterator() -> Iterator {
        return Iterator(fileDescriptor: self.fileDescriptor)
    }
}

extension RangeReplaceableCollection {
    /// Creates a new instance of a collection containing the elements of an asynchronous sequence.
    ///
    /// - Parameter source: The asynchronous sequence of elements for the new collection.
    @inlinable
    internal init<Source: AsyncSequence>(_ source: Source) async rethrows where Source.Element == Element {
        self.init()
        for try await item in source {
            append(item)
        }
    }
}
