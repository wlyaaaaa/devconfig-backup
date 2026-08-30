[CmdletBinding()]
param(
    [string] $RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-PathWithinFixtureNamespace {
    param([string] $Path, [string] $NamespaceRoot)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@([char]'\', [char]'/' ))
    $fullRoot = [IO.Path]::GetFullPath($NamespaceRoot).TrimEnd([char[]]@([char]'\', [char]'/' ))
    if (-not $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Cloud fixture cleanup path escapes its namespace: $fullPath"
    }
    return $fullPath
}

$networkHelper = Join-Path $RepoRoot 'Initialize-BackupNetwork.ps1'
$readme = Get-Content -LiteralPath (Join-Path $RepoRoot 'README.md') -Raw
$devConfig = Get-Content -LiteralPath (Join-Path $RepoRoot 'Backup-DevConfig.ps1') -Raw
$weChat = Get-Content -LiteralPath (Join-Path $RepoRoot 'Backup-WeChat.ps1') -Raw
$restore = Get-Content -LiteralPath (Join-Path $RepoRoot 'Restore-WeChat.ps1') -Raw
$status = Get-Content -LiteralPath (Join-Path $RepoRoot 'Backup-Status.ps1') -Raw
$monitor = Get-Content -LiteralPath (Join-Path $RepoRoot 'Monitor-WeChatDrive.ps1') -Raw

Assert-Condition ($devConfig -match 'Resolve-ConfiguredRcloneRemote' -and $devConfig -match 'Copy-RcloneRemoteBindingToManifest' -and $devConfig -match 'rclone-remote-binding\.json' -and $devConfig -match 'last-uploaded\.json' -and $devConfig -match 'Test-DriveUploadSkipEligibility') 'DevConfig Drive upload must use explicit remote and destination-bound state.'
Assert-Condition ($weChat -match 'Resolve-ConfiguredRcloneRemote' -and $weChat -match 'rclone-remote-binding\.json' -and $weChat -notmatch 'remotes\[0\]') 'WeChat Drive backup must refuse a missing configured remote without fallback.'
Assert-Condition ($restore -match 'Resolve-ConfiguredRcloneRemote' -and $restore -match 'rclone-remote-binding\.json' -and $restore -notmatch 'Resolve-ExistingWeChatDriveRemote') 'WeChat Drive restore must refuse a missing configured remote without fallback.'
Assert-Condition ($status -match 'Resolve-ConfiguredRcloneRemote' -and $status -match 'rclone-remote-binding\.json' -and $status -notmatch 'listremotes 2>\$null \| Select-Object -First 1') 'Backup status must use the selected remote instead of the first remote.'
Assert-Condition ($monitor -match 'Resolve-ConfiguredRcloneRemote' -and $monitor -match 'rclone-remote-binding\.json' -and $monitor -notmatch 'remotes\[0\]') 'WeChat Drive monitor must use the selected remote instead of the first remote.'
Assert-Condition ($weChat -notmatch '\*\.db-wal|\*\.db-shm|\*\.db-journal') 'WeChat Drive backup must retain SQLite companion files.'
Assert-Condition ($restore -notmatch '\*\.db-wal|\*\.db-shm|\*\.db-journal') 'WeChat Drive restore must retain SQLite companion files.'
Assert-Condition ($monitor -notmatch '\*\.db-wal|\*\.db-shm|\*\.db-journal') 'WeChat Drive monitor must retain SQLite companion files in its size and check scope.'
Assert-Condition ($readme -match '_manifests\\rclone-remote-binding\.json' -and $readme -match 'E:\\Projects\\Backups\\devconfig-backup\\state\\rclone-remote-binding\.json') 'README must document restoring the one nonsecret binding to its fixed local path.'

. $networkHelper

$realRclone = Get-Command rclone -CommandType Application -ErrorAction SilentlyContinue
$global:CloudIntegrityRemotes = @('selected:', 'other:')
$global:CloudIntegrityInventoryFailure = $false
$global:CloudIntegrityMissingRemotePaths = @()
$global:CloudIntegrityRcloneCalls = New-Object System.Collections.ArrayList
function global:rclone {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]] $RcloneArguments)
    $verb = [string]$RcloneArguments[0]
    [void]$global:CloudIntegrityRcloneCalls.Add(($RcloneArguments -join '|'))
    if ($verb -eq 'listremotes') {
        if ($global:CloudIntegrityInventoryFailure) {
            $global:LASTEXITCODE = 1
            'synthetic inventory failure'
            return
        }
        $global:LASTEXITCODE = 0
        $global:CloudIntegrityRemotes
        return
    }
    if ($verb -eq 'lsjson') {
        $remotePath = [string]$RcloneArguments[1]
        $global:LASTEXITCODE = if ($global:CloudIntegrityMissingRemotePaths -contains $remotePath) { 1 } else { 0 }
        if ($global:LASTEXITCODE -eq 0) {
            $local = if ($remotePath.EndsWith('/latest.zip')) { $latestLocal } else { $datedLocal }
            [pscustomobject]@{ IsDir = $false; Size = (Get-Item -LiteralPath $local).Length; Hashes = @{ md5 = (Get-FileHash -LiteralPath $local -Algorithm MD5).Hash } } | ConvertTo-Json -Compress
        }
        return
    }
    $global:LASTEXITCODE = 0
}

$fixtureBase = Join-Path $env:TEMP 'Codex'
$fixtureRoot = Join-Path $fixtureBase ('cloud-backup-integrity-' + [guid]::NewGuid().ToString('N'))
try {
    $bindingPath = Join-Path $fixtureRoot 'rclone-remote-binding.json'
    $selected = Resolve-ConfiguredRcloneRemote -Remote 'selected:' -RemoteWasExplicit $true
    Assert-Condition ($selected.Success -and $selected.Remote -eq 'selected:' -and $selected.Source -eq 'explicit_parameter') 'Explicit configured remote should resolve exactly when present.'
    Set-RcloneRemoteBinding -Path $bindingPath -Remote 'selected:'
    $bound = Resolve-ConfiguredRcloneRemote -Remote 'gdrive:' -BindingPath $bindingPath
    Assert-Condition ($bound.Success -and $bound.Remote -eq 'selected:' -and $bound.Source -eq 'local_binding') 'Local remote binding must take precedence over the literal default.'
    $invalidBindingPath = Join-Path $fixtureRoot 'invalid-rclone-remote-binding.json'
    Set-Content -LiteralPath $invalidBindingPath -Value '{"schema":"truncated"' -Encoding UTF8
    $global:CloudIntegrityRcloneCalls.Clear()
    $invalidBinding = Resolve-ConfiguredRcloneRemote -Remote 'gdrive:' -BindingPath $invalidBindingPath
    Assert-Condition (-not $invalidBinding.Success -and $null -eq $invalidBinding.Remote -and $invalidBinding.Reason -eq 'local_binding_invalid' -and $invalidBinding.Source -eq 'local_binding') 'An existing invalid remote binding must fail closed instead of switching to the literal default.'
    Assert-Condition ($global:CloudIntegrityRcloneCalls.Count -eq 0) 'An invalid local binding must be rejected before remote inventory or any cloud operation.'
    $missing = Resolve-ConfiguredRcloneRemote -Remote 'missing:' -RemoteWasExplicit $true
    Assert-Condition (-not $missing.Success -and $missing.Remote -eq 'missing:' -and $missing.Reason -eq 'configured_remote_not_found') 'Missing configured remote must fail instead of falling back to another remote.'

    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    $datedLocal = Join-Path $fixtureRoot 'devconfig-20260827.zip'
    $latestLocal = Join-Path $fixtureRoot 'latest.zip'
    [IO.File]::WriteAllText($datedLocal, 'synthetic dated package')
    [IO.File]::WriteAllText($latestLocal, 'synthetic latest package')
    $snapshotState = Join-Path $fixtureRoot 'snapshot-state'
    New-Item -ItemType Directory -Path $snapshotState | Out-Null
    $datedHash = (Get-FileHash -LiteralPath $datedLocal -Algorithm SHA256).Hash
    [IO.File]::WriteAllText((Join-Path $snapshotState 'latest.sha256'), "$datedHash  devconfig-20260827.zip")
    $snapshot = Get-DrivePackageSnapshot -OutDir $fixtureRoot -StateDir $snapshotState
    Assert-Condition ($snapshot.Zip -eq $datedLocal -and $snapshot.Sha -eq $datedHash) 'Drive must freeze the validated dated package, not the mutable latest.zip pointer.'
    [IO.File]::WriteAllText((Join-Path $snapshotState 'latest.sha256'), (('0' * 64) + '  devconfig-20260827.zip'))
    $badSnapshotRejected = $false
    try { Get-DrivePackageSnapshot -OutDir $fixtureRoot -StateDir $snapshotState | Out-Null } catch { $badSnapshotRejected = $true }
    Assert-Condition $badSnapshotRejected 'A mismatched snapshot record must not be uploaded under the wrong dated name.'
    $state = New-DriveUploadState -Sha256 'abc123' -Remote 'selected:' -Folder 'Backups/Host' -DatedName 'devconfig-20260827.zip'

    $eligible = Test-DriveUploadSkipEligibility -State $state -Sha256 'abc123' -Remote 'selected:' -Folder 'Backups/Host' `
        -DatedName 'devconfig-20260827.zip' -DatedLocalPath $datedLocal -LatestLocalPath $latestLocal
    Assert-Condition $eligible.Eligible 'A matching destination state and both remote objects should be eligible to skip.'

    $global:CloudIntegrityRcloneCalls.Clear()
    $changedDestination = Test-DriveUploadSkipEligibility -State $state -Sha256 'abc123' -Remote 'selected:' -Folder 'Backups/AnotherHost' `
        -DatedName 'devconfig-20260827.zip' -DatedLocalPath $datedLocal -LatestLocalPath $latestLocal
    Assert-Condition (-not $changedDestination.Eligible -and $changedDestination.Reason -eq 'state_destination_binding_mismatch') 'Changing the destination must invalidate the upload cache.'
    Assert-Condition ($global:CloudIntegrityRcloneCalls.Count -eq 0) 'Destination mismatch must not claim remote verification or skip.'

    $global:CloudIntegrityMissingRemotePaths = @('selected:Backups/Host/latest.zip')
    $missingCachedObject = Test-DriveUploadSkipEligibility -State $state -Sha256 'abc123' -Remote 'selected:' -Folder 'Backups/Host' `
        -DatedName 'devconfig-20260827.zip' -DatedLocalPath $datedLocal -LatestLocalPath $latestLocal
    Assert-Condition (-not $missingCachedObject.Eligible -and $missingCachedObject.Reason -eq 'remote_object_query_failed') 'An unverified cached remote object must not permit skipping the upload path.'
    $global:CloudIntegrityMissingRemotePaths = @()

    $global:CloudIntegrityRemotes = @('other:')
    $missingBound = Resolve-ConfiguredRcloneRemote -Remote 'gdrive:' -BindingPath $bindingPath
    Assert-Condition (-not $missingBound.Success -and $missingBound.Reason -eq 'bound_remote_not_found') 'A missing bound alias must not switch to another configured remote.'
    $global:CloudIntegrityRemotes = @('gdrive:')
    $literalDefault = Resolve-ConfiguredRcloneRemote -Remote 'gdrive:' -BindingPath (Join-Path $fixtureRoot 'missing-binding.json')
    Assert-Condition ($literalDefault.Success -and $literalDefault.Remote -eq 'gdrive:' -and $literalDefault.Source -eq 'literal_default') 'The literal default is valid only when that exact remote exists.'
    $global:CloudIntegrityInventoryFailure = $true
    $inventoryFailure = Resolve-ConfiguredRcloneRemote -Remote 'selected:' -RemoteWasExplicit $true
    Assert-Condition (-not $inventoryFailure.Success -and $inventoryFailure.Reason -eq 'remote_inventory_failed') 'Remote inventory failure must fail closed.'

    Remove-Item -LiteralPath Function:\global:rclone -Force
    if ($null -ne $realRclone) {
        # A fresh process prevents the global rclone mock from satisfying these
        # tests through PowerShell's command-resolution state.
        $probeScript = Join-Path $fixtureRoot 'real-rclone-probe.ps1'
        [IO.File]::WriteAllText($probeScript, @'
param([string]$Helper, [string]$Source, [string]$Target)
$ErrorActionPreference = 'Stop'
. $Helper
Test-RcloneRemoteFileMatchesLocal -LocalPath $Source -RemotePath $Target | ConvertTo-Json -Compress
'@, [Text.UTF8Encoding]::new($true))
        function Invoke-RealObjectProbe([string]$Source, [string]$Target) {
            $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Helper $networkHelper -Source $Source -Target $Target
            if ($LASTEXITCODE -ne 0) { throw 'Real rclone adapter process failed.' }
            return ($result | ConvertFrom-Json)
        }
        $renamedTarget = Join-Path $fixtureRoot 'remote-dated-name.zip'
        Copy-Item -LiteralPath $datedLocal -Destination $renamedTarget
        $realMatch = Invoke-RealObjectProbe $datedLocal $renamedTarget
        Assert-Condition $realMatch.Matches 'Real rclone must verify a single differently named object, not treat it as a directory.'
        [IO.File]::WriteAllText($renamedTarget, 'synthetic dated packagE')
        $realMismatch = Invoke-RealObjectProbe $datedLocal $renamedTarget
        Assert-Condition (-not $realMismatch.Matches) 'Real rclone must reject equal-size changed bytes.'
        $realMissing = Invoke-RealObjectProbe $datedLocal (Join-Path $fixtureRoot 'absent.zip')
        Assert-Condition (-not $realMissing.Matches) 'Real rclone must reject a missing exact object.'
        $realDirectory = Invoke-RealObjectProbe $datedLocal $fixtureRoot
        Assert-Condition (-not $realDirectory.Matches) 'A directory must not be accepted as a backup object.'
        Write-Host 'PASS: real rclone local-only single-object match/mismatch/missing/directory checks.'
    } else {
        Write-Host 'SKIP: rclone application is unavailable for local-only interface tests.'
    }
    Write-Host 'PASS: explicit remote selection, destination-bound cache verification, and SQLite companion retention are covered by mocks.'
}
finally {
    Remove-Item -LiteralPath Function:\global:rclone -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name CloudIntegrityRemotes, CloudIntegrityInventoryFailure, CloudIntegrityMissingRemotePaths, CloudIntegrityRcloneCalls -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot) {
        $fixtureFull = Assert-PathWithinFixtureNamespace -Path $fixtureRoot -NamespaceRoot $fixtureBase
        if ((Split-Path -Leaf $fixtureFull) -notmatch '^cloud-backup-integrity-[0-9a-f]{32}$') { throw "Unexpected cloud fixture root: $fixtureFull" }
        Remove-Item -LiteralPath $fixtureFull -Recurse -Force -ErrorAction Stop
    }
}
