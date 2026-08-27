Set-StrictMode -Version 2.0

function Resolve-NativeWeChatRecoveryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A recovery path is required.'
    }

    $unresolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $fullPath = [System.IO.Path]::GetFullPath($unresolved)
    $trimChars = [char[]]@([char]'\', [char]'/' )
    $pathWithoutTrailingSeparator = $fullPath.TrimEnd($trimChars)
    $root = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd($trimChars)

    if ([string]::IsNullOrWhiteSpace($pathWithoutTrailingSeparator) -or
        [string]::Equals($pathWithoutTrailingSeparator, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use a drive root as a WeChat recovery target: $Path"
    }

    return $pathWithoutTrailingSeparator
}

function Test-NativeWeChatPathsEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Left,
        [Parameter(Mandatory = $true)] [string] $Right
    )

    return [string]::Equals(
        (Resolve-NativeWeChatRecoveryPath -Path $Left),
        (Resolve-NativeWeChatRecoveryPath -Path $Right),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-NativeWeChatPathIsSameOrDescendant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Ancestor,
        [Parameter(Mandatory = $true)] [string] $Candidate
    )

    $ancestorPath = Resolve-NativeWeChatRecoveryPath -Path $Ancestor
    $candidatePath = Resolve-NativeWeChatRecoveryPath -Path $Candidate
    if (Test-NativeWeChatPathsEqual -Left $ancestorPath -Right $candidatePath) {
        return $true
    }

    return $candidatePath.StartsWith(
        ($ancestorPath + [System.IO.Path]::DirectorySeparatorChar),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-NativeWeChatPathsOverlap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Left,
        [Parameter(Mandatory = $true)] [string] $Right
    )

    return (Test-NativeWeChatPathIsSameOrDescendant -Ancestor $Left -Candidate $Right) -or
        (Test-NativeWeChatPathIsSameOrDescendant -Ancestor $Right -Candidate $Left)
}

function Get-NativeWeChatReparsePointPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path
    )

    $current = Resolve-NativeWeChatRecoveryPath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                return $item.FullName
            }
        }

        $parentInfo = [System.IO.Directory]::GetParent($current)
        $parent = if ($null -eq $parentInfo) { $null } else { $parentInfo.FullName }
        if ([string]::IsNullOrWhiteSpace($parent) -or
            [string]::Equals($parent, $current, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
    }
    return $null
}

function Get-NativeWeChatPathState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $fullPath = Resolve-NativeWeChatRecoveryPath -Path $Path
    $reparsePointPath = Get-NativeWeChatReparsePointPath -Path $fullPath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return [pscustomobject]@{
            Path = $fullPath
            Exists = $false
            IsDirectory = $false
            IsReparsePoint = $false
            ReparsePointPath = $reparsePointPath
            HasEntries = $false
        }
    }

    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    $isDirectory = [bool]$item.PSIsContainer
    $isReparsePoint = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    $hasEntries = $false
    if ($isDirectory) {
        $hasEntries = $null -ne (Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction Stop | Select-Object -First 1)
    }

    return [pscustomobject]@{
        Path = $fullPath
        Exists = $true
        IsDirectory = $isDirectory
        IsReparsePoint = $isReparsePoint
        ReparsePointPath = $reparsePointPath
        HasEntries = $hasEntries
    }
}

function Get-NativeWeChatClientState {
    [CmdletBinding()]
    param()

    $processes = @()
    foreach ($name in @('WeChat', 'Weixin', 'WeChatApp')) {
        $processes += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }
    $processes = @($processes | Sort-Object -Property Id -Unique)

    return [pscustomobject]@{
        Detected = ($processes.Count -gt 0)
        ProcessNames = @($processes | ForEach-Object { $_.ProcessName })
        ProcessIds = @($processes | ForEach-Object { $_.Id })
        DetectionScope = 'known official WeChat process names only; it cannot prove that no file lock exists'
    }
}

function Get-NativeWeChatClientCandidates {
    [CmdletBinding()]
    param(
        [string[]] $AdditionalCandidatePaths = @()
    )

    $candidatePaths = @()
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidatePaths += Join-Path $root 'Tencent\WeChat\WeChat.exe'
            $candidatePaths += Join-Path $root 'Tencent\Weixin\Weixin.exe'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidatePaths += Join-Path $env:LOCALAPPDATA 'Programs\WeChat\WeChat.exe'
        $candidatePaths += Join-Path $env:LOCALAPPDATA 'Programs\Weixin\Weixin.exe'
    }
    $candidatePaths += @($AdditionalCandidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $candidatePaths = @($candidatePaths | Select-Object -Unique)

    $candidates = @()
    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $item = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
            $candidates += [pscustomobject]@{
                Path = $item.FullName
                Version = $item.VersionInfo.ProductVersion
            }
        }
    }
    return $candidates
}

function Assert-NativeWeChatPathHasNoReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $PathState,
        [Parameter(Mandatory = $true)] [string] $Role
    )

    if (-not [string]::IsNullOrWhiteSpace($PathState.ReparsePointPath)) {
        throw "The $Role path or one of its parents is a reparse point: $($PathState.ReparsePointPath)"
    }
}

function Assert-NativeWeChatLocalCopyPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Target
    )

    $sourceState = Get-NativeWeChatPathState -Path $Source
    $targetState = Get-NativeWeChatPathState -Path $Target
    if (-not $sourceState.Exists -or -not $sourceState.IsDirectory -or -not $sourceState.HasEntries) {
        throw "The native WeChat backup source is missing, not a directory, or empty: $($sourceState.Path)"
    }
    if ($targetState.Exists -and -not $targetState.IsDirectory) {
        throw "The native WeChat target exists but is not a directory: $($targetState.Path)"
    }
    Assert-NativeWeChatPathHasNoReparsePoint -PathState $sourceState -Role 'backup source'
    Assert-NativeWeChatPathHasNoReparsePoint -PathState $targetState -Role 'target'
    if (Test-NativeWeChatPathsOverlap -Left $sourceState.Path -Right $targetState.Path) {
        throw "The native WeChat backup source and target overlap: $($sourceState.Path) <-> $($targetState.Path)"
    }

    return [pscustomobject]@{
        SourceState = $sourceState
        TargetState = $targetState
    }
}

function Assert-NativeWeChatTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Target
    )

    $targetState = Get-NativeWeChatPathState -Path $Target
    if ($targetState.Exists -and -not $targetState.IsDirectory) {
        throw "The native WeChat target exists but is not a directory: $($targetState.Path)"
    }
    Assert-NativeWeChatPathHasNoReparsePoint -PathState $targetState -Role 'target'
    return $targetState
}

function Get-NativeWeChatSiblingPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Target,
        [Parameter(Mandatory = $true)] [ValidateSet('pre-restore', 'failed-restore')] [string] $Kind
    )

    $suffix = Get-Date -Format 'yyyyMMdd-HHmmss'
    $candidate = '{0}.{1}-{2}' -f $Target, $Kind, $suffix
    $number = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = '{0}.{1}-{2}-{3}' -f $Target, $Kind, $suffix, $number
        $number++
    }
    return $candidate
}

function Move-NativeWeChatTargetToRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Target,
        [Parameter(Mandatory = $true)] [string] $Rollback
    )

    $targetState = Assert-NativeWeChatTargetPath -Target $Target
    if (-not $targetState.Exists -or -not $targetState.IsDirectory) {
        throw "The target is unavailable for rollback: $($targetState.Path)"
    }
    $rollbackState = Assert-NativeWeChatTargetPath -Target $Rollback
    if ($rollbackState.Exists) {
        throw "The rollback path already exists: $($rollbackState.Path)"
    }

    Move-Item -LiteralPath $targetState.Path -Destination $rollbackState.Path -ErrorAction Stop
}

function Invoke-NativeWeChatLocalCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Target
    )

    $pathStates = Assert-NativeWeChatLocalCopyPaths -Source $Source -Target $Target
    $sourceState = $pathStates.SourceState
    $targetState = $pathStates.TargetState

    New-Item -ItemType Directory -Path $targetState.Path -Force -ErrorAction Stop | Out-Null
    $arguments = @(
        $sourceState.Path, $targetState.Path,
        '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/MT:8', '/XJ',
        '/NP', '/NDL', '/NFL'
    )
    & robocopy @arguments | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 3) {
        throw "robocopy reported mismatched or failed native WeChat application data (exit=$exitCode)."
    }

    return [pscustomobject]@{
        Method = 'robocopy'
        ExitCode = $exitCode
    }
}

function Restore-NativeWeChatRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Target,
        [Parameter(Mandatory = $true)] [string] $Rollback
    )

    $rollbackState = Assert-NativeWeChatTargetPath -Target $Rollback
    if (-not $rollbackState.Exists -or -not $rollbackState.IsDirectory) {
        throw "Rollback directory is unavailable: $($rollbackState.Path)"
    }
    $targetState = Assert-NativeWeChatTargetPath -Target $Target

    $failedPath = $null
    if ($targetState.Exists) {
        $failedPath = Get-NativeWeChatSiblingPath -Target $targetState.Path -Kind 'failed-restore'
        $failedState = Assert-NativeWeChatTargetPath -Target $failedPath
        if ($failedState.Exists) {
            throw "The failed-restore path already exists: $($failedState.Path)"
        }
        Move-Item -LiteralPath $targetState.Path -Destination $failedState.Path -ErrorAction Stop
    }
    Move-Item -LiteralPath $rollbackState.Path -Destination $targetState.Path -ErrorAction Stop

    return [pscustomobject]@{
        Restored = $true
        FailedRestorePath = $failedPath
    }
}
