BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\Common.ps1')
    . (Join-Path $PSScriptRoot '..\scripts\lib\Terminal.ps1')
}

Describe 'Terminal registration plan' {
    It 'registers the x86 proxy separately from the x64 proxy' {
        $entries = @(Get-TerminalRegistryEntry 'C:\Applications\Terminal\app')
        $x86 = $entries | Where-Object { $_.View -eq 'Registry32' -and $_.Path -like '*InprocServer32' -and $_.Name -eq '' }
        $x64 = $entries | Where-Object { $_.View -eq 'Registry64' -and $_.Path -like '*InprocServer32' -and $_.Name -eq '' }
        $x86.Value | Should -Be 'C:\Applications\Terminal\app\x86\OpenConsoleProxy.dll'
        $x64.Value | Should -Be 'C:\Applications\Terminal\app\OpenConsoleProxy.dll'
    }

    It 'keeps root-directory context-menu arguments quoted and non-ambiguous' {
        $entries = @(Get-TerminalRegistryEntry 'C:\Apps With Spaces\Terminal\app' -ContextMenu)
        $drive = $entries | Where-Object Path -eq 'SOFTWARE\Classes\Drive\shell\WindowsTerminalHandoffFix\command'
        $drive.Value | Should -Be '"C:\Apps With Spaces\Terminal\app\wt.exe" -d "%1\."'
    }
}

Describe 'Update transactions' {
    BeforeEach {
        $testDirectory = Join-Path $env:TEMP ('windows-terminal-handoff-fix-tests-' + [guid]::NewGuid().ToString('N'))
        $install = Join-Path $testDirectory 'installation'
        $data = Join-Path $testDirectory 'state'
        New-Item -ItemType Directory -Path (Join-Path $install 'app'), $data | Out-Null
        [IO.File]::WriteAllText((Join-Path $install 'app\payload.txt'), 'original')
        Write-JsonFile (Join-Path $install '.windows-terminal-handoff-fix.json') @{ InstallationId = 'test' }
        $state = @{ InstallPath = $install; InstallationId = 'test'; Version = '1.0.0.0' }
        Mock Assert-TerminalClosed {}
        Mock Get-TerminalRelease { @{ tag_name = 'v2.0.0.0' } }
    }

    AfterEach {
        Remove-WorkDirectory $testDirectory $env:TEMP '^windows-terminal-handoff-fix-tests-[a-f0-9]{32}$'
    }

    It 'keeps the installed application intact when download or extraction fails' {
        Mock Expand-TerminalRelease { throw 'Download failed' }
        { Update-TerminalDeployment $state $data } | Should -Throw '*Download failed*'
        Get-Content -LiteralPath (Join-Path $install 'app\payload.txt') -Raw | Should -Be 'original'
        @(Get-ChildItem -LiteralPath $data -Directory -Filter 'work-*').Count | Should -Be 0
    }

    It 'does not create another work directory when an earlier update needs recovery' {
        New-Item -ItemType Directory -Path (Join-Path $install 'pending-app') | Out-Null
        { Update-TerminalDeployment $state $data } | Should -Throw '*needs recovery*'
        @(Get-ChildItem -LiteralPath $data -Directory -Filter 'work-*').Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $install 'app\payload.txt') -Raw | Should -Be 'original'
    }

    It 'restores the original application when registration fails after the swap' {
        Mock Expand-TerminalRelease {
            param($Release, $WorkDirectory)
            $new = Join-Path $WorkDirectory 'new'
            New-Item -ItemType Directory -Path $new | Out-Null
            [IO.File]::WriteAllText((Join-Path $new 'payload.txt'), 'updated')
            return $new
        }
        $script:registrationCalls = 0
        Mock Set-TerminalRegistration {
            $script:registrationCalls++
            if ($script:registrationCalls -eq 1) { throw 'Registration failed' }
        }
        { Update-TerminalDeployment $state $data } | Should -Throw '*Registration failed*'
        Get-Content -LiteralPath (Join-Path $install 'app\payload.txt') -Raw | Should -Be 'original'
        $state.Version | Should -Be '1.0.0.0'
        Test-Path -LiteralPath (Join-Path $install 'previous-app') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $install 'pending-app') | Should -BeFalse
    }
}
