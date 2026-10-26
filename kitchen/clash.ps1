# The clash rule for queued orders: an order whose goal names a file that a started order's goal names waits until that one finishes.
# Dot-sourced by kitchen/kitchen.ps1 (its start loop calls Hold-ForClash once per pending order each tick); tests/Test-Clash.ps1 drives it.
# Why: two builds editing the same file (J206, J211, J212, J228 all named pass-app/public/app.js) conflict at freshen or merge and waste a build.
# Rules: oldest wins; an order whose goal names no file never waits; an order already building (past the gate) is never paused;
# a requeued order (kitchen.ps1 requeue sets clashCheck) is checked again before it goes on. Older orders never wait on younger
# unstarted ones, and started orders never wait, so the waits cannot form a loop.

# the files a goal names (pass-app/..., kitchen/..., scripts/..., tests/...), lowercase with /; tests/* never counts as a clash.
# Same pattern as Goal-Files in kitchen/ideas.ps1 (the autopilot's idea clash rule), which an open order owns today; see the PR.
# shared reference docs every goal may cite ("Follow kitchen/CREED.md") and wildcard examples (kitchen/*.ps1) are not files a build edits:
# they never count as a clash (10-22: every goal citing CREED.md waited on every older one).
$script:ClashIgnore = @('kitchen/creed.md', 'kitchen/standards.md', 'kitchen/map.md', 'agents.md')
function Get-GoalFiles([string]$text) {
    @([regex]::Matches($text, '(?i)\b(?:pass-app|kitchen|scripts|tests|data|docs)/[\w./*-]+') | ForEach-Object { $_.Value.TrimEnd('.', '-').ToLowerInvariant().Replace('\', '/') } |
        Where-Object { $_ -notlike 'tests/*' -and $_ -notmatch '\*' -and $_ -notin $script:ClashIgnore } | Select-Object -Unique)
}
# the build step: the first agent step with Role 'do'; else the first agent step; else step 0
function Get-BuildStep($j) {
    $first = -1
    for ($i = 0; $i -lt @($j.steps).Count; $i++) {
        $s = $j.steps[$i]
        if ([IO.Path]::GetFileName([string]$s.script) -ne 'agent-step.ps1') { continue }
        if ($first -lt 0) { $first = $i }
        if ($s.args -and [string]$s.args.Role -eq 'do') { return $i }
    }
    [math]::Max($first, 0)
}
# started = past the gate: beyond its build step, working on it now, or has tried it before (a cook wait, a rework). Clash waits do not count.
function Test-ClashStarted($j) {
    if ($j.clashCheck) { return $false }
    $b = Get-BuildStep $j
    if ([int]$j.cursor -gt $b) { return $true }
    if ($j.status -eq 'running' -and [int]$j.cursor -ge $b) { return $true }
    [bool](@($j.history | Where-Object { $_ -and [int]$_.step -ge $b -and [string]$_.kind -ne 'clash' }).Count)
}
function Get-JobNumber($j) { [int]([string]$j.id).TrimStart('J') }
# the "WAIT: ..." reason this pending, unstarted order must wait for, or $null when it may start
function Get-ClashWait($j, $jobs, $terminal) {
    if (Test-ClashStarted $j) { return $null }
    $mine = @(Get-GoalFiles ([string]$j.vars.goal)); if (-not $mine.Count) { return $null }
    $me = Get-JobNumber $j
    foreach ($o in $jobs) {
        if ([string]$o.id -eq [string]$j.id -or $o.status -in $terminal) { continue }
        $started = Test-ClashStarted $o
        # an unstarted order blocks only when it is older and in line (pending or on a step before its build): oldest wins
        if (-not $started -and ((Get-JobNumber $o) -gt $me -or $o.status -notin 'pending', 'running')) { continue }
        $theirs = @(Get-GoalFiles ([string]$o.vars.goal)); if (-not $theirs.Count) { continue }
        $shared = @($mine | Where-Object { $f = $_; @($theirs | Where-Object { $f -like $_ -or $_ -like $f }).Count })
        if (-not $shared.Count) { continue }
        if ($started) { return "WAIT: $($j.id) shares $($shared -join ', ') with running $($o.id); starts when $($o.id) finishes" }
        return "WAIT: $($j.id) shares $($shared -join ', ') with older queued $($o.id); starts when $($o.id) finishes"
    }
    $null
}
# called by the start loop for each pending order: $true = it waits this tick (the reason is recorded once per change, like a cook wait)
function Hold-ForClash($j, $jobs, $terminal) {
    $why = Get-ClashWait $j $jobs $terminal
    if (-not $why) { if ($j.clashWait -or $j.clashCheck) { $j.clashWait = $null; $j.clashCheck = $null }; return $false }
    if ([string]$j.clashWait -ne $why) {
        $j.clashWait = $why
        Emit 'step.wait' $j.id @{ step = $j.cursor; detail = $why; kind = 'clash' }
        $j.history += , @{ step = $j.cursor; attempt = $j.attempt; outcome = 'wait'; kind = 'clash'; detail = $why; at = Iso (Now) }
        Save-Job $j
    }
    Say $why
    $true
}
