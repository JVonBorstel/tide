# Tests for rust/kitchen-sandbox (the launcher the tests, mutate and verify stations run AI-written suites through) and its wiring:
# at Low integrity a script cannot write a Medium folder but can write its scratch TEMP; a timeout kills the whole tree; exit codes
# pass through (124 timeout, 125 memory); it refuses to label folders outside TEMP Low; a config that asks for the sandbox with no
# exe makes the tests and mutate stations hold (exit 10), never run unsandboxed. Builds the exe offline if it is missing. Self-cleaning.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# a kitchen order runs this in its own worktree, where target\ (gitignored) was never built: use the main checkout's exe, the one
# the stations themselves run (building at Low integrity inside the sandbox cannot work). Oct 19: every order failed here.
$built = $repo
if (-not (Test-Path -LiteralPath (Join-Path $repo 'rust\kitchen-sandbox\target\release\kitchen-sandbox.exe'))) {
    $common = & git -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -eq 0 -and $common) { $main = Split-Path ($common.Trim()) -Parent; if (Test-Path -LiteralPath (Join-Path $main 'rust\kitchen-sandbox\target\release\kitchen-sandbox.exe')) { $built = $main } }
}
$exe = Join-Path $built 'rust\kitchen-sandbox\target\release\kitchen-sandbox.exe'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
if (-not (Test-Path -LiteralPath $exe)) { & pwsh -NoProfile -File (Join-Path $built 'rust\kitchen-sandbox\build.ps1') 2>&1 | Out-Null }
if (-not (Test-Path -LiteralPath $exe)) { Write-Host 'FAIL: kitchen-sandbox.exe could not be built (cargo build --release --offline)'; Write-Host 'Sandbox tests: 0 passed, 1 failed'; exit 1 }
$pw = Join-Path $PSHOME 'pwsh.exe'
$d = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-sandbox-' + [guid]::NewGuid().ToString('N'))
function Sbx([string[]]$a) { $o = & $exe @a 2>&1 | Out-String; @{ out = $o; code = $LASTEXITCODE } }
try {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    # a Medium folder: the default label of anything a Medium process creates. When this suite itself runs inside the sandbox (the
    # kitchen runs every suite there) what it creates is Low, so the repo's tests folder (Medium, never labelled) stands in.
    $atLow = (& "$env:SystemRoot\System32\whoami.exe" /groups 2>$null | Out-String) -match 'S-1-16-4096'
    $medium = if ($atLow) { Join-Path $repo 'tests' } else { Join-Path $d 'medium' }; New-Item -ItemType Directory -Force -Path $medium | Out-Null
    $scratch = Join-Path $d 'scratch'
    $s = Join-Path $d 'probe.ps1'
    Set-Content -LiteralPath $s -Value @'
param([string]$Medium)
$r = @()
try { [IO.File]::WriteAllText((Join-Path $Medium 'evil.txt'), 'x'); $r += 'medium:wrote' } catch { $r += 'medium:denied' }
try { [IO.File]::WriteAllText((Join-Path $env:TEMP 'ok.txt'), 'x'); $r += 'temp:wrote' } catch { $r += "temp:denied $_" }
$r += "home:$env:USERPROFILE"; $r += "sbx:$env:KITCHEN_SANDBOX"
$r -join "`n"
exit 7
'@
    # 1. Low: Medium folder refused, scratch TEMP writable, private HOME, exit code passes through
    $r = Sbx @('--timeout', '120', '--scratch', $scratch, '--path-first', $PSHOME, '--', $pw, '-NoProfile', '-File', $s, '-Medium', $medium)
    Check 'low: write to a Medium folder is denied' ($r.out -match 'medium:denied' -and -not (Test-Path -LiteralPath (Join-Path $medium 'evil.txt')))
    Check 'low: write to scratch TEMP works' ($r.out -match 'temp:wrote' -and (Test-Path -LiteralPath (Join-Path $scratch 'tmp\ok.txt')))
    Check 'low: USERPROFILE is the scratch home' ($r.out -match [regex]::Escape("home:$scratch\home"))
    Check 'low: KITCHEN_SANDBOX=1 set' ($r.out -match 'sbx:1')
    Check 'exit code passes through (7)' ($r.code -eq 7)
    $il = (& icacls.exe $scratch 2>&1 | Out-String)
    Check 'scratch labelled Low' ($il -match 'Mandatory Label\\Low Mandatory Level')
    # 2. --medium: the same job and folders without the Low label; the Medium folder is writable (that is the documented trade-off)
    $r = Sbx @('--medium', '--timeout', '120', '--scratch', (Join-Path $d 'scratch2'), '--', $pw, '-NoProfile', '-File', $s, '-Medium', $medium)
    Check 'medium mode: runs, exit passes through' ($r.code -eq 7 -and $r.out -match 'temp:wrote')
    # 3. timeout kills the whole tree: a child started by the suite (a grandchild of the launcher) must die with it
    $pidFile = Join-Path $d 'scratch3\tmp\grandchild.pid'   # the child's TEMP: a Low child can write only there
    $t = Join-Path $d 'tree.ps1'
    Set-Content -LiteralPath $t -Value "`$p = Start-Process -FilePath '$pw' -ArgumentList '-NoProfile','-Command','Start-Sleep 300' -PassThru -WindowStyle Hidden; Set-Content -LiteralPath '$pidFile' -Value `$p.Id; Start-Sleep 300"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Sbx @('--timeout', '8', '--scratch', (Join-Path $d 'scratch3'), '--', $pw, '-NoProfile', '-File', $t)
    $sw.Stop()
    Check 'timeout: exit 124' ($r.code -eq 124)
    Check 'timeout: returned promptly' ($sw.Elapsed.TotalSeconds -lt 60)
    $gpid = if (Test-Path -LiteralPath $pidFile) { [int](Get-Content -LiteralPath $pidFile -Raw).Trim() } else { 0 }
    Start-Sleep -Milliseconds 500
    Check 'timeout: grandchild was started' ($gpid -gt 0)
    Check 'timeout: grandchild killed with the tree' ($gpid -gt 0 -and -not (Get-Process -Id $gpid -ErrorAction SilentlyContinue))
    # 4. memory cap: a tree past --mem is killed with 125
    # the cap is for the whole tree: two processes of 150 MB each (each alone well under it) go over 300 MB together, and both exiting
    # 0 must still be 125
    $two = '$b = [byte[]]::new(150MB); [Array]::Fill($b, [byte]1); pwsh -NoProfile -Command ''$c = [byte[]]::new(150MB); [Array]::Fill($c, [byte]1); exit 0''; exit 0'
    $r = Sbx @('--timeout', '120', '--mem', '300', '--scratch', (Join-Path $d 'scratch4'), '--path-first', $PSHOME, '--', $pw, '-NoProfile', '-Command', $two)
    Check 'memory cap: whole tree past it -> 125 even when every process exits 0' ($r.code -eq 125)
    # one pwsh process alone, growing and swallowing its OutOfMemory, is killed with 125 too. .NET caps its heap at 75% of the job's hard
    # limit; with the hard limit at 1.25x --mem that was 94% of it, so one process never reached --mem, was never killed, and exited 0
    # (a suite past its cap in the tests Step read "timed out", TD-EH-16's Test-Big). The hard limit is 1.5x now: 112% of --mem.
    $grow = '$l = [Collections.Generic.List[byte[]]]::new(); foreach ($k in 1..24) { try { $a = [byte[]]::new(25MB); [Array]::Fill($a, [byte]1); $l.Add($a) } catch { } }; exit 0'
    $r = Sbx @('--timeout', '120', '--mem', '300', '--scratch', (Join-Path $d 'scratch4'), '--path-first', $PSHOME, '--', $pw, '-NoProfile', '-Command', $grow)
    Check 'memory cap: one process growing past it -> 125, even when it swallows its OutOfMemory and exits 0' ($r.code -eq 125 -and $r.out -match 'killed the tree \(exit 125: memory cap 300 MB\)')
    $r = Sbx @('--timeout', '120', '--mem', '300', '--scratch', (Join-Path $d 'scratch4'), '--', $pw, '-NoProfile', '-Command', '$b = [byte[]]::new(50MB); [Array]::Fill($b, [byte]1); exit 3')
    Check 'under the memory cap: the child''s own code' ($r.code -eq 3)
    # 5. refuses to label anything outside TEMP / the kitchen state folder Low (a repo, the home folder), and exits 126 without running
    $marker = Join-Path $d 'ran.txt'
    $r = Sbx @('--timeout', '30', '--label-low', $PSHOME, '--', 'cmd.exe', '/c', "echo x> `"$marker`"")
    Check 'label outside TEMP refused (126), command not run' ($r.code -eq 126 -and $r.out -match 'refusing to label' -and -not (Test-Path -LiteralPath $marker))
    $r = Sbx @('--bogus', '--', 'cmd.exe', '/c', 'exit 0')
    Check 'unknown option refused (126)' ($r.code -eq 126)
    # 6. wiring: Get-KitchenSandbox reads kitchen.json (state copy wins); asked for and not built = hold
    . (Join-Path $repo 'rust\kitchen-sandbox\sandbox.ps1')
    $fk = Join-Path $d 'fake\kitchen'; $fs = Join-Path $d 'fakestate'; New-Item -ItemType Directory -Force -Path $fk, $fs | Out-Null
    Set-Content -LiteralPath (Join-Path $fk 'kitchen.json') -Value '{"sandbox":"auto"}'
    $g = Get-KitchenSandbox $fk $fs
    Check 'auto without exe: off, no hold' ($g.mode -eq 'off' -and -not $g.hold)
    Set-Content -LiteralPath (Join-Path $fs 'kitchen.json') -Value '{"sandbox":"low"}'
    $g = Get-KitchenSandbox $fk $fs
    Check 'state copy says low, no exe: hold' ($g.mode -eq 'low' -and $g.hold -match 'not built')
    Set-Content -LiteralPath (Join-Path $fs 'kitchen.json') -Value '{ broken'
    Check 'unreadable config: low (fail closed), hold' ((Get-KitchenSandbox $fk $fs).hold)
    $g = Get-KitchenSandbox (Join-Path $built 'kitchen') $fs
    Check 'real kitchen with the exe built: low' ($g.mode -eq 'low' -and -not $g.hold)
    # sandboxMedium: a listed suite runs at Medium only while the job changed none of its files; changed, it runs Low like the rest
    Set-Content -LiteralPath (Join-Path $fs 'kitchen.json') -Value '{"sandbox":"low","sandboxMedium":{"Test-Il":["tests/Test-Il.ps1","scripts/il.ps1"]}}'
    $g = Get-KitchenSandbox (Join-Path $built 'kitchen') $fs
    $il = Join-Path $d 'Test-Il.ps1'; Set-Content -LiteralPath $il -Value 'if ((& "$env:SystemRoot\System32\whoami.exe" /groups | Out-String) -match "S-1-16-4096") { "IL=low" } else { "IL=medium" }'
    $k1 = Join-Path $d 'k1'; New-Item -ItemType Directory -Force -Path $k1 | Out-Null
    $o = Invoke-KitchenSuite $g $il $d $k1 60 1000 '' @('other.ps1')
    Check 'sandboxMedium: listed and unchanged -> Medium' ($o -match 'IL=medium' -or ($atLow -and $o -match 'IL=low'))
    $o = Invoke-KitchenSuite $g $il $d $k1 60 1000 '' @('scripts\il.ps1')
    Check 'sandboxMedium: its script changed by the job -> Low' ($o -match 'IL=low')
    $o = Invoke-KitchenSuite $g $il $d $k1 60 1000 '' @('Test-Il.ps1')
    Check 'sandboxMedium: the suite file itself added or changed by the job (same name, any repo) -> Low' ($o -match 'IL=low')
    $o = Invoke-KitchenSuite (Get-KitchenSandbox (Join-Path $built 'kitchen') $fs | ForEach-Object { $_.medium = @{}; $_ }) $il $d $k1 60 1000 ''
    Check 'not listed -> Low' ($o -match 'IL=low')
    # an entry ending in "/" is a whole folder (another repo's suite that drives its hooks and scripts): any file under it puts the job back to Low
    Set-Content -LiteralPath (Join-Path $fs 'kitchen.json') -Value '{"sandbox":"low","sandboxMedium":{"Test-Il":["scripts/",".claude\\"]}}'
    $g = Get-KitchenSandbox (Join-Path $built 'kitchen') $fs
    $o = Invoke-KitchenSuite $g $il $d $k1 60 1000 '' @('docs/readme.md', 'scripts.txt')
    Check 'sandboxMedium folder entry: nothing under it changed -> Medium (scripts.txt is not under scripts/)' ($o -match 'IL=medium' -or ($atLow -and $o -match 'IL=low'))
    $o = Invoke-KitchenSuite $g $il $d $k1 60 1000 '' @('Scripts\deep\x.ps1')
    Check 'sandboxMedium folder entry: a file anywhere under it changed (any case, any slash) -> Low' ($o -match 'IL=low')
    $o = Invoke-KitchenSuite $g $il $d $k1 60 1000 '' @('.claude/hooks/lib.ps1')
    Check 'sandboxMedium folder entry written with a backslash still matches' ($o -match 'IL=low')
    # the stations themselves: a copy of the layout with no exe and a state kitchen.json asking for low -> exit 10, no suite run
    $fr = Join-Path $d 'layout'; New-Item -ItemType Directory -Force -Path "$fr\kitchen\stations", "$fr\rust\kitchen-sandbox", "$fr\scripts", "$fr\wt\tests" | Out-Null
    foreach ($f in 'tests.ps1', 'mutate.ps1', 'verify.ps1') { Copy-Item (Join-Path $repo "kitchen\stations\$f") "$fr\kitchen\stations\$f" }
    Copy-Item (Join-Path $repo 'kitchen\repo-config.ps1') "$fr\kitchen\repo-config.ps1"   # the stations dot-source it
    Copy-Item (Join-Path $repo 'kitchen\suite-times-lib.ps1') "$fr\kitchen\suite-times-lib.ps1"   # and the tests station this
Copy-Item (Join-Path $repo 'kitchen\train.ps1') "$fr\kitchen\train.ps1"   # and verify this (one merge train per repo, W2)
    Copy-Item (Join-Path $repo 'rust\kitchen-sandbox\sandbox.ps1') "$fr\rust\kitchen-sandbox\sandbox.ps1"
    Copy-Item (Join-Path $repo 'scripts\run-bounded.ps1') "$fr\scripts\run-bounded.ps1"
Copy-Item (Join-Path $repo 'scripts\secret-patterns.ps1') "$fr\scripts\secret-patterns.ps1"   # the tests station dot-sources it (TD-EH-02)
    Set-Content -LiteralPath "$fr\kitchen\kitchen.json" -Value '{"sandbox":"auto"}'
    Set-Content -LiteralPath "$fr\wt\tests\Test-Canary.ps1" -Value "Set-Content -LiteralPath '$fr\canary.txt' -Value ran; 'Canary tests: 1 passed, 0 failed'"
    Set-Content -LiteralPath (Join-Path $fs 'kitchen.json') -Value '{"sandbox":"low"}'
    $saveK = $env:BRAIN_KITCHEN; $env:BRAIN_KITCHEN = $fs
    try {
        $o = & pwsh -NoProfile -File "$fr\kitchen\stations\tests.ps1" -Dir "$fr\wt" 2>&1 | Out-String; $c = $LASTEXITCODE
        Check 'tests station holds (exit 10) when the sandbox is asked for and not built' ($c -eq 10 -and $o -match 'not built')
        Check 'tests station ran no suite while held' (-not (Test-Path -LiteralPath "$fr\canary.txt"))
        $o = & pwsh -NoProfile -File "$fr\kitchen\stations\mutate.ps1" -Dir "$fr\wt" -Base HEAD 2>&1 | Out-String; $c = $LASTEXITCODE
        Check 'mutate station holds (exit 10) too' ($c -eq 10 -and $o -match 'not built')
        # verify on a clean main checkout: the held tests station is not a broken main, so nothing is undone (exit 10, merge train held)
        & git -C "$fr\wt" init -q -b main 2>&1 | Out-Null; & git -C "$fr\wt" add -A 2>&1 | Out-Null; & git -C "$fr\wt" -c user.name=t -c user.email=t@localhost commit -q -m init 2>&1 | Out-Null
        $o = & pwsh -NoProfile -File "$fr\kitchen\stations\verify.ps1" -Repo "$fr\wt" -Job J1 2>&1 | Out-String; $c = $LASTEXITCODE
        Check 'verify holds (exit 10) and undoes nothing when the tests station held' ($c -eq 10 -and $o -match 'NOT verified' -and $o -notmatch 'undo-merge')
        # config off: the old run-bounded path still runs the suite
        Set-Content -LiteralPath (Join-Path $fs 'kitchen.json') -Value '{"sandbox":"off"}'
        $o = & pwsh -NoProfile -File "$fr\kitchen\stations\tests.ps1" -Dir "$fr\wt" 2>&1 | Out-String; $c = $LASTEXITCODE
        Check 'sandbox off: suite runs via run-bounded' ($c -eq 0 -and (Test-Path -LiteralPath "$fr\canary.txt"))
    } finally { $env:BRAIN_KITCHEN = $saveK }
    # the real station, sandboxed: a suite that tries to write a Medium folder fails, its own private kitchen is writable
    Set-Content -LiteralPath (Join-Path $fs 'kitchen.json') -Value '{"sandbox":"low"}'
    $wt2 = Join-Path $d 'wt2'; New-Item -ItemType Directory -Force -Path "$wt2\tests" | Out-Null
    Set-Content -LiteralPath "$wt2\tests\Test-Write.ps1" -Value @"
`$ok = 0
try { Set-Content -LiteralPath (Join-Path `$env:BRAIN_KITCHEN 'q.txt') -Value x -ErrorAction Stop; `$ok++ } catch { Write-Host "FAIL: own kitchen not writable: `$_" }
try { Set-Content -LiteralPath '$medium\planted.txt' -Value x -ErrorAction Stop; Write-Host 'FAIL: wrote a Medium folder' } catch { `$ok++ }
"Write tests: `$ok passed, `$(2 - `$ok) failed"; exit ([int](`$ok -ne 2))
"@
    $env:BRAIN_KITCHEN = $fs
    try { $o = & pwsh -NoProfile -File (Join-Path $built 'kitchen\stations\tests.ps1') -Dir $wt2 -SuiteTimeoutSec 120 2>&1 | Out-String; $c = $LASTEXITCODE }
    finally { $env:BRAIN_KITCHEN = $saveK }
    Check 'station sandboxed: own kitchen writable, Medium folder refused' ($c -eq 0 -and $o -match 'ALL PASS' -and -not (Test-Path -LiteralPath "$medium\planted.txt"))
    # stopped, not failed (TD-EH-16), sandboxed as the Yard runs suites: this checkout's tests Step (the layout copy, the exe beside it)
    # reads kitchen-sandbox.exe's kill line and says "timed out after 3 s", never "crashed before its summary line"
    New-Item -ItemType Directory -Force -Path "$fr\rust\kitchen-sandbox\target\release", "$fr\wt3\tests" | Out-Null
    Copy-Item -LiteralPath $exe "$fr\rust\kitchen-sandbox\target\release\kitchen-sandbox.exe"
    Set-Content -LiteralPath "$fr\wt3\tests\Test-Slow.ps1" -Value "'step one passed'; Start-Sleep 120"
    $env:BRAIN_KITCHEN = $fs
    try { $o = & pwsh -NoProfile -File "$fr\kitchen\stations\tests.ps1" -Dir "$fr\wt3" -SuiteTimeoutSec 3 2>&1 | Out-String; $c = $LASTEXITCODE }
    finally { $env:BRAIN_KITCHEN = $saveK }
    Check 'station sandboxed: a suite past its time limit reads "timed out after 3 s" (kitchen-sandbox.exe killed it), FAILED line as before' ($c -eq 1 -and $o -match '(?m)^tests: FAIL\s+Test-Slow\s+timed out after 3 s \(' -and $o -match '(?m)^tests:\s{3,}kitchen-sandbox: killed the tree \(exit 124: timeout 3s\)' -and $o -match '(?m)^tests:\s{3,}FAIL: timed out after 3 s: .*not a failed assertion' -and $o -match '(?m)^tests: FAILED: Test-Slow\s*$' -and $o -notmatch 'crashed before')
}
finally {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    # only there if a check failed while this suite ran at Low and used the repo's tests folder as the Medium target
    foreach ($f in 'evil.txt', 'planted.txt') { Remove-Item -LiteralPath (Join-Path $repo "tests\$f") -Force -ErrorAction SilentlyContinue }
}
Write-Host "Sandbox tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
