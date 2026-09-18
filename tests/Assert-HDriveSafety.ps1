[CmdletBinding()]
param([string]$RepoRoot='')
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent $PSScriptRoot}
$ErrorActionPreference='Stop'
function Check([bool]$Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};Write-Host ('PASS: '+$Name)}
$runtime=(Get-Process -Id $PID).Path
foreach($entry in @(@('Backup-DevConfig.ps1','-Tier'),@('Backup-WeChat.ps1','-Target'))){
 $text=Get-Content (Join-Path $RepoRoot $entry[0]) -Raw
 Check ($text-notmatch 'H:\\') 'Business source has no direct H destination'
 $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$output=(& $runtime -NoProfile -File (Join-Path $RepoRoot $entry[0]) $entry[1] Usb 2>&1|Out-String);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 Check ($code-ne 0 -and $output-match 'invalid_backup_(tier|target)') 'Retired Usb target is rejected before any IO'
}
$setup=Get-Content (Join-Path $RepoRoot 'Setup-ScheduledTasks.ps1') -Raw
foreach($task in @('DevConfigBackup-Local','DevConfigBackup-Drive-Daily','WeChatBackup-Hot-Daily','WeChatBackup-Drive-Weekly')){Check ($setup.Contains($task)) ('Independent task remains: '+$task)}
Check ($setup-match 'RestartCount 3' -and $setup-match 'RestartCount 5' -and $setup-match 'RunOnlyIfNetworkAvailable') 'Task retry and network-specific availability remain'
foreach($name in @('Backup-DevConfig-Hidden.vbs','Backup-WeChat-Hidden.vbs')){$t=Get-Content (Join-Path $RepoRoot $name) -Raw;Check ($t-match 'WScript.Quit exitCode' -and $t-match 'shell.Run\(command, 0, True\)') 'Hidden launcher preserves actual exit code'}
$cfg=Import-PowerShellDataFile (Join-Path $RepoRoot 'sources.psd1')
Check ('sessions'-in $cfg.HistoryDirs -and 'logs_2.sqlite*'-in $cfg.HistoryFiles) 'Default history exclusions are retained'
Check ('.env'-in $cfg.ExcludeFiles -and 'auth.json'-in $cfg.ExcludeFiles) 'Named credential exclusions remain; this is not a whole-package secret scan'
$pc='E:\PCConfig\registries\core_recovery.json'
if(Test-Path $pc){$manifest=Get-Content $pc -Raw -Encoding UTF8|ConvertFrom-Json;Check ($manifest.maintenance.cold_copy_mode-eq 'source_follow_verified_prune') 'PCConfig cold policy follows the verified source view'}
Check ((Get-Content (Join-Path $RepoRoot 'README.md') -Raw)-match 'Invoke-CoreRecoveryMaintenance') 'Machine cold recovery is routed to PCConfig'
