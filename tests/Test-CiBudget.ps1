# Tests for TD-11 CI budgets (kitchen/ci-budget-lib.ps1, the Board lines in pass-app/public/ci-budget.js): runs and billed minutes per Site.
# Run by hand or by the tests station. GitHub is a fake gh written here (answers from a folder), so no test reaches the network; temp state only.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kcib-' + [guid]::NewGuid().ToString('N'))
$kr = Join-Path $root 'kitchen'; $gh = Join-Path $root 'gh'; $tower = Join-Path $root 'private-app'; $pubTower = Join-Path $root 'open-repo'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_GH', 'FAKE_CI_DIR', 'KITCHEN_CI_NOW', 'KITCHEN_GITHUB_OWNER') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
# the fake gh: `gh api <path>` answers <dir>\api\<sha of path>.json; offline.txt fails every call like a dropped network; calls.log lists calls
$fake = @'
$dir = $env:FAKE_CI_DIR; Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value ($args -join ' ')
if (Test-Path -LiteralPath (Join-Path $dir 'offline.txt')) { [Console]::Error.WriteLine('error connecting to api.github.com'); exit 1 }
if ($args[0] -ne 'api') { [Console]::Error.WriteLine("unknown command $($args[0])"); exit 1 }
$k = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$args[1]))).Replace('-', '').Substring(0, 16)
$p = Join-Path $dir "api\$k.json"; if (-not (Test-Path -LiteralPath $p)) { [Console]::Error.WriteLine('gh: Not Found (HTTP 404)'); exit 1 }
Get-Content -LiteralPath $p -Raw; exit 0
'@
function Key([string]$s) { [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($s))).Replace('-', '').Substring(0, 16) }
function Answer([string]$path, $obj) { $obj | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $gh "api\$(Key $path).json") -Encoding utf8 }
function Calls { @(Get-Content (Join-Path $gh 'calls.log') -ErrorAction SilentlyContinue) }
function New-CiJob([string]$os, [int]$sec) { @{ labels = @($os); started_at = '2026-10-05T10:00:00Z'; completed_at = ([DateTimeOffset]'2026-10-05T10:00:00Z').AddSeconds($sec).ToString('o') } }
function Registry($sites) { @{ sites = $sites } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $kr 'kitchen.json') -Encoding utf8 }
try {
    New-Item -ItemType Directory -Force -Path $kr, (Join-Path $gh 'api'), $tower, $pubTower | Out-Null
    Set-Content (Join-Path $root 'fake-gh.ps1') $fake -Encoding utf8
    $env:BRAIN_KITCHEN = $kr; $env:KITCHEN_GH = Join-Path $root 'fake-gh.ps1'; $env:FAKE_CI_DIR = $gh; $env:KITCHEN_CI_NOW = '2026-10-20T12:00:00Z'; $env:KITCHEN_GITHUB_OWNER = $null
    foreach ($t in @(@($tower, 'JVonBorstel/private-app', 'TD'), @($pubTower, 'JVonBorstel/open-repo', 'ZG'))) {
        & git -C $t[0] init -q -b main 2>&1 | Out-Null
        @{ github = $t[1]; site = $t[2] } | ConvertTo-Json | Set-Content (Join-Path $t[0] 'kitchen.repo.json')
        & git -C $t[0] -c user.name=t -c user.email=t@localhost add -A 2>&1 | Out-Null; & git -C $t[0] -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    }
    . (Join-Path $kd 'ci-budget-lib.ps1')

    # ---- 1. budgets and billed minutes
    Check 'budget: a whole number, "unlimited", absent' ((ConvertTo-CiBudget 1000).limit -eq 1000 -and (ConvertTo-CiBudget 'Unlimited').unlimited -and -not (ConvertTo-CiBudget $null).given)
    Check 'budget: a wrong value is named and holds nothing' ((ConvertTo-CiBudget -5).bad -match 'ciMinutesPerMonth' -and (ConvertTo-CiBudget 'lots').bad -and -not (ConvertTo-CiBudget 'lots').given)
    Check 'minutes: each job rounded up, Windows 2x, a skipped job 0' ((Get-CiRunMinutes @((New-CiJob 'ubuntu-latest' 61), (New-CiJob 'windows-latest' 30), (New-CiJob 'ubuntu-latest' 0))) -eq 4)
    Check 'month: calendar month in UTC, ends on the 1st' ((Get-CiMonth) -eq '2026-10' -and (Get-CiMonthEnd).ToString('o') -eq '2026-11-01T00:00:00.0000000Z')

    # ---- 2. a private Tower over budget: counted, measured, held; raised budget lets go
    $bm = 'JVonBorstel/private-app'; $runsPath = "repos/$bm/actions/runs?created=%3E%3D2026-10-01&per_page=100&page=1"
    Answer "repos/$bm" @{ private = $true }
    Answer $runsPath @{ total_count = 3; workflow_runs = @(@{ id = 11; status = 'in_progress' }, @{ id = 12; status = 'completed' }, @{ id = 13; status = 'completed' }) }
    Answer "repos/$bm/actions/runs/12/jobs?per_page=100" @{ jobs = @((New-CiJob 'ubuntu-latest' 300), (New-CiJob 'ubuntu-latest' 59)) }
    Answer "repos/$bm/actions/runs/13/jobs?per_page=100" @{ jobs = @((New-CiJob 'windows-latest' 600)) }
    Registry @{ TD = @{ ciMinutesPerMonth = 20 } }
    $d = Update-CiBudget $kr @($tower) 20
    $td = @($d.sites | Where-Object { $_.code -eq 'TD' })[0]
    Check 'count: 3 runs (GitHub''s own count), 26 billed minutes (5+1 Linux, 10x2 Windows), all finished runs measured' ($td.runs -eq 3 -and $td.minutes -eq 26 -and $td.state -eq 'ok' -and $td.towers[0].measured -eq 2)
    Check 'count: over a budget of 20; the file and the pool line are written' ($td.over -and (Test-Path (Join-Path $kr 'ci-budget.json')) -and $d.pool.minutesAtLeast -eq 26 -and $d.poolLimit -eq 2000)
    $h = Get-CiBudgetHold $kr 'TD'
    Check 'hold: Site TD holds new PRs, the reason names the minutes and the way out' ($h.hold -and $h.why -match 'at least 26 of 20 billed minutes' -and $h.why -match 'ciMinutesPerMonth')
    Check 'hold: another Site, or no Site, is not held' (-not (Get-CiBudgetHold $kr 'GW').hold -and -not (Get-CiBudgetHold $kr '').hold)
    Registry @{ TD = @{ ciMinutesPerMonth = 'unlimited' } }
    Check 'hold: a budget raised to "unlimited" lets PRs go at once (no recount needed)' (-not (Get-CiBudgetHold $kr 'TD').hold)
    Registry @{ TD = @{ ciMinutesPerMonth = 26 } }
    Check 'hold: reaching the budget exactly is over' ((Get-CiBudgetHold $kr 'TD').hold)
    $env:KITCHEN_CI_NOW = '2026-11-02T00:00:00Z'
    Check 'hold: a new month starts free (last month''s file holds nothing)' (-not (Get-CiBudgetHold $kr 'TD').hold)
    $env:KITCHEN_CI_NOW = '2026-10-20T12:00:00Z'

    # ---- 3. the cache: a finished run is measured once
    Remove-Item (Join-Path $gh 'calls.log')
    $d = Update-CiBudget $kr @($tower) 20
    Check 'cache: a second count asks for no job lists again and gives the same minutes' (@(Calls | Where-Object { $_ -match '/jobs' }).Count -eq 0 -and @($d.sites | Where-Object { $_.code -eq 'TD' })[0].minutes -eq 26)
    Check 'cache: the Tower is remembered from this month''s file (no order names it now)' (@((Update-CiBudget $kr @() 20).sites | Where-Object { $_.code -eq 'TD' })[0].runs -eq 3)

    # ---- 4. GitHub cannot be read: unknown with the reason, never zero, never a hold by itself
    Set-Content (Join-Path $gh 'offline.txt') 'x'; Registry @{ TD = @{ ciMinutesPerMonth = 0 } }
    $d = Update-CiBudget $kr @($tower) 20; $td = @($d.sites | Where-Object { $_.code -eq 'TD' })[0]
    Check 'unknown: runs and minutes are null (not 0), the reason says GitHub could not be read' ($td.state -eq 'unknown' -and $null -eq $td.runs -and $null -eq $td.minutes -and $null -eq $td.minutesAtLeast -and $td.why -match 'could not read' -and $d.pool.state -eq 'unknown')
    Check 'unknown: never holds by itself, even with a budget of 0' (-not $td.over -and -not (Get-CiBudgetHold $kr 'TD').hold)
    Remove-Item (Join-Path $gh 'offline.txt')

    # ---- 5. measuring cut short (time budget) or a failed job list: partial, a lower bound that still proves "over"
    Remove-Item (Join-Path $kr 'ci-budget-cache.json'); Registry @{ TD = @{ ciMinutesPerMonth = 5 } }
    $d = Update-CiBudget $kr @($tower) 0; $td = @($d.sites | Where-Object { $_.code -eq 'TD' })[0]
    Check 'partial: out of time = nothing measured yet, said so; 0 measured minutes hold nothing' ($td.state -eq 'partial' -and $td.why -match 'time budget' -and $td.minutesAtLeast -eq 0 -and -not $td.over)
    Remove-Item (Join-Path $gh "api\$(Key "repos/$bm/actions/runs/13/jobs?per_page=100").json")
    $d = Update-CiBudget $kr @($tower) 20; $td = @($d.sites | Where-Object { $_.code -eq 'TD' })[0]
    Check 'partial: a failed job list keeps what was measured (6 of a budget of 5 = over), with the reason' ($td.state -eq 'partial' -and $td.minutesAtLeast -eq 6 -and $td.why -match 'run 13' -and $td.over -and (Get-CiBudgetHold $kr 'TD').hold)

    # ---- 6. a public Tower: runs counted, 0 billed (free), never over; a budgeted Site with no Tower says so
    $op = 'JVonBorstel/open-repo'
    Answer "repos/$op" @{ private = $false }
    Answer "repos/$op/actions/runs?created=%3E%3D2026-10-01&per_page=100&page=1" @{ total_count = 2; workflow_runs = @(@{ id = 21; status = 'completed' }, @{ id = 22; status = 'completed' }) }
    Registry @{ ZG = @{ ciMinutesPerMonth = 1 }; JH = @{ ciMinutesPerMonth = 'unlimited' } }
    $d = Update-CiBudget $kr @($pubTower) 20; $zg = @($d.sites | Where-Object { $_.code -eq 'ZG' })[0]; $jh = @($d.sites | Where-Object { $_.code -eq 'JH' })[0]
    Check 'public: 2 runs counted, 0 billed minutes, not over a budget of 1, no job lists asked' ($zg.runs -eq 2 -and $zg.minutes -eq 0 -and -not $zg.over -and $zg.towers[0].public -and -not @(Calls | Where-Object { $_ -match "$op/actions/runs/\d+/jobs" }).Count)
    Check 'no Tower: a budgeted Site with no Tower on GitHub is "none", no numbers' ($jh.state -eq 'none' -and $null -eq $jh.runs -and $jh.budget -eq 'unlimited')
    # ---- 6b. review #11 F5: a registry Tower written with an environment variable (the documented %USERPROFILE%\... form) is counted
    $env:KCIB_F5_ROOT = $root
    try {
        $ct = @(Get-CiTowers @{ sites = @{ ZG = @{ towers = @('%KCIB_F5_ROOT%\open-repo') } } } @($pubTower))
        Check 'EnvTower: a %VAR% registry Tower is expanded, found on disk (its GitHub slug read), and the same Tower given by path is not counted twice' ($ct.Count -eq 1 -and $ct[0].slug -eq $op -and $ct[0].site -eq 'ZG' -and $ct[0].path -eq $pubTower)
        Registry @{ ZG = @{ ciMinutesPerMonth = 1; towers = @('%KCIB_F5_ROOT%\open-repo') } }
        $d = Update-CiBudget $kr @() 20; $zg = @($d.sites | Where-Object { $_.code -eq 'ZG' })[0]
        Check 'EnvTower: its Site gets its runs (not "no Tower of this Site is on GitHub")' ($zg.state -eq 'ok' -and $zg.runs -eq 2 -and $zg.why -notmatch 'no Tower')
    } finally { $env:KCIB_F5_ROOT = $null }
    Registry @{ TD = @{ ciMinutesPerMonth = 'lots' } }
    $d = Update-CiBudget $kr @($tower) 20
    Check 'settings: a wrong budget is named in problems and holds nothing' (@($d.problems | Where-Object { $_ -match 'sites\.TD' }).Count -eq 1 -and -not (Get-CiBudgetHold $kr 'TD').hold)
    Set-Content (Join-Path $kr 'kitchen.json') '{ torn'
    $d = Update-CiBudget $kr @($tower) 20
    Check 'settings: an unreadable registry is a problem line, no Sites, no hold' (@($d.problems).Count -eq 1 -and -not @($d.sites).Count -and -not (Get-CiBudgetHold $kr 'TD').hold)

    # ---- 7. the Board lines (pass-app/public/ci-budget.js, pure, run in node)
    $mjs = Join-Path $root 'cb.mjs'
    Set-Content $mjs @"
import { ciBudgetBanners } from '$(([Uri](Join-Path $PSScriptRoot '..\pass-app\public\ci-budget.js')).AbsoluteUri)';
const v = { month: '2026-10', monthEnds: '2026-11-01T00:00:00Z', poolLimit: 2000, pool: { state: 'unknown', minutesAtLeast: 1200 }, problems: ['sites.TD: bad'],
  sites: [{ code: 'TD', state: 'ok', runs: 300, minutes: 1200, minutesAtLeast: 1200, budget: 1000, over: true }, { code: 'GW', state: 'unknown', why: 'gh <x>', runs: null, minutes: null, minutesAtLeast: null, budget: 'unlimited', over: false },
    { code: 'ZG', state: 'partial', runs: 4, minutes: 3, minutesAtLeast: 3, budget: null, over: false }] };
console.log(JSON.stringify({ all: ciBudgetBanners(v, { day: () => 'Nov 1' }), none: ciBudgetBanners(null) }));
"@
    # node writes UTF-8 (the "·" in the count line); a console left on its OEM code page (437 here) would garble it before the match
    $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8
    try { $o = (& node $mjs | Out-String) | ConvertFrom-Json } finally { [Console]::OutputEncoding = $oldEnc }; $all = @($o.all) -join "`n"
    Check 'board: over budget is an alarm banner saying new PRs wait and what lets them go' ($all -match '<div class="banner" data-ci-budget="over">Site TD is over its CI budget: at least 1,200 of 1,000 billed minutes this month\. New pull requests for it wait until Nov 1')
    Check 'board: one calm count line; unknown says why (escaped) and no number; partial says "at least"' ($all -match 'banner calm" data-ci-budget="count">CI this month: Site TD: 300 runs, 1,200 of 1,000 min · Site GW: unknown \(gh &lt;x&gt;\) · Site ZG: 4 runs, at least 3 min \(still measuring\) · private pool: unknown, at least 1,200 of 2,000 min\.' -and $all -notmatch 'GW: 0')
    Check 'board: settings problems shown; nothing when there is no count' ($all -match 'CI budget: sites\.TD: bad' -and @($o.none).Count -eq 0)
}
finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "CiBudget tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
