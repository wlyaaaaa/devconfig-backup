[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\');$fixture=Join-Path $parent ('devconfig-scheduled-lock-'+[guid]::NewGuid().ToString('N'))
$runtime=(Get-Process -Id $PID).Path;$children=New-Object Collections.ArrayList
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw ('FAIL: '+$Name)};Write-Host ('PASS: '+$Name)}
function Wait-Marker([string]$Path){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not [IO.File]::Exists($Path)){if($clock.Elapsed.TotalSeconds-ge 20){throw 'fixture_marker_timeout'};Start-Sleep -Milliseconds 50}
}
function Start-Run([string]$Tier,[string]$Output,[int]$Wait=5){
 $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$runtime;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
 $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $psi.Arguments='-NoProfile -File "'+$harness+'" -Tier '+$Tier+' -ResourceLockWaitSeconds '+$Wait+' -ProfileRoot "'+$profile+'" -SourcesFile "'+$sources+'" -OutputRoot "'+$Output+'" -SkipSystemExport -Json'
 $p=[Diagnostics.Process]::Start($psi);[void]$children.Add($p);return $p
}
function Finish-Run($Process,[int]$Exit){
 Check ($Process.WaitForExit(20000)) 'Synthetic backup process exits within its test budget'
 $output=$Process.StandardOutput.ReadToEnd()+$Process.StandardError.ReadToEnd()
 if($Process.ExitCode-ne $Exit){throw ('Unexpected entrypoint exit: '+$output)}
 Check $true 'Real entrypoint returns the expected exit code'
}
try{
 [void][IO.Directory]::CreateDirectory($fixture);$profile=Join-Path $fixture 'profile';[void][IO.Directory]::CreateDirectory($profile)
 $sources=Join-Path $fixture 'sources.psd1';[IO.File]::WriteAllText($sources,'@{}')
 # Keep the real parameter, lock, phase order and cleanup path; replace payload/cloud work only in this fixture.
 $stub=@'
function Enter-FixturePhase([string]$Name){
 [IO.File]::WriteAllText((Join-Path $OutputRoot ('held-'+$Name)),'held')
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not [IO.File]::Exists((Join-Path $OutputRoot ('release-'+$Name)))){if($clock.Elapsed.TotalSeconds-ge 20){throw 'fixture_release_timeout'};Start-Sleep -Milliseconds 50}
}
function Get-VerifiedDevConfigPackage([string]$OutDir){
 $zip=Join-Path $OutDir 'synthetic.bin';$script:observed=[IO.File]::ReadAllText($zip)
 return [pscustomobject]@{Zip=$zip;Sha='fixture';Name='synthetic.bin';Receipt=[pscustomobject]@{file_warnings=@()}}
}
function New-DevConfigCandidate {Enter-FixturePhase 'Local';[IO.File]::WriteAllText((Join-Path $OutDir 'synthetic.bin'),'new');Get-VerifiedDevConfigPackage $OutDir}
function Publish-DevConfigPackage {}
function Push-Drive($Pack){Enter-FixturePhase 'Drive';[IO.File]::WriteAllText((Join-Path $OutputRoot 'drive-observed'),$script:observed)}
'@
 $text=[IO.File]::ReadAllText((Join-Path $repo 'Backup-DevConfig.ps1')).Replace('$PSScriptRoot',("'"+$repo.Replace("'","''")+"'"))
 $text=$text.Replace('$script:overallExitCode=0;',$stub+"`n"+'$script:overallExitCode=0;')
 $harness=Join-Path $fixture 'backup-harness.ps1';[IO.File]::WriteAllText($harness,$text,[Text.UTF8Encoding]::new($true))
 foreach($first in @('Local','Drive')){
  $second=if($first-eq 'Local'){'Drive'}else{'Local'};$root=Join-Path $fixture $first;$out=Join-Path $root 'out'
  [void][IO.Directory]::CreateDirectory($out);[IO.File]::WriteAllText((Join-Path $out 'synthetic.bin'),'old')
  $holder=Start-Run $first $root;Wait-Marker (Join-Path $root ('held-'+$first))
  $waiter=Start-Run $second $root;$kind=if($second-eq 'Drive'){'drive'}else{'local'}
  Wait-Marker (Join-Path $root ('state/devconfig-'+$kind+'-last.json'));Start-Sleep -Milliseconds 700
  Check (-not [IO.File]::Exists((Join-Path $root ('held-'+$second)))) ($second+' does not enter while '+$first+' holds the real file lock')
  [IO.File]::WriteAllText((Join-Path $root ('release-'+$first)),'release');Wait-Marker (Join-Path $root ('held-'+$second))
  [IO.File]::WriteAllText((Join-Path $root ('release-'+$second)),'release');Finish-Run $holder 0;Finish-Run $waiter 0
  $expected=if($first-eq 'Local'){'new'}else{'old'}
  Check ([IO.File]::ReadAllText((Join-Path $root 'drive-observed'))-ceq $expected) 'Drive selects the package under its acquired lock, including publication during its wait'
 }
 $root=Join-Path $fixture 'timeout';[void][IO.Directory]::CreateDirectory($root);$held=Open-BackupResourceLock (Join-Path $root 'out')
 try{
  foreach($wait in @(0,1)){
   $p=Start-Run Local $root $wait;Finish-Run $p 1;$run=Read-BackupJson (Join-Path $root 'state/devconfig-local-last.json') -Required
   $expected=if($wait){'backup_resource_wait_timeout'}else{'backup_resource_busy'}
   Check ($run.failure-ceq $expected -and $run.collection-ceq 'not_requested') 'Manual refusal and bounded wait exhaustion both fail without entering collection'
  }
 }finally{$held.Dispose()}
 $denied=Join-Path $fixture 'readonly';[IO.File]::WriteAllText(($denied+'.backup.lock'),'fixture');[IO.File]::SetAttributes(($denied+'.backup.lock'),[IO.FileAttributes]::ReadOnly)
 try{
  foreach($path in @($denied,($fixture+'\invalid'+[char]0))){
   $clock=[Diagnostics.Stopwatch]::StartNew();$errorText=$null;try{$lease=Open-BackupResourceLock $path -WaitSeconds 5;if($lease){$lease.Dispose()}}catch{$errorText=$_.Exception.Message}
   Check ($errorText -and $errorText-notmatch '^backup_resource_(busy|wait_timeout)$' -and $clock.Elapsed.TotalSeconds-lt 2) 'Permission and malformed-path errors fail promptly without being classified as lock contention'
  }
 }finally{[IO.File]::SetAttributes(($denied+'.backup.lock'),[IO.FileAttributes]::Normal)}
 $hidden=Join-Path $fixture 'hidden';[void][IO.Directory]::CreateDirectory($hidden)
 Copy-Item -LiteralPath (Join-Path $repo 'Backup-DevConfig-Hidden.vbs') -Destination $hidden
 [IO.File]::WriteAllText((Join-Path $hidden 'Backup-DevConfig.ps1'),'param($Tier,[int]$ResourceLockWaitSeconds);[IO.File]::WriteAllText((Join-Path $PSScriptRoot ($Tier+".txt")),[string]$ResourceLockWaitSeconds);exit 7')
 foreach($tier in @('Local','Drive')){
  $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=Join-Path $env:WINDIR 'System32/wscript.exe';$psi.Arguments='//B "'+(Join-Path $hidden 'Backup-DevConfig-Hidden.vbs')+'" '+$tier;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
  $p=[Diagnostics.Process]::Start($psi);[void]$children.Add($p);Check ($p.WaitForExit(20000) -and $p.ExitCode-eq 7) 'Actual hidden launcher preserves the business failure exit code'
  $expected=if($tier-eq 'Drive'){'7200'}else{'3600'};Check ([IO.File]::ReadAllText((Join-Path $hidden ($tier+'.txt')))-ceq $expected) 'Actual scheduled launcher supplies its bounded lock-wait budget'
 }
}finally{
 foreach($p in $children){try{if(-not $p.HasExited){$p.Kill();$null=$p.WaitForExit(10000)}}finally{$p.Dispose()}}
 Remove-BackupOwnedDirectory $fixture $parent '^devconfig-scheduled-lock-[a-f0-9]{32}$'
}
