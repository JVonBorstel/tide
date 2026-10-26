# GitHub plumbing for the pull-request flow: the pr, ci-wait, merge and deploy stations and automerge.ps1 dot-source this (functions only).
# gh is `gh` on PATH, or KITCHEN_GH (tests: a fake .ps1 that plays GitHub over a local bare repo, so no test ever touches the network).
# Pushes and fetches go to https://github.com/<owner>/<name>.git by explicit URL (Jordan's checkout has no 'origin' remote), or to
# KITCHEN_GITHUB_REMOTE (a remote name or URL; tests: the bare repo). Nothing here prompts: a missing login fails instead of hanging a step.

# gh, captured: {ok, code, out (stdout), err (stderr)}. Never throws (a missing gh is a failed call, not a crashed station).
function Invoke-Gh([string[]]$GhArgs) {
    $gh = if ($env:KITCHEN_GH) { $env:KITCHEN_GH } else { 'gh' }
    $env:GH_PROMPT_DISABLED = '1'; $env:GH_NO_UPDATE_NOTIFIER = '1'; $env:NO_COLOR = '1'
    # gh speaks UTF-8; a console left on the OEM code page would garble a PR title with an accent, and its JSON with it
    $enc = [Console]::OutputEncoding; try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
    try {
        $raw = if ($gh -match '\.ps1$') { & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $gh @GhArgs 2>&1 } else { & $gh @GhArgs 2>&1 }
        $code = $LASTEXITCODE
    } catch { return [pscustomobject]@{ ok = $false; code = 127; out = ''; err = "gh could not run: $($_.Exception.Message)" } }
    finally { try { [Console]::OutputEncoding = $enc } catch { } }
    $out = (@($raw | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $err = (@($raw | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { $_.Exception.Message }) -join "`n").Trim()
    [pscustomobject]@{ ok = ($code -eq 0); code = $code; out = $out; err = $err }
}
# gh with --json: the parsed answer lands in .json; output that is not JSON is a failed call (fail closed, never half-read)
function Invoke-GhJson([string[]]$GhArgs) {
    $r = Invoke-Gh $GhArgs
    $r | Add-Member -NotePropertyName json -NotePropertyValue $null -Force
    if ($r.ok) { try { $r.json = $r.out | ConvertFrom-Json -ErrorAction Stop } catch { $r.ok = $false; $r.err = 'gh did not answer with JSON' } }
    $r
}
# The author of a merge commit GitHub makes: the signed-in account's noreply address, passed as gh pr merge --author-email.
# Without it GitHub stamps the account's primary email (2026-10-26: a merge on the public tide repo carried Jordan's work address).
# KITCHEN_MERGE_EMAIL overrides. Returns $null when gh cannot say who is signed in: the caller refuses to merge (fail closed).
function Get-MergeAuthorEmail {
    if ($env:KITCHEN_MERGE_EMAIL) { return $env:KITCHEN_MERGE_EMAIL }
    $r = Invoke-GhJson @('api', 'user')
    if (-not $r.ok -or -not $r.json.id -or -not $r.json.login) { return $null }
    "$($r.json.id)+$($r.json.login)@users.noreply.github.com"
}
function Get-GhWhy($r) { $t = (("$($r.err) $($r.out)" -replace '\s+', ' ').Trim()); if ($t.Length -gt 160) { $t = $t.Substring(0, 160) + '...' }; if ($t) { $t } else { "gh exit $($r.code)" } }
# what kind of failure: the repo is not there / gh is not signed in (waiting will not help) / anything else (the network: try again later)
function Test-GhNotFound($r) { "$($r.err) $($r.out)" -match 'Could not resolve to a Repository|HTTP 404|repository not found' }
function Test-GhNoLogin($r) { "$($r.err) $($r.out)" -match 'gh auth login|not logged in|HTTP 401|Bad credentials|authentication failed|Authentication failed' }

# Which GitHub repo an order's repo lives in. The recipe var "github" names it (owner/name), or says none/off for a repo with no GitHub
# home; empty means derived: <owner>/<folder name of the repo>, owner JVonBorstel (KITCHEN_GITHUB_OWNER overrides). A derived name is
# only a guess: the pr station asks GitHub, and a repo that is not there means "no GitHub for this order" (merges stay local).
$script:GithubSlugRx = '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$'
# The "github" var in any form Jordan pastes: owner/name, https://github.com/owner/name(.git)(/), git@github.com:owner/name.git,
# ssh://git@github.com/owner/name. Gives {slug, bad}: slug = owner/name (or the value untouched when empty or none/off), bad = a loud
# reason naming the value when what is left is still not owner/name (J193 failed on 'https://github.com/JVonBorstel/demo-project').
function ConvertTo-GithubSlug([string]$GitHub) {
    $given = [string]$GitHub; $g = $given.Trim()
    if (-not $g -or $g -match '^(?i)(none|off|no|local|-)$') { return [pscustomobject]@{ slug = $g; bad = '' } }
    $g = $g -replace '^(?i)(?:(?:git\+)?(?:https?|ssh|git)://(?:[^@/]+@)?(?:www\.)?github\.com/|git@github\.com:)', ''
    $g = $g.Trim('/'); $g = ($g -replace '(?i)\.git$', '').TrimEnd('/')
    if ($g -notmatch $script:GithubSlugRx -or $g -match '\.\.') { return [pscustomobject]@{ slug = ''; bad = "github must be owner/name, a github.com URL, or none; '$given' is none of those" } }
    [pscustomobject]@{ slug = $g; bad = '' }
}
function Resolve-GithubSlug([string]$Repo, [string]$GitHub) {
    $g = ([string]$GitHub).Trim()
    if ($g -match '^(?i)(none|off|no|local|-)$') { return [pscustomobject]@{ slug = ''; none = $true; derived = $false; bad = '' } }
    $rx = $script:GithubSlugRx
    if ($g) {
        if ($g -notmatch $rx -or $g -match '\.\.') { return [pscustomobject]@{ slug = ''; none = $false; derived = $false; bad = "github must be owner/name or none, not '$g'" } }
        return [pscustomobject]@{ slug = $g; none = $false; derived = $false; bad = '' }
    }
    $top = (& git -C $Repo rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -or -not $top) { $top = $Repo }
    $name = (Split-Path -Leaf ([IO.Path]::GetFullPath($top).TrimEnd('\', '/'))) -replace '[^A-Za-z0-9._-]', '-'
    $owner = if ($env:KITCHEN_GITHUB_OWNER) { $env:KITCHEN_GITHUB_OWNER } else { 'JVonBorstel' }
    $slug = "$owner/$name"
    if ($slug -notmatch $rx) { return [pscustomobject]@{ slug = ''; none = $true; derived = $true; bad = '' } }
    [pscustomobject]@{ slug = $slug; none = $false; derived = $true; bad = '' }
}
function Get-GithubRemote([string]$Slug) { if ($env:KITCHEN_GITHUB_REMOTE) { $env:KITCHEN_GITHUB_REMOTE } else { "https://github.com/$Slug.git" } }
# git push / fetch to GitHub: never a login prompt (a scheduled task has nobody to answer it; the step would just hang to its time limit)
function Invoke-GitRemote([string]$Repo, [string[]]$GitArgs) {
    $saved = @($env:GIT_TERMINAL_PROMPT, $env:GCM_INTERACTIVE)
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
    try { $o = & git -C $Repo @GitArgs 2>&1; $code = $LASTEXITCODE } finally { $env:GIT_TERMINAL_PROMPT = $saved[0]; $env:GCM_INTERACTIVE = $saved[1] }
    [pscustomobject]@{ ok = ($code -eq 0); code = $code; text = ((@($o) | ForEach-Object { [string]$_ }) -join "`n").Trim() }
}
# GitHub's main as it is now: fetched by URL (no remote-tracking refs are made in Jordan's checkout); the sha, or '' when it failed
function Get-GithubMain([string]$Repo, [string]$Slug) {
    $f = Invoke-GitRemote $Repo @('fetch', '--no-tags', '--quiet', (Get-GithubRemote $Slug), 'refs/heads/main')
    if (-not $f.ok) { return '' }
    $sha = [string](& git -C $Repo rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>$null)
    if ($sha -match '^[0-9a-f]{40,64}$') { $sha } else { '' }
}
function Test-Ancestor([string]$Repo, [string]$Older, [string]$Newer) { & git -C $Repo merge-base --is-ancestor $Older $Newer 2>$null; $LASTEXITCODE -eq 0 }

# write-then-rename, like the supervisor's job files: a crash mid-write leaves the old record whole
function Write-JsonAtomic([string]$Path, $Obj) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $t = "$Path.tmp-$PID"; $Obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $t -Encoding utf8
    [IO.File]::Move($t, $Path, $true)
}
function Read-JsonFile([string]$Path) { try { if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } else { $null } } catch { $null } }
# TD-EH-15: a CI look that could not be taken (gh down or signed out, no PR record, a crash, the time limit) leaves its reason where a
# good look is saved: <kitchen>\results\<job>.ci.json {job, state 'error', error, at}. It replaces the last look on purpose: an old green
# must never stand in for a look that failed (automerge reads it as "the Owner taps", naming the reason; Site cleanup emits ci.look.failed).
function Save-CiLookError([string]$Kroot, [string]$Job, [string]$Why) {
    $w = ([string]$Why -replace '\s+', ' ').Trim(); if (-not $w) { $w = 'the CI look failed and gave no reason' }
    if ($w.Length -gt 200) { $w = $w.Substring(0, 200) + '...' }
    try { Write-JsonAtomic (Join-Path $Kroot "results\$Job.ci.json") ([ordered]@{ job = $Job; state = 'error'; error = $w; at = [DateTime]::UtcNow.ToString('o') }); $true } catch { $false }
}
# Runs ci-wait for one order, bounded, with KITCHEN_JOB set and no KITCHEN_RUN (both put back afterwards). A run that ended badly without
# saving a look (killed at its time limit, pwsh would not start, a crash before ci-wait could write) gets its reason saved here, so no
# failed look is silent. Exit 0 with no look is a skipped order (private, no GitHub): nothing to say. Returns {code, error ('' = none)}.
function Invoke-CiLookBounded([string]$Kroot, [string]$Job, [int]$TimeoutSeconds = 60) {
    $cp = Join-Path $Kroot "results\$Job.ci.json"
    $before = if (Test-Path -LiteralPath $cp) { (Get-Item -LiteralPath $cp).LastWriteTimeUtc } else { [DateTime]::MinValue }
    $saved = @($env:KITCHEN_JOB, $env:KITCHEN_RUN); $code = -1; $why = ''
    try {
        $env:KITCHEN_JOB = $Job; $env:KITCHEN_RUN = $null
        & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot '..\scripts\run-bounded.ps1') -Script (Join-Path $PSScriptRoot 'stations\ci-wait.ps1') -TimeoutSeconds $TimeoutSeconds 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } catch { $why = "the CI look could not run: $($_.Exception.Message)" } finally { $env:KITCHEN_JOB = $saved[0]; $env:KITCHEN_RUN = $saved[1] }
    $after = if (Test-Path -LiteralPath $cp) { (Get-Item -LiteralPath $cp).LastWriteTimeUtc } else { [DateTime]::MinValue }
    if ($code -ne 0 -and $after -le $before) {
        if (-not $why) { $why = switch ($code) { 124 { "the CI look did not finish within $TimeoutSeconds s" } 125 { 'the CI look ran out of memory' } default { "the CI look ended (exit $code) without saving a result" } } }
        $null = Save-CiLookError $Kroot $Job $why
    }
    $look = Read-JsonFile $cp
    [pscustomobject]@{ code = $code; error = $(if ($look -and [string]$look.state -eq 'error') { [string]$look.error } else { '' }) }
}

# The PR record. The pr station writes two copies: <worktree>\.kitchen\PR.json (beside the plan and tests, for people) and
# <kitchen>\results\<job>.pr.json, the one the stations and automerge trust (outside the worktree, where AI-written code ran). They must
# agree: a worktree record with no kitchen copy, or a different PR number, is refused (fail closed: Jordan looks), never followed.
# {rec, err}: rec $null = this order has no PR record at all (an order from before the PR flow: the local path).
function Read-PrRecord([string]$KitchenRoot, [string]$Job) {
    $state = Read-JsonFile (Join-Path $KitchenRoot "results\$Job.pr.json")
    $wtp = Join-Path $KitchenRoot "worktrees\$Job\.kitchen\PR.json"
    $wt = Read-JsonFile $wtp
    if (-not $state -and (Test-Path -LiteralPath (Join-Path $KitchenRoot "results\$Job.pr.json"))) { return [pscustomobject]@{ rec = $null; err = "the PR record for $Job is damaged" } }
    if (-not $state) {
        if (Test-Path -LiteralPath $wtp) { return [pscustomobject]@{ rec = $null; err = "the worktree has a PR record the kitchen did not keep (results\$Job.pr.json is missing)" } }
        return [pscustomobject]@{ rec = $null; err = '' }
    }
    if ($state.skipped) { return [pscustomobject]@{ rec = $state; err = '' } }
    $n = 0; $slug = [string]$state.repo
    if (-not [int]::TryParse([string]$state.number, [ref]$n) -or $n -le 0 -or $slug -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$' -or
        [string]$state.url -ne "https://github.com/$slug/pull/$n") { return [pscustomobject]@{ rec = $null; err = "the PR record for $Job is damaged" } }
    if ($wt -and [string]$wt.number -ne [string]$state.number) { return [pscustomobject]@{ rec = $null; err = "the PR records for $Job disagree (#$($wt.number) in the worktree, #$n in the kitchen)" } }
    [pscustomobject]@{ rec = $state; err = '' }
}

# A private order never leaves this PC: no push, no PR (its code merges locally, as before the PR flow)
function Test-JobPrivate($JobObj) {
    if (-not $JobObj) { return $false }
    if ([string]$JobObj.vars.private -in 'yes', 'true') { return $true }
    [bool]@($JobObj.steps | Where-Object { $_.args -and $_.args.Private -eq $true }).Count
}

# GitHub's statusCheckRollup in one word. CheckRun: status QUEUED/IN_PROGRESS/... until COMPLETED, then a conclusion; StatusContext
# (older status API): state PENDING/EXPECTED/SUCCESS/FAILURE/ERROR. Anything unknown counts as failed (fail closed).
#   state: failed (any failed) > pending (any not finished) > none (nothing ran, or only skipped/neutral) > green
#   allSuccess: at least one check and every one SUCCESS (what auto-merge demands; neutral or skipped is not success there)
function Get-CheckSummary($Rollup) {
    $failing = [Collections.Generic.List[string]]::new(); $pending = [Collections.Generic.List[string]]::new()
    $passed = [Collections.Generic.List[string]]::new(); $neutral = [Collections.Generic.List[string]]::new()
    foreach ($c in @($Rollup | Where-Object { $_ })) {
        $isCtx = [string]$c.__typename -eq 'StatusContext' -or ($c.context -and -not $c.status)
        $name = [string]$(if ($isCtx) { $c.context } elseif ($c.workflowName -and $c.name) { "$($c.workflowName) / $($c.name)" } else { $c.name })
        if (-not $name) { $name = 'check' }
        if ($isCtx) {
            $s = [string]$c.state
            if ($s -eq 'SUCCESS') { $passed.Add($name) } elseif ($s -in 'PENDING', 'EXPECTED') { $pending.Add($name) } else { $failing.Add($name) }
            continue
        }
        if ([string]$c.status -ne 'COMPLETED') { $pending.Add($name); continue }
        $k = [string]$c.conclusion
        if ($k -eq 'SUCCESS') { $passed.Add($name) } elseif ($k -in 'NEUTRAL', 'SKIPPED') { $neutral.Add($name) } else { $failing.Add($name) }
    }
    $count = $failing.Count + $pending.Count + $passed.Count + $neutral.Count
    $state = if ($failing.Count) { 'failed' } elseif ($pending.Count) { 'pending' } elseif (-not $passed.Count) { 'none' } else { 'green' }
    [pscustomobject]@{ state = $state; failing = @($failing); pending = @($pending); passed = @($passed); count = $count
        allSuccess = ($count -gt 0 -and $passed.Count -eq $count) }
}
