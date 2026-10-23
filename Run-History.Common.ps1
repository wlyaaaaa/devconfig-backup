# Bounded run summaries omit payload paths, filenames and contents.
function Read-BackupRunHistoryLines([string]$Path){
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite-bor [IO.FileShare]::Delete));$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
 try{while(-not $reader.EndOfStream){$reader.ReadLine()}}finally{$reader.Dispose()}
}
function Get-BackupRunTaskKind($Run){
 $family=if([string]$Run.schema-like 'wechat.*'){'wechat'}else{'devconfig'}
 $targets=if($family-eq 'wechat'){@($Run.targets)}else{@($Run.tiers)}
 return $family+'-'+$(if($targets.Count-eq 1 -and $targets[0]-eq 'Drive'){'drive'}else{'local'})
}
function Write-BackupRunHistory([string]$StateRoot,$Run,[ValidateSet('started','final')][string]$Event){
 $record=[ordered]@{schema='backup.run-history.v1';event=$Event;task_kind=(Get-BackupRunTaskKind $Run);run_id=$Run.run_id;started_utc=$Run.started_utc;process_id=$PID;process_started_utc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
 # Keep only summary fields and fixed SQLite diagnostics, without raw output or file arrays.
 foreach($key in @('status','completed_utc','tiers','targets','collection','package','hot','local','drive','retention','failure','failure_type','failure_stage','failure_io_reason','sqlite_diagnostic','skipped_file_count','capture_attempt_count','capture_max_attempts','capture_consistency','application_recovery','pack_native_exit')){if($Run.Contains($key)){$record[$key]=$Run[$key]}}
 $record.file_warning_count=@($Run.file_warnings|Where-Object{$_}).Count
 $path=Join-Path $StateRoot 'run-history.jsonl';$lease=$null;$temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  $deadline=[DateTime]::UtcNow.AddSeconds(10)
  do{try{$lease=Open-BackupResourceLock $path}catch{if($_.Exception.Message-cne 'backup_resource_busy' -or [DateTime]::UtcNow-ge $deadline){throw};Start-Sleep -Milliseconds 50}}while(-not $lease)
  $lines=@();if([IO.File]::Exists($path)){$lines=@(Read-BackupRunHistoryLines $path|Where-Object{$_}|Select-Object -Last 199)}
  $lines+=($record|ConvertTo-Json -Depth 6 -Compress)
  [IO.File]::WriteAllLines($temp,[string[]]$lines,[Text.UTF8Encoding]::new($false))
  if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)};if($lease){$lease.Dispose()}}
}
function Get-BackupRunScheduledExit([string]$Kind,[DateTimeOffset]$Started){
 $name=@{'devconfig-local'='DevConfigBackup-Local';'devconfig-drive'='DevConfigBackup-Drive-Daily';'wechat-local'='WeChatBackup-Hot-Daily';'wechat-drive'='WeChatBackup-Drive-Weekly'}[$Kind];if(-not $name){return $null}
 $before=$Started.AddMinutes(-2);$until=$Started.AddHours(6);$format='yyyy-MM-ddTHH:mm:ss.fffffffZ';$taskName='\'+$name
 $query="*[System[(EventID=100 or EventID=201) and TimeCreated[@SystemTime >= '"+$before.UtcDateTime.ToString($format)+"' and @SystemTime <= '"+$until.UtcDateTime.ToString($format)+"']] and EventData[Data[@Name='TaskName']='"+$taskName+"']]"
 try{
  $events=@(Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -FilterXPath $query -MaxEvents 128 -ErrorAction Stop);if($events.Count-ge 128){return $null};$rows=@()
  foreach($event in $events){
   [xml]$xml=$event.ToXml();$fields=@{};foreach($field in $xml.Event.EventData.Data){$fields[[string]$field.Name]=[string]$field.InnerText}
   if($fields.TaskName-ine $taskName){continue};$id=[int]$xml.Event.System.EventID;$time=[DateTimeOffset]::Parse([string]$xml.Event.System.TimeCreated.SystemTime)
   $instance=if($id-eq 100){$fields.InstanceId}else{$fields.TaskInstanceId};if($instance-notmatch '^\{[a-f0-9-]{36}\}$'){continue}
   $rows+=[pscustomobject]@{id=$id;time=$time;instance=$instance;result=$fields.ResultCode}
  }
  # A unique scheduler start before this run binds the action result by instance GUID.
  $start=@($rows|Where-Object{$_.id-eq 100 -and $_.time-ge $before -and $_.time-le $Started});if($start.Count-ne 1){return $null}
  $end=@($rows|Where-Object{$_.id-eq 201 -and $_.instance-ieq $start[0].instance -and $_.time-ge $Started -and $_.time-le $until});if($end.Count-ne 1){return $null}
  $code=[uint32]0;if(-not [uint32]::TryParse([string]$end[0].result,[ref]$code)){return $null}
  # Operational wraps Win32 process exits in HRESULT_FROM_WIN32; TaskInfo uses the exit.
  if(($code-band 4294901760)-eq 2147942400){return [int]($code-band 65535)};return [long]$code
 }catch{return $null}
}
function Get-BackupRunHistorySummary([string]$StateRoot,$ScheduledTasks=@()){
 $path=Join-Path $StateRoot 'run-history.jsonl';if(-not [IO.File]::Exists($path)){return @()}
 $starts=@{};$finals=@{};$failures=@{};$unfinished=@{}
 foreach($line in (Read-BackupRunHistoryLines $path)){
  if(-not $line){continue};$record=$line|ConvertFrom-Json -ErrorAction Stop
  if($record.schema-cne 'backup.run-history.v1' -or $record.run_id-cnotmatch '^[a-f0-9]{32}$' -or $record.task_kind-notin @('devconfig-local','devconfig-drive','wechat-local','wechat-drive') -or $record.event-notin @('started','final')){throw 'backup_run_history_invalid'}
  if($record.event-eq 'started'){$starts[$record.run_id]=$record}else{$finals[$record.run_id]=$record}
 }
 foreach($record in $finals.Values){if($record.status-eq 'failed'){$kind=$record.task_kind;if(-not $failures[$kind] -or [DateTimeOffset]$record.completed_utc-gt [DateTimeOffset]$failures[$kind].occurred_utc){$failures[$kind]=[pscustomobject]@{run_id=$record.run_id;occurred_utc=$record.completed_utc;time_basis='completed_utc';failure=$record.failure;task_scheduler_exit=$null}}}}
 foreach($record in $starts.Values){
  if($finals.ContainsKey($record.run_id)){continue};$kind=$record.task_kind;$alive=$null;$process=$null
  try{$process=[Diagnostics.Process]::GetProcessById([int]$record.process_id);$alive=([math]::Abs(($process.StartTime.ToUniversalTime()-([DateTimeOffset]$record.process_started_utc).UtcDateTime).TotalSeconds)-lt 1)}catch [ArgumentException]{$alive=$false}catch{}finally{if($process){$process.Dispose()}}
  $taskPrefix=@{'devconfig-local'='DevConfigBackup-Local';'devconfig-drive'='DevConfigBackup-Drive';'wechat-local'='WeChatBackup-Hot';'wechat-drive'='WeChatBackup-Drive'}[$kind]
  $task=@($ScheduledTasks|Where-Object{($_.name-eq $taskPrefix -or $_.name-like ($taskPrefix+'-*')) -and $_.last_run -and [math]::Abs((([DateTimeOffset]$_.last_run)-([DateTimeOffset]$record.started_utc)).TotalMinutes)-le 2}|Sort-Object last_run -Descending|Select-Object -First 1)
  $running=($alive-eq $true -or ($task.Count -and $task[0].state-eq 'Running'))
  $status=if($running){'running'}elseif($alive-eq $false){'interrupted'}else{'unknown'}
  $exitCode=if($status-eq 'interrupted' -and $task.Count){$task[0].last_exit}else{$null}
  if($status-eq 'interrupted' -and $null-eq $exitCode){$exitCode=Get-BackupRunScheduledExit $kind ([DateTimeOffset]$record.started_utc)}
  $entry=[pscustomobject]@{run_id=$record.run_id;started_utc=$record.started_utc;status=$status;failure=$(if($status-eq 'interrupted'){'backup_process_interrupted'}else{$null});task_scheduler_exit=$exitCode}
  if(-not $unfinished[$kind]){$unfinished[$kind]=@()};$unfinished[$kind]+=$entry
  if($status-eq 'interrupted' -and (-not $failures[$kind] -or [DateTimeOffset]$record.started_utc-gt [DateTimeOffset]$failures[$kind].occurred_utc)){$failures[$kind]=[pscustomobject]@{run_id=$record.run_id;occurred_utc=$record.started_utc;time_basis='started_utc_no_final';failure=$entry.failure;task_scheduler_exit=$exitCode}}
 }
 foreach($kind in @('devconfig-local','devconfig-drive','wechat-local','wechat-drive')){[pscustomobject]@{task_kind=$kind;last_failure=$failures[$kind];unfinished_runs=@($unfinished[$kind]|Where-Object{$_}|Sort-Object started_utc -Descending)}}
}
