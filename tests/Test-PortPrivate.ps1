# Tests for scripts/port-private.ps1: a private pull request ported to tide as the cleaned diff of its merge-base and its head, applied
# three-way on tide main, scanned, committed as Jordan's noreply identity, pushed and opened as a PR. GitHub is played by the fake gh
# (tests/fixtures/fake-gh.ps1) over two local bare repos (the private repo and tide), the cleaning and the scan by
# tests/fixtures/fake-port-clean.ps1 and fake-port-scan.ps1 (the real ones read this PC's private values), so no test touches the
# network. Every private value here is synthetic: PRIVATE-NAME (cleaned to public-name) and LIVE-VALUE (a live scan hit).
# Self-cleaning: one temp folder only.
$ErrorActionPreference = 'Stop'
$tool = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\port-private.ps1')).Path
$fx = Join-Path $PSScriptRoot 'fixtures'
$root = Join-Path ([IO.Path]::GetTempPath()) ('tpp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$repo = Join-Path $root 'co'; $priv = Join-Path $root 'priv.git'; $tide = Join-Path $root 'tide.git'; $gh = Join-Path $root 'gh'; $wtRoot = Join-Path $root 'wt'
$privSlug = 'JVonBorstel/brain-monitor'; $tideSlug = 'JVonBorstel/tide'
$noreply = '204934145+JVonBorstel@users.noreply.github.com'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function G { & git -C $repo -c user.name=t -c user.email=t@localhost @args 2>&1 | Out-Null }
function Ref([string]$bare, [string]$ref) { "$(& git -C $bare rev-parse --verify --quiet $ref 2>$null)".Trim() }
function Show([string]$bare, [string]$spec) { (& git -C $bare show $spec 2>$null) -join "`n" }
$pw = (Get-Process -Id $PID).Path
function Port([int]$n, [string[]]$more = @()) {
    $o = & $pw -NoProfile -File $tool -Pr $n -Repo $repo -WorktreeRoot $wtRoot -CleanScript (Join-Path $fx 'fake-port-clean.ps1') -ScanScript (Join-Path $fx 'fake-port-scan.ps1') -StageRoot $root -AuthorName 'Test Owner' @more 2>&1 | Out-String
    [pscustomobject]@{ code = $LASTEXITCODE; out = $o }
}
function Prs([string]$slug) { @((Get-Content (Join-Path $gh 'prs.json') -Raw | ConvertFrom-Json).prs | Where-Object repo -eq $slug) }
# a private branch from the old main with one commit: files to write (name -> text) and to delete
function PrivBranch([string]$name, [hashtable]$write, [string[]]$delete = @(), [switch]$Empty) {
    G checkout -q -b $name pmain
    foreach ($k in $write.Keys) { $p = Join-Path $repo $k; New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null; [IO.File]::WriteAllText($p, $write[$k]) }
    foreach ($d in $delete) { G rm -q $d }
    G add -A; if ($Empty) { G commit -q --allow-empty -m "empty $name" } else { G commit -q -m "private $name" }
    G push -q private "${name}:$name"; G checkout -q pmain
    ([string](& git -C $repo rev-parse $name)).Trim()
}
function AddPrivPr([int]$n, [string]$branch, [string]$title, [string]$body, [string]$state = 'OPEN') {
    $db = Get-Content (Join-Path $gh 'prs.json') -Raw | ConvertFrom-Json -AsHashtable
    $db.prs = @($db.prs) + @(@{ repo = $privSlug; number = $n; url = "https://github.com/$privSlug/pull/$n"; state = $state; headRefName = $branch; title = $title; body = $body; bare = $priv; headRefOid = (Ref $priv "refs/heads/$branch") })
    $db | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $gh 'prs.json')
}

$saved = @{}; foreach ($v in 'BRAIN_KITCHEN', 'KITCHEN_GH', 'FAKE_GH_DIR', 'FAKE_GH_BARE', 'FAKE_SCAN_FAIL', 'TIDE_PORT_CLEAN', 'TIDE_PORT_SCAN', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
try {
    New-Item -ItemType Directory -Force -Path $repo, $gh, (Join-Path $root 'kitchen') | Out-Null
    $env:BRAIN_KITCHEN = Join-Path $root 'kitchen'; $env:KITCHEN_GH = Join-Path $fx 'fake-gh.ps1'; $env:FAKE_GH_DIR = $gh; $env:FAKE_GH_BARE = $tide; $env:FAKE_SCAN_FAIL = $null
    $env:TIDE_PORT_CLEAN = $null; $env:TIDE_PORT_SCAN = $null
    # the bare repos are reached through git's ext:: transport, as in Test-PrFlow (a plain path starts MSYS sh.exe, which the kitchen's
    # sandbox cannot run); turned on for this suite only
    $env:GIT_CONFIG_COUNT = '1'; $env:GIT_CONFIG_KEY_0 = 'protocol.ext.allow'; $env:GIT_CONFIG_VALUE_0 = 'always'
    Set-Content (Join-Path $gh 'repos.txt') "$privSlug`n$tideSlug"
    @{ next = 1; prs = @() } | ConvertTo-Json | Set-Content (Join-Path $gh 'prs.json')
    & git init -q --bare -b main $priv 2>&1 | Out-Null; & git init -q --bare -b main $tide 2>&1 | Out-Null
    & git -C $repo init -q -b pmain 2>&1 | Out-Null
    G remote add private "ext::git %s $($priv -replace '\\', '/')"; G remote add origin "ext::git %s $($tide -replace '\\', '/')"

    # the old private main: a private word in a.txt
    [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), "line1`nhello PRIVATE-NAME`nline3`n"); [IO.File]::WriteAllText((Join-Path $repo 'b.txt'), "bee`n"); [IO.File]::WriteAllText((Join-Path $repo 'c.txt'), "sea`n")
    G add -A; G commit -q -m 'private main'; G push -q private pmain:main; G branch private-main pmain
    # tide: the cleaned first commit (no shared history), then a tide-only commit that a port must never revert
    G checkout -q --orphan tmain; [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), "line1`nhello public-name`nline3`n")
    G add -A; G commit -q -m 'tide first commit'
    [IO.File]::WriteAllText((Join-Path $repo 'c.txt'), "sea`ntide edit`n"); [IO.File]::WriteAllText((Join-Path $repo 'tide.txt'), "tide only`n")
    G add -A; G commit -q -m 'tide-only commit'; G push -q origin tmain:main
    $tideMain = Ref $tide 'refs/heads/main'
    G checkout -q pmain

    $h1 = PrivBranch 'feat1' @{ 'a.txt' = "line1`nhello PRIVATE-NAME`nline3`nnew PRIVATE-NAME line`n"; 'new.txt' = "new`n" } @('b.txt')
    AddPrivPr 1 'feat1' 'Feature one for PRIVATE-NAME' 'Body text with PRIVATE-NAME.'

    # ---- 1. the port: cleaned diff, applied on tide main, committed as the noreply identity, pushed, PR opened, private PR commented
    $r = Port 1 @('-Comment', '-Trailer', 'Co-Authored-By: Test <t@localhost>')
    Check 'port: exit 0, a tide PR opened' ($r.code -eq 0 -and $r.out -match "PR opened: https://github.com/$tideSlug/pull/1")
    $tip = Ref $tide 'refs/heads/port/feat1'
    Check 'port: the branch port/feat1 is on tide, one commit on tide main' ($tip -and (Ref $tide "$tip~1") -eq $tideMain)
    Check 'port: the private change arrives cleaned (a.txt)' ((Show $tide "${tip}:a.txt") -eq "line1`nhello public-name`nline3`nnew public-name line")
    Check 'port: an added file is added, a deleted file is deleted' ((Show $tide "${tip}:new.txt") -eq 'new' -and -not (Ref $tide "${tip}:b.txt"))
    Check "port: tide-only commits stay (tide.txt, c.txt's tide edit)" ((Show $tide "${tip}:tide.txt") -eq 'tide only' -and (Show $tide "${tip}:c.txt") -eq "sea`ntide edit")
    Check 'port: no private word anywhere in the ported tree' (-not (& git -C $tide grep -l 'PRIVATE-NAME' $tip 2>$null))
    $note = Show $tide "${tip}:docs/changes/port-1.md"
    Check 'port: a change note docs/changes/port-1.md links the private PR, carries its cleaned description and an L1-L4 line' ($note -match '^# Port #1: Feature one for public-name' -and $note -match "pull/1\) at ``$h1``" -and $note -match 'Body text with public-name' -and $note -match '## L1-L4' -and $note -notmatch 'PRIVATE-NAME')
    Check 'port: author and committer are the noreply identity' ((& git -C $tide log -1 --format='%ae|%ce|%an' $tip) -eq "$noreply|$noreply|Test Owner")
    $msg = (& git -C $tide log -1 --format=%B $tip) -join "`n"
    Check 'port: the commit message names the private PR and its head commit' ($msg -match '^Port #1: Feature one for public-name' -and $msg -match "$([regex]::Escape($privSlug))#1 at $h1" -and $msg -notmatch 'PRIVATE-NAME')
    Check 'port: a -Trailer line ends the commit message' ($msg.TrimEnd() -match 'Co-Authored-By: Test <t@localhost>$')
    $p1 = @(Prs $tideSlug)[0]
    Check 'port: the PR is against main from port/feat1, titled from the cleaned private title' ($p1.headRefName -eq 'port/feat1' -and $p1.title -eq 'Port #1: Feature one for public-name')
    Check 'port: the PR body links the private PR, names its head, lists the files' ($p1.body -match "https://github.com/$([regex]::Escape($privSlug))/pull/1" -and $p1.body -match $h1 -and $p1.body -match '- added: `new.txt`' -and $p1.body -match '- deleted: `b.txt`')
    Check "port: the PR body carries the private description, cleaned; no private word" ($p1.body -match 'Body text with public-name' -and $p1.body -notmatch 'PRIVATE-NAME' -and $p1.body -match '0 live hits')
    Check 'port: the private PR got a comment with the tide PR link' (@((Prs $privSlug | Where-Object number -eq 1).comments) -match "$tideSlug/pull/1")
    Check 'port: the worktree is kept on the branch' ((& git -C (Join-Path $wtRoot 'port-feat1') symbolic-ref --short HEAD) -eq 'port/feat1')
    $pl = @(Get-Content (Join-Path $root 'kitchen\ports.jsonl') | ConvertFrom-Json)
    Check 'port: ports.jsonl records the port (pr, private head, branch, commit, url)' ($pl.Count -eq 1 -and $pl[0].pr -eq 1 -and $pl[0].privateHead -eq $h1 -and $pl[0].branch -eq 'port/feat1' -and $pl[0].commit -eq $tip -and $pl[0].url -match '/pull/1$')
    Check 'port: the private PR is left open' ((Prs $privSlug | Where-Object number -eq 1).state -eq 'OPEN')

    # ---- 2. again: a port that began is never redone over itself; -Continue reuses the PR
    $r = Port 1
    Check 'again: the branch exists -> refused (1), still one tide PR' ($r.code -eq 1 -and $r.out -match 'already exists here' -and @(Prs $tideSlug).Count -eq 1)
    $r = Port 1 @('-Continue')
    Check 'again: -Continue after a done port -> PR reused (0), same commit, one PR' ($r.code -eq 0 -and $r.out -match 'PR reused' -and (Ref $tide 'refs/heads/port/feat1') -eq $tip -and @(Prs $tideSlug).Count -eq 1)

    # ---- 3. a live value in a changed file: refused, nothing pushed, the value never printed
    $null = PrivBranch 'feat-live' @{ 'leak.txt' = "token LIVE-VALUE`n" }; AddPrivPr 2 'feat-live' 'Leak' ''
    $r = Port 2
    Check 'live: refused (1), names the class and the file' ($r.code -eq 1 -and $r.out -match 'LIVE:test in leak\.txt')
    Check 'live: nothing pushed, no PR, the value not printed' (-not (Ref $tide 'refs/heads/port/feat-live') -and @(Prs $tideSlug).Count -eq 1 -and $r.out -notmatch 'LIVE-VALUE')

    # ---- 4. a conflict with a tide-only commit: refused with the worktree kept; fixed by hand, then -Continue opens the PR
    $null = PrivBranch 'feat-conflict' @{ 'c.txt' = "sea changed`n" }; AddPrivPr 3 'feat-conflict' 'Change c' 'c body'
    $r = Port 3
    $w3 = Join-Path $wtRoot 'port-feat-conflict'
    Check 'conflict: refused (1), names c.txt, keeps the worktree, nothing pushed' ($r.code -eq 1 -and $r.out -match 'conflicts with tide main in: c\.txt' -and (Test-Path $w3) -and -not (Ref $tide 'refs/heads/port/feat-conflict'))
    $r = Port 3 @('-Continue')
    Check 'conflict: -Continue before the fix -> refused (unmerged files)' ($r.code -eq 1 -and $r.out -match 'unmerged')
    [IO.File]::WriteAllText((Join-Path $w3 'c.txt'), "sea changed`ntide edit`n"); & git -C $w3 add c.txt 2>&1 | Out-Null
    $r = Port 3 @('-Continue')
    $t3 = Ref $tide 'refs/heads/port/feat-conflict'
    Check 'conflict: after the hand fix, -Continue commits, pushes and opens the PR' ($r.code -eq 0 -and $t3 -and (Show $tide "${t3}:c.txt") -eq "sea changed`ntide edit" -and (Ref $tide "$t3~1") -eq $tideMain -and @(Prs $tideSlug).Count -eq 2)

    # ---- 5. a live value in the private title or description: that text is left out, the port goes on
    $null = PrivBranch 'feat-title' @{ 'x.txt' = "x`n" }; AddPrivPr 4 'feat-title' 'Title with LIVE-VALUE' 'Body with LIVE-VALUE'
    $r = Port 4
    $p4 = Prs $tideSlug | Where-Object headRefName -eq 'port/feat-title'
    Check 'text: exit 0; a neutral title; the description left out, saying why' ($r.code -eq 0 -and $p4.title -eq 'Port of private PR #4' -and $p4.body -match 'Left out: the privacy scan found a private value' -and $p4.body -notmatch 'LIVE-VALUE')
    $t4 = Ref $tide 'refs/heads/port/feat-title'
    Check 'text: the commit message and the change note have neither' (((& git -C $tide log -1 --format=%B $t4) -join "`n") -notmatch 'LIVE-VALUE' -and (Show $tide "${t4}:docs/changes/port-4.md") -match '(?s)^# Port of private PR #4.*Left out: the privacy scan' -and (Show $tide "${t4}:docs/changes/port-4.md") -notmatch 'LIVE-VALUE')

    # ---- 6. the cleaning needs a hand fix (R4): refused before anything is made
    $null = PrivBranch 'feat-hand' @{ 'h.txt' = "HAND-FIX`n" }; AddPrivPr 5 'feat-hand' 'Hand' ''
    $r = Port 5
    Check 'hand fix: refused (1), says so, no worktree, no branch' ($r.code -eq 1 -and $r.out -match 'needs a hand fix' -and -not (Test-Path (Join-Path $wtRoot 'port-feat-hand')) -and -not (& git -C $repo rev-parse --verify --quiet 'refs/heads/port/feat-hand'))

    # ---- 7. a cleaning-patch hunk that applies on the merge-base but not on the head: refused unless a person read it
    $null = PrivBranch 'feat-reject' @{ 'r.txt' = "REJECT-ME`n" }; AddPrivPr 6 'feat-reject' 'Reject' ''
    $r = Port 6
    Check 'reject: refused (1), names r.txt, nothing made' ($r.code -eq 1 -and $r.out -match 'would undo them in: r\.txt' -and -not (Test-Path (Join-Path $wtRoot 'port-feat-reject')))
    $r = Port 6 @('-AcceptRejects', '-NoPush')
    Check 'reject: -AcceptRejects -NoPush commits locally, pushes nothing, opens no PR' ($r.code -eq 0 -and $r.out -match 'NOT PUSHED' -and (& git -C $repo rev-parse --verify --quiet 'refs/heads/port/feat-reject') -and -not (Ref $tide 'refs/heads/port/feat-reject') -and -not (Prs $tideSlug | Where-Object headRefName -eq 'port/feat-reject'))
    $r = Port 6 @('-Continue')
    $p6 = Prs $tideSlug | Where-Object headRefName -eq 'port/feat-reject'
    Check 'reject: -Continue then pushes the commit and opens the PR naming the accepted file' ($r.code -eq 0 -and $p6 -and $p6.body -match 'accepted after a read.*r\.txt')

    # ---- 8. a non-live class that is new: refused; -Allow (a person checked it) lets it through on -Continue
    $null = PrivBranch 'feat-job' @{ 'j.txt' = "a job hunt line`n" }; AddPrivPr 7 'feat-job' 'Job' ''
    $r = Port 7
    Check 'class: a new job-words hit -> refused (1), worktree kept, nothing pushed' ($r.code -eq 1 -and $r.out -match 'job-words in j\.txt \(\+1 new\)' -and (Test-Path (Join-Path $wtRoot 'port-feat-job')) -and -not (Ref $tide 'refs/heads/port/feat-job'))
    $r = Port 7 @('-Continue', '-Allow', 'job-words')
    $p7 = Prs $tideSlug | Where-Object headRefName -eq 'port/feat-job'
    Check 'class: -Continue -Allow job-words -> opened, the body says it was allowed' ($r.code -eq 0 -and $p7 -and $p7.body -match 'allowed by a person: job-words in j\.txt')
    $r = Port 2 @('-Continue', '-Allow', 'LIVE:*')
    Check 'class: -Allow never lets a live hit through' ($r.code -eq 1 -and $r.out -match 'LIVE:test in leak\.txt' -and -not (Ref $tide 'refs/heads/port/feat-live'))

    # ---- 9. nothing to port, a closed PR, a failed scan, a missing cleaning script
    $null = PrivBranch 'feat-none' @{} -Empty; AddPrivPr 8 'feat-none' 'None' ''
    $r = Port 8
    Check 'nothing: a branch that changes nothing after cleaning -> refused (1)' ($r.code -eq 1 -and $r.out -match 'changes nothing' -and -not (Test-Path (Join-Path $wtRoot 'port-feat-none')))
    $null = PrivBranch 'feat-closed' @{ 'k.txt' = "k`n" }; AddPrivPr 9 'feat-closed' 'Closed' '' 'CLOSED'
    $r = Port 9
    Check 'closed: a closed private PR -> refused (1)' ($r.code -eq 1 -and $r.out -match 'is CLOSED, not open')
    $null = PrivBranch 'feat-scan' @{ 's.txt' = "s`n" }; AddPrivPr 10 'feat-scan' 'Scan' ''
    $env:FAKE_SCAN_FAIL = '1'; $r = Port 10; $env:FAKE_SCAN_FAIL = $null
    Check 'scan: a scan that fails -> exit 2, nothing pushed (never ported unscanned)' ($r.code -eq 2 -and $r.out -match 'privacy scan failed' -and -not (Ref $tide 'refs/heads/port/feat-scan'))
    $o = & $pw -NoProfile -File $tool -Pr 10 -Repo $repo -WorktreeRoot $wtRoot -CleanScript (Join-Path $root 'nope.ps1') -ScanScript (Join-Path $fx 'fake-port-scan.ps1') 2>&1 | Out-String
    Check 'clean: a missing cleaning script -> exit 2, says so' ($LASTEXITCODE -eq 2 -and $o -match 'cleaning or scan script is missing')
    Check 'never: no tide branch was force-moved (port/feat1 still at its commit)' ((Ref $tide 'refs/heads/port/feat1') -eq $tip -and (Ref $tide 'refs/heads/main') -eq $tideMain)
}
finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    if (Test-Path -LiteralPath $repo) { & git -C $repo worktree prune 2>&1 | Out-Null }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PortPrivate tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
