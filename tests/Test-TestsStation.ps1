# Tests for the tests station (kitchen/stations/tests.ps1): a suite that crashes before its summary line is reported as FAIL,
# never crashes the station itself (J11 and J21 were set aside that way). Self-cleaning.
$ErrorActionPreference = 'Stop'
$st = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\tests.ps1')).Path
$dir = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-station-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
# a private kitchen for every station call: with BRAIN_KITCHEN blank the station used Jordan's live one, and these runs wrote 69 lines of
# made-up suite times (repos failfast, order, envprobe, kitchen-test-station-*) into it on 10-22; that history then ran 'order' in parallel
$svTop = $env:BRAIN_KITCHEN; $env:BRAIN_KITCHEN = Join-Path $dir 'kitchen'
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'tests'), (Join-Path $dir '.kitchen'), $env:BRAIN_KITCHEN | Out-Null
    Set-Content (Join-Path $dir 'tests\Test-Good.ps1') 'Write-Output "Good tests: 2 passed, 0 failed"; exit 0'
    Set-Content (Join-Path $dir 'tests\Test-Crash.ps1') '$x = $null; $x[0].y; throw "boom before any summary"'
    $out = $null; $threw = $false
    try { $out = & $st -Dir $dir -SuiteTimeoutSec 60 *>&1 | Out-String; $code = $LASTEXITCODE } catch { $threw = $true; $out = "$_" }
    Check 'station does not crash when a suite dies before its summary' (-not $threw)
    Check 'crashed suite reported as FAIL with a plain reason' ($out -match 'FAIL\s+Test-Crash\s+crashed before its summary line')
    Check 'good suite still reported as PASS' ($out -match 'PASS\s+Test-Good')
    Check 'station ends FAILED and exits 1' ($out -match 'FAILED: Test-Crash' -and $code -eq 1)
    Check 'results written to TESTS.txt' ((Get-Content (Join-Path $dir '.kitchen\TESTS.txt') -Raw) -match 'FAILED: Test-Crash')
    Check 'a crash with no FAIL lines still tells the repair cook what happened' ((Get-Content (Join-Path $dir '.kitchen\TESTS.txt') -Raw) -match 'boom before any summary')
    $out2 = & $st -Dir $dir -SuiteTimeoutSec 60 -Soft *>&1 | Out-String; $code2 = $LASTEXITCODE
    Check 'soft mode reports FAILED but exits 0 (the repair station decides)' ($out2 -match 'FAILED: Test-Crash' -and $code2 -eq 0)
    # Say why (TD-EH-02): a red run leaves its reasons outside the worktree. On 10-23 a verify run on main (no .kitchen) dropped them,
    # and "crashed before its summary line" was all the Yard kept. The first run above had no job: the record is nojob.tests-why-*.json
    $whyRecs = @(Get-ChildItem (Join-Path $env:BRAIN_KITCHEN 'results') -Filter 'nojob.tests-why-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
    $wr = if ($whyRecs.Count) { Get-Content $whyRecs[0].FullName -Raw | ConvertFrom-Json } else { $null }
    Check 'say why: a red run writes results\<job>.tests-why-<time>.json in the kitchen and names it in the log' ($whyRecs.Count -eq 2 -and $out -match 'tests: why: results\\nojob\.tests-why-\d{8}T\d{9}Z\.json' -and $wr.final -eq 'FAILED: Test-Crash' -and $wr.dir -eq $dir -and $wr.job -eq '')
    $crashRec = if ($wr) { @($wr.suites | Where-Object { $_.suite -eq 'Test-Crash' })[0] } else { $null }
    Check 'say why: the record has the failing suite with its exit code, seconds, summary and the lines that say why' ($crashRec -and $crashRec.code -eq 1 -and $null -ne $crashRec.sec -and [double]$crashRec.sec -ge 0 -and $crashRec.summary -eq 'crashed before its summary line' -and @($crashRec.why | Where-Object { $_ -match 'boom before any summary' }).Count -ge 1 -and @($crashRec.why).Count -le 12)
    Check 'say why: a passing suite is not in the record' (-not @($wr.suites | Where-Object { $_.suite -eq 'Test-Good' }).Count)
    Check 'say why: the step log carries the why lines, indented under the FAIL line' ($out -match '(?m)^tests:\s{3,}\S.*boom before any summary')
    $evs = @(Get-Content (Join-Path $env:BRAIN_KITCHEN 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'tests.failed' })
    Check 'say why: a tests.failed event names the suites, a short reason and the record' ($evs.Count -eq 2 -and (@($evs[0].suites) -join ',') -eq 'Test-Crash' -and $evs[0].why -match '^Test-Crash: .*boom before any summary' -and $evs[0].record -eq ('results\' + $whyRecs[0].Name) -and $evs[0].job -eq '')

    # a flaky suite (fails once, then passes on the same code) passes with a note and is logged, not blamed on the change
    $fd = Join-Path $dir 'flaky'; New-Item -ItemType Directory -Force -Path (Join-Path $fd 'tests') | Out-Null
    # marks a suite leaves for its own retry go in a folder labelled Low: the station runs suites at Low integrity (rust/kitchen-sandbox),
    # which cannot write this test's own (Medium) folders
    $shared = Join-Path $dir 'shared'; New-Item -ItemType Directory -Force -Path $shared | Out-Null; & icacls.exe $shared /setintegritylevel '(OI)(CI)low' /Q 2>&1 | Out-Null
    $mark = Join-Path $shared 'ran-once'
    Set-Content (Join-Path $fd 'tests\Test-Flaky.ps1') "if (Test-Path '$mark') { 'Flaky tests: 1 passed, 0 failed'; exit 0 } else { Set-Content '$mark' 1; 'FAIL: timing'; 'Flaky tests: 0 passed, 1 failed'; exit 1 }"
    $fk = Join-Path $dir 'fkroot'; New-Item -ItemType Directory -Force -Path $fk | Out-Null
    $svk = $env:BRAIN_KITCHEN; $env:BRAIN_KITCHEN = $fk
    try { $o3 = & $st -Dir $fd -SuiteTimeoutSec 60 *>&1 | Out-String; $c3 = $LASTEXITCODE } finally { $env:BRAIN_KITCHEN = $svk }
    Check 'flaky suite: passes on retry, says so, station passes' ($o3 -match 'PASS\s+Test-Flaky\s+.*flaky' -and $o3 -match 'ALL PASS' -and $c3 -eq 0)
    Check 'flaky suite: logged to flaky.jsonl with what failed' ((Get-Content (Join-Path $fk 'flaky.jsonl') -Raw) -match '"suite":"Test-Flaky"' -and (Get-Content (Join-Path $fk 'flaky.jsonl') -Raw) -match 'timing')
    Check 'a broken suite is not retried into a pass' ($out -match 'FAILED: Test-Crash')

    # each suite gets a fresh empty kitchen of its own and is marked under test: never a blank BRAIN_KITCHEN (blank = Jordan's live
    # kitchen), and no approval from the job leaks into a suite
    $ed = Join-Path $dir 'envprobe'; New-Item -ItemType Directory -Force -Path (Join-Path $ed 'tests') | Out-Null
    $probe = Join-Path $shared 'probe.txt'   # Low-labelled: the sandboxed suite writes it
    Set-Content (Join-Path $ed 'tests\Test-Probe.ps1') "Set-Content '$probe' (`"`$env:BRAIN_KITCHEN|`$env:KITCHEN_UNDER_TEST|`$env:KITCHEN_APPROVED|`" + (Test-Path -LiteralPath `"`$env:BRAIN_KITCHEN`")); 'Probe tests: 1 passed, 0 failed'; exit 0"
    $sva = $env:KITCHEN_APPROVED; $env:KITCHEN_APPROVED = '1'; $before = "$env:BRAIN_KITCHEN|$env:KITCHEN_UNDER_TEST"
    try { $null = & $st -Dir $ed -SuiteTimeoutSec 60 *>&1 } finally { $env:KITCHEN_APPROVED = $sva }
    $pv = "$(Get-Content $probe -Raw -ErrorAction SilentlyContinue)".Trim() -split '\|'
    Check 'suite env: BRAIN_KITCHEN is a fresh kt- folder, never blank' ($pv[0] -match '\\kt-[0-9a-f]{32}$' -and $pv[3] -eq 'True')
    Check 'suite env: marked under test, no approval leaks in' ($pv[1] -eq '1' -and $pv[2] -eq '')
    Check 'suite env: the sandbox is removed afterwards' ($pv[0] -and -not (Test-Path -LiteralPath $pv[0]))
    Check 'suite env: the station restores its own environment' ("$env:BRAIN_KITCHEN|$env:KITCHEN_UNDER_TEST" -eq $before)
    # under test, kitchen.ps1 refuses the live kitchen even with BRAIN_KITCHEN blanked (LOCALAPPDATA points at a scratch folder here,
    # so this check itself can never reach the real kitchen)
    $sve = @{ k = $env:BRAIN_KITCHEN; u = $env:KITCHEN_UNDER_TEST; l = $env:LOCALAPPDATA }
    try {
        $env:LOCALAPPDATA = Join-Path $dir 'fake-localappdata'; $env:BRAIN_KITCHEN = $null; $env:KITCHEN_UNDER_TEST = '1'
        $ko = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1') status 2>&1 | Out-String; $kc = $LASTEXITCODE
    } finally { $env:BRAIN_KITCHEN = $sve.k; $env:KITCHEN_UNDER_TEST = $sve.u; $env:LOCALAPPDATA = $sve.l }
    Check 'under test: kitchen.ps1 refuses the live kitchen' ($kc -eq 2 -and $ko -match 'refusing to use the live kitchen' -and -not (Test-Path (Join-Path $dir 'fake-localappdata\brain-kitchen')))

    # the repair station: nothing to do when the tests passed; needs a job
    $kr = Join-Path $dir 'kroot'; New-Item -ItemType Directory -Force -Path (Join-Path $kr 'worktrees\J1\.kitchen') | Out-Null
    Set-Content (Join-Path $kr 'worktrees\J1\.kitchen\TESTS.txt') "PASS  Test-Good  2 passed`nALL PASS"
    $rp = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\repair.ps1')).Path
    $sv = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB }
    try {
        $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_JOB = 'J1'
        $o = & pwsh -NoProfile -File $rp 2>&1 | Out-String
        Check 'repair: tests passed -> nothing to fix, ALL PASS, exit 0' ($LASTEXITCODE -eq 0 -and $o -match 'nothing to fix' -and $o -match 'tests: ALL PASS')
        $env:KITCHEN_JOB = $null
        $o = & pwsh -NoProfile -File $rp 2>&1 | Out-String
        Check 'repair: no job -> refuses' ($LASTEXITCODE -eq 2)
    } finally { $env:BRAIN_KITCHEN = $sv.k; $env:KITCHEN_JOB = $sv.j }
    # rework: the reviewer's critique is handed to a cook, used once, and the tests run again
    $wt = Join-Path $kr 'worktrees\J2'; New-Item -ItemType Directory -Force -Path (Join-Path $wt '.kitchen'), (Join-Path $wt 'tests') | Out-Null
    & git -C $wt init -q 2>&1 | Out-Null; Set-Content (Join-Path $wt 'tests\Test-Ok.ps1') "'Ok tests: 1 passed, 0 failed'; exit 0"
    & git -C $wt add -A 2>&1 | Out-Null; & git -C $wt -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    Set-Content (Join-Path $wt '.kitchen\BASE') ((& git -C $wt rev-parse HEAD).Trim())
    Set-Content (Join-Path $wt 'feature.txt') 'the change'; & git -C $wt add feature.txt 2>&1 | Out-Null; & git -C $wt -c user.name=t -c user.email=t@localhost commit -q -m change 2>&1 | Out-Null
    Set-Content (Join-Path $wt '.kitchen\TESTS.txt') "PASS  Test-Ok`nALL PASS"
    Set-Content (Join-Path $wt '.kitchen\CRITIQUE.md') '# The reviewer sent this change back: feature.txt needs a second line'
    $fake = Join-Path $dir 'fake-agent.ps1'; Set-Content $fake "param([string]`$WorkDir, [string]`$Context, [Parameter(ValueFromRemainingArguments)]`$rest)`nAdd-Content (Join-Path `$WorkDir 'feature.txt') 'fixed per critique'; Add-Content (Join-Path `$WorkDir '..\..\agent-calls.txt') `$Context; exit 0"
    $sv2 = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB; a = $env:KITCHEN_AGENT_STEP }
    try {
        $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_JOB = 'J2'; $env:KITCHEN_AGENT_STEP = $fake
        $o = & pwsh -NoProfile -File $rp 2>&1 | Out-String; $rc = $LASTEXITCODE
        Check 'rework: the cook gets the critique, the fix is saved, tests pass' ($rc -eq 0 -and $o -match 'rework round' -and $o -match 'reworked; tests pass' -and (Get-Content (Join-Path $kr 'agent-calls.txt') -Raw) -match 'CRITIQUE\.md' -and (& git -C $wt log -1 --format=%s) -match 'rework')
        Check 'rework: the critique is used once' (-not (Test-Path (Join-Path $wt '.kitchen\CRITIQUE.md')))
        $o = & pwsh -NoProfile -File $rp 2>&1 | Out-String
        Check 'rework: next time with no critique, nothing to fix' ($o -match 'nothing to fix')
        # the cook gets a share of the step's time (room left for the commit and the tests after it), never the whole limit
        $fakeT = Join-Path $dir 'fake-agent-t.ps1'; Set-Content $fakeT "param([string]`$WorkDir, [int]`$TimeoutSec, [Parameter(ValueFromRemainingArguments)]`$rest)`nSet-Content (Join-Path `$WorkDir '..\..\agent-timeout.txt') `$TimeoutSec; Add-Content (Join-Path `$WorkDir 'feature.txt') 'again'; exit 0"
        Set-Content (Join-Path $wt '.kitchen\CRITIQUE.md') '# sent back again'
        $env:KITCHEN_AGENT_STEP = $fakeT; $env:KITCHEN_TIMEOUT = '9000'
        try { $null = & pwsh -NoProfile -File $rp 2>&1 } finally { $env:KITCHEN_TIMEOUT = $null }
        $ts = [int](Get-Content (Join-Path $kr 'agent-timeout.txt') -ErrorAction SilentlyContinue)
        Check 'repair: the cook gets a share of the step time, not all of it' ($ts -ge 300 -and $ts -le 2100)
    } finally { $env:BRAIN_KITCHEN = $sv2.k; $env:KITCHEN_JOB = $sv2.j; $env:KITCHEN_AGENT_STEP = $sv2.a }
    # the job's own run records its result outside the worktree (results\<job>.tests.json), for the commit it tested: auto-merge reads only that
    $r2 = Get-Content (Join-Path $kr 'results\J2.tests.json') -Raw | ConvertFrom-Json
    Check 'results: job run writes results\<job>.tests.json for the tested commit' ($r2.final -eq 'ALL PASS' -and $r2.sha -eq (& git -C $wt rev-parse HEAD).Trim() -and -not @($r2.flaky | Where-Object { $_ }).Count)
    $w3 = Join-Path $kr 'worktrees\J3'; New-Item -ItemType Directory -Force -Path (Join-Path $w3 'tests'), (Join-Path $w3 '.kitchen') | Out-Null
    $m3 = Join-Path $shared 'j3-ran-once'
    Set-Content (Join-Path $w3 'tests\Test-Flaky.ps1') "if (Test-Path '$m3') { 'Flaky tests: 1 passed, 0 failed'; exit 0 } else { Set-Content '$m3' 1; 'FAIL: timing'; 'Flaky tests: 0 passed, 1 failed'; exit 1 }"
    & git -C $w3 init -q 2>&1 | Out-Null; Set-Content (Join-Path $w3 '.gitignore') '.kitchen/'; & git -C $w3 add -A 2>&1 | Out-Null; & git -C $w3 -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    # a suite that commits while the tests run (AI-written test code can) voids the result
    $w4 = Join-Path $kr 'worktrees\J4'; New-Item -ItemType Directory -Force -Path (Join-Path $w4 'tests'), (Join-Path $w4 '.kitchen') | Out-Null
    Set-Content (Join-Path $w4 'tests\Test-Sneaky.ps1') "Set-Content (Join-Path '$w4' 'x.txt') 'sneaky'; & git -C '$w4' add x.txt 2>&1 | Out-Null; & git -C '$w4' -c user.name=t -c user.email=t@localhost commit -q -m sneaky 2>&1 | Out-Null; 'Sneaky tests: 1 passed, 0 failed'; exit 0"
    & git -C $w4 init -q 2>&1 | Out-Null; Set-Content (Join-Path $w4 '.gitignore') '.kitchen/'; & git -C $w4 add -A 2>&1 | Out-Null; & git -C $w4 -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null; $b4 = (& git -C $w4 rev-parse HEAD).Trim()
    $sv3 = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB }
    try {
        $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_JOB = 'J3'; $null = & $st -SuiteTimeoutSec 60 *>&1 | Out-String
        $env:KITCHEN_JOB = 'J4'; $null = & $st -SuiteTimeoutSec 60 *>&1 | Out-String
    } finally { $env:BRAIN_KITCHEN = $sv3.k; $env:KITCHEN_JOB = $sv3.j }
    $r3 = Get-Content (Join-Path $kr 'results\J3.tests.json') -Raw | ConvertFrom-Json
    Check 'results: a suite that passed only on its retry is named as flaky (auto-merge asks Jordan)' ($r3.final -eq 'ALL PASS' -and @($r3.flaky) -contains 'Test-Flaky')
    $r4 = Get-Content (Join-Path $kr 'results\J4.tests.json') -Raw | ConvertFrom-Json
    # sandboxed (Low) the sneaky commit is refused outright; unsandboxed it lands and must void the result. Either way: no pass on changed code
    Check 'results: code that changed while the tests ran is not a pass' ($r4.final -match 'changed while the tests ran' -or ((& git -C $w4 rev-parse HEAD).Trim() -eq $b4 -and -not (Test-Path -LiteralPath (Join-Path $w4 'x.txt'))))
    # say why, for a job: the record and the event carry the job and the suite's own exit code (kept through the retry), and a line
    # shaped like a secret never leaves the worktree (not in the record, not in the event, not in the step log)
    $w5 = Join-Path $kr 'worktrees\J5'; New-Item -ItemType Directory -Force -Path (Join-Path $w5 'tests'), (Join-Path $w5 '.kitchen') | Out-Null
    $tok = 'ghp_' + ('A' * 36)
    Set-Content (Join-Path $w5 'tests\Test-Leak.ps1') "'FAIL: token is $tok'; 'FAIL: the second reason'; 'Leak tests: 0 passed, 2 failed'; exit 3"
    $sv5 = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB }
    try { $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_JOB = 'J5'; $o5 = & $st -SuiteTimeoutSec 60 *>&1 | Out-String } finally { $env:BRAIN_KITCHEN = $sv5.k; $env:KITCHEN_JOB = $sv5.j }
    $r5w = @(Get-ChildItem (Join-Path $kr 'results') -Filter 'J5.tests-why-*.json' -ErrorAction SilentlyContinue)
    $j5 = if ($r5w.Count) { Get-Content $r5w[0].FullName -Raw | ConvertFrom-Json } else { $null }
    $leak = if ($j5) { @($j5.suites | Where-Object { $_.suite -eq 'Test-Leak' })[0] } else { $null }
    Check 'say why: a job run records its job and the suite''s own exit code (3, kept through the retry)' ($r5w.Count -eq 1 -and $j5.job -eq 'J5' -and $leak.code -eq 3 -and $leak.summary -match '0 passed, 2 failed' -and $o5 -match 'tests: why: results\\J5\.tests-why-')
    Check 'say why: a line shaped like a secret is withheld from the record, the event and the step log' ($leak.why[0] -match 'withheld.*github-token' -and $leak.why[1] -eq 'FAIL: the second reason' -and -not ((Get-Content $r5w[0].FullName -Raw) -match 'ghp_A') -and -not ((Get-Content (Join-Path $kr 'events.jsonl') -Raw) -match 'ghp_A') -and -not ($o5 -match 'ghp_A') -and $o5 -match '(?m)^tests:\s{3,}FAIL: the second reason')
    $ev5 = @(Get-Content (Join-Path $kr 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'tests.failed' })
    # the short reason is the first FAIL line that can be shown (the withheld one is not it); J5 is no git repo, so its sha is blank
    Check 'say why: the event carries the job, the suites and a short reason' ($ev5.Count -eq 1 -and $ev5[0].job -eq 'J5' -and (@($ev5[0].suites) -join ',') -eq 'Test-Leak' -and $ev5[0].why -eq 'Test-Leak: FAIL: the second reason' -and [string]$ev5[0].sha -eq '' -and $ev5[0].record -eq ('results\' + $r5w[0].Name))
    Check 'say why: the green runs before it (J2, J3, J4) wrote no why record and no tests.failed event' (@(Get-ChildItem (Join-Path $kr 'results') -Filter '*.tests-why-*.json').Count -eq 1 -and $ev5.Count -eq 1)
    Check 'say why: TESTS.txt is as it was (the why lines whole, nothing withheld there)' ((Get-Content (Join-Path $w5 '.kitchen\TESTS.txt') -Raw) -match "FAIL: token is $tok")
    Check 'tests station: skips no suite by default (Test-VerifyAll runs too)' ((Get-Content $st -Raw).Contains('[string]$Skip = '''',') -and -not @((Get-Content (Join-Path $PSScriptRoot '..\kitchen\recipes\improve.json') -Raw | ConvertFrom-Json).steps | Where-Object { $_.args.Skip }).Count)
    $rec = Get-Content (Join-Path $PSScriptRoot '..\kitchen\recipes\improve.json') -Raw | ConvertFrom-Json
    Check 'improve recipe: a review sent back goes to repair once' (($rec.steps | Where-Object { $_.args.Role -eq 'check' }).reworkTo -eq 'repair')
    $names = @($rec.steps.station); $ti = [array]::IndexOf($names, 'tests')
    Check 'improve recipe: soft tests, then repair (an AI station that must end ALL PASS), then the taster' ($rec.steps[$ti].args.Soft -eq $true -and $names[$ti + 1] -eq 'repair' -and $rec.steps[$ti + 1].ai -eq $true -and $rec.steps[$ti + 1].mustMatch -eq 'ALL PASS' -and $names[$ti + 2] -eq 'mutate' -and $rec.steps[$ti + 3].args.Role -eq 'check')

    # suite ordering: related suites run first (name+content, then content, then unrelated)
    $ordDir = Join-Path $dir 'order'; New-Item -ItemType Directory -Force -Path (Join-Path $ordDir 'tests'), (Join-Path $ordDir '.kitchen') | Out-Null
    Set-Content (Join-Path $ordDir 'tests\Test-Unrelated.ps1') 'Write-Output "Unrelated: 1 passed, 0 failed"; exit 0'
    Set-Content (Join-Path $ordDir 'tests\Test-ContentRelated.ps1') '# mentions target.ps1 in content`nWrite-Output "ContentRelated: 1 passed, 0 failed"; exit 0'
    Set-Content (Join-Path $ordDir 'tests\Test-Target.ps1') '# mentions target.ps1 in content and name`nWrite-Output "Target: 1 passed, 0 failed"; exit 0'
    $outOrd = & $st -Dir $ordDir -SuiteTimeoutSec 60 -ChangedFiles 'target.ps1' *>&1 | Out-String
    $codeOrd = $LASTEXITCODE
    $posTarget = $outOrd.IndexOf('Test-Target')
    $posContent = $outOrd.IndexOf('Test-ContentRelated')
    $posUnrelated = $outOrd.IndexOf('Test-Unrelated')
    Check 'suite ordering: related suites run first' ($codeOrd -eq 0 -and $posTarget -ge 0 -and $posTarget -lt $posContent -and $posContent -lt $posUnrelated)

    # soft mode fail-fast: stops after first 2 failing suites, marks remainder as not run (fail fast), exits 0
    $ffDir = Join-Path $dir 'failfast'; New-Item -ItemType Directory -Force -Path (Join-Path $ffDir 'tests'), (Join-Path $ffDir '.kitchen') | Out-Null
    Set-Content (Join-Path $ffDir 'tests\Test-Fail1.ps1') 'Write-Output "FAIL: f1"; exit 1'
    Set-Content (Join-Path $ffDir 'tests\Test-Fail2.ps1') 'Write-Output "FAIL: f2"; exit 1'
    Set-Content (Join-Path $ffDir 'tests\Test-Pass3.ps1') 'Write-Output "Pass3: 1 passed, 0 failed"; exit 0'
    Set-Content (Join-Path $ffDir 'tests\Test-Fail4.ps1') 'Write-Output "FAIL: f4"; exit 1'
    $outSoft = & $st -Dir $ffDir -SuiteTimeoutSec 60 -Soft *>&1 | Out-String
    $codeSoft = $LASTEXITCODE
    Check 'soft mode fail-fast: stops after 2 failures and exits 0' ($codeSoft -eq 0 -and $outSoft -match 'FAILED: Test-Fail1, Test-Fail2' -and $outSoft -notmatch 'FAILED:.*Test-Fail4')
    Check 'soft mode fail-fast: reports unrun suites as not run (fail fast)' ($outSoft -match '-\s+Test-Pass3\s+not run \(fail fast\)' -and $outSoft -match '-\s+Test-Fail4\s+not run \(fail fast\)')

    # hard mode: all suites run to completion regardless of failure count
    $outHard = & $st -Dir $ffDir -SuiteTimeoutSec 60 *>&1 | Out-String
    $codeHard = $LASTEXITCODE
    Check 'hard mode: executes all suites and exits 1' ($codeHard -eq 1 -and $outHard -match 'FAILED: Test-Fail1, Test-Fail2, Test-Fail4')
    Check 'hard mode: does not mark any suite as not run' ($outHard -match 'PASS\s+Test-Pass3' -and $outHard -notmatch 'not run \(fail fast\)')
    # say why: only red suites are in the record: not the passing one, not the ones fail-fast left unrun; the soft run is marked soft
    $ffRecs = @(Get-ChildItem (Join-Path $env:BRAIN_KITCHEN 'results') -Filter 'nojob.tests-why-*.json' | Sort-Object Name)
    $hardRec = Get-Content $ffRecs[-1].FullName -Raw | ConvertFrom-Json; $softRec = Get-Content $ffRecs[-2].FullName -Raw | ConvertFrom-Json
    Check 'say why: only red suites are in the record (not the passing one, not the ones fail-fast left unrun)' ((@($hardRec.suites | ForEach-Object { $_.suite }) -join ',') -eq 'Test-Fail1,Test-Fail2,Test-Fail4' -and $hardRec.soft -eq $false -and (@($softRec.suites | ForEach-Object { $_.suite }) -join ',') -eq 'Test-Fail1,Test-Fail2' -and $softRec.soft -eq $true)

    # per-suite seconds recorded in TESTS.txt
    $testsTxt = Get-Content (Join-Path $dir '.kitchen\TESTS.txt') -Raw
    Check 'per-suite seconds recorded in TESTS.txt for PASS and FAIL' ($testsTxt -match 'PASS\s+Test-Good\s+.*\(\d+(\.\d+)?s\)' -and $testsTxt -match 'FAIL\s+Test-Crash\s+.*\(\d+(\.\d+)?s\)')

    # --- stopped, not failed (TD-EH-16) ---
    # A suite killed at its time limit (exit 124) or memory cap (125) read "crashed before its summary line" (or a stray "passed" line it
    # printed), and the repair Crew chased a crash. Tiny fake suites: Test-Slow prints a "passed" progress line and two verdict-shaped lines,
    # then sleeps past a 3 s limit; Test-Big grows in 50 MB steps past the cap (300 MB unsandboxed; the sandbox's floor is 1,024 MB, so it
    # stops growing at 1,500 MB); Test-Own124 exits 124 by itself, which is its own code, not a timeout. Sandboxed, Test-Big is one pwsh
    # process: it reaches the cap only because kitchen-sandbox.exe's hard limit is 1.5x --mem (.NET stops its heap at 75% of that).
    # Until 10-24 it was 1.25x, Test-Big got OutOfMemory at ~955 MB, slept and read "timed out"; an exe built before then still does.
    . (Join-Path $PSScriptRoot '..\rust\kitchen-sandbox\sandbox.ps1')
    $sd = Join-Path $dir 'stopped'; New-Item -ItemType Directory -Force -Path (Join-Path $sd 'tests'), (Join-Path $sd '.kitchen') | Out-Null
    Set-Content (Join-Path $sd 'tests\Test-Slow.ps1') "'step one passed'; 'FAILED: Test-Fake'; 'ALL PASS'; Start-Sleep 120"
    Set-Content (Join-Path $sd 'tests\Test-Big.ps1') '$l = [Collections.Generic.List[byte[]]]::new(); foreach ($k in 1..30) { $a = New-Object byte[] 50MB; for ($i=0; $i -lt $a.Length; $i += 4096) { $a[$i] = 1 }; $l.Add($a) }; Start-Sleep 60'
    Set-Content (Join-Path $sd 'tests\Test-Own124.ps1') "'FAIL: my own reason'; 'Own124 tests: 0 passed, 1 failed'; exit 124"
    $sk = Join-Path $dir 'stopkroot'; New-Item -ItemType Directory -Force -Path $sk | Out-Null
    $capMB = if ((Get-KitchenSandbox (Join-Path $PSScriptRoot '..\kitchen') $sk).mode -eq 'off') { 300 } else { 1024 }
    $svs = $env:BRAIN_KITCHEN; $env:BRAIN_KITCHEN = $sk
    try { $os = & $st -Dir $sd -SuiteTimeoutSec 3 -MaxMB 300 *>&1 | Out-String; $cs = $LASTEXITCODE } finally { $env:BRAIN_KITCHEN = $svs }
    Check 'stopped: past its time limit reads "timed out after 3 s", not a crash and not its stray "passed" line' ($os -match '(?m)^tests: FAIL\s+Test-Slow\s+timed out after 3 s \([\d.]+s\)' -and $os -notmatch 'Test-Slow\s+(crashed|step one)')
    Check "stopped: past its memory cap reads ""stopped at the memory cap ($capMB MB)""" ($os -match "(?m)^tests: FAIL\s+Test-Big\s+stopped at the memory cap \($capMB MB\) \([\d.]+s\)" -and $os -notmatch 'Test-Big\s+crashed')
    Check 'stopped: the FAILED line verify parses is unchanged, and the station exits 1' ($os -match '(?m)^tests: FAILED: Test-Big, Test-Own124, Test-Slow\s*$' -and $cs -eq 1)
    Check 'stopped: the step log says plainly it was too slow or too large, not a failed assertion' ($os -match '(?m)^tests:\s{3,}FAIL: timed out after 3 s: .*too slow or hung\. Being stopped is not a failed assertion' -and $os -match "(?m)^tests:\s{3,}FAIL: stopped at the memory cap \($capMB MB\): .*too much memory\. Being stopped is not a failed assertion")
    Check 'stopped: the suite''s own verdict words stay bent in the step log (TD-EH-02 escape kept)' ($os -match '(?m)^tests:\s{3,}FAILED; Test-Fake' -and $os -notmatch 'FAILED: Test-Fake' -and $os -notmatch 'ALL PASS')
    $stx = Get-Content (Join-Path $sd '.kitchen\TESTS.txt') -Raw
    Check 'stopped: TESTS.txt (what repair reads) has the stop and the plain note under it' ($stx -match '(?m)^FAIL\s+Test-Slow\s+timed out after 3 s' -and $stx -match '(?m)^\s+FAIL: timed out after 3 s: .*not a failed assertion' -and $stx -match "(?m)^FAIL\s+Test-Big\s+stopped at the memory cap \($capMB MB\)" -and $stx -match '(?m)^FAILED: Test-Big, Test-Own124, Test-Slow\s*$')
    $sRecs = @(Get-ChildItem (Join-Path $sk 'results') -Filter 'nojob.tests-why-*.json' -ErrorAction SilentlyContinue)
    $sRec = if ($sRecs.Count -eq 1) { Get-Content $sRecs[0].FullName -Raw | ConvertFrom-Json } else { $null }
    $slowR = @($sRec.suites | Where-Object { $_.suite -eq 'Test-Slow' })[0]; $bigR = @($sRec.suites | Where-Object { $_.suite -eq 'Test-Big' })[0]; $ownR = @($sRec.suites | Where-Object { $_.suite -eq 'Test-Own124' })[0]
    Check 'stopped: the why record says timed out (code 124, stopped timeout, limitSec 3, the plain note first)' ($slowR -and $slowR.code -eq 124 -and $slowR.summary -eq 'timed out after 3 s' -and $slowR.stopped -eq 'timeout' -and $slowR.limitSec -eq 3 -and "$($slowR.why[0])" -match '^FAIL: timed out after 3 s: .*not a failed assertion' -and @($slowR.why).Count -le 12 -and @($slowR.why) -contains 'FAILED: Test-Fake')
    Check 'stopped: the why record says memory cap (code 125, stopped memory, capMB)' ($bigR -and $bigR.code -eq 125 -and $bigR.summary -eq "stopped at the memory cap ($capMB MB)" -and $bigR.stopped -eq 'memory' -and $bigR.capMB -eq $capMB -and "$($bigR.why[0])" -match '^FAIL: stopped at the memory cap')
    Check 'stopped: a suite''s own exit 124 (no kill line) is not called a timeout' ($ownR -and $ownR.code -eq 124 -and $ownR.summary -eq 'Own124 tests: 0 passed, 1 failed' -and $null -eq $ownR.stopped -and "$($ownR.why[0])" -eq 'FAIL: my own reason' -and $os -match '(?m)^tests: FAIL\s+Test-Own124\s+Own124 tests: 0 passed, 1 failed')
    $sEv = @(Get-Content (Join-Path $sk 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'tests.failed' })
    Check 'stopped: the tests.failed event''s short reason says timed out and memory cap' ($sEv.Count -eq 1 -and $sEv[0].why -match 'Test-Slow: FAIL: timed out after 3 s' -and $sEv[0].why -match "Test-Big: FAIL: stopped at the memory cap \($capMB MB\)" -and $sEv[0].why -match 'Test-Own124: FAIL: my own reason')
    # the kill lines of both limiters, read the same way (the station's own Get-SuiteStop, taken from its source): kitchen-sandbox.exe says
    # "timeout 1800s" / "memory cap 4000 MB", run-bounded "timeout after 600 s" / "memory cap 3000 MB"; a kill line for another code is not a stop
    $fnAst = [Management.Automation.Language.Parser]::ParseFile($st, [ref]$null, [ref]$null).Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SuiteStop' }, $true)
    . ([scriptblock]::Create($fnAst.Extent.Text))
    $g1 = Get-SuiteStop 124 "x`nkitchen-sandbox: killed the tree (exit 124: timeout 1800s)" 60 2000
    $g2 = Get-SuiteStop 125 "kitchen-sandbox: killed the tree (exit 125: memory cap 4000 MB)`n" 60 2000
    $g3 = Get-SuiteStop 124 'run-bounded: killed C:\a (b)\Test-X.ps1 (exit 124: timeout after 600 s)' 60 2000
    $g4 = Get-SuiteStop 125 'run-bounded: killed C:\a\Test-X.ps1 (exit 125: memory cap)' 60 2000
    $g5 = Get-SuiteStop 124 'run-bounded: killed C:\a\Test-X.ps1 (exit 125: memory cap 3000 MB)' 60 2000
    Check 'stopped: both limiters'' kill lines read the same way; no number falls back to the limit given; another code''s line is no stop' ($g1.summary -eq 'timed out after 1800 s' -and $g2.summary -eq 'stopped at the memory cap (4000 MB)' -and $g3.summary -eq 'timed out after 600 s' -and $g4.summary -eq 'stopped at the memory cap (2000 MB)' -and $null -eq $g5 -and $null -eq (Get-SuiteStop 1 'run-bounded: killed x (exit 124: timeout after 3 s)' 60 2000))
    # repair tells the Crew plainly: stopped suites were slow or too large (the fake Crew keeps the prompt it was given and gives up)
    $fakeP = Join-Path $dir 'fake-agent-p.ps1'; Set-Content $fakeP "param([string]`$WorkDir, [string]`$Prompt, [Parameter(ValueFromRemainingArguments)]`$rest)`nSet-Content -LiteralPath (Join-Path `$WorkDir ('..\..\prompt-' + (Split-Path `$WorkDir -Leaf) + '.txt')) -Value `$Prompt; exit 1"
    foreach ($jn in 'J6', 'J7') { New-Item -ItemType Directory -Force -Path (Join-Path $kr "worktrees\$jn\.kitchen") | Out-Null }
    Copy-Item -LiteralPath (Join-Path $sd '.kitchen\TESTS.txt') (Join-Path $kr 'worktrees\J6\.kitchen\TESTS.txt')
    Set-Content (Join-Path $kr 'worktrees\J7\.kitchen\TESTS.txt') "FAIL  Test-Leak  Leak tests: 0 passed, 2 failed (1s)`n      FAIL: the second reason`nFAILED: Test-Leak"
    $sv6 = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB; a = $env:KITCHEN_AGENT_STEP }
    try {
        $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_AGENT_STEP = $fakeP
        foreach ($jn in 'J6', 'J7') { $env:KITCHEN_JOB = $jn; $null = & pwsh -NoProfile -File $rp -Rounds 1 2>&1 }
    } finally { $env:BRAIN_KITCHEN = $sv6.k; $env:KITCHEN_JOB = $sv6.j; $env:KITCHEN_AGENT_STEP = $sv6.a }
    $p6 = "$(Get-Content (Join-Path $kr 'prompt-J6.txt') -Raw -ErrorAction SilentlyContinue)"; $p7 = "$(Get-Content (Join-Path $kr 'prompt-J7.txt') -Raw -ErrorAction SilentlyContinue)"
    Check 'stopped: repair tells the Crew which suites were stopped, and that they were slow or too large, not a failed assertion' ($p6 -match 'Test-Big \(stopped at the memory cap \(\d+ MB\)\)' -and $p6 -match 'Test-Slow \(timed out after 3 s\)' -and $p6 -match 'not because an assertion failed' -and $p6 -notmatch 'Test-Own124 \(')
    Check 'stopped: a repair with no stopped suite gets the prompt as before' ($p7 -match 'When done, list each failure and what you changed for it\.\s*$' -and $p7 -notmatch 'not because an assertion failed')

    # --- a suite's own verdict words in its summary line (TD-EH-02 left the summary unbent) ---
    # The per-suite line shows the suite's last line with passed/failed/RESULT in it. Test-Liar's is "FAILED: Test-Fake": printed whole,
    # verify (first "FAILED:" anywhere in the step log) read "Test-Fake (1s)" as the red list. Test-Boaster fails while its summary says
    # "RESULT: ALL PASS": printed whole, a -Soft run (exit 0) satisfied the step's mustMatch 'ALL PASS'. Both are judged by the real readers,
    # taken from their source: verify.ps1's Get-FailedSuites and kitchen.ps1's Taste-Step (the taster).
    $vd = Join-Path $dir 'verdictwords'; New-Item -ItemType Directory -Force -Path (Join-Path $vd 'tests'), (Join-Path $vd '.kitchen') | Out-Null
    Set-Content (Join-Path $vd 'tests\Test-Liar.ps1') "'FAIL: the real reason'; 'FAILED: Test-Fake'; exit 1"
    Set-Content (Join-Path $vd 'tests\Test-Boaster.ps1') "'FAIL: it did not pass'; 'RESULT: ALL PASS'; exit 1"
    $vk = Join-Path $dir 'verdictkroot'; New-Item -ItemType Directory -Force -Path $vk | Out-Null
    $svv = $env:BRAIN_KITCHEN; $env:BRAIN_KITCHEN = $vk
    try {
        $ov = & $st -Dir $vd -SuiteTimeoutSec 60 *>&1 | Out-String; $cv = $LASTEXITCODE
        $ovs = & $st -Dir $vd -SuiteTimeoutSec 60 -Soft *>&1 | Out-String; $cvs = $LASTEXITCODE
    } finally { $env:BRAIN_KITCHEN = $svv }
    $vp = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\verify.ps1')).Path
    $gfAst = [Management.Automation.Language.Parser]::ParseFile($vp, [ref]$null, [ref]$null).Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-FailedSuites' }, $true)
    . ([scriptblock]::Create($gfAst.Extent.Text))
    $kp = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1')).Path
    $tsAst = [Management.Automation.Language.Parser]::ParseFile($kp, [ref]$null, [ref]$null).Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Taste-Step' }, $true)
    . ([scriptblock]::Create($tsAst.Extent.Text))
    Check 'verdict words: a suite''s "FAILED: Test-Fake" summary does not change the red list verify parses' ($cv -eq 1 -and ((Get-FailedSuites $ov) -join ',') -eq 'Test-Boaster,Test-Liar' -and $ov -notmatch 'FAILED: Test-Fake' -and $ov -match '(?m)^tests: FAILED: Test-Boaster, Test-Liar\s*$')
    $vlog = Join-Path $dir 'verdict-soft.log'; Set-Content -LiteralPath $vlog -Value $ovs -Encoding utf8
    $taste = Taste-Step ([pscustomobject]@{ mustMatch = 'ALL PASS'; mustNotMatch = $null }) $vlog
    Check 'verdict words: a failing suite''s "ALL PASS" summary does not satisfy mustMatch ALL PASS (a -Soft run exits 0)' ($cvs -eq 0 -and $ovs -match '(?m)^tests: FAILED: Test-Boaster, Test-Liar\s*$' -and $ovs -notmatch 'ALL PASS' -and $taste -eq "expected 'ALL PASS' in the output; not found")
    Check 'verdict words: the summary lines are bent in the step log, and still name the suite and its summary' ($ov -match '(?m)^tests: FAIL\s+Test-Liar\s+FAILED; Test-Fake \([\d.]+s\)' -and $ov -match '(?m)^tests: FAIL\s+Test-Boaster\s+RESULT: ALL_PASS \([\d.]+s\)')
    $vRecs = @(Get-ChildItem (Join-Path $vk 'results') -Filter 'nojob.tests-why-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
    $vRec = if ($vRecs.Count -eq 2) { Get-Content $vRecs[0].FullName -Raw | ConvertFrom-Json } else { $null }
    $vtx = Get-Content (Join-Path $vd '.kitchen\TESTS.txt') -Raw
    Check 'verdict words: the why record and TESTS.txt keep the summaries whole (only the printed copy is bent)' ($vRec -and @($vRec.suites | Where-Object { $_.suite -eq 'Test-Liar' })[0].summary -eq 'FAILED: Test-Fake' -and @($vRec.suites | Where-Object { $_.suite -eq 'Test-Boaster' })[0].summary -eq 'RESULT: ALL PASS' -and $vtx -match '(?m)^FAIL\s+Test-Liar\s+FAILED: Test-Fake' -and $vtx -match '(?m)^FAILED: Test-Boaster, Test-Liar\s*$')

    # --- the pool: several suites at once, by measured memory (kitchen/suite-times-lib.ps1) ---
    . (Join-Path $PSScriptRoot '..\kitchen\suite-times-lib.ps1')
    $pk = Join-Path $dir 'poolkroot'; New-Item -ItemType Directory -Force -Path $pk | Out-Null
    $times = Join-Path $pk 'suite-times.jsonl'
    function Pool([string]$Name, [int]$Sleep, [int]$Count, [string[]]$Extra) {
        $pd = Join-Path $dir $Name; New-Item -ItemType Directory -Force -Path (Join-Path $pd 'tests'), (Join-Path $pd '.kitchen') | Out-Null
        1..$Count | ForEach-Object { Set-Content (Join-Path $pd "tests\Test-P$_.ps1") "Start-Sleep $Sleep; 'P$_ tests: 1 passed, 0 failed'; exit 0" }
        $pd
    }
    # the pool runs as if on an 8-core PC (4 machine-wide suite slots), whatever this machine has: a 2-core CI runner has 1 slot, and
    # every pool below would run one at a time there. $More can set -Cores itself (the 2-core check).
    $poolCores = 8; $poolSlots = Get-SuiteParallelCap $poolCores
    function Run-Pool([string]$PoolDir, [hashtable]$More) {
        $svp = $env:BRAIN_KITCHEN; $env:BRAIN_KITCHEN = $pk; $pa_ = @{ Cores = $poolCores }; foreach ($key in $More.Keys) { $pa_[$key] = $More[$key] }
        try { $o = & $st -Dir $PoolDir -SuiteTimeoutSec 60 @pa_ *>&1 | Out-String } finally { $env:BRAIN_KITCHEN = $svp }
        $o
    }
    function Recs([string]$PoolDir) { @(Get-Content -LiteralPath $times -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.repo -eq (Split-Path $PoolDir -Leaf) }) }
    function Seed([string]$PoolDir, [int]$PeakMB, [int]$Count) { 1..$Count | ForEach-Object { Add-Content -LiteralPath $times -Value ([ordered]@{ repo = (Split-Path $PoolDir -Leaf); suite = "Test-P$_"; sec = 1; peakMB = $PeakMB; ok = $true } | ConvertTo-Json -Compress) } }
    # no history for a repo: one at a time, and the run says why
    $p0 = Pool 'pool0' 0 2
    $o = Run-Pool $p0 @{}
    Check 'pool: no history yet -> one at a time, and it says so' ($o -match 'up to 1 at once \(no suite history yet' -and $o -match 'ALL PASS')
    Check 'SuiteTimes_OneLinePerSuite_PeakMBAboveZero' ((Recs $p0).Count -eq 2 -and @((Recs $p0) | Where-Object { $_.peakMB -gt 0 -and $_.suite -match '^Test-P[12]$' -and $_.ok -eq $true -and $_.procs -ge 1 -and $null -ne $_.cpuSec }).Count -eq 2)
    # three 2 s sleepers at N=3 take about one suite's time, not three. Under 4 s on an idle PC; on a PC so busy that one sleeper alone
    # took over 3 s, under 1.5 x the slowest one still proves they ran together (one after another is 3 x)
    $p3 = Pool 'pool3' 2 3
    $o = Run-Pool $p3 @{ Parallel = 3; FreeMB = 100000 }
    $o8 = $o
    $poolSec = if ($o -match 'pool: 3 suites in ([\d.]+)s, at most 3 at once') { [double]$Matches[1] } else { 999 }
    $slowest = (@([regex]::Matches($o, 'PASS\s+Test-P\d\s+.*\(([\d.]+)s\)') | ForEach-Object { [double]$_.Groups[1].Value }) | Measure-Object -Maximum).Maximum
    Check "ThreeSleepers2s_AtN3_FinishUnder4s (pool $poolSec s, slowest suite $slowest s)" ($o -match 'ALL PASS' -and ($poolSec -lt 4 -or ($slowest -gt 3 -and $poolSec -lt 1.5 * $slowest)))
    # the machine-wide slots follow the core count, -Parallel never raises them: 2 cores (a 2-core CI runner) is 1 slot, one at a time
    $p2c = Pool 'pool2cores' 0 3
    $o = Run-Pool $p2c @{ Parallel = 3; FreeMB = 100000; Cores = 2 }
    Check "SuiteSlots_FollowCores: $poolCores cores -> $poolSlots slots and 3 at once; 2 cores -> 1 slot, one at a time even at -Parallel 3" ($o8 -match "up to 3 at once \(set by -Parallel; machine-wide suite slots: $poolSlots\)" -and $o8 -match 'at most 3 at once' -and $o -match 'up to 3 at once \(set by -Parallel; machine-wide suite slots: 1\)' -and $o -match 'pool: 3 suites in [\d.]+s, at most 1 at once' -and $o -match 'ALL PASS')
    # the budget: recorded peaks of the running suites + the next one's + the 1,024 MB reserve must stay under free RAM. "2000 free" is
    # 2,000 MB free beyond the reserve (free RAM 3,024 MB): with the reserve counted inside 2,000 MB not even one 900 MB suite would fit
    $pb = Pool 'pool900' 1 2; Seed $pb 900 2
    $null = Run-Pool $pb @{ FreeMB = 3024 }
    Check 'Budget_900plus900_In2000Free_RunsTwo' ((@((Recs $pb) | Where-Object { $null -ne $_.parallel }) | Measure-Object parallel -Maximum).Maximum -eq 2)
    $pc = Pool 'pool1500' 1 2; Seed $pc 1500 2
    $null = Run-Pool $pc @{ FreeMB = 3024 }
    Check 'Budget_1500plus1500_RunsOne' ((@((Recs $pc) | Where-Object { $null -ne $_.parallel }) | Measure-Object parallel -Maximum).Maximum -eq 1 -and @((Recs $pc) | Where-Object { $null -ne $_.parallel }).Count -eq 2)
    # "# runAlone" in a suite's header: it never overlaps another suite (start = end - sec from each suite-times line), the rest still overlap
    $pa = Pool 'poolalone' 2 3
    Set-Content (Join-Path $pa 'tests\Test-P2.ps1') "# a suite that starts a server`n# runAlone: flakes next to others`nStart-Sleep 2; 'P2 tests: 1 passed, 0 failed'; exit 0"
    $o = Run-Pool $pa @{ Parallel = 3; FreeMB = 100000 }
    $span = @{}; foreach ($x in (Recs $pa)) { $e = ([datetime]$x.at).ToUniversalTime(); $span[$x.suite] = @($e.AddSeconds(-[double]$x.sec), $e) }
    function Overlap($a, $b) { $a -and $b -and $a[0] -lt $b[1] -and $b[0] -lt $a[1] }
    Check 'RunAlone_NeverOverlapsAnotherSuite' ($o -match 'ALL PASS' -and $span.Count -eq 3 -and -not (Overlap $span['Test-P2'] $span['Test-P1']) -and -not (Overlap $span['Test-P2'] $span['Test-P3']) -and (Overlap $span['Test-P1'] $span['Test-P3']))
    # machine-wide slots: while another process (another order's station) holds every suite slot of this kitchen, the pool waits for one.
    # Every step waits on its condition, never on a clock: the holder keeps the slots until the station has said it is waiting (it used
    # to let go after a fixed 4 s, and on a loaded PC the station took longer than that just to start, found the slots free and never
    # waited: one red run in a full 82-suite run at 315 s). Each wait has a deadline far above a loaded PC's times, and a miss prints why.
    $slotKey = 'Local\brain-kitchen-suites-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($pk).ToLowerInvariant()))).Substring(0, 12)
    $ready = Join-Path $dir 'slots-held.txt'; $release = Join-Path $dir 'slots-release.txt'; $stOut = Join-Path $dir 'slots-station.out.txt'
    $hold = "`$n = $poolSlots; `$m = @(0..(`$n - 1) | ForEach-Object { `$x = [Threading.Mutex]::new(`$false, '$slotKey-slot' + `$_); `$null = `$x.WaitOne(); `$x }); Set-Content -LiteralPath '$ready' 1; " +
        "`$d = [Diagnostics.Stopwatch]::StartNew(); while (-not (Test-Path -LiteralPath '$release') -and `$d.Elapsed.TotalSeconds -lt 300) { Start-Sleep -Milliseconds 100 }; `$m | ForEach-Object { `$_.ReleaseMutex() }"
    function Read-Shared([string]$Path) { try { $fs = [IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite'); try { [IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() } } catch { '' } }
    function Wait-Until([scriptblock]$Cond, [int]$Sec) { $d = [Diagnostics.Stopwatch]::StartNew(); while (-not (& $Cond) -and $d.Elapsed.TotalSeconds -lt $Sec) { Start-Sleep -Milliseconds 100 }; [bool](& $Cond) }
    $ps = Pool 'poolslots' 0 1; $sp_ = $null; $sw = [Diagnostics.Stopwatch]::StartNew()
    $hp = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', $hold -PassThru -WindowStyle Hidden
    try {
        $isReady = Wait-Until { Test-Path -LiteralPath $ready } 120; $readySec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        # the station runs as its own process (as another order's would), so this test can watch its output while it waits
        $svp = $env:BRAIN_KITCHEN; $env:BRAIN_KITCHEN = $pk
        try { $sp_ = Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList '-NoProfile', '-File', "`"$st`"", '-Dir', "`"$ps`"", '-SuiteTimeoutSec', 60, '-Cores', $poolCores, '-FreeMB', 100000 -RedirectStandardOutput $stOut -RedirectStandardError "$stOut.err" -PassThru -WindowStyle Hidden }
        finally { $env:BRAIN_KITCHEN = $svp }
        $saidWait = Wait-Until { (Read-Shared $stOut) -match 'waiting for a free suite slot' -or $sp_.HasExited } 120; $waitSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        # what the station had printed while every slot was still held elsewhere: the wait line, and no suite run yet
        $before = Read-Shared $stOut; $aliveAtRelease = -not $sp_.HasExited
        Set-Content -LiteralPath $release 1
        $ended = $sp_.WaitForExit(120000); $holderEnded = $hp.WaitForExit(30000)
        $o = (Read-Shared $stOut) + (Read-Shared "$stOut.err")
        $ok = $isReady -and $before -match 'waiting for a free suite slot' -and $before -notmatch 'PASS\s+Test-P1' -and $aliveAtRelease -and $ended -and $o -match 'PASS\s+Test-P1' -and $o -match 'ALL PASS'
        Check 'SuiteSlots_AllHeldElsewhere_WaitsThenRuns' $ok
        if (-not $ok) {
            Write-Host "  slots held: $isReady at $readySec s; station said wait: $saidWait by $waitSec s; still running at release: $aliveAtRelease; station ended: $ended; holder ended: $holderEnded; total $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s"
            Write-Host "  station output before release: $((($before -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 6) -join ' | ')"
            Write-Host "  station output at the end: $((($o -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 8) -join ' | ')"
        }
    } finally {
        Set-Content -LiteralPath $release 1 -ErrorAction SilentlyContinue
        foreach ($p_ in $sp_, $hp) { if ($p_ -and -not $p_.HasExited) { try { $p_.Kill($true) } catch { } } }
    }
    Check 'budget: the reserve is always kept (900 next to nothing, 1,900 MB free -> no)' (-not (Test-SuiteBudget @() 900 1900) -and (Test-SuiteBudget @() 900 1925))
    Check 'budget: a suite with no record counts as 1,200 MB' ((Get-SuitePeakMB @()) -eq 1200 -and (Get-SuitePeakMB @([pscustomobject]@{ peakMB = 300 }, [pscustomobject]@{ peakMB = 700 })) -eq 700)
    Check 'pool cap: min(4, cores/2), at least 1' ((Get-SuiteParallelCap 16) -eq 4 -and (Get-SuiteParallelCap 4) -eq 2 -and (Get-SuiteParallelCap 1) -eq 1)
    # per-suite limit: clamp(3 x p90 of the last 20 passing runs, 60 s, the repo's limit)
    $h10 = @(1..20 | ForEach-Object { [pscustomobject]@{ sec = 10; ok = $true } })
    Check 'SuiteLimit_From10sHistory_Is60s' ((Get-SuiteLimitSec $h10 600) -eq 60)
    Check 'suite limit: no passing run yet -> the repo limit; 100 s runs -> 300 s; never above the repo limit' ((Get-SuiteLimitSec @([pscustomobject]@{ sec = 5; ok = $false }) 600) -eq 600 -and (Get-SuiteLimitSec @([pscustomobject]@{ sec = 100; ok = $true }) 600) -eq 300 -and (Get-SuiteLimitSec @([pscustomobject]@{ sec = 400; ok = $true }) 600) -eq 600)
    $fa = [pscustomobject]@{ BaseName = 'Test-Fast' }; $sl = [pscustomobject]@{ BaseName = 'Test-Slow' }; $nw = [pscustomobject]@{ BaseName = 'Test-New' }
    $ord = @(Get-SuiteRunOrder @($fa, $sl, $nw) @{ 'Test-Fast' = @([pscustomobject]@{ sec = 5 }); 'Test-Slow' = @([pscustomobject]@{ sec = 300 }) } | ForEach-Object { $_.BaseName })
    Check 'order: longest first, a suite with no record before all' (($ord -join ',') -eq 'Test-New,Test-Slow,Test-Fast')
    # history is per repo: another repo's lines never count, and a torn line is skipped
    Add-Content -LiteralPath $times -Value '{"repo":"other","suite":"Test-P1","sec":999,"peakMB":5,"ok":true}'; Add-Content -LiteralPath $times -Value '{"repo":"pool900","sui'
    $hh = Read-SuiteTimes $times 'pool900'
    Check 'history: per repo, torn lines skipped' ($hh['Test-P1'].Count -ge 1 -and -not @($hh['Test-P1'] | Where-Object { $_.sec -eq 999 }).Count)
    # say why: every pool run above was green, so that kitchen got no results folder and no events.jsonl from the station
    Check 'say why: a green run writes nothing new (no results folder, no events.jsonl)' (-not (Test-Path (Join-Path $pk 'results')) -and -not (Test-Path (Join-Path $pk 'events.jsonl')))

    # run-bounded's own cost on a no-op: the C# type is loaded from its prebuilt DLL and the child is waited on, not polled (it was 1,702 ms
    # median, the compile alone ~0.5 s). A run is two pwsh starts (run-bounded and the suite), measured 357-435 ms each on this PC, so
    # 800 ms holds only on a fast idle PC: the line is 800 ms or two of this PC's measured bare pwsh starts + 300 ms, whichever is higher.
    # The old wrapper (two starts + ~900 ms) fails it either way.
    $rbs = Join-Path $PSScriptRoot '..\scripts\run-bounded.ps1'; $noop = Join-Path $dir 'noop.ps1'; Set-Content $noop 'exit 0'
    $null = & pwsh -NoProfile -File $rbs -Script $noop   # warm: builds the DLL once if this PC has none yet
    $rbMs = @(); $bareMs = @()
    for ($i = 0; $i -lt 7; $i++) {
        $bareMs += (Measure-Command { & pwsh -NoProfile -File $noop }).TotalMilliseconds
        $rbMs += (Measure-Command { & pwsh -NoProfile -File $rbs -Script $noop }).TotalMilliseconds
    }
    $rbMed = ($rbMs | Sort-Object)[3]; $bareMed = ($bareMs | Sort-Object)[3]
    Check "RunBoundedNoop_Under800msMedian7 (median $([int]$rbMed) ms; bare pwsh $([int]$bareMed) ms)" ($rbMed -lt [math]::Max(800, 2 * $bareMed + 300))
} finally {
    $env:BRAIN_KITCHEN = $svTop
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "TestsStation tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
