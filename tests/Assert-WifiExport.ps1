[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
. (Join-Path $repo 'DevConfig.Sources.ps1')
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixture=Join-Path $parent ('wifi-export-'+[guid]::NewGuid().ToString('N'))
$original=(Get-Location).Path;$script:failWifiExport=$false
function netsh.exe {
 if($script:failWifiExport){$global:LASTEXITCODE=1;return}
 $folder=@($args|Where-Object{$_-like 'folder=*'})[0].Substring(7)
 foreach($name in @('WLAN-one','WLAN-two','WLAN-three')){
  $path=Join-Path $folder ($name+'.xml')
  # Reproduce netsh's observed path truncation without using real profiles.
  if($path.Length-gt 127){$path=$path.Substring(0,123)+'.xml'}
  [IO.File]::WriteAllText((Join-Path (Get-Location).Path $path),'<WLANProfile />')
 }
 $global:LASTEXITCODE=0
}
try{
 $destination=Join-Path $fixture (('nested-'*8)+'\_system\wifi')
 if($destination.Length-le 127){throw 'wifi_test_path_too_short'}
 Export-DevConfigWifiProfiles $destination
 if(@(Get-ChildItem -LiteralPath $destination -Filter *.xml).Count-ne 3 -or @(Get-ChildItem -LiteralPath $fixture -Filter *.xml -Recurse).Count-ne 3){throw 'wifi_profiles_outside_payload'}
 if((Get-Location).Path-ne $original){throw 'wifi_export_location_not_restored'}
 $script:failWifiExport=$true;$failed=$false
 try{Export-DevConfigWifiProfiles $destination}catch{$failed=$_.Exception.Message-ceq 'wifi_profile_export_failed'}
 if(-not $failed -or (Get-Location).Path-ne $original){throw 'wifi_export_failure_not_propagated_or_location_not_restored'}
 Write-Output 'PASS: long-path Wi-Fi export retains all profiles in the payload and restores location on success/failure.'
}finally{
 Remove-Item Function:\netsh.exe
 Remove-BackupOwnedDirectory $fixture $parent '^wifi-export-[a-f0-9]{32}$'
}
