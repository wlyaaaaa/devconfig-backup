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

. (Join-Path $RepoRoot 'Backup.Common.ps1')
. (Join-Path $RepoRoot 'DevConfig.Sources.ps1')
$fixtureParent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixturePath=Join-Path $fixtureParent ('docker-scope-'+[guid]::NewGuid().ToString('N'))
try {
 [void][IO.Directory]::CreateDirectory((Join-Path $fixturePath '.docker/contexts/test'))
 [IO.File]::WriteAllText((Join-Path $fixturePath '.docker/config.json'),'synthetic')
 [IO.File]::WriteAllText((Join-Path $fixturePath '.docker/contexts/test/one.txt'),'synthetic')
 $plan=Get-DevConfigSourceInventory @{HomePreciseFiles=@('.docker/config.json');HomePreciseDirs=@('.docker/contexts')} $fixturePath
 Assert-Text 'precise file keeps nested relative layout' ('home/.docker/config.json' -in $plan.files.relative_path)
 Assert-Text 'precise directory keeps nested relative layout' ('home/.docker/contexts/test/one.txt' -in $plan.files.relative_path)
} finally { Remove-BackupOwnedDirectory $fixturePath $fixtureParent '^docker-scope-[a-f0-9]{32}$' }
