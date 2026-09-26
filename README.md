# 开发配置与微信备份

1. 这是什么：备份电脑上的开发配置和微信原始文件，方便出问题或换电脑时恢复。
2. 我怎么用：平时按已有计划自动运行；想看情况，双击 `Open-BackupStatus.vbs` 打开状态面板。
3. 怎么知道它正常：看面板的最近结果，让 AI 分别核对本机、备份硬盘和云端；有跳过文件时不算全备份。
4. 坏了怎么提醒我：面板会显示失败或警告，没有自动提醒，出问题直接跟 AI 说。
5. 让 AI 做什么：查失败原因，或按 [恢复说明](docs/recovery.md) 核对后恢复；微信内容还要在官方客户端确认。

给 AI 的项目约定见 [AGENTS.md](AGENTS.md)。
<!-- 恢复接口兼容说明：确认云端账号授权后，将包内 _manifests\rclone-remote-binding.json 恢复到 E:\Projects\Backups\devconfig-backup\state\rclone-remote-binding.json，只还原非秘密的远端别名选择。H 盘冷备由 PCConfig 的 Invoke-CoreRecoveryMaintenance.ps1 -Mode Cold -Execute -Json 负责，本库不直接写 H。完整步骤见 docs/recovery.md。 -->
