# Kitchen check: READ-ONLY report of resource pressure and likely runaway/orphan processes. Never kills anything.
# Exit 0 = fine, 1 = at least one WARN. Run at session start/end and from Context Guard follow-ups.
param([double]$MinFreeRamGB = 2, [double]$MinFreeCGB = 5, [int]$MaxProcMB = 1500, [int]$MaxTempGB = 4, [int]$MaxCpuSec = 900, [int]$MaxFileMB = 500, [string]$TempDir = $env:TEMP, [int]$MaxTickAgeMin = 10)
$ErrorActionPreference = 'Continue'
$warn = 0
$os = Get-CimInstance Win32_OperatingSystem
$ramFree = $os.FreePhysicalMemory / 1MB
$cFree = (Get-PSDrive C).Free / 1GB
Write-Output ("KITCHEN {0}  RAM free {1:N1} GB  C: free {2:N1} GB" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $ramFree, $cFree)
if ($ramFree -lt $MinFreeRamGB) { Write-Output "WARN low RAM ($([math]::Round($ramFree,1)) GB free)"; $warn++ }
if ($cFree -lt $MinFreeCGB) { Write-Output "WARN low C: space ($([math]::Round($cFree,1)) GB free)"; $warn++ }

$names = 'pwsh', 'powershell', 'java', 'node', 'python', 'python3', 'python3.13', 'pythonw', 'llama-server', 'ollama', 'adb', 'agy', 'codex', 'qemu-system-x86_64'
$ids = @{}; Get-CimInstance Win32_Process | % { $ids[[int]$_.ProcessId] = $_ }
foreach ($pr in Get-Process -ErrorAction SilentlyContinue | ? { $names -contains $_.Name }) {
    $mb = [int]($pr.WorkingSet64 / 1MB)
    $info = $ids[[int]$pr.Id]
    $orphan = $info -and $info.ParentProcessId -and -not $ids.ContainsKey([int]$info.ParentProcessId)
    $mins = if ($pr.StartTime) { [int]((Get-Date) - $pr.StartTime).TotalMinutes } else { 0 }
    # a local model server (the tailor line keeps one resident on purpose) is normal state, so its size is shown, never warned
    if ($mb -gt $MaxProcMB -and $pr.Name -in 'llama-server', 'ollama') { Write-Output ("INFO model loaded: {0} pid {1} {2} MB" -f $pr.Name, $pr.Id, $mb); continue }
    if ($mb -gt $MaxProcMB) {
        Write-Output ("WARN heavy: {0} pid {1} {2} MB, running {3} min{4}" -f $pr.Name, $pr.Id, $mb, $mins, $(if ($orphan) { ', parent gone (orphan)' } else { '' }))
        $warn++
    }
}
foreach ($pr in Get-Process -ErrorAction SilentlyContinue | ? { $names -contains $_.Name -and $_.CPU -gt $MaxCpuSec }) {
    Write-Output ("WARN busy: {0} pid {1} used {2} CPU-seconds (possible runaway loop)" -f $pr.Name, $pr.Id, [int]$pr.CPU); $warn++
}
# Visual Studio installer package caches (a random 8-letter TEMP folder full of <Package>.<20 hex> folders) are regenerable and Jordan's
# call to clear: they are reported ONCE (remembered in brain-guard state), and left out of the TEMP total and the huge-file check, so the
# warning every session (and every 10 min from Context Guard) is not the same unactionable line that hides a real new one.
# (2>$null: a folder another process deletes mid-scan throws even under SilentlyContinue; the scan goes on)
$stateDir = if ($env:BRAIN_GUARD_STATE) { $env:BRAIN_GUARD_STATE } else { Join-Path $env:LOCALAPPDATA 'brain-guard' }
$vsCaches = @(Get-ChildItem -LiteralPath $TempDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^[a-z0-9]{8}$' } | Where-Object {
    $sub = @(Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue); $sub.Count -ge 3 -and @($sub | Where-Object { $_.Name -match '\.[0-9A-F]{20}$' }).Count -ge [math]::Ceiling($sub.Count * 0.8) })
$skip = @($vsCaches | ForEach-Object { $_.FullName.TrimEnd('\') + '\' })
$tempFiles = @(Get-ChildItem -LiteralPath $TempDir -Recurse -File -Force -ErrorAction SilentlyContinue 2>$null | Where-Object { $fp = $_.FullName; -not @($skip | Where-Object { $fp.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count })
foreach ($f in $tempFiles | ? { $_.Length -gt ($MaxFileMB * 1MB) }) {
    Write-Output ("WARN huge file: {0} ({1} MB)" -f $f.FullName, [int]($f.Length / 1MB)); $warn++
}
$t = ($tempFiles | Measure-Object Length -Sum).Sum / 1GB
if ($vsCaches.Count) {
    $seenPath = Join-Path $stateDir 'vs-caches-reported.txt'; $seen = @(try { Get-Content -LiteralPath $seenPath -ErrorAction Stop } catch { })
    $newOnes = @($vsCaches | Where-Object { $_.Name -notin $seen })
    $vsGB = 0; foreach ($c in $vsCaches) { $vsGB += (Get-ChildItem -LiteralPath $c.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB }
    if ($newOnes.Count) {
        Write-Output ("INFO Visual Studio installer caches in TEMP ({0:N1} GB, regenerable; clearing them is Jordan's call, reported once): {1}" -f $vsGB, (($newOnes | ForEach-Object { "$($_.Name) ($($_.LastWriteTime.ToString('yyyy-MM-dd')))" }) -join ', '))
        try { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null; Set-Content -LiteralPath $seenPath -Value @(@($seen) + @($newOnes.Name) | Select-Object -Unique) } catch { }
    }
}
Write-Output ("TEMP {0:N1} GB{1}" -f $t, $(if ($vsCaches.Count) { " (plus {0:N1} GB of Visual Studio caches)" -f $vsGB } else { '' }))
if ($t -gt $MaxTempGB) {
    # name the target: the three biggest TEMP folders with their age, so the warning says what to look at
    $top = @(Get-ChildItem -LiteralPath $TempDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName.TrimEnd('\') + '\' -notin $skip } | ForEach-Object { [pscustomobject]@{ n = $_.Name; d = $_.LastWriteTime; gb = (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB } } | Sort-Object gb -Descending | Select-Object -First 3)
    Write-Output ("WARN TEMP large; biggest: {0}. Clear what is regenerable (with Jordan's yes)" -f (($top | ForEach-Object { "{0} {1:N1} GB ({2:yyyy-MM-dd})" -f $_.n, $_.gb, $_.d }) -join ', ')); $warn++
}
# the supervisor: nothing else notices when its scheduled task stops starting (the watchdog lives inside the tick). Jordan's PAUSED
# marker (kitchen.ps1 pause) means he stopped it on purpose: shown, never warned.
$kr = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$pausedPath = Join-Path $kr 'PAUSED'
if (Test-Path -LiteralPath $pausedPath) { Write-Output "PAUSED the kitchen supervisor is paused by Jordan ($((Get-Item -LiteralPath $pausedPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))); kitchen.ps1 resume starts it again" }
else {
    try { $lt = (Get-Content -LiteralPath (Join-Path $kr 'supervisor.json') -Raw -ErrorAction Stop | ConvertFrom-Json).lastTick; if ($lt) { $age = ((Get-Date).ToUniversalTime() - ([DateTime]$lt).ToUniversalTime()).TotalMinutes; if ($age -gt $MaxTickAgeMin) { Write-Output ("WARN kitchen supervisor not ticking (last tick {0} min ago)" -f [int]$age); $warn++ } } } catch { }
    # the real kitchen's task: a versioned Store pwsh path dies at the next PowerShell update (0x80070002 every minute); a disabled task is deliberate
    if ([IO.Path]::GetFullPath($kr) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))) {
        try {
            # its name from scripts/task-names.json ([old, new]; renamed at S4, Jordan's tap): the newest one registered, else the old one
            $names = @(try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'task-names.json') -Raw -ErrorAction Stop | ConvertFrom-Json).supervisor | Where-Object { $_ -is [string] -and $_.Trim() } } catch { })
            if (-not $names.Count) { $names = @('Kitchen-Supervisor') }
            $task = @(for ($i = $names.Count - 1; $i -ge 0; $i--) { Get-ScheduledTask -TaskName $names[$i] -ErrorAction SilentlyContinue })[0]
            if (-not $task) { $task = Get-ScheduledTask -TaskName $names[0] -ErrorAction Stop }
            if ($task.State -ne 'Disabled') {
                $exe = [Environment]::ExpandEnvironmentVariables([string]$task.Actions[0].Execute)
                if ($exe -match '\\WindowsApps\\Microsoft\.PowerShell_' -or -not (Test-Path -LiteralPath $exe)) { Write-Output "WARN $($task.TaskName) task runs $exe (missing or version-pinned); scripts/install-tasks.ps1 re-registers it (Jordan's yes)"; $warn++ }
            }
        } catch { }
    }
}
# notes Jordan left in the Board while Claude was away (not a warning; Claude reads them first)
try { $lj = Join-Path $env:LOCALAPPDATA 'brain-kitchen\lead.json'; if (Test-Path $lj) { $nn = @((Get-Content $lj -Raw | ConvertFrom-Json).notes | Where-Object { $_.status -in 'open', 'kitchen' }).Count; if ($nn) { Write-Output "NOTES Jordan left $nn note(s) in the Board for Claude: pwsh kitchen/lead.ps1 notes" } } } catch { }
if ($warn -eq 0) { Write-Output 'OK' } else { Write-Output "$warn warning(s). Report to Jordan; do not kill without a yes." }
exit ([int]($warn -gt 0))
