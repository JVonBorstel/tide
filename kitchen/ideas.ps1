# The idea list and the autopilot: how the kitchen keeps improving itself.
#   Research teams (recipe "upgrades") write IDEA lines; this script files them in <kitchen>\ideas.json.
#   The autopilot (each supervisor tick, AI cooks live) turns the best new small or medium idea into an Improve order on the Google
#   plan, one at a time, at most 4 a day, and pauses while 2 finished changes wait for Jordan's yes. Merging stays Jordan's tap.
#   Never two changes to the same files at once: an idea whose goal names a file (not tests/*) that a running or waiting Improve order names waits (auto) or warns (build).
#   The coach (once a day, after 3 builds) reads how recent Improve orders went and files an idea to improve the kitchen's own
#   recipes and prompts: the loop improves the loop.
#   ideas.ps1 harvest -From <file> [-Source x] | add -Title t -Goal g [-Why w] [-Size S|M|L] [-Source x] | list | drop -Id I3 | build -Id I3 | auto | coach | pause | resume  [-Json]
param([Parameter(Position = 0)][ValidateSet('harvest', 'add', 'list', 'drop', 'build', 'auto', 'coach', 'pause', 'resume')][string]$Action = 'list',
      [string]$From = '', [string]$Source = '', [string]$Title = '', [string]$Goal = '', [string]$Why = '', [string]$Size = 'M', [string]$Id = '', [switch]$Json)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$path = Join-Path $root 'ideas.json'; $metaPath = Join-Path $root 'autopilot.json'
$cfg = @{ cook = 'antigravity'; fallbackCook = 'gemini'; perDay = 4; maxWaiting = 2; coachEvery = 3; maxActive = 1 }   # maxActive: Improve orders cooking at once
foreach ($kp in @((Join-Path $PSScriptRoot 'kitchen.json'), (Join-Path $root 'kitchen.json'))) {
    try { $kc = Get-Content -LiteralPath $kp -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable; if ($kc.autopilot) { foreach ($k in $kc.autopilot.Keys) { $cfg[$k] = $kc.autopilot[$k] } } } catch { }
}
function Out-Result($o) { if ($Json) { $o | ConvertTo-Json -Depth 6 -Compress } else { $o }; exit 0 }
# Fail CLOSED: an ideas.json that exists but will not parse (a lock, a half write, a bad edit) is never read as empty, because the next Save
# would then wipe every idea and restart ids at I1 (old jobs would map to the wrong idea). Refuse the whole call; ideas.json.bak holds the last good copy.
$script:nextId = 0
function Load {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { $d = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop; if ($d -isnot [hashtable]) { throw 'not an object' } }
    catch { Write-Error "ideas: $path cannot be read ($($_.Exception.Message)); refusing to touch it (last good copy: ideas.json.bak)" -ErrorAction Continue; exit 1 }
    $script:nextId = [int]$d.nextId; @($d.items)
}
# ids come from a counter kept in the file (never only from the items left), so an id is never handed out twice
function Next-Id($items) { $m = 1 + [int](@($items | ForEach-Object { [int]([string]$_.id).Substring(1) }) | Measure-Object -Maximum).Maximum; $n = [math]::Max($m, $script:nextId); $script:nextId = $n + 1; $n }
function Save($items) {
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination "$path.bak" -Force }   # the last good copy, before each write
    $t = "$path.tmp"; @{ updated = (Get-Date).ToUniversalTime().ToString('o'); nextId = $script:nextId; items = @($items) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $t -Encoding utf8; Move-Item -LiteralPath $t -Destination $path -Force
}
function Now { (Get-Date).ToUniversalTime().ToString('o') }
# autopilot.json: every writer holds the ideas mutex (Chef's pause/resume comes through this script too) and writes temp + rename
function Load-Meta { $m = @{}; if (Test-Path -LiteralPath $metaPath) { try { $m = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json -AsHashtable } catch { } }; if ($m -isnot [hashtable]) { $m = @{} }; $m }
function Save-Meta($m) { $t = "$metaPath.tmp"; $m | ConvertTo-Json | Set-Content -LiteralPath $t -Encoding utf8; Move-Item -LiteralPath $t -Destination $metaPath -Force }
function Norm([string]$t) { ($t.ToLowerInvariant() -replace '[^a-z0-9 ]', '' -replace '\s+', ' ').Trim() }
function New-Idea($items, [string]$title, [string]$goal, [string]$why, [string]$size, [string]$src, [string]$link) {
    $title = $title.Trim(); $goal = $goal.Trim()
    if ($title.Length -lt 4 -or $goal.Length -lt 12) { return $null }
    if ($title.Length -gt 120) { $title = $title.Substring(0, 120) }; if ($goal.Length -gt 1400) { $goal = $goal.Substring(0, 1400) }
    if (@($items | Where-Object { (Norm $_.title) -eq (Norm $title) }).Count) { return $null }   # already have it
    $n = Next-Id $items
    @{ id = "I$n"; title = $title; goal = $goal; why = $why.Trim(); size = $(if ($size -in 'S', 'M', 'L') { $size } else { 'M' }); source = $src; link = $link; status = 'new'; at = (Now); job = '' }
}
. (Join-Path $PSScriptRoot 'jobs-lib.ps1')
function Jobs([switch]$All) { if ($All) { @(Get-KitchenJobs $root -WithArchive) } else { @(Get-KitchenJobs $root -Live) } }   # in play, or -All: every order ever (archived ones as summaries)
# the files a goal names (pass-app/..., kitchen/..., scripts/..., tests/...), lowercase with /; tests/* never counts as a clash
function Goal-Files([string]$text) {
    @([regex]::Matches($text, '(?i)\b(?:pass-app|kitchen|scripts|tests|data|docs)/[\w./*-]+') | ForEach-Object { $_.Value.TrimEnd('.', '-').ToLowerInvariant().Replace('\', '/') } |
        Where-Object { $_ -notlike 'tests/*' } | Select-Object -Unique)
}
# the first Improve order still running or waiting whose goal names a file this idea's goal names, with the shared files; else $null
function Clashes($idea) {
    $mine = @(Goal-Files ([string]$idea.goal)); if (-not $mine.Count) { return $null }
    foreach ($j in Jobs) {
        if ([string]$j.name -notlike 'improve:*' -or $j.status -notin 'pending', 'running', 'waiting-approval', 'needs-human') { continue }
        $shared = @(Goal-Files ([string]$j.vars.goal) | Where-Object { $_ -in $mine })
        if ($shared.Count) { return @{ job = [string]$j.id; files = ($shared -join ', ') } }
    }
    $null
}
function Build($items, $idea, [string]$by) {
    $goal = "$($idea.goal)`n`n(Idea $($idea.id): $($idea.title). $($idea.why))"
    if ($goal.Length -gt 1500) { $goal = $goal.Substring(0, 1500) }
    # the Google plan has two pools: Claude models (antigravity) and Gemini. When the first is resting, Gemini builds (Claude quota stays untouched)
    $cook = [string]$cfg.cook
    try { $st = Get-Content -LiteralPath (Join-Path $root 'suppliers-state.json') -Raw | ConvertFrom-Json -AsHashtable; if ($st[$cook].restUntil -and ([DateTime]$st[$cook].restUntil).ToUniversalTime() -gt (Get-Date).ToUniversalTime()) { $cook = [string]$cfg.fallbackCook } } catch { }
    if (-not $cook) { $cook = 'gemini' }
    # cook 'any': no pin, the sous chef picks per step across every plan and moves on when one is capped or resting
    $vars = @{ goal = $goal }; if ($cook -ne 'any') { $vars.cook = $cook }
    $o = & (Join-Path $PSScriptRoot 'cook.ps1') -Recipe improve -Vars $vars -Json | Out-String
    try { $r = ($o.Trim() -split "`r?`n")[-1] | ConvertFrom-Json -AsHashtable } catch { $r = @{ ok = $false; error = $o.Trim() } }
    if ($r.ok) { $idea.status = 'building'; $idea.job = [string]$r.job; $idea.builtAt = (Now); $idea.by = $by }
    $r
}
# keep each idea's status in step with its Improve order
$script:jobById = @{}; $script:jobArchive = $null
# one order by id, read only when asked (this runs every tick): its jobs\ file, else its archive summary (kitchen/jobs-lib.ps1)
function Job-ById([string]$jid) {
    if (-not $jid) { return $null }
    if ($script:jobById.ContainsKey($jid)) { return $script:jobById[$jid] }
    $j = try { [IO.File]::ReadAllText((Join-Path $root "jobs\$jid.json")) | ConvertFrom-Json -AsHashtable } catch { $null }
    if (-not $j) { if ($null -eq $script:jobArchive) { $script:jobArchive = Read-KitchenJobArchive $root }; $s = $script:jobArchive[$jid]; if ($s) { $j = ConvertTo-ArchivedJob $s } }
    $script:jobById[$jid] = $j; $j
}
function Sync($items) {
    foreach ($i in $items) {
        # a failed idea moves on too when its order was re-cooked (kitchen.ps1 close -ReplacedBy) and the new order lands
        if ($i.status -notin 'building', 'failed' -or -not (Job-ById $i.job)) { continue }
        $n = 0; while ((Job-ById $i.job).replacedBy -and (Job-ById ([string](Job-ById $i.job).replacedBy)) -and $n++ -lt 20) { $i.job = [string](Job-ById $i.job).replacedBy }
        $s = (Job-ById $i.job).status
        if ($i.status -eq 'failed' -and $s -notin 'done', 'pending', 'running', 'waiting-approval', 'needs-human') { continue }
        if ($s -eq 'done') { $i.status = 'merged' } elseif ($s -in 'quarantined', 'failed') { $i.status = 'failed' } elseif ($s -eq 'killed') { $i.status = 'dropped' } elseif ($s -in 'waiting-approval', 'needs-human') { $i.status = 'building' }
    }
    # the Ledger (kitchen/ledger.ps1) is where the proof lives: an idea it proves shipped (a commit on main, a closed order's proof, or a
    # link) is merged here too, so the list never says "failed" about work that landed (older closes named their replacement only in text)
    try { $lg = Get-Content -LiteralPath (Join-Path $root 'ledger.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { $lg = $null }
    if ($lg -and $lg.items) {
        $shipped = @{}; foreach ($x in $lg.items) { if ($x.kind -eq 'idea' -and $x.state -eq 'shipped' -and $x.proof) { $shipped[[string]$x.id] = [string]$x.proof } }
        foreach ($i in $items) { if ($i.status -in 'failed', 'building' -and $shipped[[string]$i.id]) { $i.status = 'merged'; $i.proof = $shipped[[string]$i.id] } }
    }
}

# One writer at a time: research teams that finish together would otherwise overwrite each other's ideas.
# The lock is released when this process exits (an abandoned mutex still hands over cleanly).
$lockName = 'Local\kitchen-ideas-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($path.ToLowerInvariant()))).Substring(0, 16)
$lock = [Threading.Mutex]::new($false, $lockName)
try { if (-not $lock.WaitOne(60000)) { Write-Error 'the idea list is busy; try again'; exit 1 } } catch [Threading.AbandonedMutexException] { }
try {   # released in finally, also when this script runs inside another PowerShell process (& ideas.ps1)

$items = [Collections.Generic.List[object]]::new(); foreach ($x in Load) { $items.Add($x) }
switch ($Action) {
    'list' { Sync $items; Save $items; Out-Result @{ ok = $true; items = @($items) } }
    'add' {
        # source Jordan is what lets a change merge without his tap (automerge.ps1), so it is never a default: only Chef's own call,
        # which sets KITCHEN_FROM_CHEF=1, may file one as his. Anything else (Claude sessions, scripts, cooks) is 'cli' unless it says.
        $src = if ($Source) { $Source.Trim() } else { 'cli' }
        if ($src -eq 'Jordan' -and $env:KITCHEN_FROM_CHEF -ne '1') { Out-Result @{ ok = $false; error = 'only Chef files ideas as Jordan''s; use another -Source' } }
        $i = New-Idea $items $Title $Goal $Why $Size $src ''
        if (-not $i) { Out-Result @{ ok = $false; error = 'needs a title (4+ characters) and a goal (12+), and must be new' } }
        if ($src -eq 'Jordan') { $i.score = 100 }   # Jordan's own ideas go first
        $items.Add($i); Save $items; Out-Result @{ ok = $true; idea = $i }
    }
    'harvest' {
        if (-not (Test-Path -LiteralPath $From)) { Write-Output "ideas: nothing to harvest ($From missing)"; exit 1 }
        $text = Get-Content -LiteralPath $From -Raw; $added = @()
        foreach ($m in [regex]::Matches($text, '(?m)^\s*[-*]?\s*IDEA:\s*(\{.*\})\s*$')) {
            try { $o = $m.Groups[1].Value | ConvertFrom-Json -AsHashtable } catch { continue }
            $i = New-Idea $items ([string]$o.title) ([string]$o.goal) ([string]$o.why) ([string]$o.size) $(if ($Source -and $Source -ne 'Jordan') { $Source } else { 'research' }) ([string]$o.source)   # harvested ideas are never Jordan's
            if ($i) { $i.score = [int]$(if ($o.value) { [math]::Min(10, [math]::Max(1, [int]$o.value)) } else { 5 }) * 10 - $(switch ($i.size) { 'S' { 0 } 'M' { 10 } default { 30 } }); $items.Add($i); $added += $i.id }
        }
        Save $items
        Write-Output "ideas: filed $($added.Count) new idea(s) $($added -join ', ')"
        if (-not $added.Count -and -not [regex]::IsMatch($text, 'IDEA:')) { exit 1 }   # the research gave no ideas at all
        exit 0
    }
    'drop' { $i = $items | Where-Object id -eq $Id | Select-Object -First 1; if (-not $i) { Out-Result @{ ok = $false; error = "no idea $Id" } }; $i.status = 'dropped'; Save $items; Out-Result @{ ok = $true; idea = $i } }
    'build' {
        $i = $items | Where-Object id -eq $Id | Select-Object -First 1
        if (-not $i -or $i.status -notin 'new', 'failed') { Out-Result @{ ok = $false; error = "no new idea $Id" } }
        $c = Clashes $i
        $r = Build $items $i 'Jordan'; Save $items
        $res = @{ ok = [bool]$r.ok; idea = $i; job = [string]$r.job; error = [string]$r.error }
        if ($c) { $res.warning = "shares $($c.files) with $($c.job), which is still running or waiting; expect a merge clash" }
        Out-Result $res
    }
    'auto' {
        Sync $items
        $live = $env:KITCHEN_LIVE -eq '1' -or (Test-Path -LiteralPath (Join-Path $root 'LIVE'))
        $meta = Load-Meta
        # a new day resets only the day's count: rebuilding the table here used to drop 'paused' (the autopilot resumed at midnight without
        # Jordan's yes) and 'scored' (the coach then recorded a second scoreboard trend row a minute later)
        $day = (Get-Date).ToString('yyyy-MM-dd'); if ($meta.day -ne $day) { $meta.day = $day; $meta.built = 0 }
        $why = ''
        $improves = @(Jobs | Where-Object { [string]$_.name -like 'improve:*' })
        $active = @($improves | Where-Object { $_.status -in 'pending', 'running' }).Count
        $waiting = @($improves | Where-Object { $_.status -in 'waiting-approval', 'needs-human' }).Count
        # the job hunt goes first (Jordan 2026-10-15: keep ~25% for scout/tailor/pack): no new build while a hunt order is cooking
        $hunting = @(Jobs | Where-Object { [string]$_.name -match '^(jobscout|tailor|pack|hunt-night):' -and $_.status -in 'pending', 'running' }).Count
        if (-not $live) { $why = 'AI cooks are off' }
        elseif ($meta.paused) { $why = 'paused by Jordan' }
        elseif ($hunting) { $why = "the job hunt goes first ($hunting hunt order(s) cooking)" }
        elseif ($active -ge [int]$cfg.maxActive) { $why = "$active Improve order(s) already cooking (limit $($cfg.maxActive))" }
        elseif ($waiting -ge [int]$cfg.maxWaiting) { $why = "$waiting finished changes are waiting for your yes" }
        elseif ([int]$meta.built -ge [int]$cfg.perDay) { $why = "built $($meta.built) today (the daily limit)" }
        $built = $null
        if (-not $why) {
            $cands = @($items | Where-Object { $_.status -eq 'new' -and $_.size -in 'S', 'M' } | Sort-Object @{ e = { -[int]$_.score } }, @{ e = { $_.at } })
            $next = $null; $held = ''
            foreach ($cand in $cands) {   # never two changes to the same files at once: they clash at merge
                $c = Clashes $cand
                if ($c) { if (-not $held) { $held = "waiting: $($cand.id) shares $($c.files) with $($c.job)" }; continue }
                $next = $cand; break
            }
            if (-not $next) { $why = $(if ($held) { $held } else { 'no small or medium idea waiting' }) }
            else { $r = Build $items $next 'autopilot'; if ($r.ok) { $meta.built = [int]$meta.built + 1; $meta.sinceCoach = [int]$meta.sinceCoach + 1; $built = @{ idea = $next.id; job = [string]$r.job } } else { $why = "could not order it: $($r.error)" } }
        }
        Save $items; Save-Meta $meta
        Out-Result @{ ok = $true; built = $built; why = $why }
    }
    'pause' { $meta = Load-Meta; $meta.paused = $true; Save-Meta $meta; Out-Result @{ ok = $true; paused = $true } }
    'resume' { $meta = Load-Meta; $meta.paused = $false; Save-Meta $meta; Out-Result @{ ok = $true; paused = $false } }
    'coach' {
        # how recent Improve orders went, per station: the coach's idea is to fix the weakest link in the kitchen's own pipeline
        $meta = Load-Meta
        # the scoreboard is the fitness score the pipeline evolves against: its trend row is recorded once a day (a cheap date check)
        $sb = Join-Path $PSScriptRoot 'scoreboard.ps1'; $board = ''
        try { if ($meta.scored -ne (Get-Date).ToString('yyyy-MM-dd')) { & $sb -Record | Out-Null; $meta.scored = (Get-Date).ToString('yyyy-MM-dd'); Save-Meta $meta } } catch { }
        # the cheap gates come before reading the board: this runs every tick inside the ideas lock, a full scoreboard scans every event,
        # job and run file (~2 s each), and the coach files at most once a day
        if ([int]$meta.sinceCoach -lt [int]$cfg.coachEvery -and -not $Id) { Out-Result @{ ok = $true; filed = $null; why = "coach waits for $($cfg.coachEvery) builds ($([int]$meta.sinceCoach) so far)" } }
        if ($meta.coached -eq (Get-Date).ToString('yyyy-MM-dd') -and -not $Id) { Out-Result @{ ok = $true; filed = $null; why = 'coached today already' } }
        $recent = @(Jobs -All | Where-Object { [string]$_.name -like 'improve:*' -and $_.status -in 'done', 'quarantined', 'failed', 'killed', 'waiting-approval' } | Sort-Object { try { ([DateTime]$_.created).ToUniversalTime() } catch { [DateTime]::MinValue } } | Select-Object -Last 12 |
            ForEach-Object { if ($_.archived) { Read-ArchivedJobFile $root $_ } else { $_ } } | Where-Object { $_ })   # (an archived one is read whole: its history)
        if ($recent.Count -lt 2) { Out-Result @{ ok = $true; filed = $null; why = 'not enough Improve orders yet' } }
        # about to file: read the board once; the worst model-per-kind pair (at least 3 runs) says which line of the menu in kitchen.json to retune
        $worst = ''
        try {
            $board = (& $sb | Out-String).Trim()
            $kinds = @(((& $sb -Json | Out-String) | ConvertFrom-Json).kinds | Where-Object { [int]$_.runs -ge 3 } | Sort-Object { [double]$_.okPct }, { -[int]$_.runs })
            if ($kinds.Count) { $w = $kinds[0]; $worst = "Worst model for a kind of work: $($w.model) on '$($w.kind)' orders passed $($w.okPct)% of $($w.runs) runs; check that kind's line in the menu of kitchen/kitchen.json (menuWhy says why it is there) and move or drop that cook if the numbers justify it." }
        } catch { }
        $lines = foreach ($j in $recent) {
            $fails = @($j.history | Where-Object { $_.outcome -ne 'done' } | ForEach-Object { $st = @($j.steps)[[int]$_.step]; "$([IO.Path]::GetFileNameWithoutExtension([string]$st.script)) step $([int]$_.step + 1): $($_.outcome)$(if ($_.detail) { ' (' + ([string]$_.detail).Substring(0, [math]::Min(120, ([string]$_.detail).Length)) + ')' })" })
            "- $($j.id) $($j.status), $(@($j.history).Count) runs$(if ($fails) { '; ' + ($fails -join '; ') })"
        }
        $goal = "Make the kitchen's own self-improvement pipeline better, based on how its last $($recent.Count) Improve orders went:`n$($lines -join "`n")`n$(if ($worst) { "$worst`n" })$(if ($board) { "
The scoreboard (kitchen/scoreboard.ps1; the trend is in scoreboard.jsonl):
$board
" })Find the weakest link (the station or prompt that fails or gets sent back most, or the slowest or costliest stage on the scoreboard) and improve it, saying which scoreboard number should get better: kitchen/recipes/improve.json prompts, kitchen/stations/*.ps1 or kitchen/agent-step.ps1. Keep every guardrail (merge only with Jordan's yes, read-only planning, bounded runs). Add or update tests."
        $i = New-Idea $items "Coach: strengthen the self-improvement pipeline ($((Get-Date).ToString('MMM d')))" $goal 'The loop improves the loop: fewer failed or sent-back builds.' 'M' 'coach' ''
        if ($i) { $i.score = 90; $items.Add($i); Save $items }
        $meta.coached = (Get-Date).ToString('yyyy-MM-dd'); $meta.sinceCoach = 0; Save-Meta $meta
        Out-Result @{ ok = $true; filed = $(if ($i) { $i.id } else { $null }) }
    }
}
} finally { try { $lock.ReleaseMutex() } catch { }; $lock.Dispose() }
