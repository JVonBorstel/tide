# Tests for scripts/rename-tasks.ps1 (Tide rename S4: Kitchen-Supervisor -> Tide-Yard, Kitchen-Chores -> Tide-Cleanup, Kitchen-Pass ->
# Tide-Board). Every scheduler, process and network call goes to an in-memory stand-in (the script's -Ops), so no real task, port or
# process is read or changed; the real task cmdlets and Stop-Process are also shadowed by functions that throw, as a second fence.
# Covers: the dry run changes nothing and shows the diff, the order of the steps, settings kept, backups written before the first change,
# undo, the port wait and health check gating the Board swap, a failure midway putting the old task back (on), refusals, idempotency.
# Called by the kitchen tests station (it globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Private temp root; self-cleaning.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rt = Join-Path $repo 'scripts\rename-tasks.ps1'
$namesPath = Join-Path $repo 'scripts\task-names.json'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-renametasks-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
# second fence: if the script ever reached a real cmdlet, these (found first, by scope) throw instead
foreach ($c in 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Enable-ScheduledTask', 'Disable-ScheduledTask', 'Start-ScheduledTask', 'Stop-ScheduledTask', 'Stop-Process') {
    Set-Item -Path "function:script:$c" -Value ([scriptblock]::Create("throw 'TEST FENCE: the real $c was called'"))
}
$me = 'S-1-5-21-1-2-3-1001'
function New-TaskXml([string]$Name, [switch]$Board, [switch]$Off) {
    $trig = if ($Board) { "    <LogonTrigger>`r`n      <UserId>PC\me</UserId>`r`n    </LogonTrigger>" } else { "    <TimeTrigger>`r`n      <StartBoundary>2026-10-19T07:27:02-06:00</StartBoundary>`r`n      <Repetition>`r`n        <Interval>PT1M</Interval>`r`n        <StopAtDurationEnd>true</StopAtDurationEnd>`r`n      </Repetition>`r`n    </TimeTrigger>" }
    $rof = if ($Board) { "`r`n    <RestartOnFailure>`r`n      <Count>5</Count>`r`n      <Interval>PT1M</Interval>`r`n    </RestartOnFailure>" } else { '' }
    $en = if ($Off) { "`r`n    <Enabled>false</Enabled>" } else { '' }
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>test task $Name. Off: Unregister-ScheduledTask $Name</Description>
    <URI>\$Name</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$me</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <ExecutionTimeLimit>$(if ($Board) { 'PT0S' } else { 'PT5M' })</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>$rof
    <StartWhenAvailable>true</StartWhenAvailable>$en
    <IdleSettings>
      <Duration>PT10M</Duration>
      <StopOnIdleEnd>true</StopOnIdleEnd>
    </IdleSettings>
  </Settings>
  <Triggers>
$trig
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>C:\x\$(if ($Board) { 'wscript.exe' } else { 'pwsh.exe' })</Command>
      <Arguments>"C:\x\$Name.ps1" tick</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}
# the stand-in scheduler: tasks (xml, on, running, engine pid), one port, processes; mutating calls are logged in order
function New-World {
    $w = @{ tasks = @{}; calls = [Collections.Generic.List[string]]::new(); port = $null; procs = @{}; nextPid = 5000; fail = @{}
        stopLeavesPort = $false; strayOnPort = $false; noServer = $false; unhealthy = $false; tamper = $null; masks = @{}; slept = 0
        who = [pscustomobject]@{ Elevated = $false; Sid = $me; Name = 'PC\me'; RootMask = 0x120116 }; backupDir = $null }
    foreach ($n in 'Kitchen-Supervisor', 'Kitchen-Chores') { $w.tasks[$n] = @{ xml = (New-TaskXml $n); on = $true; engine = $null } }
    $w.tasks['Kitchen-Pass'] = @{ xml = (New-TaskXml 'Kitchen-Pass' -Board); on = $true; engine = 4000 }
    $w.procs[4000] = [pscustomobject]@{ Id = 4000; Name = 'wscript.exe'; ParentId = 1; CommandLine = 'wscript start-hidden.vbs' }
    $w.procs[4001] = [pscustomobject]@{ Id = 4001; Name = 'node.exe'; ParentId = 4000; CommandLine = '"node.exe" "C:\x\pass-app\server.mjs"' }
    $w.port = 4001
    $w
}
function New-FakeOps($w) {
    $fixXml = { param($x, $on) $x = $x -replace '\r?\n\s*<Enabled>(true|false)</Enabled>', ''; if (-not $on) { $x = $x -replace '(\r?\n)(\s*)<IdleSettings>', '$1$2<Enabled>false</Enabled>$1$2<IdleSettings>' }; $x }
    $isBoard = { param($n) $n -in 'Kitchen-Pass', 'Tide-Board' }
    $mut = { param($op, $n) $w.calls.Add("$op $n"); if ($w.fail["$op $n"]) { throw "stand-in: $op $n failed" } }
    $ops = @{
        Get        = { param($n) $t = $w.tasks[$n]; if ($t) { [pscustomobject]@{ Name = $n; State = $(if ($t.engine) { 'Running' } elseif (-not $t.on) { 'Disabled' } else { 'Ready' }) } } }
        Export     = { param($n) $x = & $fixXml $w.tasks[$n].xml $w.tasks[$n].on; if ($w.tamper -and $n -like 'Tide-*') { $x = & $w.tamper $x }; $x }
        Register   = { param($n, $x) & $mut 'Register' $n; $w.calls.Add("backups=$(@(Get-ChildItem -LiteralPath $w.backupDir -Filter *.xml -ErrorAction SilentlyContinue).Count)"); $w.tasks[$n] = @{ xml = $x; on = ($x -notmatch '<Settings>[\s\S]*<Enabled>false</Enabled>[\s\S]*</Settings>'); engine = $null } }
        Enable     = { param($n) & $mut 'Enable' $n; $w.tasks[$n].on = $true }
        Disable    = { param($n) & $mut 'Disable' $n; $w.tasks[$n].on = $false }
        Stop       = { param($n) & $mut 'Stop' $n; $t = $w.tasks[$n]; $e = $t.engine; $t.engine = $null
            if ((& $isBoard $n) -and $w.port -and $w.procs[$w.port].ParentId -eq $e) { if ($w.strayOnPort) { $w.port = 7777; $w.procs[7777] = [pscustomobject]@{ Id = 7777; Name = 'python.exe'; ParentId = 1; CommandLine = 'python -m http.server 7878' } } elseif (-not $w.stopLeavesPort) { $w.port = $null } } }
        Start      = { param($n) & $mut 'Start' $n; $t = $w.tasks[$n]; if (-not $t.on) { throw "stand-in: $n is disabled" }
            $e = $w.nextPid; $w.nextPid += 2; $t.engine = $e; $w.procs[$e] = [pscustomobject]@{ Id = $e; Name = 'wscript.exe'; ParentId = 1; CommandLine = 'wscript' }
            if ((& $isBoard $n) -and -not $w.noServer -and -not $w.port) { $w.procs[$e + 1] = [pscustomobject]@{ Id = $e + 1; Name = 'node.exe'; ParentId = $e; CommandLine = '"node.exe" "C:\x\pass-app\server.mjs"' }; $w.port = $e + 1 } }
        Unregister = { param($n) & $mut 'Unregister' $n; $w.tasks.Remove($n) }
        EnginePid  = { param($n) if ($w.tasks[$n]) { $w.tasks[$n].engine } }
        PortPid    = { param($p) if ($p -eq 7878) { $w.port } }
        Proc       = { param($id) $w.procs[[int]$id] }
        Kill       = { param($id) $w.calls.Add("Kill $id"); $w.procs.Remove([int]$id); if ($w.port -eq $id) { $w.port = $null } }
        Health     = { param($p) if ($p -eq 7878 -and $w.port -and -not $w.unhealthy) { [pscustomobject]@{ ok = $true; version = 'test' } } }
        Sleep      = { param($ms) $w.slept += $ms }
        Who        = { $w.who }
        TaskMask   = { param($n) if ($w.masks.ContainsKey($n)) { $w.masks[$n] } elseif ($w.tasks[$n]) { 0x1F01FF } }
    }
    foreach ($k in @($ops.Keys)) { $ops[$k] = $ops[$k].GetNewClosure() }
    $ops
}
function Run($w, [switch]$DryRun, [switch]$Undo, [string]$Root = $script:root) {
    $w.backupDir = Join-Path $Root 'backups\tasks-s4'
    $a = @{ Ops = (New-FakeOps $w); StateRoot = $Root; TaskNamesPath = $namesPath; PortWaitSec = 1; HealthWaitSec = 1; IdleWaitSec = 1 }
    if ($DryRun) { $a.DryRun = $true }; if ($Undo) { $a.Undo = $true }
    $o = & $rt @a *>&1 | Out-String
    [pscustomobject]@{ code = $LASTEXITCODE; out = $o; calls = @($w.calls) }
}
function Snap($w) { (@($w.tasks.Keys | Sort-Object | ForEach-Object { "$_|$($w.tasks[$_].on)|$($w.tasks[$_].engine)|$($w.tasks[$_].xml.Length)" }) -join ';') + ";port=$($w.port)" }
function Idx($r, [string]$call) { [array]::IndexOf([string[]]$r.calls, $call) }
function Norm([string]$x) { ($x -replace '\r?\n\s*<Enabled>(true|false)</Enabled>', '' -replace '<URI>[^<]*</URI>', '<URI/>') }
$mutating = '^(Register|Enable|Disable|Stop|Start|Unregister|Kill) '

try {
    $script:root = Join-Path $tmp 'yard'; New-Item -ItemType Directory -Force (Join-Path $root 'jobs') | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'PAUSED') -Value 'test'
    $src = Get-Content -LiteralPath $rt -Raw

    # 1. the script itself: real calls register from the exported XML, refuse admin, never touch Rig-RGB
    Check 'real Register uses the task XML (-Xml), so every setting, trigger, principal and action is kept' ($src -match [regex]::Escape("Register-ScheduledTask -TaskName `$n -TaskPath '\' -Xml `$xml") -and $src -match 'Export-ScheduledTask -TaskName \$n')
    Check 'the header says plainly: a normal PowerShell, not admin' ($src -match 'RUN IT FROM A NORMAL POWERSHELL, NOT "Run as administrator"')
    Check 'Rig-RGB tasks are not in the script''s work (named only to say so)' (@($src -split '\r?\n' | Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'Rig-' }).Count -eq 0)
    $errs = $null; $null = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$errs); Check 'rename-tasks.ps1 parses' (-not $errs)

    # 2. dry run: every step and the diff printed, nothing changed, no backup written
    $w = New-World; $before = Snap $w
    $r = Run $w -DryRun
    Check 'dry run: exit 0' ($r.code -eq 0)
    Check 'dry run: no changing call at all' (@($r.calls | Where-Object { $_ -match $mutating }).Count -eq 0)
    Check 'dry run: the stand-in scheduler is exactly as before' ((Snap $w) -eq $before)
    Check 'dry run: no backup file written' (-not (Test-Path -LiteralPath (Join-Path $root 'backups')))
    Check 'dry run: prints each step for all three' ($r.out -match 'would: register Tide-Yard from that XML' -and $r.out -match 'would: register Tide-Cleanup' -and $r.out -match 'would: register Tide-Board' -and $r.out -match 'would: unregister Kitchen-Pass' -and $r.out -match 'would: stop Kitchen-Pass' -and $r.out -match 'would: wait until port 7878 is free' -and $r.out -match 'would: health check http://127.0.0.1:7878/api/health')
    Check 'dry run: the XML diff is only the URI and the off switch' ($r.out -match '-\s+\d+:\s+<URI>\\Kitchen-Supervisor</URI>' -and $r.out -match '\+\s+\d+:\s+<URI>\\Tide-Yard</URI>' -and $r.out -match '\+\s+\d+:\s+<Enabled>false</Enabled>' -and $r.out -notmatch '[-+]\s+\d+:\s+<(Interval|UserId|Command|ExecutionTimeLimit)>')
    Check 'dry run: says how to do it and from a normal PowerShell' ($r.out -match 'DRY RUN done: nothing was changed' -and $r.out -match 'normal \(not admin\) PowerShell: pwsh scripts\\rename-tasks\.ps1')

    # 3. the real run (stand-in): order, backups first, settings kept, the Board gated by the port and health
    $w = New-World; $orig = @{}; foreach ($n in @($w.tasks.Keys)) { $orig[$n] = $w.tasks[$n].xml }
    $r = Run $w
    Check 'rename: exit 0 and says Done' ($r.code -eq 0 -and $r.out -match 'Done\. Next: pwsh kitchen\\kitchen\.ps1 resume')
    Check 'rename: only the three new names are left' ((@($w.tasks.Keys | Sort-Object) -join ',') -eq 'Tide-Board,Tide-Cleanup,Tide-Yard')
    Check 'rename: all three backups were written before the first change' ($r.calls[0] -eq 'Register Tide-Yard' -and $r.calls[1] -eq 'backups=3')
    $bk = Join-Path $root 'backups\tasks-s4'
    Check 'rename: each backup is the old task''s own XML (UTF-16)' (@('Kitchen-Supervisor', 'Kitchen-Chores', 'Kitchen-Pass' | Where-Object { (Get-Content -LiteralPath (Join-Path $bk "$_.xml") -Raw -Encoding Unicode) -ceq $orig[$_] }).Count -eq 3)
    foreach ($pair in @(@('Kitchen-Supervisor', 'Tide-Yard'), @('Kitchen-Chores', 'Tide-Cleanup'))) {
        $o, $n = $pair
        Check "rename order for ${n}: register (off) -> switch old off -> switch new on -> unregister old" ((Idx $r "Register $n") -lt (Idx $r "Disable $o") -and (Idx $r "Disable $o") -lt (Idx $r "Enable $n") -and (Idx $r "Enable $n") -lt (Idx $r "Unregister $o") -and (Idx $r "Register $n") -ge 0)
        Check "settings kept: $n is $o's XML except the URI and the switch" ((Norm $w.tasks[$n].xml) -ceq (Norm $orig[$o]) -and $w.tasks[$n].xml -match "<URI>\\$n</URI>" -and $w.tasks[$n].on)
    }
    Check 'Board order: register -> old off -> stop old -> new on -> start new -> unregister old' ((Idx $r 'Register Tide-Board') -lt (Idx $r 'Disable Kitchen-Pass') -and (Idx $r 'Disable Kitchen-Pass') -lt (Idx $r 'Stop Kitchen-Pass') -and (Idx $r 'Stop Kitchen-Pass') -lt (Idx $r 'Enable Tide-Board') -and (Idx $r 'Enable Tide-Board') -lt (Idx $r 'Start Tide-Board') -and (Idx $r 'Start Tide-Board') -lt (Idx $r 'Unregister Kitchen-Pass'))
    Check 'Board order: the tick tasks are all done before the Board is touched' ((Idx $r 'Unregister Kitchen-Chores') -lt (Idx $r 'Register Tide-Board'))
    Check 'Board: settings kept (logon trigger, restart on failure, no time limit)' ((Norm $w.tasks['Tide-Board'].xml) -ceq (Norm $orig['Kitchen-Pass']))
    Check 'Board: health ok and the port is held by Tide-Board''s own process' ($r.out -match 'health ok \(version test\); port 7878 is node\.exe pid \d+, started by Tide-Board' -and $w.procs[[int]$w.port].ParentId -eq $w.tasks['Tide-Board'].engine)

    # 4. idempotent: a second run does nothing
    $r2 = Run $w
    Check 'second run: exit 0, Nothing to do, no changing call' ($r2.code -eq 0 -and $r2.out -match 'Nothing to do\.' -and @($r2.calls | Select-Object -Skip $r.calls.Count | Where-Object { $_ -match $mutating }).Count -eq 0)

    # 5. undo restores the old names from the backups (and the Board runs again), then is idempotent too
    $w.calls.Clear()
    $u = Run $w -Undo
    Check 'undo: exit 0, the old three are back, the new ones gone' ($u.code -eq 0 -and (@($w.tasks.Keys | Sort-Object) -join ',') -eq 'Kitchen-Chores,Kitchen-Pass,Kitchen-Supervisor')
    Check 'undo: each old task is its backup again (URI included), switched on' (@('Kitchen-Supervisor', 'Kitchen-Chores', 'Kitchen-Pass' | Where-Object { ($w.tasks[$_].xml -replace '\r?\n\s*<Enabled>false</Enabled>', '') -ceq $orig[$_] -and $w.tasks[$_].on }).Count -eq 3)
    Check 'undo: the Board runs under Kitchen-Pass and answers' ($w.tasks['Kitchen-Pass'].engine -and $w.procs[[int]$w.port].ParentId -eq $w.tasks['Kitchen-Pass'].engine -and (Idx $u 'Stop Tide-Board') -lt (Idx $u 'Start Kitchen-Pass'))
    $w.calls.Clear(); $u2 = Run $w -Undo
    Check 'undo again: Nothing to do, no changing call' ($u2.code -eq 0 -and $u2.out -match 'Nothing to do\.' -and @($u2.calls | Where-Object { $_ -match $mutating }).Count -eq 0)
    Remove-Item -LiteralPath (Join-Path $root 'backups') -Recurse -Force

    # 6. the port gates the Board: a stranger on 7878 -> Tide-Board never started, Kitchen-Pass back on and running
    $w = New-World; $w.strayOnPort = $true
    $r = Run $w
    Check 'port held by another program: exit 1, Tide-Board never started or switched on' ($r.code -eq 1 -and (Idx $r 'Start Tide-Board') -lt 0 -and (Idx $r 'Enable Tide-Board') -lt 0 -and $r.out -match 'which is not the Board server that was running: not touching it')
    Check 'port held by another program: that program is never stopped' (@($r.calls | Where-Object { $_ -like 'Kill*' }).Count -eq 0)
    Check 'port held by another program: Tide-Board removed, Kitchen-Pass on again, the tick tasks keep their new names' (-not $w.tasks['Tide-Board'] -and $w.tasks['Kitchen-Pass'].on -and (Idx $r 'Start Kitchen-Pass') -gt (Idx $r 'Unregister Tide-Board') -and $w.tasks['Tide-Yard'] -and $w.tasks['Tide-Cleanup'] -and $r.out -match 'STOPPED')
    Remove-Item -LiteralPath (Join-Path $root 'backups') -Recurse -Force
    # the old Board server outliving its task: that one node process is stopped, then the swap goes on
    $w = New-World; $w.stopLeavesPort = $true
    $r = Run $w
    Check 'old server keeps the port: its node pid (and only it) is stopped, then Tide-Board starts' ($r.code -eq 0 -and (Idx $r 'Kill 4001') -gt (Idx $r 'Stop Kitchen-Pass') -and (Idx $r 'Kill 4001') -lt (Idx $r 'Start Tide-Board') -and @($r.calls | Where-Object { $_ -like 'Kill*' }).Count -eq 1)
    Remove-Item -LiteralPath (Join-Path $root 'backups') -Recurse -Force
    # health gates it: Tide-Board starts but nothing answers -> back to Kitchen-Pass
    $w = New-World; $w.noServer = $true
    $r = Run $w
    Check 'no health answer: exit 1, Tide-Board stopped and removed, Kitchen-Pass on and started, never unregistered' ($r.code -eq 1 -and -not $w.tasks['Tide-Board'] -and $w.tasks['Kitchen-Pass'].on -and (Idx $r 'Unregister Kitchen-Pass') -lt 0 -and (Idx $r 'Start Kitchen-Pass') -gt (Idx $r 'Stop Tide-Board') -and $r.out -match 'did not answer ok')
    Remove-Item -LiteralPath (Join-Path $root 'backups') -Recurse -Force

    # 7. a failure midway leaves the old task on
    $w = New-World; $w.fail['Register Tide-Cleanup'] = $true
    $r = Run $w
    Check 'register fails for Tide-Cleanup: exit 1, Kitchen-Chores still on, never switched off; the Board untouched' ($r.code -eq 1 -and $w.tasks['Kitchen-Chores'].on -and (Idx $r 'Disable Kitchen-Chores') -lt 0 -and -not $w.tasks['Tide-Cleanup'] -and @($r.calls | Where-Object { $_ -match 'Kitchen-Pass|Tide-Board' }).Count -eq 0)
    Remove-Item -LiteralPath (Join-Path $root 'backups') -Recurse -Force
    $w = New-World; $w.fail['Enable Tide-Yard'] = $true
    $r = Run $w
    Check 'switching the new one on fails: Tide-Yard removed, Kitchen-Supervisor switched on again, not unregistered' ($r.code -eq 1 -and -not $w.tasks['Tide-Yard'] -and $w.tasks['Kitchen-Supervisor'].on -and (Idx $r 'Enable Kitchen-Supervisor') -gt (Idx $r 'Unregister Tide-Yard') -and (Idx $r 'Unregister Kitchen-Supervisor') -lt 0)
    Remove-Item -LiteralPath (Join-Path $root 'backups') -Recurse -Force
    $w = New-World; $w.tamper = { param($x) $x -replace 'PT5M', 'PT72H' }
    $r = Run $w
    Check 'the new export differs (a setting changed): exit 1, shows the diff, Tide-Yard removed, Kitchen-Supervisor never switched off' ($r.code -eq 1 -and $r.out -match 'differs from the old one' -and $r.out -match '\+\s+\d+:\s+<ExecutionTimeLimit>PT72H' -and -not $w.tasks['Tide-Yard'] -and $w.tasks['Kitchen-Supervisor'].on -and (Idx $r 'Disable Kitchen-Supervisor') -lt 0)
    Remove-Item -LiteralPath (Join-Path $root 'backups') -Recurse -Force
    $w = New-World; $w.masks['Tide-Yard'] = 0x120089
    $r = Run $w
    Check 'your rights on the new task are less: exit 1, put back' ($r.code -eq 1 -and $r.out -match 'your rights on Tide-Yard \(0x120089\) differ' -and -not $w.tasks['Tide-Yard'] -and $w.tasks['Kitchen-Supervisor'].on)
    Remove-Item -LiteralPath (Join-Path $root 'backups') -Recurse -Force

    # 8. a task that is off on purpose stays off under its new name
    $w = New-World; $w.tasks['Kitchen-Chores'].xml = New-TaskXml 'Kitchen-Chores' -Off; $w.tasks['Kitchen-Chores'].on = $false
    $r = Run $w
    Check 'a disabled task: renamed, still off, never switched on' ($r.code -eq 0 -and $w.tasks['Tide-Cleanup'] -and -not $w.tasks['Tide-Cleanup'].on -and (Idx $r 'Enable Tide-Cleanup') -lt 0 -and (Idx $r 'Disable Kitchen-Chores') -lt 0)
    Remove-Item -LiteralPath (Join-Path $root 'backups') -Recurse -Force

    # 9. refusals: nothing changed, exit 2
    $refuse = @(
        @{ n = 'an admin PowerShell'; set = { param($w) $w.who.Elevated = $true }; rx = 'runs as administrator: run it from a normal PowerShell' }
        @{ n = 'no full access to an old task'; set = { param($w) $w.masks['Kitchen-Pass'] = 0x120089 }; rx = 'do not have full access to Kitchen-Pass' }
        @{ n = 'no right to add tasks'; set = { param($w) $w.who.RootMask = 0x120089 }; rx = 'may not add tasks' }
        @{ n = 'a task that runs as someone else'; set = { param($w) $w.tasks['Kitchen-Chores'].xml = $w.tasks['Kitchen-Chores'].xml -replace [regex]::Escape($me), 'S-1-5-18' }; rx = 'would run as S-1-5-18, not as you' }
        @{ n = 'both names registered'; set = { param($w) $w.tasks['Tide-Yard'] = @{ xml = (New-TaskXml 'Tide-Yard'); on = $false; engine = $null } }; rx = 'both Kitchen-Supervisor and Tide-Yard are registered' }
    )
    foreach ($c in $refuse) {
        $w = New-World; & $c.set $w; $before = Snap $w
        $r = Run $w
        Check "refuses $($c.n): exit 2, REFUSED, no change, no backup" ($r.code -eq 2 -and $r.out -match 'REFUSED, nothing changed' -and $r.out -match $c.rx -and (Snap $w) -eq $before -and @($r.calls | Where-Object { $_ -match $mutating }).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $root 'backups')))
    }
    $w = New-World; Remove-Item -LiteralPath (Join-Path $root 'PAUSED')
    $r = Run $w
    Check 'refuses while the Yard is not paused (says how to pause)' ($r.code -eq 2 -and $r.out -match 'kitchen\\kitchen\.ps1 pause' -and @($r.calls | Where-Object { $_ -match $mutating }).Count -eq 0)
    Set-Content -LiteralPath (Join-Path $root 'PAUSED') -Value 'test'
    '{"id":"J9","status":"running","run":null}' | Set-Content -LiteralPath (Join-Path $root 'jobs\J9.json')
    $w = New-World; $r = Run $w
    Check 'refuses while an order is running' ($r.code -eq 2 -and $r.out -match 'an order is running \(J9' -and @($r.calls | Where-Object { $_ -match $mutating }).Count -eq 0)
    '{"id":"J9","status":"pending","run":{"pid":4000}}' | Set-Content -LiteralPath (Join-Path $root 'jobs\J9.json')
    $w = New-World; $r = Run $w
    Check 'refuses while an order''s process is alive' ($r.code -eq 2 -and $r.out -match 'pid 4000 is alive')
    Remove-Item -LiteralPath (Join-Path $root 'jobs\J9.json')
    $w = New-World; $w.who.Elevated = $true; $r = Run $w -DryRun
    Check 'dry run as admin: still prints the steps, then says a real run would refuse (exit 2)' ($r.code -eq 2 -and $r.out -match 'would: register Tide-Yard' -and $r.out -match 'a real run would REFUSE' -and @($r.calls | Where-Object { $_ -match $mutating }).Count -eq 0)
    $w = New-World; $w.tasks.Remove('Kitchen-Pass'); $w.tasks['Tide-Board'] = @{ xml = (New-TaskXml 'Tide-Board' -Board); on = $true; engine = $null }
    $r = Run $w -Undo
    Check 'undo with no backup: refuses, nothing changed' ($r.code -eq 2 -and $r.out -match 'no backup of Kitchen-Pass' -and @($r.calls | Where-Object { $_ -match $mutating }).Count -eq 0)

    # 10. undo after a run that stopped midway (both names registered): the new name goes, the old one is on as its backup says
    $w = New-World; $null = Run $w
    $w.tasks['Kitchen-Chores'] = @{ xml = (New-TaskXml 'Kitchen-Chores'); on = $false; engine = $null }; $w.calls.Clear()
    $u = Run $w -Undo
    Check 'undo with both names: Tide-Cleanup unregistered, Kitchen-Chores switched on, the others restored' ($u.code -eq 0 -and -not $w.tasks['Tide-Cleanup'] -and $w.tasks['Kitchen-Chores'].on -and (Idx $u 'Register Kitchen-Chores') -lt 0 -and $w.tasks['Kitchen-Supervisor'] -and $w.tasks['Kitchen-Pass'] -and -not $w.tasks['Tide-Yard'] -and -not $w.tasks['Tide-Board'])
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Rename-tasks tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
