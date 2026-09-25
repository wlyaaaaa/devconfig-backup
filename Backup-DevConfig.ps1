<#
.SYNOPSIS
  Collect, verify, publish and distribute complete DevConfig generations.
.DESCRIPTION
  -Plan is zero-write. Collection failures never publish or prune successful
  backups. H cold copying is owned by PCConfig. Source selection remains in
  sources.psd1; configuration payload may contain private credentials.
#>
[CmdletBinding()]
param(
 [string[]]$Tier=@('Local'),[switch]$IncludeHistory,[switch]$Force,
 [string]$HotRoot='G:\80_Backup\DevConfig',[string]$GDriveRemote='gdrive:',
 [string]$GDriveFolder="Backups/$env:COMPUTERNAME",[string]$BwLimit='4M',
 [ValidateRange(1,365)][int]$KeepLocal=7,[ValidateRange(1,365)][int]$KeepHot=7,[ValidateRange(1,365)][int]$KeepDrive=3,
 [switch]$Plan,[switch]$Json,[string]$ProfileRoot=$env:USERPROFILE,
 [string]$SourcesFile='',[string]$OutputRoot='',
 [string]$SevenZipPath='E:\Scoop\shims\7z.exe',[switch]$SkipSystemExport,
 [ValidateSet('ServerCopy','Upload')][string]$CloudLatestMode='ServerCopy'
)
if(-not $SourcesFile){$SourcesFile=Join-Path $PSScriptRoot 'sources.psd1'}
if(-not $OutputRoot){$OutputRoot=$PSScriptRoot}
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Backup.Common.ps1')
. (Join-Path $PSScriptRoot 'DevConfig.Sources.ps1')
. (Join-Path $PSScriptRoot 'Initialize-BackupNetwork.ps1')
$script:GDriveRemoteWasExplicit=$PSBoundParameters.ContainsKey('GDriveRemote')
$Tier=@(@($Tier)|ForEach-Object{$_-split ','}|ForEach-Object{$_.Trim()}|Where-Object{$_}|Select-Object -Unique)
if($Tier.Count-eq 0 -or @($Tier|Where-Object{$_-notin @('Local','Hot','Drive')}).Count){throw 'invalid_backup_tier'}
$cfg=Import-PowerShellDataFile -LiteralPath $SourcesFile -ErrorAction Stop
$OutputRoot=Resolve-BackupPath $OutputRoot;$OutDir=Join-Path $OutputRoot 'out';$StateDir=Join-Path $OutputRoot 'state';$StageParent=Join-Path $OutputRoot 'staging'
$HotRoot=Resolve-BackupPath $HotRoot
if($Tier-contains 'Hot'){Assert-BackupPathsIndependent $OutDir $HotRoot}
function Test-HotRootAvailable([string]$Path){
 try{$root=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path));$null=[IO.Directory]::GetFileSystemEntries($root);return $true}catch{return $false}
}
function Push-Hot($Pack){
 Assert-BackupPathsIndependent $OutDir $HotRoot
 for($attempt=1;$attempt-le 3;$attempt++){
  if(-not (Test-HotRootAvailable $HotRoot)){if($attempt-lt 3){Start-Sleep -Seconds 30;continue};throw 'hot_backup_root_unavailable'}
  $hotLease=Open-BackupResourceLock $HotRoot
  try{Publish-DevConfigPackage $Pack $HotRoot $KeepHot;return}finally{$hotLease.Dispose()}
 }
}
function Push-Drive($Pack){
 $rclone=Get-BackupExecutable rclone -FallbackPath 'E:\Scoop\shims\rclone.exe';$env:PATH=[IO.Path]::GetDirectoryName($rclone)+';'+$env:PATH
 $network=Initialize-BackupNetwork
 $resolved=Resolve-ConfiguredRcloneRemote -Remote $GDriveRemote -RemoteWasExplicit $script:GDriveRemoteWasExplicit -BindingPath (Join-Path $StateDir 'rclone-remote-binding.json')
 if(-not $resolved.Success){throw ('drive_remote_unavailable:'+ $resolved.Reason)}
 if([string]::IsNullOrWhiteSpace($GDriveFolder) -or $GDriveFolder-match '(^|[/\\])\.\.([/\\]|$)|^[/\\]'){throw 'drive_folder_invalid'}
 $remote=$resolved.Remote;$dest=$remote+$GDriveFolder.TrimEnd('/','\')
 $preflight=Invoke-RcloneDrivePreflight -Remote $remote
 if(-not $preflight.Success){throw ('drive_preflight_failed:'+ $preflight.Category)}
 $flags=@('--checksum','--bwlimit',$BwLimit,'--transfers','1','--tpslimit','8','--tpslimit-burst','8','--retries','3','--low-level-retries','10','--contimeout','20s','--timeout','120s')
 $cachePath=Join-Path $StateDir 'last-uploaded.json';$state=Get-DriveUploadState $cachePath
 $skip=$false
 if(-not $Force){$skip=(Test-DriveUploadSkipEligibility -State $state -Sha256 $Pack.Sha -Remote $remote -Folder $GDriveFolder -DatedName $Pack.Name -DatedLocalPath $Pack.Zip -LatestLocalPath $Pack.Zip).Eligible}
 if(-not $skip){
  Invoke-BackupRclone copyto $Pack.Zip ($dest+'/'+$Pack.Name) @flags *> $null
  if($LASTEXITCODE-ne 0){throw 'drive_dated_upload_failed'}
  $latestSource=if($CloudLatestMode-eq 'ServerCopy'){$dest+'/'+$Pack.Name}else{$Pack.Zip}
  Invoke-BackupRclone copyto $latestSource ($dest+'/latest.zip') @flags *> $null
  if($LASTEXITCODE-ne 0){throw 'drive_latest_upload_failed'}
 }
 foreach($name in @($Pack.Name,'latest.zip')){
  if(-not (Test-RcloneRemoteFileMatchesLocal -LocalPath $Pack.Zip -RemotePath ($dest+'/'+$name)).Matches){throw 'drive_package_verification_failed'}
  foreach($suffix in @('.receipt.json','.manifest.json','.sha256')){
   $local=$Pack.Zip+$suffix;$target=$dest+'/'+$name+$suffix
   Invoke-BackupRclone copyto $local $target @flags *> $null
   if($LASTEXITCODE-ne 0 -or -not (Test-RcloneRemoteFileMatchesLocal -LocalPath $local -RemotePath $target).Matches){throw 'drive_portable_metadata_verification_failed'}
  }
 }
 $pointer=[ordered]@{schema='devconfig.package-current.v2';status='complete';collection_status='complete';verification_status='complete';destination=$dest;completed_utc=(Get-BackupUtc);package_name=$Pack.Name;sha256=$Pack.Sha;package_bytes=$Pack.Receipt.package_bytes;content_sha256=$Pack.Receipt.content_sha256}
 $pointerFile=Join-Path $StateDir 'drive-current-candidate.json';Write-BackupJsonAtomic $pointerFile $pointer
 Invoke-BackupRclone copyto $pointerFile ($dest+'/current.json') @flags *> $null
 if($LASTEXITCODE-ne 0 -or -not (Test-RcloneRemoteFileMatchesLocal -LocalPath $pointerFile -RemotePath ($dest+'/current.json')).Matches){throw 'drive_current_publication_failed'}
 $names=@(Invoke-BackupRclone lsf $dest --files-only --include 'devconfig-*.zip' --contimeout 20s --timeout 120s --retries 2)
 if($LASTEXITCODE-ne 0){throw 'drive_retention_inventory_failed'}
 $names=@($names|Where-Object{$_-cmatch '^devconfig-[0-9]{8}(?:-[0-9]{6})?(?:-[a-f0-9]{8})?\.zip$'}|Sort-Object -Descending)
 $retained=@($Pack.Name)+@($names|Where-Object{$_-cne $Pack.Name}|Select-Object -First ($KeepDrive-1))
 foreach($name in $names){if($name-notin $retained){
  Invoke-BackupRclone deletefile ($dest+'/'+$name) --contimeout 20s --timeout 120s --retries 2 *> $null;if($LASTEXITCODE-ne 0){throw 'drive_retention_delete_failed'}
  foreach($suffix in @('.receipt.json','.manifest.json','.sha256')){
   # Old pre-v2 packages have no sidecars; lsf is authoritative before deletion.
   $found=@(Invoke-BackupRclone lsf $dest --files-only --include ($name+$suffix) --contimeout 20s --timeout 120s --retries 2)
   if($LASTEXITCODE-ne 0){throw 'drive_retention_inventory_failed'}
   if($found-contains ($name+$suffix)){Invoke-BackupRclone deletefile ($dest+'/'+$name+$suffix) --contimeout 20s --timeout 120s --retries 2 *> $null;if($LASTEXITCODE-ne 0){throw 'drive_retention_delete_failed'}}
  }
 }}
 Write-BackupJsonAtomic $cachePath (New-DriveUploadState -Sha256 $Pack.Sha -Remote $remote -Folder $GDriveFolder -DatedName $Pack.Name)
 Write-BackupJsonAtomic (Join-Path $StateDir 'devconfig-drive-success.json') $pointer
 [IO.File]::WriteAllText((Join-Path $StateDir 'last-drive-success.txt'),(Get-BackupUtc),[Text.Encoding]::ASCII)
}
function New-DevConfigCandidate([string]$Container){
 $stage=Join-Path $Container 'payload';$inventory=Get-DevConfigSourceInventory $cfg $ProfileRoot -IncludeHistory:$IncludeHistory
 Copy-DevConfigSourceInventory $inventory $stage
 $skipped=@($inventory.skipped_files|Select-Object relative_path,reason);$script:run.skipped_file_count=$skipped.Count;$script:run.skipped_files=$skipped
 $script:run.optional_tools_absent=@(if($SkipSystemExport){'system_export_explicitly_skipped'}else{Invoke-DevConfigSystemExport $cfg $stage})
 $binding=Join-Path $StateDir 'rclone-remote-binding.json'
 if([IO.File]::Exists($binding)){$null=Copy-RcloneRemoteBindingToManifest -BindingPath $binding -ManifestDirectory (Join-Path $stage '_manifests')}
 $again=Get-DevConfigSourceInventory $cfg $ProfileRoot -IncludeHistory:$IncludeHistory
 $captureChanges=Test-DevConfigSelectionAfterCapture $inventory $again
 $script:run.capture_consistency='per_file_verified_not_point_in_time';$script:run.changed_after_capture_count=$captureChanges
 $payload=Get-BackupTreeInventory $stage -Hash;$treeHash=Get-BackupInventoryDigest $payload
 $policyHash=Get-BackupTextHash ((Get-BackupStableFileHash $SourcesFile)+'|'+[string]$IncludeHistory+'|'+[string]$SkipSystemExport)
 $contentHash=Get-BackupTextHash ($treeHash+'|'+$policyHash)
 $script:run.collection=$(if($skipped.Count){'complete_with_skipped_files'}else{'complete'});$script:run.package='running';Write-BackupJsonAtomic $runPath $script:run
 $previous=$null;try{$previous=Get-VerifiedDevConfigPackage $OutDir}catch{}
 if($previous -and $previous.Receipt.content_sha256-ceq $contentHash){$script:run.package='reused';return $previous}
 $manifest=[ordered]@{schema='devconfig.payload-manifest.v1';capture_consistency='per_file_verified_not_point_in_time';changed_after_capture_count=$captureChanges;content_sha256=$contentHash;payload_tree_sha256=$treeHash;policy_sha256=$policyHash;file_count=$payload.file_count;bytes=$payload.bytes;directories=$payload.directories;files=@($payload.files|Select-Object relative_path,length,mtime_ticks,sha256);sources=$inventory.sources;skipped_file_count=$skipped.Count;skipped_files=$skipped;application_consistency='not_proven'}
 Write-BackupJsonAtomic (Join-Path $stage 'backup-manifest.json') $manifest
 $name='devconfig-'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.zip';$zip=Join-Path $Container $name
 $zipExe=Get-BackupExecutable 7z -FallbackPath $SevenZipPath
 $zipOutput=@(& $zipExe a -tzip -mcu=on -mx=5 -mmt=4 -bso0 -bsp0 -- $zip ($stage+'\*') 2>&1 | ForEach-Object {$_.ToString()})
 $zipExit=$LASTEXITCODE
 if($zipExit-ne 0 -or -not [IO.File]::Exists($zip)){
  $script:run.pack_native_exit=$zipExit;$script:run.pack_output_lines=$zipOutput.Count
  $script:run.pack_diagnostic=ConvertTo-RcloneSafeDiagnostic -Output $zipOutput
  throw 'backup_pack_failed'
 }
 & $zipExe t -bso0 -bsp0 -- $zip *> $null;if($LASTEXITCODE-ne 0){throw 'backup_archive_test_failed'}
 Assert-BackupArchiveManifest $zip $manifest
 $hash=Get-BackupStableFileHash $zip
 $receipt=[ordered]@{schema='devconfig.package-receipt.v2';zip_entry_encoding='utf-8';capture_consistency='per_file_verified_not_point_in_time';status='complete';collection_status='complete';archive_verification='7z_test_pass';completed_utc=(Get-BackupUtc);package_name=$name;sha256=$hash;package_bytes=(Get-Item $zip).Length;content_sha256=$contentHash;payload_tree_sha256=$treeHash;file_count=$payload.file_count;skipped_file_count=$skipped.Count;collection_warnings=@(if($skipped.Count){'skipped_unreadable_files'});application_recovery='not_tested'}
 Write-BackupJsonAtomic ($zip+'.manifest.json') $manifest;Write-BackupJsonAtomic ($zip+'.receipt.json') $receipt
 [IO.File]::WriteAllText(($zip+'.sha256'),($hash+'  '+$name+"`n"),[Text.Encoding]::ASCII)
 return [pscustomobject]@{Zip=$zip;Sha=$hash;Name=$name;Receipt=[pscustomobject]$receipt;MB=[math]::Round($receipt.package_bytes/1MB,2)}
}
if($Plan){
 $inventory=Get-DevConfigSourceInventory $cfg $ProfileRoot -IncludeHistory:$IncludeHistory
 $prior=$null;$basis='no_verified_previous'
 try{$old=Get-VerifiedDevConfigPackage $OutDir -MetadataOnly;$prior=Read-BackupJson ($old.Zip+'.manifest.json') -Required;$prior.files=@($prior.files|Where-Object{$_.relative_path-match '^(home|appdata-roaming|appdata-local|extra|special)/'});$basis='verified_package_manifest'}catch{}
 $result=[ordered]@{schema='devconfig.backup-plan.v1';write_mode='zero_write';tiers=$Tier;difference=(Get-BackupDifference $inventory $prior);comparison_basis=$basis;source_count=$inventory.source_count;file_count=$inventory.file_count;bytes=$inventory.bytes;optional_absent_count=$inventory.optional_absent_count;sources=$inventory.sources;system_exports='not_run';cloud='not_contacted';out=$OutDir;hot=$HotRoot}
 if($Json){$result|ConvertTo-Json -Depth 8}else{[pscustomobject]$result|Format-List};exit 0
}
$script:overallExitCode=0;$outLease=$null;$pin=$null;$container=$null;$pack=$null
$script:run=[ordered]@{schema='devconfig.run.v2';run_id=[guid]::NewGuid().ToString('N');status='running';started_utc=(Get-BackupUtc);completed_utc=$null;tiers=$Tier;collection='not_requested';package='not_requested';hot='not_requested';drive='not_requested';retention='not_requested';failure=$null;skipped_file_count=0;skipped_files=@();optional_tools_absent=@();application_recovery='not_tested'}
$runPath=Join-Path $StateDir ('devconfig-'+$(if($Tier.Count-eq 1 -and $Tier[0]-eq 'Drive'){'drive'}else{'local'})+'-last.json')
try{
 Write-BackupJsonAtomic $runPath $run
 $outLease=Open-BackupResourceLock $OutDir
 if($Tier-contains 'Local' -or $Tier-contains 'Hot'){
  if($ProfileRoot-match '(?i)[\\/]systemprofile$'){throw 'backup_interactive_user_profile_required'}
  if(-not $SkipSystemExport -and (Resolve-BackupPath $ProfileRoot)-ine (Resolve-BackupPath $env:USERPROFILE)){throw 'system_export_requires_matching_profile'}
  Assert-BackupPathsIndependent $ProfileRoot $OutputRoot
  $run.collection='running';Write-BackupJsonAtomic $runPath $run
  $container=Join-Path $StageParent ('run-'+$run.run_id);[void][IO.Directory]::CreateDirectory($container)
  $pack=New-DevConfigCandidate $container
  $run.retention='running';Publish-DevConfigPackage $pack $OutDir $KeepLocal
  $pack=Get-VerifiedDevConfigPackage $OutDir
  if($run.package-ne 'reused'){$run.package='complete'};$run.retention='complete'
  [IO.File]::WriteAllText((Join-Path $StateDir 'latest.sha256'),($pack.Sha+'  '+$pack.Name),[Text.Encoding]::ASCII)
 }else{$pack=Get-DrivePackageSnapshot -OutDir $OutDir -StateDir $StateDir;$run.package='verified_existing'}
 $pin=[IO.File]::Open($pack.Zip,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 # Serialize collection, publication and retention through the same output lease.
 Write-BackupJsonAtomic $runPath $run
 if($Tier-contains 'Hot'){$run.hot='running';Write-BackupJsonAtomic $runPath $run;try{Push-Hot $pack;$run.hot='complete'}catch{$run.hot='failed';$run.failure=Get-BackupFailureCode $_;$script:overallExitCode=1}}
 if($Tier-contains 'Drive'){$run.drive='running';Write-BackupJsonAtomic $runPath $run;try{Push-Drive $pack;$run.drive='complete'}catch{$run.drive='failed';$run.failure=Get-BackupFailureCode $_;$script:overallExitCode=1}}
 # Skipped unreadable files keep the task successful but are never reported as plain complete.
 $run.status=if($script:overallExitCode-ne 0){'failed'}elseif($run.skipped_file_count-gt 0){'complete_with_skipped_files'}else{'complete'}
}catch{
 $script:overallExitCode=1;$run.status='failed';$run.failure=Get-BackupFailureCode $_;$run.failure_type=$_.Exception.GetType().Name
 $run.failure_site=@($_.ScriptStackTrace-split "`n")[0]
 try{$run.failure_path=Get-BackupFailureSourcePath $_ @(@('profile',$ProfileRoot),@('output',$OutputRoot));$run.failure_io_reason=Get-BackupUnreadableReason $_.Exception}catch{$run.failure_path=$null}
 foreach($phase in @('collection','package','hot','drive','retention')){if($run[$phase]-eq 'running'){$run[$phase]='failed'}}
}finally{
 if($pin){$pin.Dispose()};if($outLease){$outLease.Dispose()}
 if($container -and [IO.Directory]::Exists($container)){try{Remove-BackupOwnedDirectory $container $StageParent '^run-[a-f0-9]{32}$'}catch{$script:overallExitCode=1;$run.status='failed';$run.failure='backup_staging_cleanup_failed'}}
 $run.completed_utc=Get-BackupUtc;try{Write-BackupJsonAtomic $runPath $run}catch{$script:overallExitCode=1;$run.status='failed';$run.failure='backup_status_publication_failed'}
}
if($Json){$run|ConvertTo-Json -Depth 8}else{[pscustomobject]$run|Format-List}
exit $script:overallExitCode
