<#
.SYNOPSIS
  注册 DevConfig + WeChat 备份的计划任务（幂等，可重复运行）。
.DESCRIPTION
  - DevConfigBackup-Local  : 每天 12:30 + 登录 -> -Tier Local（仅本地硬盘·零流量·高频保护）
  - DevConfigBackup-Weekly : 每周六 04:30      -> -Tier Usb,Drive（配置一周一次到U盘+Drive·有网才跑）
  - DevConfigBackup-OnUSB  : 插入U盘事件        -> -Tier Usb（机会式即插即同步·不常插不磨损）
  - WeChatBackup-Weekly    : 每周六 04:00      -> 微信:db+密钥到Drive、全量到U盘（方案A·一周一次）
  说明: U盘是1TB闪存,为省写入寿命改为每周一次;Drive(配置+微信)均每周一次省海外流量。
  以当前用户、仅登录时运行，无需密码与管理员权限。
.NOTES
  计划任务动作固定走 wscript.exe + VBS hidden launcher，避免 PowerShell 窗口一闪而过。
  VBS 内部仍使用 Windows PowerShell 5.1 执行业务脚本，脚本本身兼容 5.1 与 7。
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

# 重建前先清理旧任务（避免调频/改名后残留旧的每天Drive任务）
Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

# ① 本地：每天12:30 + 登录（仅本地硬盘，零流量、高频保护；不碰U盘闪存、不走海外流量）
Register-T 'DevConfigBackup-Local' `
    @((New-ScheduledTaskTrigger -Daily -At $DailyAt), (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)) `
    (New-Action $devWrapper 'Local') $s1 '配置备份：仅本地（每天/登录·零流量）'

# ② U盘 + Drive：每周六（配置一周一次；省U盘闪存写入+省海外流量；有网才跑、连不通下个窗口重试）
Register-T 'DevConfigBackup-Weekly' `
    (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At '04:30') `
    (New-Action $devWrapper 'Usb,Drive') $sNet '配置备份：U盘+Drive（每周六·一周一次）'

# ③ 插入U盘事件触发（NTFS 卷挂载 EventID 98；动作内再判断 H: 是否存在）
try {
    $sub = @"
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Ntfs'] and (EventID=98)]]</Select></Query></QueryList>
"@
    $cls  = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskEventTrigger
    $tEvt = New-CimInstance -CimClass $cls -ClientOnly
    $tEvt.Enabled = $true
    $tEvt.Subscription = $sub
    Register-T 'DevConfigBackup-OnUSB' $tEvt (New-Action $devWrapper 'Usb') $s1 '开发配置备份：插入U盘即同步'
} catch {
    Write-Warning "U盘事件任务创建失败（不影响每天/登录的U盘同步）：$($_.Exception.Message)"
}

# ④ 微信聊天记录：每周六增量到U盘（仅 H: 在时；脚本内判断）
if (Test-Path $wxScript) {
    if (-not (Test-Path $wxWrapper)) { throw "找不到 $wxWrapper" }
    Register-T 'WeChatBackup-Weekly' `
        (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At '04:00') `
        (New-Action $wxWrapper 'Usb,Drive') $s4 '微信聊天记录每周增量到U盘+Drive'
}

Write-Host "`n已注册的任务：" -ForegroundColor Cyan
Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' | Format-Table TaskName, State -AutoSize
Write-Host "验证：Start-ScheduledTask DevConfigBackup-Local; (Get-ScheduledTaskInfo DevConfigBackup-Local).LastTaskResult  # 0=成功"
