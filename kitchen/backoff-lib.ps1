# The Yard's two brakes as pure functions (no clock, no random draw, no files but the failure policy table): the Stop-work order's hysteresis (TD-EH-07) and retry back-off (TD-EH-08).
# Dot-sourced by kitchen/kitchen.ps1 (the Walkround passes its own clock and random draw); tests/Test-Backoff.ps1 drives every rule with a fake clock.
# Settings: kitchen.json "breaker" and "backoff" (defaults below, also written there). Times are kept as ISO strings ('o'), read back in UTC.
#
# Stop-work order (code: breaker), one state per Yard in supervisor.json breakerEpisode:
#   closed    -> opens on the old rule: of the last <window> step outcomes since it last closed, at least <min>, and <rate> or more failed.
#                One HIGH alert per open episode. Opening again within <reopenWithinSec> of closing starts from the last cool-down x <coolGrowth>.
#   open      -> no new work for <coolSec> (at least a few minutes), growing x <coolGrowth> per re-open, never past <coolMaxSec>.
#   cooled    -> closes when the window's failure rate is under <closeRate> (clearly below <rate>), or when one trial step (the probe) passes.
#                Until then one trial step at a time may start; a failed trial re-opens it (same episode: no new alert, a longer cool-down).
#   closing   -> one "closed" note. Only outcomes after the close count toward the next opening, so one old failure cannot re-open it.
# Back-off: a retry waits floor x factor^(attempt-1), capped, with +-jitter (never under the floor, never over the cap). Failures that wait on
# something outside the Yard (CI not reporting, the network, GitHub's API, rate limits) use the longer "wait" schedule; the rest use "code".

$script:BreakerDefaults = [ordered]@{ window = 10; min = 6; rate = 0.5; coolSec = 300; coolMaxSec = 1800; coolGrowth = 2; reopenWithinSec = 1800; closeRate = 0.3 }
$script:BackoffDefaults = [ordered]@{ jitter = 0.2; code = [ordered]@{ floorSec = 30; factor = 4; capSec = 1800 }; wait = [ordered]@{ floorSec = 300; factor = 4; capSec = 3600 } }

function ConvertTo-BackoffUtc($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [DateTime]) { return $v.ToUniversalTime() }
    [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}
function ConvertTo-BackoffIso([DateTime]$d) { $d.ToUniversalTime().ToString('o') }

# kitchen.json "breaker" over the defaults (missing or non-numeric keys keep the default)
function Get-BreakerSettings($Config) {
    $s = @{}; foreach ($k in $script:BreakerDefaults.Keys) { $s[$k] = $script:BreakerDefaults[$k] }
    if ($Config -is [Collections.IDictionary]) { foreach ($k in @($script:BreakerDefaults.Keys)) { $v = $Config[$k]; if ($null -ne $v -and "$v" -match '^\d+(\.\d+)?$') { $s[$k] = [double]$v } } }
    $s.window = [int]$s.window; $s.min = [int]$s.min
    $s.coolMaxSec = [math]::Max([double]$s.coolMaxSec, [double]$s.coolSec); $s.coolGrowth = [math]::Max(1.0, [double]$s.coolGrowth)
    $s
}
# kitchen.json "backoff" over the defaults. -FloorSec (the -BackoffBaseSec parameter, for demos and tests) sets both floors in seconds.
function Get-BackoffSettings($Config, [int]$FloorSec = 0) {
    $s = @{ jitter = [double]$script:BackoffDefaults.jitter }
    if ($Config -is [Collections.IDictionary] -and "$($Config.jitter)" -match '^\d+(\.\d+)?$') { $s.jitter = [math]::Min(0.9, [double]$Config.jitter) }
    foreach ($c in 'code', 'wait') {
        $d = $script:BackoffDefaults[$c]; $x = if ($Config -is [Collections.IDictionary] -and $Config[$c] -is [Collections.IDictionary]) { $Config[$c] } else { @{} }
        $one = @{}; foreach ($k in $d.Keys) { $one[$k] = if ("$($x[$k])" -match '^\d+(\.\d+)?$') { [double]$x[$k] } else { [double]$d[$k] } }
        if ($FloorSec -gt 0) { $one.floorSec = [double]$FloorSec }
        $one.factor = [math]::Max(1.0, $one.factor); $one.capSec = [math]::Max($one.capSec, $one.floorSec)
        $s[$c] = $one
    }
    $s
}

# The back-off class of a failure, from what the Yard already records for it: the kind (fail, crash, timeout, memcap, logflood, hung,
# taster) and the detail line ("exit 1: <last log line>"). 'wait' = it waited on something outside the Yard (CI not reporting, the network,
# GitHub, a provider down, a rate limit or usage cap); 'code' = anything else. The signatures live in the one failure policy table
# (kitchen/failure-policy.json, read by failure-policy.ps1, task 32): each class says its back-off. A verdict (FAILED, STOPPED, REFUSED,
# CONFLICT, CI failed, broke main) matches first, so it is always 'code', even when its words mention GitHub or the network.
if (-not (Get-Command Get-FailureVerdict -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'failure-policy.ps1') }
function Get-FailureClass([string]$Kind, [string]$Detail) { (Get-FailureVerdict $Kind $Detail).backoff }

# "N min", rounded up (30 s reads "1 min"): the words every retry and wait line uses
function Format-WaitMinutes([double]$Sec) { '{0} min' -f [int][math]::Max(1, [math]::Ceiling($Sec / 60)) }

# How long retry number $Attempt (1 = the first retry) waits. $Rand is a draw in [0, 1): 0.5 = no jitter.
function Get-BackoffDelay([int]$Attempt, [string]$Class, $Settings, [double]$Rand) {
    $c = if ($Class -eq 'wait') { 'wait' } else { 'code' }; $p = $Settings[$c]
    $n = [math]::Max(1, $Attempt)
    $base = [math]::Min([double]$p.capSec, [double]$p.floorSec * [math]::Pow([double]$p.factor, $n - 1))
    $r = [math]::Min(1.0, [math]::Max(0.0, $Rand))
    $sec = $base * (1 + [double]$Settings.jitter * (2 * $r - 1))
    $sec = [math]::Round([math]::Min([double]$p.capSec, [math]::Max([double]$p.floorSec, $sec)), 1)
    @{ sec = $sec; baseSec = $base; class = $c; min = [int][math]::Max(1, [math]::Ceiling($sec / 60)); text = "waiting $(Format-WaitMinutes $sec) before retry" }
}

# ---- the Stop-work order ----
# the failure rate of the newest $Window outcomes ({ts, job, fail}, oldest first)
function Get-BreakerWindow([object[]]$Outcomes, [int]$Window) {
    $w = @($Outcomes | Select-Object -Last ([math]::Max(1, $Window)))
    $f = @($w | Where-Object { $_.fail }).Count
    @{ n = $w.Count; fails = $f; rate = $(if ($w.Count) { $f / $w.Count } else { 0.0 }) }
}
function New-BreakerState { @{ tripped = $false; n = 0; alerted = 0; openedAt = $null; openUntil = $null; coolSec = 0; reopens = 0; closedAt = $null; lastCoolSec = 0; probe = $null; closeWhy = '' } }
# supervisor.json's breakerEpisode, or (first run after this change) one made from the old breakerTripped / breakerOpenUntil keys
function Get-BreakerEpisode($Meta, $Cfg) {
    $st = New-BreakerState
    $e = $Meta.breakerEpisode
    if ($e -is [Collections.IDictionary]) { foreach ($k in @($e.Keys)) { $st[$k] = $e[$k] }; return $st }
    if ($Meta.breakerTripped) {   # tripped under the old rule: that episode was already announced
        $st.tripped = $true; $st.n = 1; $st.alerted = 1; $st.coolSec = [double]$Cfg.coolSec
        $st.openUntil = if ($Meta.breakerOpenUntil) { ConvertTo-BackoffIso (ConvertTo-BackoffUtc $Meta.breakerOpenUntil) } else { $null }
    }
    $st
}

# One Walkround's look. $State = the state (Get-BreakerEpisode), $Outcomes = step outcomes {ts, job, fail} oldest first, $Now = the clock,
# $ProbeLive = the trial step's order is still running it. Returns { st, did ('' | open | reopen | closed | probe-lost), alert (a new
# episode to announce), open (no new work), probe (one trial step may start), rate, n, why }. Never changes $State itself.
function Update-BreakerState($State, [object[]]$Outcomes, [DateTime]$Now, $Cfg, [bool]$ProbeLive = $false) {
    $st = @{}; foreach ($k in $State.Keys) { $st[$k] = $State[$k] }
    $all = @($Outcomes | Where-Object { $_ } | Sort-Object -Stable { ConvertTo-BackoffUtc $_.ts })
    $r = @{ st = $st; did = ''; alert = $false; open = $false; probe = $false; rate = 0.0; n = 0; why = '' }
    if (-not $st.tripped) {
        $since = ConvertTo-BackoffUtc $st.closedAt
        $w = Get-BreakerWindow @($all | Where-Object { -not $since -or (ConvertTo-BackoffUtc $_.ts) -gt $since }) $Cfg.window
        $r.rate = $w.rate; $r.n = $w.n
        if ($w.n -ge $Cfg.min -and $w.rate -ge $Cfg.rate) { Open-BreakerEpisode $r $Now $Cfg }
        return $r
    }
    $w = Get-BreakerWindow $all $Cfg.window; $r.rate = $w.rate; $r.n = $w.n
    $until = ConvertTo-BackoffUtc $st.openUntil
    if ($until -and $Now -lt $until) { $r.open = $true; return $r }
    if ($w.rate -lt $Cfg.closeRate) { Close-BreakerEpisode $r $Now ('the failure rate fell to {0:P0}' -f $w.rate) 'rate'; return $r }
    if ($st.probe) {
        $pAt = ConvertTo-BackoffUtc $st.probe.at
        $po = @($all | Where-Object { [string]$_.job -eq [string]$st.probe.job -and (ConvertTo-BackoffUtc $_.ts) -ge $pAt }) | Select-Object -First 1
        if ($po -and -not $po.fail) { Close-BreakerEpisode $r $Now "a trial step passed ($($st.probe.job))" 'probe'; return $r }
        if ($po) { Reopen-BreakerEpisode $r $Now $Cfg; return $r }
        if ($ProbeLive) { $r.open = $true; return $r }
        $st.probe = $null; $r.did = 'probe-lost'   # the trial order stopped without an outcome (a wait, a hold, a kill): another may try
    }
    $r.probe = $true
    $r
}
function Open-BreakerEpisode($r, [DateTime]$Now, $Cfg) {
    $st = $r.st; $cool = [double]$Cfg.coolSec
    $closed = ConvertTo-BackoffUtc $st.closedAt
    if ($closed -and ($Now - $closed).TotalSeconds -lt $Cfg.reopenWithinSec -and [double]$st.lastCoolSec -gt 0) {
        $cool = [math]::Min([double]$Cfg.coolMaxSec, [math]::Max($cool, [double]$st.lastCoolSec * $Cfg.coolGrowth))
    }
    $st.tripped = $true; $st.n = 1 + [int]$st.n; $st.openedAt = ConvertTo-BackoffIso $Now; $st.openUntil = ConvertTo-BackoffIso $Now.AddSeconds($cool)
    $st.coolSec = $cool; $st.reopens = 0; $st.probe = $null; $st.closeWhy = ''
    $r.did = 'open'; $r.open = $true
    if ([int]$st.alerted -ne [int]$st.n) { $st.alerted = $st.n; $r.alert = $true }   # one HIGH alert per episode
}
function Reopen-BreakerEpisode($r, [DateTime]$Now, $Cfg) {
    $st = $r.st; $cool = [math]::Min([double]$Cfg.coolMaxSec, [math]::Max([double]$Cfg.coolSec, [double]$st.coolSec * $Cfg.coolGrowth))
    $st.coolSec = $cool; $st.openUntil = ConvertTo-BackoffIso $Now.AddSeconds($cool); $st.reopens = 1 + [int]$st.reopens; $st.probe = $null
    $r.did = 'reopen'; $r.open = $true; $r.why = 'the trial step failed'
}
function Close-BreakerEpisode($r, [DateTime]$Now, [string]$Why, [string]$Kind) {
    $st = $r.st
    $st.tripped = $false; $st.closedAt = ConvertTo-BackoffIso $Now; $st.lastCoolSec = [double]$st.coolSec; $st.probe = $null; $st.closeWhy = $Kind; $st.openUntil = $null
    $r.did = 'closed'; $r.why = $Why
}
