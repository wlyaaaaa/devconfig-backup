<#
.SYNOPSIS
  Optional WeChat catchup monitor. No task is installed or enabled by this script.
.DESCRIPTION
  Completion requires a locked, verified native snapshot and exact cloud check,
  not a percentage or byte threshold. All follow-up parameters are preserved.
#>
[CmdletBinding()]
param([string]$LocalRoot='E:\WeChatBackup\xwechat_files',[string]$GDriveRemote='gdrive:',[string]$GDriveFolder='Backups/WeChat/xwechat_files',[string]$MonitorTaskName='WeChatDrive-Monitor-Hourly',[double]$CompletePercent=99.5,[ValidateRange(1,3600)][int]$RcloneTimeoutSec=900,[string]$Source='E:\Documents\xwechat_files',[string]$BwLimit='4M',[string]$MaxTransfer='8G',[switch]$Plan)
$ErrorActionPreference='Stop';$Root=$PSScriptRoot
. (Join-Path $Root 'Backup.Common.ps1')
. (Join-Path $Root 'Initialize-BackupNetwork.ps1')
$remoteExplicit=$PSBoundParameters.ContainsKey('GDriveRemote');$state=Join-Path $Root 'state'
function Write-MonitorLog([string]$Message,[string]$Level='INFO'){Write-Host ($Level+': '+$Message)}
function ConvertTo-BackupProcessArgument([string]$Value){
 if($Value -and $Value-notmatch '[\s"]'){return $Value}
 return '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Invoke-RcloneWithTimeout {
 param([string[]]$Arguments,[int]$TimeoutSec=900,[string]$Purpose='rclone')
 $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=Get-BackupExecutable rclone -FallbackPath 'E:\Scoop\shims\rclone.exe'
 $psi.Arguments=(@($Arguments|ForEach-Object{ConvertTo-BackupProcessArgument $_})-join ' ')
 $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.WorkingDirectory=$Root
 $psi.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$psi.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
 $p=New-Object Diagnostics.Process;$p.StartInfo=$psi
 try{
  [void]$p.Start();$outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
  if(-not $p.WaitForExit($TimeoutSec*1000)){try{$p.Kill();$null=$p.WaitForExit(5000)}catch{};return [pscustomobject]@{ExitCode=124;Stdout='';Stderr='';TimedOut=$true}}
  return [pscustomobject]@{ExitCode=$p.ExitCode;Stdout=$outTask.GetAwaiter().GetResult();Stderr=$errTask.GetAwaiter().GetResult();TimedOut=$false}
 }finally{$p.Dispose()}
}
function Test-WeChatRcloneActive {
 $path=$LocalRoot.TrimEnd('\','/')+'.backup.lock';if(-not [IO.File]::Exists($path)){return $false}
 try{$lease=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$lease.Dispose();return $false}catch [IO.IOException]{return $true}
}
function Start-WeChatDriveCatchup {
 $exe=Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe';if(-not [IO.File]::Exists($exe)){$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'}
 $items=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'Backup-WeChat.ps1'),'-Target','Drive','-Source',$Source,'-LocalRoot',$LocalRoot,'-GDriveRemote',$script:resolvedRemote,'-GDriveFolder',$GDriveFolder,'-BwLimit',$BwLimit,'-MaxTransfer',$MaxTransfer)
 $arguments=@($items|ForEach-Object{ConvertTo-BackupProcessArgument $_})-join ' '
 $process=Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $Root -WindowStyle Hidden -PassThru
 return $process.Id
}
function Disable-SelfMonitor([string]$Name){
 $task=Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop
 if(@($task.Actions|Where-Object{$_.Arguments-like ('*'+(Join-Path $Root 'Monitor-WeChatDrive.ps1')+'*')}).Count-ne 1){throw 'monitor_task_identity_mismatch'}
 Disable-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop|Out-Null
}
if($Plan){[pscustomobject]@{mode='plan';write_mode='zero_write';source=$Source;snapshot=$LocalRoot;cloud='not_contacted';task=$MonitorTaskName}|ConvertTo-Json;exit 0}
$monitorLease=$null;$snapshotLease=$null;$code=0
$result=[ordered]@{schema='wechat.drive-monitor.v2';observed_utc=(Get-BackupUtc);status='running';snapshot='unknown';cloud='unknown';catchup='not_started';application_recovery='not_tested'}
try{
 $monitorLease=Open-BackupResourceLock (Join-Path $state 'wechat-drive-monitor')
 $null=Initialize-BackupNetwork
 $resolved=Resolve-ConfiguredRcloneRemote -Remote $GDriveRemote -RemoteWasExplicit $remoteExplicit -BindingPath (Join-Path $state 'rclone-remote-binding.json')
 if(-not $resolved.Success){throw 'monitor_remote_unavailable'};$script:resolvedRemote=$resolved.Remote
 if(Test-WeChatRcloneActive){$result.status='busy'}else{
  $verified=$false
  try{$snapshotLease=Open-BackupResourceLock $LocalRoot;$null=Get-VerifiedBackupTreeManifest $LocalRoot -VerifyContent;$verified=$true;$result.snapshot='sha256_verified'}catch{$result.snapshot='not_verified'}
  if($verified){
   $selection=Import-PowerShellDataFile (Join-Path $Root 'wechat-sources.psd1');$filter=@();foreach($name in $selection.ExcludeDirs){$filter+=@('--exclude',($name+'/**'))}
   $check=Invoke-RcloneWithTimeout -Arguments (@('check',$LocalRoot,($resolved.Remote+$GDriveFolder),'--checkers','8','--retries','2','--contimeout','20s','--timeout','120s')+$filter) -TimeoutSec $RcloneTimeoutSec -Purpose 'cloud check'
   $result.cloud=if($check.ExitCode-eq 0){'verified'}else{'incomplete_or_unavailable'}
  }
  if($snapshotLease){$snapshotLease.Dispose();$snapshotLease=$null}
  if($result.cloud-eq 'verified'){Disable-SelfMonitor $MonitorTaskName;$result.status='complete'}
  elseif(-not (Test-WeChatRcloneActive)){$result.catchup='launched_not_completed';$result.pid=Start-WeChatDriveCatchup;$result.status='catchup_started'}else{$result.status='busy'}
 }
}catch{$code=1;$result.status='failed';$result.reason=Get-BackupFailureCode $_}
finally{
 if($snapshotLease){$snapshotLease.Dispose()};if($monitorLease){$monitorLease.Dispose()}
 if($result.status-ne 'running'){Write-BackupJsonAtomic (Join-Path $state 'wechat-monitor-last.json') $result}
}
$result|ConvertTo-Json -Depth 6;exit $code
