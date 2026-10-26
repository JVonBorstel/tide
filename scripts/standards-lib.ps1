# Owns the mechanical checks of kitchen/STANDARDS.md (file size, two-line header, bare python, secrets in URLs) and the file/function readers.
# Called by (dot-sourced): scripts/check-standards.ps1, scripts/make-map.ps1, scripts/dead-code.ps1, scripts/quality/metrics.ps1.

$script:StdMaxLines = 600
$script:StdExt = '\.(ps1|psm1|mjs|js)$'

# The code files the standards cover: tracked .ps1/.psm1/.mjs/.js under the given top folders (tests/fixtures holds deliberately bad files).
function Get-StdFiles([string]$Root, [string[]]$Dirs = @('kitchen', 'scripts', 'pass-app', 'tests')) {
    $all = @(& git -C $Root ls-files 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "standards: $Root is not a git repository" }
    @($all | Where-Object { $_ -match $script:StdExt -and $_ -notmatch '(^|/)(node_modules|fixtures)/' -and $Dirs -contains ($_ -split '/')[0] } |
        Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf } | Sort-Object)
}

function Get-StdLines([string]$Path) { @([IO.File]::ReadAllLines($Path)) }

# The two-line header: after an optional '#!' line, the first two lines are comments ('#' in PowerShell, '//' in JavaScript).
# '#requires' and '<#' do not count. Returns the two lines without their markers, or $null when the file has no header.
function Get-StdHeader([string]$Path, [string[]]$Lines = $null) {
    if ($null -eq $Lines) { $Lines = Get-StdLines $Path }
    $i = 0; if ($Lines.Count -gt 0 -and $Lines[0] -match '^#!') { $i = 1 }
    if ($Lines.Count -lt $i + 2) { return $null }
    $pat = if ($Path -match '\.(mjs|js)$') { '^//\s?(.*\S.*)$' } else { '^#(?!requires|!)\s?(.*\S.*)$' }
    $a = $Lines[$i] -match $pat; $h1 = if ($a) { $Matches[1].Trim() } else { '' }
    $b = $Lines[$i + 1] -match $pat; $h2 = if ($b) { $Matches[1].Trim() } else { '' }
    if (-not ($a -and $b)) { return $null }
    @($h1, $h2)
}

# Functions a file defines: PowerShell from the parser (exact), JavaScript by pattern (function x(, const x = (...) =>, async function x().
function Get-StdFunctions([string]$Path) {
    if ($Path -match '\.(ps1|psm1)$') {
        $tok = $null; $err = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
        return @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name -replace '^(?i)(script|global|local|private):', '' } | Select-Object -Unique)
    }
    $names = foreach ($l in [IO.File]::ReadLines($Path)) {
        if ($l -match '^\s*(export\s+)?(default\s+)?(async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(') { $Matches[4] }
        elseif ($l -match '^\s*(export\s+)?(const|let)\s+([A-Za-z_$][\w$]*)\s*=\s*(async\s+)?(\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>') { $Matches[3] }
    }
    @($names | Select-Object -Unique)
}

# Bare python: a PowerShell command named python/python3(.exe), or a Node exec/spawn of one. Count per file.
function Get-StdBarePython([string]$Path, [string[]]$Lines) {
    if ($Path -match '\.(ps1|psm1)$') {
        $tok = $null; $err = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
        return @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^(?i)(python|python3)(\.exe)?$' }, $true)).Count
    }
    @($Lines | Where-Object { $_ -match '\b(exec|execSync|spawn|spawnSync|execFile|execFileSync)\s*\(\s*[''"`](python|python3)(\.exe)?\b' }).Count
}

# A secret in a URL: a query parameter named like a credential with a literal value (a $variable or ${...} is fine, the value is not written).
function Get-StdUrlSecrets([string[]]$Lines) {
    $names = 'api[_-]?key|apikey|access[_-]?token|token|secret|client[_-]?secret|password|passwd|pwd|sig|signature|key'
    @($Lines | Where-Object { $_ -match "https?://[^\s'""``]*[?&]($names)=(?![`$\{<%]|\s|['""``&]|\)|$)[A-Za-z0-9._~+/-]{6,}" }).Count
}

# Every violation in the repo, as a map "rule|file" -> number (size: lines; header: 1; python and urlsecret: hits).
function Get-StdViolations([string]$Root, [string[]]$Files = $null) {
    if ($null -eq $Files) { $Files = Get-StdFiles $Root }
    $v = [ordered]@{}
    foreach ($rel in $Files) {
        $p = Join-Path $Root $rel; $lines = Get-StdLines $p
        if ($lines.Count -gt $script:StdMaxLines) { $v["size|$rel"] = $lines.Count }
        if ($null -eq (Get-StdHeader $p $lines)) { $v["header|$rel"] = 1 }
        $n = Get-StdBarePython $p $lines; if ($n) { $v["python|$rel"] = $n }
        $n = Get-StdUrlSecrets $lines; if ($n) { $v["urlsecret|$rel"] = $n }
    }
    $v
}
