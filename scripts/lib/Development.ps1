function Import-DevelopmentModule {
    param([Parameter(Mandatory)][string]$Name)
    $project = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $directory = Join-Path $project ('.tools\' + $Name)
    $manifest = if (Test-Path -LiteralPath $directory) {
        Get-ChildItem -LiteralPath $directory -Directory |
            Where-Object Name -match '^\d+(\.\d+){1,3}$' |
            Sort-Object { [version]$_.Name } -Descending |
            ForEach-Object { Join-Path $_.FullName ($Name + '.psd1') } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if ($manifest) { Import-Module $manifest -Force; return }
    $module = Get-Module -ListAvailable $Name | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module -or ($Name -eq 'Pester' -and $module.Version.Major -lt 5)) {
        throw "Install $Name in .tools or in the PowerShell module path; see README.md."
    }
    Import-Module $module.Path -Force
}
