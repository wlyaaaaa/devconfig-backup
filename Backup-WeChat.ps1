<#
.SYNOPSIS
  微信聊天记录增量备份（独立于 DevConfig 配置包）。
.DESCRIPTION
  仅备份"历史聊天记录"(msg/db_storage/business/config/resource/all_users/old_backup)，
  剔除缓存/临时/小程序运行时(cache/temp/WMPF/apm_record)。
  增量方式：robocopy /E（只增不删，历史永不丢失）+ rclone copy（Drive 只传新增/改动）。
  首次运行为全量(~38GB)；之后仅复制变化的库与新增媒体。
  【Drive 流量安全】① 绝不直传微信源目录(运行时数据库边传边改→反复重传烧流量)，
    而是先 robocopy 到本地静态快照再从快照上传；② 上云排除 SQLite 运行时文件
    (.db-wal/.db-shm/.db-journal，恢复时自动重建)；③ rclone copy 自动跳过已上传文件。
.EXAMPLE
  pwsh -File Backup-WeChat.ps1 -List           # 干跑，只估算将复制的量（强烈建议先跑）
  pwsh -File Backup-WeChat.ps1 -Target Usb      # 增量到U盘（零流量，推荐主力）
  pwsh -File Backup-WeChat.ps1 -Target Local    # 增量到本地另一盘
  pwsh -File Backup-WeChat.ps1 -Target Drive    # 完整聊天记录增量到 Google Drive（含媒体，默认8G封顶）
  pwsh -File Backup-WeChat.ps1 -Target Drive -DbOnly # 仅数据库上云，媒体只留U盘（省流量模式）
.NOTES
  38GB 首次上传 Drive 很费海外流量；完成后 rclone copy 会自动跳过已存在文件，后续只传增量。
  默认单次 Drive 上传设置 8G 流量保险丝；确需一次性补齐时可显式传 -MaxTransfer 0。
#>
[CmdletBinding()]
param(
    [string[]] $Target = @('Usb'),
    [string]   $Source       = 'E:\Documents\xwechat_files',
    [string]   $UsbRoot      = '',
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
$autoBackupDirName = '80_' + (-join @([char]0x81EA, [char]0x52A8, [char]0x5907, [char]0x4EFD, [char]0x533A))
if ([string]::IsNullOrWhiteSpace($UsbRoot)) {
    $UsbRoot = Join-Path (Join-Path (Join-Path 'H:\' $autoBackupDirName) 'WeChat') 'xwechat_files'
}
$Target = @($Target) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# 剔除：缓存/临时/小程序运行时/崩溃日志（历史本体在 msg / db_storage）
$exclDirs = @('cache','Cache','temp','Temp','WMPF','apm_record','crash','FileStorageTemp','recommend_cover')

$LogDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$log = Join-Path $LogDir ("wechat-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Say($m,$c='Gray'){ $l="{0} {1}" -f (Get-Date -Format 'HH:mm:ss'),$m; Write-Host $l -ForegroundColor $c; Add-Content -LiteralPath $log -Value $l -Encoding UTF8 }

if (-not (Test-Path -LiteralPath $Source)) { Say "源不存在: $Source" 'Red'; exit 1 }
Say "==== WeChat backup | Target=$($Target -join ',') | List=$List ====" 'Cyan'

$script:HDriveUsbWriteLockName = 'Global\CodexHDriveUsbWriteLock'
$script:UsbFreeSpaceBufferBytes = 1GB

function Format-Bytes {
    param([Nullable[Int64]]$Bytes)
    if ($null -eq $Bytes) { return 'unknown' }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Get-DriveRootFromPath {
    param([string]$Path)
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    return $root.TrimEnd('\')
}

function Get-HDriveUsbStatus {
    param([string]$TargetRoot)

    $drive = Get-DriveRootFromPath $TargetRoot
    $status = [ordered]@{
        Drive             = $drive
        Exists            = $false
        Dirty             = $null
        DirtySource       = ''
        HealthStatus      = 'Unknown'
        OperationalStatus = @('Unknown')
        FullRepairNeeded  = $false
        RepairNeeded      = $false
        FreeBytes         = $null
        SizeBytes         = $null
        Error             = ''
    }

    if ([string]::IsNullOrWhiteSpace($drive)) {
        $status.Error = "无法从 UsbRoot 解析盘符: $TargetRoot"
        return [pscustomobject]$status
    }

    $root = "$drive\"
    $status.Exists = Test-Path -LiteralPath $root
    if (-not $status.Exists) { return [pscustomobject]$status }

    try {
        $logical = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive.Replace("'", "''")) -ErrorAction Stop
        if ($logical) {
            if ($null -ne $logical.VolumeDirty) {
                $status.Dirty = [bool]$logical.VolumeDirty
                $status.DirtySource = 'Win32_LogicalDisk.VolumeDirty'
            }
            if ($null -ne $logical.FreeSpace) { $status.FreeBytes = [Int64]$logical.FreeSpace }
            if ($null -ne $logical.Size) { $status.SizeBytes = [Int64]$logical.Size }
        }
    } catch {
        $status.Error = "CIM 查询失败: $($_.Exception.Message)"
    }

    if ($null -eq $status.Dirty) {
        try {
            $dirtyOutput = & fsutil dirty query $drive 2>&1
            if ($LASTEXITCODE -eq 0) {
                $dirtyText = ($dirtyOutput -join "`n")
                if ($dirtyText -match 'NOT\s+Dirty') {
                    $status.Dirty = $false
                    $status.DirtySource = 'fsutil dirty query'
                } elseif ($dirtyText -match 'Dirty') {
                    $status.Dirty = $true
                    $status.DirtySource = 'fsutil dirty query'
                }
            } elseif ([string]::IsNullOrWhiteSpace($status.Error)) {
                $status.Error = "fsutil dirty query exit=$LASTEXITCODE"
            }
        } catch {
            if ([string]::IsNullOrWhiteSpace($status.Error)) { $status.Error = "fsutil dirty query 失败: $($_.Exception.Message)" }
        }
    }

    if ($drive -match '^([A-Za-z]):$') {
        try {
            $volume = Get-Volume -DriveLetter $matches[1] -ErrorAction Stop
            if ($volume) {
                $status.HealthStatus = [string]$volume.HealthStatus
                $ops = @($volume.OperationalStatus | ForEach-Object { [string]$_ })
                if ($ops.Count -gt 0) { $status.OperationalStatus = $ops }
                if ($null -ne $volume.SizeRemaining) { $status.FreeBytes = [Int64]$volume.SizeRemaining }
                if ($null -ne $volume.Size) { $status.SizeBytes = [Int64]$volume.Size }
                $opText = $status.OperationalStatus -join ','
                $status.FullRepairNeeded = ($opText -match 'Full Repair Needed')
                $status.RepairNeeded = ($opText -match 'Full Repair Needed|Spot Fix Needed|Needs Scan')
            }
        } catch {
            if ([string]::IsNullOrWhiteSpace($status.Error)) { $status.Error = "Get-Volume 查询失败: $($_.Exception.Message)" }
        }
    }

    return [pscustomobject]$status
}

function Test-HDriveUsbReady {
    param(
        [string]$TargetRoot,
        [Int64]$RequiredBytes
    )

    $status = Get-HDriveUsbStatus -TargetRoot $TargetRoot
    if (-not $status.Exists) { Say "U盘 $($status.Drive) 未插入，跳过 USB 写入" 'Yellow'; return $false }
    if ($status.Dirty -eq $true) { Say "U盘 $($status.Drive) dirty=True（$($status.DirtySource)），跳过 USB 写入" 'Yellow'; return $false }
    if ($null -eq $status.Dirty) { Say "无法确认 U盘 $($status.Drive) dirty 状态，跳过 USB 写入；$($status.Error)" 'Yellow'; return $false }
    if ($status.FullRepairNeeded -or $status.RepairNeeded) { Say "U盘 $($status.Drive) OperationalStatus=$($status.OperationalStatus -join ',')，跳过 USB 写入" 'Yellow'; return $false }
    if ($status.HealthStatus -and $status.HealthStatus -notin @('Healthy','Unknown')) { Say "U盘 $($status.Drive) HealthStatus=$($status.HealthStatus)，跳过 USB 写入" 'Yellow'; return $false }
    if ($null -eq $status.FreeBytes) { Say "无法确认 U盘 $($status.Drive) 剩余空间，跳过 USB 写入；$($status.Error)" 'Yellow'; return $false }

    $needed = [Int64]([Math]::Max(0, $RequiredBytes) + $script:UsbFreeSpaceBufferBytes)
    if ($status.FreeBytes -lt $needed) {
        Say "U盘 $($status.Drive) 剩余空间不足：剩余 $(Format-Bytes $status.FreeBytes)，预计需 $(Format-Bytes $RequiredBytes) + 1 GB 缓冲，跳过 USB 写入" 'Yellow'
        return $false
    }

    Say "U盘门禁通过: $($status.Drive) dirty=False health=$($status.HealthStatus) op=$($status.OperationalStatus -join ',') free=$(Format-Bytes $status.FreeBytes)" 'Green'
    return $true
}

function Get-DirectoryRequiredBytes {
    param([string]$Src, [string]$Dst)
    [Int64]$required = 0
    if (-not (Test-Path -LiteralPath $Src)) { return 0 }
    Get-ChildItem -LiteralPath $Src -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($Src.TrimEnd('\').Length).TrimStart('\')
        $destFile = Join-Path $Dst $rel
        [Int64]$existing = 0
        if (Test-Path -LiteralPath $destFile) { $existing = [Int64](Get-Item -LiteralPath $destFile).Length }
        $required += [Int64][Math]::Max(0, ([Int64]$_.Length - $existing))
    }
    return $required
}

function Invoke-WithHDriveUsbWriteLock {
    param([scriptblock]$Body)

    $mutex = $null
    $acquired = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $script:HDriveUsbWriteLockName)
        Say "等待 USB 写入锁 $script:HDriveUsbWriteLockName ..."
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(30)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true; Say "USB 写入锁曾被异常释放，已接管继续执行" 'Yellow' }
        if (-not $acquired) { Say "等待 USB 写入锁超时，跳过 USB 写入" 'Yellow'; return $false }
        & $Body
        return $true
    } catch {
        Say "USB 写入锁异常，跳过 USB 写入: $($_.Exception.Message)" 'Red'
        return $false
    } finally {
        if ($acquired -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Sync-Local([string]$dst, [bool]$listOnly, [int]$Threads = 16) {
    $a = @($Source, $dst, '/E','/R:1','/W:1',"/MT:$Threads",'/NDL','/NP','/XD') + $exclDirs
    if ($listOnly) { $a += '/L' }       # /L = 只列出，不实际复制
    Say "robocopy -> $dst $(if($listOnly){'(干跑)'})"
    & robocopy @a | Out-Null
    Say "  robocopy exit=$LASTEXITCODE (0-7 正常)" 'Green'
}

foreach ($t in $Target) {
    switch ($t) {
        'Usb' {
            if ($List) {
                $status = Get-HDriveUsbStatus -TargetRoot $UsbRoot
                Say "U盘干跑状态: exists=$($status.Exists) dirty=$($status.Dirty) health=$($status.HealthStatus) op=$($status.OperationalStatus -join ',') free=$(Format-Bytes $status.FreeBytes)" 'Yellow'
                Sync-Local $UsbRoot $true 4
                break
            }
            Invoke-WithHDriveUsbWriteLock {
                if (-not (Test-HDriveUsbReady -TargetRoot $UsbRoot -RequiredBytes 0)) { return }
                $requiredBytes = Get-DirectoryRequiredBytes -Src $Source -Dst $UsbRoot
                if (-not (Test-HDriveUsbReady -TargetRoot $UsbRoot -RequiredBytes $requiredBytes)) { return }
                New-Item -ItemType Directory -Path $UsbRoot -Force | Out-Null
                Sync-Local $UsbRoot $false 4
            } | Out-Null
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
            # 治本：绝不直传微信源目录——微信运行时数据库在被写入，rclone 上传中途
            # 检测到 modtime 变化即报 "source file is being updated" 并整文件从头重传，
            # 反复烧海外流量却传不成功。改为先 robocopy 源→本地静态快照（零流量），
            # 再从这份"不会被微信改写"的快照上传，从根上消除边传边改的重传循环。
            Say "Drive 上传前先刷新本地静态快照（零流量）: $LocalRoot" 'Cyan'
            New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
            Sync-Local $LocalRoot $false
            # 连通性预检：代理/海外网络没就绪则优雅跳过，下次自动重试（rclone copy 幂等续传）
            & rclone lsd "$GDriveRemote" --max-depth 1 --contimeout 15s --timeout 20s --retries 1 *> $null
            if ($LASTEXITCODE -ne 0) { Say "Drive 不可达(代理/海外网络未就绪)，跳过，下次重试" 'Yellow'; break }
            $dest = "$GDriveRemote$GDriveFolder"
            # 默认上传完整聊天历史（db + 媒体），rclone copy 会自动跳过 Drive 已有文件。
            # 只有显式 -DbOnly 时才只上传 db_storage，用作临时省流量模式。
            if (-not $DbOnly -or $DriveFull) {
                $filter  = $exclDirs | ForEach-Object { '--exclude'; "$_/**" }
                $filter += @('--exclude','*.db-wal','--exclude','*.db-shm','--exclude','*.db-journal')
                Say "  Drive范围: 完整聊天历史(db+媒体)" 'Yellow'
            } else {
                # 只收 db_storage 下的库: 先排运行时文件, 再只收 db_storage, 其余(媒体等)全排
                $filter = @('--filter','- *.db-wal','--filter','- *.db-shm','--filter','- *.db-journal',
                            '--filter','+ **/db_storage/**','--filter','- *')
                Say "  Drive范围: 仅数据库db_storage(-DbOnly省流量模式)" 'Cyan'
            }
            # copy=只增不删（历史安全）；源为静态快照 $LocalRoot（非微信源目录）
            $rc = @($LocalRoot, $dest) + $filter + @(
                '--bwlimit', $BwLimit, '--transfers', '8', '--checkers', '16',
                '--drive-chunk-size', '64M', '--fast-list',
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
            Say "rclone copy $LocalRoot -> $dest $(if($List){'(干跑)'})"
            & rclone copy @rc
            Say "  rclone exit=$LASTEXITCODE" 'Green'
            # 方案A: 上传解密密钥(几KB,恢复命门)——明文(用户授权,Drive 高级保护可信)
            $keyDir = 'E:\WeChatBackup\_KEYS'
            if (Test-Path $keyDir) {
                $keyDest = "$GDriveRemote" + "Backups/WeChat/_KEYS"
                $kc = @($keyDir, $keyDest, '--log-file', $log, '--log-level', 'INFO')
                if ($List) { $kc += '--dry-run' }
                Say "上传密钥 -> $keyDest $(if($List){'(干跑)'})" 'Cyan'
                & rclone copy @kc
                Say "  密钥上传 exit=$LASTEXITCODE" 'Green'
            } else { Say "  未找到密钥目录 $keyDir，跳过密钥上传" 'Yellow' }
        }
        default { Say "未知 Target: $t" 'Yellow' }
    }
}
Say "==== 完成 ====" 'Green'
exit 0
