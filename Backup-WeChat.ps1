<#
.SYNOPSIS
  Verified, source-follow native WeChat backup. -Plan/-List never writes.
.DESCRIPTION
  Copies opaque native files, not account/chat/key contents. Local and G publish
  a verified generation with one bounded previous generation. Drive consumes a
  completed, locked local snapshot; a failed snapshot cannot reach the cloud.
  File integrity does not establish application-consistent capture or acceptance
  by the official client. H cold recovery remains owned by PCConfig.
#>
[CmdletBinding()]
param(
    [string[]]$Target=@('Hot'), [string]$Source='E:\Documents\xwechat_files',
    [string]$HotRoot='G:\80_Backup\WeChat\xwechat_files',
    [string]$HotReceiptPath='G:\80_Backup\ControlPlane\wechat-hot-last.json',
    [string]$LocalRoot='E:\WeChatBackup\xwechat_files',
    [string]$GDriveRemote='gdrive:', [string]$GDriveFolder='Backups/WeChat/xwechat_files',
    [string]$BwLimit='4M', [string]$MaxTransfer='8G', [switch]$DriveFull,
    [switch]$DbOnly, [Alias('List')][switch]$Plan, [switch]$Json, [switch]$UseVss,
    [string]$StateRoot=''
)
if(-not $StateRoot){$StateRoot=Join-Path $PSScriptRoot 'state'}
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Backup.Common.ps1')
. (Join-Path $PSScriptRoot 'Initialize-BackupNetwork.ps1')
$script:GDriveRemoteWasExplicit=$PSBoundParameters.ContainsKey('GDriveRemote')
$script:SourceCaptureMode=if($UseVss){'vss_crash_consistent'}else{'live_source'}
$selection=Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'wechat-sources.psd1')
$exclDirs=@($selection.ExcludeDirs)
$Target=@(@($Target)|ForEach-Object{$_-split ','}|ForEach-Object{$_.Trim()}|Where-Object{$_}|Select-Object -Unique)
if($Target.Count-eq 0 -or @($Target|Where-Object{$_-notin @('Hot','Local','Drive')}).Count){throw 'invalid_backup_target'}
if($MaxTransfer -and $MaxTransfer -notmatch '^(0|[0-9]+(?:\.[0-9]+)?[kKmMgGtT]?)$'){throw 'invalid_transfer_limit'}
$Source=Resolve-BackupPath $Source; $LocalRoot=Resolve-BackupPath $LocalRoot; $HotRoot=Resolve-BackupPath $HotRoot
foreach($destination in @($LocalRoot,$HotRoot)){Assert-BackupPathsIndependent $Source $destination}
Assert-BackupPathsIndependent $LocalRoot $HotRoot
function Get-WeChatCloudFilter {
    if($DbOnly -and -not $DriveFull){return @('--filter','+ **/db_storage/**','--filter','- *')}
    $result=@();foreach($name in $exclDirs){$result+=@('--exclude',($name+'/**'))};return $result
}
function Get-WeChatSummary {
    param($Manifest,[string]$Kind)
    $portable=[string]$Manifest.destination+'.backup-manifest.json'
    $manifestHash=Get-BackupStableFileHash $portable
    $manifestBytes=[long](Get-Item -LiteralPath $portable -ErrorAction Stop).Length
    return [ordered]@{manifest_sha256=$manifestHash;manifest_bytes=$manifestBytes;schema=('wechat.'+$Kind+'-backup-receipt.v2');status='complete';completed_utc=(Get-BackupUtc);source=$Source;destination=$Manifest.destination;generation_id=$Manifest.run_id;collection_status='complete';verification_status='sha256_full_tree';retention_status='source_follow_verified';content_sha256=$Manifest.content_sha256;file_count=$Manifest.file_count;bytes=$Manifest.bytes;excluded_directory_count=$exclDirs.Count;payload_names_emitted=$false;payload_content_interpreted=$false;capture_consistency=$script:SourceCaptureMode;application_consistency='not_proven';application_recovery='not_tested'}
}
function Invoke-WeChatDrivePublication {
    param($Snapshot)
    $rclone=Get-BackupExecutable rclone -FallbackPath 'E:\Scoop\shims\rclone.exe'
    $env:PATH=[IO.Path]::GetDirectoryName($rclone)+';'+$env:PATH
    $null=Initialize-BackupNetwork
    $resolved=Resolve-ConfiguredRcloneRemote -Remote $GDriveRemote -RemoteWasExplicit $script:GDriveRemoteWasExplicit -BindingPath (Join-Path $StateRoot 'rclone-remote-binding.json')
    if(-not $resolved.Success){throw ('drive_remote_unavailable:'+ $resolved.Reason)}
    if([string]::IsNullOrWhiteSpace($GDriveFolder) -or $GDriveFolder-match '(^|[/\\])\.\.([/\\]|$)|^[/\\]'){throw 'drive_folder_invalid'}
    $dest=$resolved.Remote+$GDriveFolder.TrimEnd('/','\')
    $preflight=Invoke-RcloneDrivePreflight -Remote $resolved.Remote
    if(-not $preflight.Success){throw ('drive_preflight_failed:'+ $preflight.Category)}
    $filter=@(Get-WeChatCloudFilter)
    $common=@('--checksum','--checkers','8','--transfers','4','--bwlimit',$BwLimit,'--tpslimit','8','--retries','3','--low-level-retries','10','--contimeout','20s','--timeout','120s')
    $limit=@();if($MaxTransfer -and $MaxTransfer-ne '0'){$limit=@('--max-transfer',$MaxTransfer,'--cutoff-mode','cautious')}
    # Never delete cloud extras before all current source objects have arrived.
    Invoke-BackupRclone copy $LocalRoot $dest @filter @common @limit *> $null
    if($LASTEXITCODE-ne 0){throw 'wechat_drive_copy_failed'}
    Invoke-BackupRclone check $LocalRoot $dest @filter --one-way --checkers 8 --retries 2 --contimeout 20s --timeout 120s *> $null
    if($LASTEXITCODE-ne 0){throw 'wechat_drive_preprune_verification_failed'}
    # The exact same filter constrains pruning. DbOnly never deletes existing media.
    Invoke-BackupRclone sync $LocalRoot $dest @filter @common @limit --delete-after *> $null
    if($LASTEXITCODE-ne 0){throw 'wechat_drive_convergence_failed'}
    Invoke-BackupRclone check $LocalRoot $dest @filter --checkers 8 --retries 2 --contimeout 20s --timeout 120s *> $null
    if($LASTEXITCODE-ne 0){throw 'wechat_drive_final_verification_failed'}
    $receipt=Get-WeChatSummary $Snapshot 'drive';$receipt.destination=$dest
    $receipt.verification_status='rclone_checksum_check';$receipt.scope=if($DbOnly -and -not $DriveFull){'database_only'}else{'full_native_data'}
    if($receipt.scope-eq 'database_only'){
        $selected=@($Snapshot.files|Where-Object{$_.relative_path-match '(^|/)db_storage/'})
        $receipt.file_count=$selected.Count;$receipt.bytes=0;foreach($entry in $selected){$receipt.bytes+=[long]$entry.length}
        $receipt.source_snapshot_sha256=$receipt.content_sha256;$receipt.Remove('content_sha256')
    }
    $portable=$LocalRoot+'.backup-manifest.json'
    if($receipt.scope-eq 'full_native_data'){
        Invoke-BackupRclone copyto $portable ($dest+'.backup-manifest.json') --checksum --retries 3 --contimeout 20s --timeout 120s *> $null
        if($LASTEXITCODE-ne 0 -or -not (Test-RcloneRemoteFileMatchesLocal -LocalPath $portable -RemotePath ($dest+'.backup-manifest.json')).Matches){throw 'wechat_drive_manifest_failed'}
    }
    Write-BackupJsonAtomic (Join-Path $StateRoot 'wechat-drive-success.json') $receipt
    return $receipt
}
if($Plan){
    if($UseVss){throw 'backup_vss_plan_requires_execution'}
    $plans=@();foreach($kind in $Target){$destination=if($kind-eq 'Hot'){$HotRoot}else{$LocalRoot};$planned=Invoke-VerifiedBackupTree -Source $Source -Destination $destination -ExcludeDirs $exclDirs -Plan;$plans+=[pscustomobject]@{target=$kind;destination=$destination;source_files=$planned.file_count;source_bytes=$planned.bytes;difference=$planned.difference;cloud='not_contacted'}}
    $result=[ordered]@{schema='wechat.backup-plan.v1';write_mode='zero_write';targets=$plans;application_consistency='not_proven';application_recovery='not_tested'}
    if($Json){$result|ConvertTo-Json -Depth 10}else{[pscustomobject]$result|Format-List};exit 0
}
$run=[ordered]@{schema='wechat.run.v2';run_id=[guid]::NewGuid().ToString('N');started_utc=(Get-BackupUtc);completed_utc=$null;status='running';targets=$Target;hot='not_requested';local='not_requested';drive='not_requested';failure=$null;capture_consistency=$script:SourceCaptureMode;application_recovery='not_tested'}
$runPath=Join-Path $StateRoot ('wechat-'+$(if($Target.Count-eq 1 -and $Target[0]-eq 'Drive'){'drive'}else{'local'})+'-last.json')
$code=0;$lease=$null;$snapshot=$null;$vssCapture=$null;$sourceForCapture=$Source
try{
    Write-BackupJsonAtomic $runPath $run
    if($UseVss){$vssCapture=New-BackupVssSnapshot -Source $Source -StateRoot $StateRoot -RunId $run.run_id;$sourceForCapture=$vssCapture.SnapshotSource}
    if($Target-contains 'Hot'){
        try {
         $run.hot='running';Write-BackupJsonAtomic $runPath $run
         $hotLease=Open-BackupResourceLock $HotRoot
         try {
         # A custom Hot root may not write a receipt into the production G location.
         $receiptPath=if($PSBoundParameters.ContainsKey('HotRoot') -and -not $PSBoundParameters.ContainsKey('HotReceiptPath')){$HotRoot+'.hot-receipt.json'}else{$HotReceiptPath}
         $hot=Invoke-VerifiedBackupTree -Source $sourceForCapture -SourceIdentity $Source -Destination $HotRoot -ExcludeDirs $exclDirs -LockHeld -PostCommitReceiptPath $receiptPath -PostCommit {
             param($record)
             Write-BackupJsonAtomic $receiptPath (Get-WeChatSummary $record 'hot')
         }
         } finally {$hotLease.Dispose()}
        $run.hot='complete';Write-BackupJsonAtomic $runPath $run
        } catch { $run.hot='failed';$run.failure=Get-BackupFailureCode $_;$code=1;Write-BackupJsonAtomic $runPath $run }
    }
    if($Target-contains 'Local' -or $Target-contains 'Drive'){
        $lease=Open-BackupResourceLock $LocalRoot
        $run.local='running';Write-BackupJsonAtomic $runPath $run
        $snapshot=Invoke-VerifiedBackupTree -Source $sourceForCapture -SourceIdentity $Source -Destination $LocalRoot -ExcludeDirs $exclDirs -LockHeld
        $null=Get-VerifiedBackupTreeManifest $LocalRoot
        $run.local='complete';Write-BackupJsonAtomic $runPath $run
        if($Target-contains 'Drive'){
            $run.drive='running';Write-BackupJsonAtomic $runPath $run
            $null=Invoke-WeChatDrivePublication $snapshot
            $run.drive='complete'
        }
    }
    $run.status=if($code-eq 0){'complete'}else{'failed'}
}catch{
    $run.status='failed';$run.failure=Get-BackupFailureCode $_;$code=1
    foreach($phase in @('hot','local','drive')){if($run[$phase]-eq 'running'){$run[$phase]='failed'}}
}finally{
    if($lease){$lease.Dispose()}
    if($vssCapture){try{Remove-BackupVssSnapshot $vssCapture}catch{$code=1;$run.status='failed';$run.failure='backup_vss_cleanup_failed'}}
    $run.completed_utc=Get-BackupUtc
    try{Write-BackupJsonAtomic $runPath $run}catch{$code=1;$run.status='failed';$run.failure='run_status_publication_failed'}
}
if($Json){$run|ConvertTo-Json -Depth 8}else{[pscustomobject]$run|Format-List}
exit $code
