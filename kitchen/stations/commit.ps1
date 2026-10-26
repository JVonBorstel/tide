# Station: commit everything the cooks changed in this job's worktree, and write the full diff to .kitchen\DIFF.patch for the taster.
# No changes = a failed step (the cook did nothing). Safe to re-run: an already-committed change is reported, not doubled.
#   step: {"station":"commit","args":{"Message":"what this change does"}}
#   diff budget: more than -MaxChangedFiles files or -MaxDiffLines added+deleted lines (tests/ not counted, measured against BASE) is rejected, exit 1.
#   A repo's kitchen.repo.json "commitBudget" (read from its main checkout, never the worktree) sets its own limits when no -Max is given,
#   and its "exclude" list (folders or globs, e.g. ["fixtures","evals"]) is not counted either; the station prints what it left out.
#   ownership (a roadmap item, kitchen/roadmap-lib.ps1): -Owns lists the only paths this change may touch (exact paths, folders ending
#   in /, globs); -RoadmapItem B-01 takes them from the item in the main checkout's roadmap (never the worktree's copy) and also allows
#   docs/changes/B-01.md and specs/B-01.md. A job cooked from recipe roadmap-item gets its item's owns even when a caller (repair) passes
#   neither. Any change outside them is REFUSED (exit 1, nothing committed). Without either (and not a roadmap job), nothing changes.
#   scope (kitchen/scope-lib.ps1): files station scope-check widened for this job's item (its trusted record <kitchen>\scope\<job>.json)
#   are accepted too, and so is the roadmap file, only exactly as scope-check wrote it (then it is not counted in the budget either).
#   budget by size: kitchen.repo.json commitBudget.bySize picks the limits for the order's size (its size var, else its roadmap item's).
param([string]$Message = 'kitchen change', [int]$MaxChangedFiles = 4, [int]$MaxDiffLines = 150, [string[]]$Owns = @(), [string]$RoadmapItem = '')
$ErrorActionPreference = 'Stop'
$job = $env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'commit: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$wt = Join-Path $kroot "worktrees\$job"
$baseFile = Join-Path $wt '.kitchen\BASE'
if (-not (Test-Path -LiteralPath $baseFile)) { Write-Output "commit: no worktree for $job (run the worktree station first)"; exit 2 }
$start = (Get-Content -LiteralPath $baseFile -Raw).Trim()
# TD-EH-09: a Resurvey (stations/freshen.ps1) stopped after its merge commit but before the Benchmark move left BASE.next naming the merged
# tip. HEAD has it = the merge landed: finish the move here, or main's changes in that merge count against this change's budget (blamed on
# the Crew). HEAD does not have it = the merge never landed; BASE is right and the note is left for freshen's next start to drop.
$nextFile = "$baseFile.next"
if (Test-Path -LiteralPath $nextFile) {
    $next = "$(Get-Content -LiteralPath $nextFile -Raw)".Trim()
    if ($next -match '^[0-9a-f]{40,64}$') {
        & git -C $wt merge-base --is-ancestor $next HEAD 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Set-Content -LiteralPath $baseFile -Value $next; Remove-Item -LiteralPath $nextFile -Force; $start = $next
            Write-Output "commit: finished an interrupted Resurvey: the Benchmark moves to $($next.Substring(0, 7)) (its merge was already committed)"
        }
    }
}
# the repo's budget is always read (its exclude list applies even when a caller passes both -Max)
. (Join-Path $PSScriptRoot '..\repo-config.ps1')
try { $rcfg = Get-RepoConfig $wt } catch { Write-Output "commit: $($_.Exception.Message)"; exit 1 }   # a broken config: fail closed
. (Join-Path $PSScriptRoot '..\scope-lib.ps1')
$jf = Join-Path $kroot "jobs\$job.json"
$jj = if (Test-Path -LiteralPath $jf) { try { Get-Content -LiteralPath $jf -Raw | ConvertFrom-Json } catch { $null } }
$ritem = $null; $scopeRoadmap = ''
$budgetSkip = @('tests') + @($rcfg.CommitExclude)
if ($rcfg.CommitExclude.Count) { Write-Output "commit: budget excludes: $($budgetSkip -join ', ') (from $($rcfg.Path))" }
# TD-EH-21: a git add that fails (an index lock, a file held open) is said with git's words; unchecked, it ended as "NO CHANGES (the cook
# changed nothing)" and the Crew was blamed. git also exits 1 on every add here only to say the excluded .kitchen folder is ignored (it is,
# in every Yard worktree; the rest is still staged): that notice alone, with no fatal:/error: line, is not a failure. Anything else is.
$addOut = @(& git -C $wt add -A -- . ':(exclude).kitchen' 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
$addCode = $LASTEXITCODE
$addErr = @($addOut | Where-Object { $_ -match '^(fatal|error):' })
if ($addCode -and ($addErr.Count -or -not @($addOut | Where-Object { $_ -match '^The following paths are ignored' }).Count)) {
    Write-Output "commit: git add failed: $(if ($addErr.Count) { ($addErr | Select-Object -First 2) -join ' ' } elseif ($addOut.Count) { ($addOut | Select-Object -First 2) -join ' ' } else { "exit $addCode, no message" })"; exit 1
}
# agent config is never taken from a cook: hooks, permissions, env or an API-key helper in .claude/ (or steering in CLAUDE.md) would
# be loaded by every later cook and by Jordan's own Claude Code after a merge
$agentCfg = @(& git -C $wt diff --cached --name-only $start -- . ':(exclude).kitchen' | Where-Object { $_ -match '(^|/)(\.claude/|\.gemini/|CLAUDE(\.local)?\.md$|GEMINI\.md$|\.mcp\.json$)' })
if ($agentCfg.Count) { & git -C $wt reset -q -- . 2>&1 | Out-Null; Write-Output "commit: REFUSED: a cook changed agent config ($($agentCfg -join ', ')); the kitchen never commits .claude/, .gemini/, CLAUDE.md, GEMINI.md or .mcp.json"; exit 1 }
# GitHub automation is never taken from a cook either: a workflow runs on GitHub with its own token as soon as the PR is pushed, and
# could merge its own PR or push to main (dependabot.yml, CODEOWNERS and templates too: Jordan edits .github/ by hand)
$ghCfg = @(& git -C $wt diff --cached --name-only $start -- . ':(exclude).kitchen' | Where-Object { $_ -match '^\.github/' })
if ($ghCfg.Count) { & git -C $wt reset -q -- . 2>&1 | Out-Null; Write-Output "commit: REFUSED: a cook changed GitHub automation ($($ghCfg -join ', ')); the kitchen never commits .github/ (Jordan edits it by hand)"; exit 1 }
# a roadmap item changes only what it owns: the item comes from the order (or the job's recipe vars, kept outside the worktree), its
# owns from the main checkout's roadmap; a missing or broken roadmap fails closed
$Owns = @($Owns | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # pwsh -File passes a list as one 'a,b'
if (-not $Owns.Count -and -not $RoadmapItem) {
    if ($jj -and $jj.recipe -eq 'roadmap-item') {
        if (-not ($jj.vars -and $jj.vars.item)) { & git -C $wt reset -q -- . 2>&1 | Out-Null; Write-Output "commit: REFUSED: $job is a roadmap order with no item id"; exit 1 }
        $RoadmapItem = [string]$jj.vars.item
    }
}
if ($RoadmapItem -or $Owns.Count) {
    . (Join-Path $PSScriptRoot '..\roadmap-lib.ps1')
    $who = if ($RoadmapItem) { $RoadmapItem } else { 'this change' }
    if ($RoadmapItem) {
        try { $ritem = Get-RoadmapItem (Get-Roadmap $wt) $RoadmapItem } catch { & git -C $wt reset -q -- . 2>&1 | Out-Null; Write-Output "commit: REFUSED: $($_.Exception.Message)"; exit 1 }
        if (-not $Owns.Count) { $Owns = @($ritem.owns) }
        if ($Message -eq $RoadmapItem) { $Message = "$($ritem.id): $($ritem.title)" }
        # what scope-check widened for this item (its kitchen copy, never the worktree's): exactly those files, and the roadmap file
        # only while it is byte for byte what scope-check wrote
        $scope = Read-ScopeRecord $kroot $job
        if ($scope -and [string]$scope.item -ieq $RoadmapItem -and [string]$scope.status -eq 'ok' -and @($scope.widened).Count) {
            $Owns = @($Owns) + @($scope.widened | ForEach-Object { [string]$_ })
            $rmw = Join-Path $wt (([string]$scope.roadmap) -replace '/', '\')
            if ($scope.roadmap -and (Test-Path -LiteralPath $rmw -PathType Leaf) -and (Get-FileHash -LiteralPath $rmw -Algorithm SHA256).Hash -eq [string]$scope.roadmapSha256) { $Owns += [string]$scope.roadmap; $scopeRoadmap = [string]$scope.roadmap }
            Write-Output "commit: scope-check widened $RoadmapItem by: $(@($scope.widened) -join ', ')"
        }
    }
    foreach ($g in $Owns) { $why = Get-RepoGlobProblem $g; if ($why) { & git -C $wt reset -q -- . 2>&1 | Out-Null; Write-Output "commit: REFUSED: owns entry '$g' $why"; exit 1 } }
    $outside = @(& git -C $wt diff --cached --no-renames --name-only $start -- . ':(exclude).kitchen' | Where-Object { $_ -and -not (Test-RoadmapOwned $_ $Owns $RoadmapItem) })
    if ($outside.Count) {
        & git -C $wt reset -q -- . 2>&1 | Out-Null
        Write-Output "commit: REFUSED: changes outside what $who owns: $(($outside | Select-Object -First 10) -join ', ')"
        Write-Output "commit: $who may change only: $($Owns -join ', ')$(if ($RoadmapItem) { ", docs/changes/$RoadmapItem.md, specs/$RoadmapItem.md" }); revert the others"
        exit 1
    }
    Write-Output "commit: every change is inside what $who owns"
}
# the budget for this order's size (kitchen.repo.json commitBudget.bySize, else its flat files/lines = the M default); -Max wins
$sz = Get-OrderSize $jj $ritem
$bud = Get-RepoCommitBudget $rcfg $sz.Size
if ($bud.Files -and -not $PSBoundParameters.ContainsKey('MaxChangedFiles')) { $MaxChangedFiles = $bud.Files }
if ($bud.Lines -and -not $PSBoundParameters.ContainsKey('MaxDiffLines')) { $MaxDiffLines = $bud.Lines }
if ($rcfg.CommitBySize.Count) { Write-Output "commit: size $($sz.Size) (from $($sz.From)): budget $MaxChangedFiles files, $MaxDiffLines lines ($($bud.From))" }
$budgetFiles = 0; $budgetLines = 0
# tests stays a plain pathspec (as before); configured entries use git's glob magic, which matches the config's own glob rules
$skipSpecs = @(":(exclude)tests") + @($rcfg.CommitExclude | ForEach-Object { ":(exclude,glob,icase)$_" })
if ($scopeRoadmap) { $skipSpecs += ":(exclude,literal)$scopeRoadmap"; $budgetSkip += $scopeRoadmap }   # bookkeeping, not code
foreach ($nl in @(& git -C $wt diff --cached --numstat $start -- . ':(exclude).kitchen' @skipSpecs)) {
    if ($nl -match '^(\d+|-)\t(\d+|-)\t') {
        $budgetFiles++
        if ($Matches[1] -ne '-') { $budgetLines += [int]$Matches[1] }
        if ($Matches[2] -ne '-') { $budgetLines += [int]$Matches[2] }
    }
}
$overBudget = $false
if ($budgetFiles -gt $MaxChangedFiles) { Write-Output "commit: DIFF BUDGET EXCEEDED: $budgetFiles files changed (max $MaxChangedFiles)"; $overBudget = $true }
if ($budgetLines -gt $MaxDiffLines) { Write-Output "commit: DIFF BUDGET EXCEEDED: $budgetLines non-test lines changed (max $MaxDiffLines)"; $overBudget = $true }
if ($overBudget) { Write-Output "commit: rejected as scope bloat: keep the change minimal and surgical, revert unrelated edits or split the goal ($($budgetSkip -join ', ') are not counted)"; exit 1 }
if (@(& git -C $wt diff --cached --name-only).Count) {
    $msg = ($Message -replace '[\r\n]+', ' ').Trim(); if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
    # no git hooks: a repo may set core.hooksPath (Demo Project: scripts/hooks), and the hook files in this worktree are the cook's to edit;
    # the kitchen's own commit must never run them (lint.ps1 and the tests do the checking)
    & git -C $wt -c core.hooksPath=/dev/null -c user.name="Jordan's Kitchen" -c user.email='kitchen@localhost' commit -q -m "kitchen ${job}: $msg" 2>&1 | Out-Null
    if ($LASTEXITCODE) { Write-Output 'commit: git commit failed'; exit 1 }
}
$diff = @(& git -C $wt diff --no-renames $start HEAD -- . ':(exclude).kitchen')   # renames off: a moved file shows its full delete and add to the taster
if (-not $diff.Count) { Write-Output 'commit: NO CHANGES (the cook changed nothing)'; exit 1 }
Set-Content -LiteralPath (Join-Path $wt '.kitchen\DIFF.patch') -Value ($diff -join "`n") -Encoding utf8
# the weakened-test check (scripts\weakened-tests.ps1): findings go to WEAKENED.txt and the end of DIFF.patch, where the taster reads them
try { $wo = @(& (Join-Path $PSScriptRoot '..\..\scripts\weakened-tests.ps1') -Dir $wt -Base $start -Out (Join-Path $wt '.kitchen\WEAKENED.txt')) } catch { $wo = @("weakened-tests: could not run: $_") }
Add-Content -LiteralPath (Join-Path $wt '.kitchen\DIFF.patch') -Value (@('', '# weakened-test check') + @($wo | ForEach-Object { "# $_" })) -Encoding utf8
$wo | Where-Object { $_ -match '^(FLAG|weakened-tests: (none|could|cannot|\d))' } | ForEach-Object { "commit: $_" }
& git -C $wt diff --stat $start HEAD -- . ':(exclude).kitchen' | ForEach-Object { "commit: $_" }
Write-Output "commit: change committed on kitchen/$job"
exit 0
