# Owns the PowerShell entry of the shared contracts' suite (core/contracts): runs tests/core/contracts/test-contracts.mjs with node and passes on its line.
# Called by the Yard's tests Step and scripts/verify-all.ps1 (tests/Test-*.ps1), and by hand through scripts/run-bounded.ps1. No network, no state folder.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Output 'Contracts tests: 0 passed, 1 failed (node not found on PATH)'; exit 1 }
$out = & $node (Join-Path $repo 'tests/core/contracts/test-contracts.mjs') 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Output $out.TrimEnd()
if ($out -notmatch 'Contracts tests: \d+ passed, \d+ failed') { Write-Output 'Contracts tests: 0 passed, 1 failed (the node suite printed no result line)'; exit 1 }
exit $code
