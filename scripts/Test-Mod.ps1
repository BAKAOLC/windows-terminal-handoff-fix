#requires -Version 7.4
<#
.SYNOPSIS
Tests protocol parsing and real ConDrv requests in isolated x86 and x64 processes.
#>
[CmdletBinding()]
param([string]$WindhawkPath = (Join-Path $env:ProgramFiles 'Windhawk'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
Assert-WindowsHost
$project = Split-Path $PSScriptRoot -Parent
$work = Join-Path $env:TEMP ('windows-terminal-handoff-fix-native-' + [guid]::NewGuid().ToString('N'))
$compiler = Join-Path $WindhawkPath 'Compiler\bin\clang++.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windhawk compiler is required.' }

if (-not ('WindowsTerminalHandoffFix.NativeTestProcess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace WindowsTerminalHandoffFix {
    public static class NativeTestProcess {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct StartupInfo {
            public int cb; public string reserved, desktop, title;
            public int x, y, width, height, columns, rows, fill, flags;
            public short show, reservedSize;
            public IntPtr reservedData, input, output, error;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInformation {
            public IntPtr process, thread; public uint processId, threadId;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcessW(string app, System.Text.StringBuilder command,
            IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags,
            IntPtr environment, string directory, ref StartupInfo startup,
            out ProcessInformation information);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint time);
        [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr handle, uint code);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public static uint Run(string app, string report) {
            var startup = new StartupInfo { cb = Marshal.SizeOf<StartupInfo>() };
            var command = new System.Text.StringBuilder("\"" + app + "\" \"" + report + "\"");
            if (!CreateProcessW(app, command, IntPtr.Zero, IntPtr.Zero, false, 8,
                IntPtr.Zero, null, ref startup, out var process))
                throw new Win32Exception();
            try {
                if (WaitForSingleObject(process.process, 30000) != 0) {
                    TerminateProcess(process.process, 3);
                    WaitForSingleObject(process.process, 5000);
                    throw new TimeoutException("The isolated native test did not finish.");
                }
                if (!GetExitCodeProcess(process.process, out uint code)) throw new Win32Exception();
                return code;
            } finally { CloseHandle(process.thread); CloseHandle(process.process); }
        }
    }
}
'@
}
New-Item -ItemType Directory -Path $work | Out-Null
try {
    foreach ($architecture in @(@('x86', 'i686-w64-mingw32'), @('x64', 'x86_64-w64-mingw32'))) {
        $name = $architecture[0]
        $architectureDirectory = Join-Path $work $name
        New-Item -ItemType Directory -Path $architectureDirectory | Out-Null
        # Use an excluded basename so an existing system-wide copy of the mod
        # cannot make the isolated test pass before the implementation under test runs.
        $executable = Join-Path $architectureDirectory 'conhost.exe'
        $report = Join-Path $work ("mod-tests-$name.txt")
        $arguments = @(
            '-std=c++23', '-O2', '-mwindows', '-municode', '-static', '-DWH_EDITING', '-DWH_MOD', '-DUNICODE', '-D_UNICODE',
            '-target', $architecture[1], '-I', (Join-Path $WindhawkPath 'Compiler\include'),
            (Join-Path $project 'tests\Mod.Tests.cpp'), '-luser32', '-lshell32', '-o', $executable
        )
        & $compiler @arguments
        if ($LASTEXITCODE -ne 0) { throw "Native test compilation failed: $name" }
        $code = [WindowsTerminalHandoffFix.NativeTestProcess]::Run($executable, $report)
        if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report | Write-Host }
        if ($code -ne 0) { throw "Native tests failed for $name (exit $code)." }
    }
}
finally { Remove-WorkDirectory $work $env:TEMP '^windows-terminal-handoff-fix-native-[a-f0-9]{32}$' }
