# A stand-in for the public cleaning (public-tide-clean.ps1, kept outside this repo because its rules name private values) for
# tests/Test-PortPrivate.ps1. Same contract: -Ref <commit> -Out <dir> [-Checkout] [-Patch], or -RulesOnly <dir>; exit 0 / 3 / 2.
# Its one "rule": the synthetic private word PRIVATE-NAME becomes public-name. A line HAND-FIX makes it stop with exit 3 (R4), and a
# file holding REJECT-ME is reported as a cleaning-patch hunk that did not apply there.
[CmdletBinding(DefaultParameterSetName = 'Tree')]
param(
    [Parameter(ParameterSetName = 'Tree', Mandatory)][string]$Ref,
    [Parameter(ParameterSetName = 'Tree', Mandatory)][string]$Out,
    [Parameter(ParameterSetName = 'Tree')][string]$Checkout = '.',
    [Parameter(ParameterSetName = 'Tree')][string]$Patch = '',
    [Parameter(ParameterSetName = 'Rules', Mandatory)][string]$RulesOnly
)
$ErrorActionPreference = 'Stop'
function Rules([string]$Dir) {
    $hand = @()
    foreach ($f in Get-ChildItem -LiteralPath $Dir -Recurse -File -Force) {
        $rel = $f.FullName.Substring($Dir.TrimEnd('\', '/').Length + 1)
        $t = [IO.File]::ReadAllText($f.FullName); $n = $t.Replace('PRIVATE-NAME', 'public-name')
        if ($n -ne $t) { [IO.File]::WriteAllText($f.FullName, $n, [Text.UTF8Encoding]::new($false)); "rule fix: $rel" }
        if ($n -match 'HAND-FIX') { $hand += $rel }
        if ($n -match 'REJECT-ME') { "dropped reject (rules below cover it): $rel" }
    }
    if ($hand) { "HAND FIX NEEDED (user path in code): $($hand -join ', ')"; exit 3 }
}
if ($PSCmdlet.ParameterSetName -eq 'Rules') { Rules $RulesOnly; exit 0 }
$sha = "$(git -C $Checkout rev-parse --verify --quiet "$Ref^{commit}" 2>$null)".Trim()
if (-not $sha) { "clean: $Ref is not a commit"; exit 2 }
"source: $($sha.Substring(0, 7))"
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Path $Out | Out-Null
$tar = Join-Path ([IO.Path]::GetTempPath()) ("fpc-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tar')
git -C $Checkout archive --format=tar -o $tar $sha
tar -xf $tar -C $Out; Remove-Item -LiteralPath $tar
Rules (Resolve-Path -LiteralPath $Out).Path
exit 0
