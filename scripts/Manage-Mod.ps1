#requires -Version 7.4
<#
.SYNOPSIS
Installs, enables, disables, or uninstalls the global Windhawk handoff mod.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Enable', 'Disable', 'Uninstall', 'Status')]
    [string]$Action = 'Status',
    [string]$BuildPath = (Join-Path $PSScriptRoot '..\dist'),
    [string]$StateRoot = (Join-Path $env:ProgramData 'WindowsTerminalHandoffFix'),
    [string[]]$IncludeApplication = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
Assert-WindowsHost
$StateRoot = Get-AbsoluteDirectory $StateRoot
$directory = Join-Path $StateRoot 'mod'
$stateFile = Join-Path $directory 'state.json'
$state = Read-DeploymentState $directory 'state.json'
$modId = 'console-default-terminal'
$key = 'HKLM:\SOFTWARE\Windhawk\Engine\Mods\' + $modId
$engineKey = 'HKLM:\SOFTWARE\Windhawk\Engine\Settings'
$storage = Join-Path $env:ProgramData 'Windhawk'

function Get-PatternList {
    param([AllowNull()][string]$Value)
    return @($Value -split '\|' | Where-Object { $_ })
}

function Test-ApplicationPattern {
    param([string]$Path, [AllowNull()][string]$Patterns)
    foreach ($pattern in Get-PatternList $Patterns) {
        $expanded = [Environment]::ExpandEnvironmentVariables($pattern)
        if ($Path -like $expanded -or [IO.Path]::GetFileName($Path) -like $expanded) { return $true }
    }
    return $false
}

function Get-SettingString {
    param($Settings, [string]$Name)
    $property = $Settings.PSObject.Properties[$Name]
    if ($property) { return [string]$property.Value }
    return ''
}

function Remove-ApplicationException {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Deployment)
    if (-not $PSCmdlet.ShouldProcess('Windhawk application exceptions', 'Remove deployment-owned entries')) { return }
    foreach ($entry in $Deployment.Exceptions) {
        if (-not (Test-Path -LiteralPath $entry.Key)) { continue }
        $current = Get-SettingString (Get-ItemProperty -LiteralPath $entry.Key) $entry.Name
        $remaining = @(Get-PatternList $current | Where-Object { $_ -ine $entry.Path })
        Set-ItemProperty -LiteralPath $entry.Key -Name $entry.Name -Value ($remaining -join '|')
    }
}

function Undo-ModInstallation {
    param([Parameter(Mandatory)]$Deployment)
    if ($Deployment.Library -ne 'console-default-terminal_1.0.0.dll') { throw 'Unknown mod library identity.' }
    foreach ($file in $Deployment.Files) {
        $allowed = @(
            (Join-Path $storage ('Engine\Mods\32\' + $Deployment.Library)),
            (Join-Path $storage ('Engine\Mods\64\' + $Deployment.Library)),
            (Join-Path $storage 'ModsSource\console-default-terminal.wh.cpp')
        )
        if ([IO.Path]::GetFullPath($file.Destination) -notin $allowed) { throw 'Unexpected mod cleanup target.' }
    }
    if (Test-Path -LiteralPath $key) {
        $library = Get-SettingString (Get-ItemProperty -LiteralPath $key) 'LibraryFileName'
        if (-not $Deployment.KeyCreated -or ($library -and $library -ne $Deployment.Library)) {
            throw 'The installed mod does not match the deployment state.'
        }
        Set-ItemProperty -LiteralPath $key -Name Disabled -Value 1
    }
    Remove-ApplicationException $Deployment
    $service = Get-Service Windhawk
    if ($service.Status -eq 'Running') { Restart-Service Windhawk } else { Start-Service Windhawk }
    foreach ($file in $Deployment.Files) {
        if ($file.Created -and (Test-Path -LiteralPath $file.Destination)) {
            if (-not $file.MayBePartial -and (Get-FileHash -LiteralPath $file.Destination).Hash -ne $file.SHA256) {
                throw 'An installed mod file was modified; it was not deleted.'
            }
            Remove-Item -LiteralPath $file.Destination
        }
    }
    if (Test-Path -LiteralPath $key) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
        try { $base.DeleteSubKeyTree('SOFTWARE\Windhawk\Engine\Mods\' + $modId, $false) } finally { $base.Dispose() }
    }
    Remove-WorkDirectory $directory $StateRoot '^mod$'
}

if ($Action -eq 'Status') {
    [pscustomobject]@{ Installed = [bool]$state; Deployment = $state }
    return
}
if (-not $PSCmdlet.ShouldProcess($modId, "$Action global Windhawk handoff mod")) { return }
Assert-Administrator
if (-not (Test-Path -LiteralPath $engineKey)) { throw 'A standard registry-backed Windhawk installation is required.' }
if ($Action -eq 'Install') {
    if ((Get-Service Windhawk).Status -ne 'Running') { throw 'Start Windhawk before installing the mod.' }
    if ($state -or (Test-Path -LiteralPath $key) -or (Test-Path -LiteralPath $directory)) {
        throw 'This mod ID or its deployment state already exists. Existing installations are not overwritten.'
    }
    $BuildPath = [IO.Path]::GetFullPath($BuildPath)
    $manifest = Get-Content -LiteralPath (Join-Path $BuildPath 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.Schema -ne 1 -or $manifest.Project -ne 'windows-terminal-handoff-fix' -or $manifest.ModId -ne $modId -or $manifest.Version -ne '1.0.0') {
        throw 'Unsupported mod build manifest.'
    }
    $files = @()
    foreach ($pair in @(@('x86', '32'), @('x64', '64'))) {
        $binary = $manifest.Binaries[$pair[0]]
        if ($binary.File -ne ('console-default-terminal-' + $pair[0] + '.dll')) { throw 'Unexpected mod binary name.' }
        $source = Join-Path $BuildPath $binary.File
        if ((Get-FileHash -LiteralPath $source).Hash -ne $binary.SHA256) { throw 'Mod binary checksum mismatch.' }
        $destination = Join-Path $storage ('Engine\Mods\' + $pair[1] + '\console-default-terminal_1.0.0.dll')
        if (Test-Path -LiteralPath $destination) { throw 'A destination mod library already exists.' }
        $files += @{ Source = $source; Destination = $destination; SHA256 = $binary.SHA256; Created = $false; MayBePartial = $false }
    }
    $source = Join-Path $BuildPath 'console-default-terminal.wh.cpp'
    if ((Get-FileHash -LiteralPath $source).Hash -ne $manifest.SourceSHA256) { throw 'Mod source checksum mismatch.' }
    $sourceDestination = Join-Path $storage 'ModsSource\console-default-terminal.wh.cpp'
    if (Test-Path -LiteralPath $sourceDestination) { throw 'An existing mod source file is not overwritten.' }
    $files += @{ Source = $source; Destination = $sourceDestination; SHA256 = $manifest.SourceSHA256; Created = $false; MayBePartial = $false }
    $exceptions = @()
    foreach ($application in $IncludeApplication) {
        $application = [IO.Path]::GetFullPath($application)
        if (-not (Test-Path -LiteralPath $application -PathType Leaf) -or [IO.Path]::GetExtension($application) -ine '.exe') {
            throw "An existing executable path is required: $application"
        }
        $includes = Get-SettingString (Get-ItemProperty -LiteralPath $engineKey) 'Include'
        if (Test-ApplicationPattern $application $includes) { continue }
        $exceptions += @{ Key = $engineKey; Name = 'Include'; Path = $application }
        foreach ($other in Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Windhawk\Engine\Mods') {
            $settings = Get-ItemProperty -LiteralPath $other.PSPath
            $onlyCustom = Get-SettingString $settings 'IncludeExcludeCustomOnly'
            $inc = Get-SettingString $settings 'IncludeCustom'
            $exc = Get-SettingString $settings 'ExcludeCustom'
            if ($onlyCustom -ne '1') {
                $inc += '|' + (Get-SettingString $settings 'Include')
                $exc += '|' + (Get-SettingString $settings 'Exclude')
            }
            if ((Test-ApplicationPattern $application $inc) -and -not (Test-ApplicationPattern $application $exc)) {
                $exceptions += @{ Key = $other.PSPath; Name = 'ExcludeCustom'; Path = $application }
            }
        }
    }
    $state = @{
        Schema = 1; Project = 'windows-terminal-handoff-fix'; UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Phase = 'Installing'; KeyCreated = $false; Library = 'console-default-terminal_1.0.0.dll'; Files = $files; Exceptions = $exceptions
    }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Write-JsonFile $stateFile $state
    try {
        foreach ($file in $files) { Copy-NewDeploymentFile $file $state $stateFile }
        New-Item -Path $key | Out-Null
        $state.KeyCreated = $true
        Write-JsonFile $stateFile $state
        foreach ($pair in @{
                LibraryFileName = $state.Library; Include = '*'; Architecture = 'x86|x86-64'; Version = '1.0.0'
                Exclude = 'windhawk.exe|windhawk-x64-helper.exe|conhost.exe|OpenConsole.exe|WindowsTerminal.exe'
                IncludeCustom = ''; ExcludeCustom = ''
            }.GetEnumerator()) { New-ItemProperty -LiteralPath $key -Name $pair.Key -Value $pair.Value -PropertyType String | Out-Null }
        foreach ($name in 'Disabled', 'IncludeExcludeCustomOnly', 'PatternsMatchCriticalSystemProcesses', 'LoggingEnabled', 'DebugLoggingEnabled') {
            New-ItemProperty -LiteralPath $key -Name $name -Value 0 -PropertyType DWord | Out-Null
        }
        foreach ($entry in $exceptions) {
            $current = Get-SettingString (Get-ItemProperty -LiteralPath $entry.Key) $entry.Name
            $list = @(Get-PatternList $current) + $entry.Path
            Set-ItemProperty -LiteralPath $entry.Key -Name $entry.Name -Value (($list | Select-Object -Unique) -join '|')
        }
        Restart-Service -Name Windhawk -ErrorAction Stop
        $state.Phase = 'Installed'
        Write-JsonFile $stateFile $state
    }
    catch {
        $failure = $_
        try { Undo-ModInstallation $state } catch {
            $state.Phase = 'RecoveryRequired'
            Write-JsonFile $stateFile $state
            Write-Warning "Mod rollback could not finish. Recovery state: $directory. $($_.Exception.Message)"
        }
        throw $failure
    }
    return
}
if (-not $state) { throw 'No managed mod deployment was found.' }
if ($Action -eq 'Uninstall') { Undo-ModInstallation $state; return }
if ((Get-ItemProperty -LiteralPath $key).LibraryFileName -ne $state.Library) { throw 'The installed mod does not match its deployment state.' }
if ($Action -in 'Enable', 'Disable') {
    Set-ItemProperty -LiteralPath $key -Name Disabled -Value ([int]($Action -eq 'Disable'))
    Restart-Service Windhawk
    return
}
