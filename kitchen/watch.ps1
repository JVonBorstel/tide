# The Watch's meta-check: watches the watchers (gemini-brain projects/tide/02-the-watch.md, layer 3). No AI. Safe to re-run: yes.
# Checks, each a plain sentence when something is wrong:
#   - every heartbeat in <kitchen>\watch\*.json ran on time (late = older than 2x its interval, at least 15 minutes)
#   - the supervisor tick is fresh (supervisor.json lastTick); while Jordan has paused the Yard (PAUSED file) the paused Walkround is
#     (lastTickEnd: it still minds running work and runs the watchers, TD-EH-26), and only heartbeats marked whilePaused must stay on time
#   - the kitchen's and the rig's scheduled tasks (Kitchen-*, Rig-*, and the new names in scripts/task-names.json) last ran without an
#     error code, and no task is registered under both its old and its new name (that would tick twice)
#   - GitHub sign-in (gh auth status) still works: every PR and CI check needs it
#   - the nightly backups ran: the in-kitchen copy (backups\daily\yyyyMMdd) and the off-drive copy (kitchen.json backupDest, D:\backups\kitchen)
#   - the mode on record matches the files (LIVE, PAUSED, push-on) and is stated plainly
# Writes watch\watch.json (its own heartbeat; Chef and the doctor read it) and prints the report. Exit 0 = all good, 3 = problems found.
#   watch.ps1 [-Json] [-NoGh] [-NoTasks]
param([switch]$Json, [switch]$NoGh, [switch]$NoTasks)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$now = [DateTime]::UtcNow; $t0 = [Diagnostics.Stopwatch]::StartNew()
$problems = [Collections.Generic.List[object]]::new(); $checked = 0
function Problem([string]$what, [string]$owner, [string]$say) { $problems.Add([ordered]@{ what = $what; owner = $owner; say = $say }) }
function Utc($v) { if (-not $v) { return $null }; try { [DateTime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal) } catch { $null } }
function Mins($v) { $t = Utc $v; if ($t) { [math]::Round(($now - $t).TotalMinutes) } else { $null } }
function ReadJson([string]$p) { try { Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { $null } }
$paused = Test-Path -LiteralPath (Join-Path $root 'PAUSED'); $live = Test-Path -LiteralPath (Join-Path $root 'LIVE'); $push = Test-Path -LiteralPath (Join-Path $root 'push-on')
$mode = "kitchen $(if ($paused) { 'PAUSED by Jordan (nothing new starts; running work and the watchers are still watched)' } elseif ($live) { 'live, AI cooks on' } else { 'running, AI cooks off' }); phone alerts $(if ($push) { 'on' } else { 'OFF' })"
if (-not $push) { Problem 'push-off' 'Jordan' 'Phone alerts are off (no push-on file): if Chef cannot reach you, nothing else will.' }

# 1. heartbeats
$wd = Join-Path $root 'watch'
foreach ($f in @(Get-ChildItem -LiteralPath $wd -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    if ($f.BaseName -in 'watch', 'report') { continue }
    $checked++
    $h = ReadJson $f.FullName
    if (-not $h -or -not $h.lastRun) { Problem "heartbeat:$($f.BaseName)" 'Claude' "The $($f.BaseName) watcher's heartbeat file is damaged or empty."; continue }
    $every = [math]::Max(1, [int]$(if ($h.everyMin) { $h.everyMin } else { 60 })); $late = [math]::Max(15, 2 * $every); $age = Mins $h.lastRun
    if ($null -eq $age) { Problem "heartbeat:$($f.BaseName)" 'Claude' "The $($f.BaseName) watcher's last run time cannot be read."; continue }
    # while paused, a heartbeat counts only if its watcher keeps running then (whilePaused: the Watch, memory-truth; TD-EH-26), so a pause
    # is never read as a fault, and a watcher that should still run is never excused by it
    if ($age -gt $late -and (-not $paused -or $h.whilePaused)) { Problem "heartbeat:$($f.BaseName)" 'Claude' "The $($f.BaseName) watcher has not run for $age minutes (it should run every $every)." }
    if ($h.error) { Problem "heartbeat:$($f.BaseName)" 'Claude' "The $($f.BaseName) watcher failed last time: $($h.error)" }
}

# 2. the tick
$checked++
$sup = ReadJson (Join-Path $root 'supervisor.json')
$tickAge = if ($sup) { Mins $sup.lastTick } else { $null }
$notes = [Collections.Generic.List[string]]::new()
if ($paused) {
    # TD-EH-26: paused on purpose is not a fault, but the paused Walkround still minds running work and runs the watchers, so it must keep
    # running: lastTickEnd (every Walkround's end) is checked instead of lastTick (which a pause holds still). No record yet: unknown, said so.
    $endAge = if ($sup) { Mins $sup.lastTickEnd } else { $null }
    if ($null -eq $endAge) { $notes.Add('The Yard is paused; no record of a paused Walkround yet (unknown).') }
    elseif ($endAge -gt 10) { Problem 'tick' 'Claude' "The Yard is paused (that is fine), but its paused Walkround, which still minds running work and runs the watchers, last ran $endAge minutes ago (it runs every minute)." }
} else {
    if ($null -eq $tickAge) { Problem 'tick' 'Claude' 'The kitchen has no record of its last tick (supervisor.json).' }
    elseif ($tickAge -gt 10) { Problem 'tick' 'Claude' "The kitchen's last tick was $tickAge minutes ago (it runs every minute)." }
}

# 3. scheduled tasks
if (-not $NoTasks) {
    # scripts/task-names.json lists each task's [old, new] names (renamed at S4, Jordan's tap); the new ones are read here by name
    $tn = try { Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'scripts\task-names.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
    $roles = @(if ($tn) { foreach ($r in 'supervisor', 'chores', 'board') { ,@($tn.$r | Where-Object { $_ -is [string] -and $_.Trim() }) } })
    $newNames = @($roles | ForEach-Object { $_ } | Where-Object { $_ -notlike 'Kitchen-*' -and $_ -notlike 'Rig-*' })
    $tasks = @()
    if ($env:KITCHEN_WATCH_TASKS) { $tasks = @($env:KITCHEN_WATCH_TASKS | ConvertFrom-Json) }   # tests: [{"name":"Kitchen-X","result":1,"lastRun":"..."}]
    else { try { $tasks = @(@(Get-ScheduledTask -TaskName 'Kitchen-*', 'Rig-*' -ErrorAction Stop) + @(foreach ($n in $newNames) { Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue }) | Sort-Object TaskName -Unique | ForEach-Object { $i = $_ | Get-ScheduledTaskInfo; [pscustomobject]@{ name = $_.TaskName; result = [long]$i.LastTaskResult; lastRun = $i.LastRunTime; state = [string]$_.State } }) } catch { Problem 'tasks' 'Claude' "Could not read the kitchen's scheduled tasks: $($_.Exception.Message)" } }
    # 0 ok, 267009 running now, 267011 not run yet, 267014 stopped by the scheduler at its time limit (a long-running server restarts)
    $okCodes = @(0, 267009, 267011, 267014)
    foreach ($t in $tasks) {
        $checked++
        if ([long]$t.result -notin $okCodes) { Problem "task:$($t.name)" 'Claude' ("The scheduled task $($t.name) last ended with error code 0x{0:X} ({1})." -f [long]$t.result, [long]$t.result) }
        if ([string]$t.state -eq 'Disabled') { Problem "task:$($t.name)" 'Jordan' "The scheduled task $($t.name) is disabled." }
    }
    foreach ($names in $roles) {
        $both = @($names | Where-Object { $_ -in @($tasks.name) })
        if ($both.Count -gt 1) { Problem "task:$($both -join '+')" 'Jordan' "Both $($both -join ' and ') are registered: the same job runs twice. Keep one (the rename is Jordan's call)." }
    }
}

# 4. GitHub sign-in
if (-not $NoGh) {
    $checked++
    $ghCmd = if ($env:KITCHEN_WATCH_GH) { $env:KITCHEN_WATCH_GH } else { 'gh' }
    if (-not (Get-Command $ghCmd -ErrorAction SilentlyContinue)) { Problem 'github' 'Claude' 'The GitHub command (gh) is not installed or not on the path: pull requests and CI checks will fail.' }
    else { $o = & $ghCmd auth status 2>&1 | Out-String; if ($LASTEXITCODE -ne 0) { Problem 'github' 'Jordan' "GitHub sign-in is not working (gh auth status failed): every pull request and CI check will stop. $(($o -split "`r?`n" | Where-Object { $_ -match 'X |error|expired|invalid' } | Select-Object -First 1))".Trim() } }
}

# 5. backups (after 3 am local, last night's copy must exist)
$checked++
$local = [DateTime]::Now; $want = if ($local.Hour -ge 3) { $local.Date } else { $local.Date.AddDays(-1) }
$bdir = Join-Path $root 'backups'
# (the doctor writes backups\daily\yyyyMMdd since 10-23; backups\yyyyMMdd is the older layout it moves over)
$newest = @(Get-ChildItem -LiteralPath $bdir, (Join-Path $bdir 'daily') -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^\d{8}$' | Sort-Object Name -Descending | Select-Object -First 1)
if (-not $newest) { Problem 'backup' 'Claude' 'There is no in-kitchen backup at all (backups\).' }
elseif ([DateTime]::ParseExact($newest[0].Name, 'yyyyMMdd', $null) -lt $want.AddDays(-1)) { Problem 'backup' 'Claude' "The newest in-kitchen backup is from $($newest[0].Name); the doctor should make one every day." }
$kc = ReadJson (Join-Path $root 'kitchen.json')
$dest = if ($env:KITCHEN_WATCH_BACKUP_DEST) { $env:KITCHEN_WATCH_BACKUP_DEST } elseif ($kc -and $kc.backupDest) { [string]$kc.backupDest } else { 'D:\backups\kitchen' }
$checked++
if (-not (Test-Path -LiteralPath $dest)) { Problem 'offsite-backup' 'Jordan' "The off-drive backup folder ($dest) is missing: the nightly copy off the C: drive is not happening." }
else {
    $od = @(Get-ChildItem -LiteralPath $dest -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if (-not $od -or $od[0].LastWriteTime -lt $want.AddDays(-1)) {
        # the nightly off-drive copy is chores work, held while paused (TD-EH-26): said as a note then, not a fault
        if ($paused) { $notes.Add("The Yard is paused: the nightly off-drive copy waits for resume (the newest in $dest is older than two days).") }
        else { Problem 'offsite-backup' 'Claude' "The newest off-drive backup in $dest is older than two days." }
    }
}

$report = [ordered]@{ ok = ($problems.Count -eq 0); at = $now.ToString('o'); mode = $mode; paused = $paused; tickMinutesAgo = $tickAge; checked = $checked; problems = @($problems); notes = @($notes) }
New-Item -ItemType Directory -Force -Path $wd | Out-Null
$hb = [ordered]@{ name = 'watch'; lastRun = $now.ToString('o'); checked = $checked; found = $problems.Count; ms = [int]$t0.ElapsedMilliseconds; everyMin = 60; whilePaused = $true; mode = $mode; paused = $paused; problems = @($problems); notes = @($notes) }
$tmp = Join-Path $wd 'watch.json.tmp'; $hb | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding utf8; Move-Item -LiteralPath $tmp -Destination (Join-Path $wd 'watch.json') -Force
if ($Json) { $report | ConvertTo-Json -Depth 5 -Compress } else { Write-Output "Watch: $mode. Checked $checked. $(if ($problems.Count) { "$($problems.Count) problem(s):" } else { 'All good.' })"; $problems | ForEach-Object { Write-Output "  [$($_.owner)] $($_.say)" }; $notes | ForEach-Object { Write-Output "  note: $_" } }
if ($problems.Count) { exit 3 }
exit 0
