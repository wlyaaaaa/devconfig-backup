[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutRoot,
    [string]$ProfileRoot = $env:USERPROFILE,
    [datetimeoffset]$ExpectedAfterUtc = [datetimeoffset]'2026-09-29T04:05:00Z'
)

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $OutRoot 'latest.zip.manifest.json'
$receiptPath = Join-Path $OutRoot 'latest.zip.receipt.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -DateKind String
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -DateKind String
if ($receipt.status -cne 'complete' -or $receipt.archive_verification -cne '7z_test_pass' -or
    [datetimeoffset]::Parse($receipt.completed_utc) -lt $ExpectedAfterUtc) {
    throw 'first_ai_backup_not_yet_verified'
}
if ($manifest.file_count -ne $receipt.file_count -or
    $manifest.file_count -ne @($manifest.files).Count) {
    throw 'first_ai_backup_manifest_receipt_mismatch'
}
if ([IO.Path]::GetFileName($receipt.package_name) -cne $receipt.package_name -or
    (Get-FileHash -LiteralPath (Join-Path $OutRoot $receipt.package_name) -Algorithm SHA256).Hash -ine $receipt.sha256) {
    throw 'first_ai_backup_package_hash_mismatch'
}

$paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $manifest.files) { [void]$paths.Add([string]$file.relative_path) }
$requiredSources = @(
    'home/.codex', 'home/.codex/memories/extensions', 'home/.claude',
    'home/.gemini', 'home/.gemini/antigravity/antigravity_state.pbtxt',
    'home/.config/opencode'
)
foreach ($id in $requiredSources) {
    $source = @($manifest.sources | Where-Object { $_.id -ieq $id })
    if ($source.Count -ne 1 -or $source[0].status -cne 'available' -or
        -not $source[0].required) { throw "required_source_missing_from_manifest: $id" }
}

$expected = @(
    'home/.codex/config.toml', 'home/.codex/AGENTS.md',
    'home/.codex/version.json', 'home/.codex/chrome-native-hosts-v2.json',
    'home/.codex/browser/config.toml', 'home/.codex/computer-use/config.json',
    'home/.codex/vendor_imports/skills-curated-cache.json',
    'home/.gemini/antigravity/antigravity_state.pbtxt',
    'home/.gemini/antigravity-cli/settings.json'
)
$missing = @($expected | Where-Object { -not $paths.Contains($_) })
$memoryRoot = Join-Path $ProfileRoot '.codex\memories\extensions'
$memoryFiles = @(Get-ChildItem -LiteralPath $memoryRoot -Recurse -File -Force -ErrorAction Stop |
    ForEach-Object { 'home/.codex/memories/extensions/' +
        [IO.Path]::GetRelativePath($memoryRoot, $_.FullName).Replace('\', '/') })
$missingMemory = @($memoryFiles | Where-Object { -not $paths.Contains($_) })
$requiredTrees = @(
    'home/.codex/skills/', 'home/.gemini/config/projects/',
    'home/.gemini/config/plugins/'
)
$emptyTrees = @($requiredTrees | Where-Object {
    $prefix = $_
    @($paths | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
})
$forbidden = @($paths | Where-Object {
    $_ -like 'home/.openclaw/*' -or
    $_ -like 'home/.gemini/antigravity-cli/conversations/*' -or
    $_ -like 'home/.gemini/antigravity-cli/implicit/*' -or
    $_ -like 'home/.gemini/antigravity-cli/annotations/*' -or
    $_ -like 'home/.gemini/antigravity-cli/brain/*' -or
    $_ -like 'home/.gemini/antigravity-cli/knowledge/*'
})
if ($missing.Count -or $missingMemory.Count -or $emptyTrees.Count -or $forbidden.Count) {
    throw ("first_ai_backup_scope_mismatch: missing_core={0}, missing_memories={1}, empty_trees={2}, forbidden={3}" -f
        $missing.Count, $missingMemory.Count, $emptyTrees.Count, $forbidden.Count)
}
[pscustomobject]@{
    result = 'pass'
    package_name = $receipt.package_name
    completed_utc = $receipt.completed_utc
    manifest_files = $manifest.file_count
    codex_extension_memory_files = $memoryFiles.Count
    skipped_files = $manifest.skipped_file_count
} | ConvertTo-Json
