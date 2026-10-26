# Tests for kitchen/stations/lead-pitch.ps1 (client leads for the Clients screen): parsing the scout's file, dedupe by link, unsafe links
# dropped, an unreadable store never replaced, only a model on this PC allowed, a model that is down leaves leads saved and pitches waiting,
# Jordan's marks kept across runs. LEAD_PITCH_FAKE stands in for the model except in the model-down check. Self-cleaning.
$ErrorActionPreference = 'Stop'
$st = Join-Path $PSScriptRoot '..\kitchen\stations\lead-pitch.ps1'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$d = Join-Path ([IO.Path]::GetTempPath()) ('lead-pitch-' + [guid]::NewGuid().ToString('N'))
function Run([string[]]$a) { $o = & pwsh -NoProfile -File $st @a 2>&1 | Out-String; @{ out = $o; code = $LASTEXITCODE } }
function Store { Get-Content -LiteralPath (Join-Path $d 'leads.json') -Raw | ConvertFrom-Json }
$savedFake = $env:LEAD_PITCH_FAKE; $savedJob = $env:KITCHEN_JOB
try {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'OFFER.md') -Value '# Offer: chatbots $300'
    $leads = Join-Path $d 'a-leads.md'
    Set-Content -LiteralPath $leads -Value @"
# Leads
## Lead: Chatbot for a dental office
- Source: Reddit r/forhire
- Link: https://www.reddit.com/r/forhire/comments/abc/x/
- Posted: 2026-10-18
- Budget: `$400
- Need: "Add an AI chatbot that books cleanings."$([char]0x202E)evil
## Lead: Same post, other host
- Link: https://old.reddit.com/r/forhire/comments/abc/x
## Lead: Script link
- Link: javascript:alert(1)
## Lead: Zapier for a bakery
- **Source**: Upwork
- **Link**: [post](https://www.upwork.com/jobs/~01abc)
- **Need**: connect orders to a sheet
# SOURCES
## Lead: after sources is ignored
- Link: https://example.com/ignored
"@
    $env:KITCHEN_JOB = $null
    # 1. parse, dedupe, unsafe links dropped, pitches drafted
    $env:LEAD_PITCH_FAKE = 'PITCH for'
    $r = Run @('-Leads', $leads, '-IncomeDir', $d)
    Check 'first run exit 0, says done' ($r.code -eq 0 -and $r.out -match 'lead-pitch: done \(2 new, 2 pitched, 0 waiting')
    $s = Store
    Check 'two leads kept (duplicate host, javascript: link and post-SOURCES lead dropped)' (@($s.items).Count -eq 2)
    Check 'ids L1, L2 and nextId 3' ($s.items[0].id -eq 'L1' -and $s.items[1].id -eq 'L2' -and $s.nextId -eq 3)
    Check 'fields parsed (source, budget, need)' ($s.items[0].source -eq 'Reddit r/forhire' -and $s.items[0].budget -eq '$400' -and $s.items[0].need -match 'books cleanings')
    Check 'bidi control character stripped from web text' ($s.items[0].need -notmatch [char]0x202E)
    Check 'bold labels and a markdown link parsed' ($s.items[1].source -eq 'Upwork' -and $s.items[1].link -eq 'https://www.upwork.com/jobs/~01abc')
    Check 'pitches drafted, status new' ($s.items[0].pitch -eq 'PITCH for Chatbot for a dental office' -and $s.items[0].status -eq 'new')
    # 2. a second run of the same file adds nothing; Jordan's marks stay
    $s.items[0].status = 'sent'; $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $d 'leads.json')
    $r = Run @('-Leads', $leads, '-IncomeDir', $d)
    Check 'rerun: nothing new' ($r.code -eq 0 -and $r.out -match '\(0 new, 0 pitched')
    Check 'rerun: sent mark kept' ((Store).items[0].status -eq 'sent')
    # 3. the model is down: new leads are still saved, pitches wait; the next run fills them
    $env:LEAD_PITCH_FAKE = $null
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    $b = Join-Path $d 'b-leads.md'
    Set-Content -LiteralPath $b -Value "## Lead: Data entry from PDFs`n- Link: https://news.ycombinator.com/item?id=1`n- Need: pull invoices into a sheet"
    $r = Run @('-Leads', $b, '-IncomeDir', $d, '-OllamaUrl', "http://127.0.0.1:$port")
    Check 'model down: exit 0, lead saved, 1 waiting' ($r.code -eq 0 -and $r.out -match 'not answering' -and $r.out -match '\(1 new, 0 pitched, 1 waiting')
    $env:LEAD_PITCH_FAKE = 'LATER'
    $r = Run @('-IncomeDir', $d)
    Check 'no -Leads: fills the waiting pitch' ($r.code -eq 0 -and $r.out -match '\(0 new, 1 pitched, 0 waiting' -and ((Store).items | Where-Object id -eq 'L3').pitch -match '^LATER')
    # 4. a model that is not on this PC is refused (the offer and drafts stay local)
    $r = Run @('-IncomeDir', $d, '-OllamaUrl', 'https://api.example.com')
    Check 'non-local model refused (exit 2)' ($r.code -eq 2 -and $r.out -match 'not on this PC')
    # 4b. Chef holds leads.json.lock (a tap from the phone): the station waits, then gives up without writing
    $before = Get-Content -LiteralPath (Join-Path $d 'leads.json') -Raw
    Set-Content -LiteralPath (Join-Path $d 'leads.json.lock') -Value 'chef'
    $c = Join-Path $d 'c-leads.md'; Set-Content -LiteralPath $c -Value "## Lead: Busy test`n- Link: https://example.org/busy"
    $r = Run @('-Leads', $c, '-IncomeDir', $d)
    Check 'lock held: exit 1 busy, nothing written' ($r.code -eq 1 -and $r.out -match 'busy' -and (Get-Content -LiteralPath (Join-Path $d 'leads.json') -Raw) -eq $before)
    [IO.File]::Delete((Join-Path $d 'leads.json.lock'))
    $r = Run @('-Leads', $c, '-IncomeDir', $d)
    Check 'lock free again: the lead is saved, lock released' ($r.code -eq 0 -and $r.out -match '\(1 new' -and -not (Test-Path -LiteralPath (Join-Path $d 'leads.json.lock')))
    # 5. an unreadable store is never replaced
    Set-Content -LiteralPath (Join-Path $d 'leads.json') -Value '{ broken'
    $r = Run @('-Leads', $leads, '-IncomeDir', $d)
    Check 'unreadable leads.json: exit 2, file untouched' ($r.code -eq 2 -and (Get-Content -LiteralPath (Join-Path $d 'leads.json') -Raw).Trim() -eq '{ broken')
    # 6. the kitchen's {{job}} placeholder and a missing file
    $env:KITCHEN_JOB = 'J7'; Remove-Item -LiteralPath (Join-Path $d 'leads.json')
    Copy-Item $leads (Join-Path $d 'J7-leads.md')
    $r = Run @('-Leads', (Join-Path $d '{{job}}-leads.md'), '-IncomeDir', $d)
    Check '{{job}} filled from KITCHEN_JOB; job recorded' ($r.code -eq 0 -and (Store).items[0].job -eq 'J7')
    $r = Run @('-Leads', (Join-Path $d 'nope.md'), '-IncomeDir', $d)
    Check 'missing leads file: exit 2' ($r.code -eq 2)
    # 7. the recipe wires it: public research step saving to the income scout folder, then this station
    $rc = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\kitchen\recipes\leadscout.json') -Raw | ConvertFrom-Json
    Check 'recipe: public research step, then lead-pitch' ($rc.public -eq $true -and $rc.steps[0].args.Public -eq $true -and $rc.steps[1].station -eq 'lead-pitch' -and $rc.steps[0].args.SaveTo -eq $rc.steps[1].args.Leads)
} finally {
    $env:LEAD_PITCH_FAKE = $savedFake; $env:KITCHEN_JOB = $savedJob
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "LeadPitch tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -ne 0))
