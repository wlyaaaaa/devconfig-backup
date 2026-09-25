[CmdletBinding()]
param()
# A single source file held open by a running application is skipped and reported
# instead of failing the whole generation; required sources still fail closed and
# every failure names the offending relative path.
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
 $inventory=Get-DevConfigSourceInventory $config $profile;$failure=$null
 try{Copy-DevConfigSourceInventory $inventory (Join-Path $fixture 'stage-required')}catch{$failure=$_}
 Check ($null-ne $failure -and (Get-BackupFailureCode $failure)-ceq 'required_backup_source_unreadable') 'A locked required source fails the capture'
 Check ((Get-BackupFailureSourcePath $failure)-ceq 'home/.gitconfig') 'Required-source failure names its relative path'
 $required.Dispose();[void]$handles.Remove($required)
 $plain=$null;try{throw 'backup_example_failure'}catch{$_.Exception.Data['backup_source_path']=(Join-Path $profile 'settings\ok.txt');$plain=$_}
 Check ((Get-BackupFailureSourcePath $plain @(,@('profile',$profile)))-ceq 'profile/settings/ok.txt') 'A full source path is reported relative to its root, never as an absolute path'
 Check ($null-eq (Get-BackupUnreadableReason ([IO.FileNotFoundException]::new('gone')))) 'A vanished file is not a skippable lock'

 # End to end: task stays successful but distinguishable; required lock fails with a named path.
 $output=Join-Path $fixture 'output';$hot=Join-Path $fixture 'hot';$sources=Join-Path $fixture 'sources.psd1'
 Put $sources "@{HomeFiles=@('.gitconfig');HomeDirs=@('settings');RequiredSources=@('home/.gitconfig');ExcludeDirs=@();ExcludeFiles=@();HistoryDirs=@();HistoryFiles=@()}"
 $base=@('-ProfileRoot',$profile,'-SourcesFile',$sources,'-OutputRoot',$output,'-HotRoot',$hot,'-SkipSystemExport','-Json','-Tier','Local,Hot')
 $r=Run $base;$run=Read-BackupJson (Join-Path $output 'state\devconfig-local-last.json') -Required
 Check ($r.Exit-eq 0) ('Skipped files do not fail the task: '+$r.Text)
 Check ($run.status-ceq 'complete_with_skipped_files' -and $run.collection-ceq 'complete_with_skipped_files' -and $run.skipped_file_count-eq 2) 'Run receipt distinguishes success with skipped files'
 Check ((@($run.skipped_files|ForEach-Object{$_.relative_path+'='+$_.reason}|Sort-Object)-join ',')-ceq 'home/settings/exclusive.txt=sharing_violation,home/settings/guard.lock=lock_violation') 'Run receipt lists each skipped relative path and reason'
 $pack=Get-VerifiedDevConfigPackage (Join-Path $output 'out');$hotPack=Get-VerifiedDevConfigPackage $hot
 Check ($pack.Sha-ceq $hotPack.Sha -and $pack.Receipt.skipped_file_count-eq 2 -and @($pack.Receipt.collection_warnings)-ccontains 'skipped_unreadable_files') 'Package is published and verified with the skip recorded in its receipt'
 $manifest=Read-BackupJson ($pack.Zip+'.manifest.json') -Required
 Check (@($manifest.files|Where-Object{$_.relative_path-like '*exclusive*' -or $_.relative_path-like '*guard*'}).Count-eq 0 -and $manifest.skipped_file_count-eq 2 -and @($manifest.files|Where-Object{$_.relative_path-ceq 'home/settings/ok.txt'}).Count-eq 1) 'Package manifest lists the skipped files and omits their payload'
 foreach($h in @($handles)){$h.Dispose()};$handles.Clear()
 $r=Run $base;$run=Read-BackupJson (Join-Path $output 'state\devconfig-local-last.json') -Required
 Check ($r.Exit-eq 0 -and $run.status-ceq 'complete' -and $run.skipped_file_count-eq 0) 'Without locks the run is plain complete'
 $pointer=Get-BackupStableFileHash (Join-Path $output 'out\current.json')
 $required=Hold (Join-Path $profile '.gitconfig');$handles.Add($required)
 $r=Run $base;$run=Read-BackupJson (Join-Path $output 'state\devconfig-local-last.json') -Required
 Check ($r.Exit-ne 0 -and $run.status-ceq 'failed' -and $run.failure-ceq 'required_backup_source_unreadable') 'A locked required source fails the task'
 Check ($run.failure_path-ceq 'home/.gitconfig' -and $run.failure_io_reason-ceq 'sharing_violation') 'Failure receipt names the relative path and the lock reason'
 Check ((Get-BackupStableFileHash (Join-Path $output 'out\current.json'))-ceq $pointer) 'Failed run keeps the previous success pointer'
}finally{
 foreach($h in @($handles)){try{$h.Dispose()}catch{}}
 Remove-BackupOwnedDirectory $fixture $parent '^devconfig-locked-[a-f0-9]{32}$'
}
