# Owns the PowerShell entry of the ledger's suite (core/ledger, WO-UPG-L1): runs tests/core/ledger/test-ledger.mjs with node and passes on its line.
# Called by the Yard's tests Step and scripts/verify-all.ps1 (tests/Test-*.ps1), and by hand through scripts/run-bounded.ps1. No network,
# no state folder: the suite makes its synthetic data in a temp folder. node:sqlite needs Node 22 or later (the suite adds
# --experimental-sqlite itself on Node 22).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Output 'Ledger tests: 0 passed, 1 failed (node not found on PATH)'; exit 1 }
$out = & $node (Join-Path $repo 'tests/core/ledger/test-ledger.mjs') 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Output $out.TrimEnd()
if ($out -notmatch 'Ledger tests: \d+ passed, \d+ failed') { Write-Output 'Ledger tests: 0 passed, 1 failed (the node suite printed no result line)'; exit 1 }
exit $code
