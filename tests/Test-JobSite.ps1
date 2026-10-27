# Tests for an order's Site (multi-site design TD-3, gemini-brain projects/tide/plans/multi-site-design-2026-10-23.md): kitchen.ps1 add sets
# vars.site from the Tower's kitchen.repo.json "site", jobs-index.json stores it as si, an old order with no site gets its Site from its
# Tower when read (its file is never rewritten), and an order for a Tower with no site key is saved exactly as before TD-3.
# Synthetic Towers and kitchens under TEMP (plain folders, no git); self-cleaning; no AI; no tick (nothing runs).
$ErrorActionPreference = 'Stop'
$k = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1')).Path
$cook = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\cook.ps1')).Path
$w = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\demo-worker.ps1')).Path
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-jobsite-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_UNDER_TEST', 'KITCHEN_NO_RAMGUARD', 'KITCHEN_AGY_EXE', 'BRAIN_AGENT_DEPTH', 'KITCHEN_JOB', 'KITCHEN_NO_BACKUP', 'KITCHEN_RECIPES') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
$env:KITCHEN_UNDER_TEST = '1'; $env:KITCHEN_NO_RAMGUARD = '1'; $env:KITCHEN_AGY_EXE = 'off'; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null; $env:KITCHEN_NO_BACKUP = '1'
function New-Tower([string]$name, [string]$config) { $d = Join-Path $root "towers\$name"; New-Item -ItemType Directory -Force -Path $d | Out-Null; if ($config) { Set-Content -LiteralPath (Join-Path $d 'kitchen.repo.json') -Value $config -Encoding utf8 }; $d }
function New-Kitchen([string]$name) { $d = Join-Path $root "k-$name"; New-Item -ItemType Directory -Force -Path (Join-Path $d 'jobs') | Out-Null; $d }
# kitchen.ps1 add -SpecPath, as cook.ps1 calls it; vars $null = a spec with no vars key
function Add-Order([string]$kr, [hashtable]$vars, [string]$stepRepo = '') {
    $a = @{ Behavior = 'ok'; Seconds = 1 }; if ($stepRepo) { $a.Repo = $stepRepo }
    $spec = @{ name = 'order'; steps = @(@{ script = $w; args = $a; timeoutSec = 60 }) }; if ($null -ne $vars) { $spec.recipe = 'improve'; $spec.vars = $vars }
    $sp = Join-Path $root ("spec-" + [guid]::NewGuid().ToString('N') + '.json'); $spec | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sp -Encoding utf8
    $env:BRAIN_KITCHEN = $kr; $o = & pwsh -NoProfile -File $k add -SpecPath $sp | Out-String
    $m = [regex]::Match($o, 'added (J\d+)'); if (-not $m.Success) { throw "add failed: $o" }; $m.Groups[1].Value
}
function Read-TestJob([string]$kr, [string]$id) { Get-Content -LiteralPath (Join-Path $kr "jobs\$id.json") -Raw | ConvertFrom-Json -AsHashtable }
function Read-TestIndex([string]$kr) { (Get-Content -LiteralPath (Join-Path $kr 'jobs-index.json') -Raw | ConvertFrom-Json -AsHashtable).jobs }
function Read-TestEvents([string]$kr) { @(Get-Content (Join-Path $kr 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
function Canon($x) {   # keys sorted at every level, so two tables with the same content compare equal
    if ($x -is [Collections.IDictionary]) { $o = [ordered]@{}; foreach ($key in @($x.Keys | Sort-Object)) { $o[$key] = Canon $x[$key] }; return $o }
    if ($x -is [Collections.IList]) { return , @($x | ForEach-Object { Canon $_ }) }
    $x
}
function Same($a, $b) { ((Canon $a) | ConvertTo-Json -Depth 8 -Compress) -ceq ((Canon $b) | ConvertTo-Json -Depth 8 -Compress) }
# the keys of an order kitchen.ps1 add saved before TD-3 (recipe and vars only when the spec has them)
$addKeys = 'approval,attempt,created,cursor,depth,history,id,name,notBefore,parent,run,status,steps'
try {
    $td = New-Tower 'td' '{ "github": "o/td", "site": "TD" }'
    $plain = New-Tower 'plain' '{ "github": "o/plain", "commitBudget": { "files": 8, "lines": 400 } }'   # a Tower with no site key
    $bare = New-Tower 'bare' ''                                                                           # no kitchen.repo.json at all
    $broken = New-Tower 'broken' '{ "site": "td" }'                                                       # a site key that will not load

    # ---- AddOrder_TowerWithSite_VarsSiteAndIndexSi --------------------------------------------------------------------------------
    $ka = New-Kitchen 'a'
    $id = Add-Order $ka @{ repo = $td; goal = 'g' }
    $j = Read-TestJob $ka $id; $ix = Read-TestIndex $ka
    Check "AddOrder_TowerWithSite_VarsSiteAndIndexSi: vars.site is the Tower's site ($($j.vars.site)) and the index says si TD" ($j.vars.site -ceq 'TD' -and $j.vars.repo -eq $td -and $j.vars.goal -eq 'g' -and $ix[$id].si -ceq 'TD')
    $id2 = Add-Order $ka $null $td
    $j2 = Read-TestJob $ka $id2
    Check 'a Tower named only by a step (Repo) gives the Site too, in a vars of its own' ($j2.vars.site -ceq 'TD' -and @($j2.vars.Keys).Count -eq 1 -and (Read-TestIndex $ka)[$id2].si -ceq 'TD')
    $id3 = Add-Order $ka @{ repo = $td; goal = 'g'; site = 'GW' }
    Check "the Tower's site wins over a site passed with the order (derived from its Tower)" ((Read-TestJob $ka $id3).vars.site -ceq 'TD')

    # ---- AddOrder_TowerWithNoSiteKey_SavedExactlyAsBefore ---------------------------------------------------------------------------
    $kb = New-Kitchen 'b'; $kc = New-Kitchen 'c'
    $vars = @{ repo = $plain; goal = 'same goal'; size = 'S' }
    $ib = Add-Order $kb $vars; $jb = Read-TestJob $kb $ib
    $vc = @{ repo = $bare; goal = 'same goal'; size = 'S' }
    $ic = Add-Order $kc $vc; $jc = Read-TestJob $kc $ic
    Check 'AddOrder_TowerWithNoSiteKey_SavedExactlyAsBefore: the order keeps the keys add always gave it, and vars exactly as given' (
        ((@($jb.Keys | Sort-Object) -join ',') -eq ((@($addKeys.Split(',')) + 'recipe', 'vars' | Sort-Object) -join ',')) -and (Same $jb.vars $vars))
    $jb.created = 'x'; $jc.created = 'x'; $jc.vars.repo = $plain; $jc.steps = $jb.steps
    Check 'its file reads the same as an order for a Tower with no kitchen.repo.json at all (only the Tower path differs)' (Same $jb $jc)
    $eb = (Read-TestIndex $kb)[$ib]
    Check 'its index entry is exactly s, t, n, p, c (no si key) and jobs-index.json has no si anywhere' (
        (@($eb.Keys | Sort-Object) -join ',') -eq 'c,n,p,s,t' -and -not (Get-Content (Join-Path $kb 'jobs-index.json') -Raw).Contains('"si"'))
    $in = Add-Order $kb $null $plain; $jn = Read-TestJob $kb $in
    Check 'an order with no vars for a Tower with no site still has no vars key' (-not $jn.ContainsKey('vars') -and (@($jn.Keys | Sort-Object) -join ',') -eq $addKeys)
    Check 'no Site event was logged for either' (-not @(Read-TestEvents $kb | Where-Object { [string]$_.type -like 'job.site*' }).Count)
    $ip = Add-Order $kb @{ goal = 'research'; site = 'JH' }
    Check 'an order with no Tower keeps the site it was given (JH), stored as si' ((Read-TestJob $kb $ip).vars.site -ceq 'JH' -and (Read-TestIndex $kb)[$ip].si -ceq 'JH')
    $iq = Add-Order $kb @{ goal = 'research'; site = 'nope' }
    Check 'a given site that is not a known code stays in vars as given but is never stored as si' ((Read-TestJob $kb $iq).vars.site -eq 'nope' -and -not (Read-TestIndex $kb)[$iq].ContainsKey('si'))

    # ---- AddOrder_BrokenTowerConfig_AddedUnassignedAndLogged ------------------------------------------------------------------------
    $ir = Add-Order $kb @{ repo = $broken; goal = 'g' }
    $ev = @(Read-TestEvents $kb | Where-Object { $_.type -eq 'job.site.unread' -and $_.job -eq $ir })
    Check 'AddOrder_BrokenTowerConfig_AddedUnassignedAndLogged: the add is not refused, no site is set, and job.site.unread names the file' (
        -not (Read-TestJob $kb $ir).vars.ContainsKey('site') -and $ev.Count -eq 1 -and [string]$ev[0].detail -match 'kitchen\.repo\.json')

    # ---- OldOrder_NoSite_ReadTimeFallback_FileUntouched ----------------------------------------------------------------------------
    $ko = New-Kitchen 'old'
    $old = '{"id":"J1","name":"old","status":"pending","cursor":0,"attempt":0,"created":"2026-10-20T00:00:00Z","history":[],"recipe":"improve","vars":{"repo":' + ($td | ConvertTo-Json) + ',"goal":"g"},"steps":[{"script":' + ($w | ConvertTo-Json) + ',"args":{"Behavior":"ok"}}]}'
    [IO.File]::WriteAllText((Join-Path $ko 'jobs\J1.json'), $old)
    [IO.File]::WriteAllText((Join-Path $ko 'jobs\J2.json'), '{"id":"J2","name":"no tower","status":"pending","cursor":0,"history":[],"steps":[{"script":"x.ps1"}]}')
    $before = (Get-Item (Join-Path $ko 'jobs\J1.json')).LastWriteTimeUtc
    $env:BRAIN_KITCHEN = $ko; & pwsh -NoProfile -File $k status -Json | Out-Null
    . (Join-Path $repo 'kitchen\jobs-lib.ps1')
    $jobs = @(Get-KitchenJobs $ko); $o1 = $jobs | Where-Object { $_.id -eq 'J1' }; $o2 = $jobs | Where-Object { $_.id -eq 'J2' }
    Check "OldOrder_NoSite_ReadTimeFallback_FileUntouched: an old order's Site comes from its Tower ($(Get-KitchenJobSite $o1)); none for no Tower" ((Get-KitchenJobSite $o1) -ceq 'TD' -and (Get-KitchenJobSite $o2) -eq '')
    Check 'the old file is byte for byte as written, and its index entry has no si (nothing old is rewritten)' (
        [IO.File]::ReadAllText((Join-Path $ko 'jobs\J1.json')) -ceq $old -and (Get-Item (Join-Path $ko 'jobs\J1.json')).LastWriteTimeUtc -eq $before -and -not (Read-TestIndex $ko).J1.ContainsKey('si'))
    Check 'a stored site wins over the Tower, and a Tower with no site key or no config is Unassigned' (
        (Get-KitchenJobSite @{ vars = @{ repo = $td; site = 'GW' } }) -ceq 'GW' -and (Get-KitchenJobSite @{ vars = @{ repo = $plain } }) -eq '' -and
        (Get-KitchenJobSite @{ vars = @{ repo = $bare } }) -eq '' -and (Get-KitchenJobSite @{ vars = @{ repo = $broken } }) -eq '' -and (Get-KitchenJobSite @{ vars = @{ repo = '{{repo}}' } }) -eq '')
    # archived orders: a line written from TD-3 on carries site; an older line falls back to its repo
    $arc = ConvertTo-ArchivedJob @{ id = 'J5'; status = 'done'; repo = $plain; site = 'ZG'; month = '2026-10' }
    $arcOld = ConvertTo-ArchivedJob @{ id = 'J6'; status = 'done'; repo = $td; month = '2026-09' }
    Check 'an archive line keeps its site; an older line without one derives it from its repo' ((Get-KitchenJobSite $arc) -ceq 'ZG' -and (Get-KitchenJobSite $arcOld) -ceq 'TD' -and
        (Get-JobArchiveLine @{ id = 'J7'; vars = @{ site = 'TD'; repo = $td } } ([DateTime]::UtcNow) '2026-10').site -ceq 'TD')

    # ---- the index: si round trip, and a wrong si is damage (rebuilt from the files) --------------------------------------------------
    $kx = New-Kitchen 'ix'
    Write-JobsIndexFile $kx @{ J1 = @{ s = 'done'; t = 1L; n = 2L; p = ''; c = 0; si = 'GW' }; J2 = @{ s = 'pending'; t = 3L; n = 4L; p = 'J1'; c = 1 } }
    $rx = Read-JobsIndexFile $kx
    Check 'si survives a write and a read; an entry without one stays without one' ($rx.ok -and $rx.jobs.J1.si -ceq 'GW' -and -not $rx.jobs.J2.ContainsKey('si'))
    Set-Content (Join-Path $kx 'jobs-index.json') '{"v":1,"jobs":{"J1":{"s":"done","t":1,"n":2,"p":"","c":0,"si":7}}}'
    Check 'an si that is not a known Site code makes the index damaged (rebuilt from the files)' ((Read-JobsIndexFile $kx).reason -eq 'damaged')
    Check 'a changed site alone makes the entry differ (re-read, re-written)' (-not (Test-SameEntry @{ s = 'x'; t = 1; n = 1; p = ''; c = 0; si = 'GW' } @{ s = 'x'; t = 1; n = 1; p = ''; c = 0 }))

    # ---- cook.ps1: site is an order option (a requeue passes the stored vars back) ------------------------------------------------
    $rd = Join-Path $root 'recipes'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
    @{ name = 't'; description = 'test'; vars = @{ goal = @{ required = $true } }; steps = @(@{ script = $w; args = @{ Behavior = 'ok' } }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $rd 't.json') -Encoding utf8
    $env:KITCHEN_RECIPES = $rd; $env:BRAIN_KITCHEN = New-Kitchen 'cook'
    $c1 = (& $cook -Recipe t -Vars @{ goal = 'g'; site = 'TD' } -Json | Out-String) | ConvertFrom-Json
    $c2 = (& $cook -Recipe t -Vars @{ goal = 'g'; site = 'td' } -Json | Out-String) | ConvertFrom-Json
    Check 'cook.ps1 takes site as an order option (a requeue of a Site-tagged order still cooks) and refuses an unknown code' (
        $c1.ok -and (Read-TestJob $env:BRAIN_KITCHEN $c1.job).vars.site -ceq 'TD' -and -not $c2.ok -and [string]$c2.error -match 'site must be one of')
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Job Site tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
