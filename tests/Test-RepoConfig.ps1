# Tests for per-repo kitchen settings (kitchen/repo-config.ps1, kitchen.repo.json) and the stations that use them: the tests, mutate, map,
# lint, worktree, freshen and verify stations on a repository that is NOT brain-monitor (its default branch is master, its suites are nested,
# one has no tests\Test-*.ps1 at all). Self-cleaning: scratch repos and a scratch kitchen under TEMP only.
$ErrorActionPreference = 'Stop'
$k = Join-Path $PSScriptRoot '..\kitchen'
$st = (Resolve-Path (Join-Path $k 'stations')).Path
. (Join-Path $k 'repo-config.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('rc-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G([string]$r) { & git -C $r -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function Put([string]$path, [string]$text) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null; Set-Content -LiteralPath $path -Value $text -Encoding utf8 }
function Run([string]$station, [string[]]$more) { $o = & pwsh -NoProfile -File (Join-Path $st "$station.ps1") @more 2>&1 | Out-String; [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE } }
function Throws([scriptblock]$b) { try { & $b | Out-Null; '' } catch { $_.Exception.Message } }
$passSuite = 'Write-Output "Fixture tests: 1 passed, 0 failed"; exit 0'
$old = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB; r = $env:KITCHEN_RUN }
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $kr = Join-Path $root 'kitchen'; New-Item -ItemType Directory -Force -Path $kr | Out-Null
    $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_JOB = $null; $env:KITCHEN_RUN = $null   # never Jordan's live kitchen

    # ---- the file: defaults, validation -------------------------------------------------------------------------------------------
    $none = Join-Path $root 'none'; New-Item -ItemType Directory -Force -Path $none | Out-Null
    $d = Read-RepoConfig $none
    Check 'absent file: defaults (tests\Test-*.ps1, no timeout, nothing protected)' (-not $d.Present -and "$($d.Tests)" -eq 'tests/Test-*.ps1' -and $d.TestTimeoutSec -eq 0 -and $d.Github -eq '' -and $d.Protected.Count -eq 0 -and -not $d.TestsGiven)
    $cfgDir = Join-Path $root 'cfg'; New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    function Cfg([string]$json) { Set-Content -LiteralPath (Join-Path $cfgDir 'kitchen.repo.json') -Value $json -Encoding utf8; Read-RepoConfig $cfgDir }
    $c = Cfg '{"tests":["tests\\phase0\\Test-Phase0.ps1","tests/**/Test-*.ps1"],"testTimeoutSec":900,"github":"jordan/demo-project","protected":[".claude/**","scripts\\lock-guardrails.ps1"],"somethingNew":{"x":1}}'
    Check 'full file: every key read, backslashes become /' ($c.Present -and $c.TestsGiven -and ($c.Tests -join '|') -eq 'tests/phase0/Test-Phase0.ps1|tests/**/Test-*.ps1' -and $c.TestTimeoutSec -eq 900 -and $c.Github -eq 'jordan/demo-project' -and ($c.Protected -join '|') -eq '.claude/**|scripts/lock-guardrails.ps1')
    Check 'unknown keys are ignored' ((Cfg '{"nope":1,"tests":["a/Test-B.ps1"]}').Tests[0] -eq 'a/Test-B.ps1')
    Check 'keys are read without regard to case' ((Cfg '{"TestTimeoutSec":30}').TestTimeoutSec -eq 30)
    Check 'a file with only github keeps the default tests' (-not (Cfg '{"github":"a/b"}').TestsGiven -and (Cfg '{"github":"a/b"}').Tests[0] -eq 'tests/Test-*.ps1')
    $bad = [ordered]@{
        'not JSON'                  = '{ "tests": '
        'array root'                = '[1]'
        'tests is a string'         = '{"tests":"tests/Test-A.ps1"}'
        'tests empty (skips all)'   = '{"tests":[]}'
        'tests entry is a number'   = '{"tests":[5]}'
        'tests entry not .ps1'      = '{"tests":["tests/run.py"]}'
        'timeout is a string'       = '{"testTimeoutSec":"600"}'
        'timeout is a fraction'     = '{"testTimeoutSec":1.5}'
        'timeout is zero'           = '{"testTimeoutSec":0}'
        'timeout is huge'           = '{"testTimeoutSec":99999}'
        'timeout is a bool'         = '{"testTimeoutSec":true}'
        'github has no owner'       = '{"github":"demo"}'
        'github is a number'        = '{"github":7}'
        'protected is a string'     = '{"protected":".claude/**"}'
        'protected entry is a number' = '{"protected":[1]}'
        'commitBudget is a number'  = '{"commitBudget":10}'
        'commitBudget files zero'   = '{"commitBudget":{"files":0}}'
        'commitBudget lines huge'   = '{"commitBudget":{"lines":999999}}'
        'commitBudget lines string' = '{"commitBudget":{"lines":"600"}}'
        'commitBudget exclude is a string' = '{"commitBudget":{"exclude":"fixtures"}}'
        'commitBudget exclude entry ..'    = '{"commitBudget":{"exclude":["../x"]}}'
    }
    $c = Cfg '{"commitBudget":{"files":12,"lines":700}}'
    Check 'commitBudget: files and lines read' ($c.CommitFiles -eq 12 -and $c.CommitLines -eq 700)
    Check 'commitBudget: exclude read, backslashes become /, absent = none' (((Cfg '{"commitBudget":{"exclude":["fixtures","evals\\cases","fixtures"]}}').CommitExclude -join '|') -eq 'fixtures|evals/cases' -and (Cfg '{"commitBudget":{"files":6}}').CommitExclude.Count -eq 0)
    Check 'commitBudget: absent means the station default (0 here)' ((Cfg '{"github":"a/b"}').CommitFiles -eq 0 -and (Cfg '{"commitBudget":{"files":6}}').CommitLines -eq 0)
    foreach ($b in $bad.GetEnumerator()) {
        $m = Throws { Cfg $b.Value }
        Check "bad config fails closed with a clear message: $($b.Key)" ($m -match 'kitchen\.repo\.json' -and $m.Length -gt 40)
    }
    Check 'the message names the key and the file' ((Throws { Cfg '{"testTimeoutSec":"600"}' }) -match "'testTimeoutSec' must be a whole number" -and (Throws { Cfg '{"testTimeoutSec":"600"}' }) -match [regex]::Escape($cfgDir))
    # globs: relative and inside the repo
    foreach ($g in '../Test-A.ps1', '..\Test-A.ps1', 'tests/../../Test-A.ps1', 'tests/sub/../../../x/Test-A.ps1', 'tests/.. /Test-A.ps1', 'tests/.../Test-A.ps1', '/etc/Test-A.ps1', '\Test-A.ps1', 'C:\Windows\Test-A.ps1', 'C:Test-A.ps1', '\\server\share\Test-A.ps1', 'tests/Test-A.ps1:stream', '') {
        $j1 = ConvertTo-Json -Compress @{ tests = @($g) }; $j2 = ConvertTo-Json -Compress @{ protected = @($g) }
        Check "tests glob rejected: '$g'" ((Throws { Cfg $j1 }) -match 'kitchen\.repo\.json')
        Check "protected glob rejected: '$g'" ((Throws { Cfg $j2 }) -match 'kitchen\.repo\.json')
    }
    Check "'..' message says why" ((Throws { Cfg '{"tests":["../x/Test-A.ps1"]}' }) -match "'\.\.'" -and (Throws { Cfg '{"tests":["/x/Test-A.ps1"]}' }) -match 'absolute')
    Check "a name that merely contains dots is fine" ((Cfg '{"tests":["tests/a..b/Test-A.ps1","tests/.hidden/Test-B.ps1"]}').Tests.Count -eq 2)

    # glob matching
    $re = [regex](ConvertTo-RepoGlobRegex 'tests/**/Test-*.ps1')
    Check 'glob **/ matches no folder, one folder and many' ($re.IsMatch('tests/Test-A.ps1') -and $re.IsMatch('tests/x/Test-A.ps1') -and $re.IsMatch('tests/x/y/Test-A.ps1'))
    Check 'glob stays anchored and * does not cross /' (-not $re.IsMatch('mytests/Test-A.ps1') -and -not $re.IsMatch('tests/x/Other.ps1') -and -not ([regex](ConvertTo-RepoGlobRegex 'tests/*.ps1')).IsMatch('tests/x/A.ps1'))
    Check 'glob matches without regard to case' ($re.IsMatch('TESTS/X/TEST-A.PS1'))
    Check 'regex-special characters in a glob are literal' (([regex](ConvertTo-RepoGlobRegex 'a+b(1).ps1')).IsMatch('a+b(1).ps1') -and -not ([regex](ConvertTo-RepoGlobRegex 'a.ps1')).IsMatch('aXps1'))

    # ---- fixture repo A: default branch master, a nested suite, a slow suite, the config committed in main ---------------------------
    $a = Join-Path $root 'a'; New-Item -ItemType Directory -Force -Path $a | Out-Null
    & git -C $a init -q -b master 2>&1 | Out-Null
    Put "$a\tests\Test-Top.ps1" $passSuite
    Put "$a\tests\sub\Test-X.ps1" $passSuite
    Put "$a\README.md" 'fixture'
    G $a add -A; G $a commit -q -m base
    Check 'default branch of a master repo' ((Get-RepoDefaultBranch $a) -eq 'master')
    G $a branch main; Check 'default branch prefers main when both exist' ((Get-RepoDefaultBranch $a) -eq 'main'); G $a branch -q -D main
    G $a branch trunk; & git -C $a update-ref refs/remotes/origin/trunk HEAD; & git -C $a symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
    Check 'default branch follows origin/HEAD when that branch exists' ((Get-RepoDefaultBranch $a) -eq 'trunk')
    & git -C $a symbolic-ref --delete refs/remotes/origin/HEAD; G $a branch -q -D trunk; & git -C $a update-ref -d refs/remotes/origin/trunk
    Check 'default branch of a folder that is no repo: empty (callers refuse)' ((Get-RepoDefaultBranch $none) -eq '')

    # no config: today's behaviour. The nested suite is NOT picked up by the default pattern.
    $r = Run 'tests' @('-Dir', $a)
    Check 'no config: default pattern runs tests\Test-*.ps1 only, ALL PASS' ($r.Code -eq 0 -and $r.Out -match 'PASS\s+Test-Top' -and $r.Out -notmatch 'Test-X' -and $r.Out -match 'tests: ALL PASS' -and $r.Out -notmatch 'repo settings')

    # with a config in the main checkout: nested suites found, settings announced
    Put "$a\kitchen.repo.json" '{"tests":["tests/**/Test-*.ps1"],"github":"o/n","protected":[".claude/**","docs/"]}'
    G $a add -A; G $a commit -q -m 'repo config'
    $r = Run 'tests' @('-Dir', $a)
    Check 'config: nested suite is found next to the top one, ALL PASS' ($r.Code -eq 0 -and $r.Out -match 'PASS\s+Test-Top' -and $r.Out -match 'PASS\s+Test-X' -and $r.Out -match 'tests: ALL PASS')
    Check 'config: the station says where the settings came from' ($r.Out -match 'repo settings from .*kitchen\.repo\.json')
    $r = Run 'tests' @('-Dir', $a, '-Only', 'Test-X')
    Check '-Only runs just the named suite' ($r.Code -eq 0 -and $r.Out -match 'PASS\s+Test-X' -and $r.Out -notmatch 'Test-Top')
    $r = Run 'tests' @('-Dir', $a, '-Only', 'Test-Nope')
    Check '-Only with a name that is no suite fails (nothing run, nothing passed)' ($r.Code -eq 1 -and $r.Out -match 'no suites match' -and $r.Out -notmatch 'ALL PASS')
    $r = Run 'tests' @('-Dir', $a, '-Glob', 'tests\Test-Top.ps1')
    Check 'a caller that names its own -Glob still wins over the config' ($r.Code -eq 0 -and $r.Out -match 'PASS\s+Test-Top' -and $r.Out -notmatch 'Test-X')

    # ---- testTimeoutSec ----------------------------------------------------------------------------------------------------------
    $t = Join-Path $root 't'; New-Item -ItemType Directory -Force -Path $t | Out-Null
    & git -C $t init -q -b main 2>&1 | Out-Null
    Put "$t\checks\Test-Slow.ps1" 'Start-Sleep -Seconds 20; Write-Output "Slow tests: 1 passed, 0 failed"; exit 0'
    Put "$t\kitchen.repo.json" '{"tests":["checks/Test-Slow.ps1"],"testTimeoutSec":3}'
    G $t add -A; G $t commit -q -m base
    $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Run 'tests' @('-Dir', $t); $sw.Stop()
    Check 'testTimeoutSec: a suite longer than the configured limit is cut off and FAILS' ($r.Code -eq 1 -and $r.Out -match 'FAIL\s+Test-Slow' -and $r.Out -match 'FAILED: Test-Slow')
    Check 'testTimeoutSec: it was the config limit that applied, not the 600 s default' ($sw.Elapsed.TotalSeconds -lt 18)
    $r = Run 'tests' @('-Dir', $t, '-SuiteTimeoutSec', '60')
    Check 'an explicit -SuiteTimeoutSec wins over the config' ($r.Code -eq 0 -and $r.Out -match 'PASS\s+Test-Slow')

    # ---- bad config stops the stations (nothing runs, nothing falls back to the defaults) ------------------------------------------
    $b1 = Join-Path $root 'b1'; New-Item -ItemType Directory -Force -Path $b1 | Out-Null
    Put "$b1\tests\Test-Top.ps1" $passSuite
    foreach ($case in @(@('type', '{"tests":"tests/Test-Top.ps1"}'), @('dotdot', '{"tests":["../outside/Test-A.ps1"]}'), @('absolute', '{"tests":["C:\\Windows\\Test-A.ps1"]}'), @('json', '{"tests":'))) {
        Put "$b1\kitchen.repo.json" $case[1]
        $r = Run 'tests' @('-Dir', $b1)
        Check "tests station, bad config ($($case[0])): exit 2, clear message, no suite ran" ($r.Code -eq 2 -and $r.Out -match 'tests: kitchen\.repo\.json' -and $r.Out -notmatch 'PASS|ALL PASS')
    }
    $r = Run 'map' @('-Dir', $b1, '-Out', (Join-Path $root 'b1map.md'))
    Check 'map station, bad config: exit 2 before any AI step is paid for' ($r.Code -eq 2 -and $r.Out -match 'map: kitchen\.repo\.json' -and -not (Test-Path (Join-Path $root 'b1map.md')))
    $r = Run 'mutate' @('-Dir', $b1)
    Check 'mutate station, bad config: exit 2' ($r.Code -eq 2 -and $r.Out -match 'mutate: kitchen\.repo\.json')

    # ---- the config comes from the MAIN checkout, never the job's worktree ---------------------------------------------------------
    $wt = Join-Path $root 'wt'
    & git -C $a worktree add -q --detach $wt 2>&1 | Out-Null
    Check 'main checkout of a worktree is the repo it was made from' ((Get-RepoMainCheckout $wt) -eq (Get-RepoMainCheckout $a) -and (Get-RepoMainCheckout $a) -eq [IO.Path]::GetFullPath($a))
    # a cook edits kitchen.repo.json in its worktree: an empty list, then a list naming one trivial suite, then different protected globs
    Put "$wt\kitchen.repo.json" '{"tests":[],"protected":[]}'
    $r = Run 'tests' @('-Dir', $wt)
    Check 'worktree edited to an EMPTY test list: main''s list still runs (both suites, ALL PASS)' ($r.Code -eq 0 -and $r.Out -match 'PASS\s+Test-Top' -and $r.Out -match 'PASS\s+Test-X' -and $r.Out -match 'tests: ALL PASS')
    Put "$wt\checks\Test-Trivial.ps1" $passSuite
    Put "$wt\kitchen.repo.json" '{"tests":["checks/Test-Trivial.ps1"],"testTimeoutSec":1}'
    $r = Run 'tests' @('-Dir', $wt)
    Check 'worktree edited to one trivial suite and a 1 s limit: main''s list and limit still apply' ($r.Code -eq 0 -and $r.Out -match 'PASS\s+Test-X' -and $r.Out -notmatch 'PASS\s+Test-Trivial')
    Put "$wt\kitchen.repo.json" 'this is not even JSON'
    $r = Run 'tests' @('-Dir', $wt)
    Check 'worktree edited to garbage: ignored, main''s settings used' ($r.Code -eq 0 -and $r.Out -match 'tests: ALL PASS')
    Check 'Get-RepoConfig on the worktree reads main''s file' ((Get-RepoConfig $wt).Github -eq 'o/n' -and (Get-RepoConfig $wt).Path -eq (Join-Path ([IO.Path]::GetFullPath($a)) 'kitchen.repo.json'))
    Remove-Item -LiteralPath "$wt\checks" -Recurse -Force
    Put "$wt\kitchen.repo.json" '{"tests":[],"protected":[]}'
    # the suites themselves are found in the worktree: a nested suite the cook adds runs; one the cook deletes fails the run
    Put "$wt\tests\deep\er\Test-New.ps1" $passSuite
    $r = Run 'tests' @('-Dir', $wt)
    Check 'a new nested suite added in the worktree runs' ($r.Code -eq 0 -and $r.Out -match 'PASS\s+Test-New')
    Remove-Item -LiteralPath "$wt\tests\deep" -Recurse -Force
    # protected globs: main's, plus the config file itself, whatever the worktree says
    $pr = @(Get-RepoProtected $wt)
    Check 'protected globs come from main (plus kitchen.repo.json itself), not the worktree' (($pr -join '|') -eq 'kitchen.repo.json|.claude/**|docs/')
    $rx = @(Get-RepoProtectedRegex $wt)
    function Prot([string]$f) { @($rx | Where-Object { $f -match $_ }).Count -gt 0 }
    Check 'protected: file under a ** glob' ((Prot '.claude/hooks/pre_tool_use.ps1') -and (Prot '.claude/settings.json'))
    Check 'protected: a folder glob covers everything below it' (Prot 'docs/a/b/c.md')
    Check 'protected: kitchen.repo.json, in any letter case' ((Prot 'kitchen.repo.json') -and (Prot 'Kitchen.Repo.JSON'))
    Check 'protected: unrelated files and look-alikes are not caught' (-not (Prot 'src/app.ps1') -and -not (Prot 'mydocs/a.md') -and -not (Prot 'sub/kitchen.repo.json.bak') -and -not (Prot 'x.claude/a'))
    Check 'protected, no config: just the config file' (((@(Get-RepoProtected $none)) -join '|') -eq 'kitchen.repo.json')
    Check 'protected, bad config: throws, so the caller can ask Jordan instead' ((Throws { Get-RepoProtected $b1 }) -match 'kitchen\.repo\.json')
    # deleting the configured literal suite in the worktree must fail the run, not shrink it
    Set-Content -LiteralPath "$a\kitchen.repo.json" '{"tests":["tests/sub/Test-X.ps1","tests/Test-Top.ps1"]}' -Encoding utf8
    G $a add -A; G $a commit -q -m 'literal list'
    Remove-Item -LiteralPath "$wt\tests\sub\Test-X.ps1" -Force
    $r = Run 'tests' @('-Dir', $wt)
    Check 'a configured suite deleted in the worktree FAILS the run (exit 1, named)' ($r.Code -eq 1 -and $r.Out -match 'no suites match tests/sub/Test-X\.ps1' -and $r.Out -notmatch 'ALL PASS')
    & git -C $a worktree remove --force $wt 2>&1 | Out-Null

    # ---- mutate sees nested suites: a mutant is killed only by a suite the config names ----------------------------------------------
    $m = Join-Path $root 'm'; New-Item -ItemType Directory -Force -Path $m | Out-Null
    & git -C $m init -q -b master 2>&1 | Out-Null
    Put "$m\README.md" 'x'; Put "$m\kitchen.repo.json" '{"tests":["tests/**/Test-*.ps1"]}'
    G $m add -A; G $m commit -q -m base; $base = (& git -C $m rev-parse HEAD)
    $mw = Join-Path $root 'mw'; & git -C $m worktree add -q --detach $mw 2>&1 | Out-Null
    Put "$mw\lib.ps1" 'function Get-Flag { return $true }'
    Put "$mw\tests\sub\Test-Lib.ps1" ('. (Join-Path $PSScriptRoot "..\..\lib.ps1"); if (Get-Flag) { "Lib tests: 1 passed, 0 failed"; exit 0 } else { "FAIL: flag"; "Lib tests: 0 passed, 1 failed"; exit 1 }')
    G $mw add -A; G $mw commit -q -m 'job'
    $r = Run 'mutate' @('-Dir', $mw, '-Base', $base, '-SuiteTimeoutSec', '60')
    Check 'mutate: the nested suite from the config kills the mutant' ($r.Code -eq 0 -and $r.Out -match 'mutate: ALL PASS \(1/1 mutants killed')
    Put "$m\kitchen.repo.json" '{"tests":["tests/Test-Elsewhere.ps1"]}'   # main's config (not committed: main's working file is what counts) names no nested suite
    $r = Run 'mutate' @('-Dir', $mw, '-Base', $base, '-SuiteTimeoutSec', '60')
    Check 'mutate: it is main''s config that picks the suites (the mutant survives when no suite of its list covers it)' ($r.Out -match 'survived' -and $r.Code -eq 1)
    # lint works on any repo
    $r = Run 'lint' @('-Dir', $mw, '-Base', $base)
    Check 'lint: another repo, master branch, nested suite: clean' ($r.Code -eq 0 -and $r.Out -match 'Lint: 2 passed, 0 failed')
    & git -C $m worktree remove --force $mw 2>&1 | Out-Null

    # ---- the job stations on a repo that is not brain-monitor: master, no tests\Test-*.ps1 anywhere ----------------------------------
    $p = Join-Path $root 'p'; New-Item -ItemType Directory -Force -Path $p | Out-Null
    & git -C $p init -q -b master 2>&1 | Out-Null
    Put "$p\checks\run.ps1" 'Write-Output "Checks tests: 3 passed, 0 failed"; exit 0'
    Put "$p\src\app.ps1" "# the app`nfunction Get-Thing { 1 }"
    Put "$p\kitchen.repo.json" '{"tests":["checks/run.ps1"],"testTimeoutSec":120}'
    # the repo has git hooks that refuse every commit and merge commit (Demo Project sets core.hooksPath=scripts/hooks); the hook files are tracked,
    # so a job's worktree has its own copy of them, which the cook could edit: the kitchen's own commits must not run them
    Put "$p\hooks\pre-commit" 'exit 1'; Put "$p\hooks\pre-merge-commit" 'exit 1'
    G $p add -A; G $p commit -q -m base
    & git -C $p config core.hooksPath hooks
    $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_JOB = 'J7'
    $r = Run 'worktree' @('-Repo', $p)
    $pw = Join-Path $kr 'worktrees\J7'
    Check 'worktree: set up for a master repo' ($r.Code -eq 0 -and (Test-Path "$pw\.git") -and (& git -C $pw rev-parse --abbrev-ref HEAD) -eq 'kitchen/J7' -and (Test-Path "$pw\.kitchen\BASE"))
    $r = Run 'map' @()
    $mapText = Get-Content "$pw\.kitchen\MAP.md" -Raw
    Check 'map: lists the repo and names ITS tests, not tests\Test-*.ps1' ($r.Code -eq 0 -and $mapText -match 'Tests are checks/run\.ps1' -and $mapText -notmatch 'Tests are tests/Test' -and $mapText -match 'src/app\.ps1' -and $mapText -match 'Get-Thing')
    $r = Run 'tests' @()
    Check 'tests (job worktree, no -Dir): runs the configured suite with no tests\Test-*.ps1 in the repo' ($r.Code -eq 0 -and $r.Out -match 'PASS\s+run\s' -and $r.Out -match 'tests: ALL PASS' -and (Get-Content "$pw\.kitchen\TESTS.txt" -Raw) -match 'ALL PASS')
    # the job commits, main moves on, freshen merges main (a master branch) in
    Put "$pw\src\app.ps1" "# the app`nfunction Get-Thing { 2 }"
    $env:KITCHEN_RUN = $null
    & git -C $pw add -A 2>&1 | Out-Null
    & git -C $pw -c user.name=t -c user.email=t@localhost commit -q -m control 2>&1 | Out-Null
    Check 'control: the repo''s own commit hook does stop a plain commit' ($LASTEXITCODE -ne 0)
    & git -C $pw reset -q 2>&1 | Out-Null
    $r = Run 'commit' @('-Message', 'job edit')
    Check 'commit station: commits in a repo whose hooks refuse commits (hooks are not run)' ($r.Code -eq 0 -and (& git -C $pw log -1 --format=%s) -match '^kitchen J7: job edit')
    Put "$p\README.md" 'main moved'; & git -C $p add -A; & git -C $p -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@localhost commit -q -m 'main edit' 2>&1 | Out-Null
    $r = Run 'freshen' @('-Repo', $p)
    Check 'freshen: merges master into the job branch, with hooks that refuse merge commits' ($r.Code -eq 0 -and $r.Out -match 'up to date with master@' -and (& git -C $pw rev-list --parents -n 1 HEAD).Split(' ').Count -eq 3)
    G $p checkout -q -b side
    $r = Run 'freshen' @('-Repo', $p)
    Check 'freshen: a checkout off master waits (exit 11) and says master, not main' ($r.Code -eq 11 -and $r.Out -match "on 'side', not master")
    G $p checkout -q master
    # verify, on the real checkout: master is "main" here
    $env:KITCHEN_JOB = 'J9'
    $r = Run 'verify' @('-Repo', $p)
    Check 'verify: a master repo with its own suite list passes' ($r.Code -eq 0 -and $r.Out -match 'verify: ALL PASS on')
    G $p checkout -q side
    $r = Run 'verify' @('-Repo', $p)
    Check 'verify: off master is held (exit 10), says master, nothing undone' ($r.Code -eq 10 -and $r.Out -match "on 'side', not master" -and $r.Out -match 'nothing undone')
    G $p checkout -q master
    $env:KITCHEN_JOB = 'J7'
    & git -C $p worktree remove --force $pw 2>&1 | Out-Null
}
finally {
    $env:BRAIN_KITCHEN = $old.k; $env:KITCHEN_JOB = $old.j; $env:KITCHEN_RUN = $old.r
    foreach ($repoDir in 'a', 'm', 'p', 't') { if (Test-Path -LiteralPath (Join-Path $root $repoDir)) { & git -C (Join-Path $root $repoDir) worktree prune 2>&1 | Out-Null } }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "RepoConfig tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
