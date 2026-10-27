# The order in which the supervisor starts pending jobs: orders already under way finish before new ones start, then vars.priority
# (urgent, normal, low; cook.ps1 takes it), then (only with a Sites registry) a fair share between Sites, then oldest first. Dot-sourced
# by kitchen/kitchen.ps1 (its start loop); tests/Test-StartOrder.ps1.
# Why: 10-22 had 93 open orders and 4 slots, started strictly oldest first, so the release demo doc (J225) waited behind research orders
# and half-built orders waited behind new ones. The rank is derived from each job, never a hand-kept list; the clash rule still decides
# who owns a file (oldest wins), so priority never lets two orders build the same file at once.
# Fair share (multi-site design TD-6, section 2.3; Owner's Q4 = A, equal share; PRIORITY FIRST, the Owner's choice of 2026-10-26): with
# orders from two Sites the older Site's queue used to win every slot. Now, inside one band of equal "under way" and priority, the next
# place goes to the Site with the lowest load / share: load = the Site's running heavy steps (-HeavyLoad, counted by the start loop from
# the scaler's weights; without -HeavyLoad, its running orders) plus places already handed out in this list. A tie goes to the Site whose
# next order is oldest. Inside a Site: oldest first, as before. Orders with no Site are one group. Under way and priority come first, so an
# urgent order always goes next, whatever its Site; Sites take turns only among orders of equal priority. Holds (notBefore, the live cap,
# admission, the clash rule) are checked by the start loop on each order in turn, so a held order is skipped and never lends its place.
# Only with a Sites registry (review #11 F3): -Shares is the registry's weights (kitchen.json "sites"; Get-KitchenSiteShares gives every
# registered Site one, default 1). No registry = no weights = no fair share at all, exactly the old order, even when a Tower's own
# kitchen.repo.json names a Site. With one Site, or none, the list is also exactly the old one.
$script:PriorityRank = @{ urgent = 0; normal = 1; low = 2 }
function Get-StartRank($j) {
    $p = [string]$j.vars.priority; $p = if ($p) { $p.ToLowerInvariant() } else { 'normal' }
    $rank = if ($script:PriorityRank.ContainsKey($p)) { $script:PriorityRank[$p] } else { 1 }
    $num = 0; [void][int]::TryParse(([string]$j.id).TrimStart('J'), [ref]$num)
    [pscustomobject]@{ started = $(if ([int]$j.cursor -gt 0) { 0 } else { 1 }); priority = $rank; number = $num }
}
# The order's Site for the fair share: Get-KitchenJobSite (kitchen/jobs-lib.ps1: stored, else from its Tower) when loaded, else its
# vars.site. '' = no Site. A lookup that fails counts as no Site: a display tag never stops the start loop.
function Get-StartSite($j, [bool]$UseKitchen) {
    try {
        if ($UseKitchen) { return [string](Get-KitchenJobSite $j) }
        if ($j.vars -is [Collections.IDictionary]) { [string]$j.vars['site'] } elseif ($j.vars) { [string]$j.vars.site } else { '' }
    } catch { '' }
}
function Sort-ForStart($jobs, $Shares = $null, $HeavyLoad = $null) {
    $sorted = @($jobs | Sort-Object { (Get-StartRank $_).started }, { (Get-StartRank $_).priority }, { (Get-StartRank $_).number })
    if ($sorted.Count -lt 2) { return $sorted }
    if ($Shares -isnot [Collections.IDictionary] -or -not $Shares.Count) { return $sorted }   # no Sites registry: no fair share, the old order
    $useKitchen = [bool](Get-Command Get-KitchenJobSite -ErrorAction Ignore)
    $site = @(foreach ($j in $sorted) { Get-StartSite $j $useKitchen })   # by position in $sorted
    if (@($site | Sort-Object -Unique).Count -lt 2) { return $sorted }   # one Site or none: exactly the old order
    # A Site ranks by load / share: $Shares (TD-7, kitchen.json "sites" share, Site code -> weight) names a weight per Site; a Site it leaves
    # out (Unassigned, or a code not registered) or a bad weight weighs 1 (equal)
    $wt = @{}
    foreach ($s in $site) {
        if ($wt.ContainsKey($s)) { continue }
        $v = 1.0; if ($s -and $Shares.Contains($s)) { try { $v = [double]$Shares[$s] } catch { $v = 1.0 } }
        $wt[$s] = if ($v -gt 0) { $v } else { 1.0 }
    }
    # load: $HeavyLoad (Site code -> running heavy steps, '' = no Site; the start loop counts them with the scaler's weights) when given, else
    # this list's running orders per Site. Each place handed out below adds one.
    $load = @{}; foreach ($s in $site) { $load[$s] = 0.0 }
    if ($HeavyLoad -is [Collections.IDictionary]) { foreach ($s in @($load.Keys)) { if ($HeavyLoad.Contains($s)) { try { $load[$s] = [math]::Max(0.0, [double]$HeavyLoad[$s]) } catch { } } } }
    else { for ($k = 0; $k -lt $sorted.Count; $k++) { if ([string]$sorted[$k].status -eq 'running') { $load[$site[$k]]++ } } }
    # only orders the loop may start take part (pending, or no status); the rest follow in their old order, as the loop skips them
    $fair = @(for ($k = 0; $k -lt $sorted.Count; $k++) { if ([string]$sorted[$k].status -in '', 'pending') { $k } })
    $rest = @(for ($k = 0; $k -lt $sorted.Count; $k++) { if ([string]$sorted[$k].status -notin '', 'pending') { $sorted[$k] } })
    $rank = @(foreach ($j in $sorted) { Get-StartRank $j })
    $out = [Collections.Generic.List[object]]::new(); $i = 0
    while ($i -lt $fair.Count) {
        $r0 = $rank[$fair[$i]]; $queues = [ordered]@{}   # one band: equal under way and priority; per Site, oldest first
        while ($i -lt $fair.Count) {
            $k = $fair[$i]; if ($rank[$k].started -ne $r0.started -or $rank[$k].priority -ne $r0.priority) { break }
            if (-not $queues.Contains($site[$k])) { $queues[$site[$k]] = [Collections.Generic.Queue[int]]::new() }
            $queues[$site[$k]].Enqueue($k); $i++
        }
        $left = 0; foreach ($q in $queues.Values) { $left += $q.Count }
        for (; $left -gt 0; $left--) {
            $best = $null; $bh = $null
            foreach ($s in $queues.Keys) {
                if ($queues[$s].Count -eq 0) { continue }
                $h = $rank[$queues[$s].Peek()]
                if ($null -eq $best) { $best = $s; $bh = $h; continue }
                $a = $load[$s] * $wt[$best]; $b = $load[$best] * $wt[$s]   # (load / share, compared without dividing)
                if ($a -lt $b -or ($a -eq $b -and $h.number -lt $bh.number)) { $best = $s; $bh = $h }   # a tie: the Site whose next order is oldest
            }
            $out.Add($sorted[$queues[$best].Dequeue()]); $load[$best]++
        }
    }
    foreach ($j in $rest) { $out.Add($j) }
    $out.ToArray()
}
