# Dot-source (functions only): CI budgets per Site (multi-site design TD-11, Owner's Q8 = yes): GitHub Actions runs and billed minutes per
# Site per calendar month (UTC), counted by the chores (kitchen.ps1 Invoke-ChoreCiBudget) into <kitchen>\ci-budget.json; the pr station asks Get-CiBudgetHold.
# Budget: kitchen.json "sites": { "<CODE>": { "ciMinutesPerMonth": 1000 | "unlimited", "towers": ["C:\\path\\to\\checkout"] } }. No budget = never held.
# Billed minutes, as GitHub Free bills a private repo (projects/tide/audits/go-public-scan-2026-10-23.md): each job rounded up to a whole
# minute, Windows 2x, macOS 10x; a public repo's runs are free (0 billed). The account's private repos share one pool (2,000 a month;
# kitchen.json "ciPrivatePoolMinutes" overrides), shown on the Board, never a hold by itself.
# A GitHub read that fails makes that Tower "unknown" with the reason (TD-EH-15's rule): never zero, and unknown alone never holds a PR.
# Minutes measured so far are real minutes, so a Site is "over" only when what was measured already reaches its budget.
# gh is github-lib.ps1's Invoke-GhJson (KITCHEN_GH = a fake in tests; no test calls GitHub). KITCHEN_CI_NOW stands in for the clock.
if (-not (Get-Command Invoke-GhJson -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'github-lib.ps1') }
if (-not (Get-Command Read-SiteRegistry -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'freeze-lib.ps1') }

function Get-CiNow { if ($env:KITCHEN_CI_NOW) { ([DateTimeOffset]::Parse($env:KITCHEN_CI_NOW, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime } else { [DateTime]::UtcNow } }
function Get-CiMonth([DateTime]$Now = (Get-CiNow)) { $Now.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture) }
function Get-CiMonthEnd([DateTime]$Now = (Get-CiNow)) { [DateTime]::new($Now.Year, $Now.Month, 1, 0, 0, 0, [DateTimeKind]::Utc).AddMonths(1) }
function Get-CiBudgetPath([string]$KitchenRoot) { Join-Path $KitchenRoot 'ci-budget.json' }
function Get-CiCachePath([string]$KitchenRoot) { Join-Path $KitchenRoot 'ci-budget-cache.json' }

# A Site's "ciMinutesPerMonth": {given; unlimited; limit; bad}. Absent = not given (no hold). A wrong value is named in bad and holds nothing.
function ConvertTo-CiBudget($Value) {
    $o = @{ given = $false; unlimited = $false; limit = $null; bad = '' }
    if ($null -eq $Value) { return $o }
    if ($Value -is [string] -and $Value.Trim() -ieq 'unlimited') { $o.given = $true; $o.unlimited = $true; return $o }
    if (($Value -is [int] -or $Value -is [long]) -and $Value -ge 0) { $o.given = $true; $o.limit = [long]$Value; return $o }
    $o.bad = "ciMinutesPerMonth '$Value' must be a whole number of 0 or more, or ""unlimited""; no budget, nothing held"; $o
}
# The registry entry of one Site (exact code), or $null
function Get-CiSiteEntry($Registry, [string]$Site) {
    if (-not $Site -or $Registry.sites -isnot [Collections.IDictionary]) { return $null }
    $k = @($Registry.sites.Keys | Where-Object { [string]$_ -ceq $Site })[0]
    if ($null -eq $k -or $Registry.sites[$k] -isnot [Collections.IDictionary]) { return $null }
    $Registry.sites[$k]
}
function Get-CiSiteBudget($Registry, [string]$Site) { $e = Get-CiSiteEntry $Registry $Site; ConvertTo-CiBudget $(if ($e) { $e['ciMinutesPerMonth'] }) }

# Billed minutes of one run from its jobs (GitHub's jobs API): per job, rounded up to a whole minute, times the runner's rate
function Get-CiJobRate($Job) { $l = (@($Job.labels) + @([string]$Job.runner_name)) -join ' '; if ($l -match '(?i)windows') { 2 } elseif ($l -match '(?i)mac') { 10 } else { 1 } }
# a GitHub time as ConvertFrom-Json gives it (a DateTime, UTC or already turned local) or as text; the same instant either way
function ConvertTo-CiTime($v) { if ($v -is [DateTime]) { [DateTimeOffset]$v.ToUniversalTime() } elseif ($v -is [DateTimeOffset]) { $v } else { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture) } }
function Get-CiRunMinutes($Jobs) {
    $sum = 0
    foreach ($jb in @($Jobs | Where-Object { $_ })) {
        if (-not $jb.started_at -or -not $jb.completed_at) { continue }
        $d = ((ConvertTo-CiTime $jb.completed_at) - (ConvertTo-CiTime $jb.started_at)).TotalSeconds; if ($d -le 0) { continue }
        $sum += [math]::Ceiling($d / 60) * (Get-CiJobRate $jb)
    }
    [long]$sum
}

# One Tower's month: {slug; state ok|partial|unknown; why; public; runs; minutes; measured; completed}. $Cache: run id -> billed minutes
# (completed runs only; they never change), updated in place. $Deadline: a Stopwatch limit in seconds; runs not reached are measured next time.
function Measure-CiTower([string]$Slug, [string]$Month, [hashtable]$Cache, [Diagnostics.Stopwatch]$Clock, [double]$Deadline) {
    $t = [ordered]@{ slug = $Slug; state = 'unknown'; why = ''; public = $false; runs = $null; minutes = $null; measured = 0; completed = 0 }
    $rv = Invoke-GhJson @('api', "repos/$Slug")
    if (-not $rv.ok -or $null -eq $rv.json.private) { $t.why = "could not read $Slug on GitHub ($(Get-GhWhy $rv))"; return $t }
    $t.public = -not [bool]$rv.json.private
    $list = Get-CiMonthRuns $Slug $Month $Cache
    if ($list.why) { $t.why = $list.why; return $t }
    $t.runs = [long]$list.total; $t.completed = [long]($list.total - $list.open)
    if ($t.public) { $t.state = 'ok'; $t.minutes = 0; $t.measured = $t.completed; return $t }   # public runs are free: 0 billed, nothing to measure
    $why = ''
    foreach ($id in $list.todo) {
        if ($Clock.Elapsed.TotalSeconds -ge $Deadline) { $why = 'time budget used; the rest is measured next time'; break }
        $jr = Invoke-GhJson @('api', "repos/$Slug/actions/runs/$id/jobs?per_page=100")
        if (-not $jr.ok) { $why = "could not read the jobs of run $id ($(Get-GhWhy $jr))"; break }
        $Cache["$id"] = Get-CiRunMinutes $jr.json.jobs
    }
    $t.measured = @($Cache.Keys).Count; $t.minutes = [long](($Cache.Values | Measure-Object -Sum).Sum)
    $t.state = if ($t.measured -ge $t.completed) { 'ok' } else { 'partial' }
    if ($t.state -eq 'partial') { $t.why = if ($why) { $why } else { "$($t.completed - $t.measured) finished run(s) not measured yet" } }
    $t
}
# This month's runs of one repo, newest first: {total (GitHub's own count); open (seen not finished); todo (finished, not in the cache); why}.
# Pages stop at the first page whose finished runs are all measured already (older pages were measured on earlier passes).
function Get-CiMonthRuns([string]$Slug, [string]$Month, [hashtable]$Cache) {
    $o = @{ total = 0; open = 0; todo = [Collections.Generic.List[string]]::new(); why = '' }
    for ($p = 1; $p -le 20; $p++) {
        $r = Invoke-GhJson @('api', "repos/$Slug/actions/runs?created=%3E%3D$Month-01&per_page=100&page=$p")
        if (-not $r.ok -or $null -eq $r.json.total_count) { $o.why = "could not list the CI runs of $Slug ($(Get-GhWhy $r))"; return $o }
        if ($p -eq 1) { $o.total = [long]$r.json.total_count }
        $runs = @($r.json.workflow_runs | Where-Object { $_ }); $new = 0
        foreach ($run in $runs) {
            if ([string]$run.status -ne 'completed') { $o.open++; continue }
            if (-not $Cache.ContainsKey([string]$run.id)) { $o.todo.Add([string]$run.id); $new++ }
        }
        if ($runs.Count -lt 100 -or $new -eq 0) { break }
    }
    $o
}

# The Towers to count, as {path; slug; site}: the registry's "towers" (named by Site), then the given ones (the orders' Towers) and the
# ones the last file of this month had, each with its kitchen.repo.json "site" and "github". A Tower with no GitHub home is left out.
function Get-CiTowers($Registry, [string[]]$Towers) {
    $seen = @{}; $out = [Collections.Generic.List[object]]::new()
    $named = @(); if ($Registry.sites -is [Collections.IDictionary]) { foreach ($c in $Registry.sites.Keys) { $e = $Registry.sites[$c]; if ($e -is [Collections.IDictionary] -and $e['towers']) { foreach ($p in @($e['towers'])) { $named += , @([string]$p, [string]$c) } } } }
    $all = @($named) + @(@($Towers | Where-Object { $_ }) | ForEach-Object { , @([string]$_, '') })
    foreach ($pair in $all) {
        $path = $pair[0]; $key = $path.TrimEnd('\', '/').ToLowerInvariant(); if (-not $path -or $seen.ContainsKey($key)) { continue }
        $seen[$key] = $true; $slug = Get-CiTowerSlug $path; if (-not $slug) { continue }
        $site = if ($pair[1]) { $pair[1] } else { Get-TowerSite $path }
        $out.Add([pscustomobject]@{ path = $path; slug = $slug; site = $site })
    }
    $out.ToArray()
}
function Get-CiTowerSlug([string]$Tower) {
    if (-not (Test-Path -LiteralPath $Tower)) { return '' }
    $gh = try { [string](Get-RepoConfig $Tower).Github } catch { '' }
    $g = ConvertTo-GithubSlug $gh; if ($g.bad) { return '' }
    $s = Resolve-GithubSlug $Tower $g.slug; if ($s.none -or $s.bad) { '' } else { $s.slug }
}

# One Site's line from its Towers: runs and minutes are summed only when every Tower is known; minutesAtLeast is what was measured (for the hold)
function Get-CiSiteLine([string]$Code, $Towers, $Budget) {
    $known = @($Towers | Where-Object { $_.state -ne 'unknown' }); $unk = @($Towers | Where-Object { $_.state -eq 'unknown' })
    $atLeast = if ($known.Count) { [long](($known | ForEach-Object { [long]$_.minutes } | Measure-Object -Sum).Sum) } else { $null }
    $state = if (-not $Towers.Count) { 'none' } elseif ($unk.Count) { 'unknown' } elseif (@($known | Where-Object { $_.state -eq 'partial' }).Count) { 'partial' } else { 'ok' }
    $why = (@($Towers | Where-Object { $_.why } | ForEach-Object { "$($_.slug): $($_.why)" }) -join '; '); if (-not $Towers.Count) { $why = 'no Tower of this Site is on GitHub (on record)' }
    $over = Test-CiOver $Budget $atLeast
    [ordered]@{ code = $Code; budget = $(if ($Budget.unlimited) { 'unlimited' } else { $Budget.limit }); budgetBad = $Budget.bad; state = $state; why = $why
        runs = $(if ($state -in 'unknown', 'none') { $null } else { [long](($Towers | ForEach-Object { [long]$_.runs } | Measure-Object -Sum).Sum) })
        minutes = $(if ($state -in 'unknown', 'none') { $null } else { $atLeast }); minutesAtLeast = $atLeast; over = $over; towers = @($Towers) }
}
# over = a set, limited budget that what was measured already reaches (and something was spent: a budget of 0 with nothing used holds nothing)
function Test-CiOver($Budget, $AtLeast) { [bool]($Budget.given -and -not $Budget.unlimited -and $null -ne $AtLeast -and [long]$AtLeast -gt 0 -and [long]$AtLeast -ge [long]$Budget.limit) }

# The chore: count every Tower, write <kitchen>\ci-budget.json and the cache. Never throws; a registry that cannot be read is one unknown.
function Update-CiBudget([string]$KitchenRoot, [string[]]$Towers = @(), [double]$BudgetSec = 20) {
    $now = Get-CiNow; $month = Get-CiMonth $now; $clock = [Diagnostics.Stopwatch]::StartNew()
    $doc = [ordered]@{ at = $now.ToString('o'); month = $month; monthEnds = (Get-CiMonthEnd $now).ToString('o'); poolLimit = 2000; pool = $null; sites = @(); problems = @() }
    $reg = try { Read-SiteRegistry $KitchenRoot } catch { $doc.problems = @("the Sites registry cannot be read: $($_.Exception.Message)"); Write-JsonAtomic (Get-CiBudgetPath $KitchenRoot) $doc; return $doc }
    $doc.poolLimit = Get-CiPoolLimit $KitchenRoot
    $prev = Read-JsonFile (Get-CiBudgetPath $KitchenRoot)
    $old = if ($prev -and [string]$prev.month -eq $month) { @($prev.sites | ForEach-Object { @($_.towers) } | ForEach-Object { [string]$_.path } | Where-Object { $_ }) } else { @() }
    $cache = Read-CiCache $KitchenRoot $month
    $measured = @(foreach ($tw in (Get-CiTowers $reg (@($Towers) + $old))) {
            if (-not $cache.towers.ContainsKey($tw.slug)) { $cache.towers[$tw.slug] = @{} }
            $m = Measure-CiTower $tw.slug $month $cache.towers[$tw.slug] $clock $BudgetSec
            $m.path = $tw.path; $m.site = [string]$tw.site; [pscustomobject]$m
        })
    $set = @(if ($reg.sites -is [Collections.IDictionary]) { @($reg.sites.Keys | Where-Object { $e = Get-CiSiteEntry $reg ([string]$_); $e -and $e.Contains('ciMinutesPerMonth') }) })   # a Site with a budget shows, Towers or not
    $codes = @(@($measured | ForEach-Object { [string]$_.site }) + $set | Select-Object -Unique | Sort-Object)
    $doc.sites = @(foreach ($c in $codes) { $b = Get-CiSiteBudget $reg ([string]$c); if ($b.bad) { $doc.problems += "sites.${c}: $($b.bad)" }; Get-CiSiteLine ([string]$c) @($measured | Where-Object { $_.site -ceq [string]$c }) $b })
    $priv = @($measured | Where-Object { -not $_.public -or $_.state -eq 'unknown' })
    $doc.pool = [ordered]@{ state = $(if (@($priv | Where-Object { $_.state -eq 'unknown' }).Count) { 'unknown' } else { 'ok' }); minutesAtLeast = [long](($priv | Where-Object { $_.state -ne 'unknown' } | ForEach-Object { [long]$_.minutes } | Measure-Object -Sum).Sum) }
    Write-JsonAtomic (Get-CiCachePath $KitchenRoot) $cache
    Write-JsonAtomic (Get-CiBudgetPath $KitchenRoot) $doc
    $doc
}
function Get-CiPoolLimit([string]$KitchenRoot) {
    $v = $null
    foreach ($p in (Get-SiteRegistryPaths $KitchenRoot)) { $c = try { Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; if ($c -is [Collections.IDictionary] -and $c.Contains('ciPrivatePoolMinutes')) { $v = $c['ciPrivatePoolMinutes'] } }
    if (($v -is [int] -or $v -is [long]) -and $v -gt 0) { [long]$v } else { 2000 }
}
# The run cache of this month ({month; towers: slug -> {run id -> minutes}}); another month's cache, or a damaged one, starts empty
function Read-CiCache([string]$KitchenRoot, [string]$Month) {
    $c = try { Get-Content -LiteralPath (Get-CiCachePath $KitchenRoot) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }
    if ($c -is [Collections.IDictionary] -and [string]$c['month'] -eq $Month -and $c['towers'] -is [Collections.IDictionary]) { return @{ month = $Month; towers = $c['towers'] } }
    @{ month = $Month; towers = @{} }
}

# The pr station's question: is opening a NEW pull request for this Site held? {hold; why}. Held only when this month's file shows the
# Site's measured minutes reaching the budget the registry sets NOW (a raised budget, or "unlimited", lets PRs go at once). No file, a
# file from another month, an unreadable registry or file, no budget: not held (unknown never holds by itself).
function Get-CiBudgetHold([string]$KitchenRoot, [string]$Site) {
    $no = [pscustomobject]@{ hold = $false; why = '' }
    if (-not $Site) { return $no }
    $v = Read-JsonFile (Get-CiBudgetPath $KitchenRoot); if (-not $v -or [string]$v.month -ne (Get-CiMonth)) { return $no }
    $reg = try { Read-SiteRegistry $KitchenRoot } catch { return $no }
    $b = Get-CiSiteBudget $reg $Site
    $line = @($v.sites | Where-Object { [string]$_.code -ceq $Site })[0]; if (-not $line) { return $no }
    $at = if ($null -ne $line.minutesAtLeast) { [long]$line.minutesAtLeast } else { $null }
    if (-not (Test-CiOver $b $at)) { return $no }
    $ends = try { (ConvertTo-CiTime $v.monthEnds).ToLocalTime().ToString('MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } catch { 'the new month' }
    [pscustomobject]@{ hold = $true; why = "Site $Site is over its CI budget: at least $at of $($b.limit) billed minutes this month; new pull requests wait until $ends, a bigger ciMinutesPerMonth in kitchen.json, or a public Tower (open ones go on)" }
}
