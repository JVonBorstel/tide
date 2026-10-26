# Owns the dead-code report: PowerShell functions defined in kitchen/, scripts/, pass-app/ or tests/ whose name appears nowhere else in the repo.
# Called by hand (weekly is enough); report only, it never edits or deletes anything. Facts from a word count, no AI.
#   pwsh -File scripts/dead-code.ps1 [-Root <repo>]
# A name counts as used if it appears as a whole word in any tracked text file (code, JSON recipes, docs) outside its own definition.
# kitchen/MAP.md is skipped because it lists every function. A call built at runtime (& "Get-$x") is missed: check before removing.
param([string]$Root = '')
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not (Test-Path -LiteralPath $Root)) { Write-Output "dead-code: folder not found: $Root"; exit 2 }
. (Join-Path $PSScriptRoot 'standards-lib.ps1')
try { $code = Get-StdFiles $Root } catch { Write-Output "dead-code: $($_.Exception.Message)"; exit 2 }

# every whole word in every tracked text file, counted once per occurrence (case-insensitive, like PowerShell names)
$count = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
$text = @(& git -C $Root ls-files 2>$null | Where-Object { $_ -match '\.(ps1|psm1|mjs|js|json|md|yml|yaml|cmd|html|txt)$' -and $_ -ne 'kitchen/MAP.md' })
foreach ($rel in $text) {
    $p = Join-Path $Root $rel; if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($p), '[A-Za-z_][\w-]*')) {
        $w = $m.Value.TrimEnd('-'); $c = 0; [void]$count.TryGetValue($w, [ref]$c); $count[$w] = $c + 1
    }
}

$defs = foreach ($rel in ($code | Where-Object { $_ -match '\.(ps1|psm1)$' })) {
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $rel), [ref]$tok, [ref]$err)
    foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        [pscustomobject]@{ Name = ($f.Name -replace '^(?i)(script|global|local|private):', ''); File = $rel; Line = $f.Extent.StartLineNumber }
    }
}
$defs = @($defs)
$defCount = @{}; foreach ($d in $defs) { $defCount[$d.Name] = 1 + [int]$defCount[$d.Name] }
$dead = @($defs | Where-Object { $c = 0; [void]$count.TryGetValue($_.Name, [ref]$c); $c -le $defCount[$_.Name] } | Sort-Object File, Line)
foreach ($d in $dead) { Write-Output "$($d.File):$($d.Line) $($d.Name)" }
Write-Output "dead-code: $($dead.Count) of $($defs.Count) PowerShell functions have no reference outside their definition (report only)"
