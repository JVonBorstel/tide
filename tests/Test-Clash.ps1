# Tests for kitchen/clash.ps1 (the clash rule in the supervisor's start loop): orders naming the same file never build at once.
# Drives kitchen/kitchen.ps1 add/tick/watch/kill/requeue against a private kitchen root under TEMP with a fake build cook; self-cleaning.
$ErrorActionPreference = 'Stop'
$k = Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-clash-' + [guid]::NewGuid().ToString('N'))
$env:BRAIN_KITCHEN = $root; $env:KITCHEN_UNDER_TEST = '1'; $env:KITCHEN_AGY_EXE = 'off'; $env:BRAIN_NTFY_TOPIC = $null; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Job($id) { Get-Content (Join-Path $root "jobs\$id.json") -Raw | ConvertFrom-Json }
function LastWhy($id) { $h = @((Job $id).history); if ($h.Count) { [string]$h[-1].detail } else { '' } }
# the build step is found by its file name (agent-step.ps1) and Role 'do'; this fake one only sleeps, so no cook is ever called
$fakeDir = Join-Path $root 'fake'; New-Item -ItemType Directory -Force -Path $fakeDir | Out-Null
$agent = Join-Path $fakeDir 'agent-step.ps1'
Set-Content -LiteralPath $agent -Value "param([string]`$Role = 'do', [int]`$Seconds = 1, [int]`$Code = 0)`nStart-Sleep -Seconds `$Seconds; Write-Output `"fake build `$Role exit `$Code`"; exit `$Code" -Encoding utf8
function Order([string]$name, [string]$goal, [int]$sec = 1, [int]$code = 0) {
    $spec = Join-Path $fakeDir "$name.json"
    @{ name = $name; vars = @{ goal = $goal }; steps = @(@{ script = $agent; args = @{ Role = 'do'; Seconds = $sec; Code = $code }; timeoutSec = 30; retries = 0; hungSec = 0 }) } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $spec -Encoding utf8
    & $k add -SpecPath $spec | Out-String
}
$tickArgs = @{ MaxConcurrent = 10; BreakerMin = 99 }
try {
    Order 'menu' 'Fix the menu in pass-app/public/app.js.' 6 | Out-Null          # J1
    Order 'polish' 'Polish pass-app/public/app.js and kitchen/x.ps1' | Out-Null   # J2
    Order 'other' 'Only kitchen/other.ps1 changes' | Out-Null                       # J3
    Order 'vague' 'make Chef nicer to read' | Out-Null                              # J4
    Order 'plan-a' 'Write docs/plan.md' 3 | Out-Null                                # J5
    Order 'plan-b' 'Extend docs/plan.md' | Out-Null                                 # J6
    $out = & $k tick @tickArgs | Out-String
    $want = 'WAIT: J2 shares pass-app/public/app.js with running J1; starts when J1 finishes'
    Check 'overlap waits with the reason' ((Job J1).status -eq 'running' -and (Job J2).status -eq 'pending' -and -not (Job J2).run -and (LastWhy J2) -eq $want -and $out.Contains($want) -and
        (Get-Content (Join-Path $root 'events.jsonl') -Raw) -match '"type":"step.wait"[^\n]*"kind":"clash"')
    Check 'no overlap starts' ((Job J3).status -in 'running', 'done')
    Check 'no-file goal never waits' ((Job J4).status -in 'running', 'done')
    Check 'oldest wins in the same tick' ((Job J5).status -eq 'running' -and (Job J6).status -eq 'pending' -and (LastWhy J6) -like 'WAIT: J6 shares docs/plan.md with running J5*')
    $o2 = & $k tick @tickArgs | Out-String
    Check 'the wait reason is recorded once, not every tick' (@((Job J2).history).Count -eq 1 -and $o2.Contains($want))

    # an older order still in line (a cook wait put it off) goes before a younger one naming the same file
    Order 'old' 'Tidy docs/old.md' | Out-Null      # J7
    $p7 = Join-Path $root 'jobs\J7.json'; $j7 = Get-Content $p7 -Raw | ConvertFrom-Json -AsHashtable
    $j7.notBefore = [DateTime]::UtcNow.AddHours(1).ToString('o'); $j7 | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $p7 -Encoding utf8
    Order 'young' 'Also docs/old.md' | Out-Null    # J8
    & $k tick @tickArgs -Quiet | Out-Null
    Check 'oldest wins over a younger order' ((Job J7).status -eq 'pending' -and (Job J8).status -eq 'pending' -and (LastWhy J8) -eq 'WAIT: J8 shares docs/old.md with older queued J7; starts when J7 finishes')
    & $k kill -Id J7 | Out-Null

    Order 'broken' 'Rewrite docs/q.md' 0 1 | Out-Null   # J9: its build fails with no retries -> quarantined
    & $k watch -Seconds 60 @tickArgs -Quiet | Out-Null
    Check 'finished order does not block' ((Job J1).status -eq 'done' -and (Job J2).status -eq 'done' -and (Job J6).status -eq 'done')
    Check 'killed order does not block' ((Job J8).status -eq 'done')
    Order 'after' 'Fix docs/q.md properly' 6 | Out-Null  # J10
    & $k tick @tickArgs -Quiet | Out-Null
    Check 'quarantined order does not block' ((Job J9).status -eq 'quarantined' -and (Job J10).status -eq 'running')
    # requeued, J9 is checked again although it had reached its build step before: it waits for the build now running on the same file
    & $k requeue -Id J9 | Out-Null
    & $k tick @tickArgs -Quiet | Out-Null
    Check 'requeued order is still subject to it' ((Job J9).status -eq 'pending' -and (LastWhy J9) -eq 'WAIT: J9 shares docs/q.md with running J10; starts when J10 finishes')
} finally {
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } | ForEach-Object { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null }
    $env:BRAIN_KITCHEN = $null; $env:KITCHEN_UNDER_TEST = $null; $env:KITCHEN_AGY_EXE = $null
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}
# shared reference docs and wildcard examples never count (10-22: 'Follow kitchen/CREED.md' made every order wait on every older one)
$gf = & { . (Join-Path $PSScriptRoot '..\kitchen\clash.ps1'); Get-GoalFiles 'Edit kitchen/stations/x.ps1. Follow kitchen/CREED.md and kitchen/STANDARDS.md; see kitchen/*.ps1 and AGENTS.md' }
Check 'clash: CREED.md, STANDARDS.md and wildcard paths are ignored; real files still count' (@($gf).Count -eq 1 -and @($gf)[0] -eq 'kitchen/stations/x.ps1')
Write-Host "Clash tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
