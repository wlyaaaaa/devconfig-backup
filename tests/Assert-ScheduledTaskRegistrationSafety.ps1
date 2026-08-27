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

function New-TestAction {
    param([string] $Tier)
    [pscustomobject]@{
        Execute = 'C:\Windows\System32\wscript.exe'
        Arguments = ('"E:\synthetic\wrapper.vbs" ' + $Tier)
        WorkingDirectory = 'E:\synthetic'
    }
}

function New-TestPrincipal {
    [pscustomobject]@{ UserId = 'test-user'; LogonType = 'Interactive'; RunLevel = 'Limited' }
}

function New-TestSettings {
    param([bool] $Network, [int] $RestartCount, [int] $Hours, [int] $Minutes)
    [pscustomobject]@{
        StartWhenAvailable = $true
        RunOnlyIfNetworkAvailable = $Network
        AllowStartIfOnBatteries = $true
        DontStopIfGoingOnBatteries = $true
        MultipleInstances = 'IgnoreNew'
        ExecutionTimeLimit = [TimeSpan]::FromHours($Hours)
        RestartCount = $RestartCount
        RestartInterval = [TimeSpan]::FromMinutes($Minutes)
    }
}

function New-TestTrigger {
    param([string] $Type, [string] $At, [string] $User = '', [string] $DaysOfWeek = '', [string] $Delay = '')
    [pscustomobject]@{ Type = $Type; At = $At; User = $User; DaysOfWeek = $DaysOfWeek; Delay = $Delay }
}

function New-TestDefinitions {
    $principal = New-TestPrincipal
    @(
        [pscustomobject]@{
            Name = 'DevConfigBackup-Local'; Action = New-TestAction 'Local,Hot'; Principal = $principal
            Triggers = @((New-TestTrigger 'daily' '21:05'), (New-TestTrigger 'logon' '' 'test-user' '' 'PT20M'))
            Settings = New-TestSettings $false 3 2 10; Description = 'local'
        },
        [pscustomobject]@{
            Name = 'DevConfigBackup-Drive-Daily'; Action = New-TestAction 'Drive'; Principal = $principal
            Triggers = @((New-TestTrigger 'daily' '22:00'))
            Settings = New-TestSettings $true 3 3 15; Description = 'drive'
        },
        [pscustomobject]@{
            Name = 'WeChatBackup-Hot-Daily'; Action = New-TestAction 'Hot'; Principal = $principal
            Triggers = @((New-TestTrigger 'daily' '18:30'))
            Settings = New-TestSettings $false 3 4 15; Description = 'wechat-hot'
        },
        [pscustomobject]@{
            Name = 'WeChatBackup-Drive-Weekly'; Action = New-TestAction 'Drive'; Principal = $principal
            Triggers = @((New-TestTrigger 'weekly' '20:00' '' 'Sunday'))
            Settings = New-TestSettings $true 5 8 30; Description = 'wechat-drive'
        }
    )
}

function New-TestTask {
    param($Definition, [string] $Xml, [hashtable] $Overrides = @{})

    $task = [pscustomobject]@{
        TaskName = $Definition.Name
        State = 'Ready'
        Actions = @($Definition.Action)
        Principal = $Definition.Principal
        Triggers = @($Definition.Triggers)
        Settings = $Definition.Settings
        Description = $Definition.Description
        Xml = $Xml
    }
    foreach ($key in $Overrides.Keys) { $task.$key = $Overrides[$key] }
    return $task
}

function New-DriftedSettings {
    param($Settings)
    $copy = $Settings.PSObject.Copy()
    $copy.RestartCount = [int]$Settings.RestartCount + 1
    return $copy
}

function New-TestTaskApi {
    param(
        [hashtable] $Store,
        [object[]] $Definitions,
        [System.Collections.ArrayList] $Events,
        [string] $FailRegisterName = '',
        [string] $DriftRegisterName = '',
        [string[]] $BlockedNames = @()
    )

    $xmlToTask = @{}
    foreach ($name in @($Store.Keys)) { $xmlToTask[$Store[$name].Xml] = $Store[$name] }

    $getTask = {
        param([string] $Name)
        if ($BlockedNames -contains $Name) { return [pscustomobject]@{ Status = 'blocked'; Task = $null } }
        if ($Store.ContainsKey($Name)) { return [pscustomobject]@{ Status = 'found'; Task = $Store[$Name] } }
        return [pscustomobject]@{ Status = 'absent'; Task = $null }
    }.GetNewClosure()
    $exportTask = {
        param([string] $Name)
        if (-not $Store.ContainsKey($Name)) { throw "missing task export: $Name" }
        return $Store[$Name].Xml
    }.GetNewClosure()
    $unregisterTask = {
        param([string] $Name)
        [void]$Events.Add("unregister:$Name")
        [void]$Store.Remove($Name)
    }.GetNewClosure()
    $registerXml = {
        param([string] $Name, [string] $Xml)
        [void]$Events.Add("restore:$Name")
        if (-not $xmlToTask.ContainsKey($Xml)) { throw "unknown XML fixture: $Xml" }
        $Store[$Name] = $xmlToTask[$Xml]
    }.GetNewClosure()
    $registerDefinition = {
        param($Definition, [bool] $ReplaceExisting)
        [void]$Events.Add("register:$($Definition.Name):force=$ReplaceExisting")
        if ($Definition.Name -ceq $FailRegisterName) { throw "synthetic runtime registration failure: $($Definition.Name)" }
        $overrides = @{}
        if ($Definition.Name -ceq $DriftRegisterName) { $overrides['Settings'] = New-DriftedSettings $Definition.Settings }
        $Store[$Definition.Name] = New-TestTask -Definition $Definition -Xml ("new:$($Definition.Name)") -Overrides $overrides
    }.GetNewClosure()

    @{
        GetTask = $getTask
        ExportTask = $exportTask
        UnregisterTask = $unregisterTask
        RegisterXml = $registerXml
        RegisterDefinition = $registerDefinition
    }
}

$commonPath = Join-Path $RepoRoot 'ScheduledTask-Registration.Common.ps1'
$setupPath = Join-Path $RepoRoot 'Setup-ScheduledTasks.ps1'
$setupText = Get-Content -LiteralPath $setupPath -Raw
Assert-Condition ($setupText -match 'Invoke-BackupScheduledTaskRegistrationTransaction') 'Setup must use the transactional registration helper.'
Assert-Condition ($setupText -notmatch "TaskName 'DevConfigBackup-\*'|TaskName 'WeChatBackup-\*'|Unregister-ScheduledTask -InputObject") 'Setup must not wildcard-delete backup task prefixes.'
. $commonPath
$definitions = New-TestDefinitions

# A same-name task with another wrapper is foreign and must not be replaced.
$foreignAction = New-TestAction 'Foreign'
$foreignStore = @{
    'DevConfigBackup-Local' = New-TestTask -Definition $definitions[0] -Xml 'xml:foreign' -Overrides @{ Actions = @($foreignAction) }
    'DevConfigBackup-Other' = New-TestTask -Definition $definitions[0] -Xml 'xml:other' -Overrides @{ Actions = @($foreignAction) }
}
$foreignEvents = New-Object System.Collections.ArrayList
$foreignApi = New-TestTaskApi -Store $foreignStore -Definitions $definitions -Events $foreignEvents
$foreignRejected = $false
try { Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $foreignApi | Out-Null } catch { $foreignRejected = $_.Exception.Message -match 'non-owned' }
Assert-Condition $foreignRejected 'A same-name foreign task must block registration.'
Assert-Condition ($foreignEvents.Count -eq 0) 'Foreign-task preflight must not mutate any task.'
Assert-Condition ($foreignStore.ContainsKey('DevConfigBackup-Other')) 'A foreign prefix task must remain untouched.'

# Inaccessible or hidden state is not absence and must fail closed without -Force.
$blockedStore = @{}
$blockedEvents = New-Object System.Collections.ArrayList
$blockedApi = New-TestTaskApi -Store $blockedStore -Definitions $definitions -Events $blockedEvents -BlockedNames @('DevConfigBackup-Drive-Daily')
$blockedRejected = $false
try { Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $blockedApi | Out-Null } catch { $blockedRejected = $_.Exception.Message -match 'not safely resolved' }
Assert-Condition $blockedRejected 'An inaccessible task state must not be treated as absent.'
Assert-Condition ($blockedEvents.Count -eq 0) 'Blocked task lookup must not register or force-update anything.'

# Existing owner tasks update in place.  A runtime failure restores XML without any unregister gap.
$existingStore = @{}
foreach ($definition in $definitions) { $existingStore[$definition.Name] = New-TestTask -Definition $definition -Xml ("xml:old:$($definition.Name)") }
$existingEvents = New-Object System.Collections.ArrayList
$existingApi = New-TestTaskApi -Store $existingStore -Definitions $definitions -Events $existingEvents -FailRegisterName 'DevConfigBackup-Drive-Daily'
$existingRolledBack = $false
try { Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $existingApi | Out-Null } catch { $existingRolledBack = $_.Exception.Message -match 'Exact preimages were restored' }
Assert-Condition $existingRolledBack 'Runtime registration failure must restore existing XML preimages.'
Assert-Condition (@($existingEvents | Where-Object { $_ -like 'unregister:*' }).Count -eq 0) 'Existing tasks must never be unregistered during update or rollback.'
Assert-Condition (@($existingEvents | Where-Object { $_ -like '*:force=True' }).Count -eq 2) 'Only verified existing tasks may use -Force before the failure.'
foreach ($definition in $definitions) {
    Assert-Condition ($existingStore[$definition.Name].Xml -ceq ("xml:old:$($definition.Name)")) "Existing XML preimage was not restored for $($definition.Name)."
}

# Previously absent tasks can be removed on rollback only after a matching definition was read back.
$mixedStore = @{
    'DevConfigBackup-Local' = New-TestTask -Definition $definitions[0] -Xml 'xml:local-old'
    'DevConfigBackup-Drive-Daily' = New-TestTask -Definition $definitions[1] -Xml 'xml:drive-old'
    'WeChatBackup-Drive-Weekly' = New-TestTask -Definition $definitions[3] -Xml 'xml:weekly-old'
}
$mixedEvents = New-Object System.Collections.ArrayList
$mixedApi = New-TestTaskApi -Store $mixedStore -Definitions $definitions -Events $mixedEvents -FailRegisterName 'WeChatBackup-Drive-Weekly'
$mixedRolledBack = $false
try { Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $mixedApi | Out-Null } catch { $mixedRolledBack = $_.Exception.Message -match 'Exact preimages were restored' }
Assert-Condition $mixedRolledBack 'Failure after an absent task is created must roll back exact preimages.'
Assert-Condition (-not $mixedStore.ContainsKey('WeChatBackup-Hot-Daily')) 'A confirmed task absent before registration must be removed during rollback.'
Assert-Condition (@($mixedEvents | Where-Object { $_ -eq 'unregister:WeChatBackup-Hot-Daily' }).Count -eq 1) 'Only the confirmed newly created task may be deleted during rollback.'
Assert-Condition (@($mixedEvents | Where-Object { $_ -like 'unregister:DevConfig*' -or $_ -like 'unregister:WeChatBackup-Drive-Weekly' }).Count -eq 0) 'Existing tasks must not be deleted during mixed rollback.'

# Readback validates action, principal, triggers, and settings; a settings drift restores XML.
$driftStore = @{
    'DevConfigBackup-Local' = New-TestTask -Definition $definitions[0] -Xml 'xml:drift-local'
}
$driftEvents = New-Object System.Collections.ArrayList
$driftApi = New-TestTaskApi -Store $driftStore -Definitions $definitions -Events $driftEvents -DriftRegisterName 'DevConfigBackup-Local'
$driftRolledBack = $false
try { Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $driftApi | Out-Null } catch { $driftRolledBack = $_.Exception.Message -match 'Definition readback failed' -and $_.Exception.Message -match 'Exact preimages were restored' }
Assert-Condition $driftRolledBack 'Readback settings drift must trigger exact XML rollback.'
Assert-Condition ($driftStore['DevConfigBackup-Local'].Xml -ceq 'xml:drift-local') 'Settings-drift rollback did not restore XML preimage.'

# Fully absent definitions create without -Force and pass the complete definition comparator.
$successStore = @{}
$successEvents = New-Object System.Collections.ArrayList
$successApi = New-TestTaskApi -Store $successStore -Definitions $definitions -Events $successEvents
$success = Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $successApi
Assert-Condition $success.Success 'Successful registration transaction did not report success.'
Assert-Condition (@($successEvents | Where-Object { $_ -like '*:force=True' }).Count -eq 0) 'Verified absence must create without -Force.'
foreach ($definition in $definitions) {
    Assert-Condition (Test-BackupScheduledTaskDefinition -Task $successStore[$definition.Name] -Definition $definition) "Full readback does not match $($definition.Name)."
}

# Run the production setup script only against in-memory Task Scheduler command mocks.
$global:DevConfigBackupTaskRegistrationMock = @{}
try {
    function global:New-ScheduledTaskPrincipal { [CmdletBinding()] param([string] $UserId, [string] $LogonType, [string] $RunLevel) [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
    function global:New-ScheduledTaskAction { [CmdletBinding()] param([string] $Execute, [string] $Argument, [string] $WorkingDirectory) [pscustomobject]@{ Execute = $Execute; Arguments = $Argument; WorkingDirectory = $WorkingDirectory } }
    function global:New-ScheduledTaskSettingsSet {
        [CmdletBinding()]
        param([switch] $StartWhenAvailable, [switch] $RunOnlyIfNetworkAvailable, [switch] $AllowStartIfOnBatteries, [switch] $DontStopIfGoingOnBatteries, [string] $MultipleInstances, [TimeSpan] $ExecutionTimeLimit, [int] $RestartCount, [TimeSpan] $RestartInterval)
        [pscustomobject]@{ StartWhenAvailable = [bool]$StartWhenAvailable; RunOnlyIfNetworkAvailable = [bool]$RunOnlyIfNetworkAvailable; AllowStartIfOnBatteries = [bool]$AllowStartIfOnBatteries; DontStopIfGoingOnBatteries = [bool]$DontStopIfGoingOnBatteries; MultipleInstances = $MultipleInstances; ExecutionTimeLimit = $ExecutionTimeLimit; RestartCount = $RestartCount; RestartInterval = $RestartInterval }
    }
    function global:New-ScheduledTaskTrigger {
        [CmdletBinding()]
        param([switch] $AtLogOn, [switch] $Daily, [switch] $Weekly, [object] $At, [string] $User, [object] $DaysOfWeek)
        $type = if ($AtLogOn) { 'logon' } elseif ($Daily) { 'daily' } elseif ($Weekly) { 'weekly' } else { 'unknown' }
        [pscustomobject]@{ Type = $type; At = $At; User = $User; DaysOfWeek = $DaysOfWeek; Delay = $null }
    }
    function global:Get-ScheduledTask {
        [CmdletBinding()]
        param([string] $TaskName, [string] $TaskPath)
        if ($global:DevConfigBackupTaskRegistrationMock.ContainsKey($TaskName)) { return $global:DevConfigBackupTaskRegistrationMock[$TaskName] }
        $exception = New-Object System.Management.Automation.ItemNotFoundException "synthetic absence: $TaskName"
        $record = New-Object System.Management.Automation.ErrorRecord $exception, 'TaskNotFound', ([System.Management.Automation.ErrorCategory]::ObjectNotFound), $TaskName
        $PSCmdlet.ThrowTerminatingError($record)
    }
    function global:Export-ScheduledTask { [CmdletBinding()] param([string] $TaskName, [string] $TaskPath) return $global:DevConfigBackupTaskRegistrationMock[$TaskName].Xml }
    function global:Unregister-ScheduledTask { [CmdletBinding()] param([string] $TaskName, [string] $TaskPath, [switch] $Confirm) [void]$global:DevConfigBackupTaskRegistrationMock.Remove($TaskName) }
    function global:Register-ScheduledTask {
        [CmdletBinding()]
        param([string] $TaskName, [string] $TaskPath, [string] $Xml, $Action, [object[]] $Trigger, $Principal, $Settings, [string] $Description, [switch] $Force)
        if ($PSBoundParameters.ContainsKey('Xml')) { throw 'Production setup mock did not expect XML restoration for absent tasks.' }
        if ($Force) { throw 'Production setup mock must not force-create absent tasks.' }
        $task = [pscustomobject]@{ TaskName = $TaskName; TaskPath = $TaskPath; State = 'Ready'; Actions = @($Action); Principal = $Principal; Triggers = @($Trigger); Settings = $Settings; Description = $Description; Xml = "mock:$TaskName" }
        $global:DevConfigBackupTaskRegistrationMock[$TaskName] = $task
        return $task
    }

    & $setupPath
    Assert-Condition ($global:DevConfigBackupTaskRegistrationMock.Count -eq 4) 'Production setup mock must register exactly four tasks.'
    $mockLocal = $global:DevConfigBackupTaskRegistrationMock['DevConfigBackup-Local']
    $mockDrive = $global:DevConfigBackupTaskRegistrationMock['DevConfigBackup-Drive-Daily']
    $mockWeChatHot = $global:DevConfigBackupTaskRegistrationMock['WeChatBackup-Hot-Daily']
    $mockWeChatDrive = $global:DevConfigBackupTaskRegistrationMock['WeChatBackup-Drive-Weekly']
    Assert-Condition ($mockLocal.Actions[0].Arguments -match 'Backup-DevConfig-Hidden\.vbs" Local,Hot$') 'Local task action changed.'
    Assert-Condition ($mockDrive.Actions[0].Arguments -match 'Backup-DevConfig-Hidden\.vbs" Drive$') 'Drive task action changed.'
    Assert-Condition ($mockWeChatHot.Actions[0].Arguments -match 'Backup-WeChat-Hidden\.vbs" Hot$') 'WeChat hot task action changed.'
    Assert-Condition ($mockWeChatDrive.Actions[0].Arguments -match 'Backup-WeChat-Hidden\.vbs" Drive$') 'WeChat Drive task action changed.'
    Assert-Condition ($mockLocal.Triggers.Count -eq 2 -and $mockLocal.Triggers[1].Delay -eq 'PT20M') 'Local task triggers changed.'
    Assert-Condition ($mockDrive.Settings.RunOnlyIfNetworkAvailable -and $mockDrive.Settings.RestartCount -eq 3) 'Drive task settings changed.'
    Assert-Condition ($mockWeChatHot.Settings.RestartCount -eq 3 -and -not $mockWeChatHot.Settings.RunOnlyIfNetworkAvailable) 'WeChat hot task settings changed.'
    Assert-Condition ($mockWeChatDrive.Triggers[0].Type -eq 'weekly' -and $mockWeChatDrive.Triggers[0].DaysOfWeek -eq 'Sunday' -and $mockWeChatDrive.Settings.RestartCount -eq 5) 'WeChat Drive schedule or retry settings changed.'
    foreach ($task in @($mockLocal, $mockDrive, $mockWeChatHot, $mockWeChatDrive)) {
        Assert-Condition ($task.Principal.UserId -eq $env:USERNAME -and $task.Principal.LogonType -eq 'Interactive' -and $task.Principal.RunLevel -eq 'Limited') 'Task principal changed.'
    }
}
finally {
    foreach ($name in @('New-ScheduledTaskPrincipal', 'New-ScheduledTaskAction', 'New-ScheduledTaskSettingsSet', 'New-ScheduledTaskTrigger', 'Get-ScheduledTask', 'Export-ScheduledTask', 'Unregister-ScheduledTask', 'Register-ScheduledTask')) {
        Remove-Item -LiteralPath ("Function:\global:$name") -Force -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name DevConfigBackupTaskRegistrationMock -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'PASS: scheduled task registration is crash-safe, exact-target, and fully readback-verified with isolated mocks.'
