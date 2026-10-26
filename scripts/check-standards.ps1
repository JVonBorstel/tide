# Owns the ratchet over kitchen/STANDARDS.md: fails on violations not in kitchen/lint-baseline.json; a baselined oversize file that grew only warns.
# Called by tests/Test-Standards.ps1 (so the kitchen tests station runs it on every order) and by hand; -WriteBaseline records today.
#   pwsh -File scripts/check-standards.ps1 [-Root <repo>] [-Baseline <json>] [-WriteBaseline] [-AnalyzerModule PSScriptAnalyzer]
# Prints "FAIL: <rule> <file> ..." per new or worse violation, "WARN: size <file> grew ..." per baselined oversize file that grew (open orders
# still add to those files; splitting them is its own order), "NOTE:" per baselined one now fixed, and a closing "Standards:" count line.
# Exit 0 clean, 1 new violations, 2 bad input.
param([string]$Root = '', [string]$Baseline = '', [switch]$WriteBaseline, [string]$AnalyzerModule = 'PSScriptAnalyzer')
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not (Test-Path -LiteralPath $Root)) { Write-Output "standards: folder not found: $Root"; exit 2 }
if (-not $Baseline) { $Baseline = Join-Path $Root 'kitchen\lint-baseline.json' }
. (Join-Path $PSScriptRoot 'standards-lib.ps1')

try { $files = Get-StdFiles $Root } catch { Write-Output $_.Exception.Message; exit 2 }
$now = Get-StdViolations $Root $files

# PSScriptAnalyzer, Error severity only (warnings are advice). Used only when installed; never installed from here.
if (Get-Module -ListAvailable -Name $AnalyzerModule) {
    Import-Module $AnalyzerModule -ErrorAction Stop
    foreach ($rel in ($files | Where-Object { $_ -match '\.(ps1|psm1)$' })) {
        $n = @(Invoke-ScriptAnalyzer -Path (Join-Path $Root $rel) -Severity Error -ErrorAction SilentlyContinue).Count
        if ($n) { $now["analyzer|$rel"] = $n }
    }
} else {
    Write-Output "SKIP: $AnalyzerModule is not installed, so the analyzer rule was not checked (install it by hand if wanted; this script never installs)"
}

if ($WriteBaseline) {
    $sorted = [ordered]@{}; foreach ($k in ($now.Keys | Sort-Object)) { $sorted[$k] = $now[$k] }
    $doc = [ordered]@{
        note       = 'Known violations of kitchen/STANDARDS.md, recorded by scripts/check-standards.ps1 -WriteBaseline. rule|file -> size (size: lines; header: 1; python, urlsecret, analyzer: hits). Only shrink it; a line may be removed once fixed.'
        violations = $sorted
    }
    $doc | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Baseline -Encoding utf8
    Write-Output "Standards: baseline written with $($now.Count) known violations to $Baseline"
    exit 0
}

$base = @{}
if (Test-Path -LiteralPath $Baseline) {
    try { $j = Get-Content -LiteralPath $Baseline -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Output "standards: baseline is not valid JSON: $Baseline"; exit 2 }
    if ($j.violations) { foreach ($k in $j.violations.Keys) { $base[$k] = [int]$j.violations[$k] } }
} else {
    Write-Output "NOTE: no baseline at $Baseline, so every violation counts as new"
}
Write-Output "Standards: baseline holds $($base.Count) known violations"

$why = @{
    size      = "is over $script:StdMaxLines lines; split it by seam"
    header    = "has no two-line header (line 1 what it owns, line 2 who calls it; '#' in PowerShell, '//' in JavaScript)"
    python    = 'runs bare python/python3; use uv run'
    urlsecret = 'writes a credential-looking literal into a URL query; build it at runtime and keep it out of URLs'
    analyzer  = "has PSScriptAnalyzer errors (Invoke-ScriptAnalyzer -Severity Error)"
}
$fail = 0; $warn = 0
foreach ($k in $now.Keys) {
    $rule, $rel = $k -split '\|', 2
    if (-not $base.ContainsKey($k)) { $fail++; Write-Output "FAIL: $rule $rel $($why[$rule]) (now $($now[$k]))"; continue }
    if ($now[$k] -le $base[$k]) { continue }
    if ($rule -eq 'size') { $warn++; Write-Output "WARN: size $rel grew: baseline $($base[$k]) lines, now $($now[$k]); split it by seam when its open orders land"; continue }
    $fail++; Write-Output "FAIL: $rule $rel got worse: $($now[$k]), baseline $($base[$k]); it $($why[$rule])"
}
foreach ($k in $base.Keys) { if (-not $now.Contains($k)) { Write-Output "NOTE: $($k -replace '\|', ' ') is fixed; remove it from the baseline" } }
Write-Output "Standards: $($files.Count) files checked, $($now.Count) violations ($($now.Count - $fail) baselined), $warn grew, $fail new"
exit ([int]($fail -gt 0))
