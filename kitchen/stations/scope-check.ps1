# Station: scope control for a roadmap item, run right after the plan step (recipe roadmap-item), so a plan that cannot land stops in
# a minute instead of after the build. Reads the files the plan will change (.kitchen\PLAN.md, its "## Files to change" list) and
# compares them with the item's owns (the MAIN checkout's roadmap) and the order's commit budget (kitchen.repo.json commitBudget, by size).
#   inside owns: fine.
#   outside owns, owned by no other unmerged roadmap item, named by no running order (kitchen/clash.ps1) and not protected: WIDENED.
#     The file is added to the item's owns in the worktree's roadmap (so the merge carries it), to ITEM.md (so the cook may change it)
#     and to the scope record (.kitchen\SCOPE.json, trusted copy <kitchen>\scope\<job>.json), which the commit station accepts.
#   owned by another unmerged item, named by a running order, protected, or more files than the budget: STOPPED (exit 1), naming both
#     item ids or the order. No plan, no "Files to change" list or a broken roadmap: STOPPED, loudly.
# Every widen and stop is a line in <kitchen>\events.jsonl (scope.widen, scope.stop). Safe to re-run: files already widened stay widened.
#   step: {"station":"scope-check","args":{"Repo":"{{repo}}","Item":"{{item}}"}}
param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Item)
$ErrorActionPreference = 'Stop'
$job = $env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'scope-check: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$wt = Join-Path $kroot "worktrees\$job"
if (-not (Test-Path -LiteralPath (Join-Path $wt '.kitchen'))) { Write-Output "scope-check: no worktree for $job (run the worktree station first)"; exit 2 }
. (Join-Path $PSScriptRoot '..\roadmap-lib.ps1')
. (Join-Path $PSScriptRoot '..\clash.ps1')
. (Join-Path $PSScriptRoot '..\scope-lib.ps1')
$recPath = Get-ScopeRecordPath $kroot $job
function Save-Record($rec) {
    $json = $rec | ConvertTo-Json -Depth 6
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $recPath) | Out-Null
    Set-Content -LiteralPath $recPath -Value $json -Encoding utf8
    Set-Content -LiteralPath (Join-Path $wt '.kitchen\SCOPE.json') -Value $json -Encoding utf8
}
function Stop-Scope([string]$why, [hashtable]$data = @{}) {
    $data.item = $Item; $data.why = $why
    Write-ScopeEvent $kroot 'scope.stop' $job $data
    Save-Record ([ordered]@{ job = $job; item = $Item; status = 'stopped'; why = $why; widened = @(); at = (Get-Date).ToUniversalTime().ToString('o') })
    Write-Output "scope-check: STOPPED: $why"
    exit 1
}

$planPath = Join-Path $wt '.kitchen\PLAN.md'
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { Stop-Scope "no .kitchen\PLAN.md for $job (the plan step writes it); nothing checked" }
try { $planned = @(Get-PlanFiles (Get-Content -LiteralPath $planPath -Raw -Encoding utf8)) } catch { Stop-Scope $_.Exception.Message }
try {
    $cfg = Get-RepoConfig $Repo   # once: Get-Roadmap and Get-RepoProtectedRegex would each ask git again
    if (-not $cfg.Roadmap) { throw "roadmap: $($cfg.Main) has no roadmap (add ""roadmap"": ""map/roadmap.json"" to its kitchen.repo.json)" }
    $rm = Read-Roadmap (Join-Path $cfg.Main ($cfg.Roadmap -replace '/', '\')); $rm | Add-Member -NotePropertyName Main -NotePropertyValue $cfg.Main -Force
    $it = Get-RoadmapItem $rm $Item
    $protRe = @(@('kitchen.repo.json') + @($cfg.Protected) | Select-Object -Unique | ForEach-Object { $r = ConvertTo-RepoGlobRegex ($_.TrimEnd('/')); $r.Substring(0, $r.Length - 1) + '(?:/.*)?$' })   # = Get-RepoProtectedRegex
} catch { Stop-Scope $_.Exception.Message }
$jj = try { Get-Content -LiteralPath (Join-Path $kroot "jobs\$job.json") -Raw | ConvertFrom-Json } catch { $null }
$sz = Get-OrderSize $jj $it
$budget = Get-RepoCommitBudget $cfg $sz.Size
$maxFiles = if ($budget.Files) { $budget.Files } else { 4 }   # 4 = the commit station's own default

# merged items own nothing any more; unmerged ones keep their files (the roadmap's state, kitchen/roadmap-lib.ps1)
$merged = @(Get-RoadmapState $rm $kroot | Where-Object { $_.state -eq 'merged' } | ForEach-Object { $_.id })
# running orders on the same repo: what their goals name (the clash rule's own file finder) and what scope-check widened for them
$mainFull = $rm.Main; $mainOf = @{}
$running = foreach ($o in @(Get-KitchenJobs $kroot -Live)) {   # (orders in play only: kitchen/jobs-lib.ps1, via roadmap-lib)
    if (-not $o -or [string]$o.id -eq $job -or [string]$o.status -notin $script:RoadmapAlive) { continue }
    $r = if ($o.vars -and $o.vars.repo) { [string]$o.vars.repo } elseif (@($o.steps).Count -and $o.steps[0].args -and $o.steps[0].args.Repo) { [string]$o.steps[0].args.Repo } else { '' }
    if (-not $r) { continue }
    if (-not $mainOf.ContainsKey($r)) { $mainOf[$r] = try { Get-RepoMainCheckout $r } catch { '' } }; $rf = $mainOf[$r]
    if ($rf -ine $mainFull) { continue }
    $goal = [string]$o.vars.goal
    $sr = Read-ScopeRecord $kroot ([string]$o.id)
    [pscustomobject]@{ id = [string]$o.id; item = [string]$o.vars["item"]; goal = $goal.Replace('\', '/'); files = @(Get-GoalFiles $goal); widened = @(if ($sr) { $sr.widened }) }
}

$inside = @(); $widen = @(); $stops = @(); $owners = @()
foreach ($f in $planned) {
    if (Test-RoadmapOwned $f $it.owns $it.id) { $inside += $f; continue }
    if ($f -ieq $cfg.Roadmap -or @($protRe | Where-Object { $f -match $_ }).Count) { $stops += "$f is protected (Jordan changes it by hand)"; continue }
    $owner = $rm.Items | Where-Object { $_.id -ne $it.id -and $_.id -notin $merged -and ((Test-RoadmapOwned $f $_.owns '') -or $f -in (Get-RoadmapFragments $_.id)) } | Select-Object -First 1
    if ($owner) { $stops += "$($it.id) plans to change $f, which $($owner.id) owns (not merged yet)"; $owners += $owner.id; continue }
    $lf = $f.ToLowerInvariant()
    $by = $running | Where-Object { $o = $_; ($o.files | Where-Object { $lf -like $_ -or $_ -like $lf }) -or $o.goal -match ('(?i)(?<![\w/.-])' + [regex]::Escape($f) + '(?![\w/-])') -or ($o.widened | Where-Object { $_ -ieq $f }) } | Select-Object -First 1
    if ($by) { $stops += "$($it.id) plans to change $f, which running order $($by.id)$(if ($by.item) { " ($($by.item))" }) names"; $owners += $by.id; continue }
    $widen += $f
}
if ($stops.Count) { Stop-Scope (($stops -join '; ') + '. Split the item or wait for the other one to merge.') @{ files = @($planned); owners = @($owners | Select-Object -Unique); kind = 'owner' } }

# the budget: files the commit station will count (not tests/, not the configured excludes)
$skipRe = @('(?i)^tests(?:/.*)?$') + @($cfg.CommitExclude | ForEach-Object { $r = ConvertTo-RepoGlobRegex ($_.TrimEnd('/')); $r.Substring(0, $r.Length - 1) + '(?:/.*)?$' })
$counted = @($planned | Where-Object { $p = $_; -not @($skipRe | Where-Object { $p -match $_ }).Count })
if ($counted.Count -gt $maxFiles) {
    Stop-Scope "$($it.id) plans $($counted.Count) counted files; size $($sz.Size) (from $($sz.From)) allows $maxFiles ($($budget.From)). Split the item, or order it with size L when kitchen.repo.json commitBudget.bySize.L allows more" @{ files = @($counted); size = $sz.Size; maxFiles = $maxFiles; kind = 'budget' }
}

# widen: the worktree's roadmap (so the merge carries the new owns), edited in place; files a re-run already added are kept as they are
$rmRel = $cfg.Roadmap; $rmFull = Join-Path $wt ($rmRel -replace '/', '\'); $sha = ''
if ($widen.Count) {
    try {
        $wtItem = Get-RoadmapItem (Read-Roadmap $rmFull) $it.id
        $add = @($widen | Where-Object { $w = $_; -not ($wtItem.owns | Where-Object { $_ -ieq $w }) })
        if ($add.Count) {
            $bytes = [IO.File]::ReadAllBytes($rmFull); $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            $old = [IO.File]::ReadAllText($rmFull)
            $new = Add-RoadmapOwnsText $old $it.id $add
            [IO.File]::WriteAllText($rmFull, $new, [Text.UTF8Encoding]::new($bom))
            $chk = Get-RoadmapItem (Read-Roadmap $rmFull) $it.id
            $missing = @($widen | Where-Object { -not (Test-RoadmapOwned $_ $chk.owns '') })
            if ($missing.Count -or $chk.owns.Count -ne $wtItem.owns.Count + $add.Count) { [IO.File]::WriteAllText($rmFull, $old, [Text.UTF8Encoding]::new($bom)); throw "the edited roadmap did not read back as expected (missing: $($missing -join ', ')); put back" }
        }
        $sha = (Get-FileHash -LiteralPath $rmFull -Algorithm SHA256).Hash
    } catch { Stop-Scope "could not widen $($it.id) in $rmRel ($($_.Exception.Message))" @{ files = @($widen); kind = 'widen-failed' } }
    $itemMd = Join-Path $wt '.kitchen\ITEM.md'
    if (Test-Path -LiteralPath $itemMd) {
        $txt = Get-Content -LiteralPath $itemMd -Raw -Encoding utf8
        if ($txt -notmatch '## Owns widened by scope-check') {
            Add-Content -LiteralPath $itemMd -Value (@('', '## Owns widened by scope-check (you may change these too)') + @($widen | ForEach-Object { "- $_" })) -Encoding utf8
        }
    }
    Write-ScopeEvent $kroot 'scope.widen' $job @{ item = $it.id; files = @($widen); roadmap = $rmRel }
}
Save-Record ([ordered]@{ job = $job; item = $it.id; status = 'ok'; size = $sz.Size; sizeFrom = $sz.From; budget = [ordered]@{ files = $budget.Files; lines = $budget.Lines; from = $budget.From }
        inside = @($inside); widened = @($widen); roadmap = $rmRel; roadmapSha256 = $sha; at = (Get-Date).ToUniversalTime().ToString('o') })
Write-Output "scope-check: $($it.id): $($planned.Count) planned file(s), $($inside.Count) inside its owns, $($widen.Count) widened$(if ($widen.Count) { ': ' + ($widen -join ', ') }); size $($sz.Size) ($($sz.From)), budget $maxFiles files ($($budget.From))"
exit 0
