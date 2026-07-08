<#
.SYNOPSIS
  微信聊天记录恢复/合成（方案A的恢复侧）。
.DESCRIPTION
  把分散在「U盘(媒体全量) + Google Drive(db_storage+密钥) + 本地_KEYS(密钥)」的备份,
  合成为完整的 xwechat_files 到本机,再用密钥解密查看。
  默认恢复到本机微信目录。优先用 U盘(零流量、全量),Drive 仅补更新的 db。
.EXAMPLE
  pwsh -File Restore-WeChat.ps1 -List          # 干跑,只看将合成什么,不实际写
  pwsh -File Restore-WeChat.ps1                 # 合成到默认本机目录
  pwsh -File Restore-WeChat.ps1 -Target D:\wx_restore   # 合成到指定目录
.NOTES
  【恢复原理】db 是 SQLCipher 加密;密钥已固化在 _KEYS(亦泊 len133/WeFlow格式,root len64/wx_key裸hex)。
  合成完数据后,用 WeFlow 或 wx_key「打开指定 db 路径 + 填入对应 decryptKey」即可解密查看/导出。
  密钥一旦固化,解密只需「密钥+db文件」,不再依赖原设备 IMEI——任何机器都能解。
#>
[CmdletBinding()]
param(
    [string] $Target       = 'E:\Documents\xwechat_files',
    [string] $UsbRoot      = '',
    [string] $UsbKeys      = '',
    [string] $GDriveRemote = 'gdrive:',
    [string] $GDriveFolder = 'Backups/WeChat/xwechat_files',
    [switch] $List
)
$ErrorActionPreference = 'Continue'
$autoBackupDirName = '80_' + (-join @([char]0x81EA, [char]0x52A8, [char]0x5907, [char]0x4EFD, [char]0x533A))
$usbWeChatRoot = Join-Path (Join-Path 'H:\' $autoBackupDirName) 'WeChat'
if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Join-Path $usbWeChatRoot 'xwechat_files' }
if ([string]::IsNullOrWhiteSpace($UsbKeys)) { $UsbKeys = Join-Path $usbWeChatRoot '_KEYS' }
function Say($m,$c='Gray'){ Write-Host ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'),$m) -ForegroundColor $c }

Say "==== WeChat 恢复合成 -> $Target $(if($List){'(干跑)'}) ====" 'Cyan'

# 1) U盘媒体+db 全量合成(零流量、最快、最全) —— 主力
if (Test-Path $UsbRoot) {
    $a = @($UsbRoot, $Target, '/E','/R:1','/W:1','/MT:16','/NDL','/NP')
    if ($List) { $a += '/L' }
    Say "① 从 U盘合成全量(媒体+db): $UsbRoot" 'Green'
    & robocopy @a | Out-Null
    Say "   robocopy exit=$LASTEXITCODE (0-7 正常)"
} else {
    Say "① U盘不在($UsbRoot)——跳过,只能靠 Drive(将缺媒体)" 'Yellow'
}

# 2) Drive 补更新的 db_storage(若 Drive 的 db 比 U盘新) —— 仅传更新,流量小
if (Get-Command rclone -ErrorAction SilentlyContinue) {
    $remotes = @(& rclone listremotes 2>$null)
    if ($remotes -and ($remotes -notcontains $GDriveRemote)) { $GDriveRemote = $remotes[0] }
    & rclone lsd "$GDriveRemote" --max-depth 1 --contimeout 15s --timeout 20s --retries 1 *> $null
    if ($LASTEXITCODE -eq 0) {
        $src = "$GDriveRemote$GDriveFolder"
        $rc = @($src, $Target, '--include','**/db_storage/**','--exclude','*','--update','--transfers','8','--checkers','16','--fast-list')
        if ($List) { $rc += '--dry-run' }
        Say "② 从 Drive 补更新的数据库(db_storage)" 'Green'
        & rclone copy @rc
        Say "   rclone exit=$LASTEXITCODE"
    } else { Say "② Drive 不可达(代理没开?)——跳过,U盘的 db 已够用" 'Yellow' }
} else { Say "② rclone 未安装——跳过 Drive 补传" 'Yellow' }

# 3) 释放密钥到恢复目录旁,并给出解密指引
$keySrc = $null
foreach ($k in @($UsbKeys, 'E:\WeChatBackup\_KEYS')) {
    if (Test-Path $k) { $latest = Get-ChildItem $k -Filter 'wechat-keys-COMPLETE-*.json' -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1; if ($latest) { $keySrc = $latest.FullName; break } }
}
if ($keySrc -and -not $List) {
    $keyDst = Join-Path (Split-Path $Target -Parent) ('_WeChat_KEYS_' + (Split-Path $keySrc -Leaf))
    Copy-Item -LiteralPath $keySrc -Destination $keyDst -Force
    Say "③ 密钥已就位: $keyDst" 'Green'
} elseif ($keySrc) { Say "③ 密钥可用: $keySrc (干跑不复制)" 'Green' }
else { Say "③ 未找到密钥文件(_KEYS\wechat-keys-COMPLETE-*.json)!没有密钥无法解密" 'Red' }

Say "==== 数据合成完成 ====" 'Green'
Say ""
Say "【下一步·解密查看】" 'Cyan'
Say "  1. 安装 WeFlow(或用 _tools\wx_key) —— 任意机器均可,不依赖原设备"
Say "  2. 在工具里「指定数据目录=$Target」"
Say "  3. 手动填入对应账号的 decryptKey(见上面③的密钥文件):"
Say "     (各账号 wxid 与密钥/格式见 _KEYS\wechat-keys-COMPLETE-*.json 的 keyFormat 字段)"
Say "     注意: 不同账号 decryptKey 格式可能不同(WeFlow格式 vs wx_key裸hex),按文件对应使用"
Say "  4. 即可解密查看/导出聊天记录(HTML/JSON等)"
exit 0
