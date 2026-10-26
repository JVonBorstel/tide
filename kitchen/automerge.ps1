# Jordan's auto-merge policy (2026-10-15: "we need to auto approve most of these"). Read-only check, called by the supervisor when an
# Improve order reaches its merge step: may it merge without his tap? Yes only when ALL hold:
#   the policy is on (kitchen.json autoMerge.on, state-folder copy wins); an improve order; not private; the last test run says
#   ALL PASS; the reviewer's last verdict is SHIP; daily cap not reached (autoMerge.perDay, default 12); no undone merge in the
#   last 24 h; the change is small (added + removed lines <= maxLines); no test file deleted; no protected file touched (the gates
#   and guards: approvals, merge, privacy and money guards, cook adapters, settings, the supervisor, all stations, step wrappers,
#   the recipe compiler and recipes, the run-bounded/secret/memory scripts, so the pipeline can never loosen its own gates on its own);
#   diff touches no login or key handling code; and adds no network call.
# Nothing here is read from the job's worktree (AI-written code runs there and could rewrite any file in it, 2026-10-18 audit):
#   the order must be built from an idea whose own record in ideas.json names this job and says source Jordan; the change is
#   measured by git itself (merge-base of the repo's HEAD and kitchen/<job>, renames off, NUL-separated paths); the test result
#   comes from <kitchen>\results\<job>.tests.json and must be for the branch tip as it is now, with no suite passing only on a retry.
# Every auto-merge is logged (automerged.jsonl) and can be undone in one tap (undo-merge.ps1).
# An order with a pull request on GitHub (the pr station's record in <kitchen>\results) also needs GitHub's CI: every check SUCCESS,
# for the very commit being merged. That look comes from <kitchen>\results\<job>.ci.json, written by the ci-wait station; when it is
# more than 90 s old it is taken again by running ci-wait bounded (60 s), so a hung network never freezes the supervisor's tick.
# Jordan's own Merge on GitHub is his yes (he authored the PR, so GitHub's approve is not his to give; Merge is): when the PR is merged
# there at exactly the tested commit, the answer is {ok, kind:'github'} whatever the policy says, and the supervisor records his yes
# (approval.kind 'github'; not an auto-merge: no automerged.jsonl line, no daily cap). -GithubOnly asks only that (an order already
# waiting for his tap in Chef).
# -ReadOnly (the supervisor's pre-scan, TARGET W2): never takes a CI look itself, so no gh and no network inside a tick. It reads the
# saved look while it is under 10 minutes old (a look is pinned to one commit, so it does not go stale by itself); older or missing
# reads as no CI result (ask Jordan). The chores (kitchen.ps1 chores) refresh the looks on a 30 s budget.
#   automerge.ps1 -Job J12 [-Json] [-GithubOnly] [-ReadOnly]   -> {ok, why[, kind]}
param([Parameter(Mandatory)][ValidatePattern('^J\d+$')][string]$Job, [switch]$Json, [switch]$GithubOnly, [switch]$ReadOnly)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
function Done([bool]$ok, [string]$why, [string]$kind = '') { $r = [ordered]@{ ok = $ok; why = $why }; if ($kind) { $r.kind = $kind }; if ($Json) { $r | ConvertTo-Json -Compress } else { "$(if ($ok) { 'AUTO' } else { 'ASK' }): $why" }; exit 0 }
. (Join-Path $PSScriptRoot 'github-lib.ps1')
# GitHub's CI on this order's PR as ci-wait last saw it; a look older than 90 s is taken again first, bounded. ci-wait runs with
# KITCHEN_JOB set and no KITCHEN_RUN (this runs inside the supervisor's process: both are put back afterwards).
function Get-CiLook([bool]$NoRefresh) {
    $cp = Join-Path $root "results\$Job.ci.json"
    $c = Read-JsonFile $cp
    $age = try { $a = $c.at; ([DateTime]::UtcNow - $(if ($a -is [DateTime]) { $a.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$a, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime })).TotalSeconds } catch { 1e9 }
    if ($NoRefresh) { if ($c -and $age -le 600 -and $age -ge -60) { return $c }; return $null }
    if (-not $c -or $age -gt 90 -or $age -lt -60) {
        $null = Invoke-CiLookBounded $root $Job 60   # (TD-EH-15: a look that fails or is cut off saves its reason in the same file)
        $c = Read-JsonFile $cp
    }
    $c
}
$prr = Read-PrRecord $root $Job
$jg = try { Get-Content -LiteralPath (Join-Path $root "jobs\$Job.json") -Raw | ConvertFrom-Json } catch { $null }
$hasPrStep = [bool]@($jg.steps | Where-Object { [string]$_.script -match '(^|[\\/])pr\.ps1$' -or [string]$_.station -eq 'pr' }).Count
if ($prr.rec -and -not $prr.rec.skipped -and -not $prr.err) {
    $gm = @($jg.steps | Where-Object { [string]$_.station -eq 'merge' -or [string]$_.script -match '(^|[\\/])merge\.ps1$' }) | Select-Object -Last 1
    $grepo = if ($gm -and $gm.args) { [string]$gm.args.Repo } else { '' }
    $gtip = if ($grepo -and (Test-Path -LiteralPath $grepo)) { [string](& git -C $grepo rev-parse --verify --quiet "refs/heads/kitchen/$Job^{commit}" 2>$null) } else { '' }
    if ($gtip -match '^[0-9a-f]{40,64}$') {
        $look = Get-CiLook $ReadOnly
        if ($look -and [string]$look.state -eq 'merged' -and [string]$look.number -eq [string]$prr.rec.number -and [string]$look.head -eq $gtip) {
            Done $true "Jordan merged PR #$($prr.rec.number) on GitHub" 'github'
        }
    }
}
if ($GithubOnly) { Done $false 'not merged on GitHub' }
$pol = @{ on = $false; perDay = 12; maxLines = 400; protect = @('^kitchen/kitchen\.ps1$', '^kitchen/kitchen\.json$', '^kitchen/automerge\.ps1$', '^kitchen/undo-merge\.ps1$',
    '^kitchen/sous-chef\.ps1$', '^kitchen/cooks/', '^kitchen/notify\.ps1$', '^kitchen/stations/', '^kitchen/recipes/',
    '^kitchen/kitchen-step\.ps1$', '^kitchen/agent-step\.ps1$', '^kitchen/cook\.ps1$',
    '^scripts/run-bounded\.ps1$', '^scripts/secret-patterns\.ps1$', '^scripts/memory-check\.ps1$',
    '^scripts/approvals\.ps1$','^AGENTS\.md$', '^\.claude/', '(^|/)\.gitignore$',
    '^kitchen/[^/]+\.ps1$', '^kitchen/[^/]+\.mjs$', '^rust/', '^pass-app/server\.mjs$', '^pass-app/public/sw\.js$', '^pass-app/update\.ps1$', '^pass-app/start-hidden\.vbs$',
    # 2026-10-18 audit: everything that runs as Jordan without a tap. scripts/ holds his Claude Code hooks (context-guard, kitchen-check,
    # boot-inject, refresh-boot), the RGB scheduled task, verify-all and what they call; pass-app/ is Chef (app.js is where his
    # approval taps happen); the agent instruction files every cook reads; kitchen config/templates; git and editor plumbing
    '^scripts/', '^pass-app/', '(^|/)(CLAUDE|GEMINI|AGENTS)\.md$', '^\.gemini/', '^\.agents?/', '^\.vscode/', '^justfile$', '(^|/)\.git',
    '^kitchen/templates/', '^kitchen/[^/]+\.(json|cmd|md|vbs|mjs|js)$', '(^|/)package(-lock)?\.json$') }   # every kitchen script and Chef's server/auth: Jordan's tap (2026-10-15 safety team)
foreach ($kp in @((Join-Path $PSScriptRoot 'kitchen.json'), (Join-Path $root 'kitchen.json'))) {
    try { $kc = Get-Content -LiteralPath $kp -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable; if ($kc.autoMerge) { foreach ($k in $kc.autoMerge.Keys) { if ($k -ne 'protect') { $pol[$k] = $kc.autoMerge[$k] } else { $pol.protect = @($pol.protect) + @($kc.autoMerge.protect) } } } } catch { }
}
if (-not $pol.on) { Done $false 'auto-merge is off' }
$logPath = Join-Path $root 'automerged.jsonl'
if (Test-Path -LiteralPath $logPath) {
    $now = [DateTime]::UtcNow
    $recentUndone = $null
    $autoMergedCount = 0
    foreach ($line in [IO.File]::ReadLines($logPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = $line | ConvertFrom-Json
            if (-not $entry) { continue }
            # ConvertFrom-Json turns ISO strings into DateTime already; stringifying that drops the zone, so use it directly
            $rawAt = if ($entry.at) { $entry.at } elseif ($entry.ts) { $entry.ts } else { $null }
            if (-not $rawAt) { continue }
            $at = if ($rawAt -is [DateTime]) { $rawAt.ToUniversalTime() }
                  else { [DateTimeOffset]::Parse([string]$rawAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime }
            $ageSec = ($now - $at).TotalSeconds
            $isUndone = [bool]$entry.undone -or [bool]$entry.'merge.undone' -or ([string]$entry.type -eq 'merge.undone') -or ([string]$entry.event -eq 'merge.undone')
            # verify writes automerge.pause when a suite on main passed only on a retry: the change may be flaky-broken, so stop for 24 h
            $isPause = [string]$entry.type -eq 'automerge.pause'
            if ($ageSec -ge -60 -and $ageSec -le 86400) {
                if ($isUndone -or $isPause) { $recentUndone = $entry }
            }
            if ($entry.job -and -not $isUndone -and -not $isPause) {
                if ($at.ToLocalTime().Date -eq (Get-Date).Date) {
                    $autoMergedCount++
                }
            }
        } catch { }
    }
    if ($recentUndone) {
        $uj = if ($recentUndone.job) { " ($($recentUndone.job))" } else { '' }
        Done $false "auto-merge paused for 24 h after $(if ([string]$recentUndone.type -eq 'automerge.pause') { 'a flaky check on main' } else { 'undone merge' })$uj"
    }
    if ($autoMergedCount -ge [int]$pol.perDay) {
        Done $false "daily auto-merge cap reached ($autoMergedCount of $($pol.perDay) today)"
    }
}
$jp = Join-Path $root "jobs\$Job.json"; if (-not (Test-Path -LiteralPath $jp)) { Done $false "no job $Job" }
$j = Get-Content -LiteralPath $jp -Raw | ConvertFrom-Json -AsHashtable
if (-not ([string]$j.recipe -eq 'improve' -or [string]$j.name -like 'improve:*')) { Done $false 'not an improve order' }
if (@($j.steps | Where-Object { $_.args.Private -eq $true }).Count -or [string]$j.vars.private -in 'yes', 'true') { Done $false 'a private order' }
# Jordan (2026-10-15): ideas from web research or AI audits are built, but only his own ideas may merge without his tap
# Fail closed (2026-10-18 audit): the goal is free text anyone can write ("(Idea I6: ..." was spoofable, and an order with no tag
# skipped this check), so the proof is the idea list itself: ideas.ps1 Build writes the job id into the idea it built. No idea that
# names this job (MCP, bot and FIX GOAL orders), or a naming idea that Jordan did not file = his tap.
$named = @(); try { $named = @(@((Get-Content -LiteralPath (Join-Path $root 'ideas.json') -Raw | ConvertFrom-Json).items) | Where-Object { $_ -and [string]$_.job -eq $Job }) } catch { }
if (-not $named.Count) { Done $false 'not built from one of Jordan''s own ideas (no idea in the list names this order)' }
foreach ($idea in $named) { if ([string]$idea.source -ne 'Jordan') { Done $false "idea $($idea.id) came from $(if ($idea.source) { $idea.source } else { 'an unknown source' }), not from Jordan" } }
# the repo and branch the merge step will merge, from the job (kitchen state folder), never from the worktree
$ms = @($j.steps | Where-Object { [string]$_.station -eq 'merge' -or [string]$_.script -match '(^|[\\/])merge\.ps1$' }) | Select-Object -Last 1
$repo = if ($ms -and $ms.args) { [string]$ms.args.Repo } else { '' }
if (-not $repo -or -not (Test-Path -LiteralPath $repo)) { Done $false 'cannot find the repository this order merges into' }
$tip = [string](& git -C $repo rev-parse --verify --quiet "refs/heads/kitchen/$Job^{commit}" 2>$null); if ($LASTEXITCODE -or $tip -notmatch '^[0-9a-f]{40,64}$') { Done $false "no branch kitchen/$Job to measure" }
$mb = [string](& git -C $repo merge-base HEAD $tip 2>$null); if ($LASTEXITCODE -or $mb -notmatch '^[0-9a-f]{40,64}$') { Done $false 'cannot find where the branch started' }
# test result: written by the tests station outside the worktree, for the exact commit it tested
$tr = $null; try { $tr = Get-Content -LiteralPath (Join-Path $root "results\$Job.tests.json") -Raw | ConvertFrom-Json } catch { }
if (-not $tr) { Done $false 'no test results' }
if ([string]$tr.final -ne 'ALL PASS') { Done $false 'the tests did not all pass' }
if ([string]$tr.sha -ne $tip) { Done $false 'the branch changed after its tests ran' }
# a suite that failed and then passed on the retry is not a clean pass: a change that breaks a test half the time would slip through
$flaky = @($tr.flaky | Where-Object { $_ }); if ($flaky.Count) { Done $false "a test failed once and passed only on a retry ($($flaky -join ', '))" }
# a pull request: GitHub's CI must be all green on it, for this exact commit (a PR with no record, or a damaged one, is Jordan's tap)
if ($prr.err) { Done $false $prr.err }
if (-not $prr.rec -and $hasPrStep) { Done $false 'it opens a pull request but has no PR record' }
if ($prr.rec -and -not $prr.rec.skipped) {
    $ci = Get-CiLook $ReadOnly; $pn = $prr.rec.number
    if ($ci -and [string]$ci.state -eq 'error') { Done $false "the last CI look on PR #$pn failed: $([string]$ci.error)" }   # TD-EH-15: the reason, never a bare "no result"
    if (-not $ci -or [string]$ci.number -ne [string]$pn) { Done $false "no CI result for PR #$pn" }
    if ([string]$ci.head -ne $tip) { Done $false "CI on PR #$pn is not for the commit being merged" }
    if ([string]$ci.state -ne 'green' -or -not $ci.allSuccess) { Done $false "CI on PR #$pn is not all green ($($ci.state)$(if (@($ci.failing).Count) { ': ' + (@($ci.failing) -join ', ') } elseif (@($ci.pending).Count) { ': ' + (@($ci.pending) -join ', ') }))" }
}
$ci = -1; for ($i = 0; $i -lt @($j.steps).Count; $i++) { if ($j.steps[$i].args.Role -eq 'check') { $ci = $i } }
$dish = Get-ChildItem -LiteralPath (Join-Path $root 'run') -Filter "$Job-s$ci-a*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
$verdict = if ($dish) { @(Select-String -LiteralPath $dish.FullName -Pattern '^VERDICT: (SHIP|REWORK)' | Select-Object -Last 1) } else { @() }
if (-not $verdict.Count -or $verdict[0].Line -notmatch '^VERDICT: SHIP - \S') { Done $false 'no SHIP verdict from the reviewer' }
# a SHIP that came after a REWORK of the same change (no rework round in between) only overrules the first reviewer: Jordan taps
$sinceRework = @(); foreach ($h in @($j.history)) { if ($h.outcome -eq 'rework') { $sinceRework = @() } elseif ([int]$h.step -eq $ci -and $h.outcome -eq 'taster' -and [string]$h.detail -like 'red flag*') { $sinceRework += $h } }
if ($sinceRework.Count) { Done $false 'the reviewer said REWORK to this same change before it said SHIP' }
# who said SHIP: only a cloud reviewer counts. The local 9b model can't open files and judges a pasted diff (J50 merged on its SHIP);
# a missing receipt or a step the sous chef saw as private is never waved through either
$rcpt = $null; try { $rcpt = Get-Content -LiteralPath ($dish.FullName -replace '\.log$', '.cost.json') -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { }
if (-not $rcpt -or -not $rcpt.supplier) { Done $false 'no receipt says which cook reviewed it' }
if ([string]$rcpt.supplier -eq 'local') { Done $false 'the review was done by the local model, not a cloud reviewer' }
if ($rcpt.private -eq $true) { Done $false 'the review step was a private order' }
# The file list comes from git, NUL-separated (no quoting of spaces or non-ASCII names) with renames off, so a rename is a delete
# plus an add and BOTH paths are checked (a renamed protected file or test suite can no longer hide behind its new name).
function Git-Z([string[]]$a) { $o = & git -C $repo -c core.quotepath=off @a 2>$null; if ($LASTEXITCODE) { Done $false 'git could not measure the change' }; (@($o) -join "`n") -split "`0" }
$raw = @(Git-Z @('diff', '--raw', '-z', '--no-renames', '--no-abbrev', $mb, $tip))
$files = [Collections.Generic.List[string]]::new(); $deletedTests = @(); $oddModes = @(); $status = @{}
for ($i = 0; $i -lt $raw.Count; $i++) {
    $t = $raw[$i].Trim("`n"); if (-not $t) { continue }
    if ($t -notmatch '^:(\d{6}) (\d{6}) [0-9a-f]+ [0-9a-f]+ ([A-Z])\d*$' -or $i + 1 -ge $raw.Count) { Done $false 'could not read the list of changed files' }   # fail closed
    $newMode = $Matches[2]; $st = $Matches[3]; $p = $raw[++$i]
    $files.Add($p); $status[$p] = $st
    if ($st -eq 'D' -and $p -match '^tests/') { $deletedTests += $p }
    if ($st -notin 'A', 'M', 'D' -or $newMode -in '120000', '160000') { $oddModes += $p }   # links, submodules, type changes
}
if (-not $files.Count) { Done $false 'no change to measure' }
if ($deletedTests.Count) { Done $false "it deletes or renames a test file ($($deletedTests -join ', '))" }
if ($oddModes.Count) { Done $false "it adds a link, submodule or type change ($($oddModes -join ', '))" }
# the repo's own protected globs (kitchen.repo.json "protected", read from the MAIN checkout by repo-config.ps1; the file itself is always in the list), on top of the kitchen's built-ins above. A config that will not load means nobody can say what is protected: ask.
. (Join-Path $PSScriptRoot 'repo-config.ps1')
try { $repoProt = @(Get-RepoProtectedRegex $repo) } catch { Done $false "this repository's kitchen.repo.json cannot be read ($($_.Exception.Message))" }
$hit = @($files | Where-Object { $f = $_; @($pol.protect | Where-Object { $f -match $_ }).Count -or @($repoProt | Where-Object { $f -match $_ }).Count } | Select-Object -Unique)
if ($hit.Count) { Done $false "it touches a protected file ($($hit -join ', '))" }
$added = 0; $removed = 0; $changedTests = @(); $bin = @()
$ns = @(Git-Z @('diff', '--numstat', '-z', '--no-renames', $mb, $tip))
foreach ($t in $ns) {
    $t = $t.Trim("`n"); if (-not $t) { continue }
    if ($t -notmatch '^(\d+|-)\t(\d+|-)\t(.+)$') { Done $false 'could not count the changed lines' }
    $p = $Matches[3]; if ($Matches[1] -eq '-') { $bin += $p; continue }
    $add1 = [int]$Matches[1]; $del1 = [int]$Matches[2]; $added += $add1; $removed += $del1   # copied out: the -match below resets $Matches
    # an existing test that loses or changes a line may have been weakened to pass: only new tests or pure additions merge alone
    if ($p -match '^tests/' -and $status[$p] -eq 'M' -and $del1 -gt 0) { $changedTests += $p }
}
if ($bin.Count) { Done $false "it changes a binary file ($($bin -join ', '))" }
if ($changedTests.Count) { Done $false "it changes or removes lines in an existing test ($($changedTests -join ', '))" }
$loginHits = [Collections.Generic.List[string]]::new()
$netHits = [Collections.Generic.List[string]]::new()
$knownHosts = @('127.0.0.1', 'localhost', '::1')
$loginRx = '(?i)\b(keyOk|authed|tailscaleUser|allowedUsers|pass-key|passKey|Set-Cookie|Content-Security-Policy|X-Frame-Options|X-Content-Type-Options|Referrer-Policy|Permissions-Policy|Strict-Transport-Security|Cross-Origin-Opener-Policy|Cross-Origin-Resource-Policy)\b'
# network, exfiltration and code-loading forms (2026-10-18 audit); a regex is never complete, the protected list is the real control
$netRx = '(?i)(\bfetch\s*\(|\bInvoke-WebRequest\b|\bInvoke-RestMethod\b|\b(iwr|irm|curl|wget)\b|Net\.WebClient|HttpClient|\bhttps?\.(request|get)\b|\bchild_process\b|\bStart-Process\b|\bgit\s+(push|fetch|clone|remote|pull)\b|\bSend-MailMessage\b' +
    '|\bnode:(net|http|https|http2|dgram|tls|dns)\b|require\(\s*[''"](net|http|https|http2|dgram|tls|dns)[''"]|from\s+[''"](net|http|https|http2|dgram|tls|dns)[''"]' +
    '|\bWebSocket\b|\bXMLHttpRequest\b|\bsendBeacon\b|\bEventSource\b|Net\.Sockets|\bWebRequest\b|Start-BitsTransfer|\bbitsadmin\b|\bcertutil\b|Resolve-DnsName|\bnslookup\b|Test-NetConnection' +
    '|\b(iex|Invoke-Expression|Invoke-Command)\b|ScriptBlock\]::Create|Win32_Process|Register-ScheduledTask|\bschtasks\b|\blocation\.(href|assign|replace)\b|\bwindow\.open\s*\(' +
    '|op\s*:\s*[''"]approve|(?<![:\w/\\])//[A-Za-z0-9-]+\.[A-Za-z]{2,})'
$content = @(& git -C $repo -c core.quotepath=off diff --no-renames --no-color --no-ext-diff --no-textconv -U0 $mb $tip 2>$null); if ($LASTEXITCODE) { Done $false 'git could not read the change' }
$inHunk = $false
foreach ($l in $content) {
    if ($l.StartsWith('diff --git ')) { $inHunk = $false; continue }   # header lines (---/+++, modes) are never counted as code
    if ($l.StartsWith('@@')) { $inHunk = $true; continue }
    if (-not $inHunk) { continue }
    $isAdd = $l.StartsWith('+'); $isDel = $l.StartsWith('-')
    if ($isAdd -or $isDel) { foreach ($m in [regex]::Matches($l, $loginRx)) { $loginHits.Add($m.Groups[1].Value) } }
    if ($isAdd) {
        if ($l -match $netRx) { $netHits.Add($Matches[1].Trim()) }
        foreach ($m in [regex]::Matches($l, '(?i)https?://(?:\[(?<host>[0-9a-fA-F:]+)\]|(?<host>[A-Za-z0-9_.-]+))')) {
            $h = $m.Groups['host'].Value.ToLowerInvariant()
            if ($knownHosts -notcontains $h) { $netHits.Add($m.Value) }
        }
    }
}
# a pure addition can still gut an existing suite: an early exit, or a Check redefined to always pass (read per file, by exact path)
foreach ($p in @($files | Where-Object { $_ -match '^tests/' -and $status[$_] -eq 'M' })) {
    $gut = @(& git -C $repo diff --no-renames --no-color --no-ext-diff -U0 $mb $tip -- ":(literal)$p" 2>$null | Where-Object { $_ -match '^\+(?!\+\+ )\s*(exit\b|function\s+Check\b|Set-Alias\b.*\bCheck\b)' })
    if ($gut.Count) { Done $false "it adds an early exit or a new Check to an existing test ($p)" }
}
if ($loginHits.Count) { Done $false "it touches login or key handling ($(@($loginHits | Select-Object -Unique) -join ', '))" }
if ($netHits.Count) { Done $false "it adds a network call ($(@($netHits | Select-Object -Unique) -join ', '))" }
if ($added + $removed -gt [int]$pol.maxLines) { Done $false "too big for auto-merge ($($added + $removed) lines changed, limit $($pol.maxLines))" }
Done $true "tests all pass, reviewer said ship, $($added + $removed) lines in $($files.Count) files, nothing protected"