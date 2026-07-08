' Hidden launcher for WeChatBackup-* scheduled tasks.
Dim fso, shell, here, target, pwsh, exe, command, exitCode

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
target = "Usb,Drive"
If WScript.Arguments.Count > 0 Then
    target = WScript.Arguments(0)
End If

Select Case LCase(target)
    Case "local", "usb", "drive", "local,usb", "local,drive", "usb,drive", "local,usb,drive"
    Case Else
        WScript.Echo "Unsupported WeChat backup target: " & target
        WScript.Quit 2
End Select

pwsh = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If fso.FileExists(pwsh) Then
    exe = """" & pwsh & """"
Else
    exe = "powershell.exe"
End If

command = exe & " -NoProfile -ExecutionPolicy Bypass -File """ & here & "\Backup-WeChat.ps1"" -Target " & target
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
