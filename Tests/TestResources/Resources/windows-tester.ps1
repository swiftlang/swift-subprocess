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
    Write-Host $consoleHandle
}

function IsProcessSuspended {
    $process = Get-Process -Id $processID -ErrorAction SilentlyContinue
    if ($process) {
        $threads = $process.Threads
        $suspendedThreadCount = ($threads | Where-Object { $_.WaitReason -eq 'Suspended' }).Count
        if ($threads.Count -eq $suspendedThreadCount) {
            Write-Host "true"
        } else {
            Write-Host "false"
        }
    } else {
        Write-Host "Process not found."
    }
}

switch ($mode) {
    'get-console-window' { GetConsoleWindow }
    'is-process-suspended' { IsProcessSuspended -processID $processID }
    default { Write-Host "Invalid mode specified: [$mode]" }
}
