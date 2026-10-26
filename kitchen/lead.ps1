# The lead's desk (Claude in the desktop app). When Claude's weekly plan runs out, Jordan can't talk to Claude for a while; Chef shows
# when Claude is back, Claude's last note, and keeps Jordan's notes for Claude's return (lead.json in the kitchen folder).
#   lead.ps1 status                    mode (here / low / away), weekly use, reset time, open notes
#   lead.ps1 notes                     Jordan's open notes, oldest first
#   lead.ps1 done -Id N3               mark a note handled (it leaves Chef and the boot pack)
#   lead.ps1 handoff -Text "..."       Claude's last note, shown in Chef while Claude is away (what was going on, what to expect)
#   lead.ps1 away [-Off]               mark Claude out until the weekly reset (or back)
param(
    [Parameter(Position = 0)][ValidateSet('status', 'notes', 'done', 'handoff', 'away')][string]$Op = 'status',
    [string]$Id = '', [string]$Text = '', [switch]$Off, [switch]$Json
)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$path = Join-Path $root 'lead.json'
function Load { if (Test-Path -LiteralPath $path) { $o = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable; if ($o) { return $o } }; @{} }
function Save($o) { $tmp = "$path.tmp-$PID"; $o | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding utf8; Move-Item -LiteralPath $tmp -Destination $path -Force }
# lead.json has two writers: this script and Chef (pass-app/server.mjs, notes from the phone). Every change holds lead.json.lock (an
# exclusive-create file, the same one Chef takes; one older than 60 s is a crashed writer's) and re-reads under it, so a note added
# from the phone while Claude marks another done is never lost.
$lockPath = "$path.lock"; $locked = $false
if ($Op -in 'done', 'handoff', 'away') {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $lockUntil = (Get-Date).AddSeconds(15)
    while (-not $locked) {
        try { [IO.File]::Open($lockPath, 'CreateNew', 'Write', 'None').Dispose(); $locked = $true } catch {
            try { if (((Get-Date) - (Get-Item -LiteralPath $lockPath -ErrorAction Stop).LastWriteTime).TotalSeconds -gt 60) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop; continue } } catch { }
            if ((Get-Date) -gt $lockUntil) { Write-Output 'lead.json is busy (another writer holds the lock); nothing was saved'; exit 1 }
            Start-Sleep -Milliseconds 100
        }
    }
}
try {
$L = Load; if (-not $L.notes) { $L.notes = @() }
switch ($Op) {
    'status' {
        $pu = $null; try { $pu = (Get-Content (Join-Path $root 'plan-usage.json') -Raw | ConvertFrom-Json).claude } catch {}
        $resets = if ($pu.sevenDay.resetsAt) { [DateTime]$pu.sevenDay.resetsAt } else { $null }
        $fresh = $resets -and $resets.ToUniversalTime() -gt (Get-Date).ToUniversalTime()
        $week = if ($fresh) { [double]$pu.sevenDay.used } else { 0 }
        $manual = $L.away -and $L.away.on -and (-not $L.away.until -or ([DateTime]$L.away.until).ToUniversalTime() -gt (Get-Date).ToUniversalTime())
        $mode = if ($manual -or $week -ge 0.98) { 'away' } elseif ($week -ge 0.75) { 'low' } else { 'here' }
        $open = @($L.notes | Where-Object { $_.status -in 'open', 'kitchen' })
        $r = [ordered]@{ mode = $mode; week = $week; resetsAt = $(if ($fresh) { $resets.ToLocalTime().ToString('ddd HH:mm') } else { $null }); openNotes = $open.Count }
        if ($Json) { $r | ConvertTo-Json -Compress } else { "lead: $mode, week $([math]::Round($week * 100))%$(if ($r.resetsAt) { ", resets $($r.resetsAt)" }), $($open.Count) open note(s)" }
    }
    'notes' { foreach ($n in @($L.notes | Where-Object { $_.status -in 'open', 'kitchen' })) { "$($n.id) $($n.at) [$($n.status)$(if ($n.idea) { ' ' + $n.idea })] $($n.text)" } }
    'done' {
        $n = $L.notes | Where-Object { $_.id -eq $Id } | Select-Object -First 1
        if (-not $n) { Write-Output "no note $Id"; exit 1 }
        $n.status = 'done'; $n.doneAt = (Get-Date).ToUniversalTime().ToString('o'); Save $L; "note $Id done"
    }
    'handoff' {
        if ($Text.Trim().Length -lt 4) { Write-Output 'give the note some words (-Text)'; exit 1 }
        $L.handoff = @{ at = (Get-Date).ToUniversalTime().ToString('o'); text = $Text.Trim().Substring(0, [math]::Min(1500, $Text.Trim().Length)) }; Save $L; 'handoff note saved'
    }
    'away' {
        if ($Off) { $L.away = @{ on = $false } } else {
            $until = $null; try { $until = (Get-Content (Join-Path $root 'plan-usage.json') -Raw | ConvertFrom-Json).claude.sevenDay.resetsAt } catch {}
            if (-not $until -or ([DateTime]$until).ToUniversalTime() -le (Get-Date).ToUniversalTime()) { $until = (Get-Date).ToUniversalTime().AddDays(1).ToString('o') }
            $L.away = @{ on = $true; at = (Get-Date).ToUniversalTime().ToString('o'); until = ([DateTime]$until).ToUniversalTime().ToString('o') }
        }
        Save $L; "away: $(-not $Off)"
    }
}
} finally { if ($locked) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } }
