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
import Foundation
import Testing
import Synchronization

#if canImport(System)
import System
#else
import SystemPackage
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

            try withKnownIssue {
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
                return whoamiResult.terminationStatus == .exited(STATUS_DLL_INIT_FAILED) && userName() == "ContainerAdministrator"
            }
        }
    }

    @Test func testPlatformOptionsCreateNewConsole() async throws {
        let parentConsole = GetConsoleWindow()
        let sameConsoleResult = try await Subprocess.run(
            .name("powershell.exe"),
            arguments: [
                "-ExecutionPolicy", "Bypass", "-File", windowsTester.string,
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
                "-ExecutionPolicy", "Bypass", "-File", windowsTester.string,
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
                "-ExecutionPolicy", "Bypass", "-File", windowsTester.string,
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
                "-ExecutionPolicy", "Bypass", "-File", windowsTester.string,
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
            input: .none,
            output: .discarded,
            error: .discarded
        ) { subprocess in
            // Make sure we can kill the hung process
            try subprocess.terminate(withExitCode: 42)
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
            input: .none,
            output: .discarded,
            error: .discarded
        ) { subprocess in
            try subprocess.suspend()
            // Now check the to make sure the process is actually suspended
            // Why not spawn another process to do that?
            var checkResult = try await Subprocess.run(
                .name("powershell.exe"),
                arguments: [
                    "-ExecutionPolicy", "Bypass", "-File", windowsTester.string,
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
                    "-ExecutionPolicy", "Bypass", "-File", windowsTester.string,
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
        }
        #expect(stuckProcess.terminationStatus.isSuccess)
    }

    /// Tests a use case for Windows platform handles by assigning the newly
    /// created process to a user-supplied Job Object, nested inside
    /// Subprocess's internal job.
    /// - see: https://devblogs.microsoft.com/oldnewthing/20131209-00/
    @Test func testPlatformHandles() async throws {
        let hJob = CreateJobObjectW(nil, nil)
        defer { #expect(CloseHandle(hJob)) }
        var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        info.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        #expect(SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, &info, DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)))

        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo"],
            input: .none,
            output: .discarded,
            error: .discarded
        ) { execution in
            // Nest the child inside a user-supplied Job Object. Subprocess
            // already assigned it to its internal job. This nests further.
            guard AssignProcessToJobObject(hJob, execution.processIdentifier.processDescriptor) else {
                throw SubprocessError.WindowsError(win32Error: GetLastError())
            }
        }
        #expect(result.terminationStatus.isSuccess)
    }
}

// MARK: - Job Object Termination Tests
extension SubprocessWindowsTests {
    @Test func testTerminateToProcessGroupKillsJobMembers() async throws {
        _ = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "ping -n 60 127.0.0.1 > nul"],
            input: .none,
            output: .sequence,
            error: .discarded
        ) { execution in
            let grandchildPid = try #require(
                await Self.waitForChildPid(of: execution.processIdentifier.value, named: "ping.exe"),
                "ping.exe did not appear as a child of cmd.exe"
            )
            let grandchildHandle = try #require(
                OpenProcess(
                    DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION),
                    false,
                    grandchildPid
                ),
                "Failed to open handle to grandchild process"
            )
            defer { _ = CloseHandle(grandchildHandle) }

            #expect(Self.isProcessAlive(handle: grandchildHandle))

            // Terminate the immediate child and any job members.
            try execution.terminate(withExitCode: 0, toProcessGroup: true)

            let exited = await Self.waitForProcessExit(handle: grandchildHandle)
            #expect(exited, "Grandchild should have been terminated by TerminateJobObject")

            for try await _ in execution.standardOutput {}
        }
    }

    @Test func testTerminateWithoutProcessGroupLeavesJobMembers() async throws {
        // The complement of `testTerminateToProcessGroupKillsJobMembers`.
        // With `toProcessGroup: false`, `TerminateProcess` only affects the
        // immediate child. Other job members, including grandchildren the
        // child spawned, must survive and remain in the Job Object.
        var grandchildHandleToCleanup: HANDLE?
        defer {
            if let handle = grandchildHandleToCleanup {
                _ = TerminateProcess(handle, 0)
                _ = CloseHandle(handle)
            }
        }

        _ = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "ping -n 60 127.0.0.1 > nul"],
            input: .none,
            output: .sequence,
            error: .discarded
        ) { execution in
            let grandchildPid = try #require(
                await Self.waitForChildPid(of: execution.processIdentifier.value, named: "ping.exe"),
                "ping.exe did not appear as a child of cmd.exe"
            )
            let grandchildHandle = try #require(
                OpenProcess(
                    DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE),
                    false,
                    grandchildPid
                ),
                "Failed to open handle to grandchild process"
            )
            grandchildHandleToCleanup = grandchildHandle

            #expect(Self.isProcessAlive(handle: grandchildHandle))

            // Terminate only the immediate child.
            try execution.terminate(withExitCode: 0, toProcessGroup: false)

            // Give Windows a moment, then verify the grandchild is still alive
            // and still a member of a Job Object. Membership confirms that
            // Subprocess's internal job survived the per-process termination
            // and continues to track descendants.
            try await Task.sleep(for: .milliseconds(250))
            #expect(
                Self.isProcessAlive(handle: grandchildHandle),
                "Grandchild should remain alive after toProcessGroup: false termination"
            )

            var inJob: WindowsBool = false
            #expect(
                IsProcessInJob(grandchildHandle, nil, &inJob),
                "IsProcessInJob failed"
            )
            #expect(
                inJob.boolValue,
                "Grandchild should still be a job member after toProcessGroup: false termination"
            )

            for try await _ in execution.standardOutput {}
        }
    }

    @Test func testPreSpawnConfiguratorCanOptIntoManualResume() async throws {
        // Setting `CREATE_SUSPENDED` from `preSpawnProcessConfigurator`
        // signals that user code will resume the child explicitly.
        // Subprocess itself must not call `ResumeThread` in that case.
        //
        // Verify this by calling `ResumeThread` from the body closure and
        // check the previous suspend count it returns. `1` means the child
        // was still suspended (correct), and `0` means Subprocess has already
        // resumed it (incorrect).
        var platformOptions = PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = { creationFlags, _ in
            creationFlags |= DWORD(CREATE_SUSPENDED)
        }

        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo hello"],
            platformOptions: platformOptions,
            input: .none,
            output: .discarded,
            error: .discarded
        ) { execution in
            let previousSuspendCount = ResumeThread(execution.processIdentifier.threadHandle)
            // Expect `1` since a greater suspend count means someone
            // suspended the thread twice, and that should not happen.
            #expect(previousSuspendCount == 1)
        }
        #expect(result.terminationStatus.isSuccess)
    }
}

// MARK: - Batch File Argument Escaping (BatBadBut)
extension SubprocessWindowsTests {
    @Test func testIsWindowsBatchFileDetection() {
        #expect("deploy.bat".isWindowsBatchFile)
        #expect("DEPLOY.BAT".isWindowsBatchFile)
        #expect("run.cmd".isWindowsBatchFile)
        #expect("C:\\scripts\\go.CMD".isWindowsBatchFile)
        // Windows strips trailing spaces and dots before resolving a path, so
        // these still name a batch file. Not handling this was the
        // CVE-2024-43402 bypass of the original BatBadBut fix.
        #expect("deploy.bat. .".isWindowsBatchFile)
        #expect("deploy.bat   ".isWindowsBatchFile)
        #expect("deploy.bat...".isWindowsBatchFile)
        // Not batch files.
        #expect(!"tool.exe".isWindowsBatchFile)
        #expect(!"tool".isWindowsBatchFile)
        #expect(!"archive.bat.zip".isWindowsBatchFile)
    }

    @Test func testEscapeBatchFileArgument() throws {
        // cmd.exe metacharacters are prefixed with `^` so cmd.exe passes them
        // through literally instead of acting on them.
        #expect(try Configuration.escapeBatchFileArgument("&calc") == "^&calc")
        #expect(try Configuration.escapeBatchFileArgument("a&b|c") == "a^&b^|c")
        #expect(try Configuration.escapeBatchFileArgument("50%") == "50^%")
        // Arguments with whitespace are quoted (step 1); the quotes are then
        // themselves `^`-escaped (step 2).
        #expect(try Configuration.escapeBatchFileArgument("hello world") == "^\"hello world^\"")
        // An embedded quote: escaped for CommandLineToArgvW (\"), then each
        // resulting quote is escaped for cmd.exe (^").
        #expect(try Configuration.escapeBatchFileArgument("a\"b") == "^\"a\\^\"b^\"")
        // An empty argument is force-quoted so it isn't dropped entirely.
        #expect(try Configuration.escapeBatchFileArgument("") == "^\"^\"")
        // Characters that cannot be safely conveyed to cmd.exe are rejected.
        #expect(throws: SubprocessError.self) {
            _ = try Configuration.escapeBatchFileArgument("line1\nline2")
        }
        #expect(throws: SubprocessError.self) {
            _ = try Configuration.escapeBatchFileArgument("has\rcarriage")
        }
        #expect(throws: SubprocessError.self) {
            _ = try Configuration.escapeBatchFileArgument("has\u{0}nul")
        }
    }

    @Test func testMakeBatchFileCommandLine() throws {
        #expect(
            try Configuration.makeBatchFileCommandLine(
                scriptPath: "C:\\Temp\\noop.bat",
                arguments: ["&calc"]
            ) == "cmd.exe /d /e:ON /v:OFF /c \"\"C:\\Temp\\noop.bat\" ^&calc\""
        )
        // A script path that would break out of its quote pair is rejected.
        #expect(throws: SubprocessError.self) {
            _ = try Configuration.makeBatchFileCommandLine(
                scriptPath: "C:\\Temp\\trailing\\",
                arguments: []
            )
        }
        #expect(throws: SubprocessError.self) {
            _ = try Configuration.makeBatchFileCommandLine(
                scriptPath: "C:\\Temp\\quo\"te.bat",
                arguments: []
            )
        }
    }

    /// End-to-end proof that cmd.exe metacharacters in an argument to a real
    /// `.bat` file are not interpreted by the implicitly-spawned cmd.exe.
    @Test func testBatchFileArgumentsAreNotInterpretedByCmd() async throws {
        // A throwaway directory with a batch file that echoes a sentinel and
        // ignores its arguments. If escaping is correct, none of the payloads
        // below can spawn the injected `echo` redirection, so no marker file
        // is ever created and the sentinel is the only output.
        let workingDirectory = URL.temporaryDirectory
            .appendingPathComponent("subprocess-batbadbut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let batchURL = workingDirectory.appendingPathComponent("noop.bat")
        try "@echo off\r\necho RAN\r\nexit /b 0\r\n".write(
            to: batchURL,
            atomically: true,
            encoding: .utf8
        )
        let batchPath = FilePath(batchURL._fileSystemPath)
        let workingDirectoryPath = FilePath(workingDirectory._fileSystemPath)

        // Each payload exercises a different cmd.exe injection technique. The
        // marker file name is unique so a failure points at the payload.
        let payloads: [(name: String, argument: String, marker: String)] = [
            ("ampersand", "&echo pwned>inj_amp.txt", "inj_amp.txt"),
            ("double-ampersand", "x&&echo pwned>inj_damp.txt", "inj_damp.txt"),
            ("pipe", "x|echo pwned>inj_pipe.txt", "inj_pipe.txt"),
            ("redirect", "x>inj_redir.txt", "inj_redir.txt"),
            ("quote-breakout", "\"&echo pwned>inj_quote.txt&\"", "inj_quote.txt"),
        ]

        for payload in payloads {
            let result = try await Subprocess.run(
                .path(batchPath),
                arguments: [payload.argument],
                workingDirectory: workingDirectoryPath,
                output: .string(limit: .max),
                error: .discarded
            )
            // The batch file itself still runs successfully through cmd.exe...
            #expect(
                result.terminationStatus.isSuccess,
                "Batch file did not run for payload \(payload.name)"
            )
            // ...and its only output is the sentinel (proving the argument was
            // not interpreted as a redirection that swallowed the output).
            #expect(
                result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) == "RAN",
                "Unexpected output for payload \(payload.name)"
            )
            // No injected command ran.
            let markerURL = workingDirectory.appendingPathComponent(payload.marker)
            let injected = FileManager.default.fileExists(atPath: markerURL._fileSystemPath)
            #expect(!injected, "Command injection occurred for payload \(payload.name)")
            if injected {
                try? FileManager.default.removeItem(at: markerURL)
            }
        }
    }
}

// MARK: - Environment
extension SubprocessWindowsTests {
    @Test func testEnvironmentKeyComparableMatchesEquatable() {
        let upper: Environment.Key = "PATH"
        let lower: Environment.Key = "path"
        #expect(upper == lower)
        #expect(!(upper < lower))
        #expect(!(lower < upper))
        #expect(!(upper > lower))
        #expect(!(lower > upper))
    }

    @Test func testEnvironmentKeySortsCaseInsensitively() {
        let keys: [Environment.Key] = ["Banana", "apple", "Kiwi"]
        #expect(keys.sorted().map(\.rawValue) == ["apple", "Banana", "Kiwi"])
    }

    @Test func testEnvironmentKeyOrdinalSortMatchesWindowsBlockOrder() {
        // Windows sorts the environment block case-insensitively in uppercase
        // ordinal order, so '_' (0x5F) sorts after letters. "APPDATA" must
        // therefore precede "APP_NAME".
        let keys: [Environment.Key] = ["APP_NAME", "APPDATA"]
        #expect(keys.sorted().map(\.rawValue) == ["APPDATA", "APP_NAME"])
    }

    @Test func testRejectInvalidEnvironment() async throws {
        func _runTest(withEnvironment environment: Environment, errorReason: String) async {
            let expectedError: SubprocessError = .spawnFailed(
                withUnderlyingError: nil,
                reason: errorReason
            )

            await #expect(throws: expectedError) {
                _ = try await Subprocess.run(
                    self.cmdExe,
                    environment: environment,
                    output: .discarded
                )
            }
        }

        await _runTest(
            withEnvironment: .inherit.updating(["key=": "value"]),
            errorReason: "Environment key 'key=' must not contain '='."
        )

        await _runTest(
            withEnvironment: .inherit.updating(["key\0": "value"]),
            errorReason: "Environment key 'key\0' must not contain null bytes."
        )

        await _runTest(
            withEnvironment: .inherit.updating(["key": "value\0"]),
            errorReason: "Environment value 'value\0' must not contain null bytes."
        )

        let longKey = randomString(length: 32767 / 2 + 1)
        let longValue = randomString(length: 32767 / 2 + 1)
        await _runTest(
            withEnvironment: .inherit.updating([.init(longKey): longValue]),
            errorReason: "Environment key and value pair must not exceed 32,767 characters."
        )
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

                    let status = NetUserAdd(
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

    /// Finds the PID of a child of the given parent PID, optionally filtered
    /// by executable name (case-insensitive), and returns the first match.
    private static func findChildPid(
        of parentPid: DWORD,
        named name: String? = nil
    ) throws -> DWORD? {
        guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0),
            snapshot != INVALID_HANDLE_VALUE
        else {
            throw SubprocessError.WindowsError(win32Error: GetLastError())
        }
        defer { _ = CloseHandle(snapshot) }

        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)

        guard Process32FirstW(snapshot, &entry) else {
            return nil
        }
        repeat {
            if entry.th32ParentProcessID == parentPid {
                if let name = name {
                    let exeName = withUnsafePointer(to: entry.szExeFile) {
                        $0.withMemoryRebound(
                            to: WCHAR.self,
                            capacity: Int(MAX_PATH)
                        ) { ptr in
                            String(decodingCString: ptr, as: UTF16.self)
                        }
                    }
                    if exeName.lowercased() == name.lowercased() {
                        return entry.th32ProcessID
                    }
                } else {
                    return entry.th32ProcessID
                }
            }
        } while Process32NextW(snapshot, &entry)

        return nil
    }

    /// Polls until a child of the given parent PID appears, or the timeout
    /// elapses.
    private static func waitForChildPid(
        of parentPid: DWORD,
        named name: String? = nil,
        timeout: Duration = .seconds(5)
    ) async throws -> DWORD? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let pid = try findChildPid(of: parentPid, named: name) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Returns `true` if `WaitForSingleObject` on the handle reports the
    /// process as still running.
    private static func isProcessAlive(handle: HANDLE) -> Bool {
        return WaitForSingleObject(handle, 0) == WAIT_TIMEOUT
    }

    /// Asynchronously waits for the process referenced by the given handle
    /// to exit, or for the given timeout to elapse. Returns `true` if the
    /// process exited within the timeout.
    private static func waitForProcessExit(
        handle: HANDLE,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let handleBits = Int(bitPattern: handle)
        return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                let handle = HANDLE(bitPattern: handleBits)!
                await waitForHandleSignal(handle: handle)
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            // First child task to finish wins. Cancel the other.
            // `waitForHandleSignal` honors task cancellation and unwinds
            // promptly so the group can return.
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Asynchronously waits for the given handle to be signaled, using
    /// `RegisterWaitForSingleObject`. Honors task cancellation by
    /// unregistering the wait synchronously.
    private static func waitForHandleSignal(handle: HANDLE) async {
        // `Storage` holds Win32 pointer values whose provenance the region
        // checker cannot verify, so it is `@unchecked Sendable`. All access
        // is serialized through the `Mutex` that holds it.
        struct Storage: @unchecked Sendable {
            var waitHandle: HANDLE?
            var contextRetained: UnsafeMutableRawPointer?
        }
        final class State: Sendable {
            let storage = Mutex(Storage())
            let continuation: AsyncStream<Void>.Continuation

            init(continuation: AsyncStream<Void>.Continuation) {
                self.continuation = continuation
            }

            /// Releases the retained `Unmanaged` context if it hasn't been
            /// released yet, then finishes the stream. Idempotent.
            func finishOnce() {
                let context = self.storage.withLock { storage -> UnsafeMutableRawPointer? in
                    let context = storage.contextRetained
                    storage.contextRetained = nil
                    return context
                }
                if let context {
                    Unmanaged<AnyObject>.fromOpaque(context).release()
                }
                self.continuation.finish()
            }
        }

        let (stream, streamContinuation) = AsyncStream.makeStream(of: Void.self)
        let state = State(continuation: streamContinuation)

        await withTaskCancellationHandler {
            // Retain a reference to `state` for the C callback. The callback
            // releases this retain after yielding.
            let context = Unmanaged.passRetained(state).toOpaque()
            state.storage.withLock { storage in
                storage.contextRetained = context
            }

            let callback: WAITORTIMERCALLBACK = { context, _ in
                let state = Unmanaged<State>.fromOpaque(context!)
                    .takeRetainedValue()
                // Clear `contextRetained` since we just consumed our own
                // retain with `takeRetainedValue()`.
                state.storage.withLock { storage in
                    storage.contextRetained = nil
                }
                state.continuation.yield()
                state.continuation.finish()
            }

            var waitHandle: HANDLE?
            let flags = ULONG(WT_EXECUTEONLYONCE | WT_EXECUTELONGFUNCTION)
            guard
                RegisterWaitForSingleObject(
                    &waitHandle,
                    handle,
                    callback,
                    context,
                    INFINITE,
                    flags
                )
            else {
                // Registration failed. Finish the stream immediately. The
                // caller's timeout path handles the apparent non-exit.
                state.finishOnce()
                // Wait for the iteration below to observe the finish.
                for await _ in stream {}
                return
            }

            state.storage.withLock { storage in
                storage.waitHandle = waitHandle
            }

            // Wait for either the callback to yield, or for cancellation
            // to finish the stream. Either way, the iteration ends after
            // observing the (single) yielded value or the finish.
            for await _ in stream { break }

            // Unregister the wait. `INVALID_HANDLE_VALUE` tells
            // `UnregisterWaitEx` to wait synchronously for any in-flight
            // callbacks.
            let waitHandleToUnregister = state.storage.withLock { storage -> HANDLE? in
                let handle = storage.waitHandle
                storage.waitHandle = nil
                return handle
            }
            if let waitHandleToUnregister {
                _ = UnregisterWaitEx(waitHandleToUnregister, INVALID_HANDLE_VALUE)
            }
        } onCancel: {
            // Cancellation path. Unregister the wait synchronously, then
            // finish the stream so the awaiting `for await` returns.
            let waitHandleToUnregister = state.storage.withLock { storage -> HANDLE? in
                let handle = storage.waitHandle
                storage.waitHandle = nil
                return handle
            }
            if let waitHandleToUnregister {
                _ = UnregisterWaitEx(waitHandleToUnregister, INVALID_HANDLE_VALUE)
            }
            state.finishOnce()
        }
    }
}

#endif // canImport(WinSDK)
