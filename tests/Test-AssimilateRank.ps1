# Tests for scripts/assimilate-rank.ps1: postings de-duplicated by link, each counted once per skill family, the scout's
# "security clearance" and location tails never counted as skills, shares over postings that have must-haves. Fakes only (TEMP).
$ErrorActionPreference = 'Stop'
$rank = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\assimilate-rank.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-rank-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Set-Content (Join-Path $root 'J1-openings.md') @'
# Openings

- **Engineer A** at Acme (Remote). Posted Oct 1.
  Must-haves: "TypeScript and React", "LLM APIs (Anthropic)", "TypeScript again", security clearance: none required; location: "Remote, USA".
  Link: https://example.test/a

- **Engineer B** at Beta (Springfield). Posted Oct 2.
  Must-haves: "Python and REST APIs", security clearance: none; on-site city: "Springfield".
  Link: https://example.test/b

- **Engineer C** at Gamma (Remote). Posted Oct 3.
  Fit: no must-haves line in this one.
  Link: https://example.test/c
'@ -Encoding utf8
    Set-Content (Join-Path $root 'J2-openings.md') @'
- **Engineer A** at Acme (Remote). Posted Oct 1.
  Must-haves: "TypeScript and React", security clearance: none.
  Link: https://example.test/a
'@ -Encoding utf8
    $o = & pwsh -NoProfile -File $rank -ScoutDir $root -Json | Select-Object -Last 1 | ConvertFrom-Json
    $f = @{}; foreach ($r in $o.families) { $f[$r.family] = $r }
    Check 'postings de-duplicated by link (3, not 4)' ($o.postings -eq 3 -and $o.withoutMustHaves -eq 1)
    Check 'a posting counts once per family (TypeScript twice in A = 1)' ($f['TypeScript / JavaScript'].postings -eq 1)
    Check 'shares are over postings with must-haves (1 of 2 = 50%)' ($f['TypeScript / JavaScript'].share -eq 50 -and $f['Python'].share -eq 50)
    Check '"security clearance: none" is not a security skill' ($f['Security'].postings -eq 0)
    Check 'APIs and LLM families found (A says LLM APIs, B says REST APIs)' ($f['APIs (REST, GraphQL)'].postings -eq 2 -and $f['LLM APIs'].postings -eq 1)
    Check 'every family is listed, even at zero' (@($o.families).Count -ge 16 -and $f['MCP'].postings -eq 0)
    $md = Join-Path $root 'out\rank.md'; & pwsh -NoProfile -File $rank -ScoutDir $root -OutPath $md | Out-Null
    Check 'markdown table written' ((Get-Content $md -Raw) -match '\| TypeScript / JavaScript \| 1 \| 50% \|')
    & pwsh -NoProfile -File $rank -ScoutDir (Join-Path $root 'nope') | Out-Null
    Check 'a missing scout folder exits 2' ($LASTEXITCODE -eq 2)
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "AssimilateRank tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
