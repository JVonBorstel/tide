# Station: wait for GitHub's CI on this order's pull request (opened by the pr station) before Jordan is asked to merge.
#   CI still running (or not started yet)       -> exit 11: back on the rail in 2 minutes, no retry used
#   a check failed                               -> exit 1, naming the failing checks
#   every check passed for the branch tip        -> exit 0 (green only counts for the commit the kitchen tested, never an older push)
#   Jordan already pressed Merge on GitHub       -> exit 0 and says so (the merge step brings main home)
#   Jordan closed the PR without merging         -> exit 1 "Jordan closed the PR"
#   someone else pushed to the PR on GitHub      -> exit 1 (not the change the kitchen tested)
#   a repo with no CI workflow                   -> exit 0, "nothing to wait for" (auto-merge still needs green checks)
# Each look is saved to <kitchen>\results\<job>.ci.json {state, head, checks...}: automerge.ps1 reads that, never the network. The
# supervisor's auto-merge check also runs this (bounded, KITCHEN_JOB set, no -Repo: read from the job) to see whether CI is green or
# Jordan merged the PR on GitHub while the order waited for him.
# Safe to re-run: it only reads GitHub. An order with no GitHub repo (or a private one) has nothing to wait for: skipped, exit 0.
#   step: {"station":"ci-wait","args":{"Repo":"{{repo}}"},"timeoutSec":300,"retries":1}
param([string]$Repo = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\github-lib.ps1')
$job = $env:KITCHEN_JOB
if ($job -notmatch '^J\d+$') { Write-Output 'ci-wait: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
function Later([int]$sec, [string]$say) { if ($env:KITCHEN_RUN) { Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value $sec }; Write-Output "ci-wait: $say"; exit 11 }
# TD-EH-15: a look that could not be taken saves its reason (results\<job>.ci.json {state error, error, at}), then exits as before;
# an unexpected error anywhere does the same (the trap), so a failed look is never silent
function Fail([int]$code, [string]$say, [int]$later = 0) { $null = Save-CiLookError $kroot $job $say; if ($later) { Later $later "$say; trying again later" }; Write-Output "ci-wait: $say"; exit $code }
trap { Fail 1 "ci-wait stopped on an error: $($_.Exception.Message)" }

$pr = Read-PrRecord $kroot $job
if ($pr.err) { Fail 1 "$($pr.err)" }
if (-not $pr.rec) { Fail 1 "no PR record for $job (the pr step writes one)" }
if ($pr.rec.skipped) { Write-Output "ci-wait: $(if ([string]$pr.rec.why -eq 'private') { 'a private order has no pull request; skipped' } else { 'no GitHub repo for this order; skipped' })"; exit 0 }
$n = [int]$pr.rec.number; $slug = [string]$pr.rec.repo
if (-not $Repo) {   # the repo the order merges into, from the job (kitchen state folder), never from the worktree
    $jj = Read-JsonFile (Join-Path $kroot "jobs\$job.json")
    $Repo = [string](@($jj.steps | Where-Object { [string]$_.script -match '(^|[\\/])merge\.ps1$' -and $_.args.Repo }) | Select-Object -Last 1).args.Repo
    if (-not $Repo -or -not (Test-Path -LiteralPath $Repo)) { Fail 2 "cannot find the repository $job merges into" }
}
$tip = [string](& git -C $Repo rev-parse --verify --quiet "refs/heads/kitchen/$job^{commit}" 2>$null)
if ($tip -notmatch '^[0-9a-f]{40,64}$') { Fail 1 "branch kitchen/$job not found in $Repo" }
$v = Invoke-GhJson @('pr', 'view', "$n", '-R', $slug, '--json', 'number,state,mergedAt,mergedBy,headRefOid,statusCheckRollup')
if (-not $v.ok) {
    if (Test-GhNoLogin $v) { Fail 1 "gh is not signed in to GitHub ($(Get-GhWhy $v))" }
    Fail 11 "could not reach GitHub to read PR #$n ($(Get-GhWhy $v))" 300
}
$d = $v.json; $head = [string]$d.headRefOid; $h7 = if ($head.Length -ge 7) { $head.Substring(0, 7) } else { $head }; $t7 = $tip.Substring(0, 7)
$sum = Get-CheckSummary $d.statusCheckRollup
function Save([string]$state) {
    try {
        Write-JsonAtomic (Join-Path $kroot "results\$job.ci.json") ([ordered]@{ job = $job; number = $n; state = $state; head = $head; tip = $tip
            checks = $sum.count; passed = @($sum.passed); failing = @($sum.failing); pending = @($sum.pending); allSuccess = [bool]$sum.allSuccess
            mergedAt = [string]$d.mergedAt; mergedBy = [string]$d.mergedBy.login; at = [DateTime]::UtcNow.ToString('o') })
    } catch { Write-Output "ci-wait: (could not save the CI result: $($_.Exception.Message))" }
}
switch ([string]$d.state) {
    'MERGED' {
        # only Jordan's own Merge is his yes. A merge by anyone else (a workflow's bot token, a collaborator) is held for him: a cook's
        # workflow that merged its own PR must never count as consent. His login: KITCHEN_GITHUB_LOGIN, else the repo's owner.
        $me = if ($env:KITCHEN_GITHUB_LOGIN) { $env:KITCHEN_GITHUB_LOGIN } else { ($slug -split '/')[0] }
        $by = [string]$d.mergedBy.login
        if ($by -ne $me) { Save 'merged-by-other'; Write-Output "ci-wait: PR #$n was merged on GitHub by '$(if ($by) { $by } else { 'unknown' })', not by $me; set aside for Jordan to look at"; exit 1 }
        if ($head -ne $tip) { Save 'merged-other-head'; Write-Output "ci-wait: Jordan merged PR #$n on GitHub at $h7, which is not the kitchen's tested $t7; set aside for Jordan to look at"; exit 1 }
        Save 'merged'
        Write-Output "ci-wait: Jordan already merged PR #$n on GitHub; the merge step brings main home"; exit 0
    }
    'CLOSED' { Save 'closed'; Write-Output "ci-wait: Jordan closed the PR (#$n) on GitHub without merging it"; exit 1 }
    'OPEN' { }
    default { Save 'unknown'; Write-Output "ci-wait: PR #$n is in a state the kitchen does not know ('$($d.state)')"; exit 1 }
}
if ($head -ne $tip) {
    # GitHub still shows an older push of this branch: it catches up in a moment. Anything else on the PR is not what the kitchen tested.
    if ($head -match '^[0-9a-f]{40,64}$' -and (Test-Ancestor $Repo $head $tip)) { Save 'pending'; Later 60 "GitHub has not caught up with the last push yet (PR #$n at $h7, branch at $t7)" }
    Save 'moved'; Write-Output "ci-wait: PR #$n on GitHub is at $h7, not the kitchen's $t7 (someone pushed to it); not the change that was tested"; exit 1
}
switch ($sum.state) {
    'failed' { Save 'failed'; Write-Output "ci-wait: CI failed on PR #${n}: $($sum.failing -join ', ')"; exit 1 }
    'pending' { Save 'pending'; Later 120 "CI still running on PR #$n ($($sum.pending -join ', '))" }
    'green' { Save 'green'; Write-Output "ci-wait: CI green on PR #$n for $t7 ($($sum.passed -join ', '))"; exit 0 }
}
# no checks at all: a repo without a CI workflow has nothing to wait for; one with a workflow that never reports is a problem
$wf = @(& git -C $Repo ls-tree -r --name-only $tip -- .github/workflows 2>$null | Where-Object { $_ -match '\.ya?ml$' })
if (-not $wf.Count) { Save 'none'; Write-Output "ci-wait: no CI configured for $slug; nothing to wait for"; exit 0 }
$since = try { $pa = $pr.rec.pushedAt; if ($pa -is [DateTime]) { $pa.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$pa, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } } catch { [DateTime]::UtcNow }
if (([DateTime]::UtcNow - $since).TotalMinutes -gt 30) { Save 'none'; Write-Output "ci-wait: no CI check reported on PR #$n in 30 minutes since the push"; exit 1 }
Save 'pending'; Later 120 "CI has not started on PR #$n yet"
