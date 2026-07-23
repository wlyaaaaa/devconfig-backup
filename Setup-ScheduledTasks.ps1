<#
.SYNOPSIS
  注册 DevConfig + WeChat 备份的计划任务（幂等，可重复运行）。
.DESCRIPTION
  - DevConfigBackup-Local        : 每天 21:05 + 登录后20分钟 -> -Tier Local,Hot（本地包+G盘热备）
  - DevConfigBackup-Drive-Daily  : 每天 22:00               -> -Tier Drive（Google Drive）
  - WeChatBackup-Hot-Daily       : 每天 18:30               -> -Target Hot（G盘热备）
  - WeChatBackup-Drive-Weekly    : 每周日 20:00             -> -Target Drive（Google Drive）
  说明: 本地/G 热备与 Drive 拆成独立任务，离线不会阻断本地保护，Drive 失败会返回非零并自动重试。
  H盘是默认锁定的人工冷备，不注册自动写入任务；Drive 依靠 rclone copy 自动跳过已存在文件。
  以当前用户、仅登录时运行，无需密码与管理员权限。
.NOTES
  计划任务动作固定走 wscript.exe + VBS hidden launcher，避免 PowerShell 窗口一闪而过。
  VBS 内部仍使用 Windows PowerShell 5.1 执行业务脚本，脚本本身兼容 5.1 与 7。
  重装新机后：先跑一次 Backup-DevConfig.ps1 -Tier Local 生成 latest.zip，再运行本脚本。
#>
[CmdletBinding()]
param(
    [string] $DailyAt  = '21:05',
    [string] $DriveAt  = '22:00',
    [string] $WeChatHotAt = '18:30',
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
    [string] $WeChatDriveWeeklyDay = 'Sunday',
    [string] $WeChatDriveWeeklyAt = '20:00'
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

# 本地/G：关机错过后补跑；业务失败返回非零后再重试 3 次，不依赖网络。
$sLocalHot = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10)

# Drive：仅网络可用时启动；代理或远端失败由脚本返回非零，再由任务重试。
$sDrive = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 15)

$sWeChatHot = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15)

$sWeChatDrive = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 30)

# 重建前尽量清理旧任务（非管理员会遇到部分旧任务拒绝删除；不阻塞后续 -Force 覆盖）
foreach ($oldTask in @(Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' -ErrorAction SilentlyContinue)) {
    try {
        Unregister-ScheduledTask -InputObject $oldTask -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Warning "旧任务删除失败，后续尝试直接覆盖：$($oldTask.TaskName) - $($_.Exception.Message)"
    }
}

# ① 本地 + G 热备：每天21:05 + 登录后20分钟（桌面机错过晚间窗口时补一份；不走海外流量）
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$logonTrigger.Delay = 'PT20M'
Register-T 'DevConfigBackup-Local' `
    @((New-ScheduledTaskTrigger -Daily -At $DailyAt), $logonTrigger) `
    (New-Action $devWrapper 'Local,Hot') $sLocalHot '配置备份：本地包+G盘热备（每天/登录·零流量·失败重试3次）'

# ② Drive：与本地/G任务分离，离线或远端失败不会把热备链路一起拖住
Register-T 'DevConfigBackup-Drive-Daily' `
    (New-ScheduledTaskTrigger -Daily -At $DriveAt) `
    (New-Action $devWrapper 'Drive') $sDrive '配置备份：Drive增量（每天·有网才跑·失败重试5次）'

# ③ 微信聊天记录：G 热备与 Drive 分开调度、分别报告结果
if (Test-Path $wxScript) {
    if (-not (Test-Path $wxWrapper)) { throw "找不到 $wxWrapper" }
    Register-T 'WeChatBackup-Hot-Daily' `
        (New-ScheduledTaskTrigger -Daily -At $WeChatHotAt) `
        (New-Action $wxWrapper 'Hot') $sWeChatHot '微信聊天记录：每日增量到G盘热备（失败重试3次）'
    Register-T 'WeChatBackup-Drive-Weekly' `
        (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $WeChatDriveWeeklyDay -At $WeChatDriveWeeklyAt) `
        (New-Action $wxWrapper 'Drive') $sWeChatDrive '微信聊天记录：每周增量到Drive（有网才跑·失败重试5次）'
}

Write-Host "`n已注册的任务：" -ForegroundColor Cyan
Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' | Format-Table TaskName, State -AutoSize
Write-Host "验证：Start-ScheduledTask DevConfigBackup-Local; (Get-ScheduledTaskInfo DevConfigBackup-Local).LastTaskResult  # 0=成功"
