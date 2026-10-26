# Tests for the commit station's configurable budget excludes (kitchen/stations/commit.ps1 + kitchen.repo.json commitBudget.exclude).
# Run by the kitchen tests station (tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Self-cleaning: scratch repos under TEMP.
$ErrorActionPreference = 'Stop'
$commitPs = Join-Path $PSScriptRoot '..\kitchen\stations\commit.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('cb-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G([string]$r) { & git -C $r -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function Add-Lines([string]$wt, [string]$rel, [int]$n) {
    $full = Join-Path $wt $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
    Set-Content -LiteralPath $full -Value (1..$n | ForEach-Object { "line $_" })
}
# a job worktree whose seed commit (BASE) holds kitchen.repo.json, so the config is read but is not part of the change
function New-Case([string]$name, [string]$json) {
    $kroot = Join-Path $root $name; $wt = Join-Path $kroot 'worktrees\J1'
    New-Item -ItemType Directory -Force -Path $wt | Out-Null
    G $wt init -q
    Set-Content (Join-Path $wt 'seed.txt') 'seed'
    if ($json) { Set-Content -LiteralPath (Join-Path $wt 'kitchen.repo.json') -Value $json -Encoding utf8 }
    G $wt add -A; G $wt commit -q -m seed
    New-Item -ItemType Directory -Path (Join-Path $wt '.kitchen') | Out-Null
    $base = (& git -C $wt rev-parse HEAD).Trim()
    Set-Content (Join-Path $wt '.kitchen\BASE') $base
    [pscustomobject]@{ Kroot = $kroot; Wt = $wt; Base = $base }
}
function Invoke-Commit($case, [string[]]$extra = @()) {
    $env:KITCHEN_JOB = 'J1'; $env:BRAIN_KITCHEN = $case.Kroot
    $o = & pwsh -NoProfile -File $commitPs @extra 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}
function Head-Of($case) { (& git -C $case.Wt rev-parse HEAD).Trim() }
$old = @{ j = $env:KITCHEN_JOB; k = $env:BRAIN_KITCHEN }
$cfg = '{"commitBudget":{"files":4,"lines":150,"exclude":["fixtures","evals"]}}'
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    # no exclude configured: fixtures/ counts exactly as before, and no excludes line is printed
    $c = New-Case 'default' '{"commitBudget":{"files":4,"lines":150}}'; Add-Lines $c.Wt 'a.txt' 2; Add-Lines $c.Wt 'fixtures/mailflow/big.json' 200
    $r = Invoke-Commit $c
    Check 'absent exclude: default unchanged (fixtures counted, rejected)' ($r.Code -eq 1 -and $r.Out -match 'lines changed \(max 150\)' -and (Head-Of $c) -eq $c.Base -and $r.Out -notmatch 'budget excludes')

    # exclude ["fixtures","evals"]: data under them is not counted, but is still committed; the excludes are printed
    $c = New-Case 'excl' $cfg; Add-Lines $c.Wt 'a.txt' 2
    1..6 | ForEach-Object { Add-Lines $c.Wt "fixtures/mailflow/f$_.json" 100 }; Add-Lines $c.Wt 'evals/cases/e1.jsonl' 300
    $r = Invoke-Commit $c
    Check 'exclude: fixtures and evals not counted, change committed' ($r.Code -eq 0 -and $r.Out -match 'change committed' -and (Head-Of $c) -ne $c.Base)
    Check 'exclude: excluded files are still in the commit' (@(& git -C $c.Wt diff --name-only $c.Base HEAD -- fixtures evals).Count -eq 7)
    Check 'exclude: prints "commit: budget excludes: tests, fixtures, evals"' ($r.Out -match 'commit: budget excludes: tests, fixtures, evals')

    # tests/ is always excluded, with or without a list
    $c = New-Case 'tests' $cfg; Add-Lines $c.Wt 'a.txt' 2; 1..6 | ForEach-Object { Add-Lines $c.Wt "tests/t$_.ps1" 40 }
    $r = Invoke-Commit $c
    Check 'exclude: tests/ still not counted' ($r.Code -eq 0)

    # code outside the excludes still counts: a lookalike folder name (fixtures2/) is not excluded
    $c = New-Case 'over' $cfg; Add-Lines $c.Wt 'src/big.ps1' 200; Add-Lines $c.Wt 'fixtures2/x.json' 1; Add-Lines $c.Wt 'fixtures/x.json' 500
    $r = Invoke-Commit $c
    Check 'exclude: non-excluded lines still rejected, message names the excludes' ($r.Code -eq 1 -and $r.Out -match '201 non-test lines changed \(max 150\)' -and $r.Out -match 'tests, fixtures, evals are not counted' -and (Head-Of $c) -eq $c.Base)

    # a glob entry: * stays inside one folder, ** crosses folders (the config's own glob rules)
    $c = New-Case 'glob' '{"commitBudget":{"files":4,"lines":150,"exclude":["data/**/*.json"]}}'
    Add-Lines $c.Wt 'data/a/b/big.json' 400; Add-Lines $c.Wt 'data/notes.txt' 151
    $r = Invoke-Commit $c
    Check 'exclude: glob entry excludes only what it matches' ($r.Code -eq 1 -and $r.Out -match '151 non-test lines changed')

    # the list applies even when the caller passes both limits
    $c = New-Case 'both' $cfg; Add-Lines $c.Wt 'a.txt' 2; Add-Lines $c.Wt 'evals/e.jsonl' 50
    $r = Invoke-Commit $c @('-MaxChangedFiles', '1', '-MaxDiffLines', '5')
    Check 'exclude: applies with both -Max given' ($r.Code -eq 0)

    # a bad exclude entry fails closed: nothing committed, the message names the key
    $c = New-Case 'bad' '{"commitBudget":{"exclude":["../outside"]}}'; Add-Lines $c.Wt 'a.txt' 2
    $r = Invoke-Commit $c
    Check 'exclude: bad entry fails closed with a clear message' ($r.Code -eq 1 -and $r.Out -match "commitBudget\.exclude' entry" -and (Head-Of $c) -eq $c.Base)

    # TD-EH-09: a Resurvey stopped after its merge commit but before the Benchmark move (BASE.next names the merged tip, HEAD has it): the
    # commit Step finishes the move, so main's lines in that merge are not counted against the Crew
    $c = New-Case 'resurvey' $cfg
    G $c.Wt checkout -q -b side; Add-Lines $c.Wt 'main-big.txt' 300; G $c.Wt add -A; G $c.Wt commit -q -m 'main change'
    $tipM = (Head-Of $c); G $c.Wt checkout -q -; G $c.Wt merge -q --no-ff side -m 'Freshen (stopped)'
    Set-Content (Join-Path $c.Wt '.kitchen\BASE.next') $tipM; Add-Lines $c.Wt 'a.txt' 2
    $r = Invoke-Commit $c
    Check 'stopped Resurvey: the move is finished, main''s lines not counted, the change committed' ($r.Code -eq 0 -and $r.Out -match "commit: finished an interrupted Resurvey: the Benchmark moves to $($tipM.Substring(0, 7))" -and $r.Out -notmatch 'DIFF BUDGET EXCEEDED' -and (Get-Content (Join-Path $c.Wt '.kitchen\BASE') -Raw).Trim() -eq $tipM)
    Check 'stopped Resurvey: BASE.next gone, DIFF.patch holds only the job change' (-not (Test-Path (Join-Path $c.Wt '.kitchen\BASE.next')) -and (Get-Content (Join-Path $c.Wt '.kitchen\DIFF.patch') -Raw) -notmatch 'main-big\.txt')

    # TD-EH-21: a git add that fails (an index lock) says so with git's words, never "NO CHANGES" (which blames the Crew)
    $c = New-Case 'addfail' $cfg; Add-Lines $c.Wt 'a.txt' 2; Set-Content (Join-Path $c.Wt '.git\index.lock') ''
    $r = Invoke-Commit $c
    Check 'git add failed: said with git''s words, not NO CHANGES, nothing committed' ($r.Code -eq 1 -and $r.Out -match 'commit: git add failed: .*index\.lock' -and $r.Out -notmatch 'NO CHANGES' -and (Head-Of $c) -eq $c.Base)
}
finally {
    $env:KITCHEN_JOB = $old.j; $env:BRAIN_KITCHEN = $old.k
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "CommitBudget tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
