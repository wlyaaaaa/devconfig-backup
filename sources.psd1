@{
    # ============================================================
    # DevConfig 备份源清单（数据，非代码）
    # ~ = $env:USERPROFILE (C:\Users\10979)
    # 注意：psd1 受限语言，数组元素用逗号或换行分隔，不能用分号
    # ============================================================

    # 单个文件（散件 + 密钥配置）
    HomeFiles = @(
        '.gitconfig',
        '.zshrc',
        '.bash_history',
        '.wakatime.cfg',
        '.claude.json',
        '.claude.json.backup',
        '.wslconfig',
        '.condarc',
        '.npmrc'
    )

    # home 下目录（整目录拷入，按 ExcludeDirs/ExcludeFiles 剔除缓存/插件）
    HomeDirs = @(
        '.gnupg',
        '.config',
        '.docker',
        '.claude',
        '.codex',
        '.gemini',
        '.openclaw',
        '.cline',
        '.cursor',
        '.lingma',
        '.qoder-cn',
        '.chatlab',
        '.codeg',
        '.copilot',
        '.cagent',
        '.agents'
    )

    # AppData\Roaming 下目录
    AppDataRoamingDirs = @(
        'Code\User',
        'Cursor\User',
        'JetBrains',
        'Apifox',
        'Typora',
        'WhirlwindFX\SignalRgb',
        'GitHub CLI',
        'io.github.clash-verge-rev.clash-verge-rev'
    )

    # AppData\Local 下目录（精确子目录，避开 GB 级缓存/安装目录）
    AppDataLocalDirs = @(
        'Microsoft\PowerToys',
        'Microsoft\Windows\Fonts',
        'PixPin\Config',
        'finalshell\conn'
    )

    # AppData\Local 下单文件
    AppDataLocalFiles = @(
        'PixPin\LocalStorage.data'
    )

    # 任意绝对路径目录（非 home 下）
    ExtraDirs = @(
        @{ Src = 'E:\Scoop\persist'; Name = 'Scoop-persist' }
    )

    # 特殊单文件（相对 home）
    SpecialFiles = @(
        '.openclaw\workspace\client_secret.json'
    )

    # 始终排除的目录名（robocopy /XD）
    ExcludeDirs = @(
        'plugins', 'jdbc-drivers', 'node_modules', 'npm', 'packages', 'extensions',
        'shared_client', 'antigravity', 'worktrees', 'bin', 'share', 'nlp',
        'cache', 'caches', 'Cache', 'Cache_Data', 'GPUCache', 'DawnCache',
        'blob_storage', 'Crashpad', 'Code Cache', 'CacheStorage', 'Service Worker',
        'Session Storage', 'VideoDecodeStats', 'Shared Dictionary',
        'logs', '.tmp', 'tmp', 'temp', '.git', 'History', 'OcrModel'
    )

    # 始终排除的文件名（robocopy /XF，可重下的大数据文件）
    ExcludeFiles = @(
        '*.tmp',
        'geoip.dat', 'geosite.dat', 'Country.mmdb',
        'Cookies', 'Cookies-journal', 'History', 'History-journal',
        'Favicons', 'Favicons-journal', 'Visited Links',
        'Network Persistent State', 'TransportSecurity',
        'Trust Tokens', 'Trust Tokens-journal', 'SharedStorage'
    )

    # 历史/对话日志目录名（默认排除；-IncludeHistory 时保留）
    HistoryDirs = @(
        'projects', 'data', 'session-backup*'
    )

    # 自定义计划任务白名单（通配匹配 TaskName）
    ScheduledTaskPatterns = @(
        'AutoDigitalBackupToH', 'Scripts_AutoPush', 'RAMDisk_Code_Backup',
        'TimeAudit*', 'OpenClaw*', 'WeFlow*', 'natpierce*',
        'Cloud', 'GCC', 'ModifyLinkUpdate', 'CleanupOrphanedMillennium'
    )

    # 注册表导出（凭据/会话存在注册表里）
    RegistryExports = @(
        @{ Name = 'env-user'; Key = 'HKCU\Environment' },
        @{ Name = 'xshell';   Key = 'HKCU\Software\NetSarang' }
    )
}
