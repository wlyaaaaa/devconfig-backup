[CmdletBinding()]
param([string]$RepoRoot='')
$ErrorActionPreference='Stop'
if(-not $RepoRoot){$RepoRoot=Split-Path -Parent $PSScriptRoot}
function Assert-Condition([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Read-TestAst([string]$Path){
 $tokens=$null;$parseErrors=$null
 $tree=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$parseErrors)
 if($parseErrors.Count){throw 'source_parse_failed'}
 return $tree
}
$devTree=Read-TestAst (Join-Path $RepoRoot 'Backup-DevConfig.ps1')
$commonTree=Read-TestAst (Join-Path $RepoRoot 'Backup.Common.ps1')
$networkTree=Read-TestAst (Join-Path $RepoRoot 'Initialize-BackupNetwork.ps1')
foreach($name in @('Throw-DriveMetadataFailure','Throw-DrivePackageFailure','Push-Drive')){
 $definition=$devTree.Find({param($node) $node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-ceq $name},$true)
 if(-not $definition){throw ('source_function_missing:'+ $name)}
 Invoke-Expression $definition.Extent.Text
}
$failureCode=$commonTree.Find({param($node) $node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-ceq 'Get-BackupFailureCode'},$true)
Invoke-Expression $failureCode.Extent.Text
$categoryFunction=$networkTree.Find({param($node) $node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-ceq 'Get-RcloneFailureCategory'},$true)
Invoke-Expression $categoryFunction.Extent.Text
$driveBranch=$devTree.Find({param($node) $node-is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith("if(`$Tier-contains 'Drive')")},$true)
if(-not $driveBranch){throw 'source_drive_branch_missing'}

# Execute the production Drive function and receipt catch. Every dependency is
# replaced in memory; no real remote, payload, configuration or file is touched.
function Get-BackupExecutable {return 'X:\synthetic\rclone.exe'}
function Initialize-BackupNetwork {return [pscustomobject]@{Success=$true}}
function Resolve-ConfiguredRcloneRemote {return [pscustomobject]@{Success=$true;Remote='synthetic:'}}
function Invoke-RcloneDrivePreflight {return [pscustomobject]@{Success=$true}}
function Get-DriveUploadState {return $null}
function Test-DriveUploadSkipEligibility {return [pscustomobject]@{Eligible=$false}}
function Get-BackupUtc {return '2026-10-03T00:00:00+08:00'}
function Write-BackupJsonAtomic($Path,$Value){
 [void]$script:Published.Add($Path)
 if($Path-ceq $script:SuccessPath){$script:StoredSuccess=$Value}
}
function Invoke-BackupRclone {
 param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments)
 $verb=[string]$Arguments[0];$target=[string]$Arguments[2]
 $global:LASTEXITCODE=0
 if($verb-eq 'lsf'){throw 'synthetic_retention_stop'}
 if($verb-cne 'copyto'){throw 'unexpected_mock_command'}
 [void]$script:Copies.Add($target)
 if($script:Scenario.Operation-in @('copy','package_copy') -and $target-ceq $script:FaultTarget){$global:LASTEXITCODE=$script:Scenario.Exit;return $script:Scenario.Output}
}
function Test-RcloneRemoteFileMatchesLocal($LocalPath,$RemotePath){
 [void]$script:Verifications.Add($RemotePath)
 if($script:Scenario.Operation-ceq 'verify' -and $RemotePath-ceq $script:FaultTarget){
  return [pscustomobject]@{Matches=$false;ExitCode=$script:Scenario.Exit;Reason=$script:Scenario.Reason}
 }
 return [pscustomobject]@{Matches=$true;ExitCode=0;Reason='remote_object_matches'}
}
$priorPath=$env:PATH
$GDriveRemote='synthetic:';$GDriveFolder='Backups/Synthetic';$BwLimit='4M';$Force=$false;$CloudLatestMode='ServerCopy';$KeepDrive=3
$StateDir=Join-Path $RepoRoot 'synthetic-drive-state';$runPath=Join-Path $StateDir 'devconfig-drive-last.json';$Tier=@('Drive')
$candidatePath=Join-Path $StateDir 'drive-current-candidate.json'
$script:SuccessPath=Join-Path $StateDir 'devconfig-drive-success.json'
$script:GDriveRemoteWasExplicit=$false
$pack=[pscustomobject]@{Name='devconfig-20261003-000000-00000001.zip';Zip='X:\synthetic\out\devconfig.zip';Sha=('a'*64);Receipt=[pscustomobject]@{package_bytes=7;content_sha256=('b'*64);file_warnings=@()}}
$scenarios=@(
 @{Operation='package_copy';Kind='dated';Suffix='';Exit=5;Mode='ServerCopy';Output='ERROR failed: context deadline exceeded SECRET_PAYLOAD synthetic:Backups/Synthetic';Category='timeout'},
 @{Operation='package_copy';Kind='latest';Suffix='';Exit=7;Mode='ServerCopy';Output='ERROR failed: invalid_grant SECRET_PAYLOAD https://example.invalid?token=PRIVATE_TOKEN';Category='oauth_auth'},
 @{Operation='package_copy';Kind='latest';Suffix='';Exit=3;Mode='Upload';Output='ERROR failed: 403 rate limit exceeded SECRET_PAYLOAD X:\private\payload';Category='rate_limit'},
 @{Operation='package_copy';Kind='latest';Suffix='';Exit=5;Mode='ServerCopy';Output='ERROR failed: tls handshake SECRET_PAYLOAD';Category='network'},
 @{Operation='package_copy';Kind='latest';Suffix='';Exit=9;Mode='ServerCopy';Output='ERROR failed: unclassified SECRET_PAYLOAD';Category='unknown'},
 @{Operation='copy';Kind='dated';Suffix='.sha256';Exit=5;Reason='copy_failed'},
 @{Operation='verify';Kind='dated';Suffix='.sha256';Exit=3;Reason='remote_object_query_failed'},
 @{Operation='verify';Kind='latest';Suffix='.manifest.json';Exit=0;Reason='remote_object_missing_or_mismatch'},
 @{Operation='verify';Kind='dated';Suffix='.receipt.json';Exit=0;Reason='remote_object_hash_unavailable'},
 @{Operation='verify';Kind='dated';Suffix='.receipt.json';Exit=-1;Reason='secret arbitrary remote path'},
 @{Operation='success';Kind='latest';Suffix='.sha256';Exit=0;Reason='remote_object_matches'}
)
try{
 foreach($scenario in $scenarios){
  $script:Scenario=$scenario
  $CloudLatestMode=if($scenario.Mode){$scenario.Mode}else{'ServerCopy'}
  $remoteName=if($scenario.Kind-ceq 'dated'){$pack.Name}else{'latest.zip'}
  $script:FaultTarget='synthetic:Backups/Synthetic/'+$remoteName+$scenario.Suffix
  $script:Copies=[Collections.Generic.List[string]]::new();$script:Verifications=[Collections.Generic.List[string]]::new();$script:Published=[Collections.Generic.List[string]]::new()
  $script:PriorSuccess=[pscustomobject]@{schema='devconfig.package-current.v2';status='complete';package_name='previous-verified.zip'}
  $script:StoredSuccess=$script:PriorSuccess
  $script:run=[ordered]@{drive='not_requested';failure=$null};$script:overallExitCode=0
  Invoke-Expression $driveBranch.Extent.Text
  Assert-Condition ($run.drive-ceq 'failed' -and $script:overallExitCode-eq 1) 'Every genuine failure must retain failed Drive and nonzero task exit.'
  Assert-Condition ([object]::ReferenceEquals($script:StoredSuccess,$script:PriorSuccess)) 'A later failed run must preserve the previous successful cloud receipt.'
  Assert-Condition ($script:Published -notcontains $script:SuccessPath -and $script:Published -notcontains (Join-Path $StateDir 'last-uploaded.json')) 'A later failure must not advance cloud success or upload-cache state.'
  if($scenario.Operation-ceq 'success'){
   Assert-Condition ($run.failure-ceq 'synthetic_retention_stop' -and -not $run.Contains('drive_diagnostic')) 'Successful metadata checks must not invent a diagnostic.'
   Assert-Condition ($script:Verifications.Count-eq 9) 'Both ZIPs, all six metadata objects and the current pointer must still be checked.'
   Assert-Condition ($script:Published -contains $candidatePath) 'Current publication is reached only after every metadata verification passes.'
   continue
  }
  $diagnostic=$run.drive_diagnostic
  if($scenario.Operation-ceq 'package_copy'){
   $expectedFailure=if($scenario.Kind-ceq 'dated'){'drive_dated_upload_failed'}else{'drive_latest_upload_failed'}
   $expectedMode=if($scenario.Kind-ceq 'dated'){'Upload'}else{$scenario.Mode}
   Assert-Condition ($run.failure-ceq $expectedFailure) 'ZIP transfer failure must retain the compatible public failure code.'
   Assert-Condition ($run.failure_stage-ceq 'drive_package_copy' -and $diagnostic.stage-ceq 'drive_package_copy') 'ZIP failure must retain its transfer stage.'
   Assert-Condition ($diagnostic.object_kind-ceq $scenario.Kind -and $diagnostic.suffix-ceq '.zip' -and $diagnostic.native_exit-eq $scenario.Exit -and $diagnostic.native_exit-is [int] -and $diagnostic.transfer_mode-ceq $expectedMode -and $diagnostic.reason-ceq 'copy_failed') 'ZIP failure must retain exact native exit, object category and transfer mode.'
   Assert-Condition ($diagnostic.category-ceq $scenario.Category) 'ZIP failure must retain the existing classifier result from the failed provider output.'
   Assert-Condition ($script:Verifications.Count-eq 0 -and $script:Published -notcontains $candidatePath) 'Failed ZIP transfer must not verify a different object or publish current.'
   Assert-Condition ($script:Copies.Count-eq $(if($scenario.Kind-ceq 'dated'){1}else{2})) 'A failed ZIP copy must stop before subsequent copies.'
   Assert-Condition (($diagnostic|ConvertTo-Json -Compress) -notmatch 'synthetic:|Backups/|X:|previous-verified|SECRET_PAYLOAD|PRIVATE_TOKEN|https:') 'ZIP diagnostics must contain no provider output, paths, remote identifiers or stored payload.'
   continue
  }
  Assert-Condition ($run.failure-ceq 'drive_portable_metadata_verification_failed') 'The existing public failure code must remain compatible.'
  $expectedStage=if($scenario.Operation-ceq 'copy'){'drive_portable_metadata_copy'}else{'drive_portable_metadata_verify'}
  Assert-Condition ($run.failure_stage-ceq $expectedStage -and $diagnostic.stage-ceq $expectedStage) 'The production catch must persist copy versus verification stage.'
  Assert-Condition ($diagnostic.object_kind-ceq $scenario.Kind -and $diagnostic.suffix-ceq $scenario.Suffix -and $diagnostic.native_exit-eq $scenario.Exit) 'The failed exact object category and native exit must survive receipt handling.'
  $expectedReason=if($scenario.Reason-ceq 'secret arbitrary remote path'){'verification_result_unavailable'}else{$scenario.Reason}
  Assert-Condition ($diagnostic.reason-ceq $expectedReason) 'Only fixed safe diagnostic categories may be persisted.'
  Assert-Condition ($diagnostic.native_exit-is [int]) 'The native code must be an integer.'
  Assert-Condition ($script:Published -notcontains $candidatePath) 'Failed metadata must not publish or advance the current pointer.'
  if($scenario.Operation-ceq 'copy'){Assert-Condition ($script:Verifications -notcontains $script:FaultTarget) 'A failed upload must not be disguised by later verification.'}
 }
 Write-Host 'PASS: eleven in-memory Drive scenarios preserve failure, provider category, native exit, previous success, checksum verification and publication ordering.'
}finally{$env:PATH=$priorPath}
