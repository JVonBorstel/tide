# Dot-source (functions only): per-repo merge freeze windows, the "freeze" list of a repo's kitchen.repo.json (validated by
# repo-config.ps1, read from the MAIN checkout like every other key). Used by the merge station (waits, exit 11, until the window
# ends), scripts/merge-pr.ps1 (refuses), kitchen.ps1 status and the Chef line (<kitchen>\freeze.json, read-only).
# KITCHEN_FREEZE_NOW (a time like 2026-10-27T12:00) stands in for the clock in tests.
# Site-closed windows (multi-site design TD-9, section 2.4): a Site's windows in the Sites registry (kitchen.json "sites") are added to
# the windows of every Tower of that Site; the registry is read by kitchen/site-registry.ps1 (Read-SiteRegistry).
if (-not (Get-Command Read-RepoConfig -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'repo-config.ps1') }
if (-not (Test-Path function:Get-KitchenJobs)) { . (Join-Path $PSScriptRoot 'jobs-lib.ps1') }
if (-not (Get-Command Read-SiteRegistry -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'site-registry.ps1') }   # the one Sites registry reader

function Get-FreezeNow {
    if (-not $env:KITCHEN_FREEZE_NOW) { return [DateTimeOffset]::Now }
    $n = ConvertTo-FreezeTime $env:KITCHEN_FREEZE_NOW
    if ($null -eq $n) { throw "KITCHEN_FREEZE_NOW is not a time like 2026-10-27T12:00 (got '$($env:KITCHEN_FREEZE_NOW)')" }
    $n
}

# The window covering <Now> (from <= now < to), or $null. Overlapping windows: the one that ends last.
function Get-ActiveFreeze([object[]]$Windows, [DateTimeOffset]$Now) {
    @($Windows | Where-Object { $_ -and $_.From -le $Now -and $Now -lt $_.To } | Sort-Object { $_.To } -Descending) | Select-Object -First 1
}

function Format-FreezeTime([DateTimeOffset]$T) { $T.ToLocalTime().ToString('MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
# 'frozen until 10-28 18:00: release demo'
# a Site's window (from the registry) also names the Site: 'frozen until 10-30 12:00: release (Site TD closed)'
function Get-FreezeSite($Window) { if ($Window.PSObject.Properties['Site']) { [string]$Window.Site } else { '' } }
function Format-FreezeReason($Window) { $s = Get-FreezeSite $Window; "frozen until $(Format-FreezeTime $Window.To): $($Window.Why)$(if ($s) { " (Site $s closed)" })" }

# ---- Site-closed windows from the Sites registry (TD-9) ----------------------------------------------------------------------------------
# kitchen.json "sites": { "<CODE>": { "closed": [{ "from": "2026-10-29T00:00", "to": "2026-10-30T12:00", "why": "release" }] } }: the same
# shape and rules as a Tower's "freeze" (up to 50, local time or an ISO offset, to after from, a short why). No Tower of that Site merges
# inside one. A Tower's Site is its kitchen.repo.json "site" (TD-2; read from its main checkout). kitchen.json is read by
# site-registry.ps1 Read-SiteRegistry, the way kitchen.ps1 reads its settings: the copy next to it, then the state-folder copy, whose "sites" wins.
# Unchanged when there is nothing to add: a Tower with no "site" never reads kitchen.json, and no "sites", no entry for the Tower's Site
# or no "closed" in it leaves only the Tower's own windows. Fail closed for a Tower with a Site when its windows cannot be known: a
# kitchen.json that will not parse, a "sites" that is not an object, or a bad window (the message names the file and the field).
# One Site's closed windows as [pscustomobject]@{From; To; Why; Site}, @() when it has none. Throws naming kitchen.json and the field.
function Get-SiteClosedWindows($Registry, [string]$Site) {
    if (-not $Site -or $null -eq $Registry.sites) { return @() }
    $key = @($Registry.sites.Keys | Where-Object { [string]$_ -ceq $Site })[0]; if ($null -eq $key) { return @() }
    $f = $Registry.path; $e = $Registry.sites[$key]
    if ($e -isnot [Collections.IDictionary]) { throw "${f}: 'sites.$Site' must be an object" }
    $ck = @($e.Keys | Where-Object { [string]$_ -ieq 'closed' })[0]
    if ($null -eq $ck -or $null -eq $e[$ck]) { return @() }
    $list = $e[$ck]
    if ($list -is [string] -or $list -is [Collections.IDictionary]) { throw "${f}: 'sites.$Site.closed' must be a list of windows, each {""from"", ""to"", ""why""}" }
    $w = @($list); if ($w.Count -gt 50) { throw "${f}: 'sites.$Site.closed' has more than 50 windows" }
    @(for ($i = 0; $i -lt $w.Count; $i++) {
            $x = $w[$i]; $at = "'sites.$Site.closed[$i]"
            if ($x -isnot [Collections.IDictionary]) { throw "${f}: $at' must be an object with ""from"", ""to"" and ""why""" }
            $ev = @{}; foreach ($k in 'from', 'to', 'why') { $kk = @($x.Keys | Where-Object { [string]$_ -ieq $k })[0]; $ev[$k] = if ($null -ne $kk) { $x[$kk] } else { $null } }
            $t = @{}
            foreach ($k in 'from', 'to') {
                if ($null -eq $ev[$k]) { throw "${f}: $at.$k' is missing (a local date and time like 2026-10-27T00:00)" }
                $t[$k] = ConvertTo-FreezeTime $ev[$k]
                if ($null -eq $t[$k]) { throw "${f}: $at.$k' must be a date and time like 2026-10-27T00:00 (got '$($ev[$k])')" }
            }
            if ($t.to -le $t.from) { throw "${f}: $at.to' ($($ev.to)) must be after its 'from' ($($ev.from))" }
            $why = $ev.why
            if ($why -isnot [string] -or [string]::IsNullOrWhiteSpace($why) -or $why.Length -gt 200 -or $why -match '[\x00-\x1f]') { throw "${f}: $at.why' must be a short reason, 1 to 200 characters on one line" }
            [pscustomobject]@{ From = $t.from; To = $t.to; Why = $why.Trim(); Site = $Site }
        })
}
# A Tower's windows: its own "freeze" plus its Site's closed windows (only a Tower with a Site reads the registry). <Registry>: one already
# read (the view reads kitchen.json once for every Tower), else read here.
function Get-TowerFreezeWindows($Cfg, [string]$KitchenRoot = '', $Registry = $null) {
    if (-not $Cfg.Site) { return @($Cfg.Freeze) }
    $reg = if ($Registry) { $Registry } else { Read-SiteRegistry $KitchenRoot }
    @($Cfg.Freeze) + @(Get-SiteClosedWindows $reg $Cfg.Site)
}

# A repo's freeze as the merge station needs it: {err, active, reason, waitSec, name}. err = the config will not load (the message
# names the file and the field); nothing may merge then, because nobody can say whether a window covers now.
# The Tower's own windows and its Site's (TD-9) together: the active one is the one that ends last. <KitchenRoot>: where the state-folder
# kitchen.json is (default BRAIN_KITCHEN, else %LOCALAPPDATA%\brain-kitchen).
function Get-RepoFreezeState([string]$Repo, $Now = $null, [string]$KitchenRoot = '') {
    $r = [pscustomobject]@{ err = ''; active = $null; reason = ''; waitSec = 0; name = (Split-Path -Leaf ([IO.Path]::GetFullPath($Repo).TrimEnd('\', '/'))) }
    try { $cfg = Get-RepoConfig $Repo; $n = if ($Now) { $Now } else { Get-FreezeNow }; $all = Get-TowerFreezeWindows $cfg $KitchenRoot } catch { $r.err = "cannot tell whether merges are frozen: $($_.Exception.Message)"; return $r }
    $w = Get-ActiveFreeze $all $n
    if ($w) { $r.active = $w; $r.reason = Format-FreezeReason $w; $r.waitSec = [int][math]::Ceiling(($w.To - $n).TotalSeconds) + 5 }
    $r
}

# The repos the kitchen merges into: every Repo a job step names (jobs\J*.json, read as text: cheap enough for every tick) plus the
# checkout this kitchen runs from, each as its main checkout, without duplicates. Folders that no longer exist are left out.
function Get-KitchenRepos([string]$KitchenRoot) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $out = [Collections.Generic.List[string]]::new()
    # each distinct Repo text is decoded and resolved once (10-22: 1,012 mentions named 2 repos, and a git call per mention made a
    # tick take 160-340 s instead of ~11 s)
    # (orders still in play only, kitchen/jobs-lib.ps1: a finished order merges nothing more; its steps' Repo args, once per text)
    $raw = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($j in (Get-KitchenJobs $KitchenRoot -Live)) { foreach ($s in @($j.steps)) { if ($s -is [hashtable] -and $s.args -is [hashtable] -and $s.args.Repo -is [string] -and $s.args.Repo) { [void]$raw.Add($s.args.Repo) } } }
    $cands = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); [void]$cands.Add([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/'))
    foreach ($q in $raw) { try { [void]$cands.Add([IO.Path]::GetFullPath($q).TrimEnd('\', '/')) } catch { } }
    foreach ($c in $cands) {
        if (-not (Test-Path -LiteralPath $c -PathType Container)) { continue }
        $main = try { Get-RepoMainCheckout $c } catch { continue }
        if ($seen.Add($main)) { $out.Add($main) }
    }
    @($out)
}

# Every window not yet over, per repo, and every repo whose config will not load: {at, repos:[{repo, name, windows:[{from, to, why,
# active, fromText, toText, reason}]}], errors:[{repo, name, error}]}. Read-only; repos without a freeze are left out.
function Get-KitchenFreezeView([string]$KitchenRoot, $Now = $null) {
    $n = if ($Now) { $Now } else { Get-FreezeNow }
    $repos = @(); $errors = @(); $all = @(Get-KitchenRepos $KitchenRoot); $reg = $null; $regErr = ''
    foreach ($r in $all) {
        $name = Split-Path -Leaf $r
        try { $cfg = Read-RepoConfig $r } catch { $errors += [ordered]@{ repo = $r; name = $name; error = $_.Exception.Message }; continue }
        # a Tower with a Site: its Site's windows too (kitchen.json read once for the whole view); unreadable = an error, like a bad config
        if ($cfg.Site -and -not $reg -and -not $regErr) { try { $reg = Read-SiteRegistry $KitchenRoot } catch { $regErr = $_.Exception.Message } }
        $src = try { if ($cfg.Site -and $regErr) { throw $regErr }; Get-TowerFreezeWindows $cfg $KitchenRoot $reg } catch { $errors += [ordered]@{ repo = $r; name = $name; error = $_.Exception.Message; site = $cfg.Site; source = 'kitchen.json' }; continue }
        $ws = @($src | Where-Object { $_.To -gt $n } | Sort-Object { $_.From } | ForEach-Object {
                $o = [ordered]@{ from = $_.From.ToString('o'); to = $_.To.ToString('o'); why = $_.Why; active = ($_.From -le $n); fromText = (Format-FreezeTime $_.From); toText = (Format-FreezeTime $_.To); reason = (Format-FreezeReason $_) }
                $s = Get-FreezeSite $_; if ($s) { $o.site = $s }; $o })
        if ($ws.Count) { $e = [ordered]@{ repo = $r; name = $name; windows = $ws }; if ($cfg.Site) { $e.site = $cfg.Site }; $repos += $e }
    }
    [ordered]@{ at = $n.ToString('o'); repos = @($repos); errors = @($errors); sources = @(Get-FreezeSources $all); registry = @(Get-RegistrySources $KitchenRoot) }
}

# Plain lines for kitchen.ps1 status (none when nothing is frozen or planned).
function Format-FreezeLines($View) {
    foreach ($r in $View.repos) {
        foreach ($w in $r.windows) {
            if ($w.active) { "  FREEZE $($r.name): merges $($w.reason); building, testing and pull requests go on" }
            else { "  FREEZE $($r.name): merges will freeze $($w.fromText) to $($w.toText): $($w.why)$(if ($w.site) { " (Site $($w.site) closed)" })" }
        }
    }
    foreach ($e in $View.errors) { "  FREEZE $($e.name): cannot tell whether merges are frozen, so none merge: $($e.error)" }
    if ($View.note) { "  FREEZE: merge freeze windows $($View.note)" }
}

# The kitchen.repo.json of each repo and its last-write time (0 = none): freeze.json keeps them, so the tick can tell a changed config
# without asking git which repos there are.
function Get-FreezeSources([string[]]$Repos) {
    @(foreach ($r in $Repos) { $f = Join-Path $r 'kitchen.repo.json'; [ordered]@{ repo = $r; mtime = $(if (Test-Path -LiteralPath $f) { (Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks } else { 0 }) } })
}

# Both kitchen.json copies and their last-write times (0 = none): a changed Sites registry rebuilds freeze.json at once, like a changed config.
function Get-RegistrySources([string]$KitchenRoot) {
    @(foreach ($p in (Get-SiteRegistryPaths $KitchenRoot)) { [ordered]@{ path = $p; mtime = $(if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks } else { 0 }) } })
}

# <kitchen>\freeze.json for Chef and kitchen.ps1 status, rewritten when a repo's kitchen.repo.json changed since (its sources) or the file is
# older than <MaxAgeSec> (a new repo, or a window starting or ending, shows within 10 minutes). The supervisor calls this every tick; the
# check reads one small file and stats one config per repo (10-22: rebuilding it every 2 minutes asked git about every job's repo).
function Update-FreezeView([string]$KitchenRoot, [int]$MaxAgeSec = 600) {
    $p = Join-Path $KitchenRoot 'freeze.json'
    if ($MaxAgeSec -gt 0 -and (Test-Path -LiteralPath $p) -and ((Get-Date) - (Get-Item -LiteralPath $p).LastWriteTime).TotalSeconds -lt $MaxAgeSec) {
        $old = try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { $null }
        if ($old -and $old.PSObject.Properties['sources']) {
            $changed = @($old.sources | Where-Object { [long]$_.mtime -ne [long]@(Get-FreezeSources @([string]$_.repo))[0].mtime }).Count
            # the Sites registry (TD-9): a file written before it kept no registry times, so it is rebuilt once
            $reg = @(Get-RegistrySources $KitchenRoot)
            $was = if ($old.PSObject.Properties['registry']) { @($old.registry) } else { @() }
            if ($was.Count -ne $reg.Count -or @(for ($i = 0; $i -lt $reg.Count; $i++) { if ([string]$was[$i].path -ne $reg[$i].path -or [long]$was[$i].mtime -ne [long]$reg[$i].mtime) { 1 } }).Count) { $changed++ }
            if (-not $changed) { return }
        }
    }
    $v = Get-KitchenFreezeView $KitchenRoot
    $t = "$p.tmp-$PID"
    $v | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $t -Encoding utf8
    Move-Item -LiteralPath $t -Destination $p -Force
}

# The view as the supervisor last wrote it (freeze.json), for kitchen.ps1 status: no git, no config reads. Windows are re-judged at <Now>
# (ended ones dropped, active set again). No file yet, or one that cannot be read: a view with a note saying so (status prints it).
function ConvertTo-ViewTime($v) { if ($v -is [DateTime]) { [DateTimeOffset]$v } else { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture) } }   # ConvertFrom-Json may already have made it a DateTime
function Read-FreezeView([string]$KitchenRoot, $Now = $null) {
    $n = if ($Now) { $Now } else { Get-FreezeNow }
    $p = Join-Path $KitchenRoot 'freeze.json'
    if (-not (Test-Path -LiteralPath $p)) { return [ordered]@{ at = ''; repos = @(); errors = @(); note = 'not checked yet (the next supervisor tick writes freeze.json)' } }
    $v = try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { $null }
    if (-not $v -or $null -eq $v.repos) { return [ordered]@{ at = ''; repos = @(); errors = @(); note = "unknown: $p cannot be read (the next supervisor tick rewrites it)" } }
    $repos = @(foreach ($r in @($v.repos)) {
            $ws = @(foreach ($w in @($r.windows)) {
                    $from = [DateTimeOffset]::Parse([string]$w.from, [Globalization.CultureInfo]::InvariantCulture); $to = [DateTimeOffset]::Parse([string]$w.to, [Globalization.CultureInfo]::InvariantCulture)
                    if ($to -le $n) { continue }
                    $o = [ordered]@{ from = $w.from; to = $w.to; why = $w.why; active = ($from -le $n); fromText = $w.fromText; toText = $w.toText; reason = $w.reason }
                    if ($w.PSObject.Properties['site'] -and $w.site) { $o.site = [string]$w.site }; $o
                })
            if ($ws.Count) { $e = [ordered]@{ repo = $r.repo; name = $r.name; windows = $ws }; if ($r.PSObject.Properties['site'] -and $r.site) { $e.site = [string]$r.site }; $e }
        })
    [ordered]@{ at = [string]$v.at; repos = @($repos); errors = @($v.errors | Where-Object { $_ }) }
}
