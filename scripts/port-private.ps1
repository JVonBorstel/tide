# Port one pull request from the private repo to tide, the public home (2026-10-26 cut-over: the private repo is on a GitHub billing
# hold, so nothing merges there). One script, the same cleaning and the same privacy scan every time: no hand copies.
#   pwsh -File scripts/port-private.ps1 -Pr N [-Branch port/x] [-NoPush] [-Comment] [-Continue] [-Allow class,...] [-AcceptRejects]
# Method (never replaces the whole tree, which would revert tide-only commits):
#   1. Read private PR N (gh), fetch its head branch B from the private remote and check it is the PR's head commit.
#   2. M = merge-base(B, private-main). Clean the trees of M and of B with the public cleaning (R1-R9; the ONE implementation is
#      public-tide-clean.ps1 beside the scan in the brain's projects/tide/audits, outside this repo because its rules name the private values).
#   3. Diff cleaned(M) -> cleaned(B) and `git apply -3` that patch onto a new branch (default port/<B>) from tide main, in its own
#      worktree (<WorktreeRoot>/port-<B>, slashes as dashes). A conflict stops here: the worktree is kept for a hand fix, then run again with -Continue.
#   4. Privacy scan (public-tide-scan.ps1 -Json) of every changed file, the commit message and the PR text, against the same files on
#      tide main. Any live hit (LIVE:*, owner-full-name, project-name) refuses; another class that is new in a changed file refuses
#      unless -Allow names it (a person read it). A live hit only in the private PR's title or description drops that text instead.
#   5. Commit as the owner's name (-AuthorName, else git config user.name) and Jordan's noreply email (-AuthorEmail), naming the private PR and its head commit; push the branch (never forced); open the PR on
#      tide (or reuse the open one) with a body that links the private PR; -Comment also links the tide PR on the private PR.
#   6. One line per port in ports.jsonl in the kitchen state folder (BRAIN_KITCHEN, else %LOCALAPPDATA%\brain-kitchen).
# A cleaning-patch hunk that applies on M but not on B would be undone by the diff, so it refuses and names the files, unless
# -AcceptRejects (a person read those files' diffs, e.g. with -NoPush).
# Nothing is ever deleted, closed or force-pushed: the port worktree and branch are kept; only this run's temp stage folders are removed.
# The state of a port (for -Continue) is <git common dir>/port-private/pr-<N>.json, outside every tree.
# Exit: 0 PR opened or reused (or committed, with -NoPush); 1 refused (the reason is printed; nothing pushed); 2 bad input or a tool failed.
param(
    [Parameter(Mandatory)][ValidateRange(1, 999999)][int]$Pr,
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$PrivateRepo = 'JVonBorstel/brain-monitor',
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$TideRepo = 'JVonBorstel/tide',
    [string]$Repo = '',                 # the checkout whose remotes are tide and the private repo (default: this script's main checkout)
    [string]$PrivateRemote = 'private',
    [string]$TideRemote = 'origin',
    [string]$PrivateMain = 'private-main',
    [string]$Base = 'main',
    [string]$Branch = '',               # the tide branch (default port/<private head branch>)
    [string]$WorktreeRoot = '',         # default: the folder beside the checkout named wt
    [string]$CleanScript = '',          # default: TIDE_PORT_CLEAN, else <profile>\gemini-brain\projects\tide\audits\public-tide-clean.ps1
    [string]$ScanScript = '',           # default: TIDE_PORT_SCAN, else public-tide-scan.ps1 beside it
    [string]$StageRoot = '',            # default: the temp folder (keep it short: Windows paths stop at 260 characters)
    [string[]]$Allow = @(),
    [string[]]$Trailer = @(),           # extra commit-message trailer lines (e.g. Co-Authored-By)
    [string]$AuthorName = '',          # default: git config user.name of the checkout (the name is never written into a file)
    [string]$AuthorEmail = '204934145+JVonBorstel@users.noreply.github.com',
    [switch]$AcceptRejects,
    [switch]$Continue,
    [switch]$NoPush,
    [switch]$Comment
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\kitchen\github-lib.ps1')
$pw = (Get-Process -Id $PID).Path
$utf8 = [Text.UTF8Encoding]::new($false)
$liveRx = '^(LIVE:.*|owner-full-name|project-name)$'
function Say([string]$m) { Write-Output "port-private: $m" }
function Refuse([string]$why) { Write-Output "port-private: REFUSED private #${Pr}: $why"; exit 1 }
function Broken([string]$why) { Write-Output "port-private: FAILED private #${Pr}: $why"; exit 2 }
# git in a folder: { code, out } (stderr folded in), never throws
function G([string]$Dir, [string[]]$A) { $o = & git -C $Dir @A 2>&1; [pscustomobject]@{ code = $LASTEXITCODE; out = (($o | ForEach-Object { "$_" }) -join "`n").Trim() } }
function Sha([string]$Dir, [string]$Rev) { $r = G $Dir @('rev-parse', '--verify', '--quiet', "$Rev^{commit}"); if ($r.code) { '' } else { $r.out } }
function Short([string]$s) { if ($s.Length -ge 7) { $s.Substring(0, 7) } else { $s } }

# ---- inputs
if (-not $Repo) {
    $cd = G $PSScriptRoot @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if ($cd.code) { Broken "cannot find this script's checkout ($($cd.out)); pass -Repo" }
    $Repo = Split-Path -Parent $cd.out
}
if (-not (Test-Path -LiteralPath $Repo)) { Broken "no checkout at $Repo" }
$Repo = (Resolve-Path -LiteralPath $Repo).Path
$gitDir = (G $Repo @('rev-parse', '--path-format=absolute', '--git-common-dir')).out
if (-not $WorktreeRoot) { $WorktreeRoot = Join-Path (Split-Path -Parent $Repo) 'wt' }
$audits = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain\projects\tide\audits'
if (-not $CleanScript) { $CleanScript = if ($env:TIDE_PORT_CLEAN) { $env:TIDE_PORT_CLEAN } else { Join-Path $audits 'public-tide-clean.ps1' } }
if (-not $ScanScript) { $ScanScript = if ($env:TIDE_PORT_SCAN) { $env:TIDE_PORT_SCAN } else { Join-Path (Split-Path -Parent $CleanScript) 'public-tide-scan.ps1' } }
foreach ($s in $CleanScript, $ScanScript) { if (-not (Test-Path -LiteralPath $s)) { Broken "the cleaning or scan script is missing: $s (nothing reaches tide uncleaned or unscanned)" } }
if (-not $StageRoot) { $StageRoot = [IO.Path]::GetTempPath() }
if (-not $AuthorName) { $AuthorName = (G $Repo @('config', 'user.name')).out }
if (-not $AuthorName) { Broken 'no author name: pass -AuthorName or set git config user.name' }
$stateDir = Join-Path $gitDir 'port-private'; $statePath = Join-Path $stateDir "pr-$Pr.json"

# ---- 1. the private PR and its head commit
$v = Invoke-GhJson @('pr', 'view', "$Pr", '-R', $PrivateRepo, '--json', 'number,url,title,body,state,headRefName,headRefOid,baseRefName')
if (-not $v.ok) { Broken "could not read $PrivateRepo#$Pr from GitHub ($(Get-GhWhy $v))" }
$info = $v.json
if ([string]$info.state -ne 'OPEN') { Refuse "$PrivateRepo#$Pr is $($info.state), not open" }
$head = [string]$info.headRefName; $B = [string]$info.headRefOid
if ($B -notmatch '^[0-9a-f]{40,64}$' -or -not $head) { Broken 'GitHub did not say which branch and commit the PR is at' }
$f = G $Repo @('fetch', '-q', $PrivateRemote, "+refs/heads/${head}:refs/remotes/$PrivateRemote/$head")
if ($f.code) { Broken "could not fetch $head from the remote '$PrivateRemote' ($($f.out))" }
$fetched = Sha $Repo "refs/remotes/$PrivateRemote/$head"
if ($fetched -ne $B) { Refuse "the branch $head is at $(Short $fetched) on '$PrivateRemote' but the PR says $(Short $B) (a push in between?); run again" }
if (-not $Branch) { $Branch = "port/$head" }
if ((G $Repo @('check-ref-format', '--branch', $Branch)).code) { Broken "'$Branch' is not a valid branch name" }
$wt = Join-Path $WorktreeRoot (($Branch -replace '^port/', 'port-') -replace '[^A-Za-z0-9._-]', '-')

# ---- 2. tide main, the merge-base, the cleaned trees, the patch (skipped by -Continue, which reads the saved state)
$state = $null
if ($Continue) {
    if (-not (Test-Path -LiteralPath $statePath)) { Refuse "-Continue: no saved port for #$Pr ($statePath); run without -Continue first" }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.privateHead -ne $B) { Refuse "-Continue: the private PR moved from $(Short $state.privateHead) to $(Short $B) since the port began; start a new port with -Branch <new name>" }
    $Branch = $state.branch; $wt = $state.worktree
    if (-not (Test-Path -LiteralPath $wt)) { Refuse "-Continue: the port worktree $wt is gone" }
    if ((G $wt @('symbolic-ref', '--short', 'HEAD')).out -ne $Branch) { Refuse "-Continue: $wt is not on $Branch" }
    $baseSha = $state.base; $M = $state.mergeBase
    Say "continuing $Branch in $wt (private #$Pr at $(Short $B), on tide $Base $(Short $baseSha))"
} else {
    $f = G $Repo @('fetch', '-q', $TideRemote, "+refs/heads/${Base}:refs/remotes/$TideRemote/$Base")
    if ($f.code) { Broken "could not fetch $Base from the remote '$TideRemote' ($($f.out))" }
    $baseSha = Sha $Repo "refs/remotes/$TideRemote/$Base"
    $pm = Sha $Repo $PrivateMain; if (-not $pm) { Broken "no '$PrivateMain' in $Repo (the old private main)" }
    $mb = G $Repo @('merge-base', $B, $pm); if ($mb.code) { Refuse "$head has no merge-base with $PrivateMain" }
    $M = $mb.out
    if ($M -eq $B) { Refuse "$head has nothing that $PrivateMain lacks; nothing to port" }
    if ((Sha $Repo "refs/heads/$Branch")) { Refuse "the branch $Branch already exists here (a port began before? run again with -Continue, or pick -Branch)" }
    $lr = G $Repo @('ls-remote', '--heads', $TideRemote, "refs/heads/$Branch")
    if ($lr.code) { Broken "could not ask '$TideRemote' about $Branch ($($lr.out))" }
    if ($lr.out) { Refuse "the branch $Branch already exists on '$TideRemote'; pick -Branch" }
    if (Test-Path -LiteralPath $wt) { Refuse "the folder $wt already exists; pick -Branch or -WorktreeRoot" }
    Say "private #$Pr $head at $(Short $B); merge-base $(Short $M)$(if ($M -ne $pm) { " (older than $PrivateMain $(Short $pm))" }); tide $Base at $(Short $baseSha)"

    $stage = Join-Path $StageRoot ('pp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        # clean a commit into a folder with the one cleaning; returns its cleaned tree (objects written to this repo, no ref made)
        function Clean-Tree([string]$Sha, [string]$Name) {
            $out = Join-Path $stage $Name
            $o = & $pw -NoProfile -File $CleanScript -Ref $Sha -Out $out -Checkout $Repo 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE
            if ($code -eq 3) { Refuse "the cleaning needs a hand fix in $Name ($(Short $Sha)): $(($o | Where-Object { $_ -match 'HAND FIX' }) -join '; ')" }
            if ($code) { Broken "the cleaning of $Name ($(Short $Sha)) failed (exit $code): $((@($o) | Select-Object -Last 3) -join ' | ')" }
            $rej = @($o | Where-Object { $_ -match '^dropped reject[^:]*: (.+)$' } | ForEach-Object { ($_ -replace '^dropped reject[^:]*: ', '').Trim() -replace '\\', '/' })
            $env:GIT_INDEX_FILE = Join-Path $stage "$Name.index"
            try {
                $a = G $out @('--git-dir', $gitDir, '--work-tree', $out, 'add', '-A', '-f', '.')
                if ($a.code) { Broken "could not read the cleaned $Name into git ($($a.out))" }
                $t = G $out @('--git-dir', $gitDir, '--work-tree', $out, 'write-tree')
                if ($t.code) { Broken "could not write the cleaned $Name tree ($($t.out))" }
            } finally { $env:GIT_INDEX_FILE = $null }
            [pscustomobject]@{ tree = $t.out; rejects = $rej }
        }
        $cM = Clean-Tree $M 'base'; $cB = Clean-Tree $B 'head'
        $newRejects = @($cB.rejects | Where-Object { $_ -notin $cM.rejects })
        if ($newRejects.Count -and -not $AcceptRejects) { Refuse "cleaning-patch hunks that applied on the merge-base did not apply on the head, so the port would undo them in: $($newRejects -join ', '). Read those files' diff (run with -NoPush -AcceptRejects) before porting" }
        $patch = Join-Path $stage 'port.patch'
        $d = G $Repo @('diff-tree', '-r', '-p', '--binary', '--full-index', '--no-renames', "--output=$patch", $cM.tree, $cB.tree)
        if ($d.code) { Broken "could not diff the cleaned trees ($($d.out))" }
        if (-not (Test-Path -LiteralPath $patch) -or (Get-Item -LiteralPath $patch).Length -eq 0) { Refuse "after cleaning, $head changes nothing; nothing to port" }

        # ---- 3. a new branch from tide main in its own worktree; the patch applied three-way (tide-only commits stay)
        New-Item -ItemType Directory -Force -Path $WorktreeRoot | Out-Null
        $a = G $Repo @('worktree', 'add', '-q', '--no-track', '-b', $Branch, $wt, $baseSha)
        if ($a.code) { Broken "could not make the worktree $wt ($($a.out))" }
        $state = [ordered]@{ pr = $Pr; privateRepo = $PrivateRepo; privateUrl = [string]$info.url; privateHead = $B; mergeBase = $M; base = $baseSha
            branch = $Branch; worktree = $wt; cleanedBase = $cM.tree; cleanedHead = $cB.tree; rejects = @($cB.rejects); newRejects = @($newRejects); at = [DateTime]::UtcNow.ToString('o') }
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5), $utf8)
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $ap = G $wt @('apply', '-3', $patch)
        if ($ap.code) {
            $u = @((G $wt @('diff', '--name-only', '--diff-filter=U')).out -split "`n" | Where-Object { $_ })
            if ($u.Count) { Refuse "the port conflicts with tide $Base in: $($u -join ', '). The worktree $wt is kept: fix those files, git add them, then run again with -Continue" }
            Broken "git apply -3 failed in $wt ($($ap.out))"
        }
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- 4. the privacy scan, the change note, the commit (unless this port's commit is already there)
$tip = Sha $wt 'HEAD'
$committed = $tip -ne $baseSha
if ($committed -and (Sha $wt 'HEAD~1') -ne $baseSha) { Refuse "$Branch in $wt has more than the port's one commit on $(Short $baseSha); finish it by hand" }
if (-not $committed -and (G $wt @('ls-files', '-u')).out) { Refuse "$wt still has unmerged files; fix them and git add them, then run -Continue" }
$pat = Join-Path $wt 'scripts\secret-patterns.ps1'
function Scan([string]$Root) {
    $o = & $pw -NoProfile -File $ScanScript -Root $Root -Json -Patterns $pat 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE
    $j = $o | Where-Object { $_ -match '^\{' } | Select-Object -Last 1
    if ($code -or -not $j) { Broken "the privacy scan failed (exit $code): $((@($o) | Select-Object -Last 3) -join ' | ')" }
    try { $j | ConvertFrom-Json } catch { Broken "the privacy scan's JSON did not read: $($_.Exception.Message)" }
}
# hits counted per class and file: { "<class>|<file with forward slashes>": n }
function Count-Hits($scan) { $c = @{}; foreach ($h in @($scan.hits)) { $k = "$($h.class)|$($h.file -replace '\\', '/')"; $c[$k] = 1 + [int]$c[$k] }; $c }

$cleanTitle = ([string]$info.title -replace '[\r\n]+', ' ').Trim(); $cleanBody = [string]$info.body
$stage = Join-Path $StageRoot ('pp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    # the private PR's own words, through the same text rules (R1, R3, R8) as the code, then scanned: any hit leaves that text out
    $tx = Join-Path $stage 'text'; New-Item -ItemType Directory -Force -Path $tx | Out-Null
    [IO.File]::WriteAllText((Join-Path $tx 'title.md'), $cleanTitle, $utf8); [IO.File]::WriteAllText((Join-Path $tx 'body.md'), $cleanBody, $utf8)
    $null = & $pw -NoProfile -File $CleanScript -RulesOnly $tx 2>&1
    $cleanTitle = [IO.File]::ReadAllText((Join-Path $tx 'title.md')).Trim(); $cleanBody = [IO.File]::ReadAllText((Join-Path $tx 'body.md')).Trim()
    $textHits = Count-Hits (Scan $tx)
    $dropTitle = [bool]@($textHits.Keys | Where-Object { $_ -like '*|title.md' }).Count
    $dropBody = [bool]@($textHits.Keys | Where-Object { $_ -like '*|body.md' }).Count
    $title = if ($dropTitle -or -not $cleanTitle) { "Port of private PR #$Pr" } else { "Port #${Pr}: $cleanTitle" }
    $described = if ($dropBody) { 'Left out: the privacy scan found a private value in it.' } elseif ($cleanBody) { $cleanBody } else { '(empty)' }

    # the change note (docs/changes/port-<N>.md): every PR has one (cut-over plan, rule 5)
    $noteRel = "docs/changes/port-$Pr.md"
    if (-not $committed -and -not (Test-Path -LiteralPath (Join-Path $wt $noteRel))) {
        New-Item -ItemType Directory -Force -Path (Join-Path $wt 'docs\changes') | Out-Null
        $note = @"
# $title

Ported on $([DateTime]::UtcNow.ToString('yyyy-MM-dd')) by ``scripts/port-private.ps1`` from $PrivateRepo#$Pr ($($state.privateUrl)) at ``$($state.privateHead)``, onto tide ``$Base`` at ``$(Short $state.base)``. The private repo is on a GitHub billing hold, so its work lands here; the private PR stays open.

## What it does (the private PR's description, cleaned)

$described

## How it was ported

The private branch's changes since its merge-base ``$(Short $state.mergeBase)`` with the old private main, with the public cleaning (R1-R9) applied to both sides, applied with ``git apply -3``. Only those changes are applied, so tide-only commits stay. The changed files, the commit message and the PR text passed the privacy scan (no live hit; any other new hit needs a person's -Allow, named in the PR).

## L1-L4

The effects are the private PR's own (its description above). The port itself only moves finished work to the public home: nothing changes for a person, the business, an MSP or the community beyond that.
"@
        [IO.File]::WriteAllText((Join-Path $wt $noteRel), $note, $utf8)
    }
    if (-not $committed) { $null = G $wt @('add', '-A') }

    $ns = if ($committed) { (G $wt @('diff', '--name-status', '--no-renames', $baseSha, 'HEAD')).out } else { (G $wt @('diff', '--cached', '--name-status', '--no-renames', $baseSha)).out }
    $ns = @($ns -split "`n" | Where-Object { $_ })
    if (-not $ns.Count) { Refuse "the port changes nothing on tide $Base" }
    $changes = @($ns | ForEach-Object { $p = $_ -split "`t", 2; [pscustomobject]@{ kind = $p[0].Substring(0, 1); path = $p[1] } })
    $cur = @($changes | Where-Object kind -ne 'D' | ForEach-Object path); $old = @($changes | Where-Object kind -ne 'A' | ForEach-Object path)
    $markers = @($cur | Where-Object { $fp = Join-Path $wt $_; (Test-Path -LiteralPath $fp) -and (Select-String -LiteralPath $fp -Pattern '^(<{7} |>{7} |={7}$)' -Quiet) })
    if ($markers.Count) { Refuse "conflict markers left in: $($markers -join ', ')" }

    $kindWord = @{ A = 'added'; M = 'changed'; D = 'deleted'; T = 'changed'; C = 'copied' }
    $fileList = ($changes | ForEach-Object { "- $($kindWord[$_.kind]): ``$($_.path)``" }) -join "`n"
    $rejFiles = (@($state.newRejects) | ForEach-Object { '`' + $_ + '`' }) -join ', '
    $rejectLine = if (@($state.newRejects).Count) { "Cleaning-patch hunks that did not apply on the head (accepted after a read, -AcceptRejects): $rejFiles." } else { 'Every cleaning-patch hunk that applied on the merge-base also applied on the head.' }
    function Own-Body([string]$scanLine) {
        @"
Port of the private pull request $PrivateRepo#$Pr ($($state.privateUrl)) at its head ``$($state.privateHead)``. The private repo is on a GitHub billing hold, so its work lands here; the private PR stays open.

## How it was ported

``scripts/port-private.ps1``: the private branch's changes since its merge-base with the old main (``$(Short $state.mergeBase)``), with the public cleaning (R1-R9) applied to both sides, applied with ``git apply -3`` onto tide ``$Base`` at ``$(Short $state.base)``. Only those changes are applied, so tide-only commits stay. Change note: ``$noteRel``.

- $rejectLine
- Privacy scan of the changed files and this text: $scanLine

## Files ($($changes.Count))

$fileList
"@
    }
    $commitBody = "Ported from $PrivateRepo#$Pr at $($state.privateHead) by scripts/port-private.ps1:`nthe cleaned (R1-R9) diff from the private merge-base $($state.mergeBase)`nto that head, applied with git apply -3 onto tide $Base $(Short $state.base).`n`nFiles: $($changes.Count) ($(@($changes | Where-Object kind -eq 'A').Count) added, $(@($changes | Where-Object kind -eq 'M').Count) changed, $(@($changes | Where-Object kind -eq 'D').Count) deleted)."

    # ---- the scan: the changed files now and on tide main, plus this tool's own text
    $sNew = Join-Path $stage 'new'; $sOld = Join-Path $stage 'old'; New-Item -ItemType Directory -Force -Path $sNew, $sOld | Out-Null
    foreach ($p in $cur) {
        $dst = Join-Path $sNew $p; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath (Join-Path $wt $p) -Destination $dst
    }
    if ($old.Count) {
        $tar = Join-Path $stage 'old.tar'
        $ar = G $Repo (@('archive', '--format=tar', "--output=$tar", $state.base, '--') + $old)
        if ($ar.code) { Broken "could not read the tide $Base copies of the changed files ($($ar.out))" }
        tar -xf $tar -C $sOld; Remove-Item -LiteralPath $tar
    }
    $tt = Join-Path $sNew '_port-text'; New-Item -ItemType Directory -Force -Path $tt | Out-Null
    [IO.File]::WriteAllText((Join-Path $tt 'title.md'), $title, $utf8)
    [IO.File]::WriteAllText((Join-Path $tt 'own-body.md'), (Own-Body '0 live hits.'), $utf8)
    [IO.File]::WriteAllText((Join-Path $tt 'commit.md'), $commitBody + "`n" + ($Trailer -join "`n"), $utf8)
    $newCount = Count-Hits (Scan $sNew); $oldCount = Count-Hits (Scan $sOld)
    $bad = @(); $notes = @()
    foreach ($k in $newCount.Keys) {
        $cls, $file = $k -split '\|', 2
        if ($file -like '_port-text/*') { $bad += "$cls in this tool's own text ($file)"; continue }
        if ($cls -match $liveRx) { $bad += "$cls in $file ($($newCount[$k]))"; continue }
        $extra = $newCount[$k] - [int]$oldCount[$k]
        if ($extra -le 0) { continue }
        if (@($Allow | Where-Object { $cls -like $_ }).Count) { $notes += "$cls in $file (+$extra, allowed)" } else { $bad += "$cls in $file (+$extra new)" }
    }
    if ($bad.Count) { Refuse "the privacy scan found: $($bad -join '; '). Nothing committed or pushed$(if (-not $committed) { "; the worktree $wt is kept" }). A non-live class a person checked can pass with -Allow <class>" }
    $scanLine = "0 live hits in $($cur.Count) changed file(s)$(if ($notes.Count) { "; allowed by a person: $($notes -join '; ')" })$(if ($dropTitle) { '; the private title was left out (scan hit)' })$(if ($dropBody) { '; the private description was left out (scan hit)' })."
    Say "scan: $scanLine"
} finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }

$body = (Own-Body $scanLine) + "`n## The private PR's description (cleaned)`n`n$described`n"
if (-not $committed) {
    $msg = Join-Path $gitDir "port-private\pr-$Pr.msg"
    [IO.File]::WriteAllText($msg, "$title`n`n$commitBody`n$(if ($Trailer.Count) { "`n" + ($Trailer -join "`n") + "`n" })", $utf8)
    $c = G $wt @('-c', "user.name=$AuthorName", '-c', "user.email=$AuthorEmail", 'commit', '-q', '-F', $msg)
    if ($c.code) { Broken "the commit failed in $wt ($($c.out))" }
    $tip = Sha $wt 'HEAD'
    Say "committed $(Short $tip) on $Branch ($($changes.Count) file(s)) as $AuthorEmail"
}
$log = { param($url) $kr = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
    New-Item -ItemType Directory -Force -Path $kr | Out-Null
    Add-Content -LiteralPath (Join-Path $kr 'ports.jsonl') -Encoding utf8 -Value (([ordered]@{ pr = $Pr; privateRepo = $PrivateRepo; privateHead = $B; mergeBase = $state.mergeBase
                tideRepo = $TideRepo; base = $state.base; branch = $Branch; commit = $tip; url = $url; at = [DateTime]::UtcNow.ToString('o') }) | ConvertTo-Json -Compress) }
if ($NoPush) { & $log ''; Say "NOT PUSHED (-NoPush): $Branch at $(Short $tip) in $wt"; exit 0 }

# ---- 5. push (never forced) and the PR
$remoteTip = ((G $Repo @('ls-remote', '--heads', $TideRemote, "refs/heads/$Branch")).out -split '\s+')[0]
if ($remoteTip -ne $tip) {
    $p = G $wt @('push', '-q', $TideRemote, "HEAD:refs/heads/$Branch")
    if ($p.code) { Broken "the push of $Branch failed ($($p.out)); nothing was forced" }
}
$l = Invoke-GhJson @('pr', 'list', '-R', $TideRepo, '--head', $Branch, '--state', 'open', '--json', 'number,url')
if (-not $l.ok) { Broken "could not list $TideRepo PRs ($(Get-GhWhy $l))" }
$open = @($l.json | Where-Object { $_.url })
$bodyFile = Join-Path $gitDir "port-private\pr-$Pr.body.md"; [IO.File]::WriteAllText($bodyFile, $body, $utf8)
if ($open.Count) { $url = [string]$open[0].url; Say "PR reused: $url" }
else {
    $cr = Invoke-Gh @('pr', 'create', '-R', $TideRepo, '--base', $Base, '--head', $Branch, '--title', $title, '--body-file', $bodyFile)
    if (-not $cr.ok) { Broken "pushed $Branch, but the PR could not be opened ($(Get-GhWhy $cr)); run again with -Continue" }
    $url = (([string]$cr.out -split "`n") | Where-Object { $_ -match '^https://' } | Select-Object -Last 1).Trim()
    Say "PR opened: $url"
}
& $log $url
if ($Comment) {
    $cm = Invoke-Gh @('pr', 'comment', "$Pr", '-R', $PrivateRepo, '--body', "Ported to $TideRepo for review and merge: $url (branch ``$Branch`` at $(Short $tip), cleaned R1-R9 and scanned by scripts/port-private.ps1). This PR stays open here.")
    if ($cm.ok) { Say "commented on $PrivateRepo#$Pr" } else { Say "could not comment on $PrivateRepo#$Pr ($(Get-GhWhy $cm)); the port itself is done" }
}
Say "DONE private #$Pr -> $url ($Branch at $(Short $tip))"
exit 0
