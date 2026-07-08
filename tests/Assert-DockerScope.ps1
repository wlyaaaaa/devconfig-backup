param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-Text {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "Assertion failed: $Name" }
    Write-Host "PASS: $Name"
}

$sources = Join-Path $RepoRoot 'sources.psd1'
$script = Join-Path $RepoRoot 'Backup-DevConfig.ps1'

$cfg = Import-PowerShellDataFile -LiteralPath $sources
$scriptText = Get-Content -LiteralPath $script -Raw -Encoding utf8

Assert-Text 'HomeDirs does not copy entire .docker tree' ('.docker' -notin @($cfg.HomeDirs))
Assert-Text 'AppDataRoamingDirs does not copy entire Docker tree' ('Docker' -notin @($cfg.AppDataRoamingDirs))
Assert-Text 'AppDataRoamingDirs does not copy entire Docker Desktop tree' ('Docker Desktop' -notin @($cfg.AppDataRoamingDirs))

Assert-Text 'Docker CLI config is allowlisted' ('.docker\config.json' -in @($cfg.HomePreciseFiles))
Assert-Text 'Docker Linux daemon config is allowlisted' ('.docker\daemon.json' -in @($cfg.HomePreciseFiles))
Assert-Text 'Docker Windows daemon config is allowlisted' ('.docker\windows-daemon.json' -in @($cfg.HomePreciseFiles))
Assert-Text 'Docker contexts are allowlisted' ('.docker\contexts' -in @($cfg.HomePreciseDirs))

Assert-Text 'Docker Desktop settings-store is allowlisted' ('Docker\settings-store.json' -in @($cfg.AppDataRoamingFiles))
Assert-Text 'Docker login metadata is not allowlisted' (-not (@($cfg.AppDataRoamingFiles) -match 'login|auth-token'))
Assert-Text 'Docker browser local storage is not allowlisted' (-not (@($cfg.AppDataRoamingFiles) -match 'Local Storage|session\.db|leveldb'))

Assert-Text 'Backup script preserves precise relative files' ($scriptText -match 'function\s+Copy-RelativeFile')
Assert-Text 'Backup script preserves precise relative directories' ($scriptText -match 'function\s+Copy-RelativeDir')
