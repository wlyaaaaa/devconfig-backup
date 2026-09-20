# Shared primitives: including this file performs no disk or network mutation.
function Get-BackupUtc { [DateTimeOffset]::UtcNow.ToString('o') }
function Get-BackupTextHash([string]$Text) {
 $sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Resolve-BackupPath([string]$Path){
 if([string]::IsNullOrWhiteSpace($Path)){throw 'backup_path_required'}
 $raw=$Path.Trim()
 $full=if($raw.StartsWith('\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy',[StringComparison]::OrdinalIgnoreCase)){[IO.Path]::GetFullPath($raw)}else{[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($raw))}
 $full=$full.TrimEnd('\','/')
 if($full-eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')){throw 'backup_drive_root_forbidden'};return $full
}
function Test-BackupAdministrator {
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$principal=[Security.Principal.WindowsPrincipal]::new($identity);return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
}
function Get-BackupVssVolumeIdentity([string]$VolumeRoot){
 $root=[IO.Path]::GetFullPath($VolumeRoot);if($root -notmatch '^[A-Za-z]:\\$'){throw 'backup_vss_volume_root_invalid'}
 $drive=$root.Substring(0,1);$volumes=@(Get-Volume -DriveLetter $drive -ErrorAction Stop);if($volumes.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$volumes[0].UniqueId)){throw 'backup_vss_volume_unavailable'};return [string]$volumes[0].UniqueId
}
function Get-BackupVssSourcePath([Parameter(Mandatory)]$Shadow,[Parameter(Mandatory)][string]$Source){
 $sourceFull=Resolve-BackupPath $Source;$volumeRoot=[IO.Path]::GetPathRoot($sourceFull);$device=[string]$Shadow.DeviceObject
 if([string]::IsNullOrWhiteSpace($device) -or $device -notmatch '(?i)HarddiskVolumeShadowCopy[0-9]+$'){throw 'backup_vss_device_invalid'}
 $relative=$sourceFull.Substring($volumeRoot.Length).TrimStart('\','/');$snapshot=if($relative){$device.TrimEnd('\')+'\'+$relative}else{$device.TrimEnd('\')}
 if(-not [IO.Directory]::Exists($snapshot)){throw 'backup_vss_source_snapshot_missing'};return $snapshot
}
function Remove-BackupVssSnapshotExact([Parameter(Mandatory)][string]$ShadowId){
 if($ShadowId -notmatch '^\{[0-9A-Fa-f-]{36}\}$'){throw 'backup_vss_shadow_id_invalid'}
 $targets=@(Get-CimInstance -ClassName Win32_ShadowCopy -Namespace root/cimv2 -ErrorAction Stop|Where-Object{$_.ID-ceq $ShadowId});if($targets.Count -ne 1){throw 'backup_vss_delete_target_not_unique'}
 $targets[0]|Remove-CimInstance -ErrorAction Stop
 if(@(Get-CimInstance -ClassName Win32_ShadowCopy -Namespace root/cimv2 -ErrorAction Stop|Where-Object{$_.ID-ceq $ShadowId}).Count -ne 0){throw 'backup_vss_delete_readback_failed'}
}
function Get-BackupVssJournalPath([string]$StateRoot){return Join-Path (Resolve-BackupPath $StateRoot) 'wechat-vss-active.json'}
function Repair-BackupVssJournal([string]$StateRoot,[string]$VolumeRoot,[string]$Source){
 $journalPath=Get-BackupVssJournalPath $StateRoot;if(-not [IO.File]::Exists($journalPath)){return};$journal=Read-BackupJson $journalPath -Required;$sourceFull=Resolve-BackupPath $Source;$root=[IO.Path]::GetFullPath($VolumeRoot)
 if($journal.schema-cne 'devconfig.wechat-vss-journal.v1' -or $journal.shadow_id-cnotmatch '^\{[0-9A-Fa-f-]{36}\}$' -or [IO.Path]::GetFullPath([string]$journal.volume_root)-ine $root -or [IO.Path]::GetFullPath([string]$journal.source)-ine $sourceFull){throw 'backup_vss_journal_invalid'}
 Remove-BackupVssSnapshotExact ([string]$journal.shadow_id);[IO.File]::Delete($journalPath)
}
function New-BackupVssSnapshot([string]$Source,[string]$StateRoot,[string]$RunId){
 if(-not (Test-BackupAdministrator)){throw 'backup_vss_administrator_required'};$sourceFull=Resolve-BackupPath $Source;$volumeRoot=[IO.Path]::GetPathRoot($sourceFull);$volumeId=Get-BackupVssVolumeIdentity $volumeRoot;Repair-BackupVssJournal $StateRoot $volumeRoot $sourceFull
 $class=[System.Management.ManagementClass]::new('root\cimv2','Win32_ShadowCopy',$null);$shadowId=$null
 try{$parameters=$class.GetMethodParameters('Create');$parameters['Volume']=$volumeRoot;$parameters['Context']='ClientAccessible';$result=$class.InvokeMethod('Create',$parameters,$null);if([uint32]$result['ReturnValue'] -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result['ShadowID'])){throw "backup_vss_create_failed:$([uint32]$result['ReturnValue'])"};$shadowId=[string]$result['ShadowID']}finally{$class.Dispose()}
 $journalPath=Get-BackupVssJournalPath $StateRoot
 try{
  Write-BackupJsonAtomic $journalPath ([ordered]@{schema='devconfig.wechat-vss-journal.v1';shadow_id=$shadowId;volume_root=$volumeRoot;volume_id=$volumeId;source=$sourceFull;snapshot_source=$null;state='created';run_id=$RunId;created_utc=(Get-BackupUtc)})
  $shadow=@(Get-CimInstance -ClassName Win32_ShadowCopy -Namespace root/cimv2 -Filter ("ID='{0}'"-f $shadowId) -ErrorAction Stop);if($shadow.Count -ne 1){throw 'backup_vss_readback_failed'};$shadow=$shadow[0];$expectedVolume=Get-BackupVssVolumeIdentity $volumeRoot;if(-not ([string]$shadow.VolumeName).Equals($volumeId,[StringComparison]::OrdinalIgnoreCase) -or [int]$shadow.State -ne 12 -or -not [bool]$shadow.ClientAccessible -or -not [bool]$shadow.NoAutoRelease){throw 'backup_vss_snapshot_identity_invalid'};$snapshotSource=Get-BackupVssSourcePath $shadow $sourceFull
  Write-BackupJsonAtomic $journalPath ([ordered]@{schema='devconfig.wechat-vss-journal.v1';shadow_id=[string]$shadow.ID;volume_root=$volumeRoot;volume_id=$expectedVolume;source=$sourceFull;snapshot_source=$snapshotSource;state='active';run_id=$RunId;created_utc=(Get-BackupUtc)})
  return [pscustomobject]@{ShadowId=[string]$shadow.ID;SnapshotSource=$snapshotSource;Source=$sourceFull;VolumeRoot=$volumeRoot;JournalPath=$journalPath}
 }catch{try{Remove-BackupVssSnapshotExact $shadowId;if([IO.File]::Exists($journalPath)){[IO.File]::Delete($journalPath)}}catch{};throw}
}
function Remove-BackupVssSnapshot([Parameter(Mandatory)]$Capture){
 Remove-BackupVssSnapshotExact ([string]$Capture.ShadowId);$journalPath=[string]$Capture.JournalPath;if($journalPath -and [IO.File]::Exists($journalPath)){[IO.File]::Delete($journalPath)}
}
function Assert-BackupPathChain([string]$Path){
 $current=[IO.Path]::GetFullPath($Path)
 while($current){
  try{$a=[IO.File]::GetAttributes($current);if(($a-band [IO.FileAttributes]::ReparsePoint)-ne 0){throw 'backup_reparse_target_forbidden'}}
  catch [IO.FileNotFoundException]{} catch [IO.DirectoryNotFoundException]{}
  $p=[IO.Directory]::GetParent($current);if($null-eq $p){break};$current=$p.FullName
 }
}
function Assert-BackupPathsIndependent([string]$Left,[string]$Right){
 $a=Resolve-BackupPath $Left;$b=Resolve-BackupPath $Right
 if($a.Equals($b,[StringComparison]::OrdinalIgnoreCase) -or $a.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'backup_source_target_overlap'}
}
function Read-BackupJson([string]$Path,[switch]$Required){
 try{$text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8);return ($text|ConvertFrom-Json -ErrorAction Stop)}
 catch [IO.FileNotFoundException]{if($Required){throw 'backup_json_missing'};return $null}
 catch [IO.DirectoryNotFoundException]{if($Required){throw 'backup_json_missing'};return $null}
}
function Write-BackupJsonAtomic([string]$Path,$Value){
 $full=[IO.Path]::GetFullPath($Path);Assert-BackupPathChain $full;$parent=[IO.Path]::GetDirectoryName($full)
 [void][IO.Directory]::CreateDirectory($parent);$temp=Join-Path $parent ('.json-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try{
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 30 -Compress))
  $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
  if([IO.File]::Exists($full)){[IO.File]::Replace($temp,$full,[NullString]::Value)}else{[IO.File]::Move($temp,$full)}
  if((Get-BackupTextHash ([IO.File]::ReadAllText($full)))-cne (Get-BackupTextHash ([Text.Encoding]::UTF8.GetString($bytes)))){throw 'backup_json_readback_failed'}
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Open-BackupResourceLock([string]$Resource){
 $path=Resolve-BackupPath $Resource;Assert-BackupPathChain $path;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
 try{return [IO.File]::Open(($path+'.backup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{throw 'backup_resource_busy'}
}
function Test-BackupNameExcluded([string]$Name,[string[]]$Patterns=@()){foreach($pattern in $Patterns){if($Name-like $pattern){return $true}};return $false}
function Get-BackupStableFileHash([string]$Path){
 $before=[IO.FileInfo]::new($Path);$before.Refresh();$null=$before.Length
 $stream=$null;$algorithm=[Security.Cryptography.SHA256]::Create()
 try{
  $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete),1048576,[IO.FileOptions]::SequentialScan)
  $hash=([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
 }catch{$_.Exception.Data['backup_source_path']=$Path;throw}finally{if($stream){$stream.Dispose()};$algorithm.Dispose()}
 $after=[IO.FileInfo]::new($Path);$after.Refresh();$null=$after.Length
 if($before.Length-ne $after.Length -or $before.LastWriteTimeUtc.Ticks-ne $after.LastWriteTimeUtc.Ticks){throw 'backup_source_changed_during_hash'};return $hash
}
function Get-BackupTreeInventory {
 param([string]$Root,[string[]]$ExcludeDirs=@(),[string[]]$ExcludeFiles=@(),[switch]$Hash,[switch]$SkipReparsePoints,[string]$RelativePrefix='',[string[]]$ExcludeRelativePaths=@())
 $full=Resolve-BackupPath $Root;$attributes=[IO.File]::GetAttributes($full)
 if(($attributes-band [IO.FileAttributes]::Directory)-eq 0){throw 'backup_source_not_directory'}
 $files=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
 $directories=[Collections.Generic.List[string]]::new();$pending=[Collections.Generic.Stack[string]]::new();$pending.Push($full);$excluded=0
 while($pending.Count){
  $directory=$pending.Pop()
  foreach($path in [IO.Directory]::EnumerateFileSystemEntries($directory)){
   $name=[IO.Path]::GetFileName($path);$attr=[IO.File]::GetAttributes($path);$isDirectory=($attr-band [IO.FileAttributes]::Directory)-ne 0
   if(($isDirectory -and (Test-BackupNameExcluded $name $ExcludeDirs)) -or (-not $isDirectory -and (Test-BackupNameExcluded $name $ExcludeFiles))){$excluded++;continue}
   if(($attr-band [IO.FileAttributes]::ReparsePoint)-ne 0){if($SkipReparsePoints){$excluded++;continue};throw 'backup_unhandled_source_reparse'}
   $relative=$path.Substring($full.Length+1).Replace('\','/')
   if($relative-match '[\r\n|]'){throw 'backup_unsupported_path_character'}
   $logical=if($RelativePrefix){$RelativePrefix.TrimEnd('/')+'/'+$relative}else{$relative}
   if(Test-BackupNameExcluded $logical $ExcludeRelativePaths){$excluded++;continue}
   if($isDirectory){$directories.Add($relative);$pending.Push($path);continue}
   $item=[IO.FileInfo]::new($path);$item.Refresh();$null=$item.Length;$digest=if($Hash){Get-BackupStableFileHash $path}else{$null}
   if($files.ContainsKey($relative)){throw 'backup_case_collision'}
   $files.Add($relative,[pscustomobject]@{relative_path=$relative;full_path=$path;length=[long]$item.Length;mtime_ticks=[long]$item.LastWriteTimeUtc.Ticks;sha256=$digest})
  }
 }
 [string[]]$keys=@($files.Keys);[Array]::Sort($keys,[StringComparer]::OrdinalIgnoreCase)
 [string[]]$dirs=$directories.ToArray();[Array]::Sort($dirs,[StringComparer]::OrdinalIgnoreCase)
 $ordered=@($keys|ForEach-Object{$files[$_]});[long]$bytes=0;foreach($file in $ordered){$bytes+=$file.length}
 return [pscustomobject]@{root=$full;files=$ordered;directories=@($dirs);file_count=$ordered.Count;bytes=$bytes;excluded_count=$excluded;hashes_computed=[bool]$Hash}
}
function Get-BackupInventoryDigest($Inventory,[switch]$Metadata){
 $lines=[Collections.Generic.List[string]]::new();$lines.Add('backup-tree-v1')
 foreach($directory in @($Inventory.directories)){$lines.Add('d|'+$directory)}
 foreach($file in @($Inventory.files)){$value=if($Metadata){[string]$file.mtime_ticks}else{[string]$file.sha256};if(-not $Metadata -and $value-cnotmatch '^[a-f0-9]{64}$'){throw 'backup_sha256_required'};$lines.Add(('f|{0}|{1}|{2}'-f $file.relative_path,$file.length,$value))}
 return Get-BackupTextHash ($lines-join "`n")
}
function Assert-BackupSourceUnchanged($Inventory){
 foreach($file in @($Inventory.files)){$now=Get-Item -LiteralPath $file.full_path -Force -ErrorAction Stop;if($now.Length-ne $file.length -or $now.LastWriteTimeUtc.Ticks-ne $file.mtime_ticks){throw 'backup_source_changed_during_collection'}}
}
function Get-BackupDifference($Current,$Previous){
 $known=@{};if($Previous){foreach($file in @($Previous.files)){$known[$file.relative_path]=$file}}
 $added=0;$changed=0;$unknown=0;[long]$bytes=0
 foreach($file in @($Current.files)){
  $old=$known[$file.relative_path];if(-not $old){$added++;$bytes+=$file.length}
  elseif($file.length-ne $old.length -or ($null-ne $old.PSObject.Properties['mtime_ticks'] -and $file.mtime_ticks-ne $old.mtime_ticks)){$changed++;$bytes+=$file.length}
  elseif($null-eq $old.PSObject.Properties['mtime_ticks']){$unknown++}
  $known.Remove($file.relative_path)
 };return [pscustomobject]@{added_files=$added;changed_files=$changed;deleted_files=$known.Count;estimated_copy_bytes=$bytes;unknown_timestamp_comparisons=$unknown;comparison='metadata_estimate_not_content_verification'}
}
function Copy-BackupFileVerified([string]$Source,[string]$Destination,[string]$ExpectedHash){
 $parent=[IO.Path]::GetDirectoryName($Destination);[void][IO.Directory]::CreateDirectory($parent);$temp=Join-Path $parent ('.copy-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try{
  $info=Get-Item -LiteralPath $Source -Force -ErrorAction Stop;$reader=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$writer=$null
  try{$writer=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$reader.CopyTo($writer,131072);$writer.Flush($true)}finally{if($writer){$writer.Dispose()};$reader.Dispose()}
  [IO.File]::SetLastWriteTimeUtc($temp,$info.LastWriteTimeUtc)
  if((Get-BackupStableFileHash $temp)-cne $ExpectedHash.ToLowerInvariant()){throw 'backup_copy_hash_mismatch'}
  if([IO.File]::Exists($Destination)){[IO.File]::Replace($temp,$Destination,[NullString]::Value)}else{[IO.File]::Move($temp,$Destination)}
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Remove-BackupOwnedDirectory([string]$Path,[string]$Parent,[string]$NamePattern){
 # Never remove a bare root: require a named immediate child and an exact caller pattern.
 $full=Resolve-BackupPath $Path;$parentFull=Resolve-BackupPath $Parent
 if([IO.Path]::GetDirectoryName($full)-ine $parentFull -or [IO.Path]::GetFileName($full)-cnotmatch $NamePattern){throw 'backup_cleanup_scope_invalid'}
 Assert-BackupPathChain $full
 if([IO.Directory]::Exists($full)){
  $clear=[IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
  foreach($item in @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop)){
   if(($item.Attributes-band $clear)-ne 0){[IO.File]::SetAttributes($item.FullName,$item.Attributes-band (-bnot $clear))}
  }
  [IO.Directory]::Delete($full,$true)
 }
}
function Get-VerifiedBackupTreeManifest([string]$Destination,[switch]$VerifyContent){
 $dest=Resolve-BackupPath $Destination
 if([IO.File]::Exists($dest+'.backup-transaction.json')){throw 'backup_tree_transaction_pending'}
 $record=Read-BackupJson ($dest+'.backup-manifest.json') -Required
 if($record.schema-cne 'devconfig.tree-manifest.v1' -or $record.status-cne 'complete' -or $record.destination-ine $dest -or $record.content_sha256-cnotmatch '^[a-f0-9]{64}$' -or $record.verification-cne 'sha256_full_tree'){throw 'backup_tree_manifest_invalid'}
 if($VerifyContent -and (Get-BackupInventoryDigest (Get-BackupTreeInventory $dest -Hash))-cne $record.content_sha256){throw 'backup_tree_hash_mismatch'};return $record
}
function Test-BackupTreeReceiptBound([string]$ReceiptPath,[string]$Destination,$Manifest){
 try{
  if([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not [IO.File]::Exists($ReceiptPath)){return $false}
  $receipt=Read-BackupJson $ReceiptPath -Required;$manifestPath=$Destination+'.backup-manifest.json';$item=Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
  return ($receipt.schema-ceq 'wechat.hot-backup-receipt.v2' -and $receipt.status-ceq 'complete' -and $receipt.collection_status-ceq 'complete' -and $receipt.verification_status-ceq 'sha256_full_tree' -and $receipt.retention_status-ceq 'source_follow_verified' -and [string]$receipt.destination-ceq [string]$Destination -and [string]$receipt.generation_id-ceq [string]$Manifest.run_id -and [string]$receipt.content_sha256-ceq [string]$Manifest.content_sha256 -and [long]$receipt.manifest_bytes-eq [long]$item.Length -and [string]$receipt.manifest_sha256-ceq (Get-BackupStableFileHash $manifestPath))
 }catch{return $false}
}
function Repair-BackupTreeTransaction([string]$Destination){
 $dest=Resolve-BackupPath $Destination;$journalPath=$dest+'.backup-transaction.json';$journal=Read-BackupJson $journalPath
 if(-not $journal){return};$name=[IO.Path]::GetFileName($dest);$parent=[IO.Path]::GetDirectoryName($dest)
 if($journal.destination-ine $dest -or $journal.run_id-cnotmatch '^[a-f0-9]{32}$' -or $journal.incoming-ine ($dest+'.incoming-'+$journal.run_id) -or $journal.previous-ine ($dest+'.previous-'+$journal.run_id)){throw 'backup_tree_journal_invalid'}
 $manifestPath=$dest+'.backup-manifest.json';$current=Read-BackupJson $manifestPath
 $hasReceiptBinding=$journal.PSObject.Properties.Name-ccontains 'post_commit_receipt_path' -and -not [string]::IsNullOrWhiteSpace([string]$journal.post_commit_receipt_path)
 $hasManifestBinding=$hasReceiptBinding -and $journal.PSObject.Properties.Name-ccontains 'had_manifest'
 $hasReceiptBackup=$hasReceiptBinding -and $journal.PSObject.Properties.Name-ccontains 'had_receipt'
 $previousManifestPath=$null;if($journal.PSObject.Properties.Name-ccontains 'previous_manifest_path'){$previousManifestPath=[string]$journal.previous_manifest_path}
 $previousReceiptPath=$null;if($journal.PSObject.Properties.Name-ccontains 'previous_receipt_path'){$previousReceiptPath=[string]$journal.previous_receipt_path}
 $oldPreviousPath=$null;if($journal.PSObject.Properties.Name-ccontains 'old_previous_path'){$oldPreviousPath=[string]$journal.old_previous_path}
 if($previousManifestPath -and $previousManifestPath-cne ($dest+'.backup-manifest.previous-'+$journal.run_id+'.json')){throw 'backup_tree_journal_invalid'}
 if($previousReceiptPath -and $hasReceiptBinding -and $previousReceiptPath-cne (([string]$journal.post_commit_receipt_path)+'.previous-'+$journal.run_id+'.json')){throw 'backup_tree_journal_invalid'}
 $currentComplete=$current -and $current.run_id-ceq $journal.run_id -and $current.status-ceq 'complete' -and [IO.Directory]::Exists($dest)
 if($currentComplete -and (-not $hasReceiptBinding -or (Test-BackupTreeReceiptBound ([string]$journal.post_commit_receipt_path) $dest $current))){
  if($previousManifestPath -and [IO.File]::Exists($previousManifestPath)){[IO.File]::Delete($previousManifestPath)}
  if($previousReceiptPath -and [IO.File]::Exists($previousReceiptPath)){[IO.File]::Delete($previousReceiptPath)}
  if($oldPreviousPath){Remove-BackupOwnedDirectory $oldPreviousPath $parent ('^'+[regex]::Escape($name)+'\.previous-[a-f0-9]{32}$')}
  [IO.File]::Delete($journalPath);return
 }
 if([IO.Directory]::Exists($journal.previous)){
  if([IO.Directory]::Exists($dest)){if([IO.Directory]::Exists($journal.incoming)){throw 'backup_tree_recovery_ambiguous'};[IO.Directory]::Move($dest,$journal.incoming)}
  [IO.Directory]::Move($journal.previous,$dest)
 }elseif(-not $journal.had_target -and [IO.Directory]::Exists($dest)){
  if([IO.Directory]::Exists($journal.incoming)){throw 'backup_tree_recovery_ambiguous'};[IO.Directory]::Move($dest,$journal.incoming)
 }
 if($hasManifestBinding){
  if([bool]$journal.had_manifest){
   if(-not $previousManifestPath -or -not [IO.File]::Exists($previousManifestPath)){throw 'backup_tree_recovery_manifest_missing'}
   Copy-BackupFileVerified $previousManifestPath $manifestPath (Get-BackupStableFileHash $previousManifestPath)
  }elseif([IO.File]::Exists($manifestPath)){[IO.File]::Delete($manifestPath)}
  if($previousManifestPath -and [IO.File]::Exists($previousManifestPath)){[IO.File]::Delete($previousManifestPath)}
 }
 if($hasReceiptBinding){
  if($previousReceiptPath -and [IO.File]::Exists($previousReceiptPath)){
   if([bool]$journal.had_receipt){Copy-BackupFileVerified $previousReceiptPath ([string]$journal.post_commit_receipt_path) (Get-BackupStableFileHash $previousReceiptPath)}elseif([IO.File]::Exists([string]$journal.post_commit_receipt_path)){[IO.File]::Delete([string]$journal.post_commit_receipt_path)}
   [IO.File]::Delete($previousReceiptPath)
  }elseif(-not [bool]$journal.had_receipt -and [IO.File]::Exists([string]$journal.post_commit_receipt_path)){[IO.File]::Delete([string]$journal.post_commit_receipt_path)}
 }
 Remove-BackupOwnedDirectory $journal.incoming $parent ('^'+[regex]::Escape($name)+'\.incoming-[a-f0-9]{32}$')
 [IO.File]::Delete($journalPath)
}
function Invoke-VerifiedBackupTree {
 param([string]$Source,[string]$Destination,[string[]]$ExcludeDirs=@(),[string[]]$ExcludeFiles=@(),[switch]$Plan,[switch]$LockHeld,[scriptblock]$PostCommit,[string]$PostCommitReceiptPath='', [string]$SourceIdentity='')
 $src=Resolve-BackupPath $Source;$dest=Resolve-BackupPath $Destination;$sourceIdentityPath=if($SourceIdentity){Resolve-BackupPath $SourceIdentity}else{$src};Assert-BackupPathsIndependent $src $dest;Assert-BackupPathsIndependent $sourceIdentityPath $dest;Assert-BackupPathChain $dest
 if($PostCommit -and [string]::IsNullOrWhiteSpace($PostCommitReceiptPath)){throw 'backup_post_commit_receipt_path_required'}
 if($Plan){
  $inventory=Get-BackupTreeInventory $src -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles
  $old=if([IO.Directory]::Exists($dest)){Get-BackupTreeInventory $dest}else{$null}
  return [pscustomobject]@{write_mode='zero_write';file_count=$inventory.file_count;bytes=$inventory.bytes;difference=(Get-BackupDifference $inventory $old)}
 }
  $lease=$null;$incoming=$null;$committed=$false;$run=[guid]::NewGuid().ToString('N');$parent=[IO.Path]::GetDirectoryName($dest);$leaf=[IO.Path]::GetFileName($dest);$postReceiptPath=if($PostCommit){Resolve-BackupPath $PostCommitReceiptPath}else{$null};$previousManifestBackup=$null;$previousReceiptBackup=$null
 try{
  if(-not $LockHeld){$lease=Open-BackupResourceLock $dest};Repair-BackupTreeTransaction $dest
  $inventory=Get-BackupTreeInventory $src -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles -Hash
   $digest=Get-BackupInventoryDigest $inventory;$manifestPath=$dest+'.backup-manifest.json';$old=Read-BackupJson $manifestPath;$hadManifest=[IO.File]::Exists($manifestPath);$oldPreviousPath=if($old -and $old.previous_path){[string]$old.previous_path}else{$null}
   $hadReceipt=if($postReceiptPath){[IO.File]::Exists($postReceiptPath)}else{$false}
   if($PostCommit){
    if($hadManifest){$previousManifestBackup=$dest+'.backup-manifest.previous-'+$run+'.json';Copy-BackupFileVerified $manifestPath $previousManifestBackup (Get-BackupStableFileHash $manifestPath)}
    if($hadReceipt){$previousReceiptBackup=$postReceiptPath+'.previous-'+$run+'.json';Copy-BackupFileVerified $postReceiptPath $previousReceiptBackup (Get-BackupStableFileHash $postReceiptPath)}
   }
  $incoming=$dest+'.incoming-'+$run;$previous=$dest+'.previous-'+$run
  [void][IO.Directory]::CreateDirectory($incoming)
  foreach($directory in $inventory.directories){[void][IO.Directory]::CreateDirectory((Join-Path $incoming $directory))}
  foreach($file in $inventory.files){
   $target=Join-Path $incoming $file.relative_path;$existing=Join-Path $dest $file.relative_path;$linked=$false
   if([IO.File]::Exists($existing) -and (Get-BackupStableFileHash $existing)-ceq $file.sha256){
    try{New-Item -ItemType HardLink -Path $target -Target $existing -ErrorAction Stop|Out-Null;$linked=$true}catch{if([IO.File]::Exists($target)){throw}}
   }
   if(-not $linked){Copy-BackupFileVerified $file.full_path $target $file.sha256}
  }
  $actual=Get-BackupTreeInventory $incoming -Hash
  if((Get-BackupInventoryDigest $actual)-cne $digest){throw 'backup_candidate_tree_hash_mismatch'}
  $sourceAgain=Get-BackupTreeInventory $src -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles
  if((Get-BackupInventoryDigest $sourceAgain -Metadata)-cne (Get-BackupInventoryDigest $inventory -Metadata)){throw 'backup_source_changed_before_publication'}
  $hadTarget=[IO.Directory]::Exists($dest)
  $record=[ordered]@{schema='devconfig.tree-manifest.v1';status='complete';run_id=$run;completed_utc=(Get-BackupUtc);source=$sourceIdentityPath;destination=$dest;content_sha256=$digest;verification='sha256_full_tree';file_count=$inventory.file_count;bytes=$inventory.bytes;directories=$inventory.directories;files=@($inventory.files|Select-Object relative_path,length,mtime_ticks,sha256);previous_path=$(if($hadTarget){$previous}else{$null})}
   Write-BackupJsonAtomic ($dest+'.backup-transaction.json') @{schema='devconfig.tree-transaction.v1';run_id=$run;destination=$dest;incoming=$incoming;previous=$previous;had_target=$hadTarget;had_manifest=$hadManifest;had_receipt=$hadReceipt;previous_manifest_path=$previousManifestBackup;previous_receipt_path=$previousReceiptBackup;post_commit_receipt_path=$postReceiptPath;old_previous_path=$oldPreviousPath}
   if($hadTarget){[IO.Directory]::Move($dest,$previous)}
   [IO.Directory]::Move($incoming,$dest)
   Write-BackupJsonAtomic ($dest+'.backup-manifest.json') $record
   if($PostCommit){& $PostCommit ([pscustomobject]$record)}
   $committed=$true;[IO.File]::Delete($dest+'.backup-transaction.json')
   if($previousManifestBackup -and [IO.File]::Exists($previousManifestBackup)){[IO.File]::Delete($previousManifestBackup)}
   if($previousReceiptBackup -and [IO.File]::Exists($previousReceiptBackup)){[IO.File]::Delete($previousReceiptBackup)}
   if($oldPreviousPath){Remove-BackupOwnedDirectory $oldPreviousPath $parent ('^'+[regex]::Escape($leaf)+'\.previous-[a-f0-9]{32}$')}
   return [pscustomobject]$record
 }catch{
  if(-not $committed -and [IO.File]::Exists($dest+'.backup-transaction.json')){Repair-BackupTreeTransaction $dest};throw
 }finally{
  if($incoming -and [IO.Directory]::Exists($incoming) -and -not [IO.File]::Exists($dest+'.backup-transaction.json')){Remove-BackupOwnedDirectory $incoming $parent ('^'+[regex]::Escape($leaf)+'\.incoming-[a-f0-9]{32}$')}
  if($lease){$lease.Dispose()}
 }
}
function Get-BackupExecutable([string]$Name,[string]$FallbackPath){
 $command=Get-Command $Name -ErrorAction SilentlyContinue|Select-Object -First 1
 if($command){return $command.Source};if($FallbackPath -and [IO.File]::Exists($FallbackPath)){return $FallbackPath};throw ('backup_dependency_unavailable:'+ $Name)
}
function Get-BackupFailureCode($ErrorRecord){
 $text=$ErrorRecord.Exception.Message
 if($text-match '^([a-z][a-z0-9_]+)(?::[a-z0-9_]+)?$'){return $text};return 'backup_io_or_dependency_failure'
}
function Get-VerifiedDevConfigPackage([string]$OutDir,[switch]$MetadataOnly){
 $OutDir=Resolve-BackupPath $OutDir
 $pointer=Read-BackupJson (Join-Path $OutDir 'current.json') -Required
 if($pointer.schema-cne 'devconfig.package-current.v2' -or $pointer.status-cne 'complete' -or $pointer.package_name-cnotmatch '^devconfig-[0-9]{8}(?:-[0-9]{6})?(?:-[a-f0-9]{8})?\.zip$' -or $pointer.sha256-cnotmatch '^[a-f0-9]{64}$'){throw 'backup_package_pointer_invalid'}
 $zip=Join-Path $OutDir $pointer.package_name;$receipt=Read-BackupJson ($zip+'.receipt.json') -Required;$item=Get-Item -LiteralPath $zip -ErrorAction Stop
 if($receipt.schema-cne 'devconfig.package-receipt.v2' -or $receipt.status-cne 'complete' -or $receipt.collection_status-cne 'complete' -or $receipt.archive_verification-cne '7z_test_pass' -or $receipt.package_name-cne $pointer.package_name -or $receipt.sha256-cne $pointer.sha256 -or [long]$receipt.package_bytes-ne $item.Length){throw 'backup_collection_success_required'}
 if(-not $MetadataOnly -and (Get-BackupStableFileHash $zip)-cne $pointer.sha256){throw 'backup_package_hash_mismatch'}
 return [pscustomobject]@{Zip=$zip;Sha=$pointer.sha256;Name=$pointer.package_name;MB=[math]::Round($item.Length/1MB,2);Receipt=$receipt;Current=$pointer}
}
function Remove-OldDevConfigPackages([string]$Root,[ValidateRange(1,365)][int]$Keep,[string]$CurrentName){
 $files=@(Get-ChildItem -LiteralPath $Root -File -Filter 'devconfig-*.zip' -ErrorAction Stop|Where-Object{$_.Name-cmatch '^devconfig-[0-9]{8}(?:-[0-9]{6})?(?:-[a-f0-9]{8})?\.zip$'}|Sort-Object Name -Descending)
 $retain=@($CurrentName)+@($files|Where-Object{$_.Name-cne $CurrentName}|Select-Object -First ($Keep-1)|ForEach-Object{$_.Name})
 foreach($file in $files){if($file.Name-notin $retain){foreach($suffix in @('','.sha256','.receipt.json','.manifest.json')){$path=$file.FullName+$suffix;if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}}}
}
function Publish-DevConfigPackage($Pack,[string]$Root,[ValidateRange(1,365)][int]$Keep){
 Assert-BackupPathChain $Root;[void][IO.Directory]::CreateDirectory($Root)
 $target=Join-Path $Root $Pack.Name
 if(-not $Pack.Zip.Equals($target,[StringComparison]::OrdinalIgnoreCase)){
  Copy-BackupFileVerified $Pack.Zip $target $Pack.Sha
  foreach($suffix in @('.sha256','.receipt.json','.manifest.json')){Copy-BackupFileVerified ($Pack.Zip+$suffix) ($target+$suffix) (Get-BackupStableFileHash ($Pack.Zip+$suffix))}
 }
 $latest=Join-Path $Root 'latest.zip';Copy-BackupFileVerified $target $latest $Pack.Sha
 foreach($suffix in @('.sha256','.receipt.json','.manifest.json')){Copy-BackupFileVerified ($target+$suffix) ($latest+$suffix) (Get-BackupStableFileHash ($target+$suffix))}
 $receipt=Read-BackupJson ($target+'.receipt.json') -Required
 Write-BackupJsonAtomic (Join-Path $Root 'current.json') @{schema='devconfig.package-current.v2';status='complete';collection_status='complete';verification_status='complete';completed_utc=(Get-BackupUtc);destination=[IO.Path]::GetFullPath($Root).TrimEnd('\');package_name=$Pack.Name;sha256=$Pack.Sha;package_bytes=$receipt.package_bytes;content_sha256=$receipt.content_sha256}
 Remove-OldDevConfigPackages $Root $Keep $Pack.Name
}
function Invoke-BackupRclone {
 [CmdletBinding()]param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments)
 $null=Get-Command rclone -ErrorAction Stop;$ErrorActionPreference='Continue';$global:LASTEXITCODE=-1
 $output=@(& rclone @Arguments 2>&1);$exitCode=$global:LASTEXITCODE;Set-Variable -Name LASTEXITCODE -Value $exitCode -Scope 1
 foreach($line in $output){$line.ToString()}
}

function Get-BackupArchiveEncoding {
 param([Parameter(Mandatory)][string]$Archive,[Parameter(Mandatory)]$Manifest)
 Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
 # New archives explicitly use UTF-8. Older Windows 7-Zip archives can use the
 # source host OEM codepage without the UTF-8 flag; select only by exact manifest
 # path/length agreement, never silently accept mojibake or missing payloads.
 foreach($codepage in @(65001,437,936)){
  $encoding=[Text.Encoding]::GetEncoding($codepage)
  $zip=[IO.Compression.ZipFile]::Open($Archive,[IO.Compression.ZipArchiveMode]::Read,$encoding)
  try {
   $entries=@{};$count=0;$valid=$true
   foreach($entry in $zip.Entries){
    $name=$entry.FullName.Replace('\','/').TrimEnd('/')
    if(-not $name -or $name.StartsWith('/') -or $name-match '(^|/)\.\.(/|$)|:|[\r\n]' -or $entries.ContainsKey($name)){$valid=$false;break}
    $entries[$name]=$entry
    if(-not $entry.FullName.EndsWith('/')){$count++}
   }
   if(-not $entries.ContainsKey('backup-manifest.json') -or $count-ne (@($Manifest.files).Count+1)){$valid=$false}
   if($valid){foreach($file in @($Manifest.files)){$entry=$entries[[string]$file.relative_path];if($null-eq $entry -or [long]$entry.Length-ne [long]$file.length){$valid=$false;break}}}
   if($valid){return $encoding}
  }finally{$zip.Dispose()}
 }
 throw 'backup_archive_manifest_mismatch'
}
function Assert-BackupArchiveManifest {
 param([Parameter(Mandatory)][string]$Archive,[Parameter(Mandatory)]$Manifest)
 $null=Get-BackupArchiveEncoding $Archive $Manifest
}
