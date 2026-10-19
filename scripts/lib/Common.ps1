#requires -Version 7.4

Set-StrictMode -Version Latest

function Assert-WindowsHost {
    if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
        throw 'Run this command in 64-bit PowerShell 7.4 or later on x64 Windows.'
    }
}

function Assert-Administrator {
    Assert-WindowsHost
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this command in an elevated PowerShell session.'
    }
}

function Get-AbsoluteDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathFullyQualified($expanded)) {
        throw "An absolute directory is required: $Path"
    }
    $resolved = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($resolved).TrimEnd('\')
    if ($resolved -eq $root -or $resolved -eq $env:USERPROFILE) {
        throw "A filesystem root or user-profile root is not a deployment directory: $Path"
    }
    return $resolved
}

function Remove-WorkDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$NamePattern
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $target = (Resolve-Path -LiteralPath $Path).Path
    $boundary = (Get-AbsoluteDirectory $Parent).TrimEnd('\') + '\'
    if (-not $target.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $target -Leaf) -notmatch $NamePattern) {
        throw "Refusing to delete a directory outside the cleanup boundary: $target"
    }
    $item = Get-Item -LiteralPath $target -Force
    while ($item -and $item.FullName.Length -ge $boundary.TrimEnd('\').Length) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to traverse a reparse point: $($item.FullName)"
        }
        $item = $item.Parent
    }
    if (-not $PSCmdlet.ShouldProcess($target, 'Delete owned directory permanently')) { return }
    # Unlink nested reparse points explicitly; never recurse into their targets.
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push([IO.DirectoryInfo]::new($target))
    $links = [Collections.Generic.List[IO.FileSystemInfo]]::new()
    while ($pending.Count) {
        foreach ($child in $pending.Pop().GetFileSystemInfos()) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if (-not $child.FullName.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'A nested cleanup entry escaped the owned directory.'
                }
                $links.Add($child)
            }
            elseif ($child -is [IO.DirectoryInfo]) { $pending.Push($child) }
        }
    }
    foreach ($link in $links) {
        if ($link -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($link.FullName, $false) }
        else { [IO.File]::Delete($link.FullName) }
    }
    [IO.Directory]::Delete($target, $true)
    if (Test-Path -LiteralPath $target) { throw "Directory removal failed: $target" }
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30) + "`n",
            [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
    }
}

function Copy-NewDeploymentFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$File, [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$StateFile)
    if (-not $PSCmdlet.ShouldProcess($File.Destination, 'Create deployment-owned file')) { return }
    $inputStream = [IO.File]::OpenRead($File.Source)
    $outputStream = $null
    try {
        $outputStream = [IO.File]::Open($File.Destination, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $File.Created = $true
        $File.MayBePartial = $true
        Write-JsonFile $StateFile $State
        $inputStream.CopyTo($outputStream)
        $outputStream.Flush()
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        $inputStream.Dispose()
    }
    if ((Get-FileHash -LiteralPath $File.Destination).Hash -ne $File.SHA256) {
        throw 'Deployment file checksum mismatch after copying.'
    }
    $File.MayBePartial = $false
    Write-JsonFile $StateFile $State
}

function Read-DeploymentState {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$FileName)
    $path = Join-Path $StateRoot $FileName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($state.Schema -ne 1 -or $state.Project -ne 'windows-terminal-handoff-fix') {
        throw "Unknown deployment-state format: $path"
    }
    if ($state.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        throw 'Run this command from the Windows account that owns this deployment.'
    }
    return $state
}

function Get-RegistryValueSnapshot {
    param([Parameter(Mandatory)]$Entry)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Entry.Hive, $Entry.View)
    $key = $null
    try {
        $key = $base.OpenSubKey($Entry.Path)
        $exists = $key -and $key.GetValueNames() -contains $Entry.Name
        return @{
            Exists = [bool]$exists
            Value = if ($exists) { $key.GetValue($Entry.Name, $null, 'DoNotExpandEnvironmentNames') } else { $null }
            Kind = if ($exists) { $key.GetValueKind($Entry.Name).ToString() } else { 'String' }
        }
    }
    finally {
        if ($key) { $key.Dispose() }
        $base.Dispose()
    }
}

function Set-RegistryEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Entry)
    if (-not $PSCmdlet.ShouldProcess($Entry.Path, 'Write registry value')) { return }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Entry.Hive, $Entry.View)
    try {
        $key = $base.CreateSubKey($Entry.Path)
        try { $key.SetValue($Entry.Name, $Entry.Value, 'String') } finally { $key.Dispose() }
    }
    finally { $base.Dispose() }
}

function Get-RegistryJournal {
    param([Parameter(Mandatory)][array]$Entries)
    $journal = @()
    $created = @()
    foreach ($entry in $Entries) {
        $copy = @{} + $entry
        $copy.Before = Get-RegistryValueSnapshot $entry
        $journal += $copy
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($entry.Hive, $entry.View)
        try {
            $path = $entry.Path
            while ($path.Contains('\')) {
                $key = $base.OpenSubKey($path)
                if ($key) { $key.Dispose(); break }
                $created += @{ Hive = $entry.Hive; View = $entry.View; Path = $path }
                $path = $path.Substring(0, $path.LastIndexOf('\'))
            }
        }
        finally { $base.Dispose() }
    }
    return @{ Entries = $journal; CreatedKeys = @($created | Sort-Object Hive, View, Path -Unique) }
}

function Restore-RegistryJournal {
    param([Parameter(Mandatory)]$Journal)
    foreach ($entry in $Journal.Entries) {
        $current = Get-RegistryValueSnapshot $entry
        if (-not $current.Exists -or $current.Value -cne $entry.Value) { continue }
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($entry.Hive, $entry.View)
        try {
            $key = $base.OpenSubKey($entry.Path, $true)
            try {
                if ($entry.Before.Exists) {
                    $key.SetValue($entry.Name, $entry.Before.Value,
                        [Microsoft.Win32.RegistryValueKind]$entry.Before.Kind)
                }
                else { $key.DeleteValue($entry.Name, $false) }
            }
            finally { $key.Dispose() }
        }
        finally { $base.Dispose() }
    }
    foreach ($entry in $Journal.CreatedKeys | Sort-Object { $_.Path.Length } -Descending) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($entry.Hive, $entry.View)
        try {
            $key = $base.OpenSubKey($entry.Path)
            $empty = $key -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
            if ($key) { $key.Dispose() }
            if ($empty) { $base.DeleteSubKey($entry.Path, $false) }
        }
        finally { $base.Dispose() }
    }
}

function Get-TerminalRelease {
    param([string]$Version)
    if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw 'Version must have four numeric components, for example 1.25.2733.0.'
    }
    $url = if ($Version) {
        "https://api.github.com/repos/microsoft/terminal/releases/tags/v$Version"
    }
    else { 'https://api.github.com/repos/microsoft/terminal/releases/latest' }
    $release = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'windows-terminal-handoff-fix' }
    if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v\d+\.\d+\.\d+\.\d+$') {
        throw 'A published stable Windows Terminal release is required.'
    }
    return $release
}

function Save-ReleaseAsset {
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Destination)
    $asset = @($Release.assets | Where-Object name -eq $Name)
    if ($asset.Count -ne 1) { throw "Official release asset not found: $Name" }
    $uri = [uri]$asset[0].browser_download_url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or
        -not $uri.AbsolutePath.StartsWith('/microsoft/terminal/releases/download/', [StringComparison]::Ordinal)) {
        throw 'Unexpected release-asset origin.'
    }
    if ($asset[0].digest -notmatch '^sha256:[a-f0-9]{64}$') { throw 'The release asset has no SHA-256 digest.' }
    Invoke-WebRequest -Uri $uri -OutFile $Destination
    if (('sha256:' + (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()) -ne $asset[0].digest) {
        throw "Release-asset checksum mismatch: $Name"
    }
}

function Assert-MicrosoftBinary {
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
        throw "A valid Microsoft signature is required: $Path"
    }
}

function Expand-TerminalRelease {
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)][string]$WorkDirectory)
    $version = $Release.tag_name.Substring(1)
    foreach ($arch in 'x64', 'x86') {
        $archive = Join-Path $WorkDirectory ($arch + '.zip')
        Save-ReleaseAsset $Release "Microsoft.WindowsTerminal_${version}_$arch.zip" $archive
        Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $WorkDirectory $arch)
    }
    $app = Join-Path $WorkDirectory "x64\terminal-$version"
    foreach ($file in Get-ChildItem -LiteralPath $app -Recurse -File | Where-Object Extension -in '.exe', '.dll') {
        Assert-MicrosoftBinary $file.FullName
    }
    foreach ($name in 'WindowsTerminal.exe', 'OpenConsole.exe', 'OpenConsoleProxy.dll', 'wt.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $app $name))) { throw "Terminal component missing: $name" }
    }
    $proxy = Join-Path $WorkDirectory "x86\terminal-$version\OpenConsoleProxy.dll"
    Assert-MicrosoftBinary $proxy
    New-Item -ItemType Directory -Path (Join-Path $app 'x86') | Out-Null
    Copy-Item -LiteralPath $proxy -Destination (Join-Path $app 'x86\OpenConsoleProxy.dll')
    return $app
}

function Send-EnvironmentChange {
    if (-not ('WindowsTerminalHandoffFix.EnvironmentChange' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace WindowsTerminalHandoffFix {
    public static class EnvironmentChange {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessageTimeout(IntPtr window, uint message,
            IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
        public static void Notify() {
            IntPtr result;
            SendMessageTimeout(new IntPtr(0xffff), 0x1a, IntPtr.Zero,
                "Environment", 2, 2000, out result);
        }
    }
}
'@
    }
    [WindowsTerminalHandoffFix.EnvironmentChange]::Notify()
}

function Assert-TerminalClosed {
    param([Parameter(Mandatory)][string]$InstallPath)
    $prefix = $InstallPath.TrimEnd('\') + '\'
    $active = @(Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($active.Count) { throw 'Close this Terminal deployment and its sessions before continuing.' }
}
