[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
. (Join-Path $repo 'DevConfig.Sources.ps1')
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixture=Join-Path $parent ('devconfig-capture-'+[guid]::NewGuid().ToString('N'))
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw $Name};Write-Host ('PASS: '+$Name)}
try{
 $profile=Join-Path $fixture 'profile';$target=Join-Path $fixture 'target';[void][IO.Directory]::CreateDirectory((Join-Path $profile 'settings'))
 $file=Join-Path $profile 'settings/value.txt';[IO.File]::WriteAllText($file,'old')
 $config=@{HomeDirs=@('settings');RequiredSources=@('home/settings')}
 $before=Get-DevConfigSourceInventory $config $profile
 [IO.File]::WriteAllText($file,'new and complete')
 Copy-DevConfigSourceInventory $before $target
 $captured=Join-Path $target 'home/settings/value.txt'
 Check ((Get-BackupStableFileHash $captured)-ceq $before.files[0].sha256) 'Capture binds actual verified bytes rather than a stale pre-scan hash'
 [IO.File]::WriteAllText($file,'changed by app after capture')
 $after=Get-DevConfigSourceInventory $config $profile
 Check ((Test-DevConfigSelectionAfterCapture $before $after)-eq 1) 'Post-capture application changes are explicitly counted without false atomicity'
 Check ([IO.File]::ReadAllText($captured)-ceq 'new and complete') 'Captured backup remains unchanged when the application updates its source'
 [IO.File]::WriteAllText((Join-Path $profile 'settings/new.txt'),'new source item')
 $refused=$false;try{$null=Test-DevConfigSelectionAfterCapture $before (Get-DevConfigSourceInventory $config $profile)}catch{$refused=$_.Exception.Message-eq 'backup_source_selection_changed_during_collection'}
 Check $refused 'New or missing source paths cannot be silently skipped'
}finally{Remove-BackupOwnedDirectory $fixture $parent '^devconfig-capture-[a-f0-9]{32}$'}
