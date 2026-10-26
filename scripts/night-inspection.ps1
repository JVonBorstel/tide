# Night inspection (TD-EH-03b): the full suite on a Tower's current main, on this PC (no GitHub minutes), once a night.
# Nothing else checks main between Yard merges: a Foreman merge needs only the quick checks, so main could go red unseen for hours.
# Started by the Yard's standing order "night inspection" (kitchen.json, a watcher order: it also runs while the Yard is paused, since it
# only reads main and writes the main status). By hand:
#   pwsh -File scripts/night-inspection.ps1 [-Repo <the Tower's checkout>] [-KitchenRoot <state folder>] [-TimeoutSeconds 5400] [-MaxMB 10000]
# It adds no test logic of its own: it runs scripts/recheck-main.ps1 -All -SkipUnchanged (the same throwaway worktree, tests Step and
# Set-MainStatus as a recheck by hand) inside scripts/run-bounded.ps1, so the whole night is bounded in time and memory.
#  - main unchanged since its last green full run: skipped, and the line says so (no suite runs);
#  - otherwise every suite runs and the main status is written green or red, exactly as recheck-main writes it.
# Every night leaves one line in <kitchen>\night-inspection.jsonl:
#   { at, repo, result: green|red|skipped|no-verdict|timeout|memory|error, exit, sec, said }   (said = recheck-main's last line)
# A run stopped by the time limit leaves its throwaway worktree for the next recheck to sweep (recheck-main step 3).
# Exit: recheck-main's own (0 green, 1 red, 2 nothing recorded, 3 skipped), 124 timeout, 125 memory cap.
param(
    [string]$Repo = '',
    [string]$KitchenRoot = '',
    [int]$TimeoutSeconds = 5400,
    [int]$MaxMB = 10000
)
$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if ($KitchenRoot) { $env:BRAIN_KITCHEN = $KitchenRoot }   # recheck-main and Set-MainStatus read it
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$bounded = Join-Path $PSScriptRoot 'run-bounded.ps1'
$recheck = Join-Path $PSScriptRoot 'recheck-main.ps1'
$pwsh = (Get-Process -Id $PID).Path
$sw = [Diagnostics.Stopwatch]::StartNew()
$out = ''; $code = -1
# run-bounded's -CommandFile {exe, args} carries the arguments exactly (a pwsh -File command line cannot hand it a -ScriptArgs array)
$cmdFile = Join-Path ([IO.Path]::GetTempPath()) ("night-inspection-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
try {
    @{ exe = $pwsh; args = @('-NoProfile', '-NonInteractive', '-File', $recheck, '-Repo', $Repo, '-All', '-SkipUnchanged') } | ConvertTo-Json | Set-Content -LiteralPath $cmdFile -Encoding utf8
    $out = & $pwsh -NoProfile -File $bounded -Script $recheck -CommandFile $cmdFile -TimeoutSeconds $TimeoutSeconds -MaxMB $MaxMB 2>&1 | Out-String
    $code = $LASTEXITCODE
} catch { $out = "night-inspection: could not start the recheck ($($_.Exception.Message))" }
finally { Remove-Item -LiteralPath $cmdFile -Force -ErrorAction SilentlyContinue }
$result = switch ($code) { 0 { 'green' } 1 { 'red' } 2 { 'no-verdict' } 3 { 'skipped' } 124 { 'timeout' } 125 { 'memory' } default { 'error' } }
$said = @($out -split "`r?`n" | Where-Object { $_ -match '^(recheck-main|night-inspection|run-bounded): ' } | Select-Object -Last 1)
$said = if ($said.Count) { "$($said[0])".Trim() } else { "no line from recheck-main (exit $code)" }
if ($code -eq 124) { $said = "stopped at the $TimeoutSeconds s limit; main is not proven either way. $said" }
if ($said.Length -gt 400) { $said = $said.Substring(0, 400) }
$line = [ordered]@{ at = [DateTime]::UtcNow.ToString('o'); repo = $Repo; result = $result; exit = $code; sec = [int]$sw.Elapsed.TotalSeconds; said = $said }
try {
    New-Item -ItemType Directory -Force -Path $kroot | Out-Null
    Add-Content -LiteralPath (Join-Path $kroot 'night-inspection.jsonl') -Value ($line | ConvertTo-Json -Compress) -Encoding utf8
} catch { Write-Output "night-inspection: could not write the night's line ($($_.Exception.Message))" }
if ($out) { Write-Output $out.Trim() }
Write-Output "night-inspection: $result (exit $code, $($line.sec) s): $said"
exit $code
