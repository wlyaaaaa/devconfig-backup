' Hidden launcher for DevConfigBackup-* scheduled tasks.
Dim fso, shell, here, tier, pwsh, exe, command, exitCode

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
tier = "Local"
If WScript.Arguments.Count > 0 Then
    tier = WScript.Arguments(0)
End If

Select Case LCase(tier)
    Case "local", "hot,drive"
    Case Else
        WScript.Quit 2
End Select

pwsh = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If fso.FileExists(pwsh) Then
    exe = """" & pwsh & """"
Else
    exe = "powershell.exe"
End If

command = exe & " -NoProfile -ExecutionPolicy Bypass -File """ & here & "\Backup-DevConfig.ps1"" -Tier " & tier
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
