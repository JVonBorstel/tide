# Tests for kitchen/scaler.ps1 and the supervisor's admission (TARGET W2, J289): the RAM-scaled limit with fake readings, light steps
# outside the slots, the free-RAM math, and the W2 safety rule (no more than maxConcurrent heavy steps until weights are measured).
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path; $k = Join-Path $kd 'kitchen.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-scaler-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
. (Join-Path $kd 'scaler.ps1')
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_FAKE_FREE_MB', 'KITCHEN_AGY_EXE', 'BRAIN_NTFY_TOPIC', 'BRAIN_AGENT_DEPTH', 'KITCHEN_JOB') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
$now = [DateTime]::UtcNow
function Iso([double]$agoSec) { $now.AddSeconds(-$agoSec).ToString('o') }
# a scaler.json with readings every $step seconds over the last $span seconds (none in the gap from $gapFrom to $gapTo seconds ago)
function Seed([string]$dir, [int]$limit, [int]$mb, [int]$span = 600, [int]$step = 60, [int]$gapFrom = -1, [int]$gapTo = -1, [double]$changedAgo = 3600) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $s = @(for ($a = $span; $a -ge 30; $a -= $step) { if ($a -le $gapFrom -and $a -ge $gapTo) { continue }; @{ at = (Iso $a); freeMB = $mb } })
    @{ limit = $limit; changedAt = (Iso $changedAgo); samples = $s } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'scaler.json')
}
# a scaler.json with one reading a minute from 600 to 60 seconds ago, oldest first, at the given MB values
function SeedMbs([string]$dir, [int]$limit, [int[]]$mbs) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $s = @(for ($i = 0; $i -lt $mbs.Count; $i++) { @{ at = (Iso (600 - 60 * $i)); freeMB = $mbs[$i] } })
    @{ limit = $limit; changedAt = (Iso 3600); samples = $s } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'scaler.json')
}
# a test kitchen: supervisor.json says the Kitchen-Chores task ran just now (the tick skips the chores: fast), weights as given
function Kitchen([string]$name, $weights) {
    $d = "$root-$name"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    @{ choresTaskAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $d 'supervisor.json')
    if ($weights) { $weights | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $d 'weights.json') }
    $env:BRAIN_KITCHEN = $d; $d
}
function Add([string]$station, [int]$sec = 30) { & $k add -Name "$station order" -Script (Join-Path "$root-scripts" "$station.ps1") -ScriptArgs @{ Behavior = 'ok'; Seconds = $sec } -TimeoutSec 120 | Out-Null }
function Running([string]$d, [string]$station) { @(Get-ChildItem (Join-Path $d 'jobs') -Filter 'J*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.status -eq 'running' -and $_.name -eq "$station order" }).Count }
function Tick([int]$max = 4) { & pwsh -NoProfile -File $k tick -Quiet -MaxConcurrent $max | Out-Null }
$heavyW = @{ heavy = @{ mb = @(380, 390, 400); sec = @(600, 700, 800) }; light = @{ mb = @(40, 50, 60); sec = @(5, 8, 10) } }
try {
    $env:KITCHEN_AGY_EXE = 'off'; $env:BRAIN_NTFY_TOPIC = $null; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null
    # ---- J289's limit rule, with fake readings (one call = one tick's reading)
    $d = "$root-u1"; Seed $d 4 5000
    $r = Update-KitchenScaler $d 5000 4 6 $now
    Check 'TenMinutesOver4GB_RaisesByOne: every reading of 10 minutes over 4 GB raises 4 -> 5' ($r.limit -eq 5 -and $r.changed -and $r.old -eq 4)
    $r = Update-KitchenScaler $d 5000 4 6 $now.AddSeconds(60)
    Check 'a raise waits 10 minutes before the next one' ($r.limit -eq 5 -and -not $r.changed)
    $d = "$root-u2"; Seed $d 4 5000
    $r = Update-KitchenScaler $d 1500 4 6 $now
    Check 'OneReadingUnder2GB_LowersByOne: 4 -> 3' ($r.limit -eq 3 -and $r.changed -and $r.reading -eq 1500)
    Check 'the reading is kept in scaler.json' (@((Get-Content (Join-Path $d 'scaler.json') -Raw | ConvertFrom-Json).samples | Where-Object { $_.freeMB -eq 1500 }).Count -eq 1)
    $d = "$root-u3"; Seed $d 6 9000
    Check 'Ceiling6_Holds: 6 stays 6 with plenty free' ((Update-KitchenScaler $d 9000 4 6 $now).limit -eq 6)
    $d = "$root-u3b"; Seed $d 6 9000
    Check 'a ceiling below the limit (Jordan lowered maxConcurrentAuto) wins' ((Update-KitchenScaler $d 9000 4 5 $now).limit -eq 5)
    $d = "$root-u4"; Seed $d 1 1000
    Check 'Floor1_Holds: 1 stays 1 with almost nothing free' ((Update-KitchenScaler $d 1000 4 6 $now).limit -eq 1)
    # 10-23: cut to 1 at a dip, then 2.0-3.2 GB free for hours (this PC's normal): it must climb back
    $d = "$root-u10"; Seed $d 1 2300
    Check 'IdleAt2_3GB_ForTenMinutes_RaisesFromOne: the normal 2.0-3.2 GB free brings a cut limit back up' ((Update-KitchenScaler $d 2300 4 6 $now).limit -eq 2)
    $d = "$root-u5"; Seed $d 4 5000 -gapFrom 480 -gapTo 150
    Check 'GapInSamples_DoesNotRaise: 5 minutes without readings in the window' ((Update-KitchenScaler $d 5000 4 6 $now).limit -eq 4)
    $d = "$root-u6"; Seed $d 4 5000 -span 240
    Check 'readings of only the last 4 minutes do not raise' ((Update-KitchenScaler $d 5000 4 6 $now).limit -eq 4)
    $d = "$root-u7"; Seed $d 4 5000; $j = Get-Content (Join-Path $d 'scaler.json') -Raw | ConvertFrom-Json -AsHashtable; $j.samples[3].freeMB = 1900; $j | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $d 'scaler.json')
    Check 'OneDip_StillClimbs (TD-EH-19): one reading at 1.9 GB in a high window no longer holds Staffing back' ((Update-KitchenScaler $d 5000 4 6 $now).limit -eq 5)
    # TD-EH-19: +1 needs the MEDIAN of 10 minutes over the high mark AND the newest reading over it (readings 600..60 s ago, then the call's)
    $d = "$root-u11"; SeedMbs $d 1 @(2000, 5000, 2000, 5000, 2000, 5000, 2000, 5000, 2000, 2000)
    $r = Update-KitchenScaler $d 5000 4 6 $now
    Check 'MedianUnderMark_DoesNotClimb: 6 of 11 readings at 2.0 GB (average 3.4 GB) keep Staffing at 1' ($r.limit -eq 1 -and -not $r.changed)
    $d = "$root-u12"; SeedMbs $d 1 @(1800, 1900, 1950, 5000, 5000, 5000, 5000, 5000, 1700, 5000)
    $r = Update-KitchenScaler $d 4000 4 6 $now
    Check 'MedianOverMark_WithDips_Climbs: 4 dips, median 5 GB and the newest at 4 GB raise 1 -> 2' ($r.limit -eq 2 -and $r.changed -and $r.why -match 'median')
    $d = "$root-u13"; Seed $d 1 5000
    $r = Update-KitchenScaler $d 2000 4 6 $now
    Check 'NewestUnderMark_DoesNotClimb: 10 minutes at 5 GB, then 2,000 MB now keeps Staffing at 1 (and is no drop)' ($r.limit -eq 1 -and -not $r.changed)
    $d = "$root-u14"; Seed $d 4 5000
    Check 'a reading under 1,536 MB after a high window still drops at once (the drop rule wins)' ((Update-KitchenScaler $d 1500 4 6 $now).limit -eq 3)
    $d = "$root-u8"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $r = Update-KitchenScaler $d 5000 4 6 $now
    Check 'a new kitchen starts from maxConcurrent and does not jump on its first reading' ($r.limit -eq 4 -and -not $r.changed -and (Get-KitchenScalerLimit $d 4 6) -eq 4)
    Check 'no reading (a test kitchen): no scaler.json is written' (-not (Update-KitchenScaler "$root-u9" $null 4 6 $now).changed -and -not (Test-Path "$root-u9\scaler.json"))

    # ---- weights and the admission math
    $wd = "$root-w"; New-Item -ItemType Directory -Force -Path $wd | Out-Null
    foreach ($x in 1..25) { Add-KitchenWeight $wd 'tests' 300 900 }
    Add-KitchenWeight $wd 'commit' $null 4; Add-KitchenWeight $wd 'commit' $null 6; Add-KitchenWeight $wd 'commit' 30 5
    $w = Read-KitchenWeights $wd
    Check 'weights keep the last 20 runs per station' (@($w.tests.sec).Count -eq 20 -and @($w.tests.mb).Count -eq 20)
    Check 'a run the tick never sampled keeps its seconds, not a 0 MB peak' (@($w.commit.sec).Count -eq 3 -and @($w.commit.mb).Count -eq 1)
    Check 'short, small runs make a station light; long ones heavy and measured' ((Get-StationWeight $w 'commit').light -and -not (Get-StationWeight $w 'tests').light -and (Get-StationWeight $w 'tests').measured)
    Check 'a station with fewer than 3 runs is neither light nor measured' (-not (Get-StationWeight $heavyW 'nope').light -and -not (Get-StationWeight $heavyW 'nope').measured)
    $a = Test-KitchenAdmit 'heavy' $heavyW @() 6 4 1300
    Check 'FreeRamMath_Refuses_WhenShort: 1,300 MB free - 1,024 reserve < a 400 MB step' (-not $a.ok -and $a.why -match 'RAM')
    $a = Test-KitchenAdmit 'heavy' $heavyW @(@{ station = 'heavy'; mb = 100 }) 6 4 1700
    Check 'FreeRamMath: a running step still to grow (400 - 100 MB) is counted against the room' (-not $a.ok -and $a.why -match '300 MB still to come')
    Check 'FreeRamMath: enough room starts it' ((Test-KitchenAdmit 'heavy' $heavyW @(@{ station = 'heavy'; mb = 390 }) 6 4 1500).ok)
    $four = @(1..4 | ForEach-Object { @{ station = 'heavy'; mb = 400 } })
    Check 'measured weight and room: the scaled limit (6) lets a 5th heavy step start' ((Test-KitchenAdmit 'heavy' $heavyW $four 6 4 9000).ok)
    Check 'NoWeights_NeverOverMaxConcurrent: an unmeasured station stays at 4 even with limit 6 and 9 GB free' (-not (Test-KitchenAdmit 'other' $heavyW @(1..4 | ForEach-Object { @{ station = 'other'; mb = 400 } }) 6 4 9000).ok)
    Check 'no reading (test kitchen): a measured station stays at maxConcurrent' (-not (Test-KitchenAdmit 'heavy' $heavyW $four 6 4 $null).ok)
    Check 'LightStep_StartsWhile4HeavyRun (math): light is outside the slots' ((Test-KitchenAdmit 'light' $heavyW $four 4 4 $null).ok -and (Test-KitchenAdmit 'light' $heavyW $four 4 4 $null).light)
    Check 'maxConcurrent 0 starts nothing, light or heavy' (-not (Test-KitchenAdmit 'light' $heavyW @() 4 0 9000).ok)

    # ---- the tick uses it (station = the step script's file name)
    New-Item -ItemType Directory -Force -Path "$root-scripts" | Out-Null
    foreach ($n in 'heavy', 'light', 'other') { Copy-Item (Join-Path $kd 'demo-worker.ps1') (Join-Path "$root-scripts" "$n.ps1") }
    $d = Kitchen 'light' $heavyW
    1..5 | ForEach-Object { Add 'heavy' }; Add 'light'
    Tick
    Check 'LightStep_StartsWhile4HeavyRun: 4 heavy run, the light one starts too, the 5th heavy waits' ((Running $d 'heavy') -eq 4 -and (Running $d 'light') -eq 1)
    & $k kill -All | Out-Null
    $d = Kitchen 'scaled' $heavyW; Seed $d 2 9000 -changedAgo 30; $env:KITCHEN_FAKE_FREE_MB = '9000'
    1..4 | ForEach-Object { Add 'heavy' }
    Tick
    Check 'TickUsesScaledLimit: limit 2 in scaler.json -> 2 heavy steps start, not 4' ((Running $d 'heavy') -eq 2)
    Check 'the tick added its reading to scaler.json' (@((Get-Content (Join-Path $d 'scaler.json') -Raw | ConvertFrom-Json).samples).Count -ge 10)
    & $k kill -All | Out-Null
    $d = Kitchen 'short' $heavyW; $env:KITCHEN_FAKE_FREE_MB = '1500'
    1..3 | ForEach-Object { Add 'heavy' }
    Tick
    Check 'FreeRamMath_Refuses_WhenShort (tick): 1,500 MB free starts one 400 MB step, not three' ((Running $d 'heavy') -eq 1)
    Check 'the tick lowered the limit on a reading under 2 GB and logged it' ((Get-Content (Join-Path $d 'events.jsonl') -Raw) -match '"type":"scaler".*"old":4.*"new":3' -or (Get-Content (Join-Path $d 'events.jsonl') -Raw) -match '"type":"scaler"[^\n]*"new":3')
    & $k kill -All | Out-Null
    $d = Kitchen 'unmeasured' $null; Seed $d 6 9000 -changedAgo 30; $env:KITCHEN_FAKE_FREE_MB = '9000'
    1..6 | ForEach-Object { Add 'other' }
    Tick
    Check 'NoWeights_NeverOverMaxConcurrent (tick): limit 6 and 9 GB free, no weights -> 4 start' ((Running $d 'other') -eq 4)
    & $k kill -All | Out-Null
    $o = & $k doctor | Out-String
    Check 'the doctor report shows the current limit' ($o -match 'slots: heavy limit 6 \(scaler; maxConcurrent 4, ceiling 6\)')
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } | ForEach-Object { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null }
    Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter ((Split-Path -Leaf $root) + '*') | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Scaler tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
