<#
.SYNOPSIS
  微信原应用数据增量备份（独立于 DevConfig 配置包）。
.DESCRIPTION
  按既定 source selection 原样复制 xwechat_files 的应用数据，剔除缓存/临时/小程序运行时
  (cache/temp/WMPF/apm_record)。本地/G 热备路径不打开、不解密、不读取聊天、账号或媒体正文。
  增量方式：robocopy /E（只增不删）+ rclone copy（Drive 只传新增/改动）。
  首次运行为全量(~38GB)；之后仅复制变化的库与新增媒体。复制/远端校验只能证明备份
  文件传输结果，不能证明微信在复制时未写入，也不能替代日后的官方客户端恢复验收。
  【Drive 流量安全】① 绝不直传微信源目录(运行时数据库边传边改→反复重传烧流量)，
    而是先 robocopy 到本地静态快照再从快照上传；② 保留 SQLite 的 wal/shm/journal 伴随文件，
    但不把运行中复制冒充为一致快照；③ rclone copy 自动跳过已上传文件。
.EXAMPLE
  pwsh -File Backup-WeChat.ps1 -List           # 干跑，只估算将复制的量（强烈建议先跑）
  pwsh -File Backup-WeChat.ps1 -Target Hot      # 增量到G盘热备（零流量，自动任务主力）
  pwsh -File Backup-WeChat.ps1 -Target Local    # 增量到本地另一盘
  pwsh -File Backup-WeChat.ps1 -Target Drive    # 完整原应用数据增量到 Google Drive（含媒体，默认8G封顶）
  pwsh -File Backup-WeChat.ps1 -Target Drive -DbOnly # 仅数据库上云，媒体只留U盘（省流量模式）
.NOTES
  38GB 首次上传 Drive 很费海外流量；完成后 rclone copy 会自动跳过已存在文件，后续只传增量。
  默认单次 Drive 上传设置 8G 流量保险丝；确需一次性补齐时可显式传 -MaxTransfer 0。
#>
[CmdletBinding()]
param(
    [string[]] $Target = @('Hot'),
    [string]   $Source       = 'E:\Documents\xwechat_files',
    [string]   $HotRoot      = 'G:\80_Backup\WeChat\xwechat_files',
    [string]   $LocalRoot    = 'E:\WeChatBackup\xwechat_files',
    [string]   $GDriveRemote = 'gdrive:',
    [string]   $GDriveFolder = 'Backups/WeChat/xwechat_files',
    [string]   $BwLimit      = '4M',
    [string]   $MaxTransfer  = '8G',
    [switch]   $DriveFull,
    [switch]   $DbOnly,
    [switch]   $List
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Initialize-BackupNetwork.ps1')
$script:GDriveRemoteWasExplicit = $PSBoundParameters.ContainsKey('GDriveRemote')
$Target = @($Target) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$invalidTargets = @($Target | Where-Object { $_ -notin @('Hot','Local','Drive') })
if ($invalidTargets.Count -gt 0) { throw "Unsupported target: $($invalidTargets -join ','). H cold backup is owned by the PCConfig manual G-to-H workflow." }

# 剔除：缓存/临时/小程序运行时/崩溃日志（历史本体在 msg / db_storage）
$exclDirs = @('cache','Cache','temp','Temp','WMPF','apm_record','crash','FileStorageTemp','recommend_cover')

$LogDir = Join-Path $PSScriptRoot 'logs'
$StateDir = Join-Path $PSScriptRoot 'state'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$log = Join-Path $LogDir ("wechat-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Say($m,$c='Gray'){ $l="{0} {1}" -f (Get-Date -Format 'HH:mm:ss'),$m; Write-Host $l -ForegroundColor $c; Add-Content -LiteralPath $log -Value $l -Encoding UTF8 }
$overallExitCode = 0

if (-not (Test-Path -LiteralPath $Source)) { Say "源不存在: $Source" 'Red'; exit 1 }
Say "==== WeChat backup | Target=$($Target -join ',') | List=$List ====" 'Cyan'

function Sync-Local([string]$dst, [bool]$listOnly, [int]$Threads = 16) {
    $a = @($Source, $dst, '/E','/R:1','/W:1',"/MT:$Threads",'/NDL','/NP','/XD') + $exclDirs
    if ($listOnly) { $a += '/L' }       # /L = 只列出，不实际复制
    Say "robocopy -> $dst $(if($listOnly){'(干跑)'})"
    & robocopy @a | Out-Null
    $copyExit = $LASTEXITCODE
    Say "  robocopy exit=$copyExit (0-7 正常)" $(if($copyExit -lt 8){'Green'}else{'Red'})
    if ($copyExit -ge 8) { $script:overallExitCode = 1 }
}

foreach ($t in $Target) {
    switch ($t) {
        'Hot' {
            New-Item -ItemType Directory -Path $HotRoot -Force | Out-Null
            Sync-Local $HotRoot ([bool]$List)
        }
        'Local' {
            New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
            Sync-Local $LocalRoot ([bool]$List)
        }
        'Drive' {
            Initialize-BackupNetwork | Out-Null
            if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
                Say "rclone 未安装，跳过 Drive" 'Red'
                $overallExitCode = 1
                break
            }
            $remoteResolution = Resolve-ConfiguredRcloneRemote -Remote $GDriveRemote `
                -RemoteWasExplicit $script:GDriveRemoteWasExplicit `
                -BindingPath (Join-Path $StateDir 'rclone-remote-binding.json')
            if (-not $remoteResolution.Success) {
                Say "配置的 Drive 远端不可用 reason=$($remoteResolution.Reason)，本轮失败" 'Red'
                $overallExitCode = 1
                break
            }
            $GDriveRemote = $remoteResolution.Remote
            # 治本：绝不直传微信源目录——微信运行时数据库在被写入，rclone 上传中途
            # 检测到 modtime 变化即报 "source file is being updated" 并整文件从头重传，
            # 反复烧海外流量却传不成功。改为先 robocopy 源→本地静态快照（零流量），
            # 再从这份"不会被微信改写"的快照上传，从根上消除边传边改的重传循环。
            if ($List) {
                $rcloneSource = $Source
                Say "Drive 干跑直接读取源目录，不刷新静态快照: $rcloneSource" 'Cyan'
            } else {
                Say "Drive 上传前先刷新本地静态快照（零流量）: $LocalRoot" 'Cyan'
                New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
                Sync-Local $LocalRoot $false
                $rcloneSource = $LocalRoot
            }
            # 连通性预检：代理/海外网络没就绪则返回失败，交给计划任务重试（rclone copy 幂等续传）
            & rclone lsd "$GDriveRemote" --max-depth 1 --contimeout 15s --timeout 20s --retries 1 *> $null
            if ($LASTEXITCODE -ne 0) {
                Say "Drive 不可达(代理/海外网络未就绪)，本轮失败，下次重试" 'Red'
                $overallExitCode = 1
                break
            }
            $dest = "$GDriveRemote$GDriveFolder"
            # 默认上传完整原应用数据（db + 媒体），rclone copy 会自动跳过 Drive 已有文件。
            # 只有显式 -DbOnly 时才只上传 db_storage，用作临时省流量模式。
            if (-not $DbOnly -or $DriveFull) {
                $filter  = $exclDirs | ForEach-Object { '--exclude'; "$_/**" }
                Say "  Drive范围: 完整原应用数据(db+媒体)" 'Yellow'
            } else {
                # 只收 db_storage 下的库及其 WAL/SHM/journal 伴随文件，其他(媒体等)全排。
                $filter = @('--filter','+ **/db_storage/**','--filter','- *')
                Say "  Drive范围: 仅数据库db_storage(-DbOnly省流量模式)" 'Cyan'
            }
            # copy=只增不删（历史安全）；源为静态快照 $LocalRoot（非微信源目录）
            $rc = @($rcloneSource, $dest) + $filter + @(
                 '--bwlimit', $BwLimit, '--transfers', '8', '--checkers', '16',
                 '--drive-chunk-size', '64M', '--fast-list', '--checksum',
                 '--retries', '3', '--low-level-retries', '10',
                 '--log-file', $log, '--log-level', 'INFO', '--stats', '30s'
            )
            # 流量硬封顶（兜底不浪费海外流量）：MaxTransfer=0/空 → 不封顶（仅首次全量用，需严密监控）
            if ($MaxTransfer -and $MaxTransfer -ne '0') {
                $rc += @('--max-transfer', $MaxTransfer, '--cutoff-mode', 'cautious')
                Say "  流量封顶: --max-transfer $MaxTransfer (cautious=绝不超限)" 'Yellow'
            } else {
                Say "  ⚠ 流量封顶已关闭（首次全量模式）——请严密监控上传进度" 'Magenta'
            }
            if ($List) { $rc += '--dry-run' }
            Say "rclone copy $rcloneSource -> $dest $(if($List){'(干跑)'})"
            & rclone copy @rc
            $copyExit = $LASTEXITCODE
            Say "  rclone copy exit=$copyExit" $(if($copyExit -eq 0){'Green'}else{'Red'})
            if ($copyExit -ne 0) { $overallExitCode = 1 }

            if (-not $List) {
                $checkArgs = @(
                    $rcloneSource, $dest
                ) + $filter + @(
                    '--one-way', '--fast-list', '--checkers', '16',
                    '--retries', '3', '--low-level-retries', '10',
                    '--log-file', $log, '--log-level', 'INFO'
                )
                Say "rclone check（内容级校验） $rcloneSource -> $dest" 'Cyan'
                & rclone check @checkArgs
                $checkExit = $LASTEXITCODE
                Say "  rclone check exit=$checkExit" $(if($checkExit -eq 0){'Green'}else{'Red'})
                if ($checkExit -ne 0) { $overallExitCode = 1 }
            }

        }
        default { Say "未知 Target: $t" 'Yellow' }
    }
}
if ($overallExitCode -eq 0) {
    Say "==== 完成：备份复制与远端内容校验通过；这不等于官方微信已恢复可用 ====" 'Green'
} else {
    Say "==== 失败：上传或内容校验未通过，下一次任务应继续重试 ====" 'Red'
}
exit $overallExitCode
