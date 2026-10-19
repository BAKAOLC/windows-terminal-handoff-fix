#requires -Version 7.4
<#
.SYNOPSIS
Builds the 32-bit and 64-bit Windhawk mod with the installed Windhawk toolchain.
#>
[CmdletBinding()]
param(
    [string]$WindhawkPath = (Join-Path $env:ProgramFiles 'Windhawk'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\dist')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
Assert-WindowsHost
$WindhawkPath = Get-AbsoluteDirectory $WindhawkPath
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$project = Split-Path $PSScriptRoot -Parent
$compiler = Join-Path $WindhawkPath 'Compiler\bin\clang++.exe'
$source = Join-Path $project 'src\console-default-terminal.wh.cpp'
$configuration = Get-Content -LiteralPath (Join-Path $WindhawkPath 'windhawk.ini') -Raw
$engineMatch = [regex]::Match($configuration, '(?m)^EnginePath=(.+)\r?$')
if (-not $engineMatch.Success) { throw 'Windhawk EnginePath was not found.' }
$engine = Join-Path $WindhawkPath $engineMatch.Groups[1].Value.Trim()
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windhawk compiler is not installed.' }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$binaries = @{}
foreach ($item in @(@('x86', '32', 'i686-w64-mingw32'), @('x64', '64', 'x86_64-w64-mingw32'))) {
    $output = Join-Path $OutputPath ('console-default-terminal-' + $item[0] + '.dll')
    $library = Join-Path $engine ($item[1] + '\windhawk.lib')
    if (-not (Test-Path -LiteralPath $library)) { throw "Windhawk import library missing: $library" }
    $arguments = @(
        '-std=c++23', '-O2', '-shared', '-DUNICODE', '-D_UNICODE', '-DWH_MOD',
        '-DWH_MOD_ID=L"console-default-terminal"', '-DWH_MOD_VERSION=L"1.0.1"',
        '-DWINVER=0x0A00', '-D_WIN32_WINNT=0x0A00', '-DNTDDI_VERSION=0x0A000008',
        '-D__USE_MINGW_ANSI_STDIO=0', '-target', $item[2],
        '-include', (Join-Path $WindhawkPath 'Compiler\include\windhawk_api.h'),
        $source, $library, '-luser32', '-o', $output
    )
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw "Mod compilation failed: $($item[0])" }
    $binaries[$item[0]] = @{ File = Split-Path $output -Leaf; SHA256 = (Get-FileHash -LiteralPath $output).Hash }
}
$manifest = @{
    Schema = 1; Project = 'windows-terminal-handoff-fix'; ModId = 'console-default-terminal'; Version = '1.0.1'
    SourceSHA256 = (Get-FileHash -LiteralPath $source).Hash
    Binaries = $binaries
    Compatibility = 'ConDrv server EA protocol; exported AllocConsole and NtCreateFile'
}
Copy-Item -LiteralPath $source -Destination (Join-Path $OutputPath 'console-default-terminal.wh.cpp') -Force
Write-JsonFile (Join-Path $OutputPath 'manifest.json') $manifest
[pscustomobject]@{ OutputPath = $OutputPath; Architectures = 'x86', 'x64'; Version = $manifest.Version }
