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

    # ---- TD-7: the Sites registry (kitchen.json "sites") and a per-Site maxHeavy
    $none = Get-KitchenSites @{ maxConcurrent = 4 }
    Check 'Registry_NoBlock: no "sites" key gives no Sites and no problems' ($none.sites.Count -eq 0 -and $none.problems.Count -eq 0)
    $empty = Get-KitchenSites @{ sites = @{} }
    Check 'Registry_EmptyBlock (the repo template): no Sites, no problems' ($empty.sites.Count -eq 0 -and $empty.problems.Count -eq 0)
    $tmpl = Get-Content (Join-Path $kd 'kitchen.json') -Raw | ConvertFrom-Json -AsHashtable
    Check 'the repo template kitchen.json carries an empty sites block' ($tmpl.sites -is [Collections.IDictionary] -and (Get-KitchenSites $tmpl).sites.Count -eq 0)
    $reg = Get-KitchenSites ('{ "sites": { "TD": { "maxHeavy": 2, "share": 1 }, "GW": { "maxHeavy": 1, "share": 2.5 }, "JH": { } } }' | ConvertFrom-Json -AsHashtable)
    Check 'Registry_Reads: maxHeavy and share per Site from JSON' ($reg.sites.TD.maxHeavy -eq 2 -and $reg.sites.GW.maxHeavy -eq 1 -and $reg.sites.GW.share -eq 2.5 -and $reg.problems.Count -eq 0)
    Check 'Registry_Defaults: a Site with neither key has no limit and share 1 (equal)' ($reg.sites.ContainsKey('JH') -and $null -eq $reg.sites.JH.maxHeavy -and $reg.sites.JH.share -eq 1)
    $badReg = Get-KitchenSites ('{ "sites": { "TD": { "maxHeavy": 0, "share": -1 }, "GW": { "maxHeavy": "2", "share": "x" }, "ZG": { "maxHeavy": 1.5 }, "td": { "maxHeavy": 1 }, "JH": 3 } }' | ConvertFrom-Json -AsHashtable)
    Check 'Registry_BadValues: 0, "2" and 1.5 are no limit; -1 and "x" share 1; each one named' ($null -eq $badReg.sites.TD.maxHeavy -and $null -eq $badReg.sites.GW.maxHeavy -and $null -eq $badReg.sites.ZG.maxHeavy -and $badReg.sites.TD.share -eq 1 -and $badReg.sites.GW.share -eq 1 -and @($badReg.problems -match 'maxHeavy').Count -eq 3 -and @($badReg.problems -match 'share').Count -eq 2)
    Check 'Registry_BadEntries: a lower-case code and a non-object entry are left out and named' (@($badReg.sites.Keys) -cnotcontains 'td' -and -not $badReg.sites.ContainsKey('JH') -and @($badReg.problems -cmatch '^sites\.(td|JH): ').Count -eq 2)
    Check 'Registry_NotAnObject: "sites" as a list is left out and named' ((Get-KitchenSites @{ sites = @(1, 2) }).sites.Count -eq 0 -and (Get-KitchenSites @{ sites = @(1, 2) }).problems.Count -eq 1)
    Check 'shares: one weight per registry Site' ((Get-KitchenSiteShares $reg.sites).GW -eq 2.5 -and (Get-KitchenSiteShares $reg.sites).TD -eq 1)
    $tdRun = @(@{ station = 'heavy'; mb = 400; site = 'TD' }, @{ station = 'heavy'; mb = 400; site = 'TD' })
    $a = Test-KitchenAdmit 'other' $heavyW $tdRun 4 4 $null 1024 'TD' 2
    Check 'SiteMaxHeavy_Holds: TD at its maxHeavy 2 waits, and says why' (-not $a.ok -and $a.why -match 'Site TD: all 2 of its heavy slots busy')
    Check 'SiteMaxHeavy_OtherSiteStarts: a GW step starts while TD is at its limit' ((Test-KitchenAdmit 'other' $heavyW $tdRun 4 4 $null 1024 'GW' 1).ok)
    Check 'SiteMaxHeavy_UnderLimit: TD with 2 running and maxHeavy 3 starts' ((Test-KitchenAdmit 'other' $heavyW $tdRun 4 4 $null 1024 'TD' 3).ok)
    Check 'SiteMaxHeavy_LightIgnores: a light TD step starts at the Site limit (light is outside the slots)' ((Test-KitchenAdmit 'light' $heavyW $tdRun 4 4 $null 1024 'TD' 1).ok)
    Check 'SiteMaxHeavy_LightRunningNotCounted: light steps running for TD do not use its heavy slots' ((Test-KitchenAdmit 'other' $heavyW @(@{ station = 'light'; mb = 50; site = 'TD' }, @{ station = 'light'; mb = 50; site = 'TD' }) 4 4 $null 1024 'TD' 1).ok)
    Check 'SiteMaxHeavy_GlobalStillWins: TD maxHeavy 9, the 4 global slots full -> waits on the global cap' ((Test-KitchenAdmit 'other' $heavyW @(1..4 | ForEach-Object { @{ station = 'other'; mb = 400; site = 'GW' } }) 4 4 $null 1024 'TD' 9).why -eq 'all 4 slots busy')
    Check 'SiteMaxHeavy_RamStillWins: a TD step under its Site limit still needs the RAM' ((Test-KitchenAdmit 'heavy' $heavyW @() 6 4 1300 1024 'TD' 3).why -match 'RAM')
    # NoSitesBlock_AdmissionUnchanged: with no "sites" block every admission answer is the one from before TD-7 (the call without Site
    # arguments), over 2,000 random passes: stations light/heavy/unmeasured, running steps of any Site, limits, maxConcurrent, free RAM
    $rnd = [Random]::new(77); $same = $true; $noReg = (Get-KitchenSites @{}).sites
    for ($n = 0; $n -lt 2000; $n++) {
        $stn = @('heavy', 'light', 'other')[$rnd.Next(3)]; $si = @('', 'TD', 'GW', 'JH')[$rnd.Next(4)]
        $runR = @(1..$rnd.Next(0, 7) | ForEach-Object { @{ station = @('heavy', 'light', 'other')[$rnd.Next(3)]; mb = $rnd.Next(0, 500); site = @('', 'TD', 'GW')[$rnd.Next(3)] } })
        $lim = $rnd.Next(1, 7); $mc = $rnd.Next(0, 6); $fr = @($null, $rnd.Next(500, 9000))[$rnd.Next(2)]
        $old = Test-KitchenAdmit $stn $heavyW $runR $lim $mc $fr 1024
        $new = Test-KitchenAdmit $stn $heavyW $runR $lim $mc $fr 1024 $si $(if ($si -and $noReg.ContainsKey($si)) { $noReg[$si].maxHeavy } else { $null })
        if ($old.ok -ne $new.ok -or $old.why -ne $new.why -or $old.light -ne $new.light) { $same = $false; break }
    }
    Check 'NoSitesBlock_AdmissionUnchanged: 2,000 random passes give the same answer as before TD-7' $same
    # ---- TD-10: weights keyed by station + Tower
    # no "@" entries: every admission answer is the same with or without a Tower (exactly the old behaviour)
    $gw = 'C:\Users\x\demo-project'; $same = $true
    foreach ($st in 'heavy', 'light', 'other', 'nope') { foreach ($fr in $null, 1300, 1700, 9000) { foreach ($rs in @(@()), @(@{ station = 'heavy'; mb = 100 }), $four) {
        $x0 = Test-KitchenAdmit $st $heavyW $rs 6 4 $fr; $x1 = Test-KitchenAdmit $st $heavyW @($rs | ForEach-Object { $_ + @{ tower = $gw } }) 6 4 $fr 1024 -Tower $gw
        if ($x0.ok -ne $x1.ok -or $x0.light -ne $x1.light -or $x0.why -ne $x1.why) { $same = $false } } } }
    Check 'NoTowerKeys_SameAsBefore: 48 admission cases answer the same with a Tower and without' $same
    $wt = "$root-wt"; New-Item -ItemType Directory -Force -Path $wt | Out-Null
    Add-KitchenWeight $wt 'tests' 300 900
    Check 'a run with no Tower writes only the station entry, as before' (@((Read-KitchenWeights $wt).Keys) -join ',' -eq 'tests')
    foreach ($x in 1..3) { Add-KitchenWeight $wt 'tests' 900 900 "$gw\" }
    $w2 = Read-KitchenWeights $wt
    Check 'a run with a Tower lands under station and station@tower (folder name, lower case)' (@($w2.tests.sec).Count -eq 4 -and @($w2['tests@demo-project'].mb).Count -eq 3)
    $tw = @{ heavy = @{ mb = @(380, 390, 400); sec = @(600, 700, 800) }; 'heavy@demo-project' = @{ mb = @(2900, 3000, 3000); sec = @(600, 700, 800) }; 'heavy@brain-monitor' = @{ mb = @(9000, 9000); sec = @(600, 700) } }
    $a = Test-KitchenAdmit 'heavy' $tw @() 6 4 3000 1024 -Tower $gw
    Check 'PerTowerWeight: a Demo Project heavy step is judged by its own 3,000 MB weight (refused at 3,000 MB free)' (-not $a.ok -and $a.why -match 'needs 3000 MB')
    Check 'PerTowerWeight: the same station for another Tower keeps the station weight (400 MB fits)' ((Test-KitchenAdmit 'heavy' $tw @() 6 4 3000 1024 -Tower 'C:\r\zeitgeistd').ok)
    Check 'a Tower entry with fewer than 3 runs is not used yet: the measured station weight decides (a 5th heavy step under limit 6)' ((Test-KitchenAdmit 'heavy' $tw $four 6 4 9000 1024 -Tower 'C:\r\brain-monitor').ok)
    Check '(without its Tower the same running step would leave room)' ((Test-KitchenAdmit 'heavy' $tw @(@{ station = 'heavy'; mb = 1000 }) 6 4 3300 1024 -Tower '').ok)
    $a = Test-KitchenAdmit 'heavy' $tw @(@{ station = 'heavy'; mb = 1000; tower = $gw }) 6 4 3300 1024 -Tower ''
    Check 'a running Demo Project step still to grow counts its Tower weight (3,000 - 1,000 MB) against the room' (-not $a.ok -and $a.why -match '2000 MB still to come')

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
    Check 'no "sites" block: the doctor slots line has no Sites part' ($o -notmatch 'Sites:')

    # ---- TD-7 in the tick: orders tagged TD and GW (vars.site, as kitchen.ps1 add stores it from the Tower)
    function AddSite([string]$d, [string]$site) {
        Add 'other'
        $f = Get-ChildItem (Join-Path $d 'jobs') -Filter 'J*.json' | Sort-Object { [int]($_.BaseName.TrimStart('J')) } | Select-Object -Last 1
        $jj = Get-Content $f.FullName -Raw | ConvertFrom-Json -AsHashtable; $jj.vars = @{ site = $site }; $jj | ConvertTo-Json -Depth 20 | Set-Content $f.FullName
    }
    function RunningSite([string]$d, [string]$site) { @(Get-ChildItem (Join-Path $d 'jobs') -Filter 'J*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.status -eq 'running' -and $_.vars.site -eq $site }).Count }
    $d = Kitchen 'nosites' $null; $env:KITCHEN_FAKE_FREE_MB = $null
    foreach ($s in 'TD', 'TD', 'TD', 'GW', 'GW', 'GW') { AddSite $d $s }
    Tick
    Check 'NoSitesBlock_TickUnchanged: 6 tagged orders, no "sites" block -> 4 heavy start (maxConcurrent), as before TD-7' ((Running $d 'other') -eq 4)
    & $k kill -All | Out-Null
    $d = Kitchen 'sites' $null
    '{ "sites": { "TD": { "maxHeavy": 1 }, "GW": { "maxHeavy": 0 } } }' | Set-Content (Join-Path $d 'kitchen.json')
    foreach ($s in 'TD', 'TD', 'TD', 'GW', 'GW', 'GW') { AddSite $d $s }
    Tick
    Check 'SiteMaxHeavy_Tick: TD maxHeavy 1 -> 1 TD step runs; GW (a bad 0: no limit) fills the other 3 slots' ((RunningSite $d 'TD') -eq 1 -and (RunningSite $d 'GW') -eq 3)
    $sv = Get-Content (Join-Path $d 'supervisor.json') -Raw | ConvertFrom-Json
    Check 'the bad registry value is written to supervisor.json admission.siteProblems' (@($sv.admission.siteProblems | Where-Object { $_ -match 'sites\.GW\.maxHeavy' }).Count -eq 1)
    & $k kill -All | Out-Null
    $o = & $k doctor | Out-String
    Check 'the doctor slots line names each Site''s limit and share' ($o -match 'Sites: GW heavy any, share 1; TD heavy 1, share 1')
    Check 'the doctor notes the bad registry value' ($o -match 'note: kitchen\.json sites\.GW\.maxHeavy')
    # TD-10 in the tick: an order's Tower (vars.repo) picks its weight; its finished run is learned under station and station@tower
    $d = Kitchen 'tower' $tw; $env:KITCHEN_FAKE_FREE_MB = '3000'
    $spec = Join-Path $d 'gw-spec.json'
    @{ name = 'heavy order'; vars = @{ repo = $gw }; steps = @(@{ script = (Join-Path "$root-scripts" 'heavy.ps1'); args = @{ Behavior = 'ok'; Seconds = 1 }; timeoutSec = 120 }) } | ConvertTo-Json -Depth 5 | Set-Content $spec
    & $k add -SpecPath $spec | Out-Null; Add 'heavy' 1
    Tick
    $gwJob = @(Get-ChildItem (Join-Path $d 'jobs') -Filter 'J*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.vars.repo -eq $gw })
    Check 'PerTowerWeight (tick): at 3,000 MB free the plain heavy order starts, the Demo Project one (3,000 MB) waits' ((Running $d 'heavy') -eq 1 -and $gwJob.Count -eq 1 -and $gwJob[0].status -eq 'pending')
    $env:KITCHEN_FAKE_FREE_MB = '9000'
    for ($i = 0; $i -lt 20; $i++) {   # a tick every 2 s until both 1-second orders are done (at most 40 s)
        Start-Sleep -Seconds 2; Tick
        if (@(Get-ChildItem (Join-Path $d 'jobs') -Filter 'J*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.status -ne 'done' }).Count -eq 0) { break }
    }
    $w3 = Get-Content (Join-Path $d 'weights.json') -Raw | ConvertFrom-Json -AsHashtable
    Check 'the tick learns a Demo Project run under heavy and heavy@demo-project, a plain run under heavy only' (@($w3.heavy.sec).Count -eq 5 -and @($w3['heavy@demo-project'].sec).Count -eq 4)
    & $k kill -All | Out-Null
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } | ForEach-Object { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null }
    Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter ((Split-Path -Leaf $root) + '*') | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Scaler tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
