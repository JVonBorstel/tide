# Station: merge the real checkout's current branch into this job's worktree branch, so the tests and the taster see the freshened code.
# Refuses when the worktree has uncommitted tracked changes. On a conflict a cook (agent-step, ai: true in the recipe) resolves the markers
# keeping both sides; no markers, no edits outside the conflict and lint must hold, then the merge is committed. Otherwise it aborts
# cleanly (nothing half-merged) and fails naming the files.
# Writes only in the job's worktree, its branch and .kitchen\ (BASE and DIFF.patch are reset so the diff shows only this job's change;
# BASE.next holds the tip while the move is under way, TD-EH-09).
# Safe to re-run: merging a tip that is already in the branch does nothing.
# A branch that shares no history with main (main was replaced, as in the 2026-10-26 cut-over to tide) is held for Jordan (exit 10)
# with the way out (re-cook or port), nothing changed (kitchen/history-lib.ps1).
#   step: {"station":"freshen","args":{"Repo":"C:\\path\\to\\repo"}}
param([Parameter(Mandatory)][string]$Repo, [string]$Order = '', [string]$Supplier = '', [switch]$Private, [switch]$Public, [int]$MaxTurns = 40, [double]$MaxBudgetUsd = 3, [string]$Agent = '')
$ErrorActionPreference = 'Stop'
$clock = [Diagnostics.Stopwatch]::StartNew()
if (-not $Agent) { $Agent = Join-Path $PSScriptRoot '..\agent-step.ps1' }   # -Agent: the test seam for a fake cook
$job = $env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'freshen: no kitchen job in the environment'; exit 2 }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$wt = Join-Path $kroot "worktrees\$job"; $branch = "kitchen/$job"
$baseFile = Join-Path $wt '.kitchen\BASE'
if (-not (Test-Path -LiteralPath $baseFile)) { Write-Output "freshen: no worktree for $job (run the worktree station first)"; exit 2 }
& git -C $wt rev-parse --verify --quiet MERGE_HEAD 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { & git -C $wt merge --abort 2>&1 | Out-Null }   # a killed earlier run left a merge half done
# TD-EH-09: a Resurvey is recoverable at any point. .kitchen\BASE.next names the tip being merged in, written before the merge and removed
# only once BASE and DIFF.patch are rewritten. Stopped after its merge commit but before the Benchmark move, BASE stayed old and DIFF.patch
# then held main's changes (the commit Step failed it as "DIFF BUDGET EXCEEDED", blamed on the Crew). On start: HEAD has that tip = finish
# the move now (the rest of this run rewrites DIFF.patch and removes the note); HEAD does not = the merge never landed, BASE is right, drop it.
$nextFile = Join-Path $wt '.kitchen\BASE.next'
if (Test-Path -LiteralPath $nextFile) {
    $next = "$(Get-Content -LiteralPath $nextFile -Raw)".Trim()
    $landed = $false
    if ($next -match '^[0-9a-f]{40,64}$') { & git -C $wt merge-base --is-ancestor $next HEAD 2>&1 | Out-Null; $landed = ($LASTEXITCODE -eq 0) }
    $was = "$(Get-Content -LiteralPath $baseFile -Raw)".Trim()
    $nextShort = if ($next.Length -ge 7) { $next.Substring(0, 7) } else { "'$next'" }
    if ($landed) {
        Set-Content -LiteralPath $baseFile -Value $next
        Write-Output "freshen: finished an interrupted Resurvey: the Benchmark moves to $nextShort (its merge was already committed)"
    } else {
        Remove-Item -LiteralPath $nextFile -Force
        Write-Output "freshen: an interrupted Resurvey of $nextShort never committed its merge; the Benchmark stays at $(if ($was.Length -ge 7) { $was.Substring(0, 7) } else { $was })"
    }
}
$dirty = @(& git -C $wt status --porcelain --untracked-files=no)
if ($dirty.Count) { Write-Output "freshen: the worktree has uncommitted changes; commit them first:"; $dirty | Select-Object -First 10 | ForEach-Object { "  $_" }; exit 1 }
$into = (& git -C $Repo rev-parse --abbrev-ref HEAD)
# freshen only from main with a clean tree: from a feature branch or a detached HEAD the job would be tested against code main does not
# have. Nothing changes; the order waits its turn (exit 11) until the checkout is back on main.
$mainDirty = @(& git -C $Repo status --porcelain --untracked-files=no)
# "main" is the repo's default branch (origin/HEAD, else main, else master; repo-config.ps1): other repos may use master. None found: 'main'.
. (Join-Path $PSScriptRoot '..\repo-config.ps1'); $mainName = Get-RepoDefaultBranch $Repo; if (-not $mainName) { $mainName = 'main' }
. (Join-Path $PSScriptRoot '..\history-lib.ps1')
if ($into -ne $mainName -or $mainDirty.Count) {
    if ($env:KITCHEN_RUN) { Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value 600 }
    Write-Output "freshen: the real checkout is $(if ($into -ne $mainName) { "on '$into', not $mainName" } else { "$mainName with uncommitted changes" }); waiting, nothing changed"; exit 11
}
$tip =(& git -C $Repo rev-parse HEAD)
$short = (& git -C $Repo rev-parse --short HEAD)
# main replaced by an unrelated history (2026-10-26: brain-monitor moved to tide with a fresh history): no merge can bring this order up to
# date, and git would only fail late. Held for Jordan (exit 10) in one plain line naming the way out; nothing written, BASE stays.
if ((Get-HistoryRelation $wt $tip HEAD) -eq 'unrelated') {
    Write-Output (Get-UnrelatedHistoryHold 'freshen' $job $branch $mainName $short 'Nothing merged, nothing changed')
    exit 10
}
Set-Content -LiteralPath $nextFile -Value $tip   # before the merge: a stop anywhere from here on is finished or dropped by the next start
& git -C $wt merge-base --is-ancestor $tip HEAD 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Output "freshen: $branch already has $into@$short"
} else {
    # core.hooksPath=/dev/null: the worktree's hook files are the cook's to edit; the kitchen's own merge commits never run them
    & git -C $wt -c core.hooksPath=/dev/null -c user.name="Jordan's Kitchen" -c user.email='kitchen@localhost' merge --no-ff --no-edit -m "Freshen $branch with $into (kitchen $job)" $tip 2>&1 | ForEach-Object { "git: $_" }
    if ($LASTEXITCODE) {
        $files = @(& git -C $wt diff --name-only --diff-filter=U)
        $gitDir = (& git -C $wt rev-parse --git-path MERGE_HEAD)
        if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $wt $gitDir }
        $aborted = $false
        $why = ''
        if ($files.Count) {
            # a cook resolves the markers keeping both sides; everything it did is then checked without AI
            Write-Output "freshen: CONFLICT merging $into into $branch in: $($files -join ', '); asking a cook to resolve it keeping both sides"
            $a = @{ Role = 'do'; Mode = 'acceptEdits'; WorkDir = $wt; Tools = 'Read,Grep,Glob,Edit,Write'; MaxTurns = $MaxTurns; MaxBudgetUsd = $MaxBudgetUsd
                Prompt = "You are a line cook finishing a git merge in this repository. You are in a git worktree on its own branch ($branch); the merge of $into into it stopped with conflicts in these files: $($files -join ', ').`n`nOpen each conflicted file and resolve every conflict marker (the <<<<<<<, ======= and >>>>>>> lines), keeping both sides' intent: both features stay; lines that changed for different reasons are combined into one line that does both; never drop the other change. Remove every marker line and leave the file valid (it must still parse, and JSON must stay JSON). Edit only the conflicted files. You cannot run commands and must not commit; the merge is committed and the tests run after you. When done, list each file and how you combined the two sides." }
            if ($Order) { $a.Order = $Order }; if ($Supplier) { $a.Supplier = $Supplier }; if ($Private) { $a.Private = $true } elseif ($Public) { $a.Public = $true }
            # the cook gets the step's time less 5 minutes for the checks, lint and commit after it (with all of it, the supervisor stopped
            # the unsafe step mid-commit and Jordan was asked whether re-running it was safe)
            if ([int]$env:KITCHEN_TIMEOUT -gt 0) { $a.TimeoutSec = [math]::Max(120, [int]$env:KITCHEN_TIMEOUT - [int]$clock.Elapsed.TotalSeconds - 300) }
            $global:LASTEXITCODE = 0
            & $Agent @a
            $code = $LASTEXITCODE
            if ($code -in 10, 11) { & git -C $wt merge --abort 2>&1 | Out-Null; Remove-Item -LiteralPath $nextFile -Force -ErrorAction SilentlyContinue; exit $code }   # held for Jordan / no cook free: the supervisor handles it like any AI step
            if ($code) { $why = 'the cook could not finish' }
            if (-not $why) {
                $marked = @($files | Where-Object {
                    $p = Join-Path $wt $_
                    (Test-Path -LiteralPath $p -PathType Leaf) -and (Select-String -LiteralPath $p -Pattern '^(<{7}( |$)|={7}$|>{7}( |$))' -Quiet)
                })
                if ($marked.Count) { $why = "conflict markers remain in: $($marked -join ', ')" }
            }
            if (-not $why) {
                $stray = @(& git -C $wt diff --name-only | Where-Object { $_ -and $_ -notin $files })
                if ($stray.Count) { $why = "the cook edited files outside the conflict: $($stray -join ', ')" }
            }
            if (-not $why) {
                & git -C $wt add -- @files 2>&1 | Out-Null
                if (@(& git -C $wt diff --name-only --diff-filter=U).Count) { $why = 'unmerged paths remain' }
            }
            if (-not $why) {
                $global:LASTEXITCODE = 0
                $lint = @(& (Join-Path $PSScriptRoot 'lint.ps1') -Dir $wt -Files $files)
                if ($LASTEXITCODE) { $why = "lint failed: $((@($lint | Where-Object { $_ -match '^FAIL' }) | Select-Object -First 3) -join '; ')" }
            }
            if (-not $why) {
                & git -C $wt -c core.hooksPath=/dev/null -c user.name="Jordan's Kitchen" -c user.email='kitchen@localhost' commit --no-edit 2>&1 | ForEach-Object { "git: $_" }
                if ($LASTEXITCODE) { $why = 'could not commit the merge' }
            }
            if ($why) { Write-Output "freshen: the cook's resolution was refused: $why" }
        } else { $why = 'no conflicted files' }
        if ($why) {
            if (Test-Path -LiteralPath $gitDir) { & git -C $wt merge --abort 2>&1 | Out-Null }
            & git -C $wt reset --hard HEAD 2>&1 | Out-Null   # the worktree was clean at the start: drop anything the cook left behind
            Remove-Item -LiteralPath $nextFile -Force -ErrorAction SilentlyContinue   # nothing merged: the Benchmark stays
            if ($files.Count) {
                Write-Output "freshen: CONFLICT merging $into into $branch in: $($files -join ', ') (aborted, nothing changed). Another change touched the same lines; cook this order again on top of the new code."
            } else {
                Write-Output 'freshen: git merge failed (aborted)'
            }
            exit 1
        }
        Write-Output "freshen: conflict resolved by the cook and committed ($($files -join ', '))"
    }
}
# the merged-in code is not this job's change: move BASE to the tip so the diff is exactly what the final merge will apply
Set-Content -LiteralPath $baseFile -Value $tip
$diff = @(& git -C $wt diff --no-renames $tip HEAD -- . ':(exclude).kitchen')   # renames off, as in commit.ps1
Set-Content -LiteralPath (Join-Path $wt '.kitchen\DIFF.patch') -Value ($diff -join "`n") -Encoding utf8
# the weakened-test check, as in commit.ps1 (the diff was just rewritten against the new BASE, so its findings are written again)
try { $wo = @(& (Join-Path $PSScriptRoot '..\..\scripts\weakened-tests.ps1') -Dir $wt -Base $tip -Out (Join-Path $wt '.kitchen\WEAKENED.txt')) } catch { $wo = @("weakened-tests: could not run: $_") }
Add-Content -LiteralPath (Join-Path $wt '.kitchen\DIFF.patch') -Value (@('', '# weakened-test check') + @($wo | ForEach-Object { "# $_" })) -Encoding utf8
$wo | Where-Object { $_ -match '^(FLAG|weakened-tests: (none|could|cannot|\d))' } | ForEach-Object { "freshen: $_" }
Remove-Item -LiteralPath $nextFile -Force   # BASE and DIFF.patch are both rewritten: the Benchmark move is done
& git -C $wt diff --stat $tip HEAD -- . ':(exclude).kitchen' | ForEach-Object { "freshen: $_" }
Write-Output "freshen: $branch is up to date with $into@$short"
exit 0
