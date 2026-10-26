# Tests for ZG-22, crew Brier on the scoreboard (kitchen/scoreboard.ps1): an Inspector's "VERDICT: SHIP" and a build crew's "tests pass"
# line are claims scored against what happened (kept, undone within 7 days, red on verify; the tests Step's first run), per model and kind,
# and the build standard's four numbers print beside it or say 'unknown' with the missing source. A FIXTURE kitchen in TEMP only (6 work
# orders: 3 kept, 2 undone, 1 red verify; 3 Floors); never Jordan's live kitchen. Run by the tests station (tests\Test-*.ps1). Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-crewbrier-' + [guid]::NewGuid().ToString('N'))
$empty = "$root-empty"
$save = $env:BRAIN_KITCHEN
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Score([string]$Kitchen, [switch]$Text) {
    $env:BRAIN_KITCHEN = $Kitchen
    if ($Text) { return (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Days 30 | Out-String) }
    (& pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Days 30 -Json | Out-String) | ConvertFrom-Json
}
function Put([string]$rel, [string]$text) { Set-Content -LiteralPath (Join-Path $root $rel) -Value $text -Encoding utf8 }
function Lines([string]$rel, [object[]]$items) { $items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } | Set-Content -LiteralPath (Join-Path $root $rel) -Encoding utf8 }
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'jobs'), (Join-Path $root 'run'), $empty | Out-Null
    $now = [DateTime]::UtcNow
    $iso = { param([double]$days) $now.AddDays($days).ToString('o') }
    # improve line: 0 worktree, 1 plan, 2 build, 3 tests, 4 repair, 5 review (Inspector), 6 merge, 7 verify
    $steps = @(@{ script = 'x\worktree.ps1' }, @{ script = 'x\agent-step.ps1'; args = @{ Role = 'plan' } }, @{ script = 'x\agent-step.ps1'; args = @{ Role = 'do' } },
        @{ script = 'x\tests.ps1' }, @{ script = 'x\repair.ps1' }, @{ script = 'x\agent-step.ps1'; args = @{ Role = 'check' } }, @{ script = 'x\merge.ps1' }, @{ script = 'x\verify.ps1' })
    $mk = { param($id, $status, $created, $name = "improve: thing $id", $recipe = 'improve') @{ id = $id; name = $name; recipe = $recipe; status = $status; created = $created; cursor = 7; steps = $steps } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$id.json") }
    # J1-J3 kept (J2 undone only 9 days after its merge; J3 merged yesterday, still inside its 7 days), J4-J5 undone, J6 red on verify
    & $mk 'J1' 'done' (& $iso -20); & $mk 'J2' 'done' (& $iso -20); & $mk 'J3' 'done' (& $iso -2)
    & $mk 'J4' 'failed' (& $iso -20); & $mk 'J5' 'failed' (& $iso -20); & $mk 'J6' 'failed' (& $iso -20)
    # Floors (roadmap-item): J7 merged 90 min after its start, J8 30 min after, J9 not merged; never counted as improve orders
    & $mk 'J7' 'done' (& $iso -3) 'roadmap-item: ZG-1' 'roadmap-item'; & $mk 'J8' 'done' (& $iso -2) 'roadmap-item: ZG-2' 'roadmap-item'; & $mk 'J9' 'running' (& $iso -1) 'roadmap-item: ZG-3' 'roadmap-item'
    foreach ($id in 'J1', 'J2', 'J3', 'J4', 'J5', 'J6') { Put "run\$id-s5-a0.dish.md" "# In plain words`nok`nVERDICT: SHIP - checked the diff and the tests" }
    # build crew lines: J1 and J2 claim the tests pass (they did), J4 claims it (they did not); J5 says it could not run them, J6 only
    # has the tests Step's own line, J3 lists files: no claim
    Put 'run\J1-s2-a0.log' "Changed kitchen/a.ps1 to fix the count.`nAll tests should pass now."
    Put 'run\J2-s2-a0.log' "Edited b.ps1.`nThe suites are green with this change."
    Put 'run\J3-s2-a0.log' "Changed c.ps1 because the plan said so."
    Put 'run\J4-s2-a0.log' "Tests pass with this change."
    Put 'run\J5-s2-a0.log' "The tests should pass, but I could not run them."
    Put 'run\J6-s2-a0.log' "tests: ALL PASS"
    foreach ($id in 'J1', 'J2', 'J3', 'J5', 'J6') { Put "run\$id-s3-a0.log" "tests: PASS  Test-A`ntests: ALL PASS" }
    Put 'run\J4-s3-a0.log' "tests: FAIL  Test-A`ntests: FAILED: Test-A"
    $ev = [Collections.Generic.List[object]]::new()
    foreach ($id in 'J1', 'J2', 'J3') { $ev.Add(@{ ts = (& $iso -3); type = 'cost'; job = $id; step = 5; supplier = 'claude'; model = 'sonnet'; usd = 0.1; inputTokens = 10; outputTokens = 10 }); $ev.Add(@{ ts = (& $iso -3); type = 'cook'; job = $id; step = 5; supplier = 'claude'; model = 'sonnet'; kind = 'review'; ok = $true }) }
    foreach ($id in 'J4', 'J5', 'J6') { $ev.Add(@{ ts = (& $iso -3); type = 'cost'; job = $id; step = 5; supplier = 'gemini'; model = 'gemini-4-argon-high'; usd = 0.1; inputTokens = 10; outputTokens = 10 }); $ev.Add(@{ ts = (& $iso -3); type = 'cook'; job = $id; step = 5; supplier = 'gemini'; model = 'gemini-4-argon-high'; kind = 'review'; ok = $true }) }
    foreach ($id in 'J1', 'J2', 'J4') { $ev.Add(@{ ts = (& $iso -3); type = 'cost'; job = $id; step = 2; supplier = 'local'; model = 'qwen3.5:9b'; usd = 0; inputTokens = 10; outputTokens = 10 }); $ev.Add(@{ ts = (& $iso -3); type = 'cook'; job = $id; step = 2; supplier = 'local'; model = 'qwen3.5:9b'; kind = 'code'; ok = $true }) }
    $ev.Add(@{ ts = (& $iso -1); type = 'job.done'; job = 'J3' })
    $ev.Add(@{ ts = (& $iso -6); type = 'merge.undone'; job = 'J5'; suites = @('Test-A'); why = 'broke main (Test-A)'; preMergeSha = 'a' * 40 })
    $ev.Add(@{ ts = (& $iso -5); type = 'merge.broken'; job = 'J6'; suites = @('Test-A'); why = 'broke main (Test-A)'; undo = 'could not reverse' })
    $ev.Add(@{ ts = (& $iso -40); type = 'main.status'; tower = 't'; state = 'red'; job = 'J0' })
    $ev.Add(@{ ts = (& $iso -5); type = 'main.status'; tower = 't'; state = 'red'; job = 'J6' })
    $ev.Add(@{ ts = (& $iso -4); type = 'main.status'; tower = 't'; state = 'green'; job = 'J6' })
    $f7 = $now.AddDays(-3); $f8 = $now.AddDays(-2)
    $ev.Add(@{ ts = $f7.AddMinutes(90).ToString('o'); type = 'step.done'; job = 'J7'; step = 6 }); $ev.Add(@{ ts = $f7.AddMinutes(200).ToString('o'); type = 'job.done'; job = 'J7' })
    $ev.Add(@{ ts = $f8.AddMinutes(30).ToString('o'); type = 'job.done'; job = 'J8' })
    Lines 'events.jsonl' $ev
    # the Floors' created times must be exact for the minutes: rewrite them from the same clock
    & $mk 'J7' 'done' $f7.ToString('o') 'roadmap-item: ZG-1' 'roadmap-item'; & $mk 'J8' 'done' $f8.ToString('o') 'roadmap-item: ZG-2' 'roadmap-item'
    Lines 'automerged.jsonl' @(
        @{ at = (& $iso -15); job = 'J1'; name = 'improve: thing J1'; why = 'tests all pass' },
        @{ at = (& $iso -12); job = 'J2'; name = 'improve: thing J2'; why = 'tests all pass' },
        @{ at = (& $iso -3); job = 'J2'; undone = 'b' * 40; why = 'asked by Jordan' },
        @{ at = (& $iso -10); job = 'J4'; name = 'improve: thing J4'; why = 'tests all pass' },
        @{ at = (& $iso -9); job = 'J4'; undone = 'c' * 40 },
        @{ at = (& $iso -6); job = 'J5'; undone = 'unknown'; type = 'merge.undone'; why = 'broke main (Test-A)' },
        @{ at = (& $iso -4); job = 'J1'; type = 'automerge.pause'; why = 'passed only on a retry (Test-B)' })

    $s = Score $root
    Check 'ZG22-3 the fixture: 6 improve orders, Floors not counted as orders' ($s.orders -eq 6)
    Check 'ZG22-1 Inspector Brier: 6 SHIP claims, 3 kept and 3 wrong = 0.50' ($s.brier.inspector.claims -eq 6 -and [math]::Round($s.brier.inspector.value, 2) -eq 0.50)
    Check 'ZG22-1 build crew Brier: 3 tests-pass lines (J1, J2 right, J4 wrong) = 0.33; "could not run" and a "tests:" line are not claims' ($s.brier.builder.claims -eq 3 -and [math]::Round($s.brier.builder.value, 2) -eq 0.33)
    Check 'ZG22-1 crew Brier over all 9 claims = 0.44' ($s.brier.claims -eq 9 -and [math]::Round($s.brier.value, 2) -eq 0.44)
    Check 'ZG22-1 an undo 9 days after the merge does not count against the Inspector; J3 merged yesterday is pending' ($s.brier.pending -eq 1)
    $mc = $s.models.'claude/sonnet'; $mg = $s.models.'gemini/gemini-4-argon-high'; $ml = $s.models.'local/qwen3.5:9b'
    Check 'ZG22-1 per model, next to firstTryPct: sonnet 0.00 (3), argon 1.00 (3), qwen 0.33 (3)' ($mc.brier -eq 0 -and $mc.brierClaims -eq 3 -and $mg.brier -eq 1 -and $mg.brierClaims -eq 3 -and [math]::Round($ml.brier, 2) -eq 0.33 -and $ml.brierClaims -eq 3 -and $mc.PSObject.Properties.Name -contains 'firstTryPct')
    $kr = @($s.kinds | Where-Object { $_.kind -eq 'review' -and $_.model -eq 'gemini/gemini-4-argon-high' }); $kc = @($s.kinds | Where-Object { $_.kind -eq 'code' })
    Check 'ZG22-1 per kind and model: review argon 1.00 (3), code qwen 0.33 (3)' ($kr.Count -eq 1 -and $kr[0].brier -eq 1 -and $kr[0].brierClaims -eq 3 -and $kc.Count -eq 1 -and [math]::Round($kc[0].brier, 2) -eq 0.33)
    Check 'ZG22-1 brier.models and brier.kinds carry the same numbers' ([math]::Round($s.brier.models.'local/qwen3.5:9b'.value, 2) -eq 0.33 -and @($s.brier.kinds).Count -eq 3)
    $sd = $s.standard
    Check 'ZG22-2 broken mains: 1 red main.status event in the window (the one 40 days ago is outside)' ($sd.brokenMains -eq 1)
    Check 'ZG22-2 false undos: 0 when every undo in the window carries the blame check (preMergeSha)' ($sd.falseUndos -eq 0)
    Check 'ZG22-2 silent failures: unknown, the missing source named' ($null -eq $sd.silentFailures -and $sd.missing.silentFailures -match 'Board')
    Check 'ZG22-2 minutes from Floor start to merge: (90 + 30) / 2 = 60 over 2 Floors (merge step, else job.done)' ($sd.floorMinutes -eq 60 -and $sd.floors -eq 2)
    $t = Score $root -Text
    Check 'ZG22-2 plain report: crew Brier line and the build standard beside it' ($t -match 'crew Brier 0\.44 over 9 claims' -and $t -match 'Inspector said ship 0\.5 over 6' -and $t -match 'build crew said tests pass 0\.33 over 3' -and $t -match 'build standard: broken mains 1 · false undos 0 · silent failures unknown \(nothing records' -and $t -match 'minutes Floor start to merge 60 over 2 Floors')
    Check 'ZG22-1 plain report: per model and per kind' ($t -match 'crew Brier per model: .*gemini/gemini-4-argon-high 1 \(3\)' -and $t -match 'crew Brier per kind: .*code local/qwen3\.5:9b 0\.33 \(3\)')

    # an undo with no blame check: false undos are unknown, and say why
    $ev.Add(@{ ts = (& $iso -2); type = 'merge.undone'; job = 'J99'; suites = @('Test-B'); why = 'broke main (Test-B)' }); Lines 'events.jsonl' $ev
    $s2 = Score $root
    Check 'ZG22-2 false undos: unknown when an undo has no preMergeSha, the source named' ($null -eq $s2.standard.falseUndos -and $s2.standard.missing.falseUndos -match '1 of 2 merge\.undone events in events\.jsonl have no preMergeSha')
    Check 'an undo of an order outside the window changes no crew claim' ($s2.brier.claims -eq 9)

    # -Record writes the Brier and the standard to scoreboard.jsonl
    $env:BRAIN_KITCHEN = $root
    & pwsh -NoProfile -File (Join-Path $kd 'scoreboard.ps1') -Days 30 -Record | Out-Null
    $rec = (Get-Content (Join-Path $root 'scoreboard.jsonl') -Raw) | ConvertFrom-Json
    Check 'ZG22-1 -Record writes brier (with per model) and the standard to scoreboard.jsonl' ([math]::Round($rec.brier.value, 2) -eq 0.44 -and $rec.brier.models.'claude/sonnet'.claims -eq 3 -and $rec.standard.brokenMains -eq 1)

    # an empty kitchen: nothing guessed, every number unknown with its source
    $e = Score $empty
    Check 'empty kitchen: crew Brier null, says what is missing' ($null -eq $e.brier.value -and $e.brier.claims -eq 0 -and $e.brier.missing -match 'no Inspector SHIP')
    Check 'empty kitchen: all four build-standard numbers unknown, each with its source' ($null -eq $e.standard.brokenMains -and $e.standard.missing.brokenMains -match 'events\.jsonl is missing' -and $null -eq $e.standard.falseUndos -and $e.standard.missing.falseUndos -match 'events\.jsonl' -and $null -eq $e.standard.floorMinutes -and $e.standard.missing.floorMinutes -match 'roadmap-item' -and $null -eq $e.standard.silentFailures)
    $et = Score $empty -Text
    Check 'empty kitchen: plain report says unknown, never a number' ($et -match 'crew Brier unknown \(no Inspector SHIP' -and $et -match 'broken mains unknown \(events\.jsonl is missing\)' -and $et -match 'minutes Floor start to merge unknown \(no merged roadmap-item')

    # the change note drafts the Dispatcher rule and says routing is not changed here
    $note = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\docs\changes\ZG-22.md') -Raw
    Check 'ZG22-3 the change note drafts the one-line rule (brier > 0.25 over at least 4, beside demoteBelow) and leaves routing alone' ($note -match '"demoteBrierAbove": 0\.25' -and $note -match 'demoteBelow' -and $note -match '(?i)at least 4' -and $note -match '(?i)routing is not changed')
} finally {
    $env:BRAIN_KITCHEN = $save
    Remove-Item -LiteralPath $root, $empty -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "CrewBrier tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
