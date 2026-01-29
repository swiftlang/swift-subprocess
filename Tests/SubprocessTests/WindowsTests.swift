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

#if canImport(WinSDK)

@preconcurrency import WinSDK
import FoundationEssentials
import Testing
import Dispatch

#if canImport(System)
@preconcurrency import System
#else
@preconcurrency import SystemPackage
#endif

import TestResources
@testable import Subprocess

@Suite(.serialized)
struct SubprocessWindowsTests {
    private let cmdExe: Subprocess.Executable = .name("cmd.exe")
}

// MARK: - PlatformOption Tests
extension SubprocessWindowsTests {
    @Test(
        .disabled("Disabled until we investigate CI specific failures"),
        .bug("https://github.com/swiftlang/swift-subprocess/issues/128")
    )
    func testPlatformOptionsRunAsUser() async throws {
        try await self.withTemporaryUser { username, password, succeed in
            // Use public directory as working directory so the newly created user
            // has access to it
            let workingDirectory = FilePath("C:\\Users\\Public")

            var platformOptions: Subprocess.PlatformOptions = .init()
            platformOptions.userCredentials = .init(
                username: username,
                password: password,
                domain: nil
            )

            let whoamiResult = try await Subprocess.run(
                .path("C:\\Windows\\System32\\whoami.exe"),
                workingDirectory: workingDirectory,
                platformOptions: platformOptions,
                output: .string(limit: .max)
            )

            try await withKnownIssue {
                #expect(whoamiResult.terminationStatus.isSuccess)
                let result = try #require(
                    whoamiResult.standardOutput
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                // whoami returns `computerName\userName`.
                let userInfo = result.split(separator: "\\")
                guard userInfo.count == 2 else {
                    Issue.record("Fail to parse the result for whoami: \(result)")
                    return
                }
                #expect(
                    userInfo[1].lowercased() == username.lowercased()
                )
            } when: {
                func userName() -> String {
                    var capacity = UNLEN + 1
                    let pointer = UnsafeMutablePointer<UTF16.CodeUnit>.allocate(capacity: Int(capacity))
                    defer { pointer.deallocate() }
                    guard GetUserNameW(pointer, &capacity) else {
                        return ""
                    }
                    return String(decodingCString: pointer, as: UTF16.self)
                }
                // On CI, we might failed to create user due to privilege issues
                // There's nothing much we can do in this case
                guard succeed else {
                    // If we fail to create the user, skip this test
                    return true
                }
                // CreateProcessWithLogonW doesn't appear to work when running in a container
                return whoamiResult.terminationStatus == .unhandledException(STATUS_DLL_INIT_FAILED) && userName() == "ContainerAdministrator"
            }
        }
    }

    @Test func testPlatformOptionsCreateNewConsole() async throws {
        let parentConsole = GetConsoleWindow()
        let sameConsoleResult = try await Subprocess.run(
            .name("powershell.exe"),
            arguments: [
                "-File", windowsTester.string,
                "-mode", "get-console-window",
            ],
            output: .string(limit: .max)
        )
        #expect(sameConsoleResult.terminationStatus.isSuccess)
        let sameConsoleValue = try #require(
            sameConsoleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Make sure the child console is same as parent
        #expect(
            "\(intptr_t(bitPattern: parentConsole))" == sameConsoleValue
        )
        // Now launch a process with new console
        var platformOptions: Subprocess.PlatformOptions = .init()
        platformOptions.consoleBehavior = .createNew
        let differentConsoleResult = try await Subprocess.run(
            .name("powershell.exe"),
            arguments: [
                "-File", windowsTester.string,
                "-mode", "get-console-window",
            ],
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        #expect(differentConsoleResult.terminationStatus.isSuccess)
        let differentConsoleValue = try #require(
            differentConsoleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Make sure the child console is different from parent
        #expect(
            "\(intptr_t(bitPattern: parentConsole))" != differentConsoleValue
        )
    }

    @Test func testPlatformOptionsDetachedProcess() async throws {
        var platformOptions: Subprocess.PlatformOptions = .init()
        platformOptions.consoleBehavior = .detach
        let detachConsoleResult = try await Subprocess.run(
            .name("powershell.exe"),
            arguments: [
                "-File", windowsTester.string,
                "-mode", "get-console-window",
            ],
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        #expect(detachConsoleResult.terminationStatus.isSuccess)
        let detachConsoleValue = try #require(
            detachConsoleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Detached process should NOT have a console
        #expect(detachConsoleValue.isEmpty)
    }

    @Test func testPlatformOptionsPreSpawnConfigurator() async throws {
        // Manually set the create new console flag
        var platformOptions: Subprocess.PlatformOptions = .init()
        platformOptions.preSpawnProcessConfigurator = { creationFlags, _ in
            creationFlags |= DWORD(CREATE_NEW_CONSOLE)
        }
        let parentConsole = GetConsoleWindow()
        let newConsoleResult = try await Subprocess.run(
            .name("powershell.exe"),
            arguments: [
                "-File", windowsTester.string,
                "-mode", "get-console-window",
            ],
            platformOptions: platformOptions,
            output: .string(limit: .max)
        )
        #expect(newConsoleResult.terminationStatus.isSuccess)
        let newConsoleValue = try #require(
            newConsoleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Make sure the child console is different from parent
        #expect(
            "\(intptr_t(bitPattern: parentConsole))" != newConsoleValue
        )

        guard !Self.hasAdminPrivileges() else {
            return
        }
        // Change the console title
        let title = "My Awesome Process"
        platformOptions.preSpawnProcessConfigurator = { creationFlags, startupInfo in
            creationFlags |= DWORD(CREATE_NEW_CONSOLE)
            title.withCString(
                encodedAs: UTF16.self
            ) { titleW in
                startupInfo.lpTitle = UnsafeMutablePointer(mutating: titleW)
            }
        }
        let changeTitleResult = try await Subprocess.run(
            .name("powershell.exe"),
            arguments: [
                "-Command", "$consoleTitle = [console]::Title; Write-Host $consoleTitle",
            ],
            platformOptions: platformOptions,
            output: .string(limit: 32)
        )
        #expect(changeTitleResult.terminationStatus.isSuccess)
        let newTitle = try #require(
            changeTitleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Make sure the child console is different from parent\
        #expect(newTitle == title)
    }
}

// MARK: - Subprocess Controlling Tests
extension SubprocessWindowsTests {
    @Test func testTerminateProcess() async throws {
        let stuckProcess = try await Subprocess.run(
            self.cmdExe,
            // This command will intentionally hang
            arguments: ["/c", "type con"],
            error: .discarded
        ) { subprocess, standardOutput in
            // Make sure we can kill the hung process
            try subprocess.terminate(withExitCode: 42)
            for try await _ in standardOutput {}
        }
        // If we got here, the process was terminated
        guard case .exited(let exitCode) = stuckProcess.terminationStatus else {
            Issue.record("Process should have exited")
            return
        }
        #expect(exitCode == 42)
    }

    @Test func testSuspendResumeProcess() async throws {
        let stuckProcess = try await Subprocess.run(
            self.cmdExe,
            // This command will intentionally hang
            arguments: ["/c", "type con"],
            error: .discarded
        ) { subprocess, standardOutput in
            try subprocess.suspend()
            // Now check the to make sure the process is actually suspended
            // Why not spawn another process to do that?
            var checkResult = try await Subprocess.run(
                .name("powershell.exe"),
                arguments: [
                    "-File", windowsTester.string,
                    "-mode", "is-process-suspended",
                    "-processID", "\(subprocess.processIdentifier.value)",
                ],
                output: .string(limit: .max)
            )
            #expect(checkResult.terminationStatus.isSuccess)
            var isSuspended = try #require(
                checkResult.standardOutput
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(isSuspended == "true")

            // Now resume the process
            try subprocess.resume()
            checkResult = try await Subprocess.run(
                .name("powershell.exe"),
                arguments: [
                    "-File", windowsTester.string,
                    "-mode", "is-process-suspended",
                    "-processID", "\(subprocess.processIdentifier.value)",
                ],
                output: .string(limit: .max)
            )
            #expect(checkResult.terminationStatus.isSuccess)
            isSuspended = try #require(
                checkResult.standardOutput
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(isSuspended == "false")

            // Now finally kill the process since it's intentionally hung
            try subprocess.terminate(withExitCode: 0)
            for try await _ in standardOutput {}
        }
        #expect(stuckProcess.terminationStatus.isSuccess)
    }

    /// Tests a use case for Windows platform handles by assigning the newly created process to a Job Object
    /// - see: https://devblogs.microsoft.com/oldnewthing/20131209-00/
    @Test func testPlatformHandles() async throws {
        let hJob = CreateJobObjectW(nil, nil)
        defer { #expect(CloseHandle(hJob)) }
        var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        info.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        #expect(SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, &info, DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)))

        var platformOptions = PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = { (createProcessFlags, startupInfo) in
            createProcessFlags |= DWORD(CREATE_SUSPENDED)
        }

        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo"],
            platformOptions: platformOptions,
            output: .discarded
        ) { execution, _ in
            guard AssignProcessToJobObject(hJob, execution.processIdentifier.processDescriptor) else {
                throw SubprocessError.WindowsError(rawValue: GetLastError())
            }
            guard ResumeThread(execution.processIdentifier.threadHandle) != DWORD(bitPattern: -1) else {
                throw SubprocessError.WindowsError(rawValue: GetLastError())
            }
        }
        #expect(result.terminationStatus.isSuccess)
    }
}

// MARK: - User Utils
extension SubprocessWindowsTests {
    private func withTemporaryUser(
        _ work: (String, String, Bool) async throws -> Void
    ) async throws {
        let username: String = "TestUser\(randomString(length: 5, lettersOnly: true))"
        let password: String = "Password\(randomString(length: 10))"

        func createUser(withUsername username: String, password: String) -> Bool {
            return username.withCString(
                encodedAs: UTF16.self
            ) { usernameW in
                return password.withCString(
                    encodedAs: UTF16.self
                ) { passwordW in
                    var userInfo: USER_INFO_1 = USER_INFO_1()
                    userInfo.usri1_name = UnsafeMutablePointer<WCHAR>(mutating: usernameW)
                    userInfo.usri1_password = UnsafeMutablePointer<WCHAR>(mutating: passwordW)
                    userInfo.usri1_priv = DWORD(USER_PRIV_USER)
                    userInfo.usri1_home_dir = nil
                    userInfo.usri1_comment = nil
                    userInfo.usri1_flags = DWORD(UF_SCRIPT | UF_DONT_EXPIRE_PASSWD)
                    userInfo.usri1_script_path = nil

                    var error: DWORD = 0

                    var status = NetUserAdd(
                        nil,
                        1,
                        &userInfo,
                        &error
                    )
                    guard status == NERR_Success else {
                        return false
                    }
                    return true
                }
            }
        }

        let succeed = createUser(withUsername: username, password: password)

        defer {
            if succeed {
                // Now delete the user
                let status = username.withCString(
                    encodedAs: UTF16.self
                ) { usernameW in
                    return NetUserDel(nil, usernameW)
                }
                if status != NERR_Success {
                    Issue.record("Failed to delete user with error: \(status)")
                }
            }
        }
        // Run work
        try await work(username, password, succeed)
    }

    private static func hasAdminPrivileges() -> Bool {
        var isAdmin: WindowsBool = false
        var adminGroup: PSID? = nil
        // SECURITY_NT_AUTHORITY
        var netAuthority = SID_IDENTIFIER_AUTHORITY(Value: (0, 0, 0, 0, 0, 5))
        guard
            AllocateAndInitializeSid(
                &netAuthority,
                2, // nSubAuthorityCount
                DWORD(SECURITY_BUILTIN_DOMAIN_RID),
                DWORD(DOMAIN_ALIAS_RID_ADMINS),
                0,
                0,
                0,
                0,
                0,
                0,
                &adminGroup
            )
        else {
            return false
        }
        defer {
            FreeSid(adminGroup)
        }
        // Check if the current process's token is part of
        // the Administrators group
        guard
            CheckTokenMembership(
                nil,
                adminGroup,
                &isAdmin
            )
        else {
            return false
        }
        // Okay the below is intentional because
        // `isAdmin` is a `WindowsBool` and we need `Bool`
        return isAdmin.boolValue
    }
}

extension FileDescriptor {
    internal func readUntilEOF(upToLength maxLength: Int) async throws -> Data {
        // TODO: Figure out a better way to asynchronously read
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var totalBytesRead: Int = 0
                var lastError: DWORD? = nil
                let values = [UInt8](
                    unsafeUninitializedCapacity: maxLength
                ) { buffer, initializedCount in
                    while true {
                        guard let baseAddress = buffer.baseAddress else {
                            initializedCount = 0
                            break
                        }
                        let bufferPtr = baseAddress.advanced(by: totalBytesRead)
                        var bytesRead: DWORD = 0
                        let readSucceed = ReadFile(
                            self.platformDescriptor,
                            UnsafeMutableRawPointer(mutating: bufferPtr),
                            DWORD(maxLength - totalBytesRead),
                            &bytesRead,
                            nil
                        )
                        if !readSucceed {
                            // Windows throws ERROR_BROKEN_PIPE when the pipe is closed
                            let error = GetLastError()
                            if error == ERROR_BROKEN_PIPE {
                                // We are done reading
                                initializedCount = totalBytesRead
                            } else {
                                // We got some error
                                lastError = error
                                initializedCount = 0
                            }
                            break
                        } else {
                            // We successfully read the current round
                            totalBytesRead += Int(bytesRead)
                        }

                        if totalBytesRead >= maxLength {
                            initializedCount = min(maxLength, totalBytesRead)
                            break
                        }
                    }
                }
                if let lastError = lastError {
                    let windowsError = SubprocessError(
                        code: .init(.failedToReadFromSubprocess),
                        underlyingError: SubprocessError.WindowsError(rawValue: lastError)
                    )
                    continuation.resume(throwing: windowsError)
                } else {
                    continuation.resume(returning: Data(values))
                }
            }
        }
    }
}

#endif // canImport(WinSDK)
