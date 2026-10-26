# Dot-source: a repo's machine-readable roadmap (the "map, roadmap, build" method; kitchen/BUILDING.md "Map, roadmap, build").
# A repo opts in with "roadmap": "map/roadmap.json" in its kitchen.repo.json. The roadmap is read from the MAIN checkout, never from a
# job's worktree (the same reason as kitchen.repo.json: a cook edits the worktree and could widen what its own item owns).
# Format: { "waves": [ { "id": "W1", "goal": "...", "items": [ { "id": "B-01", "title": "...", "why": "...", "depends_on": ["B-00"],
#   "owns": ["src/a.py", "src/b/", "tests/**/test_b01*.py"], "acceptance": ["B01-1: ..."], "controls": [], "inventory_ids": [],
#   "standards": [], "size": "M", "owner_only": false } ] } ] }
# Required: waves[].id, waves[].goal, waves[].items, and per item id, title, why, depends_on, owns (1+), acceptance (1+). Optional:
# controls, inventory_ids, standards (lists of strings), size (short string), owner_only (true/false). Anything wrong is an ERROR that
# names the file and the item, never a guess (fail closed). Unknown keys are ignored.
# Optional Site block (multi-site design TD-1): "site": { "code": "GW", "name": "Demo Project", "id_prefix": "B" }. code: 2-3 capital
# letters; name: optional text; id_prefix: the STORED prefix of Floor ids when it differs from the code (absent = the code). It changes
# displayed words only (Get-SiteDisplayId: B-42 shows as GW-42); stored ids, paths and events stay as they are. No block = as before.
. (Join-Path $PSScriptRoot 'repo-config.ps1')
if (-not (Test-Path function:Get-KitchenJobs)) { . (Join-Path $PSScriptRoot 'jobs-lib.ps1') }

$script:RoadmapIdRe = '^[A-Za-z][A-Za-z0-9]{0,5}-\d{1,4}$'
$script:RoadmapAlive = @('pending', 'running', 'waiting-approval', 'needs-human')   # job states that mean "cooking"
$script:RoadmapSetAside = @('failed', 'quarantined')                              # waits for Jordan (close or recook) before it is tried again

function Get-RoadmapProp($o, [string]$name) {
    if ($o -isnot [pscustomobject]) { return $null }
    $p = $o.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if ($p) { , $p.Value } else { $null }
}

# Reads and validates one roadmap file. Returns @{ Path; Waves = @(@{ id; goal; items }); Items = ordered list; ById = dictionary }.
function Read-Roadmap([string]$Path) {
    $bad = { param($msg) throw "roadmap ($Path): $msg" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { & $bad 'file not found' }
    try { $j = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop } catch { & $bad "is not valid JSON ($($_.Exception.Message))" }
    if ($j -isnot [pscustomobject]) { & $bad 'must be a JSON object' }
    $list = { param($v) ($null -ne $v -and $v -isnot [string] -and ($v -is [array] -or $v -is [Collections.IList])) }
    $strs = { param($v, [string]$what, [int]$min, [int]$max)
        if (-not (& $list $v)) { & $bad "$what must be a list" }
        $a = @($v); if ($a.Count -lt $min -or $a.Count -gt $max) { & $bad "$what must have $min to $max entries" }
        foreach ($s in $a) { if ($s -isnot [string] -or [string]::IsNullOrWhiteSpace($s) -or $s.Length -gt 2000) { & $bad "$what entries must be non-empty strings" } }
        , @($a | ForEach-Object { $_.Trim() }) }
    $site = Read-RoadmapSite (Get-RoadmapProp $j 'site') $bad
    $waves = Get-RoadmapProp $j 'waves'
    if (-not (& $list $waves) -or @($waves).Count -lt 1 -or @($waves).Count -gt 100) { & $bad "'waves' must be a list of 1 to 100 waves" }
    $byId = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $waveIds = @{}; $outWaves = @(); $items = [Collections.Generic.List[object]]::new()
    foreach ($w in @($waves)) {
        if ($w -isnot [pscustomobject]) { & $bad 'each wave must be an object' }
        $wid = Get-RoadmapProp $w 'id'
        if ($wid -isnot [string] -or $wid -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$') { & $bad "a wave id must be 1-20 letters, digits, '.', '_' or '-' (got '$wid')" }
        if ($waveIds.ContainsKey($wid.ToLowerInvariant())) { & $bad "wave '$wid' appears twice" }; $waveIds[$wid.ToLowerInvariant()] = $true
        $goal = Get-RoadmapProp $w 'goal'
        if ($goal -isnot [string] -or [string]::IsNullOrWhiteSpace($goal)) { & $bad "wave '$wid' needs a 'goal' (text)" }
        $wi = Get-RoadmapProp $w 'items'
        if (-not (& $list $wi)) { & $bad "wave '$wid' needs 'items' (a list)" }
        $wItems = @()
        foreach ($it in @($wi)) {
            if ($it -isnot [pscustomobject]) { & $bad "wave '$wid': each item must be an object" }
            $id = Get-RoadmapProp $it 'id'
            if ($id -isnot [string] -or $id -notmatch $script:RoadmapIdRe) { & $bad "wave '$wid': item id '$id' must look like B-01" }
            if ($byId.ContainsKey($id)) { & $bad "item '$id' appears twice" }
            $where = "item '$id'"
            foreach ($k in 'title', 'why') {
                $v = Get-RoadmapProp $it $k
                if ($v -isnot [string] -or [string]::IsNullOrWhiteSpace($v) -or $v.Length -gt 2000) { & $bad "$where needs '$k' (non-empty text, at most 2000 characters)" }
            }
            $deps = Get-RoadmapProp $it 'depends_on'
            if ($null -eq $deps) { & $bad "$where needs 'depends_on' (a list, [] when none)" }
            $deps = & $strs $deps "$where 'depends_on'" 0 100
            $owns = Get-RoadmapProp $it 'owns'
            if ($null -eq $owns) { & $bad "$where needs 'owns' (the files it may change)" }
            $owns = & $strs $owns "$where 'owns'" 1 200
            $ownsN = foreach ($g in $owns) { $why = Get-RepoGlobProblem $g; if ($why) { & $bad "$where 'owns' entry '$g' $why" }; ConvertTo-RepoGlob $g }
            $acc = Get-RoadmapProp $it 'acceptance'
            if ($null -eq $acc) { & $bad "$where needs 'acceptance' (the tests that prove it is done)" }
            $acc = & $strs $acc "$where 'acceptance'" 1 100
            $opt = @{}
            foreach ($k in 'controls', 'inventory_ids', 'standards') {
                $v = Get-RoadmapProp $it $k
                $opt[$k] = if ($null -eq $v) { @() } else { & $strs $v "$where '$k'" 0 200 }
            }
            $size = Get-RoadmapProp $it 'size'
            if ($null -ne $size -and ($size -isnot [string] -or $size.Length -gt 10)) { & $bad "$where 'size' must be short text such as S, M or L" }
            $oo = Get-RoadmapProp $it 'owner_only'
            if ($null -ne $oo -and $oo -isnot [bool]) { & $bad "$where 'owner_only' must be true or false" }
            $o = [pscustomobject]@{ id = $id; wave = $wid; title = $it.title.Trim(); why = $it.why.Trim(); depends_on = @($deps); owns = @($ownsN | Select-Object -Unique)
                acceptance = @($acc); controls = @($opt.controls); inventory_ids = @($opt.inventory_ids); standards = @($opt.standards)
                size = $(if ($size) { $size } else { '' }); owner_only = [bool]$oo }
            $byId[$id] = $o; $items.Add($o); $wItems += $o
        }
        $outWaves += [pscustomobject]@{ id = $wid; goal = $goal.Trim(); items = @($wItems) }
    }
    foreach ($o in $items) {
        foreach ($d in $o.depends_on) {
            if ($d -ieq $o.id) { & $bad "item '$($o.id)' depends on itself" }
            if (-not $byId.ContainsKey($d)) { & $bad "item '$($o.id)' depends on '$d', which is not in the roadmap" }
        }
    }
    # a dependency cycle would leave every item in it blocked forever: refuse the file instead
    $mark = @{}
    $visit = { param($id, $path)
        if ($mark[$id] -eq 2) { return }
        if ($mark[$id] -eq 1) { & $bad "dependency cycle: $(($path + $id) -join ' -> ')" }
        $mark[$id] = 1
        foreach ($d in $byId[$id].depends_on) { & $visit $byId[$d].id (@($path) + $id) }
        $mark[$id] = 2 }
    foreach ($o in $items) { & $visit $o.id @() }
    [pscustomobject]@{ Path = $Path; Waves = @($outWaves); Items = @($items); ById = $byId; Site = $site }
}

# The optional 'site' block, validated: $null when absent, else @{ code; name; id_prefix }. $Bad throws the file's error.
function Read-RoadmapSite($Block, [scriptblock]$Bad) {
    if ($null -eq $Block) { return $null }
    if ($Block -isnot [pscustomobject]) { & $Bad "'site' must be an object such as { ""code"": ""GW"" }" }
    $code = Get-RoadmapProp $Block 'code'
    if ($code -isnot [string] -or $code -cnotmatch '^[A-Z]{2,3}$') { & $Bad "'site.code' must be 2 or 3 capital letters such as GW (got '$code')" }
    $name = Get-RoadmapProp $Block 'name'
    if ($null -ne $name -and ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 60)) { & $Bad "'site.name' must be non-empty text, at most 60 characters" }
    $pre = Get-RoadmapProp $Block 'id_prefix'
    if ($null -ne $pre -and ($pre -isnot [string] -or $pre -notmatch '^[A-Za-z][A-Za-z0-9]{0,5}$')) { & $Bad "'site.id_prefix' must be the stored id prefix such as B (got '$pre')" }
    [pscustomobject]@{ code = $code; name = $(if ($name) { $name.Trim() } else { $code }); id_prefix = $(if ($pre) { $pre } else { $code }) }
}

# The id people see for a stored Floor id. $Site: a roadmap (its .Site) or a site block from Read-RoadmapSite. With a site, an id
# with the Site's stored prefix shows the Site code: B-42 -> GW-42 (digits as stored). Anything else is returned unchanged: no site
# block, an id with another prefix (NN-3), or text that is not an id. Display only: never store or match on what this returns.
function Get-SiteDisplayId($Site, [string]$Id) {
    if ($Site -and $Site.PSObject.Properties['Waves']) { $Site = $Site.Site }
    if (-not $Site -or -not $Site.code -or $Id -notmatch $script:RoadmapIdRe) { return $Id }
    $dash = $Id.IndexOf('-')
    if ($Id.Substring(0, $dash) -ine $Site.id_prefix) { return $Id }
    "$($Site.code)$($Id.Substring($dash))"
}

# The roadmap that governs <Dir> (a main checkout or any worktree of it), from the main checkout's kitchen.repo.json "roadmap".
function Get-Roadmap([string]$Dir) {
    $cfg = Get-RepoConfig $Dir
    if (-not $cfg.Roadmap) { throw "roadmap: $($cfg.Main) has no roadmap (add ""roadmap"": ""map/roadmap.json"" to its kitchen.repo.json)" }
    $rm = Read-Roadmap (Join-Path $cfg.Main ($cfg.Roadmap -replace '/', '\'))
    $rm | Add-Member -NotePropertyName Main -NotePropertyValue $cfg.Main -Force
    $rm
}

function Get-RoadmapItem($Roadmap, [string]$Id) {
    if ($Id -notmatch $script:RoadmapIdRe) { throw "roadmap: '$Id' is not an item id (like B-01)" }
    if (-not $Roadmap.ById.ContainsKey($Id)) { throw "roadmap: no item '$Id' in $($Roadmap.Path)" }
    $Roadmap.ById[$Id]
}

# The two notes every item may always write: its change fragment and its spec.
function Get-RoadmapFragments([string]$Id) { if ($Id) { @("docs/changes/$Id.md", "specs/$Id.md") } else { @() } }

# The order for the cooks, built from the item (what ITEM.md says). $Dir: where to look for docs/STANDARDS.md and docs/ROADMAP.md.
function Get-RoadmapGoal($Item, $Wave = $null, [string]$Dir = '') {
    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine("# $($Item.id): $($Item.title)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Roadmap item $($Item.id), wave $($Item.wave)$(if ($Item.size) { ", size $($Item.size)" }). Build this item and nothing more, as one pull request.")
    if ($Wave) { [void]$sb.AppendLine(''); [void]$sb.AppendLine("## Wave goal"); [void]$sb.AppendLine($Wave.goal) }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Why'); [void]$sb.AppendLine($Item.why)
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Owns (the ONLY files this change may create, edit or delete; the commit station refuses anything else)')
    foreach ($o in $Item.owns) { [void]$sb.AppendLine("- $o") }
    foreach ($f in Get-RoadmapFragments $Item.id) { [void]$sb.AppendLine("- $f (always allowed for this item)") }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Acceptance (each one met, each one proved by a test)')
    foreach ($a in $Item.acceptance) { [void]$sb.AppendLine("- $a") }
    if ($Item.depends_on.Count) { [void]$sb.AppendLine(''); [void]$sb.AppendLine("## Builds on (already merged)"); [void]$sb.AppendLine(($Item.depends_on -join ', ')) }
    foreach ($k in @(@('standards', 'Standards'), @('controls', 'Controls'), @('inventory_ids', 'Inventory'))) {
        $v = @($Item.($k[0])); if ($v.Count) { [void]$sb.AppendLine(''); [void]$sb.AppendLine("## $($k[1])"); [void]$sb.AppendLine(($v -join ', ')) }
    }
    $rules = @()
    $std = $Dir -and (Test-Path -LiteralPath (Join-Path $Dir 'docs\STANDARDS.md'))
    $rmd = $Dir -and (Test-Path -LiteralPath (Join-Path $Dir 'docs\ROADMAP.md'))
    $rules += if ($std -or -not $Dir) { 'Follow docs/STANDARDS.md (if present), including the standards named above.' } else { 'Follow the repo''s own rules (AGENTS.md or CLAUDE.md).' }
    $rules += if ($rmd -or -not $Dir) { 'Meet the definition of done (DOD) in docs/ROADMAP.md (if present).' } else { 'Done means every acceptance line above is met and tested.' }
    $rules += "Write docs/changes/$($Item.id).md: what changed and why, for the wave's fold-in."
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Rules')
    foreach ($r in $rules) { [void]$sb.AppendLine("- $r") }
    $sb.ToString()
}

# Is one changed path (repo-relative, / or \) inside what the item owns? Owns entries: exact paths, folders ending in /, globs.
function Test-RoadmapOwned([string]$Path, [string[]]$Owns, [string]$Item = '') {
    $p = ConvertTo-RepoGlob $Path
    foreach ($f in Get-RoadmapFragments $Item) { if ($p -ieq $f) { return $true } }
    foreach ($o in $Owns) { if ($p -match (ConvertTo-RepoGlobRegex $o)) { return $true } }
    $false
}

# Could two owns lists touch the same file? Conservative: two patterns overlap when one's fixed start is a prefix of the other's.
function Test-RoadmapOwnsOverlap([string[]]$A, [string[]]$B) {
    $stem = { param($g) $g = ConvertTo-RepoGlob $g; $i = $g.IndexOfAny([char[]]'*?'); if ($i -ge 0) { $g.Substring(0, $i) } elseif ($g.EndsWith('/')) { $g } else { $null } }
    foreach ($a in $A) {
        foreach ($b in $B) {
            $sa = & $stem $a; $sb = & $stem $b
            if ($null -eq $sa -and $null -eq $sb) { if ((ConvertTo-RepoGlob $a) -ieq (ConvertTo-RepoGlob $b)) { return $true }; continue }
            if ($null -eq $sa) { if ((ConvertTo-RepoGlob $a) -match (ConvertTo-RepoGlobRegex $b)) { return $true }; continue }
            if ($null -eq $sb) { if ((ConvertTo-RepoGlob $b) -match (ConvertTo-RepoGlobRegex $a)) { return $true }; continue }
            if ($sa.StartsWith($sb, [StringComparison]::OrdinalIgnoreCase) -or $sb.StartsWith($sa, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    $false
}

# The ids proven merged on the repo's default branch: the item's change note docs/changes/<id>.md was added there (the roadmap
# standard: every item ships one). The only proof: a merge text or commit subject that merely names an id (a map edit "B-42 owns ...")
# and a kitchen job marked done are claims, not proof. The tree, not history: a revert that removes the note un-merges the item (so a
# wave's notes must stay in docs/changes/ on main, also after the wave is closed).
function Get-RoadmapMergedIds($Roadmap) {
    $out = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $br = Get-RepoDefaultBranch $Roadmap.Main
    if (-not $br) { return , $out }
    $changes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @(& git -C $Roadmap.Main ls-tree --name-only "${br}:docs/changes" 2>$null)) { if ($f -match '^(.+)\.md$') { [void]$changes.Add($Matches[1]) } }
    foreach ($it in $Roadmap.Items) { if ($changes.Contains($it.id)) { [void]$out.Add($it.id) } }
    , $out
}

# The kitchen's roadmap-item orders for this repo: id -> list of @{ id; status }.
function Get-RoadmapJobs($Roadmap, [string]$KitchenRoot) {
    $by = @{}
    $main = [IO.Path]::GetFullPath($Roadmap.Main).TrimEnd('\', '/')
    foreach ($j in (Get-KitchenJobs $KitchenRoot -WithArchive)) {   # (archived orders as their summary: recipe, vars.repo, vars.item, status)
        if (-not $j -or $j.recipe -ne 'roadmap-item' -or -not $j.vars -or -not $j.vars['item']) { continue }
        $r = [string]$j.vars.repo; if (-not $r) { continue }
        $rf = try { (Get-RepoMainCheckout $r) } catch { try { [IO.Path]::GetFullPath($r).TrimEnd('\', '/') } catch { '' } }
        if ($rf -ine $main) { continue }
        $k = ([string]$j.vars['item']).ToUpperInvariant()
        if (-not $by.ContainsKey($k)) { $by[$k] = @() }
        $by[$k] += [pscustomobject]@{ id = [string]$j.id; status = [string]$j.status }
    }
    $by
}

# Every item's state: merged (proven on main, Get-RoadmapMergedIds; also what unblocks a dependant) | cooking (job) | set-aside (job) | owner-only | blocked (by) | ready. Ordered as in the file.
function Get-RoadmapState($Roadmap, [string]$KitchenRoot) {
    $merged = Get-RoadmapMergedIds $Roadmap
    $jobs = Get-RoadmapJobs $Roadmap $KitchenRoot
    foreach ($it in $Roadmap.Items) {
        $js = @($jobs[$it.id.ToUpperInvariant()] | Where-Object { $_ })
        $alive = @($js | Where-Object { $_.status -in $script:RoadmapAlive })
        $aside = @($js | Where-Object { $_.status -in $script:RoadmapSetAside })
        $blockers = @($it.depends_on | Where-Object { -not $merged.Contains($_) })
        $state = if ($merged.Contains($it.id)) { 'merged' } elseif ($alive.Count) { 'cooking' } elseif ($aside.Count) { 'set-aside' } elseif ($it.owner_only) { 'owner-only' } elseif ($blockers.Count) { 'blocked' } else { 'ready' }
        $job = if ($alive.Count) { $alive[-1].id } elseif ($aside.Count -and $state -eq 'set-aside') { $aside[-1].id } else { '' }
        [pscustomobject]@{ id = $it.id; wave = $it.wave; title = $it.title; state = $state; job = $job; blockers = $blockers; item = $it }
    }
}
