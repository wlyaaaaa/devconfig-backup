<#
.SYNOPSIS
  DevConfig 备份：采集开发配置/凭据/系统设置 -> 打包 -> 本地/G盘热备/Drive 分发。
.DESCRIPTION
  内容来自 sources.psd1。剔除可重下的插件/缓存/包/二进制；默认剔除聊天历史。
  Tier 控制分发：Local（产出本地 zip）、Hot（同步到G盘热备）、Drive（rclone 上传，改动才传）。H 冷备统一由 PCConfig 从 G 人工复制。
.EXAMPLE
  pwsh -File Backup-DevConfig.ps1 -Tier Local
  pwsh -File Backup-DevConfig.ps1 -Tier Local,Hot
  pwsh -File Backup-DevConfig.ps1 -Tier Drive
#>
[CmdletBinding()]
param(
    # Local/Hot/Drive 任意组合；-File 传入时可能是 "Local,Hot" 单串，下面会拆分
    [string[]] $Tier = @('Local'),

    [switch]   $IncludeHistory,
    [switch]   $Force,                       # 跳过 Drive 的 hash 门控（测试用）

    [string]   $HotRoot      = 'G:\80_Backup\DevConfig',
    [string]   $GDriveRemote = 'gdrive:',
    [string]   $GDriveFolder = "Backups/$env:COMPUTERNAME",
    [string]   $BwLimit      = '4M',

    [int]      $KeepLocal = 7,
    [int]      $KeepHot   = 7,
    [int]      $KeepDrive = 3
)

$ErrorActionPreference = 'Continue'

# 归一化 Tier：兼容 -File 把 "Local,Hot" 当单串传入的情况
$Tier = @($Tier) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$validTiers = @('Local','Hot','Drive')
$bad = $Tier | Where-Object { $_ -notin $validTiers }
if ($bad) { Write-Host "无效 Tier: $($bad -join ',')（可选 Local/Hot/Drive；H 冷备请使用 PCConfig 人工 G→H 流程）" -ForegroundColor Red; exit 2 }

$Root     = $PSScriptRoot
$Staging  = Join-Path $Root 'staging'
$OutDir   = Join-Path $Root 'out'
$StateDir = Join-Path $Root 'state'
$LogDir   = Join-Path $Root 'logs'
$Home10   = $env:USERPROFILE
$SevenZip = 'E:\Scoop\shims\7z.exe'

foreach ($d in @($Staging,$OutDir,$StateDir,$LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------- 日志 ----------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir "backup-$stamp.log"
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Msg
    $color = switch ($Level) { 'WARN' {'Yellow'} 'ERR' {'Red'} 'OK' {'Green'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

Write-Log "==== DevConfig backup start | Tier=$($Tier -join ',') | History=$IncludeHistory ===="

# ---------- 载入源清单 ----------
$srcFile = Join-Path $Root 'sources.psd1'
if (-not (Test-Path -LiteralPath $srcFile)) { Write-Log "缺少 sources.psd1" 'ERR'; exit 1 }
$cfg = Import-PowerShellDataFile -LiteralPath $srcFile

$excludeDirs  = @($cfg.ExcludeDirs)
$excludeFiles = @($cfg.ExcludeFiles)
if (-not $IncludeHistory) {
    $excludeDirs += @($cfg.HistoryDirs)
    $excludeFiles += @($cfg.HistoryFiles)
}

# ---------- robocopy 包装 ----------
function Invoke-Rc {
    param([string]$Src, [string]$Dst, [string[]]$Excl, [string[]]$ExclF)
    if (-not (Test-Path -LiteralPath $Src)) { Write-Log "  跳过(不存在) $Src" 'WARN'; return }
    $rcArgs = @($Src, $Dst, '/E','/R:1','/W:1','/MT:8','/NFL','/NDL','/NJH','/NJS','/NP','/XJ','/XD') + $Excl
    if ($ExclF) { $rcArgs += @('/XF') + $ExclF }
    & robocopy @rcArgs *> $null
    if ($LASTEXITCODE -ge 8) { Write-Log "  robocopy 异常 exit=${LASTEXITCODE}: $Src" 'WARN' }
}
function Copy-One {
    param([string]$Src, [string]$DstDir)
    if (Test-Path -LiteralPath $Src) {
        New-Item -ItemType Directory -Path $DstDir -Force | Out-Null
        Copy-Item -LiteralPath $Src -Destination $DstDir -Force -ErrorAction SilentlyContinue
    }
}

function Copy-RelativeFile {
    param([string]$Base, [string]$Relative, [string]$OutBase)
    $src = Join-Path $Base $Relative
    if (-not (Test-Path -LiteralPath $src)) { return }
    $parent = Split-Path $Relative -Parent
    $dstDir = if ([string]::IsNullOrWhiteSpace($parent)) { $OutBase } else { Join-Path $OutBase $parent }
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination $dstDir -Force -ErrorAction SilentlyContinue
}

function Copy-RelativeDir {
    param([string]$Base, [string]$Relative, [string]$OutBase, [string[]]$Excl, [string[]]$ExclF)
    $src = Join-Path $Base $Relative
    if (-not (Test-Path -LiteralPath $src)) { Write-Log "  跳过(不存在) $src" 'WARN'; return }
    $dst = Join-Path $OutBase $Relative
    Invoke-Rc $src $dst $Excl $ExclF
}

# ============================================================
# 1) 采集 -> staging
# ============================================================
function Invoke-Gather {
    Write-Log "重建 staging ..."
    if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue }
    $homeOut  = Join-Path $Staging 'home'
    $adOut    = Join-Path $Staging 'appdata-roaming'
    $adlOut   = Join-Path $Staging 'appdata-local'
    $extraOut = Join-Path $Staging 'extra'
    New-Item -ItemType Directory -Path $homeOut,$adOut,$adlOut,$extraOut -Force | Out-Null

    foreach ($f in $cfg.HomeFiles)  { Copy-One (Join-Path $Home10 $f) $homeOut }
    foreach ($f in @($cfg.HomePreciseFiles)) { Copy-RelativeFile $Home10 $f $homeOut }
    foreach ($d in @($cfg.HomePreciseDirs))  { Copy-RelativeDir  $Home10 $d $homeOut $excludeDirs $excludeFiles }
    foreach ($d in $cfg.HomeDirs)   { Invoke-Rc (Join-Path $Home10 $d) (Join-Path $homeOut $d) $excludeDirs $excludeFiles }
    foreach ($d in $cfg.AppDataRoamingDirs) { Invoke-Rc (Join-Path $Home10 "AppData\Roaming\$d") (Join-Path $adOut $d) $excludeDirs $excludeFiles }
    foreach ($f in @($cfg.AppDataRoamingFiles)) { Copy-RelativeFile (Join-Path $Home10 'AppData\Roaming') $f $adOut }
    foreach ($d in $cfg.AppDataLocalDirs)   { Invoke-Rc (Join-Path $Home10 "AppData\Local\$d")   (Join-Path $adlOut $d) $excludeDirs $excludeFiles }
    foreach ($f in $cfg.AppDataLocalFiles)  { Copy-One (Join-Path $Home10 "AppData\Local\$f") (Join-Path $adlOut (Split-Path $f)) }
    foreach ($e in $cfg.ExtraDirs)  { Invoke-Rc $e.Src (Join-Path $extraOut $e.Name) $excludeDirs $excludeFiles }
    foreach ($sf in $cfg.SpecialFiles) { Copy-One (Join-Path $Home10 $sf) (Join-Path $Staging (Join-Path 'special' (Split-Path $sf))) }

    # Windows Terminal settings.json
    $wt = Get-ChildItem "$Home10\AppData\Local\Packages\Microsoft.WindowsTerminal_*\LocalState\settings.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wt) { Copy-One $wt.FullName (Join-Path $adOut 'WindowsTerminal') }
    Write-Log "采集完成" 'OK'
}

# ============================================================
# 2) 系统配置导出 -> staging\_system
# ============================================================
function Invoke-SystemExport {
    $sys = Join-Path $Staging '_system'
    New-Item -ItemType Directory -Path $sys,"$sys\tasks","$sys\wifi" -Force | Out-Null

    foreach ($re in $cfg.RegistryExports) {
        & reg export $re.Key (Join-Path $sys "$($re.Name).reg") /y *> $null
    }
    [Environment]::GetEnvironmentVariable('Path','Machine') -split ';' |
        Where-Object { $_ } | Set-Content (Join-Path $sys 'path-machine.txt') -Encoding UTF8

    $n = 0
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        foreach ($pat in $cfg.ScheduledTaskPatterns) {
            if ($t.TaskName -like $pat) {
                try {
                    (Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop) |
                        Set-Content (Join-Path "$sys\tasks" ("{0}.xml" -f ($t.TaskName -replace '[^\w\-]','_'))) -Encoding Unicode
                    $n++
                } catch {}
                break
            }
        }
    }
    Write-Log "  计划任务导出: $n 个"

    Copy-Item "$env:WINDIR\System32\drivers\etc\hosts" (Join-Path $sys 'hosts') -Force -ErrorAction SilentlyContinue
    & netsh wlan export profile key=clear folder="$sys\wifi" *> $null
    if (-not (Get-ChildItem "$sys\wifi" -ErrorAction SilentlyContinue)) { & netsh wlan export profile folder="$sys\wifi" *> $null }
    Write-Log "系统导出完成" 'OK'
}

# ============================================================
# 3) 重装清单 -> staging\_manifests
# ============================================================
function Invoke-Manifests {
    $man = Join-Path $Staging '_manifests'
    New-Item -ItemType Directory -Path $man -Force | Out-Null

    try { & scoop export *> (Join-Path $man 'scoop.json') } catch {}
    try { & winget export -o (Join-Path $man 'winget.json') --accept-source-agreements *> $null } catch {}
    try { & code   --list-extensions *> (Join-Path $man 'vscode-extensions.txt') }  catch {}
    try { & cursor --list-extensions *> (Join-Path $man 'cursor-extensions.txt') }  catch {}

    $jb = "$Home10\AppData\Roaming\JetBrains"
    if (Test-Path $jb) {
        Get-ChildItem $jb -Directory | ForEach-Object {
            $pl = Join-Path $_.FullName 'plugins'
            if (Test-Path $pl) { "## $($_.Name)"; (Get-ChildItem $pl -Directory -ErrorAction SilentlyContinue).Name; '' }
        } | Set-Content (Join-Path $man 'jetbrains-plugins.txt') -Encoding UTF8
    }

    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } | Select-Object DisplayName, DisplayVersion, Publisher |
        Sort-Object DisplayName -Unique |
        Export-Csv (Join-Path $man 'installed-software.csv') -NoTypeInformation -Encoding UTF8
    Write-Log "重装清单完成" 'OK'
}

# ============================================================
# 4) 打包 + sha256
# ============================================================
function Invoke-Pack {
    $idx = Get-ChildItem -LiteralPath $Staging -Recurse -File -ErrorAction SilentlyContinue
    $sizeMB = [math]::Round((($idx | Measure-Object Length -Sum).Sum)/1MB, 2)
    @("DevConfig backup  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
      "Host: $env:COMPUTERNAME   IncludeHistory: $IncludeHistory",
      "Files: $($idx.Count)   Size: $sizeMB MB") | Set-Content (Join-Path $Staging 'MANIFEST.txt') -Encoding UTF8

    $zip = Join-Path $OutDir "devconfig-$stamp.zip"
    Write-Log "打包 -> $([IO.Path]::GetFileName($zip)) (staging $sizeMB MB) ..."
    & $SevenZip a -tzip -mx=5 -bso0 -bsp0 -- $zip "$Staging\*" *> $null
    if (-not (Test-Path -LiteralPath $zip)) { Write-Log "打包失败" 'ERR'; return $null }

    $zipMB = [math]::Round((Get-Item $zip).Length/1MB, 2)
    $sha   = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $zip -Destination (Join-Path $OutDir 'latest.zip') -Force
    Set-Content (Join-Path $StateDir 'latest.sha256') "$sha  devconfig-$stamp.zip" -Encoding ASCII
    Write-Log "打包完成: $zipMB MB  sha256=$($sha.Substring(0,12))..." 'OK'

    Get-ChildItem $OutDir -Filter 'devconfig-*.zip' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepLocal | Remove-Item -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Zip = $zip; Sha = $sha; MB = $zipMB; Name = "devconfig-$stamp.zip" }
}

# ============================================================
# 5) 分发：G盘热备 / H盘冷备
# ============================================================
function Push-Hot {
    param($Pack)
    New-Item -ItemType Directory -Path $HotRoot -Force | Out-Null
    Copy-Item -LiteralPath $Pack.Zip -Destination $HotRoot -Force
    Copy-Item -LiteralPath (Join-Path $OutDir 'latest.zip') -Destination $HotRoot -Force
    Get-ChildItem $HotRoot -Filter 'devconfig-*.zip' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepHot | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Log "G盘热备同步完成 -> $HotRoot" 'OK'
}

# ============================================================
# 6) 分发：Google Drive（rclone，改动才传）
# ============================================================
function Push-Drive {
    param($Pack)
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) { Write-Log "rclone 未安装，跳过 Drive" 'WARN'; return }
    # 远端解析：默认用 $GDriveRemote，不存在则回退到第一个已配置远端（适配任意命名）
    $remotes = @(& rclone listremotes 2>$null)
    if ($remotes -notcontains $GDriveRemote) {
        if ($remotes.Count) { $GDriveRemote = $remotes[0]; Write-Log "  默认远端不存在，改用 $GDriveRemote" }
        else { Write-Log "rclone 无已配置远端，跳过 Drive" 'WARN'; return }
    }
    $lastFile = Join-Path $StateDir 'last-uploaded.sha256'
    $last = if (Test-Path $lastFile) { (Get-Content $lastFile -Raw).Trim() } else { '' }
    if (-not $Force -and $last -eq $Pack.Sha) { Write-Log "内容未变化(sha 相同)，跳过 Drive 上传" 'OK'; return }

    # 连通性预检：代理没开/海外网络不通时优雅跳过（下次触发自动重试，不报错为失败）
    & rclone lsd "$GDriveRemote" --max-depth 1 --contimeout 15s --timeout 20s --retries 1 --low-level-retries 2 *> $null
    if ($LASTEXITCODE -ne 0) { Write-Log "Drive 不可达(代理/海外网络未就绪)，跳过本次，下次触发自动重试" 'WARN'; return }

    $dest = "$GDriveRemote$GDriveFolder"
    Write-Log "rclone 上传 -> $dest/$($Pack.Name) (bwlimit=$BwLimit) ..."
    # 强重试 + 断点续传（rclone copy 幂等：进程被中断后再次运行自动跳过已传文件）
    & rclone copyto $Pack.Zip "$dest/$($Pack.Name)" --bwlimit $BwLimit --transfers 1 --retries 5 --retries-sleep 30s --low-level-retries 20 --timeout 120s
    if ($LASTEXITCODE -eq 0) {
        & rclone copy (Join-Path $OutDir 'latest.zip') $dest --bwlimit $BwLimit --retries 3 *> $null
        Set-Content $lastFile $Pack.Sha -Encoding ASCII
        Set-Content (Join-Path $StateDir 'last-drive-success.txt') (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding ASCII
        $remote = (& rclone lsf $dest --include 'devconfig-*.zip' 2>$null) | Sort-Object -Descending
        if ($remote.Count -gt $KeepDrive) { $remote | Select-Object -Skip $KeepDrive | ForEach-Object { & rclone deletefile "$dest/$_" *> $null } }
        Write-Log "Drive 上传完成" 'OK'
    } else { Write-Log "rclone 上传失败 exit=$LASTEXITCODE（部分已传，下次自动续传）" 'ERR' }
}

# ============================================================
# 主流程
# ============================================================
$pack = $null
if ($Tier -contains 'Local' -or $Tier -contains 'Hot') {
    Invoke-Gather; Invoke-SystemExport; Invoke-Manifests
    $pack = Invoke-Pack
} else {
    $lz = Join-Path $OutDir 'latest.zip'
    if (Test-Path $lz) {
        # 从 state 解析带日期的文件名（用于在 Drive 存日期版）
        $sf = Join-Path $StateDir 'latest.sha256'
        $datedName = if (Test-Path $sf) { ((Get-Content $sf -Raw).Trim() -split '\s+')[-1] } else { "devconfig-$stamp.zip" }
        $pack = [pscustomobject]@{ Zip = $lz; Sha = (Get-FileHash $lz -Algorithm SHA256).Hash; MB = [math]::Round((Get-Item $lz).Length/1MB,2); Name = $datedName }
    }
    else { Write-Log "无 latest.zip，Drive 需先跑一次 Local" 'ERR'; exit 1 }
}
if ($pack) {
    if ($Tier -contains 'Hot')   { Push-Hot   $pack }
    if ($Tier -contains 'Drive') { Push-Drive $pack }
}
Write-Log "==== 完成 ====" 'OK'
exit 0
