# Station: the tailor's taster. Checks a tailored draft against the job posting and the claims file, with no model involved.
# Read-only except for the draft, which gets one "# Tailor check" scorecard appended (a re-run replaces it).
#   - ATS keyword coverage: tools and technical terms found in the posting that appear in Summary, Bullets or Cover note.
#   - Claims: any forbidden phrase from the claims file's "avoid / cannot defend" lists found in Summary, Bullets or Cover note.
# Exit codes: 0 pass, 1 forbidden phrase or coverage below -Threshold, 2 bad input (missing file, no posting). No off-limits list is a note, not an error.
#   step: {"station":"tailor-check","args":{"Draft":"...-draft.md","Claims":"...claims_to_defend.md","Posting":"{{posting}}"},"mustMatch":"TAILOR-CHECK PASS"}
#   -Resume: Jordan's canonical resume. When given, coverage counts only posting terms the resume holds (an honest draft is not failed
#     for skills he lacks), and a tool or "N+ years" in the scored sections that the resume never mentions fails as unsupported.
#   -Sections: which draft headings are scored (comma list). The pack recipe scores 'resume html,draft answers' (tags are stripped).
param(
    [string]$Draft = '',
    [string]$Claims = '',
    [string]$Posting = '',
    [string]$PostingFile = '',
    [double]$Threshold = 50,
    [string]$Resume = '',
    [string]$Sections = 'summary,bullets,cover note'
)
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
# runtime token: the supervisor names the order in KITCHEN_JOB (the agent step fills {{job}} itself; a script station has to)
if ($env:KITCHEN_JOB -match '^J\d+$') { $Draft = $Draft.Replace('{{job}}', $env:KITCHEN_JOB) }

function Bad([string]$m) { Write-Output "TAILOR-CHECK ERROR: $m"; exit 2 }

# Tools and terms recognised by name, on top of acronyms and mixed-case tokens found by shape.
$lexicon = @(
    'python', 'powershell', 'bash', 'java', 'javascript', 'typescript', 'kotlin', 'swift', 'rust', 'ruby', 'php', 'scala', 'sql', 'nosql',
    'react', 'angular', 'vue', 'node.js', 'django', 'flask', 'fastapi', '.net', 'c#', 'c++',
    'aws', 'azure', 'gcp', 'docker', 'kubernetes', 'terraform', 'ansible', 'jenkins', 'github actions', 'ci/cd', 'linux', 'windows',
    'postgresql', 'postgres', 'mysql', 'mongodb', 'redis', 'kafka', 'elasticsearch', 'snowflake', 'oracle', 'sqlite',
    'git', 'jira', 'confluence', 'splunk', 'datadog', 'grafana', 'prometheus', 'tableau', 'power bi', 'excel', 'salesforce', 'servicenow',
    'graphql', 'grpc', 'api', 'microservices', 'machine learning', 'llm', 'agile', 'scrum', 'devops', 'sre', 'etl', 'oauth', 'saml', 'sso'
)
# roman numerals in titles ("Engineer II"), places and levels are not skills a resume can hold (they failed honest drafts: J115)
$stop = @('THE', 'AND', 'FOR', 'YOU', 'OUR', 'WITH', 'ARE', 'NOT', 'BUT', 'ALL', 'ANY', 'CAN', 'WILL', 'USA', 'EEO', 'PTO', 'FAQ', 'ASAP', 'TBD',
    'II', 'III', 'IV', 'VI', 'US', 'UK', 'EU', 'SR', 'JR', 'CO', 'TX', 'CA', 'NY', 'WA', 'MST', 'PST', 'EST', 'CST')

function Get-Keywords([string]$text) {
    $found = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    $add = { param([string]$k) $key = $k.ToLowerInvariant(); if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $found.Add($k) } }
    foreach ($t in $lexicon) {
        if ($text -match ('(?i)(?<![\w+#.])' + [regex]::Escape($t) + '(?![\w+#])')) { & $add $t }
    }
    # Acronyms: two or more capitals, optionally with digits or slashes (SQL, CI/CD, S3).
    foreach ($m in [regex]::Matches($text, '(?<![\w])[A-Z][A-Z0-9]*(?:/[A-Z0-9]+)?(?![\w])')) {
        if ($m.Value.Length -ge 2 -and $stop -notcontains $m.Value) { & $add $m.Value }
    }
    # Mixed-case product names (JavaScript, PostgreSQL, GitHub) and dotted ones (Node.js, ASP.NET).
    foreach ($m in [regex]::Matches($text, '(?<![\w])(?:[A-Z][a-z0-9]+){2,}(?![\w])|(?<![\w])[A-Za-z]+\.(?:js|NET|io)(?![\w])')) { & $add $m.Value }
    $found.ToArray()
}

function Test-Term([string]$text, [string]$term) {
    $text -match ('(?i)(?<![\w+#])' + [regex]::Escape($term) + '(?![\w+#])')
}

# Splits markdown on its "# " / "## " headings into name -> body.
function Get-Sections([string]$md) {
    $sec = @{}; $name = ''
    foreach ($line in ($md -split '\r?\n')) {
        if ($line -match '^#{1,2}\s+(.+?)\s*$') { $name = $Matches[1].ToLowerInvariant(); if (-not $sec.ContainsKey($name)) { $sec[$name] = '' }; continue }
        if ($name) { $sec[$name] += $line + "`n" }
    }
    $sec
}

# Forbidden phrases: bullets under any heading that says avoid / never / cannot / do not / unapproved.
function Get-Forbidden([string]$md) {
    $out = [System.Collections.Generic.List[string]]::new()
    $level = 0
    $q1 = [char]0x201C; $q2 = [char]0x201D
    foreach ($line in ($md -split '\r?\n')) {
        if ($line -match '^(#{1,6})\s+(.+?)\s*$') {
            $lv = $Matches[1].Length
            if ($Matches[2] -match "(?i)avoid|forbid|never|cannot|can't|can not|do not|don't|not defend|unapproved|off.?limits") { $level = $lv }
            elseif ($level -and $lv -le $level) { $level = 0 }
            continue
        }
        if (-not $level) { continue }
        if ($line -notmatch '^\s*(?:[-*+]|\d+[.)])\s+(.+?)\s*$') { continue }
        $item = ($Matches[1] -replace '\*\*|__', '').Trim()
        $quoted = [regex]::Matches($item, "[`"$q1$q2``]([^`"$q1$q2``]{3,})[`"$q1$q2``]")
        if ($quoted.Count -gt 0) { foreach ($m in $quoted) { $out.Add($m.Groups[1].Value.Trim()) }; continue }
        $first = ($item -split '\s+[-–—]\s+|:\s|\s\(')[0].Trim().TrimEnd('.', ';', ',')
        if ($first.Length -ge 3) { $out.Add($first) }
    }
    @($out | Select-Object -Unique)
}

if (-not $Draft -or -not (Test-Path -LiteralPath $Draft -PathType Leaf)) { Bad "draft not found: $Draft" }
if (-not $Claims -or -not (Test-Path -LiteralPath $Claims -PathType Leaf)) { Bad "claims file not found: $Claims" }
if (-not $Posting -and $PostingFile) {
    if (-not (Test-Path -LiteralPath $PostingFile -PathType Leaf)) { Bad "posting file not found: $PostingFile" }
    $Posting = Get-Content -LiteralPath $PostingFile -Raw -Encoding utf8
}
if ([string]::IsNullOrWhiteSpace($Posting)) { Bad 'no posting text (pass -Posting or -PostingFile)' }
if ($Resume -and -not (Test-Path -LiteralPath $Resume -PathType Leaf)) { Bad "resume not found: $Resume" }

# The overnight hunt passes the scout's summary block, not the posting: "- **Title** at Company (where). Pay." then Fit:/Must-haves:/Link:.
# Keep the title and the posting's own words; the company, place, the scout's Fit: commentary and links are not skills to cover.
$company = ''
$postLines = foreach ($l in ($Posting -split '\r?\n')) {
    if ($l -match '^\s*[-*]\s+\*\*([^*]+)\*\*\s+at\s+([^(.\n]+)') { $company = $Matches[2].Trim(); $Matches[1]; continue }
    if ($l -match '^\s*(Fit|Link):') { continue }
    $l -replace 'https?://\S+', ' '
}
$Posting = $postLines -join "`n"

$forbidden = @(Get-Forbidden (Get-Content -LiteralPath $Claims -Raw -Encoding utf8))
# a claims file may only list claims to be ready to defend (Jordan's does): then there is nothing off-limits to check, only coverage
if ($forbidden.Count -eq 0) { Write-Output 'TAILOR-CHECK NOTE: no claims are marked off-limits in the claims file (bullets under an avoid/cannot/never heading); checking keyword coverage only' }

# Drop any earlier scorecard so a re-run replaces it instead of scoring itself.
$raw = Get-Content -LiteralPath $Draft -Raw -Encoding utf8
$body = [regex]::Replace($raw, '(?ms)^# Tailor check[^\n]*\n.*\z', '').TrimEnd()
$secMap = Get-Sections $body
$want = @($Sections -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$scored = (@($want | ForEach-Object { $secMap[$_] }) | Where-Object { $_ }) -join "`n"
$scored = [Net.WebUtility]::HtmlDecode(($scored -replace '<[^>]+>', ' '))   # a pack scores resume HTML: tags are not words
if ([string]::IsNullOrWhiteSpace($scored)) { Bad "draft has no $($want -join ' / ') section" }

$keywords = @(Get-Keywords $Posting | Where-Object { -not $company -or $_ -ne $company })
$unsupported = @()
if ($Resume) {
    $resumeText = Get-Content -LiteralPath $Resume -Raw -Encoding utf8
    # honest coverage: only terms the resume holds can be asked of the draft (the rest belong under Gaps)
    # "the resume holds it" is a plain substring test on purpose: "SQL" is backed by "PostgreSQL", "API" by "REST APIs". Lenient here
    # means an honest draft is never failed for rewording; a tool the resume never names at all still fails.
    $inResume = { param([string]$t) $resumeText.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
    $keywords = @($keywords | Where-Object { & $inResume $_ })
    # a named tool or an "N+ years" in the scored text that the resume never says is an invented claim
    $unsupported = @(@($lexicon | Where-Object { (Test-Term $scored $_) -and -not (& $inResume $_) }) +
        @([regex]::Matches($scored, '(?i)\b\d{1,2}\s*\+?\s*years?\b') | ForEach-Object { $_.Value } | Where-Object { $resumeText -notmatch ('(?i)\b' + [regex]::Escape(($_ -replace '\s+', ' '))) }) | Select-Object -Unique)
}
$matched = @($keywords | Where-Object { Test-Term $scored $_ })
$missing = @($keywords | Where-Object { $matched -notcontains $_ })
$coverage = if ($keywords.Count -gt 0) { [math]::Round(100.0 * $matched.Count / $keywords.Count, 1) } else { $null }
$covText = if ($null -eq $coverage) { 'n/a' } else { $coverage.ToString('0.0', $inv) + '%' }

$flat = ($scored -replace '\s+', ' ')
$hits = @($forbidden | Where-Object { Test-Term $flat (($_ -replace '\s+', ' ')) })

$problems = @()
if ($hits.Count -gt 0) { $problems += "forbidden phrase(s): $($hits -join '; ')" }
if ($unsupported.Count -gt 0) { $problems += "not in the resume: $($unsupported -join '; ')" }
if ($null -ne $coverage -and $coverage -lt $Threshold) { $problems += "coverage $covText is below the $($Threshold.ToString('0.#', $inv))% threshold" }
$verdict = if ($problems.Count -eq 0) { 'PASS' } else { 'FAIL' }

$card = @(
    '', '', '# Tailor check',
    "- Keyword coverage: $covText ($($matched.Count) of $($keywords.Count) posting terms)",
    "- Matched: $(if ($matched.Count) { $matched -join ', ' } else { 'none' })",
    "- Missing: $(if ($missing.Count) { $missing -join ', ' } else { 'none' })",
    "- Forbidden phrases: $(if ($hits.Count) { $hits -join '; ' } else { 'none' })",
    "- Not in the resume: $(if (-not $Resume) { 'not checked' } elseif ($unsupported.Count) { $unsupported -join '; ' } else { 'none' })",
    "- Threshold: $($Threshold.ToString('0.#', $inv))%",
    "- Result: $verdict"
) -join "`n"
Set-Content -LiteralPath $Draft -Value ($body + $card + "`n") -Encoding utf8 -NoNewline

Write-Output "TAILOR-CHECK $verdict coverage=$covText matched=$($matched.Count)/$($keywords.Count) forbidden=$($hits.Count) unsupported=$($unsupported.Count)"
foreach ($p in $problems) { Write-Output "  - $p" }
exit ([int]($problems.Count -gt 0))
