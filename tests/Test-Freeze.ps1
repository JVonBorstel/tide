# Tests for per-repo merge freeze windows (kitchen.repo.json "freeze"; kitchen/repo-config.ps1, kitchen/freeze-lib.ps1): the merge
# station waits with the reason inside a window and merges outside it, a malformed window fails loudly naming the field, no freeze key
# is today's behaviour, and kitchen.ps1 status and Chef's freeze.json show it. Site-closed windows from the Sites registry (kitchen.json
# "sites.<CODE>.closed", TD-9) join a Tower's own and name the Site; the Demo Project window answers the same whatever the registry holds.
# KITCHEN_FREEZE_NOW stands in for the clock.
# Self-cleaning: a scratch repo and a scratch kitchen under TEMP only; no network.
$ErrorActionPreference = 'Stop'
$k = Join-Path $PSScriptRoot '..\kitchen'
$merge = Join-Path $k 'stations\merge.ps1'
. (Join-Path $k 'freeze-lib.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('fz-' + [guid]::NewGuid().ToString('N'))
$kr = Join-Path $root 'kitchen'; $repo = Join-Path $root 'demo-project'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G { & git -C $repo -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function Throws([scriptblock]$b) { try { & $b | Out-Null; '' } catch { $_.Exception.Message } }
$demo = '{"freeze":[{"from":"2026-10-27T00:00","to":"2026-10-28T18:00","why":"release demo"}]}'
function SetCfg([string]$json) { if ($json) { Set-Content -LiteralPath (Join-Path $repo 'kitchen.repo.json') -Value $json -Encoding utf8 } else { Remove-Item -LiteralPath (Join-Path $repo 'kitchen.repo.json') -ErrorAction SilentlyContinue } }
# a fresh kitchen/J1 branch with one change, then the merge station on it at the given clock
function Branch([string]$file) { G checkout -q -b kitchen/J1; Set-Content (Join-Path $repo $file) $file; G add -- $file; G commit -q -m "add $file"; G checkout -q main }
function Merge([string]$now) {
    $env:KITCHEN_FREEZE_NOW = $now; $run = Join-Path $root 'run-J1'; Remove-Item "$run.wait" -ErrorAction SilentlyContinue; $env:KITCHEN_RUN = $run
    $o = & pwsh -NoProfile -File $merge -Repo $repo -Approved 2>&1 | Out-String
    [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE; Wait = $(if (Test-Path "$run.wait") { [int](Get-Content "$run.wait" -Raw).Trim() } else { 0 }) }
}
$old = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB; r = $env:KITCHEN_RUN; n = $env:KITCHEN_FREEZE_NOW }
try {
    New-Item -ItemType Directory -Force -Path $kr, (Join-Path $kr 'jobs'), $repo | Out-Null
    $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_JOB = 'J1'
    & git -C $repo init -q -b main 2>&1 | Out-Null
    Set-Content (Join-Path $repo 'a.txt') 'base'; G add -A; G commit -q -m base

    # ---- the config: read, validated ----------------------------------------------------------------------------------------------
    Check 'no freeze key: no windows' ((Read-RepoConfig $repo).Freeze.Count -eq 0)
    SetCfg $demo; $c = Read-RepoConfig $repo
    Check 'freeze: window read in local time' ($c.Freeze.Count -eq 1 -and $c.Freeze[0].From -eq [DateTimeOffset]::new([DateTime]::new(2026, 10, 27, 0, 0, 0)) -and $c.Freeze[0].Why -eq 'release demo')
    Check 'reason reads frozen until 10-28 18:00: release demo' ((Format-FreezeReason $c.Freeze[0]) -eq 'frozen until 10-28 18:00: release demo')
    $env:KITCHEN_FREEZE_NOW = '2026-10-28T23:00:00Z'
    SetCfg '{"freeze":[{"from":"2026-10-28T06:00Z","to":"2026-10-29T00:00:00Z","why":"utc window"}]}'
    Check 'an ISO offset (Z) is honoured' ($null -ne (Get-RepoFreezeState $repo).active)
    $env:KITCHEN_FREEZE_NOW = 'tomorrow'
    Check 'a bad KITCHEN_FREEZE_NOW fails loudly' ((Get-RepoFreezeState $repo).err -match 'KITCHEN_FREEZE_NOW')
    $bad = @(
        @('{"freeze":{"from":"2026-10-27T00:00","to":"2026-10-28T18:00","why":"x"}}', "'freeze' must be a list"),
        @('{"freeze":["2026-10-27"]}', "'freeze\[0\]' must be an object"),
        @('{"freeze":[{"to":"2026-10-28T18:00","why":"x"}]}', "'freeze\[0\]\.from' is missing"),
        @('{"freeze":[{"from":"10/27 midnight","to":"2026-10-28T18:00","why":"x"}]}', "'freeze\[0\]\.from' must be a date and time"),
        @('{"freeze":[{"from":"2026-10-27T00:00","to":"2026-10-28T18:00","why":"ok"},{"from":"2026-10-27T00:00","to":"2026-10-26T18:00","why":"x"}]}', "'freeze\[1\]\.to' .* must be after"),
        @('{"freeze":[{"from":"2026-10-27T00:00","to":"2026-10-28T18:00"}]}', "'freeze\[0\]\.why' must be a short reason"),
        @('{"freeze":[{"from":"2026-10-27T00:00","to":"2026-10-28T18:00","why":"  "}]}', "'freeze\[0\]\.why' must be a short reason"))
    foreach ($b in $bad) { SetCfg $b[0]; $m = Throws { Read-RepoConfig $repo }; Check "malformed window names the field: $($b[1])" ($m -match $b[1] -and $m -match 'kitchen\.repo\.json') }

    # ---- the merge station ----------------------------------------------------------------------------------------------------------
    SetCfg ''; Branch 'b.txt'
    $r = Merge '2026-10-27T12:00'
    Check 'no freeze key = today: merges' ($r.Code -eq 0 -and $r.Out -match 'MERGED' -and (Test-Path (Join-Path $repo 'b.txt')))

    SetCfg $demo; Branch 'c.txt'; $before = (& git -C $repo rev-parse HEAD)
    $r = Merge '2026-10-27T12:00'
    Check 'inside window: waits (exit 11) with the reason' ($r.Code -eq 11 -and $r.Out -match 'demo-project frozen until 10-28 18:00: release demo' -and $r.Out -match 'nothing merged')
    Check 'inside window: main unchanged, branch kept' ((& git -C $repo rev-parse HEAD) -eq $before -and (& git -C $repo rev-parse --verify --quiet kitchen/J1))
    Check 'inside window: back on the rail until the window ends (30 h + 5 s)' ($r.Wait -eq (30 * 3600 + 5))
    $r = Merge '2026-10-26T23:59'
    Check 'outside window (just before): merges' ($r.Code -eq 0 -and $r.Out -match 'MERGED' -and (Test-Path (Join-Path $repo 'c.txt')))
    Branch 'd.txt'
    $r = Merge '2026-10-28T18:00'
    Check 'outside window (the end minute): merges and resumes' ($r.Code -eq 0 -and $r.Out -match 'MERGED')

    SetCfg '{"freeze":[{"from":"2026-10-27T00:00","to":"soon","why":"x"}]}'; Branch 'e.txt'; $before = (& git -C $repo rev-parse HEAD)
    $r = Merge '2026-10-27T12:00'
    Check 'malformed window: merge held for Jordan (exit 10) naming the field' ($r.Code -eq 10 -and $r.Out -match "'freeze\[0\]\.to'" -and (& git -C $repo rev-parse HEAD) -eq $before)

    # ---- status and Chef: read-only lines -----------------------------------------------------------------------------------------
    SetCfg $demo
    @{ id = 'J1'; name = 'freeze probe'; status = 'pending'; cursor = 0; attempt = 0; history = @(); steps = @(@{ script = $merge; args = @{ Repo = $repo }; approve = $true }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $kr 'jobs\J1.json') -Encoding utf8
    $env:KITCHEN_FREEZE_NOW = '2026-10-27T12:00'
    $v = Get-KitchenFreezeView $kr
    $gw = @($v.repos | Where-Object { $_.name -eq 'demo-project' })
    Check 'view: the repo a job names is found, its window active with the reason' ($gw.Count -eq 1 -and $gw[0].windows[0].active -and $gw[0].windows[0].reason -eq 'frozen until 10-28 18:00: release demo')
    $sn = & pwsh -NoProfile -File (Join-Path $k 'kitchen.ps1') status 2>&1 | Out-String
    Check 'status before the first tick: the freeze is not known yet, and says so' ($sn -match 'FREEZE: merge freeze windows not checked yet' -and $sn -notmatch 'FREEZE demo')
    Update-FreezeView $kr 0   # what the tick does; status reads the file it writes
    # Status_DoesNotRunGit: a fake git first on PATH logs every call; status must make none (10-22: status rebuilt the view through git, 145 s)
    $bin = Join-Path $root 'bin'; $gitLog = Join-Path $root 'git-calls.txt'; New-Item -ItemType Directory -Force $bin | Out-Null
    Set-Content (Join-Path $bin 'git.cmd') "@echo %* >> `"$gitLog`"`r`n@exit /b 1" -Encoding ascii
    $oldPath = $env:PATH; $env:PATH = "$bin;$env:PATH"
    try {
        & pwsh -NoProfile -Command 'git rev-parse --git-dir' 2>&1 | Out-Null
        $shimWorks = (Test-Path $gitLog); Remove-Item $gitLog -ErrorAction SilentlyContinue
        $s = & pwsh -NoProfile -File (Join-Path $k 'kitchen.ps1') status 2>&1 | Out-String
    } finally { $env:PATH = $oldPath }
    Check 'Status_DoesNotRunGit: kitchen.ps1 status makes no git call (fake git on PATH logs none)' ($shimWorks -and -not (Test-Path $gitLog))
    Check 'kitchen.ps1 status shows the freeze line' ($s -match 'FREEZE demo-project: merges frozen until 10-28 18:00: release demo')
    $sj = (& pwsh -NoProfile -File (Join-Path $k 'kitchen.ps1') status -Json 2>&1 | Out-String) | ConvertFrom-Json
    Check 'kitchen.ps1 status -Json carries the freeze' (@($sj.freeze.repos | Where-Object { $_.name -eq 'demo-project' }).Count -eq 1)
    $env:KITCHEN_FREEZE_NOW = '2026-10-25T12:00'
    $s = ((Format-FreezeLines (Get-KitchenFreezeView $kr)) -join "`n")   # the same lines kitchen.ps1 status prints (shown wired above); in-process keeps the suite fast
    Check 'status: a window ahead is shown as ahead' ($s -match 'FREEZE demo-project: merges will freeze 10-27 00:00 to 10-28 18:00: release demo')
    $env:KITCHEN_FREEZE_NOW = '2026-10-29T12:00'
    Check 'status: a window that is over is not shown' (((Format-FreezeLines (Get-KitchenFreezeView $kr)) -join "`n") -cnotmatch 'FREEZE ')
    $env:KITCHEN_FREEZE_NOW = '2026-10-27T12:00'
    Update-FreezeView $kr 0
    $fj = Get-Content (Join-Path $kr 'freeze.json') -Raw | ConvertFrom-Json
    # the tick rebuilds freeze.json only when a repo's kitchen.repo.json changed, or every 10 minutes; otherwise it is left alone
    $fzp = Join-Path $kr 'freeze.json'; $back = (Get-Date).AddMinutes(-2)
    (Get-Item $fzp).LastWriteTime = $back; Update-FreezeView $kr
    Check 'freeze view: nothing changed and under 10 min old: not rebuilt' ((Get-Item $fzp).LastWriteTime -eq $back)
    SetCfg '{"freeze":[{"from":"2026-10-27T00:00","to":"2026-10-28T20:00","why":"demo moved"}]}'; (Get-Item (Join-Path $repo 'kitchen.repo.json')).LastWriteTime = (Get-Date).AddMinutes(-1)
    (Get-Item $fzp).LastWriteTime = $back; Update-FreezeView $kr
    Check 'freeze view: a changed kitchen.repo.json rebuilds it at once' ((Get-Item $fzp).LastWriteTime -gt $back -and (Get-Content $fzp -Raw) -match 'demo moved')
    SetCfg $demo; (Get-Item (Join-Path $repo 'kitchen.repo.json')).LastWriteTime = (Get-Date).AddMinutes(-1); Update-FreezeView $kr 0
    $old = (Get-Date).AddMinutes(-11); (Get-Item $fzp).LastWriteTime = $old; Update-FreezeView $kr
    Check 'freeze view: 10 minutes old: rebuilt' ((Get-Item $fzp).LastWriteTime -gt $old)
    $env:KITCHEN_FREEZE_NOW = '2026-10-26T12:00'
    Check 'status from freeze.json: windows judged again at the current time (ahead, not active)' ((Format-FreezeLines (Read-FreezeView $kr)) -join "`n" -match 'merges will freeze 10-27 00:00')
    $env:KITCHEN_FREEZE_NOW = '2026-10-29T12:00'
    Check 'status from freeze.json: an ended window is dropped' (-not @((Read-FreezeView $kr).repos).Count)
    $env:KITCHEN_FREEZE_NOW = '2026-10-27T12:00'
    Set-Content $fzp '{"repos": [' -Encoding utf8
    Check 'status from freeze.json: a damaged file says the freeze is unknown' (((Format-FreezeLines (Read-FreezeView $kr)) -join "`n") -match 'FREEZE: merge freeze windows unknown: .*cannot be read')
    Update-FreezeView $kr 0
    $w = @($fj.repos | Where-Object { $_.name -eq 'demo-project' })[0].windows[0]
    Check "Chef's freeze.json: window with from, to, why and display times" ($w.why -eq 'release demo' -and $w.toText -eq '10-28 18:00' -and $w.fromText -eq '10-27 00:00' -and [DateTimeOffset]::Parse($w.to) -eq [DateTimeOffset]::new([DateTime]::new(2026, 10, 28, 18, 0, 0)))
    SetCfg '{"freeze":[{"from":"2026-10-27T00:00","to":"2026-10-28T18:00","why":""}]}'
    Check "status: a repo whose freeze will not load says so (none merge)" (((Format-FreezeLines (Get-KitchenFreezeView $kr)) -join "`n") -match "FREEZE demo-project: cannot tell whether merges are frozen, so none merge: .*'freeze\[0\]\.why'")
    $app = Get-Content (Join-Path $PSScriptRoot '..\pass-app\public\app.js') -Raw
    Check 'Board app: freeze banner lines in Site closed words (closed until, closing ahead, cannot be read)' ($app -match 'const st = w\.site \? `Site \$\{esc\(w\.site\)\}` : ''Site''' -and $app -match '\$\{st\} closed: \$\{esc\(r\.name\)\} takes no merges until \$\{esc\(w\.toText\)\}' -and $app -match '\$\{st\} closing ahead for' -and $app -match 'kitchen\.repo\.json cannot be read''\}, so the site stays closed and nothing merges')

    # ---- Site-closed windows from the Sites registry (TD-9): kitchen.json "sites.<CODE>.closed", added to its Towers' own windows ----
    $kj = Join-Path $kr 'kitchen.json'
    function SetReg([string]$json) { if ($json) { Set-Content -LiteralPath $kj -Value $json -Encoding utf8 } else { Remove-Item -LiteralPath $kj -ErrorAction SilentlyContinue } }
    function FzAt([string]$now) { $env:KITCHEN_FREEZE_NOW = $now; Get-RepoFreezeState $repo }
    $tdRel = '{"sites":{"TD":{"maxHeavy":2,"closed":[{"from":"2026-10-29T00:00","to":"2026-10-30T12:00","why":"release"}]}}}'
    # today's Demo Project freeze, Mon 10-27 00:00 to Tue 10-28 18:00 MT, in its own kitchen.repo.json: the same answer at every edge whatever
    # the registry holds (none, no sites, empty, another Site's window, a damaged file for a Tower with no Site, the same window under GW)
    function GwSame([string]$label, [bool]$exact = $true) {
        $a = FzAt '2026-10-26T23:59'; $b = FzAt '2026-10-27T00:00'; $c = FzAt '2026-10-27T12:00'; $d = FzAt '2026-10-28T17:59'; $e = FzAt '2026-10-28T18:00'
        $why = if ($exact) { $c.reason -eq 'frozen until 10-28 18:00: release demo' } else { $c.reason -match '^frozen until 10-28 18:00: release demo' }
        Check "Demo Project 10-27 00:00 to 10-28 18:00 exactly as today: $label" (-not $a.err -and -not $a.active -and $b.active -and $c.active -and $why -and $c.waitSec -eq (30 * 3600 + 5) -and $d.active -and -not $e.active -and -not $e.err)
    }
    SetCfg $demo
    SetReg ''; GwSame 'no state kitchen.json'
    SetReg '{"maxConcurrent":4}'; GwSame 'a kitchen.json with no sites'
    SetReg '{"sites":{}}'; GwSame 'an empty registry'
    SetReg $tdRel; GwSame "another Site's window"
    SetReg '{"sites": ['; GwSame 'a damaged kitchen.json never touches a Tower with no Site'
    SetCfg '{"site":"GW","freeze":[{"from":"2026-10-27T00:00","to":"2026-10-28T18:00","why":"release demo"}]}'
    SetReg ''; GwSame 'the Tower names Site GW, no registry'
    SetReg '{"sites":{"GW":{"closed":[{"from":"2026-10-27T00:00","to":"2026-10-28T18:00","why":"release demo"}]}}}'; GwSame 'the same window under GW in the registry' $false

    SetCfg '{"site":"TD"}'; SetReg $tdRel
    $s1 = FzAt '2026-10-29T12:00'
    Check 'Site window: a Tower of that Site is closed, the reason names the Site, back on the rail at its end (24 h + 5 s)' ($s1.active -and $s1.reason -eq 'frozen until 10-30 12:00: release (Site TD closed)' -and $s1.waitSec -eq (24 * 3600 + 5))
    Check 'Site window: open just before it and at its end minute' (-not (FzAt '2026-10-28T23:59').active -and -not (FzAt '2026-10-30T12:00').active)
    SetCfg '{"site":"GW"}'
    Check "Site window: a Tower of another Site is not closed by it" (-not (FzAt '2026-10-29T12:00').active -and -not (FzAt '2026-10-29T12:00').err)
    SetCfg '{"site":"TD","freeze":[{"from":"2026-10-28T00:00","to":"2026-10-29T06:00","why":"tower window"}]}'
    $u1 = FzAt '2026-10-28T12:00'; $u2 = FzAt '2026-10-29T03:00'
    Check "union: the Tower's own window alone" ($u1.reason -eq 'frozen until 10-29 06:00: tower window' -and $u1.waitSec -eq (18 * 3600 + 5))
    Check 'union: where both cover now, the one that ends last (the Site window, 33 h + 5 s)' ($u2.reason -match '\(Site TD closed\)' -and $u2.waitSec -eq (33 * 3600 + 5))
    SetReg '{"sites":{"TD":{"closed":[{"from":"2026-10-29T00:00","to":"2026-10-30T12:00","why":"repo copy"}]}}}'
    Check 'the state-folder copy is the registry read (here, the repo copy has an empty sites)' ((FzAt '2026-10-29T12:00').reason -match 'repo copy')
    SetCfg '{"site":"TD"}'
    $badReg = @(
        @('{"sites": [', 'cannot be read as JSON'),
        @('{"sites":["TD"]}', "'sites' must be an object"),
        @('{"sites":{"TD":"closed"}}', "'sites\.TD' must be an object"),
        @('{"sites":{"TD":{"closed":{"from":"2026-10-29T00:00"}}}}', "'sites\.TD\.closed' must be a list"),
        @('{"sites":{"TD":{"closed":[{"from":"2026-10-29T00:00","why":"x"}]}}}', "'sites\.TD\.closed\[0\]\.to' is missing"),
        @('{"sites":{"TD":{"closed":[{"from":"Tuesday","to":"2026-10-30T12:00","why":"x"}]}}}', "'sites\.TD\.closed\[0\]\.from' must be a date and time"),
        @('{"sites":{"TD":{"closed":[{"from":"2026-10-30T00:00","to":"2026-10-29T12:00","why":"x"}]}}}', "'sites\.TD\.closed\[0\]\.to' .* must be after"),
        @('{"sites":{"TD":{"closed":[{"from":"2026-10-29T00:00","to":"2026-10-30T12:00","why":" "}]}}}', "'sites\.TD\.closed\[0\]\.why' must be a short reason"))
    foreach ($b in $badReg) { SetReg $b[0]; $m = (FzAt '2026-10-25T12:00').err; Check "bad registry for the Tower's Site fails closed naming the field: $($b[1])" ($m -match 'cannot tell whether merges are frozen' -and $m -match $b[1] -and $m -match 'kitchen\.json') }
    SetReg '{"sites":{"GW":{"closed":"soon"}}}'
    Check "a bad window under another Site does not hold this Tower" (-not (FzAt '2026-10-25T12:00').err)

    # the merge station: waits inside the Site window naming the Site, held for Jordan on a bad registry, merges after
    if (-not (& git -C $repo rev-parse --verify --quiet kitchen/J1)) { Branch 'f.txt' }
    SetReg $tdRel; $before = (& git -C $repo rev-parse HEAD)
    $r = Merge '2026-10-29T12:00'
    Check 'merge station, Site window: waits (exit 11) naming the Site, main unchanged' ($r.Code -eq 11 -and $r.Out -match 'demo-project frozen until 10-30 12:00: release \(Site TD closed\)' -and $r.Wait -eq (24 * 3600 + 5) -and (& git -C $repo rev-parse HEAD) -eq $before)
    SetReg '{"sites":{"TD":{"closed":[{"from":"2026-10-29T00:00","why":"x"}]}}}'
    $r = Merge '2026-10-25T12:00'
    Check 'merge station, bad registry: held for Jordan (exit 10) naming the field' ($r.Code -eq 10 -and $r.Out -match "'sites\.TD\.closed\[0\]\.to' is missing" -and (& git -C $repo rev-parse HEAD) -eq $before)
    SetReg $tdRel
    $r = Merge '2026-10-30T12:00'
    Check 'merge station, after the Site window: merges' ($r.Code -eq 0 -and $r.Out -match 'MERGED')

    # status and Chef's freeze.json name the Site; a changed registry rebuilds freeze.json at once
    $env:KITCHEN_FREEZE_NOW = '2026-10-29T12:00'
    $v = Get-KitchenFreezeView $kr; $gr = @($v.repos | Where-Object { $_.name -eq 'demo-project' })
    Check 'view: the Tower carries its Site and the window names it' ($gr.Count -eq 1 -and $gr[0].site -eq 'TD' -and $gr[0].windows[0].site -eq 'TD' -and $gr[0].windows[0].active)
    Check 'status line names the Site (closed now)' (((Format-FreezeLines $v) -join "`n") -match 'FREEZE demo-project: merges frozen until 10-30 12:00: release \(Site TD closed\)')
    $env:KITCHEN_FREEZE_NOW = '2026-10-27T12:00'
    Check 'status line names the Site (ahead)' (((Format-FreezeLines (Get-KitchenFreezeView $kr)) -join "`n") -match 'FREEZE demo-project: merges will freeze 10-29 00:00 to 10-30 12:00: release \(Site TD closed\)')
    SetCfg $demo; $v = Get-KitchenFreezeView $kr; $gr = @($v.repos | Where-Object { $_.name -eq 'demo-project' })
    Check 'view, no Site on the Tower: the same keys as before (no site added)' ($gr.Count -eq 1 -and -not $gr[0].Contains('site') -and -not $gr[0].windows[0].Contains('site'))
    SetCfg '{"site":"TD"}'
    Update-FreezeView $kr 0
    Check "freeze.json read back keeps the Site" (@((Read-FreezeView $kr).repos | Where-Object { $_.name -eq 'demo-project' -and $_.site -eq 'TD' -and $_.windows[0].site -eq 'TD' }).Count -eq 1)
    $back = (Get-Date).AddMinutes(-2); (Get-Item $fzp).LastWriteTime = $back; Update-FreezeView $kr
    Check 'freeze view: registry unchanged and under 10 min old: not rebuilt' ((Get-Item $fzp).LastWriteTime -eq $back)
    SetReg '{"sites":{"TD":{"closed":[{"from":"2026-10-29T00:00","to":"2026-10-30T12:00","why":"release moved"}]}}}'; (Get-Item $kj).LastWriteTime = (Get-Date).AddMinutes(-1)
    (Get-Item $fzp).LastWriteTime = $back; Update-FreezeView $kr
    Check 'freeze view: a changed registry rebuilds it at once' ((Get-Item $fzp).LastWriteTime -gt $back -and (Get-Content $fzp -Raw) -match 'release moved')
    SetReg '{"sites":{"TD":{"closed":[{"from":"2026-10-29T00:00"}]}}}'
    $v = Get-KitchenFreezeView $kr; $er = @($v.errors | Where-Object { $_.name -eq 'demo-project' })
    Check 'view, bad registry: an error for the Tower naming its Site and kitchen.json, no windows shown' ($er.Count -eq 1 -and $er[0].site -eq 'TD' -and $er[0].source -eq 'kitchen.json' -and -not @($v.repos | Where-Object { $_.name -eq 'demo-project' }).Count)
    Check 'status line, bad registry: none merge, naming the field' (((Format-FreezeLines $v) -join "`n") -match "FREEZE demo-project: cannot tell whether merges are frozen, so none merge: .*'sites\.TD\.closed\[0\]\.to'")
    $srv = Get-Content (Join-Path $PSScriptRoot '..\pass-app\server.mjs') -Raw
    Check 'Board: the server passes the Site of a window and of a registry error; the banner names it' ($srv -match "site: String\(w\.site \|\| ''\)" -and $srv -match "source: String\(e\?\.source \|\| ''\)" -and $app -match 'Site \$\{esc\(e\.site\)\}''s closed windows in kitchen\.json cannot be read')
    SetReg ''; SetCfg $demo
    # 10-22 regression: 1,012 Repo mentions naming 2 repos meant 2 git calls each, and ticks took 160-340 s. Each distinct path once.
    $many = Join-Path $root 'many'; New-Item -ItemType Directory -Force "$many\jobs" | Out-Null
    $rj = ($repo | ConvertTo-Json)
    1..300 | ForEach-Object { Set-Content "$many\jobs\J$_.json" ("{`"id`":`"J$_`",`"steps`":[{`"args`":{`"Repo`":$rj}},{`"args`":{`"Repo`":$rj}}]}") }
    $script:mainCalls = 0
    $realMain = ${function:Get-RepoMainCheckout}
    function Get-RepoMainCheckout($p) { $script:mainCalls++; & $realMain $p }
    $t = [Diagnostics.Stopwatch]::StartNew(); $got = @(Get-KitchenRepos $many); $t.Stop()
    Remove-Item function:Get-RepoMainCheckout
    Check "kitchen repos: 600 mentions of one repo resolve it once ($script:mainCalls git lookups, $($t.ElapsedMilliseconds) ms)" ($script:mainCalls -le 2 -and @($got | Where-Object { $_ -like '*demo-project' }).Count -eq 1)
}
finally {
    $env:BRAIN_KITCHEN = $old.k; $env:KITCHEN_JOB = $old.j; $env:KITCHEN_RUN = $old.r; $env:KITCHEN_FREEZE_NOW = $old.n
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Freeze tests: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
exit 0
