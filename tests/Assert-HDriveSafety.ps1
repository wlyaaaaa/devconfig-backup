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
$setupScript = Join-Path $RepoRoot 'Setup-ScheduledTasks.ps1'
$readme = Join-Path $RepoRoot 'README.md'

$devText = Get-Content -LiteralPath $devScript -Raw
$wechatText = Get-Content -LiteralPath $wechatScript -Raw
$statusText = Get-Content -LiteralPath $statusScript -Raw
$setupText = Get-Content -LiteralPath $setupScript -Raw
$devWrapperText = Get-Content -LiteralPath (Join-Path $RepoRoot 'Backup-DevConfig-Hidden.vbs') -Raw
$wechatWrapperText = Get-Content -LiteralPath (Join-Path $RepoRoot 'Backup-WeChat-Hidden.vbs') -Raw
$readmeText = Get-Content -LiteralPath $readme -Raw
$sourcesText = Get-Content -LiteralPath (Join-Path $RepoRoot 'sources.psd1') -Raw
$allText = @($devText, $wechatText, $statusText, $readmeText) -join "`n"

foreach ($file in @($devScript, $wechatScript, $statusScript)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-Text "$([IO.Path]::GetFileName($file)) parses" ($errors.Count -eq 0)
}

Assert-Text 'project scripts contain no direct H backup destination' (
    $devText -notmatch 'H:\\' -and $wechatText -notmatch 'H:\\' -and $statusText -notmatch 'H:\\'
)
Assert-Text 'project scripts reject the retired Usb target' (
    $devText -notmatch "'Usb'" -and $wechatText -match 'Usb.*PCConfig|PCConfig.*G.*H'
)
Assert-Text 'Backup-Status reports G hot backup' ($statusText -match 'G:\\80_Backup' -and $statusText -notmatch 'HealthStatus|OperationalStatus|dirty')
Assert-Text 'scheduled backups use G hot tier and never schedule H cold writes' (
    $devText -match 'G:\\80_Backup\\DevConfig' -and
    $wechatText -match 'G:\\80_Backup\\WeChat\\xwechat_files' -and
    $setupText -match "'Hot,Drive'" -and
    $setupText -notmatch 'DevConfigBackup-OnUSB|Usb,Drive'
)
Assert-Text 'scheduled wrappers accept current hot targets without legacy Usb or modal prompts' (
    $devWrapperText -match '"hot,drive"' -and
    $wechatWrapperText -match '"hot,drive"' -and
    $devWrapperText -notmatch '"usb"|WScript\.Echo' -and
    $wechatWrapperText -notmatch '"usb"|WScript\.Echo'
)
Assert-Text 'G hot backup is not gated on network availability' (
    $setupText.Contains("(New-Action `$devWrapper 'Hot,Drive') `$s4") -and
    -not $setupText.Contains("(New-Action `$devWrapper 'Hot,Drive') `$sNet")
)
Assert-Text 'README routes cold backup through PCConfig G to H' ($readmeText -match 'Invoke-HotToColdBackup.ps1' -and $readmeText -match 'G.*H')
Assert-Text 'default DevConfig backup excludes Codex session history and log database' (
    $sourcesText -match "'sessions'" -and
    $sourcesText -match "'logs_2\.sqlite\*'" -and
    $devText -match 'HistoryFiles'
)
Assert-Text 'old H backup path has no residual references' ($allText -notmatch 'H:\\My_Digital_Backup')
