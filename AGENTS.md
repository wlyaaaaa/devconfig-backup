# 开发配置备份的项目约定

- 本库是可公开的备份工具（public-safe backup tooling），负责脚本、来源选择、隐藏入口和测试；PCConfig 是机器配置与恢复中心（configuration and recovery center），负责路径、计划任务和恢复顺序。
- 真实备份、微信数据库与媒体、凭据和原始日志不入 Git。生成区 `out/`、`staging/`、`state/`、`logs/` 以及 `*.zip`、`*.7z`、`*.reg`、`*.kdbx`、`*.pfx`、`*.pem`、`*.key`、`.env` 保持排除。
- 配置来源先改 `sources.psd1`，微信来源改 `wechat-sources.psd1`；PowerShell 脚本兼容 Windows PowerShell 5.1，入口明确选择 PowerShell 7 的除外。
- `RequiredSources` 不可读须失败；未安装的可选软件与离线、拒绝访问、读取失败不同。当前文件锁只按精确路径排除，不能全局排除 `*.lock`。
- `SQLiteBackupRelativePaths` 选中的活动库用 Python 标准库的只读事务和 SQLite 在线备份获取一致副本，验证 `integrity_check` 后只排除该成功库对应的 WAL/SHM/journal；失败不回退为原始文件复制或跳过。各库分别一致，整包仍不是同一时刻快照，回执列 `sqlite_snapshots`。
- 采集普通文件遇占用或拒绝访问，有界重试后可跳过并报告 `complete_with_skipped_files`；必要来源失败、其他读取错误或持续变化不能报成功。运行中源的后续修改另列，不能声称同一时刻的完整快照。
- 配置源的选择集合在采集前后增删或变化时，整轮重建独立候选，默认最多 3 轮（`-CaptureAttempts` 可调）。选择持续变化时失败，记录尝试数、复核阶段和增删计数，保留旧成功版本；同路径的捕获后修改仍按逐文件快照约定另列。无配置恢复必要的 Claude 文件检查点、缓存、会话环境与调试日志只在 `sources.psd1` 按精确子树排除，不放宽必要来源或全局锁文件规则。
- 单文件 Win32 225/226（HRESULT 0x800700E1/E2）或已枚举源文件随后消失，跳过该文件，整体 `complete` 并写 `file_warnings=[{relative_path,reason,error_code,stage}]`；下次重试。目录根不可读、磁盘写入失败、内容不一致和配置错误仍失败。目标复制后消失须有本轮同一精确路径的 Defender 成功隔离/移除证据，才可记 `antivirus_removed`。警告路径不触发旧副本删除或完整性误判，云端排除范围须同步使用；详细语义见 `docs/recovery.md`。
- 配置包要经压缩包检测、清单与哈希核验后发布；G 和云端独立报告结果。失败保留原成功版本，内容与策略未变时复用已验证包，不为了刷新时间重复上传。
- 微信保留数据库的 WAL/SHM/journal 伴随文件。云端上传只消费 G 的已核验 VSS（卷影快照）版本，默认最多 48 小时；不能改成直接读活动微信目录或在 E 再存一份。
- 默认传输上限为 8G，显式 `0` 才取消。`-DbOnly` 不删除媒体，也不算新完成的全量恢复包。复制后按相同过滤范围清理并完整比对，离线或不可读来源不能触发删除。
- 云端使用已选远端 binding；缺失或损坏就失败，不回退到第一个账号。代理状态与脚本实际退出码分别处理。
- 备份收集到的配置仍可能含凭据，排除几个文件名不代表整个包可公开。恢复不自动导入注册表、覆盖软件配置或恢复登录；微信文件复制完成后仍需官方客户端确认。
- 本库不直接自动写 H；监控安装保留已有启用状态，新建默认禁用。正式任务、网络和恢复接口见 [docs/recovery.md](docs/recovery.md)。
- 根 README 末尾保留现有测试读取的两条恢复接口说明；正文入口和这些接口应同步维护。
- 运行 `tests/Assert-NoBackupArtifacts.ps1` 和受影响的 `tests/Assert-*.ps1`。测试只用专属临时目录；语法、隔离测试、正式任务、真实云端、H 介质和客户端验收分别报告。
