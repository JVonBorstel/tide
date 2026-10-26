# Tests for recipes (cook.ps1), stations (worktree, commit, tests, merge), settings (kitchen.json) and the self-improvement line,
# end to end on a scratch git repo with a scripted "cook" instead of a model. Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$k = Join-Path $kd 'kitchen.ps1'; $cook = Join-Path $kd 'cook.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-rec-' + [guid]::NewGuid().ToString('N'))
$repo = "$root-repo"; $rec = "$root-recipes"
$env:BRAIN_KITCHEN = $root; $env:KITCHEN_RECIPES = $rec; $env:KITCHEN_AGY_EXE = 'off'; $env:BRAIN_NTFY_TOPIC = $null; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Job($id) { Get-Content (Join-Path $root "jobs\$id.json") -Raw | ConvertFrom-Json }
function Watch($s = 60) { & $k watch -Seconds $s -BreakerMin 99 -Quiet | Out-Null }
try {
    New-Item -ItemType Directory -Force -Path $root, $repo, $rec, "$repo\tests" | Out-Null
    # scratch repo with one passing test
    Set-Content "$repo\app.txt" 'version 1'
    Set-Content "$repo\tests\Test-App.ps1" "if ((Get-Content `"`$PSScriptRoot\..\app.txt`" -Raw) -match 'version') { 'App tests: 1 passed, 0 failed'; exit 0 } else { 'FAIL: app'; exit 1 }"
    git -C $repo init -q -b main; git -C $repo -c user.name=t -c user.email=t@t add -A; git -C $repo -c user.name=t -c user.email=t@t commit -q -m init
    # a scripted cook that edits the worktree like an agent would
    $fake = Join-Path $root 'fake-cook.ps1'
    Set-Content $fake "param([string]`$Text = 'version 2'); `$wt = Join-Path `$env:BRAIN_KITCHEN `"worktrees\`$env:KITCHEN_JOB`"; Set-Content (Join-Path `$wt 'app.txt') `$Text; 'cook: edited app.txt'; exit 0"
    $esc = { param($p) $p.Replace('\', '\\') }
    $recipe = @"
{ "description": "test line", "vars": { "goal": { "required": true, "max": 100 }, "repo": { "default": "$(& $esc $repo)" }, "text": { "default": "version 2" } },
  "steps": [
    { "station": "worktree", "args": { "Repo": "{{repo}}" }, "timeoutSec": 60 },
    { "script": "$(& $esc $fake)", "args": { "Text": "{{text}}" }, "timeoutSec": 60, "retries": 0 },
    { "station": "commit", "args": { "Message": "{{goal}}" }, "timeoutSec": 60, "retries": 0 },
    { "station": "tests", "args": { "Glob": "tests\\Test-*.ps1", "SuiteTimeoutSec": 60 }, "timeoutSec": 180, "retries": 0, "mustMatch": "ALL PASS" },
    { "station": "merge", "args": { "Repo": "{{repo}}" }, "approve": true, "replay": "unsafe", "timeoutSec": 60, "retries": 0 }
  ] }
"@
    Set-Content "$rec\line.json" $recipe

    # 1. cook basics
    Check 'list shows the recipe' ((& $cook -List | Out-String) -match 'line\s+test line')
    Check 'missing required var refused' ((& $cook -Recipe line | Out-String) -match "needs 'goal'")
    Check 'unknown var refused' ((& $cook -Recipe line -Vars @{ goal = 'g'; nope = 1 } | Out-String) -match "has no 'nope'")
    Check 'template injection refused' ((& $cook -Recipe line -Vars @{ goal = '{{repo}}' } | Out-String) -match 'may not contain')
    Check 'too long refused' ((& $cook -Recipe line -Vars @{ goal = ('x' * 101) } | Out-String) -match 'longer than 100')
    Check 'bad recipe name refused' ((& $cook -Recipe '..\x' | Out-String) -match 'recipe name')
    Check 'unknown station refused' ((& $k add -Name s -Script 'no-such-station' | Out-String) -match "no station named")

    # 2. the full line: branch, cook, commit, tests, wait for Jordan, merge
    $o = & $cook -Recipe line -Vars @{ goal = 'bump to version 2' } | Out-String
    Check 'cook creates a job' ($o -match 'cooking J1 from recipe line \(5 steps\)')
    Watch 120
    $j = Job J1
    Check 'recipe metadata persisted on job' ($j.recipe -eq 'line' -and $j.vars.goal -eq 'bump to version 2')
    Check 'line stops at the merge for Jordan' ($j.status -eq 'waiting-approval' -and $j.cursor -eq 4)
    $wt = Join-Path $root 'worktrees\J1'
    Check 'worktree on its own branch' ((git -C $wt rev-parse --abbrev-ref HEAD) -eq 'kitchen/J1')
    Check 'real checkout untouched before merge' ((Get-Content "$repo\app.txt" -Raw).Trim() -eq 'version 1')
    Check 'diff written for the taster' ((Get-Content "$wt\.kitchen\DIFF.patch" -Raw) -match '\+version 2')
    Check 'test results written' ((Get-Content "$wt\.kitchen\TESTS.txt" -Raw) -match 'ALL PASS')
    Check 'kitchen notes never committed' (-not ((git -C $wt show --name-only --format= HEAD) -match '\.kitchen'))
    & $k approve -Id J1 | Out-Null
    Watch 60
    Check 'merged after the yes' ((Job J1).status -eq 'done' -and (Get-Content "$repo\app.txt" -Raw).Trim() -eq 'version 2')
    Check 'merge commit names the job' ((git -C $repo log -1 --format=%s) -match 'kitchen/J1.*approved by Jordan')
    Check 'worktree and branch cleaned up' (-not (Test-Path $wt) -and -not (git -C $repo branch --list 'kitchen/J1'))

    # 3. failing tests stop the line before Jordan is ever asked
    & $cook -Recipe line -Vars @{ goal = 'break it'; text = 'broken' } | Out-Null
    Watch 120
    $j2 = Job J2
    Check 'failing tests quarantine the job' ($j2.status -eq 'quarantined' -and $j2.cursor -eq 3)
    Check 'no approval asked for a failed change' (-not $j2.approval)
    Check 'real checkout still clean' ((Get-Content "$repo\app.txt" -Raw).Trim() -eq 'version 2')

    # 4. a cook that changes nothing fails at commit
    & $cook -Recipe line -Vars @{ goal = 'no-op'; text = 'version 2' } | Out-Null
    Watch 90
    Check 'empty change fails at commit' ((Job J3).status -eq 'quarantined' -and (Job J3).cursor -eq 2)

    # 5. merge refuses a dirty checkout
    & $cook -Recipe line -Vars @{ goal = 'v3'; text = 'version 3' } | Out-Null
    Watch 120
    Set-Content "$repo\app.txt" 'local edit'
    & $k approve -Id J4 | Out-Null
    Watch 30
    Check 'merge refuses uncommitted local changes' ((Job J4).status -in 'needs-human', 'quarantined' -and (Get-Content "$repo\app.txt" -Raw).Trim() -eq 'local edit')
    git -C $repo checkout -- app.txt

    # 6. gate for bot orders, and settings file
    $g = & $cook -Recipe line -Vars @{ goal = 'gated' } -Gate -Json | ConvertFrom-Json
    & $k tick -Quiet | Out-Null
    Check 'gated recipe waits at step 1' ((Job $g.job).status -eq 'waiting-approval' -and (Job $g.job).cursor -eq 0)
    Check 'order is named for what was asked, not a default path' ((Job $g.job).name -eq 'line: gated')
    # a code recipe's "about" travels with the order, so the privacy judge reads "security" as code
    Set-Content "$rec\ab.json" '{ "about": "a change to the code of a software repository", "description": "x", "vars": { "repo": { "default": "C:\\x" }, "goal": { "required": true } }, "steps": [ { "station": "agent", "args": { "Role": "plan", "Prompt": "{{goal}}" } } ] }'
    $ab = & $cook -Recipe ab -Vars @{ goal = 'overall security and safety' } -Gate -Json | ConvertFrom-Json
    Check 'about is part of what the privacy judge reads' ((Job $ab.job).steps[0].args.Order -eq "About: a change to the code of a software repository.`nOrder: overall security and safety")
    Check 'about recipe named for the goal' ((Job $ab.job).name -eq 'ab: overall security and safety')
    & $k kill -All | Out-Null
    Set-Content (Join-Path $root 'kitchen.json') '{"dailyBudgetUsd": 7.5, "hunt": {"homeMetro": "Springfield"}}'   # hunt.homeMetro: the hunt below has a hybrid role there
    Check 'kitchen.json in the state folder sets defaults' ((& $k status | Out-String) -match 'of \$7\.50')
    Check 'command line beats kitchen.json' ((& $k status -DailyBudgetUsd 3 | Out-String) -match 'of \$3\.00')

    # 7. Overnight hunt (Idea I62): standing order, hunt-night recipe, pack recipe, hunt-night station
    $kcfg = Get-Content (Join-Path $kd 'kitchen.json') -Raw | ConvertFrom-Json
    $so = @($kcfg.standing | Where-Object { $_.name -eq 'overnight hunt' })
    Check 'standing order for overnight hunt in kitchen.json' ($so.Count -eq 1 -and $so[0].everyHours -eq 24 -and $so[0].recipe -eq 'hunt-night')
    # TD-EH-03b: the night inspection is a watcher order at 2 am, defined here but off until the Owner's kitchen.json names it in standingOn;
    # its script reuses recheck-main (-All -SkipUnchanged) inside run-bounded rather than its own test logic
    $ni = @($kcfg.standing | Where-Object { $_.name -eq 'night inspection' })
    $niSrc = Get-Content (Join-Path $kd '..\scripts\night-inspection.ps1') -Raw
    Check 'night inspection: a watcher order at 2 am, off by default, no recipe, not turned on in the repo' ($ni.Count -eq 1 -and $ni[0].watcher -eq 'night-inspection' -and $ni[0].atHour -eq 2 -and $ni[0].off -eq $true -and -not $ni[0].recipe -and -not $kcfg.standingOn -and $kcfg._nightInspection -match '"standingOn": \["night inspection"\]')
    Check 'night inspection: runs recheck-main -All -SkipUnchanged through run-bounded with a time limit' ($niSrc -match "run-bounded\.ps1" -and $niSrc -match "recheck-main\.ps1" -and $niSrc -match "'-All', '-SkipUnchanged'" -and $niSrc -match '-CommandFile \$cmdFile' -and $niSrc -match '-TimeoutSeconds \$TimeoutSeconds' -and $niSrc -notmatch 'stations\\tests\.ps1')

    # copy recipes to $rec so cook -List and cook -Recipe see them in this isolated test environment
    Copy-Item (Join-Path $kd 'recipes\*.json') $rec -Force
    $listStr = & $cook -List | Out-String
    Check 'cook list includes hunt-night' ($listStr -match 'hunt-night')
    Check 'cook list includes pack' ($listStr -match '\bpack\b')

    $hnJob = & $cook -Recipe hunt-night -Json | ConvertFrom-Json
    Check 'cook hunt-night cooks 3 steps' ($hnJob.ok -and $hnJob.steps -eq 3)
    $hnData = Job $hnJob.job
    Check 'hunt-night step 1 is agent' ($hnData.steps[0].script -match 'agent-step\.ps1')
    Check 'hunt-night step 2 is rankfit' ($hnData.steps[1].script -match 'rank-fit\.ps1')
    Check 'hunt-night step 3 is hunt-night station' ($hnData.steps[2].script -match 'hunt-night\.ps1')
    & $k kill -Id $hnJob.job | Out-Null

    # improve recipe stays NOT public: Jordan types some Improve orders himself, so the life judge must read them (review of J78)
    $impRaw = Get-Content (Join-Path $kd 'recipes\improve.json') -Raw | ConvertFrom-Json
    Check 'improve.json is not public (the life judge stays on)' ($impRaw.public -ne $true)

    $impJob = & $cook -Recipe improve -Vars @{ goal = 'strengthen self-improvement pipeline' } -Json | ConvertFrom-Json
    Check 'cook improve creates job' ($impJob.ok -and $impJob.steps -gt 0)
    $impData = Job $impJob.job
    $impAgentSteps = @($impData.steps | Where-Object { $_.script -match 'agent-step\.ps1' })
    Check 'improve recipe agent steps are not marked Public' ($impAgentSteps.Count -gt 0 -and @($impAgentSteps | Where-Object { $_.args.Public -eq $true }).Count -eq 0)
    & $k kill -Id $impJob.job | Out-Null

    # private override test: -Vars @{ private = 'yes' } marks every agent step private
    $impPrivJob = & $cook -Recipe improve -Vars @{ goal = 'strengthen self-improvement pipeline'; private = 'yes' } -Json | ConvertFrom-Json
    Check 'cook improve with private override creates job' ($impPrivJob.ok -and $impPrivJob.steps -gt 0)
    $impPrivData = Job $impPrivJob.job
    $impPrivAgentSteps = @($impPrivData.steps | Where-Object { $_.script -match 'agent-step\.ps1' })
    Check 'private override sets Private = $true on agent steps' ($impPrivAgentSteps.Count -gt 0 -and @($impPrivAgentSteps | Where-Object { $_.args.Private -eq $true }).Count -eq $impPrivAgentSteps.Count)
    Check 'private override suppresses Public = $true on agent steps' (@($impPrivAgentSteps | Where-Object { $_.args.Public }).Count -eq 0)
    & $k kill -Id $impPrivJob.job | Out-Null

    # hunt-night station test: deduplicates, scores, updates tracker.json and queues private local tailor jobs
    $huntStation = Join-Path $kd 'stations\hunt-night.ps1'
    Check 'hunt-night station exists' (Test-Path -LiteralPath $huntStation)

    $cDir = Join-Path $root 'career-test'
    New-Item -ItemType Directory -Force "$cDir\scout" | Out-Null

    $initTracker = [ordered]@{
        updated = (Get-Date).ToUniversalTime().ToString('o')
        items = @(
            [ordered]@{
                id = 'A1'
                company = 'ExistingCorp'
                role = 'Old Dev'
                link = 'https://example.com/existing'
                status = 'saved'
                source = 'scout'
            }
        )
    }
    $initTracker | ConvertTo-Json -Depth 5 | Set-Content "$cDir\tracker.json" -Encoding utf8

    $openingsFile = "$cDir\scout\Jtest-openings.md"
    $openingsContent = @"
# Openings

- **Old Dev** at ExistingCorp (remote, US). `$120,000.
  Fit: Already tracked.
  Link: https://example.com/existing

- **Lead AI Agent Engineer** at AlphaAI (Springfield). `$180,000.
  Fit: Strong match.
  Must-haves: LLMs, agentic workflows, Python, TypeScript, React Native.
  Link: https://example.com/alpha

- **AI Python Developer** at BetaLabs (remote, US). `$150,000.
  Fit: Good match.
  Must-haves: LLM agents and Python; security clearance: none mentioned; on-site city: none.
  Link: https://example.com/beta

- **Cloud Python Engineer** at GammaCloud (hybrid, Springfield). `$130,000.
  Fit: Python and AWS.
  Must-haves: Python, TypeScript and AWS.
  Link: https://example.com/gamma

- **Java Specialist** at DeltaLegacy (remote, US). `$110,000.
  Fit: Strong match for LLMs, Python, TypeScript, React Native, AWS.
  Must-haves: Java and Ruby only.
  Link: https://example.com/delta

# Worth a look today
- **AI Python Developer** at BetaLabs (remote, US). Same role again.
  Link: https://example.com/beta-share
"@
    Set-Content -LiteralPath $openingsFile -Value $openingsContent -Encoding utf8

    $pwshExe = (Get-Process -Id $PID).Path
    $hnOut = & $pwshExe -NoProfile -File $huntStation -Openings $openingsFile -CareerDir $cDir -Top 3 | Out-String
    Check 'hunt-night outputs done' ($hnOut -match 'hunt-night: done \(3 opening\(s\) queued for review\)')

    $resTracker = Get-Content "$cDir\tracker.json" -Raw -Encoding utf8 | ConvertFrom-Json
    Check 'tracker has 4 total items (1 original + 3 new)' (@($resTracker.items).Count -eq 4)

    $newItems = @($resTracker.items | Where-Object { $_.id -ne 'A1' })
    Check '3 new items appended' ($newItems.Count -eq 3)
    Check 'all new items are saved status' (@($newItems | Where-Object { $_.status -eq 'saved' }).Count -eq 3)
    Check 'all new items have source hunt-night' (@($newItems | Where-Object { $_.source -eq 'hunt-night' }).Count -eq 3)
    Check 'duplicate link was skipped' (-not ($newItems | Where-Object { $_.link -eq 'https://example.com/existing' }))
    Check 'lowest scoring opening was excluded from top 3' (-not ($newItems | Where-Object { $_.company -eq 'DeltaLegacy' }))
    Check 'top 3 companies are AlphaAI, BetaLabs, GammaCloud' (
        ($newItems | Where-Object { $_.company -eq 'AlphaAI' }) -and
        ($newItems | Where-Object { $_.company -eq 'BetaLabs' }) -and
        ($newItems | Where-Object { $_.company -eq 'GammaCloud' })
    )
    Check 'queued jobs created in kitchen and stored in drafts' (
        @($newItems | Where-Object { $_.drafts.Count -ge 1 -and $_.drafts[0] -match '^J\d+$' }).Count -eq 3
    )
    foreach ($ni in $newItems) {
        $qj = Job $ni.drafts[0]
        Check "$($ni.company) queued tailor job is private and local" (
            $qj.steps[0].args.Private -eq $true -and
            $qj.steps[0].args.Supplier -eq 'local'
        )
    }
    # apply packets fill the slots the 3 tailors leave under the 5-child cap: 2 tonight, best fit first, the third is told to wait
    $withPacket = @($newItems | Where-Object { $_.packetJob -match '^J\d+$' })
    Check 'hunt-night queues apply packets only up to the child cap (2 of 3)' ($withPacket.Count -eq 2 -and $hnOut -match "no slot left for A\d+'s apply packet")
    foreach ($ni in $withPacket) {
        $pj = Job $ni.packetJob
        Check "$($ni.company) apply packet job is apply-prep, private and local" ($pj.recipe -eq 'apply-prep' -and @($pj.steps | Where-Object { $_.script -match 'agent-step' -and $_.args.Private -eq $true -and $_.args.Supplier -eq 'local' }).Count -eq 1 -and $pj.vars.appId -eq $ni.id)
    }
    Check "the scout's own 'Fit:' words are not scored (DeltaLegacy lists Jordan's skills there)" (-not ($newItems | Where-Object { $_.company -eq 'DeltaLegacy' }))
    Check "'Worth a look today' repeats are not openings" (@($newItems | Where-Object { $_.company -eq 'BetaLabs' }).Count -eq 1)
    Check 'tracker.json.bak kept before the replace' (Test-Path "$cDir\tracker.json.bak")
    Check 'no lock or temp file left behind' (-not (Test-Path "$cDir\tracker.json.lock") -and -not @(Get-ChildItem $cDir -Filter 'tracker.json.tmp-*').Count)

    # an unreadable tracker is never treated as empty: refused, byte-for-byte unchanged, nothing queued
    $jobsBefore = @(Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json').Count
    $bad = '{ "items": [ { "id": "A1", "company": "Kept", "status": "applied" } ' + "`n<<<<<<< HEAD`n"
    [IO.File]::WriteAllText("$cDir\tracker.json", $bad)
    Set-Content -LiteralPath "$cDir\scout\Jnew-openings.md" -Encoding utf8 -Value "# Openings`n- **LLM Engineer** at NewCo (remote, US).`n  Must-haves: LLM agents, Python, TypeScript.`n  Link: https://example.com/newco"
    $badOut = & $pwshExe -NoProfile -File $huntStation -Openings "$cDir\scout\Jnew-openings.md" -CareerDir $cDir -Top 3 | Out-String
    Check 'unreadable tracker: hunt-night refuses (exit 2)' ($LASTEXITCODE -eq 2 -and $badOut -match 'unreadable' -and $badOut -notmatch 'hunt-night: done')
    Check 'unreadable tracker: file left byte-for-byte unchanged' ([IO.File]::ReadAllText("$cDir\tracker.json") -eq $bad)
    Check 'unreadable tracker: no tailor queued' (@(Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json').Count -eq $jobsBefore)

    # repeats inside one file take one slot; skip verdicts are never queued; a posting with {{ }} still queues; nothing fits -> done (0)
    Set-Content -LiteralPath "$cDir\tracker.json" -Encoding utf8 -Value '{ "items": [] }'
    Set-Content -LiteralPath "$cDir\scout\Jdup-openings.md" -Encoding utf8 -Value ("# Openings`n" +
        "- **LLM Engineer** at DupCo (remote, US).`n  Must-haves: LLM agents, Python, TypeScript, Angular {{ templates }}.`n  Link: https://example.com/dup`n" +
        "- **LLM Engineer** at DupCo (remote, US).`n  Must-haves: LLM agents, Python, TypeScript.`n  Link: https://example.com/dup`n" +
        "- **Cleared LLM Engineer** at SecretCo (remote, US).`n  Must-haves: LLM agents, Python, TypeScript; active TS/SCI clearance required.`n  Link: https://example.com/secret")
    $dupOut = & $pwshExe -NoProfile -File $huntStation -Openings "$cDir\scout\Jdup-openings.md" -CareerDir $cDir -Top 3 | Out-String
    $dupCode = $LASTEXITCODE
    $dupT = @((Get-Content "$cDir\tracker.json" -Raw | ConvertFrom-Json).items)
    Check 'same role twice in one file is saved once' ($dupT.Count -eq 1 -and $dupT[0].company -eq 'DupCo' -and $dupT[0].id -eq 'A1')
    Check 'a skip verdict (clearance) is never queued' (-not ($dupT | Where-Object { $_.company -eq 'SecretCo' }))
    Check "a posting with '{{' still queues its tailor" ($dupCode -eq 0 -and $dupOut -match 'hunt-night: done \(1 opening' -and @($dupT[0].drafts).Count -eq 1)
    Set-Content -LiteralPath "$cDir\scout\Jnone-openings.md" -Encoding utf8 -Value "# Openings`n- **Java Dev** at JavaCo (remote, US).`n  Must-haves: Java.`n  Link: https://example.com/java"
    $noneOut = & $pwshExe -NoProfile -File $huntStation -Openings "$cDir\scout\Jnone-openings.md" -CareerDir $cDir -Top 3 | Out-String
    Check 'nothing fits: done (0) and the tracker is untouched' ($LASTEXITCODE -eq 0 -and $noneOut -match 'hunt-night: done \(0 opening' -and @((Get-Content "$cDir\tracker.json" -Raw | ConvertFrom-Json).items).Count -eq 1)
    # a tailor that can't be queued is reported, recorded on the row and fails the step (never a silent 'done')
    $env:KITCHEN_RECIPES = Join-Path $root 'no-such-recipe-dir'
    Set-Content -LiteralPath "$cDir\scout\Jfail-openings.md" -Encoding utf8 -Value "# Openings`n- **LLM Engineer** at FailCo (remote, US).`n  Must-haves: LLM agents, Python, TypeScript.`n  Link: https://example.com/fail"
    $failOut = & $pwshExe -NoProfile -File $huntStation -Openings "$cDir\scout\Jfail-openings.md" -CareerDir $cDir -Top 3 | Out-String
    $failCode = $LASTEXITCODE
    $env:KITCHEN_RECIPES = $rec
    $failRow = @((Get-Content "$cDir\tracker.json" -Raw | ConvertFrom-Json).items | Where-Object { $_.company -eq 'FailCo' })
    Check 'queue failure: exit 1, no done line' ($failCode -eq 1 -and $failOut -match 'could not queue' -and $failOut -notmatch 'hunt-night: done')
    Check 'queue failure: row records draftError' ($failRow.Count -eq 1 -and $failRow[0].draftError)
    Check 'top over the child cap is clamped to 5' ((& $pwshExe -NoProfile -File $huntStation -Openings "$cDir\scout\Jnone-openings.md" -CareerDir $cDir -Top 8 | Out-String) -match 'taking 5')
    & $k kill -All | Out-Null   # the tailors queued above would otherwise take the tick slots the requeue checks below need

    # 7. requeue: fresh job stays as plain retry; old recipe job (> 12 hours) re-cooks as new job
    $recFresh = & $cook -Recipe line -Vars @{ goal = 'fresh retry'; text = 'version 2' } -Json | ConvertFrom-Json
    $freshId = $recFresh.job
    & $k kill -Id $freshId | Out-Null
    $rqFresh = & $k requeue -Id $freshId | Out-String
    Check 'fresh job retry preserves job id and resets to pending' ($rqFresh -match "requeued $freshId" -and (Job $freshId).status -eq 'pending')
    # the rerun starts a clean log: the earlier run of the same step and attempt is moved aside, not appended to (J28)
    $cur = [int](Job $freshId).cursor; $oldLog = Join-Path $root "run\$freshId-s$cur-a0.log"
    Set-Content $oldLog 'VERDICT: REWORK - from the earlier run'
    $evLines0 = @(Get-Content (Join-Path $root 'events.jsonl') -ErrorAction SilentlyContinue).Count
    $tickOut = & $k tick 2>&1 | Out-String
    # [string]: the new run's log may exist but be empty yet (kitchen-step.ps1 opens it before the station writes; a busy PC widens that
    # gap). Get-Content -Raw of an empty file gives nothing, and nothing -notmatch 'x' is an empty array, which reads as false: that was
    # the flake (10-24: 3 of 3 runs under load failed with the step started, the old log in run\old and the new log at 0 bytes).
    $rqOk = (-not (Test-Path $oldLog) -or [string](Get-Content $oldLog -Raw) -notmatch 'earlier run') -and @(Get-ChildItem (Join-Path $root 'run\old') -Filter "$freshId-s$cur-a0-*.log" -ErrorAction SilentlyContinue).Count -eq 1
    Check 'requeued step: earlier log moved to run\old, new log does not carry it' $rqOk
    if (-not $rqOk) {
        # evidence for the flake hunt: what the Walkround did, the Stop-work order, the run folder; the kitchen is copied aside and kept
        Write-Host "--- requeue evidence: $freshId (cursor $cur; its status is in the status block below)"
        Write-Host "--- tick output:`n$tickOut"
        Write-Host "--- events since the tick began:"; Get-Content (Join-Path $root 'events.jsonl') | Select-Object -Skip ([math]::Max(0, $evLines0 - 15)) | ForEach-Object { Write-Host "  $_" }
        Write-Host "--- status:`n$(& $k status | Out-String)"
        Write-Host "--- run\ and run\old:"; Get-ChildItem (Join-Path $root 'run'), (Join-Path $root 'run\old') -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$freshId-*" -or $_.PSIsContainer } | ForEach-Object { Write-Host "  $($_.FullName.Substring($root.Length)) $($_.Length)" }
        $keep = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-evidence-' + (Split-Path $root -Leaf))
        Copy-Item -Recurse -Force -Path $root -Destination $keep -ErrorAction SilentlyContinue
        Write-Host "--- kitchen kept at $keep"
    }
    & $k kill -Id $freshId | Out-Null

    $recOld = & $cook -Recipe line -Vars @{ goal = 'old retry'; text = 'version 2' } -Json | ConvertFrom-Json
    $oldId = $recOld.job
    & $k kill -Id $oldId | Out-Null
    $oldFile = Join-Path $root "jobs\$oldId.json"
    $oldJ = Get-Content $oldFile -Raw | ConvertFrom-Json -AsHashtable
    $oldJ.status = 'quarantined'
    $oldJ.created = (Get-Date).AddHours(-13).ToUniversalTime().ToString('o')
    $oldJ | ConvertTo-Json -Depth 12 | Set-Content $oldFile -Encoding utf8

    $rqOld = & $k requeue -Id $oldId | Out-String
    $mOld = [regex]::Match($rqOld, "re-cooked recipe line as (J\d+) \(closed $oldId\)")
    Check 'old recipe requeue re-cooks as new job' ($mOld.Success)
    $newJId = $mOld.Groups[1].Value
    $oldJAfter = Job $oldId
    Check 'old job closed' ($oldJAfter.status -eq 'closed' -and $oldJAfter.closed -eq $true -and $oldJAfter.replacedBy -eq $newJId -and -not $oldJAfter.recooking)
    # a second tap on Requeue (another phone) is refused: the old order is never re-cooked twice
    $rqAgain = & $k requeue -Id $oldId | Out-String
    Check 'requeue twice: refused, no second re-cook' ($rqAgain -match 'only set-aside jobs' -and $rqAgain -notmatch 're-cooked')
    $newJob = Job $newJId
    Check 'new job has status pending, recipe line, and same vars' ($newJob.status -eq 'pending' -and $newJob.recipe -eq 'line' -and $newJob.vars.goal -eq 'old retry')
    $evContent = Get-Content (Join-Path $root 'events.jsonl') -Raw
    Check 'events has job.closed' ($evContent -match '"type":"job\.closed"')
    & $k kill -Id $newJId | Out-Null

    # an old order already past its commit step is retried in place, not re-cooked from scratch
    $recPr = & $cook -Recipe line -Vars @{ goal = 'old with pr'; text = 'v' } -Json | ConvertFrom-Json
    $prId = $recPr.job; & $k kill -Id $prId | Out-Null
    $prFile = Join-Path $root "jobs\$prId.json"; $prJ = Get-Content $prFile -Raw | ConvertFrom-Json -AsHashtable
    $prJ.status = 'quarantined'; $prJ.created = (Get-Date).AddHours(-13).ToUniversalTime().ToString('o')
    $prJ.steps = @($prJ.steps[0], @{} + $prJ.steps[0], @{} + $prJ.steps[0]); $prJ.steps[1].script = 'C:\x\stations\commit.ps1'; $prJ.cursor = 2
    $prJ | ConvertTo-Json -Depth 12 | Set-Content $prFile -Encoding utf8
    $rqPr = & $k requeue -Id $prId | Out-String
    Check 'old order past its commit step: requeued in place, not re-cooked' ($rqPr -match "requeued $prId at step 3" -and $rqPr -notmatch 're-cooked' -and (Get-Content $prFile -Raw | ConvertFrom-Json).status -eq 'pending')
    & $k kill -Id $prId | Out-Null

    # night shift (reserved var night): the job waits (notBefore) until the next 22:00 local time; already night (22:00-06:00) = now
    $utcOf = { param($v) ([DateTime]$v).ToUniversalTime() }
    Check 'night: a bad value is refused' ((& $cook -Recipe line -Vars @{ goal = 'g'; night = 'later' } | Out-String) -match 'night must be yes or no')
    $env:KITCHEN_COOK_NOW = '2026-10-22T14:00:00'
    $n14 = & $cook -Recipe line -Vars @{ goal = 'night at two'; night = 'yes' } -Json | ConvertFrom-Json
    $want22 = ([DateTime]::SpecifyKind([DateTime]'2026-10-22T22:00:00', 'Local')).ToUniversalTime()
    Check 'night: ordered at 14:00 waits until today 22:00 local' ($n14.ok -and (& $utcOf (Job $n14.job).notBefore) -eq $want22 -and (& $utcOf $n14.notBefore) -eq $want22)
    $env:KITCHEN_COOK_NOW = '2026-10-22T23:00:00'
    $n23 = & $cook -Recipe line -Vars @{ goal = 'night at eleven'; night = 'yes' } -Json | ConvertFrom-Json
    Check 'night: ordered at 23:00 may start now' ($n23.ok -and (& $utcOf (Job $n23.job).notBefore) -eq ([DateTime]::SpecifyKind([DateTime]'2026-10-22T23:00:00', 'Local')).ToUniversalTime())
    $env:KITCHEN_COOK_NOW = '2026-10-23T03:00:00'
    $n03 = & $cook -Recipe line -Vars @{ goal = 'night at three'; night = 'yes' } -Json | ConvertFrom-Json
    Check 'night: ordered at 03:00 (still night) may start now' ($n03.ok -and (& $utcOf (Job $n03.job).notBefore) -eq ([DateTime]::SpecifyKind([DateTime]'2026-10-23T03:00:00', 'Local')).ToUniversalTime())
    $env:KITCHEN_COOK_NOW = $null
    $nNo = & $cook -Recipe line -Vars @{ goal = 'day order' } -Json | ConvertFrom-Json
    Check 'night: default no leaves notBefore empty' ($nNo.ok -and -not (Job $nNo.job).notBefore)
    foreach ($id in $n14.job, $n23.job, $n03.job, $nNo.job) { & $k kill -Id $id | Out-Null }
} finally {
    $env:BRAIN_KITCHEN = $null; $env:KITCHEN_RECIPES = $null; $env:KITCHEN_AGY_EXE = $null; $env:KITCHEN_COOK_NOW = $null
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains((Split-Path $root -Leaf)) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }  # only this run's GUID root: a concurrent run of this suite (another job's tests station, verify) must keep its workers
    if (Test-Path $repo) { git -C $repo worktree prune 2>$null }
    Remove-Item -Recurse -Force $root, $repo, $rec -ErrorAction SilentlyContinue
}
Write-Host "KitchenRecipes tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
