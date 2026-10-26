# Tests for the apply packet (kitchen/stations/apply-prep.ps1, kitchen/recipes/apply-prep.json, pack-render -LockedFrom): the recipe
# stays private and local, profile.json is made empty once and never overwritten, every question is answered from the profile or sent
# to the cook or to Jordan, a failed tailor check gets no packet, and the packet hash is stable. Temp career folder; self-cleaning.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$station = Join-Path $repo 'kitchen\stations\apply-prep.ps1'
$render = Join-Path $repo 'kitchen\stations\pack-render.ps1'
$recipePath = Join-Path $repo 'kitchen\recipes\apply-prep.json'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-apply-' + [guid]::NewGuid().ToString('N'))
$career = Join-Path $root 'career'
$env:PASS_CAREER_DIR = $career; $env:BRAIN_KITCHEN = Join-Path $root 'kitchen'; $env:KITCHEN_JOB = $null
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$pwshExe = (Get-Process -Id $PID).Path
function Run([string[]]$a) { $o = & $pwshExe -NoProfile -File $station @a | Out-String; @{ out = $o; code = $LASTEXITCODE } }
function Hash([string]$dir) {   # the packet hash as Chef's server computes it
    $sha = [Security.Cryptography.SHA256]::Create()
    foreach ($f in 'answers.json', 'cover.txt', 'link.txt', 'resume.pdf') { $b = [IO.File]::ReadAllBytes((Join-Path $dir $f)); [void]$sha.TransformBlock($b, 0, $b.Length, $null, 0) }
    [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0); ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
}
try {
    New-Item -ItemType Directory -Force -Path "$career\demo\03_resume", $env:BRAIN_KITCHEN | Out-Null

    # 1. the recipe: private, local-only, Tools none, a mustMatch output contract on every step, only Jordan's own files as context
    $rec = Get-Content -LiteralPath $recipePath -Raw | ConvertFrom-Json -AsHashtable
    $agents = @($rec.steps | Where-Object { $_.station -eq 'agent' })
    Check 'recipe is marked private and never public' ($rec.private -eq $true -and -not $rec.public)
    Check 'recipe: appId is required' ($rec.vars.appId.required -eq $true)
    Check 'recipe: every AI step is Private, Supplier local, local model, no tools' ($agents.Count -ge 1 -and @($agents | Where-Object { $_.args.Private -eq $true -and $_.args.Supplier -eq 'local' -and $_.args.Model -match '^qwen' -and $_.args.Tools -eq 'none' -and -not $_.args.Public }).Count -eq $agents.Count)
    Check 'recipe: no step is a cloud research or web step' (-not ($rec.steps | Where-Object { $_.args.Tools -match 'Web' -or $_.args.Role -eq 'research' }))
    Check 'recipe: every step has a mustMatch contract' (@($rec.steps | Where-Object { $_.mustMatch }).Count -eq @($rec.steps).Count)
    Check 'recipe: gather, cook, tailor check, build in that order' (($rec.steps.station -join ',') -eq 'apply-prep,agent,tailor-check,apply-prep' -and $rec.steps[0].args.Phase -eq 'gather' -and $rec.steps[3].args.Phase -eq 'build')
    $ctx = @($agents[0].args.Context -split ';')
    Check 'recipe: the cook reads only the canonical resume, the claims file and the gathered questions' ($ctx.Count -eq 3 -and $ctx[0] -eq '{{resume}}' -and $ctx[1] -eq '{{claims}}' -and $ctx[2] -match 'packets\\\{\{appId\}\}\\ask\.md$')
    Check 'recipe: the cook never sees profile.json' ($agents[0].args.Context -notmatch 'profile' -and $agents[0].args.Prompt -notmatch 'profile\.json')
    Check 'recipe: the taster checks the same draft the cook saved, then build reads it' ($rec.steps[2].args.Draft -eq $agents[0].args.SaveTo -and $rec.steps[2].mustMatch -eq 'TAILOR-CHECK PASS')
    Check 'recipe: nothing in the packet line submits' (-not ((Get-Content $recipePath -Raw) + (Get-Content $station -Raw) -match '(?i)apply-fill|--submit|\.click\('))

    # 2. fixtures: tracker row, canonical resume, claims file, a Greenhouse posting with every kind of question, a fake Edge
    Set-Content "$career\demo\03_resume\PROJECT_TAILORED_RESUME.md" "# Old Tailored Version`n- one interview only" -Encoding utf8
    Set-Content "$career\MASTER_RESUME.md" "# Test Person`n**Engineer** at [GitHub](https://github.com/test)`n`n## Experience`n- Built Python and TypeScript agents <script>x</script>`n- Shipped React Native apps" -Encoding utf8
    Set-Content "$career\demo\03_resume\claims_to_defend.md" "# Claims`n## Never claim`n- `"7+ years`"`n" -Encoding utf8
    @{ items = @(@{ id = 'A1'; company = 'Acme'; role = 'AI Engineer'; link = 'https://boards.greenhouse.io/acme/jobs/123'; status = 'saved' }) } | ConvertTo-Json -Depth 5 | Set-Content "$career\tracker.json" -Encoding utf8
    $q = @(
        @{ label = 'First Name'; name = 'first_name'; required = $true; type = 'input_text' },
        @{ label = 'Email'; name = 'email'; required = $true; type = 'input_text' },
        @{ label = 'Resume/CV'; name = 'resume'; required = $true; type = 'input_file' },
        @{ label = 'Will you now or in the future require visa sponsorship?'; name = 'q1'; required = $true; type = 'multi_value_single_select'; values = @(@{ label = 'Yes' }, @{ label = 'No' }) },
        @{ label = 'What are your salary expectations?'; name = 'q2'; required = $true; type = 'input_text' },
        @{ label = 'Why do you want to work at Acme?'; name = 'q3'; required = $true; type = 'textarea' },
        @{ label = 'Describe your work with LLM agents'; name = 'q4'; required = $false; type = 'textarea' },
        @{ label = 'Gender'; name = 'gender'; required = $false; type = 'multi_value_single_select'; values = @(@{ label = 'Male' }, @{ label = 'Female' }, @{ label = 'Decline To Self Identify' }) },
        @{ label = 'Veteran status'; name = 'veteran'; required = $false; type = 'multi_value_single_select'; values = @(@{ label = 'I am a veteran' }, @{ label = 'I am not a veteran' }) },
        @{ label = 'I certify that the information I provide is true'; name = 'q5'; required = $true; type = 'input_checkbox' },
        @{ label = 'How did you hear about us?'; name = 'q6'; required = $false; type = 'input_text' }
    )
    @{ title = 'AI Engineer'; company_name = 'Acme'; content = '&lt;p&gt;Build agents in Python.&lt;/p&gt;'; questions = $q } | ConvertTo-Json -Depth 6 | Set-Content "$root\ats.json" -Encoding utf8
    $env:PASS_ATS_FIXTURE = "$root\ats.json"
    Set-Content "$root\fake-edge.cmd" "@echo off`r`npwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-edge.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n" -Encoding ascii
    Set-Content "$root\fake-edge.ps1" @"
`$cl = [Environment]::CommandLine
if (`$cl -match '--print-to-pdf[= ]"?([A-Za-z]:\\[^"]+?\.pdf)') { Set-Content -LiteralPath `$Matches[1] -Value "%PDF-1.4 locked" -Encoding utf8 }
exit 0
"@ -Encoding utf8
    $env:KITCHEN_EDGE_EXE = "$root\fake-edge.cmd"
    Set-Content "$root\no-edge.cmd" "@echo off`r`nexit /b 3`r`n" -Encoding ascii   # an Edge that fails to print

    # 3. gather: profile template made empty, locked resume rendered once, every question sorted
    $r = Run @('-Phase', 'gather', '-AppId', 'A1')
    Check 'gather: done' ($r.code -eq 0 -and $r.out -match 'APPLY-PREP GATHERED 11 question')
    $profRaw = Get-Content "$career\profile.json" -Raw
    $prof = $profRaw | ConvertFrom-Json -AsHashtable
    $blank = @('name', 'email', 'phone', 'city', 'state', 'country', 'linkedin', 'github', 'website', 'workAuthorization', 'needsSponsorship', 'salaryExpectation', 'earliestStart', 'willingToRelocate', 'remotePreference', 'yearsExperience')
    Check 'profile template: every personal field present and empty' (@($blank | Where-Object { $prof.ContainsKey($_) -and $prof[$_] -eq '' }).Count -eq $blank.Count)
    Check 'profile template: only the standing defaults are set (how did you hear, EEO decline)' ($prof.howDidYouHear -eq 'Company website' -and @('gender', 'race', 'veteran', 'disability' | Where-Object { $prof.eeo[$_] -eq 'Decline to self-identify' }).Count -eq 4 -and $prof.Count -eq ($blank.Count + 2))
    Check 'profile is never printed' ($r.out -notmatch 'Company website|Decline to self')
    Check 'locked resume rendered from the canonical markdown, escaped' ((Test-Path "$career\resume-locked.pdf") -and (Get-Content "$career\resume-locked.html" -Raw) -match '<h1>Test Person</h1>' -and (Get-Content "$career\resume-locked.html" -Raw) -notmatch '<script>x' -and -not (Test-Path "$career\resume-locked-draft.md"))
    Check 'the locked resume comes from the resume setting (MASTER_RESUME.md), not the old tailored one' ((Get-Content "$career\resume-locked.html" -Raw) -notmatch 'Old Tailored' -and $r.out -match 'from MASTER_RESUME\.md')
    $lm = Get-Content "$career\resume-locked.json" -Raw | ConvertFrom-Json
    Check 'resume-locked.json records the source hash next to the PDF' ($lm.sourceSha256 -eq (Get-FileHash "$career\MASTER_RESUME.md").Hash.ToLowerInvariant() -and $lm.pdfSha256 -eq (Get-FileHash "$career\resume-locked.pdf").Hash.ToLowerInvariant())
    Set-Content "$career\resume-locked.pdf" '%PDF-1.4 kept' -Encoding utf8
    $again = & $pwshExe -NoProfile -File $render -Locked | Out-String
    Check 'unchanged source: the locked resume is not re-rendered' ($again -match 'up to date' -and (Get-Content "$career\resume-locked.pdf" -Raw) -match 'kept')
    Add-Content "$career\MASTER_RESUME.md" "`n## New Section" -Encoding utf8
    $again = & $pwshExe -NoProfile -File $render -Locked | Out-String
    Check 'edited source: the locked resume is re-rendered and the new hash recorded' ($again -match 'locked resume rendered' -and (Get-Content "$career\resume-locked.pdf" -Raw) -match 'locked' -and (Get-Content "$career\resume-locked.html" -Raw) -match 'New Section' -and (Get-Content "$career\resume-locked.json" -Raw | ConvertFrom-Json).sourceSha256 -eq (Get-FileHash "$career\MASTER_RESUME.md").Hash.ToLowerInvariant() -and -not (Test-Path "$career\resume-locked.next.pdf"))
    $env:KITCHEN_EDGE_EXE = "$root\no-edge.cmd"; Add-Content "$career\MASTER_RESUME.md" "`n## Another" -Encoding utf8
    $r2 = Run @('-Phase', 'gather', '-AppId', 'A1')
    Check 'a changed resume that cannot be rendered: gather refuses, the old PDF stays' ($r2.code -eq 1 -and $r2.out -match 'could not be rendered' -and (Get-Content "$career\resume-locked.pdf" -Raw) -match 'locked')
    $env:KITCHEN_EDGE_EXE = "$root\fake-edge.cmd"
    $r2 = Run @('-Phase', 'gather', '-AppId', 'A1')
    Check 'gather re-renders the edited resume' ($r2.code -eq 0 -and (Get-Content "$career\resume-locked.html" -Raw) -match 'Another')
    Set-Content "$career\resume-locked.pdf" '%PDF-1.4 kept' -Encoding utf8
    Check 'a resume outside the career folder is refused' ((Run @('-Phase', 'gather', '-AppId', 'A1', '-Resume', "$root\elsewhere.md")).code -eq 2)
    $g = Get-Content "$career\packets\A1\gather.json" -Raw | ConvertFrom-Json
    $by = @{}; foreach ($a in $g.answers) { $by[$a.name] = $a }
    Check 'empty profile + required field: needsJordan (first name, email, sponsorship, salary)' (@('first_name', 'email', 'q1', 'q2' | Where-Object { $by[$_].needsJordan -and $by[$_].source -eq 'jordan' -and -not $by[$_].answer }).Count -eq 4)
    Check 'resume file question gets the locked resume' ($by.resume.answer -eq 'resume.pdf' -and -not $by.resume.needsJordan)
    Check 'EEO answered only from the profile, matched to the option wording' ($by.gender.answer -eq 'Decline To Self Identify' -and -not $by.gender.needsJordan)
    Check 'EEO with no matching option: blank, voluntary, not flagged' (-not $by.veteran.answer -and -not $by.veteran.needsJordan -and $by.veteran.note -eq 'voluntary, left blank')
    Check 'legal sign-off always goes to Jordan' ($by.q5.needsJordan -and $by.q5.source -eq 'jordan')
    Check 'how did you hear: the standing default' ($by.q6.answer -eq 'Company website')
    Check 'open questions go to the cook, numbered' ($by.q3.ask -eq 1 -and $by.q4.ask -eq 2 -and (Get-Content "$career\packets\A1\ask.md" -Raw) -match 'Q1\. Why do you want to work at Acme\? \(required\)' -and (Get-Content "$career\packets\A1\ask.md" -Raw) -notmatch 'salary|sponsor|Gender')

    # 4. build: refused without a passing check; then a full packet with a stable hash
    $draft = "# Cover lines`nI build Python agents. I shipped React Native apps. A third line is dropped.`n# Answers`n**Q1:** I like what Acme builds with agents.`nQ2: NEEDS JORDAN`n"
    Set-Content "$career\packets\A1\draft.md" ($draft + "`n# Tailor check`n- Result: FAIL`n") -Encoding utf8
    $r = Run @('-Phase', 'build', '-AppId', 'A1')
    Check 'failed tailor check: no packet' ($r.code -eq 1 -and $r.out -match 'did not pass' -and -not (Test-Path "$career\packets\A1\packet.json"))
    Set-Content "$career\packets\A1\draft.md" $draft -Encoding utf8
    Check 'unchecked draft: no packet' ((Run @('-Phase', 'build', '-AppId', 'A1')).code -eq 1 -and -not (Test-Path "$career\packets\A1\packet.json"))
    New-Item -ItemType Directory -Force "$career\tailored" | Out-Null
    Set-Content "$career\tailored\J7-draft.md" "# Summary`nx`n# Tailor check`n- Result: FAIL" -Encoding utf8
    $t = Get-Content "$career\tracker.json" -Raw | ConvertFrom-Json -AsHashtable; $t.items[0].drafts = @('J7'); $t | ConvertTo-Json -Depth 6 | Set-Content "$career\tracker.json" -Encoding utf8
    Set-Content "$career\packets\A1\draft.md" ($draft + "`n# Tailor check`n- Result: PASS`n") -Encoding utf8
    $r = Run @('-Phase', 'build', '-AppId', 'A1')
    Check "a role whose tailor draft failed its check gets no packet" ($r.code -eq 1 -and $r.out -match 'tailored draft failed' -and -not (Test-Path "$career\packets\A1\packet.json"))
    Set-Content "$career\tailored\J7-draft.md" "# Summary`nx`n# Tailor check`n- Result: PASS" -Encoding utf8
    $r = Run @('-Phase', 'build', '-AppId', 'A1')
    Check 'build: packet ready' ($r.code -eq 0 -and $r.out -match 'APPLY-PACKET READY A1 \(11 answer')
    $pd = "$career\packets\A1"
    Check 'packet files: resume.pdf (the locked copy), cover.txt, answers.json, link.txt, packet.json' (@('resume.pdf', 'cover.txt', 'answers.json', 'link.txt', 'packet.json' | Where-Object { Test-Path "$pd\$_" }).Count -eq 5 -and (Get-Content "$pd\resume.pdf" -Raw) -match 'kept' -and (Get-Content "$pd\link.txt" -Raw) -eq 'https://boards.greenhouse.io/acme/jobs/123')
    $cover = Get-Content "$pd\cover.txt" -Raw
    Check 'cover note: fixed template, company and role, at most two cook lines' ($cover -match '^Hello Acme team,' -and $cover -match 'AI Engineer role\. I build Python agents\. I shipped React Native apps\.' -and $cover -notmatch 'third line' -and $cover -match 'Thank you,\s+Jordan')
    $ans = @(Get-Content "$pd\answers.json" -Raw | ConvertFrom-Json)
    $ab = @{}; foreach ($a in $ans) { $ab[$a.name] = $a }
    Check 'answers.json: every answer has question, type, required, answer, source, needsJordan' (@($ans | Where-Object { $null -ne $_.question -and $null -ne $_.type -and $null -ne $_.required -and $null -ne $_.answer -and $_.source -in 'resume', 'profile', 'jordan' -and $null -ne $_.needsJordan }).Count -eq 11)
    Check "the cook's answer lands (bold stripped), NEEDS JORDAN becomes Jordan's" ($ab.q3.answer -eq 'I like what Acme builds with agents.' -and $ab.q3.source -eq 'resume' -and $ab.q4.needsJordan -and -not $ab.q4.answer -and -not ($ans | Where-Object { $_.PSObject.Properties.Name -contains 'ask' }))
    $pk = Get-Content "$pd\packet.json" -Raw | ConvertFrom-Json
    Check 'packet.json: profile hash and resume source hash recorded' ($pk.profileHash -eq (Get-FileHash "$career\profile.json").Hash.ToLowerInvariant() -and $pk.resumeSourceSha256 -eq (Get-FileHash "$career\MASTER_RESUME.md").Hash.ToLowerInvariant())
    Check 'packet.json: hash matches the files, resume hash recorded' ($pk.hash -eq (Hash $pd) -and $pk.resumeSha256 -eq (Get-FileHash "$career\resume-locked.pdf").Hash.ToLowerInvariant() -and $pk.needsJordan -eq 6)
    $row = (Get-Content "$career\tracker.json" -Raw | ConvertFrom-Json).items[0]
    Check 'tracker row marked with the packet' ($row.packet.ready -and $row.packet.hash -eq $pk.hash -and $row.status -eq 'saved')
    Check 'the draft is moved aside after a build' (-not (Test-Path "$pd\draft.md") -and (Test-Path "$pd\draft.built.md"))

    # 5. profile.json is never overwritten; once Jordan fills it, those questions are answered (booleans read Yes/No)
    $mine = '{ "name": "Test Person", "email": "t@example.com", "needsSponsorship": false, "salaryExpectation": "", "eeo": { "veteran": "I am not a veteran" } }'
    Set-Content "$career\profile.json" $mine -Encoding utf8
    $r = Run @('-Phase', 'gather', '-AppId', 'A1')
    Check 'gather never overwrites a filled profile.json' ((Get-Content "$career\profile.json" -Raw).Trim() -eq $mine -and $r.out -notmatch 'made an empty profile')
    $g = Get-Content "$career\packets\A1\gather.json" -Raw | ConvertFrom-Json; $by = @{}; foreach ($a in $g.answers) { $by[$a.name] = $a }
    Check 'filled profile answers its questions' ($by.first_name.answer -eq 'Test' -and $by.email.answer -eq 't@example.com' -and $by.q1.answer -eq 'No' -and $by.veteran.answer -eq 'I am not a veteran' -and -not $by.q1.needsJordan)
    Check 'a still-empty required profile field stays with Jordan' ($by.q2.needsJordan -and $by.q2.note -match 'salaryExpectation')
    Check 'gather clears the last draft so a silent cook cannot reuse it' (-not (Test-Path "$career\packets\A1\draft.md"))
    Remove-Item "$career\profile.json"
    Set-Content "$career\profile.json" 'not json' -Encoding utf8
    $r = Run @('-Phase', 'gather', '-AppId', 'A1')
    Check 'an unreadable profile is left alone and answers nothing' ($r.code -eq 0 -and (Get-Content "$career\profile.json" -Raw).Trim() -eq 'not json' -and $r.out -match 'not valid JSON')
    # 6. cook.ps1 fills {{resume}} / {{claims}} from kitchen.json "career" into every step, script stations included; the state-folder copy wins
    $cook = Join-Path $repo 'kitchen\cook.ps1'
    function Cooked([string]$id) { (Get-Content (Join-Path $env:BRAIN_KITCHEN "jobs\$id.json") -Raw | ConvertFrom-Json -AsHashtable).steps }
    $o = & $cook -Recipe apply-prep -Vars @{ appId = 'A1'; company = 'Acme' } | Out-String
    $st = Cooked 'J1'; $all = $st | ConvertTo-Json -Depth 10
    Check 'cook: no {{token}} left in any step (gather, agent, taster, build)' ($o -match 'cooking J1' -and $all -notmatch '\{\{(?!job\}\}|worktree\}\})')
    Check 'cook: every step reads the resume setting' ($st[0].args.Resume -eq "$career\MASTER_RESUME.md" -and $st[1].args.Context -like "$career\MASTER_RESUME.md;$career\demo\03_resume\claims_to_defend.md;*" -and $st[2].args.Resume -eq "$career\MASTER_RESUME.md" -and $st[2].args.Claims -eq "$career\demo\03_resume\claims_to_defend.md")
    $kj = Join-Path $env:BRAIN_KITCHEN 'kitchen.json'
    Set-Content $kj '{ "career": { "resume": "cv\\Mine.md" } }' -Encoding utf8
    $null = & $cook -Recipe tailor -Vars @{ posting = 'a job' }
    $st = Cooked 'J2'
    Check 'cook: the state-folder kitchen.json resume setting wins (tailor recipe too)' ($st[0].args.Context -like "$career\cv\Mine.md;*" -and $st[1].args.Resume -eq "$career\cv\Mine.md")
    Set-Content $kj '{ "career": { "resume": "..\\..\\secret.md", "claims": "C:\\x.md" } }' -Encoding utf8
    $null = & $cook -Recipe pack -Vars @{ appId = 'A1' }
    $st = Cooked 'J3'
    Check 'cook: a resume setting outside the career folder is ignored' ($st[0].args.Context -eq "$career\MASTER_RESUME.md;$career\demo\03_resume\claims_to_defend.md" -and $st[1].args.Resume -eq "$career\MASTER_RESUME.md")
    Check 'cook: an order cannot set the resume' ((& $cook -Recipe tailor -Vars @{ posting = 'x'; resume = 'C:\evil.md' } | Out-String) -match "has no 'resume'")
    Remove-Item -LiteralPath $kj
    Check 'bad AppId refused' ((Run @('-Phase', 'gather', '-AppId', 'A1;x')).code -eq 2)
    Check 'unknown role refused' ((Run @('-Phase', 'gather', '-AppId', 'A99')).code -eq 2)
} catch {
    $script:fail++; Write-Host "FAIL: unexpected exception in test: $_ $($_.ScriptStackTrace)"
} finally {
    foreach ($v in 'PASS_CAREER_DIR', 'PASS_ATS_FIXTURE', 'KITCHEN_EDGE_EXE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}
Write-Host "Apply packet tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
