# The pipeline's scoreboard: how well Improve orders go, from the kitchen's own records (no AI, read-only).
# This is the fitness score the kitchen evolves against: a change to the pipeline is good if these numbers get better.
#   first try  - tests passed the first time they ran (lint included)      repaired - tests failed, the repair round fixed them
#   set aside  - quarantined or failed                                     shipped  - the taster said SHIP; merged - Jordan said yes
# Plus minutes and pay-per-use cost per stage (plan, build, tests, repair, review...), so slow or costly stages stand out.
# Evolution (kitchen/EVOLUTION.md): rate = merged per day x first-try rate x (1 - set-aside rate), supporting numbers, runner faults,
# and which of the five leaps the kitchen is on with what its exit numbers still lack.
# ZG-22: crew Brier (claims vs outcomes, per model and kind) and the build standard's four numbers, 'unknown' with the missing source named.
#   scoreboard.ps1 [-Days 7] [-Json] [-Record]   (-Record appends today's numbers to <kitchen>\scoreboard.jsonl, the trend line)
param([double]$Days = 7, [switch]$Json, [switch]$Record)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$since = (Get-Date).ToUniversalTime().AddDays(-$Days)
$utc = { param($s) ([DateTime]$s).ToUniversalTime() }
# the window's Improve orders: jobs\ plus the archived ones whose summary falls in the window, read whole (kitchen/jobs-lib.ps1)
. (Join-Path $PSScriptRoot 'jobs-lib.ps1')
# (Floors, the roadmap-item orders, are read too, only for the build standard's minutes from Floor start to merge; never counted as orders)
$isFloor = { param($s) ([string]$s.name) -notlike 'improve:*' -and ([string]$s.recipe -eq 'roadmap-item' -or ([string]$s.name) -like 'roadmap-item:*') }
$inWindow = { param($s) (([string]$s.name) -like 'improve:*' -or (& $isFloor $s)) -and $s.created -and (& $utc $s.created) -ge $since }
$loaded = @(Get-KitchenJobs $root -ArchiveFull $inWindow | Where-Object { $_ -and $_.created -and (& $utc $_.created) -ge $since })
$jobs = @($loaded | Where-Object { ([string]$_.name) -like 'improve:*' })
$floors = @($loaded | Where-Object { & $isFloor $_ })
$ids = @{}; foreach ($j in $jobs) { $ids[[string]$j.id] = $j }
$floorIds = @{}; foreach ($f in $floors) { $floorIds[[string]$f.id] = $f }
# timings and costs from the event log
$reqEv = @{}; $autoEv = @{}; $doneAt = @{}; $faults = [ordered]@{ logflood = 0; hung = 0; 'crash-before-summary' = 0; 'merge conflict' = 0 }
$started = @{}; $mins = @{}; $cost = @{}; $tokens = @{}; $costEv = @(); $cookEv = @()
$globalEv = [Collections.Generic.List[hashtable]]::new(); $undoneEvAt = @{}; $brokenAt = @{}; $floorStepDone = @{}; $floorDone = @{}
$ev = Join-Path $root 'events.jsonl'
if (Test-Path -LiteralPath $ev) {
    foreach ($line in [IO.File]::ReadLines($ev)) {
        # main's state changes and every undo, whatever order they belong to (the build standard's broken mains and false undos)
        if ($line -match '"type":"(main\.status|merge\.undone)"') { try { $globalEv.Add(($line | ConvertFrom-Json -AsHashtable)) } catch { } }
        if ($line -notmatch '"job":"(J\d+)"') { continue }
        $jid = $Matches[1]
        if ($floorIds.ContainsKey($jid) -and $line -match '"type":"(step\.done|job\.done)"') {
            try { $fe = $line | ConvertFrom-Json -AsHashtable; if ($fe.type -eq 'job.done') { $floorDone[$jid] = & $utc $fe.ts } else { $floorStepDone["$jid/$($fe.step)"] = & $utc $fe.ts } } catch { }
        }
        if (-not $ids.ContainsKey($jid)) { continue }
        try { $e = $line | ConvertFrom-Json -AsHashtable } catch { continue }
        $k = "$($e.job)/$($e.step)"
        if ($line -match '"type":"[^"]*logflood') { $faults['logflood']++ } elseif ($line -match '"type":"[^"]*hung') { $faults['hung']++ }
        if ($line -match 'crashed before its summary line') { $faults['crash-before-summary']++ }
        if ($line -match 'conflict merging|merge conflict') { $faults['merge conflict']++ }
        switch ($e.type) {
            'step.started' { $started[$k] = & $utc $e.ts }
            'step.done' { if ($started[$k]) { $mins[$k] = [double]$mins[$k] + ((& $utc $e.ts) - $started[$k]).TotalMinutes; $started.Remove($k) } }
            'cost' {
                $cost[$k] = [double]$cost[$k] + [double]$e.usd
                $tk = [int]$e.inputTokens + [int]$e.outputTokens + [int]$e.cacheReadTokens + [int]$e.cacheWriteTokens
                $tokens[$k] = [int]$tokens[$k] + $tk
                $costEv += @{ job = [string]$e.job; step = [int]$e.step; sup = [string]$e.supplier; model = [string]$e.model; usd = [double]$e.usd; tokens = $tk }
            }
            'approval.requested' { $reqEv[[string]$e.job] = [int]$reqEv[[string]$e.job] + 1 }
            'approval.auto' { $autoEv[[string]$e.job] = [int]$autoEv[[string]$e.job] + 1 }
            'job.done' { $doneAt[[string]$e.job] = & $utc $e.ts }
            'merge.undone' { if (-not $undoneEvAt[[string]$e.job]) { $undoneEvAt[[string]$e.job] = & $utc $e.ts } }
            'merge.broken' { $brokenAt[[string]$e.job] = & $utc $e.ts }
            'cook' { $cookEv += @{ job = [string]$e.job; step = [int]$e.step; sup = [string]$e.supplier; model = [string]$e.model; kind = [string]$e.kind; ok = [bool]$e.ok } }
        }
    }
}
function Stage($s) { $n = [IO.Path]::GetFileNameWithoutExtension([string]$s.script); if ($n -eq 'agent-step') { switch ([string]$s.args.Role) { 'do' { 'build' } 'check' { 'review' } default { [string]$s.args.Role } } } else { $n } }
function RunLog($id, $i) { Get-ChildItem -LiteralPath (Join-Path $root 'run') -Filter "$id-s$i-a*.log" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1 }
# ZG-22: a build crew's line claiming the tests pass ("all tests pass", "the suites should be green": the verb at most 3 words after). Not the
# tests Step's own "tests:" lines, not a line that says they did not, could not or failed to run, and not a condition or a requirement
# ("if", "only", "must", "unless", "either", "whether": 10-24 live build logs describe tests that way).
function Test-BuildClaim([string]$Path) {
    foreach ($ln in [IO.File]::ReadLines($Path)) {
        if ($ln -match '^\s*tests:' -or $ln -notmatch '(?i)\b(tests?|suites?)\b(\s+\w+){0,3}?\s+(pass|passes|passed|passing|green)\b') { continue }
        if ($ln -notmatch "(?i)\b(not|never|cannot|can't|couldn't|could not|unable|didn't|did not|fail\w*|unverified|untested|unknown|if|only|must|unless|either|whether)\b") { return $true }
    }
    $false
}
$rows = foreach ($j in $jobs) {
    $st = @($j.steps); $names = @($st | ForEach-Object { Stage $_ })
    $ti = [array]::IndexOf($names, 'tests'); $ri = [array]::IndexOf($names, 'repair'); $ci = [array]::IndexOf($names, 'review')
    $bi = [array]::IndexOf($names, 'build'); $buildClaim = $false
    if ($bi -ge 0) { $l = RunLog $j.id $bi; if ($l) { $buildClaim = Test-BuildClaim $l.FullName } }
    $first = $null; $repaired = $false; $ship = $null
    if ($ti -ge 0) { $l = RunLog $j.id $ti; if ($l) { $first = [bool](Select-String -LiteralPath $l.FullName -Pattern 'tests: ALL PASS' -SimpleMatch -Quiet) } }
    if ($ri -ge 0) { $l = RunLog $j.id $ri; if ($l) { $repaired = [bool](Select-String -LiteralPath $l.FullName -Pattern 'repair: fixed in round' -SimpleMatch -Quiet) } }
    if ($ci -ge 0) { $d = Get-ChildItem -LiteralPath (Join-Path $root 'run') -Filter "$($j.id)-s$ci-a*.dish.md" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1; if ($d) { $ship = [bool](Select-String -LiteralPath $d.FullName -Pattern 'VERDICT: SHIP' -SimpleMatch -Quiet) } }
    $stages = [ordered]@{}; for ($i = 0; $i -lt $st.Count; $i++) { $n = $names[$i]; if (-not $stages[$n]) { $stages[$n] = @{ min = 0.0; usd = 0.0; tokens = 0 } }; $stages[$n].min += [double]$mins["$($j.id)/$i"]; $stages[$n].usd += [double]$cost["$($j.id)/$i"]; $stages[$n].tokens += [int]$tokens["$($j.id)/$i"] }
    [pscustomobject]@{ id = $j.id; status = [string]$j.status; first = $first; repaired = $repaired; ship = $ship
        aside = [string]$j.status -in 'quarantined', 'failed'; merged = [string]$j.status -eq 'done'; stages = $stages; ci = $ci; bi = $bi; buildClaim = $buildClaim }
}
$rows = @($rows)
# per model: runs, first-try pass rate of the orders it planned or built, tokens and minutes per run (events without a model: 'unknown')
$stageOf = @{}; foreach ($j in $jobs) { $nm = @(@($j.steps) | ForEach-Object { Stage $_ }); for ($i = 0; $i -lt $nm.Count; $i++) { $stageOf["$($j.id)/$i"] = $nm[$i] } }
$firstOf = @{}; foreach ($r in $rows) { if ($null -ne $r.first) { $firstOf[[string]$r.id] = [bool]$r.first } }
$perStep = @{}; foreach ($c in $costEv) { $perStep["$($c.job)/$($c.step)"] = [int]$perStep["$($c.job)/$($c.step)"] + 1 }
$modelKey = { param($c) if ($c.model) { if ($c.sup) { "$($c.sup)/$($c.model)" } else { [string]$c.model } } else { 'unknown' } }
$mm = @{}
foreach ($c in $costEv) {
    $key = & $modelKey $c
    if (-not $mm[$key]) { $mm[$key] = @{ runs = 0; tokens = 0; min = 0.0; usd = 0.0; tested = @{}; passed = @{} } }
    $m = $mm[$key]; $sk = "$($c.job)/$($c.step)"
    $m.runs++; $m.tokens += [int]$c.tokens; $m.usd += [double]$c.usd; $m.min += [double]$mins[$sk] / [math]::Max(1, [int]$perStep[$sk])
    if ($stageOf[$sk] -in 'plan', 'build' -and $firstOf.ContainsKey([string]$c.job)) { $m.tested[[string]$c.job] = $true; if ($firstOf[[string]$c.job]) { $m.passed[[string]$c.job] = $true } }
}
$kk = @{}
foreach ($c in $cookEv) {
    $mk = & $modelKey $c; $key = "$($c.kind)|$mk"
    if (-not $kk[$key]) { $kk[$key] = @{ kind = [string]$c.kind; model = $mk; runs = 0; ok = 0 } }
    $kk[$key].runs++; if ($c.ok) { $kk[$key].ok++ }
}
$tested = @($rows | Where-Object { $null -ne $_.first })
$pct = { param($a, $b) if ($b) { [math]::Round(100.0 * $a / $b) } else { $null } }
$stageTot = [ordered]@{}
foreach ($r in $rows) { foreach ($k in $r.stages.Keys) { if (-not $stageTot[$k]) { $stageTot[$k] = @{ min = 0.0; usd = 0.0; tokens = 0; n = 0 } }; if ($r.stages[$k].min -gt 0) { $stageTot[$k].n++ }; $stageTot[$k].min += $r.stages[$k].min; $stageTot[$k].usd += $r.stages[$k].usd; $stageTot[$k].tokens += [int]$r.stages[$k].tokens } }
$score = [ordered]@{
    at = (Get-Date).ToUniversalTime().ToString('o'); days = $Days; orders = $rows.Count
    firstTryPct = & $pct @($tested | Where-Object first).Count $tested.Count
    repairedPct = & $pct @($tested | Where-Object { -not $_.first -and $_.repaired }).Count $tested.Count
    asidePct = & $pct @($rows | Where-Object aside).Count $rows.Count
    shipPct = & $pct @($rows | Where-Object { $_.ship }).Count @($rows | Where-Object { $null -ne $_.ship }).Count
    merged = @($rows | Where-Object merged).Count
    stages = [ordered]@{}; jobs = @($rows | ForEach-Object { [ordered]@{ id = $_.id; status = $_.status; first = $_.first; repaired = $_.repaired; ship = $_.ship } })
}
foreach ($k in $stageTot.Keys) { $t = $stageTot[$k]; $score.stages[$k] = [ordered]@{ avgMin = $(if ($t.n) { [math]::Round($t.min / $t.n, 1) } else { 0 }); tokens = [int]$t.tokens; usd = [math]::Round($t.usd, 2) } }
$score.models = [ordered]@{}
foreach ($k in ($mm.Keys | Sort-Object)) {
    $m = $mm[$k]
    $score.models[$k] = [ordered]@{ runs = $m.runs; tested = $m.tested.Count; firstTryPct = $(if ($m.tested.Count) { [math]::Round(100.0 * $m.passed.Count / $m.tested.Count) } else { $null })
        tokensPerRun = [int][math]::Round($m.tokens / [math]::Max(1, $m.runs)); avgMin = [math]::Round($m.min / [math]::Max(1, $m.runs), 1); usd = [math]::Round($m.usd, 2) }
}
$score.kinds = @($kk.Values | Sort-Object { $_.kind }, { $_.model } | ForEach-Object { [ordered]@{ kind = $_.kind; model = $_.model; runs = $_.runs; okPct = [int][math]::Round(100.0 * $_.ok / $_.runs) } })
# evolution: the rate, its supporting numbers and the leap the kitchen is on
$trendFile = Join-Path $root 'scoreboard.jsonl'
$trendRows = @(); if (Test-Path -LiteralPath $trendFile) { $trendRows = @(Get-Content -LiteralPath $trendFile -ErrorAction SilentlyContinue | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ }) }
$prev = if ($trendRows.Count) { $trendRows[-1] } else { $null }; $base = if ($trendRows.Count) { $trendRows[0] } else { $null }
$mergedRows = @($rows | Where-Object merged); $nMerged = $mergedRows.Count
$firstRate = if ($null -ne $score.firstTryPct) { $score.firstTryPct / 100.0 } else { 0.0 }
$asideRate = if ($null -ne $score.asidePct) { $score.asidePct / 100.0 } else { 0.0 }
$score.rate = [math]::Round(($nMerged / [math]::Max($Days, 0.01)) * $firstRate * (1.0 - $asideRate), 2)
$totTokens = 0; foreach ($c in $costEv) { $totTokens += [int]$c.tokens }
$score.tokensPerMerged = if ($nMerged) { [int][math]::Round($totTokens / $nMerged) } else { $null }
$spans = @(); foreach ($r in $mergedRows) { $j = $ids[[string]$r.id]; if ($doneAt.ContainsKey([string]$r.id) -and $j.created) { $spans += ($doneAt[[string]$r.id] - (& $utc $j.created)).TotalMinutes } }
$score.minOrderToMerge = if ($spans.Count) { [math]::Round(($spans | Measure-Object -Average).Average, 1) } else { $null }
$nReq = 0; $nAuto = 0; foreach ($i in $ids.Keys) { $nReq += [int]$reqEv[$i]; $nAuto += [int]$autoEv[$i] }
$score.tapsPerMerged = if ($nMerged) { [math]::Round([math]::Max(0, $nReq - $nAuto) / $nMerged, 2) } else { $null }
$autoSet = @{}; foreach ($i in $autoEv.Keys) { $autoSet[$i] = $true }
$undone = 0; $amMergedAt = @{}; $amUndoneAt = @{}
$amf = Join-Path $root 'automerged.jsonl'
if (Test-Path -LiteralPath $amf) {
    foreach ($l in (Get-Content -LiteralPath $amf -ErrorAction SilentlyContinue | Where-Object { $_ })) {
        try { $a = $l | ConvertFrom-Json } catch { continue }
        $aj = [string]$a.job; $aat = if ($a.at) { & $utc $a.at } else { $null }
        if ($a.undone) { $undone++; if ($aat -and -not $amUndoneAt[$aj]) { $amUndoneAt[$aj] = $aat } }
        elseif ($ids.ContainsKey($aj)) { $autoSet[$aj] = $true; if ($aat -and -not $a.type -and -not $amMergedAt[$aj]) { $amMergedAt[$aj] = $aat } }
    }
}
$score.autoMergedPct = & $pct @($mergedRows | Where-Object { $autoSet[[string]$_.id] }).Count $nMerged
$score.undone = $undone
# ZG-22 crew Brier (Creed 5, proven not claimed): each claim a crew makes is scored against what happened. Brier = mean (claim - outcome)^2:
# 0 = always right, 1 = always wrong. An Inspector's "VERDICT: SHIP" is a 1.0 claim that the change is good: outcome 1 when it merged and
# was not undone within 7 days of the merge, 0 when it was undone within those 7 days (automerged.jsonl and undo-merge.ps1's records, or a
# merge.undone event) or red on verify (merge.broken: it broke main and could not be undone). A build crew's line saying the tests pass is
# a 1.0 claim scored against the tests Step's first run (ends "tests: ALL PASS" = 1, else 0). No outcome yet (not merged, not undone, no
# tests run) = not scored. A kept merge younger than 7 days is scored 1 and counted as pending: it can still be undone.
function Get-InspectorOutcome($r) {
    $id = [string]$r.id
    if ($brokenAt[$id]) { return @{ outcome = 0.0 } }
    $mergedAt = if ($amMergedAt[$id]) { $amMergedAt[$id] } else { $doneAt[$id] }
    $undoAt = @(@($amUndoneAt[$id], $undoneEvAt[$id]) | Where-Object { $_ } | Sort-Object | Select-Object -First 1)
    if ($undoAt.Count -and ($null -eq $mergedAt -or ($undoAt[0] - $mergedAt).TotalDays -le 7)) { return @{ outcome = 0.0 } }
    if (-not $r.merged) { return $null }
    @{ outcome = 1.0; pending = ($null -eq $mergedAt -or ((Get-Date).ToUniversalTime() - $mergedAt).TotalDays -lt 7) }
}
$stepModel = @{}; foreach ($c in $costEv) { $stepModel["$($c.job)/$($c.step)"] = & $modelKey $c }
$stepKind = @{}; foreach ($c in $cookEv) { if ($c.job) { $stepKind["$($c.job)/$($c.step)"] = @{ kind = $c.kind; model = & $modelKey $c } } }
$bTot = @{}; $bModel = @{}; $bKind = @{}; $bPending = 0
function Add-Claim([string]$Who, [string]$Step, [double]$Outcome) {
    $sq = [math]::Pow(1.0 - $Outcome, 2); $sk = $stepKind[$Step]
    $mk = if ($stepModel[$Step]) { $stepModel[$Step] } elseif ($sk) { $sk.model } else { 'unknown' }
    $kk = if ($sk) { "$($sk.kind)|$($sk.model)" } else { "unknown|$mk" }
    foreach ($p in @(@($bTot, 'all'), @($bTot, $Who), @($bModel, $mk), @($bKind, $kk))) {
        $m = $p[0]; $k = [string]$p[1]; if (-not $m[$k]) { $m[$k] = @{ n = 0; sum = 0.0 } }; $m[$k].n++; $m[$k].sum += $sq
    }
}
foreach ($r in $rows) {
    if ($r.ship -eq $true -and $r.ci -ge 0) { $o = Get-InspectorOutcome $r; if ($o) { Add-Claim -Who 'inspector' -Step "$($r.id)/$($r.ci)" -Outcome $o.outcome; if ($o.pending) { $bPending++ } } }
    if ($r.buildClaim -and $null -ne $r.first) { Add-Claim -Who 'builder' -Step "$($r.id)/$($r.bi)" -Outcome $(if ($r.first) { 1.0 } else { 0.0 }) }
}
$bv = { param($t) if ($t -and $t.n) { [math]::Round($t.sum / $t.n, 2) } else { $null } }
$score.brier = [ordered]@{ value = & $bv $bTot['all']; claims = [int]$bTot['all'].n; pending = $bPending
    inspector = [ordered]@{ value = & $bv $bTot['inspector']; claims = [int]$bTot['inspector'].n }
    builder = [ordered]@{ value = & $bv $bTot['builder']; claims = [int]$bTot['builder'].n }
    models = [ordered]@{}; kinds = @(); missing = '' }
foreach ($k in ($bModel.Keys | Sort-Object)) { $score.brier.models[$k] = [ordered]@{ value = & $bv $bModel[$k]; claims = $bModel[$k].n } }
$score.brier.kinds = @($bKind.Keys | Sort-Object | ForEach-Object { $kp = $_ -split '\|', 2; [ordered]@{ kind = $kp[0]; model = $kp[1]; value = & $bv $bKind[$_]; claims = $bKind[$_].n } })
if (-not $score.brier.claims) { $score.brier.missing = 'no Inspector SHIP with an outcome yet and no build crew line saying the tests pass (jobs\, run\ logs, automerged.jsonl, events.jsonl)' }
# next to firstTryPct: each model's and each kind's own Brier (null = no scored claim)
foreach ($k in @($score.models.Keys)) { $b = $bModel[$k]; $score.models[$k]['brier'] = & $bv $b; $score.models[$k]['brierClaims'] = [int]$b.n }
foreach ($c in $score.kinds) { $b = $bKind["$($c.kind)|$($c.model)"]; $c['brier'] = & $bv $b; $c['brierClaims'] = [int]$b.n }
# ZG-22: the build standard's four numbers (projects/tide/plans/build-standard-2026-10-23.md) for the same window. A number with no data
# behind it is null and missing.<name> says which source is missing; never a guess.
$std = [ordered]@{ brokenMains = $null; falseUndos = $null; silentFailures = $null; floorMinutes = $null; floors = 0; missing = [ordered]@{} }
$winEv = @($globalEv | Where-Object { $_.ts -and (& $utc $_.ts) -ge $since })
$hasEv = Test-Path -LiteralPath $ev
if (-not $hasEv) { $std.missing.brokenMains = 'events.jsonl is missing' }
elseif (-not @($globalEv | Where-Object { $_.type -eq 'main.status' }).Count -and -not (Test-Path -LiteralPath (Join-Path $root 'main-status'))) { $std.missing.brokenMains = 'no main.status events in events.jsonl and no main-status folder (verify writes them)' }
else { $std.brokenMains = @($winEv | Where-Object { $_.type -eq 'main.status' -and [string]$_.state -eq 'red' }).Count }
$undos = @($winEv | Where-Object { $_.type -eq 'merge.undone' }); $unproven = @($undos | Where-Object { -not $_.preMergeSha }).Count
if (-not $hasEv) { $std.missing.falseUndos = 'events.jsonl is missing' }
elseif ($unproven) { $std.missing.falseUndos = "$unproven of $($undos.Count) merge.undone events in events.jsonl have no preMergeSha (no blame check ran)" }
else { $std.falseUndos = 0 }
$std.missing.silentFailures = 'nothing records yet when a failure reached the Board'
$fMin = @(foreach ($f in $floors) {
        $mi = [array]::IndexOf(@(@($f.steps) | ForEach-Object { Stage $_ }), 'merge')
        $at = if ($mi -ge 0 -and $floorStepDone["$($f.id)/$mi"]) { $floorStepDone["$($f.id)/$mi"] } else { $floorDone[[string]$f.id] }
        if ($at) { ($at - (& $utc $f.created)).TotalMinutes }
    })
$std.floors = $fMin.Count
if ($fMin.Count) { $std.floorMinutes = [math]::Round(($fMin | Measure-Object -Average).Average, 1) }
else { $std.missing.floorMinutes = 'no merged roadmap-item work orders started in the window (jobs\, events.jsonl); hand-merged Floors (merges.jsonl) carry no start time' }
$score.standard = $std
$score.runnerFaultDetails = $faults
$score.runnerFaults = [int](($faults.Values | Measure-Object -Sum).Sum)
$missing = [System.Collections.Generic.List[string]]::new(); $leap = 6
$leaps = 'A reliable line', 'Measured and lean', 'Visible', 'Useful end to end', 'Self-directed evolution'
if ($null -eq $score.firstTryPct -or $score.firstTryPct -lt 70) { $missing.Add('first try >= 70%') }
if ($null -eq $score.asidePct -or $score.asidePct -gt 10) { $missing.Add('set aside <= 10%') }
if ($score.runnerFaults -gt 0) { $missing.Add("runner faults = 0 (now $($score.runnerFaults))") }
if ($missing.Count) { $leap = 1 } else {
    $untracked = @($costEv | Where-Object { [int]$_.tokens -le 0 }).Count
    if (-not $costEv.Count -or $untracked) { $missing.Add('tokens tracked on every run') }
    if ($null -eq $base -or $null -eq $base.tokensPerMerged -or $null -eq $score.tokensPerMerged) { $missing.Add('tokens per merged change down 30% (no first-week baseline yet)') }
    elseif ($score.tokensPerMerged -gt 0.7 * [double]$base.tokensPerMerged) { $missing.Add('tokens per merged change down 30% from the first week') }
    $tn = if ($score.stages.Contains('tests')) { [double]$score.stages['tests'].avgMin } else { $null }
    $baseTestMin = if ($base -and $base.stages -and $base.stages.tests -and $null -ne $base.stages.tests.avgMin) { [double]$base.stages.tests.avgMin } else { $null }
    if ($null -eq $baseTestMin -or $null -eq $tn) { $missing.Add('test time per change down 40% (no first-week baseline yet)') }
    elseif ($tn -gt 0.6 * $baseTestMin) { $missing.Add('test time per change down 40% from the first week') }
    if ($missing.Count) { $leap = 2 } else {
        if (-not (Get-ChildItem -LiteralPath (Join-Path $root 'run') -Filter '*.activity.jsonl' -ErrorAction SilentlyContinue | Select-Object -First 1)) { $missing.Add('live activity stream') }
        if (-not (Get-ChildItem -LiteralPath $root -Filter '*recap*' -ErrorAction SilentlyContinue | Select-Object -First 1)) { $missing.Add('replay and recap for every order') }
        if (-not (Test-Path -LiteralPath (Join-Path $root 'alerts.jsonl'))) { $missing.Add('push alerts working') }
        if ($missing.Count) { $leap = 3 } else {
            $hunt = @(Get-KitchenJobs $root -WithArchive | Where-Object { $_ -and [string]$_.name -match 'hunt' -and [string]$_.status -eq 'done' })
            if (-not $hunt.Count) { $missing.Add('overnight job-hunt run with tailored packs') }
            if (-not (Get-ChildItem -LiteralPath $root -Filter 'tracker*' -ErrorAction SilentlyContinue | Select-Object -First 1)) { $missing.Add('application tracker follow-ups') }
            if ($missing.Count) { $leap = 4 } else {
                if (-not (Select-String -LiteralPath (Join-Path $root 'ideas.json') -Pattern 'target' -SimpleMatch -Quiet -ErrorAction SilentlyContinue)) { $missing.Add('coach experiments filed with a target number') }
                if ($null -eq $prev -or $score.rate -le [double]$prev.rate) { $missing.Add('rate of evolution rising week over week') }
                $leap = if ($missing.Count) { 5 } else { 6 }
            }
        }
    }
}
$score.leap = [math]::Min($leap, 5); $score.leapName = $leaps[$score.leap - 1]; $score.missing = @($missing)
if ($leap -eq 6) { $score.leapName = $leaps[4] + ' (all exit numbers met)' }
$up = [string][char]0x2191; $down = [string][char]0x2193; $flat = [string][char]0x2192
$score.trend = 'flat'; $score.trendArrow = $flat
if ($prev -and $null -ne $prev.rate) { if ($score.rate -gt [double]$prev.rate) { $score.trend = 'up'; $score.trendArrow = $up } elseif ($score.rate -lt [double]$prev.rate) { $score.trend = 'down'; $score.trendArrow = $down } }
if ($Record) { ($score | ConvertTo-Json -Depth 6 -Compress) | Add-Content -LiteralPath (Join-Path $root 'scoreboard.jsonl') -Encoding utf8 }
if ($Json) { $score | ConvertTo-Json -Depth 6 -Compress; exit 0 }
$fmt = { param($v) if ($null -eq $v) { '-' } else { "$v%" } }
"Pipeline scoreboard, last $Days days: $($score.orders) improve orders, $($score.merged) merged"
"  first try $(& $fmt $score.firstTryPct) · repaired $(& $fmt $score.repairedPct) · set aside $(& $fmt $score.asidePct) · reviewer said ship $(& $fmt $score.shipPct)"
$dash = { param($v) if ($null -eq $v) { '-' } else { "$v" } }
"  evolution rate $($score.rate) $($score.trendArrow) (merged per day x first try x (1 - set aside)) · Leap $($score.leap): $($score.leapName)"
if ($score.missing.Count) { "  missing for the next leap: $($score.missing -join '; ')" }
"  tokens per merged $(& $dash $score.tokensPerMerged) · minutes order to merge $(& $dash $score.minOrderToMerge) · Jordan taps per merged $(& $dash $score.tapsPerMerged) · auto-merged $(& $fmt $score.autoMergedPct) · undone $($score.undone)"
"  runner faults $($score.runnerFaults) (logflood $($faults['logflood']), hung $($faults['hung']), crash-before-summary $($faults['crash-before-summary']), merge conflict $($faults['merge conflict']))"
foreach ($k in $score.stages.Keys) { "  {0,-9} {1,6} min avg   {2,8} tokens   `${3}" -f $k, $score.stages[$k].avgMin, $score.stages[$k].tokens, $score.stages[$k].usd }
if ($score.models.Count) {
    "  per model (first try = orders it planned or built):"
    foreach ($k in $score.models.Keys) { $m = $score.models[$k]; "  {0,-34} {1,3} runs   first try {2,5}   {3,8} tokens/run   {4,5} min avg   `${5}" -f $k, $m.runs, $(& $fmt $m.firstTryPct), $m.tokensPerRun, $m.avgMin, $m.usd }
}
foreach ($c in $score.kinds) { "  kind {0,-9} {1,-34} {2,3} runs   ok {3}%" -f $c.kind, $c.model, $c.runs, $c.okPct }
$bz = $score.brier; $bu = { param($v) if ($null -eq $v) { 'unknown' } else { "$v" } }
if ($bz.claims) {
    "  crew Brier $($bz.value) over $($bz.claims) claims (0 = always right, 1 = always wrong): Inspector said ship $(& $bu $bz.inspector.value) over $($bz.inspector.claims), build crew said tests pass $(& $bu $bz.builder.value) over $($bz.builder.claims); $($bz.pending) kept merges still inside their 7 days"
    "  crew Brier per model: $(@($bz.models.Keys | ForEach-Object { "$_ $($bz.models[$_].value) ($($bz.models[$_].claims))" }) -join ' · ')"
    "  crew Brier per kind: $(@($bz.kinds | ForEach-Object { "$($_.kind) $($_.model) $($_.value) ($($_.claims))" }) -join ' · ')"
} else { "  crew Brier unknown ($($bz.missing))" }
$sv = { param($n) if ($null -ne $std[$n]) { "$($std[$n])" } else { "unknown ($($std.missing[$n]))" } }
"  build standard: broken mains $(& $sv 'brokenMains') · false undos $(& $sv 'falseUndos') · silent failures $(& $sv 'silentFailures') · minutes Floor start to merge $(& $sv 'floorMinutes')$(if ($std.floors) { " over $($std.floors) Floors" })"
