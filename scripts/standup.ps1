# Supervised launcher for the pinned agent-standup clone (a fork of Atoll92/agent-standup; unofficial).
# Actions: start | stop | status   (serve is internal: the hidden supervisor that owns the node process)
# Safety: refuses unless the clone is at the pinned commit and clean; refuses a busy port; strips API keys from the
# server's environment; demo mode points the server at an EMPTY projects folder (no real transcripts);
# auto-expires after -MaxMinutes; stop/status only ever touch the pids recorded in the state file (start time must match).
# Exit: 0 ok / running, 1 not running, 3 already running, 4 port busy, 5 pin or clone check failed, 6 failed to start, 7 node missing.
param(
    [ValidateSet('start', 'stop', 'status', 'serve')][string]$Action = 'status',
    [ValidateSet('demo', 'live')][string]$Mode = 'demo',
    [int]$Port = 4747,
    [double]$MaxMinutes = 120,
    [string]$StandupDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'source\repos\agent-standup'),
    [string]$PinnedSha = '2dc346ca4e5b36a52b504a2574627d57c970cc38'
)
$ErrorActionPreference = 'Stop'
$stateDir = if ($env:BRAIN_STANDUP_STATE) { $env:BRAIN_STANDUP_STATE } else { Join-Path $env:LOCALAPPDATA 'brain-standup' }
$stateFile = Join-Path $stateDir 'run.json'

function Get-State { if (Test-Path -LiteralPath $stateFile) { try { Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { $null } } }
function Test-Port($p) { try { $c = [Net.Sockets.TcpClient]::new(); $a = $c.BeginConnect('127.0.0.1', $p, $null, $null); $ok = $a.AsyncWaitHandle.WaitOne(800) -and $c.Connected; $c.Close(); $ok } catch { $false } }
function Get-Same($procId, $iso) {   # live process whose start time matches the recorded one (guards against pid reuse)
    if (-not $procId -or -not $iso) { return $null }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p -and [math]::Abs(($p.StartTime - [datetime]$iso).TotalSeconds) -lt 2) { $p } else { $null }
}
function Stop-Tree($p) { if ($p) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } }
function Clear-State { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath (Join-Path $stateDir 'emptyroot') -Recurse -Force -ErrorAction SilentlyContinue }
function Stop-Recorded($st) { Stop-Tree (Get-Same $st.supervisor $st.supervisorStart); Stop-Tree (Get-Same $st.node $st.nodeStart); Clear-State }

switch ($Action) {
    'status' {
        $st = Get-State
        if (-not $st) { Write-Output 'standup: not running'; exit 1 }
        $sup = Get-Same $st.supervisor $st.supervisorStart
        if ($sup -and (Test-Port $st.port)) {
            $left = [math]::Max(0, [math]::Round(([datetime]$st.deadline - (Get-Date)).TotalMinutes, 1))
            Write-Output ("standup: RUNNING mode={0} http://127.0.0.1:{1} (auto-stops in {2} min)" -f $st.mode, $st.port, $left); exit 0
        }
        Stop-Recorded $st
        Write-Output 'standup: stale instance reaped (not running)'; exit 1
    }
    'stop' {
        $st = Get-State
        if (-not $st) { Write-Output 'standup: not running'; exit 0 }
        Stop-Recorded $st
        Write-Output 'standup: stopped'; exit 0
    }
    'start' {
        $st = Get-State
        if ($st -and (Get-Same $st.supervisor $st.supervisorStart)) { Write-Output ("standup: already running on port {0}" -f $st.port); exit 3 }
        if ($st) { Stop-Recorded $st }
        if (-not (Test-Path -LiteralPath (Join-Path $StandupDir 'server.js'))) { Write-Output "standup: clone not found at $StandupDir"; exit 5 }
        $head = (git -C $StandupDir rev-parse HEAD 2>$null)
        $dirty = (git -C $StandupDir status --porcelain 2>$null)
        if ($head -ne $PinnedSha) { Write-Output "standup: clone is at '$head', not the pinned commit; refusing"; exit 5 }
        if ($dirty) { Write-Output 'standup: clone has local changes; refusing'; exit 5 }
        if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Output 'standup: node is not installed'; exit 7 }
        if (Test-Port $Port) { Write-Output "standup: port $Port is already in use"; exit 4 }
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        $pwsh = (Get-Process -Id $PID).Path
        $sup = Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-File', $PSCommandPath, '-Action', 'serve', '-Mode', $Mode, '-Port', $Port,
            '-MaxMinutes', ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $MaxMinutes)), '-StandupDir', $StandupDir, '-PinnedSha', $PinnedSha)
        $ok = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            $s2 = Get-State
            if ($s2 -and $s2.node -and (Test-Port $Port)) { $ok = $true; break }
            if ($sup.HasExited) { break }
        }
        if (-not $ok) {
            Stop-Tree (Get-Process -Id $sup.Id -ErrorAction SilentlyContinue); $s3 = Get-State; if ($s3) { Stop-Recorded $s3 }
            $err = Join-Path $stateDir 'server.err'; if (Test-Path $err) { Get-Content $err -Tail 3 }
            Write-Output 'standup: failed to start'; exit 6
        }
        Write-Output ("standup: started mode={0} http://127.0.0.1:{1} (auto-stops in {2} min; stop with -Action stop)" -f $Mode, $Port, $MaxMinutes)
        if ($Mode -eq 'live') { Write-Output 'LIVE mode: every session transcript on this machine is readable at this address by any local process while it runs. Stop it when done.' }
        else { Write-Output 'demo mode: built-in fictional session only; no real transcripts are served.' }
        exit 0
    }
    'serve' {
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        $node = (Get-Command node).Source
        foreach ($v in 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
        $env:PORT = [string]$Port
        if ($Mode -eq 'demo') {
            $empty = Join-Path $stateDir 'emptyroot'; New-Item -ItemType Directory -Force -Path $empty | Out-Null
            $env:AGENT_STANDUP_PROJECTS = $empty
        } else { Remove-Item Env:AGENT_STANDUP_PROJECTS -ErrorAction SilentlyContinue }
        $np = $null
        try {
            $np = Start-Process -FilePath $node -ArgumentList 'server.js' -WorkingDirectory $StandupDir -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput (Join-Path $stateDir 'server.log') -RedirectStandardError (Join-Path $stateDir 'server.err')
            $me = Get-Process -Id $PID
            $deadline = (Get-Date).AddMinutes($MaxMinutes)
            @{ supervisor = $PID; supervisorStart = $me.StartTime.ToString('o'); node = $np.Id; nodeStart = $np.StartTime.ToString('o'); port = $Port; mode = $Mode; deadline = $deadline.ToString('o'); started = (Get-Date).ToString('o') } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $stateFile -Encoding utf8
            while (-not $np.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        } finally {
            if ($np -and -not $np.HasExited) { & taskkill.exe /T /F /PID $np.Id 2>&1 | Out-Null }
            $cur = Get-State; if ($cur -and $cur.supervisor -eq $PID) { Clear-State }
        }
        exit 0
    }
}
