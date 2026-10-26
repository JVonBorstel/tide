# Recheck main on demand (TD-EH-03d): runs a Tower's red suites (or every suite, -All) on its current main in a throwaway worktree and
# records the main status green or red. Run by the Foreman (later a scheduled task); never touches the live checkout's working tree.
#   pwsh -File scripts/recheck-main.ps1 -Repo <the Tower's checkout> [-All] [-SkipUnchanged] [-Local] [-Glob ...] [-Skip ...] [-SuiteTimeoutSec N] [-MaxMB N]
# Why: a red main closes the Tower to merges (TD-EH-03c), and only a green check opens it again. The verify Step checks main only after
# a Yard merge, so a fix merged with `merge-pr.ps1 -FixesRed` left main marked red for good. This is the way out.
# What it does, in order:
#  1. Reads the Tower's main status (kitchen/main-status.ps1). Without -All it reruns the suites the status names as failing: green has
#     nothing to recheck (exit 0, nothing written); no status, a file that cannot be read, or a red status that names no suites needs -All.
#  2. Finds "current main": this PC's main branch (the repo's default branch, repo-config.ps1) and GitHub's main (fetched by URL, as the
#     merge Step does; the Tower's "github" in kitchen.repo.json, else the slug the Yard derives). The one that contains the other is main.
#     Split apart, or GitHub cannot be reached: nothing is checked (exit 2) rather than guessed. -Local checks this PC's main only (a Tower
#     that is not on GitHub needs it). -SkipUnchanged (the night inspection, TD-EH-03b): when the status is green from a full run (the
#     verify Step or a recheck -All, not a recheck of only the red suites) at this commit or one with the same tree, nothing runs (exit 3).
#  3. Checks that commit out detached in a throwaway worktree under TEMP (recheck-main-<sha12>-*), runs the same tests Step the verify
#     Step runs (kitchen/stations/tests.ps1, each suite through scripts/run-bounded.ps1), and removes the worktree however the run ends.
#     A worktree left by a recheck that was stopped is swept by the next one. One recheck per Tower at a time.
#  4. Writes the main status through Set-MainStatus: green, or red with the suites still failing, why and since (kept while it stays red),
#     at the commit checked. A status that changed while the suites ran (the verify Step wrote one) is not overwritten.
# Exit: 0 green recorded (or already green, nothing to recheck), 1 red recorded, 2 nothing recorded (bad input, no verdict, says why),
# 3 skipped by -SkipUnchanged (main unchanged since its last green full run; nothing run, nothing recorded, says so).
param(
    [Parameter(Mandatory)][string]$Repo,
    [switch]$All,
    [switch]$Local,
    [switch]$SkipUnchanged,
    [string]$Glob = 'tests\Test-*.ps1',
    [string]$Skip = '',
    [int]$SuiteTimeoutSec = 600,
    [int]$MaxMB = 2000
)
$ErrorActionPreference = 'Stop'
$kitchenDir = Join-Path $PSScriptRoot '..\kitchen'
. (Join-Path $kitchenDir 'main-status.ps1')
. (Join-Path $kitchenDir 'repo-config.ps1')
. (Join-Path $kitchenDir 'github-lib.ps1')
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$testsStation = Join-Path $kitchenDir 'stations\tests.ps1'
$pwsh = (Get-Process -Id $PID).Path
function Say([string]$t) { Write-Output "recheck-main: $t" }
function Stop-Recheck([string]$t) { Say "$t; nothing recorded"; exit 2 }
function Get-Short([string]$s) { if ($s.Length -gt 12) { $s.Substring(0, 12) } else { $s } }

# 1. the Tower and what its main status says
if (-not (Test-Path -LiteralPath $Repo -PathType Container)) { Stop-Recheck "folder not found: $Repo" }
if (-not (Test-Path -LiteralPath $testsStation)) { Stop-Recheck "the tests Step is not at $testsStation" }
try { $Repo = Get-RepoMainCheckout $Repo } catch { Stop-Recheck $_.Exception.Message }
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { Stop-Recheck "$Repo is not a git checkout" }
$tower = Split-Path -Leaf $Repo
$prev = @(Get-MainStatusFor $kroot $Repo)[0]
$prevState = if ($prev) { [string]$prev.state } else { 'none' }
$suites = @()
if (-not $All) {
    if ($prevState -eq 'green') { Say "$tower main is already green (checked $(Get-Short ([string]$prev.sha)) at $($prev.at)); nothing to recheck (-All runs every suite anyway)"; exit 0 }
    if ($prevState -eq 'none') { Stop-Recheck "no main status is recorded for $tower yet, so no suites are named as failing: run with -All" }
    if ($prevState -ne 'red') { Stop-Recheck "the main status file for $tower cannot be read, so no suites are named as failing: run with -All" }
    $suites = @($prev.suites | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $suites.Count -or $suites -contains 'suite') { Stop-Recheck "$tower main is red but its status does not name the failing suites: run with -All" }
}

# one recheck per Tower at a time (the sweep below removes this Tower's leftover worktrees, which must not be a running one's)
$key = Get-MainStatusKey $Repo
$lock = [Threading.Mutex]::new($false, "Global\brain-recheck-main-$key"); $got = $false
try { $got = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { $lock.Dispose(); Stop-Recheck "another recheck of $tower is running" }

# 2. current main: this PC's main branch, or GitHub's main when it is ahead; split apart or unreachable = not guessed
$mainName = Get-RepoDefaultBranch $Repo
if (-not $mainName) { Stop-Recheck "$tower has no main branch (no origin/HEAD, main or master)" }
$localSha = "$(& git -C $Repo rev-parse --verify --quiet "refs/heads/$mainName^{commit}" 2>$null)".Trim()
$sha = $localSha; $from = "this PC's $mainName"
if (-not $Local) {
    try { $gh = [string](Get-RepoConfig $Repo).Github } catch { Stop-Recheck $_.Exception.Message }
    $gs = Resolve-GithubSlug $Repo $gh
    if ($gs.bad) { Stop-Recheck $gs.bad }
    if (-not $gs.none) {
        $ghSha = Get-GithubMain $Repo $gs.slug
        if (-not $ghSha) { Stop-Recheck "could not fetch main from GitHub ($($gs.slug)); -Local checks this PC's $mainName instead" }
        if ($ghSha -eq $localSha) { $from = "main (this PC's and GitHub's agree)" }
        elseif (Test-Ancestor $Repo $localSha $ghSha) { $sha = $ghSha; $from = "GitHub's main ($($gs.slug)), ahead of this PC's $mainName" }
        elseif (Test-Ancestor $Repo $ghSha $localSha) { $from = "this PC's $mainName, ahead of GitHub's main" }
        else { Stop-Recheck "this PC's $mainName ($(Get-Short $localSha)) and GitHub's main ($(Get-Short $ghSha)) have split apart, so which one is main is not known; -Local checks this PC's" }
    }
}
$short = Get-Short $sha
# -SkipUnchanged: main has not moved since its last green FULL run (same commit, or same tree); a green from a recheck of only the red
# suites proves only those suites, so it never counts
if ($SkipUnchanged -and $prevState -eq 'green' -and [string]$prev.note -notmatch 'only the suites that were red') {
    $tree = "$(& git -C $Repo rev-parse --verify --quiet "$sha^{tree}" 2>$null)".Trim()
    if ([string]$prev.sha -eq $sha -or ($tree -and [string]$prev.tree -eq $tree)) {
        Say "skipped: $tower main is unchanged since its last green full run ($short, checked at $($prev.at)); nothing run, nothing recorded"
        $lock.ReleaseMutex(); exit 3
    }
}
$what = if ($All) { 'every suite' } else { $suites -join ', ' }
Say "checking $what on $from at $short, in a throwaway worktree"

# 3. a throwaway worktree at that commit: earlier leftovers swept first, removed again however the run ends
foreach ($old in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter "recheck-main-$key-*" -ErrorAction SilentlyContinue)) {
    & git -C $Repo worktree remove --force $old.FullName 2>&1 | Out-Null
    Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
}
& git -C $Repo worktree prune 2>&1 | Out-Null
$wt = Join-Path ([IO.Path]::GetTempPath()) ("recheck-main-$key-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$out = ''; $code = -1; $addErr = ''
try {
    $wo = & git -C $Repo worktree add --detach $wt $sha 2>&1 | Out-String
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $wt)) { $addErr = $wo.Trim() }
    else {
        # what changed since the status's last check (the sandbox reads it, as on verify's run on main); not known = 'unknown'
        $cf = ''; if ([string]$prev.sha -match '^[0-9a-f]{40,64}$') { $cf = (@(& git -C $Repo diff --name-only ([string]$prev.sha) $sha 2>$null) -join ',') }
        if (-not $cf) { $cf = 'unknown' }
        $onlyArgs = if ($All) { @() } else { @('-Only', ($suites -join ',')) }
        $out = & $pwsh -NoProfile -File $testsStation -Dir $wt -ChangedFiles $cf -Glob $Glob -Skip $Skip @onlyArgs -SuiteTimeoutSec $SuiteTimeoutSec -MaxMB $MaxMB 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
} finally {
    & git -C $Repo worktree remove --force $wt 2>&1 | Out-Null
    if (Test-Path -LiteralPath $wt) { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue }
    & git -C $Repo worktree prune 2>&1 | Out-Null
    if (Test-Path -LiteralPath $wt) { Say "could not remove the throwaway worktree $wt (the next recheck sweeps it)" }
}
if ($addErr) { Stop-Recheck "could not check out $short in a throwaway worktree ($addErr)" }
if ($out) { Write-Output $out.Trim() }

# the verdict: ALL PASS = green (every named suite must have run); FAILED: <suites> = red; anything else says nothing about main
if ($code -eq 10) { Stop-Recheck 'the tests Step held (the sandbox the config asks for is not built)' }
$red = [Collections.Generic.List[string]]::new()
if ($out -match 'FAILED:\s*([^\r\n]+)') { foreach ($s in @($Matches[1] -split '[,;]')) { $n = "$s".Trim(); if ($n -and -not $red.Contains($n)) { $red.Add($n) } } }
$green = $code -eq 0 -and $out.Trim() -match 'ALL PASS\s*$'
if (-not $green -and -not $red.Count) { Stop-Recheck "the tests Step gave no verdict on $short (exit $code)$(if (-not $All) { '; a suite that is not on main any more needs -All' })" }
$ran = @([regex]::Matches($out, '(?m)^tests:\s+(?:PASS|FAIL)\s+(\S+)') | ForEach-Object { $_.Groups[1].Value })
$missing = @($suites | Where-Object { $_ -notin $ran })
if ($green -and $missing.Count) { Stop-Recheck "$($missing -join ', ') did not run on $short (renamed or removed?), so main is not proven green: run with -All" }

# 4. record it, unless the status changed while the suites ran (a newer verdict is never overwritten)
$now = @(Get-MainStatusFor $kroot $Repo)[0]
if ([string]$now.at -ne [string]$prev.at -or [string]$now.state -ne [string]$prev.state) {
    Stop-Recheck "the main status of $tower changed while this ran (now $([string]$now.state), checked $(Get-Short ([string]$now.sha)) at $([string]$now.at)); not overwritten"
}
$note = "recheck of ${from}: $(if ($All) { 'all suites' } else { "only the suites that were red ($($suites -join ', '))" })"
try {
    if ($green) {
        $null = Set-MainStatus $kroot $Repo green -Note $note -Sha $sha
        Say "$tower main is green at $short ($what passed); recorded, the Tower is open to merges again"
        $lock.ReleaseMutex(); exit 0
    }
    $w = Get-MainRedWhy $kroot $out @($red)
    $lead = if ($prevState -eq 'red') { "still red on a recheck of $short" } else { "red on a recheck of $short" }
    $r = Set-MainStatus $kroot $Repo red @($red) "$lead; $($w.why)" '' $w.record $note -Sha $sha
    Say "$tower main is red at $short (Failed: $($red -join ', ')); recorded, red since $($r.since)"
    $lock.ReleaseMutex(); exit 1
} catch { Stop-Recheck "could not write the main status ($($_.Exception.Message))" }
