# Tests for kitchen/stations/merge.ps1 queueing: merges into one repo run one at a time and both succeed; and (section 9, TD-EH-10) an undo
# of a PR order that could not be pushed to GitHub is said (undo-merge.ps1 -Json pushed/pushWhy) and recorded for the Board until undo-push-check.ps1 finds it there.
# Self-cleaning: temp kitchen root and scratch repo only; every merge process is killed after 120 s.
$ErrorActionPreference = 'Stop'
$st = Join-Path $PSScriptRoot '..\kitchen\stations'
$root = Join-Path ([IO.Path]::GetTempPath()) ('km-' + [guid]::NewGuid().ToString('N'))
$kr = Join-Path $root 'kitchen'; $repo = Join-Path $root 'repo'
. (Join-Path $PSScriptRoot '..\kitchen\train.ps1'); $trainP = Get-TrainPath $kr $repo   # this repo's merge train (one per repo, kitchen/train.ps1)
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G { & git -C $repo -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function NewJob($job, $file) {
    $env:KITCHEN_JOB = $job
    pwsh -NoProfile -File (Join-Path $st 'worktree.ps1') -Repo $repo | Out-Null
    $wt = Join-Path $kr "worktrees\$job"
    Set-Content "$wt\$file" "edited by $job"
    pwsh -NoProfile -File (Join-Path $st 'commit.ps1') -Message "edit $job" | Out-Null
}
function StartMerge($job) {
    $env:KITCHEN_JOB = $job
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($a in '-NoProfile', '-File', (Join-Path $st 'merge.ps1'), '-Repo', $repo, '-Approved') { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    [pscustomobject]@{ P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Killed = $false }
}
# wait for all, kill after 120 s total so nothing is left running
function WaitAll($ms) {
    $end = (Get-Date).AddSeconds($ms)
    foreach ($m in $args[0]) { $left = [int][math]::Max(0, ($end - (Get-Date)).TotalMilliseconds); if (-not $m.P.WaitForExit($left)) { try { $m.P.Kill($true) } catch { }; $m.P.WaitForExit(); $m.Killed = $true } }
}
$oldKitchen = $env:BRAIN_KITCHEN; $oldJob = $env:KITCHEN_JOB; $oldRemote = $env:KITCHEN_GITHUB_REMOTE
$running = @(); $lock = $null; $held = $false
try {
    New-Item -ItemType Directory -Path $kr, $repo | Out-Null
    $env:BRAIN_KITCHEN = $kr
    & git -C $repo init -q -b main 2>&1 | Out-Null
    foreach ($f in 'a.txt', 'b.txt', 'c.txt', 'd.txt') { Set-Content "$repo\$f" 'base' }
    G add -A; G commit -q -m base

    # the lock name is built the same way merge.ps1 builds it
    $top = (& git -C $repo rev-parse --show-toplevel)
    $key = [IO.Path]::GetFullPath($top).TrimEnd('\', '/').ToLowerInvariant()
    $lockName = 'Global\brain-kitchen-merge-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).Substring(0, 16)

    # 1. queueing: the test holds the lock, J1 and J2 start together and both wait
    NewJob 'J1' 'a.txt'; NewJob 'J2' 'b.txt'
    $base = (& git -C $repo rev-parse HEAD)
    $lock = [Threading.Mutex]::new($false, $lockName); $held = $lock.WaitOne(5000)
    Check 'queue: test holds the lock' $held
    $running = @(StartMerge 'J1'; StartMerge 'J2')
    Start-Sleep -Seconds 5
    Check 'queue: both wait while the lock is held' (@($running | Where-Object { -not $_.P.HasExited }).Count -eq 2)
    Check 'queue: main has not moved' ((& git -C $repo rev-parse HEAD) -eq $base)
    $lock.ReleaseMutex(); $held = $false
    WaitAll 120 $running
    foreach ($m in $running) { Check "queue: exit 0 and MERGED ($($m.P.Id))" (-not $m.Killed -and $m.P.ExitCode -eq 0 -and $m.Out.Result -match 'MERGED') }
    Check 'queue: main has both edits' ((Get-Content "$repo\a.txt" -Raw) -match 'edited by J1' -and (Get-Content "$repo\b.txt" -Raw) -match 'edited by J2')
    Check 'queue: two merge commits' ((& git -C $repo rev-list --merges --count "$base..HEAD") -eq '2')
    Check 'queue: nothing half-merged, checkout clean' (-not (& git -C $repo rev-parse --verify --quiet MERGE_HEAD) -and @(& git -C $repo status --porcelain --untracked-files=no).Count -eq 0)
    Check 'queue: worktrees gone' (-not (Test-Path "$kr\worktrees\J1") -and -not (Test-Path "$kr\worktrees\J2"))
    Check 'queue: branches gone' (-not (& git -C $repo rev-parse --verify --quiet kitchen/J1) -and -not (& git -C $repo rev-parse --verify --quiet kitchen/J2))

    # 2. the goal's case: two fresh non-conflicting jobs merge at the same instant, no lock held by the test
    NewJob 'J3' 'c.txt'; NewJob 'J4' 'd.txt'
    $base = (& git -C $repo rev-parse HEAD)
    $running = @(StartMerge 'J3'; StartMerge 'J4')
    WaitAll 120 $running
    foreach ($m in $running) { Check "race: exit 0 and MERGED ($($m.P.Id))" (-not $m.Killed -and $m.P.ExitCode -eq 0 -and $m.Out.Result -match 'MERGED') }
    Check 'race: main has both edits' ((Get-Content "$repo\c.txt" -Raw) -match 'edited by J3' -and (Get-Content "$repo\d.txt" -Raw) -match 'edited by J4')
    Check 'race: two merge commits' ((& git -C $repo rev-list --merges --count "$base..HEAD") -eq '2')
    Check 'race: clean, nothing half-merged' (-not (& git -C $repo rev-parse --verify --quiet MERGE_HEAD) -and @(& git -C $repo status --porcelain --untracked-files=no).Count -eq 0)

    # 3. the merge train is checked inside the lock: two live orders approved together, only one merges; the other waits (exit 11)
    New-Item -ItemType Directory -Force -Path "$kr\jobs" | Out-Null
    Remove-Item -LiteralPath $trainP -ErrorAction SilentlyContinue
    foreach ($jid in 'J5', 'J6') { @{ id = $jid; status = 'running'; cursor = 0 } | ConvertTo-Json | Set-Content "$kr\jobs\$jid.json" }
    Set-Content "$repo\e.txt" 'base'; Set-Content "$repo\f.txt" 'base'; G add -A; G commit -q -m 'more files'
    NewJob 'J5' 'e.txt'; NewJob 'J6' 'f.txt'
    $base = (& git -C $repo rev-parse HEAD)
    $running = @(StartMerge 'J5'; StartMerge 'J6')
    WaitAll 120 $running
    $codes = @($running | ForEach-Object { $_.P.ExitCode } | Sort-Object)
    Check 'train: one merges, the other waits its turn (exit 11)' (-not @($running | Where-Object Killed).Count -and ($codes -join ',') -eq '0,11')
    Check 'train: only one merge landed before verify' ((& git -C $repo rev-list --merges --count "$base..HEAD") -eq '1')
    $winner = @($running | Where-Object { $_.P.ExitCode -eq 0 })[0]; $wj = if ($winner.Out.Result -match 'kitchen/(J\d+)') { $Matches[1] } else { '' }
    Check 'train: held by the order that merged' ((Get-Content $trainP -Raw | ConvertFrom-Json).job -eq $wj -and $wj)

    # 4. only ever into main: with the real checkout on another branch the merge is held for Jordan (exit 10) and nothing moves
    Remove-Item -LiteralPath $trainP -ErrorAction SilentlyContinue
    Set-Content "$repo\g.txt" 'base'; G add -A; G commit -q -m 'g'
    NewJob 'J7' 'g.txt'
    G checkout -q -b side; $sideHead = (& git -C $repo rev-parse HEAD)
    $running = @(StartMerge 'J7'); WaitAll 120 $running
    Check 'off main: merge held (exit 10), says so' ($running[0].P.ExitCode -eq 10 -and $running[0].Out.Result -match "on 'side', not main")
    Check 'off main: nothing merged, job branch kept' ((& git -C $repo rev-parse HEAD) -eq $sideHead -and (& git -C $repo rev-parse --verify --quiet kitchen/J7))
    G checkout -q main

    # 5. merge train holders: a live holder makes the merge wait (exit 11, back in 120 s, main unchanged); a holder older than 90 minutes
    # or one that is finished is passed over; after a merge the train names the order that merged
    function MergeOne($job, $run) { $env:KITCHEN_RUN = $run; try { $r = @(StartMerge $job); WaitAll 120 $r; $r[0] } finally { $env:KITCHEN_RUN = $null } }
    Set-Content "$repo\h.txt" 'base'; Set-Content "$repo\i.txt" 'base'; Set-Content "$repo\k.txt" 'base'; G add -A; G commit -q -m 'h i k'
    NewJob 'J8' 'h.txt'
    @{ id = 'J9'; status = 'running'; cursor = 0 } | ConvertTo-Json | Set-Content "$kr\jobs\J9.json"
    @{ job = 'J9'; at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress | Set-Content $trainP
    $base = (& git -C $repo rev-parse HEAD)
    $m = MergeOne 'J8' "$root\run-J8"
    Check 'train: a live holder makes the merge wait (exit 11)' ($m.P.ExitCode -eq 11 -and $m.Out.Result -match 'waiting for the merge train \(J9')
    Check 'train: back on the rail in 120 s' ((Get-Content "$root\run-J8.wait" -Raw).Trim() -eq '120')
    Check 'train: main unchanged while waiting' ((& git -C $repo rev-parse HEAD) -eq $base)
    # TornMergeTrain_Waits_NeverMerges: a train file cut off mid-write, or empty, names no holder; it is held, never read as "no train"
    foreach ($torn in @('{"job":"J9","at":"2026-10-2', '')) {
        [IO.File]::WriteAllText($trainP, $torn)
        $m = MergeOne 'J8' "$root\run-J8t"
        Check "TornMergeTrain_Waits_NeverMerges ($(if ($torn) { 'torn' } else { 'empty' })): waits (exit 11, 120 s) and says so, main unchanged" ($m.P.ExitCode -eq 11 -and $m.Out.Result -match 'merge-train-[0-9a-f]+.json cannot be read' -and $m.Out.Result -match 'nothing merged' -and (Get-Content "$root\run-J8t.wait" -Raw).Trim() -eq '120' -and (& git -C $repo rev-parse HEAD) -eq $base)
    }
    Check 'train: an unreadable train file is left for its writer (not deleted)' ((Test-Path $trainP) -and (Get-Content $trainP -Raw) -eq $null)
    @{ job = 'J9'; at = [DateTime]::UtcNow.AddHours(-2).ToString('o') } | ConvertTo-Json -Compress | Set-Content $trainP
    $m = MergeOne 'J8' "$root\run-J8b"
    Check 'train: a holder older than 90 minutes is passed over' ($m.P.ExitCode -eq 0 -and $m.Out.Result -match 'MERGED')
    Check 'train: after the merge the train names the order that merged' ((Get-Content $trainP -Raw | ConvertFrom-Json).job -eq 'J8')
    NewJob 'J10' 'i.txt'
    @{ id = 'J9'; status = 'done'; cursor = 1 } | ConvertTo-Json | Set-Content "$kr\jobs\J9.json"
    @{ job = 'J9'; at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress | Set-Content $trainP
    $m = MergeOne 'J10' "$root\run-J10"
    Check 'train: a finished holder is passed over' ($m.P.ExitCode -eq 0 -and $m.Out.Result -match 'MERGED')
    Set-Content "$repo\t.txt" 'base'; G add -A; G commit -q -m 't'; NewJob 'J12' 't.txt'
    Set-Content $trainP '{"job":"J9","at":"2026-10-2' -NoNewline; (Get-Item $trainP).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
    $m = MergeOne 'J12' "$root\run-J12"
    Check 'train: an unreadable train file last written over 90 minutes ago is passed over like a stale holder' ($m.P.ExitCode -eq 0 -and $m.Out.Result -match 'MERGED' -and (Get-Content $trainP -Raw | ConvertFrom-Json).job -eq 'J12')

    # 5b. site closed when red (TD-EH-03c): while this Tower's main status (kitchen/main-status.ps1) is red, or its file cannot be read,
    # the merge waits (exit 11, back in 15 minutes) naming the suites and why; main unchanged, the train not claimed. Green merges.
    Remove-Item -LiteralPath $trainP -ErrorAction SilentlyContinue
    . (Join-Path $PSScriptRoot '..\kitchen\main-status.ps1'); $msP = Get-MainStatusPath $kr $repo
    Set-Content "$repo\r.txt" 'base'; G add -A; G commit -q -m 'r'; NewJob 'J13' 'r.txt'
    $null = Set-MainStatus $kr $repo red @('Test-VerifyCache', 'Test-PassApp') 'Test-VerifyCache: FAIL: train.ps1 not found' 'J9'
    $base = (& git -C $repo rev-parse HEAD)
    $m = MergeOne 'J13' "$root\run-J13"
    Check 'main red: waits (exit 11), naming the suites and why' ($m.P.ExitCode -eq 11 -and $m.Out.Result -match '(?m)^merge: site closed: repo main is red since at least \d\d-\d\d \d\d:\d\d UTC \(Failed: Test-VerifyCache, Test-PassApp; why: Test-VerifyCache: FAIL: train\.ps1 not found; last checked [0-9a-f]{12}\); nothing merged, the Work order waits until the verify Step finds main green again')
    Check 'main red: back on the rail in 15 minutes, main unchanged, train not claimed, branch kept' ((Get-Content "$root\run-J13.wait" -Raw).Trim() -eq '900' -and (& git -C $repo rev-parse HEAD) -eq $base -and -not (Test-Path $trainP) -and (& git -C $repo rev-parse --verify --quiet kitchen/J13))
    Set-Content $msP '{"state":"re' -NoNewline
    $m = MergeOne 'J13' "$root\run-J13u"
    Check 'main status unreadable: unknown, not green: waits (exit 11) and says so, main unchanged' ($m.P.ExitCode -eq 11 -and $m.Out.Result -match "site closed: main status file main-status\\$(Split-Path -Leaf $msP) \(repo\) cannot be read, so whether main is red is unknown" -and (Get-Content "$root\run-J13u.wait" -Raw).Trim() -eq '900' -and (& git -C $repo rev-parse HEAD) -eq $base)
    $null = Set-MainStatus $kr $repo green
    $m = MergeOne 'J13' "$root\run-J13g"
    Check 'main green: merges' ($m.P.ExitCode -eq 0 -and $m.Out.Result -match 'MERGED kitchen/J13' -and (Get-Content "$repo\r.txt" -Raw) -match 'edited by J13')
    Remove-Item -LiteralPath $msP -ErrorAction SilentlyContinue

    # 6. main moved and conflicts after the yes: aborted cleanly, exit 11 "needs freshen" (the supervisor re-freshens), train let go
    Remove-Item -LiteralPath $trainP -ErrorAction SilentlyContinue
    NewJob 'J11' 'k.txt'
    Set-Content "$repo\k.txt" 'changed on main meanwhile'; G add -A; G commit -q -m 'main moved'
    $base = (& git -C $repo rev-parse HEAD)
    $m = MergeOne 'J11' "$root\run-J11"
    Check 'conflict: exit 11 needs freshen, not a failure' ($m.P.ExitCode -eq 11 -and $m.Out.Result -match '(?m)^merge: needs freshen')
    Check 'conflict: nothing half-merged, main unchanged, branch kept' ((& git -C $repo rev-parse HEAD) -eq $base -and -not (& git -C $repo rev-parse --verify --quiet MERGE_HEAD) -and @(& git -C $repo status --porcelain --untracked-files=no).Count -eq 0 -and (& git -C $repo rev-parse --verify --quiet kitchen/J11))
    Check 'conflict: the train is let go' (-not (Test-Path $trainP) -or (Get-Content $trainP -Raw | ConvertFrom-Json).job -ne 'J11')

    # 6b. TD-EH-21: a cleanup that fails after the merge is said in one line (the merge itself stands, exit 0)
    Remove-Item -LiteralPath $trainP -ErrorAction SilentlyContinue
    Set-Content "$repo\m.txt" 'base'; G add -A; G commit -q -m 'm'; NewJob 'J14' 'm.txt'
    G worktree lock "$kr\worktrees\J14"
    $m = MergeOne 'J14' "$root\run-J14"
    Check 'cleanup failed: merged (exit 0), one line says the worktree and branch were not cleaned up, no "cleaned up" claim' ($m.P.ExitCode -eq 0 -and $m.Out.Result -match 'MERGED kitchen/J14' -and $m.Out.Result -match '(?m)^merge: cleanup failed: worktree \S+J14 not removed \(.+\); branch kitchen/J14 not deleted \(.+\)\r?$' -and $m.Out.Result -notmatch 'worktree and branch cleaned up')
    G worktree unlock "$kr\worktrees\J14"; G worktree remove --force "$kr\worktrees\J14"; G branch -D kitchen/J14

    # 6c. TD-EH-25: the merge says how far main is from its last verified tree (<kitchen>\verify-cache), emits it (merge.verified-gap) and
    # keeps it in merge.json (pastVerified) for the verify Step; any gap, or none found, makes the blame check mandatory
    function Events([string]$type) { @(Get-Content "$kr\events.jsonl" -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.type -eq $type }) }
    $vc = Join-Path $kr 'verify-cache'
    Remove-Item -LiteralPath $trainP, $vc -Recurse -ErrorAction SilentlyContinue
    Set-Content "$repo\v.txt" 'base'; G add -A; G commit -q -m 'v'; NewJob 'J15' 'v.txt'
    $m = MergeOne 'J15' "$root\run-J15"; $mj = Get-Content "$kr\results\J15.merge.json" -Raw | ConvertFrom-Json
    Check 'gap unknown: said, the blame check mandatory, pastVerified null in merge.json' ($m.P.ExitCode -eq 0 -and $m.Out.Result -match "(?m)^merge: main's last verified tree is unknown \(the verify cache holds no passed tree\); the blame check is mandatory for this Work order" -and $mj.PSObject.Properties.Name -contains 'pastVerified' -and $null -eq $mj.pastVerified)
    $vsha = (& git -C $repo rev-parse HEAD); $vtree = (& git -C $repo rev-parse 'HEAD^{tree}')
    New-Item -ItemType Directory -Force $vc | Out-Null
    @{ key = 'k1'; result = 'PASS'; tree = $vtree; tested = '2026-10-24T01:02:03.0000000Z'; job = 'J1'; repo = $repo } | ConvertTo-Json -Compress | Set-Content "$vc\k1.json"
    Set-Content "$repo\w1.txt" '1'; G add -A; G commit -q -m 'w1'; Set-Content "$repo\w2.txt" '2'; G add -A; G commit -q -m 'w2'; NewJob 'J16' 'v.txt'
    Remove-Item -LiteralPath $trainP -ErrorAction SilentlyContinue
    $m = MergeOne 'J16' "$root\run-J16"; $mj = Get-Content "$kr\results\J16.merge.json" -Raw | ConvertFrom-Json; $ev = @(Events 'merge.verified-gap' | Where-Object { $_.job -eq 'J16' })
    Check 'gap 2: "main is 2 commits past its last verified tree (<sha>, <when>)", the blame check mandatory' ($m.P.ExitCode -eq 0 -and $m.Out.Result -match "(?m)^merge: main is 2 commits past its last verified tree \($($vsha.Substring(0, 12)), 2026-10-24T01:02:03\.0000000Z\); the blame check is mandatory for this Work order")
    Check 'gap 2: emitted as merge.verified-gap and kept in merge.json' ($ev.Count -eq 1 -and $ev[0].n -eq 2 -and $ev[0].sha -eq $vsha -and $mj.pastVerified -eq 2 -and $mj.verifiedSha -eq $vsha)
    @{ key = 'k2'; result = 'PASS'; tree = (& git -C $repo rev-parse 'HEAD^{tree}'); tested = '2026-10-24T02:00:00.0000000Z'; job = 'J16'; repo = $repo } | ConvertTo-Json -Compress | Set-Content "$vc\k2.json"
    NewJob 'J17' 'w1.txt'; Remove-Item -LiteralPath $trainP -ErrorAction SilentlyContinue
    $m = MergeOne 'J17' "$root\run-J17"; $mj = Get-Content "$kr\results\J17.merge.json" -Raw | ConvertFrom-Json
    Check 'gap 0: "main is 0 commits past", the blame check not made mandatory, pastVerified 0' ($m.P.ExitCode -eq 0 -and $m.Out.Result -match '(?m)^merge: main is 0 commits past its last verified tree \([0-9a-f]{12}, 2026-10-24T02:00:00\.0000000Z\)\r?$' -and $mj.pastVerified -eq 0)
    Remove-Item -LiteralPath $trainP, $vc -Recurse -ErrorAction SilentlyContinue

    # 7. a job whose branch outlived its folder (deleted, or pruned after a close, then requeued): the worktree station checks it out again
    NewJob 'J12' 'l.txt'; $tip12 = (& git -C $repo rev-parse kitchen/J12)
    Remove-Item -LiteralPath "$kr\worktrees\J12" -Recurse -Force
    $env:KITCHEN_JOB = 'J12'; $o = pwsh -NoProfile -File (Join-Path $st 'worktree.ps1') -Repo $repo | Out-String; $wc = $LASTEXITCODE
    Check 'rebuild: the existing branch is checked out again with its commits' ($wc -eq 0 -and (& git -C "$kr\worktrees\J12" rev-parse HEAD) -eq $tip12 -and (Get-Content "$kr\worktrees\J12\l.txt" -Raw) -match 'edited by J12')
    Check 'rebuild: BASE is where the branch left main' ((Get-Content "$kr\worktrees\J12\.kitchen\BASE" -Raw).Trim() -eq (& git -C $repo merge-base HEAD kitchen/J12))

    # 8. doctor prunes worktrees of finished orders (closed, killed, done) and deletes only branches main already has; never a waiting,
    # set-aside or running order's
    function JobFile($id, $status) { @{ id = $id; name = "order $id"; status = $status; cursor = 0; steps = @(@{ script = 'x.ps1'; args = @{ Repo = $repo } }); history = @() } | ConvertTo-Json -Depth 5 | Set-Content "$kr\jobs\$id.json" }
    $cases = [ordered]@{ J20 = 'closed'; J21 = 'killed'; J22 = 'quarantined'; J23 = 'waiting-approval'; J24 = 'done'; J25 = 'running' }
    foreach ($id in $cases.Keys) { NewJob $id "$id.txt"; JobFile $id $cases[$id] }
    G merge -q --no-ff kitchen/J24 -m 'merge J24'   # J24's merge left its worktree behind (a file lock)
    $env:KITCHEN_SCRATCH_DIR = Join-Path $root 'scratch'; New-Item -ItemType Directory -Force -Path $env:KITCHEN_SCRATCH_DIR | Out-Null
    try { $dr = pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1') doctor -Json | Out-String | ConvertFrom-Json } finally { $env:KITCHEN_SCRATCH_DIR = $null }
    Check 'doctor: worktrees of closed, killed and done orders removed' (-not (Test-Path "$kr\worktrees\J20") -and -not (Test-Path "$kr\worktrees\J21") -and -not (Test-Path "$kr\worktrees\J24") -and $dr.prunedWorktrees -ge 3)
    Check 'doctor: set-aside, waiting and running orders keep their worktrees' ((Test-Path "$kr\worktrees\J22\.git") -and (Test-Path "$kr\worktrees\J23\.git") -and (Test-Path "$kr\worktrees\J25\.git"))
    $br = @(& git -C $repo branch --list 'kitchen/J2*' --format '%(refname:short)')
    Check 'doctor: a merged branch of a done order is deleted' ($br -notcontains 'kitchen/J24')
    Check 'doctor: unmerged branches of closed/killed orders are kept (their work stays reachable)' ($br -contains 'kitchen/J20' -and $br -contains 'kitchen/J21' -and $dr.keptBranches -ge 2)
    Check 'doctor: branches of live orders untouched' ($br -contains 'kitchen/J22' -and $br -contains 'kitchen/J23' -and $br -contains 'kitchen/J25')
    Check 'doctor: git no longer lists the removed worktrees' (-not ((& git -C $repo worktree list) -match 'worktrees[\\/]J2[014]\b'))

    # 9. TD-EH-10: an undo of a PR order that had to go up to GitHub and did not (the Board's one-tap undo runs undo-merge.ps1 like verify)
    # says so (-Json pushed false + pushWhy in fixed words) and is recorded for the Board (<kitchen>\undo-unpushed\<job>.json) until
    # undo-push-check.ps1 finds it on GitHub. GitHub here is a local bare repository (KITCHEN_GITHUB_REMOTE); nothing touches the network.
    $ur = Join-Path $root 'undo-repo'; $ub = Join-Path $root 'undo-github.git'; New-Item -ItemType Directory -Force $ur | Out-Null
    function U { & git -C $ur -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
    & git -C $ur init -q -b main 2>&1 | Out-Null; Set-Content "$ur\base.txt" 'base'; U add -A; U commit -q -m base
    function MergeHere($jid) { U checkout -q -b "kitchen/$jid"; Set-Content "$ur\$jid.txt" $jid; U add -A; U commit -q -m "work $jid"; U checkout -q main; U merge -q --no-ff "kitchen/$jid" -m "Merge kitchen/$jid (kitchen $jid, approved by Jordan)" }
    function PrRec($jid, $n) { New-Item -ItemType Directory -Force "$kr\results" | Out-Null; @{ repo = 'VonBorstel-J/undo-repo'; number = $n; url = "https://github.com/VonBorstel-J/undo-repo/pull/$n" } | ConvertTo-Json | Set-Content "$kr\results\$jid.pr.json" }
    function LastJson([string]$o) { ($o.Trim() -split "`r?`n")[-1] | ConvertFrom-Json }
    function Undo($jid) { $env:KITCHEN_JOB = $null; LastJson (& pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\kitchen\undo-merge.ps1') -Job $jid -Repo $ur -Json | Out-String) }
    function UndoCheck { LastJson (& pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\kitchen\undo-push-check.ps1') -Json | Out-String) }
    function UndoRec($jid) { Get-Content "$kr\undo-unpushed\$jid.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json }
    & git clone -q --bare $ur $ub 2>&1 | Out-Null; $env:KITCHEN_GITHUB_REMOTE = $ub
    # pushed: GitHub merged the PR (its main is at the merge), so the undo goes up as one commit on top
    MergeHere 'J30'; PrRec 'J30' 30; & git -C $ur push -q $ub main 2>&1 | Out-Null
    $u = Undo 'J30'
    Check 'undo push: on GitHub too -> pushed true, no reason, nothing for the Board' ($u.ok -and $u.pushed -eq $true -and -not $u.pushWhy -and $u.message -match 'pushed to GitHub' -and (& git -C $ub rev-parse main) -eq (& git -C $ur rev-parse HEAD) -and -not (Test-Path "$kr\undo-unpushed\J30.json"))
    # the push is refused (GitHub said no): pushed false, 'the push to GitHub failed', recorded with the Tower, the repo and the undo commit
    MergeHere 'J31'; PrRec 'J31' 31; & git -C $ur push -q $ub main 2>&1 | Out-Null
    [IO.File]::WriteAllText("$ub\hooks\pre-receive", "#!/bin/sh`nexit 1`n")
    $u = Undo 'J31'; $rec = UndoRec 'J31'
    Check 'undo push refused: still undone here, pushed false, the reason in fixed words, the message says push by hand' ($u.ok -and $u.pushed -eq $false -and $u.pushWhy -eq 'the push to GitHub failed' -and $u.message -match 'NOT on GitHub yet \(push failed' -and (& git -C $ur log -1 --format=%s) -match '^Undo J31 ' -and (& git -C $ub rev-parse main) -ne (& git -C $ur rev-parse HEAD))
    Check 'undo push refused: recorded for the Board (job, Tower, GitHub repo, undo commit, reason, time)' ($rec.job -eq 'J31' -and $rec.tower -eq 'undo-repo' -and $rec.slug -eq 'VonBorstel-J/undo-repo' -and $rec.sha -eq (& git -C $ur rev-parse HEAD) -and $rec.why -eq 'the push to GitHub failed' -and $null -ne $rec.at -and [IO.Path]::GetFullPath($rec.repo) -eq [IO.Path]::GetFullPath($ur))
    Remove-Item "$ub\hooks\pre-receive"
    # GitHub's main is not where this PC's was (it lacks the merge): nothing is pushed, said and recorded
    MergeHere 'J32'; PrRec 'J32' 32
    $u = Undo 'J32'
    Check "undo push: GitHub's main elsewhere -> pushed false with that reason, recorded" ($u.ok -and $u.pushed -eq $false -and $u.pushWhy -eq "GitHub's main is not where this PC's main was" -and (UndoRec 'J32').why -eq $u.pushWhy)
    # GitHub cannot be reached
    MergeHere 'J33'; PrRec 'J33' 33; $env:KITCHEN_GITHUB_REMOTE = Join-Path $root 'no-such-github.git'
    $u = Undo 'J33'
    Check 'undo push: GitHub not reachable -> pushed false with that reason, recorded' ($u.ok -and $u.pushed -eq $false -and $u.pushWhy -eq 'GitHub could not be reached' -and (UndoRec 'J33').why -eq 'GitHub could not be reached')
    # an order that never went through GitHub (no PR record): nothing to push, pushed null, nothing recorded
    MergeHere 'J34'
    $u = Undo 'J34'
    Check 'undo of a local-only order: pushed null (nothing to push), nothing for the Board' ($u.ok -and $null -eq $u.pushed -and -not (Test-Path "$kr\undo-unpushed\J34.json"))
    # the check lets a record go only with proof: GitHub not reachable, or main here still ahead of GitHub's = kept; a torn record is kept
    $c = UndoCheck
    Check 'undo check: GitHub not reachable -> every record kept, each says why' ($c.ok -and -not @($c.cleared).Count -and (@($c.left | ForEach-Object { $_.job }) -join ',') -eq 'J31,J32,J33' -and -not @($c.left | Where-Object { $_.why -ne 'GitHub could not be reached' }).Count -and @(Get-ChildItem "$kr\undo-unpushed" -Filter 'J*.json').Count -eq 3)
    $env:KITCHEN_GITHUB_REMOTE = $ub; Set-Content "$kr\undo-unpushed\J35.json" '{ torn'
    $c = UndoCheck
    Check 'undo check: GitHub reachable but main here still ahead -> kept, says so; a torn record is kept and named' (-not @($c.cleared).Count -and @($c.left | Where-Object { $_.why -eq 'main on this PC is still ahead of GitHub' }).Count -eq 3 -and @($c.left | Where-Object { $_.job -eq 'J35' -and $_.why -eq 'its record cannot be read' }).Count -eq 1 -and (Test-Path "$kr\undo-unpushed\J35.json"))
    Remove-Item "$kr\undo-unpushed\J35.json"
    # the Owner pushes main by hand: the next check finds every undo on GitHub, removes the records and says so (undo.pushed events)
    & git -C $ur push -q $ub main 2>&1 | Out-Null
    $c = UndoCheck
    $up = @(Get-Content "$kr\events.jsonl" -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.type -eq 'undo.pushed' })
    Check 'undo check: after the push by hand every record is cleared, nothing left, one undo.pushed event each' ((@($c.cleared) -join ',') -eq 'J31,J32,J33' -and -not @($c.left).Count -and -not @(Get-ChildItem "$kr\undo-unpushed" -Filter 'J*.json').Count -and (@($up | ForEach-Object { $_.job }) -join ',') -eq 'J31,J32,J33' -and -not @($up | Where-Object { $_.how -ne 'the undo is on GitHub' }).Count)
}
finally {
    foreach ($m in $running) { if ($m.P -and -not $m.P.HasExited) { try { $m.P.Kill($true) } catch { } } }
    if ($lock) { if ($held) { try { $lock.ReleaseMutex() } catch { } }; $lock.Dispose() }
    $env:BRAIN_KITCHEN = $oldKitchen; $env:KITCHEN_JOB = $oldJob; $env:KITCHEN_GITHUB_REMOTE = $oldRemote
    if (Test-Path -LiteralPath $repo) { & git -C $repo worktree prune 2>&1 | Out-Null }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "KitchenMerge tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
