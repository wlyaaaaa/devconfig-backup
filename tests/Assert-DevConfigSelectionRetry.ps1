[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
. (Join-Path $repo 'DevConfig.Sources.ps1')
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\');$fixture=Join-Path $parent ('devconfig-selection-'+[guid]::NewGuid().ToString('N'))
$script:checks=0;$oldRcloneConfig=$env:RCLONE_CONFIG
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw ('FAIL: '+$Name)};$script:checks++;Write-Host ('PASS: '+($Name -split ': \{')[0])}
function Put([string]$Path,[string]$Text){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text)}
function Run([string]$Path,[string[]]$Arguments){$runtime=(Get-Process -Id $PID).Path;$old=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$text=(& $runtime -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1|Out-String);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old};return [pscustomobject]@{Exit=$code;Text=$text}}
function New-MutatingEntrypoint([string]$Mode){
 $text=[IO.File]::ReadAllText((Join-Path $repo 'Backup-DevConfig.ps1')).Replace('$PSScriptRoot',("'"+$repo.Replace("'","''")+"'"))
 $inject=@'
$script:CaptureCopies=0
$script:OriginalCaptureCopy=(Get-Command Copy-DevConfigSourceInventory).ScriptBlock
function Copy-DevConfigSourceInventory($Inventory,[string]$Destination){
 & $script:OriginalCaptureCopy $Inventory $Destination
 $script:CaptureCopies++
 if('__MODE__'-eq 'continuous' -or $script:CaptureCopies-eq 1){
  $path=Join-Path $ProfileRoot ('settings/__MODE__-late-'+$script:CaptureCopies+'.txt')
  [IO.File]::WriteAllText($path,'new selected configuration')
 }
}
'@
 $text=$text.Replace('$script:GDriveRemoteWasExplicit=',$inject.Replace('__MODE__',$Mode)+"`n"+'$script:GDriveRemoteWasExplicit=')
 $path=Join-Path $fixture ('mutating-'+$Mode+'.ps1');[IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($true));return $path
}
try{
 [void][IO.Directory]::CreateDirectory($fixture)
 $cfg=@{HomeDirs=@('settings');RequiredSources=@('home/settings')}
 foreach($mode in @('add','remove')){
  $profile=Join-Path $fixture ($mode+'-profile');Put (Join-Path $profile 'settings/keep.txt') 'keep';Put (Join-Path $profile 'settings/old.txt') 'old'
  $script:round=0;$script:profile=$profile;$script:mode=$mode;$script:moved=Join-Path $fixture 'removed-source.txt'
  $change={param($stage)$script:round++;if($script:round-eq 1){if($script:mode-eq 'add'){Put (Join-Path $script:profile 'settings/new.txt') 'new'}else{[IO.File]::Move((Join-Path $script:profile 'settings/old.txt'),$script:moved)}}}
  $result=Invoke-DevConfigSourceCapture $cfg $profile (Join-Path $fixture ($mode+'-capture')) -PostCapture $change
  Check ($result.attempt_count-eq 2 -and $result.retry_history.Count-eq 1 -and $result.retry_history[0].stage-ceq 'selection_recheck') ($mode+' stabilizes after one fresh full recapture')
  Check ($result.stage.EndsWith('payload-2') -and [IO.File]::Exists((Join-Path $result.stage 'home/settings/keep.txt'))) ($mode+' uses an independent new candidate')
  if($mode-eq 'add'){Check ([IO.File]::Exists((Join-Path $result.stage 'home/settings/new.txt'))) 'New selected real configuration is captured'}else{
   Check (-not [IO.File]::Exists((Join-Path $result.stage 'home/settings/old.txt')) -and $result.inventory.file_warnings[0].reason-ceq 'source_disappeared') 'Stable removal has no stale candidate bytes and protects the old package this run'
  }
 }
 $profile=Join-Path $fixture 'always-profile';Put (Join-Path $profile 'settings/keep.txt') 'keep';$script:round=0;$script:profile=$profile
 $always={param($stage)$script:round++;Put (Join-Path $script:profile ('settings/new-'+$script:round+'.txt')) 'new'}
 $failure=$null;try{$null=Invoke-DevConfigSourceCapture $cfg $profile (Join-Path $fixture 'always-capture') -PostCapture $always}catch{$failure=$_}
 Check ($failure.Exception.Message-ceq 'backup_source_selection_changed_during_collection' -and $failure.Exception.Data['backup_capture_attempt_count']-eq 3) 'Continuously changing selection fails after the default three rounds'
 Check (@($failure.Exception.Data['backup_capture_retry_history']).Count-eq 3 -and $failure.Exception.Data['backup_stage']-ceq 'selection_recheck') 'Exhausted recapture has bounded stage and count metadata'
 $profile=Join-Path $fixture 'live-profile';Put (Join-Path $profile 'settings/keep.txt') 'captured';$script:profile=$profile
 $live={param($stage)Put (Join-Path $script:profile 'settings/keep.txt') 'changed later by live app'}
 $result=Invoke-DevConfigSourceCapture $cfg $profile (Join-Path $fixture 'live-capture') -PostCapture $live
 Check ($result.attempt_count-eq 1 -and $result.changed_after_capture_count-eq 1 -and [IO.File]::ReadAllText((Join-Path $result.stage 'home/settings/keep.txt'))-ceq 'captured') 'Same-path post-capture modification retains verified per-file snapshot semantics'
 $missing=$false;try{$null=Invoke-DevConfigSourceCapture $cfg (Join-Path $fixture 'missing-profile') (Join-Path $fixture 'missing-capture')}catch{$missing=$true}
 Check $missing 'Missing source remains fatal'

 # Real entrypoint: fail-stable selection publishes; exhaustion preserves Local and G pointers.
 $profile=Join-Path $fixture 'entry-profile';$output=Join-Path $fixture 'entry-output';$hot=Join-Path $fixture 'entry-hot';$sources=Join-Path $fixture 'sources.psd1'
 Put (Join-Path $profile 'settings/keep.txt') 'real configuration';Put $sources "@{HomeDirs=@('settings');RequiredSources=@('home/settings')}"
 $base=@('-ProfileRoot',$profile,'-SourcesFile',$sources,'-OutputRoot',$output,'-HotRoot',$hot,'-SkipSystemExport','-Tier','Local,Hot','-Json')
 $run=Run (Join-Path $repo 'Backup-DevConfig.ps1') $base;Check ($run.Exit-eq 0) ('Initial synthetic entrypoint succeeds: '+$run.Text)
 $run=Run (New-MutatingEntrypoint 'once') $base;$record=Read-BackupJson (Join-Path $output 'state/devconfig-local-last.json')
 Check ($run.Exit-eq 0 -and $record.status-ceq 'complete' -and $record.capture_attempt_count-eq 2 -and $record.capture_retry_history[0].added_count-ge 1) ('One transient selection change publishes after recapture: '+$run.Text)
 $localPointer=Get-BackupStableFileHash (Join-Path $output 'out/current.json');$hotPointer=Get-BackupStableFileHash (Join-Path $hot 'current.json')
 $run=Run (New-MutatingEntrypoint 'continuous') $base;$record=Read-BackupJson (Join-Path $output 'state/devconfig-local-last.json')
 Check ($run.Exit-ne 0 -and $record.status-ceq 'failed' -and $record.capture_attempt_count-eq 3 -and $record.failure_stage-ceq 'selection_recheck') 'Persistent real configuration selection change fails visibly'
 Check ((Get-BackupStableFileHash (Join-Path $output 'out/current.json'))-ceq $localPointer -and (Get-BackupStableFileHash (Join-Path $hot 'current.json'))-ceq $hotPointer) 'Exhaustion does not publish or change either previous success pointer'

 # Current sources selection, on fake data only: exact runtime exclusions preserve useful configuration.
 $profile=Join-Path $fixture 'scope-profile';$current=Import-PowerShellDataFile (Join-Path $repo 'sources.psd1');$current.ExtraDirs=@()
 foreach($path in @('.codex/config.toml','.codex/memories/extensions/s/SKILL.md','.claude/settings.json','.claude/skills/s/SKILL.md','.claude/agents/a.md','.claude/commands/c.md','.claude/plans/p.md','.claude/dependency.lock','.claude/file-history-backup/settings.json','.gemini/settings.json','.gemini/antigravity/antigravity_state.pbtxt','.config/opencode/opencode.jsonc')){Put (Join-Path $profile $path) 'configuration'}
 foreach($dir in @('file-history','debug','paste-cache','image-cache','session-env','shell-snapshots','usage-data')){Put (Join-Path $profile ('.claude/'+$dir+'/session/example.txt')) 'ephemeral'}
 foreach($history in @($false,$true)){
  $inventory=Get-DevConfigSourceInventory $current $profile -IncludeHistory:$history;$paths=@($inventory.files.relative_path)
  Check (@($paths|Where-Object{$_-match '^home/\.claude/(file-history|debug|paste-cache|image-cache|session-env|shell-snapshots|usage-data)/'}).Count-eq 0) ('Exact volatile subtrees are excluded; IncludeHistory='+$history)
  foreach($path in @('home/.claude/settings.json','home/.claude/skills/s/SKILL.md','home/.claude/agents/a.md','home/.claude/commands/c.md','home/.claude/plans/p.md','home/.claude/dependency.lock','home/.claude/file-history-backup/settings.json','home/.codex/config.toml')){Check ($path-in $paths) ('Useful selected configuration remains: '+$path)}
 }
 Check ('*.lock'-notin $current.ExcludeFiles -and 'home/.claude'-in $current.RequiredSources) 'No global lock exclusion or required-source weakening'
 $oldAv=[pscustomobject]@{files=@();file_warnings=@([pscustomobject]@{relative_path='home/.claude/file-history/session/missing.txt';reason='antivirus_blocked';error_code=225;stage='hash'})}
 Check (@((Get-DevConfigSourceInventory $current $profile -KnownInventory $oldAv).file_warnings).Count-eq 0) 'A prior antivirus warning inside a now-excluded subtree does not keep that retired scope alive'

 # Only local synthetic rclone trees: warning metacharacters must not act as glob syntax.
 $env:RCLONE_CONFIG=Join-Path $fixture 'empty-rclone.conf';Put $env:RCLONE_CONFIG ''
 $src=Join-Path $fixture 'filter-source';$dst=Join-Path $fixture 'filter-target'
 $bad=@('bad[1].txt','bad{a,b}.txt','double{{x}}.txt','folder[1]/bad.txt','braces{a,b}/bad.txt','space [1].txt')
 $good=@('bad1.txt','bada.txt','badb.txt','doublex.txt','folder1/bad.txt','bracesa/bad.txt','space 1.txt','bad[1].txt.other','healthy.txt')
 foreach($path in $bad){Put (Join-Path $src $path) 'bad'};foreach($path in $good){Put (Join-Path $src $path) 'good';Put (Join-Path $dst $path) 'good'}
 $warnings=@($bad|ForEach-Object{[pscustomobject]@{relative_path=$_;reason='antivirus_blocked';error_code=225;stage='copy'}});$filters=@(Get-BackupRcloneWarningFilters $warnings)
 $listed=@(Invoke-BackupRclone lsf $src -R --files-only @filters);Check ($LASTEXITCODE-eq 0 -and (($listed|Sort-Object)-join '|')-ceq (($good|Sort-Object)-join '|')) 'Literal rclone warnings exclude only their exact paths and preserve the healthy list'
 $old=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=Invoke-BackupRclone check $src $dst @filters 2>&1;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 Check ($code-eq 0) 'Full healthy rclone check passes despite missing warned objects'
 Put (Join-Path $dst 'bad1.txt') 'different'
 $old=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=Invoke-BackupRclone check $src $dst @filters 2>&1;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 Check ($code-ne 0) 'A healthy name resembling a warning glob is still checked and mismatched bytes fail'
 Write-Output ('RESULT: '+$script:checks+' selection retry and literal-filter checks passed; runtime='+$PSVersionTable.PSVersion)
}finally{
 $env:RCLONE_CONFIG=$oldRcloneConfig
 if([IO.Directory]::Exists($fixture)){$result=& pwsh -NoProfile -ExecutionPolicy Bypass -File 'E:\.agents\tools\Move-TaskItemToRecycleBin.ps1' -LiteralPath $fixture -AllowedRoot $parent -Json|ConvertFrom-Json;if($result.status-ne 'recycled' -or -not $result.original_path_verified -or -not $result.recovery_item_exists){throw 'fixture_recycle_failed'}}
}
