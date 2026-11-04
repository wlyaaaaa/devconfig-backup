[CmdletBinding()]
param([string]$RepoRoot='')
$ErrorActionPreference='Stop'
if(-not $RepoRoot){$RepoRoot=Split-Path -Parent $PSScriptRoot}
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Load-Functions([string]$Path,[string[]]$Names){
 $tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'source_parse_failed'}
 foreach($name in $Names){$node=$tree.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $name},$true);if(-not $node){throw ('source_function_missing:'+ $name)};. ([scriptblock]::Create($node.Extent.Text))}
 return $tree
}
# Extract production functions/catch; all dependencies below stay in memory.
$tree=Load-Functions (Join-Path $RepoRoot 'Backup-WeChat.ps1') @()
foreach($name in @('Invoke-WeChatDriveRclone','Invoke-WeChatDrivePublication')){
 $node=$tree.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $name},$true);. ([scriptblock]::Create($node.Extent.Text))
}
foreach($entry in @(@('Backup.Common.ps1','Get-BackupFailureCode'),@('Initialize-BackupNetwork.ps1','Get-RcloneFailureCategory'),@('Initialize-BackupNetwork.ps1','ConvertTo-RcloneSafeDiagnostic'),@('Run-History.Common.ps1','Get-BackupHistoryDriveDiagnostic'))){
 $t=Load-Functions (Join-Path $RepoRoot $entry[0]) @();$n=$t.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $entry[1]},$true);. ([scriptblock]::Create($n.Extent.Text))
}
$mainTry=@($tree.EndBlock.Statements|Where-Object{$_-is [Management.Automation.Language.TryStatementAst]})[-1]
$catchText=$mainTry.CatchClauses[0].Body.Extent.Text;$catchBlock=[scriptblock]::Create($catchText.Substring(1,$catchText.Length-2))
function Invoke-RcloneDrivePreflight {return [pscustomobject]@{Success=$true}}
function Get-WeChatCloudFilter {return @('--filter','- excluded/**')}
function Get-BackupStableFileHash {return 'synthetic-manifest'}
function Get-WeChatSummary {return [ordered]@{destination='must be removed';scope='full_native_data'}}
function Get-BackupTextHash {return 'synthetic-binding'}
function Test-RcloneRemoteFileMatchesLocal {return [pscustomobject]@{Matches=$true}}
function Write-BackupJsonAtomic($Path,$Value){if($script:FailDiagnosticWrite -and $Path.EndsWith('wechat-drive-failure-diagnostic.json')){throw 'synthetic diagnostic write failure'};$script:Published[$Path]=$Value}
function Invoke-BackupRclone {
 param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments)
 $script:Calls.Add(@($Arguments));$global:LASTEXITCODE=0
 if($script:Calls.Count-eq $script:FaultCall){$global:LASTEXITCODE=$script:NativeExit;return $script:ProviderOutput}
}
$HotRoot='E:\synthetic\hot';$StateRoot='E:\synthetic\state';$BwLimit='4M';$MaxTransfer='8G';$DbOnly=$false;$DriveFull=$false;$GDriveFolder='Backups/Synthetic'
$upload=[pscustomobject]@{hot_manifest_sha256='synthetic-manifest';hot_capture_consistency='vss_crash_consistent'}
$stages=@('wechat_drive_copy','wechat_drive_preprune_check','wechat_drive_sync','wechat_drive_final_check')
$failures=@('wechat_drive_copy_failed','wechat_drive_preprune_verification_failed','wechat_drive_convergence_failed','wechat_drive_final_verification_failed')
$cases=@(
 @{Call=1;Exit=5;Output='ERROR context deadline exceeded token=PRIVATE_TOKEN';Category='timeout'},
 @{Call=2;Exit=7;Output='ERROR invalid_grant password=PRIVATE_PASSWORD';Category='oauth_auth'},
 @{Call=3;Exit=3;Output='ERROR 429 rate limit exceeded https://synthetic.invalid?token=PRIVATE_TOKEN';Category='rate_limit'},
 @{Call=4;Exit=1;Output=('ERROR synthetic/path/file.bin: mismatched checksum '+('x'*400)+' token=PRIVATE_TOKEN');Category='unknown'},
 @{Call=4;Exit=5;Output='ERROR TLS handshake failed Authorization: Bearer PRIVATE_BEARER';Category='network'}
)
foreach($case in $cases){
 $script:FaultCall=$case.Call;$script:NativeExit=$case.Exit;$script:ProviderOutput=$case.Output;$script:Calls=[Collections.Generic.List[object]]::new();$script:Published=@{}
 $run=[ordered]@{run_id='synthetic-run';status='running';hot='not_requested';local='not_requested';drive='running'};$code=0
 try{$null=Invoke-WeChatDrivePublication ([pscustomobject]@{}) $upload 'synthetic:Backups/Synthetic'}catch{. $catchBlock}
 Check ($code-eq 1 -and $run.status-ceq 'failed' -and $run.drive-ceq 'failed' -and $run.failure-ceq $failures[$case.Call-1]) 'A native failure must remain a real failed run with its original public failure code.'
 Check ($script:Calls.Count-eq $case.Call) 'A failed stage must stop before later mutation or verification.'
 $diagnostic=$run.drive_diagnostic
 Check ($diagnostic.stage-ceq $stages[$case.Call-1] -and $diagnostic.native_exit-eq $case.Exit -and $diagnostic.category-ceq $case.Category) 'Stage, exact native exit and provider category must survive the production catch.'
 Check (-not $script:Published.ContainsKey((Join-Path $StateRoot 'wechat-drive-success.json'))) 'A failure must preserve the previous successful receipt.'
 $local=$script:Published[(Join-Path $StateRoot 'wechat-drive-failure-diagnostic.json')]
 Check ($local.run_id-ceq $run.run_id -and $local.detail.Length-le 240 -and $local.detail-notmatch 'PRIVATE_TOKEN|PRIVATE_PASSWORD|PRIVATE_BEARER') 'Local diagnostic text must be bounded, secret-filtered and tied to the failed run.'
 Check ($run.drive_diagnostic_file-ceq 'wechat-drive-failure-diagnostic.json') 'The run must reference the bounded local diagnostic artifact.'
 $history=Get-BackupHistoryDriveDiagnostic $diagnostic;$json=$history|ConvertTo-Json -Compress
 Check ($history.stage-ceq $diagnostic.stage -and $history.native_exit-eq $case.Exit -and $history.category-ceq $case.Category -and $json-notmatch 'synthetic/path|file.bin|PRIVATE_|detail') 'Run history must retain only fixed diagnostic fields, never provider text or payload filenames.'
 Check (($run|ConvertTo-Json -Depth 6 -Compress)-notmatch 'PRIVATE_|synthetic/path|mismatched checksum') 'Status output must not contain the local provider diagnostic body.'
}
$script:FailDiagnosticWrite=$true;$script:FaultCall=4;$script:NativeExit=5;$script:ProviderOutput='ERROR context deadline exceeded';$script:Calls=[Collections.Generic.List[object]]::new();$script:Published=@{}
$run=[ordered]@{run_id='synthetic-run';status='running';hot='not_requested';local='not_requested';drive='running'};$code=0
try{$null=Invoke-WeChatDrivePublication ([pscustomobject]@{}) $upload 'synthetic:Backups/Synthetic'}catch{. $catchBlock}
Check ($code-eq 1 -and $run.failure-ceq 'wechat_drive_final_verification_failed' -and $run.drive_diagnostic_status-ceq 'write_failed' -and $run.drive_diagnostic.native_exit-eq 5 -and -not $run.Contains('drive_diagnostic_file')) 'Local diagnostic publication failure must preserve the real cloud failure and report the evidence gap.'
$script:FailDiagnosticWrite=$false
$script:FaultCall=0;$script:Calls=[Collections.Generic.List[object]]::new();$script:Published=@{}
$null=Invoke-WeChatDrivePublication ([pscustomobject]@{}) $upload 'synthetic:Backups/Synthetic'
Check ($script:Published.ContainsKey((Join-Path $StateRoot 'wechat-drive-success.json')) -and $script:Calls.Count-eq 5) 'Successful copy/check/sync/check/manifest-copy must still publish cloud success.'
Check ($script:Calls[0][0]-ceq 'copy' -and $script:Calls[1]-contains '--one-way' -and $script:Calls[2]-contains '--delete-after' -and $script:Calls[3]-notcontains '--one-way' -and $script:Calls[4][0]-ceq 'copyto') 'Cloud operations and preprune/final check semantics must remain unchanged.'
$invalid=Get-BackupHistoryDriveDiagnostic ([pscustomobject]@{stage='wechat_drive_final_check';native_exit=1;category='arbitrary provider text'})
Check ($null-eq $invalid) 'History must reject nonfixed provider categories.'
Write-Host 'PASS: five in-memory WeChat Drive failures, local evidence write failure and successful publication retain native diagnostics, secret filtering, bounded local evidence and safe history.'
