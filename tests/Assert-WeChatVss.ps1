[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')

$fixtureParent = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixtureRoot = Join-Path $fixtureParent ('wechat-vss-' + [guid]::NewGuid().ToString('N'))
$checks = 0
function Check([bool] $Condition, [string] $Name) {
    if (-not $Condition) { throw ('FAIL: ' + $Name) }
    $script:checks++
    Write-Host ('PASS: ' + $Name)
}
function Put([string] $Path, [string] $Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $source = Join-Path $fixtureRoot 'source'
    $target = Join-Path $fixtureRoot 'target'
    $state = Join-Path $fixtureRoot 'state'
    $receipt = Join-Path $fixtureRoot 'hot-receipt.json'
    Put (Join-Path $source 'db_storage\fixture.bin') 'stable fixture'

    $backupText = Get-Content -LiteralPath (Join-Path $repo 'Backup-WeChat.ps1') -Raw
    Check ($backupText -match '\[switch\]\$UseVss' -and $backupText -match 'New-BackupVssSnapshot') 'Hot entrypoint exposes the explicit VSS source path'
    $hiddenText = Get-Content -LiteralPath (Join-Path $repo 'Backup-WeChat-Hidden.vbs') -Raw
    $setupText = Get-Content -LiteralPath (Join-Path $repo 'Setup-ScheduledTasks.ps1') -Raw
    Check ($hiddenText -match 'LCase\(target\) = "hot"' -and $hiddenText -match 'vssArg = " -UseVss"') 'The existing Hot launcher passes UseVss without changing Drive'
    Check ($setupText -match '\$weChatHotPrincipal\s*=\s*New-ScheduledTaskPrincipal' -and $setupText -match 'RunLevel Highest' -and $setupText -match 'Principal = \$weChatHotPrincipal') 'The installer declares Highest only for the existing WeChat Hot task'
    Check ((Resolve-BackupPath '\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy999\fixture') -match '(?i)HarddiskVolumeShadowCopy999') 'VSS device paths resolve without a filesystem provider lookup'

    $record = Invoke-VerifiedBackupTree -Source $source -SourceIdentity $source -Destination $target
    $manifest = Get-VerifiedBackupTreeManifest $target
    Check ([string]$manifest.source -eq [IO.Path]::GetFullPath($source).TrimEnd('\')) 'Tree manifests retain the registered source identity when reading a source view'

    [void][IO.Directory]::CreateDirectory($state)
    $journalPath = Get-BackupVssJournalPath $state
    Write-BackupJsonAtomic $journalPath ([ordered]@{schema='devconfig.wechat-vss-journal.v1';shadow_id='{00000000-0000-0000-0000-000000000000}';volume_root='E:\';source=[IO.Path]::GetFullPath($source);snapshot_source='\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy999\fixture';run_id='fixture';created_utc=(Get-BackupUtc)})
    $refused = $false
    $cleanupCode = $null
    try { Repair-BackupVssJournal $state 'E:\' $source } catch { $cleanupCode = $_.Exception.Message; $refused = [IO.File]::Exists($journalPath) }
    Check ($refused -and [IO.File]::Exists($journalPath)) 'VSS cleanup refuses an unverified snapshot identity and preserves its journal'
    [IO.File]::Delete($journalPath)

    $invalidId = $false
    try { Remove-BackupVssSnapshotExact '{not-a-vss-id}' } catch { $invalidId = $_.Exception.Message -eq 'backup_vss_shadow_id_invalid' }
    Check $invalidId 'VSS cleanup rejects malformed IDs before querying the volume'

    if (-not (Test-BackupAdministrator)) {
        $runtime = (Get-Process -Id $PID).Path
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'Backup-WeChat.ps1'),
            '-Source', $source, '-HotRoot', (Join-Path $fixtureRoot 'hot'),
            '-HotReceiptPath', $receipt, '-StateRoot', $state, '-Target', 'Hot', '-UseVss', '-Json'
        )
        $output = @(& $runtime @arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
        Check ($exitCode -ne 0 -and ($output -join [Environment]::NewLine) -match 'backup_vss_administrator_required') 'VSS Hot execution fails closed without elevation'
        Check (-not [IO.Directory]::Exists((Join-Path $fixtureRoot 'hot')) -and -not [IO.File]::Exists($receipt)) 'Failed VSS preflight creates no Hot target or receipt'
    } else {
        Write-Host 'SKIP: current test host is elevated; production VSS consumption remains a separate acceptance.'
    }

    Write-Output ("RESULT: {0} WeChat VSS checks passed; runtime={1}" -f $checks, $PSVersionTable.PSVersion)
} finally {
    if ([IO.Directory]::Exists($fixtureRoot)) { [IO.Directory]::Delete($fixtureRoot, $true) }
}
