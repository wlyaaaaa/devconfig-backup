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
# Evaluate only the four settings commands, never the registration entrypoint.
$tokens=$null;$parseErrors=$null
$setupAst=[Management.Automation.Language.Parser]::ParseInput($setup,[ref]$tokens,[ref]$parseErrors)
Check (@($parseErrors).Count-eq 0) 'Scheduled task setup parses before settings contract checks'
foreach($contract in @(
 @('sLocalHot',$false,'PT10M','PT2H'),@('sDrive',$true,'PT15M','PT3H'),
 @('sWeChatHot',$false,'PT15M','PT3H'),@('sWeChatDrive',$true,'PT30M','PT4H')
)){
 $name=[string]$contract[0]
 $assignments=@($setupAst.FindAll({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left-is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath-ceq $name},$false))
 Check ($assignments.Count-eq 1) ('One settings definition: '+$name)
 $commands=@($assignments[0].Right.FindAll({param($node)$node-is [Management.Automation.Language.CommandAst]},$false))
 $settingsCommands=@($commands|Where-Object{$_.GetCommandName()-ceq 'New-ScheduledTaskSettingsSet'})
 Check ($settingsCommands.Count-eq 1 -and @($commands|Where-Object{$_.GetCommandName()-notin @('New-ScheduledTaskSettingsSet','New-TimeSpan')}).Count-eq 0) ('Settings are created without task registration: '+$name)
 $settings=& ([scriptblock]::Create($settingsCommands[0].Extent.Text))
 Check ($settings.RunOnlyIfNetworkAvailable-eq [bool]$contract[1]) ('Network availability matches local or Drive purpose: '+$name)
 Check ($settings.RestartCount-eq 3 -and $settings.RestartInterval-ceq $contract[2]) ('Three retries use the configured interval: '+$name)
 Check ($settings.MultipleInstances-eq 2 -and $settings.StartWhenAvailable -and $settings.ExecutionTimeLimit-ceq $contract[3]) ('IgnoreNew concurrency, missed-run recovery and execution limit remain: '+$name)
 Check (-not $settings.DisallowStartIfOnBatteries -and -not $settings.StopIfGoingOnBatteries) ('Battery power does not block or stop backup: '+$name)
}
foreach($name in @('Backup-DevConfig-Hidden.vbs','Backup-WeChat-Hidden.vbs')){$t=Get-Content (Join-Path $RepoRoot $name) -Raw;Check ($t-match 'WScript.Quit exitCode' -and $t-match 'shell.Run\(command, 0, True\)') 'Hidden launcher preserves actual exit code'}
$cfg=Import-PowerShellDataFile (Join-Path $RepoRoot 'sources.psd1')
Check ('sessions'-in $cfg.HistoryDirs -and 'logs_2.sqlite*'-in $cfg.HistoryFiles -and 'thread_history_*.sqlite*'-in $cfg.HistoryFiles) 'Default history exclusions are retained'
Check ('.env'-in $cfg.ExcludeFiles -and 'auth.json'-in $cfg.ExcludeFiles) 'Named credential exclusions remain; this is not a whole-package secret scan'
Check ('home/.codex/.sandbox-bin'-in $cfg.ExcludeRelativePaths) 'ACL-locked ephemeral Codex sandbox binaries are excluded by exact relative path'
Check ('home/.codex/aicli-background-children'-in $cfg.ExcludeRelativePaths) 'Runtime AICLI child leases are excluded by exact relative path'
Check ('appdata-roaming/io.github.clash-verge-rev.clash-verge-rev/singleton-instance.lock'-in $cfg.ExcludeRelativePaths -and '*.lock'-notin $cfg.ExcludeFiles) 'Clash Verge single-instance guard is excluded by exact relative path, not by a global *.lock rule'
$pc='E:\PCConfig\registries\core_recovery.json'
if(Test-Path $pc){$manifest=Get-Content $pc -Raw -Encoding UTF8|ConvertFrom-Json;Check ($manifest.maintenance.cold_copy_mode-eq 'source_follow_verified_prune') 'PCConfig cold policy follows the verified source view'}
Check ((Get-Content (Join-Path $RepoRoot 'README.md') -Raw)-match 'Invoke-CoreRecoveryMaintenance') 'Machine cold recovery is routed to PCConfig'
