function Get-TerminalRegistryEntry {
    param([Parameter(Mandatory)][string]$AppPath, [switch]$ContextMenu)
    $entries = [Collections.Generic.List[hashtable]]::new()
    foreach ($view in 'Registry64', 'Registry32') {
        $values = @(
            @('CLSID\{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}\LocalServer32', '', ('"' + $AppPath + '\OpenConsole.exe"')),
            @('CLSID\{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}\LocalServer32', '', ('"' + $AppPath + '\WindowsTerminal.exe"')),
            @('CLSID\{3171DE52-6EFA-4AEF-8A9F-D02BD67E7A4F}\InprocServer32', '',
                (Join-Path $AppPath $(if ($view -eq 'Registry64') { 'OpenConsoleProxy.dll' } else { 'x86\OpenConsoleProxy.dll' }))),
            @('CLSID\{3171DE52-6EFA-4AEF-8A9F-D02BD67E7A4F}\InprocServer32', 'ThreadingModel', 'Both')
        )
        foreach ($iid in '{E686C757-9A35-4A1C-B3CE-0BCC8B5C69F4}',
            '{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}', '{746E6BC0-AB05-4E38-AB14-71E86763141F}') {
            $values += , @("Interface\$iid\ProxyStubClsid32", '', '{3171DE52-6EFA-4AEF-8A9F-D02BD67E7A4F}')
        }
        foreach ($value in $values) {
            $entries.Add(@{ Hive = 'LocalMachine'; View = $view; Path = 'SOFTWARE\Classes\' + $value[0]; Name = $value[1]; Value = $value[2] })
        }
    }
    foreach ($pair in @(@('DelegationConsole', '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'),
            @('DelegationTerminal', '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'))) {
        $entries.Add(@{ Hive = 'CurrentUser'; View = 'Registry64'; Path = 'Console\%%Startup'; Name = $pair[0]; Value = $pair[1] })
    }
    foreach ($exe in 'wt.exe', 'WindowsTerminal.exe') {
        $path = "SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe"
        $entries.Add(@{ Hive = 'LocalMachine'; View = 'Registry64'; Path = $path; Name = ''; Value = Join-Path $AppPath $exe })
        $entries.Add(@{ Hive = 'LocalMachine'; View = 'Registry64'; Path = $path; Name = 'Path'; Value = $AppPath })
    }
    if ($ContextMenu) {
        foreach ($kind in 'Directory', 'Directory\Background', 'Drive') {
            $path = "SOFTWARE\Classes\$kind\shell\WindowsTerminalHandoffFix"
            $argument = if ($kind -eq 'Directory\Background') { '%V' } else { '%1' }
            $entries.Add(@{ Hive = 'LocalMachine'; View = 'Registry64'; Path = $path; Name = ''; Value = 'Open in Terminal' })
            $entries.Add(@{ Hive = 'LocalMachine'; View = 'Registry64'; Path = $path; Name = 'Icon'; Value = '"' + $AppPath + '\WindowsTerminal.exe",0' })
            $entries.Add(@{ Hive = 'LocalMachine'; View = 'Registry64'; Path = $path + '\command'; Name = ''; Value = '"' + $AppPath + '\wt.exe" -d "' + $argument + '\."' })
        }
    }
    return $entries.ToArray()
}

function Assert-TerminalOwnership {
    param([Parameter(Mandatory)]$State)
    $marker = Join-Path $State.InstallPath '.windows-terminal-handoff-fix.json'
    if (-not (Test-Path -LiteralPath $marker)) { throw 'The installation ownership marker is missing.' }
    $owner = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if ($owner.InstallationId -ne $State.InstallationId) { throw 'Installation ownership does not match the deployment state.' }
}

function Set-TerminalRegistration {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$StateFile)
    if (-not $PSCmdlet.ShouldProcess($State.InstallPath, 'Register Terminal handoff services')) { return }
    $app = Join-Path $State.InstallPath 'app'
    Assert-TerminalOwnership $State
    foreach ($name in 'WindowsTerminal.exe', 'OpenConsole.exe', 'OpenConsoleProxy.dll', 'x86\OpenConsoleProxy.dll', 'wt.exe') {
        Assert-MicrosoftBinary (Join-Path $app $name)
    }
    foreach ($entry in $State.Registry.Entries) { Set-RegistryEntry $entry }
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (@($path -split ';' | Where-Object { $_.TrimEnd('\') -ieq $app }).Count -eq 0) {
        $State.PathAdded = $true
        Write-JsonFile $StateFile $State
        [Environment]::SetEnvironmentVariable('Path', ($path.TrimEnd(';') + ';' + $app), 'Machine')
    }
    Send-EnvironmentChange
}

function Undo-TerminalDeployment {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$StateDirectory)
    Assert-TerminalOwnership $State
    Assert-TerminalClosed $State.InstallPath
    if ($State.RemoveStore -and $State.OriginalStoreVersion -and -not (Get-AppxPackage Microsoft.WindowsTerminal)) {
        $bundle = Join-Path $StateDirectory 'store.msixbundle'
        if ((Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash -ne $State.StoreBundleHash) {
            throw 'The Store recovery package checksum does not match.'
        }
        Add-AppxPackage -Path $bundle
        $destination = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Get-ChildItem -LiteralPath $State.SettingsPath | Copy-Item -Destination $destination -Recurse -Force
    }
    Restore-RegistryJournal $State.Registry
    if ($State.PathAdded) {
        $app = Join-Path $State.InstallPath 'app'
        $entries = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' |
            Where-Object { $_.TrimEnd('\') -ine $app }
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'Machine')
    }
    Send-EnvironmentChange
    $parent = Split-Path $State.InstallPath -Parent
    $leaf = '^' + [regex]::Escape((Split-Path $State.InstallPath -Leaf)) + '$'
    Remove-WorkDirectory $State.InstallPath $parent $leaf
    Remove-WorkDirectory $StateDirectory (Split-Path $StateDirectory -Parent) '^terminal$'
}

function Install-TerminalDeployment {
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$Version,
        [switch]$RemoveStore,
        [switch]$ContextMenu
    )
    $directory = Join-Path $StateRoot 'terminal'
    if (Test-Path -LiteralPath $InstallPath) { throw 'The installation directory already exists; choose an empty, unused destination.' }
    if (Test-Path -LiteralPath $directory) { throw 'Terminal deployment state already exists; use Repair, Update, or Uninstall.' }
    $release = Get-TerminalRelease $Version
    $work = Join-Path $env:TEMP ('windows-terminal-handoff-fix-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $state = $null
    $stateDirectoryCreated = $false
    $installDirectoryCreated = $false
    try {
        $app = Expand-TerminalRelease $release $work
        $package = Get-AppxPackage Microsoft.WindowsTerminal
        $storeBundle = $null
        if ($package -and $RemoveStore) {
            $storeRelease = Get-TerminalRelease $package.Version.ToString()
            $storeBundle = Join-Path $work 'store.msixbundle'
            Save-ReleaseAsset $storeRelease ("Microsoft.WindowsTerminal_" + $package.Version + '_8wekyb3d8bbwe.msixbundle') $storeBundle
        }
        $settings = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal'
        $source = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $stateDirectoryCreated = $true
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $directory 'original-settings') -Recurse }
        New-Item -ItemType Directory -Path $settings -Force | Out-Null
        if (-not (Get-ChildItem -LiteralPath $settings -Force) -and (Test-Path -LiteralPath $source)) {
            Get-ChildItem -LiteralPath $source | Copy-Item -Destination $settings -Recurse
        }
        $state = @{
            Schema = 1; Project = 'windows-terminal-handoff-fix'; Phase = 'Installing'
            InstallationId = [guid]::NewGuid().ToString('N')
            UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Version = $release.tag_name.Substring(1); InstallPath = $InstallPath
            SettingsPath = $settings; RemoveStore = [bool]$RemoveStore
            OriginalStoreVersion = if ($package) { $package.Version.ToString() } else { $null }
            StoreBundleHash = if ($storeBundle) { (Get-FileHash -LiteralPath $storeBundle).Hash } else { $null }
            PathAdded = $false
            Registry = Get-RegistryJournal @(Get-TerminalRegistryEntry (Join-Path $InstallPath 'app') -ContextMenu:$ContextMenu)
        }
        if ($storeBundle) { Copy-Item -LiteralPath $storeBundle -Destination (Join-Path $directory 'store.msixbundle') }
        $stateFile = Join-Path $directory 'state.json'
        Write-JsonFile $stateFile $state
        New-Item -ItemType Directory -Path $InstallPath | Out-Null
        $installDirectoryCreated = $true
        Write-JsonFile (Join-Path $InstallPath '.windows-terminal-handoff-fix.json') @{ InstallationId = $state.InstallationId }
        Copy-Item -LiteralPath $app -Destination (Join-Path $InstallPath 'app') -Recurse
        Set-TerminalRegistration $state $stateFile
        if ($package -and $RemoveStore) { Remove-AppxPackage -Package $package.PackageFullName }
        $state.Phase = 'Installed'
        Write-JsonFile $stateFile $state
        return [pscustomobject]@{ Version = $state.Version; InstallPath = $InstallPath; SettingsPath = $settings }
    }
    catch {
        $failure = $_
        if ($state -and (Test-Path -LiteralPath (Join-Path $InstallPath '.windows-terminal-handoff-fix.json'))) {
            try { Undo-TerminalDeployment $state $directory } catch {
                Write-Warning "Automatic rollback could not finish. Recovery state: $directory. $($_.Exception.Message)"
            }
        }
        else {
            if ($installDirectoryCreated) {
                Remove-WorkDirectory $InstallPath (Split-Path $InstallPath -Parent) ('^' + [regex]::Escape((Split-Path $InstallPath -Leaf)) + '$')
            }
            if ($stateDirectoryCreated) { Remove-WorkDirectory $directory $StateRoot '^terminal$' }
        }
        throw $failure
    }
    finally { Remove-WorkDirectory $work $env:TEMP '^windows-terminal-handoff-fix-[a-f0-9]{32}$' }
}

function Update-TerminalDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$StateDirectory, [string]$Version)
    if (-not $PSCmdlet.ShouldProcess($State.InstallPath, 'Update Terminal deployment')) { return }
    Assert-TerminalOwnership $State
    Assert-TerminalClosed $State.InstallPath
    $release = Get-TerminalRelease $Version
    if ($release.tag_name.Substring(1) -eq $State.Version) { return }
    $app = Join-Path $State.InstallPath 'app'
    $previous = Join-Path $State.InstallPath 'previous-app'
    $pending = Join-Path $State.InstallPath 'pending-app'
    if ((Test-Path -LiteralPath $previous) -or (Test-Path -LiteralPath $pending)) {
        throw 'A previous update needs recovery; pending-app or previous-app already exists.'
    }
    $work = Join-Path $StateDirectory ('work-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $oldVersion = $State.Version
    $swapped = $false
    try {
        $new = Expand-TerminalRelease $release $work
        Copy-Item -LiteralPath $new -Destination $pending -Recurse
        [IO.Directory]::Move($app, $previous)
        try { [IO.Directory]::Move($pending, $app) } catch { [IO.Directory]::Move($previous, $app); throw }
        $swapped = $true
        $State.Version = $release.tag_name.Substring(1)
        Set-TerminalRegistration $State (Join-Path $StateDirectory 'state.json')
        Write-JsonFile (Join-Path $StateDirectory 'state.json') $State
    }
    catch {
        if ($swapped) {
            Remove-WorkDirectory $app $State.InstallPath '^app$'
            [IO.Directory]::Move($previous, $app)
            $State.Version = $oldVersion
            Set-TerminalRegistration $State (Join-Path $StateDirectory 'state.json')
            Write-JsonFile (Join-Path $StateDirectory 'state.json') $State
        }
        throw
    }
    finally {
        Remove-WorkDirectory $work $StateDirectory '^work-[a-f0-9]{32}$'
        if (Test-Path -LiteralPath $pending) { Remove-WorkDirectory $pending $State.InstallPath '^pending-app$' }
    }
    Remove-WorkDirectory $previous $State.InstallPath '^previous-app$'
}
