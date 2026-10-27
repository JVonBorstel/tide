# Owns the PowerShell entry of the Work tab's suite (pass-app/work, lane L5 of the Tide upgrade): runs pass-app/test-work.mjs with node
# and passes on its counts line. Called by CI's Core step (core/ship/gates.json coreSuites), the Yard's tests Step and
# scripts/verify-all.ps1 (tests/Test-*.ps1), and by hand through scripts/run-bounded.ps1. The suite starts its own Board server on a
# throwaway state folder under TEMP (removed at the end); never the live state folder; no network beyond 127.0.0.1.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Output 'Work tests: 0 passed, 1 failed (node not found on PATH)'; exit 1 }
$out = & $node (Join-Path $repo 'pass-app/test-work.mjs') 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Output $out.TrimEnd()
if ($out -notmatch 'Work tests: \d+ passed, \d+ failed') { Write-Output 'Work tests: 0 passed, 1 failed (the node suite printed no result line)'; exit 1 }
exit $code
