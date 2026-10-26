#requires -Version 7
<#
Brain Monitor v0 tests. Plain PowerShell 7. Run: pwsh -NoProfile -File tests/Test-BrainMonitor.ps1
All fixtures are throwaway brain trees under <repo>/.tmp (git-ignored). Secret-looking values are assembled from fragments.
#>
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# fixtures live under TEMP, not <repo>/.tmp: the kitchen runs suites at Low integrity (rust/kitchen-sandbox), which cannot write the repo
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('brain-monitor-test-' + [guid]::NewGuid().ToString('N'))
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory $tmp | Out-Null
$pass = 0; $fail = 0; $skip = 0
function Check([string]$Name, [bool]$Cond, [string]$Detail = '') { if ($Cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $Name $Detail" -ForegroundColor Red } }

function New-Brain([string]$Name) {
    $b = Join-Path $tmp $Name
    foreach ($d in 'memory\user', 'memory\evie', 'memory\user\finances', 'projects\career\demo', 'projects\naf', 'projects\life_admin') { New-Item -ItemType Directory -Force (Join-Path $b $d) | Out-Null }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    Set-Content (Join-Path $b 'AGENT_CONTEXT.md') "# Agent Context`nSee ``memory/NOW.md`` and ``projects/career/demo/STATUS.md``.`nProtected: ``memory/evie/``."
    Set-Content (Join-Path $b 'memory\NOW.md') "# NOW`nLast updated: $today by test.`n## Directive`nx`n## Active threads`nx`n## Waiting on Jordan`nx"
    Set-Content (Join-Path $b 'projects\career\demo\STATUS.md') '# status'
    Set-Content (Join-Path $b 'memory\user\context.md') '# context'
    Set-Content (Join-Path $b '.gitignore') "memory/evie`nmemory/user/finances`nprojects/life_admin`nprojects/evie_admin`nmemory/user/USER_IDENTITY.md"
    git -C $b init -q -b main 2>&1 | Out-Null; git -C $b config user.email t@example.invalid; git -C $b config user.name t
    git -C $b add -A 2>&1 | Out-Null; git -C $b commit -q -m init 2>&1 | Out-Null
    $b
}
function Run-Check([string]$Brain, [string]$Data = (Join-Path $tmp 'data'), [string[]]$Extra = @()) {
    $out = & pwsh -NoProfile -File (Join-Path $repo 'scripts\memory-check.ps1') -BrainPath $Brain -DataDir $Data @Extra 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}
function Tree-Hash([string]$Root) {
    (Get-ChildItem $Root -Recurse -Force -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($Root.Length)):$((Get-FileHash $_.FullName).Hash)" }) -join "`n"
}
$canary = 'sk-' + ('C4n4ryV4lue' * 3)
$pwCanary = 'pass' + 'word = "Canary' + 'Secret12345"'

Write-Host '== healthy brain'
$b1 = New-Brain 'b1'
$before = Tree-Hash $b1; $dirsBefore = (Get-ChildItem $b1 -Recurse -Force -Directory | Where-Object FullName -notmatch '\\\.git' | Measure-Object).Count
$r = Run-Check $b1
Check 'healthy brain exits 0' ($r.Code -eq 0) "(code $($r.Code)) $($r.Out)"
Check 'healthy brain reports no FAIL' ($r.Out -notmatch '\[FAIL\]')
Check 'summary line present' ($r.Out -match 'SUMMARY: 0 FAIL')
Check 'report file written under the data dir' ((Get-ChildItem (Join-Path $tmp 'data\reports') -Filter 'check-*.txt' -ErrorAction SilentlyContinue | Measure-Object).Count -ge 1)
Check 'brain files are byte-identical after a run (read-only)' ((Tree-Hash $b1) -eq $before)
Check 'no new folders or files appear in the brain' ((Get-ChildItem $b1 -Recurse -Force -Directory | Where-Object FullName -notmatch '\\\.git' | Measure-Object).Count -eq $dirsBefore)

Write-Host '== context budget'
$b2 = New-Brain 'b2'; Set-Content (Join-Path $b2 'AGENT_CONTEXT.md') ((1..120 | ForEach-Object { "line $_" }) -join "`n")
$r = Run-Check $b2; Check 'oversized AGENT_CONTEXT fails' ($r.Code -eq 1 -and $r.Out -match '\[FAIL\] context')
$b2b = New-Brain 'b2b'; Set-Content (Join-Path $b2b 'AGENT_CONTEXT.md') ((1..70 | ForEach-Object { "line $_ ``memory/NOW.md``" }) -join "`n")
$r = Run-Check $b2b; Check 'long AGENT_CONTEXT warns but passes' ($r.Code -eq 0 -and $r.Out -match '\[WARN\] context')
$b2c = New-Brain 'b2c'; Remove-Item (Join-Path $b2c 'AGENT_CONTEXT.md')
$r = Run-Check $b2c; Check 'missing AGENT_CONTEXT fails' ($r.Code -eq 1 -and $r.Out -match 'AGENT_CONTEXT.md is missing')

Write-Host '== short-term memory (NOW.md)'
$b3 = New-Brain 'b3'; Remove-Item (Join-Path $b3 'memory\NOW.md')
$r = Run-Check $b3; Check 'missing NOW.md fails' ($r.Code -eq 1 -and $r.Out -match 'NOW.md is missing')
$b3b = New-Brain 'b3b'; (Get-Content (Join-Path $b3b 'memory\NOW.md') -Raw) -replace 'Last updated: \d{4}-\d{2}-\d{2}', ('Last updated: ' + (Get-Date).AddDays(-20).ToString('yyyy-MM-dd')) | Set-Content (Join-Path $b3b 'memory\NOW.md')
$r = Run-Check $b3b; Check 'stale NOW.md (20 days) fails' ($r.Code -eq 1 -and $r.Out -match 'stale')
$b3c = New-Brain 'b3c'; (Get-Content (Join-Path $b3c 'memory\NOW.md') -Raw) -replace 'Last updated: \d{4}-\d{2}-\d{2}', ('Last updated: ' + (Get-Date).AddDays(-5).ToString('yyyy-MM-dd')) | Set-Content (Join-Path $b3c 'memory\NOW.md')
$r = Run-Check $b3c; Check 'aging NOW.md (5 days) warns but passes' ($r.Code -eq 0 -and $r.Out -match '\[WARN\] now')
$b3d = New-Brain 'b3d'; Set-Content (Join-Path $b3d 'memory\NOW.md') "# NOW`nno stamp here"
$r = Run-Check $b3d; Check 'NOW.md without a date stamp fails' ($r.Code -eq 1 -and $r.Out -match 'no "Last updated')
$b3e = New-Brain 'b3e'; Set-Content (Join-Path $b3e 'memory\NOW.md') ("# NOW`nLast updated: " + (Get-Date).ToString('yyyy-MM-dd') + "`n" + ((1..50 | ForEach-Object { "x$_" }) -join "`n"))
$r = Run-Check $b3e; Check 'NOW.md over 40 lines and missing sections warns' ($r.Out -match 'NOW.md has 5\d lines' -and $r.Out -match "no 'Directive' section")

Write-Host '== pointers'
$b4 = New-Brain 'b4'; Add-Content (Join-Path $b4 'AGENT_CONTEXT.md') "`nSee ``projects/career/demo/GONE.md`` and ``projects/career/demo/STATUS.md``."
$r = Run-Check $b4; Check 'broken pointer is reported' ($r.Out -match "points to 'projects/career/demo/GONE.md'")
Check 'valid pointer is not reported' ($r.Out -notmatch "points to 'projects/career/demo/STATUS.md'")
Check 'pointer to a protected dir is not probed' ($r.Out -notmatch "memory/evie")

Write-Host '== secrets'
$b5 = New-Brain 'b5'; Set-Content (Join-Path $b5 'projects\career\notes.md') "line one`nkey: $canary`nline three"
$r = Run-Check $b5
Check 'secret in an allowed file fails' ($r.Code -eq 1 -and $r.Out -match 'notes.md:2')
Check 'secret value is never printed' ($r.Out -notmatch [regex]::Escape($canary))
Check 'secret value is never written to the report file' (-not ((Get-ChildItem (Join-Path $tmp 'data\reports') -Filter *.txt | ForEach-Object { Get-Content $_.FullName -Raw }) -match [regex]::Escape($canary)))
$b5b = New-Brain 'b5b'; Set-Content (Join-Path $b5b 'projects\career\n.md') $pwCanary
$r = Run-Check $b5b; Check 'password assignment is flagged without its value' ($r.Code -eq 1 -and $r.Out -notmatch 'CanarySecret12345')
$b5c = New-Brain 'b5c'; Set-Content (Join-Path $b5c 'projects\career\n.md') ('pass' + 'word = os.environ["X"]  # example')
$r = Run-Check $b5c; Check 'password read from environment is not flagged' ($r.Code -eq 0)
$b5d = New-Brain 'b5d'; Set-Content (Join-Path $b5d '.env') "A=$canary"
$r = Run-Check $b5d; Check 'a .env file in the brain fails by name' ($r.Code -eq 1 -and $r.Out -match 'secret-type file present')
Check 'a .env file is never opened (canary absent from output)' ($r.Out -notmatch [regex]::Escape($canary))

Write-Host '== protected paths'
$b6 = New-Brain 'b6'
foreach ($p in 'memory\evie\a.md', 'memory\user\finances\b.md', 'projects\life_admin\c.md', 'projects\naf\d.md', 'memory\user\USER_IDENTITY.md') { Set-Content (Join-Path $b6 $p) "key: $canary`n$pwCanary" }
$r = Run-Check $b6
Check 'protected paths with secrets do not fail the check' ($r.Code -eq 0) "($($r.Out))"
Check 'canary from protected paths never appears' ($r.Out -notmatch [regex]::Escape($canary) -and $r.Out -notmatch 'CanarySecret12345')
Check 'protected paths are named only as a count' ($r.Out -match 'skipped [3-9] protected path' -and $r.Out -notmatch 'a\.md|b\.md|c\.md|d\.md|USER_IDENTITY')

Write-Host '== git hygiene'
$b7 = New-Brain 'b7'; git -C $b7 remote add origin 'https://example.invalid/x.git'
$r = Run-Check $b7; Check 'a git remote on the brain fails' ($r.Code -eq 1 -and $r.Out -match 'git remote')
$b7b = New-Brain 'b7b'; Add-Content (Join-Path $b7b 'memory\user\context.md') 'changed'
$r = Run-Check $b7b; Check 'uncommitted tracked changes warn' ($r.Out -match 'uncommitted')
$b7c = New-Brain 'b7c'; Set-Content (Join-Path $b7c '.gitignore') 'nothing'
$r = Run-Check $b7c; Check 'missing .gitignore entries for protected paths warn' ($r.Out -match "not listed in .gitignore")

Write-Host '== never follows links, prunes node_modules'
$b8 = New-Brain 'b8'; New-Item -ItemType Directory (Join-Path $b8 'projects\x\node_modules\pkg') -Force | Out-Null
Set-Content (Join-Path $b8 'projects\x\node_modules\pkg\leak.md') "key: $canary"
$outsideDir = Join-Path $tmp 'outside'; New-Item -ItemType Directory $outsideDir | Out-Null; Set-Content (Join-Path $outsideDir 'o.md') "key: $canary"
New-Item -ItemType Junction -Path (Join-Path $b8 'projects\linked') -Target $outsideDir | Out-Null
$r = Run-Check $b8
Check 'node_modules is pruned' ($r.Out -notmatch 'leak.md')
Check 'a junction out of the brain is not followed' ($r.Code -eq 0 -and $r.Out -notmatch 'o\.md')
Check 'a junction is reported as a link WARN' ($r.Out -match '\[WARN\] link: .*projects/linked')
[IO.Directory]::Delete((Join-Path $b8 'projects\linked'))

Write-Host '== checkpoint'
$b9 = New-Brain 'b9'; $d9 = Join-Path $tmp 'data9'; $h9 = Tree-Hash $b9
1..5 | ForEach-Object { & pwsh -NoProfile -File (Join-Path $repo 'scripts\checkpoint.ps1') -BrainPath $b9 -DataDir $d9 -Keep 3 | Out-Null; Start-Sleep -Milliseconds 1100 }
$cps = @(Get-ChildItem (Join-Path $d9 'checkpoints') -Filter 'NOW-*.md')
Check 'checkpoint keeps only the newest N copies' ($cps.Count -eq 3) "($($cps.Count))"
Check 'checkpoint content matches NOW.md' ((Get-Content $cps[0].FullName -Raw) -eq (Get-Content (Join-Path $b9 'memory\NOW.md') -Raw))
Check 'checkpoint leaves the brain untouched' ((Tree-Hash $b9) -eq $h9)
$b9b = New-Brain 'b9b'; Remove-Item (Join-Path $b9b 'memory\NOW.md')
& pwsh -NoProfile -File (Join-Path $repo 'scripts\checkpoint.ps1') -BrainPath $b9b -DataDir (Join-Path $tmp 'data9b') | Out-Null
Check 'checkpoint with no NOW.md exits 1 and writes nothing' ($LASTEXITCODE -eq 1 -and -not (Test-Path (Join-Path $tmp 'data9b\checkpoints\NOW-*.md')))

Write-Host '== links: a linked memory\ is never read or copied (junction, needs no special rights)'
$b10 = New-Brain 'b10'
$outMem = Join-Path $tmp 'outside-mem'; New-Item -ItemType Directory $outMem | Out-Null
Set-Content (Join-Path $outMem 'NOW.md') ("# NOW`nLast updated: " + (Get-Date).ToString('yyyy-MM-dd') + "`n## Directive`nkey: $canary")
Remove-Item (Join-Path $b10 'memory') -Recurse -Force
New-Item -ItemType Junction -Path (Join-Path $b10 'memory') -Target $outMem | Out-Null
$r = Run-Check $b10
Check 'linked memory\ means NOW.md is not read (FAIL now)' ($r.Code -eq 1 -and $r.Out -match '\[FAIL\] now') "($($r.Out))"
Check 'linked memory\ is reported as a link' ($r.Out -match '\[WARN\] link: .*memory')
Check 'canary behind a linked memory\ never appears' ($r.Out -notmatch [regex]::Escape($canary))
$d10 = Join-Path $tmp 'data10'
& pwsh -NoProfile -File (Join-Path $repo 'scripts\checkpoint.ps1') -BrainPath $b10 -DataDir $d10 | Out-Null
Check 'checkpoint refuses a linked memory\ (exit 1, nothing written)' ($LASTEXITCODE -eq 1 -and @(Get-ChildItem (Join-Path $d10 'checkpoints') -Filter 'NOW-*.md' -ErrorAction SilentlyContinue).Count -eq 0)
[IO.Directory]::Delete((Join-Path $b10 'memory'))

Write-Host '== pointers that climb or leave the brain'
$b11 = New-Brain 'b11'; Add-Content (Join-Path $b11 'AGENT_CONTEXT.md') "`nSee ``memory/user/../evie/a.md`` and ``projects/../../outside/o.md`` and ``projects/career/``."
$r = Run-Check $b11
$ptrLines = ($r.Out -split "`n" | Where-Object { $_ -match '\[WARN\] pointer' }) -join "`n"
Check 'unsafe pointer tokens are counted' ($ptrLines -match '2 pointer\(s\) with unsafe path parts') "($($r.Out))"
Check 'unsafe pointer tokens are never echoed or probed' ($ptrLines -notmatch 'evie|outside|a\.md|o\.md')
Check 'a pointer to a folder is not reported' ($r.Out -notmatch "points to 'projects/career/'")

Write-Host '== links: file symlinks (need permission to create symlinks)'
function Remove-Link([string]$Path) { if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete($Path) } elseif ([IO.File]::Exists($Path) -or (Test-Path -LiteralPath $Path)) { [IO.File]::Delete($Path) } }
function New-FileLink([string]$Path, [string]$Target) { try { New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null; $true } catch { $false } }
function Skip([string]$Name) { $script:skip++; Write-Host "SKIP: $Name (cannot create symlinks here; enable Developer Mode or run elevated)" -ForegroundColor Yellow }

$b12 = New-Brain 'b12'
Set-Content (Join-Path $b12 'memory\evie\a.md') "key: $canary"
$outFile = Join-Path $tmp 'outside\o.md'; New-Item -ItemType Directory (Join-Path $tmp 'outside') -Force | Out-Null; Set-Content $outFile "key: $canary"
$lnk1 = Join-Path $b12 'projects\career\link.md'; $lnk2 = Join-Path $b12 'projects\career\out.md'
if ((New-FileLink $lnk1 (Join-Path $b12 'memory\evie\a.md')) -and (New-FileLink $lnk2 $outFile)) {
    $h12 = Tree-Hash $b12
    $r = Run-Check $b12
    Check 'file links to a protected file and to the outside: exit 0' ($r.Code -eq 0) "($($r.Out))"
    Check 'a linked file is never opened (no link.md / out.md secret hit)' ($r.Out -notmatch 'link\.md:\d|out\.md:\d')
    Check 'canary behind file links never appears' ($r.Out -notmatch [regex]::Escape($canary))
    Check 'file links produce a link WARN' ($r.Out -match '\[WARN\] link: 2 link\(s\)')
    Check 'brain is byte-identical after a run with file links' ((Tree-Hash $b12) -eq $h12)
    Remove-Link $lnk1; Remove-Link $lnk2
} else { Remove-Link $lnk1; Remove-Link $lnk2; Skip 'file links to protected and outside files' }

$b13 = New-Brain 'b13'; $dead = Join-Path $b13 'projects\career\dead.md'
if (New-FileLink $dead (Join-Path $tmp 'does-not-exist.md')) {
    $r = Run-Check $b13
    Check 'a link with a missing target does not crash the check' ($r.Code -eq 0 -and $r.Out -match 'SUMMARY:' -and $r.Out -match '\[WARN\] link: .*dead\.md') "($($r.Out))"
    Remove-Link $dead
} else { Remove-Link $dead; Skip 'link with a missing target' }

$b14 = New-Brain 'b14'; $nowLink = Join-Path $b14 'memory\NOW.md'
$outNow = Join-Path $tmp 'outside\now.md'; Set-Content $outNow "# NOW`nLast updated: $((Get-Date).ToString('yyyy-MM-dd'))`nkey: $canary"
Remove-Item $nowLink
if (New-FileLink $nowLink $outNow) {
    $d14 = Join-Path $tmp 'data14'
    $o14 = & pwsh -NoProfile -File (Join-Path $repo 'scripts\checkpoint.ps1') -BrainPath $b14 -DataDir $d14 | Out-String
    Check 'checkpoint refuses a NOW.md that is a file link' ($LASTEXITCODE -eq 1 -and $o14 -match 'is a link; not copied' -and @(Get-ChildItem (Join-Path $d14 'checkpoints') -Filter 'NOW-*.md' -ErrorAction SilentlyContinue).Count -eq 0)
    Remove-Link $nowLink
} else { Skip 'NOW.md as a file link' }

Write-Host '== repo hygiene'
Check '.gitignore keeps data and scratch out of git' ((Get-Content (Join-Path $repo '.gitignore') -Raw) -match '(?m)^data/' -and (Get-Content (Join-Path $repo '.gitignore') -Raw) -match '(?m)^\.tmp/')
Check 'README states the limits honestly' ((Get-Content (Join-Path $repo 'README.md') -Raw) -match 'Limits')
Check 'scripts contain no network calls' (-not (Select-String -Path (Get-ChildItem (Join-Path $repo 'scripts\*.ps1') | Where-Object { $_.Name -notin 'run-bounded.ps1', 'standup.ps1', 'standup-recap.ps1', 'rgb.ps1', 'rename-tasks.ps1' }).FullName -Pattern 'Invoke-WebRequest|Invoke-RestMethod|curl|wget|Net\.Http|Start-Process|Invoke-Expression|iex ' -Quiet))
# rgb.ps1 may only Start-Process the local OMEN Light Studio app (shell:AppsFolder); everything else stays banned
$rgbHits = @(Select-String -Path (Join-Path $repo 'scripts\rgb.ps1') -Pattern 'Invoke-WebRequest|Invoke-RestMethod|curl|wget|Net\.Http|Start-Process|Invoke-Expression|iex ')
Check 'rgb.ps1 only launches the local app' (@($rgbHits | Where-Object { $_.Line -notmatch 'Start-Process "shell:AppsFolder\\' -or $_.Line -match 'Invoke-WebRequest|Invoke-RestMethod|curl|wget|Net\.Http|Invoke-Expression|iex ' }).Count -eq 0)
# the two agent-standup scripts are the only exceptions, each narrowly: localhost URLs only, no download/exec primitives
foreach ($n in 'standup.ps1', 'standup-recap.ps1') {
    $p = Join-Path $repo "scripts\$n"
    Check "$n has no download/exec primitives" (-not (Select-String -Path $p -Pattern 'Invoke-WebRequest|curl|wget|Net\.Http|Invoke-Expression|iex |DownloadFile|Start-BitsTransfer' -Quiet))
    $urls = @(Select-String -Path $p -Pattern 'https?://[^\s"''`)]+' -AllMatches | ForEach-Object { $_.Matches.Value })
    Check "$n only mentions localhost URLs" (@($urls | Where-Object { $_ -notmatch '^http://127\.0\.0\.1[:/]' -and $_ -notmatch '^https://github\.com/' }).Count -eq 0)
}
Check 'standup-recap does not spawn processes' (-not (Select-String -Path (Join-Path $repo 'scripts\standup-recap.ps1') -Pattern 'Start-Process|Invoke-Expression' -Quiet))
Check 'scripts never write into the brain (no Set-Content/Out-File on $brain paths)' (-not (Select-String -Path (Join-Path $repo 'scripts\memory-check.ps1') -Pattern 'Set-Content|Out-File|Add-Content|Remove-Item|Move-Item|Copy-Item' -Quiet))

# Leave no scratch behind: every fixture and report this run created is removed (kitchen rule: nothing unaccounted for).
Remove-Item -LiteralPath $tmp -Recurse -Force

Write-Host ''
Write-Host "RESULT: $pass passed, $fail failed, $skip skipped"
if ($fail) { exit 1 } else { exit 0 }
