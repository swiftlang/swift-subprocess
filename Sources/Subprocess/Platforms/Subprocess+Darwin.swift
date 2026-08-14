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

#if canImport(Darwin)

public import Darwin

#if SubprocessFoundation

#if canImport(Darwin)
// On Darwin always prefer system Foundation
public import Foundation
#else
// On other platforms prefer FoundationEssentials
public import FoundationEssentials
#endif

#endif // SubprocessFoundation

// MARK: - PlatformOptions

/// The collection of platform-specific settings
/// to configure the subprocess when running.
public struct PlatformOptions: Sendable {
    /// The quality of service for the subprocess.
    public var qualityOfService: QualityOfService = .default
    /// The user ID for the subprocess.
    public var userID: uid_t? = nil
    /// The real, effective, and saved set-group-ID for the subprocess.
    ///
    /// Setting this value is equivalent to calling `setgid()` on the subprocess.
    /// The group ID controls permissions, particularly for file access.
    public var groupID: gid_t? = nil
    /// The list of supplementary group IDs for the subprocess.
    public var supplementaryGroups: [gid_t]? = nil
    /// The process group for the subprocess.
    ///
    /// This is equivalent to calling `setpgid()` on the subprocess.
    /// The process group ID groups related processes for controlling signals.
    public var processGroupID: pid_t? = nil
    /// A Boolean value that indicates whether to create a session
    /// and detach from the terminal.
    public var createSession: Bool = false
    /// An ordered list of steps to tear down the subprocess
    /// if the calling task is canceled before
    /// the subprocess terminates.
    ///
    /// The sequence always ends by sending a `.kill` signal.
    public var teardownSequence: [TeardownStep] = []
    /// A closure that configures platform-specific
    /// process-launching constructs.
    ///
    /// Use this closure to directly configure or override
    /// the underlying platform-specific launch settings that the
    /// library uses internally, when higher-level APIs aren't
    /// available for such modifications.
    ///
    /// On Darwin, Subprocess uses `posix_spawn()` as the
    /// underlying process-launching mechanism. This closure allows
    /// modification of the `posix_spawnattr_t` attribute
    /// and file actions `posix_spawn_file_actions_t` before
    /// they are sent to `posix_spawn()`.
    ///
    /// On Darwin this closure is always called. A configuration `posix_spawn`
    /// cannot express on its own — one that sets ``userID``, ``groupID`` or
    /// ``supplementaryGroups``, or combines ``createSession`` with
    /// ``processGroupID`` — is launched by forking first and then execing
    /// through `posix_spawn` with `POSIX_SPAWN_SETEXEC`, which applies these
    /// same attributes and file actions.
    public var preSpawnProcessConfigurator:
        (
            @Sendable (
                inout posix_spawnattr_t?,
                inout posix_spawn_file_actions_t?
            ) throws -> Void
        )? = nil

    /// Creates platform options with default values.
    public init() {}
}

extension PlatformOptions {
    #if SubprocessFoundation
    /// Constants that indicate the nature and importance of work to the system.
    public typealias QualityOfService = Foundation.QualityOfService
    #else
    /// Constants that indicate the nature and importance of work to the system.
    ///
    /// Work with higher quality-of-service classes receives more resources
    /// than work with lower quality-of-service classes whenever
    /// there’s resource contention.
    public enum QualityOfService: Int, Sendable {
        /// Work directly involved in providing an
        /// interactive UI.
        ///
        /// For example, processing control
        /// events or drawing to the screen.
        case userInteractive = 0x21
        /// Work that the user explicitly requested and for which results
        /// must be immediately presented to allow for further user interaction.
        ///
        /// For example, loading an email after a user selects
        /// it in a message list.
        case userInitiated = 0x19
        /// Work whose results the user is unlikely to be
        /// immediately waiting for.
        ///
        /// This work may have been
        /// requested by the user or initiated automatically, and often
        /// operates at user-visible timescales using a non-modal
        /// progress indicator. For example, periodic content updates
        /// or bulk file operations, such as media import.
        case utility = 0x11
        /// Work that isn’t user-initiated or visible.
        ///
        /// In general, the user is unaware that this work is even happening.
        /// For example, prefetching content, search indexing, backups,
        /// or syncing of data with external systems.
        case background = 0x09
        /// No explicit quality-of-service information.
        ///
        /// Whenever possible, an appropriate quality of service is determined
        /// from available sources. Otherwise, some quality-of-service level
        /// between ``userInteractive`` and ``utility`` is used.
        case `default` = -1
    }
    #endif
}

extension PlatformOptions: CustomStringConvertible, CustomDebugStringConvertible {
    internal func description(withIndent indent: Int) -> String {
        if #available(macOS 15.0, *) {
            let indent = String(repeating: " ", count: indent * 4)
            return """
                PlatformOptions(
                \(indent)    qualityOfService: \(self.qualityOfService),
                \(indent)    userID: \(String(describing: userID)),
                \(indent)    groupID: \(String(describing: groupID)),
                \(indent)    supplementaryGroups: \(String(describing: supplementaryGroups)),
                \(indent)    processGroupID: \(String(describing: processGroupID)),
                \(indent)    createSession: \(createSession),
                \(indent)    preSpawnProcessConfigurator: \(self.preSpawnProcessConfigurator == nil ? "not set" : "set")
                \(indent))
                """
        } else {
            let indent = String(repeating: " ", count: indent * 4)
            return """
                PlatformOptions(
                \(indent)    qualityOfService: \(self.qualityOfService),
                \(indent)    userID: \(String(describing: userID)),
                \(indent)    groupID: \(String(describing: groupID)),
                \(indent)    supplementaryGroups: \(String(describing: supplementaryGroups)),
                \(indent)    processGroupID: \(String(describing: processGroupID)),
                \(indent)    createSession: \(createSession)
                \(indent))
                """
        }
    }

    /// A textual representation of the platform options.
    public var description: String {
        return self.description(withIndent: 0)
    }

    /// A debug-oriented textual representation of the platform options.
    public var debugDescription: String {
        return self.description(withIndent: 0)
    }
}

// MARK: - ProcessIdentifier

extension ProcessIdentifier {
    /// Creates a process identifier with the value you provide.
    public init(value: pid_t) {
        // Darwin has no process descriptors.
        self.init(value: value, processDescriptor: .invalidDescriptor)
    }
}

#endif // canImport(Darwin)
