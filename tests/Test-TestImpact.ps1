# Tests for diff-scoped test selection (kitchen/stations/tests.ps1 -Impacted, kitchen/stations/repair.ps1): a change runs only the suites it maps to,
# anything shared, unmapped or unknown runs all of them, and a narrowed run is never "ALL PASS". Self-cleaning.
$ErrorActionPreference = 'Stop'
$st = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\tests.ps1')).Path
$rp = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\repair.ps1')).Path
$dir = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-impact-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
# a private kitchen for every station call: with BRAIN_KITCHEN blank the station used Jordan's live one, wrote 936 lines of made-up
# suite times (repos r1-r5) into it and shared its suite slots; that history ran these fake suites in parallel and the move below failed
$svTop = $env:BRAIN_KITCHEN; $env:BRAIN_KITCHEN = Join-Path $dir 'kitchen-top'
function New-Repo($name, [string[]]$names, [string[]]$failing = @()) {
    $d = Join-Path $dir $name; New-Item -ItemType Directory -Force -Path (Join-Path $d 'tests'), (Join-Path $d '.kitchen') | Out-Null
    foreach ($n in $names) {
        $body = if ($n -in $failing) { "Write-Output 'FAIL: broken'; Write-Output '$n : 0 passed, 1 failed'; exit 1" } else { "Write-Output '$n : 1 passed, 0 failed'; exit 0" }
        Set-Content (Join-Path $d "tests\$n.ps1") $body
    }
    $d
}
function Ran($o, $n) { $o -match "(?m)^tests: PASS\s+$n\s" }
function Skipped($o, $n) { $o -match "-\s+$n\s+not run \(not impacted\)" }
$all = 'Test-PassApp', 'Test-BrainMonitor', 'Test-KitchenSupervisor', 'Test-Foo', 'Test-Other'
try {
    $d1 = New-Repo 'r1' $all
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'pass-app/server.mjs' *>&1 | Out-String
    Check 'pass-app change: only Test-PassApp runs' ((Ran $o 'Test-PassApp') -and -not (Ran $o 'Test-Foo') -and -not (Ran $o 'Test-BrainMonitor') -and -not (Ran $o 'Test-KitchenSupervisor'))
    Check 'pass-app change: the others are listed as not run (not impacted)' ((Skipped $o 'Test-Foo') -and (Skipped $o 'Test-Other') -and (Skipped $o 'Test-KitchenSupervisor') -and $o -match 'impacted run: 1 of 5 suites')
    Check 'pass-app change: ends PARTIAL PASS, never ALL PASS' ($o -match 'tests: PARTIAL PASS: 1 of 5 suites' -and $o -notmatch 'ALL PASS' -and (Get-Content (Join-Path $d1 '.kitchen\TESTS.txt'))[-1] -eq 'PARTIAL PASS: 1 of 5 suites')

    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'kitchen/foo.ps1' *>&1 | Out-String
    Check 'kitchen script change: Test-KitchenSupervisor and the same-name suite run, not Test-PassApp' ((Ran $o 'Test-KitchenSupervisor') -and (Ran $o 'Test-Foo') -and -not (Ran $o 'Test-PassApp') -and -not (Ran $o 'Test-Other'))
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'kitchen\stations\foo.ps1' *>&1 | Out-String
    Check 'kitchen station change with backslashes maps the same way' ((Ran $o 'Test-KitchenSupervisor') -and (Ran $o 'Test-Foo') -and -not (Ran $o 'Test-PassApp'))
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'scripts/memory-check.ps1' *>&1 | Out-String
    Check 'memory-check change: only Test-BrainMonitor runs' ((Ran $o 'Test-BrainMonitor') -and -not (Ran $o 'Test-PassApp') -and -not (Ran $o 'Test-KitchenSupervisor') -and -not (Ran $o 'Test-Foo'))
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'tests/Test-Other.ps1' *>&1 | Out-String
    Check 'a changed test file runs itself and nothing else' ((Ran $o 'Test-Other') -and -not (Ran $o 'Test-PassApp') -and -not (Ran $o 'Test-Foo'))

    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'scripts/run-bounded.ps1' *>&1 | Out-String
    Check 'shared core file: all suites run and the reason is printed' (@($all | Where-Object { Ran $o $_ }).Count -eq 5 -and $o -match 'impacted run: all 5 suites \(shared file changed: scripts/run-bounded\.ps1\)' -and $o -match 'tests: ALL PASS')
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'tests/helper.ps1' *>&1 | Out-String
    Check 'a helper under tests/ counts as shared: all suites run' (@($all | Where-Object { Ran $o $_ }).Count -eq 5 -and $o -match 'shared file changed')
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'docs/x.md' *>&1 | Out-String
    Check 'unmapped file (docs): all suites run and the reason is printed' (@($all | Where-Object { Ran $o $_ }).Count -eq 5 -and $o -match 'no suite is mapped to docs/x\.md')
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'pass-app/a.js', 'docs/x.md' *>&1 | Out-String
    Check 'one unmapped file among mapped ones still runs everything' (@($all | Where-Object { Ran $o $_ }).Count -eq 5)
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'unknown' *>&1 | Out-String
    Check 'unknown changed list: all suites run and the reason is printed' (@($all | Where-Object { Ran $o $_ }).Count -eq 5 -and $o -match 'the changed files are unknown')
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted *>&1 | Out-String
    Check 'no BASE and no git diff: all suites run' (@($all | Where-Object { Ran $o $_ }).Count -eq 5 -and $o -match 'the changed files are unknown')
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -ChangedFiles 'pass-app/server.mjs' *>&1 | Out-String
    Check 'without -Impacted every suite runs (verify and CI are unchanged)' (@($all | Where-Object { Ran $o $_ }).Count -eq 5 -and $o -match 'tests: ALL PASS' -and $o -notmatch 'impacted run')

    # a suite that failed last time is re-checked even when the map does not name it
    Set-Content (Join-Path $d1 '.kitchen\TESTS.txt') "FAIL  Test-Other   crashed`nFAILED: Test-Other"
    $o = & $st -Dir $d1 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'pass-app/server.mjs' *>&1 | Out-String
    Check 'a suite that failed in the previous TESTS.txt is included' ((Ran $o 'Test-PassApp') -and (Ran $o 'Test-Other') -and -not (Ran $o 'Test-Foo'))

    # a suite that names the changed file by its full path is included
    $d2 = New-Repo 'r2' 'Test-PassApp', 'Test-Foo', 'Test-Mentions'
    Add-Content (Join-Path $d2 'tests\Test-Mentions.ps1') '# covers kitchen/zzz.ps1'
    $o = & $st -Dir $d2 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'kitchen/zzz.ps1' *>&1 | Out-String
    Check 'a suite naming the changed file by its path is included' ((Ran $o 'Test-Mentions') -and -not (Ran $o 'Test-PassApp') -and -not (Ran $o 'Test-Foo'))

    # a file outside the fixed table: its owners run (a suite naming its path, or its Test-<Name> suite); with none, the owners of the
    # other files in its folder (shared core files left out); only then every suite
    $d6 = New-Repo 'r6' 'Test-PassApp', 'Test-Foo', 'Test-Names', 'Test-MakeThing', 'Test-Sib', 'Test-Core'
    Add-Content (Join-Path $d6 'tests\Test-Names.ps1') '# runs (Join-Path $PSScriptRoot ''..\scripts\owned.ps1'')'
    Add-Content (Join-Path $d6 'tests\Test-Sib.ps1') '# covers scripts/sibling.ps1'
    Add-Content (Join-Path $d6 'tests\Test-Core.ps1') '# runs scripts\run-bounded.ps1'
    New-Item -ItemType Directory -Force -Path (Join-Path $d6 'scripts'), (Join-Path $d6 'other') | Out-Null
    foreach ($f in 'scripts\sibling.ps1', 'scripts\lonely.ps1', 'scripts\run-bounded.ps1', 'other\x.ps1', 'other\none.ps1') { Set-Content (Join-Path $d6 $f) '# a file' }
    $six = 'Test-PassApp', 'Test-Foo', 'Test-Names', 'Test-MakeThing', 'Test-Sib', 'Test-Core'
    $o = & $st -Dir $d6 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'scripts/owned.ps1' *>&1 | Out-String
    Check 'a suite that names a file owns it: a change to it runs that suite, not all' ((Ran $o 'Test-Names') -and @($six | Where-Object { Ran $o $_ }).Count -eq 1 -and $o -match 'impacted run: 1 of 6 suites' -and $o -match 'tests: PARTIAL PASS')
    $o = & $st -Dir $d6 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'scripts/make-thing.ps1' *>&1 | Out-String
    Check 'a suite that names a file owns it: its Test-<Name> suite runs, not all' ((Ran $o 'Test-MakeThing') -and @($six | Where-Object { Ran $o $_ }).Count -eq 1)
    $o = & $st -Dir $d6 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'scripts/owned.ps1', 'pass-app/zzz.mjs' *>&1 | Out-String
    Check 'a suite that names a file owns it: mixed with a table file, both owners run and nothing else' ((Ran $o 'Test-Names') -and (Ran $o 'Test-PassApp') -and @($six | Where-Object { Ran $o $_ }).Count -eq 2)
    $o = & $st -Dir $d6 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'scripts\lonely.ps1' *>&1 | Out-String
    Check 'when nothing maps, the owning suites of the parent folder run' ((Ran $o 'Test-Sib') -and @($six | Where-Object { Ran $o $_ }).Count -eq 1 -and $o -match 'no suite names scripts/lonely\.ps1; running the suites that own other files in scripts/ \(Test-Sib\)')
    Check 'when nothing maps, a shared core file in the folder does not pull in its owners' (-not (Ran $o 'Test-Core') -and (Skipped $o 'Test-Core'))
    $o = & $st -Dir $d6 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'other/none.ps1' *>&1 | Out-String
    Check 'and only then all: no owner and no folder owner runs every suite with the reason' (@($six | Where-Object { Ran $o $_ }).Count -eq 6 -and $o -match 'impacted run: all 6 suites \(no suite is mapped to other/none\.ps1 or to another file in other/\)')
    $o = & $st -Dir $d6 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'README.md' *>&1 | Out-String
    Check 'and only then all: an unowned file at the top of the repo runs every suite' (@($six | Where-Object { Ran $o $_ }).Count -eq 6 -and $o -match 'no suite is mapped to README\.md\)')

    # the case that ran every suite: a change to the rebase-orders script (and the Board's towers module), mapped against this repo's
    # real suite texts. Each stub prints a pass and exits; the real text follows as comments, which is all the map reads. The two paths
    # are built from parts so this suite does not name them itself (a suite that names a file owns it, and this one would run for them).
    $ro = 'scripts/' + 'rebase-orders.ps1'; $tw = 'pass-app/' + 'towers.mjs'
    $d7 = New-Repo 'r7' @()
    $real = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File)
    foreach ($rf in $real) {
        $body = @("Write-Output '$($rf.BaseName) : 1 passed, 0 failed'; exit 0") + @(Get-Content -LiteralPath $rf.FullName | ForEach-Object { "# $_" })
        Set-Content -LiteralPath (Join-Path $d7 "tests\$($rf.Name)") -Value $body
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $o = & $st -Dir $d7 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles $ro *>&1 | Out-String
    $sw.Stop(); $ranN = @([regex]::Matches($o, '(?m)^tests: PASS\s+(\S+)')).Count
    Check "a change to $ro runs a handful of suites in minutes" ((Ran $o 'Test-RebaseOrders') -and $ranN -ge 1 -and $ranN -le 5 -and $real.Count -gt 20 -and $o -match "impacted run: $ranN of $($real.Count) suites" -and $sw.Elapsed.TotalSeconds -lt 300)
    $o = & $st -Dir $d7 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles $ro, $tw *>&1 | Out-String
    $ranN = @([regex]::Matches($o, '(?m)^tests: PASS\s+(\S+)')).Count
    Check "a change to $ro runs a handful of suites in minutes: with $tw too, not all" ((Ran $o 'Test-RebaseOrders') -and (Ran $o 'Test-PassApp') -and $ranN -le 6 -and $o -notmatch 'impacted run: all')

    # a mapped suite that is not in the repo is named, and the run does not quietly shrink to nothing
    $d3 = New-Repo 'r3' 'Test-Foo', 'Test-Other'
    $o = & $st -Dir $d3 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'pass-app/server.mjs' *>&1 | Out-String
    Check 'a mapped suite missing from the repo is reported by name' ($o -match 'mapped suite not found: Test-PassApp')
    Check 'nothing mapped is present: all suites run, reason printed' ((Ran $o 'Test-Foo') -and (Ran $o 'Test-Other') -and $o -match 'the mapping found no suite to run')

    # failure state: an impacted suite that fails is FAILED, exit 1 hard and 0 soft
    $d4 = New-Repo 'r4' $all -failing 'Test-PassApp'
    $o = & $st -Dir $d4 -SuiteTimeoutSec 60 -Impacted -ChangedFiles 'pass-app/server.mjs' *>&1 | Out-String; $c = $LASTEXITCODE
    Check 'impacted suite fails: FAILED: <name> and exit 1' ($o -match 'tests: FAILED: Test-PassApp' -and $c -eq 1 -and $o -notmatch 'PARTIAL PASS')
    $o = & $st -Dir $d4 -SuiteTimeoutSec 60 -Soft -Impacted -ChangedFiles 'pass-app/server.mjs' *>&1 | Out-String; $c = $LASTEXITCODE
    Check 'impacted suite fails in soft mode: FAILED and exit 0' ($o -match 'tests: FAILED: Test-PassApp' -and $c -eq 0)

    # the diff comes from .kitchen/BASE in a real git repo
    $d5 = New-Repo 'r5' $all
    & git -C $d5 init -q 2>&1 | Out-Null; Set-Content (Join-Path $d5 '.gitignore') '.kitchen/'
    & git -C $d5 add -A 2>&1 | Out-Null; & git -C $d5 -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    Set-Content (Join-Path $d5 '.kitchen\BASE') ((& git -C $d5 rev-parse HEAD).Trim())
    New-Item -ItemType Directory -Force -Path (Join-Path $d5 'pass-app') | Out-Null; Set-Content (Join-Path $d5 'pass-app\x.txt') 'the change'
    & git -C $d5 add -A 2>&1 | Out-Null; & git -C $d5 -c user.name=t -c user.email=t@localhost commit -q -m change 2>&1 | Out-Null
    $o = & $st -Dir $d5 -SuiteTimeoutSec 120 -Soft -Impacted *>&1 | Out-String
    Check 'diff against .kitchen/BASE picks the right suite' ((Ran $o 'Test-PassApp') -and -not (Ran $o 'Test-Foo') -and $o -match 'tests: PARTIAL PASS')

    # a partial run records no passing result for the job; a full run does
    $kr = Join-Path $dir 'kroot'; New-Item -ItemType Directory -Force -Path (Join-Path $kr 'worktrees') | Out-Null
    $sv = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB; a = $env:KITCHEN_AGENT_STEP }
    try {
        $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_JOB = 'J5'
        # copied, not moved: right after the station ran in $d5 something holds a directory handle in it for a few seconds (10-23: the
        # move and even a rename in place failed "access denied" 4 of 4 times with no file lock found; which process is unknown)
        Copy-Item -LiteralPath $d5 -Destination (Join-Path $kr 'worktrees\J5') -Recurse -Force
        $null = & $st -SuiteTimeoutSec 120 -Soft -Impacted *>&1 | Out-String
        Check 'partial run: no results\<job>.tests.json is written' (-not (Test-Path -LiteralPath (Join-Path $kr 'results\J5.tests.json')))
        $null = & $st -SuiteTimeoutSec 120 -Soft *>&1 | Out-String
        Check 'full run: results\<job>.tests.json says ALL PASS' ((Get-Content (Join-Path $kr 'results\J5.tests.json') -Raw | ConvertFrom-Json).final -eq 'ALL PASS')
        Remove-Item -LiteralPath (Join-Path $kr 'results') -Recurse -Force

        # repair: impacted run first, then one full run, which alone says ALL PASS and records the result
        $fake = Join-Path $dir 'fake-agent.ps1'
        Set-Content $fake "param([string]`$WorkDir, [Parameter(ValueFromRemainingArguments)]`$rest)`nAdd-Content (Join-Path `$WorkDir 'pass-app\x.txt') 'fixed'; exit 0"
        $env:KITCHEN_AGENT_STEP = $fake
        $wt = Join-Path $kr 'worktrees\J5'
        Set-Content (Join-Path $wt '.kitchen\TESTS.txt') "FAILED: Test-Foo"
        Set-Content (Join-Path $wt '.kitchen\CRITIQUE.md') '# rework please'
        $o = & pwsh -NoProfile -File $rp 2>&1 | Out-String; $rc = $LASTEXITCODE
        Check 'repair: impacted run first, then one full run, ends ALL PASS' ($rc -eq 0 -and $o -match 'tests: PARTIAL PASS' -and $o -match 'running all suites once' -and $o -match 'reworked; tests pass' -and (Get-Content (Join-Path $wt '.kitchen\TESTS.txt'))[-1] -eq 'ALL PASS')
        $r5 = Get-Content (Join-Path $kr 'results\J5.tests.json') -Raw | ConvertFrom-Json
        Check 'repair: the result file is written by the full run for the tested commit' ($r5.final -eq 'ALL PASS' -and $r5.sha -eq (& git -C $wt rev-parse HEAD).Trim())

        # a full run that fails after a PARTIAL PASS fails the repair (the partial pass is not a pass)
        Set-Content (Join-Path $wt 'tests\Test-Other.ps1') "Write-Output 'FAIL: broken'; Write-Output 'Test-Other : 0 passed, 1 failed'; exit 1"
        & git -C $wt add -A 2>&1 | Out-Null; & git -C $wt -c user.name=t -c user.email=t@localhost commit -q -m 'break other' 2>&1 | Out-Null
        Set-Content (Join-Path $wt '.kitchen\BASE') ((& git -C $wt rev-parse HEAD).Trim())   # the break is now "before" the change, so only pass-app is impacted
        Set-Content (Join-Path $wt '.kitchen\CRITIQUE.md') '# rework again'
        $o = & pwsh -NoProfile -File $rp 2>&1 | Out-String; $rc = $LASTEXITCODE
        Check 'repair: PARTIAL PASS then a failing full run is still a failed repair' ($rc -eq 1 -and $o -match 'tests: PARTIAL PASS' -and $o -match 'tests: FAILED: Test-Other' -and $o -match 'still failing')
    } finally { $env:BRAIN_KITCHEN = $sv.k; $env:KITCHEN_JOB = $sv.j; $env:KITCHEN_AGENT_STEP = $sv.a }
} finally {
    $env:BRAIN_KITCHEN = $svTop
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "TestImpact tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
