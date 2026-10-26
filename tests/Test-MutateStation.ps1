# Tests for the mutate station (kitchen/stations/mutate.ps1). Self-cleaning.
$ErrorActionPreference = 'Stop'
$st = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\mutate.ps1')).Path
$dir = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-mutate-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }

try {
    # Set up scratch git repository
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'tests'), (Join-Path $dir '.kitchen') | Out-Null
    & git -C $dir init -q -b main 2>&1 | Out-Null
    & git -C $dir config user.name "Test Cook"
    & git -C $dir config user.email "test@localhost"

    # Base commit with an unchanged function
    $baseContent = @"
function Get-Base {
    if (`$true) {
        return 1
    }
    return 0
}
"@
    Set-Content (Join-Path $dir 'lib.ps1') $baseContent
    & git -C $dir add -A 2>&1 | Out-Null
    & git -C $dir commit -q -m "base commit" 2>&1 | Out-Null
    $baseTip = (& git -C $dir rev-parse HEAD).Trim()
    Set-Content (Join-Path $dir '.kitchen\BASE') $baseTip

    # 1. Zero-Mutant / Clean Diff (test case 9)
    # Adding docs and comments only produces 0 mutants and exits 0 cleanly
    Set-Content (Join-Path $dir 'README.md') '# Sample Documentation'
    Set-Content (Join-Path $dir 'tests\Test-Lib.ps1') "Write-Output 'Lib tests: 1 passed, 0 failed'; exit 0"
    & git -C $dir add -A 2>&1 | Out-Null
    & git -C $dir commit -q -m "docs change" 2>&1 | Out-Null
    $outZero = & pwsh -NoProfile -File $st -Dir $dir 2>&1 | Out-String
    $codeZero = $LASTEXITCODE
    Check 'zero mutants on clean/docs diff exits 0 cleanly' ($codeZero -eq 0 -and $outZero -match '0 mutants generated')

    # Now add code changes to lib.ps1 exercising operators, booleans, and truthy inversion
    $modifiedContent = @"
function Get-Base {
    if (`$true) {
        return 1
    }
    return 0
}

function Check-All(`$a, `$b, `$flag) {
    if (`$a -gt `$b) {
        if (-not `$flag) {
            return `$true
        }
    }
    return `$false
}
"@
    Set-Content (Join-Path $dir 'lib.ps1') $modifiedContent
    & git -C $dir add -A 2>&1 | Out-Null
    & git -C $dir commit -q -m "add Check-All logic" 2>&1 | Out-Null

    # 2. Diff Scoping (test case 1)
    # The unchanged function Get-Base (lines 1-6) must not be mutated, only Check-All (lines 8-15)
    # Test suite currently has vacuous pass, so all mutants on changed lines will survive
    Set-Content (Join-Path $dir 'tests\Test-Lib.ps1') "Write-Output 'Lib tests: 1 passed, 0 failed'; exit 0"
    $outSurv = & pwsh -NoProfile -File $st -Dir $dir 2>&1 | Out-String
    $codeSurv = $LASTEXITCODE

    Check 'diff scoping: unchanged lines in Get-Base are not mutated' ($outSurv -notmatch 'lib\.ps1:2\b')
    Check 'diff scoping: changed lines in Check-All are mutated' ($outSurv -match 'lib\.ps1:9\b')

    # 3. Operator Swapping (test case 2)
    Check 'operator swapping: -gt swapped to -le' ($outSurv -match 'lib\.ps1:9 \(-gt -> -le\) survived')

    # 4. Truthy Inversion (test case 4)
    Check 'truthy inversion: -not inverted' ($outSurv -match 'lib\.ps1:10 \(-not -> \) survived')

    # 5. Boolean Toggling (test case 3)
    Check 'boolean toggling: $true swapped to $false' ($outSurv -match 'lib\.ps1:11 \(\$true -> \$false\) survived')
    Check 'boolean toggling: $false swapped to $true' ($outSurv -match 'lib\.ps1:14 \(\$false -> \$true\) survived')

    # 6. Mutant Survived & .kitchen/TESTS.txt Append (test case 6)
    Check 'mutant survived: station reports failure and exits 1' ($codeSurv -eq 1 -and $outSurv -match 'FAILED: Mutate')
    $testsTxt = Join-Path $dir '.kitchen\MUTANTS.txt'
    Check 'mutant survived: written to .kitchen/MUTANTS.txt for the taster' (
        (Test-Path -LiteralPath $testsTxt) -and
        ((Get-Content -LiteralPath $testsTxt -Raw) -match 'FAIL\s+Mutate') -and
        ((Get-Content -LiteralPath $testsTxt -Raw) -match '\(-gt -> -le\) survived') -and
        ((Get-Content -LiteralPath $testsTxt -Raw) -match 'FAILED: Mutate')
    )

    Check 'mutant survived: TESTS.txt is left as the suites wrote it' (-not (Test-Path (Join-Path $dir '.kitchen\TESTS.txt')) -or (Get-Content (Join-Path $dir '.kitchen\TESTS.txt') -Raw) -notmatch 'Mutate')

    # 7. Soft Mode (test case 7)
    $outSoft = & pwsh -NoProfile -File $st -Dir $dir -Soft 2>&1 | Out-String
    $codeSoft = $LASTEXITCODE
    Check 'soft mode: reports failure but exits 0' ($codeSoft -eq 0 -and $outSoft -match 'FAILED: Mutate')

    # 8. Mutant Killed (test case 5)
    # Strengthen test suite so every mutant is caught and killed
    $strongTests = @"
. "`$PSScriptRoot\..\lib.ps1"
if (-not (Check-All 10 5 `$false)) { Write-Output "FAIL: 10 > 5 with false flag should return true"; exit 1 }
if (Check-All 5 10 `$false) { Write-Output "FAIL: 5 > 10 should return false"; exit 1 }
if (Check-All 10 10 `$false) { Write-Output "FAIL: 10 > 10 should return false"; exit 1 }
if (Check-All 10 5 `$true) { Write-Output "FAIL: true flag should return false"; exit 1 }
Write-Output "Lib tests: 4 passed, 0 failed"; exit 0
"@
    Set-Content (Join-Path $dir 'tests\Test-Lib.ps1') $strongTests
    $outKilled = & pwsh -NoProfile -File $st -Dir $dir 2>&1 | Out-String
    $codeKilled = $LASTEXITCODE
    Check 'mutant killed: when tests assert logic, all mutants killed and station exits 0' ($codeKilled -eq 0 -and $outKilled -match 'mutate: ALL PASS \(\d+\/\d+ mutants killed\)')

    # 9. File Restoration (test case 8)
    # Verify file content on disk is restored to exact pre-mutation content
    $diskLib = Get-Content (Join-Path $dir 'lib.ps1') -Raw
    Check 'file restoration: file content on disk restored after normal run' ($diskLib.Trim() -eq $modifiedContent.Trim())

    # Verify file content is restored even if a test suite crashes / throws
    Set-Content (Join-Path $dir 'tests\Test-Lib.ps1') "throw 'simulated test crash'"
    $outCrash = & pwsh -NoProfile -File $st -Dir $dir 2>&1 | Out-String
    $diskLibCrash = Get-Content (Join-Path $dir 'lib.ps1') -Raw
    Check 'file restoration: file content on disk restored even when test suite crashes' ($diskLibCrash.Trim() -eq $modifiedContent.Trim())

    # 10. A run killed mid-mutant (J64: the step timed out and app.js stayed mutated): the next run restores the noted file first
    Set-Content (Join-Path $dir 'lib.ps1') ($modifiedContent -replace '-gt', '-ge')
    Set-Content (Join-Path $dir '.kitchen\MUTANT.txt') 'lib.ps1'
    $outRestore = & pwsh -NoProfile -File $st -Dir $dir -BudgetSec 0 2>&1 | Out-String
    Check 'killed run: the left-over mutant is restored from the last commit' ((Get-Content (Join-Path $dir 'lib.ps1') -Raw).Trim() -eq $modifiedContent.Trim() -and $outRestore -match 'restored lib\.ps1')
    Check 'killed run: the note is cleared' (-not (Test-Path (Join-Path $dir '.kitchen\MUTANT.txt')))
    # 11. The time budget stops new mutants before the step's timeout can kill one mid-way
    Check 'time budget: no mutant started once the budget is used' ($outRestore -match 'time budget \(0 s\) used; tried 0 of')

    # 12. JavaScript markup is not a comparison (J64: 8 "survivors" were '<' and '>' of HTML tags in app.js templates)
    & git -C $dir checkout -q -- . 2>&1 | Out-Null
    Set-Content (Join-Path $dir 'ui.mjs') ("export const row = (n) => ``<b>`${n}</b>``;`nexport const tag = '<i>';`n<div class=`"x`">`n</div>")
    & git -C $dir add -A 2>&1 | Out-Null; & git -C $dir commit -q -m "ui markup" 2>&1 | Out-Null
    Set-Content (Join-Path $dir '.kitchen\BASE') ((& git -C $dir rev-parse HEAD~1).Trim())
    $outJs = & pwsh -NoProfile -File $st -Dir $dir -BudgetSec 0 2>&1 | Out-String
    Check 'JS: markup in templates, strings and multi-line HTML makes no mutants' ($outJs -match '0 mutants generated')
    Add-Content (Join-Path $dir 'ui.mjs') "`nexport const less = (a, b) => a < b;"
    & git -C $dir add -A 2>&1 | Out-Null; & git -C $dir commit -q -m "ui compare" 2>&1 | Out-Null
    $outJs2 = & pwsh -NoProfile -File $st -Dir $dir -BudgetSec 0 2>&1 | Out-String
    Check 'JS: a real spaced comparison still makes a mutant' ($outJs2 -notmatch '0 mutants generated' -and $outJs2 -match 'tried 0 of 1 ')

    # 13. each suite run gets a fresh empty kitchen of its own, marked under test: never a blank BRAIN_KITCHEN (blank = Jordan's live kitchen)
    # the probe goes in a folder labelled Low: suites run at Low integrity (rust/kitchen-sandbox) and cannot write this test's Medium folders
    $pd = Join-Path $dir 'shared'; New-Item -ItemType Directory -Force -Path $pd | Out-Null; & icacls.exe $pd /setintegritylevel '(OI)(CI)low' /Q 2>&1 | Out-Null
    $probe = Join-Path $pd 'probe.txt'
    Set-Content (Join-Path $dir 'tests\Test-Probe.ps1') "Add-Content '$probe' (`"`$env:BRAIN_KITCHEN|`$env:KITCHEN_UNDER_TEST|`" + (Test-Path -LiteralPath `"`$env:BRAIN_KITCHEN`")); 'Probe tests: 1 passed, 0 failed'; exit 0"
    Add-Content (Join-Path $dir 'ui.mjs') "`nexport const more = (a, b) => a > b;"
    & git -C $dir add -A 2>&1 | Out-Null; & git -C $dir commit -q -m "probe" 2>&1 | Out-Null
    Set-Content (Join-Path $dir '.kitchen\BASE') ((& git -C $dir rev-parse HEAD~1).Trim())
    $null = & pwsh -NoProfile -File $st -Dir $dir 2>&1
    $pv = "$(@(Get-Content $probe -ErrorAction SilentlyContinue | Where-Object { $_ }) | Select-Object -First 1)" -split '\|'
    Check 'suite env: a fresh kt- kitchen, marked under test, removed afterwards' ($pv[0] -match '\\kt-[0-9a-f]{32}$' -and $pv[1] -eq '1' -and $pv[2] -eq 'True' -and -not (Test-Path -LiteralPath $pv[0]))

    # 14. a suite cut short by its time limit says nothing about the mutant: not judged (never "killed"), listed for the taster
    Set-Content (Join-Path $dir 'tests\Test-Slow.ps1') "Start-Sleep 6; 'Slow tests: 1 passed, 0 failed'; exit 0"
    $outSlow = & pwsh -NoProfile -File $st -Dir $dir -Glob 'tests\Test-Slow.ps1' -SuiteTimeoutSec 2 2>&1 | Out-String
    Check 'suite timeout: not counted as a killed mutant' ($outSlow -notmatch '1/1 mutants killed' -and $outSlow -match '1 not judged')
    Check 'suite timeout: MUTANTS.txt says not judged: suite too slow' ((Get-Content (Join-Path $dir '.kitchen\MUTANTS.txt') -Raw) -match 'ui\.mjs:\d+ .*not judged: suite too slow')
    # 15. the suite's limit comes from its own time in TESTS.txt (twice it): the slow suite now runs to the end and judges the mutant
    Set-Content (Join-Path $dir '.kitchen\TESTS.txt') "PASS  Test-Slow                          Slow tests: 1 passed, 0 failed (5.5s)`nALL PASS"
    $outFit = & pwsh -NoProfile -File $st -Dir $dir -Glob 'tests\Test-Slow.ps1' -SuiteTimeoutSec 2 2>&1 | Out-String
    Check 'suite limit from TESTS.txt: the suite finishes and the mutant is judged (survived)' ($outFit -match 'ui\.mjs:\d+ \(> -> <=\) survived' -and $outFit -notmatch 'not judged')
    # 16. a mutant whose suites cannot finish before the step's own limit is not started (the step would be stopped mid-mutant)
    $env:KITCHEN_TIMEOUT = '125'
    try { $outCost = & pwsh -NoProfile -File $st -Dir $dir -Glob 'tests\Test-Slow.ps1' -SuiteTimeoutSec 2 2>&1 | Out-String } finally { $env:KITCHEN_TIMEOUT = $null }
    Check 'step limit: a mutant that cannot finish in time is not started' ($outCost -match '0/0 mutants killed, 1 not tried')
    Remove-Item -LiteralPath (Join-Path $dir '.kitchen\TESTS.txt')

    # 17. a run with no mutants clears last round's MUTANTS.txt (after a rework the taster must not see old survivors)
    Set-Content (Join-Path $dir '.kitchen\MUTANTS.txt') "FAIL  Mutate  3 mutants survived`n      FAIL: gone.ps1:9 (-gt -> -le) survived"
    Set-Content (Join-Path $dir '.kitchen\BASE') ((& git -C $dir rev-parse HEAD).Trim())
    $outNone = & pwsh -NoProfile -File $st -Dir $dir 2>&1 | Out-String
    Check 'no mutants: a stale MUTANTS.txt is removed' ($outNone -match '0 mutants generated' -and -not (Test-Path (Join-Path $dir '.kitchen\MUTANTS.txt')))

} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "MutateStation tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
