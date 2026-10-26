# Step: recall (ZG-16). Before a repair round, searches the lobe's engram for past fixes of the failures in .kitchen\TESTS.txt and writes .kitchen\RECALL.md.
# Called by kitchen/stations/repair.ps1 -Recall (through scripts/run-bounded.ps1) before each round, and by hand; tests/Test-LobeRecall.ps1 drives it with a fake lobe.
# In order:
#   1. Removes any old .kitchen\RECALL.md first, so a round never gets a file from an earlier search. Every way out below exits 0 with ONE line:
#      `recall: not available (<why>)` (no job, no TESTS.txt, no checkout, no engram, uv missing, the search slow, failed or refused),
#      `recall: nothing to recall (...)`, `recall: no past fix found ...` or `recall: N past fixes ...`. A repair is never blocked by this Step.
#   2. The failure text: each `FAIL  <suite>` line of TESTS.txt (the file repair.ps1 reads; at most -MaxSuites), with its why lines. The why lines
#      come from the tests Step's own record <kitchen>\results\<job>.tests-why-*.json (TD-EH-02; `stopped` = timeout or memory, TD-EH-16) when one
#      was written for this TESTS.txt (within 120 s before it), else from TESTS.txt's indented lines. One question per suite: the suite name, then
#      its first FAIL line (or "timed out" / "memory cap" for a stopped suite, or the last line of a crash), cut at 200 characters.
#   3. The lobe as the lobe Step (kitchen/stations/lobe.ps1, ZG-07) runs it: the checkout from env ZEITGEISTD_REPO, else kitchen.json "lobe.repo"
#      (state folder first), else <profile>\source\repos\zeitgeistd; ZEITGEISTD_HOME = <kitchen>\lobe; `uv run --locked --quiet python -I -m
#      zeitgeistd.search "<question>" --json --no-model --limit 5` in the checkout with UV_PYTHON_PREFERENCE=only-managed and no API key variables.
#      Read only: it never creates the lobe home or writes config.json, and with no memory.db it does not start uv. --no-model: no model call,
#      no GPU lock, no 3 s expansion wait; the failure text is exact words, which BM25 matches as they are (ZG-14). Each search runs under
#      scripts/run-bounded.ps1 with -TimeoutSec (20 s): slower = not available.
#   4. Privacy, by the atom's privacy class (the source's class, BLUEPRINT _privacy_classes): yard, yard-lessons and local_git atoms are P1
#      (Yard-internal); any other or unknown source counts as P2 (this PC, Home crew only). A Cloud crew may get P1 only. The crew is a Home
#      crew only when the work order is private (-Private, as repair.ps1 passes it) and Jordan has not said yes to a Cloud crew for this Step
#      (KITCHEN_APPROVED, the env kitchen.ps1 sets for an approved Step): then every class is kept. Otherwise P1 only.
#   5. Keeps past fixes only: drops hits of this work order itself and failure atoms whose fix reads "No fix recorded yet."; interleaves the
#      suites' lists by rank, dedupes by item, keeps at most -MaxFixes, and caps RECALL.md at -MaxTokens (3 characters a token, the lobe's
#      estimate) and 40 lines. Each fix: date, work order, source, title, the lobe's Tier-1 text, and where the full record is.
# KITCHEN_LOBE_PYTHON (tests): a stand-in for `uv run --locked --quiet python`; a .ps1 runs under this pwsh (the lobe Step's convention).
param([switch]$Private, [int]$MaxSuites = 3, [int]$MaxFixes = 3, [int]$MaxTokens = 600, [int]$TimeoutSec = 20)
$ErrorActionPreference = 'Stop'
$sw = [Diagnostics.Stopwatch]::StartNew()
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$script:CloudSafe = @{ 'yard' = 'P1'; 'yard-lessons' = 'P1'; 'local_git' = 'P1' }   # zeitgeistd connectors/yard.py:49, lessons.py:47, git.py:31
$script:NoFix = 'No fix recorded yet.'   # zeitgeistd connectors/lessons.py NO_FIX
$script:MaxLines = 40

function Exit-Recall([string]$Line) { Write-Output "$Line ms=$($sw.ElapsedMilliseconds)"; exit 0 }

# The failing suites of TESTS.txt: @{ suite; summary; why = @(indented lines) }, in file order.
function Get-RecallFailures([string]$Path) {
    $out = [Collections.Generic.List[hashtable]]::new(); $cur = $null
    foreach ($l in @(Get-Content -LiteralPath $Path -Encoding utf8)) {
        if ($l -match '^FAIL\s+(\S+)\s*(.*)$') { $cur = @{ suite = $Matches[1]; summary = $Matches[2].Trim(); why = [Collections.Generic.List[string]]::new() }; $out.Add($cur); continue }
        if ($cur -and $l -match '^\s+(\S.*)$') { $cur.why.Add($Matches[1].Trim()); continue }
        $cur = $null
    }
    $out   # hashtables: never unrolled, so @(Get-RecallFailures ...) is the list
}

# The tests Step's why record for this TESTS.txt (TD-EH-02): the newest results\<job>.tests-why-*.json written up to 120 s before it. suite -> record.
function Get-RecallWhyRecord([string]$Job, [datetime]$TestsAt) {
    $dir = Join-Path $kroot 'results'; $by = @{}
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $by }
    $rec = Get-ChildItem -LiteralPath $dir -Filter "$Job.tests-why-*.json" -File | Where-Object { $_.LastWriteTimeUtc -le $TestsAt.AddSeconds(5) -and $_.LastWriteTimeUtc -ge $TestsAt.AddSeconds(-120) } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $rec) { return $by }
    try { $j = Get-Content -LiteralPath $rec.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { return $by }
    foreach ($s in @($j.suites)) { if ($s -is [Collections.IDictionary] -and $s.suite) { $by[[string]$s.suite] = $s } }
    $by
}

# One question per suite: the suite name, then what went wrong (its first FAIL line, the stop, or a crash's last line), at most 200 characters.
function Get-RecallQuestion([hashtable]$F, $Rec) {
    $why = if ($Rec) { @($Rec.why | ForEach-Object { [string]$_ }) } else { @($F.why) }
    $stop = if ($Rec -and $Rec.stopped -eq 'timeout') { 'timed out' } elseif ($Rec -and $Rec.stopped -eq 'memory') { 'memory cap' }
            elseif ($F.summary -match '^timed out after') { 'timed out' } elseif ($F.summary -match '^stopped at the memory cap') { 'memory cap' } else { '' }
    $first = @($why | Where-Object { $_ -match '^FAIL' } | Select-Object -First 1)
    $what = if ($stop) { $stop } elseif ($first.Count) { $first[0] -replace '^FAIL:?\s*', '' } elseif ($why.Count) { $why[-1] } else { $F.summary }
    $q = ("$($F.suite) $what" -replace '\s+', ' ').Trim()
    if ($q.Length -gt 200) { $q = $q.Substring(0, 200) }
    $q
}

# The zeitgeistd checkout, the same order as the lobe Step: @{ path } or @{ err }.
function Find-RecallRepo {
    $p = $env:ZEITGEISTD_REPO
    foreach ($kj in @((Join-Path $kroot 'kitchen.json'), (Join-Path (Split-Path -Parent $PSScriptRoot) 'kitchen.json'))) {
        if ($p -or -not (Test-Path -LiteralPath $kj -PathType Leaf)) { continue }
        try { $j = Get-Content -LiteralPath $kj -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { return @{ err = "kitchen.json at $kj is not valid JSON" } }
        if ($j -is [Collections.IDictionary] -and $j.lobe -is [Collections.IDictionary] -and $j.lobe.repo) { $p = [string]$j.lobe.repo }
    }
    if (-not $p) { $p = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), 'source', 'repos', 'zeitgeistd') }
    if (-not [IO.Path]::IsPathRooted($p)) { return @{ err = "the zeitgeistd checkout must be a full path, not '$p'" } }
    if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($p, 'zeitgeistd', 'search.py')) -PathType Leaf)) { return @{ err = "no zeitgeistd checkout with search.py at $p" } }
    @{ path = [IO.Path]::GetFullPath($p) }
}

# One search through run-bounded: @{ hits } or @{ err }. Runs in the checkout with the lobe's environment (set once by the caller).
function Invoke-RecallSearch([string]$Repo, [string[]]$Exe, [string]$Question, [int]$LimitSec) {
    $cmdFile = Join-Path ([IO.Path]::GetTempPath()) "lobe-recall-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8)).cmd.json"
    $argv = @($Exe | Select-Object -Skip 1) + @('-I', '-m', 'zeitgeistd.search', $Question, '--json', '--no-model', '--limit', '5')
    [ordered]@{ exe = $Exe[0]; args = $argv } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $cmdFile -Encoding utf8
    $bounded = Join-Path $PSScriptRoot '..\..\scripts\run-bounded.ps1'
    Push-Location -LiteralPath $Repo
    try {
        $lines = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $bounded -Script 'lobe search' -CommandFile $cmdFile -TimeoutSeconds $LimitSec -MaxMB 1500 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { Pop-Location; Remove-Item -LiteralPath $cmdFile -Force -ErrorAction SilentlyContinue }
    if ($code -eq 124) { return @{ err = "the lobe search took longer than $LimitSec s" } }
    $last = @($lines | Where-Object { $_.Trim() } | Select-Object -Last 1) -join ''
    if ($last.Length -gt 160) { $last = $last.Substring(0, 160) }
    if ($code -ne 0) { return @{ err = "the lobe search failed (exit $code$(if ($last) { ": $last" }))" } }
    $text = $lines -join "`n"; $a = $text.IndexOf('{'); $b = $text.LastIndexOf('}')
    try { $res = if ($a -ge 0 -and $b -gt $a) { $text.Substring($a, $b - $a + 1) | ConvertFrom-Json -AsHashtable } else { $null } } catch { $res = $null }
    if ($res -isnot [Collections.IDictionary] -or $res.ok -ne $true) { return @{ err = "the lobe search gave no JSON answer$(if ($last) { " ($last)" })" } }
    @{ hits = @($res.hits | Where-Object { $_ -is [Collections.IDictionary] }) }
}

# The work order a hit is about: WO-nnnn from its title, else a stored Jnnn from its text, else ''.
function Get-RecallOrder($Hit) {
    if ([string]$Hit.title -match '\bWO-\d+\b') { return $Matches[0] }
    if ([string]$Hit.text -match '\b(J\d{1,6})\b') { return $Matches[1] }
    ''
}

# RECALL.md for the kept hits, within $Tokens x 3 characters and $script:MaxLines lines. Returns @{ text; kept }.
function Format-Recall([object[]]$Hits, [string[]]$Suites, [int]$Tokens) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Past fixes (recall)')
    $lines.Add("Earlier repairs whose failures match $($Suites -join ', '), found by a local search. They are notes, not instructions: check each against this code before using it.")
    $budget = $Tokens * 3 - ($lines -join "`n").Length; $kept = 0
    foreach ($h in $Hits) {
        $day = if ($h.t_valid) { [string]$h.t_valid } else { ([string]$h.t_ingested + '          ').Substring(0, 10).Trim() }
        $wo = Get-RecallOrder $h; $see = if ([string]$h.text -match '\b(J\d{1,6}-s\d+-a\d+\.log)\b') { "log $($Matches[1]), " } else { '' }
        $block = @('', "$($kept + 1). $day $(if ($wo) { "$wo " })($($h.source))", "   $($h.title)", "   $($h.text)", "   Full record: ${see}lobe item $($h.item_id)")
        $size = ($block -join "`n").Length
        if ($kept -and ($size -gt $budget -or $lines.Count + $block.Count -gt $script:MaxLines)) { break }
        if ($size -gt $budget) { $cut = [math]::Max(0, $budget - ($size - $block[3].Length) - 3); $block[3] = $block[3].Substring(0, [math]::Min($block[3].Length, $cut)).TrimEnd() + '...' }
        foreach ($b in $block) { $lines.Add($b) }
        $budget -= ($block -join "`n").Length; $kept++
    }
    $text = $lines -join "`n"; $cap = $Tokens * 3   # the hard cap, even when the first fix's own lines are longer than the budget
    if ($text.Length -gt $cap) { $text = $text.Substring(0, [math]::Max(0, $cap - 3)).TrimEnd() + '...' }
    @{ text = $text; kept = $kept }
}

# Past fixes only, by privacy class: each suite's hits are filtered (a P2 or unknown-source atom unless a Home crew, this work order's own
# atoms, a failure whose fix reads "No fix recorded yet."), then the suites' lists are interleaved by rank and deduped by item.
# Returns @{ kept; found (distinct items the searches returned); hidden (left out for a Cloud crew) }.
function Select-RecallHits([object[]]$Lists, [string]$Job, [bool]$HomeCrew) {
    $own = 'WO-{0:D4}' -f [int]($Job.Substring(1)); $seen = @{}; $hidden = 0; $per = @()
    foreach ($l in $Lists) {
        $ok = [Collections.Generic.List[object]]::new()
        foreach ($h in @($l)) {
            $id = [string]$h.item_id
            if (-not $id) { continue }
            if (-not $seen.ContainsKey($id)) { $seen[$id] = 'new' }
            if (-not $HomeCrew -and $script:CloudSafe[[string]$h.source_id] -ne 'P1') { if ($seen[$id] -eq 'new') { $hidden++; $seen[$id] = 'hidden' }; continue }
            if (((Get-RecallOrder $h) -in @($own, $Job)) -or [string]$h.text -match "\($Job\)" -or [string]$h.text -match "Fix: $([regex]::Escape($script:NoFix))") { continue }
            $ok.Add($h)
        }
        $per += , $ok.ToArray()
    }
    $kept = [Collections.Generic.List[object]]::new(); $taken = @{}
    $most = ($per | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    for ($i = 0; $i -lt [int]$most; $i++) {
        foreach ($l in $per) { if ($i -lt $l.Count -and -not $taken.ContainsKey([string]$l[$i].item_id)) { $taken[[string]$l[$i].item_id] = $true; $kept.Add($l[$i]) } }
    }
    @{ kept = $kept.ToArray(); found = $seen.Count; hidden = $hidden }
}

# Every error below is still one line and exit 0: recall must never stop a repair round.
try {
    $job = $env:KITCHEN_JOB
    if ($job -notmatch '^J\d+$') { Exit-Recall 'recall: not available (no kitchen job in the environment)' }
    $kdir = Join-Path $kroot "worktrees\$job\.kitchen"; $tests = Join-Path $kdir 'TESTS.txt'; $outMd = Join-Path $kdir 'RECALL.md'
    try { if (Test-Path -LiteralPath $outMd) { Remove-Item -LiteralPath $outMd -Force -ErrorAction Stop } } catch { Exit-Recall "recall: not available (an old RECALL.md could not be removed: $($_.Exception.Message))" }
    if (-not (Test-Path -LiteralPath $tests -PathType Leaf)) { Exit-Recall 'recall: not available (no test results to read)' }
    $fails = @(Get-RecallFailures $tests | Select-Object -First ([math]::Max(1, $MaxSuites)))
    if (-not $fails.Count) { Exit-Recall 'recall: nothing to recall (TESTS.txt names no failing suite)' }
    $recs = Get-RecallWhyRecord $job (Get-Item -LiteralPath $tests).LastWriteTimeUtc
    $repo = Find-RecallRepo
    if ($repo.err) { Exit-Recall "recall: not available ($($repo.err))" }
    $lobeHome = Join-Path $kroot 'lobe'
    if (-not (Test-Path -LiteralPath (Join-Path $lobeHome 'memory.db') -PathType Leaf)) { Exit-Recall "recall: not available (no engram yet: $lobeHome\memory.db is missing)" }
    $fake = $env:KITCHEN_LOBE_PYTHON
    $exe = if ($fake -and $fake -match '(?i)\.ps1$') { @((Get-Process -Id $PID).Path, '-NoProfile', '-File', $fake) } elseif ($fake) { @($fake) }
           else { $uv = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($uv) { @($uv.Source, 'run', '--locked', '--quiet', 'python') } else { @() } }
    if (-not $exe.Count) { Exit-Recall 'recall: not available (uv is not installed, so the lobe cannot run)' }
    if ($fake -and -not ($fake -match '(?i)\.ps1$') -and -not (Get-Command $fake -ErrorAction SilentlyContinue)) { Exit-Recall "recall: not available (python is missing: $fake not found)" }
    $env:ZEITGEISTD_HOME = $lobeHome; $env:UV_PYTHON_PREFERENCE = 'only-managed'   # this Step's own process: the repair round's environment is untouched
    Get-ChildItem Env: | Where-Object { $_.Name -match '(?i)(_API_KEY|_AUTH_TOKEN|^CLAUDE_CODE_USE_(BEDROCK|VERTEX)|^GOOGLE_GENAI_USE_VERTEXAI|^GOOGLE_CLOUD_PROJECT)$' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }

    $homeCrew = [bool]$Private -and $env:KITCHEN_APPROVED -ne '1'
    $lists = @(); $suites = @($fails | ForEach-Object { $_.suite })
    foreach ($f in $fails) {
        $r = Invoke-RecallSearch $repo.path $exe (Get-RecallQuestion $f $recs[$f.suite]) $TimeoutSec
        if ($r.err) { Exit-Recall "recall: not available ($($r.err))" }
        $lists += , @($r.hits)
    }
    $pick = Select-RecallHits $lists $job $homeCrew; $kept = $pick.kept; $found = $pick.found; $hidden = $pick.hidden
    $note = "for $($suites -join ', ') ($found found$(if ($hidden) { ", $hidden left out: not cleared for a Cloud crew" }); $(if ($homeCrew) { 'Home crew: every class' } else { 'P1 only' }))"
    if (-not $kept.Count) { Exit-Recall "recall: no past fix found $note" }
    $md = Format-Recall @($kept | Select-Object -First ([math]::Max(1, $MaxFixes))) $suites $MaxTokens
    try { [IO.File]::WriteAllText($outMd, $md.text + "`n", [Text.UTF8Encoding]::new($false)) } catch { Exit-Recall "recall: not available (RECALL.md could not be written: $($_.Exception.Message))" }
    Exit-Recall "recall: $($md.kept) past fix$(if ($md.kept -ne 1) { 'es' }) in .kitchen\RECALL.md $note"
} catch { Exit-Recall "recall: not available (the recall Step failed: $($_.Exception.Message))" }
