# Privacy map check: owns the rule that the data map (gemini-brain projects/tide/privacy-map.md) still matches the code: every cook in
# kitchen/kitchen.json, every recipe with private or career handling, and every cited file:line. Called by tests/Test-Privacy.ps1 (fixtures) and by hand after the map or the kitchen changes.
#   pwsh -File scripts/privacy-map-check.ps1 [-MapPath <privacy-map.md>] [-RepoRoot <brain-monitor folder>] [-Quiet]
# Map format: one markdown table (5 columns: Data | Where it lives | What may leave | Through which path | Rule). Cooks are written
# `cook:<name>`, recipes `recipe:<name>`, citations `path/to/file:<line>` in backticks, relative to the repo root. Every row's last
# column cites code or says "unknown". Read-only: opens only the map, kitchen.json, kitchen/recipes/*.json and the cited files.
# Exit: 0 the map matches, 1 a mismatch (each one printed as FAIL), 2 cannot run (map or kitchen.json missing or unreadable).
param([string]$MapPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain\projects\tide\privacy-map.md'), [string]$RepoRoot = '', [switch]$Quiet)
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
function Stop-Check([string]$why) { Write-Output "privacy-map-check: cannot run: $why"; exit 2 }
if (-not (Test-Path -LiteralPath $MapPath -PathType Leaf)) { Stop-Check "no map at $MapPath" }
$kjPath = Join-Path $RepoRoot 'kitchen\kitchen.json'
try { $kj = Get-Content -LiteralPath $kjPath -Raw | ConvertFrom-Json -AsHashtable } catch { Stop-Check "kitchen.json at $kjPath is missing or not valid JSON" }
if (-not ($kj.suppliers -is [Collections.IDictionary]) -or -not $kj.suppliers.Count) { Stop-Check "kitchen.json has no suppliers" }

$fails = [Collections.Generic.List[string]]::new()
# ---- the table: header, separator, rows ----
$rows = @(Get-Content -LiteralPath $MapPath | Where-Object { $_ -match '^\s*\|' })
$body = @($rows | Select-Object -Skip 2 | Where-Object { $_ -notmatch '^\s*\|[\s:|-]+\|\s*$' })
if ($rows.Count -lt 3 -or $rows[1] -notmatch '^\s*\|[\s:|-]+\|\s*$' -or -not $body.Count) { Stop-Check "the map has no table (header, separator and at least one row)" }
$table = $body -join "`n"
foreach ($r in $body) {
    $cells = @($r.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    if ($cells.Count -ne 5) { $fails.Add("row '$($cells[0])' has $($cells.Count) columns, not 5"); continue }
    if ($cells[4] -notmatch '`[^`\s]+:\d+`' -and $cells[4] -notmatch '(?i)\bunknown\b') { $fails.Add("row '$($cells[0])' cites no code and does not say unknown") }
}
# ---- every cook supplier is mapped; every cook named still exists ----
$cooks = @($kj.suppliers.Keys | ForEach-Object { [string]$_ })
foreach ($c in $cooks) { if ($table -notmatch ('(?<![\w-])cook:' + [regex]::Escape($c) + '(?![\w-])')) { $fails.Add("cook '$c' (kitchen.json suppliers) is not in the map; add cook:$c to the row(s) it can carry") } }
foreach ($m in [regex]::Matches($table, '(?<![\w-])cook:([\w-]+)')) { if ($cooks -notcontains $m.Groups[1].Value) { $fails.Add("the map names cook:$($m.Groups[1].Value), which is not in kitchen.json suppliers") } }
# ---- every recipe with private or career handling is mapped; every recipe named still exists ----
$recipeDir = Join-Path $RepoRoot 'kitchen\recipes'; $flagged = @(); $allRecipes = @()
foreach ($f in @(Get-ChildItem -LiteralPath $recipeDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $allRecipes += $f.BaseName; $raw = Get-Content -LiteralPath $f.FullName -Raw
    try { $r = $raw | ConvertFrom-Json -AsHashtable } catch { $fails.Add("recipe $($f.Name) is not valid JSON"); continue }
    $why = if ($r.private -eq $true) { 'private' } elseif (@($r.steps | Where-Object { $_.args -is [Collections.IDictionary] -and $_.args.Private -eq $true }).Count) { 'a Private step' }
           elseif ($raw -match '\{\{(resume|claims)\}\}') { 'reads the resume or claims' } elseif ($raw -match '(?i)projects(\\\\|/)+career') { 'writes or reads the career folder' } else { '' }
    if ($why) { $flagged += $f.BaseName; if ($table -notmatch ('(?<![\w-])recipe:' + [regex]::Escape($f.BaseName) + '(?![\w-])')) { $fails.Add("recipe '$($f.BaseName)' ($why) is not in the map; add recipe:$($f.BaseName)") } }
}
foreach ($m in [regex]::Matches($table, '(?<![\w-])recipe:([\w-]+)')) { if ($allRecipes -notcontains $m.Groups[1].Value) { $fails.Add("the map names recipe:$($m.Groups[1].Value), which has no kitchen/recipes file") } }
# ---- every cited file:line still exists ----
$cites = @([regex]::Matches($table, '`([A-Za-z0-9_.\-/\\]+\.[A-Za-z0-9]+):(\d+)`') | ForEach-Object { "$($_.Groups[1].Value):$($_.Groups[2].Value)" } | Select-Object -Unique)
$lines = @{}
foreach ($c in $cites) {
    $i = $c.LastIndexOf(':'); $rel = $c.Substring(0, $i); $n = [int]$c.Substring($i + 1)
    if ($rel -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($rel)) { $fails.Add("citation $c leaves the repo"); continue }
    $p = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $fails.Add("dead citation $c (no such file)"); continue }
    if (-not $lines.ContainsKey($p)) { $lines[$p] = @(Get-Content -LiteralPath $p).Count }
    if ($n -lt 1 -or $n -gt $lines[$p]) { $fails.Add("dead citation $c (the file has $($lines[$p]) lines)") }
}
foreach ($f in $fails) { Write-Output "FAIL: $f" }
if ($fails.Count) { Write-Output "privacy-map-check: $($fails.Count) problem(s) in $MapPath"; exit 1 }
if (-not $Quiet) { Write-Output "privacy-map-check: OK ($($body.Count) rows, $($cites.Count) citations, $($cooks.Count) cooks, $($flagged.Count) private/career recipes)" }
exit 0
