# The memory lobe's check: is what memory SAYS still true? No model, read-only on memory. Safe to re-run: yes.
# (gemini-brain projects/tide: "no guessing"; memory that drifts from the files makes every later session guess.)
# Checks Claude's auto-memory folder and the brain's short-term files:
#   - MEMORY.md (the index) links only to files that exist, and every memory file is in the index
#   - each memory file has frontmatter with a name and a description
#   - every absolute path a memory file names (C:\..., D:\...) still exists (placeholders like <name> are skipped)
#   - claims about the kitchen's mode match the files: "kitchen is PAUSED" while no PAUSED file (or the reverse) is a drift
#   - gemini-brain memory/NOW.md is under 3 days old; memory/BOOT.md under 12 hours; an ACTIVE BUILD progress file under 1 day
#   - proof or unknown (the Creed, rule 1), WARN only: a bullet in gemini-brain memory/*.md (top level; never evie*, user/, archive/;
#     not BOOT.md, which is script-built) that states a number, date or id but carries no proof (a path, URL, `command`, commit sha,
#     Test-Name, "(source: ...)") and does not say "unknown" or "UNVERIFIED". Listed with file:line; never fails the run or alerts.
#   - the lobe (ZG-38, wraps, never replaces): each open tension in <kitchen>\lobe\tensions.json (zeitgeistd ZG-37: two memory lines that
#     disagree) is a drift finding with both sources (file:line); no file = 'lobe: no tensions file', not a failure; a damaged file is drift.
# Writes <kitchen>\watch\memory.json (heartbeat + findings + warnings; `unproven` = the WARN count). Exit 0 = true, 3 = drift found, 2 = bad
# call (WARNs never change it).
#   memory-truth.ps1 [-MemoryDir <dir>] [-BrainPath <dir>] [-Json]
param([string]$MemoryDir = '', [string]$BrainPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain'), [switch]$Json)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
if (-not $MemoryDir) {
    # the Claude Code auto-memory folders on this PC (one per project); the newest MEMORY.md wins
    $cand = @(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.claude\projects') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'memory\MEMORY.md' } | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending)
    if (-not $cand.Count) { Write-Output 'ERROR: no Claude memory folder found (give -MemoryDir)'; exit 2 }
    $MemoryDir = Split-Path -Parent $cand[0]
}
if (-not (Test-Path -LiteralPath (Join-Path $MemoryDir 'MEMORY.md'))) { Write-Output "ERROR: no MEMORY.md in $MemoryDir"; exit 2 }
$now = [DateTime]::UtcNow
$found = [Collections.Generic.List[object]]::new(); $checked = 0
function Drift([string]$file, [string]$say) { $found.Add([ordered]@{ file = $file; say = $say }) }

# 1. index vs files
$index = Get-Content -LiteralPath (Join-Path $MemoryDir 'MEMORY.md') -Raw -Encoding utf8
$linked = @([regex]::Matches($index, '\]\(([^)\s]+\.md)\)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$files = @(Get-ChildItem -LiteralPath $MemoryDir -Filter '*.md' -File | Where-Object Name -ne 'MEMORY.md')
foreach ($l in $linked) { $checked++; if (-not (Test-Path -LiteralPath (Join-Path $MemoryDir $l))) { Drift 'MEMORY.md' "the index links to $l, which does not exist" } }
foreach ($f in $files) { $checked++; if ($f.Name -notin $linked) { Drift $f.Name 'this memory file is not in the index (MEMORY.md), so no session will find it' } }

# 2. each file: frontmatter, named paths, mode claims
$paused = Test-Path -LiteralPath (Join-Path $root 'PAUSED')
foreach ($f in $files) {
    $t = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8
    $checked++
    if ($t -notmatch '(?s)^---\s.*?\bname:\s*\S.*?\bdescription:\s*\S.*?---') { Drift $f.Name 'no frontmatter with a name and a description' }
    foreach ($m in [regex]::Matches($t, '(?<![\w/])([A-Za-z]:\\[^\s`''"<>|*?,;)\]]+)')) {
        $p = $m.Groups[1].Value.TrimEnd('.', ':', '\')
        $next = if ($m.Index + $m.Length -lt $t.Length) { $t[$m.Index + $m.Length] } else { ' ' }
        if ($p -match '[<>{}]|\.\.\.|\*' -or $p.Length -lt 6 -or $next -in '<', '{', '*') { continue }   # a template path (wt\gw-w<N>) is not a claim
        $checked++
        if (-not (Test-Path -LiteralPath $p)) { Drift $f.Name "names $p, which does not exist" }
    }
    $checked++
    $claimsPaused = $t -match '(?im)^(?!.*\b(history|was|were|until|from)\b).*\bkitchen (is|stays) (deliberately )?paused\b'
    if ($claimsPaused -and -not $paused) { Drift $f.Name 'says the kitchen is paused, but there is no PAUSED file (it is running)' }
}

# 3. short-term files: age
function AgeH([string]$p) { if (Test-Path -LiteralPath $p) { [math]::Round(($now - (Get-Item -LiteralPath $p).LastWriteTimeUtc).TotalHours, 1) } else { $null } }
$checked++
$nowAge = AgeH (Join-Path $BrainPath 'memory\NOW.md'); if ($null -eq $nowAge) { Drift 'NOW.md' 'gemini-brain memory/NOW.md is missing' } elseif ($nowAge -gt 72) { Drift 'NOW.md' "NOW.md (short-term memory) is $([math]::Round($nowAge / 24, 1)) days old" }
$checked++
$bootAge = AgeH (Join-Path $BrainPath 'memory\BOOT.md'); if ($null -ne $bootAge -and $bootAge -gt 12) { Drift 'BOOT.md' "the boot pack is $bootAge hours old (refresh-boot.ps1 rewrites it)" }
foreach ($m in [regex]::Matches($index, '(?im)^- ACTIVE BUILD[^:]*:.*?([A-Za-z]:\\\S+\.md)')) {
    $checked++; $a = AgeH $m.Groups[1].Value
    if ($null -eq $a) { Drift 'MEMORY.md' "the active build file $($m.Groups[1].Value) is missing" } elseif ($a -gt 24) { Drift 'MEMORY.md' "the active build file has not been updated for $([math]::Round($a)) hours: finish it or take it out of the index" }
}

# 4. proof or unknown (WARN only, day one 10-22: the count is the baseline to bring down; it never fails the run). A bullet that states a
#    fact (a number, a date like 10-22, an id like J176 or #38) must carry its proof or say it does not know. Protected files are never opened.
$warns = [Collections.Generic.List[object]]::new(); $factBullets = 0
$bm = Join-Path $BrainPath 'memory'
$lintFiles = @(Get-ChildItem -LiteralPath $bm -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'evie*' -and $_.Name -ne 'BOOT.md' })
$proof = '(?i)[A-Za-z]:\\|(?<![\w/])[A-Za-z][\w.-]*/[\w.-]*[A-Za-z]|\b[\w-]+\.(ps1|psm1|mjs|js|ts|py|md|json|jsonl|txt|ya?ml|csv|html?)\b|https?://|`[^`]+`|\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b|\bTest-[A-Z]\w+|\(source:'
$fact = '\d'   # a number, a date (2026-10-22, 10-22) or an id (J176, A12, #38, B-41): each has a digit
foreach ($f in $lintFiles) {
    $n = 0; $fence = $false
    foreach ($line in [IO.File]::ReadLines($f.FullName)) {
        $n++
        if ($line -match '^\s*(```|~~~)') { $fence = -not $fence; continue }
        if ($fence -or $line -notmatch '^\s*([-*+]|\d+[.)])\s+(.*)$') { continue }
        $body = $Matches[2]
        if ($body -notmatch $fact) { continue }
        $factBullets++
        if ($body -match $proof -or $body -match '(?i)\bunknown\b|\bUNVERIFIED\b') { continue }
        $say = ($body -replace '[\x00-\x1f\x7f-\x9f​-‏‪-‮⁠-⁤⁦-⁩﻿]', ' ').Trim()
        if ($say.Length -gt 100) { $say = $say.Substring(0, 100) + '...' }
        $warns.Add([ordered]@{ file = "memory/$($f.Name)"; line = $n; say = "states a fact with no proof and no 'unknown': $say" })
    }
}
$checked += $factBullets

# 5. the lobe's eyes (ZG-38): zeitgeistd's contradiction edges (ZG-37) in <kitchen>\lobe\tensions.json. Each open tension (two memory lines that
#    disagree, neither proven newer) is a drift finding naming both sources (file:line). This only ADDS findings; checks 1-4 are unchanged.
#    No file = one line 'lobe: no tensions file' (the lobe has not run), never a failure. A damaged file is a finding, never read as "none".
function Clean([object]$v, [int]$max) {
    $s = ([string]$v -replace '[\x00-\x1f\x7f-\x9f​-‏‪-‮⁠-⁤⁦-⁩﻿]', ' ').Trim()
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) + '...' }; $s
}
function Side([object]$x) {
    # one side of a tension: its value and where it was said (at = <file>:<line>, else the source id); $null when unusable
    if ($null -eq $x -or $x -isnot [Management.Automation.PSCustomObject]) { return $null }
    $at = Clean $x.at 160; $src = Clean $x.source 120
    if (-not $at -and -not $src) { return $null }
    $file = if ($at -match '^(.+):\d+$') { $Matches[1] } elseif ($at) { $at } else { $src -replace '^memory:', '' }
    [ordered]@{ value = (Clean $x.value 60); where = $(if ($at) { $at } else { $src }); source = $src; file = $file }
}
$tensPath = Join-Path (Join-Path $root 'lobe') 'tensions.json'
$lobe = [ordered]@{ state = 'absent'; path = $tensPath; tensions = 0; unreadable = 0 }
if (Test-Path -LiteralPath $tensPath -PathType Leaf) {
    $checked++
    $list = $null; $why = ''
    try {
        $raw = Get-Content -LiteralPath $tensPath -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) { $why = 'it is empty' }
        else { $list = ConvertFrom-Json -InputObject $raw -NoEnumerate; if ($list -isnot [Array]) { $why = 'it is not a list'; $list = $null } }
    } catch { $why = "it is not JSON: $(Clean $_.Exception.Message 120)" }
    if ($null -eq $list) { $lobe.state = 'damaged'; Drift 'lobe\tensions.json' "the lobe's tensions file is damaged ($why), so whether memory contradicts itself is unknown" }
    else {
        $lobe.state = 'read'
        foreach ($e in $list) {
            $checked++
            $a = if ($e -is [Management.Automation.PSCustomObject]) { Side $e.a } else { $null }; $b = if ($a) { Side $e.b } else { $null }
            $subj = if ($e -is [Management.Automation.PSCustomObject]) { Clean $e.subject 120 } else { '' }
            if (-not $a -or -not $b -or -not $subj) { $lobe.unreadable++; continue }
            $lobe.tensions++
            $since = Clean $e.since 40; $id = Clean $e.id 12
            $say = "memory disagrees with itself: $subj = $($a.value) ($($a.where)) vs $($b.value) ($($b.where))" + $(if ($since) { ", since $since" } else { '' }) +
                $(if ($e.reviewed -eq $true) { "; the Owner looked and said unknown" } else { '' }) + "; a proof or the Owner's decision settles it (lobe tension $id)"
            $found.Add([ordered]@{ file = $a.file; say = $say; source = 'lobe'; tension = (Clean $e.id 80); a = $a.where; b = $b.where })
        }
        if ($lobe.unreadable) { Drift 'lobe\tensions.json' "$($lobe.unreadable) tension(s) in the lobe's tensions file could not be read (no subject, or a side with no source), so they are unknown" }
    }
}
$lobeLine = switch ($lobe.state) {
    'absent' { 'lobe: no tensions file' }
    'damaged' { 'lobe: the tensions file is damaged (a drift finding above)' }
    default { "lobe: $($lobe.tensions) tension(s) from $tensPath" + $(if ($lobe.unreadable) { ", $($lobe.unreadable) unreadable" } else { '' }) }
}

$wd = Join-Path $root 'watch'; New-Item -ItemType Directory -Force -Path $wd | Out-Null
# unproven (ZG-38) = the WARN count (fact bullets with no proof and no 'unknown'): the baseline the lobe (ZG-39) and the Board's Trust card trend
$hb = [ordered]@{ name = 'memory'; lastRun = $now.ToString('o'); checked = $checked; found = $found.Count; everyMin = 60; whilePaused = $true; memoryDir = $MemoryDir; findings = @($found); warn = $warns.Count; unproven = $warns.Count; tensions = $lobe.tensions; lobe = $lobe.state; warnings = @($warns | Select-Object -First 200) }
$tmp = Join-Path $wd 'memory.json.tmp'; $hb | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding utf8; Move-Item -LiteralPath $tmp -Destination (Join-Path $wd 'memory.json') -Force
$lintLine = "Proof lint (WARN only, baseline; never fails the run): $($warns.Count) of $factBullets fact bullet(s) in $($lintFiles.Count) memory file(s) carry no proof and no 'unknown'."
if ($Json) { [ordered]@{ ok = ($found.Count -eq 0); checked = $checked; findings = @($found); proofLint = [ordered]@{ files = $lintFiles.Count; factBullets = $factBullets; warn = $warns.Count; summary = $lintLine }; unproven = $warns.Count; lobe = [ordered]@{ state = $lobe.state; tensions = $lobe.tensions; unreadable = $lobe.unreadable; summary = $lobeLine }; warnings = @($warns) } | ConvertTo-Json -Depth 5 -Compress }
else {
    Write-Output "Memory: checked $checked. $(if ($found.Count) { "$($found.Count) drift(s):" } else { 'All true.' })"; $found | ForEach-Object { Write-Output "  $($_.file): $($_.say)" }
    Write-Output $lobeLine
    Write-Output $lintLine
    $warns | Select-Object -First 50 | ForEach-Object { Write-Output "  WARN $($_.file):$($_.line): $($_.say)" }
    if ($warns.Count -gt 50) { Write-Output "  ... and $($warns.Count - 50) more (all of them in -Json)" }
}
if ($found.Count) { exit 3 }
exit 0
