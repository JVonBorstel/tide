# Owns the code-quality ratchet over kitchen/quality-baseline.json: long functions, deep nesting, duplicated blocks, analyzer regressions.
# Called by tests/Test-Quality.ps1 (kitchen tests station, every order), the ci.yml "quality" job, and by hand. No installs, no network.
#   pwsh -File scripts/quality/metrics.ps1 [-Root <repo>] [-Baseline <json>] [-WriteBaseline] [-ChangedSince <git ref>] [-Report <json>]
#        [-Summary <markdown file>] [-AnalyzerModule PSScriptAnalyzer]
# Measures every code file kitchen/STANDARDS.md covers: PowerShell through the parser (exact), JavaScript through js-metrics.mjs (a
# tokenizer that skips strings, comments, templates and regex literals, then a brace pass). Duplicates: every run of 6 normalized code
# lines (trimmed, spaces collapsed, blank, comment-only and bracket-only lines dropped) is hashed across the whole repo.
# Prints "FAIL:" per new violation, "WARN:" per baselined one that grew, "NOTE:" per baselined one now fixed, "SKIP:" with the reason for
# any part that could not run, and a closing "Quality:" count line. Exit 0 clean, 1 new violations, 2 bad input.
param([string]$Root = '', [string]$Baseline = '', [switch]$WriteBaseline, [string]$ChangedSince = '', [string]$Report = '',
    [string]$Summary = '', [string]$AnalyzerModule = 'PSScriptAnalyzer')
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
if (-not (Test-Path -LiteralPath $Root)) { Write-Output "quality: folder not found: $Root"; exit 2 }
if (-not $Baseline) { $Baseline = Join-Path $Root 'kitchen/quality-baseline.json' }
# Forward slashes throughout: the same script runs on Windows (kitchen) and on the ubuntu CI runner.
. (Join-Path $PSScriptRoot '../standards-lib.ps1')

# The limits. A function longer than this many lines, a control block nested deeper than this, a run of this many lines found twice.
$MaxFnLines = 80
$MaxNesting = 5
$DupWindow = 6
# Analyzer rules left out of the changed-file check, each with its reason (measured over the repo on 2026-10-22, see STANDARDS.md):
$AnalyzerSkip = @{
    PSAvoidUsingWriteHost                          = 'test suites print FAIL lines with Write-Host on purpose'
    PSUseShouldProcessForStateChangingFunctions    = 'these are scripts, not cmdlets; nobody calls them with -WhatIf'
    PSUseSingularNouns                             = 'naming taste, not a defect'
    PSUseApprovedVerbs                             = 'naming taste, not a defect (85 hits in 34 files)'
    PSUseBOMForUnicodeEncodedFile                  = 'files are UTF-8 without BOM by house choice'
    PSAvoidUsingEmptyCatchBlock                    = 'house style: best-effort cleanup and optional reads use catch {} on purpose (3 of the last 6 merges); failing on it would stall kitchen orders at CI'
}

try { $files = Get-StdFiles $Root } catch { Write-Output $_.Exception.Message; exit 2 }

# ---- per-file measurements: functions (name, start, lines) and the deepest control nesting ----
$metrics = [ordered]@{}
# Collects function definitions and control blocks (if, every loop, switch, try) in one walk. A visitor runs PowerShell code only on
# those node kinds; a FindAll predicate runs once per node of every file, which made the whole repo take 6 s instead of under 1 s.
class QualityVisitor : System.Management.Automation.Language.AstVisitor2 {
    [Collections.Generic.List[System.Management.Automation.Language.Ast]]$Fns = [Collections.Generic.List[System.Management.Automation.Language.Ast]]::new()
    [Collections.Generic.List[System.Management.Automation.Language.Ast]]$Ctl = [Collections.Generic.List[System.Management.Automation.Language.Ast]]::new()
    [System.Management.Automation.Language.AstVisitAction] Fn($a) { $this.Fns.Add($a); return 'Continue' }
    [System.Management.Automation.Language.AstVisitAction] C($a) { $this.Ctl.Add($a); return 'Continue' }
    [System.Management.Automation.Language.AstVisitAction] VisitFunctionDefinition([System.Management.Automation.Language.FunctionDefinitionAst]$a) { return $this.Fn($a) }
    [System.Management.Automation.Language.AstVisitAction] VisitIfStatement([System.Management.Automation.Language.IfStatementAst]$a) { return $this.C($a) }
    [System.Management.Automation.Language.AstVisitAction] VisitForStatement([System.Management.Automation.Language.ForStatementAst]$a) { return $this.C($a) }
    [System.Management.Automation.Language.AstVisitAction] VisitForEachStatement([System.Management.Automation.Language.ForEachStatementAst]$a) { return $this.C($a) }
    [System.Management.Automation.Language.AstVisitAction] VisitWhileStatement([System.Management.Automation.Language.WhileStatementAst]$a) { return $this.C($a) }
    [System.Management.Automation.Language.AstVisitAction] VisitDoWhileStatement([System.Management.Automation.Language.DoWhileStatementAst]$a) { return $this.C($a) }
    [System.Management.Automation.Language.AstVisitAction] VisitDoUntilStatement([System.Management.Automation.Language.DoUntilStatementAst]$a) { return $this.C($a) }
    [System.Management.Automation.Language.AstVisitAction] VisitSwitchStatement([System.Management.Automation.Language.SwitchStatementAst]$a) { return $this.C($a) }
    [System.Management.Automation.Language.AstVisitAction] VisitTryStatement([System.Management.Automation.Language.TryStatementAst]$a) { return $this.C($a) }
}

# Nesting is counted inside the innermost function or script block, like ESLint max-depth: a nested function or a
# ForEach-Object { } block starts again at 0, so the JavaScript and PowerShell numbers mean the same thing.
function Get-PsMetrics([string]$Path) {
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
    $v = [QualityVisitor]::new(); $ast.Visit($v)
    $fns = @(foreach ($f in $v.Fns) {
        @{ name = $f.Name -replace '^(?i)(script|global|local|private):', ''; start = $f.Extent.StartLineNumber; lines = $f.Extent.EndLineNumber - $f.Extent.StartLineNumber + 1 } })
    $ctl = [Collections.Generic.HashSet[object]]::new(); foreach ($n in $v.Ctl) { [void]$ctl.Add($n) }
    $max = 0
    foreach ($n in $v.Ctl) {
        $d = 1; $p = $n.Parent
        while ($p -and $p -isnot [Management.Automation.Language.FunctionDefinitionAst] -and $p -isnot [Management.Automation.Language.ScriptBlockExpressionAst]) {
            if ($ctl.Contains($p)) { $d++ }
            $p = $p.Parent
        }
        if ($d -gt $max) { $max = $d }
    }
    @{ functions = $fns; maxNesting = $max }
}

$skips = [Collections.Generic.List[string]]::new()
foreach ($rel in ($files | Where-Object { $_ -match '\.(ps1|psm1)$' })) { $metrics[$rel] = Get-PsMetrics (Join-Path $Root $rel) }
$js = @($files | Where-Object { $_ -match '\.(mjs|js)$' })
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if ($js.Count -and -not $node) {
    $skips.Add("SKIP: node is not on PATH, so $($js.Count) JavaScript files were not measured (their baselined lines are kept, not marked fixed)")
} elseif ($js.Count) {
    $raw = & $node (Join-Path $PSScriptRoot 'js-metrics.mjs') @($js | ForEach-Object { Join-Path $Root $_ }) 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Output "quality: js-metrics.mjs failed: $($raw.Trim())"; exit 2 }
    $parsed = $raw | ConvertFrom-Json -AsHashtable -NoEnumerate  # always an array, even for one file
    for ($i = 0; $i -lt $js.Count; $i++) {
        $r = $parsed[$i]
        if ($r.error) { $skips.Add("SKIP: $($js[$i]) could not be read: $($r.error)"); continue }
        if ($r.unbalanced) { $skips.Add("SKIP: $($js[$i]) has $($r.unbalanced) unclosed braces after tokenizing; its numbers may be off") }
        $metrics[$js[$i]] = @{ functions = @($r.functions); maxNesting = [int]$r.maxNesting }
    }
}

# ---- duplicated blocks: every window of $DupWindow normalized code lines, hashed across all files ----
$kept = @{}   # file -> list of original line numbers of the kept (normalized) lines
$windows = [Collections.Generic.Dictionary[string, Collections.Generic.List[object]]]::new()
foreach ($rel in $metrics.Keys) {
    $norm = [Collections.Generic.List[string]]::new(); $nums = [Collections.Generic.List[int]]::new(); $ln = 0
    foreach ($l in [IO.File]::ReadLines((Join-Path $Root $rel))) {
        $ln++; $t = $l.Trim()
        if (-not $t -or $t -match '^(#|//|/\*|\*|<#)' -or $t -match '^[\s{}()\[\];,]*$') { continue }
        $norm.Add(($t -replace '\s+', ' ')); $nums.Add($ln)
    }
    $kept[$rel] = $nums
    for ($i = 0; $i + $DupWindow -le $norm.Count; $i++) {
        $key = [string]::Join("`n", $norm.GetRange($i, $DupWindow))
        if (-not $windows.ContainsKey($key)) { $windows[$key] = [Collections.Generic.List[object]]::new() }
        $windows[$key].Add(@($rel, $i))
    }
}
$dupMarks = @{}; $dupWhere = @{}
foreach ($occ in $windows.Values) {
    if ($occ.Count -lt 2) { continue }
    # Overlapping copies inside one file (a line repeated 7 times) are one block, not two.
    $distinct = [Collections.Generic.List[object]]::new()
    foreach ($o in $occ) { if (-not ($distinct | Where-Object { $_[0] -eq $o[0] -and [math]::Abs($_[1] - $o[1]) -lt $DupWindow })) { $distinct.Add($o) } }
    if ($distinct.Count -lt 2) { continue }
    foreach ($o in $distinct) {
        $rel = $o[0]
        if (-not $dupMarks.ContainsKey($rel)) { $dupMarks[$rel] = [Collections.Generic.HashSet[int]]::new() }
        for ($k = 0; $k -lt $DupWindow; $k++) { [void]$dupMarks[$rel].Add($o[1] + $k) }
        if (-not $dupWhere.ContainsKey($rel)) {
            $other = $distinct | Where-Object { -not ($_[0] -eq $rel -and $_[1] -eq $o[1]) } | Select-Object -First 1
            $dupWhere[$rel] = "line $($kept[$rel][$o[1]]) repeats $($other[0]):$($kept[$other[0]][$other[1]])"
        }
    }
}

# ---- violations (the ratchet's keys) ----
$now = [ordered]@{}; $longest = @()
foreach ($rel in $metrics.Keys) {
    $m = $metrics[$rel]; $seen = @{}
    foreach ($f in ($m.functions | Sort-Object { $_.start })) {
        $name = $f.name; $seen[$name] = 1 + [int]$seen[$name]; if ($seen[$name] -gt 1) { $name = "$name#$($seen[$name])" }
        $longest += [pscustomobject]@{ file = $rel; name = $name; start = $f.start; lines = [int]$f.lines }
        if ($f.lines -gt $MaxFnLines) { $now["longfn|$rel|$name"] = [int]$f.lines }
    }
    if ($m.maxNesting -gt $MaxNesting) { $now["nesting|$rel"] = [int]$m.maxNesting }
    $dl = if ($dupMarks.ContainsKey($rel)) { $dupMarks[$rel].Count } else { 0 }
    $m.dupLines = $dl
    if ($dl) { $now["dup|$rel"] = $dl }
}

if ($Report) {
    $rep = [ordered]@{}
    foreach ($rel in $metrics.Keys) {
        $m = $metrics[$rel]; $top = $m.functions | Sort-Object { [int]$_.lines } -Descending | Select-Object -First 1
        $rep[$rel] = [ordered]@{ longestFunction = if ($top) { "$($top.name) ($($top.lines) lines)" } else { '' }; longestLines = if ($top) { [int]$top.lines } else { 0 }
            functionsOver80 = @($m.functions | Where-Object { $_.lines -gt $MaxFnLines }).Count; maxNesting = [int]$m.maxNesting; duplicatedLines = $m.dupLines }
    }
    $rep | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Report -Encoding utf8
}

if ($WriteBaseline) {
    $sorted = [ordered]@{}; foreach ($k in ($now.Keys | Sort-Object)) { $sorted[$k] = $now[$k] }
    [ordered]@{
        note       = "Known code-quality violations, recorded by scripts/quality/metrics.ps1 -WriteBaseline. longfn|file|function -> lines (over $MaxFnLines); nesting|file -> deepest control nesting (over $MaxNesting); dup|file -> lines inside a $DupWindow-line block that also appears elsewhere. Only shrink it."
        violations = $sorted
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Baseline -Encoding utf8
    Write-Output "Quality: baseline written with $($now.Count) known violations to $Baseline"
    exit 0
}

$base = @{}
if (Test-Path -LiteralPath $Baseline) {
    try { $j = Get-Content -LiteralPath $Baseline -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Output "quality: baseline is not valid JSON: $Baseline"; exit 2 }
    if ($j.violations) { foreach ($k in $j.violations.Keys) { $base[$k] = [int]$j.violations[$k] } }
} else { Write-Output "NOTE: no baseline at $Baseline, so every violation counts as new" }
Write-Output "Quality: baseline holds $($base.Count) known violations"

$why = @{
    longfn  = "is over $MaxFnLines lines; split it into named steps"
    nesting = "nests control blocks deeper than $MaxNesting; return early or pull the inner part into a function"
    dup     = "repeats a $DupWindow-line block found elsewhere; share it through one function"
}
$lines = [Collections.Generic.List[string]]::new(); $fail = 0; $warn = 0
foreach ($k in $now.Keys) {
    $rule, $rel, $fn = $k -split '\|', 3
    $what = if ($fn) { "$rel $fn" } else { $rel }
    $where = if ($rule -eq 'dup') { " ($($dupWhere[$rel]))" } else { '' }
    if (-not $base.ContainsKey($k)) { $fail++; $lines.Add("FAIL: $rule $what $($why[$rule]) (now $($now[$k]))$where"); continue }
    if ($now[$k] -gt $base[$k]) { $warn++; $lines.Add("WARN: $rule $what grew: baseline $($base[$k]), now $($now[$k])$where") }
}
foreach ($k in $base.Keys) {
    $rel = ($k -split '\|')[1]
    if (-not $now.Contains($k) -and $metrics.Contains($rel)) { $lines.Add("NOTE: $($k -replace '\|', ' ') is fixed; remove it from the baseline") }
}

# ---- PSScriptAnalyzer on the PowerShell files this change touched: a rule with more findings than the base version fails ----
# Findings per rule for one file (Warning and Error, minus $AnalyzerSkip), plus "@<rule>" -> the first finding's line and message.
function Get-AnalyzerCounts([string]$Path) {
    $h = @{}
    foreach ($d in @(Invoke-ScriptAnalyzer -Path $Path -Severity Warning, Error -ExcludeRule @($AnalyzerSkip.Keys) -ErrorAction SilentlyContinue)) {
        $h[$d.RuleName] = 1 + [int]$h[$d.RuleName]
        if (-not $h.ContainsKey("@$($d.RuleName)")) { $h["@$($d.RuleName)"] = "line $($d.Line): $($d.Message)" }
    }
    $h
}
# FAIL lines for the changed files: each rule that has more findings now than in the file at $Since (a new file starts from 0).
function Compare-Analyzer([string[]]$Changed, [string]$Since) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('quality-base-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        foreach ($rel in $Changed) {
            $after = Get-AnalyzerCounts (Join-Path $Root $rel)
            $old = @(& git -C $Root show "$($Since):$rel" 2>$null)
            $before = if ($LASTEXITCODE -eq 0) { [IO.File]::WriteAllLines($tmp, [string[]]$old); Get-AnalyzerCounts $tmp } else { @{} }
            foreach ($r in ($after.Keys | Where-Object { $_ -notlike '@*' -and $after[$_] -gt [int]$before[$_] } | Sort-Object)) {
                "FAIL: analyzer $rel $r went from $([int]$before[$r]) to $($after[$r]) (first finding: $($after["@$r"]))"
            }
        }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
$changed = @()
if ($ChangedSince) { $changed = @(& git -C $Root diff --name-only $ChangedSince HEAD 2>$null); $diffOk = $LASTEXITCODE -eq 0 }
if (-not $ChangedSince) {
    $skips.Add("SKIP: analyzer regression check needs -ChangedSince <git ref> (CI passes the PR base); not run")
} elseif (-not (Get-Module -ListAvailable -Name $AnalyzerModule)) {
    $skips.Add("SKIP: $AnalyzerModule is not installed here, so changed PowerShell files were not analyzed (this script never installs)")
} elseif (-not $diffOk) {
    $skips.Add("SKIP: git could not diff against '$ChangedSince', so the analyzer check did not run")
} else {
    Import-Module $AnalyzerModule -ErrorAction Stop
    $ps = @($changed | Where-Object { $_ -match '\.(ps1|psm1)$' -and $metrics.Contains($_) })
    foreach ($l in @(Compare-Analyzer $ps $ChangedSince)) { $fail++; $lines.Add($l) }
    $skips.Add("Analyzer: $($ps.Count) changed PowerShell files checked against $ChangedSince")
}

$lines | ForEach-Object { Write-Output $_ }
$skips | ForEach-Object { Write-Output $_ }
$fnCount = $longest.Count; $over = @($longest | Where-Object { $_.lines -gt $MaxFnLines }).Count
$deep = @($metrics.Values | Where-Object { $_.maxNesting -gt $MaxNesting }).Count
$dupTotal = ($metrics.Values | Measure-Object -Property dupLines -Sum).Sum; $dupFiles = @($metrics.Values | Where-Object { $_.dupLines }).Count
$closing = "Quality: $($metrics.Count) files, $fnCount functions ($over over $MaxFnLines lines), $deep files nested deeper than $MaxNesting, $dupTotal duplicated lines in $dupFiles files; $($now.Count) violations ($($now.Count - @($now.Keys | Where-Object { -not $base.ContainsKey($_) }).Count) baselined), $warn grew, $fail new"
Write-Output $closing

if ($Summary) {
    $md = [Collections.Generic.List[string]]::new()
    $md.Add('## Code quality (scripts/quality/metrics.ps1)'); $md.Add(''); $md.Add($closing); $md.Add('')
    foreach ($l in ($lines | Where-Object { $_ -match '^(FAIL|WARN):' })) { $md.Add("- $l") }
    foreach ($l in $skips) { $md.Add("- $l") }
    $md.Add(''); $md.Add('| Longest functions | Lines |'); $md.Add('|---|---|')
    foreach ($f in ($longest | Sort-Object lines -Descending | Select-Object -First 10)) { $md.Add("| ``$($f.file)`` $($f.name) (line $($f.start)) | $($f.lines) |") }
    Add-Content -LiteralPath $Summary -Value $md -Encoding utf8
}
exit ([int]($fail -gt 0))
