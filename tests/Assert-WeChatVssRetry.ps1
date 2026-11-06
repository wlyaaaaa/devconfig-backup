[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1');. (Join-Path $repo 'Run-History.Common.ps1')
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\');$fixture=Join-Path $parent ('wechat-vss-retry-'+[guid]::NewGuid().ToString('N'))
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};Write-Host ('PASS: '+$Message)}
function New-FakeClass([object[]]$Codes,[bool]$EmptyId=$false){
 $fake=[pscustomobject]@{Codes=$Codes;Calls=0;Disposed=$false;EmptyId=$EmptyId;Parameters=$null}
 $fake|Add-Member ScriptMethod GetMethodParameters {param($method) Check ($method-ceq 'Create') 'Only Create parameters requested';$this.Parameters=@{};return $this.Parameters}
 $fake|Add-Member ScriptMethod InvokeMethod {
  param($method,$parameters,$options)
  Check ($method-ceq 'Create' -and [object]::ReferenceEquals($parameters,$this.Parameters) -and $parameters.Volume-ceq $script:volumeRoot -and $parameters.Context-ceq 'ClientAccessible' -and $null-eq $options) 'Create reuses its parameters, volume and context'
  $code=$this.Codes[$this.Calls];$this.Calls++;return @{ReturnValue=[uint32]$code;ShadowID=$(if($this.EmptyId){''}else{'{00000000-0000-0000-0000-000000000001}'})}
 }
 $fake|Add-Member ScriptMethod Dispose {$this.Disposed=$true};return $fake
}
function Start-Sleep {param([int]$Seconds,[int]$Milliseconds) if($PSBoundParameters.ContainsKey('Seconds')){$script:waits.Add($Seconds)}}
try{
 $script:volumeRoot='Q:\'
 $cases=@(
  @{codes=@(0);attempts=1;waits='';failed=''}
  foreach($value in @(7,9,10,12)){@{codes=@($value,0);attempts=2;waits='120';failed="$value"}}
  foreach($value in @(0,1,2,3,4,5,6,8,11,13,99)){@{codes=@($value);attempts=1;waits='';empty=($value-eq 0);failed="$value";error="backup_vss_create_failed:$($value)_attempts_1"}}
  @{codes=@(10,10,10);attempts=3;waits='120|300';failed='10|10|10';error='backup_vss_create_failed:10_attempts_3'}
  @{codes=@(7,9,12);attempts=3;waits='120|300';failed='7|9|12';error='backup_vss_create_failed:12_attempts_3'}
 )
 foreach($case in $cases){
  $fake=New-FakeClass $case.codes ([bool]$case.empty);$script:waits=[Collections.Generic.List[int]]::new();$result=$null;$failure=$null
  try{$result=Invoke-BackupVssCreate $fake $script:volumeRoot}catch{$failure=$_}
  Check ($fake.Calls-eq $case.attempts -and ($script:waits-join '|')-ceq $case.waits) 'Return codes control bounded attempts and exact waits'
  if($case.error){Check ($null-ne $failure -and (Get-BackupFailureCode $failure)-ceq $case.error) 'Failure filtering preserves the final code and attempt count';$stats=$failure.Exception.Data['backup_vss_source_snapshot']}
  else{Check ($null-eq $failure -and $result.ShadowId-ceq '{00000000-0000-0000-0000-000000000001}') 'Successful Create returns its ID';$stats=$result.SourceSnapshot}
  Check ($stats.create_attempts-eq $case.attempts -and $stats.create_failed_codes-is [array] -and ($stats.create_failed_codes-join '|')-ceq $case.failed) 'Attempt statistics retain an exact numeric array, including empty arrays'
 }
 # Substitute only the ManagementClass constructor; execute the production lifecycle and Hot body.
 $common=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Backup.Common.ps1'),[ref]$null,[ref]$null)
 $node=$common.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'New-BackupVssSnapshot'},$true)
 $constructor='[System.Management.ManagementClass]::new(''root\cimv2'',''Win32_ShadowCopy'',$null)'
 Check ($node.Extent.Text.Contains($constructor)) 'The fixture replaces the real class constructor explicitly'
 . ([scriptblock]::Create($node.Extent.Text.Replace($constructor,'$script:fakeClass')))
 function Test-BackupAdministrator {return $true}
 function Get-BackupVssVolumeIdentity {param($VolumeRoot) return 'fixture-volume'}
 function Get-BackupVssSourcePath {param($Shadow,$Source) return $Source}
 function Get-CimInstance {param($ClassName,$Namespace,$Filter,$ErrorAction) $script:reads++;if($script:readFailure){throw 'fixture_vss_readback_failed'};return [pscustomobject]@{ID='{00000000-0000-0000-0000-000000000001}';VolumeName='fixture-volume';State=12;ClientAccessible=$true;NoAutoRelease=$true}}
 function Remove-BackupVssSnapshotExact {param($ShadowId) Check ($ShadowId-ceq '{00000000-0000-0000-0000-000000000001}') 'Cleanup targets only the owned fixture ID';$script:cleanups++}
 $backup=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Backup-WeChat.ps1'),[ref]$null,[ref]$null)
 foreach($name in @('Get-WeChatSummary','Invoke-WeChatDriveRclone','Invoke-WeChatDrivePublication')){
  $node=$backup.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $name},$true);. ([scriptblock]::Create($node.Extent.Text))
 }
 $start=@($backup.EndBlock.Statements|Where-Object{$_.Extent.Text-like '$capturesSource=*'})[0]
 $mainTry=@($backup.EndBlock.Statements|Where-Object{$_-is [Management.Automation.Language.TryStatementAst]})[-1]
 $body=@($backup.EndBlock.Statements|Where-Object{$_.Extent.StartOffset-ge $start.Extent.StartOffset -and $_.Extent.StartOffset-le $mainTry.Extent.StartOffset}|ForEach-Object{$_.Extent.Text})-join "`n"
 $main=[scriptblock]::Create($body)
 $Source=Join-Path $fixture 'source';[void][IO.Directory]::CreateDirectory($Source);[IO.File]::WriteAllText((Join-Path $Source 'fixture.bin'),'synthetic source')
 $script:volumeRoot=[IO.Path]::GetPathRoot($Source);$UseVss=$true;$Target=@('Hot');$exclDirs=@();$script:SourceCaptureMode='vss_crash_consistent'
 $StateRoot=Join-Path $fixture 'success-state';$HotRoot=Join-Path $fixture 'success-hot';$LocalRoot=Join-Path $fixture 'local';$script:HotReceiptFile=Join-Path $fixture 'wechat-hot-last.json'
 $script:fakeClass=New-FakeClass @(10,0);$script:waits=[Collections.Generic.List[int]]::new();$script:cleanups=0;$script:reads=0;$script:readFailure=$false
 . $main
 $hotReceipt=Read-BackupJson $script:HotReceiptFile -Required;$localRun=Read-BackupJson (Join-Path $StateRoot 'wechat-local-last.json') -Required
 $history=@(Read-BackupRunHistoryLines (Join-Path $StateRoot 'run-history.jsonl')|ForEach-Object{$_|ConvertFrom-Json});$final=$history[-1]
 foreach($value in @($hotReceipt,$localRun,$final)){
  Check ($value.status-ceq 'complete' -and $value.source_snapshot.create_attempts-eq 2 -and ($value.source_snapshot.create_failed_codes-join '|')-ceq '10') 'Fake 10 then success reaches the Hot receipt, local run and final history'
 }
 Check ($final.event-ceq 'final' -and $script:fakeClass.Calls-eq 2 -and $script:fakeClass.Disposed -and $script:cleanups-eq 1 -and $script:reads-eq 1 -and ($script:waits-join '|')-ceq '120') 'Successful lifecycle disposes, verifies and cleans up without extra Create calls'
 function Get-WeChatCloudFilter {return @()}
 function Invoke-RcloneDrivePreflight {return [pscustomobject]@{Success=$true}}
 function Invoke-BackupRclone {$global:LASTEXITCODE=0}
 function Test-RcloneRemoteFileMatchesLocal {return [pscustomobject]@{Matches=$true}}
 $GDriveFolder='Backups/Fixture';$BwLimit='4M';$MaxTransfer='8G';$DbOnly=$false;$DriveFull=$false
 $manifest=Get-VerifiedBackupTreeManifest $HotRoot;$upload=[pscustomobject]@{hot_manifest_sha256=$hotReceipt.manifest_sha256;hot_capture_consistency='vss_crash_consistent'}
 $null=Invoke-WeChatDrivePublication $manifest $upload 'fixture:Backups/Fixture'
 $drive=Read-BackupJson (Join-Path $StateRoot 'wechat-drive-success.json') -Required
 Check ($null-eq $drive.PSObject.Properties['source_snapshot']) 'Drive publication excludes source_snapshot even after a retried Hot capture'
 $StateRoot=Join-Path $fixture 'failed-state';$HotRoot=Join-Path $fixture 'failed-hot';$script:HotReceiptFile=Join-Path $fixture 'failed-hot-receipt.json'
 $script:fakeClass=New-FakeClass @(10,10,10);$script:waits=[Collections.Generic.List[int]]::new();$script:cleanups=0;$script:reads=0
 . $main
 $failed=Read-BackupJson (Join-Path $StateRoot 'wechat-local-last.json') -Required
 $final=@(Read-BackupRunHistoryLines (Join-Path $StateRoot 'run-history.jsonl')|ForEach-Object{$_|ConvertFrom-Json})[-1]
 foreach($value in @($failed,$final)){Check ($value.status-ceq 'failed' -and $value.failure-ceq 'backup_vss_create_failed:10_attempts_3' -and $value.source_snapshot.create_attempts-eq 3 -and ($value.source_snapshot.create_failed_codes-join '|')-ceq '10|10|10') 'Exhausted Create retains exact failure and statistics in local run and history'}
 Check ($code-eq 1 -and $script:fakeClass.Calls-eq 3 -and $script:fakeClass.Disposed -and $script:cleanups-eq 0 -and $script:reads-eq 0 -and ($script:waits-join '|')-ceq '120|300') 'Exhaustion stops before journaling, readback or cleanup'
 Check (-not [IO.Directory]::Exists($HotRoot) -and -not [IO.File]::Exists($script:HotReceiptFile) -and -not [IO.File]::Exists((Get-BackupVssJournalPath $StateRoot))) 'Exhaustion publishes no Hot target, receipt or VSS journal'
 foreach($stage in @('journal','readback')){
  & {
   function Write-BackupJsonAtomic($Path,$Value){$script:journalWrites++;throw 'fixture_vss_journal_failed'}
   if($stage-ceq 'readback'){Remove-Item Function:\Write-BackupJsonAtomic}
   $script:fakeClass=New-FakeClass @(10,0);$script:waits=[Collections.Generic.List[int]]::new();$script:cleanups=0;$script:reads=0;$script:journalWrites=0;$script:readFailure=($stage-ceq 'readback');$failure=$null
   try{$null=New-BackupVssSnapshot $Source $StateRoot 'fixture'}catch{$failure=$_}
   Check ($null-ne $failure -and $script:fakeClass.Calls-eq 2 -and $script:fakeClass.Disposed -and $script:cleanups-eq 1 -and ($script:waits-join '|')-ceq '120') 'Post-Create failure cleans up once and never retries Create'
   Check ($failure.Exception.Data['backup_vss_source_snapshot'].create_attempts-eq 2) 'Post-Create failure retains successful creation statistics'
  }
 }
 Write-Output ('RESULT: WeChat VSS retry and publication checks passed; runtime='+$PSVersionTable.PSVersion)
}finally{if([IO.Directory]::Exists($fixture)){[IO.Directory]::Delete($fixture,$true)}}
