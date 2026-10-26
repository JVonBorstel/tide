# Tests for kitchen/apply-fill.mjs (job application auto-fill). Serves three LOCAL fixture forms (Greenhouse-, Lever- and Ashby-like) from a
# tiny node server on 127.0.0.1, runs apply-fill against them with a temp career folder and a temp BRAIN_KITCHEN, the browser headless
# (APPLY_FILL_HEADLESS=1, tests only), and checks the fill, the never-sends guard (static and live), the --submit gates and the one-send
# marker. Never touches a real job site, Jordan's career files or the live kitchen. SKIPs (passes) when neither Chrome nor Edge exists.
#   pwsh -NoProfile -File scripts/run-bounded.ps1 -Script tests/Test-ApplyFill.ps1 -TimeoutSeconds 400
# Chrome can't start at Low integrity (the kitchen sandbox for AI-written tests): this suite runs at Medium via kitchen.json
# sandboxMedium; if it ever finds itself at Low (a job edited apply-fill), it skips with a clear SKIP rather than failing every order
if ((& "$env:SystemRoot\System32\whoami.exe" /groups 2>$null | Out-String) -match 'Low Mandatory Level') { Write-Host 'SKIP: apply-fill needs Chrome, which cannot run at Low integrity'; Write-Host 'apply-fill tests: 0 passed, 0 failed'; exit 0 }
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script = Join-Path $repo 'kitchen\apply-fill.mjs'
$fx = Join-Path $repo 'tests\fixtures\apply-fill'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }

# ---- 1. static guard: fill mode can't press, send or type anything; the one send function sits behind --submit and every gate ----
$src = Get-Content -LiteralPath $script -Raw -Encoding utf8
$i0 = $src.IndexOf('// >>> SEND-ONLY REGION'); $i1 = $src.IndexOf('// <<< SEND-ONLY REGION')
Check 'source: one SEND-ONLY region, opened and closed once' ($i0 -gt 0 -and $i1 -gt $i0 -and $src.LastIndexOf('// >>> SEND-ONLY REGION') -eq $i0 -and $src.LastIndexOf('// <<< SEND-ONLY REGION') -eq $i1)
$outside = $src.Substring(0, $i0) + $src.Substring($i1); $region = $src.Substring($i0, $i1 - $i0)
Check 'source: no press/send/key code outside the SEND-ONLY region' ($outside -notmatch 'requestSubmit|\.submit\s*\(|\.click\s*\(|dispatchMouseEvent|dispatchKeyEvent|insertText|MouseEvent|PointerEvent|KeyboardEvent|mousePressed|type=submit')
Check 'source: no key events or Enter anywhere (not even in the region)' ($src -notmatch 'dispatchKeyEvent|KeyboardEvent|keydown|keypress|keyup|insertText|[''"`]Enter[''"`]|\\r''|\.submit\s*\(|requestSubmit|\.click\s*\(')
Check 'source: the region holds submitApplicationOnce, which writes the marker exclusively before pressing' ($region -match 'async function submitApplicationOnce' -and $region.IndexOf("openSync(marker, 'wx')") -gt 0 -and $region.IndexOf("openSync(marker, 'wx')") -lt $region.IndexOf('Input.dispatchMouseEvent'))
$calls = [regex]::Matches($outside, 'submitApplicationOnce\(')
Check 'source: submitApplicationOnce is called exactly once, outside the region' ($calls.Count -eq 1 -and ([regex]::Matches($region, 'submitApplicationOnce\(')).Count -eq 1)
$gate = $outside.LastIndexOf('if (opts.submit) {', $calls[0].Index)
$between = if ($gate -ge 0) { $outside.Substring($gate, $calls[0].Index - $gate) } else { '' }
Check 'source: the call sits behind --submit and the hash, captcha and required gates' ($between -match 'opts\.hash !== packetHash' -and $between -match 'fin\.captcha' -and $between -match 'missing\.length' -and $between -match 'if \(why\) result = ''needs-you'';\s*else')
Check 'source: an already-sent marker stops the run before any browser opens' ($outside.IndexOf('fs.existsSync(marker)') -gt 0 -and $outside.IndexOf('fs.existsSync(marker)') -lt $outside.IndexOf('await openBrowser('))
Check 'source: captchas are only detected, never driven' ($src -notmatch 'grecaptcha|hcaptcha\.|turnstile\.|recaptcha-response|g-recaptcha-response')
Check 'source: no network of its own (no fetch/http client); DevTools socket is 127.0.0.1' ($src -notmatch '\bfetch\s*\(|node:https?[''"]|XMLHttpRequest' -and $src -match 'ws://127\.0\.0\.1:' -and $src -match '--remote-debugging-port=0')
Check 'source: dedicated profile per browser under the kitchen, never a default profile' ($src -match 'apply-\$\{b\.name\}-profile' -and $src -match '--user-data-dir=')
Check 'source: zero dependencies (node: builtins only)' (-not ([regex]::Matches($src, "from '([^']+)'") | Where-Object { $_.Groups[1].Value -notmatch '^node:' }))

# ---- 2. browser present? (Chrome first, Edge fallback, same as the script) ----
$pf86 = ${env:ProgramFiles(x86)}; if (-not $pf86) { $pf86 = 'C:\Program Files (x86)' }
$cands = @($env:CHROME_EXE, "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "$pf86\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe", $env:MSEDGE_EXE, "$pf86\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { $_ }
$browserExe = $cands | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $browserExe) {
    Write-Host 'SKIP: neither Chrome nor Edge is installed; live apply-fill tests skipped'
    Write-Host "apply-fill tests: $($script:pass) passed, $($script:fail) failed (live part skipped)"
    exit ([int]($script:fail -gt 0))
}
$bname = if ($browserExe -match 'chrome\.exe$') { 'chrome' } else { 'edge' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('apply-fill-test-' + [guid]::NewGuid().ToString('N'))
$career = Join-Path $root 'career'; $kitchen = Join-Path $root 'kitchen'; $out = Join-Path $root 'out'
$saved = @{ PASS_CAREER_DIR = $env:PASS_CAREER_DIR; BRAIN_KITCHEN = $env:BRAIN_KITCHEN; APPLY_FILL_HEADLESS = $env:APPLY_FILL_HEADLESS }
$server = $null
try {
    New-Item -ItemType Directory -Force -Path $career, $kitchen, $out | Out-Null
    $env:PASS_CAREER_DIR = $career; $env:BRAIN_KITCHEN = $kitchen; $env:APPLY_FILL_HEADLESS = '1'

    $server = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $fx 'server.mjs'), "`"$out`"") -PassThru -WindowStyle Hidden
    $until = (Get-Date).AddSeconds(15)
    while (-not (Test-Path -LiteralPath "$out\port") -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 100 }
    $port = (Get-Content -LiteralPath "$out\port" -Raw).Trim()
    $base = "http://127.0.0.1:$port"

    # fixture profile, tracker, packets and the locked resume (all fake values)
    $email = 'test.person@example.com'; $phone = '555-0100'; $li = 'https://www.linkedin.example/in/test-person'; $gh = 'https://github.example/test-person'; $web = 'https://test-person.example'
    [ordered]@{ name = 'Test Person'; email = $email; phone = $phone; city = 'Springfield'; state = 'IL'; country = 'United States'; linkedin = $li; github = $gh; website = $web
        workAuthorization = $true; needsSponsorship = $false; salaryExpectation = '100k'; earliestStart = '2 weeks'; willingToRelocate = $false; eeo = @{ gender = 'Decline to self-identify' } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$career\profile.json" -Encoding utf8
    $items = @(
        @{ id = 'A1'; company = 'Acme'; role = 'AI Engineer'; link = "$base/greenhouse/acme/jobs/123" },
        @{ id = 'A2'; company = 'Acme'; role = 'Agent Engineer'; link = "$base/lever/acme/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b/apply" },
        @{ id = 'A3'; company = 'Acme'; role = 'Agent Builder'; link = "$base/ashby/acme/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5c/application" },
        @{ id = 'A4'; company = 'Nopacket'; role = 'Dev'; link = "$base/greenhouse/nopacket/jobs/9" },
        @{ id = 'A5'; company = 'Elsewhere'; role = 'Dev'; link = "$base/other/careers/1" })
    @{ updated = (Get-Date).ToString('o'); items = $items } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$career\tracker.json" -Encoding utf8
    $answers = @(
        [ordered]@{ question = 'Why do you want to work at Acme?'; type = 'textarea'; required = $true; answer = 'Because Acme ships agents people use.'; source = 'draft'; needsJordan = $false },
        [ordered]@{ question = 'What are your salary expectations?'; type = 'text'; required = $false; answer = ''; source = ''; needsJordan = $true },
        [ordered]@{ question = 'How many years of professional TypeScript experience do you have?'; type = 'text'; required = $true; answer = '6 years'; source = 'resume'; needsJordan = $false },
        [ordered]@{ question = 'Describe a time you disagreed with a teammate and how it was resolved.'; type = 'textarea'; required = $false; answer = ''; source = ''; needsJordan = $true },
        [ordered]@{ question = 'What excites you about building AI agents?'; type = 'textarea'; required = $true; answer = 'Shipping tools that do real work.'; source = 'draft'; needsJordan = $false },
        [ordered]@{ question = 'Tell us about a project you are proud of.'; type = 'textarea'; required = $true; answer = ''; source = ''; needsJordan = $true })
    $cover = "Dear Acme team,`nI build agents that ship.`nThanks for reading."
    foreach ($id in 'A1', 'A2', 'A3', 'A5') {
        New-Item -ItemType Directory -Force -Path "$career\packets\$id" | Out-Null
        [IO.File]::WriteAllText("$career\packets\$id\answers.json", (ConvertTo-Json -InputObject $answers -Depth 5))
        [IO.File]::WriteAllText("$career\packets\$id\cover.txt", $cover)
    }
    [IO.File]::WriteAllBytes("$career\resume-locked.pdf", [Text.Encoding]::ASCII.GetBytes("%PDF-1.4`n% apply-fill fixture resume`n%%EOF`n"))
    $resumeSize = (Get-Item -LiteralPath "$career\resume-locked.pdf").Length
    function Get-PacketHash($id) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]([IO.File]::ReadAllBytes("$career\packets\$id\answers.json") + [IO.File]::ReadAllBytes("$career\resume-locked.pdf")))).ToLowerInvariant() }

    $script:allOut = ''
    function Fill([string]$id, [string[]]$extra = @()) {
        $o = (& node $script --item $id @extra 2>&1 | Out-String); $code = $LASTEXITCODE
        $script:allOut += $o
        [pscustomobject]@{ code = $code; out = $o.Trim() }
    }
    function Report($id) { Get-Content -LiteralPath "$career\packets\$id\fill-report.json" -Raw | ConvertFrom-Json -AsHashtable }
    function State($site) { Start-Sleep -Milliseconds 800; if (Test-Path -LiteralPath "$out\state-$site.json") { Get-Content -LiteralPath "$out\state-$site.json" -Raw | ConvertFrom-Json -AsHashtable } else { @{} } }
    function Why($rep, $label) { (@($rep.left) | Where-Object { $_.label -eq $label } | Select-Object -First 1).why }

    # ---- 3. fill mode on the three fixtures ----
    $r = Fill 'A1'
    Check "greenhouse: exit 0 with a one-line summary ($($r.out))" ($r.code -eq 0 -and $r.out -match '^apply-fill: A1 greenhouse \(' -and ($r.out -split "`n").Count -eq 1)
    $s = State 'greenhouse'
    Check 'greenhouse: names, email, phone, location filled' ($s.first_name -eq 'Test' -and $s.last_name -eq 'Person' -and $s.email -eq $email -and $s.phone -eq $phone -and $s.job_application_location -eq 'Springfield, IL')
    Check 'greenhouse: locked resume attached to the hidden file input' ((@($s.resume) -join ',') -eq "resume-locked.pdf:$resumeSize")
    Check 'greenhouse: cover note pasted, LinkedIn and website filled' ($s.cover_letter_text -eq $cover -and $s.q1 -eq $li -and $s.q2 -eq $web)
    Check 'greenhouse: custom question answered from answers.json' ($s.q3 -eq 'Because Acme ships agents people use.')
    Check 'greenhouse: needs-Jordan question left empty (beats the profile salary)' ($s.q4 -eq '')
    Check 'greenhouse: authorization Yes, sponsorship No, EEO gender picked' ($s.q5 -eq '1' -and $s.q6 -eq '0' -and $s.gender -eq '3')
    Check 'greenhouse: unknown question left empty' ($s.q7 -eq '')
    $rep = Report 'A1'
    Check 'greenhouse report: site, url, captcha, fill mode' ($rep.site -eq 'greenhouse' -and $rep.url -eq "$base/greenhouse/acme/jobs/123" -and $rep.captcha -eq $true -and $rep.mode -eq 'fill' -and $rep.result -eq 'filled' -and $rep.at)
    Check 'greenhouse report: filled labels' ((@($rep.filled) -contains 'First Name') -and (@($rep.filled) -contains 'Resume/CV') -and (@($rep.filled) -contains 'Why do you want to work at Acme?') -and (@($rep.filled) -contains 'Gender'))
    Check 'greenhouse report: left labels with why' ((Why $rep 'What are your salary expectations?') -eq 'needs Jordan' -and (Why $rep 'How did you hear about this job?') -eq 'not sure')
    Check 'greenhouse: summary reports the captcha for Jordan' ($r.out -match 'captcha: Jordan solves it')

    $r = Fill 'A2'
    Check "lever: exit 0 ($($r.out))" ($r.code -eq 0 -and $r.out -match '^apply-fill: A2 lever')
    $s = State 'lever'
    Check 'lever: full name, email, phone, location' ($s.name -eq 'Test Person' -and $s.email -eq $email -and $s.phone -eq $phone -and $s.location -eq 'Springfield, IL')
    Check 'lever: links (LinkedIn, GitHub, Portfolio) filled, Twitter and company left' ($s['urls[LinkedIn]'] -eq $li -and $s['urls[GitHub]'] -eq $gh -and $s['urls[Portfolio]'] -eq $web -and $s['urls[Twitter]'] -eq '' -and $s.org -eq '')
    Check 'lever: unlabeled custom card answered, relocate radio set to No' ($s['cards[c1][field0]'] -eq '6 years' -and $s['cards[c1][field1]=No'] -eq $true -and -not $s.ContainsKey('cards[c1][field1]=Yes'))
    Check 'lever: needs-Jordan card empty, consent checkbox untouched' ($s['cards[c1][field2]'] -eq '' -and -not $s.ContainsKey('consent[marketing]=1'))
    Check 'lever: cover note into "Additional information" (placeholder says cover letter)' ($s.comments -eq $cover)
    Check 'lever: resume attached' ((@($s['resume-upload-input']) -join ',') -eq "resume-locked.pdf:$resumeSize")
    $rep = Report 'A2'
    Check 'lever report: no captcha; checkbox and needs-Jordan left with why' ($rep.captcha -eq $false -and (Why $rep 'Describe a time you disagreed with a teammate and how it was resolved.') -eq 'needs Jordan' -and (Why $rep 'Send me future job updates') -match 'checkbox')

    $r = Fill 'A3'
    Check "ashby (late, React-style controlled form): exit 0 ($($r.out))" ($r.code -eq 0 -and $r.out -match '^apply-fill: A3 ashby')
    $s = State 'ashby'
    Check 'ashby: React-style state registered name, email, phone, links' ($s._systemfield_name -eq 'Test Person' -and $s._systemfield_email -eq $email -and $s.phone -eq $phone -and $s.linkedin -eq $li -and $s.gh -eq $gh)
    Check 'ashby: resume attached, custom answer and cover in state' ((@($s.resume) -join ',') -eq "resume-locked.pdf:$resumeSize" -and $s.q_excite -eq 'Shipping tools that do real work.' -and $s.cover -eq $cover)
    Check 'ashby: needs-Jordan and autocomplete location left empty' (-not $s.q_proud -and -not $s.loc)
    $rep = Report 'A3'
    Check 'ashby report: why for the combobox and the needs-Jordan question' ((Why $rep 'Location') -match 'autocomplete' -and (Why $rep 'Tell us about a project you are proud of.') -eq 'needs Jordan' -and $rep.captcha -eq $false)

    Check 'fill mode never sent anything: no press marker, no POST /apply' (-not (Test-Path "$out\MARKER.log") -and -not (Test-Path "$out\APPLIED.log") -and -not ((Get-Content "$out\requests.log") -match '/apply/|/marker/'))
    Check 'fill mode wrote no submitted marker' (-not (Get-ChildItem -LiteralPath "$career\packets" -Recurse -Filter 'submitted.json'))

    $profDir = Join-Path $kitchen "apply-$bname-profile"
    Check "dedicated $bname profile under the (temp) kitchen" (Test-Path -LiteralPath "$profDir\DevToolsActivePort")
    $dport = [int]((Get-Content -LiteralPath "$profDir\DevToolsActivePort")[0])
    $lis = @(Get-NetTCPConnection -LocalPort $dport -State Listen -ErrorAction SilentlyContinue)
    Check "DevTools endpoint listens on 127.0.0.1 only ($(@($lis.LocalAddress) -join ','))" ($lis.Count -ge 1 -and -not ($lis | Where-Object { $_.LocalAddress -ne '127.0.0.1' }))

    # ---- 4. bad inputs ----
    $r = Fill 'A4'
    Check "missing packet -> exit 2 with a clear message ($($r.out))" ($r.code -eq 2 -and $r.out -match 'no apply packet' -and -not (Test-Path "$career\packets\A4\fill-report.json"))
    $r = Fill 'A9'
    Check 'unknown item -> exit 2' ($r.code -eq 2)
    $r = Fill '..\x'
    Check 'path-like item id -> exit 2' ($r.code -eq 2)
    Move-Item "$career\resume-locked.pdf" "$career\resume-locked.bak"
    $r = Fill 'A1'
    Check 'missing locked resume -> exit 2' ($r.code -eq 2 -and $r.out -match 'locked resume')
    Move-Item "$career\resume-locked.bak" "$career\resume-locked.pdf"
    $r = Fill 'A5'
    $rep = Report 'A5'
    Check "unsupported site: page opened, packet only, exit 0 ($($r.out))" ($r.code -eq 0 -and $rep.site -eq 'other' -and $rep.why -eq 'unsupported site, packet only' -and @($rep.filled).Count -eq 0)

    # ---- 5. --submit gates and the one send ----
    $r = Fill 'A2' @('--print-hash')
    Check 'print-hash = sha256(answers.json + resume-locked.pdf)' ($r.code -eq 0 -and $r.out -eq (Get-PacketHash 'A2'))
    # a full packet from apply-prep.ps1 (answers, cover, link, its own resume.pdf): the hash Chef shows and checks is the one we send under
    $pd = Join-Path $career 'packets\A2'; Set-Content (Join-Path $pd 'cover.txt') 'cover' -NoNewline; Set-Content (Join-Path $pd 'link.txt') 'https://x' -NoNewline
    Copy-Item (Join-Path $career 'resume-locked.pdf') (Join-Path $pd 'resume.pdf')
    $sha = [Security.Cryptography.SHA256]::Create(); foreach ($f in 'answers.json', 'cover.txt', 'link.txt', 'resume.pdf') { $b = [IO.File]::ReadAllBytes((Join-Path $pd $f)); [void]$sha.TransformBlock($b, 0, $b.Length, $null, 0) }
    [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0); $prepHash = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    $r = Fill 'A2' @('--print-hash')
    Check 'full packet: print-hash matches apply-prep.ps1 and Chef (answers, cover, link, resume.pdf)' ($r.code -eq 0 -and $r.out -eq $prepHash)
    foreach ($f in 'cover.txt', 'link.txt', 'resume.pdf') { Remove-Item (Join-Path $pd $f) }
    $r = Fill 'A2' @('--submit', '--packet-hash', ('0' * 64))
    $rep = Report 'A2'
    Check "submit, wrong hash -> needs-you, nothing sent ($($r.out))" ($r.code -eq 0 -and $rep.result -eq 'needs-you' -and $rep.why -match 'hash mismatch' -and -not (Test-Path "$out\APPLIED.log") -and -not (Test-Path "$career\packets\A2\submitted.json"))
    $r = Fill 'A1' @('--submit', '--packet-hash', (Get-PacketHash 'A1'))
    $rep = Report 'A1'
    Check "submit, captcha page -> needs-you, nothing sent ($($r.out))" ($rep.result -eq 'needs-you' -and $rep.why -match 'captcha' -and -not (Test-Path "$out\APPLIED.log") -and -not (Test-Path "$career\packets\A1\submitted.json"))
    $r = Fill 'A3' @('--submit', '--packet-hash', (Get-PacketHash 'A3'))
    $rep = Report 'A3'
    Check "submit, required field empty -> needs-you naming it, nothing sent ($($r.out))" ($rep.result -eq 'needs-you' -and $rep.why -match 'required field empty: .*proud' -and -not (Test-Path "$out\APPLIED.log") -and -not (Test-Path "$career\packets\A3\submitted.json"))
    Check 'no press marker after the refused sends' (-not (Test-Path "$out\MARKER.log"))

    $r = Fill 'A2' @('--submit', '--packet-hash', (Get-PacketHash 'A2'))
    $rep = Report 'A2'
    Check "submit, all gates hold -> applied with the confirmation text ($($r.out))" ($r.code -eq 0 -and $rep.result -eq 'applied' -and $rep.confirmation -match 'Thank you for applying' -and $r.out -match 'applied:')
    $sent = @(if (Test-Path "$out\APPLIED.log") { Get-Content "$out\APPLIED.log" })
    Check "sent exactly once, to the lever fixture ($($sent -join ','))" ($sent.Count -eq 1 -and $sent[0] -eq '/apply/lever')
    Check 'submitted marker written with the packet hash' ((Get-Content "$career\packets\A2\submitted.json" -Raw | ConvertFrom-Json).packetHash -eq (Get-PacketHash 'A2'))
    $r = Fill 'A2' @('--submit', '--packet-hash', (Get-PacketHash 'A2'))
    Check "second send refused (exit 3), nothing sent again ($($r.out))" ($r.code -eq 3 -and @(Get-Content "$out\APPLIED.log").Count -eq 1)
    $r = Fill 'A2'
    Check 'a plain fill after sending is refused too (exit 3), report kept' ($r.code -eq 3 -and (Report 'A2').result -eq 'applied')

    # ---- 6. privacy: values never logged or reported ----
    $reports = (Get-ChildItem -LiteralPath "$career\packets" -Recurse -Filter 'fill-report.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    Check 'no personal values in output or reports' (($script:allOut + $reports) -notmatch [regex]::Escape($email) -and ($script:allOut + $reports) -notmatch [regex]::Escape($phone) -and ($script:allOut + $reports) -notmatch 'linkedin\.example|github\.example|Springfield')
    Check 'the server only ever saw the fixture site (every request was to 127.0.0.1 paths it serves)' (-not ((Get-Content "$out\requests.log") -match '404'))
} finally {
    # only the browser on this test's temp profile and this test's server: the profile path identifies them
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($kitchen) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] -ErrorAction SilentlyContinue; if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } }
    for ($t = 0; $t -lt 10 -and (Test-Path -LiteralPath $root); $t++) { Start-Sleep -Milliseconds 500; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "apply-fill tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
