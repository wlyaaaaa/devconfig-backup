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
    return [pscustomobject]@{
        Execute = 'C:\Windows\System32\wscript.exe'
        Arguments = ('"E:\synthetic\wrapper.vbs" ' + $Tier)
        WorkingDirectory = 'E:\synthetic'
    }
}

function New-TestDefinitions {
    return @(
        [pscustomobject]@{ Name = 'DevConfigBackup-Local'; Action = New-TestAction 'Local,Hot'; Triggers = @('daily'); Settings = 'local'; Description = 'local' },
        [pscustomobject]@{ Name = 'DevConfigBackup-Drive-Daily'; Action = New-TestAction 'Drive'; Triggers = @('daily'); Settings = 'drive'; Description = 'drive' },
        [pscustomobject]@{ Name = 'WeChatBackup-Hot-Daily'; Action = New-TestAction 'Hot'; Triggers = @('daily'); Settings = 'wechat-hot'; Description = 'wechat-hot' },
        [pscustomobject]@{ Name = 'WeChatBackup-Drive-Weekly'; Action = New-TestAction 'Drive'; Triggers = @('weekly'); Settings = 'wechat-drive'; Description = 'wechat-drive' }
    )
}

function New-TestTask {
    param($Action, [string] $Xml)
    return [pscustomobject]@{
        Actions = @($Action)
        Xml = $Xml
    }
}

function New-TestTaskApi {
    param(
        [hashtable] $Store,
        [object[]] $Definitions,
        [System.Collections.ArrayList] $Events,
        [string] $FailRegisterName = '',
        [int] $HideGetCall = 0
    )

    $definitionByName = @{}
    $xmlToAction = @{}
    foreach ($definition in $Definitions) {
        $definitionByName[$definition.Name] = $definition
    }
    foreach ($name in @($Store.Keys)) {
        $xmlToAction[$Store[$name].Xml] = $Store[$name].Actions[0]
    }
    $getState = [pscustomobject]@{ Count = 0 }

    $getTask = {
        param([string] $Name)
        $getState.Count++
        if ($HideGetCall -gt 0 -and $getState.Count -eq $HideGetCall) { return }
        if ($Store.ContainsKey($Name)) { return $Store[$Name] }
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
        if (-not $xmlToAction.ContainsKey($Xml)) { throw "unknown XML fixture: $Xml" }
        $Store[$Name] = New-TestTask -Action $xmlToAction[$Xml] -Xml $Xml
    }.GetNewClosure()
    $registerDefinition = {
        param($Definition)
        [void]$Events.Add("register:$($Definition.Name)")
        if ($Definition.Name -ceq $FailRegisterName) { throw "synthetic registration failure: $($Definition.Name)" }
        $Store[$Definition.Name] = New-TestTask -Action $Definition.Action -Xml ("new:$($Definition.Name)")
    }.GetNewClosure()

    return @{
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

# A same-name task with another action is foreign: preflight must abort before any deletion.
$foreignStore = @{
    'DevConfigBackup-Local' = New-TestTask -Action (New-TestAction 'Foreign') -Xml 'xml:foreign'
    'DevConfigBackup-Other' = New-TestTask -Action (New-TestAction 'Foreign') -Xml 'xml:other'
}
$foreignEvents = New-Object System.Collections.ArrayList
$foreignApi = New-TestTaskApi -Store $foreignStore -Definitions $definitions -Events $foreignEvents
$foreignRejected = $false
try {
    Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $foreignApi | Out-Null
} catch {
    $foreignRejected = $_.Exception.Message -match 'non-owned'
}
Assert-Condition $foreignRejected 'A same-name foreign task must block registration.'
Assert-Condition (@($foreignEvents | Where-Object { $_ -like 'unregister:*' }).Count -eq 0) 'Foreign-task preflight must not unregister anything.'
Assert-Condition ($foreignStore.ContainsKey('DevConfigBackup-Other')) 'A foreign prefix task must remain untouched.'

# A later registration failure restores exact XML for old tasks and removes tasks that were previously absent.
$rollbackStore = @{
    'DevConfigBackup-Local' = New-TestTask -Action $definitions[0].Action -Xml 'xml:local-old'
    'DevConfigBackup-Drive-Daily' = New-TestTask -Action $definitions[1].Action -Xml 'xml:drive-old'
    'WeChatBackup-Drive-Weekly' = New-TestTask -Action $definitions[3].Action -Xml 'xml:weekly-old'
    'DevConfigBackup-Other' = New-TestTask -Action (New-TestAction 'Foreign') -Xml 'xml:other'
}
$rollbackEvents = New-Object System.Collections.ArrayList
$rollbackApi = New-TestTaskApi -Store $rollbackStore -Definitions $definitions -Events $rollbackEvents -FailRegisterName 'WeChatBackup-Drive-Weekly'
$rolledBack = $false
try {
    Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $rollbackApi | Out-Null
} catch {
    $rolledBack = $_.Exception.Message -match 'Exact preimages were restored'
}
Assert-Condition $rolledBack 'A registration failure must report successful preimage restoration.'
Assert-Condition ($rollbackStore['DevConfigBackup-Local'].Xml -ceq 'xml:local-old') 'Local task XML preimage was not restored.'
Assert-Condition ($rollbackStore['DevConfigBackup-Drive-Daily'].Xml -ceq 'xml:drive-old') 'Drive task XML preimage was not restored.'
Assert-Condition (-not $rollbackStore.ContainsKey('WeChatBackup-Hot-Daily')) 'A task absent before registration must be removed during rollback.'
Assert-Condition ($rollbackStore['WeChatBackup-Drive-Weekly'].Xml -ceq 'xml:weekly-old') 'Weekly task XML preimage was not restored.'
Assert-Condition ($rollbackStore.ContainsKey('DevConfigBackup-Other')) 'Rollback must not delete a foreign prefix task.'

# Every successful registration is read back and must expose the expected single wrapper action.
$successStore = @{}
$successEvents = New-Object System.Collections.ArrayList
$successApi = New-TestTaskApi -Store $successStore -Definitions $definitions -Events $successEvents
$success = Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $successApi
Assert-Condition $success.Success 'Successful registration transaction did not report success.'
foreach ($definition in $definitions) {
    Assert-Condition ($successStore.ContainsKey($definition.Name)) "Successful registration is missing $($definition.Name)."
    Assert-Condition (Test-BackupScheduledTaskAction -Task $successStore[$definition.Name] -ExpectedAction $definition.Action) "Readback action does not match $($definition.Name)."
}
Assert-Condition (@($successEvents | Where-Object { $_ -like 'unregister:*' }).Count -eq 0) 'Absent tasks must not be unregistered before creation.'

# Run the production setup script only against in-memory Task Scheduler command mocks.
$global:DevConfigBackupTaskRegistrationMock = @{}
try {
    function global:New-ScheduledTaskPrincipal {
        [CmdletBinding()]
        param([string] $UserId, [string] $LogonType, [string] $RunLevel)
        [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
    }
    function global:New-ScheduledTaskAction {
        [CmdletBinding()]
        param([string] $Execute, [string] $Argument, [string] $WorkingDirectory)
        [pscustomobject]@{ Execute = $Execute; Arguments = $Argument; WorkingDirectory = $WorkingDirectory }
    }
    function global:New-ScheduledTaskSettingsSet {
        [CmdletBinding()]
        param(
            [switch] $StartWhenAvailable,
            [switch] $RunOnlyIfNetworkAvailable,
            [switch] $AllowStartIfOnBatteries,
            [switch] $DontStopIfGoingOnBatteries,
            [string] $MultipleInstances,
            [TimeSpan] $ExecutionTimeLimit,
            [int] $RestartCount,
            [TimeSpan] $RestartInterval
        )
        [pscustomobject]@{
            StartWhenAvailable = [bool]$StartWhenAvailable
            RunOnlyIfNetworkAvailable = [bool]$RunOnlyIfNetworkAvailable
            AllowStartIfOnBatteries = [bool]$AllowStartIfOnBatteries
            DontStopIfGoingOnBatteries = [bool]$DontStopIfGoingOnBatteries
            MultipleInstances = $MultipleInstances
            ExecutionTimeLimit = $ExecutionTimeLimit
            RestartCount = $RestartCount
            RestartInterval = $RestartInterval
        }
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
        if ($global:DevConfigBackupTaskRegistrationMock.ContainsKey($TaskName)) {
            return $global:DevConfigBackupTaskRegistrationMock[$TaskName]
        }
    }
    function global:Export-ScheduledTask {
        [CmdletBinding()]
        param([string] $TaskName, [string] $TaskPath)
        return $global:DevConfigBackupTaskRegistrationMock[$TaskName].Xml
    }
    function global:Unregister-ScheduledTask {
        [CmdletBinding()]
        param([string] $TaskName, [string] $TaskPath, [switch] $Confirm)
        [void]$global:DevConfigBackupTaskRegistrationMock.Remove($TaskName)
    }
    function global:Register-ScheduledTask {
        [CmdletBinding()]
        param(
            [string] $TaskName,
            [string] $TaskPath,
            [string] $Xml,
            $Action,
            [object[]] $Trigger,
            $Principal,
            $Settings,
            [string] $Description,
            [switch] $Force
        )
        if ($PSBoundParameters.ContainsKey('Xml')) {
            throw 'The production setup mock should not need XML restore when all task preimages are absent.'
        }
        $task = [pscustomobject]@{
            TaskName = $TaskName
            TaskPath = $TaskPath
            State = 'Ready'
            Actions = @($Action)
            Triggers = @($Trigger)
            Principal = $Principal
            Settings = $Settings
            Description = $Description
            Xml = "mock:$TaskName"
        }
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
    Assert-Condition ($mockLocal.Triggers.Count -eq 2 -and $mockLocal.Triggers[0].Type -eq 'daily' -and $mockLocal.Triggers[1].Type -eq 'logon' -and $mockLocal.Triggers[1].Delay -eq 'PT20M') 'Local task triggers changed.'
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

# A final readback failure after all four registrations must also restore the preimages.
$finalReadbackStore = @{
    'DevConfigBackup-Local' = New-TestTask -Action $definitions[0].Action -Xml 'xml:final-local'
    'DevConfigBackup-Drive-Daily' = New-TestTask -Action $definitions[1].Action -Xml 'xml:final-drive'
    'WeChatBackup-Hot-Daily' = New-TestTask -Action $definitions[2].Action -Xml 'xml:final-hot'
    'WeChatBackup-Drive-Weekly' = New-TestTask -Action $definitions[3].Action -Xml 'xml:final-weekly'
}
$finalReadbackEvents = New-Object System.Collections.ArrayList
# Four preimage reads plus eight per-task pre/post reads make call 14 the second final readback.
$finalReadbackApi = New-TestTaskApi -Store $finalReadbackStore -Definitions $definitions -Events $finalReadbackEvents -HideGetCall 14
$finalReadbackRolledBack = $false
$finalReadbackMessage = ''
try {
    Invoke-BackupScheduledTaskRegistrationTransaction -Definitions $definitions -Api $finalReadbackApi | Out-Null
} catch {
    $finalReadbackMessage = $_.Exception.Message
    $finalReadbackRolledBack = $_.Exception.Message -match 'Exact preimages were restored'
}
Assert-Condition $finalReadbackRolledBack ("Final definition readback failure must trigger rollback. Actual: {0}" -f $finalReadbackMessage)
$expectedFinalXml = @{
    'DevConfigBackup-Local' = 'xml:final-local'
    'DevConfigBackup-Drive-Daily' = 'xml:final-drive'
    'WeChatBackup-Hot-Daily' = 'xml:final-hot'
    'WeChatBackup-Drive-Weekly' = 'xml:final-weekly'
}
foreach ($definition in $definitions) {
    Assert-Condition ($finalReadbackStore[$definition.Name].Xml -ceq $expectedFinalXml[$definition.Name]) "Final readback rollback did not restore $($definition.Name)."
}

Write-Host 'PASS: scheduled task registration is exact-target, transactional, and readback-verified with isolated mocks.'
