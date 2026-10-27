# Owns the PowerShell entry of adopt's suite (core/engine/adopt.mjs, lane L2 of the Tide upgrade): runs tests/core/engine/test-adopt.mjs
# with node and passes on its counts line. Called by the Yard's tests Step and scripts/verify-all.ps1 (tests/Test-*.ps1), and by hand
# through scripts/run-bounded.ps1. Scratch folders under TEMP only (removed by the suite); never the live state folder; no network.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Output 'Adopt tests: 0 passed, 1 failed (node not found on PATH)'; exit 1 }
$out = & $node (Join-Path $repo 'tests/core/engine/test-adopt.mjs') 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Output $out.TrimEnd()
if ($out -notmatch 'Adopt tests: \d+ passed, \d+ failed') { Write-Output 'Adopt tests: 0 passed, 1 failed (the node suite printed no result line)'; exit 1 }
exit $code
