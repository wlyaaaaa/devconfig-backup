[CmdletBinding()]
param()
# A single source file held open by a running application is skipped and reported
# instead of failing the whole generation. Required files need verified prior bytes.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
. (Join-Path $repo 'DevConfig.Sources.ps1')
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixture=Join-Path $parent ('devconfig-locked-'+[guid]::NewGuid().ToString('N'))
$runtime=(Get-Process -Id $PID).Path
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw ('FAIL: '+$Name)};Write-Host ('PASS: '+$Name)}
function Put([string]$Path,[string]$Text){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Hold([string]$Path){return [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
function Run([string[]]$Arguments){
 $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$text=(& $runtime -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'Backup-DevConfig.ps1') @Arguments 2>&1|Out-String);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 return [pscustomobject]@{Exit=$code;Text=$text}
}
$handles=[Collections.Generic.List[object]]::new()
try{
 # Unit level: sharing violation, byte-range lock violation, required source.
 $profile=Join-Path $fixture 'profile'
 Put (Join-Path $profile '.gitconfig') 'required configuration'
 Put (Join-Path $profile 'settings\ok.txt') 'ordinary configuration'
 Put (Join-Path $profile 'settings\exclusive.txt') 'held without sharing'
 Put (Join-Path $profile 'settings\guard.lock') ''
 $config=@{HomeFiles=@('.gitconfig');HomeDirs=@('settings');RequiredSources=@('home/.gitconfig')}
 $exclusive=Hold (Join-Path $profile 'settings\exclusive.txt');$handles.Add($exclusive)
 # Same shape as the real Clash Verge single-instance guard: empty file, locked range past EOF.
 $guard=[IO.File]::Open((Join-Path $profile 'settings\guard.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite);$handles.Add($guard);$guard.Lock(0,1)
 $inventory=Get-DevConfigSourceInventory $config $profile
 Check ($inventory.file_count-eq 4) 'Inventory still lists every selected file before capture'
 $stage=Join-Path $fixture 'stage-unit'
 Copy-DevConfigSourceInventory $inventory $stage
 $skipped=@($inventory.skipped_files|Sort-Object relative_path)
 Check ($skipped.Count-eq 2) 'Two unreadable files are skipped instead of failing the capture'
 Check ($skipped[0].relative_path-ceq 'home/settings/exclusive.txt' -and $skipped[0].reason-ceq 'sharing_violation') 'Exclusive open is reported by relative path as sharing_violation'
 Check ($skipped[1].relative_path-ceq 'home/settings/guard.lock' -and $skipped[1].reason-ceq 'lock_violation') 'Byte-range lock is reported by relative path as lock_violation'
 Check ($inventory.file_count-eq 2 -and @($inventory.files|Where-Object{$_.relative_path-like '*exclusive*' -or $_.relative_path-like '*guard*'}).Count-eq 0) 'Skipped files are removed from the captured inventory'
 Check ([IO.File]::Exists((Join-Path $stage 'home/settings/ok.txt')) -and -not [IO.File]::Exists((Join-Path $stage 'home/settings/exclusive.txt')) -and -not [IO.File]::Exists((Join-Path $stage 'home/settings/guard.lock'))) 'Readable files are staged and skipped files leave nothing behind'
 Check ((Get-BackupStableFileHash (Join-Path $stage 'home/settings/ok.txt'))-ceq @($inventory.files|Where-Object{$_.relative_path-ceq 'home/settings/ok.txt'})[0].sha256) 'Readable files are still hash verified'
 $again=Get-DevConfigSourceInventory $config $profile
 Check ((Test-DevConfigSelectionAfterCapture $inventory $again)-eq 0) 'A skipped file still present afterwards is not mistaken for a selection change'
 Put (Join-Path $profile 'settings\late.txt') 'new file'
 $refused=$false;try{$null=Test-DevConfigSelectionAfterCapture $inventory (Get-DevConfigSourceInventory $config $profile)}catch{$refused=$_.Exception.Message-eq 'backup_source_selection_changed_during_collection'}
 Check $refused 'New source files still fail the selection check'
 [IO.File]::Delete((Join-Path $profile 'settings\late.txt'))
 $required=Hold (Join-Path $profile '.gitconfig');$handles.Add($required)
 $inventory=Get-DevConfigSourceInventory $config $profile
 Copy-DevConfigSourceInventory $inventory (Join-Path $fixture 'stage-required')
 Check ($inventory.file_warnings[0].relative_path-ceq 'home/.gitconfig' -and $inventory.file_warnings[0].reason-ceq 'sharing_violation') 'A locked required file is reported for package fallback'
 $required.Dispose();[void]$handles.Remove($required)
 $plain=$null;try{throw 'backup_example_failure'}catch{$_.Exception.Data['backup_source_path']=(Join-Path $profile 'settings\ok.txt');$plain=$_}
 Check ((Get-BackupFailureSourcePath $plain @(,@('profile',$profile)))-ceq 'profile/settings/ok.txt') 'A full source path is reported relative to its root, never as an absolute path'
 Check ($null-eq (Get-BackupUnreadableReason ([IO.FileNotFoundException]::new('gone')))) 'A vanished file is not a skippable lock'

 # Required roots stay strict, but an exact runtime mutex is outside the selection.
 Put (Join-Path $profile '.codex/config.toml') 'real configuration'
 Put (Join-Path $profile '.codex/dependency.lock') 'recoverable dependency versions'
 Put (Join-Path $profile '.codex/.sqlite-maintenance.lock') ''
 $maintenance=[IO.File]::Open((Join-Path $profile '.codex/.sqlite-maintenance.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite);$handles.Add($maintenance);$maintenance.Lock(0,1)
 $policy=Import-PowerShellDataFile (Join-Path $repo 'sources.psd1')
 $requiredRoot=@{HomeDirs=@('.codex');RequiredSources=@('home/.codex');ExcludeRelativePaths=$policy.ExcludeRelativePaths}
 $inventory=Get-DevConfigSourceInventory $requiredRoot $profile
 Copy-DevConfigSourceInventory $inventory (Join-Path $fixture 'stage-runtime-mutex')
 Check ($inventory.file_count-eq 2 -and @($inventory.skipped_files).Count-eq 0) 'A locked maintenance mutex does not fail or downgrade the required Codex root'
 $dependency=Hold (Join-Path $profile '.codex/dependency.lock');$handles.Add($dependency)
 $inventory=Get-DevConfigSourceInventory $requiredRoot $profile;Copy-DevConfigSourceInventory $inventory (Join-Path $fixture 'stage-real-lock')
 Check ($inventory.file_count-eq 1 -and $inventory.file_warnings[0].relative_path-ceq 'home/.codex/dependency.lock' -and $inventory.file_warnings[0].reason-ceq 'sharing_violation') 'A locked file in an available required directory is reported while the other file is copied'
 $dependency.Dispose();[void]$handles.Remove($dependency)

 # End to end: partial success, required-file fallback and no prior package.
 $output=Join-Path $fixture 'output';$hot=Join-Path $fixture 'hot';$sources=Join-Path $fixture 'sources.psd1'
 $runtimeLocks=@('appdata-local/Microsoft/PowerToys/settings.json.cli-lock','appdata-roaming/Typora/Local Storage/leveldb/LOCK')
 foreach($relative in $runtimeLocks){
  $sourceRelative=$relative.Replace('appdata-local/','AppData/Local/').Replace('appdata-roaming/','AppData/Roaming/')
  $path=Join-Path $profile $sourceRelative;Put $path ''; $handles.Add((Hold $path))
 }
 Put (Join-Path $profile 'AppData/Local/Microsoft/PowerToys/settings.json') '{"enabled":true}'
 Put (Join-Path $profile 'AppData/Local/Microsoft/PowerToys/dependency.lock') 'version=1'
 Put (Join-Path $profile 'AppData/Roaming/Typora/Local Storage/leveldb/CURRENT') 'MANIFEST-000001'
 Put (Join-Path $profile 'AppData/Roaming/Typora/Local Storage/leveldb/000001.ldb') 'database payload'
 $excludes=(@($policy.ExcludeRelativePaths)|ForEach-Object{"'$_'"})-join ','
 Put $sources "@{HomeFiles=@('.gitconfig');HomeDirs=@('settings');RequiredSources=@('home/.gitconfig');AppDataLocalDirs=@('Microsoft/PowerToys');AppDataRoamingDirs=@('Typora');ExcludeRelativePaths=@($excludes);ExcludeDirs=@();ExcludeFiles=@();HistoryDirs=@();HistoryFiles=@()}"
 $base=@('-ProfileRoot',$profile,'-SourcesFile',$sources,'-OutputRoot',$output,'-HotRoot',$hot,'-SkipSystemExport','-Json','-Tier','Local,Hot')
 $r=Run $base;$run=Read-BackupJson (Join-Path $output 'state\devconfig-local-last.json') -Required
 Check ($r.Exit-eq 0) ('Skipped files do not fail the task: '+$r.Text)
 Check ($run.status-ceq 'complete_with_skipped_files' -and $run.collection-ceq 'complete_with_skipped_files' -and $run.skipped_file_count-eq 2) 'Run receipt distinguishes success with skipped files'
 Check ((@($run.skipped_files|ForEach-Object{$_.relative_path+'='+$_.reason}|Sort-Object)-join ',')-ceq 'home/settings/exclusive.txt=sharing_violation,home/settings/guard.lock=lock_violation') 'Run receipt lists each skipped relative path and reason'
 $pack=Get-VerifiedDevConfigPackage (Join-Path $output 'out');$hotPack=Get-VerifiedDevConfigPackage $hot
 Check ($pack.Sha-ceq $hotPack.Sha -and $pack.Receipt.skipped_file_count-eq 2 -and @($pack.Receipt.collection_warnings)-ccontains 'skipped_unreadable_files') 'Package is published and verified with the skip recorded in its receipt'
 $manifest=Read-BackupJson ($pack.Zip+'.manifest.json') -Required
 foreach($relative in $runtimeLocks){
  foreach($proof in @($run,$pack.Receipt,$manifest)){Check ($relative-in @($proof.intentional_exclusions)) ('Receipt records intentional exclusion: '+$relative)}
  Check ($relative-notin @($manifest.files.relative_path) -and $relative-notin @($manifest.skipped_files.relative_path)) ('Runtime lock is neither payload nor skipped: '+$relative)
 }
 foreach($relative in @('appdata-local/Microsoft/PowerToys/settings.json','appdata-local/Microsoft/PowerToys/dependency.lock','appdata-roaming/Typora/Local Storage/leveldb/CURRENT','appdata-roaming/Typora/Local Storage/leveldb/000001.ldb')){
  Check ($relative-in @($manifest.files.relative_path)) ('Recoverable neighbor remains in package: '+$relative)
 }
 Check (@($manifest.files|Where-Object{$_.relative_path-like '*exclusive*' -or $_.relative_path-like '*guard*'}).Count-eq 0 -and $manifest.skipped_file_count-eq 2 -and @($manifest.files|Where-Object{$_.relative_path-ceq 'home/settings/ok.txt'}).Count-eq 1) 'Package manifest lists the skipped files and omits their payload'
 $majoritySources=Join-Path $fixture 'majority.psd1';Put $majoritySources "@{HomeDirs=@('settings')}"
 $majorityArgs=$base.Clone();$majorityArgs[[array]::IndexOf($majorityArgs,'-SourcesFile')+1]=$majoritySources
 $failed=Run $majorityArgs;$failedRun=Read-BackupJson (Join-Path $output 'state/devconfig-local-last.json') -Required
 Check ($failed.Exit-eq 1 -and $failedRun.status-ceq 'failed' -and $failedRun.failure-ceq 'backup_majority_of_files_skipped' -and @($failedRun.file_warnings).Count-eq 2) ('Majority missed fails and lists both files: '+$failed.Text)
 Check ((Get-VerifiedDevConfigPackage (Join-Path $output 'out')).Name-ceq $pack.Name -and (Get-VerifiedDevConfigPackage $hot).Name-ceq $hotPack.Name) 'Majority missed preserves both previous backup pointers'
 foreach($h in @($handles)){$h.Dispose()};$handles.Clear()
 $r=Run $base;$run=Read-BackupJson (Join-Path $output 'state\devconfig-local-last.json') -Required
 Check ($r.Exit-eq 0 -and $run.status-ceq 'complete' -and $run.skipped_file_count-eq 0) 'Without locks the run is plain complete'
 $previous=Get-VerifiedDevConfigPackage (Join-Path $output 'out')
 Put (Join-Path $profile '.gitconfig') 'new locked configuration'
 $required=Hold (Join-Path $profile '.gitconfig');$handles.Add($required)
 $r=Run $base;$run=Read-BackupJson (Join-Path $output 'state\devconfig-local-last.json') -Required
 $pack=Get-VerifiedDevConfigPackage (Join-Path $output 'out');$warning=$run.file_warnings[0]
 Check ($r.Exit-eq 0 -and $run.status-ceq 'complete_with_skipped_files' -and $pack.Name-cne $previous.Name -and $pack.Sha-ceq (Get-VerifiedDevConfigPackage $hot).Sha) ('A locked required file publishes a new verified package: '+$r.Text)
 Check ($warning.relative_path-ceq 'home/.gitconfig' -and $warning.reason-ceq 'sharing_violation' -and $warning.fallback-ceq 'previous_package') 'Run receipt names the locked required file and its fallback'
 $manifest=Read-BackupJson ($pack.Zip+'.manifest.json') -Required
 $zip=[IO.Compression.ZipFile]::OpenRead($pack.Zip)
 try{$reader=[IO.StreamReader]::new($zip.GetEntry('home/.gitconfig').Open());try{$oldBytes=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$zip.Dispose()}
 Check ($oldBytes-ceq 'required configuration' -and $manifest.file_warnings[0].fallback-ceq 'previous_package' -and [IO.File]::Exists($previous.Zip)) 'New ZIP contains the previous bytes and retains the previous package'
 [pscustomobject]@{exit_code=$r.Exit;status=$run.status;file_warnings=$run.file_warnings;archive_contains_previous_value=($oldBytes-ceq 'required configuration')}|ConvertTo-Json -Depth 5 -Compress
 $empty=$base.Clone();$empty[[array]::IndexOf($empty,'-OutputRoot')+1]=Join-Path $fixture 'empty-output'
 $noPrior=Run $empty
 Check ($noPrior.Exit-eq 1 -and ($noPrior.Text|ConvertFrom-Json).failure-ceq 'required_backup_previous_package_unavailable') 'A locked required file fails without a previous package'
 Put $majoritySources "@{HomeDirs=@('settings');RequiredSources=@('home/settings')}"
 foreach($name in 'exclusive.txt','guard.lock'){$handles.Add((Hold (Join-Path $profile ('settings/'+$name))))}
 $failed=Run $majorityArgs;$failedRun=$failed.Text|ConvertFrom-Json
 Check ($failed.Exit-eq 1 -and $failedRun.failure-ceq 'backup_majority_of_files_skipped' -and $failedRun.file_warnings[0].fallback-ceq 'previous_package') 'Prior copies do not count as current coverage in a required directory'
 Check ((Get-VerifiedDevConfigPackage (Join-Path $output 'out')).Name-ceq $pack.Name) 'A failed majority leaves the previous pointer unchanged'
}finally{
 foreach($h in @($handles)){try{$h.Dispose()}catch{}}
 Remove-BackupOwnedDirectory $fixture $parent '^devconfig-locked-[a-f0-9]{32}$'
}
