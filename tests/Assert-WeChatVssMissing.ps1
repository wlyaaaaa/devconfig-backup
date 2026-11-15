[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Backup.Common.ps1')
$id='{00000000-0000-0000-0000-000000000001}'
$script:mode='missing';$script:removed=0
function Get-CimInstance { param($ClassName,$Namespace,$ErrorAction)
 if($script:mode -eq 'error'){throw 'fixture_query_failed'}
 if($script:mode -eq 'duplicate'){return @([pscustomobject]@{ID=$id},[pscustomobject]@{ID=$id})}
 if($script:mode -eq 'present'){return [pscustomobject]@{ID=$id}}
}
function Remove-CimInstance { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:removed++;$script:mode='missing'} }
function Check($ok,$label){if(-not $ok){throw "FAIL: $label"};Write-Output "PASS: $label"}
Remove-BackupVssSnapshotExact $id -AllowMissing
Check ($script:removed -eq 0) 'Missing journal snapshot causes no deletion'
$err='';try{Remove-BackupVssSnapshotExact $id}catch{$err=$_.Exception.Message}
Check ($err -eq 'backup_vss_delete_target_not_unique') 'Normal cleanup remains strict'
foreach($mode in @('duplicate','error')){$script:mode=$mode;$err='';try{Remove-BackupVssSnapshotExact $id -AllowMissing}catch{$err=$_.Exception.Message};Check ([bool]$err -and $script:removed -eq 0) "$mode remains a failure without deletion"}
$script:mode='present';Remove-BackupVssSnapshotExact $id -AllowMissing
Check ($script:removed -eq 1) 'Existing exact snapshot still deleted and verified'
$source=Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'Backup.Common.ps1') -Raw
Check ($source -match 'Remove-BackupVssSnapshotExact \(\[string\]\$journal.shadow_id\) -AllowMissing;') 'Only journal recovery opts into absent snapshot acceptance'
'RESULT: 6 isolated missing snapshot checks passed; no real snapshots queried or modified'