<#
.SYNOPSIS
  Restore a native WeChat application-data backup for use by the official client.
.DESCRIPTION
  The default is a read-only plan and preflight.  Copying requires -Execute.
  This script copies the backup's native xwechat_files layout; it does not open
  databases, read accounts, extract keys, decrypt data, launch WeChat, or claim
  that a successful copy has restored the application.

  Before an overwrite, an existing non-empty target is moved beside itself as a
  rollback directory.  That rollback is kept until the user has opened the
  official client and confirmed the intended account and history themselves.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1
  # Read-only preflight using the G: hot backup.  No files are changed.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -Execute
  # Copy into an empty default target after the official client has been closed.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -Execute -ReplaceExisting
  # Preserve a non-empty target as a sibling .pre-restore-* rollback, then copy.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -DriveOnly -Execute -Target E:\restore\xwechat_files
  # Legacy compatibility path only.  Its remote configuration is not validated by this local/G recovery workflow.
#>
[CmdletBinding()]
param(
    [string] $Target = 'E:\Documents\xwechat_files',
    [Alias('UsbRoot', 'SourceRoot')]
    [string] $BackupRoot = 'G:\80_Backup\WeChat\xwechat_files',
    [string] $GDriveRemote = 'gdrive:',
    [string] $GDriveFolder = 'Backups/WeChat/xwechat_files',
    [switch] $DriveOnly,
    [Alias('List')]
    [switch] $Plan,
    [switch] $Execute,
    [switch] $ReplaceExisting,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WeChat-Recovery.Common.ps1')
. (Join-Path $PSScriptRoot 'Initialize-BackupNetwork.ps1')
$script:GDriveRemoteWasExplicit = $PSBoundParameters.ContainsKey('GDriveRemote')

function Say {
    param([string] $Message, [string] $Color = 'Gray')
    Write-Host ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

function Get-NativeWeChatDriveSource {
    param([string] $Remote, [string] $Folder)

    $normalizedRemote = $Remote.Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedRemote)) {
        throw 'A Drive remote is required for -DriveOnly.'
    }
    if (-not $normalizedRemote.EndsWith(':')) {
        $normalizedRemote += ':'
    }
    return $normalizedRemote + $Folder.Trim('/').Trim('\')
}

function Invoke-NativeWeChatDriveCopy {
    param(
        [string] $Remote,
        [string] $Folder,
        [string] $Destination
    )

    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        throw 'rclone is required for -DriveOnly, but it is not available on PATH.'
    }

    $destinationState = Assert-NativeWeChatTargetPath -Target $Destination
    New-Item -ItemType Directory -Path $destinationState.Path -Force -ErrorAction Stop | Out-Null
    $remoteResolution = Resolve-ConfiguredRcloneRemote -Remote $Remote `
        -RemoteWasExplicit $script:GDriveRemoteWasExplicit `
        -BindingPath (Join-Path (Join-Path $PSScriptRoot 'state') 'rclone-remote-binding.json')
    if (-not $remoteResolution.Success) {
        throw "Configured Drive remote is unavailable: $($remoteResolution.Reason)"
    }
    $source = Get-NativeWeChatDriveSource -Remote $remoteResolution.Remote -Folder $Folder
    $excludes = @(
        '--exclude', 'cache/**',
        '--exclude', 'Cache/**',
        '--exclude', 'temp/**',
        '--exclude', 'Temp/**',
        '--exclude', 'WMPF/**',
        '--exclude', 'apm_record/**',
        '--exclude', 'crash/**',
        '--exclude', 'FileStorageTemp/**',
        '--exclude', 'recommend_cover/**'
    )
    $arguments = @('copy', $source, $destinationState.Path, '--checksum', '--transfers', '8', '--checkers', '16', '--fast-list') + $excludes
    & rclone @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "rclone failed while copying the native WeChat backup (exit=$exitCode)."
    }

    return [pscustomobject]@{
        Method = 'rclone'
        ExitCode = $exitCode
    }
}

function Write-NativeWeChatPreflight {
    param(
        $TargetState,
        $ClientState,
        [object[]] $ClientCandidates,
        [string] $SourceDescription,
        [string[]] $ExecutionBlockers
    )

    Say 'MODE=PLAN: no application data is copied or changed.' 'Cyan'
    Say "Backup source: $SourceDescription"
    Say ("Target: {0}; exists={1}; directory={2}; nonEmpty={3}; reparsePointPath={4}" -f $TargetState.Path, $TargetState.Exists, $TargetState.IsDirectory, $TargetState.HasEntries, $TargetState.ReparsePointPath)
    if ($ClientState.Detected) {
        Say ("Official WeChat process detected: {0}. -Execute will refuse; close it yourself first." -f ($ClientState.ProcessNames -join ', ')) 'Yellow'
    } else {
        Say 'Known official WeChat process names were not detected. This does not prove there are no file locks.' 'Yellow'
    }
    if ($ClientCandidates.Count -gt 0) {
        foreach ($candidate in $ClientCandidates) {
            Say ("Detected client candidate: {0}; version={1}" -f $candidate.Path, $candidate.Version)
        }
    } else {
        Say 'Installed official-client version was not found in the standard locations; compatibility remains unverified.' 'Yellow'
    }
    Say 'Account state is deliberately not read. Databases are deliberately not opened.'

    if ($ExecutionBlockers.Count -gt 0) {
        Say 'Execution blockers:' 'Red'
        foreach ($blocker in $ExecutionBlockers) {
            Say ("  - {0}" -f $blocker) 'Red'
        }
    } else {
        Say 'Preflight has no local blocker. Use -Execute only after closing the official client.' 'Green'
    }
}

function Write-NativeWeChatAcceptanceInstructions {
    param([string] $RollbackPath)

    Say 'COPY_COMPLETE_AWAITING_HUMAN_ACCEPTANCE' 'Green'
    Say 'The copy result is not evidence that the official client has recovered.' 'Yellow'
    Say 'Next: start the official WeChat client yourself, sign in to the intended account if prompted, and verify that the expected history is visible.' 'Yellow'
    Say 'Keep the backup source and any .pre-restore-* directory until that human acceptance is complete.' 'Yellow'
    if ($RollbackPath) {
        Say "Rollback preserved: $RollbackPath" 'Yellow'
        Say 'If the client does not show the intended data, close it and restore that directory with the same explicit -Execute workflow; do not overwrite it in place.' 'Yellow'
    }
}

if ($Plan -and $Execute) {
    throw '-Plan (or legacy -List) cannot be combined with -Execute.'
}
if (-not $Execute) {
    $Plan = $true
}

$targetState = Get-NativeWeChatPathState -Path $Target
$clientState = Get-NativeWeChatClientState
$clientCandidates = @(Get-NativeWeChatClientCandidates)
$executionBlockers = @()
$sourceDescription = $null
$sourceState = $null

if (-not $targetState.IsDirectory -and $targetState.Exists) {
    $executionBlockers += 'The target exists but is not a directory.'
}
if (-not [string]::IsNullOrWhiteSpace($targetState.ReparsePointPath)) {
    $executionBlockers += "The target path or one of its parents is a reparse point: $($targetState.ReparsePointPath)"
}
if ($targetState.HasEntries -and -not $ReplaceExisting) {
    $executionBlockers += 'The target is non-empty. Re-run with -ReplaceExisting to preserve it as a rollback before copying.'
}
if ($clientState.Detected) {
    $executionBlockers += 'An official WeChat process is running. Close it yourself before executing a restore.'
}

if ($DriveOnly) {
    $sourceDescription = 'unverified Drive compatibility source: ' + (Get-NativeWeChatDriveSource -Remote $GDriveRemote -Folder $GDriveFolder)
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        $executionBlockers += 'rclone is not available for the requested -DriveOnly restore.'
    }
} else {
    $sourceState = Get-NativeWeChatPathState -Path $BackupRoot
    $sourceDescription = $sourceState.Path
    if (-not [string]::IsNullOrWhiteSpace($sourceState.ReparsePointPath)) {
        $executionBlockers += "The backup source path or one of its parents is a reparse point: $($sourceState.ReparsePointPath)"
    }
    if (Test-NativeWeChatPathsOverlap -Left $sourceState.Path -Right $targetState.Path) {
        $executionBlockers += 'The backup source and target are equal or one contains the other.'
    }
    if (-not $sourceState.Exists -or -not $sourceState.IsDirectory -or -not $sourceState.HasEntries) {
        $executionBlockers += 'The local backup source is missing, not a directory, or empty.'
    }
}

Write-NativeWeChatPreflight -TargetState $targetState -ClientState $clientState -ClientCandidates $clientCandidates -SourceDescription $sourceDescription -ExecutionBlockers $executionBlockers

if ($Plan) {
    $planResult = [pscustomobject]@{
        Mode = 'plan'
        Source = $sourceDescription
        Target = $targetState.Path
        ClientProcessDetected = $clientState.Detected
        ClientVersions = @($clientCandidates | ForEach-Object { $_.Version })
        AccountState = 'not_read'
        DatabaseState = 'not_opened'
        ExecutionBlockers = $executionBlockers
    }
    if ($PassThru) { $planResult }
    if ($executionBlockers | Where-Object { $_ -notmatch '^An official WeChat process is running' }) {
        exit 2
    }
    exit 0
}

if ($executionBlockers.Count -gt 0) {
    throw ('Restore preflight failed: ' + ($executionBlockers -join ' '))
}

$rollbackPath = $null
try {
    if ($targetState.HasEntries) {
        $rollbackPath = Get-NativeWeChatSiblingPath -Target $targetState.Path -Kind 'pre-restore'
        Say "Preserving the existing target as rollback: $rollbackPath" 'Yellow'
        Move-NativeWeChatTargetToRollback -Target $targetState.Path -Rollback $rollbackPath
    }

    if ($DriveOnly) {
        $copyResult = Invoke-NativeWeChatDriveCopy -Remote $GDriveRemote -Folder $GDriveFolder -Destination $targetState.Path
    } else {
        $copyResult = Invoke-NativeWeChatLocalCopy -Source $sourceState.Path -Target $targetState.Path
    }

    $restoredTargetState = Get-NativeWeChatPathState -Path $targetState.Path
    if (-not $restoredTargetState.IsDirectory -or -not $restoredTargetState.HasEntries) {
        throw 'The copy command returned without a usable non-empty target directory.'
    }
} catch {
    $originalError = $_
    if ($rollbackPath -and (Test-Path -LiteralPath $rollbackPath -PathType Container)) {
        try {
            $rollbackResult = Restore-NativeWeChatRollback -Target $targetState.Path -Rollback $rollbackPath
            Say "Copy failed; the prior target was restored from rollback. Partial copy retained at: $($rollbackResult.FailedRestorePath)" 'Red'
        } catch {
            throw ("Copy failed and automatic rollback also failed. Original error: {0}; rollback error: {1}" -f $originalError.Exception.Message, $_.Exception.Message)
        }
    }
    throw $originalError
}

Write-NativeWeChatAcceptanceInstructions -RollbackPath $rollbackPath
$executeResult = [pscustomobject]@{
    Mode = 'execute'
    CopyMethod = $copyResult.Method
    CopyExitCode = $copyResult.ExitCode
    Target = $targetState.Path
    RollbackPath = $rollbackPath
    RecoveryStatus = 'copy_complete_awaiting_human_acceptance'
    AccountState = 'not_read'
    DatabaseState = 'not_opened'
}
if ($PassThru) { $executeResult }
exit 0
