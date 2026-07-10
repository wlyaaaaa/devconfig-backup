# 微信增量完整性与恢复流程 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints.

**Goal:** 将微信备份改为“静态快照 + checksum 增量 + 内容级校验 + Drive 全量恢复”，并退役只用于首次补齐的小时监控任务。

**Architecture:** 每周任务刷新本地静态快照后，从快照执行 rclone copy --checksum；未变化文件只做哈希/元数据比较，变化文件才上传。上传结束后运行不带 --size-only 的 rclone check，校验失败则返回失败并等待下一周重试。恢复脚本保留 U 盘优先路径，同时新增仅 Drive 时下载完整媒体和数据库的路径。

**Tech Stack:** Windows PowerShell 5.1-compatible scripts, rclone, robocopy, Windows Task Scheduler, custom PowerShell regression tests, GitHub public-safe repository.

## Global Constraints

- 不把聊天数据、密钥、原始日志、.env、数据库或备份包写入 Git。
- Drive 增量必须保留 --max-transfer 8G 流量保险丝。
- 静态快照必须与正在运行的微信源目录分离。
- 默认备份只增不删；不因云端差异自动删除远端对象。
- 内容校验使用 MD5/hash，不得继续把 --size-only 当作完整性证明。
- 计划任务实际执行本地工作区文件；GitHub 推送不会自动更新本机脚本。
- 实施期间先暂停旧的 WeChatBackup-Weekly，完成测试和云端修复后再恢复。
- WeChatDrive-Monitor-Hourly 只作为首次全量补齐工具；完成后保持 Disabled，不删除，便于回滚。

## Current Evidence

- rclone check --size-only：127731 matching files，0 differences。
- 普通 MD5 rclone check：127717 matching files，14 differences。
- 差异集中在微信配置/MMKV 文件及 .crc 配对文件，未发现消息数据库或媒体缺失。
- 最终上传日志记录主上传 exit=0、密钥上传 exit=0、==== 完成 ====。
- WeChatDrive-Monitor-Hourly 当前仍可能处于 Running/扫描状态；以实时 Windows Task Scheduler 为准，PCConfig 旧登记需在收尾后刷新。
- WeChatBackup-Weekly 当前启用，下一次本机约 2026-07-11 20:00；修复前不得让它继续使用旧逻辑。

## File Map

- Modify: Backup-WeChat.ps1 — checksum 增量、内容校验、失败退出码、-List 语义。
- Modify: Monitor-WeChatDrive.ps1 — 仅保留临时补齐用途；最终校验改为 hash，识别所有相关 rclone 操作。
- Modify: Restore-WeChat.ps1 — 新增 Drive-only 全量恢复媒体和数据库。
- Modify: README.md — 周任务、自包含校验、恢复命令、流量与失败语义。
- Create: tests/Assert-WeChatIncrementalIntegrity.ps1 — 本地临时 fixture 的同大小同时间变更回归测试。
- Modify: tests/Assert-NoBackupArtifacts.ps1 only if the new test fixture needs an additional public-safe allowlist rule; do not weaken artifact protections.
- Machine fact: live Windows task state and E:\PCConfig\registries\tasks.json; update only through the PCConfig owner flow after live verification.
- Cloud data: repair only the 14 checksum differences; never upload the repository or expose keys.

---

### Task 1: Freeze Runtime State Before Code Changes

**Files:**
- Read: E:\Projects\Backups\devconfig-backup\Backup-WeChat.ps1
- Read: E:\Projects\Backups\devconfig-backup\Monitor-WeChatDrive.ps1
- Read: E:\Projects\Backups\devconfig-backup\Backup-WeChat-Hidden.vbs
- Machine: WeChatBackup-Weekly, WeChatDrive-Monitor-Hourly

**Interfaces:**
- Consumes: current Windows Task Scheduler state and current process list.
- Produces: a recorded baseline showing no active old upload before code rollout.

- [ ] Record current UTC, local time, China time, task states, last results, next runs, and relevant rclone command lines.
- [ ] Wait for the current WeChatDrive-Monitor-Hourly run to finish naturally; do not kill an active rclone size or rclone check operation.
- [ ] Disable WeChatBackup-Weekly before its next trigger with Disable-ScheduledTask -TaskName 'WeChatBackup-Weekly'.
- [ ] Confirm no Backup-WeChat.ps1 or WeChat Drive upload process remains before editing.
- [ ] Do not delete WeChatDrive-Monitor-Hourly; leave it available for rollback until the new weekly flow has passed one successful cycle.

Expected result: no old weekly job can start while checksum changes are being tested, and no running backup process is interrupted.

---

### Task 2: Write the Failing Incremental Integrity Test

**Files:**
- Create: tests/Assert-WeChatIncrementalIntegrity.ps1

**Interfaces:**
- Consumes: rclone.exe from PATH or E:\Scoop\shims\rclone.exe.
- Produces: exit code 0 only when checksum update, no-change skip, size-only contrast, and artifact cleanup all pass.

- [ ] Create a temporary fixture under $env:TEMP with source and remote directories; never use E:\Documents\xwechat_files, E:\WeChatBackup, or the real Drive remote.
- [ ] Write a fixed-size test file and record its original UTC modification time and MD5.
- [ ] Run a first rclone copy source remote; assert exit code 0.
- [ ] Change only the bytes while preserving file length and restoring the original modification time.
- [ ] Run the pre-fix comparison without --checksum and assert the remote hash remains stale; this documents the regression that produced the real 14-file mismatch.
- [ ] Run rclone copy source remote --checksum; assert local and remote MD5 now match.
- [ ] Run a second unchanged rclone copy source remote --checksum --dry-run; assert no Copied/Transferred action is reported.
- [ ] Run rclone check source remote --one-way; assert exit code 0.
- [ ] Put cleanup in a finally block and remove the temporary fixture even when an assertion fails.

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

Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Assert-WeChatIncrementalIntegrity.ps1

Expected: FAIL before the implementation adds checksum-aware behavior; PASS after the implementation.

---

### Task 3: Make Backup-WeChat Checksum-Aware and Self-Verifying

**Files:**
- Modify: Backup-WeChat.ps1:252-303
- Test: tests/Assert-WeChatIncrementalIntegrity.ps1

**Interfaces:**
- Consumes: existing $LocalRoot, $GDriveRemote, $GDriveFolder, $MaxTransfer, and $filter.
- Produces: a Drive backup that returns nonzero when content verification fails.

- [ ] Add --checksum to the $rc argument array immediately after --fast-list; keep --bwlimit, --transfers, retries, and --max-transfer 8G.
- [ ] Preserve the static snapshot rule for real Drive uploads; the rclone source must remain $LocalRoot, never the live WeChat source.
- [ ] After rclone copy returns, run a normal rclone check $LocalRoot $dest with the same excludes, --one-way, --fast-list, and --checkers 16; do not add --size-only.
- [ ] Record separate copy exit, check exit, and key upload exit values in the log.
- [ ] Set a script-level $overallExitCode = 0; set it to 1 on copy, hash-check, key-upload, or connectivity failure; replace the unconditional final exit 0 with exit $overallExitCode.
- [ ] Keep -Target Usb behavior unchanged except for shared error reporting.
- [ ] Keep --max-transfer 8G; a cutoff or incomplete set must fail the content check and be retried by the next weekly run.
- [ ] Make -List a true no-cloud-write mode. For Drive list mode, skip the real snapshot refresh and run rclone copy $Source $dest --dry-run with the same filters; never write to the real snapshot in list mode.

Verification:

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Assert-WeChatIncrementalIntegrity.ps1
powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.Management.Automation.Language.Parser]::ParseFile('Backup-WeChat.ps1',[ref]$null,[ref]$null) | Out-Null"
~~~~

Expected: the fixture proves same-size/same-time content changes are repaired; parser returns no errors.

---

### Task 4: Simplify the Monitor and Define Its Retirement

**Files:**
- Modify: Monitor-WeChatDrive.ps1:98-190
- Read: Install-WeChatDriveMonitor.ps1

**Interfaces:**
- Consumes: the weekly script's self-verifying exit code and current rclone process list.
- Produces: a safe temporary catch-up monitor that cannot launch duplicate uploads and is disabled after hash verification.

- [ ] Detect all relevant rclone operations whose command line contains the WeChat source or destination, including copy, size, and check; do not treat only copy as active.
- [ ] Change the monitor's final check arguments from --size-only to ordinary hash checking.
- [ ] Only call Disable-ScheduledTask after hash check exit code 0; log the matching count and explicit verification result.
- [ ] If a hash check fails, log the failure and leave the task enabled for catch-up; do not start another upload while any relevant rclone process is alive.
- [ ] Keep the script usable for manual recovery, but document that the scheduled task is temporary and should be disabled after the first full verified backup.
- [ ] Add a focused parser/source assertion that the monitor no longer contains --size-only in its final verification arguments.

Run:

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.Management.Automation.Language.Parser]::ParseFile('Monitor-WeChatDrive.ps1',[ref]$null,[ref]$null) | Out-Null"
~~~~

Expected: monitor has no duplicate-launch path and uses content-level final verification.

---

### Task 5: Add Drive-Only Full Restore

**Files:**
- Modify: Restore-WeChat.ps1:19-75
- Modify: README.md:200-240

**Interfaces:**
- Add switch: [switch] $DriveOnly.
- Default mode: preserve current U盘 full merge plus Drive db_storage update.
- Drive-only mode: copy the full Drive tree to $Target with the same excludes used by backup, then copy _KEYS beside the target and print the WeFlow/wx_key decrypt instructions.

- [ ] Add $DriveOnly to the parameter block.
- [ ] When -DriveOnly is set, skip the U盘 robocopy branch and run rclone copy $src $Target with --exclude cache/**, Cache/**, temp/**, Temp/**, WMPF/**, apm_record/**, crash/**, FileStorageTemp/**, recommend_cover/**, *.db-wal, *.db-shm, and *.db-journal.
- [ ] Keep -List as robocopy /L or rclone --dry-run; no target or key files may be written in list mode.
- [ ] Return nonzero when Drive is unreachable or the full restore copy fails.
- [ ] Add a README command:

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -DriveOnly -Target E:\Restore\xwechat_files
~~~~

- [ ] State explicitly that this restores data for WeFlow/wx_key viewing and does not guarantee direct import into the official WeChat client.

Verification:

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Restore-WeChat.ps1 -DriveOnly -List -Target (Join-Path $env:TEMP 'wechat-restore-list')
~~~~

Expected: only a dry-run is produced; no target or key file is created.

---

### Task 6: Document the New Weekly-Only Operating Model

**Files:**
- Modify: README.md
- Modify: AGENTS.md only if the repository boundary or verification rule changes; do not duplicate PCConfig machine facts.

- [ ] Document that WeChatBackup-Weekly is the normal recurring job and WeChatDrive-Monitor-Hourly is temporary catch-up only.
- [ ] Document that rclone copy --checksum is the incremental comparison rule and that unchanged files consume no upload bytes.
- [ ] Document that ordinary rclone check is required for content integrity; --size-only is not a completion proof.
- [ ] Document the 8G per-run cap and how the next weekly run continues after an incomplete run.
- [ ] Document the 14-file repair as a one-time checksum reconciliation, not a full re-upload.
- [ ] Document the two restore paths: U盘-first merge and Drive-only full restore.
- [ ] Keep all examples free of real remote account names, tokens, keys, raw logs, and chat identifiers.

---

### Task 7: Run Repository Verification Before Cloud Repair

**Files:**
- Read/execute: tests/Assert-NoBackupArtifacts.ps1
- Execute: tests/Assert-WeChatIncrementalIntegrity.ps1
- Execute: PowerShell parser checks for all modified scripts

- [ ] Run:

~~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Assert-NoBackupArtifacts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Assert-WeChatIncrementalIntegrity.ps1
~~~~

- [ ] Parse Backup-WeChat.ps1, Monitor-WeChatDrive.ps1, and Restore-WeChat.ps1 with [System.Management.Automation.Language.Parser]::ParseFile.
- [ ] Confirm git status --short contains only intended public-safe source, test, docs, and plan files.
- [ ] Confirm no xwechat_files, db_storage, chat database, archive, key, .env, or raw log is a Git candidate.
- [ ] Do not repair Drive if any repository test fails.

---

### Task 8: Repair the 14 Cloud Differences Without Full Re-upload

**Files:**
- Cloud target: Backups/WeChat/xwechat_files
- Source: E:\WeChatBackup\xwechat_files static snapshot
- Log: a new local log under E:\Projects\Backups\devconfig-backup\logs\

- [ ] Confirm the source snapshot is stable and no WeChat upload process is active.
- [ ] Run a one-time checksum-aware incremental copy from the static snapshot using the production excludes, --checksum, retries, and --max-transfer 8G.
- [ ] Do not use --delete, --purge, --ignore-times, or a full archive.
- [ ] Run ordinary rclone check --one-way with the same excludes after the copy.
- [ ] Require 0 differences, 0 missing, and exit code 0; record the matching count and the repaired file count.
- [ ] Treat duplicate-object notices as a separate non-blocking cleanup report; do not delete duplicate Drive objects in this task.

Expected: only the stale same-size/same-time objects are uploaded; no full 38GB transfer occurs.

---

### Task 9: Roll Out the Weekly-Only Task Model

**Files:**
- Machine: Windows Task Scheduler
- Machine record: E:\PCConfig\registries\tasks.json
- Optional owner notes: relevant PCConfig task purpose entry

- [ ] After Task 8 passes, keep WeChatDrive-Monitor-Hourly Disabled; do not unregister it until one weekly cycle is verified.
- [ ] Re-enable WeChatBackup-Weekly only after the local DEV scripts are the tested version.
- [ ] Run one manual Backup-WeChat.ps1 -Target Drive or start the weekly task with the same production arguments, depending on the approved rollout path.
- [ ] Confirm log sequence: snapshot refresh, checksum-aware copy, hash check exit 0, key upload exit 0.
- [ ] After one successful weekly cycle, refresh PCConfig's read-only task registry and ensure it records the monitor as disabled/temporary and the weekly task as enabled.
- [ ] If the weekly run fails, leave the monitor disabled, preserve the failure log, and rerun only after fixing the reported cause; do not silently revert to size-only checking.

---

### Task 10: Git Closeout and Public-Safe Publication

**Files:**
- All intended changed files in E:\Projects\Backups\devconfig-backup

- [ ] Run the repository tests and parser checks again from a clean worktree candidate set.
- [ ] Review the diff for secrets, raw paths that are not already public-safe, keys, chat content, raw logs, and generated backup artifacts.
- [ ] Commit source, tests, docs, and the implementation plan with a focused message such as fix: verify WeChat incremental backups by checksum.
- [ ] Push only the public-safe DEV repository after verification.
- [ ] Run the GitHub index fast path required by git-change-closeout; do not add raw task XML, secrets, or cloud logs to the public index.
- [ ] Report affected_fact_domains: ["business","machine","git"], target branch, commit hash, push status, and whether PCConfig was refreshed.

## Acceptance Criteria

- A same-size/same-mtime content change is detected and repaired by the regression test.
- An unchanged incremental run performs no data upload.
- Production Drive copy uses checksum comparison and retains the 8G cap.
- Production completion requires ordinary content-level rclone check.
- The 14 known cloud differences are repaired without a full re-upload.
- Drive-only restore downloads the complete backup tree and places keys beside the restore directory without exposing key values.
- WeChatDrive-Monitor-Hourly is disabled after verified catch-up and is not required for normal weekly operation.
- WeChatBackup-Weekly runs the tested local code and returns a failure signal when copy or verification fails.
- Public GitHub contains only scripts, tests, documentation, and plan metadata; no backup data or secrets.

## Risks and Mitigations

- Hash scan is slower: it costs local CPU and metadata enumeration, not full upload bandwidth; run weekly and keep the 8G cap.
- WeChat source changes during snapshot: continue using the static snapshot and never upload the live source directory.
- Weekly task starts before code rollout: disable it during implementation and re-enable only after tests pass.
- Drive duplicate objects: report and review separately; no automatic destructive deduplication.
- PCConfig registry drift: treat live Task Scheduler as truth, refresh the registry only after the final task state is stable.
