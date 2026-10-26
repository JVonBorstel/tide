# Station: overnight job hunt (Idea I62). Takes top N new openings by rank-fit score,
# appends them to tracker.json as 'saved', and queues private tailor jobs (local cook only, private), then an apply packet (apply-prep,
# also private and local) for as many of those roles as the child cap leaves room for, best fit first.
# Never submits anything anywhere.
#   step: {"station":"hunt-night","args":{"Openings":"...","Top":3}}
# Exit: 0 done (all chosen roles queued, or nothing fit tonight), 1 a tailor could not be queued, 2 bad input or tracker.json unreadable.
param(
    [string]$Openings = '',
    [string]$CareerDir = '',
    [int]$Top = 3,
    [string]$Recipe = 'tailor',
    [string]$PacketRecipe = 'apply-prep'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tracker-lib.ps1')

if (-not $CareerDir) {
    $CareerDir = if ($env:PASS_CAREER_DIR) { $env:PASS_CAREER_DIR } else { (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain\projects\career') }
}
# one hunt makes at most maxChildren (5) child jobs; past that kitchen.ps1 refuses them and the roles would be saved with no draft
$maxTop = 5
if ($Top -gt $maxTop) { Write-Output "hunt-night: top $Top is over the kitchen's $maxTop-child cap; taking $maxTop"; $Top = $maxTop }
if ($Top -lt 1) { $Top = 1 }

$job = $env:KITCHEN_JOB
if ($Openings -and $job) {
    $Openings = $Openings.Replace('{{job}}', [string]$job)
}
if (-not $Openings) {
    $Openings = Join-Path $CareerDir "scout\$job-openings.md"
}

if (-not (Test-Path -LiteralPath $Openings -PathType Leaf)) {
    Write-Output "hunt-night: openings file not found: $Openings"
    exit 2
}

$rankPs = (Resolve-Path (Join-Path $PSScriptRoot '..\rank-fit.ps1')).Path
if (-not (Test-Path -LiteralPath $rankPs -PathType Leaf)) {
    Write-Output "hunt-night: rank-fit.ps1 not found at $rankPs"
    exit 2
}

$cookPs = (Resolve-Path (Join-Path $PSScriptRoot '..\cook.ps1')).Path
if (-not (Test-Path -LiteralPath $cookPs -PathType Leaf)) {
    Write-Output "hunt-night: cook.ps1 not found at $cookPs"
    exit 2
}

# The scout's markdown is hostile web text: strip control and bidi characters (same set as rank-fit.ps1) and cap every field at the
# server's own limits, so a junk multi-kilobyte 'company' or 'Fit:' line never lands in the tracker.
function Clean([string]$s, [int]$max) { $s = [regex]::Replace([string]$s, '[\x00-\x08\x0B-\x1F\x7F​-‏‪-‮⁦-⁩﻿]', '').Trim(); if ($s.Length -gt $max) { $s.Substring(0, $max) } else { $s } }

# 1. Parse opening blocks from the markdown file; only under the Openings heading ("Worth a look today" repeats the same roles)
$lines = [IO.File]::ReadAllText($Openings).Split("`n")
$blocks = [Collections.Generic.List[string]]::new()
$cur = $null; $inOpenings = $true
foreach ($l in $lines) {
    if ($l -match '^#') { if ($null -ne $cur) { $blocks.Add($cur) }; $cur = $null; $inOpenings = $l -match '(?i)openings'; continue }
    if (-not $inOpenings) { continue }
    if ($l -match '^\s*([-*]|\d+[.)])\s+\*\*') { if ($null -ne $cur) { $blocks.Add($cur) }; $cur = $l }
    elseif ($null -ne $cur) { $cur += "`n$l" }
}
if ($null -ne $cur) { $blocks.Add($cur) }

if ($blocks.Count -eq 0) {
    Write-Output 'hunt-night: no openings found in the file'
    exit 1
}

# 2. Read existing tracker.json. A tracker that exists but can't be read is never treated as empty: that would replace Jordan's
#    whole application history with tonight's roles. Refuse and leave the file alone.
$trackerPath = Join-Path $CareerDir 'tracker.json'
try { $existing = Read-Tracker $trackerPath } catch {
    Write-Output "hunt-night: tracker.json is unreadable; nothing changed and nothing queued ($($_.Exception.Message))"
    exit 2
}
$knownLinks = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$knownPairs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($it in $existing) {
    if ($it.link) { [void]$knownLinks.Add([string]$it.link) }
    if ($it.company -and $it.role) { [void]$knownPairs.Add("$($it.company)::$($it.role)".ToLowerInvariant()) }
}

# 3. Score each block with rank-fit.ps1 and filter duplicates
$candidates = [Collections.Generic.List[object]]::new()

foreach ($b in $blocks) {
    $firstLine = ($b -split "`r?`n")[0]
    $role = ''; $company = ''; $where = ''; $pay = ''
    if ($firstLine -match '^\s*(?:[-*]|\d+[.)])\s+\*\*([^*]+)\*\*\s+at\s+([^(.\n]+?)(?:\s*\(([^)]*)\))?(?:\.\s*(.*))?$') {
        $role = $Matches[1].Trim()
        $company = $Matches[2].Trim()
        $where = if ($Matches[3]) { $Matches[3].Trim() } else { '' }
        $pay = if ($Matches[4]) { $Matches[4].Trim() } else { '' }
    } else {
        if ($b -match '\*\*([^*]+)\*\*') { $role = $Matches[1].Trim() }
        if ($b -match 'at\s+([^(.\n]+)') { $company = $Matches[1].Trim() } else { $company = 'Unknown' }
    }
    $link = if ($b -match 'https?://[^\s)>\]]+') { $Matches[0].Trim() } else { '' }
    if ($b -match 'Link:\s*(https?://\S+)') { $link = $Matches[1].Trim() }
    $fitLine = if ($b -match 'Fit:\s*(.+)') { $Matches[1].Trim() } else { '' }
    $company = Clean $company 120; $role = Clean $role 160; $where = Clean $where 120; $pay = Clean $pay 160; $fitLine = Clean $fitLine 2000
    $link = Clean $link 500; if ($link -notmatch '^https?://') { $link = '' }

    # Deduplicate against existing tracker
    if ($link -and $knownLinks.Contains($link)) { continue }
    $pairKey = "$company::$role".ToLowerInvariant()
    if ($company -and $role -and $knownPairs.Contains($pairKey)) { continue }

    # Score the posting's own words (title, place, Must-haves), not the scout's 'Fit:' commentary, which names Jordan's skills
    $scoreText = (@($b -split "`r?`n" | Where-Object { $_ -notmatch '^\s*Fit:' }) -join "`n")
    $fitOut = & $rankPs -Text $scoreText -Json | Out-String
    $score = 0
    $verdict = 'skip'
    try {
        $fitObj = $fitOut.Trim() | ConvertFrom-Json
        $score = [int]$fitObj.score
        $verdict = [string]$fitObj.verdict
    } catch { }

    $candidates.Add([pscustomobject]@{
        company = $company
        role    = $role
        where   = $where
        pay     = $pay
        link    = $link
        notes   = $fitLine
        block   = $b
        score   = $score
        verdict = $verdict
    })
}

# 4. Drop 'skip' verdicts (a disqualifier or too weak a fit), sort by score then company, and drop repeats of the same link or
#    company::role inside tonight's file (keeping the best-scored copy) before choosing, so one role never takes two slots.
$sorted = @($candidates | Where-Object { $_.verdict -ne 'skip' } | Sort-Object -Property @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.company } })
$seenLinks = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$seenPairs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$chosen = @(foreach ($c in $sorted) {
    $pk = "$($c.company)::$($c.role)".ToLowerInvariant()
    if (($c.link -and $seenLinks.Contains($c.link)) -or ($c.company -and $c.role -and $seenPairs.Contains($pk))) { continue }
    if ($c.link) { [void]$seenLinks.Add($c.link) }; if ($c.company -and $c.role) { [void]$seenPairs.Add($pk) }
    $c
}) | Select-Object -First $Top
$chosen = @($chosen)
if (-not $chosen.Count) {
    Write-Output "hunt-night: done (0 opening(s) fit tonight; $($candidates.Count) new scored, none above the skip line)"
    exit 0
}

# 5. Save the chosen roles first, under the tracker lock: re-read the tracker fresh (another writer may have changed it since step 2),
#    drop roles that arrived meanwhile and number from the fresh max. Rows are written before any tailor is queued, so a crash never
#    leaves queued jobs without tracker rows.
$added = [Collections.Generic.List[object]]::new()
try {
    Update-Tracker $trackerPath {
        param($items)
        $links = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $pairs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $maxNum = 0
        foreach ($it in $items) {
            if ($it.link) { [void]$links.Add([string]$it.link) }
            if ($it.company -and $it.role) { [void]$pairs.Add("$($it.company)::$($it.role)".ToLowerInvariant()) }
            if ([string]$it.id -match '^A(\d+)$' -and [int]$Matches[1] -gt $maxNum) { $maxNum = [int]$Matches[1] }
        }
        foreach ($cand in $chosen) {
            if (($cand.link -and $links.Contains($cand.link)) -or ($cand.company -and $cand.role -and $pairs.Contains("$($cand.company)::$($cand.role)".ToLowerInvariant()))) { continue }
            $maxNum++
            $newItem = [ordered]@{
                id        = "A$maxNum"
                company   = $cand.company
                role      = $cand.role
                link      = $cand.link
                where     = $cand.where
                pay       = $cand.pay
                notes     = $cand.notes
                status    = 'saved'
                savedAt   = (Get-Date).ToUniversalTime().ToString('o')
                appliedAt = ''
                followUp  = ''
                source    = 'hunt-night'
                drafts    = @()
            }
            $items.Add($newItem); $added.Add([pscustomobject]@{ id = $newItem.id; cand = $cand })
        }
        $added.Count -gt 0
    }
} catch {
    Write-Output "hunt-night: could not update tracker.json; nothing queued ($($_.Exception.Message))"
    exit 2
}

# 6. Queue a private tailor (local cook only) for each saved role, then record each job id (or the error) in a second locked update.
$results = @{}; $failed = 0
foreach ($a in $added) {
    # cook.ps1 refuses any value holding '{{' (template injection guard); postings about Angular/Jinja/Handlebars contain it
    $vars = @{
        posting = ($a.cand.block -replace '\{\{', '{ {')
        cook    = 'local'
        private = 'yes'
    }
    $cookOut = & $cookPs -Recipe $Recipe -Vars $vars -Json | Out-String
    $cookRes = $null
    try { $cookRes = $cookOut.Trim() | ConvertFrom-Json } catch { }
    if ($cookRes -and $cookRes.ok -and [string]$cookRes.job -match '^J\d+$') {
        $results[$a.id] = @{ job = [string]$cookRes.job }
        Write-Output "  queued $($cookRes.job) ($($a.id)): $($a.cand.company) - $($a.cand.role) (score: $($a.cand.score))"
    } else {
        $err = if ($cookRes -and $cookRes.error) { [string]$cookRes.error } else { Clean $cookOut 200 }
        $results[$a.id] = @{ error = (Clean $err 300) }; $failed++
        Write-Output "hunt-night: could not queue a tailor for $($a.id) $($a.cand.company) - $($a.cand.role): $err"
    }
}
# 7. Apply packets in the slots the tailors left under the child cap (a tailor is queued first: the packet refuses a role whose tailor
#    draft failed its check). A role with no slot tonight is said so; Chef's "Build apply packet" queues it later. Never fails the hunt.
$slots = $maxTop - ($added.Count - $failed)
foreach ($a in $added) {
    if (-not $PacketRecipe) { break }
    if ($slots -le 0) { Write-Output "  no slot left for $($a.id)'s apply packet tonight (child cap $maxTop); build it from Chef"; continue }
    $vars = @{ appId = $a.id; company = $a.cand.company; role = $a.cand.role; description = ($a.cand.block -replace '\{\{', '{ {'); cook = 'local'; private = 'yes' }
    $cookRes = $null; try { $cookRes = (& $cookPs -Recipe $PacketRecipe -Vars $vars -Json | Out-String).Trim() | ConvertFrom-Json } catch { }
    if ($cookRes -and $cookRes.ok -and [string]$cookRes.job -match '^J\d+$') { $slots--; $results[$a.id].packetJob = [string]$cookRes.job; Write-Output "  packet $($cookRes.job) ($($a.id))" }
    else { $e = Clean $(if ($cookRes -and $cookRes.error) { [string]$cookRes.error } else { 'no answer from cook.ps1' }) 300; $results[$a.id].packetError = $e; Write-Output "  could not queue an apply packet for $($a.id): $e" }
}
try {
    Update-Tracker $trackerPath {
        param($items)
        $changed = $false
        foreach ($it in $items) {
            $r = $results[[string]$it.id]; if (-not $r) { continue }
            if ($r.job) { $it.drafts = @(@($it.drafts | Where-Object { $_ }) + $r.job) } elseif ($r.error) { $it.draftError = $r.error }
            if ($r.packetJob) { $it.packetJob = $r.packetJob } elseif ($r.packetError) { $it.packetError = $r.packetError }
            $changed = $true
        }
        $changed
    }
} catch {
    Write-Output "hunt-night: queued the tailors but could not record their job ids in tracker.json ($($_.Exception.Message))"
    exit 1
}

if ($failed) {
    Write-Output "hunt-night: queued $($added.Count - $failed) of $($added.Count) tailor(s); $failed could not be queued (see above)"
    exit 1
}
Write-Output "hunt-night: done ($($added.Count) opening(s) queued for review)"
exit 0
