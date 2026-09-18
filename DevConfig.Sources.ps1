# Source inventory preserves the original selection; failures are never successful absence.
function Get-DevConfigSourceInventory {
 param($Config,[string]$ProfileRoot,[switch]$IncludeHistory,[switch]$Hash)
 $profile=Resolve-BackupPath $ProfileRoot
 $null=[IO.Directory]::GetFileSystemEntries($profile) # Unavailable profile is never an empty configuration.
 $excludeDirs=@($Config.ExcludeDirs);$excludeFiles=@($Config.ExcludeFiles)
 if(-not $IncludeHistory){$excludeDirs+=@($Config.HistoryDirs);$excludeFiles+=@($Config.HistoryFiles)}
 $fileMap=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
 $dirSet=[Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $sources=[Collections.Generic.List[object]]::new()
 function Add-SelectedSource([string]$Source,[string]$Relative,[bool]$IsDirectory){
  if([IO.Path]::IsPathRooted($Relative) -or $Relative-match '(^|[/\\])\.\.([/\\]|$)|[\r\n|:]'){throw 'source_selection_destination_invalid'}
  $Relative=$Relative.Replace('\','/').Trim('/')
  if($Relative-match '(^|/)\.\.(/|$)|[\r\n|:]'){throw 'source_selection_destination_invalid'}
  $required=$Relative-in @($Config.RequiredSources)
  $present=$true
  try{$attributes=[IO.File]::GetAttributes($Source)}
  catch [IO.FileNotFoundException]{$present=$false}
  catch [IO.DirectoryNotFoundException]{$present=$false}
  if(-not $present){
   $volume=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Source));$null=[IO.Directory]::GetFileSystemEntries($volume)
   if($required){throw 'required_backup_source_missing'}
   $sources.Add([pscustomobject]@{id=$Relative;status='optional_absent';required=$required});return
  }
  if($IsDirectory-ne (($attributes-band [IO.FileAttributes]::Directory)-ne 0)){throw 'backup_source_type_changed'}
  $sources.Add([pscustomobject]@{id=$Relative;status='available';required=$required})
  if($IsDirectory){
   [void]$dirSet.Add($Relative)
   $tree=Get-BackupTreeInventory $Source -ExcludeDirs $excludeDirs -ExcludeFiles $excludeFiles -Hash:$Hash -SkipReparsePoints -RelativePrefix $Relative -ExcludeRelativePaths @($Config.ExcludeRelativePaths)
   foreach($directory in $tree.directories){[void]$dirSet.Add($Relative+'/'+$directory)}
   foreach($file in $tree.files){$path=$Relative+'/'+$file.relative_path;$file.relative_path=$path;if($fileMap.ContainsKey($path)){if($fileMap[$path].full_path-ine $file.full_path){throw 'backup_source_destination_collision'}}else{$fileMap.Add($path,$file)}}
  }else{
   if(Test-BackupNameExcluded ([IO.Path]::GetFileName($Source)) $excludeFiles){return}
   $item=Get-Item -LiteralPath $Source -Force -ErrorAction Stop
   $record=[pscustomobject]@{relative_path=$Relative;full_path=$Source;length=[long]$item.Length;mtime_ticks=[long]$item.LastWriteTimeUtc.Ticks;sha256=$(if($Hash){Get-BackupStableFileHash $Source}else{$null})}
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
 foreach($key in $fileMap.Keys){$parent=[IO.Path]::GetDirectoryName($key).Replace('\','/');while($parent){[void]$dirSet.Add($parent);$next=[IO.Path]::GetDirectoryName($parent);$parent=if($next){$next.Replace('\','/')}else{''}}}
 [string[]]$keys=@($fileMap.Keys);[Array]::Sort($keys,[StringComparer]::OrdinalIgnoreCase)
 $files=@($keys|ForEach-Object{$fileMap[$_]});[long]$bytes=0;foreach($file in $files){$bytes+=$file.length}
 return [pscustomobject]@{root=$profile;files=$files;directories=@($dirSet);sources=@($sources);file_count=$files.Count;bytes=$bytes;source_count=$sources.Count;optional_absent_count=@($sources|Where-Object{$_.status-eq 'optional_absent'}).Count;hashes_computed=[bool]$Hash}
}
function Copy-DevConfigSourceInventory($Inventory,[string]$Destination){
 [void][IO.Directory]::CreateDirectory($Destination)
 foreach($directory in $Inventory.directories){[void][IO.Directory]::CreateDirectory((Join-Path $Destination $directory))}
 foreach($file in $Inventory.files){Copy-BackupFileVerified $file.full_path (Join-Path $Destination $file.relative_path) $file.sha256}
 Assert-BackupSourceUnchanged $Inventory
}
function Invoke-DevConfigSystemExport($Config,[string]$Stage){
 $system=Join-Path $Stage '_system';$man=Join-Path $Stage '_manifests';$missing=[Collections.Generic.List[string]]::new()
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
 $hosts=Join-Path $env:WINDIR 'System32\drivers\etc\hosts';Copy-BackupFileVerified $hosts (Join-Path $system 'hosts') (Get-BackupStableFileHash $hosts)
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
