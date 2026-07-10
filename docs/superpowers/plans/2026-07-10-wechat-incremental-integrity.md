# 微信增量完整性与恢复流程实施计划

> **执行说明：** 实施人员必须使用 superpowers:executing-plans，按任务逐项执行，并在每个任务之间进行验证。

**目标：** 将微信备份改为“静态快照 + checksum 增量 + 内容级校验 + Drive 全量恢复”，并退役只用于首次补齐的小时监控任务。

**架构：** 每周任务刷新本地静态快照后，从快照执行 rclone copy --checksum；未变化文件只做哈希/元数据比较，变化文件才上传。上传结束后运行不带 --size-only 的 rclone check，校验失败则返回失败并等待下一周重试。恢复脚本保留 U 盘优先路径，同时新增仅 Drive 时下载完整媒体和数据库的路径。

**技术栈：** 兼容 Windows PowerShell 5.1 的脚本、rclone、robocopy、Windows Task Scheduler、自定义 PowerShell 回归测试、公开安全的 GitHub 仓库。

## 全局约束

- 不把聊天数据、密钥、原始日志、.env、数据库或备份包写入 Git。
- Drive 增量必须保留 --max-transfer 8G 流量保险丝。
- 静态快照必须与正在运行的微信源目录分离。
- 默认备份只增不删；不因云端差异自动删除远端对象。
- 内容校验使用 MD5/hash，不得继续把 --size-only 当作完整性证明。
- 计划任务实际执行本地工作区文件；GitHub 推送不会自动更新本机脚本。
- 实施期间先暂停旧的 WeChatBackup-Weekly，完成测试和云端修复后再恢复。
- WeChatDrive-Monitor-Hourly 只作为首次全量补齐工具；完成后保持 Disabled，不删除，便于回滚。

## 当前证据

- rclone check --size-only：127731 matching files，0 differences。
- 普通 MD5 rclone check：127717 matching files，14 differences。
- 差异集中在微信配置/MMKV 文件及 .crc 配对文件，未发现消息数据库或媒体缺失。
- 最终上传日志记录主上传 exit=0、密钥上传 exit=0、==== 完成 ====。
- WeChatDrive-Monitor-Hourly 当前仍可能处于 Running/扫描状态；以实时 Windows Task Scheduler 为准，PCConfig 旧登记需在收尾后刷新。
- WeChatBackup-Weekly 当前启用，下一次本机约 2026-07-11 20:00；修复前不得让它继续使用旧逻辑。

## 文件范围

- 修改：Backup-WeChat.ps1 — checksum 增量、内容校验、失败退出码、-List 语义。
- 修改：Monitor-WeChatDrive.ps1 — 仅保留临时补齐用途；最终校验改为 hash，识别所有相关 rclone 操作。
- 修改：Restore-WeChat.ps1 — 新增 Drive-only 全量恢复媒体和数据库。
- 修改：README.md — 周任务、自包含校验、恢复命令、流量与失败语义。
- 新建：tests/Assert-WeChatIncrementalIntegrity.ps1 — 本地临时 fixture 的同大小同时间变更回归测试。
- 按需修改：tests/Assert-NoBackupArtifacts.ps1；只有新测试 fixture 需要额外公开安全白名单规则时才修改，不能放宽备份产物保护。
- 机器事实：实时 Windows 任务状态和 E:\PCConfig\registries\tasks.json；完成实时核验后只能通过 PCConfig 所有者流程更新。
- 云端数据：只修复 14 个 checksum 差异；绝不上传仓库或暴露密钥。

---

### 任务 1：修改代码前冻结运行状态

**文件与对象：**
- 读取：E:\Projects\Backups\devconfig-backup\Backup-WeChat.ps1
- 读取：E:\Projects\Backups\devconfig-backup\Monitor-WeChatDrive.ps1
- 读取：E:\Projects\Backups\devconfig-backup\Backup-WeChat-Hidden.vbs
- 机器任务：WeChatBackup-Weekly、WeChatDrive-Monitor-Hourly

**输入与输出：**
- 输入：当前 Windows Task Scheduler 状态和当前进程列表。
- 输出：记录旧上传任务已停止的基线，作为代码上线前证据。

- [ ] 记录当前 UTC、本机时间、中国时间、任务状态、上次结果、下次运行时间和相关 rclone 命令行。
- [ ] 等当前 WeChatDrive-Monitor-Hourly 自然结束；不要终止正在运行的 rclone size 或 rclone check。
- [ ] 在下一次触发前，使用 Disable-ScheduledTask -TaskName 'WeChatBackup-Weekly' 禁用 WeChatBackup-Weekly。
- [ ] 修改前确认不存在 Backup-WeChat.ps1 或微信 Drive 上传进程。
- [ ] 不要删除 WeChatDrive-Monitor-Hourly；在新的周任务流程完成一个成功周期前，保留它作为回滚入口。

预期结果：checksum 改动测试期间旧周任务不会启动，正在运行的备份进程不会被中断。

---

### 任务 2：先编写会失败的增量完整性测试

**文件：**
- 新建：tests/Assert-WeChatIncrementalIntegrity.ps1

**输入与输出：**
- 输入：PATH 中的 rclone.exe，或 E:\Scoop\shims\rclone.exe。
- 输出：只有 checksum 更新、无变化跳过、size-only 对照和清理全部通过时才返回退出码 0。

- [ ] 在 $env:TEMP 下创建 source 和 remote 临时目录；绝不使用 E:\Documents\xwechat_files、E:\WeChatBackup 或真实 Drive 远端。
- [ ] 写入固定大小的测试文件，记录原始 UTC 修改时间和 MD5。
- [ ] 首次执行 rclone copy source remote，并断言退出码为 0。
- [ ] 只修改文件字节，保持文件长度不变并恢复原始修改时间。
- [ ] 执行不带 --checksum 的修复前对照，并断言云端 hash 仍为旧值；这会固定记录本次 14 个差异的回归问题。
- [ ] 执行 rclone copy source remote --checksum，并断言本地与远端 MD5 一致。
- [ ] 对未变化内容再次执行 rclone copy source remote --checksum --dry-run，并断言没有 Copied/Transferred 动作。
- [ ] 执行 rclone check source remote --one-way，并断言退出码为 0。
- [ ] 将清理动作放入 finally，即使断言失败也要删除临时 fixture。

~~~~powershell
$ErrorActionPreference = 'Stop'
$rclone = (Get-Command rclone -ErrorAction SilentlyContinue).Source
if (-not $rclone -and (Test-Path 'E:\Scoop\shims\rclone.exe')) {
    $rclone = 'E:\Scoop\shims\rclone.exe'
}
if (-not $rclone) { throw 'rclone is required for this test' }
$root = Join-Path $env:TEMP ('wechat-integrity-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$remote = Join-Path $root 'remote'
try {
    New-Item -ItemType Directory -Path $source,$remote -Force | Out-Null
    $file = Join-Path $source 'same-size-same-time.bin'
    [IO.File]::WriteAllBytes($file, [byte[]](1..64))
    $fixedTime = [datetime]::UtcNow.AddMinutes(-10)
    [IO.File]::SetLastWriteTimeUtc($file, $fixedTime)
    & $rclone copy $source $remote
    if ($LASTEXITCODE -ne 0) { throw 'initial copy failed' }
    $before = (Get-FileHash $file -Algorithm MD5).Hash
    [IO.File]::WriteAllBytes($file, [byte[]](65..128))
    [IO.File]::SetLastWriteTimeUtc($file, $fixedTime)
    & $rclone copy $source $remote --checksum
    if ($LASTEXITCODE -ne 0) { throw 'checksum copy failed' }
    $after = (Get-FileHash (Join-Path $remote 'same-size-same-time.bin') -Algorithm MD5).Hash
    if ($before -eq $after) { throw 'checksum copy did not update changed content' }
    & $rclone check $source $remote --one-way
    if ($LASTEXITCODE -ne 0) { throw 'checksum check failed' }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
~~~~

运行：powershell -NoProfile -ExecutionPolicy Bypass -File tests\Assert-WeChatIncrementalIntegrity.ps1

预期：加入 checksum 逻辑前测试失败；实现完成后测试通过。

---

### 任务 3：让 Backup-WeChat 支持 checksum 并自我校验

**文件：**
- 修改：Backup-WeChat.ps1:252-303
- 测试：tests/Assert-WeChatIncrementalIntegrity.ps1

**输入与输出：**
- 输入：现有的 $LocalRoot、$GDriveRemote、$GDriveFolder、$MaxTransfer 和 $filter。
- 输出：内容校验失败时返回非零退出码的 Drive 备份流程。

- [ ] 在 $rc 参数数组中紧跟 --fast-list 加入 --checksum；保留 --bwlimit、--transfers、重试参数和 --max-transfer 8G。
- [ ] 保留真实 Drive 上传使用静态快照的规则；rclone 源必须是 $LocalRoot，绝不能是正在运行的微信源目录。
- [ ] rclone copy 返回后，使用相同排除规则、--one-way、--fast-list 和 --checkers 16 执行普通 rclone check $LocalRoot $dest；不能加入 --size-only。
- [ ] 在日志中分别记录 copy exit、check exit 和 key upload exit。
- [ ] 设置脚本级 $overallExitCode = 0；copy、hash 校验、密钥上传或连通性失败时设为 1；将无条件的 exit 0 改为 exit $overallExitCode。
- [ ] 除统一错误报告外，保持 -Target Usb 行为不变。
- [ ] 保留 --max-transfer 8G；达到上限或文件集不完整时，内容校验必须失败，并由下一次周任务重试。
- [ ] 让 -List 真正不写入云端。Drive 的 list 模式跳过真实快照刷新，使用相同过滤条件执行 rclone copy $Source $dest --dry-run；list 模式绝不写入真实快照。

验证命令：

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Assert-WeChatIncrementalIntegrity.ps1
powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.Management.Automation.Language.Parser]::ParseFile('Backup-WeChat.ps1',[ref]$null,[ref]$null) | Out-Null"
~~~~

预期：fixture 证明同大小同时间的内容变化可以被修复；脚本解析器不返回错误。

---

### 任务 4：简化监控并定义退役规则

**文件：**
- 修改：Monitor-WeChatDrive.ps1:98-190
- 读取：Install-WeChatDriveMonitor.ps1

**输入与输出：**
- 输入：周任务脚本的自校验退出码和当前 rclone 进程列表。
- 输出：不会重复启动上传、并在 hash 校验后禁用的临时补齐监控。

- [ ] 识别命令行包含微信源或目标的所有相关 rclone 操作，包括 copy、size 和 check；不能只把 copy 视为活跃。
- [ ] 将监控最终校验参数从 --size-only 改为普通 hash 校验。
- [ ] 只有 hash 校验退出码为 0 时才调用 Disable-ScheduledTask，并记录匹配数量和明确的校验结果。
- [ ] hash 校验失败时记录失败并保持任务启用以便补齐；只要相关 rclone 进程仍在运行，就不能启动另一个上传。
- [ ] 保留脚本手动恢复能力，但明确文档说明计划任务只是临时任务，首次完整校验通过后应禁用。
- [ ] 增加针对脚本内容/解析的断言，确认监控最终校验参数不再包含 --size-only。

运行：

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.Management.Automation.Language.Parser]::ParseFile('Monitor-WeChatDrive.ps1',[ref]$null,[ref]$null) | Out-Null"
~~~~

预期：监控没有重复启动路径，并使用内容级最终校验。

---

### 任务 5：增加仅 Drive 的完整恢复

**文件：**
- 修改：Restore-WeChat.ps1:19-75
- 修改：README.md:200-240

**输入与输出：**
- 新增开关：[switch] $DriveOnly。
- 默认模式：保留当前 U 盘全量合并加 Drive db_storage 更新。
- Drive-only 模式：按备份相同排除规则将完整 Drive 树复制到 $Target，再把 _KEYS 复制到目标旁边，并输出 WeFlow/wx_key 解密说明。

- [ ] 在参数块中加入 $DriveOnly。
- [ ] 设置 -DriveOnly 时跳过 U 盘 robocopy 分支，使用 cache/**、Cache/**、temp/**、Temp/**、WMPF/**、apm_record/**、crash/**、FileStorageTemp/**、recommend_cover/**、*.db-wal、*.db-shm、*.db-journal 排除规则执行 rclone copy $src $Target。
- [ ] 保持 -List 使用 robocopy /L 或 rclone --dry-run；list 模式不能写入恢复目标或密钥文件。
- [ ] Drive 不可达或完整恢复复制失败时返回非零退出码。
- [ ] 在 README 中加入命令：

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -DriveOnly -Target E:\Restore\xwechat_files
~~~~

- [ ] 明确说明该模式用于 WeFlow/wx_key 查看数据，不保证能够直接导入官方微信客户端。

验证命令：

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -DriveOnly -List -Target (Join-Path $env:TEMP 'wechat-restore-list')
~~~~

预期：只产生干跑结果，不创建恢复目标或密钥文件。

---

### 任务 6：记录新的“仅周任务”运行模式

**文件：**
- 修改：README.md
- 按需修改：AGENTS.md；只有仓库边界或验证规则发生变化时才修改，不能复制 PCConfig 机器事实。

- [ ] 记录 WeChatBackup-Weekly 是正常周期任务，WeChatDrive-Monitor-Hourly 只用于临时补齐。
- [ ] 记录 rclone copy --checksum 是增量比较规则，未变化文件不消耗上传流量。
- [ ] 记录内容完整性必须使用普通 rclone check；--size-only 不能作为完成证明。
- [ ] 记录每次 8G 上限，以及不完整任务如何由下一次周任务继续。
- [ ] 记录 14 个文件的修复是一次 checksum 对账，不是全量重传。
- [ ] 记录两条恢复路径：U 盘优先合并和 Drive-only 全量恢复。
- [ ] 所有示例不得包含真实远端账号、token、密钥、原始日志或聊天标识。

---

### 任务 7：云端修复前执行仓库验证

**文件与命令：**
- 读取并执行：tests/Assert-NoBackupArtifacts.ps1
- 执行：tests/Assert-WeChatIncrementalIntegrity.ps1
- 执行：所有修改脚本的 PowerShell 解析检查

- [ ] 运行：

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Assert-NoBackupArtifacts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Assert-WeChatIncrementalIntegrity.ps1
~~~~

- [ ] 使用 [System.Management.Automation.Language.Parser]::ParseFile 解析 Backup-WeChat.ps1、Monitor-WeChatDrive.ps1 和 Restore-WeChat.ps1。
- [ ] 确认 git status --short 只包含本次明确的公开安全源代码、测试、文档和计划文件。
- [ ] 确认 xwechat_files、db_storage、聊天数据库、压缩包、key、.env 或原始日志均不是 Git 候选文件。
- [ ] 任何仓库测试失败时都不能修复 Drive。

---

### 任务 8：不全量重传，修复云端 14 个差异

**对象：**
- 云端目标：Backups/WeChat/xwechat_files
- 源：E:\WeChatBackup\xwechat_files 静态快照
- 日志：E:\Projects\Backups\devconfig-backup\logs\ 下的新本地日志

- [ ] 确认源静态快照稳定，且没有微信上传进程运行。
- [ ] 按生产排除规则、--checksum、重试参数和 --max-transfer 8G，从静态快照执行一次 checksum 增量复制。
- [ ] 不能使用 --delete、--purge、--ignore-times 或全量压缩包。
- [ ] 复制后使用相同排除规则执行普通 rclone check --one-way。
- [ ] 必须得到 0 differences、0 missing 和退出码 0；记录匹配数量与修复文件数量。
- [ ] 将重复对象提示作为独立的非阻断清理报告；本任务不删除 Drive 重复对象。

预期：只上传同大小同时间但内容过期的对象，不发生完整 38GB 重传。

---

### 任务 9：上线“仅周任务”模型

**对象：**
- 机器任务：Windows Task Scheduler
- 机器记录：E:\PCConfig\registries\tasks.json
- 可选所有者说明：PCConfig 中对应的任务用途条目

- [ ] 任务 8 通过后保持 WeChatDrive-Monitor-Hourly Disabled；在一个周周期验证通过前不要注销它。
- [ ] 只有本地 DEV 脚本完成测试后，才重新启用 WeChatBackup-Weekly。
- [ ] 根据批准的上线路径，手动运行一次 Backup-WeChat.ps1 -Target Drive，或使用相同生产参数启动周任务。
- [ ] 确认日志顺序为：刷新快照、checksum 复制、hash check exit 0、密钥上传 exit 0。
- [ ] 一个周周期成功后，刷新 PCConfig 只读任务登记，确认监控记录为禁用/临时任务，周任务记录为启用。
- [ ] 周任务失败时保持监控禁用、保留失败日志；修复原因后再重跑，不能静默退回 size-only 校验。

---

### 任务 10：Git 收尾与公开安全发布

**文件：**
- E:\Projects\Backups\devconfig-backup 中所有本次明确修改的文件

- [ ] 在干净的 Git 候选文件集上重新运行仓库测试和脚本解析检查。
- [ ] 检查 diff 中是否包含密钥、尚未公开安全化的原始路径、key、聊天内容、原始日志或生成的备份产物。
- [ ] 使用聚焦提交信息提交源代码、测试、文档和实施计划，例如 fix: verify WeChat incremental backups by checksum。
- [ ] 验证通过后，只推送公开安全的 DEV 仓库。
- [ ] 执行 git-change-closeout 要求的 GitHub 总索引 fast path；不能把原始任务 XML、密钥或云端日志加入公开索引。
- [ ] 报告 affected_fact_domains: ["business","machine","git"]、目标分支、commit hash、推送状态，以及是否刷新了 PCConfig。

## 验收标准

- 回归测试能够发现并修复同大小同修改时间但内容变化的文件。
- 未变化的增量运行不会产生数据上传。
- 生产 Drive 复制使用 checksum 比较，并保留 8G 上限。
- 生产任务只有普通内容级 rclone check 通过才算完成。
- 14 个已知云端差异可以在不全量重传的情况下修复。
- 仅 Drive 恢复能够下载完整备份树，并把密钥文件放在恢复目录旁边，同时不暴露密钥值。
- WeChatDrive-Monitor-Hourly 在补齐校验通过后被禁用，正常周任务不再依赖它。
- WeChatBackup-Weekly 运行经过测试的本地代码，复制或校验失败时返回失败信号。
- 公开 GitHub 只包含脚本、测试、文档和计划元数据，不包含备份数据或密钥。

## 风险与缓解措施

- Hash 扫描会更慢：增加的是本地 CPU 和元数据枚举，不是完整上传流量；按周运行并保留 8G 上限。
- 快照期间微信源发生变化：继续使用静态快照，绝不直接上传正在运行的源目录。
- 周任务在代码上线前触发：实施期间禁用，测试通过后再启用。
- Drive 重复对象：单独报告和复核，不自动执行破坏性去重。
- PCConfig 登记漂移：以实时 Task Scheduler 为准，最终任务状态稳定后再刷新。
