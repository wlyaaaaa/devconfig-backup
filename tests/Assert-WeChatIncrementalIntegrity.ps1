[CmdletBinding()]
param(
    [string] $RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$backupScript = Get-Content -LiteralPath (Join-Path $RepoRoot 'Backup-WeChat.ps1') -Raw
$monitorScript = Get-Content -LiteralPath (Join-Path $RepoRoot 'Monitor-WeChatDrive.ps1') -Raw
$restoreScript = Get-Content -LiteralPath (Join-Path $RepoRoot 'Restore-WeChat.ps1') -Raw
Assert-Condition ($backupScript -match "'--checksum'") 'Backup-WeChat.ps1 must pass --checksum to rclone copy.'
Assert-Condition ($monitorScript -notmatch "'--size-only'") 'Monitor-WeChat.ps1 must not use --size-only for final verification.'
Assert-Condition ($restoreScript -match '\[switch\]\s+\$DriveOnly') 'Restore-WeChat.ps1 must expose -DriveOnly.'

$rclone = (Get-Command rclone -ErrorAction SilentlyContinue).Source
if (-not $rclone -and (Test-Path -LiteralPath 'E:\Scoop\shims\rclone.exe')) {
    $rclone = 'E:\Scoop\shims\rclone.exe'
}
Assert-Condition ([bool]$rclone) 'rclone is required for this test.'

$root = Join-Path $env:TEMP ('wechat-integrity-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$remote = Join-Path $root 'remote'

try {
    New-Item -ItemType Directory -Path $source, $remote -Force | Out-Null
    $file = Join-Path $source 'same-size-same-time.bin'
    [IO.File]::WriteAllBytes($file, [byte[]](1..64))
    $fixedTime = [datetime]::UtcNow.AddMinutes(-10)
    [IO.File]::SetLastWriteTimeUtc($file, $fixedTime)

    & $rclone copy $source $remote
    Assert-Condition ($LASTEXITCODE -eq 0) 'Initial rclone copy failed.'
    $before = (Get-FileHash $file -Algorithm MD5).Hash

    [IO.File]::WriteAllBytes($file, [byte[]](65..128))
    [IO.File]::SetLastWriteTimeUtc($file, $fixedTime)

    & $rclone copy $source $remote
    Assert-Condition ($LASTEXITCODE -eq 0) 'Default comparison copy failed.'
    $stale = (Get-FileHash (Join-Path $remote 'same-size-same-time.bin') -Algorithm MD5).Hash
    Assert-Condition ($stale -eq $before) 'The fixture did not reproduce the same-size/same-time stale-content case.'

    & $rclone copy $source $remote --checksum
    Assert-Condition ($LASTEXITCODE -eq 0) 'Checksum copy failed.'
    $updated = (Get-FileHash (Join-Path $remote 'same-size-same-time.bin') -Algorithm MD5).Hash
    Assert-Condition ($updated -ne $before) 'Checksum copy did not update changed content.'

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $dryRun = & $rclone copy $source $remote --checksum --dry-run 2>&1 | Out-String
    $ErrorActionPreference = $previousErrorAction
    Assert-Condition ($LASTEXITCODE -eq 0) 'Unchanged checksum dry-run failed.'
    Assert-Condition ($dryRun -notmatch 'Copied') 'Unchanged checksum dry-run reported a copy action.'

    & $rclone check $source $remote --one-way
    Assert-Condition ($LASTEXITCODE -eq 0) 'Checksum check failed.'

    Write-Host 'PASS: checksum incremental integrity and no-change skip.'
    exit 0
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
