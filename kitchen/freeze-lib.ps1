# Dot-source (functions only): per-repo merge freeze windows, the "freeze" list of a repo's kitchen.repo.json (validated by
# repo-config.ps1, read from the MAIN checkout like every other key). Used by the merge station (waits, exit 11, until the window
# ends), scripts/merge-pr.ps1 (refuses), kitchen.ps1 status and the Chef line (<kitchen>\freeze.json, read-only).
# KITCHEN_FREEZE_NOW (a time like 2026-10-27T12:00) stands in for the clock in tests.
if (-not (Get-Command Read-RepoConfig -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'repo-config.ps1') }
if (-not (Test-Path function:Get-KitchenJobs)) { . (Join-Path $PSScriptRoot 'jobs-lib.ps1') }

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
function Format-FreezeReason($Window) { "frozen until $(Format-FreezeTime $Window.To): $($Window.Why)" }

# A repo's freeze as the merge station needs it: {err, active, reason, waitSec, name}. err = the config will not load (the message
# names the file and the field); nothing may merge then, because nobody can say whether a window covers now.
function Get-RepoFreezeState([string]$Repo, $Now = $null) {
    $r = [pscustomobject]@{ err = ''; active = $null; reason = ''; waitSec = 0; name = (Split-Path -Leaf ([IO.Path]::GetFullPath($Repo).TrimEnd('\', '/'))) }
    try { $cfg = Get-RepoConfig $Repo; $n = if ($Now) { $Now } else { Get-FreezeNow } } catch { $r.err = "cannot tell whether merges are frozen: $($_.Exception.Message)"; return $r }
    $w = Get-ActiveFreeze $cfg.Freeze $n
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
    $repos = @(); $errors = @(); $all = @(Get-KitchenRepos $KitchenRoot)
    foreach ($r in $all) {
        $name = Split-Path -Leaf $r
        try { $cfg = Read-RepoConfig $r } catch { $errors += [ordered]@{ repo = $r; name = $name; error = $_.Exception.Message }; continue }
        $ws = @($cfg.Freeze | Where-Object { $_.To -gt $n } | Sort-Object { $_.From } | ForEach-Object {
                [ordered]@{ from = $_.From.ToString('o'); to = $_.To.ToString('o'); why = $_.Why; active = ($_.From -le $n); fromText = (Format-FreezeTime $_.From); toText = (Format-FreezeTime $_.To); reason = (Format-FreezeReason $_) } })
        if ($ws.Count) { $repos += [ordered]@{ repo = $r; name = $name; windows = $ws } }
    }
    [ordered]@{ at = $n.ToString('o'); repos = @($repos); errors = @($errors); sources = @(Get-FreezeSources $all) }
}

# Plain lines for kitchen.ps1 status (none when nothing is frozen or planned).
function Format-FreezeLines($View) {
    foreach ($r in $View.repos) {
        foreach ($w in $r.windows) {
            if ($w.active) { "  FREEZE $($r.name): merges $($w.reason); building, testing and pull requests go on" }
            else { "  FREEZE $($r.name): merges will freeze $($w.fromText) to $($w.toText): $($w.why)" }
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

# <kitchen>\freeze.json for Chef and kitchen.ps1 status, rewritten when a repo's kitchen.repo.json changed since (its sources) or the file is
# older than <MaxAgeSec> (a new repo, or a window starting or ending, shows within 10 minutes). The supervisor calls this every tick; the
# check reads one small file and stats one config per repo (10-22: rebuilding it every 2 minutes asked git about every job's repo).
function Update-FreezeView([string]$KitchenRoot, [int]$MaxAgeSec = 600) {
    $p = Join-Path $KitchenRoot 'freeze.json'
    if ($MaxAgeSec -gt 0 -and (Test-Path -LiteralPath $p) -and ((Get-Date) - (Get-Item -LiteralPath $p).LastWriteTime).TotalSeconds -lt $MaxAgeSec) {
        $old = try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { $null }
        if ($old -and $old.PSObject.Properties['sources']) {
            $changed = @($old.sources | Where-Object { [long]$_.mtime -ne [long]@(Get-FreezeSources @([string]$_.repo))[0].mtime }).Count
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
                    [ordered]@{ from = $w.from; to = $w.to; why = $w.why; active = ($from -le $n); fromText = $w.fromText; toText = $w.toText; reason = $w.reason }
                })
            if ($ws.Count) { [ordered]@{ repo = $r.repo; name = $r.name; windows = $ws } }
        })
    [ordered]@{ at = [string]$v.at; repos = @($repos); errors = @($v.errors | Where-Object { $_ }) }
}
