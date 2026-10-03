# Source inventory preserves the original selection; failures are never successful absence.
$script:DevConfigSQLiteHelper=Join-Path $PSScriptRoot 'DevConfig.Sqlite.py'
function Get-DevConfigSourceInventory {
 param($Config,[string]$ProfileRoot,[switch]$IncludeHistory,[switch]$Hash,$KnownInventory=$null)
 $profile=Resolve-BackupPath $ProfileRoot
 $null=[IO.Directory]::GetFileSystemEntries($profile) # Unavailable profile is never an empty configuration.
 $excludeDirs=@($Config.ExcludeDirs);$excludeFiles=@($Config.ExcludeFiles)
 if(-not $IncludeHistory){$excludeDirs+=@($Config.HistoryDirs);$excludeFiles+=@($Config.HistoryFiles)}
 $fileMap=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
 $dirSet=[Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $sources=[Collections.Generic.List[object]]::new()
 $warnings=[Collections.Generic.List[object]]::new()
 function Add-SelectedSource([string]$Source,[string]$Relative,[bool]$IsDirectory){
  if([IO.Path]::IsPathRooted($Relative) -or $Relative-match '(^|[/\\])\.\.([/\\]|$)|[\r\n|:]'){throw 'source_selection_destination_invalid'}
  $Relative=$Relative.Replace('\','/').Trim('/')
  if($Relative-match '(^|/)\.\.(/|$)|[\r\n|:]'){throw 'source_selection_destination_invalid'}
  $required=$Relative-in @($Config.RequiredSources)
  $present=$true
  try{$attributes=[IO.File]::GetAttributes($Source)}
  catch [IO.FileNotFoundException]{$present=$false}
  catch [IO.DirectoryNotFoundException]{$present=$false}
  catch{
   $warning=Get-BackupFileWarning $_ $Relative 'scan'
   if($IsDirectory -or -not $warning){throw};Add-BackupFileWarning $warnings $warning;$sources.Add([pscustomobject]@{id=$Relative;status='available_with_file_warning';required=$required});return
  }
  if(-not $present){
   $volume=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Source));$null=[IO.Directory]::GetFileSystemEntries($volume)
   if(-not $IsDirectory -and $KnownInventory -and (@($KnownInventory.files|Where-Object{$_.relative_path-ieq $Relative}).Count -or (Test-BackupWarningPath $Relative $KnownInventory.file_warnings))){
    $priorAv=@($KnownInventory.file_warnings|Where-Object{$_.relative_path-ieq $Relative -and $_.reason-in @('antivirus_blocked','antivirus_removed')})
    $warning=if($priorAv.Count){Get-BackupAntivirusRetryWarning $priorAv[0] $Source}else{[pscustomobject]@{relative_path=$Relative;reason='source_disappeared';error_code=2;stage='source_recheck'}}
    Add-BackupFileWarning $warnings $warning;$sources.Add([pscustomobject]@{id=$Relative;status='available_with_file_warning';required=$required});return
   }
   if($required){throw ('required_backup_source_missing: '+$Relative)}
   $sources.Add([pscustomobject]@{id=$Relative;status='optional_absent';required=$required});return
  }
  if($IsDirectory-ne (($attributes-band [IO.FileAttributes]::Directory)-ne 0)){throw 'backup_source_type_changed'}
  $sources.Add([pscustomobject]@{id=$Relative;status='available';required=$required})
  if($IsDirectory){
   [void]$dirSet.Add($Relative)
   $tree=Get-BackupTreeInventory $Source -ExcludeDirs $excludeDirs -ExcludeFiles $excludeFiles -Hash:$Hash -SkipReparsePoints -RelativePrefix $Relative -ExcludeRelativePaths @($Config.ExcludeRelativePaths) -FileWarnings $warnings -AllowSourceDisappeared
   foreach($directory in $tree.directories){[void]$dirSet.Add($Relative+'/'+$directory)}
   foreach($file in $tree.files){$path=$Relative+'/'+$file.relative_path;$file.relative_path=$path;if($fileMap.ContainsKey($path)){if($fileMap[$path].full_path-ine $file.full_path){throw 'backup_source_destination_collision'}}else{$fileMap.Add($path,$file)}}
   foreach($warning in @($KnownInventory.file_warnings|Where-Object{$_ -and $_.reason-in @('antivirus_blocked','antivirus_removed')})){
    $path=[string]$warning.relative_path;if(-not $path.StartsWith($Relative+'/',[StringComparison]::OrdinalIgnoreCase) -or (Test-BackupWarningPath $path $warnings)){continue}
    if($path-match '(^|/)\.\.(/|$)|[\r\n|]'){throw 'backup_warning_path_invalid'}
    $tail=$path.Substring($Relative.Length+1)
    if((Test-BackupRelativeSelection $tail $excludeDirs $excludeFiles) -and -not (Test-BackupRelativePathExcluded $path @($Config.ExcludeRelativePaths))){Add-BackupFileWarning $warnings (Get-BackupAntivirusRetryWarning $warning (Join-Path $Source $tail))}
   }
  }else{
   if(Test-BackupNameExcluded ([IO.Path]::GetFileName($Source)) $excludeFiles){return}
   try{
    $item=Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    $record=[pscustomobject]@{relative_path=$Relative;full_path=$Source;length=[long]$item.Length;mtime_ticks=[long]$item.LastWriteTimeUtc.Ticks;sha256=$(if($Hash){Get-BackupStableFileHash $Source}else{$null})}
   }catch{$warning=Get-BackupFileWarning $_ $Relative $(if($Hash){'hash'}else{'scan'}) -AllowSourceDisappeared;if(-not $warning){throw};Add-BackupFileWarning $warnings $warning;return}
   if($fileMap.ContainsKey($Relative)){if($fileMap[$Relative].full_path-ine $Source){throw 'backup_source_destination_collision'}}else{$fileMap.Add($Relative,$record)}
  }
 }
 foreach($path in @($Config.HomeFiles)+@($Config.HomePreciseFiles)){if($path){Add-SelectedSource (Join-Path $profile $path) ('home/'+$path) $false}}
 foreach($path in @($Config.HomeDirs)+@($Config.HomePreciseDirs)){if($path){Add-SelectedSource (Join-Path $profile $path) ('home/'+$path) $true}}
 foreach($group in @(@('AppDataRoamingDirs','AppData\Roaming','appdata-roaming',$true),@('AppDataRoamingFiles','AppData\Roaming','appdata-roaming',$false),@('AppDataLocalDirs','AppData\Local','appdata-local',$true),@('AppDataLocalFiles','AppData\Local','appdata-local',$false))){
  foreach($path in @($Config[$group[0]])){if($path){Add-SelectedSource (Join-Path (Join-Path $profile $group[1]) $path) ($group[2]+'/'+$path) $group[3]}}
 }
 foreach($extra in @($Config.ExtraDirs)){if($extra){Add-SelectedSource $extra.Src ('extra/'+$extra.Name) $true}}
 foreach($path in @($Config.SpecialFiles)){if($path){Add-SelectedSource (Join-Path $profile $path) ('special/'+$path) $false}}
 foreach($required in @($Config.RequiredSources)){if($required -and $required-notin @($sources|ForEach-Object{$_.id})){throw 'required_backup_source_not_declared'}}
 # Parent directories are part of the same deterministic logical tree.
 foreach($key in @($fileMap.Keys)+@($warnings|ForEach-Object{$_.relative_path})){$parent=[IO.Path]::GetDirectoryName($key).Replace('\','/');while($parent){[void]$dirSet.Add($parent);$next=[IO.Path]::GetDirectoryName($parent);$parent=if($next){$next.Replace('\','/')}else{''}}}
 [string[]]$keys=@($fileMap.Keys);[Array]::Sort($keys,[StringComparer]::OrdinalIgnoreCase)
 $files=@($keys|ForEach-Object{$fileMap[$_]});[long]$bytes=0;foreach($file in $files){$bytes+=$file.length}
 $sqlitePaths=@($files|Where-Object{$_.relative_path-like '*.sqlite' -and (Test-BackupNameExcluded $_.relative_path @($Config.SQLiteBackupRelativePaths))}|ForEach-Object{$_.relative_path})
 return [pscustomobject]@{root=$profile;files=$files;directories=@($dirSet);sources=@($sources);file_count=$files.Count;bytes=$bytes;source_count=$sources.Count;optional_absent_count=@($sources|Where-Object{$_.status-eq 'optional_absent'}).Count;hashes_computed=[bool]$Hash;file_warnings=$warnings.ToArray();sqlite_paths=$sqlitePaths}
}
function Get-DevConfigSQLiteSourceSignature($Inventory,[string]$Path){
 $rows=@($Inventory.files|Where-Object{$_.relative_path-ieq $Path -or $_.relative_path-ieq ($Path+'-wal') -or $_.relative_path-ieq ($Path+'-shm') -or $_.relative_path-ieq ($Path+'-journal')}|ForEach-Object{$_.relative_path+'|'+$_.length+'|'+$_.mtime_ticks})
 return Get-BackupTextHash ($rows-join "`n")
}
function Copy-DevConfigSQLiteDatabase([string]$Source,[string]$Destination,[string]$ScratchRoot){
 $python=Get-BackupExecutable python
 $snapshot=Join-Path $ScratchRoot ('sqlite-'+[guid]::NewGuid().ToString('N')+'.tmp')
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$python
 $start.Arguments='-I -B '+((@($script:DevConfigSQLiteHelper,$Source,$snapshot)|ForEach-Object{'"'+$_+'"'})-join ' ')
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $process=[Diagnostics.Process]::new();$process.StartInfo=$start
 try{
  [void]$process.Start()
  if(-not $process.WaitForExit(20000)){
   $process.Kill();$process.WaitForExit();$timeout=[TimeoutException]::new('backup_sqlite_capture_failed');$timeout.Data['backup_sqlite_reason']='timeout';throw $timeout
  }
  $reply=$process.StandardOutput.ReadToEnd();$null=$process.StandardError.ReadToEnd();$code=$process.ExitCode
 }finally{$process.Dispose()}
 if($code-ne 0){
  $failure=[InvalidOperationException]::new('backup_sqlite_capture_failed')
  try{$detail=$reply|ConvertFrom-Json;$failure.Data['backup_sqlite_error_code']=[int]$detail.sqlite_error_code;$failure.Data['backup_sqlite_reason']=[string]$detail.reason}catch{}
  throw $failure
 }
 $result=$reply|ConvertFrom-Json
 if($result.status-cne 'complete' -or $result.method-cne 'sqlite_online_backup' -or $result.integrity_check-cne 'ok'){throw 'backup_sqlite_capture_failed'}
 $hash=Get-BackupStableFileHash $snapshot;Copy-BackupFileVerified $snapshot $Destination $hash
 return $hash
}
function Test-DevConfigSQLiteSidecar([string]$Path,$Snapshots){
 foreach($snapshot in @($Snapshots)){foreach($suffix in @('-wal','-shm','-journal')){if($Path-ieq ($snapshot.relative_path+$suffix)){return $true}}};return $false
}
function Test-DevConfigRequiredPath([string]$RelativePath,$Inventory){
 foreach($source in @($Inventory.sources|Where-Object{$_.required})){$id=[string]$source.id;if($RelativePath-ieq $id -or $RelativePath.StartsWith($id+'/',[StringComparison]::OrdinalIgnoreCase)){return $true}};return $false
}
function Copy-DevConfigSourceInventory($Inventory,[string]$Destination){
 # A single file held open exclusively (or ACL-denied) by a running application is
 # skipped and reported; required sources and every other failure stay fatal.
 [void][IO.Directory]::CreateDirectory($Destination)
 foreach($directory in @($Inventory.directories)){[void][IO.Directory]::CreateDirectory((Join-Path $Destination $directory))}
 $kept=[Collections.Generic.List[object]]::new();$skipped=[Collections.Generic.List[object]]::new();$warnings=[Collections.Generic.List[object]]::new();foreach($warning in @($Inventory.file_warnings)){Add-BackupFileWarning $warnings $warning};$since=[DateTimeOffset]::UtcNow
 $snapshots=[Collections.Generic.List[object]]::new()
 foreach($file in @($Inventory.files)){
  # The base sorts before its sidecars. Exclude them only after its online backup succeeded.
  if(Test-DevConfigSQLiteSidecar $file.relative_path $snapshots){continue}
  $sqlite=$file.relative_path-in @($Inventory.sqlite_paths)
  $signature=if($sqlite){Get-DevConfigSQLiteSourceSignature $Inventory $file.relative_path}else{$null}
  $target=Join-Path $Destination $file.relative_path
  for($attempt=1;$attempt-le 3;$attempt++){
   $stage='source_read'
   try{
    $before=Get-Item -LiteralPath $file.full_path -Force -ErrorAction Stop
    if($sqlite){
     $stage='sqlite_backup';$hash=Copy-DevConfigSQLiteDatabase $file.full_path $target ([IO.Path]::GetDirectoryName($Destination))
     [IO.File]::SetLastWriteTimeUtc($target,$before.LastWriteTimeUtc)
     $captured=Get-Item -LiteralPath $target -Force -ErrorAction Stop
     $file.sha256=$hash;$file.length=[long]$captured.Length;$file.mtime_ticks=[long]$captured.LastWriteTimeUtc.Ticks
     $file|Add-Member -NotePropertyName sqlite_source_signature -NotePropertyValue $signature -Force
     $snapshots.Add([pscustomobject]@{relative_path=$file.relative_path;method='sqlite_online_backup';integrity_check='ok'})
     $kept.Add($file);break
    }
    $stage='hash';$hash=Get-BackupStableFileHash $file.full_path
    $stage='copy'
    Copy-BackupFileVerified $file.full_path $target $hash
    $stage='source_recheck';$after=Get-Item -LiteralPath $file.full_path -Force -ErrorAction Stop
    if($before.Length-ne $after.Length -or $before.LastWriteTimeUtc.Ticks-ne $after.LastWriteTimeUtc.Ticks){throw 'backup_source_changed_during_capture'}
    $file.sha256=$hash;$file.length=[long]$after.Length;$file.mtime_ticks=[long]$after.LastWriteTimeUtc.Ticks
    $kept.Add($file);break
   }catch{
    $_.Exception.Data['backup_source_path']=$file.full_path;$_.Exception.Data['backup_source_relative_path']=$file.relative_path
    $copyStage=[string]$_.Exception.Data['backup_file_stage'];if($copyStage){$stage=$copyStage}
    $warning=Get-BackupFileWarning $_ $file.relative_path $stage -AllowSourceDisappeared:(-not $stage.StartsWith('destination_'))
    if(-not $warning -and $stage.StartsWith('destination_')){$warning=Get-BackupDestinationWarning $_ ([string]$_.Exception.Data['backup_destination_path']) $file.relative_path $stage $since}
    if($warning){Add-BackupFileWarning $warnings $warning;break}
    $reason=Get-BackupUnreadableReason $_.Exception
    $retryable=$_.Exception.Message-match 'backup_source_changed|backup_copy_hash_mismatch' -or ($reason-ne 'access_denied' -and ($_.Exception-is [IO.IOException] -or $_.Exception.InnerException-is [IO.IOException]))
    if($sqlite -and ($_.Exception.Data['backup_sqlite_error_code']-in @(5,6) -or $_.Exception.Data['backup_sqlite_reason']-eq 'timeout')){$retryable=$true}
    if($attempt-lt 3 -and $retryable){Start-Sleep -Milliseconds 150;continue}
    if($sqlite){throw} # Never fall back to raw copies or skipped database payloads.
    if(-not $reason){throw}
    if(Test-DevConfigRequiredPath $file.relative_path $Inventory){
     $required=[Management.Automation.RuntimeException]::new('required_backup_source_unreadable',$_.Exception)
     $required.Data['backup_source_relative_path']=$file.relative_path;$required.Data['backup_unreadable_reason']=$reason;throw $required
    }
    if([IO.File]::Exists($target)){[IO.File]::Delete($target)}
    $skipped.Add([pscustomobject]@{relative_path=$file.relative_path;reason=$reason});break
   }
  }
 }
 $Inventory.files=$kept.ToArray();$Inventory.file_count=$kept.Count
 $Inventory|Add-Member -NotePropertyName skipped_files -NotePropertyValue $skipped.ToArray() -Force
 $Inventory|Add-Member -NotePropertyName file_warnings -NotePropertyValue @($warnings|Where-Object{-not (Test-DevConfigSQLiteSidecar $_.relative_path $snapshots)}) -Force
 $Inventory|Add-Member -NotePropertyName sqlite_snapshots -NotePropertyValue $snapshots.ToArray() -Force
 $Inventory.bytes=[long](($Inventory.files|Measure-Object length -Sum).Sum)
}
function Test-DevConfigSelectionAfterCapture($Captured,$Current){
 # Per-file capture is not a point-in-time application snapshot. Changes to files
 # already captured are counted, while changed selection (missing/new paths) fails.
 # Files reported as skipped during capture are compared only by their absence here.
 $skippedPaths=@{};foreach($entry in @($Captured.skipped_files)){if($entry){$skippedPaths[[string]$entry.relative_path]=$true}}
 $warnings=[Collections.Generic.List[object]]::new();foreach($warning in @($Captured.file_warnings)+@($Current.file_warnings)){if(-not (Test-DevConfigSQLiteSidecar $warning.relative_path $Captured.sqlite_snapshots)){Add-BackupFileWarning $warnings $warning}}
 $currentPaths=@{};foreach($file in $Current.files){$currentPaths[$file.relative_path]=$true}
 foreach($file in $Captured.files){if(-not $currentPaths.ContainsKey($file.relative_path) -and -not (Test-BackupWarningPath $file.relative_path $warnings)){Add-BackupFileWarning $warnings ([pscustomobject]@{relative_path=$file.relative_path;reason='source_disappeared';error_code=2;stage='source_recheck'})}}
 $Captured.file_warnings=$warnings.ToArray();$leftInventory=Get-BackupInventoryWithoutWarnings $Captured $warnings;$rightInventory=Get-BackupInventoryWithoutWarnings $Current $warnings
 $currentFiles=@($rightInventory.files|Where-Object{-not $skippedPaths.ContainsKey([string]$_.relative_path) -and -not (Test-DevConfigSQLiteSidecar $_.relative_path $Captured.sqlite_snapshots)})
 $left=@(@($leftInventory.directories|ForEach-Object{'d|'+$_})+@($leftInventory.files|ForEach-Object{'f|'+$_.relative_path}))
 $right=@(@($rightInventory.directories|ForEach-Object{'d|'+$_})+@($currentFiles|ForEach-Object{'f|'+$_.relative_path}))
 if(($left-join "`n")-cne ($right-join "`n")){
  $leftSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$rightSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($row in $left){[void]$leftSet.Add($row)};foreach($row in $right){[void]$rightSet.Add($row)}
  $failure=[Management.Automation.RuntimeException]::new('backup_source_selection_changed_during_collection')
  $failure.Data['backup_stage']='selection_recheck';$failure.Data['backup_selection_added_count']=@($right|Where-Object{-not $leftSet.Contains($_)}).Count;$failure.Data['backup_selection_removed_count']=@($left|Where-Object{-not $rightSet.Contains($_)}).Count;throw $failure
 }
 $byPath=@{};foreach($file in $Captured.files){$byPath[$file.relative_path]=$file}
 $changes=0;foreach($file in $currentFiles){$old=$byPath[$file.relative_path];if($old.PSObject.Properties['sqlite_source_signature']){if($old.sqlite_source_signature-cne (Get-DevConfigSQLiteSourceSignature $Current $file.relative_path)){$changes++}}elseif($old.length-ne $file.length -or $old.mtime_ticks-ne $file.mtime_ticks){$changes++}}
 return $changes
}

function Invoke-DevConfigSourceCapture {
 param($Config,[string]$ProfileRoot,[string]$Container,[switch]$IncludeHistory,$KnownInventory=$null,[ValidateRange(1,10)][int]$MaxAttempts=3,[scriptblock]$PostCapture)
 $history=[Collections.Generic.List[object]]::new();$disappeared=[Collections.Generic.List[object]]::new()
 for($attempt=1;$attempt-le $MaxAttempts;$attempt++){
  $stage=Join-Path $Container ('payload-'+$attempt);$inventory=$null;$phase='source_scan'
  try{
   $inventory=Get-DevConfigSourceInventory $Config $ProfileRoot -IncludeHistory:$IncludeHistory -KnownInventory $KnownInventory
   $phase='source_capture';Copy-DevConfigSourceInventory $inventory $stage
   if($PostCapture){$phase='capture_metadata';& $PostCapture $stage}
   $phase='selection_recheck';$again=Get-DevConfigSourceInventory $Config $ProfileRoot -IncludeHistory:$IncludeHistory -KnownInventory $inventory
   $changes=Test-DevConfigSelectionAfterCapture $inventory $again
   $gone=@($inventory.file_warnings|Where-Object{$_ -and $_.reason-ceq 'source_disappeared'})
   foreach($warning in $gone){Add-BackupFileWarning $disappeared $warning}
   # A vanished selected file is also a collection-set change. A fresh whole round
   # can stabilize, while the original single-file warning protects its old package this run.
   if($gone.Count){
    $failure=[Management.Automation.RuntimeException]::new('backup_source_selection_changed_during_collection')
    $failure.Data['backup_stage']=$phase;$failure.Data['backup_selection_added_count']=0;$failure.Data['backup_selection_removed_count']=$gone.Count;throw $failure
   }
   $warnings=[Collections.Generic.List[object]]::new();foreach($warning in @($inventory.file_warnings)){Add-BackupFileWarning $warnings $warning}
   $captured=@{};foreach($file in $inventory.files){$captured[$file.relative_path]=$true}
   foreach($warning in $disappeared){if(-not $captured.ContainsKey($warning.relative_path)){Add-BackupFileWarning $warnings $warning}}
   $inventory.file_warnings=$warnings.ToArray()
   return [pscustomobject]@{stage=$stage;inventory=$inventory;changed_after_capture_count=$changes;attempt_count=$attempt;max_attempts=$MaxAttempts;retry_history=$history.ToArray()}
  }catch{
   if($inventory){foreach($warning in @($inventory.file_warnings|Where-Object{$_ -and $_.reason-ceq 'source_disappeared'})){Add-BackupFileWarning $disappeared $warning}}
   $_.Exception.Data['backup_capture_attempt_count']=$attempt;$_.Exception.Data['backup_capture_max_attempts']=$MaxAttempts;$_.Exception.Data['backup_capture_retry_history']=$history.ToArray()
   $_.Exception.Data['backup_stage']=$phase
   $reason=Get-BackupFailureCode $_;$retryable=$reason-ceq 'backup_source_selection_changed_during_collection'
   if(-not $retryable){throw}
   $history.Add([pscustomobject]@{attempt=$attempt;stage=$phase;reason=$reason;added_count=[int]$_.Exception.Data['backup_selection_added_count'];removed_count=[int]$_.Exception.Data['backup_selection_removed_count']})
   $_.Exception.Data['backup_capture_retry_history']=$history.ToArray()
   if($attempt-eq $MaxAttempts){throw}
   Start-Sleep -Milliseconds 150
  }
 }
}

function Invoke-DevConfigSystemExport($Config,[string]$Stage,$FileWarnings=$null,$KnownWarnings=@()){
 $system=Join-Path $Stage '_system';$man=Join-Path $Stage '_manifests';$missing=[Collections.Generic.List[string]]::new();$since=[DateTimeOffset]::UtcNow
 [void][IO.Directory]::CreateDirectory($system);[void][IO.Directory]::CreateDirectory($man)
 foreach($entry in @($Config.RegistryExports)){
  $path=([string]$entry.Key).Replace('HKCU\','Registry::HKEY_CURRENT_USER\').Replace('HKLM\','Registry::HKEY_LOCAL_MACHINE\')
  try{$null=Get-Item -LiteralPath $path -ErrorAction Stop}catch{if($_.CategoryInfo.Category-eq [Management.Automation.ErrorCategory]::ObjectNotFound){$missing.Add('registry:'+ $entry.Name);continue};throw}
  & reg.exe export $entry.Key (Join-Path $system ($entry.Name+'.reg')) /y *> $null
  if($LASTEXITCODE-ne 0){throw 'registry_export_failed'}
 }
 [IO.File]::WriteAllText((Join-Path $system 'path-machine.txt'),[Environment]::GetEnvironmentVariable('Path','Machine'),[Text.UTF8Encoding]::new($false))
 $tasks=Join-Path $system 'tasks';[void][IO.Directory]::CreateDirectory($tasks)
 foreach($task in @(Get-ScheduledTask -ErrorAction Stop)){
  if(-not (Test-BackupNameExcluded $task.TaskName @($Config.ScheduledTaskPatterns))){continue}
  $id=(Get-BackupTextHash ($task.TaskPath+$task.TaskName)).Substring(0,12);$name=($task.TaskName-replace '[^\w-]','_')+'-'+$id+'.xml'
  $xml=Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
  [IO.File]::WriteAllText((Join-Path $tasks $name),$xml,[Text.Encoding]::Unicode)
 }
 $hosts=Join-Path $env:WINDIR 'System32\drivers\etc\hosts';$hostSeen=$false
 try{$null=Get-Item -LiteralPath $hosts -Force -ErrorAction Stop;$hostSeen=$true;Copy-BackupFileVerified $hosts (Join-Path $system 'hosts') (Get-BackupStableFileHash $hosts)}catch{
  if($null-eq $FileWarnings){throw};$stageCode=[string]$_.Exception.Data['backup_file_stage'];if(-not $stageCode){$stageCode='system_export_source'}
  $warning=Get-BackupFileWarning $_ '_system/hosts' $stageCode -AllowSourceDisappeared:($hostSeen -and -not $stageCode.StartsWith('destination_'))
  if(-not $warning -and -not $stageCode.StartsWith('destination_')){$priorAv=@($KnownWarnings|Where-Object{$_.relative_path-ceq '_system/hosts'});if($priorAv.Count){$warning=Get-BackupAntivirusRetryWarning $priorAv[0] $hosts}}
  if(-not $warning -and $stageCode.StartsWith('destination_')){$warning=Get-BackupDestinationWarning $_ ([string]$_.Exception.Data['backup_destination_path']) '_system/hosts' $stageCode $since}
  if(-not $warning){throw};Add-BackupFileWarning $FileWarnings $warning
 }
 $wifi=Join-Path $system 'wifi';[void][IO.Directory]::CreateDirectory($wifi)
 & netsh.exe wlan export profile key=clear "folder=$wifi" *> $null
 if($LASTEXITCODE-ne 0){throw 'wifi_profile_export_failed'}
 foreach($definition in @(@('scoop','scoop.json'),@('code','vscode-extensions.txt'),@('cursor','cursor-extensions.txt'))){
  $command=Get-Command $definition[0] -ErrorAction SilentlyContinue|Select-Object -First 1
  if(-not $command){$missing.Add($definition[0]);continue}
  $global:LASTEXITCODE=0
  $text=if($definition[0]-eq 'scoop'){@(& $command.Source export 2>&1)}else{@(& $command.Source --list-extensions 2>&1)}
  if($LASTEXITCODE-ne 0){throw ('software_manifest_export_failed:'+ $definition[0])}
  $file=Join-Path $man $definition[1];[IO.File]::WriteAllText($file,($text-join "`r`n"),[Text.UTF8Encoding]::new($false))
  if($definition[0]-eq 'scoop'){$null=Read-BackupJson $file -Required}
 }
 $winget=Get-Command winget -ErrorAction SilentlyContinue|Select-Object -First 1
 if($winget){& $winget.Source export -o (Join-Path $man 'winget.json') --accept-source-agreements *> $null;if($LASTEXITCODE-ne 0){throw 'winget_export_failed'};$null=Read-BackupJson (Join-Path $man 'winget.json') -Required}else{$missing.Add('winget')}
 Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction Stop|Where-Object{$_.DisplayName}|Select-Object DisplayName,DisplayVersion,Publisher|Sort-Object DisplayName -Unique|Export-Csv (Join-Path $man 'installed-software.csv') -NoTypeInformation -Encoding UTF8
 $jetbrains=Join-Path $env:USERPROFILE 'AppData\Roaming\JetBrains'
 if([IO.Directory]::Exists($jetbrains)){$lines=@(foreach($app in Get-ChildItem $jetbrains -Directory){$plugins=Join-Path $app.FullName 'plugins';if([IO.Directory]::Exists($plugins)){'## '+$app.Name;(Get-ChildItem $plugins -Directory).Name;''}});[IO.File]::WriteAllText((Join-Path $man 'jetbrains-plugins.txt'),($lines-join "`r`n"),[Text.UTF8Encoding]::new($false))}
 return @($missing)
}
