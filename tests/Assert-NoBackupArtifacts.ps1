param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-Text {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "Assertion failed: $Name" }
    Write-Host "PASS: $Name"
}

function Assert-NoMatch {
    param(
        [string]$Name,
        [string[]]$Values,
        [string]$Pattern
    )
    $hits = @($Values | Where-Object { $_ -match $Pattern })
    Assert-Text $Name ($hits.Count -eq 0)
}

$gitFiles = @(git -C $RepoRoot ls-files --cached --others --exclude-standard)
$gitIgnore = Get-Content -LiteralPath (Join-Path $RepoRoot '.gitignore') -Raw -Encoding utf8
$agentsPath = Join-Path $RepoRoot 'AGENTS.md'

Assert-Text 'repository has local agent boundary rules' (Test-Path -LiteralPath $agentsPath)
$agentsText = if (Test-Path -LiteralPath $agentsPath) {
    Get-Content -LiteralPath $agentsPath -Raw -Encoding utf8
} else {
    ''
}
Assert-Text 'agent rules keep PCConfig as recovery center' ($agentsText -match 'PCConfig' -and $agentsText -match 'configuration and recovery center')
Assert-Text 'agent rules keep backup artifacts out of git' ($agentsText -match 'out/' -and $agentsText -match 'staging/' -and $agentsText -match '\*\.zip' -and $agentsText -match '\*\.reg')
Assert-Text 'agent rules classify this as public-safe tooling' ($agentsText -match 'public-safe backup tooling')

Assert-NoMatch 'git candidates do not include backup work directories' $gitFiles '^(out|staging|state|logs)(/|$)'
Assert-NoMatch 'git candidates do not include backup archives or exports' $gitFiles '\.(zip|7z|rar|reg|kdbx|pfx|pem|key|env)$'
Assert-NoMatch 'git candidates do not include WeChat databases or media backups' $gitFiles '(?i)(xwechat_files|db_storage|msg|micromsg|\.db$|\.sqlite$|\.sqlite3$)'

Assert-Text 'gitignore excludes generated backup directories' (
    $gitIgnore -match '(?m)^out/$' -and
    $gitIgnore -match '(?m)^staging/$' -and
    $gitIgnore -match '(?m)^state/$' -and
    $gitIgnore -match '(?m)^logs/$'
)
Assert-Text 'gitignore excludes backup archives and secret containers' (
    $gitIgnore -match '(?m)^\*\.zip$' -and
    $gitIgnore -match '(?m)^\*\.reg$' -and
    $gitIgnore -match '(?m)^\*\.key$'
)
