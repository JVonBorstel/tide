# Station: a map of the repository for the cooks (no AI, no tokens to make; it saves the planner's exploring turns).
# Writes .kitchen\MAP.md in the job's worktree: every tracked code file with its size, its functions (PowerShell, JavaScript) and the
# first comment line saying what it is; test suites listed with what they test. The plan and build steps read it first.
#   step: {"station":"map","args":{"MaxChars":24000}}      or by hand: map.ps1 -Dir <repo> [-Out file]
param([string]$Dir = '', [int]$MaxChars = 24000, [string]$Out = '')
$ErrorActionPreference = 'Stop'
$job = $env:KITCHEN_JOB
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
if (-not $Dir) { if ($job -notmatch '^J\d+$') { Write-Output 'map: no kitchen job and no -Dir'; exit 2 }; $Dir = Join-Path $kroot "worktrees\$job" }
if (-not (Test-Path -LiteralPath $Dir)) { Write-Output "map: folder not found: $Dir"; exit 2 }
if (-not $Out) { $Out = Join-Path $Dir '.kitchen\MAP.md' }
. (Join-Path $PSScriptRoot '..\repo-config.ps1')
# the tests line below names this repo's suites; a bad kitchen.repo.json stops the order here, before any AI step is paid for
try { $rc = Get-RepoConfig $Dir } catch { Write-Output "map: $($_.Exception.Message)"; exit 2 }
# brain-monitor's map stays as it was (it is near its size cap); a repo with its own kitchen.repo.json also gets its other common languages and CLAUDE.md
$exts = if ($rc.Present) { 'ps1|psm1|mjs|js|json|py|ts|tsx|cs|go|rs|bicep|yml|yaml|sh' } else { 'ps1|psm1|mjs|js|json' }
$docs = if ($rc.Present) { 'README|AGENTS|CLAUDE|API|BUILDING' } else { 'README|AGENTS|API|BUILDING' }
$files = @(& git -C $Dir ls-files 2>$null | Where-Object { ($_ -match "\.($exts)$" -or $_ -match "(^|/)($docs)\.md$") -and $_ -notmatch '(^|/)(node_modules|\.kitchen)/' })
function Head([string]$p) {   # the file's own first comment line: what it is, in its author's words
    foreach ($l in [IO.File]::ReadLines($p)) { $t = $l.Trim(); if (-not $t -or $t -match '^(#!|<#|#>|"use strict"|import |param\()') { continue }; if ($t -match '^(#|//)\s*(.+)$') { $h = $Matches[2]; return $(if ($h.Length -gt 140) { $h.Substring(0, 137) + '...' } else { $h }) }; return '' }
    ''
}
$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine('# Repository map (made by a script; read this before exploring)')
$testsNote = if ($rc.Present) { "Tests are $($rc.Tests -join ', '); a suite prints its own pass/fail summary line." } else { 'Tests are tests/Test-*.ps1; each prints "<Name> tests: N passed, M failed".' }
[void]$sb.AppendLine("Each line: file (lines) - what it says it is. Then its functions. $testsNote")
foreach ($grp in ($files | Group-Object { if ($_ -match '/') { $_.Split('/')[0] } else { '.' } })) {
    [void]$sb.AppendLine(''); [void]$sb.AppendLine("## $($grp.Name)/")
    foreach ($rel in $grp.Group) {
        $p = Join-Path $Dir $rel; if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $n = 0; try { $n = @([IO.File]::ReadLines($p)).Count } catch { }
        $line = "- $rel ($n)"; $h = if ($rel -notmatch '\.json$') { Head $p } else { '' }; if ($h) { $line += " - $h" }
        [void]$sb.AppendLine($line)
        $fns = @()
        if ($rel -match '\.ps1|\.psm1') { $fns = @(Select-String -LiteralPath $p -Pattern '^\s*function\s+([\w-]+)' -AllMatches | ForEach-Object { $_.Matches[0].Groups[1].Value }) }
        elseif ($rel -match '\.m?js$') { $fns = @(Select-String -LiteralPath $p -Pattern '^(?:export\s+)?(?:async\s+)?function\s+(\w+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }) }
        if ($fns.Count) { [void]$sb.AppendLine("  functions: $(($fns | Select-Object -Unique) -join ', ')") }
    }
}
$text = $sb.ToString(); if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + "`n(map cut at $MaxChars characters; search for anything not listed)" }
$od = Split-Path -Parent $Out; if ($od -and -not (Test-Path -LiteralPath $od)) { New-Item -ItemType Directory -Force -Path $od | Out-Null }
Set-Content -LiteralPath $Out -Value $text -Encoding utf8
# the lesson book: what broke in earlier changes and had to be repaired (newest first), so builders avoid it the first time
$lb = Join-Path $kroot 'lessons.jsonl'; $lessons = 0
if ($job -and (Test-Path -LiteralPath $lb)) {
    $seen = @{}; $lines = [Collections.Generic.List[string]]::new()
    foreach ($l in @(Get-Content -LiteralPath $lb -Tail 200)[-1..-200]) { if (-not $l) { continue }; try { $e = $l | ConvertFrom-Json } catch { continue }; foreach ($b in @($e.broke)) { $k = ($b -replace '\d+', '#' -replace '\s+', ' ').ToLowerInvariant(); if ($b -and -not $seen[$k] -and $lines.Count -lt 25) { $seen[$k] = 1; $lines.Add("- $b ($($e.job))") } } }
    if ($lines.Count) { Set-Content -LiteralPath (Join-Path (Split-Path -Parent $Out) 'LESSONS.md') -Encoding utf8 -Value ("# Lessons: failures earlier changes had to repair (avoid these)`n" + ($lines -join "`n")); $lessons = $lines.Count }
}
# positive exemplars: proven patterns from successful improvements, ranked by relevance to this change
$eb = Join-Path $kroot 'exemplars.jsonl'; $exemplars = 0
if (Test-Path -LiteralPath $eb) {
    $cand = [Collections.Generic.List[object]]::new()
    foreach ($l in [IO.File]::ReadLines($eb)) {
        if (-not $l -or -not $l.Trim()) { continue }
        try { $e = $l | ConvertFrom-Json; if ($e -and $e.goal) { $cand.Add($e) } } catch { }
    }
    if ($cand.Count) {
        $currentGoal = if ($env:KITCHEN_GOAL) { $env:KITCHEN_GOAL }
            elseif ($job -and (Test-Path -LiteralPath (Join-Path $kroot "jobs\$job.json"))) {
                try {
                    $jObj = Get-Content -LiteralPath (Join-Path $kroot "jobs\$job.json") -Raw | ConvertFrom-Json
                    if ($jObj.vars -and $jObj.vars.goal) { [string]$jObj.vars.goal }
                    elseif ($jObj.name -match '^improve:\s*(.+)$') { $Matches[1].Trim() }
                    else { [string]$jObj.name }
                } catch { '' }
            } else { '' }

        $stopWords = [Collections.Generic.HashSet[string]]::new([string[]]@('and','the','for','with','from','this','that','into','when','what','have','been','were','will'), [StringComparer]::OrdinalIgnoreCase)
        $goalWords = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($currentGoal) {
            foreach ($m in [regex]::Matches($currentGoal.ToLowerInvariant(), '\b[a-z0-9_-]{3,}\b')) {
                if (-not $stopWords.Contains($m.Value)) { [void]$goalWords.Add($m.Value) }
            }
        }
        $repoFileSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $files) {
            $norm = $f.Replace('\', '/').TrimStart('/')
            [void]$repoFileSet.Add($norm)
            [void]$repoFileSet.Add([IO.Path]::GetFileName($norm))
        }

        $scored = [Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $cand.Count; $i++) {
            $c = $cand[$i]
            $score = 0.0
            if ($goalWords.Count -gt 0 -and $c.goal) {
                foreach ($m in [regex]::Matches($c.goal.ToLowerInvariant(), '\b[a-z0-9_-]{3,}\b')) {
                    if ($goalWords.Contains($m.Value)) { $score += 10.0 }
                }
            }
            if ($c.files) {
                foreach ($f in @($c.files)) {
                    $normF = ([string]$f).Replace('\', '/').TrimStart('/')
                    if ($repoFileSet.Contains($normF) -or $repoFileSet.Contains([IO.Path]::GetFileName($normF))) {
                        $score += 5.0
                    }
                }
            }
            $score += ($i * 0.01)
            $scored.Add(@{ entry = $c; score = $score; idx = $i })
        }

        $top = @($scored | Sort-Object { $_.score } -Descending | Select-Object -First 10 | ForEach-Object { $_.entry })
        $exLines = [Collections.Generic.List[string]]::new()
        foreach ($ex in $top) {
            $goalStr = [string]$ex.goal
            $jobStr = if ($ex.job) { " ($($ex.job))" } else { '' }
            $exLines.Add("- $goalStr$jobStr")
            $fileList = if ($ex.files -and @($ex.files).Count) { (@($ex.files) -join ', ') } else { '(none)' }
            $exLines.Add("  - Files: $fileList")
            $testPat = if ($ex.testPattern) { [string]$ex.testPattern } else { 'tests\Test-*.ps1' }
            $exLines.Add("  - Tests: $testPat")
        }
        if ($exLines.Count) {
            Set-Content -LiteralPath (Join-Path (Split-Path -Parent $Out) 'EXEMPLARS.md') -Encoding utf8 -Value ("# Exemplars: proven patterns from successful improvements`n" + ($exLines -join "`n"))
            $exemplars = $top.Count
        }
    }
}
Write-Output "map: $($files.Count) files, $($text.Length) characters, $lessons lessons, $exemplars exemplars -> $Out"
exit 0
