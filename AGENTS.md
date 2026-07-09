# DevConfig Backup Agent Rules

This repository is public-safe backup tooling for DevConfig and WeChat backup automation. Keep it as a tool repository, not a second configuration and recovery center.

## Ownership Boundary

- `E:\PCConfig` is the machine configuration and recovery center. It owns machine facts, path inventory, scheduled task meaning, restore order, migration gates, and private configuration recovery runbooks.
- `E:\GitHub总索引` owns GitHub repository identity, visibility, branch state, push policy, and public-safe synchronization records.
- This repository owns only the backup scripts, source selection rules, hidden launchers, focused tests, and tool-local documentation for DevConfig and WeChat backup flows.
- When a change affects paths, scheduled tasks, restore semantics, local data sources, drive targets, rclone behavior, or migration state, update or consult PCConfig instead of duplicating those facts here.

## Public Boundary

- Treat this repository as public-safe backup tooling even if GitHub visibility changes later.
- Do not commit real backup data, expanded staging content, raw credentials, secret values, chat databases, private logs, screenshots, or machine recovery dumps.
- Keep generated backup directories out of Git: `out/`, `staging/`, `state/`, and `logs/`.
- Keep backup and secret container files out of Git: `*.zip`, `*.7z`, `*.reg`, `*.kdbx`, `*.pfx`, `*.pem`, `*.key`, and `.env` files.
- Keep WeChat restore materials out of Git: SQLCipher keys, `xwechat_files`, `db_storage`, message databases, media backups, and extracted chat content.

## Change Rules

- Prefer editing `sources.psd1` for backup source selection changes before changing script logic.
- Keep PowerShell scripts compatible with Windows PowerShell 5.1 unless a wrapper explicitly chooses PowerShell 7.
- PowerShell scripts containing non-ASCII constants must be saved as UTF-8 with BOM.
- Before finishing a change, run the focused tests under `tests/` and a parse check for changed PowerShell scripts.
- If a test or script needs current machine facts, read them from PCConfig or the owning runtime instead of copying private state into this repository.

## Verification

- Run `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Assert-NoBackupArtifacts.ps1` before staging changes.
- Run the relevant focused test for the area changed, such as `tests\Assert-DockerScope.ps1` or `tests\Assert-HDriveSafety.ps1`.
- Before any push while the repository remains public, verify that `git ls-files` contains no backup artifacts or secret containers.
