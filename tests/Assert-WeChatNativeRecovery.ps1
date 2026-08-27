[CmdletBinding()]
param(
    [string] $RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$restorePath = Join-Path $RepoRoot 'Restore-WeChat.ps1'
$helperPath = Join-Path $RepoRoot 'WeChat-Recovery.Common.ps1'
$backupPath = Join-Path $RepoRoot 'Backup-WeChat.ps1'
$restoreText = Get-Content -LiteralPath $restorePath -Raw
$helperText = Get-Content -LiteralPath $helperPath -Raw
$backupText = Get-Content -LiteralPath $backupPath -Raw

Assert-Condition ($restoreText -match '\[switch\]\s+\$Execute') 'Restore-WeChat.ps1 must require an explicit -Execute switch.'
Assert-Condition ($restoreText -match 'MODE=PLAN') 'Restore-WeChat.ps1 must expose a read-only plan mode.'
Assert-Condition ($restoreText -match 'COPY_COMPLETE_AWAITING_HUMAN_ACCEPTANCE') 'Copy completion must be distinct from official-client acceptance.'
Assert-Condition ($restoreText -match 'Close it yourself') 'The restore flow must refuse a running official client without terminating it.'
Assert-Condition ($restoreText -notmatch '(?i)WeFlow|wx_key|decryptKey|_KEYS') 'Native recovery must not include decryption or personal-vault behavior.'
Assert-Condition ($backupText -match '本地/G 热备路径不打开') 'Backup documentation must distinguish the local/G native-data path.'
Assert-Condition ($backupText -notmatch '(?i)_KEYS|keyDir') 'Backup tooling must not automatically read or copy WeChat key material.'
Assert-Condition ($helperText -match 'Tencent\\Weixin\\Weixin\.exe') 'Client discovery must include the native Weixin installation path.'

. $helperPath

$root = Join-Path $env:TEMP ('wechat-native-recovery-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'hot-backup'
$planTarget = Join-Path $root 'plan-target'
$executeTarget = Join-Path $root 'execute-target'
$target = Join-Path $root 'target'
$junctionParent = Join-Path $root 'junction-parent'

try {
    New-Item -ItemType Directory -Path (Join-Path $source 'wxid_fixture') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $source 'wxid_fixture\fixture.bin'), 'synthetic native-layout fixture')
    $weixinFixture = Join-Path $root 'Weixin.exe'
    [System.IO.File]::WriteAllText($weixinFixture, 'synthetic executable fixture')
    $weixinCandidates = @(Get-NativeWeChatClientCandidates -AdditionalCandidatePaths @($weixinFixture))
    Assert-Condition (@($weixinCandidates | Where-Object { $_.Path -eq $weixinFixture }).Count -eq 1) 'Synthetic Weixin client candidate was not surfaced.'

    $planOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restorePath -BackupRoot $source -Target $planTarget 2>&1 | Out-String
    $planExit = $LASTEXITCODE
    Assert-Condition ($planExit -eq 0) 'Default restore invocation must be a successful read-only plan for a valid synthetic source.'
    Assert-Condition ($planOutput -match 'MODE=PLAN') 'Default restore invocation did not report plan mode.'
    Assert-Condition ($planOutput -match 'Account state is deliberately not read') 'Plan output must preserve account/database privacy boundaries.'
    Assert-Condition (-not (Test-Path -LiteralPath $planTarget)) 'Default plan unexpectedly created a target directory.'

    $clientState = Get-NativeWeChatClientState
    if (-not $clientState.Detected) {
        $executeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restorePath -Execute -BackupRoot $source -Target $executeTarget 2>&1 | Out-String
        $executeExit = $LASTEXITCODE
        if ($executeExit -ne 0 -and $executeOutput -match 'official WeChat process is running') {
            Write-Host 'SKIP: official WeChat started during the synthetic execute test; the safety refusal was observed.'
        } else {
            Assert-Condition ($executeExit -eq 0) 'Synthetic explicit execute failed unexpectedly.'
            Assert-Condition ($executeOutput -match 'COPY_COMPLETE_AWAITING_HUMAN_ACCEPTANCE') 'Synthetic execute did not keep copy completion separate from client acceptance.'
            Assert-Condition (Test-Path -LiteralPath (Join-Path $executeTarget 'wxid_fixture\fixture.bin')) 'Synthetic explicit execute did not copy the native fixture.'
        }
    } else {
        Write-Host 'SKIP: official WeChat is running; synthetic execute is intentionally not attempted.'
    }

    $nestedTarget = Join-Path $source 'nested-target'
    Assert-Condition (Test-NativeWeChatPathsOverlap -Left $source -Right $nestedTarget) 'A target below the backup source must be treated as overlapping.'
    Assert-Condition (Test-NativeWeChatPathsOverlap -Left $root -Right $source) 'A target above the backup source must be treated as overlapping.'
    $nestedCopyRejected = $false
    try {
        Invoke-NativeWeChatLocalCopy -Source $source -Target $nestedTarget | Out-Null
    } catch {
        $nestedCopyRejected = $_.Exception.Message -match 'overlap'
    }
    Assert-Condition $nestedCopyRejected 'Local copy must reject a target nested under its source.'
    Assert-Condition (-not (Test-Path -LiteralPath $nestedTarget)) 'Rejected nested copy unexpectedly created a target.'

    $realParent = Join-Path $root 'real-parent'
    New-Item -ItemType Directory -Path $realParent -Force | Out-Null
    New-Item -ItemType Junction -Path $junctionParent -Target $realParent -ErrorAction Stop | Out-Null
    $reparseTarget = Join-Path $junctionParent 'blocked-target'
    $reparseTargetState = Get-NativeWeChatPathState -Path $reparseTarget
    Assert-Condition ($reparseTargetState.ReparsePointPath -eq $junctionParent) 'A target below a synthetic junction must report its reparse-point parent.'
    $reparseTargetRejected = $false
    try {
        Invoke-NativeWeChatLocalCopy -Source $source -Target $reparseTarget | Out-Null
    } catch {
        $reparseTargetRejected = $_.Exception.Message -match 'reparse point'
    }
    Assert-Condition $reparseTargetRejected 'Local copy must reject a target below a junction.'

    $realSource = Join-Path $realParent 'source'
    New-Item -ItemType Directory -Path $realSource -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $realSource 'fixture.bin'), 'synthetic reparse-source fixture')
    $sourceViaJunction = Join-Path $junctionParent 'source'
    $reparseSourceRejected = $false
    try {
        Invoke-NativeWeChatLocalCopy -Source $sourceViaJunction -Target (Join-Path $root 'normal-target') | Out-Null
    } catch {
        $reparseSourceRejected = $_.Exception.Message -match 'reparse point'
    }
    Assert-Condition $reparseSourceRejected 'Local copy must reject a source below a junction.'

    New-Item -ItemType Directory -Path $target -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $target 'previous.bin'), 'existing target data')
    $targetState = Get-NativeWeChatPathState -Path $target
    Assert-Condition ($targetState.HasEntries) 'Synthetic existing target should be classified as non-empty.'

    $rollback = Get-NativeWeChatSiblingPath -Target $target -Kind 'pre-restore'
    Move-NativeWeChatTargetToRollback -Target $target -Rollback $rollback
    Assert-Condition (Test-Path -LiteralPath (Join-Path $rollback 'previous.bin')) 'Existing target was not preserved in rollback.'

    $copyResult = Invoke-NativeWeChatLocalCopy -Source $source -Target $target
    Assert-Condition ($copyResult.ExitCode -le 3) 'Synthetic native copy did not return a clean robocopy result.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $target 'wxid_fixture\fixture.bin')) 'Synthetic native layout was not copied to the target.'

    $rollbackResult = Restore-NativeWeChatRollback -Target $target -Rollback $rollback
    Assert-Condition ($rollbackResult.Restored) 'Rollback helper did not report success.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $target 'previous.bin')) 'Rollback did not restore the prior target.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $rollbackResult.FailedRestorePath 'wxid_fixture\fixture.bin')) 'Partial replacement was not retained separately during rollback.'

    $driveRoot = [System.IO.Path]::GetPathRoot($target)
    $rootRejected = $false
    try {
        [void](Resolve-NativeWeChatRecoveryPath -Path $driveRoot)
    } catch {
        $rootRejected = $true
    }
    Assert-Condition $rootRejected 'Drive-root recovery targets must be rejected.'

    Write-Host 'PASS: native WeChat recovery defaults to plan, preserves rollback, and separates copy from human acceptance.'
    exit 0
}
finally {
    if (Test-Path -LiteralPath $junctionParent) {
        & cmd.exe /d /c ('rmdir "{0}"' -f $junctionParent) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to remove synthetic junction fixture: $junctionParent" }
    }
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
