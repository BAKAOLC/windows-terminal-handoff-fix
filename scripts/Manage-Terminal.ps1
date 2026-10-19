#requires -Version 7.4
<#
.SYNOPSIS
Installs and maintains an unpackaged Windows Terminal deployment with global COM registration.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Update', 'Repair', 'Uninstall', 'Status')]
    [string]$Action = 'Status',
    [string]$Version,
    [string]$InstallPath = (Join-Path $env:ProgramFiles 'Windows Terminal'),
    [string]$StateRoot = (Join-Path $env:ProgramData 'WindowsTerminalHandoffFix'),
    [switch]$RemoveStore,
    [switch]$ContextMenu
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Terminal.ps1')
Assert-WindowsHost
$InstallPath = Get-AbsoluteDirectory $InstallPath
$StateRoot = Get-AbsoluteDirectory $StateRoot
if ($StateRoot.StartsWith($InstallPath + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $InstallPath.StartsWith($StateRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $StateRoot -eq $InstallPath) {
    throw 'Installation and recovery-state directories must be separate.'
}
$directory = Join-Path $StateRoot 'terminal'
$state = Read-DeploymentState $directory 'state.json'
if ($Action -eq 'Status') {
    [pscustomobject]@{ Installed = [bool]$state; Deployment = $state }
    return
}
if (-not $PSCmdlet.ShouldProcess($InstallPath, "$Action Windows Terminal deployment")) { return }
Assert-Administrator
if ($Action -eq 'Install') {
    Install-TerminalDeployment -InstallPath $InstallPath -StateRoot $StateRoot -Version $Version -RemoveStore:$RemoveStore -ContextMenu:$ContextMenu
    return
}
if (-not $state) { throw 'No deployment state was found. Install this deployment before using this action.' }
switch ($Action) {
    'Update' { Update-TerminalDeployment $state $directory $Version }
    'Repair' { Set-TerminalRegistration $state (Join-Path $directory 'state.json') }
    'Uninstall' { Undo-TerminalDeployment $state $directory }
}
