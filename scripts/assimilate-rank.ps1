# Assimilation: rank what job posts ask for, so the next run (A-02, ...) builds what most posts want. No AI, local only, read-only
# on the scout files (career data never leaves the PC). Safe to re-run: yes.
# Reads every "- **Title** at Company ..." block in <scout>\*-openings.md, de-duplicates postings by link (else title+company), and
# counts, per skill family, the share of postings whose Must-haves line names it (a posting counts once per family).
#   assimilate-rank.ps1 [-ScoutDir <dir>] [-OutPath <file.md>] [-Json]
param([string]$ScoutDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain\projects\career\scout'), [string]$OutPath = '', [switch]$Json)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ScoutDir)) { Write-Output "ERROR: no scout folder at $ScoutDir"; exit 2 }
# skill families: each a regex over the must-haves text (word-bounded, case-insensitive). Extend here; every family is shown.
$families = [ordered]@{
    'TypeScript / JavaScript' = '\b(typescript|javascript|node\.?js|\bts\b)'
    'React (web or native)'   = '\breact'
    'Python'                  = '\bpython'
    'AI agents'               = '\bagent(s|ic)?\b'
    'LLM APIs'                = '\b(llm|large language|openai|anthropic|claude|gpt|gemini)'
    'APIs (REST, GraphQL)'    = '\b(rest(ful)?|graphql|api)s?\b'
    'Cloud (AWS, GCP, Azure)' = '\b(aws|gcp|google cloud|azure)\b'
    'Containers / CI/CD'      = '\b(docker|kubernetes|k8s|ci/cd|github actions|terraform)'
    'Databases / SQL'         = '\b(sql|postgres(ql)?|mysql|mongo(db)?|database)'
    'Security'                = '\b(security|secure|oauth|soc ?2|compliance)'
    'RAG / retrieval'         = '\b(rag|retrieval|vector|embedding)'
    'MCP'                     = '\bmcp\b|model context protocol'
    'Evals / testing AI'      = '\b(evals?|evaluation)\b'
    'Mobile (iOS, Android)'   = '\b(ios|android|mobile)\b'
    'PowerShell'              = '\bpowershell\b'
    'Microsoft 365 / Entra'   = '\b(microsoft 365|m365|office 365|entra|intune|azure ad)\b'
}
$posts = @{}
foreach ($f in Get-ChildItem -LiteralPath $ScoutDir -Filter '*-openings.md' -File) {
    $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8
    foreach ($b in [regex]::Split($text, '(?m)^(?=- \*\*)') | Where-Object { $_ -match '^- \*\*' }) {
        $head = [regex]::Match($b, '^- \*\*(.+?)\*\* at (.+?)[ (.]'); if (-not $head.Success) { continue }
        $link = [regex]::Match($b, '(?m)^\s*Link:\s*(\S+)').Groups[1].Value
        $key = if ($link) { $link.ToLowerInvariant() } else { ($head.Groups[1].Value + '|' + $head.Groups[2].Value).ToLowerInvariant() }
        $must = [regex]::Match($b, '(?ms)^\s*Must-haves:\s*(.+?)(?=^\s*Link:|\z)').Groups[1].Value
        # the scout appends "security clearance: ..." and "location/on-site city: ..." to every line: facts about the job, not skills
        $must = [regex]::Replace($must, '(?i)security clearance:[^;]*;?|(on-site city|location):.*$', '')
        if (-not $posts.ContainsKey($key)) { $posts[$key] = @{ title = $head.Groups[1].Value; company = $head.Groups[2].Value; must = $must; file = $f.Name } }
    }
}
$n = $posts.Count
if (-not $n) { Write-Output "ERROR: no postings found in $ScoutDir\*-openings.md"; exit 1 }
$noMust = @($posts.Values | Where-Object { -not $_.must.Trim() }).Count
$withMust = $n - $noMust
if (-not $withMust) { Write-Output 'ERROR: no posting has a Must-haves line'; exit 1 }
$rows = foreach ($k in $families.Keys) {
    $hit = @($posts.Values | Where-Object { $_.must -match ('(?i)' + $families[$k]) }).Count
    [pscustomobject]@{ family = $k; postings = $hit; share = [math]::Round(100 * $hit / $withMust) }
}
$rows = @($rows | Sort-Object postings -Descending)
$at = Get-Date -Format 'yyyy-MM-dd HH:mm'
if ($Json) { @{ ok = $true; at = $at; postings = $n; withoutMustHaves = $noMust; families = $rows } | ConvertTo-Json -Depth 4 -Compress; exit 0 }
$md = @("# What job posts ask for (Assimilation ranking)", "", "Built $at by brain-monitor/scripts/assimilate-rank.ps1 from $n unique postings in projects/career/scout/*-openings.md ($noMust without a Must-haves line are left out of the shares, so the base is $withMust).",
    "Share = postings whose must-haves name the family (a posting counts once per family). Counted by keyword, so read it as a ranking, not a census.", "",
    "| Skill family | Postings | Share |", "|---|---|---|") + @($rows | ForEach-Object { "| $($_.family) | $($_.postings) | $($_.share)% |" })
if ($OutPath) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath) | Out-Null; Set-Content -LiteralPath $OutPath -Value ($md -join "`n") -Encoding utf8; Write-Output "wrote $OutPath ($n postings)" } else { $md }
exit 0
