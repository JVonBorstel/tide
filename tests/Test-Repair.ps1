# Tests for the repair station's test runs (kitchen/stations/repair.ps1): after a cook round the suites that failed run first, alone;
# still red ends the round without a full run, green goes on to the impacted suites and then one full run. The real repair.ps1 is
# copied next to a fake tests station, a fake commit station and a fake cook that only record what they were asked. No AI, no network,
# no git. Run by the kitchen tests station on every order (it globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1.
$ErrorActionPreference = 'Stop'
$repair = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\repair.ps1')).Path
$d = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-repair-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$st = Join-Path $d 'stations'; $kr = Join-Path $d 'kroot'; $wt = Join-Path $kr 'worktrees\J1'
New-Item -ItemType Directory -Force -Path $st, (Join-Path $wt '.kitchen') | Out-Null
Copy-Item -LiteralPath $repair -Destination (Join-Path $st 'repair.ps1')
Set-Content -LiteralPath (Join-Path $st 'commit.ps1') -Value 'exit 0'
# the fake tests station: logs how it was called; mode.txt says whether the failed suite is fixed (green), still broken (red), or gone
Set-Content -LiteralPath (Join-Path $st 'tests.ps1') -Value @'
param([switch]$Soft, [switch]$Impacted, [string[]]$Only = @())
$kr = $env:BRAIN_KITCHEN; $txt = Join-Path $kr "worktrees\$env:KITCHEN_JOB\.kitchen\TESTS.txt"; $mode = (Get-Content (Join-Path $kr 'mode.txt') -Raw).Trim()
$call = if ($Only.Count) { 'only=' + ($Only -join ',') } elseif ($Impacted) { 'impacted' } else { 'full' }
Add-Content -LiteralPath (Join-Path $kr 'calls.txt') -Value $call
if ($Only.Count -and $mode -eq 'gone') { 'tests: no suites match tests\Test-*.ps1'; exit 1 }
$body = if ($Only.Count -and $mode -eq 'red') { "FAIL  Test-A  0 passed, 1 failed (1s)`n      FAIL: still broken`nFAILED: Test-A" }
    elseif ($Only.Count) { "PASS  Test-A  1 passed, 0 failed (1s)`nALL PASS" }
    elseif ($Impacted) { "PASS  Test-A  1 passed, 0 failed (1s)`n-     Test-B  not run (not impacted)`nPARTIAL PASS: 1 of 2 suites" }
    else { "PASS  Test-A  1 passed, 0 failed (1s)`nPASS  Test-B  1 passed, 0 failed (1s)`nALL PASS" }
Set-Content -LiteralPath $txt -Value $body
"tests: $(($body -split "`n")[-1])"; exit 0
'@
$fakeCook = Join-Path $d 'cook.ps1'; Set-Content -LiteralPath $fakeCook -Value 'param([Parameter(ValueFromRemainingArguments)]$rest) exit 0'
$red = "PASS  Test-B  1 passed, 0 failed (1s)`nFAIL  Test-A  0 passed, 1 failed (1s)`n      FAIL: broken`nFAILED: Test-A"
function Run-Repair([string]$Mode, [int]$Rounds = 1) {
    Set-Content -LiteralPath (Join-Path $kr 'mode.txt') -Value $Mode
    Set-Content -LiteralPath (Join-Path $wt '.kitchen\TESTS.txt') -Value $red
    Remove-Item -LiteralPath (Join-Path $kr 'calls.txt') -Force -ErrorAction SilentlyContinue
    $sv = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB; a = $env:KITCHEN_AGENT_STEP; t = $env:KITCHEN_TIMEOUT }
    try {
        $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_JOB = 'J1'; $env:KITCHEN_AGENT_STEP = $fakeCook; $env:KITCHEN_TIMEOUT = $null
        $o = & pwsh -NoProfile -File (Join-Path $st 'repair.ps1') -Rounds $Rounds 2>&1 | Out-String; $c = $LASTEXITCODE
    } finally { $env:BRAIN_KITCHEN = $sv.k; $env:KITCHEN_JOB = $sv.j; $env:KITCHEN_AGENT_STEP = $sv.a; $env:KITCHEN_TIMEOUT = $sv.t }
    @{ out = $o; code = $c; calls = @(Get-Content -LiteralPath (Join-Path $kr 'calls.txt') -ErrorAction SilentlyContinue) }
}
try {
    $r = Run-Repair 'red'
    Check 'RepairStillRed_RunsOnlyFailedSuite' (($r.calls -join '|') -eq 'only=Test-A' -and $r.code -eq 1 -and $r.out -match 'still fail; no full run' -and $r.out -match 'still failing after the repair rounds')
    $r = Run-Repair 'red' 2
    Check 'RepairStillRed_TwoRounds_TwoSmallRunsNoFullRun' (($r.calls -join '|') -eq 'only=Test-A|only=Test-A' -and $r.code -eq 1)
    $r = Run-Repair 'green'
    Check 'RepairGreen_ThenFullRun' (($r.calls -join '|') -eq 'only=Test-A|impacted|full' -and $r.code -eq 0 -and $r.out -match 'fixed in round 1' -and $r.out -match 'tests: ALL PASS')
    # the failed suite was renamed or deleted by the fix: the small run writes nothing, so the impacted and full runs decide
    $r = Run-Repair 'gone'
    Check 'RepairFailedSuiteGone_GoesOnToFullRun' (($r.calls -join '|') -eq 'only=Test-A|impacted|full' -and $r.code -eq 0)
} finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "Repair tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
