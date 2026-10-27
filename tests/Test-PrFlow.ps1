# Tests for the GitHub pull-request flow: stations pr, ci-wait, merge (GitHub path), deploy, automerge's CI rule and the supervisor
# taking Jordan's Merge on GitHub as his yes. GitHub is played by a fake gh (tests/fixtures/fake-gh.ps1) over a local bare repo, so no
# test touches the network. Self-cleaning: temp kitchen root, scratch repos and the fake's state only.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path; $st = Join-Path $kd 'stations'
. (Join-Path $kd 'train.ps1')   # Get-TrainPath: the merge train is one file per repo
$root = Join-Path ([IO.Path]::GetTempPath()) ('kpr-' + [guid]::NewGuid().ToString('N'))
$kr = Join-Path $root 'kitchen'; $repo = Join-Path $root 'brain-monitor'; $bare = Join-Path $root 'github.git'; $gh = Join-Path $root 'gh'
$slug = 'JVonBorstel/brain-monitor'
# the bare repo is reached through git's ext:: transport (git runs 'git receive-pack <path>' itself): a plain path makes git start the
# MSYS sh.exe, which cannot run at Low integrity inside the kitchen's test sandbox. Turned on for this suite only (GIT_CONFIG_* env).
$remote = "ext::git %s $($bare -replace '\\', '/')"
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G { & git -C $repo -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
$pw = (Get-Process -Id $PID).Path
$script:runN = 0
# run a station for a job: its exit code, its output, and the wait it asked for (exit 11)
function Station([string]$name, [string]$job, [string[]]$more = @(), [string]$r = $repo) {
    $env:KITCHEN_JOB = $job; $script:runN++; $env:KITCHEN_RUN = Join-Path $root "run-$script:runN"
    try { $o = & $pw -NoProfile -File (Join-Path $st "$name.ps1") -Repo $r @more 2>&1 | Out-String; $c = $LASTEXITCODE }
    finally { $env:KITCHEN_JOB = $null }
    $w = if (Test-Path "$env:KITCHEN_RUN.wait") { (Get-Content "$env:KITCHEN_RUN.wait" -Raw).Trim() } else { '' }
    $env:KITCHEN_RUN = $null
    [pscustomobject]@{ code = $c; out = $o; wait = $w }
}
function JobFile([string]$id, [string]$r = $repo, [hashtable]$vars = @{ goal = "make change $id" }, [string]$status = 'running', [int]$cursor = 2, [object[]]$extra = @()) {
    $steps = @(@{ script = (Join-Path $st 'worktree.ps1'); args = @{ Repo = $r } }) + @($extra) + @(
        @{ script = (Join-Path $st 'pr.ps1'); args = @{ Repo = $r; GitHub = '' } }, @{ script = (Join-Path $st 'ci-wait.ps1'); args = @{ Repo = $r } },
        @{ script = (Join-Path $st 'merge.ps1'); args = @{ Repo = $r }; approve = $true })
    @{ id = $id; name = "improve: $id"; recipe = 'improve'; status = $status; cursor = $cursor; steps = $steps; vars = $vars; history = @() } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $kr "jobs\$id.json")
}
function NewJob([string]$id, [string]$file, [string]$r = $repo, [hashtable]$vars = @{ goal = "make change $id" }) {
    JobFile $id $r $vars
    $env:KITCHEN_JOB = $id
    & $pw -NoProfile -File (Join-Path $st 'worktree.ps1') -Repo $r | Out-Null
    $w = Join-Path $kr "worktrees\$id"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $w $file)) | Out-Null
    Set-Content (Join-Path $w $file) "edited by $id"
    & $pw -NoProfile -File (Join-Path $st 'commit.ps1') -Message "edit $id" | Out-Null
    Set-Content (Join-Path $w '.kitchen\PLAN.md') "# Plan for $id`n`nChange $file so it says who edited it.`napi_key=$('sk-' + ('abcdef0123' * 3))`nPLAN READY"
    Set-Content (Join-Path $w '.kitchen\TESTS.txt') "PASS  Test-A`nALL PASS"
    $env:KITCHEN_JOB = $null
    $w
}
function Tip([string]$id, [string]$r = $repo) { ([string](& git -C $r rev-parse "refs/heads/kitchen/$id")).Trim() }
function BareRef([string]$ref) { "$(& git -C $bare rev-parse --verify --quiet $ref 2>$null)".Trim() }
function Prs { @((Get-Content (Join-Path $gh 'prs.json') -Raw | ConvertFrom-Json).prs) }
function SetChecks([hashtable]$bySha) { $bySha | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $gh 'checks.json') }
function Run([string]$name, [string]$status, [string]$conclusion = '') { @{ __typename = 'CheckRun'; name = $name; workflowName = 'ci'; status = $status; conclusion = $conclusion } }
function JordanMerges([int]$n) { & $pw -NoProfile -File (Join-Path $PSScriptRoot 'fixtures\fake-gh.ps1') pr merge "$n" -R $slug --merge | Out-Null }
function Am([string]$id, [switch]$GithubOnly) { (& $pw -NoProfile -File (Join-Path $kd 'automerge.ps1') -Job $id -Json -GithubOnly:$GithubOnly | Out-String) | ConvertFrom-Json }
function Train { Remove-Item -LiteralPath (Get-TrainPath $kr $repo) -ErrorAction SilentlyContinue }

$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_JOB', 'KITCHEN_RUN', 'KITCHEN_GH', 'KITCHEN_GITHUB_REMOTE', 'KITCHEN_GITHUB_OWNER', 'KITCHEN_GITHUB_LOGIN', 'FAKE_GH_MERGER', 'FAKE_GH_DIR', 'FAKE_GH_BARE', 'KITCHEN_CHEF_UPDATE_SCRIPT', 'KITCHEN_CHEF_UPDATE_DRYRUN', 'BRAIN_NTFY_TOPIC', 'KITCHEN_AGY_EXE', 'KITCHEN_OLLAMA_URL', 'BRAIN_AGENT_DEPTH', 'KITCHEN_APPROVED', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $kr 'jobs'), (Join-Path $kr 'run'), $repo, $gh | Out-Null
    $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_GH = Join-Path $PSScriptRoot 'fixtures\fake-gh.ps1'; $env:FAKE_GH_DIR = $gh; $env:FAKE_GH_BARE = $bare
    $env:KITCHEN_GITHUB_REMOTE = $remote; $env:GIT_CONFIG_COUNT = '1'; $env:GIT_CONFIG_KEY_0 = 'protocol.ext.allow'; $env:GIT_CONFIG_VALUE_0 = 'always'; $env:KITCHEN_GITHUB_OWNER = $null; $env:BRAIN_NTFY_TOPIC = $null; $env:KITCHEN_AGY_EXE = 'off'; $env:KITCHEN_OLLAMA_URL = 'off'
    $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_APPROVED = $null
    Set-Content (Join-Path $gh 'repos.txt') $slug
    & git -C $repo init -q -b main 2>&1 | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $repo '.github\workflows'), (Join-Path $repo 'pass-app\public') | Out-Null
    Set-Content (Join-Path $repo '.github\workflows\ci.yml') 'name: ci'; Set-Content (Join-Path $repo 'pass-app\server.mjs') '// server'; Set-Content (Join-Path $repo 'base.txt') 'base'
    G add -A; G commit -q -m base
    & git init -q --bare -b main $bare 2>&1 | Out-Null
    G push -q $remote main

    # ---- 1. pr: push the branch, open a PR with the plan summary, test line and job id; nothing secret in it
    $w1 = NewJob 'J1' 'a.txt'; $tip1 = Tip 'J1'
    $r = Station 'pr' 'J1' @('-GitHub', '')
    Check 'pr: opens PR #1 (exit 0)' ($r.code -eq 0 -and $r.out -match 'PR #1 opened')
    Check 'pr: the branch is on GitHub at the tested commit' ((BareRef 'refs/heads/kitchen/J1') -eq $tip1)
    $rec = Get-Content (Join-Path $kr 'results\J1.pr.json') -Raw | ConvertFrom-Json
    Check 'pr: the kitchen keeps the record (number, url, repo, head)' ($rec.number -eq 1 -and $rec.url -eq "https://github.com/$slug/pull/1" -and $rec.repo -eq $slug -and $rec.head -eq $tip1)
    Check 'pr: .kitchen/PR.json in the worktree says the same' ((Get-Content (Join-Path $w1 '.kitchen\PR.json') -Raw | ConvertFrom-Json).number -eq 1)
    $p1 = @(Prs)[0]
    Check 'pr: against main from kitchen/J1, titled with the job and goal' ($p1.headRefName -eq 'kitchen/J1' -and $p1.title -eq 'Kitchen J1: make change J1')
    Check 'pr: body has the plan summary, the test line and the job id' ($p1.body -match 'Change a\.txt so it says who edited it' -and $p1.body -match 'ALL PASS' -and $p1.body -match 'kitchen-job: J1')
    Check 'pr: body leaves out a secret-looking line and the PLAN READY marker' ($p1.body -notmatch 'sk-abcdef' -and $p1.body -match 'looks like a secret' -and $p1.body -notmatch 'PLAN READY')

    # ---- 2. idempotent: run again -> the same PR; a rework commit -> pushed again, still one PR
    $r = Station 'pr' 'J1'
    Check 'pr: a second run reuses PR #1' ($r.code -eq 0 -and $r.out -match 'PR #1 reused' -and @(Prs).Count -eq 1)
    # files scope-check widened (its kitchen copy of the record, kitchen/scope-lib.ps1) are named in the PR's plain words
    Check 'pr: no widened files, no plain-words scope note' ($p1.body -notmatch 'In plain words')
    New-Item -ItemType Directory -Force -Path (Join-Path $kr 'scope') | Out-Null
    Set-Content (Join-Path $kr 'scope\J1.json') '{"job":"J1","item":"B-01","status":"ok","widened":["lib/free.ps1"],"roadmap":"map/roadmap.json"}'
    $r = Station 'pr' 'J1'
    Check 'pr: widened files are named in the plain words' ($r.code -eq 0 -and (Get-Content (Join-Path $w1 '.kitchen\PR-BODY.md') -Raw) -match '(?s)## In plain words.*1 file\(s\) its roadmap item did not list: lib/free\.ps1.*map/roadmap\.json')
    Remove-Item (Join-Path $kr 'scope\J1.json')
    $r = Station 'pr' 'J1' @('-GitHub', "https://github.com/$slug.git")
    Check 'pr: a full GitHub URL in the github var works like owner/name (J193, J269)' ($r.code -eq 0 -and $r.out -match 'PR #1 reused' -and @(Prs).Count -eq 1)
    Set-Content (Join-Path $w1 'a.txt') 'reworked'; & git -C $w1 -c user.name=t -c user.email=t@localhost commit -qam rework 2>&1 | Out-Null; $tip1 = Tip 'J1'
    $r = Station 'pr' 'J1'
    Check 'pr: rework is pushed again to the same PR' ($r.code -eq 0 -and @(Prs).Count -eq 1 -and (BareRef 'refs/heads/kitchen/J1') -eq $tip1 -and (Get-Content (Join-Path $kr 'results\J1.pr.json') -Raw | ConvertFrom-Json).head -eq $tip1)

    # ---- 2b. a branch that shares no history with main (built before main was replaced, as in the 2026-10-26 cut-over of brain-monitor to
    # the public tide): never pushed, so the old history cannot reach the new home. Held (exit 10) in one plain line; no PR, no record.
    JobFile 'J70'
    $blob = ('old history' | & git -C $repo hash-object -w --stdin); $tree = ("100644 blob $blob`told.txt" | & git -C $repo mktree)
    $orphan = (& git -C $repo -c user.name=t -c user.email=t@localhost commit-tree $tree -m 'built on the old history'); G update-ref refs/heads/kitchen/J70 $orphan
    $prsBefore = @(Prs).Count
    $r = Station 'pr' 'J70'
    $lastLine = @($r.out -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
    Check 'pr: unrelated history -> held (exit 10) with the plain hold as its last line' ($r.code -eq 10 -and $lastLine -match '^pr: HOLD: kitchen/J70 and main@\w{7} share no history' -and $lastLine -match '2026-10-26 cut-over' -and $lastLine -match 'Nothing pushed, no pull request opened')
    Check 'pr: unrelated history -> nothing pushed, no PR, no record' (-not (BareRef 'refs/heads/kitchen/J70') -and @(Prs).Count -eq $prsBefore -and -not (Test-Path (Join-Path $kr 'results\J70.pr.json')))

    # ---- 3. ci-wait: pending -> 11, failed -> 1, green for the current head -> 0
    $r = Station 'ci-wait' 'J1'
    Check 'ci-wait: no checks yet (a workflow exists) -> wait (11)' ($r.code -eq 11 -and $r.out -match 'has not started' -and $r.wait -eq '120')
    SetChecks @{ $tip1 = @((Run 'tests' 'IN_PROGRESS')) }
    $r = Station 'ci-wait' 'J1'
    Check 'ci-wait: CI running -> wait (11), back in 2 minutes' ($r.code -eq 11 -and $r.out -match 'still running' -and $r.wait -eq '120')
    Check 'ci-wait: the look is saved for automerge' ((Get-Content (Join-Path $kr 'results\J1.ci.json') -Raw | ConvertFrom-Json).state -eq 'pending')
    SetChecks @{ $tip1 = @((Run 'tests' 'COMPLETED' 'FAILURE'), (Run 'lint' 'COMPLETED' 'SUCCESS')) }
    $r = Station 'ci-wait' 'J1'
    Check 'ci-wait: a failed check -> exit 1 naming it' ($r.code -eq 1 -and $r.out -match 'CI failed on PR #1: ci / tests' -and $r.out -notmatch 'lint')
    $old = ([string](& git -C $repo rev-parse "refs/heads/kitchen/J1~1")).Trim()
    SetChecks @{ $old = @((Run 'tests' 'COMPLETED' 'SUCCESS')) }
    $r = Station 'ci-wait' 'J1'
    Check 'ci-wait: green on an older push does not count (still waiting)' ($r.code -eq 11)
    SetChecks @{ $tip1 = @((Run 'tests' 'COMPLETED' 'SUCCESS'), @{ __typename = 'StatusContext'; context = 'deploy/preview'; state = 'SUCCESS' }) }
    $r = Station 'ci-wait' 'J1'
    Check 'ci-wait: every check green for the tip -> exit 0' ($r.code -eq 0 -and $r.out -match 'CI green on PR #1')

    # ---- 4. merge through GitHub: gh pr merge pinned to the tested commit, then main fast-forwards; branch, worktree tidied
    # (first, site closed when red, TD-EH-03c: a red main status for this Tower makes it wait, exit 11, and GitHub is not asked to merge)
    . (Join-Path $kd 'main-status.ps1')
    Train; $null = Set-MainStatus $kr $repo red @('Test-VerifyCache') 'Test-VerifyCache: FAIL: train.ps1 not found' 'J9'
    $r = Station 'merge' 'J1' @('-Approved')
    Check 'merge: main red -> waits (11) naming the suites, GitHub not asked to merge' ($r.code -eq 11 -and $r.wait -eq '900' -and $r.out -match 'site closed: brain-monitor main is red since at least .*Failed: Test-VerifyCache; why: Test-VerifyCache: FAIL: train\.ps1 not found' -and -not ((Get-Content (Join-Path $gh 'calls.log') -Raw) -match 'pr merge 1 ') -and -not (Test-Path (Get-TrainPath $kr $repo)))
    $null = Set-MainStatus $kr $repo green
    Train; $before = ([string](& git -C $repo rev-parse HEAD)).Trim()
    $r = Station 'merge' 'J1' @('-Approved')
    $bm = BareRef 'refs/heads/main'
    Check 'merge: exit 0, MERGED via PR #1' ($r.code -eq 0 -and $r.out -match 'merged PR #1 here as 1001\+fake-owner@users\.noreply\.github\.com and pushed it' -and $r.out -match 'MERGED kitchen/J1 into main')
    $mc = "$(& git -C $bare log -1 --format='%P|%ae|%ce' main)"
    Check "merge: GitHub's main got one merge commit whose second parent is exactly the tested commit" (($mc -split '\|')[0] -match " $tip1$")
    Check "merge: the merge commit's author and committer are the account's noreply address, never its primary email" ($mc -like '*|1001+fake-owner@users.noreply.github.com|1001+fake-owner@users.noreply.github.com')
    Check 'merge: GitHub is never asked to merge (it would stamp the primary email)' ((Get-Content (Join-Path $gh 'calls.log') -Raw) -notmatch 'pr merge 1 ')
    Check "merge: GitHub's main has the merge with the kitchen's subject" ((& git -C $bare log -1 --format=%s main) -eq 'Merge kitchen/J1 (kitchen J1, approved by Jordan)')
    Check "merge: the real checkout's main fast-forwarded to GitHub's" (([string](& git -C $repo rev-parse HEAD)).Trim() -eq $bm -and (Get-Content (Join-Path $repo 'a.txt') -Raw) -match 'reworked')
    Check 'merge: worktree, local branch and GitHub branch cleaned up' (-not (Test-Path $w1) -and -not (& git -C $repo rev-parse --verify --quiet kitchen/J1) -and -not (BareRef 'refs/heads/kitchen/J1'))
    $mr = Get-Content (Join-Path $kr 'results\J1.merge.json') -Raw | ConvertFrom-Json
    Check 'merge: the range is recorded for deploy' ($mr.before -eq $before -and $mr.after -eq $bm -and $mr.via -eq 'github')
    Check 'merge: the train names the order that merged' ((Get-Content (Get-TrainPath $kr $repo) -Raw | ConvertFrom-Json).job -eq 'J1')

    # ---- 5. Jordan pressed Merge on GitHub: ci-wait says so, automerge reads it as his yes, merge brings main home
    Train; $w2 = NewJob 'J2' 'b.txt'; $tip2 = Tip 'J2'
    $null = Station 'pr' 'J2'; $n2 = [int](Get-Content (Join-Path $kr 'results\J2.pr.json') -Raw | ConvertFrom-Json).number
    JordanMerges $n2
    $r = Station 'ci-wait' 'J2'
    Check 'ci-wait: PR merged by Jordan on GitHub -> exit 0, says so' ($r.code -eq 0 -and $r.out -match 'Jordan already merged PR #2 on GitHub')
    Remove-Item (Join-Path $kr 'results\J2.ci.json')
    Set-Content (Join-Path $kr 'kitchen.json') '{"autoMerge":{"on":false}}'
    $a = Am 'J2'
    Check "automerge: Jordan's Merge on GitHub is his yes even with auto-merge off (kind github)" ($a.ok -and $a.kind -eq 'github' -and $a.why -match 'Jordan merged PR #2')
    Check 'automerge: -GithubOnly says the same' ((Am 'J2' -GithubOnly).kind -eq 'github')
    # dirty main: GitHub has the merge, but the real checkout cannot take it -> held for Jordan (10), nothing changed
    $h0 = ([string](& git -C $repo rev-parse HEAD)).Trim()
    Set-Content (Join-Path $repo 'base.txt') 'dirty edit'
    $r = Station 'merge' 'J2' @('-Approved')
    Check 'merge: dirty main with a PR -> held for Jordan (10), main unchanged' ($r.code -eq 10 -and $r.out -match 'uncommitted changes' -and ([string](& git -C $repo rev-parse HEAD)).Trim() -eq $h0)
    G checkout -- base.txt
    $null = Set-MainStatus $kr $repo red @('Test-VerifyCache') 'Test-VerifyCache: FAIL: train.ps1 not found' 'J9'   # (TD-EH-03c: that merge already happened)
    $r = Station 'merge' 'J2' @('-Approved')
    Remove-Item -LiteralPath (Get-MainStatusPath $kr $repo)
    Check 'merge: already merged on GitHub -> main fast-forwards, no second merge, even while main is red' ($r.code -eq 0 -and $r.out -match 'already merged on GitHub' -and ([string](& git -C $repo rev-parse HEAD)).Trim() -eq (BareRef 'refs/heads/main') -and -not ((Get-Content (Join-Path $gh 'calls.log') -Raw) -match 'pr merge 2 -R \S+ --merge --match'))
    # undo of a merge GitHub made itself (its own message) is found
    $env:KITCHEN_JOB = 'J2'; @{ id = 'J2'; status = 'done'; cursor = 5 } | ConvertTo-Json | Set-Content (Join-Path $kr 'jobs\J2.json')
    $u = (& $pw -NoProfile -File (Join-Path $kd 'undo-merge.ps1') -Job J2 -Repo $repo -Json | Out-String).Trim() | ConvertFrom-Json; $env:KITCHEN_JOB = $null
    Check "undo: finds GitHub's own merge commit for Jordan's merge" ($u.ok -and -not (Test-Path (Join-Path $repo 'b.txt')))
    Check 'undo: a PR order is undone on GitHub too (one commit on top of its main, pushed)' ($u.message -match 'pushed to GitHub' -and (BareRef 'refs/heads/main') -eq ([string](& git -C $repo rev-parse HEAD)).Trim())
    # a local-only commit (a private order merged here): GitHub's main lacks it, for section 6
    Set-Content (Join-Path $repo 'local-only.txt') 'x'; G add -A; G commit -q -m 'a private order, local only'

    # ---- 6. not a fast-forward: a local-only commit is not on GitHub -> the next PR merge is held (10), nothing merged on GitHub
    Train; $w3 = NewJob 'J3' 'c.txt'; $null = Station 'pr' 'J3'; $tip3 = Tip 'J3'; SetChecks @{ $tip3 = @((Run 'tests' 'COMPLETED' 'SUCCESS')) }
    $bm0 = BareRef 'refs/heads/main'
    $r = Station 'merge' 'J3' @('-Approved')
    Check "merge: local main has commits GitHub's does not -> held (10), nothing merged" ($r.code -eq 10 -and $r.out -match 'commits GitHub' -and (BareRef 'refs/heads/main') -eq $bm0 -and (@(Prs) | Where-Object number -eq 3).state -eq 'OPEN')
    G push -q $remote main   # Jordan pushes the local commit
    # GitHub reports a conflict -> needs freshen (11), like a local conflict
    Set-Content (Join-Path $gh 'mergeable.txt') 'CONFLICTING'
    $r = Station 'merge' 'J3' @('-Approved')
    Check 'merge: a PR that conflicts on GitHub -> needs freshen (11), nothing merged' ($r.code -eq 11 -and $r.out -match '(?m)^merge: needs freshen' -and (@(Prs) | Where-Object number -eq 3).state -eq 'OPEN')
    Remove-Item (Join-Path $gh 'mergeable.txt')
    # someone pushed to the PR on GitHub: ci-wait refuses it, merge holds
    G branch tmp kitchen/J3; G checkout -q tmp; Set-Content (Join-Path $repo 'x.txt') 'not the kitchen'; G add -A; G commit -q -m sneaky; G push -q $remote tmp:kitchen/J3; G checkout -q main; G branch -D tmp
    $r = Station 'ci-wait' 'J3'
    Check 'ci-wait: someone else pushed to the PR -> exit 1' ($r.code -eq 1 -and $r.out -match 'someone pushed')
    $r = Station 'merge' 'J3' @('-Approved')
    Check 'merge: PR head is not the tested commit -> held (10), nothing merged' ($r.code -eq 10 -and (@(Prs) | Where-Object number -eq 3).state -eq 'OPEN')
    & git -C $repo push -q -f $remote "kitchen/J3:kitchen/J3" 2>&1 | Out-Null
    $r = Station 'merge' 'J3' @('-Approved')
    Check 'merge: back at the tested commit -> merges' ($r.code -eq 0 -and $r.out -match 'MERGED kitchen/J3')

    # ---- 7. Jordan closed the PR: ci-wait 1, pr does not reopen it, merge refuses
    Train; $null = NewJob 'J4' 'd.txt'; $null = Station 'pr' 'J4'
    $db = Get-Content (Join-Path $gh 'prs.json') -Raw | ConvertFrom-Json -AsHashtable; foreach ($p in $db.prs) { if ($p.headRefName -eq 'kitchen/J4') { $p.state = 'CLOSED' } }; $db | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $gh 'prs.json')
    $r = Station 'ci-wait' 'J4'
    Check 'ci-wait: closed PR -> exit 1 "Jordan closed the PR"' ($r.code -eq 1 -and $r.out -match 'Jordan closed the PR')
    $r = Station 'pr' 'J4'
    Check 'pr: a PR Jordan closed is not reopened (exit 1)' ($r.code -eq 1 -and $r.out -match 'closed' -and @(Prs | Where-Object headRefName -eq 'kitchen/J4').Count -eq 1)
    $r = Station 'merge' 'J4' @('-Approved')
    Check 'merge: closed PR -> nothing merged (exit 1), branch kept' ($r.code -eq 1 -and (& git -C $repo rev-parse --verify --quiet kitchen/J4))

    # ---- 7b. merged on GitHub by someone else (a workflow's bot token merging its own PR): never Jordan's yes, set aside
    Train; $null = NewJob 'J21' 'i.txt'; $null = Station 'pr' 'J21'; $n9 = [int](Get-Content (Join-Path $kr 'results\J21.pr.json') -Raw | ConvertFrom-Json).number
    $env:FAKE_GH_MERGER = 'github-actions[bot]'; JordanMerges $n9; $env:FAKE_GH_MERGER = $null
    $r = Station 'ci-wait' 'J21'
    Check 'ci-wait: merged by a bot, not Jordan -> set aside (exit 1), names who' ($r.code -eq 1 -and $r.out -match "github-actions\[bot\]" -and (Get-Content (Join-Path $kr 'results\J21.ci.json') -Raw | ConvertFrom-Json).state -eq 'merged-by-other')
    $a = Am 'J21' -GithubOnly
    Check 'automerge: a bot merge is never his yes' (-not $a.ok -and $a.kind -ne 'github')
    $env:KITCHEN_GITHUB_LOGIN = 'github-actions[bot]'; Remove-Item (Join-Path $kr 'results\J21.ci.json')
    $r = Station 'ci-wait' 'J21'; $env:KITCHEN_GITHUB_LOGIN = $null
    Check 'ci-wait: KITCHEN_GITHUB_LOGIN names whose Merge counts' ($r.code -eq 0 -and $r.out -match 'already merged')
    G fetch -q $remote main; G merge -q --ff-only FETCH_HEAD   # the real checkout catches up with GitHub before the next sections

    # ---- 7c. Jordan used Squash on GitHub: the tested commit never reaches main -> set aside at once (exit 1), not a 7-hour wait
    Train; $null = NewJob 'J22' 'j.txt'; $null = Station 'pr' 'J22'; $n10 = [int](Get-Content (Join-Path $kr 'results\J22.pr.json') -Raw | ConvertFrom-Json).number
    & $pw -NoProfile -File (Join-Path $PSScriptRoot 'fixtures\fake-gh.ps1') pr merge "$n10" -R $slug --squash | Out-Null
    $h10 = ([string](& git -C $repo rev-parse HEAD)).Trim()
    $r = Station 'merge' 'J22' @('-Approved')
    Check 'merge: a Squash merge on GitHub -> set aside (exit 1), says why, main unchanged' ($r.code -eq 1 -and $r.out -match 'Squash' -and ([string](& git -C $repo rev-parse HEAD)).Trim() -eq $h10)
    G fetch -q $remote main; G merge -q --ff-only FETCH_HEAD

    # ---- 8. no GitHub home: skipped, and merge takes the local path; an explicit none and a private order never reach gh
    $other = Join-Path $root 'side-project'; New-Item -ItemType Directory -Force $other | Out-Null
    & git -C $other init -q -b main 2>&1 | Out-Null; Set-Content (Join-Path $other 'o.txt') 'o'; & git -C $other -c user.name=t -c user.email=t@localhost add -A 2>&1 | Out-Null; & git -C $other -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    Train; $null = NewJob 'J5' 'e.txt' $other
    $r = Station 'pr' 'J5' @() $other
    Check 'pr: a repo not on GitHub -> "no GitHub repo for this order; skipped" (0)' ($r.code -eq 0 -and $r.out -match 'no GitHub repo for this order; skipped' -and (Get-Content (Join-Path $kr 'results\J5.pr.json') -Raw | ConvertFrom-Json).skipped)
    $r = Station 'ci-wait' 'J5' @() $other
    Check 'ci-wait: no GitHub repo -> skipped (0)' ($r.code -eq 0 -and $r.out -match 'no GitHub repo for this order; skipped')
    $calls = @(Get-Content (Join-Path $gh 'calls.log')).Count
    $r = Station 'merge' 'J5' @('-Approved') $other
    Check 'merge: no GitHub -> the local merge, as before' ($r.code -eq 0 -and $r.out -match 'MERGED kitchen/J5' -and (& git -C $other log -1 --format=%s main) -match '^Merge kitchen/J5 \(kitchen J5' -and @(Get-Content (Join-Path $gh 'calls.log')).Count -eq $calls)
    # a repo with CI workflows whose guessed GitHub name is wrong: held, never a quiet local merge without CI
    $ciRepo = Join-Path $root 'ci-project'; New-Item -ItemType Directory -Force (Join-Path $ciRepo '.github\workflows') | Out-Null
    Set-Content (Join-Path $ciRepo '.github\workflows\ci.yml') 'name: ci'; Set-Content (Join-Path $ciRepo 'o.txt') 'o'
    foreach ($gargs in @(@('init', '-q', '-b', 'main'), @('add', '-A'), @('commit', '-q', '-m', 'base'))) { & git -C $ciRepo -c user.name=t -c user.email=t@localhost @gargs 2>&1 | Out-Null }
    Train; $null = NewJob 'J23' 'e.txt' $ciRepo
    $r = Station 'pr' 'J23' @() $ciRepo
    Check 'pr: a guessed name not on GitHub, but the repo has CI workflows -> held (10)' ($r.code -eq 10 -and $r.out -match 'CI workflows')
    # its kitchen.repo.json "github" (from the main checkout) is used before any guess
    Set-Content (Join-Path $ciRepo 'kitchen.repo.json') '{"github":"JVonBorstel/configured-name"}'
    foreach ($gargs in @(@('add', '-A'), @('commit', '-q', '-m', 'config'))) { & git -C $ciRepo -c user.name=t -c user.email=t@localhost @gargs 2>&1 | Out-Null }
    $r = Station 'pr' 'J23' @() $ciRepo
    Check 'pr: kitchen.repo.json "github" is the name asked for (not found -> exit 1, named)' ($r.code -eq 1 -and $r.out -match 'JVonBorstel/configured-name was not found' -and (Get-Content (Join-Path $gh 'calls.log') -Raw) -match 'repo view JVonBorstel/configured-name')
    $calls = @(Get-Content (Join-Path $gh 'calls.log')).Count
    $null = NewJob 'J6' 'f.txt'
    $r = Station 'pr' 'J6' @('-GitHub', 'none')
    Check 'pr: github=none -> skipped without asking GitHub' ($r.code -eq 0 -and $r.out -match 'no GitHub repo for this order; skipped' -and @(Get-Content (Join-Path $gh 'calls.log')).Count -eq $calls -and -not (BareRef 'refs/heads/kitchen/J6'))
    $null = NewJob 'J7' 'g.txt' $repo @{ goal = 'private thing'; private = 'yes' }
    $r = Station 'pr' 'J7'
    Check 'pr: a private order never leaves the PC (skipped, nothing pushed)' ($r.code -eq 0 -and $r.out -match 'private order' -and -not (BareRef 'refs/heads/kitchen/J7') -and @(Get-Content (Join-Path $gh 'calls.log')).Count -eq $calls)
    $r = Station 'pr' 'J6' @('-GitHub', 'JVonBorstel/not-there')
    Check 'pr: a GitHub repo Jordan named that does not exist -> exit 1' ($r.code -eq 1 -and $r.out -match 'not found')
    $r = Station 'pr' 'J6' @('-GitHub', 'bad slug!')
    Check 'pr: a malformed github value is refused (exit 2)' ($r.code -eq 2)
    # a PR record in the worktree that the kitchen did not write is never followed
    $null = NewJob 'J8' 'h.txt'
    @{ number = 9; url = "https://github.com/$slug/pull/9"; repo = $slug } | ConvertTo-Json | Set-Content (Join-Path $kr 'worktrees\J8\.kitchen\PR.json')
    $r = Station 'merge' 'J8' @('-Approved')
    Check 'merge: a worktree PR record with no kitchen copy -> held (10), nothing merged' ($r.code -eq 10 -and (& git -C $repo rev-parse --verify --quiet kitchen/J8))
    Remove-Item (Join-Path $kr 'worktrees\J8\.kitchen\PR.json')
    $r = Station 'merge' 'J8' @('-Approved')
    Check 'merge: an order that opens a PR but has no record -> held (10)' ($r.code -eq 10 -and $r.out -match 'no PR record')

    # ---- 9. GitHub out of reach: pr and ci-wait wait (11) instead of failing
    Set-Content (Join-Path $gh 'offline.txt') 'x'
    $r = Station 'pr' 'J8'
    Check 'pr: GitHub unreachable -> wait (11), back in 5 minutes' ($r.code -eq 11 -and $r.wait -eq '300')
    Remove-Item (Join-Path $gh 'offline.txt'); $null = Station 'pr' 'J8'; Set-Content (Join-Path $gh 'offline.txt') 'x'
    $r = Station 'ci-wait' 'J8'
    Check 'ci-wait: GitHub unreachable -> wait (11)' ($r.code -eq 11)
    $cl = try { Get-Content (Join-Path $kr 'results\J8.ci.json') -Raw | ConvertFrom-Json } catch { $null }
    Check 'TD-EH-15: ci-wait with GitHub unreachable leaves its reason (results\<job>.ci.json {state error, error, at})' ($cl.state -eq 'error' -and $cl.error -match '^could not reach GitHub to read PR #\d+ \(error connecting to api\.github\.com\)' -and $cl.at)
    Remove-Item (Join-Path $gh 'offline.txt'); Set-Content (Join-Path $gh 'signedout.txt') 'x'
    $r = Station 'ci-wait' 'J8'; $cl = try { Get-Content (Join-Path $kr 'results\J8.ci.json') -Raw | ConvertFrom-Json } catch { $null }
    Check 'TD-EH-15: ci-wait with gh signed out fails (1) and leaves that reason' ($r.code -eq 1 -and $r.out -match 'not signed in' -and $cl.state -eq 'error' -and $cl.error -match '^gh is not signed in to GitHub \(.*gh auth login')
    Remove-Item (Join-Path $gh 'signedout.txt'); Set-Content (Join-Path $gh 'offline.txt') 'x'
    Remove-Item (Join-Path $gh 'offline.txt')

    # ---- 10. automerge: an order with a PR also needs every CI check SUCCESS on it, for the commit being merged
    Set-Content (Join-Path $kr 'kitchen.json') '{"autoMerge":{"on":true}}'
    Remove-Item (Join-Path $kr 'automerged.jsonl') -ErrorAction SilentlyContinue   # the undo above would pause auto-merge for 24 h
    function AmJob([string]$id, [switch]$NoPr, [switch]$Skipped) {
        Train; $null = NewJob $id "docs/$id.md"
        JobFile $id $repo @{ goal = "docs $id" } 'pending' 4 @(@{ script = (Join-Path $kd 'agent-step.ps1'); args = @{ Role = 'check' } })
        $t = Tip $id
        $ideas = Join-Path $kr 'ideas.json'; $items = @(); if (Test-Path $ideas) { $items = @((Get-Content $ideas -Raw | ConvertFrom-Json).items) }
        @{ items = @($items) + @([pscustomobject]@{ id = "I$($items.Count + 1)"; source = 'Jordan'; job = $id }) } | ConvertTo-Json -Depth 4 | Set-Content $ideas
        New-Item -ItemType Directory -Force (Join-Path $kr 'results') | Out-Null
        @{ job = $id; sha = $t; final = 'ALL PASS'; flaky = @() } | ConvertTo-Json | Set-Content (Join-Path $kr "results\$id.tests.json")
        Set-Content (Join-Path $kr "run\$id-s1-a0.log") "# In plain words`nfine`nVERDICT: SHIP - checked the goal, tests and rules"
        @{ supplier = 'gemini'; model = 'x'; private = $false } | ConvertTo-Json | Set-Content (Join-Path $kr "run\$id-s1-a0.cost.json")
        if ($Skipped) { $null = Station 'pr' $id @('-GitHub', 'none') } elseif (-not $NoPr) { $null = Station 'pr' $id }
        $t
    }
    $t9 = AmJob 'J9'
    SetChecks @{ $t9 = @((Run 'tests' 'IN_PROGRESS')) }
    $a = Am 'J9'; Check 'automerge: CI still running -> ask Jordan' (-not $a.ok -and $a.why -match 'not all green')
    SetChecks @{ $t9 = @((Run 'tests' 'COMPLETED' 'FAILURE')) }; Remove-Item (Join-Path $kr 'results\J9.ci.json') -ErrorAction SilentlyContinue
    $a = Am 'J9'; Check 'automerge: CI failed -> ask Jordan' (-not $a.ok -and $a.why -match 'failed')
    SetChecks @{ $t9 = @((Run 'tests' 'COMPLETED' 'SUCCESS'), (Run 'docs' 'COMPLETED' 'SKIPPED')) }; Remove-Item (Join-Path $kr 'results\J9.ci.json') -ErrorAction SilentlyContinue
    $a = Am 'J9'; Check 'automerge: a skipped check is not "all success" -> ask Jordan' (-not $a.ok -and $a.why -match 'not all green')
    SetChecks @{ $t9 = @((Run 'tests' 'COMPLETED' 'SUCCESS'), (Run 'lint' 'COMPLETED' 'SUCCESS')) }; Remove-Item (Join-Path $kr 'results\J9.ci.json') -ErrorAction SilentlyContinue
    $a = Am 'J9'; Check 'automerge: every CI check SUCCESS -> may merge on its own' ($a.ok -and -not $a.kind -and $a.why -match 'tests all pass')
    Set-Content (Join-Path $gh 'signedout.txt') 'x'; Remove-Item (Join-Path $kr 'results\J9.ci.json') -ErrorAction SilentlyContinue
    $a = Am 'J9'; Remove-Item (Join-Path $gh 'signedout.txt')
    Check 'TD-EH-15: a CI look that failed (gh signed out) -> ask, naming the reason, never a bare "no CI result"' (-not $a.ok -and $a.why -match '^the last CI look on PR #\d+ failed: gh is not signed in')
    Remove-Item (Join-Path $kr 'results\J9.ci.json') -ErrorAction SilentlyContinue; $a = Am 'J9'
    Check 'TD-EH-15: the next good look replaces the failed one (may merge again)' ($a.ok -and (Get-Content (Join-Path $kr 'results\J9.ci.json') -Raw | ConvertFrom-Json).state -eq 'green')
    @{ job = 'J9'; number = 99; state = 'green'; head = $t9; allSuccess = $true; at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $kr 'results\J9.ci.json')
    $a = Am 'J9'; Check 'automerge: a CI look for another PR does not count' (-not $a.ok)
    $null = AmJob 'J10' -NoPr
    $a = Am 'J10'; Check 'automerge: an order with a pr step but no PR record -> ask' (-not $a.ok -and $a.why -match 'no PR record')
    $null = AmJob 'J11' -Skipped
    $a = Am 'J11'; Check 'automerge: no GitHub for the order -> the usual rules (no CI needed)' ($a.ok)
    Set-Content (Join-Path $kr 'kitchen.json') '{"autoMerge":{"on":false}}'

    # ---- 11. deploy: only when the verified merge changed pass-app/, and never without a passed verify
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = Join-Path $root 'fake-update.ps1'
    Set-Content $env:KITCHEN_CHEF_UPDATE_SCRIPT "param([switch]`$DryRun) Set-Content '$root\updated.txt' 'yes'; 'Chef updated (fake)'"
    function DeployJob([string]$id, [string]$before, [string]$after, [string]$verify = 'done') {
        @{ id = $id; name = "improve: $id"; recipe = 'improve'; status = 'running'; cursor = 2
            steps = @(@{ script = (Join-Path $st 'merge.ps1'); args = @{ Repo = $repo } }, @{ script = (Join-Path $st 'verify.ps1'); args = @{ Repo = $repo } }, @{ script = (Join-Path $st 'deploy.ps1'); args = @{ Repo = $repo } })
            history = @(@{ step = 0; outcome = 'done' }, @{ step = 1; outcome = $verify }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $kr "jobs\$id.json")
        @{ job = $id; before = $before; after = $after } | ConvertTo-Json | Set-Content (Join-Path $kr "results\$id.merge.json")
    }
    $b0 = ([string](& git -C $repo rev-parse HEAD)).Trim(); Set-Content (Join-Path $repo 'notes.txt') 'n'; G add -A; G commit -q -m notes; $b1 = ([string](& git -C $repo rev-parse HEAD)).Trim()
    DeployJob 'J12' $b0 $b1
    $r = Station 'deploy' 'J12'
    Check 'deploy: no pass-app change -> "deploy: nothing to deploy" (0)' ($r.code -eq 0 -and $r.out -match 'deploy: nothing to deploy' -and -not (Test-Path "$root\updated.txt"))
    Set-Content (Join-Path $repo 'pass-app\server.mjs') '// server v2'; G add -A; G commit -q -m chef; $b2 = ([string](& git -C $repo rev-parse HEAD)).Trim()
    DeployJob 'J13' $b1 $b2 'fail'
    $r = Station 'deploy' 'J13'
    Check 'deploy: verify did not pass -> nothing deployed (exit 1)' ($r.code -eq 1 -and $r.out -match 'verify did not pass' -and -not (Test-Path "$root\updated.txt"))
    DeployJob 'J13' $b1 $b2
    Remove-Item (Join-Path $kr 'results\J13.merge.json')
    $r = Station 'deploy' 'J13'
    Check 'deploy: no record of the merged range -> nothing deployed (exit 1)' ($r.code -eq 1 -and -not (Test-Path "$root\updated.txt"))
    DeployJob 'J13' $b1 $b2
    $r = Station 'deploy' 'J13'
    Check 'deploy: pass-app changed and verify passed -> runs the update (0)' ($r.code -eq 0 -and $r.out -match 'deploy: Chef updated' -and $r.out -match 'pass-app/server\.mjs' -and (Test-Path "$root\updated.txt"))
    Check 'deploy: logged as chef.updated' ((Get-Content (Join-Path $kr 'events.jsonl') -Raw) -match '"type":"chef.updated".*"after":"deploy"')
    Set-Content $env:KITCHEN_CHEF_UPDATE_SCRIPT "param([switch]`$DryRun) 'NOT UPDATED: syntax error'; exit 1"
    $r = Station 'deploy' 'J13'
    Check 'deploy: a failed update fails the step and says so' ($r.code -eq 1 -and $r.out -match 'Chef update FAILED')
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $null

    # ---- 12. the supervisor: Jordan's Merge on GitHub while the order waits for his tap is his yes; the merge then syncs main
    Train; G push -q $remote main
    foreach ($jf in Get-ChildItem (Join-Path $kr 'jobs') -Filter 'J*.json') { $o = Get-Content $jf.FullName -Raw | ConvertFrom-Json -AsHashtable; $o.status = 'done'; $o | ConvertTo-Json -Depth 8 | Set-Content $jf.FullName }   # only the new order is live
    $spec = Join-Path $root 'spec.json'
    @{ name = 'improve: supervisor case'; steps = @(@{ station = 'merge'; args = @{ Repo = $repo }; timeoutSec = 120; retries = 0 }) } | ConvertTo-Json -Depth 6 | Set-Content $spec
    $add = & $pw -NoProfile -File (Join-Path $kd 'kitchen.ps1') add -SpecPath $spec | Out-String
    $sid = if ($add -match 'added (J\d+)') { $Matches[1] } else { '' }
    Check 'supervisor: the order is added' ($sid)
    & $pw -NoProfile -File (Join-Path $kd 'kitchen.ps1') tick -Quiet | Out-Null
    Check 'supervisor: it waits for Jordan at the merge gate' ((Get-Content (Join-Path $kr "jobs\$sid.json") -Raw | ConvertFrom-Json).status -eq 'waiting-approval')
    $env:KITCHEN_JOB = $sid; & $pw -NoProfile -File (Join-Path $st 'worktree.ps1') -Repo $repo | Out-Null
    Set-Content (Join-Path $kr "worktrees\$sid\s.txt") 'supervisor case'; & $pw -NoProfile -File (Join-Path $st 'commit.ps1') -Message 'sup' | Out-Null; $env:KITCHEN_JOB = $null
    $null = Station 'pr' $sid; $sn = [int](Get-Content (Join-Path $kr "results\$sid.pr.json") -Raw | ConvertFrom-Json).number
    JordanMerges $sn
    & $pw -NoProfile -File (Join-Path $kd 'kitchen.ps1') watch -Seconds 90 -Quiet | Out-Null
    $sj = Get-Content (Join-Path $kr "jobs\$sid.json") -Raw | ConvertFrom-Json
    Check "supervisor: Jordan's Merge on GitHub is taken as his yes (approval kind github)" ($sj.approval.kind -eq 'github' -and $sj.approval.granted)
    Check 'supervisor: the merge step ran and synced main' ($sj.status -eq 'done' -and (Test-Path (Join-Path $repo 's.txt')) -and ([string](& git -C $repo rev-parse HEAD)).Trim() -eq (BareRef 'refs/heads/main'))
    Check 'supervisor: logged as approval.github, never as an auto-merge' ((Get-Content (Join-Path $kr 'events.jsonl') -Raw) -match """type"":""approval.github"",""job"":""$sid""" -and -not ((Get-Content (Join-Path $kr 'automerged.jsonl') -Raw -ErrorAction SilentlyContinue) -match """$sid"""))
    $ml = Get-ChildItem (Join-Path $kr 'run') -Filter "$sid-s0-a*.log" | Sort-Object LastWriteTime | Select-Object -Last 1
    Check 'supervisor: the merge log says who said yes' ($ml -and (Get-Content $ml.FullName -Raw) -match 'already merged on GitHub')

    # ---- 13. the improve recipe: pr and ci-wait after the taster, before merge; deploy after verify
    $rec = Get-Content (Join-Path $kd 'recipes\improve.json') -Raw | ConvertFrom-Json; $names = @($rec.steps.station)
    $ti = -1; for ($i = 0; $i -lt $names.Count; $i++) { if ($rec.steps[$i].args.Role -eq 'check') { $ti = $i } }
    Check 'recipe: taster -> pr -> ci-wait -> merge -> verify -> deploy' ($ti -gt 0 -and (($names[($ti + 1)..($names.Count - 1)]) -join ',') -eq 'pr,ci-wait,merge,verify,deploy')
    Check 'recipe: a github var (empty = derived), passed to pr; merge keeps its yes' ($null -ne $rec.vars.github -and $rec.vars.github.default -eq '' -and $rec.steps[$ti + 1].args.GitHub -eq '{{github}}' -and $rec.steps[$ti + 3].approve -eq $true)

    # ---- 14. TD-11 (Q8 = yes): a Site over its CI budget opens no NEW pull request; a raised budget or an unknown count lets it go
    $month = [DateTime]::UtcNow.ToString('yyyy-MM'); $before = @(Prs).Count
    $cbDoc = { param($at, $state) @{ month = $month; monthEnds = [DateTime]::UtcNow.AddDays(3).ToString('o'); sites = @(@{ code = 'TD'; state = $state; minutesAtLeast = $at; over = $true }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $kr 'ci-budget.json') }
    $setBudget = { param($b) @{ sites = @{ TD = @{ ciMinutesPerMonth = $b } } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $kr 'kitchen.json') }
    $null = NewJob 'J90' 'cb.txt' $repo @{ goal = 'make change J90'; site = 'TD' }
    & $cbDoc 1200 'ok'; & $setBudget 1000
    $r = Station 'pr' 'J90'
    Check 'ci budget: over budget -> no new PR, a 6-hour wait (11) with the reason' ($r.code -eq 11 -and $r.wait -eq '21600' -and $r.out -match 'Site TD is over its CI budget: at least 1200 of 1000' -and @(Prs).Count -eq $before)
    & $cbDoc $null 'unknown'
    $r = Station 'pr' 'J90'
    Check 'ci budget: an unknown count never holds by itself (the PR opens)' ($r.code -eq 0 -and $r.out -match 'opened' -and @(Prs).Count -eq $before + 1)
    $null = NewJob 'J91' 'cb2.txt' $repo @{ goal = 'make change J91'; site = 'TD' }
    & $cbDoc 1200 'ok'; & $setBudget 'unlimited'
    $r = Station 'pr' 'J91'
    Check 'ci budget: a budget raised to "unlimited" lets the new PR open at once' ($r.code -eq 0 -and $r.out -match 'opened' -and @(Prs).Count -eq $before + 2)
    & $setBudget 1000
    $r = Station 'pr' 'J91'
    Check 'ci budget: an open PR is still pushed to while over budget (only new PRs wait)' ($r.code -eq 0 -and $r.out -match 'reused')
    Remove-Item (Join-Path $kr 'kitchen.json'), (Join-Path $kr 'ci-budget.json') -ErrorAction SilentlyContinue
}
finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    foreach ($r in @($repo, (Join-Path $root 'side-project'))) { if (Test-Path -LiteralPath $r) { & git -C $r worktree prune 2>&1 | Out-Null } }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PrFlow tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
