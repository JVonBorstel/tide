# Station: verify the repository after a merge by running the full test station on the main checkout.
# A tree that already passed with the same test files and station versions is not re-run: "verify: cache hit <key> (tested <time>)".
# If tests do not end in ALL PASS, the failing suites are run once more on main (flaky = kept) and then once on the commit before the
# merge (HEAD^1): red there too means main was already red before this order (verify.main-red event, the job file marked, one HIGH
# alert, held for Jordan, nothing undone). Green there means the merge broke it: undoes the merge (kitchen/undo-merge.ps1), emits a
# merge.undone event to events.jsonl with the failing suites, alerts Jordan via notify.ps1 ("$job was undone: it broke main"),
# logs the undo to automerged.jsonl, and purges any exemplar entry for this job from exemplars.jsonl.
# Every verdict about main is also recorded as the Tower's main status (kitchen/main-status.ps1): green, or red with suites, why and since.
# An undo that could not be pushed to GitHub is on the merge.undone event (undoPushed false, undoPushWhy) and in its HIGH alert, and the
# Board shows it (TD-EH-10). When merge.ps1 found main past its last verified tree (TD-EH-25), the blame check is mandatory: a check that
# cannot decide holds for the Owner instead of undoing. A pause of auto-merge after a flaky check is announced once and shown on the Board while it lasts (TD-EH-11).
#   step: {"station":"verify","args":{"Repo":"{{repo}}"},"timeoutSec":2400,"maxMB":4000,"retries":0}
param(
    [Parameter(Mandatory)][string]$Repo,
    [string]$Glob = 'tests\Test-*.ps1',
    [string]$Skip = '',
    [int]$SuiteTimeoutSec = 600,
    [int]$MaxMB = 2000,
    [string]$Job = ''
)
$ErrorActionPreference = 'Stop'

$job = if ($Job) { $Job } else { $env:KITCHEN_JOB }
if ($job -notmatch '^J\d+$') { Write-Output "verify: no kitchen job in the environment or parameters ($job)"; exit 2 }
if (-not (Test-Path -LiteralPath $Repo)) { Write-Output "verify: repository folder not found: $Repo"; exit 2 }

$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$testsStation = Join-Path $PSScriptRoot 'tests.ps1'
if (-not (Test-Path -LiteralPath $testsStation)) { Write-Output "verify: tests station not found at $testsStation"; exit 2 }

# hand the merge train back however verify ends (pass, keep after a flaky rerun, undo, or a crash)
. (Join-Path $PSScriptRoot '..\train.ps1')   # (one train per repo; an old shared merge-train.json naming this order is let go too)
function Release-Train { Clear-TrainClaim $kroot $Repo $job }
# no trap release: a crashed verify leaves main unverified, and the supervisor asks Jordan; the train stays held until then (or its 90-min limit)
# Main status (TD-EH-03a, kitchen/main-status.ps1): every verdict about main is recorded for this Tower (green; or red with the suites, why
# and since when), so the Board's banner and the Toolbox talk show a red main at once (10-23: red 8.5 h, nobody told). Not written when
# nothing about main was proven (a hold, an off-main checkout) or after an undo that leaves main as it was before the merge. A missing
# library or a failed write never changes the verdict; the step log says the status was NOT recorded.
function Save-MainStatus([string]$State, [string[]]$Suites = @(), [string]$Lead = '', [string]$Note = '') {
    $lib = Join-Path $PSScriptRoot '..\main-status.ps1'
    if (-not (Test-Path -LiteralPath $lib)) { Write-Output 'verify: main status NOT recorded (kitchen\main-status.ps1 is missing)'; return }
    try {
        . $lib
        $w = if ($State -eq 'red') { Get-MainRedWhy $kroot "$testOut" $Suites } else { @{ why = ''; record = '' } }
        $r = Set-MainStatus $kroot $Repo $State @($Suites) $(if ($Lead) { "$Lead; $($w.why)" } else { $w.why }) $job $w.record $Note
        Write-Output "verify: main status of $($r.tower) recorded: $State$(if ($State -eq 'red') { " since $($r.since) ($($Suites -join ', '))" })"
    } catch { Write-Output "verify: main status NOT recorded ($($_.Exception.Message))" }
}
$woText = 'Work order WO-' + ($job -replace '^J', '').PadLeft(4, '0')
$pwsh = (Get-Process -Id $PID).Path
# verify checks main, and only main as committed: on another branch or with uncommitted edits the result would say nothing about the
# merge, and an undo would land in the wrong place. Held for Jordan (exit 10), the merge train stays held, nothing is undone.
# "main" is the repo's default branch (origin/HEAD, else main, else master; repo-config.ps1); none found = held, never guessed
. (Join-Path $PSScriptRoot '..\repo-config.ps1')
$vMain = Get-RepoDefaultBranch $Repo; if (-not $vMain) { $vMain = 'main' }
$vBranch = (& git -C $Repo rev-parse --abbrev-ref HEAD 2>$null); $vDirty = @(& git -C $Repo status --porcelain --untracked-files=no 2>$null)
if ($vBranch -ne $vMain -or $vDirty.Count) { Write-Output "verify: the real checkout is $(if ($vBranch -ne $vMain) { "on '$vBranch', not $vMain" } else { "$vMain with uncommitted changes" }); $job is merged but NOT verified, nothing undone"; exit 10 }
# the repo's own per-suite time limit (kitchen.repo.json in this checkout, which IS main); a bad config means main cannot be checked: held
try { $vCfg = Get-RepoConfig $Repo } catch { Write-Output "verify: $($_.Exception.Message); $job is merged but NOT verified, nothing undone"; exit 10 }
if (-not $PSBoundParameters.ContainsKey('SuiteTimeoutSec') -and $vCfg.TestTimeoutSec) { $SuiteTimeoutSec = $vCfg.TestTimeoutSec }
# the supervisor stops verify at the step's time limit (KITCHEN_TIMEOUT), and a stopped verify never reaches its undo. So the slow
# second-chance reruns only run while there is still time for them and the undo before that limit; otherwise a failed suite counts
# as broken (fail closed: the merge is undone rather than left on main unverified).
$deadline = if ([int]$env:KITCHEN_TIMEOUT -gt 0) { (Get-Date).AddSeconds([int]$env:KITCHEN_TIMEOUT - 180) } else { [DateTime]::MaxValue }
# what the merge changed: on main there is no .kitchen\BASE, so without this the sandbox would think nothing changed (sandboxMedium)
$cf = (@(& git -C $Repo diff --name-only 'HEAD^1' HEAD 2>$null) -join ','); if (-not $cf) { $cf = 'unknown' }
# Verify cache (tide performance plan, step 3): this exact tree already passed with these exact tests, so skip the full re-run.
# Key = git tree of HEAD (main as committed: checked clean above) + every file -Glob matches, tracked or not + the text of this station
# and the tests station + -Glob and -Skip. Only a clean ALL PASS is stored: a fail, a hold or a pass-on-retry never is, so a hit always
# means "this exact thing passed before". Entries live in <kitchen>\verify-cache (BRAIN_KITCHEN overrides the kitchen folder).
$cacheDir = Join-Path $kroot 'verify-cache'; $vKey = $null; $vTree = ''
try {
    $vTree = (& git -C $Repo rev-parse 'HEAD^{tree}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $vTree -match '^[0-9a-f]{40,64}$') {
        $sha = [Security.Cryptography.SHA256]::Create()
        $hashOf = { param([byte[]]$b) ([BitConverter]::ToString($sha.ComputeHash($b)) -replace '-', '').ToLowerInvariant() }
        $parts = [Collections.Generic.List[string]]::new(); $parts.Add("tree $vTree"); $parts.Add("glob $Glob"); $parts.Add("skip $Skip")
        foreach ($f in @(Get-ChildItem -Path (Join-Path $Repo $Glob) -File -ErrorAction SilentlyContinue | Sort-Object FullName)) { $parts.Add("test $([IO.Path]::GetRelativePath($Repo, $f.FullName)) $(& $hashOf ([IO.File]::ReadAllBytes($f.FullName)))") }
        foreach ($f in $PSCommandPath, $testsStation) { $parts.Add("station $(Split-Path -Leaf $f) $(& $hashOf ([IO.File]::ReadAllBytes($f)))") }
        $vKey = (& $hashOf ([Text.Encoding]::UTF8.GetBytes($parts -join "`n"))).Substring(0, 32)
    }
} catch { $vKey = $null }
if (-not $vKey) { Write-Output "verify: no cache key (could not read the tree or the test files); running in full" }
else {
    $hit = $null; try { $hp = Join-Path $cacheDir "$vKey.json"; if (Test-Path -LiteralPath $hp) { $hit = Get-Content -LiteralPath $hp -Raw | ConvertFrom-Json } } catch { $hit = $null }
    if ($hit -and [string]$hit.result -eq 'PASS' -and [string]$hit.key -eq $vKey) {
        $at = $hit.tested; if ($at -is [DateTime]) { $at = $at.ToUniversalTime().ToString('o') }
        Write-Output "verify: cache hit $vKey (tested $at)"
        try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value ([ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = 'verify.cached'; job = $job; key = $vKey; tree = $vTree; testedBy = [string]$hit.job } | ConvertTo-Json -Compress) -Encoding utf8 } catch { }
        Write-Output "verify: ALL PASS on $Repo (cached: tree $vTree passed these exact tests for $($hit.job))"
        Save-MainStatus green -Note 'cached pass'
        Release-Train; exit 0
    }
}
# store a clean pass (the newest 500 entries are kept); a failed save only means the next verify of this tree runs in full
function Save-VerifyCache {
    if (-not $vKey) { return }
    try {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $tmp = Join-Path $cacheDir "$vKey.json.tmp"
        [ordered]@{ key = $vKey; result = 'PASS'; tree = $vTree; tested = (Get-Date).ToUniversalTime().ToString('o'); job = $job; repo = $Repo } | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination (Join-Path $cacheDir "$vKey.json") -Force
        @(Get-ChildItem -LiteralPath $cacheDir -Filter '*.json' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 500) | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { Write-Output "verify: could not save the cache entry ($($_.Exception.Message)); the next verify of this tree runs in full" }
}
$testOut =& $pwsh -NoProfile -File $testsStation -Dir $Repo -ChangedFiles $cf -Glob $Glob -Skip $Skip -SuiteTimeoutSec $SuiteTimeoutSec -MaxMB $MaxMB 2>&1 | Out-String
$testCode = $LASTEXITCODE
# exit 10 = the tests station held (the sandbox the config asks for is not built): nothing ran, so nothing says main broke. Held for
# Jordan like an off-main checkout; the merge train stays held and nothing is undone.
if ($testCode -eq 10) { if ($testOut) { Write-Output $testOut.Trim() }; Write-Output "verify: tests held (sandbox not built); $job is merged but NOT verified, nothing undone"; exit 10 }

if ($testOut) { Write-Output $testOut.Trim() }

# a suite that fails and then passes on a retry keeps the merge, but auto-merge stops for 24 h (automerge.ps1 reads automerge.pause):
# a change that breaks a test half the time would otherwise stay on main and the next AI change would merge on top of it
# TD-EH-11: the pause is also told. <kitchen>\automerge-paused.json {until, since, flaky, suites, jobs} is what the Board shows ("Auto-merge
# paused until <time> after N flaky checks", naming the suites): until = 24 h from this pause, the same clock automerge.ps1 reads from
# automerged.jsonl. A pause that is still running is extended: its suites and count grow, its start stays. One alert when a pause
# starts (fixed words, nothing about the order), none when a running pause is extended. A failed write is said in the step log.
function Pause-AutoMerge([string[]]$suites) {
    $now = (Get-Date).ToUniversalTime()
    try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value (@{ ts = $now.ToString('o'); type = 'verify.flaky'; job = $job; suites = @($suites); until = $now.AddHours(24).ToString('o') } | ConvertTo-Json -Compress) -Encoding utf8 } catch { }
    try { [ordered]@{ at = $now.ToString('o'); job = $job; type = 'automerge.pause'; why = "passed only on a retry ($($suites -join ', '))" } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $kroot 'automerged.jsonl') -Encoding utf8 } catch { }
    $pp = Join-Path $kroot 'automerge-paused.json'; $prev = $null; $prevUntil = [DateTime]::MinValue
    try { if (Test-Path -LiteralPath $pp) { $prev = Get-Content -LiteralPath $pp -Raw | ConvertFrom-Json; $u = $prev.until; $prevUntil = if ($u -is [DateTime]) { $u.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$u, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } } } catch { $prev = $null; $prevUntil = [DateTime]::MinValue }
    $running = $prev -and $prevUntil -gt $now
    $since = $now.ToString('o'); if ($running) { $s0 = $prev.since; if ($s0 -is [DateTime]) { $since = $s0.ToUniversalTime().ToString('o') } elseif ($s0) { $since = [string]$s0 } }
    $all = [Collections.Generic.List[string]]::new(); foreach ($s in (@(if ($running) { $prev.suites }) + @($suites))) { if ($s -and -not $all.Contains([string]$s)) { $all.Add([string]$s) } }
    $jobs = [Collections.Generic.List[string]]::new(); foreach ($x in (@(if ($running) { $prev.jobs }) + @($job))) { if ($x -and -not $jobs.Contains([string]$x)) { $jobs.Add([string]$x) } }
    $n = @($suites).Count + $(if ($running) { [int]$prev.flaky } else { 0 })
    $until = $now.AddHours(24).ToString('o')
    try {
        $tmp = "$pp.tmp-$PID"; [ordered]@{ until = $until; since = $since; flaky = $n; suites = @($all); jobs = @($jobs); at = $now.ToString('o') } | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding utf8
        [IO.File]::Move($tmp, $pp, $true)
        Write-Output "verify: auto-merge paused until $until after $n flaky $(if ($n -eq 1) { 'check' } else { 'checks' }) ($($all -join ', ')); the Board shows it"
    } catch { Write-Output "verify: auto-merge is paused, but the Board was NOT told ($($_.Exception.Message))" }
    $notifyScript = Join-Path $PSScriptRoot '..\notify.ps1'
    if (-not $running -and (Test-Path -LiteralPath $notifyScript)) { & $pwsh -NoProfile -File $notifyScript -Level MED -Text "Auto-merge paused for 24 h: a check on main passed only on a retry" -Safe 2>&1 | Out-Null }
}
if ($testCode -eq 0 -and ($testOut.Trim() -match 'ALL PASS\s*$')) {
    if ($testOut -match 'RESULT note: flaky') {
        # the tests station retried a suite inside this run: name the suites whose summary is the flaky note
        $fl = @([regex]::Matches($testOut, '(?m)^tests:\s+PASS\s+(\S+)\s+RESULT note: flaky') | ForEach-Object { $_.Groups[1].Value }); if (-not $fl.Count) { $fl = @('suite') }
        Write-Output "verify: ALL PASS on $Repo, but $($fl -join ', ') passed only on a retry; keeping the merge, auto-merge paused for 24 h"
        Pause-AutoMerge $fl; Save-MainStatus green -Note "passed on a retry ($($fl -join ', '))"; Release-Train; exit 0
    }
    Write-Output "verify: ALL PASS on $Repo"
    Save-VerifyCache
    Save-MainStatus green
    Release-Train; exit 0
}

# Tests did not end in ALL PASS: parse failed suites and revert the merge
# the suites a tests-station run named as red: its "FAILED: a, b" line first, else its "FAIL <suite>" lines (the parent run below reads
# its output the same way)
function Get-FailedSuites([string]$out) {
    $names = [Collections.Generic.List[string]]::new()
    $found = if ($out -match 'FAILED:\s*([^\r\n]+)') { @($Matches[1] -split '[,;]') } else { @([regex]::Matches($out, '(?m)^\s*(?:tests:\s*)?FAIL\s+(\S+)') | ForEach-Object { $_.Groups[1].Value }) }
    foreach ($s in $found) { $clean = "$s".Trim(); if ($clean -and -not $names.Contains($clean)) { $names.Add($clean) } }
    , $names
}
$failedSuites = Get-FailedSuites $testOut
if (-not $failedSuites.Count) {
    $failedSuites.Add('suite')
}

# A suite that failed may only have been slow while the PC was busy (a crash before its summary line, a timeout). Before undoing
# anything, run just the failed suites once more; if they all pass now, it was flaky, not broken: keep the merge and say so.
if (-not $failedSuites.Contains('suite')) {
    $late = [Collections.Generic.List[string]]::new()
    $again = @(foreach ($s in $failedSuites) {
        if ((Get-Date).AddSeconds($SuiteTimeoutSec * 2 + 60) -gt $deadline) { $late.Add($s); $s; continue }
        $o =& $pwsh -NoProfile -File $testsStation -Dir $Repo -ChangedFiles $cf -Glob $Glob -Only $s -Skip $Skip -SuiteTimeoutSec ($SuiteTimeoutSec * 2) -MaxMB $MaxMB 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $o.Trim() -notmatch 'ALL PASS\s*$') { $s }
    })
    if ($late.Count) { Write-Output "verify: no time left before the step's limit to re-run $($late -join ', '); counted as broken" }
    if (-not $again.Count) {
        Write-Output "verify: $($failedSuites -join ', ') passed on a second run; flaky, not broken. Keeping the merge; auto-merge paused for 24 h."
        Pause-AutoMerge @($failedSuites)
        Save-MainStatus green -Note "passed on a second run ($($failedSuites -join ', '))"
        Release-Train; exit 0
    }
    $failedSuites = [Collections.Generic.List[string]]::new([string[]]$again)
}

# Blame check (TD-EH-01, error-handling audit 2026-10-23): a suite that is red after this merge is this merge's fault only if it is green
# on the commit before it. Main went red at 06:20 UTC on 10-23 (a hand merge) and the next two orders were undone for it. So the suites
# still red run once more on HEAD^1 (the merge's first parent) in a throwaway worktree, with the same tests station (bounded runner,
# suite slots), and only those suites. Red there too = main was already red before this order: nothing is undone, a verify.main-red
# event names the suites and the pre-merge commit, the order's job file says it was not at fault, one HIGH alert, held for Jordan
# (exit 10), and the train is let go (main is red whoever merges next). Green there = the merge broke it: undone as before. Only proof
# spares a merge: no parent, no time left before the step's limit, or a parent run that gives no verdict = the check could not decide,
# and verify goes on exactly as before it existed (fail closed: undone), saying the check could not run and why.
# "The commit before the merge" is the first parent of this order's own merge commit, found the way undo-merge.ps1 finds it; HEAD^1 when
# no such merge is found (verify runs straight after the merge, so HEAD is the merge then). Later commits on top never shift the blame.
# Returns @{ ok; why (when not ok); red = suites red on the parent; sha = the parent; out = the parent run's output }.
function Get-PreMergeSha {
    $m = ''
    foreach ($grep in "^Merge kitchen/$job ", "^Merge kitchen/$job\b", "^Merge pull request #[0-9][0-9]* from [^ ]*/kitchen/$job`$") {
        if (-not $m) { $m = "$(& git -C $Repo log --merges --format=%H "--grep=$grep" -n 1 2>$null)".Trim() }
    }
    $ref = if ($m -match '^[0-9a-f]{40,64}$') { "$m^1" } else { 'HEAD^1' }
    "$(& git -C $Repo rev-parse --verify --quiet $ref 2>$null)".Trim()
}
function Test-ParentRed([string[]]$suites) {
    $parent = Get-PreMergeSha
    if ($parent -notmatch '^[0-9a-f]{40,64}$') { return @{ ok = $false; why = 'no commit before the merge to compare with' } }
    $short = $parent.Substring(0, 12)
    if ((Get-Date).AddSeconds($SuiteTimeoutSec * 2 + 60) -gt $deadline) { return @{ ok = $false; why = "no time left before the step's limit to run $($suites -join ', ') on $short" } }
    # a throwaway checkout under TEMP; one left by an earlier run of this order that was stopped mid-check is swept first
    foreach ($old in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter "verify-parent-$job-*" -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    & git -C $Repo worktree prune 2>&1 | Out-Null
    $wt = Join-Path ([IO.Path]::GetTempPath()) ("verify-parent-$job-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $wo = & git -C $Repo worktree add --detach $wt $parent 2>&1 | Out-String
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $wt)) { return @{ ok = $false; why = "could not check out $short to compare ($($wo.Trim()))" } }
    try {
        $o =& $pwsh -NoProfile -File $testsStation -Dir $wt -ChangedFiles $cf -Glob $Glob -Only ($suites -join ',') -Skip $Skip -SuiteTimeoutSec ($SuiteTimeoutSec * 2) -MaxMB $MaxMB 2>&1 | Out-String
        $c = $LASTEXITCODE
    } finally {
        & git -C $Repo worktree remove --force $wt 2>&1 | Out-Null
        if (Test-Path -LiteralPath $wt) { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue; & git -C $Repo worktree prune 2>&1 | Out-Null }
    }
    $red = Get-FailedSuites $o
    # a suite the merge itself added is not on the parent ("no suites match"): nothing was red there, so the merge is to blame for it
    $noVerdict = ($c -eq 10) -or ($c -ne 0 -and -not $red.Count -and $o -notmatch 'no suites match') -or ($c -eq 0 -and $o.Trim() -notmatch 'ALL PASS\s*$')
    if ($noVerdict) { return @{ ok = $false; why = "the tests station gave no verdict on $short (exit $c)"; out = $o } }
    @{ ok = $true; red = @($red); sha = $parent; out = $o }
}
function Set-JobMainRed([string[]]$suites, [string]$parent) {
    $jp = Join-Path $kroot "jobs\$job.json"
    if (-not (Test-Path -LiteralPath $jp)) { Write-Output "verify: no job file at $jp to mark"; return }
    try {
        $jj = Get-Content -LiteralPath $jp -Raw | ConvertFrom-Json
        $mark = [ordered]@{ why = "main was already red, not this order's fault"; suites = @($suites); preMergeSha = $parent; at = (Get-Date).ToUniversalTime().ToString('o') }
        $jj | Add-Member -NotePropertyName mainRed -NotePropertyValue $mark -Force
        $tmp = "$jp.tmp-verify-$PID"; $jj | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding utf8
        [IO.File]::Move($tmp, $jp, $true)
    } catch { Write-Output "verify: could not mark $job's job file ($($_.Exception.Message)); the verify.main-red event still says so" }
}
$alreadyRed = @(); $preMerge = ''; $pr = $null
if (-not $failedSuites.Contains('suite')) {
    Write-Output "verify: running $($failedSuites -join ', ') on the commit before this merge to see whether main was already red"
    $pr = Test-ParentRed @($failedSuites)
    if ($pr.out) { Write-Output $pr.out.Trim() }
}
# TD-EH-25: main was past its last verified tree when this order merged (merge.ps1's results\<job>.merge.json: pastVerified > 0, or null =
# unknown; a file that cannot be read is unknown too): main may have been red before it, so the blame check is mandatory. When it could not
# decide (or could not run: no suite named), nothing is undone: held for the Owner (exit 10), main recorded red, a verify.blame-unknown event,
# the train let go (main is red whoever merges next; Site closed when red stops the next merge). No merge.json, or one without pastVerified
# (written before TD-EH-25): as before.
$gapWords = ''
$mjPath = Join-Path $kroot "results\$job.merge.json"
if (Test-Path -LiteralPath $mjPath) {
    try {
        $mj = Get-Content -LiteralPath $mjPath -Raw | ConvertFrom-Json
        if ($mj.PSObject.Properties.Name -contains 'pastVerified') {
            if ($null -eq $mj.pastVerified) { $gapWords = 'an unknown number of' } elseif ([int]$mj.pastVerified -gt 0) { $gapWords = "$([int]$mj.pastVerified)" }
        }
    } catch { $gapWords = 'an unknown number of'; Write-Output "verify: results\$job.merge.json cannot be read ($($_.Exception.Message)); how far main was from its last verified tree is unknown" }
}
$undecided = if ($failedSuites.Contains('suite')) { 'the failing suites could not be named' } elseif ($pr -and -not $pr.ok) { [string]$pr.why } else { '' }
if ($gapWords -and $undecided) {
    Write-Output "verify: main was $gapWords commits past its last verified tree when $job merged, so the blame check is mandatory; it could not decide ($undecided): nothing undone, held for the Owner"
    try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value ([ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = 'verify.blame-unknown'; job = $job; suites = @($failedSuites); why = $undecided; pastVerified = $gapWords } | ConvertTo-Json -Compress) -Encoding utf8 } catch { Write-Output "verify: the verify.blame-unknown event was NOT written ($($_.Exception.Message))" }
    Save-MainStatus red @($failedSuites) "red after $woText merged; whether it was red before is unknown"
    Release-Train; exit 10
}
if ($pr -and -not $pr.ok) {
    Write-Output "verify: the blame check could not run ($($pr.why)); whether main was already red before $job is unknown, so it is treated as before: counted as broken"
}
elseif ($pr) {
    $preMerge = $pr.sha
    $alreadyRed = @($failedSuites | Where-Object { $pr.red -contains $_ })
    $blamed = @($failedSuites | Where-Object { $pr.red -notcontains $_ })
    $preShort = $pr.sha.Substring(0, 12)
    if (-not $blamed.Count) {
        $headSha = "$(& git -C $Repo rev-parse HEAD 2>$null)".Trim()
        try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value ([ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = 'verify.main-red'; job = $job; suites = @($alreadyRed); why = "main was already red, not this order's fault"; preMergeSha = $pr.sha; sha = $headSha } | ConvertTo-Json -Compress) -Encoding utf8 } catch { }
        Set-JobMainRed $alreadyRed $pr.sha
        Save-MainStatus red @($alreadyRed) "red before $woText merged"
        $notifyScript = Join-Path $PSScriptRoot '..\notify.ps1'
        if (Test-Path -LiteralPath $notifyScript) { & $pwsh -NoProfile -File $notifyScript -Level HIGH -Text "$job merged onto a main that was already red; nothing undone, needs a look" -Safe 2>&1 | Out-Null }
        Release-Train
        Write-Output "verify: main was already red before $job ($($alreadyRed -join ', ') also fail on $preShort, the commit before this merge); nothing undone"
        exit 10
    }
    if ($alreadyRed.Count) { Write-Output "verify: $($alreadyRed -join ', ') already fail on $preShort (main was red before $job); not counted against this order" }
    Write-Output "verify: $($blamed -join ', ') pass on $preShort (the commit before this merge) and fail after it: this merge is to blame"
    $failedSuites = [Collections.Generic.List[string]]::new([string[]]$blamed)
}

$why = "broke main ($($failedSuites -join ', '))"
Write-Output "verify: $why; running undo-merge for $job"

# 1. Run undo-merge.ps1 (it refuses when the checkout has uncommitted changes or later work builds on the merge)
$undone = $false; $undoMsg = 'undo script not found'; $undoPushed = $null; $undoPushWhy = ''
$undoScript = Join-Path $PSScriptRoot '..\undo-merge.ps1'
if (Test-Path -LiteralPath $undoScript) {
    $undoOut = & $pwsh -NoProfile -File $undoScript -Job $job -Repo $Repo -Why $why -Json 2>&1 | Out-String
    Write-Output "verify: undo-merge output: $($undoOut.Trim())"
    try { $u = ($undoOut.Trim() -split "`r?`n")[-1] | ConvertFrom-Json; $undone = [bool]$u.ok; $undoMsg = [string]$u.message; $undoPushed = $u.pushed; $undoPushWhy = [string]$u.pushWhy } catch { $undoMsg = $undoOut.Trim() }
}
if (-not $undone) {
    # main is broken and could NOT be undone: say exactly that (never claim an undo that did not happen)
    try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value ([ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = 'merge.broken'; job = $job; suites = @($failedSuites); why = $why; undo = $undoMsg } | ConvertTo-Json -Compress) -Encoding utf8 } catch { }
    Save-MainStatus red @(@($failedSuites) + @($alreadyRed) | Select-Object -Unique) "$woText broke main and could not be undone"
    $notifyScript = Join-Path $PSScriptRoot '..\notify.ps1'
    if (Test-Path -LiteralPath $notifyScript) { & $pwsh -NoProfile -File $notifyScript -Level HIGH -Text "$job broke main and could not be undone automatically; needs a look" -Safe 2>&1 | Out-Null }
    Write-Output "verify: FAILED - $why; undo refused: $undoMsg"
    Release-Train; exit 1
}

# 2. Emit merge.undone event to events.jsonl
$ev = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    type = 'merge.undone'
    job = $job
    suites = @($failedSuites)
    why = $why
}
if ($preMerge) { $ev['preMergeSha'] = $preMerge }                 # the blame check ran: these suites pass there
if ($alreadyRed.Count) { $ev['alreadyRed'] = @($alreadyRed) }   # red on the parent too: main's, not this order's
# TD-EH-10: whether the undo reached GitHub (undo-merge.ps1's pushed/pushWhy). false = main here is now ahead of GitHub's and later PR
# merges hold until it is pushed by hand; left out when the order never went through GitHub (nothing to push)
if ($null -ne $undoPushed) { $ev['undoPushed'] = [bool]$undoPushed; if (-not $undoPushed) { $ev['undoPushWhy'] = $(if ($undoPushWhy) { $undoPushWhy } else { 'no reason was given' }) } }
try {
    Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value ($ev | ConvertTo-Json -Compress) -Encoding utf8
} catch { }
# main is back to the commit before the merge: still red only where the blame check proved it red there; otherwise left as it was
if ($alreadyRed.Count) { Save-MainStatus red @($alreadyRed) "red before $woText merged (its merge was undone)" }
else { Write-Output 'verify: main status left as it was (the undo puts main back to before this merge; the next verify records it)' }

# 3. Alert Jordan via notify.ps1
$notifyScript = Join-Path $PSScriptRoot '..\notify.ps1'
$unpushed = ($null -ne $undoPushed) -and -not $undoPushed
if ($unpushed) { Write-Output "verify: the undo is NOT on GitHub ($(if ($undoPushWhy) { $undoPushWhy } else { 'no reason was given' })): main on this PC is ahead of GitHub, and later merges hold until it is pushed by hand" }
if (Test-Path -LiteralPath $notifyScript) {
    # one HIGH alert either way; an undo that did not reach GitHub says so in fixed words (TD-EH-10)
    if ($unpushed) { & $pwsh -NoProfile -File $notifyScript -Level HIGH -Text "$job was undone: it broke main. The undo could not be pushed: main on this PC is ahead of GitHub" -Safe 2>&1 | Out-Null }
    else { & $pwsh -NoProfile -File $notifyScript -Level HIGH -Text "$job was undone: it broke main" -Safe 2>&1 | Out-Null }
}

# 4. Ensure { at, job, undone, why } is recorded in automerged.jsonl
$amPath = Join-Path $kroot 'automerged.jsonl'
$hasAmRecord = $false
if (Test-Path -LiteralPath $amPath) {
    try {
        foreach ($line in [IO.File]::ReadLines($amPath)) {
            if ($line -match "`"job`"\s*:\s*`"$job`"" -and $line -match '"undone"') { $hasAmRecord = $true; break }
        }
    } catch { }
}
if (-not $hasAmRecord) {   # undone 'unknown' + type merge.undone: automerge.ps1 must count it as an undo (24 h pause), never as a merge toward the cap
    try {
        [ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); job = $job; undone = 'unknown'; type = 'merge.undone'; why = $why } |
            ConvertTo-Json -Compress | Add-Content -LiteralPath $amPath -Encoding utf8
    } catch { }
}

# 5. Purge any exemplar entry for $job from exemplars.jsonl
$exPath = Join-Path $kroot 'exemplars.jsonl'
if (Test-Path -LiteralPath $exPath) {
    try {
        $lines = @(Get-Content -LiteralPath $exPath)
        $kept = [Collections.Generic.List[string]]::new()
        foreach ($l in $lines) {
            if (-not $l -or -not $l.Trim()) { continue }
            try {
                $e = $l | ConvertFrom-Json
                if ($e.job -ne $job) { $kept.Add($l) }
            } catch {
                $kept.Add($l)
            }
        }
        Set-Content -LiteralPath $exPath -Value ($kept -join "`n") -Encoding utf8
    } catch { }
}

# 6. The undo reverted Chef server code (pass-app outside public/): put the reverted server live too, so Jordan's phone never keeps
# running code main no longer has. Same rules as the supervisor's update: bounded, and a dry run unless this is the real kitchen.
try {
    $revFiles = @(& git -C $Repo diff --name-only HEAD~1 HEAD 2>$null | Where-Object { $n = ([string]$_) -replace '\\', '/'; $n -match '(^|/)pass-app/' -and $n -notmatch '(^|/)pass-app/public/' })
    if ($revFiles.Count) {
        $upd = if ($env:KITCHEN_CHEF_UPDATE_SCRIPT) { $env:KITCHEN_CHEF_UPDATE_SCRIPT } else { Join-Path $Repo 'pass-app\update.ps1' }
        $isProd = try { [IO.Path]::GetFullPath($kroot) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen')) } catch { $false }
        $dry = if ($env:KITCHEN_CHEF_UPDATE_DRYRUN -eq '1') { $true } elseif ($env:KITCHEN_CHEF_UPDATE_DRYRUN -eq '0') { $false } else { -not $isProd -and -not $env:KITCHEN_CHEF_UPDATE_SCRIPT }
        $bounded = Join-Path $PSScriptRoot '..\..\scripts\run-bounded.ps1'
        $uo = 'update script not found'; $uc = 1
        if (Test-Path -LiteralPath $upd) { $uo = & $pwsh -NoProfile -NonInteractive -File $bounded -Script $upd -TimeoutSeconds 240 @(if ($dry) { '-ScriptArgs', '-DryRun' }) 2>&1 | Out-String; $uc = $LASTEXITCODE }
        $uo = $uo.Trim(); if ($uo.Length -gt 300) { $uo = $uo.Substring(0, 300) }
        $ue = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = $(if ($uc -eq 0) { 'chef.updated' } else { 'chef.update.failed' }); job = $job; after = 'undo'; files = @($revFiles); detail = $uo }
        try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value ($ue | ConvertTo-Json -Compress) -Encoding utf8 } catch { }
        Write-Output "verify: Chef server put back on the reverted code: $(if ($uc -eq 0) { 'ok' } else { "FAILED ($uo)" })"
        if ($uc -ne 0) { $notifyScript = Join-Path $PSScriptRoot '..\notify.ps1'; if (Test-Path -LiteralPath $notifyScript) { & $pwsh -NoProfile -File $notifyScript -Level HIGH -Text "$job was undone but the Chef server could not be put back; needs a look" -Safe 2>&1 | Out-Null } }
    }
} catch { Write-Output "verify: Chef server rollback check failed: $($_.Exception.Message)" }

Write-Output "verify: FAILED - $why"
Release-Train; exit 1
