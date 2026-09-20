[CmdletBinding()]
param([switch]$SkipCloud)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
. (Join-Path $repo 'Initialize-BackupNetwork.ps1')
Set-Variable -Name FixtureParent -Scope Script -Option ReadOnly -Value ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\'))
Set-Variable -Name FixtureRoot -Scope Script -Option ReadOnly -Value (Join-Path $script:FixtureParent ('backup-closure-'+[guid]::NewGuid().ToString('N')))
$script:checks=0;$runtime=(Get-Process -Id $PID).Path;$oldConfig=$env:RCLONE_CONFIG
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw ('FAIL: '+$Name)};$script:checks++;Write-Host ('PASS: '+$Name)}
function Put([string]$Path,[string]$Text){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Run([string]$Name,[string[]]$Arguments){
 $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$text=(& $runtime -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo $Name) @Arguments 2>&1|Out-String);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 return [pscustomobject]@{Exit=$code;Text=$text}
}
try{
 [void][IO.Directory]::CreateDirectory($script:FixtureRoot)
 $refused=$false;try{Remove-BackupOwnedDirectory $repo ([IO.Path]::GetDirectoryName($repo)) '^backup-closure-[a-f0-9]{32}$'}catch{$refused=$true}
 Check ($refused -and [IO.File]::Exists((Join-Path $repo 'Backup.Common.ps1'))) 'Cleanup rejects source repository even if a test variable accidentally points to it'
 $readonlyOwned=Join-Path $script:FixtureRoot 'owned-readonly';Put (Join-Path $readonlyOwned 'fixture.bin') 'read-only cleanup';[IO.File]::SetAttributes((Join-Path $readonlyOwned 'fixture.bin'),[IO.FileAttributes]::ReadOnly);Remove-BackupOwnedDirectory $readonlyOwned $script:FixtureRoot '^owned-readonly$'
 Check (-not [IO.Directory]::Exists($readonlyOwned)) 'Owned cleanup clears read-only attributes before removing its exact directory'
 $profile=Join-Path $script:FixtureRoot 'profile';$output=Join-Path $script:FixtureRoot 'output';$hot=Join-Path $script:FixtureRoot 'hot'
 Put (Join-Path $profile '.gitconfig') 'synthetic required configuration';Put (Join-Path $profile 'settings\one.txt') 'AAAA'
 $sources=Join-Path $script:FixtureRoot 'sources.psd1';Put $sources "@{HomeFiles=@('.gitconfig','optional-absent');HomeDirs=@('settings');RequiredSources=@('home/.gitconfig');ExcludeDirs=@();ExcludeFiles=@();HistoryDirs=@();HistoryFiles=@()}"
 $base=@('-ProfileRoot',$profile,'-SourcesFile',$sources,'-OutputRoot',$output,'-HotRoot',$hot,'-SkipSystemExport','-Json')
 $r=Run 'Backup-DevConfig.ps1' ($base+@('-Plan'));Check ($r.Exit-eq 0 -and -not [IO.Directory]::Exists($output)) ('Plan is zero-write: '+$r.Text)
 Check (($r.Text|ConvertFrom-Json).optional_absent_count-eq 1) 'Optional absent source differs from a required failure'
 . (Join-Path $repo 'DevConfig.Sources.ps1')
 $refused=$false;try{$null=Get-DevConfigSourceInventory @{HomeFiles=@('optional')} (Join-Path $script:FixtureRoot 'nonexistent-profile')}catch{$refused=$true};Check $refused 'Unreadable profile cannot publish an empty successful backup'
 $refused=$false;try{$null=Get-DevConfigSourceInventory @{HomeFiles=@('.gitconfig');RequiredSources=@('typo')} $profile}catch{$refused=$true};Check $refused 'An undeclared required source is rejected'
 $r=Run 'Backup-DevConfig.ps1' ($base+@('-Tier','Local,Hot'));Check ($r.Exit-eq 0) ('First Local+Hot generation: '+$r.Text)
 $out=Join-Path $output 'out';$first=Get-VerifiedDevConfigPackage $out;$firstHot=Get-VerifiedDevConfigPackage $hot
 Check ($first.Sha-ceq $firstHot.Sha) 'Hot immutable package matches local package'
 Check ((Get-BackupStableFileHash (Join-Path $hot 'latest.zip'))-ceq $first.Sha -and [IO.File]::Exists((Join-Path $hot 'latest.zip.receipt.json'))) 'Hot latest has matching bytes and portable success proof'
 $r=Run 'Backup-DevConfig.ps1' ($base+@('-Tier','Local,Hot'));$second=Get-VerifiedDevConfigPackage $out
 Check ($r.Exit-eq 0 -and $second.Name-ceq $first.Name) 'Unchanged useful content reuses the same archive'
 $path=Join-Path $profile 'settings\one.txt';$time=[IO.File]::GetLastWriteTimeUtc($path);Put $path 'BBBB';[IO.File]::SetLastWriteTimeUtc($path,$time)
 $r=Run 'Backup-DevConfig.ps1' ($base+@('-Tier','Local,Hot'));$changed=Get-VerifiedDevConfigPackage $out
 Check ($r.Exit-eq 0 -and $changed.Sha-cne $first.Sha) 'Same-size same-time content change is detected'
 $pointerHash=Get-BackupStableFileHash (Join-Path $out 'current.json');$hotHash=Get-BackupStableFileHash (Join-Path $hot 'current.json')
 [IO.File]::Move((Join-Path $profile '.gitconfig'),(Join-Path $profile '.saved'))
 $r=Run 'Backup-DevConfig.ps1' ($base+@('-Tier','Local,Hot','-KeepLocal','1'))
 Check ($r.Exit-ne 0) 'Required-source failure is a nonzero task result'
 Check ((Get-BackupStableFileHash (Join-Path $out 'current.json'))-ceq $pointerHash -and (Get-BackupStableFileHash (Join-Path $hot 'current.json'))-ceq $hotHash) 'Failed collection cannot replace success pointers'
 Check ([IO.File]::Exists($first.Zip)) 'Failed collection cannot prune an older successful generation'
 [IO.File]::Move((Join-Path $profile '.saved'),(Join-Path $profile '.gitconfig'))
 $legacy=Join-Path $script:FixtureRoot 'legacy';Put (Join-Path $legacy 'devconfig-20260917.zip') 'legacy';Put (Join-Path $legacy 'latest.sha256') ('0'*64+'  devconfig-20260917.zip')
 $refused=$false;try{$null=Get-DrivePackageSnapshot -OutDir $legacy -StateDir $legacy}catch{$refused=$true};Check $refused 'Legacy hash-only record cannot authorize cloud publication'
 $receiptPath=$changed.Zip+'.receipt.json';$receiptBytes=[IO.File]::ReadAllBytes($receiptPath);$bad=Read-BackupJson $receiptPath;$bad.collection_status='failed';Write-BackupJsonAtomic $receiptPath $bad
 $refused=$false;try{$null=Get-VerifiedDevConfigPackage $out}catch{$refused=$true};Check $refused 'Incomplete collection receipt cannot be consumed by Drive';[IO.File]::WriteAllBytes($receiptPath,$receiptBytes)
 $restore=Join-Path $script:FixtureRoot 'restored';Put (Join-Path $restore 'original.txt') 'keep original'
 $r=Run 'Restore-DevConfig.ps1' @('-Archive',$changed.Zip,'-Destination',$restore,'-Json');Check ($r.Exit-eq 0 -and [IO.File]::Exists((Join-Path $restore 'original.txt'))) 'Restore defaults to a read-only plan'
 $r=Run 'Restore-DevConfig.ps1' @('-Archive',$changed.Zip,'-Destination',$restore,'-Execute','-Json');Check ($r.Exit-ne 0 -and [IO.File]::Exists((Join-Path $restore 'original.txt'))) 'Restore refuses implicit overwrite'
 $r=Run 'Restore-DevConfig.ps1' @('-Archive',$changed.Zip,'-Destination',$restore,'-Execute','-ReplaceExisting','-Json');Check ($r.Exit-eq 0) ('Verified extraction: '+$r.Text)
 $recovered=$r.Text|ConvertFrom-Json;Check ([IO.File]::ReadAllText((Join-Path $restore 'home\settings\one.txt'))-ceq 'BBBB' -and [IO.File]::Exists((Join-Path $recovered.rollback_path 'original.txt'))) 'Recovered bytes and pre-restore original both remain intact'
 $shared=Join-Path $script:FixtureRoot 'shared.bin';Put $shared 'shared open database'
 $writer=[IO.File]::Open($shared,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
 try{$hash=Get-BackupStableFileHash $shared;Copy-BackupFileVerified $shared ($shared+'.copy') $hash;Check ((Get-BackupStableFileHash ($shared+'.copy'))-ceq $hash) 'Open shared database can be copied without stopping its owner'}finally{$writer.Dispose()}
 $ws=Join-Path $script:FixtureRoot 'wechat-source';$wd=Join-Path $script:FixtureRoot 'wechat-target';Put (Join-Path $ws 'account\db_storage\fixture.bin') 'old1';Put (Join-Path $ws 'account\media.bin') 'media'
 $plan=Invoke-VerifiedBackupTree $ws $wd -Plan;Check ($plan.write_mode-eq 'zero_write' -and -not [IO.Directory]::Exists($wd) -and -not [IO.File]::Exists($wd+'.backup.lock')) 'Native tree plan creates no directory, log or lock'
 $record=Invoke-VerifiedBackupTree $ws $wd;Check ((Get-VerifiedBackupTreeManifest $wd -VerifyContent).content_sha256-ceq $record.content_sha256) 'Native generation matches its full SHA-256 manifest'
 [IO.File]::Delete((Join-Path $ws 'account\media.bin'));Put (Join-Path $ws 'account\db_storage\fixture.bin') 'new2';$record2=Invoke-VerifiedBackupTree $ws $wd
 Check (-not [IO.File]::Exists((Join-Path $wd 'account\media.bin')) -and [IO.File]::Exists((Join-Path $record2.previous_path 'account\media.bin'))) 'Deletion converges while preserving one bounded predecessor'
 $script:OriginalAtomic=(Get-Command Write-BackupJsonAtomic).ScriptBlock;$script:RejectCommit=$true
 function Write-BackupJsonAtomic {param([string]$Path,$Value);if($script:RejectCommit -and $Path.EndsWith('.backup-manifest.json')){$script:RejectCommit=$false;throw 'synthetic_commit_failure'};& $script:OriginalAtomic $Path $Value}
 Put (Join-Path $ws 'account\db_storage\fixture.bin') 'new3';$refused=$false;try{$null=Invoke-VerifiedBackupTree $ws $wd}catch{$refused=$true}
 . (Join-Path $repo 'Backup.Common.ps1')
 Check ($refused -and [IO.File]::ReadAllText((Join-Path $wd 'account\db_storage\fixture.bin'))-ceq 'new2') 'Manifest commit failure rolls back the previous tree'
 Check (-not [IO.File]::Exists($wd+'.backup-transaction.json')) 'Failed transaction is recovered rather than left falsely complete'
 $lease=Open-BackupResourceLock $wd;$refused=$false;try{try{$null=Invoke-VerifiedBackupTree $ws $wd}catch{$refused=$true}}finally{$lease.Dispose()};Check $refused 'Competing writers cannot mutate the same destination'
 $record3=Invoke-VerifiedBackupTree $ws $wd;Check (-not [IO.Directory]::Exists($record2.previous_path)) 'Only the bounded old predecessor is retired after success'
 $receiptPath=Join-Path $script:FixtureRoot 'wechat-hot-receipt.json';$manifestPath=$wd+'.backup-manifest.json';$priorManifestHash=Get-BackupStableFileHash $manifestPath;$priorPayloadHash=Get-BackupInventoryDigest (Get-BackupTreeInventory $wd -Hash)
 $receiptFailure={param($record)throw 'synthetic_receipt_publication_failure'};$refused=$false;try{$null=Invoke-VerifiedBackupTree $ws $wd -PostCommitReceiptPath $receiptPath -PostCommit $receiptFailure}catch{$refused=$true}
 Check ($refused -and (Get-BackupStableFileHash $manifestPath)-ceq $priorManifestHash -and (Get-BackupInventoryDigest (Get-BackupTreeInventory $wd -Hash))-ceq $priorPayloadHash) 'Receipt publication failure rolls back the committed native tree'
 Check (-not [IO.File]::Exists($wd+'.backup-transaction.json') -and -not (Get-ChildItem -LiteralPath $script:FixtureRoot -Filter 'wechat-hot-receipt.json.previous-*.json' -File -ErrorAction SilentlyContinue)) 'Receipt rollback cleans its transaction sidecars'
 $partialReceipt=Join-Path $script:FixtureRoot 'wechat-hot-partial-receipt.json';$partialFailure={param($record)Write-BackupJsonAtomic $partialReceipt @{schema='wechat.hot-backup-receipt.v2';status='incomplete'};throw 'synthetic_receipt_failure_after_write'};$refused=$false;try{$null=Invoke-VerifiedBackupTree $ws $wd -PostCommitReceiptPath $partialReceipt -PostCommit $partialFailure}catch{$refused=$true}
 Check ($refused -and -not [IO.File]::Exists($partialReceipt) -and -not [IO.File]::Exists($wd+'.backup-transaction.json')) 'Failed receipt publication removes a newly created receipt'
 $scriptHot=Join-Path $script:FixtureRoot 'wechat-hot-script';$scriptReceipt=Join-Path $script:FixtureRoot 'wechat-hot-script-receipt.json';$scriptState=Join-Path $script:FixtureRoot 'wechat-hot-script-state';$r=Run 'Backup-WeChat.ps1' @('-Source',$ws,'-HotRoot',$scriptHot,'-HotReceiptPath',$scriptReceipt,'-StateRoot',$scriptState,'-Target','Hot','-Json');$scriptManifest=Read-BackupJson ($scriptHot+'.backup-manifest.json') -Required
 Check ($r.Exit-eq 0 -and (Test-BackupTreeReceiptBound $scriptReceipt $scriptHot $scriptManifest) -and -not [IO.File]::Exists($scriptHot+'.backup-transaction.json')) 'WeChat Hot entrypoint publishes a receipt bound to the committed tree'
 [IO.Directory]::Delete((Join-Path $ws 'account'),$true);$empty=Invoke-VerifiedBackupTree $ws $wd
 Check ($empty.file_count-eq 0 -and [IO.Directory]::GetFileSystemEntries($wd).Length-eq 0) 'Readable genuinely empty source converges to empty'
 [IO.Directory]::Move($ws,$ws+'.offline');$refused=$false;try{$null=Invoke-VerifiedBackupTree $ws $wd}catch{$refused=$true}
 Check ($refused -and (Get-VerifiedBackupTreeManifest $wd).run_id-ceq $empty.run_id) 'Offline source never becomes a deletion event';[IO.Directory]::Move($ws+'.offline',$ws)
 if(-not $SkipCloud){
  $env:RCLONE_CONFIG=Join-Path $script:FixtureRoot 'rclone.conf';Put $env:RCLONE_CONFIG "[fixture-local]`ntype = local`n"
  $cloud=Join-Path $script:FixtureRoot 'cloud';$r=Run 'Backup-DevConfig.ps1' ($base+@('-Tier','Drive','-GDriveRemote','fixture-local:','-GDriveFolder',$cloud.Replace('\','/'),'-KeepDrive','1'))
  Check ($r.Exit-eq 0) ('Cloud protocol with isolated local backend: '+$r.Text)
  Check ((Get-VerifiedDevConfigPackage $cloud).Sha-ceq $changed.Sha) 'Remote success pointer and portable archive agree'
  $wc=Join-Path $script:FixtureRoot 'wechat-cloud';$wl=Join-Path $script:FixtureRoot 'wechat-local';$state=Join-Path $script:FixtureRoot 'wechat-state'
  Put (Join-Path $ws 'account\db_storage\fixture.bin') 'cloud data';Put (Join-Path $ws 'account\media.bin') 'cloud media';Put (Join-Path $wc 'obsolete.bin') 'obsolete'
  $wx=@('-Source',$ws,'-LocalRoot',$wl,'-HotRoot',(Join-Path $script:FixtureRoot 'unused-hot'),'-StateRoot',$state,'-Target','Drive','-GDriveRemote','fixture-local:','-GDriveFolder',$wc.Replace('\','/'),'-Json')
  $r=Run 'Backup-WeChat.ps1' $wx;Check ($r.Exit-eq 0 -and -not [IO.File]::Exists((Join-Path $wc 'obsolete.bin'))) ('WeChat verifies before cloud pruning: '+$r.Text)
  Check ([IO.File]::Exists($wc+'.backup-manifest.json')) 'Full native cloud copy carries its portable manifest'
  $locked=Join-Path $ws 'account\db_storage\fixture.bin';$lease=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  Put (Join-Path $wc 'must-survive.bin') 'keep after failed snapshot'
  try{$r=Run 'Backup-WeChat.ps1' $wx}finally{$lease.Dispose()}
  Check ($r.Exit-ne 0 -and [IO.File]::Exists((Join-Path $wc 'must-survive.bin'))) 'Failed snapshot cannot enter any cloud mutation'
  [IO.File]::Delete((Join-Path $ws 'account\media.bin'));$r=Run 'Backup-WeChat.ps1' ($wx+@('-DbOnly'))
  Check ($r.Exit-eq 0 -and [IO.File]::Exists((Join-Path $wc 'account\media.bin'))) 'Database-only mode does not delete excluded remote media'
 }
 $production=Import-PowerShellDataFile (Join-Path $repo 'sources.psd1')
 Check ('thread-writer-locks'-in $production.ExcludeDirs -and '*.lock'-notin $production.ExcludeFiles) 'Runtime coordination exclusion does not remove dependency lockfiles generally'
 Write-Output ("RESULT: {0} closure checks passed; runtime={1}; local_cloud_fixture={2}" -f $script:checks,$PSVersionTable.PSVersion,(-not $SkipCloud))
}finally{
 $env:RCLONE_CONFIG=$oldConfig
 Remove-BackupOwnedDirectory $script:FixtureRoot $script:FixtureParent '^backup-closure-[a-f0-9]{32}$'
}
