# Station: run the test suites in this job's worktree, each bounded (time + memory), and write the results to .kitchen\TESTS.txt.
# Ends with "ALL PASS" (exit 0) or "FAILED: <names>" (exit 1). A suite that prints SKIP or "skipped" counts as a red flag line.
#   step: {"station":"tests","args":{"Glob":"tests\\Test-*.ps1"},"mustMatch":"ALL PASS"}
# A job's own run also writes <kitchen>\results\<job>.tests.json {sha, final, flaky}: outside the worktree, where the AI-written code
# it runs cannot rewrite it; auto-merge trusts only that, and only for the commit that was tested.
# -Soft: always exit 0 (the repair station reads TESTS.txt and decides)
# Which suites run: -Glob when a caller names a different one; else the "tests" list of the repo's kitchen.repo.json; else tests\Test-*.ps1.
# That file (and its testTimeoutSec) is read from the repo's MAIN checkout, never from this worktree: see kitchen\repo-config.ps1.
# -Only: just the suites with these names (verify's second look at the ones that failed), picked from the same set.
# -Impacted: only the suites the changed files map to (repair's loop runs); ends "PARTIAL PASS: N of M suites", never "ALL PASS", and writes no
# results\<job>.tests.json unless it failed. Any shared core file or unknown change list runs all suites and says why. A file the fixed
# table does not map is owned by the suites that name it (by its path, or Test-<Name> after its file name); with no owner, by the owners
# of the other files in its folder; only a file with neither runs all suites (and says why).
# -Only never writes a pass to results\<job>.tests.json either: a named few suites are never the job's whole result.
# The repo's "inspector" block can make -Impacted the default for an order's own run ("local": "impacted"; see below and repo-config.ps1).
# Suites run several at once (kitchen/suite-times-lib.ps1 has the rules): up to min(4, cores/2), longest first, each started only while
# the recorded peaks of the running suites + its own + 1,024 MB stay under free RAM; one at a time until the repo has any history in
# <kitchen>\suite-times.jsonl (run-bounded writes a line per suite run). Each suite's limit is clamp(3 x p90 of its last 20 passing runs,
# 60 s, SuiteTimeoutSec). TESTS.txt keeps the suites' own order whatever order they finish in.
# -Parallel N: at most N at once, history or not (1 = one at a time). -FreeMB: use this free RAM figure instead of reading it (tests).
# -Cores N: size the pool and the machine-wide suite slots for N logical cores instead of this PC's (tests: a 2-core CI runner has 1 slot).
# Say why (TD-EH-02): a red run leaves its reasons outside the worktree, where they survive it (.kitchen\TESTS.txt goes with the
# worktree, and a run on main has no .kitchen at all, so 10-23's undone merges had no recorded cause). Every FAIL prints its why lines
# (indented, at most 10) into the step log; <kitchen>\results\<job>.tests-why-<time>.json keeps, per failing suite, the exit code,
# seconds, summary and the first 12 FAIL lines (a crash with none: its last 12 lines); a tests.failed event in events.jsonl names the
# suites, a short reason and that record. A passing run writes none of this. Lines that leave the worktree are cut to 300 chars and a line shaped like a secret is
# withheld (scripts/secret-patterns.ps1); TESTS.txt keeps them as they are.
# Stopped, not failed (TD-EH-16): a suite killed at its time limit (exit 124) or memory cap (125) reads "timed out after N s" or "stopped
# at the memory cap (N MB)", with a first why line that says it was too slow or too large, not a failed assertion (Get-SuiteStop).
param([string]$Glob = 'tests\Test-*.ps1', [string]$Skip = '', [int]$SuiteTimeoutSec = 600, [int]$MaxMB = 2000, [string]$Dir = '', [switch]$Soft, [string[]]$ChangedFiles = @(), [string[]]$Only = @(), [switch]$Impacted,
    [int]$Parallel = 0, [int]$FreeMB = 0, [int]$Cores = 0)
$ErrorActionPreference = 'Stop'
$job = $env:KITCHEN_JOB
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$ownWorktree = -not $Dir   # verify runs this on main with -Dir; only a job's own worktree run is that job's result
if (-not $Dir) { if ($job -notmatch '^J\d+$') { Write-Output 'tests: no kitchen job and no -Dir'; exit 2 }; $Dir = Join-Path $kroot "worktrees\$job" }
if (-not (Test-Path -LiteralPath $Dir)) { Write-Output "tests: folder not found: $Dir"; exit 2 }
$bounded = Join-Path $PSScriptRoot '..\..\scripts\run-bounded.ps1'
# AI-written suites run contained (kitchen.json "sandbox", rust/kitchen-sandbox): a config that asks for the sandbox and has no exe holds
. (Join-Path $PSScriptRoot '..\..\rust\kitchen-sandbox\sandbox.ps1'); $sb = Get-KitchenSandbox (Join-Path $PSScriptRoot '..') $kroot
if ($sb.hold) { Write-Output "tests: $($sb.hold)"; exit 10 }
. (Join-Path $PSScriptRoot '..\repo-config.ps1')
. (Join-Path $PSScriptRoot '..\suite-times-lib.ps1')
. (Join-Path $PSScriptRoot '..\..\scripts\secret-patterns.ps1')
function Clean-WhyLine([string]$l) {
    $l = $l.Trim(); if ($l.Length -gt 300) { $l = $l.Substring(0, 300) }
    $hit = Find-SecretPattern $l; if ($hit) { return "[a line withheld: it looks like a $hit]" }
    $l
}
# The step log is read by verify ('FAILED: <suites>', first match) and by the step's mustMatch ('ALL PASS', anywhere), so a suite's own
# output must never pass for the station's verdict: those two tokens are bent in the printed copy only (the record keeps them whole).
# That covers its why lines and its summary on the per-suite line (a summary "FAILED: X" printed whole fed verify a made-up red list).
function Hide-VerdictWords([string]$l) { $l -replace 'FAILED:', 'FAILED;' -replace 'ALL PASS', 'ALL_PASS' }
function Write-WhyLine([string]$l) { Write-Output ('tests:       ' + (Hide-VerdictWords (Clean-WhyLine $l))) }
# the record's lines: the first 12 FAIL lines; a suite that died with none (a crash, a parse error) leaves its last 12 lines, where
# PowerShell puts the error and its message (10-23: "Test-VerifyCache crashed before its summary line" was all anyone had)
function Get-WhyRecordLines([string[]]$lines) {
    $w = @($lines | Where-Object { $_ -match '^FAIL' } | Select-Object -First 12)
    if (-not $w.Count) { $w = @($lines | Where-Object { $_.Trim() } | Select-Object -Last 12) }
    @($w | ForEach-Object { Clean-WhyLine $_ })
}
# Stopped, not failed (TD-EH-16): run-bounded.ps1 and kitchen-sandbox.exe end a suite they kill with exit 124 (past its time limit) or
# 125 (past its memory cap), and each prints a "killed" line with the limit. Before, such a suite read "crashed before its summary line"
# (or a stray "passed" line it printed earlier), and the repair Crew chased a crash. Code 124/125 with no killed line is the suite's own
# exit code, not a stop. The limit comes from the last killed line; $LimitSec / $CapMB (what this Step gave the limiter) only when the
# line has no number. Returns $null, or {kind, n, summary, note}: the note is the first why line, so it is what the record, the
# tests.failed event and the main status name first.
function Get-SuiteStop([int]$Code, [string]$Out, [int]$LimitSec, [int]$CapMB) {
    if ($Code -ne 124 -and $Code -ne 125) { return $null }
    $kill = @($Out -split "`r?`n" | Where-Object { $_ -match "^(run-bounded: killed .+|kitchen-sandbox: killed the tree) \(exit $Code\b[^)]*\)\s*$" } | Select-Object -Last 1)
    if (-not $kill.Count) { return $null }
    $n = if ($kill[0] -match '\(exit \d+: \D*(\d+)\s*(s|MB)\)\s*$') { [int]$Matches[1] } elseif ($Code -eq 124) { $LimitSec } else { $CapMB }
    if ($Code -eq 124) {
        $sum = "timed out after $n s"
        $note = "FAIL: ${sum}: the suite was stopped at its time limit; it ran too slow or hung. Being stopped is not a failed assertion: look for what made it slow or stuck (a wait that never ends, a loop, a call that never returns)."
        return [pscustomobject]@{ kind = 'timeout'; n = $n; summary = $sum; note = $note }
    }
    $sum = "stopped at the memory cap ($n MB)"
    $note = "FAIL: ${sum}: the suite was stopped because it used too much memory. Being stopped is not a failed assertion: look for what made it so large (a leak, a big file or list held at once, too many processes)."
    [pscustomobject]@{ kind = 'memory'; n = $n; summary = $sum; note = $note }
}
# a bad kitchen.repo.json stops the run (exit 2): falling back to the defaults would run a different set of checks than the repo asked for
try { $rc = Get-RepoConfig $Dir } catch { Write-Output "tests: $($_.Exception.Message)"; exit 2 }
$defaultGlob = 'tests\Test-*.ps1'
$patterns = if ($Glob -ne $defaultGlob) { @($Glob) } elseif ($rc.TestsGiven) { @($rc.Tests) } else { @($defaultGlob) }
foreach ($pg in $patterns) { $why = Get-RepoGlobProblem $pg; if ($why) { Write-Output "tests: test path '$pg' $why"; exit 2 } }
if ($rc.Present) { Write-Output "tests: repo settings from $($rc.Path) (the main checkout, not this worktree)" }
if (-not $PSBoundParameters.ContainsKey('SuiteTimeoutSec') -and $rc.TestTimeoutSec) { $SuiteTimeoutSec = $rc.TestTimeoutSec }
$skipList = @($Skip -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$onlyList = @($Only | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# The Tower's inspector block (TD-12, repo-config.ps1): "local": "impacted" makes an order's own run an impacted one, as if -Impacted
# were given, because its CI runs every suite (the block refuses impacted without ci full). Verify on main (-Dir), -Only and a caller's
# own -Glob are left as they were. No block prints nothing new and changes nothing.
$ip = $rc.Inspector; $byInspector = $ownWorktree -and -not $Impacted -and -not $onlyList.Count -and $Glob -eq $defaultGlob -and $ip.Local -eq 'impacted'
if ($byInspector) { $Impacted = [switch]$true }
if ($ip.Given) { Write-Output "tests: inspector: local $($ip.Local), ci $($ip.Ci)$(if ($byInspector) { ' (this run maps the change to its suites; CI runs them all)' })" }
$found = Resolve-RepoSuites $Dir $patterns
# a pattern that matches nothing fails the run: a cook that deletes a suite must not make the check pass by shrinking it
if ($found.Unmatched.Count) { Write-Output "tests: no suites match $($found.Unmatched -join ', ') in $Dir"; exit 1 }
$suites = @($found.Suites | Where-Object { $_.Name -notin $skipList -and (-not $onlyList.Count -or $_.BaseName -in $onlyList) } | Sort-Object Name)
if (-not $suites.Count) { Write-Output "tests: no suites match $($patterns -join ', ') in $Dir"; exit 1 }

$cfList = @($ChangedFiles | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $cfList.Count) {
    $base = ''
    $bf = Join-Path $Dir '.kitchen\BASE'
    if (Test-Path -LiteralPath $bf) { $base = (Get-Content -LiteralPath $bf -Raw).Trim() }
    try {
        if ($base) {
            $cfList = @(& git -C $Dir diff --name-only --diff-filter=ACMR $base HEAD -- . ':(exclude).kitchen' 2>$null) + @(& git -C $Dir diff --name-only --diff-filter=ACMR -- . ':(exclude).kitchen' 2>$null)
        } elseif (Test-Path -LiteralPath (Join-Path $Dir '.git')) {
            $cfList = @(& git -C $Dir diff --name-only --diff-filter=ACMR HEAD -- . ':(exclude).kitchen' 2>$null) + @(& git -C $Dir diff --name-only --diff-filter=ACMR -- . ':(exclude).kitchen' 2>$null)
        }
    } catch { }
}
$baseNames = @($cfList | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_).Trim() } | Where-Object { $_ } | Sort-Object -Unique)

# each suite's text, read once (the score below and the -Impacted owners both search it)
$suiteText = @{}
function Get-SuiteText($s) { if (-not $suiteText.ContainsKey($s.FullName)) { $suiteText[$s.FullName] = try { [IO.File]::ReadAllText($s.FullName) } catch { '' } }; $suiteText[$s.FullName] }
$suiteScores = @{}
foreach ($s in $suites) {
    $score = 0
    if ($baseNames.Count) {
        $content = Get-SuiteText $s
        foreach ($bn in $baseNames) {
            if ($bn) {
                if ($s.Name.IndexOf($bn, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $score += 2 }
                if ($content.IndexOf($bn, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $score += 1 }
            }
        }
    }
    $suiteScores[$s.FullName] = $score
}
$suites = @($suites | Sort-Object @{ Expression = { -$suiteScores[$_.FullName] } }, Name)

# -Impacted: map the changed files to suites. Anything shared, unmapped or unknown falls back to every suite (never a silently smaller check).
$partial = $false; $skippedSuites = @()
if ($Impacted) {
    $coreRx = '^(scripts/(run-bounded|secret-patterns)\.ps1|kitchen/(repo-config|github-lib|tracker-lib|roadmap-lib|suite-times-lib)\.ps1|kitchen/kitchen\.json|kitchen/stations/(tests|lint)\.ps1|lint\.ps1|kitchen\.repo\.json|rust/kitchen-sandbox/|\.github/)'
    $fallback = ''; $must = [Collections.Generic.List[string]]::new(); $guess = [Collections.Generic.List[string]]::new(); $seen = [Collections.Generic.List[string]]::new()
    $loose = [Collections.Generic.List[string]]::new()   # changed files the fixed table does not map: their owners decide
    $suiteNames = @($suites | ForEach-Object { $_.BaseName })
    # a-b-c -> ABC: the name of a file's own suite is Test-<that>
    function ConvertTo-SuiteStem([string]$stem) { (($stem -split '-') | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '' }
    # a file's owners: the suites that name it by its path (either slash), and its own Test-<Name> suite
    function Get-FileOwners([string]$rel) {
        $bs = $rel -replace '/', '\'; $own = "Test-$(ConvertTo-SuiteStem ([IO.Path]::GetFileNameWithoutExtension($rel)))"
        @($suites | Where-Object { $_.BaseName -eq $own -or (Get-SuiteText $_).IndexOf($rel, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or (Get-SuiteText $_).IndexOf($bs, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { $_.BaseName })
    }
    if (-not $cfList.Count -or $cfList -contains 'unknown') { $fallback = 'the changed files are unknown' }
    foreach ($cf in $cfList) {
        if ($fallback) { break }
        $rel = $cf -replace '\\', '/' -replace '^\./', ''
        $stem = [IO.Path]::GetFileNameWithoutExtension($rel)
        if ($rel -match $coreRx -or ($rel -match '^tests/' -and $rel -notmatch '^tests/(.+/)?Test-[^/]+\.ps1$')) { $fallback = "shared file changed: $rel" }
        elseif ($rel -match '^tests/') { $must.Add($stem) }
        elseif ($rel -match '^pass-app/') { $must.Add('Test-PassApp'); $seen.Add($rel) }
        elseif ($rel -eq 'scripts/memory-check.ps1') { $must.Add('Test-BrainMonitor'); $seen.Add($rel) }
        elseif ($rel -match '^kitchen/([^/]+\.ps1|stations/[^/]+\.ps1|(recipes|cooks)/.+)$') {
            $must.Add('Test-KitchenSupervisor'); $seen.Add($rel)
            $pc = ConvertTo-SuiteStem $stem
            foreach ($gn in "Test-$pc", "Test-Kitchen$pc", "Test-${pc}Station") { $guess.Add($gn) }
        }
        else { $loose.Add($rel) }
    }
    $chosen = @()
    if (-not $fallback) {
        $pick = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($nm in @($must) + @($guess)) { if ($nm -in $suiteNames) { $null = $pick.Add($nm) } }
        # a suite that names a changed file by its full path tests it; suites that failed last time are re-checked
        foreach ($rel in $seen) { foreach ($nm in Get-FileOwners $rel) { $null = $pick.Add($nm) } }
        # a file the table does not map: the suites that own it; with none, the suites that own the other files in its folder (shared
        # core files left out: every suite runs through them); with none of those either, all suites
        foreach ($rel in $loose) {
            $own = @(Get-FileOwners $rel)
            if (-not $own.Count) {
                $folder = [IO.Path]::GetDirectoryName($rel) -replace '\\', '/'
                $fp = if ($folder) { Join-Path $Dir $folder } else { '' }
                $sibs = if ($fp -and (Test-Path -LiteralPath $fp -PathType Container)) { @(Get-ChildItem -LiteralPath $fp -File | ForEach-Object { "$folder/$($_.Name)" } | Where-Object { $_ -ne $rel -and $_ -notmatch $coreRx }) } else { @() }
                $own = @($sibs | ForEach-Object { Get-FileOwners $_ } | Sort-Object -Unique)
                if (-not $own.Count) { $fallback = if ($folder) { "no suite is mapped to $rel or to another file in $folder/" } else { "no suite is mapped to $rel" }; break }
                Write-Output "tests: impacted map: no suite names $rel; running the suites that own other files in $folder/ ($($own -join ', '))"
            }
            foreach ($nm in $own) { $null = $pick.Add($nm) }
        }
    }
    if (-not $fallback) {
        $prevTxt = Join-Path $Dir '.kitchen\TESTS.txt'
        if (Test-Path -LiteralPath $prevTxt) { foreach ($pl in Get-Content -LiteralPath $prevTxt) { if ($pl -match '^FAIL\s+(\S+)') { $null = $pick.Add($Matches[1]) } } }
        $lost = @($must | Sort-Object -Unique | Where-Object { $_ -notin $suiteNames })
        if ($lost.Count) { Write-Output "tests: mapped suite not found: $($lost -join ', ')" }
        $chosen = @($suites | Where-Object { $pick.Contains($_.BaseName) })
        if (-not $chosen.Count) { $fallback = 'the mapping found no suite to run' }
    }
    if ($fallback) { Write-Output "tests: impacted run: all $($suites.Count) suites ($fallback)" }
    elseif ($chosen.Count -lt $suites.Count) {
        $skippedSuites = @($suites | Where-Object { $_.FullName -notin $chosen.FullName }); $partial = $true
        Write-Output "tests: impacted run: $($chosen.Count) of $($suites.Count) suites ($((@($chosen | ForEach-Object { $_.BaseName })) -join ', ')); skipped: $((@($skippedSuites | ForEach-Object { $_.BaseName })) -join ', ')"
        $suites = $chosen
    }
}

$report = [Collections.Generic.List[string]]::new(); $failed = @(); $flakyNames = @(); $lintRec = $null
$sha0 = "$(& git -C $Dir rev-parse HEAD 2>$null)".Trim()   # "" outside git; [string] of an empty pipeline is $null
$saved = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB; h = $env:KITCHEN_HEARTBEAT; r = $env:KITCHEN_RUN; a = $env:KITCHEN_APPROVED; s = $env:KITCHEN_AGENT_STEP; u = $env:KITCHEN_UNDER_TEST }
# free checks first (no tokens, a second or two): every changed file parses, and known traps are caught by name (lint.ps1)
if (Test-Path -LiteralPath (Join-Path $Dir '.kitchen\BASE')) {
    $swLint = [Diagnostics.Stopwatch]::StartNew()
    $lo = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'lint.ps1') -Dir $Dir 2>&1 | Out-String; $lc = $LASTEXITCODE
    $swLint.Stop()
    $lsec = [math]::Round($swLint.Elapsed.TotalSeconds, 1)
    $ls = (($lo -split "`r?`n") | Where-Object { $_ -match '^Lint:' } | Select-Object -Last 1)
    $line = "{0,-5} {1,-34} {2} ({3}s)" -f $(if ($lc -eq 0) { 'PASS' } else { 'FAIL' }), 'Lint (free checks)', "$ls".Trim(), $lsec
    $report.Add($line); Write-Output "tests: $line"
    if ($lc -ne 0) {
        $failed += 'Lint'; ($lo -split "`r?`n") | Where-Object { $_ -match '^FAIL' } | Select-Object -First 15 | ForEach-Object { $report.Add("      $_"); Write-Output ('tests:       ' + (Hide-VerdictWords $_)) }
        $lintRec = [ordered]@{ suite = 'Lint'; code = [int]$lc; sec = $lsec; summary = "$ls".Trim(); why = @(Get-WhyRecordLines ($lo -split "`r?`n")) }
    }
}

# The pool (kitchen/suite-times-lib.ps1 has the rules and their numbers): up to $cap suites at once, each its own run-bounded process
# with its own empty kitchen, started longest first while the memory budget allows; every run adds a line to suite-times.jsonl.
$repoName = Get-SuiteRepoName $Dir
$timesFile = Join-Path $kroot 'suite-times.jsonl'
Limit-SuiteTimesFile $timesFile
$hist = Read-SuiteTimes $timesFile $repoName
$known = @($suites | Where-Object { $hist.ContainsKey($_.BaseName) }).Count
$coreN = if ($Cores -gt 0) { $Cores } else { [Environment]::ProcessorCount }
$cap = if ($Parallel -gt 0) { $Parallel } elseif (-not $hist.Count) { 1 } else { Get-SuiteParallelCap $coreN }
$why = if ($Parallel -gt 0) { 'set by -Parallel' } elseif (-not $hist.Count) { "no suite history yet for $repoName, so one at a time" } else { "min(4, $coreN cores/2); $known of $($suites.Count) suites have history" }
$order = if ($cap -gt 1) { @(Get-SuiteRunOrder $suites $hist) } else { @($suites) }
# a suite whose header (its leading # lines) has a "# runAlone" line never runs next to another suite (one that starts servers and
# flakes under load, e.g. Test-PassApp): it starts only when nothing runs, and nothing starts while it runs. Such suites go first.
$alone = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($s in $suites) { foreach ($hl in [IO.File]::ReadLines($s.FullName)) { if ($hl -notmatch '^\s*(#|$)') { break }; if ($hl -match '^\s*#\s*runAlone\b') { $null = $alone.Add($s.FullName); break } } }
if ($cap -gt 1 -and $alone.Count) { $order = @($order | Where-Object { $alone.Contains($_.FullName) }) + @($order | Where-Object { -not $alone.Contains($_.FullName) }) }
$queue = [Collections.Generic.List[object]]::new(); foreach ($s in $order) { $queue.Add([pscustomobject]@{ s = $s; retry = $false; first = '' }) }
$running = [Collections.Generic.List[object]]::new(); $leftovers = [Collections.Generic.List[string]]::new(); $done = @{}; $failCount = 0; $stopLaunch = $false; $most = 0
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
function Quote-Arg([string]$a) { '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
function Start-Suite($item) {
    $s = $item.s; $recs = $hist[$s.BaseName]
    $limit = Get-SuiteLimitSec $recs $SuiteTimeoutSec
    # suites build their own private kitchens and never see this job's environment. BRAIN_KITCHEN points at a fresh empty folder, never
    # blank: blank, every kitchen script falls back to Jordan's live kitchen, so one suite that forgot to set it would queue or approve
    # real work there. KITCHEN_UNDER_TEST makes kitchen.ps1 and undo-merge.ps1 refuse the live kitchen outright. The child process
    # takes this environment when it starts; the station's own is put back straight after.
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('kt-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    $r = [pscustomobject]@{ item = $item; sandbox = $sandbox; out = "$sandbox.out.txt"; err = "$sandbox.err.txt"; cmd = ''; scratch = ''; p = $null; sw = $null; limit = $limit; peak = (Get-SuitePeakMB $recs); startErr = ''; stopSec = $limit; stopMB = $MaxMB }
    $a = @('-NoProfile', '-File', $bounded, '-Script', $s.FullName, '-TimesFile', $timesFile, '-Repo', $repoName, '-Suite', $s.BaseName, '-Parallel', ($running.Count + 1), '-Sha', $sha0)
    if ($sb.mode -eq 'off') { $a += @('-TimeoutSeconds', $limit, '-MaxMB', $MaxMB) }
    else {
        # sandboxed: kitchen-sandbox.exe enforces the limit and the memory cap; run-bounded around it measures the run and is the backstop
        # (TD-10: $repoName is the Tower whose sandboxMedium block applies, besides the global list)
        $c = Get-KitchenSuiteCommand $sb $s.FullName $Dir $sandbox $limit $MaxMB $cfList $repoName
        $r.cmd = "$sandbox.cmd.json"; $r.scratch = $c.scratch; $r.stopMB = [math]::Max(1024, $MaxMB * 2)   # the sandbox's own cap (sandbox.ps1)
        [ordered]@{ exe = $c.exe; args = @($c.args) } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $r.cmd -Encoding utf8
        $a += @('-CommandFile', $r.cmd, '-TimeoutSeconds', ($limit + 60), '-MaxMB', ([math]::Max(1024, $MaxMB * 2) + 1024))
    }
    $env:BRAIN_KITCHEN = $sandbox; $env:KITCHEN_UNDER_TEST = '1'; $env:KITCHEN_JOB = $null; $env:KITCHEN_HEARTBEAT = $null; $env:KITCHEN_RUN = $null; $env:KITCHEN_APPROVED = $null; $env:KITCHEN_AGENT_STEP = $null
    try {
        $r.sw = [Diagnostics.Stopwatch]::StartNew()
        $r.p = Start-Process -FilePath $pwshExe -ArgumentList (($a | ForEach-Object { Quote-Arg "$_" }) -join ' ') -WorkingDirectory $Dir -RedirectStandardOutput $r.out -RedirectStandardError $r.err -NoNewWindow -PassThru
        $null = $r.p.Handle   # held now, so the exit code can still be read after the process ends
    } catch { $r.startErr = "FAIL: the test runner could not start this suite: $_" }
    finally { $env:BRAIN_KITCHEN = $saved.k; $env:KITCHEN_JOB = $saved.j; $env:KITCHEN_HEARTBEAT = $saved.h; $env:KITCHEN_RUN = $saved.r; $env:KITCHEN_APPROVED = $saved.a; $env:KITCHEN_AGENT_STEP = $saved.s; $env:KITCHEN_UNDER_TEST = $saved.u }
    $r
}
function Read-Suite($r) {
    $out = $r.startErr; $code = 1
    if (-not $r.startErr) {
        $r.p.WaitForExit(); $code = $r.p.ExitCode
        $out = (@($r.out, $r.err) | ForEach-Object { try { [IO.File]::ReadAllText($_) } catch { '' } }) -join "`n"
    }
    # a sandboxed suite's folders can stay locked for a moment after it ends (seen: empty kt- folders left behind): tried again after the pool
    foreach ($f in $r.sandbox, $r.scratch, $r.out, $r.err, $r.cmd) { if ($f) { try { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction Stop } catch { if (Test-Path -LiteralPath $f) { $leftovers.Add($f) } } } }
    if ($null -eq $code) { $code = 1 }
    @{ out = $out; code = $code; sec = [math]::Round($r.sw.Elapsed.TotalSeconds, 1) }
}
# Machine-wide suite slots: every order's tests station on this kitchen shares the same named mutexes, so 4 orders no longer start up to
# 4 suites each on one PC (10-22 night: Test-PassApp failed in 6 orders' repair steps; it passed 712/0 run alone). A runAlone suite takes
# every slot; while it gathers them it holds the gate, and no suite anywhere starts. A mutex a dead station left is abandoned: the next
# taker gets it, so a crash never leaks a slot. A suite's slots are released by this thread when it ends (mutexes belong to a thread).
$slotKey = 'Local\brain-kitchen-suites-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($kroot).ToLowerInvariant()))).Substring(0, 12)
$slotCount = Get-SuiteParallelCap $coreN
$slotMx = @(0..($slotCount - 1) | ForEach-Object { [Threading.Mutex]::new($false, "$slotKey-slot$_") })
$gateMx = [Threading.Mutex]::new($false, "$slotKey-gate")
$script:slotsHeld = [Collections.Generic.List[int]]::new(); $script:gateHeld = $false
function Enter-Mx($m) { try { $m.WaitOne(0) } catch [Threading.AbandonedMutexException] { $true } }
function Get-SuiteSlots([bool]$all) {
    if ($all) { if (-not $script:gateHeld) { if (-not (Enter-Mx $gateMx)) { return $null }; $script:gateHeld = $true } }
    elseif (-not $script:gateHeld) { if (-not (Enter-Mx $gateMx)) { return $null }; $gateMx.ReleaseMutex() }
    # a mutex is re-entrant for the thread that owns it: skip the slots this station's running suites already hold
    $own = @($running | ForEach-Object { $_.slots }) + @($script:slotsHeld)
    $want = if ($all) { $slotCount } else { 1 }
    for ($i = 0; $i -lt $slotCount -and $script:slotsHeld.Count -lt $want; $i++) { if ($i -notin $own -and (Enter-Mx $slotMx[$i])) { $script:slotsHeld.Add($i) } }
    if ($script:slotsHeld.Count -lt $want) { return $null }   # a runAlone suite keeps what it has gathered (and the gate) for the next pass
    $mine = @($script:slotsHeld); $script:slotsHeld.Clear()
    if ($all) { $gateMx.ReleaseMutex(); $script:gateHeld = $false }
    , $mine
}
function Exit-SuiteSlots($ids) { foreach ($i in @($ids)) { try { $slotMx[$i].ReleaseMutex() } catch { } } }
function Write-Heartbeat {
    # a suite runs silent up to its own limit: no hung call meanwhile
    $q = ($running | ForEach-Object { $_.limit } | Measure-Object -Maximum).Maximum; if (-not $q) { $q = $SuiteTimeoutSec }
    if ($env:KITCHEN_HEARTBEAT) { for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::WriteAllText($env:KITCHEN_HEARTBEAT, "$(Get-Date -Format o) quiet=$([int]$q + 120)"); break } catch [IO.IOException] { Start-Sleep -Milliseconds 50 } } }
}
$swPool = [Diagnostics.Stopwatch]::StartNew(); $beat = [Diagnostics.Stopwatch]::StartNew(); $freeAt = $null; $free = 0; $slotWait = $false; $waitSaid = $false
Write-Output "tests: $($suites.Count) suites, up to $cap at once ($why; machine-wide suite slots: $slotCount)"
while ($queue.Count -or $running.Count) {
    foreach ($r in @($running | Where-Object { $_.startErr -or $_.p.HasExited })) {
        $null = $running.Remove($r); Exit-SuiteSlots $r.slots; $res = Read-Suite $r; $it = $r.item; $s = $it.s
        # one retry: a suite that fails then passes on the same code is flaky (timing under load), not this change's fault; it is logged
        if ($res.code -ne 0 -and -not $it.retry -and -not $r.startErr -and $res.out -notmatch 'crashed before|does not parse' -and -not $stopLaunch) {
            $queue.Insert(0, [pscustomobject]@{ s = $s; retry = $true; first = $res.out; code = $res.code; sec = $res.sec }); continue
        }
        if ($it.retry) {
            if ($res.code -eq 0) {
                $first = (($it.first -split "`r?`n") | Where-Object { $_ -match '^FAIL' } | Select-Object -First 3) -join '; '
                try { [ordered]@{ suite = $s.BaseName; failed = $first; job = $saved.j; at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $kroot 'flaky.jsonl') -Encoding utf8 } catch { }
                $res.out = $res.out + "`nRESULT note: flaky - failed once ($first), passed on retry"; $flakyNames += $s.BaseName
            } else { $res.out = $it.first; $res.code = $it.code }   # what the first run said (and its exit code) is what the repair cook reads
            $res.sec = [math]::Round($res.sec + $it.sec, 1)
        }
        # a suite that crashed before its summary line leaves an empty result, and [string] of that is $null, not '' (J11, J21)
        $summary = "$($res.out -split "`r?`n" | Where-Object { $_ -match 'passed|failed|RESULT' } | Select-Object -Last 1)"
        if (-not $summary.Trim()) { $summary = 'crashed before its summary line' }
        # killed at its time limit or memory cap (TD-EH-16): that is what it says, whatever the suite printed before the kill
        $stop = if ($res.code -ne 0) { Get-SuiteStop $res.code $res.out $r.stopSec $r.stopMB } else { $null }
        if ($stop) { $summary = $stop.summary }
        $line = "{0,-5} {1,-34} {2} ({3}s)" -f $(if ($res.code -eq 0) { 'PASS' } else { 'FAIL' }), $s.BaseName, $summary.Trim(), $res.sec
        Write-Output "tests: $(Hide-VerdictWords $line)"
        $whyLines = @(); $recLines = @()
        if ($res.code -ne 0) {
            $failCount++; $lines = $res.out -split "`r?`n"
            $whyLines = @($lines | Where-Object { $_ -match '^FAIL' } | Select-Object -First 10)
            # no FAIL lines (a crash, a parse error): the last lines of output say what happened, for the repair cook
            if (-not $whyLines.Count) { $whyLines = @($lines | Where-Object { $_.Trim() } | Select-Object -Last 12) }
            $recLines = Get-WhyRecordLines $lines
            # stopped: the plain note goes first (the repair Crew reads TESTS.txt), the suite's own lines after it; the record keeps 12
            if ($stop) { $whyLines = @($stop.note) + $whyLines; $recLines = @(@(Clean-WhyLine $stop.note) + @($recLines) | Select-Object -First 12) }
            # the step log says why too (it outlives the worktree; TESTS.txt does not)
            $whyLines | Select-Object -First 10 | ForEach-Object { Write-WhyLine $_ }
            # -Soft: two red suites are enough for the repair cook; what is still running finishes, nothing new starts
            if ($Soft -and $failCount -ge 2) { $stopLaunch = $true }
        }
        $done[$s.FullName] = @{ line = $line; why = $whyLines; code = $res.code; summary = $summary.Trim(); sec = $res.sec; rec = $recLines; stop = $stop }
    }
    if ($stopLaunch -and $queue.Count) {
        foreach ($q in @($queue)) {
            if ($q.retry) { continue }   # a red suite waiting for its retry still gets it
            $line = "{0,-5} {1,-34} {2}" -f '-', $q.s.BaseName, 'not run (fail fast)'; Write-Output "tests: $line"
            $done[$q.s.FullName] = @{ line = $line; why = @(); code = $null }; $null = $queue.Remove($q)
        }
    }
    while ($queue.Count -and $running.Count -lt $cap) {
        $next = $queue[0]
        if ($running.Count) {
            # runAlone: it waits for an empty pool (its retry too), and while it runs nothing else starts
            if ($alone.Contains($next.s.FullName) -or @($running | Where-Object { $alone.Contains($_.item.s.FullName) }).Count) { break }
            # the budget is checked only next to a running suite: alone, a suite always starts (as it did when every suite ran one at a time)
            if ($FreeMB -gt 0) { $free = $FreeMB } elseif (-not $freeAt -or $freeAt.Elapsed.TotalSeconds -ge 1) { $free = Get-FreeMemoryMB; $freeAt = [Diagnostics.Stopwatch]::StartNew() }
            $nextPeak = Get-SuitePeakMB $hist[$next.s.BaseName]
            if (-not (Test-SuiteBudget @($running | ForEach-Object { [double]$_.peak }) $nextPeak $free)) { break }
        }
        $slots = Get-SuiteSlots $alone.Contains($next.s.FullName)
        if ($null -eq $slots) { $slotWait = $true; break }
        $queue.RemoveAt(0)
        try { $sr = Start-Suite $next; $sr | Add-Member -NotePropertyName slots -NotePropertyValue $slots; $running.Add($sr) }
        catch {
            Exit-SuiteSlots $slots
            # an unexpected error around one suite fails that suite (with where it happened), never the whole station (J11 lost a run that way)
            $line = "{0,-5} {1,-34} {2}" -f 'FAIL', $next.s.BaseName, 'crashed before its summary line'; Write-Output "tests: $line"; $failCount++
            $runnerWhy = "FAIL: the test runner hit an error around this suite: $_ at $($_.ScriptStackTrace -replace '\s+', ' ')"; Write-WhyLine $runnerWhy
            $done[$next.s.FullName] = @{ line = $line; why = @($runnerWhy); code = 1; summary = 'crashed before its summary line'; sec = 0; rec = @(Clean-WhyLine $runnerWhy) }
        }
        if ($running.Count -gt $most) { $most = $running.Count }
        Write-Heartbeat; $beat.Restart()
    }
    if ($beat.Elapsed.TotalSeconds -ge 30) { Write-Heartbeat; $beat.Restart() }
    if ($running.Count) { $w = $running | Where-Object { -not $_.startErr } | Select-Object -First 1; if ($w) { $null = $w.p.WaitForExit(200) } }
    elseif ($slotWait) { if (-not $waitSaid) { Write-Output 'tests: waiting for a free suite slot (other orders are running tests)'; $waitSaid = $true }; Start-Sleep -Milliseconds 500 }
    $slotWait = $false
}
Exit-SuiteSlots @($script:slotsHeld); if ($script:gateHeld) { $gateMx.ReleaseMutex() }
$swPool.Stop()
foreach ($f in $leftovers) { for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $f); $i++) { Start-Sleep -Milliseconds 300; Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue } }
$stuck = @($leftovers | Where-Object { Test-Path -LiteralPath $_ }); if ($stuck.Count) { Write-Output "tests: could not remove $($stuck.Count) suite folder(s) under TEMP: $($stuck -join ', ')" }
Write-Output ("tests: pool: {0} suites in {1}s, at most {2} at once" -f $suites.Count, [math]::Round($swPool.Elapsed.TotalSeconds, 1), $most)
# TESTS.txt and the FAILED list keep the suites' own order, whatever order they finished in
foreach ($s in $suites) {
    $d = $done[$s.FullName]; if (-not $d) { continue }
    $report.Add($d.line); $d.why | ForEach-Object { $report.Add("      $_") }
    if ($d.code -ne 0 -and $null -ne $d.code) { $failed += $s.BaseName }
}
foreach ($sk in $skippedSuites) { $line = "{0,-5} {1,-34} {2}" -f '-', $sk.BaseName, 'not run (not impacted)'; $report.Add($line); Write-Output "tests: $line" }
$final = if ($failed.Count) { "FAILED: $($failed -join ', ')" } elseif ($partial) { "PARTIAL PASS: $($suites.Count) of $($suites.Count + $skippedSuites.Count) suites" } else { 'ALL PASS' }
$report.Add($final)
# Say why (see the header): the reasons for a red run go outside the worktree, into results\<job>.tests-why-<time>.json and a
# tests.failed event. Only a red run writes them; neither write may fail the station (the verdict stands either way, and says so).
if ($failed.Count) {
    $who = if ($job -match '^J\d+$') { $job } else { 'nojob' }
    $ts = (Get-Date).ToUniversalTime(); $recName = "results\$who.tests-why-$($ts.ToString('yyyyMMddTHHmmssfff'))Z.json"
    $red = @(); if ($lintRec) { $red += $lintRec }
    foreach ($s in $suites) {
        $d = $done[$s.FullName]
        if ($d -and $null -ne $d.code -and $d.code -ne 0) {
            $one = [ordered]@{ suite = $s.BaseName; code = [int]$d.code; sec = $d.sec; summary = [string]$d.summary; why = @($d.rec) }
            # stopped (TD-EH-16): 'timeout' with limitSec, or 'memory' with capMB
            if ($d.stop) { $one.stopped = $d.stop.kind; if ($d.stop.kind -eq 'timeout') { $one.limitSec = $d.stop.n } else { $one.capMB = $d.stop.n } }
            $red += $one
        }
    }
    # the short reason: a suite's first FAIL line; for a crash its last line (the error's message), never the boilerplate above it
    $short = (@($red | ForEach-Object {
        $w = [string]@($_.why | Where-Object { $_ -match '^FAIL' })[0]
        if (-not $w) { $w = if (@($_.why).Count) { [string]$_.why[-1] } else { [string]$_.summary } }
        if ($w.Length -gt 120) { $w = $w.Substring(0, 120) }; "$($_.suite): $w" }) -join '; ')
    if ($short.Length -gt 400) { $short = $short.Substring(0, 400) }
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $kroot 'results') | Out-Null
        [ordered]@{ job = $(if ($who -eq 'nojob') { '' } else { $who }); dir = $Dir; sha = $sha0; at = $ts.ToString('o'); final = $final; soft = [bool]$Soft; poolSec = [math]::Round($swPool.Elapsed.TotalSeconds, 1); suites = @($red) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $kroot $recName) -Encoding utf8
        Write-Output "tests: why: $recName"
    } catch { Write-Output "tests: could not write $recName ($_)"; $recName = '' }
    $ev = [ordered]@{ ts = $ts.ToString('o'); type = 'tests.failed'; job = $(if ($who -eq 'nojob') { '' } else { $who }); suites = @($red | ForEach-Object { $_.suite }); why = $short; record = $recName; dir = $Dir; sha = $sha0 } | ConvertTo-Json -Compress -Depth 4
    $sent = $false
    for ($i = 0; $i -lt 6 -and -not $sent; $i++) { try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value $ev -Encoding utf8 -ErrorAction Stop; $sent = $true } catch { Start-Sleep -Milliseconds (50 + (Get-Random -Maximum 150)) } }
    if (-not $sent) { Write-Output 'tests: could not append the tests.failed event (events.jsonl stayed busy)' }
}
# -Only is never the job's whole result (repair's first look at what failed, verify's second look): a pass there is not recorded
if ($ownWorktree -and $job -match '^J\d+$' -and ((-not $partial -and -not $onlyList.Count) -or $failed.Count)) {
    # the commit tested, and nothing changed while the suites ran (a suite that commits or edits code makes this result void)
    $sha1 = "$(& git -C $Dir rev-parse HEAD 2>$null)".Trim(); $dirty = @(& git -C $Dir status --porcelain --untracked-files=no -- . ':(exclude).kitchen' 2>$null)
    $rfinal = if (-not $sha0 -or $sha0 -ne $sha1 -or $dirty.Count) { 'FAILED: the code changed while the tests ran' } else { $final }
    try { $rd = Join-Path $kroot 'results'; New-Item -ItemType Directory -Force -Path $rd | Out-Null; [ordered]@{ job = $job; sha = $sha1; final = $rfinal; flaky = @($flakyNames); at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $rd "$job.tests.json") -Encoding utf8 } catch { }
}
if (Test-Path -LiteralPath (Join-Path $Dir '.kitchen')) { Set-Content -LiteralPath (Join-Path $Dir '.kitchen\TESTS.txt') -Value ($report -join "`n") -Encoding utf8 }
Write-Output "tests: $final"
exit ([int]($failed.Count -gt 0 -and -not $Soft))
