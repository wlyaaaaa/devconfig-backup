<#
.SYNOPSIS
  Register or refresh the hourly WeChat Drive monitor task.
.DESCRIPTION
  The task runs Monitor-WeChatDrive.ps1 directly instead of waiting through VBS.
  Task Scheduler can then enforce ExecutionTimeLimit if a Drive query hangs.
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'WeChatDrive-Monitor-Hourly',
    [int] $StartDelayMinutes = 10,
    [int] $IntervalHours = 1,
    [int] $ExecutionTimeMinutes = 30
)

$ErrorActionPreference = 'Stop'

$monitorScript = Join-Path $PSScriptRoot 'Monitor-WeChatDrive.ps1'
if (-not (Test-Path -LiteralPath $monitorScript)) {
    throw "Monitor script not found: $monitorScript"
}

$powershell51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershell51)) {
    throw "Windows PowerShell not found: $powershell51"
}

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($StartDelayMinutes)
$repetitionClass = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskRepetitionPattern
$repetition = New-CimInstance -CimClass $repetitionClass -ClientOnly
$repetition.Interval = "PT${IntervalHours}H"
$repetition.Duration = 'P3650D'
$repetition.StopAtDurationEnd = $false
$trigger.Repetition = $repetition

$action = New-ScheduledTaskAction `
    -Execute $powershell51 `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $monitorScript) `
    -WorkingDirectory $PSScriptRoot

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes $ExecutionTimeMinutes)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Limited

try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
} catch {}

Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Force `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Hourly monitor for WeChat Drive backup; resumes when no upload is active; disables itself after verification.' | Out-Null

Enable-ScheduledTask -TaskName $TaskName | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{
    Task = $TaskName
    State = $task.State
    NextRun = $info.NextRunTime
    Interval = $repetition.Interval
    ExecutionTimeLimitMinutes = $ExecutionTimeMinutes
}
