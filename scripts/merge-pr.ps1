# How a Claude session merges a pull request: only after GitHub's CI reports green, pinned to the commit that was checked, and logged
# as a session merge. (2026-10-22: brain-monitor PR #27 merged 44 s before its CI finished, and every merge shows Jordan's account, so a
# session merge and Jordan's own tap looked the same.)
#   pwsh -File scripts/merge-pr.ps1 -Repo owner/name -Pr N [-Why text] [-DryRun] [-FixesRed]
# Site closed when red (TD-EH-03c): first of all, the Tower's main status (kitchen/main-status.ps1, written by the verify step) is read
# from the kitchen state folder. While it is red, or a status file cannot be read (unknown is not green), it refuses and names the
# suites and why: a merge onto a red main inherits the blame. -FixesRed merges anyway, for the PR that is the fix; that merge says so in
# its body and its merges.jsonl line carries fixesRed: true, mainWas (red / unknown / green / none) and mainStatus (the reason it overrode).
# No status recorded for the Tower (verify never checked its main) does not close it. The refusal names the way out: once the fix is on
# main, scripts/recheck-main.ps1 checks main again and records it green (TD-EH-03d).
# Reads the PR (gh api repos/<repo>/pulls/<n>) and every check run on its head commit (gh api .../commits/<sha>/check-runs, GitHub's
# latest run of each check). Refuses, with a plain reason and exit 1, unless: the PR is open and not a draft; at least one check
# exists; every check is completed with success, skipped or neutral; the repo's kitchen.repo.json on the PR's base branch (read from
# GitHub) has no merge freeze window covering now (kitchen/freeze-lib.ps1); and the PR's head is still that commit just before the
# merge. Then the merge commit is made here, not by GitHub (step 5 says why), as the account's noreply address from exactly that
# commit, and pushed as a fast-forward of the base (refused if the base moved), with a subject and
# body that say a Claude session merged it, and one line {pr, repo, sha, actor:'claude-session', why, at, ok[, error]} is appended to
# merges.jsonl in the kitchen state folder (BRAIN_KITCHEN, else %LOCALAPPDATA%\brain-kitchen); a failed merge is logged with its error.
# -DryRun prints the decision only (exit 0 would merge, 1 refused): nothing merged, nothing logged.
# Exit: 0 merged (or would merge), 1 refused or the merge failed (or bad arguments).
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repo,
    [Parameter(Mandatory)][ValidateRange(1, 999999)][int]$Pr,
    [string]$Why = '',
    [switch]$DryRun,
    [switch]$FixesRed
)
$ErrorActionPreference = 'Stop'
$kitchenDir = Join-Path $PSScriptRoot '..\kitchen'
. (Join-Path $kitchenDir 'github-lib.ps1')
. (Join-Path $kitchenDir 'freeze-lib.ps1')
. (Join-Path $kitchenDir 'main-status.ps1')
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$Why = ($Why -replace '[\x00-\x1f]+', ' ').Trim(); if ($Why.Length -gt 300) { $Why = $Why.Substring(0, 300) }
$okConclusions = 'success', 'skipped', 'neutral'

function Refuse([string]$reason, [string]$then = '') { Write-Output "merge-pr: REFUSED $Repo#${Pr}: $reason; nothing merged"; if ($then) { Write-Output "merge-pr: $then" }; exit 1 }
function Log-Merge([string]$sha, [bool]$ok, [string]$err) {
    $line = [ordered]@{ pr = $Pr; repo = $Repo; sha = $sha; actor = 'claude-session'; why = $Why; at = [DateTime]::UtcNow.ToString('o'); ok = $ok }
    if ($FixesRed) { $line.fixesRed = $true; $line.mainWas = $gate.state; $line.mainStatus = $gate.text }
    if ($err) { $line.error = $err }
    New-Item -ItemType Directory -Force -Path $kroot | Out-Null
    Add-Content -LiteralPath (Join-Path $kroot 'merges.jsonl') -Value ($line | ConvertTo-Json -Compress) -Encoding utf8
}
function Read-Pr {
    $r = Invoke-GhJson @('api', "repos/$Repo/pulls/$Pr")
    if (-not $r.ok) { Refuse "could not read the pull request from GitHub ($(Get-GhWhy $r))" }
    $r.json
}

# 0. site closed when red (TD-EH-03c): the Tower's main status in the kitchen state folder; red or unreadable refuses, unless -FixesRed
$statusRecs = @(Get-MainStatusForSlug $kroot $Repo); $gate = Get-MainStatusGate $statusRecs
$where = @($statusRecs | Where-Object { $_.state -eq 'red' -and $_.repo } | ForEach-Object { "'$([string]$_.repo)'" })[0]; if (-not $where) { $where = "<the Tower's checkout>" }
if ($gate.closed -and -not $FixesRed) { Refuse "site closed: $($gate.text); nothing merges into $Repo until the verify Step finds main green again (if this PR is the fix, run again with -FixesRed; it is logged as the fix)" "the way out: once the fix is on main, pwsh -File scripts/recheck-main.ps1 -Repo $where$(if ($gate.state -ne 'red') { ' -All' }) checks main again and records it green (TD-EH-03d)" }
$fixNote = if ($FixesRed -and $gate.closed) { " as the fix for a red main ($($gate.text))" } elseif ($FixesRed) { " marked -FixesRed ($($gate.text))" } else { '' }

# 1. the pull request: open, not a draft, its head commit
$p = Read-Pr
if ([string]$p.state -ne 'open') { Refuse "the pull request is $(if ($p.merged) { 'already merged' } else { "not open ($($p.state))" })" }
if ($p.draft -eq $true) { Refuse 'the pull request is a draft' }
$sha = [string]$p.head.sha; $base = [string]$p.base.ref
if ($sha -notmatch '^[0-9a-f]{40,64}$' -or -not $base) { Refuse 'GitHub did not say which commit the pull request is at' }
$short = $sha.Substring(0, 7)

# 2. a merge freeze on the base branch's kitchen.repo.json (no file there = no freeze; a file that will not load = refuse)
$cf = Invoke-Gh @('api', '-H', 'Accept: application/vnd.github.raw+json', "repos/$Repo/contents/kitchen.repo.json?ref=$([uri]::EscapeDataString($base))")
if ($cf.ok) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('merge-pr-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tmp | Out-Null
        [IO.File]::WriteAllText((Join-Path $tmp 'kitchen.repo.json'), $cf.out, [Text.UTF8Encoding]::new($false))
        $fzErr = ''; $fw = try { Get-ActiveFreeze (Read-RepoConfig $tmp).Freeze (Get-FreezeNow) } catch { $fzErr = $_.Exception.Message.Replace((Join-Path $tmp "kitchen.repo.json"), "$base on GitHub"); $null }
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    if ($fzErr) { Refuse "cannot tell whether merges into $Repo are frozen: $fzErr" }
    if ($fw) { Refuse "$Repo is $(Format-FreezeReason $fw)" }
} elseif (-not (Test-GhNotFound $cf)) { Refuse "could not read kitchen.repo.json on $base from GitHub to check for a merge freeze ($(Get-GhWhy $cf))" }

# 3. every check run on that commit: at least one, all completed, all success / skipped / neutral
$c = Invoke-GhJson @('api', "repos/$Repo/commits/$sha/check-runs?per_page=100")
if (-not $c.ok) { Refuse "could not read the CI checks on $short ($(Get-GhWhy $c))" }
$runs = @($c.json.check_runs)
if ([int]$c.json.total_count -gt $runs.Count) { Refuse "$short has $($c.json.total_count) checks, more than the $($runs.Count) one read can see" }
if (-not $runs.Count) { Refuse "no CI checks on $short yet (nothing says it works; wait for CI to start)" }
$running = @($runs | Where-Object { [string]$_.status -ne 'completed' })
if ($running.Count) { Refuse "CI is still running on ${short}: $(($running | ForEach-Object { "$($_.name) ($($_.status))" }) -join ', ')" }
$failed = @($runs | Where-Object { [string]$_.conclusion -notin $okConclusions })
if ($failed.Count) { Refuse "CI did not pass on ${short}: $(($failed | ForEach-Object { "$($_.name) ($($_.conclusion))" }) -join ', ')" }

# 4. the head must not have moved while the checks were read (a new push = checks for a commit nobody looked at)
$p2 = Read-Pr
if ([string]$p2.head.sha -ne $sha) { Refuse "the pull request moved from $short to $(([string]$p2.head.sha).Substring(0, [math]::Min(7, ([string]$p2.head.sha).Length))) while its checks were read" }
if ([string]$p2.state -ne 'open') { Refuse "the pull request is no longer open ($($p2.state))" }

$green = "all $($runs.Count) check(s) on $short green"
if ($DryRun) { Write-Output "merge-pr: DRY RUN $Repo#${Pr}: would merge at $short ($green)$fixNote; nothing merged"; exit 0 }

# 5. merge HERE, not on GitHub, pinned to the checked commit, labelled as a session merge, and logged either way.
# GitHub stamps a merge it makes with the account's primary email (2026-10-26: Jordan's work address landed on the public tide main),
# and refuses the noreply address as --author-email while "Keep my email addresses private" is off ("Invalid email address"). So the
# merge commit is made in a throwaway repo as the account's noreply address (github-lib.ps1 Get-MergeAuthorEmail), from exactly the
# checked commit, and pushed as a fast-forward of the base branch: a base that moved meanwhile is refused by the push, never
# overwritten. GitHub then marks the pull request merged by itself (its head commit is in the base).
$body = "Merged by a Claude session (scripts/merge-pr.ps1), not by Jordan's tap, after $green$fixNote.$(if ($Why) { " Why: $Why" })"
$subject = "Merge pull request #$Pr from $($p.head.ref) (Claude session)"
$who = Get-MergeAuthorEmail
if (-not $who) { Refuse "gh could not say which account is signed in, so the merge commit's author email is unknown (it must be the noreply address)" }
$name = if ($who -match '^\d+\+([^@]+)@users\.noreply\.github\.com$') { $Matches[1] } else { 'Claude session' }
$remote = Get-GithubRemote $Repo
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('merge-pr-' + [guid]::NewGuid().ToString('N'))
function Git-Here([string[]]$GitArgs) { $o = & git -C $tmp -c "user.name=$name" -c "user.email=$who" @GitArgs 2>&1; [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); out = (($o | ForEach-Object { "$_" }) -join ' ').Trim() } }
$err = ''
try {
    & git init -q $tmp 2>&1 | Out-Null
    $f = Git-Here @('fetch', '-q', '--no-tags', $remote, "+refs/heads/${base}:refs/remotes/base", "+refs/pull/$Pr/head:refs/remotes/pr")
    if (-not $f.ok) { $err = "could not fetch $base and the pull request ($($f.out))" }
    elseif ("$(& git -C $tmp rev-parse refs/remotes/pr 2>$null)".Trim() -ne $sha) { $err = "the pull request on GitHub is no longer at $short" }
    else {
        $null = Git-Here @('checkout', '-q', '--detach', 'refs/remotes/base')
        $mg = Git-Here @('merge', '--no-ff', '-q', '-m', $subject, '-m', $body, $sha)
        if (-not $mg.ok) { $err = "$short does not merge cleanly into $base (conflicts); freshen the branch first" }
        else {
            $ps = Git-Here @('push', '-q', $remote, "HEAD:refs/heads/$base")
            if (-not $ps.ok) { $err = "the push to $base was refused, so nothing changed (did $base move meanwhile?): $($ps.out)" }
        }
    }
    $mc = if (-not $err) { "$(& git -C $tmp rev-parse --short HEAD 2>$null)".Trim() } else { '' }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
if ($err) { if ($err.Length -gt 300) { $err = $err.Substring(0, 300) + '...' }; Log-Merge $sha $false $err; Write-Output "merge-pr: FAILED $Repo#${Pr}: $err; logged"; exit 1 }
Log-Merge $sha $true ''
Write-Output "merge-pr: MERGED $Repo#$Pr at $short ($green)$fixNote as merge commit $mc by $who; logged as claude-session$(if ($FixesRed) { ', fixesRed' })"
exit 0
