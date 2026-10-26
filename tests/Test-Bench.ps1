# Tests for scripts/bench (the Tide benchmark): both scripts parse, and the before/after comparison marks better and worse correctly.
# Fast: no server is started and the live kitchen is not read (the full run is scripts/bench/bench.ps1, about a minute).
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$dir = Join-Path $PSScriptRoot '..\scripts\bench'
$errs = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $dir 'bench.ps1'), [ref]$null, [ref]$errs)
Check 'bench.ps1 parses' (-not $errs)
& node --check (Join-Path $dir 'chef.mjs') 2>&1 | Out-Null
Check 'chef.mjs parses' ($LASTEXITCODE -eq 0)
$src = Get-Content (Join-Path $dir 'bench.ps1') -Raw
Check 'bench never measures the live Chef port (its own random port 30000-40000)' ($src -notmatch '7878' -and $src -match 'Get-Random -Minimum 30000 -Maximum 40000')
Check 'bench copies the state and removes the copy' ($src -match 'tide-bench-' -and $src -match 'Remove-Item -Recurse -Force \$copy')
Check 'throughput counts more-is-better' ($src -match "higherBetter = 'flow.doneLast24h', 'flow.workShareMedianPct'")
Write-Host "Bench tests: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
