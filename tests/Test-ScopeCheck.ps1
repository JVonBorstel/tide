# Tests for scope control of roadmap-item orders: station scope-check (kitchen/stations/scope-check.ps1, kitchen/scope-lib.ps1), what the
# commit station accepts from it, and the commit budget by size (kitchen.repo.json commitBudget.bySize, kitchen/repo-config.ps1).
# One fake main repo with a roadmap, one linked worktree per case (as the kitchen makes them), a scratch kitchen. No AI, no network.
# Run by the kitchen tests station (tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Self-cleaning: everything under TEMP.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$scopePs = Join-Path $kd 'stations\scope-check.ps1'; $commitPs = Join-Path $kd 'stations\commit.ps1'
. (Join-Path $kd 'roadmap-lib.ps1')
. (Join-Path $kd 'scope-lib.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('scope-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G([string]$r) { & git -C $r -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function Put([string]$path, [string]$text) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null; Set-Content -LiteralPath $path -Value $text -Encoding utf8 }
function New-RmItem([string]$id, [string[]]$owns) { [ordered]@{ id = $id; title = "title of $id"; why = "why $id"; depends_on = @(); owns = @($owns); acceptance = @("$id-1: it works") } }
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_JOB') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
$script:n = 0
# a fresh kitchen with job J1 (recipe roadmap-item, item B-01) in its own linked worktree of the main repo; PLAN.md as given ($null = none)
function New-Case([object]$plan, [string]$size = '') {
    $script:n++; $kr = Join-Path $root "k$script:n"; $wt = Join-Path $kr 'worktrees\J1'
    G $main worktree add -q -b "kitchen/case$script:n" $wt main
    New-Item -ItemType Directory -Force -Path (Join-Path $wt '.kitchen') | Out-Null
    Set-Content (Join-Path $wt '.kitchen\BASE') ((& git -C $wt rev-parse HEAD).Trim())
    Set-Content (Join-Path $wt '.kitchen\ITEM.md') '# B-01: title of B-01'
    if ($null -ne $plan) { Put (Join-Path $wt '.kitchen\PLAN.md') $plan }
    $vars = @{ repo = $main; item = 'B-01' }; if ($size) { $vars.size = $size }
    Put (Join-Path $kr 'jobs\J1.json') (@{ id = 'J1'; recipe = 'roadmap-item'; status = 'running'; vars = $vars; steps = @(@{ script = 'fake.ps1'; args = @{ Repo = $main } }); history = @() } | ConvertTo-Json -Depth 6)
    [pscustomobject]@{ Kroot = $kr; Wt = $wt }
}
function Plan([string[]]$files) { (@('# Plan', 'Some prose naming src/b02.txt, which must not count.', '', '## Files to change') + @($files | ForEach-Object { "- ``$_`` - why" }) + @('', '## Risks', '- none', 'PLAN READY')) -join "`n" }
# in this process (a station's exit ends only the station; a pwsh per run made the suite too slow for the tests station)
function Run-Station($case, [string]$ps, [hashtable]$more) {
    $env:KITCHEN_JOB = 'J1'; $env:BRAIN_KITCHEN = $case.Kroot; $global:LASTEXITCODE = 0
    $o = try { & $ps @more 2>&1 | Out-String } catch { "THREW: $($_.Exception.Message)"; $global:LASTEXITCODE = 99 }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}
function Scope($case) { Run-Station $case $scopePs @{ Repo = $main; Item = 'B-01' } }
function Commit($case) { Run-Station $case $commitPs @{ Message = 'B-01'; RoadmapItem = 'B-01' } }
function Events($case) { $p = Join-Path $case.Kroot 'events.jsonl'; if (Test-Path $p) { @(Get-Content $p | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
function WtOwns($case) { (Get-RoadmapItem (Read-Roadmap (Join-Path $case.Wt 'map\roadmap.json')) 'B-01').owns }
function Touch($case, [string[]]$files) { foreach ($f in $files) { Put (Join-Path $case.Wt $f) "content of $f" } }
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $main = Join-Path $root 'main'; New-Item -ItemType Directory -Path $main | Out-Null
    G $main init -q -b main
    Put (Join-Path $main 'kitchen.repo.json') '{"roadmap":"map/roadmap.json","protected":["config/**"],"commitBudget":{"files":3,"lines":100,"bySize":{"L":{"files":6,"lines":500}}}}'
    $rmObj = @{ waves = @(@{ id = 'W1'; goal = 'g'; items = @((New-RmItem 'B-01' @('src/b01/')), (New-RmItem 'B-02' @('src/b02.txt'))) }) }
    Put (Join-Path $main 'map\roadmap.json') ($rmObj | ConvertTo-Json -Depth 10)
    Put (Join-Path $main 'seed.txt') 'seed'
    G $main add -A; G $main commit -q -m seed

    # ---- inside owns passes ------------------------------------------------------------------------------------------------------------
    $c = New-Case (Plan @('src/b01/a.ps1', 'docs/changes/B-01.md'))
    $r = Scope $c
    $rec = Get-Content (Join-Path $c.Wt '.kitchen\SCOPE.json') -Raw | ConvertFrom-Json
    Check "inside owns passes: exit 0, nothing widened ($($r.Out.Trim()))" ($r.Code -eq 0 -and $r.Out -match '2 inside its owns, 0 widened' -and $rec.status -eq 'ok' -and @($rec.widened).Count -eq 0)
    Check 'inside owns passes: roadmap untouched, no event' (-not (& git -C $c.Wt status --porcelain -- map) -and -not @(Events $c).Count)

    # ---- free file auto-widens and commit accepts it ---------------------------------------------------------------------------------------
    $c = New-Case (Plan @('src/b01/a.ps1', 'lib/free.ps1'))
    $r = Scope $c
    $rec = Read-ScopeRecord $c.Kroot 'J1'
    Check "free file auto-widens: exit 0, recorded in both copies ($($r.Out.Trim()))" ($r.Code -eq 0 -and @($rec.widened) -join ',' -eq 'lib/free.ps1' -and ((Get-Content (Join-Path $c.Wt '.kitchen\SCOPE.json') -Raw | ConvertFrom-Json).widened -join ',') -eq 'lib/free.ps1')
    Check 'free file auto-widens: added to the worktree roadmap owns, the diff is only that line' ((WtOwns $c) -contains 'lib/free.ps1' -and (& git -C $c.Wt diff --numstat -- map/roadmap.json) -match '^2\s+1\s')
    Check 'free file auto-widens: ITEM.md tells the cook, events.jsonl has scope.widen' ((Get-Content (Join-Path $c.Wt '.kitchen\ITEM.md') -Raw) -match '(?s)Owns widened by scope-check.*lib/free\.ps1' -and @(Events $c | Where-Object { $_.type -eq 'scope.widen' -and $_.files -contains 'lib/free.ps1' -and $_.item -eq 'B-01' }).Count -eq 1)
    $again = Scope $c
    Check 're-run keeps the widened file once (no duplicate owns)' ($again.Code -eq 0 -and @(WtOwns $c | Where-Object { $_ -eq 'lib/free.ps1' }).Count -eq 1)
    Touch $c @('src/b01/a.ps1', 'lib/free.ps1')
    $r = Commit $c
    $committed = @(& git -C $c.Wt diff --name-only main HEAD)
    Check "commit accepts the widened file and the roadmap edit ($($r.Out.Trim()))" ($r.Code -eq 0 -and $committed -contains 'lib/free.ps1' -and $committed -contains 'map/roadmap.json' -and $r.Out -match 'widened B-01 by: lib/free\.ps1')

    # commit accepts exactly what SCOPE.json widened and nothing else: another file, a tampered roadmap, a cook-edited SCOPE.json
    $c = New-Case (Plan @('lib/free.ps1')); $null = Scope $c
    Touch $c @('lib/free.ps1', 'lib/other.ps1')
    $rmw = Join-Path $c.Wt 'map\roadmap.json'; Set-Content $rmw ((Get-Content $rmw -Raw).Replace('src/b02.txt', 'src/b02.txt", "lib/stolen.ps1'))
    Set-Content (Join-Path $c.Wt '.kitchen\SCOPE.json') '{"item":"B-01","status":"ok","widened":["lib/free.ps1","lib/other.ps1"]}'
    $r = Commit $c
    $outside = if ($r.Out -match 'owns: ([^\r\n]+)') { @($Matches[1] -split ', ') } else { @() }
    Check "commit refuses a file scope-check did not widen, even when the worktree's SCOPE.json lists it ($($outside -join ' '))" ($r.Code -eq 1 -and $outside -contains 'lib/other.ps1' -and $outside -notcontains 'lib/free.ps1')
    Check 'commit refuses the roadmap file once a cook changed it after scope-check' ($outside -contains 'map/roadmap.json')
    # ---- file owned by another item stops naming both ----------------------------------------------------------------------------------------
    $c = New-Case (Plan @('src/b01/a.ps1', 'src/b02.txt'))
    $r = Scope $c
    Check "file owned by another item stops naming both ($($r.Out.Trim()))" ($r.Code -eq 1 -and $r.Out -match 'STOPPED: B-01 plans to change src/b02\.txt, which B-02 owns' -and (Read-ScopeRecord $c.Kroot 'J1').status -eq 'stopped')
    Check 'owned by another item: roadmap untouched, scope.stop names B-02' (-not (& git -C $c.Wt status --porcelain -- map) -and @(Events $c | Where-Object { $_.type -eq 'scope.stop' -and $_.owners -contains 'B-02' -and $_.item -eq 'B-01' }).Count -eq 1)
    $c = New-Case (Plan @('lib/busy.ps1', 'config/x.json'))
    Put (Join-Path $c.Kroot 'jobs\J2.json') (@{ id = 'J2'; recipe = 'improve'; status = 'running'; vars = @{ goal = 'tidy lib/busy.ps1 please' }; steps = @(@{ script = 'x.ps1'; args = @{ Repo = $main } }); history = @() } | ConvertTo-Json -Depth 6)
    $r = Scope $c
    Check 'a file a running order names is not widened: stops naming the order' ($r.Code -eq 1 -and $r.Out -match 'lib/busy\.ps1, which running order J2 names')
    Check 'a protected file is never widened' ($r.Code -eq 1 -and $r.Out -match 'config/x\.json is protected')

    # ---- bySize picks L limits ---------------------------------------------------------------------------------------------------------------
    $cfg = Read-RepoConfig $main
    $bl = Get-RepoCommitBudget $cfg 'L'; $bm = Get-RepoCommitBudget $cfg 'M'; $bx = Get-RepoCommitBudget $cfg ''
    Check 'bySize picks L limits; M and unknown fall back to the flat numbers' ($bl.Files -eq 6 -and $bl.Lines -eq 500 -and $bl.From -eq 'commitBudget.bySize.L' -and $bm.Files -eq 3 -and $bm.Lines -eq 100 -and $bx.Size -eq 'M' -and $bx.Files -eq 3)
    Check 'order size: size var, else roadmap item size, else M' ((Get-OrderSize ([pscustomobject]@{ vars = @{ size = 'l' } }) ([pscustomobject]@{ size = 'S' })).Size -eq 'L' -and
        (Get-OrderSize ([pscustomobject]@{ vars = @{} }) ([pscustomobject]@{ size = 'L' })).From -eq 'roadmap' -and (Get-OrderSize $null $null).Size -eq 'M')
    $five = @(1..5 | ForEach-Object { "src/b01/f$_.ps1" })
    $c = New-Case (Plan $five) 'L'; Touch $c $five
    $r = Commit $c
    Check "commit with size L takes the bySize.L budget ($($r.Out.Trim()))" ($r.Code -eq 0 -and $r.Out -match 'size L \(from order\): budget 6 files, 500 lines')
    $c = New-Case (Plan $five); Touch $c $five
    $r = Commit $c
    Check 'commit with no size keeps the M default (flat numbers)' ($r.Code -eq 1 -and $r.Out -match '5 files changed \(max 3\)')
    $r = Scope $c
    Check 'scope-check stops a plan over the budget before the build' ($r.Code -eq 1 -and $r.Out -match 'plans 5 counted files; size M \(from default\) allows 3')
    $bad = Join-Path $root 'badcfg'; Put (Join-Path $bad 'kitchen.repo.json') '{"commitBudget":{"bySize":{"XL":{"files":9}}}}'
    $m = try { Read-RepoConfig $bad | Out-Null; '' } catch { $_.Exception.Message }
    Check 'a bad bySize key fails closed' ($m -match "bySize' key 'XL' must be S, M or L")

    # ---- no PLAN.md fails loudly ------------------------------------------------------------------------------------------------------------
    $c = New-Case $null
    $r = Scope $c
    Check "no PLAN.md fails loudly ($($r.Out.Trim()))" ($r.Code -eq 1 -and $r.Out -match 'STOPPED: no \.kitchen\\PLAN\.md' -and @(Events $c | Where-Object { $_.type -eq 'scope.stop' }).Count -eq 1)
    Put (Join-Path $c.Wt '.kitchen\PLAN.md') "# Plan`nedit some files`nPLAN READY"
    $r = Scope $c
    Check 'a plan without a Files to change list fails loudly' ($r.Code -eq 1 -and $r.Out -match "no '## Files to change' section")

    # the in-place edit keeps an inline list inline
    Check 'roadmap edit: inline owns list stays inline' ((Add-RoadmapOwnsText '{"waves":[{"items":[{"id":"B-01","owns":["a"]}]}]}' 'B-01' @('b/c.ps1')) -eq '{"waves":[{"items":[{"id":"B-01","owns":["a", "b/c.ps1"]}]}]}')
}
finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "ScopeCheck tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
