# Owns the PowerShell entry of the Work tab's suites (pass-app/work, lane L5 of the Tide upgrade): runs every pass-app/test-work*.mjs with
# node (the API, push, previews ...) and prints one total line. Called by CI's Core step (core/ship/gates.json coreSuites), the Yard's tests
# Step and scripts/verify-all.ps1 (tests/Test-*.ps1), and by hand through scripts/run-bounded.ps1. Each suite works in a throwaway folder
# under TEMP (removed at the end); never the live state folder; no network beyond 127.0.0.1.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Output 'Work tests: 0 passed, 1 failed (node not found on PATH)'; exit 1 }
$suites = @(Get-ChildItem -LiteralPath (Join-Path $repo 'pass-app') -File -Filter 'test-work*.mjs' | Sort-Object Name)
if (-not $suites) { Write-Output 'Work tests: 0 passed, 1 failed (no pass-app/test-work*.mjs found)'; exit 1 }
$pass = 0; $fail = 0; $code = 0
foreach ($s in $suites) {
  $out = & $node $s.FullName 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { $code = 1 }
  Write-Output $out.TrimEnd()
  $m = [regex]::Match($out, 'Work tests: (\d+) passed, (\d+) failed')
  if (-not $m.Success) { Write-Output "FAIL: $($s.Name) printed no result line"; $fail++; $code = 1; continue }
  $pass += [int]$m.Groups[1].Value; $fail += [int]$m.Groups[2].Value
}
Write-Output "Work tests: $pass passed, $fail failed ($($suites.Count) files)"
if ($fail -gt 0) { $code = 1 }
exit $code
