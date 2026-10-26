# Tests for scripts/run-registry.ps1. Self-cleaning: temp folder removed and every child process it spawns is killed at the end.
$ErrorActionPreference = 'Stop'
$rr = Join-Path $PSScriptRoot '..\scripts\run-registry.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('rrt-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
$spawned = [Collections.Generic.List[int]]::new()
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function RR { $o = & pwsh -NoProfile -File $rr @args 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }
function Spawn { $p = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 300' -PassThru -WindowStyle Hidden; $spawned.Add($p.Id); $p }
function Alive($id) { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $env:BRAIN_RUNS = Join-Path $root 'sub\runs.jsonl'
    Remove-Item Env:BRAIN_AGENT_DEPTH -ErrorAction SilentlyContinue

    # register: required fields
    $p1 = Spawn
    $r = RR register -Name 'job one' -ProcessId $p1.Id -EndCondition 'tests finish' -MaxMinutes 30
    Check 'register ok' ($r.Code -eq 0); Check 'registry file created (BRAIN_RUNS honoured)' (Test-Path $env:BRAIN_RUNS)
    $rec = Get-Content $env:BRAIN_RUNS | Select-Object -First 1 | ConvertFrom-Json
    Check 'record fields' ($rec.name -eq 'job one' -and $rec.pid -eq $p1.Id -and $rec.endCondition -eq 'tests finish' -and $rec.maxMinutes -eq 30 -and $rec.start_ms -gt 0)
    $r = RR register -Name 'x' -ProcessId $p1.Id -EndCondition '' -MaxMinutes 5; Check 'empty EndCondition refused' ($r.Code -eq 2)
    $r = RR register -Name 'x' -ProcessId $p1.Id -EndCondition '   ' -MaxMinutes 5; Check 'blank EndCondition refused' ($r.Code -eq 2)
    $r = RR register -Name 'x' -ProcessId $p1.Id -MaxMinutes 5; Check 'missing EndCondition refused' ($r.Code -eq 2)
    $r = RR register -Name 'x' -ProcessId 999999 -EndCondition 'e' -MaxMinutes 5; Check 'nonexistent pid refused' ($r.Code -eq 2)
    $r = RR register -Name 'x' -ProcessId $p1.Id -EndCondition 'e' -MaxMinutes 0; Check 'MaxMinutes 0 refused' ($r.Code -eq 2)
    Check 'refusals wrote nothing' (@(Get-Content $env:BRAIN_RUNS).Count -eq 1)

    # list: alive
    $r = RR list; Check 'list alive' ($r.Code -eq 0 -and $r.Out -match 'job one' -and $r.Out -match 'alive')

    # dead: kill child then list
    $p2 = Spawn; $null = RR register -Name 'short lived' -ProcessId $p2.Id -EndCondition 'dies' -MaxMinutes 30
    Stop-Process -Id $p2.Id -Force; Start-Sleep -Milliseconds 800
    $r = RR list; Check 'list dead' ($r.Out -match 'short lived.*dead')

    # overdue: rewrite registered time into the past
    $p3 = Spawn; $null = RR register -Name 'slow one' -ProcessId $p3.Id -EndCondition 'never' -MaxMinutes 5
    $lines = @(Get-Content $env:BRAIN_RUNS)
    $new = foreach ($l in $lines) { $o = $l | ConvertFrom-Json; if ($o.name -eq 'slow one') { $o.registered_ms = $o.registered_ms - 3600000 }; $o | ConvertTo-Json -Compress }
    Set-Content $env:BRAIN_RUNS $new
    $r = RR list; Check 'list overdue' ($r.Out -match 'slow one.*overdue')
    Check 'healthy job not overdue' ($r.Out -notmatch 'job one.*overdue')

    # reap: report only by default
    $r = RR reap
    Check 'reap reports dead' ($r.Out -match 'short lived'); Check 'reap reports overdue' ($r.Out -match 'slow one'); Check 'reap does not list healthy' ($r.Out -notmatch 'job one')
    Check 'reap default kills nothing' ((Alive $p3.Id) -and (Alive $p1.Id))

    # unregistered process is never touched, even with -Kill
    $pu = Spawn
    $r = RR reap -Kill
    Check 'reap -Kill killed the overdue registered process' (-not (Alive $p3.Id))
    Check 'reap -Kill spared healthy registered process' (Alive $p1.Id)
    Check 'reap -Kill spared unregistered process' (Alive $pu.Id)

    # pid reuse guard: record points at a LIVE pid but with a different start time -> treated dead, never killed
    $victim = Spawn
    $fake = @{ name = 'reused'; pid = $victim.Id; start_ms = 1000; registered_ms = 1000; endCondition = 'x'; maxMinutes = 1; depth = 0 } | ConvertTo-Json -Compress
    Add-Content $env:BRAIN_RUNS $fake
    $r = RR list; Check 'pid reuse shown as dead' ($r.Out -match 'reused.*dead')
    $r = RR reap -Kill
    Check 'pid reuse: victim not killed' (Alive $victim.Id)

    # malformed registry lines: reported, not fatal
    Add-Content $env:BRAIN_RUNS 'this is not json {'
    $r = RR list; Check 'malformed line tolerated' ($r.Code -eq 0 -and $r.Out -match '(?i)malformed')

    # depth cap
    $r = RR depth; Check 'depth default 0' ($r.Code -eq 0 -and $r.Out -match '0')
    $env:BRAIN_AGENT_DEPTH = '1'; $r = RR depth -Check; Check 'depth 1 allowed' ($r.Code -eq 0)
    $env:BRAIN_AGENT_DEPTH = '2'; $r = RR depth -Check; Check 'depth 2 exit 3' ($r.Code -eq 3)
    $env:BRAIN_AGENT_DEPTH = '5'; $r = RR depth -Check; Check 'depth 5 exit 3' ($r.Code -eq 3)
    $before = @(Get-Content $env:BRAIN_RUNS).Count
    $env:BRAIN_AGENT_DEPTH = '2'; $r = RR register -Name 'deep' -ProcessId $p1.Id -EndCondition 'e' -MaxMinutes 5
    Check 'register refused at depth 2' ($r.Code -eq 3); Check 'register at depth 2 wrote nothing' (@(Get-Content $env:BRAIN_RUNS).Count -eq $before)
    $env:BRAIN_AGENT_DEPTH = 'banana'; $r = RR depth -Check; Check 'garbage depth fails closed (exit 3)' ($r.Code -eq 3)
    $env:BRAIN_AGENT_DEPTH = '1'; $r = RR register -Name 'depth one ok' -ProcessId $p1.Id -EndCondition 'e' -MaxMinutes 5; Check 'register ok at depth 1' ($r.Code -eq 0)
    Remove-Item Env:BRAIN_AGENT_DEPTH

    # parallel registers do not corrupt the file
    $jobs = 1..5 | % { $n = $_; Start-Job { $env:BRAIN_RUNS = $using:env:BRAIN_RUNS; pwsh -NoProfile -File $using:rr register -Name "par$using:n" -ProcessId $using:p1.Id -EndCondition e -MaxMinutes 5 | Out-Null } }
    $jobs | Wait-Job -Timeout 120 | Out-Null; $jobs | Remove-Job -Force
    $par = @(Get-Content $env:BRAIN_RUNS | ? { $_ -match '"par\d"' })
    Check 'parallel registers all landed intact' ($par.Count -eq 5 -and @($par | % { $_ | ConvertFrom-Json }).Count -eq 5)

    # FROZEN per ORG.md: header and README say so (no new features)
    Check 'FROZEN note in run-registry.ps1 header' (@(Get-Content $rr -TotalCount 12) -cmatch 'FROZEN')
    Check 'FROZEN note in README row for run-registry.ps1' ((Get-Content (Join-Path $PSScriptRoot '..\README.md') -Raw) -match '(?m)^\|[^\n]*run-registry\.ps1[^\n]*FROZEN')
    # depth cap is advisory: nothing sets BRAIN_AGENT_DEPTH; header and README say it only works if the launching agent sets it
    Check 'depth caveat in run-registry header' (@(Get-Content $rr -TotalCount 12) -match 'only works if the launching agent sets BRAIN_AGENT_DEPTH')
    Check 'depth caveat in README' ((Get-Content (Join-Path $PSScriptRoot '..\README.md') -Raw) -match 'only works if the launching agent sets BRAIN_AGENT_DEPTH')
    $env:BRAIN_RUNS = Join-Path $root 'sub\runs.jsonl'; Remove-Item Env:BRAIN_AGENT_DEPTH -ErrorAction SilentlyContinue
    $r = RR depth -Check; Check 'unset depth: reported as 0 and flagged as not set (cap inert)' ($r.Code -eq 0 -and $r.Out -match 'BRAIN_AGENT_DEPTH=0' -and $r.Out -match '(?i)not set')
    $r = RR register -Name 'unset depth ok' -ProcessId $p1.Id -EndCondition 'e' -MaxMinutes 5; Check 'unset depth: register allowed (documented limitation)' ($r.Code -eq 0)

    # empty registry lists cleanly
    $env:BRAIN_RUNS = Join-Path $root 'empty.jsonl'; $r = RR list; Check 'empty list ok' ($r.Code -eq 0 -and $r.Out -match '(?i)no registered')
    Check 'no network / Invoke-Expression in script' (-not (Select-String -Path $rr -Pattern 'Invoke-Expression|\biex\b|Invoke-WebRequest|Invoke-RestMethod' -Quiet))
} finally {
    foreach ($id in $spawned) { if (Alive $id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }
    Remove-Item Env:BRAIN_RUNS, Env:BRAIN_AGENT_DEPTH -ErrorAction SilentlyContinue
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
}
Write-Host "RunRegistry tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
