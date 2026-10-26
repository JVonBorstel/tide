# Restore drill: prove last night's off-drive backup can actually be restored (an untested backup is a hope). No AI. Read-only on the
# backup and on the kitchen: copies the newest <Source>\<yyyy-MM-dd> folder into a throwaway folder in TEMP, then checks that every
# .json parses, every .jsonl line parses, the files the kitchen cannot rebuild are present (ideas.json, kitchen.json, jobs), and that
# the job count is close to the live kitchen's. Writes <kitchen>\watch\restore.json (heartbeat, everyMin = 1 week) and removes the copy.
#   restore-drill.ps1 [-Source D:\backups\kitchen] [-Json]       Exit 0 = restorable, 3 = problems, 2 = no backup to test.
param([string]$Source = 'D:\backups\kitchen', [switch]$Json)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$now = [DateTime]::UtcNow; $problems = [Collections.Generic.List[string]]::new()
$newest = @(Get-ChildItem -LiteralPath $Source -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^\d{4}-\d{2}-\d{2}$' | Sort-Object Name -Descending | Select-Object -First 1)
if (-not $newest) { $m = "no backup folder to test in $Source"; if ($Json) { @{ ok = $false; error = $m } | ConvertTo-Json -Compress } else { Write-Output "ERROR: $m" }; exit 2 }
$work = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-restore-' + [guid]::NewGuid().ToString('N'))
$files = 0; $jsonN = 0; $lines = 0; $jobs = 0
try {
    Copy-Item -LiteralPath $newest[0].FullName -Destination $work -Recurse -ErrorAction Stop
    foreach ($f in Get-ChildItem -LiteralPath $work -Recurse -File) {
        $files++
        if ($f.Extension -eq '.json') {
            $jsonN++
            try { $null = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop } catch { $problems.Add("$($f.FullName.Substring($work.Length + 1)) does not parse") }
            if ($f.Name -match '^J\d+\.json$') { $jobs++ }
        } elseif ($f.Extension -eq '.jsonl') {
            $n = 0; foreach ($l in [IO.File]::ReadLines($f.FullName)) { $n++; if ($l.Trim()) { $lines++; try { $null = $l | ConvertFrom-Json -ErrorAction Stop } catch { $problems.Add("$($f.Name) line $n does not parse"); break } } }
        }
    }
    foreach ($must in 'ideas.json', 'kitchen.json') { if (-not @(Get-ChildItem -LiteralPath $work -Recurse -File -Filter $must).Count) { $problems.Add("the backup has no $must") } }
    $live = @(Get-ChildItem -LiteralPath (Join-Path $root 'jobs') -Filter 'J*.json' -File -ErrorAction SilentlyContinue).Count
    if (-not $jobs) { $problems.Add('the backup has no job files') }
    elseif ($live -and $jobs -lt [math]::Floor($live * 0.9)) { $problems.Add("the backup has $jobs job files but the kitchen has $live (more than 10% missing)") }
} catch { $problems.Add("could not copy the backup: $($_.Exception.Message)") }
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
$ok = $problems.Count -eq 0
$wd = Join-Path $root 'watch'; New-Item -ItemType Directory -Force -Path $wd | Out-Null
$hb = [ordered]@{ name = 'restore'; lastRun = $now.ToString('o'); everyMin = 10080; checked = $files; found = $problems.Count; backup = $newest[0].Name; jobs = $jobs; jsonFiles = $jsonN; jsonlLines = $lines; problems = @($problems | ForEach-Object { @{ say = $_ } }) }
$t = Join-Path $wd 'restore.json.tmp'; $hb | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $t -Encoding utf8; Move-Item -LiteralPath $t -Destination (Join-Path $wd 'restore.json') -Force
if ($Json) { [ordered]@{ ok = $ok; backup = $newest[0].Name; files = $files; jobs = $jobs; jsonFiles = $jsonN; jsonlLines = $lines; problems = @($problems | ForEach-Object { @{ say = "Restore drill: $_" } }) } | ConvertTo-Json -Depth 4 -Compress }
else { Write-Output "Restore drill of $($newest[0].Name): $files files, $jobs jobs, $jsonN JSON files, $lines log lines. $(if ($ok) { 'Restorable.' } else { "$($problems.Count) problem(s):" })"; $problems | ForEach-Object { "  $_" } }
if (-not $ok) { exit 3 }
exit 0
