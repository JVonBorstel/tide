# Renames the Yard's three scheduled tasks (Tide rename, stage S4, Jordan's tap). The names come from scripts/task-names.json [old, new]:
#   Kitchen-Supervisor -> Tide-Yard      Kitchen-Chores -> Tide-Cleanup      Kitchen-Pass -> Tide-Board
# Rig-RGB-On and Rig-RGB-Off are not touched.
#
#   pwsh scripts/rename-tasks.ps1 -DryRun        prints every step and the XML diff, changes nothing (run this first)
#   pwsh scripts/rename-tasks.ps1                does the rename (Jordan's tap)
#   pwsh scripts/rename-tasks.ps1 -Undo          puts the old names back from the backups (-Undo -DryRun shows how)
#
# RUN IT FROM A NORMAL POWERSHELL, NOT "Run as administrator". Admin is not needed, and the script checks this before it changes
# anything: you have full access to the three tasks, any signed-in user may add a task to the scheduler's root folder, and each task
# runs as you. An admin PowerShell is refused, because the rights check has to be made as the plain you: that is the account the Yard's
# watchdog runs as when it restarts the Board, so the new tasks must give the plain you the same rights the old ones do.
#
# For each task, in order (supervisor, chores, the Board):
#   0. before anything changes, each old task's own XML (Export-ScheduledTask) is saved to <Yard state>\backups\tasks-s4\<old name>.xml
#   1. the new name is registered from that same XML (only the URI changes), switched off for now, so the two never run side by side
#   2. its export is compared with the old one: everything except the URI and the on/off switch must be equal (settings, triggers,
#      principal, actions), and your rights on it must equal your rights on the old task
#   3. the old task is switched off (and, for a tick task, the script waits until no run of it is in progress)
#   4. the Board only: the old task is stopped and the script waits until port 7878 is free (if the old Board server outlives its task,
#      that one node process, and only it, is stopped)
#   5. the new task is switched on (a task that was off on purpose stays off); the Board only: it is started, and
#      http://127.0.0.1:7878/api/health must answer and the port must be held by the new task's own process
#   6. the old task is unregistered
# A failure in steps 1-5 undoes that task's steps: the new name is removed and the old task is switched on (and the Board restarted)
# again. Tasks already done stay done; running the script again finishes the rest. Running it again when all three have their new names
# does nothing.
#
# Before: pause the Yard (pwsh kitchen\kitchen.ps1 pause). It refuses while the Yard is not paused or an order is running.
# After: pwsh kitchen\kitchen.ps1 resume. Changing scheduled tasks is Jordan's call: sessions and cooks only ever run -DryRun.
# Exit: 0 done (or nothing to do), 1 a step failed (that task was put back), 2 refused (nothing changed).
param(
    [switch]$DryRun, [switch]$Undo,
    [string]$TaskNamesPath = (Join-Path $PSScriptRoot 'task-names.json'),
    [string]$StateRoot = $(if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }),
    [int]$Port = 7878, [int]$PortWaitSec = 30, [int]$HealthWaitSec = 60, [int]$IdleWaitSec = 90,
    [hashtable]$Ops   # tests only: stand-ins for every scheduler, process and network call (New-RealOps lists them)
)
$ErrorActionPreference = 'Stop'
$FullAccess = 0x1F01FF   # FILE_ALL_ACCESS, what "FA" in a task's SDDL means: the rights you hold on the Yard's tasks today
$AddFile = 0x2           # FILE_ADD_FILE on the root folder: adding a task there
$TaskNs = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
$BackupDir = Join-Path $StateRoot 'backups\tasks-s4'
if ($Port -lt 1 -or $PortWaitSec -lt 1 -or $HealthWaitSec -lt 1 -or $IdleWaitSec -lt 1) { Write-Host 'ERROR: -Port and the waits must be positive; nothing changed'; exit 2 }

function Say([string]$m) { Write-Host $m }

# ---- the real calls (read-only ones are used by -DryRun too; the changing ones only by a real run) ----
function Get-MyMask([string]$Sddl) {
    # the rights this token holds under a DACL: allow ACEs for its user or an enabled group (deny-only groups such as the
    # Administrators group of a non-elevated token do not count), minus deny ACEs; inherit-only ACEs do not apply to the object itself
    $me = [Security.Principal.WindowsIdentity]::GetCurrent(); $pr = [Security.Principal.WindowsPrincipal]::new($me)
    $sd = [Security.AccessControl.RawSecurityDescriptor]::new($Sddl); $allow = 0; $deny = 0
    foreach ($a in @($sd.DiscretionaryAcl)) {
        if ($a.AceFlags -band [Security.AccessControl.AceFlags]::InheritOnly) { continue }
        if (-not ($a.SecurityIdentifier -eq $me.User -or $pr.IsInRole($a.SecurityIdentifier))) { continue }
        if ($a.AceQualifier -eq 'AccessAllowed') { $allow = $allow -bor $a.AccessMask } elseif ($a.AceQualifier -eq 'AccessDenied') { $deny = $deny -bor $a.AccessMask }
    }
    $allow -band (-bnot $deny)
}
function Get-SchedulerFolder { $s = New-Object -ComObject Schedule.Service; $s.Connect(); $s.GetFolder('\') }
function New-RealOps {
    @{
        Get        = { param($n) $t = Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue; if ($t) { [pscustomobject]@{ Name = $t.TaskName; State = [string]$t.State } } }
        Export     = { param($n) [string](Export-ScheduledTask -TaskName $n -TaskPath '\') }
        Register   = { param($n, $xml) Register-ScheduledTask -TaskName $n -TaskPath '\' -Xml $xml | Out-Null }
        Enable     = { param($n) Enable-ScheduledTask -TaskName $n -TaskPath '\' | Out-Null }
        Disable    = { param($n) Disable-ScheduledTask -TaskName $n -TaskPath '\' | Out-Null }
        Stop       = { param($n) Stop-ScheduledTask -TaskName $n -TaskPath '\' }
        Start      = { param($n) Start-ScheduledTask -TaskName $n -TaskPath '\' }
        Unregister = { param($n) Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false }
        # the running instance's process: for an Exec action that is the action's own process (here wscript.exe, the node server's parent)
        EnginePid  = { param($n) $t = try { (Get-SchedulerFolder).GetTask($n) } catch { $null }; if ($t) { @($t.GetInstances(0) | ForEach-Object { [int]$_.EnginePID })[0] } }
        PortPid    = { param($p) @(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.OwningProcess })[0] }
        Proc       = { param($id) $p = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$id)" -ErrorAction SilentlyContinue; if ($p) { [pscustomobject]@{ Id = [int]$p.ProcessId; Name = $p.Name; ParentId = [int]$p.ParentProcessId; CommandLine = [string]$p.CommandLine } } }
        Kill       = { param($id) Stop-Process -Id $id -Force }
        Health     = { param($p) try { Invoke-RestMethod "http://127.0.0.1:$p/api/health" -TimeoutSec 3 } catch { $null } }
        Sleep      = { param($ms) Start-Sleep -Milliseconds $ms }
        Who        = {
            $me = [Security.Principal.WindowsIdentity]::GetCurrent(); $sddl = (Get-SchedulerFolder).GetSecurityDescriptor(4)
            [pscustomobject]@{ Elevated = ([Security.Principal.WindowsPrincipal]::new($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                Sid = $me.User.Value; Name = $me.Name; RootMask = (Get-MyMask $sddl); RootSddl = $sddl }
        }
        TaskMask   = { param($n) $t = try { (Get-SchedulerFolder).GetTask($n) } catch { $null }; if ($t) { Get-MyMask $t.GetSecurityDescriptor(4) } }
    }
}

# ---- task XML ----
function Read-TaskXml([string]$Xml) {
    $d = [xml]::new(); $d.LoadXml($Xml)
    $ns = [Xml.XmlNamespaceManager]::new($d.NameTable); $ns.AddNamespace('t', $TaskNs)
    [pscustomobject]@{ Doc = $d; Ns = $ns }
}
# what has to match between the old and the new task: everything but its own URI and its on/off switch, printed one element a line
function Get-NormalXml([string]$Xml) {
    $x = Read-TaskXml $Xml
    foreach ($n in @($x.Doc.SelectNodes('/t:Task/t:RegistrationInfo/t:URI | /t:Task/t:Settings/t:Enabled', $x.Ns))) { [void]$n.ParentNode.RemoveChild($n) }
    $sw = [IO.StringWriter]::new(); $ws = [Xml.XmlWriterSettings]::new(); $ws.Indent = $true; $ws.OmitXmlDeclaration = $true
    $w = [Xml.XmlWriter]::Create($sw, $ws); $x.Doc.DocumentElement.WriteTo($w); $w.Flush(); $sw.ToString()
}
function Test-XmlEnabled([string]$Xml) { $x = Read-TaskXml $Xml; $e = $x.Doc.SelectSingleNode('/t:Task/t:Settings/t:Enabled', $x.Ns); -not ($e -and $e.InnerText.Trim() -eq 'false') }
function Get-XmlPrincipal([string]$Xml) {
    $x = Read-TaskXml $Xml; $p = @($x.Doc.SelectNodes('/t:Task/t:Principals/t:Principal', $x.Ns))
    $v = { param($name) if ($p.Count -eq 1) { $e = $p[0].SelectSingleNode("t:$name", $x.Ns); if ($e) { $e.InnerText.Trim() } } }
    [pscustomobject]@{ Count = $p.Count; UserId = (& $v 'UserId'); LogonType = (& $v 'LogonType'); RunLevel = (& $v 'RunLevel') }
}
# the XML the new name is registered from: the old one with its own URI, switched off (Enabled sits just before IdleSettings, where
# Windows itself writes it in an exported disabled task)
function New-TargetXml([string]$Xml, [string]$Name) {
    $out = [regex]::new('<URI>[^<]*</URI>').Replace($Xml, "<URI>\$Name</URI>", 1)
    if ($out -match '<Settings>(?:(?!</Settings>)[\s\S])*<Enabled>') {
        $out = [regex]::new('(<Settings>(?:(?!</Settings>)[\s\S])*?)<Enabled>[^<]*</Enabled>').Replace($out, { param($m) $m.Groups[1].Value + '<Enabled>false</Enabled>' }, 1)
    } elseif ($out -match '(\r?\n)([ \t]*)<IdleSettings>') {
        $out = [regex]::new('(\r?\n)([ \t]*)<IdleSettings>').Replace($out, { param($m) "$($m.Groups[1].Value)$($m.Groups[2].Value)<Enabled>false</Enabled>$($m.Groups[1].Value)$($m.Groups[2].Value)<IdleSettings>" }, 1)
    } else {
        $out = [regex]::new('</Settings>').Replace($out, '<Enabled>false</Enabled></Settings>', 1)
    }
    $x = Read-TaskXml $out
    $uri = $x.Doc.SelectSingleNode('/t:Task/t:RegistrationInfo/t:URI', $x.Ns)
    if ((Test-XmlEnabled $out) -or ($uri -and $uri.InnerText -ne "\$Name") -or (Get-NormalXml $out) -ne (Get-NormalXml $Xml)) { throw "could not build the XML for $Name from the old task's XML" }
    $out
}
# a line diff (longest common subsequence), printed with line numbers of the old (-) and new (+) side
function Show-Diff([string]$A, [string]$B, [string]$LabelA, [string]$LabelB) {
    $x = @($A -split '\r?\n'); $y = @($B -split '\r?\n'); $n = $x.Count; $m = $y.Count
    $L = New-Object 'int[,]' ($n + 1), ($m + 1)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) { $L[$i, $j] = if ($x[$i] -ceq $y[$j]) { $L[($i + 1), ($j + 1)] + 1 } else { [Math]::Max($L[($i + 1), $j], $L[$i, ($j + 1)]) } }
    }
    Say "    XML diff: - $LabelA, + $LabelB"
    $i = 0; $j = 0; $c = 0
    while ($i -lt $n -or $j -lt $m) {
        if ($i -lt $n -and $j -lt $m -and $x[$i] -ceq $y[$j]) { $i++; $j++ }
        elseif ($i -lt $n -and ($j -ge $m -or $L[($i + 1), $j] -ge $L[$i, ($j + 1)])) { Say ("    - {0,3}: {1}" -f ($i + 1), $x[$i].TrimEnd()); $i++; $c++ }
        else { Say ("    + {0,3}: {1}" -f ($j + 1), $y[$j].TrimEnd()); $j++; $c++ }
    }
    if (-not $c) { Say '    (identical)' }
}

# ---- small helpers ----
function Read-Pairs([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "task-names.json is missing: $Path" }
    $tn = try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { throw "task-names.json is not valid JSON: $Path" }
    foreach ($role in 'supervisor', 'chores', 'board') {
        $n = @($tn.$role | Where-Object { $_ -is [string] -and $_.Trim() })
        if ($n.Count -ne 2 -or $n[0] -eq $n[1]) { throw "task-names.json must list $role as [old name, new name]: $Path" }
        [pscustomobject]@{ Role = $role; Old = $n[0]; New = $n[1]; Board = ($role -eq 'board') }
    }
}
function Wait-Until([scriptblock]$Cond, [int]$Sec) {
    for ($k = 0; $k -le $Sec * 2; $k++) { if (& $Cond) { return $true }; & $Ops.Sleep 500 }
    $false
}
# one change: always printed; done only in a real run
function Step([string]$What, [scriptblock]$Do) {
    if ($DryRun) { Say "    would: $What"; return }
    Say "    $What"
    & $Do
}
function Get-LiveJobs {
    $dir = Join-Path $StateRoot 'jobs'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'J*.json' -File)) {
        $j = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { $null }
        if (-not $j) { continue }
        $alive = [bool]($j.run -and $j.run.pid -and (& $Ops.Proc ([int]$j.run.pid)))
        if ($j.status -eq 'running' -or $alive) { "$($j.id) (status $($j.status)$(if ($alive) { ", pid $($j.run.pid) is alive" }))" }
    }
}
function Get-PortText {
    $lp = & $Ops.PortPid $Port
    if (-not $lp) { return "port $Port is free" }
    $pr = & $Ops.Proc $lp
    "port $Port is held by $(if ($pr) { "$($pr.Name) pid $lp (parent pid $($pr.ParentId))" } else { "pid $lp" })"
}

# ---- what to do: one item per task that is not where it should be, and the reasons a real run would refuse ----
function Get-Plan($Pairs) {
    $items = [Collections.Generic.List[object]]::new(); $block = [Collections.Generic.List[string]]::new(); $done = [Collections.Generic.List[string]]::new()
    foreach ($p in $Pairs) {
        $o = & $Ops.Get $p.Old; $n = & $Ops.Get $p.New
        $bk = Join-Path $BackupDir "$($p.Old).xml"; $hasBk = Test-Path -LiteralPath $bk
        if (-not $o -and -not $n) { $block.Add("neither $($p.Old) nor $($p.New) is registered"); continue }
        if (-not $Undo) {
            if ($n -and -not $o) { $done.Add("$($p.New) (already renamed)"); continue }
            if ($n) { $block.Add("both $($p.Old) and $($p.New) are registered (an earlier run stopped midway?): run -Undo first, then this again"); continue }
            $items.Add([pscustomobject]@{ Kind = 'swap'; From = $p.Old; To = $p.New; Board = $p.Board; Src = (& $Ops.Export $p.Old); SrcLabel = "$($p.Old), exported now" })
            continue
        }
        if ($o -and -not $n) { $done.Add("$($p.Old) (already the old name)"); continue }
        if (-not $hasBk) { $block.Add("no backup of $($p.Old) at $bk, so -Undo cannot rebuild it"); continue }
        $src = Get-Content -LiteralPath $bk -Raw
        $kind = if ($o) { 'drop' } else { 'swap' }
        $items.Add([pscustomobject]@{ Kind = $kind; From = $p.New; To = $p.Old; Board = $p.Board; Src = $src; SrcLabel = "the backup $bk" })
    }
    [pscustomobject]@{ Items = $items; Blockers = $block; Done = $done }
}
function Test-Gates($Plan) {
    $b = $Plan.Blockers
    $who = & $Ops.Who
    Say "  You: $($who.Name) ($($who.Sid)), $(if ($who.Elevated) { 'ADMIN (elevated)' } else { 'not admin' })"
    if ($who.Elevated) { $b.Add('this PowerShell runs as administrator: run it from a normal PowerShell (the rights check must be made as the plain you, the account the Yard''s watchdog runs as)') }
    $needRoot = @($Plan.Items | Where-Object Kind -eq 'swap').Count -gt 0
    Say ("  Root folder \: you may add tasks: {0} (rights 0x{1:X})" -f $(if (($who.RootMask -band $AddFile) -eq $AddFile) { 'yes' } else { 'NO' }), [int]$who.RootMask)
    if ($needRoot -and ($who.RootMask -band $AddFile) -ne $AddFile) { $b.Add("you may not add tasks to the scheduler's root folder as a normal user (rights 0x$('{0:X}' -f [int]$who.RootMask)); this script does not handle that") }
    foreach ($it in $Plan.Items) {
        $mask = & $Ops.TaskMask $it.From
        Say ("  {0}: your rights 0x{1:X} ({2})" -f $it.From, [int]$mask, $(if ($mask -eq $FullAccess) { 'full access' } else { 'NOT full access' }))
        if ($mask -ne $FullAccess) { $b.Add("you do not have full access to $($it.From) as a normal user; this script does not handle that") }
        $pr = Get-XmlPrincipal $it.Src
        $mine = $pr.Count -eq 1 -and ($pr.UserId -eq $who.Sid -or $pr.UserId -eq $who.Name)
        Say "  $($it.To) will run as: $($pr.UserId), $($pr.LogonType)$(if ($pr.RunLevel) { ", $($pr.RunLevel)" })$(if ($mine) { ' (you)' })"
        if (-not $mine) { $b.Add("$($it.To) would run as $($pr.UserId), not as you: registering it needs that account's password or admin; not handled") }
        elseif ($pr.LogonType -in 'Password', 'S4U' -or $pr.RunLevel -eq 'HighestAvailable') { $b.Add("$($it.To) needs a stored password or the highest run level ($($pr.LogonType) $($pr.RunLevel)); not handled") }
    }
    $paused = Test-Path -LiteralPath (Join-Path $StateRoot 'PAUSED')
    Say "  The Yard: $(if ($paused) { 'paused' } else { 'NOT paused' }) ($StateRoot)"
    if (-not $paused) { $b.Add('the Yard is not paused: run pwsh kitchen\kitchen.ps1 pause first (and resume after)') }
    $live = @(Get-LiveJobs)
    Say "  Running orders: $(if ($live.Count) { $live -join ', ' } else { 'none' })"
    if ($live.Count) { $b.Add("an order is running ($($live -join ', ')): wait for it to finish, or stop it, first") }
    $bi = @($Plan.Items | Where-Object Board)
    if ($bi.Count) {
        $lp = & $Ops.PortPid $Port; $pr = if ($lp) { & $Ops.Proc $lp }; $eng = & $Ops.EnginePid $bi[0].From
        $own = if ($pr -and $eng -and $pr.ParentId -eq $eng) { ", started by $($bi[0].From) (pid $eng)" } else { '' }
        Say "  The Board now: $(Get-PortText)$own$(if (& $Ops.Health $Port) { '; /api/health answers' } else { '; /api/health does not answer' })"
    }
}

# ---- the Board: the port, the health check, whose process holds the port ----
function Wait-PortFree([int]$KnownPid) {
    if (Wait-Until { -not (& $Ops.PortPid $Port) } $PortWaitSec) { Say "    port $Port is free"; return $true }
    $lp = & $Ops.PortPid $Port; $pr = & $Ops.Proc $lp
    if (-not $KnownPid -or $lp -ne $KnownPid -or -not $pr -or $pr.CommandLine -notmatch 'pass-app[\\/]server\.mjs') {
        Say "    port $Port is still held after $PortWaitSec s by $(if ($pr) { "$($pr.Name) " })pid $lp, which is not the Board server that was running: not touching it"
        return $false
    }
    Say "    the old Board server (node pid $lp) still holds port $Port after its task stopped: stopping that one process"
    & $Ops.Kill $lp
    if (Wait-Until { -not (& $Ops.PortPid $Port) } 15) { Say "    port $Port is free"; return $true }
    Say "    port $Port is still held"; $false
}
function Confirm-Board([string]$Task, $OldPid) {
    if (-not (Wait-Until { $h = & $Ops.Health $Port; [bool]($h -and $h.ok) } $HealthWaitSec)) { throw "http://127.0.0.1:$Port/api/health did not answer ok within $HealthWaitSec s" }
    $h = & $Ops.Health $Port; $lp = & $Ops.PortPid $Port; $pr = if ($lp) { & $Ops.Proc $lp }; $eng = & $Ops.EnginePid $Task
    if (-not $lp -or -not $pr -or -not $eng -or $pr.ParentId -ne $eng -or ($OldPid -and $lp -eq $OldPid)) {
        throw "port $Port is held by pid $lp (parent $(if ($pr) { $pr.ParentId })), not by a process $Task started (its process: $(if ($eng) { "pid $eng" } else { 'none' }))"
    }
    Say "    health ok (version $($h.version)); port $Port is $($pr.Name) pid $lp, started by $Task (pid $eng)"
}

# ---- one task: rename (or, for -Undo, the way back) ----
function Confirm-NewTask($St, [string]$Src) {
    $t = & $Ops.Get $St.To
    if (-not $t) { throw "$($St.To) is not registered after registering it" }
    if ($t.State -ne 'Disabled') { throw "$($St.To) is $($t.State); it should be off until $($St.From) is off" }
    $a = Get-NormalXml $Src; $b = Get-NormalXml (& $Ops.Export $St.To)
    if ($a -ne $b) { Show-Diff $a $b $St.From $St.To; throw "the new task's XML differs from the old one beyond its URI and on/off switch (Windows rewrote something)" }
    $mo = & $Ops.TaskMask $St.From; $mn = & $Ops.TaskMask $St.To
    if ($mn -ne $mo) { throw ("your rights on {0} (0x{1:X}) differ from those on {2} (0x{3:X})" -f $St.To, [int]$mn, $St.From, [int]$mo) }
    Say "    checked: $($St.To) equals $($St.From) in settings, triggers, principal and actions (only the URI and the on/off switch differ), and your rights on both are the same"
}
function Restore-From($St) {
    Say "    putting $($St.From) back:"
    $try = { param($what, $sb) try { & $sb; Say "      $what" } catch { $St.restoreFailed = $true; Say "      FAILED to $what`: $($_.Exception.Message)" } }
    if ($St.toStarted) { & $try "stop $($St.To)" { & $Ops.Stop $St.To }; [void](Wait-PortFree $(& $Ops.PortPid $Port)) }
    if ($St.registered -and (& $Ops.Get $St.To)) { & $try "unregister $($St.To)" { & $Ops.Unregister $St.To } }
    if ($St.fromOff) { & $try "switch $($St.From) on" { & $Ops.Enable $St.From } }
    if ($St.stopped) { & $try "start $($St.From)" { & $Ops.Start $St.From }; & $try 'Board health check' { Confirm-Board $St.From $null } }
    $f = & $Ops.Get $St.From
    Say "      $($St.From) is $(if ($f) { $f.State } else { 'NOT REGISTERED' })"
    if ($St.restoreFailed) { Say "      Not everything went back. The old task's XML is in $BackupDir; re-create it with: Register-ScheduledTask -TaskName $($St.From) -Xml (Get-Content '$(Join-Path $BackupDir "$($St.From).xml")' -Raw)" }
}
function Invoke-Swap($It) {
    $wasOn = Test-XmlEnabled $It.Src; $target = New-TargetXml $It.Src $It.To
    $fromState = (& $Ops.Get $It.From).State
    Say ''; Say "- $($It.From) -> $($It.To)$(if ($It.Board) { ' (the Board)' }); now $fromState; from $($It.SrcLabel)"
    Show-Diff $It.Src $target $It.SrcLabel "what $($It.To) is registered from"
    $St = @{ From = $It.From; To = $It.To; registered = $false; fromOff = $false; stopped = $false; toStarted = $false; restoreFailed = $false }
    $ok = $false; $oldPid = $null
    try {
        Step "register $($It.To) from that XML, switched off for now" { & $Ops.Register $It.To $target; $St.registered = $true }
        if ($DryRun) { Say "    would check: the export of $($It.To) equals the XML above except the URI and the on/off switch, and your rights on it equal those on $($It.From)" }
        else { Confirm-NewTask $St $It.Src }
        if ($fromState -ne 'Disabled') { Step "switch $($It.From) off" { & $Ops.Disable $It.From; $St.fromOff = $true } }
        if (-not $It.Board) {
            Step "wait until no run of $($It.From) is in progress (up to $IdleWaitSec s)" { if (-not (Wait-Until { -not (& $Ops.EnginePid $It.From) } $IdleWaitSec)) { throw "$($It.From) is still running after $IdleWaitSec s" } }
        } else {
            $oldPid = & $Ops.PortPid $Port
            Say "    now: $(Get-PortText)"
            Step "stop $($It.From)" { & $Ops.Stop $It.From; $St.stopped = $true }
            Step "wait until port $Port is free (up to $PortWaitSec s)" { if (-not (Wait-PortFree $oldPid)) { throw "port $Port did not come free" } }
        }
        if ($wasOn) { Step "switch $($It.To) on" { & $Ops.Enable $It.To } } else { Say "    $($It.To) stays off: $($It.From) was off on purpose" }
        if ($It.Board -and $wasOn) {
            Step "start $($It.To)" { & $Ops.Start $It.To; $St.toStarted = $true }
            Step "health check http://127.0.0.1:$Port/api/health (up to $HealthWaitSec s) and that the port is held by $($It.To)'s own process" { Confirm-Board $It.To $oldPid }
        }
        $ok = $true
    } catch { Say "    FAILED: $($_.Exception.Message)" }
    finally { if (-not $ok -and -not $DryRun) { Restore-From $St } }
    if (-not $ok) { return $false }
    try { Step "unregister $($It.From)" { & $Ops.Unregister $It.From } }
    catch { Say "    FAILED to unregister $($It.From): $($_.Exception.Message). $($It.To) works and $($It.From) is off; finish by hand: Unregister-ScheduledTask -TaskName $($It.From) -Confirm:`$false"; return $false }
    if (-not $DryRun) { $t = & $Ops.Get $It.To; Say "    done: $($It.To) is $($t.State); $($It.From) is $(if (& $Ops.Get $It.From) { 'STILL registered' } else { 'gone' })" }
    $true
}
# -Undo when both names are registered (a run that stopped midway): keep the old name as its backup says, remove the new one
function Invoke-Drop($It) {
    $wasOn = Test-XmlEnabled $It.Src; $keep = & $Ops.Get $It.To; $drop = & $Ops.Get $It.From
    Say ''; Say "- $($It.From) and $($It.To) are both registered: removing $($It.From), keeping $($It.To) ($($keep.State))"
    try {
        if ($It.Board -and $drop.State -eq 'Running') {
            $held = & $Ops.PortPid $Port
            Step "stop $($It.From)" { & $Ops.Stop $It.From }
            Step "wait until port $Port is free (up to $PortWaitSec s)" { if (-not (Wait-PortFree $held)) { throw "port $Port did not come free" } }
        }
        Step "unregister $($It.From)" { & $Ops.Unregister $It.From }
        if ($wasOn -and $keep.State -eq 'Disabled') { Step "switch $($It.To) on" { & $Ops.Enable $It.To } }
        if ($It.Board -and $wasOn -and $keep.State -ne 'Running') {
            Step "start $($It.To)" { & $Ops.Start $It.To }
            Step "health check http://127.0.0.1:$Port/api/health and that the port is held by $($It.To)'s own process" { Confirm-Board $It.To $null }
        }
    } catch { Say "    FAILED: $($_.Exception.Message)"; return $false }
    $true
}

# ---- main ----
try {
    if (-not $Ops) { $Ops = New-RealOps }
    $pairs = @(Read-Pairs $TaskNamesPath)
} catch { Say "ERROR: $($_.Exception.Message); nothing changed"; exit 2 }
Say "Tide rename S4: $(if ($Undo) { 'put the old task names back' } else { 'rename the Yard''s scheduled tasks' })$(if ($DryRun) { '. DRY RUN: nothing will change' })"
Say "  $(@($pairs | ForEach-Object { if ($Undo) { "$($_.New) -> $($_.Old)" } else { "$($_.Old) -> $($_.New)" } }) -join ', ')"
try { $plan = Get-Plan $pairs } catch { Say "ERROR: could not read the tasks: $($_.Exception.Message); nothing changed"; exit 2 }
foreach ($d in $plan.Done) { Say "  nothing to do for $d" }
if (-not $plan.Items.Count -and -not $plan.Blockers.Count) { Say 'Nothing to do.'; exit 0 }
try { Test-Gates $plan } catch { $plan.Blockers.Add("the checks could not run: $($_.Exception.Message)") }
if ($plan.Blockers.Count -and -not $DryRun) {
    Say 'REFUSED, nothing changed:'; foreach ($b in $plan.Blockers) { Say "  - $b" }; exit 2
}
if (-not $Undo -and $plan.Items.Count) {
    Say ''; Say "Backups (before any change), in $BackupDir"
    foreach ($it in $plan.Items) {
        $f = Join-Path $BackupDir "$($it.From).xml"
        Step "save $($it.From)'s XML to $f" { New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null; [IO.File]::WriteAllText($f, $it.Src, [Text.Encoding]::Unicode) }
    }
}
$failed = $false
foreach ($it in $plan.Items) {
    $ok = if ($it.Kind -eq 'drop') { Invoke-Drop $it } else { Invoke-Swap $it }
    if (-not $ok) { $failed = $true; break }
}
Say ''
foreach ($p in $pairs) {
    $o = & $Ops.Get $p.Old; $n = & $Ops.Get $p.New
    Say "  $($p.Old): $(if ($o) { $o.State } else { 'not registered' }); $($p.New): $(if ($n) { $n.State } else { 'not registered' })"
}
if ($DryRun) {
    if ($plan.Blockers.Count) { Say 'DRY RUN: a real run would REFUSE now, for:'; foreach ($b in $plan.Blockers) { Say "  - $b" }; exit 2 }
    Say "DRY RUN done: nothing was changed. To do it, from a normal (not admin) PowerShell: pwsh scripts\rename-tasks.ps1$(if ($Undo) { ' -Undo' })"
    exit 0
}
if ($failed) { Say 'STOPPED: the task above was put back as it was; tasks before it keep their new names. Fix the cause and run this again.'; exit 1 }
Say "Done$(if ($Undo) { ': the old names are back' }). Next: pwsh kitchen\kitchen.ps1 resume, then pwsh scripts\kitchen-check.ps1 and pwsh kitchen\watch.ps1 (they read both names)."
if (-not $Undo) { Say 'To undo: pwsh scripts\rename-tasks.ps1 -Undo' }
exit 0
