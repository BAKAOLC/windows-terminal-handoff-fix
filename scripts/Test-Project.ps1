#requires -Version 7.4
<#
.SYNOPSIS
Runs syntax checks, static analysis, and isolated PowerShell tests.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Development.ps1')
Import-DevelopmentModule PSScriptAnalyzer
Import-DevelopmentModule Pester
$project = Split-Path $PSScriptRoot -Parent
foreach ($folder in 'scripts', 'tests') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $project $folder) -Recurse -Filter '*.ps1' -File) {
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors) { throw ($parseErrors | Out-String) }
    }
}
$findings = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings (Join-Path $project 'PSScriptAnalyzerSettings.psd1') -Severity Warning, Error)
if ($findings.Count) { $findings | Format-Table -AutoSize | Out-Host; throw 'Static analysis failed.' }
$result = Invoke-Pester -Path (Join-Path $project 'tests') -PassThru -Output Detailed
if ($result.FailedCount -or $result.Result -ne 'Passed') { throw 'Project tests failed.' }
