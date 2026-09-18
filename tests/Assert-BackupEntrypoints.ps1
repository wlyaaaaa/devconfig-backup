[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
Set-Variable -Name FixtureParent -Scope Script -Option ReadOnly -Value ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\'))
Set-Variable -Name FixtureRoot -Scope Script -Option ReadOnly -Value (Join-Path $script:FixtureParent ('backup-entrypoints-'+[guid]::NewGuid().ToString('N')))
$runtime=(Get-Process -Id $PID).Path
function Check([bool]$Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};Write-Host ('PASS: '+$Name)}
try{
 [void][IO.Directory]::CreateDirectory($script:FixtureRoot)
 $source=Join-Path $script:FixtureRoot 'native-source';$target=Join-Path $script:FixtureRoot 'native-restored'
 [void][IO.Directory]::CreateDirectory((Join-Path $source 'account\db_storage'))
 [IO.File]::WriteAllText((Join-Path $source 'account\db_storage\fixture.bin'),'synthetic native data')
 # Override process detection only inside a temporary fixture harness. The real
 # source retains its live-client refusal and has no production bypass switch.
 $native=[IO.File]::ReadAllText((Join-Path $repo 'Restore-WeChat.ps1')).Replace('$PSScriptRoot',("'"+$repo.Replace("'","''")+"'"))
 $native=$native.Replace('function Say {',"function Get-NativeWeChatClientState { [pscustomobject]@{Detected=`$false;ProcessNames=@();ProcessIds=@()} }`nfunction Say {")
 $harness=Join-Path $script:FixtureRoot 'native-harness.ps1';[IO.File]::WriteAllText($harness,$native,[Text.UTF8Encoding]::new($false))
 $output=(& $runtime -NoProfile -ExecutionPolicy Bypass -File $harness -BackupRoot $source -Target $target -Execute 2>&1|Out-String)
 Check ($LASTEXITCODE-eq 0 -and $output-match 'COPY_COMPLETE_AWAITING_HUMAN_ACCEPTANCE') ('Native CLI fixture executes without application-recovery claim: '+$output)
 Check ((Get-BackupStableFileHash (Join-Path $target 'account\db_storage\fixture.bin'))-ceq (Get-BackupStableFileHash (Join-Path $source 'account\db_storage\fixture.bin'))) 'Native full-entry bytes match the source'
 $output=(& $runtime -NoProfile -ExecutionPolicy Bypass -File $harness -BackupRoot $source -Target $target -Execute -ReplaceExisting 2>&1|Out-String)
 Check ($LASTEXITCODE-eq 0 -and @(Get-ChildItem $script:FixtureRoot -Directory -Filter 'native-restored.pre-restore-*').Count-eq 1) 'Native replacement preserves the original directory'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Monitor-WeChatDrive.ps1'),[ref]$tokens,[ref]$errors)
 foreach($name in @('ConvertTo-BackupProcessArgument','Invoke-RcloneWithTimeout')){
  $definition=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true))
  . ([scriptblock]::Create($definition[0].Extent.Text))
 }
 $Root=$repo
 function Get-BackupExecutable {param($Name,$FallbackPath) return $runtime}
 $flood=Join-Path $script:FixtureRoot 'flood.ps1';[IO.File]::WriteAllText($flood,"[Console]::Out.Write(('o'*200000));[Console]::Error.Write(('e'*200000));exit 0")
 $result=Invoke-RcloneWithTimeout -Arguments @('-NoProfile','-File',$flood) -TimeoutSec 20
 Check ($result.ExitCode-eq 0 -and $result.Stdout.Length-eq 200000 -and $result.Stderr.Length-eq 200000) 'Monitor drains both large output pipes without deadlock'
 $sleep=Join-Path $script:FixtureRoot 'sleep.ps1';[IO.File]::WriteAllText($sleep,'Start-Sleep -Seconds 10')
 $result=Invoke-RcloneWithTimeout -Arguments @('-NoProfile','-File',$sleep) -TimeoutSec 1
 Check ($result.TimedOut -and $result.ExitCode-eq 124) 'Monitor times out its own child without killing unrelated processes'
 $ui=[IO.File]::ReadAllText((Join-Path $repo 'Backup-Status.ps1')).Replace('$PSScriptRoot',("'"+$repo.Replace("'","''")+"'"))
 $paint="`$form.CreateControl();`$form.PerformLayout();& `$update;if(`$box.Text-notmatch 'DevConfig'){throw 'panel_refresh_failed'};`$image=New-Object Drawing.Bitmap(`$form.Width,`$form.Height);try{`$form.DrawToBitmap(`$image,(New-Object Drawing.Rectangle(0,0,`$form.Width,`$form.Height)))}finally{`$image.Dispose()};Write-Output 'PANEL_PAINT_PASS'"
 $ui=$ui.Replace('[void]$form.ShowDialog()',$paint)
 $uiPath=Join-Path $script:FixtureRoot 'panel-harness.ps1';[IO.File]::WriteAllText($uiPath,$ui,[Text.UTF8Encoding]::new($true))
 $output=(& $runtime -NoProfile -ExecutionPolicy Bypass -File $uiPath -Gui -NoDrive -OutputRoot $script:FixtureRoot -HotRoot (Join-Path $script:FixtureRoot 'hot') -HotReceiptPath (Join-Path $script:FixtureRoot 'absent.json') 2>&1|Out-String)
 Check ($LASTEXITCODE-eq 0 -and $output-match 'PANEL_PAINT_PASS') ('Actual panel builds, refreshes and paints without a desktop capture: '+$output)
 Check ([IO.File]::Exists((Join-Path $repo 'Backup.Common.ps1'))) 'Source repository still exists after entrypoint work'
 Write-Output 'RESULT: 7 guarded entrypoint and panel checks passed.'
}finally{
 Remove-BackupOwnedDirectory $script:FixtureRoot $script:FixtureParent '^backup-entrypoints-[a-f0-9]{32}$'
}
