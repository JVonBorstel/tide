# Run registry: every background process an agent starts is registered with an end condition, so nothing is left unaccounted for.
#   run-registry.ps1 register -Name <n> -ProcessId <pid> -EndCondition <text> [-MaxMinutes 60]
#   run-registry.ps1 list                    alive | dead | overdue (dead includes a reused pid: start time must match)
#   run-registry.ps1 reap [-Kill]            REPORT ONLY by default; -Kill stops only registered, overdue, start-time-verified processes
#   run-registry.ps1 depth [-Check]          BRAIN_AGENT_DEPTH; -Check exits 3 when depth >= 2 (subagents must not spawn subagents)
# Registry: %LOCALAPPDATA%\brain-runs\runs.jsonl (override: env BRAIN_RUNS). Exit: 0 ok, 2 refused/error, 3 depth cap.
# FROZEN per ORG.md: no new features.
# The depth cap only works if the launching agent sets BRAIN_AGENT_DEPTH. Nothing sets it today, so depth reads 0 and the cap never blocks.
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('register', 'list', 'reap', 'depth')][string]$Action,
    [string]$Name = '', [int]$ProcessId = 0, [string]$EndCondition = '', [int]$MaxMinutes = 60,
    [switch]$Kill, [switch]$Check
)
$ErrorActionPreference = 'Stop'
$reg = if ($env:BRAIN_RUNS) { $env:BRAIN_RUNS } else { Join-Path $env:LOCALAPPDATA 'brain-runs\runs.jsonl' }
$reg = [IO.Path]::GetFullPath($reg)
function Die([string]$m, [int]$code = 2) { Write-Output "ERROR: $m"; exit $code }
function Get-Depth {
    $d = $env:BRAIN_AGENT_DEPTH
    if ([string]::IsNullOrEmpty($d)) { return 0 }
    $n = 0; if ([int]::TryParse($d, [ref]$n) -and $n -ge 0) { return $n }
    return -1   # garbage: callers fail closed
}
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Start-Ms($p) { [DateTimeOffset]::new($p.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() }

# ---- depth ----
$depth = Get-Depth
if ($Action -eq 'depth') {
    Write-Output "BRAIN_AGENT_DEPTH=$(if ($depth -lt 0) { "invalid ($env:BRAIN_AGENT_DEPTH)" } else { $depth })$(if ([string]::IsNullOrEmpty($env:BRAIN_AGENT_DEPTH)) { ' (not set: the cap is inert unless the launching agent sets it)' })"
    if ($Check -and ($depth -lt 0 -or $depth -ge 2)) { Write-Output 'DEPTH CAP: subagents must not spawn subagents'; exit 3 }
    exit 0
}

function Read-Records {
    $recs = [Collections.Generic.List[object]]::new(); $bad = 0
    if (Test-Path -LiteralPath $reg) {
        foreach ($l in [IO.File]::ReadAllLines($reg)) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            try {
                $o = $l | ConvertFrom-Json
                if ($null -eq $o.pid -or $null -eq $o.start_ms -or $null -eq $o.registered_ms) { throw 'fields' }
                $recs.Add($o)
            } catch { $bad++ }
        }
    }
    [pscustomobject]@{ Recs = $recs; Bad = $bad }
}
function Get-State($r) {
    $p = Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue
    if (-not $p) { return 'dead' }
    try { $diff = [math]::Abs((Start-Ms $p) - [int64]$r.start_ms) } catch { return 'dead' }
    if ($diff -gt 2000) { return 'dead' }   # pid reused by a different process
    $ageMin = ((Now-Ms) - [int64]$r.registered_ms) / 60000.0
    if ($ageMin -gt [double]$r.maxMinutes) { return 'overdue' }
    return 'alive'
}
function Clean([string]$s, [int]$max) { $t = ($s -replace '[\x00-\x1f\x7f]', ' ').Trim(); if ($t.Length -gt $max) { $t.Substring(0, $max) } else { $t } }

switch ($Action) {
    'register' {
        if ($depth -lt 0 -or $depth -ge 2) { Die 'refused: agent depth cap reached (BRAIN_AGENT_DEPTH >= 2 or invalid); subagents must not spawn subagents' 3 }
        $Name = Clean $Name 80; $EndCondition = Clean $EndCondition 200
        if (-not $Name) { Die 'refused: -Name is required' }
        if (-not $EndCondition) { Die 'refused: -EndCondition is required (how will we know this run is finished?)' }
        if ($MaxMinutes -lt 1 -or $MaxMinutes -gt 1440) { Die 'refused: -MaxMinutes must be 1..1440' }
        $p = if ($ProcessId -gt 0) { Get-Process -Id $ProcessId -ErrorAction SilentlyContinue } else { $null }
        if (-not $p) { Die "refused: process $ProcessId does not exist" }
        $rec = [ordered]@{ name = $Name; pid = $ProcessId; start_ms = (Start-Ms $p); registered_ms = (Now-Ms); endCondition = $EndCondition; maxMinutes = $MaxMinutes; depth = $depth }
        $dir = Split-Path -Parent $reg; New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($reg.ToLowerInvariant()))
        $mxName = 'Global\brain-runs-' + (([BitConverter]::ToString($hash, 0, 6)) -replace '-')
        $mx = New-Object Threading.Mutex($false, $mxName)
        $got = $false
        try {
            try { $got = $mx.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $got = $true }
            if (-not $got) { Die 'could not get the registry lock within 15s' }
            [IO.File]::AppendAllText($reg, (($rec | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        } finally { if ($got) { $mx.ReleaseMutex() }; $mx.Dispose() }
        Write-Output "registered '$Name' pid $ProcessId, ends when: $EndCondition (max $MaxMinutes min)"
    }
    'list' {
        $x = Read-Records
        if (-not $x.Recs.Count) { Write-Output "no registered runs ($reg)" }
        foreach ($r in $x.Recs) {
            $age = [int](((Now-Ms) - [int64]$r.registered_ms) / 60000)
            Write-Output ("{0} (pid {1}) {2}, age {3}/{4} min, ends when: {5}" -f (Clean ([string]$r.name) 80), $r.pid, (Get-State $r), $age, $r.maxMinutes, (Clean ([string]$r.endCondition) 200))
        }
        if ($x.Bad) { Write-Output "WARN $($x.Bad) malformed registry line(s) ignored" }
    }
    'reap' {
        $x = Read-Records; $stale = 0
        foreach ($r in $x.Recs) {
            $st = Get-State $r
            if ($st -eq 'alive') { continue }
            $stale++
            $act = ''
            if ($Kill -and $st -eq 'overdue') {
                # re-verify immediately before acting: same pid AND same start time as recorded
                $p = Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue
                if ($p -and [math]::Abs((Start-Ms $p) - [int64]$r.start_ms) -le 2000) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null; $act = ' -> KILLED (registered, overdue, start time verified)' }
            }
            Write-Output ("STALE {0} (pid {1}) {2}{3}" -f (Clean ([string]$r.name) 80), $r.pid, $st, $act)
        }
        if ($x.Bad) { Write-Output "WARN $($x.Bad) malformed registry line(s) ignored" }
        Write-Output $(if ($stale) { "$stale stale entr$(if ($stale -eq 1) {'y'} else {'ies'}). $(if ($Kill) { 'Only registered overdue processes were stopped; dead entries need no action.' } else { 'Report only; nothing was killed. Use -Kill to stop overdue registered runs.' })" } else { 'no stale runs' })
    }
}
exit 0
