# Tests for the job store's live set (kitchen/jobs-lib.ps1 and its use in kitchen/kitchen.ps1; TARGET W3 in gemini-brain
# projects/tide/arch-10-22): a tick opens only the orders still in play, jobs-index.json is a cache that is rebuilt (and logged) when it
# is missing or damaged and re-read where a file changed, Next-Id never gives an id twice, and no other script lists the jobs folder.
# (maxLive/maxQueued and Add150 are in Test-KitchenSupervisor.ps1.) Synthetic jobs in private kitchens under TEMP; self-cleaning; no AI.
$ErrorActionPreference = 'Stop'
$k = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1')).Path
$w = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\demo-worker.ps1')).Path
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-jobsindex-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_UNDER_TEST', 'KITCHEN_TRACE_READS', 'KITCHEN_NO_RAMGUARD', 'KITCHEN_AGY_EXE', 'BRAIN_AGENT_DEPTH', 'KITCHEN_JOB', 'KITCHEN_NO_BACKUP') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
$env:KITCHEN_UNDER_TEST = '1'; $env:KITCHEN_NO_RAMGUARD = '1'; $env:KITCHEN_AGY_EXE = 'off'; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null; $env:KITCHEN_NO_BACKUP = '1'
$wj = $w | ConvertTo-Json   # (once: the 2,845 synthetic files share it)
function Put-Job([string]$kr, [int]$n, [string]$status, [int]$cursor = 0) {
    $s = '{"id":"J' + $n + '","name":"j' + $n + '","status":"' + $status + '","cursor":' + $cursor + ',"attempt":0,"created":"2026-10-20T00:00:00Z","history":[],"steps":[{"script":' + $wj + ',"args":{"Behavior":"ok","Seconds":1},"timeoutSec":60,"maxMB":400,"maxLogMB":5,"hungSec":-1,"retries":0}]}'
    [IO.File]::WriteAllText("$kr\jobs\J$n.json", $s)
}
function Events([string]$kr) { @(Get-Content (Join-Path $kr 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
try {
    # ---- Tick_2840DoneJobs5Pending_Reads5Files: a tick never opens a finished order's file ---------------------------------------
    $big = Join-Path $root 'big'; New-Item -ItemType Directory -Force -Path (Join-Path $big 'jobs') | Out-Null
    foreach ($n in 1..2840) { Put-Job $big $n 'done' 1 }
    foreach ($n in 2841..2845) { Put-Job $big $n 'pending' }
    $now = [DateTime]::UtcNow.ToString('o')
    @{ lastDoctor = $now; lastLedger = $now } | ConvertTo-Json | Set-Content (Join-Path $big 'supervisor.json')   # no hourly chores in this tick
    $env:BRAIN_KITCHEN = $big
    # the index as Save-Job leaves it (written here: having kitchen.ps1 parse 2,845 fresh files first costs ~30 s of virus scanning)
    $sb = [Text.StringBuilder]::new('{"v":1,"jobs":{')
    foreach ($n in 1..2845) { $f = [IO.FileInfo]::new("$big\jobs\J$n.json"); [void]$sb.Append($(if ($n -gt 1) { ',' })).Append("`"J$n`":{`"s`":`"$(if ($n -le 2840) { 'done' } else { 'pending' })`",`"t`":$($f.LastWriteTimeUtc.Ticks),`"n`":$($f.Length),`"p`":`"`",`"c`":0}") }
    [IO.File]::WriteAllText((Join-Path $big 'jobs-index.json'), $sb.Append('}}').ToString())
    $trace = Join-Path $root 'reads.txt'; $env:KITCHEN_TRACE_READS = $trace
    $sw = [Diagnostics.Stopwatch]::StartNew(); & pwsh -NoProfile -File $k tick -Quiet | Out-Null; $sw.Stop()
    $env:KITCHEN_TRACE_READS = $null
    $ids = @(Get-Content $trace -ErrorAction SilentlyContinue | Where-Object { $_ -like 'tick *' } | ForEach-Object { ($_ -split ' ')[1] } | Sort-Object -Unique)
    Check "Tick_2840DoneJobs5Pending_Reads5Files: the tick opened $($ids.Count) job file(s) ($($ids -join ', ')) in $($sw.ElapsedMilliseconds) ms" ($ids.Count -eq 5 -and -not @($ids | Where-Object { [int]$_.Substring(1) -le 2840 }).Count)
    $started = @(2841..2845 | Where-Object { (Get-Content (Join-Path $big "jobs\J$_.json") -Raw | ConvertFrom-Json).status -ne 'pending' }).Count
    Check 'the tick still started the pending orders (at most maxConcurrent 4)' ($started -ge 1 -and $started -le 4)
    & pwsh -NoProfile -File $k kill -All | Out-Null

    # ---- the index is a cache: damaged -> rebuilt, a changed file -> read again, a gone file -> dropped ------------------------------
    $sm = Join-Path $root 'small'; New-Item -ItemType Directory -Force -Path (Join-Path $sm 'jobs') | Out-Null
    Put-Job $sm 1 'done' 1; Put-Job $sm 2 'pending'; Put-Job $sm 3 'quarantined'
    $env:BRAIN_KITCHEN = $sm
    $st = (& pwsh -NoProfile -File $k status -Json | Out-String) | ConvertFrom-Json   # the first read builds jobs-index.json (none yet)
    Check 'a missing index is built from the files and logged (jobs.index.rebuilt, reason missing)' (@($st.jobs).Count -eq 3 -and (Test-Path (Join-Path $sm 'jobs-index.json')) -and
        @(Events $sm | Where-Object { $_.type -eq 'jobs.index.rebuilt' -and $_.reason -eq 'missing' }).Count -eq 1)
    Set-Content (Join-Path $sm 'jobs-index.json') '{"v":1,"jobs":{"J1":{"s":"done"' -NoNewline
    $st = (& pwsh -NoProfile -File $k status -Json | Out-String) | ConvertFrom-Json
    $ix = Get-Content (Join-Path $sm 'jobs-index.json') -Raw | ConvertFrom-Json -AsHashtable
    Check 'BadIndex_Rebuilt_EventLogged: a torn jobs-index.json is rebuilt from the files and logged (reason damaged)' (
        @($st.jobs).Count -eq 3 -and @(Events $sm | Where-Object { $_.type -eq 'jobs.index.rebuilt' -and $_.reason -eq 'damaged' }).Count -eq 1 -and $ix.jobs.Count -eq 3 -and $ix.jobs.J2.s -eq 'pending')
    Set-Content (Join-Path $sm 'jobs-index.json') '{"v":1,"jobs":{"J1":{"s":"done","t":"x","n":1}}}'
    & pwsh -NoProfile -File $k status -Json | Out-Null
    Check 'an index entry of the wrong shape counts as damaged too (rebuilt, logged)' (@(Events $sm | Where-Object { $_.type -eq 'jobs.index.rebuilt' -and $_.reason -eq 'damaged' }).Count -eq 2)
    # a writer that bypasses Save-Job (cook.ps1's night wait, a hand edit): the size and time no longer match, so the file is read again
    $j1 = Get-Content (Join-Path $sm 'jobs\J1.json') -Raw | ConvertFrom-Json -AsHashtable; $j1.status = 'pending'; $j1.cursor = 0
    Start-Sleep -Milliseconds 20; [IO.File]::WriteAllText((Join-Path $sm 'jobs\J1.json'), ($j1 | ConvertTo-Json -Depth 6))
    . (Join-Path $repo 'kitchen\jobs-lib.ps1')
    $live = @(Get-KitchenJobs $sm -Live | ForEach-Object { $_.id })
    Check 'a job file changed behind the index is read again (done -> pending joins the live set)' (($live -join ',') -eq 'J1,J2,J3')
    Remove-Item (Join-Path $sm 'jobs\J3.json')
    $r = Update-KitchenJobs $sm 'index'
    Check 'an index entry whose file is gone is dropped' (-not $r.index.ContainsKey('J3') -and $r.index.Count -eq 2 -and $r.read -eq 0)
    Check 'set-aside orders stay in the live set; only done and closed leave it' ((Test-JobLive @{ s = 'quarantined'; c = 0 }) -and (Test-JobLive @{ s = 'killed'; c = 0 }) -and -not (Test-JobLive @{ s = 'done'; c = 0 }) -and -not (Test-JobLive @{ s = 'closed'; c = 0 }) -and (Test-JobLive @{ s = 'done'; c = 1 }))

    # ---- Next-Id: jobs\next-id.txt, never trusted blindly -------------------------------------------------------------------------
    $ni = Join-Path $root 'nextid'; New-Item -ItemType Directory -Force -Path (Join-Path $ni 'jobs\archive\2026-09') | Out-Null
    Put-Job $ni 1 'pending'; [IO.File]::WriteAllText((Join-Path $ni 'jobs\archive\2026-09\J7.json'), '{"id":"J7"}')
    '{"id":"J9","status":"done","month":"2026-09"}' | Set-Content (Join-Path $ni 'jobs\archive\index.jsonl')   # (its file is missing: the line alone still holds J9)
    $env:BRAIN_KITCHEN = $ni
    $o = & pwsh -NoProfile -File $k add -Name n1 -Script $w | Out-String
    Check 'no counter yet: the next id is past every id in jobs\, the archive and its index (J10)' ($o -match 'added J10' -and (Get-Content (Join-Path $ni 'jobs\next-id.txt') -Raw).Trim() -eq '11')
    Move-Item (Join-Path $ni 'jobs\J10.json') (Join-Path $ni 'jobs\archive\2026-09\J10.json')   # J10 archived too
    Set-Content (Join-Path $ni 'jobs\next-id.txt') '7'
    $o = & pwsh -NoProfile -File $k add -Name n2 -Script $w | Out-String
    Check 'a stale counter never reuses an archived id (7 is archived, 8 is free)' ($o -match 'added J8')
    Set-Content (Join-Path $ni 'jobs\next-id.txt') 'garbage'
    $o = & pwsh -NoProfile -File $k add -Name n3 -Script $w | Out-String
    Check 'an unreadable counter is rebuilt from the files (J11)' ($o -match 'added J11')

    # ---- NoScriptListsJobsDir_ExceptKitchenPs1: only the store lists jobs\ (a missed reader would silently see fewer orders) -------
    $listing = '(?i)(Get-ChildItem|EnumerateFiles|GetFiles|readdir(Sync)?\(|fs\.watch\()[^\r\n]*(''jobs''|"jobs"|\\jobs[''"\\)]|\$jobsDir\b|/jobs[''"])|(''jobs''|"jobs"|\$jobsDir)[^\r\n]*(Get-ChildItem|EnumerateFiles|GetFiles|readdir)'
    Check 'the lint catches a jobs\ listing (positive control)' ("foreach (`$f in Get-ChildItem -LiteralPath (Join-Path `$root 'jobs') -Filter 'J*.json') { }" -match $listing -and "fs.readdirSync(path.join(root, 'jobs'))" -match $listing)
    # allowed, each for a reason: the store itself; copies and counts that never read a job's state; the bench (it measures the store);
    # Chef (it lists jobs\ top level, which is the live set, through fs.watch; W4 owns its change-driven reads)
    $allow = @{ 'kitchen/kitchen.ps1' = 'the store'; 'kitchen/jobs-lib.ps1' = 'the store'; 'scripts/backup-state.ps1' = 'copies files off the C: drive'
        'scripts/restore-drill.ps1' = 'counts files'; 'scripts/bench/bench.ps1' = 'measures the store'; 'scripts/bench/chef.mjs' = 'measures the store'; 'pass-app/server.mjs' = 'jobs\ top level is the live set' }
    $hits = @(foreach ($d in 'kitchen', 'scripts', 'pass-app') {
            foreach ($f in Get-ChildItem (Join-Path $repo $d) -Recurse -File -Include '*.ps1', '*.mjs', '*.js' | Where-Object { $_.FullName -notmatch '\\node_modules\\|\\tests?\\|\\test-[^\\]*$|\\fixtures\\' }) {
                $rel = $f.FullName.Substring($repo.Length + 1).Replace('\', '/')
                if ($allow.ContainsKey($rel)) { continue }
                $n = 0; foreach ($l in [IO.File]::ReadLines($f.FullName)) { $n++; if ($l -match $listing) { "${rel}:$n" } }
            }
        })
    Check "NoScriptListsJobsDir_ExceptKitchenPs1: no other script lists jobs\ ($($hits -join ', '))" (-not $hits.Count)
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Jobs index tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
