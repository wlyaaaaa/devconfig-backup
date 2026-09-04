# DevConfig Backup — 开发配置 / 凭据 / 系统设置分层备份

> 面向“系统损坏后重装或换机”的灾备工具。它不做整机镜像，而是优先保留难以重建的
> 配置、凭据和恢复状态，并剔除软件本体、IDE 插件、npm 包及常见缓存。恢复时把备份
> 当候选材料：先看版本、兼容性和现场状态，再选择性回填，不把整个包不加判断地覆盖到新系统。
>
> 包体积不是固定产品承诺。2026-09-03 21:05 的最近一次 `History=False` 任务实际采集
> **5,657.16 MB**，生成 **1,911.28 MB** 压缩包；早期约 170 MB / 65 MB 的数字已经不代表
> 当前清单规模。

本仓库只包含**工具脚本**。**备份数据（含 API key/私钥的 zip、注册表导出）永不进仓库**，
见 [.gitignore](.gitignore)。仓库边界见 [AGENTS.md](AGENTS.md)，提交前用
[`tests/Assert-NoBackupArtifacts.ps1`](tests/Assert-NoBackupArtifacts.ps1) 检查备份产物没有进入 Git 候选文件。

---

## 1. 它备份什么

| 类别 | 内容 | 关键点 |
|---|---|---|
| **AI/Agent 配置** | `.claude .codex .gemini .openclaw .cline .cursor .lingma .qoder-cn .chatlab .copilot .cagent .codeg .agents` | 含各家 API key、MCP、自定义 agent/skill；剔除 packages/缓存/历史 |
| **密钥/凭据** | `.gnupg`(GPG 私钥)、`.docker/config.json`、`GitHub CLI`(gh token)、`.openclaw/.../client_secret.json` | 不可再生 |
| **编辑器** | VS Code / Cursor 的 `User\`(设置/快捷键/snippets/MCP)、JetBrains 设置(剔 plugins/jdbc-drivers)、Apifox、Typora、Windows Terminal | |
| **终端/代理** | FinalShell `conn\`(SSH会话+密码)、Clash Verge Rev `profiles\`(订阅)+yaml(剔 geo*.dat) | |
| **Docker 小配置** | `.docker\config.json`、daemon 配置、contexts、Docker Desktop settings 偏好文件 | 不含 Docker Desktop VHDX、镜像层、容器运行态、登录/会话数据库 |
| **生产力** | PowerToys 配置、PixPin 配置、用户自装字体、Scoop `persist\` | |
| **散件** | `.gitconfig .zshrc .wakatime.cfg .claude.json .wslconfig .condarc .npmrc` | |
| **系统导出**(脚本现生成) | 环境变量(`HKCU\Environment` + `HKLM...\Environment`)、机器 PATH、20+ 个自定义计划任务 XML、hosts、Wi-Fi(含密码)、Xshell 注册表 | |
| **重装清单** | `scoop export`、`winget export`、VS Code/Cursor 扩展列表、JetBrains 插件名单、已装软件 CSV | 让"可重下"的部分一条命令补回 |

**默认剔除**（`-IncludeHistory` 可保留）：AI 聊天历史（`.claude\projects`、`.openclaw\session-backup*` 等）。

当前包会随 `sources.psd1`、已安装工具和本机配置增长或缩小。它仍然不是整机镜像：插件、
依赖、缓存、Docker 大盘和运行态数据库继续排除，但较完整的 AI 工具配置、Scoop persist
与其他恢复状态会让它明显大于早期的数十 MB 示例。

**清单数据驱动**：增删备份项只改 [sources.psd1](sources.psd1)，不动脚本。

### 避坑（只取配置，不取缓存/本体）
- PowerToys：取 `AppData\Local\Microsoft\PowerToys`(1.3M)，**不是** 843M 的安装目录
- FinalShell：只取 `conn\`，**不是** 191M 的 JRE
- PixPin：只取 `Config`，**不是** 203M 的截图 `History`
- Clash：取 `profiles\`+yaml，剔 `geoip.dat/geosite.dat/Country.mmdb`(34M 可重下)
- JetBrains：剔 `plugins\`(10.6G)+`jdbc-drivers\`
- Docker：DevConfig 只保存 allowlist 内的 CLI/Desktop 小配置；本地自建镜像另由软件环境备份导出 tar，Docker Desktop 的 `docker_data.vhdx`、登录态、会话数据库和插件二进制不进 DevConfig

---

## 2. 分层备份架构（按恢复速度与介质角色分工）

```
[Backup-DevConfig.ps1] ──产出──> ① 本地 out\devconfig-*.zip  (零流量)
                                      │
                          ┌───────────┴────────────┐
                          ▼                         ▼
                   ② G:\80_Backup 热备       ③ Google Drive (rclone)
                      (在线,计划任务主力)          (每个新代上传完整 zip)
                   ④ H: 冷备（PCConfig 日任务在人工解锁窗口机会式刷新）
```

| 级 | 任务 | 周期/触发 | 流量 |
|---|---|---|---|
| ① 本地 + G盘热备 | `DevConfigBackup-Local` (`-Tier Local,Hot`) | 每天 21:05 + 登录后20分钟；错过补跑、失败重试3次 | 无 |
| ② Drive | `DevConfigBackup-Drive-Daily` (`-Tier Drive`) | 每天 22:00；有网才跑、失败重试5次 | 海外（每个新代上传日期包与 `latest.zip` 两个完整对象） |
| 微信 G盘热备 | `WeChatBackup-Hot-Daily` (`-Target Hot`) | 每天 18:30；错过补跑、失败重试3次 | 无 |
| 微信 Drive | `WeChatBackup-Drive-Weekly` (`-Target Drive`) | 每周日 20:00；有网才跑、失败重试5次 | 只传新增/变化文件并做内容校验 |

当前运行快照（2026-09-04 10:31，本机时区）：本地/G 配置任务、微信 Hot 与微信 Drive
最近一次结果为 0；`DevConfigBackup-Drive-Daily` 最近一次结果为 1。随后只读远端预检已恢复，
但远端 `latest.zip` 仍对应 9 月 2 日，本地/G 已到 9 月 3 日，本轮没有执行上传。
`WeChatDrive-Monitor-Hourly` 是首次云端补齐的临时任务，当前已禁用，不算第五个常规任务。
PCConfig 的 `AIRecoveryColdSync-Daily` 已启用，最近任务结果为 0，但有界回执明确是
`status=skipped` / `H_unavailable`：本轮没有发生 H 冷拷贝，也没有自动重锁 H。

> - **介质原则(2026-07调整)**：G 盘是可直接访问的在线热备；H 盘平时不可用。本仓库不注册 H 写入任务；PCConfig 自己的 `AIRecoveryColdSync-Daily` 每日机会式调用 `Invoke-CoreRecoveryMaintenance.ps1 -Mode Cold -Execute -Json`，只有用户已人工解锁 H 且全部前置条件通过时才复制。H 不可用时会写出 `status=skipped` / `H_unavailable`，不是失败，也不是完成冷备。
> - **配置保留**：本地与 G 盘各保留 **7 份带日期**（`devconfig-YYYYMMDD-HHMMSS.zip`）+ 一份 `latest.zip`，Drive 保留 **3 份带日期** + 一份 `latest.zip`；H 盘只接收 PCConfig 统一的 `G → H` 冷备。
> - **rclone 远端必须明确**：显式 `-GDriveRemote` 优先；否则读取本机非秘密 binding，最后才尝试字面 `gdrive:`。候选 remote 不存在就失败并等待重试，绝不改用第一个已配置远端。binding 会作为单个 `_manifests/rclone-remote-binding.json` 随 DevConfig 备份，不含 OAuth、token 或账号配置。
> - **微信完整历史上云**：当前 G 盘微信热备约 **41.89 GB / 142,693 文件**，其中大部分媒体已经压缩，继续打成一个大包收益很小；因此使用 `rclone copy --checksum` 逐文件增量，已上传且内容未变的文件自动跳过。默认单次 Drive 上传有 **8G 流量保险丝**，限制一次任务的传输量，但不承诺累计云空间永远够用。
> - **binding 失败关闭**：本地 remote binding 文件存在但损坏或不可读时，Drive 流程直接失败并等待修复；只有文件确实不存在时才尝试字面 `gdrive:`，避免静默切到另一云目标。
> - **两类“增量”必须分开**：微信用 robocopy(`/E`) 与 rclone(`copy --checksum`) 做逐文件增量；DevConfig 每次 Local 都写入当前时间并生成新的时间戳 zip/SHA-256，所以正常新代会完整上传日期包与 `latest.zip`。只有同一代、同一目标的两个对象都已经按大小/MD5 核对一致时才跳过，不是 zip 内部差量。
> - **内容校验是完成条件**：DevConfig 对日期包和 `latest.zip` 分别核对远端大小/MD5，微信目录使用 `rclone check`；只比较大小不算内容一致。两个 DevConfig 名称始终来自同一个 hash 已验证的日期包，不能在上传中重新读取会变化的本地 `latest.zip`。
> - **Drive 海外可靠性**：① 没开机 → `StartWhenAvailable` 开机补跑一次；② 后台任务没有显式代理变量时，自动继承当前用户已启用的 Windows 代理；代理/远端仍没就绪则返回失败，由任务级重试继续；③ 传一半断 → `rclone copy` 幂等续传；④ 本地/G 与 Drive 分任务，离线不会阻断热备。
> - **小时监控是临时工具**：`WeChatDrive-Monitor-Hourly` 只用于首次全量补齐，首次内容级校验通过后禁用；正常运行依赖 `WeChatBackup-Hot-Daily` 与 `WeChatBackup-Drive-Weekly`。
> - **看进度/日志**：`pwsh -File Backup-Status.ps1`。
> - **H盘边界**：本项目不直接写 H。PCConfig 冷备要求整体 Hot context 不超过 48 小时、DevConfig 与微信各自不超过 36 小时，核对 G/H 介质身份、H 已解锁、剩余空间高于 100 GiB 并取得写锁；复制模式为 `additive_no_mirror`，不自动重锁 H。DevConfig 只有在新文件通过 SHA-256、大小和存在性核对后才按 allowlist 清理旧日期包。

---

## 3. 在新电脑上恢复（重装后）

先装 Git，再取得两个不同角色的仓库：本 PUBLIC 仓库只提供 DevConfig/微信工具；机器路径、
计划任务、系统设置与 H 冷备顺序来自 PRIVATE `wlyaaaaa/PCConfig`。恢复 GitHub 登录后执行：

```powershell
git clone https://github.com/wlyaaaaa/devconfig-backup.git E:\Projects\Backups\devconfig-backup
git clone https://github.com/wlyaaaaa/PCConfig.git E:\PCConfig
```

若暂时没有 PRIVATE PCConfig 访问权，仍可检查/解压 DevConfig 包和预检微信，但必须暂停
机器级设置、计划任务与 H 冷备步骤；一个本地路径不存在不能冒充恢复入口已经就绪。

选包不能只看“最新”文件名。当前 `state\latest.sha256` 只保存在原工作目录，没有随
G/Drive 包发布为可携带 sidecar；若它仍存活，可核对候选包 SHA-256。若已丢失，
`7z t` 只能证明 zip 内部 CRC 可读，不能证明它与原始发布哈希一致。这是当前真实缺口；
核验失败时改试上一日期包或另一介质，所有候选都失败就停止恢复。

```powershell
$candidateZip = 'G:\80_Backup\DevConfig\latest.zip'
& 'C:\Program Files\7-Zip\7z.exe' t $candidateZip
$shaRecord = 'E:\Projects\Backups\devconfig-backup\state\latest.sha256'
if (Test-Path -LiteralPath $shaRecord) {
    $expectedSha = (Get-Content $shaRecord -ErrorAction Stop).Split()[0]
    $actualSha = (Get-FileHash $candidateZip -Algorithm SHA256).Hash
    if ($actualSha -ine $expectedSha) { throw 'devconfig_backup_hash_mismatch' }
} else {
    Write-Warning 'portable expected SHA-256 is unavailable; 7z CRC is the strongest current check'
}
```

```powershell
# 0) 装基础：scoop（含 7zip）、Windows Terminal、各 IDE、rclone
#    用备份里的 _manifests\ 一键补软件：
scoop import  _manifests\scoop.json
winget import _manifests\winget.json
Get-Content _manifests\vscode-extensions.txt | ForEach-Object { code --install-extension $_ }

# 1) 解开最新 zip
& 'C:\Program Files\7-Zip\7z.exe' x devconfig-YYYYMMDD.zip -o"$env:USERPROFILE\restore"

# 2) 把 home\ 回填到 ~，appdata-roaming\ -> AppData\Roaming，appdata-local\ -> AppData\Local
#    _system\*.reg 双击导入（环境变量/Xshell）；计划任务不要通配导入 XML，按 PCConfig 重建计划逐项恢复
#    _system\wifi\*.xml: netsh wlan add profile filename=...

# 3) 重新挂上备份任务
pwsh -File Setup-ScheduledTasks.ps1     # 或 powershell -File（兼容 5.1）

# 4) Drive：装 rclone 并配置远端
scoop install rclone
rclone config        # 配置已选的 Google Drive 远端（OAuth，需挂代理）
# 如备份内有 _manifests/rclone-remote-binding.json，只回填这一个非秘密 alias 选择：
New-Item -ItemType Directory -Force E:\Projects\Backups\devconfig-backup\state
Copy-Item _manifests\rclone-remote-binding.json E:\Projects\Backups\devconfig-backup\state\rclone-remote-binding.json
```

> ⚠️ **两个恢复陷阱**（务必注意）：
> 1. **Documents 在 E 盘**：重装后"我的文档"默认指向 `C:\Users\<你>\Documents`，Xshell/Navicat 会读到空目录。
>    解决：右键"文档"→属性→位置→移动 到 `E:\Documents`，旧配置瞬间满血。
> 2. **用户名路径要兼容**：很多配置里固化了 `C:\Users\10979\...` 绝对路径。
>    沿用 `10979` 最省事；使用新用户名也可以，但恢复后必须有界替换或重映射这些已知路径。

---

## 4. 微信原应用数据备份与恢复（独立流）

微信应用数据当前约 **41.89 GB**（媒体也是原应用数据的一部分），太大不进配置包，单独走 [Backup-WeChat.ps1](Backup-WeChat.ps1)。本地/G 的原生恢复路径保留 `xwechat_files` 的原生目录布局，目标是让官方微信客户端有机会继续使用该数据；本次恢复流程不是个人保险库、解密工具或聊天导出工具。

```powershell
pwsh -File Backup-WeChat.ps1 -List          # 干跑:刷新本地快照后列出待传量
pwsh -File Backup-WeChat.ps1 -Target Hot     # 全量到G盘热备(robocopy /E,只增不删,零流量;主力)
pwsh -File Backup-WeChat.ps1 -Target Local   # 增量到本地另一盘
pwsh -File Backup-WeChat.ps1 -Target Drive   # 完整原应用数据增量到Drive(含媒体;已传自动跳过;默认8G封顶)
pwsh -File Backup-WeChat.ps1 -Target Drive -MaxTransfer 0   # 一次性补齐模式(关闭封顶,需人工看进度)
pwsh -File Backup-WeChat.ps1 -Target Drive -DbOnly   # 临时省流量模式:只传db_storage
pwsh -File Backup-WeChat.ps1 -Target Drive -DbOnly -DriveFull # 兼容覆盖：仍按完整原应用数据上传
```

**当前策略：完整原应用数据逐文件增量备份**：
- **G盘热备**：`Backup-WeChat.ps1 -Target Hot` 原样复制所选 `xwechat_files` 目录到 `G:\80_Backup\WeChat\xwechat_files`，是零流量恢复主力；H 由 PCConfig 日任务在人工解锁窗口机会式冷备。
- **热备回执**：一次 G 盘热备成功后，脚本原子写入并回读 `G:\80_Backup\ControlPlane\wechat-hot-last.json`。回执只含 schema、完成时间、目标绑定、robocopy 退出码和排除项数量，不输出文件名或正文；PCConfig 用它判断微信热备是否足够新，再决定人工冷备窗口能否继续。
- **USB 人工冷备**：可把其 `xwechat_files` 路径显式传给恢复脚本的 `-BackupRoot`；不会自动扫盘或选择介质。
- **Drive 副本**：代码只使用用户已选 remote，远端缺失、对象缺失或对象不一致都会失败关闭；本次没有实际上传、改账号或修改现有云端对象，不能据此声称云端恢复已验收。
- **增量机制**：`robocopy /E` 和 `rclone copy --checksum` 只复制新增/内容变化文件；文件大小和修改时间相同但内容变化时也会被识别。
- **模式边界**：`-DbOnly` 只传 `db_storage`，不含图片、视频等媒体，不能称为完整原应用备份；`-DriveFull` 是兼容覆盖开关。`-MaxTransfer 8G` 只限制一次脚本进程，计划任务最多重试 5 次会产生新的单次额度；`-MaxTransfer 0` 只能用于明确的一次性补齐并持续人工观察。

**流量护栏**：静态快照上传(不直传使用中源目录，杜绝"边传边改"反复重传)、`-MaxTransfer 8G` 默认硬封顶。SQLite 的 `-wal`、`-shm` 与 journal 伴随文件会随原生目录保留；SQLite 明确说明 WAL 是数据库持久状态的一部分，分离时可能丢失已提交事务或损坏数据库，[官方说明](https://sqlite.org/wal.html#the_wal_file)。脚本不替应用做 checkpoint，也不把运行中复制称为一致快照。

**运行中一致性边界**：传输成功和 `rclone check` 只证明备份副本可比对，不证明微信在复制期间没有写入，也不证明日后官方客户端一定能接受它。该不确定性会如实保留；应用 owner 负责后续版本/账号兼容与真实恢复验收，不能因此停掉每日备份。

**恢复流程（默认不写入）**：

```powershell
# 先只读预检：检查备份源、目标保护、已知微信进程和可见客户端版本
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -Target E:\Documents\xwechat_files

# 确认官方微信已由你手动关闭，且目标为空后，才显式回填 G 盘热备
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -Execute -Target E:\Documents\xwechat_files

# 目标已有数据时，显式要求保留为同级 .pre-restore-* 回滚目录
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -Execute -ReplaceExisting -Target E:\Documents\xwechat_files

# 使用已人工确认的 USB 原生备份时，明确给出其目录；默认仍只做预检
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -BackupRoot <USB-xwechat_files-path> -Target E:\Documents\xwechat_files
```

`COPY_COMPLETE_AWAITING_HUMAN_ACCEPTANCE` 只表示原生目录已复制，不表示“微信已恢复”。此后由用户自行启动官方微信、按提示登录目标账号并确认预期历史可见；在此之前必须保留备份源与 `.pre-restore-*` 回滚目录。脚本不读取账号、数据库、聊天、媒体或密钥正文，也不自动关闭或启动微信。

恢复预检只证明源是可用的非空目录、目标和已知客户端状态可检查，并不做内容 hash 完整性验证。它拒绝盘符根目录、源/目标相同或互为父子目录，以及路径链上的 reparse point（重解析点）。复制失败时，部分结果移到 `.failed-restore-*`，再恢复 `.pre-restore-*` 原目录；`-DriveOnly` 仍是未完成真实联网验收的兼容路径。

本次闭合的范围是本地/G/人工指定 USB 的原生目录恢复，以及云端代码的失败关闭逻辑；`-DriveOnly` 与上传链路没有做真实联网验收，也不应从本次结果推导为云端已恢复或可用。

---

## 5. 安全说明（重要）

- 备份内**含明文凭据**：各 AI 工具 API key、`env-user.reg` 里的 `GITHUB_TOKEN/GEMINI_API_KEY/GOOGLE_API_KEY/OPENCLAW_GATEWAY_PASSWORD`、FinalShell/Xshell 服务器密码、GPG 私钥。
- **本仓库（公开）只放脚本，绝不放 zip/reg/任何备份数据**——见 `.gitignore`，并由 `tests/Assert-NoBackupArtifacts.ps1` 做提交前护栏检查。公开仓库泄露 token 会被爬虫几分钟内扫走。
- **U盘 + 私有 Google Drive 存明文的可信度**：
  - 私有 Drive（开 2FA）+ 自己保管的 U盘，对**可轮换的密钥**（token/API key）是可接受的；万一泄露，轮换即可。
  - **GPG 私钥不可轮换**，建议对 `.gnupg` 单独加密（或给整包加 7z AES-256 密码）。
  - U盘建议开 BitLocker，防物理丢失。
  - 红线：**永不进公开仓库**。

---

## 6. 项目文件

| 文件 | 作用 |
|---|---|
| `Backup-DevConfig.ps1` | 主脚本：采集→系统导出→清单→打包→分层分发（`-Tier Local/Hot/Drive`） |
| `Backup-WeChat.ps1` | 微信原应用数据增量备份；G 盘成功后发布不含文件名或正文的有界热备回执 |
| `Restore-WeChat.ps1` | 默认只读预检、显式原生目录回填与回滚保护；官方客户端验收仍由用户完成 |
| `Initialize-BackupNetwork.ps1` | 让无窗口计划任务在缺少进程代理变量时继承当前用户已启用的 Windows 代理，不保存固定代理地址 |
| `Monitor-WeChatDrive.ps1` | 每小时监控微信 Drive 备份进度；未完成且无上传进程时自动续传；成功后自动禁用监控任务 |
| `Install-WeChatDriveMonitor.ps1` | 注册/刷新微信 Drive 小时监控任务；直接运行 PowerShell，30 分钟硬超时，避免监控实例卡住 |
| `Setup-ScheduledTasks.ps1` | 注册/重建 DevConfig + WeChat 常规备份计划任务（幂等） |
| `ScheduledTask-Registration.Common.ps1` | 拒绝接管非本项目同名任务；注册前保存精确 XML 前像，逐项回读失败时恢复原定义 |
| `sources.psd1` | 备份源清单 + 排除规则（数据，改这里即可） |
| `AGENTS.md` | 仓库边界、PCConfig 分工、公开安全规则 |
| `tests/Assert-NoBackupArtifacts.ps1` | 检查 Git 候选文件中没有备份包、注册表导出、密钥容器、`.env` 或微信数据库 |
| `tests/Assert-WeChatNativeRecovery.ps1` | 合成 fixture 验证默认预检、回滚保护与“已复制/待官方客户端验收”状态区分 |
| `tests/Assert-ScheduledDriveProxy.ps1` | 检查后台 Drive 任务的代理继承与脚本接线 |
| `out/ staging/ state/ logs/` | 运行产物，**已 gitignore** |

---

## 7. 踩坑记录（给 AI/未来的自己）

- **psd1 必须逗号分隔 + UTF-8 BOM**：Windows PowerShell 5.1 的 `Import-PowerShellDataFile`
  拒绝分号分隔数组；无 BOM 时中文按本地代码页误解。pwsh7 宽容会掩盖此问题。
- **`-File` 的逗号陷阱**：`powershell -File x.ps1 -Tier Local,Hot` 会把 `Local,Hot` 当**单个字符串**
  传入（不是数组）。脚本已在入口 `-split ','` 归一化，并去掉了 `ValidateSet`。
- **任务计划不直接使用 Store 别名**：四个常规任务的 Action 是 `wscript.exe`。隐藏 VBS 先找
  `%ProgramFiles%\PowerShell\7\pwsh.exe`，存在就用 PowerShell 7；只有该固定路径不存在时才选择
  `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` 5.1。独立临时监控安装器固定用 5.1。
- **7z 非零不能装成成功**：当前脚本只有在采集、打包和请求的分发层全部完成后才返回 0；7z 返回警告或错误码时保留旧包、跳过本轮分发并让计划任务重试。

---

## 8. 命令速查

### 日常备份（手动触发，平时由计划任务自动跑）
```powershell
cd E:\Projects\Backups\devconfig-backup
.\Backup-DevConfig.ps1 -Tier Local          # 仅本地
.\Backup-DevConfig.ps1 -Tier Local,Hot      # 本地+G盘热备
.\Backup-DevConfig.ps1 -Tier Drive          # 把当前冻结的新代完整上传为日期包与 latest.zip
.\Backup-DevConfig.ps1 -Tier Local,Hot -IncludeHistory   # 连聊天历史一起备(+256M)

.\Backup-WeChat.ps1 -List                   # 微信干跑估算
.\Backup-WeChat.ps1 -Target Hot             # 微信增量到G盘热备
.\Backup-WeChat.ps1 -Target Hot,Drive       # 微信增量到G盘热备+Drive
.\Monitor-WeChatDrive.ps1                   # 手动检查微信Drive进度/必要时续传
.\Install-WeChatDriveMonitor.ps1            # 注册每小时监控，完成后监控脚本会自禁用
```

### 计划任务管理
```powershell
.\Setup-ScheduledTasks.ps1                  # 注册/重建常规备份任务
Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' | ft TaskName,State
Start-ScheduledTask DevConfigBackup-Local   # 手动生成本地包并刷新G热备
(Get-ScheduledTaskInfo DevConfigBackup-Local).LastTaskResult   # 0=成功
Start-ScheduledTask DevConfigBackup-Drive-Daily  # 手动补一次Drive
```

### 查看 Drive 上的备份
```powershell
rclone listremotes
rclone lsf  <remote>:Backups/WLY                       # 配置(3份带日期+latest)
rclone lsf  <remote>:Backups/WeChat/xwechat_files      # 微信
rclone about <remote>:                                 # 配额
```

### 🆘 新电脑完整恢复（按顺序）
```powershell
# 1. 装 PowerShell7 / Git / scoop(含7zip) / rclone / Windows Terminal / 各 IDE
#    （四个常规任务用 wscript 隐藏启动：优先 Program Files 下的 PowerShell 7，缺失时才用 5.1）

# 2. 取回最新配置包：优先从 G 热备，灾难场景再人工解锁 H 冷备；也可从 Drive 拉
rclone copy <remote>:Backups/WLY/latest.zip E:\restore\
& 'C:\Program Files\7-Zip\7z.exe' x E:\restore\latest.zip -oE:\restore\devconfig

# 3. 一键补软件
scoop import  E:\restore\devconfig\_manifests\scoop.json
winget import E:\restore\devconfig\_manifests\winget.json --accept-source-agreements
Get-Content E:\restore\devconfig\_manifests\vscode-extensions.txt | % { code --install-extension $_ }

# 4. 回填配置
#    home\*          -> %USERPROFILE%\
#    appdata-roaming\* -> %APPDATA%\        appdata-local\* -> %LOCALAPPDATA%\
#    extra\Scoop-persist\* -> E:\Scoop\persist\
robocopy E:\restore\devconfig\home          $env:USERPROFILE /E
robocopy E:\restore\devconfig\appdata-roaming $env:APPDATA   /E
robocopy E:\restore\devconfig\appdata-local   $env:LOCALAPPDATA /E

# 5. 还原系统设置
reg import E:\restore\devconfig\_system\env-user.reg      # 用户环境变量
reg import E:\restore\devconfig\_system\env-machine.reg   # 机器环境变量（管理员）
# 如只需核对机器 PATH，也可查看 _system\path-machine.txt
reg import E:\restore\devconfig\_system\xshell.reg        # Xshell 会话
# 不要把旧包里的任务 XML 批量导入；其中可能包含已退役的 H 盘写入任务。
node E:\PCConfig\tools\validate_scheduled_task_rebuild_plan.mjs
# 然后按 E:\PCConfig\docs\recovery\scheduled_tasks_rebuild.md 逐项恢复。
Get-ChildItem E:\restore\devconfig\_system\wifi\*.xml | % {
    netsh wlan add profile filename=$_.FullName }             # Wi-Fi
Copy-Item E:\restore\devconfig\_system\hosts $env:WINDIR\System32\drivers\etc\hosts

# 6. 取回微信原应用数据（可选，约 38G）
#    默认先做只读预检；确认官方微信已手动关闭后才显式复制。
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -Target E:\restore\xwechat_files
#    G 热备可用时用默认源；已有目标须显式保留回滚。
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -Execute -ReplaceExisting -Target E:\restore\xwechat_files
#    云端 `-DriveOnly` 在本次未联网验收；不要把它当作本地/G 恢复闭环的一部分。

# 7. 重挂备份任务 + 重配 Drive
rclone config        # 建并明确选择 Google Drive 远端；脚本不会自动改用其他名字
# 如 _manifests 中有 binding，只回填到这个固定本机位置；它不含 OAuth/token：
New-Item -ItemType Directory -Force E:\Projects\Backups\devconfig-backup\state
Copy-Item E:\restore\devconfig\_manifests\rclone-remote-binding.json E:\Projects\Backups\devconfig-backup\state\rclone-remote-binding.json
.\Setup-ScheduledTasks.ps1
```
复制完成后仍须由用户启动官方微信、登录目标账号并确认历史可见；在人工确认前保留备份源和脚本创建的 `.pre-restore-*` 目录。复制 exit code 或文件清单不能替代这一步。

> ⚠️ 恢复两大陷阱（详见 §3）：① 重设 Documents 指向 `E:\Documents`；② 新用户名保持 `10979`。
