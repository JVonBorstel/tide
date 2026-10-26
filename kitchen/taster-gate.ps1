# The taster override (Watch plan step 1): a red final tests run beats the taster's SHIP; functions only (Get-TasterGate).
# Called by kitchen/stations/pr.ps1 before anything leaves the PC (and before a private order merges locally); tests/Test-WatchGates.ps1.
# The verdict comes from the kitchen's own records, never the worktree: <kitchen>\results\<job>.tests.json (written by the tests station
# for the exact commit it tested) and the taster's run log <kitchen>\run\<job>-s<i>-a<n>.log (its last "VERDICT: SHIP|REWORK" line).
# Red means: no record, a last line other than ALL PASS, or a record for a different commit than the branch tip (code changed after the
# tests ran). An order with no tests step (a recipe that never runs tests) is not gated, and says so.

function Get-TasterVerdict([string]$Kroot, [string]$Job, $JobObj) {
    $ci = -1; $steps = @($JobObj.steps)
    for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i].args -and [string]$steps[$i].args.Role -eq 'check') { $ci = $i } }
    if ($ci -lt 0) { return '' }
    $log = Get-ChildItem -LiteralPath (Join-Path $Kroot 'run') -Filter "$Job-s$ci-a*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $log) { return '' }
    $v = @(Select-String -LiteralPath $log.FullName -Pattern '^\s*VERDICT: (SHIP|REWORK)' | Select-Object -Last 1)
    if ($v.Count) { return $v[0].Matches[0].Groups[1].Value }
    ''
}

# returns @{ block = $true|$false; say = '<one plain line>' }
function Get-TasterGate([string]$Kroot, [string]$Job, $JobObj, [string]$Repo) {
    $hasTests = @(@($JobObj.steps) | Where-Object { $_ -and ([string]$_.station -eq 'tests' -or [string]$_.script -match '(^|[\\/])tests\.ps1$') }).Count
    if (-not $hasTests) { return @{ block = $false; say = 'this order has no tests step; the test gate does not apply' } }
    $verdict = Get-TasterVerdict $Kroot $Job $JobObj
    $tr = $null; try { $tr = Get-Content -LiteralPath (Join-Path $Kroot "results\$Job.tests.json") -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
    $tip = [string](& git -C $Repo rev-parse --verify --quiet "refs/heads/kitchen/$Job^{commit}" 2>$null)
    $red = if (-not $tr) { 'no record of a tests run' }
        elseif ([string]$tr.final -ne 'ALL PASS') { "final tests run: $([string]$tr.final)" }
        elseif ($tip -and [string]$tr.sha -ne $tip.Trim()) { 'the code changed after the last tests run' }
        else { '' }
    if (-not $red) { return @{ block = $false; say = "tests pass on this commit (ALL PASS)$(if ($verdict) { "; the taster said $verdict" })" } }
    $say = if ($verdict -eq 'SHIP') { "tests are red; the taster's SHIP is overridden ($red)" } else { "tests are red; nothing goes further ($red)" }
    @{ block = $true; say = $say }
}
