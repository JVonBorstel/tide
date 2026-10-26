# Admission by free RAM and measured weight (TARGET W2 D5, J289 re-filed from J235): how many heavy steps may run, and whether this one
# may start now. Dot-sourced by kitchen.ps1 (its locked pass and the doctor line); tests/Test-Scaler.ps1 drives every rule with fake readings.
# The limit (<kitchen>\scaler.json {limit, changedAt, samples of the last 30 min as {at, freeMB}}) starts at maxConcurrent and moves by one:
#   -1 when the newest reading is under 1,536 MB free (at most once a minute; never below 1; running steps are never stopped, new ones wait);
#   +1 when the MEDIAN reading of the last 10 minutes is over 2,048 MB, the newest reading is too, and they cover it (no gap over
#      2 minutes), at most once per 10 minutes (TD-EH-19, 10-24: "every reading over" let one low sample hold Staffing at 1 for hours;
#      10-23: at 2,048/4,096 a limit cut to 1 never came back for 5 h; this PC runs 1-4 orders at 2.0-3.2 GB free. The real guard is
#      per start: a measured step starts only if free RAM minus a 1,024 MB reserve and the running steps' unclaimed weight fits it)
#      never above kitchen.json maxConcurrentAuto (default 6; above that is Jordan's own edit).
# Weights (<kitchen>\weights.json, the last 20 runs per station: peak MB of the whole process tree as the tick sampled it, and seconds):
#   a station with 3+ runs, p90 under 120 s and p90 peak under 150 MB is LIGHT: it starts outside the slots (worktree, commit, pr... are
#   60 s of tick wait, not work). A HEAVY station with 3+ sampled runs is MEASURED: it may use the scaled limit when the free RAM after a
#   1,024 MB reserve and the unclaimed weight of the running heavy steps (p90, else 400 MB, minus what each already uses) fits its p90.
#   Anything not measured keeps today's rule: at most maxConcurrent heavy steps (W2 safety: no more than 4 until weights exist).
# KITCHEN_FAKE_FREE_MB stands in for the reading in tests; test kitchens take no reading otherwise (their limit stays maxConcurrent).
$script:ScalerLowMB = 1536; $script:ScalerHighMB = 2048; $script:ScalerWindowSec = 600; $script:ScalerGapSec = 120
$script:WeightKeep = 20; $script:WeightMinRuns = 3; $script:LightMB = 150; $script:LightSec = 120; $script:HeavyDefaultMB = 400

function Get-ScalerFreeMB([bool]$Real) {
    if ($env:KITCHEN_FAKE_FREE_MB -match '^\d+$') { return [int]$env:KITCHEN_FAKE_FREE_MB }
    if (-not $Real) { return $null }
    try { [int]((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1KB) } catch { $null }
}
function Read-ScalerJson([string]$Path) { try { [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable } catch { $null } }
function Save-ScalerJson([string]$Path, $Obj) { $t = "$Path.tmp-$PID"; $Obj | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $t -Encoding utf8; [IO.File]::Move($t, $Path, $true) }
function ScalerUtc($v) { if ($v -is [DateTime]) { $v.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } }

# The current limit without a new reading (the doctor line; a kitchen with no scaler.json yet: maxConcurrent)
function Get-KitchenScalerLimit([string]$Root, [int]$Start, [int]$Ceiling) {
    $s = Read-ScalerJson (Join-Path $Root 'scaler.json')
    $l = if ($s -and $s.limit) { [int]$s.limit } else { $Start }
    [math]::Max(1, [math]::Min($l, $Ceiling))
}
# One reading (none when $FreeMB is $null), then the rule. Returns @{ limit; old; changed; reading; why }.
function Update-KitchenScaler([string]$Root, $FreeMB, [int]$Start, [int]$Ceiling, [DateTime]$Now = [DateTime]::UtcNow) {
    $p = Join-Path $Root 'scaler.json'; $s = Read-ScalerJson $p
    if (-not ($s -is [hashtable])) { $s = @{ limit = $Start; samples = @() } }
    $old = [math]::Max(1, [math]::Min([int]$s.limit, $Ceiling)); $limit = $old; $why = ''
    $samples = @(@($s.samples) | Where-Object { $_ -and $_.at } | Where-Object { ($Now - (ScalerUtc $_.at)).TotalSeconds -le 1800 })
    $added = $false
    if ($null -ne $FreeMB -and (-not $samples.Count -or ($Now - (ScalerUtc $samples[-1].at)).TotalSeconds -ge 20)) {   # (drain passes add no extra readings)
        $samples += @{ at = $Now.ToString('o'); freeMB = [int]$FreeMB }; $added = $true
    }
    $since = if ($s.changedAt) { ($Now - (ScalerUtc $s.changedAt)).TotalSeconds } else { 1e9 }
    if ($added -and [int]$FreeMB -lt $script:ScalerLowMB -and $limit -gt 1 -and $since -ge 60) { $limit--; $why = "only $FreeMB MB free" }
    elseif ($added -and $limit -lt $Ceiling -and $since -ge $script:ScalerWindowSec -and (Test-ScalerHighWindow $samples $Now)) { $limit++; $why = "median over $($script:ScalerHighMB) MB free for 10 minutes, and now" }
    $s.limit = $limit; $s.samples = $samples
    if ($limit -ne $old) { $s.changedAt = $Now.ToString('o') }
    if ($added -or $limit -ne $old) { Save-ScalerJson $p $s }
    @{ limit = $limit; old = $old; changed = ($limit -ne $old); reading = $FreeMB; why = $why }
}
# the readings of the last 10 minutes cover the whole window (one near its start, no gap over 2 minutes), their median is over the high
# mark, and the newest one is over it too (one dip no longer resets the climb; a reading low right now still stops it)
function Test-ScalerHighWindow($Samples, [DateTime]$Now) {
    $from = $Now.AddSeconds(-$script:ScalerWindowSec)
    $win = @($Samples | Where-Object { (ScalerUtc $_.at) -ge $from.AddSeconds(-$script:ScalerGapSec) } | Sort-Object { ScalerUtc $_.at })
    if (-not $win.Count -or (ScalerUtc $win[0].at) -gt $from.AddSeconds($script:ScalerGapSec)) { return $false }
    $prev = ScalerUtc $win[0].at
    foreach ($x in $win) { $t = ScalerUtc $x.at; if (($t - $prev).TotalSeconds -gt $script:ScalerGapSec) { return $false }; $prev = $t }
    if (($Now - $prev).TotalSeconds -gt $script:ScalerGapSec -or [int]$win[-1].freeMB -le $script:ScalerHighMB) { return $false }
    $mbs = @($win | Where-Object { (ScalerUtc $_.at) -ge $from } | ForEach-Object { [double]$_.freeMB } | Sort-Object)
    if (-not $mbs.Count) { return $false }
    $mid = [int][math]::Floor($mbs.Count / 2)
    $median = if ($mbs.Count % 2) { $mbs[$mid] } else { ($mbs[$mid - 1] + $mbs[$mid]) / 2 }
    $median -gt $script:ScalerHighMB
}

# ---- weights: the last runs of each station ----
function Read-KitchenWeights([string]$Root) { $w = Read-ScalerJson (Join-Path $Root 'weights.json'); if ($w -is [hashtable]) { $w } else { @{} } }
function Add-KitchenWeight([string]$Root, [string]$Station, $PeakMB, [double]$Sec) {
    if (-not $Station) { return }
    $w = Read-KitchenWeights $Root
    $e = if ($w[$Station] -is [hashtable]) { $w[$Station] } else { @{ mb = @(); sec = @() } }
    $e.sec = @(@($e.sec) + [int][math]::Round($Sec) | Select-Object -Last $script:WeightKeep)
    if ($null -ne $PeakMB -and [double]$PeakMB -gt 0) { $e.mb = @(@($e.mb) + [int][math]::Round([double]$PeakMB) | Select-Object -Last $script:WeightKeep) }
    $w[$Station] = $e
    Save-ScalerJson (Join-Path $Root 'weights.json') $w
}
function Get-P90($xs) { $a = @($xs | ForEach-Object { [double]$_ } | Sort-Object); if (-not $a.Count) { return $null }; $a[[math]::Min($a.Count - 1, [int][math]::Ceiling(0.9 * $a.Count) - 1)] }
$script:WMemoFor = $null; $script:WMemo = @{}   # (one pass asks for the same stations once per pending order: worked out once per weights read)
function Get-StationWeight($Weights, [string]$Station) {
    if (-not [object]::ReferenceEquals($Weights, $script:WMemoFor)) { $script:WMemoFor = $Weights; $script:WMemo = @{} }
    if ($script:WMemo.ContainsKey($Station)) { return $script:WMemo[$Station] }
    $script:WMemo[$Station] = Get-StationWeightOf $Weights $Station; $script:WMemo[$Station]
}
function Get-StationWeightOf($Weights, [string]$Station) {
    $e = $Weights[$Station]; $mb = @($e.mb | Where-Object { $null -ne $_ }); $sec = @($e.sec | Where-Object { $null -ne $_ })
    $p90MB = Get-P90 $mb; $p90Sec = Get-P90 $sec
    $light = $sec.Count -ge $script:WeightMinRuns -and $p90Sec -le $script:LightSec -and ($null -eq $p90MB -or $p90MB -le $script:LightMB)
    @{ runs = $sec.Count; sampled = $mb.Count; p90MB = $p90MB; p90Sec = $p90Sec; light = $light; measured = (-not $light -and $mb.Count -ge $script:WeightMinRuns) }
}
# May a step of $Station start now? $Running: the running steps as @{station; mb} (mb = what the tree uses now). Returns @{ ok; light; why }.
function Test-KitchenAdmit([string]$Station, $Weights, $Running, [int]$Limit, [int]$MaxConcurrent, $FreeMB, [int]$ReserveMB = 1024) {
    if ($MaxConcurrent -le 0) { return @{ ok = $false; light = $false; why = 'maxConcurrent is 0' } }
    $w = Get-StationWeight $Weights $Station
    if ($w.light) { return @{ ok = $true; light = $true; why = 'light step (outside the slots)' } }
    $heavy = @($Running | Where-Object { -not (Get-StationWeight $Weights ([string]$_.station)).light })
    $byRam = $w.measured -and $null -ne $FreeMB
    $cap = if ($byRam) { $Limit } else { [math]::Min($Limit, $MaxConcurrent) }
    if ($heavy.Count -ge $cap) { return @{ ok = $false; light = $false; why = "all $cap slots busy" } }
    if ($byRam) {
        $unclaimed = 0.0
        foreach ($r in $heavy) { $rw = (Get-StationWeight $Weights ([string]$r.station)).p90MB; if ($null -eq $rw) { $rw = $script:HeavyDefaultMB }; $unclaimed += [math]::Max(0, $rw - [double]$r.mb) }
        $room = [double]$FreeMB - $ReserveMB - $unclaimed
        if ($room -lt $w.p90MB) { return @{ ok = $false; light = $false; why = "RAM: $([int]$room) MB room after the $ReserveMB MB reserve and $([int]$unclaimed) MB still to come, needs $([int]$w.p90MB) MB" } }
    }
    @{ ok = $true; light = $false; why = '' }
}
