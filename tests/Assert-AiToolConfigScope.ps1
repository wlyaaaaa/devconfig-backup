[CmdletBinding()]
param()
# AI 工具配置范围：Codex 配置与记忆、Antigravity 设置、OpenCode 配置在包内；
# 对话、brain、缓存和已冻结的 OpenClaw 不在包内。用真实 sources.psd1 对合成目录取清单。
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'Backup.Common.ps1')
. (Join-Path $repo 'DevConfig.Sources.ps1')
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw ('FAIL: '+$Name)};Write-Host ('PASS: '+$Name)}
$cfg=Import-PowerShellDataFile -LiteralPath (Join-Path $repo 'sources.psd1')
Check ('home/.codex' -in @($cfg.RequiredSources)) 'Codex home is required'
Check ('home/.codex/memories/extensions' -in @($cfg.RequiredSources)) 'Codex extension memories are required'
Check ('home/.gemini/antigravity/antigravity_state.pbtxt' -in @($cfg.RequiredSources)) 'Antigravity desktop settings are required'
Check ('.openclaw'-notin @($cfg.HomeDirs)) 'Frozen OpenClaw home is not in the daily selection'
Check (@(@($cfg.ScheduledTaskPatterns)|Where-Object{'OpenClaw Gateway'-like $_}).Count-eq 0) 'Frozen OpenClaw scheduled tasks are not exported'
Check ('antigravity'-in @($cfg.ExcludeDirs)) 'Antigravity runtime tree stays excluded as a whole'
$cfg.ExtraDirs=@() # 合成目录之外的绝对路径不参与本测试
$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fixture=Join-Path $parent ('devconfig-aiscope-'+[guid]::NewGuid().ToString('N'))
try{
 $profile=Join-Path $fixture 'profile'
 foreach($relative in @(
  '.codex/config.toml','.codex/memories/MEMORY.md','.codex/memories/extensions/ad_hoc/instructions.md','.codex/memories/extensions/ad_hoc/notes/n.md',
  '.claude/settings.json',
  '.codex/memories/.git/HEAD','.codex/skills/s/SKILL.md','.codex/sessions/2026/r.jsonl',
  '.gemini/settings.json','.gemini/config/config.json','.gemini/config/projects/p.json','.gemini/config/plugins/x/plugin.json',
  '.gemini/antigravity/antigravity_state.pbtxt','.gemini/antigravity/annotations/c.pbtxt','.gemini/antigravity/brain/b/task.md',
  '.gemini/antigravity/conversations/c.pb','.gemini/antigravity/mcp/server/tool.json','.gemini/antigravity-cli/settings.json',
  '.gemini/antigravity-cli/mcp.json','.gemini/antigravity-cli/oauth_creds.json',
  '.gemini/antigravity-cli/conversations/c.pb','.gemini/antigravity-cli/implicit/i.pbtxt',
  '.gemini/antigravity-cli/annotations/a.pbtxt','.gemini/antigravity-cli/brain/b.md',
  '.gemini/antigravity-cli/knowledge/k.md','.gemini/antigravity-cli/conversation_summaries.db',
  '.gemini/antigravity-cli/history.jsonl','.gemini/antigravity-cli/jetbox_summaries_proto.pb',
  '.config/opencode/opencode.jsonc','.config/opencode/plugins/huihui-backend.js','.config/opencode/node_modules/m/index.js',
  'AppData/Roaming/ai.opencode.desktop/default.dat','AppData/Roaming/ai.opencode.desktop/drafts.sqlite',
  '.openclaw/openclaw.json')){
  $path=Join-Path $profile $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllText($path,'x')
 }
 $paths=@((Get-DevConfigSourceInventory $cfg $profile).files|ForEach-Object{$_.relative_path})
 foreach($expected in @(
  'home/.codex/config.toml','home/.codex/memories/MEMORY.md','home/.codex/memories/extensions/ad_hoc/instructions.md',
  'home/.codex/memories/extensions/ad_hoc/notes/n.md','home/.codex/skills/s/SKILL.md',
  'home/.gemini/config/projects/p.json','home/.gemini/config/plugins/x/plugin.json','home/.gemini/antigravity/antigravity_state.pbtxt',
  'home/.gemini/antigravity-cli/settings.json','home/.gemini/antigravity-cli/mcp.json',
  'home/.gemini/antigravity-cli/oauth_creds.json','home/.config/opencode/opencode.jsonc','home/.config/opencode/plugins/huihui-backend.js',
  'appdata-roaming/ai.opencode.desktop/default.dat')){Check ($expected-in $paths) ('Selected: '+$expected)}
 foreach($pattern in @('home/.codex/memories/.git/*','home/.codex/sessions/*','home/.gemini/antigravity/annotations/*','home/.gemini/antigravity/brain/*',
  'home/.gemini/antigravity/conversations/*','home/.gemini/antigravity/mcp/*',
  'home/.gemini/antigravity-cli/conversations/*','home/.gemini/antigravity-cli/implicit/*',
  'home/.gemini/antigravity-cli/annotations/*','home/.gemini/antigravity-cli/brain/*',
  'home/.gemini/antigravity-cli/knowledge/*','home/.gemini/antigravity-cli/conversation_summaries.db',
  'home/.gemini/antigravity-cli/history.jsonl','home/.gemini/antigravity-cli/jetbox_summaries_proto.pb',
  'home/.config/opencode/node_modules/*',
  'appdata-roaming/ai.opencode.desktop/drafts.sqlite','home/.openclaw/*')){
  Check (@($paths|Where-Object{$_-like $pattern}).Count-eq 0) ('Not selected: '+$pattern)
 }
 $withHistory=@((Get-DevConfigSourceInventory $cfg $profile -IncludeHistory).files|ForEach-Object{$_.relative_path})
 Check (@($withHistory|Where-Object{$_-like 'home/.gemini/antigravity-cli/conversations/*' -or $_-like 'home/.gemini/antigravity-cli/annotations/*'}).Count-eq 0) 'CLI conversations and annotations stay excluded even with IncludeHistory'
 $missingProfile=Join-Path $fixture 'missing-profile';[void][IO.Directory]::CreateDirectory($missingProfile)
 $missingConfig=@{HomeDirs=@('.codex');RequiredSources=@('home/.codex')}
 $missing=$false
 try{$null=Get-DevConfigSourceInventory $missingConfig $missingProfile}catch{$missing=$_.Exception.Message -eq 'required_backup_source_missing: home/.codex'}
 Check $missing 'Missing required directory reports its exact source and fails'
 $optionalConfig=@{HomeDirs=@('.uninstalled-app')}
 $optional=Get-DevConfigSourceInventory $optionalConfig $missingProfile
 Check ($optional.optional_absent_count -eq 1 -and $optional.sources[0].status -eq 'optional_absent') 'Uninstalled optional software remains distinct from missing required source'
}finally{if([IO.Directory]::Exists($fixture)){Remove-BackupOwnedDirectory $fixture $parent '^devconfig-aiscope-[a-f0-9]{32}$'}}
