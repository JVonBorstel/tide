# Backup of the kitchen state that is hard to rebuild, OFF the C: drive (the doctor's own backups\ sit on the same NVMe as everything else).
# Cheap and AI-free: plain file copies into <Dest>\<yyyy-MM-dd> (one folder a day, a rerun the same day refreshes it), 14 days kept.
# The destination is Jordan's own disk (D: by default), so the data stays local. Run once a night by the supervisor (kitchen.ps1 tick).
#   backup-state.ps1 [-KitchenRoot <dir>] [-CareerDir <dir>] [-Dest D:\backups\kitchen] [-KeepDays 14] [-Json]
# Exit: 0 copied, 1 the destination drive is missing or a copy failed (nothing is deleted then).
param(
    [string]$KitchenRoot = $(if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }),
    [string]$CareerDir = (Join-Path $env:USERPROFILE 'gemini-brain\projects\career'),
    [string]$Dest = 'D:\backups\kitchen', [int]$KeepDays = 14, [switch]$Json
)
$ErrorActionPreference = 'Stop'
$res = [ordered]@{ ok = $false; dest = ''; copied = 0; pruned = 0; error = '' }
function Done { if ($Json) { $res | ConvertTo-Json -Compress } else { if ($res.ok) { "backup: $($res.copied) file(s) to $($res.dest); $($res.pruned) old day(s) removed" } else { "backup FAILED: $($res.error)" } }; exit ([int](-not $res.ok)) }
# fail closed on a missing drive: never create D:\ paths on some other disk, never prune when today's copy did not land
$qual = Split-Path -Qualifier $Dest -ErrorAction SilentlyContinue
if ($qual -and -not (Test-Path -LiteralPath "$qual\")) { $res.error = "drive $qual is not there"; Done }
$day = Join-Path $Dest (Get-Date -Format 'yyyy-MM-dd'); $res.dest = $day
try {
    New-Item -ItemType Directory -Force -Path $day, (Join-Path $day 'jobs') | Out-Null
    foreach ($f in 'ideas.json', 'kitchen.json', 'lessons.jsonl', 'exemplars.jsonl', 'lead.json', 'autopilot.json') {
        $src = Join-Path $KitchenRoot $f
        if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -LiteralPath $src -Destination (Join-Path $day $f) -Force; $res.copied++ }
    }
    foreach ($j in Get-ChildItem -LiteralPath (Join-Path $KitchenRoot 'jobs') -Filter '*.json' -File -ErrorAction SilentlyContinue) { Copy-Item -LiteralPath $j.FullName -Destination (Join-Path $day 'jobs') -Force; $res.copied++ }
    # the archive (finished orders the doctor moved to jobs\archive\yyyy-MM\, and index.jsonl): this is their only copy off the C: drive
    $arc = Join-Path $KitchenRoot 'jobs\archive'
    if (Test-Path -LiteralPath $arc) { foreach ($f in Get-ChildItem -LiteralPath $arc -File -Recurse -ErrorAction SilentlyContinue) { $to = Join-Path $day ('jobs\archive\' + $f.FullName.Substring($arc.Length + 1)); New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null; Copy-Item -LiteralPath $f.FullName -Destination $to -Force; $res.copied++ } }
    foreach ($f in 'next-id.txt') { $src = Join-Path $KitchenRoot "jobs\$f"; if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $day "jobs\$f") -Force; $res.copied++ } }
    # the job-hunt tracker Chef writes on every job-hunt tap (it lives in gemini-brain, which has uncommitted work and no remote)
    $tr = Join-Path $CareerDir 'tracker.json'
    if (Test-Path -LiteralPath $tr -PathType Leaf) { New-Item -ItemType Directory -Force -Path (Join-Path $day 'career') | Out-Null; Copy-Item -LiteralPath $tr -Destination (Join-Path $day 'career\tracker.json') -Force; $res.copied++ }
} catch { $res.error = "copy failed: $($_.Exception.Message)"; Done }
# keep the newest KeepDays days: only our own yyyy-MM-dd folders, judged by the date in the name (a touched folder never lives longer)
$cut = (Get-Date).Date.AddDays(-($KeepDays - 1))
foreach ($d in Get-ChildItem -LiteralPath $Dest -Directory -ErrorAction SilentlyContinue) {
    $dt = [datetime]::MinValue
    if ($d.Name -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [datetime]::TryParseExact($d.Name, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)) { continue }
    if ($dt -lt $cut) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $res.pruned++ } catch { } }
}
$res.ok = $true; Done
