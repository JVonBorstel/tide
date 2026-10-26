# Station: the repair round. If the tests that just ran (.kitchen\TESTS.txt) all passed, nothing happens. Otherwise a cook gets the
# failures and the change, fixes the code, and the change is saved and re-tested; up to -Rounds times. Ends with the tests station's
# own last line ("tests: ALL PASS" or "tests: FAILED: ..."), so the recipe step can require ALL PASS.
# The builder cannot run commands, so this is how it learns what broke before Jordan is ever asked (J21, J28 and J30 were set aside
# over small mistakes a second look would have caught).
#   step: {"station":"repair","ai":true,"args":{"Rounds":2}}   (ai: cook.ps1 hands it the order, the cook choice and privacy like an agent step)
# -Recall (ZG-16, off unless the recipe sets it): before each round stations/lobe-recall.ps1 searches the lobe for past fixes of the same failures
# (bounded, always exit 0, one line in this log); its .kitchen\RECALL.md is attached only when it was written. The prompt words do not change.
param([int]$Rounds = 2, [string]$Order = '', [string]$Supplier = '', [switch]$Private, [switch]$Public, [int]$MaxTurns = 50, [double]$MaxBudgetUsd = 4, [switch]$Recall)
$ErrorActionPreference = 'Stop'
$job = $env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'repair: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$wt = Join-Path $kroot "worktrees\$job"
$results = Join-Path $wt '.kitchen\TESTS.txt'
if (-not (Test-Path -LiteralPath $results)) { Write-Output 'repair: no test results to read (run the tests station first)'; exit 2 }
function Last-Line { (Get-Content -LiteralPath $results -Raw) -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1 }
function Passed { (Last-Line) -eq 'ALL PASS' }
# After a cook round the suites that failed run first, alone (-Only): still red, the round is over at the cost of those suites, not a full
# run (6 of 32 in-repair full runs were still red, ~1,600 s each). Green, the suites the change touches run (-Impacted), and a PARTIAL PASS
# is never a pass: one full run follows (the pre-review run, and the only one that records the job's result). The exit code lands in
# $script:tcode (10 = sandbox not ready). A failed-suites run that wrote no TESTS.txt (the suite was renamed or deleted) goes on to the rest.
function Failed-Suites { @((Get-Content -LiteralPath $results) | Where-Object { $_ -match '^FAIL\s+(Test-\S+)' } | ForEach-Object { $Matches[1] } | Sort-Object -Unique) }
function Run-Tests {
    $redOnes = @(Failed-Suites)
    if ($redOnes.Count) {
        Write-Output "repair: re-running the failed suites first: $($redOnes -join ', ')"
        $before = (Get-Item -LiteralPath $results).LastWriteTimeUtc
        $global:LASTEXITCODE = 0
        & (Join-Path $PSScriptRoot 'tests.ps1') -Soft -Only ($redOnes -join ',')
        $script:tcode = $LASTEXITCODE
        if ($script:tcode -eq 10) { return }
        if ((Get-Item -LiteralPath $results).LastWriteTimeUtc -ne $before -and -not (Passed)) { Write-Output 'repair: the failed suites still fail; no full run this round'; return }
    }
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot 'tests.ps1') -Soft -Impacted
    $script:tcode = $LASTEXITCODE
    if ($script:tcode -ne 10 -and (Last-Line) -like 'PARTIAL PASS*') {
        Write-Output 'repair: the impacted suites pass; running all suites once'
        $global:LASTEXITCODE = 0
        & (Join-Path $PSScriptRoot 'tests.ps1') -Soft
        $script:tcode = $LASTEXITCODE
    }
}
# each cook round gets its share of the step's time, less ~15 minutes for the commit and the test run after it: given the whole limit, one
# slow round let the supervisor stop the step mid-tests, and an unsafe step stopped that way needs Jordan to guess whether to re-run it
$clock = [Diagnostics.Stopwatch]::StartNew()
function Cook-Sec([int]$roundsLeft) { if ([int]$env:KITCHEN_TIMEOUT -le 0) { return 0 }; [math]::Max(300, [int](([int]$env:KITCHEN_TIMEOUT - $clock.Elapsed.TotalSeconds) / [math]::Max(1, $roundsLeft)) - 900) }
$agent = if ($env:KITCHEN_AGENT_STEP) { $env:KITCHEN_AGENT_STEP } else { Join-Path $PSScriptRoot '..\agent-step.ps1' }   # tests may stand in a fake cook
# the reviewer sent the change back (the supervisor wrote its critique): fix what it found, then the tests and the review run again
$critique = Join-Path $wt '.kitchen\CRITIQUE.md'
if (Test-Path -LiteralPath $critique) {
    Write-Output 'repair: rework round (the reviewer sent the change back)'
    $a = @{ Role = 'do'; Mode = 'acceptEdits'; WorkDir = $wt; Tools = 'Read,Grep,Glob,Edit,Write'; MaxTurns = $MaxTurns; MaxBudgetUsd = $MaxBudgetUsd
        Context = '.kitchen\CRITIQUE.md;.kitchen\DIFF.patch'; TimeoutSec = (Cook-Sec ($Rounds + 1))
        Prompt = "You are a line cook addressing a reviewer's findings on this change. You are in a git worktree on its own branch. The plan is in .kitchen/PLAN.md; the reviewer's critique (CRITIQUE.md) and the change so far (DIFF.patch) are attached below.`n`nFix every problem the reviewer names that is real; if a point is wrong, leave the code and say why. Keep the change to its goal, never delete, skip or weaken an existing test, and add a test when the critique shows a gap. You cannot run commands; the tests and the review run again after you. When done, list each point and what you did." }
    if ($Order) { $a.Order = $Order }; if ($Supplier) { $a.Supplier = $Supplier }; if ($Private) { $a.Private = $true } elseif ($Public) { $a.Public = $true }
    $global:LASTEXITCODE = 0
    & $agent @a
    $code = $LASTEXITCODE
    if ($code -in 10, 11) { exit $code }
    Move-Item -LiteralPath $critique -Destination (Join-Path $wt ".kitchen\CRITIQUE.done-$((Get-Date).ToString('HHmmss')).md") -Force   # used once
    if ($code) { Write-Output 'repair: the cook could not finish the rework'; exit 1 }
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot 'commit.ps1') -Message 'rework (the reviewer sent it back)'
    if ($LASTEXITCODE) { Write-Output 'repair: could not save the rework'; exit 1 }
    Run-Tests
    if ($script:tcode -eq 10) { Write-Output 'repair: the tests station is holding (sandbox not ready); nothing was tested'; exit 10 }
    if (Passed) { Write-Output 'repair: reworked; tests pass'; exit 0 }
    Write-Output 'repair: tests fail after the rework; repairing'
}
if (Passed) { Write-Output 'repair: nothing to fix'; Write-Output 'tests: ALL PASS'; exit 0 }
# what broke, kept for the lesson book if the repair works: every later builder reads it (map.ps1 copies it into .kitchen\LESSONS.md)
$broke = @((Get-Content -LiteralPath $results) | Where-Object { $_ -match '^\s+FAIL' -or $_ -match '^FAIL ' } | ForEach-Object { $_.Trim() } | Select-Object -First 6)
for ($n = 1; $n -le $Rounds; $n++) {
    Write-Output "repair: round $n of $Rounds"
    # suites the tests Step stopped at their time limit or memory cap (TD-EH-16): the Crew is told plainly they were slow or too large
    $stopped = @((Get-Content -LiteralPath $results) | Where-Object { $_ -match '^FAIL\s+(Test-\S+)\s+(timed out after \d+ s|stopped at the memory cap \(\d+ MB\))' } | ForEach-Object { "$($Matches[1]) ($($Matches[2]))" })
    $stopNote = if ($stopped.Count) { "`n`nNot every failure is a wrong result: $($stopped -join ', ') did not finish. The tests Step stopped them because they ran too slow, hung, or used too much memory, not because an assertion failed. For those, find what made them slow, stuck or large (a wait that never ends, a loop, a call that never returns, a leak) and fix that." } else { '' }
    $ctxFiles = '.kitchen\TESTS.txt;.kitchen\DIFF.patch'
    if ($Recall) {   # ZG-16: a missing, slow or refused lobe is one line here and the round goes on (90 s cap on the whole search)
        $rb = @('-NoProfile', '-File', (Join-Path $PSScriptRoot '..\..\scripts\run-bounded.ps1'), '-Script', (Join-Path $PSScriptRoot 'lobe-recall.ps1'), '-TimeoutSeconds', '90', '-MaxMB', '2000')
        $rc = -1; try { & (Get-Process -Id $PID).Path @rb @(if ($Private) { '-ScriptArgs', '-Private' }) 2>&1 | ForEach-Object { "$_" }; $rc = $LASTEXITCODE } catch { "recall: not available ($($_.Exception.Message))" }
        if ($rc -eq 0 -and (Test-Path -LiteralPath (Join-Path $wt '.kitchen\RECALL.md'))) { $ctxFiles += ';.kitchen\RECALL.md' } elseif ($rc -gt 0) { "recall: not available (exit $rc); nothing attached" }
    }
    $a = @{ Role = 'do'; Mode = 'acceptEdits'; WorkDir = $wt; Tools = 'Read,Grep,Glob,Edit,Write'; MaxTurns = $MaxTurns; MaxBudgetUsd = $MaxBudgetUsd
        Context = $ctxFiles; TimeoutSec = (Cook-Sec ($Rounds - $n + 1))
        Prompt = "You are a line cook repairing a change in this repository that failed its tests (round $n of $Rounds). You are in a git worktree on its own branch. The plan is in .kitchen/PLAN.md; the change so far (DIFF.patch) and the test results (TESTS.txt, failing suites with their error lines) are attached below.`n`nFind the cause of each failure by reading the failing test and the code it exercises, then fix it. Usually the new code is wrong; if a test this change added is itself wrong, fix that test. Never delete, skip or weaken a test that existed before this change, and do not touch anything unrelated. Watch for PowerShell traps: variable names are case-insensitive (`$json and a -Json switch are the same variable), `"`$name?`" reads a variable named 'name?' (write `${name}?), a backtick escapes the next character inside double quotes, and [string] of an empty pipeline is `$null. You cannot run commands; the tests run again after you. When done, list each failure and what you changed for it.$stopNote" }
    if ($Order) { $a.Order = $Order }; if ($Supplier) { $a.Supplier = $Supplier }; if ($Private) { $a.Private = $true } elseif ($Public) { $a.Public = $true }
    $global:LASTEXITCODE = 0
    & $agent @a
    $code = $LASTEXITCODE
    if ($code -in 10, 11) { exit $code }   # held for Jordan / no cook free: the supervisor handles it like any AI step
    if ($code) { Write-Output "repair: the cook could not finish round $n"; break }
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot 'commit.ps1') -Message "repair round $n (tests had failed)"
    if ($LASTEXITCODE) { Write-Output 'repair: could not save the fix'; exit 1 }
    Run-Tests
    if ($script:tcode -eq 10) { Write-Output 'repair: the tests station is holding (sandbox not ready); nothing was tested'; exit 10 }
    if (Passed) {
        try { @{ at = (Get-Date).ToUniversalTime().ToString('o'); job = $job; round = $n; broke = $broke } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $kroot 'lessons.jsonl') -Encoding utf8 } catch { }
        Write-Output "repair: fixed in round $n"; exit 0
    }
}
Write-Output "repair: still failing after the repair rounds"
exit 1
