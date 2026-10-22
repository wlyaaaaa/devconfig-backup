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
    Check ($setupText -match '\[string\[\]\]\s*\$TaskName' -and $setupText -match 'Invoke-BackupScheduledTaskRegistrationTransaction .*AllowSubset') 'The installer exposes exact task selection through the existing transaction'
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

    # Extract and execute just the entry guard; never create a real VSS snapshot.
    $tree=[Management.Automation.Language.Parser]::ParseInput($backupText,[ref]$null,[ref]$null)
    $guard=$tree.EndBlock.Statements | Where-Object {$_.Extent.Text -like 'if($UseVss -and -not $Plan*'}
    $UseVss=$true;$Plan=$false;$PSCommandPath=Join-Path $repo 'Backup-WeChat.ps1'
    $PSBoundParameters=@{UseVss=$true;Source=$source};$script:relaunched=$false
    function Test-BackupAdministrator {return $false}
    function Invoke-ProjectElevated($Command){$script:relaunched=$Command -match 'FromBase64String';$global:LASTEXITCODE=23}
    # Replacing exit only in the isolated fixture allows checking the child result.
    & ([scriptblock]::Create($guard.Extent.Text.Replace('exit $LASTEXITCODE','return $LASTEXITCODE'))) | Out-Null
    Check $script:relaunched 'VSS entry automatically relaunches before snapshot or receipt work'
    Check ($LASTEXITCODE -eq 23) 'VSS entry preserves elevated child exit code'
    Check (-not [IO.Directory]::Exists((Join-Path $fixtureRoot 'hot')) -and -not [IO.File]::Exists($receipt)) 'Elevation dispatch creates no Hot target or receipt'

    Write-Output ("RESULT: {0} WeChat VSS checks passed; runtime={1}" -f $checks, $PSVersionTable.PSVersion)
} finally {
    if ([IO.Directory]::Exists($fixtureRoot)) { [IO.Directory]::Delete($fixtureRoot, $true) }
}
