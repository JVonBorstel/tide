# Tests for per-repo merge freeze windows (kitchen.repo.json "freeze"; kitchen/repo-config.ps1, kitchen/freeze-lib.ps1): the merge
# station waits with the reason inside a window and merges outside it, a malformed window fails loudly naming the field, no freeze key
# is today's behaviour, and kitchen.ps1 status and Chef's freeze.json show it. KITCHEN_FREEZE_NOW stands in for the clock.
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
    Check 'Board app: freeze banner lines in Site closed words (closed until, closing ahead, cannot be read)' ($app -match 'Site closed: \$\{esc\(r\.name\)\} takes no merges until \$\{esc\(w\.toText\)\}' -and $app -match 'Site closing ahead for' -and $app -match 'kitchen\.repo\.json cannot be read, so the site stays closed and nothing merges')
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
