# Deterministic job-fit scorer: no model, no network, no writes to the brain. Scores posting text against Jordan's core skills
# (weighted keywords, each counted once), subtracts penalties for disqualifiers (security clearance, on-site outside the home metro with no
# remote option), and lists gaps by category. Only disqualifiers change the score; experience and skill gaps are for reading.
# Posting text is untrusted web text: input is capped at 200,000 characters and control/bidi characters are stripped from anything printed.
#   rank-fit.ps1 -Text '<posting>' [-Json]          one posting
#   rank-fit.ps1 -Path posting.txt [-Json]          one posting from a file
#   rank-fit.ps1 -Openings <scout>-openings.md      rank every opening in the scout's saved file; report goes to -OutDir
# Exit: 0 scored, 1 the openings file has no openings in it, 2 bad input.
param([string]$Text = '', [string]$Path = '', [string]$Openings = '', [string]$OutDir = '', [string]$HomeMetro = '', [switch]$Json)
$ErrorActionPreference = 'Stop'
# the home metro (an on-site or hybrid role there is fine): -HomeMetro, else kitchen.json "hunt".homeMetro (the state-folder copy wins).
# Personal, so it lives only in the state-folder kitchen.json; empty = no city is exempt.
if (-not $HomeMetro) {
    $kr = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
    foreach ($kp in (Join-Path $PSScriptRoot 'kitchen.json'), (Join-Path $kr 'kitchen.json')) {
        try { $kc = [IO.File]::ReadAllText($kp) | ConvertFrom-Json -AsHashtable } catch { continue }
        if ($kc.hunt -is [Collections.IDictionary] -and $kc.hunt.homeMetro) { $HomeMetro = [string]$kc.hunt.homeMetro }
    }
}
$HomeMetro = $HomeMetro.Trim()
$cap = 200000

# weight per skill (sum 90) and the pattern that proves it. 'React' alone is not 'React Native'; 'C' alone is not 'C#'.
$skills = [ordered]@{
    'LLMs/agents'  = @{ weight = 20; rx = '\bLLMs?\b|\blarge language models?\b|\bagentic\b|\b(AI|LLM|autonomous) agents?\b|\bgenerative AI\b|\bGenAI\b|\bMCP\b|\bRAG\b|\bprompt engineering\b|\bLangChain\b' }
    'Python'       = @{ weight = 15; rx = '\bpython\b' }
    'TypeScript'   = @{ weight = 15; rx = '\btype\s?script\b' }
    'React Native' = @{ weight = 15; rx = '\breact[\s-]native\b' }
    'C#'           = @{ weight = 10; rx = '(?<![A-Za-z0-9])c#|\bc[\s-]sharp\b|\basp\.net\b' }
    'AWS'          = @{ weight = 10; rx = '\bAWS\b|\bamazon web services\b' }
    'PMP'          = @{ weight = 5;  rx = '\bPMP\b|\bproject management professional\b' }
}
$penalty = @{ clearance = 50; onsite = 40 }
# skills Jordan does not list; reported as gaps, never scored
$gapSkills = [ordered]@{ 'Java' = '\bjava\b'; 'Go' = '\bgolang\b|\bgo (language|programming)\b'; 'Kubernetes' = '\bkubernetes\b|\bk8s\b'; 'Rust' = '\brust\b'
    'Scala' = '\bscala\b'; 'Ruby' = '\bruby\b'; 'PHP' = '\bphp\b'; 'C++' = '(?<![A-Za-z0-9])c\+\+'; 'Swift' = '\bswift\b'; 'Kotlin' = '\bkotlin\b'
    'Terraform' = '\bterraform\b'; 'Azure' = '\bazure\b' }
$fitAt = 60; $maybeAt = 30
$ci = [Text.RegularExpressions.RegexOptions]::IgnoreCase

function Clean([string]$s) { [regex]::Replace($s, '[\x00-\x08\x0B-\x1F\x7F​-‏‪-‮⁦-⁩﻿]', '') }

function Get-Fit([string]$posting) {
    $t = Clean $posting
    if ($t.Length -gt $cap) { $t = $t.Substring(0, $cap) }
    $score = 0; $matched = @(); $missing = @()
    foreach ($k in $skills.Keys) {
        if ([regex]::IsMatch($t, $skills[$k].rx, $ci)) { $score += $skills[$k].weight; $matched += $k } else { $missing += $k }
    }
    $gaps = [ordered]@{ disqualifier = @(); experience = @(); skill = @() }
    # clearance: drop negated mentions ("no clearance required", "clearance not required") before looking
    # The scout recipes ask it to quote "security clearance" for every opening, so "clearance: none mentioned" / "not listed" is the
    # common answer and must not cost 50 points (it made every opening 'skip' and the hunt picked roles alphabetically).
    $noClr = '\b(no|not|without|none|n/a)\b[^.\n]{0,30}\bclearance\b|\bclearance\b[^.\n;]{0,30}\b(none|not (required|needed|necessary|mentioned|listed|stated|specified|given)|no mention|unnecessary|n/a)\b|\bdoes(n.t| not) require[^.\n]{0,30}\bclearance\b'
    $c = [regex]::Replace($t, $noClr, ' ', $ci)
    if ([regex]::IsMatch($c, '\bclearance\b|\bTS/SCI\b|\bpublic trust\b', $ci)) { $score -= $penalty.clearance; $gaps.disqualifier += 'security clearance required' }
    # on-site: on-site/hybrid words, no remote option left after negations ("not a remote role"), and not in the home metro
    $noRem = '\b(no|not|non|without)\b[\s-]{1,3}(\w+[\s-]+){0,2}remote\b|\bremote\b[^.\n]{0,20}\b(not (available|offered|possible|allowed)|is not)\b'
    $r = [regex]::Replace($t, $noRem, ' ', $ci)
    $r = [regex]::Replace($r, '\b(on-?site|in[- ]office)\b[^.\n;]{0,20}\b(none|not (required|mentioned|listed|stated|specified|given)|no mention|n/a)\b', ' ', $ci)   # "on-site city: none mentioned" is the scout saying there is no on-site rule
    if ([regex]::IsMatch($r, '\b(on-?site|in[- ]office|in[- ]person|hybrid)\b', $ci) -and -not [regex]::IsMatch($r, '\bremote\b', $ci) -and -not ($HomeMetro -and [regex]::IsMatch($t, '\b' + [regex]::Escape($HomeMetro) + '\b', $ci))) {
        $score -= $penalty.onsite; $gaps.disqualifier += $(if ($HomeMetro) { "on-site or hybrid outside $HomeMetro, no remote option" } else { 'on-site or hybrid, no remote option' })
    }
    # experience: 5+ years asked for, senior-level title (first line only; "senior leadership" in the body is not a title)
    $yrs = 0
    foreach ($m in [regex]::Matches($t, '\b(\d{1,2})\s*\+?\s*(?:or more\s+)?years?\b', $ci)) { $n = [int]$m.Groups[1].Value; if ($n -gt $yrs -and $n -le 40) { $yrs = $n } }
    if ($yrs -ge 5) { $gaps.experience += "$yrs+ years asked for" }
    $title = ($t -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($title -and [regex]::IsMatch($title, '\b(senior|sr\.?|staff|principal|lead|architect)\b', $ci)) { $gaps.experience += 'senior-level title' }
    foreach ($g in $gapSkills.Keys) { if ([regex]::IsMatch($t, $gapSkills[$g], $ci)) { $gaps.skill += $g } }
    $score = [int][Math]::Max(0, [Math]::Min(100, $score))
    $verdict = if ($gaps.disqualifier.Count) { 'skip' } elseif ($score -ge $fitAt) { 'fit' } elseif ($score -ge $maybeAt) { 'maybe' } else { 'skip' }
    [ordered]@{ score = $score; verdict = $verdict; matched = @($matched); missing = @($missing); gaps = $gaps }
}

function Show-Fit($f) {
    "rank-fit: score $($f.score) verdict $($f.verdict)"
    "skills: $(if ($f.matched.Count) { $f.matched -join ', ' } else { 'none' })"
    foreach ($k in $f.gaps.Keys) { if ($f.gaps[$k].Count) { "gap $($k): $($f.gaps[$k] -join '; ')" } }
}

if (-not $Openings) {
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Output 'rank-fit: posting file not found'; exit 2 }
        $Text = [IO.File]::ReadAllText($Path)
    } elseif (-not $PSBoundParameters.ContainsKey('Text')) { Write-Output 'rank-fit: give -Text, -Path or -Openings'; exit 2 }
    $f = Get-Fit $Text
    if ($Json) { $f | ConvertTo-Json -Depth 5 } else { Show-Fit $f; "rank-fit: scored 1" }
    exit 0
}

# openings file: blocks that start with "- **Title** ..." (the scout's answer shape), up to the next block or heading
$Openings = $Openings.Replace('{{job}}', [string]$env:KITCHEN_JOB)
if (-not (Test-Path -LiteralPath $Openings -PathType Leaf)) { Write-Output 'rank-fit: openings file not found'; exit 2 }
$lines = [IO.File]::ReadAllText($Openings).Split("`n")
$blocks = [Collections.Generic.List[string]]::new(); $cur = $null
foreach ($l in $lines) {
    if ($l -match '^\s*([-*]|\d+[.)])\s+\*\*') { if ($null -ne $cur) { $blocks.Add($cur) }; $cur = $l }
    elseif ($l -match '^#') { if ($null -ne $cur) { $blocks.Add($cur) }; $cur = $null }
    elseif ($null -ne $cur) { $cur += "`n$l" }
}
if ($null -ne $cur) { $blocks.Add($cur) }
if ($blocks.Count -eq 0) { Write-Output 'rank-fit: no openings found in the file'; exit 1 }

$rows = @(foreach ($b in $blocks) {
    $f = Get-Fit $b
    $name = if ($b -match '\*\*([^*]{1,120})\*\*') { Clean $Matches[1] } else { 'opening' }
    $link = if ($b -match 'https?://[^\s)>\]]+') { Clean $Matches[0] } else { '' }
    [pscustomobject]@{ title = $name; link = $link; fit = $f }
})
$rows = @($rows | Sort-Object @{ e = { $_.fit.score }; Descending = $true }, @{ e = { $_.title } })
$out = @('# Fit ranking (deterministic, keyword-based)', '')
$i = 0
foreach ($r in $rows) {
    $i++
    $out += "$i. **$($r.title)**: $($r.fit.score) ($($r.fit.verdict)); skills: $(if ($r.fit.matched.Count) { $r.fit.matched -join ', ' } else { 'none' })"
    foreach ($k in $r.fit.gaps.Keys) { if ($r.fit.gaps[$k].Count) { $out += "   gap $($k): $($r.fit.gaps[$k] -join '; ')" } }
    if ($r.link) { $out += "   $($r.link)" }
}
if ($Json) { $rows | ForEach-Object { [ordered]@{ title = $_.title; link = $_.link; score = $_.fit.score; verdict = $_.fit.verdict; gaps = $_.fit.gaps } } | ConvertTo-Json -Depth 6 }
else { $out }
if (-not $OutDir) { $kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }; $OutDir = Join-Path $kroot 'jobscout' }
$stem = if ($env:KITCHEN_JOB -match '^[\w-]{1,40}$') { $env:KITCHEN_JOB } else { [IO.Path]::GetFileNameWithoutExtension($Openings) }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Set-Content -LiteralPath (Join-Path $OutDir "$stem-fit.md") -Value $out -Encoding utf8
"rank-fit: scored $($rows.Count)"
exit 0
