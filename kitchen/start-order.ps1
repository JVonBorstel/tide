# The order in which the supervisor starts pending jobs: orders already under way finish before new ones start, then vars.priority
# (urgent, normal, low; cook.ps1 takes it), then oldest first. Dot-sourced by kitchen/kitchen.ps1 (its start loop); tests/Test-StartOrder.ps1.
# Why: 10-22 had 93 open orders and 4 slots, started strictly oldest first, so the release demo doc (J225) waited behind research orders
# and half-built orders waited behind new ones. The rank is derived from each job, never a hand-kept list; the clash rule still decides
# who owns a file (oldest wins), so priority never lets two orders build the same file at once.
$script:PriorityRank = @{ urgent = 0; normal = 1; low = 2 }
function Get-StartRank($j) {
    $p = [string]$j.vars.priority; $p = if ($p) { $p.ToLowerInvariant() } else { 'normal' }
    $rank = if ($script:PriorityRank.ContainsKey($p)) { $script:PriorityRank[$p] } else { 1 }
    $num = 0; [void][int]::TryParse(([string]$j.id).TrimStart('J'), [ref]$num)
    [pscustomobject]@{ started = $(if ([int]$j.cursor -gt 0) { 0 } else { 1 }); priority = $rank; number = $num }
}
function Sort-ForStart($jobs) {
    @($jobs | Sort-Object { (Get-StartRank $_).started }, { (Get-StartRank $_).priority }, { (Get-StartRank $_).number })
}
