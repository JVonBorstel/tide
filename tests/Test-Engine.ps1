# Owns the PowerShell entry of the engine's suite (core/engine, lane L2 of the Tide upgrade): runs tests/core/engine/test-engine.mjs with
# node and passes on its counts line. Called by the Yard's tests Step and scripts/verify-all.ps1 (tests/Test-*.ps1), and by hand through
# scripts/run-bounded.ps1. Scratch folders under TEMP only (removed by each test); never the live state folder; no network. The Temporal
# part's 4 live tests start a dev server on a free 127.0.0.1 port (about 2.5 min); where the Temporal CLI or the packages
# (npm ci --ignore-scripts in core/engine/temporal, see core/engine/temporal/INSTALL.md) are missing, they skip and say why.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Output 'Engine tests: 0 passed, 1 failed, 0 skipped (node not found on PATH)'; exit 1 }
$out = & $node (Join-Path $repo 'tests/core/engine/test-engine.mjs') 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Output $out.TrimEnd()
if ($out -notmatch 'Engine tests: \d+ passed, \d+ failed, \d+ skipped') { Write-Output 'Engine tests: 0 passed, 1 failed, 0 skipped (the node suite printed no result line)'; exit 1 }
exit $code
