<#
.SYNOPSIS
  微信聊天记录增量备份（独立于 DevConfig 配置包）。
.DESCRIPTION
  仅备份"历史聊天记录"(msg/db_storage/business/config/resource/all_users/old_backup)，
  剔除缓存/临时/小程序运行时(cache/temp/WMPF/apm_record)。
  增量方式：robocopy /E（只增不删，历史永不丢失）+ rclone copy（Drive 只传新增/改动）。
  首次运行为全量(~27GB)；之后仅复制变化的库与新增媒体。
.EXAMPLE
  pwsh -File Backup-WeChat.ps1 -List           # 干跑，只估算将复制的量（强烈建议先跑）
  pwsh -File Backup-WeChat.ps1 -Target Usb      # 增量到U盘（零流量，推荐主力）
  pwsh -File Backup-WeChat.ps1 -Target Local    # 增量到本地另一盘
  pwsh -File Backup-WeChat.ps1 -Target Drive    # 增量到 Google Drive（走海外流量，按需）
.NOTES
  27GB 首次上传 Drive 很费海外流量，建议：先 -Target Usb 全量，Drive 仅按需/低频。
#>
[CmdletBinding()]
param(
    [string[]] $Target = @('Usb'),
    [string]   $Source       = 'E:\Documents\xwechat_files',
    [string]   $UsbRoot      = 'H:\My_Digital_Backup\WeChat\xwechat_files',
    [string]   $LocalRoot    = 'E:\WeChatBackup\xwechat_files',
    [string]   $GDriveRemote = 'gdrive:',
    [string]   $GDriveFolder = 'Backups/WeChat/xwechat_files',
    [string]   $BwLimit      = '4M',
    [switch]   $List
)

$ErrorActionPreference = 'Continue'
$Target = @($Target) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# 剔除：缓存/临时/小程序运行时/崩溃日志（历史本体在 msg / db_storage）
$exclDirs = @('cache','Cache','temp','Temp','WMPF','apm_record','crash','FileStorageTemp','recommend_cover')

$LogDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$log = Join-Path $LogDir ("wechat-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Say($m,$c='Gray'){ $l="{0} {1}" -f (Get-Date -Format 'HH:mm:ss'),$m; Write-Host $l -ForegroundColor $c; Add-Content -LiteralPath $log -Value $l -Encoding UTF8 }

if (-not (Test-Path -LiteralPath $Source)) { Say "源不存在: $Source" 'Red'; exit 1 }
Say "==== WeChat backup | Target=$($Target -join ',') | List=$List ====" 'Cyan'

function Sync-Local([string]$dst, [bool]$listOnly) {
    $a = @($Source, $dst, '/E','/R:1','/W:1','/MT:16','/NDL','/NP','/XD') + $exclDirs
    if ($listOnly) { $a += '/L' }       # /L = 只列出，不实际复制
    Say "robocopy -> $dst $(if($listOnly){'(干跑)'})"
    & robocopy @a | Out-Null
    Say "  robocopy exit=$LASTEXITCODE (0-7 正常)" 'Green'
}

foreach ($t in $Target) {
    switch ($t) {
        'Usb' {
            $drv = ($UsbRoot -split '\\')[0]
            if (-not (Test-Path "$drv\")) { Say "U盘 $drv 未插入，跳过" 'Yellow'; break }
            New-Item -ItemType Directory -Path $UsbRoot -Force | Out-Null
            Sync-Local $UsbRoot ([bool]$List)
        }
        'Local' {
            New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
            Sync-Local $LocalRoot ([bool]$List)
        }
        'Drive' {
            if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) { Say "rclone 未安装，跳过 Drive" 'Yellow'; break }
            # 远端自动探测（默认名不存在则用第一个已配置远端）
            $remotes = @(& rclone listremotes 2>$null)
            if ($remotes -notcontains $GDriveRemote) {
                if ($remotes.Count) { $GDriveRemote = $remotes[0]; Say "  默认远端不存在，改用 $GDriveRemote" }
                else { Say "rclone 无已配置远端，跳过 Drive" 'Yellow'; break }
            }
            # 连通性预检：代理/海外网络没就绪则优雅跳过，下次自动重试（rclone copy 幂等续传）
            & rclone lsd "$GDriveRemote" --max-depth 1 --contimeout 15s --timeout 20s --retries 1 *> $null
            if ($LASTEXITCODE -ne 0) { Say "Drive 不可达(代理/海外网络未就绪)，跳过，下次重试" 'Yellow'; break }
            $dest = "$GDriveRemote$GDriveFolder"
            $exArgs = $exclDirs | ForEach-Object { '--exclude'; "$_/**" }
            # copy=只增不删（历史安全）；多小文件调参：并发/分块/fast-list/限速
            $rc = @($Source, $dest) + $exArgs + @(
                '--bwlimit', $BwLimit, '--transfers', '8', '--checkers', '16',
                '--drive-chunk-size', '64M', '--fast-list',
                '--retries', '3', '--low-level-retries', '10', '--stats', '60s'
            )
            if ($List) { $rc += '--dry-run' }
            Say "rclone copy -> $dest $(if($List){'(干跑)'})"
            & rclone copy @rc
            Say "  rclone exit=$LASTEXITCODE" 'Green'
        }
        default { Say "未知 Target: $t" 'Yellow' }
    }
}
Say "==== 完成 ====" 'Green'
exit 0
