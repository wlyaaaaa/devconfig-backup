[CmdletBinding()]
param([string]$WorkerRoot='')
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
if($WorkerRoot){
 $path=Join-Path $WorkerRoot 'manifest.json'
 $packet=[ordered]@{schema='fixture';nothing=$null;empty=@();single=@([long]4294967297);record=[pscustomobject][ordered]@{length=[long]::MaxValue;utc='2026-10-19T01:30:01.9605878+00:00';text=('quote" slash\ newline'+"`n`r`t"+[char]1+[char]0x4e2d+[char]0xd83d+[char]0xde00)}}
 $expected=ConvertTo-Json -InputObject $packet -Depth 30 -Compress
 Write-BackupJsonAtomic $path $packet
 $actual=[IO.File]::ReadAllText($path)
 # Escape choices differ between the two built-in JSON engines; compare decoded values.
 $parse=@{};if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$parse.DateKind='String'}
 $a=ConvertFrom-Json -InputObject $actual @parse;$e=ConvertFrom-Json -InputObject $expected @parse
 if(($a.PSObject.Properties.Name -join ',')-cne 'schema,nothing,empty,single,record' -or $null-ne $a.nothing -or @($a.empty).Count-ne 0 -or @($a.single).Count-ne 1 -or $a.single[0]-ne 4294967297 -or $a.record.length-ne [long]::MaxValue -or $a.record.utc-cne $e.record.utc -or $a.record.text-cne $packet.record.text){throw 'json_type_or_text_roundtrip_failed'}
 $before=Get-BackupStableFileHash $path;$failed=$false
 try{Write-BackupJsonAtomic $path ([ordered]@{changed=$true;invalid=@{1='nonstring key'}})}catch{$failed=$true}
 if(-not $failed -or (Get-BackupStableFileHash $path)-cne $before -or @(Get-ChildItem -LiteralPath $WorkerRoot -Filter '.json-*.tmp').Count){throw 'serialization_failure_changed_preimage_or_leaked_temp'}
 $held=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$failed=$false
 try{try{Write-BackupJsonAtomic $path @{changed=$true}}catch{$failed=$true}}finally{$held.Dispose()}
 if(-not $failed -or (Get-BackupStableFileHash $path)-cne $before -or @(Get-ChildItem -LiteralPath $WorkerRoot -Filter '.json-*.tmp').Count){throw 'replace_failure_changed_preimage_or_leaked_temp'}
 Add-Type -ReferencedAssemblies ([Management.Automation.PSObject].Assembly.Location) -TypeDefinition @'
using System;
using System.Collections;
using System.Management.Automation;
public static class BackupJsonFixture {
 public static object Build() {
  object[] files = new object[153226];
  string suffix = new string('p', 96) + ".bin", hash = new string('a', 64);
  for (int i = 0; i < files.Length; i++) {
   PSObject file = new PSObject();
   file.Properties.Add(new PSNoteProperty("relative_path", "fixture/" + i.ToString("D6") + "/" + suffix));
   file.Properties.Add(new PSNoteProperty("length", (long)304271));
   file.Properties.Add(new PSNoteProperty("mtime_ticks", (long)638000000000000000));
   file.Properties.Add(new PSNoteProperty("sha256", hash)); files[i] = file;
  }
  return new Hashtable { {"schema", "anonymous.manifest.v1"}, {"file_count", files.Length}, {"files", files} };
 }
}
'@
 $large=[BackupJsonFixture]::Build();[GC]::Collect();[GC]::WaitForPendingFinalizers();[GC]::Collect()
 $process=[Diagnostics.Process]::GetCurrentProcess();$process.Refresh();$baseline=$process.PrivateMemorySize64
 $clock=[Diagnostics.Stopwatch]::StartNew();Write-BackupJsonAtomic $path $large;$clock.Stop()
 $bytes=([IO.FileInfo]::new($path)).Length
 if($bytes-lt 35000000 -or $bytes-gt 45000000){throw 'fixture_did_not_match_production_manifest_scale'}
 [pscustomobject]@{runtime=$PSVersionTable.PSVersion.ToString();items=153226;manifest_bytes=$bytes;write_seconds=[math]::Round($clock.Elapsed.TotalSeconds,3);before_write_private_bytes=$baseline;types_and_atomic_failures='passed'}|ConvertTo-Json -Compress
 exit 0
}
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixture=Join-Path $parent ('backup-json-streaming-'+[guid]::NewGuid().ToString('N'))
try{
 [void][IO.Directory]::CreateDirectory($fixture)
 $runtimes=@((Get-Process -Id $PID).Path,(Get-Command powershell.exe).Source)|Select-Object -Unique
 foreach($runtime in $runtimes){
  $worker=Join-Path $fixture ([IO.Path]::GetFileNameWithoutExtension($runtime));[void][IO.Directory]::CreateDirectory($worker)
  $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$runtime;$info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -WorkerRoot "'+$worker+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $process=[Diagnostics.Process]::Start($info);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  $samples=[Collections.Generic.Queue[object]]::new();[long]$peak=0;[long]$growth=0;$clock=[Diagnostics.Stopwatch]::StartNew()
  try{
   while(-not $process.HasExited){
    $process.Refresh();$seconds=$clock.Elapsed.TotalSeconds;[long]$private=$process.PrivateMemorySize64;$peak=[math]::Max($peak,$private)
    while($samples.Count -and $seconds-$samples.Peek().seconds-gt 10){$null=$samples.Dequeue()}
    foreach($sample in $samples){$growth=[math]::Max($growth,$private-$sample.bytes)}
    $samples.Enqueue([pscustomobject]@{seconds=$seconds;bytes=$private});Start-Sleep -Milliseconds 25
   }
   $process.WaitForExit();$output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
   if($process.ExitCode-ne 0){throw ('worker_failed: '+$output+$errorText)}
   if($peak-ge 1GB -or $growth-ge 768MB){throw ('streaming_memory_budget_exceeded: peak='+$peak+';growth_10s='+$growth)}
   $result=$output|ConvertFrom-Json;$result|Add-Member NoteProperty peak_private_bytes $peak;$result|Add-Member NoteProperty maximum_growth_within_10s_bytes $growth;$result|ConvertTo-Json -Compress
  }finally{$process.Dispose()}
 }
}finally{
 $full=[IO.Path]::GetFullPath($fixture)
 if([IO.Path]::GetDirectoryName($full)-ine $parent -or [IO.Path]::GetFileName($full)-notmatch '^backup-json-streaming-[a-f0-9]{32}$'){throw 'fixture_cleanup_scope_invalid'}
 if([IO.Directory]::Exists($full)){[IO.Directory]::Delete($full,$true)}
}
