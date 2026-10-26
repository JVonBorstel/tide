# A repo's roadmap, item by item: what is merged, cooking, blocked, ready; and cooking the ready ones (the "map, roadmap, build" method,
# kitchen/BUILDING.md). The roadmap is read from the repo's main checkout (kitchen.repo.json "roadmap"; kitchen/roadmap-lib.ps1).
#   roadmap.ps1 status -Repo C:\path [-Wave W1] [-Json]     every item: merged | cooking Jnn | set-aside Jnn | owner-only | blocked-by B-xx | not-started
#   roadmap.ps1 next   -Repo C:\path -Wave W1 [-Json]       items ready to cook: every depends_on merged, not owner_only, not cooking
#   roadmap.ps1 cook   -Repo C:\path -Wave W1 [-Max 3] [-WhatIf]
#       cooks the ready ones with recipe roadmap-item (cook.ps1), in roadmap order. Never more than -Max of this roadmap's items cooking at
#       once (counting those already cooking), never two whose owns overlap, never approves anything (the merge waits for Jordan as always).
#       -WhatIf prints what it would cook and cooks nothing.
# Merged = a job of recipe roadmap-item for the item is done, or a merge commit on the repo's default branch names the item's id.
# status and next only read. Exit 0 ok, 1 a cook.ps1 call failed, 2 a bad roadmap or a bad call.
param([Parameter(Position = 0)][string]$Action = 'status', [string]$Repo = '', [string]$Wave = '', [int]$Max = 3, [switch]$WhatIf, [switch]$Json)
$ErrorActionPreference = 'Stop'
function Fail([string]$m) { if ($Json) { @{ ok = $false; error = $m } | ConvertTo-Json -Compress } else { Write-Output "ERROR: $m" }; exit 2 }
if ($Action -notin 'status', 'next', 'cook') { Fail "unknown action '$Action' (status, next or cook)" }
if (-not $Repo) { Fail 'give -Repo (the repository whose roadmap to read)' }
if (-not (Test-Path -LiteralPath $Repo -PathType Container)) { Fail "no such folder: $Repo" }
if ($Action -ne 'status' -and -not $Wave) { Fail "$Action needs -Wave (for example -Wave W1)" }
if ($Max -lt 1 -or $Max -gt 10) { Fail '-Max must be 1 to 10' }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
. (Join-Path $PSScriptRoot 'roadmap-lib.ps1')
try { $rm = Get-Roadmap $Repo } catch { Fail $_.Exception.Message }
if ($Wave -and -not ($rm.Waves | Where-Object { $_.id -ieq $Wave })) { Fail "no wave '$Wave' in the roadmap (waves: $(($rm.Waves.id) -join ', '))" }
$all = @(Get-RoadmapState $rm $kroot)
$shown = @($all | Where-Object { -not $Wave -or $_.wave -ieq $Wave })
function Label($s) {
    switch ($s.state) {
        'merged' { 'merged' } 'cooking' { "cooking $($s.job)" } 'set-aside' { "set-aside $($s.job)" } 'owner-only' { "owner-only (Jordan's)" }
        'blocked' { "blocked-by $($s.blockers -join ',')" } default { 'not-started' }
    }
}
function Row($s) { [ordered]@{ id = $s.id; wave = $s.wave; state = $s.state; label = (Label $s); job = $s.job; blockers = @($s.blockers); title = $s.title } }

if ($Action -eq 'status') {
    if ($Json) { @{ ok = $true; repo = $rm.Main; items = @($shown | ForEach-Object { Row $_ }) } | ConvertTo-Json -Depth 5 -Compress; exit 0 }
    foreach ($g in $shown | Group-Object wave) {
        $w = $rm.Waves | Where-Object { $_.id -eq $g.Name } | Select-Object -First 1
        $m = @($g.Group | Where-Object state -eq 'merged').Count
        Write-Output "$($g.Name): $m of $($g.Count) merged"
        foreach ($s in $g.Group) { Write-Output ("  {0,-6} {1,-26} {2}" -f $s.id, (Label $s), $s.title) }
    }
    exit 0
}

$ready = @($shown | Where-Object state -eq 'ready')
if ($Action -eq 'next') {
    if ($Json) { @{ ok = $true; wave = $Wave; items = @($ready | ForEach-Object { Row $_ }) } | ConvertTo-Json -Depth 5 -Compress; exit 0 }
    if (-not $ready.Count) { Write-Output "$($Wave): nothing ready" } else { foreach ($s in $ready) { Write-Output ("{0,-6} {1}" -f $s.id, $s.title) } }
    exit 0
}

# cook: in roadmap order, up to -Max cooking at once, owns never overlapping anything already cooking or picked
$cooking = @($all | Where-Object state -eq 'cooking')
$slots = $Max - $cooking.Count
$picked = @(); $skipped = @()
foreach ($s in $ready) {
    if ($picked.Count -ge $slots) { $skipped += [ordered]@{ id = $s.id; why = "already $($cooking.Count + $picked.Count) cooking (max $Max)" }; continue }
    $clash = @(@($cooking) + @($picked) | Where-Object { Test-RoadmapOwnsOverlap $s.item.owns $_.item.owns } | Select-Object -First 1)
    if ($clash.Count) { $skipped += [ordered]@{ id = $s.id; why = "owns overlap with $($clash[0].id)" }; continue }
    $picked += $s
}
$results = @()
foreach ($s in $picked) {
    if ($WhatIf) { $results += [ordered]@{ id = $s.id; job = ''; would = $true }; continue }
    $out = & (Join-Path $PSScriptRoot 'cook.ps1') -Recipe 'roadmap-item' -Vars @{ repo = $rm.Main; item = $s.id } -Json | Out-String
    $r = try { $out | ConvertFrom-Json } catch { $null }
    if ($r -and $r.ok) { $results += [ordered]@{ id = $s.id; job = [string]$r.job } }
    else { $results += [ordered]@{ id = $s.id; job = ''; error = $(if ($r) { [string]$r.error } else { $out.Trim() }) } }
}
$okCount = @($results | Where-Object { $_.job -or $_.would }).Count
if ($Json) { @{ ok = $true; wave = $Wave; whatIf = [bool]$WhatIf; cooked = @($results); skipped = @($skipped); cooking = @($cooking | ForEach-Object { $_.id }) } | ConvertTo-Json -Depth 5 -Compress }
else {
    foreach ($r in $results) {
        if ($r.would) { Write-Output "would cook $($r.id)" } elseif ($r.job) { Write-Output "cooking $($r.id) as $($r.job)" } else { Write-Output "could not cook $($r.id): $($r.error)" }
    }
    foreach ($k in $skipped) { Write-Output "not now: $($k.id) ($($k.why))" }
    if (-not $results.Count) { Write-Output "$($Wave): nothing to cook" }
}
exit $(if ($results.Count -and $okCount -lt $results.Count) { 1 } else { 0 })
