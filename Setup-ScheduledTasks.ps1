<#
.SYNOPSIS
  注册 DevConfig + WeChat 备份的计划任务（幂等，可重复运行）。
.DESCRIPTION
  - DevConfigBackup-Local        : 每天北京时间 11:05 + 登录后20分钟 -> -Tier Local,Hot（本地包+G盘热备）
  - WeChatBackup-Hot-Daily       : 每天北京时间 09:30               -> -Target Hot（G盘热备）
  默认值按北京时间换算成本机钟点；触发器带时区偏移，之后本机改时区北京时间不变。显式传参仍为本机钟点。
  本地和 G 热备离线运行，失败后下次定时自然重跑。
  H 盘由 PCConfig 冷备任务管理。
  DevConfig 保持当前用户 Limited；WeChat Hot 使用同一用户、Interactive、Highest，以便创建 Windows VSS 快照。实际注册/提权仍由 PCConfig 负责。
  可用 -TaskName 只收敛一个已登记任务；省略时保持两项任务的默认安装语义。
.NOTES
  计划任务动作固定走 wscript.exe + VBS hidden launcher，避免 PowerShell 窗口一闪而过。
  VBS 优先使用 PowerShell 7，缺少时回退 Windows PowerShell 5.1。
  重装新机后：先跑一次 Backup-DevConfig.ps1 -Tier Local 生成 latest.zip，再运行本脚本。
#>
[CmdletBinding()]
param(
    [string] $DailyAt  = '',
    [string] $WeChatHotAt = '',
    [ValidateSet('DevConfigBackup-Local','WeChatBackup-Hot-Daily')]
    [string[]] $TaskName = @()
)

$ErrorActionPreference = 'Stop'
function Convert-BeijingTimeToLocal([string] $At) {
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $today = [DateTime]::Today.ToString('yyyy-MM-dd', $culture)
    $beijing = [DateTimeOffset]::ParseExact("$today ${At}:00 +08:00", 'yyyy-MM-dd HH:mm:ss zzz', $culture)
    return [TimeZoneInfo]::ConvertTime($beijing, [TimeZoneInfo]::Local).ToString('HH:mm', $culture)
}
if ([string]::IsNullOrEmpty($DailyAt)) { $DailyAt = Convert-BeijingTimeToLocal '11:05' }
if ([string]::IsNullOrEmpty($WeChatHotAt)) { $WeChatHotAt = Convert-BeijingTimeToLocal '09:30' }

. (Join-Path $PSScriptRoot 'ScheduledTask-Registration.Common.ps1')
$devScript = Join-Path $PSScriptRoot 'Backup-DevConfig.ps1'
$wxScript  = Join-Path $PSScriptRoot 'Backup-WeChat.ps1'
$devWrapper = Join-Path $PSScriptRoot 'Backup-DevConfig-Hidden.vbs'
$wxWrapper  = Join-Path $PSScriptRoot 'Backup-WeChat-Hidden.vbs'
if (-not (Test-Path $devScript)) { throw "找不到 $devScript" }
if (-not (Test-Path $devWrapper)) { throw "找不到 $devWrapper" }
if (-not (Test-Path $wxScript)) { throw "找不到 $wxScript" }
if (-not (Test-Path $wxWrapper)) { throw "找不到 $wxWrapper" }

$launcher = Join-Path $env:WINDIR 'System32\wscript.exe'

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Limited
$weChatHotPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
function New-Action([string]$Wrapper, [string]$ScriptArgs) {
    New-ScheduledTaskAction -Execute $launcher `
        -Argument "`"$Wrapper`" $ScriptArgs" `
        -WorkingDirectory $PSScriptRoot
}
# 本地/G：关机错过后补跑；业务失败后下次定时自然重跑，不依赖网络。
$sLocalHot = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10)

$sWeChatHot = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 270) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15)

# ① 本地 + G 热备：默认每天北京时间11:05 + 登录后20分钟（错过窗口时补一份；不走海外流量）
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$logonTrigger.Delay = 'PT20M'

$taskDefinitions = @(
    [pscustomobject]@{
        Name = 'DevConfigBackup-Local'
        Triggers = @((New-ScheduledTaskTrigger -Daily -At $DailyAt), $logonTrigger)
        Action = New-Action $devWrapper 'Local,Hot'
        Principal = $principal
        Settings = $sLocalHot
        Description = '配置备份：本地包+G盘热备（每天/登录·零流量·失败后下次定时自然重跑）'
    },
    [pscustomobject]@{
        Name = 'WeChatBackup-Hot-Daily'
        Triggers = @((New-ScheduledTaskTrigger -Daily -At $WeChatHotAt))
        Action = New-Action $wxWrapper 'Hot'
        Principal = $weChatHotPrincipal
        Settings = $sWeChatHot
        Description = '微信聊天记录：每日增量到G盘热备（失败后下次定时自然重跑）'
    }
)

$allowSubset = $TaskName.Count -gt 0
if ($allowSubset) {
    $taskDefinitions = @($taskDefinitions | Where-Object { $_.Name -in $TaskName })
}

$nativeTaskApi = @{
    GetTask = {
        param([string] $Name)
        try {
            $tasks = @(Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop)
            if ($tasks.Count -eq 0) {
                return [pscustomobject]@{ Status = 'absent'; Task = $null }
            }
            if ($tasks.Count -ne 1) { throw "Scheduled task lookup is ambiguous: $Name" }
            return [pscustomobject]@{ Status = 'found'; Task = $tasks[0] }
        } catch {
            $notFound = $_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound -or
                $_.Exception.HResult -eq -2147024894
            if ($notFound) { return [pscustomobject]@{ Status = 'absent'; Task = $null } }
            throw
        }
    }
    ExportTask = {
        param([string] $Name)
        Export-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop
    }
    UnregisterTask = {
        param([string] $Name)
        Unregister-ScheduledTask -TaskName $Name -TaskPath '\' -Confirm:$false -ErrorAction Stop
    }
    RegisterXml = {
        param([string] $Name, [string] $Xml)
        Register-ScheduledTask -TaskName $Name -TaskPath '\' -Xml $Xml -Force -ErrorAction Stop | Out-Null
    }
    RegisterDefinition = {
        param($Definition, [bool] $ReplaceExisting)
        $registerArgs = @{
            TaskName = $Definition.Name
            TaskPath = '\'
            Action = $Definition.Action
            Trigger = $Definition.Triggers
            Principal = $Definition.Principal
            Settings = $Definition.Settings
            Description = $Definition.Description
            ErrorAction = 'Stop'
        }
        if ($ReplaceExisting) { $registerArgs['Force'] = $true }
        Register-ScheduledTask @registerArgs | Out-Null
    }
}

if ($allowSubset) {
    foreach ($definition in $taskDefinitions) {
        $lookup = Get-BackupScheduledTaskLookup -Api $nativeTaskApi -Name $definition.Name
        if ($lookup.Status -eq 'found') {
            if (-not (Test-BackupScheduledTaskAction -Task $lookup.Task -ExpectedAction $definition.Action)) {
                throw "Refusing to reuse settings from a non-owned scheduled task: $($definition.Name)"
            }
            # Keep the active trigger and settings. The Hot launcher needs room to close its receipt.
            $definition.Triggers = @($lookup.Task.Triggers)
            $definition.Settings = $lookup.Task.Settings
            if ($definition.Name -ceq 'WeChatBackup-Hot-Daily') {
                $limit = $definition.Settings.ExecutionTimeLimit
                if ($limit -is [string]) { $limit = [System.Xml.XmlConvert]::ToTimeSpan($limit) }
                if ($limit -gt [TimeSpan]::Zero -and $limit -lt [TimeSpan]::FromMinutes(270)) {
                    $definition.Settings.ExecutionTimeLimit = $sWeChatHot.ExecutionTimeLimit
                }
            }
        }
    }
}

$registration = Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $taskDefinitions -Api $nativeTaskApi -AllowSubset:$allowSubset
foreach ($name in $registration.Names) {
    Write-Host "  [OK] $name" -ForegroundColor Green
}
Write-Host "`n已注册的任务：" -ForegroundColor Cyan
$registeredTasks = foreach ($name in $registration.Names) {
    Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop
}
$registeredTasks | Format-Table TaskName, State -AutoSize
Write-Host "下一次自然运行后核对：(Get-ScheduledTaskInfo DevConfigBackup-Local).LastTaskResult  # 0=成功"
