# Tests for the one scheduled-task name list, scripts/task-names.json ([old, new] per task), and the scripts that read it:
# install-tasks.ps1 (accepts both names, installs one, refuses a second name for a task that is registered), the kitchen.ps1 watchdog
# (restarts whichever Board task exists), kitchen-check.ps1, watch.ps1, pass-app/update.ps1 and the justfile. The real tasks are never
# read for a decision and never changed: install-tasks runs only with -WhatIf and a stand-in list of registered names (-TestRegistered).
# Called by the kitchen tests station (it globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Private temp root; self-cleaning.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$namesPath = Join-Path $repo 'scripts\task-names.json'
$it = Join-Path $repo 'scripts\install-tasks.ps1'
$pwshBin = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-tasknames-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Run([string[]]$a) { $o = & $pwshBin -NoProfile -NonInteractive -File $it @a 2>&1 | Out-String; [pscustomobject]@{ code = $LASTEXITCODE; out = $o } }
$saved = @{}; foreach ($n in 'BRAIN_KITCHEN') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
try {
    New-Item -ItemType Directory -Force $root | Out-Null
    $env:BRAIN_KITCHEN = Join-Path $root 'kitchen'; New-Item -ItemType Directory -Force $env:BRAIN_KITCHEN | Out-Null

    # 1. the list: three tasks, each [old, new], with Jordan's names (GLOSSARY.md, decisions 2026-10-23 09:30 MT)
    $tn = Get-Content -LiteralPath $namesPath -Raw | ConvertFrom-Json
    Check 'task-names.json: supervisor is [Kitchen-Supervisor, Tide-Yard]' ((@($tn.supervisor) -join ',') -eq 'Kitchen-Supervisor,Tide-Yard')
    Check 'task-names.json: chores is [Kitchen-Chores, Tide-Cleanup]' ((@($tn.chores) -join ',') -eq 'Kitchen-Chores,Tide-Cleanup')
    Check 'task-names.json: board is [Kitchen-Pass, Tide-Board]' ((@($tn.board) -join ',') -eq 'Kitchen-Pass,Tide-Board')

    # 2. kitchen.ps1 watchdog: Find-KitchenTask, taken from kitchen.ps1 itself, with a stand-in for the scheduler
    $ksrc = Get-Content -LiteralPath (Join-Path $repo 'kitchen\kitchen.ps1') -Raw
    $ast = [Management.Automation.Language.Parser]::ParseInput($ksrc, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Find-KitchenTask' }, $true))
    Check 'kitchen.ps1 defines Find-KitchenTask once' ($fn.Count -eq 1)
    . ([scriptblock]::Create($fn[0].Extent.Text))
    function Stub([string[]]$present) { $p = $present; { param($n) if ($n -in $p) { [pscustomobject]@{ TaskName = $n; State = 'Ready' } } }.GetNewClosure() }
    Check 'watchdog: today (only Kitchen-Pass registered) it finds Kitchen-Pass' ((Find-KitchenTask 'board' -Path $namesPath -Get (Stub 'Kitchen-Pass', 'Kitchen-Supervisor')).TaskName -eq 'Kitchen-Pass')
    Check 'watchdog: after S4 (only Tide-Board) it finds Tide-Board' ((Find-KitchenTask 'board' -Path $namesPath -Get (Stub 'Tide-Board')).TaskName -eq 'Tide-Board')
    Check 'watchdog: both registered -> the new name wins' ((Find-KitchenTask 'board' -Path $namesPath -Get (Stub 'Kitchen-Pass', 'Tide-Board')).TaskName -eq 'Tide-Board')
    Check 'watchdog: no Board task -> nothing (no restart)' ($null -eq (Find-KitchenTask 'board' -Path $namesPath -Get (Stub 'Kitchen-Supervisor')))
    Check 'watchdog: no task-names.json -> the old name still works' ((Find-KitchenTask 'board' -Path (Join-Path $root 'nope.json') -Get (Stub 'Kitchen-Pass')).TaskName -eq 'Kitchen-Pass')
    Set-Content -LiteralPath (Join-Path $root 'broken.json') -Value '{ not json'
    Check 'watchdog: a broken task-names.json -> the old name (the tick never breaks)' ((Find-KitchenTask 'board' -Path (Join-Path $root 'broken.json') -Get (Stub 'Kitchen-Pass')).TaskName -eq 'Kitchen-Pass')
    Check 'watchdog: restarts the task it found, by its name, and says "The Board server was down; restarted"' ($ksrc -match [regex]::Escape("`$pt = if (-not `$up) { Find-KitchenTask 'board' }") -and $ksrc -match [regex]::Escape("Start-ScheduledTask -TaskName `$pt.TaskName; `$fixed += 'The Board server was down; restarted'") -and $ksrc -notmatch "ScheduledTask -TaskName 'Kitchen-Pass'" -and $ksrc -notmatch 'Chef server was down')

    # 3. the other readers name the list, not a fixed task
    $kc = Get-Content -LiteralPath (Join-Path $repo 'scripts\kitchen-check.ps1') -Raw
    Check 'kitchen-check.ps1 reads the supervisor names from task-names.json' ($kc -match [regex]::Escape("(Join-Path `$PSScriptRoot 'task-names.json')") -and $kc -match [regex]::Escape('ConvertFrom-Json).supervisor') -and $kc -notmatch "-TaskName 'Kitchen-Supervisor'")
    $jf = Get-Content -LiteralPath (Join-Path $repo 'justfile') -Raw
    Check 'justfile health reads the supervisor names from task-names.json' ($jf -match 'scripts/task-names\.json" -Raw \| ConvertFrom-Json\)\.supervisor' -and $jf -notmatch 'Get-ScheduledTask Kitchen-Supervisor')
    Check 'pass-app/update.ps1 reads the board names from the same file' ((Get-Content -LiteralPath (Join-Path $repo 'pass-app\update.ps1') -Raw) -match [regex]::Escape("'..\scripts\task-names.json'"))

    # 4. install-tasks.ps1 (only -WhatIf, with a stand-in list of registered tasks; Task Scheduler objects are built, nothing is registered)
    $groups = & "$env:SystemRoot\System32\whoami.exe" /groups 2>$null | Out-String
    if ($groups -match 'Low Mandatory Level') { Write-Host 'SKIP: install-tasks checks need Task Scheduler (not at Low)' } else {
    $fakePwsh = Join-Path $root 'ps7\pwsh.exe'; New-Item -ItemType Directory -Force (Split-Path $fakePwsh) | Out-Null; Set-Content -LiteralPath $fakePwsh -Value 'x'
    $base = @('-WhatIf', '-PwshCandidates', $fakePwsh)
    $r = Run ($base + @('-TestRegistered', 'Kitchen-Supervisor,Kitchen-Chores,Kitchen-Pass'))
    Check 'install-tasks today: plans the three old names and registers nothing' ($r.code -eq 0 -and $r.out -match '(?m)^Kitchen-Supervisor: ' -and $r.out -match '(?m)^Kitchen-Chores: ' -and $r.out -match '(?m)^Kitchen-Pass: ' -and $r.out -notmatch 'Tide-' -and $r.out -match 'WHATIF: nothing registered')
    $r = Run ($base + @('-TestRegistered', ''))
    Check 'install-tasks on a new PC (nothing registered): the old names' ($r.code -eq 0 -and $r.out -match '(?m)^Kitchen-Supervisor: ' -and $r.out -match '(?m)^Kitchen-Pass: ' -and $r.out -notmatch 'Tide-')
    $r = Run ($base + @('-TestRegistered', 'Tide-Yard,Tide-Cleanup,Tide-Board'))
    Check 'install-tasks after S4: keeps the new names (Tide-Yard tick, Tide-Cleanup chores, Tide-Board server)' ($r.code -eq 0 -and $r.out -match '(?m)^Tide-Yard: .*kitchen\.ps1" tick -Quiet' -and $r.out -match '(?m)^Tide-Cleanup: .*kitchen\.ps1" chores -Quiet' -and $r.out -match '(?m)^Tide-Board: \S*wscript\.exe' -and $r.out -notmatch '(?m)^Kitchen-')
    $r = Run ($base + @('-Only', 'Tide-Yard', '-TestRegistered', 'Kitchen-Supervisor'))
    Check 'install-tasks refuses a new-name task while the old-name one exists (no double tick)' ($r.code -eq 2 -and $r.out -match 'Kitchen-Supervisor is registered, so registering Tide-Yard would run the same task twice' -and $r.out -match 'nothing registered' -and $r.out -notmatch 'WHATIF')
    $r = Run ($base + @('-Only', 'Kitchen-Pass', '-TestRegistered', 'Tide-Board'))
    Check 'install-tasks refuses the old name while the new-name one exists (the old script after S4)' ($r.code -eq 2 -and $r.out -match 'Tide-Board is registered, so registering Kitchen-Pass')
    $r = Run ($base + @('-Only', 'Tide-Cleanup', '-TestRegistered', ''))
    Check 'install-tasks accepts a new name when no other name of that task exists' ($r.code -eq 0 -and $r.out -match '(?m)^Tide-Cleanup: .*chores -Quiet' -and $r.out -notmatch '(?m)^Kitchen-' -and $r.out -match 'WHATIF')
    $r = Run ($base + @('-Only', 'Kitchen-Chores', '-TestRegistered', 'Kitchen-Chores'))
    Check 'install-tasks -Only with an old name still works (the W2 tap)' ($r.code -eq 0 -and $r.out -match '(?m)^Kitchen-Chores: ' -and $r.out -match 'WHATIF')
    $r = Run ($base + @('-Only', 'Tide-Yard,Kitchen-Supervisor', '-TestRegistered', ''))
    Check 'install-tasks refuses two names of one task in one run' ($r.code -eq 2 -and $r.out -match 'are the same task')
    $r = Run ($base + @('-Only', 'Kitchen-Nope', '-TestRegistered', ''))
    Check 'install-tasks refuses an unknown name' ($r.code -eq 2 -and $r.out -match 'unknown task name Kitchen-Nope')
    $r = Run ($base + @('-TaskNamesPath', (Join-Path $root 'broken.json'), '-TestRegistered', ''))
    Check 'install-tasks stops on a broken task-names.json' ($r.code -eq 2 -and $r.out -match 'not valid JSON' -and $r.out -notmatch 'WHATIF')
    Set-Content -LiteralPath (Join-Path $root 'swapped.json') -Value '{"supervisor":["Tide-Yard","Kitchen-Supervisor"],"chores":["Kitchen-Chores","Tide-Cleanup"],"board":["Kitchen-Pass","Tide-Board"]}'
    $r = Run ($base + @('-TaskNamesPath', (Join-Path $root 'swapped.json'), '-TestRegistered', ''))
    Check 'install-tasks stops when a list does not start with the old name' ($r.code -eq 2 -and $r.out -match 'must list supervisor as \[Kitchen-Supervisor, new name\]')
    $r = Run ($base + @('-TaskNamesPath', (Join-Path $root 'nope.json'), '-TestRegistered', ''))
    Check 'install-tasks with no task-names.json: the old names' ($r.code -eq 0 -and $r.out -match '(?m)^Kitchen-Supervisor: ' -and $r.out -match '(?m)^Kitchen-Pass: ')
    }
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Task-name tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
