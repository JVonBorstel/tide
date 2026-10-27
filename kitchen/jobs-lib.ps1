# The job store, read by its live set (TARGET W3, gemini-brain projects/tide/arch-10-22). jobs\J*.json holds the orders still in play
# plus finished ones from the last few days; the doctor moves finished orders (done, closed) older than that to jobs\archive\yyyy-MM\,
# after one summary line each in jobs\archive\index.jsonl. <kitchen>\jobs-index.json remembers each jobs\ file's status, parent and
# chefUpdate flag by the file's size and write time, so a scan parses only files that changed plus the orders still in play.
# The index is a cache, never the truth: an entry whose size or time no longer matches the file is read again, a file it does not
# know is read, an entry without a file is dropped, and a missing or damaged index is rebuilt from the files (the caller logs that).
# Dot-sourced by kitchen.ps1 (its All-Jobs, add and doctor) and by every script that reads many jobs (ledger, scoreboard, ideas,
# diagnose, freeze-lib, roadmap-lib, scripts/handoff.ps1). Only this file lists the jobs folder (tests/Test-JobsIndex.ps1 lints it).
# To bring an archived order back, move its file from jobs\archive\yyyy-MM\ to jobs\: a jobs\ file always wins over its archive line.
$script:JobsFinished = @('done', 'closed')   # statuses that leave the live set (set-aside orders stay: Jordan can requeue or close them)

function Test-JobLive($e) { ([string]$e.s -notin $script:JobsFinished) -or [int]$e.c -eq 1 }
function Get-JobsIndexPath([string]$Root) { Join-Path $Root 'jobs-index.json' }

# @{ ok; reason; jobs = id -> @{ s = status; t = write time ticks (UTC); n = bytes; p = parent; c = 1 when a Chef update waits;
#    si = the order's stored Site code, only when it has one (vars.site, set at add: TD-3; an order without one has no si key) } }
function Read-JobsIndexFile([string]$Root) {
    $p = Get-JobsIndexPath $Root
    if (-not (Test-Path -LiteralPath $p)) { return @{ ok = $false; reason = 'missing' } }
    $raw = $null
    for ($i = 0; $i -lt 5 -and $null -eq $raw; $i++) { try { $raw = [IO.File]::ReadAllText($p) } catch { Start-Sleep -Milliseconds 40 } }
    if ($null -eq $raw) { return @{ ok = $false; reason = 'unreadable' } }
    $d = try { $raw | ConvertFrom-Json -AsHashtable } catch { $null }
    if ($d -isnot [hashtable] -or $d.v -ne 1 -or $d.jobs -isnot [hashtable]) { return @{ ok = $false; reason = 'damaged' } }
    foreach ($k in $d.jobs.Keys) {
        $e = $d.jobs[$k]
        if ($k -notmatch '^J\d+$' -or $e -isnot [hashtable] -or $null -eq $e.s -or -not (Test-JobsNum $e.t) -or -not (Test-JobsNum $e.n)) { return @{ ok = $false; reason = 'damaged' } }
        if ($e.ContainsKey('si') -and [string]$e.si -cnotin $script:RepoSiteCodes) { return @{ ok = $false; reason = 'damaged' } }
    }
    @{ ok = $true; reason = ''; jobs = $d.jobs }
}
function Test-JobsNum($v) { $v -is [long] -or $v -is [int] }
function ConvertTo-JsonText([string]$s) { '"' + ($s -replace '[\x00-\x1f]', ' ' -replace '\\', '\\' -replace '"', '\"') + '"' }
# written whole (temp then rename); a writer that loses a race only costs the next reader a re-read of the files it changed
function Write-JobsIndexFile([string]$Root, [hashtable]$Jobs) {
    $sb = [Text.StringBuilder]::new('{"v":1,"jobs":{'); $first = $true
    foreach ($k in $Jobs.Keys) {
        $e = $Jobs[$k]; if (-not $first) { [void]$sb.Append(',') }; $first = $false
        [void]$sb.Append('"').Append($k).Append('":{"s":').Append((ConvertTo-JsonText ([string]$e.s))).Append(',"t":').Append([long]$e.t).Append(',"n":').Append([long]$e.n)
        [void]$sb.Append(',"p":').Append((ConvertTo-JsonText ([string]$e.p))).Append(',"c":').Append([int]$e.c)
        if ($e.si) { [void]$sb.Append(',"si":').Append((ConvertTo-JsonText ([string]$e.si))) }   # no Site, no key: the index reads as before TD-3
        [void]$sb.Append('}')
    }
    [void]$sb.Append('}}')
    $p = Get-JobsIndexPath $Root; $t = "$p.tmp-$PID"
    try {
        [IO.File]::WriteAllText($t, $sb.ToString())
        for ($i = 0; ; $i++) { try { [IO.File]::Move($t, $p, $true); break } catch { if ($i -ge 10) { throw }; Start-Sleep -Milliseconds (30 + (Get-Random -Maximum 60)) } }
    } catch { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
}
function New-JobsIndexEntry($j, [IO.FileInfo]$f) {
    $e = @{ s = [string]$j.status; t = $f.LastWriteTimeUtc.Ticks; n = $f.Length; p = [string]$j.parent; c = [int][bool]$j.chefUpdate }
    $si = Get-JobStoredSite $j; if ($si) { $e.si = $si }
    $e
}
function Test-SameEntry($a, $b) { $a -and $b -and [string]$a.s -eq [string]$b.s -and [long]$a.t -eq [long]$b.t -and [long]$a.n -eq [long]$b.n -and [string]$a.p -eq [string]$b.p -and [int]$a.c -eq [int]$b.c -and [string]$a.si -ceq [string]$b.si }

# ---- the Site of an order (multi-site design TD-3) ----
# kitchen.ps1 add stores vars.site from the order's Tower (its kitchen.repo.json "site", read from the main checkout; repo-config.ps1).
# Orders added before that have none and are never rewritten for it: Get-KitchenJobSite derives theirs from the Tower when read.
# '' = Unassigned (no Tower, a Tower that names no Site, or a config that will not load: a display tag never stops a reader).
if ($null -eq $script:RepoSiteCodes -or -not (Get-Command Read-RepoConfig -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'repo-config.ps1') }   # (its list must be in this script's scope)
$script:JobSiteByTower = @{}   # Tower path -> its Site, once per process (a reader of 100 old orders reads each Tower's config once)
function Get-JobVar($j, [string]$Name) { if ($j.vars -is [Collections.IDictionary]) { [string]$j.vars[$Name] } elseif ($j.vars) { [string]$j.vars.$Name } else { '' } }
# The order's Tower (a local checkout): vars.repo, else the first step's Repo argument; a {{template}} not yet filled is no Tower.
function Get-JobTower($j) {
    $r = Get-JobVar $j 'repo'; if ($r -and $r -notmatch '\{\{') { return $r }
    foreach ($s in @($j.steps)) { if ($s.args -and $s.args.Repo -and [string]$s.args.Repo -notmatch '\{\{') { return [string]$s.args.Repo } }
    ''
}
# The Site the order carries itself (vars.site, a known code), '' when none. What jobs-index.json stores as si.
function Get-JobStoredSite($j) { $s = Get-JobVar $j 'site'; if ($s -cin $script:RepoSiteCodes) { $s } else { '' } }
# The Tower's Site; throws on a config that will not load (kitchen.ps1 add logs that). Get-TowerSite: the same for readers, cached, no git, '' on any error.
function Read-TowerSite([string]$Tower) { [string](Get-RepoConfig $Tower).Site }
# Readers never run git for a Site tag (kitchen.ps1 status must make no git call: Test-Freeze Status_DoesNotRunGit, 10-22's 145 s status;
# TD-5 grouped status by Site through here). The main checkout is found from the files, the way pass-app/server.mjs mainOf does it: a
# .git folder, or none, = the folder itself; a worktree's .git file names <main>\.git\worktrees\<name> (its commondir, when there is one).
function Get-TowerMainNoGit([string]$Tower) {
    $full = [IO.Path]::GetFullPath($Tower).TrimEnd('\', '/')
    $g = Join-Path $full '.git'
    if (-not (Test-Path -LiteralPath $g -PathType Leaf)) { return $full }
    $m = [regex]::Match([IO.File]::ReadAllText($g), '(?m)^gitdir:\s*(.+?)\s*$'); if (-not $m.Success) { throw "$g names no gitdir" }
    $gd = [IO.Path]::GetFullPath([IO.Path]::Combine($full, $m.Groups[1].Value))
    $cf = Join-Path $gd 'commondir'
    $common = if (Test-Path -LiteralPath $cf -PathType Leaf) { [IO.Path]::GetFullPath([IO.Path]::Combine($gd, [IO.File]::ReadAllText($cf).Trim())) } else { [IO.Path]::GetFullPath([IO.Path]::Combine($gd, '..', '..')) }
    Split-Path -Parent $common.TrimEnd('\', '/')
}
function Get-TowerSite([string]$Tower) {
    if (-not $Tower) { return '' }
    if (-not $script:JobSiteByTower.ContainsKey($Tower)) { $script:JobSiteByTower[$Tower] = try { [string](Read-RepoConfig (Get-TowerMainNoGit $Tower)).Site } catch { '' } }
    $script:JobSiteByTower[$Tower]
}
# For readers: the order's Site, stored or (an order from before TD-3) derived from its Tower on the fly. Never written back.
function Get-KitchenJobSite($j) { $s = Get-JobStoredSite $j; if ($s) { $s } else { Get-TowerSite (Get-JobTower $j) } }

# The jobs\ files as FileInfo, oldest id first (the one place the jobs folder is listed).
function Get-JobFiles([string]$Root) {
    $dir = [IO.DirectoryInfo]::new((Join-Path $Root 'jobs'))
    if (-not $dir.Exists) { return , @() }
    $fs = [Collections.Generic.List[IO.FileInfo]]::new(); $ks = [Collections.Generic.List[int]]::new()
    foreach ($f in $dir.EnumerateFiles('J*.json')) { $nm = $f.Name; $n = 0; if ($nm.Length -le 15 -and [int]::TryParse($nm.Substring(1, $nm.Length - 6), [ref]$n) -and $nm -ceq "J$n.json") { $fs.Add($f); $ks.Add($n) } }
    $fa = $fs.ToArray(); [Array]::Sort($ks.ToArray(), $fa)
    , $fa
}

# Refresh the index and read jobs. Mode: 'index' (only files that changed), 'live' (also every order still in play, returned),
# 'all' (every jobs\ file, returned). -RequireSteps (the supervisor) counts a job without steps as damaged too. OnDamaged { param($file, $why) } is called for a file that will not parse or has no id/steps.
# Returns @{ jobs = parsed hashtables oldest first; index = id -> entry; rebuilt = '' or why the index was rebuilt; read = files parsed }.
$script:JobsIndexMem = $null
function Update-KitchenJobs([string]$Root, [string]$Mode = 'all', [scriptblock]$OnDamaged = $null, [string]$Trace = '', [switch]$RequireSteps) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'jobs'))) { return @{ jobs = @(); index = @{}; rebuilt = ''; read = 0 } }   # no kitchen here (yet)
    $rebuilt = ''
    if ($script:JobsIndexMem -and $script:JobsIndexMem.root -eq $Root) { $idx = $script:JobsIndexMem.jobs }
    else {
        $r = Read-JobsIndexFile $Root
        if ($r.ok) { $idx = $r.jobs } else { $idx = @{}; $rebuilt = $r.reason }
    }
    $out = [Collections.Generic.List[object]]::new(); $seen = [Collections.Generic.HashSet[string]]::new(); $changed = [bool]$rebuilt; $read = 0
    foreach ($f in (Get-JobFiles $Root)) {
        $id = $f.Name.Substring(0, $f.Name.Length - 5); [void]$seen.Add($id)
        $e = $idx[$id]
        $fresh = -not $rebuilt -and $e -and [long]$e.t -eq $f.LastWriteTimeUtc.Ticks -and [long]$e.n -eq $f.Length
        if ($fresh -and ($Mode -eq 'index' -or ($Mode -eq 'live' -and -not (Test-JobLive $e)))) { continue }
        $j = $null; $why = ''
        try { $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json -AsHashtable; if ($j -isnot [hashtable] -or -not $j.id) { $why = 'missing id' } elseif ($RequireSteps -and -not $j.steps) { $why = 'missing id or steps' } }
        catch { $why = $_.Exception.Message }
        $read++
        if ($Trace -and $env:KITCHEN_TRACE_READS) { try { Add-Content -LiteralPath $env:KITCHEN_TRACE_READS -Value "$Trace $id" -Encoding utf8 } catch { } }
        if ($why) {
            if ($idx.ContainsKey($id)) { $idx.Remove($id); $changed = $true }
            if ($OnDamaged) { & $OnDamaged $f $why }
            continue
        }
        $ne = New-JobsIndexEntry $j $f
        if (-not (Test-SameEntry $e $ne)) { $idx[$id] = $ne; $changed = $true }
        if ($Mode -eq 'all' -or ($Mode -eq 'live' -and (Test-JobLive $ne))) { $out.Add($j) }
    }
    foreach ($k in @($idx.Keys)) { if (-not $seen.Contains($k)) { $idx.Remove($k); $changed = $true } }
    $script:JobsIndexMem = @{ root = $Root; jobs = $idx; dirty = $false }
    if ($changed) { Write-JobsIndexFile $Root $idx }
    @{ jobs = $out.ToArray(); index = $idx; rebuilt = $rebuilt; read = $read }
}
# Save-Job's half: the entry of a file just written (the index is written when the caller is done: Save-KitchenJobsIndex).
function Set-KitchenJobsIndexEntry([string]$Root, $j) {
    if (-not $script:JobsIndexMem -or $script:JobsIndexMem.root -ne $Root) { return }   # not read in this process: the next reader sees the change
    $f = [IO.FileInfo]::new((Join-Path $Root "jobs\$($j.id).json")); if (-not $f.Exists) { return }
    $script:JobsIndexMem.jobs[[string]$j.id] = New-JobsIndexEntry $j $f; $script:JobsIndexMem.dirty = $true
}
function Save-KitchenJobsIndex([string]$Root) {
    if ($script:JobsIndexMem -and $script:JobsIndexMem.root -eq $Root -and $script:JobsIndexMem.dirty) { Write-JobsIndexFile $Root $script:JobsIndexMem.jobs; $script:JobsIndexMem.dirty = $false }
}

# ---- the archive ----
function Get-JobsArchiveDir([string]$Root) { Join-Path $Root 'jobs\archive' }
# One summary line per archived order: what the history readers (ledger, scoreboard, roadmap, Chef history) need without the file.
function Get-JobArchiveLine($j, [DateTime]$endedUtc, [string]$month) {
    $repo = Get-JobTower $j
    $idea = [regex]::Match([string]$j.vars.goal, '\(Idea (I\d+):'); $code = [bool](@($j.steps | Where-Object { [string]$_.script -match 'merge\.ps1$' }).Count)
    $created = if ($j.created -is [DateTime]) { $j.created.ToUniversalTime().ToString('o') } else { [string]$j.created }   # (the JSON reader turns ISO text into a DateTime)
    [ordered]@{ id = [string]$j.id; status = [string]$j.status; name = [string]$j.name; recipe = [string]$j.recipe; created = $created; ended = $endedUtc.ToString('o')
        costUsd = [double]$j.costUsd; repo = $repo; parent = [string]$j.parent; replacedBy = [string]$j.replacedBy; idea = $(if ($idea.Success) { $idea.Groups[1].Value } else { '' })
        item = (Get-JobVar $j 'item'); site = (Get-JobStoredSite $j); code = $code; month = $month; archivedAt = [DateTime]::UtcNow.ToString('o') }
}
# Finished orders (done, closed) whose file is untouched for OlderThanDays move to jobs\archive\yyyy-MM\ (month of their last write).
# Call it holding the kitchen's state lock. The summary lines are appended before any file moves, so a stop half way leaves a line
# whose file is still in jobs\ (the jobs\ file wins) and the next run moves it: running it again is always safe.
function Invoke-KitchenJobArchive([string]$Root, [double]$OlderThanDays = 3) {
    $res = [ordered]@{ archived = 0; skipped = @(); ms = 0 }; $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Update-KitchenJobs $Root 'index'
    $cut = [DateTime]::UtcNow.AddDays(-$OlderThanDays).Ticks; $ad = Get-JobsArchiveDir $Root; $lines = [Collections.Generic.List[string]]::new(); $moves = @()
    foreach ($id in @($r.index.Keys)) {
        $e = $r.index[$id]
        if ([string]$e.s -notin $script:JobsFinished -or [int]$e.c -eq 1 -or [long]$e.t -gt $cut) { continue }
        $src = Join-Path $Root "jobs\$id.json"
        $j = try { [IO.File]::ReadAllText($src) | ConvertFrom-Json -AsHashtable } catch { $null }
        if (-not $j -or [string]$j.status -notin $script:JobsFinished -or $j.chefUpdate -or $j.recooking) { continue }   # changed since the index saw it
        $ended = [DateTime]::new([long]$e.t, [DateTimeKind]::Utc); $month = $ended.ToString('yyyy-MM')
        $dest = Join-Path $ad "$month\$id.json"
        if (Test-Path -LiteralPath $dest) { $res.skipped += "$id (an archived copy already exists at $dest)"; continue }
        $lines.Add(((Get-JobArchiveLine $j $ended $month) | ConvertTo-Json -Compress)); $moves += , @($id, $src, $dest)
    }
    if ($lines.Count) {
        New-Item -ItemType Directory -Force -Path $ad | Out-Null
        [IO.File]::AppendAllText((Join-Path $ad 'index.jsonl'), (($lines -join "`n") + "`n"))
        foreach ($m in $moves) {
            try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $m[2]) | Out-Null; [IO.File]::Move($m[1], $m[2]); $r.index.Remove($m[0]); $res.archived++ }
            catch { $res.skipped += "$($m[0]) ($($_.Exception.Message))" }
        }
        Write-JobsIndexFile $Root $r.index
    }
    $res.ms = $sw.ElapsedMilliseconds; $res
}
# id -> summary of every archived order (a later line for the same id wins; a damaged line is skipped)
function Read-KitchenJobArchive([string]$Root) {
    $by = @{}; $p = Join-Path (Get-JobsArchiveDir $Root) 'index.jsonl'
    if (-not (Test-Path -LiteralPath $p)) { return $by }
    foreach ($l in [IO.File]::ReadLines($p)) { if (-not $l.Trim()) { continue }; try { $s = $l | ConvertFrom-Json -AsHashtable; if ($s.id -match '^J\d+$') { $by[[string]$s.id] = $s } } catch { } }
    $by
}
# An archive line shaped like a job (id, status, name, recipe, created, parent, replacedBy, costUsd, vars.repo/item/goal, a merge
# step when it merged code), marked archived = $true. Enough for the ledger and the roadmap; read the file for anything else.
function ConvertTo-ArchivedJob($s) {
    $vars = @{ repo = [string]$s.repo; item = [string]$s.item }; if ($s.idea) { $vars.goal = "(Idea $($s.idea): archived order)" }
    if ($s.site) { $vars.site = [string]$s.site }   # (a line from before TD-3 has none: Get-KitchenJobSite derives it from repo)
    @{ id = [string]$s.id; status = [string]$s.status; name = [string]$s.name; recipe = [string]$s.recipe; created = [string]$s.created; ended = [string]$s.ended
        parent = [string]$s.parent; replacedBy = [string]$s.replacedBy; costUsd = [double]$s.costUsd; vars = $vars; history = @()
        steps = @(if ($s.code) { @{ script = 'merge.ps1'; args = @{ Repo = [string]$s.repo } } }); archived = $true; month = [string]$s.month }
}
function Read-ArchivedJobFile([string]$Root, $s) { $p = Join-Path (Get-JobsArchiveDir $Root) "$($s.month)\$($s.id).json"; try { [IO.File]::ReadAllText($p) | ConvertFrom-Json -AsHashtable } catch { $null } }
# Where an order's file is: jobs\ first, then the archive (null when neither has it).
function Get-KitchenJobPath([string]$Root, [string]$Id) {
    $p = Join-Path $Root "jobs\$Id.json"; if (Test-Path -LiteralPath $p) { return $p }
    $s = (Read-KitchenJobArchive $Root)[$Id]; if ($s) { $a = Join-Path (Get-JobsArchiveDir $Root) "$($s.month)\$Id.json"; if (Test-Path -LiteralPath $a) { return $a } }
    $null
}

# For readers: the jobs\ orders (-Live: only those still in play), plus -WithArchive every archived order as ConvertTo-ArchivedJob,
# plus -ArchiveFull { param($summary) ... } the full file of each archived order the filter keeps. A jobs\ file wins over its archive line.
function Get-KitchenJobs([string]$Root, [switch]$Live, [switch]$WithArchive, [scriptblock]$ArchiveFull = $null) {
    $r = Update-KitchenJobs $Root $(if ($Live) { 'live' } else { 'all' })
    $out = [Collections.Generic.List[object]]::new(); foreach ($j in $r.jobs) { $out.Add($j) }
    if ($WithArchive -or $ArchiveFull) {
        foreach ($s in (Read-KitchenJobArchive $Root).Values) {
            if ($r.index.ContainsKey([string]$s.id)) { continue }
            if ($ArchiveFull) { if (& $ArchiveFull $s) { $full = Read-ArchivedJobFile $Root $s; if ($full) { $full.archived = $true; $out.Add($full) } } }
            else { $out.Add((ConvertTo-ArchivedJob $s)) }
        }
    }
    $out.ToArray()   # (one job per pipeline item, like a Get-ChildItem)
}
