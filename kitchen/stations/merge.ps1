# Station: merge this job's branch into the real checkout. Always an approved, unsafe step in recipes: it runs only after Jordan's yes.
# Refuses when the real checkout has uncommitted changes; a merge conflict is aborted cleanly (nothing half-merged) and exits 11 "needs freshen".
# On success the job's worktree and branch are removed; a removal that fails is said in one line (TD-EH-21). Every merge also says how far
# main is from its last verified tree (TD-EH-25: "main is N commits past its last verified tree (<sha>, <when>)", a merge.verified-gap event).
# An order with a pull request (the pr station's record, <kitchen>\results\<job>.pr.json) merges on GitHub instead: `gh pr merge --merge`
# pinned to the exact commit that was tested (--match-head-commit), or, when Jordan already pressed Merge there, nothing to merge; then
# GitHub's main is fetched and the real checkout's main fast-forwards to it. A checkout with uncommitted changes, or a main that has
# commits GitHub's main does not (so no fast-forward), is held for Jordan (exit 10), nothing changed. Orders without a PR record (a
# private order, a repo with no GitHub home, orders from before the PR flow) merge locally exactly as before.
# Inside a merge freeze window of the repo's kitchen.repo.json ("freeze") nothing merges: exit 11 with the reason, the order waits.
# Site closed when red (TD-EH-03c): while this Tower's main status (kitchen/main-status.ps1, written by the verify step) is red, or its
# file cannot be read (unknown is not green), nothing merges: exit 11 naming the suites and why, back in 15 minutes, the order waits.
# An order whose PR the Owner already merged on GitHub still brings main home (that merge has happened; holding it back changes nothing).
# Either way the range main moved over is kept in <kitchen>\results\<job>.merge.json {before, after} for the deploy station.
#   step: {"station":"merge","args":{"Repo":"C:\\path\\to\\repo"},"approve":true,"replay":"unsafe"}
param([Parameter(Mandatory)][string]$Repo, [switch]$Approved)
$ErrorActionPreference = 'Stop'
$job = $env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'merge: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$jj = try { Get-Content -LiteralPath (Join-Path $kroot "jobs\$job.json") -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
$jobOk = [bool]($jj -and $jj.approval -and $jj.approval.granted -and ($null -eq $jj.approval.cursor -or [int]$jj.approval.cursor -eq [int]$jj.cursor))
if (-not ($Approved -or $env:KITCHEN_APPROVED -eq '1' -or $jobOk)) { Write-Output 'merge: unapproved merge operation refused; requires -Approved or KITCHEN_APPROVED=1'; exit 2 }
$wt = Join-Path $kroot "worktrees\$job"; $branch = "kitchen/$job"
if (-not (& git -C $Repo rev-parse --verify --quiet $branch)) { Write-Output "merge: branch $branch not found"; exit 2 }
. (Join-Path $PSScriptRoot '..\github-lib.ps1')
# the PR record decides the path. A damaged or disputed record, or an order whose recipe opened a PR but left no record, never falls
# back to the local merge on its own (that would skip GitHub's CI and Jordan's PR): held for Jordan, nothing changed.
$pr = Read-PrRecord $kroot $job
if ($pr.err) { Write-Output "merge: $($pr.err); nothing merged"; exit 10 }
$hasPrStep = [bool]@($jj.steps | Where-Object { [string]$_.script -match '(^|[\\/])pr\.ps1$' }).Count
if (-not $pr.rec -and $hasPrStep) { Write-Output "merge: this order opens a pull request but has no PR record (did the pr step run?); nothing merged"; exit 10 }
$viaPr = [bool]($pr.rec -and -not $pr.rec.skipped)
function Rail([int]$sec) { if ($env:KITCHEN_RUN) { Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value $sec } }
# A merge freeze window (the repo's kitchen.repo.json "freeze", from its main checkout; kitchen/freeze-lib.ps1): nothing merges into
# the repo, on GitHub or here, until the window ends. The order waits on the rail (exit 11; the supervisor re-runs this step, at most
# 6 h apart) and resumes after. A config that will not load is held for Jordan (exit 10); the message names the field.
. (Join-Path $PSScriptRoot '..\freeze-lib.ps1')
$fz = Get-RepoFreezeState $Repo
if ($fz.err) { Write-Output "merge: $($fz.err); nothing merged"; exit 10 }
if ($fz.active) { Rail $fz.waitSec; Write-Output "merge: $($fz.name) $($fz.reason); nothing merged, the order waits and resumes after"; exit 11 }
# The merge train: one change at a time goes merge -> verify on main. While another order's merge is still being verified, this
# one waits its turn (exit 11: back on the rail in 2 minutes), so a failing check always blames the right change. The verify
# station hands the train back. A holder that is no longer alive, or older than 90 minutes, is passed over.
# The train is checked and claimed INSIDE the merge lock below: checked before it, two approvals in one tick both found the train
# empty, both merged, and two verifies then ran on main at once, each able to blame (and undo) the other's change.
# The train is per repo (kitchen/train.ps1: a merge into another repo never waits on this one). A train file that cannot be read (torn,
# empty) is a holder nobody can name for 90 minutes from its write time: wait, never merge on top. The supervisor also checks the train
# before it starts this step (no worker, no slot while it is busy); the check here, inside the lock, is what makes the claim safe.
. (Join-Path $PSScriptRoot '..\train.ps1')
function Train-Holder { Get-TrainHolder $kroot $Repo $job }   # (needs-human counts as live: a verify cut short waits for Jordan's yes)
function Release-Claim { Clear-TrainClaim $kroot $Repo $job }
. (Join-Path $PSScriptRoot '..\main-status.ps1')
function Wait-IfMainRed {   # called inside the lock, just before this order would merge
    $g = Get-MainStatusGate (Get-MainStatusFor $kroot $Repo)
    if ($g.closed) { Rail 900; Write-Output "merge: site closed: $($g.text); nothing merged, the Work order waits until the verify Step finds main green again (checked again in 15 minutes)"; exit 11 }
}
# One merge at a time per repo: two at once would fight over .git/index.lock, and the loser's abort could undo the winner's merge.
# An abandoned lock (a holder that died) is taken over. The lock is always released in the finally.
$top = (& git -C $Repo rev-parse --show-toplevel); if ($LASTEXITCODE -or -not $top) { $top = $Repo }
$key = [IO.Path]::GetFullPath($top).TrimEnd('\', '/').ToLowerInvariant()
$lockName = 'Global\brain-kitchen-merge-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).Substring(0, 16)
$lock = [Threading.Mutex]::new($false, $lockName); $got = $false
try { $got = $lock.WaitOne(300000) } catch [Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { $lock.Dispose(); Write-Output 'merge: another merge into this repo is still running after 5 minutes; nothing changed'; exit 1 }
try {
    $holder = Train-Holder
    if ($holder) {
        if ($env:KITCHEN_RUN) { Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value 120 }
        Write-Output "merge: waiting for the merge train ($holder is being checked on main); nothing merged"; exit 11
    }
    $dirty = @(& git -C $Repo status --porcelain --untracked-files=no)
    # with a PR, GitHub may already hold the merge: main must still come home, so a dirty checkout is a hold for Jordan (10), not a failure
    if ($dirty.Count) { Write-Output "merge: the real checkout has uncommitted changes; commit or stash them first:"; $dirty | Select-Object -First 10 | ForEach-Object { "  $_" }; exit $(if ($viaPr) { 10 } else { 1 }) }
    $into = (& git -C $Repo rev-parse --abbrev-ref HEAD)
    # only ever into main: a checkout left on a feature branch or a detached HEAD (a bisect) would take the AI change there, and branch -d
    # below would then delete the job's branch while main never got it. Held for Jordan (exit 10) until the checkout is back on main.
    if ($into -ne 'main') { Write-Output "merge: the real checkout is on '$into', not main; nothing merged"; exit 10 }
    # say who said yes: Jordan's tap, his auto-merge policy (the supervisor marks those approval.kind = 'auto'), or his Merge on GitHub ('github')
    $who = 'approved by Jordan'
    try { $jj = Get-Content -LiteralPath (Join-Path $kroot "jobs\$job.json") -Raw | ConvertFrom-Json; if ($jj.approval -and $jj.approval.kind -eq 'auto') { $who = "auto-merged under Jordan's policy" } elseif ($jj.approval -and $jj.approval.kind -eq 'github') { $who = 'merged by Jordan on GitHub' } } catch { }
    $before = [string](& git -C $Repo rev-parse HEAD)
    if ($viaPr) {
        $slug = [string]$pr.rec.repo; $n = [int]$pr.rec.number
        $tip = [string](& git -C $Repo rev-parse --verify "refs/heads/$branch^{commit}")
        $v = Invoke-GhJson @('pr', 'view', "$n", '-R', $slug, '--json', 'state,headRefOid,mergeable')
        if (-not $v.ok) { Rail 300; Write-Output "merge: could not reach GitHub to read PR #$n ($(Get-GhWhy $v)); nothing changed"; exit 11 }
        $state = [string]$v.json.state
        if ($state -eq 'CLOSED') { Write-Output "merge: Jordan closed PR #$n on GitHub without merging it; nothing merged"; exit 1 }
        if ($state -notin 'OPEN', 'MERGED') { Write-Output "merge: PR #$n is in a state the kitchen does not know ('$state'); nothing merged"; exit 1 }
        $ghMain = Get-GithubMain $Repo $slug
        if (-not $ghMain) { Rail 300; Write-Output "merge: could not fetch main from GitHub; nothing changed"; exit 11 }
        # main comes home only as a fast-forward: a local main with commits GitHub's main lacks (pushed by nobody, or a local undo that
        # never went up) cannot follow GitHub without losing them. Jordan sorts that out (push them, or reset); nothing changes meanwhile.
        if (-not (Test-Ancestor $Repo $before $ghMain)) { Write-Output "merge: the real checkout's main has commits GitHub's main does not (push them to GitHub first); nothing merged"; exit 10 }
        if ($state -eq 'OPEN') {
            $head = [string]$v.json.headRefOid
            if ($head -ne $tip) { Write-Output "merge: PR #$n on GitHub is at $head, not the kitchen's tested $tip; nothing merged"; exit 10 }
            $mg = [string]$v.json.mergeable
            # conflicts with GitHub's main: the same "needs freshen" as a local conflict (the supervisor sends the order back to freshen)
            # main first comes up to GitHub's (a fast-forward, checked above): freshen merges the LOCAL main into the branch, and would
            # never see a conflict with commits only GitHub had
            if ($mg -eq 'CONFLICTING') {
                $synced = if ($before -ne $ghMain) { & git -C $Repo merge --ff-only --quiet $ghMain 2>&1 | Out-Null; if ($LASTEXITCODE) { '' } else { "; main brought up to GitHub's first" } } else { '' }
                Rail 60; Write-Output "merge: needs freshen: PR #$n conflicts with main on GitHub$synced; nothing merged"; exit 11
            }
            if ($mg -ne 'MERGEABLE') { Rail 60; Write-Output "merge: GitHub is still working out whether PR #$n can merge ($mg); nothing changed"; exit 11 }
        }
        if ($state -eq 'OPEN') { Wait-IfMainRed }
        Set-TrainClaim $kroot $Repo $job   # (written whole: a reader never sees half of it)
        if ($state -eq 'OPEN') {
            # pinned to the tested commit: if anything was pushed to the PR since, GitHub refuses instead of merging what nobody checked
            $m = Invoke-Gh @('pr', 'merge', "$n", '-R', $slug, '--merge', '--match-head-commit', $tip, '--subject', "Merge $branch (kitchen $job, $who)", '--body', "Pull request #$n, merged by Jordan's Kitchen.")
            if (-not $m.ok) {
                $again = Invoke-GhJson @('pr', 'view', "$n", '-R', $slug, '--json', 'state')   # an error after GitHub merged (a dropped answer) is still a merge
                if (-not ($again.ok -and [string]$again.json.state -eq 'MERGED')) { Release-Claim; Write-Output "merge: GitHub did not merge PR #$n ($(Get-GhWhy $m)); nothing changed"; exit 1 }
            }
            Write-Output "merge: GitHub merged PR #$n"
        } else { Write-Output "merge: PR #$n was already merged on GitHub" }
        $ghMain = ''; for ($i = 0; $i -lt 3 -and -not ($ghMain -and (Test-Ancestor $Repo $tip $ghMain)); $i++) { if ($i) { Start-Sleep -Seconds 3 }; $ghMain = Get-GithubMain $Repo $slug }
        # merged on GitHub before this ran, GitHub's main readable, and the tested commit still not in it: a Squash or Rebase merge (new
        # commits, not the tested one), or a merge at another head. Waiting never fixes that: set aside for Jordan, nothing changed here.
        if ($state -eq 'MERGED' -and $ghMain -and -not (Test-Ancestor $Repo $tip $ghMain)) { Release-Claim; Write-Output "merge: PR #$n was merged on GitHub without the tested commit $($tip.Substring(0, 7)) (Squash or Rebase merge, or another head); the kitchen only brings home a plain merge; set aside, nothing changed here"; exit 1 }
        if (-not $ghMain -or -not (Test-Ancestor $Repo $tip $ghMain)) { Release-Claim; Rail 120; Write-Output "merge: PR #$n is merged on GitHub, but its main could not be fetched with the change yet; the real checkout is unchanged"; exit 11 }
        & git -C $Repo merge --ff-only --quiet $ghMain 2>&1 | ForEach-Object { "git: $_" }
        if ($LASTEXITCODE) { Release-Claim; Write-Output "merge: PR #$n is merged on GitHub, but the real checkout's main could not fast-forward to it; nothing changed here"; exit 10 }
        Write-Output "merge: MERGED $branch into $into at $(& git -C $Repo rev-parse --short HEAD) (PR #$n on GitHub)"
    } else {
        Wait-IfMainRed
        # claim the train before main changes: the next merge waiting on the lock sees it at once
        Set-TrainClaim $kroot $Repo $job   # (written whole: a reader never sees half of it)
        & git -C $Repo -c user.name="Jordan's Kitchen" -c user.email='kitchen@localhost' merge --no-ff --no-edit -m "Merge $branch (kitchen $job, $who)" $branch 2>&1 | ForEach-Object { "git: $_" }
        # main moved since freshen and now conflicts: not a failure of this change. Exit 11 with "needs freshen": the supervisor sends the order
        # back to its freshen step (the change is merged with the new main, tested and reviewed again, and Jordan is asked again), instead of
        # setting aside an order he already said yes to.
        if ($LASTEXITCODE) { & git -C $Repo merge --abort 2>&1 | Out-Null; Release-Claim; if ($env:KITCHEN_RUN) { Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value 60 }; Write-Output "merge: needs freshen: conflict merging $branch into $into (main moved since it was freshened); aborted, nothing changed"; exit 11 }
        Write-Output "merge: MERGED $branch into $into at $(& git -C $Repo rev-parse --short HEAD)"
    }
    $after = [string](& git -C $Repo rev-parse HEAD)
    try { Set-TrainClaim $kroot $Repo $job $after } catch { }   # hold the train until verify is done
    # TD-EH-25: how far main was from its last verified tree (kitchen/main-status.ps1 Get-VerifiedGap) when this order landed on it, measured
    # at the commit before this order's own merge (found as verify finds it; else main before this run). Said, emitted (merge.verified-gap)
    # and kept in merge.json (pastVerified: a number, or null = unknown). Any gap, or unknown, makes the verify Step's blame check (TD-EH-01)
    # mandatory: a red it cannot pin on this merge or on main before it is held for the Owner, never undone on a guess.
    $pre = $before; $m = ''
    foreach ($grep in "^Merge $branch ", "^Merge pull request #[0-9][0-9]* from [^ ]*/$branch`$") { if (-not $m) { $m = "$(& git -C $Repo log --merges --format=%H "--grep=$grep" -n 1 $after 2>$null)".Trim() } }
    if ($m -match '^[0-9a-f]{40,64}$') { $p1 = "$(& git -C $Repo rev-parse --verify --quiet "$m^1" 2>$null)".Trim(); if ($p1) { $pre = $p1 } }
    $gap = try { Get-VerifiedGap $kroot $Repo $pre } catch { @{ n = $null; why = "it could not be read ($($_.Exception.Message))" } }
    $gapText = if ($null -ne $gap.n) { "main is $($gap.n) commits past its last verified tree ($($gap.sha.Substring(0, 12)), $($gap.tested))" } else { "main's last verified tree is unknown ($($gap.why))" }
    Write-Output "merge: $gapText$(if ($null -eq $gap.n -or $gap.n -gt 0) { '; the blame check is mandatory for this Work order' })"
    try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value ([ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = 'merge.verified-gap'; job = $job; n = $gap.n; sha = [string]$gap.sha; tested = [string]$gap.tested; why = [string]$gap.why; pre = $pre } | ConvertTo-Json -Compress) -Encoding utf8 } catch { Write-Output "merge: the verified-tree gap was NOT emitted ($($_.Exception.Message))" }
    try { Write-JsonAtomic (Join-Path $kroot "results\$job.merge.json") ([ordered]@{ job = $job; before = $before; after = $after; via = $(if ($viaPr) { 'github' } else { 'local' }); at = [DateTime]::UtcNow.ToString('o'); pastVerified = $gap.n; verifiedSha = [string]$gap.sha; verifiedAt = [string]$gap.tested }) } catch { Write-Output "merge: results\$job.merge.json was NOT written ($($_.Exception.Message)); the deploy Step and the blame check will not see this merge's range" }
}
finally { try { $lock.ReleaseMutex() } catch { }; $lock.Dispose() }
# TD-EH-21: a cleanup that fails (a file held open, a locked worktree) is said in one line with git's words; the merge itself stands
function Get-GitFirstLine([object[]]$Lines) { $l = @($Lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -First 1); if ($l.Count) { $l[0] } else { "exit $LASTEXITCODE, no message" } }
$left = @()
if (Test-Path -LiteralPath $wt) {   # (a worktree already gone is not a failure)
    $wo = @(& git -C $Repo worktree remove --force $wt 2>&1)
    if ($LASTEXITCODE) { $left += "worktree $wt not removed ($(Get-GitFirstLine $wo))" }
}
$bo = @(& git -C $Repo branch -d $branch 2>&1)
if ($LASTEXITCODE) { $left += "branch $branch not deleted ($(Get-GitFirstLine $bo))" }
# the merged branch on GitHub is tidied away too (best effort: GitHub may have deleted it already; the PR keeps its commits)
if ($viaPr) { $null = Invoke-GitRemote $Repo @('push', '--quiet', (Get-GithubRemote $slug), '--delete', "refs/heads/$branch") }
if ($left.Count) { Write-Output "merge: cleanup failed: $($left -join '; ')" } else { Write-Output 'merge: worktree and branch cleaned up' }
exit 0
