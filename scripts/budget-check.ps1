# FROZEN per ORG.md: no new features.
# Size budgets for the always-loaded brain files. READ-ONLY. Exit 0 = within budget, 1 = at least one WARN, 2 = bad brain path.
#   pwsh -File scripts/budget-check.ps1 [-BrainPath <home>\gemini-brain]
param([string]$BrainPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain'))
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $BrainPath -PathType Container)) { Write-Output "ERROR brain path not found: $BrainPath"; exit 2 }
$brain = (Resolve-Path -LiteralPath $BrainPath).Path
# rel path, unit, max
$budgets = @(
    @('AGENT_CONTEXT.md', 'lines', 40), @('memory\NOW.md', 'lines', 40), @('memory\HANDOFF.md', 'lines', 120),
    @('memory\BOOT.md', 'chars', 10000), @('memory\ORG.md', 'lines', 80)
)
$warn = 0
foreach ($b in $budgets) {
    $p = Join-Path $brain $b[0]
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Write-Output "INFO $($b[0]) absent (skipped)"; continue }
    $n = if ($b[1] -eq 'lines') { [IO.File]::ReadAllLines($p).Count } else { [IO.File]::ReadAllText($p).Length }
    if ($n -gt $b[2]) { Write-Output "WARN $($b[0]) is $n $($b[1]) (budget $($b[2])); trim it"; $warn++ }
    else { Write-Output "OK   $($b[0]) $n/$($b[2]) $($b[1])" }
}
exit ([int]($warn -gt 0))
