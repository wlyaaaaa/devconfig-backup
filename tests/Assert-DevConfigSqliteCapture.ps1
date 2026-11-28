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
 if(-not $source.Contains('$idleTimeoutMs=125000') -or -not $source.Contains('$captureTimeoutSeconds=1800')){throw 'sqlite_production_timeout_changed'}
 $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Copy-DevConfigSQLiteDatabase'},$false)
 Invoke-Expression ($function.Extent.Text.Replace('$idleTimeoutMs=125000','$idleTimeoutMs=2000'))
 $script:DevConfigSQLiteHelper=Join-Path $fixture 'delayed-helper.py'
 [IO.File]::WriteAllText($script:DevConfigSQLiteHelper,@'
import json,sqlite3,sys,time
if sys.argv[1].endswith('large-priority.sqlite'):
    import ctypes
    budget = int(sys.argv[sys.argv.index('--timeout') + 1])
    assert 1800 < budget <= 2400, budget
    kernel = ctypes.windll.kernel32
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    kernel.GetPriorityClass.argtypes = [ctypes.c_void_p]
    for _ in range(80):
        if kernel.GetPriorityClass(kernel.GetCurrentProcess()) == 32:
            break
        time.sleep(0.02)
    else:
        raise RuntimeError('helper_not_at_normal_priority')
    with sqlite3.connect(sys.argv[2]) as db:
        db.execute('CREATE TABLE fixture(a)')
    print(json.dumps({'status':'complete','method':'sqlite_online_backup','integrity_check':'ok'}))
    sys.exit(0)
if sys.argv[1].endswith('progressing.sqlite'):
    print(json.dumps({'schema':'devconfig.sqlite-stage.v1','stage':'online_backup'}),file=sys.stderr,flush=True)
    for step in range(1,7):
        print(json.dumps({'schema':'devconfig.sqlite-progress.v1','step_count':step,'sqlite_status':0,'remaining_pages':10-step,'total_pages':10,'elapsed_ms':450*(step-1)}),file=sys.stderr,flush=True)
        time.sleep(0.45)
    for stage in ('standalone_mode', 'integrity_check'):
        print(json.dumps({'schema':'devconfig.sqlite-stage.v1','stage':stage}),file=sys.stderr,flush=True)
    time.sleep(2.25)
    with sqlite3.connect(sys.argv[2]) as db:
        db.execute('CREATE TABLE fixture(a)')
    print(json.dumps({'status':'complete','method':'sqlite_online_backup','integrity_check':'ok'}))
    sys.exit(0)
print('untrusted private-looking text',file=sys.stderr,flush=True)
print(json.dumps({'schema':'devconfig.sqlite-stage.v1','stage':'online_backup'}),file=sys.stderr,flush=True)
print(json.dumps({'schema':'devconfig.sqlite-stage.v1','stage':'integrity_check','payload':'reject'}),file=sys.stderr,flush=True)
print(json.dumps({'schema':'devconfig.sqlite-stage.v1','stage':'untrusted-stage'}),file=sys.stderr,flush=True)
progress={'schema':'devconfig.sqlite-progress.v1','step_count':2,'sqlite_status':0,'remaining_pages':100,'total_pages':612,'elapsed_ms':500}
print(json.dumps(progress),file=sys.stderr,flush=True)
print(json.dumps(dict(progress,payload='reject')),file=sys.stderr,flush=True)
print(json.dumps(dict(progress,remaining_pages='untrusted')),file=sys.stderr,flush=True)
print(json.dumps(dict(progress,remaining_pages=900)),file=sys.stderr,flush=True)
# More than the OS pipe capacity must drain while the child is still running.
print('x'*200000,file=sys.stderr,flush=True)
print('x'*200000,file=sys.stdout,flush=True)
print(json.dumps(dict(progress,step_count=3,remaining_pages=50,elapsed_ms=600)),file=sys.stderr,flush=True)
print(json.dumps(dict(progress,remaining_pages=-1)),file=sys.stderr,flush=True)
for step in range(4,12):
    time.sleep(0.45)
    print(json.dumps(dict(progress,step_count=step,remaining_pages=50,elapsed_ms=600+450*(step-3))),file=sys.stderr,flush=True)
sys.exit(0)
'@,[Text.Encoding]::UTF8)
 $failure=$null
 try{Copy-DevConfigSQLiteDatabase (Join-Path $fixture 'synthetic.sqlite') (Join-Path $fixture 'must-not-publish.sqlite') $fixture}
 catch{$failure=$_.Exception}
 if(-not $failure -or $failure.Message-ne 'backup_sqlite_capture_failed'){throw 'sqlite_timeout_did_not_fail'}
 $diagnostic=$failure.Data['backup_sqlite_diagnostic']
 if($diagnostic.reason-ne 'timeout' -or $diagnostic.stage-ne 'online_backup' -or $diagnostic.native_exit-eq 0){throw 'sqlite_timeout_last_safe_stage_missing'}
 if($diagnostic.backup_progress.step_count-lt 3 -or $diagnostic.backup_progress.remaining_pages-ne 50 -or $diagnostic.backup_progress.total_pages-ne 612 -or $diagnostic.backup_progress.elapsed_ms-lt 600){throw 'sqlite_timeout_last_safe_progress_missing'}
 if(($diagnostic|ConvertTo-Json -Compress)-match 'untrusted|payload|reject'){throw 'sqlite_stderr_payload_leaked'}
 if(Test-Path -LiteralPath (Join-Path $fixture 'must-not-publish.sqlite')){throw 'sqlite_timeout_published_output'}
 Write-Output 'PASS: Outer timeout retains only the last valid safe stage and remains failed'
 $verified=Join-Path $fixture 'published.sqlite'
 $hash=Copy-DevConfigSQLiteDatabase (Join-Path $fixture 'progressing.sqlite') $verified $fixture
 if($hash-cne (Get-BackupStableFileHash $verified)){throw 'sqlite_integrity_check_did_not_publish'}
 Write-Output 'PASS: Advancing backup and quiet integrity check both finish past the idle timeout'
 Start-BackupRunBudget 1
 try{Copy-DevConfigSQLiteDatabase (Join-Path $fixture 'progressing.sqlite') $verified $fixture;throw 'sqlite_exceeded_run_budget'}
 catch{if($_.Exception.Message-cne 'backup_run_budget_exhausted'){throw}}
 finally{Start-BackupRunBudget 0}
 if((Get-BackupStableFileHash $verified)-cne $hash){throw 'sqlite_budget_changed_verified_copy'}
 Write-Output 'PASS: SQLite uses the remaining business budget and retains the prior verified file'
 $large=Join-Path $fixture 'large-priority.sqlite'
 $stream=[IO.File]::Create($large)
 try{$stream.SetLength(256MB)}finally{$stream.Dispose()}
 $fixtureProcess=[Diagnostics.Process]::GetCurrentProcess()
 $originalPriority=$fixtureProcess.PriorityClass
 Start-BackupRunBudget 3600
 try{
  $fixtureProcess.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
  $null=Copy-DevConfigSQLiteDatabase $large (Join-Path $fixture 'large-priority-copy.sqlite') $fixture
 }finally{$fixtureProcess.PriorityClass=$originalPriority;$fixtureProcess.Dispose();Start-BackupRunBudget 0}
 Write-Output 'PASS: Large SQLite gets spare copy time without using the 20-minute reserve, and the helper reaches Normal priority'
}finally{Remove-BackupOwnedDirectory $fixture $parent '^devconfig-sqlite-[a-f0-9]{32}$'}
