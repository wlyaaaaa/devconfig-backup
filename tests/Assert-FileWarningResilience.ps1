[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
. (Join-Path $repo 'DevConfig.Sources.ps1')
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixture=Join-Path $parent ('backup-file-warnings-'+[guid]::NewGuid().ToString('N'))
$script:checks=0
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw ('FAIL: '+$Name)};$script:checks++;Write-Host ('PASS: '+($Name -split ': \{')[0])}
function Put([string]$Path,[string]$Text){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text)}
function NativeError([int]$Code){return [IO.IOException]::new('synthetic native failure',(-2147024896+$Code))}
function New-FaultEntrypoint([string]$Name,[int]$Code){
 $text=[IO.File]::ReadAllText((Join-Path $repo $Name)).Replace('$PSScriptRoot',("'"+$repo.Replace("'","''")+"'"))
 $injection=@'
$script:OriginalCopy=(Get-Command Copy-BackupFileVerified).ScriptBlock
function Copy-BackupFileVerified([string]$Source,[string]$Destination,[string]$ExpectedHash){
 if($Source.EndsWith('\blocked.bin')){throw [IO.IOException]::new('synthetic antivirus failure',__HRESULT__)}
 & $script:OriginalCopy $Source $Destination $ExpectedHash
}
'@
 $text=$text.Replace('$script:GDriveRemoteWasExplicit=',$injection.Replace('__HRESULT__',[string](-2147024896+$Code))+"`r`n"+'$script:GDriveRemoteWasExplicit=')
 $path=Join-Path $fixture ('fault-'+$Code+'-'+$Name);[IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($true));return $path
}
function Run-Script([string]$Path,[string[]]$Arguments){
 $runtime=(Get-Process -Id $PID).Path;$old=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$output=(& $runtime -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1|Out-String);$exitCode=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 return [pscustomobject]@{Exit=$exitCode;Text=$output}
}
try{
 [void][IO.Directory]::CreateDirectory($fixture)
 foreach($code in @(225,226)){
  $wrapped=[Management.Automation.RuntimeException]::new('outer',[ComponentModel.Win32Exception]::new($code))
  $warning=Get-BackupFileWarning $wrapped 'a/[odd].bin' 'copy'
  Check ($warning.error_code-eq $code -and $warning.reason-ceq $(if($code-eq 225){'antivirus_blocked'}else{'antivirus_removed'})) ('Native and nested Win32 classification '+$code)
  Check (($warning.PSObject.Properties.Name|Sort-Object)-join ',' -ceq 'error_code,reason,relative_path,stage') 'Uniform warning fields'
 }
 Check ($null-eq (Get-BackupFileWarning (NativeError 5) 'a' 'copy' -AllowSourceDisappeared)) 'Access denied stays outside the antivirus rule'
 Check ($null-eq (Get-BackupFileWarning ([IO.FileNotFoundException]::new()) 'a' 'verify')) 'Unexplained destination absence is fatal'
 Check ((Get-BackupFileWarning ([IO.FileNotFoundException]::new()) 'a' 'copy' -AllowSourceDisappeared).reason-ceq 'source_disappeared') 'Only known source absence is a warning'
 Check (-not (Test-BackupWarningPath 'a/x.bin' @([pscustomobject]@{relative_path='a/[x].bin'}))) 'Warning paths are literal, not wildcard patterns'

 # Read-only Defender evidence must be a successful action on the exact destination.
 $script:eventXml='<Event><EventData><Data Name="Path">file:_E:\synthetic\quarantined.bin</Data><Data Name="Action ID">2</Data><Data Name="Error Code">0x00000000</Data></EventData></Event>'
 function Get-WinEvent{param($FilterHashtable,$ErrorAction);$item=[pscustomobject]@{};$item|Add-Member ScriptMethod ToXml {$script:eventXml};return $item}
 Check (Test-BackupDefenderRemovedPath 'E:\synthetic\quarantined.bin' ([DateTimeOffset]::UtcNow.AddMinutes(-1))) 'Successful same-path Defender action matches'
 Check (-not (Test-BackupDefenderRemovedPath 'E:\synthetic\quarantined.bin.other' ([DateTimeOffset]::UtcNow))) 'Similar Defender path does not match'
 $script:eventXml=$script:eventXml.Replace('<Data Name="Action ID">2</Data>','<Data Name="Action ID">6</Data>')
 Check (-not (Test-BackupDefenderRemovedPath 'E:\synthetic\quarantined.bin' ([DateTimeOffset]::UtcNow))) 'Allow action is not removal evidence'
 $script:eventXml=$script:eventXml.Replace('<Data Name="Action ID">6</Data>','<Data Name="Action ID">2</Data>')
 $script:eventXml=$script:eventXml.Replace('0x00000000','0x80508023')
 Check (-not (Test-BackupDefenderRemovedPath 'E:\synthetic\quarantined.bin' ([DateTimeOffset]::UtcNow))) 'Unsuccessful Defender action is insufficient'

 # Scan and hash skip only the affected file, then preserve its last successful copy.
 foreach($stage in @('scan','hash','copy')){foreach($code in @(225,226)){
  . (Join-Path $repo 'Backup.Common.ps1')
  $src=Join-Path $fixture ($stage+$code+'-source');$dest=Join-Path $fixture ($stage+$code+'-target')
  Put (Join-Path $src 'blocked.bin') 'old';Put (Join-Path $src 'good.bin') 'old-good'
  $null=Invoke-VerifiedBackupTree $src $dest
  Put (Join-Path $src 'blocked.bin') 'new';Put (Join-Path $src 'good.bin') 'new-good'
  $script:FaultPath=Join-Path $src 'blocked.bin';$script:FaultCode=$code
  if($stage-eq 'scan'){
   $script:OriginalAttributes=(Get-Command Get-BackupEntryAttributes).ScriptBlock
   function Get-BackupEntryAttributes([string]$Path){if($Path-ieq $script:FaultPath){throw (NativeError $script:FaultCode)};& $script:OriginalAttributes $Path}
  }elseif($stage-eq 'hash'){
   $script:OriginalHash=(Get-Command Get-BackupStableFileHash).ScriptBlock
   function Get-BackupStableFileHash([string]$Path){if($Path-ieq $script:FaultPath){throw (NativeError $script:FaultCode)};& $script:OriginalHash $Path}
  }else{
   $script:OriginalCopy=(Get-Command Copy-BackupFileVerified).ScriptBlock
   function Copy-BackupFileVerified([string]$Source,[string]$Destination,[string]$ExpectedHash){if($Source-ieq $script:FaultPath){throw (NativeError $script:FaultCode)};& $script:OriginalCopy $Source $Destination $ExpectedHash}
  }
  $record=Invoke-VerifiedBackupTree $src $dest
  Check ($record.status-ceq 'complete' -and @($record.file_warnings).Count-ge 1 -and $record.file_warnings[0].error_code-eq $code) ($stage+' antivirus completes with warning '+$code)
  Check ([IO.File]::ReadAllText((Join-Path $dest 'good.bin'))-ceq 'new-good' -and [IO.File]::ReadAllText((Join-Path $dest 'blocked.bin'))-ceq 'old') ($stage+' preserves old copy and continues other files')
  $null=Get-VerifiedBackupTreeManifest $dest -VerifyContent
  . (Join-Path $repo 'Backup.Common.ps1')
  $retry=Invoke-VerifiedBackupTree $src $dest
  Check (@($retry.file_warnings).Count-eq 0 -and [IO.File]::ReadAllText((Join-Path $dest 'blocked.bin'))-ceq 'new') ($stage+' naturally retries next run')
 }}
 foreach($stage in @('destination_copy','destination_hash','source_scan_disappeared','source_copy_disappeared')){
  . (Join-Path $repo 'Backup.Common.ps1')
  $src=Join-Path $fixture ($stage+'-source');$dest=Join-Path $fixture ($stage+'-target');Put (Join-Path $src 'blocked.bin') 'old';Put (Join-Path $src 'good.bin') 'old-good';$null=Invoke-VerifiedBackupTree $src $dest
  Put (Join-Path $src 'blocked.bin') 'new';Put (Join-Path $src 'good.bin') 'new-good';$script:FaultPath=Join-Path $src 'blocked.bin';$script:MovedTo=Join-Path $fixture ($stage+'-moved.bin');$script:Fault=$stage
  if($stage-eq 'destination_hash'){
   $script:OriginalHash=(Get-Command Get-BackupStableFileHash).ScriptBlock
   function Get-BackupStableFileHash([string]$Path){if($Path-like '*.incoming-*\blocked.bin'){throw (NativeError 226)};& $script:OriginalHash $Path}
  }elseif($stage-eq 'source_scan_disappeared'){
   $script:OriginalAttributes=(Get-Command Get-BackupEntryAttributes).ScriptBlock
   function Get-BackupEntryAttributes([string]$Path){if($Path-ieq $script:FaultPath -and [IO.File]::Exists($Path)){[IO.File]::Move($Path,$script:MovedTo)};& $script:OriginalAttributes $Path}
  }else{
   $script:OriginalCopy=(Get-Command Copy-BackupFileVerified).ScriptBlock
   function Copy-BackupFileVerified([string]$Source,[string]$Destination,[string]$ExpectedHash){
    if($Source-ieq $script:FaultPath){if($script:Fault-eq 'destination_copy'){$error=NativeError 225;$error.Data['backup_file_stage']='destination_write';throw $error};[IO.File]::Move($Source,$script:MovedTo)}
    & $script:OriginalCopy $Source $Destination $ExpectedHash
   }
  }
  $record=Invoke-VerifiedBackupTree $src $dest
  Check ($record.status-ceq 'complete' -and @($record.file_warnings).Count-ge 1 -and [IO.File]::ReadAllText((Join-Path $dest 'good.bin'))-ceq 'new-good') ($stage+' keeps other files complete')
  Check ([IO.File]::ReadAllText((Join-Path $record.previous_path 'blocked.bin'))-ceq 'old') ($stage+' retains the previous copy')
  $null=Get-VerifiedBackupTreeManifest $dest -VerifyContent
  if($stage-eq 'source_copy_disappeared'){
   . (Join-Path $repo 'Backup.Common.ps1');$ordinaryNext=Invoke-VerifiedBackupTree $src $dest
   Check (@($ordinaryNext.file_warnings).Count-eq 0 -and -not [IO.File]::Exists((Join-Path $dest 'blocked.bin'))) 'Ordinary disappearance protects only its run and later follows source deletion'
  }
 }
 . (Join-Path $repo 'Backup.Common.ps1')
 $src=Join-Path $fixture 'pending-av-source';$dest=Join-Path $fixture 'pending-av-target';Put (Join-Path $src 'blocked.bin') 'old';Put (Join-Path $src 'good.bin') 'old-good';$null=Invoke-VerifiedBackupTree $src $dest
 Put (Join-Path $src 'blocked.bin') 'new';$script:FaultPath=Join-Path $src 'blocked.bin';$script:OriginalCopy=(Get-Command Copy-BackupFileVerified).ScriptBlock
 function Copy-BackupFileVerified([string]$Source,[string]$Destination,[string]$ExpectedHash){if($Source-ieq $script:FaultPath){throw (NativeError 225)};& $script:OriginalCopy $Source $Destination $ExpectedHash}
 $null=Invoke-VerifiedBackupTree $src $dest
 . (Join-Path $repo 'Backup.Common.ps1')
 [IO.File]::Move((Join-Path $src 'blocked.bin'),(Join-Path $fixture 'pending-av-moved.bin'));Put (Join-Path $src 'good.bin') 'new-good'
 $pending=Invoke-VerifiedBackupTree $src $dest
 Check ($pending.status-ceq 'complete' -and $pending.file_warnings[0].reason-ceq 'antivirus_blocked' -and $pending.file_warnings[0].stage-ceq 'source_retry' -and [IO.File]::ReadAllText((Join-Path $dest 'blocked.bin'))-ceq 'old') 'A prior antivirus path absent next run retains its old copy'
 $null=Get-VerifiedBackupTreeManifest $dest -VerifyContent
 [IO.File]::Move((Join-Path $fixture 'pending-av-moved.bin'),(Join-Path $src 'blocked.bin'));$recovered=Invoke-VerifiedBackupTree $src $dest
 Check (@($recovered.file_warnings).Count-eq 0 -and [IO.File]::ReadAllText((Join-Path $dest 'blocked.bin'))-ceq 'new') 'Recovered antivirus source copies normally and clears its pending warning'

 # The file can vanish after enumeration and before copy, including a required config file.
 . (Join-Path $repo 'Backup.Common.ps1')
 $profile=Join-Path $fixture 'profile';Put (Join-Path $profile 'settings/gone.txt') 'gone';Put (Join-Path $profile 'settings/good.txt') 'good'
 $config=@{HomeDirs=@('settings');RequiredSources=@('home/settings')}
 $inventory=Get-DevConfigSourceInventory $config $profile
 [IO.File]::Move((Join-Path $profile 'settings/gone.txt'),(Join-Path $fixture 'moved-source.txt'))
 Copy-DevConfigSourceInventory $inventory (Join-Path $fixture 'config-stage')
 Check ($inventory.file_count-eq 1 -and $inventory.file_warnings[0].reason-ceq 'source_disappeared') 'Config capture skips an enumerated vanished file'
 Check ((Test-DevConfigSelectionAfterCapture $inventory (Get-DevConfigSourceInventory $config $profile))-eq 0) 'Source recheck does not turn a warned missing file into failure'
 Put (Join-Path $profile 'settings/new.txt') 'new'
 $refused=$false;try{$null=Test-DevConfigSelectionAfterCapture $inventory (Get-DevConfigSourceInventory $config $profile)}catch{$refused=$true}
 Check $refused 'Unrelated selection changes still fail'
 $directProfile=Join-Path $fixture 'direct-profile';Put (Join-Path $directProfile 'required.txt') 'required'
 $directConfig=@{HomeFiles=@('required.txt');RequiredSources=@('home/required.txt')}
 $direct=Get-DevConfigSourceInventory $directConfig $directProfile
 [IO.File]::Move((Join-Path $directProfile 'required.txt'),(Join-Path $fixture 'moved-required.txt'))
 $again=Get-DevConfigSourceInventory $directConfig $directProfile -KnownInventory $direct
 Check (@($again.file_warnings).Count-eq 1 -and (Test-DevConfigSelectionAfterCapture $direct $again)-eq 0) 'An enumerated required single file disappearing on recheck is warned'
 $refused=$false;try{$null=Get-DevConfigSourceInventory $directConfig $directProfile}catch{$refused=$true}
 Check $refused 'A required file absent at the start still fails'

 foreach($evidence in @($false,$true)){
  . (Join-Path $repo 'Backup.Common.ps1')
  $src=Join-Path $fixture ('removed-source-'+$evidence);$dest=Join-Path $fixture ('removed-target-'+$evidence)
  Put (Join-Path $src 'missing.bin') 'copied';Put (Join-Path $src 'good.bin') 'good'
  $script:OriginalCopy=(Get-Command Copy-BackupFileVerified).ScriptBlock;$script:Evidence=$evidence;$script:MovedTo=Join-Path $fixture ('quarantine-'+$evidence+'.bin');$script:RemovedPath=$null
  function Copy-BackupFileVerified([string]$Source,[string]$Destination,[string]$ExpectedHash){& $script:OriginalCopy $Source $Destination $ExpectedHash;if($Source.EndsWith('\missing.bin')){$script:RemovedPath=$Destination;[IO.File]::Move($Destination,$script:MovedTo)}}
  function Test-BackupDefenderRemovedPath([string]$Path,[DateTimeOffset]$Since){return ($script:Evidence -and $Path-ieq $script:RemovedPath)}
  $record=$null;$refused=$false;try{$record=Invoke-VerifiedBackupTree $src $dest}catch{$refused=$true}
  Check ($refused-eq (-not $evidence)) ('Destination quarantine requires exact evidence: '+$evidence)
  if($evidence){Check ($record.status-ceq 'complete' -and $record.file_warnings[0].reason-ceq 'antivirus_removed' -and $record.file_warnings[0].stage-ceq 'verify') 'Matched quarantine is visible as warning'}
 }
 foreach($evidence in @($false,$true)){
  . (Join-Path $repo 'Backup.Common.ps1')
  $src=Join-Path $fixture ('published-source-'+$evidence);$dest=Join-Path $fixture ('published-target-'+$evidence);Put (Join-Path $src 'blocked.bin') 'old';Put (Join-Path $src 'good.bin') 'good';$old=Invoke-VerifiedBackupTree $src $dest
  Put (Join-Path $src 'blocked.bin') 'new';$script:PublishedPath=Join-Path $dest 'blocked.bin';$script:MovedTo=Join-Path $fixture ('published-quarantine-'+$evidence+'.bin');$script:Evidence=$evidence
  $script:OriginalAttributes=(Get-Command Get-BackupEntryAttributes).ScriptBlock
  function Get-BackupEntryAttributes([string]$Path){if($Path-ieq $script:PublishedPath -and [IO.File]::Exists($Path)){[IO.File]::Move($Path,$script:MovedTo)};& $script:OriginalAttributes $Path}
  function Test-BackupDefenderRemovedPath([string]$Path,[DateTimeOffset]$Since){return ($script:Evidence -and $Path-ieq $script:PublishedPath)}
  $record=$null;$refused=$false;try{$record=Invoke-VerifiedBackupTree $src $dest}catch{$refused=$true}
  Check ($refused-eq (-not $evidence)) ('Post-rename quarantine requires exact evidence: '+$evidence)
  if($evidence){Check ($record.file_warnings[0].reason-ceq 'antivirus_removed' -and (Get-VerifiedBackupTreeManifest $dest -VerifyContent).content_sha256-ceq $record.content_sha256) 'Post-rename quarantine updates the bound manifest'}else{Check ((Get-VerifiedBackupTreeManifest $dest).run_id-ceq $old.run_id) 'Unexplained post-rename absence rolls back'}
 }

 # Genuine write failure and unequal bytes must retain the last generation.
 foreach($fault in @('disk','mismatch')){
  . (Join-Path $repo 'Backup.Common.ps1')
  $src=Join-Path $fixture ($fault+'-source');$dest=Join-Path $fixture ($fault+'-target');Put (Join-Path $src 'value.bin') 'old';$old=Invoke-VerifiedBackupTree $src $dest;Put (Join-Path $src 'value.bin') 'new'
  $script:OriginalCopy=(Get-Command Copy-BackupFileVerified).ScriptBlock;$script:Fault=$fault
  function Copy-BackupFileVerified([string]$Source,[string]$Destination,[string]$ExpectedHash){if($Source.EndsWith('\value.bin')){if($script:Fault-eq 'disk'){throw (NativeError 112)};Put $Destination 'bad';return};& $script:OriginalCopy $Source $Destination $ExpectedHash}
  $refused=$false;try{$null=Invoke-VerifiedBackupTree $src $dest}catch{$refused=$true}
  Check ($refused -and (Get-VerifiedBackupTreeManifest $dest).run_id-ceq $old.run_id) ('True '+$fault+' failure does not replace the prior generation')
 }

 # Real entrypoints/package publication/status propagation, with only the copy operation injected.
 . (Join-Path $repo 'Backup.Common.ps1')
 $profile=Join-Path $fixture 'entry-profile';$output=Join-Path $fixture 'entry-output';$hot=Join-Path $fixture 'entry-hot';$sources=Join-Path $fixture 'sources.psd1'
 Put (Join-Path $profile 'settings/blocked.bin') 'old';Put (Join-Path $profile 'settings/good.bin') 'old-good'
 Put $sources "@{HomeDirs=@('settings');RequiredSources=@('home/settings');ExcludeDirs=@();ExcludeFiles=@();HistoryDirs=@();HistoryFiles=@()}"
 $args=@('-ProfileRoot',$profile,'-SourcesFile',$sources,'-OutputRoot',$output,'-HotRoot',$hot,'-SkipSystemExport','-Tier','Local,Hot','-KeepLocal','1','-KeepHot','1','-Json')
 $normal=Run-Script (Join-Path $repo 'Backup-DevConfig.ps1') $args
 Check ($normal.Exit-eq 0) ('Normal config entrypoint: '+$normal.Text)
 $prior=Get-VerifiedDevConfigPackage (Join-Path $output 'out')
 Put (Join-Path $profile 'settings/blocked.bin') 'new';Put (Join-Path $profile 'settings/good.bin') 'new-good'
 $warned=Run-Script (New-FaultEntrypoint 'Backup-DevConfig.ps1' 225) $args
 $run=Read-BackupJson (Join-Path $output 'state/devconfig-local-last.json') -Required
 Check ($warned.Exit-eq 0 -and $run.status-ceq 'complete' -and $run.file_warnings[0].reason-ceq 'antivirus_blocked') ('Config entrypoint remains complete with warning: '+$warned.Text)
 $pack=Get-VerifiedDevConfigPackage (Join-Path $output 'out');$hotPack=Get-VerifiedDevConfigPackage $hot
 Check ($pack.Receipt.file_warnings[0].relative_path-ceq 'home/settings/blocked.bin' -and $pack.Sha-ceq $hotPack.Sha -and @($hotPack.Current.file_warnings).Count-eq 1) 'Package receipt and G pointer propagate file warning'
 Check ([IO.File]::Exists($prior.Zip) -and [IO.File]::Exists((Join-Path $hot $prior.Name))) 'Warned config generation does not prune old packages even with Keep=1'
 [IO.File]::Move((Join-Path $profile 'settings/blocked.bin'),(Join-Path $fixture 'config-av-moved.bin'))
 $pending=Run-Script (Join-Path $repo 'Backup-DevConfig.ps1') $args;$pendingRun=Read-BackupJson (Join-Path $output 'state/devconfig-local-last.json')
 Check ($pending.Exit-eq 0 -and $pendingRun.file_warnings[0].reason-ceq 'antivirus_blocked' -and $pendingRun.file_warnings[0].stage-ceq 'source_retry' -and [IO.File]::Exists($prior.Zip)) 'Config package carries the prior antivirus absence and preserves old packages'
 [IO.File]::Move((Join-Path $fixture 'config-av-moved.bin'),(Join-Path $profile 'settings/blocked.bin'))
 $retry=Run-Script (Join-Path $repo 'Backup-DevConfig.ps1') $args
 Check ($retry.Exit-eq 0 -and @((Read-BackupJson (Join-Path $output 'state/devconfig-local-last.json')).file_warnings).Count-eq 0) 'Normal config run retries the formerly warned file'

 $src=Join-Path $fixture 'entry-wechat-source';$dest=Join-Path $fixture 'entry-wechat-hot';$receipt=Join-Path $fixture 'entry-wechat-receipt.json';$state=Join-Path $output 'state'
 Put (Join-Path $src 'blocked.bin') 'old';Put (Join-Path $src 'good.bin') 'old-good'
 $args=@('-Source',$src,'-HotRoot',$dest,'-HotReceiptPath',$receipt,'-StateRoot',$state,'-Target','Hot','-Json')
 $normal=Run-Script (Join-Path $repo 'Backup-WeChat.ps1') $args;Check ($normal.Exit-eq 0) 'Normal WeChat entrypoint'
 $normalReceipt=Read-BackupJson $receipt;Check (-not $normalReceipt.payload_names_emitted -and -not $normalReceipt.payload_content_interpreted) 'A receipt without file warnings emits no payload names and interprets no content'
 Put (Join-Path $src 'blocked.bin') 'new';Put (Join-Path $src 'good.bin') 'new-good'
 $warned=Run-Script (New-FaultEntrypoint 'Backup-WeChat.ps1' 226) $args
 $run=Read-BackupJson (Join-Path $state 'wechat-local-last.json') -Required;$manifest=Get-VerifiedBackupTreeManifest $dest -VerifyContent
 Check ($warned.Exit-eq 0 -and $run.status-ceq 'complete' -and $run.hot-ceq 'complete' -and $run.file_warnings[0].error_code-eq 226) ('WeChat entrypoint remains complete with warning: '+$warned.Text)
 Check ((Test-BackupTreeReceiptBound $receipt $dest $manifest) -and @((Read-BackupJson $receipt).file_warnings).Count-eq 1) 'Warned WeChat receipt remains bound to its verified manifest'
 $warnedReceipt=Read-BackupJson $receipt;Check ($warnedReceipt.payload_names_emitted -and -not $warnedReceipt.payload_content_interpreted) 'Warning relative paths count as emitted names while payload content remains uninterpreted'
 $plan=Run-Script (Join-Path $repo 'Backup-WeChat.ps1') @('-Source',$src,'-HotRoot',$dest,'-HotReceiptPath',$receipt,'-StateRoot',$state,'-Target','Drive','-AllowLiveSourceHot','-Plan','-Json')
 Check ($plan.Exit-eq 0 -and ($plan.Text|ConvertFrom-Json).targets[0].upload_ready) 'Warned G generation passes existing read-only Drive gate'
 $status=Run-Script (Join-Path $repo 'Backup-Status.ps1') @('-OutputRoot',$output,'-HotRoot',$hot,'-WeChatHotRoot',$dest,'-HotReceiptPath',$receipt,'-Json')
 $snapshot=$status.Text|ConvertFrom-Json
 Check ($status.Exit-eq 0 -and $snapshot.status-ceq 'receipts_current_with_file_warnings' -and $snapshot.file_warnings[0].relative_path-ceq 'blocked.bin') 'Existing JSON status entry exposes complete with file warnings'
 $human=Run-Script (Join-Path $repo 'Backup-Status.ps1') @('-OutputRoot',$output,'-HotRoot',$hot,'-WeChatHotRoot',$dest,'-HotReceiptPath',$receipt)
 Check ($human.Exit-eq 0 -and $human.Text.Contains('blocked.bin') -and $human.Text.Contains('226')) 'Existing human status entry shows warning path and code'
 Write-Output ('RESULT: '+$script:checks+' file warning checks passed')
}finally{
 if([IO.Directory]::Exists($fixture)){
  $recycled=& pwsh -NoProfile -ExecutionPolicy Bypass -File 'E:\.agents\tools\Move-TaskItemToRecycleBin.ps1' -LiteralPath $fixture -AllowedRoot $parent -Json | ConvertFrom-Json
  if($recycled.status-ne 'recycled' -or -not $recycled.original_path_verified -or -not $recycled.recovery_item_exists){throw 'fixture_recycle_failed'}
 }
}
