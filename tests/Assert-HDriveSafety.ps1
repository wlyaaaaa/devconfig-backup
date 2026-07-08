param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-Text {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "Assertion failed: $Name" }
    Write-Host "PASS: $Name"
}

$devScript = Join-Path $RepoRoot 'Backup-DevConfig.ps1'
$wechatScript = Join-Path $RepoRoot 'Backup-WeChat.ps1'
$statusScript = Join-Path $RepoRoot 'Backup-Status.ps1'
$readme = Join-Path $RepoRoot 'README.md'

$devText = Get-Content -LiteralPath $devScript -Raw
$wechatText = Get-Content -LiteralPath $wechatScript -Raw
$statusText = Get-Content -LiteralPath $statusScript -Raw
$readmeText = Get-Content -LiteralPath $readme -Raw
$allText = @($devText, $wechatText, $statusText, $readmeText) -join "`n"

foreach ($file in @($devScript, $wechatScript, $statusScript)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-Text "$([IO.Path]::GetFileName($file)) parses" ($errors.Count -eq 0)
}

foreach ($text in @($devText, $wechatText)) {
    Assert-Text 'USB writer uses shared mutex' ($text -match 'Global\\CodexHDriveUsbWriteLock')
    Assert-Text 'USB writer checks dirty state' ($text -match 'dirty|Dirty|Full Repair Needed|OperationalStatus')
    Assert-Text 'USB writer checks free space' ($text -match 'FreeBytes|FreeSpace|剩余空间')
}

Assert-Text 'WeChat USB checks H health before source size scan' (
    $wechatText -match 'Test-HDriveUsbReady\s+-TargetRoot\s+\$UsbRoot\s+-RequiredBytes\s+0[\s\S]*Get-DirectoryRequiredBytes'
)
Assert-Text 'WeChat USB uses conservative robocopy thread count' (
    $wechatText -match 'Sync-Local\s+\$UsbRoot\s+\$true\s+4' -and
    $wechatText -match 'Sync-Local\s+\$UsbRoot\s+\$false\s+4'
)
Assert-Text 'Backup-Status reports H health' ($statusText -match 'HealthStatus|OperationalStatus|dirty')
Assert-Text 'README documents H dirty skip' ($readmeText -match 'dirty|Full Repair Needed|CodexHDriveUsbWriteLock|跳过')
Assert-Text 'old H backup path has no residual references' ($allText -notmatch 'H:\\My_Digital_Backup')
