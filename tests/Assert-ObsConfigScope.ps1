$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$cfg = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'sources.psd1')

function Assert-True([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}

$dirs = @($cfg.AppDataRoamingDirs)
$files = @($cfg.AppDataRoamingFiles)
$obsDirs = @($dirs | Where-Object { $_ -like 'obs-studio*' })
$obsFiles = @($files | Where-Object { $_ -like 'obs-studio*' })

Assert-True 'OBS root is not copied wholesale' ('obs-studio' -notin $dirs)
Assert-True 'OBS basic config is allowlisted' ('obs-studio\basic' -in $dirs)
Assert-True 'OBS plugin config is allowlisted' ('obs-studio\plugin_config' -in $dirs)
Assert-True 'OBS global.ini is allowlisted' ('obs-studio\global.ini' -in $files)
Assert-True 'OBS user.ini is allowlisted' ('obs-studio\user.ini' -in $files)
Assert-True 'OBS volatile directories are excluded from the allowlist' (-not (@($obsDirs) -match '(?i)\\(logs|crashes|profiler_data|updates)(\\|$)'))
Assert-True 'OBS selected paths do not include recording/video roots' (-not (@($obsDirs + $obsFiles) -match '(?i)(videos|recordings?)'))