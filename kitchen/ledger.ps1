# The Ledger: one true list of every idea, order and roadmap item, with its state, owner, age, chain and PROOF (gemini-brain
# projects/tide/02-the-watch.md, layer 1). It never trusts a status field alone: shipped needs a commit on the repo's main that
# names the order or item, a docs/changes/<id>.md on main, a finished non-code order, or a manual link that carries proof.
# Read-only on kitchen state, except ledger.json, ledger-links.json (link) and watch\ledger.json (its heartbeat). Safe to re-run: yes.
# ZG-25: also reads the lobe's <lobe home>\flags.json (never writes it): flags 'decision-ready' and 'post-mortem-due', counted in the top line.
#   ledger.ps1 [build] [-Json] [-Quiet]        build ledger.json (also every tick); prints the top line
#   ledger.ps1 show -Id I15|J140|B-09 [-Json]   one item with its chain and proof
#   ledger.ps1 link -Id I21 -Proof <commit|PR url|file> -Why "..."   record proof for work done outside the kitchen
#   ledger.ps1 flags [-Json]                    the flags only (each with an owner and a plain sentence)
# States: shipped | waiting-on-jordan | moving | stuck | lost | claimed (closed as "done another way", no proof) | not-started | dropped (by Jordan) | replaced
# Exit 0 ok, 2 bad call, 1 could not read the kitchen.
param([Parameter(Position = 0)][string]$Action = 'build', [string]$Id = '', [string]$Proof = '', [string]$Why = '', [switch]$Json, [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$kitchenRepo = if ($env:KITCHEN_REPO) { $env:KITCHEN_REPO } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
$outPath = Join-Path $root 'ledger.json'; $linksPath = Join-Path $root 'ledger-links.json'
function Fail([string]$m, [int]$code = 2) { if ($Json) { @{ ok = $false; error = $m } | ConvertTo-Json -Compress } else { Write-Output "ERROR: $m" }; exit $code }
if ($Action -notin 'build', 'show', 'link', 'flags') { Fail "unknown action '$Action' (build, show, link, flags)" }
$now = [DateTime]::UtcNow
function Utc($v) { if (-not $v) { return $null }; if ($v -is [DateTime]) { return $v.ToUniversalTime() }; try { [DateTime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal) } catch { $null } }
function Days($v) { $t = Utc $v; if ($t) { [math]::Round(($now - $t).TotalDays, 1) } else { $null } }
function ReadJson([string]$p) { if (-not (Test-Path -LiteralPath $p)) { return $null }; Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
function Write-Atomic([string]$p, $obj) { $t = "$p.tmp"; $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $t -Encoding utf8; Move-Item -LiteralPath $t -Destination $p -Force }

# ---------- link: proof for work done by hand ----------
if ($Action -eq 'link') {
    if ($Id -notmatch '^(I\d{1,5}|J\d{1,5}|[A-Za-z][A-Za-z0-9]{0,5}-\d{1,4}|R-\d{1,4})$') { Fail 'give -Id (an idea I12, order J12, roadmap item B-01 or request R-001)' }
    if ($Proof.Trim().Length -lt 6) { Fail 'give -Proof: a commit hash, a PR url, a file path or a test result (no proof, no link)' }
    if ($Why.Trim().Length -lt 6) { Fail 'give -Why: one plain sentence on what the proof shows' }
    $p = $Proof.Trim()
    $okProof = ($p -match '^[0-9a-f]{7,40}$') -or ($p -match '^https://github\.com/[\w.-]+/[\w.-]+/(pull|commit)/\w+') -or (Test-Path -LiteralPath $p) -or ($p -match '^(I|J)\d+$')
    if (-not $okProof) { Fail "proof '$p' is not a commit hash, a GitHub PR or commit url, an existing file, or an order id" }
    $links = ReadJson $linksPath; if (-not $links) { $links = @{} }
    $links[$Id] = @{ proof = $p; why = $Why.Trim(); at = $now.ToString('o'); by = $(if ($env:KITCHEN_FROM_CHEF -eq '1') { 'Jordan' } else { 'cli' }) }
    Write-Atomic $linksPath $links
    if ($Json) { @{ ok = $true; id = $Id; link = $links[$Id] } | ConvertTo-Json -Compress } else { Write-Output "linked $Id -> $p" }
    exit 0
}

# ---------- read everything ----------
try {
    $ideasDoc = ReadJson (Join-Path $root 'ideas.json')
    $ideas = @(if ($ideasDoc) { $ideasDoc.items })
    # every order ever: the jobs\ files plus one summary per archived order (jobs\archive\index.jsonl; kitchen/jobs-lib.ps1)
    . (Join-Path $PSScriptRoot 'jobs-lib.ps1')
    . (Join-Path $PSScriptRoot 'site-registry.ps1')   # programs grouped by Site (TD-5)
    $jobs = @{}
    foreach ($j in (Get-KitchenJobs $root -WithArchive)) { if ($j.id) { $jobs[[string]$j.id] = $j } }
} catch { Fail "cannot read the kitchen at ${root}: $($_.Exception.Message)" 1 }
$links = ReadJson $linksPath; if (-not $links) { $links = @{} }

# close/kill reasons from the event log; a reason naming another order is a replacement ("re-cooked fresh as J143")
$closed = @{}; $replacedBy = @{}; $claimedDone = @{}
$ev = Join-Path $root 'events.jsonl'
if (Test-Path -LiteralPath $ev) {
    foreach ($m in Select-String -LiteralPath $ev -Pattern '"type":"job\.(closed|killed)"' -ErrorAction SilentlyContinue) {
        try { $e = $m.Line | ConvertFrom-Json -AsHashtable } catch { continue }
        $jid = [string]$e.job; if (-not $jid) { continue }
        $closed[$jid] = @{ type = ([string]$e.type -replace '^job\.', ''); reason = [string]$e.reason; at = [string]$e.ts; proof = [string]$e.proof; dropped = [bool]$e.dropped; by = [string]$e.by }
        if ($e.replacedBy) { $replacedBy[$jid] = [string]$e.replacedBy; continue }   # a close that names its ending (kitchen.ps1 close)
        if ($e.proof -or $e.dropped) { continue }
        $r = [string]$e.reason
        # the first other order named in the reason is its replacement ("re-cooked fresh as J143", "done another way: J91 merged ...")
        $mm = @([regex]::Matches($r, '\b(J\d+)\b') | Where-Object { $_.Groups[1].Value -ne $jid }) | Select-Object -First 1
        if ($mm) { $replacedBy[$jid] = $mm.Groups[1].Value }
        elseif ($r -match '(?i)done another way|integrated|merged by the lead|replaced by|already (does|reads|has)') { $claimedDone[$jid] = $r }
    }
}
foreach ($j in $jobs.Values) { if ($j.replacedBy) { $replacedBy[[string]$j.id] = [string]$j.replacedBy } }
# merges undone in one tap (undo-merge.ps1 / verify write merge.undone): a Sign-off's post-mortem proof (ZG-25)
$undone = @{}
if (Test-Path -LiteralPath $ev) {
    foreach ($m in Select-String -LiteralPath $ev -Pattern '"type":"merge\.undone"' -ErrorAction SilentlyContinue) { try { $e = $m.Line | ConvertFrom-Json -AsHashtable; if ($e.job -and -not $undone[[string]$e.job]) { $undone[[string]$e.job] = [string]$e.ts } } catch { } }
}

# Jordan's own drops and builds from Chef (pass-actions.jsonl)
$jordanDrop = @{}
$pa = Join-Path $root 'pass-actions.jsonl'
if (Test-Path -LiteralPath $pa) {
    foreach ($m in Select-String -LiteralPath $pa -Pattern '"op":"ideas-drop"' -ErrorAction SilentlyContinue) { try { $e = $m.Line | ConvertFrom-Json -AsHashtable; if ($e.ok) { $jordanDrop[[string]$e.id] = [string]$e.ts } } catch { } }
}

# ---------- proof from each repo's main ----------
# (a Tower path that cannot be made full, such as one with a NUL in it, is kept as written: one bad Tower is a finding, not a crash; TD-5)
function Repo-Of($j) { $r = [string]$j.vars.repo; if ($r) { (ConvertTo-SiteTowerKey $r) } else { $kitchenRepo.TrimEnd('\', '/') } }
function Tower-Name([string]$repo) { @(($repo -replace '[\x00-\x1f]', '?') -split '[\\/]' | Where-Object { $_ })[-1] }   # the folder name, control characters shown as ?
$repoProof = @{}
function Get-RepoProof([string]$repo) {
    if ($repoProof.ContainsKey($repo)) { return $repoProof[$repo] }
    $o = @{ ok = $false; reverted = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); ids =[Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase); changes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); branch = ''; head = '' }
    try { Read-RepoProof $repo $o } catch { $o.ok = $false }   # an unreadable Tower: ok stays false and the flags below name it
    $repoProof[$repo] = $o; $o
}
function Read-RepoProof([string]$repo, $o) {
    if (Test-Path -LiteralPath (Join-Path $repo '.git')) {
        $br = ''
        foreach ($b in 'main', 'master') { & git -C $repo rev-parse --verify --quiet "refs/heads/$b" *> $null; if ($LASTEXITCODE -eq 0) { $br = $b; break } }
        if ($br) {
            $o.branch = $br; $o.head = (& git -C $repo rev-parse --short $br 2>$null)
            $log = @(& git -C $repo log $br -n 4000 --format='%h%x1f%s%x1f%b%x1e' 2>$null) -join "`n"
            foreach ($rec in $log -split [char]0x1e) {
                $parts = $rec.Trim() -split [char]0x1f; if ($parts.Count -lt 2) { continue }
                $h = $parts[0]; $text = ($parts[1..($parts.Count - 1)] -join ' '); $rev = $parts[1] -match '^Revert\b'
                # newest first: the first commit naming an id is its newest; when that one is a revert, the id was undone on main (ZG-25)
                foreach ($mm in [regex]::Matches($text, '(?<![A-Za-z0-9])(J\d{1,5}|I\d{1,5}|[A-Z][A-Za-z0-9]{0,5}-\d{1,4})(?![\d])')) { $k = $mm.Groups[1].Value; if ($rev -and -not $o.ids.ContainsKey($k)) { [void]$o.reverted.Add($k) }; if (-not $o.ids.ContainsKey($k)) { $o.ids[$k] = $h } }
            }
            foreach ($f in @(& git -C $repo ls-tree --name-only "${br}:docs/changes" 2>$null)) { if ($f -match '^(.+)\.md$') { [void]$o.changes.Add($Matches[1]) } }
            $o.ok = $true
        }
    }
}

# ---------- orders ----------
$alive = @('pending', 'running'); $waitJ = @('waiting-approval', 'needs-human'); $aside = @('quarantined', 'failed')
function Is-Code($j) { @($j.steps | Where-Object { [string]$_.script -match 'merge\.ps1$' }).Count -gt 0 }
function Order-Fact([string]$jid) {
    $j = $jobs[$jid]; if (-not $j) { return @{ id = $jid; status = 'missing'; proof = ''; note = 'no job file' } }
    $st = [string]$j.status; $proof = ''; $note = ''
    if ($st -eq 'done') {
        if (Is-Code $j) {
            $rp = Get-RepoProof (Repo-Of $j)
            if ($rp.ok -and $rp.ids.ContainsKey($jid)) { $proof = "commit $($rp.ids[$jid]) on $($rp.branch)" } else { $note = 'done, but no commit on main names it' }
        } else { $proof = "order finished ($([string]$j.recipe))" }
    }
    if ($closed[$jid]) { $note = $closed[$jid].reason; if ($closed[$jid].proof) { $proof = "closed as done another way: $($closed[$jid].proof)" } }
    @{ id = $jid; status = $st; recipe = [string]$j.recipe; created = [string]$j.created; proof = $proof; note = $note; replacedBy = [string]$replacedBy[$jid]; approval = [string]$j.approval }
}
# follow replacements to the end (cycle-safe)
function Chain([string[]]$start) {
    $seen = [Collections.Generic.List[string]]::new()
    # the starting orders oldest first, each followed by its replacements in order (a replacement can be older than what it replaces)
    $first = @($start | Where-Object { $_ } | Sort-Object { $c = Utc $jobs[$_].created; if ($c) { $c } else { [DateTime]::MaxValue } })
    foreach ($s in $first) { $x = $s; while ($x -and -not $seen.Contains($x)) { $seen.Add($x); $x = $replacedBy[$x] } }
    @($seen | ForEach-Object { Order-Fact $_ })
}
function State-Of($chain) {
    if (-not $chain.Count) { return 'not-started' }
    if ($chain | Where-Object { $_.proof }) { return 'shipped' }
    $last = $chain[-1]
    if ($last.status -in $waitJ) { return 'waiting-on-jordan' }
    if ($last.status -in $alive) { return 'moving' }
    if ($last.status -in $aside) { return 'stuck' }
    if ($claimedDone[$last.id]) { return 'claimed' }
    if ($closed[$last.id] -and $closed[$last.id].dropped) { return 'dropped' }
    'lost'
}
function Owner-Of([string]$state) { switch ($state) { 'waiting-on-jordan' { 'Jordan' } 'moving' { 'kitchen' } 'stuck' { 'Claude' } 'lost' { 'Claude' } 'claimed' { 'Claude' } 'not-started' { 'kitchen' } default { '' } } }

# ---------- items ----------
$items = [Collections.Generic.List[object]]::new(); $inChain = [Collections.Generic.HashSet[string]]::new()
# an idea's orders: its job, any order whose goal carries "(Idea I12:" (ideas.ps1 Build), then their replacements
$byIdea = @{}
foreach ($j in $jobs.Values) { $m = [regex]::Match([string]$j.vars.goal, '\(Idea (I\d+):'); if ($m.Success) { $k = $m.Groups[1].Value; if (-not $byIdea[$k]) { $byIdea[$k] = [Collections.Generic.List[string]]::new() }; $byIdea[$k].Add([string]$j.id) } }
foreach ($i in $ideas) {
    $iid = [string]$i.id
    $start = @(@([string]$i.job) + @($byIdea[$iid]) | Where-Object { $_ } | Select-Object -Unique)
    $chain = @(Chain $start); foreach ($c in $chain) { [void]$inChain.Add($c.id) }
    $state = State-Of $chain; $proof = (@($chain | Where-Object proof | ForEach-Object { "$($_.id): $($_.proof)" }) -join '; ')
    $why = ''
    if ($links[$iid]) { $state = 'shipped'; $proof = "linked: $($links[$iid].proof) ($($links[$iid].why))" }
    elseif ($state -ne 'shipped' -and [string]$i.status -eq 'dropped') {
        if ($jordanDrop[$iid]) { $state = 'dropped'; $why = 'you dropped it in Chef' }
        elseif (-not $chain.Count) { $state = 'lost'; $why = 'marked dropped, but not by you, and never built' }
    }
    if ($state -eq 'lost' -and -not $why) { $last = $chain[-1]; $why = "its last order $($last.id) was $($last.status)$(if ($last.note) { ' (' + $last.note + ')' }) and nothing replaced it" }
    if ($state -eq 'claimed') { $why = "order $($chain[-1].id) was closed as done another way ($($chain[-1].note)), with no proof linked" }
    if ($state -eq 'dropped' -and -not $why -and $chain.Count) { $c = $closed[$chain[-1].id]; $why = if ($c.by -eq 'Jordan') { 'you dropped it in Chef' } else { "dropped by $(if ($c.by) { $c.by } else { 'the kitchen' }), not by you: $($c.reason)" } }
    if ($state -eq 'stuck') { $why = "order $($chain[-1].id) is set aside" }
    if ($state -eq 'waiting-on-jordan') { $why = "order $($chain[-1].id) waits for your yes" }
    $since = if ($chain.Count) { $c = $chain[-1]; if ($closed[$c.id]) { $closed[$c.id].at } else { $c.created } } else { [string]$i.at }
    $items.Add([ordered]@{ id = $iid; kind = 'idea'; title = [string]$i.title; from = [string]$i.source; jordans = ([string]$i.source -like 'Jordan*'); score = [int]$i.score; size = [string]$i.size
            state = $state; owner = (Owner-Of $state); why = $why; proof = $proof; listed = [string]$i.status; since = $since; ageDays = (Days $since); chain = @($chain) })
}
# orders that belong to no idea (direct orders, roadmap items, Claude's orders) and are not finished
foreach ($j in $jobs.Values) {
    $jid = [string]$j.id; if ($inChain.Contains($jid)) { continue }
    $st = [string]$j.status; if ($st -notin ($alive + $waitJ + $aside)) { continue }
    if ($j.parent) { continue }   # sub-orders show under their parent
    $chain = @(Chain @($jid)); $state = State-Of $chain
    if ($state -eq 'shipped') { continue }
    $since = [string]$j.created
    $items.Add([ordered]@{ id = $jid; kind = 'order'; title = ([string]$j.name -replace '^improve:\s*', ''); from = [string]$j.recipe; jordans = $false; score = 0; size = ''
            state = $state; owner = (Owner-Of $state); why = $(switch ($state) { 'waiting-on-jordan' { 'waits for your yes' } 'stuck' { 'set aside' } default { '' } }); proof = ''; listed = $st; since = $since; ageDays = (Days $since); chain = @($chain) })
}

# ---------- roadmaps (repos that opt in) ----------
$programs = [Collections.Generic.List[object]]::new(); $towerFindings = [Collections.Generic.List[object]]::new()
$repos = @($jobs.Values | ForEach-Object { Repo-Of $_ }) + @($kitchenRepo.TrimEnd('\', '/')) | Select-Object -Unique
. (Join-Path $PSScriptRoot 'roadmap-lib.ps1')
# the Sites registry (kitchen.json "sites", TD-7's; read here by site-registry.ps1): one that will not read is a finding, never a guess
$siteReg = $null; try { $siteReg = Get-SiteList (Read-SiteRegistry $root) } catch { $towerFindings.Add([ordered]@{ id = 'kitchen.json'; rule = 'sites-registry-unreadable'; owner = 'Claude'; pri = 2; say = "The Sites registry could not be read ($($_.Exception.Message)); programs are grouped by each Tower's own Site only." }) }
# One Tower's program and its open roadmap items, or a throw. Its Site: the Tower's kitchen.repo.json "site", else its Blueprint's
# site block, else the registry entry listing it; '' = none.
function Read-TowerProgram([string]$repo) {
    $cfg = Get-RepoConfig $repo
    if (-not $cfg.Roadmap) { return $null }
    $rm = Get-Roadmap $repo
    $site = [string]$cfg.Site; if (-not $site -and $rm.Site) { $site = [string]$rm.Site.code }; if (-not $site) { $site = Find-RegistrySite $siteReg $repo }
    $rp = Get-RepoProof $repo
    $st = @(Get-RoadmapState $rm $root)
    $done = 0; $open = [Collections.Generic.List[object]]::new()
    foreach ($s in $st) {
        $rid = [string]$s.id
        $proof = ''
        if ($rp.changes.Contains($rid)) { $proof = "docs/changes/$rid.md on $($rp.branch)" } elseif ($rp.ids.ContainsKey($rid)) { $proof = "commit $($rp.ids[$rid]) on $($rp.branch)" } elseif ($s.state -eq 'merged') { $proof = 'roadmap: merged' }
        if ($links[$rid]) { $proof = "linked: $($links[$rid].proof)" }
        $state = if ($proof) { 'shipped' } else { switch ($s.state) { 'cooking' { 'moving' } 'set-aside' { 'stuck' } 'owner-only' { 'not-started' } 'blocked' { 'not-started' } default { 'not-started' } } }
        if ($state -eq 'moving' -and $jobs[[string]$s.job] -and [string]$jobs[[string]$s.job].status -in $waitJ) { $state = 'waiting-on-jordan' }
        if ($state -eq 'shipped') { $done++; continue }
        $why = switch ($s.state) { 'blocked' { "waits for $(@($s.blockers) -join ', ')" } 'owner-only' { 'an owner step (protected files)' } 'cooking' { "order $($s.job)" } 'set-aside' { "order $($s.job) is set aside" } default { 'ready to build' } }
        $open.Add([ordered]@{ id = $rid; kind = 'roadmap'; title = [string]$s.title; from = (Split-Path $repo -Leaf); jordans = $false; score = 0; size = [string]$s.item.size
                state = $state; owner = (Owner-Of $state); why = $why; proof = ''; listed = [string]$s.state; since = ''; ageDays = $null; wave = [string]$s.wave; chain = @(if ($s.job) { Order-Fact ([string]$s.job) }) })
    }
    $prog = [ordered]@{ repo = (Split-Path $repo -Leaf); total = $st.Count; shipped = $done; stuck = @($open | Where-Object { $_.state -eq 'stuck' }).Count }
    if ($site) { $prog.site = $site }   # (no Site, no key: the program line reads exactly as before Sites)
    @{ program = $prog; items = @($open) }
}
# One unreadable Tower (a damaged kitchen.repo.json or Blueprint, a path git cannot read) is a named finding; the other Towers still
# report (TD-5; before, a bad Blueprint vanished silently and a bad path stopped the whole Ledger).
foreach ($repo in $repos) {
    try {
        if (-not (Test-Path -LiteralPath $repo)) { continue }
        $tp = Read-TowerProgram $repo; if (-not $tp) { continue }
        foreach ($it in $tp.items) { $items.Add($it) }; $programs.Add($tp.program)
    } catch { $towerFindings.Add([ordered]@{ id = (Tower-Name $repo); rule = 'tower-unreadable'; owner = 'Claude'; pri = 2; say = "Could not read the Tower $(Tower-Name $repo) ($($_.Exception.Message -replace '[\x00-\x1f]', '?')); its Floors are missing from the Ledger, the other Towers still report." }) }
}
# grouped by Site when any Tower has one: Sites by code, then the Towers with none, each by name; with no Site the order is unchanged
if (@($programs | Where-Object { $_.Contains('site') }).Count) { $programs = [Collections.Generic.List[object]]@($programs | Sort-Object { if ($_.Contains('site')) { "0$($_.site)" } else { '1' } }, { [string]$_.repo }) }

# ---------- drift between systems ----------
$drift = [Collections.Generic.List[object]]::new()
foreach ($it in $items) {
    if ($it.kind -ne 'idea') { continue }
    if ($it.listed -eq 'failed' -and $it.state -eq 'shipped') { $drift.Add(@{ id = $it.id; what = "the idea list says failed, but it shipped ($($it.proof))" }) }
    if ($it.listed -eq 'merged' -and $it.state -ne 'shipped') { $drift.Add(@{ id = $it.id; what = "the idea list says merged, but no proof was found ($($it.why))" }) }
}
foreach ($j in $jobs.Values) {
    if ([string]$j.status -ne 'done' -or -not (Is-Code $j) -or $j.parent) { continue }
    $rp = Get-RepoProof (Repo-Of $j)
    if ($rp.ok -and -not $rp.ids.ContainsKey([string]$j.id)) { $drift.Add(@{ id = [string]$j.id; what = "order finished, but no commit on main in $(Tower-Name (Repo-Of $j)) names it" }) }
}

# ---------- flags (each with an owner and a plain sentence) ----------
$flags = [Collections.Generic.List[object]]::new()
foreach ($it in $items) {
    $a = $it.ageDays
    if ($it.state -eq 'lost') { $flags.Add([ordered]@{ id = $it.id; rule = 'lost'; owner = 'Claude'; pri = $(if ($it.jordans) { 1 } else { 3 }); say = "$($it.title): lost. $($it.why)." }) }
    elseif ($it.state -eq 'dropped' -and $it.why -match 'not by you') { $flags.Add([ordered]@{ id = $it.id; rule = 'dropped-not-by-you'; owner = 'Jordan'; pri = 2; say = "$($it.title): $($it.why). Keep it dropped or build it again?" }) }
    elseif ($it.state -eq 'claimed') { $flags.Add([ordered]@{ id = $it.id; rule = 'claimed-no-proof'; owner = 'Claude'; pri = 2; say = "$($it.title): said to be done another way, but no proof is linked. Link the commit or re-open it." }) }
    elseif ($it.state -eq 'waiting-on-jordan' -and $a -ne $null -and $a -ge 0.5) { $flags.Add([ordered]@{ id = $it.id; rule = 'waiting-on-you'; owner = 'Jordan'; pri = 1; say = "$($it.title): waiting on you for $([math]::Round($a, 1)) days." }) }
    elseif ($it.state -eq 'stuck' -and $a -ne $null -and $a -ge 1) { $flags.Add([ordered]@{ id = $it.id; rule = 'stuck'; owner = 'Claude'; pri = 2; say = "$($it.title): set aside for $([math]::Round($a)) days, nobody on it." }) }
    elseif ($it.kind -eq 'idea' -and $it.jordans -and $it.state -eq 'not-started' -and $a -ne $null -and $a -ge 3) { $flags.Add([ordered]@{ id = $it.id; rule = 'your-idea-waiting'; owner = 'kitchen'; pri = 1; say = "Your idea '$($it.title)' has waited $([math]::Round($a)) days." }) }
    elseif ($it.kind -eq 'idea' -and $it.state -eq 'not-started' -and $it.score -ge 90 -and $a -ne $null -and $a -ge 7) { $flags.Add([ordered]@{ id = $it.id; rule = 'valuable-waiting'; owner = 'kitchen'; pri = 3; say = "'$($it.title)' (score $($it.score)) has waited $([math]::Round($a)) days." }) }
}
foreach ($d in $drift) { $flags.Add([ordered]@{ id = $d.id; rule = 'drift'; owner = 'Claude'; pri = 2; say = "$($d.id): $($d.what)." }) }
# ---------- the lobe's decisions (ZG-25): <lobe home>\flags.json, written whole by zeitgeistd `decisions run` ----------
# A decision ready for the Owner, or a post-mortem due, is a wait on him like waiting-on-you: one flag each (owner Jordan, pri 2), counted in
# the top line. Ids, days and dates only: the question text stays on the World tab. A missing file is "unknown" (null counts), never a made-up
# zero; an unreadable one is also a flag for Claude. The lobe home is the Board's (server.mjs lobeFile): ZEITGEISTD_HOME, else <kitchen>\lobe.
$lobeHome = [string]$env:ZEITGEISTD_HOME; if ($lobeHome -match '^~(?=$|[\\/])') { $lobeHome = $env:USERPROFILE + $lobeHome.Substring(1) }
$lobeHome = if ($lobeHome.Trim()) { [IO.Path]::GetFullPath($lobeHome.Trim()) } else { Join-Path $root 'lobe' }
$lobeFlagsPath = Join-Path $lobeHome 'flags.json'
$lobe = [ordered]@{ ok = $false; why = ''; updated = $null; decisionsReady = $null; postMortemsDue = $null }
$decId = '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$'
# the Ledger's proof for a post-mortem: a Sign-off row (S-J<n>-...) names a work order; its merge is still on main, undone, or replaced
function Decision-Proof([string]$did) {
    if ($did -notmatch '^S-(J\d{1,5})-') { return @{ kind = 'none'; order = ''; say = 'a lobe decision, not a work order: the Ledger has no proof for it' } }
    $jid = $Matches[1]
    if ($undone[$jid]) { $u = Utc $undone[$jid]; return @{ kind = 'undone'; order = $jid; say = "undone: the merge of $jid was reversed$(if ($u) { ' on ' + $u.ToString('yyyy-MM-dd') })" } }
    if ($replacedBy[$jid]) { return @{ kind = 'replaced'; order = $jid; say = "replaced by $($replacedBy[$jid])" } }
    $j = $jobs[$jid]; if (-not $j) { return @{ kind = 'unknown'; order = $jid; say = "unknown: no work order file for $jid" } }
    $rp = Get-RepoProof (Repo-Of $j)
    if (-not $rp.ok) { return @{ kind = 'unknown'; order = $jid; say = "unknown: main in $(Tower-Name (Repo-Of $j)) could not be read" } }
    if ($rp.reverted.Contains($jid)) { return @{ kind = 'undone'; order = $jid; say = "undone: commit $($rp.ids[$jid]) on $($rp.branch) reverts it" } }
    if ($rp.ids.ContainsKey($jid)) { return @{ kind = 'on-main'; order = $jid; say = "still on main: commit $($rp.ids[$jid]) on $($rp.branch)" } }
    @{ kind = 'unknown'; order = $jid; say = "unknown: no commit on $($rp.branch) names $jid" }
}
# flags.json as a table, or a fixed-words reason why not (never the file's own text)
function Read-LobeFlags([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return @{ why = 'no flags.json yet (the lobe writes it on its decisions run)'; missing = $true } }
    $fi = Get-Item -LiteralPath $p
    if ($fi.PSIsContainer) { return @{ why = 'flags.json cannot be read (it is not a file)' } }
    if ($fi.Length -gt 1MB) { return @{ why = 'flags.json cannot be read (it is over 1 MB)' } }
    $lf = try { ReadJson $p } catch { $null }
    if ($lf -isnot [Collections.IDictionary]) { return @{ why = 'flags.json cannot be read (it is not JSON)' } }
    if (-not $lf.Contains('decisionReady') -or -not $lf.Contains('postMortemDue')) { return @{ why = 'flags.json cannot be read (it has no decisionReady or postMortemDue list)' } }
    @{ doc = $lf }
}
$lfr = Read-LobeFlags $lobeFlagsPath; $lf = $lfr.doc; $lobe.why = [string]$lfr.why
if ($lf) {
    $lobe.ok = $true; $lobe.updated = [string]$lf.updated
    foreach ($d in @($lf.decisionReady | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_.id -match $decId })) {
        $did = [string]$d.id
        $flags.Add([ordered]@{ id = $did; rule = 'decision-ready'; owner = 'Jordan'; pri = 2; readyAt = [string]$d.ready_at; say = "Decision $did is ready for you: A, B, neither or ask more, on the World tab." })
    }
    foreach ($d in @($lf.postMortemDue | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_.id -match $decId -and "$($_.day)" -in '30', '60', '90' })) {
        $did = [string]$d.id; $pf = Decision-Proof $did; $by = Utc $d.expires_at; $byWords = if ($by) { ' by ' + $by.ToString('yyyy-MM-dd') } else { '' }
        $flags.Add([ordered]@{ id = $did; rule = 'post-mortem-due'; owner = 'Jordan'; pri = 2; day = [int]$d.day; dueAt = [string]$d.due_at; expiresAt = [string]$d.expires_at; proofKind = $pf.kind; proof = $pf.say; order = [string]$pf.order
                say = "Post-mortem due: $did, the day-$([int]$d.day) check. Held up, didn't, or unknown? On the World tab$byWords. Ledger: $($pf.say)." })
    }
    $lobe.decisionsReady = @($flags | Where-Object { $_.rule -eq 'decision-ready' }).Count; $lobe.postMortemsDue = @($flags | Where-Object { $_.rule -eq 'post-mortem-due' }).Count
} elseif (-not $lfr.missing) { $flags.Add([ordered]@{ id = 'flags.json'; rule = 'lobe-flags-unreadable'; owner = 'Claude'; pri = 2; say = "The lobe's $($lobe.why); decisions and post-mortems are unknown." }) }
foreach ($rp in $repoProof.GetEnumerator()) { if (-not $rp.Value.ok) { $flags.Add([ordered]@{ id = (Tower-Name $rp.Key); rule = 'repo-unreadable'; owner = 'Claude'; pri = 2; say = "Could not read main in $($rp.Key -replace '[\x00-\x1f]', '?'); its orders can't be proved." }) } }
foreach ($tf in $towerFindings) { $flags.Add($tf) }   # one unreadable Tower, or an unreadable Sites registry (TD-5)
# (scriptblock keys: a bare property name does not read the keys of an [ordered] dictionary, so "Sort-Object pri, id" left the flags in
# $jobs hashtable order, which changes from one process to the next)
$flags = @($flags | Sort-Object { [int]$_.pri }, { [string]$_.id })

$count = { param($s) @($items | Where-Object { $_.state -eq $s }).Count }
$counts = [ordered]@{ waitingOnJordan = (& $count 'waiting-on-jordan'); lost = (& $count 'lost'); claimed = (& $count 'claimed'); stuck = (& $count 'stuck'); moving = (& $count 'moving'); notStarted = (& $count 'not-started')
    shipped = (& $count 'shipped'); yourIdeasOpen = @($items | Where-Object { $_.jordans -and $_.state -notin 'shipped', 'dropped' }).Count; flags = $flags.Count; drift = $drift.Count
    decisionsReady = $lobe.decisionsReady; postMortemsDue = $lobe.postMortemsDue }
$lobeTop = if ($lobe.ok) { "$($lobe.decisionsReady) decisions ready, $($lobe.postMortemsDue) post-mortems due" } else { 'decisions unknown' }
$top = "Ledger: $($counts.waitingOnJordan) waiting on you, $lobeTop, $($counts.lost) lost, $($counts.claimed) claimed without proof, $($counts.stuck) stuck, $($counts.yourIdeasOpen) of your ideas open, $($counts.moving) moving, $($counts.shipped) shipped"
$doc = [ordered]@{ ok = $true; updated = $now.ToString('o'); top = $top; counts = $counts; lobe = $lobe; programs = @($programs); flags = @($flags); drift = @($drift)
    items = @($items | Sort-Object @{ e = { @('waiting-on-jordan', 'lost', 'claimed', 'stuck', 'moving', 'not-started', 'shipped', 'dropped', 'replaced').IndexOf($_.state) } }, @{ e = { -[int]$_.jordans } }, @{ e = { -[int]$_.score } }, { [string]$_.id }) }
# one line per Site (its Towers' programs added up), only when a Tower has a Site: no Site, no "sites" key (ledger.json as before)
function Get-ProgramSum($Programs, [string]$Key) { $n = 0; foreach ($p in $Programs) { $n += [int]$p[$Key] }; $n }
$progSites = @($programs | Where-Object { $_.Contains('site') } | ForEach-Object { [string]$_.site } | Sort-Object -Unique)
if ($progSites.Count) {
    $doc.sites = @(foreach ($sc in $progSites) {
            $ps = @($programs | Where-Object { $_.Contains('site') -and $_.site -ceq $sc }); $sn = @($siteReg | Where-Object { $_ -and $_.code -ceq $sc } | ForEach-Object { $_.name }) | Select-Object -First 1
            [ordered]@{ site = $sc; name = $(if ($sn) { [string]$sn } else { $sc }); towers = @($ps | ForEach-Object { $_.repo }); total = (Get-ProgramSum $ps 'total'); shipped = (Get-ProgramSum $ps 'shipped'); stuck = (Get-ProgramSum $ps 'stuck') }
        })
}

if ($Action -eq 'show') {
    $it = $doc.items | Where-Object { $_.id -ieq $Id } | Select-Object -First 1
    if (-not $it) { Fail "nothing named $Id in the ledger (shipped orders that belong to no idea are not listed)" }
    if ($Json) { $it | ConvertTo-Json -Depth 6 -Compress } else { Write-Output "$($it.id) [$($it.kind)] $($it.title): $($it.state)$(if ($it.why) { ' - ' + $it.why })"; if ($it.proof) { Write-Output "  proof: $($it.proof)" }; foreach ($c in $it.chain) { Write-Output "  $($c.id) $($c.status)$(if ($c.proof) { ' proof: ' + $c.proof })$(if ($c.note) { ' (' + $c.note + ')' })$(if ($c.replacedBy) { ' -> ' + $c.replacedBy })" } }
    exit 0
}

# build: write ledger.json and the heartbeat (the meta-check reads watch\*.json)
Write-Atomic $outPath $doc
$wd = Join-Path $root 'watch'; New-Item -ItemType Directory -Force -Path $wd | Out-Null
Write-Atomic (Join-Path $wd 'ledger.json') ([ordered]@{ name = 'ledger'; lastRun = $now.ToString('o'); checked = $items.Count; found = $flags.Count; ms = [int]([DateTime]::UtcNow - $now).TotalMilliseconds; everyMin = 5 })
if ($Action -eq 'flags') { if ($Json) { @{ ok = $true; flags = @($flags) } | ConvertTo-Json -Depth 4 -Compress } else { $flags | ForEach-Object { "[$($_.owner)] $($_.say)" } }; exit 0 }
if ($Json) { @{ ok = $true; top = $top; counts = $counts } | ConvertTo-Json -Compress } elseif (-not $Quiet) { Write-Output $top }
exit 0
