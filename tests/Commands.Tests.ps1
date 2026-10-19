BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\Common.ps1')
    . (Join-Path $PSScriptRoot '..\scripts\lib\Terminal.ps1')
    $project = Split-Path $PSScriptRoot -Parent
}

Describe 'Public command boundaries' {
    BeforeEach {
        $testDirectory = Join-Path $env:TEMP ('windows-terminal-handoff-fix-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testDirectory | Out-Null
    }

    AfterEach {
        Remove-WorkDirectory $testDirectory $env:TEMP '^windows-terminal-handoff-fix-tests-[a-f0-9]{32}$'
    }

    It 'previews Terminal installation without creating files or requesting elevation' {
        & (Join-Path $project 'scripts\Manage-Terminal.ps1') -Action Install -InstallPath (Join-Path $testDirectory 'app') -StateRoot (Join-Path $testDirectory 'state') -WhatIf
        @(Get-ChildItem -LiteralPath $testDirectory -Force).Count | Should -Be 0
    }

    It 'previews mod installation without requiring a build or creating files' {
        & (Join-Path $project 'scripts\Manage-Mod.ps1') -Action Install -StateRoot (Join-Path $testDirectory 'state') -WhatIf
        @(Get-ChildItem -LiteralPath $testDirectory -Force).Count | Should -Be 0
    }

    It 'rejects overlapping installation and recovery directories' {
        { & (Join-Path $project 'scripts\Manage-Terminal.ps1') -Action Install -InstallPath $testDirectory -StateRoot (Join-Path $testDirectory 'state') -WhatIf } | Should -Throw '*must be separate*'
    }

    It 'does not adopt an existing installation directory' {
        Mock Get-TerminalRelease { throw 'Network should not be used' }
        { Install-TerminalDeployment -InstallPath $testDirectory -StateRoot (Join-Path $testDirectory 'state') } | Should -Throw '*already exists*'
        Should -Invoke Get-TerminalRelease -Times 0
    }
}
