# Tests for the Watch's two review gates: the taster override (kitchen/taster-gate.ps1, wired into kitchen/stations/pr.ps1) and the weakened-test check (scripts/weakened-tests.ps1, wired into commit.ps1).
# Run by the kitchen tests station (tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Scratch git repos and a scratch kitchen in TEMP; no AI, no network.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$gateLib = (Resolve-Path (Join-Path $here '..\kitchen\taster-gate.ps1')).Path
$prSt = (Resolve-Path (Join-Path $here '..\kitchen\stations\pr.ps1')).Path
$commitSt = (Resolve-Path (Join-Path $here '..\kitchen\stations\commit.ps1')).Path
$weak = (Resolve-Path (Join-Path $here '..\scripts\weakened-tests.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-watchgates-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Put([string]$path, [string]$text) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null; Set-Content -LiteralPath $path -Value $text -Encoding utf8 }
function G([string]$dir) { & git -C $dir -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function NewRepo([string]$dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null; G $dir init -q -b main; Put "$dir\app.txt" 'v1'; G $dir add -A; G $dir commit -q -m base }
function Weak([string]$dir, [string]$base) { $o = & pwsh -NoProfile -File $weak -Dir $dir -Base $base 2>&1 | Out-String; @{ out = $o; code = $LASTEXITCODE } }
$saved = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB }
try {
    # ---- the taster override ------------------------------------------------------------------------------------------------------
    . $gateLib
    $kr = Join-Path $root 'kitchen'; $repo = Join-Path $root 'repo'; NewRepo $repo
    $testsScript = 'C:\x\kitchen\stations\tests.ps1'
    function Job([string]$id, [string]$verdict, $tests, [switch]$NoTestsStep, [switch]$Private) {
        G $repo branch -f "kitchen/$id" main
        $steps = @(@{ script = 'C:\x\kitchen\stations\commit.ps1'; args = @{} })
        if (-not $NoTestsStep) { $steps += @{ script = $testsScript; args = @{ Soft = $true } } }
        $steps += @{ script = 'C:\x\kitchen\agent-step.ps1'; args = @{ Role = 'check' } }
        $steps += @{ script = 'C:\x\kitchen\stations\pr.ps1'; args = @{ Repo = $repo } }
        $j = [ordered]@{ id = $id; recipe = 'improve'; vars = @{ goal = "change $id"; private = $(if ($Private) { 'yes' } else { '' }) }; steps = $steps }
        Put "$kr\jobs\$id.json" ($j | ConvertTo-Json -Depth 6)
        $ti = $steps.Count - 2
        if ($verdict) { Put "$kr\run\$id-s$ti-a0.log" "# Review`nchecked things`nVERDICT: $verdict - reasons checked carefully here" }
        if ($tests) { Put "$kr\results\$id.tests.json" ($tests | ConvertTo-Json) }
        Get-Content "$kr\jobs\$id.json" -Raw | ConvertFrom-Json
    }
    $tip = ([string](& git -C $repo rev-parse main)).Trim()

    $g = Get-TasterGate $kr 'J1' (Job 'J1' 'SHIP' @{ job = 'J1'; sha = $tip; final = 'FAILED: Test-X' }) $repo
    Check 'final tests red + taster SHIP: blocked with the plain reason' ($g.block -and $g.say -match "^tests are red; the taster's SHIP is overridden" -and $g.say -match 'FAILED: Test-X')
    $g = Get-TasterGate $kr 'J2' (Job 'J2' 'SHIP' @{ job = 'J2'; sha = $tip; final = 'ALL PASS' }) $repo
    Check 'final tests green on the tip + SHIP: goes through' (-not $g.block -and $g.say -match 'ALL PASS' -and $g.say -match 'SHIP')
    $g = Get-TasterGate $kr 'J3' (Job 'J3' 'SHIP' @{ job = 'J3'; sha = ('0' * 40); final = 'ALL PASS' }) $repo
    Check 'green tests for another commit than the tip count as red' ($g.block -and $g.say -match 'changed after the last tests run')
    $g = Get-TasterGate $kr 'J4' (Job 'J4' 'SHIP' $null) $repo
    Check 'no tests record counts as red' ($g.block -and $g.say -match 'no record')
    $g = Get-TasterGate $kr 'J5' (Job 'J5' 'REWORK' @{ job = 'J5'; sha = $tip; final = 'FAILED: Test-Y' }) $repo
    Check 'red tests without a SHIP: still blocked, no SHIP claimed' ($g.block -and $g.say -notmatch 'SHIP' -and $g.say -match 'tests are red')
    $g = Get-TasterGate $kr 'J6' (Job 'J6' 'SHIP' $null -NoTestsStep) $repo
    Check 'an order with no tests step is not gated, and says so' (-not $g.block -and $g.say -match 'no tests step')

    # the pr station itself: a private order (no GitHub needed) is stopped before it can go on to merge locally
    $env:BRAIN_KITCHEN = $kr
    Job 'J7' 'SHIP' @{ job = 'J7'; sha = $tip; final = 'FAILED: Test-Z' } -Private | Out-Null
    $env:KITCHEN_JOB = 'J7'; $o = & pwsh -NoProfile -File $prSt -Repo $repo 2>&1 | Out-String; $c = $LASTEXITCODE
    Check 'pr station: red tests + SHIP fails loudly (exit 1, plain reason)' ($c -eq 1 -and $o -match "pr: STOPPED: tests are red; the taster's SHIP is overridden" -and -not (Test-Path "$kr\results\J7.pr.json"))
    Job 'J8' 'SHIP' @{ job = 'J8'; sha = $tip; final = 'ALL PASS' } -Private | Out-Null
    $env:KITCHEN_JOB = 'J8'; $o = & pwsh -NoProfile -File $prSt -Repo $repo 2>&1 | Out-String; $c = $LASTEXITCODE
    Check 'pr station: green tests + SHIP goes on as before' ($c -eq 0 -and $o -match 'pr: tests pass on this commit' -and $o -match 'private order')

    # ---- the weakened-test check --------------------------------------------------------------------------------------------------
    $w = Join-Path $root 'weak'; NewRepo $w
    Put "$w\tests\Test-A.ps1" "Check 'one' (`$x -eq 1)`nCheck 'two' (`$y -eq 2)`nCheck 'count' (`$items.Count -eq 5)"
    Put "$w\tests\Test-B.ps1" "Check 'b' `$true"
    G $w add -A; G $w commit -q -m tests; $b0 = ([string](& git -C $w rev-parse HEAD)).Trim()

    G $w checkout -q -b clean $b0
    Put "$w\tests\Test-A.ps1" "Check 'one' (`$x -eq 1)`nCheck 'two' (`$y -eq 2)`nCheck 'count' (`$items.Count -eq 6)`nCheck 'three' (`$z -eq 3)"
    Put "$w\app.txt" 'v2'; G $w add -A; G $w commit -q -m clean
    $r = Weak $w $b0
    Check 'weakened: an added check and a raised count are not flagged (exit 0)' ($r.code -eq 0 -and $r.out -match 'weakened-tests: none' -and $r.out -notmatch 'FLAG')

    G $w checkout -q -b del $b0; G $w rm -q tests/Test-B.ps1; G $w commit -q -m del
    $r = Weak $w $b0
    Check 'weakened: a deleted test file is flagged (exit 1)' ($r.code -eq 1 -and $r.out -match 'FLAG: test file deleted: tests/Test-B.ps1')

    G $w checkout -q -b fewer $b0
    Put "$w\tests\Test-A.ps1" "Check 'count' (`$items.Count -eq 5)"; G $w add -A; G $w commit -q -m fewer
    $r = Weak $w $b0
    Check 'weakened: removed check lines are flagged with the count' ($r.code -eq 1 -and $r.out -match 'FLAG: tests/Test-A.ps1 has 2 fewer check line')

    G $w checkout -q -b lower $b0
    Put "$w\tests\Test-A.ps1" "Check 'one' (`$x -eq 1)`nCheck 'two' (`$y -eq 2)`nCheck 'count' (`$items.Count -eq 3)"; G $w add -A; G $w commit -q -m lower
    $r = Weak $w $b0
    Check 'weakened: a lowered expected count is flagged (5 -> 3)' ($r.code -eq 1 -and $r.out -match 'FLAG: tests/Test-A.ps1 lowers an expected number \(5 -> 3\)')

    $r = Weak $w 'no-such-commit'
    Check 'weakened: a base that is not a commit cannot be checked (exit 2, says why)' ($r.code -eq 2 -and $r.out -match "cannot check: 'no-such-commit' is not a commit")

    # wired in: the commit station writes the findings next to the diff the taster reads
    $kr2 = Join-Path $root 'kitchen2'; $wt = Join-Path $kr2 'worktrees\J9'; NewRepo $wt
    Put "$wt\tests\Test-C.ps1" "Check 'c1' `$true`nCheck 'c2' `$true"; G $wt add -A; G $wt commit -q -m t
    Put "$wt\.kitchen\BASE" ([string](& git -C $wt rev-parse HEAD)).Trim()
    Put "$wt\.git\info\exclude" '.kitchen/'
    Put "$wt\tests\Test-C.ps1" "Check 'c1' `$true"; Put "$wt\app.txt" 'v3'
    $env:BRAIN_KITCHEN = $kr2; $env:KITCHEN_JOB = 'J9'
    $o = & pwsh -NoProfile -File $commitSt -Message 'weaken it' 2>&1 | Out-String; $c = $LASTEXITCODE
    $patch = Get-Content "$wt\.kitchen\DIFF.patch" -Raw
    Check 'commit station: the taster sees weakened-test findings (DIFF.patch, WEAKENED.txt, station output)' ($c -eq 0 -and $patch -match '# weakened-test check' -and $patch -match '# FLAG: tests/Test-C.ps1 has 1 fewer check line' -and (Get-Content "$wt\.kitchen\WEAKENED.txt" -Raw) -match 'FLAG' -and $o -match 'commit: FLAG')
}
catch { $script:fail++; Write-Host "FAIL: crashed: $_ at $($_.ScriptStackTrace -replace '\s+', ' ')" }
finally {
    $env:BRAIN_KITCHEN = $saved.k; $env:KITCHEN_JOB = $saved.j
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Test-WatchGates: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
