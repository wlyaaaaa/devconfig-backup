<#
.SYNOPSIS
  Plan or extract a hash-verified DevConfig package; preserve replaced targets.
.DESCRIPTION
  Registry import, account recovery, task recreation and machine-path remapping
  belong to PCConfig. A successful extraction is not application recovery.
#>
[CmdletBinding()]
param([string]$Archive='G:\80_Backup\DevConfig\latest.zip',[string]$Destination='E:\Projects\RecoveryTests\DevConfig',[switch]$Execute,[switch]$ReplaceExisting,[switch]$Json)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Backup.Common.ps1')
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$Archive=Resolve-BackupPath $Archive;$Destination=Resolve-BackupPath $Destination
Assert-BackupPathsIndependent $Archive $Destination;Assert-BackupPathChain $Destination;Assert-BackupPathChain $Archive
$receipt=Read-BackupJson ($Archive+'.receipt.json') -Required;$manifest=Read-BackupJson ($Archive+'.manifest.json') -Required
if($receipt.schema-cne 'devconfig.package-receipt.v2' -or $receipt.status-cne 'complete' -or $receipt.collection_status-cne 'complete' -or $receipt.archive_verification-cne '7z_test_pass' -or $receipt.sha256-cnotmatch '^[a-f0-9]{64}$'){throw 'restore_collection_success_required'}
if($manifest.schema-cne 'devconfig.payload-manifest.v1' -or $manifest.payload_tree_sha256-cne $receipt.payload_tree_sha256 -or $manifest.content_sha256-cne $receipt.content_sha256){throw 'restore_manifest_binding_invalid'}
$item=Get-Item -LiteralPath $Archive -ErrorAction Stop
if($item.Length-ne [long]$receipt.package_bytes -or (Get-BackupStableFileHash $Archive)-cne $receipt.sha256){throw 'restore_archive_hash_mismatch'}
$entryEncoding=Get-BackupArchiveEncoding $Archive $manifest
$entries=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$zip=[IO.Compression.ZipFile]::Open($Archive,[IO.Compression.ZipArchiveMode]::Read,$entryEncoding)
try{
 foreach($entry in $zip.Entries){
  $name=$entry.FullName.Replace('\','/').TrimEnd('/');if(-not $name){continue}
  if($name.StartsWith('/') -or $name-match '(^|/)\.\.(/|$)|:|[\r\n]' -or -not $entries.Add($name)){throw 'restore_archive_entry_invalid'}
  $path=[IO.Path]::GetFullPath((Join-Path $Destination $name));if(-not $path.StartsWith($Destination+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'restore_archive_path_escape'}
 }
 if(-not $entries.Contains('backup-manifest.json')){throw 'restore_internal_manifest_missing'}
 foreach($file in @($manifest.files)){if(-not $entries.Contains([string]$file.relative_path)){throw 'restore_archive_payload_missing'}}
}finally{$zip.Dispose()}
if([IO.File]::Exists($Destination)){throw 'restore_destination_not_directory'}
$nonEmpty=[IO.Directory]::Exists($Destination) -and [IO.Directory]::GetFileSystemEntries($Destination).Length-gt 0
$result=[ordered]@{schema='devconfig.restore-result.v1';mode='plan';write_mode='zero_write';archive=$Archive;destination=$Destination;package_sha256=$receipt.sha256;archive_integrity='sha256_verified';payload_verification='not_extracted';file_count=$manifest.file_count;payload_bytes=$manifest.bytes;existing_target_nonempty=$nonEmpty;replacement_required=($nonEmpty -and -not $ReplaceExisting);rollback_path=$null;application_recovery='not_tested';machine_recovery_owner='PCConfig'}
if(-not $Execute){if($Json){$result|ConvertTo-Json -Depth 6}else{[pscustomobject]$result|Format-List};exit 0}
if($nonEmpty -and -not $ReplaceExisting){throw 'restore_replace_existing_required'}
$lease=Open-BackupResourceLock $Destination;$incoming=$Destination+'.incoming-'+[guid]::NewGuid().ToString('N');$rollback=$null
try{
 $nonEmpty=[IO.Directory]::Exists($Destination) -and [IO.Directory]::GetFileSystemEntries($Destination).Length-gt 0
 if($nonEmpty -and -not $ReplaceExisting){throw 'restore_replace_existing_required'}
 [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$incoming,$entryEncoding)
 $internal=Read-BackupJson (Join-Path $incoming 'backup-manifest.json') -Required
 if($internal.payload_tree_sha256-cne $manifest.payload_tree_sha256 -or $internal.content_sha256-cne $manifest.content_sha256){throw 'restore_internal_manifest_mismatch'}
 $actual=Get-BackupTreeInventory $incoming -Hash;$actual.files=@($actual.files|Where-Object{$_.relative_path-cne 'backup-manifest.json'})
 if((Get-BackupInventoryDigest $actual)-cne $manifest.payload_tree_sha256){throw 'restore_payload_hash_mismatch'}
 if([IO.Directory]::Exists($Destination)){$rollback=$Destination+'.pre-restore-'+[guid]::NewGuid().ToString('N');[IO.Directory]::Move($Destination,$rollback)}
 try{[IO.Directory]::Move($incoming,$Destination)}catch{if($rollback -and -not [IO.Directory]::Exists($Destination)){[IO.Directory]::Move($rollback,$Destination)};throw}
 $result.mode='execute';$result.write_mode='verified_extraction';$result.payload_verification='sha256_full_tree';$result.rollback_path=$rollback
 Write-BackupJsonAtomic ($Destination+'.restore-result.json') $result
}finally{
 if([IO.Directory]::Exists($incoming)){Remove-BackupOwnedDirectory $incoming ([IO.Path]::GetDirectoryName($Destination)) ('^'+[regex]::Escape([IO.Path]::GetFileName($Destination))+'\.incoming-[a-f0-9]{32}$')}
 $lease.Dispose()
}
if($Json){$result|ConvertTo-Json -Depth 6}else{[pscustomobject]$result|Format-List}
exit 0
