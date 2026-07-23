<#
.SYNOPSIS
  注册 DevConfig + WeChat 备份的计划任务（幂等，可重复运行）。
.DESCRIPTION
  - DevConfigBackup-Local  : 每天 21:05 + 登录后20分钟 -> -Tier Local（仅本地硬盘·零流量·高频保护）
  - DevConfigBackup-Weekly : 每周日 20:00             -> -Tier Hot,Drive（G盘热备+Drive）
  - WeChatBackup-Weekly    : 每周六 20:00             -> 微信完整聊天记录增量到G盘热备+Drive（含媒体）
  说明: H盘是默认锁定的人工冷备，不注册自动写入任务；Drive 依靠 rclone copy 自动跳过已存在文件。
  以当前用户、仅登录时运行，无需密码与管理员权限。
.NOTES
  计划任务动作固定走 wscript.exe + VBS hidden launcher，避免 PowerShell 窗口一闪而过。
  VBS 内部仍使用 Windows PowerShell 5.1 执行业务脚本，脚本本身兼容 5.1 与 7。
  重装新机后：先跑一次 Backup-DevConfig.ps1 -Tier Local 生成 latest.zip，再运行本脚本。
#>
[CmdletBinding()]
param(
    [string] $DailyAt  = '21:05',
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
    [string] $WeeklyDay = 'Sunday',
    [string] $WeeklyAt = '20:00',
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
    [string] $WeChatWeeklyDay = 'Saturday',
    [string] $WeChatWeeklyAt = '20:00'
)

$ErrorActionPreference = 'Stop'
$devScript = Join-Path $PSScriptRoot 'Backup-DevConfig.ps1'
$wxScript  = Join-Path $PSScriptRoot 'Backup-WeChat.ps1'
$devWrapper = Join-Path $PSScriptRoot 'Backup-DevConfig-Hidden.vbs'
$wxWrapper  = Join-Path $PSScriptRoot 'Backup-WeChat-Hidden.vbs'
if (-not (Test-Path $devScript)) { throw "找不到 $devScript" }
if (-not (Test-Path $devWrapper)) { throw "找不到 $devWrapper" }

$launcher = Join-Path $env:WINDIR 'System32\wscript.exe'

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Limited
function New-Settings([int]$Hours) {
    New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours $Hours)
}
function New-Action([string]$Wrapper, [string]$ScriptArgs) {
    New-ScheduledTaskAction -Execute $launcher `
        -Argument "`"$Wrapper`" $ScriptArgs" `
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

# 重建前尽量清理旧任务（非管理员会遇到部分旧任务拒绝删除；不阻塞后续 -Force 覆盖）
foreach ($oldTask in @(Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' -ErrorAction SilentlyContinue)) {
    try {
        Unregister-ScheduledTask -InputObject $oldTask -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Warning "旧任务删除失败，后续尝试直接覆盖：$($oldTask.TaskName) - $($_.Exception.Message)"
    }
}

# ① 本地：每天21:05 + 登录后20分钟（桌面机错过晚间窗口时补一份；不碰U盘闪存、不走海外流量）
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$logonTrigger.Delay = 'PT20M'
Register-T 'DevConfigBackup-Local' `
    @((New-ScheduledTaskTrigger -Daily -At $DailyAt), $logonTrigger) `
    (New-Action $devWrapper 'Local') $s1 '配置备份：仅本地（每天/登录·零流量）'

# ② G盘热备 + Drive：每周日晚上（不以网络作为任务启动条件，确保G盘热备始终先执行）
Register-T 'DevConfigBackup-Weekly' `
    (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $WeeklyDay -At $WeeklyAt) `
    (New-Action $devWrapper 'Hot,Drive') $s4 '配置备份：G盘热备+Drive（每周晚间）'

# ③ 微信聊天记录：每周六晚上增量到G盘热备+Drive
if (Test-Path $wxScript) {
    if (-not (Test-Path $wxWrapper)) { throw "找不到 $wxWrapper" }
    Register-T 'WeChatBackup-Weekly' `
        (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $WeChatWeeklyDay -At $WeChatWeeklyAt) `
        (New-Action $wxWrapper 'Hot,Drive') $s4 '微信聊天记录每周增量到G盘热备+Drive'
}

Write-Host "`n已注册的任务：" -ForegroundColor Cyan
Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' | Format-Table TaskName, State -AutoSize
Write-Host "验证：Start-ScheduledTask DevConfigBackup-Local; (Get-ScheduledTaskInfo DevConfigBackup-Local).LastTaskResult  # 0=成功"
