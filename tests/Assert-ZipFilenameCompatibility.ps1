[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$runtime=(Get-Process -Id $PID).Path
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixture=Join-Path $parent ('zip-encoding-'+[guid]::NewGuid().ToString('N'))
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw $Name};Write-Host ('PASS: '+$Name)}
try {
 $profile=Join-Path $fixture 'profile';$out=Join-Path $fixture 'backup';$restore=Join-Path $fixture 'restore';[void][IO.Directory]::CreateDirectory((Join-Path $profile 'settings'))
 $names=@('café.txt','设置.json','ascii.txt')
 foreach($name in $names){[IO.File]::WriteAllText((Join-Path $profile ('settings/'+$name)),'synthetic-'+$name,[Text.UTF8Encoding]::new($false))}
 $sources=Join-Path $fixture 'sources.psd1';[IO.File]::WriteAllText($sources,"@{HomeDirs=@('settings');RequiredSources=@('home/settings')}",[Text.UTF8Encoding]::new($false))
 $result=@(& $runtime -NoProfile -File (Join-Path $repo 'Backup-DevConfig.ps1') -SourcesFile $sources -ProfileRoot $profile -OutputRoot $out -SkipSystemExport -Tier Local -Json 2>&1)
 Check ($LASTEXITCODE-eq 0) ('Actual package accepts both CP437 and Unicode filenames: '+($result-join [Environment]::NewLine))
 $package=Get-VerifiedDevConfigPackage (Join-Path $out 'out')
 $result=@(& $runtime -NoProfile -File (Join-Path $repo 'Restore-DevConfig.ps1') -Archive $package.Zip -Destination $restore -Execute -Json 2>&1)
 Check ($LASTEXITCODE-eq 0) 'Restore decodes ZIP legacy and UTF-8 names consistently'
 foreach($name in $names){$source=Join-Path $profile ('settings/'+$name);$dest=Join-Path $restore ('home/settings/'+$name);Check ((Get-BackupStableFileHash $source)-ceq (Get-BackupStableFileHash $dest)) ('Restored filename and bytes match: '+$name)}
 $manifest=Read-BackupJson ($package.Zip+'.manifest.json') -Required
 foreach($cp in @(437,936)){
  $legacy=Join-Path $fixture ('legacy-'+$cp+'.zip')
  $encoding=[Text.Encoding]::GetEncoding($cp)
  $zip=[IO.Compression.ZipFile]::Open($legacy,[IO.Compression.ZipArchiveMode]::Create,$encoding)
  $legacyName=if($cp-eq 437){'café.txt'}else{'设置.json'}
  try{$e=$zip.CreateEntry('backup-manifest.json');$e=$zip.CreateEntry($legacyName);$stream=$e.Open();try{$stream.WriteByte(42)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
  $selected=Get-BackupArchiveEncoding $legacy @{files=@(@{relative_path=$legacyName;length=1})}
  Check ($selected.CodePage-eq $cp) ('Legacy ZIP codepage selected only by matching full manifest: '+$cp)
 }
 $manifest.files[0].length++
 $refused=$false;try{Assert-BackupArchiveManifest $package.Zip $manifest}catch{$refused=$_.Exception.Message-eq 'backup_archive_manifest_mismatch'}
 Check $refused 'Publication rejects a CRC-readable archive whose entries disagree with its manifest'
}finally{Remove-BackupOwnedDirectory $fixture $parent '^zip-encoding-[a-f0-9]{32}$'}
