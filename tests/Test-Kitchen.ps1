# Tests for scripts/run-bounded.ps1 and scripts/kitchen-check.ps1. Self-cleaning.
$ErrorActionPreference = 'Stop'
$rb = Join-Path $PSScriptRoot '..\scripts\run-bounded.ps1'
$kc = Join-Path $PSScriptRoot '..\scripts\kitchen-check.ps1'
$k = Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kt-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }

# 1. exit code passes through
Set-Content "$root\ok.ps1" 'exit 7'
pwsh -NoProfile -File $rb -TimeoutSeconds 30 -Script "$root\ok.ps1" | Out-Null
Check 'exit code passthrough' ($LASTEXITCODE -eq 7)

# Polls instead of fixed sleeps: under load (4 job suites + verify at once) a fixed 1-6 s wait was the flake.
function Wait-Until([scriptblock]$cond, [int]$sec = 30) { $e = (Get-Date).AddSeconds($sec); while ((Get-Date) -lt $e) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 250 }; [bool](& $cond) }
function Alive($id) { $id -gt 0 -and $null -ne (Get-Process -Id $id -ErrorAction SilentlyContinue) }

# 2. timeout kills process tree and returns 124 (the timeout is long enough for hang.ps1 to record its child even under load)
Set-Content "$root\hang.ps1" ('$c = Start-Process pwsh -ArgumentList "-NoProfile","-Command","Start-Sleep 120" -PassThru -WindowStyle Hidden; Set-Content "' + $root + '\child.txt" $c.Id; Start-Sleep 120')
$sw = [Diagnostics.Stopwatch]::StartNew()
pwsh -NoProfile -File $rb -TimeoutSeconds 15 -Script "$root\hang.ps1" | Out-Null
Check 'timeout exit 124' ($LASTEXITCODE -eq 124)
Check 'timeout fast' ($sw.Elapsed.TotalSeconds -lt 60)
$cid = [int](Get-Content "$root\child.txt" -ErrorAction SilentlyContinue)
Check 'child recorded before the timeout' ($cid -gt 0)
Check 'child killed' ($cid -gt 0 -and (Wait-Until { -not (Alive $cid) } 15))

# 2b. an orphaned grandchild (its parent already exited, so a parent-PID walk cannot find it) dies on timeout too
Set-Content "$root\orphan.ps1" ('$m = Start-Process pwsh -ArgumentList "-NoProfile","-Command","`$g = Start-Process pwsh -ArgumentList ''-NoProfile'',''-Command'',''Start-Sleep 120'' -PassThru -WindowStyle Hidden; Set-Content ''' + $root + '\gc.txt'' `$g.Id" -PassThru -WindowStyle Hidden; $m.WaitForExit(); Start-Sleep 120')
pwsh -NoProfile -File $rb -TimeoutSeconds 20 -Script "$root\orphan.ps1" | Out-Null
$gid = [int](Get-Content "$root\gc.txt" -ErrorAction SilentlyContinue)
Check 'orphan: grandchild recorded' ($gid -gt 0)
Check 'orphan: grandchild killed on timeout' ($gid -gt 0 -and (Wait-Until { -not (Alive $gid) } 15))

# 2c. a suite that exits 0 but leaves a helper running: the helper dies with the job (it would hold the worktree)
Set-Content "$root\leak.ps1" ('$c = Start-Process pwsh -ArgumentList "-NoProfile","-Command","Start-Sleep 120" -PassThru -WindowStyle Hidden; Set-Content "' + $root + '\leak.txt" $c.Id; exit 0')
pwsh -NoProfile -File $rb -TimeoutSeconds 60 -Script "$root\leak.ps1" | Out-Null
Check 'leak: suite exit code kept' ($LASTEXITCODE -eq 0)
$lid = [int](Get-Content "$root\leak.txt" -ErrorAction SilentlyContinue)
Check 'leak: leftover helper killed on normal exit' ($lid -gt 0 -and (Wait-Until { -not (Alive $lid) } 15))

# 3. memory cap kills and returns 125
# (grows in 50 MB steps like a real leak; one giant block past the 1.5x hard wall just fails with out-of-memory instead)
Set-Content "$root\mem.ps1" '$l = [Collections.Generic.List[byte[]]]::new(); foreach ($k in 1..12) { $a = New-Object byte[] 50MB; for ($i=0; $i -lt $a.Length; $i += 4096) { $a[$i] = 1 }; $l.Add($a) }; Start-Sleep 60'
pwsh -NoProfile -File $rb -TimeoutSeconds 60 -MaxMB 300 -Script "$root\mem.ps1" | Out-Null
Check 'memory cap exit 125' ($LASTEXITCODE -eq 125)

# 3b. the cap covers the whole tree: a grandchild allocating while the top pwsh stays small still trips it
Set-Content "$root\memkid.ps1" '$c = Start-Process pwsh -ArgumentList "-NoProfile","-Command","`$l = [Collections.Generic.List[byte[]]]::new(); foreach (`$k in 1..12) { `$a = New-Object byte[] 50MB; for (`$i=0; `$i -lt `$a.Length; `$i += 4096) { `$a[`$i] = 1 }; `$l.Add(`$a) }; Start-Sleep 60" -PassThru -NoNewWindow; Start-Sleep 60'
pwsh -NoProfile -File $rb -TimeoutSeconds 60 -MaxMB 400 -Script "$root\memkid.ps1" | Out-Null
Check 'memory cap counts child processes (exit 125)' ($LASTEXITCODE -eq 125)
# 4. kitchen-check: healthy thresholds -> OK-ish output and exit 0; absurd threshold -> WARN (a scratch kitchen and guard state: the live
# kitchen's tick age and the real brain-guard state are never read or written by the suite)
$kcSaved = @{ k = $env:BRAIN_KITCHEN; g = $env:BRAIN_GUARD_STATE }
$env:BRAIN_KITCHEN = Join-Path $root 'kc-kitchen'; $env:BRAIN_GUARD_STATE = Join-Path $root 'kc-guard'; New-Item -ItemType Directory -Force -Path $env:BRAIN_KITCHEN | Out-Null
$ok = pwsh -NoProfile -File $kc -MinFreeRamGB 0 -MinFreeCGB 0 -MaxProcMB 999999 -MaxTempGB 999999 -MaxFileMB 999999 -MaxCpuSec 999999 | Out-String
Check 'kitchen ok exit' ($LASTEXITCODE -eq 0); Check 'kitchen has header' ($ok -match 'KITCHEN')
$w = pwsh -NoProfile -File $kc -MinFreeRamGB 9999 | Out-String
Check 'kitchen warns' ($w -match 'WARN' -and $LASTEXITCODE -eq 1)
$easy = @('-MinFreeRamGB', '0', '-MinFreeCGB', '0', '-MaxProcMB', '999999', '-MaxFileMB', '999999', '-MaxCpuSec', '999999')
# 4b. a Visual Studio installer cache in TEMP is reported once (INFO), never as a TEMP warning; a real big folder is named in the warning
$ft = Join-Path $root 'kc-temp'; $vs = Join-Path $ft 'abcdefgh'
foreach ($p in 'Microsoft.VC.A.0123456789ABCDEF0123', 'Microsoft.VC.B.0123456789ABCDEF0124', 'Microsoft.VC.C.0123456789ABCDEF0125') { New-Item -ItemType Directory -Force -Path (Join-Path $vs $p) | Out-Null; Set-Content (Join-Path $vs "$p\x.bin") ('x' * 1000) }
$v1 = pwsh -NoProfile -File $kc @easy -MaxTempGB 999 -TempDir $ft | Out-String
Check 'vs cache reported once as INFO' ($v1 -match 'INFO Visual Studio installer caches.*abcdefgh' -and $v1 -notmatch 'WARN TEMP' -and $LASTEXITCODE -eq 0)
$v2 = pwsh -NoProfile -File $kc @easy -MaxTempGB 999 -TempDir $ft | Out-String
Check 'vs cache not repeated the next session' ($v2 -notmatch 'INFO Visual Studio' -and $LASTEXITCODE -eq 0)
New-Item -ItemType Directory -Force -Path (Join-Path $ft 'bigthing') | Out-Null; Set-Content (Join-Path $ft 'bigthing\y.bin') ('y' * 1000)
$v3 = pwsh -NoProfile -File $kc @easy -MaxTempGB 0 -TempDir $ft | Out-String
Check 'TEMP warning names the biggest folder, not the VS cache' ($v3 -match 'WARN TEMP large; biggest: bigthing' -and $v3 -notmatch 'biggest:[^\r\n]*abcdefgh')
# 4c. a supervisor that stopped ticking is a WARN (nothing else notices); Jordan's PAUSED marker turns it into a plain status line
@{ lastTick = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $env:BRAIN_KITCHEN 'supervisor.json')
$s1 = pwsh -NoProfile -File $kc @easy -MaxTempGB 999 -TempDir $ft | Out-String
Check 'stalled supervisor warns' ($s1 -match 'WARN kitchen supervisor not ticking \(last tick 3\d min ago\)' -and $LASTEXITCODE -eq 1)
Set-Content (Join-Path $env:BRAIN_KITCHEN 'PAUSED') 'test'
$s2 = pwsh -NoProfile -File $kc @easy -MaxTempGB 999 -TempDir $ft | Out-String
Check 'paused supervisor is shown, not warned' ($s2 -match 'PAUSED the kitchen supervisor is paused' -and $s2 -notmatch 'not ticking' -and $LASTEXITCODE -eq 0)
$env:BRAIN_KITCHEN = $kcSaved.k; $env:BRAIN_GUARD_STATE = $kcSaved.g

# 5-6 run kitchen-check against a scratch TEMP (TEMP and TMP point at it for the check's own default), and their heavy and busy processes
# live until this suite stops them (or this suite's pwsh exits), never on a clock of their own. They used to end themselves after 90 s
# while kitchen-check scanned the real TEMP: at 170,000 files one scan took 57 s, the first scan came too early to see the CPU, the
# second ended at t+116 s, and 'busy loop not killed' failed on a loop that had ended by itself (exit 0 at start+90 s; nothing killed it).
$ktTemp = Join-Path $root 'kc-scratch-temp'; New-Item -ItemType Directory -Force -Path $ktTemp | Out-Null
$tempSaved = @{ TEMP = $env:TEMP; TMP = $env:TMP }
$untilSuiteEnds = "`$suite = Get-Process -Id $PID; "   # each helper below runs while this suite's pwsh is running
try {
    $env:TEMP = $ktTemp; $env:TMP = $ktTemp

    # 5. kitchen-check flags a heavy process but never kills it
    $p = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', ($untilSuiteEnds + '$a = New-Object byte[] 300MB; for ($i=0; $i -lt $a.Length; $i += 4096) { $a[$i] = 1 }; while (-not $suite.HasExited) { Start-Sleep -Milliseconds 500 }') -PassThru -WindowStyle Hidden
    $h = ''; [void](Wait-Until { $script:h = pwsh -NoProfile -File $kc -MaxProcMB 200 | Out-String; $script:h -match "pid $($p.Id)\b" } 45)
    Check 'flags heavy pid' ($h -match "pid $($p.Id)\b")
    Check 'did not kill' ($null -ne (Get-Process -Id $p.Id -ErrorAction SilentlyContinue))
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue

    # 6. flags a busy-loop process (high CPU seconds) and a huge TEMP file; kills nothing
    $b = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', ($untilSuiteEnds + 'while (-not $suite.HasExited) { $x = 1 + 1 }') -PassThru -WindowStyle Hidden
    $big = Join-Path $ktTemp ('kt-big-' + [guid]::NewGuid().ToString('N') + '.bin')
    $fs = [IO.File]::Create($big); $fs.SetLength(60MB); $fs.Dispose()
    $h2 = ''; [void](Wait-Until { $script:h2 = pwsh -NoProfile -File $kc -MaxCpuSec 3 -MaxFileMB 50 | Out-String; $script:h2 -match "busy.*pid $($b.Id)\b" } 45)
    Check 'flags busy loop' ($h2 -match "busy.*pid $($b.Id)\b")
    Check 'flags huge temp file' ($h2 -match [regex]::Escape((Split-Path $big -Leaf)))
    Check 'busy loop not killed' ($null -ne (Get-Process -Id $b.Id -ErrorAction SilentlyContinue))
    Stop-Process -Id $b.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $big -Force
} finally {
    $env:TEMP = $tempSaved.TEMP; $env:TMP = $tempSaved.TMP
}

# 7. Spend-Today retains cumulative spend across rotated events-*.jsonl files
$origKitchen = $env:BRAIN_KITCHEN
$rot = Join-Path $root 'k-rot'
New-Item -ItemType Directory -Force -Path $rot | Out-Null
try {
    $env:BRAIN_KITCHEN = $rot
    $todayUtc = [DateTime]::UtcNow.ToString('o')
    $ev = Join-Path $rot 'events.jsonl'
    Set-Content -LiteralPath $ev -Value (@{ ts = $todayUtc; type = 'cost'; job = 'J1'; usd = 8.50 } | ConvertTo-Json -Compress) -Encoding utf8
    $rotFile = Join-Path $rot ("events-{0:yyyyMMddHHmmss}.jsonl" -f (Get-Date))
    Move-Item -LiteralPath $ev -Destination $rotFile -Force
    (Get-Item -LiteralPath $rotFile).LastWriteTime = (Get-Date)
    Set-Content -LiteralPath $ev -Value (@{ ts = $todayUtc; type = 'cost'; job = 'J2'; usd = 4.25 } | ConvertTo-Json -Compress) -Encoding utf8
    $oldDate = (Get-Date).AddDays(-5)
    $oldUtc = $oldDate.ToUniversalTime().ToString('o')
    $oldRot = Join-Path $rot 'events-20260101000000.jsonl'
    Set-Content -LiteralPath $oldRot -Value (@{ ts = $oldUtc; type = 'cost'; job = 'J0'; usd = 99.00 } | ConvertTo-Json -Compress) -Encoding utf8
    (Get-Item -LiteralPath $oldRot).LastWriteTime = $oldDate

    $st = & $k status -DailyBudgetUsd 20 | Out-String
    Check 'Spend-Today retains cumulative spend across rotated events' ($st -match 'spent today \$12\.75 of \$20\.00')
    Check 'spend did not reset upon log rotation' ($st -notmatch 'spent today \$4\.25')
    Check 'older rotated logs from prior days are ignored' ($st -notmatch 'spent today \$111\.75')
} finally {
    $env:BRAIN_KITCHEN = $origKitchen
}

# 8. commit station diff budget (temp repo + worktree; env restored afterwards)
$commitPs = Join-Path $PSScriptRoot '..\kitchen\stations\commit.ps1'
$oldJob = $env:KITCHEN_JOB; $oldKitchen = $env:BRAIN_KITCHEN
function New-BudgetCase($name) {
    $kroot = Join-Path $root "bk-$name"
    $wtDir = Join-Path $kroot 'worktrees\J1'
    New-Item -ItemType Directory -Path $wtDir | Out-Null
    git -C $wtDir init -q 2>&1 | Out-Null
    Set-Content (Join-Path $wtDir 'seed.txt') 'seed'
    git -C $wtDir add -A 2>&1 | Out-Null
    git -C $wtDir -c user.name=t -c user.email=t@localhost commit -q -m seed 2>&1 | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $wtDir '.kitchen') | Out-Null
    $baseSha = (git -C $wtDir rev-parse HEAD).Trim()
    Set-Content (Join-Path $wtDir '.kitchen\BASE') $baseSha
    [pscustomobject]@{ Kroot = $kroot; Wt = $wtDir; Base = $baseSha }
}
function Invoke-BudgetCommit($case, [string[]]$extra = @()) {
    $env:KITCHEN_JOB = 'J1'; $env:BRAIN_KITCHEN = $case.Kroot
    $o = & pwsh -NoProfile -File $commitPs @extra 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}
function Add-Lines($case, $rel, $n) {
    $full = Join-Path $case.Wt $rel
    $dir = Split-Path $full -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Set-Content -LiteralPath $full -Value (1..$n | ForEach-Object { "line $_" })
}
function Head-Of($case) { (git -C $case.Wt rev-parse HEAD).Trim() }

$c = New-BudgetCase 'ok'; Add-Lines $c 'a.txt' 5; Add-Lines $c 'b.txt' 5
$r = Invoke-BudgetCommit $c
Check 'budget: within budget exits 0' ($r.Code -eq 0)
Check 'budget: within budget committed' ($r.Out -match 'change committed')
Check 'budget: DIFF.patch written' (Test-Path (Join-Path $c.Wt '.kitchen\DIFF.patch'))

$c = New-BudgetCase 'files'; 1..5 | ForEach-Object { Add-Lines $c "f$_.txt" 1 }
$r = Invoke-BudgetCommit $c
Check 'budget: too many files exits 1' ($r.Code -eq 1)
Check 'budget: too many files says so' ($r.Out -match 'files changed \(max 4\)')
Check 'budget: too many files not committed' ((Head-Of $c) -eq $c.Base)
Check 'budget: too many files no DIFF.patch' (-not (Test-Path (Join-Path $c.Wt '.kitchen\DIFF.patch')))

# agent config is never committed from a cook (a planted hook or CLAUDE.md would steer every later cook)
foreach ($cfg in '.claude\settings.json', 'CLAUDE.md', 'sub\CLAUDE.md', '.mcp.json') {
    $c = New-BudgetCase ('cfg-' + ($cfg -replace '\W', '')); Add-Lines $c 'a.txt' 2; Add-Lines $c $cfg 1
    $r = Invoke-BudgetCommit $c
    Check "commit refuses cook-written agent config ($cfg)" ($r.Code -eq 1 -and $r.Out -match 'REFUSED: a cook changed agent config' -and (Head-Of $c) -eq $c.Base)
}

# GitHub automation is never committed from a cook (a workflow could merge its own PR with its token)
foreach ($cfg in '.github\workflows\ci.yml', '.github\dependabot.yml') {
    $c = New-BudgetCase ('gh-' + ($cfg -replace '\W', '')); Add-Lines $c 'a.txt' 2; Add-Lines $c $cfg 1
    $r = Invoke-BudgetCommit $c
    Check "commit refuses cook-written GitHub automation ($cfg)" ($r.Code -eq 1 -and $r.Out -match 'REFUSED: a cook changed GitHub automation' -and (Head-Of $c) -eq $c.Base)
}

$c = New-BudgetCase 'lines'; Add-Lines $c 'big.txt' 200
$r = Invoke-BudgetCommit $c
Check 'budget: too many lines exits 1' ($r.Code -eq 1)
Check 'budget: too many lines says so' ($r.Out -match 'lines changed \(max 150\)')
Check 'budget: too many lines not committed' ((Head-Of $c) -eq $c.Base)

$c = New-BudgetCase 'tests'; Add-Lines $c 'src.txt' 3; 1..8 | ForEach-Object { Add-Lines $c "tests/t$_.ps1" 40 }
$r = Invoke-BudgetCommit $c
Check 'budget: tests/ not counted' ($r.Code -eq 0)

$c = New-BudgetCase 'maxfiles'; Add-Lines $c 'a.txt' 1; Add-Lines $c 'b.txt' 1
$r = Invoke-BudgetCommit $c @('-MaxChangedFiles', '1')
Check 'budget: -MaxChangedFiles 1 rejects 2 files' ($r.Code -eq 1 -and $r.Out -match 'max 1\)')

$c = New-BudgetCase 'maxlines'; Add-Lines $c 'a.txt' 6
$r = Invoke-BudgetCommit $c @('-MaxDiffLines', '5')
Check 'budget: -MaxDiffLines 5 rejects 6 lines' ($r.Code -eq 1 -and $r.Out -match 'max 5\)')

$c = New-BudgetCase 'edge'; 1..4 | ForEach-Object { Add-Lines $c "f$_.txt" 1 }; Add-Lines $c 'f4.txt' 147
$r = Invoke-BudgetCommit $c
Check 'budget: exactly at limit (4 files, 150 lines) passes' ($r.Code -eq 0)

$c = New-BudgetCase 'del'
Add-Lines $c 'old.txt' 160
git -C $c.Wt add -A 2>&1 | Out-Null
git -C $c.Wt -c user.name=t -c user.email=t@localhost commit -q -m old 2>&1 | Out-Null
Set-Content (Join-Path $c.Wt '.kitchen\BASE') (Head-Of $c)
Remove-Item -LiteralPath (Join-Path $c.Wt 'old.txt')
$r = Invoke-BudgetCommit $c
Check 'budget: deletions count' ($r.Code -eq 1 -and $r.Out -match 'lines changed \(max 150\)')

$c = New-BudgetCase 'none'
$r = Invoke-BudgetCommit $c
Check 'budget: no changes still exits 1' ($r.Code -eq 1 -and $r.Out -match 'NO CHANGES')

$recipe = Get-Content -Raw (Join-Path $PSScriptRoot '..\kitchen\recipes\improve.json') | ConvertFrom-Json
$cookPrompt = ($recipe.steps | Where-Object { $_.args -and $_.args.Prompt -match 'line cook' } | Select-Object -First 1).args.Prompt
Check 'improve.json line cook prompt has DIFF BUDGET' ($cookPrompt -match 'DIFF BUDGET')
$env:KITCHEN_JOB = $oldJob; $env:BRAIN_KITCHEN = $oldKitchen

# 9. merge station approval enforcement (merge.ps1 requires approval; kitchen enforces approve:true)
$mergePs = Join-Path $PSScriptRoot '..\kitchen\stations\merge.ps1'
$savedJob = $env:KITCHEN_JOB; $savedKitchen = $env:BRAIN_KITCHEN; $savedApproved = $env:KITCHEN_APPROVED
try {
    $k9 = Join-Path $root 'k9'
    New-Item -ItemType Directory -Force -Path (Join-Path $k9 'jobs') | Out-Null
    $env:BRAIN_KITCHEN = $k9

    # 9a. direct execution without approval exits 2
    $env:KITCHEN_JOB = 'J99'; $env:KITCHEN_APPROVED = $null
    $oNoAppr = & pwsh -NoProfile -File $mergePs -Repo $root 2>&1 | Out-String
    Check 'merge: direct execution without approval exits 2' ($LASTEXITCODE -eq 2)
    Check 'merge: direct execution without approval refuses' ($oNoAppr -match 'unapproved merge operation refused')

    # 9b. direct execution with -Approved passes approval gate
    $oAppr = & pwsh -NoProfile -File $mergePs -Repo $root -Approved 2>&1 | Out-String
    Check 'merge: direct execution with -Approved passes approval check' ($oAppr -notmatch 'unapproved merge operation refused' -and $oAppr -match 'branch kitchen/J99 not found')

    # 9c. direct execution with KITCHEN_APPROVED=1 passes approval gate
    $env:KITCHEN_APPROVED = '1'
    $oEnv = & pwsh -NoProfile -File $mergePs -Repo $root 2>&1 | Out-String
    $env:KITCHEN_APPROVED = $null
    Check 'merge: direct execution with KITCHEN_APPROVED=1 passes approval check' ($oEnv -notmatch 'unapproved merge operation refused' -and $oEnv -match 'branch kitchen/J99 not found')

    # 9d. kitchen add enforces approve:true for station merge even when approve:false was requested
    $env:KITCHEN_JOB = $null
    $specStation = Join-Path $k9 'spec-station.json'
    @{
        name = 'test-station-merge'
        steps = @(
            @{ station = 'merge'; args = @{ Repo = $root }; approve = $false }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $specStation -Encoding utf8
    & $k add -SpecPath $specStation | Out-Null
    $jStation = Get-Content -LiteralPath (Join-Path $k9 'jobs\J1.json') -Raw | ConvertFrom-Json
    Check 'merge: spec with station:merge enforces approve:true' ($jStation.steps[0].approve -eq $true)

    # 9e. kitchen add enforces approve:true for script merge.ps1 even when approve:false was requested
    $specScript = Join-Path $k9 'spec-script.json'
    @{
        name = 'test-script-merge'
        steps = @(
            @{ script = $mergePs; args = @{ Repo = $root }; approve = $false }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $specScript -Encoding utf8
    & $k add -SpecPath $specScript | Out-Null
    $jScript = Get-Content -LiteralPath (Join-Path $k9 'jobs\J2.json') -Raw | ConvertFrom-Json
    Check 'merge: spec with script:merge.ps1 enforces approve:true' ($jScript.steps[0].approve -eq $true)

    # 9f. supervisor tick holds unapproved merge step in waiting-approval
    Set-Content -LiteralPath (Join-Path $k9 'kitchen.json') '{"autoMerge":{"on":false}}'
    & $k tick | Out-Null
    $jHeld = Get-Content -LiteralPath (Join-Path $k9 'jobs\J1.json') -Raw | ConvertFrom-Json
    Check 'merge: unapproved merge job held in waiting-approval' ($jHeld.status -eq 'waiting-approval')
    Check 'merge: approval requested for held job' ($null -ne $jHeld.approval -and $jHeld.approval.id -match '^A\d+')
} finally {
    $env:KITCHEN_JOB = $savedJob; $env:BRAIN_KITCHEN = $savedKitchen; $env:KITCHEN_APPROVED = $savedApproved
}

# 10. update-proof pwsh for scheduled tasks (read-only: -WhatIf registers nothing; the live task definition is compared before and after)
$sp = Join-Path $PSScriptRoot '..\scripts\stable-pwsh.ps1'; $it = Join-Path $PSScriptRoot '..\scripts\install-tasks.ps1'
$alias = Join-Path $root 'alias\pwsh.exe'; New-Item -ItemType Directory -Force -Path (Split-Path $alias) | Out-Null; Set-Content $alias 'x'
$verDir = Join-Path $root 'Program Files\WindowsApps\Microsoft.PowerShell_7.6.7.0_x64__8wekyb3d8bbwe'; New-Item -ItemType Directory -Force -Path $verDir | Out-Null; Set-Content "$verDir\pwsh.exe" 'x'
$r1 = & $sp -Candidates "$verDir\pwsh.exe", $alias 2>$null
Check 'stable-pwsh skips the versioned Store folder for the alias' ($LASTEXITCODE -eq 0 -and $r1 -eq $alias)
$null = & pwsh -NoProfile -File $sp -Candidates "$verDir\pwsh.exe" 2>$null
Check 'stable-pwsh fails closed when only a versioned pwsh exists' ($LASTEXITCODE -eq 1)
# Task Scheduler is denied at Low integrity by design (the kitchen sandbox): this check needs it, so it runs at Medium only
if ((& "$env:SystemRoot\System32\whoami.exe" /groups 2>$null | Out-String) -match 'Low Mandatory Level') { Write-Host 'SKIP: install-tasks check needs Task Scheduler (not at Low)' } else {
# the tick's live name (old or new, scripts/task-names.json): the plan uses whichever one is registered
$liveTick = @(foreach ($n in 'Tide-Yard', 'Kitchen-Supervisor') { if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { $n } })[0]; if (-not $liveTick) { $liveTick = 'Kitchen-Supervisor' }
$before = try { (Export-ScheduledTask -TaskName $liveTick -ErrorAction Stop) } catch { '' }
$wi = & pwsh -NoProfile -File $it -WhatIf -RunBeforeSignIn | Out-String
Check 'install-tasks -WhatIf plans both tasks with the alias pwsh and registers nothing' ($LASTEXITCODE -eq 0 -and $wi -match 'WHATIF: nothing registered' -and $wi -match '(Kitchen-Supervisor|Tide-Yard): \S*\\wscript\.exe //B //NoLogo "\S*\\run-hidden\.vbs" "\S*\\Microsoft\\WindowsApps\\pwsh\.exe" .*kitchen\.ps1" tick -Quiet' -and $wi -match '(Kitchen-Pass|Tide-Board): \S*wscript\.exe' -and $wi -match 'and at startup' -and $wi -match 'stored password')
Check 'install-tasks -WhatIf plans Kitchen-Chores (TARGET W2): kitchen.ps1 chores every 2 minutes, 10 min limit' ($wi -match '(Kitchen-Chores|Tide-Cleanup): \S*\\wscript\.exe //B //NoLogo "\S*\\run-hidden\.vbs" "\S*\\Microsoft\\WindowsApps\\pwsh\.exe" .*kitchen\.ps1" chores -Quiet' -and $wi -match 'every 2 minutes, forever')
Check 'install-tasks never plans a versioned pwsh'($wi -notmatch '(Kitchen-Supervisor|Tide-Yard|Kitchen-Chores|Tide-Cleanup): [^\r\n]*Microsoft\.PowerShell_\d')
$after = try { (Export-ScheduledTask -TaskName $liveTick -ErrorAction Stop) } catch { '' }
Check 'install-tasks -WhatIf left the live task untouched' ($before -eq $after)
}
$wf = & pwsh -NoProfile -File $it -WhatIf -PwshCandidates "$verDir\pwsh.exe" | Out-String
Check 'install-tasks refuses when only a versioned pwsh exists' ($LASTEXITCODE -eq 1 -and $wf -match 'nothing registered')
$rd = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\rgb.ps1') -Action install-schedule -OffAt 22:00 -OnAt 07:00 -TaskPrefix RigRgbDry -DryRun | Out-String
# the alias exists only where PowerShell came from the Microsoft Store (Jordan's PC); the CI box has a plain install
if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')) { Check 'rgb schedule would run the update-proof pwsh' ($rd -match 'running \S*\\Microsoft\\WindowsApps\\pwsh\.exe' -and $rd -notmatch 'PowerShell_\d') } else { Write-Host 'SKIP: no Store pwsh alias here' }

# Tree-MB: a reused parent pid must not pull an older, unrelated process into a step's memory
$fa = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $k).Path, [ref]$null, [ref]$null).FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Tree-MB' }, $true)
. ([scriptblock]::Create($fa[0].Extent.Text))
$t0 = [datetime]'2026-10-22T20:00:00'
function P($id, $parent, $mb, $min) { [pscustomobject]@{ ProcessId = $id; ParentProcessId = $parent; WorkingSetSize = $mb * 1MB; CreationDate = $t0.AddMinutes($min) } }
$ps = @((P 100 1 50 10), (P 101 100 200 11), (P 102 101 300 12), (P 900 100 8000 -60), (P 901 900 1000 -59))
Check 'Tree-MB sums the real tree' ((Tree-MB 100 $ps) -eq 550)
Check 'Tree-MB skips a process older than its reused-pid parent' ((Tree-MB 100 $ps) -lt 8000)
$nd = @($ps | ForEach-Object { [pscustomobject]@{ ProcessId = $_.ProcessId; ParentProcessId = $_.ParentProcessId; WorkingSetSize = $_.WorkingSetSize } })
Check 'Tree-MB without start times still walks by parent' ((Tree-MB 100 $nd) -eq 9550)

# a heartbeat write waits out a reader holding the file instead of killing the step (10-22: J211, J229 died on a busy .hb)
$hb = "$root\busy.hb"; Set-Content $hb 'old'
$held = [IO.File]::Open($hb, 'Open', 'Read', 'None')
$env:KITCHEN_HEARTBEAT = $hb
$wp = Start-Process pwsh -ArgumentList '-NoProfile', '-File', (Join-Path $PSScriptRoot '..\kitchen\demo-worker.ps1'), '-Behavior', 'ok', '-Seconds', '1' -PassThru -NoNewWindow -RedirectStandardOutput "$root\hbw.out" -RedirectStandardError "$root\hbw.err"
Start-Sleep -Milliseconds 1500; $held.Dispose(); $wp.WaitForExit(30000) | Out-Null; $env:KITCHEN_HEARTBEAT = $null
Check 'heartbeat on a busy file does not crash the step' ($wp.ExitCode -eq 0 -and -not (Get-Content "$root\hbw.err" -Raw))

Remove-Item -Recurse -Force $root
Write-Host "Kitchen tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
