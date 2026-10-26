# A fake `gh` for tests/Test-PrFlow.ps1 (KITCHEN_GH points here): plays GitHub over a local bare repo, so no test touches the network.
# State lives in FAKE_GH_DIR: repos.txt (repos that exist, one owner/name per line), prs.json (the pull requests), checks.json
# ({ "<head sha>": [statusCheckRollup items] }), mergeable.txt (overrides MERGEABLE), offline.txt (every call fails like a dropped
# network), signedout.txt (every call fails as gh does when signed out), calls.log (every call, one per line). FAKE_GH_BARE is the bare repo that stands in for GitHub's git side.
# Speaks only what the kitchen uses: repo view, pr list / create / edit / view / merge.
$ErrorActionPreference = 'Stop'
$dir = $env:FAKE_GH_DIR; $bare = $env:FAKE_GH_BARE
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value ($args -join ' ')
if (Test-Path -LiteralPath (Join-Path $dir 'offline.txt')) { [Console]::Error.WriteLine('error connecting to api.github.com'); exit 1 }
if (Test-Path -LiteralPath (Join-Path $dir 'signedout.txt')) { [Console]::Error.WriteLine('To get started with GitHub CLI, please run:  gh auth login'); exit 4 }
$a = @($args); $pos = [Collections.Generic.List[string]]::new(); $opt = @{}
$flags = '--merge', '--squash', '--rebase', '--delete-branch'
for ($i = 0; $i -lt $a.Count; $i++) {
    $t = [string]$a[$i]
    if ($t -in $flags) { $opt[$t] = $true } elseif ($t.StartsWith('-')) { $opt[$t] = [string]$a[$i + 1]; $i++ } else { $pos.Add($t) }
}
$repo = if ($opt['-R']) { $opt['-R'] } else { $opt['--repo'] }
$prsPath = Join-Path $dir 'prs.json'
$db = if (Test-Path -LiteralPath $prsPath) { Get-Content -LiteralPath $prsPath -Raw | ConvertFrom-Json -AsHashtable } else { @{ next = 1; prs = @() } }
function Save { $db | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $prsPath -Encoding utf8 }
function Fail([string]$m) { [Console]::Error.WriteLine($m); exit 1 }
function Head([string]$branch) { "$(& git -C $bare rev-parse --verify --quiet "refs/heads/$branch" 2>$null)".Trim() }
function Pick([hashtable]$o, [string]$fields) { $r = [ordered]@{}; foreach ($f in ($fields -split ',')) { $r[$f] = $o[$f] }; $r }
function View([hashtable]$p) {
    $h = if ($p.state -eq 'OPEN') { Head $p.headRefName } else { [string]$p.headRefOid }
    $checks = @{}; $cp = Join-Path $dir 'checks.json'; if (Test-Path -LiteralPath $cp) { $checks = Get-Content -LiteralPath $cp -Raw | ConvertFrom-Json -AsHashtable }
    $mg = if (Test-Path -LiteralPath (Join-Path $dir 'mergeable.txt')) { (Get-Content -LiteralPath (Join-Path $dir 'mergeable.txt') -Raw).Trim() } else { 'MERGEABLE' }
    @{ number = $p.number; url = $p.url; state = $p.state; headRefName = $p.headRefName; headRefOid = $h; mergedAt = $p.mergedAt; mergedBy = $(if ($p.mergedBy) { @{ login = $p.mergedBy } } else { $null })
        statusCheckRollup = @($(if ($checks[$h]) { $checks[$h] } else { @() })); mergeable = $mg; mergeCommit = $(if ($p.mergeCommit) { @{ oid = $p.mergeCommit } } else { $null }) }
}
function Find([string]$n) { $p = @($db.prs | Where-Object { [string]$_.number -eq $n -and $_.repo -eq $repo }); if (-not $p.Count) { Fail "GraphQL: Could not resolve to a PullRequest with the number of $n." }; $p[0] }
$cmd = ($pos | Select-Object -First 2) -join ' '
switch ($cmd) {
    'repo view' {
        $known = @(Get-Content -LiteralPath (Join-Path $dir 'repos.txt') -ErrorAction SilentlyContinue)
        if ($known -notcontains $pos[2]) { Fail "GraphQL: Could not resolve to a Repository with the name '$($pos[2])'. (repository)" }
        @{ nameWithOwner = $pos[2] } | ConvertTo-Json -Compress; exit 0
    }
    'pr list' {
        $l = @($db.prs | Where-Object { $_.repo -eq $repo -and (-not $opt['--head'] -or $_.headRefName -eq $opt['--head']) } | ForEach-Object { Pick (View $_) $opt['--json'] })
        ConvertTo-Json -InputObject @($l) -Depth 6 -Compress; exit 0
    }
    'pr create' {
        if (@($db.prs | Where-Object { $_.repo -eq $repo -and $_.headRefName -eq $opt['--head'] -and $_.state -eq 'OPEN' }).Count) { Fail "a pull request for branch `"$($opt['--head'])`" into branch `"main`" already exists" }
        if (-not (Head $opt['--head'])) { Fail "pull request create failed: GraphQL: Head sha can't be blank" }
        $n = [int]$db.next; $db.next = $n + 1
        $db.prs = @($db.prs) + @(@{ repo = $repo; number = $n; url = "https://github.com/$repo/pull/$n"; state = 'OPEN'; headRefName = $opt['--head']; title = $opt['--title']
                body = (Get-Content -LiteralPath $opt['--body-file'] -Raw); mergedAt = $null; mergeCommit = $null; headRefOid = $null })
        Save; "https://github.com/$repo/pull/$n"; exit 0
    }
    'pr edit' { $p = Find $pos[2]; $p.body = (Get-Content -LiteralPath $opt['--body-file'] -Raw); Save; "https://github.com/$repo/pull/$($p.number)"; exit 0 }
    'pr view' { $p = Find $pos[2]; Pick (View $p) $opt['--json'] | ConvertTo-Json -Depth 8 -Compress; exit 0 }
    'pr merge' {
        $p = Find $pos[2]
        if ($p.state -ne 'OPEN') { Fail "Pull request #$($p.number) is not open" }
        $h = Head $p.headRefName
        if ($opt['--match-head-commit'] -and $opt['--match-head-commit'] -ne $h) { Fail 'GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)' }
        # a real merge commit on main, as GitHub makes it (first parent: main, second: the PR head)
        $main = Head 'main'
        $tree = [string](& git -C $bare merge-tree --write-tree $main $h 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE) { Fail 'Pull request is not mergeable: the merge commit cannot be cleanly created.' }
        $msg = if ($opt['--subject']) { $opt['--subject'] } else { "Merge pull request #$($p.number) from $(($repo -split '/')[0])/$($p.headRefName)" }
        $parents = if ($opt['--squash']) { @('-p', $main) } else { @('-p', $main, '-p', $h) }   # a squash: one new commit, the PR head not in main
        $mc = [string](& git -C $bare -c user.name=GitHub -c user.email=noreply@github.com commit-tree $tree.Trim() @parents -m $msg -m $(if ($opt['--body']) { $opt['--body'] } else { [string]$p.title }))
        & git -C $bare update-ref refs/heads/main $mc.Trim() $main
        $p.state = 'MERGED'; $p.mergedAt = [DateTime]::UtcNow.ToString('o'); $p.mergedBy = $(if ($env:FAKE_GH_MERGER) { $env:FAKE_GH_MERGER } else { ($repo -split '/')[0] }); $p.mergeCommit = $mc.Trim(); $p.headRefOid = $h
        Save; exit 0
    }
    default { Fail "fake gh: unknown command '$($a -join ' ')'" }
}
