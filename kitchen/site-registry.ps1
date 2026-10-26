# Dot-source (functions only): the ONE reader of the Sites registry (kitchen.json "sites", multi-site design 1.2; Owner's Q1 = A), and
# which Site a Tower or work order is in. Every reader goes through Read-SiteRegistry: kitchen.ps1 (admission, per-Site Stop-work and
# pause, status, doctor), kitchen/scaler.ps1 (per-Site maxHeavy and share), kitchen/freeze-lib.ps1 (Site-closed windows),
# kitchen/ci-budget-lib.ps1 (CI budgets), kitchen/ledger.ps1 (programs by Site) and scripts/verify-all.ps1 (suites by Site).
#
# One shape: an object keyed by Site code (2-3 capital letters), one entry per Site:
#   "sites": { "GW": { "name": "Demo Project", "towers": ["%USERPROFILE%\\demo-project"], "maxHeavy": 2, "share": 1,
#                      "ciMinutesPerMonth": 1000, "closed": [{ "from": "...", "to": "...", "why": "..." }] }, ... }
# Every key of an entry is optional. Each reader takes the keys it owns: name and towers (Get-SiteList: status, Ledger, verify-all),
# maxHeavy and share (Get-KitchenSites: admission and the start order), closed (freeze-lib.ps1), ciMinutesPerMonth (ci-budget-lib.ps1).
# Where: kitchen.json next to this script (the repo template, an empty "sites"), then the state-folder copy, whose "sites" replaces it:
# the same files and order as kitchen.ps1's settings. No "sites", or an empty one = no registry, and every reader works exactly as
# before Sites.
# A kitchen.json that will not parse, or a "sites" that is not an object, throws (fail closed): each caller names it (status line, a
# Ledger finding, verify-all exit 2, merges held for a Tower with a Site), and admission keeps the old rules with the problem named.
$script:SiteCodeRe = '^[A-Z]{2,3}$'

# ---- the file ----------------------------------------------------------------------------------------------------------------------------
function Get-SiteKitchenRoot([string]$KitchenRoot) { if ($KitchenRoot) { $KitchenRoot } elseif ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' } }
function Get-SiteRegistryPaths([string]$KitchenRoot) { @((Join-Path $PSScriptRoot 'kitchen.json'), (Join-Path (Get-SiteKitchenRoot $KitchenRoot) 'kitchen.json')) }
# The raw registry: @{ sites = <the "sites" object, or $null>; path = <the file it came from> }. Throws naming the file.
function Read-SiteRegistry([string]$KitchenRoot) {
    $reg = $null; $src = ''
    foreach ($p in (Get-SiteRegistryPaths $KitchenRoot)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $c = try { Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { throw "${p}: cannot be read as JSON ($($_.Exception.Message))" }
        if ($c -is [Collections.IDictionary] -and $c.Contains('sites')) { $reg = $c['sites']; $src = $p }
    }
    if ($null -ne $reg -and $reg -isnot [Collections.IDictionary]) { throw "${src}: 'sites' must be an object keyed by Site code" }
    @{ sites = $reg; path = $src }
}

# ---- name and towers: status, the Ledger, verify-all (TD-5) -------------------------------------------------------------------------------
# One spelling of a Tower path for comparing: full, no trailing slash. A path that cannot be made full is compared as written.
function ConvertTo-SiteTowerKey([string]$Path) {
    if (-not $Path) { return '' }
    $p = try { [IO.Path]::GetFullPath($Path) } catch { $Path }
    $p.TrimEnd('\', '/')
}
# The registry (from Read-SiteRegistry) as a list of @{ code; name; towers }, sorted by code; $null when there is none. Throws
# "sites registry: ..." on a bad code, a non-object entry or a Tower that is not a path: these readers name it, never guess a Site.
function Get-SiteList($Registry) {
    $raw = $Registry.sites
    if ($null -eq $raw -or -not $raw.Count) { return $null }
    $out = [Collections.Generic.List[object]]::new()
    foreach ($code in @($raw.Keys)) {
        $e = $raw[$code]; $code = [string]$code
        if ($code -cnotmatch $script:SiteCodeRe) { throw "sites registry: '$code' is not a Site code (2-3 capital letters)" }
        if ($e -isnot [Collections.IDictionary]) { throw "sites registry: $code is not an object" }
        $towers = @(); if ($e.Contains('towers') -and $null -ne $e.towers) { $towers = @($e.towers) }
        foreach ($t in $towers) { if ($t -isnot [string] -or -not $t.Trim()) { throw "sites registry: $code has a Tower that is not a path" } }
        $out.Add([pscustomobject]@{ code = $code; name = $(if ($e.name) { [string]$e.name } else { $code }); towers = @($towers | ForEach-Object { ConvertTo-SiteTowerKey $_ }) })
    }
    , @($out | Sort-Object code)
}
# The registry Site that lists this Tower, '' when none (or no registry).
function Find-RegistrySite($Registry, [string]$Tower) {
    if (-not $Registry -or -not $Tower) { return '' }
    $k = ConvertTo-SiteTowerKey $Tower
    foreach ($s in $Registry) { if ($s.towers -icontains $k) { return $s.code } }
    ''
}
# A work order's Site for readers: its own (vars.site), else its Tower's kitchen.repo.json (jobs-lib.ps1 Get-KitchenJobSite), else the
# registry entry that lists its Tower; '' = Unassigned.
function Get-JobSiteForReader($j, $Registry) {
    $s = Get-KitchenJobSite $j
    if ($s) { return $s }
    Find-RegistrySite $Registry (Get-JobTower $j)
}
# Order groups for a list keyed by Site: Sites by code, Unassigned ('') last. Returns the codes in that order.
function Get-SiteGroupOrder([string[]]$Codes) { @(@($Codes | Where-Object { $_ } | Sort-Object -Unique) + @(if (@($Codes | Where-Object { -not $_ }).Count) { '' })) }
# Work orders grouped by Site, in Get-SiteGroupOrder order: a list of @{ site; name; jobs } (each group keeps the orders' own order).
# One group with site '' = no order has a Site: callers then print exactly what they printed before Sites.
function Group-JobsBySite($Jobs, $Registry) {
    $by = [ordered]@{}
    foreach ($j in @($Jobs)) { $s = [string](Get-JobSiteForReader $j $Registry); if (-not $by.Contains($s)) { $by[$s] = [Collections.Generic.List[object]]::new() }; $by[$s].Add($j) }
    foreach ($s in (Get-SiteGroupOrder @($by.Keys))) {
        $n = @($Registry | Where-Object { $_ -and $_.code -ceq $s } | ForEach-Object { $_.name }) | Select-Object -First 1
        [pscustomobject]@{ site = $s; name = [string]$n; jobs = @($by[$s]) }
    }
}

# ---- maxHeavy and share: admission and the start order (TD-7) -----------------------------------------------------------------------------
# maxHeavy: heavy steps at once for that Site, a whole number of 1 or more; the global limit still wins (a Site never gets more than the
# Yard has). share: a number over 0, default 1 (equal share, Q4 = A); Sort-ForStart (start-order.ps1) divides a Site's load by it. Orders
# with no Site weigh 1 and have no Site limit. No registry: no Site limits and equal shares, so admission and the start order are exactly
# as before TD-7. A wrong entry or value is left out (that Site keeps the old rule) and named in problems, which the supervisor writes to
# supervisor.json admission.siteProblems: never silent, never a stopped Yard.
# $Config: anything with a "sites" key: the registry from Read-SiteRegistry (what kitchen.ps1 passes, Get-YardSites) or a settings table.
function Get-KitchenSites($Config) {
    $sites = @{}; $problems = [Collections.Generic.List[string]]::new()
    $reg = if ($Config -is [Collections.IDictionary]) { $Config['sites'] } else { $null }
    if ($null -eq $reg) { return @{ sites = $sites; problems = @() } }
    if ($reg -isnot [Collections.IDictionary]) { return @{ sites = $sites; problems = @("'sites' must be an object keyed by Site code; it was left out") } }
    $known = if ($script:RepoSiteCodes) { @($script:RepoSiteCodes) } else { $null }
    foreach ($code in @($reg.Keys | Sort-Object)) {
        $e = $reg[$code]
        if ([string]$code -cnotmatch '^[A-Z]{2,3}$' -or ($known -and [string]$code -cnotin $known)) { $problems.Add("sites.${code}: not a known Site code; left out"); continue }
        if ($e -isnot [Collections.IDictionary]) { $problems.Add("sites.${code}: must be an object; left out"); continue }
        $mh = $null; $sh = 1.0
        if ($e.Contains('maxHeavy')) {
            $v = $e['maxHeavy']
            if (($v -is [int] -or $v -is [long]) -and $v -ge 1) { $mh = [int]$v } else { $problems.Add("sites.${code}.maxHeavy: '$v' is not a whole number of 1 or more; no Site limit") }
        }
        if ($e.Contains('share')) {
            $v = $e['share']
            if (($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) -and [double]$v -gt 0) { $sh = [double]$v } else { $problems.Add("sites.${code}.share: '$v' is not a number over 0; share 1") }
        }
        $sites[[string]$code] = @{ maxHeavy = $mh; share = $sh }
    }
    @{ sites = $sites; problems = $problems.ToArray() }
}
# Site code -> share weight, for Sort-ForStart (only Sites in the registry; every other group weighs 1)
function Get-KitchenSiteShares($Sites) { $o = @{}; foreach ($c in $Sites.Keys) { $o[$c] = [double]$Sites[$c].share }; $o }
# The Yard's Sites for admission and Stop-work: Get-KitchenSites over the file read by Read-SiteRegistry. A registry that will not read
# gives no Sites (the old rules) and one problem naming it.
function Get-YardSites([string]$KitchenRoot) {
    $r = try { Read-SiteRegistry $KitchenRoot } catch { return @{ sites = @{}; problems = @("the Sites registry cannot be read: $($_.Exception.Message)") } }
    Get-KitchenSites $r
}
