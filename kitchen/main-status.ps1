# Main status per Tower (TD-EH-03a, error-handling audit 2026-10-23): is each repo's main green or red, since when, which suites, why.
# Dot-sourced by stations/verify.ps1 (writes it on every verdict about main), scripts/recheck-main.ps1 (writes it when the Foreman rechecks
# main, TD-EH-03d), scripts/handoff.ps1 (one line in the Toolbox talk), and scripts/merge-pr.ps1 and stations/merge.ps1 (no merges while it
# is red or cannot be read: Get-MainStatusGate, TD-EH-03c).
# On 10-23 main sat red for 8.5 hours and nothing said so. Verify now records what it found, in <kitchen>\main-status\<sha12>.json
# (<sha12> = the first 12 hex of SHA-256 of the lowercased full repo path, the same key as the merge train in train.ps1):
#   { repo, tower, state: green|red, suites, why, since, sha, tree, at, job, record }
# since = when a check first found main in this state (red: "red since at least"; the break itself may be earlier), at = the last
# check, sha = the commit it checked, record = the tests station's results\<job>.tests-why-*.json that says why. A change of state
# (or the first record) is also a main.status event in events.jsonl. The Board (pass-app/server.mjs mainStatusView) reads the folder.
# Written whole (temp file, then a rename), so a reader never sees half of one. Nothing here sends anything anywhere.
function Get-MainStatusKey([string]$Repo) {
    $k = [IO.Path]::GetFullPath($Repo).TrimEnd('\', '/').ToLowerInvariant()
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($k))).Substring(0, 12).ToLowerInvariant()
}
function Get-MainStatusPath([string]$KitchenRoot, [string]$Repo) { Join-Path (Join-Path $KitchenRoot 'main-status') "$(Get-MainStatusKey $Repo).json" }
# ConvertFrom-Json turns ISO times into local DateTime values; since and at are given back as the ISO UTC strings that were written
function ConvertTo-MainStatusIso($v) { if ($v -is [DateTime]) { $v.ToUniversalTime().ToString('o') } elseif ($null -eq $v) { '' } else { [string]$v } }
function Read-MainStatusFile([string]$Path) {
    $r = try { [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { $null }
    if ($r -and [string]$r.state -in 'green', 'red') { foreach ($k in 'since', 'at') { $r.$k = ConvertTo-MainStatusIso $r.$k }; return $r }
    $null
}
function Read-MainStatus([string]$KitchenRoot, [string]$Repo) {
    $p = Get-MainStatusPath $KitchenRoot $Repo
    if (-not [IO.File]::Exists($p)) { return $null }
    Read-MainStatusFile $p
}
# every Tower's record, newest check first; a file that cannot be read comes back as { state = 'unreadable'; file; why }, never dropped
function Read-MainStatusAll([string]$KitchenRoot) {
    $dir = Join-Path $KitchenRoot 'main-status'
    if (-not [IO.Directory]::Exists($dir)) { return @() }
    $all = foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $r = Read-MainStatusFile $f.FullName
        if ($r) { $r } else { [pscustomobject]@{ state = 'unreadable'; file = $f.Name; tower = $f.BaseName; why = 'cannot be read'; at = $f.LastWriteTimeUtc.ToString('o') } }
    }
    @($all | Sort-Object { [string]$_.at } -Descending)
}
# The plain reason for red suites: per suite, its first FAIL line (a crash: its last line; else its summary) from the tests station's
# why record, which the run names in its output as "tests: why: results\<job>.tests-why-<time>.json". No record: the first indented why
# line under its FAIL line in the output. Neither: says no reason was recorded. Capped at 400 chars.
function Get-MainRedWhy([string]$KitchenRoot, [string]$TestOut, [string[]]$Suites) {
    $parts = [Collections.Generic.List[string]]::new(); $recName = ''
    if ($TestOut -match '(?m)^tests: why: (results[\\/]\S+\.json)\s*$') { $recName = $Matches[1] }
    $rec = $null; if ($recName) { try { $rec = [IO.File]::ReadAllText((Join-Path $KitchenRoot $recName)) | ConvertFrom-Json } catch { $rec = $null } }
    foreach ($s in $Suites) {
        $r = @($rec.suites | Where-Object { [string]$_.suite -eq $s })[0]
        $w = ''
        if ($r) { $w = [string]@($r.why | Where-Object { "$_" -match '^FAIL' })[0]; if (-not $w) { $w = if (@($r.why).Count) { [string]@($r.why)[-1] } else { [string]$r.summary } } }
        if (-not $w -and $TestOut -match "(?m)^tests:\s+FAIL\s+$([regex]::Escape($s))\b[^\r\n]*[\r\n]+tests:\s{3,}(\S[^\r\n]*)") { $w = $Matches[1] }
        $w = ($w -replace '\s+', ' ').Trim(); if ($w.Length -gt 160) { $w = $w.Substring(0, 160) }
        if ($w) { $parts.Add("${s}: $w") }
    }
    $why = if ($parts.Count) { $parts -join '; ' } else { 'no reason was recorded (see the verify step log)' }
    if ($why.Length -gt 400) { $why = $why.Substring(0, 400) }
    @{ why = $why; record = $recName }
}
# Record what a check found on $Repo's main. Returns the record written. Throws only on a write it could not do (the caller says so).
# -Sha: the commit that was checked when it is not the checkout's HEAD (scripts/recheck-main.ps1 checks main in a throwaway worktree).
function Set-MainStatus([string]$KitchenRoot, [string]$Repo, [ValidateSet('green', 'red')][string]$State, [string[]]$Suites = @(), [string]$Why = '',
    [string]$Job = '', [string]$Record = '', [string]$Note = '', [string]$Sha = '') {
    $now = [DateTime]::UtcNow.ToString('o')
    $prev = Read-MainStatus $KitchenRoot $Repo
    $since = if ($prev -and [string]$prev.state -eq $State -and $prev.since) { [string]$prev.since } else { $now }
    $rev = if ($Sha) { $Sha } else { 'HEAD' }
    $sha = "$(& git -C $Repo rev-parse --verify --quiet "$rev^{commit}" 2>$null)".Trim(); $tree = "$(& git -C $Repo rev-parse --verify --quiet "$rev^{tree}" 2>$null)".Trim()
    $full = [IO.Path]::GetFullPath($Repo).TrimEnd('\', '/')
    $rec = [ordered]@{ repo = $full; tower = (Split-Path -Leaf $full); state = $State; suites = @($(if ($State -eq 'red') { $Suites } else { @() }))
        why = $(if ($State -eq 'red') { $Why } else { '' }); since = $since; sha = $sha; tree = $tree; at = $now; job = $Job; record = $Record; note = $Note }
    $p = Get-MainStatusPath $KitchenRoot $Repo
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    $tmp = "$p.tmp-$PID"
    $rec | ConvertTo-Json -Compress -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
    [IO.File]::Move($tmp, $p, $true)
    if (-not $prev -or [string]$prev.state -ne $State) {
        $ev = [ordered]@{ ts = $now; type = 'main.status'; tower = $rec.tower; repo = $full; state = $State; suites = $rec.suites; why = $rec.why; sha = $sha; job = $Job }
        try { Add-Content -LiteralPath (Join-Path $KitchenRoot 'events.jsonl') -Value ($ev | ConvertTo-Json -Compress -Depth 4) -Encoding utf8 } catch { }
    }
    [pscustomobject]$rec
}
# One line for the Toolbox talk: every Tower's main, red ones first ("RED since at least ..., Failed: ..., why: ..."); green ones short.
function Format-MainStatusLine([object[]]$All, [DateTime]$Now = [DateTime]::UtcNow) {
    $All = @($All | Where-Object { $_ })   # no records reaches here as $null, which @() would count as one
    if (-not $All.Count) { return 'Main status: none recorded yet (verify writes one per Tower after it checks main)' }
    $utc = { param($t) try { $(if ($t -is [DateTime]) { $t.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$t, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }) } catch { $null } }
    $bits = foreach ($r in @(@($All | Where-Object { $_.state -ne 'green' }) + @($All | Where-Object { $_.state -eq 'green' }))) {
        $tw = [string]$r.tower; $sha = ([string]$r.sha); if ($sha.Length -gt 12) { $sha = $sha.Substring(0, 12) }
        $at = & $utc $r.at; $atText = if ($at) { $at.ToString('MM-dd HH:mm') + ' UTC' } else { 'unknown time' }
        if ($r.state -eq 'red') {
            $since = & $utc $r.since; $h = if ($since) { ' ({0:N1} h)' -f ($Now - $since).TotalHours } else { '' }
            $wo = if ([string]$r.job -match '^J(\d+)$') { ", Work order WO-$($Matches[1].PadLeft(4, '0'))" } else { '' }
            "$tw main is RED since at least $(if ($since) { $since.ToString('MM-dd HH:mm') + ' UTC' } else { 'an unknown time' })$h, Failed: $(@($r.suites) -join ', '); why: $([string]$r.why); last checked $sha at $atText$wo"
        }
        elseif ($r.state -eq 'green') { "$tw main green (checked $sha at $atText)" }
        else { "$tw main status cannot be read (main-status\$([string]$r.file))" }
    }
    'Main status: ' + ($bits -join '; ')
}
# TD-EH-03c "Site closed when red": nothing merges onto a red main (10-23: merges landed on it and inherited the blame). Read by
# scripts/merge-pr.ps1 (refuses unless -FixesRed) and stations/merge.ps1 (waits, exit 11). Given the records that apply to one Tower,
# gives { closed, state, text }: state red (closed), unknown (a status file that cannot be read: not green, closed), green, or none
# (verify has never checked this Tower's main: nothing says it is red, open). text is the plain reason, with the suites and why.
function Get-MainStatusGate([object[]]$Recs) {
    $Recs = @($Recs | Where-Object { $_ })
    $utc = { param($t) try { [DateTimeOffset]::Parse([string]$t, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('MM-dd HH:mm') + ' UTC' } catch { 'an unknown time' } }
    $bits = [Collections.Generic.List[string]]::new()
    foreach ($r in @($Recs | Where-Object { $_.state -eq 'red' })) {
        $sha = [string]$r.sha; if ($sha.Length -gt 12) { $sha = $sha.Substring(0, 12) }
        $bits.Add("$([string]$r.tower) main is red since at least $(& $utc $r.since) (Failed: $(@($r.suites) -join ', '); why: $([string]$r.why); last checked $(if ($sha) { $sha } else { 'an unknown commit' }))")
    }
    $red = $bits.Count
    foreach ($r in @($Recs | Where-Object { $_.state -notin 'red', 'green' })) {
        $bits.Add("main status file main-status\$([string]$r.file) $(if ($r.whose) { "($([string]$r.whose)) " })cannot be read, so whether main is red is unknown")
    }
    if ($bits.Count) { return [pscustomobject]@{ closed = $true; state = $(if ($red) { 'red' } else { 'unknown' }); text = $bits -join '; ' } }
    if (@($Recs | Where-Object { $_.state -eq 'green' }).Count) { return [pscustomobject]@{ closed = $false; state = 'green'; text = 'main is green' } }
    [pscustomobject]@{ closed = $false; state = 'none'; text = 'no main status recorded yet' }
}
# The records for the Tower checked out at $Repo (stations/merge.ps1): its one file; a file that is there but cannot be read is unknown.
function Get-MainStatusFor([string]$KitchenRoot, [string]$Repo) {
    $p = Get-MainStatusPath $KitchenRoot $Repo
    if (-not [IO.File]::Exists($p)) { return @() }
    $r = Read-MainStatusFile $p
    if ($r) { return @($r) }
    @([pscustomobject]@{ state = 'unreadable'; file = (Split-Path -Leaf $p); whose = (Split-Path -Leaf ([IO.Path]::GetFullPath($Repo).TrimEnd('\', '/'))) })
}
# The records for a GitHub owner/name (scripts/merge-pr.ps1 knows only that): a record whose checkout's kitchen.repo.json names that
# "github", or, with no "github" there, whose folder name is the slug's name (how the Yard derives a slug: github-lib.ps1 Resolve-GithubSlug).
# A file that cannot be read does not say whose it is, so it counts for every slug: unknown, never green.
function Get-MainStatusForSlug([string]$KitchenRoot, [string]$Slug) {
    $name = ($Slug -split '/')[-1]
    @(foreach ($r in @(Read-MainStatusAll $KitchenRoot)) {
        if ($r.state -eq 'unreadable') { $r; continue }
        $gh = ''; $cfg = Join-Path ([string]$r.repo) 'kitchen.repo.json'
        if ($r.repo -and [IO.File]::Exists($cfg)) { $gh = try { [string]([IO.File]::ReadAllText($cfg) | ConvertFrom-Json).github } catch { '' } }
        $mine = if ($gh) { $gh -eq $Slug } else { (([string]$r.tower) -replace '[^A-Za-z0-9._-]', '-') -eq $name }   # (-eq ignores case, as GitHub does)
        if ($mine) { $r }
    })
}
# TD-EH-25: how far main is from its last verified tree, said at every merge (stations/merge.ps1). The verify cache (<kitchen>\verify-cache,
# stations/verify.ps1) holds every tree that passed the full tests cleanly; the newest commit on $Ref's first-parent line (500 back at most)
# whose tree is one of them is main's last verified commit. Gives { n; sha; tested } (n = commits in $Ref after it; 0 = $Ref itself passed),
# or { n = $null; why } when none is found or git cannot say: unknown, never 0.
function Get-VerifiedGap([string]$KitchenRoot, [string]$Repo, [string]$Ref) {
    $trees = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $KitchenRoot 'verify-cache') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $e = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { $null }
        if (-not $e -or [string]$e.result -ne 'PASS' -or [string]$e.tree -notmatch '^[0-9a-f]{40,64}$') { continue }
        $t = ConvertTo-MainStatusIso $e.tested
        if (-not $trees.ContainsKey([string]$e.tree) -or $t -gt $trees[[string]$e.tree]) { $trees[[string]$e.tree] = $t }
    }
    if (-not $trees.Count) { return @{ n = $null; why = 'the verify cache holds no passed tree' } }
    $lines = @(& git -C $Repo log --first-parent --format='%H %T' -n 500 $Ref 2>$null)
    if ($LASTEXITCODE -or -not $lines.Count) { return @{ n = $null; why = "git could not read main's history" } }
    foreach ($line in $lines) {
        $sha, $tree = "$line".Trim() -split ' ', 2
        if (-not $trees.ContainsKey($tree)) { continue }
        $count = "$(& git -C $Repo rev-list --count "$sha..$Ref" 2>$null)".Trim()
        if ($LASTEXITCODE -or $count -notmatch '^\d+$') { return @{ n = $null; why = "git could not count the commits after $($sha.Substring(0, 12))" } }
        return @{ n = [int]$count; sha = $sha; tested = $trees[$tree] }
    }
    @{ n = $null; why = "none of main's last $($lines.Count) commits has a tree the verify cache holds as passed" }
}
