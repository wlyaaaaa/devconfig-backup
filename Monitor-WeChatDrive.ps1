<#
.SYNOPSIS
  每小时监控微信聊天记录 Drive 备份，直到完整成功。
.DESCRIPTION
  - 计算本地静态快照（E:\WeChatBackup\xwechat_files）按同一排除规则后的应备份大小。
  - 查询 Google Drive 端 Backups/WeChat/xwechat_files 当前大小和文件数。
  - 未完成且没有正在运行的 rclone 上传时，自动启动 Backup-WeChat.ps1 -Target Drive 续传。
  - 接近完成后运行 rclone check 做确认；确认成功后自动禁用本监控任务。
.NOTES
  本脚本不上传密钥内容到日志，只记录大小、百分比、进程和任务状态。
#>
[CmdletBinding()]
param(
    [string] $LocalRoot = 'E:\WeChatBackup\xwechat_files',
    [string] $GDriveRemote = 'gdrive:',
    [string] $GDriveFolder = 'Backups/WeChat/xwechat_files',
    [string] $MonitorTaskName = 'WeChatDrive-Monitor-Hourly',
    [double] $CompletePercent = 99.5,
    [int] $RcloneTimeoutSec = 900
)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$LogDir = Join-Path $Root 'logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'wechat-drive-monitor.log'

function Write-MonitorLog([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Resolve-RcloneRemote {
    param([string]$Preferred)
    $remotes = @(& rclone listremotes 2>$null)
    if ($remotes -contains $Preferred) { return $Preferred }
    if ($remotes.Count -gt 0) {
        Write-MonitorLog "默认远端不存在，改用第一个已配置远端: $($remotes[0])"
        return $remotes[0]
    }
    return $null
}

function Invoke-RcloneWithTimeout {
    param(
        [Parameter(Mandatory=$true)]
        [string[]] $Arguments,
        [int] $TimeoutSec = 900,
        [string] $Purpose = 'rclone'
    )

    function ConvertTo-ProcessArgumentString([string[]]$Items) {
        $quoted = foreach ($item in $Items) {
            if ($item -match '[\s"]') {
                '"' + ($item -replace '"', '\"') + '"'
            } else {
                $item
            }
        }
        return ($quoted -join ' ')
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'rclone.exe'
    $psi.Arguments = ConvertTo-ProcessArgumentString $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Root

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            Write-MonitorLog "$Purpose 超过 ${TimeoutSec}s 未返回，终止本轮检查，等待下一轮重试。" 'WARN'
            return [pscustomobject]@{ ExitCode = 124; Stdout = ''; Stderr = ''; TimedOut = $true }
        }

        $outText = $p.StandardOutput.ReadToEnd()
        $errText = $p.StandardError.ReadToEnd()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Stdout = $outText; Stderr = $errText; TimedOut = $false }
    } finally {
        if ($p) { $p.Dispose() }
    }
}

function Get-RcloneSizeJson {
    param([string]$Path, [string[]]$ExtraArgs = @())
    $args = @('size', $Path) + $ExtraArgs + @('--fast-list', '--json')
    $result = Invoke-RcloneWithTimeout -Arguments $args -TimeoutSec $RcloneTimeoutSec -Purpose "rclone size $Path"
    if ($result.ExitCode -ne 0 -or -not $result.Stdout) { return $null }
    try { return ($result.Stdout | ConvertFrom-Json) } catch { return $null }
}

function Test-WeChatRcloneActive {
    $procs = @(Get-CimInstance Win32_Process -Filter "name='rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'E:\\WeChatBackup\\xwechat_files|Backups[/\\]WeChat[/\\]xwechat_files' })
    return $procs.Count -gt 0
}

function Start-WeChatDriveCatchup {
    $script = Join-Path $Root 'Backup-WeChat.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        Write-MonitorLog "找不到续传脚本: $script" 'ERR'
        return
    }
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Target Drive' -f $script
    $p = Start-Process -FilePath powershell.exe -ArgumentList $arg -WorkingDirectory $Root -WindowStyle Hidden -PassThru
    Write-MonitorLog "未完成且未检测到 rclone 上传，已启动 Drive 续传 PID=$($p.Id)"
}

function Disable-SelfMonitor {
    param([string]$Name)
    try {
        Disable-ScheduledTask -TaskName $Name -ErrorAction Stop | Out-Null
        Write-MonitorLog "已禁用监控任务: $Name" 'OK'
    } catch {
        Write-MonitorLog "禁用监控任务失败，可能需要管理员权限: $($_.Exception.Message)" 'WARN'
    }
}

$excludes = @(
    '--exclude','cache/**',
    '--exclude','Cache/**',
    '--exclude','temp/**',
    '--exclude','Temp/**',
    '--exclude','WMPF/**',
    '--exclude','apm_record/**',
    '--exclude','crash/**',
    '--exclude','FileStorageTemp/**',
    '--exclude','recommend_cover/**',
    '--exclude','*.db-wal',
    '--exclude','*.db-shm',
    '--exclude','*.db-journal'
)

Write-MonitorLog "==== WeChat Drive monitor start PID=$PID ===="
if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-MonitorLog 'rclone 未安装或不在 PATH，无法监控 Drive' 'ERR'
    exit 1
}
if (-not (Test-Path -LiteralPath $LocalRoot)) {
    Write-MonitorLog "本地静态快照不存在: $LocalRoot" 'ERR'
    exit 1
}

$remote = Resolve-RcloneRemote $GDriveRemote
if (-not $remote) {
    Write-MonitorLog '未发现 rclone 远端，跳过本轮监控' 'WARN'
    exit 0
}
$dest = "$remote$GDriveFolder"

$local = Get-RcloneSizeJson -Path $LocalRoot -ExtraArgs $excludes
if (-not $local -or $local.bytes -le 0) {
    Write-MonitorLog '本地静态快照大小读取失败，跳过本轮监控' 'ERR'
    exit 1
}

$drive = Get-RcloneSizeJson -Path $dest
if (-not $drive) {
    Write-MonitorLog 'Drive 端大小读取失败（网络/代理/Google 暂时不可用），下轮重试' 'WARN'
    exit 0
}

$pct = [math]::Round(($drive.bytes / [double]$local.bytes) * 100, 2)
$localGiB = [math]::Round($local.bytes / 1GB, 2)
$driveGiB = [math]::Round($drive.bytes / 1GB, 2)
$active = Test-WeChatRcloneActive
Write-MonitorLog ("进度: {0} GiB / {1} GiB = {2}% ; Drive文件={3} 本地文件={4} ; rcloneActive={5}" -f $driveGiB, $localGiB, $pct, $drive.count, $local.count, $active)

if ($pct -ge $CompletePercent) {
    Write-MonitorLog "达到 $CompletePercent%，执行 rclone check 做最终确认..."
    $checkArgs = @('check', $LocalRoot, $dest) + $excludes + @('--one-way', '--fast-list', '--checkers', '16', '--retries', '3', '--low-level-retries', '10', '--log-file', $LogFile, '--log-level', 'INFO')
    $check = Invoke-RcloneWithTimeout -Arguments $checkArgs -TimeoutSec ([math]::Max($RcloneTimeoutSec, 1800)) -Purpose 'rclone check'
    if ($check.ExitCode -eq 0) {
        Write-MonitorLog "微信 Drive 备份已确认完成: $driveGiB / $localGiB GiB, $pct%" 'OK'
        Disable-SelfMonitor $MonitorTaskName
        exit 0
    }
    Write-MonitorLog "rclone check 未通过(exit=$($check.ExitCode))，继续保持监控并等待补齐" 'WARN'
}

    $active = Test-WeChatRcloneActive
    if (-not $active) {
    Start-WeChatDriveCatchup
} else {
    Write-MonitorLog '检测到上传正在进行，本轮不重复启动。'
}
Write-MonitorLog '==== WeChat Drive monitor end ===='
exit 0
