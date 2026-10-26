# Tests for the "map, roadmap, build" method: the roadmap contract (kitchen.repo.json "roadmap", kitchen/roadmap-lib.ps1), the goal a
# roadmap item becomes (station roadmap-item), ownership enforcement in the commit station, and kitchen/roadmap.ps1 status / next / cook
# (ordering, max, owns overlap) with a fake roadmap and fake job files. No AI and no supervisor run: cook.ps1 only queues a job in a
# scratch kitchen. Self-cleaning: scratch repos and a scratch kitchen under TEMP only (BRAIN_KITCHEN, KITCHEN_UNDER_TEST=1).
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$st = Join-Path $kd 'stations'
$roadmapPs = Join-Path $kd 'roadmap.ps1'
. (Join-Path $kd 'roadmap-lib.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('roadmap-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G([string]$r) { & git -C $r -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function Put([string]$path, [string]$text) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null; Set-Content -LiteralPath $path -Value $text -Encoding utf8 }
function Throws([scriptblock]$blk) { try { & $blk | Out-Null; '' } catch { $_.Exception.Message } }
function Run([string]$file, [string[]]$more) { $o = & pwsh -NoProfile -File $file @more 2>&1 | Out-String; [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE } }
function RmJson($obj) { $obj | ConvertTo-Json -Depth 10 }
function Item([string]$id, [string[]]$deps = @(), [string[]]$owns = @("src/$id.txt"), [bool]$ownerOnly = $false) {
    [ordered]@{ id = $id; title = "title of $id"; why = "why $id"; depends_on = @($deps); owns = @($owns); acceptance = @("$($id -replace '-', '')-1: it works")
        controls = @('C-01'); inventory_ids = @('W-01'); standards = @('STD-PY'); size = 'S'; owner_only = $ownerOnly }
}
function Job([string]$id, [string]$item, [string]$status, [string]$repo) {
    Put (Join-Path $kr "jobs\$id.json") (@{ id = $id; name = "roadmap-item: $item"; recipe = 'roadmap-item'; vars = @{ repo = $repo; item = $item }; status = $status; steps = @(@{ script = 'fake.ps1' }); history = @() } | ConvertTo-Json -Depth 6)
}
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_JOB', 'KITCHEN_RUN', 'KITCHEN_UNDER_TEST', 'KITCHEN_RECIPES', 'BRAIN_NTFY_TOPIC', 'BRAIN_AGENT_DEPTH', 'KITCHEN_AGY_EXE') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
try {
    $kr = Join-Path $root 'kitchen'; New-Item -ItemType Directory -Force -Path $kr | Out-Null
    $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_UNDER_TEST = '1'; $env:KITCHEN_JOB = $null; $env:KITCHEN_RUN = $null; $env:KITCHEN_RECIPES = $null
    $env:BRAIN_NTFY_TOPIC = $null; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_AGY_EXE = 'off'

    # ---- 1. the contract: kitchen.repo.json "roadmap" and the roadmap file, fail closed ---------------------------------------------
    $cfgDir = Join-Path $root 'cfg'; New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    function Cfg([string]$json) { Set-Content -LiteralPath (Join-Path $cfgDir 'kitchen.repo.json') -Value $json -Encoding utf8; Read-RepoConfig $cfgDir }
    Check 'config: roadmap read and normalized' ((Cfg '{"roadmap":"map\\roadmap.json"}').Roadmap -eq 'map/roadmap.json')
    Check 'config: no roadmap key = empty (not opted in)' ((Cfg '{"github":"a/b"}').Roadmap -eq '')
    $badKeys = [ordered]@{ 'absolute' = '{"roadmap":"C:/x/roadmap.json"}'; 'dot-dot' = '{"roadmap":"../roadmap.json"}'; 'wildcard' = '{"roadmap":"map/*.json"}'
        'not json' = '{"roadmap":"map/roadmap.yml"}'; 'number' = '{"roadmap":5}'; 'list' = '{"roadmap":["map/roadmap.json"]}'; 'empty' = '{"roadmap":""}' }
    foreach ($b in $badKeys.GetEnumerator()) {
        $m = Throws { Cfg $b.Value }
        Check "config: bad roadmap key fails closed: $($b.Key)" ($m -match 'kitchen\.repo\.json' -and $m -match 'roadmap')
    }
    $rmFile = Join-Path $root 'rm.json'
    function Road($obj) { Set-Content -LiteralPath $rmFile -Value $(if ($obj -is [string]) { $obj } else { RmJson $obj }) -Encoding utf8; Read-Roadmap $rmFile }
    $good = @{ waves = @(@{ id = 'W1'; goal = 'first'; items = @((Item 'B-01'), (Item 'B-02' @('B-01'))) }, @{ id = 'W2'; goal = 'second'; items = @((Item 'B-03' @('B-02') @('lib/', 'tests/**/test_b03*.py'))) }) }
    $r = Road $good
    Check 'roadmap: good file reads (waves, items in order, wave on each item)' ($r.Waves.Count -eq 2 -and ($r.Items.id -join ',') -eq 'B-01,B-02,B-03' -and $r.ById['b-03'].wave -eq 'W2')
    Check 'roadmap: fields carried (owns, acceptance, standards, owner_only)' (($r.ById['B-03'].owns -join '|') -eq 'lib/|tests/**/test_b03*.py' -and $r.ById['B-01'].acceptance.Count -eq 1 -and $r.ById['B-01'].standards[0] -eq 'STD-PY' -and $r.ById['B-01'].owner_only -eq $false)
    $min = Road '{"waves":[{"id":"W1","goal":"g","items":[{"id":"B-01","title":"t","why":"w","depends_on":[],"owns":["a.txt"],"acceptance":["x"]}]}]}'
    Check 'roadmap: optional fields default (controls, standards empty; not owner_only)' ($min.Items[0].controls.Count -eq 0 -and $min.Items[0].standards.Count -eq 0 -and -not $min.Items[0].owner_only)
    $bad = [ordered]@{
        'not JSON'               = '{ "waves": '
        'no waves'               = '{}'
        'waves empty'            = '{"waves":[]}'
        'waves is an object'     = '{"waves":{"id":"W1"}}'
        'wave without id'        = '{"waves":[{"goal":"g","items":[]}]}'
        'wave without goal'      = '{"waves":[{"id":"W1","items":[]}]}'
        'wave without items'     = '{"waves":[{"id":"W1","goal":"g"}]}'
        'duplicate wave'         = '{"waves":[{"id":"W1","goal":"g","items":[]},{"id":"w1","goal":"g","items":[]}]}'
    }
    foreach ($b in $bad.GetEnumerator()) { $m = Throws { Road $b.Value }; Check "roadmap: bad file fails closed: $($b.Key)" ($m -match '^roadmap \(' -and $m.Length -gt 20) }
    function Broken([scriptblock]$change) { $it = Item 'B-01'; & $change $it; @{ waves = @(@{ id = 'W1'; goal = 'g'; items = @($it, (Item 'B-02')) }) } }
    $badItems = [ordered]@{
        'bad id'                 = { param($i) $i.id = 'item one' }
        'no title'               = { param($i) $i.Remove('title') }
        'empty why'              = { param($i) $i.why = ' ' }
        'no depends_on'          = { param($i) $i.Remove('depends_on') }
        'depends_on a string'    = { param($i) $i.depends_on = 'B-02' }
        'unknown dependency'     = { param($i) $i.depends_on = @('B-77') }
        'depends on itself'      = { param($i) $i.depends_on = @('B-01') }
        'no owns'                = { param($i) $i.Remove('owns') }
        'owns empty'             = { param($i) $i.owns = @() }
        'owns absolute'          = { param($i) $i.owns = @('C:/Windows/x') }
        'owns leaves the repo'   = { param($i) $i.owns = @('../other/x.py') }
        'owns a number'          = { param($i) $i.owns = @(5) }
        'no acceptance'          = { param($i) $i.Remove('acceptance') }
        'acceptance empty'       = { param($i) $i.acceptance = @() }
        'standards a string'     = { param($i) $i.standards = 'STD-PY' }
        'owner_only a string'    = { param($i) $i.owner_only = 'yes' }
        'size a number'          = { param($i) $i.size = 3 }
        'duplicate id'           = { param($i) $i.id = 'B-02' }
    }
    foreach ($b in $badItems.GetEnumerator()) { $m = Throws { Road (Broken $b.Value) }; Check "roadmap: bad item fails closed: $($b.Key)" ($m -match '^roadmap \(' -and $m -match "item|B-0") }
    $cyc = @{ waves = @(@{ id = 'W1'; goal = 'g'; items = @((Item 'B-01' @('B-03')), (Item 'B-02' @('B-01')), (Item 'B-03' @('B-02'))) }) }
    Check 'roadmap: a dependency cycle fails closed' ((Throws { Road $cyc }) -match 'cycle')
    Check 'roadmap: a missing file fails closed' ((Throws { Read-Roadmap (Join-Path $root 'nope.json') }) -match 'not found')
    $gw = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'demo-project\map\roadmap.json')
    if (Test-Path -LiteralPath $gw) { $g = $null; $m = Throws { $script:g = Read-Roadmap $gw }; Check "roadmap: Demo Project's real roadmap reads ($m)" (-not $m) }

    # ---- 1b. the optional Site block and display ids (multi-site TD-1): displayed words only, stored ids unchanged ----------------------
    $plain = Road $good
    Check 'site: no site block = Site is null, every id shows as stored' ($null -eq $plain.Site -and (Get-SiteDisplayId $plain 'B-01') -ceq 'B-01' -and (Get-SiteDisplayId $null 'B-42') -ceq 'B-42' -and (Get-SiteDisplayId $plain 'b-07') -ceq 'b-07')
    $sited = $good.Clone(); $sited['site'] = [ordered]@{ code = 'GW'; name = 'Demo Project'; id_prefix = 'B' }
    $gwr = Road $sited
    Check 'site: no site block reads exactly like the same file with one (waves, items, goal text)' ((RmJson $plain.Waves) -ceq (RmJson $gwr.Waves) -and (RmJson $plain.Items) -ceq (RmJson $gwr.Items) -and (Get-RoadmapGoal $plain.ById['B-03'] $plain.Waves[1]) -ceq (Get-RoadmapGoal $gwr.ById['B-03'] $gwr.Waves[1]))
    Check 'site: block read (code, name, stored prefix)' ($gwr.Site.code -ceq 'GW' -and $gwr.Site.name -ceq 'Demo Project' -and $gwr.Site.id_prefix -ceq 'B')
    Check 'site: stored prefix shows the Site code (B-42 -> GW-42, digits as stored)' ((Get-SiteDisplayId $gwr 'B-42') -ceq 'GW-42' -and (Get-SiteDisplayId $gwr 'b-07') -ceq 'GW-07' -and (Get-SiteDisplayId $gwr.Site 'B-1234') -ceq 'GW-1234')
    Check 'site: other prefixes and non-ids stay as they are (NN-3, BB-1, text, empty)' ((Get-SiteDisplayId $gwr 'NN-3') -ceq 'NN-3' -and (Get-SiteDisplayId $gwr 'BB-1') -ceq 'BB-1' -and (Get-SiteDisplayId $gwr 'B 42') -ceq 'B 42' -and (Get-SiteDisplayId $gwr '') -ceq '')
    Check 'site: stored ids are untouched (items, lookup by stored id; a display id is not a stored id)' (($gwr.Items.id -join ',') -ceq 'B-01,B-02,B-03' -and (Get-RoadmapItem $gwr 'B-02').id -ceq 'B-02' -and (Throws { Get-RoadmapItem $gwr 'GW-02' }) -match 'no item')
    $tdr = Road '{"site":{"code":"TD"},"waves":[{"id":"W1","goal":"g","items":[{"id":"TD-7","title":"t","why":"w","depends_on":[],"owns":["a.txt"],"acceptance":["x"]}]}]}'
    Check 'site: no id_prefix = the code is the prefix; name defaults to the code' ($tdr.Site.id_prefix -ceq 'TD' -and $tdr.Site.name -ceq 'TD' -and (Get-SiteDisplayId $tdr 'TD-7') -ceq 'TD-7' -and (Get-SiteDisplayId $tdr 'td-7') -ceq 'TD-7' -and (Get-SiteDisplayId $tdr 'B-7') -ceq 'B-7')
    $badSite = [ordered]@{ 'a string' = 'GW'; 'a list' = @('GW'); 'no code' = @{ name = 'x' }; 'lower-case code' = @{ code = 'gw' }; 'code too long' = @{ code = 'GOWE' }
        'one-letter code' = @{ code = 'G' }; 'code a number' = @{ code = 12 }; 'empty name' = @{ code = 'GW'; name = ' ' }; 'name a number' = @{ code = 'GW'; name = 5 }
        'prefix with a dash' = @{ code = 'GW'; id_prefix = 'B-' }; 'prefix a number' = @{ code = 'GW'; id_prefix = 5 }; 'prefix too long' = @{ code = 'GW'; id_prefix = 'ABCDEFG' } }
    foreach ($b in $badSite.GetEnumerator()) { $s = $good.Clone(); $s['site'] = $b.Value; $m = Throws { Road $s }; Check "site: bad site block fails closed: $($b.Key)" ($m -match '^roadmap \(' -and $m -match 'site') }

    # ---- 2. the goal an item becomes -----------------------------------------------------------------------------------------------
    $it = $r.ById['B-03']
    $goal = Get-RoadmapGoal $it $r.Waves[1] ''
    Check 'goal: title, why, wave goal' ($goal -match '(?m)^# B-03: title of B-03' -and $goal -match 'why B-03' -and $goal -match 'second')
    Check 'goal: every owns entry and the two fragments' ($goal -match '- lib/' -and $goal -match 'tests/\*\*/test_b03\*\.py' -and $goal -match 'docs/changes/B-03\.md' -and $goal -match 'specs/B-03\.md')
    Check 'goal: acceptance, standards, controls, inventory, dependencies' ($goal -match 'B03-1: it works' -and $goal -match 'STD-PY' -and $goal -match 'C-01' -and $goal -match 'W-01' -and $goal -match 'B-02')
    Check 'goal: names docs/STANDARDS.md and the DOD in docs/ROADMAP.md' ($goal -match 'docs/STANDARDS\.md' -and $goal -match 'DOD.*docs/ROADMAP\.md')
    $docDir = Join-Path $root 'docdir'; New-Item -ItemType Directory -Force -Path $docDir | Out-Null
    Check 'goal: a repo without those docs is told its own rules instead' ((Get-RoadmapGoal $it $null $docDir) -notmatch 'STANDARDS\.md')
    Put (Join-Path $docDir 'docs\STANDARDS.md') 'x'
    Check 'goal: a repo with docs/STANDARDS.md is told to follow it' ((Get-RoadmapGoal $it $null $docDir) -match 'docs/STANDARDS\.md')

    # ---- 3. owns: what is inside, what overlaps -------------------------------------------------------------------------------------
    $o = @('src/a.py', 'lib/', 'tests/**/test_b01*.py')
    Check 'owned: an exact path' (Test-RoadmapOwned 'src/a.py' $o 'B-01')
    Check 'owned: case and backslashes do not matter' (Test-RoadmapOwned 'SRC\A.py' $o 'B-01')
    Check 'owned: anything under a folder ending in /' (Test-RoadmapOwned 'lib/deep/x.ps1' $o 'B-01')
    Check 'owned: a glob' (Test-RoadmapOwned 'tests/py/levers/test_b01_fields.py' $o 'B-01')
    Check 'not owned: a sibling file' (-not (Test-RoadmapOwned 'src/b.py' $o 'B-01'))
    Check 'not owned: a folder name without the slash is not a prefix' (-not (Test-RoadmapOwned 'library/x' $o 'B-01'))
    Check 'not owned: the glob does not reach another item''s test' (-not (Test-RoadmapOwned 'tests/py/test_b02.py' $o 'B-01'))
    Check 'fragments: docs/changes/<item>.md and specs/<item>.md are always allowed' ((Test-RoadmapOwned 'docs/changes/B-01.md' $o 'B-01') -and (Test-RoadmapOwned 'specs/B-01.md' $o 'B-01'))
    Check 'fragments: only the item''s own' (-not (Test-RoadmapOwned 'docs/changes/B-02.md' $o 'B-01') -and -not (Test-RoadmapOwned 'docs/changes/B-01.md' $o ''))
    Check 'overlap: the same file' (Test-RoadmapOwnsOverlap @('src/a.py') @('SRC/a.py'))
    Check 'overlap: a folder and a file inside it' ((Test-RoadmapOwnsOverlap @('src/') @('src/x/y.py')) -and (Test-RoadmapOwnsOverlap @('src/x/y.py') @('src/')))
    Check 'overlap: a glob and a file it matches' (Test-RoadmapOwnsOverlap @('tests/**/test_*.py') @('tests/py/test_a.py'))
    Check 'overlap: two globs under one folder' (Test-RoadmapOwnsOverlap @('src/*.py') @('src/**'))
    Check 'no overlap: different files' (-not (Test-RoadmapOwnsOverlap @('src/a.py', 'docs/a.md') @('src/b.py', 'docs/b.md')))
    Check 'no overlap: different folders' (-not (Test-RoadmapOwnsOverlap @('src/') @('lib/', 'srcx/a.py')))
    Check 'no overlap: a glob that does not match the file' (-not (Test-RoadmapOwnsOverlap @('tests/**/test_b01*.py') @('tests/py/test_b02.py')))

    # ---- 4. a real repo: station roadmap-item, ownership in the commit station ------------------------------------------------------
    $repo = Join-Path $root 'repo'
    $fix = @{ waves = @(
        @{ id = 'W1'; goal = 'first wave'; items = @(
            (Item 'B-01' @() @('src/a.txt', 'src/b/', 'tests/**/test_b01*.py')),
            (Item 'B-02' @('B-01') @('src/two.txt')),
            (Item 'B-03' @() @('owner.txt') $true),
            (Item 'B-04' @() @('src/b/c.txt')),
            (Item 'B-05' @() @('lib/')),
            (Item 'B-06' @() @('docs/x.md'))) },
        @{ id = 'W2'; goal = 'second wave'; items = @((Item 'B-07' @('B-02') @('w2.txt'))) }) }
    Put (Join-Path $repo 'map\roadmap.json') (RmJson $fix)
    Put (Join-Path $repo 'kitchen.repo.json') '{"roadmap":"map/roadmap.json","commitBudget":{"files":20,"lines":500},"github":"none/none"}'
    Put (Join-Path $repo 'README.md') 'fixture'
    & git -C $repo init -q -b main 2>&1 | Out-Null; G $repo add -A; G $repo commit -q -m init
    $rm = Get-Roadmap $repo
    Check 'Get-Roadmap: read from the main checkout via kitchen.repo.json' ($rm.Items.Count -eq 7 -and $rm.Main -eq [IO.Path]::GetFullPath($repo).TrimEnd('\'))
    [void](Cfg '{"github":"a/b"}'); Check 'Get-Roadmap: a repo that has not opted in is refused' ((Throws { Get-Roadmap $cfgDir }) -match 'no roadmap')

    $env:KITCHEN_JOB = 'J1'
    $w = Run (Join-Path $st 'worktree.ps1') @('-Repo', $repo)
    $wt = Join-Path $kr 'worktrees\J1'
    Check "worktree for J1 ($($w.Code))" ($w.Code -eq 0 -and (Test-Path (Join-Path $wt '.kitchen\BASE')))
    $s = Run (Join-Path $st 'roadmap-item.ps1') @('-Repo', $repo, '-Item', 'B-01')
    Check "station: a ready item writes ITEM.md ($($s.Code))" ($s.Code -eq 0 -and (Get-Content (Join-Path $wt '.kitchen\ITEM.md') -Raw) -match '(?m)^# B-01: title of B-01')
    Check 'station: ITEM.md carries owns and acceptance' ((Get-Content (Join-Path $wt '.kitchen\ITEM.md') -Raw) -match 'src/b/' -and (Get-Content (Join-Path $wt '.kitchen\ITEM.md') -Raw) -match 'B01-1')
    $s = Run (Join-Path $st 'roadmap-item.ps1') @('-Repo', $repo, '-Item', 'B-03')
    Check 'station: an owner_only item is refused (Jordan''s)' ($s.Code -eq 1 -and $s.Out -match 'owner_only')
    $s = Run (Join-Path $st 'roadmap-item.ps1') @('-Repo', $repo, '-Item', 'B-02')
    Check 'station: an item whose dependencies are not merged is refused' ($s.Code -eq 1 -and $s.Out -match 'blocked by B-01')
    $s = Run (Join-Path $st 'roadmap-item.ps1') @('-Repo', $repo, '-Item', 'B-99')
    Check 'station: an unknown item is refused' ($s.Code -eq 1 -and $s.Out -match "no item 'B-99'")
    $s = Run (Join-Path $st 'roadmap-item.ps1') @('-Repo', $repo, '-Item', 'x;rm')
    Check 'station: a malformed item id is refused' ($s.Code -eq 1 -and $s.Out -match 'not an item id')

    $commit = Join-Path $st 'commit.ps1'
    $head = { ([string](& git -C $wt rev-parse HEAD)).Trim() }
    Put (Join-Path $wt 'src\a.txt') 'a'; Put (Join-Path $wt 'src\b\deep.txt') 'deep'; Put (Join-Path $wt 'tests\py\test_b01_x.py') 'pass'
    $c = Run $commit @('-Message', 'B-01', '-RoadmapItem', 'B-01')
    Check "commit: changes inside the item's owns are committed ($($c.Code))" ($c.Code -eq 0 -and $c.Out -match 'inside what B-01 owns')
    Check 'commit: the message names the item and its title' ((& git -C $wt log -1 --format=%s) -match 'kitchen J1: B-01: title of B-01')
    $before = & $head
    Put (Join-Path $wt 'src\a.txt') 'a2'; Put (Join-Path $wt 'README.md') 'changed by the cook'; Put (Join-Path $wt 'src\two.txt') 'not mine'
    $c = Run $commit @('-Message', 'B-01', '-RoadmapItem', 'B-01')
    Check 'commit: a change outside the owns is REFUSED (exit 1)' ($c.Code -eq 1 -and $c.Out -match 'REFUSED' -and $c.Out -match 'README\.md' -and $c.Out -match 'src/two\.txt')
    Check 'commit: refused = nothing committed, nothing left staged' ((& $head) -eq $before -and -not @(& git -C $wt diff --cached --name-only).Count)
    Check 'commit: the owned file in the refused change is not committed either' ((& git -C $wt show HEAD:src/a.txt).Trim() -eq 'a')
    & git -C $wt checkout -q -- README.md 2>&1 | Out-Null; Remove-Item -LiteralPath (Join-Path $wt 'src\two.txt')
    Put (Join-Path $wt 'docs\changes\B-01.md') 'what changed'; Put (Join-Path $wt 'specs\B-01.md') 'spec'
    $c = Run $commit @('-Message', 'B-01', '-RoadmapItem', 'B-01')
    Check "commit: the item's fragments (docs/changes, specs) are allowed ($($c.Code))" ($c.Code -eq 0 -and (& git -C $wt ls-files 'docs/changes/B-01.md' 'specs/B-01.md').Count -eq 2)
    Put (Join-Path $wt 'docs\changes\B-02.md') 'not mine'
    $c = Run $commit @('-Message', 'B-01', '-RoadmapItem', 'B-01')
    Check "commit: another item's fragment is refused" ($c.Code -eq 1 -and $c.Out -match 'docs/changes/B-02\.md')
    Remove-Item -LiteralPath (Join-Path $wt 'docs\changes\B-02.md')
    # deleting a file the item does not own is a change outside it too
    Remove-Item -LiteralPath (Join-Path $wt 'README.md')
    $c = Run $commit @('-Message', 'B-01', '-RoadmapItem', 'B-01')
    Check 'commit: deleting a file the item does not own is refused' ($c.Code -eq 1 -and $c.Out -match 'README\.md')
    & git -C $wt checkout -q -- README.md 2>&1 | Out-Null
    # explicit -Owns (a list, as pwsh -File passes it: one comma-joined string)
    Put (Join-Path $wt 'lib\x.txt') 'x'
    $c = Run $commit @('-Message', 'explicit', '-Owns', 'lib/,src/,tests/,docs/changes/,specs/')
    Check "commit: explicit -Owns allows what it lists ($($c.Code))" ($c.Code -eq 0)
    Put (Join-Path $wt 'zzz.txt') 'z'
    $c = Run $commit @('-Message', 'explicit', '-Owns', 'lib/')
    Check 'commit: explicit -Owns refuses what it does not list (fragments need an item)' ($c.Code -eq 1 -and $c.Out -match 'zzz\.txt')
    $c = Run $commit @('-Message', 'explicit', '-Owns', '../x')
    Check 'commit: a bad -Owns entry fails closed' ($c.Code -eq 1 -and $c.Out -match "owns entry")
    # a roadmap order's job file gives the item even when the caller passes nothing (the repair station's commits)
    Job 'J1' 'B-01' 'running' $repo
    $c = Run $commit @('-Message', 'repair round 1')
    Check 'commit: a roadmap-item job is held to its owns even without -RoadmapItem' ($c.Code -eq 1 -and $c.Out -match 'zzz\.txt' -and $c.Out -match 'B-01')
    Remove-Item -LiteralPath (Join-Path $kr 'jobs\J1.json')
    # without -Owns, and not a roadmap job: unchanged behaviour
    $c = Run $commit @('-Message', 'plain change')
    Check "commit: without -Owns nothing about ownership changes ($($c.Code))" ($c.Code -eq 0 -and $c.Out -notmatch 'owns' -and (& git -C $wt ls-files 'zzz.txt'))
    # a broken roadmap in the main checkout: fail closed (and the worktree's own copy is never what counts)
    Put (Join-Path $wt 'src\a.txt') 'a3'
    Put (Join-Path $wt 'map\roadmap.json') (RmJson @{ waves = @(@{ id = 'W1'; goal = 'g'; items = @((Item 'B-01' @() @('**'))) }) })
    $c = Run $commit @('-Message', 'B-01', '-RoadmapItem', 'B-01')
    Check 'commit: the worktree''s own roadmap (owns ** there) does not widen what the item owns' ($c.Code -eq 1 -and $c.Out -match 'map/roadmap\.json')
    & git -C $wt checkout -q -- map/roadmap.json 2>&1 | Out-Null
    Put (Join-Path $repo 'map\roadmap.json') '{ "waves": '
    $c = Run $commit @('-Message', 'B-01', '-RoadmapItem', 'B-01')
    Check 'commit: a broken roadmap in the main checkout is refused' ($c.Code -eq 1 -and $c.Out -match 'REFUSED' -and $c.Out -match 'not valid JSON')
    Put (Join-Path $repo 'map\roadmap.json') (RmJson $fix)
    $env:KITCHEN_JOB = $null

    # ---- 5. roadmap.ps1: status, next, cook (fake job files; -WhatIf; then one real queueing) ----------------------------------------
    Remove-Item -Recurse -Force (Join-Path $kr 'jobs') -ErrorAction SilentlyContinue
    Job 'J50' 'B-06' 'running' $repo                     # cooking
    Job 'J51' 'B-01' 'done' (Join-Path $root 'elsewhere') # another repo's B-01: ignored
    Job 'J52' 'B-04' 'quarantined' $repo                 # set aside, waits for Jordan
    $o = Run $roadmapPs @('status', '-Repo', $repo)
    Check "status: every item, with its state ($($o.Code))" ($o.Code -eq 0 -and $o.Out -match 'B-06\s+cooking J50' -and $o.Out -match 'B-02\s+blocked-by B-01' -and $o.Out -match 'B-03\s+owner-only' -and $o.Out -match 'B-01\s+not-started' -and $o.Out -match 'B-04\s+set-aside J52' -and $o.Out -match 'W1: 0 of 6 merged')
    $n = (Run $roadmapPs @('next', '-Repo', $repo, '-Wave', 'W1', '-Json')).Out | ConvertFrom-Json
    Check 'next: ready items in roadmap order (not blocked, owner-only, cooking or set aside)' (($n.items.id -join ',') -eq 'B-01,B-05')
    Check 'next: another wave' (-not ((Run $roadmapPs @('next', '-Repo', $repo, '-Wave', 'W2', '-Json')).Out | ConvertFrom-Json).items.Count)
    Check 'next: needs -Wave; an unknown wave is refused' ((Run $roadmapPs @('next', '-Repo', $repo)).Code -eq 2 -and (Run $roadmapPs @('next', '-Repo', $repo, '-Wave', 'W9')).Out -match "no wave 'W9'")
    Remove-Item -LiteralPath (Join-Path $kr 'jobs\J52.json')   # Jordan closed it: B-04 is ready again, and overlaps B-01 (src/b/)
    $c = (Run $roadmapPs @('cook', '-Repo', $repo, '-Wave', 'W1', '-WhatIf', '-Json')).Out | ConvertFrom-Json
    Check 'cook -WhatIf: picks in order, skips an item whose owns overlap one picked' (($c.cooked.id -join ',') -eq 'B-01,B-05' -and ($c.skipped | Where-Object id -eq 'B-04').why -match 'overlap with B-01')
    Check 'cook -WhatIf: queues nothing' (@(Get-ChildItem (Join-Path $kr 'jobs') -Filter 'J*.json').Count -eq 2)
    $c = (Run $roadmapPs @('cook', '-Repo', $repo, '-Wave', 'W1', '-WhatIf', '-Max', '2', '-Json')).Out | ConvertFrom-Json
    Check 'cook -Max counts what is already cooking (1 cooking + 1 new = 2)' (($c.cooked.id -join ',') -eq 'B-01' -and ($c.skipped | Where-Object id -eq 'B-05').why -match 'max 2')
    $c = (Run $roadmapPs @('cook', '-Repo', $repo, '-Wave', 'W1', '-WhatIf', '-Max', '1', '-Json')).Out | ConvertFrom-Json
    Check 'cook: nothing new when the max is already cooking' (-not @($c.cooked).Count)
    Job 'J54' 'B-01' 'running' $repo   # B-01 cooking: B-04 overlaps it, so it must wait even though B-01 is not picked now
    $c = (Run $roadmapPs @('cook', '-Repo', $repo, '-Wave', 'W1', '-WhatIf', '-Json')).Out | ConvertFrom-Json
    Check 'cook: never overlaps an item already cooking' (($c.cooked.id -join ',') -eq 'B-05' -and ($c.skipped | Where-Object id -eq 'B-04').why -match 'overlap with B-01')
    Remove-Item -LiteralPath (Join-Path $kr 'jobs\J54.json')

    # merged = the item's change note docs/changes/<id>.md on main, nothing else. A merge text or commit subject that names the id (the
    # real case: PR #43 "map: B-42 owns the lever registry files" marked B-42 merged with no B-42 code) and a done job are claims, not proof.
    G $repo checkout -q -b map/b01-owns; Put (Join-Path $repo 'other.txt') '1'; G $repo add -A; G $repo commit -q -m 'map edit'
    G $repo checkout -q main; G $repo merge -q --no-ff -m 'Merge pull request #43 from me/map/b01-owns' -m 'map: B-01 owns the registry files (unblocks J9)' map/b01-owns
    Put (Join-Path $repo 'other.txt') '2'; G $repo add -A; G $repo commit -q -m 'B-01: title of B-01 (#7)'
    Job 'J55' 'B-05' 'done' $repo
    $s = @(Get-RoadmapState (Get-Roadmap $repo) $kr)
    Check 'merged: a merge commit or a commit subject naming B-01 is not proof' (($s | Where-Object id -eq 'B-01').state -ne 'merged')
    Check 'merged: a done job is not proof (B-05)' (($s | Where-Object id -eq 'B-05').state -ne 'merged')
    $b2 = $s | Where-Object id -eq 'B-02'
    Check 'blocked: B-02 stays blocked while B-01 has no change note on main' ($b2.state -eq 'blocked' -and ($b2.blockers -join ',') -eq 'B-01')
    $env:KITCHEN_JOB = 'J1'
    $o = Run (Join-Path $st 'roadmap-item.ps1') @('-Repo', $repo, '-Item', 'B-01')
    Check 'station: an item named only in merge text is not refused as merged' ($o.Code -eq 0 -and $o.Out -notmatch 'already merged')
    $o = Run (Join-Path $st 'roadmap-item.ps1') @('-Repo', $repo, '-Item', 'B-02')
    Check 'station: its dependant is refused as blocked (not merged yet)' ($o.Code -eq 1 -and $o.Out -match 'blocked by B-01 \(not merged yet\)')
    $env:KITCHEN_JOB = $null
    G $repo checkout -q -b side; Put (Join-Path $repo 'docs\changes\B-04.md') 'what, why, undo'; G $repo add -A; G $repo commit -q -m 'B-04 note on a branch'; G $repo checkout -q main
    Put (Join-Path $repo 'docs\changes\B-01.md') 'what, why, undo'; Put (Join-Path $repo 'docs\changes\B-05.md') 'what, why, undo'; G $repo add -A; G $repo commit -q -m 'change notes'
    $notes = (& git -C $repo rev-parse HEAD)
    $o = Run $roadmapPs @('status', '-Repo', $repo, '-Wave', 'W1')
    Check 'status: merged by the change note on main' ($o.Out -match 'B-01\s+merged' -and $o.Out -match 'B-05\s+merged' -and $o.Out -match 'W1: 2 of 6 merged')
    Check 'merged: a change note on another branch is not proof (B-04)' ($o.Out -notmatch 'B-04\s+merged')
    Check 'status -Wave: only that wave' ($o.Out -notmatch 'B-07')
    $n = (Run $roadmapPs @('next', '-Repo', $repo, '-Wave', 'W1', '-Json')).Out | ConvertFrom-Json
    Check 'next: a merged dependency unblocks the next item' (($n.items.id -join ',') -eq 'B-02,B-04')
    $env:KITCHEN_JOB = 'J1'
    $s = Run (Join-Path $st 'roadmap-item.ps1') @('-Repo', $repo, '-Item', 'B-01')
    Check 'station: an item already merged is refused' ($s.Code -eq 1 -and $s.Out -match 'already merged')
    $env:KITCHEN_JOB = $null
    G $repo rm -q docs/changes/B-05.md; G $repo commit -q -m 'Undo J55 (reverts its merge)'
    $s = @(Get-RoadmapState (Get-Roadmap $repo) $kr)
    Check 'merged: a revert that removes the change note un-merges the item' (($s | Where-Object id -eq 'B-05').state -ne 'merged' -and ($s | Where-Object id -eq 'B-01').state -eq 'merged')
    G $repo reset -q --hard $notes   # the scratch repo is this test's own: the cook tests below need B-01 and B-05 merged, B-02 and B-04 ready

    # cook for real: cook.ps1 queues roadmap-item orders in the scratch kitchen (no supervisor runs them), approves nothing
    $c = Run $roadmapPs @('cook', '-Repo', $repo, '-Wave', 'W1', '-Max', '3', '-Json')
    $cj = $c.Out | ConvertFrom-Json
    Check "cook: queues the ready items ($($c.Code): $($c.Out.Trim()))" ($c.Code -eq 0 -and ($cj.cooked.id -join ',') -eq 'B-02,B-04' -and @($cj.cooked | Where-Object { $_.job -match '^J\d+$' }).Count -eq 2)
    $q = @($cj.cooked | ForEach-Object { Get-Content (Join-Path $kr "jobs\$($_.job).json") -Raw | ConvertFrom-Json })
    Check 'cook: each order is recipe roadmap-item with the repo and the item' (@($q | Where-Object { $_.recipe -eq 'roadmap-item' -and $_.vars.item -in 'B-02', 'B-04' -and $_.vars.repo -eq $rm.Main }).Count -eq 2)
    Check 'cook: nothing approved; the merge step still waits for Jordan' (@($q | Where-Object { $_.status -eq 'pending' -and -not $_.approval -and ($_.steps | Where-Object { $_.script -match 'merge\.ps1$' }).approve -eq $true }).Count -eq 2)
    $o = Run $roadmapPs @('status', '-Repo', $repo, '-Wave', 'W1')
    Check 'status: the queued items show as cooking' ($o.Out -match 'B-02\s+cooking J\d+' -and $o.Out -match 'B-04\s+cooking J\d+')
    $c2 = Run $roadmapPs @('cook', '-Repo', $repo, '-Wave', 'W1', '-Json')
    $c = try { $c2.Out | ConvertFrom-Json } catch { $null }
    Check "cook: an item already cooking is never cooked twice ($($c2.Out.Trim()))" ($c -and $c.ok -and -not @($c.cooked | Where-Object { $_ }).Count)
    Check 'cook: a bad call is refused (-Max 0, unknown action, no repo)' ((Run $roadmapPs @('cook', '-Repo', $repo, '-Wave', 'W1', '-Max', '0')).Code -eq 2 -and (Run $roadmapPs @('approve', '-Repo', $repo)).Code -eq 2 -and (Run $roadmapPs @('status')).Code -eq 2)

    # ---- 6. the recipe ---------------------------------------------------------------------------------------------------------------
    $rec = Get-Content (Join-Path $kd 'recipes\roadmap-item.json') -Raw | ConvertFrom-Json
    $imp = Get-Content (Join-Path $kd 'recipes\improve.json') -Raw | ConvertFrom-Json
    Check 'recipe: vars item and repo required, github optional' ($rec.vars.item.required -and $rec.vars.repo.required -and -not $rec.vars.github.required)
    $names = @($rec.steps | ForEach-Object { if ($_.station -eq 'agent') { "agent:$($_.args.Role)" } else { $_.station } })
    $impNames = @($imp.steps | ForEach-Object { if ($_.station -eq 'agent') { "agent:$($_.args.Role)" } else { $_.station } })
    $expect = @($impNames[0], 'roadmap-item') + $impNames[1..($impNames.Count - 1)]
    $pi = [array]::IndexOf($expect, 'agent:plan'); $expect = @($expect[0..$pi]) + @('scope-check') + @($expect[($pi + 1)..($expect.Count - 1)])
    Check 'recipe: the improve line with roadmap-item after the worktree and scope-check right after the plan' ($pi -gt 0 -and ($names -join ',') -eq ($expect -join ','))
    Check 'recipe: commit enforces the item''s owns' (($rec.steps | Where-Object station -eq 'commit').args.RoadmapItem -eq '{{item}}')
    Check 'recipe: the merge waits for Jordan' (($rec.steps | Where-Object station -eq 'merge').approve -eq $true -and ($rec.steps | Where-Object station -eq 'merge').replay -eq 'unsafe')
    Check 'recipe: plan, build and taster read ITEM.md' (@($rec.steps | Where-Object { $_.station -eq 'agent' -and $_.args.Context -match 'ITEM\.md' }).Count -eq 3)
    Check 'recipe: the build prompt states the ownership rule' (($rec.steps | Where-Object { $_.args.Role -eq 'do' }).args.Prompt -match 'OWNERSHIP')
    Check 'recipe: not public (the privacy judge stays on)' ($rec.public -ne $true)
    Check 'cook.ps1 -List shows roadmap-item' ((& (Join-Path $kd 'cook.ps1') -List | Out-String) -match 'roadmap-item')
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    if (Test-Path -LiteralPath (Join-Path $root 'repo')) { & git -C (Join-Path $root 'repo') worktree prune 2>&1 | Out-Null }
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}
Write-Output "Roadmap tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
exit 0
