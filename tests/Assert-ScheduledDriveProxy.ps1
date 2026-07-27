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

$categories = @{
    'proxyconnect tcp: dial tcp 127.0.0.1:7892: connectex' = 'proxy_connect'
    'context deadline exceeded'                            = 'timeout'
    'oauth2: cannot fetch token: 401 unauthorized'         = 'oauth_auth'
    'quota exceeded: rate limit 429'                       = 'rate_limit'
    'dial tcp: no such host'                               = 'network'
    'didn''t find section in config file'                  = 'config'
    'server returned 503 service unavailable'              = 'remote_api'
    'unexpected failure'                                   = 'unknown'
}
foreach ($sample in $categories.Keys) {
    Assert-Equal (Get-RcloneFailureCategory -Output @($sample)) $categories[$sample] "Wrong rclone category for '$sample'."
}

$devConfig = Get-Content -LiteralPath (Join-Path $repoRoot 'Backup-DevConfig.ps1') -Raw
$weChat = Get-Content -LiteralPath (Join-Path $repoRoot 'Backup-WeChat.ps1') -Raw
foreach ($body in @($devConfig, $weChat)) {
    if ($body -notmatch "Initialize-BackupNetwork\.ps1" -or
        $body -notmatch 'Initialize-BackupNetwork \| Out-Null') {
        throw 'Both scheduled Drive backup scripts must initialize the user proxy before rclone.'
    }
}
if ($devConfig -notmatch 'Invoke-RcloneDrivePreflight') {
    throw 'DevConfig Drive backup must use the bounded preflight helper.'
}
if ($devConfig -notmatch '--tpslimit 1' -or
    (Get-Content -LiteralPath $helper -Raw) -notmatch '--tpslimit 0\.5') {
    throw 'DevConfig Drive API calls must be paced for the shared rclone client quota.'
}

Write-Host 'PASS: scheduled Drive backups inherit the user proxy and classify bounded preflight failures.'
