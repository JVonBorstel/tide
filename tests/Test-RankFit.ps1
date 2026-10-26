# Tests for kitchen/rank-fit.ps1: the deterministic fit scorer, on synthetic postings. No model, no network. Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$rf = Join-Path $kd 'rank-fit.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('rankfit-test-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Fit([string]$t) { (& $rf -Text $t -HomeMetro 'Springfield' -Json | Out-String) | ConvertFrom-Json }   # the home metro is a setting (kitchen.json hunt.homeMetro); a made-up one here
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    # 1. weights
    Check 'empty posting scores 0' ((Fit '').score -eq 0)
    Check 'python alone is 15' ((Fit 'We use Python daily.').score -eq 15)
    Check 'LLM alone is 20' ((Fit 'Build LLM features.').score -eq 20)
    Check 'typescript alone is 15' ((Fit 'TypeScript services').score -eq 15)
    Check 'react native alone is 15' ((Fit 'React Native apps').score -eq 15)
    Check 'c# alone is 10' ((Fit 'Backend in C# and SQL').score -eq 10)
    Check 'aws alone is 10' ((Fit 'Deploy on AWS').score -eq 10)
    Check 'pmp alone is 5' ((Fit 'PMP preferred').score -eq 5)
    $full = Fit "Staff-free role. Python, TypeScript, React Native, C#, AWS, PMP, LLM agents. Remote."
    Check 'full match scores 90' ($full.score -eq 90-and $full.verdict -eq 'fit')

    # 2. false hits
    Check 'React is not React Native' ((Fit 'React and Redux front end').score -eq 0)
    Check 'C is not C#' ((Fit 'Embedded C firmware').score -eq 0)
    Check 'drag and laws are not RAG or LLM' ((Fit 'drag and drop, laws of motion').score -eq 0)
    Check 'travel agent is not an AI agent' ((Fit 'Work with our travel agent partners').score -eq 0)
    Check 'java is not javascript' (@((Fit 'JavaScript only').gaps.skill).Count -eq 0)

    # 3. keyword stuffing counts once
    Check 'repeats count once' ((Fit ('Python ' * 500)).score -eq 15)

    # 4. disqualifiers
    $clr = Fit 'Python role. Active TS/SCI security clearance required. Remote.'
    Check 'clearance costs 50' ($clr.score -eq 0 -and $clr.verdict -eq 'skip' -and @($clr.gaps.disqualifier).Count -eq 1)
    $neg = Fit 'Python role. No security clearance required. Remote.'
    Check 'negated clearance is not a penalty' ($neg.score -eq 15 -and @($neg.gaps.disqualifier).Count -eq 0)
    $neg2 = Fit 'Python role. Security clearance is not required. Remote.'
    Check 'clearance not required is not a penalty' (@($neg2.gaps.disqualifier).Count -eq 0)
    # the scout's own answer shape (it is asked to quote clearance and on-site city for every opening)
    $scoutNone = Fit "LLM Engineer at Beta (remote, US)`n  Must-haves: Python, LLM agents; security clearance: none mentioned; on-site city: none"
    Check "scout 'clearance: none mentioned' is not a penalty" ($scoutNone.score -eq 35 -and @($scoutNone.gaps.disqualifier).Count -eq 0)
    Check "'Security clearance: not listed' is not a penalty" (@((Fit 'Python. Security clearance: not listed. Remote.').gaps.disqualifier).Count -eq 0)
    Check "'clearance: none' is not a penalty" (@((Fit 'Python. Clearance: none. Remote.').gaps.disqualifier).Count -eq 0)
    Check "'on-site city: none mentioned' is not on-site" (@((Fit 'Python. On-site city: none mentioned.').gaps.disqualifier).Count -eq 0)
    Check 'a real clearance still costs 50' (@((Fit 'Python. Clearance: Secret required. Remote.').gaps.disqualifier).Count -eq 1)
    $aus = Fit 'Python, AWS. On-site in Austin, TX.'
    Check 'on-site outside the home metro costs 40' ($aus.score -eq 0 -and $aus.verdict -eq 'skip')
    $den = Fit 'Python, AWS. Hybrid in Springfield.'
    Check 'hybrid in the home metro is fine' ($den.score -eq 25 -and @($den.gaps.disqualifier).Count -eq 0)
    $rem = Fit 'Python, AWS. Hybrid Austin or fully remote in the US.'
    Check 'remote option removes the on-site penalty' ($rem.score -eq 25)
    $nrem = Fit 'Python, AWS. On-site in Austin. This is not a remote role.'
    Check 'not a remote role is on-site' (@($nrem.gaps.disqualifier).Count -eq 1)
    Check 'score never below 0' ((Fit 'Clearance required. On-site in Austin.').score -eq 0)

    # 5. verdicts and gaps
    Check 'maybe band' ((Fit 'Python and TypeScript, remote').verdict -eq 'maybe')
    Check 'low score skips' ((Fit 'Python, remote').verdict -eq 'skip')
    $g = Fit "Senior Java Engineer`n7+ years of Java and Kubernetes. Python. Remote."
    Check 'skill gaps listed' ((@($g.gaps.skill) -contains 'Java') -and (@($g.gaps.skill) -contains 'Kubernetes'))
    Check 'experience gaps listed' ((@($g.gaps.experience) -contains 'senior-level title') -and (@($g.gaps.experience) -match '7\+ years').Count -eq 1)
    Check 'gaps do not change the score' ($g.score -eq 15)
    Check 'senior in the body is not a title' (@((Fit "Engineer`nWork with senior leadership. 2 years experience.").gaps.experience).Count -eq 0)

    # 6. determinism, bad input, size, hostile characters
    $a = (& $rf -Text 'Python, AWS, remote' -Json | Out-String); $b = (& $rf -Text 'Python, AWS, remote' -Json | Out-String)
    Check 'repeatable output' ($a -eq $b)
    Check 'no input is refused' ((& $rf | Out-String) -match 'give -Text' -and $LASTEXITCODE -eq 2)
    Check 'missing file is refused' ((& $rf -Path (Join-Path $root 'nope.txt') | Out-String) -match 'not found' -and $LASTEXITCODE -eq 2)
    $big = 'lorem ipsum dolor sit amet ' * 40000
    $sw = [Diagnostics.Stopwatch]::StartNew(); $bigFit = Fit ($big + ' Python'); $sw.Stop()
    Check '1 MB input is fast' ($sw.Elapsed.TotalSeconds -lt 10 -and $bigFit.score -eq 0)
    $hostile = & $rf -Text "Python`e[31m`u{202E} AWS"
    Check 'control and bidi characters not printed' (-not (($hostile | Out-String) -match '[\x00-\x08\x0B\x0C\x0E-\x1F‪-‮]'))
    Set-Content -LiteralPath (Join-Path $root 'p.txt') 'Python and TypeScript. Remote.'
    Check '-Path reads a file' ((& $rf -Path (Join-Path $root 'p.txt') | Out-String) -match 'score 30 verdict maybe')

    # 7. openings ranking
    $op = Join-Path $root 'x-openings.md'
    Set-Content -LiteralPath $op @'
# Openings
- **Backend Dev** at Acme (on-site, Austin). Posted today.
  Must-haves: Python, AWS. On-site only.
  Link: https://example.com/a
- **LLM Engineer** at Beta (remote). Posted today.
  Must-haves: LLM agents, Python, TypeScript.
  Link: https://example.com/b

# Worth a look today
Python everywhere.
'@
    $env:BRAIN_KITCHEN = $root
    $o = & $rf -Openings $op -OutDir (Join-Path $root 'out') | Out-String
    Check 'openings scored' ($o -match 'rank-fit: scored 2')
    Check 'best fit first' ($o.IndexOf('LLM Engineer') -lt $o.IndexOf('Backend Dev') -and $o -match '1\. \*\*LLM Engineer\*\*: 50')
    Check 'summary section is not an opening' ($o -notmatch 'scored 3')
    Check 'report written outside the brain' (Test-Path (Join-Path $root 'out\x-openings-fit.md'))
    # a numbered list ("1. **Role** at Co") is openings too: J148 found 7 that way and was set aside as "no openings"
    $opN = Join-Path $root 'n-openings.md'
    Set-Content -LiteralPath $opN "# Openings`nI found 2.`n`n1. **Data Engineer** at Gamma (remote). Posted today.`n   Must-haves: Python.`n   Link: https://example.com/c`n`n2. **AI Engineer** at Delta (hybrid). Posted today.`n   Must-haves: LLM agents, TypeScript.`n   Link: https://example.com/d"
    Check 'a numbered list of openings is scored' ((& $rf -Openings $opN -OutDir (Join-Path $root 'out') | Out-String) -match 'rank-fit: scored 2')
    Set-Content -LiteralPath (Join-Path $root 'bad.md') 'The scout answered in prose.'
    Check 'no openings exits 1' ((& $rf -Openings (Join-Path $root 'bad.md') -OutDir (Join-Path $root 'out') | Out-String) -match 'no openings' -and $LASTEXITCODE -eq 1)

    # 8. wiring
    $cfg = Get-Content (Join-Path $kd 'kitchen.json') -Raw | ConvertFrom-Json
    Check 'kitchen.json names the rankfit station' ($cfg.stations.rankfit -eq 'rank-fit.ps1')
    $rec = Get-Content (Join-Path $kd 'recipes\jobscout.json') -Raw | ConvertFrom-Json
    $st = @($rec.steps | Where-Object { $_.station -eq 'rankfit' })
    Check 'jobscout has a rankfit step after the scout' ($st.Count -eq 1 -and $rec.steps[0].station -eq 'agent' -and $rec.steps[-1].station -eq 'rankfit')
    Check 'rankfit step reads the saved openings and must print scored' ($st[0].args.Openings -match '\{\{job\}\}-openings\.md$' -and $st[0].mustMatch -eq 'rank-fit: scored')
} finally {
    $env:BRAIN_KITCHEN = $null
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
Write-Host "RankFit tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
