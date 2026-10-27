# Failure care (task 32): the one reader of kitchen/failure-policy.json and the lifecycle rules every failed order follows.
# Dot-sourced by kitchen/kitchen.ps1 (Fail-Step, kill, close, requeue, reopen, doctor) and kitchen/backoff-lib.ps1 (Get-FailureClass).
# Tests: tests/Test-KitchenCare.ps1 (and tests/Test-Backoff.ps1 for the back-off classes).
#
# 1. The policy table: a failure (the kind the Yard records: fail, crash, timeout, hung, memcap, logflood, taster, killed, hold, plus its
#    detail line) -> a class (flaky, conflict, stale, resting, privacy, real, infra, stopped) -> one action (retry once on fresh main,
#    freshen, wait for the window, ask Jordan, stop and say why) and plain words. The first signature that matches wins (its own next step, when it has one, wins over its class's); a kind other
#    than 'fail' takes its kind's class; anything else is the unknown class: "real failure, needs a look". Never retried silently.
# 2. The lifecycle: every order that is not done ends in exactly one cleared state with a reason and a time, written on the order
#    (j.cleared {state, reason, at, by?, from}) and to events.jsonl (job.cleared): retried (by a new attempt on fresh main), superseded
#    (by an order id or a merged PR), duplicate (of an order id), stale (no human action for staleDays, or its brief names files main
#    changed since) or dropped (with the reason). Killed, quarantined and closed are working states; the doctor clears them (Get-CarePlan).
#    kitchen.ps1 reopen -Id J5 puts a cleared order back as it was.

$script:FailurePolicyCache = $null
$script:ClearedStates = @('retried', 'superseded', 'duplicate', 'stale', 'dropped')
$script:SetAsideStates = @('quarantined', 'killed', 'failed')

function Read-FailurePolicy([string]$Path = (Join-Path $PSScriptRoot 'failure-policy.json')) {
    if ($script:FailurePolicyCache -and $script:FailurePolicyCache.path -eq $Path) { return $script:FailurePolicyCache.p }
    $raw = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
    if ($raw.v -ne 1 -or $raw.classes -isnot [Collections.IDictionary] -or $raw.unknown -isnot [Collections.IDictionary]) { throw "failure policy $Path is not version 1 with classes and unknown" }
    $sigs = @(foreach ($s in @($raw.signatures)) {
            if (-not $raw.classes.Contains([string]$s.class)) { throw "failure policy: signature class '$($s.class)' is not a class" }
            @{ class = [string]$s.class; say = [string]$s.say; next = [string]$s.next; rx = [regex]::new([string]$s.match, 'IgnoreCase, CultureInvariant') }
        })
    foreach ($k in @($raw.kinds.Keys)) { if (-not $raw.classes.Contains([string]$raw.kinds[$k].class)) { throw "failure policy: kind '$k' names no class" } }
    if (-not $raw.classes.Contains([string]$raw.unknown.class)) { throw 'failure policy: the unknown class is not a class' }
    $care = @{ staleDays = 3.0; autoActHours = 24.0; recentHours = 72.0 }
    if ($raw.care -is [Collections.IDictionary]) { foreach ($k in @($care.Keys)) { if ("$($raw.care[$k])" -match '^\d+(\.\d+)?$') { $care[$k] = [double]$raw.care[$k] } } }
    $p = @{ classes = $raw.classes; actions = $raw.actions; unknown = $raw.unknown; kinds = $raw.kinds; signatures = $sigs; care = $care }
    $script:FailurePolicyCache = @{ path = $Path; p = $p }
    $p
}

# The class, action and plain words of one failure. Returns @{ class; label; action; actionWords; backoff; say; next; unknown }.
function Get-FailureVerdict([string]$Kind, [string]$Detail, $Policy = $null) {
    if (-not $Policy) { $Policy = Read-FailurePolicy }
    $cls = ''; $say = ''; $unknown = $false; $sigNext = ''
    if ($Kind -and $Kind -ne 'fail' -and $Policy.kinds.Contains($Kind)) { $cls = [string]$Policy.kinds[$Kind].class; $say = [string]$Policy.kinds[$Kind].say }
    else {
        $d = [string]$Detail
        foreach ($s in $Policy.signatures) { if ($s.rx.IsMatch($d)) { $cls = $s.class; $say = $s.say; $sigNext = [string]$s.next; break } }
    }
    $next = $sigNext   # a signature's own next step (disk space) wins over its class's
    if (-not $cls) { $cls = [string]$Policy.unknown.class; $say = [string]$Policy.unknown.say; $next = [string]$Policy.unknown.next; $unknown = $true }
    $c = $Policy.classes[$cls]
    if (-not $next) { $next = [string]$c.next }
    $act = [string]$c.action
    @{ class = $cls; label = [string]$c.label; action = $act; actionWords = [string]$Policy.actions[$act]; backoff = $(if ($c.backoff -eq 'wait') { 'wait' } else { 'code' })
        say = $say; next = $next; unknown = $unknown }
}

# One plain sentence: what happened (and where), then the next step. Never the raw log line: that stays in the history (See why).
function Format-FailureText($Verdict, [int]$Step = 0, [int]$Steps = 0, [string]$Station = '') {
    $where = if ($Step -gt 0 -and $Steps -gt 0) { " at step $Step of $Steps$(if ($Station) { " ($Station)" })" } elseif ($Station) { " ($Station)" } else { '' }
    # The first letter goes lower case after "next:", except a button name (Retry, Close, See why), which keeps its capital.
    $n = [string]$Verdict.next; if ($n -and $n -cnotmatch '^(Retry|Close|See why)\b') { $n = $n.Substring(0, 1).ToLowerInvariant() + $n.Substring(1) }
    "$($Verdict.say)$where; next: $n."
}

# The record a failed order carries (j.failure): the class, the action, one sentence and the raw detail (cut to 400) for See why.
function New-FailureRecord($j, [string]$Kind, [string]$Detail, [string]$At, $Policy = $null) {
    $v = Get-FailureVerdict $Kind $Detail $Policy
    $steps = @($j.steps).Count; $cur = [int]$j.cursor; $st = ''
    if ($cur -lt $steps) { $st = ([IO.Path]::GetFileNameWithoutExtension([string]$j.steps[$cur].script)) -replace '^agent-step$', 'agent' -replace '^demo-worker$', 'demo' }
    $det = ([string]$Detail -replace '\s+', ' ').Trim(); if ($det.Length -gt 400) { $det = $det.Substring(0, 400) }
    @{ class = $v.class; label = $v.label; action = $v.action; say = $v.say; next = $v.next; unknown = $v.unknown; kind = $Kind; detail = $det; at = $At
        text = (Format-FailureText $v $(if ($cur -lt $steps) { $cur + 1 } else { 0 }) $steps $st) }
}

# ---- the lifecycle ----
# Sets the cleared state on the order (status closed, the record, a history line) and returns the job.cleared event's data.
function Set-JobCleared($j, [string]$State, [string]$Reason, [string]$By, [string]$At) {
    if ($State -notin $script:ClearedStates) { throw "not a cleared state: $State" }
    $r = ([string]$Reason -replace '\s+', ' ').Trim(); if ($r.Length -gt 300) { $r = $r.Substring(0, 300) }
    if (-not $r) { throw 'a cleared state needs a reason' }
    $from = if ($j.cleared -and $j.cleared.from) { [string]$j.cleared.from } else { [string]$j.status }
    $c = [ordered]@{ state = $State; reason = $r; at = $At; from = $from }; if ($By) { $c.by = $By }
    $j.cleared = $c; $j.status = 'closed'; $j.stateAt = $At
    $j.history += , @{ step = [int]$j.cursor; attempt = [int]$j.attempt; outcome = 'cleared'; detail = "$State`: $r"; at = $At }
    $ev = @{ state = $State; reason = $r; from = $from }; if ($By) { $ev.by = $By }
    $ev
}

# When the order last saw a human (or the Yard) act on it: stateAt (written by kill, close, requeue, reopen, quarantine), else the newest
# history entry, else the file's write time, else created. UTC.
function ConvertTo-CareUtc($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    try { if ($v -is [DateTime]) { $v.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } } catch { $null }
}
function Get-CareSince($j, $FileTimeUtc = $null) {
    $t = ConvertTo-CareUtc $j.stateAt; if ($t) { return $t }   # (an explicit state time wins)
    $best = $null
    foreach ($v in @($(if (@($j.history).Count) { @($j.history)[-1].at } else { $null }), $FileTimeUtc, $j.created)) {
        $t = ConvertTo-CareUtc $v
        if ($t -and (-not $best -or $t -gt $best)) { $best = $t }
    }
    $best
}
# The newest failure on the order's own record: j.failure.at, else the last failing history entry. $null when none.
function Get-LastFailureAt($j) {
    $v = if ($j.failure -and $j.failure.at) { $j.failure.at } else { $null }
    if (-not $v) { foreach ($h in @($j.history)) { if ($h -and [string]$h.outcome -in 'fail', 'crash', 'timeout', 'memcap', 'logflood', 'hung', 'taster') { $v = $h.at } } }
    ConvertTo-CareUtc $v
}
# The failure record an older order never got (it failed before failure care): from its last failing history entry, or killed.
function Get-BackfillFailure($j, $Policy = $null) {
    if ([string]$j.status -eq 'killed') { return New-FailureRecord $j 'killed' '' ([string]$j.stateAt) $Policy }
    $last = $null; foreach ($h in @($j.history)) { if ($h -and [string]$h.outcome -in 'fail', 'crash', 'timeout', 'memcap', 'logflood', 'hung', 'taster', 'rework') { $last = $h } }
    if ($last) { $k = if ([string]$last.outcome -eq 'rework') { 'taster' } else { [string]$last.outcome }; return New-FailureRecord $j $k ([string]$last.detail) ([string]$last.at) $Policy }
    New-FailureRecord $j 'fail' '' '' $Policy
}

# The goal files an order names (the paths in its goal), lowercase with /; shared reference docs never count.
function Get-CareGoalFiles([string]$Text) {
    @([regex]::Matches($Text, '(?i)\b(?:pass-app|kitchen|scripts|tests|data|docs|core|rust|tools)/[\w./-]+') | ForEach-Object { $_.Value.TrimEnd('.', '-').ToLowerInvariant() } |
        Where-Object { $_ -notin 'kitchen/creed.md', 'kitchen/standards.md', 'kitchen/map.md' } | Select-Object -Unique)
}
# The files main changed after $SinceUtc, from one git log of a repo's main (a list of @{ at; files }), cached per repo for one doctor run.
function Get-MainChanges([string]$Repo, [DateTime]$SinceUtc, [hashtable]$Cache) {
    $key = $Repo.ToLowerInvariant()
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }
    $out = @()
    try {
        $since = $SinceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $lines = @(& git -C $Repo log main --since=$since --name-only '--pretty=format:@%ct' 2>$null)
        if ($LASTEXITCODE -ne 0) { $lines = @(& git -C $Repo log HEAD --since=$since --name-only '--pretty=format:@%ct' 2>$null) }
        $cur = $null
        foreach ($l in $lines) {
            if ($l -match '^@(\d+)$') { if ($cur) { $out += $cur }; $cur = @{ at = [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).UtcDateTime; files = @() } }
            elseif ($cur -and "$l".Trim()) { $cur.files += ([string]$l).Trim().ToLowerInvariant().Replace('\', '/') }
        }
        if ($cur) { $out += $cur }
    } catch { $out = @() }
    $Cache[$key] = $out
    $out
}

# The doctor's failure-care plan for every order it was given (no files written; the caller applies it under the state lock, or only
# lists it with -FindOnly). Returns @{ clear = @(@{ id; state; reason; by }); act = @(@{ id; action; to; why }); fill = @(ids) }.
#   $FileTimes: id -> the file's write time (UTC); $MainChanges: { param($repo, $sinceUtc) -> @(@{ at; files }) } (git, or a test stand-in).
function Get-CarePlan([object[]]$Jobs, [DateTime]$Now, $Policy = $null, [hashtable]$FileTimes = @{}, [scriptblock]$MainChanges = $null) {
    if (-not $Policy) { $Policy = Read-FailurePolicy }
    $staleDays = [double]$Policy.care.staleDays; $actHours = [double]$Policy.care.autoActHours
    $plan = @{ clear = @(); act = @(); fill = @() }
    $all = @($Jobs | Where-Object { $_ -and $_.id })
    # dup keys of every order (jobs-lib.ps1 Get-OrderDupKeys): who shares a goal with whom
    $byKey = @{}
    foreach ($j in $all) { foreach ($k in @(Get-OrderDupKeys $j)) { if (-not $byKey.ContainsKey($k)) { $byKey[$k] = [Collections.Generic.List[object]]::new() }; $byKey[$k].Add($j) } }
    $open = @('pending', 'running', 'waiting-approval', 'needs-human')
    $num = { param($x) [int]([string]$x.id).TrimStart('J') }
    foreach ($j in $all) {
        $st = [string]$j.status
        if ($j.cleared -or $j.recooking) { continue }
        $aside = $st -in $script:SetAsideStates; $legacyClosed = $st -eq 'closed'
        if (-not ($aside -or $legacyClosed)) { continue }
        if ($aside -and -not $j.failure) { $plan.fill += [string]$j.id }
        # a closed order that names what replaced it: superseded by it (closed before failure care, or a requeue's re-cook)
        if ($legacyClosed -and $j.replacedBy) { $plan.clear += @{ id = [string]$j.id; state = 'superseded'; by = [string]$j.replacedBy; reason = "replaced by $($j.replacedBy) (closed before failure care)" }; continue }
        # the same goal elsewhere: duplicate of an open order or a newer set-aside one; superseded by one that was handed over
        if ($aside) {
            # (a handed-over twin first, then an open one, then a newer set-aside one)
            $done = $null; $live = $null; $newer = $null
            foreach ($k in @(Get-OrderDupKeys $j)) {
                foreach ($o in $byKey[$k]) {
                    if ($o.id -eq $j.id -or $o.cleared) { continue }
                    $os = [string]$o.status
                    if ($os -eq 'done' -and -not $done) { $done = $o }
                    elseif ($os -in $open -and -not $live) { $live = $o }
                    elseif ($os -in $script:SetAsideStates -and (& $num $o) -gt (& $num $j) -and (-not $newer -or (& $num $o) -gt (& $num $newer))) { $newer = $o }
                }
            }
            $twin = if ($done) { $done } elseif ($live) { $live } else { $newer }
            $twinWhy = if ($done) { 'superseded' } else { 'duplicate' }
            if ($twin) {
                $why = if ($twinWhy -eq 'superseded') { "the same goal was handed over as $($twin.id)" } else { "the same goal is open as $($twin.id) ($($twin.status))" }
                $plan.clear += @{ id = [string]$j.id; state = $twinWhy; by = [string]$twin.id; reason = $why }; continue
            }
        }
        # the policy's one action, once, for a fresh failure (never for an old one: no surprise runs)
        $failAt = Get-LastFailureAt $j
        $v = if ($j.failure -and $j.failure.class) { Get-FailureVerdictOfClass ([string]$j.failure.class) $Policy } else { $f = Get-BackfillFailure $j $Policy; Get-FailureVerdictOfClass $f.class $Policy }
        if ($st -eq 'quarantined' -and $failAt -and ($Now - $failAt).TotalHours -le $actHours -and -not $j.care -and -not $j.retryOf -and $v.action -in 'retry', 'freshen', 'wait') {
            $fi = -1; $ci = -1
            for ($i = 0; $i -lt @($j.steps).Count; $i++) { $nm = [IO.Path]::GetFileNameWithoutExtension([string]$j.steps[$i].script); if ($nm -eq 'freshen' -and $i -lt [int]$j.cursor) { $fi = $i }; if ($nm -eq 'commit') { $ci = $i } }
            $recipe = if ($j.recipe) { [string]$j.recipe } elseif ([string]$j.name -match '^([\w-]+):') { $Matches[1] } else { '' }
            if ($v.action -eq 'wait') { $plan.act += @{ id = [string]$j.id; action = 'wait'; to = [int]$j.cursor; why = "$($v.label): $($v.actionWords)" } }
            elseif ($fi -ge 0) { $plan.act += @{ id = [string]$j.id; action = $v.action; to = $fi; why = "$($v.label): $($v.actionWords) (from its freshen step)" } }
            # no freshen step behind it: a recipe order that has not committed yet is made again from today's recipe on fresh main
            elseif ($recipe -and $recipe -ne 'diagnose' -and ($ci -lt 0 -or [int]$j.cursor -le $ci) -and (Get-JobTower $j)) { $plan.act += @{ id = [string]$j.id; action = 'recook'; to = 0; why = "$($v.label): $($v.actionWords) (a new attempt from today's recipe)" } }
            continue
        }
        # killed, quarantined and closed are working states: after staleDays without a human action they are cleared as stale
        $since = Get-CareSince $j $FileTimes[[string]$j.id]
        if (-not $since -or ($Now - $since).TotalDays -lt $staleDays) { continue }
        $days = [int][math]::Floor(($Now - $since).TotalDays)
        $was = switch ($st) { 'killed' { 'stopped' } 'closed' { 'closed with no recorded ending' } default { 'failed' } }
        $reason = "no human action for $days days since it $(if ($st -eq 'closed') { 'was ' })$was"
        $goalFiles = @(Get-CareGoalFiles ([string](Get-JobVar $j 'goal')))
        $repo = Get-JobTower $j
        if ($MainChanges -and $goalFiles.Count -and $repo -and $j.created) {
            $made = try { if ($j.created -is [DateTime]) { $j.created.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$j.created, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } } catch { $null }
            if ($made) {
                $hit = @(@(& $MainChanges $repo $made) | Where-Object { $_.at -gt $made } | ForEach-Object { $_.files } | Where-Object { $_ -in $goalFiles } | Select-Object -Unique)
                if ($hit.Count) { $reason = "its brief was written against $($hit[0..([math]::Min(2, $hit.Count - 1))] -join ', ')$(if ($hit.Count -gt 3) { " and $($hit.Count - 3) more" }), which changed on main since; $reason" }
            }
        }
        $plan.clear += @{ id = [string]$j.id; state = 'stale'; by = ''; reason = $reason }
    }
    $plan
}
function Get-FailureVerdictOfClass([string]$Class, $Policy) {
    if (-not $Policy.classes.Contains($Class)) { $Class = [string]$Policy.unknown.class }
    $c = $Policy.classes[$Class]
    @{ class = $Class; label = [string]$c.label; action = [string]$c.action; actionWords = [string]$Policy.actions[[string]$c.action] }
}
