# Tests for scripts/recheck-main.ps1 (TD-EH-03d): red to green after a fix that landed on GitHub's main, red stays red, -All, the throwaway
# worktree removed even when the tests Step crashes, the live checkout's working tree never touched, and every case that records nothing.
# Run by the Yard's tests Step (tests\Test-*.ps1) and by hand; a copied script with a scripted tests Step, a local bare repo as GitHub. Self-cleaning.
$ErrorActionPreference = 'Stop'
$src = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-recheck-' + [guid]::NewGuid().ToString('N'))
$save = @{ BRAIN_KITCHEN = $env:BRAIN_KITCHEN; KITCHEN_JOB = $env:KITCHEN_JOB; KITCHEN_GITHUB_REMOTE = $env:KITCHEN_GITHUB_REMOTE; TMP = $env:TMP; TEMP = $env:TEMP
    RC_RUNLOG = $env:RC_RUNLOG; RC_CRASH = $env:RC_CRASH; RC_TOUCH = $env:RC_TOUCH; RC_SLEEP = $env:RC_SLEEP }
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$tower = Join-Path $root 'tower'; $gh = Join-Path $root 'gh.git'; $other = Join-Path $root 'other-clone'
$state = Join-Path $root 'state'; $tmp = Join-Path $root 'tmp'; $runLog = Join-Path $root 'runs.log'
$recheck = Join-Path $root 'scripts\recheck-main.ps1'
function G([string]$dir) { & git -C $dir -c user.name=t -c user.email=t@localhost -c core.autocrlf=false @args 2>&1 | Out-String }
function Recheck { $o = & pwsh -NoProfile -File $recheck -Repo $tower @args 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }
function Runs { if (Test-Path $runLog) { @(Get-Content $runLog) } else { @() } }
function Events([string]$type) { @(Get-Content (Join-Path $state 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.type -eq $type }) }
function Leftovers { @(Get-ChildItem -LiteralPath $tmp -Directory -Filter 'recheck-main-*' -ErrorAction SilentlyContinue) }
function Worktrees { @((G $tower worktree list --porcelain) -split "`n" | Where-Object { $_ -match '^worktree ' }) }
# the live checkout as the Owner left it: on a feature branch, a tracked file edited, an untracked file; none of it may change
function LiveState { (G $tower rev-parse HEAD) + (G $tower rev-parse --abbrev-ref HEAD) + (G $tower rev-parse refs/heads/main) + (G $tower status --porcelain) + (Get-Content (Join-Path $tower 'app.txt') -Raw) + (Get-Content (Join-Path $tower 'notes.txt') -Raw) }
# a fix (or a break) that lands on "GitHub" only, the way merge-pr.ps1 -FixesRed lands one: committed in another clone and pushed
function Land-OnGitHub([string]$redText, [string]$msg) {
    G $other pull -q $gh main | Out-Null
    if ($redText) { Set-Content (Join-Path $other 'red.txt') $redText } else { Remove-Item (Join-Path $other 'red.txt') -ErrorAction SilentlyContinue }
    G $other add -A | Out-Null; G $other commit -q -m $msg | Out-Null; G $other push -q $gh HEAD:main | Out-Null
    (G $other rev-parse HEAD).Trim()
}
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts'), (Join-Path $root 'kitchen\stations'), $state, $tmp, (Join-Path $tower 'tests') | Out-Null
    Copy-Item (Join-Path $src 'scripts\recheck-main.ps1') (Join-Path $root 'scripts')
    foreach ($lib in 'main-status.ps1', 'repo-config.ps1', 'github-lib.ps1') { Copy-Item (Join-Path $src "kitchen\$lib") (Join-Path $root 'kitchen') }
    # the scripted tests Step: logs the folder it was given, its commit and -Only; suites named in that folder's red.txt fail, printed and
    # recorded the way the real one does (FAIL lines, a why record, "FAILED: a, b"); RC_CRASH=1 dies; RC_TOUCH=<file> rewrites a status
    Set-Content (Join-Path $root 'kitchen\stations\tests.ps1') @'
param([string]$Dir, [string]$ChangedFiles, [string]$Glob, [string]$Skip, [string[]]$Only, [int]$SuiteTimeoutSec, [int]$MaxMB)
$only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
Add-Content -LiteralPath $env:RC_RUNLOG -Value "dir=$Dir only=$($only -join ',') head=$((& git -C $Dir rev-parse HEAD).Trim()) live=$(Test-Path (Join-Path $Dir 'notes.txt'))"
if ($env:RC_TOUCH) { $j = Get-Content -LiteralPath $env:RC_TOUCH -Raw | ConvertFrom-Json; $j.at = '2099-01-01T00:00:00.0000000Z'; $j | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:RC_TOUCH }
if ($env:RC_CRASH -eq '1') { throw 'the scripted tests Step crashed' }
if ($env:RC_SLEEP) { Start-Sleep -Seconds ([int]$env:RC_SLEEP) }
$red = @(if (Test-Path (Join-Path $Dir 'red.txt')) { Get-Content (Join-Path $Dir 'red.txt') | Where-Object { $_ } })
$pick = @(Get-ChildItem (Join-Path $Dir 'tests') -Filter 'Test-*.ps1' | ForEach-Object BaseName | Sort-Object | Where-Object { -not $only.Count -or $_ -in $only })
if (-not $pick.Count) { "tests: no suites match tests\Test-*.ps1 in $Dir"; exit 1 }
$bad = @(foreach ($s in $pick) { if ($s -in $red) { $s } })
foreach ($s in $pick) { if ($s -in $bad) { "tests: FAIL  $s  0 passed, 1 failed"; "tests:       FAIL: $s is broken here" } else { "tests: PASS  $s  1 passed, 0 failed" } }
if (-not $bad.Count) { 'tests: ALL PASS'; 'ALL PASS'; exit 0 }
$rn = "results\nojob.tests-why-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"; New-Item -ItemType Directory -Force (Join-Path $env:BRAIN_KITCHEN 'results') | Out-Null
@{ suites = @($bad | ForEach-Object { @{ suite = $_; code = 1; summary = '0 passed, 1 failed'; why = @("FAIL: $_ is broken here") } }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $env:BRAIN_KITCHEN $rn)
"tests: why: $rn"; "FAILED: $($bad -join ', ')"; exit 1
'@
    . (Join-Path $src 'kitchen\main-status.ps1')
    $env:BRAIN_KITCHEN = $state; $env:KITCHEN_JOB = $null; $env:RC_RUNLOG = $runLog; $env:RC_CRASH = $null; $env:RC_TOUCH = $null
    $env:TMP = $tmp; $env:TEMP = $tmp; $env:KITCHEN_GITHUB_REMOTE = $gh
    # the Tower: Test-A and Test-B, main broken in Test-A (red.txt), its GitHub a local bare repo; the Owner's checkout then left on a branch
    Set-Content (Join-Path $tower 'tests\Test-A.ps1') "'A'"; Set-Content (Join-Path $tower 'tests\Test-B.ps1') "'B'"
    Set-Content (Join-Path $tower 'app.txt') 'v1'; Set-Content (Join-Path $tower 'red.txt') 'Test-A'
    Set-Content (Join-Path $tower 'kitchen.repo.json') '{"github":"VonBorstel-J/tower"}'
    & git init -q -b main $tower 2>&1 | Out-Null; G $tower add -A | Out-Null; G $tower commit -q -m 'main, Test-A broken' | Out-Null
    & git init -q --bare -b main $gh 2>&1 | Out-Null; G $tower push -q $gh main | Out-Null
    & git clone -q $gh $other 2>&1 | Out-Null
    $redSha = (G $tower rev-parse main).Trim()
    G $tower checkout -q -b feature | Out-Null; Set-Content (Join-Path $tower 'app.txt') 'v1 edited, not committed'; Set-Content (Join-Path $tower 'notes.txt') 'untracked'
    $live = LiveState

    # 1. nothing to go on: no status and no -All records nothing and runs nothing; the merge-pr refusal's -All case
    $r = Recheck
    Check 'no status, no -All: exit 2, says to run with -All, runs nothing, records nothing' ($r.Code -eq 2 -and $r.Out -match 'no main status is recorded for tower yet.*run with -All; nothing recorded' -and -not (Runs).Count -and -not (Read-MainStatus $state $tower))

    # 2. red stays red: the verify Step recorded Test-A red; main still has it broken
    $vr = Set-MainStatus $state $tower red @('Test-A') 'red before Work order WO-0005 merged; Test-A: FAIL: broken' 'J5' -Sha $redSha
    Start-Sleep -Milliseconds 20
    $r = Recheck
    $ms = Read-MainStatus $state $tower; $run = @(Runs)[-1]
    Check 'red stays red: exit 1, says still red at the commit, Failed: Test-A' ($r.Code -eq 1 -and $r.Out -match "recheck-main: tower main is red at $($redSha.Substring(0, 12)) \(Failed: Test-A\); recorded")
    Check 'red stays red: only the suite the status named was run, on main, in a throwaway worktree under TEMP (not the live checkout)' ((Runs).Count -eq 1 -and $run -match '^dir=(\S+) only=Test-A head=(\S+) live=False$' -and $Matches[2] -eq $redSha -and $Matches[1] -like "$tmp*recheck-main-*" -and $Matches[1] -ne $tower)
    Check 'red stays red: status red, same since, newer at, the commit checked, why from the record, a recheck note, no work order' ($ms.state -eq 'red' -and @($ms.suites) -join ',' -eq 'Test-A' -and $ms.since -eq $vr.since -and $ms.at -gt $vr.at -and $ms.sha -eq $redSha -and $ms.why -eq "still red on a recheck of $($redSha.Substring(0, 12)); Test-A: FAIL: Test-A is broken here" -and $ms.record -match '^results\\nojob\.tests-why-' -and $ms.note -match '^recheck of main \(this PC.s and GitHub.s agree\): only the suites that were red \(Test-A\)$' -and $ms.job -eq '')
    Check 'red stays red: no new main.status event (the state did not change)' (@(Events 'main.status').Count -eq 1)
    Check 'red stays red: the worktree is gone, git lists only the live checkout' (-not (Leftovers).Count -and (Worktrees).Count -eq 1)
    Check 'red stays red: the live checkout is untouched (branch, HEAD, main, edits, untracked file)' ((LiveState) -eq $live)

    # 3. red to green after a fix: the fix lands on GitHub's main only (merge-pr.ps1 -FixesRed); this PC's main has not caught up
    $fixSha = Land-OnGitHub '' 'fix Test-A'
    $r = Recheck
    $ms = Read-MainStatus $state $tower; $run = @(Runs)[-1]
    Check 'after a fix: checks GitHub''s main, which is ahead of this PC''s, and says so' ($r.Code -eq 0 -and $r.Out -match "checking Test-A on GitHub's main \(VonBorstel-J/tower\), ahead of this PC's main at $($fixSha.Substring(0, 12))" -and $run -match "only=Test-A head=$fixSha ")
    Check 'after a fix: recorded green at the fix, no suites, no why, says the Tower is open again' ($ms.state -eq 'green' -and $ms.sha -eq $fixSha -and -not @($ms.suites).Count -and $ms.why -eq '' -and $ms.note -match "^recheck of GitHub's main .*only the suites that were red \(Test-A\)$" -and $r.Out -match 'tower main is green at .* \(Test-A passed\); recorded, the Tower is open to merges again')
    $ev = @(Events 'main.status')
    Check 'after a fix: one main.status event, green, at the fix' ($ev.Count -eq 2 -and $ev[-1].state -eq 'green' -and $ev[-1].sha -eq $fixSha)
    Check 'after a fix: the gate merge-pr.ps1 reads is open' (-not (Get-MainStatusGate (Get-MainStatusFor $state $tower)).closed)
    Check 'after a fix: worktree gone, live checkout untouched (this PC''s main not moved)' (-not (Leftovers).Count -and (Worktrees).Count -eq 1 -and (LiveState) -eq $live)
    $r = Recheck
    Check 'green: nothing to recheck without -All (exit 0, no run, nothing written)' ($r.Code -eq 0 -and $r.Out -match 'already green .*nothing to recheck' -and (Runs).Count -eq 2 -and (Read-MainStatus $state $tower).at -eq $ms.at)

    # 4. -All: every suite runs, whatever the status says; a break in Test-B (never named as red) is found and recorded
    $breakSha = Land-OnGitHub 'Test-B' 'break Test-B'
    $r = Recheck -All
    $ms = Read-MainStatus $state $tower; $run = @(Runs)[-1]
    Check '-All: every suite runs (no -Only) on current main' ($r.Code -eq 1 -and $run -match "only= head=$breakSha ")
    Check '-All: red with Test-B, why from the record, red since now, a main.status event' ($ms.state -eq 'red' -and @($ms.suites) -join ',' -eq 'Test-B' -and $ms.why -eq "red on a recheck of $($breakSha.Substring(0, 12)); Test-B: FAIL: Test-B is broken here" -and $ms.since -eq $ms.at -and $ms.note -match ': all suites$' -and @(Events 'main.status')[-1].state -eq 'red')
    $fix2 = Land-OnGitHub '' 'fix Test-B'
    $r = Recheck -All
    Check '-All: green once every suite passes' ($r.Code -eq 0 -and (Read-MainStatus $state $tower).state -eq 'green' -and (Read-MainStatus $state $tower).sha -eq $fix2 -and $r.Out -match '\(every suite passed\)')
    Remove-Item (Join-Path $state 'main-status') -Recurse -Force
    $r = Recheck -All
    Check '-All with no status: records the first one' ($r.Code -eq 0 -and (Read-MainStatus $state $tower).state -eq 'green')

    # 5. the worktree is removed even when the tests Step crashes; a worktree left by a stopped recheck is swept by the next one
    $key = Get-MainStatusKey $tower; $stale = Join-Path $tmp "recheck-main-$key-deadbeef"
    G $tower worktree add -q --detach $stale main | Out-Null
    Set-MainStatus $state $tower red @('Test-A') 'broken' 'J6' | Out-Null; $before = (Read-MainStatus $state $tower)
    $env:RC_CRASH = '1'; $r = Recheck; $env:RC_CRASH = $null
    Check 'crash: exit 2, no verdict, nothing recorded' ($r.Code -eq 2 -and $r.Out -match 'the tests Step gave no verdict on .*nothing recorded' -and (Read-MainStatus $state $tower).at -eq $before.at)
    $crashDir = @(Runs)[-1] -replace '^dir=(\S+) .*$', '$1'
    Check 'crash: the throwaway worktree is removed and the stale one swept (no folder, git lists only the live checkout)' ($crashDir -like "$tmp*recheck-main-$key-*" -and -not (Test-Path $crashDir) -and -not (Leftovers).Count -and (Worktrees).Count -eq 1 -and -not (Test-Path $stale))
    Check 'crash: the live checkout is untouched' ((LiveState) -eq $live)

    # 6. nothing is guessed: a named suite that is not on main, a split main, GitHub unreachable, a status written meanwhile
    Set-MainStatus $state $tower red @('Test-A', 'Test-Gone') 'broken' 'J7' | Out-Null; $before = (Read-MainStatus $state $tower)
    $r = Recheck
    Check 'a named suite that is not on main: not proven green, says -All, nothing recorded' ($r.Code -eq 2 -and $r.Out -match 'Test-Gone did not run on .*run with -All; nothing recorded' -and (Read-MainStatus $state $tower).at -eq $before.at -and -not (Leftovers).Count)
    Set-MainStatus $state $tower red @('Test-A') 'broken' 'J7' | Out-Null
    $env:RC_TOUCH = Get-MainStatusPath $state $tower; $r = Recheck; $env:RC_TOUCH = $null
    Check 'a status written while the suites ran (the verify Step) is not overwritten' ($r.Code -eq 2 -and $r.Out -match 'changed while this ran .*not overwritten; nothing recorded' -and (Read-MainStatus $state $tower).at -match '^2099-')
    Set-MainStatus $state $tower red @('Test-A') 'broken' 'J8' | Out-Null; $before = (Read-MainStatus $state $tower); $runs0 = (Runs).Count
    G $tower checkout -q main | Out-Null; G $tower stash -q | Out-Null
    Set-Content (Join-Path $tower 'local.txt') 'only here'; G $tower add local.txt | Out-Null; G $tower commit -q -m 'local only' | Out-Null
    G $tower checkout -q feature | Out-Null; G $tower stash pop -q | Out-Null
    $live = LiveState; Land-OnGitHub 'Test-Nothing' 'github only' | Out-Null
    $r = Recheck
    Check 'this PC''s main and GitHub''s split apart: exit 2, says so and names -Local, runs nothing' ($r.Code -eq 2 -and $r.Out -match 'have split apart, so which one is main is not known; -Local' -and (Runs).Count -eq $runs0 -and (Read-MainStatus $state $tower).at -eq $before.at)
    $env:KITCHEN_GITHUB_REMOTE = Join-Path $root 'no-such-remote.git'; $r = Recheck; $env:KITCHEN_GITHUB_REMOTE = $gh
    Check 'GitHub cannot be reached: exit 2, names -Local, nothing recorded' ($r.Code -eq 2 -and $r.Out -match 'could not fetch main from GitHub \(VonBorstel-J/tower\); -Local checks' -and (Read-MainStatus $state $tower).at -eq $before.at)
    $localSha = (G $tower rev-parse main).Trim()
    $r = Recheck -Local
    Check '-Local: checks this PC''s main (still red there in Test-A)' ($r.Code -eq 1 -and @(Runs)[-1] -match "head=$localSha " -and (Read-MainStatus $state $tower).sha -eq $localSha -and $r.Out -match "checking Test-A on this PC's main")
    Check 'every run: no worktree left, the live checkout untouched' (-not (Leftovers).Count -and (Worktrees).Count -eq 1 -and (LiveState) -eq $live)
    $r = & pwsh -NoProfile -File $recheck -Repo (Join-Path $root 'nowhere') 2>&1 | Out-String
    Check 'a folder that is not there: exit 2' ($LASTEXITCODE -eq 2 -and $r -match 'folder not found')

    # 7. -SkipUnchanged and the night inspection (TD-EH-03b): main unchanged since its last green FULL run is skipped and says so; a green
    # from a recheck of only the red suites never counts; the night inspection runs recheck-main -All -SkipUnchanged bounded, one line a night
    $localSha = (G $tower rev-parse main).Trim(); $runs0 = (Runs).Count
    Set-MainStatus $state $tower green -Note 'verify after WO-0009' -Sha $localSha | Out-Null; $before = (Read-MainStatus $state $tower)
    $r = Recheck -All -SkipUnchanged -Local
    Check '-SkipUnchanged: main unchanged since its last green full run: exit 3, says skipped, runs nothing, records nothing' ($r.Code -eq 3 -and $r.Out -match "skipped: tower main is unchanged since its last green full run \($($localSha.Substring(0, 12))," -and (Runs).Count -eq $runs0 -and (Read-MainStatus $state $tower).at -eq $before.at)
    Set-MainStatus $state $tower green -Note 'recheck of main: only the suites that were red (Test-B)' -Sha $localSha | Out-Null
    $r = Recheck -All -SkipUnchanged -Local
    Check '-SkipUnchanged: a green from a recheck of only the red suites does not count: every suite runs' ($r.Code -eq 1 -and (Runs).Count -eq $runs0 + 1 -and @(Runs)[-1] -match "only= head=$localSha ")
    Copy-Item (Join-Path $src 'scripts\night-inspection.ps1'), (Join-Path $src 'scripts\run-bounded.ps1') (Join-Path $root 'scripts')
    $night = Join-Path $root 'scripts\night-inspection.ps1'; $nightLog = Join-Path $state 'night-inspection.jsonl'
    function Night { $o = & pwsh -NoProfile -File $night -Repo $tower -KitchenRoot $state @args 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o; Line = @(Get-Content $nightLog | ForEach-Object { $_ | ConvertFrom-Json })[-1] } }
    G $tower fetch -q $gh main | Out-Null; G $tower branch -f main FETCH_HEAD | Out-Null; $ghSha = (G $tower rev-parse main).Trim()
    Set-MainStatus $state $tower green -Note 'verify after WO-0010' -Sha $localSha | Out-Null; $runs0 = (Runs).Count
    $n = Night
    Check 'night inspection: main moved since the last green: every suite runs on current main, green recorded, one line' ($n.Code -eq 0 -and @(Runs)[-1] -match "only= head=$ghSha " -and (Read-MainStatus $state $tower).sha -eq $ghSha -and (Read-MainStatus $state $tower).note -match ': all suites$' -and $n.Line.result -eq 'green' -and $n.Line.exit -eq 0 -and $n.Line.repo -eq $tower)
    $n = Night
    Check 'night inspection: the next night with main unchanged is skipped, and the line says why' ($n.Code -eq 3 -and (Runs).Count -eq $runs0 + 1 -and $n.Line.result -eq 'skipped' -and $n.Line.said -match 'unchanged since its last green full run' -and @(Get-Content $nightLog).Count -eq 2)
    Set-MainStatus $state $tower red @('Test-A') 'broken' 'J9' | Out-Null
    $env:RC_SLEEP = '60'; $n = Night -TimeoutSeconds 4; $env:RC_SLEEP = $null
    Check 'night inspection: bounded: a run past its limit is stopped (124), the line says main is not proven, the status untouched' ($n.Code -eq 124 -and $n.Line.result -eq 'timeout' -and $n.Line.said -match 'not proven either way' -and $n.Line.sec -lt 30 -and (Read-MainStatus $state $tower).state -eq 'red')
} finally {
    foreach ($k in $save.Keys) { Set-Item -Path "Env:$k" -Value $save[$k] -ErrorAction SilentlyContinue; if ($null -eq $save[$k]) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue } }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "RecheckMain tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
