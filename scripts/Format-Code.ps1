#requires -Version 7.4
<#
.SYNOPSIS
Formats PowerShell, C++, Markdown, and JSON files, or checks that formatting is current.
#>
[CmdletBinding()]
param([switch]$Check, [string]$ClangFormat = 'clang-format')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Development.ps1')
Import-DevelopmentModule PSScriptAnalyzer
$project = Split-Path $PSScriptRoot -Parent
$settings = Join-Path $project 'PSScriptAnalyzerSettings.psd1'
$clang = Get-Command $ClangFormat -ErrorAction SilentlyContinue
if (-not $clang) {
    $locator = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $locator) {
        $candidate = & $locator -latest -products '*' -find 'VC\Tools\Llvm\bin\clang-format.exe' | Select-Object -First 1
        if ($candidate) { $clang = Get-Command $candidate }
    }
}
if (-not $clang) { throw 'Install clang-format or provide its path with -ClangFormat.' }
$different = @()
$powershellFiles = @(Get-ChildItem -LiteralPath $project -Filter '*.psd1' -File)
foreach ($folder in 'scripts', 'tests') {
    $powershellFiles += Get-ChildItem -LiteralPath (Join-Path $project $folder) -Recurse -File |
        Where-Object Extension -in '.ps1', '.psm1', '.psd1'
}
foreach ($file in $powershellFiles) {
    $original = Get-Content -LiteralPath $file.FullName -Raw
    $formatted = (Invoke-Formatter -ScriptDefinition $original -Settings $settings).Replace("`r`n", "`n").TrimEnd() + "`n"
    if ($original -cne $formatted) {
        if ($Check) { $different += $file.FullName } else { [IO.File]::WriteAllText($file.FullName, $formatted, [Text.UTF8Encoding]::new($false)) }
    }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $project 'src'), (Join-Path $project 'tests') -Recurse -File |
        Where-Object Extension -in '.cpp', '.h', '.hpp') {
    $arguments = if ($Check) { @('--dry-run', '--Werror', $file.FullName) } else { @('-i', $file.FullName) }
    & $clang.Source @arguments
    if ($LASTEXITCODE -ne 0) { throw 'C++ formatting check failed.' }
}
Push-Location $project
try {
    $task = if ($Check) { 'check:docs' } else { 'format:docs' }
    & bun run $task
    if ($LASTEXITCODE -ne 0) { throw 'Document formatting check failed.' }
}
finally { Pop-Location }
if ($different.Count) { throw ('PowerShell formatting differs: ' + ($different -join ', ')) }
