# Tests for scripts/verify-all.ps1 (one-screen verification across repos). Fixture suites in a temp folder; self-cleaning.
$ErrorActionPreference = 'Stop'
$va = Join-Path $PSScriptRoot '..\scripts\verify-all.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('va-' + [guid]::NewGuid().ToString('N'))
$t = Join-Path $root 'tests'; New-Item -ItemType Directory -Path $t -Force | Out-Null
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
Set-Content "$t\Test-Good.ps1" 'Write-Host "Good tests: 7 passed, 0 failed"; exit 0'
Set-Content "$t\Test-Bad.ps1" 'Write-Host "Bad tests: 3 passed, 2 failed"; exit 1'
Set-Content "$t\Test-Hang.ps1" 'Start-Sleep 120'
Set-Content "$t\Test-Env.ps1" 'if ($env:PATH -like "*va-marker-dir*") { Write-Host "Env tests: 1 passed, 0 failed"; exit 0 } else { Write-Host "Env tests: 0 passed, 1 failed"; exit 1 }'
function Cfg($name, $entries) { $p = Join-Path $root "$name.json"; (@{ suites = $entries } | ConvertTo-Json -Depth 5) | Set-Content $p; $p }
function Va($cfg) { $o = pwsh -NoProfile -File $va -ConfigPath $cfg -NoKitchen 2>&1 | Out-String; $script:o = $o; $script:ec = $LASTEXITCODE }

# all good -> exit 0, counts shown
Va (Cfg 'good' @(@{ name = 'fix-good'; dir = $root; glob = 'tests\Test-Good.ps1'; timeoutSeconds = 60; maxMB = 1000 }))
Check 'all pass exit 0' ($ec -eq 0); Check 'pass line' ($o -match 'PASS\s+fix-good.*Test-Good'); Check 'counts shown' ($o -match '7 passed'); Check 'overall pass' ($o -match 'OVERALL: PASS')

# one failing suite -> exit 1, others still run
Va (Cfg 'mixed' @(@{ name = 'm'; dir = $root; glob = 'tests\Test-*.ps1'; timeoutSeconds = 8; maxMB = 1000; skip = @('Test-Env.ps1') }))
Check 'mixed exit 1' ($ec -eq 1)
Check 'fail reported' ($o -match 'FAIL\s+m.*Test-Bad' -and $o -match '2 failed')
Check 'timeout reported' ($o -match 'TIMEOUT\s+m.*Test-Hang')
Check 'good still ran' ($o -match 'PASS\s+m.*Test-Good')
Check 'overall fail + counts' ($o -match 'OVERALL: FAIL \(3 suites, 2 not passing\)')   # the old check ended in '-or OVERALL: FAIL', so the counts were never checked

# prependPath reaches the suite
$mk = Join-Path $root 'va-marker-dir'; New-Item -ItemType Directory $mk | Out-Null
Va (Cfg 'env' @(@{ name = 'e'; dir = $root; glob = 'tests\Test-Env.ps1'; timeoutSeconds = 60; maxMB = 1000; prependPath = $mk }))
Check 'prependPath applied' ($ec -eq 0 -and $o -match 'PASS\s+e')

# a glob that matches nothing is a FAILURE (never silently green)
Va (Cfg 'empty' @(@{ name = 'none'; dir = $root; glob = 'tests\Test-Nothing-*.ps1'; timeoutSeconds = 10; maxMB = 100 }))
Check 'empty glob fails' ($ec -eq 1 -and $o -match 'no suites matched')
# a suite dropped, renamed or skipped (fewer files than minSuites) is a FAILURE too, while the ones left still run
Va (Cfg 'few' @(@{ name = 'few'; dir = $root; glob = 'tests\Test-Good.ps1'; minSuites = 2; timeoutSeconds = 60; maxMB = 1000 }))
Check 'fewer suites than minSuites fails' ($ec -eq 1 -and $o -match 'expected at least 2' -and $o -match 'PASS\s+few.*Test-Good')
# the real config never skips a brain-monitor suite and sets a floor for it
$real = Get-Content (Join-Path $PSScriptRoot '..\scripts\verify-all.json') -Raw | ConvertFrom-Json
Check 'verify-all.json: brain-monitor skips nothing and has minSuites' (@($real.suites | Where-Object { $_.name -eq 'brain-monitor' -and -not $_.skip -and [int]$_.minSuites -ge 30 }).Count -eq 1)

# kitchen-check WARNs (a loaded local model, a big TEMP) are resource state, not a failed suite: OVERALL stays PASS, the warnings are counted beside it
$kstub = Join-Path $root 'kc-stub.ps1'; Set-Content $kstub "Write-Output 'KITCHEN now'; Write-Output 'WARN heavy: llama-server pid 1 6000 MB'; Write-Output 'WARN TEMP large'; Write-Output '2 warning(s).'; exit 1"
$o = pwsh -NoProfile -File $va -ConfigPath (Cfg 'kgood' @(@{ name = 'fix-good'; dir = $root; glob = 'tests\Test-Good.ps1'; timeoutSeconds = 60; maxMB = 1000 })) -KitchenCheck $kstub 2>&1 | Out-String; $ec = $LASTEXITCODE
Check 'kitchen warnings never turn a green run into OVERALL FAIL' ($ec -eq 0 -and $o -match 'OVERALL: PASS' -and $o -match 'kitchen: 2 warnings' -and $o -match 'KITCHEN 2 warning')

# missing dir is a failure
Va (Cfg 'nodir' @(@{ name = 'x'; dir = (Join-Path $root 'nope'); glob = 'tests\*.ps1'; timeoutSeconds = 10; maxMB = 100 }))
Check 'missing dir fails' ($ec -eq 1)

# bad config
Set-Content (Join-Path $root 'bad.json') 'not json'
Va (Join-Path $root 'bad.json'); Check 'bad config exit 2' ($ec -eq 2)

# leaves no processes behind from the hung suite
Start-Sleep -Milliseconds 800
Check 'no leftover hung pwsh' (@(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like "*$root*" }).Count -eq 0)

Remove-Item -Recurse -Force $root
Write-Host "VerifyAll tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
