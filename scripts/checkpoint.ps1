# Brain Monitor v0: short-term memory checkpoint. Copies the brain's memory/NOW.md into this repo's data\checkpoints\ with a timestamp,
# so the current directive and open loops survive a bad edit or a lost session. READ-ONLY on the brain; keeps only the newest -Keep copies.
#   pwsh -File scripts/checkpoint.ps1 [-BrainPath <home>\gemini-brain] [-DataDir <dir>] [-Keep 30]
param(
    [string]$BrainPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain'),
    [string]$DataDir = '',
    [ValidateRange(1, 500)][int]$Keep = 30
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $repo 'data' }
$brainRoot = (Resolve-Path $BrainPath).Path
$src = Join-Path $brainRoot 'memory\NOW.md'
# never copy through a link: a linked memory\ or NOW.md could point anywhere (including protected paths)
foreach ($p in (Join-Path $brainRoot 'memory'), $src) {
    if ((Test-Path -LiteralPath $p) -and ([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint)) { Write-Host 'NOW.md or memory/ is a link; not copied'; exit 1 }
}
if (-not (Test-Path -LiteralPath $src)) { Write-Host 'No memory/NOW.md to checkpoint.'; exit 1 }
$dir = Join-Path $DataDir 'checkpoints'; New-Item -ItemType Directory -Force $dir | Out-Null
$dest = Join-Path $dir ("NOW-{0:yyyyMMdd-HHmmss}.md" -f (Get-Date))
Copy-Item -LiteralPath $src -Destination $dest
$old = @(Get-ChildItem $dir -Filter 'NOW-*.md' -File | Sort-Object Name -Descending | Select-Object -Skip $Keep)
foreach ($f in $old) { if ($f.DirectoryName -ieq (Resolve-Path $dir).Path) { Remove-Item -LiteralPath $f.FullName -Force } }
Write-Host "checkpoint: $dest ($($old.Count) older copy(ies) pruned, keeping $Keep)"
