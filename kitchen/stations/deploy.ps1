# Station: put a verified merge live. Runs after verify: if the merge changed anything under pass-app/ (Chef, Jordan's phone app), it
# runs pass-app/update.ps1 from main (syntax check, a trial server against the real kitchen, then the swap; the live server is touched
# only after the trial passes). Otherwise: "deploy: nothing to deploy".
# Never deploys what verify did not pass: the job's own history must show its verify step done (exit 0, the tests ALL PASS on main),
# and the range comes from what the merge step recorded (<kitchen>\results\<job>.merge.json {before, after}), never from the worktree.
# The update command: KITCHEN_CHEF_UPDATE_SCRIPT (tests: a fake), else <repo>\pass-app\update.ps1; a dry run (-DryRun) unless this is
# the real kitchen, or KITCHEN_CHEF_UPDATE_DRYRUN=0/1 says otherwise (the same rules as the supervisor's own Chef update and verify's).
# Safe to re-run: update.ps1 leaves an unchanged server alone.
#   step: {"station":"deploy","args":{"Repo":"{{repo}}"},"timeoutSec":420,"retries":0}
param([Parameter(Mandatory)][string]$Repo)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\github-lib.ps1')
$job = $env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'deploy: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$jj = Read-JsonFile (Join-Path $kroot "jobs\$job.json")
if (-not $jj) { Write-Output "deploy: cannot read job $job; nothing deployed"; exit 1 }

# verify passed: the latest verify step before this one has 'done' as its last outcome (a verify that failed, undid the merge, was cut
# short or is still waiting for Jordan never reads 'done')
$steps = @($jj.steps); $cur = [int]$jj.cursor
$vi = -1; for ($i = [math]::Min($cur, $steps.Count) - 1; $i -ge 0; $i--) { if ([IO.Path]::GetFileNameWithoutExtension([string]$steps[$i].script) -eq 'verify') { $vi = $i; break } }
$last = @(@($jj.history) | Where-Object { $_ -and [int]$_.step -eq $vi }) | Select-Object -Last 1
if ($vi -lt 0 -or -not $last -or [string]$last.outcome -ne 'done') { Write-Output 'deploy: verify did not pass for this order; nothing deployed'; exit 1 }

$mr = Read-JsonFile (Join-Path $kroot "results\$job.merge.json")
if (-not $mr -or [string]$mr.before -notmatch '^[0-9a-f]{40,64}$' -or [string]$mr.after -notmatch '^[0-9a-f]{40,64}$') { Write-Output "deploy: no record of what $job's merge changed; nothing deployed"; exit 1 }
# the merge must still be on main (an undo, or a reset, means what it changed is no longer what runs)
if (-not (Test-Ancestor $Repo ([string]$mr.after) 'HEAD')) { Write-Output "deploy: $job's merge is no longer on the checkout's main; nothing deployed"; exit 1 }
$files = @(& git -C $Repo -c core.quotepath=off diff --name-only --no-renames ([string]$mr.before) ([string]$mr.after) 2>$null | Where-Object { ([string]$_ -replace '\\', '/') -match '^pass-app/' })
if ($LASTEXITCODE) { Write-Output 'deploy: git could not list what the merge changed; nothing deployed'; exit 1 }
if (-not $files.Count) { Write-Output 'deploy: nothing to deploy'; exit 0 }

$upd = if ($env:KITCHEN_CHEF_UPDATE_SCRIPT) { $env:KITCHEN_CHEF_UPDATE_SCRIPT } else { Join-Path $Repo 'pass-app\update.ps1' }
if (-not (Test-Path -LiteralPath $upd)) { Write-Output "deploy: update script not found: $upd"; exit 1 }
$isProd = try { [IO.Path]::GetFullPath($kroot) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen')) } catch { $false }
$dry = if ($env:KITCHEN_CHEF_UPDATE_DRYRUN -eq '1') { $true } elseif ($env:KITCHEN_CHEF_UPDATE_DRYRUN -eq '0') { $false } else { -not $isProd -and -not $env:KITCHEN_CHEF_UPDATE_SCRIPT }
Write-Output "deploy: Chef files changed ($(@($files | Select-Object -First 8) -join ', ')$(if ($files.Count -gt 8) { ', ...' })); updating Chef$(if ($dry) { ' (dry run)' })"
$pwsh = (Get-Process -Id $PID).Path
$bounded = Join-Path $PSScriptRoot '..\..\scripts\run-bounded.ps1'
$uo = & $pwsh -NoProfile -NonInteractive -File $bounded -Script $upd -TimeoutSeconds 240 @(if ($dry) { '-ScriptArgs', '-DryRun' }) 2>&1 | Out-String; $uc = $LASTEXITCODE
$uo = $uo.Trim(); if ($uo.Length -gt 600) { $uo = $uo.Substring($uo.Length - 600) }
$ev = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = $(if ($uc -eq 0) { 'chef.updated' } else { 'chef.update.failed' }); job = $job; after = 'deploy'; files = @($files); detail = $(if ($uo.Length -gt 300) { $uo.Substring($uo.Length - 300) } else { $uo }) }
try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value ($ev | ConvertTo-Json -Compress) -Encoding utf8 } catch { }
if ($uo) { Write-Output $uo }
if ($uc -ne 0) { Write-Output "deploy: Chef update FAILED (exit $uc); the update's own words are above"; exit 1 }
Write-Output 'deploy: Chef updated'
exit 0
