# Kitchen supervisor: a durable, bounded job runner for agent swarms.
# Every job is a list of steps; each step runs as its own worker process. The supervisor never runs work itself: each `tick` reads the
# saved state, checks every worker, kills breaches, retries or quarantines failures, and starts what is next. All state is on disk, so a
# supervisor that dies (or a reboot) loses nothing: the next tick resumes from the last checkpoint. Run `tick` from a scheduled task for 24/7.
#   kitchen.ps1 add -Name <n> -Script <ps1> [-ScriptArgs @{k='v'}] [-Replay safe|unsafe] [-Approve] [-TimeoutSec 300] [-MaxMB 2000]
#                   [-MaxLogMB 50] [-HungSec 0] [-Retries 2]          (HungSec 0 = the 900 s default, -1 = off) (or -SpecPath job.json with {name, steps:[{script,args,replay,...}]})
#   kitchen.ps1 tick                  the supervisor: inbox, then a pass (check workers, start what is next), again at once while a finished
#                                     step's run\WAKE appears (at most 10 passes, 45 s); as its own scheduled process it also waits for wakes
#                                     until 45 s after its start. A second tick touches WAKE and steps aside. It runs the chores itself while
#                                     the Kitchen-Chores task is absent or stale (no chores run started in 5 min).
#   kitchen.ps1 chores                housekeeping on its own clock and lock (TARGET W2): Chef updates, freeze view, CI looks (30 s budget),
#                                     board, report, ledger, doctor, backup, watchdog, standing orders, diagnose, ideas. Never starts a worker.
#                                     While paused (TD-EH-26) only the watchers run: the doctor's findings (doctor -FindOnly), the Watch and
#                                     memory-truth, on their usual hourly clock; nothing that changes work.
#   kitchen.ps1 doctor [-FindOnly]    self-check, backup and cleanup; -FindOnly (and always while paused) only finds: no reset, prune or archive
#   kitchen.ps1 watch [-Seconds 120]  ticks once a second until every job settles or time runs out
#   kitchen.ps1 status [-Json]        jobs, breaker, recent alerts
#   kitchen.ps1 approve -Id J3        says yes to the approval J3 is waiting on (recorded via scripts/approvals.ps1, hash-verified)
#   kitchen.ps1 kill -Id J3 | -All    stops the worker tree; job becomes killed
#   kitchen.ps1 report -HtmlPath x    static status page (no network, no scripts)
#   kitchen.ps1 pause | resume        Jordan stops the supervisor on purpose (a PAUSED file: every tick starts nothing new and only minds
#                                     the running steps and runs the watchers (TD-EH-26), and Chef and
#                                     kitchen-check show 'paused by you' instead of the stopped-ticking alarm) / starts it again
#   kitchen.ps1 pause -Site GW | resume -Site GW   the Owner stops one Site (TD-8, a PAUSED-GW file): only that Site's new starts wait;
#                                     its running work, the watchers and every other Site carry on. Needs the Sites registry (kitchen.json
#                                     "sites"). The global pause above is unchanged and still wins.
# Safety caps (swarm behaviours): concurrent workers, orders under way (maxLive) and waiting (maxQueued), children per job, agent depth (BRAIN_AGENT_DEPTH; workers get depth+1, depth>=2
# may not add jobs), per-step timeout / memory (whole process tree) / log size / heartbeat, retries with backoff, quarantine, unsafe-replay
# needs a human, and a circuit breaker that stops new starts when most recent steps fail.
# State: %LOCALAPPDATA%\brain-kitchen (override env BRAIN_KITCHEN). events.jsonl is append-only. jobs\ holds the orders in play and
# finished ones of the last 3 days (jobs-index.json caches their status); the doctor moves older finished ones to jobs\archive\yyyy-MM\. Exit: 0 ok, 2 error/refused, 3 depth cap.
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('add', 'tick', 'chores', 'watch', 'status', 'approve', 'kill', 'requeue', 'close', 'report', 'doctor', 'pause', 'resume')][string]$Action,
    [string]$Name = '', [string]$Script = '', [hashtable]$ScriptArgs = @{}, [ValidateSet('safe', 'unsafe')][string]$Replay = 'safe',
    [switch]$Approve, [string]$SpecPath = '', [int]$TimeoutSec = 300, [int]$MaxMB = 2000, [int]$MaxLogMB = 50, [int]$HungSec = 0, [int]$Retries = 2,
    [string]$Id = '', [switch]$All, [switch]$Json, [int]$Seconds = 120, [string]$HtmlPath = '',
    [string]$Why = '',   # close: why a set-aside order is closed for good
    [switch]$FindOnly,   # doctor: findings only (TD-EH-26; always so while paused): nothing reset, pruned, archived or moved
    [string]$Site = '',   # pause / resume: one Site's code (TD-8), for that Site only
    [string]$ReplacedBy = '', [string]$Proof = '',   # close: the order that replaces it, or proof it was done another way (no silent endings)
    [string]$ApprovalId = '',   # approve: sign off only if this is still the job's ask (Chef sends the one Jordan was shown)
    [int]$MaxConcurrent = 4, [int]$MaxLive = 100, [int]$MaxQueued = 2000, [int]$MaxJobs = 0, [int]$MaxChildren = 5, [int]$BackoffBaseSec = 2,
    [int]$BreakerWindow = 10, [int]$BreakerMin = 6, [double]$BreakerRate = 0.5, [int]$BreakerCoolSec = 300, [switch]$Quiet,
    [string]$MustMatch = '', [string]$MustNotMatch = '', [double]$DailyBudgetUsd = 20
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($(if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }))
# a test suite (the tests and mutate stations set KITCHEN_UNDER_TEST) never touches Jordan's live kitchen, even if it blanked BRAIN_KITCHEN
if ($env:KITCHEN_UNDER_TEST -eq '1' -and $root -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))) { Write-Output 'ERROR: under test: refusing to use the live kitchen (set BRAIN_KITCHEN to a test folder)'; exit 2 }
$jobsDir = Join-Path $root 'jobs'; $runDir = Join-Path $root 'run'
New-Item -ItemType Directory -Force -Path $jobsDir, $runDir | Out-Null
$eventsPath = Join-Path $root 'events.jsonl'; $alertsPath = Join-Path $root 'alerts.jsonl'; $metaPath = Join-Path $root 'supervisor.json'
$approvalsPath = Join-Path $root 'approvals.md'
$approvalsPs = Join-Path $PSScriptRoot '..\scripts\approvals.ps1'
$runner = Join-Path $PSScriptRoot 'kitchen-step.ps1'
$notify = Join-Path $PSScriptRoot 'notify.ps1'
$pwsh = (Get-Process -Id $PID).Path
$terminal = 'done', 'failed', 'quarantined', 'killed', 'closed'
. (Join-Path $PSScriptRoot 'start-order.ps1')   # which pending order starts first (Sort-ForStart): under way, then priority, then a fair share between Sites (registry only), then oldest
. (Join-Path $PSScriptRoot 'clash.ps1')   # the clash rule: an order naming a file a started order names waits (Hold-ForClash)
. (Join-Path $PSScriptRoot 'jobs-lib.ps1')   # the job store's live set: jobs-index.json, the archive, the only listing of jobs\
. (Join-Path $PSScriptRoot 'site-registry.ps1')   # the one Sites registry reader (kitchen.json "sites"): admission, Stop-work and pause per Site, status, doctor
. (Join-Path $PSScriptRoot 'freeze-lib.ps1')   # merge freeze windows per repo (kitchen.repo.json "freeze"): status lines and Chef's freeze.json
. (Join-Path $PSScriptRoot 'scaler.ps1')   # admission: the RAM-scaled limit (scaler.json) and each station's measured weight (weights.json)
. (Join-Path $PSScriptRoot 'backoff-lib.ps1')   # the Stop-work order's hysteresis and retry back-off (TD-EH-07/08), pure functions
. (Join-Path $PSScriptRoot 'train.ps1')   # the merge train per repo: a merge step waits (no worker, no slot) while its repo's train is busy

# ---- settings: kitchen.json next to this script, then one in the state folder; parameters given on the command line win ----
$config = @{}
foreach ($cp in (Join-Path $PSScriptRoot 'kitchen.json'), (Join-Path $root 'kitchen.json')) {
    if (Test-Path -LiteralPath $cp) { try { $c = Get-Content -LiteralPath $cp -Raw | ConvertFrom-Json -AsHashtable; foreach ($key in $c.Keys) { $config[$key] = $c[$key] } } catch { } }
}
$fromConfig = @{ DailyBudgetUsd = 'dailyBudgetUsd'; MaxConcurrent = 'maxConcurrent'; MaxLive = 'maxLive'; MaxQueued = 'maxQueued'; MaxChildren = 'maxChildren' }
foreach ($p in $fromConfig.Keys) { if (-not $PSBoundParameters.ContainsKey($p) -and $null -ne $config[$fromConfig[$p]]) { Set-Variable -Name $p -Value $config[$fromConfig[$p]] } }
# maxJobs (until 10-23 one cap of 100 orders alive, with adds past it refused) now means maxLive, the orders under way at once; waiting
# orders queue up to maxQueued instead of being refused (TARGET W3, data-growth R4). -MaxJobs and a kitchen.json maxJobs still work.
if ($PSBoundParameters.ContainsKey('MaxJobs')) { if (-not $PSBoundParameters.ContainsKey('MaxLive')) { $MaxLive = $MaxJobs } }
elseif ($null -ne $config.maxJobs -and $null -eq $config.maxLive -and -not $PSBoundParameters.ContainsKey('MaxLive')) { $MaxLive = [int]$config.maxJobs }
if ($config.breaker -is [hashtable]) {
    foreach ($pair in @(@('BreakerWindow', 'window'), @('BreakerMin', 'min'), @('BreakerRate', 'rate'), @('BreakerCoolSec', 'coolSec'))) {
        if (-not $PSBoundParameters.ContainsKey($pair[0]) -and $null -ne $config.breaker[$pair[1]]) { Set-Variable -Name $pair[0] -Value $config.breaker[$pair[1]] }
    }
}
# the Stop-work order's settings (kitchen.json breaker; -Breaker* parameters win) and the retry back-off (kitchen.json backoff). The old
# backoffBaseSec key (2 s, then 4 s: TD-EH-08) is no longer read; only an explicit -BackoffBaseSec (demos, tests) sets both floors in seconds.
$script:breakerCfg = Get-BreakerSettings $config.breaker
$script:breakerCfg.window = $BreakerWindow; $script:breakerCfg.min = $BreakerMin; $script:breakerCfg.rate = $BreakerRate; $script:breakerCfg.coolSec = $BreakerCoolSec
$script:breakerCfg.coolMaxSec = [math]::Max([double]$script:breakerCfg.coolMaxSec, [double]$BreakerCoolSec)
$script:backoffCfg = Get-BackoffSettings $config.backoff $(if ($PSBoundParameters.ContainsKey('BackoffBaseSec')) { $BackoffBaseSec } else { 0 })
# Stations: a step may name a station instead of a script path. Named in kitchen.json, or any kitchen/stations/<name>.ps1.
function Resolve-Station([string]$name) {
    if ($name -notmatch '^[\w-]{1,40}$') { throw "station name not allowed: $name" }
    if ($config.stations -is [hashtable] -and $config.stations[$name]) { $p = Join-Path $PSScriptRoot $config.stations[$name] }
    else { $p = Join-Path $PSScriptRoot "stations\$name.ps1" }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "no station named '$name'" }
    (Resolve-Path -LiteralPath $p).Path
}

function Station-Name($s) { ([IO.Path]::GetFileNameWithoutExtension([string]$s.script)) -replace '^agent-step$', 'agent' -replace '^demo-worker$', 'demo' }
function Die([string]$m, [int]$code = 2) { Write-Output "ERROR: $m"; exit $code }
function Sha([string]$t, [int]$n = 12) { $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t)); (($h | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, $n) }
function Now { [DateTime]::UtcNow }
# a scheduled task by its role (supervisor, chores, board) from scripts/task-names.json, which lists [old, new] names: the newest one
# registered wins (the rename to the new names is S4, Jordan's tap). A missing or broken file means the old name. Read-only.
function Find-KitchenTask([string]$Role, [string]$Path = (Join-Path (Split-Path $PSScriptRoot) 'scripts\task-names.json'), [scriptblock]$Get = { param($n) Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue }) {
    $names = @(try { (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json).$Role | Where-Object { $_ -is [string] -and $_.Trim() } } catch { })
    if (-not $names.Count) { $names = @(@{ supervisor = 'Kitchen-Supervisor'; chores = 'Kitchen-Chores'; board = 'Kitchen-Pass' }[$Role]) }
    for ($i = $names.Count - 1; $i -ge 0; $i--) { $t = & $Get $names[$i]; if ($t) { return $t } }
    $null
}
# ConvertFrom-Json turns ISO strings into DateTime on its own; accept either form and always compare in UTC
function ToUtc($v) { if ($v -is [DateTime]) { $v.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } }
function Iso([DateTime]$d) { $d.ToString('o') }
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }
# A line cut to fit $max characters on a word boundary, with '...' where it was cut (TD-EH-06: a Sign-off once ended "a cloud cook t").
# A single word longer than $max is the only thing ever cut inside a word.
function Cut-Words([string]$t, [int]$max) {
    $t = ([string]$t -replace '\s+', ' ').Trim()
    if ($t.Length -le $max) { return $t }
    $n = [math]::Max(1, $max - 3); $head = $t.Substring(0, $n)
    if ($t[$n] -ne ' ') { $sp = $head.LastIndexOf(' '); if ($sp -gt 0) { $head = $head.Substring(0, $sp) } }   # (the cut fell inside a word)
    $head.TrimEnd(' ', ',', ';', ':', '-') + '...'
}
# A step silent this long (no heartbeat, log line or cook activity) is hung, when its recipe sets no hungSec of its own (10-22: J207
# held a slot for 2.5 h with hung checks off). KITCHEN_HUNG_DEFAULT_SEC stands in for it in tests.
$DefaultHungSec = if ([int]$env:KITCHEN_HUNG_DEFAULT_SEC -gt 0) { [int]$env:KITCHEN_HUNG_DEFAULT_SEC } else { 900 }

# ---- the tick clock: sleep is measured from when this tick's process started (not from the locked pass, which a slow freeze view or CI
# look delayed into a false "the PC slept"), against the previous tick's recorded end. Each phase is timed; a tick slower than
# KITCHEN_TICK_SLOW_SEC (60 s) logs tick.slow {sec, phase, phaseSec} with its slowest phase. KITCHEN_TICK_FROM stands in for the start in tests.
$script:tickFrom = $null; $script:tickMark = $null; $script:tickPhases = $null; $script:gapFrom = $null
function Start-TickClock {
    $script:tickFrom = if ($script:tickPhases) { Now } elseif ($env:KITCHEN_TICK_FROM) { ToUtc $env:KITCHEN_TICK_FROM } else { [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime() }
    $script:tickMark = $script:tickFrom; $script:tickPhases = [ordered]@{}; $script:gapFrom = $script:tickFrom
    Tick-Phase 'start'   # pwsh start-up and the wait for the tick lock
}
function Tick-Phase([string]$name) {
    if ($null -eq $script:tickPhases) { return }
    $n = Now; $script:tickPhases[$name] = [double]$script:tickPhases[$name] + ($n - $script:tickMark).TotalSeconds; $script:tickMark = $n
}
function Finish-Tick {
    Tick-Phase 'end'
    try { [IO.File]::Delete($script:tickBeganPath) } catch { }   # (this Walkround reached its end: Mark-TickBegan)
    $sec = ((Now) - $script:tickFrom).TotalSeconds - [double]$script:tickPhases['linger']   # (waiting for a wake is not slowness)
    $slowSec = if ($env:KITCHEN_TICK_SLOW_SEC -match '^\d+$') { [int]$env:KITCHEN_TICK_SLOW_SEC } else { 60 }
    Enter-State
    try {
        $m = Load-Meta; $m.lastTickEnd = Iso (Now); Save-Meta $m
        if ($script:passes -gt 1) { Emit 'tick.drained' '' @{ passes = $script:passes; stop = [string]$script:drainStop } }
        if ($sec -gt $slowSec) {
            $top = @($script:tickPhases.GetEnumerator() | Where-Object Key -ne 'linger' | Sort-Object Value -Descending)[0]
            Emit 'tick.slow' '' @{ sec = [int]$sec; phase = [string]$top.Key; phaseSec = [int]$top.Value }
        }
    } finally { Exit-State }
}

# A Walkround (the tick action, holding the tick lock) writes when it began to run\TICK-BEGAN and Finish-Tick deletes it. One still there
# when the next Walkround takes the tick lock never reached its end: the scheduled task's 5-minute limit or a restart cut it off, maybe
# with its workers. Logged as tick.stopped {began, ageSec}; Get-CrashWhy names it for a worker that died without an exit code (TD-EH-20).
$script:tickBeganPath = Join-Path $runDir 'TICK-BEGAN'
function Mark-TickBegan {
    $prev = try { ([string][IO.File]::ReadAllText($script:tickBeganPath)).Trim() } catch { '' }
    if ($prev) {
        $age = try { [int]((Now) - (ToUtc $prev)).TotalSeconds } catch { -1 }
        Emit 'tick.stopped' '' @{ began = $prev; ageSec = $age; note = 'a Walkround was cut off before its end (the task limit or a restart)' }
    }
    try { [IO.File]::WriteAllText($script:tickBeganPath, (Iso $script:tickFrom)) } catch { }
}

# ---- one state lock per kitchen root (named mutex; an abandoned lock from a dead supervisor is taken over) ----
$mutex = New-Object Threading.Mutex($false, "Global\brain-kitchen-$(Sha $root.ToLowerInvariant())")
function Enter-State([int]$ms = 30000) { try { if (-not $mutex.WaitOne($ms)) { Die "kitchen state is busy (lock not free within $([int]($ms / 1000))s)" } } catch [Threading.AbandonedMutexException] { } }
function Exit-State { try { Save-KitchenJobsIndex $root } catch { }; try { $mutex.ReleaseMutex() } catch { } }   # (with the jobs-index.json entries Save-Job changed)

function Emit([string]$type, [string]$job = '', [hashtable]$data = @{}) {
    $e = [ordered]@{ ts = Iso (Now); type = $type; job = $job }
    foreach ($k in $data.Keys) { $e[$k] = $data[$k] }
    # Emit never throws: verify, talk and the Chef server append to this log without the kitchen lock, so a busy file is retried and,
    # as a last resort, the line goes to events-pending-<pid>.jsonl (still read for today's spend; Site cleanup folds it back, TD-EH-18). A throwing Emit used to abort a tick
    # between starting a worker and saving its pid, leaving the worker unsupervised and the step started twice.
    try {
        $line = $e | ConvertTo-Json -Compress -Depth 6
        if ((Test-Path -LiteralPath $eventsPath) -and (Get-Item -LiteralPath $eventsPath).Length -gt 20MB) {   # rotate; old logs are kept
            try { Move-Item -LiteralPath $eventsPath -Destination (Join-Path $root ("events-{0:yyyyMMddHHmmss}.jsonl" -f (Get-Date))) -Force } catch { }
        }
        for ($i = 0; $i -lt 6; $i++) { try { Add-Content -LiteralPath $eventsPath -Value $line -Encoding utf8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds (50 + (Get-Random -Maximum 150)) } }
        Add-Content -LiteralPath (Join-Path $root "events-pending-$PID.jsonl") -Value $line -Encoding utf8 -ErrorAction Stop
    } catch { }
}
# Every alert line says whether it reached the phone (TD-EH-04 "Sent or not"): sent = ok, off (phone alerts are off), failed (ntfy error,
# with its HTTP status), limited (ntfy's rate limit) or held (the tick sends it once it lets go of the lock; the result follows as an
# alert.sent event). The why is notify.ps1's fixed words, never the text again. The 'alert' event carries the same sent/why.
# $detail (TD-EH-05: what failed) goes on the alerts.jsonl line and the event after the text, never to notify.ps1: the push is made from
# $text alone, so a log line can neither leave this PC nor change the kind of news the push names.
function Alert([string]$level, [string]$text, [string]$job = '', [string]$detail = '') {
    $a = [ordered]@{ ts = Iso (Now); level = $level; job = $job; text = $(if ($detail) { "$text Why: $detail" } else { $text }) }
    $r = if ($null -ne $script:deferNotify) { Send-Notify $level $text -Check } else { Send-Notify $level $text }
    if ($null -ne $script:deferNotify -and $r.sent -eq 'ready') { $r = @{ sent = 'held'; why = 'sent when the Walkround lets go of the lock' } }
    $a.sent = [string]$r.sent; if ($r.why) { $a.why = [string]$r.why }; if ($r.http) { $a.http = [int]$r.http }
    for ($i = 0; $i -lt 6; $i++) { try { Add-Content -LiteralPath $alertsPath -Value ($a | ConvertTo-Json -Compress) -Encoding utf8 -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds (50 + (Get-Random -Maximum 150)) } }
    $ev = @{ level = $level; text = $a.text; sent = $a.sent }; if ($a.why) { $ev.why = $a.why }
    Emit 'alert' $job $ev
    if ($a.sent -eq 'held') { $script:deferNotify.Add(@($level, $text, $a.ts, $job)) }   # the tick sends these after Exit-State
}
# a held alert (TD-EH-04), sent after the tick let go of the lock: its result is the alert.sent event {alertTs, level, sent, why?, http?}
function Send-HeldAlert($n) {
    $r = Send-Notify $n[0] $n[1]; $d = @{ alertTs = $n[2]; level = $n[0]; sent = [string]$r.sent }
    if ($r.why) { $d.why = [string]$r.why }; if ($r.http) { $d.http = [int]$r.http }
    Emit 'alert.sent' $n[3] $d
}
# notify.ps1's answer as {sent, why?, http?} (its last JSON line); a missing or crashed notify.ps1 is a failed send, never a silent one
# (notify.ps1's exit code is put back as it was: a caller reading LASTEXITCODE after an alert sees what it saw before)
function Send-Notify([string]$level, [string]$text, [switch]$Check) { $keep = $global:LASTEXITCODE; try { if (-not (Test-Path -LiteralPath $notify)) { return @{ sent = 'failed'; why = 'notify.ps1 is missing' } }; Read-NotifyAnswer @(& $notify -Level $level -Text $text -Check:$Check 2>$null) } catch { @{ sent = 'failed'; why = 'notify.ps1 failed' } } finally { $global:LASTEXITCODE = $keep } }
function Read-NotifyAnswer([object[]]$out) {
    $line = @($out | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\{.*"sent"' })[-1]
    $r = try { $line | ConvertFrom-Json -AsHashtable } catch { $null }
    if (-not $r -or $r.sent -notin 'ok', 'ready', 'off', 'failed', 'limited') { return @{ sent = 'failed'; why = 'notify.ps1 gave no answer' } }
    $r
}
$script:deferNotify = $null; $script:amPre = @{}

function Job-Path([string]$jid) { Join-Path $jobsDir "$jid.json" }
function Load-Job([string]$jid) { Get-Content -LiteralPath (Job-Path $jid) -Raw | ConvertFrom-Json -AsHashtable }
# write-then-rename: a crash mid-write leaves the old file whole. A reader holding the file open (status, the Chef server) only
# delays the rename, so it is retried for ~2 s before giving up (the temp file is removed then; the old file stays whole).
function Move-Into([string]$tmp, [string]$dest) {
    for ($i = 0; ; $i++) {
        try { [IO.File]::Move($tmp, $dest, $true); return }
        catch { if ($i -ge 20) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw }; Start-Sleep -Milliseconds (50 + (Get-Random -Maximum 100)) }
    }
}
function Save-Job($j) {
    $p = Job-Path $j.id; $t = "$p.tmp-$PID"
    $j | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $t -Encoding utf8
    Move-Into $t $p
    Set-KitchenJobsIndexEntry $root $j   # its jobs-index.json entry, written at Exit-State
}
# A damaged job file must never take the supervisor down: it is moved to corrupt\ (kept for inspection) and Jordan is alerted.
$corruptDir = Join-Path $root 'corrupt'
# Every job in jobs\ (oldest first), or with -Live only the orders still in play (not done or closed, or with a Chef update to run).
# jobs-index.json (kitchen/jobs-lib.ps1) knows which files are finished without opening them; a file whose size or write time changed
# is read again, and a missing or damaged index is rebuilt from the files and logged (jobs.index.rebuilt).
function All-Jobs([switch]$Live) {
    $r = Update-KitchenJobs $root $(if ($Live) { 'live' } else { 'all' }) -Trace $Action -RequireSteps -OnDamaged {
        param($f, $why)
        New-Item -ItemType Directory -Force -Path $corruptDir | Out-Null
        try { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $corruptDir ("{0}-{1:yyyyMMddHHmmss}.json" -f $f.BaseName, (Get-Date))) -Force } catch { }
        Alert 'HIGH' "Job file $($f.Name) was damaged and set aside in corrupt\ ($why). Restore from backups\ if needed." $f.BaseName
    }
    if ($r.rebuilt) { Emit 'jobs.index.rebuilt' '' @{ reason = $r.rebuilt; jobs = $r.index.Count; read = $r.read } }
    $r.jobs
}
# The next order number, from jobs\next-id.txt, never trusted blindly: a number already used in jobs\, the archive or corrupt\ moves it
# on, and a missing or unreadable counter is rebuilt from all three. An id is never given twice, not even one an archived order had.
function Next-Id {
    $ad = Get-JobsArchiveDir $root; $n = 0
    $txt = try { [IO.File]::ReadAllText((Join-Path $jobsDir 'next-id.txt')) } catch { '' }
    $ok = [int]::TryParse($txt.Trim(), [ref]$n) -and $n -gt 0
    # never below jobs\ and corrupt\ (cheap to list), so a counter restored from an old copy cannot reuse an order still here
    $top = 0; $jf = Get-JobFiles $root; if ($jf.Count) { $top = [int]$jf[-1].BaseName.Substring(1) }
    $dirs = @($corruptDir); if (-not $ok) { $dirs += $ad }   # (a counter that is gone or unreadable: the whole archive too)
    foreach ($d in $dirs) { if ([IO.Directory]::Exists($d)) { foreach ($f in [IO.Directory]::EnumerateFiles($d, 'J*.json', 'AllDirectories')) { if ([IO.Path]::GetFileName($f) -match '^J(\d+)') { $top = [math]::Max($top, [int]$Matches[1]) } } } }
    if (-not $ok) { foreach ($x in (Read-KitchenJobArchive $root).Keys) { $top = [math]::Max($top, [int]$x.Substring(1)) } }
    $n = [math]::Max($n, $top + 1)
    $months = if ([IO.Directory]::Exists($ad)) { [IO.Directory]::GetDirectories($ad) } else { @() }
    while ([IO.File]::Exists((Job-Path "J$n")) -or @($months | Where-Object { [IO.File]::Exists((Join-Path $_ "J$n.json")) }).Count) { $n++ }
    $n
}
function Save-NextId([int]$n) { $cp = Join-Path $jobsDir 'next-id.txt'; $t = "$cp.tmp-$PID"; [IO.File]::WriteAllText($t, "$n"); Move-Into $t $cp }
function Get-Depth { $d = $env:BRAIN_AGENT_DEPTH; if ([string]::IsNullOrEmpty($d)) { return 0 }; $n = 0; if ([int]::TryParse($d, [ref]$n) -and $n -ge 0) { return $n }; return -1 }

# ---- processes: identity is pid + start time (a reused pid is not our worker) ----
function Start-Ms($p) { [DateTimeOffset]::new($p.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() }
function Is-Alive([int]$procId, [long]$startMs) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    try { return [math]::Abs((Start-Ms $p) - $startMs) -lt 2000 } catch { return $false }
}
# A child must start after its parent: Windows reuses a dead parent's pid, and without this check an unrelated
# process was summed into a step (seen 10-22: LightStudio-background.exe in J234's tree) and can trip memcap.
function Tree-MB([int]$rootId, $procs) {
    $born = @{}; foreach ($p in $procs) { $born[[int]$p.ProcessId] = $p.CreationDate }
    $ids = [Collections.Generic.HashSet[int]]::new(); [void]$ids.Add($rootId); $grew = $true
    while ($grew) { $grew = $false; foreach ($p in $procs) {
        $pp = [int]$p.ParentProcessId; $me = [int]$p.ProcessId
        if (-not $ids.Contains($pp) -or $ids.Contains($me)) { continue }
        if ($p.CreationDate -and $born[$pp] -and $p.CreationDate -lt $born[$pp]) { continue }
        [void]$ids.Add($me); $grew = $true } }
    $sum = 0.0; foreach ($p in $procs) { if ($ids.Contains([int]$p.ProcessId)) { $sum += $p.WorkingSetSize } }
    $sum / 1MB
}
function Kill-Tree([int]$procId) { & taskkill.exe /T /F /PID $procId 2>&1 | Out-Null }

# ---- approvals: reuse the hash-verified queue (scripts/approvals.ps1) with the kitchen's own file ----
function Request-Approval($j, [string]$text, [string]$level) {
    $text = ($text -replace '[|\r\n]', ' ')
    $wasFailed = [bool]($j.approval -and $j.approval.failed)
    $j.approval = $null   # an older yes, even one for this same step, must never stand in for this new question
    $out = & $approvalsPs add -ApprovalsPath $approvalsPath -Level $level -Text $text | Out-String
    $m = [regex]::Match($out, 'added (A\d+)')
    if (-not $m.Success) {
        # remembered as failed (approvals lock busy, text too long or refused by the secret filter): the tick asks again with a
        # contents-free text, instead of leaving the job stuck with nothing to answer. Jordan is told once, not every tick.
        $j.approval = @{ id = ''; failed = $true; text = ''; cursor = $j.cursor; attempt = $j.attempt; granted = $false; level = $level }
        Emit 'approval.failed' $j.id @{ detail = $out.Trim() }
        if (-not $wasFailed) { Alert 'HIGH' "approval request failed for $($j.id); it is asked again on the next tick" $j.id }
        return
    }
    $j.approval = @{ id = $m.Groups[1].Value; text = $text; cursor = $j.cursor; attempt = $j.attempt; granted = $false }
    Emit 'approval.requested' $j.id @{ approval = $m.Groups[1].Value; text = $text }
    Alert $level "$($j.id) needs your yes ($($m.Groups[1].Value)): $text" $j.id
}
# a step's args as one line Jordan can read (sorted, whitespace folded) plus a hash of all of them (the line may be cut to fit)
function Args-Summary($s) {
    $a = if ($s -and $s.args) { $s.args } else { @{} }
    $keys = @(if ($a -is [hashtable]) { $a.Keys } else { $a.PSObject.Properties.Name }) | Sort-Object
    $parts = @(foreach ($k in $keys) { "$k=" + ([string]$a.$k -replace '\s+', ' ').Trim() })
    $full = [ordered]@{}; foreach ($k in $keys) { $full[$k] = [string]$a.$k }
    @{ text = ($parts -join '; '); sha = (Sha ($full | ConvertTo-Json -Compress) 10) }
}
function Approval-Granted($j) {
    if (-not $j.approval -or [int]$j.approval.cursor -ne [int]$j.cursor) { return $false }   # a yes covers only the step it was asked for
    if ($j.approval.failed) { return $false }   # a request that never reached the queue has nothing to say yes to
    if ($j.approval.argsSha -and $j.approval.argsSha -ne (Args-Summary $j.steps[$j.cursor]).sha) { return $false }   # the args he saw changed since
    if ($j.approval.granted) { return $true }   # memo: a yes is remembered across restarts and never asked twice
    & $approvalsPs verify -ApprovalsPath $approvalsPath -Id $j.approval.id -Text $j.approval.text | Out-Null
    if ($LASTEXITCODE -eq 0) { $j.approval.granted = $true; Emit 'approval.granted' $j.id @{ approval = $j.approval.id }; return $true }
    return $false
}

# ---- circuit breaker over the most recent step outcomes ----
# supervisor.json is read defensively: an empty or torn file (power lost mid-write before writes were atomic, a disk hiccup) is set
# aside in corrupt\ and the kitchen carries on with fresh settings; it never stops every tick from then on. A file that is only
# busy (another reader) is retried, never mistaken for damage.
function Load-Meta {
    if (-not (Test-Path -LiteralPath $metaPath)) { return @{} }
    $raw = $null
    for ($i = 0; ; $i++) { try { $raw = [IO.File]::ReadAllText($metaPath); break } catch { if (-not (Test-Path -LiteralPath $metaPath)) { return @{} }; if ($i -ge 20) { throw }; Start-Sleep -Milliseconds 100 } }
    try { $m = $raw | ConvertFrom-Json -AsHashtable; if ($m -is [hashtable]) { return $m }; throw 'empty or not an object' }
    catch {
        $why = "$($_.Exception.Message)"; if ($why.Length -gt 120) { $why = $why.Substring(0, 120) }
        try { New-Item -ItemType Directory -Force -Path $corruptDir | Out-Null; Move-Item -LiteralPath $metaPath -Destination (Join-Path $corruptDir ("supervisor-{0:yyyyMMddHHmmss}.json" -f (Get-Date))) -Force } catch { }
        try { Alert 'HIGH' "supervisor.json was damaged and was reset (the old copy is in corrupt\): $why" } catch { }
        return @{}
    }
}
function Breaker-State {
    $meta = Load-Meta
    $outcomes = [Collections.Generic.List[object]]::new()   # {ts, job, fail}, oldest first: what the Stop-work order judges (backoff-lib.ps1)
    if (Test-Path -LiteralPath $eventsPath) {
        $tail = try { @(Get-Content -LiteralPath $eventsPath -Tail 500 -ErrorAction Stop) } catch { @() }   # a log busy in another writer never stops the tick
        $key = [DateTime]::MinValue; $late = $false
        foreach ($l in $tail) {
            if ($l -notmatch 'step\.(done|fail|crash|timeout|memcap|logflood|hung|taster)') { continue }   # (cheap skip; the type is checked below)
            try { $e = $l | ConvertFrom-Json } catch { continue }
            if ($e.type -notmatch '^step\.(done|fail|crash|timeout|memcap|logflood|hung|taster)$') { continue }
            # TD-EH-18: lines folded back from events-pending come after newer ones; they are put back in time order, as Update-BreakerState
            # orders them, so status shows the same rate (a line whose time cannot be read keeps its place after the line before it)
            $k = try { $u = ConvertTo-BackoffUtc $e.ts; if ($u) { $u } else { $key } } catch { $key }
            if ($k -lt $key) { $late = $true }; $key = $k
            $outcomes.Add(@{ ts = $e.ts; job = [string]$e.job; fail = [bool]($e.type -ne 'step.done'); k = $k })
        }
        if ($late) { $sorted = @($outcomes | Sort-Object -Stable { $_.k }); $outcomes.Clear(); foreach ($o in $sorted) { $outcomes.Add($o) } }
    }
    $w = Get-BreakerWindow $outcomes.ToArray() $BreakerWindow
    @{ meta = $meta; rate = $w.rate; n = $w.n; outcomes = $outcomes.ToArray() }
}
# The Stop-work order for this pass (TD-EH-07): opens on the same rule, stays open a few minutes (longer each time it re-opens soon after
# closing), closes only when failures are clearly down or a trial step passed. One HIGH alert per open episode and one closed note.
# Returns {open (no new work), probe (one trial step may start)}; the state is meta.breakerEpisode (breakerTripped / breakerOpenUntil kept
# for the Board and status).
function Step-Breaker($meta, $jobs) {
    $b = Breaker-State; $cfg = $script:breakerCfg
    $st = Get-BreakerEpisode $meta $cfg
    $live = $false
    if ($st.probe) { $pj = @($jobs | Where-Object { [string]$_.id -eq [string]$st.probe.job -and $_.status -eq 'running' }); $live = $pj.Count -gt 0 }
    $r = Update-BreakerState $st $b.outcomes (Now) $cfg $live
    $meta.breakerEpisode = $r.st; $meta.breakerTripped = [bool]$r.st.tripped; $meta.breakerOpenUntil = $r.st.openUntil
    Send-BreakerNews $r ''
    $r
}
# The events and alerts of one Stop-work order's look. $Site '' = the whole Yard (the words as before TD-8); a code (or '?', Unassigned)
# = that Site's own order: the events carry site and the alert names the Site and says the other Sites carry on.
function Send-BreakerNews($r, [string]$Site) {
    $mins = Format-WaitMinutes ([double]$r.st.coolSec)
    $tag = @{}; $who = 'No new work'; $other = ''
    if ($Site) { $tag = @{ site = $Site }; $nm = if ($Site -eq '?') { 'Unassigned' } else { $Site }; $who = "No new work of $nm"; $other = ' Other Sites carry on.' }
    $news = { param($t, $d) foreach ($k in $tag.Keys) { $d[$k] = $tag[$k] }; Emit $t '' $d }
    switch ($r.did) {
        'open' {
            & $news 'breaker.open' @{ failRate = [math]::Round($r.rate, 2); window = $r.n; coolSec = [int]$r.st.coolSec; episode = [int]$r.st.n; note = "new work waits $mins" }
            if ($r.alert) { Alert 'HIGH' ("Stop-work order{3}: {0:P0} of the last {1} steps failed. $who starts for {2}; then one trial step runs first.$other" -f $r.rate, $r.n, $mins, $(if ($Site) { " on $nm" } else { '' })) }
        }
        'reopen' { & $news 'breaker.reopen' @{ coolSec = [int]$r.st.coolSec; episode = [int]$r.st.n; reopens = [int]$r.st.reopens; note = "the trial step failed; new work waits $mins" } }
        'probe-lost' { & $news 'breaker.probe' @{ episode = [int]$r.st.n; note = 'the trial step stopped without a result; another may try' } }
        'closed' {
            $openMin = try { [int][math]::Round(((Now) - (ToUtc $r.st.openedAt)).TotalMinutes) } catch { 0 }
            & $news 'breaker.closed' @{ why = [string]$r.st.closeWhy; episode = [int]$r.st.n; failRate = [math]::Round($r.rate, 2); openMin = $openMin; note = $r.why }
            Alert 'INFO' "Stop-work order$(if ($Site) { " on $nm" }) lifted after $openMin min: $($r.why). New work starts again."
        }
    }
}
# ---- TD-8: Stop-work and pause per Site (multi-site design section 5). Only with a Sites registry (kitchen.json "sites"); none = the one
# Yard-wide Stop-work order above and no Site pauses, exactly as before TD-8. Machine-level stops (the global PAUSED, the RAM guard, the
# daily budget) stay global and still win.
function Get-SiteStopKey([string]$Site) { if ($Site) { $Site } else { '?' } }   # '?' = orders with no Site (Unassigned)
# The Sites the Owner stopped (kitchen.ps1 pause -Site X wrote PAUSED-X); a file for a code not in the registry is not read
function Get-SitePauseCodes($Sites) {
    if (-not $Sites.Count) { return @() }
    @(Get-ChildItem -LiteralPath $root -Filter 'PAUSED-*' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Substring(7).ToUpperInvariant() } | Where-Object { $Sites.ContainsKey($_) })
}
# Each step outcome's Site: live orders by their Site (Get-AdmitSite), finished ones by jobs-index.json si (read once, only when needed)
function Get-OutcomeSites($outcomes, $jobs, $Sites) {
    $map = @{}; foreach ($j in $jobs) { $map[[string]$j.id] = Get-AdmitSite $j $Sites }
    $idx = $null
    foreach ($o in $outcomes) {
        $id = [string]$o.job; if ($map.ContainsKey($id)) { continue }
        if ($null -eq $idx) { $ix = Read-JobsIndexFile $root; $idx = if ($ix.ok) { $ix.jobs } else { @{} } }
        $map[$id] = if ($idx[$id] -and $idx[$id].si) { [string]$idx[$id].si } else { '' }
    }
    $map
}
# One Stop-work order per Site, with the same hysteresis as the Yard-wide one (TD-EH-07, backoff-lib.ps1): the outcomes are bucketed by
# the order's Site, so one Site's failures never stop another. State: supervisor.json siteBreakers.<code> (an episode each); the Yard-wide
# breakerTripped is cleared (no Yard-wide order while Sites are on). Returns key -> @{ open; probe } for this pass's starts.
function Step-SiteBreakers($meta, $jobs, $Sites) {
    $b = Breaker-State; $cfg = $script:breakerCfg
    $map = Get-OutcomeSites $b.outcomes $jobs $Sites
    $prev = if ($meta.siteBreakers -is [Collections.IDictionary]) { $meta.siteBreakers } else { @{} }
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in @($Sites.Keys) + @($prev.Keys) + @($map.Values | ForEach-Object { Get-SiteStopKey $_ })) { [void]$keys.Add([string]$c) }
    $states = @{}; $out = @{}
    foreach ($k in $keys) {
        $st = Get-BreakerEpisode @{ breakerEpisode = $prev[$k] } $cfg
        $live = $false
        if ($st.probe) { $live = @($jobs | Where-Object { [string]$_.id -eq [string]$st.probe.job -and $_.status -eq 'running' }).Count -gt 0 }
        $mine = @($b.outcomes | Where-Object { (Get-SiteStopKey $map[[string]$_.job]) -eq $k })
        $r = Update-BreakerState $st $mine (Now) $cfg $live
        Send-BreakerNews $r $k
        if ($r.st.tripped -or $r.st.n) { $states[$k] = $r.st }   # (a Site that never tripped keeps no record)
        $out[$k] = @{ open = [bool]$r.open; probe = [bool]$r.probe }
    }
    $meta.siteBreakers = $states; $meta.breakerTripped = $false; $meta.breakerOpenUntil = $null
    $out
}
# This pass's stop rules: Sites registered = per-Site Stop-work orders (siteBk) and the Sites the Owner stopped (held); none = the
# Yard-wide order (open, probe), exactly as before TD-8
function Get-StopWorkPlan($meta, $jobs) {
    $reg = (Get-YardSites $root).sites
    if ($reg.Count) { return @{ open = $false; probe = $false; siteBk = (Step-SiteBreakers $meta $jobs $reg); held = @(Get-SitePauseCodes $reg) } }
    $bk = Step-Breaker $meta $jobs; @{ open = [bool]$bk.open; probe = [bool]$bk.probe; siteBk = $null; held = @() }
}
# an order's Site is stopped by the Owner, or that Site's own Stop-work order is open (or its one trial step already started)
function Test-SiteHeld($plan, [string]$Site) {
    if (-not $plan.siteBk) { return $false }
    if ($Site -and $plan.held -contains $Site) { return $true }
    $sb = $plan.siteBk[(Get-SiteStopKey $Site)]; [bool]($sb -and $sb.open)
}
# a step just started while its Site's Stop-work order is cooling: it is that Site's one trial step; its other orders wait for it
function Set-SiteProbe($plan, $meta, [string]$Site, $j) {
    if (-not $plan.siteBk) { return }
    $sk = Get-SiteStopKey $Site; $sb = $plan.siteBk[$sk]
    if (-not ($sb -and $sb.probe -and $meta.siteBreakers[$sk])) { return }
    $meta.siteBreakers[$sk].probe = @{ job = [string]$j.id; at = Iso (Now) }; $sb.open = $true
    Emit 'breaker.probe' $j.id @{ step = $j.cursor; site = $sk; episode = [int]$meta.siteBreakers[$sk].n; note = "one trial step runs before $sk's new work starts again" }
}
# pause / resume -Site: the code checked (2-3 letters); pause also needs it in the registry, so a typo never stops nothing quietly
function Resolve-PauseSite([string]$Code, [bool]$MustBeListed) {
    $c = $Code.Trim().ToUpperInvariant()
    if ($c -notmatch '^[A-Z]{2,3}$') { Die "'$Code' is not a Site code (2-3 letters, like GW)" }
    if ($MustBeListed) {
        $reg = (Get-YardSites $root).sites
        if (-not $reg.Count) { Die "no Sites are registered (kitchen.json `"sites`"), so there is no Site to stop; kitchen.ps1 pause stops the whole Yard" }
        if (-not $reg.ContainsKey($c)) { Die "Site $c is not in the Sites registry (kitchen.json `"sites`": $(@($reg.Keys | Sort-Object) -join ', '))" }
    }
    $c
}
# kitchen.ps1 status: each Site stopped by the Owner (PAUSED-<code>) or under its own Stop-work order (supervisor.json siteBreakers),
# as @{ site; paused; stopWork; until }, Sites by code ('?' = Unassigned). @() with no registry: status then prints what it did before TD-8.
function Get-SiteStopState($meta) {
    $reg = (Get-YardSites $root).sites
    if (-not $reg.Count) { return @() }
    $held = @(Get-SitePauseCodes $reg); $sb = if ($meta.siteBreakers -is [Collections.IDictionary]) { $meta.siteBreakers } else { @{} }
    @(foreach ($k in @(@($reg.Keys) + @($sb.Keys) | Sort-Object -Unique)) {
            $e = $sb[$k]; $open = [bool]($e -is [Collections.IDictionary] -and $e.tripped); $paused = $held -contains $k
            if ($paused -or $open) { [ordered]@{ site = [string]$k; paused = $paused; stopWork = $open; until = $(if ($open -and $e.openUntil) { [string]$e.openUntil } else { $null }) } }
        })
}
function Format-SiteStopLine($x) {
    $name = if ($x.site -eq '?') { 'UNASSIGNED' } else { "SITE $($x.site)" }
    $bits = @()
    if ($x.paused) { $bits += "stopped by you: none of its new work starts until 'kitchen.ps1 resume -Site $($x.site)'" }
    if ($x.stopWork) { $u = if ($x.until) { ToUtc $x.until } else { $null }; $bits += "Stop-work order on: $(if ($u -and $u -gt (Now)) { "no new work for $(Format-WaitMinutes ($u - (Now)).TotalSeconds) more" } else { 'one trial step runs before new work starts again' })" }
    "  $($name): $($bits -join '; '). The other Sites carry on"
}
function Save-Meta($meta) { $t = "$metaPath.tmp-$PID"; $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $t -Encoding utf8; Move-Into $t $metaPath }   # atomic, like jobs

# TD-EH-20: a worker gone without an exit code says why it might be: its last non-empty log line, and whether in the last 5 minutes
# the PC slept (supervisor.resumed) or a Walkround was cut off before its end (tick.stopped: the scheduled task's 5-minute limit, or a
# restart, ends the Walkround and can take its workers with it).
function Get-CrashWhy([string]$base) {
    $t = 'worker died without an exit code'
    $line = @(Get-Content -LiteralPath "$base.log" -Tail 20 -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() }) | Select-Object -Last 1
    $t += if ($line) { '; last log line: ' + (Cut-Words $line 160) } else { '; its log is empty' }
    $seen = @()
    $tail = if (Test-Path -LiteralPath $eventsPath) { try { @(Get-Content -LiteralPath $eventsPath -Tail 400 -ErrorAction Stop) } catch { @() } } else { @() }
    foreach ($l in $tail) {
        if ($l -notmatch '"type":"(supervisor\.resumed|tick\.stopped)"') { continue }   # (cheap skip)
        $e = try { $l | ConvertFrom-Json } catch { $null }
        if (-not $e) { continue }
        $ago = try { ((Now) - (ToUtc $e.ts)).TotalMinutes } catch { 99 }
        if ($ago -gt 5) { continue }
        $min = [int][math]::Floor([math]::Max(0, $ago))
        $seen += if ($e.type -eq 'supervisor.resumed') { "the PC slept $min min ago (asleep $([int]$e.gapSec) s)" } else { "a Walkround was cut off $min min ago (the task's 5-min limit or a restart)" }
    }
    $t + '; ' + $(if ($seen.Count) { @($seen | Select-Object -Unique) -join '; ' } else { 'no PC sleep and no cut-off Walkround in the last 5 min' })
}

# ---- failures: retry with backoff, quarantine repeat offenders, never silently replay an unsafe step ----
function Fail-Step($j, [string]$kind, [string]$detail) {
    $s = $j.steps[$j.cursor]
    $runBase = if ($j.run) { [string]$j.run.base } else { '' }
    $j.run = $null
    # the reviewer sent it back: hand its critique to the rework station (repair) and come back through tests and review (J48)
    if ($kind -eq 'taster' -and $s.reworkTo -and [int]$j.reworks -lt [int]$s.reworkMax) {
        $to = -1; for ($i = 0; $i -lt $j.steps.Count; $i++) { if ((Station-Name $j.steps[$i]) -eq $s.reworkTo) { $to = $i } }
        $wt = Join-Path $root "worktrees\$($j.id)"
        if ($to -ge 0 -and $to -lt $j.cursor -and (Test-Path -LiteralPath (Join-Path $wt '.kitchen'))) {
            $critique = ''; foreach ($ext in '.dish.md', '.log') { if (-not $critique -and $runBase -and (Test-Path -LiteralPath "$runBase$ext")) { $critique = Get-Content -LiteralPath "$runBase$ext" -Raw } }
            if (-not $critique) { $critique = $detail }
            if ($critique.Length -gt 30000) { $critique = $critique.Substring($critique.Length - 30000) }
            Set-Content -LiteralPath (Join-Path $wt '.kitchen\CRITIQUE.md') -Value "# The reviewer sent this change back`n`n$critique" -Encoding utf8
            $j.history += , @{ step = $j.cursor; attempt = $j.attempt; outcome = 'rework'; detail = $detail; at = Iso (Now) }
            Emit 'step.rework' $j.id @{ step = $j.cursor; to = $to; round = [int]$j.reworks + 1 }
            $j.reworks = [int]$j.reworks + 1; $j.cursor = $to; $j.attempt = 0; $j.notBefore = $null; $j.status = 'pending'
            return
        }
    }
    Emit "step.$kind" $j.id @{ step = $j.cursor; attempt = $j.attempt; detail = $detail }
    $j.history += , @{ step = $j.cursor; attempt = $j.attempt; outcome = $kind; detail = $detail; at = Iso (Now) }
    # an explicit REWORK from the reviewer (its mustNotMatch fired) after the rework rounds are used up is a verdict, not a crash:
    # retrying would ask another (stronger) cook the same question until one says SHIP, overruling the rejection. Jordan decides.
    # A missing verdict (mustMatch not found: the cook died or said nothing) still retries as before.
    if ($kind -eq 'taster' -and $s.reworkTo -and $s.mustNotMatch -and $detail -like 'red flag in the output*') {
        $j.status = 'needs-human'
        Emit 'review.rejected' $j.id @{ step = $j.cursor; reworks = [int]$j.reworks }
        Request-Approval $j "$($j.name): the reviewer sent it back again after $([int]$j.reworks) rework round(s) ($($detail.Substring(0, [math]::Min(120, $detail.Length)))). Review it once more?" 'MED'
        return
    }
    # verify is part of the merge transaction. Cut short (timeout, crash, reboot, memory cap, hang) or ending without its own verdict
    # ('verify: FAILED' is printed only after it undid the merge or reported it could not), it never reached its undo: main holds an AI
    # change nobody checked. Never a quiet set-aside: Jordan is told plainly and says yes to run verify again.
    if ((Station-Name $s) -eq 'verify' -and $j.cursor -gt 0 -and (Station-Name $j.steps[$j.cursor - 1]) -eq 'merge') {
        $verdict = $kind -eq 'fail' -and $runBase -and (Test-Path -LiteralPath "$runBase.log") -and (Select-String -LiteralPath "$runBase.log" -Pattern '^verify: FAILED' -Quiet)
        if (-not $verdict) {
            $j.status = 'needs-human'
            Emit 'merge.unverified' $j.id @{ step = $j.cursor; kind = $kind }
            Request-Approval $j "$($j.id) is merged on main but was NOT verified (verify: $kind). Run verify again?" 'HIGH'
            return
        }
    }
    if ($kind -in 'crash', 'hung', 'timeout' -and $s.replay -eq 'unsafe') {
        $j.status = 'needs-human'
        Request-Approval $j "$($j.name): run step $($j.cursor + 1) of $($j.steps.Count) ($(Station-Name $s)) again after a ${kind}? It may not be safe to repeat." 'HIGH'
        return
    }
    if ($j.attempt -ge $s.retries) {
        $j.status = 'quarantined'
        Emit 'job.quarantined' $j.id @{ reason = "$kind x$($j.attempt + 1)" }
        # TD-EH-05: the alert says what failed (the first 120 characters of the detail; the job's history keeps it whole)
        $why = ([string]$detail -replace '\s+', ' ').Trim(); if ($why.Length -gt 120) { $why = $why.Substring(0, 120) }
        Alert 'MED' "$($j.id) $($j.name) quarantined after $($j.attempt + 1) attempts (last: $kind). Look at it when you can." $j.id $why
        return
    }
    # TD-EH-08: a retry waits long enough for the world to change: minutes, with jitter, longer when the failure waited on CI, the
    # network, GitHub or a rate limit (Get-FailureClass) than when the step's own work failed. The attempt cap above is unchanged.
    $j.attempt++
    $bo = Get-BackoffDelay $j.attempt (Get-FailureClass $kind $detail) $script:backoffCfg (Get-Random -Minimum 0.0 -Maximum 1.0)
    $j.notBefore = Iso ((Now).AddSeconds($bo.sec))
    $j.retryWait = @{ sec = $bo.sec; class = $bo.class; text = $bo.text; until = $j.notBefore }
    $j.status = 'pending'
    Emit 'step.retry' $j.id @{ step = $j.cursor; attempt = $j.attempt; inSec = $bo.sec; waitMin = $bo.min; class = $bo.class; note = $bo.text }
}

# An autopilot order whose pinned cook rests for more than 2 hours moves its remaining agent steps to the autopilot fallbackCook
# (gemini) instead of sitting idle for days (J21). Never to claude, never for private steps. Returns the number of steps rewritten.
function Switch-Cook($j, [int]$restSec) {
    if ($restSec -le 7200 -or -not ($j.recipe -eq 'improve' -or [string]$j.name -match '^improve:')) { return 0 }
    $ap = if ($config.autopilot -is [hashtable]) { $config.autopilot } else { @{} }
    $from = if ($ap.cook) { [string]$ap.cook } else { 'antigravity' }
    $to = if ($ap.fallbackCook) { [string]$ap.fallbackCook } else { 'gemini' }
    if ($to -notmatch '^[\w-]{1,30}$' -or $to -in 'claude', 'local', 'any', 'auto' -or $to -eq $from) { return 0 }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "cooks\$to.ps1") -PathType Leaf)) { return 0 }
    $curr = $j.steps[[int]$j.cursor]
    $ca = if ($curr -is [hashtable]) { $curr.args } elseif ($curr) { $curr.args } else { $null }
    if (-not ($ca -is [hashtable] -and [string]$ca.Supplier -eq $from -and -not $ca.Private)) { return 0 }
    $n = 0
    for ($i = [int]$j.cursor; $i -lt $j.steps.Count; $i++) {
        $a = $j.steps[$i].args
        if ($a -is [hashtable] -and [string]$a.Supplier -eq $from -and -not $a.Private) { $a.Supplier = $to; $n++ }
    }
    $n
}

function Start-Step($j) {
    if ($script:inChores) { throw 'the chores never start a worker (only the supervisor pass does)' }
    $s = $j.steps[$j.cursor]
    $base = Join-Path $runDir ('{0}-s{1}-a{2}' -f $j.id, $j.cursor, $j.attempt)
    foreach ($ext in '.exit', '.hb', '.wait', '.hiccup', '.hold') { Remove-Item -LiteralPath "$base$ext" -ErrorAction SilentlyContinue }
    # a requeued job runs the same step and attempt number again: move the earlier run's files aside, or its old output
    # (an old "VERDICT: REWORK") is appended to and judged with the new run (J28)
    if (Test-Path -LiteralPath "$base.log") {
        $old = Join-Path $runDir 'old'; New-Item -ItemType Directory -Force -Path $old | Out-Null; $stamp = (Get-Date).ToString('yyyyMMddHHmmss')
        foreach ($ext in '.log', '.dish.md', '.cost.json', '.sous.json', '.activity.jsonl') { if (Test-Path -LiteralPath "$base$ext") { Move-Item -LiteralPath "$base$ext" -Destination (Join-Path $old ("{0}-{1}{2}" -f (Split-Path -Leaf $base), $stamp, $ext)) -Force } }
    }
    $spec = @{ script = $s.script; args = $s.args; log = "$base.log"; exit = "$base.exit" }
    $spec | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$base.json" -Encoding utf8
    $saved = @{ d = $env:BRAIN_AGENT_DEPTH; h = $env:KITCHEN_HEARTBEAT; j = $env:KITCHEN_JOB; r = $env:KITCHEN_RUN; a = $env:KITCHEN_ATTEMPT; y = $env:KITCHEN_APPROVED }
    try {
        $env:BRAIN_AGENT_DEPTH = [string]($j.depth + 1); $env:KITCHEN_HEARTBEAT = "$base.hb"; $env:KITCHEN_JOB = $j.id; $env:KITCHEN_RUN = $base
        $env:KITCHEN_ATTEMPT = [string]$j.attempt; $env:KITCHEN_TIMEOUT = [string]$s.timeoutSec   # the sous chef escalates on a retry
        # Jordan's yes for this very step (asked by a hold or an approve gate) lets the sous chef do what it held for, this step only
        $env:KITCHEN_APPROVED = $(if ($j.approval -and $j.approval.granted -and [int]$j.approval.cursor -eq [int]$j.cursor) { '1' } else { $null })
        $p = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$runner`"", '-Spec', "`"$base.json`"") -PassThru -WindowStyle Hidden
    } finally {
        $env:BRAIN_AGENT_DEPTH = $saved.d; $env:KITCHEN_HEARTBEAT = $saved.h; $env:KITCHEN_JOB = $saved.j; $env:KITCHEN_RUN = $saved.r; $env:KITCHEN_ATTEMPT = $saved.a; $env:KITCHEN_APPROVED = $saved.y
    }
    $j.run = @{ pid = $p.Id; startMs = (Start-Ms $p); base = $base; startedAt = Iso (Now) }
    $j.status = 'running'; $j.retryWait = $null   # (no longer waiting before a retry)
    # the pid is on disk before anything else can fail: a worker no saved job knows about has no timeout, memory cap or kill. If even
    # the save fails, the worker is stopped at once and the job stays pending (the next tick starts it cleanly)
    try { Save-Job $j } catch { Kill-Tree $p.Id; $j.run = $null; $j.status = 'pending'; throw }
    Emit 'step.started' $j.id @{ step = $j.cursor; attempt = $j.attempt; pid = $p.Id }
}

function Check-Running($j, $procs) {
    $s = $j.steps[$j.cursor]; $r = $j.run; $base = $r.base
    if (Test-Path -LiteralPath "$base.exit") {
        # an .exit file that exists but is still empty (being written, or busy) is looked at again next tick, not read as a failure;
        # only one left empty for a minute by a dead worker counts as exit 1
        $txt = try { ([string][IO.File]::ReadAllText("$base.exit")).Trim() } catch { '' }
        if (-not $txt) { $exAge = try { ((Now) - (Get-Item -LiteralPath "$base.exit").LastWriteTimeUtc).TotalSeconds } catch { 0 }; if ((Is-Alive $r.pid $r.startMs) -or $exAge -lt 60) { return }; $txt = '1' }
        $code = 1; [void][int]::TryParse($txt, [ref]$code)
        $cost = $null
        if (Test-Path -LiteralPath "$base.cost.json") { try { $cost = Get-Content -LiteralPath "$base.cost.json" -Raw | ConvertFrom-Json -AsHashtable } catch { } }
        if ($cost -and ([double]$cost.usd -gt 0 -or [int]$cost.inputTokens -gt 0 -or [int]$cost.outputTokens -gt 0)) {
            $j.costUsd = [math]::Round([double]$j.costUsd + [double]$cost.usd, 4)
            Emit 'cost' $j.id @{
                step = $j.cursor; usd = [double]$cost.usd; model = [string]$cost.model; turns = [int]$cost.turns; supplier = [string]$cost.supplier
                inputTokens = [int]$cost.inputTokens; outputTokens = [int]$cost.outputTokens
                cacheReadTokens = [int]$cost.cacheReadTokens; cacheWriteTokens = [int]$cost.cacheWriteTokens
            }
        }
        $why = @(Get-Content -LiteralPath "$base.log" -Tail 5 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) | Select-Object -Last 1
        $why = Cut-Words $why 200   # (a log line, cut on a word boundary)
        # 10 = hold for Jordan (e.g. a private order only a cloud cook could do); 11 = every able cook is resting or a cloud hiccup, try again later.
        # Neither is a failure: no retry is used and the breaker does not count them.
        if ($code -eq 10) {
            # TD-EH-06: the hold's whole reason, from <run>.hold (kitchen-step.ps1 or the station writes it); the log line only when there is none.
            # The event and the history keep it whole (up to 2000 characters); the Sign-off text fits the 300 the approvals queue takes, cut
            # on a word boundary, never mid-word.
            if (Test-Path -LiteralPath "$base.hold") { $hw = try { Cut-Words ([IO.File]::ReadAllText("$base.hold")) 2000 } catch { '' }; if ($hw) { $why = $hw } }
            $j.run = $null; $j.status = 'needs-human'
            Emit 'step.hold' $j.id @{ step = $j.cursor; detail = $why }
            $j.history += , @{ step = $j.cursor; attempt = $j.attempt; outcome = 'hold'; detail = $why; at = Iso (Now) }
            $ask = "Step $($j.cursor) of $($j.id) $($j.name): "
            Request-Approval $j ($ask + (Cut-Words $why ([math]::Max(40, 300 - $ask.Length)))) 'HIGH'
            if ($j.approval) { $j.approval.kind = 'hold' }
            return
        }
        if ($code -eq 11) {
            $sec = 900; if (Test-Path -LiteralPath "$base.wait") { [void][int]::TryParse((Get-Content -LiteralPath "$base.wait" -Raw).Trim(), [ref]$sec) }
            $sec = [math]::Min([math]::Max($sec, 60), 6 * 3600)
            $j.run = $null; $j.waits = 1 + [int]$j.waits
            # merge found main moved and conflicting: back to the freshen step (twice at most), and the old yes is dropped, because the
            # change Jordan approved is not the one that will merge after the re-freshen (a cook may resolve the conflict)
            if ((Station-Name $s) -eq 'merge' -and (Test-Path -LiteralPath "$base.log") -and (Select-String -LiteralPath "$base.log" -Pattern '^merge: needs freshen' -Quiet)) {
                $fi = -1; for ($i = [int]$j.cursor - 1; $i -ge 0; $i--) { if ((Station-Name $j.steps[$i]) -eq 'freshen') { $fi = $i; break } }
                if ($fi -lt 0 -or [int]$j.refreshens -ge 2) { Fail-Step $j 'fail' $why; return }
                $j.refreshens = 1 + [int]$j.refreshens
                Emit 'merge.refreshen' $j.id @{ step = $j.cursor; to = $fi; round = $j.refreshens }
                $j.history += , @{ step = $j.cursor; attempt = $j.attempt; outcome = 'refreshen'; detail = $why; at = Iso (Now) }
                $j.approval = $null; $j.cursor = $fi; $j.attempt = 0; $j.waits = 0; $j.notBefore = $null; $j.status = 'pending'
                return
            }
            $hiccup = Test-Path -LiteralPath "$base.hiccup"
            if ($hiccup) {
                $j.hiccups = 1 + [int]$j.hiccups
                if ($j.hiccups -gt 5) { Fail-Step $j 'fail' "cloud hiccup x$($j.hiccups): $why"; return }   # a provider that stays down is a failure after all
            }
            if (-not $hiccup) {
                $moved = Switch-Cook $j $sec
                if ($moved -gt 0) {
                    $to = if ($config.autopilot.fallbackCook) { [string]$config.autopilot.fallbackCook } else { 'gemini' }
                    Emit 'cook.switched' $j.id @{ step = $j.cursor; to = $to; steps = $moved; restSec = $sec; detail = $why }
                    $j.history += , @{ step = $j.cursor; attempt = $j.attempt; outcome = 'cook.switched'; detail = "to $to ($moved step(s))"; at = Iso (Now) }
                    $j.notBefore = $null; $j.status = 'pending'
                    return
                }
            }
            Emit 'step.wait' $j.id @{ step = $j.cursor; inSec = $sec; detail = $why; kind =$(if ($hiccup) { 'hiccup' } else { 'wait' }) }
            $j.history += , @{ step = $j.cursor; attempt = $j.attempt; outcome = 'wait'; detail = $why; at = Iso (Now) }
            # ~4 days of 30-minute waits, counted per step: every cook capped for a weekend parks orders, it does not set them aside
            if ($j.waits -gt 200) { $j.status = 'quarantined'; Emit 'job.quarantined' $j.id @{ reason = 'waited too long for a cook' }; Alert 'MED' "$($j.id) $($j.name) set aside: no cook was free after 200 waits ($why)" $j.id; return }
            $j.notBefore = Iso ((Now).AddSeconds($sec)); $j.status = 'pending'; $j.retryWait = $null   # a wait, not a retry
            return
        }
        if ($cost -and $cost.supplier) {   # the sous chef learns from this: which cook, for which kind of order, and whether the dish passed
            $okDish = $code -eq 0 -and -not (Taste-Step $s "$base.log")
            Emit 'cook' $j.id @{ step = $j.cursor; supplier = [string]$cost.supplier; model = [string]$cost.model; kind = [string]$cost.kind; ok = $okDish; reason = [string]$cost.reason }
        }
        if ($code -eq 0) {
            $taste = Taste-Step $s "$base.log"
            if ($taste) { Fail-Step $j 'taster' $taste; return }   # the taster says nothing unless the dish is wrong
            Emit 'step.done' $j.id @{ step = $j.cursor; attempt = $j.attempt }
            $j.history += , @{ step = $j.cursor; attempt = $j.attempt; outcome = 'done'; at = Iso (Now) }
            # only a VERIFIED merge teaches the planners and goes live on Jordan's phone (at merge time a failing verify would undo it while
            # Chef kept serving the broken code). The Chef update itself runs after the tick, outside the state lock: it can take minutes.
            if ((Station-Name $s) -eq 'verify' -and ($j.recipe -eq 'improve' -or $j.name -match '^improve:')) {
                $mi = -1; for ($i = [int]$j.cursor - 1; $i -ge 0; $i--) { if ((Station-Name $j.steps[$i]) -eq 'merge') { $mi = $i; break } }
                $ms = if ($mi -ge 0) { $j.steps[$mi] } else { $s }
                Record-Exemplar $j $ms $base
                # a recipe with its own deploy step after verify puts Chef live itself (stations/deploy.ps1); never both
                $hasDeploy = $false; for ($i = [int]$j.cursor + 1; $i -lt $j.steps.Count; $i++) { if ((Station-Name $j.steps[$i]) -eq 'deploy') { $hasDeploy = $true } }
                if (-not $hasDeploy) { $j.chefUpdate = @{ step = $(if ($mi -ge 0) { $mi } else { [int]$j.cursor }); base = $base; at = Iso (Now) } }
            }
            $j.cursor++; $j.attempt = 0; $j.hiccups = 0; $j.waits = 0; $j.run = $null; $j.notBefore = $null   # checkpoint: the step is never run again; waits count per step
            if ($j.cursor -ge $j.steps.Count) { $j.status = 'done'; Emit 'job.done' $j.id }
            else { $j.status = 'pending' }
        } else {
            Fail-Step $j 'fail' ("exit $code" + $(if ($why) { ': ' + (Cut-Words $why 160) } else { '' }))
        }
        return
    }
    if (-not (Is-Alive $r.pid $r.startMs)) { Fail-Step $j 'crash' (Get-CrashWhy $base); return }
    $age = ((Now) - (ToUtc $r.startedAt)).TotalSeconds
    $mb = Tree-MB $r.pid $procs; $r.mb = [int]$mb; if ($mb -gt [double]$r.peakMB) { $r.peakMB = [int]$mb }   # (the weight admission learns from)
    $logMB = if (Test-Path -LiteralPath "$base.log") { (Get-Item -LiteralPath "$base.log").Length / 1MB } else { 0 }
    $kind = $null
    if ($age -gt $s.timeoutSec) { $kind = 'timeout'; $why = "ran $([int]$age)s (limit $($s.timeoutSec)s)" }
    elseif ($mb -gt $s.maxMB) { $kind = 'memcap'; $why = "used $([int]$mb) MB (limit $($s.maxMB) MB)" }
    elseif ($logMB -gt $(if ($s.maxLogMB) { [double]$s.maxLogMB } else { $MaxLogMB })) { $kind = 'logflood'; $why = "log $([math]::Round($logMB,1)) MB (limit $(if ($s.maxLogMB) { $s.maxLogMB } else { $MaxLogMB }) MB)" }   # a step saved without a limit gets the default, never 0
    elseif (($hungLim = $(if ([int]$s.hungSec -gt 0) { [int]$s.hungSec } elseif ([int]$s.hungSec -lt 0) { 0 } else { $DefaultHungSec })) -gt 0) {
        # alive = the newest of the heartbeat, a log line and the cook's activity file (a tool call). A heartbeat written as
        # "<time> quiet=<sec>" announces a bounded silent wait (a test suite, a cook run, each under its own time limit): no hung call before it ends.
        $hbAt = ToUtc $r.startedAt; $quietTo = $hbAt
        foreach ($ext in '.hb', '.log', '.activity.jsonl') {
            if (-not (Test-Path -LiteralPath "$base$ext")) { continue }
            $t = (Get-Item -LiteralPath "$base$ext").LastWriteTimeUtc; if ($t -gt $hbAt) { $hbAt = $t }
            $hbText = ''; if ($ext -eq '.hb') { try { $hbText = [IO.File]::ReadAllText("$base.hb") } catch [IO.IOException] { } }   # the step may be writing it this instant
            if ($hbText -match 'quiet=(\d+)') { $quietTo = $t.AddSeconds([int]$Matches[1]) }
        }
        $silent = ((Now) - $hbAt).TotalSeconds
        if ($silent -gt $hungLim -and (Now) -gt $quietTo) { $kind = 'hung'; $why = "no heartbeat for $([int]$silent)s (limit $($hungLim)s)" }
    }
    if ($kind) { Kill-Tree $r.pid; Fail-Step $j $kind $why }
}

# The taster: a step that exits 0 is only done if its output proves it (mustMatch) and shows no red flags (mustNotMatch),
# e.g. mustMatch 'passed' and mustNotMatch '\bskipped\b|not done|TODO'. Silent unless something is wrong.
function Taste-Step($s, [string]$log) {
    if (-not $s.mustMatch -and -not $s.mustNotMatch) { return $null }
    $text = [string]$(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' })
    if ($s.mustMatch -and $text -notmatch $s.mustMatch) { return "expected '$($s.mustMatch)' in the output; not found" }
    if ($s.mustNotMatch) { $m = [regex]::Match($text, $s.mustNotMatch); if ($m.Success) { return "red flag in the output: '$($m.Value.Trim())'" } }
    $null
}

function Record-Exemplar($j, $s, [string]$base) {
    try {
        $goal = if ($j.vars -and $j.vars.goal) { [string]$j.vars.goal }
        elseif ($j.name -match '^improve:\s*(.+)$') { $Matches[1].Trim() }
        else { [string]$j.name }
        $repo = if ($s.args -and $s.args.Repo) { [string]$s.args.Repo } elseif ($j.vars -and $j.vars.repo) { [string]$j.vars.repo } else { '' }
        $files = @()
        if ($repo -and (Test-Path -LiteralPath $repo)) {
            try {
                $gitOut = @(& git -C $repo diff-tree --no-commit-id --name-only -r HEAD^1 HEAD 2>$null | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^\.kitchen[\\/]' })
                if ($LASTEXITCODE -eq 0 -and $gitOut.Count) { $files = @($gitOut | ForEach-Object { $_.Trim() }) }
            } catch { }
        }
        if (-not $files.Count) {
            foreach ($lf in Get-ChildItem -LiteralPath $runDir -Filter "$($j.id)-s*-a*.log" -File -ErrorAction SilentlyContinue) {
                foreach ($line in [IO.File]::ReadLines($lf.FullName)) {
                    if ($line -match '^\s*commit:\s+([^|\s]+)\s*\|') {
                        $fName = $Matches[1].Trim()
                        if ($fName -and $fName -notmatch '^\.kitchen[\\/]' -and $files -notcontains $fName) {
                            $files += $fName
                        }
                    }
                }
            }
        }
        $testFiles = @($files | Where-Object { $_ -match '(^|[\\/])tests[\\/]' -or $_ -match 'Test-[\w-]+\.ps1' })
        $testPattern = if ($testFiles.Count) {
            $testFiles -join ', '
        } else {
            $tStep = $j.steps | Where-Object { (Station-Name $_) -eq 'tests' } | Select-Object -First 1
            if ($tStep -and $tStep.args -and $tStep.args.Glob) {
                [string]$tStep.args.Glob
            } else {
                'tests\Test-*.ps1'
            }
        }
        $exPath = Join-Path $root 'exemplars.jsonl'
        $existing = [Collections.Generic.List[object]]::new()
        if (Test-Path -LiteralPath $exPath) {
            foreach ($line in [IO.File]::ReadLines($exPath)) {
                if (-not $line -or -not $line.Trim()) { continue }
                try { $item = $line | ConvertFrom-Json; if ($item) { $existing.Add($item) } } catch { }
            }
        }
        $filesList = [Collections.Generic.List[string]]::new()
        foreach ($f in $files) { $filesList.Add([string]$f) }
        $existing.Add([ordered]@{
            at = Iso (Now)
            job = [string]$j.id
            goal = $goal
            files = $filesList
            testPattern = $testPattern
        })
        $toKeep = @($existing | Select-Object -Last 30)
        $linesToWrite = @($toKeep | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 })
        Set-Content -LiteralPath $exPath -Value ($linesToWrite -join "`n") -Encoding utf8
        Emit 'exemplar.recorded' $j.id @{ goal = $goal; files = $files.Count }
    } catch { }
}

function Invoke-ChefUpdate($j, $s, [string]$base) {
    try {
        $files = @()
        if ($s.args -and $s.args.Files) {
            $files = @($s.args.Files)
        } elseif ($s.args -and $s.args.files) {
            $files = @($s.args.files)
        } elseif ($j.vars -and $j.vars.files) {
            $files = @($j.vars.files)
        } elseif ($j.vars -and $j.vars.Files) {
            $files = @($j.vars.Files)
        }
        $files = @($files | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $files.Count) {
            $repo = if ($s.args -and $s.args.Repo) { [string]$s.args.Repo } elseif ($j.vars -and $j.vars.repo) { [string]$j.vars.repo } else { '' }
            if ($repo -and (Test-Path -LiteralPath $repo)) {
                try {
                    $gitOut = @(& git -C $repo diff-tree --no-commit-id --name-only -r HEAD^1 HEAD 2>$null | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^\.kitchen[\\/]' })
                    if ($LASTEXITCODE -eq 0 -and $gitOut.Count) { $files = @($gitOut | ForEach-Object { $_.Trim() }) }
                } catch { }
            }
        }
        if (-not $files.Count) {
            foreach ($lf in Get-ChildItem -LiteralPath $runDir -Filter "$($j.id)-s*-a*.log" -File -ErrorAction SilentlyContinue) {
                foreach ($line in [IO.File]::ReadLines($lf.FullName)) {
                    if ($line -match '^\s*commit:\s+([^|\s]+)\s*\|') {
                        $fName = $Matches[1].Trim()
                        if ($fName -and $fName -notmatch '^\.kitchen[\\/]' -and $files -notcontains $fName) {
                            $files += $fName
                        }
                    }
                }
            }
        }
        $chefFiles = @($files | Where-Object {
            $norm = ([string]$_) -replace '\\', '/'
            $norm -match '(^|/)pass-app/' -and $norm -notmatch '(^|/)pass-app/public/'
        } | Select-Object -Unique)
        if (-not $chefFiles.Count) { return }

        $updateScript = $null
        if ($env:KITCHEN_CHEF_UPDATE_SCRIPT -and (Test-Path -LiteralPath $env:KITCHEN_CHEF_UPDATE_SCRIPT)) {
            $updateScript = (Resolve-Path -LiteralPath $env:KITCHEN_CHEF_UPDATE_SCRIPT).Path
        } elseif ($env:KITCHEN_CHEF_UPDATE_SCRIPT) {
            $updateScript = $env:KITCHEN_CHEF_UPDATE_SCRIPT
        } else {
            $repo = if ($s.args -and $s.args.Repo) { [string]$s.args.Repo } elseif ($j.vars -and $j.vars.repo) { [string]$j.vars.repo } else { '' }
            $candidates = @()
            if ($repo) { $candidates += (Join-Path $repo 'pass-app\update.ps1') }
            $candidates += (Join-Path $PSScriptRoot '..\pass-app\update.ps1')
            $candidates += (Join-Path $PSScriptRoot 'pass-app\update.ps1')
            foreach ($c in $candidates) {
                if (Test-Path -LiteralPath $c) { $updateScript = (Resolve-Path -LiteralPath $c).Path; break }
            }
        }

        $chefList = [Collections.Generic.List[string]]::new()
        foreach ($cf in $chefFiles) { $chefList.Add([string]$cf) }

        if (-not $updateScript -or -not (Test-Path -LiteralPath $updateScript)) {
            $errMsg = "update script not found: $updateScript"
            Emit 'chef.update.failed' $j.id @{ error = $errMsg; files = $chefList }
            Alert 'HIGH' "Chef update failed for $($j.id): $errMsg" $j.id
            return
        }

        $isProd = try {
            [IO.Path]::GetFullPath($root) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))
        } catch { $false }
        $isCustom = [bool]$env:KITCHEN_CHEF_UPDATE_SCRIPT
        $dryRun = if ($env:KITCHEN_CHEF_UPDATE_DRYRUN -eq '1') { $true } elseif ($env:KITCHEN_CHEF_UPDATE_DRYRUN -eq '0') { $false } else { -not $isProd -and -not $isCustom }

        # bounded: this runs as part of every tick (after the locked pass), so a hung update must never freeze the kitchen (run-bounded kills it after 4 minutes)
        $bounded = Join-Path $PSScriptRoot '..\scripts\run-bounded.ps1'
        $scriptArgs = if ($dryRun) { @('-DryRun') } else { @() }
        $cmdArgs = if (Test-Path -LiteralPath $bounded) {
            @('-NoProfile', '-NonInteractive', '-File', $bounded, '-Script', $updateScript, '-TimeoutSeconds', '240') + @(if ($scriptArgs.Count) { @('-ScriptArgs') + $scriptArgs })
        } else {
            @('-NoProfile', '-NonInteractive', '-File', $updateScript) + $scriptArgs
        }

        $procOut = & $pwsh @cmdArgs 2>&1
        $code = $LASTEXITCODE
        $msg = ($procOut | Out-String).Trim()
        if ($code -eq 0) {
            Emit 'chef.updated' $j.id @{ detail = $msg; files = $chefList }
        } else {
            $errMsg = if ($msg) { $msg } else { "update script failed with exit code $code" }
            if ($errMsg.Length -gt 300) { $errMsg = $errMsg.Substring(0, 300) }
            Emit 'chef.update.failed' $j.id @{ error = $errMsg; files = $chefList }
            Alert 'HIGH' "Chef update failed for $($j.id): $errMsg" $j.id
        }
    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg.Length -gt 300) { $errMsg = $errMsg.Substring(0, 300) }
        try {
            $cList = if ($chefList) { $chefList } else { [Collections.Generic.List[string]]::new() }
            Emit 'chef.update.failed' $j.id @{ error = $errMsg; files = $cList }
            Alert 'HIGH' "Chef update failed for $($j.id): $errMsg" $j.id
        } catch { }
    }
}

# Chef updates marked by the tick (a verified merge touched the Chef server) run here, after the tick and outside the state lock, so
# approvals and adds never wait up to 4 minutes on a server swap. Each marker is claimed under the lock first: it runs at most once.
function Invoke-PendingChefUpdates {
    foreach ($pj in @(All-Jobs -Live | Where-Object { $_.chefUpdate })) {   # (-Live keeps finished orders with a Chef update to run)
        $cu = $null
        Enter-State
        try { $fresh = Load-Job $pj.id; if ($fresh.chefUpdate) { $cu = $fresh.chefUpdate; $fresh.chefUpdate = $null; Save-Job $fresh } } catch { } finally { Exit-State }
        if ($cu) { $st = $pj.steps[[math]::Min([int]$cu.step, $pj.steps.Count - 1)]; Invoke-ChefUpdate $pj $st ([string]$cu.base) }
    }
}

# Money spent today (local day), from the cost events that agent steps report.
function Spend-Today {
    $sum = 0.0; $today = (Get-Date).Date; $day = $today.ToString('yyyy-MM-dd')
    # the log rotates at 20 MB, so today's costs may also sit in events-*.jsonl files rotated today
    $files = @(Get-ChildItem -LiteralPath $root -Filter 'events-*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime.Date -eq $today } | ForEach-Object { $_.FullName })
    if (Test-Path -LiteralPath $eventsPath) { $files += $eventsPath }
    # each file is read only from where the last count stopped (spend-cache.json: length, a hash of its first bytes, today's sum so far).
    # A shorter file or other first bytes (rotated, replaced) or a new day is counted again from the start.
    $cachePath = Join-Path $root 'spend-cache.json'
    $cache = @{}; try { $c = Get-Content -LiteralPath $cachePath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable; if ($c.day -eq $day -and $c.files -is [hashtable]) { $cache = $c.files } } catch { }
    $next = @{}
    foreach ($f in $files) {
        try {
            $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite, Delete')
            try {
                $len = $fs.Length; $hb = [byte[]]::new([math]::Min(256, $len)); [void]$fs.Read($hb, 0, $hb.Length); $head = Sha ([Convert]::ToBase64String($hb)) 16
                $e0 = $cache[$f]; $from = 0L; $part = 0.0
                if ($e0 -and $e0.head -eq $head -and [long]$e0.len -le $len) { $from = [long]$e0.len; $part = [double]$e0.sum }
                $buf = [byte[]]::new($len - $from); [void]$fs.Seek($from, 'Begin'); $got = 0; while ($got -lt $buf.Length) { $r = $fs.Read($buf, $got, $buf.Length - $got); if ($r -le 0) { break }; $got += $r }
                $end = if ($got -gt 0) { [Array]::LastIndexOf($buf, [byte]10, $got - 1) } else { -1 }   # only whole lines; a line being written is read next time
                if ($end -ge 0) {
                    foreach ($l in [Text.Encoding]::UTF8.GetString($buf, 0, $end + 1) -split "`n") {
                        if ($l -notmatch '"type":"cost"') { continue }
                        try { $e = $l | ConvertFrom-Json; if ((ToUtc $e.ts).ToLocalTime().Date -eq $today) { $part += [double]$e.usd } } catch { continue }
                    }
                }
                $next[$f] = @{ len = $from + $end + 1; head = $head; sum = $part }; $sum += $part
            } finally { $fs.Dispose() }
        } catch { }
    }
    try { $t = "$cachePath.tmp-$PID"; @{ day = $day; files = $next } | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $t -Encoding utf8; Move-Into $t $cachePath } catch { }
    [math]::Round($sum, 4)
}

function Invoke-Tick([switch]$Paused) {
    # slow outside calls happen before the state lock is taken: the RAM guard's model unloads (up to 13 s per model) and the auto-merge
    # check of each order waiting at its merge step. Inside the lock only files are read and written; alerts are queued and pushed after.
    if (-not $script:inTickAction) { Start-TickClock }   # (the tick action starts the clock itself, before the inbox; watch starts one per pass)
    if ($Paused) {   # TD-EH-13: a paused Walkround minds the running steps and records their exits; no work starts before or after that
        $script:amPre = @{}; $script:deferNotify = [Collections.Generic.List[object]]::new()
        try { Invoke-TickLocked $false $true }
        finally { Tick-Phase 'locked'; $q = $script:deferNotify; $script:deferNotify = $null; foreach ($n in $q) { Send-HeldAlert $n }; Tick-Phase 'notify' }
        # TD-EH-03b: watcher standing orders (the night inspection) still start while paused; they read and report, never change work
        try { Invoke-ChoreStanding -WatchersOnly }
        catch { $wm = "$($_.Exception.Message)"; Enter-State; try { Emit 'standing.failed' '' @{ name = 'watchers'; detail = $wm } } finally { Exit-State } }
        Tick-Phase 'watchers'
        return
    }
    $script:freeMB = Get-ScalerFreeMB ([IO.Path]::GetFullPath($root) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen')))   # (one reading: the scaler and the RAM guard)
    $lowRam = Test-RamGuard
    Tick-Phase 'ram'
    $script:amPre = @{}
    foreach ($pj in (All-Jobs -Live)) {   # (orders still in play only: finished ones are never opened)
        try {
            if ($pj.status -notin 'pending', 'waiting-approval' -or -not $pj.steps) { continue }
            $ps = $pj.steps[[int]$pj.cursor]
            if (-not $ps.approve -or (Station-Name $ps) -ne 'merge') { continue }
            $asked = [bool]($pj.approval -and [int]$pj.approval.cursor -eq [int]$pj.cursor)
            # an order already waiting for Jordan's tap whose pull request he may merge on GitHub instead: only that is asked (-GithubOnly)
            $ghOnly = $pj.status -eq 'waiting-approval' -and $asked -and -not $pj.approval.granted -and (Test-Path -LiteralPath (Join-Path $root "results\$($pj.id).pr.json"))
            if (-not $ghOnly -and ($pj.status -ne 'pending' -or $asked)) { continue }
            # -ReadOnly: the saved CI look only (no gh, no network in the tick); the chores take the looks (Invoke-ChoreCiLooks)
            $am = try { (& (Join-Path $PSScriptRoot 'automerge.ps1') -Job $pj.id -Json -GithubOnly:$ghOnly -ReadOnly | Out-String) | ConvertFrom-Json } catch { $null }
            $script:amPre[[string]$pj.id] = @{ cursor = [int]$pj.cursor; am = $am; approval = $(if ($asked) { [string]$pj.approval.id } else { '' }) }
        } catch { }
    }
    Tick-Phase 'prescan'
    $script:deferNotify = [Collections.Generic.List[object]]::new()
    try { Invoke-TickLocked $lowRam }
    finally { Tick-Phase 'locked'; $q = $script:deferNotify; $script:deferNotify = $null; foreach ($n in $q) { Send-HeldAlert $n }; Tick-Phase 'notify' }
}
function Test-RamGuard {
    # RAM guard: under ~1 GB free, local models parked in system memory (not on the graphics card) are unloaded, and nothing new
    # starts until memory is back (running work is never touched). Jordan's rig must stay usable.
    $isReal = [IO.Path]::GetFullPath($root) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))
    if ($env:KITCHEN_NO_RAMGUARD -eq '1' -or -not ($isReal -or $env:KITCHEN_RAMGUARD -eq '1')) { return $false }   # the real kitchen only (test kitchens never stall)
    $freeMB = if ($null -ne $script:freeMB) { [int]$script:freeMB } else { try { [int]((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1KB) } catch { 99999 } }
    $minMB = if ($config.minFreeMB) { [int]$config.minFreeMB } else { 1024 }
    if ($freeMB -ge $minMB) { return $false }
    $ol = if ($env:KITCHEN_OLLAMA_URL -and $env:KITCHEN_OLLAMA_URL -ne 'off') { $env:KITCHEN_OLLAMA_URL.TrimEnd('/') } else { 'http://127.0.0.1:11434' }
    $freed = @()
    if ($env:KITCHEN_OLLAMA_URL -ne 'off') {
        try { foreach ($m in @((Invoke-RestMethod -Uri "$ol/api/ps" -TimeoutSec 3).models)) { if ([double]$m.size_vram -lt [double]$m.size) { Invoke-RestMethod -Uri "$ol/api/generate" -Method Post -Body (@{ model = $m.name; keep_alive = 0 } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 | Out-Null; $freed += $m.name } } } catch { }
    }
    $mark = Join-Path $root 'ram-alert.txt'
    if (-not (Test-Path -LiteralPath $mark) -or ((Get-Date) - (Get-Item -LiteralPath $mark).LastWriteTime).TotalMinutes -gt 15) {
        Set-Content -LiteralPath $mark -Value (Iso (Now))
        Emit 'ram.low' '' @{ freeMB = $freeMB; detail = "only $freeMB MB free$(if ($freed) { '; unloaded ' + ($freed -join ', ') }); new work waits" }
    }
    $true
}
# The gap: when this pass began (the tick process's start; for a later pass of the same tick, that pass's start) minus the previous
# pass's end (D4). The task runs every minute and never twice at once, so a gap over 90 s means nothing ran: the PC slept. A slow tick
# (its own chores, a CI look) no longer counts. The PC slept or hibernated: its workers were frozen too, so the time away must not count
# against their timeout or heartbeat (every overnight sleep used to kill and set aside every order that was cooking). Each running
# step's start and heartbeat move forward by the gap, less the minute a normal tick takes.
function Resume-AfterSleep($meta) {
    $prevEnd = if ($meta.lastTickEnd) { $meta.lastTickEnd } else { $meta.lastTick }   # (lastTick alone: a kitchen from before 10-22)
    if (-not $prevEnd -or -not $script:gapFrom) { return }
    $gap = ($script:gapFrom - (ToUtc $prevEnd)).TotalSeconds
    if ($gap -le 90) { return }
    $act = @(All-Jobs -Live | Where-Object { $_.status -eq 'running' }); if (-not $act.Count) { return }
    Emit 'supervisor.resumed' '' @{ gapSec = [int]$gap; running = $act.Count }
    $shift = $gap - 60
    foreach ($rj in $act) {
        try {
            if (-not $rj.run -or -not $rj.run.startedAt) { continue }
            $rj.run.startedAt = Iso ((ToUtc $rj.run.startedAt).AddSeconds($shift)); $rj.run.resumedSec = [int]$rj.run.resumedSec + [int]$shift
            # (the log and the cook's activity file too: the hung check reads all three)
            foreach ($hb in "$($rj.run.base).hb", "$($rj.run.base).log", "$($rj.run.base).activity.jsonl") {
                if (Test-Path -LiteralPath $hb) { $hi = Get-Item -LiteralPath $hb; $to = $hi.LastWriteTimeUtc.AddSeconds($shift); if ($to -gt (Now)) { $to = Now }; $hi.LastWriteTimeUtc = $to }
            }
            Save-Job $rj
        } catch { Emit 'tick.error' $rj.id @{ detail = "resume shift: $($_.Exception.Message)" } }
    }
}
# Check-Running, and when that run ended with real work (done or failed, not a wait or a hold for Jordan) its peak MB and seconds go to
# weights.json: what admission learns each station's weight from (TD-10: also under station@Tower when the order has one)
function Check-RunningWeighed($j, $procs) {
    $r = $j.run; $st = Station-Name $j.steps[$j.cursor]
    Check-Running $j $procs
    if (-not $r -or ($j.run -and $j.run.base -eq $r.base)) { return }
    $last = if (@($j.history).Count) { [string]$j.history[-1].outcome } else { '' }
    if ($last -in 'wait', 'hold', 'refreshen', 'cook.switched') { return }
    # the real kitchen learns; a test kitchen only when it was given a weights.json (its demo steps would otherwise turn "light" after
    # three runs and slip past the -MaxConcurrent its test sets)
    $real = [IO.Path]::GetFullPath($root) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))
    if (-not $real -and -not (Test-Path -LiteralPath (Join-Path $root 'weights.json'))) { return }
    try { Add-KitchenWeight $root $st $r.peakMB ((Now) - (ToUtc $r.startedAt)).TotalSeconds (Get-JobTower $j) } catch { Emit 'tick.error' $j.id @{ detail = "weights: $($_.Exception.Message)" } }
}
# This pass's admission inputs: the scaled limit (a new free-RAM reading moves it; a change is a 'scaler' event), the weights, and the
# running steps with what their trees use now. The summary goes to supervisor.json for the doctor line.
# the scaler's ceiling: kitchen.json maxConcurrentAuto (default 6), never below a maxConcurrent Jordan set higher himself
function Get-ScalerCeiling { [math]::Max($(if ($null -ne $config.maxConcurrentAuto) { [int]$config.maxConcurrentAuto } else { 6 }), $MaxConcurrent) }
function Get-Admission($jobs, $meta) {
    $ceil = Get-ScalerCeiling
    $sc = if ($null -ne $script:freeMB) { Update-KitchenScaler $root $script:freeMB $MaxConcurrent $ceil } else { @{ limit = (Get-KitchenScalerLimit $root $MaxConcurrent $ceil); changed = $false } }
    if ($sc.changed) { Emit 'scaler' '' @{ old = $sc.old; new = $sc.limit; freeMB = $sc.reading; why = $sc.why } }
    $reg = Get-YardSites $root   # TD-7: kitchen.json "sites" (per-Site maxHeavy and share); none = no Site limits, equal shares
    $run = @(foreach ($x in $jobs) { if ($x.status -eq 'running' -and $x.run) { @{ station = (Station-Name $x.steps[$x.cursor]); mb = [double]$x.run.mb; site = (Get-AdmitSite $x $reg.sites); tower = (Get-JobTower $x) } } })
    $res = if ($config.admission -is [hashtable] -and $null -ne $config.admission.reserveMB) { [int]$config.admission.reserveMB } else { 1024 }
    $meta.admission = @{ limit = $sc.limit; ceiling = $ceil; maxConcurrent = $MaxConcurrent; running = $run.Count; freeMB = $script:freeMB; at = Iso (Now) }
    if ($reg.problems.Count) { $meta.admission.siteProblems = @($reg.problems) }
    $w = Read-KitchenWeights $root
    # the fair share's load (multi-site design 2.3): running heavy steps per Site ('' = no Site), light steps left out as admission does;
    # only with a registry (no registry: Sort-ForStart gets no weights and keeps the old order)
    $siteLoad = @{}; if ($reg.sites.Count) { foreach ($r in $run) { if (-not (Get-StationWeight $w ([string]$r.station) ([string]$r.tower)).light) { $siteLoad[[string]$r.site] = 1 + [int]$siteLoad[[string]$r.site] } } }
    @{ limit = $sc.limit; weights = $w; running = $run; free = $script:freeMB; reserve = $res; sites = $reg.sites; shares = (Get-KitchenSiteShares $reg.sites); siteLoad = $siteLoad }
}
# The order's Site for a per-Site limit: '' when the registry is empty (no lookup at all: exactly as before TD-7) or the lookup fails
function Get-AdmitSite($j, $Sites) { if (-not $Sites.Count) { return '' }; try { [string](Get-KitchenJobSite $j) } catch { '' } }
# That Site's maxHeavy, $null for no Site or no limit (Test-KitchenAdmit then skips the Site check)
function Get-AdmitSiteMax([string]$Site, $Sites) { if ($Site -and $Sites.ContainsKey($Site)) { $Sites[$Site].maxHeavy } else { $null } }
function Invoke-TickLocked([bool]$lowRam, [bool]$paused = $false) {
    Enter-State
    try {
        $b = Breaker-State; $meta = $b.meta
        Resume-AfterSleep $meta
        $procs = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, WorkingSetSize, CreationDate)
        $jobs = All-Jobs -Live   # the supervisor never opens a finished order (TARGET W3: a tick costs live jobs, not all jobs ever)
        # one job's error (a busy file, a bad record) is logged and the loop goes on: it never starves every job queued after it
        foreach ($j in $jobs) { if ($j.status -eq 'running') { try { Check-RunningWeighed $j $procs; Save-Job $j } catch { Emit 'tick.error' $j.id @{ detail = "$($_.Exception.Message)" } } } }
        # paused by Jordan (TD-EH-13): the running steps were minded above (time, memory, log, heartbeat; exits recorded, a hold's Sign-off
        # asked); nothing else: no re-asks, no grants, no starts, and lastTick stays as it was (the Walkround's end, lastTickEnd, still moves, so a long pause never reads as the PC asleep)
        if ($paused) { return }
        # a job waiting on a yes with no request in the queue (the request failed) is asked again, contents-free
        foreach ($j in $jobs) {
            try {
                if ($j.status -in 'waiting-approval', 'needs-human' -and (-not $j.approval -or ($j.approval.failed -and [int]$j.approval.cursor -eq [int]$j.cursor))) {
                    $ak = if ($j.approval) { $j.approval.kind } else { $null }; $al = if ($j.approval -and $j.approval.level) { [string]$j.approval.level } else { 'HIGH' }
                    Request-Approval $j "$($j.id): step $($j.cursor + 1) of $($j.steps.Count) ($(Station-Name $j.steps[$j.cursor])) needs your yes" $al
                    if ($ak -and $j.approval) { $j.approval.kind = $ak }
                    Save-Job $j
                }
            } catch { Emit 'tick.error' $j.id @{ detail = "$($_.Exception.Message)" } }
        }
        # Jordan pressed Merge on the order's pull request on GitHub while it waited for his tap: that is his yes (automerge.ps1 checked
        # it is merged there at exactly the tested commit). Only for the very ask that was pending when it was checked.
        foreach ($j in $jobs) {
            try {
                $pre = $script:amPre[[string]$j.id]
                if ($j.status -eq 'waiting-approval' -and $pre -and $pre.am -and $pre.am.ok -and [string]$pre.am.kind -eq 'github' -and [int]$pre.cursor -eq [int]$j.cursor -and
                    $j.approval -and -not $j.approval.granted -and [string]$j.approval.id -eq [string]$pre.approval) {
                    Grant-Github $j ([string]$pre.am.why); $j.status = 'pending'; $j.notBefore = $null; Save-Job $j
                }
            } catch { Emit 'tick.error' $j.id @{ detail = "$($_.Exception.Message)" } }
        }
        # approvals answered since the last tick
        foreach ($j in $jobs) {
            try { if ($j.status -in 'waiting-approval', 'needs-human' -and (Approval-Granted $j)) { $j.status = 'pending'; $j.notBefore = $null; Save-Job $j } }
            catch { Emit 'tick.error' $j.id @{ detail = "$($_.Exception.Message)" } }
        }
        # the Stop-work order (TD-EH-07): open = no new work; probe = cooled down but not yet clear, so one trial step may start
        # TD-8: with a Sites registry the order is per Site and the Owner may have stopped some Sites (Get-StopWorkPlan); without one, as before
        $plan = Get-StopWorkPlan $meta $jobs; $open = $plan.open; $probeOnly = $plan.probe
        # start work (never past the daily budget)
        $spent = Spend-Today; $broke = $spent -ge $DailyBudgetUsd
        if ($broke -and $meta.budgetAlertDay -ne (Get-Date -Format 'yyyy-MM-dd')) {
            $meta.budgetAlertDay = Get-Date -Format 'yyyy-MM-dd'; Emit 'budget.stop' '' @{ spentUsd = $spent; budgetUsd = $DailyBudgetUsd }
            Alert 'HIGH' ('Daily budget reached: ${0:N2} of ${1:N2} spent today. No new work starts until tomorrow.' -f $spent, $DailyBudgetUsd)
        }
        # ($lowRam: the RAM guard ran before the lock, in Invoke-Tick)
        # maxLive: orders under way at once (running, waiting on a yes, or past their first step); a queued order not yet begun waits
        $underWay = @($jobs | Where-Object { $_.status -in 'running', 'waiting-approval', 'needs-human' -or ($_.status -eq 'pending' -and [int]$_.cursor -gt 0) }).Count
        # admission (TARGET W2, kitchen/scaler.ps1): light steps start outside the slots; heavy ones up to the RAM-scaled limit when their
        # weight is measured and fits the free RAM, else up to maxConcurrent as before
        $adm = Get-Admission $jobs $meta
        foreach ($j in (Sort-ForStart $jobs $adm.shares $adm.siteLoad)) {
            if ($j.status -ne 'pending') { continue }
            if ($open -or $broke -or $lowRam) { break }
            if ([int]$j.cursor -eq 0 -and $underWay -ge $MaxLive) { continue }
            if ($j.notBefore -and (Now) -lt (ToUtc $j.notBefore)) { continue }
            $st = Station-Name $j.steps[$j.cursor]; $si = Get-AdmitSite $j $adm.sites; $tw = Get-JobTower $j
            if (Test-SiteHeld $plan $si) { continue }   # TD-8: this Site stopped by the Owner, or its own Stop-work order open
            if (-not (Test-KitchenAdmit $st $adm.weights $adm.running $adm.limit $MaxConcurrent $adm.free $adm.reserve $si (Get-AdmitSiteMax $si $adm.sites) $tw).ok) { continue }
            try { if (Hold-ForClash $j $jobs $terminal) { continue } } catch { Emit 'tick.error' $j.id @{ detail = "clash check: $($_.Exception.Message)" } }
            try {
                $wasNew = [int]$j.cursor -eq 0
                if (Start-Job-Or-Gate $j) {
                    $adm.running += @{ station = $st; mb = 0; site = $si; tower = $tw }
                    if ($probeOnly) {   # the one trial step while the Stop-work order is cooling: nothing else starts until it ends
                        $meta.breakerEpisode.probe = @{ job = [string]$j.id; at = Iso (Now) }; $open = $true
                        Emit 'breaker.probe' $j.id @{ step = $j.cursor; episode = [int]$meta.breakerEpisode.n; note = 'one trial step runs before new work starts again' }
                    }
                    Set-SiteProbe $plan $meta $si $j   # TD-8: that Site's one trial step, if its Stop-work order is cooling
                }
                if ($wasNew -and $j.status -ne 'pending') { $underWay++ }
            } catch { Emit 'tick.error' $j.id @{ detail = "$($_.Exception.Message)" } }
        }
        $meta.lastTick = Iso (Now); $meta.lastTickEnd = $meta.lastTick; Save-Meta $meta   # (the tick action moves lastTickEnd to its very end)
    } finally { Exit-State }
}

# Jordan's Merge on GitHub recorded as his yes for this merge step (kind 'github': merge.ps1 says so in its log; it is not logged as an
# auto-merge, so it never counts toward the daily cap or reads as "merged on its own")
function Grant-Github($j, [string]$why) {
    $j.approval = @{ id = 'github'; text = $why; cursor = $j.cursor; attempt = $j.attempt; granted = $true; kind = 'github' }
    Emit 'approval.github' $j.id @{ why = $why }
}
# Start one pending job's step, or ask for (or auto-grant) the approval its gate needs. Returns $true when a worker was started.
function Start-Job-Or-Gate($j) {
    $s = $j.steps[$j.cursor]
    if ($s.approve -and -not (Approval-Granted $j)) {
        if (-not $j.approval -or $j.approval.cursor -ne $j.cursor) {
            # Jordan's auto-merge policy (automerge.ps1): small, tested, reviewed changes that touch no gate or guard merge without his tap
            $am = $null
            if ((Station-Name $s) -eq 'merge') {
                $pre = $script:amPre[[string]$j.id]
                if (-not $pre -or [int]$pre.cursor -ne [int]$j.cursor) { return $false }   # reached merge during this tick: checked (outside the lock) next tick
                $am = $pre.am
            }
            if ($am -and $am.ok -and [string]$am.kind -eq 'github') { Grant-Github $j ([string]$am.why); Save-Job $j; return $false }   # his own Merge on GitHub: not an auto-merge
            if ($am -and $am.ok) {
                $j.approval = @{ id = 'auto'; text = "auto-merge: $($am.why)"; cursor = $j.cursor; attempt = $j.attempt; granted = $true; kind = 'auto' }
                Emit 'approval.auto' $j.id @{ why = [string]$am.why }
                try { [ordered]@{ at = Iso (Now); job = $j.id; name = [string]$j.name; why = [string]$am.why } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $root 'automerged.jsonl') -Encoding utf8 } catch { }
                Save-Job $j; return $false
            }
            $j.status = 'waiting-approval'
            $txt = "$($j.name): start step $($j.cursor + 1) of $($j.steps.Count) ($(Station-Name $s))"
            # an order not cooked from a recipe (added by a bot, MCP or by hand) says what will actually run: the script and its args (a
            # bot-chosen name alone is not consent to what runs). The args are bound by their hash: changed afterwards, the yes is void.
            $sum = $null
            if (-not $j.recipe) {
                $sum = Args-Summary $s; $tail = " runs $(Split-Path -Leaf ([string]$s.script))"; $room = 270 - $txt.Length - $tail.Length - 24
                if ($sum.text) { $t2 = $sum.text; if ($t2.Length -gt $room) { $t2 = $t2.Substring(0, [math]::Max(0, $room)) + '...' }; $tail += " with $t2" }
                $txt += ":$tail [args sha $($sum.sha)]"
            }
            Request-Approval $j $txt 'MED'
            if ($sum -and $j.approval) { $j.approval.argsSha = $sum.sha }
            Save-Job $j
        }
        return $false
    }
    if (Wait-ForTrain $j $s) { return $false }
    Start-Step $j; Save-Job $j; return $true
}
# A merge step whose repo's train is busy (another order of that repo is being merged or verified, kitchen/train.ps1) is not started:
# no worker, no slot, one 'step.wait' kind 'train' per holder (like the clash wait). merge.ps1 still checks again inside its lock.
function Wait-ForTrain($j, $s) {
    $repo = if ($s.args) { [string]$s.args.Repo } else { '' }
    $th = if ((Station-Name $s) -eq 'merge' -and $repo -and $repo -notmatch '\{\{') { Get-TrainHolder $root $repo ([string]$j.id) } else { $null }
    if (-not $th) { if ($j.trainWait) { $j.trainWait = $null }; return $false }
    if ([string]$j.trainWait -ne $th) { $j.trainWait = $th; Emit 'step.wait' $j.id @{ step = $j.cursor; kind = 'train'; detail = "waiting for the merge train ($th is being checked on main)" }; Save-Job $j }
    $true
}

function Job-Repo($j, [string]$wt = '') {
    $rf = if ($wt) { Join-Path $wt '.kitchen\REPO' } else { '' }
    if ($rf -and (Test-Path -LiteralPath $rf)) { return ([string](Get-Content -LiteralPath $rf -Raw)).Trim() }
    Get-JobTower $j   # vars.repo, else a step's Repo (jobs-lib.ps1)
}
# add: the order's Site (multi-site design TD-3). Its Tower's kitchen.repo.json "site" (read from the main checkout) becomes vars.site.
# A Tower that names no Site, or no Tower: the order is saved exactly as given (a vars.site passed with it stays; nothing is added).
# A config that will not load: logged (job.site.unread) and the order is added Unassigned; the merge station holds that Tower anyway.
function Set-NewJobSite($j) {
    $tower = Get-JobTower $j; if (-not $tower) { return }
    $site = try { Read-TowerSite $tower } catch { Emit 'job.site.unread' $j.id @{ repo = $tower; detail = (Cut-Words "$($_.Exception.Message)" 200) }; '' }
    if (-not $site) { return }
    if ($null -eq $j.vars) { $j.vars = @{} } elseif ($j.vars -isnot [Collections.IDictionary]) { return }   # (vars of another shape: left as given)
    $j.vars['site'] = $site
}
# git's first output line (its error), cut to 160 characters; its exit code when it printed nothing
function Get-GitNote($out, [int]$code) {
    $l = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -First 1
    if ($l) { Cut-Words $l 160 } else { "exit $code" }
}
# doctor: clean up after finished orders (see the call in 'doctor'). Each job is read again right before its folder goes: a requeue
# between the snapshot and here keeps its worktree.
function Prune-Worktrees($jobs) {
    # notes (TD-EH-21): a git cleanup call that failed says so in one line (the doctor prints them and logs them on its event); a branch
    # kept because main does not have it yet is not a failure (counted in kept)
    $n = @{ worktrees = 0; branches = 0; kept = 0; notes = @() }; $gone = 'closed', 'killed', 'done'
    $byId = @{}; foreach ($j in $jobs) { $byId[[string]$j.id] = $j }
    $repos = @{}
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $root 'worktrees') -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^J\d+$' -or -not $byId.ContainsKey($d.Name)) { continue }   # no job file: not ours to judge, kept
        $fresh = try { Load-Job $d.Name } catch { $null }
        if (-not $fresh -or [string]$fresh.status -notin $gone) { continue }
        $repo = Job-Repo $fresh $d.FullName
        if ($repo -and (Test-Path -LiteralPath $repo)) {
            $repos[$repo] = $true
            if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) {
                $o = & git -C $repo worktree remove --force $d.FullName 2>&1
                if ($LASTEXITCODE -ne 0) { $n.notes += "git worktree remove failed for $($d.Name): $(Get-GitNote $o $LASTEXITCODE)" }
            }
        }
        # a folder git no longer tracks (its remove failed on a file lock, or it was pruned) is just files now
        if (Test-Path -LiteralPath $d.FullName) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop } catch { $n.notes += "could not delete the folder worktrees\$($d.Name): $(Cut-Words $_.Exception.Message 160)" } }
        if (-not (Test-Path -LiteralPath $d.FullName)) { $n.worktrees++ }
    }
    foreach ($j in $jobs) { if ([string]$j.status -in $gone) { $r = Job-Repo $j; if ($r -and (Test-Path -LiteralPath $r)) { $repos[$r] = $true } } }
    foreach ($repo in @($repos.Keys)) {
        $o = & git -C $repo worktree prune 2>&1
        if ($LASTEXITCODE -ne 0) { $n.notes += "git worktree prune failed in ${repo}: $(Get-GitNote $o $LASTEXITCODE)" }
        foreach ($b in @(& git -C $repo branch --list 'kitchen/J*' --format '%(refname:short)' 2>$null)) {
            $bid = ([string]$b).Trim() -replace '^kitchen/', ''
            if (-not $byId.ContainsKey($bid) -or [string]$byId[$bid].status -notin $gone) { continue }
            $o = & git -C $repo branch -d ([string]$b).Trim() 2>&1
            if ($LASTEXITCODE -eq 0) { $n.branches++; continue }
            $n.kept++   # not merged: kept, its work stays reachable
            if ("$o" -notmatch 'not fully merged') { $n.notes += "git branch -d failed for $(([string]$b).Trim()): $(Get-GitNote $o $LASTEXITCODE)" }
        }
    }
    $n
}
# doctor: the in-kitchen backups. The doctor's own copies live in backups\daily\yyyyMMdd and the newest 7 days are kept, judged by the
# date in the name; hand-made backups (jobs-github-*, J190-cursor-*.json, anything else) live in backups\manual\ and are kept 14 days,
# by the yyyyMMdd in their name or else their write time. Until 10-23 both shared backups\ and were pruned by name sort, so hand-made
# folders (sorting above dates) took 3 of the 7 places and were never pruned: the old layout is moved over on the first run (a move,
# never a copy or a delete; an item whose new place is taken stays where it is). Returns @{ daily; manual; pruned; moved }.
function Invoke-BackupRetention([string]$bkRoot, [int]$keepDaily = 7, [int]$keepManualDays = 14) {
    $res = @{ daily = 0; manual = 0; pruned = 0; moved = 0 }
    if (-not (Test-Path -LiteralPath $bkRoot)) { return $res }
    $daily = Join-Path $bkRoot 'daily'; $manual = Join-Path $bkRoot 'manual'
    $inv = [Globalization.CultureInfo]::InvariantCulture; $dt = [DateTime]::MinValue
    foreach ($i in @(Get-ChildItem -LiteralPath $bkRoot -Force | Where-Object { $_.Name -notin 'daily', 'manual' })) {
        $isDay = $i.PSIsContainer -and $i.Name -match '^\d{8}$' -and [DateTime]::TryParseExact($i.Name, 'yyyyMMdd', $inv, 'None', [ref]$dt)
        $to = Join-Path $(if ($isDay) { $daily } else { $manual }) $i.Name
        if (Test-Path -LiteralPath $to) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
        try { Move-Item -LiteralPath $i.FullName -Destination $to -ErrorAction Stop; $res.moved++ } catch { }
    }
    $days = @(Get-ChildItem -LiteralPath $daily -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '^\d{8}$' -and [DateTime]::TryParseExact($_.Name, 'yyyyMMdd', $inv, 'None', [ref]$dt)) { [pscustomobject]@{ d = $_; at = $dt } } } | Sort-Object at -Descending)
    foreach ($x in @($days | Select-Object -Skip $keepDaily)) { try { Remove-Item -LiteralPath $x.d.FullName -Recurse -Force -ErrorAction Stop; $res.pruned++ } catch { } }
    $res.daily = [math]::Min($days.Count, $keepDaily)
    $cut = (Get-Date).Date.AddDays(-$keepManualDays)
    foreach ($m in @(Get-ChildItem -LiteralPath $manual -Force -ErrorAction SilentlyContinue)) {
        $at = $m.LastWriteTime
        foreach ($c in [regex]::Matches($m.Name, '(?<!\d)(\d{8})')) { if ([DateTime]::TryParseExact($c.Groups[1].Value, 'yyyyMMdd', $inv, 'None', [ref]$dt)) { $at = $dt; break } }
        if ($at -lt $cut) { try { Remove-Item -LiteralPath $m.FullName -Recurse -Force -ErrorAction Stop; $res.pruned++; continue } catch { } }
        $res.manual++
    }
    $res
}
function New-Step($h) {
    $sp = if ($h.station) { Resolve-Station ([string]$h.station) } else { [string]$h.script }
    if (-not $sp -or -not (Test-Path -LiteralPath $sp -PathType Leaf) -or $sp -notmatch '\.ps1$') { throw "step script not found or not a .ps1: $sp" }
    $resolved = (Resolve-Path -LiteralPath $sp).Path
    $isMerge = ([string]$h.station -eq 'merge') -or ((Split-Path -Path $resolved -Leaf) -eq 'merge.ps1')
    @{
        script = $resolved; args = $(if ($h.args) { $h.args } else { @{} })
        replay = $(if ($h.replay -eq 'unsafe') { 'unsafe' } else { 'safe' }); approve = $(if ($isMerge) { $true } else { [bool]$h.approve })
        timeoutSec = $(if ($h.timeoutSec) { [int]$h.timeoutSec } else { $TimeoutSec }); maxMB = $(if ($h.maxMB) { [int]$h.maxMB } else { $MaxMB })
        maxLogMB = $(if ($h.maxLogMB) { [double]$h.maxLogMB } else { $MaxLogMB }); hungSec = $(if ($null -ne $h.hungSec) { [int]$h.hungSec } else { $HungSec })
        retries = $(if ($null -ne $h.retries) { [int]$h.retries } else { $Retries })
        mustMatch = $(Test-Rx ([string]$h.mustMatch)); mustNotMatch = $(Test-Rx ([string]$h.mustNotMatch))
        # rework loop: when this step's taster check fails, go back to the named station (once by default) instead of quarantining
        reworkTo = $(if ($h.reworkTo -match '^[\w-]{1,40}$') { [string]$h.reworkTo } else { '' }); reworkMax = $(if ($null -ne $h.reworkMax) { [int]$h.reworkMax } else { 1 })
    }
}
function Test-Rx([string]$rx) {
    if (-not $rx) { return '' }
    if ($rx.Length -gt 200) { throw 'taster patterns must be 200 characters or fewer' }
    try { [void][regex]::new($rx) } catch { throw "taster pattern is not a valid regex: $rx" }
    $rx
}

# ---- the chores (TARGET W2 D3): housekeeping on its own clock and lock, off the start/kill path. Run by `kitchen.ps1 chores` (the
# Kitchen-Chores task, every 2 minutes) or, while that task is absent or stale, by the tick after its first pass. The chores never start
# a worker (Start-Step refuses while they run), and a slow chore (the ledger, GitHub) can no longer delay a start, a kill or a wake.
function Invoke-Chores {
    $cl = New-Object Threading.Mutex($false, "Global\brain-kitchen-chores-$(Sha $root.ToLowerInvariant())")
    $have = $false; try { $have = $cl.WaitOne(0) } catch [Threading.AbandonedMutexException] { $have = $true }
    if (-not $have) { $cl.Dispose(); Say 'the chores are already running elsewhere; this run steps aside'; return }
    $script:inChores = $true
    try {
        Invoke-ChoreFoldPending   # TD-EH-18: lines a busy log pushed to events-pending-<pid>.jsonl rejoin events.jsonl first
        Tick-Phase 'fold'
        Invoke-PendingChefUpdates
        Tick-Phase 'chef'
        try { Update-FreezeView $root } catch { }   # Chef's read-only freeze line (<kitchen>\freeze.json, rebuilt when a kitchen.repo.json changes or every 10 minutes)
        Tick-Phase 'freeze'
        Invoke-ChoreCiLooks   # the CI looks the supervisor's pre-scan reads (it never takes one itself)
        Tick-Phase 'ci'
        Invoke-ChoreCiBudget   # TD-11: CI runs and minutes per Site this month (ci-budget.json; the pr station's hold reads it)
        Tick-Phase 'ci-budget'
        try { & (Join-Path $PSScriptRoot 'sous-chef.ps1') board -Write | Out-Null } catch { }   # the cooks' state for the board and the Chef app
        Tick-Phase 'board'
        & $PSCommandPath report -HtmlPath (Join-Path $root 'board.html') | Out-Null   # the live board: refreshed every tick, page reloads itself
        Tick-Phase 'report'
        $meta = Load-Meta
        # the Ledger (one true list of every idea, order and roadmap item, from proof): rebuilt every 5 minutes; it writes its own heartbeat
        if (-not $meta.lastLedger -or ((Now) - (ToUtc $meta.lastLedger)).TotalMinutes -ge 5) {
            try { & (Join-Path $PSScriptRoot 'ledger.ps1') build -Quiet | Out-Null } catch { }
            Enter-State; try { $m2 = Load-Meta; $m2.lastLedger = Iso (Now); Save-Meta $m2 } finally { Exit-State }
        }
        Tick-Phase 'ledger'
        if (-not $meta.lastDoctor -or ((Now) - (ToUtc $meta.lastDoctor)).TotalMinutes -ge 60) { & $PSCommandPath doctor -Quiet | Out-Null }
        Tick-Phase 'doctor'
        Invoke-ChoreGuards $meta
        Tick-Phase 'watchdog'
        Invoke-ChoreStanding
        Tick-Phase 'standing'
        # fix what breaks: a newly set-aside order gets a read-only diagnosis (live only, 3 a day, never a diagnosis of a diagnosis)
        if ($env:KITCHEN_NO_DIAGNOSE -ne '1' -and (Test-Path -LiteralPath (Join-Path $root 'LIVE'))) {
            try {
                $dg = & (Join-Path $PSScriptRoot 'diagnose.ps1') -Auto -Json | Out-String | ConvertFrom-Json
                foreach ($x in @($dg.started | Where-Object { $_.ok })) { Enter-State; try { Emit 'diagnose.started' ([string]$x.job) @{ detail = [string]$x.diagnosis } } finally { Exit-State } }
            } catch { }
        }
        Tick-Phase 'diagnose'
        # the autopilot: the best new idea becomes an Improve order (one at a time; merging stays Jordan's yes); the coach files an idea
        # to improve the pipeline itself after every few builds
        if ($env:KITCHEN_NO_AUTOPILOT -ne '1' -and (Test-Path -LiteralPath (Join-Path $root 'LIVE'))) {
            try {
                $ip = Join-Path $PSScriptRoot 'ideas.ps1'
                $co = & $ip coach -Json | Out-String | ConvertFrom-Json
                if ($co.filed) { Enter-State; try { Emit 'coach.filed' '' @{ detail = [string]$co.filed } } finally { Exit-State } }
                $ap = & $ip auto -Json | Out-String | ConvertFrom-Json
                if ($ap.built) { Enter-State; try { Emit 'autopilot.built' ([string]$ap.built.job) @{ detail = [string]$ap.built.idea } } finally { Exit-State } }
            } catch { }
        }
        Tick-Phase 'ideas'
    } finally { $script:inChores = $false; try { $cl.ReleaseMutex() } catch { }; $cl.Dispose() }
}
# TD-EH-26: the chores while the Owner has paused the Yard. Pausing once blinded every watcher (10-23: the last doctor run 14:09Z, the
# pause 14:17Z, nothing since), because the doctor ran only from the chores. Now a paused run keeps the read-only watchers on their usual
# hourly clock: the doctor's findings (-FindOnly: no reset, prune, archive or move) with the Watch (watch.ps1) and memory-truth inside it.
# Nothing that changes work runs: no Chef updates, no CI looks, no ledger rebuild, no off-drive backup, no standing orders, no diagnosis, no
# ideas. Folding events-pending lines back into the log (TD-EH-18) is not work, so it runs. Same lock as the chores, so a paused run
# and a chores run never overlap.
function Invoke-ChoresPaused {
    $cl = New-Object Threading.Mutex($false, "Global\brain-kitchen-chores-$(Sha $root.ToLowerInvariant())")
    $have = $false; try { $have = $cl.WaitOne(0) } catch [Threading.AbandonedMutexException] { $have = $true }
    if (-not $have) { $cl.Dispose(); Say 'the chores are already running elsewhere; this run steps aside'; return }
    $script:inChores = $true
    try {
        Invoke-ChoreFoldPending   # TD-EH-18: the log stays whole while paused too (a fold only moves lines into events.jsonl)
        Tick-Phase 'fold'
        $meta = Load-Meta
        # the newer of the last full run and the last findings-only run sets the clock; after resume the full doctor runs as soon as its
        # own lastDoctor is an hour old, so the cleanup a pause skipped is caught up at once
        $last = @(@($meta.lastDoctor, $meta.lastDoctorFind) | Where-Object { $_ } | ForEach-Object { ToUtc $_ } | Sort-Object -Descending | Select-Object -First 1)
        if (-not $last.Count -or ((Now) - $last[0]).TotalMinutes -ge 60) { & $PSCommandPath doctor -FindOnly -Quiet | Out-Null }
        Tick-Phase 'doctor'
    } finally { $script:inChores = $false; try { $cl.ReleaseMutex() } catch { }; $cl.Dispose() }
}
# the nightly backup, the Claude plan reading and the watchdog of Jordan's way in from the phone (real kitchen only)
function Invoke-ChoreGuards($meta) {
    # the Claude plan reading (5-hour / weekly use) goes stale when only Jordan's own chats use the plan: while AI cooks are on,
    # refresh it every 2 hours with one tiny haiku run, in the background (real kitchen only)
    $realRoot = $root -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))
    # the nightly copy OFF the C: drive (plain file copies, no AI): once a local day from 2 am, real kitchen only. A failed copy is told
    # once and tried again the next night (kitchen.json "backupDest" moves it; scripts/backup-state.ps1 says what it copies).
    if ($realRoot -and $env:KITCHEN_NO_BACKUP -ne '1' -and (Get-Date).Hour -ge 2 -and $meta.lastBackupDay -ne (Get-Date -Format 'yyyy-MM-dd')) {
        $bargs = @{ KitchenRoot = $root; Json = $true }; if ($config.backupDest) { $bargs.Dest = [string]$config.backupDest }
        $bo = try { & (Join-Path $PSScriptRoot '..\scripts\backup-state.ps1') @bargs | Out-String | ConvertFrom-Json } catch { [pscustomobject]@{ ok = $false; error = "$($_.Exception.Message)" } }
        Enter-State
        try {
            $meta = Load-Meta; $meta.lastBackupDay = Get-Date -Format 'yyyy-MM-dd'; Save-Meta $meta
            if ($bo.ok) { Emit 'backup' '' @{ detail = "$($bo.copied) file(s) to $($bo.dest)" } } else { Emit 'backup.failed' '' @{ detail = [string]$bo.error }; Alert 'MED' "Nightly backup off the C: drive failed: $($bo.error)" }
        } finally { Exit-State }
    }
    if ($realRoot -and (Test-Path -LiteralPath (Join-Path $root 'LIVE')) -and -not $env:KITCHEN_NO_WATCHDOG) {
        $pu = try { (Get-Content -LiteralPath (Join-Path $root 'plan-usage.json') -Raw | ConvertFrom-Json).claude } catch { $null }
        $mark = Join-Path $root 'plan-usage.refresh'
        # near a cap the sous chef holds claude back once the reading is 20 min old (fail closed), so refresh that often there
        $every = if ($pu -and ([double]$pu.fiveHour.used -ge 0.75 -or [double]$pu.sevenDay.used -ge 0.75)) { 20 } else { 120 }
        $recent = (Test-Path -LiteralPath $mark) -and ((Get-Date) - (Get-Item -LiteralPath $mark).LastWriteTime).TotalMinutes -lt $every
        if (-not $recent -and (-not $pu -or ((Now) - (ToUtc $pu.at)).TotalMinutes -ge $every)) {
            Set-Content -LiteralPath $mark -Value (Now).ToString('o')
            Start-Process pwsh -ArgumentList '-NoProfile', '-File', (Join-Path $PSScriptRoot 'sous-chef.ps1'), 'usage' -WindowStyle Hidden
        }
    }
    # watchdog for Jordan's way in from the phone (the real kitchen only, never a test root): the Board server and Tailscale
    if ($realRoot -and -not $env:KITCHEN_NO_WATCHDOG) {
        $fixed = @()
        $up = try { (Invoke-WebRequest 'http://127.0.0.1:7878/manifest.webmanifest' -TimeoutSec 3 -SkipHttpErrorCheck).StatusCode -eq 200 } catch { $false }
        # a task that reads Running while nothing answers is a stuck instance (IgnoreNew would drop a plain Start): stop it first
        $pt = if (-not $up) { Find-KitchenTask 'board' }   # Kitchen-Pass today, Tide-Board after S4 (scripts/task-names.json)
        if ($pt) { if ([string]$pt.State -eq 'Running') { Stop-ScheduledTask -TaskName $pt.TaskName; Start-Sleep -Seconds 1 }; Start-ScheduledTask -TaskName $pt.TaskName; $fixed += 'The Board server was down; restarted' }
        $tsx = 'C:\Program Files\Tailscale\tailscale.exe'
        if (Test-Path -LiteralPath $tsx) {
            $tstate = try { (& $tsx status --json 2>$null | Out-String | ConvertFrom-Json).BackendState } catch { '' }
            if ($tstate -ne 'Running' -and -not (Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath 'C:\Program Files\Tailscale\tailscale-ipn.exe'; $fixed += "Tailscale was $(if ($tstate) { $tstate } else { 'not answering' }); started its app"
            }
        }
        if ($fixed.Count) { Enter-State; try { Emit 'watchdog' '' @{ detail = ($fixed -join '; ') } } finally { Exit-State } }
    }
}
# a watcher order's last run is still alive: its pid is running and started within 2 minutes of the recorded start (a reused pid is not)
function Test-WatcherAlive($rec) {
    if (-not $rec -or -not $rec.pid -or -not $rec.at) { return $false }
    $gp = Get-Process -Id ([int]$rec.pid) -ErrorAction SilentlyContinue
    if (-not $gp) { return $false }
    try { return [math]::Abs(($gp.StartTime.ToUniversalTime() - (ToUtc $rec.at)).TotalSeconds) -lt 120 } catch { return $true }   # (start time unreadable: alive, not guessed dead)
}
# standing orders (kitchen.json "standing"): recipes the kitchen cooks by itself on a schedule
function Invoke-ChoreStanding([switch]$WatchersOnly) {
    # standing orders (kitchen.json "standing"): recipes the kitchen cooks by itself on a schedule, e.g. the weekly model scout.
    # Only while the AI cooks are live. The first run is one period after the order is added (never a surprise run on install).
    # The stamp moves only after a SUCCESSFUL cook: a cook refused (swarm cap, a busy lock) used to cost a whole period (a week for the
    # model scout). A failing order is tried again at most every 15 minutes, and Jordan hears of it after 3 failures in a row. No new
    # copy is cooked while the last one is still alive (a weekend of capped cooks no longer piles up a scout a day).
    # Watcher orders (TD-EH-03b; "watcher": "<name>" in place of "recipe"): scripts\<name>.ps1 (KITCHEN_WATCHERS moves the folder, for
    # tests) started on this PC with -KitchenRoot, no AI cook, so no LIVE needed. They only read and report (the night inspection writes
    # the main status), so they also start while the Owner has paused the Yard (TD-EH-26: paused = start no work, still watch): the paused
    # Walkround calls this with -WatchersOnly. Started detached, so the chores and the Walkround never wait on a run that takes many
    # minutes; the stamp moves once it has started, and no second copy starts while the last one is alive (standingPid: pid + start).
    # "off": true keeps an order off unless kitchen.json "standingOn" names it: the repo defines it, the Owner's kitchen.json turns it on.
    $on = @($config.standingOn | ForEach-Object { [string]$_ })
    $isLive = Test-Path -LiteralPath (Join-Path $root 'LIVE')
    $orders = @(@($config.standing) | Where-Object { $_ -and (-not $_.off -or $on -contains [string]$_.name) -and ($_.watcher -or (-not $WatchersOnly -and $isLive)) })
    $due = @()
    if ($orders.Count) {
        Enter-State
        try {
            $meta = Load-Meta
            if (-not $meta.standing) { $meta.standing = @{} }
            if (-not $meta.standingTry) { $meta.standingTry = @{} }
            if (-not $meta.standingPid) { $meta.standingPid = @{} }
            $aliveRecipes = if (@($orders | Where-Object { -not $_.watcher }).Count) { @(All-Jobs -Live | Where-Object { $_.status -notin $terminal } | ForEach-Object { [string]$_.recipe }) } else { @() }
            foreach ($so in $orders) {
                $what = if ($so.watcher) { [string]$so.watcher } else { [string]$so.recipe }
                $nm = [string]$so.name; if ($nm -notmatch '^[\w -]{1,40}$' -or $what -notmatch '^[\w-]{1,40}$') { continue }
                $every = [double]$(if ($so.everyHours) { $so.everyHours } else { 168 })
                if (-not $meta.standing[$nm]) { $meta.standing[$nm] = Iso (Now); continue }
                # atHour (local clock, 0-23): once a day, at or after that hour; the overnight hunt runs at 1 am
                $isDue = if ($null -ne $so.atHour) {
                    $lastLocal = (ToUtc $meta.standing[$nm]).ToLocalTime(); $nowLocal = (Now).ToLocalTime()
                    $nowLocal.Hour -ge [int]$so.atHour -and $lastLocal.Date -lt $nowLocal.Date
                } else { ((Now) - (ToUtc $meta.standing[$nm])).TotalHours -ge $every }
                if (-not $isDue) { continue }
                $try = $meta.standingTry[$nm]
                if ($try -and $try.at -and ((Now) - (ToUtc $try.at)).TotalMinutes -lt 15) { continue }
                if ($so.watcher) { if (Test-WatcherAlive $meta.standingPid[$nm]) { continue } }
                elseif ($aliveRecipes -contains [string]$so.recipe) { continue }
                $meta.standingTry[$nm] = @{ at = Iso (Now); fails = $(if ($try) { [int]$try.fails } else { 0 }) }
                $due += $so
            }
            Save-Meta $meta
        } finally { Exit-State }
    }
    foreach ($so in $due) {   # outside the lock: cooking adds a job, which takes the lock itself
        $nm = [string]$so.name; $ok = $false; $detail = ''; $started = $null
        try {
            if ($so.watcher) {
                $wdir = if ($env:KITCHEN_WATCHERS) { $env:KITCHEN_WATCHERS } else { Join-Path $PSScriptRoot '..\scripts' }
                $wsp = Join-Path $wdir "$([string]$so.watcher).ps1"
                if (-not (Test-Path -LiteralPath $wsp)) { $detail = "no watcher script at $wsp" }
                else {
                    $wp = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$wsp`"", '-KitchenRoot', "`"$root`"") -PassThru -WindowStyle Hidden
                    $started = @{ pid = $wp.Id; at = Iso (Now) }; $ok = $true; $detail = "started $([string]$so.watcher) (pid $($wp.Id))"
                }
            } else {
                $vars = @{}; if ($so.vars) { foreach ($k in $so.vars.Keys) { $vars[$k] = [string]$so.vars[$k] } }
                $o = & (Join-Path $PSScriptRoot 'cook.ps1') -Recipe ([string]$so.recipe) -Vars $vars -Json | Out-String
                $detail = $o.Trim(); $cj = try { $o | ConvertFrom-Json } catch { $null }; $ok = [bool]($cj -and $cj.ok)
            }
        } catch { $detail = "$($_.Exception.Message)" }
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
        Enter-State
        try {
            $meta = Load-Meta; if (-not $meta.standing) { $meta.standing = @{} }; if (-not $meta.standingTry) { $meta.standingTry = @{} }
            if ($started) { if (-not $meta.standingPid) { $meta.standingPid = @{} }; $meta.standingPid[$nm] = $started }
            if ($ok) { $meta.standing[$nm] = Iso (Now); $meta.standingTry.Remove($nm); Emit $(if ($started) { 'standing.started' } else { 'standing.cooked' }) '' @{ name = $nm; detail = $detail } }
            else {
                $fails = 1 + $(if ($meta.standingTry[$nm]) { [int]$meta.standingTry[$nm].fails } else { 0 }); $meta.standingTry[$nm] = @{ at = Iso (Now); fails = $fails }
                Emit 'standing.failed' '' @{ name = $nm; fails = $fails; detail = $detail }
                if ($fails -eq 3) { Alert 'MED' "Standing order '$nm' could not be cooked 3 times in a row; it is tried again every 15 minutes" }
            }
            Save-Meta $meta
        } finally { Exit-State }
    }
}
# The CI looks (engine B4): for each order at its merge gate with a pull request, GitHub's CI is looked at again when the saved look
# (results\<job>.ci.json) is over 90 s old, oldest look first, through ci-wait (bounded) within one 30 s budget per chores run
# (KITCHEN_CI_BUDGET_SEC). Orders the budget did not reach are first next time; that is logged ('ci.budget'), never dropped silently.
# TD-EH-15: a look that failed (gh down or signed out, a crash, the time limit) saved its reason in that file {state 'error', error, at}
# (github-lib.ps1 Save-CiLookError). Each gate's failed look is logged once as ci.look.failed {error, at} when its reason is new (the
# reason last logged per order: supervisor.json ciLookFailed), so an hour of GitHub being down is one line per order, not one a minute.
function Invoke-ChoreCiLooks {
    . (Join-Path $PSScriptRoot 'github-lib.ps1')   # (Invoke-CiLookBounded, Read-JsonFile; functions only, scoped to this run)
    $budget = if ($env:KITCHEN_CI_BUDGET_SEC -match '^\d+$') { [int]$env:KITCHEN_CI_BUDGET_SEC } else { 30 }
    $gates = [Collections.Generic.List[string]]::new()
    $due = @(foreach ($pj in (All-Jobs -Live)) {
            if ($pj.status -notin 'pending', 'waiting-approval' -or -not $pj.steps -or [int]$pj.cursor -ge $pj.steps.Count) { continue }
            $ps = $pj.steps[[int]$pj.cursor]
            if (-not $ps.approve -or (Station-Name $ps) -ne 'merge' -or -not (Test-Path -LiteralPath (Join-Path $root "results\$($pj.id).pr.json"))) { continue }
            $gates.Add([string]$pj.id)
            $cp = Join-Path $root "results\$($pj.id).ci.json"
            $age = if (Test-Path -LiteralPath $cp) { ((Get-Date) - (Get-Item -LiteralPath $cp).LastWriteTime).TotalSeconds } else { 1e9 }
            if ($age -gt 90) { [pscustomobject]@{ id = [string]$pj.id; age = $age } }
        }) | Sort-Object age -Descending
    $sw = [Diagnostics.Stopwatch]::StartNew(); $looked = 0
    foreach ($d in $due) {
        $left = $budget - $sw.Elapsed.TotalSeconds; if ($left -lt 5) { break }
        $null = Invoke-CiLookBounded $root $d.id ([int][math]::Min(60, $left))
        $looked++
    }
    # every gate's saved look, whoever took it (these looks or automerge's own): a reason not logged yet is logged now
    $failed = @{}
    foreach ($id in $gates) { $c = Read-JsonFile (Join-Path $root "results\$id.ci.json"); if ($c -and [string]$c.state -eq 'error') { $failed[$id] = @{ error = [string]$c.error; at = [string]$c.at } } }
    $meta0 = Load-Meta; $known = if ($meta0.ciLookFailed -is [Collections.IDictionary]) { $meta0.ciLookFailed } else { @{} }
    $new = @($failed.Keys | Where-Object { [string]$known[$_] -ne $failed[$_].error })
    $gone = @($known.Keys | Where-Object { -not $failed.ContainsKey($_) })
    if ($looked -lt $due.Count -or $new.Count -or $gone.Count) {
        Enter-State
        try {
            if ($looked -lt $due.Count) { Emit 'ci.budget' '' @{ looked = $looked; left = $due.Count - $looked; sec = [int]$sw.Elapsed.TotalSeconds } }
            foreach ($id in $new) { Emit 'ci.look.failed' $id @{ error = $failed[$id].error; at = $failed[$id].at } }
            if ($new.Count -or $gone.Count) {
                $meta = Load-Meta; $m = @{}; foreach ($id in $failed.Keys) { $m[$id] = $failed[$id].error }
                $meta.ciLookFailed = $m; Save-Meta $meta
            }
        } finally { Exit-State }
    }
}
# TD-EH-18: a line Emit could not add to events.jsonl (the log stayed busy through its retries) went to events-pending-<pid>.jsonl. Site
# cleanup folds those lines back into events.jsonl, so the Stop-work order (Breaker-State) and the Board's event index see them.
#  1. One fold at a time per Yard: its own named lock. A second cleanup that finds it taken skips; the next run folds.
#  2. Each pending file is claimed by renaming it to <name>.fold (atomic). A writer still appending keeps its file until the next run, and
#     that writer's next line starts a fresh pending file, so nothing is written into a claimed file.
#  3. A claim's lines are added to events.jsonl in one write, then the claim is deleted. Lines already at the end of the log are skipped,
#     so a claim left by a fold that was cut off between its write and its delete never adds a line twice.
# A log still busy, or a claim that cannot be read, waits for the next run: no line is dropped. Logged as events.folded {files, lines}.
function Invoke-ChoreFoldPending {
    $lk = New-Object Threading.Mutex($false, "Global\brain-kitchen-fold-$(Sha $root.ToLowerInvariant())")
    $have = $false; try { $have = $lk.WaitOne(0) } catch [Threading.AbandonedMutexException] { $have = $true }
    if (-not $have) { $lk.Dispose(); return }
    try {
        $files = 0; $lines = 0; $utf8 = [Text.UTF8Encoding]::new($false); $nl = [Environment]::NewLine
        for ($round = 0; $round -lt 2; $round++) {   # (a second round claims a file that waited behind its writer's older claim)
            $waited = 0
            foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter 'events-pending-*.jsonl' -File -ErrorAction SilentlyContinue)) {
                if ($f.Name -notmatch '^events-pending-\d+\.jsonl$') { continue }
                $claim = "$($f.FullName).fold"
                if ([IO.File]::Exists($claim)) { $waited++; continue }   # that writer's older claim is folded first (below), then this one
                try { [IO.File]::Move($f.FullName, $claim) } catch { }   # busy (a writer mid-line): the next run claims it
            }
            foreach ($c in @(Get-ChildItem -LiteralPath $root -Filter 'events-pending-*.jsonl.fold' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)) {
                if ($c.Name -notmatch '^events-pending-\d+\.jsonl\.fold$') { continue }
                $text = $null; try { $text = [IO.File]::ReadAllText($c.FullName) } catch { continue }
                $rows = @($text.TrimStart([char]0xFEFF) -split '\r?\n' | Where-Object { $_.Trim() })
                if ($rows.Count) {
                    $tail = $null
                    for ($i = 0; $i -lt 10; $i++) {
                        try { $tail = if ([IO.File]::Exists($eventsPath)) { @(Get-Content -LiteralPath $eventsPath -Tail ($rows.Count + 2000) -Encoding utf8 -ErrorAction Stop) } else { @() }; break }
                        catch { Start-Sleep -Milliseconds (50 + (Get-Random -Maximum 150)) }
                    }
                    if ($null -eq $tail) { continue }
                    $seen = [Collections.Generic.HashSet[string]]::new([string[]]@($tail | ForEach-Object { ([string]$_).TrimStart([char]0xFEFF) }))
                    $add = @($rows | Where-Object { -not $seen.Contains($_) })
                    if ($add.Count) {
                        $done = $false
                        for ($i = 0; $i -lt 10; $i++) {
                            try { [IO.File]::AppendAllText($eventsPath, (($add -join $nl) + $nl), $utf8); $done = $true; break }
                            catch { Start-Sleep -Milliseconds (50 + (Get-Random -Maximum 150)) }
                        }
                        if (-not $done) { continue }
                        $lines += $add.Count
                    }
                }
                try { [IO.File]::Delete($c.FullName); $files++ } catch { }
            }
            if (-not $waited) { break }
        }
        if ($files) { Enter-State; try { Emit 'events.folded' '' @{ files = $files; lines = $lines } } finally { Exit-State } }
    } finally { try { $lk.ReleaseMutex() } catch { }; $lk.Dispose() }
}
# TD-11 CI budgets (kitchen/ci-budget-lib.ps1): every KITCHEN_CI_COUNT_EVERY_MIN (10) minutes, within KITCHEN_CI_COUNT_BUDGET_SEC (20 s),
# count this month's CI runs and billed minutes of every Tower the orders and the Sites registry name. Only the real Yard asks GitHub;
# a test Yard opts in with KITCHEN_CI_COUNT=1 (and a fake gh), so no test reaches the network. A failure is logged, never a stop.
# Only with a Sites registry (kitchen.json "sites" with at least one Site; review #11 F2): no registry = no count, no GitHub call, no
# ci-budget.json and so no Board banner, whatever KITCHEN_CI_COUNT says. A registry that cannot be read goes on to Update-CiBudget, which
# writes only the problem (no GitHub call), so the Board names it.
function Test-CiCountOn {
    try { $r = Read-SiteRegistry $root } catch { return $true }
    [bool]($r.sites -is [Collections.IDictionary] -and $r.sites.Count)
}
function Invoke-ChoreCiBudget {
    $realRoot = $root -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))
    if ($env:KITCHEN_CI_COUNT -ne '1' -and -not ($realRoot -and $env:KITCHEN_CI_COUNT -ne '0')) { return }
    if (-not (Test-CiCountOn)) { return }
    $every = if ($env:KITCHEN_CI_COUNT_EVERY_MIN -match '^\d+$') { [int]$env:KITCHEN_CI_COUNT_EVERY_MIN } else { 10 }
    $m = Load-Meta; if ($m.lastCiCount -and ((Now) - (ToUtc $m.lastCiCount)).TotalMinutes -lt $every) { return }
    Enter-State; try { $m = Load-Meta; $m.lastCiCount = Iso (Now); Save-Meta $m } finally { Exit-State }
    $sec = if ($env:KITCHEN_CI_COUNT_BUDGET_SEC -match '^\d+$') { [int]$env:KITCHEN_CI_COUNT_BUDGET_SEC } else { 20 }
    try {
        . (Join-Path $PSScriptRoot 'ci-budget-lib.ps1')
        $towers = @(All-Jobs -Live | ForEach-Object { Get-JobTower $_ } | Where-Object { $_ } | Select-Object -Unique)
        $null = Update-CiBudget $root $towers $sec
    } catch { Enter-State; try { Emit 'ci.count.failed' '' @{ detail = "$($_.Exception.Message)" } } finally { Exit-State } }
}
# The Kitchen-Chores task ran (started a chores run) within KITCHEN_CHORES_STALE_SEC (300 s): then the tick leaves the chores to it.
# Absent (never ran) or stale (stopped, disabled, hung): the tick runs them itself after its first pass, as before W2.
function Test-ChoresByTask {
    $m = Load-Meta; if (-not $m.choresTaskAt) { return $false }
    $stale = if ($env:KITCHEN_CHORES_STALE_SEC -match '^\d+$') { [int]$env:KITCHEN_CHORES_STALE_SEC } else { 300 }
    try { ((Now) - (ToUtc $m.choresTaskAt)).TotalSeconds -lt $stale } catch { $false }
}
# ---- the tick's passes (TARGET W2, J252): a finished step touches run\WAKE (kitchen-step.ps1). After a pass, a WAKE that appeared
# meanwhile means another pass at once, while the tick has run under 45 s (KITCHEN_TICK_WINDOW_SEC) and for at most 10 passes
# (KITCHEN_TICK_MAX_PASSES). A scheduled tick (its own process: pwsh -File kitchen.ps1 tick, on the real kitchen) also waits for a wake
# until 45 s after its start, so a step that finishes between ticks wakes the next one within a second (KITCHEN_TICK_LINGER_SEC sets
# that wait anywhere; 0 turns it off). The wait is not counted as slowness (tick.slow); 'tick.drained' {passes, stop} when it ran more.
$script:passes = 0; $script:drainStop = ''; $script:wakePath = Join-Path $runDir 'WAKE'
function Get-TickEnvInt([string]$name, [int]$default) { $v = [Environment]::GetEnvironmentVariable($name); if ($v -match '^\d+$') { [int]$v } else { $default } }
function Invoke-SupervisePass {
    try { [IO.File]::Delete($script:wakePath) } catch { }   # a wake from before this pass is this pass's work
    if ($script:passes -gt 0) { $script:gapFrom = Now }   # (a later pass: sleep is measured from its own start)
    $script:passes++
    Invoke-Tick
}
function Get-TickLingerSec {
    $own = @([Environment]::GetCommandLineArgs() | Where-Object { [string]$_ -like '*kitchen.ps1' }).Count -gt 0
    $real = [IO.Path]::GetFullPath($root) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))
    Get-TickEnvInt 'KITCHEN_TICK_LINGER_SEC' $(if ($own -and $real) { 45 } else { 0 })
}
function Invoke-TickDrain([double]$lingerSec) {
    $window = Get-TickEnvInt 'KITCHEN_TICK_WINDOW_SEC' 45; $maxPasses = Get-TickEnvInt 'KITCHEN_TICK_MAX_PASSES' 10
    while ($true) {
        $el = ((Now) - $script:tickFrom).TotalSeconds
        if ($script:passes -ge $maxPasses) { $script:drainStop = 'passes'; break }
        if ($el -ge $window) { $script:drainStop = 'time'; break }
        if ([IO.File]::Exists($script:wakePath)) { Tick-Phase 'linger'; Invoke-SupervisePass; continue }
        if ($el -ge $lingerSec) { $script:drainStop = 'idle'; break }
        $t0 = Now; Start-Sleep -Milliseconds 250
        # the PC slept while this tick waited: one pass measures the gap and moves the running steps' clocks, then the next tick goes on
        if (((Now) - $t0).TotalSeconds -gt 30) { Tick-Phase 'linger'; Invoke-SupervisePass; $script:drainStop = 'resumed'; break }
    }
    Tick-Phase 'linger'
}

switch ($Action) {
    'add' {
        $depth = Get-Depth
        if ($depth -lt 0) { Die 'BRAIN_AGENT_DEPTH is not a number; refusing' }
        if ($depth -ge 2) { Enter-State; try { Emit 'spawn.refused' $env:KITCHEN_JOB @{ reason = "depth $depth" } } finally { Exit-State }; Die "depth cap: an agent at depth $depth may not add jobs" 3 }
        $recName = $null; $recVars = $null
        try {
            if ($SpecPath) {
                $spec = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json -AsHashtable
                $Name = [string]$spec.name; $steps = @($spec.steps | ForEach-Object { New-Step $_ })
                if ($spec.recipe) { $recName = [string]$spec.recipe }
                if ($null -ne $spec.vars) { $recVars = $spec.vars }
            } else {
                $steps = @(New-Step @{ script = $(if ($Script -match '^[\w-]{1,40}$' -and -not (Test-Path -LiteralPath $Script)) { Resolve-Station $Script } else { $Script }); args = $ScriptArgs; replay = $Replay; approve = [bool]$Approve; mustMatch = $MustMatch; mustNotMatch = $MustNotMatch; retries = $Retries; timeoutSec = $TimeoutSec; maxMB = $MaxMB; maxLogMB = $MaxLogMB; hungSec = $HungSec })
            }
        } catch { Die $_.Exception.Message }
        if (-not $Name -or $Name -match '[|\r\n]') { Die 'a job needs a -Name without pipes or newlines' }
        if (-not $steps.Count) { Die 'a job needs at least one step' }
        Enter-State
        try {
            # counted from jobs-index.json (status and parent of every jobs\ file; only files that changed are opened)
            $ur = Update-KitchenJobs $root 'index'; $ix = $ur.index.Values
            if ($ur.rebuilt) { Emit 'jobs.index.rebuilt' '' @{ reason = $ur.rebuilt; jobs = $ur.index.Count; read = $ur.read } }
            # the queue cap stops a runaway: past maxQueued orders waiting to begin, adds are refused (orders under way are held to
            # maxLive by the tick, not refused here; finished, stopped and set-aside ones never count)
            $queued = @($ix | Where-Object { [string]$_.s -eq 'pending' }).Count
            if ($queued -ge $MaxQueued) { Emit 'spawn.refused' $env:KITCHEN_JOB @{ reason = "queue cap $MaxQueued" }; Die "swarm cap: $MaxQueued orders already queued" }
            $parent = [string]$env:KITCHEN_JOB
            if ($parent -and @($ix | Where-Object { [string]$_.p -eq $parent }).Count -ge $MaxChildren) {
                Emit 'spawn.refused' $parent @{ reason = "child cap $MaxChildren" }; Die "child cap: $parent already has $MaxChildren child jobs"
            }
            $n = Next-Id
            $j = @{ id = "J$n"; name = $Name; status = 'pending'; cursor = 0; attempt = 0; depth = $depth; parent = $parent; steps = $steps
                    run = $null; notBefore = $null; approval = $null; history = @(); created = Iso (Now) }
            if ($recName) { $j.recipe = $recName }
            if ($null -ne $recVars) { $j.vars = $recVars }
            Set-NewJobSite $j
            Save-Job $j; Save-NextId ($n + 1)
            Emit 'job.added' $j.id @{ name = $Name; steps = $steps.Count; depth = $depth; parent = $parent }
            Write-Output "added $($j.id) $Name ($($steps.Count) step(s))"
        } finally { Exit-State }
    }
    'tick' {
        # Jordan paused the kitchen on purpose (kitchen.ps1 pause): the scheduled task and Chef's kicks keep calling, and every tick only minds
        # the steps already running (TD-EH-13: time, memory, log and heartbeat limits, exits recorded); no inbox, no new work, no chores
        $paused = Test-Path -LiteralPath (Join-Path $root 'PAUSED')
        if ($paused) { Say 'the Yard is paused by the Owner: running work orders are still watched (time, memory, log, heartbeat); nothing new starts (kitchen.ps1 resume starts it again)' }
        # one tick at a time per kitchen: the scheduled tick and a Chef kick used to run together, both handling the same rail tickets and
        # diagnoses (twice the orders, twice the cloud runs) until the loser threw. A tick that finds another one running touches run\WAKE
        # (the running one, waiting for wakes, takes a pass for it at once) and steps aside after up to 10 s.
        $tickLock = New-Object Threading.Mutex($false, "Global\brain-kitchen-tick-$(Sha $root.ToLowerInvariant())")
        $haveTick = $false; try { $haveTick = $tickLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveTick = $true }
        if (-not $haveTick) {
            try { [IO.File]::WriteAllText($script:wakePath, (Iso (Now))) } catch { }
            try { $haveTick = $tickLock.WaitOne(1000 * (Get-TickEnvInt 'KITCHEN_TICK_WAIT_SEC' 10)) } catch [Threading.AbandonedMutexException] { $haveTick = $true }
        }
        if (-not $haveTick) { Say 'another tick is running; this one steps aside'; break }
        try {   # (released in the finally at the end of this action)
        $script:inTickAction = $true; Start-TickClock
        Mark-TickBegan
        if ($paused) {   # (the finally below still records the Walkround's end and frees the tick lock)
            Invoke-Tick -Paused
            if (-not (Test-ChoresByTask)) { Invoke-ChoresPaused }   # TD-EH-26: the watchers keep their clock while paused (findings only)
            break
        }
        # front ends first (other bots drop requests in inbox\), then the supervisor pass (and more while steps finish), then the chores
        # when no Kitchen-Chores task runs them, then (a scheduled tick) waiting for wakes until 45 s after the start
        $api = Join-Path $PSScriptRoot 'kitchen-api.ps1'
        if (Test-Path -LiteralPath $api) { try { & $api -ProcessInbox | Out-Null } catch { Enter-State; try { Emit 'tick.error' '' @{ detail = "inbox: $($_.Exception.Message)" } } finally { Exit-State } } }
        Tick-Phase 'inbox'
        Invoke-SupervisePass
        Invoke-TickDrain 0
        if (-not (Test-ChoresByTask)) { Invoke-Chores }
        $linger = Get-TickLingerSec; if ($linger -gt 0) { Invoke-TickDrain $linger }   # (a tick that does not wait for wakes: one drain, before the chores, as J252 has it)
        } finally {
            # the end of this tick, for the next one's sleep check, and tick.slow (a tick that threw still records its end)
            try { Finish-Tick } catch { }
            try { $tickLock.ReleaseMutex() } catch { }; $tickLock.Dispose()
        }
        if (-not $Quiet) { & $PSCommandPath status }
    }
    'chores' {
        # TD-EH-26: while paused, only the read-only watchers run (Invoke-ChoresPaused); this used to return here and blind them all
        $paused = Test-Path -LiteralPath (Join-Path $root 'PAUSED')
        if ($paused) { Say 'the Yard is paused by the Owner: only the watchers run (doctor findings, the Watch, memory-truth); no cleanup, nothing that changes work' }
        # choresTaskAt tells the tick that chores run outside it (Test-ChoresByTask); lastChoresEnd says when a run last finished
        Enter-State; try { $m = Load-Meta; $m.choresTaskAt = Iso (Now); Save-Meta $m } finally { Exit-State }
        try { if ($paused) { Invoke-ChoresPaused } else { Invoke-Chores } }
        finally { Enter-State; try { $m = Load-Meta; $m.lastChoresEnd = Iso (Now); Save-Meta $m } finally { Exit-State } }
    }
    'doctor' {
        # self-check and redundancy: damaged files set aside, a daily backup of the live jobs (7 days kept), old run files pruned and
        # finished orders archived. The state lock is held only to read the jobs, to archive and to write supervisor.json (data-growth
        # R3): the backup copy, the prunes and the watchers run outside it, so an add, approve or kill never waits on them. Logged as
        # doctor {ms, lockMs}.
        # TD-EH-26: -FindOnly, and always while the Owner has paused the Yard, the doctor only finds: nothing is reset, pruned, archived or
        # moved (the daily backup copy is still taken, and the watchers still run). The findings say what a full run would have fixed.
        $lookOnly = [bool]$FindOnly -or (Test-Path -LiteralPath (Join-Path $root 'PAUSED'))
        $report = [ordered]@{ ok = $true; findOnly = $lookOnly; problems = @(); backup = ''; prunedRunFiles = 0; prunedEventFiles = 0; archived = 0; ms = 0; lockMs = 0 }
        $dsw = [Diagnostics.Stopwatch]::StartNew(); $lsw = [Diagnostics.Stopwatch]::new()
        $lsw.Start(); Enter-State
        try {
            $jobs = All-Jobs   # every jobs\ file (the worktree prune needs the finished ones too); sets damaged files aside and alerts
            $bad = @(Get-ChildItem -LiteralPath $corruptDir -File -ErrorAction SilentlyContinue)
            if ($bad.Count) { $report.problems += "$($bad.Count) damaged job file(s) in corrupt\" }
            foreach ($j in $jobs) {
                if ($j.status -eq 'running' -and -not $j.run) {
                    if ($lookOnly) { $report.problems += "$($j.id) is running with no worker (left as is: findings only)" }
                    else { $j.status = 'pending'; Save-Job $j; $report.problems += "$($j.id) was running with no worker; reset to pending" }
                }
                # TD-EH-17: a requeue that died while re-cooking (cook.ps1 takes seconds) left the order closed with recooking set and no
                # replacement; nothing else ever reset it. After 15 minutes it goes back to the status it had (a record from before
                # recookAt: its file's write time; before recookFrom: quarantined), and the problem line alerts.
                if ($j.recooking) {
                    $rAt = try { if ($j.recookAt) { ToUtc $j.recookAt } else { (Get-Item -LiteralPath (Job-Path $j.id)).LastWriteTimeUtc } } catch { Now }
                    $rMin = ((Now) - $rAt).TotalMinutes
                    if ($rMin -gt 15 -and $lookOnly) { $report.problems += "$($j.id): a requeue stopped halfway $([int]$rMin) min ago (left as is: findings only)" }
                    elseif ($rMin -gt 15) {
                        $to = if ([string]$j.recookFrom -in 'quarantined', 'killed', 'failed') { [string]$j.recookFrom } else { 'quarantined' }
                        $j.status = $to; $j.recooking = $null; $j.recookFrom = $null; $j.recookAt = $null
                        $j.history += , @{ step = $j.cursor; attempt = $j.attempt; outcome = 'requeue.reset'; detail = "a requeue stopped halfway; put back to $to"; at = Iso (Now) }
                        Save-Job $j; Emit 'job.requeue.reset' $j.id @{ to = $to; ageMin = [int]$rMin }
                        $report.problems += "$($j.id): a requeue stopped halfway $([int]$rMin) min ago; the work order is back as it was before (requeue it again)"
                    }
                }
            }
        } finally { Exit-State; $lsw.Stop() }
        # the daily backup, outside the lock: Save-Job renames, so each copy is a whole old or a whole new file (a busy one is tried again)
        $bkRoot = Join-Path $root 'backups'; $bk = Join-Path $bkRoot ("daily\{0:yyyyMMdd}" -f (Get-Date))
        if (-not (Test-Path -LiteralPath $bk)) {
            New-Item -ItemType Directory -Force -Path $bk | Out-Null
            foreach ($f in (Get-JobFiles $root)) { for ($i = 0; $i -lt 3; $i++) { try { Copy-Item -LiteralPath $f.FullName -Destination $bk -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 100 } } }
            # the archive's summary and the id counter (the archived files themselves never change; scripts/backup-state.ps1 copies them off the C: drive)
            foreach ($f in (Join-Path $jobsDir 'next-id.txt'), (Join-Path (Get-JobsArchiveDir $root) 'index.jsonl')) { if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination $bk } }
            # the state that is hard to rebuild, not only the jobs: ideas and their history, Jordan's notes and Claude's handoff, the
            # autopilot's day, the settings and the merges done without a tap (scripts/backup-state.ps1 also copies these off the C: drive)
            foreach ($f in 'approvals.md', 'supervisor.json', 'ideas.json', 'lead.json', 'kitchen.json', 'autopilot.json', 'automerged.jsonl') { if (Test-Path -LiteralPath (Join-Path $root $f)) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination $bk } }
        }
        $report.backup = $bk
        if (-not $lookOnly) {   # (TD-EH-26: findings only prunes nothing; the daily backup above is a copy and still taken)
            try { $br = Invoke-BackupRetention $bkRoot; $report.backupsDaily = $br.daily; $report.backupsManual = $br.manual; $report.prunedBackups = $br.pruned } catch { $report.problems += "backup retention: $($_.Exception.Message)" }
            $live = @($jobs | Where-Object { $_.status -notin $terminal } | ForEach-Object { $_.id })
            foreach ($f in Get-ChildItem -LiteralPath $runDir -File) {
                $owner = ($f.Name -split '[-.]')[0]
                $keepDays = if ($f.Name -like '*.dish.md' -or $f.Name -like '*.cost.json') { 90 } else { 3 }   # answers and receipts are kept 90 days
                if ($owner -notin $live -and $f.LastWriteTime -lt (Get-Date).AddDays(-$keepDays)) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $report.prunedRunFiles++ } catch { } }
            }
            foreach ($f in Get-ChildItem -LiteralPath $root -Filter 'events-*.jsonl' -File -ErrorAction SilentlyContinue) {   # rotated event logs kept 14 days
                if ($f.LastWriteTime -lt (Get-Date).AddDays(-14)) { Remove-Item -LiteralPath $f.FullName -Force; $report.prunedEventFiles++ }
            }
            # scratch kitchens the test suites leave in TEMP when a run is cut short (a timeout, the tests station failing fast):
            # only our own test names, only untouched for 6 hours (no suite runs that long), never anything else in TEMP
            $report.prunedTestDirs = 0; $scratch = if ($env:KITCHEN_SCRATCH_DIR) { $env:KITCHEN_SCRATCH_DIR } else { [IO.Path]::GetTempPath() }
            foreach ($d in Get-ChildItem -LiteralPath $scratch -Directory -ErrorAction SilentlyContinue) {
                # kitchen-demo-<date>-<time> is demo.ps1's private kitchen (it was never pruned and piled up in TEMP)
                if ($d.Name -notmatch '^(kitchen-test-[a-z]*-?[0-9a-f]{32}(-[a-z0-9]{1,12})?|kt-[0-9a-f]{32}|kitchen-demo-\d{8}-\d{6})$') { continue }
                if ($d.LastWriteTime -gt (Get-Date).AddHours(-6)) { continue }
                try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $report.prunedTestDirs++ } catch { }
            }
            # Antigravity transcripts and logs in the kitchen's own agy homes (agy-home*, never Jordan's own ~\.gemini) grow ~200 MB a day
            # while cooking; a week is plenty to look back at a run. Only files untouched for 7 days, so a running cook's files are never hit.
            $report.prunedAgyFiles = 0; $agyBytes = 0
            foreach ($h in Get-ChildItem -LiteralPath $root -Directory -Filter 'agy-home*' -ErrorAction SilentlyContinue) {
                foreach ($sub in 'conversations', 'log') {
                    $dir = Join-Path $h.FullName ".gemini\antigravity-cli\$sub"
                    foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue) {
                        if ($f.LastWriteTime -lt (Get-Date).AddDays(-7)) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $report.prunedAgyFiles++; continue } catch { } }
                        $agyBytes += $f.Length
                    }
                }
            }
            $report.agyHomeMB = [int]($agyBytes / 1MB)   # what is left, so growth shows up in the doctor's report
        }
        $free = (Get-PSDrive -Name ($root.Substring(0, 1))).Free / 1GB
        if ($free -lt 5) { $report.problems += ("only {0:N1} GB free on the kitchen drive" -f $free) }
        # the watchers of the watchers (kitchen/watch.ps1: heartbeats, the tick, scheduled task results, GitHub sign-in, backups) and the
        # memory lobe (scripts/memory-truth.ps1: does memory still match the files). Both write a heartbeat in watch\. Real kitchen only
        # unless a test asks (they read the PC's tasks, gh and Claude's memory folder; KITCHEN_DOCTOR_WATCHERS names stand-ins in tests).
        $watchFound = @(); $drillDue = $false
        if (($root -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen')) -and $env:KITCHEN_NO_WATCH -ne '1') -or $env:KITCHEN_WATCH_IN_TEST -eq '1') {
            if ($env:KITCHEN_DOCTOR_WATCHERS) { $wlist = @($env:KITCHEN_DOCTOR_WATCHERS -split ';' | Where-Object { $_ } | ForEach-Object { @{ f = $_; k = 'problems' } }) }
            else {
                $wlist = @(@{ f = (Join-Path $PSScriptRoot 'watch.ps1'); k = 'problems' }, @{ f = (Join-Path $PSScriptRoot '..\scripts\memory-truth.ps1'); k = 'findings' })
                # the restore drill once a week: last night's off-drive backup restored into TEMP and every file parsed (writes watch\restore.json)
                $mw = Load-Meta; if (-not $mw.lastRestoreDrill -or ((Now) - (ToUtc $mw.lastRestoreDrill)).TotalDays -ge 7) { $wlist += @{ f = (Join-Path $PSScriptRoot '..\scripts\restore-drill.ps1'); k = 'problems' }; $drillDue = $true }
            }
            foreach ($w in $wlist) {
                # TD-EH-14: a watcher that gave no JSON report (it crashed, printed nothing, or printed null) is itself a finding, never "all good"
                try {
                    $global:LASTEXITCODE = 0
                    $o = & pwsh -NoProfile -NonInteractive -File $w.f -Json 2>$null | Select-Object -Last 1 | ConvertFrom-Json; $wx = $LASTEXITCODE
                    if ($null -eq $o) { $watchFound += "watcher $(Split-Path $w.f -Leaf) gave no report (exit $wx)" }
                    else { foreach ($p in @($o.($w.k))) { if ($p.say) { $watchFound += [string]$p.say } } }
                }
                catch { $watchFound += "a watcher could not run ($(Split-Path $w.f -Leaf)): $($_.Exception.Message)" }
            }
        }
        $report.watch = @($watchFound)
        # worktrees and kitchen/* branches of finished orders (closed, killed, done), outside the state lock (git can take a while on a big
        # checkout). Never of a waiting, set-aside or running one. A branch is only deleted once main has it (git branch -d): the work of a
        # closed or killed order that never merged stays reachable on its branch; only its checkout folder goes.
        $report.notes = @()
        if (-not $lookOnly) { try { $pr = Prune-Worktrees $jobs; $report.prunedWorktrees = $pr.worktrees; $report.prunedBranches = $pr.branches; $report.keptBranches = $pr.kept; $report.notes = @($pr.notes) } catch { $report.problems += "worktree prune: $($_.Exception.Message)" } }
        # finished orders (done, closed) untouched for archiveDays (kitchen.json, default 3) move to jobs\archive\yyyy-MM\ with a summary
        # line each in jobs\archive\index.jsonl, so every scan costs the live set. After the worktree prune, which still needed them.
        $archiveDays = if ($env:KITCHEN_ARCHIVE_DAYS -match '^\d+(\.\d+)?$') { [double]$env:KITCHEN_ARCHIVE_DAYS } elseif ($null -ne $config.archiveDays) { [double]$config.archiveDays } else { 3 }
        $lsw.Start(); Enter-State
        try {
            if (-not $lookOnly) { try { $ar = Invoke-KitchenJobArchive $root $archiveDays; $report.archived = $ar.archived; foreach ($s in $ar.skipped) { $report.problems += "not archived: $s" } } catch { $report.problems += "archive: $($_.Exception.Message)" } }
            $meta = Load-Meta
            # a findings-only run keeps its own clock (lastDoctorFind): lastDoctor stays the last full run, so resume catches the cleanup up
            if ($lookOnly) { $meta.lastDoctorFind = Iso (Now) } else { $meta.lastDoctor = Iso (Now) }
            if ($drillDue) { $meta.lastRestoreDrill = Iso (Now) }
            # alert on a watch finding only when the set changes (an hourly repeat of the same finding teaches Jordan to ignore alerts)
            $sig = (Sha (($watchFound | Sort-Object) -join "`n")); $newWatch = $watchFound.Count -and $sig -ne [string]$meta.lastWatchSig; $meta.lastWatchSig = $sig
            Save-Meta $meta
        } finally { Exit-State; $lsw.Stop() }
        # the slots (kitchen/scaler.ps1): the RAM-scaled limit for heavy steps, and which stations are measured light or heavy
        $ceilD = Get-ScalerCeiling; $wd = Read-KitchenWeights $root
        $lightD = @($wd.Keys | Where-Object { (Get-StationWeight $wd $_).light } | Sort-Object); $heavyD = @($wd.Keys | Where-Object { (Get-StationWeight $wd $_).measured } | Sort-Object)
        $report.slots = "heavy limit $(Get-KitchenScalerLimit $root $MaxConcurrent $ceilD) (scaler; maxConcurrent $MaxConcurrent, ceiling $ceilD); light: $(if ($lightD.Count) { $lightD -join ', ' } else { 'none measured yet' }); measured heavy: $(if ($heavyD.Count) { $heavyD -join ', ' } else { 'none yet (at most maxConcurrent)' })"
        $regD = Get-YardSites $root   # TD-7: the Sites registry's limits (no "sites" block: nothing added, the line is as before)
        if ($regD.sites.Count) { $report.slots += "; Sites: " + (@($regD.sites.Keys | Sort-Object | ForEach-Object { "$_ heavy $(if ($null -ne $regD.sites[$_].maxHeavy) { $regD.sites[$_].maxHeavy } else { 'any' }), share $($regD.sites[$_].share)" }) -join '; ') }
        foreach ($sp in $regD.problems) { $report.notes += "kitchen.json $sp" }
        $report.ok = -not $report.problems.Count; $report.ms = $dsw.ElapsedMilliseconds; $report.lockMs = $lsw.ElapsedMilliseconds
        Emit 'doctor' '' @{ ok = $report.ok; findOnly = $lookOnly; problems = ($report.problems -join '; '); watch = ($watchFound -join '; '); archived = $report.archived; ms = $report.ms; lockMs = $report.lockMs; slots = $report.slots; notes = ($report.notes -join '; ') }
        if (-not $report.ok) { Alert 'MED' ("Kitchen doctor: " + ($report.problems -join '; ')) }
        if ($newWatch) { Alert 'MED' ("The Watch found: " + ($watchFound -join '; ')) }
        if ($Json) { $report | ConvertTo-Json -Depth 4 } elseif (-not $Quiet) {
            Write-Output $(if ($report.ok) { 'DOCTOR OK' } else { 'DOCTOR found problems:' })
            if ($lookOnly) { Write-Output '  findings only (the Yard is paused, or -FindOnly): nothing was reset, pruned, archived or moved' }
            $report.problems | ForEach-Object { Write-Output "  - $_" }
            $watchFound | ForEach-Object { Write-Output "  watch: $_" }   # (the Watch's findings, a watcher that gave no report among them)
            $report.notes | ForEach-Object { Write-Output "  note: $_" }   # (a git cleanup call that failed: TD-EH-21)
            Write-Output "  slots: $($report.slots)"
            Write-Output "  backup: $($report.backup)"
        }
    }
    'watch' {
        $until = (Get-Date).AddSeconds($Seconds); $last = ''
        while ((Get-Date) -lt $until) {
            Invoke-ChoreCiLooks; Invoke-Tick; Invoke-PendingChefUpdates   # (watch does it all in one process: the CI looks the pre-scan reads too)
            $jobs = All-Jobs
            $line = ($jobs | ForEach-Object { "$($_.id):$($_.status)" }) -join ' '
            if ($line -ne $last) { Say ("{0:HH:mm:ss}  {1}" -f (Get-Date), $line); $last = $line }
            if (-not @($jobs | Where-Object { $_.status -in 'pending', 'running' }).Count) { break }
            Start-Sleep -Milliseconds 1000
        }
    }
    'status' {
        $jobs = All-Jobs; $b = Breaker-State
        $alerts = if (Test-Path -LiteralPath $alertsPath) { @(Get-Content -LiteralPath $alertsPath -Tail 5 | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
        # freeze windows as the supervisor last wrote them (freeze.json): status never runs git (10-22: rebuilding here took 145 s)
        $freeze = try { Read-FreezeView $root } catch { [ordered]@{ repos = @(); errors = @([ordered]@{ repo = ''; name = 'kitchen'; error = $_.Exception.Message }) } }
        # work orders grouped by Site (TD-5): its own vars.site, its Tower's, else the registry's. No order with a Site = exactly the
        # output from before Sites (no headers, no "sites" key); a registry that will not read is named, and grouping goes on without it.
        $reg = $null; $regErr = ''; try { $reg = Get-SiteList (Read-SiteRegistry $root) } catch { $regErr = $_.Exception.Message }
        $groups = @(Group-JobsBySite $jobs $reg); $bySite = $groups.Count -gt 1 -or ($groups.Count -eq 1 -and $groups[0].site)
        if ($Json) {
            $sj = @{ jobs = $jobs; failRate = $b.rate; breaker = $b.meta; alerts = $alerts; freeze = $freeze }
            if ($bySite) { $sj.sites = @($groups | ForEach-Object { [ordered]@{ site = $_.site; name = $_.name; jobs = @($_.jobs | ForEach-Object { [string]$_.id }) } }) }
            if ($regErr) { $sj.sitesError = $regErr }
            $ss = @(Get-SiteStopState $b.meta); if ($ss.Count) { $sj.siteStops = $ss }   # TD-8: only when a Site is stopped or paused
            $sj | ConvertTo-Json -Depth 12; break
        }
        Write-Output ("KITCHEN  {0} jobs  running {1}  done {2}  attention {3}  recent fail rate {4:P0}  spent today `${5:N2} of `${6:N2}" -f $jobs.Count,
            @($jobs | ? status -eq 'running').Count, @($jobs | ? status -eq 'done').Count,
            @($jobs | ? { $_.status -in 'quarantined', 'needs-human', 'waiting-approval', 'failed' }).Count, $b.rate, (Spend-Today), $DailyBudgetUsd)
        if ($regErr) { Write-Output "  SITES REGISTRY unreadable, Sites from work orders and Towers only: $regErr" }
        foreach ($g in $groups) {
            if ($bySite) { Write-Output ("  {0}: {1} work order{2}" -f $(if ($g.site) { "SITE $($g.site)$(if ($g.name -and $g.name -cne $g.site) { ' ' + $g.name })" } else { 'UNASSIGNED' }), $g.jobs.Count, $(if ($g.jobs.Count -ne 1) { 's' })) }
            foreach ($j in $g.jobs) {
                $last = if ($j.history.Count) { $j.history[-1].outcome + $(if ($j.history[-1].detail) { ": " + $j.history[-1].detail } else { '' }) } else { '' }
                if ($j.status -eq 'pending' -and $j.retryWait -and $j.notBefore -and (ToUtc $j.notBefore) -gt (Now)) { $last = "waiting $(Format-WaitMinutes ((ToUtc $j.notBefore) - (Now)).TotalSeconds) before retry; last $last" }
                Write-Output ("  {0,-4} {1,-16} {2,-16} step {3}/{4}  {5}" -f $j.id, $j.status, $j.name, [math]::Min($j.cursor + 1, $j.steps.Count), $j.steps.Count, $last)
            }
        }
        if ($b.meta.breakerTripped) {
            $bu = if ($b.meta.breakerOpenUntil) { ToUtc $b.meta.breakerOpenUntil } else { $null }
            Write-Output ("  STOP-WORK ORDER on: {0}" -f $(if ($bu -and $bu -gt (Now)) { "no new work for $(Format-WaitMinutes ($bu - (Now)).TotalSeconds) more" } else { 'one trial step runs before new work starts again' }))
        }
        foreach ($x in @(Get-SiteStopState $b.meta)) { Write-Output (Format-SiteStopLine $x) }   # TD-8: Sites stopped by the Owner or by their own Stop-work order
        Format-FreezeLines $freeze | ForEach-Object { Write-Output $_ }
        foreach ($a in $alerts) { Write-Output "  ALERT [$($a.level)] $($a.text)$(if ($a.sent -in 'off', 'failed', 'limited') { " (not sent: $($a.why))" })" }   # TD-EH-04: an unsent alert says so
    }
    'pause' {
        if ($Site) {   # TD-8: one Site stopped; its running work, the watchers and the other Sites go on (the tick reads PAUSED-<code>)
            $c = Resolve-PauseSite $Site $true
            Set-Content -LiteralPath (Join-Path $root "PAUSED-$c") -Value (Iso (Now))
            Enter-State; try { Emit 'site.paused' '' @{ site = $c } } finally { Exit-State }
            Write-Output "Site $c stopped: none of its new work starts until 'kitchen.ps1 resume -Site $c'; its running work, the watchers and the other Sites carry on"
            break
        }
        # a marker, not a scheduled-task change (that needs Jordan's yes): the dead-supervisor alarm in Chef and kitchen-check stays quiet
        # while it exists, so a deliberate stop is never mistaken for a broken task. Workers already running are still minded by each tick (TD-EH-13).
        Set-Content -LiteralPath (Join-Path $root 'PAUSED') -Value (Iso (Now))
        Enter-State; try { Emit 'kitchen.paused' '' } finally { Exit-State }
        $run = @(All-Jobs -Live | Where-Object { $_.status -eq 'running' }).Count
        Write-Output "Yard paused; each Walkround starts nothing new until 'kitchen.ps1 resume'$(if ($run) { " ($run work order(s) still running, still watched for time, memory, log and heartbeat; kitchen.ps1 kill -Id <J> stops one)" })"
    }
    'resume' {
        if ($Site) {   # TD-8: lifts that Site's stop only; the global pause, if any, still holds everything
            $c = Resolve-PauseSite $Site $false; $sf = Join-Path $root "PAUSED-$c"
            if (-not (Test-Path -LiteralPath $sf)) { Write-Output "Site $c was not stopped"; break }
            Remove-Item -LiteralPath $sf -Force
            Enter-State; try { Emit 'site.resumed' '' @{ site = $c } } finally { Exit-State }
            Write-Output "Site $c resumed$(if (Test-Path -LiteralPath (Join-Path $root 'PAUSED')) { '; the whole Yard is still paused (kitchen.ps1 resume)' } else { '; its new work starts on the next tick' })"
            break
        }
        $pf = Join-Path $root 'PAUSED'
        if (-not (Test-Path -LiteralPath $pf)) { Write-Output 'the kitchen was not paused'; break }
        Remove-Item -LiteralPath $pf -Force
        Enter-State; try { Emit 'kitchen.resumed' '' } finally { Exit-State }
        Write-Output 'kitchen resumed; the next tick runs as usual'
    }
    'approve' {
        Enter-State 90000   # Jordan's tap waits out a slow tick instead of failing with 'busy'
        try {
            $j = Load-Job $Id
            if (-not $j.approval) { Die "$Id is not waiting on an approval" }
            if ($j.approval.failed) { Die "$Id's approval request did not reach the queue; it is asked again on the next tick" }
            # checked under the state lock: a yes for an older ask (the job moved to its next gate meanwhile) never signs off the new one
            if ($ApprovalId -and ([string]$j.approval.id -ne $ApprovalId -or $j.approval.granted)) { Die "$Id now asks something else ($($j.approval.id)); look again before saying yes" }
            & $approvalsPs answer -ApprovalsPath $approvalsPath -Reply "$($j.approval.id) yes" | Out-Null
            Write-Output "approved $($j.approval.id) for $Id; it starts on the next tick"
        } finally { Exit-State }
    }
    'kill' {
        Enter-State 90000   # Jordan's tap waits out a slow tick instead of failing with 'busy'
        try {
            $targets = if ($All) { All-Jobs -Live } else { @(Load-Job $Id) }
            foreach ($j in $targets) {
                if ($j.status -in $terminal) { continue }
                if ($j.run -and (Is-Alive $j.run.pid $j.run.startMs)) { Kill-Tree $j.run.pid }
                $atVerify = $j.status -in 'running', 'pending', 'needs-human' -and $j.cursor -gt 0 -and $j.cursor -lt $j.steps.Count -and (Station-Name $j.steps[$j.cursor]) -eq 'verify' -and (Station-Name $j.steps[$j.cursor - 1]) -eq 'merge'
                $j.run = $null; $j.status = 'killed'; Save-Job $j; Emit 'job.killed' $j.id
                # stopping verify stops it before its undo: the merge stays on main unchecked, so Jordan is told so in plain words
                if ($atVerify) { Emit 'merge.unverified' $j.id @{ step = $j.cursor; kind = 'killed' }; Alert 'HIGH' "$($j.id) was stopped while being verified: it is merged on main but NOT verified" $j.id }
                Write-Output "killed $($j.id)"
            }
        } finally { Exit-State }
    }
    'close' {
        # a set-aside order closed for good (done another way, replaced, or unsafe): it leaves the set-aside list; nothing is deleted
        if ($Why.Trim().Length -lt 4) { Die 'close needs -Why (a few words on why it is closed)' }
        # nothing ends silently (gemini-brain projects/tide): a close names what replaced it (-ReplacedBy J12), gives proof it was done
        # another way (-Proof <commit, PR url or file>), or says plainly that it is dropped (-Why "dropped: ..."). The Ledger reads all three.
        $rb = $ReplacedBy.Trim().ToUpperInvariant(); $pf = $Proof.Trim(); $dropped = $Why.Trim() -match '^(?i)dropped\b'
        if ($rb -and $rb -notmatch '^J\d{1,5}$') { Die "-ReplacedBy must be an order id like J12 (got '$ReplacedBy')" }
        if ($pf -and -not (($pf -match '^[0-9a-f]{7,40}$') -or ($pf -match '^https://github\.com/[\w.-]+/[\w.-]+/(pull|commit)/\w+') -or (Test-Path -LiteralPath $pf))) { Die "-Proof must be a commit hash, a GitHub PR or commit url, or an existing file (got '$Proof')" }
        if (-not ($rb -or $pf -or $dropped)) { Die 'close needs an ending: -ReplacedBy J12 (what replaced it), -Proof <commit|PR url|file> (done another way), or -Why "dropped: <reason>"' }
        Enter-State
        try {
            $j = Load-Job $Id
            if ($j.status -notin 'quarantined', 'killed', 'failed') { Die "$Id is $($j.status); only set-aside jobs (quarantined, killed, failed) can be closed" }
            if ($rb) { if ($rb -eq $Id.ToUpperInvariant()) { Die 'an order cannot replace itself' }; if (-not (Get-KitchenJobPath $root $rb)) { Die "-ReplacedBy ${rb}: no such order" }; $j.replacedBy = $rb }
            $j.status = 'closed'; Save-Job $j
            $ev = @{ reason = $Why.Trim().Substring(0, [math]::Min(300, $Why.Trim().Length)); by = $(if ($env:KITCHEN_FROM_CHEF -eq '1') { 'Jordan' } else { 'cli' }) }
            if ($rb) { $ev.replacedBy = $rb }; if ($pf) { $ev.proof = $pf }; if ($dropped) { $ev.dropped = $true }
            Emit 'job.closed' $Id $ev
            Write-Output "closed $Id"
        } finally { Exit-State }
    }
    'requeue' {
        # Jordan puts a set-aside job back on the rail: it restarts at the step it stopped on, with fresh retries
        Enter-State
        try {
            $j = Load-Job $Id
            if ($j.status -notin 'quarantined', 'killed', 'failed') { Die "$Id is $($j.status); only set-aside jobs (quarantined, killed, failed) can go back on the rail" }
            $isOld = $false
            if ($j.created) { try { $isOld = ((Now) - (ToUtc $j.created)).TotalHours -ge 12 } catch { } }
            $isRecipe = $false
            $recipe = ''
            if ($j.recipe -and [string]$j.recipe -match '^[\w-]{1,40}$') {
                $isRecipe = $true
                $recipe = [string]$j.recipe
            } elseif ($j.name -match '^([\w-]+):') {
                $isRecipe = $true
                $recipe = $Matches[1]
            }
            # an order past its commit step keeps its work: re-cooking throws away a committed change (10-22: J207, tests green)
            # or opens a second PR for it (10-22: J210 -> J299)
            $prAt = -1; for ($i = 0; $i -lt @($j.steps).Count; $i++) { if ([IO.Path]::GetFileName([string]$j.steps[$i].script) -eq 'commit.ps1') { $prAt = $i } }
            $hasPr = $prAt -ge 0 -and [int]$j.cursor -gt $prAt
            if ($isOld -and $isRecipe -and -not $hasPr) {
                # claim the order before the lock is let go for cooking: a second tap (another phone) then finds it closed and is refused,
                # so one set-aside order is never re-cooked twice. Put back as it was if cooking fails.
                $prevStatus = $j.status
                # (recookFrom and recookAt let the doctor put back a requeue that died halfway: TD-EH-17)
                $j.status = 'closed'; $j.recooking = $true; $j.recookFrom = $prevStatus; $j.recookAt = Iso (Now); Save-Job $j
                Exit-State
                $vars = @{}
                if ($j.vars -is [hashtable]) {
                    foreach ($k in $j.vars.Keys) { $vars[$k] = [string]$j.vars[$k] }
                } elseif ($j.vars -is [PSCustomObject]) {
                    foreach ($p in $j.vars.PSObject.Properties) { $vars[$p.Name] = [string]$p.Value }
                }
                $cookScript = Join-Path $PSScriptRoot 'cook.ps1'
                $out = & $cookScript -Recipe $recipe -Vars $vars -Json | Out-String
                $c = $null
                try { $c = $out | ConvertFrom-Json } catch { }
                if ($LASTEXITCODE -ne 0 -or -not $c -or -not $c.ok) {
                    $errMsg = if ($c -and $c.error) { $c.error } else { $out.Trim() }
                    Enter-State; $j = Load-Job $Id; $j.status = $prevStatus; $j.recooking = $null; $j.recookFrom = $null; $j.recookAt = $null; Save-Job $j
                    Die "could not re-cook recipe '$recipe': $errMsg"
                }
                $newJobId = [string]$c.job
                Enter-State
                $j = Load-Job $Id
                # 'closed' (not 'killed'): it leaves the set-aside list, and requeue refuses it from now on
                $j.status = 'closed'; $j.recooking = $null; $j.recookFrom = $null; $j.recookAt = $null; $j.run = $null; $j.closed = $true; $j.replacedBy = $newJobId
                Save-Job $j
                Emit 'job.closed' $Id @{ replacedBy = $newJobId; reason = 're-cooked from current recipe' }
                Write-Output "re-cooked recipe $recipe as $newJobId (closed $Id)"
            } else {
                $j.status = 'pending'; $j.attempt = 0; $j.notBefore = $null; $j.run = $null; $j.waits = 0; $j.hiccups = 0
                $j.clashCheck = $true   # a requeued order passes the clash rule again before it goes on (kitchen/clash.ps1)
                Save-Job $j; Emit 'job.requeued' $j.id @{ step = $j.cursor }
                Write-Output "requeued $Id at step $($j.cursor + 1) of $($j.steps.Count)"
            }
        } finally { Exit-State }
    }
    'report' {
        if (-not $HtmlPath) { Die 'report needs -HtmlPath' }
        # The pass board: what a chef sees at a glance. Needs-you first, then the line (rail / cooking / plated / set aside), then the feed.
        # (every tick: the orders in play, and only the 12 newest finished files are opened for the Plated column)
        $jobs = @(All-Jobs -Live); $inPlay = @($jobs | ForEach-Object { [string]$_.id })
        $jobs += @(@($script:JobsIndexMem.jobs.GetEnumerator() | Where-Object { [string]$_.Value.s -eq 'done' -and $_.Key -notin $inPlay } | Sort-Object { [int]$_.Key.Substring(1) } |
                Select-Object -Last 12) | ForEach-Object { try { Load-Job $_.Key } catch { } })
        $b = Breaker-State; $meta = $b.meta
        $ev =if (Test-Path -LiteralPath $eventsPath) { try { @(Get-Content -LiteralPath $eventsPath -Tail 50 -ErrorAction Stop | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) } catch { @() } } else { @() }   # a busy log never breaks the board
        $enc = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
        $spent = Spend-Today; $pct = [math]::Min(100, [math]::Round(100 * $spent / [math]::Max($DailyBudgetUsd, 0.01)))
        $tickAge = if ($meta.lastTick) { [int]((Now) - (ToUtc $meta.lastTick)).TotalSeconds } else { -1 }
        $sup = if ($tickAge -lt 0) { 'never ticked' } elseif ($tickAge -le 150) { "alive, last tick ${tickAge}s ago" } else { "STALLED, last tick $([int]($tickAge/60)) min ago" }
        $supCls = if ($tickAge -ge 0 -and $tickAge -le 150) { 'ok' } else { 'bad' }
        $live = Test-Path -LiteralPath (Join-Path $root 'LIVE')
        $board = try { Get-Content -LiteralPath (Join-Path $root 'suppliers-board.json') -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
        function Card($j) {
            $s = $j.steps[[math]::Min($j.cursor, $j.steps.Count - 1)]
            $who = if ([IO.Path]::GetFileName($s.script) -eq 'agent-step.ps1') { $r = if ($s.args.Role) { $s.args.Role } else { 'do' }
                $pk = if ($j.status -eq 'running' -and $j.run -and (Test-Path -LiteralPath "$($j.run.base).sous.json")) { try { Get-Content -LiteralPath "$($j.run.base).sous.json" -Raw | ConvertFrom-Json } catch { $null } } else { $null }
                "$r &middot; $(if ($pk -and $pk.supplier) { & $enc ("$($pk.supplier) $($pk.model)".Trim()) } elseif ($s.args.Supplier -and $s.args.Supplier -ne 'auto') { & $enc $s.args.Supplier } else { 'sous chef picks' })" } else { & $enc ([IO.Path]::GetFileNameWithoutExtension($s.script)) }
            $last = if ($j.history.Count) { "$($j.history[-1].outcome) $($j.history[-1].detail)" } else { '' }
            $extra = ''
            if ($j.status -eq 'running' -and $j.run) {
                $secs = [int]((Now) - (ToUtc $j.run.startedAt)).TotalSeconds
                $tail = if (Test-Path -LiteralPath "$($j.run.base).log") { (@(Get-Content -LiteralPath "$($j.run.base).log" -Tail 3 -ErrorAction SilentlyContinue) | ForEach-Object { $_.Substring(0, [math]::Min(140, $_.Length)) }) -join "`n" } else { '' }
                $extra = "<div class='meta'>cooking ${secs}s of $($s.timeoutSec)s</div>" + $(if ($tail) { "<pre>$(& $enc $tail)</pre>" } else { '' })
            }
            if ($j.status -in 'waiting-approval', 'needs-human') { $extra += "<div class='cmd'>just approve $($j.id)</div>" }
            if ($j.status -in 'quarantined', 'killed') { $extra += "<div class='cmd'>just log $($j.id)</div>" }
            $cost = if ([double]$j.costUsd -gt 0) { " &middot; `$$('{0:N2}' -f [double]$j.costUsd)" } else { '' }
            "<article class='card s-$($j.status)'><header><b>$($j.id)</b> $(& $enc $j.name)</header><div class='meta'>$who &middot; step $([math]::Min($j.cursor + 1, $j.steps.Count))/$($j.steps.Count)$(if ($j.attempt) { " &middot; try $($j.attempt + 1)" })$cost</div>$(if ($last -and $j.status -ne 'running') { "<div class='last'>$(& $enc $last)</div>" })$extra</article>"
        }
        $cols = [ordered]@{
            'Needs you' = @($jobs | Where-Object { $_.status -in 'waiting-approval', 'needs-human' })
            'On the rail' = @($jobs | Where-Object { $_.status -eq 'pending' })
            'Cooking' = @($jobs | Where-Object { $_.status -eq 'running' })
            'Set aside' = @($jobs | Where-Object { $_.status -in 'quarantined', 'killed', 'failed' })
            'Plated' = @($jobs | Where-Object { $_.status -eq 'done' } | Select-Object -Last 12)
        }
        $colHtml = ($cols.Keys | ForEach-Object { $k = $_; $list = $cols[$k]
            "<section class='col'><h2>$k <span>$($list.Count)</span></h2>$(if ($list.Count) { ($list | ForEach-Object { Card $_ }) -join '' } else { "<p class='empty'>nothing here</p>" })</section>" }) -join "`n"
        $evRows = ($ev | Sort-Object ts -Descending | ForEach-Object {
            $t = [string]$_.type; $cls = if ($t -match 'done|granted|closed') { 'ok' } elseif ($t -match 'alert|quarantined|breaker.open|budget|refused|crash|timeout|memcap|logflood|hung|taster|fail') { 'bad' } elseif ($t -match 'approval|needs') { 'warn' } else { '' }
            $what = $_.detail ?? $_.text ?? $_.reason ?? $(if ($_.usd) { '$' + ('{0:N3}' -f [double]$_.usd) + " $($_.model)" } else { '' })
            "<li class='$cls'><code>$(([DateTime]$_.ts).ToLocalTime().ToString('HH:mm:ss'))</code> <b>$(& $enc $t)</b> $(& $enc $_.job) $(& $enc $what)</li>" }) -join "`n"
        $html = @"
<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="10"><title>Kitchen Status</title>
<style>:root{--bg:#f2f4f3;--card:#fff;--fg:#1b2422;--mut:#5a6966;--line:#d6dedb;--ok:#1f7a4d;--warn:#a46a00;--bad:#b3261e;--run:#1f5f8b;--acc:#1f6f62}
@media(prefers-color-scheme:dark){:root{--bg:#101614;--card:#18201e;--fg:#e4ebe9;--mut:#9aaba7;--line:#2c3835;--ok:#5cc28f;--warn:#e0a83a;--bad:#ef6b62;--run:#6aaee0;--acc:#6cc3b2}}
*{box-sizing:border-box}body{background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif;margin:0;padding:16px}
h1{font-size:1.4rem;margin:0 0 8px}.strip{display:flex;flex-wrap:wrap;gap:8px 18px;margin-bottom:14px;color:var(--mut)}
.strip b{color:var(--fg)}.ok{color:var(--ok)}.bad{color:var(--bad)}.warn{color:var(--warn)}
.meter{display:inline-block;width:110px;height:8px;background:var(--line);border-radius:4px;vertical-align:middle;overflow:hidden}
.meter i{display:block;height:100%;background:var(--acc)}
.line{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px;align-items:start}
.col{background:transparent;min-width:0}.col h2{font-size:.8rem;text-transform:uppercase;letter-spacing:.08em;color:var(--mut);margin:0 0 6px}
.col h2 span{color:var(--fg)}.empty{color:var(--mut);font-size:.85rem;margin:0}
.card{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--line);border-radius:8px;padding:8px 10px;margin-bottom:8px}
.card header{font-size:.95rem}.meta,.last{color:var(--mut);font-size:.8rem}.last{margin-top:2px}
.s-running{border-left-color:var(--run)}.s-done{border-left-color:var(--ok)}.s-quarantined,.s-killed,.s-failed{border-left-color:var(--bad)}
.s-waiting-approval,.s-needs-human{border-left-color:var(--warn)}
pre{margin:6px 0 0;padding:6px;background:var(--bg);border-radius:6px;font-size:.75rem;white-space:pre-wrap;overflow-wrap:anywhere;max-height:6.5em;overflow:hidden}
.cmd{margin-top:6px;font:600 .8rem ui-monospace,monospace;color:var(--warn)}
h3{font-size:.8rem;text-transform:uppercase;letter-spacing:.08em;color:var(--mut);margin:18px 0 6px}
ul{list-style:none;padding:0;margin:0;font-size:.82rem}li{padding:3px 0;border-bottom:1px solid var(--line)}li code{color:var(--mut)}</style>
<h1>Kitchen Status</h1>
<div class="strip"><span>Supervisor <b class="$supCls">$sup</b></span><span>Usage today (API-equivalent) <b>`$$('{0:N2}' -f $spent)</b> of `$$('{0:N2}' -f $DailyBudgetUsd) <span class="meter"><i style="width:$pct%"></i></span></span>
<span>Fail rate <b>$([math]::Round($b.rate*100))%</b></span><span>Breaker <b class="$(if ($meta.breakerTripped) { 'bad' } else { 'ok' })">$(if ($meta.breakerTripped) { 'OPEN' } else { 'closed' })</b></span>
<span>AI cooks <b>$(if ($live) { 'live' } else { 'off (demo only)' })</b></span>$(if ($board -and $board.suppliers) { ($board.suppliers.Keys | ForEach-Object { $x = $board.suppliers[$_]; "<span>$(& $enc $_) <b class='$(if ($x.status -eq 'ready') { 'ok' } elseif ($x.status -in 'off', 'signed-out') { 'bad' } else { 'warn' })'>$(& $enc $x.status)</b> $($x.runs)/$($x.maxRuns)</span>" }) -join '' })<span>Updated $(Get-Date -Format 'HH:mm:ss')</span></div>
<div class="line">
$colHtml
</div>
<h3>What just happened</h3><ul>
$evRows
</ul>
"@
        Set-Content -LiteralPath $HtmlPath -Value $html -Encoding utf8
        Write-Output "wrote $HtmlPath"
    }
}
