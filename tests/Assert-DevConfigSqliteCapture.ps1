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
}finally{Remove-BackupOwnedDirectory $fixture $parent '^devconfig-sqlite-[a-f0-9]{32}$'}
