<#
.SYNOPSIS
  Register/update the optional monitor, preserving disabled state by default.
.DESCRIPTION
  -Enable explicitly opts in. Existing running tasks are not killed, and a same-
  named unrelated task is never taken over. Failures restore the saved definition.
#>
[CmdletBinding()]
param([string]$TaskName='WeChatDrive-Monitor-Hourly',[ValidateRange(0,1440)][int]$StartDelayMinutes=10,[ValidateRange(1,24)][int]$IntervalHours=1,[ValidateRange(1,1440)][int]$ExecutionTimeMinutes=30,[switch]$Enable)
$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot 'Monitor-WeChatDrive.ps1'
if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){throw 'monitor_source_missing'}
if($TaskName-match '["\r\n]'){throw 'monitor_task_name_invalid'}
$exe=Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe';if(-not [IO.File]::Exists($exe)){$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'}
$existing=$null
try{$existing=Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop}catch{if($_.CategoryInfo.Category-ne [Management.Automation.ErrorCategory]::ObjectNotFound){throw}}
if($existing){
 if(@($existing.Actions|Where-Object{$_.Arguments-like ('*'+$scriptPath+'*')}).Count-ne 1){throw 'monitor_task_identity_mismatch'}
 if([string]$existing.State-eq 'Running'){throw 'stop_owned_monitor_before_update'}
}
$wasEnabled=$existing -and $existing.Settings.Enabled;$xml=if($existing){Export-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop}else{$null}
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($StartDelayMinutes)
$class=Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskRepetitionPattern
$repetition=New-CimInstance -CimClass $class -ClientOnly;$repetition.Interval="PT${IntervalHours}H";$repetition.Duration='P3650D';$repetition.StopAtDurationEnd=$false;$trigger.Repetition=$repetition
$action=New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -MonitorTaskName "{1}"' -f $scriptPath,$TaskName) -WorkingDirectory $PSScriptRoot
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes $ExecutionTimeMinutes)
$principal=New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
try{
 Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -Description 'Optional catchup monitor. Manage in Task Scheduler. Disabling does not cancel a previously launched upload.'|Out-Null
 if($Enable -or $wasEnabled){Enable-ScheduledTask -TaskName $TaskName -TaskPath '\'|Out-Null}else{Disable-ScheduledTask -TaskName $TaskName -TaskPath '\'|Out-Null}
 $readback=Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
 if([bool]$readback.Settings.Enabled-ne [bool]($Enable -or $wasEnabled) -or $readback.Actions[0].Execute-ine $exe -or $readback.Actions[0].Arguments-cne $action.Arguments){throw 'monitor_registration_readback_failed'}
}catch{
 if($xml){Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $xml -Force -ErrorAction Stop|Out-Null}
 else{Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue}
 throw
}
$info=Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\'
[pscustomobject]@{Task=$TaskName;State=$readback.State;Enabled=$readback.Settings.Enabled;NextRun=$info.NextRunTime;Interval=$repetition.Interval;ExecutionTimeLimitMinutes=$ExecutionTimeMinutes;Control='Task Scheduler'}
