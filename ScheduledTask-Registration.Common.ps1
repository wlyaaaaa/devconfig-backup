Set-StrictMode -Version 2.0

$script:BackupScheduledTaskNames = @(
    'DevConfigBackup-Local',
    'DevConfigBackup-Drive-Daily',
    'WeChatBackup-Hot-Daily',
    'WeChatBackup-Drive-Weekly'
)

function Test-BackupScheduledTaskAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Task,
        [Parameter(Mandatory = $true)] $ExpectedAction
    )

    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }

    $actualAction = $actions[0]
    foreach ($property in @('Execute', 'Arguments', 'WorkingDirectory')) {
        $actualValue = ([string]$actualAction.$property).Trim()
        $expectedValue = ([string]$ExpectedAction.$property).Trim()
        if (-not [string]::Equals($actualValue, $expectedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Assert-BackupScheduledTaskDefinitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Definitions
    )

    $names = @($Definitions | ForEach-Object { [string]$_.Name })
    if ($names.Count -ne $script:BackupScheduledTaskNames.Count -or
        @(Compare-Object -ReferenceObject $script:BackupScheduledTaskNames -DifferenceObject $names).Count -gt 0) {
        throw 'Scheduled task definitions must contain exactly the four owned backup task names.'
    }
    if (@($names | Select-Object -Unique).Count -ne $names.Count) {
        throw 'Scheduled task definitions contain duplicate names.'
    }
}

function Get-BackupScheduledTaskPreimages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Definitions,
        [Parameter(Mandatory = $true)] [hashtable] $Api
    )

    Assert-BackupScheduledTaskDefinitions -Definitions $Definitions
    $getTask = $Api.GetTask
    $exportTask = $Api.ExportTask
    if ($null -eq $getTask -or $null -eq $exportTask) {
        throw 'Scheduled task API must provide GetTask and ExportTask.'
    }

    $preimages = @()
    foreach ($definition in $Definitions) {
        $current = @(& $getTask $definition.Name) | Select-Object -First 1
        if ($null -eq $current) {
            $preimages += [pscustomobject]@{
                Name = $definition.Name
                Exists = $false
                Xml = $null
            }
            continue
        }

        if (-not (Test-BackupScheduledTaskAction -Task $current -ExpectedAction $definition.Action)) {
            throw "Refusing to replace non-owned scheduled task: $($definition.Name)"
        }
        $xml = [string](& $exportTask $definition.Name)
        if ([string]::IsNullOrWhiteSpace($xml)) {
            throw "Unable to capture an exact XML preimage for scheduled task: $($definition.Name)"
        }
        $preimages += [pscustomobject]@{
            Name = $definition.Name
            Exists = $true
            Xml = $xml
        }
    }
    return $preimages
}

function Restore-BackupScheduledTaskPreimages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Definitions,
        [Parameter(Mandatory = $true)] [object[]] $Preimages,
        [Parameter(Mandatory = $true)] [hashtable] $Api
    )

    $getTask = $Api.GetTask
    $unregisterTask = $Api.UnregisterTask
    $registerXml = $Api.RegisterXml
    if ($null -eq $getTask -or $null -eq $unregisterTask -or $null -eq $registerXml) {
        throw 'Scheduled task API must provide GetTask, UnregisterTask, and RegisterXml for rollback.'
    }

    foreach ($preimage in $Preimages) {
        $definition = @($Definitions | Where-Object { $_.Name -ceq $preimage.Name }) | Select-Object -First 1
        if ($null -eq $definition) {
            throw "No definition is available to restore scheduled task: $($preimage.Name)"
        }

        $current = @(& $getTask $preimage.Name) | Select-Object -First 1
        if ($preimage.Exists) {
            if ($null -ne $current) {
                if (-not (Test-BackupScheduledTaskAction -Task $current -ExpectedAction $definition.Action)) {
                    throw "Rollback refuses to remove a non-owned scheduled task: $($preimage.Name)"
                }
                & $unregisterTask $preimage.Name
            }
            & $registerXml $preimage.Name $preimage.Xml
            $restored = @(& $getTask $preimage.Name) | Select-Object -First 1
            if ($null -eq $restored -or -not (Test-BackupScheduledTaskAction -Task $restored -ExpectedAction $definition.Action)) {
                throw "Rollback XML readback failed for scheduled task: $($preimage.Name)"
            }
        } elseif ($null -ne $current) {
            if (-not (Test-BackupScheduledTaskAction -Task $current -ExpectedAction $definition.Action)) {
                throw "Rollback refuses to remove a non-owned scheduled task created during registration: $($preimage.Name)"
            }
            & $unregisterTask $preimage.Name
            $removed = @(& $getTask $preimage.Name) | Select-Object -First 1
            if ($null -ne $removed) {
                throw "Rollback could not remove a task that was absent before registration: $($preimage.Name)"
            }
        }
    }
}

function Invoke-BackupScheduledTaskRegistrationTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Definitions,
        [Parameter(Mandatory = $true)] [hashtable] $Api
    )

    Assert-BackupScheduledTaskDefinitions -Definitions $Definitions
    $getTask = $Api.GetTask
    $unregisterTask = $Api.UnregisterTask
    $registerDefinition = $Api.RegisterDefinition
    if ($null -eq $getTask -or $null -eq $unregisterTask -or $null -eq $registerDefinition) {
        throw 'Scheduled task API must provide GetTask, UnregisterTask, and RegisterDefinition.'
    }

    # Capture every exact XML preimage before the first mutation.  Foreign tasks abort here.
    $preimages = @(Get-BackupScheduledTaskPreimages -Definitions $Definitions -Api $Api)

    $mutatedNames = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($definition in $Definitions) {
            # Re-read immediately before mutation to avoid deleting a same-name task changed after preflight.
            $current = @(& $getTask $definition.Name) | Select-Object -First 1
            if ($null -ne $current) {
                if (-not (Test-BackupScheduledTaskAction -Task $current -ExpectedAction $definition.Action)) {
                    throw "Refusing to replace non-owned scheduled task: $($definition.Name)"
                }
                [void]$mutatedNames.Add($definition.Name)
                & $unregisterTask $definition.Name
            } else {
                [void]$mutatedNames.Add($definition.Name)
            }

            & $registerDefinition $definition
            $readback = @(& $getTask $definition.Name) | Select-Object -First 1
            if ($null -eq $readback -or -not (Test-BackupScheduledTaskAction -Task $readback -ExpectedAction $definition.Action)) {
                throw "Definition readback failed for scheduled task: $($definition.Name)"
            }
        }

        # Do not report success until every exact target is still present and owned by this setup script.
        foreach ($definition in $Definitions) {
            $readback = @(& $getTask $definition.Name) | Select-Object -First 1
            if ($null -eq $readback -or -not (Test-BackupScheduledTaskAction -Task $readback -ExpectedAction $definition.Action)) {
                throw "Final definition readback failed for scheduled task: $($definition.Name)"
            }
        }
    } catch {
        $registrationFailure = $_.Exception.Message
        try {
            $affectedPreimages = @($preimages | Where-Object { $mutatedNames -contains $_.Name })
            Restore-BackupScheduledTaskPreimages -Definitions $Definitions -Preimages $affectedPreimages -Api $Api
        } catch {
            throw "Scheduled task registration failed: $registrationFailure Rollback also failed: $($_.Exception.Message)"
        }
        throw "Scheduled task registration failed: $registrationFailure Exact preimages were restored."
    }

    return [pscustomobject]@{
        Success = $true
        Names = @($Definitions | ForEach-Object { $_.Name })
    }
}
