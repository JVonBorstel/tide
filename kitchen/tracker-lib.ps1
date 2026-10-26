# Shared tracker.json helpers for the hunt stations (hunt-night, pack-render); dot-source it. tracker.json is Jordan's whole
# application history, so: a file that exists but can't be read or parsed is never treated as empty (fail closed: refuse to write),
# every replace keeps the previous file as tracker.json.bak and goes temp + rename, and every writer holds tracker.json.lock (the same
# lock pass-app/server.mjs takes) around re-read, change and write, so two writers never lose each other's edits.

# The items list (hashtables), or an empty list when the file is missing. Throws when the file exists but can't be read or parsed.
function Read-Tracker([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , @() }
    $raw = [IO.File]::ReadAllText($Path)   # a locked or half-synced file throws here; that is a refusal, never "empty"
    if (-not $raw.Trim()) { throw 'tracker.json is empty (a cut-off write?); restore it from tracker.json.bak' }
    $d = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable -Depth 30
    if ($d -isnot [Collections.IDictionary] -or ($d.Contains('items') -and $null -ne $d.items -and $d.items -isnot [Collections.IList])) { throw 'tracker.json does not hold an items list' }
    return , @($d.items | Where-Object { $null -ne $_ })
}

# Takes tracker.json.lock (exclusive create). Waits up to $WaitSec; a lock older than 60 s is a crashed writer's and is cleared.
function Lock-Tracker([string]$Path, [int]$WaitSec = 15) {
    $lock = "$Path.lock"; $until = (Get-Date).AddSeconds($WaitSec)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    while ($true) {
        try {
            $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $b = [Text.Encoding]::UTF8.GetBytes("$PID $((Get-Date).ToUniversalTime().ToString('o'))"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
            return $lock
        } catch {
            try { if (((Get-Date) - (Get-Item -LiteralPath $lock -ErrorAction Stop).LastWriteTime).TotalSeconds -gt 60) { Remove-Item -LiteralPath $lock -Force -ErrorAction Stop; continue } } catch { }
            if ((Get-Date) -gt $until) { throw "tracker.json is locked by another writer ($lock)" }
            Start-Sleep -Milliseconds 100
        }
    }
}
function Unlock-Tracker([string]$Path) { Remove-Item -LiteralPath "$Path.lock" -Force -ErrorAction SilentlyContinue }

# Replaces tracker.json: keeps the current file as tracker.json.bak, then writes a temp file and renames it over (never half a file).
function Save-Tracker([string]$Path, $Items) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
    $tmp = "$Path.tmp-$PID"
    [ordered]@{ updated = (Get-Date).ToUniversalTime().ToString('o'); items = @($Items) } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Re-read, change and write under the lock. $Change gets the fresh items list (a List[object]) and returns $true to save.
function Update-Tracker([string]$Path, [scriptblock]$Change) {
    Lock-Tracker $Path | Out-Null
    try {
        $items = [Collections.Generic.List[object]]::new(); foreach ($it in (Read-Tracker $Path)) { $items.Add($it) }
        $r = & $Change $items
        if (@($r)[-1] -eq $true) { Save-Tracker $Path $items }   # only the last value decides, so a stray output line can't force a write
    } finally { Unlock-Tracker $Path }
}

# ---- Jordan's career files: the folder (env PASS_CAREER_DIR, tests) and the one resume + claims file every resume step reads.
# kitchen.json "career": {"resume": "MASTER_RESUME.md", "claims": "..."} (relative to the career folder; the state-folder copy wins).
# A value that is rooted, climbs out with .., or is not a .md file is ignored (the default stays): the resume never comes from elsewhere.
function Get-CareerFiles {
    $dir = if ($env:PASS_CAREER_DIR) { [IO.Path]::GetFullPath($env:PASS_CAREER_DIR) } else { (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain\projects\career') }
    $c = @{ resume = 'MASTER_RESUME.md'; claims = 'demo\03_resume\claims_to_defend.md' }
    $kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
    foreach ($kp in (Join-Path $PSScriptRoot 'kitchen.json'), (Join-Path $kroot 'kitchen.json')) {
        try { $kc = [IO.File]::ReadAllText($kp) | ConvertFrom-Json -AsHashtable } catch { continue }
        if ($kc.career -isnot [Collections.IDictionary]) { continue }
        foreach ($k in 'resume', 'claims') {
            $v = [string]$kc.career[$k]
            if ($v -and $v -match '\.md$' -and -not [IO.Path]::IsPathRooted($v) -and $v -notmatch '(^|[\\/])\.\.([\\/]|$)' -and $v -notmatch '[:*?"<>|{}]') { $c[$k] = $v }
        }
    }
    @{ dir = $dir; resume = (Join-Path $dir $c.resume); claims = (Join-Path $dir $c.claims) }
}
# profile.json's fingerprint (sha256 of its bytes, '' when missing): packet.json records it, so Chef knows a packet predates a profile edit
function Get-ProfileHash([string]$Path) { if (Test-Path -LiteralPath $Path -PathType Leaf) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' } }
