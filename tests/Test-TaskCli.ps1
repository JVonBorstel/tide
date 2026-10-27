# Owns the PowerShell entry of the task orchestrator's suite (tools/task.mjs and .claude/workflows/task-orchestrate.js): runs
# tests/tools/test-task.mjs with node and passes on its counts line. Called by the Yard's tests Step, scripts/verify-all.ps1
# (tests/Test-*.ps1), the CI Core step (core/ship/gates.json coreSuites) and by hand through scripts/run-bounded.ps1.
# Scratch folders under TEMP only (removed by the suite); never the live task store or state folder; no network, no git, no model.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Output 'Task tests: 0 passed, 1 failed, 0 skipped (node not found on PATH)'; exit 1 }
$out = & $node (Join-Path $repo 'tests/tools/test-task.mjs') 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Output $out.TrimEnd()
if ($out -notmatch 'Task tests: \d+ passed, \d+ failed, \d+ skipped') { Write-Output 'Task tests: 0 passed, 1 failed, 0 skipped (the node suite printed no result line)'; exit 1 }
exit $code
