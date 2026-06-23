# DevConfig Backup — 开发配置 / 凭据 / 系统设置 三级级联备份

> 面向"极端意外下快速重装新机"的灾备工具。**只备份真正不可再生的配置与凭据**，
> 软件本体、IDE 插件、npm 包、缓存等可重下内容一律剔除。
> 核心事实：原始一锅端是 **十几 GB**，精选后仅 **~170 MB**（打包后 **~65 MB**）。

本仓库只包含**工具脚本**。**备份数据（含 API key/私钥的 zip、注册表导出）永不进仓库**，
见 [.gitignore](.gitignore)。

---

## 1. 它备份什么

| 类别 | 内容 | 关键点 |
|---|---|---|
| **AI/Agent 配置** | `.claude .codex .gemini .openclaw .cline .cursor .lingma .qoder-cn .chatlab .copilot .cagent .codeg .agents` | 含各家 API key、MCP、自定义 agent/skill；剔除 packages/缓存/历史 |
| **密钥/凭据** | `.gnupg`(GPG 私钥)、`.docker/config.json`、`GitHub CLI`(gh token)、`.openclaw/.../client_secret.json` | 不可再生 |
| **编辑器** | VS Code / Cursor 的 `User\`(设置/快捷键/snippets/MCP)、JetBrains 设置(剔 plugins/jdbc-drivers)、Apifox、Typora、Windows Terminal | |
| **终端/代理** | FinalShell `conn\`(SSH会话+密码)、Clash Verge Rev `profiles\`(订阅)+yaml(剔 geo*.dat) | |
| **生产力** | PowerToys 配置、PixPin 配置、用户自装字体、Scoop `persist\` | |
| **散件** | `.gitconfig .zshrc .wakatime.cfg .claude.json .wslconfig .condarc .npmrc` | |
| **系统导出**(脚本现生成) | 环境变量(`HKCU\Environment`)、机器 PATH、20+ 个自定义计划任务 XML、hosts、Wi-Fi(含密码)、Xshell 注册表 | |
| **重装清单** | `scoop export`、`winget export`、VS Code/Cursor 扩展列表、JetBrains 插件名单、已装软件 CSV | 让"可重下"的部分一条命令补回 |

**默认剔除**（`-IncludeHistory` 可保留）：AI 聊天历史（`.claude\projects`、`.openclaw\session-backup*` 等，约 +256MB）。

**清单数据驱动**：增删备份项只改 [sources.psd1](sources.psd1)，不动脚本。

### 避坑（只取配置，不取缓存/本体）
- PowerToys：取 `AppData\Local\Microsoft\PowerToys`(1.3M)，**不是** 843M 的安装目录
- FinalShell：只取 `conn\`，**不是** 191M 的 JRE
- PixPin：只取 `Config`，**不是** 203M 的截图 `History`
- Clash：取 `profiles\`+yaml，剔 `geoip.dat/geosite.dat/Country.mmdb`(34M 可重下)
- JetBrains：剔 `plugins\`(10.6G)+`jdbc-drivers\`

---

## 2. 三级级联架构（按流量分配周期）

```
[Backup-DevConfig.ps1] ──产出──> ① 本地 out\devconfig-*.zip  (零流量)
                                      │
                          ┌───────────┴────────────┐
                          ▼                         ▼
                   ② U盘 H:\My_Digital_Backup   ③ Google Drive (rclone)
                      (零流量,插上才同步)         (海外额度,改动才传)
```

| 级 | 任务 | 周期/触发 | 流量 |
|---|---|---|---|
| ① 本地 | `DevConfigBackup-Local` (`-Tier Local,Usb,Drive`) | 每天 12:30 + 登录 | 本地/U盘无 |
| ② U盘 | 同上 + `DevConfigBackup-OnUSB` | 插U盘(NTFS卷挂载)即同步 | 无 |
| ③ Drive | 上面 Local 顺带 + `DevConfigBackup-Cloud` 兜底 | 每天 12:30/登录尝试 + 21:00 兜底；**连通性预检+sha变了才传+强重试续传** | 海外（多数天为 0） |
| 微信 | `WeChatBackup-Weekly` (`-Target Usb,Drive`) | 每周六 04:00，增量到U盘+Drive | U盘无;Drive~1.5G/周 |

> - **配置保留**：U盘 / Drive 各保留 **3 份带日期**（`devconfig-YYYYMMDD-HHMMSS.zip`）+ 一份 `latest.zip`。
> - **rclone 远端名自动探测**：脚本默认找 `gdrive:`，没有就用第一个已配置远端（本机实为 `<邮箱>:`）。
> - **微信选增量(非压缩包)**：微信 ~90% 是已压缩媒体，压缩省不到 10% 且单包无法增量；增量每周仅传变化的库(~1.5G)，一年比"全量压缩包"省 ~16 倍海外流量。
> - **增量是自动的**：robocopy(`/E`) 与 rclone(`copy`) 都按"文件名+大小+修改时间"比对，已存在且未变的文件自动跳过——首次全量后，每次只扫描+复制增量(变化的库+新增媒体)，速度快、流量小，无需担心。
> - **Drive 海外可靠性（针对断网/没开机/代理没开）**：① 到点没开机 → `StartWhenAvailable` 开机后补跑；② 代理/海外网络没就绪 → 连通性预检优雅跳过，下个窗口(登录/12:30/21:00)自动重试；③ 传到一半断 → `rclone copy` 幂等，下次从断点续传(只补没传完的)。
> - **看进度/日志**：`pwsh -File Backup-Status.ps1`（任务结果、本地/U盘/Drive 新鲜度、Drive 上次成功时间、微信上传进度、最近日志尾部）。

省流量三杠杆全在 ③：**改动才传** + **封顶每周** + `--bwlimit` 低峰。内容仅 ~65MB，满传也微不足道。

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
#    _system\*.reg 双击导入（环境变量/Xshell），_system\tasks\*.xml 用 schtasks /create 还原
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

聊天历史 ~**38 GB**（媒体在 `msg` 里，是历史本体，无法只留文字），太大不进配置包，单独走
[Backup-WeChat.ps1](Backup-WeChat.ps1)：

```powershell
pwsh -File Backup-WeChat.ps1 -List          # 先干跑估算
pwsh -File Backup-WeChat.ps1 -Target Usb     # 增量到U盘（robocopy /E，只增不删，零流量；推荐主力）
pwsh -File Backup-WeChat.ps1 -Target Drive   # 增量到 Drive（rclone copy，走海外流量，按需）
```

**全量+增量原理**：robocopy `/E` 与 rclone `copy` 都只复制新增/改动文件，且**从不删除**（历史永不丢）。
首次全量 ~38GB；之后仅复制变化的库(`db_storage`~1.5G)与新增媒体。
**建议**：U盘做主力（零流量），Drive 仅按需/低频（38G 首传费海外额度）。
已自动化：`WeChatBackup-Weekly` 每周六增量到U盘；首次全量(~38G)已完成。

---

## 5. 安全说明（重要）

- 备份内**含明文凭据**：各 AI 工具 API key、`env-user.reg` 里的 `GITHUB_TOKEN/GEMINI_API_KEY/GOOGLE_API_KEY/OPENCLAW_GATEWAY_PASSWORD`、FinalShell/Xshell 服务器密码、GPG 私钥。
- **本仓库（公开）只放脚本，绝不放 zip/reg/任何备份数据**——见 `.gitignore`。公开仓库泄露 token 会被爬虫几分钟内扫走。
- **U盘 + 私有 Google Drive 存明文的可信度**：
  - 私有 Drive（开 2FA）+ 自己保管的 U盘，对**可轮换的密钥**（token/API key）是可接受的；万一泄露，轮换即可。
  - **GPG 私钥不可轮换**，建议对 `.gnupg` 单独加密（或给整包加 7z AES-256 密码）。
  - U盘建议开 BitLocker，防物理丢失。
  - 红线：**永不进公开仓库**。

---

## 6. 项目文件

| 文件 | 作用 |
|---|---|
| `Backup-DevConfig.ps1` | 主脚本：采集→系统导出→清单→打包→三级分发（`-Tier Local/Usb/Drive`） |
| `Backup-WeChat.ps1` | 微信聊天记录增量备份 |
| `Setup-ScheduledTasks.ps1` | 注册 3 个计划任务（幂等） |
| `sources.psd1` | 备份源清单 + 排除规则（数据，改这里即可） |
| `out/ staging/ state/ logs/` | 运行产物，**已 gitignore** |

---

## 7. 踩坑记录（给 AI/未来的自己）

- **psd1 必须逗号分隔 + UTF-8 BOM**：Windows PowerShell 5.1 的 `Import-PowerShellDataFile`
  拒绝分号分隔数组；无 BOM 时中文按本地代码页误解。pwsh7 宽容会掩盖此问题。
- **`-File` 的逗号陷阱**：`powershell -File x.ps1 -Tier Local,Usb` 会把 `Local,Usb` 当**单个字符串**
  传入（不是数组）。脚本已在入口 `-split ','` 归一化，并去掉了 `ValidateSet`。
- **任务计划无法启动 Store 版 pwsh**：`(Get-Command pwsh).Source` 指向
  `C:\Program Files\WindowsApps\...\pwsh.exe`，任务计划起不来（结果码 1）。
  故启动器固定用 `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`（脚本兼容 5.1）。
- **脚本结尾 `exit 0`**：7z 遇到被占用文件返回警告码 1，显式 `exit 0` 让任务稳定报成功。

---

## 8. 命令速查

### 日常备份（手动触发，平时由计划任务自动跑）
```powershell
cd E:\DevConfigBackup
.\Backup-DevConfig.ps1 -Tier Local          # 仅本地
.\Backup-DevConfig.ps1 -Tier Local,Usb      # 本地+U盘
.\Backup-DevConfig.ps1 -Tier Drive          # 仅上 Drive（改动才传；-Force 强制）
.\Backup-DevConfig.ps1 -Tier Local,Usb -IncludeHistory   # 连聊天历史一起备(+256M)

.\Backup-WeChat.ps1 -List                   # 微信干跑估算
.\Backup-WeChat.ps1 -Target Usb             # 微信增量到U盘
.\Backup-WeChat.ps1 -Target Usb,Drive       # 微信增量到U盘+Drive
```

### 计划任务管理
```powershell
.\Setup-ScheduledTasks.ps1                  # 注册/重建全部 4 个任务
Get-ScheduledTask -TaskName 'DevConfigBackup-*','WeChatBackup-*' | ft TaskName,State
Start-ScheduledTask DevConfigBackup-Local   # 手动跑
(Get-ScheduledTaskInfo DevConfigBackup-Local).LastTaskResult   # 0=成功
Disable-ScheduledTask DevConfigBackup-Cloud # 临时停掉某个
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

# 2. 取回最新配置包：U盘直接拷，或从 Drive 拉
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
reg import E:\restore\devconfig\_system\env-user.reg      # 环境变量/PATH
reg import E:\restore\devconfig\_system\xshell.reg        # Xshell 会话
Get-ChildItem E:\restore\devconfig\_system\tasks\*.xml | % {
    schtasks /create /tn $_.BaseName /xml $_.FullName /f }    # 你的自动化任务
Get-ChildItem E:\restore\devconfig\_system\wifi\*.xml | % {
    netsh wlan add profile filename=$_.FullName }             # Wi-Fi
Copy-Item E:\restore\devconfig\_system\hosts $env:WINDIR\System32\drivers\etc\hosts

# 6. 取回微信（可选，38G）
rclone copy <remote>:Backups/WeChat/xwechat_files E:\Documents\xwechat_files --transfers 8

# 7. 重挂备份任务 + 重配 Drive
rclone config        # 建 Google Drive 远端（脚本会自动探测名字）
.\Setup-ScheduledTasks.ps1
```

> ⚠️ 恢复两大陷阱（详见 §3）：① 重设 Documents 指向 `E:\Documents`；② 新用户名保持 `10979`。
