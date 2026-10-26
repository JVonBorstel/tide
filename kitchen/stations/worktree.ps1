# Station: give this job its own git branch and folder, so its changes never touch the real checkout until merge.
# Branch kitchen/<job>, folder <kitchen root>\worktrees\<job>. Safe to re-run (already there = fine).
#   step: {"station":"worktree","args":{"Repo":"C:\\path\\to\\repo"}}
param([Parameter(Mandatory)][string]$Repo)
$ErrorActionPreference = 'Stop'
$job = $env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'worktree: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$wt = Join-Path $kroot "worktrees\$job"; $branch = "kitchen/$job"
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { Write-Output "worktree: not a git repository: $Repo"; exit 2 }
if (Test-Path -LiteralPath (Join-Path $wt '.git')) { Write-Output "worktree: already set up at $wt on $branch"; exit 0 }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $wt) | Out-Null
# the branch can outlive its folder (deleted by hand, or pruned by doctor after the order was closed, then requeued): check the
# branch out again, its commits intact, instead of failing on 'branch already exists'
$had = [bool](& git -C $Repo rev-parse --verify --quiet "refs/heads/$branch" 2>$null)
if ($had) { & git -C $Repo worktree prune 2>&1 | Out-Null; & git -C $Repo worktree add $wt $branch 2>&1 | ForEach-Object { "git: $_" } }
else { & git -C $Repo worktree add -b $branch $wt HEAD 2>&1 | ForEach-Object { "git: $_" } }
if ($LASTEXITCODE) { Write-Output 'worktree: git could not create the worktree'; exit 1 }
# the kitchen's own notes (.kitchen\: plan, diff, test results) never get committed
$exclude = Join-Path (& git -C $Repo rev-parse --git-common-dir | ForEach-Object { if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Repo $_ } }) 'info\exclude'
if (-not (Select-String -LiteralPath $exclude -SimpleMatch '.kitchen/' -Quiet -ErrorAction SilentlyContinue)) { Add-Content -LiteralPath $exclude -Value '.kitchen/' }
New-Item -ItemType Directory -Force -Path (Join-Path $wt '.kitchen') | Out-Null
Set-Content -LiteralPath (Join-Path $wt '.kitchen\BASE') -Value $(if ($had) { & git -C $Repo merge-base HEAD $branch } else { & git -C $wt rev-parse HEAD })   # where this branch started
Set-Content -LiteralPath (Join-Path $wt '.kitchen\REPO') -Value ([IO.Path]::GetFullPath($Repo))
Write-Output "worktree: $wt on branch $branch (from $(& git -C $Repo rev-parse --short HEAD))"
exit 0
