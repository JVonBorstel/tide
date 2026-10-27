# Tests for failure care (task 32): kitchen/failure-policy.json and its reader kitchen/failure-policy.ps1, the cleared states written by
# kitchen/kitchen.ps1 (close, requeue, reopen, doctor), duplicates at the door (add, cook.ps1) and the plain sentence on every failure.
# One check per acceptance line of the task, named after it. A private kitchen root and a recipe folder under TEMP; self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$k = Join-Path $kd 'kitchen.ps1'; $cook = Join-Path $kd 'cook.ps1'; $w = Join-Path $kd 'demo-worker.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-care-' + [guid]::NewGuid().ToString('N'))
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_RECIPES', 'BRAIN_NTFY_TOPIC', 'BRAIN_AGENT_DEPTH', 'KITCHEN_JOB', 'KITCHEN_NO_WATCH', 'KITCHEN_CARE_NO_GIT', 'KITCHEN_AGY_EXE') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
$env:BRAIN_KITCHEN = $root; $env:BRAIN_NTFY_TOPIC = $null; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null; $env:KITCHEN_NO_WATCH = '1'; $env:KITCHEN_AGY_EXE = 'off'
$script:pass = 0; $script:fail = 0
function Check($n, $c, [scriptblock]$why = $null) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n"; if ($why) { try { & $why | ForEach-Object { Write-Host "  $_" } } catch { } } } }
function Read-CareJob($id) { Get-Content (Join-Path $root "jobs\$id.json") -Raw | ConvertFrom-Json -AsHashtable }
function Events { @(Get-Content (Join-Path $root 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
function Iso([DateTime]$d) { $d.ToUniversalTime().ToString('o') }
$now = [DateTime]::UtcNow
# a job file written by hand (the tests need old times the clock cannot make); the next id moves past it
function Put-Job([string]$id, [hashtable]$h) {
    $j = @{ id = $id; name = "test $id"; status = 'quarantined'; cursor = 0; attempt = 0; depth = 0; parent = ''; run = $null; notBefore = $null; approval = $null
        steps = @(@{ script = $w; args = @{ Behavior = 'fail' }; replay = 'safe'; retries = 0; timeoutSec = 60; maxMB = 400; maxLogMB = 5; hungSec = 60 }); history = @(); created = (Iso $now.AddDays(-5)) }
    foreach ($key in $h.Keys) { $j[$key] = $h[$key] }
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'jobs') | Out-Null
    $j | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $root "jobs\$id.json") -Encoding utf8
    $n = [int]$id.Substring(1) + 1; $cp = Join-Path $root 'jobs\next-id.txt'
    $cur = 0; if (Test-Path $cp) { [void][int]::TryParse((Get-Content $cp -Raw).Trim(), [ref]$cur) }
    if ($n -gt $cur) { Set-Content $cp "$n" -NoNewline }
}
function Doctor([switch]$FindOnly) { (& $k doctor -Json -FindOnly:$FindOnly | Out-String) | ConvertFrom-Json }
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $rd = Join-Path $root 'recipes'; New-Item -ItemType Directory -Force -Path $rd | Out-Null; $env:KITCHEN_RECIPES = $rd
    @{ description = 'care test'; vars = @{ goal = @{ required = $true; max = 400 }; repo = @{ default = $root } }
        steps = @(@{ script = $w; args = @{ Behavior = 'ok'; Seconds = 1 }; retries = 0; timeoutSec = 60; maxMB = 400 }) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rd 'care.json') -Encoding utf8
    . (Join-Path $kd 'jobs-lib.ps1'); . (Join-Path $kd 'failure-policy.ps1')
    $pol = Read-FailurePolicy

    # ---- policy table maps each class and an unknown failure to "needs a look" ----
    $cases = [ordered]@{
        flaky = @('timeout', 'ran 301s (limit 300s)'); conflict = @('fail', 'exit 1: freshen: CONFLICT merging main into kitchen/J12 in: kitchen/kitchen.ps1')
        stale = @('fail', 'exit 1: freshen: the patch does not apply to main any more'); resting = @('fail', 'cloud hiccup x6: claude usage limit reached')
        privacy = @('hold', 'looks private: a cloud crew would see it'); real = @('fail', 'exit 1: tests: FAILED: Test-KitchenSupervisor')
        infra = @('fail', 'exit 1: ci-wait: could not reach GitHub to read PR #12 (HTTP 502)'); stopped = @('killed', '')
    }
    $wrong = @(foreach ($c in $cases.Keys) { $v = Get-FailureVerdict $cases[$c][0] $cases[$c][1] $pol; if ($v.class -ne $c -or -not $v.action -or -not $v.say -or -not $v.next) { "$c -> $($v.class)" } })
    $acts = @{ flaky = 'retry'; conflict = 'freshen'; stale = 'retry'; resting = 'wait'; privacy = 'ask'; real = 'stop'; infra = 'wait'; stopped = 'ask' }
    $wrongAct = @(foreach ($c in $acts.Keys) { if ((Get-FailureVerdictOfClass $c $pol).action -ne $acts[$c]) { $c } })
    $u = Get-FailureVerdict 'fail' 'exit 1: something nobody has seen before' $pol
    Check "policy table maps each class and an unknown failure to ""needs a look"" ($($wrong + $wrongAct -join ', '))" ($wrong.Count -eq 0 -and $wrongAct.Count -eq 0 -and $u.class -eq 'real' -and $u.unknown -and $u.next -match 'needs a look' -and $u.action -eq 'stop')
    Check 'policy table: every class has one of the five actions and a back-off' (@($pol.classes.Keys | Where-Object { $pol.classes[$_].action -notin 'retry', 'freshen', 'wait', 'ask', 'stop' -or $pol.classes[$_].backoff -notin 'wait', 'code' }).Count -eq 0)
    $texts = @(foreach ($c in $cases.Keys) { Format-FailureText (Get-FailureVerdict $cases[$c][0] $cases[$c][1] $pol) 2 3 'tests' }) + (Format-FailureText $u 2 3 'tests')
    $bad = @($texts | Where-Object { $_ -match ':[^;]*:' -or $_ -cmatch '\b(retry|close|see why)\b' })
    Check "failure sentences read cleanly: one colon after next, button names keep their capitals ($($bad -join ' | '))" ($bad.Count -eq 0 -and ($texts -join "`n") -cmatch 'next: Retry puts it back in the queue; Close ends it\.')
    Check 'policy table: the back-off classes are read from it (Get-FailureClass)' ((& { . (Join-Path $kd 'backoff-lib.ps1'); (Get-FailureClass 'fail' 'gh: API rate limit exceeded') + ',' + (Get-FailureClass 'fail' 'exit 1') }) -eq 'wait,code')

    # ---- add refuses a duplicate and the force flag works ----
    $c1 = (& $cook -Recipe care -Vars @{ goal = 'Make kitchen/notify.ps1 say the job number.' } -Json | Out-String) | ConvertFrom-Json
    $c2 = (& $cook -Recipe care -Vars @{ goal = '  make Kitchen/Notify.ps1 say the JOB number!! ' } -Json | Out-String) | ConvertFrom-Json
    $c3 = (& $cook -Recipe care -Vars @{ goal = 'Make kitchen/notify.ps1 say the job number. It should read better on a phone.' } -Json | Out-String) | ConvertFrom-Json
    $c4 = (& $cook -Recipe care -Vars @{ goal = 'make kitchen/notify.ps1 say the job number' } -Force -Json | Out-String) | ConvertFrom-Json
    $c5 = (& $cook -Recipe care -Vars @{ goal = 'something else entirely' } -Json | Out-String) | ConvertFrom-Json
    $dupEv = @(Events | Where-Object type -eq 'job.duplicate')
    Check 'add refuses a duplicate and the force flag works' ($c1.ok -and -not $c2.ok -and $c2.duplicate -eq $c1.job -and $c4.ok -and $c4.job -ne $c1.job -and $c5.ok -and $dupEv.Count -ge 1) { "c1 $($c1 | ConvertTo-Json -Compress)"; "c2 $($c2 | ConvertTo-Json -Compress)"; "c4 $($c4 | ConvertTo-Json -Compress)" }
    Check 'add: the same files and title is a duplicate too (more words after the first sentence)' (-not $c3.ok -and $c3.duplicate -eq $c1.job)
    $raw = & $k add -Name 'plain' -Script $w | Out-String; $raw2 = & $k add -Name 'plain' -Script $w | Out-String
    Check 'add: a plain script order (no goal) is never a duplicate' ($raw -match '^added' -and $raw2 -match '^added')
    $spec = Join-Path $root 'spec.json'; @{ name = 'care: same'; recipe = 'care'; vars = @{ goal = 'Make kitchen/notify.ps1 say the job number.' }; steps = @(@{ script = $w; args = @{ Behavior = 'ok' } }) } | ConvertTo-Json -Depth 6 | Set-Content $spec
    $o = & $k add -SpecPath $spec | Out-String; $code = $LASTEXITCODE
    $o2 = & $k add -SpecPath $spec -Force | Out-String
    Check 'add (kitchen.ps1): DUPLICATE names the open order, exit 4; -Force adds it and notes it' ($o -match "^DUPLICATE: $($c1.job) is open" -and $code -eq 4 -and $o2 -match '^added (J\d+)' -and (Read-CareJob ([regex]::Match($o2, 'added (J\d+)').Groups[1].Value)).forcedOver -eq $c1.job)
    & $k kill -All | Out-Null
    $c6 = (& $cook -Recipe care -Vars @{ goal = 'Make kitchen/notify.ps1 say the job number.' } -Json | Out-String) | ConvertFrom-Json
    Check 'add: a stopped or failed twin does not block a new attempt at its goal (the doctor clears the old one as its duplicate)' ($c6.ok -and $c6.job)
    & $k kill -All | Out-Null

    # ---- every failure has a plain sentence ----
    $a = & $k add -Name 'breaks' -Script $w -ScriptArgs @{ Behavior = 'fail' } -Retries 0 -TimeoutSec 60 -HungSec 60 | Out-String
    $fid = [regex]::Match($a, 'added (J\d+)').Groups[1].Value
    & $k watch -Seconds 90 -BackoffBaseSec 1 -BreakerMin 99 -Quiet | Out-Null
    $fj = Read-CareJob $fid
    $stepEv = @(Events | Where-Object { $_.job -eq $fid -and $_.type -eq 'step.fail' })
    $qEv = @(Events | Where-Object { $_.job -eq $fid -and $_.type -eq 'job.quarantined' })
    Check 'every failure has a plain sentence' ($fj.status -eq 'quarantined' -and $fj.failure.text -match '^Something failed that the Yard does not recognise at step 1 of 1 \(demo\); next: it needs a look \(See why has the detail\), then Retry or Close\.$' -and $fj.failure.text -notmatch 'exit 1' -and $fj.failure.detail -match 'exit 1: fail: something is broken' -and $stepEv.Count -and $stepEv[-1].say -eq $fj.failure.text -and $qEv.Count -and $qEv[-1].class -eq 'real' -and @($fj.history)[-1].say) { $fj.failure | ConvertTo-Json -Compress }
    $killed = @(Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable } | Where-Object status -eq 'killed')
    Check 'every failure has a plain sentence: a stopped order too' ($killed.Count -ge 1 -and @($killed | Where-Object { $_.failure.class -ne 'stopped' -or $_.failure.text -notmatch '^It was stopped by hand' }).Count -eq 0)
    Put-Job 'J90' @{ history = @(@{ step = 0; attempt = 1; outcome = 'crash'; detail = 'worker died without an exit code; its log is empty'; at = (Iso $now.AddHours(-30)) }); stateAt = (Iso $now.AddHours(-30)) }
    $null = Doctor
    Check 'every failure has a plain sentence: an older order gets its words from the doctor' ((Read-CareJob J90).failure.class -eq 'flaky' -and (Read-CareJob J90).failure.text -match '^The worker stopped without an exit code')

    # ---- a 3-day-old quarantined order cleared as stale and reopenable; -FindOnly clears nothing ----
    Put-Job 'J91' @{ stateAt = (Iso $now.AddDays(-4)); history = @(@{ step = 0; attempt = 0; outcome = 'fail'; detail = 'exit 1: tests: FAILED: Test-X'; at = (Iso $now.AddDays(-4)) }) }
    Put-Job 'J92' @{ status = 'killed'; stateAt = (Iso $now.AddDays(-2)) }   # (2 days: not yet)
    $before = Get-Content (Join-Path $root 'jobs\J91.json') -Raw
    $fo = Doctor -FindOnly
    Check '-FindOnly clears nothing' ((Get-Content (Join-Path $root 'jobs\J91.json') -Raw) -eq $before -and (Read-CareJob J91).status -eq 'quarantined' -and $fo.findOnly -and [int]$fo.care.cleared -ge 1 -and @($fo.care.items) -match '^J91 stale: no human action for 4 days' -and -not @(Events | Where-Object { $_.type -eq 'job.cleared' -and $_.job -eq 'J91' }).Count) { $fo.care | ConvertTo-Json -Compress }
    $dr = Doctor
    $j91 = Read-CareJob J91; $ce = @(Events | Where-Object { $_.type -eq 'job.cleared' -and $_.job -eq 'J91' })
    $ro = & $k reopen -Id J91 | Out-String
    $j91b = Read-CareJob J91
    Check 'a 3-day-old quarantined order cleared as stale and reopenable' ($j91.status -eq 'closed' -and $j91.cleared.state -eq 'stale' -and $j91.cleared.reason -match 'no human action for 4 days' -and $j91.cleared.at -and $j91.cleared.from -eq 'quarantined' -and $ce.Count -eq 1 -and $ce[0].state -eq 'stale' -and $ro -match 'reopened J91 as quarantined' -and $j91b.status -eq 'quarantined' -and -not $j91b.cleared -and @($j91b.clearedBefore).Count -eq 1 -and @(Events | Where-Object { $_.type -eq 'job.reopened' -and $_.job -eq 'J91' }).Count -eq 1) { "doctor: $($dr.care | ConvertTo-Json -Compress)"; "reopen: $ro" }
    Check 'stale: a 2-day-old stopped order is left alone (a working state until 3 days)' ((Read-CareJob J92).status -eq 'killed' -and -not (Read-CareJob J92).cleared)
    $null = Doctor
    Check 'stale: a reopened order starts its 3 days again' ((Read-CareJob J91).status -eq 'quarantined')
    Check 'reopen refuses an order that was never cleared' ((& $k reopen -Id J92 | Out-String) -match 'never cleared')

    # ---- each cleared state written with reason ----
    Put-Job 'J93' @{ stateAt = (Iso $now.AddHours(-1)) }
    $null = & $k close -Id J93 -Why 'dropped: the idea is no longer wanted'
    Put-Job 'J94' @{ stateAt = (Iso $now.AddHours(-1)) }
    $null = & $k close -Id J94 -ReplacedBy J93 -Why 'done in J93 instead'
    Put-Job 'J95' @{ stateAt = (Iso $now.AddHours(-1)) }
    $null = & $k close -Id J95 -Proof 'https://github.com/example/repo/pull/7' -Why 'merged by hand'
    # duplicate: two set-aside orders with the same goal, the older one is the duplicate (the doctor); open twin: J97 of pending J98
    Put-Job 'J96' @{ recipe = 'care'; vars = @{ goal = 'teach the doctor a new trick' }; stateAt = (Iso $now.AddHours(-1)) }
    Put-Job 'J97' @{ recipe = 'care'; vars = @{ goal = 'Teach the doctor a NEW trick.' }; stateAt = (Iso $now.AddHours(-1)) }
    Put-Job 'J98' @{ recipe = 'care'; vars = @{ goal = 'teach the doctor a new trick' }; status = 'pending' }
    # superseded by a handed-over order with the same goal
    Put-Job 'J99' @{ recipe = 'care'; vars = @{ goal = 'one more thing' }; stateAt = (Iso $now.AddHours(-1)) }
    Put-Job 'J100' @{ recipe = 'care'; vars = @{ goal = 'one more thing' }; status = 'done' }
    # retried: a recipe order made again on fresh main (requeue -Recook)
    Put-Job 'J101' @{ recipe = 'care'; name = 'care: retry me'; vars = @{ goal = 'retry me on fresh main'; repo = $root }; stateAt = (Iso $now.AddHours(-1)) }
    $rq = & $k requeue -Id J101 -Recook | Out-String
    $null = Doctor
    $want = [ordered]@{ J93 = @('dropped', '', 'no longer wanted'); J94 = @('superseded', 'J93', 'done in J93'); J95 = @('superseded', 'https://github.com/example/repo/pull/7', 'merged by hand')
        J96 = @('duplicate', 'J98', 'open as J98'); J97 = @('duplicate', 'J98', 'open as J98'); J99 = @('superseded', 'J100', 'handed over as J100'); J101 = @('retried', '', 'fresh main') }
    $bad = @(foreach ($id in $want.Keys) {
            $x = Read-CareJob $id; $e = @(Events | Where-Object { $_.type -eq 'job.cleared' -and $_.job -eq $id })
            $byOk = if ($want[$id][1]) { $x.cleared.by -eq $want[$id][1] } else { $true }
            if ($x.status -ne 'closed' -or $x.cleared.state -ne $want[$id][0] -or $x.cleared.reason -notmatch $want[$id][2] -or -not $x.cleared.at -or -not $byOk -or $e.Count -ne 1 -or $e[0].state -ne $want[$id][0] -or -not $e[0].reason) { "$id $($x.status) $($x.cleared | ConvertTo-Json -Compress) events $($e.Count)" }
        })
    $newId = [regex]::Match($rq, 're-cooked recipe care as (J\d+)').Groups[1].Value
    Check "each cleared state written with reason ($($bad -join ' | '))" ($bad.Count -eq 0 -and $newId -and (Read-CareJob J101).cleared.by -eq $newId -and (Read-CareJob $newId).retryOf -eq 'J101') { "requeue: $rq" }
    Check 'cleared: an open twin stays open' ((Read-CareJob J98).status -eq 'pending' -and -not (Read-CareJob J98).cleared)
    Check 'cleared: one cleared state only (a second doctor run does not clear again)' (@(Events | Where-Object { $_.type -eq 'job.cleared' -and $_.job -eq 'J96' }).Count -eq 1)

    # ---- the policy's one action, once, for a fresh failure: flaky with a freshen step behind it goes back to freshen ----
    $steps = @(@{ script = (Join-Path $kd 'stations\worktree.ps1'); args = @{} }, @{ script = (Join-Path $kd 'stations\freshen.ps1'); args = @{} }, @{ script = $w; args = @{ Behavior = 'fail' }; retries = 0; timeoutSec = 60; maxMB = 400 })
    Put-Job 'J102' @{ steps = $steps; cursor = 2; history = @(@{ step = 2; attempt = 0; outcome = 'timeout'; detail = 'ran 61s (limit 60s)'; at = (Iso $now.AddMinutes(-20)) }); stateAt = (Iso $now.AddMinutes(-20)) }
    Put-Job 'J103' @{ steps = $steps; cursor = 2; history = @(@{ step = 2; attempt = 0; outcome = 'fail'; detail = 'exit 1: tests: FAILED: Test-Y'; at = (Iso $now.AddMinutes(-20)) }); stateAt = (Iso $now.AddMinutes(-20)) }
    $null = & $k kill -All   # (J98 must not start)
    $null = Doctor
    $j102 = Read-CareJob J102
    Check 'care action: a fresh flaky failure is retried once from its freshen step (on fresh main)' ($j102.status -eq 'pending' -and $j102.cursor -eq 1 -and $j102.care.action -eq 'retry' -and @(Events | Where-Object { $_.type -eq 'job.care' -and $_.job -eq 'J102' }).Count -eq 1) { $j102 | ConvertTo-Json -Depth 4 -Compress }
    Check 'care action: a real failure is never retried by itself (stop and say why)' ((Read-CareJob J103).status -eq 'quarantined' -and -not (Read-CareJob J103).care)

    # ---- stale reason names the files main changed since the brief was written (one git log per repo) ----
    $repo = Join-Path $root 'repo'; New-Item -ItemType Directory -Force -Path "$repo\kitchen" | Out-Null
    & git -C $repo init -q -b main 2>&1 | Out-Null
    Set-Content "$repo\kitchen\a.ps1" '1'; & git -C $repo add -A 2>&1 | Out-Null
    $env:GIT_COMMITTER_DATE = (Iso $now.AddDays(-6)); $env:GIT_AUTHOR_DATE = $env:GIT_COMMITTER_DATE
    & git -C $repo -c user.name=t -c user.email=t@example.invalid commit -q -m one 2>&1 | Out-Null
    Set-Content "$repo\kitchen\a.ps1" '2'; & git -C $repo add -A 2>&1 | Out-Null
    $env:GIT_COMMITTER_DATE = (Iso $now.AddDays(-4)); $env:GIT_AUTHOR_DATE = $env:GIT_COMMITTER_DATE
    & git -C $repo -c user.name=t -c user.email=t@example.invalid commit -q -m two 2>&1 | Out-Null
    $env:GIT_COMMITTER_DATE = $null; $env:GIT_AUTHOR_DATE = $null
    Put-Job 'J104' @{ status = 'killed'; recipe = 'care'; vars = @{ goal = 'change kitchen/a.ps1 to say hello'; repo = $repo }; stateAt = (Iso $now.AddDays(-3.5)) }
    $null = Doctor
    Check 'stale: the reason names the files main changed since the brief was written' ((Read-CareJob J104).cleared.state -eq 'stale' -and (Read-CareJob J104).cleared.reason -match '^its brief was written against kitchen/a\.ps1, which changed on main since; no human action for 3 days since it stopped') { (Read-CareJob J104).cleared | ConvertTo-Json -Compress }
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
Write-Output "Kitchen care tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
