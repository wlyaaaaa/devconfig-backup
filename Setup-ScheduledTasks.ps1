<#
.SYNOPSIS
  注册 DevConfig + WeChat 备份的计划任务（幂等，可重复运行）。
.DESCRIPTION
  - DevConfigBackup-Local : 每天 12:30 + 登录时 -> -Tier Local,Usb,Drive（Drive改动才传/连不通自跳过/强重试续传）
  - DevConfigBackup-Cloud : 每天 21:00 兜底    -> -Tier Drive（有网才跑，补白天没传成功的）
  - DevConfigBackup-OnUSB : 插入U盘(NTFS卷挂载)事件 -> -Tier Usb（即插即同步）
  - WeChatBackup-Weekly   : 每周六 04:00     -> 微信聊天记录增量到U盘+Drive
  以当前用户、仅登录时运行，无需密码与管理员权限。
.NOTES
  启动器固定用 Windows PowerShell 5.1（powershell.exe）——任务计划无法直接启动
  Microsoft Store 版 pwsh（WindowsApps 打包路径）。脚本本身兼容 5.1 与 7。
  重装新机后：先跑一次 Backup-DevConfig.ps1 -Tier Local 生成 latest.zip，再运行本脚本。
#>
[CmdletBinding()]
param(
    [string] $DailyAt  = '12:30',
    [string] $WeeklyAt = '03:00'
)

$ErrorActionPreference = 'Stop'
$devScript = Join-Path $PSScriptRoot 'Backup-DevConfig.ps1'
$wxScript  = Join-Path $PSScriptRoot 'Backup-WeChat.ps1'
if (-not (Test-Path $devScript)) { throw "找不到 $devScript" }

# 固定用 5.1（WindowsApps 版 pwsh 无法被任务计划启动）
$launcher = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Limited
function New-Settings([int]$Hours) {
    New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours $Hours)
}
function New-Action([string]$Script, [string]$ScriptArgs) {
    New-ScheduledTaskAction -Execute $launcher `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`" $ScriptArgs" `
        -WorkingDirectory $PSScriptRoot
}
function Register-T([string]$Name, $Triggers, $Action, $Settings, [string]$Desc) {
    Register-ScheduledTask -TaskName $Name -TaskPath '\' -Force `
        -Action $Action -Trigger $Triggers -Principal $principal -Settings $Settings -Description $Desc | Out-Null
    Write-Host "  [OK] $Name" -ForegroundColor Green
}

$s1 = New-Settings 1
$s4 = New-Settings 4
# Drive 兜底专用：仅有网络时跑 + 错过自动补跑（Drive 内部还会做代理连通性预检）
$sNet = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)

# ① 本地 + U盘 + Drive：每天12:30 + 登录（Drive 改动才传、连不通自跳过、强重试续传）
Register-T 'DevConfigBackup-Local' `
    @((New-ScheduledTaskTrigger -Daily -At $DailyAt), (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)) `
    (New-Action $devScript '-Tier Local,Usb,Drive') $s1 '配置备份：本地+U盘+Drive（每天/登录）'

# ② Drive 兜底：每天 21:00（有网才跑，补白天没传成功的）
Register-T 'DevConfigBackup-Cloud' `
    (New-ScheduledTaskTrigger -Daily -At '21:00') `
    (New-Action $devScript '-Tier Drive') $sNet '配置备份：Drive 兜底（每天21点·有网才跑）'

# ③ 插入U盘事件触发（NTFS 卷挂载 EventID 98；动作内再判断 H: 是否存在）
try {
    $sub = @"
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Ntfs'] and (EventID=98)]]</Select></Query></QueryList>
"@
    $cls  = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskEventTrigger
    $tEvt = New-CimInstance -CimClass $cls -ClientOnly
    $tEvt.Enabled = $true
    $tEvt.Subscription = $sub
    Register-T 'DevConfigBackup-OnUSB' $tEvt (New-Action $devScript '-Tier Usb') $s1 '开发配置备份：插入U盘即同步'
} catch {
    Write-Warning "U盘事件任务创建失败（不影响每天/登录的U盘同步）：$($_.Exception.Message)"
}

# ④ 微信聊天记录：每周六增量到U盘（仅 H: 在时；脚本内判断）
if (Test-Path $wxScript) {
    Register-T 'WeChatBackup-Weekly' `
        (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At '04:00') `
        (New-Action $wxScript '-Target Usb,Drive') $s4 '微信聊天记录每周增量到U盘+Drive'
}

Write-Host "`n已注册的任务：" -ForegroundColor Cyan
Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' | Format-Table TaskName, State -AutoSize
Write-Host "验证：Start-ScheduledTask DevConfigBackup-Local; (Get-ScheduledTaskInfo DevConfigBackup-Local).LastTaskResult  # 0=成功"
