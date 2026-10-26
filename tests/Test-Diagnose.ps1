# Tests for fix-what-breaks (kitchen/diagnose.ps1): newly set-aside orders get one read-only diagnosis, only while the AI cooks are
# live, 3 a day at most, never for old failures, never a diagnosis of a diagnosis; a job with private steps gets a private diagnosis.
# Nothing is cooked here (no tick after a diagnosis is placed; every cook is switched off). Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$k = Join-Path $kd 'kitchen.ps1'; $w = Join-Path $kd 'demo-worker.ps1'; $dgs = Join-Path $kd 'diagnose.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-diag-' + [guid]::NewGuid().ToString('N'))
$save = @{}; foreach ($n in 'BRAIN_KITCHEN', 'KITCHEN_LIVE', 'KITCHEN_NO_DIAGNOSE', 'KITCHEN_CLAUDE_EXE', 'KITCHEN_AGY_EXE', 'KITCHEN_OLLAMA_URL') { $save[$n] = [Environment]::GetEnvironmentVariable($n) }
$env:BRAIN_KITCHEN = $root; $env:KITCHEN_LIVE = $null; $env:KITCHEN_NO_DIAGNOSE = '1'; $env:KITCHEN_CLAUDE_EXE = Join-Path $root 'no-such-claude.exe'; $env:KITCHEN_AGY_EXE = 'off'; $env:KITCHEN_OLLAMA_URL = 'off'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Auto { (& $dgs -Auto -Json | Out-String) | ConvertFrom-Json }
function Jobs { @(Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }) }
function Fail-Job([string]$name) { & $k add -Name $name -Script $w -ScriptArgs @{ Behavior = 'fail'; Seconds = 1 } -Retries 0 | Out-Null }
function Settle { for ($i = 0; $i -lt 10; $i++) { & $k tick -Quiet | Out-Null; if (-not @(Jobs | Where-Object { $_.status -in 'pending', 'running' }).Count) { break }; Start-Sleep -Milliseconds 600 } }
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Fail-Job 'broken one'; Settle
    $j1 = @(Jobs | Where-Object name -eq 'broken one')[0]
    Check 'the failing order is set aside' ($j1.status -eq 'quarantined')
    Check 'AI cooks off -> no diagnosis' (@((Auto).started).Count -eq 0 -and @(Jobs).Count -eq 1)

    Set-Content (Join-Path $root 'LIVE') 'test'
    $r = Auto
    Check 'live -> one diagnosis placed' (@($r.started).Count -eq 1 -and $r.started[0].ok -and $r.started[0].job -eq $j1.id)
    $d1 = @(Jobs | Where-Object { $_.name -like 'diagnose:*' })
    Check 'it is named for the ticket and read-only' ($d1.Count -eq 1 -and $d1[0].name -eq "diagnose: $($j1.id)" -and $d1[0].steps[0].args.Tools -eq 'Read,Grep,Glob' -and -not $d1[0].steps[0].args.Mode)
    Check 'the failure travels with it' ($d1[0].steps[0].args.Prompt -match 'broken one' -and $d1[0].steps[0].args.Order -match 'broken one')
    Check 'never twice for the same order' (@((Auto).started).Count -eq 0)

    # a diagnosis that itself fails is not diagnosed again
    $dj = Get-Content (Join-Path $root "jobs\$($d1[0].id).json") -Raw | ConvertFrom-Json -AsHashtable; $dj.status = 'quarantined'
    $dj | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $root "jobs\$($d1[0].id).json")
    Check 'no diagnosis of a diagnosis' (@((Auto).started).Count -eq 0)

    # a job with private steps gets a private diagnosis
    Fail-Job 'private broken'; Settle
    $pj = @(Jobs | Where-Object name -eq 'private broken')[0]
    $h = Get-Content (Join-Path $root "jobs\$($pj.id).json") -Raw | ConvertFrom-Json -AsHashtable; $h.steps[0].args.Private = $true
    $h | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $root "jobs\$($pj.id).json")
    $r = Auto
    $pd = @(Jobs | Where-Object { $_.name -eq "diagnose: $($pj.id)" })[0]
    Check 'private order -> private diagnosis' (@($r.started).Count -eq 1 -and $pd.steps[0].args.Private -eq $true)

    # at most 3 a day
    Fail-Job 'third'; Fail-Job 'fourth'; Settle
    $r = Auto
    Check 'three a day at most' (@($r.started).Count -eq 1 -and @(Jobs | Where-Object { $_.name -like 'diagnose:*' }).Count -eq 3)

    # old failures are never a surprise
    Remove-Item (Join-Path $root 'diagnosed.json')
    Fail-Job 'old one'; Settle
    $oj = @(Jobs | Where-Object name -eq 'old one')[0]
    $h = Get-Content (Join-Path $root "jobs\$($oj.id).json") -Raw | ConvertFrom-Json -AsHashtable; foreach ($x in $h.history) { $x.at = (Get-Date).ToUniversalTime().AddDays(-3).ToString('o') }
    $h | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $root "jobs\$($oj.id).json")
    $null = Auto
    Check 'a failure older than a day gets no diagnosis' (-not @(Jobs | Where-Object { $_.name -eq "diagnose: $($oj.id)" }).Count)

    # by hand (the app's Find the fix)
    $r = (& $dgs -Id $oj.id -Json | Out-String) | ConvertFrom-Json
    Check 'Find the fix works for any set-aside order' ($r.ok -and $r.diagnosis -match '^J\d+$')
    Check 'bad id refused' (-not ((& $dgs -Id 'J1; x' -Json | Out-String) | ConvertFrom-Json).ok)

    # a failure whose log quotes a template token ({{job}}) can still be diagnosed (recipes refuse "{{" in a var)
    Fail-Job 'brace one'; Settle
    $bj = @(Jobs | Where-Object name -eq 'brace one')[0]
    $h = Get-Content (Join-Path $root "jobs\$($bj.id).json") -Raw | ConvertFrom-Json -AsHashtable; $h.history[-1].detail = 'draft not found: C:\career\packs\{{job}}-draft.md'
    $h | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $root "jobs\$($bj.id).json")
    $r = (& $dgs -Id $bj.id -Json | Out-String) | ConvertFrom-Json
    Check 'a log with {{ }} in it: the diagnosis is placed' ($r.ok -and $r.diagnosis -match '^J\d+$')
    Check 'the braces are split apart, the text kept' (@(Jobs | Where-Object { $_.id -eq $r.diagnosis })[0].steps[0].args.Order -match '\{ \{job\} \}-draft\.md')

    # -Auto: an order whose diagnosis cannot be placed is marked once (not retried every tick) and does not use up the 3 a day
    Remove-Item (Join-Path $root 'diagnosed.json')
    foreach ($jf in Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json') { $x = Get-Content $jf.FullName -Raw | ConvertFrom-Json -AsHashtable; if ($x.name -like 'diagnose:*' -or $x.status -eq 'quarantined') { $x.status = 'closed'; $x | ConvertTo-Json -Depth 12 | Set-Content $jf.FullName } }
    foreach ($nn in 900, 901) { $x = Get-Content (Join-Path $root "jobs\$($bj.id).json") -Raw | ConvertFrom-Json -AsHashtable; $x.id = "J$nn"; $x.name = "set aside $nn"; $x.status = 'quarantined'; $x.history[-1].at = (Get-Date).ToUniversalTime().ToString('o'); $x | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $root "jobs\J$nn.json") }   # written directly: the breaker may hold new work by now
    $env:KITCHEN_RECIPES = Join-Path $root 'no-recipes-here'   # every cook.ps1 call fails for the first pass
    try { $r = Auto } finally { $env:KITCHEN_RECIPES = $null }
    Check 'auto: a diagnosis that could not be placed is not counted as started' (@($r.started | Where-Object ok).Count -eq 0 -and @($r.started).Count -eq 2)
    $marks = Get-Content (Join-Path $root 'diagnosed.json') -Raw | ConvertFrom-Json -AsHashtable
    Check 'auto: the failed attempt is marked, with its error, so the next tick does not retry it' (@($marks.Values | Where-Object { -not $_.by -and $_.error }).Count -eq 2)
    Check 'auto: next tick tries nothing again' (@((Auto).started).Count -eq 0)

    # the output contract: a non-answer (J108: "dispatched a subagent ... standing by") is not a diagnosis
    $dmm = [string](Get-Content (Join-Path $kd 'recipes\diagnose.json') -Raw | ConvertFrom-Json).steps[0].mustMatch
    Check 'diagnose recipe: a real answer meets its contract' ($dmm -and "# What broke`nThe diff was too big.`n# Why`nBudget.`n# The fix`nJust retry it." -match $dmm)
    Check 'diagnose recipe: "dispatched a subagent, standing by" fails it' ("Wait for the subagent to report back. I've dispatched a research subagent. Standing by for its findings." -notmatch $dmm)
}
finally {
    foreach ($n in $save.Keys) { [Environment]::SetEnvironmentVariable($n, $save[$n]) }
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains((Split-Path $root -Leaf)) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }  # only this run's GUID root: a concurrent run of this suite (another job's tests station, verify) must keep its workers
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
Write-Host "Diagnose tests: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
