# Tests for kitchen/start-order.ps1 (which pending order the supervisor starts first) and cook.ps1's priority var.
# Pure function checks plus one cook.ps1 refusal; no kitchen root is touched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\kitchen\start-order.ps1')
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function J($id, $cursor = 0, $prio = $null) { $v = @{}; if ($prio) { $v.priority = $prio }; [pscustomobject]@{ id = $id; cursor = $cursor; vars = [pscustomobject]$v } }

$ids = { param($list) (Sort-ForStart $list | ForEach-Object id) -join ' ' }
Check 'oldest first when nothing else differs' ((& $ids @((J 'J12'), (J 'J3'), (J 'J7'))) -eq 'J3 J7 J12')
Check 'numbers sort as numbers, not text (J9 before J10)' ((& $ids @((J 'J10'), (J 'J9'))) -eq 'J9 J10')
Check 'an order already under way starts before a new one' ((& $ids @((J 'J1'), (J 'J5' 4))) -eq 'J5 J1')
Check 'urgent before normal before low among new orders' ((& $ids @((J 'J1' 0 'low'), (J 'J2'), (J 'J3' 0 'urgent'))) -eq 'J3 J2 J1')
Check 'an urgent new order never jumps an order under way' ((& $ids @((J 'J9' 0 'urgent'), (J 'J4' 2))) -eq 'J4 J9')
Check 'priority is case-insensitive; an unknown word counts as normal' ((& $ids @((J 'J2' 0 'bogus'), (J 'J1' 0 'LOW'), (J 'J3' 0 'Urgent'))) -eq 'J3 J2 J1')
Check 'no vars at all is normal' ((Get-StartRank ([pscustomobject]@{ id = 'J1'; cursor = 0 })).priority -eq 1)
Check 'an empty queue sorts to nothing' (@(Sort-ForStart @()).Count -eq 0)
# 1,000 orders rank in well under a tick (the same path for 10 orders or 1,000)
$many = 1..1000 | ForEach-Object { J "J$_" ($_ % 3) @('urgent', 'normal', 'low')[$_ % 3] }
$t = [Diagnostics.Stopwatch]::StartNew(); $sorted = Sort-ForStart $many; $t.Stop()
Check "1,000 orders sort in under 5 s (took $($t.ElapsedMilliseconds) ms)" ($sorted.Count -eq 1000 -and $t.ElapsedMilliseconds -lt 5000)
# cook.ps1 takes priority as a reserved var and refuses anything but urgent, normal or low
$cook = Join-Path $PSScriptRoot '..\kitchen\cook.ps1'
# a private kitchen root, so even a wrongly accepted order could never reach the real queue
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-startorder-' + [guid]::NewGuid().ToString('N'))
$bad = & pwsh -NoProfile -Command "`$env:BRAIN_KITCHEN = '$tmpRoot'; & '$cook' -Recipe improve -Vars @{ goal = 'x'; priority = 'asap' }" 2>&1 | Out-String
Check 'cook.ps1 refuses an unknown priority before filing anything' ($bad -match 'priority must be urgent, normal or low' -and -not (Test-Path (Join-Path $tmpRoot 'jobs')))
Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
$src = Get-Content $cook -Raw
Check 'cook.ps1 lists priority among the reserved vars' ($src -match "priority = 'normal'")
$ks = Get-Content (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1') -Raw
Check 'the supervisor start loop walks Sort-ForStart' ($ks -match 'foreach \(\$j in \(Sort-ForStart \$jobs( \$adm\.shares \$adm\.siteLoad)?\)\)')

# ---- fair share between Sites (multi-site design TD-6, section 2.3; Q4 = A, equal share) ----
# Fair share needs a Sites registry: the start loop passes the registry's weights (Get-KitchenSiteShares; every registered Site has one).
# $on stands for a registry listing GW and TD; no weights = no registry = the old order (review #11 F3).
$on = @{ GW = 1; TD = 1 }
$fids = { param($list, $sh = $on) (Sort-ForStart $list $sh | ForEach-Object id) -join ' ' }
function JS($id, $site, $cursor = 0, $prio = $null, $status = $null) {
    $v = @{}; if ($prio) { $v.priority = $prio }; if ($site) { $v.site = $site }
    $o = [pscustomobject]@{ id = $id; cursor = $cursor; vars = [pscustomobject]$v }; if ($status) { $o | Add-Member status $status }; $o
}
# the start order as it was before TD-6, kept here to prove one Site (or none, or no registry) sorts exactly as before
function Sort-Before($jobs) { @($jobs | Sort-Object { (Get-StartRank $_).started }, { (Get-StartRank $_).priority }, { (Get-StartRank $_).number }) }
$same = { param($list, $sh = $on) ((Sort-ForStart $list $sh | ForEach-Object id) -join ' ') -ceq ((Sort-Before $list | ForEach-Object id) -join ' ') }
$rnd = [Random]::new(624)
$mix = { param($site) 1..300 | ForEach-Object { JS "J$($rnd.Next(1, 5000))" $site ($rnd.Next(0, 3) * $rnd.Next(0, 2)) @($null, 'urgent', 'normal', 'low')[$rnd.Next(0, 4)] @($null, 'pending', 'running', 'waiting-approval')[$rnd.Next(0, 4)] } }
Check 'one Site: exactly the order from before TD-6 (300 mixed orders: under way, priority, status)' (& $same @(& $mix 'TD'))
Check 'no Site at all: exactly the order from before TD-6' (& $same @(& $mix $null))
$three = @(& $mix 'GW') + @(& $mix 'TD') + @(& $mix $null)
Check 'NoRegistry_Mixed: no weights (no registry), 900 orders over GW, TD and no Site: exactly the old order' ((& $same $three $null) -and (& $same $three @{}))
Check 'one Site, small: oldest first as before' ((& $fids @((JS 'J12' 'GW'), (JS 'J3' 'GW'), (JS 'J7' 'GW'))) -eq 'J3 J7 J12')
Check 'two Sites share the starts equally; each Site keeps oldest first' ((& $fids @((JS 'J1' 'GW'), (JS 'J2' 'GW'), (JS 'J3' 'GW'), (JS 'J4' 'GW'), (JS 'J5' 'GW'), (JS 'J6' 'TD'), (JS 'J7' 'TD'), (JS 'J8' 'TD'))) -eq 'J1 J6 J2 J7 J3 J8 J4 J5')
Check 'orders with no Site are one group, sharing equally with each Site' ((& $fids @((JS 'J1' $null), (JS 'J2' $null), (JS 'J3' 'GW'), (JS 'J4' 'GW'), (JS 'J5' 'TD'))) -eq 'J1 J3 J5 J2 J4')
Check 'a Site with nothing running starts next, ahead of an older Site that has 2 running' ((& $fids @((JS 'J1' 'TD'), (JS 'J20' 'TD' 1 $null 'running'), (JS 'J21' 'TD' 1 $null 'running'), (JS 'J9' 'GW'))) -eq 'J9 J1 J20 J21')
Check 'running orders count toward their Site: 2 running TD means GW takes the next two places' ((& $fids @((JS 'J1' 'TD'), (JS 'J2' 'TD'), (JS 'J30' 'TD' 1 $null 'running'), (JS 'J31' 'TD' 1 $null 'running'), (JS 'J8' 'GW'), (JS 'J9' 'GW'))) -eq 'J8 J9 J1 J2 J30 J31')
# PRIORITY FIRST (the Owner's choice, 2026-10-26): urgent work always goes next, whatever its Site; Sites take turns only among orders of equal priority
Check 'PriorityFirst_Urgent: an urgent order from a Site with 2 running starts before a normal one from a Site with nothing running' ((& $fids @((JS 'J1' 'TD'), (JS 'J10' 'GW' 0 'urgent'), (JS 'J40' 'GW' 1 $null 'running'), (JS 'J41' 'GW' 1 $null 'running'))) -eq 'J10 J1 J40 J41')
Check 'PriorityFirst_Low: a low order waits behind every normal one, from any Site' ((& $fids @((JS 'J1' 'TD' 0 'low'), (JS 'J2' 'GW'), (JS 'J3' 'GW'))) -eq 'J2 J3 J1')
Check 'PriorityFirst_AheadOfTurn: an urgent GW order goes ahead of TD''s waiting turn (TD has nothing running, GW has 1), then TD gets its turn' ((& $fids @((JS 'J3' 'TD'), (JS 'J9' 'GW' 0 'urgent'), (JS 'J4' 'GW'), (JS 'J40' 'GW' 1 $null 'running'))) -eq 'J9 J3 J4 J40')
Check 'PriorityFirst_Interleave: inside one priority the Sites still take turns (urgent J9 of TD first and it counts as TD''s place, so GW takes the next two, then TD)' ((& $fids @((JS 'J1' 'GW'), (JS 'J2' 'GW'), (JS 'J3' 'TD'), (JS 'J4' 'TD'), (JS 'J9' 'TD' 0 'urgent'))) -eq 'J9 J1 J2 J3 J4' -and (& $fids @((JS 'J1' 'GW'), (JS 'J2' 'GW'), (JS 'J3' 'TD'), (JS 'J4' 'TD'), (JS 'J8' 'GW' 0 'urgent'), (JS 'J9' 'TD' 0 'urgent'))) -eq 'J8 J9 J1 J3 J2 J4')
Check 'under way wins over fairness: both half-built orders of one Site go before the other Site''s new one' ((& $fids @((JS 'J1' 'GW'), (JS 'J5' 'TD' 2), (JS 'J6' 'TD' 3))) -eq 'J5 J6 J1')
Check 'half-built orders count as places: the other Site leads the next band' ((& $fids @((JS 'J1' 'TD'), (JS 'J2' 'GW'), (JS 'J3' 'GW'), (JS 'J5' 'TD' 2))) -eq 'J5 J2 J1 J3')
# -HeavyLoad (the start loop's running heavy steps per Site) replaces the count of running orders
Check 'Load_Heavy: -HeavyLoad is the load; running orders are not counted again (GW runs a light step: load 0)' (((Sort-ForStart @((JS 'J1' 'TD'), (JS 'J2' 'GW'), (JS 'J40' 'GW' 1 $null 'running')) $on @{ TD = 1 } | ForEach-Object id) -join ' ') -eq 'J2 J1 J40')
Check 'Load_Unassigned: the no-Site group''s load is the '''' key' (((Sort-ForStart @((JS 'J1' $null), (JS 'J2' 'GW')) $on @{ '' = 3 } | ForEach-Object id) -join ' ') -eq 'J2 J1')
Check 'Load_Bad: a text or negative load counts as 0' (((Sort-ForStart @((JS 'J1' 'TD'), (JS 'J2' 'GW')) $on @{ TD = 'x'; GW = -2 } | ForEach-Object id) -join ' ') -eq 'J1 J2')
$out = @(Sort-ForStart $three $on)
$seen = [Collections.Generic.HashSet[int]]::new(); foreach ($j in $out) { [void]$seen.Add([Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($j)) }
Check 'every order comes back exactly once' ($out.Count -eq $three.Count -and $seen.Count -eq $three.Count)
$ok = $true
foreach ($s in 'GW', 'TD', '') {
    $mine = @($out | Where-Object { [string]$_.vars.site -eq $s -and [string]$_.status -in '', 'pending' })
    if ((($mine | ForEach-Object id) -join ' ') -cne ((Sort-Before $mine | ForEach-Object id) -join ' ')) { $ok = $false }
}
Check 'inside each Site the old order (under way, priority, oldest) is kept' $ok
$bandOk = $true; $prev = $null
foreach ($j in @($out | Where-Object { [string]$_.status -in '', 'pending' })) { $r = Get-StartRank $j; $key = $r.started * 10 + $r.priority; if ($null -ne $prev -and $key -lt $prev) { $bandOk = $false }; $prev = $key }
Check 'across Sites, under way then priority still order the whole list' $bandOk
$notStartable = @($three | Where-Object { [string]$_.status -notin '', 'pending' })
Check 'orders the loop will not start (running, waiting) follow, in their old order' ((($out | Where-Object { [string]$_.status -notin '', 'pending' } | ForEach-Object id) -join ' ') -ceq ((Sort-Before $notStartable | ForEach-Object id) -join ' '))
$hj = @(@{ id = 'J1'; cursor = 0; vars = @{ site = 'GW' } }, @{ id = 'J2'; cursor = 0; vars = @{ site = 'GW' } }, @{ id = 'J3'; cursor = 0; status = 'pending'; vars = @{ site = 'TD' } })
Check 'hashtable orders (as the supervisor reads them) share too' (((Sort-ForStart $hj $on | ForEach-Object { $_.id }) -join ' ') -eq 'J1 J3 J2')
Check 'a Site lookup that throws counts as no Site: the old order, no error' ((& { function Get-KitchenJobSite { throw 'boom' }; & $fids @((JS 'J3' 'GW'), (JS 'J1' 'GW'), (JS 'J2' 'TD')) }) -eq 'J1 J2 J3')
$many = 1..1000 | ForEach-Object { JS "J$_" @('GW', 'TD', $null)[$_ % 3] ($_ % 2) @('urgent', 'normal', 'low')[$_ % 3] @($null, 'running')[[int]($_ % 7 -eq 0)] }
$t = [Diagnostics.Stopwatch]::StartNew(); $sorted = Sort-ForStart $many $on; $t.Stop()
Check "1,000 orders over 3 Sites sort in under 5 s (took $($t.ElapsedMilliseconds) ms)" (@($sorted).Count -eq 1000 -and $t.ElapsedMilliseconds -lt 5000)
# with kitchen/jobs-lib.ps1 loaded (as in kitchen.ps1) the Site is Get-KitchenJobSite's: a stored known code, else the Tower's
. (Join-Path $PSScriptRoot '..\kitchen\jobs-lib.ps1')
Check 'with jobs-lib loaded, stored Sites share the starts' ((& $fids @((JS 'J1' 'GW'), (JS 'J2' 'GW'), (JS 'J3' 'TD'))) -eq 'J1 J3 J2')
Check 'with jobs-lib loaded, an unknown code is no Site (one group: the old order)' ((& $fids @((JS 'J1' 'XX'), (JS 'J2' 'XX'), (JS 'J3' $null))) -eq 'J1 J2 J3')
# review #11 F3: a Tower whose own kitchen.repo.json says "site": "TD" (as tide's does) must not reorder anything without a registry.
# J10-J12 are that Tower's orders (Site TD from the file), J13 has no Tower (Unassigned).
$tower = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-startorder-tower-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tower | Out-Null
[IO.File]::WriteAllText((Join-Path $tower 'kitchen.repo.json'), '{ "site": "TD" }')
try {
    $tj = @((JS 'J13' $null), (JS 'J12' $null), (JS 'J11' $null), (JS 'J10' $null))
    foreach ($x in $tj) { if ($x.id -ne 'J13') { $x.vars | Add-Member repo $tower } }
    Check 'TowerSite_Read: the temp Tower''s orders read Site TD from its kitchen.repo.json (the setup is real)' ((Get-KitchenJobSite $tj[3]) -ceq 'TD' -and (Get-KitchenJobSite $tj[0]) -eq '')
    Check 'NoRegistry_J10_J13: no registry (no weights): J10 J11 J12 J13, exactly the old order' (((Sort-ForStart $tj | ForEach-Object id) -join ' ') -eq 'J10 J11 J12 J13')
    Check 'NoRegistry_J10_J13: an empty registry (empty weights): the same old order' (((Sort-ForStart $tj @{} | ForEach-Object id) -join ' ') -eq 'J10 J11 J12 J13')
    Check 'Registry_J10_J13: with a registry the Unassigned group gets its fair turn (J10 J13 J11 J12)' (((Sort-ForStart $tj @{ TD = 1 } | ForEach-Object id) -join ' ') -eq 'J10 J13 J11 J12')
} finally { Remove-Item -Recurse -Force $tower -ErrorAction SilentlyContinue }
Check 'the start loop still checks holds on each order in turn (notBefore, live cap, admission, clash)' ($ks -match '(?s)foreach \(\$j in \(Sort-ForStart \$jobs \$adm\.shares \$adm\.siteLoad\)\).{0,400}notBefore.{0,400}Test-KitchenAdmit.{0,300}Hold-ForClash')

# ---- TD-7: per-Site share weights (kitchen.json "sites" share; default 1 = equal) ----
$two = { @((JS 'J1' 'GW'), (JS 'J2' 'GW'), (JS 'J3' 'GW'), (JS 'J4' 'GW'), (JS 'J5' 'TD'), (JS 'J6' 'TD'), (JS 'J7' 'TD'), (JS 'J8' 'TD')) }
$shareIds = { param($list, $sh) (Sort-ForStart $list $sh | ForEach-Object id) -join ' ' }
Check 'Shares_None: no weights (no registry) is the old order, no turns' ((& $shareIds (& $two) $null) -eq 'J1 J2 J3 J4 J5 J6 J7 J8')
Check 'Shares_AllOne: every weight 1 is the TD-6 order (equal turns)' ((& $shareIds (& $two) @{ GW = 1; TD = 1 }) -eq 'J1 J5 J2 J6 J3 J7 J4 J8')
Check 'Shares_Empty: an empty weights table is no registry: the old order' ((& $shareIds (& $two) @{}) -eq (& $shareIds (& $two) $null))
Check 'Shares_GW2: GW with share 2 gets two places for each TD place' ((& $shareIds (& $two) @{ GW = 2; TD = 1 }) -eq 'J1 J5 J2 J3 J6 J4 J7 J8')
Check 'Shares_Unlisted: a Site the weights leave out weighs 1' ((& $shareIds (& $two) @{ GW = 1 }) -eq (& $shareIds (& $two) $on))
Check 'Shares_Bad: a 0, negative or text weight counts as 1' ((& $shareIds (& $two) @{ GW = 0; TD = 'x' }) -eq (& $shareIds (& $two) $on) -and (& $shareIds (& $two) @{ GW = -3 }) -eq (& $shareIds (& $two) $on))
Check 'Shares_RunningDivided: TD running 2 with share 2 ranks like 1 running at share 1 (tie -> oldest: TD J7 first; unweighted, GW would lead)' ((& $shareIds @((JS 'J7' 'TD'), (JS 'J30' 'TD' 1 $null 'running'), (JS 'J31' 'TD' 1 $null 'running'), (JS 'J8' 'GW'), (JS 'J32' 'GW' 1 $null 'running')) @{ TD = 2 }) -eq 'J7 J8 J30 J31 J32' -and (& $shareIds @((JS 'J7' 'TD'), (JS 'J30' 'TD' 1 $null 'running'), (JS 'J31' 'TD' 1 $null 'running'), (JS 'J8' 'GW'), (JS 'J32' 'GW' 1 $null 'running')) $on) -eq 'J8 J7 J30 J31 J32')
$big2 = @(& $mix 'GW') + @(& $mix 'TD') + @(& $mix $null)
Check 'Shares_AllOne_Big: 900 mixed orders over 3 groups sort the same with all weights 1 as with only one Site listed' (((Sort-ForStart $big2 @{ GW = 1; TD = 1 } | ForEach-Object id) -join ' ') -ceq ((Sort-ForStart $big2 @{ GW = 1 } | ForEach-Object id) -join ' '))
Check 'the start loop passes the registry weights and the heavy load' ($ks -match 'Sort-ForStart \$jobs \$adm\.shares \$adm\.siteLoad')
Check 'the start loop counts only heavy steps, per Site, and only with a registry' ($ks -match '(?s)\$siteLoad = @\{\}; if \(\$reg\.sites\.Count\).{0,200}\.light\)')
Write-Host "StartOrder tests: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
