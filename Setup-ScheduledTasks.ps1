<#
.SYNOPSIS
  注册 DevConfig 三级备份的计划任务（幂等，可重复运行）。
.DESCRIPTION
  - DevConfigBackup-Local : 每天 12:30 + 登录时 -> -Tier Local,Usb（零流量；U盘在就同步）
  - DevConfigBackup-Cloud : 每周日 03:00     -> -Tier Drive（改动才传，海外低峰）
  - DevConfigBackup-OnUSB : 插入U盘(NTFS卷挂载)事件 -> -Tier Usb（即插即同步）
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
$script = Join-Path $PSScriptRoot 'Backup-DevConfig.ps1'
if (-not (Test-Path $script)) { throw "找不到 $script" }

# 固定用 5.1（WindowsApps 版 pwsh 无法被任务计划启动）
$launcher = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

function New-Action([string]$TierArgs) {
    New-ScheduledTaskAction -Execute $launcher `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" $TierArgs" `
        -WorkingDirectory $PSScriptRoot
}
function Register-DCB([string]$Name, $Triggers, [string]$TierArgs, [string]$Desc) {
    Register-ScheduledTask -TaskName $Name -TaskPath '\' -Force `
        -Action (New-Action $TierArgs) -Trigger $Triggers -Principal $principal -Settings $settings -Description $Desc | Out-Null
    Write-Host "  [OK] $Name" -ForegroundColor Green
}

# ① 本地 + U盘：每天 + 登录
Register-DCB 'DevConfigBackup-Local' `
    @((New-ScheduledTaskTrigger -Daily -At $DailyAt), (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)) `
    '-Tier Local,Usb' '开发配置备份：本地+U盘（每天/登录）'

# ② Drive：每周日低峰
Register-DCB 'DevConfigBackup-Cloud' `
    (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $WeeklyAt) `
    '-Tier Drive' '开发配置备份：Google Drive（每周·改动才传）'

# ③ 插入U盘事件触发（NTFS 卷挂载 EventID 98；动作内再判断 H: 是否存在）
try {
    $sub = @"
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Ntfs'] and (EventID=98)]]</Select></Query></QueryList>
"@
    $cls  = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskEventTrigger
    $tEvt = New-CimInstance -CimClass $cls -ClientOnly
    $tEvt.Enabled = $true
    $tEvt.Subscription = $sub
    Register-DCB 'DevConfigBackup-OnUSB' $tEvt '-Tier Usb' '开发配置备份：插入U盘即同步'
} catch {
    Write-Warning "U盘事件任务创建失败（不影响每天/登录的U盘同步）：$($_.Exception.Message)"
}

Write-Host "`n已注册的任务：" -ForegroundColor Cyan
Get-ScheduledTask -TaskName 'DevConfigBackup-*' | Format-Table TaskName, State -AutoSize
Write-Host "提示：可手动验证 -> Start-ScheduledTask DevConfigBackup-Local; (Get-ScheduledTaskInfo DevConfigBackup-Local).LastTaskResult  # 0=成功"
