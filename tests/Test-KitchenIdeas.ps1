# Tests for the self-improvement loop (kitchen/ideas.ps1): research IDEA lines filed and de-duplicated, Jordan's ideas first, the
# autopilot's limits (live only, one build at a time, pauses while changes wait for Jordan, daily cap, paused switch, never Large on
# its own), builds on the Google plan, idea status follows its job, and the coach files a pipeline idea after enough builds.
# Nothing is cooked (no supervisor tick). Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$ip = Join-Path $kd 'ideas.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-ideas-' + [guid]::NewGuid().ToString('N'))
$save = @{}; foreach ($n in 'BRAIN_KITCHEN', 'KITCHEN_LIVE', 'KITCHEN_FROM_CHEF') { $save[$n] = [Environment]::GetEnvironmentVariable($n) }
$env:BRAIN_KITCHEN = $root; $env:KITCHEN_LIVE = $null; $env:KITCHEN_FROM_CHEF = $null
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function I { (& $ip @args -Json | Out-String) | ConvertFrom-Json }
function Ideas { @((Get-Content (Join-Path $root 'ideas.json') -Raw | ConvertFrom-Json).items) }
function Jobs { @(Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }) }
function Set-Job([string]$id, [string]$status) { $p = Join-Path $root "jobs\$id.json"; $j = Get-Content $p -Raw | ConvertFrom-Json -AsHashtable; $j.status = $status; $j | ConvertTo-Json -Depth 12 | Set-Content $p }
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $f = Join-Path $root 'research.md'
    Set-Content $f @'
Summary of findings.
IDEA: {"title":"Reflection step","goal":"Add a self-review step to kitchen/recipes/improve.json before commit.","why":"Fewer reworks","size":"S","value":9,"source":"https://example.com/a"}
- IDEA: {"title":"Swipe to approve","goal":"Let Jordan swipe right on a Needs-you row in pass-app/public/app.js to approve.","why":"Faster","size":"M","value":6,"source":"https://example.com/b"}
IDEA: {"title":"Rewrite everything","goal":"Port the whole kitchen to another language entirely.","why":"?","size":"L","value":10}
IDEA: {not json}
IDEA: {"title":"x","goal":"too short"}
SOURCES
'@
    & $ip harvest -From $f -Source 'research: agents' | Out-Null
    Check 'harvest: valid IDEA lines filed, junk skipped' ((Ideas).Count -eq 3 -and (Ideas)[0].source -eq 'research: agents' -and (Ideas)[0].status -eq 'new')
    & $ip harvest -From $f | Out-Null
    Check 'harvest: the same idea is never filed twice' ((Ideas).Count -eq 3)
    # four research teams finishing at the same moment: every idea kept, no id handed out twice
    $procs = foreach ($n in 1..4) {
        $g = Join-Path $root "race$n.md"
        Set-Content $g ("IDEA: {""title"":""Race idea $n alpha"",""goal"":""Goal text number $n for a parallel harvest check."",""size"":""S"",""value"":5}`n" + "IDEA: {""title"":""Race idea $n beta"",""goal"":""Second goal text number $n for a parallel harvest check."",""size"":""S"",""value"":5}")
        Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $ip, 'harvest', '-From', $g) -NoNewWindow -PassThru
    }
    $procs | Wait-Process -Timeout 120
    $all = Ideas
    Check 'harvest: teams finishing together never overwrite each other' ($all.Count -eq 11 -and @($all.id | Sort-Object -Unique).Count -eq 11)
    Set-Content (Join-Path $root 'empty.md') 'nothing here'
    & $ip harvest -From (Join-Path $root 'empty.md') | Out-Null
    Check 'harvest: research with no ideas fails the step' ($LASTEXITCODE -eq 1)
    # source Jordan is what may auto-merge, so it is never a default and only Chef (KITCHEN_FROM_CHEF=1 on its own call) may claim it
    $cl = I add -Title 'Filed by a session' -Goal 'An idea a Claude session filed without saying who it came from.'
    Check 'add: no -Source is not Jordan (no top score)' ($cl.ok -and $cl.idea.source -eq 'cli' -and [int]$cl.idea.score -ne 100)
    $fake = I add -Title 'Claims to be Jordan' -Goal 'A script that says it is Jordan without being Chef.' -Source Jordan
    Check 'add: -Source Jordan outside Chef is refused' (-not $fake.ok -and -not @(Ideas | Where-Object { $_.title -eq 'Claims to be Jordan' }).Count)
    Set-Content (Join-Path $root 'jh.md') 'IDEA: {"title":"Harvest says Jordan","goal":"A research line that claims to be from Jordan.","size":"S","value":5}'
    & $ip harvest -From (Join-Path $root 'jh.md') -Source Jordan | Out-Null
    Check 'harvest: never files an idea as Jordan''s' (@(Ideas | Where-Object { $_.title -eq 'Harvest says Jordan' })[0].source -eq 'research')
    $null = I drop -Id @(Ideas | Where-Object { $_.title -eq 'Harvest says Jordan' })[0].id; $null = I drop -Id $cl.idea.id
    $env:KITCHEN_FROM_CHEF = '1'
    $a = I add -Title 'Dark mode toggle' -Goal 'Add a light and dark switch in Settings of pass-app.' -Source Jordan
    $env:KITCHEN_FROM_CHEF = $null
    Check 'add: Jordan''s idea goes to the top' ($a.ok -and $a.idea.score -eq 100 -and $a.idea.source -eq 'Jordan')
    Check 'add: too short refused' (-not (I add -Title 'ab' -Goal 'short').ok)

    Check 'auto: AI cooks off -> nothing built' ((I auto).why -match 'off' -and -not (Jobs).Count)
    Set-Content (Join-Path $root 'LIVE') 'test'
    $r = I auto
    $j = @(Jobs)
    Check 'auto: builds Jordan''s idea first, as an Improve order' ($r.built.idea -eq $a.idea.id -and $j.Count -eq 1 -and $j[0].name -like 'improve:*')
    Check 'auto: on the Google plan (antigravity), never Claude quota' (@($j[0].steps | Where-Object { $_.station -eq 'agent' -and $_.args.Supplier -ne 'antigravity' }).Count -eq 0)
    Check 'auto: the merge still waits for Jordan' (@($j[0].steps | Where-Object { $_.approve }).Count -ge 1)
    Check 'auto: idea marked building with its job' (@(Ideas | Where-Object { $_.id -eq $a.idea.id })[0].status -eq 'building')
    Check 'auto: one build at a time' ((I auto).why -match 'already cooking')
    Set-Job $j[0].id 'waiting-approval'
    $r = I auto
    Check 'auto: next idea while the first waits for Jordan' ($r.built.idea -and (Jobs).Count -eq 2)
    Set-Job (@(Jobs) | Sort-Object { [int]$_.id.Substring(1) } | Select-Object -Last 1).id 'waiting-approval'
    Check 'auto: pauses while 2 changes wait for Jordan' ((I auto).why -match 'waiting for your yes')
    Set-Job $j[0].id 'done'
    $null = I list
    Check 'sync: a merged job marks its idea merged' (@(Ideas | Where-Object { $_.id -eq $a.idea.id })[0].status -eq 'merged')
    # no silent endings: an idea whose order failed moves on when that order is re-cooked (close -ReplacedBy) and the new one lands
    $second = (@(Jobs) | Sort-Object { [int]$_.id.Substring(1) } | Select-Object -Last 1); $sIdea = @(Ideas | Where-Object { $_.job -eq $second.id })[0]
    Set-Job $second.id 'quarantined'; $null = I list
    Check 'sync: a set-aside order marks its idea failed' (@(Ideas | Where-Object { $_.id -eq $sIdea.id })[0].status -eq 'failed')
    $jp = Join-Path $root "jobs\$($second.id).json"; $jj = Get-Content $jp -Raw | ConvertFrom-Json -AsHashtable; $jj.status = 'closed'; $jj.replacedBy = $j[0].id; $jj | ConvertTo-Json -Depth 8 | Set-Content $jp -Encoding utf8
    $null = I list
    $after = @(Ideas | Where-Object { $_.id -eq $sIdea.id })[0]
    Check 'sync: a failed idea follows its replacement and is merged when it lands' ($after.status -eq 'merged' -and $after.job -eq $j[0].id)
    # the Ledger's proof wins over a stale status: a failed idea the Ledger proves shipped is merged, with the proof; no proof, no change
    $fid = (@(Ideas | Where-Object { $_.status -eq 'new' })[0]).id
    $ideasPath = Join-Path $root 'ideas.json'; $doc = Get-Content $ideasPath -Raw | ConvertFrom-Json -AsHashtable; foreach ($x in $doc.items) { if ($x.id -eq $fid) { $x.status = 'failed' } }; $doc | ConvertTo-Json -Depth 8 | Set-Content $ideasPath -Encoding utf8
    @{ items = @(@{ id = $fid; kind = 'idea'; state = 'shipped'; proof = 'linked: abc1234 (built by hand)' }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'ledger.json') -Encoding utf8
    $null = I list
    $fx = @(Ideas | Where-Object { $_.id -eq $fid })[0]
    Check 'sync: a failed idea the Ledger proves shipped is merged, with the proof' ($fx.status -eq 'merged' -and $fx.proof -match 'abc1234')
    Remove-Item (Join-Path $root 'ledger.json')
    $r = I auto
    Check 'auto: never builds a Large idea by itself' ($r.built -and @(Ideas | Where-Object { $_.size -eq 'L' })[0].status -eq 'new')
    Check 'auto: holds while that build cooks' ((I auto).why -match 'already cooking')
    # Jordan's "build more and faster": autopilot.maxActive lets several Improve orders cook at once
    $kjBefore = if (Test-Path (Join-Path $root 'kitchen.json')) { Get-Content (Join-Path $root 'kitchen.json') -Raw } else { $null }
    Set-Content (Join-Path $root 'kitchen.json') '{"autopilot":{"maxActive":2}}'
    $null = I add -Title 'Parallel idea' -Goal 'A second change that can cook beside the first one.'
    $r2 = I auto
    Check 'auto: maxActive 2 -> a second build starts beside the first' ($r2.built.idea)
    Check 'auto: maxActive 2 -> a third waits' ((I auto).why -match 'already cooking \(limit 2\)')
    if ($null -ne $kjBefore) { Set-Content (Join-Path $root 'kitchen.json') $kjBefore } else { Remove-Item (Join-Path $root 'kitchen.json') }
    foreach ($x in @(Jobs | Where-Object { $_.status -eq 'pending' } | Select-Object -Last 1)) { Set-Job $x.id 'done' }
    $m = Get-Content (Join-Path $root 'autopilot.json') -Raw | ConvertFrom-Json -AsHashtable; $m.paused = $true; $m | ConvertTo-Json | Set-Content (Join-Path $root 'autopilot.json')
    Check 'auto: paused by Jordan' ((I auto).why -match 'paused')
    # the first tick after midnight used to rebuild the table and drop the pause (and 'scored', which wrote a 2nd trend row a minute later)
    $mid = Get-Content (Join-Path $root 'autopilot.json') -Raw | ConvertFrom-Json -AsHashtable; $mid.day = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd'); $mid.built = 3; $mid.scored = (Get-Date).ToString('yyyy-MM-dd'); $mid | ConvertTo-Json | Set-Content (Join-Path $root 'autopilot.json')
    $ra = I auto; $after = Get-Content (Join-Path $root 'autopilot.json') -Raw | ConvertFrom-Json -AsHashtable
    Check 'auto: a pause survives midnight' ($ra.why -match 'paused' -and $after.paused -eq $true -and $after.day -eq (Get-Date).ToString('yyyy-MM-dd') -and [int]$after.built -eq 0)
    Check 'auto: midnight keeps scored (one trend row a day)' ($after.scored -eq (Get-Date).ToString('yyyy-MM-dd'))
    # Chef's pause/resume go through ideas.ps1 (the ideas mutex, temp + rename) and a new day never drops Jordan's pause
    $m.paused = $false; $m | ConvertTo-Json | Set-Content (Join-Path $root 'autopilot.json')
    Check 'pause: ideas.ps1 pause sets the switch and keeps the counts' ((I pause).paused -eq $true -and (Get-Content (Join-Path $root 'autopilot.json') -Raw | ConvertFrom-Json).paused -eq $true -and $null -ne (Get-Content (Join-Path $root 'autopilot.json') -Raw | ConvertFrom-Json).day)
    $m2 = Get-Content (Join-Path $root 'autopilot.json') -Raw | ConvertFrom-Json -AsHashtable; $m2.day = '2000-01-01'; $m2 | ConvertTo-Json | Set-Content (Join-Path $root 'autopilot.json')
    Check 'pause: a new day keeps the pause' ((I auto).why -match 'paused' -and (Get-Content (Join-Path $root 'autopilot.json') -Raw | ConvertFrom-Json).paused -eq $true)
    Check 'resume: ideas.ps1 resume clears it' ((I resume).paused -eq $false -and -not (Get-Content (Join-Path $root 'autopilot.json') -Raw | ConvertFrom-Json).paused)
    $m = Get-Content (Join-Path $root 'autopilot.json') -Raw | ConvertFrom-Json -AsHashtable
    $m.paused = $false; $m.built = 4; $m | ConvertTo-Json | Set-Content (Join-Path $root 'autopilot.json')
    foreach ($x in Jobs) { Set-Job $x.id 'done' }
    $null = I add -Title 'Another one' -Goal 'Something else that is worth building soon.'
    Check 'auto: daily limit' ((I auto).why -match 'daily limit')
    $l = @(Ideas | Where-Object size -eq 'L')[0]
    $b = I build -Id $l.id
    Check 'build: Jordan can build a Large idea himself' ($b.ok -and $b.job -match '^J\d+$')
    Check 'drop: works' ((I drop -Id $l.id).ok)

    $c = I coach
    Check 'coach: files a pipeline idea after 3 builds, built from how they went' ($c.filed -and @(Ideas | Where-Object { $_.source -eq 'coach' })[0].goal -match 'Improve orders went')
    Check 'coach: once a day' (-not (I coach).filed)
    # Claude-via-Google resting -> the autopilot builds on Gemini instead (still the Google plan, never Claude quota)
    @{ antigravity = @{ restUntil = (Get-Date).ToUniversalTime().AddMinutes(30).ToString('o'); why = 'plan limit' } } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $root 'suppliers-state.json')
    $g = I add -Title 'Gemini fallback idea' -Goal 'Something to build while antigravity rests.'
    $b2 = I build -Id $g.idea.id
    $gj = Get-Content (Join-Path $root "jobs\$($b2.job).json") -Raw | ConvertFrom-Json
    Check 'build: antigravity resting -> Gemini builds it' (@($gj.steps | Where-Object { $_.station -eq 'agent' -and $_.args.Supplier -ne 'gemini' }).Count -eq 0)

    # never two changes to the same files at once: a clashing idea waits (auto) or warns (manual build)
    function Reset-Kitchen {
        foreach ($x in Jobs) { Set-Job $x.id 'done' }
        foreach ($x in @(Ideas | Where-Object { $_.status -eq 'new' })) { $null = I drop -Id $x.id }
        $mp = Join-Path $root 'autopilot.json'; $mm = Get-Content $mp -Raw | ConvertFrom-Json -AsHashtable; $mm.built = 0; $mm.paused = $false; $mm | ConvertTo-Json | Set-Content $mp
    }
    Reset-Kitchen
    $ia = I add -Title 'Hunt sheet change one' -Goal 'Rework the hunt sheet in pass-app/server.mjs and pass-app/public/app.js.'
    $ba = I build -Id $ia.idea.id
    Check 'clash: nothing running -> manual build has no warning' ($ba.ok -and -not $ba.warning)
    Set-Job $ba.job 'waiting-approval'
    $ib = I add -Title 'Hunt sheet change two' -Goal 'Also fix the hunt sheet sort in pass-app/server.mjs.'
    $before = (Jobs).Count
    $r = I auto
    Check 'clash: auto waits when a waiting order shares a file' ($r.why -match 'waiting' -and $r.why -match 'pass-app/server.mjs' -and $r.why -match $ba.job -and -not $r.built)
    Check 'clash: no order created, the idea stays new' ((Jobs).Count -eq $before -and @(Ideas | Where-Object { $_.id -eq $ib.idea.id })[0].status -eq 'new')
    $bb = I build -Id $ib.idea.id
    Check 'clash: manual build warns but still builds' ($bb.ok -and $bb.job -and $bb.warning -match 'pass-app/server.mjs' -and $bb.warning -match $ba.job)
    # A done, B waits; C clashes with B and comes first, D does not
    Set-Job $ba.job 'done'; Set-Job $bb.job 'waiting-approval'
    $ic = I add -Title 'Hunt sheet change three' -Goal 'Third change to PASS-APP/server.mjs for the hunt sheet.'
    $id = I add -Title 'Unrelated notes change' -Goal 'Tidy kitchen/notes.md headings.'
    $r = I auto
    Check 'clash: auto skips a clashing idea and builds the next one' ($r.built.idea -eq $id.idea.id -and @(Ideas | Where-Object { $_.id -eq $ic.idea.id })[0].status -eq 'new')
    Reset-Kitchen
    $ie = I add -Title 'Tests only overlap one' -Goal 'Add checks to tests/Test-Shared.ps1 and change kitchen/e.ps1.'
    $be = I build -Id $ie.idea.id
    Set-Job $be.job 'waiting-approval'
    $if = I add -Title 'Tests only overlap two' -Goal 'More checks in tests/Test-Shared.ps1 and change kitchen/f.ps1.'
    $r = I auto
    Check 'clash: a tests/* overlap does not block' ($r.built.idea -eq $if.idea.id)
    Reset-Kitchen
    $ig = I add -Title 'Done order never blocks' -Goal 'Change kitchen/e.ps1 once more.'
    $r = I auto
    Check 'clash: a done order does not block' ($r.built.idea -eq $ig.idea.id)
    Set-Job $r.built.job 'waiting-approval'
    $ih = I add -Title 'Goal naming no files' -Goal 'Make the whole kitchen a little friendlier to read.'
    $r = I auto
    Check 'clash: a goal with no paths never clashes' ($r.built.idea -eq $ih.idea.id)

    # an unreadable ideas.json is never read as empty and overwritten: the call refuses, the file stays, a .bak holds the last good copy
    $ipath = Join-Path $root 'ideas.json'; $good = Get-Content $ipath -Raw
    Check 'save: keeps ideas.json.bak' (Test-Path "$ipath.bak")
    Set-Content $ipath ($good.Substring(0, [int]($good.Length / 2))) -NoNewline; $broken = Get-Content $ipath -Raw
    & $ip list -Json 2>$null | Out-Null; $lx = $LASTEXITCODE
    & $ip auto -Json 2>$null | Out-Null; $ax = $LASTEXITCODE
    Check 'load: a damaged ideas.json fails closed and is never overwritten' ($lx -eq 1 -and $ax -eq 1 -and (Get-Content $ipath -Raw) -eq $broken)
    Set-Content $ipath $good -NoNewline
    # ids never restart: drop the newest item from the file by hand, the next idea still gets a fresh number
    $d = $good | ConvertFrom-Json -AsHashtable; $top = ($d.items | ForEach-Object { [int]([string]$_.id).Substring(1) } | Measure-Object -Maximum).Maximum
    $d.items = @($d.items | Where-Object { [int]([string]$_.id).Substring(1) -ne $top }); $d | ConvertTo-Json -Depth 8 | Set-Content $ipath
    $nx = I add -Title 'After a lost item' -Goal 'An idea filed after the newest one vanished from the list.'
    Check 'ids: never handed out twice' ($nx.ok -and [int]([string]$nx.idea.id).Substring(1) -gt $top)
    # the coach's cheap gates (once a day, every N builds) run before the ~2 s scoreboard is read, not after
    $src = Get-Content $ip -Raw; $cs = $src.IndexOf("'coach' {")
    Check 'coach: gates come before reading the board' ($src.IndexOf("'coached today already'", $cs) -lt $src.IndexOf('& $sb -Json', $cs) -and $src.IndexOf("'coached today already'", $cs) -gt 0)}
finally {
    foreach ($n in $save.Keys) { [Environment]::SetEnvironmentVariable($n, $save[$n]) }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
Write-Host "KitchenIdeas tests: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
