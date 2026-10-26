# Tests for the doctor's retention and lock (kitchen/kitchen.ps1 doctor, kitchen/jobs-lib.ps1; TARGET W3 in gemini-brain
# projects/tide/arch-10-22): finished orders older than 3 days move to jobs\archive\yyyy-MM\ (idempotent, reversible, readers still see
# them), the daily backups keep 7 dated days whatever hand-made backups sit beside them, and the state lock is never held while the
# watchers run. Private kitchens under TEMP; self-cleaning; no AI, no network.
$ErrorActionPreference = 'Stop'
$k = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1')).Path
$w = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\demo-worker.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-retention-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_UNDER_TEST', 'KITCHEN_ARCHIVE_DAYS', 'KITCHEN_WATCH_IN_TEST', 'KITCHEN_DOCTOR_WATCHERS', 'KITCHEN_SCRATCH_DIR', 'BRAIN_AGENT_DEPTH', 'KITCHEN_JOB') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
$env:KITCHEN_UNDER_TEST = '1'; $env:KITCHEN_ARCHIVE_DAYS = $null; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null
function Put-Job([string]$kr, [string]$id, [string]$status, [double]$ageDays, [hashtable]$extra = @{}) {
    $j = @{ id = $id; name = "job $id"; status = $status; cursor = 1; attempt = 0; created = [DateTime]::UtcNow.AddDays(-$ageDays - 1).ToString('o'); history = @()
        steps = @(@{ script = $w; args = @{ Behavior = 'ok' } }); vars = @{ repo = 'C:\nowhere\repo'; item = 'B-01' }; recipe = 'roadmap-item' }
    foreach ($x in $extra.Keys) { $j[$x] = $extra[$x] }
    $p = Join-Path $kr "jobs\$id.json"; Set-Content -LiteralPath $p -Value ($j | ConvertTo-Json -Depth 6) -Encoding utf8
    (Get-Item -LiteralPath $p).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-$ageDays)
}
function Doctor { (& pwsh -NoProfile -File $k doctor -Json 2>&1 | Out-String) | ConvertFrom-Json }
try {
    $env:KITCHEN_SCRATCH_DIR = Join-Path $root 'scratch'   # the doctor's TEMP prune looks here, never at the real TEMP
    # ---- the archive -------------------------------------------------------------------------------------------------------------
    $kr = Join-Path $root 'k'; New-Item -ItemType Directory -Force -Path (Join-Path $kr 'jobs') | Out-Null; $env:BRAIN_KITCHEN = $kr
    Put-Job $kr J1 'done' 5; Put-Job $kr J2 'closed' 4 @{ replacedBy = 'J1' }; Put-Job $kr J3 'quarantined' 9; Put-Job $kr J4 'done' 1
    Put-Job $kr J5 'done' 6 @{ chefUpdate = @{ step = 0; base = 'abc' } }; Put-Job $kr J6 'pending' 8
    $d1 = Doctor
    $month = [DateTime]::UtcNow.AddDays(-5).ToString('yyyy-MM')
    $lines = @(Get-Content (Join-Path $kr 'jobs\archive\index.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Sort-Object id)
    Check 'archive: done and closed orders untouched 3+ days move to jobs\archive\yyyy-MM\ with one index line each' (
        [int]$d1.archived -eq 2 -and (Test-Path (Join-Path $kr "jobs\archive\$month\J1.json")) -and -not (Test-Path (Join-Path $kr 'jobs\J1.json')) -and
        (@($lines.id) -join ',') -eq 'J1,J2' -and $lines[1].replacedBy -eq 'J1' -and $lines[0].item -eq 'B-01' -and $lines[0].repo -eq 'C:\nowhere\repo')
    Check 'archive: set-aside, recent, pending and Chef-update orders stay in jobs\' (@('J3', 'J4', 'J5', 'J6' | Where-Object { Test-Path (Join-Path $kr "jobs\$_.json") }).Count -eq 4)
    $d2 = Doctor
    Check 'archive: running the doctor again moves nothing and adds no line (idempotent)' ([int]$d2.archived -eq 0 -and @(Get-Content (Join-Path $kr 'jobs\archive\index.jsonl')).Count -eq 2)
    . (Join-Path $PSScriptRoot '..\kitchen\jobs-lib.ps1')
    $all = @(Get-KitchenJobs $kr -WithArchive)
    Check 'readers still see every order: archived ones as their summary (status, replacedBy, vars.item)' (
        $all.Count -eq 6 -and @($all | Where-Object { $_.id -eq 'J2' -and $_.archived -and $_.replacedBy -eq 'J1' -and $_.status -eq 'closed' }).Count -eq 1 -and @($all | Where-Object { $_.id -eq 'J1' -and $_.vars.item -eq 'B-01' }).Count -eq 1)
    Check 'Get-KitchenJobPath finds an archived order (undo-merge of an old merge)' ((Get-KitchenJobPath $kr 'J1') -like "*jobs\archive\$month\J1.json" -and $null -eq (Get-KitchenJobPath $kr 'J99'))
    # reversible: moving the file back makes it a jobs\ order again; its archive line is shadowed, never shown twice
    Move-Item (Join-Path $kr "jobs\archive\$month\J1.json") (Join-Path $kr 'jobs\J1.json'); (Get-Item (Join-Path $kr 'jobs\J1.json')).LastWriteTimeUtc = [DateTime]::UtcNow
    $st = (& pwsh -NoProfile -File $k status -Json | Out-String) | ConvertFrom-Json
    $all = @(Get-KitchenJobs $kr -WithArchive)
    Check 'archive: moving a file back restores the order (status lists it, readers count it once)' (@($st.jobs | Where-Object { $_.id -eq 'J1' }).Count -eq 1 -and @($all | Where-Object { $_.id -eq 'J1' }).Count -eq 1 -and -not @($all | Where-Object { $_.id -eq 'J1' })[0].archived)
    $add = & pwsh -NoProfile -File $k add -Name after-archive -Script $w | Out-String
    Check 'an add after archiving takes the next number (J7)' ($add -match 'added J7')
    $ev = @(Get-Content (Join-Path $kr 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'doctor' })
    Check 'the doctor logs how long it took and how long it held the state lock (doctor.ms, lockMs)' ($ev.Count -ge 2 -and $null -ne $ev[-1].ms -and $null -ne $ev[-1].lockMs -and [int]$ev[-1].lockMs -le [int]$ev[-1].ms -and [int]$ev[0].archived -eq 2)

    # ---- ThreeManualTenDated_SevenDatedKept: dated backups pruned by their date, hand-made ones never take their places --------------
    $bk = Join-Path $kr 'backups'; Remove-Item -Recurse -Force $bk -ErrorAction SilentlyContinue
    foreach ($i in 1..10) { $dd = Join-Path $bk ('{0:yyyyMMdd}' -f (Get-Date).AddDays(-$i)); New-Item -ItemType Directory -Force -Path $dd | Out-Null; Set-Content (Join-Path $dd 'J1.json') '{}' }   # the old layout: backups\yyyyMMdd
    $today = '{0:yyyyMMdd}' -f (Get-Date)
    New-Item -ItemType Directory -Force -Path (Join-Path $bk "jobs-github-$today-1321"), (Join-Path $bk "jobs-size-$today-1145") | Out-Null
    Set-Content (Join-Path $bk "J190-cursor-$($today)160522.json") '{}'
    New-Item -ItemType Directory -Force -Path (Join-Path $bk 'manual\jobs-old-20200101-0000') | Out-Null   # a hand backup far past 14 days
    $d3 = Doctor
    $dated = @(Get-ChildItem (Join-Path $bk 'daily') -Directory | ForEach-Object Name | Sort-Object -Descending)
    $want = @(0..6 | ForEach-Object { '{0:yyyyMMdd}' -f (Get-Date).AddDays(-$_) })
    $manual = @(Get-ChildItem (Join-Path $bk 'manual') | ForEach-Object Name | Sort-Object)
    Check "ThreeManualTenDated_SevenDatedKept: the newest 7 dated days are kept ($($dated -join ' '))" (($dated -join ',') -eq ($want -join ','))
    Check 'hand-made backups move to backups\manual\ and are kept 14 days; older ones go' (($manual -join ',') -eq (@("J190-cursor-$($today)160522.json", "jobs-github-$today-1321", "jobs-size-$today-1145") -join ',') -and [int]$d3.backupsManual -eq 3)
    Check 'nothing is left in the old layout' (-not @(Get-ChildItem $bk | Where-Object { $_.Name -notin 'daily', 'manual' }).Count)
    Check "today's daily backup holds the live jobs and the archive's index" ((Test-Path (Join-Path $bk "daily\$today\J6.json")) -and (Test-Path (Join-Path $bk "daily\$today\index.jsonl")) -and $d3.backup -like "*backups\daily\$today")

    # ---- Doctor3sWatcher_ApproveSucceedsUnder1s: the state lock is free while the doctor's watchers run ------------------------------
    $kw = Join-Path $root 'w'; New-Item -ItemType Directory -Force -Path $kw | Out-Null; $env:BRAIN_KITCHEN = $kw
    & $k add -Name gated -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } -Approve | Out-Null
    & $k tick -Quiet | Out-Null
    $mark = Join-Path $root 'watcher-running.txt'; $fake = Join-Path $root 'slow-watcher.ps1'
    Set-Content $fake "param([switch]`$Json); Set-Content -LiteralPath '$mark' 'x'; Start-Sleep -Seconds 3; Remove-Item -LiteralPath '$mark'; '{`"problems`":[]}'"
    $env:KITCHEN_WATCH_IN_TEST = '1'; $env:KITCHEN_DOCTOR_WATCHERS = $fake
    $doc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-File', $k, 'doctor', '-Quiet' -PassThru -WindowStyle Hidden
    $t0 = Get-Date; while (-not (Test-Path $mark) -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 50 }
    $env:KITCHEN_WATCH_IN_TEST = $null; $env:KITCHEN_DOCTOR_WATCHERS = $null
    $kroot = [IO.Path]::GetFullPath($kw).ToLowerInvariant()
    $mx = [Threading.Mutex]::new($false, 'Global\brain-kitchen-' + (([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($kroot)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12))
    $sw = [Diagnostics.Stopwatch]::StartNew(); $got = $false; try { $got = $mx.WaitOne(1000) } catch [Threading.AbandonedMutexException] { $got = $true }; $lockWait = $sw.ElapsedMilliseconds
    if ($got) { $mx.ReleaseMutex() }; $mx.Dispose()
    $ap = & $k approve -Id J1 | Out-String
    $stillRunning = (Test-Path $mark) -and -not $doc.HasExited
    $doc.WaitForExit(30000) | Out-Null
    Check "Doctor3sWatcher_ApproveSucceedsUnder1s: the state lock was free within $lockWait ms while a 3 s watcher ran, and approve went through before the doctor ended" (
        $got -and $lockWait -lt 1000 -and $ap -match 'approved A1 for J1' -and $stillRunning)
    $dev = @(Get-Content (Join-Path $kw 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'doctor' })[-1]
    Check "the doctor's lock time leaves out the watcher (lockMs $($dev.lockMs) of $($dev.ms) ms)" ($dev -and [int]$dev.ms -ge 3000 -and [int]$dev.lockMs -lt 2000)
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Retention tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
