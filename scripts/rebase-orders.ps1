# Re-cook orders that were built on a main since replaced by an unrelated history, so they start fresh from the new main.
# Written for the 2026-10-26 cut-over: brain-monitor's code moved to the public repo tide with a fresh history, and the orders queued
# before it were built on the old private history (the freshen station can never merge them; the pr station must never push them).
#
#   pwsh -File scripts/rebase-orders.ps1 [-Repo <checkout>]                  # dry run: lists the affected orders, changes nothing
#   pwsh -File scripts/rebase-orders.ps1 -Ids J239,J248                       # dry run: the exact steps for these orders
#   pwsh -File scripts/rebase-orders.ps1 -Ids J239,J248 -Apply                # does them (only while the Yard is PAUSED)
#
# Affected (derived, never a hand list): a live order (not done or closed) of this repo whose branch kitchen/<id> shares no history with
# main (kitchen/history-lib.ps1), or that has no branch yet and was created before main's first commit (it was queued for the old main;
# its steps were written from the recipes of that time). Which affected orders to re-cook is a person's choice (-Ids): some goals were
# done another way or wait for a decision (the audit says which). An id that is not affected, running, or has no recipe is refused.
#
# Per order, in this order (each step said in plain words; a failed step stops that order and says what is left):
#   1. a copy of jobs\<id>.json in <kitchen>\pre-tide\jobs\ (never overwritten: a second run adds the time). Outside backups\, which the
#      doctor prunes after 14 days.
#   2. its branch kitchen/<id>, if any, labelled pre-tide/kitchen/<id> (a new branch at the same commit; the old one stays).
#   3. its folder worktrees\<id>, if any, moved to worktrees\pre-tide-<id> (git worktree move): the doctor removes the folders of closed
#      or killed orders by their J<n> name, so the new name keeps the old work and its .kitchen records.
#   4. the new order: kitchen\cook.ps1 with the order's recipe and vars, the same two commands kitchen.ps1 requeue re-cooks with (requeue
#      itself re-cooks only orders before their commit step and resumes the rest on their old branch, which cannot work here). A
#      failed cook moves the folder back and stops: the old order is as it was.
#   5. the old order set aside (kitchen.ps1 kill, only when pending or waiting on Jordan) and closed with -ReplacedBy <new id> (no silent
#      endings: the Ledger links the two).
# Nothing is deleted: no job file, branch, worktree or commit. Each applied step adds a line to <kitchen>\pre-tide\rebase-orders.jsonl.
# Exit: 0 ok (or dry run), 1 a step failed (said), 2 refused (bad id, Yard not paused, unknown repo). Tests: tests/Test-RebaseOrders.ps1.
param(
    [string]$Repo = '', [string[]]$Ids = @(), [switch]$Apply,
    [string]$Why = 're-cooked on the new main after the 2026-10-26 cut-over (old work kept as pre-tide)',
    [string]$KitchenScript = '', [string]$CookScript = ''   # test seams: the kitchen and cook scripts to call
)
$ErrorActionPreference = 'Stop'
$kd = Join-Path $PSScriptRoot '..\kitchen'
if (-not $KitchenScript) { $KitchenScript = Join-Path $kd 'kitchen.ps1' }
if (-not $CookScript) { $CookScript = Join-Path $kd 'cook.ps1' }
. (Join-Path $kd 'repo-config.ps1'); . (Join-Path $kd 'history-lib.ps1')
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
function Say([string]$m) { Write-Output "rebase-orders: $m" }
function Refuse([string]$m) { Say "REFUSED: $m"; exit 2 }
function Full([string]$p) { try { [IO.Path]::GetFullPath($p).TrimEnd('\', '/') } catch { '' } }
if (-not $Repo) { $Repo = Join-Path $PSScriptRoot '..' }
$Repo = Full $Repo
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { Refuse "$Repo is not a git checkout" }
$mainName = Get-RepoDefaultBranch $Repo; if (-not $mainName) { $mainName = 'main' }
$mainSha = "$(& git -C $Repo rev-parse --verify --quiet "refs/heads/$mainName^{commit}" 2>$null)".Trim()
if (-not $mainSha) { Refuse "$Repo has no branch $mainName" }
# main's first commit: an order with no branch yet that is older than this was queued for the main it replaced
$roots = @(& git -C $Repo log --max-parents=0 --format=%cI $mainSha 2>$null | ForEach-Object { [DateTimeOffset]::Parse($_).UtcDateTime } | Sort-Object)
$mainBorn = if ($roots.Count) { $roots[0] } else { [DateTime]::MinValue }
$live = 'pending', 'needs-human', 'quarantined', 'killed', 'failed'

function JobRepo($j) {
    if ($j.vars -and $j.vars.repo) { return Full ([string]$j.vars.repo) }
    foreach ($s in @($j.steps)) { if ($s.args -and $s.args.Repo) { return Full ([string]$s.args.Repo) } }
    ''
}
function JobRecipe($j) { if ([string]$j.recipe -match '^[\w-]{1,40}$') { [string]$j.recipe } elseif ([string]$j.name -match '^([\w-]+):') { $Matches[1] } else { '' } }
# a worktree moves with git (it stays registered); a plain folder is renamed. '' = moved, else git's or the system's words
function Move-Folder([string]$From, [string]$To) {
    if (Test-Path -LiteralPath (Join-Path $From '.git')) { $o = "$(& git -C $Repo worktree move $From $To 2>&1)".Trim(); if ($LASTEXITCODE) { if ($o) { return $o } else { return "git exit $LASTEXITCODE" } }; return '' }
    try { Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop; '' } catch { $_.Exception.Message }
}
function Created($j) { $c = $j.created; if ($c -is [DateTime]) { return $c.ToUniversalTime() }; try { [DateTimeOffset]::Parse([string]$c).UtcDateTime } catch { $null } }

# ---- the affected orders, derived from the job store's live set (kitchen/jobs-lib.ps1, oldest first) and git
. (Join-Path $kd 'jobs-lib.ps1')
$affected = [ordered]@{}
$store = Update-KitchenJobs $kroot 'live' -OnDamaged { param($file, $why) Say "$($file.BaseName): job file unreadable, skipped" }
foreach ($j in @($store.jobs)) {
    $f = [IO.FileInfo]::new((Join-Path $kroot "jobs\$($j.id).json"))
    if ([string]$j.status -in 'done', 'closed' -or (JobRepo $j) -ne $Repo) { continue }
    $id = [string]$j.id; $branch = "kitchen/$id"
    $tip = "$(& git -C $Repo rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>$null)".Trim()
    $reason = ''   # (not $why: PowerShell names are case-blind, and $Why is the close reason)
    if ($tip) { if ((Get-HistoryRelation $Repo $tip $mainSha) -eq 'unrelated') { $reason = "branch $branch is on the old history" } }
    else { $c = Created $j; if ($c -and $c -lt $mainBorn) { $reason = "queued $($c.ToString('yyyy-MM-dd HH:mm'))Z, before main began" } }
    if (-not $reason) { continue }
    $cur = [int]$j.cursor; $n = @($j.steps).Count
    $st = if ($cur -lt $n) { [IO.Path]::GetFileNameWithoutExtension([string]$j.steps[$cur].script) } else { 'end' }
    $affected[$id] = [pscustomobject]@{ id = $id; status = [string]$j.status; step = "$($cur + 1)/$n $st"; why = $reason; recipe = (JobRecipe $j)
        tip = $tip; worktree = (Test-Path -LiteralPath (Join-Path $kroot "worktrees\$id")); file = $f.FullName; job = $j }
}
Say "repo $Repo, $mainName@$($mainSha.Substring(0, 7)) (first commit $($mainBorn.ToString('yyyy-MM-dd HH:mm'))Z); kitchen $kroot"
Say "$($affected.Count) affected order(s) (live, of this repo, built for the old main):"
foreach ($a in $affected.Values) { Say ("  {0,-6} {1,-12} step {2,-18} {3}{4}" -f $a.id, $a.status, $a.step, $a.why, $(if ($a.worktree) { '; has a worktree' } else { '' })) }
if (-not $Ids.Count) { Say 'no -Ids given: nothing to do. Pass -Ids J1,J2 for the orders to re-cook (dry run), then add -Apply.'; exit 0 }

# ---- the chosen orders: checked first, all or nothing
$Ids = @($Ids | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)
foreach ($id in $Ids) {
    if ($id -notmatch '^J\d+$') { Refuse "'$id' is not an order id like J12" }
    if (-not $affected.Contains($id)) { Refuse "$id is not an affected order of this repo (done, closed, running elsewhere, another repo, or already on the new history)" }
    if ($affected[$id].status -notin $live) { Refuse "$id is $($affected[$id].status); only an order that is not running can be re-cooked" }
    if (-not $affected[$id].recipe) { Refuse "$id has no recipe to re-cook from" }
}
if ($Apply -and -not (Test-Path -LiteralPath (Join-Path $kroot 'PAUSED'))) { Refuse 'the Yard is not paused: -Apply runs only while it is (an order must not start halfway through its move)' }

$pre = Join-Path $kroot 'pre-tide'; $log = Join-Path $pre 'rebase-orders.jsonl'
function Note($id, [string]$step, [bool]$ok, [string]$detail) {
    if (-not $Apply) { return }
    New-Item -ItemType Directory -Force -Path $pre | Out-Null
    Add-Content -LiteralPath $log -Value ([ordered]@{ at = [DateTime]::UtcNow.ToString('o'); id = $id; step = $step; ok = $ok; detail = $detail } | ConvertTo-Json -Compress) -Encoding utf8
}
$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN (nothing changes; add -Apply)' }
Say "$mode for $($Ids.Count) order(s): $($Ids -join ', ')"
$bad = 0; $made = @()
foreach ($id in $Ids) {
    $a = $affected[$id]; $j = $a.job; $branch = "kitchen/$id"; $label = "pre-tide/kitchen/$id"
    $wt = Join-Path $kroot "worktrees\$id"; $wtTo = Join-Path $kroot "worktrees\pre-tide-$id"
    Say "$id ($($a.status), step $($a.step); recipe $($a.recipe)):"
    # 1. the job file, copied before anything changes it
    $bk = Join-Path $pre "jobs\$id.json"; if (Test-Path -LiteralPath $bk) { $bk = Join-Path $pre ("jobs\$id-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')) }
    if ($Apply) {
        try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bk) | Out-Null; Copy-Item -LiteralPath $a.file -Destination $bk -ErrorAction Stop }
        catch { Say "  1. FAILED to copy the job file ($($_.Exception.Message)); stopped here, nothing changed"; $bad++; continue }
        Note $id 'backup' $true $bk
    }
    Say "  1. copy the job file to $bk"
    # 2. the old branch labelled (a new name at the same commit)
    if ($a.tip) {
        $has = "$(& git -C $Repo rev-parse --verify --quiet "refs/heads/$label" 2>$null)".Trim()
        if ($has) { Say "  2. $label already exists (at $($has.Substring(0, 7))); left as it is" }
        elseif ($Apply) {
            $o = & git -C $Repo branch $label $a.tip 2>&1
            if ($LASTEXITCODE) { Say "  2. FAILED to label ${branch}: $o. Stopped here; the job file copy is made, nothing else changed"; Note $id 'label' $false "$o"; $bad++; continue }
            Note $id 'label' $true "$label=$($a.tip)"; Say "  2. labelled $branch as $label (at $($a.tip.Substring(0, 7)))"
        } else { Say "  2. label $branch as $label (git branch $label $($a.tip.Substring(0, 7)); kitchen/$id stays too)" }
    } else { Say '  2. no branch yet: nothing to label' }
    # 3. the old folder out of the doctor's reach (it removes closed and killed orders' folders by their J<n> name)
    $moved = $false
    if ($a.worktree) {
        if (Test-Path -LiteralPath $wtTo) { Say "  3. FAILED: $wtTo already exists; stopped here (move the folder by hand, then run this again)"; Note $id 'move' $false "$wtTo exists"; $bad++; continue }
        $isGit = Test-Path -LiteralPath (Join-Path $wt '.git')
        if ($Apply) {
            $o = Move-Folder $wt $wtTo
            if ($o) { Say "  3. FAILED to move ${wt}: $o. Stopped here; the label is made, the order is unchanged"; Note $id 'move' $false $o; $bad++; continue }
            $moved = $true; Note $id 'move' $true $wtTo; Say "  3. moved $wt to $wtTo"
        } else { Say "  3. move $wt to $wtTo ($(if ($isGit) { 'git worktree move' } else { 'a folder rename' }))" }
    } else { Say '  3. no worktree folder: nothing to move' }
    # 4. the new order from the current recipe, with the same vars
    $vars = @{}; if ($j.vars -is [Collections.IDictionary]) { foreach ($k in $j.vars.Keys) { $vars[[string]$k] = [string]$j.vars[$k] } }
    if ($Apply) {
        $global:LASTEXITCODE = 0
        $out = (& $CookScript -Recipe $a.recipe -Vars $vars -Json 2>&1 | Out-String); $cc = $LASTEXITCODE
        $c = $null; try { $c = $out | ConvertFrom-Json } catch { }
        if ($cc -or -not $c -or -not $c.ok -or [string]$c.job -notmatch '^J\d+$') {
            $err = if ($c -and $c.error) { [string]$c.error } else { $out.Trim() }
            Note $id 'cook' $false $err
            $o = if ($moved) { Move-Folder $wtTo $wt } else { '' }
            $back = if (-not $moved) { '' } elseif ($o) { " The folder could NOT be moved back ($o): it is at $wtTo; move it to $wt before the Yard resumes." } else { ' The folder is moved back.' }
            if ($moved) { Note $id 'move-back' (-not $o) $o }
            Say "  4. FAILED to re-cook recipe $($a.recipe): $err. Stopped here; the old order is unchanged.$back"; $bad++; continue
        }
        $new = [string]$c.job; $made += $new; Note $id 'cook' $true $new; Say "  4. re-cooked recipe $($a.recipe) as $new (starts from $mainName when the Yard runs)"
    } else { $new = '<new id>'; Say "  4. re-cook: kitchen/cook.ps1 -Recipe $($a.recipe) -Vars <its $($vars.Count) vars> -Json (a new order that starts from $mainName)" }
    # 5. the old order set aside and closed, naming the order that replaces it
    $steps = @()
    if ($a.status -in 'pending', 'needs-human') { $steps += , @('kill', @('kill', '-Id', $id)) }
    $steps += , @('close', @('close', '-Id', $id, '-ReplacedBy', $new, '-Why', $Why))
    foreach ($s in $steps) {
        if (-not $Apply) { Say "  5. kitchen.ps1 $(@($s[1]) -join ' ')"; continue }
        $o = (& pwsh -NoProfile -NonInteractive -File $KitchenScript @($s[1]) 2>&1 | Out-String).Trim(); $kc = $LASTEXITCODE
        Note $id $s[0] (-not $kc) $o
        if ($kc) { Say "  5. FAILED: kitchen.ps1 $($s[0]) $id said: $o. The new order $new is made; finish by hand: kitchen.ps1 $(@($s[1]) -join ' ')"; $bad++; break }
        Say "  5. kitchen.ps1 $($s[0]) ${id}: $o"
    }
}
if ($Apply) { Say "done: $($Ids.Count - $bad) of $($Ids.Count) re-cooked$(if ($made.Count) { " (new: $($made -join ', '))" }); log $log" }
else { Say "dry run done: $($Ids.Count) order(s) would be re-cooked; nothing changed" }
exit ([int]($bad -gt 0))
