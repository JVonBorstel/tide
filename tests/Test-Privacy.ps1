# Tests for scripts/privacy-map-check.ps1 (the data map checker, on fixture maps) and the outbound proofs of the privacy plan, step 2:
# a push carries only a fixed title and contents-free words (read from the code, plus notify.ps1's test-log mode: nothing is sent),
# and a private order never routes to a cloud cook (sous-chef.ps1 pick, read-only, with the local model switched off).
# No network, no real kitchen state: everything runs in a temp folder that is removed at the end.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$check = Join-Path $repo 'scripts\privacy-map-check.ps1'; $sous = Join-Path $repo 'kitchen\sous-chef.ps1'; $notify = Join-Path $repo 'kitchen\notify.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('privacy-test-' + [guid]::NewGuid().ToString('N'))
$envNames = 'BRAIN_KITCHEN', 'KITCHEN_OLLAMA_URL', 'KITCHEN_APPROVED', 'KITCHEN_RUN', 'KITCHEN_ATTEMPT', 'KITCHEN_JOB', 'BRAIN_NTFY_TOPIC', 'KITCHEN_NOTIFY_LOG', 'KITCHEN_NOTIFY_FAIL'
$saveEnv = @{}; foreach ($n in $envNames) { $saveEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Run-Check([string]$map) { $p = Join-Path $tmp 'map.md'; Set-Content -LiteralPath $p $map; $o = @(& pwsh -NoProfile -File $check -MapPath $p -RepoRoot (Join-Path $tmp 'repo') 2>&1) -join "`n"; @{ code = $LASTEXITCODE; out = $o } }
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'repo\kitchen\recipes'), (Join-Path $tmp 'repo\src'), (Join-Path $tmp 'kitchen') | Out-Null

    # ---- the map checker, on a fixture repo: two cooks, one private recipe, one career recipe, one plain recipe, one cited file ----
    Set-Content (Join-Path $tmp 'repo\kitchen\kitchen.json') '{ "suppliers": { "claude": { "on": true }, "local": { "on": true } } }'
    Set-Content (Join-Path $tmp 'repo\kitchen\recipes\secret-note.json') '{ "steps": [ { "station": "agent", "args": { "Private": true, "Supplier": "local" } } ] }'
    Set-Content (Join-Path $tmp 'repo\kitchen\recipes\scout.json') '{ "steps": [ { "station": "agent", "args": { "SaveTo": "C:\\Users\\x\\projects\\career\\scout\\a.md" } } ] }'
    Set-Content (Join-Path $tmp 'repo\kitchen\recipes\plain.json') '{ "steps": [ { "station": "agent", "args": { "Role": "do" } } ] }'
    Set-Content (Join-Path $tmp 'repo\src\rule.ps1') "one`ntwo`nthree"
    $head = "# map`n`n| Data | Where | Leaves | Path | Rule |`n|---|---|---|---|---|`n"
    $good = $head + "| Notes | here | nothing | cook:local for recipe:secret-note | private menu ``src/rule.ps1:3`` |`n| Leads | there | search words | cook:claude for recipe:scout | unknown |`n"
    $r = Run-Check $good
    Check 'map check: a good map passes (exit 0, counts printed)' ($r.code -eq 0 -and $r.out -match 'OK \(2 rows, 1 citations, 2 cooks, 2 private/career recipes\)')
    $r = Run-Check ($good -replace 'cook:claude', 'a cloud cook')
    Check 'map check: a cook missing from the map fails and names it' ($r.code -eq 1 -and $r.out -match "cook 'claude'")
    $r = Run-Check ($good -replace 'src/rule.ps1:3', 'src/rule.ps1:9')
    Check 'map check: a dead citation (line past the end) fails' ($r.code -eq 1 -and $r.out -match 'dead citation src/rule.ps1:9')
    $r = Run-Check ($good -replace 'src/rule.ps1:3', 'src/gone.ps1:1')
    Check 'map check: a dead citation (file gone) fails' ($r.code -eq 1 -and $r.out -match 'dead citation src/gone.ps1:1 \(no such file\)')
    $r = Run-Check ($good -replace ' for recipe:scout', '')
    Check 'map check: a career recipe missing from the map fails and names it' ($r.code -eq 1 -and $r.out -match "recipe 'scout'" -and $r.out -notmatch "recipe 'plain'")
    $r = Run-Check ($good -replace '\| unknown \|', '| see the code |')
    Check 'map check: a row with no citation and no "unknown" fails' ($r.code -eq 1 -and $r.out -match "row 'Leads' cites no code")
    $r = Run-Check ($good -replace 'cook:local for', 'cook:local, cook:retired for')
    Check 'map check: a cook the map names but kitchen.json lacks fails' ($r.code -eq 1 -and $r.out -match 'cook:retired')
    $r = @{ out = (@(& pwsh -NoProfile -File $check -MapPath (Join-Path $tmp 'nope.md') -RepoRoot (Join-Path $tmp 'repo') 2>&1) -join "`n"); code = $LASTEXITCODE }
    Check 'map check: no map -> cannot run (exit 2, says why)' ($r.code -eq 2 -and $r.out -match 'no map at')

    # ---- push: what leaves is a fixed title and contents-free words (static, from the code) ----
    $nsrc = Get-Content -LiteralPath $notify
    $sends = @($nsrc | Select-String -Pattern '(?i)Invoke-RestMethod|Invoke-WebRequest|\bcurl\b|WebClient|HttpClient|Net\.Sockets')
    Check 'push: notify.ps1 has exactly one network call' ($sends.Count -eq 1)
    $send = if ($sends.Count) { $sends[0].Line } else { '' }
    Check 'push: that call goes to ntfy.sh with the fixed title "The Board" and only $Text as the body' ($send -match [regex]::Escape('-Uri "https://ntfy.sh/$topic"') -and $send -match "Title = 'The Board'" -and $send -match [regex]::Escape('-Body ([Text.Encoding]::UTF8.GetBytes($Text))'))
    Check 'push: notify.ps1 never reads the hostname' (-not ($nsrc -match '(?i)COMPUTERNAME|hostname|MachineName|GetHostName'))
    $logAt = @($nsrc | Select-String -Pattern 'KITCHEN_NOTIFY_LOG.*exit 0').LineNumber; $sendAt = if ($sends.Count) { $sends[0].LineNumber } else { 0 }
    Check 'push: the test-log branch exits before the send (so this suite sends nothing)' ($logAt.Count -eq 1 -and $logAt[0] -lt $sendAt)
    # behaviour, with the test log instead of the network: an alert with private words goes out as ticket + fixed phrase only
    $env:BRAIN_KITCHEN = Join-Path $tmp 'kitchen'; $env:BRAIN_NTFY_TOPIC = 'privacytest' + ([guid]::NewGuid().ToString('N').Substring(0, 8)); $env:KITCHEN_NOTIFY_LOG = Join-Path $tmp 'notify.log'
    & pwsh -NoProfile -File $notify -Level HIGH -Text ('J12 needs your yes: tailor the resume for Acme, call ' + ('5' * 3) + '-0100') | Out-Null
    & pwsh -NoProfile -File $notify -Level MED -Text 'my sister''s birthday plan was set aside' | Out-Null
    $logged = @(Get-Content -LiteralPath $env:KITCHEN_NOTIFY_LOG -ErrorAction SilentlyContinue)
    Check 'push: an alert with private words sends only "J12 needs your sign-off"' ($logged.Count -eq 2 -and $logged[0] -eq "HIGH|$env:BRAIN_NTFY_TOPIC|J12 needs your sign-off")
    Check 'push: an alert with no ticket sends only a fixed phrase' ($logged.Count -eq 2 -and $logged[1] -eq "MED|$env:BRAIN_NTFY_TOPIC|Kitchen: Failed; the Board has the details")
    $env:BRAIN_NTFY_TOPIC = $null; $env:KITCHEN_NOTIFY_LOG = $null
    # TD-EH-04: notify.ps1's delivery answer (kept on the alerts.jsonl line) is fixed words and a status code, never the text or the topic
    $env:BRAIN_NTFY_TOPIC = 'privacytest' + ([guid]::NewGuid().ToString('N').Substring(0, 8)); $env:KITCHEN_NOTIFY_LOG = Join-Path $tmp 'notify-fail.log'; $env:KITCHEN_NOTIFY_FAIL = '502'
    $ans = @(& pwsh -NoProfile -File $notify -Level HIGH -Text 'J12 my sister''s secret plan' 2>&1); $ansCode = $LASTEXITCODE
    Check 'push answer: a failed send answers only "ntfy error (HTTP 502)" and its status (exit 4), nothing logged as sent' ($ansCode -eq 4 -and $ans.Count -eq 1 -and $ans[0] -eq '{"sent":"failed","why":"ntfy error (HTTP 502)","http":502}' -and -not (Test-Path -LiteralPath $env:KITCHEN_NOTIFY_LOG))
    $env:BRAIN_NTFY_TOPIC = $null; $env:KITCHEN_NOTIFY_LOG = $null; $env:KITCHEN_NOTIFY_FAIL = $null
    $ans = @(& pwsh -NoProfile -File $notify -Level HIGH -Text 'J12 my sister''s secret plan' 2>&1); $ansCode = $LASTEXITCODE
    Check 'push answer: with phone alerts off nothing is sent and it says so (exit 3)' ($ansCode -eq 3 -and $ans.Count -eq 1 -and $ans[0] -eq '{"sent":"off","why":"phone alerts are off"}')
    $dones = @($nsrc | Where-Object { $_ -notmatch '^\s*(#|function Done)' } | ForEach-Object { [regex]::Matches($_, '\bDone\b[^}]*') } | ForEach-Object { $_.Value })
    Check 'push answer: every reason notify.ps1 gives is fixed words; the only value put in is the HTTP status' ($dones.Count -ge 6 -and -not @($dones | Where-Object { @([regex]::Matches($_, '\$\w+') | Where-Object { $_.Value -ne '$status' }).Count }).Count)
    # callers that skip the rewrite (-Safe) pass only fixed words or counts
    $ksrc = Get-Content -LiteralPath (Join-Path $repo 'kitchen\kitchen.ps1') | Select-String -Pattern '^function Send-Notify'
    Check 'push: the supervisor never passes -Safe (its text is always rewritten)' ($ksrc.Count -eq 1 -and $ksrc[0].Line -match [regex]::Escape('& $notify') -and $ksrc[0].Line -notmatch '-Safe')
    $vsafe = @(Get-Content -LiteralPath (Join-Path $repo 'kitchen\stations\verify.ps1') | Select-String -Pattern '\$notifyScript .*-Safe')
    Check 'push: verify.ps1 -Safe alerts interpolate only the ticket number' ($vsafe.Count -ge 1 -and -not @($vsafe | Where-Object { $_.Line -notmatch '-Text "[^"]*"' -or ([regex]::Match($_.Line, '-Text "([^"]*)"').Groups[1].Value -match '\$(?!job\b)') }).Count)
    $ssrc = Get-Content -LiteralPath (Join-Path $repo 'pass-app\server.mjs')
    $calls = @($ssrc | Select-String -Pattern "\bpush\('(INFO|MED|HIGH)', (.+?)\);(\s|$)" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[2].Value })
    # every Chef push is quoted text plus counts: the names left after dropping quoted text (in a template, those inside ${...}) must be
    # on the list given (m = the lead's mode word, away or back; n and bits = counts)
    function Only-Counts([string]$s, [string[]]$ok) { foreach ($m in [regex]::Matches($s, '\$\{([^}]*)\}')) { $e = $m.Groups[1].Value -replace "'[^']*'", ''; foreach ($id in [regex]::Matches($e, '[A-Za-z_]\w*')) { if ($ok -notcontains $id.Value) { return $false } } }; $true }
    function Alert-Ok([string]$a) { if ($a -match '^`[^`]*`$') { Only-Counts $a @('bits', 'length', 'join', 'n') } elseif ($a -notmatch '`') { Only-Counts ('${' + $a + '}') @('m') } else { $false } }
    Check 'push: Chef sends at least the known alerts (the scan below is not empty)' ($calls.Count -ge 5)
    Check "push: every Chef alert is fixed text or counts (no names, links or chat)" (-not @($calls | Where-Object { -not (Alert-Ok $_) }).Count)
    $bits = @($ssrc | Select-String -Pattern 'const bits = \[')
    Check 'push: the morning brief alert is built from counts only' ($bits.Count -eq 1 -and (Only-Counts $bits[0].Line @('b', 'packCount', 'newRoleCount', 'followUps', 'needsYou', 'plated', 'setAside', 'length')))

    # ---- a private order never routes to a cloud cook (sous-chef.ps1 pick, read-only; local model off so nothing is called) ----
    $env:BRAIN_KITCHEN = Join-Path $tmp 'kitchen'; $env:KITCHEN_OLLAMA_URL = 'off'
    foreach ($n in 'KITCHEN_APPROVED', 'KITCHEN_RUN', 'KITCHEN_ATTEMPT', 'KITCHEN_JOB') { [Environment]::SetEnvironmentVariable($n, $null) }
    $kj = Get-Content -LiteralPath (Join-Path $repo 'kitchen\kitchen.json') -Raw | ConvertFrom-Json -AsHashtable
    $cloud = @($kj.suppliers.Keys | Where-Object { $_ -ne 'local' })
    Check 'private route: kitchen.json has cloud cooks to guard against' ($cloud.Count -ge 1)
    function Pick([hashtable]$a) { (& $sous pick @a -Json | Out-String) | ConvertFrom-Json }
    function Stays-Here($d) { $d.private -eq $true -and $cloud -notcontains [string]$d.supplier -and -not @(@($d.fallbacks) | Where-Object { $_ -and $cloud -contains [string]$_.supplier }).Count }
    $d = Pick @{ Role = 'do'; Prompt = 'Draft a cover note from my resume'; Tools = 'none'; Private = $true }
    Check 'private route: a private plain-text order never gets a cloud cook' (Stays-Here $d)
    $d = Pick @{ Role = 'do'; Prompt = 'Update the tailored resume file'; Tools = 'Read,Edit'; Mode = 'acceptEdits'; Private = $true }
    Check 'private route: a private edit order (no local cook can edit) holds, never a cloud cook' ((Stays-Here $d) -and $d.action -ne 'cook')
    $d = Pick @{ Role = 'research'; Prompt = 'Find salary data for my role'; Tools = 'WebSearch'; Private = $true }
    Check 'private route: a private web order never gets a cloud cook' ((Stays-Here $d) -and $d.action -ne 'cook')
    foreach ($c in $cloud) {
        $d = Pick @{ Role = 'do'; Prompt = 'Summarise my career notes'; Tools = 'none'; Private = $true; Supplier = $c }
        Check "private route: a private order that names $c is held" ($d.action -eq 'hold' -and (Stays-Here $d))
    }
    $d = Pick @{ Role = 'do'; Prompt = 'Summarise my career notes'; Tools = 'none'; Private = $true; Model = 'sonnet' }
    Check 'private route: a private order that names a cloud model is held' ($d.action -eq 'hold' -and (Stays-Here $d))
    $d = Pick @{ Role = 'do'; Prompt = ('Send my resume to ' + 'jane.doe' + '@' + 'gmail.com'); Tools = 'none' }
    Check 'private route: an unmarked order with personal details is private and stays here' (Stays-Here $d)
}
finally {
    foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $saveEnv[$n]) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Test-Privacy: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
exit 0
