# Station: open this order's pull request on GitHub, after the taster said SHIP and before Jordan is asked to merge.
# Pushes kitchen/<job> to GitHub (by explicit URL) and opens a PR against main; its body is the plan's summary, the last line of the
# test results and the job id, so Jordan can read it, and merge it, from the GitHub app too (his Merge there counts as his yes).
# Safe to re-run: an open PR for the branch is reused and the branch pushed again (a rework round adds commits). Never a force push:
# a branch someone else pushed to on GitHub is left alone and the step fails. A PR Jordan closed is never reopened by the kitchen.
# Writes the PR to <worktree>\.kitchen\PR.json and to <kitchen>\results\<job>.pr.json, the copy ci-wait, merge and automerge trust
# (outside the worktree, where AI-written code ran). A private order (never leaves this PC) or a repo with no GitHub home is skipped:
# the record says so and the order merges locally, as before. Exit 11 (try again later) when GitHub cannot be reached.
# First, the taster override (kitchen\taster-gate.ps1): final tests red (or run on another commit) = exit 1, even after a SHIP.
#   step: {"station":"pr","args":{"Repo":"{{repo}}","GitHub":"{{github}}"},"timeoutSec":300,"retries":1}
param([Parameter(Mandatory)][string]$Repo, [string]$GitHub = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\github-lib.ps1')
. (Join-Path $PSScriptRoot '..\..\scripts\secret-patterns.ps1')
. (Join-Path $PSScriptRoot '..\scope-lib.ps1')
# the github var in any form (owner/name, a github.com URL, ssh, .git): gh only ever gets owner/name; still not one = a loud stop
$ghIn = ConvertTo-GithubSlug $GitHub
if ($ghIn.bad) { Write-Output "pr: $($ghIn.bad)"; exit 2 }
$GitHub = $ghIn.slug
$job =$env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'pr: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$wt = Join-Path $kroot "worktrees\$job"; $branch = "kitchen/$job"
$statePath = Join-Path $kroot "results\$job.pr.json"; $wtPath = Join-Path $wt '.kitchen\PR.json'
function Skip([string]$why, [string]$say) {
    Write-JsonAtomic $statePath ([ordered]@{ job = $job; skipped = $true; why = $why; at = [DateTime]::UtcNow.ToString('o') })
    Remove-Item -LiteralPath $wtPath -ErrorAction SilentlyContinue
    Write-Output "pr: $say"; exit 0
}
function Later([int]$sec, [string]$say) { if ($env:KITCHEN_RUN) { Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value $sec }; Write-Output "pr: $say; trying again later"; exit 11 }
function GhFailed($r, [string]$what) {
    if (Test-GhNoLogin $r) { Write-Output "pr: gh is not signed in to GitHub ($(Get-GhWhy $r)); $what"; exit 1 }
    Later 300 "could not reach GitHub to $what ($(Get-GhWhy $r))"
}

$jj = Read-JsonFile (Join-Path $kroot "jobs\$job.json")
# the taster override (kitchen\taster-gate.ps1): a red final tests run stops the order here, whatever the taster said, private or not
. (Join-Path $PSScriptRoot '..\taster-gate.ps1')
$gate = Get-TasterGate $kroot $job $jj $Repo
if ($gate.block) { Write-Output "pr: STOPPED: $($gate.say)"; exit 1 }
Write-Output "pr: $($gate.say)"
if (Test-JobPrivate $jj) { Skip 'private' 'a private order stays on this PC: no push, no pull request (it merges locally); skipped' }
$tip = [string](& git -C $Repo rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>$null)
if ($tip -notmatch '^[0-9a-f]{40,64}$') { Write-Output "pr: branch $branch not found in $Repo"; exit 2 }
# no name on the order: the repo's own kitchen.repo.json "github" (read from its main checkout) before any guess from the folder name
if (-not $GitHub) {
    . (Join-Path $PSScriptRoot '..\repo-config.ps1')
    try { $GitHub = [string](Get-RepoConfig $Repo).Github } catch { Write-Output "pr: $($_.Exception.Message)"; exit 1 }
}
$gs = Resolve-GithubSlug $Repo $GitHub
if ($gs.bad) { Write-Output "pr: $($gs.bad)"; exit 2 }
if ($gs.none) { Skip 'none' 'no GitHub repo for this order; skipped' }
$slug = $gs.slug
$rv = Invoke-Gh @('repo', 'view', $slug, '--json', 'nameWithOwner')
if (-not $rv.ok) {
    # a derived name is only a guess: not on GitHub = this repo has no GitHub home. A name Jordan gave that is not there is a mistake.
    if (Test-GhNotFound $rv) {
        if ($gs.derived) {
            # a repo with CI workflows clearly lives on GitHub under some name: a wrong guess must not quietly skip CI and merge locally
            if (@(& git -C $Repo ls-tree -r --name-only $tip -- .github/workflows 2>$null | Where-Object { $_ -match '\.ya?ml$' }).Count) { Write-Output "pr: $slug is not on GitHub, but this repo has CI workflows; set ""github"" in its kitchen.repo.json; held for Jordan"; exit 10 }
            Skip 'none' "no GitHub repo for this order; skipped ($slug is not on GitHub)"
        }
        Write-Output "pr: the GitHub repo $slug was not found"; exit 1
    }
    GhFailed $rv "check $slug"
}

# the PRs GitHub already has for this branch: an open one is reused; one Jordan merged is recorded (the merge step syncs main);
# one he closed is his no, and stays closed
$ls = Invoke-GhJson @('pr', 'list', '-R', $slug, '--head', $branch, '--state', 'all', '--json', 'number,url,state,headRefName', '--limit', '20')
if (-not $ls.ok) { GhFailed $ls 'list its pull requests' }
$mine = @(@($ls.json) | Where-Object { $_ -and [string]$_.headRefName -eq $branch } | Sort-Object { [int]$_.number } -Descending)
$open = @($mine | Where-Object { [string]$_.state -eq 'OPEN' }) | Select-Object -First 1
$merged = @($mine | Where-Object { [string]$_.state -eq 'MERGED' }) | Select-Object -First 1
$closed = @($mine | Where-Object { [string]$_.state -eq 'CLOSED' }) | Select-Object -First 1
if (-not $open -and -not $merged -and $closed) { Write-Output "pr: Jordan closed PR #$($closed.number) on GitHub; the kitchen does not reopen it (reopen it there to go on)"; exit 1 }

$how = 'already merged on GitHub'
if (-not $merged -or $open) {
    # push first: the PR must show exactly the commit the tests and the taster passed
    $p = Invoke-GitRemote $Repo @('push', '--porcelain', (Get-GithubRemote $slug), "refs/heads/${branch}:refs/heads/$branch")
    if (-not $p.ok) {
        if ($p.text -match 'rejected|non-fast-forward|fetch first|stale info') { Write-Output "pr: GitHub's $branch has commits this branch does not (someone pushed to it); nothing overwritten"; exit 1 }
        if ($p.text -match 'Authentication failed|could not read Username|terminal prompts disabled|Permission denied|403') { Write-Output "pr: GitHub refused the push (not signed in?): $(($p.text -split "`n")[-1])"; exit 1 }
        Later 300 "could not push $branch to GitHub ($(($p.text -split "`n")[-1]))"
    }
    Remove-Item -LiteralPath (Join-Path $kroot "results\$job.ci.json") -ErrorAction SilentlyContinue   # the head moved: an old CI verdict says nothing now

    # the PR text: what the branch already says (the goal, the plan's summary, the test summary). Every line goes through the secret
    # filter, and Jordan's home folder is shortened to ~, so nothing private rides along that the branch itself does not carry.
    $home1 = [Environment]::GetFolderPath('UserProfile')
    function Clean([string]$t) { if (Find-SecretPattern $t) { return '[line left out: it looks like a secret]' }; if ($home1) { $t = $t -ireplace [regex]::Escape($home1), '~' }; $t -replace '<!--|-->', '' }
    # a roadmap item: its id leads the title (the merge commit then names it, which is how kitchen/roadmap.ps1 sees it merged)
    $ih = if ($jj -and $jj.vars -and $jj.vars.item) { @(Get-Content -LiteralPath (Join-Path $wt '.kitchen\ITEM.md') -TotalCount 1 -ErrorAction SilentlyContinue) -replace '^#\s*', '' } else { @() }
    $goal = if ($jj -and $jj.vars -and $jj.vars.goal) { [string]$jj.vars.goal } elseif ($jj -and $jj.vars -and $jj.vars.item) { $h = "$($ih | Select-Object -First 1)".Trim(); if ($h.StartsWith("$($jj.vars.item): ")) { $h } else { [string]$jj.vars.item } } elseif ($jj -and $jj.name) { ([string]$jj.name) -replace '^improve:\s*', '' } else { 'a kitchen change' }
    $g1 = (($goal -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1); if (-not $g1) { $g1 = 'a kitchen change' }; $g1 = $g1.Trim()
    if ($g1.Length -gt 72) { $g1 = $g1.Substring(0, 72).TrimEnd() + '...' }
    $title = Clean "Kitchen ${job}: $g1"
    $plan = [Collections.Generic.List[string]]::new(); $len = 0
    $pp = Join-Path $wt '.kitchen\PLAN.md'
    if (Test-Path -LiteralPath $pp) {
        foreach ($l in @(Get-Content -LiteralPath $pp)) {
            if ($l -match '^\s*PLAN READY\s*$') { continue }
            if ($len + $l.Length -gt 1800) { $plan.Add('...'); break }
            $plan.Add((Clean $l)); $len += $l.Length + 1
        }
    }
    while ($plan.Count -and -not $plan[0].Trim()) { $plan.RemoveAt(0) }
    if (-not $plan.Count) { $plan.Add('(no plan was written)') }
    $tl = @(Get-Content -LiteralPath (Join-Path $wt '.kitchen\TESTS.txt') -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) | Select-Object -Last 1
    $testLine = if ($tl) { Clean ([string]$tl).Trim() } else { '(no test results)' }
    # files scope-check added to a roadmap item's owns (kitchen/scope-lib.ps1; its trusted kitchen copy) are said in plain words
    $sc = Read-ScopeRecord $kroot $job
    $wide = if ($sc -and [string]$sc.status -eq 'ok') { @(foreach ($wf in @($sc.widened)) { Clean ([string]$wf) }) } else { @() }
    $plain = if ($wide.Count) { @('## In plain words', '', "This change also touches $($wide.Count) file(s) its roadmap item did not list: $($wide -join ', '). No other roadmap item or running order owned them, so the kitchen added them to the item's owns in $($sc.roadmap) before the build.", '') } else { @() }
    $body = @("Kitchen order **$job** (branch ``$branch``, at ``$($tip.Substring(0, 7))``).", '') + $plain + @('## Plan (summary)', '') + @($plan) +
        @('', '## Tests', '', "``$testLine``", '', "Merges only with Jordan's yes: his tap in Chef, or Merge here once CI is green. The kitchen then brings main home and checks it again.", '', "<!-- kitchen-job: $job -->")
    $bodyPath = Join-Path $wt '.kitchen\PR-BODY.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bodyPath) | Out-Null
    [IO.File]::WriteAllText($bodyPath, ($body -join "`n") + "`n", [Text.UTF8Encoding]::new($false))

    if ($open) {
        $n = [int]$open.number; $url = [string]$open.url; $how = 'reused'
        $e = Invoke-Gh @('pr', 'edit', "$n", '-R', $slug, '--body-file', $bodyPath)   # the description follows the latest push; best effort
        if (-not $e.ok) { Write-Output "pr: (the PR description was not refreshed: $(Get-GhWhy $e))" }
    } else {
        $c = Invoke-Gh @('pr', 'create', '-R', $slug, '--base', 'main', '--head', $branch, '--title', $title, '--body-file', $bodyPath)
        if (-not $c.ok) { GhFailed $c 'open the pull request' }
        $url = [string](@($c.out -split "`r?`n" | Where-Object { $_.Trim() -match '^https://github\.com/[^/\s]+/[^/\s]+/pull/\d+$' }) | Select-Object -Last 1)
        if (-not $url) { Write-Output "pr: gh did not say which pull request it opened ($(Get-GhWhy $c))"; exit 1 }
        $url = $url.Trim(); $n = [int]($url -replace '^.*/pull/', ''); $how = 'opened'
    }
} else {
    $n = [int]$merged.number; $url = [string]$merged.url
}
if ($url -ne "https://github.com/$slug/pull/$n") { Write-Output "pr: GitHub gave an unexpected address for PR #${n}: $url"; exit 1 }
$rec = [ordered]@{ job = $job; repo = $slug; number = $n; url = $url; branch = $branch; base = 'main'; head = $tip; pushedAt = [DateTime]::UtcNow.ToString('o') }
Write-JsonAtomic $statePath $rec
if (Test-Path -LiteralPath (Join-Path $wt '.kitchen')) { Write-JsonAtomic $wtPath $rec }
Write-Output "pr: PR #$n $how, at $($tip.Substring(0, 7)): $url"
exit 0
