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
    param()

    $hasHttpProxy = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Process') -or
                    [Environment]::GetEnvironmentVariable('http_proxy', 'Process')
    $hasHttpsProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process') -or
                     [Environment]::GetEnvironmentVariable('https_proxy', 'Process')
    if ($hasHttpProxy -and $hasHttpsProxy) { return $false }

    try {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$settings.ProxyEnable -ne 1) { return $false }
        $resolved = Resolve-BackupProxySettings ([string]$settings.ProxyServer)
        if (-not $resolved) { return $false }

        if (-not $hasHttpProxy -and $resolved.Http) {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', $resolved.Http, 'Process')
            [Environment]::SetEnvironmentVariable('http_proxy', $resolved.Http, 'Process')
        }
        if (-not $hasHttpsProxy -and $resolved.Https) {
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $resolved.Https, 'Process')
            [Environment]::SetEnvironmentVariable('https_proxy', $resolved.Https, 'Process')
        }
        return $true
    } catch {
        return $false
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

function Invoke-RcloneDrivePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Remote,
        [ValidateRange(1, 10)]
        [int]$Attempts = 5,
        [ValidateRange(0, 300)]
        [int]$DelaySeconds = 15,
        [string]$ConnectTimeout = '20s',
        [string]$Timeout = '60s'
    )

    $lastExitCode = 1
    $lastCategory = 'unknown'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $output = @(& rclone lsd $Remote --max-depth 1 --contimeout $ConnectTimeout --timeout $Timeout `
            --retries 1 --low-level-retries 3 `
            --tpslimit 0.5 --tpslimit-burst 1 `
            --drive-pacer-min-sleep 2s --drive-pacer-burst 1 2>&1 |
            ForEach-Object { $_.ToString() })
        $lastExitCode = $LASTEXITCODE
        if ($lastExitCode -eq 0) {
            return [pscustomobject]@{
                Success  = $true
                Attempts = $attempt
                ExitCode = 0
                Category = 'none'
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
        ExitCode = $lastExitCode
        Category = $lastCategory
    }
}
