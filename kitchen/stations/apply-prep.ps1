# Station: the apply packet (career\packets\<id>\) for one tracked role. Two phases around the private local cook:
#   gather: makes profile.json if missing (empty values, never guessed), renders the locked resume when its source changed, reads the
#           posting's own questions (kitchen/ats.ps1: public Greenhouse/Lever/Ashby APIs), answers every question the profile can, and
#           writes ask.md: only the questions left for the cook, which answers them from the canonical resume and claims file alone.
#   build:  after the tailor check passed, turns the cook's draft into cover.txt, answers.json, link.txt, resume.pdf (a copy of the
#           locked resume) and packet.json (with the packet hash Chef shows and apply-submit checks), and marks the tracker row.
#   The resume source is kitchen.json "career".resume (Get-CareerFiles); packet.json records profile.json's hash and the resume source's,
#   so Chef asks for Rebuild instead of sending answers drawn from an older profile or resume.
#   step: {"station":"apply-prep","args":{"Phase":"gather","AppId":"A12"}}
# Never fills, clicks or submits anything; never prints profile.json. Exit: 0 done, 1 refused (failed check, no locked resume), 2 bad input.
param(
    [ValidateSet('gather', 'build')][string]$Phase = 'gather',
    [string]$AppId = '',
    [string]$Resume = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tracker-lib.ps1')
function Say([string]$m, [int]$code) { Write-Output "apply-prep: $m"; $global:LASTEXITCODE = $code; exit $code }

if ($AppId -notmatch '^A\d{1,5}$') { Say "invalid AppId '$AppId'" 2 }
$cf = Get-CareerFiles; $careerDir = $cf.dir   # the one resume source: kitchen.json "career".resume (cook.ps1 passes the same path as {{resume}})
if (-not $Resume) { $Resume = $cf.resume }
$Resume = [IO.Path]::GetFullPath($Resume)
if (-not $Resume.StartsWith($careerDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Say 'the resume must be a file inside the career folder' 2 }
$dir = Join-Path $careerDir "packets\$AppId"
$trackerPath = Join-Path $careerDir 'tracker.json'
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Utf8([string]$p, [string]$s) { [IO.File]::WriteAllText($p, $s, $utf8) }

# ---- profile.json: Jordan's standing answers. Created only when missing (CreateNew: never over a file he filled), never printed.
$profilePath = Join-Path $careerDir 'profile.json'
$template = [ordered]@{
    name = ''; email = ''; phone = ''; city = ''; state = ''; country = ''; linkedin = ''; github = ''; website = ''
    workAuthorization = ''; needsSponsorship = ''; salaryExpectation = ''; earliestStart = ''; willingToRelocate = ''
    remotePreference = ''; yearsExperience = ''; howDidYouHear = 'Company website'
    eeo = [ordered]@{ gender = 'Decline to self-identify'; race = 'Decline to self-identify'; veteran = 'Decline to self-identify'; disability = 'Decline to self-identify' }
}
function Initialize-Profile {
    if (Test-Path -LiteralPath $profilePath) { return }
    New-Item -ItemType Directory -Force -Path $careerDir | Out-Null
    try { $fs = [IO.File]::Open($profilePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write) } catch { return }   # someone made it meanwhile: theirs wins
    try { $b = $utf8.GetBytes(($template | ConvertTo-Json -Depth 4)); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
    Write-Output 'apply-prep: made an empty profile.json in the career folder; fill it in once to answer the standing questions'
}
function Read-Profile {
    try { $p = [IO.File]::ReadAllText($profilePath).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable -Depth 6 } catch { $p = $null }
    if ($p -isnot [Collections.IDictionary]) { Write-Host 'apply-prep: profile.json is not valid JSON; no question is answered from it'; return @{} }   # Write-Host: output here would land in the caller's variable
    $p
}
# a profile value as an answer: booleans read Yes/No, everything else as trimmed text
function Get-ProfileValue($p, [string]$field) {
    $v = if ($field -like 'eeo.*') { if ($p.eeo -is [Collections.IDictionary]) { $p.eeo[$field.Substring(4)] } } else { $p[$field] }
    if ($v -is [bool]) { return $(if ($v) { 'Yes' } else { 'No' }) }
    if ($null -eq $v) { return '' }
    ([string]$v).Trim()
}

# ---- question -> profile field. First match wins; EEO and the legal/sign-off kind come first so "gender identity" or "I certify my
#      answers are true" never reach a looser pattern. Anything unmatched goes to the cook (answered from the resume or marked for Jordan).
$eeoRules = @(@('eeo.gender', '\bgender\b|\bsex\b'), @('eeo.race', '\brace\b|ethnic|hispanic|latin[oax]'), @('eeo.veteran', 'veteran'), @('eeo.disability', 'disabilit'))
$jordanOnly = 'convict|criminal|felony|background check|drug (test|screen)|non-?compete|non-?solicit|arbitration|signature|e-?sign|\bi (certify|attest|agree|acknowledge|consent)\b|terms (of|and)|privacy (policy|notice)|\bconsent\b|reference'
$profileRules = @(
    @('needsSponsorship', 'sponsor|\bvisa\b'),
    @('workAuthorization', 'authori[sz]ed to work|legally (eligible|authori[sz]ed|permitted)|work authori[sz]ation|eligible to work|right to work'),
    @('salaryExpectation', 'salary|compensation|pay (expectation|range)|desired pay|expected pay'),
    @('earliestStart', 'start date|when can you start|earliest|available to start|notice period'),
    @('willingToRelocate', 'relocat'),
    @('yearsExperience', 'how many years|years of (professional |relevant |work )?experience'),
    @('howDidYouHear', 'how did you (hear|find|learn)|hear about (us|this)|where did you (hear|find|see)|referral source'),
    @('linkedin', 'linkedin'), @('github', 'github'), @('website', 'website|portfolio|personal (site|url)'),
    @('first', 'first name|given name|preferred name'), @('last', 'last name|surname|family name'), @('name', 'full name|legal name|your name|^name\W*$'),
    @('email', 'e-?mail'), @('phone', 'phone|mobile'),
    @('location', '^(current )?(location|city)\b|where are you (located|based)|current location'), @('state', '^(state|province)\b'), @('country', '^country\b'),
    @('remotePreference', '\bremote\b|hybrid|on-?site|in[- ]office|work arrangement|commute')
)
# a value must be one of a select question's options: exact, then "starts with" (No -> "No, I do not"), then the decline wording
function Find-Option([string]$v, $opts) {
    $opts = @($opts | Where-Object { $_ }); if (-not $opts.Count -or -not $v) { return $v }
    foreach ($o in $opts) { if ($o -ieq $v) { return $o } }
    foreach ($o in $opts) { if ($o -match ('(?i)^\s*' + [regex]::Escape($v) + '\b')) { return $o } }
    if ($v -match '(?i)decline|prefer not|not wish') { foreach ($o in $opts) { if ($o -match "(?i)decline|prefer not|not (wish|want) to|don.t wish") { return $o } } }
    $null
}

if ($Phase -eq 'gather') {
    Initialize-Profile
    $prof = Read-Profile
    $profileHash = Get-ProfileHash $profilePath   # what these answers were drawn from; packet.json carries it so Chef sees a later profile edit
    # the one locked resume: rendered from the canonical markdown, and again only when that markdown changed (pack-render compares the
    # source hash it recorded in resume-locked.json), so an edited resume reaches the next packet and an unchanged one never drifts
    $locked = Join-Path $careerDir 'resume-locked.pdf'
    $out = (& (Join-Path $PSScriptRoot 'pack-render.ps1') -LockedFrom $Resume | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $locked -PathType Leaf)) { Say "the locked resume could not be rendered from $(Split-Path -Leaf $Resume) ($out)" 1 }
    if ($out -notmatch 'up to date') { Write-Output $out }
    try { $items = Read-Tracker $trackerPath } catch { Say "tracker.json is unreadable ($($_.Exception.Message))" 2 }
    $it = $items | Where-Object { $_.id -eq $AppId } | Select-Object -First 1
    if (-not $it) { Say "no tracked role $AppId" 2 }

    # the posting's own questions; a site ats.ps1 can't read falls back to what Inspect saved on the row (or none: cover note only)
    $desc = [string]$it.description; $qs = @($it.questions | Where-Object { $_ })
    if ($it.link -match '^https?://') {
        $ats = & (Join-Path $PSScriptRoot '..\ats.ps1') -Url ([string]$it.link)
        if ($ats -and $ats.ok) { $qs = @($ats.questions); if ($ats.description) { $desc = [string]$ats.description } }
        else { Write-Output "apply-prep: could not read the posting's questions ($(if ($ats) { $ats.error } else { 'no answer' })); using what the tracker has" }
    }
    $answers = [Collections.Generic.List[object]]::new(); $ask = [Collections.Generic.List[string]]::new()
    foreach ($q in $qs) {
        $label = ([string]$(if ($q.label) { $q.label } else { $q.name })).Trim(); if (-not $label) { continue }
        $type = [string]$q.type; if ($type -match '(?i)hidden') { continue }
        $a = [ordered]@{ question = $label; name = [string]$(if ($q.name) { $q.name } else { $q.field_name }); type = $type; required = [bool]$q.required
            options = @($q.options | Where-Object { $_ } | ForEach-Object { [string]$_ }); answer = ''; source = 'profile'; needsJordan = $false; note = '' }
        $l = $label.ToLowerInvariant()
        $eeo = $eeoRules | Where-Object { $l -match $_[1] } | Select-Object -First 1
        $field = if ($eeo) { $null } else { $profileRules | Where-Object { $l -match $_[1] } | Select-Object -First 1 }
        if ($type -match '(?i)file' -and $l -match 'cover') { $a.answer = 'cover.txt'; $a.source = 'resume' }
        elseif ($type -match '(?i)file' -or ($l -match '^(resume|cv)\b' -and -not $eeo)) { $a.answer = 'resume.pdf'; $a.source = 'resume' }
        elseif ($eeo) {   # voluntary: only what Jordan set (the template says decline), otherwise blank and never flagged
            $v = Find-Option (Get-ProfileValue $prof $eeo[0]) $a.options
            if ($v) { $a.answer = $v } else { $a.note = 'voluntary, left blank' }
        }
        elseif ($l -match $jordanOnly) { $a.source = 'jordan'; $a.needsJordan = $true; $a.note = 'legal or sign-off: only you can answer this' }
        elseif ($field) {
            $f = $field[0]
            $v = switch ($f) {
                'first' { ((Get-ProfileValue $prof 'name') -split '\s+')[0] }
                'last' { $n = @((Get-ProfileValue $prof 'name') -split '\s+' | Where-Object { $_ }); if ($n.Count -gt 1) { $n[-1] } else { '' } }
                'location' { (@('city', 'state', 'country') | ForEach-Object { Get-ProfileValue $prof $_ } | Where-Object { $_ }) -join ', ' }
                default { Get-ProfileValue $prof $f }
            }
            $pick = Find-Option $v $a.options
            if ($pick) { $a.answer = $pick }
            elseif ($v) { $a.source = 'jordan'; $a.needsJordan = $a.required; $a.note = "profile.json says '$v', which is not one of the options" }
            elseif ($a.required) { $a.source = 'jordan'; $a.needsJordan = $true; $a.note = "add $(if ($f -in 'first', 'last') { 'name' } elseif ($f -eq 'location') { 'city' } else { $f }) to profile.json" }
            else { $a.note = 'optional, left blank' }
        }
        else { $a.source = 'resume'; $a.ask = $ask.Count + 1; $ask.Add("Q$($a.ask). $label$(if ($a.required) { ' (required)' })$(if ($a.options.Count) { ' Options: ' + ($a.options -join ' / ') })") }
        $answers.Add($a)
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Remove-Item -LiteralPath (Join-Path $dir 'draft.md') -Force -ErrorAction SilentlyContinue   # a cook that writes nothing must not find the last run's draft
    if (-not $desc.Trim()) { $desc = (@("$($it.role) at $($it.company)", [string]$it.notes) | Where-Object { $_ }) -join "`n" }
    $d = if ($desc.Length -gt 8000) { $desc.Substring(0, 8000) } else { $desc }
    Write-Utf8 (Join-Path $dir 'gather.json') ([ordered]@{ id = $AppId; company = [string]$it.company; role = [string]$it.role; link = [string]$it.link; profileHash = $profileHash; answers = $answers.ToArray() } | ConvertTo-Json -Depth 6)
    Write-Utf8 (Join-Path $dir 'ask.md') ("ROLE: $($it.role) at $($it.company)`n`nTHE POSTING:`n$d`n`nQUESTIONS FOR YOU TO ANSWER:`n" + $(if ($ask.Count) { $ask -join "`n" } else { '(none)' }) + "`n")
    Write-Output "APPLY-PREP GATHERED $($answers.Count) question(s): $($ask.Count) for the cook, $(@($answers | Where-Object { $_.needsJordan }).Count) for Jordan"
    exit 0
}

# ---- build
$gatherPath = Join-Path $dir 'gather.json'; $draftPath = Join-Path $dir 'draft.md'
if (-not (Test-Path -LiteralPath $gatherPath -PathType Leaf) -or -not (Test-Path -LiteralPath $draftPath -PathType Leaf)) { Say 'no gathered questions or no cook draft for this role; run the whole apply-prep recipe' 1 }
$g = [IO.File]::ReadAllText($gatherPath) | ConvertFrom-Json -AsHashtable -Depth 8
$raw = [IO.File]::ReadAllText($draftPath).Replace("`r`n", "`n")
# the taster's verdict on this draft; and a role whose tailor draft failed its check gets no packet either
if ($raw -notmatch '(?m)^- Result:\s*PASS\s*$' -or $raw -match '(?m)^- Result:\s*FAIL') { Say 'the draft did not pass the tailor check; no packet' 1 }
try { $items = Read-Tracker $trackerPath } catch { Say "tracker.json is unreadable ($($_.Exception.Message))" 2 }
$it = $items | Where-Object { $_.id -eq $AppId } | Select-Object -First 1
if (-not $it) { Say "no tracked role $AppId" 2 }
$tailored = @(@($it.drafts) | Where-Object { [string]$_ -match '^J\d{1,6}$' } | ForEach-Object { Join-Path $careerDir "tailored\$_-draft.md" } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Get-Item | Sort-Object LastWriteTime -Descending)
if ($tailored.Count -and [IO.File]::ReadAllText($tailored[0].FullName) -match '(?m)^- Result:\s*FAIL') { Say "this role's tailored draft failed the tailor check; no packet" 1 }
$locked = Join-Path $careerDir 'resume-locked.pdf'
if (-not (Test-Path -LiteralPath $locked -PathType Leaf)) { Say 'the locked resume is missing' 1 }
$srcSha = try { [string]([IO.File]::ReadAllText((Join-Path $careerDir 'resume-locked.json')) | ConvertFrom-Json).sourceSha256 } catch { '' }

$body = [regex]::Replace($raw, '(?ms)^# Tailor check[^\n]*\n.*\z', '')
function Get-Section([string]$name) { if ($body -match "(?msi)^#\s*$name\s*$\r?\n(.*?)(?=^#\s|\z)") { $Matches[1].Trim() } else { '' } }
# cover note: Jordan's fixed template; the cook only supplies one or two plain sentences from the resume
$lines = ((Get-Section 'Cover lines') -replace '(?m)^\s*[-*]\s*', '' -replace '\s+', ' ').Trim()
$sent = @([regex]::Matches($lines, '[^.!?]+[.!?]+') | ForEach-Object { $_.Value.Trim() } | Select-Object -First 2)
$lines = if ($sent.Count) { $sent -join ' ' } else { $lines }
if ($lines.Length -gt 400) { $lines = $lines.Substring(0, 400).Trim() }
$prof = if (Test-Path -LiteralPath $profilePath) { Read-Profile } else { @{} }
$me = Get-ProfileValue $prof 'name'; if (-not $me) { $me = 'Jordan' }
$cover = "Hello $($g.company) team,`n`nI'm applying for the $($g.role) role.$(if ($lines) { ' ' + $lines })`n`nI'd welcome the chance to talk about how I can help.`n`nThank you,`n$me`n"

$given = @{}
foreach ($m in [regex]::Matches(((Get-Section 'Answers') -replace '\*\*', ''), '(?ms)^\s*Q(\d+)[.:)]\s*(.*?)(?=^\s*Q\d+[.:)]|\z)')) { $given[[int]$m.Groups[1].Value] = $m.Groups[2].Value.Trim() }
$answers = foreach ($a in @($g.answers)) {
    if ($a.ask) {
        $t = [string]$given[[int]$a.ask]; if ($t.Length -gt 3000) { $t = $t.Substring(0, 3000) }
        $pick = if ($t -and @($a.options).Count) { Find-Option $t $a.options } else { $t }
        if (-not $t -or $t -match '(?i)NEEDS\s+JORDAN') { $a.answer = ''; $a.source = 'jordan'; $a.needsJordan = $true; $a.note = "the resume doesn't say; you answer" }
        elseif (-not $pick) { $a.answer = ''; $a.source = 'jordan'; $a.needsJordan = [bool]$a.required; $a.note = "the draft answer was not one of the options: $t" }
        else { $a.answer = $pick }
        $a.Remove('ask')
    }
    [ordered]@{ question = $a.question; name = $a.name; type = $a.type; required = [bool]$a.required; options = @($a.options); answer = [string]$a.answer; source = $a.source; needsJordan = [bool]$a.needsJordan; note = [string]$a.note }
}
$answers = @($answers)
Write-Utf8 (Join-Path $dir 'cover.txt') $cover
Write-Utf8 (Join-Path $dir 'answers.json') (ConvertTo-Json -InputObject $answers -Depth 5)
Write-Utf8 (Join-Path $dir 'link.txt') ([string]$g.link)
Copy-Item -LiteralPath $locked -Destination (Join-Path $dir 'resume.pdf') -Force
# packet hash: answers.json, cover.txt, link.txt, resume.pdf bytes in that order (pass-app/server.mjs packetHash does the same)
function Get-PacketHash {
    $sha = [Security.Cryptography.SHA256]::Create()
    foreach ($f in 'answers.json', 'cover.txt', 'link.txt', 'resume.pdf') { $b = [IO.File]::ReadAllBytes((Join-Path $dir $f)); [void]$sha.TransformBlock($b, 0, $b.Length, $null, 0) }
    [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0); ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
}
$hash = Get-PacketHash
$now = (Get-Date).ToUniversalTime().ToString('o')
$forYou = @($answers | Where-Object { $_.needsJordan }).Count
Write-Utf8 (Join-Path $dir 'packet.json') ([ordered]@{ id = $AppId; company = [string]$g.company; role = [string]$g.role; link = [string]$g.link; resume = 'resume.pdf'
    resumeSha256 = (Get-FileHash -LiteralPath $locked -Algorithm SHA256).Hash.ToLowerInvariant(); resumeSourceSha256 = $srcSha; profileHash = [string]$g.profileHash; hash = $hash; generatedAt = $now; questions = $answers.Count; needsJordan = $forYou } | ConvertTo-Json -Depth 3)
Move-Item -LiteralPath $draftPath -Destination (Join-Path $dir 'draft.built.md') -Force
try {
    Update-Tracker $trackerPath { param($items)
        $row = $items | Where-Object { $_.id -eq $AppId } | Select-Object -First 1; if (-not $row) { return $false }
        $row.packet = [ordered]@{ ready = $true; hash = $hash; generatedAt = $now; needsJordan = $forYou }; $row.changedAt = $now; $true }
} catch { Write-Output "apply-prep: warning: the packet is built but tracker.json was not updated ($($_.Exception.Message))" }
Write-Output "APPLY-PACKET READY $AppId ($($answers.Count) answer(s), $forYou for Jordan)"
exit 0
