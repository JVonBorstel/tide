# Owns the PowerShell entry of the ship path's suite (core/ship, scripts/check-*.mjs): runs tests/core/ship/test-ship.mjs with node and passes on its line.
# Called by the Yard's tests Step and scripts/verify-all.ps1 (tests/Test-*.ps1), the ci.yml "Ship" step, and by hand through scripts/run-bounded.ps1.
# Uses only temp folders (throwaway git repos); no network, no state folder.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Output 'Ship tests: 0 passed, 1 failed (node not found on PATH)'; exit 1 }
$out = & $node (Join-Path $repo 'tests/core/ship/test-ship.mjs') 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Output $out.TrimEnd()
if ($out -notmatch 'Ship tests: \d+ passed, \d+ failed') { Write-Output 'Ship tests: 0 passed, 1 failed (the node suite printed no result line)'; exit 1 }
exit $code
