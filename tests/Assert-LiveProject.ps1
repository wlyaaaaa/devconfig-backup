$ErrorActionPreference='Stop';$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1');. (Join-Path $repo 'Live.Project.ps1')
$root=Join-Path $env:TEMP ('backup-live-'+[guid]::NewGuid().ToString('N'));$out=Join-Path $root 'out';$wx=Join-Path $root 'wechat.json';$live=Join-Path $root 'state\live.project.json'
function Check($ok,$message){if(-not $ok){throw $message};Write-Host ('PASS: '+$message)}
try{
 [void][IO.Directory]::CreateDirectory($out);$name='devconfig-20260101-010101-abcdef01.zip';$zip=Join-Path $out $name;[IO.File]::WriteAllText($zip,'abc');$at='2026-01-01T08:00:00+08:00';$hash='a'*64
 $receipt=@{schema='devconfig.package-receipt.v2';status='complete';collection_status='complete';archive_verification='7z_test_pass';package_name=$name;package_bytes=3;file_count=2;sha256=$hash;completed_utc=$at}
 Write-BackupJsonAtomic ($zip+'.receipt.json') $receipt;Write-BackupJsonAtomic (Join-Path $out 'devconfig-duplicate.zip.receipt.json') $receipt
 Write-BackupJsonAtomic (Join-Path $out 'current.json') @{schema='devconfig.package-current.v2';status='complete';package_name=$name;sha256=$hash}
 $manifest=@{file_count=2;bytes=6;files=@(@{length=2},@{length=4});sources=@(@{status='available'},@{status='optional_absent'},@{status='available'});sqlite_snapshots=@(@{integrity_check='ok'},@{integrity_check='failed'})}
 Write-BackupJsonAtomic ($zip+'.manifest.json') $manifest
 Write-BackupJsonAtomic $wx @{schema='wechat.hot-backup-receipt.v2';status='complete';collection_status='complete';verification_status='sha256_full_tree';retention_status='source_follow_verified';file_count=4;bytes=12;completed_utc=$at;destination=$out}
 Write-BackupProjectLive $root $wx;$v=Read-BackupJson $live
 Check ($v.metrics.sources.value.available-eq 2 -and $v.metrics.sources.value.planned-eq 3 -and $v.metrics.sources.value.optional_absent-eq 1) 'Available sources are distinct from the selected plan'
 Check ($v.metrics.compression.value.percent-eq 50 -and $v.metrics.sqlite.value-eq 1 -and $v.metrics.retained.value-eq 1) 'Aggregation counts verified SQLite copies and distinct packages'
 Check ($null-eq $v.metrics.exclusions.value -and $v.metrics.exclusions.note -and $v.metrics.files.at-ceq $at) 'An old missing field stays unknown and source time is preserved'
 Check ($v.artifacts.Count-eq 2 -and $v.artifacts[0].kind-eq 'copy' -and $v.metrics.wechat_files.value-eq 4) 'Completed artifacts are ordered'
 Check ($null-eq $v.artifacts[0].open -and $v.artifacts[1].open.path-ceq $name) 'Only the real package file gets an open target; the directory stays a summary'
 $manifest.Remove('sqlite_snapshots');Write-BackupJsonAtomic ($zip+'.manifest.json') $manifest;Write-BackupProjectLive $root $wx;$v=Read-BackupJson $live
 Check ($null-eq $v.metrics.sqlite.value -and $v.metrics.sqlite.note) 'Missing SQLite evidence is not a measured zero'
 $manifest.file_count=3;Write-BackupJsonAtomic ($zip+'.manifest.json') $manifest;[IO.File]::Delete($wx);Write-BackupProjectLive $root $wx;$v=Read-BackupJson $live
 Check ($null-eq $v.metrics.files.value -and $null-eq $v.metrics.wechat_files.value -and $v.metrics.files.note -and $v.metrics.wechat_files.note) 'Mismatched or missing receipts yield null with a reason'
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
