# The weakened-test check (Watch plan step 2): flags a change that deletes test files, removes check lines or lowers expected counts under tests/.
# Called by kitchen/stations/commit.ps1 and freshen.ps1 (findings go to .kitchen\WEAKENED.txt and the end of DIFF.patch, which the taster reads); tests/Test-WatchGates.ps1.
# Usage: weakened-tests.ps1 -Dir <worktree> -Base <commit> [-Head HEAD] [-Out <file>]
# Prints one "FLAG: ..." line per finding, then "weakened-tests: none" or "weakened-tests: N finding(s)". Exit 0 none, 1 findings, 2 cannot check.
# Plain patterns, no model: git diff --numstat and --name-status for the files, then the removed/added lines of each test file.
#   check line: Check / Assert / assert / expect( / Should / t.ok|equal|deepEqual|throws ... (net fewer of them in a file is a finding)
#   lowered count: a removed line and an added line that read the same apart from their numbers, on a line that compares (-eq, -ge,
#   Count, ==, toBe, length ...), where a number went down
param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Base, [string]$Head = 'HEAD', [string]$Out = '')
$ErrorActionPreference = 'Stop'
$checkRx = '^\s*(Check\b|Assert|assert\b|assert\.|expect\(|.*\|\s*Should\b|t\.(ok|equal|deepEqual|strictEqual|throws|is|true|false)\b)'
$compareRx = '-eq|-ge|-gt|-le|-lt|-ne|Count|count|==|toBe|toHaveLength|length|Length|expected'
$lines = [Collections.Generic.List[string]]::new()
function Say([string]$t) { $lines.Add($t); Write-Output $t }
function Done([int]$code) { if ($Out) { Set-Content -LiteralPath $Out -Value ($lines -join "`n") -Encoding utf8 }; exit $code }

if (-not (Test-Path -LiteralPath $Dir)) { Say "weakened-tests: cannot check: folder not found: $Dir"; Done 2 }
foreach ($ref in $Base, $Head) {
    & git -C $Dir rev-parse --verify --quiet "$ref^{commit}" 2>$null | Out-Null
    if ($LASTEXITCODE) { Say "weakened-tests: cannot check: '$ref' is not a commit in $Dir"; Done 2 }
}
$found = 0
$stat = @(& git -C $Dir diff --no-renames --numstat $Base $Head -- tests 2>$null)
$add = 0; $del = 0; foreach ($n in $stat) { if ($n -match '^(\d+)\t(\d+)\t') { $add += [int]$Matches[1]; $del += [int]$Matches[2] } }
foreach ($ns in @(& git -C $Dir diff --no-renames --name-status --diff-filter=D $Base $Head -- tests 2>$null)) {
    if ($ns -match '^D\t(.+)$') { Say "FLAG: test file deleted: $($Matches[1])"; $found++ }
}
foreach ($f in @(& git -C $Dir diff --no-renames --name-only --diff-filter=M $Base $Head -- tests 2>$null)) {
    $rem = [Collections.Generic.List[string]]::new(); $new = [Collections.Generic.List[string]]::new()
    foreach ($l in @(& git -C $Dir diff --no-renames -U0 $Base $Head -- $f 2>$null)) {
        if ($l -match '^(\+\+\+|---) ') { continue }
        if ($l.StartsWith('-')) { $rem.Add($l.Substring(1)) } elseif ($l.StartsWith('+')) { $new.Add($l.Substring(1)) }
    }
    $cr = @($rem | Where-Object { $_ -match $checkRx }).Count; $ca = @($new | Where-Object { $_ -match $checkRx }).Count
    if ($cr -gt $ca) { Say "FLAG: $f has $($cr - $ca) fewer check line(s) ($cr removed, $ca added)"; $found++ }
    # lowered counts: pair a removed and an added line that are the same text once their numbers are blanked
    $byShape = @{}; foreach ($a in $new) { if ($a -match '\d' -and $a -match $compareRx) { $byShape[($a -replace '\d+', '#').Trim()] = $a } }
    foreach ($r in $rem) {
        if ($r -notmatch '\d' -or $r -notmatch $compareRx) { continue }
        $a = $byShape[($r -replace '\d+', '#').Trim()]; if (-not $a) { continue }
        $rn = @([regex]::Matches($r, '\d+') | ForEach-Object { [long]$_.Value }); $an = @([regex]::Matches($a, '\d+') | ForEach-Object { [long]$_.Value })
        for ($i = 0; $i -lt [math]::Min($rn.Count, $an.Count); $i++) {
            if ($an[$i] -lt $rn[$i]) { Say "FLAG: $f lowers an expected number ($($rn[$i]) -> $($an[$i])): $($a.Trim())"; $found++; break }
        }
    }
}
Say "weakened-tests: tests/ changed by +$add -$del lines in $($stat.Count) file(s)"
if ($found) { Say "weakened-tests: $found finding(s): a reviewer must see a reason in the plan, or send the change back"; Done 1 }
Say 'weakened-tests: none'
Done 0
