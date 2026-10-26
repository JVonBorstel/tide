# Tests for kitchen/backoff-lib.ps1 (TD-EH-07 the Stop-work order stops flapping, TD-EH-08 real back-off): pure functions with a fake clock
# and a fixed random draw, so nothing sleeps; plus the settings written in kitchen.json and the push words of the "lifted" note (notify.ps1 test log).
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
. (Join-Path $kd 'backoff-lib.ps1')
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$T0 = [DateTime]::new(2026, 10, 23, 8, 0, 0, [DateTimeKind]::Utc)
function At([double]$sec) { $T0.AddSeconds($sec) }
# outcomes {ts, job, fail}: $pattern is a string of F (failed) and o (passed), one per $step seconds, ending $endSec after T0
function Outcomes([string]$pattern, [double]$endSec, [double]$step = 10, [string]$prefix = 'J') {
    $n = $pattern.Length
    @(for ($i = 0; $i -lt $n; $i++) { @{ ts = ConvertTo-BackoffIso (At ($endSec - ($n - 1 - $i) * $step)); job = "$prefix$($i + 1)"; fail = $pattern[$i] -ceq 'F' } })
}
function O([double]$sec, [string]$job, [bool]$fail) { @{ ts = ConvertTo-BackoffIso (At $sec); job = $job; fail = $fail } }
$cfg = Get-BreakerSettings $null
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-backoff-' + [guid]::NewGuid().ToString('N'))
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'BRAIN_NTFY_TOPIC', 'KITCHEN_NOTIFY_LOG', 'KITCHEN_NOTIFY_FAIL') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
try {
    # ---- settings: the defaults are the ones written in kitchen.json ----
    $kj = Get-Content (Join-Path $kd 'kitchen.json') -Raw | ConvertFrom-Json -AsHashtable
    $fromFile = Get-BreakerSettings $kj.breaker
    Check 'settings: kitchen.json writes every Stop-work order setting, equal to the defaults' (@($script:BreakerDefaults.Keys | Where-Object { $null -eq $kj.breaker[$_] -or [double]$kj.breaker[$_] -ne [double]$cfg[$_] }).Count -eq 0)
    Check 'settings: the Stop-work order opens on the same rule as before (10, 6, 0.5) and stays open 5 min' ($fromFile.window -eq 10 -and $fromFile.min -eq 6 -and $fromFile.rate -eq 0.5 -and $fromFile.coolSec -eq 300 -and $fromFile.closeRate -lt $fromFile.rate)
    $bf = Get-BackoffSettings $kj.backoff; $bd = Get-BackoffSettings $null
    Check 'settings: kitchen.json writes the back-off schedule, equal to the defaults' (($bf | ConvertTo-Json -Depth 4 -Compress) -eq ($bd | ConvertTo-Json -Depth 4 -Compress) -and $kj.backoff.code.floorSec -eq 30 -and $kj.backoff.wait.floorSec -eq 300)
    Check 'settings: the old 2-second backoffBaseSec key is gone from kitchen.json' ($null -eq $kj.backoffBaseSec)
    $bad = Get-BackoffSettings @{ jitter = 'x'; code = @{ floorSec = 'soon' } }
    Check 'settings: a broken value keeps the default' ($bad.jitter -eq 0.2 -and $bad.code.floorSec -eq 30)
    $f1 = Get-BackoffSettings $null 1
    Check 'settings: -BackoffBaseSec (demos, tests) sets both floors in seconds' ($f1.code.floorSec -eq 1 -and $f1.wait.floorSec -eq 1 -and (Get-BackoffDelay 1 'code' $f1 0.5).sec -eq 1 -and (Get-BackoffDelay 2 'wait' $f1 0.5).sec -eq 4)

    # ---- classification: by the failure reason the Yard records (kind + detail) ----
    $table = @(
        @('fail', 'exit 1: ci-wait: no CI check reported on PR #12 in 30 minutes since the push', 'wait'),
        @('fail', 'exit 1: ci-wait: could not reach GitHub to read PR #12 (HTTP 502)', 'wait'),
        @('fail', 'exit 1: agent-step: gemini failed: Gemini ended with ERROR: API error (attempt 3): UNAVAILABLE (code 503)', 'wait'),
        @('fail', 'exit 1: agent-step: gemini failed: Gemini ended with ERROR: The stream was interrupted. Please continue', 'wait'),
        @('fail', 'exit 1: pr: gh: API rate limit exceeded for user', 'wait'),
        @('fail', 'exit 1: freshen: fatal: unable to access github.com: Could not resolve host: github.com', 'wait'),
        @('fail', 'cloud hiccup x6: claude usage limit reached', 'wait'),
        @('fail', 'exit 1: ci-wait: CI failed on PR #12: ci / Phase 0 acceptance tests (windows)', 'code'),
        @('fail', 'exit 1: verify: FAILED - broke main (chrome did not open its debugging port; network)', 'code'),
        @('fail', 'exit 1: tests: FAILED: Test-KitchenSupervisor', 'code'),
        @('fail', 'exit 1: freshen: CONFLICT merging main into kitchen/J12 in: kitchen/kitchen.ps1', 'code'),
        @('fail', 'exit 1: roadmap-item: REFUSED: B-12 is blocked by B-11 (not merged yet)', 'code'),
        @('fail', 'exit 1: repair: still failing after the repair rounds', 'code'),
        @('fail', "exit 1: kitchen-step: The process cannot access the file 'C:\x\run\J1-s1-a0.log'", 'code'),
        @('fail', 'exit 1', 'code'),
        @('timeout', 'ran 301s (limit 300s)', 'code'),
        @('hung', 'no heartbeat for 950s (limit 900s)', 'code'),
        @('crash', 'worker died without an exit code', 'code'),
        @('memcap', 'used 2100 MB (limit 2000 MB)', 'code'),
        @('taster', "expected 'VERDICT: SHIP' in the output; not found", 'code')
    )
    $wrong = @($table | Where-Object { (Get-FailureClass $_[0] $_[1]) -ne $_[2] } | ForEach-Object { "$($_[0]): $($_[1]) -> $(Get-FailureClass $_[0] $_[1])" })
    Check "classification: CI not reporting, network, GitHub/provider and rate limits wait longer; verdicts and the step's own failures do not ($($wrong -join ' | '))" ($wrong.Count -eq 0)
    Check 'classification: a lower-case "failed" (a cook adapter line) is not a verdict' ((Get-FailureClass 'fail' 'gemini failed: HTTP 429 too many requests') -eq 'wait')

    # ---- back-off schedule per class (no jitter: draw 0.5) ----
    $code = @(1..5 | ForEach-Object { (Get-BackoffDelay $_ 'code' $bd 0.5).sec })
    $wait = @(1..4 | ForEach-Object { (Get-BackoffDelay $_ 'wait' $bd 0.5).sec })
    Check "back-off: code failures wait 30 s, 2 min, 8 min, 30 min, then stay at the 30-min cap ($($code -join ', '))" (($code -join ',') -eq '30,120,480,1800,1800')
    Check "back-off: waits on CI, the network or GitHub wait 5, 20, 60 min, then stay at the 60-min cap ($($wait -join ', '))" (($wait -join ',') -eq '300,1200,3600,3600')
    Check 'back-off: an external wait is always longer than a code failure at the same retry' (@(1..4 | Where-Object { (Get-BackoffDelay $_ 'wait' $bd 0.5).sec -le (Get-BackoffDelay $_ 'code' $bd 0.5).sec }).Count -eq 0)
    Check 'back-off: an unknown class is a code failure' ((Get-BackoffDelay 1 'other' $bd 0.5).sec -eq 30)
    Check 'back-off: the words say "waiting N min before retry", rounded up' ((Get-BackoffDelay 1 'code' $bd 0.5).text -eq 'waiting 1 min before retry' -and (Get-BackoffDelay 3 'code' $bd 0.5).text -eq 'waiting 8 min before retry' -and (Get-BackoffDelay 2 'wait' $bd 0.5).text -eq 'waiting 20 min before retry' -and (Get-BackoffDelay 3 'code' $bd 0.5).min -eq 8)
    Check 'back-off: the old schedule (2 s, then 4 s) is gone: the first retry waits at least 24 s' (@(0.0, 0.25, 0.5, 0.999) | ForEach-Object { (Get-BackoffDelay 1 'code' $bd $_).sec } | Measure-Object -Minimum).Minimum -ge 24

    # ---- jitter bounds: +-20 %, never under the floor, never over the cap ----
    $out = @()
    foreach ($cls in 'code', 'wait') { foreach ($n in 1..5) { foreach ($r in @(0..100 | ForEach-Object { $_ / 100 })) {
        $d = Get-BackoffDelay $n $cls $bd $r; $p = $bd[$cls]
        $lo = [math]::Max($p.floorSec, $d.baseSec * 0.8) - 0.05; $hi = [math]::Min($p.capSec, $d.baseSec * 1.2) + 0.05
        if ($d.sec -lt $lo -or $d.sec -gt $hi) { $out += "$cls/$n/$r -> $($d.sec)" } } } }
    Check "jitter: every draw lands within +-20 % of the schedule, inside floor and cap ($($out.Count) out)" ($out.Count -eq 0)
    Check 'jitter: the draw moves the wait (2 min retry: 96 s to 144 s)' ((Get-BackoffDelay 2 'code' $bd 0.0).sec -eq 96 -and (Get-BackoffDelay 2 'code' $bd 1.0).sec -eq 144)
    Check 'jitter: the first retry never goes under its floor' ((Get-BackoffDelay 1 'code' $bd 0.0).sec -eq 30 -and (Get-BackoffDelay 1 'wait' $bd 0.0).sec -eq 300)
    Check 'jitter: the cap holds at the top draw' ((Get-BackoffDelay 4 'code' $bd 1.0).sec -eq 1800 -and (Get-BackoffDelay 3 'wait' $bd 1.0).sec -eq 3600)
    Check 'jitter: a draw outside [0, 1] is clamped' ((Get-BackoffDelay 2 'code' $bd 5).sec -eq 144 -and (Get-BackoffDelay 2 'code' $bd -3).sec -eq 96)

    # ---- the Stop-work order: opens on the same rule ----
    $st = New-BreakerState
    $r = Update-BreakerState $st (Outcomes 'oooooFFFFF' 0) (At 0) $cfg
    Check 'stop-work: 5 of the last 10 failed opens it (rate 0.5, as before), with an alert' ($r.did -eq 'open' -and $r.open -and $r.alert)
    $r0 = Update-BreakerState (New-BreakerState) (Outcomes 'ooooooFFFF' 0) (At 0) $cfg
    Check 'stop-work: 4 of 10 failed does not open' ($r0.did -eq '' -and -not $r0.open -and -not $r0.st.tripped)
    $r1 = Update-BreakerState (New-BreakerState) (Outcomes 'FFFFF' 0) (At 0) $cfg
    Check 'stop-work: fewer than 6 outcomes never open it' (-not $r1.st.tripped)
    Check 'stop-work: the input state is never changed' (-not $st.tripped -and $st.n -eq 0)

    # ---- no flapping: the 10-23 pattern (60 s cool-off, then one pass closed it, the next failure re-opened it) ----
    $alerts = 0; $events = [Collections.Generic.List[string]]::new()
    $outs = [Collections.Generic.List[object]]::new(); foreach ($o in (Outcomes 'ooooFFFFFF' 0)) { $outs.Add($o) }
    function Look([double]$sec, [bool]$live = $false) {
        $script:r = Update-BreakerState $script:st $script:outs.ToArray() (At $sec) $script:cfg $live
        $script:st = $script:r.st; if ($script:r.alert) { $script:alerts++ }; if ($script:r.did) { $script:events.Add("$($script:r.did)@$sec") }; $script:r
    }
    $st = New-BreakerState
    $null = Look 0
    Check 'no flap: it opens once, with one HIGH alert' ($st.tripped -and $alerts -eq 1 -and $st.coolSec -eq 300)
    $outs.Add((O 50 'J20' $false))
    Check 'no flap: still open 60 s later, even after a pass (the old rule closed here)' ((Look 60).open -and $st.tripped)
    Check 'no flap: still open after 4 min' ((Look 240).open)
    $l = Look 301
    Check 'no flap: after the cool-down, failures are not clearly down (5 of 10): it stays on and lets one trial step start' ($st.tripped -and -not $l.open -and $l.probe -and $l.did -eq '')
    $st.probe = @{ job = 'J30'; at = ConvertTo-BackoffIso (At 302) }   # (the Walkround records the trial step it started)
    Check 'no flap: while the trial step runs, nothing else starts' ((Look 330 $true).open -and -not $r.probe)
    $outs.Add((O 340 'J21' $false))   # another order passing is not the trial
    Check 'no flap: a pass by another order does not close it at 50 %' ((Look 345 $true).open -and $st.tripped)
    $outs.Add((O 400 'J30' $false))
    $l = Look 410
    Check 'no flap: the trial step passed: it closes, with one closed note' ($l.did -eq 'closed' -and -not $st.tripped -and $st.closeWhy -eq 'probe' -and $l.why -match 'trial step passed')
    $outs.Add((O 420 'J22' $true))
    Check 'no flap: one failure right after closing does not re-open it (the old rule re-opened here)' (-not (Look 425).open -and -not $st.tripped)
    foreach ($i in 1..4) { $outs.Add((O (430 + $i) "J4$i" ($i % 2 -eq 0))) }
    Check 'no flap: 5 outcomes since closing (3 failed) are still under the minimum of 6' (-not (Look 440).st.tripped)
    Check "no flap: the whole run made one alert and one close ($($events -join ', '))" ($alerts -eq 1 -and @($events | Where-Object { $_ -like 'closed@*' }).Count -eq 1 -and @($events | Where-Object { $_ -like 'open@*' }).Count -eq 1)

    # ---- re-open soon after closing: a new episode, its own single alert, and a longer cool-down ----
    $outs.Add((O 450 'J50' $true))   # 6 since closing, 4 failed
    $l = Look 450
    Check 're-open: 6 outcomes since closing with 4 failed opens a second episode, with its one alert' ($l.did -eq 'open' -and $st.n -eq 2 -and $alerts -eq 2)
    Check 're-open: within 30 min of closing, the cool-down doubles (10 min)' ($st.coolSec -eq 600 -and (ConvertTo-BackoffUtc $st.openUntil) -eq (At 1050))
    Check 're-open: still open at 9 min' ((Look 990).open)

    # ---- a failed trial step keeps it on: same episode, no new alert, the cool-down grows to the 30-min cap ----
    $null = Look 1051; $st.probe = @{ job = 'J60'; at = ConvertTo-BackoffIso (At 1052) }
    $outs.Add((O 1100 'J60' $true)); $l = Look 1110
    Check 'trial failed: it re-opens for 20 min, with no new alert' ($l.did -eq 'reopen' -and $l.open -and $st.coolSec -eq 1200 -and $alerts -eq 2 -and $st.n -eq 2 -and $st.reopens -eq 1)
    $null = Look 2311; $st.probe = @{ job = 'J61'; at = ConvertTo-BackoffIso (At 2312) }
    $outs.Add((O 2400 'J61' $true)); $l = Look 2410
    Check 'trial failed again: the cool-down stops at the 30-min cap' ($l.did -eq 'reopen' -and $st.coolSec -eq 1800 -and $alerts -eq 2)

    # ---- a trial step that ends without an outcome (a wait, a hold, a kill) frees the slot for another ----
    $null = Look 4211; $st.probe = @{ job = 'J62'; at = ConvertTo-BackoffIso (At 4212) }
    $l = Look 4300 $false
    Check 'trial lost: no outcome and no longer running: another trial may start' ($l.did -eq 'probe-lost' -and $l.probe -and -not $l.open -and $null -eq $st.probe -and $st.tripped)

    # ---- closing by the failure rate: clearly below the threshold (under 30 %) ----
    foreach ($i in 1..8) { $outs.Add((O (4400 + $i) "J7$i" $false)) }   # window now: 2 failed of 10
    $l = Look 4420
    Check 'close by rate: 2 of 10 failed (20 %) closes it, with one closed note' ($l.did -eq 'closed' -and $st.closeWhy -eq 'rate' -and $l.why -match '20')
    $st2 = @{}; foreach ($k in $st.Keys) { $st2[$k] = $st[$k] }
    $rs = Update-BreakerState $st2 (Outcomes 'oooooo' 4430) (At 4430) $cfg
    $rs = Update-BreakerState $rs.st (Outcomes 'FFFFFFFFF' (4430 + 1801)) (At (4430 + 1801)) $cfg
    Check 're-open after 30 min of calm: the cool-down starts again at 5 min' ($rs.did -eq 'open' -and $rs.st.coolSec -eq 300 -and $rs.alert)
    $x = Update-BreakerState @{ tripped = $true; n = 1; alerted = 1; openUntil = (ConvertTo-BackoffIso (At -1)); coolSec = 300 } (Outcomes 'oooooooFFF' 0) (At 0) $cfg
    Check 'close by rate: 3 of 10 (30 %) is not clearly below: it stays on and waits for a trial step' ($x.did -eq '' -and $x.st.tripped -and $x.probe)

    # ---- the first run after this change: an old tripped breaker is one episode already announced ----
    $old = Get-BreakerEpisode @{ breakerTripped = $true; breakerOpenUntil = (ConvertTo-BackoffIso (At 60)) } $cfg
    $ro = Update-BreakerState $old (Outcomes 'FFFFFFFFFF' 0) (At 30) $cfg
    Check 'upgrade: an old open breaker carries on as episode 1, open until its old time, no second alert' ($old.tripped -and $old.alerted -eq 1 -and $ro.open -and -not $ro.alert -and $ro.did -eq '')
    $none = Get-BreakerEpisode @{} $cfg
    Check 'upgrade: no old state is a closed Stop-work order' (-not $none.tripped -and $none.n -eq 0)
    $kept = Get-BreakerEpisode @{ breakerEpisode = @{ tripped = $true; n = 4; alerted = 4; coolSec = 600 } } $cfg
    Check 'upgrade: a saved episode is read back as it was' ($kept.tripped -and $kept.n -eq 4 -and $kept.coolSec -eq 600)

    # ---- times written by the Yard come back as DateTime (ConvertFrom-Json): both forms read the same ----
    $asDate = Update-BreakerState @{ tripped = $true; n = 1; alerted = 1; openUntil = (At 600); coolSec = 300 } @() (At 300) $cfg
    Check 'times: an openUntil read back as a DateTime works like the ISO text' ($asDate.open)

    # ---- the push words: one "lifted" note, and the open alert still reads as a pause ----
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $env:BRAIN_KITCHEN = $tmp; $env:BRAIN_NTFY_TOPIC = 'backofftest' + ([guid]::NewGuid().ToString('N').Substring(0, 8)); $env:KITCHEN_NOTIFY_LOG = Join-Path $tmp 'notify.log'; $env:KITCHEN_NOTIFY_FAIL = $null
    $said = foreach ($t in 'Stop-work order: 60% of the last 10 steps failed. No new work starts for 5 min; then one trial step runs first.', 'Stop-work order lifted after 12 min: a trial step passed (J30). New work starts again.') {
        & pwsh -NoProfile -File (Join-Path $kd 'notify.ps1') -Level INFO -Text $t | Out-Null; (Get-Content $env:KITCHEN_NOTIFY_LOG | Select-Object -Last 1) -replace '^INFO\|[^|]+\|', '' }
    Check 'push: the open alert still says the work paused' ($said[0] -eq 'Kitchen: the kitchen paused new work (many failures)')
    Check 'push: the lifted note says new work starts again, never "paused"' ($said[1] -eq 'Kitchen: new work starts again (the Stop-work order was lifted)')
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Output "Backoff tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
