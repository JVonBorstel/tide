# Tests for the merge train per repo (kitchen/train.ps1, TARGET W2, J253): merges into two repos never wait on each other, the same repo
# waits, a dead or stale holder is passed over, an old shared merge-train.json is honoured until let go, and the supervisor checks the
# train before it starts a merge worker (no worker, no slot, one step.wait per holder). Self-cleaning temp kitchen and repos.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path; $k = Join-Path $kd 'kitchen.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-train-' + [guid]::NewGuid().ToString('N'))
$kr = Join-Path $root 'kitchen'; $ra = Join-Path $root 'repo-a'; $rb = Join-Path $root 'repo-b'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
. (Join-Path $kd 'train.ps1')
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_JOB', 'KITCHEN_RUN', 'KITCHEN_AGY_EXE', 'BRAIN_NTFY_TOPIC', 'BRAIN_AGENT_DEPTH') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
function Put-TestJob([string]$id, [string]$status, [string]$repo = '') {
    $steps = if ($repo) { @(@{ script = (Join-Path $kd 'stations\merge.ps1'); args = @{ Repo = $repo } }) } else { @() }
    @{ id = $id; status = $status; cursor = 0; steps = $steps } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $kr "jobs\$id.json")
}
function Claim([string]$path, [string]$id, [double]$agoMin = 0) { @{ job = $id; at = [DateTime]::UtcNow.AddMinutes(-$agoMin).ToString('o') } | ConvertTo-Json -Compress | Set-Content $path }
function G([string]$repo) { & git -C $repo -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
# a repo with main and a kitchen/<job> branch holding one edit
function Repo([string]$repo, [string]$job) {
    New-Item -ItemType Directory -Force -Path $repo | Out-Null; & git -C $repo init -q -b main 2>&1 | Out-Null
    Set-Content "$repo\a.txt" 'base'; G $repo add -A; G $repo commit -q -m base
    G $repo checkout -q -b "kitchen/$job"; Set-Content "$repo\a.txt" "edited by $job"; G $repo commit -q -am "edit $job"; G $repo checkout -q main
}
function Merge([string]$repo, [string]$job) {
    $env:KITCHEN_JOB = $job; $env:KITCHEN_RUN = Join-Path $root "run-$job"
    try { $o = & pwsh -NoProfile -File (Join-Path $kd 'stations\merge.ps1') -Repo $repo -Approved 2>&1 | Out-String; @{ code = $LASTEXITCODE; out = $o } }
    finally { $env:KITCHEN_JOB = $null; $env:KITCHEN_RUN = $null }
}
function Events { @(Get-Content (Join-Path $kr 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
try {
    $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_AGY_EXE = 'off'; $env:BRAIN_NTFY_TOPIC = $null; $env:BRAIN_AGENT_DEPTH = $null
    New-Item -ItemType Directory -Force -Path (Join-Path $kr 'jobs') | Out-Null
    # ---- the rules (train.ps1)
    Check 'one train file per repo, named by the repo path (any case, trailing slash)' ((Get-TrainPath $kr $ra) -ne (Get-TrainPath $kr $rb) -and (Get-TrainPath $kr $ra) -eq (Get-TrainPath $kr ($ra.ToUpperInvariant() + '\')) -and (Get-TrainPath $kr $ra) -match 'merge-train-[0-9a-f]{12}\.json$')
    Put-TestJob 'J1' 'running' $ra; Set-TrainClaim $kr $ra 'J1'
    Check 'the same repo waits: J2 into repo A sees J1' ((Get-TrainHolder $kr $ra 'J2') -eq 'J1')
    Check 'two repos merge at once: repo B is free while A is held' ($null -eq (Get-TrainHolder $kr $rb 'J2'))
    Check 'the holder itself is not held by its own claim' ($null -eq (Get-TrainHolder $kr $ra 'J1'))
    Put-TestJob 'J1' 'needs-human' $ra
    Check 'a verify cut short (needs-human) still holds the train' ((Get-TrainHolder $kr $ra 'J2') -eq 'J1')
    Put-TestJob 'J1' 'done' $ra
    Check 'a dead holder (finished order) is passed over' ($null -eq (Get-TrainHolder $kr $ra 'J2'))
    Put-TestJob 'J1' 'running' $ra; Claim (Get-TrainPath $kr $ra) 'J1' 100
    Check 'a claim over 90 minutes old is passed over' ($null -eq (Get-TrainHolder $kr $ra 'J2'))
    [IO.File]::WriteAllText((Get-TrainPath $kr $ra), '{"job":"J1","at":"2026-')
    Check 'a torn train file holds (never read as no holder)' ((Get-TrainHolder $kr $ra 'J2') -match 'cannot be read')
    Set-TrainClaim $kr $ra 'J1'; Clear-TrainClaim $kr $ra 'J2'
    Check 'only the holder hands the train back' (Test-Path (Get-TrainPath $kr $ra))
    Clear-TrainClaim $kr $ra 'J1'
    Check 'the holder hands it back' (-not (Test-Path (Get-TrainPath $kr $ra)))
    # an old shared merge-train.json (before 10-23) is honoured once: it holds its holder's repo until let go, then is deleted
    $old = Join-Path $kr 'merge-train.json'; Put-TestJob 'J3' 'running' $ra; Claim $old 'J3'
    Check 'old merge-train.json is honoured: J3 (repo A) holds repo A' ((Get-TrainHolder $kr $ra 'J2') -eq 'J3')
    Check 'old merge-train.json does not hold another repo' ($null -eq (Get-TrainHolder $kr $rb 'J2') -and (Test-Path $old))
    Put-TestJob 'J3' 'done' $ra
    Check 'old merge-train.json, let go: passed over and deleted for good' ($null -eq (Get-TrainHolder $kr $ra 'J2') -and -not (Test-Path $old))

    # ---- merge.ps1 with two real repos: TwoRepos_MergeNeverWaitsOnOtherRepo
    Repo $ra 'J5'; Repo $rb 'J6'
    Put-TestJob 'J4' 'running' $ra; Set-TrainClaim $kr $ra 'J4'
    $mb = Merge $rb 'J6'
    Check 'TwoRepos_MergeNeverWaitsOnOtherRepo: repo B merges while repo A is being verified' ($mb.code -eq 0 -and $mb.out -match 'MERGED' -and (Get-Content "$rb\a.txt" -Raw) -match 'edited by J6')
    Check 'repo B train now names its own order; repo A train untouched' ((Get-Content (Get-TrainPath $kr $rb) -Raw | ConvertFrom-Json).job -eq 'J6' -and (Get-Content (Get-TrainPath $kr $ra) -Raw | ConvertFrom-Json).job -eq 'J4')
    $ma = Merge $ra 'J5'
    Check 'the same repo waits: exit 11, names J4, nothing merged' ($ma.code -eq 11 -and $ma.out -match 'waiting for the merge train \(J4' -and (Get-Content "$ra\a.txt" -Raw) -match '^base')

    # ---- the supervisor: Train_CheckedBeforeSpawn (a busy train starts no worker)
    Remove-Item (Join-Path $kr 'jobs\*') -Force
    $fake = Join-Path $root 'fake'; New-Item -ItemType Directory -Force -Path $fake | Out-Null   # (a step named merge.ps1 is the merge station)
    Set-Content (Join-Path $fake 'merge.ps1') "param([string]`$Repo) Set-Content -LiteralPath '$root\merge-ran.txt' -Value `$env:KITCHEN_JOB; exit 0"
    @{ choresTaskAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $kr 'supervisor.json')   # (no chores in these ticks)
    $spec = Join-Path $root 'spec.json'; @{ name = 'merge me'; steps = @(@{ script = (Join-Path $fake 'merge.ps1'); args = @{ Repo = $ra }; retries = 0 }) } | ConvertTo-Json -Depth 5 | Set-Content $spec
    $add = & $k add -SpecPath $spec | Out-String; $id = if ($add -match 'added (J\d+)') { $Matches[1] } else { 'none' }
    & pwsh -NoProfile -File $k tick -Quiet | Out-Null   # asks Jordan (a merge step is always a gate)
    & $k approve -Id $id | Out-Null
    # the holder: an order whose verify waits for Jordan (needs-human, its ask already in the queue): live, and the supervisor leaves it be
    @{ id = 'J9'; status = 'needs-human'; cursor = 0; steps = @(@{ script = (Join-Path $kd 'stations\verify.ps1'); args = @{ Repo = $ra } }); approval = @{ id = 'A99'; cursor = 0; granted = $false; text = 'x' } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $kr 'jobs\J9.json')
    Set-TrainClaim $kr $ra 'J9'
    $before = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($kr) }).Count
    & pwsh -NoProfile -File $k tick -Quiet | Out-Null; & pwsh -NoProfile -File $k tick -Quiet | Out-Null
    $after = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($kr) }).Count
    $jo = Get-Content (Join-Path $kr "jobs\$id.json") -Raw | ConvertFrom-Json
    Check 'Train_CheckedBeforeSpawn: approved, but the train is busy: no worker (no run spec, process count unchanged), still pending' ($jo.status -eq 'pending' -and -not $jo.run -and -not (Test-Path (Join-Path $kr "run\$id-s0-a0.json")) -and $after -eq $before -and -not (Test-Path "$root\merge-ran.txt"))
    $waits = @(Events | Where-Object { $_.type -eq 'step.wait' -and $_.job -eq $id -and $_.kind -eq 'train' })
    Check 'one step.wait kind train for the holder over two ticks, naming it' ($waits.Count -eq 1 -and $waits[0].detail -match 'J9')
    Clear-TrainClaim $kr $ra 'J9'
    & pwsh -NoProfile -File $k tick -Quiet | Out-Null
    $jo = Get-Content (Join-Path $kr "jobs\$id.json") -Raw | ConvertFrom-Json
    Check 'the train free again: the merge worker starts' ($jo.status -in 'running', 'done' -and (Test-Path (Join-Path $kr "run\$id-s0-a0.json")) -and -not $jo.trainWait)
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } | ForEach-Object { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
Write-Host "MergeTrain tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
