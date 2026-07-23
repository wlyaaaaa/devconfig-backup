# DevConfig Backup — 开发配置 / 凭据 / 系统设置分层备份

> 面向"极端意外下快速重装新机"的灾备工具。**只备份真正不可再生的配置与凭据**，
> 软件本体、IDE 插件、npm 包、缓存等可重下内容一律剔除。
> 核心事实：原始一锅端是 **十几 GB**，精选后仅 **~170 MB**（打包后 **~65 MB**）。

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

**默认剔除**（`-IncludeHistory` 可保留）：AI 聊天历史（`.claude\projects`、`.openclaw\session-backup*` 等，约 +256MB）。

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
                      (在线,计划任务主力)          (海外额度,改动才传)
                   ④ H: 冷备（由 PCConfig 在人工维护窗口从 G 刷新）
```

| 级 | 任务 | 周期/触发 | 流量 |
|---|---|---|---|
| ① 本地 + G盘热备 | `DevConfigBackup-Local` (`-Tier Local,Hot`) | 每天 21:05 + 登录后20分钟；错过补跑、失败重试3次 | 无 |
| ② Drive | `DevConfigBackup-Drive-Daily` (`-Tier Drive`) | 每天 22:00；有网才跑、失败重试5次 | 海外（sha 变化才传） |
| 微信 G盘热备 | `WeChatBackup-Hot-Weekly` (`-Target Hot`) | 每周六 20:00；错过补跑、失败重试3次 | 无 |
| 微信 Drive | `WeChatBackup-Drive-Weekly` (`-Target Drive`) | 每周日 20:00；有网才跑、失败重试5次 | 只传新增/变化文件并做内容校验 |

> - **介质原则(2026-07调整)**：G盘是可直接访问的在线热备；H盘是默认 BitLocker 锁定的冷备，只在人工维护窗口刷新，不注册计划任务。
> - **配置保留**：G盘 / Drive 各保留 **3 份带日期**（`devconfig-YYYYMMDD-HHMMSS.zip`）+ 一份 `latest.zip`；H盘只接收 PCConfig 统一的 `G → H` 冷备。
> - **rclone 远端名自动探测**：脚本默认找 `gdrive:`，没有就用第一个已配置远端（本机实为 `<邮箱>:`）。
> - **微信完整历史上云**：微信 38GB 里大部分是已压缩媒体，压缩收益很小；因此不用全量压缩包，而是用 `rclone copy --checksum` 逐文件增量，已上传且内容未变的文件自动跳过。默认单次 Drive 上传有 **8G 流量保险丝**，防止异常情况下大额重传。
> - **增量是自动的**：robocopy(`/E`) 先刷新静态快照，rclone(`copy --checksum`) 按内容 hash 判断是否变化；只传新增或内容变化的文件，数据库仍是**整文件级**增量。
> - **内容校验是完成条件**：上传后执行普通 `rclone check`；`--size-only` 只能证明大小一致，不能证明内容一致。
> - **Drive 海外可靠性**：① 没开机 → `StartWhenAvailable` 开机补跑一次；② 代理/远端没就绪 → 脚本返回失败，由任务级重试继续；③ 传一半断 → `rclone copy` 幂等续传；④ 本地/G 与 Drive 分任务，离线不会阻断热备。
> - **小时监控是临时工具**：`WeChatDrive-Monitor-Hourly` 只用于首次全量补齐，首次内容级校验通过后禁用；正常运行依赖 `WeChatBackup-Hot-Weekly` 与 `WeChatBackup-Drive-Weekly`。
> - **看进度/日志**：`pwsh -File Backup-Status.ps1`。
> - **H盘边界**：本项目不直接写 H。冷备由 `E:\PCConfig\tools\Invoke-HotToColdBackup.ps1` 在人工解锁窗口把固定 G 热备集合复制到 H，完成后重新锁定。

---

## 3. 在新电脑上恢复（重装后）

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
rclone config        # 新建名为 gdrive 的 Google Drive 远端（OAuth，需挂代理）
```

> ⚠️ **两个恢复陷阱**（务必注意）：
> 1. **Documents 在 E 盘**：重装后"我的文档"默认指向 `C:\Users\<你>\Documents`，Xshell/Navicat 会读到空目录。
>    解决：右键"文档"→属性→位置→移动 到 `E:\Documents`，旧配置瞬间满血。
> 2. **用户名必须仍是 `10979`**：很多配置里固化了 `C:\Users\10979\...` 绝对路径。
>    新建用户时保持同名，或恢复后批量文本替换路径。

---

## 4. 微信聊天记录备份（独立流）

聊天历史 ~**38 GB**（媒体是历史本体），太大不进配置包，单独走 [Backup-WeChat.ps1](Backup-WeChat.ps1)。
⚠️ **微信 db 是 SQLCipher 加密——没有密钥，备份的 db 只是一堆乱码**（见下「解密密钥」）。

```powershell
pwsh -File Backup-WeChat.ps1 -List          # 干跑:刷新本地快照后列出待传量
pwsh -File Backup-WeChat.ps1 -Target Hot     # 全量到G盘热备(robocopy /E,只增不删,零流量;主力)
pwsh -File Backup-WeChat.ps1 -Target Drive   # 完整聊天记录增量到Drive(含媒体;已传自动跳过;默认8G封顶)
pwsh -File Backup-WeChat.ps1 -Target Drive -MaxTransfer 0   # 一次性补齐模式(关闭封顶,需人工看进度)
pwsh -File Backup-WeChat.ps1 -Target Drive -DbOnly   # 临时省流量模式:只传db_storage
```

**当前策略：完整聊天记录逐文件增量上云**：
- **Drive 全量历史**：`xwechat_files` 剔除 cache/temp/WMPF/apm_record 和 SQLite 运行时 wal/shm/journal 后，聊天数据库与媒体都上云。
- **G盘全量历史**：同样保留完整聊天记录，是零流量热备主力；H盘仅人工冷备。
**增量机制**：`robocopy /E` 刷新静态快照，`rclone copy --checksum` 自动跳过内容未变化文件；首次是全量，之后只传新增/变化。即使文件大小和修改时间不变，只要内容变化也会被识别。

**解密密钥（恢复命门）**：微信4.x db 用 SQLCipher，密钥 = IMEI+UIN 派生、不随版本变、**必须本机提取**。已提取两账号密钥固化到 `_KEYS`(U盘 + 本地 `E:\WeChatBackup`，**不进git**)。**绝不可丢**：当前 4.1.10 版本下 WeFlow GUI 提取已被封、wx_key 也已停更，丢了难重提；wx_key v2.1.8 工具留存于 `E:\WeChatBackup\_tools`。

**流量护栏**：静态快照上传(不直传使用中源目录，杜绝"边传边改"反复重传)、排除 wal/shm、`-MaxTransfer 8G` 默认硬封顶。checksum 扫描增加本地哈希计算和 Drive 元数据读取，但不会把未变化文件重新上传。db 是**整文件级**增量，故 Drive **每周一次**即可。

本次首次补齐曾发现 14 个同大小同时间但内容不同的配置/MMKV 文件；修复后以普通 `rclone check` 的 0 differences 为最终证据，不再使用 `--size-only` 作为完成证明。

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
| `Backup-WeChat.ps1` | 微信聊天记录增量备份 |
| `Monitor-WeChatDrive.ps1` | 每小时监控微信 Drive 备份进度；未完成且无上传进程时自动续传；成功后自动禁用监控任务 |
| `Install-WeChatDriveMonitor.ps1` | 注册/刷新微信 Drive 小时监控任务；直接运行 PowerShell，30 分钟硬超时，避免监控实例卡住 |
| `Setup-ScheduledTasks.ps1` | 注册/重建 DevConfig + WeChat 常规备份计划任务（幂等） |
| `sources.psd1` | 备份源清单 + 排除规则（数据，改这里即可） |
| `AGENTS.md` | 仓库边界、PCConfig 分工、公开安全规则 |
| `tests/Assert-NoBackupArtifacts.ps1` | 检查 Git 候选文件中没有备份包、注册表导出、密钥容器、`.env` 或微信数据库 |
| `out/ staging/ state/ logs/` | 运行产物，**已 gitignore** |

---

## 7. 踩坑记录（给 AI/未来的自己）

- **psd1 必须逗号分隔 + UTF-8 BOM**：Windows PowerShell 5.1 的 `Import-PowerShellDataFile`
  拒绝分号分隔数组；无 BOM 时中文按本地代码页误解。pwsh7 宽容会掩盖此问题。
- **`-File` 的逗号陷阱**：`powershell -File x.ps1 -Tier Local,Hot` 会把 `Local,Hot` 当**单个字符串**
  传入（不是数组）。脚本已在入口 `-split ','` 归一化，并去掉了 `ValidateSet`。
- **任务计划无法启动 Store 版 pwsh**：`(Get-Command pwsh).Source` 指向
  `C:\Program Files\WindowsApps\...\pwsh.exe`，任务计划起不来（结果码 1）。
  故启动器固定用 `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`（脚本兼容 5.1）。
- **脚本结尾 `exit 0`**：7z 遇到被占用文件返回警告码 1，显式 `exit 0` 让任务稳定报成功。

---

## 8. 命令速查

### 日常备份（手动触发，平时由计划任务自动跑）
```powershell
cd E:\Projects\Backups\devconfig-backup
.\Backup-DevConfig.ps1 -Tier Local          # 仅本地
.\Backup-DevConfig.ps1 -Tier Local,Hot      # 本地+G盘热备
.\Backup-DevConfig.ps1 -Tier Drive          # 仅上 Drive（改动才传；-Force 强制）
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
#    （Store 版 pwsh 任务计划起不来，本工具的任务固定用 powershell.exe 5.1）

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

# 6. 取回微信（可选，约 38G）
#    只有 Drive 时，下载完整数据库+媒体+配置（缓存和 SQLite 运行时文件会排除）
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -DriveOnly -Target E:\restore\xwechat_files
#    有 U 盘时，默认模式先合并 U 盘全量，再从 Drive 补更新 db_storage
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -Target E:\restore\xwechat_files

# 7. 重挂备份任务 + 重配 Drive
rclone config        # 建 Google Drive 远端（脚本会自动探测名字）
.\Setup-ScheduledTasks.ps1
```
`Restore-WeChat.ps1 -DriveOnly` 会把 `_KEYS` 下载到恢复目录旁边；恢复后使用 WeFlow 或 `wx_key` 指定数据目录并填入对应 decryptKey。它用于解密查看和导出聊天记录，不保证可以直接导入官方微信客户端。

> ⚠️ 恢复两大陷阱（详见 §3）：① 重设 Documents 指向 `E:\Documents`；② 新用户名保持 `10979`。
