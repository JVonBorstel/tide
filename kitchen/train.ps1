# The merge train, one per repo (TARGET W2, J253): one change at a time goes merge -> verify on a repo's main, and a train never holds a
# merge into another repo. Dot-sourced by stations/merge.ps1 (claims), stations/verify.ps1 (hands back), undo-merge.ps1 and kitchen.ps1.
# Until 10-23 one <kitchen>\merge-train.json served every repo, so a Demo Project merge waited for a brain-monitor verify (292 train waits,
# 311 slot-minutes). Now each repo has <kitchen>\merge-train-<sha12 of the lowercased full repo path>.json {job, at, sha, repo}.
# The rules are merge.ps1's, unchanged: a holder counts while its order is alive (running, pending, needs-human) and its claim is under
# 90 minutes old; a train file that cannot be read (torn, empty) holds for 90 minutes from its write time, never "no holder".
# Migration: an old merge-train.json is honoured until it is let go (its holder's merge step names the repo; one that cannot be read holds
# every repo), then deleted. Nothing writes it any more. The supervisor checks the train before it starts a merge worker (kitchen.ps1).
function Get-TrainKey([string]$Repo) { [IO.Path]::GetFullPath($Repo).TrimEnd('\', '/').ToLowerInvariant() }
function Get-TrainPath([string]$KitchenRoot, [string]$Repo) {
    $h = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((Get-TrainKey $Repo)))).Substring(0, 12).ToLowerInvariant()
    Join-Path $KitchenRoot "merge-train-$h.json"
}
function Read-TrainFile([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    $tr = try { [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { $null }
    $age = try { ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($Path)).TotalMinutes } catch { 0 }
    @{ tr = $tr; ok = [bool]($tr -and $tr.job); ageMin = $age }
}
function Get-TrainJobStatus([string]$KitchenRoot, [string]$Id) {
    if ($Id -notmatch '^J\d+$') { return '' }
    try { [string]([IO.File]::ReadAllText((Join-Path $KitchenRoot "jobs\$Id.json")) | ConvertFrom-Json).status } catch { '' }
}
# The repo an order merges into: its last merge step's Repo (the old shared train file does not say)
function Get-TrainJobRepo([string]$KitchenRoot, [string]$Id) {
    $j = try { [IO.File]::ReadAllText((Join-Path $KitchenRoot "jobs\$Id.json")) | ConvertFrom-Json } catch { $null }
    $m = @($j.steps | Where-Object { [string]$_.script -match '(^|[\\/])merge\.ps1$' -or [string]$_.station -eq 'merge' }) | Select-Object -Last 1
    if ($m -and $m.args -and $m.args.Repo) { [string]$m.args.Repo } else { '' }
}
# Who holds the repo's train, other than $Job: a job id, a sentence for an unreadable file, or $null when it is free
function Get-TrainHolderIn([string]$KitchenRoot, [string]$Path, [string]$Job, [string[]]$LiveStatus, [string]$Repo = '') {
    $f = Read-TrainFile $Path
    if (-not $f) { return $null }
    if (-not $f.ok) { if ($f.ageMin -lt 90) { return "an order ($(Split-Path -Leaf $Path) cannot be read)" }; return $null }
    $tr = $f.tr
    if ([string]$tr.job -eq $Job) { return $null }
    if ($Repo) { $hr = Get-TrainJobRepo $KitchenRoot ([string]$tr.job); if ($hr -and (Get-TrainKey $hr) -ne (Get-TrainKey $Repo)) { return $null } }
    $at = try { if ($tr.at -is [DateTime]) { $tr.at.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$tr.at, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } } catch { [DateTime]::MinValue }
    $fresh = ([DateTime]::UtcNow - $at).TotalMinutes -lt 90
    if ($fresh -and (Get-TrainJobStatus $KitchenRoot ([string]$tr.job)) -in $LiveStatus) { return [string]$tr.job }
    $null
}
function Get-TrainHolder([string]$KitchenRoot, [string]$Repo, [string]$Job = '', [string[]]$LiveStatus = @('running', 'pending', 'needs-human')) {
    $h = Get-TrainHolderIn $KitchenRoot (Get-TrainPath $KitchenRoot $Repo) $Job $LiveStatus
    if ($h) { return $h }
    $old = Join-Path $KitchenRoot 'merge-train.json'
    if (-not [IO.File]::Exists($old)) { return $null }
    $h = Get-TrainHolderIn $KitchenRoot $old $Job $LiveStatus $Repo
    if ($h) { return $h }
    # let go (its holder is finished, stale or another repo's and finished): the migration is over for good
    $f = Read-TrainFile $old
    if ($f -and $f.ok -and [string]$f.tr.job -ne $Job -and -not (Get-TrainHolderIn $KitchenRoot $old $Job $LiveStatus)) { try { [IO.File]::Delete($old) } catch { } }
    $null
}
function Set-TrainClaim([string]$KitchenRoot, [string]$Repo, [string]$Job, [string]$Sha = 'pending') {
    $p = Get-TrainPath $KitchenRoot $Repo; $t = "$p.tmp-$PID"
    [ordered]@{ job = $Job; at = [DateTime]::UtcNow.ToString('o'); sha = $Sha; repo = (Get-TrainKey $Repo) } | ConvertTo-Json -Compress | Set-Content -LiteralPath $t -Encoding utf8
    [IO.File]::Move($t, $p, $true)   # written whole: a reader never sees half of it
}
# hand the train back: this repo's file and the old shared one, each only when it names $Job
function Clear-TrainClaim([string]$KitchenRoot, [string]$Repo, [string]$Job) {
    foreach ($p in (Get-TrainPath $KitchenRoot $Repo), (Join-Path $KitchenRoot 'merge-train.json')) {
        try { $f = Read-TrainFile $p; if ($f -and $f.ok -and [string]$f.tr.job -eq $Job) { [IO.File]::Delete($p) } } catch { }
    }
}
