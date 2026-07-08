# Windows Terminal LocalState Backup Verification

## Paths

- Source config: `E:\DevConfigBackup\sources.psd1`
- Windows Terminal LocalState: `C:\Users\10979\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState`
- Staging LocalState: `E:\DevConfigBackup\staging\appdata-local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState`
- Local backup package: `E:\DevConfigBackup\out\devconfig-20260708-094459.zip`
- Report: `E:\DevConfigBackup\reports\windows_terminal_localstate_20260709_004611.md`

## Validation Commands And Results

- Command: `Test-Path -LiteralPath 'C:\Users\10979\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'`
  Result: `True`

- Command: `$cfg = Import-PowerShellDataFile -LiteralPath 'E:\DevConfigBackup\sources.psd1'; $cfg.AppDataLocalDirs -contains 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'`
  Result: `True`

- Command: `$cfg = Import-PowerShellDataFile -LiteralPath 'E:\DevConfigBackup\sources.psd1'; check AppDataLocalDirs for broad Packages/browser/cache entries`
  Result: `PASS: no broad Packages/browser/cache AppData Local source added`

- Command: `[System.IO.File]::ReadAllBytes('E:\DevConfigBackup\sources.psd1') UTF-8 BOM check`
  Result: `PASS: sources.psd1 has UTF-8 BOM`

- Command: `pwsh -NoProfile -ExecutionPolicy Bypass -File 'E:\DevConfigBackup\tests\Assert-HDriveSafety.ps1'`
  Result: `PASS: existing safety test completed successfully`

- Command: `pwsh -NoProfile -ExecutionPolicy Bypass -File 'E:\DevConfigBackup\Backup-DevConfig.ps1' -Tier Local -KeepLocal 999`
  Result: `PASS: Local backup completed; no Usb or Drive tier requested`

- Command: `Test-Path -LiteralPath 'E:\DevConfigBackup\staging\appdata-local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'; count files recursively`
  Result: `PASS: staging Windows Terminal LocalState present; file_count=3`

- Command: `Get-ChildItem -LiteralPath 'E:\DevConfigBackup\staging\appdata-local\Packages' -Directory`
  Result: `PASS: staging Packages contains only Windows Terminal package root from this source`
