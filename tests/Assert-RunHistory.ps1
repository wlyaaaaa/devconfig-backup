[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1');. (Join-Path $repo 'Run-History.Common.ps1')
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\');$fixture=Join-Path $parent ('backup-history-'+[guid]::NewGuid().ToString('N'));$children=@();$runtime=(Get-Process -Id $PID).Path
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};Write-Host ('PASS: '+$Message)}
function Start-FixtureChild([string]$Command){$psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$runtime;$psi.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command));$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;return [Diagnostics.Process]::Start($psi)}
$script:HistoryEvents=@();$script:HistoryEventsDenied=$false
function Get-WinEvent {param($LogName,$FilterXPath,$MaxEvents,$ErrorAction) if($script:HistoryEventsDenied){throw 'synthetic_event_log_access_denied'};return $script:HistoryEvents}
function New-HistoryEvent($Id,$Instance,[DateTimeOffset]$Time,$Result='0',$Name='\DevConfigBackup-Local'){
 $key=if($Id-eq 100){'InstanceId'}else{'TaskInstanceId'};$item=[pscustomobject]@{Payload=('<Event><System><EventID>'+ $Id+'</EventID><TimeCreated SystemTime="'+$Time.UtcDateTime.ToString('o')+'"/></System><EventData><Data Name="TaskName">'+$Name+'</Data><Data Name="'+$key+'">'+$Instance+'</Data><Data Name="ResultCode">'+$Result+'</Data></EventData></Event>')};$item|Add-Member ScriptMethod ToXml {$this.Payload};return $item
}
try{
 $state=Join-Path $fixture 'state';$history=Join-Path $state 'run-history.jsonl'
 $run=[ordered]@{schema='devconfig.run.v2';run_id=[guid]::NewGuid().ToString('N');started_utc=(Get-BackupUtc);completed_utc=$null;tiers=@('Local');status='running';failure=$null;failure_path='PRIVATE_FILENAME';skipped_files=@('PRIVATE_FILENAME');file_warnings=@(@{relative_path='PRIVATE_FILENAME';reason='source_disappeared'});pack_diagnostic='PRIVATE_CONTENT'}
 Write-BackupRunHistory $state $run started
 $summary=@(Get-BackupRunHistorySummary $state)|Where-Object task_kind -eq 'devconfig-local'
 Check ($summary.unfinished_runs.Count-eq 1 -and $summary.unfinished_runs[0].status-eq 'running' -and -not $summary.last_failure) 'An active process without final receipt is running, not interrupted'
 $failedId=$run.run_id;$run.status='failed';$run.failure='backup_pack_failed';$run.completed_utc=Get-BackupUtc;Write-BackupRunHistory $state $run final
 $run.run_id=[guid]::NewGuid().ToString('N');$run.started_utc=Get-BackupUtc;$run.status='running';$run.failure=$null;$run.completed_utc=$null;Write-BackupRunHistory $state $run started
 $run.status='complete';$run.completed_utc=Get-BackupUtc;Write-BackupRunHistory $state $run final;Write-BackupJsonAtomic (Join-Path $state 'devconfig-local-last.json') $run
 $summary=@(Get-BackupRunHistorySummary $state)|Where-Object task_kind -eq 'devconfig-local'
 Check ($summary.last_failure.run_id-eq $failedId -and $summary.last_failure.failure-eq 'backup_pack_failed' -and $summary.unfinished_runs.Count-eq 0) 'A later success preserves the preceding failure code and time'
 Check ([IO.File]::ReadAllText($history)-notmatch 'PRIVATE_FILENAME|PRIVATE_CONTENT') 'History excludes source paths, file arrays and diagnostic content'
 $status=& $runtime -NoProfile -File (Join-Path $repo 'Backup-Status.ps1') -Json -NoDrive -OutputRoot $fixture -HotRoot (Join-Path $fixture 'hot') -HotReceiptPath (Join-Path $fixture 'absent.json') -WeChatHotRoot (Join-Path $fixture 'wechat')|ConvertFrom-Json
 Check ($LASTEXITCODE-eq 0 -and $status.last_attempts[0].status-eq 'complete' -and $status.last_attempts[0].last_failure.failure-eq 'backup_pack_failed') 'The real status entrypoint reports historical failure alongside the current success'
 $prefix="`$ErrorActionPreference='Stop';. '"+$repo.Replace("'","''")+"\Backup.Common.ps1';. '"+$repo.Replace("'","''")+"\Run-History.Common.ps1';`$state='"+$state.Replace("'","''")+"';"
 $writer=$prefix+'for($i=0;$i-lt 20;$i++){$r=[ordered]@{schema="wechat.run.v2";run_id=[guid]::NewGuid().ToString("N");started_utc=(Get-BackupUtc);targets=@("Drive");status="running";failure=$null};Write-BackupRunHistory $state $r started;$r.status="complete";$r.completed_utc=Get-BackupUtc;Write-BackupRunHistory $state $r final}'
 1..3|ForEach-Object{$children+=Start-FixtureChild $writer}
 foreach($child in $children){Check ($child.WaitForExit(30000) -and $child.ExitCode-eq 0) 'Concurrent history writer exits successfully'}
 $lines=@([IO.File]::ReadAllLines($history));$records=@($lines|ForEach-Object{$_|ConvertFrom-Json})
 Check ($lines.Count-eq 124 -and @($records|Group-Object run_id|Where-Object Count -ne 2).Count-eq 0) 'Concurrent appends lose no run and retain both events for every run'
 1..80|ForEach-Object{$run.run_id=[guid]::NewGuid().ToString('N');Write-BackupRunHistory $state $run final};$records=@(Read-BackupRunHistoryLines $history|ForEach-Object{$_|ConvertFrom-Json})
 Check ($records.Count-eq 200 -and @($records|Where-Object schema -ne 'backup.run-history.v1').Count-eq 0) 'Trimming retains exactly 200 complete JSON lines'
 $killedId=[guid]::NewGuid().ToString('N');$sleeper=Start-FixtureChild ($prefix+'$r=[ordered]@{schema="devconfig.run.v2";run_id="'+$killedId+'";started_utc=(Get-BackupUtc);tiers=@("Local");status="running";failure=$null};Write-BackupRunHistory $state $r started;Start-Sleep -Seconds 30');$children+=$sleeper
 $deadline=[DateTime]::UtcNow.AddSeconds(10);do{$started=@(Read-BackupRunHistoryLines $history|ForEach-Object{$_|ConvertFrom-Json}|Where-Object run_id -eq $killedId);if(-not $started.Count){Start-Sleep -Milliseconds 50}}while(-not $started.Count -and [DateTime]::UtcNow-lt $deadline)
 Check ($started.Count-eq 1) 'Synthetic child publishes its started receipt before termination'
 $sleeper.Kill();Check ($sleeper.WaitForExit(10000)) 'Only the synthetic started-only child is terminated'
 $task=[pscustomobject]@{name='DevConfigBackup-Local';state='Ready';last_exit=125;last_run=[DateTimeOffset]$started[0].started_utc}
 $summary=@(Get-BackupRunHistorySummary $state @($task))|Where-Object task_kind -eq 'devconfig-local'
 Check ($summary.last_failure.failure-eq 'backup_process_interrupted' -and $summary.last_failure.task_scheduler_exit-eq 125 -and $summary.unfinished_runs[0].status-eq 'interrupted') 'A killed run is reported with its matching task exit code'
 $task.last_run=([DateTimeOffset]$started[0].started_utc).AddDays(-1);$summary=@(Get-BackupRunHistorySummary $state @($task))|Where-Object task_kind -eq 'devconfig-local'
 Check ($null-eq $summary.last_failure.task_scheduler_exit) 'An unrelated scheduled invocation cannot supply the interrupted run exit code'
 [IO.File]::Delete((Join-Path $state 'devconfig-local-last.json'));$status=& $runtime -NoProfile -File (Join-Path $repo 'Backup-Status.ps1') -Json -NoDrive -OutputRoot $fixture -HotRoot (Join-Path $fixture 'hot') -HotReceiptPath (Join-Path $fixture 'absent.json') -WeChatHotRoot (Join-Path $fixture 'wechat')|ConvertFrom-Json
 Check ($LASTEXITCODE-eq 0 -and $status.last_attempts[0].run_id-eq $killedId -and $status.last_attempts[0].status-eq 'interrupted') 'History alone supplies a valid current run when the last receipt is absent'
 $time=[DateTimeOffset]$started[0].started_utc;$instance='{11111111-1111-1111-1111-111111111111}';$later='{22222222-2222-2222-2222-222222222222}';$task.last_run=$time.AddDays(1)
 $script:HistoryEvents=@((New-HistoryEvent 100 $instance ($time.AddSeconds(-1))),(New-HistoryEvent 201 $instance ($time.AddMinutes(1)) '2147942525'),(New-HistoryEvent 100 $later ($time.AddMinutes(2))),(New-HistoryEvent 201 $later ($time.AddMinutes(3)) '0'))
 $summary=@(Get-BackupRunHistorySummary $state @($task))|Where-Object task_kind -eq 'devconfig-local';Check ($summary.last_failure.task_scheduler_exit-eq 125) 'A later success cannot replace the older instance-bound Operational exit code'
 $script:HistoryEvents=@($script:HistoryEvents[0],$script:HistoryEvents[2],$script:HistoryEvents[3]);Check ($null-eq (Get-BackupRunScheduledExit 'devconfig-local' $time)) 'Missing completion never borrows a later instance exit'
 $script:HistoryEvents=@((New-HistoryEvent 100 $instance ($time.AddSeconds(-1))),(New-HistoryEvent 100 $later ($time.AddSeconds(-2))),(New-HistoryEvent 201 $instance ($time.AddMinutes(1)) '125'));Check ($null-eq (Get-BackupRunScheduledExit 'devconfig-local' $time)) 'Ambiguous starts cannot claim an exit code'
 $script:HistoryEvents=@((New-HistoryEvent 100 $instance ($time.AddSeconds(-1)) '0' '\OtherTask'),(New-HistoryEvent 201 $instance ($time.AddMinutes(1)) '125' '\OtherTask'));Check ($null-eq (Get-BackupRunScheduledExit 'devconfig-local' $time)) 'A different task cannot supply an exit code'
 $script:HistoryEventsDenied=$true;Check ($null-eq (Get-BackupRunScheduledExit 'devconfig-local' $time)) 'Unreadable Operational logs leave the exit unknown'
 $driveState=Join-Path $fixture 'drive-state';$driveHistory=Join-Path $driveState 'run-history.jsonl'
 $driveRun=[ordered]@{schema='devconfig.run.v2';run_id=[guid]::NewGuid().ToString('N');started_utc=(Get-BackupUtc);completed_utc=(Get-BackupUtc);tiers=@('Drive');status='failed';drive='failed';failure='drive_latest_upload_failed';failure_stage='drive_package_copy';drive_diagnostic=[pscustomobject]@{stage='drive_package_copy';object_kind='latest';suffix='.zip';native_exit=7;reason='copy_failed';transfer_mode='ServerCopy';category='oauth_auth';raw_output='PRIVATE_CONTENT';remote='PRIVATE_FILENAME';unexpected=@{token='PRIVATE_CONTENT'}}}
 $driveFailedId=$driveRun.run_id;Write-BackupRunHistory $driveState $driveRun final
 $driveRun.run_id=[guid]::NewGuid().ToString('N');$driveRun.status='complete';$driveRun.drive='complete';$driveRun.failure=$null;$driveRun.Remove('failure_stage');$driveRun.Remove('drive_diagnostic');Write-BackupRunHistory $driveState $driveRun final
 Write-BackupJsonAtomic (Join-Path $driveState 'devconfig-drive-last.json') $driveRun
 $driveRecords=@(Read-BackupRunHistoryLines $driveHistory|ForEach-Object{$_|ConvertFrom-Json});$historicalFailure=@($driveRecords|Where-Object run_id -eq $driveFailedId)[0]
 Check ($driveRecords.Count-eq 2 -and $historicalFailure.failure-eq 'drive_latest_upload_failed' -and $historicalFailure.failure_stage-eq 'drive_package_copy' -and $historicalFailure.drive_diagnostic.native_exit-eq 7 -and $historicalFailure.drive_diagnostic.category-eq 'oauth_auth' -and $historicalFailure.drive_diagnostic.transfer_mode-eq 'ServerCopy' -and $historicalFailure.drive_diagnostic.object_kind-eq 'latest') 'Later natural success and last-receipt replacement preserve fixed ZIP provider diagnostics in history'
 Check ([IO.File]::ReadAllText($driveHistory)-notmatch 'PRIVATE_CONTENT|PRIVATE_FILENAME|raw_output|unexpected|token') 'Drive history writes only fixed diagnostic fields and excludes raw provider output, paths and secrets'
 $driveRun.drive_diagnostic=[pscustomobject]@{stage='PRIVATE_CONTENT';object_kind='latest';suffix='.zip';native_exit=7;reason='copy_failed';category='PRIVATE_CONTENT'};Write-BackupRunHistory $driveState $driveRun final
 $invalidDrive=@(Read-BackupRunHistoryLines $driveHistory|ForEach-Object{$_|ConvertFrom-Json})[-1]
 Check ($null-eq $invalidDrive.PSObject.Properties['drive_diagnostic'] -and [IO.File]::ReadAllText($driveHistory)-notmatch 'PRIVATE_CONTENT') 'Non-enumerated Drive diagnostics cannot enter history'
}finally{
 foreach($child in $children){try{if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(10000)}}finally{$child.Dispose()}}
 Remove-BackupOwnedDirectory $fixture $parent '^backup-history-[a-f0-9]{32}$'
}
