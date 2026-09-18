[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
$runtime=(Get-Process -Id $PID).Path
$fixtureParent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixture=Join-Path $fixtureParent ('relative-path-test-'+[guid]::NewGuid().ToString('N'))
$oldNativeCwd=[Environment]::CurrentDirectory
try{
 $profile=Join-Path $fixture 'profile';$output=Join-Path $fixture 'output'
 [void][IO.Directory]::CreateDirectory($profile)
 [IO.File]::WriteAllText((Join-Path $profile 'setting.txt'),'synthetic relative-path restoration')
 $sources=Join-Path $fixture 'sources.psd1'
 [IO.File]::WriteAllText($sources,"@{HomeFiles=@('setting.txt');RequiredSources=@('home/setting.txt')}")
 $text=@(& $runtime -NoProfile -File (Join-Path $repo 'Backup-DevConfig.ps1') -SourcesFile $sources -ProfileRoot $profile -OutputRoot $output -SkipSystemExport -Tier Local -Json 2>&1)
 if($LASTEXITCODE-ne 0){throw 'relative_test_fixture_backup_failed'}
 Push-Location $output
 try{
  [Environment]::CurrentDirectory=$env:WINDIR
  $pack=Get-VerifiedDevConfigPackage '.\out'
  if(-not $pack.Zip.StartsWith($output,[StringComparison]::OrdinalIgnoreCase)){throw 'relative_package_resolved_against_wrong_directory'}
 }finally{[Environment]::CurrentDirectory=$oldNativeCwd;Pop-Location}
 $command="Set-Location '"+$output.Replace("'","''")+"'; [Environment]::CurrentDirectory='"+$env:WINDIR.Replace("'","''")+"'; & '"+(Join-Path $repo 'Restore-DevConfig.ps1').Replace("'","''")+"' -Archive 'out\"+$pack.Name+"' -Destination 'restored' -Execute -Json"
 $text=@(& $runtime -NoProfile -Command $command 2>&1)
 if($LASTEXITCODE-ne 0 -or [IO.File]::ReadAllText((Join-Path $output 'restored\home\setting.txt'))-cne 'synthetic relative-path restoration'){throw 'relative_restore_entry_failed'}
 Write-Output 'PASS: package lookup and actual restore use the PowerShell working directory when process cwd differs.'
}finally{
 [Environment]::CurrentDirectory=$oldNativeCwd
 Remove-BackupOwnedDirectory $fixture $fixtureParent '^relative-path-test-[a-f0-9]{32}$'
}
