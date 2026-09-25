<#
.SYNOPSIS
  Verified, source-follow native WeChat backup. -Plan/-List never writes.
.DESCRIPTION
  Copies opaque native files, not account/chat/key contents. Local and G publish
  a verified generation with one bounded previous generation. Drive never reads
  the running WeChat directory: it uploads the current G hot generation only
  after its receipt proves a complete, VSS-captured, SHA-256-verified tree that
  is recent enough and still matches its manifest; the G lock is held for the
  whole upload. A refused or failed generation cannot reach the cloud.
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
    [ValidateRange(1,720)][int]$MaxHotAgeHours=48, [switch]$AllowLiveSourceHot,
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
# A custom Hot root may not read or write a receipt at the production G location.
$script:HotReceiptFile=if($PSBoundParameters.ContainsKey('HotRoot') -and -not $PSBoundParameters.ContainsKey('HotReceiptPath')){$HotRoot+'.hot-receipt.json'}else{$HotReceiptPath}
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
function New-WeChatUploadSourceRecord {
    return [ordered]@{kind='g_hot_verified_generation';gate='pending';refusal=$null;hot_generation_id=$null;hot_completed_utc=$null;hot_age_hours=$null;max_hot_age_hours=$MaxHotAgeHours;hot_receipt_status=$null;hot_verification_status=$null;hot_capture_consistency=$null;hot_manifest_sha256=$null;pre_upload_check='not_run'}
}
function ConvertTo-WeChatReceiptTime($Value){
    # PowerShell 7 may already have converted the ISO string into a DateTime.
    if($Value -is [DateTime]){return [DateTimeOffset]$Value.ToUniversalTime()}
    $parsed=[DateTimeOffset]::MinValue
    if([DateTimeOffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)){return $parsed}
    throw 'wechat_hot_receipt_time_invalid'
}
function Get-WeChatTreeShapeDigest($Directories,$Files){
    $lines=[Collections.Generic.List[string]]::new();$lines.Add('wechat-tree-shape-v1')
    foreach($directory in @($Directories|Where-Object{$null-ne $_})){$lines.Add('d|'+$directory)}
    foreach($file in @($Files|Where-Object{$null-ne $_})){$lines.Add('f|'+$file.relative_path+'|'+[string][long]$file.length)}
    return Get-BackupTextHash ($lines-join "`n")
}
function Get-WeChatHotUploadGeneration {
    # Read-only gate. Returns the verified G manifest or throws a stable refusal code.
    param([Parameter(Mandatory)]$UploadSource)
    if(-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($HotRoot))){throw 'wechat_hot_root_unavailable'}
    try{$receipt=Read-BackupJson $script:HotReceiptFile -Required}catch{if($_.Exception.Message-ceq 'backup_json_missing'){throw 'wechat_hot_receipt_missing'};throw 'wechat_hot_receipt_unreadable'}
    if($null-eq $receipt){throw 'wechat_hot_receipt_unreadable'}
    $UploadSource.hot_generation_id=[string]$receipt.generation_id;$UploadSource.hot_receipt_status=[string]$receipt.status
    $UploadSource.hot_verification_status=[string]$receipt.verification_status;$UploadSource.hot_capture_consistency=[string]$receipt.capture_consistency
    $UploadSource.hot_manifest_sha256=[string]$receipt.manifest_sha256
    $completed=$null;try{$completed=ConvertTo-WeChatReceiptTime $receipt.completed_utc;$UploadSource.hot_completed_utc=$completed.UtcDateTime.ToString('o')}catch{}
    if($receipt.schema-cne 'wechat.hot-backup-receipt.v2' -or $receipt.status-cne 'complete' -or $receipt.collection_status-cne 'complete' -or $receipt.verification_status-cne 'sha256_full_tree' -or $receipt.retention_status-cne 'source_follow_verified'){throw 'wechat_hot_receipt_not_verified'}
    if([string]$receipt.destination-ine $HotRoot){throw 'wechat_hot_receipt_destination_mismatch'}
    if($null-eq $completed){throw 'wechat_hot_receipt_time_invalid'}
    $age=([DateTimeOffset]::UtcNow-$completed).TotalHours;$UploadSource.hot_age_hours=[math]::Round($age,2)
    if($age-lt -0.1){throw 'wechat_hot_receipt_time_invalid'}
    if($age-gt $MaxHotAgeHours){throw 'wechat_hot_receipt_stale'}
    if($receipt.capture_consistency-cne 'vss_crash_consistent' -and -not $AllowLiveSourceHot){throw 'wechat_hot_capture_not_vss'}
    try{$manifest=Get-VerifiedBackupTreeManifest $HotRoot}catch{throw ('wechat_hot_manifest_unavailable:'+(Get-BackupFailureCode $_))}
    if(-not (Test-BackupTreeReceiptBound $script:HotReceiptFile $HotRoot $manifest)){throw 'wechat_hot_receipt_manifest_mismatch'}
    # Cheap tamper check: the tree must still have exactly the verified directories, paths and sizes.
    # Times are not compared: unchanged files are hard-linked from the previous generation and
    # keep its time while the manifest records the source time (content is still hash-verified).
    try{$current=Get-BackupTreeInventory $HotRoot}catch{throw ('wechat_hot_tree_unreadable:'+(Get-BackupFailureCode $_))}
    if((Get-WeChatTreeShapeDigest $current.directories $current.files)-cne (Get-WeChatTreeShapeDigest $manifest.directories $manifest.files)){throw 'wechat_hot_tree_changed_since_verification'}
    $UploadSource.pre_upload_check='receipt_manifest_bound_tree_shape_match';$UploadSource.gate='passed'
    return $manifest
}
function Invoke-WeChatDrivePublication {
    param($Snapshot,$UploadSource)
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
    # The source is the locked, verified G generation, never the running WeChat directory.
    # Never delete cloud extras before all current source objects have arrived.
    Invoke-BackupRclone copy $HotRoot $dest @filter @common @limit *> $null
    if($LASTEXITCODE-ne 0){throw 'wechat_drive_copy_failed'}
    Invoke-BackupRclone check $HotRoot $dest @filter --one-way --checkers 8 --retries 2 --contimeout 20s --timeout 120s *> $null
    if($LASTEXITCODE-ne 0){throw 'wechat_drive_preprune_verification_failed'}
    # The exact same filter constrains pruning. DbOnly never deletes existing media.
    Invoke-BackupRclone sync $HotRoot $dest @filter @common @limit --delete-after *> $null
    if($LASTEXITCODE-ne 0){throw 'wechat_drive_convergence_failed'}
    Invoke-BackupRclone check $HotRoot $dest @filter --checkers 8 --retries 2 --contimeout 20s --timeout 120s *> $null
    if($LASTEXITCODE-ne 0){throw 'wechat_drive_final_verification_failed'}
    if((Get-BackupStableFileHash ($HotRoot+'.backup-manifest.json'))-cne $UploadSource.hot_manifest_sha256){throw 'wechat_hot_generation_changed_during_upload'}
    # The resolved remote name can be an account address; receipts keep only the folder.
    $receipt=Get-WeChatSummary $Snapshot 'drive';$receipt.Remove('destination');$receipt.source=$HotRoot
    $receipt.destination_remote='configured_rclone_binding';$receipt.destination_folder=$GDriveFolder.TrimEnd('/','\')
    $receipt.capture_consistency=$UploadSource.hot_capture_consistency;$receipt.upload_source=$UploadSource
    $receipt.verification_status='rclone_checksum_check';$receipt.scope=if($DbOnly -and -not $DriveFull){'database_only'}else{'full_native_data'}
    if($receipt.scope-eq 'database_only'){
        $selected=@($Snapshot.files|Where-Object{$_.relative_path-match '(^|/)db_storage/'})
        $receipt.file_count=$selected.Count;$receipt.bytes=0;foreach($entry in $selected){$receipt.bytes+=[long]$entry.length}
        $receipt.source_snapshot_sha256=$receipt.content_sha256;$receipt.Remove('content_sha256')
    }
    $portable=$HotRoot+'.backup-manifest.json'
    if($receipt.scope-eq 'full_native_data'){
        Invoke-BackupRclone copyto $portable ($dest+'.backup-manifest.json') --checksum --retries 3 --contimeout 20s --timeout 120s *> $null
        if($LASTEXITCODE-ne 0 -or -not (Test-RcloneRemoteFileMatchesLocal -LocalPath $portable -RemotePath ($dest+'.backup-manifest.json')).Matches){throw 'wechat_drive_manifest_failed'}
    }
    Write-BackupJsonAtomic (Join-Path $StateRoot 'wechat-drive-success.json') $receipt
    return $receipt
}
if($Plan){
    if($UseVss){throw 'backup_vss_plan_requires_execution'}
    $plans=@();foreach($kind in $Target){
        if($kind-eq 'Drive'){
            # Same read-only gate as the real upload, without taking the G lock or contacting the cloud.
            $gate=New-WeChatUploadSourceRecord;$ready=$false
            try{$null=Get-WeChatHotUploadGeneration $gate;$ready=$true}catch{$gate.gate='refused';$gate.refusal=Get-BackupFailureCode $_}
            $plans+=[pscustomobject]@{target=$kind;source=$HotRoot;upload_ready=$ready;upload_source=[pscustomobject]$gate;cloud='not_contacted'};continue
        }
        $destination=if($kind-eq 'Hot'){$HotRoot}else{$LocalRoot};$planned=Invoke-VerifiedBackupTree -Source $Source -Destination $destination -ExcludeDirs $exclDirs -Plan;$plans+=[pscustomobject]@{target=$kind;destination=$destination;source_files=$planned.file_count;source_bytes=$planned.bytes;difference=$planned.difference;cloud='not_contacted'}
    }
    $result=[ordered]@{schema='wechat.backup-plan.v1';write_mode='zero_write';targets=$plans;application_consistency='not_proven';application_recovery='not_tested'}
    if($Json){$result|ConvertTo-Json -Depth 10}else{[pscustomobject]$result|Format-List};exit 0
}
$capturesSource=($Target-contains 'Hot' -or $Target-contains 'Local')
$run=[ordered]@{schema='wechat.run.v2';run_id=[guid]::NewGuid().ToString('N');started_utc=(Get-BackupUtc);completed_utc=$null;status='running';targets=$Target;hot='not_requested';local='not_requested';drive='not_requested';failure=$null;capture_consistency=$(if($capturesSource){$script:SourceCaptureMode}else{'no_source_capture'});application_recovery='not_tested'}
if($Target-contains 'Drive'){$run.upload_source=New-WeChatUploadSourceRecord}
$runPath=Join-Path $StateRoot ('wechat-'+$(if($Target.Count-eq 1 -and $Target[0]-eq 'Drive'){'drive'}else{'local'})+'-last.json')
$code=0;$lease=$null;$driveLease=$null;$snapshot=$null;$vssCapture=$null;$sourceForCapture=$Source
try{
    Write-BackupJsonAtomic $runPath $run
    if($UseVss -and $capturesSource){$vssCapture=New-BackupVssSnapshot -Source $Source -StateRoot $StateRoot -RunId $run.run_id;$sourceForCapture=$vssCapture.SnapshotSource}
    if($Target-contains 'Hot'){
        try {
         $run.hot='running';Write-BackupJsonAtomic $runPath $run
         $hotLease=Open-BackupResourceLock $HotRoot
         try {
         $receiptPath=$script:HotReceiptFile
         $hot=Invoke-VerifiedBackupTree -Source $sourceForCapture -SourceIdentity $Source -Destination $HotRoot -ExcludeDirs $exclDirs -LockHeld -PostCommitReceiptPath $receiptPath -PostCommit {
             param($record)
             Write-BackupJsonAtomic $receiptPath (Get-WeChatSummary $record 'hot')
         }
         } finally {$hotLease.Dispose()}
        $run.hot='complete';Write-BackupJsonAtomic $runPath $run
        } catch { $run.hot='failed';$run.failure=Get-BackupFailureCode $_;$code=1;Write-BackupJsonAtomic $runPath $run }
    }
    if($Target-contains 'Local'){
        $lease=Open-BackupResourceLock $LocalRoot
        $run.local='running';Write-BackupJsonAtomic $runPath $run
        $snapshot=Invoke-VerifiedBackupTree -Source $sourceForCapture -SourceIdentity $Source -Destination $LocalRoot -ExcludeDirs $exclDirs -LockHeld
        $null=Get-VerifiedBackupTreeManifest $LocalRoot
        $run.local='complete';Write-BackupJsonAtomic $runPath $run
        $lease.Dispose();$lease=$null
    }
    if($Target-contains 'Drive'){
        $run.drive='running';Write-BackupJsonAtomic $runPath $run
        # Hold the G lock so the daily Hot run cannot swap the tree during upload.
        try{$driveLease=Open-BackupResourceLock $HotRoot}catch{$run.upload_source.gate='refused';$run.upload_source.refusal='wechat_hot_resource_busy';$run.drive='not_uploaded';throw 'wechat_hot_resource_busy'}
        try{$hotGeneration=Get-WeChatHotUploadGeneration $run.upload_source}catch{$run.upload_source.gate='refused';$run.upload_source.refusal=Get-BackupFailureCode $_;$run.drive='not_uploaded';throw}
        Write-BackupJsonAtomic $runPath $run
        $null=Invoke-WeChatDrivePublication $hotGeneration $run.upload_source
        $run.drive='complete'
    }
    $run.status=if($code-eq 0){'complete'}else{'failed'}
}catch{
    $run.status='failed';$run.failure=Get-BackupFailureCode $_;$code=1
    foreach($phase in @('hot','local','drive')){if($run[$phase]-eq 'running'){$run[$phase]='failed'}}
}finally{
    if($lease){$lease.Dispose()}
    if($driveLease){$driveLease.Dispose()}
    if($vssCapture){try{Remove-BackupVssSnapshot $vssCapture}catch{$code=1;$run.status='failed';$run.failure='backup_vss_cleanup_failed'}}
    $run.completed_utc=Get-BackupUtc
    try{Write-BackupJsonAtomic $runPath $run}catch{$code=1;$run.status='failed';$run.failure='run_status_publication_failed'}
}
if($Json){$run|ConvertTo-Json -Depth 8}else{[pscustomobject]$run|Format-List}
exit $code
