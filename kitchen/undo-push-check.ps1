# TD-EH-10: is an undo that could not be pushed on GitHub now? undo-merge.ps1 writes <kitchen>\undo-unpushed\<job>.json when an undo
# had to go up to GitHub and did not; the Board shows it ("Undo not pushed: main on this PC is ahead of GitHub") until this check finds
# it gone: the undo commit is on GitHub's main, or main on this PC is no longer ahead of GitHub's (the Owner pushed or sorted it by hand).
# Only then is the record removed (an undo.pushed event says so). GitHub not reachable, a record that cannot be read, or a repository
# that is busy merging = the record stays (no proof, no change). Fetches GitHub's main by URL (github-lib.ps1); never pushes anything.
#   undo-push-check.ps1 [-Json]     -> {ok, cleared: [job...], left: [{job, why}]}
# Run by the Board (its "Check now" button, and every 15 minutes while a record exists).
param([switch]$Json)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
. (Join-Path $PSScriptRoot 'github-lib.ps1')
$asJson = $Json.IsPresent   # read here, not inside Say: the analyzer counts only uses at script level
$cleared = [Collections.Generic.List[string]]::new(); $left = [Collections.Generic.List[object]]::new()
function Say { $o = [ordered]@{ ok = $true; cleared = @($cleared); left = @($left) }; if ($asJson) { $o | ConvertTo-Json -Compress -Depth 4 } else { "cleared: $(if ($cleared.Count) { $cleared -join ', ' } else { 'none' }); left: $(if ($left.Count) { ($left | ForEach-Object { "$($_.job) ($($_.why))" }) -join ', ' } else { 'none' })" }; exit 0 }
# a test suite (KITCHEN_UNDER_TEST) never touches Jordan's live kitchen
if ($env:KITCHEN_UNDER_TEST -eq '1' -and [IO.Path]::GetFullPath($root) -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'brain-kitchen'))) { $left.Add([ordered]@{ job = ''; why = 'under test: refusing to use the live kitchen' }); Say }
$dir = Join-Path $root 'undo-unpushed'
$files = @(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Filter 'J*.json' -File | Where-Object { $_.Name -match '^J\d+\.json$' } | Sort-Object Name })
foreach ($f in $files) {
    $jid = $f.BaseName
    $r = Read-JsonFile $f.FullName
    if (-not $r -or -not [string]$r.repo -or [string]$r.slug -notmatch $script:GithubSlugRx -or [string]$r.sha -notmatch '^[0-9a-f]{40,64}$') { $left.Add([ordered]@{ job = $jid; why = 'its record cannot be read' }); continue }
    $repo = [string]$r.repo
    if (-not (Test-Path -LiteralPath $repo)) { $left.Add([ordered]@{ job = $jid; why = 'its repository folder is not there' }); continue }
    # the per-repo merge lock (merge.ps1, undo-merge.ps1): a fetch here would overwrite the FETCH_HEAD a running merge reads
    $key = [IO.Path]::GetFullPath($repo).TrimEnd('\', '/').ToLowerInvariant()
    $lock = [Threading.Mutex]::new($false, 'Global\brain-kitchen-merge-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).Substring(0, 16)); $got = $false
    try { $got = $lock.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { $lock.Dispose(); $left.Add([ordered]@{ job = $jid; why = 'a merge into its repository is running; try again in a minute' }); continue }
    try {
        $gh = Get-GithubMain $repo ([string]$r.slug)
        if (-not $gh) { $left.Add([ordered]@{ job = $jid; why = 'GitHub could not be reached' }); continue }
        $local = "$(& git -C $repo rev-parse --verify --quiet 'refs/heads/main' 2>$null)".Trim()
        $how = if (Test-Ancestor $repo ([string]$r.sha) $gh) { 'the undo is on GitHub' } elseif ($local -match '^[0-9a-f]{40,64}$' -and (Test-Ancestor $repo $local $gh)) { "main on this PC is no longer ahead of GitHub's" } else { '' }
        if (-not $how) { $left.Add([ordered]@{ job = $jid; why = 'main on this PC is still ahead of GitHub' }); continue }
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $f.FullName) { $left.Add([ordered]@{ job = $jid; why = 'its record could not be removed' }); continue }
        $cleared.Add($jid)
        try { Add-Content -LiteralPath (Join-Path $root 'events.jsonl') -Value ([ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = 'undo.pushed'; job = $jid; how = $how; github = $gh } | ConvertTo-Json -Compress) -Encoding utf8 } catch { }
    } finally { try { $lock.ReleaseMutex() } catch { }; $lock.Dispose() }
}
Say
