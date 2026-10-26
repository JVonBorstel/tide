#requires -Version 7
<#
Tests for kitchen/tailor-check.ps1 (ATS keyword coverage, forbidden claims, exit codes, scorecard) and its recipe wiring.
Offline only: temp files, no model, no network.
#>
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script = Join-Path $repo 'kitchen\tailor-check.ps1'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-tailorcheck-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null

$pass = 0; $fail = 0
function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $name $detail" -ForegroundColor Red }
}

# Runs the script in its own pwsh so its exit code is real; returns the exit code and the output text.
function Invoke-Check([hashtable]$p) {
    $a = @('-NoProfile', '-File', $script)
    foreach ($k in $p.Keys) { $a += "-$k"; $a += [string]$p[$k] }
    $out = & pwsh @a 2>&1 | Out-String
    @{ code = $LASTEXITCODE; out = $out }
}

function New-Draft([string]$name, [string]$summary, [string]$bullets, [string]$cover, [string]$gaps = 'Nothing.') {
    $p = Join-Path $tmp $name
    Set-Content -LiteralPath $p -Encoding utf8 -Value "# Fit`nGood.`n# Summary`n$summary`n# Bullets`n$bullets`n# Cover note`n$cover`n# Gaps`n$gaps`n"
    $p
}

try {
    $claims = Join-Path $tmp 'claims.md'
    Set-Content -LiteralPath $claims -Encoding utf8 -Value @'
# Claims he can defend
- Python scripting
- "Docker" in daily use

# Claims to avoid
- "led a team of 50"
- **Kubernetes expert** - never ran production clusters
- Fluent in Rust

# Notes
- "mentioned only here" is not a forbidden claim
'@
    $posting = 'We need Python, Docker and Kubernetes experience, plus SQL.'

    # Coverage math: python, docker, kubernetes, sql -> 3 of 4 matched
    $d = New-Draft 'a.md' 'Python and Docker engineer.' '- Wrote SQL reports.' 'Happy to talk.' 'Kubernetes: not yet.'
    $r = Invoke-Check @{ Draft = $d; Claims = $claims; Posting = $posting; Threshold = 50 }
    Check 'coverage: 75.0 percent' ($r.out -match 'coverage=75\.0%' -and $r.out -match 'matched=3/4') $r.out
    Check 'coverage: passes above threshold, exit 0' ($r.code -eq 0 -and $r.out -match 'TAILOR-CHECK PASS') $r.out
    $card = Get-Content -LiteralPath $d -Raw
    Check 'scorecard: appended once with missing term' (([regex]::Matches($card, '(?m)^# Tailor check')).Count -eq 1 -and $card -match 'Missing: kubernetes' -and $card -match 'Keyword coverage: 75\.0%') $card

    # Re-run replaces the scorecard instead of stacking or scoring itself
    $r2 = Invoke-Check @{ Draft = $d; Claims = $claims; Posting = $posting }
    $card2 = Get-Content -LiteralPath $d -Raw
    Check 'scorecard: idempotent on re-run' (([regex]::Matches($card2, '(?m)^# Tailor check')).Count -eq 1 -and $r2.out -match 'coverage=75\.0%') $card2

    # Gaps are not scored: Kubernetes only in Gaps stays missing; 0 percent and 100 percent
    $d0 = New-Draft 'zero.md' 'Generalist.' '- Did things.' 'Hello.' 'Python Docker Kubernetes SQL'
    $r0 = Invoke-Check @{ Draft = $d0; Claims = $claims; Posting = $posting; Threshold = 0 }
    Check 'coverage: 0.0 percent, terms in Gaps do not count' ($r0.out -match 'coverage=0\.0%' -and $r0.out -match 'matched=0/4') $r0.out
    $d100 = New-Draft 'full.md' 'python docker KUBERNETES sql' '- x' 'y'
    $r100 = Invoke-Check @{ Draft = $d100; Claims = $claims; Posting = $posting; Threshold = 100 }
    Check 'coverage: 100.0 percent, case-insensitive' ($r100.out -match 'coverage=100\.0%' -and $r100.code -eq 0) $r100.out

    # Whole-word matching: "Pythonic" and "sqlite" must not count for python / sql
    $dw = New-Draft 'word.md' 'Pythonic code and sqlite.' '- x' 'y'
    $rw = Invoke-Check @{ Draft = $dw; Claims = $claims; Posting = $posting; Threshold = 0 }
    Check 'coverage: whole words only' ($rw.out -match 'matched=0/4') $rw.out

    # Determinism
    $da = New-Draft 'det1.md' 'Python Docker' '- x' 'y'
    $db = New-Draft 'det2.md' 'Python Docker' '- x' 'y'
    $ra = Invoke-Check @{ Draft = $da; Claims = $claims; Posting = $posting }
    $rb = Invoke-Check @{ Draft = $db; Claims = $claims; Posting = $posting }
    Check 'coverage: deterministic' ($ra.out -eq $rb.out -and (Get-Content -LiteralPath $da -Raw) -eq (Get-Content -LiteralPath $db -Raw))

    # No extractable keywords: n/a, passes coverage
    $dn = New-Draft 'na.md' 'Plain text.' '- x' 'y'
    $rn = Invoke-Check @{ Draft = $dn; Claims = $claims; Posting = 'We value kindness and curiosity.' }
    Check 'coverage: no keywords gives n/a and passes' ($rn.out -match 'coverage=n/a' -and $rn.code -eq 0) $rn.out

    # Below threshold: exit 1
    $dl = New-Draft 'low.md' 'Python only.' '- x' 'y'
    $rl = Invoke-Check @{ Draft = $dl; Claims = $claims; Posting = $posting; Threshold = 80 }
    Check 'threshold: below gives exit 1 and FAIL' ($rl.code -eq 1 -and $rl.out -match 'TAILOR-CHECK FAIL' -and $rl.out -match 'below') $rl.out

    # Forbidden claims: bullets, cover note, and quoted / bold / plain list items
    $fb = New-Draft 'fb.md' 'Python Docker Kubernetes SQL.' '- I led a team of 50 engineers.' 'Fine.'
    $rfb = Invoke-Check @{ Draft = $fb; Claims = $claims; Posting = $posting }
    Check 'forbidden: phrase in Bullets, exit 1' ($rfb.code -eq 1 -and $rfb.out -match 'led a team of 50') $rfb.out
    Check 'forbidden: scorecard lists the hit' ((Get-Content -LiteralPath $fb -Raw) -match 'Forbidden phrases: led a team of 50') (Get-Content -LiteralPath $fb -Raw)

    $fc = New-Draft 'fc.md' 'Python Docker Kubernetes SQL.' '- ok' 'As a Kubernetes expert I would help.'
    $rfc = Invoke-Check @{ Draft = $fc; Claims = $claims; Posting = $posting }
    Check 'forbidden: bold item caught in Cover note' ($rfc.code -eq 1 -and $rfc.out -match 'Kubernetes expert') $rfc.out

    $fp = New-Draft 'fp.md' 'Python Docker Kubernetes SQL.' '- Fluent in RUST.' 'ok'
    $rfp = Invoke-Check @{ Draft = $fp; Claims = $claims; Posting = $posting }
    Check 'forbidden: plain item matched case-insensitively' ($rfp.code -eq 1) $rfp.out

    $fg = New-Draft 'fg.md' 'Python Docker Kubernetes SQL.' '- ok' 'ok' 'I never led a team of 50; that is a gap.'
    $rfg = Invoke-Check @{ Draft = $fg; Claims = $claims; Posting = $posting }
    Check 'forbidden: phrase only in Gaps is ignored' ($rfg.code -eq 0) $rfg.out

    $fe = New-Draft 'fe.md' 'Python Docker Kubernetes SQL.' '- Wrote a mentioned only here note.' 'ok'
    $rfe = Invoke-Check @{ Draft = $fe; Claims = $claims; Posting = $posting }
    Check 'forbidden: only the avoid heading counts' ($rfe.code -eq 0) $rfe.out

    # Bad input: exit 2
    $r = Invoke-Check @{ Draft = (Join-Path $tmp 'nope.md'); Claims = $claims; Posting = $posting }
    Check 'exit 2: missing draft' ($r.code -eq 2) $r.out
    $r = Invoke-Check @{ Draft = $d; Claims = (Join-Path $tmp 'nope-claims.md'); Posting = $posting }
    Check 'exit 2: missing claims file' ($r.code -eq 2) $r.out
    $r = Invoke-Check @{ Draft = $d; Claims = $claims; Posting = ' ' }
    Check 'exit 2: empty posting' ($r.code -eq 2) $r.out
    $noList = Join-Path $tmp 'nolist.md'
    Set-Content -LiteralPath $noList -Encoding utf8 -Value "# Claims he can defend`n- Python`n"
    $r = Invoke-Check @{ Draft = $d; Claims = $noList; Posting = $posting }
    Check 'a claims file with no off-limits list: a note, and coverage is still checked (Jordan''s file only lists claims to defend)' ($r.out -match 'TAILOR-CHECK NOTE: no claims are marked off-limits' -and $r.out -match 'TAILOR-CHECK (PASS|FAIL) coverage=' -and $r.code -ne 2) $r.out
    $pf = Join-Path $tmp 'posting.txt'
    Set-Content -LiteralPath $pf -Encoding utf8 -Value $posting
    $r = Invoke-Check @{ Draft = (New-Draft 'pf.md' 'Python Docker Kubernetes SQL' '- x' 'y'); Claims = $claims; PostingFile = $pf }
    Check 'posting: -PostingFile works' ($r.code -eq 0 -and $r.out -match 'coverage=100\.0%') $r.out

    # Scout-shaped posting (what the overnight hunt passes): title numerals, place, company, Fit: and Link: are not keywords (J115)
    $scout = "- **Software Engineer II** at ExampleCo (remote, US / Oregon). Pay not listed.`n  Fit: strong TypeScript match; gap: Go.`n  Must-haves: React, Python, TypeScript; UI work.`n  Link: https://example.com/ExampleCo/jobs/1"
    $ds = New-Draft 'scout.md' 'Python and TypeScript engineer.' '- Built web front ends.' 'Hello.'
    $scoutFile = Join-Path $tmp 'scout.txt'; Set-Content -LiteralPath $scoutFile -Encoding utf8 -Value $scout   # a leading '-' can't go on a pwsh command line
    $rs = Invoke-Check @{ Draft = $ds; Claims = $claims; PostingFile = $scoutFile }
    Check 'scout block: II, US, company and links are not scored; an honest draft passes' ($rs.code -eq 0 -and $rs.out -match 'TAILOR-CHECK PASS' -and (Get-Content -LiteralPath $ds -Raw) -notmatch 'Missing: .*\b(II|US|ExampleCo)\b') $rs.out

    # -Resume: coverage only over terms the resume holds; tools or years the resume never says fail as unsupported
    $resume = Join-Path $tmp 'resume.md'
    Set-Content -LiteralPath $resume -Encoding utf8 -Value "Jordan. Python and Docker. About 3 years in engineering roles."
    $dh = New-Draft 'honest.md' 'Python and Docker engineer.' '- Shipped Docker services.' 'Hi.' 'Kubernetes and SQL: not yet.'
    $rh = Invoke-Check @{ Draft = $dh; Claims = $claims; Posting = $posting; Resume = $resume }
    Check 'resume: honest draft passes (Kubernetes/SQL are not asked of it)' ($rh.code -eq 0 -and $rh.out -match 'matched=2/2' -and $rh.out -match 'unsupported=0') $rh.out
    $di = New-Draft 'invented.md' 'Python, Docker and Kubernetes engineer with 7+ years.' '- Ran Kubernetes clusters.' 'Hi.'
    $ri = Invoke-Check @{ Draft = $di; Claims = $claims; Posting = $posting; Resume = $resume }
    Check 'resume: invented tool and years fail as not in the resume' ($ri.code -eq 1 -and $ri.out -match 'not in the resume: .*kubernetes' -and $ri.out -match '7\+ years') $ri.out
    $r = Invoke-Check @{ Draft = $dh; Claims = $claims; Posting = $posting; Resume = (Join-Path $tmp 'nope-resume.md') }
    Check 'resume: missing resume file is exit 2' ($r.code -eq 2) $r.out

    # -Sections: the pack draft (resume HTML + answers) is scored with tags stripped
    $pk = Join-Path $tmp 'pack-draft.md'
    Set-Content -LiteralPath $pk -Encoding utf8 -Value "# Resume HTML`n<section><h2>Skills</h2><p>Python, Docker</p></section>`n# Draft Answers`nI use Docker daily."
    $rp = Invoke-Check @{ Draft = $pk; Claims = $claims; Posting = $posting; Resume = $resume; Sections = 'resume html,draft answers' }
    Check 'sections: pack draft scored from resume html and answers' ($rp.code -eq 0 -and $rp.out -match 'matched=2/2') $rp.out

    # Recipe wiring
    $rec = Get-Content -LiteralPath (Join-Path $repo 'kitchen\recipes\tailor.json') -Raw | ConvertFrom-Json
    $cfg = Get-Content -LiteralPath (Join-Path $repo 'kitchen\kitchen.json') -Raw | ConvertFrom-Json
    Check 'recipe: two steps, check second' (@($rec.steps).Count -eq 2 -and $rec.steps[1].station -eq 'tailor-check')
    Check 'recipe: check step taster and no retries' ($rec.steps[1].mustMatch -eq 'TAILOR-CHECK PASS' -and $rec.steps[1].retries -eq 0)
    Check 'recipe: check reads the draft step 1 saves' ($rec.steps[1].args.Draft -eq $rec.steps[0].args.SaveTo -and $rec.steps[1].args.Posting -eq '{{posting}}')
    Check 'recipe: check reads the canonical resume (unsupported claims, honest coverage)' ($rec.steps[1].args.Resume -eq '{{resume}}' -and $rec.steps[0].args.Context -match [regex]::Escape($rec.steps[1].args.Resume))
    Check 'recipe: station resolves to the script' ($cfg.stations.'tailor-check' -eq 'tailor-check.ps1' -and (Test-Path -LiteralPath (Join-Path $repo 'kitchen\tailor-check.ps1')))
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "TailorCheck tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
