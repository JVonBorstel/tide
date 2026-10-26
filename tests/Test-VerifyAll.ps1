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
# every run reads its Sites registry from a temp kitchen root (TD-5), never the live one
$kroot = Join-Path $root kitchen; New-Item -ItemType Directory -Path $kroot -Force | Out-Null
function Va($cfg) { $o = pwsh -NoProfile -File $va -ConfigPath $cfg -NoKitchen -KitchenRoot $kroot 2>&1 | Out-String; $script:o = $o; $script:ec = $LASTEXITCODE }

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
$o = pwsh -NoProfile -File $va -ConfigPath (Cfg 'kgood' @(@{ name = 'fix-good'; dir = $root; glob = 'tests\Test-Good.ps1'; timeoutSeconds = 60; maxMB = 1000 })) -KitchenCheck $kstub -KitchenRoot $kroot 2>&1 | Out-String; $ec = $LASTEXITCODE
Check 'kitchen warnings never turn a green run into OVERALL FAIL' ($ec -eq 0 -and $o -match 'OVERALL: PASS' -and $o -match 'kitchen: 2 warnings' -and $o -match 'KITCHEN 2 warning')

# missing dir is a failure
Va (Cfg 'nodir' @(@{ name = 'x'; dir = (Join-Path $root 'nope'); glob = 'tests\*.ps1'; timeoutSeconds = 10; maxMB = 100 }))
Check 'missing dir fails' ($ec -eq 1)

# bad config
Set-Content (Join-Path $root 'bad.json') 'not json'
Va (Join-Path $root 'bad.json'); Check 'bad config exit 2' ($ec -eq 2)

# ---- TD-5: the Sites registry (kitchen.json "sites" in the kitchen root) groups the suites by Site ----
# no registry: exactly today's output (the golden lines below are what verify-all printed before Sites)
$golden = "PASS    fix-good       Test-Good                  Good tests: 7 passed, 0 failed`nOVERALL: PASS (1 suites, 0 not passing)"
$gcfg = Cfg 'golden' @(@{ name = 'fix-good'; dir = $root; glob = 'tests\Test-Good.ps1'; timeoutSeconds = 60; maxMB = 1000 })
Va $gcfg; $o0 = ($o.Trim() -split "`r?`n") -join "`n"
Check 'TD5 no Sites: the output is exactly as before Sites (no header line)' ($ec -eq 0 -and $o0 -ceq $golden)
Set-Content (Join-Path $kroot 'kitchen.json') '{ "maxConcurrent": 4 }'
Va $gcfg; Check 'TD5 a kitchen.json with no "sites" key: the same exact output' ($ec -eq 0 -and (($o.Trim() -split "`r?`n") -join "`n") -ceq $golden)
Set-Content (Join-Path $kroot 'kitchen.json') '{ "sites": {} }'
Va $gcfg; Check 'TD5 an empty registry: the same exact output' ($ec -eq 0 -and (($o.Trim() -split "`r?`n") -join "`n") -ceq $golden)
# a registry: TD lists this config's Tower, GW a Tower the config does not know (it runs tests\Test-*.ps1), and a config entry no Site lists
$gw = Join-Path $root 'gw'; New-Item -ItemType Directory -Force (Join-Path $gw 'tests') | Out-Null
Set-Content "$gw\tests\Test-Gw.ps1" 'Write-Host "Gw tests: 2 passed, 0 failed"; exit 0'
$lone = Join-Path $root 'lone'; New-Item -ItemType Directory -Force (Join-Path $lone 'tests') | Out-Null
Set-Content "$lone\tests\Test-Lone.ps1" 'Write-Host "Lone tests: 1 passed, 0 failed"; exit 0'
$scfg = Cfg 'sites' @(@{ name = 'lone'; dir = $lone; glob = 'tests\Test-Lone.ps1'; timeoutSeconds = 60; maxMB = 1000 }, @{ name = 'fix-good'; dir = "$root\"; glob = 'tests\Test-Good.ps1'; timeoutSeconds = 60; maxMB = 1000 })
Set-Content (Join-Path $kroot 'kitchen.json') (@{ sites = @{ TD = @{ name = 'Tide'; towers = @($root) }; GW = @{ name = 'Demo Project'; towers = @($gw) } } } | ConvertTo-Json -Depth 5)
Va $scfg; $ol = @($o.Trim() -split "`r?`n")
$want = @('^SITE GW Demo Project: 1 suites, 0 not passing$', '^PASS\s+gw\s+Test-Gw\s', '^SITE TD Tide: 1 suites, 0 not passing$', '^PASS\s+fix-good\s+Test-Good\s', '^UNASSIGNED: 1 suites, 0 not passing$', '^PASS\s+lone\s+Test-Lone\s', '^OVERALL: PASS \(3 suites, 0 not passing\)$')
$okLines = $ol.Count -eq $want.Count; for ($i = 0; $okLines -and $i -lt $want.Count; $i++) { $okLines = $ol[$i] -match $want[$i] }
Check 'TD5 registry: suites run Site by Site (codes in order), a Tower the config lacks runs tests\Test-*.ps1, an unlisted entry is UNASSIGNED, never dropped' ($ec -eq 0 -and $okLines)
if (-not $okLines) { Write-Host $o }
# a Site with no name shows its code; a failing suite is counted on its Site's header
Set-Content "$gw\tests\Test-Gw.ps1" 'Write-Host "Gw tests: 1 passed, 1 failed"; exit 1'
Set-Content (Join-Path $kroot 'kitchen.json') (@{ sites = @{ GW = @{ towers = @($gw) } } } | ConvertTo-Json -Depth 5)
Va $scfg
Check 'TD5 registry: GW (no name) shows its code, its failing suite counted on its header, the rest UNASSIGNED' ($ec -eq 1 -and $o -match '(?m)^SITE GW: 1 suites, 1 not passing\r?$' -and $o -match '(?m)^UNASSIGNED: 2 suites, 0 not passing\r?$' -and $o -match 'OVERALL: FAIL \(3 suites, 1 not passing\)')
# a damaged registry is a bad config (exit 2), never a guess
Set-Content (Join-Path $kroot 'kitchen.json') '{ "sites": { "tide": { "towers": [] } } }'
Va $scfg; Check 'TD5 a malformed registry: exit 2, named' ($ec -eq 2 -and $o -match 'bad Sites registry')
# one shape (reconciled with TD-7/TD-9/TD-11): a list of Sites is refused, never half-read
Set-Content (Join-Path $kroot 'kitchen.json') '{ "sites": [ { "code": "TD", "towers": [] } ] }'
Va $scfg; Check 'one registry shape: "sites" as a list is a bad registry (exit 2), named' ($ec -eq 2 -and $o -match "bad Sites registry.*'sites' must be an object")
Set-Content (Join-Path $kroot 'kitchen.json') '{ broken'
Va $scfg; Check 'TD5 a registry file that is not JSON: exit 2' ($ec -eq 2 -and $o -match 'bad Sites registry')
Remove-Item (Join-Path $kroot 'kitchen.json')

# leaves no processes behind from the hung suite
Start-Sleep -Milliseconds 800
Check 'no leftover hung pwsh' (@(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like "*$root*" }).Count -eq 0)

# no -ConfigPath: a state-folder verify-all.json (this PC's repo list) wins over the repo copy, and says so
$savedK = $env:BRAIN_KITCHEN; $sk = Join-Path $root 'state'; New-Item -ItemType Directory $sk | Out-Null; $env:BRAIN_KITCHEN = $sk
try {
    Copy-Item (Cfg 'state' @(@{ name = 'state-suites'; dir = $root; glob = 'tests\Test-Good.ps1'; timeoutSeconds = 60; maxMB = 1000 })) (Join-Path $sk 'verify-all.json')
    $o = pwsh -NoProfile -File $va -NoKitchen 2>&1 | Out-String
    Check 'state-folder verify-all.json wins over the repo copy, and is named' ($LASTEXITCODE -eq 0 -and $o -match 'PASS\s+state-suites' -and $o -match [regex]::Escape("suites: $(Join-Path $sk 'verify-all.json')"))
} finally { $env:BRAIN_KITCHEN = $savedK }

Remove-Item -Recurse -Force $root
Write-Host "VerifyAll tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
