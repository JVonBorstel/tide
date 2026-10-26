# PreCompact hook (also safe to run by hand): rebuild the boot pack with handoff.ps1 using the standard repo list.
# Must never block compaction: always exits 0, prints at most a short line. Bounded by the kitchen/standup timeouts in handoff.ps1.
param(
    [string]$BrainPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain'),
    [string]$Repos = ((@('gemini-brain', 'demo-project', 'source\repos\my-apps', 'source\repos\brain-monitor', 'source\repos\agent-standup') | ForEach-Object { Join-Path ([Environment]::GetFolderPath('UserProfile')) $_ }) -join ';'),
    [string]$KitchenScript = '',
    [int]$KitchenTimeoutSeconds = 30,
    [string]$StandupDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'source\repos\agent-standup')
)
$ErrorActionPreference = 'Continue'
try {
    try { [void]([Console]::In.ReadToEnd()) } catch { }
    $a = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'handoff.ps1'), '-BrainPath', $BrainPath, '-Repos', $Repos, '-KitchenTimeoutSeconds', $KitchenTimeoutSeconds, '-StandupDir', $StandupDir)
    if ($KitchenScript) { $a += @('-KitchenScript', $KitchenScript) }
    $out = & (Get-Process -Id $PID).Path @a 2>&1 | Out-String
    $line = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    Write-Output ("refresh-boot: " + $(if ($line) { $line.Trim().Substring(0, [math]::Min(160, $line.Trim().Length)) } else { 'done' }))
} catch { Write-Output "refresh-boot: skipped ($($_.Exception.Message))" }
exit 0
