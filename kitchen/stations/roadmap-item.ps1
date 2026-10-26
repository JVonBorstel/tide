# Station: turn one roadmap item into this job's order. Reads the item from the repo's roadmap in its MAIN checkout (kitchen.repo.json
# "roadmap"; kitchen/roadmap-lib.ps1) and writes .kitchen\ITEM.md in the job's worktree: title, why, owns, acceptance, standards and the
# rules, which the plan, build and taster steps read as their goal. Refuses (exit 1) an item that is owner_only (Jordan's own), one whose
# depends_on are not all merged, or one already merged. Safe to re-run (it only rewrites ITEM.md).
#   step: {"station":"roadmap-item","args":{"Repo":"{{repo}}","Item":"{{item}}"}}
param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Item)
$ErrorActionPreference = 'Stop'
$job = $env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'roadmap-item: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$wt = Join-Path $kroot "worktrees\$job"
if (-not (Test-Path -LiteralPath (Join-Path $wt '.kitchen'))) { Write-Output "roadmap-item: no worktree for $job (run the worktree station first)"; exit 2 }
. (Join-Path $PSScriptRoot '..\roadmap-lib.ps1')
try { $rm = Get-Roadmap $Repo; $it = Get-RoadmapItem $rm $Item } catch { Write-Output "roadmap-item: $($_.Exception.Message)"; exit 1 }
if ($it.owner_only) { Write-Output "roadmap-item: REFUSED: $($it.id) is owner_only: it is Jordan's to do, not a cook's"; exit 1 }
$st = @(Get-RoadmapState $rm $kroot) | Where-Object { $_.id -eq $it.id } | Select-Object -First 1
if ($st.state -eq 'merged') { Write-Output "roadmap-item: REFUSED: $($it.id) is already merged"; exit 1 }
if ($st.blockers.Count) { Write-Output "roadmap-item: REFUSED: $($it.id) is blocked by $($st.blockers -join ', ') (not merged yet)"; exit 1 }
$wave = $rm.Waves | Where-Object { $_.id -eq $it.wave } | Select-Object -First 1
$goal = Get-RoadmapGoal $it $wave $wt
Set-Content -LiteralPath (Join-Path $wt '.kitchen\ITEM.md') -Value $goal -Encoding utf8
Write-Output "roadmap-item: $($it.id) ($($it.title)), wave $($it.wave), owns $($it.owns.Count) path(s); order written to .kitchen\ITEM.md"
Write-Output $goal
exit 0
