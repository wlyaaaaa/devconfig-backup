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

$oldHttpProxy = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Process')
$oldHttpsProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process')
try {
    [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://127.0.0.1:1', 'Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://127.0.0.1:1', 'Process')
    $initialized = Initialize-BackupNetwork -ProxyServerOverride '127.0.0.1:7892'
    if (-not $initialized.Applied -or $initialized.Source -ne 'override') {
        throw 'Scheduled backup proxy initialization did not report the override source.'
    }
    Assert-Equal $env:HTTP_PROXY 'http://127.0.0.1:7892' 'Stale HTTP proxy was not replaced.'
    Assert-Equal $env:HTTPS_PROXY 'http://127.0.0.1:7892' 'Stale HTTPS proxy was not replaced.'
}
finally {
    [Environment]::SetEnvironmentVariable('HTTP_PROXY', $oldHttpProxy, 'Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $oldHttpsProxy, 'Process')
    [Environment]::SetEnvironmentVariable('http_proxy', $oldHttpProxy, 'Process')
    [Environment]::SetEnvironmentVariable('https_proxy', $oldHttpsProxy, 'Process')
}

$categories = @{
    'proxyconnect tcp: dial tcp 127.0.0.1:7892: connectex' = 'proxy_connect'
    'context deadline exceeded'                            = 'timeout'
    'oauth2: cannot fetch token: 401 unauthorized'         = 'oauth_auth'
    'quota exceeded: rate limit 429'                       = 'rate_limit'
    'Google Drive API has not been used in project'        = 'api_config'
    'googleapi: Error 403: Forbidden'                      = 'permission'
    'dial tcp: no such host'                               = 'network'
    'didn''t find section in config file'                  = 'config'
    'server returned 503 service unavailable'              = 'remote_api'
    'unexpected failure'                                   = 'unknown'
}
foreach ($sample in $categories.Keys) {
    Assert-Equal (Get-RcloneFailureCategory -Output @($sample)) $categories[$sample] "Wrong rclone category for '$sample'."
}

$ordinary = 'Error: https://example.invalid/path?id=abcdefghijklmnopqrstuvwxyz&state=ready account@example.com C:\private\file.txt \\server\share\file.txt'
Assert-Equal (ConvertTo-RcloneSafeDiagnostic @($ordinary)) $ordinary 'Ordinary URLs, accounts, paths and long IDs must remain unchanged.'
$credentialCases = @(
    @('Error: password=synthetic-password account@example.com', 'Error: password=[redacted] account@example.com'),
    @('Error: passwd=''synthetic password'' C:\private\file.txt', 'Error: passwd=[redacted] C:\private\file.txt'),
    @('Error: {"refresh_token": "synthetic token", "client_id": "abcdefghijklmnopqrstuvwxyz"}', 'Error: {"refresh_token": [redacted], "client_id": "abcdefghijklmnopqrstuvwxyz"}'),
    @('Error: token=short; client_secret=synthetic-secret', 'Error: token=[redacted]; client_secret=[redacted]'),
    @('Error: API_KEY=synthetic-key, pwd=synthetic-pwd', 'Error: API_KEY=[redacted], pwd=[redacted]'),
    @('Error: Authorization: Bearer synthetic-bearer', 'Error: Authorization: [redacted]'),
    @('Error: Authorization=Basic c3ludGhldGljOnBhc3M=', 'Error: Authorization=[redacted]'),
    @('Error: {"Authorization": "Bearer synthetic-json"}', 'Error: {"Authorization": [redacted]}'),
    @('Error: Bearer synthetic-standalone', 'Error: Bearer [redacted]'),
    @('Error: https://user:synthetic-pass@example.invalid/file?id=ordinary', 'Error: https://user:[redacted]@example.invalid/file?id=ordinary'),
    @('Error: https://example.invalid/?access_token=synthetic-url&id=ordinary', 'Error: https://example.invalid/?access_token=[redacted]&id=ordinary'),
    @('Error: https://example.invalid/?access%5Ftoken=synthetic-encoded#part', 'Error: https://example.invalid/?access%5Ftoken=[redacted]#part'),
    @('Error: https://example.invalid/callback?code=synthetic-code&state=ready', 'Error: https://example.invalid/callback?code=[redacted]&state=ready'),
    @('Error: https://example.invalid/?X-Amz-Signature=synthetic-signature&file=ordinary', 'Error: https://example.invalid/?X-Amz-Signature=[redacted]&file=ordinary'),
    @('Error: https://user@example.invalid/?key=synthetic-api-key&page=2', 'Error: https://user@example.invalid/?key=[redacted]&page=2')
)
foreach ($case in $credentialCases) {
    Assert-Equal (ConvertTo-RcloneSafeDiagnostic @($case[0])) $case[1] 'Credentials must be hidden while surrounding ordinary content remains.'
}
Assert-Equal (ConvertTo-RcloneSafeDiagnostic @('Error: first', 'ordinary tail')) 'Error: first' 'Error selection must remain unchanged.'
Assert-Equal (ConvertTo-RcloneSafeDiagnostic @('', '{', ']')) 'no_output' 'Empty diagnostic behavior must remain unchanged.'
Assert-Equal (ConvertTo-RcloneSafeDiagnostic @('ordinary tail')) 'ordinary tail' 'Non-error fallback must remain unchanged.'
$longDiagnostic = 'Error: ' + ('ordinary-id-' * 30)
Assert-Equal (ConvertTo-RcloneSafeDiagnostic @($longDiagnostic)) $longDiagnostic.Substring(0, 240) 'Diagnostics must retain the 240-character limit.'

function global:rclone {
    param([Parameter(ValueFromRemainingArguments)][object[]]$CommandArguments)
    $global:LASTEXITCODE = 0
    if ($CommandArguments[0] -eq 'config') {
        'Configuration file is stored at:'
        'C:\synthetic\rclone.conf'
        return
    }
    '{"total":100,"used":1,"free":99}'
}
try {
    $syntheticPreflight = Invoke-RcloneDrivePreflight -Remote 'synthetic:' -Attempts 1 -DelaySeconds 0
    if (-not $syntheticPreflight.Success -or $syntheticPreflight.ExitCode -ne 0) {
        throw 'A successful native rclone exit must not be shadowed by a similarly named local variable.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\global:rclone -Force
}

$devConfig = Get-Content -LiteralPath (Join-Path $repoRoot 'Backup-DevConfig.ps1') -Raw
$weChat = Get-Content -LiteralPath (Join-Path $repoRoot 'Backup-WeChat.ps1') -Raw
foreach ($body in @($devConfig, $weChat)) {
    if ($body -notmatch "Initialize-BackupNetwork\.ps1") {
        throw 'Both scheduled Drive backup scripts must load the network helper.'
    }
}
if ($devConfig -notmatch '\$network\s*=\s*Initialize-BackupNetwork' -or
    $weChat -notmatch '\$null=Initialize-BackupNetwork') {
    throw 'Both scheduled Drive backup scripts must initialize the user proxy before rclone.'
}
if ($devConfig -notmatch 'Invoke-RcloneDrivePreflight') {
    throw 'DevConfig Drive backup must use the bounded preflight helper.'
}
if ($devConfig -notmatch 'tpslimit' -or
    (Get-Content -LiteralPath $helper -Raw) -notmatch 'rclone about') {
    throw 'DevConfig Drive API calls must use dedicated-client pacing and a metadata-only preflight.'
}

Write-Host 'PASS: scheduled Drive backups inherit the user proxy and classify bounded preflight failures.'

$oldHttp=$env:HTTP_PROXY;$oldHttps=$env:HTTPS_PROXY
try{
 $env:HTTP_PROXY='http://127.0.0.1:1';$env:HTTPS_PROXY='http://127.0.0.1:1'
 function Get-ItemProperty { [pscustomobject]@{ProxyEnable=0;ProxyServer='127.0.0.1:1'} }
 $state=Initialize-BackupNetwork
 if($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $state.Source-ne 'direct'){throw 'proxy_off_must_clear_stale_process_variables'}
}finally{Remove-Item Function:\Get-ItemProperty -ErrorAction SilentlyContinue;$env:HTTP_PROXY=$oldHttp;$env:HTTPS_PROXY=$oldHttps}
