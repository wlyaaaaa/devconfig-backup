[CmdletBinding()]
param([string]$RepoRoot='')
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent $PSScriptRoot}
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'Backup.Common.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Backup-DevConfig.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'source_parse_failure'}
foreach($name in @('Test-HotRootAvailable','Push-Hot')){
 $definition=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true))
 . ([scriptblock]::Create($definition[0].Extent.Text))
}
$HotRoot='G:\synthetic-hot';$OutDir='E:\synthetic-out';$KeepHot=7
$script:tries=0;$script:published=0;$script:disposed=0
function Test-HotRootAvailable {param($Path)$script:tries++;return $script:tries-ge 2}
function Start-Sleep {param($Seconds)}
function Open-BackupResourceLock {param($Resource)$o=New-Object PSObject;$o|Add-Member ScriptMethod Dispose {$script:disposed++};return $o}
function Publish-DevConfigPackage {param($Pack,$Root,$Keep)$script:published++;if($Pack.Zip-ne 'E:\synthetic-out\fixed.zip'){throw 'mutable_package_used'}}
Push-Hot ([pscustomobject]@{Zip='E:\synthetic-out\fixed.zip'})
if($script:tries-ne 2 -or $script:published-ne 1 -or $script:disposed-ne 1){throw 'bounded_retry_or_lock_disposal_failed'}
$script:tries=0;function Test-HotRootAvailable {param($Path)$script:tries++;return $false}
$blocked=$false;try{Push-Hot ([pscustomobject]@{Zip='E:\synthetic-out\fixed.zip'})}catch{$blocked=$_.Exception.Message-eq 'hot_backup_root_unavailable'}
if(-not $blocked -or $script:tries-ne 3 -or $script:published-ne 1){throw 'unavailable_hot_must_not_publish_or_prune'}
Write-Output 'PASS: bounded retries, fixed package, lock disposal and unavailable-volume failure.'
