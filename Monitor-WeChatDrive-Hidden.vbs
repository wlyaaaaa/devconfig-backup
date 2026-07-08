' Hidden launcher for WeChatDrive-Monitor-Hourly.
Dim fso, shell, here, command, exitCode

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & here & "\Monitor-WeChatDrive.ps1"""
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

