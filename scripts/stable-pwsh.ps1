# The pwsh.exe a scheduled task should be saved with: one that survives PowerShell updates. The Microsoft Store install lives in a
# versioned folder (C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__...) that the next update DELETES, so a task saved with
# that path fails 'file not found' (0x80070002) every run from then on (the kitchen stopped for 2+ days on 2026-10-16). The app-execution
# alias in %LOCALAPPDATA%\Microsoft\WindowsApps always points at the installed version. Resolved when called, never hard-coded.
# Prints the path; exit 1 (fail closed) when only a version-pinned pwsh is found. -Candidates is for tests.
param([string[]]$Candidates)
if (-not $Candidates) {
    $Candidates = @((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')) +
        @(Get-Command pwsh -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object Source) +
        @((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))   # an MSI/winget install is not versioned either
}
foreach ($c in $Candidates) {
    if (-not $c -or $c -match '\\WindowsApps\\Microsoft\.PowerShell_\d') { continue }   # a versioned Store package folder: dies at the next update
    if (Test-Path -LiteralPath $c) { Write-Output $c; exit 0 }
}
Write-Error 'no update-proof pwsh.exe found (only a version-pinned Store path); install PowerShell 7 from the Store or winget first' -ErrorAction Continue
exit 1
