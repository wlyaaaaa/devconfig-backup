' Open the visible backup panel without a console window.
Dim shell, fso, root, executable, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
executable = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If Not fso.FileExists(executable) Then executable = shell.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
command = """" & executable & """ -NoProfile -ExecutionPolicy Bypass -File """ & root & "\Backup-Status.ps1"" -Gui"
WScript.Quit shell.Run(command, 0, True)
