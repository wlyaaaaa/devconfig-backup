[CmdletBinding()]
param([string]$RepoRoot = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$scriptPath = Join-Path $RepoRoot 'Backup-DevConfig.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
Assert-Condition (@($errors).Count -eq 0) 'backup source must parse'
$functions = @{}
foreach ($name in @('Test-HotRootAvailable', 'Push-Hot')) {
    $matches = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true))
    Assert-Condition ($matches.Count -eq 1) "required function missing or duplicated: $name"
    $functions[$name] = $matches[0]
}
. ([scriptblock]::Create($functions['Test-HotRootAvailable'].Extent.Text))
. ([scriptblock]::Create($functions['Push-Hot'].Extent.Text))

$script:HotRoot = 'G:\80_Backup\DevConfig'
$script:OutDir = 'E:\synthetic-out'
$script:KeepHot = 7
$script:availabilityCalls = 0
$script:copyCalls = 0
$script:failure = $null
function Test-HotRootAvailable { param([string]$Path) $script:availabilityCalls++; return $script:availabilityCalls -ge 2 }
function Start-Sleep { param([int]$Seconds) }
function New-Item { param() [pscustomobject]@{} }
function Copy-Item { param() $script:copyCalls++ }
function Get-ChildItem { param() @() }
function Write-Log { param([string]$Msg,[string]$Level) }
function Set-BackupFailure { param([string]$Message) $script:failure = $Message }

Push-Hot ([pscustomobject]@{ Zip = 'E:\synthetic-out\package.zip' })
Assert-Condition ($script:availabilityCalls -eq 2 -and $script:copyCalls -eq 2 -and $null -eq $script:failure) `
    'a transient unavailable hot root must retry once and then copy both artifacts'

$script:availabilityCalls = 0
$script:copyCalls = 0
$script:failure = $null
function Test-HotRootAvailable { param([string]$Path) $script:availabilityCalls++; return $false }
Push-Hot ([pscustomobject]@{ Zip = 'E:\synthetic-out\package.zip' })
Assert-Condition ($script:availabilityCalls -eq 3 -and $script:copyCalls -eq 0 -and
    [string]$script:failure -match 'hot_backup_root_unavailable') `
    "a persistently unavailable hot root must stop after the bounded retries without altering retention (failure=$script:failure)"

Write-Output 'PASS: Hot backup drive availability retries are bounded and preserve failure reporting.'
