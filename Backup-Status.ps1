<#
.SYNOPSIS
  Bounded backup status. Default is local-only, read-only, with no private log output.
.DESCRIPTION
  -Gui opens a visible panel; closing it stops display refresh, not backups.
  -LiveDrive explicitly queries cloud metadata and may refresh the existing OAuth token.
#>
[CmdletBinding()]
param([int]$LogLines=0,[switch]$NoDrive,[string]$GDriveRemote='gdrive:',[switch]$LiveDrive,[switch]$Json,[switch]$Gui,[switch]$VerifyContent,[string]$OutputRoot='',[string]$HotRoot='G:\80_Backup\DevConfig',[string]$HotReceiptPath='G:\80_Backup\ControlPlane\wechat-hot-last.json',[string]$WeChatHotRoot='G:\80_Backup\WeChat\xwechat_files')
if(-not $OutputRoot){$OutputRoot=$PSScriptRoot}
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Backup.Common.ps1')
. (Join-Path $PSScriptRoot 'Initialize-BackupNetwork.ps1')
$remoteWasExplicit=$PSBoundParameters.ContainsKey('GDriveRemote')
function Get-ReceiptAgeState([string]$Timestamp){
 $age=([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($Timestamp)).TotalHours
 if($age-lt -0.1){return 'invalid_timestamp'};if($age-gt 36){return 'stale'};return 'current'
}
function Get-PackageStatus([string]$Directory){
 $result=[ordered]@{status='unknown';path=$Directory;package=$null;bytes=$null;completed_utc=$null;verification='unknown';reason=$null}
 try{
  $pack=Get-VerifiedDevConfigPackage $Directory -MetadataOnly:(-not $VerifyContent)
  $result.status=Get-ReceiptAgeState $pack.Current.completed_utc;$result.package=$pack.Name;$result.bytes=$pack.Receipt.package_bytes;$result.completed_utc=$pack.Current.completed_utc
  if($VerifyContent -and (Get-BackupStableFileHash (Join-Path $Directory 'latest.zip'))-cne $pack.Sha){throw 'latest_alias_mismatch'}
  $result.verification=if($VerifyContent){'sha256_rechecked'}else{'producer_verified_not_rehashed_by_status'}
 }catch{$result.reason=Get-BackupFailureCode $_;if([IO.File]::Exists((Join-Path $Directory 'latest.zip'))){$result.status='legacy_or_unverified'}}
 return [pscustomobject]$result
}
function Get-BackupStatusSnapshot {
 $state=Join-Path $OutputRoot 'state';$attempts=@()
 foreach($name in @('devconfig-local-last.json','devconfig-drive-last.json','wechat-local-last.json','wechat-drive-last.json')){
  try{$record=Read-BackupJson (Join-Path $state $name);if($record){$attempts+=$record}}catch{$attempts+=[pscustomobject]@{schema=$name;status='unreadable';failure='run_record_unreadable'}}
 }
 $tasks=@();try{foreach($task in @(Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*','WeChatDrive-Monitor-Hourly' -ErrorAction Stop)){
  $info=$task|Get-ScheduledTaskInfo -ErrorAction Stop
  $tasks+=[pscustomobject]@{name=$task.TaskName;state=[string]$task.State;enabled=[bool]$task.Settings.Enabled;last_exit=$info.LastTaskResult;last_run=$info.LastRunTime;next_run=$info.NextRunTime}
 }}catch{$tasks=@([pscustomobject]@{name='Task Scheduler';state='unavailable';last_exit=$null;next_run=$null})}
 $wechat=[ordered]@{status='unknown';verification='unknown';bytes=$null;completed_utc=$null;application_consistency='not_proven';application_recovery='not_tested';reason=$null}
 try{
  $receipt=Read-BackupJson $HotReceiptPath -Required
  if($receipt.schema-cne 'wechat.hot-backup-receipt.v2' -or $receipt.status-cne 'complete' -or $receipt.collection_status-cne 'complete' -or $receipt.verification_status-cne 'sha256_full_tree' -or $receipt.retention_status-cne 'source_follow_verified'){throw 'wechat_receipt_not_verified'}
  if($receipt.destination-ine (Resolve-BackupPath $WeChatHotRoot)){throw 'wechat_receipt_destination_mismatch'}
  $manifestPath=$WeChatHotRoot+'.backup-manifest.json'
  $bound=Get-VerifiedBackupTreeManifest $WeChatHotRoot -VerifyContent:$VerifyContent
  if($bound.run_id-cne $receipt.generation_id -or $bound.content_sha256-cne $receipt.content_sha256 -or (Get-Item $manifestPath).Length-ne $receipt.manifest_bytes -or (Get-BackupStableFileHash $manifestPath)-cne $receipt.manifest_sha256){throw 'wechat_receipt_manifest_mismatch'}
  $wechat.status=Get-ReceiptAgeState $receipt.completed_utc;$wechat.verification=if($VerifyContent){'sha256_full_tree_rechecked'}else{'producer_verified_manifest_bound'};$wechat.completed_utc=$receipt.completed_utc;$wechat.bytes=$receipt.bytes;$wechat.file_count=$receipt.file_count
 }catch{$wechat.reason=Get-BackupFailureCode $_}
 $drive=[ordered]@{status='not_contacted';application_recovery='not_tested'}
 if($LiveDrive -and -not $NoDrive){try{
  $rclone=Get-BackupExecutable rclone -FallbackPath 'E:\Scoop\shims\rclone.exe';$env:PATH=[IO.Path]::GetDirectoryName($rclone)+';'+$env:PATH;$null=Initialize-BackupNetwork
  $resolved=Resolve-ConfiguredRcloneRemote -Remote $GDriveRemote -RemoteWasExplicit $remoteWasExplicit -BindingPath (Join-Path $state 'rclone-remote-binding.json')
  if(-not $resolved.Success){throw 'drive_remote_unavailable'}
  $probe=Invoke-RcloneDrivePreflight -Remote $resolved.Remote -Attempts 1 -DelaySeconds 0
  $drive.status=if($probe.Success){'reachable_not_content_verified'}else{'unreachable'}
 }catch{$drive.status='unavailable';$drive.reason=Get-BackupFailureCode $_}}
 $local=Get-PackageStatus (Join-Path $OutputRoot 'out');$hot=Get-PackageStatus $HotRoot
 $health=if(@($attempts|Where-Object{$_.status-in @('failed','unreadable')}).Count -or $local.status-ne 'current' -or $hot.status-ne 'current' -or $wechat.status-ne 'current'){'attention_required'}elseif(@($attempts|Where-Object{$_.status-eq 'complete_with_skipped_files'}).Count){'receipts_current_with_skipped_files'}else{'receipts_current'}
 return [pscustomobject][ordered]@{schema='devconfig.backup-status.v2';observed_utc=(Get-BackupUtc);write_mode=$(if($LiveDrive -and -not $NoDrive){'metadata_query_may_refresh_oauth'}else{'zero_write'});status=$health;local=$local;hot=$hot;wechat_hot=[pscustomobject]$wechat;drive=[pscustomobject]$drive;last_attempts=$attempts;scheduled_tasks=$tasks;application_recovery='not_tested';log_payloads='not_read'}
}
function Format-BackupStatusForHuman($Snapshot){
 $labels=@{current='当前有效';stale='已过期';unknown='尚未验证';legacy_or_unverified='旧版或未验证';complete='完成';failed='失败';running='进行中';not_requested='本次未请求';not_contacted='未联网检查';attention_required='需要处理';receipts_current='成功回执均在有效期内';complete_with_skipped_files='完成，但跳过了被占用的文件';receipts_current_with_skipped_files='成功回执均在有效期内，但最近一次跳过了被占用的文件';Ready='就绪';Disabled='已禁用'}
 function Label([string]$Value){if($labels.ContainsKey($Value)){return $labels[$Value]};return $Value}
 $lines=[Collections.Generic.List[string]]::new();$lines.Add('DevConfig / 微信备份状态');$lines.Add('检查时间：'+$Snapshot.observed_utc);$lines.Add('总体：'+(Label $Snapshot.status));$lines.Add('')
 foreach($entry in @(@('本地配置',$Snapshot.local),@('G 盘配置',$Snapshot.hot),@('G 盘微信',$Snapshot.wechat_hot))){
  $item=$entry[1];$lines.Add($entry[0]+'：'+(Label $item.status));if($item.completed_utc){$lines.Add('  最近成功：'+$item.completed_utc)}
  if($null-ne $item.bytes){$lines.Add(('  大小：{0:N2} GiB' -f ([double]$item.bytes/1GB)))};$lines.Add('  校验依据：'+$item.verification);if($item.reason){$lines.Add('  原因：'+$item.reason)}
 }
 $lines.Add('');$lines.Add('最近尝试（失败不会覆盖上一个成功版本）：');foreach($attempt in $Snapshot.last_attempts){$lines.Add(('  {0}：{1}  {2}' -f $attempt.schema,(Label $attempt.status),$attempt.failure));if($attempt.failure_path){$lines.Add('    出错文件：'+$attempt.failure_path)};foreach($skip in @($attempt.skipped_files|Where-Object{$_})){$lines.Add(('    已跳过：{0}（{1}）' -f $skip.relative_path,$skip.reason))}}
 $lines.Add('');$lines.Add('计划任务：');foreach($task in $Snapshot.scheduled_tasks){$lines.Add(('  {0}：{1}；上次返回 {2}；下次 {3}' -f $task.name,(Label $task.state),$task.last_exit,$task.next_run))}
 $lines.Add('');$lines.Add('云端：'+(Label $Snapshot.drive.status));$lines.Add('文件校验、复制成功与官方客户端恢复是不同结果；此页不证明应用已经恢复。')
 $lines.Add('界面每分钟刷新。关闭窗口不停止备份；启停任务请使用“管理计划任务”。')
 return $lines-join [Environment]::NewLine
}
if($Gui){
 if($Json){throw 'gui_json_modes_are_exclusive'};Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
 $form=New-Object Windows.Forms.Form;$form.Text='DevConfig / 微信备份状态';$form.Width=1080;$form.Height=760
 $bar=New-Object Windows.Forms.FlowLayoutPanel;$bar.Dock='Top';$bar.Height=42
 $refresh=New-Object Windows.Forms.Button;$refresh.Text='立即刷新';$refresh.Width=120
 $control=New-Object Windows.Forms.Button;$control.Text='管理计划任务';$control.Width=160
 $notice=New-Object Windows.Forms.Label;$notice.Text='关闭窗口只停止界面刷新，不停止备份任务。';$notice.AutoSize=$true;$notice.Padding='8,8,0,0'
 $bar.Controls.AddRange(@($refresh,$control,$notice))
 $box=New-Object Windows.Forms.TextBox;$box.Multiline=$true;$box.ReadOnly=$true;$box.ScrollBars='Both';$box.Dock='Fill';$box.WordWrap=$false;$box.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
 $form.Controls.Add($box);$form.Controls.Add($bar)
 $update={try{$box.Text=Format-BackupStatusForHuman (Get-BackupStatusSnapshot)}catch{$box.Text='状态读取失败，不推断备份成功。'}}
 $refresh.Add_Click($update);$form.Add_Shown($update);$control.Add_Click({Start-Process taskschd.msc})
 $timer=New-Object Windows.Forms.Timer;$timer.Interval=60000;$timer.Add_Tick($update);$timer.Start()
 try{[void]$form.ShowDialog()}finally{$timer.Stop();$timer.Dispose();$form.Dispose()};exit 0
}
$snapshot=Get-BackupStatusSnapshot
if($Json){$snapshot|ConvertTo-Json -Depth 12}else{Format-BackupStatusForHuman $snapshot}
