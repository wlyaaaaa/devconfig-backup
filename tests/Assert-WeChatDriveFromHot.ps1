[CmdletBinding()]
param()
# The weekly WeChat Drive upload must consume only the verified G hot generation:
# fresh and verified -> upload; stale, unverified, missing, changed or busy -> refuse
# before any cloud mutation, with the reason in the run receipt. Isolated local rclone backend only.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
Set-Variable -Name FixtureParent -Scope Script -Option ReadOnly -Value ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\'))
Set-Variable -Name FixtureRoot -Scope Script -Option ReadOnly -Value (Join-Path $script:FixtureParent ('wechat-drive-hot-'+[guid]::NewGuid().ToString('N')))
$script:checks=0;$runtime=(Get-Process -Id $PID).Path;$oldConfig=$env:RCLONE_CONFIG
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw ('FAIL: '+$Name)};$script:checks++;Write-Host ('PASS: '+$Name)}
function Put([string]$Path,[string]$Text){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Run([string[]]$Arguments){
 $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$text=(& $runtime -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'Backup-WeChat.ps1') @Arguments 2>&1|Out-String);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 return [pscustomobject]@{Exit=$code;Text=$text}
}
function Set-ReceiptField([string]$Path,[string]$Name,$Value){$r=Read-BackupJson $Path -Required;$r.$Name=$Value;Write-BackupJsonAtomic $Path $r}
try{
 [void][IO.Directory]::CreateDirectory($script:FixtureRoot)
 $ws=Join-Path $script:FixtureRoot 'source';$wh=Join-Path $script:FixtureRoot 'hot';$wr=Join-Path $script:FixtureRoot 'hot-receipt.json'
 $wl=Join-Path $script:FixtureRoot 'local-must-not-exist';$wc=Join-Path $script:FixtureRoot 'cloud';$state=Join-Path $script:FixtureRoot 'state'
 $runPath=Join-Path $state 'wechat-drive-last.json';$successPath=Join-Path $state 'wechat-drive-success.json'
 Put (Join-Path $ws 'account\db_storage\fixture.bin') 'verified data';Put (Join-Path $ws 'account\media.bin') 'verified media';Put (Join-Path $wc 'obsolete.bin') 'obsolete'
 $env:RCLONE_CONFIG=Join-Path $script:FixtureRoot 'rclone.conf';Put $env:RCLONE_CONFIG "[fixture-local]`ntype = local`n"
 $hotArgs=@('-Source',$ws,'-HotRoot',$wh,'-HotReceiptPath',$wr,'-StateRoot',$state,'-Target','Hot','-Json')
 $driveArgs=@('-Source',$ws,'-LocalRoot',$wl,'-HotRoot',$wh,'-HotReceiptPath',$wr,'-StateRoot',$state,'-Target','Drive','-GDriveRemote','fixture-local:','-GDriveFolder',$wc.Replace('\','/'),'-Json')
 $r=Run $hotArgs;Check ($r.Exit-eq 0) ('Fixture G generation is produced by the real Hot entrypoint: '+$r.Text)
 $manifest=Read-BackupJson ($wh+'.backup-manifest.json') -Required

 # A non-VSS Hot generation is refused by default.
 $r=Run ($driveArgs+@('-Plan'));$plan=($r.Text|ConvertFrom-Json).targets[0]
 Check ($r.Exit-eq 0 -and -not $plan.upload_ready -and $plan.upload_source.refusal-ceq 'wechat_hot_capture_not_vss' -and $plan.cloud-ceq 'not_contacted') 'Plan reports a live-source G generation as not uploadable'
 $r=Run $driveArgs;$run=Read-BackupJson $runPath -Required
 Check ($r.Exit-ne 0 -and $run.failure-ceq 'wechat_hot_capture_not_vss' -and $run.drive-ceq 'not_uploaded' -and [IO.File]::Exists((Join-Path $wc 'obsolete.bin'))) 'Live-source G generation never reaches the cloud'

 # Simulate the production VSS Hot receipt (VSS needs elevation); the tree binding is unchanged.
 Set-ReceiptField $wr 'capture_consistency' 'vss_crash_consistent'
 $r=Run ($driveArgs+@('-Plan'));$plan=($r.Text|ConvertFrom-Json).targets[0]
 Check ($r.Exit-eq 0 -and $plan.upload_ready -and $plan.upload_source.gate-ceq 'passed' -and $plan.source-ieq $wh) 'Plan accepts a fresh verified VSS G generation without contacting the cloud'
 Check ([IO.File]::Exists((Join-Path $wc 'obsolete.bin'))) 'Plan is zero-write for the cloud'
 # The running source changes after verification; Drive must upload the G bytes, not the source.
 Put (Join-Path $ws 'account\db_storage\fixture.bin') 'changed after hot verification'
 $r=Run $driveArgs;$run=Read-BackupJson $runPath -Required;$success=Read-BackupJson $successPath -Required
 Check ($r.Exit-eq 0 -and $run.status-ceq 'complete' -and $run.drive-ceq 'complete') ('Fresh verified G generation is uploaded: '+$r.Text)
 Check ([IO.File]::ReadAllText((Join-Path $wc 'account\db_storage\fixture.bin'))-ceq 'verified data') 'Cloud receives the verified G bytes, not the running source'
 Check (-not [IO.File]::Exists((Join-Path $wc 'obsolete.bin')) -and [IO.File]::Exists($wc+'.backup-manifest.json')) 'Upload converges the cloud copy and carries the portable manifest'
 Check (-not [IO.Directory]::Exists($wl) -and -not [IO.File]::Exists($wl+'.backup.lock')) 'Drive no longer writes a second local copy'
 Check ($run.local-ceq 'not_requested' -and $run.capture_consistency-ceq 'no_source_capture' -and $run.upload_source.gate-ceq 'passed' -and [string]$run.upload_source.hot_generation_id-ceq [string]$manifest.run_id -and $run.upload_source.hot_verification_status-ceq 'sha256_full_tree' -and $run.upload_source.hot_capture_consistency-ceq 'vss_crash_consistent' -and $null-ne $run.upload_source.hot_completed_utc) 'Run receipt names the uploaded G generation, its time and verification'
 Check ([string]$success.upload_source.hot_generation_id-ceq [string]$manifest.run_id -and $success.source-ieq $wh -and $success.content_sha256-ceq $manifest.content_sha256 -and $success.verification_status-ceq 'rclone_checksum_check') 'Drive success receipt is bound to the uploaded G generation'
 foreach($path in @($runPath,$successPath)){$text=[IO.File]::ReadAllText($path);Check ($text-notmatch 'fixture-local' -and $text-notmatch '@') ('Receipt carries no remote account name: '+[IO.Path]::GetFileName($path))}
 Put (Join-Path $wc 'must-survive.bin') 'cloud extra kept after a refused run'
 # Hot reuses unchanged files by hard link, so a G file can keep an older time than its manifest entry.
 $linked=Join-Path $wh 'account\media.bin';$linkedTime=[IO.File]::GetLastWriteTimeUtc($linked);[IO.File]::SetLastWriteTimeUtc($linked,$linkedTime.AddDays(-7))
 try{$r=Run ($driveArgs+@('-Plan'));$plan=($r.Text|ConvertFrom-Json).targets[0]}finally{[IO.File]::SetLastWriteTimeUtc($linked,$linkedTime)}
 Check ($plan.upload_ready) 'A hard-linked G file with an older time but the verified size is still uploadable'

 $receiptBytes=[IO.File]::ReadAllBytes($wr)
 $cases=@(
  @{Name='stale';Code='wechat_hot_receipt_stale';Mutate={Set-ReceiptField $wr 'completed_utc' ([DateTimeOffset]::UtcNow.AddDays(-3).ToString('o'))}},
  @{Name='failed verification';Code='wechat_hot_receipt_not_verified';Mutate={Set-ReceiptField $wr 'status' 'failed'}},
  @{Name='missing receipt';Code='wechat_hot_receipt_missing';Mutate={[IO.File]::Delete($wr)}},
  @{Name='receipt bound to another manifest';Code='wechat_hot_receipt_manifest_mismatch';Mutate={Set-ReceiptField $wr 'manifest_sha256' ('0'*64)}},
  @{Name='tree changed after verification';Code='wechat_hot_tree_changed_since_verification';Mutate={Put (Join-Path $wh 'account\unexpected.bin') 'not in manifest'};Undo={[IO.File]::Delete((Join-Path $wh 'account\unexpected.bin'))}}
 )
 foreach($case in $cases){
  & $case.Mutate
  try{$r=Run $driveArgs;$run=Read-BackupJson $runPath -Required}finally{[IO.File]::WriteAllBytes($wr,$receiptBytes);if($case.Undo){& $case.Undo}}
  Check ($r.Exit-ne 0 -and $run.failure-ceq $case.Code -and $run.upload_source.gate-ceq 'refused' -and $run.upload_source.refusal-ceq $case.Code -and $run.drive-ceq 'not_uploaded') ('Refuses a '+$case.Name+' G generation with reason '+$case.Code)
  Check ([IO.File]::Exists((Join-Path $wc 'must-survive.bin'))) ('No cloud mutation after a '+$case.Name+' refusal')
 }
 $lease=Open-BackupResourceLock $wh
 try{$r=Run $driveArgs;$run=Read-BackupJson $runPath -Required}finally{$lease.Dispose()}
 Check ($r.Exit-ne 0 -and $run.failure-ceq 'wechat_hot_resource_busy' -and [IO.File]::Exists((Join-Path $wc 'must-survive.bin'))) 'A running Hot backup blocks the upload instead of racing it'
 Set-ReceiptField $wr 'completed_utc' ([DateTimeOffset]::UtcNow.AddHours(-60).ToString('o'))
 $r=Run ($driveArgs+@('-Plan','-MaxHotAgeHours','72'));$plan=($r.Text|ConvertFrom-Json).targets[0];[IO.File]::WriteAllBytes($wr,$receiptBytes)
 Check ($plan.upload_ready -and [double]$plan.upload_source.hot_age_hours-gt 48) 'The freshness limit is an explicit parameter'

 # Database-only mode still never prunes media that is outside its filter.
 [IO.File]::Delete((Join-Path $ws 'account\media.bin'));$r=Run $hotArgs;Check ($r.Exit-eq 0) 'Second fixture G generation'
 Set-ReceiptField $wr 'capture_consistency' 'vss_crash_consistent'
 $r=Run ($driveArgs+@('-DbOnly'))
 Check ($r.Exit-eq 0 -and [IO.File]::Exists((Join-Path $wc 'account\media.bin'))) ('Database-only mode does not delete excluded remote media: '+$r.Text)
 Write-Output ("RESULT: {0} WeChat Drive-from-G checks passed; runtime={1}" -f $script:checks,$PSVersionTable.PSVersion)
}finally{
 $env:RCLONE_CONFIG=$oldConfig
 Remove-BackupOwnedDirectory $script:FixtureRoot $script:FixtureParent '^wechat-drive-hot-[a-f0-9]{32}$'
}
