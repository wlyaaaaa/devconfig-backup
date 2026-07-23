$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$helper = Join-Path $repoRoot 'Initialize-BackupNetwork.ps1'

. $helper

function Assert-Equal {
    param(
        [string]$Actual,
        [string]$Expected,
        [string]$Message
    )
    if ($Actual -cne $Expected) {
        throw "$Message (actual='$Actual', expected='$Expected')"
    }
}

$single = Resolve-BackupProxySettings '127.0.0.1:7892'
Assert-Equal $single.Http 'http://127.0.0.1:7892' 'Single proxy endpoint must cover HTTP.'
Assert-Equal $single.Https 'http://127.0.0.1:7892' 'Single proxy endpoint must cover HTTPS.'

$split = Resolve-BackupProxySettings 'http=127.0.0.1:8080;https=127.0.0.1:8443'
Assert-Equal $split.Http 'http://127.0.0.1:8080' 'HTTP proxy mapping is wrong.'
Assert-Equal $split.Https 'http://127.0.0.1:8443' 'HTTPS proxy mapping is wrong.'

$devConfig = Get-Content -LiteralPath (Join-Path $repoRoot 'Backup-DevConfig.ps1') -Raw
$weChat = Get-Content -LiteralPath (Join-Path $repoRoot 'Backup-WeChat.ps1') -Raw
foreach ($body in @($devConfig, $weChat)) {
    if ($body -notmatch "Initialize-BackupNetwork\.ps1" -or
        $body -notmatch 'Initialize-BackupNetwork \| Out-Null') {
        throw 'Both scheduled Drive backup scripts must initialize the user proxy before rclone.'
    }
}

Write-Host 'PASS: scheduled Drive backups inherit the enabled user proxy without hard-coded endpoints.'
