# Tests for the Watch's meta-check (kitchen/watch.ps1: heartbeats, the tick, scheduled task results, GitHub sign-in, backups, the mode)
# and the memory lobe (scripts/memory-truth.ps1: the index, frontmatter, named paths, mode claims, short-term file ages). Fakes only:
# a scratch kitchen, fake task results (KITCHEN_WATCH_TASKS), a fake gh, a scratch memory folder and brain. No AI. Self-cleaning (TEMP).
$ErrorActionPreference = 'Stop'
$watch = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\watch.ps1')).Path
$truth = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\memory-truth.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-watch-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Put([string]$path, [string]$text) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null; Set-Content -LiteralPath $path -Value $text -Encoding utf8 }
function Iso([double]$minAgo) { [DateTime]::UtcNow.AddMinutes(-$minAgo).ToString('o') }
function Run([string]$file, [string[]]$more) { $o = & pwsh -NoProfile -File $file @more 2>&1 | Out-String; [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE; J = $(try { ($o.Trim() -split "`r?`n")[-1] | ConvertFrom-Json } catch { $null }) } }
$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_WATCH_TASKS', 'KITCHEN_WATCH_GH', 'KITCHEN_WATCH_BACKUP_DEST') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
try {
    $kr = Join-Path $root 'kitchen'; New-Item -ItemType Directory -Force -Path $kr | Out-Null
    $env:BRAIN_KITCHEN = $kr
    # a healthy kitchen: fresh tick, fresh heartbeats, tasks ok, gh ok, both backups fresh, push on
    Put (Join-Path $kr 'supervisor.json') (@{ lastTick = (Iso 1) } | ConvertTo-Json)
    Put (Join-Path $kr 'watch\ledger.json') (@{ name = 'ledger'; lastRun = (Iso 3); everyMin = 5; checked = 10; found = 0 } | ConvertTo-Json)
    Put (Join-Path $kr 'push-on') 'on'; Put (Join-Path $kr 'LIVE') 'x'
    New-Item -ItemType Directory -Force -Path (Join-Path $kr ("backups\{0:yyyyMMdd}" -f (Get-Date))) | Out-Null
    $off = Join-Path $root 'offsite'; New-Item -ItemType Directory -Force -Path (Join-Path $off 'today') | Out-Null; $env:KITCHEN_WATCH_BACKUP_DEST = $off
    $env:KITCHEN_WATCH_TASKS = '[{"name":"Kitchen-Supervisor","result":0,"state":"Ready"},{"name":"Kitchen-Pass","result":267009,"state":"Running"}]'
    $ghOk = Join-Path $root 'gh-ok.cmd'; Set-Content $ghOk '@echo Logged in to github.com& exit /b 0' -Encoding ascii
    $ghBad = Join-Path $root 'gh-bad.cmd'; Set-Content $ghBad '@echo X Failed to log in: token expired& exit /b 1' -Encoding ascii
    $env:KITCHEN_WATCH_GH = $ghOk

    # ---- watch.ps1 ----------------------------------------------------------------------------------------------------------------
    $r = Run $watch @('-Json')
    Check 'healthy kitchen: exit 0, no problems' ($r.Code -eq 0 -and $r.J.ok -and @($r.J.problems).Count -eq 0)
    Check 'the mode is stated plainly' ($r.J.mode -match 'live' -and $r.J.mode -match 'phone alerts on')
    $hb = Get-Content (Join-Path $kr 'watch\watch.json') -Raw | ConvertFrom-Json
    Check 'the watch writes its own heartbeat' ($hb.name -eq 'watch' -and $hb.lastRun -and $hb.checked -ge 5)
    Put (Join-Path $kr 'watch\ledger.json') (@{ name = 'ledger'; lastRun = (Iso 40); everyMin = 5 } | ConvertTo-Json)
    $r = Run $watch @('-Json')
    Check 'a late heartbeat (40 min, every 5) is a problem, exit 3' ($r.Code -eq 3 -and @($r.J.problems | Where-Object { $_.what -eq 'heartbeat:ledger' -and $_.say -match '40 minutes' }).Count -eq 1)
    Put (Join-Path $kr 'watch\ledger.json') (@{ name = 'ledger'; lastRun = (Iso 3); everyMin = 5; error = 'git failed' } | ConvertTo-Json)
    Check 'a heartbeat that reports an error is a problem' (@((Run $watch @('-Json')).J.problems | Where-Object { $_.say -match 'failed last time: git failed' }).Count -eq 1)
    Put (Join-Path $kr 'watch\ledger.json') '{ broken'
    Check 'a damaged heartbeat is a problem (never read as fine)' (@((Run $watch @('-Json')).J.problems | Where-Object { $_.say -match 'damaged' }).Count -eq 1)
    Put (Join-Path $kr 'watch\ledger.json') (@{ name = 'ledger'; lastRun = (Iso 3); everyMin = 5 } | ConvertTo-Json)
    Put (Join-Path $kr 'supervisor.json') (@{ lastTick = (Iso 30) } | ConvertTo-Json)
    Check 'a stale tick (30 min) is a problem' (@((Run $watch @('-Json')).J.problems | Where-Object { $_.what -eq 'tick' }).Count -eq 1)
    Put (Join-Path $kr 'PAUSED') 'Jordan'
    $r = Run $watch @('-Json')
    Check 'paused by Jordan: a stale tick is not a problem, and the mode says paused' (-not @($r.J.problems | Where-Object { $_.what -eq 'tick' }).Count -and $r.J.mode -match 'PAUSED')
    # TD-EH-26: paused, the watchers keep running: the paused Walkround (lastTickEnd) and the heartbeats marked whilePaused (memory-truth,
    # the Watch) must stay on time; a heartbeat of paused work (the ledger) and the held off-drive copy are not faults, and the report says paused
    Put (Join-Path $kr 'supervisor.json') (@{ lastTick = (Iso 30); lastTickEnd = (Iso 1) } | ConvertTo-Json)
    Put (Join-Path $kr 'watch\memory.json') (@{ name = 'memory'; lastRun = (Iso 300); everyMin = 60; whilePaused = $true } | ConvertTo-Json)
    Put (Join-Path $kr 'watch\ledger.json') (@{ name = 'ledger'; lastRun = (Iso 40); everyMin = 5 } | ConvertTo-Json)
    (Get-Item (Join-Path $off 'today')).LastWriteTime = (Get-Date).AddDays(-5)
    $r = Run $watch @('-Json')
    Check 'TD-EH-26: paused: a late whilePaused heartbeat (memory) is still a problem; a late heartbeat of paused work (ledger) is not' (@($r.J.problems | Where-Object { $_.what -eq 'heartbeat:memory' -and $_.say -match '300 minutes' }).Count -eq 1 -and -not @($r.J.problems | Where-Object { $_.what -eq 'heartbeat:ledger' }).Count)
    Check 'TD-EH-26: paused: a fresh paused Walkround is no problem, and the report says paused' (-not @($r.J.problems | Where-Object { $_.what -eq 'tick' }).Count -and $r.J.paused -eq $true -and $r.J.mode -match 'watchers are still watched')
    Check 'TD-EH-26: paused: the held off-drive copy is a note, not a fault' (-not @($r.J.problems | Where-Object { $_.what -eq 'offsite-backup' }).Count -and @($r.J.notes | Where-Object { $_ -match 'off-drive copy waits for resume' }).Count -eq 1)
    $whb = Get-Content (Join-Path $kr 'watch\watch.json') -Raw | ConvertFrom-Json
    Check 'TD-EH-26: the Watch heartbeat is marked whilePaused and says paused' ($whb.whilePaused -eq $true -and $whb.paused -eq $true)
    Put (Join-Path $kr 'supervisor.json') (@{ lastTick = (Iso 30); lastTickEnd = (Iso 30) } | ConvertTo-Json)
    $r = Run $watch @('-Json')
    Check 'TD-EH-26: paused: a paused Walkround silent for 30 min is a problem' (@($r.J.problems | Where-Object { $_.what -eq 'tick' -and $_.say -match 'paused Walkround' -and $_.say -match '30 minutes' }).Count -eq 1)
    Remove-Item (Join-Path $kr 'watch\memory.json'); Put (Join-Path $kr 'watch\ledger.json') (@{ name = 'ledger'; lastRun = (Iso 3); everyMin = 5 } | ConvertTo-Json)
    (Get-Item (Join-Path $off 'today')).LastWriteTime = Get-Date
    Remove-Item (Join-Path $kr 'PAUSED'); Put (Join-Path $kr 'supervisor.json') (@{ lastTick = (Iso 1) } | ConvertTo-Json)
    $env:KITCHEN_WATCH_TASKS = '[{"name":"Kitchen-Supervisor","result":2147942402,"state":"Ready"},{"name":"Kitchen-Pass","result":0,"state":"Disabled"}]'
    $r = Run $watch @('-Json')
    Check 'a scheduled task with an error code is a problem (in hex, as Windows shows it)' (@($r.J.problems | Where-Object { $_.what -eq 'task:Kitchen-Supervisor' -and $_.say -match '0x80070002' }).Count -eq 1)
    Check 'a disabled task is a problem for Jordan' (@($r.J.problems | Where-Object { $_.what -eq 'task:Kitchen-Pass' -and $_.owner -eq 'Jordan' }).Count -eq 1)
    # new task names (scripts/task-names.json; the real tasks are renamed at S4): checked the same way, and old + new together is a problem
    $env:KITCHEN_WATCH_TASKS = '[{"name":"Tide-Yard","result":2147942402,"state":"Ready"},{"name":"Tide-Board","result":0,"state":"Disabled"},{"name":"Tide-Cleanup","result":0,"state":"Ready"}]'
    $r = Run $watch @('-Json')
    Check 'new names: a Tide-Yard error code and a disabled Tide-Board are problems, a healthy Tide-Cleanup is not' (@($r.J.problems | Where-Object { $_.what -eq 'task:Tide-Yard' -and $_.say -match '0x80070002' }).Count -eq 1 -and @($r.J.problems | Where-Object { $_.what -eq 'task:Tide-Board' -and $_.owner -eq 'Jordan' }).Count -eq 1 -and -not @($r.J.problems | Where-Object { $_.what -eq 'task:Tide-Cleanup' }).Count)
    $env:KITCHEN_WATCH_TASKS = '[{"name":"Kitchen-Supervisor","result":0,"state":"Ready"},{"name":"Tide-Yard","result":0,"state":"Ready"},{"name":"Kitchen-Pass","result":0,"state":"Ready"}]'
    $r = Run $watch @('-Json')
    Check 'old and new name of one task both registered: one problem for Jordan (it would tick twice); a lone old name is fine' (@($r.J.problems | Where-Object { $_.what -eq 'task:Kitchen-Supervisor+Tide-Yard' -and $_.owner -eq 'Jordan' -and $_.say -match 'runs twice' }).Count -eq 1 -and -not @($r.J.problems | Where-Object { $_.what -match 'Kitchen-Pass' }).Count)
    $wsrc = Get-Content -LiteralPath $watch -Raw
    Check 'watch.ps1 reads the new names from scripts/task-names.json next to Kitchen-* and Rig-*' ($wsrc -match [regex]::Escape("'scripts\task-names.json'") -and $wsrc -match [regex]::Escape("Get-ScheduledTask -TaskName 'Kitchen-*', 'Rig-*' -ErrorAction Stop") -and $wsrc -match [regex]::Escape('foreach ($n in $newNames) { Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue }'))
    $env:KITCHEN_WATCH_TASKS = '[{"name":"Kitchen-Supervisor","result":0,"state":"Ready"}]'
    $env:KITCHEN_WATCH_GH = $ghBad
    Check 'GitHub sign-in failing is a problem for Jordan' (@((Run $watch @('-Json')).J.problems | Where-Object { $_.what -eq 'github' -and $_.owner -eq 'Jordan' -and $_.say -match 'expired' }).Count -eq 1)
    $env:KITCHEN_WATCH_GH = 'no-such-gh-command-xyz'
    Check 'gh missing is a problem' (@((Run $watch @('-Json')).J.problems | Where-Object { $_.what -eq 'github' -and $_.say -match 'not installed' }).Count -eq 1)
    $env:KITCHEN_WATCH_GH = $ghOk
    Remove-Item (Join-Path $kr 'backups') -Recurse -Force; New-Item -ItemType Directory -Force -Path (Join-Path $kr 'backups\20200101') | Out-Null
    Check 'an old in-kitchen backup is a problem' (@((Run $watch @('-Json')).J.problems | Where-Object { $_.what -eq 'backup' -and $_.say -match '20200101' }).Count -eq 1)
    New-Item -ItemType Directory -Force -Path (Join-Path $kr ("backups\{0:yyyyMMdd}" -f (Get-Date))) | Out-Null
    $env:KITCHEN_WATCH_BACKUP_DEST = Join-Path $root 'no-such-drive'
    Check 'a missing off-drive backup folder is a problem for Jordan' (@((Run $watch @('-Json')).J.problems | Where-Object { $_.what -eq 'offsite-backup' -and $_.owner -eq 'Jordan' }).Count -eq 1)
    $env:KITCHEN_WATCH_BACKUP_DEST = $off
    Remove-Item (Join-Path $kr 'push-on')
    $r = Run $watch @('-Json')
    Check 'phone alerts off is a problem for Jordan, and the mode says OFF' (@($r.J.problems | Where-Object { $_.what -eq 'push-off' -and $_.owner -eq 'Jordan' }).Count -eq 1 -and $r.J.mode -match 'phone alerts OFF')
    Check 'text output: one line per problem with its owner' ((Run $watch @()).Out -match '\[Jordan\] Phone alerts are off')

    # ---- memory-truth.ps1 -----------------------------------------------------------------------------------------------------------
    $mem = Join-Path $root 'memory'; $brain = Join-Path $root 'brain'
    Put (Join-Path $brain 'memory\NOW.md') 'now'; Put (Join-Path $brain 'memory\BOOT.md') 'boot'
    $fm = { param($n) "---`nname: $n`ndescription: about $n`nmetadata:`n  type: project`n---`n" }
    Put (Join-Path $mem 'a.md') ((& $fm 'a') + "Worktrees live in $root (exists).")
    Put (Join-Path $mem 'b.md') ((& $fm 'b') + "Template: C:\Users\x\wt\gw-w<N> is not a claim.")
    Put (Join-Path $mem 'MEMORY.md') "- [A](a.md) - a`n- [B](b.md) - b"
    $r = Run $truth @('-MemoryDir', $mem, '-BrainPath', $brain, '-Json')
    Check 'memory true: exit 0' ($r.Code -eq 0 -and $r.J.ok)
    Check 'memory: heartbeat written' ((Get-Content (Join-Path $kr 'watch\memory.json') -Raw | ConvertFrom-Json).name -eq 'memory')
    Check 'TD-EH-26: the memory heartbeat is marked whilePaused (it keeps running while the Yard is paused)' ((Get-Content (Join-Path $kr 'watch\memory.json') -Raw | ConvertFrom-Json).whilePaused -eq $true)
    Put (Join-Path $mem 'c.md') ((& $fm 'c') + 'not in the index')
    Put (Join-Path $mem 'MEMORY.md') "- [A](a.md) - a`n- [B](b.md) - b`n- [Gone](gone.md) - x"
    $r = Run $truth @('-MemoryDir', $mem, '-BrainPath', $brain, '-Json')
    Check 'memory: an index link to a missing file is drift' ($r.Code -eq 3 -and @($r.J.findings | Where-Object { $_.say -match 'gone\.md' }).Count -eq 1)
    Check 'memory: a file missing from the index is drift' (@($r.J.findings | Where-Object { $_.file -eq 'c.md' -and $_.say -match 'not in the index' }).Count -eq 1)
    Put (Join-Path $mem 'MEMORY.md') "- [A](a.md) - a`n- [B](b.md) - b`n- [C](c.md) - c"
    Put (Join-Path $mem 'c.md') "no frontmatter. The kitchen is PAUSED (kitchen.ps1 pause). Data in C:\no\such\folder\here."
    $r = Run $truth @('-MemoryDir', $mem, '-BrainPath', $brain, '-Json')
    Check 'memory: no frontmatter is drift' (@($r.J.findings | Where-Object { $_.file -eq 'c.md' -and $_.say -match 'frontmatter' }).Count -eq 1)
    Check 'memory: a named path that does not exist is drift' (@($r.J.findings | Where-Object { $_.say -match 'C:\\no\\such\\folder\\here' }).Count -eq 1)
    Check 'memory: "kitchen is PAUSED" with no PAUSED file is drift' (@($r.J.findings | Where-Object { $_.say -match 'says the kitchen is paused' }).Count -eq 1)
    Check 'memory: a template path (gw-w<N>) is not drift' (-not @($r.J.findings | Where-Object { $_.say -match 'gw-w' }).Count)
    Put (Join-Path $kr 'PAUSED') 'Jordan'
    Check 'memory: "kitchen is PAUSED" while it is paused is true' (-not @((Run $truth @('-MemoryDir', $mem, '-BrainPath', $brain, '-Json')).J.findings | Where-Object { $_.say -match 'says the kitchen is paused' }).Count)
    Remove-Item (Join-Path $kr 'PAUSED')
    Put (Join-Path $mem 'c.md') ((& $fm 'c') + 'History: the kitchen was paused Oct 18-19.')
    Check 'memory: history ("was paused") is not a claim about now' (-not @((Run $truth @('-MemoryDir', $mem, '-BrainPath', $brain, '-Json')).J.findings | Where-Object { $_.say -match 'paused' }).Count)
    (Get-Item (Join-Path $brain 'memory\NOW.md')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-5)
    $r = Run $truth @('-MemoryDir', $mem, '-BrainPath', $brain, '-Json')
    Check 'memory: NOW.md 5 days old is drift' (@($r.J.findings | Where-Object { $_.file -eq 'NOW.md' -and $_.say -match '5 days' }).Count -eq 1)
    (Get-Item (Join-Path $brain 'memory\NOW.md')).LastWriteTimeUtc = [DateTime]::UtcNow
    $prog = Join-Path $root 'PROGRESS.md'; Put $prog 'build'; (Get-Item $prog).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-3)
    Put (Join-Path $mem 'MEMORY.md') "- ACTIVE BUILD (x): read $prog first`n- [A](a.md) - a`n- [B](b.md) - b`n- [C](c.md) - c"
    Check 'memory: a stale active-build file is drift' (@((Run $truth @('-MemoryDir', $mem, '-BrainPath', $brain, '-Json')).J.findings | Where-Object { $_.say -match 'active build file has not been updated' }).Count -eq 1)
    # proof-or-unknown lint: one fixture line per rule in a top-level memory file; WARN with file:line, never a finding, never exit 3
    Put $prog 'build'
    $lint = @('# facts', '- a number: 42 orders shipped', '- a date: merged on 2026-10-21', '- an id: J176 is done', '- no fact here at all',
        '- proof by path: 3 suites in C:\x\y', '- proof by relative path: 12 jobs in kitchen/jobs', '- proof by file name: 5 rules in CREED.md',
        '- proof by URL: 9 checks https://example.invalid/pr/1', '- proof by command: 7 found by `git log -7`', '- proof by commit: 4 fixes in b02f911',
        '- proof by test: 66 checks in Test-Handoff', '- proof by source: 3 days (source: Jordan in chat)', '- says unknown: 2 users, count unknown',
        '- says UNVERIFIED: 30 % faster (UNVERIFIED)', '```', '- 99 inside a code fence', '```')
    Put (Join-Path $brain 'memory\NOW.md') ($lint -join "`n")
    Put (Join-Path $brain 'memory\evie-notes.md') '- 77 private bullet'; Put (Join-Path $brain 'memory\archive\old.md') '- 88 archived bullet'
    Put (Join-Path $brain 'memory\user\x.md') '- 66 user bullet'; Put (Join-Path $brain 'memory\BOOT.md') '- 55 script-built bullet'
    $r = Run $truth @('-MemoryDir', $mem, '-BrainPath', $brain, '-Json'); $w = @($r.J.warnings)
    function Warned($ln) { @($w | Where-Object { $_.file -eq 'memory/NOW.md' -and $_.line -eq $ln }).Count -eq 1 }
    Check 'proof lint: a bullet with a number and no proof is a WARN with file:line' (Warned 2)
    Check 'proof lint: a bullet with a date and no proof is a WARN' (Warned 3)
    Check 'proof lint: a bullet with an id (J176) and no proof is a WARN' (Warned 4)
    Check 'proof lint: a bullet with no number, date or id is not linted' (-not (Warned 5))
    Check 'proof lint: an absolute path is proof' (-not (Warned 6))
    Check 'proof lint: a relative path is proof' (-not (Warned 7))
    Check 'proof lint: a file name is proof' (-not (Warned 8))
    Check 'proof lint: a URL is proof' (-not (Warned 9))
    Check 'proof lint: a `command` is proof' (-not (Warned 10))
    Check 'proof lint: a commit sha is proof' (-not (Warned 11))
    Check 'proof lint: a test name is proof' (-not (Warned 12))
    Check 'proof lint: (source: ...) is proof' (-not (Warned 13))
    Check 'proof lint: "unknown" is allowed' (-not (Warned 14))
    Check 'proof lint: "UNVERIFIED" is allowed' (-not (Warned 15))
    Check 'proof lint: code fences are skipped' (-not (Warned 17))
    Check 'proof lint: evie*, archive/, user/ and the script-built BOOT.md are never linted' ($w.Count -eq 3 -and -not @($w | Where-Object { $_.file -ne 'memory/NOW.md' }).Count)
    Check 'proof lint: WARNs never fail the run (exit 0, ok, no findings) and the baseline count is in the output' ($r.Code -eq 0 -and $r.J.ok -and $r.J.proofLint.warn -eq 3 -and $r.J.proofLint.factBullets -eq 13 -and (Run $truth @('-MemoryDir', $mem, '-BrainPath', $brain)).Out -match "Proof lint \(WARN only, baseline[^\n]*3 of 13 fact bullet[\s\S]*WARN memory/NOW\.md:2:")
    Check 'proof lint: the heartbeat carries the WARN count' ((Get-Content (Join-Path $kr 'watch\memory.json') -Raw | ConvertFrom-Json).warn -eq 3)
    Put (Join-Path $brain 'memory\NOW.md') 'now'
    # ---- restore-drill.ps1 --------------------------------------------------------------------------------------------------------
    $drill = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\restore-drill.ps1')).Path
    $bk = Join-Path $root 'bk'
    Check 'restore drill: no backup folder exits 2' ((Run $drill @('-Source', $bk, '-Json')).Code -eq 2)
    $day = Join-Path $bk '2026-10-20'; Put (Join-Path $day 'ideas.json') '{"items":[]}'; Put (Join-Path $day 'kitchen.json') '{}'; Put (Join-Path $day 'jobs\J1.json') '{"id":"J1"}'
    Set-Content (Join-Path $day 'alerts.jsonl') ('{"a":1}', '{"a":2}') -Encoding utf8
    $r = Run $drill @('-Source', $bk, '-Json')
    Check 'restore drill: a good backup is restorable (exit 0) and counted' ($r.Code -eq 0 -and $r.J.ok -and $r.J.jobs -eq 1 -and $r.J.jsonlLines -eq 2)
    Check 'restore drill: heartbeat written (weekly)' ((Get-Content (Join-Path $kr 'watch\restore.json') -Raw | ConvertFrom-Json).everyMin -eq 10080)
    Check 'restore drill: the throwaway copy is removed' (-not @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'kitchen-test-restore-*' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) }).Count)
    $day2 = Join-Path $bk '2026-10-21'; Put (Join-Path $day2 'ideas.json') '{ broken'; Put (Join-Path $day2 'jobs\J1.json') '{"id":"J1"}'
    $r = Run $drill @('-Source', $bk, '-Json')
    Check 'restore drill: the newest backup is the one tested; a damaged file and a missing kitchen.json are problems' ($r.Code -eq 3 -and $r.J.backup -eq '2026-10-21' -and @($r.J.problems | Where-Object { $_.say -match 'ideas.json does not parse' }).Count -eq 1 -and @($r.J.problems | Where-Object { $_.say -match 'no kitchen.json' }).Count -eq 1)
    Check 'memory: bad call (no MEMORY.md) exits 2' ((Run $truth @('-MemoryDir', (Join-Path $root 'nothing'), '-Json')).Code -eq 2)
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Watch tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
