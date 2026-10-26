# Tests for the tick drain and wake (TARGET W2, J252): a finished step touches run\WAKE and the tick takes another pass at once, so
# chained steps run back to back inside one tick call; the drain stops at its time window and its pass cap; no WAKE is one pass as before;
# a second tick touches WAKE and steps aside. Uses 1-second demo steps in private kitchens under TEMP; self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path; $k = Join-Path $kd 'kitchen.ps1'; $w = Join-Path $kd 'demo-worker.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-drain-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$vars = 'BRAIN_KITCHEN', 'KITCHEN_TICK_LINGER_SEC', 'KITCHEN_TICK_WINDOW_SEC', 'KITCHEN_TICK_MAX_PASSES', 'KITCHEN_TICK_WAIT_SEC', 'KITCHEN_TICK_FROM', 'KITCHEN_AGY_EXE', 'BRAIN_NTFY_TOPIC', 'BRAIN_AGENT_DEPTH', 'KITCHEN_JOB'
$saved = @{}; foreach ($v in $vars) { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
# a kitchen whose chores run elsewhere (supervisor.json says the Kitchen-Chores task just ran: the tick is only its passes)
function Kitchen([string]$name) {
    $d = "$root-$name"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    @{ choresTaskAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $d 'supervisor.json')
    $env:BRAIN_KITCHEN = $d; foreach ($v in 'KITCHEN_TICK_LINGER_SEC', 'KITCHEN_TICK_WINDOW_SEC', 'KITCHEN_TICK_MAX_PASSES', 'KITCHEN_TICK_FROM') { [Environment]::SetEnvironmentVariable($v, $null) }
    $d
}
function Chain([int]$n, [int]$sec = 1) {
    $spec = Join-Path $env:BRAIN_KITCHEN 'spec.json'
    @{ name = "chain of $n"; steps = @(1..$n | ForEach-Object { @{ script = $w; args = @{ Behavior = 'ok'; Seconds = $sec }; timeoutSec = 60; retries = 0 } }) } | ConvertTo-Json -Depth 6 | Set-Content $spec
    & $k add -SpecPath $spec | Out-Null
}
function Events([string]$d) { @(Get-Content (Join-Path $d 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
function Drained([string]$d) { @(Events $d | Where-Object type -eq 'tick.drained') }
function J1([string]$d) { Get-Content (Join-Path $d 'jobs\J1.json') -Raw | ConvertFrom-Json }
function Utc($v) { if ($v -is [DateTime]) { $v.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } }
# a tick in its own process, started now with the environment as it is now (the four cases run side by side: each kitchen is private)
function StartTick { Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-File', "`"$k`"", 'tick', '-Quiet' -PassThru -WindowStyle Hidden }
function Sec($p) { ($p.ExitTime - $p.StartTime).TotalSeconds }
try {
    $env:KITCHEN_AGY_EXE = 'off'; $env:BRAIN_NTFY_TOPIC = $null; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null
    # 1. three chained 1 s steps in one tick call (the tick waits for wakes up to 30 s here; 45 s for the scheduled tick). 30 s, not 12:
    # with this process held to 2 cores (start /affinity 3, as a 2-core CI runner) the steps started 4.7 s and 9.7 s in, so 12 s held 2 of 3
    $d1 = Kitchen 'chain'; Chain 3; $env:KITCHEN_TICK_LINGER_SEC = '30'; $p1 = StartTick
    # 2. the drain stops at its window (45 s): the tick "started" 30 s ago (KITCHEN_TICK_FROM), so it stops ~15 s in, mid-chain. 15 s of
    # runway, not 5: it failed once on a 2-core CI runner, most likely because pwsh start-up plus the first step took over 5 s next to the
    # other three ticks (one pass, so no tick.drained; the failing clause was not logged then, the detail below says it now). 20 steps
    # of 1 s cannot finish in 15 s (20 s of sleep alone), and the pass cap is lifted to 100 so only the window can stop it
    $d2 = Kitchen 'window'; Chain 20 1; $env:KITCHEN_TICK_LINGER_SEC = '60'; $env:KITCHEN_TICK_MAX_PASSES = '100'; $env:KITCHEN_TICK_FROM = [DateTime]::UtcNow.AddSeconds(-30).ToString('o'); $p2 = StartTick
    # 3. the drain stops at its pass cap (10; 3 here)
    $d3 = Kitchen 'cap'; Chain 6 0; $env:KITCHEN_TICK_LINGER_SEC = '30'; $env:KITCHEN_TICK_MAX_PASSES = '3'; $p3 = StartTick
    # 4. no WAKE: one pass as before (a test kitchen does not wait for wakes)
    $d4 = Kitchen 'once'; Chain 1 3; $p4 = StartTick
    foreach ($p in $p1, $p2, $p3, $p4) { if (-not $p.WaitForExit(60000)) { $p.Kill($true) } }

    $dr = @(Drained $d1); $j1 = J1 $d1
    $starts = @(Events $d1 | Where-Object { $_.type -eq 'step.started' -and $_.job -eq 'J1' })
    $at1 = (@($starts | ForEach-Object { '{0:N1}' -f ((Utc $_.ts) - $p1.StartTime.ToUniversalTime()).TotalSeconds }) -join ', ')
    Check "ThreeChained1sSteps_FinishInsideOneTickCall: done after one tick ($('{0:N1}' -f (Sec $p1)) s; J1 $($j1.status) at step $($j1.cursor) of 3, steps started at $at1 s; passes $(@($dr.passes) -join ',')), one tick.drained with the passes" ($j1.status -eq 'done' -and $dr.Count -eq 1 -and $dr[0].passes -ge 4)
    # ExitFile_WakesTick_Under5s: from each step's .exit (written by kitchen-step.ps1, which then touches WAKE) to the next step's start
    $lags = @(foreach ($s in 0, 1) { $ex = Get-Item (Join-Path $d1 "run\J1-s$s-a0.exit") -ErrorAction SilentlyContinue; if ($ex -and $starts.Count -gt $s + 1) { ((Utc $starts[$s + 1].ts) - $ex.LastWriteTimeUtc).TotalSeconds } })
    Check "ExitFile_WakesTick_Under5s: next step started $(($lags | ForEach-Object { '{0:N1}' -f $_ }) -join ' s, ') s after the .exit" ($lags.Count -eq 2 -and @($lags | Where-Object { $_ -ge 0 -and $_ -lt 5 }).Count -eq 2)
    Check 'the wait for wakes is not counted as a slow tick' (-not @(Events $d1 | Where-Object type -eq 'tick.slow').Count)
    $dr = @(Drained $d2); $j2 = J1 $d2
    # the window closes 15 s after the start; 25 s leaves 10 s for the pass under way then (a 1-s step) and the tick's own exit
    Check "DrainStopsAt45s: stopped by time ($('{0:N1}' -f (Sec $p2)) s, under 25 s; $($dr.Count) tick.drained, passes $(@($dr.passes) -join ','), stop '$(@($dr.stop) -join ',')'; J1 $($j2.status) at step $($j2.cursor) of 20), the chain not finished" ($dr.Count -eq 1 -and $dr[0].stop -eq 'time' -and (Sec $p2) -lt 25 -and $j2.status -ne 'done')
    $dr = @(Drained $d3)
    Check "DrainStopsAtPassCap: 3 passes then stop ($('{0:N1}' -f (Sec $p3)) s), the chain not finished" ($dr.Count -eq 1 -and $dr[0].passes -eq 3 -and $dr[0].stop -eq 'passes' -and (J1 $d3).cursor -lt 6)
    Check "NoWake_OnePass: one pass ($('{0:N1}' -f (Sec $p4)) s), no tick.drained, the step left running" (-not @(Drained $d4).Count -and (J1 $d4).status -eq 'running')
    foreach ($d in $d2, $d3, $d4) { $env:BRAIN_KITCHEN = $d; & $k kill -All | Out-Null }

    # 5. a second tick while one runs (here the test holds the tick lock, as a running tick does): it touches WAKE, so the running one
    # takes a pass for it at once (case 1 shows a WAKE pass), and steps aside (after 1 s here instead of 10)
    $d = Kitchen 'aside'
    $sha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($d)).ToLowerInvariant()))) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    $held = [Threading.Mutex]::new($false, "Global\brain-kitchen-tick-$sha"); [void]$held.WaitOne(0)
    try { $env:KITCHEN_TICK_WAIT_SEC = '1'; $o = & pwsh -NoProfile -File $k tick 2>&1 | Out-String } finally { $env:KITCHEN_TICK_WAIT_SEC = $null; $held.ReleaseMutex(); $held.Dispose() }
    Check 'SecondTick_StepsAside: says so, did no pass, and left run\WAKE for the running tick' ($o -match 'another tick is running; this one steps aside' -and (Test-Path (Join-Path $d 'run\WAKE')) -and -not (Test-Path (Join-Path $d 'events.jsonl')))
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } | ForEach-Object { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null }
    Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter ((Split-Path -Leaf $root) + '*') | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "TickDrain tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
