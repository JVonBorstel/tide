# Tests for kitchen/stations/freshen.ps1 (clean freshen, conflicting freshen, guards). Self-cleaning: temp kitchen root and scratch repo only.
$ErrorActionPreference = 'Stop'
$st = Join-Path $PSScriptRoot '..\kitchen\stations'
$recipe = Join-Path $PSScriptRoot '..\kitchen\recipes\improve.json'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kf-' + [guid]::NewGuid().ToString('N'))
$kr = Join-Path $root 'kitchen'; $repo = Join-Path $root 'repo'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G { & git -C $repo -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function Station($name, [string[]]$more = @()) { (& pwsh -NoProfile -File (Join-Path $st "$name.ps1") -Repo $repo @more 2>&1 | Out-String) }
# a fake cook: FAKE_MODE picks what it does, the prompt it was given goes to FAKE_LOG
$fake = Join-Path $root 'fake-agent.ps1'
function NewConflict($job, $file) {
    Set-Content "$repo\$file" "a`nb`nc"; G add -A; G commit -q -m "base $file"
    $env:KITCHEN_JOB = $job
    pwsh -NoProfile -File (Join-Path $st 'worktree.ps1') -Repo $repo | Out-Null
    $w = Join-Path $kr "worktrees\$job"
    Set-Content "$w\$file" "a`nb-job`nc"
    pwsh -NoProfile -File (Join-Path $st 'commit.ps1') -Message "job $file" | Out-Null
    Set-Content "$repo\$file" "a`nb-main`nc"; G add -A; G commit -q -m "main $file"
    $w
}
function Aborted($label, $w, $before, $ec) {
    Check "${label}: exit non-zero" ($ec -ne 0)
    Check "${label}: HEAD unchanged" ((& git -C $w rev-parse HEAD) -eq $before)
    Check "${label}: no MERGE_HEAD" (-not (& git -C $w rev-parse --verify --quiet MERGE_HEAD))
    Check "${label}: worktree clean" (@(& git -C $w status --porcelain --untracked-files=no).Count -eq 0)
}
$oldKitchen = $env:BRAIN_KITCHEN; $oldJob = $env:KITCHEN_JOB
try {
    New-Item -ItemType Directory -Path $kr, $repo | Out-Null
    $env:BRAIN_KITCHEN = $kr
    & git -C $repo init -q -b main 2>&1 | Out-Null
    Set-Content "$repo\app.txt" "a`nb`nc"; Set-Content "$repo\other.txt" 'o'
    G add -A; G commit -q -m base

    # 1. clean freshen: the job and main touch different files
    $env:KITCHEN_JOB = 'J1'
    pwsh -NoProfile -File (Join-Path $st 'worktree.ps1') -Repo $repo | Out-Null
    $wt = Join-Path $kr 'worktrees\J1'
    Set-Content "$wt\app.txt" "a-job`nb`nc"
    pwsh -NoProfile -File (Join-Path $st 'commit.ps1') -Message 'job edit' | Out-Null
    Set-Content "$repo\other.txt" 'o-main'; G add -A; G commit -q -m 'main edit'
    $tip = (& git -C $repo rev-parse HEAD)
    $headBefore = $tip
    $out = Station 'freshen'
    Check 'clean: exit 0' ($LASTEXITCODE -eq 0)
    & git -C $wt merge-base --is-ancestor $tip HEAD; Check 'clean: worktree has main tip' ($LASTEXITCODE -eq 0)
    Check 'clean: HEAD is a merge commit' ((& git -C $wt rev-list --parents -n 1 HEAD).Split(' ').Count -eq 3)
    Check 'clean: kitchen identity' ((& git -C $wt log -1 --format=%an) -eq "Jordan's Kitchen")
    Check 'clean: both changes present' ((Get-Content "$wt\app.txt" -Raw) -match 'a-job' -and (Get-Content "$wt\other.txt" -Raw) -match 'o-main')
    $patch = Get-Content "$wt\.kitchen\DIFF.patch" -Raw
    Check 'clean: diff has the job line' ($patch -match '\+a-job')
    Check 'clean: diff leaves out main change' ($patch -notmatch 'other\.txt')
    Check 'clean: BASE is the tip' ((Get-Content "$wt\.kitchen\BASE" -Raw).Trim() -eq $tip)
    Check 'clean: real checkout untouched' ((& git -C $repo rev-parse HEAD) -eq $headBefore -and (Get-Content "$repo\app.txt" -Raw) -notmatch 'a-job')
    $wtHead = (& git -C $wt rev-parse HEAD)
    $out = Station 'freshen'
    Check 're-run: exit 0, no new commit' ($LASTEXITCODE -eq 0 -and (& git -C $wt rev-parse HEAD) -eq $wtHead)

    # 2. conflicting freshen: the job and main change the same line
    $env:KITCHEN_JOB = 'J2'
    pwsh -NoProfile -File (Join-Path $st 'worktree.ps1') -Repo $repo | Out-Null
    $wt2 = Join-Path $kr 'worktrees\J2'
    Set-Content "$wt2\app.txt" "a`nb-job`nc"
    pwsh -NoProfile -File (Join-Path $st 'commit.ps1') -Message 'job conflict' | Out-Null
    Set-Content "$repo\app.txt" "a`nb-main`nc"; G add -A; G commit -q -m 'main conflict'
    $mainHead = (& git -C $repo rev-parse HEAD)
    $before = (& git -C $wt2 rev-parse HEAD)
    Set-Content $fake @'
param([string]$Role, [string]$Mode, [string]$WorkDir, [string]$Tools, [int]$MaxTurns, [double]$MaxBudgetUsd, [string]$Prompt, [string]$Order, [string]$Supplier, [switch]$Private, [switch]$Public, [int]$TimeoutSec)
Set-Content -LiteralPath $env:FAKE_LOG -Value $Prompt; Set-Content -LiteralPath "$($env:FAKE_LOG).timeout" -Value $TimeoutSec
$nx = Join-Path $WorkDir '.kitchen\BASE.next'; Set-Content -LiteralPath "$($env:FAKE_LOG).next" -Value $(if (Test-Path -LiteralPath $nx) { Get-Content -LiteralPath $nx -Raw } else { 'none' })
$m = $env:FAKE_MODE
if ($m -eq 'fail') { exit 1 }
if ($m -eq 'wait') { exit 11 }
foreach ($f in @(& git -C $WorkDir diff --name-only --diff-filter=U)) {
    $p = Join-Path $WorkDir $f
    if ($m -eq 'resolve' -or $m -eq 'outside') { Set-Content -LiteralPath $p -Value "a`nb-job`nb-main`nc" }
    if ($m -eq 'badjson') { Set-Content -LiteralPath $p -Value '{ not json' }
}
if ($m -eq 'outside') { Set-Content -LiteralPath (Join-Path $WorkDir 'other.txt') -Value 'tampered' }
exit 0
'@
    $env:FAKE_LOG = Join-Path $root 'prompt.txt'; $env:FAKE_MODE = 'leave'
    $out = Station 'freshen' @('-Agent', $fake)
    Check 'conflict: exit non-zero' ($LASTEXITCODE -ne 0)
    Check 'conflict: message names CONFLICT and the file' ($out -match 'CONFLICT' -and $out -match 'app\.txt')
    Check 'conflict: HEAD unchanged' ((& git -C $wt2 rev-parse HEAD) -eq $before)
    Check 'conflict: no MERGE_HEAD' (-not (& git -C $wt2 rev-parse --verify --quiet MERGE_HEAD))
    Check 'conflict: no tracked changes' (@(& git -C $wt2 status --porcelain --untracked-files=no).Count -eq 0)
    Check 'conflict: file still the job version' ((Get-Content "$wt2\app.txt" -Raw) -match 'b-job')
    Check 'conflict: main unchanged' ((& git -C $repo rev-parse HEAD) -eq $mainHead)

    # 2b. the cook resolves the conflict keeping both sides
    $w = NewConflict 'J3' 'r1.txt'
    $tip3 = (& git -C $repo rev-parse HEAD); $real = $tip3
    $env:FAKE_MODE = 'resolve'
    $out = Station 'freshen' @('-Agent', $fake)
    Check 'resolve: exit 0' ($LASTEXITCODE -eq 0)
    Check 'resolve: HEAD is a two-parent merge' ((& git -C $w rev-list --parents -n 1 HEAD).Split(' ').Count -eq 3)
    & git -C $w merge-base --is-ancestor $tip3 HEAD; Check 'resolve: worktree has main tip' ($LASTEXITCODE -eq 0)
    $txt = Get-Content "$w\r1.txt" -Raw
    Check 'resolve: both sides present' ($txt -match 'b-job' -and $txt -match 'b-main')
    Check 'resolve: no markers' ($txt -notmatch '(?m)^(<<<<<<<|=======|>>>>>>>)')
    Check 'resolve: BASE is the tip' ((Get-Content "$w\.kitchen\BASE" -Raw).Trim() -eq $tip3)
    $patch = Get-Content "$w\.kitchen\DIFF.patch" -Raw
    Check 'resolve: diff has the job line, not main change' ($patch -match '\+b-job' -and $patch -notmatch '\+b-main')
    Check 'resolve: worktree clean' (@(& git -C $w status --porcelain --untracked-files=no).Count -eq 0)
    Check 'resolve: real checkout untouched' ((& git -C $repo rev-parse HEAD) -eq $real -and (Get-Content "$repo\r1.txt" -Raw) -notmatch 'b-job')
    $prompt = Get-Content $env:FAKE_LOG -Raw
    Check 'resolve: prompt names the file and both sides' ($prompt -match 'r1\.txt' -and $prompt -match 'both sides')

    # 2b2. the cook gets the step's time less room for the checks and the commit after it, never the whole limit
    $w = NewConflict 'J9' 'r9.txt'; $env:FAKE_MODE = 'resolve'; $env:KITCHEN_TIMEOUT = '1800'
    try { $null = Station 'freshen' @('-Agent', $fake) } finally { $env:KITCHEN_TIMEOUT = $null }
    $fts = [int](Get-Content "$($env:FAKE_LOG).timeout" -ErrorAction SilentlyContinue)
    Check 'resolve: the cook gets less than the step limit (room for lint and commit)' ($fts -ge 120 -and $fts -le 1500)
    # 2c. refused resolutions abort the merge as before
    foreach ($case in @(@('leave', 'J4', 'm1.txt'), @('outside', 'J5', 'm2.txt'), @('fail', 'J6', 'm3.txt'), @('wait', 'J7', 'm4.txt'), @('badjson', 'J8', 'm5.json'))) {
        $mode, $j, $f = $case
        $w = NewConflict $j $f
        $before = (& git -C $w rev-parse HEAD)
        $env:FAKE_MODE = $mode
        $out = Station 'freshen' @('-Agent', $fake)
        $ec = $LASTEXITCODE
        Aborted $mode $w $before $ec
        Check "${mode}: job file still the job version" ((Get-Content "$w\$f" -Raw) -match 'b-job')
        Check "${mode}: other.txt not tampered" ((Get-Content "$w\other.txt" -Raw) -notmatch 'tampered')
        if ($mode -eq 'wait') { Check 'wait: exit 11 propagates' ($ec -eq 11) }
        else { Check "${mode}: says CONFLICT aborted" ($out -match 'CONFLICT' -and $out -match 'aborted') }
    }

    # 4. TD-EH-09: a Resurvey is recoverable at any point. BASE.next names the tip before the merge starts (the cook sees it) and is gone after;
    # a run stopped after its merge commit but before the Benchmark move is finished on the next start; a note whose merge never landed is dropped
    $w = NewConflict 'J40' 'n1.txt'; $tip40 = (& git -C $repo rev-parse HEAD); $env:FAKE_MODE = 'resolve'
    $out = Station 'freshen' @('-Agent', $fake); $ec = $LASTEXITCODE
    Check 'BASE.next: written with the tip before the merge (the cook saw it)' ((Get-Content "$($env:FAKE_LOG).next" -Raw).Trim() -eq $tip40)
    Check 'BASE.next: gone after a finished Resurvey' ($ec -eq 0 -and -not (Test-Path "$w\.kitchen\BASE.next"))
    $env:KITCHEN_JOB = 'J41'
    pwsh -NoProfile -File (Join-Path $st 'worktree.ps1') -Repo $repo | Out-Null
    $w41 = Join-Path $kr 'worktrees\J41'; $base41 = (Get-Content "$w41\.kitchen\BASE" -Raw).Trim()
    Set-Content "$w41\q1.txt" 'job'; pwsh -NoProfile -File (Join-Path $st 'commit.ps1') -Message 'job q1' | Out-Null
    Set-Content "$repo\q2.txt" "m1`nm2`nm3"; G add -A; G commit -q -m 'main q2'; $tip41 = (& git -C $repo rev-parse HEAD)
    # the stop: the merge commit is made, BASE.next names its tip, BASE is still the old Benchmark
    Set-Content "$w41\.kitchen\BASE.next" $tip41
    & git -C $w41 -c user.name=t -c user.email=t@localhost merge -q --no-ff -m 'Freshen (stopped before the Benchmark move)' $tip41 2>&1 | Out-Null
    Check 'stopped Resurvey: BASE is still old before the re-run' ((Get-Content "$w41\.kitchen\BASE" -Raw).Trim() -eq $base41)
    $out = Station 'freshen'; $ec = $LASTEXITCODE
    Check 'stopped Resurvey: the next start finishes the Benchmark move and says so' ($ec -eq 0 -and $out -match "freshen: finished an interrupted Resurvey: the Benchmark moves to $($tip41.Substring(0, 7))" -and (Get-Content "$w41\.kitchen\BASE" -Raw).Trim() -eq $tip41)
    Check 'stopped Resurvey: BASE.next gone, DIFF.patch holds only the job change' (-not (Test-Path "$w41\.kitchen\BASE.next") -and (Get-Content "$w41\.kitchen\DIFF.patch" -Raw) -match 'q1\.txt' -and (Get-Content "$w41\.kitchen\DIFF.patch" -Raw) -notmatch 'q2\.txt')
    # a note whose merge never landed (stopped before the merge commit): dropped at the start, BASE untouched, even when freshen then waits
    Set-Content "$repo\q3.txt" 'm'; G add -A; G commit -q -m 'main q3'; $tip42 = (& git -C $repo rev-parse HEAD)
    Set-Content "$w41\.kitchen\BASE.next" $tip42; G checkout -q -b side41
    $out = Station 'freshen'; $ec = $LASTEXITCODE
    G checkout -q main
    Check 'merge never landed: the note is dropped and said, BASE untouched' ($ec -eq 11 -and $out -match "freshen: an interrupted Resurvey of $($tip42.Substring(0, 7)) never committed its merge; the Benchmark stays at $($tip41.Substring(0, 7))" -and -not (Test-Path "$w41\.kitchen\BASE.next") -and (Get-Content "$w41\.kitchen\BASE" -Raw).Trim() -eq $tip41)

    # 3. guards
    # the real checkout off main (a feature branch, a detached HEAD) or with uncommitted edits: freshen waits (exit 11), nothing changes
    $env:KITCHEN_JOB = 'J1'; $wtHead = (& git -C $wt rev-parse HEAD)
    G checkout -q -b side
    $out = Station 'freshen'
    Check 'off main: waits (exit 11), says so, worktree untouched' ($LASTEXITCODE -eq 11 -and $out -match "on 'side', not main" -and (& git -C $wt rev-parse HEAD) -eq $wtHead)
    G checkout -q main; Set-Content "$repo\other.txt" 'editing'
    $out = Station 'freshen'
    Check 'main with uncommitted edits: waits (exit 11)' ($LASTEXITCODE -eq 11 -and $out -match 'uncommitted' -and (& git -C $wt rev-parse HEAD) -eq $wtHead)
    G checkout -q -- other.txt
    $env:KITCHEN_JOB = ''
    $null = Station 'freshen'
    Check 'no job: exit 2' ($LASTEXITCODE -eq 2)
    $r = Get-Content $recipe -Raw | ConvertFrom-Json
    $names = @($r.steps | ForEach-Object { $_.station })
    $i = [array]::IndexOf($names, 'freshen')
    Check 'recipe: freshen right before tests, after commit' ($i -gt 0 -and $names[$i + 1] -eq 'tests' -and $names[$i - 1] -eq 'commit')
    Check 'recipe: freshen takes the repo' ($i -gt 0 -and $r.steps[$i].args.Repo -eq '{{repo}}')
    Check 'recipe: freshen is an ai step' ($i -gt 0 -and $r.steps[$i].ai -eq $true -and $r.steps[$i].timeoutSec -ge 1200)
}
finally {
    $env:BRAIN_KITCHEN = $oldKitchen; $env:KITCHEN_JOB = $oldJob
    if (Test-Path -LiteralPath $repo) { & git -C $repo worktree prune 2>&1 | Out-Null }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "KitchenFreshen tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
