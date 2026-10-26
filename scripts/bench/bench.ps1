# Tide benchmark: one command measures the system's speed, size and throughput, so every architecture or art wave proves its gain.
# Run by hand or by the main session: pwsh -File scripts/bench/bench.ps1 [-Out <json>] [-Baseline <json>] [-Tests]. Read-only on the live kitchen.
# Chef is measured on a temp copy of the kitchen state with its own throwaway server (scripts/bench/chef.mjs); throughput comes from the
# live events.jsonl (read only); -Tests also times every tests/Test-*.ps1 suite through scripts/run-bounded.ps1. With -Baseline it prints
# each metric's change; lower is better for times and bytes, higher for throughput.
param([string]$Out = '', [string]$Baseline = '', [switch]$Tests, [int]$Port = 0)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$live = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$m = [ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); commit = (git -C $repo rev-parse --short HEAD) }
function Median($xs) { $s = @($xs | Sort-Object); if (-not $s.Count) { return $null }; $s[[int][math]::Floor($s.Count / 2)] }

# --- Chef, on a copy of the state (never the live Chef server) ---
$copy = Join-Path ([IO.Path]::GetTempPath()) ('tide-bench-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force $copy | Out-Null
    Copy-Item (Join-Path $live 'jobs') (Join-Path $copy 'jobs') -Recurse
    foreach ($f in 'events.jsonl', 'supervisor.json', 'suppliers-board.json', 'alerts.jsonl', 'scoreboard.jsonl', 'ideas.json') { $p = Join-Path $live $f; if (Test-Path $p) { Copy-Item $p $copy } }
    New-Item -ItemType Directory -Force (Join-Path $copy 'run') | Out-Null
    $port = if ($Port) { $Port } else { Get-Random -Minimum 30000 -Maximum 40000 }
    $chef = & node (Join-Path $PSScriptRoot 'chef.mjs') (Join-Path $repo 'pass-app\server.mjs') $port $copy | Select-Object -Last 1 | ConvertFrom-Json
    foreach ($p in $chef.PSObject.Properties) { $m["chef.$($p.Name)"] = $p.Value }
    # the kitchen's own read of every job (status loads them all, as each tick does), on the copy
    $env:BRAIN_KITCHEN = $copy
    $st = 1..3 | ForEach-Object { (Measure-Command { & pwsh -NoProfile -File (Join-Path $repo 'kitchen\kitchen.ps1') status | Out-Null }).TotalMilliseconds }
    $m['engine.statusMs'] = [math]::Round((Median $st), 0)
} finally {
    $env:BRAIN_KITCHEN = $null
    Remove-Item -Recurse -Force $copy, "$copy-career", "$copy-income", "$copy-notify.txt" -ErrorAction SilentlyContinue
}
# one pwsh start: every station and tick pays it
$ps = 1..5 | ForEach-Object { (Measure-Command { & pwsh -NoProfile -Command 1 | Out-Null }).TotalMilliseconds }
$m['engine.pwshStartMs'] = [math]::Round((Median $ps), 0)
$m['engine.jobFiles'] = @(Get-ChildItem (Join-Path $live 'jobs') -Filter 'J*.json').Count
$m['engine.runFiles'] = @(Get-ChildItem (Join-Path $live 'run') -File -ErrorAction SilentlyContinue).Count
$m['engine.eventsMB'] = [math]::Round((Get-Item (Join-Path $live 'events.jsonl')).Length / 1MB, 2)

# --- throughput, from the live event log (read only) ---
$now = [DateTime]::UtcNow; $added = @{}; $done = @{}; $work = @{}; $start = @{}
foreach ($l in [IO.File]::ReadLines((Join-Path $live 'events.jsonl'))) {
    if ($l -notmatch '"type":"(job\.added|job\.done|step\.started|step\.done)"') { continue }
    try { $e = $l | ConvertFrom-Json } catch { continue }
    $t = ([DateTime]$e.ts).ToUniversalTime()
    switch ($e.type) {
        'job.added' { $added[$e.job] = $t }
        'job.done' { $done[$e.job] = $t }
        'step.started' { $start["$($e.job)/$($e.step)"] = $t }
        'step.done' { $k = "$($e.job)/$($e.step)"; if ($start[$k]) { $work[$e.job] = [double]$work[$e.job] + ($t - $start[$k]).TotalMinutes } }
    }
}
$recent = @($done.Keys | Where-Object { ($now - $done[$_]).TotalHours -le 24 })
$week = @($done.Keys | Where-Object { ($now - $done[$_]).TotalDays -le 7 -and $added[$_] })
$m['flow.doneLast24h'] = $recent.Count
$m['flow.leadTimeMedianH'] = if ($week.Count) { [math]::Round((Median ($week | ForEach-Object { ($done[$_] - $added[$_]).TotalHours })), 2) } else { $null }
$m['flow.workShareMedianPct'] = if ($week.Count) { [math]::Round((Median ($week | ForEach-Object { $lead = ($done[$_] - $added[$_]).TotalMinutes; if ($lead -gt 0) { 100 * [double]$work[$_] / $lead } else { 0 } })), 1) } else { $null }
$m['flow.openOrders'] = @(Get-ChildItem (Join-Path $live 'jobs') -Filter 'J*.json' | ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).status } | Where-Object { $_ -notin 'done', 'closed', 'killed' }).Count

# --- tests (slow; only with -Tests) ---
if ($Tests) {
    $total = 0
    foreach ($s in Get-ChildItem (Join-Path $repo 'tests') -Filter 'Test-*.ps1' | Sort-Object Name) {
        $sec = (Measure-Command { & pwsh -NoProfile -File (Join-Path $repo 'scripts\run-bounded.ps1') -Script $s.FullName -TimeoutSeconds 900 | Out-Null }).TotalSeconds
        $m["tests.$($s.BaseName)Sec"] = [math]::Round($sec, 1); $total += $sec
    }
    $m['tests.serialTotalSec'] = [math]::Round($total, 0)
}

if ($Out) { $m | ConvertTo-Json | Set-Content $Out -Encoding utf8 }
if ($Baseline -and (Test-Path $Baseline)) {
    $b = Get-Content $Baseline -Raw | ConvertFrom-Json
    $higherBetter = 'flow.doneLast24h', 'flow.workShareMedianPct'
    foreach ($k in $m.Keys) {
        $old = $b.$k; $new = $m[$k]
        if ($null -eq $old -or $null -eq $new -or $old -isnot [ValueType] -or $new -isnot [ValueType] -or $k -in 'at', 'commit') { "{0,-34} {1}" -f $k, $new; continue }
        $pct = if ([double]$old) { [math]::Round(100 * ([double]$new - [double]$old) / [double]$old, 1) } else { 0 }
        $better = if ($k -in $higherBetter) { $new -gt $old } else { $new -lt $old }
        "{0,-34} {1,12} -> {2,-12} {3,6}% {4}" -f $k, $old, $new, $pct, $(if ($new -eq $old) { '' } elseif ($better) { 'better' } else { 'WORSE' })
    }
} else { $m.GetEnumerator() | ForEach-Object { "{0,-34} {1}" -f $_.Key, $_.Value } }
