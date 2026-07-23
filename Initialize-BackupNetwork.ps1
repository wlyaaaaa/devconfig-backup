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
