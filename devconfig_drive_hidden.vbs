' ============================================================
'  隐藏窗口启动器 —— 由计划任务 DevConfigBackup-Cloud 调用。
'  窗口模式 0 = 完全隐藏，不弹 PowerShell 窗、不抢前台焦点。
'  可移植：自动推导本脚本所在目录。
' ============================================================
Dim fso, here, shell, exitCode
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & here & "\Backup-DevConfig.ps1"" -Tier Drive", 0, True)
WScript.Quit exitCode
