# Tests for scripts/batch-run.ps1 (the Foreman's merge batch): GREEN, GREEN-WITH-FLAKE, RED (always red, and a flake the batch touches),
# conflicts and bad input refused, -Merge refused on RED and when main moved, merge-pr stopping mid-batch, landing with a tree check and the
# pass-app update. Run by the Yard's tests Step (tests\Test-*.ps1) and by hand. A local bare repo plays GitHub; merge-pr.ps1, gh and
# pass-app/update.ps1 are stubs passed as parameters, so nothing reaches the network. The real run-bounded.ps1 runs the first case; the rest use an
# in-process runner with the same parameters (one pwsh per suite, not two: under load a pwsh start took 18 s). Self-cleaning.
$ErrorActionPreference = 'Stop'
$src = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$batch = Join-Path $src 'scripts\batch-run.ps1'; $bounded = Join-Path $src 'scripts\run-bounded.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('batch-run-test-' + [guid]::NewGuid().ToString('N'))
$gh = Join-Path $root 'gh.git'; $seed = Join-Path $root 'seed'; $live = Join-Path $root 'live'; $lander = Join-Path $root 'lander'; $mover = Join-Path $root 'mover'
$counts = Join-Path $root 'counts'; $mergeLog = Join-Path $root 'merges.log'; $updateLog = Join-Path $root 'update.log'
$stubMerge = Join-Path $root 'stub-merge-pr.ps1'; $stubGh = Join-Path $root 'stub-gh.ps1'; $stubUpdate = Join-Path $root 'stub-update.ps1'; $quick = Join-Path $root 'quick-bounded.ps1'; $script:runner = $quick; $stubLoad = Join-Path $root 'stub-load.ps1'
$envNames = 'BR_RED', 'BR_FLAKY', 'BR_TOUCHFLAKE', 'BR_DRIFT', 'BR_MOVE', 'BR_MERGE_FAIL', 'BR_COUNT_DIR', 'BR_MAP', 'BR_LANDER', 'BR_MERGELOG', 'BR_UPDATELOG', 'BR_LOAD'
$saved = @{}; foreach ($e in $envNames) { $saved[$e] = [Environment]::GetEnvironmentVariable($e) }
$script:pass = 0; $script:fail = 0
function Check([string]$n, [bool]$c, [string]$show = '') { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n"; if ($show) { Write-Host $show.Trim() } } }
function G([string]$dir) { & git -C $dir -c user.name=t -c user.email=t@localhost -c core.autocrlf=false @args 2>&1 | Out-String }
function Put([string]$dir, [string]$rel, [string]$text) { $p = Join-Path $dir $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null; [IO.File]::WriteAllText($p, $text) }
function New-Branch([string]$name, [string]$rel, [string]$text) {
    G $seed checkout -q -B $name main | Out-Null; Put $seed $rel $text
    G $seed add -A | Out-Null; G $seed commit -q -m $name | Out-Null; G $seed push -q origin $name | Out-Null; G $seed checkout -q main | Out-Null
}
function Set-Case([hashtable]$set = @{}) {
    foreach ($e in 'BR_RED', 'BR_FLAKY', 'BR_TOUCHFLAKE', 'BR_DRIFT', 'BR_MOVE', 'BR_MERGE_FAIL') { [Environment]::SetEnvironmentVariable($e, $null) }
    $env:BR_LOAD = '10:8000'
    foreach ($k in $set.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$set[$k]) }
    Remove-Item -Path (Join-Path $counts '*') -Force -ErrorAction SilentlyContinue
}
function Invoke-Batch([string]$case, [string[]]$BatchArgs) {
    $o = & pwsh -NoProfile -File $batch -Repo $live -RemoteUrl $gh -Slug 'o/r' -Name $case -Worktree (Join-Path $root "wt\$case") -OutDir (Join-Path $root "out\$case") `
        -RunBounded $script:runner -MergePrScript $stubMerge -PassAppUpdate $stubUpdate -Gh $stubGh -LoadProbe $stubLoad -TimeoutSeconds 120 @BatchArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $j = try { Get-Content -LiteralPath (Join-Path $root "out\$case\summary.json") -Raw | ConvertFrom-Json } catch { $null }
    [pscustomobject]@{ code = $code; out = $o; j = $j }
}
function Suite($r, [string]$n) { @($r.j.suites | Where-Object { $_.name -eq $n })[0] }
function Merges { if (Test-Path -LiteralPath $mergeLog) { @(Get-Content -LiteralPath $mergeLog) } else { @() } }
function Updates { if (Test-Path -LiteralPath $updateLog) { @(Get-Content -LiteralPath $updateLog).Count } else { 0 } }
try {
    New-Item -ItemType Directory -Force -Path $root, $counts | Out-Null
    G $root init -q --bare --initial-branch=main $gh | Out-Null
    G $root clone -q $gh $seed | Out-Null
    G $seed symbolic-ref HEAD refs/heads/main | Out-Null
    # the fake suites: one always green (BR_MOVE pushes to main while it runs), one red on BR_RED, one flaky (red on its first run only),
    # one that dot-sources lib/thing.ps1 and is flaky on BR_TOUCHFLAKE
    $counter = '$c = Join-Path $env:BR_COUNT_DIR "{0}.count"; $n = 1 + [int](Get-Content -LiteralPath $c -ErrorAction SilentlyContinue); Set-Content -LiteralPath $c $n'
    Put $seed 'tests\Test-Green.ps1' "if (`$env:BR_MOVE) { & git -C `$env:BR_MOVE fetch -q origin; & git -C `$env:BR_MOVE reset -q --hard origin/main; & git -C `$env:BR_MOVE -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m moved; & git -C `$env:BR_MOVE push -q origin HEAD:main }`nexit 0`n"
    Put $seed 'tests\Test-Red.ps1' "if (`$env:BR_RED -eq '1') { Write-Output 'always red'; exit 1 }`nexit 0`n"
    Put $seed 'tests\Test-Flaky.ps1' (($counter -f 'flaky') + "`nif (`$env:BR_FLAKY -eq '1' -and `$n -eq 1) { exit 1 }`nexit 0`n")
    Put $seed 'tests\Test-Touched.ps1' (". (Join-Path `$PSScriptRoot '..\lib\thing.ps1')`n" + ($counter -f 'touched') + "`nif (`$env:BR_TOUCHFLAKE -eq '1' -and `$n -eq 1) { exit 1 }`nif ((Get-Thing) -ne 1) { exit 1 }`nexit 0`n")
    Put $seed 'lib\thing.ps1' "function Get-Thing { 1 }`n"
    Put $seed 'docs\readme.txt' "line one`n"
    Put $seed 'pass-app\public\app.js' "// app`n"
    G $seed add -A | Out-Null; G $seed commit -q -m seed | Out-Null; G $seed push -q origin main | Out-Null
    New-Branch 'br-a' 'lib\thing.ps1' "function Get-Thing { 1 } # a`n"
    New-Branch 'br-b' 'docs\readme.txt' "line one b`n"
    New-Branch 'br-c' 'docs\readme.txt' "line one c`n"
    New-Branch 'br-d' 'pass-app\public\app.js' "// app d`n"
    foreach ($b in 'f', 'g', 'h', 'i') { New-Branch "br-$b" "docs\$b.txt" "$b`n" }
    foreach ($d in $live, $lander, $mover) { G $root clone -q $gh $d | Out-Null }
    # stubs: merge-pr merges the PR's branch into "GitHub" main through the lander clone (BR_DRIFT adds a commit; BR_MERGE_FAIL=<pr> refuses)
    Set-Content -LiteralPath $stubMerge -Value @'
param([string]$Repo, [int]$Pr, [string]$Why)
Add-Content -LiteralPath $env:BR_MERGELOG -Value "$Repo #$Pr $Why"
if ("$Pr" -eq $env:BR_MERGE_FAIL) { Write-Output "merge-pr: REFUSED ${Repo}#${Pr}: CI did not pass; nothing merged"; exit 1 }
$b = (@($env:BR_MAP -split ';') | Where-Object { $_ -like "$Pr=*" }) -replace '^\d+=', ''
function L { & git -C $env:BR_LANDER -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
L fetch -q origin; L checkout -q -B main origin/main; L merge -q --no-ff --no-edit "origin/$b"
if ($env:BR_DRIFT -eq '1') { Set-Content (Join-Path $env:BR_LANDER "drift-$Pr.txt") 'drift'; L add -A; L commit -q -m drift }
L push -q origin main
Write-Output "merge-pr: MERGED ${Repo}#$Pr"; exit 0
'@
    Set-Content -LiteralPath $stubGh -Value @'
$n = $args[2]; $b = (@($env:BR_MAP -split ';') | Where-Object { $_ -like "$n=*" }) -replace '^\d+=', ''
if (-not $b) { Write-Output 'GraphQL: Could not resolve to a PullRequest'; exit 1 }
Write-Output $b
'@
    Set-Content -LiteralPath $quick -Value 'param([string]$Script, [int]$TimeoutSeconds); & $Script; exit $LASTEXITCODE'
    # the load probe: BR_LOAD = '<cpu %>:<free MB>'; 'fail' throws (load unknown)
    Set-Content -LiteralPath $stubLoad -Value 'if ($env:BR_LOAD -eq ''fail'') { throw ''no probe'' }; $v = $env:BR_LOAD -split '':''; [pscustomobject]@{ cpu = [double]$v[0]; freeMB = [double]$v[1] }'
    Set-Content -LiteralPath $stubUpdate -Value 'Add-Content -LiteralPath $env:BR_UPDATELOG -Value "updated"; Write-Output "UPDATED"; exit 0'
    $env:BR_COUNT_DIR = $counts; $env:BR_MAP = '10=br-a;11=br-b;12=br-d;15=br-f;16=br-g;17=br-h;18=br-i'
    $env:BR_LOAD = '10:8000'; $env:BR_LANDER = $lander; $env:BR_MERGELOG = $mergeLog; $env:BR_UPDATELOG = $updateLog

    # 1. GREEN (through the real run-bounded.ps1): every suite passes; logs and a summary line per suite; nothing merged without -Merge
    Set-Case
    $script:runner = $bounded
    $r = Invoke-Batch 'green' @('-Prs', '11', '-Branches', 'br-b')
    $script:runner = $quick; $stubLoad = Join-Path $root 'stub-load.ps1'
    Check 'GREEN: exit 0, verdict GREEN' ($r.code -eq 0 -and $r.j.verdict -eq 'GREEN' -and $r.out -match 'verdict: GREEN: all 4 suites passed') $r.out
    Check 'GREEN: four suites, sorted, each with exit code, seconds and a log' ((@($r.j.suites | ForEach-Object { $_.name }) -join ',') -eq 'Test-Flaky,Test-Green,Test-Red,Test-Touched' -and
        @($r.j.suites | Where-Object { $_.code -eq 0 -and $null -ne $_.sec -and (Test-Path -LiteralPath $_.log) }).Count -eq 4)
    Check 'GREEN: one plain line per stage' ($r.out -match 'input: PRs #11 \(br-b\)' -and $r.out -match 'fetch: main is at' -and $r.out -match 'integrate: integrate-green at' -and
        $r.out -match 'suite: Test-Red exit 0, [\d.]+ s, passed' -and $r.out -match 'tests: 4 of 4 suites passed' -and $r.out -match 'land: not asked')
    Check 'GREEN: load sampled at the start and per suite, in lines and summary.json; quiet is not LOADED' ($r.out -match 'load: at start: cpu 10%, free 8000 MB' -and
        $r.out -match 'suite: Test-Flaky exit 0, [\d.]+ s, passed; cpu 10%, free 8000 MB' -and @($r.j.load.samples).Count -eq 5 -and $r.j.load.avgCpu -eq 10 -and
        $r.j.loaded -eq $false -and $r.out -match 'load: not loaded: average CPU 10%' -and $r.j.verdictText -eq 'GREEN') $r.out
    Check 'GREEN: the batch diff and branch are recorded' (@($r.j.diff) -contains 'docs/readme.txt' -and (G (Join-Path $root 'wt\green') rev-parse --abbrev-ref HEAD).Trim() -eq 'integrate-green')
    Check 'GREEN: the fetch refs are cleaned up, the live checkout untouched' (-not (G $live for-each-ref refs/batch-run).Trim() -and -not (G $live status --porcelain).Trim())

    # 2. GREEN-WITH-FLAKE: the flaky suite fails once, then passes 3 of 3 alone, and the batch does not touch it
    Set-Case @{ BR_FLAKY = '1' }
    $r = Invoke-Batch 'flake' @('-Prs', '11', '-Branches', 'br-b')
    $s = Suite $r 'Test-Flaky'
    Check 'GREEN-WITH-FLAKE: exit 0, the flake listed' ($r.code -eq 0 -and $r.j.verdict -eq 'GREEN-WITH-FLAKE' -and (@($r.j.flakes) -join ',') -eq 'Test-Flaky') $r.out
    Check 'GREEN-WITH-FLAKE: three reruns alone, each logged' ((@($s.reruns) -join ',') -eq '0,0,0' -and (Get-Content (Join-Path $counts 'flaky.count')) -eq '4' -and
        (Test-Path (Join-Path $root 'out\flake\Test-Flaky.rerun3.log')) -and $r.out -match 'rerun: Test-Flaky passed 3 of 3 alone; the batch does not touch it')

    # 3. RED: a suite that fails alone too
    Set-Case @{ BR_RED = '1' }
    $r = Invoke-Batch 'red' @('-Prs', '11', '-Branches', 'br-b')
    Check 'RED: always red gives exit 1, verdict RED' ($r.code -eq 1 -and $r.j.verdict -eq 'RED' -and (@((Suite $r 'Test-Red').reruns) -join ',') -eq '1,1,1' -and $r.out -match 'verdict: RED: Test-Red') $r.out

    # 4. RED: a flake that passes alone, but the batch touches the file it dot-sources
    Set-Case @{ BR_TOUCHFLAKE = '1' }
    $r = Invoke-Batch 'touched' @('-Prs', '10', '-Branches', 'br-a')
    $s = Suite $r 'Test-Touched'
    Check 'RED: a touched suite is red even after 3 of 3 alone' ($r.code -eq 1 -and $r.j.verdict -eq 'RED' -and (@($s.reruns) -join ',') -eq '0,0,0' -and "$($s.touched)" -match 'lib/thing\.ps1') $r.out
    # 5. the same flake with a batch that does not touch lib/thing.ps1 is a flake
    Set-Case @{ BR_TOUCHFLAKE = '1' }
    $r = Invoke-Batch 'untouched' @('-Prs', '11', '-Branches', 'br-b')
    Check 'GREEN-WITH-FLAKE: the same suite, untouched by the batch' ($r.code -eq 0 -and (@($r.j.flakes) -join ',') -eq 'Test-Touched') $r.out

    # 6. a conflict stops the run, names the file and aborts that merge
    Set-Case
    $r = Invoke-Batch 'conflict' @('-Prs', '11,13', '-Branches', 'br-b,br-c')
    $cw = Join-Path $root 'wt\conflict'
    Check 'conflict: exit 2, names the file, nothing tested' ($r.code -eq 2 -and $r.out -match 'PR #13 \(br-c\) conflicts in docs/readme\.txt; that merge was aborted' -and $r.j.verdict -eq 'REFUSED' -and -not @($r.j.suites).Count) $r.out
    Check 'conflict: the merge was aborted (no MERGE_HEAD, clean tree)' (-not ((& git -C $cw status --porcelain) -join '') -and -not (Test-Path -LiteralPath ((& git -C $cw rev-parse --path-format=absolute --git-path MERGE_HEAD) -join '')))

    # 7. bad input is refused with exit 2
    foreach ($bad in @(@{ n = 'no PRs'; a = @(); m = 'no PRs given' }, @{ n = 'count mismatch'; a = @('-Prs', '11,12', '-Branches', 'br-b'); m = '2 PR\(s\) but 1 branch' },
            @{ n = 'not a number'; a = @('-Prs', 'x'); m = 'not PR numbers: x' }, @{ n = 'twice'; a = @('-Prs', '11,11', '-Branches', 'br-b,br-b'); m = 'named twice' },
            @{ n = 'missing branch'; a = @('-Prs', '11', '-Branches', 'br-zzz'); m = 'could not fetch' }, @{ n = 'gh does not know the PR'; a = @('-Prs', '99'); m = "could not read PR #99's branch" },
            @{ n = 'bad branch name'; a = @('-Prs', '11', '-Branches', 'a..b'); m = 'not plain branch names' })) {
        $r = Invoke-Batch 'bad' $bad.a
        Check "refused: $($bad.n)" ($r.code -eq 2 -and $r.out -match $bad.m) $r.out
    }
    $o = & pwsh -NoProfile -File $batch -Repo $live -Name '..' -Prs 11 2>&1 | Out-String
    Check 'refused: a -Name that is not plain' ($LASTEXITCODE -eq 2 -and $o -match 'is not a plain name') $o
    # no -RemoteUrl: the remote is the repo's own kitchen.repo.json "github" (the repo's home moved to tide on 2026-10-26); none there = refused
    $noHome = Join-Path $root 'no-home'; New-Item -ItemType Directory -Force $noHome | Out-Null; & git init -q $noHome 2>&1 | Out-Null
    $o = & pwsh -NoProfile -File $batch -Repo $noHome -Name 'no-home' -Prs 11 2>&1 | Out-String
    Check 'refused: no -RemoteUrl and no github in the repo''s kitchen.repo.json' ($LASTEXITCODE -eq 2 -and $o -match 'kitchen\.repo\.json names no github owner/name') $o
    '{"github":"o/home"}' | Set-Content (Join-Path $noHome 'kitchen.repo.json')
    $echoGh = Join-Path $root 'echo-gh.cmd'; Set-Content $echoGh '@echo gh asked: %* 1>&2 & exit /b 1' -Encoding ascii   # (offline: says what it was asked, then fails)
    $o = & pwsh -NoProfile -File $batch -Repo $noHome -Name 'no-home' -Prs 11 -Gh $echoGh -Worktree (Join-Path $root 'wt\no-home') -OutDir (Join-Path $root 'out\no-home') 2>&1 | Out-String
    Check 'no -RemoteUrl: the slug and remote come from kitchen.repo.json github (gh is asked about o/home)' ($o -match 'gh asked: .*o/home' -and $o -notmatch 'brain-monitor') $o
    $o = & pwsh -NoProfile -File $batch -Repo $live -RemoteUrl $gh -Name 'live-as-wt' -Prs 11 -Branches br-b -Worktree $live -OutDir (Join-Path $root 'out\live-as-wt') 2>&1 | Out-String
    Check 'refused: the live checkout as the integration worktree' ($LASTEXITCODE -eq 2 -and $o -match 'cannot be the live checkout') $o

    # 8. -Merge never merges on RED
    Set-Case @{ BR_RED = '1' }
    $before = (G $live rev-parse HEAD).Trim()
    $r = Invoke-Batch 'red-merge' @('-Prs', '11', '-Branches', 'br-b', '-Merge')
    Check '-Merge on RED: refused, exit 1, merge-pr never called, live not moved' ($r.code -eq 1 -and $r.out -match 'land: REFUSED: the verdict is RED; nothing merged' -and
        -not (Merges).Count -and (G $live rev-parse HEAD).Trim() -eq $before) $r.out

    # 9. -Merge on GREEN: branches read through gh, merge-pr per PR in order with a -Why, live fast-forwarded, same tree, pass-app updated
    Set-Case
    $r = Invoke-Batch 'land' @('-Prs', '11,12', '-Merge')
    $m = Merges
    Check '-Merge GREEN: exit 0, merged #11 then #12' ($r.code -eq 0 -and $m.Count -eq 2 -and $m[0] -match '^o/r #11 batch-run integrate-land: tested together' -and $m[1] -match '^o/r #12 ') $r.out
    Check '-Merge GREEN: the live checkout is on the landed main' ((G $live rev-parse HEAD).Trim() -eq (G $gh rev-parse main).Trim() -and $r.out -match 'fast-forward: live checkout fast-forwarded')
    Check '-Merge GREEN: main tree is the tested tree; pass-app changed so update ran once' ($r.out -match "tree: main's tree is the tested tree" -and $r.j.tree.same -eq $true -and (Updates) -eq 1 -and $r.out -match 'pass-app: 1 pass-app file')

    # 10. a landed main whose tree is not the tested one is reported, exit 1; no pass-app change, no update
    Set-Case @{ BR_DRIFT = '1' }
    $r = Invoke-Batch 'drift' @('-Prs', '15', '-Branches', 'br-f', '-Merge')
    Check '-Merge: a different tree on main is reported, exit 1' ($r.code -eq 1 -and $r.out -match "tree: main's tree differs from the tested tree in: drift-15\.txt" -and (Updates) -eq 1 -and $r.out -match 'no pass-app file changed') $r.out

    # 11. main moved while the suites ran: nothing merged
    Set-Case @{ BR_MOVE = $mover }
    $n0 = (Merges).Count
    $r = Invoke-Batch 'moved' @('-Prs', '16', '-Branches', 'br-g', '-Merge')
    Check '-Merge: main moved since the test, refused, exit 2' ($r.code -eq 2 -and $r.out -match 'main moved from \w+ to \w+ since the batch was tested; nothing merged' -and (Merges).Count -eq $n0) $r.out

    # 12. merge-pr refuses the second PR: stop, say what merged
    Set-Case @{ BR_MERGE_FAIL = '18' }
    $r = Invoke-Batch 'stopped' @('-Prs', '17,18', '-Branches', 'br-h,br-i', '-Merge')
    Check '-Merge: merge-pr refuses #18, stops, names #17 as merged' ($r.code -eq 1 -and $r.out -match 'did not merge PR #18 \(exit 1: merge-pr: REFUSED' -and $r.out -match 'merged before it: #17' -and
        (@($r.j.merged) -join ',') -eq '17') $r.out
    # 13. a RED on a loaded PC (average CPU over 70%) says so, and -Merge still refuses it
    Set-Case @{ BR_RED = '1'; BR_LOAD = '90:8000' }
    $n0 = (Merges).Count
    $r = Invoke-Batch 'loaded-red' @('-Prs', '11', '-Branches', 'br-b', '-Merge')
    Check 'LOADED RED: "RED (loaded: re-run on a quiet PC)", exit 1, -Merge refused' ($r.code -eq 1 -and $r.out -match 'verdict: RED \(loaded: re-run on a quiet PC\): Test-Red' -and
        $r.j.verdict -eq 'RED' -and $r.j.verdictText -eq 'RED (loaded: re-run on a quiet PC)' -and $r.j.loaded -eq $true -and $r.out -match 'load: LOADED: average CPU 90% is over 70%' -and
        @($r.j.load.samples).Count -eq 8 -and $r.out -match 'land: REFUSED: the verdict is RED' -and (Merges).Count -eq $n0) $r.out
    # 14. low free RAM marks a green run LOADED; the thresholds are parameters
    Set-Case @{ BR_LOAD = '10:1000' }
    $r = Invoke-Batch 'loaded-ram' @('-Prs', '11', '-Branches', 'br-b')
    Check 'LOADED GREEN: free RAM under 2500 MB is marked, exit 0' ($r.code -eq 0 -and $r.out -match 'verdict: GREEN \(LOADED\): all 4' -and $r.out -match 'free RAM 1000 MB is under 2500 MB' -and $r.j.loaded -eq $true) $r.out
    Set-Case @{ BR_LOAD = '90:1000' }
    $r = Invoke-Batch 'thresholds' @('-Prs', '11', '-Branches', 'br-b', '-MaxCpuPercent', '95', '-MinFreeMB', '500')
    Check 'thresholds: -MaxCpuPercent 95 and -MinFreeMB 500 make 90% / 1000 MB not loaded' ($r.code -eq 0 -and $r.j.loaded -eq $false -and $r.j.load.maxCpuPercent -eq 95 -and $r.j.verdictText -eq 'GREEN') $r.out
    # 15. a probe that fails is unknown, never LOADED
    Set-Case @{ BR_LOAD = 'fail' }
    $r = Invoke-Batch 'no-probe' @('-Prs', '11', '-Branches', 'br-b')
    Check 'a failing probe: load unknown, not LOADED' ($r.code -eq 0 -and $r.out -match 'load: at start: load unknown' -and $r.out -match 'load: not loaded: load unknown' -and $r.j.loaded -eq $false) $r.out
} finally {
    foreach ($e in $envNames) { [Environment]::SetEnvironmentVariable($e, $saved[$e]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Test-BatchRun: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
exit 0
