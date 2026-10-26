# Tests for kitchen/stations/lobe-recall.ps1 (the recall Step, ZG-16) and its use by kitchen/stations/repair.ps1 -Recall.
# Run by the tests Step (it globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. A temp kitchen, a fake zeitgeistd checkout and a
# fake python (KITCHEN_LOBE_PYTHON) that records each call and answers with set hits; repair runs with fake tests, commit and cook Steps. One real
# search through uv against the zeitgeistd checkout, on a synthetic engram the lessons connector builds in a temp lobe home (SKIP when this PC
# has no checkout, no uv, or a .venv uv cannot see). Self-cleaning.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pwshExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('lobe-recall-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$envNames = @('BRAIN_KITCHEN', 'KITCHEN_JOB', 'ZEITGEISTD_REPO', 'ZEITGEISTD_HOME', 'KITCHEN_LOBE_PYTHON', 'KITCHEN_APPROVED', 'KITCHEN_AGENT_STEP', 'KITCHEN_TIMEOUT',
    'LOBE_FAKE_LOG', 'LOBE_FAKE_HITS', 'LOBE_FAKE_MODE', 'RECALL_COOK_LOG', 'ANTHROPIC_API_KEY', 'ZG16_TEST_API_KEY', 'PATH', 'UV_PYTHON_PREFERENCE')
$saved = @{}; $envNames | ForEach-Object { $saved[$_] = [Environment]::GetEnvironmentVariable($_) }
$script:pass = 0; $script:fail = 0
# one check: counts it, and on a failure prints its name and the last 15 lines of what it saw
function Check([string]$Name, [bool]$Ok, [string]$Show = '') {
    if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $Name"; if ($Show) { Write-Host (($Show -split "`r?`n" | Select-Object -Last 15) -join "`n") } }
}

# Layout: <tmp>\bm\kitchen\stations\{lobe-recall,repair}.ps1 + <tmp>\bm\scripts\run-bounded.ps1 (the paths the Steps use), a fake checkout, a kitchen.
$bm = Join-Path $tmp 'bm'; $st = Join-Path $bm 'kitchen\stations'
New-Item -ItemType Directory -Force -Path $st, (Join-Path $bm 'scripts') | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'kitchen\stations\lobe-recall.ps1'), (Join-Path $repoRoot 'kitchen\stations\repair.ps1') -Destination $st
Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\run-bounded.ps1') -Destination (Join-Path $bm 'scripts')
$station = Join-Path $st 'lobe-recall.ps1'
$fakeRepo = Join-Path $tmp 'repo'; New-Item -ItemType Directory -Force -Path (Join-Path $fakeRepo 'zeitgeistd') | Out-Null; Set-Content -LiteralPath (Join-Path $fakeRepo 'zeitgeistd\search.py') -Value ''
$kitchen = Join-Path $tmp 'k'; $kd = Join-Path $kitchen 'worktrees\J7\.kitchen'; $lobeHome = Join-Path $kitchen 'lobe'
New-Item -ItemType Directory -Force -Path $kd, $lobeHome | Out-Null; Set-Content -LiteralPath (Join-Path $lobeHome 'memory.db') -Value ''
$testsTxt = Join-Path $kd 'TESTS.txt'; $recallMd = Join-Path $kd 'RECALL.md'
$red1 = "FAIL  Test-Widget                        3 passed, 1 failed (4s)`n      FAIL: loader: cache key collision ERR-4471`nFAILED: Test-Widget"   # one suite, one search: for cases that need no more
$red = "PASS  Test-Other                        4 passed, 0 failed (2s)`nFAIL  Test-Widget                        3 passed, 1 failed (4s)`n      FAIL: loader: cache key collision ERR-4471`nFAIL  Test-Slow                          timed out after 60 s (60s)`n      Not every failure is a wrong result: it ran too slow`nFAILED: Test-Widget, Test-Slow"

# The fake python: one JSON line per call (argv, folder, lobe home, uv preference, key variables left), then a search answer by LOBE_FAKE_MODE:
# hits (from LOBE_FAKE_HITS: {"<suite>": [hits], "default": [hits]}, picked by the question's first word), fail (exit 1), slow (sleeps 30 s).
$fakePy = Join-Path $tmp 'fake-python.ps1'
Set-Content -LiteralPath $fakePy -Value @'
$a = @($args); $q = if ($a.Count -ge 4) { [string]$a[3] } else { '' }
$keys = @(Get-ChildItem Env: | Where-Object { $_.Name -match '(?i)(API_KEY|AUTH_TOKEN)$' } | ForEach-Object Name)
Add-Content -LiteralPath $env:LOBE_FAKE_LOG -Value ([ordered]@{ argv = $a; q = $q; cwd = (Get-Location).Path; home = $env:ZEITGEISTD_HOME; uvpref = $env:UV_PYTHON_PREFERENCE; keys = $keys } | ConvertTo-Json -Compress -Depth 4)
if ($env:LOBE_FAKE_MODE -eq 'fail') { [Console]::Error.WriteLine('zeitgeistd: search FAIL database is locked'); exit 1 }
if ($env:LOBE_FAKE_MODE -eq 'slow') { Start-Sleep -Seconds 30; exit 0 }
$all = Get-Content -LiteralPath $env:LOBE_FAKE_HITS -Raw | ConvertFrom-Json -AsHashtable
$suite = ($q -split ' ')[0]; $hits = if ($all.ContainsKey($suite)) { $all[$suite] } else { $all['default'] }
[ordered]@{ ok = $true; question = $q; hits = @($hits); ms = 1.0 } | ConvertTo-Json -Depth 6
exit 0
'@
$script:hitN = 0
function New-Hit([string]$Src, [string]$Title, [string]$Text, [string]$Day = '2026-10-20') {
    $script:hitN++; [ordered]@{ rank = 1; item_id = ('item{0:D12}' -f $script:hitN); atom_id = "atom$script:hitN"; source = "source $Src"; source_id = $Src; t_valid = $Day
        t_ingested = "$Day 06:00:00"; title = $Title; text = $Text; score = 1.0; tokens = 40 }
}
$fixW = New-Hit 'yard-lessons' 'Yard lesson: WO-9001 fixed in repair round 1: Test-Widget' 'WO-9001 (J9001): Test-Widget failed. Fix: Repair round 1 of WO-9001 (J9001) made the tests pass. The repair crew''s account: keyed the cache by widget id instead of name. | Error: FAIL: loader: cache key collision ERR-4471'
$fixS = New-Hit 'yard-lessons' 'Yard flaky: Test-Slow (WO-0042)' 'Test-Slow failed once and passed on the retry on the same code, in WO-0042 (J42). Fix: None in the change: the suite passed on the retry.' '2026-10-18'
$noFix = New-Hit 'yard-lessons' 'Yard failure: WO-0050 tests FAILED: Test-Widget' 'WO-0050 (J50) failed at its tests step (log J50-s7-a1.log). Fix: No fix recorded yet. | Error: FAIL Test-Widget'
$ownJob = New-Hit 'yard-lessons' 'Yard failure: WO-0007 tests FAILED: Test-Widget' 'WO-0007 (J7) failed at its tests step. Fix: Repair round 1 of WO-0007 (J7) ...'
$git = New-Hit 'local_git' 'loader: key widget cache by id (fix ERR-4471)' 'commit 1a2b3c in brain-monitor: loader keys the widget cache by id.' '2026-10-19'
$personal = New-Hit 'ai-sessions' 'Session note: the cache bug and my week' 'PERSONAL-SESSION-TEXT about the cache collision.' '2026-10-21'
function Save-Hits([hashtable]$Map) { $p = Join-Path $tmp "hits-$([guid]::NewGuid().ToString('N').Substring(0, 6)).json"; $Map | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $p -Encoding utf8; $p }
$hitsMain = Save-Hits @{ 'Test-Widget' = @($ownJob, $noFix, $fixW, $personal, $git); 'Test-Slow' = @($fixS); default = @() }
$hitsNone = Save-Hits @{ default = @() }

$script:runN = 0
# Sets the test environment plus $Env ($null removes a variable). Returns the fake's log path.
function Set-RecallEnv([hashtable]$Env) {
    $script:runN++; $log = Join-Path $tmp "fake-$($script:runN).jsonl"
    $base = @{ BRAIN_KITCHEN = $kitchen; KITCHEN_JOB = 'J7'; ZEITGEISTD_REPO = $fakeRepo; ZEITGEISTD_HOME = $null; KITCHEN_LOBE_PYTHON = $fakePy; KITCHEN_APPROVED = $null
        LOBE_FAKE_LOG = $log; LOBE_FAKE_HITS = $hitsMain; LOBE_FAKE_MODE = 'hits'; ANTHROPIC_API_KEY = 'placeholder-1'; ZG16_TEST_API_KEY = 'placeholder-2'
        PATH = $saved.PATH; UV_PYTHON_PREFERENCE = $null; KITCHEN_AGENT_STEP = $null; KITCHEN_TIMEOUT = $null; RECALL_COOK_LOG = $null }
    foreach ($k in $Env.Keys) { $base[$k] = $Env[$k] }
    foreach ($k in $base.Keys) { [Environment]::SetEnvironmentVariable($k, $base[$k]) }
    $log
}
function Read-Calls([string]$Log) { , @(if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } }) }
# Runs the Step in a child pwsh. Returns { out; code; calls; md (RECALL.md or $null); lines (non-empty output lines) }.
function Invoke-Recall([string[]]$StepArgs = @(), [hashtable]$Env = @{}, [string]$Tests = $red) {
    if ($Tests -eq '<none>') { Remove-Item -LiteralPath $testsTxt -Force -ErrorAction SilentlyContinue } else { Set-Content -LiteralPath $testsTxt -Value $Tests -Encoding utf8 }
    $log = Set-RecallEnv $Env
    $out = & $pwshExe -NoProfile -File $station @StepArgs 2>&1 | Out-String; $code = $LASTEXITCODE
    [pscustomobject]@{ out = $out; code = $code; calls = (Read-Calls $log); md = $(if (Test-Path -LiteralPath $recallMd) { Get-Content -LiteralPath $recallMd -Raw } else { $null })
        lines = @($out -split "`r?`n" | Where-Object { $_.Trim() }) }
}
function Test-OneLine($r, [string]$Pattern) { $r.code -eq 0 -and $r.lines.Count -eq 1 -and $r.lines[0] -match $Pattern }

try {
    # ---- ZG16-1: reads TESTS.txt, searches through the lobe Step's way of running zeitgeistd, writes RECALL.md, one line, exit 0 ----
    $r = Invoke-Recall
    Check 'ZG16-1 a hit: exit 0 and one line naming the fixes, the suites and the scope' (Test-OneLine $r '^recall: 3 past fixes in \.kitchen\\RECALL\.md for Test-Widget, Test-Slow \(\d+ found, 1 left out: not cleared for a Cloud crew; P1 only\) ms=\d+$') $r.out
    $c = $r.calls
    Check 'ZG16-1 one search per failing suite, in TESTS.txt order (passing suites not searched)' ($c.Count -eq 2 -and $c[0].q -like 'Test-Widget *' -and $c[1].q -like 'Test-Slow *') ($c | ConvertTo-Json -Depth 4)
    Check 'ZG16-1 the call is `-I -m zeitgeistd.search <question> --json --no-model --limit 5`' ((@($c[0].argv) -join ' ') -eq "-I -m zeitgeistd.search $($c[0].q) --json --no-model --limit 5")
    Check 'ZG16-1 the question is the suite and its first FAIL line (FAIL: dropped); a stopped suite reads "timed out"' ($c[0].q -eq 'Test-Widget loader: cache key collision ERR-4471' -and $c[1].q -eq 'Test-Slow timed out') "$($c[0].q) | $($c[1].q)"
    Check 'ZG16-1 runs in the checkout with ZEITGEISTD_HOME=<kitchen>\lobe, uv''s managed python and no API key variables' ($c[0].cwd -eq $fakeRepo -and $c[0].home -eq $lobeHome -and $c[0].uvpref -eq 'only-managed' -and @($c[0].keys).Count -eq 0) ($c[0] | ConvertTo-Json)
    $mdLines = @($r.md -split "`n")
    Check 'ZG16-1 RECALL.md: the past fixes with date, work order, source, title, text and where the record is' ($r.md -match '(?m)^1\. 2026-10-20 WO-9001 \(source yard-lessons\)$' -and $r.md -match 'keyed the cache by widget id' -and $r.md -match "Full record: lobe item $($fixW.item_id)" -and $r.md -match '(?m)^2\. 2026-10-18 WO-0042 ') $r.md
    Check 'ZG16-1 RECALL.md stays short: at most 40 lines and 600 tokens (3 characters a token)' ($mdLines.Count -le 40 -and $r.md.Length -le 1800) "$($mdLines.Count) lines, $($r.md.Length) chars"
    Check 'ZG16-1 past fixes only: this work order''s own failure and a failure with no fix are left out' ($r.md -notmatch 'WO-0007' -and $r.md -notmatch 'No fix recorded yet') $r.md
    Check 'ZG16-1 read only: the lobe home gets no config.json and nothing new' (@(Get-ChildItem -LiteralPath $lobeHome -Force).Name -join ',' -eq 'memory.db')

    # privacy: the atom's class. A Cloud crew may get P1 only; a private work order with no yes for a Cloud crew = Home crew, every class
    Check 'ZG16-1 privacy: a non-private order never gets a P2 (or unknown-source) atom; P1 git and lesson atoms stay' ($r.md -notmatch 'PERSONAL-SESSION-TEXT' -and $r.md -notmatch 'Session note' -and $r.md -match 'WO-9001') $r.md
    $r = Invoke-Recall @('-Private', '-MaxFixes', '5', '-MaxTokens', '2000') @{} $red1
    Check 'ZG16-1 privacy: a private order (Home crew) keeps every class, the personal atom included' ((Test-OneLine $r 'Home crew: every class') -and $r.md -match 'PERSONAL-SESSION-TEXT' -and $r.md -match 'loader: key widget cache by id') $r.out
    $r = Invoke-Recall @('-Private', '-MaxFixes', '5', '-MaxTokens', '2000') @{ KITCHEN_APPROVED = '1' } $red1
    Check 'ZG16-1 privacy: a private order Jordan cleared for a Cloud crew (KITCHEN_APPROVED=1) gets P1 only' ((Test-OneLine $r 'P1 only') -and $r.md -notmatch 'PERSONAL-SESSION-TEXT' -and $r.md -match 'loader: key widget cache by id') $r.out

    # the why record of the tests Step (TD-EH-02) is read when it was written for this TESTS.txt; its `stopped` (TD-EH-16) names the stop
    $rd = Join-Path $kitchen 'results'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
    $rec = Join-Path $rd 'J7.tests-why-20261024T000000000Z.json'
    @{ job = 'J7'; suites = @(@{ suite = 'Test-Widget'; code = 1; why = @('FAIL: ERR-9999 from the record'); summary = 'x' }, @{ suite = 'Test-Slow'; code = 124; stopped = 'memory'; why = @('stopped') }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $rec
    $r = Invoke-Recall
    Check 'ZG16-1 the tests Step''s why record (TD-EH-02) gives the why lines; its stopped field (TD-EH-16) names the stop' ($r.calls[0].q -eq 'Test-Widget ERR-9999 from the record' -and $r.calls[1].q -eq 'Test-Slow memory cap') "$($r.calls[0].q) | $($r.calls[1].q)"
    (Get-Item -LiteralPath $rec).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-2)
    $r = Invoke-Recall
    Check 'ZG16-1 a why record from an older run is not used: TESTS.txt''s own why lines are' ($r.calls[0].q -eq 'Test-Widget loader: cache key collision ERR-4471') $r.calls[0].q
    Remove-Item -LiteralPath $rec -Force

    $r = Invoke-Recall @('-MaxTokens', '150') @{} $red1
    Check 'ZG16-1 the token cap: -MaxTokens 150 keeps one fix, cut, within 450 characters' ((Test-OneLine $r '^recall: 1 past fix in ') -and $r.md.Length -le 451 -and $r.md -match '\.\.\.') "$($r.md.Length): $($r.md)"
    $r = Invoke-Recall @() @{} "PASS  Test-Other  1 passed, 0 failed (1s)`nALL PASS"
    Check 'ZG16-1 tests that pass: nothing to recall, no search' ((Test-OneLine $r '^recall: nothing to recall') -and $r.calls.Count -eq 0 -and $null -eq $r.md) $r.out
    $r = Invoke-Recall @() @{ KITCHEN_JOB = $null }
    Check 'ZG16-1 no kitchen job: not available, exit 0' (Test-OneLine $r '^recall: not available \(no kitchen job') $r.out
    $r = Invoke-Recall @() @{} '<none>'
    Check 'ZG16-1 no TESTS.txt: not available, exit 0' (Test-OneLine $r '^recall: not available \(no test results to read\)') $r.out

    # ---- ZG16-2: hit (above), no-hit, lobe down, python missing, slow, refused: exit 0 and one line every time ----
    $r = Invoke-Recall @() @{ LOBE_FAKE_HITS = $hitsNone } $red1
    Check 'ZG16-2 no hit: "no past fix found", exit 0, no RECALL.md' ((Test-OneLine $r '^recall: no past fix found for Test-Widget \(0 found; P1 only\)') -and $null -eq $r.md) $r.out
    Set-Content -LiteralPath $recallMd -Value 'old'
    Remove-Item -LiteralPath (Join-Path $lobeHome 'memory.db')
    $r = Invoke-Recall
    Check 'ZG16-2 lobe down (no engram): not available, no search started, and an old RECALL.md is removed' ((Test-OneLine $r '^recall: not available \(no engram yet: .*memory\.db is missing\)') -and $r.calls.Count -eq 0 -and $null -eq $r.md) $r.out
    Set-Content -LiteralPath (Join-Path $lobeHome 'memory.db') -Value ''
    $r = Invoke-Recall @() @{ ZEITGEISTD_REPO = (Join-Path $tmp 'nope') }
    Check 'ZG16-2 lobe down (no checkout): not available, exit 0' (Test-OneLine $r '^recall: not available \(no zeitgeistd checkout with search\.py at ') $r.out
    $r = Invoke-Recall @() @{ KITCHEN_LOBE_PYTHON = (Join-Path $tmp 'no-python.exe') }
    Check 'ZG16-2 python missing: not available, exit 0' (Test-OneLine $r '^recall: not available \(python is missing: ') $r.out
    $emptyBin = Join-Path $tmp 'empty-bin'; New-Item -ItemType Directory -Force -Path $emptyBin | Out-Null
    $r = Invoke-Recall @() @{ KITCHEN_LOBE_PYTHON = $null; PATH = $emptyBin }
    Check 'ZG16-2 no uv on PATH: not available, exit 0' (Test-OneLine $r '^recall: not available \(uv is not installed') $r.out
    $r = Invoke-Recall @('-TimeoutSec', '2') @{ LOBE_FAKE_MODE = 'slow' } $red1
    Check 'ZG16-2 a slow lobe: the search is stopped at -TimeoutSec, not available, exit 0, no RECALL.md' ((Test-OneLine $r '^recall: not available \(the lobe search took longer than 2 s\)') -and $null -eq $r.md) $r.out
    $r = Invoke-Recall @() @{ LOBE_FAKE_MODE = 'fail' } $red1
    Check 'ZG16-2 a refused search (exit 1): not available with the lobe''s own words, exit 0' (Test-OneLine $r '^recall: not available \(the lobe search failed \(exit 1: zeitgeistd: search FAIL database is locked\)\)') $r.out

    # ---- repair.ps1 -Recall: the crew gets RECALL.md when there is one; the round always goes on; off by default ----
    Set-Content -LiteralPath (Join-Path $st 'commit.ps1') -Value 'exit 0'
    Set-Content -LiteralPath (Join-Path $st 'tests.ps1') -Value @'
param([switch]$Soft, [switch]$Impacted, [string[]]$Only = @())
Set-Content -LiteralPath (Join-Path $env:BRAIN_KITCHEN "worktrees\$env:KITCHEN_JOB\.kitchen\TESTS.txt") -Value "PASS  Test-Widget  1 passed, 0 failed (1s)`nALL PASS"; 'tests: ALL PASS'; exit 0
'@
    $cook = Join-Path $tmp 'cook.ps1'
    Set-Content -LiteralPath $cook -Value 'param([string]$Context = "", [switch]$Private, [Parameter(ValueFromRemainingArguments)]$rest) $md = Join-Path $env:BRAIN_KITCHEN "worktrees\$env:KITCHEN_JOB\.kitchen\RECALL.md"; Add-Content -LiteralPath $env:RECALL_COOK_LOG -Value (@{ context = $Context; private = [bool]$Private; recall = $(if (Test-Path $md) { Get-Content $md -Raw } else { "" }) } | ConvertTo-Json -Compress); exit 0'
    function Invoke-Repair([string[]]$RepairArgs, [hashtable]$Env = @{}) {
        Set-Content -LiteralPath $testsTxt -Value $red1 -Encoding utf8; Remove-Item -LiteralPath $recallMd -Force -ErrorAction SilentlyContinue
        $cl = Join-Path $tmp "cook-$($script:runN + 1).jsonl"; $Env.KITCHEN_AGENT_STEP = $cook; $Env.RECALL_COOK_LOG = $cl
        $log = Set-RecallEnv $Env
        $out = & $pwshExe -NoProfile -File (Join-Path $st 'repair.ps1') -Rounds 1 @RepairArgs 2>&1 | Out-String; $code = $LASTEXITCODE
        [pscustomobject]@{ out = $out; code = $code; calls = (Read-Calls $log); cook = @(if (Test-Path -LiteralPath $cl) { Get-Content -LiteralPath $cl | ForEach-Object { $_ | ConvertFrom-Json } }) }
    }
    $r = Invoke-Repair @('-Recall')
    Check 'ZG16-1 repair -Recall: the recall line is in the round''s log and the crew gets RECALL.md as an attachment' ($r.code -eq 0 -and $r.out -match '(?m)^recall: \d+ past fix(es)? in ' -and $r.cook.Count -eq 1 -and $r.cook[0].context -eq '.kitchen\TESTS.txt;.kitchen\DIFF.patch;.kitchen\RECALL.md' -and $r.cook[0].recall -match 'WO-9001' -and $r.out -match 'fixed in round 1') $r.out
    $r = Invoke-Repair @('-Recall') @{ LOBE_FAKE_MODE = 'fail' }
    Check 'ZG16-2 repair -Recall with the lobe refusing: one line, the round goes on with the usual attachments' ($r.code -eq 0 -and @($r.out -split "`r?`n" | Where-Object { $_ -match '^recall:' }).Count -eq 1 -and $r.out -match '(?m)^recall: not available' -and $r.cook.Count -eq 1 -and $r.cook[0].context -eq '.kitchen\TESTS.txt;.kitchen\DIFF.patch' -and $r.out -match 'fixed in round 1') $r.out
    $r = Invoke-Repair @('-Recall', '-Private')
    Check 'ZG16-1 repair -Recall -Private: the recall Step is told the order is private (Home crew: every class)' ($r.out -match '(?m)^recall: .*Home crew: every class' -and $r.cook[0].recall -match 'PERSONAL-SESSION-TEXT' -and $r.cook[0].private) $r.out
    Copy-Item -LiteralPath $station -Destination "$station.real"   # a recall Step that wrote RECALL.md but then failed: nothing is attached
    Set-Content -LiteralPath $station -Value "Set-Content -LiteralPath (Join-Path `$env:BRAIN_KITCHEN 'worktrees\J7\.kitchen\RECALL.md') -Value 'half'; exit 3"
    $r = Invoke-Repair @('-Recall')
    Move-Item -LiteralPath "$station.real" -Destination $station -Force
    Check 'ZG16-2 repair -Recall: a recall Step that ends with an error code never feeds the crew its RECALL.md; the round goes on' ($r.out -match '(?m)^recall: not available \(exit 3\); nothing attached' -and $r.cook[0].context -eq '.kitchen\TESTS.txt;.kitchen\DIFF.patch' -and $r.code -eq 0) $r.out
    $r = Invoke-Repair @()
    Check 'ZG16-1 repair without -Recall: no search, no recall line, the attachments exactly as before' ($r.calls.Count -eq 0 -and $r.out -notmatch 'recall:' -and $r.cook[0].context -eq '.kitchen\TESTS.txt;.kitchen\DIFF.patch' -and $r.code -eq 0) $r.out

    # ---- ZG16-3: the change note gives the one-line Spec change and the measure; no Spec turns recall on in this change ----
    $note = Get-Content -LiteralPath (Join-Path $repoRoot 'docs\changes\ZG-16.md') -Raw
    $imp = Get-Content -LiteralPath (Join-Path $repoRoot 'kitchen\recipes\improve.json') -Raw
    Check 'ZG16-3 the change note gives the improve.json repair line with "Recall": true and the scoreboard measure, two weeks before and after' ($note -match '\{ "station": "repair", "ai": true, "args": \{ "Rounds": 2, "Recall": true \}' -and $note -match 'kitchen/scoreboard\.ps1' -and $note -match '(?i)two weeks before and (two weeks )?after')
    Check 'ZG16-3 improve.json is unchanged: recall stays off until the line is added' ($imp -notmatch 'Recall')

    # ---- the one real call: the zeitgeistd checkout's search through uv, on a synthetic engram built by the lessons connector ----
    $realRepo = if ($saved.ZEITGEISTD_REPO) { $saved.ZEITGEISTD_REPO } else { [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), 'source', 'repos', 'zeitgeistd') }
    $uvCmd = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; $skipWhy = ''
    if (-not $uvCmd -or -not (Test-Path -LiteralPath (Join-Path $realRepo 'zeitgeistd\connectors\lessons.py'))) { $skipWhy = "it needs uv and a zeitgeistd checkout with the lessons connector at $realRepo" }
    else {
        # where uv cannot see the managed python the .venv was made with (a sandboxed suite's private APPDATA), uv would try to rebuild that
        # .venv (measured for ZG-07, 2026-10-23), so the real call runs only where uv sees it
        $pv = Join-Path $realRepo '.venv\pyvenv.cfg'
        $vh = if (Test-Path -LiteralPath $pv) { [string](@(Select-String -LiteralPath $pv -Pattern '^home\s*=\s*(.+)$').Matches | Select-Object -First 1 | ForEach-Object { $_.Groups[1].Value.Trim() }) } else { '' }
        $uvDir = if ($env:UV_PYTHON_INSTALL_DIR) { $env:UV_PYTHON_INSTALL_DIR } elseif ($env:APPDATA) { Join-Path $env:APPDATA 'uv\python' } else { '' }
        if (-not $vh) { $skipWhy = "the checkout has no .venv yet (scripts\test.ps1 in $realRepo makes it)" }
        elseif (-not $uvDir -or -not $vh.StartsWith($uvDir, [StringComparison]::OrdinalIgnoreCase)) { $skipWhy = "the checkout's .venv python ($vh) is not under $uvDir, where uv looks from here" }
    }
    if ($skipWhy) { Write-Host "SKIP: the real search: $skipWhy" }
    else {
        $rk = Join-Path $tmp 'real-k'; $syn = Join-Path $tmp 'synthetic'; $rlobe = Join-Path $rk 'lobe'
        New-Item -ItemType Directory -Force -Path (Join-Path $syn 'jobs'), (Join-Path $syn 'run'), $rlobe, (Join-Path $rk 'worktrees\J8\.kitchen') | Out-Null
        '{"id":"J9001","name":"improve: widget cache","recipe":"improve","vars":{"goal":"widget cache"},"steps":[{"station":"repair","args":{"Rounds":2}}]}' | Set-Content -LiteralPath (Join-Path $syn 'jobs\J9001.json')
        "repair: round 1 of 2`nThe loader keyed the cache by widget name; two widgets with one name collided. Keyed it by widget id instead.`nrepair: fixed in round 1`n" | Set-Content -LiteralPath (Join-Path $syn 'run\J9001-s8-a1.log') -NoNewline
        '{"at":"2026-10-20T10:00:00Z","job":"J9001","round":1,"broke":["FAIL  Test-Widget  3 passed, 1 failed (4s)","FAIL: loader: cache key collision ERR-4471 when two widgets share a name"]}' | Set-Content -LiteralPath (Join-Path $syn 'lessons.jsonl')
        @{ 'yard.lessons' = @(Join-Path $syn 'lessons.jsonl'); 'yard.run_dir' = (Join-Path $syn 'run'); 'yard.jobs_dir' = (Join-Path $syn 'jobs'); 'yard.private_recipes' = @() } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $rlobe 'config.json')
        $env:ZEITGEISTD_HOME = $rlobe; $env:UV_PYTHON_PREFERENCE = 'only-managed'
        Push-Location -LiteralPath $realRepo
        try { $seed = & $uvCmd.Source run --locked --quiet python -I -m zeitgeistd.connectors.lessons 2>&1 | Out-String } finally { Pop-Location; $env:ZEITGEISTD_HOME = $null; $env:UV_PYTHON_PREFERENCE = $null }
        Check 'real: the lessons connector builds the synthetic engram (1 lesson atom) in the temp lobe home' ($seed -match 'zeitgeistd: lessons ok items=1 atoms=1') $seed
        Set-Content -LiteralPath (Join-Path $rk 'worktrees\J8\.kitchen\TESTS.txt') -Value "FAIL  Test-Widget  3 passed, 1 failed (4s)`n      FAIL: loader: cache key collision ERR-4471 when two widgets share a name`nFAILED: Test-Widget"
        [void](Set-RecallEnv @{ BRAIN_KITCHEN = $rk; KITCHEN_JOB = 'J8'; ZEITGEISTD_REPO = $realRepo; KITCHEN_LOBE_PYTHON = $null })
        $out = & $pwshExe -NoProfile -File $station 2>&1 | Out-String; $code = $LASTEXITCODE
        $md = Get-Content -LiteralPath (Join-Path $rk 'worktrees\J8\.kitchen\RECALL.md') -Raw -ErrorAction SilentlyContinue
        Check 'real: the real search finds the past fix; RECALL.md carries the crew''s account, WO-9001 and its date' ($code -eq 0 -and $out -match '^recall: 1 past fix in ' -and $md -match 'Keyed it by widget id instead' -and $md -match '2026-10-20 WO-9001') "$out`n$md"
    }
}
finally {
    foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "LobeRecall tests: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
exit 0
