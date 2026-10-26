# (Re)registers the kitchen's three scheduled tasks from the repo, so they can be rebuilt on a new PC and never depend on a by-hand setup:
#   Kitchen-Supervisor  one supervisor tick a minute: pwsh kitchen\kitchen.ps1 tick -Quiet (5 min limit, no overlapping runs)
#   Kitchen-Chores      the housekeeping every 2 minutes: pwsh kitchen\kitchen.ps1 chores -Quiet (10 min limit, no overlapping runs;
#                       TARGET W2: until it runs, the supervisor tick does the chores itself, so installing it is safe at any time)
#   Kitchen-Pass        the Chef server at sign-in: wscript pass-app\start-hidden.vbs (no time limit, restarted up to 5 times a minute apart)
# Same triggers and settings as the tasks Jordan set up on 2026-10-13. The difference: pwsh is the UPDATE-PROOF app alias found by
# scripts/stable-pwsh.ps1 (%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe, resolved when this runs), never the versioned Store folder
# that the 7.6.6 -> 7.6.7 update deleted (every tick then failed 0x80070002 and the kitchen stopped for 2+ days).
# HEADLESS: the tick and the chores run through wscript.exe //B //NoLogo scripts\run-hidden.vbs "<pwsh>" ... (scripts/headless-task-lib.ps1),
# so no console ever flashes (pwsh -WindowStyle Hidden alone still flashed one every minute) and Last Run Result is still pwsh's own exit code.
# The Board stays on wscript.exe: a GUI program with no console, and start-hidden.vbs starts the server hidden, so nothing flashes.
#
#   install-tasks.ps1 -WhatIf               prints what it would register and changes nothing (always run this first)
#   install-tasks.ps1                       registers all three tasks as Jordan, running only while he is signed in (as today)
#   install-tasks.ps1 -RunBeforeSignIn      opt-in, see below
#   install-tasks.ps1 -Only Kitchen-Chores  just one of them (Kitchen-Chores alone is the W2 tap)
#
# NAMES: scripts/task-names.json lists each task's [old, new] names (Kitchen-Supervisor/Tide-Yard, Kitchen-Chores/Tide-Cleanup,
# Kitchen-Pass/Tide-Board). -Only takes either name. With no name given, each task keeps the name it is registered under now (the
# newest listed one that exists), else the old name. The rename itself is S4, Jordan's tap. It refuses (exit 2, nothing registered)
# to register a task under one name while another name of the same task is registered, so a task never runs twice.
#
# Changing scheduled tasks is Jordan's call: run it yourself (Claude and the cooks only ever run -WhatIf). Mind the LIVE file in the
# kitchen folder: with it, a repaired supervisor turns the AI cooks, autopilot and standing orders back on at the next minute. A task that
# is Disabled now stays Disabled after re-registering (a deliberate stop is kept); 'kitchen.ps1 pause' is the softer way to stop ticks.
#
# RUNNING BEFORE SIGN-IN (after a Windows Update reboot at 2 am, Chef and the kitchen stay down until someone signs in at the PC):
#   A task runs with nobody signed in only when Windows can start it as Jordan without him: the task must store his Windows password
#   (LogonType Password). -RunBeforeSignIn does that and adds an at-startup trigger to Kitchen-Pass. What it needs:
#   - Jordan types his Windows account password (for a Microsoft account, the account password, not the PIN) into the prompt. This
#     script never saves or prints it; Windows keeps it in the task scheduler's protected store. Changing that password later breaks both
#     tasks until this is run again (they fail with 'logon failure').
#   - 'Log on as a batch job' for his account (Windows grants it when a task is saved with a password; a work policy could deny it).
#   - Not S4U ('do not store password'): S4U runs without network credentials and without DPAPI, so the claude/agy cooks that sign in
#     with saved Windows credentials would fail. A stored password keeps those working.
#   - Before sign-in there is no desktop: the watchdog cannot open the Tailscale tray app (the Tailscale service itself runs as a service
#     and is unaffected), and nothing ever shows a window.
param(
    [switch]$WhatIf, [switch]$RunBeforeSignIn,
    [string[]]$Only,   # task names, old or new (scripts/task-names.json); default: all three
    [string]$Repo = (Split-Path $PSScriptRoot -Parent),
    [string[]]$PwshCandidates,   # tests: stand-in candidates for scripts/stable-pwsh.ps1
    [string]$TaskNamesPath = (Join-Path $PSScriptRoot 'task-names.json'),
    [string[]]$TestRegistered   # tests: stand-in for the task names registered on this PC (the scheduler is then not read)
)
$ErrorActionPreference = 'Stop'
$Repo = [IO.Path]::GetFullPath($Repo)
$kitchenPs = Join-Path $Repo 'kitchen\kitchen.ps1'; $vbs = Join-Path $Repo 'pass-app\start-hidden.vbs'
foreach ($f in $kitchenPs, $vbs) { if (-not (Test-Path -LiteralPath $f)) { Write-Output "ERROR: $f is missing; refusing"; exit 2 } }
. (Join-Path $PSScriptRoot 'headless-task-lib.ps1')
$sp = @{}; if ($PwshCandidates) { $sp.Candidates = $PwshCandidates }
$pwsh = & (Join-Path $PSScriptRoot 'stable-pwsh.ps1') @sp 2>$null
if ($LASTEXITCODE -ne 0 -or -not $pwsh) { Write-Output 'ERROR: no update-proof pwsh.exe found (only a version-pinned Store path); nothing registered'; exit 1 }
$me = "$env:USERDOMAIN\$env:USERNAME"
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }

$useStub = $PSBoundParameters.ContainsKey('TestRegistered')
# 'a,b' arrives as one string through pwsh -File: split it
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$TestRegistered = @($TestRegistered | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# read-only: is it there, is it disabled, whose sign-in starts it
function Get-Task([string]$n) {
    if ($script:useStub) { if ($n -in @($script:TestRegistered)) { [pscustomobject]@{ TaskName = $n; State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'test' }); Triggers = @() } }; return }
    Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
}
$roles = [ordered]@{ supervisor = @('Kitchen-Supervisor'); chores = @('Kitchen-Chores'); board = @('Kitchen-Pass') }
if (Test-Path -LiteralPath $TaskNamesPath) {
    $tn = try { Get-Content -LiteralPath $TaskNamesPath -Raw | ConvertFrom-Json } catch { Write-Output "ERROR: task-names.json is not valid JSON: $TaskNamesPath; nothing registered"; exit 2 }
    foreach ($r in @($roles.Keys)) {
        $n = @($tn.$r | Where-Object { $_ -is [string] -and $_.Trim() })
        if (-not $n.Count -or $n[0] -ne $roles[$r][0]) { Write-Output "ERROR: task-names.json must list $r as [$($roles[$r][0]), new name]: $TaskNamesPath; nothing registered"; exit 2 }
        $roles[$r] = $n
    }
}
$roleOf = @{}; foreach ($r in $roles.Keys) { foreach ($n in $roles[$r]) { $roleOf[$n] = $r } }
if (-not $Only) { $Only = foreach ($r in $roles.Keys) { $n = $roles[$r]; $pick = $n[0]; for ($i = $n.Count - 1; $i -gt 0; $i--) { if (Get-Task $n[$i]) { $pick = $n[$i]; break } }; $pick } }
$bad = @($Only | Where-Object { -not $roleOf.ContainsKey($_) })
if ($bad.Count) { Write-Output "ERROR: unknown task name $($bad -join ', ') (known: $(@($roleOf.Keys | Sort-Object) -join ', ')); nothing registered"; exit 2 }
$twice = @($Only | Group-Object { $roleOf[$_] } | Where-Object Count -gt 1)
if ($twice.Count) { Write-Output "ERROR: $(($twice | ForEach-Object { $_.Group -join ' and ' }) -join '; ') are the same task; give one name per task; nothing registered"; exit 2 }
foreach ($name in $Only) {
    $other = @($roles[$roleOf[$name]] | Where-Object { $_ -ne $name -and (Get-Task $_) })
    if ($other.Count) { Write-Output "ERROR: $($other -join ', ') is registered, so registering $name would run the same task twice; the rename is S4, Jordan's tap; nothing registered"; exit 2 }
}

$plans = foreach ($name in $Only) {
    $old = Get-Task $name
    if ($roleOf[$name] -eq 'supervisor') {
        $h = Get-HeadlessAction $pwsh "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$kitchenPs`" tick -Quiet"
        [pscustomobject]@{ Name = $name; Old = $old; Execute = $h.Execute; Args = $h.Args; Dir = (Split-Path $kitchenPs)
            Desc = "Jordan's Kitchen: one supervisor tick per minute. Off: Unregister-ScheduledTask $name"
            Triggers = { @(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)) }   # no duration = forever
            TriggerText = 'every minute, forever'
            Settings = { New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) } }
    } elseif ($roleOf[$name] -eq 'chores') {
        $h = Get-HeadlessAction $pwsh "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$kitchenPs`" chores -Quiet"
        [pscustomobject]@{ Name = $name; Old = $old; Execute = $h.Execute; Args = $h.Args; Dir = (Split-Path $kitchenPs)
            Desc = "Jordan's Kitchen: the housekeeping (board, ledger, doctor, CI looks, ideas) every 2 minutes, off the supervisor's path. Off: Unregister-ScheduledTask $name"
            Triggers = { @(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)) }
            TriggerText = 'every 2 minutes, forever'
            Settings = { New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) } }
    } else {
        # the sign-in trigger keeps the account the current task names (it is Jordan's own sign-in); else the account running this
        $logonUser = if ($old) { @($old.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $_.UserId } | ForEach-Object UserId)[0] } else { $null }
        if (-not $logonUser) { $logonUser = $me }
        [pscustomobject]@{ Name = $name; Old = $old; Execute = (Join-Path $env:SystemRoot 'System32\wscript.exe'); Args = "`"$vbs`""; Dir = (Split-Path $vbs)
            Desc = "The Board: Jordan's private app on 127.0.0.1:7878 (+Tailscale). Off: Unregister-ScheduledTask $name"
            Triggers = [scriptblock]::Create("@(New-ScheduledTaskTrigger -AtLogOn -User '$($logonUser -replace "'", "''")')" + $(if ($RunBeforeSignIn) { ' + @(New-ScheduledTaskTrigger -AtStartup)' } else { '' }))
            TriggerText = "at sign-in of $logonUser$(if ($RunBeforeSignIn) { ', and at startup' })"
            Settings = { New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) } }
    }
}
$who = if ($RunBeforeSignIn) { "$me with a stored password (runs before sign-in)" } else { "$me, only while signed in (Interactive)" }
# build every definition first (plain objects, nothing registered), so a bad trigger or setting fails here, even under -WhatIf;
# the printed line is the built action itself, so it shows exactly what would be registered
foreach ($p in $plans) {
    $a = (New-ScheduledTask -Action (New-ScheduledTaskAction -Execute $p.Execute -Argument $p.Args -WorkingDirectory $p.Dir) -Trigger (& $p.Triggers) -Settings (& $p.Settings) -Description $p.Desc).Actions[0]
    $now = if ($p.Old) { "now: $($p.Old.Actions[0].Execute) [$($p.Old.State)]" } else { 'now: not registered' }
    Write-Output "$($p.Name): $($a.Execute) $($a.Arguments)"
    Write-Output "    start in $($p.Dir); $($p.TriggerText); as $who; $now$(if ($p.Old -and $p.Old.State -eq 'Disabled') { '; stays Disabled' })"
}
if (Test-Path -LiteralPath (Join-Path $kroot 'LIVE')) { Write-Output 'NOTE: the LIVE file exists: a working supervisor turns the AI cooks, autopilot and standing orders on at the next minute' }
if ($WhatIf) { Write-Output 'WHATIF: nothing registered (run without -WhatIf to do it; that is Jordan''s call)'; exit 0 }

$cred = $null
if ($RunBeforeSignIn) { $cred = Get-Credential -UserName $me -Message 'Your Windows password, so the kitchen tasks can start before you sign in (kept by Windows, not by this script)'; if (-not $cred) { Write-Output 'cancelled; nothing registered'; exit 1 } }
foreach ($p in $plans) {
    $action = New-ScheduledTaskAction -Execute $p.Execute -Argument $p.Args -WorkingDirectory $p.Dir
    $reg = @{ TaskName = $p.Name; Action = $action; Trigger = (& $p.Triggers); Settings = (& $p.Settings); Description = $p.Desc; Force = $true }
    if ($cred) { $reg.User = $cred.UserName; $reg.Password = $cred.GetNetworkCredential().Password; $reg.RunLevel = 'Limited' }
    else { $reg.Principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited }
    Register-ScheduledTask @reg | Out-Null
    if ($p.Old -and $p.Old.State -eq 'Disabled') { Disable-ScheduledTask -TaskName $p.Name | Out-Null }
    Write-Output "registered $($p.Name)"
}
$cred = $null
