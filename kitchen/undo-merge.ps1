# Undo a merged Improve order in one tap: adds a commit that reverses its merge (git revert; history is kept, nothing deleted).
# Refuses if the repository has uncommitted changes, or if the merge cannot be reversed cleanly (then nothing changes).
#   undo-merge.ps1 -Job J12 [-Repo <path>] [-Json]
param([Parameter(Mandatory)][ValidatePattern('^J\d+$')][string]$Job, [string]$Repo = '', [string]$Why = '', [switch]$Json)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
# -Json: {ok, message}; after an undo also {pushed, pushWhy} (TD-EH-10): pushed true = the undo is on GitHub too, false = it had to go
# up and did not (pushWhy says why in fixed words), null = the order never went through GitHub, so there was nothing to push
function Done([bool]$ok, [string]$msg, $extra = $null) { if ($Json) { $o = [ordered]@{ ok = $ok; message = $msg }; if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }; $o | ConvertTo-Json -Compress } else { $msg }; exit $(if ($ok) { 0 } else { 1 }) }
# a test suite (KITCHEN_UNDER_TEST, set by the tests and mutate stations) never undoes anything for Jordan's live kitchen
if ($env:KITCHEN_UNDER_TEST -eq '1' -and [IO.Path]::GetFullPath($root) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))) { Done $false 'under test: refusing to use the live kitchen' }
if (-not $Repo) {
    . (Join-Path $PSScriptRoot 'jobs-lib.ps1')
    $jp = Get-KitchenJobPath $root $Job   # jobs\, or jobs\archive\yyyy-MM\ for an order finished more than a few days ago
    if ($jp) { $j = Get-Content -LiteralPath $jp -Raw | ConvertFrom-Json; $m = @($j.steps | Where-Object { $_.script -match 'merge\.ps1$' } | Select-Object -First 1); if ($m -and $m[0].args.Repo) { $Repo = [string]$m[0].args.Repo } }
    if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
}
# the same per-repo lock merge.ps1 holds: a revert never runs while a merge is writing to the checkout (.git/index.lock, a half-done merge)
$top = (& git -C $Repo rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -or -not $top) { $top = $Repo }
$key = [IO.Path]::GetFullPath($top).TrimEnd('\', '/').ToLowerInvariant()
$lock = [Threading.Mutex]::new($false, 'Global\brain-kitchen-merge-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).Substring(0, 16)); $got = $false
try { $got = $lock.WaitOne(300000) } catch [Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { $lock.Dispose(); Done $false "another merge into this repository is still running after 5 minutes; nothing changed" }
try {
    # never during a verify on main (except from that verify itself, which runs as KITCHEN_JOB): verify may be undoing the same merge itself, and a second undo makes it report a false 'could not undo'
    # (this repo's train, kitchen/train.ps1; a holder's claim counts for 90 minutes, an unreadable train file holds too)
    . (Join-Path $PSScriptRoot 'train.ps1')
    $th = try { Get-TrainHolder $root $Repo ([string]$env:KITCHEN_JOB) @('running', 'pending') } catch { $null }
    if ($th) { Done $false "$th is being checked on main right now; try the undo again in a few minutes" }
    if (@(& git -C $Repo status --porcelain --untracked-files=no).Count) { Done $false "the repository has uncommitted changes; undo nothing" }
    # merges land only on main, so the undo goes only there: never a revert on a feature branch or a detached HEAD
    # "main" = the repo's default branch (origin/HEAD, else main, else master: repo-config.ps1); none found = main, as before
    . (Join-Path $PSScriptRoot 'repo-config.ps1'); $mainName = Get-RepoDefaultBranch $Repo; if (-not $mainName) { $mainName = 'main' }
    $onBranch = (& git -C $Repo rev-parse --abbrev-ref HEAD 2>$null); if ($onBranch -ne $mainName) { Done $false "the repository is on '$onBranch', not $mainName; undo nothing" }
    # "$(...)": a search that finds nothing is empty text, not a null that .Trim() would throw on before the next search is tried
    $sha = "$(& git -C $Repo log --merges --format=%H "--grep=^Merge kitchen/$Job " -n 1)".Trim()
    if (-not $sha) { $sha = "$(& git -C $Repo log --merges --format=%H "--grep=^Merge kitchen/$Job\b" -n 1)".Trim() }
    # a pull request Jordan merged himself on GitHub carries GitHub's own message (the kitchen's own PR merges use the subject above)
    if (-not $sha) { $sha = "$(& git -C $Repo log --merges --format=%H "--grep=^Merge pull request #[0-9][0-9]* from [^ ]*/kitchen/$Job`$" -n 1)".Trim() }
    if (-not $sha) { Done $false "no merge of $Job found" }
    if (@(& git -C $Repo log --format=%s "--grep=^Undo $Job " -n 1).Count) { Done $false "$Job was already undone" }
    & git -C $Repo -c user.name="Jordan's Kitchen" -c user.email='kitchen@localhost' revert -m 1 --no-edit $sha 2>&1 | Out-Null
    if ($LASTEXITCODE) { & git -C $Repo revert --abort 2>&1 | Out-Null; Done $false "could not reverse $Job cleanly (later changes build on it); nothing changed" }
    $msg = if ($Why) { "Undo $Job (reverts its merge $($sha.Substring(0, 7)): $Why)" } else { "Undo $Job (reverts its merge $($sha.Substring(0, 7)), asked by Jordan)" }
    & git -C $Repo -c user.name="Jordan's Kitchen" -c user.email='kitchen@localhost' commit --amend -q -m $msg 2>&1 | Out-Null
    # an order that came through a pull request is on GitHub's main too: the undo goes up as well, or GitHub keeps the broken change
    # (and every later PR merge holds, since local main would be ahead). Only as exactly this one commit on top of GitHub's main: a
    # local main with anything else GitHub lacks (a private order) is never pushed; Jordan is told instead.
    $pushNote = ''; $pushed = $null; $pushWhy = ''
    . (Join-Path $PSScriptRoot 'github-lib.ps1')
    $prr = Read-PrRecord $root $Job
    if ($prr.rec -and -not $prr.rec.skipped) {
        $slug = [string]$prr.rec.repo; $parent = [string](& git -C $Repo rev-parse 'HEAD~1')
        $gh = Get-GithubMain $Repo $slug
        if (-not $gh) { $pushed = $false; $pushWhy = 'GitHub could not be reached'; $pushNote = "; NOT on GitHub yet (could not reach it): push main to GitHub by hand" }
        elseif ($gh -ne $parent) { $pushed = $false; $pushWhy = "GitHub's main is not where this PC's main was"; $pushNote = "; NOT on GitHub yet (GitHub's main is not where this PC's was): push main to GitHub by hand" }
        else {
            $p = Invoke-GitRemote $Repo @('push', '--quiet', (Get-GithubRemote $slug), 'HEAD:refs/heads/main')
            $pushed = [bool]$p.ok; if (-not $p.ok) { $pushWhy = 'the push to GitHub failed' }
            $pushNote = if ($p.ok) { '; pushed to GitHub' } else { "; NOT on GitHub yet (push failed: $($p.text)): push main to GitHub by hand" }
        }
        # TD-EH-10: an undo that stayed on this PC leaves main here ahead of GitHub's, and every later PR merge holds ("main has commits
        # GitHub's main does not"). So it is recorded for the Board (<kitchen>\undo-unpushed\<job>.json: the Tower, the GitHub repo, the
        # undo commit, the reason in fixed words) until undo-push-check.ps1 finds the undo on GitHub. Names and shas only, no file contents.
        if ($pushed -eq $false) {
            try {
                $topFull = [IO.Path]::GetFullPath($top).TrimEnd('\', '/')
                Write-JsonAtomic (Join-Path $root "undo-unpushed\$Job.json") ([ordered]@{ job = $Job; tower = (Split-Path -Leaf $topFull); repo = $topFull; slug = $slug
                    sha = ([string](& git -C $Repo rev-parse HEAD)).Trim(); at = (Get-Date).ToUniversalTime().ToString('o'); why = $pushWhy })
            } catch { $pushNote += " (the Board could NOT be told: $($_.Exception.Message))" }
        }
    }
    try {
        $rec = [ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); job = $Job; undone = $sha }
        if ($Why) { $rec['why'] = $Why }
        # Chef reads this log too: a locked file gets 3 tries, else verify writes its own undo record (it checks for one)
        for ($try = 1; $try -le 3; $try++) { try { $rec | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $root 'automerged.jsonl') -Encoding utf8 -ErrorAction Stop; break } catch { if ($try -lt 3) { [Threading.Thread]::Sleep(300) } } }
    } catch { }
} finally { try { $lock.ReleaseMutex() } catch { }; $lock.Dispose() }
Done $true "undid $Job$pushNote" ([ordered]@{ pushed = $pushed; pushWhy = $pushWhy })
