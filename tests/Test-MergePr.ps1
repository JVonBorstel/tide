# Tests for scripts/merge-pr.ps1 (how a Claude session merges a PR: only after CI is green, pinned to the checked commit, logged as
# actor claude-session in merges.jsonl; never onto a red or unknown main unless -FixesRed, TD-EH-03c). A fake gh (gh.cmd running a node script) is first on PATH and plays GitHub from a scenario file: no network.
# Self-cleaning: a scratch folder under TEMP only.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\scripts\merge-pr.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('mpr-' + [guid]::NewGuid().ToString('N'))
$bin = Join-Path $root 'bin'; $kr = Join-Path $root 'kitchen'; $log = Join-Path $kr 'merges.jsonl'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
# A real repo stands in for GitHub's git side (the merge commit is made locally and pushed, merge-pr.ps1 step 5): main at $M, the PR's
# commits $A then $B; a pre-receive hook refuses every push while pushfail.txt exists (the base moved meanwhile).
$src = Join-Path $root 'src'; $bare = Join-Path $root 'gh.git'
New-Item -ItemType Directory -Force -Path $src | Out-Null
function G { & git -C $src -c user.name=t -c user.email=t@example.invalid @args 2>&1 | Out-Null }
& git init -q -b main $src 2>&1 | Out-Null
Set-Content "$src\a.txt" 'base'; G add -A; G commit -q -m base; $M = "$(& git -C $src rev-parse HEAD)".Trim()
G checkout -q -b feature; Set-Content "$src\b.txt" 'feature'; G add -A; G commit -q -m feature; $A = "$(& git -C $src rev-parse HEAD)".Trim()
Set-Content "$src\c.txt" 'more'; G add -A; G commit -q -m more; $B = "$(& git -C $src rev-parse HEAD)".Trim()
& git clone -q --bare $src $bare 2>&1 | Out-Null
[IO.File]::WriteAllText((Join-Path $bare 'hooks\pre-receive'), "#!/bin/sh`nif [ -f `"`$FAKE_GH_DIR/pushfail.txt`" ]; then echo 'rejected: main moved' >&2; exit 1; fi`nexit 0`n")
function MainNow { "$(& git -C $bare rev-parse refs/heads/main)".Trim() }
function MergeCommit { "$(& git -C $bare log -1 --format='%P|%ae|%ce|%s|%b' refs/heads/main)" }
$green = @(@{ name = 'checks'; status = 'completed'; conclusion = 'success' }, @{ name = 'lint'; status = 'completed'; conclusion = 'skipped' }, @{ name = 'notes'; status = 'completed'; conclusion = 'neutral' })
$fake = @'
// fake gh for Test-MergePr.ps1 (node: starts in a tenth of the time pwsh does). Plays GitHub from scenario.json; logs every call.
const fs = require('fs'), path = require('path');
const a = process.argv.slice(2), d = process.env.FAKE_GH_DIR, f = (n) => path.join(d, n);
const s = JSON.parse(fs.readFileSync(f('scenario.json'), 'utf8').replace(/^\uFEFF/, ''));
fs.appendFileSync(f('calls.log'), a.join(' ') + '\n');
const heads = [].concat(s.heads), out = (x) => process.stdout.write(typeof x === 'string' ? x : JSON.stringify(x)), err = (m, c) => { process.stderr.write(m + '\n'); process.exitCode = c; };
if (a[0] === 'api' && a[1] === 'user') { if (s.noUser) err('gh: Requires authentication (HTTP 401)', 1); else out({ id: 1001, login: 'fake-owner' }); }
else if (a[0] === 'api') {
  const ep = a.find((x) => x.startsWith('repos/')) || '';
  if (/\/pulls\/\d+$/.test(ep)) {
    let n = 0; try { n = Number(fs.readFileSync(f('pulls.count'), 'utf8')); } catch {} fs.writeFileSync(f('pulls.count'), String(n + 1));
    out({ state: s.state, merged: !!s.merged, draft: !!s.draft, head: { sha: heads[Math.min(n, heads.length - 1)], ref: 'feature' }, base: { ref: 'main' } });
  } else if (/\/check-runs/.test(ep)) { const runs = [].concat(s.checks || []); out({ total_count: s.total ?? runs.length, check_runs: runs }); }
  else if (/\/contents\/kitchen\.repo\.json/.test(ep)) { if (!s.config) { out('{"message":"Not Found","status":"404"}'); err('gh: Not Found (HTTP 404)', 1); } else out(s.config); }
  else err('fake gh: unknown endpoint ' + ep, 3);
} else if (a[0] === 'pr' && a[1] === 'merge') {
  err('fake gh: merge-pr.ps1 must not ask GitHub to merge (GitHub would stamp the primary email)', 3);
} else err('fake gh: unknown call ' + a.join(' '), 3);
'@
function Scenario([hashtable]$s) {
    $d = @{ state = 'open'; merged = $false; draft = $false; heads = @($A); checks = $green; config = $null }; foreach ($k in $s.Keys) { $d[$k] = $s[$k] }
    $d | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $bin 'scenario.json') -Encoding utf8
    foreach ($f in 'pulls.count', 'pushfail.txt', 'calls.log') { Remove-Item (Join-Path $bin $f) -ErrorAction SilentlyContinue }
    & git -C $bare update-ref refs/heads/main $M; & git -C $bare update-ref refs/pull/7/head @($d.heads)[-1]
    if ($s.pushFail) { Set-Content (Join-Path $bin 'pushfail.txt') 'x' }
    Remove-Item $log -ErrorAction SilentlyContinue
}
function Run([hashtable]$more = @{}) {
    $o = & $script -Repo "JVonBorstel/demo" -Pr 7 @more *>&1 | Out-String   # in this process: exit inside the script returns here
    [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE; Merged = ((MainNow) -ne $M); Log = @(if (Test-Path $log) { Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json } }) }
}
$old = @{ path = $env:PATH; k = $env:BRAIN_KITCHEN; gh = $env:KITCHEN_GH; d = $env:FAKE_GH_DIR; n = $env:KITCHEN_FREEZE_NOW; r = $env:KITCHEN_GITHUB_REMOTE }
$env:KITCHEN_GITHUB_REMOTE = $bare
try {
    New-Item -ItemType Directory -Force -Path $bin, $kr | Out-Null
    Set-Content (Join-Path $bin 'fake-gh.js') $fake -Encoding utf8
    Set-Content (Join-Path $bin 'gh.cmd') "@node `"%~dp0fake-gh.js`" %*" -Encoding ascii
    $env:PATH = "$bin;$env:PATH"; $env:KITCHEN_GH = $null; $env:FAKE_GH_DIR = $bin; $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_FREEZE_NOW = '2026-10-22T12:00'
    Check 'the fake gh is the one first on PATH' ((Get-Command gh).Source -eq (Join-Path $bin 'gh.cmd'))

    Scenario @{}; $r = Run @{ Why = 'CI green, Jordan asked for it' }
    $call = if ($r.Merged) { MergeCommit } else { '' }
    Check 'all checks green: merges' ($r.Code -eq 0 -and $r.Merged -and $r.Out -match 'MERGED JVonBorstel/demo#7' -and $r.Out -match 'all 3 check')
    Check 'all checks green: one merge commit of main and exactly the checked head, labelled a Claude session merge' ($call -like "$M $A|*" -and $call -match '\(Claude session\)' -and $call -match 'Merged by a Claude session')
    Check 'GitHub is never asked to merge (it would stamp the primary email)' ((Get-Content (Join-Path $bin 'calls.log') -Raw) -notmatch 'pr merge')
    Check 'all checks green: logs pr, repo, sha, actor claude-session, why, at' ($r.Log.Count -eq 1 -and $r.Log[0].pr -eq 7 -and $r.Log[0].repo -eq 'JVonBorstel/demo' -and $r.Log[0].sha -eq $A -and $r.Log[0].actor -eq 'claude-session' -and $r.Log[0].why -eq 'CI green, Jordan asked for it' -and $r.Log[0].at -and $r.Log[0].ok -eq $true)

    Check "all checks green: the merge commit's author and committer are the account's noreply address, never its primary email" ($call -like '*|1001+fake-owner@users.noreply.github.com|1001+fake-owner@users.noreply.github.com|*')
    Scenario @{ noUser = $true }; $r = Run
    Check 'gh cannot say who is signed in: refuses (author email unknown), nothing merged' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'REFUSED' -and $r.Out -match 'noreply')

    Scenario @{ checks = @($green[0], @{ name = 'windows-suite'; status = 'in_progress'; conclusion = $null }) }; $r = Run
    Check 'a running check refuses' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'REFUSED' -and $r.Out -match 'still running.*windows-suite \(in_progress\)' -and $r.Log.Count -eq 0)

    Scenario @{ checks = @($green[0], @{ name = 'windows-suite'; status = 'completed'; conclusion = 'failure' }) }; $r = Run
    Check 'a failed check refuses' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'did not pass.*windows-suite \(failure\)')
    Scenario @{ checks = @(@{ name = 'checks'; status = 'completed'; conclusion = 'cancelled' }) }; $r = Run
    Check 'a cancelled check refuses too (only success, skipped, neutral pass)' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'checks \(cancelled\)')

    Scenario @{ checks = @() }; $r = Run
    Check 'no checks refuses' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'no CI checks')
    Scenario @{ total = 150 }; $r = Run
    Check 'more checks than one read sees refuses' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match '150 checks')

    Scenario @{}; $r = Run @{ ExpectHead = $A.Substring(0, 12) }
    Check '-ExpectHead at the head: merges exactly that commit' ($r.Code -eq 0 -and $r.Merged -and (MergeCommit) -like "$M $A|*")
    Scenario @{}; $r = Run @{ ExpectHead = $B }
    Check '-ExpectHead not the head: refuses (a commit nobody reviewed), nothing merged or logged' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'not at the reviewed commit' -and $r.Log.Count -eq 0)
    Scenario @{ heads = @($A, $B) }; $r = Run
    Check 'a head sha that moved refuses' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match "moved from $($A.Substring(0, 7)) to $($B.Substring(0, 7))")

    Scenario @{ pushFail = $true }; $r = Run
    Check 'a refused push (the base moved) is a failed merge, logged with its error; main untouched' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'FAILED' -and $r.Log.Count -eq 1 -and $r.Log[0].ok -eq $false -and $r.Log[0].error -match 'push to main was refused' -and $r.Log[0].actor -eq 'claude-session')
    Scenario @{ heads = @($A) }; & git -C $bare update-ref refs/pull/7/head $B; $r = Run
    Check 'GitHub says one head but the pull ref holds another: refuses to merge an unchecked commit' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match "no longer at $($A.Substring(0, 7))")

    Scenario @{}; $r = Run @{ DryRun = $true }
    Check '-DryRun never merges (prints the decision, logs nothing)' ($r.Code -eq 0 -and -not $r.Merged -and $r.Out -match 'DRY RUN.*would merge' -and $r.Log.Count -eq 0 -and -not ((Get-Content (Join-Path $bin 'calls.log') -Raw) -match 'pr merge'))
    Scenario @{ checks = @() }; $r = Run @{ DryRun = $true }
    Check '-DryRun prints a refusal too' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'REFUSED')

    Scenario @{ state = 'closed'; merged = $true }; $r = Run
    Check 'an already merged PR refuses' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'already merged')
    Scenario @{ draft = $true }; $r = Run
    Check 'a draft PR refuses' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'draft')

    # the repo's merge freeze (kitchen.repo.json on the base branch, as GitHub has it)
    $fz = '{"freeze":[{"from":"2026-10-27T00:00","to":"2026-10-28T18:00","why":"release demo"}]}'
    $env:KITCHEN_FREEZE_NOW = '2026-10-28T13:00'; Scenario @{ config = $fz }; $r = Run
    Check 'inside a freeze window refuses with the reason' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'frozen until 10-28 18:00: release demo')
    $env:KITCHEN_FREEZE_NOW = '2026-10-28T18:00'; Scenario @{ config = $fz }; $r = Run
    Check 'after the freeze window merges' ($r.Code -eq 0 -and $r.Merged)
    Scenario @{ config = '{"freeze":[{"from":"2026-10-27T00:00","to":"later","why":"x"}]}' }; $r = Run
    Check 'a malformed freeze refuses naming the field' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match "'freeze\[0\]\.to'" -and $r.Out -match 'main on GitHub')
    # Site-closed windows (TD-9) from the Sites registry (kitchen.json "sites" in the kitchen state folder), for a Tower whose config names its Site
    $kj = Join-Path $kr 'kitchen.json'; $env:KITCHEN_FREEZE_NOW = '2026-10-29T12:00'
    Scenario @{ config = '{"site":"TD"}' }; $r = Run
    Check 'Site-closed: no registry, a Tower with a Site merges as before' ($r.Code -eq 0 -and $r.Merged)
    Set-Content $kj '{"sites":{"TD":{"closed":[{"from":"2026-10-29T00:00","to":"2026-10-30T12:00","why":"release"}]}}}' -Encoding utf8
    Scenario @{ config = '{"site":"TD"}' }; $r = Run
    Check "Site-closed: inside its Site's window refuses, naming the Site" ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'frozen until 10-30 12:00: release \(Site TD closed\)')
    Scenario @{ config = '{"site":"GW"}' }; $r = Run
    Check "Site-closed: another Site's window never closes this Tower" ($r.Code -eq 0 -and $r.Merged)
    Scenario @{ config = $null }; $r = Run
    Check 'Site-closed: a Tower with no kitchen.repo.json (no Site) merges' ($r.Code -eq 0 -and $r.Merged)
    $env:KITCHEN_FREEZE_NOW = '2026-10-30T12:00'; Scenario @{ config = '{"site":"TD"}' }; $r = Run
    Check "Site-closed: after the Site's window merges" ($r.Code -eq 0 -and $r.Merged)
    Set-Content $kj '{"sites": [' -Encoding utf8
    Scenario @{ config = '{"site":"TD"}' }; $r = Run
    Check 'Site-closed: a registry that will not read refuses a Tower with a Site, naming kitchen.json' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'cannot tell whether merges' -and $r.Out -match 'kitchen\.json')
    Scenario @{ config = '{"freeze":[]}' }; $r = Run
    Check 'Site-closed: a damaged registry never touches a Tower with no Site' ($r.Code -eq 0 -and $r.Merged)
    Remove-Item $kj

    # site closed when red (TD-EH-03c): the Tower's main status in the kitchen state folder (kitchen/main-status.ps1, written by verify)
    $env:KITCHEN_FREEZE_NOW = '2026-10-22T12:00'
    $ms = Join-Path $kr 'main-status'; New-Item -ItemType Directory -Force $ms | Out-Null
    function Status($file, $tower, $state, $repoPath = "C:\nowhere\$tower") {
        [ordered]@{ repo = $repoPath; tower = $tower; state = $state; suites = @(if ($state -eq 'red') { 'Test-VerifyCache', 'Test-PassApp' }); why = $(if ($state -eq 'red') { 'Test-VerifyCache: FAIL: train.ps1 not found' } else { '' })
            since = '2026-10-23T13:14:00.0000000Z'; sha = '9228e6f229278eb369c24b28b875f6dcef2ff057'; at = '2026-10-23T16:00:00.0000000Z'; job = 'J209' } | ConvertTo-Json | Set-Content (Join-Path $ms $file) -Encoding utf8
    }
    Status 'aaaaaaaaaaaa.json' 'demo' 'red'; Scenario @{}; $r = Run
    Check 'main red: refuses, naming the suites and the why, nothing merged, nothing logged' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'REFUSED JVonBorstel/demo#7: site closed: demo main is red since at least 10-23 13:14 UTC \(Failed: Test-VerifyCache, Test-PassApp; why: Test-VerifyCache: FAIL: train\.ps1 not found; last checked 9228e6f22927\)' -and $r.Out -match '-FixesRed' -and $r.Log.Count -eq 0)
    Check 'main red: refused before GitHub is asked anything' (-not (Test-Path (Join-Path $bin 'calls.log')))
    Check 'main red: the refusal names the way out, scripts/recheck-main.ps1 on the red Tower''s checkout (TD-EH-03d)' ($r.Out -match "(?m)^merge-pr: the way out: once the fix is on main, pwsh -File scripts/recheck-main\.ps1 -Repo 'C:\\nowhere\\demo' checks main again and records it green" -and $r.Out -notmatch 'recheck-main\.ps1 -Repo \S+ -All')
    Scenario @{}; $r = Run @{ DryRun = $true }
    Check 'main red: -DryRun refuses too' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'site closed')
    Scenario @{}; $r = Run @{ FixesRed = $true; Why = 'fixes train.ps1 not found' }
    $call = if ($r.Merged) { MergeCommit } else { '' }
    Check 'main red, -FixesRed: merges, says it is the fix' ($r.Code -eq 0 -and $r.Merged -and $r.Out -match 'MERGED JVonBorstel/demo#7 .*as the fix for a red main \(demo main is red' -and $r.Out -match 'fixesRed' -and $call -match 'as the fix for a red main')
    Check 'main red, -FixesRed: logged as the fix, with what main was and why' ($r.Log.Count -eq 1 -and $r.Log[0].ok -eq $true -and $r.Log[0].fixesRed -eq $true -and $r.Log[0].mainWas -eq 'red' -and $r.Log[0].mainStatus -match 'Failed: Test-VerifyCache, Test-PassApp' -and $r.Log[0].actor -eq 'claude-session' -and $r.Log[0].why -eq 'fixes train.ps1 not found')
    Status 'aaaaaaaaaaaa.json' 'Demo' 'red'; Scenario @{}; $r = Run
    Check 'main red: the Tower name matches the slug name ignoring case' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'site closed')
    Status 'aaaaaaaaaaaa.json' 'other-tower' 'red'; Scenario @{}; $r = Run
    Check 'another Tower red: this one stays open' ($r.Code -eq 0 -and $r.Merged -and $r.Log.Count -eq 1 -and $null -eq $r.Log[0].fixesRed)
    $named = Join-Path $root 'checkout-x'; New-Item -ItemType Directory -Force $named | Out-Null; '{"github":"JVonBorstel/demo"}' | Set-Content (Join-Path $named 'kitchen.repo.json')
    Status 'aaaaaaaaaaaa.json' 'checkout-x' 'red' $named; Scenario @{}; $r = Run
    Check 'main red: a checkout whose kitchen.repo.json names this github counts, whatever its folder is called' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'checkout-x main is red')
    '{"github":"JVonBorstel/elsewhere"}' | Set-Content (Join-Path $named 'kitchen.repo.json'); Status 'aaaaaaaaaaaa.json' 'demo' 'red' $named; Scenario @{}; $r = Run
    Check 'main red: a checkout named demo whose kitchen.repo.json names another github does not close this one' ($r.Code -eq 0 -and $r.Merged)
    Status 'aaaaaaaaaaaa.json' 'demo' 'green'; Scenario @{}; $r = Run
    Check 'main green: merges, logged without fixesRed' ($r.Code -eq 0 -and $r.Merged -and $r.Log.Count -eq 1 -and $null -eq $r.Log[0].fixesRed)
    Set-Content (Join-Path $ms 'bbbbbbbbbbbb.json') '{"tower":"demo","state":"re' -NoNewline; Scenario @{}; $r = Run
    Check 'a status file that cannot be read: unknown, not green: refuses naming the file' ($r.Code -eq 1 -and -not $r.Merged -and $r.Out -match 'site closed: main status file main-status\\bbbbbbbbbbbb\.json cannot be read, so whether main is red is unknown' -and $r.Log.Count -eq 0)
    Check 'unknown: the way out is a recheck of every suite (-All); an unreadable file does not say whose checkout' ($r.Out -match "recheck-main\.ps1 -Repo <the Tower's checkout> -All checks main again")
    Scenario @{}; $r = Run @{ FixesRed = $true }
    Check 'unknown, -FixesRed: merges, logged as the fix with mainWas unknown' ($r.Code -eq 0 -and $r.Merged -and $r.Log.Count -eq 1 -and $r.Log[0].fixesRed -eq $true -and $r.Log[0].mainWas -eq 'unknown' -and $r.Log[0].mainStatus -match 'cannot be read')
    Remove-Item -LiteralPath $ms -Recurse -Force; Scenario @{}; $r = Run
    Check 'no main status recorded at all: open (verify never checked it), merges' ($r.Code -eq 0 -and $r.Merged)
}
finally {
    $env:PATH = $old.path; $env:BRAIN_KITCHEN = $old.k; $env:KITCHEN_GH = $old.gh; $env:FAKE_GH_DIR = $old.d; $env:KITCHEN_FREEZE_NOW = $old.n; $env:KITCHEN_GITHUB_REMOTE = $old.r
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "MergePr tests: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
exit 0
