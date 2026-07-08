<#
.SYNOPSIS
  备份状态/进度面板：任务结果、各处备份新鲜度、Drive 上次成功、微信上传进度、最近日志。
.EXAMPLE
  pwsh -File Backup-Status.ps1            # 一览
  pwsh -File Backup-Status.ps1 -LogLines 25
  # 实时跟最新日志：  Get-Content (gci E:\DevConfigBackup\logs\*.log | sort LastWriteTime)[-1] -Wait -Tail 20
#>
[CmdletBinding()]
param([int]$LogLines = 12, [switch]$NoDrive)

$dir   = $PSScriptRoot
$state = Join-Path $dir 'state'
$logs  = Join-Path $dir 'logs'
function GB($b){ '{0:N2} GB' -f ($b/1GB) }
function Age($t){ if(-not $t){return '—'}; $d=(Get-Date)-$t; if($d.TotalDays -ge 1){'{0:N0} 天前' -f $d.TotalDays}elseif($d.TotalHours -ge 1){'{0:N0} 小时前' -f $d.TotalHours}else{'{0:N0} 分钟前' -f $d.TotalMinutes} }
function Line(){ Write-Host ('-'*60) -ForegroundColor DarkGray }

Write-Host "`n===== DevConfig / WeChat 备份状态  $(Get-Date -Format 'yyyy-MM-dd HH:mm') =====" -ForegroundColor Cyan

# 1) 计划任务
Line; Write-Host "① 计划任务" -ForegroundColor Yellow
Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' -ErrorAction SilentlyContinue | ForEach-Object {
    $i = $_ | Get-ScheduledTaskInfo
    $r = switch ($i.LastTaskResult) { 0 {'OK'} 267009 {'运行中'} 267011 {'未运行过'} default {"err=$($i.LastTaskResult)"} }
    '{0,-26} {1,-7} 上次:{2}  结果:{3}  下次:{4}' -f $_.TaskName, $_.State,
        $(if($i.LastRunTime){$i.LastRunTime.ToString('MM-dd HH:mm')}else{'—'}), $r,
        $(if($i.NextRunTime){$i.NextRunTime.ToString('MM-dd HH:mm')}else{'—'})
}

# 2) 本地 / U盘
Line; Write-Host "② 本地 & U盘" -ForegroundColor Yellow
$lz = Join-Path $dir 'out\latest.zip'
if (Test-Path $lz) { '本地 latest.zip : {0:N1} MB  ({1})' -f ((Get-Item $lz).Length/1MB), (Age (Get-Item $lz).LastWriteTime) }
$dated = Get-ChildItem (Join-Path $dir 'out') -Filter 'devconfig-*.zip' -ErrorAction SilentlyContinue
'本地带日期版   : {0} 份  {1}' -f $dated.Count, (($dated | Sort-Object Name -Descending | Select-Object -First 3 -ExpandProperty Name) -join ', ')
$autoBackupDirName = '80_' + (-join @([char]0x81EA, [char]0x52A8, [char]0x5907, [char]0x4EFD, [char]0x533A))
$usbBackupRoot = Join-Path 'H:\' $autoBackupDirName
$ud = Join-Path $usbBackupRoot 'DevConfig'
$uw = Join-Path (Join-Path $usbBackupRoot 'WeChat') 'xwechat_files'
if (Test-Path 'H:\') {
    if (Test-Path $ud) { $z=Get-ChildItem $ud -Filter 'devconfig-*.zip'; 'U盘 配置       : {0} 份带日期, 最新 {1}' -f $z.Count, (Age ($z|Sort LastWriteTime|Select -Last 1).LastWriteTime) }
    if (Test-Path $uw) { $w=Get-ChildItem $uw -Recurse -File -ErrorAction SilentlyContinue|Measure-Object Length -Sum; 'U盘 微信       : {0} ({1} 文件)' -f (GB $w.Sum), $w.Count }
} else { Write-Host 'U盘 H: 未插入' -ForegroundColor DarkGray }

# 3) Drive
if (-not $NoDrive) {
    Line; Write-Host "③ Google Drive (海外)" -ForegroundColor Yellow
    $ds = Join-Path $state 'last-drive-success.txt'
    if (Test-Path $ds) { $t=[datetime]::Parse((Get-Content $ds -Raw).Trim()); Write-Host ("配置上次成功上云: {0}  ({1})" -f $t.ToString('yyyy-MM-dd HH:mm'), (Age $t)) -ForegroundColor Green }
    else { Write-Host '配置上次成功上云: 无记录' -ForegroundColor DarkGray }
    $remote = (& rclone listremotes 2>$null | Select-Object -First 1)
    if ($remote) {
        Write-Host "连通性测试 ..." -NoNewline
        & rclone lsd "$remote" --max-depth 1 --contimeout 10s --timeout 15s --retries 1 *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host " 可达 ✓" -ForegroundColor Green
            $cfg = & rclone lsf "${remote}Backups/WLY" 2>$null
            "  配置: $(($cfg | Where-Object {$_ -match 'devconfig'}).Count) 份带日期 + latest.zip"
            $wxsz = (& rclone size "${remote}Backups/WeChat/xwechat_files" --json 2>$null | ConvertFrom-Json)
            if ($wxsz) { "  微信: {0} / ~38 GB ({1} 文件)  {2}" -f (GB $wxsz.bytes), $wxsz.count, $(if($wxsz.bytes -lt 37GB){'⏳上传中'}else{'✓'}) }
        } else { Write-Host " 不可达（代理没开/网络断）——下次触发会自动重试" -ForegroundColor Red }
    } else { Write-Host 'rclone 无已配置远端' -ForegroundColor DarkGray }
}

# 4) 微信→Drive 首次全量进度（若日志存在）
$wdlog = Join-Path $logs 'wechat-drive-firstfull.log'
if (Test-Path $wdlog) {
    Line; Write-Host "④ 微信→Drive 首传日志尾部" -ForegroundColor Yellow
    Get-Content $wdlog -Tail 6 -ErrorAction SilentlyContinue
}

# 5) 最近日志
Line; Write-Host "⑤ 最近一次备份日志" -ForegroundColor Yellow
$last = Get-ChildItem "$logs\backup-*.log","$logs\wechat-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($last) { Write-Host "($($last.Name))" -ForegroundColor DarkGray; Get-Content $last.FullName -Tail $LogLines -Encoding UTF8 }
Line
