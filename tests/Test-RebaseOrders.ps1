# Tests for scripts/rebase-orders.ps1: which orders are affected after main was replaced by an unrelated history (the 2026-10-26 cut-over
# to tide), the dry run (changes nothing), the refusals, and -Apply (backup, label, folder move, re-cook, kill and close; nothing deleted).
# The kitchen and cook scripts are fakes that log their calls. Self-cleaning: temp kitchen root and scratch repo only.
$ErrorActionPreference = 'Stop'
$tool = Join-Path $PSScriptRoot '..\scripts\rebase-orders.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kro-' + [guid]::NewGuid().ToString('N'))
$kr = Join-Path $root 'kitchen'; $repo = Join-Path $root 'repo'; $other = Join-Path $root 'other'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G { & git -C $repo -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
$fakeK = Join-Path $root 'fake-kitchen.ps1'; $fakeC = Join-Path $root 'fake-cook.ps1'
$kLog = Join-Path $root 'kitchen.log'; $cLog = Join-Path $root 'cook.log'
function Tool([string[]]$more = @()) {
    $o = (& pwsh -NoProfile -File $tool -Repo $repo -KitchenScript $fakeK -CookScript $fakeC @more 2>&1 | Out-String)
    [pscustomobject]@{ code = $LASTEXITCODE; out = $o }
}
function Job([string]$id, [string]$status, [string]$created, [string]$r = $repo, [int]$cursor = 0) {
    @{ id = $id; name = "improve: goal $id"; recipe = 'improve'; status = $status; cursor = $cursor; created = $created; history = @()
        vars = @{ goal = "goal of $id"; repo = $r }; steps = @(@{ script = 'C:\x\worktree.ps1'; args = @{ Repo = $r } }, @{ script = 'C:\x\tests.ps1'; args = @{} }) } |
        ConvertTo-Json -Depth 6 | Set-Content (Join-Path $kr "jobs\$id.json")
}
function Wt([string]$id) { & git -C $repo worktree add -q (Join-Path $kr "worktrees\$id") "kitchen/$id" 2>&1 | Out-Null }
$oldKitchen = $env:BRAIN_KITCHEN
try {
    New-Item -ItemType Directory -Path (Join-Path $kr 'jobs'), (Join-Path $kr 'worktrees'), $repo, $other | Out-Null
    $env:BRAIN_KITCHEN = $kr
    Set-Content $fakeK @'
$a = @($args); Add-Content -LiteralPath $env:FAKE_K_LOG -Value ($a -join ' ')
if ($env:FAKE_K_FAIL -and $a[0] -eq $env:FAKE_K_FAIL) { 'ERROR: fake refusal'; exit 2 }
"$($a[0])ed $($a[2])"; exit 0
'@
    Set-Content $fakeC @'
param([string]$Recipe, [hashtable]$Vars, [switch]$Json)
Add-Content -LiteralPath $env:FAKE_C_LOG -Value ("{0} {1}" -f $Recipe, ($Vars | ConvertTo-Json -Compress))
if ($env:FAKE_C_FAIL) { @{ ok = $false; error = 'no cook today' } | ConvertTo-Json -Compress; exit 2 }
@{ ok = $true; job = 'J100' } | ConvertTo-Json -Compress; exit 0
'@
    $env:FAKE_K_LOG = $kLog; $env:FAKE_C_LOG = $cLog
    # the old history: main with orders' branches cut from it
    & git -C $repo init -q -b main 2>&1 | Out-Null
    Set-Content "$repo\app.txt" 'a'; G add -A; G commit -q -m 'old base'
    foreach ($b in 'J1', 'J6', 'J7', 'J8') { G branch "kitchen/$b" }
    G checkout -q kitchen/J1; Set-Content "$repo\j1.txt" 'work'; G add -A; G commit -q -m 'J1 work'; G checkout -q main
    $tip1 = (& git -C $repo rev-parse kitchen/J1)
    Wt 'J1'; Wt 'J8'
    # the cut-over: main replaced by a fresh history with the same files (the old main kept)
    Start-Sleep -Seconds 1
    G branch -m main old-main; G checkout -q --orphan main; G commit -q -m 'fresh history'
    G branch kitchen/J9   # an order already on the new history: not affected
    $past = '2000-01-01T00:00:00Z'; $future = [DateTime]::UtcNow.AddHours(1).ToString('o')
    Job 'J1' 'pending' $past -cursor 1; Job 'J2' 'pending' $past; Job 'J3' 'pending' $future; Job 'J4' 'done' $past; Job 'J5' 'pending' $past $other
    Job 'J6' 'quarantined' $past -cursor 1; Job 'J7' 'running' $past -cursor 1; Job 'J8' 'needs-human' $past -cursor 1; Job 'J9' 'pending' $past -cursor 1
    $orig1 = Get-Content (Join-Path $kr 'jobs\J1.json') -Raw

    # 1. no -Ids: lists the affected orders only, changes nothing
    $r = Tool
    Check 'list: exit 0' ($r.code -eq 0)
    Check 'list: an old-history branch is affected' ($r.out -match 'J1\s+pending.*branch kitchen/J1 is on the old history; has a worktree' -and $r.out -match 'J6\s+quarantined' -and $r.out -match 'J7\s+running' -and $r.out -match 'J8\s+needs-human')
    Check 'list: an order with no branch queued before main began is affected' ($r.out -match 'J2\s+pending.*queued 2000-01-01')
    Check 'list: newer, done, other-repo and new-history orders are not' ($r.out -notmatch '\bJ3\b' -and $r.out -notmatch '\bJ4\b' -and $r.out -notmatch '\bJ5\b' -and $r.out -notmatch '\bJ9\b' -and $r.out -match '5 affected order')
    Check 'list: says how to go on, nothing changed' ($r.out -match 'no -Ids given' -and -not (Test-Path (Join-Path $kr 'pre-tide')) -and -not (Test-Path $kLog) -and -not (Test-Path $cLog))

    # 2. dry run for chosen orders: every step said, nothing done
    $r = Tool @('-Ids', 'J1,J2')
    Check 'dry run: exit 0, says DRY RUN' ($r.code -eq 0 -and $r.out -match 'DRY RUN' -and $r.out -match 'dry run done: 2 order')
    Check 'dry run: J1 steps (backup, label, move, cook, kill, close)' ($r.out -match 'copy the job file to .*pre-tide\\jobs\\J1\.json' -and $r.out -match 'label kitchen/J1 as pre-tide/kitchen/J1' -and $r.out -match 'worktrees\\pre-tide-J1 \(git worktree move\)' -and $r.out -match 'cook\.ps1 -Recipe improve' -and $r.out -match 'kitchen\.ps1 kill -Id J1' -and $r.out -match 'kitchen\.ps1 close -Id J1 -ReplacedBy <new id>')
    Check 'dry run: J2 has nothing to label or move' ($r.out -match 'no branch yet: nothing to label' -and $r.out -match 'no worktree folder: nothing to move')
    Check 'dry run: nothing changed (no copy, no label, folder in place, no calls)' (-not (Test-Path (Join-Path $kr 'pre-tide')) -and -not (& git -C $repo rev-parse --verify --quiet pre-tide/kitchen/J1) -and (Test-Path (Join-Path $kr 'worktrees\J1\.git')) -and -not (Test-Path $kLog) -and -not (Test-Path $cLog))

    # 3. refusals (exit 2, nothing changed)
    $r = Tool @('-Ids', 'J3'); Check 'refused: an order that is not affected' ($r.code -eq 2 -and $r.out -match 'REFUSED: J3 is not an affected order')
    $r = Tool @('-Ids', 'J7'); Check 'refused: a running order' ($r.code -eq 2 -and $r.out -match 'REFUSED: J7 is running')
    $r = Tool @('-Ids', 'nope'); Check 'refused: not an order id' ($r.code -eq 2 -and $r.out -match "REFUSED: 'NOPE' is not an order id")
    $r = Tool @('-Ids', 'J1', '-Apply'); Check 'refused: -Apply while the Yard is not paused, nothing changed' ($r.code -eq 2 -and $r.out -match 'not paused' -and -not (Test-Path (Join-Path $kr 'pre-tide')) -and (Test-Path (Join-Path $kr 'worktrees\J1\.git')))

    # 4. apply: backup, label, folder moved, re-cooked with the same recipe and vars, the old order killed then closed naming the new one
    Set-Content (Join-Path $kr 'PAUSED') 'test'
    $r = Tool @('-Ids', 'J1', '-Apply')
    Check 'apply: exit 0, says what it made' ($r.code -eq 0 -and $r.out -match 're-cooked recipe improve as J100' -and $r.out -match 'done: 1 of 1 re-cooked \(new: J100\)')
    Check 'apply: the job file is copied first, byte for byte' ((Get-Content (Join-Path $kr 'pre-tide\jobs\J1.json') -Raw) -eq $orig1)
    Check 'apply: the old branch is labelled pre-tide and kept' ((& git -C $repo rev-parse pre-tide/kitchen/J1) -eq $tip1 -and (& git -C $repo rev-parse kitchen/J1) -eq $tip1)
    $wl = (& git -C $repo worktree list --porcelain) -join "`n"
    Check 'apply: the folder is moved out of the doctor''s reach, still a worktree, work intact' (-not (Test-Path (Join-Path $kr 'worktrees\J1')) -and (Test-Path (Join-Path $kr 'worktrees\pre-tide-J1\j1.txt')) -and $wl -match 'pre-tide-J1')
    $cl = Get-Content $cLog -Raw
    Check 'apply: re-cooked with its recipe and vars' ($cl -match '^improve ' -and $cl -match 'goal of J1')
    $kl = @(Get-Content $kLog)
    Check 'apply: kill then close -ReplacedBy the new order, with the reason' ($kl.Count -eq 2 -and $kl[0] -eq 'kill -Id J1' -and $kl[1] -match '^close -Id J1 -ReplacedBy J100 -Why re-cooked on the new main after the 2026-10-26 cut-over')
    $jl = @(Get-Content (Join-Path $kr 'pre-tide\rebase-orders.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'apply: every step logged' ((($jl | ForEach-Object { $_.step }) -join ',') -eq 'backup,label,move,cook,kill,close' -and @($jl | Where-Object { -not $_.ok }).Count -eq 0)

    # 5. a quarantined order is closed without a kill; a second backup never overwrites the first
    Remove-Item $kLog
    $r = Tool @('-Ids', 'J6', '-Apply')
    Check 'apply: a set-aside order is only closed (no kill)' ($r.code -eq 0 -and @(Get-Content $kLog).Count -eq 1 -and (Get-Content $kLog) -match '^close -Id J6')
    $r = Tool @('-Ids', 'J6', '-Apply')
    Check 'apply again: the first copy is kept, the second gets the time; the label is left as it is' ($r.code -eq 0 -and @(Get-ChildItem (Join-Path $kr 'pre-tide\jobs') -Filter 'J6*.json').Count -eq 2 -and $r.out -match 'pre-tide/kitchen/J6 already exists')

    # 6. a failed cook moves the folder back and stops: the old order is not killed or closed
    Remove-Item $kLog; $env:FAKE_C_FAIL = '1'
    try { $r = Tool @('-Ids', 'J8', '-Apply') } finally { $env:FAKE_C_FAIL = $null }
    Check 'cook fails: exit 1, said plainly, folder moved back' ($r.code -eq 1 -and $r.out -match 'FAILED to re-cook recipe improve: no cook today' -and $r.out -match 'The folder is moved back' -and (Test-Path (Join-Path $kr 'worktrees\J8\.git')) -and -not (Test-Path (Join-Path $kr 'worktrees\pre-tide-J8')))
    Check 'cook fails: the old order is not touched by the kitchen' (-not (Test-Path $kLog))

    # 7. a kitchen refusal after the cook names the command left to run by hand
    $env:FAKE_K_FAIL = 'close'
    try { $r = Tool @('-Ids', 'J2', '-Apply') } finally { $env:FAKE_K_FAIL = $null }
    Check 'close refused: exit 1, names the new order and the command to finish by hand' ($r.code -eq 1 -and $r.out -match 'The new order J100 is made; finish by hand: kitchen\.ps1 close -Id J2 -ReplacedBy J100')
}
finally {
    $env:BRAIN_KITCHEN = $oldKitchen; $env:FAKE_K_LOG = $null; $env:FAKE_C_LOG = $null
    if (Test-Path -LiteralPath $repo) { & git -C $repo worktree prune 2>&1 | Out-Null }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "RebaseOrders tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
