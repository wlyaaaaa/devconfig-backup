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
    $setupText -match 'New-Action \$devWrapper ''Local,Hot''' -and
    $setupText -match 'New-Action \$devWrapper ''Drive''' -and
    $setupText -match 'New-Action \$wxWrapper ''Hot''' -and
    $setupText -match 'New-Action \$wxWrapper ''Drive''' -and
    $setupText -notmatch 'DevConfigBackup-OnUSB|Usb,Drive'
)
Assert-Text 'scheduled wrappers accept current hot targets without legacy Usb or modal prompts' (
    $devWrapperText -match '"local,hot"' -and
    $devWrapperText -match '"drive"' -and
    $wechatWrapperText -match '"hot"' -and
    $wechatWrapperText -match '"drive"' -and
    $devWrapperText -notmatch '"usb"|WScript\.Echo' -and
    $wechatWrapperText -notmatch '"usb"|WScript\.Echo'
)
Assert-Text 'local hot and Drive tasks are split with independent availability gates' (
    $setupText -match "DevConfigBackup-Local" -and
    $setupText -match "DevConfigBackup-Drive-Daily" -and
    $setupText -match "WeChatBackup-Hot-Daily" -and
    $setupText -match "WeChatBackup-Drive-Weekly" -and
    $setupText -match '\$sLocalHot = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries' -and
    $setupText -match '\$sDrive = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable' -and
    $setupText -match '\$sWeChatHot = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries' -and
    $setupText -match '\$sWeChatDrive = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable'
)
Assert-Text 'scheduled backup failures are retried and hidden launchers preserve exit codes' (
    $setupText -match '-RestartCount 3' -and
    $setupText -match '-RestartCount 5' -and
    $devWrapperText -match 'shell\.Run\(command, 0, True\)' -and
    $devWrapperText -match 'WScript\.Quit exitCode' -and
    $wechatWrapperText -match 'shell\.Run\(command, 0, True\)' -and
    $wechatWrapperText -match 'WScript\.Quit exitCode'
)
Assert-Text 'Drive skip and upload failures propagate to Task Scheduler' (
    $devText -match 'Set-BackupFailure "Drive 预检失败' -and
    $devText -match '\$preflight\.Category' -and
    $devText -match 'exit \$overallExitCode' -and
    $wechatText -match '\$overallExitCode = 1' -and
    $wechatText -match 'exit \$overallExitCode'
)
Assert-Text 'README routes cold backup through the current PCConfig maintenance contract' (
    $readmeText -match 'Invoke-CoreRecoveryMaintenance\.ps1' -and
    $readmeText -match '-Mode Cold' -and $readmeText -match 'G.*H'
)
$coreRecoveryMaintenance = Get-Content -LiteralPath 'E:\PCConfig\tools\Invoke-CoreRecoveryMaintenance.ps1' -Raw
Assert-Text 'PCConfig cold recovery uses the current explicit maintenance contract' (
    $coreRecoveryMaintenance -match "\[ValidateSet\('Inspect', 'Hot', 'Cold'\)\]" -and
    $coreRecoveryMaintenance -match '\$Mode -ne ''Inspect'' -and -not \$Execute' -and
    $coreRecoveryMaintenance -match "'additive_no_mirror'" -and
    $coreRecoveryMaintenance -match "'consume_validated_hot_context'"
)
Assert-Text 'default DevConfig backup excludes Codex session history and log database' (
    $sourcesText -match "'sessions'" -and
    $sourcesText -match "'logs_2\.sqlite\*'" -and
    $devText -match 'HistoryFiles'
)
Assert-Text 'default DevConfig backup excludes plaintext secret staging' (
    $sourcesText -match "'\.env', '\.env\.\*'" -and
    $sourcesText -match "'auth\.json', 'client_secret\.json'" -and
    $sourcesText -match "'memory-backup', 'secrets-backup'" -and
    $sourcesText -match 'SpecialFiles\s*=\s*@\(\)'
)
Assert-Text 'old H backup path has no residual references' ($allText -notmatch 'H:\\My_Digital_Backup')
