# Tests for the verify station's cache (kitchen/stations/verify.ps1): hit, miss on a changed tree, miss on a changed test file, fail not cached;
# and its blame check (TD-EH-01): a red suite is run on the commit before the merge; red there too = main was already red (nothing undone,
# verify.main-red event, the job file marked, one HIGH alert, held); green there = the merge is to blame (undone as before); the parent is the
# order's own merge's (later work on top changes nothing); no parent or no time = the check cannot run and verify fails closed as before.
# Run by the kitchen tests station (tests\Test-*.ps1) and by hand; uses a copied verify station with a scripted tests station. Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-vcache-' + [guid]::NewGuid().ToString('N'))
$save = @{ BRAIN_KITCHEN = $env:BRAIN_KITCHEN; KITCHEN_JOB = $env:KITCHEN_JOB; KITCHEN_TIMEOUT = $env:KITCHEN_TIMEOUT; VC_RUNLOG = $env:VC_RUNLOG; VC_FAIL = $env:VC_FAIL
    BRAIN_NTFY_TOPIC = $env:BRAIN_NTFY_TOPIC; KITCHEN_NOTIFY_LOG = $env:KITCHEN_NOTIFY_LOG; KITCHEN_GITHUB_REMOTE = $env:KITCHEN_GITHUB_REMOTE; VC_FLAKY = $env:VC_FLAKY }
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$repo = Join-Path $root 'repo'; $state = Join-Path $root 'state'; $st = Join-Path $root 'kitchen\stations'
function G { & git -C $repo -c user.name=t -c user.email=t@localhost -c core.autocrlf=false @args 2>&1 | Out-Null }
$runLog = Join-Path $root 'runs.log'; $notifyLog = Join-Path $root 'notify.log'
function Runs { if (Test-Path $runLog) { @(Get-Content $runLog).Count } else { 0 } }
function RunLines { if (Test-Path $runLog) { @(Get-Content $runLog) } else { @() } }
function Verify([string]$jobId = 'J1', [string]$r = $repo) { $env:KITCHEN_JOB = $jobId; $o = & pwsh -NoProfile -File (Join-Path $st 'verify.ps1') -Repo $r -Job $jobId 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }
function Events([string]$type) { @(Get-Content (Join-Path $state 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.type -eq $type }) }
function Notifies { if (Test-Path $notifyLog) { @(Get-Content $notifyLog) } else { @() } }
. (Join-Path $kd 'train.ps1'); function Hold-Train($jid) { @{ job = $jid; at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress | Set-Content (Get-TrainPath $state $repo) }
function Train-Holder { $p = Get-TrainPath $state $repo; if (Test-Path $p) { (Get-Content $p -Raw | ConvertFrom-Json).job } else { '' } }
try {
    New-Item -ItemType Directory -Force -Path $st, $state, "$state\jobs", "$repo\tests" | Out-Null
    # verify.ps1 dot-sources ..\train.ps1 (W2, #60) and ..\repo-config.ps1, runs ..\undo-merge.ps1 (which dot-sources ..\github-lib.ps1),
    # alerts through ..\notify.ps1 and records main's status through ..\main-status.ps1 (TD-EH-03a): all six go next to the copied station
    Copy-Item (Join-Path $kd 'stations\verify.ps1') $st
    Copy-Item (Join-Path $kd 'repo-config.ps1'), (Join-Path $kd 'train.ps1'), (Join-Path $kd 'undo-merge.ps1'), (Join-Path $kd 'github-lib.ps1'), (Join-Path $kd 'notify.ps1'), (Join-Path $kd 'main-status.ps1') (Join-Path $root 'kitchen')
    # the scripted tests station: logs each run with the folder's state; a red.txt in the folder it is given (HEAD, or the commit before the
    # merge in the blame check) or VC_FAIL=1 (red everywhere) makes it report a failed suite, with its why line and why record (as TD-EH-02's)
    Set-Content (Join-Path $st 'tests.ps1') @'
param([string]$Dir, [string]$ChangedFiles, [string]$Glob, [string]$Skip, [string[]]$Only, [int]$SuiteTimeoutSec, [int]$MaxMB)
$red = Test-Path (Join-Path $Dir 'red.txt')
Add-Content -LiteralPath $env:VC_RUNLOG -Value "run only=$($Only -join ',') red=$red"
if ($env:VC_FAIL -eq '1' -or $red) {
    $rn = "results\nojob.tests-why-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"; New-Item -ItemType Directory -Force (Join-Path $env:BRAIN_KITCHEN 'results') | Out-Null
    @{ suites = @(@{ suite = 'Test-A'; code = 1; summary = '0 passed, 1 failed'; why = @('FAIL: app.txt is not v1') }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $env:BRAIN_KITCHEN $rn)
    'tests: FAIL Test-A'; 'tests:       FAIL: app.txt is not v1'; "tests: why: $rn"; 'FAILED: Test-A'; exit 1
}
if ($env:VC_FLAKY) { "tests: PASS $($env:VC_FLAKY) RESULT note: flaky (passed on its retry)"; 'ALL PASS'; exit 0 }
'tests: PASS Test-A'; 'ALL PASS'; exit 0
'@
    . (Join-Path $kd 'main-status.ps1')   # to read what verify recorded (and, at the end, its own checks in-process)
    function MainStatus([string]$r = $repo) { Read-MainStatus $state $r }
    $env:BRAIN_KITCHEN = $state; $env:KITCHEN_JOB = 'J1'; $env:KITCHEN_TIMEOUT = $null; $env:VC_RUNLOG = $runLog; $env:VC_FAIL = '0'
    $env:BRAIN_NTFY_TOPIC = 'test-topic-12345'; $env:KITCHEN_NOTIFY_LOG = $notifyLog
    Set-Content "$repo\tests\Test-A.ps1" "'A: 1 passed, 0 failed'"; Set-Content "$repo\app.txt" 'v1'
    & git -C $repo init -q -b main 2>&1 | Out-Null; G add -A; G commit -q -m init

    $r1 = Verify
    Check 'first verify runs the tests and passes' ($r1.Code -eq 0 -and (Runs) -eq 1 -and $r1.Out -notmatch 'cache hit')
    Check 'a clean pass is stored in <kitchen>\verify-cache' (@(Get-ChildItem (Join-Path $state 'verify-cache') -Filter '*.json').Count -eq 1)
    # main status (TD-EH-03a): a pass records the Tower's main green, at the commit checked, in <kitchen>\main-status\<sha12 of the path>.json
    $ms1 = MainStatus; $head1 = (& git -C $repo rev-parse HEAD)
    Check 'main status: a pass records main green with the sha checked, the order and no suites' ($ms1.state -eq 'green' -and $ms1.sha -eq $head1 -and $ms1.tower -eq 'repo' -and $ms1.job -eq 'J1' -and -not @($ms1.suites).Count -and $r1.Out -match 'verify: main status of repo recorded: green')
    Check 'main status: one file per Tower, named by the same key as its merge train' ((Test-Path (Join-Path $state "main-status\$((Split-Path -Leaf (Get-TrainPath $state $repo)) -replace '^merge-train-', '')")) -and @(Get-ChildItem (Join-Path $state 'main-status')).Count -eq 1)
    Check 'main status: the first record is a main.status event' (@(Events 'main.status').Count -eq 1 -and (Events 'main.status')[0].state -eq 'green')
    $r2 = Verify
    Check 'hit: same tree and tests are not re-run, says cache hit <key> (tested <time>)' ($r2.Code -eq 0 -and (Runs) -eq 1 -and $r2.Out -match 'verify: cache hit [0-9a-f]{32} \(tested \d{4}-\d\d-\d\dT')
    Check 'hit: logged as verify.cached' ((Get-Content (Join-Path $state 'events.jsonl') -Raw) -match '"type":"verify.cached"')
    $ms2 = MainStatus
    Check 'main status: a cache hit is a check too (green, newer at, since kept, no new event)' ($ms2.state -eq 'green' -and $ms2.note -eq 'cached pass' -and [string]$ms2.since -eq [string]$ms1.since -and [string]$ms2.at -ge [string]$ms1.at -and @(Events 'main.status').Count -eq 1)

    Set-Content "$repo\app.txt" 'v2'; G add -A; G commit -q -m change
    $r3 = Verify
    Check 'miss on a changed tree: the tests run again' ($r3.Code -eq 0 -and (Runs) -eq 2 -and $r3.Out -notmatch 'cache hit')

    Set-Content "$repo\tests\Test-B.ps1" "'B: 1 passed, 0 failed'"   # not committed: same tree, different test files
    $r4 = Verify
    Check 'miss on a changed test file: the tests run again' ($r4.Code -eq 0 -and (Runs) -eq 3 -and $r4.Out -notmatch 'cache hit')

    # main already red (10-23: a hand merge broke a suite at 06:20, and the next two orders were undone for it): the suite is red on HEAD and
    # on the commit before it, so nothing is undone, the order is held and marked, main's redness is recorded once
    Set-Content "$repo\app.txt" 'v3'; G add -A; G commit -q -m breaks; $env:VC_FAIL = '1'
    @{ id = 'J1'; name = 'order J1'; status = 'running'; cursor = 1; steps = @(@{ script = 'merge.ps1'; args = @{ Repo = $repo } }, @{ script = 'verify.ps1'; args = @{ Repo = $repo } }) } | ConvertTo-Json -Depth 5 | Set-Content "$state\jobs\J1.json"
    Hold-Train 'J1'; $before = Runs; $headBefore = (& git -C $repo rev-parse HEAD); $parentSha = (& git -C $repo rev-parse 'HEAD^1')
    $r5 = Verify
    Check 'main already red: held for Jordan (exit 10), says main was already red before J1 and nothing undone' ($r5.Code -eq 10 -and $r5.Out -match 'verify: main was already red before J1 \(Test-A' -and $r5.Out -match 'nothing undone' -and $r5.Out -notmatch 'FAILED - broke main')
    Check 'main already red: no undo was run, main keeps the merge' ($r5.Out -notmatch 'undo-merge' -and (& git -C $repo rev-parse HEAD) -eq $headBefore -and (& git -C $repo log -1 --format=%s) -eq 'breaks')
    Check 'main already red: only the red suite was re-run on main, then once on the commit before the merge (HEAD^1)' ((Runs) -eq $before + 3 -and @(RunLines)[-1] -eq 'run only=Test-A red=False' -and @(RunLines)[-2] -eq 'run only=Test-A red=False' -and @(RunLines)[-3] -eq 'run only= red=False')
    $mr = Events 'verify.main-red'
    Check 'main already red: one verify.main-red event with the suites and the pre-merge sha' ($mr.Count -eq 1 -and $mr[0].job -eq 'J1' -and @($mr[0].suites) -contains 'Test-A' -and $mr[0].preMergeSha -eq $parentSha -and $mr[0].sha -eq $headBefore -and $mr[0].why -match 'not this order')
    $j1 = Get-Content "$state\jobs\J1.json" -Raw | ConvertFrom-Json
    Check 'main already red: the job file says so (mainRed: why, suites, preMergeSha), everything else kept' ($j1.mainRed.why -eq "main was already red, not this order's fault" -and @($j1.mainRed.suites) -contains 'Test-A' -and $j1.mainRed.preMergeSha -eq $parentSha -and $j1.status -eq 'running' -and $j1.cursor -eq 1 -and @($j1.steps).Count -eq 2)
    Check 'main already red: one HIGH alert with a plain reason, nothing else leaves this PC' (@(Notifies).Count -eq 1 -and @(Notifies)[0] -eq 'HIGH|test-topic-12345|J1 merged onto a main that was already red; nothing undone, needs a look')
    Check 'main already red: no merge.undone event, nothing in automerged.jsonl' (-not @(Events 'merge.undone').Count -and -not (Test-Path (Join-Path $state 'automerged.jsonl')))
    Check 'main already red: the merge train is let go' (-not (Train-Holder))
    # main status turns red: suites, the plain reason from the tests station's why record, since when, the sha checked, the record's name
    $ms5 = MainStatus
    Check 'main status: red, with the suites, the sha checked and the order' ($ms5.state -eq 'red' -and @($ms5.suites) -join ',' -eq 'Test-A' -and $ms5.sha -eq $headBefore -and $ms5.job -eq 'J1')
    Check 'main status: red says why in plain words (from the why record) and that main was red before the order merged' ($ms5.why -eq 'red before Work order WO-0001 merged; Test-A: FAIL: app.txt is not v1' -and $ms5.record -match '^results\\nojob\.tests-why-[0-9a-f]{8}\.json$')
    Check 'main status: red since this check (a new state), said in the step log' ([string]$ms5.since -eq [string]$ms5.at -and [string]$ms5.since -gt [string]$ms2.since -and $r5.Out -match 'verify: main status of repo recorded: red since \S+ \(Test-A\)')
    Check 'main status: green to red is a main.status event naming the suites' (@(Events 'main.status').Count -eq 2 -and (Events 'main.status')[1].state -eq 'red' -and @((Events 'main.status')[1].suites) -contains 'Test-A' -and (Events 'main.status')[1].tower -eq 'repo')
    $before = Runs; $env:VC_FAIL = '0'
    $r6 = Verify
    Check 'fail not cached: the same tree runs in full next time' ($r6.Code -eq 0 -and (Runs) -eq $before + 1 -and $r6.Out -notmatch 'cache hit')
    $ms6 = MainStatus
    Check 'main status: red back to green on the next pass (no suites, no why, a new since) and a main.status event' ($ms6.state -eq 'green' -and -not @($ms6.suites).Count -and -not $ms6.why -and [string]$ms6.since -gt [string]$ms5.since -and @(Events 'main.status').Count -eq 3 -and (Events 'main.status')[2].state -eq 'green')

    # the merge is to blame: the suite is red on HEAD (the merge adds red.txt) and green on the commit before it, so the merge is undone as before
    G checkout -q -b kitchen/J2; Set-Content "$repo\red.txt" 'breaks the suite'; G add -A; G commit -q -m 'red'
    G checkout -q main; G merge -q --no-ff kitchen/J2 -m 'Merge kitchen/J2 (kitchen J2, approved by Jordan)'
    $mergeSha = (& git -C $repo rev-parse HEAD); $parentSha = (& git -C $repo rev-parse 'HEAD^1')
    Hold-Train 'J2'; $before = Runs; $notifiesBefore = @(Notifies).Count
    $r7 = Verify 'J2'
    Check 'merge to blame: verify fails (exit 1), says the suite passes before the merge and fails after it' ($r7.Code -eq 1 -and $r7.Out -match "verify: Test-A pass on $($parentSha.Substring(0, 12)) .* this merge is to blame" -and $r7.Out -match 'verify: FAILED - broke main \(Test-A\)')
    Check 'merge to blame: the red suite ran on main again, then on the commit before the merge, where red.txt is not there' ((Runs) -eq $before + 3 -and @(RunLines)[-1] -eq 'run only=Test-A red=False' -and @(RunLines)[-2] -eq 'run only=Test-A red=True')
    Check 'merge to blame: undone as before (an Undo commit on main, red.txt gone)' ((& git -C $repo log -1 --format=%s) -match '^Undo J2 \(reverts its merge' -and -not (Test-Path "$repo\red.txt") -and (& git -C $repo rev-parse 'HEAD^1') -eq $mergeSha)
    $un = Events 'merge.undone'
    Check 'merge to blame: merge.undone event with the suites, no verify.main-red for J2' ($un.Count -eq 1 -and $un[0].job -eq 'J2' -and @($un[0].suites) -contains 'Test-A' -and $un[0].why -eq 'broke main (Test-A)' -and -not @(Events 'verify.main-red' | Where-Object { $_.job -eq 'J2' }).Count)
    Check 'merge to blame: Jordan alerted as before, the train let go' (@(Notifies).Count -eq $notifiesBefore + 1 -and @(Notifies)[-1] -eq 'HIGH|test-topic-12345|J2 was undone: it broke main' -and -not (Train-Holder))
    Check 'merge to blame: no job file for J2, said plainly, nothing else marked' (-not (Test-Path "$state\jobs\J2.json") -and $r7.Out -notmatch 'to mark' -and ((Get-Content "$state\jobs\J1.json" -Raw | ConvertFrom-Json).mainRed.preMergeSha -ne $parentSha))
    $ms7 = MainStatus
    Check 'main status: an undo puts main back to before the merge, so the status is left as it was (green), and the log says so' ($ms7.state -eq 'green' -and [string]$ms7.at -eq [string]$ms6.at -and $r7.Out -match 'main status left as it was')
    Check 'merge to blame: the throwaway worktree of the parent is gone' (-not @(& git -C $repo worktree list | Where-Object { $_ -match 'verify-parent' }).Count -and -not @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'verify-parent-J2-*' -ErrorAction SilentlyContinue).Count)

    # later work on top of the merge: the blame check compares with the commit before this order's own merge, not with HEAD^1 (which holds the merge)
    G checkout -q -b kitchen/J4; Set-Content "$repo\red.txt" 'breaks the suite again'; G add -A; G commit -q -m 'red again'
    G checkout -q main; G merge -q --no-ff kitchen/J4 -m 'Merge kitchen/J4 (kitchen J4, approved by Jordan)'
    $preJ4 = (& git -C $repo rev-parse 'HEAD^1'); Set-Content "$repo\later.txt" 'later work'; G add -A; G commit -q -m 'later work'
    $r9 = Verify 'J4'
    Check 'later work on top: compared with the merge''s own parent (green there), so J4 is to blame and undone' ($r9.Code -eq 1 -and $r9.Out -match "verify: Test-A pass on $($preJ4.Substring(0, 12)) " -and (& git -C $repo log -1 --format=%s) -match '^Undo J4 ' -and -not (Test-Path "$repo\red.txt") -and (Test-Path "$repo\later.txt"))
    Check 'later work on top: no verify.main-red for J4' (-not @(Events 'verify.main-red' | Where-Object { $_.job -eq 'J4' }).Count -and @(Events 'merge.undone' | Where-Object { $_.job -eq 'J4' -and $_.preMergeSha -eq $preJ4 }).Count -eq 1)

    # the check needs proof to spare a merge. No time left before the step's limit: it does not run, and verify fails closed as before (undone)
    G checkout -q -b kitchen/J5; Set-Content "$repo\red.txt" 'breaks it, late'; G add -A; G commit -q -m 'red late'
    G checkout -q main; G merge -q --no-ff kitchen/J5 -m 'Merge kitchen/J5 (kitchen J5, approved by Jordan)'
    $before = Runs; $env:KITCHEN_TIMEOUT = '600'
    try { $r10 = Verify 'J5' } finally { $env:KITCHEN_TIMEOUT = $null }
    Check 'no time left: the check does not run, says so, and the merge is undone as before' ($r10.Code -eq 1 -and $r10.Out -match "the blame check could not run \(no time left" -and $r10.Out -match 'counted as broken' -and (Runs) -eq $before + 1 -and (& git -C $repo log -1 --format=%s) -match '^Undo J5 ')

    # TD-EH-25: main was past its last verified tree when the order merged (merge.json pastVerified > 0, or null = unknown): the blame check is
    # mandatory. When it cannot decide (here: no time left), nothing is undone; held for the Owner (exit 10), said, a verify.blame-unknown event
    New-Item -ItemType Directory -Force "$state\results" | Out-Null
    foreach ($case in @(@('J11', 3), @('J12', $null))) {
        $jid, $gap = $case
        G checkout -q -b "kitchen/$jid"; Set-Content "$repo\red.txt" "breaks it ($jid)"; G add -A; G commit -q -m "red $jid"
        G checkout -q main; G merge -q --no-ff "kitchen/$jid" -m "Merge kitchen/$jid (kitchen $jid, approved by Jordan)"
        [ordered]@{ job = $jid; before = (& git -C $repo rev-parse 'HEAD^1'); after = (& git -C $repo rev-parse HEAD); pastVerified = $gap } | ConvertTo-Json | Set-Content "$state\results\$jid.merge.json"
        $headM = (& git -C $repo rev-parse HEAD); $env:KITCHEN_TIMEOUT = '600'
        try { $rm = Verify $jid } finally { $env:KITCHEN_TIMEOUT = $null }
        $gapWords = if ($null -eq $gap) { 'an unknown number of' } else { "$gap" }
        Check "mandatory blame check ($jid, gap $gapWords): cannot decide = held (exit 10), nothing undone, says why" ($rm.Code -eq 10 -and $rm.Out -match "verify: main was $gapWords commits past its last verified tree when $jid merged, so the blame check is mandatory; it could not decide \(no time left" -and $rm.Out -match 'nothing undone' -and $rm.Out -notmatch 'undo-merge' -and (& git -C $repo rev-parse HEAD) -eq $headM)
        $bu = @(Events 'verify.blame-unknown' | Where-Object { $_.job -eq $jid })
        Check "mandatory blame check ($jid): a verify.blame-unknown event with the suites, main status red" ($bu.Count -eq 1 -and @($bu[0].suites) -contains 'Test-A' -and $bu[0].why -match '^no time left' -and (MainStatus).state -eq 'red')
        & git -C $repo -c user.name=t -c user.email=t@localhost revert --no-edit -m 1 HEAD 2>&1 | Out-Null
    }
    # pastVerified 0 (main was at a verified tree): not mandatory, the undecided check fails closed as before (undone)
    G checkout -q -b kitchen/J13; Set-Content "$repo\red.txt" 'breaks it (J13)'; G add -A; G commit -q -m 'red J13'
    G checkout -q main; G merge -q --no-ff kitchen/J13 -m 'Merge kitchen/J13 (kitchen J13, approved by Jordan)'
    [ordered]@{ job = 'J13'; pastVerified = 0 } | ConvertTo-Json | Set-Content "$state\results\J13.merge.json"
    $env:KITCHEN_TIMEOUT = '600'
    try { $rm = Verify 'J13' } finally { $env:KITCHEN_TIMEOUT = $null }
    Check 'gap 0: the blame check is not mandatory; undecided = undone as before' ($rm.Code -eq 1 -and $rm.Out -match 'counted as broken' -and $rm.Out -notmatch 'mandatory' -and (& git -C $repo log -1 --format=%s) -match '^Undo J13 ')
    $null = Set-MainStatus $state $repo green   # main is green again (the reds above were reverted); the checks below start from green

    # no commit before this one (a root commit, no merge of J3): the check cannot run, so verify goes on as before (the undo finds no merge: refused)
    $repo2 = Join-Path $root 'repo2'; New-Item -ItemType Directory -Force -Path "$repo2\tests" | Out-Null
    Set-Content "$repo2\tests\Test-A.ps1" "'A: 1 passed, 0 failed'"; Set-Content "$repo2\red.txt" 'red from the start'
    & git -C $repo2 init -q -b main 2>&1 | Out-Null; & git -C $repo2 -c user.name=t -c user.email=t@localhost add -A 2>&1 | Out-Null; & git -C $repo2 -c user.name=t -c user.email=t@localhost commit -q -m root 2>&1 | Out-Null
    $r8 = Verify 'J3' $repo2
    Check 'no parent: the check says it could not run, then as before: undo refused (exit 1), main unchanged' ($r8.Code -eq 1 -and $r8.Out -match 'the blame check could not run \(no commit before the merge' -and $r8.Out -match 'undo refused' -and (& git -C $repo2 log -1 --format=%s) -eq 'root')
    Check 'no parent: merge.broken recorded, no verify.main-red' (@(Events 'merge.broken' | Where-Object { $_.job -eq 'J3' }).Count -eq 1 -and -not @(Events 'verify.main-red' | Where-Object { $_.job -eq 'J3' }).Count)
    $ms8 = MainStatus $repo2
    Check 'main status: broken and not undone = that Tower red, saying so, its own file (the first Tower untouched)' ($ms8.state -eq 'red' -and $ms8.tower -eq 'repo2' -and $ms8.why -eq 'Work order WO-0003 broke main and could not be undone; Test-A: FAIL: app.txt is not v1' -and (MainStatus).state -eq 'green' -and @(Get-ChildItem (Join-Path $state 'main-status')).Count -eq 2)

    # TD-EH-10: an undo that had to go up to GitHub and did not is told. The order came through a PR (results\J6.pr.json) and GitHub cannot
    # be reached: the undo is made on this PC, the merge.undone event says undoPushed false with the reason, the one HIGH alert says so in
    # fixed words, the Board's record (<kitchen>\undo-unpushed\J6.json) names the Tower, the GitHub repo and the undo commit
    $bare = Join-Path $root 'github.git'; & git clone -q --bare $repo $bare 2>&1 | Out-Null   # GitHub's main: main as it is before J6
    New-Item -ItemType Directory -Force "$state\results" | Out-Null
    function PrRec($jid, $n) { @{ repo = 'VonBorstel-J/repo'; number = $n; url = "https://github.com/VonBorstel-J/repo/pull/$n" } | ConvertTo-Json | Set-Content "$state\results\$jid.pr.json" }
    G checkout -q -b kitchen/J6; Set-Content "$repo\red.txt" 'breaks the suite (J6)'; G add -A; G commit -q -m 'red J6'
    G checkout -q main; G merge -q --no-ff kitchen/J6 -m 'Merge kitchen/J6 (kitchen J6, approved by Jordan)'; PrRec 'J6' 6
    $env:KITCHEN_GITHUB_REMOTE = Join-Path $root 'no-such-github.git'; $nb = @(Notifies).Count
    $r11 = Verify 'J6'
    $un6 = @(Events 'merge.undone' | Where-Object { $_.job -eq 'J6' })
    Check 'undo not pushed: undone on this PC as before (exit 1, an Undo commit), the step log says it is NOT on GitHub and why' ($r11.Code -eq 1 -and (& git -C $repo log -1 --format=%s) -match '^Undo J6 ' -and $r11.Out -match 'verify: the undo is NOT on GitHub \(GitHub could not be reached\): main on this PC is ahead of GitHub')
    Check 'undo not pushed: the merge.undone event carries undoPushed false and the reason' ($un6.Count -eq 1 -and $un6[0].undoPushed -eq $false -and $un6[0].undoPushWhy -eq 'GitHub could not be reached' -and @($un6[0].suites) -contains 'Test-A')
    Check 'undo not pushed: one HIGH alert, fixed words, the ticket number only' (@(Notifies).Count -eq $nb + 1 -and @(Notifies)[-1] -eq 'HIGH|test-topic-12345|J6 was undone: it broke main. The undo could not be pushed: main on this PC is ahead of GitHub')
    $rec6 = Get-Content "$state\undo-unpushed\J6.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    Check 'undo not pushed: recorded for the Board with the Tower, the GitHub repo, the undo commit and the reason' ($rec6.job -eq 'J6' -and $rec6.tower -eq 'repo' -and $rec6.slug -eq 'VonBorstel-J/repo' -and $rec6.sha -eq (& git -C $repo rev-parse HEAD) -and $rec6.why -eq 'GitHub could not be reached' -and $null -ne $rec6.at)
    Check 'undo not pushed: the blame check still ran first (TD-EH-01 unchanged)' ($r11.Out -match 'verify: Test-A pass on [0-9a-f]{12} \(the commit before this merge\) and fail after it: this merge is to blame' -and $un6[0].preMergeSha -eq (& git -C $repo rev-parse 'HEAD~1^1'))
    # the same with GitHub reachable and at the merge (GitHub merged the PR): the undo goes up too, undoPushed true, no record, the usual alert
    G checkout -q -b kitchen/J7; Set-Content "$repo\red.txt" 'breaks the suite (J7)'; G add -A; G commit -q -m 'red J7'
    G checkout -q main; G merge -q --no-ff kitchen/J7 -m 'Merge kitchen/J7 (kitchen J7, approved by Jordan)'; PrRec 'J7' 7
    & git -C $repo push -q $bare main 2>&1 | Out-Null; $env:KITCHEN_GITHUB_REMOTE = $bare; $nb = @(Notifies).Count
    $r12 = Verify 'J7'
    $un7 = @(Events 'merge.undone' | Where-Object { $_.job -eq 'J7' })
    Check 'undo pushed: GitHub has the undo, the event says undoPushed true with no reason, nothing for the Board' ($r12.Code -eq 1 -and $un7.Count -eq 1 -and $un7[0].undoPushed -eq $true -and $un7[0].PSObject.Properties.Name -notcontains 'undoPushWhy' -and (& git -C $bare rev-parse main) -eq (& git -C $repo rev-parse HEAD) -and -not (Test-Path "$state\undo-unpushed\J7.json") -and $r12.Out -notmatch 'NOT on GitHub')
    Check 'undo pushed: the usual HIGH alert' (@(Notifies).Count -eq $nb + 1 -and @(Notifies)[-1] -eq 'HIGH|test-topic-12345|J7 was undone: it broke main')
    Check 'an order that never went through GitHub: its merge.undone event has no undoPushed (nothing to push)' (@(Events 'merge.undone' | Where-Object { $_.job -eq 'J2' })[0].PSObject.Properties.Name -notcontains 'undoPushed')
    $env:KITCHEN_GITHUB_REMOTE = $null

    # TD-EH-11: a check that passed on main only on a retry pauses auto-merge for 24 h, and that is told: automerge-paused.json for the Board
    # (until, since, the count of flaky checks, the suites, the orders) and one alert when the pause starts; a second flaky check while paused
    # extends it (count and suites grow, since kept) with no second alert; a pause that is over starts afresh with a new alert
    $pp = Join-Path $state 'automerge-paused.json'
    Set-Content "$repo\app.txt" 'v4'; G add -A; G commit -q -m 'v4'; $env:VC_FLAKY = 'Test-A'; $nb = @(Notifies).Count; $t0 = [DateTime]::UtcNow
    $r13 = Verify 'J8'
    $p13 = Get-Content $pp -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    $u13 = if ($p13) { ([DateTime]$p13.until).ToUniversalTime() } else { [DateTime]::MinValue }
    Check 'pause: the merge is kept (exit 0) and the step log says until when, after how many flaky checks, which suites' ($r13.Code -eq 0 -and $r13.Out -match 'verify: auto-merge paused until \S+ after 1 flaky check \(Test-A\); the Board shows it')
    Check 'pause: automerge-paused.json says until (24 h on), since, 1 flaky check, the suite and the order' ($p13 -and ($u13 - $t0).TotalHours -gt 23.9 -and ($u13 - $t0).TotalHours -lt 24.1 -and $p13.flaky -eq 1 -and (@($p13.suites) -join ',') -eq 'Test-A' -and (@($p13.jobs) -join ',') -eq 'J8' -and [string]$p13.since -eq [string]$p13.at)
    Check 'pause: one alert, fixed words (nothing about the order)' (@(Notifies).Count -eq $nb + 1 -and @(Notifies)[-1] -eq 'MED|test-topic-12345|Auto-merge paused for 24 h: a check on main passed only on a retry')
    Check 'pause: still written to automerged.jsonl (what automerge.ps1 reads) and as a verify.flaky event with the end time' (@(Get-Content (Join-Path $state 'automerged.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'automerge.pause' -and $_.job -eq 'J8' }).Count -eq 1 -and @(Events 'verify.flaky' | Where-Object { $_.job -eq 'J8' -and $_.until }).Count -eq 1)
    Set-Content "$repo\app.txt" 'v5'; G add -A; G commit -q -m 'v5'; $env:VC_FLAKY = 'Test-B'; $nb = @(Notifies).Count
    $r14 = Verify 'J9'
    $p14 = Get-Content $pp -Raw | ConvertFrom-Json
    Check 'pause extended: a second flaky check while paused adds its suite and count, keeps since, moves until, no second alert' ($r14.Code -eq 0 -and $p14.flaky -eq 2 -and (@($p14.suites) -join ',') -eq 'Test-A,Test-B' -and (@($p14.jobs) -join ',') -eq 'J8,J9' -and [string]$p14.since -eq [string]$p13.since -and ([DateTime]$p14.until) -ge ([DateTime]$p13.until) -and @(Notifies).Count -eq $nb -and $r14.Out -match 'after 2 flaky checks \(Test-A, Test-B\)')
    # a pause that is over: the next flaky check starts a new one (count and suites afresh) and alerts again
    $p14.until = [DateTime]::UtcNow.AddMinutes(-5).ToString('o'); $p14 | ConvertTo-Json -Compress | Set-Content $pp
    Set-Content "$repo\app.txt" 'v6'; G add -A; G commit -q -m 'v6'; $env:VC_FLAKY = 'Test-C'; $nb = @(Notifies).Count
    $r15 = Verify 'J10'
    $p15 = Get-Content $pp -Raw | ConvertFrom-Json
    Check 'pause over: the next flaky check starts afresh (1 check, its suite, a new since) with one new alert' ($r15.Code -eq 0 -and $p15.flaky -eq 1 -and (@($p15.suites) -join ',') -eq 'Test-C' -and [string]$p15.since -ne [string]$p13.since -and @(Notifies).Count -eq $nb + 1)
    $env:VC_FLAKY = $null

    # the library in-process: red twice keeps since; a reason with no why record falls back to the step log's why line; the brief's line
    $ms = Join-Path $root 'ms-kitchen'; New-Item -ItemType Directory -Force $ms | Out-Null
    $a = Set-MainStatus $ms $repo red @('Test-X') 'first'; Start-Sleep -Milliseconds 30; $b = Set-MainStatus $ms $repo red @('Test-X', 'Test-Y') 'second'
    Check 'library: red again keeps since and takes the newest suites and why' ([string]$b.since -eq [string]$a.since -and [string]$b.at -gt [string]$a.at -and @($b.suites).Count -eq 2 -and $b.why -eq 'second')
    $wb = Get-MainRedWhy $ms "tests: FAIL  Test-Q   crashed before its summary line (2s)`r`ntests:       Cannot find path x`r`nFAILED: Test-Q" @('Test-Q')
    Check 'library: no why record = the why line under the FAIL line in the output' ($wb.why -eq 'Test-Q: Cannot find path x' -and -not $wb.record)
    Check 'library: no reason anywhere is said, never left blank' ((Get-MainRedWhy $ms 'FAILED: Test-Q' @('Test-Q')).why -match '^no reason was recorded')
    $line = Format-MainStatusLine @((Read-MainStatus $ms $repo)) ([DateTime]::Parse([string]$a.since, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime().AddHours(2.5))
    Check 'library: the brief line says RED since at least <time> (hours), the suites as Failed, why, the sha checked' ($line -match '^Main status: repo main is RED since at least \d\d-\d\d \d\d:\d\d UTC \(2\.5 h\), Failed: Test-X, Test-Y; why: second; last checked [0-9a-f]{12} at ')
    Set-Content (Join-Path $ms 'main-status\abcdefabcdef.json') '{ torn'
    $all = Read-MainStatusAll $ms
    Check 'library: an unreadable status file is listed as unreadable, never dropped' (@($all).Count -eq 2 -and @($all | Where-Object { $_.state -eq 'unreadable' -and $_.file -eq 'abcdefabcdef.json' }).Count -eq 1 -and (Format-MainStatusLine $all) -match 'abcdefabcdef main status cannot be read')
    Check 'library: no record at all is said plainly' ((Format-MainStatusLine @()) -match '^Main status: none recorded yet')
} finally {
    foreach ($k in $save.Keys) { Set-Item "env:$k" $save[$k] -ErrorAction SilentlyContinue; if ($null -eq $save[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } }
    if (Test-Path -LiteralPath $repo) { & git -C $repo worktree prune 2>&1 | Out-Null }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
Write-Host "VerifyCache tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
