BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\Common.ps1')
    $testDirectory = Join-Path $env:TEMP ('windows-terminal-handoff-fix-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testDirectory | Out-Null
    $registryPath = 'Software\WindowsTerminalHandoffFixTests\' + [guid]::NewGuid().ToString('N')
    $registryBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry64')
    $testKey = $registryBase.CreateSubKey($registryPath)
    $testKey.Dispose()
}

AfterAll {
    $registryBase.DeleteSubKeyTree($registryPath, $false)
    $parent = $registryBase.OpenSubKey('Software\WindowsTerminalHandoffFixTests')
    $empty = $parent -and $parent.ValueCount -eq 0 -and $parent.SubKeyCount -eq 0
    if ($parent) { $parent.Dispose() }
    if ($empty) { $registryBase.DeleteSubKey('Software\WindowsTerminalHandoffFixTests', $false) }
    $registryBase.Dispose()
    Remove-WorkDirectory $testDirectory $env:TEMP '^windows-terminal-handoff-fix-tests-[a-f0-9]{32}$'
}

Describe 'Cleanup boundaries' {
    It 'rejects drive roots and the user-profile root' {
        { Get-AbsoluteDirectory ([IO.Path]::GetPathRoot($env:TEMP)) } | Should -Throw
        { Get-AbsoluteDirectory $env:USERPROFILE } | Should -Throw
    }

    It 'does not remove a sibling directory outside the boundary' {
        $parent = Join-Path $testDirectory 'boundary'
        $sibling = Join-Path $testDirectory 'sibling'
        New-Item -ItemType Directory -Path $parent, $sibling | Out-Null
        { Remove-WorkDirectory $sibling $parent '^sibling$' } | Should -Throw
        Test-Path -LiteralPath $sibling | Should -BeTrue
    }

    It 'deletes only a directory with the expected name' {
        $target = Join-Path $testDirectory 'owned-work'
        New-Item -ItemType Directory -Path $target | Out-Null
        { Remove-WorkDirectory $target $testDirectory '^something-else$' } | Should -Throw
        Remove-WorkDirectory $target $testDirectory '^owned-work$'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'does not traverse a junction inside the directory being removed' {
        $outside = Join-Path $testDirectory 'junction-target'
        $work = Join-Path $testDirectory 'junction-work'
        New-Item -ItemType Directory -Path $outside, $work | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'keep')
        New-Item -ItemType Junction -Path (Join-Path $work 'link') -Target $outside | Out-Null
        Remove-WorkDirectory $work $testDirectory '^junction-work$'
        Get-Content -LiteralPath (Join-Path $outside 'keep.txt') -Raw | Should -Be 'keep'
    }
}

Describe 'Exclusive deployment file creation' {
    It 'persists file ownership and verifies a completed copy' {
        $source = Join-Path $testDirectory 'copy-source.txt'
        $destination = Join-Path $testDirectory 'copy-result.txt'
        [IO.File]::WriteAllText($source, 'payload')
        $file = @{ Source = $source; Destination = $destination; SHA256 = (Get-FileHash -LiteralPath $source).Hash; Created = $false; MayBePartial = $false }
        $state = @{ Files = @($file) }
        $stateFile = Join-Path $testDirectory 'copy-state.json'
        Copy-NewDeploymentFile $file $state $stateFile
        $stored = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $stored.Files[0].Created | Should -BeTrue
        $stored.Files[0].MayBePartial | Should -BeFalse
        Get-Content -LiteralPath $destination -Raw | Should -Be 'payload'
    }

    It 'does not overwrite or claim a pre-existing destination' {
        $source = Join-Path $testDirectory 'existing-source.txt'
        $destination = Join-Path $testDirectory 'existing-result.txt'
        [IO.File]::WriteAllText($source, 'new')
        [IO.File]::WriteAllText($destination, 'existing')
        $file = @{ Source = $source; Destination = $destination; SHA256 = (Get-FileHash -LiteralPath $source).Hash; Created = $false; MayBePartial = $false }
        $state = @{ Files = @($file) }
        { Copy-NewDeploymentFile $file $state (Join-Path $testDirectory 'existing-state.json') } | Should -Throw
        $file.Created | Should -BeFalse
        Get-Content -LiteralPath $destination -Raw | Should -Be 'existing'
    }
}

Describe 'Registry journaling' {
    It 'restores existing values and removes newly created empty keys' {
        $entry = @{ Hive = 'CurrentUser'; View = 'Registry64'; Path = $registryPath + '\roundtrip'; Name = 'Value'; Value = 'old' }
        Set-RegistryEntry $entry
        $entry.Value = 'managed'
        $new = @{ Hive = 'CurrentUser'; View = 'Registry64'; Path = $registryPath + '\new\nested'; Name = ''; Value = 'managed' }
        $journal = Get-RegistryJournal @($entry, $new)
        Set-RegistryEntry $entry
        Set-RegistryEntry $new
        Restore-RegistryJournal $journal
        (Get-RegistryValueSnapshot $entry).Value | Should -Be 'old'
        $key = $registryBase.OpenSubKey($registryPath + '\new')
        $key | Should -BeNullOrEmpty
        if ($key) { $key.Dispose() }
    }

    It 'preserves an independent change made after installation' {
        $entry = @{ Hive = 'CurrentUser'; View = 'Registry64'; Path = $registryPath + '\independent'; Name = 'Value'; Value = 'managed' }
        $journal = Get-RegistryJournal @($entry)
        Set-RegistryEntry $entry
        $changed = @{} + $entry
        $changed.Value = 'user-change'
        Set-RegistryEntry $changed
        Restore-RegistryJournal $journal
        (Get-RegistryValueSnapshot $entry).Value | Should -Be 'user-change'
    }

    It 'survives a JSON persistence roundtrip' {
        $entry = @{ Hive = 'CurrentUser'; View = 'Registry64'; Path = $registryPath + '\json'; Name = ''; Value = 'managed' }
        $journal = Get-RegistryJournal @($entry)
        $file = Join-Path $testDirectory 'journal.json'
        Write-JsonFile $file $journal
        $restored = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
        Set-RegistryEntry $entry
        Restore-RegistryJournal $restored
        (Get-RegistryValueSnapshot $entry).Exists | Should -BeFalse
    }
}

Describe 'Release validation' {
    It 'rejects invalid versions before making requests' {
        Mock Invoke-RestMethod { throw 'Network should not be used' }
        { Get-TerminalRelease 'latest; command' } | Should -Throw '*four numeric*'
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'rejects a release asset from another repository' {
        $release = @{ assets = @(@{ name = 'test.zip'; browser_download_url = 'https://github.com/other/project/releases/download/v1/test.zip'; digest = 'sha256:' + ('0' * 64) }) }
        { Save-ReleaseAsset $release 'test.zip' (Join-Path $testDirectory 'bad.zip') } | Should -Throw '*origin*'
    }

    It 'rejects a downloaded payload with the wrong hash' {
        Mock Invoke-WebRequest { param($Uri, $OutFile) [IO.File]::WriteAllText($OutFile, 'invalid payload') }
        $release = @{ assets = @(@{ name = 'test.zip'; browser_download_url = 'https://github.com/microsoft/terminal/releases/download/v1/test.zip'; digest = 'sha256:' + ('0' * 64) }) }
        { Save-ReleaseAsset $release 'test.zip' (Join-Path $testDirectory 'bad.zip') } | Should -Throw '*checksum mismatch*'
    }
}
