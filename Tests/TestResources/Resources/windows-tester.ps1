##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift.org open source project
##
## Copyright (c) 2025 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See https://swift.org/LICENSE.txt for license information
##
##===----------------------------------------------------------------------===##

param (
    [string]$mode,
    [int]$processID
)

Add-Type @"
   using System;
   using System.Runtime.InteropServices;
   public class NativeMethods {
       [DllImport("Kernel32.dll")]
       public static extern IntPtr GetConsoleWindow();
   }
"@

function GetConsoleWindow {
    $consoleHandle = [NativeMethods]::GetConsoleWindow()
    Write-Output $consoleHandle
}

function IsProcessSuspended {
    $process = Get-Process -Id $processID -ErrorAction SilentlyContinue
    if ($process) {
        $threads = $process.Threads
        $suspendedThreadCount = ($threads | Where-Object { $_.WaitReason -eq 'Suspended' }).Count
        if ($threads.Count -eq $suspendedThreadCount) {
            Write-Output "true"
        } else {
            Write-Output "false"
        }
    } else {
        Write-Output "Process not found."
    }
}

switch ($mode) {
    'get-console-window' { GetConsoleWindow }
    'is-process-suspended' { IsProcessSuspended -processID $processID }
    default { Write-Output "Invalid mode specified: [$mode]" }
}
