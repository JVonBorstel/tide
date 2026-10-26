# Tests for kitchen/kitchen.ps1: every swarm misbehaviour is caught, state survives a supervisor restart, approvals are remembered.
# Uses a private kitchen root under TEMP; self-cleaning.
$ErrorActionPreference = 'Stop'
$k = Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1'
$w = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\demo-worker.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-' + [guid]::NewGuid().ToString('N'))
$env:BRAIN_KITCHEN = $root; $env:KITCHEN_AGY_EXE = 'off'; $env:BRAIN_NTFY_TOPIC = $null; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null
$script:pass = 0; $script:fail = 0
function Check($n, $c, [scriptblock]$why = $null) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n"; if ($why) { try { & $why | ForEach-Object { Write-Host "  $_" } } catch { Write-Host "  (evidence unreadable: $($_.Exception.Message))" } } } }
# Evidence for a failed check: every job in a kitchen root, its status and its last attempts (outcome, detail, when).
function Show-Jobs([string]$r = $root) {
    foreach ($f in @(Get-ChildItem (Join-Path $r "jobs") -Filter "J*.json" -ErrorAction SilentlyContinue | Sort-Object { [int]($_.BaseName -replace "\D") })) {
        try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { "$($f.BaseName): unreadable ($($_.Exception.Message))"; continue }
        $h = @($j.history | Select-Object -Last 3 | ForEach-Object { "$($_.outcome)$(if ($_.detail) { ": " + $_.detail }) @$($_.at)" }) -join "; "
        "$($j.id) $($j.status) $($j.name) attempts=$(@($j.history).Count) [$h]"
    }
}
function Job($id) { Get-Content (Join-Path $root "jobs\$id.json") -Raw | ConvertFrom-Json }
function ToUtcT($v) { if ($v -is [DateTime]) { $v.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } }
function Events { @(Get-Content (Join-Path $root 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }) }
# Limits are roomy (60 s heartbeat, 120 s run) so a loaded PC never turns a slow start into a false 'hung' or 'timeout': measured 10-24
# with 16 busy threads and 4 suites at once, a worker's pwsh took over 6 s to write its first heartbeat, so the old 6 s limit killed
# J1, J2 and the spawner as 'hung' on both attempts (spawner quarantined, 4 of 4 runs). The jobs that test a limit set their own
# (hang: HungSec 6, slow: TimeoutSec 5), so every limit is still proven.
function Add([string]$name, [string]$b, [hashtable]$extra = @{}) {
    $p = @{ Name = $name; Script = $w; ScriptArgs = @{ Behavior = $b; Seconds = 2 }; TimeoutSec = 120; MaxMB = 400; MaxLogMB = 5; HungSec = 60; Retries = 1 }
    foreach ($key in $extra.Keys) { $p[$key] = $extra[$key] }
    & $k add @p | Out-String
}
try {
    # 1. add + refusals
    Check 'add ok' ((Add 'good' 'ok') -match '^added J1')
    Check 'missing script refused' ((& $k add -Name x -Script 'C:\nope\x.ps1' | Out-String) -match 'ERROR')
    $env:BRAIN_AGENT_DEPTH = '2'; $o = & $k add -Name deep -Script $w | Out-String; $code = $LASTEXITCODE; $env:BRAIN_AGENT_DEPTH = $null
    Check 'depth 2 may not add jobs (exit 3)' ($code -eq 3 -and $o -match 'depth cap')
    $env:BRAIN_AGENT_DEPTH = 'abc'; $o = & $k add -Name bad -Script $w | Out-String; $env:BRAIN_AGENT_DEPTH = $null
    Check 'garbage depth fails closed' ($o -match 'ERROR')

    # 2. one job per misbehaviour, small swarm
    Add 'flaky' 'flaky' | Out-Null      # J2
    Add 'fail' 'fail' | Out-Null        # J3
    Add 'crash' 'crash' | Out-Null      # J4 (safe replay -> retried -> quarantined)
    Add 'hog' 'hog' | Out-Null          # J5
    Add 'flood' 'flood' | Out-Null      # J6
    Add 'hang' 'hang' @{ HungSec = 6 } | Out-Null                      # J7 (the heartbeat limit under test)
    Add 'slow' 'slow' @{ TimeoutSec = 5 } | Out-Null                   # J8
    Add 'unsafe-crash' 'crash' @{ Replay = 'unsafe' } | Out-Null       # J9 -> needs-human
    Add 'gated' 'ok' @{ Approve = $true } | Out-Null                   # J10 -> waiting-approval
    Add 'spawner' 'spawner' | Out-Null                                 # J11 -> 5 children max

    # supervisor "crash": first watch is cut short, a second one resumes from disk
    & $k watch -Seconds 6 -MaxConcurrent 6 -BackoffBaseSec 1 -BreakerMin 99 -Quiet | Out-Null
    $mid = @(Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json').Count
    # watch returns as soon as no job is pending or running; -Seconds is only the bound (quiet PC: about 40 s)
    $sw2 = [Diagnostics.Stopwatch]::StartNew(); & $k watch -Seconds 300 -MaxConcurrent 6 -BackoffBaseSec 1 -BreakerMin 99 -Quiet | Out-Null; $sw2.Stop()

    Check 'ok job done' ((Job J1).status -eq 'done')
    Check 'flaky job retried then done' ((Job J2).status -eq 'done' -and @((Job J2).history | ? outcome -eq 'fail').Count -eq 1)
    Check 'always-failing job quarantined' ((Job J3).status -eq 'quarantined')
    Check 'crash detected' (@((Job J4).history | ? outcome -eq 'crash').Count -ge 1)
    Check 'crashing safe job quarantined after retries' ((Job J4).status -eq 'quarantined')
    Check 'memory hog capped' (@((Job J5).history | ? outcome -eq 'memcap').Count -ge 1)
    Check 'log flood capped' (@((Job J6).history | ? outcome -eq 'logflood').Count -ge 1)
    Check 'hung worker caught by heartbeat' (@((Job J7).history | ? outcome -eq 'hung').Count -ge 1)
    Check 'slow worker timed out' (@((Job J8).history | Where-Object outcome -eq 'timeout').Count -ge 1)
    Check 'unsafe step not replayed; needs a human' ((Job J9).status -eq 'needs-human' -and @((Job J9).history).Count -eq 1)
    Check 'gated step waits for approval' ((Job J10).status -eq 'waiting-approval' -and @((Job J10).history).Count -eq 0)
    Check 'spawner done' ((Job J11).status -eq 'done') { "second watch ran $([int]$sw2.Elapsed.TotalSeconds)s (bound 300s)"; Show-Jobs }
    $kids = @(Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json' | % { Get-Content $_.FullName -Raw | ConvertFrom-Json } | ? parent -eq 'J11')
    Check 'child cap held (5 of 20)' ($kids.Count -eq 5)
    Check 'children ran at depth 1' (@($kids | ? depth -eq 1).Count -eq 5 -and @($kids | ? status -eq 'done').Count -eq 5)
    Check 'refused spawns logged' (@(Events | ? type -eq 'spawn.refused').Count -ge 15)
    Check 'alerts written for attention items' (@(Get-Content (Join-Path $root 'alerts.jsonl')).Count -ge 4)
    Check 'state survived the supervisor restart' ($mid -ge 11)

    # 3. no worker left behind
    $left = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | ? { $_.CommandLine -like "*$root*" })
    Check 'no orphan workers' ($left.Count -eq 0)

    # 4. approval: yes is remembered, step runs, never asked again
    & $k approve -Id J10 | Out-Null
    $sw4 = [Diagnostics.Stopwatch]::StartNew(); & $k watch -Seconds 120 -BreakerMin 99 -Quiet | Out-Null; $sw4.Stop()
    Check 'approved job ran' ((Job J10).status -eq 'done') { "watch ran $([int]$sw4.Elapsed.TotalSeconds)s (bound 120s)"; Show-Jobs }
    Check 'asked exactly once' (@(Events | ? { $_.type -eq 'approval.requested' -and $_.job -eq 'J10' }).Count -eq 1)
    Check 'approval recorded with hash in queue' ((Get-Content (Join-Path $root 'approvals.md') -Raw) -match 'A\d+ \| MED \| .*start step 1 of 1 .* \| sha:[0-9a-f]{12} \| status:yes')

    # 5. unsafe replay only after a yes
    & $k approve -Id J9 | Out-Null
    & $k watch -Seconds 120 -BackoffBaseSec 1 -BreakerMin 99 -Quiet | Out-Null
    Check 'unsafe step re-ran only after approval' (@((Job J9).history).Count -ge 2) { Show-Jobs }

    # 6. kill (ticks until the worker has a pid, up to 30 s: one tick under load may not start it, and a null pid crashed Get-Process)
    Add 'to-kill' 'slow' @{ TimeoutSec = 60 } | Out-Null
    $id = 'J' + (@(Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json').Count)
    $until = (Get-Date).AddSeconds(30)
    do { & $k tick -Quiet | Out-Null; $wpid = (Job $id).run.pid; if (-not $wpid) { Start-Sleep -Milliseconds 300 } } while (-not $wpid -and (Get-Date) -lt $until)
    & $k kill -Id $id | Out-Null
    $until = (Get-Date).AddSeconds(10)
    while ($wpid -and (Get-Process -Id $wpid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
    Check 'kill stops the worker' ((Job $id).status -eq 'killed' -and $wpid -and -not (Get-Process -Id $wpid -ErrorAction SilentlyContinue)) { "worker pid '$wpid'"; Show-Jobs }

    # 7. circuit breaker: a swarm of failures stops new starts
    $env:BRAIN_KITCHEN = "$root-b"
    for ($i = 1; $i -le 8; $i++) { Add "f$i" 'fail' @{ Retries = 0 } | Out-Null }
    Add 'after' 'ok' | Out-Null
    & $k watch -Seconds 25 -MaxConcurrent 2 -BreakerMin 4 -BreakerWindow 4 -BreakerCoolSec 300 -Quiet | Out-Null
    $ev = @(Get-Content "$root-b\events.jsonl" | % { $_ | ConvertFrom-Json })
    Check 'breaker opened' (@($ev | ? type -eq 'breaker.open').Count -eq 1)
    Check 'breaker held back remaining work' ((Get-Content "$root-b\jobs\J9.json" -Raw | ConvertFrom-Json).status -eq 'pending')
    # TD-EH-07: one HIGH alert for the episode, in plain words; the episode and its cool-down are kept in supervisor.json
    $bal = @(Get-Content "$root-b\alerts.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.text -match 'Stop-work order' })
    Check 'stop-work: one HIGH alert for the episode, saying how long new work waits' ($bal.Count -eq 1 -and $bal[0].level -eq 'HIGH' -and $bal[0].text -match 'No new work starts for 5 min; then one trial step runs first')
    $bop = @($ev | Where-Object type -eq 'breaker.open')[0]
    $bmeta = Get-Content "$root-b\supervisor.json" -Raw | ConvertFrom-Json
    Check 'stop-work: the open event and supervisor.json carry the episode and its cool-down' ([int]$bop.coolSec -eq 300 -and [int]$bop.episode -eq 1 -and $bop.note -eq 'new work waits 5 min' -and $bmeta.breakerTripped -and $bmeta.breakerEpisode.tripped -and [int]$bmeta.breakerEpisode.n -eq 1 -and [int]$bmeta.breakerEpisode.alerted -eq 1)
    Check 'stop-work: status says it is on and for how long' ((& $k status | Out-String) -match 'STOP-WORK ORDER on: no new work for \d+ min more')
    # TD-8: no Sites registry = exactly the old behaviour: one Yard-wide order, no Site keys anywhere, and a stray PAUSED-<code> is not read
    Check 'TD-8: with no Sites the Stop-work order is Yard-wide, as before' (-not $bmeta.siteBreakers -and @($ev | Where-Object { $_.type -match '^breaker\.' -and $null -ne $_.site }).Count -eq 0)
    Set-Content "$root-b\PAUSED-TD" 'test'
    $nsp = & $k pause -Site TD | Out-String
    Check 'TD-8: with no Sites, pause -Site refuses and says how to stop the whole Yard' ($nsp -match 'ERROR' -and $nsp -match 'no Sites are registered' -and -not (Test-Path "$root-b\PAUSED")) { $nsp }
    $env:BRAIN_KITCHEN = "$root-nosite"; New-Item -ItemType Directory -Force "$root-nosite" | Out-Null; Set-Content "$root-nosite\PAUSED-TD" 'test'
    Add 'no sites' 'ok' @{ Retries = 0 } | Out-Null
    $nsj = Get-Content "$root-nosite\jobs\J1.json" -Raw | ConvertFrom-Json -AsHashtable; $nsj.vars = @{ site = 'TD' }; $nsj | ConvertTo-Json -Depth 20 | Set-Content "$root-nosite\jobs\J1.json" -Encoding utf8
    & $k watch -Seconds 10 -BreakerMin 99 -Quiet | Out-Null
    $nsm = Get-Content "$root-nosite\supervisor.json" -Raw | ConvertFrom-Json
    Check "TD-8: with no Sites a TD order starts despite a stray PAUSED-TD, and no Site state is kept" ((Get-Content "$root-nosite\jobs\J1.json" -Raw | ConvertFrom-Json).status -eq 'done' -and -not $nsm.siteBreakers) { Show-Jobs "$root-nosite" }
    $env:BRAIN_KITCHEN = "$root-b"
    & $k kill -All | Out-Null

    # 7a. TD-EH-08: a failed step really waits before its retry (30 s for a code failure, +-20 %), and says so in plain words
    $env:BRAIN_KITCHEN = "$root-r"
    Add 'fails once' 'fail' @{ Retries = 1 } | Out-Null
    & $k watch -Seconds 12 -BreakerMin 99 -Quiet | Out-Null
    $rj = Get-Content "$root-r\jobs\J1.json" -Raw | ConvertFrom-Json
    $rr = @(Get-Content "$root-r\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'step.retry')
    Check 'back-off: the retry event says "waiting 1 min before retry" (a code failure, 24-36 s)' ($rr.Count -eq 1 -and [double]$rr[0].inSec -ge 24 -and [double]$rr[0].inSec -le 36 -and $rr[0].class -eq 'code' -and [int]$rr[0].waitMin -eq 1 -and $rr[0].note -eq 'waiting 1 min before retry')
    Check 'back-off: the order waits (pending, one failure, not retried within the 12 s run)' ($rj.status -eq 'pending' -and @($rj.history | Where-Object outcome -eq 'fail').Count -eq 1 -and (ToUtcT $rj.notBefore) -gt [DateTime]::UtcNow.AddSeconds(5) -and $rj.retryWait.text -eq 'waiting 1 min before retry')
    Check 'back-off: status shows the wait in plain words' ((& $k status | Out-String) -match 'J1 .*waiting 1 min before retry; last fail: exit 1')
    & $k kill -All | Out-Null
    Remove-Item -Recurse -Force "$root-r" -ErrorAction SilentlyContinue

    # 7b. taster, cost ledger, daily budget
    $env:BRAIN_KITCHEN = "$root-t"
    & $k add -Name skipper -Script $w -ScriptArgs @{ Behavior = 'skipper' } -MustMatch '\d+ passed' -MustNotMatch '\bskipped\b' -Retries 0 | Out-Null
    & $k add -Name honest -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } -MustMatch 'working 1/1' -MustNotMatch '\bskipped\b' | Out-Null
    Check 'bad taster regex refused' ((& $k add -Name badrx -Script $w -MustMatch '([' | Out-String) -match 'not a valid regex')
    & $k watch -Seconds 20 -BreakerMin 99 -Quiet | Out-Null
    $tj = Get-Content "$root-t\jobs\J1.json" -Raw | ConvertFrom-Json
    Check 'taster catches skipped tests behind exit 0' ($tj.status -eq 'quarantined' -and $tj.history[-1].outcome -eq 'taster' -and $tj.history[-1].detail -match 'skipped')
    Check 'taster passes honest work' ((Get-Content "$root-t\jobs\J2.json" -Raw | ConvertFrom-Json).status -eq 'done')
    & $k add -Name pricey -Script $w -ScriptArgs @{ Behavior = 'costly' } | Out-Null
    & $k watch -Seconds 15 -BreakerMin 99 -DailyBudgetUsd 6 -Quiet | Out-Null
    & $k add -Name after-budget -Script $w -ScriptArgs @{ Behavior = 'costly' } | Out-Null
    & $k add -Name blocked -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null
    & $k watch -Seconds 15 -BreakerMin 99 -DailyBudgetUsd 6 -MaxConcurrent 1 -Quiet | Out-Null   # budget is checked before each start round
    $pj = Get-Content "$root-t\jobs\J3.json" -Raw | ConvertFrom-Json
    Check 'cost receipt lands on the job ledger' ([double]$pj.costUsd -eq 5)
    $tev = @(Get-Content "$root-t\events.jsonl" | % { $_ | ConvertFrom-Json })
    Check 'cost event logged' (@($tev | ? { $_.type -eq 'cost' -and [double]$_.usd -eq 5 }).Count -ge 1)
    Check 'daily budget stops new work' (@($tev | ? type -eq 'budget.stop').Count -eq 1 -and (Get-Content "$root-t\jobs\J5.json" -Raw | ConvertFrom-Json).status -eq 'pending')
    Check 'status shows spend' ((& $k status -DailyBudgetUsd 6 | Out-String) -match 'spent today \$10\.00 of \$6\.00')
    & $k report -HtmlPath "$root-t\b.html" -DailyBudgetUsd 6 | Out-Null
    $bh = Get-Content "$root-t\b.html" -Raw
    Check 'board has the line and needs-you' ($bh -match 'Needs you' -and $bh -match 'Cooking' -and $bh -match 'Set aside' -and $bh -match 'Plated')
    Check 'board tells the chef what to type' ($bh -match 'just log J1')
    Check 'board shows supervisor and spend' ($bh -match 'Supervisor' -and $bh -match 'Spent today')
    & $k kill -All | Out-Null
    Remove-Item -Recurse -Force "$root-t" -ErrorAction SilentlyContinue

    # 7c. a pinned cook resting for hours: an autopilot order switches to the fallback cook at once (never claude, never private)
    $fake = Join-Path ([IO.Path]::GetTempPath()) ("kitchen-fakecook-$([guid]::NewGuid().ToString('N')).ps1")
    Set-Content -LiteralPath $fake -Encoding utf8 -Value @'
param([string]$Supplier = '', [switch]$Private)
$restWho = if ($env:FAKE_REST_WHO) { $env:FAKE_REST_WHO } else { 'antigravity' }
if ($Supplier -eq $restWho) { Set-Content -LiteralPath "$($env:KITCHEN_RUN).wait" -Value $env:FAKE_REST; 'every able cook is resting'; exit 11 }
"cooked by $Supplier"; exit 0
'@
    function Rest-Case([string]$tag, [string]$name, [hashtable]$args1, [int]$rest, [string]$cfg = '', [int]$secs = 12, [hashtable]$args2 = $null, [string]$restWho = 'antigravity') {
        $env:BRAIN_KITCHEN = "$root-s$tag"; $env:FAKE_REST = [string]$rest; $env:FAKE_REST_WHO = $restWho
        New-Item -ItemType Directory -Force -Path $env:BRAIN_KITCHEN | Out-Null
        if ($cfg) { Set-Content -LiteralPath "$($env:BRAIN_KITCHEN)\kitchen.json" -Value $cfg -Encoding utf8 }
        $s2 = if ($args2) { $args2 } else { $args1 }
        $spec = @{ name = $name; steps = @(@{ script = $fake; args = $args1 }, @{ script = $fake; args = $s2 }) } | ConvertTo-Json -Depth 6
        $sp = Join-Path $env:BRAIN_KITCHEN 'spec.json'; Set-Content -LiteralPath $sp -Value $spec -Encoding utf8
        & $k add -SpecPath $sp | Out-Null
        & $k watch -Seconds $secs -BreakerMin 99 -Quiet | Out-Null
        $r = @{ job = (Get-Content "$($env:BRAIN_KITCHEN)\jobs\J1.json" -Raw | ConvertFrom-Json); ev = @(Get-Content "$($env:BRAIN_KITCHEN)\events.jsonl" | % { $_ | ConvertFrom-Json }) }
        & $k kill -All | Out-Null
        $env:FAKE_REST_WHO = $null
        $r
    }
    $c = Rest-Case 'a' 'improve:rest' @{ Supplier = 'antigravity' } 10800
    Check 'long rest: switched once' (@($c.ev | ? type -eq 'cook.switched').Count -eq 1 -and @($c.ev | ? type -eq 'step.wait').Count -eq 0)
    Check 'long rest: all remaining steps moved to gemini and the order finished' ($c.job.status -eq 'done' -and @($c.job.steps | ? { $_.args.Supplier -eq 'gemini' }).Count -eq 2)
    $c = Rest-Case 'b' 'improve:rest' @{ Supplier = 'antigravity' } 3600 -secs 6
    Check 'short rest: waits, no switch' (@($c.ev | ? type -eq 'cook.switched').Count -eq 0 -and @($c.ev | ? type -eq 'step.wait').Count -ge 1 -and $c.job.steps[0].args.Supplier -eq 'antigravity')
    $c = Rest-Case 'c' 'improve:rest' @{ Supplier = 'antigravity'; Private = $true } 10800 -secs 6
    Check 'private step is never switched away' (@($c.ev | ? type -eq 'cook.switched').Count -eq 0 -and $c.job.steps[0].args.Supplier -eq 'antigravity')
    $c = Rest-Case 'd' 'improve:rest' @{ Supplier = 'antigravity' } 10800 '{"autopilot":{"fallbackCook":"claude"}}' -secs 6
    Check 'never switches to claude' (@($c.ev | ? type -eq 'cook.switched').Count -eq 0 -and $c.job.steps[0].args.Supplier -eq 'antigravity')
    $c = Rest-Case 'e' 'plain-order' @{ Supplier = 'antigravity' } 10800 -secs 6
    Check 'non-autopilot order is not switched' (@($c.ev | ? type -eq 'cook.switched').Count -eq 0 -and $c.job.steps[0].args.Supplier -eq 'antigravity')
    $c = Rest-Case 'f' 'improve:rest' @{ Supplier = 'claude' } 10800 -secs 6 -args2 @{ Supplier = 'antigravity' } -restWho 'claude'
    Check 'mixed job: resting claude step waits and is not switched or retried' (@($c.ev | ? type -eq 'cook.switched').Count -eq 0 -and @($c.ev | ? type -eq 'step.wait').Count -ge 1 -and @($c.ev | ? type -eq 'step.started').Count -eq 1 -and $c.job.steps[0].args.Supplier -eq 'claude' -and $c.job.steps[1].args.Supplier -eq 'antigravity')
    $c = Rest-Case 'g' 'improve:rest' @{ Supplier = 'antigravity' } 10800 -args2 @{ Supplier = 'claude' }
    Check 'mixed job: antigravity step switches and claude step is unchanged' ($c.job.status -eq 'done' -and @($c.ev | ? type -eq 'cook.switched').Count -eq 1 -and $c.job.steps[0].args.Supplier -eq 'gemini' -and $c.job.steps[1].args.Supplier -eq 'claude')
    $env:FAKE_REST = $null; $env:FAKE_REST_WHO = $null
    Remove-Item -LiteralPath $fake -ErrorAction SilentlyContinue

    # 8. status and report
    $env:BRAIN_KITCHEN = $root
    Check 'status lists jobs' ((& $k status | Out-String) -match 'KITCHEN\s+\d+ jobs')
    & $k report -HtmlPath "$root\r.html" | Out-Null
    Check 'report written and escaped' ((Get-Content "$root\r.html" -Raw) -match 'Kitchen Status' -and (Get-Content "$root\r.html" -Raw) -notmatch '<script')

    # 9. Chef auto-update after improve merge
    $env:BRAIN_KITCHEN = $root
    $updatePs1 = (Resolve-Path (Join-Path $PSScriptRoot '..\pass-app\update.ps1')).Path

    # 9.1 direct update.ps1 -DryRun verification
    $pwshBin = (Get-Process -Id $PID).Path
    $dryOut = & $pwshBin -NoProfile -NonInteractive -File $updatePs1 -DryRun 2>&1
    Check 'update.ps1 -DryRun exits 0' ($LASTEXITCODE -eq 0)
    Check 'update.ps1 -DryRun outputs confirmation' (($dryOut | Out-String) -match 'Chef update dry-run ok: syntax valid')

    # helper to set up an improve job whose verify step (after its merge) just finished: the Chef update waits for a verified merge
    function Setup-MergeJob([string]$jid, [string[]]$files, [string]$recipe = 'improve', [string]$name = "improve: test $jid", [string]$code = '0', [int]$cursor = 1) {
        $runBase = Join-Path $root "run\$jid-s$cursor-a0"
        Set-Content -LiteralPath "$runBase.exit" -Value $code -Encoding utf8
        Set-Content -LiteralPath "$runBase.log" -Value "verify: ALL PASS`n$(if ($code -ne '0') { 'verify: FAILED - broke main' })" -Encoding utf8
        $jObj = @{
            id = $jid
            name = $name
            recipe = $recipe
            status = 'running'
            cursor = $cursor
            attempt = 0
            steps = @(
                @{
                    script = 'merge.ps1'
                    args = @{ Files = $files }
                },
                @{ script = 'verify.ps1'; args = @{}; retries = 0 }
            )
            run = @{
                pid = $PID
                startMs = 0
                base = $runBase
                startedAt = [DateTime]::UtcNow.ToString('o')
            }
            history = @()
        }
        $jObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root "jobs\$jid.json") -Encoding utf8
    }

    # 9.2 supervisor tick on improve merge with server changes (chef.updated)
    $passScript = Join-Path $root 'dummy-update-pass.ps1'
    Set-Content -LiteralPath $passScript -Value 'Write-Output "mock update ok"; exit 0' -Encoding utf8
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $passScript

    Setup-MergeJob 'J20' @('pass-app/server.mjs')
    & $k tick -Quiet | Out-Null
    Check 'improve merge job completes on chef update pass' ((Job J20).status -eq 'done')
    $upEv = @(Events | Where-Object { $_.type -eq 'chef.updated' -and $_.job -eq 'J20' })
    Check 'chef.updated event emitted' ($upEv.Count -eq 1)
    Check 'chef.updated event contains files' ($upEv[0].files -contains 'pass-app/server.mjs')
    Check 'chef.updated event contains detail' ($upEv[0].detail -match 'mock update ok')

    # 9.3 supervisor tick on update failure (chef.update.failed + alert)
    $failScript = Join-Path $root 'dummy-update-fail.ps1'
    Set-Content -LiteralPath $failScript -Value 'Write-Error "mock update failed"; exit 1' -Encoding utf8
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $failScript

    Setup-MergeJob 'J21' @('pass-app/server.mjs')
    & $k tick -Quiet | Out-Null
    Check 'improve merge job completes even when chef update fails' ((Job J21).status -eq 'done')
    $failEv = @(Events | Where-Object { $_.type -eq 'chef.update.failed' -and $_.job -eq 'J21' })
    Check 'chef.update.failed event emitted' ($failEv.Count -eq 1)
    Check 'chef.update.failed event contains files' ($failEv[0].files -contains 'pass-app/server.mjs')
    $jobAlerts = @(Get-Content -LiteralPath (Join-Path $root 'alerts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.job -eq 'J21' -and $_.level -eq 'HIGH' })
    Check 'alert written on chef update failure' ($jobAlerts.Count -ge 1 -and $jobAlerts[-1].text -match 'Chef update failed for J21')

    # 9.4 public-only and unrelated file filter check
    Setup-MergeJob 'J22' @('pass-app/public/app.js', 'pass-app/public/sw.js')
    Setup-MergeJob 'J23' @('kitchen/kitchen.ps1')
    & $k tick -Quiet | Out-Null
    Check 'public-only merge completed' ((Job J22).status -eq 'done')
    Check 'unrelated file merge completed' ((Job J23).status -eq 'done')
    $skipEv = @(Events | Where-Object { ($_.job -eq 'J22' -or $_.job -eq 'J23') -and $_.type -match '^chef\.' })
    Check 'public-only and unrelated files do not trigger chef update' ($skipEv.Count -eq 0)

    # 9.5 real update.ps1 auto-DryRun in test kitchen root
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $null
    Setup-MergeJob 'J24' @('pass-app/server.mjs')
    & $k tick -Quiet | Out-Null
    Check 'real update.ps1 auto-dryrun completes' ((Job J24).status -eq 'done')
    $realDryEv = @(Events | Where-Object { $_.type -eq 'chef.updated' -and $_.job -eq 'J24' })
    Check 'real update.ps1 emitted chef.updated via dry-run' ($realDryEv.Count -eq 1 -and $realDryEv[0].detail -match 'Chef update dry-run ok')

    # 9.6 explicit KITCHEN_CHEF_UPDATE_DRYRUN flag and multiple files deduplication
    $env:KITCHEN_CHEF_UPDATE_DRYRUN = '1'
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $passScript
    Setup-MergeJob 'J25' @('pass-app/server.mjs', 'pass-app/update.ps1', 'pass-app/server.mjs')
    & $k tick -Quiet | Out-Null
    Check 'explicit dryrun completes job' ((Job J25).status -eq 'done')
    $dryFlagEv = @(Events | Where-Object { $_.type -eq 'chef.updated' -and $_.job -eq 'J25' })
    Check 'explicit dryrun emits chef.updated' ($dryFlagEv.Count -eq 1)
    Check 'explicit dryrun deduplicates chef files' (@($dryFlagEv[0].files).Count -eq 2)
    $env:KITCHEN_CHEF_UPDATE_DRYRUN = $null

    # 9.7 missing update script emits chef.update.failed and alerts
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = (Join-Path $root 'nonexistent-update.ps1')
    Setup-MergeJob 'J26' @('pass-app/server.mjs')
    & $k tick -Quiet | Out-Null
    Check 'missing update script completes job' ((Job J26).status -eq 'done')
    $missingEv = @(Events | Where-Object { $_.type -eq 'chef.update.failed' -and $_.job -eq 'J26' })
    Check 'chef.update.failed emitted for missing update script' ($missingEv.Count -eq 1 -and $missingEv[0].error -match 'update script not found')
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $null

    # 9.7b no Chef update when only the merge finished (not verified yet), nor when verify failed and undid it
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $passScript
    Setup-MergeJob 'J27' @('pass-app/server.mjs') -code '1'
    Setup-MergeJob 'J28' @('pass-app/server.mjs') -cursor 0
    & $k tick -Quiet | Out-Null
    Check 'no Chef update before verify passes' (-not @(Events | Where-Object { $_.job -in 'J27', 'J28' -and $_.type -match '^chef\.' }).Count -and (Job J28).cursor -eq 1)
    & $k kill -Id J28 | Out-Null
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $null

    # 9.9 the Chef update runs exactly once, however many ticks follow
    $countFile = Join-Path $root 'chef-update-count.txt'
    $countScript = Join-Path $root 'dummy-update-count.ps1'
    Set-Content -LiteralPath $countScript -Value "Add-Content -LiteralPath '$countFile' -Value 'ran'; Write-Output 'mock update ok'; exit 0" -Encoding utf8
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $countScript
    Setup-MergeJob 'J29' @('pass-app/server.mjs')
    & $k tick -Quiet | Out-Null
    & $k tick -Quiet | Out-Null
    Check 'chef update script ran once over two ticks' (@(Get-Content -LiteralPath $countFile -ErrorAction SilentlyContinue).Count -eq 1)
    Check 'one chef.updated event over two ticks' (@(Events | Where-Object { $_.type -eq 'chef.updated' -and $_.job -eq 'J29' }).Count -eq 1)
    Check 'chefUpdate marker is cleared after the update' (-not (Job J29).chefUpdate)

    # 9.10 a failed update is reported once and not retried
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $failScript
    Setup-MergeJob 'J30' @('pass-app/server.mjs')
    & $k tick -Quiet | Out-Null
    & $k tick -Quiet | Out-Null
    Check 'failed chef update emits chef.update.failed once' (@(Events | Where-Object { $_.type -eq 'chef.update.failed' -and $_.job -eq 'J30' }).Count -eq 1)
    $j30Alerts = @(Get-Content -LiteralPath (Join-Path $root 'alerts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.job -eq 'J30' -and $_.level -eq 'HIGH' })
    Check 'failed chef update alerts once' ($j30Alerts.Count -eq 1)
    Check 'failed chef update clears the marker' (-not (Job J30).chefUpdate)
    $env:KITCHEN_CHEF_UPDATE_SCRIPT = $null

    # 9.8 syntax error in server.mjs fails update.ps1 -DryRun
    $badDir = Join-Path $root 'bad-app'
    New-Item -ItemType Directory -Force -Path (Join-Path $badDir 'public') | Out-Null
    Set-Content -LiteralPath (Join-Path $badDir 'server.mjs') -Value 'function broken( {' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $badDir 'public\app.js') -Value '// ok' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $badDir 'public\sw.js') -Value '// ok' -Encoding utf8
    Copy-Item -LiteralPath $updatePs1 -Destination (Join-Path $badDir 'update.ps1')
    $badOut = & $pwshBin -NoProfile -NonInteractive -File (Join-Path $badDir 'update.ps1') -DryRun 2>&1
    Check 'update.ps1 -DryRun detects syntax error' ($LASTEXITCODE -ne 0 -and ($badOut | Out-String) -match 'syntax error in server\.mjs')

    # 10 spend survives a simulated 20 MB log rotation; doctor prunes old rotated logs
    $env:BRAIN_KITCHEN = "$root-rot"
    New-Item -ItemType Directory -Force -Path "$root-rot" | Out-Null
    $nowTs = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $rotEv = Join-Path "$root-rot" 'events.jsonl'
    Set-Content -LiteralPath $rotEv -Value ('{"ts":"' + $nowTs + '","type":"cost","job":"J1","usd":12.5}') -Encoding utf8
    $fs = [IO.File]::OpenWrite($rotEv); $fs.SetLength(21MB); $fs.Close()
    & $k add -Name rotjob -Script $w | Out-Null   # emits, which rotates the oversize log
    Add-Content -LiteralPath $rotEv -Value ('{"ts":"' + $nowTs + '","type":"cost","job":"J1","usd":3.25}') -Encoding utf8
    $rotated = @(Get-ChildItem -LiteralPath "$root-rot" -Filter 'events-*.jsonl' -File)
    Check 'log rotated at 20 MB' ($rotated.Count -ge 1)
    Check 'Spend-Today retains costs across simulated 20 MB log rotation' ((& $k status -DailyBudgetUsd 15 | Out-String) -match 'spent today \$15\.75 of \$15\.00')
    $old = Join-Path "$root-rot" 'events-20260101000000.jsonl'
    Set-Content -LiteralPath $old -Value '{"type":"x"}' -Encoding utf8
    (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-16)
    $dr = (& $k doctor -Json | Out-String) | ConvertFrom-Json
    Check 'doctor removes rotated logs older than 14 days' (-not (Test-Path -LiteralPath $old))
    Check 'doctor retains recent rotated logs' (@(Get-ChildItem -LiteralPath "$root-rot" -Filter 'events-*.jsonl' -File).Count -ge 1)
    Check 'doctor retains active events.jsonl' (Test-Path -LiteralPath $rotEv)
    Check 'doctor reports prunedEventFiles count' ([int]$dr.prunedEventFiles -ge 1)

    # doctor clears test scratch kitchens left in TEMP: only our names, only when 6 hours untouched
    $scr = "$root-scr"; $env:KITCHEN_SCRATCH_DIR = $scr; $g = [guid]::NewGuid().ToString('N')
    $oldT = New-Item -ItemType Directory -Force "$scr\kitchen-test-talk-$g"; $oldS = New-Item -ItemType Directory -Force "$scr\kitchen-test-$g-t"
    $newT = New-Item -ItemType Directory -Force "$scr\kitchen-test-sous-$g"; $other = New-Item -ItemType Directory -Force "$scr\someone-elses-$g"
    foreach ($d in $oldT, $oldS, $other) { $d.LastWriteTime = (Get-Date).AddHours(-7) }
    $dr2 = (& $k doctor -Json | Out-String) | ConvertFrom-Json; $env:KITCHEN_SCRATCH_DIR = $null
    Check 'doctor clears old test scratch kitchens' (-not (Test-Path $oldT.FullName) -and -not (Test-Path $oldS.FullName) -and [int]$dr2.prunedTestDirs -eq 2)
    Check 'doctor keeps fresh test scratch and anything not ours' ((Test-Path $newT.FullName) -and (Test-Path $other.FullName))
    # demo.ps1's kitchen-demo-<date>-<time> scratch is ours too (it used to pile up in TEMP forever)
    $env:KITCHEN_SCRATCH_DIR = $scr; $demo = New-Item -ItemType Directory -Force "$scr\kitchen-demo-20261013-070846"; $demo.LastWriteTime = (Get-Date).AddHours(-7)
    $null = & $k doctor -Json; $env:KITCHEN_SCRATCH_DIR = $null
    Check 'doctor clears old demo scratch kitchens' (-not (Test-Path $demo.FullName))
    # agy transcripts/logs in the kitchen's agy homes: older than 7 days go, fresh ones stay, anything outside those folders is untouched
    $conv = Join-Path "$root-rot" 'agy-home-ro\.gemini\antigravity-cli\conversations'; $alog = Join-Path "$root-rot" 'agy-home-edit\.gemini\antigravity-cli\log'
    New-Item -ItemType Directory -Force -Path $conv, $alog | Out-Null
    Set-Content "$conv\old.pb" 'o'; Set-Content "$alog\old.log" 'o'; Set-Content "$conv\new.pb" 'n'; Set-Content "$root-rot\agy-home-ro\.gemini\settings.json" '{}'
    foreach ($f in "$conv\old.pb", "$alog\old.log", "$root-rot\agy-home-ro\.gemini\settings.json") { (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-8) }
    $dr3 = (& $k doctor -Json | Out-String) | ConvertFrom-Json
    Check 'doctor prunes week-old agy transcripts and logs' (-not (Test-Path "$conv\old.pb") -and -not (Test-Path "$alog\old.log") -and [int]$dr3.prunedAgyFiles -eq 2)
    Check 'doctor keeps fresh agy transcripts and agy settings' ((Test-Path "$conv\new.pb") -and (Test-Path "$root-rot\agy-home-ro\.gemini\settings.json") -and $null -ne $dr3.agyHomeMB)
    # the daily in-place backup holds the hard-to-rebuild state, not only the jobs
    Set-Content "$root-rot\ideas.json" '{"items":[]}'; Set-Content "$root-rot\lead.json" '{"notes":[]}'
    Remove-Item -Recurse -Force (Join-Path "$root-rot" 'backups'); $null = & $k doctor -Json
    $bkd = Get-ChildItem (Join-Path "$root-rot" 'backups\daily') -Directory | Select-Object -First 1
    Check 'doctor backup includes ideas.json and lead.json' ((Test-Path "$($bkd.FullName)\ideas.json") -and (Test-Path "$($bkd.FullName)\lead.json"))

    # pause/resume: a PAUSED kitchen's tick starts nothing new (no new work, lastTick unchanged), resume starts it again.
    # TD-EH-13: while paused, the steps already running are still minded (a time limit kills a slow one) and their exits are recorded.
    $env:BRAIN_KITCHEN = "$root-pause"
    function PJob($id) { Get-Content "$root-pause\jobs\$id.json" -Raw | ConvertFrom-Json }
    & $k add -Name paused-slow -Script $w -ScriptArgs @{ Behavior = 'slow'; Seconds = 1 } -TimeoutSec 4 -HungSec 60 -Retries 0 | Out-Null   # J1
    & $k add -Name paused-ok -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null                                            # J2
    & $k tick -Quiet | Out-Null
    $slowPid = (PJob J1).run.pid; $lt0 = (Get-Content "$root-pause\supervisor.json" -Raw | ConvertFrom-Json).lastTick
    & $k add -Name paused-job -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null                                           # J3
    $po = & $k pause | Out-String
    Check 'pause writes the PAUSED marker' ((Test-Path "$root-pause\PAUSED") -and $po -match 'Yard paused' -and $po -match 'still watched')
    Check 'both steps were running when the Yard paused' ((PJob J1).status -eq 'running' -and (PJob J2).status -eq 'running' -and $slowPid)
    # TD-EH-26: pausing once blinded every watcher (the doctor ran only from the chores, which returned at once while paused). A stand-in
    # watcher (it notes each run), an old run file a full doctor would prune, and a full doctor run two hours ago: the paused Walkround
    # (no chores task) runs the doctor's findings on its hourly clock, and nothing is pruned, reset or archived.
    $pws = "$root-pause\standin-watcher.ps1"; $pwm = "$root-pause\standin-ran.txt"
    Set-Content $pws "param([switch]`$Json); Add-Content -LiteralPath '$pwm' -Value 'ran'; '{`"problems`":[{`"say`":`"stand-in watch finding`"}]}'"
    $pold = "$root-pause\run\J99-s0-a1.log"; Set-Content $pold 'old'; (Get-Item $pold).LastWriteTime = (Get-Date).AddDays(-5)
    function PMeta { Get-Content "$root-pause\supervisor.json" -Raw | ConvertFrom-Json -AsHashtable }
    function PAge([string]$key) { $m = PMeta; $m[$key] = [DateTime]::UtcNow.AddHours(-2).ToString('o'); $m | ConvertTo-Json -Depth 10 | Set-Content "$root-pause\supervisor.json" }
    PAge 'lastDoctor'; $ld0 = (PMeta).lastDoctor
    $env:KITCHEN_WATCH_IN_TEST = '1'; $env:KITCHEN_DOCTOR_WATCHERS = $pws
    Start-Sleep -Seconds 6
    $to = & $k tick | Out-String
    $lt1 = (Get-Content "$root-pause\supervisor.json" -Raw | ConvertFrom-Json).lastTick
    $pdoc = @(Get-Content "$root-pause\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'doctor')
    Check 'TD-EH-26: a paused Walkround still runs the watchers (the doctor, findings only)' ((Test-Path $pwm) -and $pdoc.Count -ge 1 -and $pdoc[-1].findOnly -eq $true -and $pdoc[-1].watch -match 'stand-in watch finding' -and (PMeta).lastDoctorFind)
    Check 'TD-EH-26: the paused doctor prunes nothing and leaves the last full run as it was' ((Test-Path $pold) -and "$((PMeta).lastDoctor)" -eq "$ld0")
    # the chores task while paused: the watchers again on their clock (findings only); within the hour they do not repeat
    Remove-Item $pwm -ErrorAction SilentlyContinue; PAge 'lastDoctorFind'
    $pco = & $k chores | Out-String
    Check 'TD-EH-26: paused chores run the watchers and say only the watchers run' ((Test-Path $pwm) -and $pco -match 'only the watchers run' -and (Test-Path $pold) -and (PMeta).choresTaskAt)
    Remove-Item $pwm -ErrorAction SilentlyContinue; & $k chores -Quiet | Out-Null
    Check 'TD-EH-26: the paused watchers keep the hourly clock (no second run within the hour)' (-not (Test-Path $pwm))
    $pdj = (& $k doctor -Json | Out-String) | ConvertFrom-Json
    Check 'TD-EH-26: a doctor run by hand while paused only finds' ($pdj.findOnly -eq $true -and [int]$pdj.prunedRunFiles -eq 0 -and (Test-Path $pold) -and @($pdj.watch) -contains 'stand-in watch finding')
    Check 'a paused tick starts nothing new' ($to -match 'paused by the Owner' -and (PJob J3).status -eq 'pending' -and -not (PJob J3).run -and "$lt1" -eq "$lt0")
    Check 'TD-EH-13: a paused tick still times out a running step and stops its worker' (@((PJob J1).history | Where-Object outcome -eq 'timeout').Count -eq 1 -and (PJob J1).status -ne 'running' -and -not (Get-Process -Id $slowPid -ErrorAction SilentlyContinue))
    Check 'TD-EH-13: a paused tick records a step that finished' ((PJob J2).status -eq 'done' -and @((PJob J2).history | Where-Object outcome -eq 'done').Count -eq 1)
    $ro = & $k resume | Out-String; & $k tick -Quiet | Out-Null
    Check 'resume removes the marker and ticks run again' ($ro -match 'resumed' -and -not (Test-Path "$root-pause\PAUSED") -and (PJob J3).status -ne 'pending')
    $pfull = (& $k doctor -Json | Out-String) | ConvertFrom-Json
    $env:KITCHEN_WATCH_IN_TEST = $null; $env:KITCHEN_DOCTOR_WATCHERS = $null
    Check 'TD-EH-26: after resume the full doctor cleans up what the pause left' ($pfull.findOnly -eq $false -and -not (Test-Path $pold))
    & $k kill -All | Out-Null

    # TD-8: pause per Site. With a Sites registry, kitchen.ps1 pause -Site GW holds only GW's new starts: GW's running order finishes,
    # TD's orders start, and the watchers are not touched (no global PAUSED). The global pause still wins over a Site's resume.
    $env:BRAIN_KITCHEN = "$root-sitep"; New-Item -ItemType Directory -Force "$root-sitep" | Out-Null
    Set-Content "$root-sitep\kitchen.json" '{"sites":{"GW":{},"TD":{}}}' -Encoding utf8
    function SpJob($id) { Get-Content "$root-sitep\jobs\$id.json" -Raw | ConvertFrom-Json }
    function Set-TestSite([string]$r, [string]$id, [string]$code) { $p = "$r\jobs\$id.json"; $h = Get-Content $p -Raw | ConvertFrom-Json -AsHashtable; if ($h.vars -isnot [hashtable]) { $h.vars = @{} }; $h.vars.site = $code; $h | ConvertTo-Json -Depth 20 | Set-Content $p -Encoding utf8 }
    Add 'gw running' 'ok' @{ Retries = 0 } | Out-Null; Set-TestSite "$root-sitep" J1 GW
    & $k tick -Quiet -BreakerMin 99 | Out-Null
    $spo = & $k pause -Site gw | Out-String
    Add 'gw new' 'ok' @{ Retries = 0 } | Out-Null; Set-TestSite "$root-sitep" J2 GW
    Add 'td new' 'ok' @{ Retries = 0 } | Out-Null; Set-TestSite "$root-sitep" J3 TD
    $spBad = & $k pause -Site XX | Out-String
    & $k watch -Seconds 12 -BreakerMin 99 -Quiet | Out-Null
    Check 'TD-8: pause -Site writes PAUSED-<code> only and says the rest carries on' ((Test-Path "$root-sitep\PAUSED-GW") -and -not (Test-Path "$root-sitep\PAUSED") -and $spo -match 'Site GW stopped' -and $spo -match 'other Sites carry on') { $spo }
    Check 'TD-8: pause -Site refuses a Site not in the registry' ($spBad -match 'ERROR' -and $spBad -match 'not in the Sites registry' -and -not (Test-Path "$root-sitep\PAUSED-XX")) { $spBad }
    $sps = & $k status | Out-String; $spj = & $k status -Json | Out-String | ConvertFrom-Json -AsHashtable
    Check 'TD-8 in status: the stopped Site is listed with how to resume it; -Json siteStops says the same' ($sps -match "SITE GW: stopped by you: none of its new work starts until 'kitchen.ps1 resume -Site GW'" -and $sps -notmatch 'SITE TD: stopped' -and @($spj.siteStops).Count -eq 1 -and $spj.siteStops[0].site -eq 'GW' -and $spj.siteStops[0].paused -and -not $spj.siteStops[0].stopWork) { $sps }
    Check "TD-8: a stopped Site's running order still finishes" ((SpJob J1).status -eq 'done') { Show-Jobs "$root-sitep" }
    Check "TD-8: a stopped Site's new order waits; another Site's starts" ((SpJob J2).status -eq 'pending' -and -not (SpJob J2).run -and (SpJob J3).status -eq 'done') { Show-Jobs "$root-sitep" }
    Set-Content "$root-sitep\PAUSED" 'test'
    $sro = & $k resume -Site GW | Out-String; & $k tick -Quiet -BreakerMin 99 | Out-Null
    Check 'TD-8: the global pause still wins after a Site resumes' (-not (Test-Path "$root-sitep\PAUSED-GW") -and $sro -match 'Site GW resumed' -and $sro -match 'still paused' -and (SpJob J2).status -eq 'pending') { $sro; Show-Jobs "$root-sitep" }
    & $k resume | Out-Null; & $k watch -Seconds 12 -BreakerMin 99 -Quiet | Out-Null
    $spev = @(Get-Content "$root-sitep\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'TD-8: after both resumes the Site starts again; both taps are logged' ((SpJob J2).status -eq 'done' -and @($spev | Where-Object { $_.type -eq 'site.paused' -and $_.site -eq 'GW' }).Count -eq 1 -and @($spev | Where-Object { $_.type -eq 'site.resumed' -and $_.site -eq 'GW' }).Count -eq 1) { Show-Jobs "$root-sitep" }

    # TD-8: the Stop-work order per Site. GW's failures open GW's order only (same episode rules, TD-EH-07); TD's work still starts.
    $env:BRAIN_KITCHEN = "$root-siteb"; New-Item -ItemType Directory -Force "$root-siteb" | Out-Null
    Set-Content "$root-siteb\kitchen.json" '{"sites":{"GW":{},"TD":{}}}' -Encoding utf8
    for ($i = 1; $i -le 6; $i++) { Add "gw f$i" 'fail' @{ Retries = 0 } | Out-Null; Set-TestSite "$root-siteb" "J$i" GW }
    Add 'gw after' 'ok' | Out-Null; Set-TestSite "$root-siteb" J7 GW
    Add 'td after' 'ok' | Out-Null; Set-TestSite "$root-siteb" J8 TD
    & $k watch -Seconds 20 -MaxConcurrent 2 -BreakerMin 4 -BreakerWindow 4 -BreakerCoolSec 300 -Quiet | Out-Null
    $sbev = @(Get-Content "$root-siteb\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
    $sbm = Get-Content "$root-siteb\supervisor.json" -Raw | ConvertFrom-Json -AsHashtable
    $sbal = @(Get-Content "$root-siteb\alerts.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.text -match 'Stop-work order' })
    function SbJob($id) { Get-Content "$root-siteb\jobs\$id.json" -Raw | ConvertFrom-Json }
    Check "TD-8: one Site's failures open that Site's Stop-work order only" (@($sbev | Where-Object type -eq 'breaker.open').Count -eq 1 -and @($sbev | Where-Object type -eq 'breaker.open')[0].site -eq 'GW' -and $sbm.siteBreakers.GW.tripped -and -not $sbm.siteBreakers.TD -and -not $sbm.breakerTripped) { $sbev | Where-Object type -match 'breaker' | ConvertTo-Json -Compress }
    Check "TD-8: the stopped Site's next order waits; the other Site's order starts" ((SbJob J7).status -eq 'pending' -and (SbJob J8).status -eq 'done') { Show-Jobs "$root-siteb" }
    Check 'TD-8: the alert names the Site and says the other Sites carry on' ($sbal.Count -eq 1 -and $sbal[0].level -eq 'HIGH' -and $sbal[0].text -match 'Stop-work order on GW' -and $sbal[0].text -match 'No new work of GW starts for 5 min' -and $sbal[0].text -match 'Other Sites carry on') { $sbal | ConvertTo-Json -Compress }
    $sbs = & $k status | Out-String
    Check 'TD-8 in status: the Site under its own Stop-work order is listed, the other Site is not' ($sbs -match 'SITE GW: Stop-work order on: no new work for' -and $sbs -notmatch 'SITE TD: (Stop-work|stopped)') { $sbs }
    & $k kill -All | Out-Null

    # TD-EH-06: a hold's reason is whole. kitchen-step.ps1 keeps the held step's last line in <run>.hold; a step may write its own;
    # an empty one falls back to the log line, cut on a word boundary. The Sign-off text fits 300 characters and is never cut mid-word.
    $env:BRAIN_KITCHEN = "$root-hold"; New-Item -ItemType Directory -Force -Path "$root-hold" | Out-Null
    function HJob($id) { Get-Content "$root-hold\jobs\$id.json" -Raw | ConvertFrom-Json }
    $whole = ('word ' * 40) + 'Say yes to let a cloud cook take this step.'                    # 243 characters: the old 200 cut ended "a cl"
    $toks = (1..80 | ForEach-Object { 'w{0:000}' -f $_ }) -join ' '                               # 399 characters of 4-letter words
    Set-Content "$root-hold\h1.ps1" "Write-Output 'checking'; Write-Output 'HOLD: $whole'; exit 10"
    Set-Content "$root-hold\h2.ps1" "Set-Content -LiteralPath `"`$env:KITCHEN_RUN.hold`" -Value 'HOLD: $toks'; Write-Output 'HOLD: see the hold file'; exit 10"
    Set-Content "$root-hold\h3.ps1" "Set-Content -LiteralPath `"`$env:KITCHEN_RUN.hold`" -Value ''; Write-Output 'HOLD: $toks'; exit 10"
    foreach ($n in 1..3) { & $k add -Name "hold-$n" -Script "$root-hold\h$n.ps1" | Out-Null }
    & $k watch -Seconds 40 -Quiet | Out-Null
    $soText = @(Get-Content "$root-hold\approvals.md" | Where-Object { $_ -match 'A\d+ \| \w+ \| ' })
    function SoFor($id) { [string]($soText | Where-Object { $_ -match "Step 0 of $id hold-" } | Select-Object -First 1) }
    Check 'TD-EH-06: the hold reason is whole in the history and the event, not cut at 200' ((HJob J1).status -eq 'needs-human' -and (HJob J1).history[-1].detail -eq "HOLD: $whole" -and (Test-Path "$root-hold\run\J1-s0-a0.hold") -and @(Get-Content "$root-hold\events.jsonl" | Where-Object { $_ -match '"type":"step\.hold"' -and $_ -match 'take this step\.' }).Count -eq 1)
    Check 'TD-EH-06: a reason that fits is the whole Sign-off text' ((SoFor J1).Contains("HOLD: $whole"))
    Check "TD-EH-06: the step's own .hold is read first" ((HJob J2).history[-1].detail -eq "HOLD: $toks")
    Check 'TD-EH-06: a Sign-off too long for 300 characters is cut on a word boundary' ((SoFor J2) -match 'HOLD: w001 (w\d{3} )*w\d{3}\.\.\. \|' -and (SoFor J2) -notmatch 'w080')
    Check 'TD-EH-06: an empty .hold falls back to the log line, cut at a word boundary' ((HJob J3).history[-1].detail -match '^HOLD: (w\d{3} )*w\d{3}\.\.\.$' -and (HJob J3).history[-1].detail.Length -le 200)
    & $k kill -All | Out-Null

    # TD-EH-14: a watcher that gives no JSON report is a doctor finding ("gave no report (exit N)"), never a silent all good
    $env:BRAIN_KITCHEN = "$root-wd"; New-Item -ItemType Directory -Force -Path "$root-wd" | Out-Null
    Set-Content "$root-wd\dead-watcher.ps1" 'param([switch]$Json); exit 3'
    Set-Content "$root-wd\good-watcher.ps1" "param([switch]`$Json); '{`"problems`":[]}'"
    $env:KITCHEN_WATCH_IN_TEST = '1'; $env:KITCHEN_DOCTOR_WATCHERS = "$root-wd\dead-watcher.ps1;$root-wd\good-watcher.ps1"
    try { $wdj = (& $k doctor -Json | Out-String) | ConvertFrom-Json; $wdt = & $k doctor | Out-String }
    finally { $env:KITCHEN_WATCH_IN_TEST = $null; $env:KITCHEN_DOCTOR_WATCHERS = $null }
    Check 'TD-EH-14: a watcher with no report is a finding, with its exit code' (@($wdj.watch) -contains 'watcher dead-watcher.ps1 gave no report (exit 3)' -and @($wdj.watch).Count -eq 1)
    Check 'TD-EH-14: the doctor text shows the watch finding' ($wdt -match 'watch: watcher dead-watcher\.ps1 gave no report \(exit 3\)')

    # scripts/backup-state.ps1 (temp folders only): the listed state lands in <dest>\<today>, 14 days kept, a missing drive fails closed
    $bs = Join-Path $PSScriptRoot '..\scripts\backup-state.ps1'; $bkK = "$root-bk\kitchen"; $bkC = "$root-bk\career"; $bkD = "$root-bk\dest"
    New-Item -ItemType Directory -Force -Path "$bkK\jobs", $bkC | Out-Null
    foreach ($f in 'ideas.json', 'kitchen.json', 'lessons.jsonl', 'exemplars.jsonl', 'lead.json', 'autopilot.json') { Set-Content "$bkK\$f" '{}' }
    Set-Content "$bkK\jobs\J1.json" '{}'; Set-Content "$bkK\events.jsonl" 'not copied'; Set-Content "$bkC\tracker.json" '{}'
    $old = New-Item -ItemType Directory -Force "$bkD\$((Get-Date).AddDays(-20).ToString('yyyy-MM-dd'))"; $keep = New-Item -ItemType Directory -Force "$bkD\$((Get-Date).AddDays(-13).ToString('yyyy-MM-dd'))"; $notOurs = New-Item -ItemType Directory -Force "$bkD\keep-me"
    $br = & $bs -KitchenRoot $bkK -CareerDir $bkC -Dest $bkD -Json | ConvertFrom-Json
    $today = Join-Path $bkD (Get-Date -Format 'yyyy-MM-dd')
    Check 'backup-state copies the state that matters' ($br.ok -and $br.copied -eq 8 -and (Test-Path "$today\ideas.json") -and (Test-Path "$today\jobs\J1.json") -and (Test-Path "$today\career\tracker.json") -and (Test-Path "$today\exemplars.jsonl"))
    Check 'backup-state skips what is not on the list' (-not (Test-Path "$today\events.jsonl"))
    Check 'backup-state keeps 14 days, only its own dated folders' (-not (Test-Path $old.FullName) -and (Test-Path $keep.FullName) -and (Test-Path $notOurs.FullName) -and $br.pruned -eq 1)
    $nd = (67..90 | ForEach-Object { [string][char]$_ + ':' } | Where-Object { -not (Test-Path "$_\") } | Select-Object -First 1)
    if ($nd) { $bf = & $bs -KitchenRoot $bkK -CareerDir $bkC -Dest "$nd\backups\kitchen" -Json | ConvertFrom-Json; Check 'backup-state fails closed on a missing drive' (-not $bf.ok -and $bf.error -match 'not there' -and -not (Test-Path "$nd\")) }

    # a busy events log (another writer holds it) never aborts a tick between starting a worker and saving its pid
    $env:BRAIN_KITCHEN = "$root-busy"
    & $k add -Name busy-log -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 3 } | Out-Null
    $fs = [IO.File]::Open("$root-busy\events.jsonl", 'OpenOrCreate', 'ReadWrite', 'None')
    try { $null = & (Get-Process -Id $PID).Path -NoProfile -File $k tick -Quiet 2>&1 } finally { $fs.Dispose() }
    $bj = Get-Content "$root-busy\jobs\J1.json" -Raw | ConvertFrom-Json
    Check 'busy events log: the worker started and its pid is saved' ($bj.status -eq 'running' -and [int]$bj.run.pid -gt 0)
    Check 'busy events log: the event is kept in events-pending (or its .fold claim: Site cleanup took it while the log was still busy, TD-EH-18)' ((Get-Content "$root-busy\events-pending-*" -Raw) -match 'step\.started')
    # an .exit file that exists but is still empty is looked at again next tick, not read as a failure
    $eb = Join-Path "$root-busy" 'run\J2-s0-a0'
    Set-Content -LiteralPath "$eb.exit" -Value '' -NoNewline
    @{ id = 'J2'; name = 'empty-exit'; status = 'running'; cursor = 0; attempt = 0; history = @(); steps = @(@{ script = $w; args = @{}; retries = 0; timeoutSec = 60; maxMB = 400 })
        run = @{ pid = $PID; startMs = 0; base = $eb; startedAt = [DateTime]::UtcNow.ToString('o') } } | ConvertTo-Json -Depth 6 | Set-Content "$root-busy\jobs\J2.json" -Encoding utf8
    & $k tick -Quiet | Out-Null
    Check 'empty .exit: not read as a failure' ((Get-Content "$root-busy\jobs\J2.json" -Raw | ConvertFrom-Json).status -eq 'running')
    Check 'TD-EH-18: once the log is free, the next Site cleanup puts the kept line in events.jsonl and leaves no pending file' (((Get-Content "$root-busy\events.jsonl" -Raw) -match '"type":"step.started","job":"J1"') -and -not @(Get-ChildItem "$root-busy" -Filter 'events-pending-*').Count)
    Set-Content -LiteralPath "$eb.exit" -Value '0'
    & $k tick -Quiet | Out-Null
    Check 'empty .exit: once written, the step is done' ((Get-Content "$root-busy\jobs\J2.json" -Raw | ConvertFrom-Json).status -eq 'done')
    & $k kill -All | Out-Null

    # the PC slept 3 hours while a step was cooking: on wake the sleep does not count against its timeout or heartbeat
    $env:BRAIN_KITCHEN = "$root-sleep"
    & $k add -Name sleeper -Script $w -ScriptArgs @{ Behavior = 'hang' } -TimeoutSec 600 -HungSec 300 -Retries 0 | Out-Null
    & $k tick -Quiet | Out-Null
    $sjp = "$root-sleep\jobs\J1.json"; $sj = Get-Content $sjp -Raw | ConvertFrom-Json -AsHashtable
    $ago = [DateTime]::UtcNow.AddHours(-3)
    $sj.run.startedAt = $ago.ToString('o'); $sj | ConvertTo-Json -Depth 12 | Set-Content $sjp -Encoding utf8
    Start-Sleep 2; if (Test-Path "$($sj.run.base).hb") { (Get-Item "$($sj.run.base).hb").LastWriteTimeUtc = $ago }
    # the sleep is measured from this tick's process start (KITCHEN_TICK_FROM stands in for it) to the previous tick's recorded end
    $from = [DateTime]::UtcNow; $env:KITCHEN_TICK_FROM = $from.ToString('o')
    $sm = Get-Content "$root-sleep\supervisor.json" -Raw | ConvertFrom-Json -AsHashtable; $sm.lastTick = $ago.ToString('o'); $sm.lastTickEnd = $from.AddSeconds(-(3 * 3600 + 60)).ToString('o'); $sm | ConvertTo-Json | Set-Content "$root-sleep\supervisor.json" -Encoding utf8
    & $k tick -Quiet | Out-Null
    $env:KITCHEN_TICK_FROM = $null
    $sj2 = Get-Content $sjp -Raw | ConvertFrom-Json
    Check 'after a 3 h sleep: the cooking step is not timed out or called hung' ($sj2.status -eq 'running' -and -not @($sj2.history).Count)
    Check 'after a 3 h sleep: the resume is logged' ((Get-Content "$root-sleep\events.jsonl" -Raw) -match 'supervisor\.resumed')
    Check "Sleep3h_ShiftsBy3h: the step's clock moved by exactly the 3 h away (resumedSec $($sj2.run.resumedSec))" ([int]$sj2.run.resumedSec -eq 3 * 3600 -and [math]::Abs(((ToUtcT $sj2.run.startedAt) - $ago).TotalSeconds - 3 * 3600) -lt 2)
    & $k kill -All | Out-Null

    # 10-22: a tick that was only slow (a 200 s freeze view before its locked pass) read as a sleep and moved every running step's clock
    $env:BRAIN_KITCHEN = "$root-slow"
    & $k add -Name busy -Script $w -ScriptArgs @{ Behavior = 'slow' } -TimeoutSec 600 -HungSec 300 -Retries 0 | Out-Null
    & $k tick -Quiet | Out-Null
    $slp = "$root-slow\jobs\J1.json"; $started = (Get-Content $slp -Raw | ConvertFrom-Json).run.startedAt
    $from = [DateTime]::UtcNow.AddSeconds(-200); $env:KITCHEN_TICK_FROM = $from.ToString('o')
    $sm = Get-Content "$root-slow\supervisor.json" -Raw | ConvertFrom-Json -AsHashtable
    $sm.lastTick = $from.AddSeconds(-250).ToString('o'); $sm.lastTickEnd = $from.AddSeconds(-30).ToString('o'); $sm | ConvertTo-Json | Set-Content "$root-slow\supervisor.json" -Encoding utf8
    & $k tick -Quiet | Out-Null
    $env:KITCHEN_TICK_FROM = $null
    $sl = Get-Content $slp -Raw | ConvertFrom-Json; $sev = @(Get-Content "$root-slow\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'SlowTick200s_NoSleep_ShiftsNothing: no resume, the step clock untouched' (-not @($sev | Where-Object type -eq 'supervisor.resumed').Count -and $sl.run.startedAt -eq $started -and -not $sl.run.resumedSec -and $sl.status -eq 'running')
    $ts = @($sev | Where-Object type -eq 'tick.slow')   # (the last one: in-process ticks before it count from this test's own start)
    Check "a slow tick logs tick.slow with its seconds and slowest phase ($($ts | ConvertTo-Json -Compress))" ($ts.Count -ge 1 -and [int]$ts[-1].sec -ge 200 -and $ts[-1].phase -eq 'start' -and [int]$ts[-1].phaseSec -ge 199)
    $me = Get-Content "$root-slow\supervisor.json" -Raw | ConvertFrom-Json
    Check 'the tick records its end for the next one' (((ToUtcT $me.lastTickEnd) - [DateTime]::UtcNow).TotalSeconds -gt -30)
    & $k kill -All | Out-Null

    # hung checks are on by default (900 s; KITCHEN_HUNG_DEFAULT_SEC = 3 here): a silent step is killed, a step that heartbeats, one that
    # announced a bounded quiet wait, and one with hungSec -1 (off) are not (10-22: J207 held a slot 2.5 h with hung checks off)
    $env:BRAIN_KITCHEN = "$root-hung"; $env:KITCHEN_HUNG_DEFAULT_SEC = '3'
    New-Item -ItemType Directory -Force "$root-hung" | Out-Null; $qw = Join-Path "$root-hung" 'quiet-worker.ps1'
    Set-Content $qw 'Set-Content -LiteralPath $env:KITCHEN_HEARTBEAT -Value "$(Get-Date -Format o) quiet=30"; Start-Sleep 60' -Encoding utf8
    & $k add -Name silent -Script $w -ScriptArgs @{ Behavior = 'hang' } -TimeoutSec 60 -Retries 0 | Out-Null          # J1: no hungSec set
    & $k add -Name beating -Script $w -ScriptArgs @{ Behavior = 'slow' } -TimeoutSec 60 -Retries 0 | Out-Null         # J2: beats every 1 s
    & $k add -Name quiet -Script $qw -TimeoutSec 60 -Retries 0 | Out-Null                                              # J3: quiet=30
    & $k add -Name off -Script $w -ScriptArgs @{ Behavior = 'hang' } -TimeoutSec 60 -HungSec -1 -Retries 0 | Out-Null # J4: off
    & $k tick -Quiet | Out-Null
    $hs = [Diagnostics.Stopwatch]::StartNew(); $killedAt = 0
    while ($hs.Elapsed.TotalSeconds -lt 10) {
        & $k tick -Quiet | Out-Null
        if (-not $killedAt -and (Get-Content "$root-hung\jobs\J1.json" -Raw | ConvertFrom-Json).status -ne 'running') { $killedAt = $hs.Elapsed.TotalSeconds }
        Start-Sleep -Milliseconds 300
    }
    $h1 = Get-Content "$root-hung\jobs\J1.json" -Raw | ConvertFrom-Json
    Check "SilentStep_KilledAtHungSec: a step with no hungSec of its own is killed as hung at the default ($([int]$killedAt) s; $($h1.history[-1].detail))" (@($h1.history | Where-Object outcome -eq 'hung').Count -eq 1 -and $h1.history[-1].detail -match 'limit 3s' -and $killedAt -gt 0)
    $alive = @('J2', 'J3', 'J4' | ForEach-Object { $hj = Get-Content "$root-hung\jobs\$_.json" -Raw | ConvertFrom-Json; if ($hj.status -eq 'running' -and -not @($hj.history).Count) { $_ } })
    Check "HeartbeatEvery30s_For20min_NotKilled: beating for 3x the limit (J2), a quiet=30 wait (J3) and hungSec -1 (J4) stay running ($($alive -join ','))" ($alive.Count -eq 3)
    $env:KITCHEN_HUNG_DEFAULT_SEC = $null
    & $k kill -All | Out-Null

    # an approval request that fails (here: a text over 300 chars) is asked again contents-free; an older yes never covers the new question
    $env:BRAIN_KITCHEN = "$root-appr"
    & $k add -Name ('long-' + ('x' * 290)) -Script $w -ScriptArgs @{ Behavior = 'crash' } -Replay unsafe -Approve -Retries 0 | Out-Null
    & $k tick -Quiet | Out-Null; & $k tick -Quiet | Out-Null
    $aj = Get-Content "$root-appr\jobs\J1.json" -Raw | ConvertFrom-Json
    Check 'failed approval request: asked again with a short text' ($aj.status -eq 'waiting-approval' -and $aj.approval.id -match '^A\d+$' -and -not $aj.approval.failed)
    & $k approve -Id J1 | Out-Null
    & $k tick -Quiet | Out-Null; Start-Sleep 4
    for ($i = 0; $i -lt 3; $i++) { & $k tick -Quiet | Out-Null; Start-Sleep 1 }
    $aj = Get-Content "$root-appr\jobs\J1.json" -Raw | ConvertFrom-Json
    Check 'failed request after an unsafe crash: the old yes does not re-run the step' ($aj.status -eq 'needs-human' -and @($aj.history | Where-Object outcome -eq 'crash').Count -eq 1 -and $aj.approval.id -match '^A\d+$' -and -not $aj.approval.granted)
    Check 'failed approval request: Jordan told once' (@(Get-Content "$root-appr\alerts.jsonl" | Where-Object { $_ -match 'approval request failed' }).Count -eq 2)
    & $k kill -All | Out-Null

    # a verify cut short after a merge (crash, reboot, timeout, kill) is never a quiet set-aside: main holds an unverified merge
    $env:BRAIN_KITCHEN = "$root-ver"
    New-Item -ItemType Directory -Force -Path "$root-ver\jobs", "$root-ver\run" | Out-Null
    function VerifyJob([string]$jid, [string]$exit, [string]$log, [string]$status = 'running') {
        $vb = Join-Path "$root-ver" "run\$jid-s1-a0"
        if ($exit) { Set-Content "$vb.exit" $exit }; Set-Content "$vb.log" $log
        @{ id = $jid; name = "improve: $jid"; recipe = 'improve'; status = $status; cursor = 1; attempt = 0; history = @()
            steps = @(@{ script = 'merge.ps1'; args = @{} }, @{ script = 'verify.ps1'; args = @{}; retries = 0; timeoutSec = 2400; maxMB = 4000 })
            run = $(if ($status -eq 'running') { @{ pid = $PID; startMs = 0; base = $vb; startedAt = [DateTime]::UtcNow.ToString('o') } } else { $null }) } | ConvertTo-Json -Depth 6 | Set-Content "$root-ver\jobs\$jid.json" -Encoding utf8
    }
    VerifyJob 'J1' '' 'verify: running the suites'                           # the worker died (a reboot): no exit code
    VerifyJob 'J2' '1' "tests: FAILED: Test-X`nverify: FAILED - broke main (Test-X)"   # verify's own verdict: it undid the merge
    VerifyJob 'J3' '1' 'kitchen-step: verify threw before its verdict'
    & $k tick -Quiet | Out-Null
    $vev = @(Get-Content "$root-ver\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
    $v1 = Get-Content "$root-ver\jobs\J1.json" -Raw | ConvertFrom-Json
    Check 'verify crash after merge: needs Jordan, says merged but NOT verified' ($v1.status -eq 'needs-human' -and $v1.approval.text -match 'merged on main but was NOT verified' -and @($vev | Where-Object { $_.type -eq 'merge.unverified' -and $_.job -eq 'J1' }).Count -eq 1)
    Check 'verify with its own verdict: set aside as before' ((Get-Content "$root-ver\jobs\J2.json" -Raw | ConvertFrom-Json).status -eq 'quarantined' -and -not @($vev | Where-Object { $_.type -eq 'merge.unverified' -and $_.job -eq 'J2' }).Count)
    Check 'verify exit 1 without a verdict: unverified, needs Jordan' ((Get-Content "$root-ver\jobs\J3.json" -Raw | ConvertFrom-Json).status -eq 'needs-human')
    VerifyJob 'J4' '' '' 'pending'
    & $k kill -Id J4 | Out-Null
    Check 'killing verify after a merge: Jordan told it is NOT verified' ((Get-Content "$root-ver\alerts.jsonl" -Raw) -match 'J4 was stopped while being verified' -and (Get-Content "$root-ver\events.jsonl" -Raw) -match '"type":"merge.unverified","job":"J4"')

    # standing orders: the stamp moves only after a successful cook; a failed cook is retried (15 min apart), never skipped for a whole
    # period; no second copy is cooked while the last one is still alive
    $env:BRAIN_KITCHEN = "$root-so"; $soRec = "$root-so\recipes"
    New-Item -ItemType Directory -Force -Path $soRec | Out-Null
    Set-Content "$soRec\demo.json" '{ "description": "demo", "vars": {}, "steps": [ { "station": "demo", "args": { "Behavior": "slow" }, "timeoutSec": 120 } ] }'
    Set-Content "$root-so\kitchen.json" '{"standing":[{"name":"broken order","recipe":"nosuchrecipe","everyHours":24},{"name":"demo order","recipe":"demo","everyHours":24}]}'
    Set-Content "$root-so\LIVE" 'test'
    $soOld = [DateTime]::UtcNow.AddDays(-2).ToString('o')
    @{ standing = @{ 'broken order' = $soOld; 'demo order' = $soOld } } | ConvertTo-Json | Set-Content "$root-so\supervisor.json"
    function SoAge($v) { [DateTime]::UtcNow - $(if ($v -is [DateTime]) { $v.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }) }
    $soEnv = @{ r = $env:KITCHEN_RECIPES; d = $env:KITCHEN_NO_DIAGNOSE; a = $env:KITCHEN_NO_AUTOPILOT }
    try {
        $env:KITCHEN_RECIPES = $soRec; $env:KITCHEN_NO_DIAGNOSE = '1'; $env:KITCHEN_NO_AUTOPILOT = '1'
        & $k tick -Quiet | Out-Null; & $k tick -Quiet | Out-Null
        $som = Get-Content "$root-so\supervisor.json" -Raw | ConvertFrom-Json -AsHashtable
        $soEv = @(Get-Content "$root-so\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
        Check 'standing: a failed cook keeps the old stamp (tried again, not skipped for a period)' ((SoAge $som.standing['broken order']).TotalHours -gt 24 -and @($soEv | Where-Object { $_.type -eq 'standing.failed' -and $_.name -eq 'broken order' }).Count -eq 1)
        Check 'standing: a successful cook moves the stamp' ((SoAge $som.standing['demo order']).TotalMinutes -lt 5 -and @($soEv | Where-Object { $_.type -eq 'standing.cooked' -and $_.name -eq 'demo order' }).Count -eq 1)
        $som.standing['demo order'] = $soOld; $som | ConvertTo-Json -Depth 5 | Set-Content "$root-so\supervisor.json"
        & $k tick -Quiet | Out-Null
        Check 'standing: no second copy while the last one is still alive' (@(Get-ChildItem "$root-so\jobs" -Filter 'J*.json').Count -eq 1)
    } finally { $env:KITCHEN_RECIPES = $soEnv.r; $env:KITCHEN_NO_DIAGNOSE = $soEnv.d; $env:KITCHEN_NO_AUTOPILOT = $soEnv.a; Remove-Item "$root-so\LIVE" -ErrorAction SilentlyContinue }
    & $k kill -All | Out-Null

    # atHour standing orders (the 1 am overnight hunt): once a day at or after that local hour; never twice the same day; not before the hour
    $env:BRAIN_KITCHEN = "$root-ah"; $ahRec = "$root-ah\recipes"; New-Item -ItemType Directory -Force -Path $ahRec | Out-Null
    foreach ($rn in 'hnow', 'hlater') { Set-Content "$ahRec\$rn.json" '{ "description": "demo", "vars": {}, "steps": [ { "station": "demo", "args": { "Behavior": "ok", "Seconds": 1 }, "timeoutSec": 60 } ] }' }
    $hr = (Get-Date).Hour
    @{ standing = @(@{ name = 'hour now'; recipe = 'hnow'; atHour = $hr }, @{ name = 'hour later'; recipe = 'hlater'; atHour = $hr + 1 }) } | ConvertTo-Json -Depth 4 | Set-Content "$root-ah\kitchen.json"
    Set-Content "$root-ah\LIVE" 'test'
    $ahYday = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o')
    @{ standing = @{ 'hour now' = $ahYday; 'hour later' = $ahYday } } | ConvertTo-Json | Set-Content "$root-ah\supervisor.json"
    $ahEnv = @{ r = $env:KITCHEN_RECIPES; d = $env:KITCHEN_NO_DIAGNOSE; a = $env:KITCHEN_NO_AUTOPILOT }
    try {
        $env:KITCHEN_RECIPES = $ahRec; $env:KITCHEN_NO_DIAGNOSE = '1'; $env:KITCHEN_NO_AUTOPILOT = '1'
        & $k tick -Quiet | Out-Null
        $ahCooked = { @(Get-Content "$root-ah\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'standing.cooked' }) }
        Check 'atHour: due at its hour after yesterday -> cooked once' (@(& $ahCooked | Where-Object name -eq 'hour now').Count -eq 1)
        Check 'atHour: an hour still ahead -> not cooked' (@(& $ahCooked | Where-Object name -eq 'hour later').Count -eq 0)
        & $k kill -All | Out-Null   # the copy is no longer alive, so only the once-a-day rule can stop a second one
        & $k tick -Quiet | Out-Null
        Check 'atHour: not cooked twice the same day' (@(& $ahCooked | Where-Object name -eq 'hour now').Count -eq 1 -and @(Get-ChildItem "$root-ah\jobs" -Filter 'J*.json').Count -eq 1)
    } finally { $env:KITCHEN_RECIPES = $ahEnv.r; $env:KITCHEN_NO_DIAGNOSE = $ahEnv.d; $env:KITCHEN_NO_AUTOPILOT = $ahEnv.a; Remove-Item "$root-ah\LIVE" -ErrorAction SilentlyContinue }
    & $k kill -All | Out-Null

    # watcher standing orders (TD-EH-03b, the night inspection): started while the Yard is PAUSED and not LIVE (a watcher only reads and
    # reports), given the kitchen root; once a day at its hour; no second copy while the last run is alive; an "off" order only when
    # standingOn names it; a recipe order still cooks nothing while paused
    $env:BRAIN_KITCHEN = "$root-nw"; $nwDir = "$root-nw\watchers"; $nwRuns = "$root-nw\watch-runs.txt"
    New-Item -ItemType Directory -Force -Path $nwDir, "$root-nw\recipes" | Out-Null
    Set-Content "$nwDir\fakewatch.ps1" "param([string]`$KitchenRoot); Add-Content -LiteralPath (Join-Path `$KitchenRoot 'watch-runs.txt') `"root=`$KitchenRoot pid=`$PID`"; Start-Sleep -Seconds 40"
    Set-Content "$root-nw\recipes\pr.json" '{ "description": "demo", "vars": {}, "steps": [ { "station": "demo", "args": { "Behavior": "ok", "Seconds": 1 }, "timeoutSec": 60 } ] }'
    $hr = (Get-Date).Hour
    @{ standingOn = @('night watch'); standing = @(@{ name = 'night watch'; watcher = 'fakewatch'; atHour = $hr; off = $true }, @{ name = 'idle watch'; watcher = 'fakewatch'; atHour = $hr; off = $true },
            @{ name = 'paused recipe'; recipe = 'pr'; atHour = $hr }) } | ConvertTo-Json -Depth 4 | Set-Content "$root-nw\kitchen.json"
    $nwYday = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o')
    @{ standing = @{ 'night watch' = $nwYday; 'idle watch' = $nwYday; 'paused recipe' = $nwYday } } | ConvertTo-Json | Set-Content "$root-nw\supervisor.json"
    Set-Content "$root-nw\PAUSED" 'test'
    $nwEnv = @{ w = $env:KITCHEN_WATCHERS; r = $env:KITCHEN_RECIPES }
    $nwStarted = { @(Get-Content "$root-nw\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'standing.started' }) }
    try {
        $env:KITCHEN_WATCHERS = $nwDir; $env:KITCHEN_RECIPES = "$root-nw\recipes"
        & $k tick -Quiet | Out-Null
        $t0 = Get-Date; while (-not (Test-Path $nwRuns) -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200 }
        $nwEv = @(Get-Content "$root-nw\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
        Check 'watcher order: started while paused and not live, given the kitchen root' ((Test-Path $nwRuns) -and (Get-Content $nwRuns -Raw) -match [regex]::Escape("root=$root-nw ") -and @(& $nwStarted | Where-Object name -eq 'night watch').Count -eq 1)
        Check 'watcher order: an off order that standingOn does not name never starts' (-not @($nwEv | Where-Object { $_.name -eq 'idle watch' }).Count)
        Check 'watcher order: a recipe order cooks nothing while paused' (-not @($nwEv | Where-Object { $_.name -eq 'paused recipe' }).Count -and -not @(Get-ChildItem "$root-nw\jobs" -Filter 'J*.json' -ErrorAction SilentlyContinue).Count)
        & $k tick -Quiet | Out-Null
        Check 'watcher order: not started twice the same day' (@(& $nwStarted).Count -eq 1)
        $som = Get-Content "$root-nw\supervisor.json" -Raw | ConvertFrom-Json -AsHashtable; $som.standing['night watch'] = $nwYday; $som | ConvertTo-Json -Depth 5 | Set-Content "$root-nw\supervisor.json"
        & $k tick -Quiet | Out-Null; Start-Sleep -Milliseconds 1500
        Check 'watcher order: no second copy while the last run is still alive' (@(& $nwStarted).Count -eq 1 -and @(Get-Content $nwRuns).Count -eq 1)
    } finally {
        $env:KITCHEN_WATCHERS = $nwEnv.w; $env:KITCHEN_RECIPES = $nwEnv.r; Remove-Item "$root-nw\PAUSED" -ErrorAction SilentlyContinue
        foreach ($l in @(Get-Content $nwRuns -ErrorAction SilentlyContinue)) { if ($l -match 'pid=(\d+)') { Stop-Process -Id ([int]$Matches[1]) -Force -ErrorAction SilentlyContinue } }
    }

    # a merge that finds main moved and conflicting (exit 11 "needs freshen") goes back to freshen, and Jordan is asked again
    $env:BRAIN_KITCHEN = "$root-rf"; New-Item -ItemType Directory -Force -Path "$root-rf\st" | Out-Null
    Set-Content "$root-rf\st\freshen.ps1" "Add-Content '$root-rf\freshens.txt' 'f'; 'freshen: up to date'"
    Set-Content "$root-rf\st\merge.ps1" "if (-not (Test-Path '$root-rf\merged-once.txt')) { Set-Content '$root-rf\merged-once.txt' 1; 'merge: needs freshen: conflict merging kitchen/J1 into main'; exit 11 }; 'merge: MERGED'"
    @{ name = 'refreshen'; steps = @(@{ script = "$root-rf\st\freshen.ps1"; retries = 0; timeoutSec = 30 }, @{ script = "$root-rf\st\merge.ps1"; retries = 0; timeoutSec = 30 }) } | ConvertTo-Json -Depth 5 | Set-Content "$root-rf\spec.json"
    & $k add -SpecPath "$root-rf\spec.json" | Out-Null
    & $k watch -Seconds 8 -BreakerMin 99 -Quiet | Out-Null
    & $k approve -Id J1 | Out-Null
    & $k watch -Seconds 15 -BreakerMin 99 -Quiet | Out-Null
    $rf = Get-Content "$root-rf\jobs\J1.json" -Raw | ConvertFrom-Json
    Check 'needs freshen: back to the freshen step, which ran again' (@(Get-Content "$root-rf\freshens.txt").Count -eq 2 -and @($rf.history | ? outcome -eq 'refreshen').Count -eq 1)
    Check 'needs freshen: not set aside; the merge asks Jordan again' ($rf.status -eq 'waiting-approval' -and [int]$rf.cursor -eq 1 -and @(Get-Content "$root-rf\events.jsonl" | ? { $_ -match '"type":"approval.requested"' }).Count -eq 2)
    & $k kill -All | Out-Null

    # a gated order not cooked from a recipe (a bot's or MCP's add): Jordan's question names the script and its args, bound by their hash
    $env:BRAIN_KITCHEN = "$root-ap2"
    & $k add -Name 'tidy demo notes' -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1; Mode = 'bypassPermissions'; WorkDir = 'C:\Users\someone' } -Approve | Out-Null
    $env:BRAIN_NTFY_TOPIC = 'test-topic-defer1'; $env:KITCHEN_NOTIFY_LOG = "$root-ap2\notify.log"
    try { & $k tick -Quiet | Out-Null } finally { $env:BRAIN_NTFY_TOPIC = $null; $env:KITCHEN_NOTIFY_LOG = $null }
    Check 'tick alerts are still pushed (queued in the lock, sent after it)' ((Get-Content "$root-ap2\notify.log" -Raw -ErrorAction SilentlyContinue) -match 'MED\|test-topic-defer1\|J1 needs your sign-off')
    $aj = Get-Content "$root-ap2\jobs\J1.json" -Raw | ConvertFrom-Json -AsHashtable
    Check 'bot order: the question names the script and its real args' ($aj.approval.text -match 'runs demo-worker\.ps1 with ' -and $aj.approval.text -match 'Mode=bypassPermissions' -and $aj.approval.text -match 'WorkDir=C:\\Users\\someone' -and $aj.approval.text -match 'args sha [0-9a-f]{10}')
    $aj.steps[0].args.Mode = 'acceptEdits'; $aj | ConvertTo-Json -Depth 12 | Set-Content "$root-ap2\jobs\J1.json"   # args changed after the question
    & $k approve -Id J1 | Out-Null; & $k tick -Quiet | Out-Null
    Check 'bot order: a yes to other args does not start it' ((Get-Content "$root-ap2\jobs\J1.json" -Raw | ConvertFrom-Json).status -eq 'waiting-approval')
    & $k kill -All | Out-Null

    # spend today is counted incrementally (spend-cache.json) and still right after appends and a replaced log
    $env:BRAIN_KITCHEN = "$root-sp"; New-Item -ItemType Directory -Force -Path "$root-sp" | Out-Null
    $cost = { param($usd) '{"ts":"' + [DateTime]::UtcNow.ToString('o') + '","type":"cost","job":"J1","usd":' + $usd + '}' }
    Set-Content "$root-sp\events.jsonl" ((& $cost 1.5), '{"ts":"2020-01-01T00:00:00Z","type":"cost","job":"J0","usd":100}')
    Check 'spend: first count' ((& $k status | Out-String) -match 'spent today \$1\.50' -and (Test-Path "$root-sp\spend-cache.json"))
    Add-Content "$root-sp\events.jsonl" (& $cost 2.25)
    Check 'spend: an appended cost is added (read from where the last count stopped)' ((& $k status | Out-String) -match 'spent today \$3\.75')
    Set-Content "$root-sp\events.jsonl" (& $cost 0.5)
    Check 'spend: a replaced (rotated) log is counted again from the start' ((& $k status | Out-String) -match 'spent today \$0\.50')

    # a REWORK verdict goes to repair once (reworkTo); a second REWORK asks Jordan, it is never retried until some cook says SHIP
    $env:BRAIN_KITCHEN = "$root-rw"; New-Item -ItemType Directory -Force -Path "$root-rw\worktrees\J1\.kitchen", "$root-rw\st" | Out-Null
    Set-Content "$root-rw\st\repair.ps1" "Add-Content '$root-rw\repairs.txt' 'r'; 'repaired'"
    Set-Content "$root-rw\st\review.ps1" "Add-Content '$root-rw\reviews.txt' 'v'; 'VERDICT: REWORK - the new test does not cover X'"
    @{ name = 'rework-twice'; steps = @(@{ script = "$root-rw\st\repair.ps1"; retries = 0; timeoutSec = 30 }, @{ script = "$root-rw\st\review.ps1"; retries = 1; timeoutSec = 30; mustMatch = 'VERDICT: (SHIP|REWORK)'; mustNotMatch = 'VERDICT: REWORK'; reworkTo = 'repair'; reworkMax = 1 }) } | ConvertTo-Json -Depth 5 | Set-Content "$root-rw\spec.json"
    & $k add -SpecPath "$root-rw\spec.json" | Out-Null
    & $k watch -Seconds 30 -BackoffBaseSec 1 -BreakerMin 99 -Quiet | Out-Null
    $rw = Get-Content "$root-rw\jobs\J1.json" -Raw | ConvertFrom-Json
    Check 'rework: the first REWORK goes back to repair once' (@($rw.history | ? outcome -eq 'rework').Count -eq 1 -and @(Get-Content "$root-rw\repairs.txt").Count -eq 2)
    Check 'rework: a second REWORK is not retried on another cook' (@(Get-Content "$root-rw\reviews.txt").Count -eq 2)
    Check 'rework: a second REWORK asks Jordan (not quarantined, not done)' ($rw.status -eq 'needs-human' -and $rw.approval.text -match 'reviewer sent it back again' -and $rw.approval.text -match 'REWORK')
    & $k kill -All | Out-Null

    # one tick at a time: while another tick holds the kitchen's tick lock, a second (a Chef kick) steps aside and touches nothing
    $env:BRAIN_KITCHEN = "$root-tl"
    & $k add -Name tick-lock -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null
    $tlRoot = [IO.Path]::GetFullPath("$root-tl").ToLowerInvariant()
    $tlName = 'Global\brain-kitchen-tick-' + (([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($tlRoot)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
    $tl = [Threading.Mutex]::new($false, $tlName); [void]$tl.WaitOne(5000)
    try { $tlOut = & (Get-Process -Id $PID).Path -NoProfile -File $k tick 2>&1 | Out-String } finally { $tl.ReleaseMutex(); $tl.Dispose() }
    Check 'second tick steps aside while one is running' ($tlOut -match 'another tick is running' -and (Get-Content "$root-tl\jobs\J1.json" -Raw | ConvertFrom-Json).status -eq 'pending')
    & $k tick -Quiet | Out-Null
    Check 'the next tick does the work' ((Get-Content "$root-tl\jobs\J1.json" -Raw | ConvertFrom-Json).status -in 'running', 'done')
    & $k kill -All | Out-Null

    # a torn supervisor.json (power lost mid-write) is set aside and reset: the tick still runs work, and the rewrite is whole
    $env:BRAIN_KITCHEN = "$root-meta"
    & $k add -Name after-tear -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null
    Set-Content -LiteralPath "$root-meta\supervisor.json" -Value '{"lastTi' -NoNewline
    & $k tick -Quiet | Out-Null
    Check 'torn supervisor.json: the tick still starts work' ((Get-Content "$root-meta\jobs\J1.json" -Raw | ConvertFrom-Json).status -in 'running', 'done')
    Check 'torn supervisor.json: set aside in corrupt\ and rewritten whole' (@(Get-ChildItem "$root-meta\corrupt" -Filter 'supervisor-*.json').Count -eq 1 -and (Get-Content "$root-meta\supervisor.json" -Raw | ConvertFrom-Json).lastTick)
    Check 'torn supervisor.json: Jordan is told' ((Get-Content "$root-meta\alerts.jsonl" -Raw) -match 'supervisor\.json was damaged')
    Set-Content -LiteralPath "$root-meta\supervisor.json" -Value ''
    Check 'empty supervisor.json: status still works' ((& $k status | Out-String) -match 'KITCHEN\s+\d+ jobs')
    Check 'supervisor.json writes leave no temp files' (-not @(Get-ChildItem "$root-meta" -Filter 'supervisor.json.tmp-*').Count)
    & $k kill -All | Out-Null

    # queue cap (maxQueued): counts orders waiting to begin, so a kitchen full of finished orders can still take new work; a runaway is
    # still stopped. (Until 10-23 one cap of 100 orders alive refused adds; now orders queue and maxLive holds them on the rail.)
    $env:BRAIN_KITCHEN = "$root-cap"
    & $k add -Name done-a -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null
    & $k add -Name done-b -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null
    & $k watch -Seconds 12 -BreakerMin 99 -Quiet | Out-Null
    Check 'queue cap: finished orders never block new work' ((& $k add -Name after-cap -Script $w -MaxQueued 1 | Out-String) -notmatch 'swarm cap')
    Check 'queue cap: queued orders past maxQueued are refused and logged' ((& $k add -Name over-cap -Script $w -MaxQueued 1 | Out-String) -match 'swarm cap: 1 orders already queued' -and
        @(Get-Content "$root-cap\events.jsonl" | Where-Object { $_ -match '"type":"spawn.refused"' -and $_ -match 'queue cap 1' }).Count -eq 1)
    Check 'the old -MaxJobs (now maxLive) never refuses an add' ((& $k add -Name legacy-cap -Script $w -MaxJobs 1 | Out-String) -match '^added J4')
    & $k kill -All | Out-Null
    # Add150_Queues150_0Refused: 150 orders filed at once (6 at a time) all queue (past the old cap of 100), none is refused, ids never
    # repeat, and one tick starts at most maxConcurrent of them
    $env:BRAIN_KITCHEN = "$root-q150"
    $q150 = @(1..150 | ForEach-Object -ThrottleLimit 6 -Parallel { & $using:k add -Name "q$_" -Script $using:w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-String })
    & $k tick -Quiet | Out-Null
    $qj = @(Get-ChildItem "$root-q150\jobs" -Filter 'J*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    Check "Add150_Queues150_0Refused: $(@($q150 | Where-Object { $_ -match '^added J\d+' }).Count) added, $($qj.Count) job files, $(@($qj | Where-Object status -eq 'running').Count) running" (
        @($q150 | Where-Object { $_ -match '^added J\d+' }).Count -eq 150 -and @($qj.id | Sort-Object -Unique).Count -eq 150 -and
        -not @(Get-Content "$root-q150\events.jsonl" | Where-Object { $_ -match '"type":"spawn.refused"' }).Count -and @($qj | Where-Object { $_.status -in 'running', 'done' }).Count -in 1..4)
    & $k kill -All | Out-Null
    # maxLive: with as many orders under way as allowed (here 1, waiting on a yes), a new order waits on the rail
    $env:BRAIN_KITCHEN = "$root-live"
    & $k add -Name gated -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } -Approve | Out-Null
    & $k tick -Quiet | Out-Null
    & $k add -Name next -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null
    & $k tick -Quiet -MaxLive 1 | Out-Null
    Check 'maxLive 1: one order waiting on a yes holds a new order on the rail' ((Get-Content "$root-live\jobs\J1.json" -Raw | ConvertFrom-Json).status -eq 'waiting-approval' -and (Get-Content "$root-live\jobs\J2.json" -Raw | ConvertFrom-Json).status -eq 'pending')
    & $k tick -Quiet | Out-Null
    Check 'maxLive 100 (the default): the same order starts' ((Get-Content "$root-live\jobs\J2.json" -Raw | ConvertFrom-Json).status -in 'running', 'done')
    & $k kill -All | Out-Null
    $env:BRAIN_KITCHEN = "$root-cap"
    # close: a set-aside order closed for good leaves the set-aside list (needs a reason; only set-aside orders)
    Check 'close needs a reason' ((& $k close -Id J3 | Out-String) -match 'needs -Why')
    # nothing ends silently: a close names its replacement, gives proof, or says "dropped:"
    Check 'close needs an ending (a reason alone is not enough)' ((& $k close -Id J3 -Why 'done another way' | Out-String) -match 'needs an ending')
    Check 'close refuses proof that is not a commit, url or file' ((& $k close -Id J3 -Why 'done another way' -Proof 'trust me' | Out-String) -match '-Proof must be')
    Check 'close refuses a replacement that does not exist' ((& $k close -Id J3 -Why 're-cooked' -ReplacedBy J999 | Out-String) -match 'no such order')
    Check 'close refuses an order replacing itself' ((& $k close -Id J3 -Why 're-cooked' -ReplacedBy J3 | Out-String) -match 'cannot replace itself')
    Check 'close a stopped order with its replacement' ((& $k close -Id J3 -Why 're-cooked fresh' -ReplacedBy J1 | Out-String) -match 'closed J3' -and ($j3 = Get-Content "$root-cap\jobs\J3.json" -Raw | ConvertFrom-Json).status -eq 'closed' -and $j3.replacedBy -eq 'J1')
    Check 'close refuses a finished order' ((& $k close -Id J1 -Why 'dropped: nope' | Out-String) -match 'only set-aside')
    Check 'close logs job.closed with the reason and the replacement' ((Get-Content "$root-cap\events.jsonl" -Raw) -match '"type":"job.closed"[^\n]*re-cooked fresh' -and (Get-Content "$root-cap\events.jsonl" -Raw) -match '"replacedBy":"J1"')

    # the chores (TARGET W2): housekeeping on its own clock and lock; they never start a worker, and a GitHub that hangs inside them
    # never slows the supervisor's tick (its pre-scan reads saved CI looks only)
    $kc = "$root-chores"; $env:BRAIN_KITCHEN = $kc; $crepo = Join-Path $kc 'repo'
    function CJob($id) { Get-Content (Join-Path $kc "jobs\$id.json") -Raw | ConvertFrom-Json }
    New-Item -ItemType Directory -Force -Path $crepo, (Join-Path $kc 'results') | Out-Null
    & git -C $crepo init -q -b main 2>&1 | Out-Null; Set-Content "$crepo\a.txt" 'base'
    & git -C $crepo -c user.name=t -c user.email=t@localhost add -A 2>&1 | Out-Null; & git -C $crepo -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    foreach ($b in 'kitchen/J1', 'kitchen/J2') { & git -C $crepo branch $b 2>&1 | Out-Null }
    $mspec = Join-Path $kc 'spec.json'; @{ name = 'gate'; steps = @(@{ station = 'merge'; args = @{ Repo = $crepo } }) } | ConvertTo-Json -Depth 5 | Set-Content $mspec
    & $k add -SpecPath $mspec | Out-Null; & $k add -SpecPath $mspec | Out-Null; Add 'idle' 'ok' | Out-Null   # J1, J2 at a merge gate; J3 a plain step
    & pwsh -NoProfile -File $k chores -Quiet | Out-Null
    Check 'Chores_CannotStartWorker: a chores run leaves every pending order pending, no worker, no step.started' (@(1..3 | Where-Object { (CJob "J$_").status -eq 'pending' -and -not (CJob "J$_").run }).Count -eq 3 -and -not (Test-Path (Join-Path $kc 'run\J3-s0-a0.json')) -and -not ((Get-Content (Join-Path $kc 'events.jsonl') -Raw) -match '"step.started"'))
    $sm = Get-Content (Join-Path $kc 'supervisor.json') -Raw | ConvertFrom-Json
    Check 'chores: the run is stamped for the tick (choresTaskAt, lastChoresEnd) and did the housekeeping (board.html, freeze.json)' ($sm.choresTaskAt -and $sm.lastChoresEnd -and (Test-Path (Join-Path $kc 'board.html')) -and (Test-Path (Join-Path $kc 'freeze.json')))
    Remove-Item (Join-Path $kc 'board.html')
    & pwsh -NoProfile -File $k tick -Quiet | Out-Null
    Check 'a tick right after a chores run leaves the chores to them (no board rebuilt) and starts the plain step' (-not (Test-Path (Join-Path $kc 'board.html')) -and (CJob 'J3').status -in 'running', 'done')
    # HangingFakeGh_InChores_TickUnder5s: both gate orders have a PR and no CI look; the fake gh hangs 60 s; the chores' 8 s budget reaches one
    foreach ($id in 'J1', 'J2') { @{ job = $id; number = 1; repo = 'o/r'; url = 'https://github.com/o/r/pull/1' } | ConvertTo-Json | Set-Content (Join-Path $kc "results\$id.pr.json") }
    $ghLog = Join-Path $kc 'gh-calls.txt'; $fakeGh = Join-Path $kc 'hang-gh.ps1'
    Set-Content $fakeGh "Add-Content -LiteralPath '$ghLog' -Value (`$args -join ' '); Start-Sleep -Seconds 60; exit 1"
    $env:KITCHEN_GH = $fakeGh; $env:KITCHEN_CI_BUDGET_SEC = '8'
    try {
        $cp = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-File', "`"$k`"", 'chores', '-Quiet' -PassThru -WindowStyle Hidden
        $until = (Get-Date).AddSeconds(20); while (-not (Test-Path $ghLog) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
        $sw = [Diagnostics.Stopwatch]::StartNew(); & pwsh -NoProfile -File $k tick -Quiet | Out-Null; $sw.Stop()
        $calls = @(Get-Content $ghLog -ErrorAction SilentlyContinue).Count
        Check "HangingFakeGh_InChores_TickUnder5s: the tick took $('{0:N1}' -f $sw.Elapsed.TotalSeconds) s while gh hung in the chores" ($calls -ge 1 -and $sw.Elapsed.TotalSeconds -lt 5)
        Check 'the tick itself called gh 0 times (one call so far: the chores look)' ($calls -eq 1)
        [void]$cp.WaitForExit(40000)
        Check "the chores' CI looks stop at their budget: one look of two, logged as ci.budget ($('{0:N0}' -f ($cp.ExitTime - $cp.StartTime).TotalSeconds) s)" ((Get-Content (Join-Path $kc 'events.jsonl') -Raw) -match '"type":"ci.budget"[^\n]*"left":1' -and @(Get-Content $ghLog).Count -eq 1 -and ($cp.ExitTime - $cp.StartTime).TotalSeconds -lt 30)
        # TD-EH-15: the look the time limit cut off left its reason; Site cleanup logged it once as ci.look.failed
        function CiLook($id) { try { Get-Content (Join-Path $kc "results\$id.ci.json") -Raw | ConvertFrom-Json } catch { $null } }
        function CiFailed { @(Get-Content (Join-Path $kc 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'ci.look.failed') }
        $cut = @('J1', 'J2' | Where-Object { (CiLook $_).state -eq 'error' })
        Check 'TD-EH-15: a CI look cut off at its time limit leaves its reason in <job>.ci.json' ($cut.Count -eq 1 -and (CiLook $cut[0]).error -match '^the CI look did not finish within \d+ s$' -and (CiLook $cut[0]).at)
        $cf = CiFailed
        Check 'TD-EH-15: Site cleanup logs ci.look.failed with that reason and time' ($cf.Count -eq 1 -and $cf[0].job -eq $cut[0] -and $cf[0].error -eq (CiLook $cut[0]).error -and $cf[0].at)
        # gh signed out: both gates' looks fail at once, each with gh's reason, each logged once (the reason changed for the first)
        $soGh = Join-Path $kc 'signedout-gh.ps1'; Set-Content $soGh "[Console]::Error.WriteLine('To get started with GitHub CLI, please run:  gh auth login'); exit 4"
        $env:KITCHEN_GH = $soGh; $env:KITCHEN_CI_BUDGET_SEC = '90'
        try {
            foreach ($id in 'J1', 'J2') { $f = Join-Path $kc "results\$id.ci.json"; if (Test-Path $f) { (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-5) } }
            & pwsh -NoProfile -File $k chores -Quiet | Out-Null
            $cf = CiFailed
            Check 'TD-EH-15: gh signed out -> each gate keeps "gh is not signed in" as its reason' (@('J1', 'J2' | Where-Object { (CiLook $_).state -eq 'error' -and (CiLook $_).error -match '^gh is not signed in to GitHub' }).Count -eq 2)
            Check 'TD-EH-15: a new reason is logged once per gate (3 ci.look.failed lines so far)' ($cf.Count -eq 3 -and @($cf | Where-Object { $_.error -match 'not signed in' }).Count -eq 2)
            foreach ($id in 'J1', 'J2') { (Get-Item (Join-Path $kc "results\$id.ci.json")).LastWriteTime = (Get-Date).AddMinutes(-5) }
            & pwsh -NoProfile -File $k chores -Quiet | Out-Null
            Check 'TD-EH-15: the same reason again is not logged again (still 3), though the look was taken again' ((CiFailed).Count -eq 3 -and ((Get-Date) - (Get-Item (Join-Path $kc 'results\J1.ci.json')).LastWriteTime).TotalMinutes -lt 2)
            Check 'TD-EH-15: the reasons logged are remembered per gate (supervisor.json ciLookFailed)' ((Get-Content (Join-Path $kc 'supervisor.json') -Raw | ConvertFrom-Json).ciLookFailed.J2 -match 'not signed in')
        } finally { $env:KITCHEN_GH = $fakeGh }
    } finally { $env:KITCHEN_GH = $null; $env:KITCHEN_CI_BUDGET_SEC = $null; & $k kill -All | Out-Null }
    Remove-Item -Recurse -Force $kc -ErrorAction SilentlyContinue

    # TD-EH-18: lines a busy log pushed to events-pending-<pid>.jsonl rejoin events.jsonl at Site cleanup: none lost, none twice, and a
    # second cleanup at the same moment (the fold lock held) leaves them for the next run. The Stop-work order then counts them.
    $kf = "$root-fold"; $env:BRAIN_KITCHEN = $kf; New-Item -ItemType Directory -Force $kf | Out-Null
    $fev = Join-Path $kf 'events.jsonl'; $ft0 = [DateTime]::UtcNow
    function FLine([int]$i, [string]$type, [int]$ago) { [ordered]@{ ts = $ft0.AddMinutes(-$ago).ToString('o'); type = $type; job = "J$i" } | ConvertTo-Json -Compress }
    function FCount([string]$job) { @(Get-Content $fev | Where-Object { $_ -match """job"":""$job""" -and $_ -match '"type":"step\.' }).Count }
    Set-Content $fev (FLine 1 'step.done' 1) -Encoding utf8
    $crash4 = FLine 4 'step.crash' 3; Add-Content $fev $crash4 -Encoding utf8
    Set-Content (Join-Path $kf 'events-pending-111.jsonl') @((FLine 2 'step.fail' 6), (FLine 3 'step.fail' 5)) -Encoding utf8   # a busy log's lines
    Set-Content (Join-Path $kf 'events-pending-222.jsonl.fold') @($crash4, (FLine 5 'step.fail' 2)) -Encoding utf8   # a fold cut off half-way
    $p333 = Join-Path $kf 'events-pending-333.jsonl'; Set-Content $p333 (FLine 6 'step.fail' 1) -Encoding utf8
    Check 'TD-EH-18: before the fold the Stop-work order sees 1 failure in 2 steps' ((& $k status | Out-String) -match 'recent fail rate 50\s?%')
    $hold = [IO.File]::Open($p333, 'Open', 'ReadWrite', 'None')   # a writer mid-line
    try { & pwsh -NoProfile -File $k chores -Quiet | Out-Null } finally { $hold.Dispose() }
    Check 'TD-EH-18: pending lines rejoin events.jsonl, each once (J2, J3, J5)' ((FCount 'J2') -eq 1 -and (FCount 'J3') -eq 1 -and (FCount 'J5') -eq 1)
    Check 'TD-EH-18: a line already in the log from a cut-off fold is not added twice (J4)' ((FCount 'J4') -eq 1)
    Check 'TD-EH-18: folded files are removed; a file a writer still holds waits for the next run' (-not (Test-Path (Join-Path $kf 'events-pending-111.jsonl')) -and -not (Test-Path (Join-Path $kf 'events-pending-222.jsonl.fold')) -and (Test-Path $p333) -and (FCount 'J6') -eq 0)
    $fd = @(Get-Content $fev | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'events.folded')
    Check 'TD-EH-18: logged as events.folded {files 2, lines 3}' ($fd.Count -eq 1 -and $fd[0].files -eq 2 -and $fd[0].lines -eq 3)
    Check 'TD-EH-18: the Stop-work order now counts the folded failures (4 of 5)' ((& $k status | Out-String) -match 'recent fail rate 80\s?%')
    $sha = (([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($kf.ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
    $fl = New-Object Threading.Mutex($false, "Global\brain-kitchen-fold-$sha"); [void]$fl.WaitOne(5000)
    try { & pwsh -NoProfile -File $k chores -Quiet | Out-Null } finally { $fl.ReleaseMutex(); $fl.Dispose() }
    Check 'TD-EH-18: a cleanup that finds another fold under way leaves the file for later (nothing lost)' ((Test-Path $p333) -and (FCount 'J6') -eq 0)
    $j1 = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-File', "`"$k`"", 'chores', '-Quiet' -PassThru -WindowStyle Hidden
    & pwsh -NoProfile -File $k chores -Quiet | Out-Null; [void]$j1.WaitForExit(60000)
    Check 'TD-EH-18: two cleanups started together fold the line once' ((FCount 'J6') -eq 1 -and -not (Test-Path $p333) -and -not @(Get-ChildItem $kf -Filter 'events-pending-*').Count)
    Remove-Item -Recurse -Force $kf -ErrorAction SilentlyContinue

    # TD-EH-04 "Sent or not": every alert line says whether it reached the phone. notify.ps1 writes to a test log instead of ntfy, and
    # KITCHEN_NOTIFY_FAIL makes it answer as if ntfy had returned that status: no network call in any of these.
    $env:BRAIN_KITCHEN = "$root-sent"; $sentLog = "$root-sent-notify.log"; $env:BRAIN_NTFY_TOPIC = $null; $env:KITCHEN_NOTIFY_LOG = $null; $env:KITCHEN_NOTIFY_FAIL = $null
    try {
        & $k add -Name sent-a -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null
        function SentAlerts { @(Get-Content "$root-sent\alerts.jsonl" | ForEach-Object { $_ | ConvertFrom-Json }) }
        function Sent-Alert([string]$id) { Set-Content -LiteralPath "$root-sent\jobs\$id.json" '{ torn'; & $k status | Out-Null; @(SentAlerts | Where-Object job -eq $id)[-1] }   # a damaged job file is alerted at once
        $a = Sent-Alert 'J90'
        Check 'SentOrNot_PushOff: the alert line says not sent because phone alerts are off' ($a.sent -eq 'off' -and $a.why -eq 'phone alerts are off' -and -not (Test-Path $sentLog))
        Check 'SentOrNot_PushOff: kitchen status marks it "(not sent: phone alerts are off)"' ((& $k status | Out-String) -match 'J90\.json was damaged[^\r\n]*\(not sent: phone alerts are off\)')
        $env:BRAIN_NTFY_TOPIC = 'sentornot' + [guid]::NewGuid().ToString('N').Substring(0, 8); $env:KITCHEN_NOTIFY_LOG = $sentLog
        $a = Sent-Alert 'J91'
        Check 'SentOrNot_Sent: the alert line says sent (ok, no reason) and the push went out once' ($a.sent -eq 'ok' -and -not $a.why -and @(Get-Content $sentLog).Count -eq 1)
        $env:KITCHEN_NOTIFY_FAIL = '503'; $a = Sent-Alert 'J92'
        Check 'SentOrNot_NtfyError: the alert line says failed, "ntfy error (HTTP 503)", http 503' ($a.sent -eq 'failed' -and $a.why -eq 'ntfy error (HTTP 503)' -and $a.http -eq 503 -and @(Get-Content $sentLog).Count -eq 1)
        $env:KITCHEN_NOTIFY_FAIL = '429'; $a = Sent-Alert 'J93'
        Check 'SentOrNot_RateLimited: the alert line says limited, "ntfy rate limit (HTTP 429)"' ($a.sent -eq 'limited' -and $a.why -eq 'ntfy rate limit (HTTP 429)' -and $a.http -eq 429)
        $env:KITCHEN_NOTIFY_FAIL = $null
        $ev = @(Get-Content "$root-sent\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'alert' -and $_.job -eq 'J92' })
        Check 'SentOrNot_NtfyError: the alert event carries sent and why too (the Board marks it)' ($ev.Count -eq 1 -and $ev[0].sent -eq 'failed' -and $ev[0].why -eq 'ntfy error (HTTP 503)')
        # inside the tick's locked pass the alert is held, sent after the lock is let go, and the result follows as an alert.sent event
        Set-Content -LiteralPath "$root-sent\supervisor.json" -Value '{"lastTi' -NoNewline
        & $k tick -Quiet | Out-Null
        $h = @(SentAlerts | Where-Object { $_.text -match 'supervisor\.json was damaged' })
        $hs = @(Get-Content "$root-sent\events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'alert.sent' })
        Check 'SentOrNot_Held: an alert in the locked pass is written as held, then an alert.sent event says it was sent' ($h.Count -eq 1 -and $h[0].sent -eq 'held' -and $hs.Count -eq 1 -and $hs[0].sent -eq 'ok' -and "$($hs[0].alertTs)" -eq "$($h[0].ts)" -and @(Get-Content $sentLog).Count -ge 2)
        # with phone alerts off, the same alert in the locked pass is recorded off at once: nothing is held for a send that cannot happen
        $env:BRAIN_NTFY_TOPIC = $null; $env:KITCHEN_NOTIFY_LOG = $null
        Set-Content -LiteralPath "$root-sent\supervisor.json" -Value '{"lastTi' -NoNewline
        & $k tick -Quiet | Out-Null
        $h2 = @(SentAlerts | Where-Object { $_.text -match 'supervisor\.json was damaged' })
        Check 'SentOrNot_PushOff: an alert in the locked pass is recorded off, not held' ($h2.Count -eq 2 -and $h2[1].sent -eq 'off' -and $h2[1].why -eq 'phone alerts are off' -and @(Get-Content "$root-sent\events.jsonl" | Where-Object { $_ -match '"type":"alert\.sent"' }).Count -eq 1)
        Check 'SentOrNot: every alert line has a sent field, and no reason repeats the alert words' (@(SentAlerts | Where-Object { -not $_.sent }).Count -eq 0 -and @(SentAlerts | Where-Object { $_.why -match 'damaged|J9\d' }).Count -eq 0)
    } finally { $env:BRAIN_NTFY_TOPIC = $null; $env:KITCHEN_NOTIFY_LOG = $null; $env:KITCHEN_NOTIFY_FAIL = $null; & $k kill -All | Out-Null; Remove-Item -Force $sentLog -ErrorAction SilentlyContinue }

    # TD-EH-05/17/20/21: a set-aside alert says what failed (the push stays contents-free), a crash says why it may have died, the doctor
    # puts back a requeue that died halfway, and a failed git cleanup call says so. Private kitchen; pushes go to a test log, not ntfy.
    $eh = "$root-eh"; $env:BRAIN_KITCHEN = $eh; $ehLog = "$root-eh-notify.log"; $env:KITCHEN_SCRATCH_DIR = "$root-eh-scratch"
    New-Item -ItemType Directory -Force -Path $eh, "$root-eh-scratch" | Out-Null
    function EJob($id) { Get-Content (Join-Path $eh "jobs\$id.json") -Raw | ConvertFrom-Json }
    function ETickUntil([string]$id) { for ($i = 0; $i -lt 30; $i++) { & $k tick -Quiet | Out-Null; if ((EJob $id).status -notin 'running', 'pending') { return }; Start-Sleep -Milliseconds 700 } }
    $failer = Join-Path $eh 'failer.ps1'
    Set-Content $failer ("'tests: 3 failed in Test-Pay.ps1, it needs your yes to retry " + ('word ' * 30).Trim() + "'; exit 1")
    $env:BRAIN_NTFY_TOPIC = 'ehtest' + [guid]::NewGuid().ToString('N').Substring(0, 10); $env:KITCHEN_NOTIFY_LOG = $ehLog
    try {
        & $k add -Name eh-fail -Script $failer -Retries 0 | Out-Null                                     # J1
        & $k add -Name eh-crash -Script $w -ScriptArgs @{ Behavior = 'crash' } -Retries 0 | Out-Null    # J2
        ETickUntil 'J1'; ETickUntil 'J2'
        $qa = @(Get-Content "$eh\alerts.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.job -eq 'J1' -and $_.text -match 'quarantined after' })
        $qWhy = if ($qa.Count) { ($qa[0].text -split ' Why: ', 2)[1] } else { '' }
        Check "TD-EH-05: the set-aside alert says what failed, its first 120 characters ($($qWhy.Length))" ((EJob 'J1').status -eq 'quarantined' -and $qa.Count -eq 1 -and $qWhy -like 'exit 1: tests: 3 failed in Test-Pay.ps1, it needs your yes*' -and $qWhy.Length -eq 120)
        $pushes = @(Get-Content $ehLog -ErrorAction SilentlyContinue)
        Check 'TD-EH-05: the push stays contents-free and keeps its kind (Failed, not sign-off, though the log line says "needs your yes")' (@($pushes | Where-Object { $_ -match '\|J1 ' }).Count -eq 1 -and @($pushes | Where-Object { $_ -match '\|J1 ' })[0] -eq "MED|$($env:BRAIN_NTFY_TOPIC)|J1 Failed; the Board has the details" -and -not ($pushes -match 'Test-Pay|eh-fail|word'))
        $cd = [string]@((EJob 'J2').history)[-1].detail
        Check "TD-EH-20: a crash names its last log line and no sleep or cut-off Walkround ($cd)" ((EJob 'J2').status -eq 'quarantined' -and $cd -match '^worker died without an exit code; last log line: demo-worker crash starting \(job J2' -and $cd -match 'no PC sleep and no cut-off Walkround in the last 5 min$')
        Check 'TD-EH-20: a Walkround that reached its end leaves no TICK-BEGAN and logs no tick.stopped' (-not (Test-Path "$eh\run\TICK-BEGAN") -and -not ((Get-Content "$eh\events.jsonl" -Raw) -match '"type":"tick\.stopped"'))
        # the PC slept a moment ago (supervisor.resumed in the log): the crash says so
        & $k add -Name eh-crash-sleep -Script $w -ScriptArgs @{ Behavior = 'crash' } -Retries 0 | Out-Null   # J3
        & $k tick -Quiet | Out-Null
        Add-Content "$eh\events.jsonl" (@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = 'supervisor.resumed'; job = ''; gapSec = 400; running = 1 } | ConvertTo-Json -Compress)
        ETickUntil 'J3'
        $cd3 = [string]@((EJob 'J3').history)[-1].detail
        Check "TD-EH-20: a crash right after the PC slept says so ($cd3)" ($cd3 -match 'the PC slept 0 min ago \(asleep 400 s\)')
        # a Walkround cut off before its end (its TICK-BEGAN is still there): the next one logs tick.stopped and the crash names it
        & $k add -Name eh-crash-cut -Script $w -ScriptArgs @{ Behavior = 'crash' } -Retries 0 | Out-Null   # J4
        & $k tick -Quiet | Out-Null
        Set-Content "$eh\run\TICK-BEGAN" (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
        ETickUntil 'J4'
        $cd4 = [string]@((EJob 'J4').history)[-1].detail
        $ts = @(Get-Content "$eh\events.jsonl" | Where-Object { $_ -match '"type":"tick\.stopped"' } | ForEach-Object { $_ | ConvertFrom-Json })
        Check "TD-EH-20: a cut-off Walkround is logged once (tick.stopped, ~300 s) and the crash names it ($cd4)" ($ts.Count -eq 1 -and $ts[0].ageSec -ge 295 -and $cd4 -match "a Walkround was cut off \d min ago \(the task's 5-min limit or a restart\)" -and -not (Test-Path "$eh\run\TICK-BEGAN"))

        # TD-EH-17: closed with recooking for 20 min = a requeue that died halfway: put back as it was and alerted; 2 min old = still going
        $tpl = Get-Content "$eh\jobs\J1.json" -Raw | ConvertFrom-Json -AsHashtable
        foreach ($x in @(@{ id = 'J5'; from = 'killed'; min = 20 }, @{ id = 'J6'; from = 'quarantined'; min = 2 })) {
            $tpl.id = $x.id; $tpl.status = 'closed'; $tpl.recooking = $true; $tpl.recookFrom = $x.from; $tpl.recookAt = (Get-Date).ToUniversalTime().AddMinutes(-$x.min).ToString('o')
            $tpl | ConvertTo-Json -Depth 12 | Set-Content "$eh\jobs\$($x.id).json" -Encoding utf8
        }
        # TD-EH-21: a closed order's worktree folder git does not know (remove fails) and a branch checked out elsewhere (branch -d fails)
        $ehRepo = "$eh-repo"; New-Item -ItemType Directory -Force -Path $ehRepo | Out-Null
        & git -C $ehRepo init -q -b main 2>&1 | Out-Null; Set-Content "$ehRepo\a.txt" 'base'
        & git -C $ehRepo -c user.name=t -c user.email=t@localhost add -A 2>&1 | Out-Null; & git -C $ehRepo -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
        & git -C $ehRepo branch kitchen/J8 2>&1 | Out-Null; & git -C $ehRepo worktree add -q "$eh-wt8" kitchen/J8 2>&1 | Out-Null
        foreach ($id in 'J7', 'J8') { $tpl.id = $id; $tpl.status = 'closed'; $tpl.recooking = $null; $tpl.recookFrom = $null; $tpl.recookAt = $null; $tpl.vars = @{ repo = $ehRepo }; $tpl | ConvertTo-Json -Depth 12 | Set-Content "$eh\jobs\$id.json" -Encoding utf8 }
        New-Item -ItemType Directory -Force -Path "$eh\worktrees\J7" | Out-Null; Set-Content "$eh\worktrees\J7\.git" 'gitdir: C:\no-such-place\.git\worktrees\J7'
        $dr = & $k doctor -Json | Out-String | ConvertFrom-Json
        $j5 = EJob 'J5'; $j6 = EJob 'J6'
        Check 'TD-EH-17: the doctor puts a requeue stuck for 20 min back to its status before (killed) and clears recooking' ($j5.status -eq 'killed' -and -not $j5.recooking -and -not $j5.recookAt -and @($j5.history)[-1].outcome -eq 'requeue.reset')
        Check 'TD-EH-17: a requeue 2 min old is left alone' ($j6.status -eq 'closed' -and $j6.recooking)
        Check 'TD-EH-17: it is a doctor problem, alerted and logged (job.requeue.reset)' (@($dr.problems | Where-Object { $_ -match '^J5: a requeue stopped halfway 2\d min ago' }).Count -eq 1 -and (Get-Content "$eh\alerts.jsonl" -Raw) -match 'Kitchen doctor: [^\r\n]*J5: a requeue stopped halfway' -and (Get-Content "$eh\events.jsonl" -Raw) -match '"type":"job.requeue.reset","job":"J5"')
        $notes = @($dr.notes)
        Check "TD-EH-21: a failed git worktree remove is a one-line note, and the folder still goes ($($notes -join ' | '))" (@($notes | Where-Object { $_ -match '^git worktree remove failed for J7: \S' }).Count -eq 1 -and -not (Test-Path "$eh\worktrees\J7"))
        Check 'TD-EH-21: a failed git branch -d (checked out elsewhere) is a note; the branch is kept' (@($notes | Where-Object { $_ -match '^git branch -d failed for kitchen/J8: \S' }).Count -eq 1 -and (& git -C $ehRepo branch --list 'kitchen/J8'))
        Check 'TD-EH-21: the doctor event carries the notes' ((Get-Content "$eh\events.jsonl" -Raw) -match '"type":"doctor"[^\n]*"notes":"[^"]*git worktree remove failed for J7')
    } finally {
        $env:BRAIN_NTFY_TOPIC = $null; $env:KITCHEN_NOTIFY_LOG = $null; $env:KITCHEN_SCRATCH_DIR = $null; & $k kill -All | Out-Null
        Remove-Item -Recurse -Force $ehLog, "$root-eh-scratch", "$eh-repo", "$eh-wt8" -ErrorAction SilentlyContinue
    }
    # ---- TD-5: kitchen.ps1 status groups work orders by Site; with no Site its output is exactly as before ----
    function SiteJob([string]$dir, [string]$jid, [hashtable]$vars) {
        @{ id = $jid; name = "n$jid"; recipe = 'improve'; status = 'done'; cursor = 1; attempt = 0; history = @(); vars = $vars; steps = @(@{ script = $w; args = @{} }) } | ConvertTo-Json -Depth 6 | Set-Content "$dir\jobs\$jid.json" -Encoding utf8
    }
    $ns = "$root-nosite"; New-Item -ItemType Directory -Force -Path "$ns\jobs" | Out-Null; $env:BRAIN_KITCHEN = $ns
    SiteJob $ns 'J1' @{ goal = 'g' }; SiteJob $ns 'J2' @{ goal = 'g' }
    $nsOut = @((& $k status -DailyBudgetUsd 5 | Out-String).TrimEnd() -split "`r?`n")
    $golden = @('KITCHEN  2 jobs  running 0  done 2  attention 0  recent fail rate 0%  spent today $0.00 of $5.00', ('  {0,-4} {1,-16} {2,-16} step {3}/{4}  {5}' -f 'J1', 'done', 'nJ1', 1, 1, ''), ('  {0,-4} {1,-16} {2,-16} step {3}/{4}  {5}' -f 'J2', 'done', 'nJ2', 1, 1, ''), '  FREEZE: merge freeze windows not checked yet (the next supervisor tick writes freeze.json)')
    Check "TD5 status with no Site: exactly the lines from before Sites, no header ($($nsOut -join ' | '))" (($nsOut -join "`n") -ceq ($golden -join "`n"))
    $nsJson = & $k status -Json | Out-String | ConvertFrom-Json -AsHashtable
    Check 'TD5 status -Json with no Site: the same keys as before (no "sites", no "sitesError")' ((@($nsJson.Keys | Sort-Object) -join ',') -ceq 'alerts,breaker,failRate,freeze,jobs')
    # Sites: J1 carries TD, J2 GW, J3's Tower names ZG in kitchen.repo.json, J4's Tower is listed by the registry as JH, J5 has none
    $st = "$root-site"; $zgT = "$st-zg"; $jhT = "$st-jh"
    New-Item -ItemType Directory -Force -Path "$st\jobs", $zgT, $jhT | Out-Null; $env:BRAIN_KITCHEN = $st
    Set-Content "$zgT\kitchen.repo.json" '{ "site": "ZG" }'
    Set-Content "$st\kitchen.json" (@{ sites = @{ JH = @{ name = 'Job hunt'; towers = @($jhT) } } } | ConvertTo-Json -Depth 5)
    SiteJob $st 'J1' @{ site = 'TD' }; SiteJob $st 'J2' @{ site = 'GW' }; SiteJob $st 'J3' @{ repo = $zgT }; SiteJob $st 'J4' @{ repo = $jhT }; SiteJob $st 'J5' @{ goal = 'g' }; SiteJob $st 'J6' @{ site = 'TD' }
    $sOut = @((& $k status | Out-String).TrimEnd() -split "`r?`n" | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^\s+FREEZE:' } | ForEach-Object { if ($_ -match '^\s+(J\d+)\s') { $Matches[1] } else { $_.Trim() } })
    Check "TD5 status grouped by Site: Sites by code with their counts, registry names, Unassigned last ($($sOut -join ' | '))" (($sOut -join '|') -ceq 'SITE GW: 1 work order|J2|SITE JH Job hunt: 1 work order|J4|SITE TD: 2 work orders|J1|J6|SITE ZG: 1 work order|J3|UNASSIGNED: 1 work order|J5')
    $sJson = & $k status -Json | Out-String | ConvertFrom-Json -AsHashtable
    Check 'TD5 status -Json carries the groups (site, name, order ids), the jobs list unchanged' (@($sJson.jobs).Count -eq 6 -and (@($sJson.sites | ForEach-Object { "$($_.site)=$(@($_.jobs) -join '+')" }) -join ' ') -ceq 'GW=J2 JH=J4 TD=J1+J6 ZG=J3 =J5' -and @($sJson.sites)[1].name -eq 'Job hunt')
    Set-Content "$st\kitchen.json" '{ "sites": "nope" }'
    $bOut = & $k status | Out-String
    Check 'TD5 a malformed registry: status still works, names it, groups by the orders and Towers alone' ($bOut -match 'SITES REGISTRY unreadable[^\r\n]*''sites'' must be an object' -and $bOut -match 'SITE TD: 2 work orders' -and $bOut -match 'UNASSIGNED: 2 work orders')
    Remove-Item -Recurse -Force $ns, $st, $zgT, $jhT -ErrorAction SilentlyContinue; $env:BRAIN_KITCHEN = $root
} finally {
    $env:BRAIN_KITCHEN = $null; $env:KITCHEN_TICK_FROM = $null; $env:KITCHEN_HUNG_DEFAULT_SEC = $null; $env:KITCHEN_AGY_EXE = $null; $env:KITCHEN_CHEF_UPDATE_SCRIPT = $null; $env:KITCHEN_CHEF_UPDATE_DRYRUN = $null
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | ? { $_.CommandLine -and $_.CommandLine.Contains($root) } | % { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null }
    Remove-Item -Recurse -Force $root, "$root-b", "$root-sa", "$root-sb", "$root-sc", "$root-sd", "$root-se", "$root-sf", "$root-sg", "$root-rot", "$root-t", "$root-cap", "$root-scr", "$root-meta", "$root-busy", "$root-sleep", "$root-slow", "$root-hung", "$root-appr", "$root-ver", "$root-so", "$root-tl", "$root-rw", "$root-ah", "$root-rf", "$root-ap2", "$root-sp", "$root-q150", "$root-live", "$root-sent", "$root-eh", "$root-r", "$root-pause", "$root-hold", "$root-wd", "$root-sitep", "$root-siteb", "$root-nosite" -ErrorAction SilentlyContinue
    Remove-Item -Force -LiteralPath $fake -ErrorAction SilentlyContinue  # only this run's fake cook; a wildcard deleted a concurrent run's
    $env:FAKE_REST = $null; $env:FAKE_REST_WHO = $null
}
Write-Host "KitchenSupervisor tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
