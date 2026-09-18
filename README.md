# DevConfig Backup

开发配置与微信原应用数据的分层备份工具。项目负责采集、校验、成功版本发布和工具级恢复；**PCConfig 仍是机器配置、盘符映射、计划任务、迁移与恢复顺序的负责人**。GitHub 总索引负责仓库身份与发布，活动 E 规则负责授权和备份保留原则。

## 日常使用

```powershell
# 默认只读本机回执和计划任务，不扫描私人日志或云端内容
pwsh -File Backup-Status.ps1
pwsh -File Backup-Status.ps1 -Json -NoDrive
# 图形面板，也可双击 Open-BackupStatus.vbs
pwsh -File Backup-Status.ps1 -Gui

# 真正零写入的计划：不创建 staging、日志、锁或目标目录
pwsh -File Backup-DevConfig.ps1 -Tier Local,Hot -Plan -Json
pwsh -File Backup-WeChat.ps1 -Target Hot -Plan -Json

# 实际备份；本地/G 与云端可独立执行
pwsh -File Backup-DevConfig.ps1 -Tier Local,Hot -Json
pwsh -File Backup-DevConfig.ps1 -Tier Drive -Json
pwsh -File Backup-WeChat.ps1 -Target Hot -Json
pwsh -File Backup-WeChat.ps1 -Target Drive -Json
```

面板每分钟刷新，也可手动刷新；关闭窗口只停止显示，不停止备份。通过“管理计划任务”进入 Windows 已有的任务管理界面，不另建常驻服务。默认状态不联网；显式 `-LiveDrive` 才检查连通性，连通不等于内容完整。`-VerifyContent` 重算配置日期包及 latest 的 SHA-256，并对微信当前树逐文件校验，需要读取相应备份数据。兼容参数 `-LogLines` 不再输出可能含私人文件名的原始日志；错误通过分阶段结果定位。

## 备份范围及敏感内容

开发配置选择由 `sources.psd1` 定义，保留 home、AppData、Scoop、Docker 精确配置和 OBS 场景/配置等原有范围。默认排除清单中的缓存、插件和历史；`-IncludeHistory` 只改变清单中的历史排除项，不是自动识别一切聊天或秘密的扫描器。

`RequiredSources` 可登记必要的来源标识，例如 `home/.gitconfig`；必需项缺失会失败。未安装软件可以标为 `optional_absent`，但卷离线、权限错误、读取失败不是“可选软件不存在”。正常可读来源的删除跟随有效保留视图，不从旧副本复活。

运行时协调锁不是恢复数据：只排除 Codex 的 `thread-writer-locks` 目录、指定 SignalRGB LevelDB 的 `LOCK` 文件和 Gemini presence 的进程锁。**不全局排除 `*.lock`**，依赖版本锁文件继续保留。已打开文件采用共享读取，并检查字节哈希、大小和时间；实际字节锁或采集期间变化会导致本轮失败，保留原成功版本。不停止应用、不绕过实际文件锁，也不将读取失败记为成功。

配置包仍可能含 `.gnupg` 私钥、工具配置中的 API 凭据、环境变量和无线网络恢复信息。原有 Wi-Fi 明文恢复导出保持不变，但值不会输出到公开仓库或状态面板。`.env`、`auth.json` 等明确排除项继续排除；Password Center 管理的独立凭据仍走自己的恢复入口。**排除几个文件名不等于整个包不含秘密。** 不随意删改原始凭据来制造“安全”结果，也不能把真实配置包推到公开 Git 仓库。

微信范围在独立 `wechat-sources.psd1` 中维护。备份保留原应用目录及 SQLite WAL/SHM/journal 伴随文件；只复制和校验不解释内容的文件，不提取账号、密钥、聊天或媒体正文。文件完整性不证明多个数据库是在同一个事务时点取得，更不证明官方客户端一定能够恢复。

## 成功发布与失败隔离

DevConfig 每轮使用独立 staging，检查必需源、复制、系统导出和重装清单结果。每个文件以最多三次有界重试取得稳定读取并核对复制结果；采集结束再次核对来源路径集合。已捕获文件随后被应用更新，会单列 changed_after_capture_count，不冒充整个运行中应用在同一时点的快照；源项新增或消失、文件始终无法稳定读取仍会失败。打包必须通过 7-Zip 检测，再生成成功回执；只有完整成功版本可以更新 `current.json`。失败不会替换成功指针，也不能因失败采集而淘汰旧成功包。

每个日期包携带 `.sha256`、`.receipt.json`、`.manifest.json`，包内还有 `backup-manifest.json`。`current.json` 绑定包名、哈希、完整采集状态和目标。`latest.zip` 与附属文件是兼容别名，恢复时必须核验，不能只看文件名或修改时间。旧 `state/latest.sha256` 仅作兼容记录，不能单独证明采集成功或准许上云。

内容及源策略未变时复用现有验证包，而不是反复生成重复大包。云端默认从已上传的日期对象复制出 latest，减少重复本地上传；可显式 `-CloudLatestMode Upload` 使用原上传方式。远端是否支持服务器内复制由 rclone/backend 决定，不把“选择该模式”当成实际流量测量。

G 热备从同一个不可变包发布所有名称，先写临时文件并校验，再原子替换。资源锁协调并发写入，上传中的日期包另持只读句柄。云端逐对象核对大小和哈希，附属材料齐全后才发布 current。保留清理失败会反映到任务结果，不静默报全成功。

微信构建并核验候选树，确认来源稳定后切换当前树和清单。事务失败恢复前一可用树；当前树与一个有界前代保留，更早前代只在后续成功后淘汰。新增、修改、删除和合法清空均收敛；离线或不可读源不触发删除。未变文件可以复用目标树中的硬链接，但不与活动原应用数据建立硬链接。备份目标不应作为活动工作目录编辑。

Drive 只消费已经完成并锁定的本地微信快照：先复制、核对当前源内容，再按相同过滤范围清理旧对象，最后进行严格比对。快照失败不进入云端写入。`-DbOnly` 只处理数据库，不清理已有媒体，也不冒充新完成的全量恢复包。默认 `-MaxTransfer 8G` 限制传输命令，显式 `0` 才取消；中断状态与全量完成状态分开。

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

`Install-WeChatDriveMonitor.ps1` 默认保留已有启用状态，新建默认禁用；显式 `-Enable` 才启用，不自动恢复已经停用的监控。补传传递完整源、快照、远端与限额参数，采集阶段也视为资源忙。监控同时读取 stdout/stderr，超时仅处理自己启动的查询。最终成功依据锁定且验证过的快照与完整远端核对，不是固定容量百分比。禁用监控不等于终止此前已经启动的上传。

所有云端入口使用同一远端 binding 和网络初始化。远端不存在、binding 损坏时失败，不改用“第一个可用账户”。代理关闭时清除旧进程代理变量；命令以实际退出码判定，不把 PowerShell 5.1 包装出的正常 stderr 通知误判为失败。

本项目不直接自动写 H，不解锁或重锁介质。PCConfig 在既有任务或人工可用窗口中使用 `Invoke-CoreRecoveryMaintenance.ps1 -Mode Cold -Execute -Json` 执行 G→H 的 `source_follow_verified_prune`，消费 v2 成功回执并协调 G 生产者锁。微信可携带清单一并复制到 H 树旁。H 不可用表示冷备未执行，不是本次数据已经有新的 H 副本。

## 验证与清理边界

```powershell
pwsh -NoProfile -File tests\Assert-BackupClosure.ps1
powershell -NoProfile -File tests\Assert-BackupClosure.ps1
pwsh -NoProfile -File tests\Assert-BackupEntrypoints.ps1
```

其余 `tests/Assert-*.ps1` 覆盖源范围、公开产物隔离、任务注册、代理、云端对象完整性和原生恢复。测试只能使用随机命名的专属临时目录；清理必须同时核对固定父目录及随机目录名称，误指向源码目录必须拒绝。代码应先保存到独立 Git 分支，再执行有写入的隔离验证。

源码、语法测试、隔离后端、正式任务、真实云端、H 介质及官方客户端验收分别记录，未知不能写成通过。公开仓库只保存工具、测试和安全说明；`out/`、`staging/`、`state/`、`logs/` 和真实秘密、备份产物不进入 Git。
