# Read producer receipts and manifests only; never open configuration or chat payloads.
function Write-BackupProjectLive([string]$OutputRoot,[string]$HotReceiptPath='G:\80_Backup\ControlPlane\wechat-hot-last.json',[string]$OutputPath=''){
 if(-not $OutputPath){$OutputPath=Join-Path $OutputRoot 'state\live.project.json'}
 $at=[DateTimeOffset]::UtcNow.ToString('o');$metrics=[ordered]@{};$artifacts=@()
 foreach($key in @('sources','files','package_size','compression','sqlite','exclusions','wechat_size','wechat_files','retained')){$metrics[$key]=[ordered]@{value=$null;at=$null;note='尚无可读的生产回执'}}
 $out=Join-Path $OutputRoot 'out'
 try{
  $pack=Get-VerifiedDevConfigPackage $out -MetadataOnly;$r=$pack.Receipt;$m=Read-BackupJson ($pack.Zip+'.manifest.json') -Required
  if($m.file_count-ne $r.file_count -or @($m.files).Count-ne $m.file_count -or ($m.files|Measure-Object length -Sum).Sum-ne $m.bytes){throw 'live_manifest_mismatch'}
  $available=@($m.sources|Where-Object status -eq 'available').Count;$absent=@($m.sources|Where-Object status -eq 'optional_absent').Count
  if($available+$absent-ne @($m.sources).Count){throw 'live_source_status_unknown'}
  $percent=if($m.bytes){[math]::Round(100*(1-$r.package_bytes/$m.bytes),2)}else{$null}
  $values=[ordered]@{
   sources=@{text=('{0} 处（计划 {1} 处，这台电脑上没有 {2} 处）' -f $available,@($m.sources).Count,$absent);available=$available;planned=@($m.sources).Count;optional_absent=$absent}
   files=$m.file_count
   package_size=@{text=('{0:N0} MB（原文件 {1:N2} GB）' -f ($r.package_bytes/1MB),($m.bytes/1GB));bytes=$r.package_bytes;original_bytes=$m.bytes}
   compression=@{text=$(if($null-ne $percent){'{0:N2} GB，压小 {1:N2}%' -f (($m.bytes-$r.package_bytes)/1GB),$percent}else{'原文件合计为 0，压缩比无定义'});saved_bytes=($m.bytes-$r.package_bytes);percent=$percent}
   sqlite=$(if($m.PSObject.Properties['sqlite_snapshots']){@($m.sqlite_snapshots|Where-Object integrity_check -eq 'ok').Count}else{$null})
   exclusions=$(if($m.PSObject.Properties['intentional_exclusions']){@($m.intentional_exclusions).Count}else{$null})
  }
  foreach($key in $values.Keys){$metrics[$key]=@{value=$values[$key];at=$r.completed_utc;note=$(if($key-eq 'exclusions' -and $null-eq $values[$key]){'旧包没有记录有意排除策略；下一包起才有'}else{''})}}
  if($null-eq $values.sqlite){$metrics.sqlite.note='这份包没有记录 SQLite 副本清单'}
 }catch{foreach($key in @('sources','files','package_size','compression','sqlite','exclusions')){$metrics[$key].note='当前包或清单不可读，或同代文件数、长度不一致'}}
 try{
  $packages=@(Get-ChildItem -LiteralPath $out -Filter 'devconfig-*.zip.receipt.json' -File -ErrorAction Stop|ForEach-Object{
   $r=Read-BackupJson $_.FullName -Required;$zip=Join-Path $out $r.package_name
   if($r.schema-ceq 'devconfig.package-receipt.v2' -and $r.status-ceq 'complete' -and $r.collection_status-ceq 'complete' -and $r.archive_verification-ceq '7z_test_pass' -and $r.package_name-cmatch '^devconfig-[0-9]{8}-[0-9]{6}-[a-f0-9]{8}\.zip$' -and [IO.File]::Exists($zip) -and (Get-Item -LiteralPath $zip).Length-eq $r.package_bytes){$r}
  }|Sort-Object completed_utc -Descending|Sort-Object package_name -Unique)
  $metrics.retained=@{value=$packages.Count;at=$at;note='只计存在且长度匹配的完成包；latest 别名和其它副本不重复计数'}
  foreach($r in @($packages|Sort-Object { [DateTimeOffset]$_.completed_utc } -Descending)){
   $excluded=if($r.PSObject.Properties['intentional_exclusions']){[string]@($r.intentional_exclusions).Count}else{'旧包未记录'}
   $artifacts+=@{at=$r.completed_utc;kind='archive';title=('开发配置包 · {0:N0} 个文件 · {1:N0} MB · 有意不装：{2}' -f $r.file_count,($r.package_bytes/1MB),$excluded);status='completed';public='same';open=@{source='devconfig.packages'}}
  }
 }catch{$metrics.retained.note='本机包目录或完成回执不可读，不能取得完整库存'}
 try{
  $w=Read-BackupJson $HotReceiptPath -Required
  if($w.schema-cne 'wechat.hot-backup-receipt.v2' -or $w.status-cne 'complete' -or $w.collection_status-cne 'complete' -or $w.verification_status-cne 'sha256_full_tree' -or $w.retention_status-cne 'source_follow_verified'){throw 'live_wechat_receipt_not_verified'}
  $metrics.wechat_size=@{value=$w.bytes;at=$w.completed_utc;note='生产回执的文件合计，未重扫微信或核验云端'};$metrics.wechat_files=@{value=$w.file_count;at=$w.completed_utc;note='文件个数，不是消息条数'}
  if([IO.Directory]::Exists($w.destination)){$artifacts=@(@{at=$w.completed_utc;kind='copy';title=('微信原始副本 · {0:N0} 个文件 · {1:N2} GB' -f $w.file_count,($w.bytes/1GB));status='completed';public='same';open=@{source='devconfig.wechat'}})+$artifacts}
 }catch{$metrics.wechat_size.note='微信完整生产回执不可读或核验状态不全';$metrics.wechat_files.note=$metrics.wechat_size.note}
 Write-BackupJsonAtomic $OutputPath ([ordered]@{v=1;at=$at;scope='已发布的本机配置包和 G 盘微信副本；各文件分别采集，不证明应用已能恢复';metrics=$metrics;artifacts=$artifacts})
}
function Update-BackupProjectSnapshot([string]$RepoRoot){
 $paths=@(& git -C $RepoRoot ls-files);if($LASTEXITCODE-ne 0){throw 'live_git_files_failed'}
 $docs=@($paths|Where-Object{$_-match '\.md$'});$code=@($paths|Where-Object{$_-match '\.(ps1|psd1|vbs|py|cs)$'})
 $chars=0;$lines=0;$codeChars=0
 foreach($path in $docs){$chars+=[regex]::Matches([IO.File]::ReadAllText((Join-Path $RepoRoot $path)),'[\p{IsCJKUnifiedIdeographs}]|[A-Za-z0-9]+').Count}
 foreach($path in $code){$text=[IO.File]::ReadAllText((Join-Path $RepoRoot $path));$lines+=[IO.File]::ReadAllLines((Join-Path $RepoRoot $path)).Count;$codeChars+=[regex]::Replace($text,'\s','').Length}
 $metrics=[ordered]@{docs_files=$docs.Count;code_files=$code.Count};$size=[ordered]@{docs_chars=$chars;code_lines=$lines;code_chars=$codeChars};$path=Join-Path $RepoRoot 'docs\live.snapshot.json';$old=Read-BackupJson $path
 if($old -and ($old.metrics|ConvertTo-Json -Compress)-ceq ($metrics|ConvertTo-Json -Compress) -and $old.size.docs_chars-eq $chars -and $old.size.code_lines-eq $lines -and $old.size.code_chars-eq $codeChars){return}
 $at=[DateTimeOffset]::UtcNow.ToString('o');$size.at=$at
 Write-BackupJsonAtomic $path ([ordered]@{v=1;at=$at;scope='Git 跟踪的自有 Markdown 和代码，含测试，排除备份、第三方和生成物；按需更新';metrics=$metrics;size=$size})
}
