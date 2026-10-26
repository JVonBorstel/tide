# Tests for the pipeline's measuring and token-saving scripts: the scoreboard (kitchen/scoreboard.ps1) counts first-try passes,
# repairs, set-asides, reviewer verdicts, minutes and cost per stage from a kitchen's records; the repo map (kitchen/stations/map.ps1)
# lists files with their purpose and functions, within its size cap. Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-pipeline-' + [guid]::NewGuid().ToString('N'))
$save = $env:BRAIN_KITCHEN
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'jobs'), (Join-Path $root 'run') | Out-Null
    $env:BRAIN_KITCHEN = $root
    $now = [DateTime]::UtcNow
    $steps = @(@{ script = 'x\worktree.ps1' }, @{ script = 'x\agent-step.ps1'; args = @{ Role = 'plan' } }, @{ script = 'x\agent-step.ps1'; args = @{ Role = 'do' } },
        @{ script = 'x\tests.ps1' }, @{ script = 'x\repair.ps1' }, @{ script = 'x\agent-step.ps1'; args = @{ Role = 'check' } }, @{ script = 'x\merge.ps1' })
    $mk = { param($id, $status) @{ id = $id; name = "improve: thing $id"; status = $status; created = $now.AddHours(-2).ToString('o'); cursor = 6; steps = $steps } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$id.json") }
    & $mk 'J1' 'done'; & $mk 'J2' 'waiting-approval'; & $mk 'J3' 'quarantined'
    @{ id = 'J4'; name = 'scout: not an improve order'; status = 'done'; created = $now.ToString('o'); steps = @() } | ConvertTo-Json | Set-Content (Join-Path $root 'jobs\J4.json')
    Set-Content (Join-Path $root 'run\J1-s3-a0.log') "tests: PASS  Lint`ntests: ALL PASS"
    Set-Content (Join-Path $root 'run\J1-s4-a0.log') "repair: nothing to fix`ntests: ALL PASS"
    Set-Content (Join-Path $root 'run\J1-s5-a0.dish.md') "# In plain words`nok`nVERDICT: SHIP - fine"
    Set-Content (Join-Path $root 'run\J2-s3-a0.log') "tests: FAIL  Test-X`ntests: FAILED: Test-X"
    Set-Content (Join-Path $root 'run\J2-s4-a0.log') "repair: round 1 of 2`nrepair: fixed in round 1"
    Set-Content (Join-Path $root 'run\J2-s5-a0.dish.md') "VERDICT: SHIP - fixed"
    Set-Content (Join-Path $root 'run\J3-s3-a0.log') "tests: FAILED: Test-Y"
    Set-Content (Join-Path $root 'run\J3-s4-a0.log') "repair: still failing after the repair rounds"
    $ev = @(
        @{ ts = $now.AddMinutes(-60).ToString('o'); type = 'step.started'; job = 'J1'; step = 1 }, @{ ts = $now.AddMinutes(-50).ToString('o'); type = 'step.done'; job = 'J1'; step = 1 },
        @{ ts = $now.AddMinutes(-50).ToString('o'); type = 'cost'; job = 'J1'; step = 1; usd = 1.5; supplier = 'claude'; model = 'sonnet'; inputTokens = 1000; outputTokens = 500; cacheReadTokens = 50; cacheWriteTokens = 25 },
        @{ ts = $now.AddMinutes(-60).ToString('o'); type = 'step.started'; job = 'J2'; step = 1 }, @{ ts = $now.AddMinutes(-56).ToString('o'); type = 'step.done'; job = 'J2'; step = 1 },
        @{ ts = $now.AddMinutes(-56).ToString('o'); type = 'cost'; job = 'J2'; step = 1; usd = 0.5; supplier = 'claude'; model = 'sonnet'; inputTokens = 300; outputTokens = 200; cacheReadTokens = 20; cacheWriteTokens = 5 },
        # per-model fixtures: claude sonnet planned J1 and J2 (J1 passed first try, J2 did not); gemini built J3 (failed); an old event has no model
        @{ ts = $now.AddMinutes(-40).ToString('o'); type = 'cost'; job = 'J3'; step = 2; usd = 0.25; supplier = 'gemini'; model = 'gemini-3.8-flash-medium'; inputTokens = 900; outputTokens = 100; cacheReadTokens = 0; cacheWriteTokens = 0 },
        @{ ts = $now.AddMinutes(-40).ToString('o'); type = 'cost'; job = 'J2'; step = 2; usd = 0.1; inputTokens = 80; outputTokens = 20; cacheReadTokens = 0; cacheWriteTokens = 0 },
        @{ ts = $now.AddMinutes(-50).ToString('o'); type = 'cook'; job = 'J1'; step = 1; supplier = 'claude'; model = 'sonnet'; kind = 'plan'; ok = $true },
        @{ ts = $now.AddMinutes(-56).ToString('o'); type = 'cook'; job = 'J2'; step = 1; supplier = 'claude'; model = 'sonnet'; kind = 'plan'; ok = $true },
        @{ ts = $now.AddMinutes(-55).ToString('o'); type = 'cook'; job = 'J2'; step = 1; supplier = 'claude'; model = 'sonnet'; kind = 'plan'; ok = $true },
        @{ ts = $now.AddMinutes(-54).ToString('o'); type = 'cook'; job = 'J2'; step = 1; supplier = 'claude'; model = 'sonnet'; kind = 'plan'; ok = $false },
        # evolution fixtures: J1 merged 90 minutes after its order, auto-merged (one request, one auto); faults of every kind
        @{ ts = $now.AddMinutes(-31).ToString('o'); type = 'approval.requested'; job = 'J1'; step = 6 },
        @{ ts = $now.AddMinutes(-30).ToString('o'); type = 'approval.auto'; job = 'J1'; step = 6 },
        @{ ts = $now.AddMinutes(-30).ToString('o'); type = 'job.done'; job = 'J1' },
        @{ ts = $now.AddMinutes(-45).ToString('o'); type = 'step.logflood'; job = 'J2'; step = 3 },
        @{ ts = $now.AddMinutes(-44).ToString('o'); type = 'step.hung'; job = 'J3'; step = 2 },
        @{ ts = $now.AddMinutes(-43).ToString('o'); type = 'step.failed'; job = 'J2'; step = 3; why = 'Test-SousChef crashed before its summary line' },
        @{ ts = $now.AddMinutes(-42).ToString('o'); type = 'step.failed'; job = 'J3'; step = 6; why = 'conflict merging main' })
    $ev | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root 'events.jsonl')
    $s = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'counts only improve orders' ($s.orders -eq 3)
    Check 'first try: 1 of 3 tested' ($s.firstTryPct -eq 33)
    Check 'repaired: 1 of 3 fixed by the repair round' ($s.repairedPct -eq 33)
    Check 'set aside: 1 of 3' ($s.asidePct -eq 33)
    Check 'reviewer said ship: 2 of 2 reviewed' ($s.shipPct -eq 100)
    Check 'merged count' ($s.merged -eq 1)
    Check 'plan stage: average minutes over jobs that ran it, and cost summed' ($s.stages.plan.avgMin -eq 7 -and $s.stages.plan.usd -eq 2)
    Check 'plan stage: tokens aggregated in stages' ($s.stages.plan.tokens -eq 2100)
    $cs = $s.models.'claude/sonnet'; $gm = $s.models.'gemini/gemini-3.8-flash-medium'
    Check 'per model: runs and tokens per run (cache tokens included)' ($cs.runs -eq 2 -and $cs.tokensPerRun -eq 1050)
    Check 'per model: first-try pass rate of the orders it planned (1 of 2)' ($cs.tested -eq 2 -and $cs.firstTryPct -eq 50)
    Check 'per model: minutes per run and cost' ($cs.avgMin -eq 7 -and $cs.usd -eq 2)
    Check 'per model: a model that built a failed order has 0 percent first try' ($gm.runs -eq 1 -and $gm.firstTryPct -eq 0 -and $gm.tokensPerRun -eq 1000)
    Check 'per model: cost events without a model go to unknown' ($s.models.unknown.runs -eq 1 -and $s.models.unknown.tokensPerRun -eq 100)
    $kp = @($s.kinds | Where-Object { $_.kind -eq 'plan' -and $_.model -eq 'claude/sonnet' })
    Check 'per kind and model: ok rate from cook events' ($kp.Count -eq 1 -and $kp[0].runs -eq 4 -and $kp[0].okPct -eq 75)
    # evolution: rate, supporting numbers, faults, leap
    Check 'evolution rate: merged per day x first try x (1 - set aside)' ($s.rate -eq 0.03)
    Check 'evolution: tokens per merged change (all cost events)' ($s.tokensPerMerged -eq 3200)
    Check 'evolution: minutes order to merge' ($s.minOrderToMerge -eq 90)
    Check 'evolution: taps per merged is requested minus auto' ($s.tapsPerMerged -eq 0)
    Check 'evolution: auto-merged share' ($s.autoMergedPct -eq 100 -and $s.undone -eq 0)
    Check 'evolution: runner faults by kind' ($s.runnerFaults -eq 4 -and $s.runnerFaultDetails.logflood -eq 1 -and $s.runnerFaultDetails.hung -eq 1 -and $s.runnerFaultDetails.'crash-before-summary' -eq 1 -and $s.runnerFaultDetails.'merge conflict' -eq 1)
    Check 'evolution: leap 1, missing first try, set aside and faults' ($s.leap -eq 1 -and $s.leapName -eq 'A reliable line' -and @($s.missing) -contains 'first try >= 70%' -and @($s.missing) -contains 'set aside <= 10%' -and (@($s.missing) -match 'runner faults').Count -eq 1)
    Check 'evolution: no earlier line means a flat trend' ($s.trend -eq 'flat')
    Set-Content (Join-Path $root 'automerged.jsonl') (@(@{ job = 'J1'; at = $now.ToString('o') }, @{ job = 'J1'; undone = $true; at = $now.ToString('o') }) | ForEach-Object { $_ | ConvertTo-Json -Compress })
    $s3 = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution: undone merges counted from automerged.jsonl' ($s3.undone -eq 1)
    Remove-Item (Join-Path $root 'automerged.jsonl')
    & pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Record | Out-Null
    Check '-Record appends one line to the trend file' (@(Get-Content (Join-Path $root 'scoreboard.jsonl')).Count -eq 1)
    $rl = (Get-Content (Join-Path $root 'scoreboard.jsonl') -Raw) | ConvertFrom-Json
    Check '-Record keeps the evolution numbers' ($rl.rate -eq 0.03 -and $rl.leap -eq 1 -and $rl.runnerFaults -eq 4 -and $rl.tokensPerMerged -eq 3200 -and $rl.trendArrow)
    $s4 = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution: same rate as the recorded line is flat' ($s4.trend -eq 'flat')
    $txt = & pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') | Out-String
    Check 'plain report: evolution rate, leap, missing and supporting numbers' ($txt -match 'evolution rate 0\.03' -and $txt -match 'Leap 1: A reliable line' -and $txt -match 'missing for the next leap: first try >= 70%' -and $txt -match 'tokens per merged 3200' -and $txt -match 'runner faults 4 \(logflood 1, hung 1, crash-before-summary 1, merge conflict 1\)')
    Check 'plain report' ($txt -match 'first try 33%' -and $txt -match '3 improve orders, 1 merged')
    Check 'plain report: per-model row and per-kind row' ($txt -match 'claude/sonnet\s+2 runs\s+first try\s+50%\s+1050 tokens/run' -and $txt -match 'kind plan\s+claude/sonnet\s+4 runs\s+ok 75%')
    Check 'plain report shows tokens next to minutes' ($txt -match 'plan\s+7\s+min avg\s+2100 tokens\s+\$2')
    $null = & pwsh -NoProfile -File (Join-Path $kd 'ideas.ps1') coach -Id 'test' -Json
    $coachedIdea = @(Get-Content (Join-Path $root 'ideas.json') -Raw | ConvertFrom-Json).items | Where-Object { $_.source -eq 'coach' } | Select-Object -Last 1
    Check 'coach mentions worst model-per-kind pair with >= 3 runs' ($coachedIdea.goal -match "Worst model for a kind of work: claude/sonnet on 'plan' orders passed 75% of 4 runs")

    # auto-merge tracking: verifies approval.auto (line 113) and automerged.jsonl (line 119) with mixed manual/auto merge
    $rootAuto = Join-Path $root 'auto'; New-Item -ItemType Directory -Force -Path (Join-Path $rootAuto 'jobs'), (Join-Path $rootAuto 'run') | Out-Null
    $env:BRAIN_KITCHEN = $rootAuto
    @{ id = 'J1'; name = 'improve: order 1'; status = 'done'; created = $now.AddHours(-2).ToString('o'); steps = $steps } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $rootAuto 'jobs\J1.json')
    @{ id = 'J2'; name = 'improve: order 2'; status = 'done'; created = $now.AddHours(-2).ToString('o'); steps = $steps } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $rootAuto 'jobs\J2.json')
    Set-Content (Join-Path $rootAuto 'run\J1-s3-a0.log') 'tests: ALL PASS'
    Set-Content (Join-Path $rootAuto 'run\J2-s3-a0.log') 'tests: ALL PASS'
    @(
        @{ ts = $now.AddMinutes(-40).ToString('o'); type = 'approval.requested'; job = 'J1'; step = 6 },
        @{ ts = $now.AddMinutes(-39).ToString('o'); type = 'approval.auto'; job = 'J1'; step = 6 },
        @{ ts = $now.AddMinutes(-30).ToString('o'); type = 'job.done'; job = 'J1' },
        @{ ts = $now.AddMinutes(-20).ToString('o'); type = 'approval.requested'; job = 'J2'; step = 6 },
        @{ ts = $now.AddMinutes(-10).ToString('o'); type = 'job.done'; job = 'J2' }
    ) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $rootAuto 'events.jsonl')
    $sa1 = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution auto-merge: 1 of 2 merged jobs auto-merged via approval.auto' ($sa1.autoMergedPct -eq 50 -and $sa1.undone -eq 0)

    # Now add automerged.jsonl marking J2 as auto-merged and an undone record
    @(@{ job = 'J2'; at = $now.ToString('o') }, @{ job = 'J2'; undone = $true; at = $now.ToString('o') }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $rootAuto 'automerged.jsonl')
    $sa2 = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution auto-merge: automerged.jsonl marks J2 as auto-merged and counts undone' ($sa2.autoMergedPct -eq 100 -and $sa2.undone -eq 1)

    # a clean week passes leap 1 and the scoreboard moves on to leap 2 (tokens down 30% from the first line not yet shown)
    $root2 = Join-Path $root 'second'; New-Item -ItemType Directory -Force -Path (Join-Path $root2 'jobs'), (Join-Path $root2 'run') | Out-Null
    $env:BRAIN_KITCHEN = $root2
    @{ id = 'J1'; name = 'improve: clean'; status = 'done'; created = $now.AddHours(-2).ToString('o'); steps = $steps } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root2 'jobs\J1.json')
    Set-Content (Join-Path $root2 'run\J1-s3-a0.log') 'tests: ALL PASS'
    $evClean = @(
        @{ ts = $now.AddMinutes(-50).ToString('o'); type = 'step.started'; job = 'J1'; step = 3 },
        @{ ts = $now.AddMinutes(-45).ToString('o'); type = 'step.done'; job = 'J1'; step = 3 },
        @{ ts = $now.AddMinutes(-45).ToString('o'); type = 'cost'; job = 'J1'; step = 1; usd = 1; supplier = 'claude'; model = 'sonnet'; inputTokens = 100; outputTokens = 50; cacheReadTokens = 0; cacheWriteTokens = 0 },
        @{ ts = $now.AddMinutes(-30).ToString('o'); type = 'approval.requested'; job = 'J1'; step = 6 },
        @{ ts = $now.AddMinutes(-30).ToString('o'); type = 'approval.auto'; job = 'J1'; step = 6 },
        @{ ts = $now.AddMinutes(-30).ToString('o'); type = 'job.done'; job = 'J1' }
    )
    $evClean | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'events.jsonl')
    $c = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution: leap 1 exit met moves the kitchen to leap 2' ($c.leap -eq 2 -and $c.leapName -eq 'Measured and lean' -and $c.runnerFaults -eq 0 -and (@($c.missing) -match 'baseline').Count -ge 1)
    Check 'leap 2: tokens tracked on every run is satisfied when cost events have tokens' (-not (@($c.missing) -contains 'tokens tracked on every run'))
    Check 'leap 2: reports baseline missing for tokens and tests' ((@($c.missing) -contains 'tokens per merged change down 30% (no first-week baseline yet)') -and (@($c.missing) -contains 'test time per change down 40% (no first-week baseline yet)'))

    # Leap 2: verify untracked tokens condition when a cost event has 0 tokens
    $evUntracked = @($evClean) + @(@{ ts = $now.AddMinutes(-40).ToString('o'); type = 'cost'; job = 'J1'; step = 2; usd = 0; supplier = 'claude'; model = 'sonnet'; inputTokens = 0; outputTokens = 0; cacheReadTokens = 0; cacheWriteTokens = 0 })
    $evUntracked | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'events.jsonl')
    $cUntracked = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'leap 2: untracked tokens caught when cost event has 0 tokens' (@($cUntracked.missing) -contains 'tokens tracked on every run')

    # Leap 2: verify untracked tokens condition when cost events are completely absent
    @($evClean | Where-Object { $_.type -ne 'cost' }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'events.jsonl')
    $cNoCost = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'leap 2: missing cost events caught as untracked tokens' (@($cNoCost.missing) -contains 'tokens tracked on every run')

    # Restore clean events
    $evClean | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'events.jsonl')

    # Leap 2: baseline present but reductions insufficient (tokensPerMerged = 150 vs base 160 -> down 6% < 30%; test time = 5.0 min vs base 6.0 min -> down 17% < 40%)
    @(@{ rate = 0.05; tokensPerMerged = 160; stages = @{ tests = @{ avgMin = 6.0 } } }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'scoreboard.jsonl') -Encoding utf8
    $cInsuf = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'leap 2: tokens reduction insufficient against baseline' (@($cInsuf.missing) -contains 'tokens per merged change down 30% from the first week')
    Check 'leap 2: test reduction insufficient against baseline' (@($cInsuf.missing) -contains 'test time per change down 40% from the first week')
    Check 'leap 2: does not report missing baseline when baseline exists' (-not (@($cInsuf.missing) -match 'no first-week baseline yet'))

    # Leap 2: baseline present but tests stage missing from baseline stages reports missing baseline
    @(@{ rate = 0.05; tokensPerMerged = 160; stages = @{ plan = @{ avgMin = 2.0 } } }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'scoreboard.jsonl') -Encoding utf8
    $cNoTestStage = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'leap 2: baseline missing tests stage reports missing baseline for tests' (@($cNoTestStage.missing) -contains 'test time per change down 40% (no first-week baseline yet)')

    # Leap 2 exit -> Leap 3: baseline reductions met (tokensPerMerged = 150 vs base 300 -> down 50% >= 30%; test time = 5.0 min vs base 10.0 min -> down 50% >= 40%)
    $baseRow = @{ rate = 0.05; tokensPerMerged = 300; stages = @{ tests = @{ avgMin = 10.0 } } }
    @($baseRow) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'scoreboard.jsonl') -Encoding utf8
    $c3 = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution: leap 2 exit met moves the kitchen to leap 3' ($c3.leap -eq 3 -and $c3.leapName -eq 'Visible')
    Check 'leap 3: missing live activity stream, recap, and push alerts' (@($c3.missing) -contains 'live activity stream' -and @($c3.missing) -contains 'replay and recap for every order' -and @($c3.missing) -contains 'push alerts working')

    # Leap 3 exit -> Leap 4: add activity stream, recap, alerts
    Set-Content (Join-Path $root2 'run\live.activity.jsonl') '{"type":"step"}'
    Set-Content (Join-Path $root2 'order-recap.md') '# Recap'
    Set-Content (Join-Path $root2 'alerts.jsonl') '{"alert":"ok"}'
    $c4 = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution: leap 3 exit met moves the kitchen to leap 4' ($c4.leap -eq 4 -and $c4.leapName -eq 'Useful end to end')
    Check 'leap 4: missing overnight job-hunt and application tracker' (@($c4.missing) -contains 'overnight job-hunt run with tailored packs' -and @($c4.missing) -contains 'application tracker follow-ups')

    # Leap 4 exit -> Leap 5: add job-hunt job and application tracker
    @{ id = 'J99'; name = 'hunt: openings'; status = 'done'; created = $now.ToString('o'); steps = @() } | ConvertTo-Json | Set-Content (Join-Path $root2 'jobs\J99.json')
    Set-Content (Join-Path $root2 'tracker-followups.json') '{"tracked":1}'
    $c5 = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution: leap 4 exit met moves the kitchen to leap 5' ($c5.leap -eq 5 -and $c5.leapName -eq 'Self-directed evolution')
    Check 'leap 5: missing target ideas (rate is already above the recorded line)' (@($c5.missing) -contains 'coach experiments filed with a target number' -and @($c5.missing) -notcontains 'rate of evolution rising week over week')

    # Leap 5 with declining rate produces down trend and keeps rising-rate missing
    Set-Content (Join-Path $root2 'ideas.json') '{"target": 0.5}'
    @($baseRow, @{ rate = 0.50; tokensPerMerged = 150 }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'scoreboard.jsonl') -Encoding utf8
    $cDown = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution: declining rate produces downward trend' ($cDown.trend -eq 'down' -and $cDown.trendArrow -and @($cDown.missing) -contains 'rate of evolution rising week over week')

    # Leap 5 with flat rate (rate equal to previous) produces flat trend and keeps rising-rate missing
    @($baseRow, @{ rate = 0.14; tokensPerMerged = 150 }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'scoreboard.jsonl') -Encoding utf8
    $cFlat = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution: equal rate produces flat trend and keeps rising-rate missing' ($cFlat.trend -eq 'flat' -and @($cFlat.missing) -contains 'rate of evolution rising week over week')

    # Leap 5 exit (all exit numbers met): rising evolution rate
    @($baseRow, @{ rate = 0.05; tokensPerMerged = 150 }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root2 'scoreboard.jsonl') -Encoding utf8
    $c6 = (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Json | Out-String) | ConvertFrom-Json
    Check 'evolution: leap 5 exit met achieves all exit numbers' ($c6.leap -eq 5 -and $c6.leapName -eq 'Self-directed evolution (all exit numbers met)' -and $c6.missing.Count -eq 0)
    Check 'evolution: rising rate produces upward trend' ($c6.trend -eq 'up' -and $c6.trendArrow)
    $env:BRAIN_KITCHEN = $root

    # the repo map
    $g = Join-Path $root 'repo'; New-Item -ItemType Directory -Force -Path (Join-Path $g 'kitchen'), (Join-Path $g 'docs') | Out-Null
    & git -C $g init -q 2>&1 | Out-Null
    Set-Content (Join-Path $g 'kitchen\tool.ps1') "# Tool: does a useful thing.`nparam([string]`$X)`nfunction Get-Thing { 1 }`nfunction Set-Thing { 2 }"
    Set-Content (Join-Path $g 'kitchen\app.mjs') "// The app server.`nexport function serve() {}`nasync function helper() {}"
    Set-Content (Join-Path $g 'docs\notes.md') '# Long notes nobody needs in the map'
    Set-Content (Join-Path $g 'README.md') '# The repo'
    & git -C $g add -A 2>&1 | Out-Null
    $out = Join-Path $root 'MAP.md'
    & pwsh -NoProfile -File (Join-Path $kd 'stations\map.ps1') -Dir $g -Out $out | Out-Null
    $m = Get-Content $out -Raw
    Check 'map: file, line count and its own first comment' ($m -match 'kitchen/tool\.ps1 \(4\) - Tool: does a useful thing\.')
    Check 'map: PowerShell and JavaScript functions' ($m -match 'functions: Get-Thing, Set-Thing' -and $m -match 'functions: serve, helper')
    Check 'map: README in, other docs out' ($m -match 'README\.md' -and $m -notmatch 'notes\.md')
    & pwsh -NoProfile -File (Join-Path $kd 'stations\map.ps1') -Dir $g -Out $out -MaxChars 200 | Out-Null
    Check 'map: cut at its size cap, saying so' ((Get-Content $out -Raw) -match 'map cut at 200 characters')
    # the lesson book: repaired failures, newest first, the same failure only once
    @(@{ job = 'J7'; broke = @('FAIL: a.ps1:2 $json is the same variable as the -Json switch') }, @{ job = 'J9'; broke = @('FAIL: a.ps1:40 $json is the same variable as the -Json switch', 'FAIL: Lever URL empty') }) |
        ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root 'lessons.jsonl')
    $env:KITCHEN_JOB = 'J10'
    try { & pwsh -NoProfile -File (Join-Path $kd 'stations\map.ps1') -Dir $g -Out $out | Out-Null } finally { $env:KITCHEN_JOB = $null }
    $les = Get-Content (Join-Path $root 'LESSONS.md') -Raw
    Check 'lessons: written beside the map, newest first, repeats merged' ($les -match 'Lever URL empty \(J9\)' -and ([regex]::Matches($les, 'same variable')).Count -eq 1 -and $les.IndexOf('(J9)') -lt $les.IndexOf('Lever'))
    $rec = Get-Content (Join-Path $kd 'recipes\improve.json') -Raw | ConvertFrom-Json
    Check 'planner and builder both read the lessons' ($rec.steps[2].args.Context -match 'LESSONS\.md' -and $rec.steps[3].args.Context -match 'LESSONS\.md')
    Check 'improve recipe: map right after the worktree, and the planner reads it' ($rec.steps[1].station -eq 'map' -and $rec.steps[2].args.Context -match 'MAP\.md')
} finally {
    $env:BRAIN_KITCHEN = $save
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Pipeline tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
