function ConvertTo-BackupProxyUri {
    param([string]$Endpoint)

    if ([string]::IsNullOrWhiteSpace($Endpoint)) { return $null }
    $candidate = $Endpoint.Trim()
    if ($candidate -match '^[a-z][a-z0-9+.-]*://') { return $candidate }
    return "http://$candidate"
}

function Resolve-BackupProxySettings {
    param([string]$ProxyServer)

    if ([string]::IsNullOrWhiteSpace($ProxyServer)) { return $null }

    $raw = $ProxyServer.Trim()
    $byScheme = @{}
    foreach ($part in ($raw -split ';')) {
        if ($part -match '^\s*([^=]+)=(.+)$') {
            $byScheme[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
        }
    }

    if ($byScheme.Count -eq 0) {
        $httpEndpoint = $raw
        $httpsEndpoint = $raw
    } else {
        $httpEndpoint = $byScheme['http']
        $httpsEndpoint = $byScheme['https']
        if (-not $httpEndpoint) { $httpEndpoint = $httpsEndpoint }
        if (-not $httpsEndpoint) { $httpsEndpoint = $httpEndpoint }
    }

    [pscustomobject]@{
        Http  = ConvertTo-BackupProxyUri $httpEndpoint
        Https = ConvertTo-BackupProxyUri $httpsEndpoint
    }
}

function Initialize-BackupNetwork {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ProxyServerOverride
    )

    try {
        if ($PSBoundParameters.ContainsKey('ProxyServerOverride')) {
            $proxyServer = $ProxyServerOverride
            $source = 'override'
        } else {
            $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
            if ([int]$settings.ProxyEnable -ne 1) {
                return [pscustomobject]@{ Applied = $false; Source = 'direct'; Http = $null; Https = $null }
            }
            $proxyServer = [string]$settings.ProxyServer
            $source = 'windows_user_proxy'
        }

        $resolved = Resolve-BackupProxySettings $proxyServer
        if (-not $resolved) {
            return [pscustomobject]@{ Applied = $false; Source = 'unavailable'; Http = $null; Https = $null }
        }

        # Task Scheduler can retain stale process-level proxy variables. The current
        # user's live Windows proxy is the authority for scheduled Drive backups.
        foreach ($name in @('HTTP_PROXY', 'http_proxy')) {
            [Environment]::SetEnvironmentVariable($name, $resolved.Http, 'Process')
        }
        foreach ($name in @('HTTPS_PROXY', 'https_proxy')) {
            [Environment]::SetEnvironmentVariable($name, $resolved.Https, 'Process')
        }
        return [pscustomobject]@{ Applied = $true; Source = $source; Http = $resolved.Http; Https = $resolved.Https }
    } catch {
        return [pscustomobject]@{ Applied = $false; Source = 'unavailable'; Http = $null; Https = $null }
    }
}

function Get-RcloneFailureCategory {
    [CmdletBinding()]
    param([string[]]$Output)

    $message = ($Output -join "`n").ToLowerInvariant()
    if ($message -match 'proxyconnect|proxy connect|connection refused.*127\.0\.0\.1|connectex.*127\.0\.0\.1') {
        return 'proxy_connect'
    }
    if ($message -match 'context deadline exceeded|i/o timeout|timed out|timeout awaiting response') {
        return 'timeout'
    }
    if ($message -match 'invalid_grant|invalid credentials|oauth|token.*expired|unauthorized|401') {
        return 'oauth_auth'
    }
    if ($message -match 'rate.?limit|too many requests|quota exceeded|429') {
        return 'rate_limit'
    }
    if ($message -match 'accessnotconfigured|api.*not.*enabled|has not been used.*project') {
        return 'api_config'
    }
    if ($message -match 'forbidden|insufficient permission|permission denied|403') {
        return 'permission'
    }
    if ($message -match 'no such host|network is unreachable|connection reset|connection closed|tls handshake') {
        return 'network'
    }
    if ($message -match 'didn.t find section|failed to create file system|config file') {
        return 'config'
    }
    if ($message -match 'server returned|service unavailable|internal server error|bad gateway|502|503|504') {
        return 'remote_api'
    }
    return 'unknown'
}

function ConvertTo-RcloneSafeDiagnostic {
    [CmdletBinding()]
    param([string[]]$Output)

    $line = @(
        $Output |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notmatch '^\s*[\{\}\[\],]\s*$' -and
                $_ -match '(?i)error|failed|fatal|critical|warning|unknown|usage'
            } |
            Select-Object -Last 1
    )
    if ($line.Count -eq 0) {
        $line = @(
            $Output |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) -and
                    $_ -notmatch '^\s*[\{\}\[\],]\s*$'
                } |
                Select-Object -Last 1
        )
    }
    if ($line.Count -eq 0) { return 'no_output' }
    $safe = [string]$line[0]
    $safe = $safe -replace 'https?://\S+', '[url]'
    $safe = $safe -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '[account]'
    $safe = $safe -replace '(?i)(token|code|secret|state)=\S+', '$1=[redacted]'
    $safe = $safe -replace '(?i)\b[A-Za-z0-9_-]{24,}\b', '[redacted]'
    $safe = $safe -replace '(?i)\b[A-Z]:\\[^""\r\n]+', '[path]'
    if ($safe.Length -gt 240) { $safe = $safe.Substring(0, 240) }
    return $safe
}

function Invoke-RcloneDrivePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Remote,
        [ValidateRange(1, 10)]
        [int]$Attempts = 3,
        [ValidateRange(0, 300)]
        [int]$DelaySeconds = 5,
        [string]$ConnectTimeout = '20s',
        [string]$Timeout = '45s'
    )

    $rcloneCommand = Get-Command rclone -ErrorAction SilentlyContinue
    $rclonePath = if ($rcloneCommand) { [string]$rcloneCommand.Source } else { 'unavailable' }
    $configOutput = @(& rclone config file 2>&1 | ForEach-Object { $_.ToString() })
    $configPath = if ($LASTEXITCODE -eq 0 -and $configOutput.Count -gt 0) {
        [string]$configOutput[-1]
    } else {
        'unavailable'
    }

    $lastNativeExitCode = 1
    $lastCategory = 'unknown'
    $output = @()
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $output = @(& rclone about $Remote --json --contimeout $ConnectTimeout --timeout $Timeout `
            --retries 1 --low-level-retries 3 `
            --tpslimit 2 --tpslimit-burst 2 `
            --drive-pacer-min-sleep 1s --drive-pacer-burst 2 2>&1 |
            ForEach-Object { $_.ToString() })
        $lastNativeExitCode = $LASTEXITCODE
        if ($lastNativeExitCode -eq 0) {
            return [pscustomobject]@{
                Success  = $true
                Attempts = $attempt
                ExitCode = 0
                Category = 'none'
                Diagnostic = 'none'
                OutputLines = $output.Count
                RclonePath = $rclonePath
                ConfigPath = $configPath
            }
        }

        $lastCategory = Get-RcloneFailureCategory -Output $output
        if ($attempt -lt $Attempts -and $DelaySeconds -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return [pscustomobject]@{
        Success  = $false
        Attempts = $Attempts
        ExitCode = $lastNativeExitCode
        Category = $lastCategory
        Diagnostic = ConvertTo-RcloneSafeDiagnostic -Output $output
        OutputLines = $output.Count
        RclonePath = $rclonePath
        ConfigPath = $configPath
    }
}
