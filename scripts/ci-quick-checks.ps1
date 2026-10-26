# Fast, cheap repo checks for the CI "checks" job (runs on ubuntu in a few minutes; also runnable locally). No model, no network.
#   1. every .ps1 parses (PowerShell AST parser)
#   2. every .mjs/.js under kitchen/ and pass-app/ passes `node --check`
#   3. every .json under kitchen/ is valid JSON
#   4. no secret-shaped string in any tracked text file (uses scripts/secret-patterns.ps1; value is never printed, only file:line and pattern name)
# Prints "FAIL: ..." per problem and a summary. Exit 0 clean, 1 problems.
param([string]$Root = (Join-Path $PSScriptRoot '..'))
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path
$fails = [Collections.Generic.List[string]]::new()
$counts = [ordered]@{ ps1 = 0; node = 0; json = 0; secretFiles = 0 }
$tracked = @(& git -C $Root ls-files -z 2>$null | Out-String) -split "`0" | Where-Object { $_ }
if (-not $tracked) { $tracked = Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\/](\.git|node_modules|target)[\/]' } | ForEach-Object { [IO.Path]::GetRelativePath($Root, $_.FullName) } }
$tracked = @($tracked | ForEach-Object { $_.Replace('\', '/')})

foreach ($rel in ($tracked | Where-Object { $_ -match '\.ps1$' })) {
    $counts.ps1++
    $tokens = $null; $errs = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $rel), [ref]$tokens, [ref]$errs)
    foreach ($e in $errs) { $fails.Add("FAIL: $rel`:$($e.Extent.StartLineNumber) PowerShell parse error: $($e.Message)") }
}

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
foreach ($rel in ($tracked | Where-Object { $_ -match '^(kitchen|pass-app)/.+\.(mjs|js)$' })) {
    if (-not $node) { $fails.Add('FAIL: node not found on PATH'); break }
    $counts.node++
    $out = & $node --check (Join-Path $Root $rel) 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { $fails.Add("FAIL: $rel node --check failed: $($out.Trim() -split "`n" | Select-Object -First 3 | Out-String)") }
}

foreach ($rel in ($tracked | Where-Object { $_ -match '^kitchen/.+\.json$' })) {
    $counts.json++
    try { [void](Get-Content -LiteralPath (Join-Path $Root $rel) -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop) }
    catch { $fails.Add("FAIL: $rel is not valid JSON: $($_.Exception.Message)") }
}

# Secret scan with the repo's own shapes. Only text files (no NUL in the first 4 KB), skip big files.
. (Join-Path $Root 'scripts/secret-patterns.ps1')
$allow = @{}
$allowFile = Join-Path $Root '.github/secret-scan-allow.txt'
if (Test-Path -LiteralPath $allowFile) {
    foreach ($l in [IO.File]::ReadLines($allowFile)) {
        if ($l -match '^\s*#' -or -not $l.Trim()) { continue }
        $parts = $l -split "`t", 2
        if ($parts.Count -ne 2) { $fails.Add("FAIL: .github/secret-scan-allow.txt bad line (want path<TAB>substring): $l"); continue }
        if (-not $allow.ContainsKey($parts[0])) { $allow[$parts[0]] = [Collections.Generic.List[string]]::new() }
        $allow[$parts[0]].Add($parts[1])
    }
}
foreach ($rel in $tracked) {
    if ($rel -eq '.github/secret-scan-allow.txt') { continue }   # the allowlist quotes its own fixtures
    $skips = $allow[$rel]
    if ($skips -and $skips.Contains('*')) { continue }
    $p = Join-Path $Root $rel
    $fi = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
    if (-not $fi -or $fi.Length -gt 2MB -or $fi.Length -eq 0) { continue }
    $head = [IO.File]::ReadAllBytes($p) | Select-Object -First 4096
    if ($head -contains 0) { continue }
    $counts.secretFiles++
    $n = 0
    foreach ($line in [IO.File]::ReadLines($p)) {
        $n++
        if ($skips -and @($skips | Where-Object { $line.Contains($_) }).Count) { continue }
        $hit = Find-SecretPattern $line
        if ($hit) { $fails.Add("FAIL: $rel`:$n secret-shaped string ($hit); value not shown") }
    }
}

foreach ($f in $fails) { Write-Output $f }
Write-Output ("Quick checks: {0} ps1 parsed, {1} js checked, {2} json parsed, {3} files secret-scanned; {4} problem(s)" -f $counts.ps1, $counts.node, $counts.json, $counts.secretFiles, $fails.Count)
if ($fails.Count) { exit 1 } else { exit 0 }
