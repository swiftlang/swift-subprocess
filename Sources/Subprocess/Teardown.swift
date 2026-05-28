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

import _SubprocessCShims

#if canImport(Darwin)
import Darwin
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
@preconcurrency import WinSDK
#endif

/// A step in a graceful shutdown sequence.
///
/// Each step specifies an action to perform on the child process and
/// the duration to wait for the process to exit before proceeding
/// to the next step.
public struct TeardownStep: Sendable, Hashable {
    internal enum Storage: Sendable, Hashable {
        #if !os(Windows)
        case sendSignal(Signal, toProcessGroup: Bool, allowedDuration: Duration)
        #endif
        case gracefulShutDown(toProcessGroup: Bool, allowedDuration: Duration)
        case kill
    }
    var storage: Storage

    #if !os(Windows)
    /// Sends a signal to the process and waits for the specified duration
    /// before proceeding to the next step.
    ///
    /// The final step in the sequence always sends a `.kill` signal.
    ///
    /// - Important: When sending the signal to the process group, unless you
    /// also set `createSession` to `true`, or `processGroupID` to a
    /// non-inherited value, the targeted process group includes the parent
    /// process. This is almost never what you want. Pair `toProcessGroup`
    /// with `createSession` to isolate the subprocess and its descendants in
    /// their own session.
    public static func send(
        signal: Signal,
        toProcessGroup: Bool = false,
        allowedDurationToNextStep: Duration
    ) -> Self {
        return Self(
            storage: .sendSignal(
                signal,
                toProcessGroup: toProcessGroup,
                allowedDuration: allowedDurationToNextStep
            )
        )
    }
    #endif // !os(Windows)

    /// Attempts a graceful shutdown, waiting for the specified duration
    /// before proceeding to the next step.
    ///
    /// - On Unix: Sends `SIGTERM`.
    /// - On Windows:
    ///   1. Sends `WM_CLOSE` if the child process is a GUI process.
    ///   2. Sends `CTRL_C_EVENT` to the console.
    ///   3. Sends `CTRL_BREAK_EVENT` to the process group.
    ///
    /// - Important: On Unix, when sending the signal to the process group,
    /// unless you also set `createSession` to `true`, or `processGroupID`
    /// to a non-inherited value, the targeted process group includes the parent
    /// process. This is almost never what you want. Pair `toProcessGroup`
    /// with `createSession` to isolate the subprocess and its descendants in
    /// their own session. On Windows, the `toProcessGroup` parameter has no
    /// effect; `WM_CLOSE` and `CTRL_C_EVENT` have no process-group equivalent,
    /// and `CTRL_BREAK_EVENT` is always sent to the process group.
    public static func gracefulShutDown(
        toProcessGroup: Bool = false,
        allowedDurationToNextStep: Duration
    ) -> Self {
        return Self(
            storage: .gracefulShutDown(
                toProcessGroup: toProcessGroup,
                allowedDuration: allowedDurationToNextStep
            )
        )
    }
}

extension Execution {
    /// Performs a sequence of teardown steps on the subprocess.
    ///
    /// The teardown sequence always ends with a `.kill` signal.
    /// - Parameter sequence: The steps to perform.
    public func teardown(using sequence: some Sequence<TeardownStep> & Sendable) async {
        await withUncancelledTask {
            await runTeardownSequence(sequence)
        }
    }
}

internal enum TeardownStepCompletion {
    case processHasExited
    case processStillAlive
    case killedTheProcess
}

extension Execution {
    internal func gracefulShutDown(
        toProcessGroup: Bool,
        allowedDurationToNextStep duration: Duration
    ) async {
        #if os(Windows)
        // 1. Attempt to send WM_CLOSE to the main window
        if _subprocess_windows_send_vm_close(
            processIdentifier.value
        ) {
            try? await Task.sleep(for: duration)
        }

        // 2. Attempt to attach to the console and send CTRL_C_EVENT
        if AttachConsole(processIdentifier.value) {
            // Disable Ctrl-C handling in this process
            if SetConsoleCtrlHandler(nil, true) {
                if GenerateConsoleCtrlEvent(DWORD(CTRL_C_EVENT), 0) {
                    // We successfully sent the event. wait for the process to exit
                    try? await Task.sleep(for: duration)
                }
                // Re-enable Ctrl-C handling
                SetConsoleCtrlHandler(nil, false)
            }
            // Detach console
            FreeConsole()
        }

        // 3. Attempt to send CTRL_BREAK_EVENT to the process group
        if GenerateConsoleCtrlEvent(DWORD(CTRL_BREAK_EVENT), processIdentifier.value) {
            // Wait for process to exit
            try? await Task.sleep(for: duration)
        }
        #else
        // Send SIGTERM
        try? self.send(
            signal: .terminate,
            toProcessGroup: toProcessGroup
        )
        #endif
    }

    internal func runTeardownSequence(
        _ sequence: some Sequence<TeardownStep> & Sendable
    ) async {
        // The implicit final `.kill` inherits `toProcessGroup` from the last
        // explicit step in the sequence. This matches user intent: A sequence
        // configured to target the process group should have its terminal kill
        // also target the group, so descendants don't leak after teardown.
        let steps = Array(sequence)
        let killProcessGroup: Bool = {
            guard let last = steps.last else { return false }
            switch last.storage {
            #if !os(Windows)
            case .sendSignal(_, let toProcessGroup, _): return toProcessGroup
            #endif
            case .gracefulShutDown(let toProcessGroup, _): return toProcessGroup
            case .kill: return false
            }
        }()
        let finalSequence = steps + [TeardownStep(storage: .kill)]
        for step in finalSequence {
            let stepCompletion: TeardownStepCompletion
            guard self.isPotentiallyStillAlive() else {
                // Early return since the process has already exited
                return
            }

            switch step.storage {
            case .gracefulShutDown(let toProcessGroup, let allowedDuration):
                stepCompletion = await withTaskGroup(of: TeardownStepCompletion.self) { group in
                    group.addTask {
                        do {
                            try await Task.sleep(for: allowedDuration)
                            return .processStillAlive
                        } catch {
                            // teardown(using:) cancels this task
                            // when process has exited
                            return .processHasExited
                        }
                    }
                    await self.gracefulShutDown(
                        toProcessGroup: toProcessGroup,
                        allowedDurationToNextStep: allowedDuration
                    )
                    return await group.next()!
                }
            #if !os(Windows)
            case .sendSignal(let signal, let toProcessGroup, let allowedDuration):
                stepCompletion = await withTaskGroup(of: TeardownStepCompletion.self) { group in
                    group.addTask {
                        do {
                            try await Task.sleep(for: allowedDuration)
                            return .processStillAlive
                        } catch {
                            // teardown(using:) cancels this task
                            // when process has exited
                            return .processHasExited
                        }
                    }
                    try? self.send(signal: signal, toProcessGroup: toProcessGroup)
                    return await group.next()!
                }
            #endif // !os(Windows)
            case .kill:
                #if os(Windows)
                try? self.terminate(
                    withExitCode: 0,
                    toProcessGroup: killProcessGroup
                )
                #else
                try? self.send(signal: .kill, toProcessGroup: killProcessGroup)
                #endif
                stepCompletion = .killedTheProcess
            }

            switch stepCompletion {
            case .killedTheProcess, .processHasExited:
                return
            case .processStillAlive:
                // Continue to next step
                break
            }
        }
    }

    private func isPotentiallyStillAlive() -> Bool {
        // Non-blockingly check whether the current execution has already exited
        // Note here we do NOT want to reap the exit status because we are still
        // running monitorProcessTermination()
        #if os(Windows)
        return WaitForSingleObject(self.processIdentifier.processDescriptor, 0) == WAIT_TIMEOUT
        #else
        return kill(self.processIdentifier.value, 0) == 0
        #endif
    }
}

func withUncancelledTask<Result: Sendable>(
    returning: Result.Type = Result.self,
    _ body: @Sendable @escaping () async -> Result
) async -> Result {
    // This looks unstructured but it isn't, please note that we `await` `.value` of this task.
    // The reason we need this separate `Task` is that in general, we cannot assume that code performs to our
    // expectations if the task we run it on is already cancelled. However, in some cases we need the code to
    // run regardless -- even if our task is already cancelled. Therefore, we create a new, uncanceled task here.
    await Task {
        await body()
    }.value
}
