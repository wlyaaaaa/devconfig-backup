Set-StrictMode -Version 2.0

$script:BackupScheduledTaskNames = @(
    'DevConfigBackup-Local',
    'DevConfigBackup-Drive-Daily',
    'WeChatBackup-Hot-Daily',
    'WeChatBackup-Drive-Weekly'
)

function ConvertTo-BackupScheduledTaskValue {
    param($Value)

    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        return (@($Value | ForEach-Object { ConvertTo-BackupScheduledTaskValue $_ }) -join ',')
    }
    return [string]$Value
}

function Test-BackupScheduledTaskPropertySet {
    param($Actual, $Expected, [string[]] $Properties)

    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    foreach ($property in $Properties) {
        $actualProperty = $Actual.PSObject.Properties[$property]
        $expectedProperty = $Expected.PSObject.Properties[$property]
        if ($null -eq $actualProperty -or $null -eq $expectedProperty) { return $false }
        if (-not [string]::Equals(
                (ConvertTo-BackupScheduledTaskValue $actualProperty.Value),
                (ConvertTo-BackupScheduledTaskValue $expectedProperty.Value),
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            return $false
        }
    }
    return $true
}

function Get-BackupScheduledTaskTriggerSignature {
    param($Trigger)

    if ($null -eq $Trigger) { return '<null>' }
    $kind = $null
    if ($Trigger.PSObject.Properties['Type']) {
        $kind = [string]$Trigger.Type
    } elseif ($Trigger.PSObject.Properties['CimClass'] -and $Trigger.CimClass) {
        $kind = [string]$Trigger.CimClass.CimClassName
    }
    $parts = @('kind=' + $kind)
    foreach ($property in @(
        'At', 'StartBoundary', 'EndBoundary', 'Enabled', 'User', 'UserId', 'Delay',
        'DaysInterval', 'WeeksInterval', 'DaysOfWeek', 'RandomDelay'
    )) {
        $value = $Trigger.PSObject.Properties[$property]
        if ($null -ne $value) {
            $parts += ('{0}={1}' -f $property, (ConvertTo-BackupScheduledTaskValue $value.Value))
        }
    }
    return ($parts -join ';')
}

function Test-BackupScheduledTaskAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Task,
        [Parameter(Mandatory = $true)] $ExpectedAction
    )

    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    return Test-BackupScheduledTaskPropertySet -Actual $actions[0] -Expected $ExpectedAction `
        -Properties @('Execute', 'Arguments', 'WorkingDirectory')
}

function Test-BackupScheduledTaskDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Task,
        [Parameter(Mandatory = $true)] $Definition
    )

    if (-not (Test-BackupScheduledTaskAction -Task $Task -ExpectedAction $Definition.Action)) { return $false }
    if (-not (Test-BackupScheduledTaskPropertySet -Actual $Task.Principal -Expected $Definition.Principal `
            -Properties @('UserId', 'LogonType', 'RunLevel'))) { return $false }
    if (-not (Test-BackupScheduledTaskPropertySet -Actual $Task.Settings -Expected $Definition.Settings `
            -Properties @(
                'StartWhenAvailable', 'RunOnlyIfNetworkAvailable', 'AllowStartIfOnBatteries',
                'DontStopIfGoingOnBatteries', 'MultipleInstances', 'ExecutionTimeLimit',
                'RestartCount', 'RestartInterval'
            ))) { return $false }

    $actualTriggers = @($Task.Triggers)
    $expectedTriggers = @($Definition.Triggers)
    if ($actualTriggers.Count -ne $expectedTriggers.Count) { return $false }
    for ($index = 0; $index -lt $expectedTriggers.Count; $index++) {
        if (-not [string]::Equals(
                (Get-BackupScheduledTaskTriggerSignature $actualTriggers[$index]),
                (Get-BackupScheduledTaskTriggerSignature $expectedTriggers[$index]),
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
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

function Get-BackupScheduledTaskLookup {
    param([hashtable] $Api, [string] $Name)

    $getTask = $Api.GetTask
    if ($null -eq $getTask) { throw 'Scheduled task API must provide GetTask.' }
    $lookup = @(& $getTask $Name) | Select-Object -First 1
    if ($null -eq $lookup) { throw "Scheduled task lookup returned no state for: $Name" }
    $status = ([string]$lookup.Status).ToLowerInvariant()
    if ($status -eq 'found' -and $null -ne $lookup.Task) { return $lookup }
    if ($status -eq 'absent' -and $null -eq $lookup.Task) { return $lookup }
    throw "Scheduled task lookup is not safely resolved for $Name (status=$status)."
}

function Get-BackupScheduledTaskPreimages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Definitions,
        [Parameter(Mandatory = $true)] [hashtable] $Api
    )

    Assert-BackupScheduledTaskDefinitions -Definitions $Definitions
    $exportTask = $Api.ExportTask
    if ($null -eq $exportTask) { throw 'Scheduled task API must provide ExportTask.' }

    $preimages = @()
    foreach ($definition in $Definitions) {
        $lookup = Get-BackupScheduledTaskLookup -Api $Api -Name $definition.Name
        if ($lookup.Status -eq 'absent') {
            $preimages += [pscustomobject]@{ Name = $definition.Name; Exists = $false; Xml = $null }
            continue
        }

        if (-not (Test-BackupScheduledTaskAction -Task $lookup.Task -ExpectedAction $definition.Action)) {
            throw "Refusing to replace non-owned scheduled task: $($definition.Name)"
        }
        $xml = [string](& $exportTask $definition.Name)
        if ([string]::IsNullOrWhiteSpace($xml)) {
            throw "Unable to capture an exact XML preimage for scheduled task: $($definition.Name)"
        }
        $preimages += [pscustomobject]@{ Name = $definition.Name; Exists = $true; Xml = $xml }
    }
    return $preimages
}

function Restore-BackupScheduledTaskPreimages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]] $Definitions,
        [Parameter(Mandatory = $true)] [object[]] $Preimages,
        [Parameter(Mandatory = $true)] [hashtable] $Mutations,
        [Parameter(Mandatory = $true)] [hashtable] $Api
    )

    $registerXml = $Api.RegisterXml
    $unregisterTask = $Api.UnregisterTask
    if ($null -eq $registerXml -or $null -eq $unregisterTask) {
        throw 'Scheduled task API must provide RegisterXml and UnregisterTask for rollback.'
    }

    foreach ($preimage in $Preimages) {
        $definition = @($Definitions | Where-Object { $_.Name -ceq $preimage.Name }) | Select-Object -First 1
        $mutation = $Mutations[$preimage.Name]
        if ($null -eq $definition -or $null -eq $mutation) {
            throw "Rollback metadata is incomplete for scheduled task: $($preimage.Name)"
        }

        if ($preimage.Exists) {
            # Direct in-place XML restore avoids a crash window with no task.
            & $registerXml $preimage.Name $preimage.Xml
            $restored = Get-BackupScheduledTaskLookup -Api $Api -Name $preimage.Name
            if ($restored.Status -ne 'found' -or
                -not (Test-BackupScheduledTaskAction -Task $restored.Task -ExpectedAction $definition.Action)) {
                throw "Rollback XML readback failed for scheduled task: $($preimage.Name)"
            }
            continue
        }

        $current = Get-BackupScheduledTaskLookup -Api $Api -Name $preimage.Name
        if ($mutation.CreatedConfirmed) {
            if ($current.Status -eq 'found') {
                if (-not (Test-BackupScheduledTaskDefinition -Task $current.Task -Definition $definition)) {
                    throw "Rollback refuses to remove a task whose definition no longer matches this transaction: $($preimage.Name)"
                }
                & $unregisterTask $preimage.Name
                $removed = Get-BackupScheduledTaskLookup -Api $Api -Name $preimage.Name
                if ($removed.Status -ne 'absent') {
                    throw "Rollback could not remove a task that was absent before registration: $($preimage.Name)"
                }
            }
        } elseif ($mutation.CreatedAttempted -and $current.Status -eq 'found') {
            throw "Rollback cannot prove ownership of a partially created task: $($preimage.Name)"
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
    $registerDefinition = $Api.RegisterDefinition
    if ($null -eq $registerDefinition) { throw 'Scheduled task API must provide RegisterDefinition.' }
    $preimages = @(Get-BackupScheduledTaskPreimages -Definitions $Definitions -Api $Api)
    $mutations = @{}

    try {
        foreach ($definition in $Definitions) {
            $preimage = @($preimages | Where-Object { $_.Name -ceq $definition.Name }) | Select-Object -First 1
            $current = Get-BackupScheduledTaskLookup -Api $Api -Name $definition.Name
            if ($preimage.Exists) {
                if ($current.Status -ne 'found' -or
                    -not (Test-BackupScheduledTaskAction -Task $current.Task -ExpectedAction $definition.Action)) {
                    throw "Refusing to update a task whose wrapper ownership changed: $($definition.Name)"
                }
            } elseif ($current.Status -ne 'absent') {
                throw "Refusing to create a task whose absence is no longer proven: $($definition.Name)"
            }

            $mutation = [pscustomobject]@{
                CreatedAttempted = (-not $preimage.Exists)
                CreatedConfirmed = $false
            }
            $mutations[$definition.Name] = $mutation
            # Existing verified tasks are updated in place; verified absence creates without -Force.
            & $registerDefinition $definition ([bool]$preimage.Exists)
            $readback = Get-BackupScheduledTaskLookup -Api $Api -Name $definition.Name
            if ($readback.Status -ne 'found' -or
                -not (Test-BackupScheduledTaskDefinition -Task $readback.Task -Definition $definition)) {
                throw "Definition readback failed for scheduled task: $($definition.Name)"
            }
            if (-not $preimage.Exists) { $mutation.CreatedConfirmed = $true }
        }

        foreach ($definition in $Definitions) {
            $readback = Get-BackupScheduledTaskLookup -Api $Api -Name $definition.Name
            if ($readback.Status -ne 'found' -or
                -not (Test-BackupScheduledTaskDefinition -Task $readback.Task -Definition $definition)) {
                throw "Final definition readback failed for scheduled task: $($definition.Name)"
            }
        }
    } catch {
        $registrationFailure = $_.Exception.Message
        try {
            $affectedPreimages = @($preimages | Where-Object { $mutations.ContainsKey($_.Name) })
            Restore-BackupScheduledTaskPreimages -Definitions $Definitions -Preimages $affectedPreimages -Mutations $mutations -Api $Api
        } catch {
            throw "Scheduled task registration failed: $registrationFailure Rollback also failed: $($_.Exception.Message)"
        }
        throw "Scheduled task registration failed: $registrationFailure Exact preimages were restored."
    }

    return [pscustomobject]@{ Success = $true; Names = @($Definitions | ForEach-Object { $_.Name }) }
}
