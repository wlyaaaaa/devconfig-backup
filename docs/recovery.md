# 开发配置与微信恢复说明

这里只保留实际恢复和跨仓库接口。盘符、任务启用状态与恢复顺序以 PCConfig 当前登记和现场回读为准。

## 开发配置恢复

```powershell
# 默认仅核对指定包和附属材料，不改目的地
pwsh -File Restore-DevConfig.ps1 -Archive 'G:\80_Backup\DevConfig\latest.zip' -Destination 'E:\Projects\RecoveryTests\DevConfig' -Json
# 显式提取并核验内部清单及全部文件
pwsh -File Restore-DevConfig.ps1 -Archive 'G:\80_Backup\DevConfig\latest.zip' -Destination 'E:\Projects\RecoveryTests\DevConfig' -Execute -Json
# 非空目标必须明确保留原目录作为同级回滚
pwsh -File Restore-DevConfig.ps1 -Archive 'G:\80_Backup\DevConfig\latest.zip' -Destination 'E:\Projects\RecoveryTests\DevConfig' -Execute -ReplaceExisting -Json
```

这一步只提取到独立目录，不自动导入注册表、重建旧任务、覆盖正在使用的软件配置或恢复登录状态。随后按 PCConfig 当前指南，将 `home`、`appdata-roaming`、`appdata-local`、`extra` 映射到实际机器路径。新用户名、Documents 重定向和盘符变化须使用实际映射，不能直接复制旧账号路径。

全新电脑先安装当前官方 PowerShell、Git、7-Zip 等运行时；恢复 GitHub 登录后，从核实过的 `wlyaaaaa/PCConfig` 当前默认分支取得恢复指南，不假定旧 E 盘目录还存在。软件重装清单位于包内 `_manifests`，只对实际安装且成功导出的工具承诺有记录。不要通配导入旧任务 XML。

若包内有 `_manifests/rclone-remote-binding.json`，只恢复这个非秘密别名选择；先通过凭据所属入口完成授权，不复制未知账户的完整 OAuth 配置：

```powershell
New-Item -ItemType Directory -Path 'E:\Projects\Backups\devconfig-backup\state' -Force | Out-Null
Copy-Item -LiteralPath 'E:\Projects\RecoveryTests\DevConfig\_manifests\rclone-remote-binding.json' -Destination 'E:\Projects\Backups\devconfig-backup\state\rclone-remote-binding.json'
```

新版恢复入口要求同行的 v2 成功回执。老包缺乏这种证据时不伪造回执，也不把 CRC 当成发布哈希；保留老包，优先选择经过验证的新包，必要时由 PCConfig 明确标注证据不足后实施人工旧包恢复。

## 微信原应用恢复

```powershell
# 默认只读预检，不启动或关闭微信，不读取账号
pwsh -File Restore-WeChat.ps1
# 用户自行关闭官方客户端后，显式复制到空目标
pwsh -File Restore-WeChat.ps1 -Execute
# 非空目标先保留 .pre-restore-*，失败自动回滚
pwsh -File Restore-WeChat.ps1 -Execute -ReplaceExisting
# 指定已经人工确认的其他备份介质
pwsh -File Restore-WeChat.ps1 -BackupRoot 'X:\backup\xwechat_files' -Target 'E:\restore\xwechat_files'
```

本地复制核对源、目标完整 SHA-256；存在可携带清单时还必须与它一致。源与目标不得重叠，不接受盘符根目录或路径链重解析跳转。执行时持有源/目标资源锁，并重新核对目标及已知客户端进程。

`COPY_COMPLETE_AWAITING_HUMAN_ACCEPTANCE` 只表示文件复制完成，用户仍需在官方客户端亲自确认目标账号、历史和媒体。在这之前保留备份源和回滚目录。`-DriveOnly` 使用明确远端、当前用户代理并校验复制结果；隔离本地后端测试不等于真实 Google Drive 灾难恢复已经验收。

## 任务、网络和 H 冷备

四个正式任务由 `Setup-ScheduledTasks.ps1` 的事务式注册流程管理：精确名称、原定义前像、逐项回读和失败回滚。隐藏启动器优先 PowerShell 7，缺失才回退 5.1，并传递实际业务退出码。本地/G 与 Drive 分离，网络不可用不阻断本地保护；实际时间、启用状态及下次执行以 Task Scheduler 为准。

`Install-WeChatDriveMonitor.ps1` 默认保留已有启用状态，新建默认禁用；显式 `-Enable` 才启用，不自动恢复已经停用的监控。补传以 G 热备为快照，传递 G 路径、回执、远端与限额参数，Hot 写入期间也视为资源忙。监控同时读取 stdout/stderr，超时仅处理自己启动的查询。最终成功依据锁定且验证过的快照与完整远端核对，不是固定容量百分比。禁用监控不等于终止此前已经启动的上传。

所有云端入口使用同一远端 binding 和网络初始化。远端不存在、binding 损坏时失败，不改用“第一个可用账户”。代理关闭时清除旧进程代理变量；命令以实际退出码判定，不把 PowerShell 5.1 包装出的正常 stderr 通知误判为失败。

本项目不直接自动写 H，不解锁或重锁介质。PCConfig 在既有任务或人工可用窗口中使用 `Invoke-CoreRecoveryMaintenance.ps1 -Mode Cold -Execute -Json` 执行 G→H 的 `source_follow_verified_prune`，消费 v2 成功回执并协调 G 生产者锁。微信可携带清单一并复制到 H 树旁。H 不可用表示冷备未执行，不是本次数据已经有新的 H 副本。
