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

function Normalize-ConfiguredRcloneRemote {
    param([string] $Remote)

    $normalized = if ($null -eq $Remote) { '' } else { $Remote.Trim() }
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
    if (-not $normalized.EndsWith(':')) { $normalized += ':' }
    return $normalized
}

function Get-RcloneRemoteBinding {
    [CmdletBinding()]
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $binding = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $expected = @('schema', 'remote')
        $actual = @($binding.PSObject.Properties | ForEach-Object { $_.Name })
        if (@(Compare-Object -ReferenceObject $expected -DifferenceObject $actual).Count -ne 0 -or
            [string]$binding.schema -cne 'devconfig-backup.rclone-remote-binding.v1') {
            return $null
        }
        $remote = Normalize-ConfiguredRcloneRemote -Remote ([string]$binding.remote)
        if ($null -eq $remote) { return $null }
        return [pscustomobject]@{ Remote = $remote; Source = 'local_binding' }
    } catch {
        return $null
    }
}

function Set-RcloneRemoteBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Remote
    )

    $normalized = Normalize-ConfiguredRcloneRemote -Remote $Remote
    if ($null -eq $normalized) { throw 'rclone_remote_binding_invalid' }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    [pscustomobject]@{
        schema = 'devconfig-backup.rclone-remote-binding.v1'
        remote = $normalized
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
}

function Copy-RcloneRemoteBindingToManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BindingPath,
        [Parameter(Mandatory)] [string] $ManifestDirectory
    )

    $binding = Get-RcloneRemoteBinding -Path $BindingPath
    if ($null -eq $binding) { return $false }
    New-Item -ItemType Directory -Path $ManifestDirectory -Force -ErrorAction Stop | Out-Null
    $destination = Join-Path $ManifestDirectory 'rclone-remote-binding.json'
    Copy-Item -LiteralPath $BindingPath -Destination $destination -Force -ErrorAction Stop
    if ($null -eq (Get-RcloneRemoteBinding -Path $destination)) {
        throw 'rclone_remote_binding_manifest_copy_invalid'
    }
    return $true
}

function Resolve-ConfiguredRcloneRemote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Remote,
        [bool] $RemoteWasExplicit = $false,
        [string] $BindingPath = '',
        [string] $LiteralDefault = 'gdrive:'
    )

    $requested = $null
    $source = $null
    if ($RemoteWasExplicit) {
        $requested = Normalize-ConfiguredRcloneRemote -Remote $Remote
        $source = 'explicit_parameter'
        if ($null -eq $requested) {
            return [pscustomobject]@{ Success = $false; Remote = $null; Reason = 'explicit_remote_missing'; Source = $source }
        }
    } else {
        $binding = Get-RcloneRemoteBinding -Path $BindingPath
        if ($null -ne $binding) {
            $requested = $binding.Remote
            $source = $binding.Source
        } else {
            $requested = Normalize-ConfiguredRcloneRemote -Remote $LiteralDefault
            $source = 'literal_default'
        }
    }

    $configured = @(& rclone listremotes 2>&1 | ForEach-Object { $_.ToString().Trim() })
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Success = $false; Remote = $requested; Reason = 'remote_inventory_failed'; Source = $source }
    }
    if ($configured -notcontains $requested) {
        $reason = if ($source -eq 'local_binding') { 'bound_remote_not_found' } else { 'configured_remote_not_found' }
        return [pscustomobject]@{ Success = $false; Remote = $requested; Reason = $reason; Source = $source }
    }
    return [pscustomobject]@{ Success = $true; Remote = $requested; Reason = 'configured_remote_verified'; Source = $source }
}

function Test-RcloneRemoteFileMatchesLocal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LocalPath,
        [Parameter(Mandatory)] [string] $RemotePath
    )

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        return [pscustomobject]@{ Matches = $false; Reason = 'local_file_missing'; ExitCode = -1 }
    }
    # check compares directory trees; lsjson --stat addresses one exact object,
    # including a dated remote name whose local source is latest.zip.
    try {
        $metadata = @(& rclone lsjson $RemotePath --stat --hash --hash-type MD5 `
            --contimeout 15s --timeout 30s --retries 2 --low-level-retries 4 2>$null)
        $exitCode = $LASTEXITCODE
    } catch {
        return [pscustomobject]@{ Matches = $false; Reason = 'remote_object_query_failed'; ExitCode = -1 }
    }
    if ($exitCode -ne 0) {
        return [pscustomobject]@{ Matches = $false; Reason = 'remote_object_query_failed'; ExitCode = $exitCode }
    }
    try {
        $remote = ($metadata -join "`n") | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $remote -or $remote.IsDir -ne $false -or
            $null -eq $remote.PSObject.Properties['Size'] -or
            $null -eq $remote.PSObject.Properties['Hashes'] -or
            $null -eq $remote.Hashes.PSObject.Properties['md5'] -or
            [string]$remote.Hashes.md5 -notmatch '^[a-fA-F0-9]{32}$') {
            throw 'remote_object_hash_unavailable'
        }
        $before = Get-Item -LiteralPath $LocalPath -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $LocalPath -Algorithm MD5 -ErrorAction Stop).Hash
        $after = Get-Item -LiteralPath $LocalPath -ErrorAction Stop
        $sameObject = [long]$remote.Size -eq $after.Length -and
            $before.Length -eq $after.Length -and
            $before.LastWriteTimeUtc.Ticks -eq $after.LastWriteTimeUtc.Ticks -and
            [string]::Equals($hash, [string]$remote.Hashes.md5, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return [pscustomobject]@{ Matches = $false; Reason = 'remote_object_hash_unavailable'; ExitCode = $exitCode }
    }
    return [pscustomobject]@{
        Matches = $sameObject
        Reason = if ($sameObject) { 'remote_object_matches' } else { 'remote_object_missing_or_mismatch' }
        ExitCode = $exitCode
    }
}

function Get-DrivePackageSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$StateDir)
    $recordPath = Join-Path $StateDir 'latest.sha256'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw 'local_snapshot_manifest_missing' }
    $record = (Get-Content -LiteralPath $recordPath -Raw -Encoding ASCII).Trim()
    if ($record -notmatch '^([a-fA-F0-9]{64})\s+(devconfig-[0-9-]+\.zip)$') { throw 'local_snapshot_manifest_invalid' }
    $expectedHash = $Matches[1]
    $name = $Matches[2]
    $zip = Join-Path $OutDir $name
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw 'local_snapshot_file_missing' }
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($hash -ine $expectedHash) { throw 'local_snapshot_hash_mismatch' }
    [pscustomobject]@{ Zip = $zip; Sha = $hash; Name = $name; MB = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 2) }
}

function Get-DriveUploadState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $expected = @('schema', 'sha256', 'remote', 'folder', 'dated_name', 'latest_name')
        $actual = @($state.PSObject.Properties | ForEach-Object { $_.Name })
        if (@(Compare-Object -ReferenceObject $expected -DifferenceObject $actual).Count -ne 0) { return $null }
        if ([string]$state.schema -cne 'devconfig.drive-upload-state.v1') { return $null }
        return $state
    } catch {
        return $null
    }
}

function New-DriveUploadState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Sha256,
        [Parameter(Mandatory)] [string] $Remote,
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $DatedName,
        [string] $LatestName = 'latest.zip'
    )

    return [pscustomobject]@{
        schema = 'devconfig.drive-upload-state.v1'
        sha256 = $Sha256
        remote = $Remote
        folder = $Folder
        dated_name = $DatedName
        latest_name = $LatestName
    }
}

function Test-DriveUploadStateMatches {
    [CmdletBinding()]
    param(
        $State,
        [Parameter(Mandatory)] [string] $Sha256,
        [Parameter(Mandatory)] [string] $Remote,
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $DatedName,
        [string] $LatestName = 'latest.zip'
    )

    if ($null -eq $State) { return $false }
    return [string]$State.schema -ceq 'devconfig.drive-upload-state.v1' -and
        [string]$State.sha256 -ceq $Sha256 -and
        [string]$State.remote -ceq $Remote -and
        [string]$State.folder -ceq $Folder -and
        [string]$State.dated_name -ceq $DatedName -and
        [string]$State.latest_name -ceq $LatestName
}

function Test-DriveUploadSkipEligibility {
    [CmdletBinding()]
    param(
        $State,
        [Parameter(Mandatory)] [string] $Sha256,
        [Parameter(Mandatory)] [string] $Remote,
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $DatedName,
        [Parameter(Mandatory)] [string] $DatedLocalPath,
        [Parameter(Mandatory)] [string] $LatestLocalPath,
        [string] $LatestName = 'latest.zip'
    )

    if (-not (Test-DriveUploadStateMatches -State $State -Sha256 $Sha256 -Remote $Remote -Folder $Folder -DatedName $DatedName -LatestName $LatestName)) {
        return [pscustomobject]@{ Eligible = $false; Reason = 'state_destination_binding_mismatch' }
    }

    $destination = $Remote + $Folder.Trim('/').Trim('\')
    $dated = Test-RcloneRemoteFileMatchesLocal -LocalPath $DatedLocalPath -RemotePath ($destination + '/' + $DatedName)
    if (-not $dated.Matches) {
        return [pscustomobject]@{ Eligible = $false; Reason = $dated.Reason }
    }
    $latest = Test-RcloneRemoteFileMatchesLocal -LocalPath $LatestLocalPath -RemotePath ($destination + '/' + $LatestName)
    if (-not $latest.Matches) {
        return [pscustomobject]@{ Eligible = $false; Reason = $latest.Reason }
    }
    return [pscustomobject]@{ Eligible = $true; Reason = 'destination_verified' }
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
