# Tests for the Ledger (kitchen/ledger.ps1): states from PROOF only, chains through replacements, drift between the idea list and
# the repo, flags with owners, manual links that need proof, roadmap items proved by docs/changes/<id>.md or a commit naming them,
# and the heartbeat. The fixture is the 2026-10-21 discovery: ideas marked failed that shipped, orders closed "re-cooked as Jnn",
# orders closed "done another way" with no proof, and orders closed with nothing replacing them. No AI. Self-cleaning (TEMP only).
$ErrorActionPreference = 'Stop'
$ledger = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\ledger.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('ledger-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G([string]$r) { & git -C $r -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function Put([string]$path, [string]$text) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null; Set-Content -LiteralPath $path -Value $text -Encoding utf8 }
function Iso([double]$daysAgo) { [DateTime]::UtcNow.AddDays(-$daysAgo).ToString('o') }
function Run([string[]]$more) { $o = & pwsh -NoProfile -File $ledger @more 2>&1 | Out-String; [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE } }
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_REPO', 'KITCHEN_FROM_CHEF', 'ZEITGEISTD_HOME') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
try {
    $kr = Join-Path $root 'kitchen'; $repo = Join-Path $root 'repo'; $rm = Join-Path $root 'gw'
    New-Item -ItemType Directory -Force -Path $kr, $repo, $rm | Out-Null
    $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_REPO = $repo; $env:KITCHEN_FROM_CHEF = $null; $env:ZEITGEISTD_HOME = $null   # the lobe home is <kitchen>\lobe here
    $code = @(@{ script = 'stations/build.ps1' }, @{ script = 'stations/merge.ps1' })
    function Job([string]$id, [string]$status, [double]$age, [hashtable]$vars = @{ goal = 'g' }, $steps = $code, [string]$recipe = 'improve', [string]$parent = '') {
        $j = @{ id = $id; name = "improve: $id"; recipe = $recipe; status = $status; created = (Iso $age); vars = $vars; steps = @($steps); history = @() }
        if ($parent) { $j.parent = $parent }
        Put (Join-Path $kr "jobs\$id.json") ($j | ConvertTo-Json -Depth 6)
    }
    # the kitchen's own repo: main names J1, J3 and J12 (the way kitchen merges and PRs do)
    G $repo init -q -b main; Put (Join-Path $repo 'a.txt') 'a'; G $repo add -A; G $repo commit -q -m 'start'
    foreach ($m in 'Merge kitchen/J1 (kitchen J1, approved by Jordan)', 'Kitchen J3: thing (#4)', 'Merge pull request #9 from x/kitchen/J12') { Add-Content (Join-Path $repo 'a.txt') $m; G $repo add -A; G $repo commit -q -m $m }

    $ideas = @(
        @{ id = 'I1'; title = 'failed but shipped'; source = 'research'; status = 'failed'; job = 'J1'; at = (Iso 9); score = 90 }
        @{ id = 'I2'; title = 'recooked'; source = 'Jordan'; status = 'failed'; job = 'J2'; at = (Iso 9); score = 100 }
        @{ id = 'I3'; title = 'closed and lost'; source = 'Jordan'; status = 'failed'; job = 'J4'; at = (Iso 9); score = 100 }
        @{ id = 'I4'; title = 'claimed done'; source = 'audit'; status = 'failed'; job = 'J5'; at = (Iso 9); score = 90 }
        @{ id = 'I5'; title = 'your idea waiting'; source = 'Jordan'; status = 'new'; job = ''; at = (Iso 5); score = 100 }
        @{ id = 'I6'; title = 'you dropped it'; source = 'research'; status = 'dropped'; job = ''; at = (Iso 5); score = 80 }
        @{ id = 'I7'; title = 'dropped by no one'; source = 'research'; status = 'dropped'; job = ''; at = (Iso 5); score = 80 }
        @{ id = 'I8'; title = 'built by hand'; source = 'Jordan'; status = 'new'; job = ''; at = (Iso 5); score = 100 }
        @{ id = 'I9'; title = 'research pack'; source = 'Jordan'; status = 'building'; job = 'J13'; at = (Iso 2); score = 100 }
        @{ id = 'I10'; title = 'rebuilt by idea tag'; source = 'research'; status = 'failed'; job = 'J14'; at = (Iso 4); score = 90 }
        @{ id = 'I11'; title = 'fresh idea'; source = 'research'; status = 'new'; job = ''; at = (Iso 1); score = 95 }
        @{ id = 'I12'; title = 'closed with proof'; source = 'audit'; status = 'failed'; job = 'J41'; at = (Iso 6); score = 90 }
        @{ id = 'I13'; title = 'dropped by cli'; source = 'audit'; status = 'failed'; job = 'J42'; at = (Iso 6); score = 90 }
        @{ id = 'I14'; title = 'dropped by you'; source = 'audit'; status = 'failed'; job = 'J43'; at = (Iso 6); score = 90 }
        @{ id = 'I15'; title = 'replaced by field'; source = 'audit'; status = 'failed'; job = 'J44'; at = (Iso 6); score = 90 }
    )
    Put (Join-Path $kr 'ideas.json') (@{ updated = (Iso 0); nextId = 16; items = $ideas } | ConvertTo-Json -Depth 6)
    Job 'J1' 'done' 8; Job 'J2' 'closed' 8; Job 'J3' 'done' 7; Job 'J4' 'closed' 8; Job 'J5' 'closed' 8
    Job 'J9' 'waiting-approval' 2; Job 'J10' 'done' 3; Job 'J11' 'quarantined' 3; Job 'J20' 'running' 0.1 -parent 'J9'
    Job 'J12' 'done' 3 @{ goal = "do x`n`n(Idea I10: rebuilt by idea tag. why)" }
    Job 'J13' 'done' 1 @{ goal = 'research' } @(@{ script = 'stations/research.ps1' }) 'upgrades'
    Job 'J14' 'quarantined' 4; Job 'J41' 'closed' 5; Job 'J42' 'closed' 5; Job 'J43' 'closed' 5; Job 'J44' 'closed' 5
    $events = @(
        @{ ts = (Iso 7); type = 'job.closed'; job = 'J2'; reason = 're-cooked fresh as J3: old copy predated the test fix' }
        @{ ts = (Iso 7); type = 'job.closed'; job = 'J4'; reason = 'stale set-aside cleared (superseded)' }
        @{ ts = (Iso 7); type = 'job.closed'; job = 'J5'; reason = 'done another way: repair already reads the critique' }
        @{ ts = (Iso 4); type = 'job.closed'; job = 'J41'; reason = 'built by hand'; proof = 'https://github.com/x/y/pull/7'; by = 'cli' }
        @{ ts = (Iso 4); type = 'job.closed'; job = 'J42'; reason = 'dropped: not worth it'; dropped = $true; by = 'cli' }
        @{ ts = (Iso 4); type = 'job.closed'; job = 'J43'; reason = 'dropped: cleared by Jordan in Chef'; dropped = $true; by = 'Jordan' }
        @{ ts = (Iso 4); type = 'job.closed'; job = 'J44'; reason = 'see the new one'; replacedBy = 'J3'; by = 'cli' }
    ) | ForEach-Object { $_ | ConvertTo-Json -Compress }
    Set-Content (Join-Path $kr 'events.jsonl') $events -Encoding utf8
    Set-Content (Join-Path $kr 'pass-actions.jsonl') (@{ ts = (Iso 4); op = 'ideas-drop'; id = 'I6'; ok = $true } | ConvertTo-Json -Compress) -Encoding utf8

    # a roadmap repo: B-01 has its change file, B-02 a commit that starts with its id, B-03 neither (and waits for B-02's twin B-04)
    G $rm init -q -b main
    Put (Join-Path $rm 'kitchen.repo.json') '{"roadmap":"map/roadmap.json"}'
    $item = { param($id, $deps) [ordered]@{ id = $id; title = "title $id"; why = 'w'; depends_on = @($deps); owns = @("src/$id.txt"); acceptance = @('x') } }
    Put (Join-Path $rm 'map\roadmap.json') (@{ waves = @(@{ id = 'W1'; goal = 'g'; items = @((& $item 'B-01' @()), (& $item 'B-02' @()), (& $item 'B-03' @('B-04')), (& $item 'B-04' @())) }) } | ConvertTo-Json -Depth 8)
    Put (Join-Path $rm 'docs\changes\B-01.md') 'what, why, undo'
    G $rm add -A; G $rm commit -q -m 'start'
    Put (Join-Path $rm 'src\B-02.txt') 'x'; G $rm add -A; G $rm commit -q -m 'B-02: runner gates'
    Job 'J30' 'pending' 0.2 @{ item = 'B-04'; repo = $rm } $code 'roadmap-item'

    # ---- 1. build -----------------------------------------------------------------------------------------------------------------
    $r = Run @('build')
    Check 'build: exit 0 and a top line' ($r.Code -eq 0 -and $r.Out -match '^Ledger: ')
    $doc = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable
    $by = @{}; foreach ($it in $doc.items) { $by[$it.id] = $it }
    Check 'idea failed in the list but merged on main = shipped, with the commit as proof' ($by.I1.state -eq 'shipped' -and $by.I1.proof -match 'J1: commit [0-9a-f]+ on main')
    Check 'drift flag: the list says failed but it shipped' (@($doc.drift | Where-Object { $_.id -eq 'I1' }).Count -eq 1)
    Check 'replacement followed: J2 closed "re-cooked as J3", J3 merged = shipped' ($by.I2.state -eq 'shipped' -and (@($by.I2.chain.id) -join ',') -eq 'J2,J3' -and $by.I2.chain[0].replacedBy -eq 'J3')
    Check 'closed with nothing replacing it = lost, owned by Claude' ($by.I3.state -eq 'lost' -and $by.I3.owner -eq 'Claude' -and $by.I3.why -match 'nothing replaced it')
    Check 'lost flag for Jordan''s idea is top priority' (@($doc.flags | Where-Object { $_.id -eq 'I3' -and $_.rule -eq 'lost' -and $_.pri -eq 1 }).Count -eq 1)
    Check '"done another way" with no proof = claimed, flagged' ($by.I4.state -eq 'claimed' -and @($doc.flags | Where-Object { $_.id -eq 'I4' -and $_.rule -eq 'claimed-no-proof' }).Count -eq 1)
    Check 'Jordan''s idea waiting 5 days = flag "your idea waiting"' ($by.I5.state -eq 'not-started' -and @($doc.flags | Where-Object { $_.id -eq 'I5' -and $_.rule -eq 'your-idea-waiting' }).Count -eq 1)
    Check 'dropped by Jordan in Chef = dropped, no flag' ($by.I6.state -eq 'dropped' -and -not @($doc.flags | Where-Object { $_.id -eq 'I6' }).Count)
    Check 'marked dropped but not by Jordan and never built = lost' ($by.I7.state -eq 'lost' -and $by.I7.why -match 'not by you')
    Check 'a finished non-code order counts as shipped' ($by.I9.state -eq 'shipped' -and $by.I9.proof -match 'order finished')
    Check 'a later order tagged "(Idea I10:" joins the chain and its merge ships the idea' ($by.I10.state -eq 'shipped' -and @($by.I10.chain.id) -contains 'J12')
    Check 'a fresh idea (1 day) is not flagged' (-not @($doc.flags | Where-Object { $_.id -eq 'I11' }).Count)
    Check 'order with no idea waiting on Jordan for 2 days = flag waiting-on-you' ($by.J9.kind -eq 'order' -and $by.J9.state -eq 'waiting-on-jordan' -and @($doc.flags | Where-Object { $_.id -eq 'J9' -and $_.rule -eq 'waiting-on-you' -and $_.owner -eq 'Jordan' }).Count -eq 1)
    Check 'set aside 3 days = stuck flag' ($by.J11.state -eq 'stuck' -and @($doc.flags | Where-Object { $_.id -eq 'J11' -and $_.rule -eq 'stuck' }).Count -eq 1)
    Check 'sub-orders are not listed on their own' (-not $by.ContainsKey('J20'))
    Check 'a merged order with no idea is not listed (nothing to do)' (-not $by.ContainsKey('J12') -and -not $by.ContainsKey('J1'))
    Check 'drift: an order done but not named on main' (@($doc.drift | Where-Object { $_.id -eq 'J10' -and $_.what -match 'no commit on main' }).Count -eq 1)
    Check 'roadmap: change file on main = shipped (not listed)' (-not $by.ContainsKey('B-01'))
    Check 'roadmap: a commit that starts with the id = shipped (not listed)' (-not $by.ContainsKey('B-02'))
    Check 'roadmap: B-03 not started, says what it waits for' ($by['B-03'].state -eq 'not-started' -and $by['B-03'].why -match 'B-04')
    Check 'roadmap: B-04 cooking = moving' ($by['B-04'].state -eq 'moving' -and $by['B-04'].kind -eq 'roadmap')
    $prog = @($doc.programs | Where-Object { $_.repo -eq 'gw' })[0]
    Check 'program line: 2 of 4 shipped' ($prog.total -eq 4 -and $prog.shipped -eq 2)
    Check 'counts add up (waiting, lost, claimed, stuck)' ($doc.counts.waitingOnJordan -eq 1 -and $doc.counts.lost -eq 2 -and $doc.counts.claimed -eq 1 -and $doc.counts.stuck -ge 1)
    Check 'items sorted: waiting on Jordan first' ($doc.items[0].state -eq 'waiting-on-jordan')
    $fk = @($doc.flags | ForEach-Object { '{0}|{1}' -f $_.pri, $_.id }); $fs = @($doc.flags | Sort-Object { [int]$_.pri }, { [string]$_.id } | ForEach-Object { '{0}|{1}' -f $_.pri, $_.id })
    Check 'flags sorted by priority, then id (never in hashtable order)' ($fk.Count -ge 5 -and ($fk -join ',') -ceq ($fs -join ','))
    $hb = Get-Content (Join-Path $kr 'watch\ledger.json') -Raw | ConvertFrom-Json
    Check 'heartbeat written with counts' ($hb.name -eq 'ledger' -and $hb.checked -ge 10 -and $hb.found -ge 5 -and $hb.lastRun)

    Check 'close with -Proof = shipped, the proof shown' ($by.I12.state -eq 'shipped' -and $by.I12.proof -match 'pull/7')
    Check 'close dropped by a script = dropped, flagged for Jordan to confirm' ($by.I13.state -eq 'dropped' -and @($doc.flags | Where-Object { $_.id -eq 'I13' -and $_.rule -eq 'dropped-not-by-you' -and $_.owner -eq 'Jordan' }).Count -eq 1)
    Check 'close dropped by Jordan = dropped, no flag' ($by.I14.state -eq 'dropped' -and -not @($doc.flags | Where-Object { $_.id -eq 'I14' }).Count)
    Check 'close with replacedBy (event field) follows the chain' ($by.I15.state -eq 'shipped' -and (@($by.I15.chain.id) -join ',') -eq 'J44,J3')

    # ---- 2. link needs proof -----------------------------------------------------------------------------------------------------
    Check 'link refuses without proof' ((Run @('link', '-Id', 'I8', '-Why', 'built by hand in PR 3')).Code -eq 2)
    Check 'link refuses proof that is not a commit, url, file or order' ((Run @('link', '-Id', 'I8', '-Proof', 'trust me', '-Why', 'built by hand')).Code -eq 2)
    Check 'link refuses without a reason' ((Run @('link', '-Id', 'I8', '-Proof', 'abc1234')).Code -eq 2)
    $r = Run @('link', '-Id', 'I8', '-Proof', 'https://github.com/x/y/pull/3', '-Why', 'built by hand in PR 3')
    Check 'link with a PR url is recorded' ($r.Code -eq 0)
    $null = Run @('build')
    $doc = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable; $i8 = @($doc.items | Where-Object id -eq 'I8')[0]
    Check 'a linked idea is shipped with the link as proof' ($i8.state -eq 'shipped' -and $i8.proof -match 'pull/3')
    $r = Run @('show', '-Id', 'I2')
    Check 'show prints the chain with the replacement' ($r.Code -eq 0 -and $r.Out -match 'J2 closed' -and $r.Out -match '-> J3' -and $r.Out -match 'J3 done proof: commit')
    Check 'show of an unknown id fails' ((Run @('show', '-Id', 'I999')).Code -eq 2)
    $r = Run @('flags', '-Json'); $fl = ($r.Out.Trim() -split "`r?`n")[-1] | ConvertFrom-Json
    Check 'flags -Json: every flag has an owner and a sentence' ($fl.ok -and @($fl.flags | Where-Object { -not $_.owner -or $_.say.Length -lt 10 }).Count -eq 0)

    # ---- ZG-25: the lobe's flags.json -> flags 'decision-ready' and 'post-mortem-due', counted in the top line --------------------------
    $d0 = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable
    Check 'ZG25 missing flags.json: decisions unknown (null counts, never a made-up 0), no decision flag, the top line says so' ($null -eq $d0.counts.decisionsReady -and $null -eq $d0.counts.postMortemsDue -and $d0.lobe.ok -eq $false -and $d0.lobe.why -match 'no flags\.json yet' -and $d0.top -match '^Ledger: \d+ waiting on you, decisions unknown, ' -and -not @($d0.flags | Where-Object { $_.rule -in 'decision-ready', 'post-mortem-due', 'lobe-flags-unreadable' }).Count)
    # J50 merged then reverted on main; J10's merge undone in one tap (merge.undone event); J2 replaced by J3 (above); J1 still on main
    Add-Content (Join-Path $repo 'a.txt') 'j50'; G $repo add -A; G $repo commit -q -m 'Merge kitchen/J50 (kitchen J50, approved by Jordan)'
    Add-Content (Join-Path $repo 'a.txt') 'j50 undone'; G $repo add -A; G $repo commit -q -m 'Revert "Merge kitchen/J50 (kitchen J50, approved by Jordan)"'
    Put (Join-Path $kr 'jobs\J50.json') (@{ id = 'J50'; name = 'improve: J50'; recipe = 'improve'; status = 'done'; created = (Iso 40); vars = @{ goal = 'g' }; steps = @($code); history = @() } | ConvertTo-Json -Depth 6)
    Add-Content (Join-Path $kr 'events.jsonl') (@{ ts = (Iso 1); type = 'merge.undone'; job = 'J10' } | ConvertTo-Json -Compress) -Encoding utf8
    $pm = { param($id, $day) [ordered]@{ id = $id; day = $day; due_at = (Iso 2); expires_at = (Iso -12); choice = 'approve' } }
    $flagsDoc = [ordered]@{ updated = (Iso 0); decisionReady = @([ordered]@{ id = 'D-L1'; loop = 'L1'; question = 'SECRET-QUESTION about a person'; ready_at = (Iso 0.5) }, [ordered]@{ id = 'bad id!'; loop = 'x' })
        postMortemDue = @((& $pm 'S-J1-A7' 30), (& $pm 'S-J2-A8' 60), (& $pm 'S-J10-A9' 30), (& $pm 'S-J50-A10' 90), (& $pm 'D-L2' 30), (& $pm 'S-J999-A1' 30), (& $pm 'D-L3' 45)) }
    $flagsJson = $flagsDoc | ConvertTo-Json -Depth 5
    Put (Join-Path $kr 'lobe\flags.json') $flagsJson
    $r = Run @('build')
    $raw = Get-Content (Join-Path $kr 'ledger.json') -Raw; $d1 = $raw | ConvertFrom-Json -AsHashtable
    $fx = @{}; foreach ($x in $d1.flags) { $fx["$($x.rule)|$($x.id)"] = $x }
    $dr1 = $fx['decision-ready|D-L1']
    Check 'ZG25 decision-ready: one flag per ready decision (owner Jordan, pri 2, its ready time); a bad id is skipped' ($r.Code -eq 0 -and $dr1 -and $dr1.owner -eq 'Jordan' -and $dr1.pri -eq 2 -and $dr1.readyAt -and $dr1.say -match 'Decision D-L1 is ready for you' -and @($d1.flags | Where-Object { $_.rule -eq 'decision-ready' }).Count -eq 1)
    Check 'ZG25 ids only: the question text never enters the Ledger' ($raw -notmatch 'SECRET-QUESTION')
    $p1 = $fx['post-mortem-due|S-J1-A7']
    Check 'ZG25 post-mortem-due: owner Jordan, pri 2, the day and its dates; a day that is not 30, 60 or 90 is skipped' ($p1 -and $p1.owner -eq 'Jordan' -and $p1.pri -eq 2 -and $p1.day -eq 30 -and $p1.dueAt -and $p1.expiresAt -and $p1.say -match 'day-30 check' -and -not $fx['post-mortem-due|D-L3'] -and @($d1.flags | Where-Object { $_.rule -eq 'post-mortem-due' }).Count -eq 6)
    Check 'ZG25 proof: a Sign-off whose merge is still on main names the commit' ($p1.proofKind -eq 'on-main' -and $p1.proof -match '^still on main: commit [0-9a-f]+ on main$' -and $p1.order -eq 'J1')
    Check 'ZG25 proof: a replaced order says "replaced by Jnn"' ($fx['post-mortem-due|S-J2-A8'].proofKind -eq 'replaced' -and $fx['post-mortem-due|S-J2-A8'].proof -eq 'replaced by J3')
    Check 'ZG25 proof: a merge undone in one tap (merge.undone) and a merge reverted on main are both "undone"' ($fx['post-mortem-due|S-J10-A9'].proofKind -eq 'undone' -and $fx['post-mortem-due|S-J50-A10'].proofKind -eq 'undone' -and $fx['post-mortem-due|S-J50-A10'].proof -match 'reverts it')
    Check 'ZG25 proof: a lobe decision has none, an unknown order is unknown (never a guess)' ($fx['post-mortem-due|D-L2'].proofKind -eq 'none' -and $fx['post-mortem-due|S-J999-A1'].proofKind -eq 'unknown' -and $fx['post-mortem-due|S-J999-A1'].proof -match 'no work order file for J999')
    Check 'ZG25 the top line counts them right after waiting-on-you; counts carry both' ($d1.counts.decisionsReady -eq 1 -and $d1.counts.postMortemsDue -eq 6 -and $d1.lobe.ok -and $d1.top -match '^Ledger: \d+ waiting on you, 1 decisions ready, 6 post-mortems due, ' -and $r.Out -match '1 decisions ready, 6 post-mortems due')
    $fk = @($d1.flags | ForEach-Object { '{0}|{1}' -f $_.pri, $_.id }); $fs = @($d1.flags | Sort-Object { [int]$_.pri }, { [string]$_.id } | ForEach-Object { '{0}|{1}' -f $_.pri, $_.id })
    Check 'ZG25 the new flags sort with the rest (priority, then id)' (($fk -join ',') -ceq ($fs -join ','))
    $r = Run @('flags', '-Json'); $fl = ($r.Out.Trim() -split "`r?`n")[-1] | ConvertFrom-Json
    Check 'ZG25 flags -Json carries them, each with an owner and a sentence' (@($fl.flags | Where-Object { $_.rule -in 'decision-ready', 'post-mortem-due' }).Count -eq 7)
    Check 'ZG25 the Ledger never writes the lobe''s flags.json' ((Get-Content (Join-Path $kr 'lobe\flags.json') -Raw).Trim() -eq $flagsJson.Trim())
    Put (Join-Path $kr 'lobe\flags.json') '{ broken SECRET'
    $r = Run @('build'); $d2 = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable
    Check 'ZG25 an unreadable flags.json: the Ledger still builds, a flag for Claude, counts unknown, its text never copied' ($r.Code -eq 0 -and @($d2.flags | Where-Object { $_.rule -eq 'lobe-flags-unreadable' -and $_.owner -eq 'Claude' }).Count -eq 1 -and $null -eq $d2.counts.decisionsReady -and $d2.top -match 'decisions unknown' -and -not @($d2.flags | Where-Object { $_.rule -eq 'decision-ready' }).Count -and ((Get-Content (Join-Path $kr 'ledger.json') -Raw) -notmatch 'SECRET'))
    Put (Join-Path $kr 'lobe\flags.json') '{"updated": null, "items": []}'
    $null = Run @('build'); $d3 = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable
    Check 'ZG25 a JSON file without the two lists is unreadable too (never a silent zero)' ($null -eq $d3.counts.decisionsReady -and @($d3.flags | Where-Object { $_.rule -eq 'lobe-flags-unreadable' }).Count -eq 1)
    Put (Join-Path $kr 'lobe\flags.json') $flagsJson   # kept for the archive check below: the same flags and proof after archiving

    # ---- LedgerTotals_SameBeforeAfterArchive: the doctor moves finished orders older than 3 days to jobs\archive\yyyy-MM\ (TARGET
    # W3); the ledger then reads their summary lines (jobs\archive\index.jsonl) and must say exactly the same, item by item
    $null = Run @('build'); $before = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($f in Get-ChildItem (Join-Path $kr 'jobs') -Filter 'J*.json') { $f.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-10) }
    $env:KITCHEN_ARCHIVE_DAYS = $null
    $dr = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1') doctor -Json 2>&1 | Out-String) | ConvertFrom-Json
    $null = Run @('build'); $after = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable
    $sig = { param($d) (@($d.items | ForEach-Object { "$($_.id)=$($_.state)|$($_.owner)|$($_.proof)|$($_.why)|$(@($_.chain | ForEach-Object { "$($_.id):$($_.status):$($_.proof):$($_.replacedBy)" }) -join ',')" }) -join "`n") }
    $fsig = { param($d) (@($d.flags | ForEach-Object { "$($_.id)|$($_.rule)|$($_.say)" }) -join "`n") }
    $left = @(Get-ChildItem (Join-Path $kr 'jobs') -Filter 'J*.json').Count
    Check "LedgerTotals_SameBeforeAfterArchive: $([int]$dr.archived) orders archived ($left left in jobs\), counts, items, chains and flags unchanged" (
        [int]$dr.archived -ge 10 -and $left -ge 1 -and ($before.counts | ConvertTo-Json -Compress) -eq ($after.counts | ConvertTo-Json -Compress) -and
        (& $sig $before) -eq (& $sig $after) -and (& $fsig $before) -eq (& $fsig $after) -and @($before.items).Count -eq @($after.items).Count)
    if (($before.counts | ConvertTo-Json -Compress) -ne ($after.counts | ConvertTo-Json -Compress)) { Write-Host ("  counts " + ($before.counts | ConvertTo-Json -Compress) + " vs " + ($after.counts | ConvertTo-Json -Compress)) }
    if ((& $sig $before) -ne (& $sig $after) -or (& $fsig $before) -ne (& $fsig $after)) { Compare-Object @((& $sig $before) -split "`n") @((& $sig $after) -split "`n") | Select-Object -First 4 | ForEach-Object { Write-Host "  ledger diff $($_.SideIndicator) $($_.InputObject)" }; Compare-Object @((& $fsig $before) -split "`n") @((& $fsig $after) -split "`n") | Select-Object -First 4 | ForEach-Object { Write-Host "  flags diff $($_.SideIndicator) $($_.InputObject)" } }

    # ---- TD-5: programs grouped by Site; one bad Tower is a named finding and the rest still report ---------------------------------
    $d4 = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable
    Check 'TD5 no Sites: every program line has exactly the keys it had before Sites, and ledger.json has no "sites" key' (@($d4.programs).Count -ge 1 -and -not @($d4.programs | Where-Object { (@($_.Keys | Sort-Object) -join ',') -cne 'repo,shipped,stuck,total' }).Count -and (@($d4.Keys | Sort-Object) -join ',') -ceq 'counts,drift,flags,items,lobe,ok,programs,top,updated')
    Check 'TD5 no Sites: no Site or Tower finding' (-not @($d4.flags | Where-Object { $_.rule -in 'tower-unreadable', 'sites-registry-unreadable' }).Count)
    # three more Towers: td names its Site in kitchen.repo.json, zg only in its Blueprint's site block, plain has none; gw gets GW from the registry
    $td = Join-Path $root 'td'; $zg = Join-Path $root 'zg'; $plain = Join-Path $root 'plain'
    foreach ($tw in @(@($td, '{"roadmap":"map/roadmap.json","site":"TD"}', $null, @('TD-1', 'TD-2')), @($zg, '{"roadmap":"map/roadmap.json"}', @{ code = 'ZG' }, @('ZG-1')), @($plain, '{"roadmap":"map/roadmap.json"}', $null, @('P-1')))) {
        $dir = $tw[0]; New-Item -ItemType Directory -Force -Path $dir | Out-Null; G $dir init -q -b main
        Put (Join-Path $dir 'kitchen.repo.json') $tw[1]
        $bp = [ordered]@{ waves = @(@{ id = 'W1'; goal = 'g'; items = @($tw[3] | ForEach-Object { & $item $_ @() }) }) }; if ($tw[2]) { $bp.site = $tw[2] }
        Put (Join-Path $dir 'map\roadmap.json') ($bp | ConvertTo-Json -Depth 8)
        Put (Join-Path $dir "docs\changes\$($tw[3][0]).md") 'what, why, undo'
        G $dir add -A; G $dir commit -q -m 'start'
    }
    # a closed order per Tower (so the Ledger knows the Tower); written here, not by Job (a bare Job reads as an alias of Get-Job)
    function Add-TowerOrder([string]$id, [string]$tower) { Put (Join-Path $kr "jobs\$id.json") (@{ id = $id; name = "improve: $id"; recipe = 'improve'; status = 'closed'; created = (Iso 1); vars = @{ goal = 'g'; repo = $tower }; steps = @($code); history = @() } | ConvertTo-Json -Depth 6) }
    Add-TowerOrder 'J61' $td; Add-TowerOrder 'J62' $zg; Add-TowerOrder 'J63' $plain
    Put (Join-Path $kr 'kitchen.json') (@{ maxConcurrent = 4; sites = @{ GW = @{ name = 'Demo Project'; towers = @($rm) } } } | ConvertTo-Json -Depth 5)
    $r = Run @('build'); $d5 = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable
    $pl = @($d5.programs | ForEach-Object { "$($_.repo):$($_.site):$($_.shipped)/$($_.total)" }) -join ' '
    Check "TD5 grouped by Site: Sites by code (registry GW, kitchen.repo.json TD, Blueprint ZG), then the Tower with none ($pl)" ($r.Code -eq 0 -and $pl -ceq 'gw:GW:2/4 td:TD:1/2 zg:ZG:1/1 plain::1/1' -and -not @($d5.programs | Where-Object { $_.repo -eq 'plain' })[0].Contains('site'))
    $sl = @($d5.sites | ForEach-Object { "$($_.site)=$($_.name)|$(@($_.towers) -join '+')|$($_.shipped)/$($_.total)" }) -join ' '
    Check "TD5 one line per Site, its name from the registry ($sl)" ($sl -ceq 'GW=Demo Project|gw|2/4 TD=TD|td|1/2 ZG=ZG|zg|1/1')
    # one bad Tower of each kind: a Blueprint that is not JSON, a kitchen.repo.json that is not JSON, a path no file system can hold
    $bad1 = Join-Path $root 'bad1'; $bad2 = Join-Path $root 'bad2'
    foreach ($dir in $bad1, $bad2) { New-Item -ItemType Directory -Force -Path $dir | Out-Null; G $dir init -q -b main }
    Put (Join-Path $bad1 'kitchen.repo.json') '{"roadmap":"map/roadmap.json"}'; Put (Join-Path $bad1 'map\roadmap.json') '{ broken'
    Put (Join-Path $bad2 'kitchen.repo.json') '{ nope'
    Add-TowerOrder 'J64' $bad1; Add-TowerOrder 'J65' $bad2; Add-TowerOrder 'J66' "$root\nul$([char]0)tower"
    Remove-Item -LiteralPath (Join-Path $kr 'ledger.json')   # (so a build that stops reads as no ledger, never as the last good one)
    $r = Run @('build'); $d6 = if (Test-Path -LiteralPath (Join-Path $kr 'ledger.json')) { Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    $tf = @($d6.flags | Where-Object { $_.rule -eq 'tower-unreadable' })
    Check "TD5 the Ledger survives bad Towers: exit 0, each a named finding for Claude ($(@($tf.id) -join ', '))" ($r.Code -eq 0 -and @($tf | Where-Object { $_.id -eq 'bad1' -and $_.say -match 'bad1' }).Count -eq 1 -and @($tf | Where-Object { $_.id -eq 'bad2' }).Count -eq 1 -and @($tf | Where-Object { $_.id -match '^nul.tower$' }).Count -eq 1 -and -not @($tf | Where-Object { $_.owner -ne 'Claude' -or $_.pri -ne 2 }).Count)
    $pl6 = @($d6.programs | ForEach-Object { "$($_.repo):$($_.site):$($_.shipped)/$($_.total)" }) -join ' '
    Check "TD5 and every good Tower still reports, unchanged ($pl6)" ($pl6 -ceq $pl -and $d6.top -match '^Ledger: ' -and @($d6.items | Where-Object { $_.id -eq 'TD-2' }).Count -eq 1)
    Check 'TD5 a NUL in a Tower path never reaches a finding''s text (no \u0000 in ledger.json)' ((Test-Path -LiteralPath (Join-Path $kr 'ledger.json')) -and (Get-Content (Join-Path $kr 'ledger.json') -Raw) -notmatch '\\u0000' -and (Get-Content (Join-Path $kr 'ledger.json') -Raw) -match 'nul\?tower')
    # an unreadable registry is a finding too; the Towers then group by their own Site only (gw loses GW)
    Put (Join-Path $kr 'kitchen.json') '{ broken'
    $r = Run @('build'); $d7 = Get-Content (Join-Path $kr 'ledger.json') -Raw | ConvertFrom-Json -AsHashtable
    $pl7 = @($d7.programs | ForEach-Object { "$($_.repo):$($_.site)" }) -join ' '
    Check "TD5 an unreadable Sites registry: exit 0, a finding, Towers keep their own Site ($pl7)" ($r.Code -eq 0 -and @($d7.flags | Where-Object { $_.rule -eq 'sites-registry-unreadable' -and $_.owner -eq 'Claude' }).Count -eq 1 -and $pl7 -ceq 'td:TD zg:ZG gw: plain:')
    Remove-Item -LiteralPath (Join-Path $kr 'kitchen.json')

    # ---- 3. fail visible -------------------------------------------------------------------------------------------------------------
    Put (Join-Path $kr 'ideas.json') '{ broken'
    Check 'an unreadable idea list fails (exit 1), never an empty ledger' ((Run @('build')).Code -eq 1)
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Ledger tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
