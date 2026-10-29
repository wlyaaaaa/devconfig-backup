[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixture=Join-Path $parent ('devconfig-sqlite-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try{
 $python=Get-BackupExecutable python
 & $python -I -B (Join-Path $PSScriptRoot 'devconfig_sqlite_capture.test.py') --repo $repo --fixture $fixture --powershell (Get-Process -Id $PID).Path
 if($LASTEXITCODE-ne 0){throw 'devconfig_sqlite_capture_test_failed'}
 # Exercise the real timeout failure path with only its test wait shortened.
 $source=Get-Content -LiteralPath (Join-Path $repo 'DevConfig.Sources.ps1') -Raw
 if(-not $source.Contains('WaitForExit(($captureTimeoutSeconds+5)*1000)')){throw 'sqlite_production_timeout_changed'}
 $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Copy-DevConfigSQLiteDatabase'},$false)
 Invoke-Expression ($function.Extent.Text.Replace('WaitForExit(($captureTimeoutSeconds+5)*1000)','WaitForExit(1500)'))
 $script:DevConfigSQLiteHelper=Join-Path $fixture 'delayed-helper.py'
 [IO.File]::WriteAllText($script:DevConfigSQLiteHelper,@'
import json,sys,time
print('untrusted private-looking text',file=sys.stderr,flush=True)
print(json.dumps({'schema':'devconfig.sqlite-stage.v1','stage':'source_read'}),file=sys.stderr,flush=True)
print(json.dumps({'schema':'devconfig.sqlite-stage.v1','stage':'integrity_check','payload':'reject'}),file=sys.stderr,flush=True)
print(json.dumps({'schema':'devconfig.sqlite-stage.v1','stage':'untrusted-stage'}),file=sys.stderr,flush=True)
time.sleep(10)
'@,[Text.Encoding]::UTF8)
 $failure=$null
 try{Copy-DevConfigSQLiteDatabase (Join-Path $fixture 'synthetic.sqlite') (Join-Path $fixture 'must-not-publish.sqlite') $fixture}
 catch{$failure=$_.Exception}
 if(-not $failure -or $failure.Message-ne 'backup_sqlite_capture_failed'){throw 'sqlite_timeout_did_not_fail'}
 $diagnostic=$failure.Data['backup_sqlite_diagnostic']
 if($diagnostic.reason-ne 'timeout' -or $diagnostic.stage-ne 'source_read' -or $diagnostic.native_exit-eq 0){throw 'sqlite_timeout_last_safe_stage_missing'}
 if(($diagnostic|ConvertTo-Json -Compress)-match 'untrusted|payload|reject'){throw 'sqlite_stderr_payload_leaked'}
 if(Test-Path -LiteralPath (Join-Path $fixture 'must-not-publish.sqlite')){throw 'sqlite_timeout_published_output'}
 Write-Output 'PASS: Outer timeout retains only the last valid safe stage and remains failed'
}finally{Remove-BackupOwnedDirectory $fixture $parent '^devconfig-sqlite-[a-f0-9]{32}$'}
