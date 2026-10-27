# Tests for pass-app/server.mjs (the phone app): key required, live stream, actions through the kitchen API, path safety, localhost only.
# Private kitchen root under TEMP, its own port; self-cleaning.
# runAlone: the tests station never runs this next to another suite (it failed twice in a 4-at-once run of all suites, 653/653 alone)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$k = Join-Path $repo 'kitchen\kitchen.ps1'; $w = Join-Path $repo 'kitchen\demo-worker.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-pass-' + [guid]::NewGuid().ToString('N'))
# W4 acceptance (pass-app/test-patch.mjs: patches, keyed rows, change-driven state, no git on the loop; its own three throwaway servers,
# about 75 s, one of them watched for a full 60 s loop window): started now, beside this suite, and read at the end
$w4Out = "$root-w4.json"
$env:PASS_GITHUB = 'off'   # the City's GitHub reads (pass-app/towers.mjs): off for W4's servers; this suite's server reads a fake gh (below)
$w4Psi =[Diagnostics.ProcessStartInfo]::new('cmd.exe'); $w4Psi.Arguments = "/c node `"$(Join-Path $repo 'pass-app\test-patch.mjs')`" > `"$w4Out`" 2> `"$root-w4-err.txt`""
$w4Psi.UseShellExecute = $false; $w4Psi.CreateNoWindow = $true
$w4 = [Diagnostics.Process]::new(); $w4.StartInfo = $w4Psi; [void]$w4.Start()
$port = Get-Random -Minimum 20000 -Maximum 40000
$env:BRAIN_KITCHEN = $root; $env:PASS_PORT = "$port"; $env:PASS_NO_TAILSCALE = '1'; $env:PASS_HOSTS = 'chef-box.tailnet-test.example'; $env:BRAIN_NTFY_TOPIC = $null; $env:PASS_NO_KICK = '1'; $env:KITCHEN_OLLAMA_URL = 'off'; $env:KITCHEN_AGY_EXE = 'off'
# the City's GitHub reads go to a fake gh (node, answers.json beside it), every 5 s, never the network
$ghFake = "$root-gh"; New-Item -ItemType Directory -Force $ghFake | Out-Null
Set-Content "$ghFake\gh.mjs" @'
// a fake gh for tests/Test-PassApp.ps1: answers from answers.json beside it; never the network
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url)); const args = process.argv.slice(2);
// the suite's hand on the read clock: while a "hold" file is here, a PR list call says so ("held") and waits for it to go, so no read
// can finish (and move githubAt) while the suite reads the City, and that read's lists see only the answers written while it was held.
// Only the lists: a read with both lists good sets githubAt even when its last call (api rate_limit) fails, so holding that call
// would let a read that already had good lists finish after the switch.
if (args[0] === 'pr' && fs.existsSync(path.join(here, 'hold'))) { fs.writeFileSync(path.join(here, 'held'), ''); while (fs.existsSync(path.join(here, 'hold'))) await new Promise((r) => setTimeout(r, 25)); }
const a = JSON.parse(fs.readFileSync(path.join(here, 'answers.json'), 'utf8'));
if (a.fail) { process.stderr.write('To get started with GitHub CLI, please run:  gh auth login'); process.exit(4); }
if (args[0] === 'api') { process.stdout.write(JSON.stringify({ resources: { graphql: { remaining: 4999 } } })); process.exit(0); }
process.stdout.write(JSON.stringify(a[args[args.indexOf('--state') + 1]] || []));
'@ -Encoding utf8
function Set-GhAnswers($fail) {
    @{ fail = $fail; merged = @(@{ number = 5; title = 'City floor from GitHub'; mergedAt = [DateTime]::UtcNow.AddHours(-1).ToString('o'); mergeCommit = @{ oid = ('5' * 40) }; headRefName = 'hand-branch' })
        open = @(@{ number = 6; title = 'City crane from GitHub'; isDraft = $false; createdAt = [DateTime]::UtcNow.ToString('o'); headRefName = 'kitchen/J952'; statusCheckRollup = @(@{ status = 'COMPLETED'; conclusion = 'FAILURE' }) }) } | ConvertTo-Json -Depth 6 | Set-Content "$ghFake\answers.tmp" -Encoding utf8
    Move-Item -LiteralPath "$ghFake\answers.tmp" -Destination "$ghFake\answers.json" -Force   # whole, never a half-written file to a read
}
# holds the fake gh (above) and returns once a read is waiting on it: from then until Release-GhRead, githubAt cannot move
function Hold-GhRead {
    Remove-Item -LiteralPath "$ghFake\held" -Force -ErrorAction SilentlyContinue; Set-Content "$ghFake\hold" ''
    for ($i = 0; $i -lt 80 -and -not (Test-Path -LiteralPath "$ghFake\held"); $i++) { Start-Sleep -Milliseconds 250 }
    Test-Path -LiteralPath "$ghFake\held"
}
function Release-GhRead { Remove-Item -LiteralPath "$ghFake\hold", "$ghFake\held" -Force -ErrorAction SilentlyContinue }
Set-GhAnswers $false
$env:PASS_GITHUB = $null; $env:PASS_GH = "$ghFake\gh.mjs"; $env:PASS_GITHUB_MS = '5000'
$career = "$root-career"; $env:PASS_CAREER_DIR = $career; $env:PASS_APPLY_FILL = "$root-fill\apply-fill.mjs"; $env:KITCHEN_NOTIFY_LOG = "$root-notify.txt"; $env:KITCHEN_NO_DIAGNOSE = '1'; $env:PASS_STALL_CHECK_MS = '500'
New-Item -ItemType Directory -Force "$career\scout" | Out-Null
$income = "$root-income"; $env:PASS_INCOME_DIR = $income; New-Item -ItemType Directory -Force $income | Out-Null
Set-Content "$income\leads.json" '{"nextId":3,"items":[{"id":"L1","title":"Chatbot for a dentist","source":"Reddit","link":"https://example.com/l1","need":"FAQ bot","pitch":"Hi, I can build that.","status":"new"},{"id":"L2","title":"Bad link","link":"javascript:alert(1)","pitch":"x","status":"new"}]}'
Set-Content "$career\scout\J1-openings.md" "# Openings`n`n- **AI Engineer** at Acme (remote, US). `$150,000 – `$180,000. Posted today.`n  Fit: Strong match.`n  Link: https://example.com/acme`n`n- **Full Stack Dev** at Beta (Springfield). Pay not listed.`n  Fit: Good.`n  Link: https://example.com/beta`n" -Encoding utf8
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$base = "http://127.0.0.1:$port"
function Get-Code($url, $headers = @{}) { try { (Invoke-WebRequest $url -Headers $headers -SkipHttpErrorCheck -TimeoutSec 20).StatusCode } catch { -1 } }
$srv = $null
try {
    & $k add -Name gated -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } -Approve | Out-Null
    & $k add -Name 'flaky thing' -Script $w -ScriptArgs @{ Behavior = 'fail'; Seconds = 1 } -Retries 0 | Out-Null
    for ($i = 0; $i -lt 8; $i++) { & $k tick -Quiet | Out-Null; Start-Sleep -Milliseconds 700 }
    # started through ProcessStartInfo (not Start-Process, which the lint forbids without -Wait); the finally block stops it
    $psi = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $psi.Arguments = "/c node `"$(Join-Path $repo 'pass-app\server.mjs')`" > `"$root-out.txt`" 2> `"$root-err.txt`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $srv = [Diagnostics.Process]::new(); $srv.StartInfo = $psi; [void]$srv.Start()
    for ($i = 0; $i -lt 40 -and (Get-Code "$base/manifest.webmanifest") -ne 200; $i++) { Start-Sleep -Milliseconds 250 }
    $key = (Get-Content (Join-Path $root 'pass-key.txt') -Raw).Trim()
    $auth = @{ Authorization = "Bearer $key" }

    Check 'key file is 64 hex' ($key -match '^[0-9a-f]{64}$')
    Check 'state needs the key' ((Get-Code "$base/api/state") -eq 401)
    Check 'app page needs the key' ((Get-Code "$base/") -eq 401)
    Check 'wrong key refused' ((Get-Code "$base/api/state" @{ Authorization = 'Bearer ' + ('0' * 64) }) -eq 401)
    Check 'manifest open for home-screen install' ((Get-Code "$base/manifest.webmanifest") -eq 200)
    Set-Content (Join-Path $root 'pass-users.txt') 'chef@example.com'
    $tsHost = 'chef-box.tailnet-test.example'
    Check 'tailscale login on the list gets in' ((Get-Code "$base/api/state" @{ 'Tailscale-User-Login' = 'Chef@Example.com'; Host = $tsHost }) -eq 200)
    Check 'other tailscale login refused' ((Get-Code "$base/api/state" @{ 'Tailscale-User-Login' = 'stranger@example.com'; Host = $tsHost }) -eq 401)
    # DNS rebinding: a page on evil.example resolved to 127.0.0.1 carries its own Host; a local Host never trusts the Tailscale header
    Check 'rebinding: a foreign Host is refused before auth (421)' ((Get-Code "$base/api/state" @{ 'Tailscale-User-Login' = 'chef@example.com'; Host = "evil.example:$port" }) -eq 421 -and (Get-Code "$base/manifest.webmanifest" @{ Host = "evil.example:$port" }) -eq 421)
    Check 'rebinding: the Tailscale header on a local Host is not trusted' ((Get-Code "$base/api/state" @{ 'Tailscale-User-Login' = 'chef@example.com' }) -eq 401)
    Check 'rebinding: localhost on the wrong port is refused' ((Get-Code "$base/api/state" @{ Host = 'localhost:1' }) -eq 421)
    $foreign = Invoke-WebRequest "$base/api/action" -Method Post -Headers @{ Authorization = "Bearer $((Get-Content (Join-Path $root 'pass-key.txt') -Raw).Trim())"; Origin = 'http://evil.example' } -ContentType 'application/json' -Body '{"op":"live-off"}' -SkipHttpErrorCheck
    Check 'csrf: a POST from a foreign Origin is refused (403)' ($foreign.StatusCode -eq 403)
    $own = Invoke-WebRequest "$base/api/action" -Method Post -Headers @{ 'Tailscale-User-Login' = 'chef@example.com'; Host = $tsHost; Origin = "https://$tsHost" } -ContentType 'application/json' -Body '{"op":"live-off"}' -SkipHttpErrorCheck
    Check "csrf: a POST from Chef's own tailnet origin is accepted" ($own.StatusCode -eq 200)
    $h = [Net.Http.HttpClientHandler]::new(); $h.AllowAutoRedirect = $false; $nc = [Net.Http.HttpClient]::new($h)
    # sign-in is the POST form (the key never goes in a link; tests/Test-ChefSecurity.ps1 holds GET /login?key= to "never signs in")
    $signIn = { param($k) $nc.PostAsync("$base/login", [Net.Http.StringContent]::new("key=$k", [Text.Encoding]::UTF8, 'application/x-www-form-urlencoded')).GetAwaiter().GetResult() }
    $login = & $signIn $key
    $cookie = ($login.Headers.GetValues('Set-Cookie') -join ' ')
    Check 'login sets an HttpOnly Secure strict cookie' ([int]$login.StatusCode -eq 303 -and $cookie -match 'HttpOnly' -and $cookie -match 'Secure' -and $cookie -match 'SameSite=Strict')
    Check 'bad login refused' ([int](& $signIn 'nope').StatusCode -eq 401)
    $nc.Dispose()

    # the Ledger tab: ledger.json (kitchen/ledger.ps1) plus the watchers' heartbeats; Chef is also an independent watcher of the tick
    Check 'ledger needs the key' ((Get-Code "$base/api/ledger") -eq 401)
    $ledgerSaved = if (Test-Path (Join-Path $root 'ledger.json')) { Get-Content (Join-Path $root 'ledger.json') -Raw } else { $null }
    $lgItems = @(@{ id = 'I1'; kind = 'idea'; title = 'lost one'; state = 'lost'; owner = 'Claude'; why = 'nothing replaced it'; jordans = $true; chain = @(@{ id = 'J9'; status = 'closed'; note = 'x' }) })
    @{ ok = $true; updated = [DateTime]::UtcNow.ToString('o'); top = 'Ledger: 1 lost'; counts = @{ lost = 1; waitingOnJordan = 0 }; programs = @(@{ repo = 'gw'; total = 4; shipped = 2 }); flags = @(@{ id = 'I1'; rule = 'lost'; owner = 'Claude'; say = 'lost one: lost.' }); items = $lgItems } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'ledger.json') -Encoding utf8
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'watch') | Out-Null
    @{ name = 'memory'; lastRun = [DateTime]::UtcNow.AddMinutes(-300).ToString('o'); everyMin = 60; found = 1; findings = @(@{ say = 'NOW.md is 5 days old' }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'watch\memory.json') -Encoding utf8
    $lg = (Invoke-RestMethod "$base/api/ledger" -Headers $auth).data
    Check 'ledger: items, counts and programs come through' ($lg.items[0].id -eq 'I1' -and $lg.items[0].chain[0].id -eq 'J9' -and $lg.counts.lost -eq 1 -and $lg.programs[0].shipped -eq 2)
    Check 'ledger: a late watcher (5 h, every 60 min) raises an alarm' (@($lg.alarms | Where-Object { $_ -match 'memory watcher last ran 300 minutes ago' }).Count -eq 1)
    Check 'ledger: watcher findings are listed' (@($lg.watch | Where-Object { $_.name -eq 'memory' })[0].problems[0] -match 'NOW.md')
    # TD-EH-26: paused, the watchers marked whilePaused and the paused Walkround (lastTickEnd) still alarm when late; paused work's
    # heartbeats (the ledger) and the held lastTick do not
    $supP26 = Join-Path $root 'supervisor.json'; $supKeep26 = Get-Content $supP26 -Raw -ErrorAction SilentlyContinue
    @{ name = 'memory'; lastRun = [DateTime]::UtcNow.AddMinutes(-300).ToString('o'); everyMin = 60; whilePaused = $true } | ConvertTo-Json | Set-Content (Join-Path $root 'watch\memory.json') -Encoding utf8
    @{ name = 'ledger'; lastRun = [DateTime]::UtcNow.AddMinutes(-300).ToString('o'); everyMin = 5 } | ConvertTo-Json | Set-Content (Join-Path $root 'watch\ledger.json') -Encoding utf8
    @{ lastTick = [DateTime]::UtcNow.AddMinutes(-60).ToString('o'); lastTickEnd = [DateTime]::UtcNow.AddMinutes(-30).ToString('o') } | ConvertTo-Json | Set-Content $supP26 -Encoding utf8
    Set-Content (Join-Path $root 'PAUSED') 'test'
    try { $lgp = (Invoke-RestMethod "$base/api/ledger" -Headers $auth).data }
    finally { Remove-Item (Join-Path $root 'PAUSED'), (Join-Path $root 'watch\ledger.json') -ErrorAction SilentlyContinue; if ($null -ne $supKeep26) { Set-Content $supP26 $supKeep26 -NoNewline -Encoding utf8 } else { Remove-Item $supP26 -ErrorAction SilentlyContinue } }
    Check 'TD-EH-26: paused, a late whilePaused watcher still alarms; a late heartbeat of paused work does not' ($lgp.paused -eq $true -and @($lgp.alarms | Where-Object { $_ -match 'memory watcher last ran 300' }).Count -eq 1 -and -not @($lgp.alarms | Where-Object { $_ -match 'ledger watcher' }).Count)
    Check 'TD-EH-26: paused, a silent paused Walkround alarms; the held lastTick does not' (@($lgp.alarms | Where-Object { $_ -match 'paused Walkround' -and $_ -match '30 minutes' }).Count -eq 1 -and -not @($lgp.alarms | Where-Object { $_ -match 'not ticked' }).Count)
    Remove-Item (Join-Path $root 'watch\memory.json')
    Remove-Item (Join-Path $root 'ledger.json')
    $lg = (Invoke-RestMethod "$base/api/ledger" -Headers $auth).data
    Check 'ledger: no ledger yet is an alarm, never an empty all-clear' (@($lg.alarms | Where-Object { $_ -match 'not been built' }).Count -eq 1 -and @($lg.items).Count -eq 0)
    if ($null -ne $ledgerSaved) { Set-Content (Join-Path $root 'ledger.json') $ledgerSaved -NoNewline -Encoding utf8 }
    $app = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw; $html = Get-Content (Join-Path $repo 'pass-app\public\index.html') -Raw
    Check 'ledger tab: in the bar, a view, and rendered from /api/ledger' ($html -match 'href="#/ledger"' -and $html -match 'id="view-ledger"' -and $app -match "api\('/api/ledger'\)" -and $app -match "ledger: 'Ledger'")
    # I173: `lead-text?.focus()` parses as `lead - text?.focus()` and throws (the note box never got focus); J113's fix was undone once
    Check 'lead note: focus goes through $() (no bare lead-text?. expression)' ($app -notmatch '(?<![''"#\w-])lead-text\?\.' -and $app -match "\`$\('lead-text'\)\?\.focus")
    Check 'ledger tab: Drop and Build again ask first' ($app -match "title: 'Drop this idea\?'" -and $app -match "title: 'Build this again\?'")

    $s = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'state lists the jobs' (@($s.jobs).Count -eq 2 -and @($s.jobs | Where-Object { $_.name -eq 'gated' })[0].status -eq 'waiting-approval')
    Check 'state has vitals' ($null -ne $s.tickAge -and $s.budget -gt 0)
    Check 'state: no scoreboard line yet is null' ($null -eq $s.scoreboard)
    @(@{ rate = 0.5; leap = 1 }, @{ rate = 0.9; leap = 2; leapName = 'Measured and lean'; trendArrow = [string][char]0x2191 }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root 'scoreboard.jsonl') -Encoding utf8
    $s2 = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'state: carries the last scoreboard line (rate, leap, trend arrow)' ($s2.scoreboard.rate -eq 0.9 -and $s2.scoreboard.leap -eq 2 -and $s2.scoreboard.leapName -eq 'Measured and lean' -and $s2.scoreboard.trendArrow -eq [string][char]0x2191)
    Add-Content (Join-Path $root 'scoreboard.jsonl') -Value 'not-json-line'
    $sCorrupt = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'state: malformed scoreboard line gracefully returns null' ($null -eq $sCorrupt.scoreboard)
    Check 'state: the tick wrote freeze.json, nothing frozen in this kitchen' ((Test-Path (Join-Path $root 'freeze.json')) -and @($sCorrupt.freeze.repos).Count -eq 0)
    $fzTo = [DateTimeOffset]::Now.AddHours(30).ToString('o'); $fzOld = [DateTimeOffset]::Now.AddHours(-1).ToString('o')
    @{ at = (Get-Date).ToString('o'); repos = @(@{ repo = 'C:\x\demo-project'; name = 'demo-project'; windows = @(@{ from = [DateTimeOffset]::Now.AddHours(-2).ToString('o'); to = $fzTo; why = 'release demo'; fromText = '10-27 00:00'; toText = '10-28 18:00' }, @{ from = [DateTimeOffset]::Now.AddHours(-5).ToString('o'); to = $fzOld; why = 'over'; fromText = 'a'; toText = 'b' }) }); errors = @(@{ repo = 'C:\x\y'; name = 'y'; error = "'freeze[0].to' bad" }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'freeze.json') -Encoding utf8
    $sFz = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'state: freeze windows from freeze.json (ended ones dropped) and config errors' (@($sFz.freeze.repos).Count -eq 1 -and @($sFz.freeze.repos[0].windows).Count -eq 1 -and $sFz.freeze.repos[0].windows[0].why -eq 'release demo' -and $sFz.freeze.repos[0].windows[0].toText -eq '10-28 18:00' -and $sFz.freeze.errors[0].error -match 'freeze\[0\]\.to')
    Remove-Item (Join-Path $root 'freeze.json')
    # main status (TD-EH-03a): verify writes <kitchen>\main-status\<sha12>.json per Tower; the state carries every Tower, red and green,
    # and a file that cannot be read is shown as unreadable (never dropped)
    Check 'state: no main status recorded yet is an empty list' ($sFz.PSObject.Properties.Name -contains 'mainStatus' -and @($sFz.mainStatus).Count -eq 0)
    $msDir = Join-Path $root 'main-status'; New-Item -ItemType Directory -Force $msDir | Out-Null
    $msSince = [DateTime]::UtcNow.AddHours(-3.5).ToString('o')
    @{ repo = 'C:\x\brain-monitor'; tower = 'brain-monitor'; state = 'red'; suites = @('Test-VerifyCache', 'Test-PassApp'); why = 'Test-VerifyCache: FAIL: train.ps1 not found <b>'; since = $msSince; sha = '9228e6f229278eb369c24b28b875f6dcef2ff057'; at = [DateTime]::UtcNow.ToString('o'); job = 'J209' } | ConvertTo-Json | Set-Content (Join-Path $msDir 'aaaaaaaaaaaa.json') -Encoding utf8
    @{ repo = 'C:\x\demo-project'; tower = 'demo-project'; state = 'green'; suites = @(); why = ''; since = $msSince; sha = 'b' * 40; at = [DateTime]::UtcNow.ToString('o'); job = 'J210' } | ConvertTo-Json | Set-Content (Join-Path $msDir 'bbbbbbbbbbbb.json') -Encoding utf8
    Set-Content (Join-Path $msDir 'cccccccccccc.json') '{ torn' -Encoding utf8
    $sMs = Invoke-RestMethod "$base/api/state" -Headers $auth
    $msRed = @($sMs.mainStatus | Where-Object { $_.tower -eq 'brain-monitor' })[0]
    Check 'state: a red main comes through with suites, why, since, sha and the order' ($msRed.state -eq 'red' -and (@($msRed.suites) -join ',') -eq 'Test-VerifyCache,Test-PassApp' -and $msRed.why -match '^Test-VerifyCache: FAIL: train\.ps1 not found' -and $msRed.sha -eq '9228e6f229278eb369c24b28b875f6dcef2ff057' -and $msRed.job -eq 'J209' -and $null -ne $msRed.since)
    Check 'state: a green main comes through; an unreadable file is shown as unreadable' (@($sMs.mainStatus | Where-Object { $_.tower -eq 'demo-project' -and $_.state -eq 'green' }).Count -eq 1 -and @($sMs.mainStatus | Where-Object { $_.state -eq 'unreadable' -and $_.tower -eq 'cccccccccccc' }).Count -eq 1 -and @($sMs.mainStatus).Count -eq 3)
    # the banner text itself (pass-app/public/main-status.js, pure, run in node): red says since when, which suites, why; green says nothing
    $msJson = Join-Path $root 'ms-in.json'; ConvertTo-Json -InputObject @($sMs.mainStatus) -Depth 5 | Set-Content $msJson -Encoding utf8
    $msMjs = Join-Path $root 'ms-banner.mjs'
    Set-Content $msMjs @"
import fs from 'node:fs';
import { mainStatusBanners } from '$(([Uri](Join-Path $repo 'pass-app\public\main-status.js')).AbsoluteUri)';
const towers = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, ''));
const red = towers.find((t) => t.state === 'red');
console.log(JSON.stringify({ all: mainStatusBanners(towers, { when: () => 'Fri 1:14 PM', now: new Date(red.since).getTime() + 3.5 * 3600000 }),
  green: mainStatusBanners(towers.filter((t) => t.state === 'green')), none: mainStatusBanners(undefined), noWhy: mainStatusBanners([{ tower: 't', state: 'red', since: 'x', suites: [] }]) }));
"@ -Encoding utf8
    $msOut = (& node $msMjs $msJson 2>$null | Out-String) | ConvertFrom-Json   # stdout only: node may warn on stderr about module types
    $msBanner = @($msOut.all | Where-Object { $_ -match 'data-main-status="red"' })[0]
    Check 'banner: main is red, with since, how long, suites as Failed, why and the sha checked by its work order' ($msBanner -eq '<div class="banner" data-main-status="red">Main is red: brain-monitor, since at least Fri 1:14 PM (3.5 h). Failed: Test-VerifyCache, Test-PassApp. Why: Test-VerifyCache: FAIL: train.ps1 not found &lt;b&gt;. Last checked 9228e6f22927 by Work order WO-0209.</div>')
    Check 'banner: an unreadable status is a banner too; a green main shows none' (@($msOut.all).Count -eq 2 -and @($msOut.all | Where-Object { $_ -match 'data-main-status="unreadable"' -and $_ -match 'Main status for cccccccccccc cannot be read' }).Count -eq 1 -and @($msOut.green).Count -eq 0 -and @($msOut.none).Count -eq 0)
    Check 'banner: no reason and no time are said, never left blank' (@($msOut.noWhy)[0] -match 'Main is red: t, since an unknown time\. No reason was recorded\.</div>$')
    Check 'banner: the app shows it first among the Yard banners, in the existing banner style' ($app -match "import \{ mainStatusBanners \} from './main-status\.js'" -and $app -match '(?s)Can''t reach the Yard\. Retrying\.</div>`\);\s*b\.push\(\.\.\.mainStatusBanners\(s\?\.mainStatus\)\);' -and (Get-Content (Join-Path $repo 'pass-app\public\main-status.js') -Raw) -notmatch 'data-css|style=')
    # red then green: the Board follows the file (no restart)
    @{ repo = 'C:\x\brain-monitor'; tower = 'brain-monitor'; state = 'green'; suites = @(); why = ''; since = [DateTime]::UtcNow.ToString('o'); sha = 'c' * 40; at = [DateTime]::UtcNow.ToString('o'); job = 'J211' } | ConvertTo-Json | Set-Content (Join-Path $msDir 'aaaaaaaaaaaa.json') -Encoding utf8
    Remove-Item (Join-Path $msDir 'cccccccccccc.json')
    $sMs2 = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'state: red then green, the next state read shows main green (no red Tower left)' (@($sMs2.mainStatus | Where-Object { $_.tower -eq 'brain-monitor' -and $_.state -eq 'green' -and $_.job -eq 'J211' }).Count -eq 1 -and -not @($sMs2.mainStatus | Where-Object { $_.state -ne 'green' }).Count)
    Remove-Item $msDir -Recurse -Force
    @(@{ rate = 0.5; leap = 1 }, @{ rate = 0.9; leap = 2; leapName = 'Measured and lean'; trendArrow = [string][char]0x2191 }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $root 'scoreboard.jsonl') -Encoding utf8
    $appjs = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'app.js: Live tab header shows rate, leap and trend arrow' ($appjs -match 's\.scoreboard' -and $appjs -match 'sb\.trendArrow' -and $appjs -match 'Evolution rate' -and $appjs -match 'Leap \$\{esc\(sb\.leap\)\}')
    $page = Invoke-WebRequest "$base/" -Headers $auth
    Check 'app page served with CSP' ($page.StatusCode -eq 200 -and ($page.Headers['Content-Security-Policy'] -join '') -match "script-src 'self'")
    Check 'path traversal blocked' ((Get-Code "$base/..%2f..%2fpass-key.txt" $auth) -in 400, 404)

    # live stream delivers state and events
    $hc = [Net.Http.HttpClient]::new(); $hc.Timeout = [TimeSpan]::FromSeconds(10); $hc.DefaultRequestHeaders.Add('Authorization', "Bearer $key")
    $stream = $hc.GetStreamAsync("$base/api/stream").GetAwaiter().GetResult(); $rd = [IO.StreamReader]::new($stream)
    $got = ''; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 8 -and $got -notmatch 'approval\.requested') { $got += $rd.ReadLine() + "`n" }
    Check 'stream sends state' ($got -match 'event: state')
    Check 'stream sends events' ($got -match 'event: event' -and $got -match 'approval.requested')
    $rd.Dispose(); $hc.Dispose()

    # actions
    function Act($body) { Invoke-RestMethod "$base/api/action" -Method Post -Headers $auth -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) }
    Check 'unknown action refused' (-not (Act @{ op = 'format' }).ok)
    Check 'bad job id refused' (-not (Act @{ op = 'approve'; id = 'J1; rm -rf' }).ok)
    Check 'bad recipe name refused' (-not (Act @{ op = 'cook'; recipe = '..\x'; vars = @{ question = 'q' } }).ok)
    Check 'nested recipe value refused' (-not (Act @{ op = 'cook'; recipe = 'research'; vars = @{ question = @{ a = 1 } } }).ok)
    $rb = Invoke-RestMethod "$base/api/recipes" -Headers $auth
    Check 'recipe book served' ($rb.ok -and @($rb.data.name) -contains 'improve')
    $ck = Act @{ op = 'cook'; recipe = 'research'; vars = @{ question = 'what is a cloche?' } }
    Check 'order a recipe from the phone (chef, not gated)' ($ck.ok -and $ck.data.job -match '^J\d+$' -and -not $ck.data.needsApproval)
    & $k kill -Id $ck.data.job | Out-Null
    $ck2 = Act @{ op = 'cook'; recipe = 'research'; vars = @{ question = 'q2'; cook = 'gemini'; private = 'yes' } }
    $st2 = (Get-Content "$root\jobs\$($ck2.data.job).json" -Raw | ConvertFrom-Json).steps[0].args
    Check 'order with a chosen cook and private' ($ck2.ok -and $st2.Supplier -eq 'gemini' -and $st2.Private -eq $true)
    & $k kill -Id $ck2.data.job | Out-Null
    Check 'bad cook name refused on wake' (-not (Act @{ op = 'wake'; name = 'x; rm' }).ok)
    '{"suppliers":{"gemini":{"status":"resting","why":"test","runs":3,"maxRuns":150,"windowHours":24}},"dailyBudgetUsd":9}' | Set-Content "$root\suppliers-board.json"
    $now = (Get-Date).ToUniversalTime().ToString('o')
    Add-Content -LiteralPath (Join-Path $root 'events.jsonl') -Value ('{"ts":"' + $now + '","type":"cost","job":"J1","supplier":"gemini","usd":0.5,"inputTokens":1200000,"outputTokens":50000,"cacheReadTokens":1000,"cacheWriteTokens":500}') -Encoding utf8
    $s3 = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'state shows the cooks and the budget from the kitchen' ($s3.cooks.gemini.status -eq 'resting' -and $s3.budget -eq 9)
    Check 'state includes token metrics (today and per cook window)' ($s3.tokensToday -eq 1251500 -and $s3.cooks.gemini.tokensToday -eq 1251500 -and $s3.cooks.gemini.tokensWindow -eq 1251500)
    $appJs = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'app.js shows pay-per-use secondary estimate' ($appJs -match 'about \$\{money\(s\.spent\)\} pay-per-use at current prices')
    $none = Act @{ op = 'approve-all'; items = @(@{ id = 'J2'; approval = 'A1' }, @{ id = 'J1; rm -rf'; approval = 'A1' }) }
    Check 'approve all: skips orders that are not waiting and drops bad ids' (-not $none.ok -and @($none.data.skipped) -contains 'J2' -and @($none.data.approved).Count -eq 0)
    Check 'approve all: an empty list is refused' (-not (Act @{ op = 'approve-all'; items = @() }).ok)
    $a1 = [string]@((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object id -eq 'J1')[0].approval.id
    Check 'approve all: a plain step gate (not a merge) is never batched' ($a1 -match '^A\d+$' -and -not (Act @{ op = 'approve-all'; items = @(@{ id = 'J1'; approval = $a1 }) }).ok)
    Check 'approve: a yes that does not name the ask is refused' (-not (Act @{ op = 'approve'; id = 'J1' }).ok)
    Check 'approve: a yes for another ask is refused' (-not (Act @{ op = 'approve'; id = 'J1'; approval = 'A99999' }).ok)
    $kOut = (& pwsh -NoProfile -File $k approve -Id J1 -ApprovalId A99999 2>&1 | Out-String)
    Check 'kitchen approve -ApprovalId: refuses an ask that is no longer current (under the state lock)' ($kOut -match 'now asks something else' -and @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object id -eq 'J1')[0].status -eq 'waiting-approval')
    Check 'sign off from the app works' ((Act @{ op = 'approve'; id = 'J1'; approval = $a1 }).ok)
    & $k watch -Seconds 20 -Quiet | Out-Null
    Check 'signed-off job cooked' ((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs[0].status -eq 'done')
    $log = Invoke-RestMethod "$base/api/log/J1" -Headers $auth
    Check 'job output readable' (($log.lines -join "`n") -match 'working 1/1')
    Check 'live switch on/off' ((Act @{ op = 'live-on' }).ok -and (Test-Path "$root\LIVE") -and (Act @{ op = 'live-off' }).ok -and -not (Test-Path "$root\LIVE"))
    Check 'actions are logged' ((Get-Content "$root\pass-actions.jsonl" -Raw) -match '"op":"approve"')

    # inspection gate: a merge gate's yes carries the sha of the diff Jordan looked at; a change since then is refused
    # its own scratch repo ($ir): the merge-gate section further down creates $gr only when it is absent
    $ir = "$root-inspect-repo"; New-Item -ItemType Directory -Force $ir | Out-Null
    function Git-In { & git -C $ir -c user.name=t -c user.email=t@example.com @args 2>&1 | Out-Null }
    # line endings are set by this repo, never by the machine's git config: Git for Windows puts core.autocrlf=true only in its system
    # config, which the kitchen sandbox (GIT_CONFIG_NOSYSTEM) and other machines lack. a.txt is written as LF bytes for the phone diff.
    Git-In init -q -b main; Git-In config core.autocrlf false; [IO.File]::WriteAllText("$ir\a.txt", "one`n"); Git-In add -A; Git-In commit -q -m base
    # an order added by hand gets a longer ask (script + args sha), so the merge gate is written the way the kitchen words a recipe's
    $mid = 'J980'; $mtext = 'inspect me: start step 1 of 1 (merge)'
    # the yes is answered in the kitchen's approvals queue, so the ask must really be queued there (a made-up id has nothing to answer)
    $mq = (& (Join-Path $repo 'scripts\approvals.ps1') add -ApprovalsPath "$root\approvals.md" -Level HIGH -Text $mtext | Out-String)
    $mapp = [regex]::Match($mq, 'added (A\d+)').Groups[1].Value
    @{ id = $mid; name = 'inspect me'; status = 'waiting-approval'; cursor = 0; attempt = 0; created = (Get-Date).ToUniversalTime().ToString('o'); history = @();
       steps = @(@{ script = (Join-Path $repo 'kitchen\stations\merge.ps1'); args = @{ Repo = $ir } }); approval = @{ id = $mapp; text = $mtext; cursor = 0; attempt = 0; granted = $false; kind = 'gate' } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$mid.json") -Encoding utf8
    Git-In checkout -q -b "kitchen/$mid"; Set-Content "$ir\b.txt" 'two'; Git-In add -A; Git-In commit -q -m change1; Git-In checkout -q main
    $sha1 = [string](Invoke-RestMethod "$base/api/job/$mid" -Headers $auth).data.diffSha
    Check 'inspect: change carries a diffSha' ($sha1 -match '^[0-9a-f]{64}$')
    $miss = Act @{ op = 'approve'; id = $mid; approval = $mapp }
    Check 'inspect: a merge gate without a sha is refused' (-not $miss.ok -and $miss.error -match 'which change' -and (Get-Content "$root\jobs\$mid.json" -Raw | ConvertFrom-Json).status -eq 'waiting-approval')
    Git-In checkout -q "kitchen/$mid"; Set-Content "$ir\c.txt" 'three'; Git-In add -A; Git-In commit -q -m change2; Git-In checkout -q main
    $old = Act @{ op = 'approve'; id = $mid; approval = $mapp; diffSha = $sha1 }
    Check 'inspect: a changed worktree refuses the old sha' (-not $old.ok -and $old.error -match 'changed since' -and (Get-Content "$root\jobs\$mid.json" -Raw | ConvertFrom-Json).status -eq 'waiting-approval')
    $sha2 = [string](Invoke-RestMethod "$base/api/job/$mid" -Headers $auth).data.diffSha
    Check 'inspect: the new diff has its own sha' ($sha2 -match '^[0-9a-f]{64}$' -and $sha2 -ne $sha1)
    $aaMiss = Act @{ op = 'approve-all'; everything = $true; items = @(@{ id = $mid; approval = $mapp }) }
    $aaOld = Act @{ op = 'approve-all'; everything = $true; items = @(@{ id = $mid; approval = $mapp; diffSha = $sha1 }) }
    Check 'inspect: approve-all skips a missing or mismatched sha' (-not $aaMiss.ok -and -not $aaOld.ok -and @($aaMiss.data.skipped) -contains $mid -and @($aaOld.data.skipped) -contains $mid)
    $aaOk = Act @{ op = 'approve-all'; everything = $true; items = @(@{ id = $mid; approval = $mapp; diffSha = $sha2 }) }
    Check 'inspect: the matching diff sha is approved' ($aaOk.ok -and @($aaOk.data.approved) -contains $mid)
    & $k kill -Id $mid | Out-Null; Remove-Item (Join-Path $root "jobs\$mid.json") -Force   # fixtures go, so later orders keep their low ids
    # fail closed: a merge gate whose diff cannot be read (no kitchen/<id> branch) is refused, and the job keeps waiting
    $uid = 'J981'; $utext = 'inspect unreadable: start step 1 of 1 (merge)'
    $uq = (& (Join-Path $repo 'scripts\approvals.ps1') add -ApprovalsPath "$root\approvals.md" -Level HIGH -Text $utext | Out-String)
    $uapp = [regex]::Match($uq, 'added (A\d+)').Groups[1].Value
    @{ id = $uid; name = 'inspect unreadable'; status = 'waiting-approval'; cursor = 0; attempt = 0; created = (Get-Date).ToUniversalTime().ToString('o'); history = @();
       steps = @(@{ script = (Join-Path $repo 'kitchen\stations\merge.ps1'); args = @{ Repo = $ir } }); approval = @{ id = $uapp; text = $utext; cursor = 0; attempt = 0; granted = $false; kind = 'gate' } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$uid.json") -Encoding utf8
    $un = Act @{ op = 'approve'; id = $uid; approval = $uapp; diffSha = ('0' * 64) }
    $un2 = Act @{ op = 'approve'; id = $uid; approval = $uapp }
    Check 'inspect: unreadable diff (no branch) is refused for merge gates' (-not $un.ok -and -not $un2.ok -and (Get-Content "$root\jobs\$uid.json" -Raw | ConvertFrom-Json).status -eq 'waiting-approval')
    & $k kill -Id $uid | Out-Null; Remove-Item (Join-Path $root "jobs\$uid.json") -Force
    # a step gate has no diff: it still needs no sha
    & $k add -Name 'step gate' -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } -Approve | Out-Null
    for ($i = 0; $i -lt 3; $i++) { & $k tick -Quiet | Out-Null; Start-Sleep -Milliseconds 500 }
    $sg = @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object name -eq 'step gate')[0]
    Check 'inspect: a step gate still needs no diff sha' ($sg.approval.gate -eq 'step' -and (Act @{ op = 'approve'; id = $sg.id; approval = [string]$sg.approval.id }).ok)
    if ($sg.id) { & $k kill -Id $sg.id | Out-Null; Remove-Item (Join-Path $root "jobs\$($sg.id).json") -Force -ErrorAction SilentlyContinue }
    $ajs = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'inspect: app.js checklist shows tests, files, an unopened diff, and sends the sha' ($ajs -match 'const testCounts' -and $ajs -match 'Files modified' -and $ajs -match 'Diff not opened' -and $ajs -match 'Approve without reading' -and $ajs -match 'diffSha: sha')

    # Phone Diff (Chef 2.10.0): a merge gate's files from git with +/- counts and protected marks; one file's lines on a tap; private = names only
    $pdq = (& (Join-Path $repo 'scripts\approvals.ps1') add -ApprovalsPath "$root\approvals.md" -Level HIGH -Text 'phone diff: start step 1 of 1 (merge)' | Out-String)
    $pdapp = [regex]::Match($pdq, 'added (A\d+)').Groups[1].Value
    $pdGate = { param($id, $name, $priv) @{ id = $id; name = $name; status = 'waiting-approval'; cursor = 0; attempt = 0; created = (Get-Date).ToUniversalTime().ToString('o'); history = @(); vars = @{ private = $(if ($priv) { 'yes' } else { 'no' }) }
        steps = @(@{ script = (Join-Path $repo 'kitchen\stations\merge.ps1'); args = @{ Repo = $ir } }); approval = @{ id = $pdapp; text = "${name}: start step 1 of 1 (merge)"; cursor = 0; attempt = 0; granted = $false; kind = 'gate' } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$id.json") -Encoding utf8 }
    & $pdGate 'J982' 'phone diff' $false; & $pdGate 'J983' 'phone diff private' $true
    foreach ($pid_ in 'J982', 'J983') {
        Git-In checkout -q -b "kitchen/$pid_" main; New-Item -ItemType Directory -Force "$ir\kitchen" | Out-Null
        [IO.File]::WriteAllText("$ir\a.txt", "one`nadded line for $pid_`n"); Set-Content "$ir\kitchen\automerge.ps1" '# guardrail'; Set-Content "$ir\long.txt" ((1..2000 | ForEach-Object { "line $_" }) -join "`n")
        Git-In add -A; Git-In commit -q -m "change $pid_"; Git-In checkout -q main
    }
    $pdl = Invoke-RestMethod "$base/api/job/J982/diff" -Headers $auth
    $pdA = @($pdl.data.files | Where-Object path -eq 'a.txt')[0]
    Check 'phone diff: the gate lists its files with +/- counts' ($pdl.ok -and @($pdl.data.files).Count -eq 3 -and $pdA.add -eq 1 -and $pdA.del -eq 0 -and -not $pdl.data.private)
    Check 'phone diff: a protected file is marked (automerge.ps1 list), an ordinary one is not' (@($pdl.data.files | Where-Object path -eq 'kitchen/automerge.ps1')[0].protected -eq $true -and $pdA.protected -eq $false)
    Check 'phone diff: the list carries the same sha the yes is checked against' ($pdl.data.sha -match '^[0-9a-f]{64}$' -and $pdl.data.sha -eq [string](Invoke-RestMethod "$base/api/job/J982" -Headers $auth).data.diffSha)
    $pdf = Invoke-RestMethod "$base/api/job/J982/diff?file=a.txt" -Headers $auth
    Check "phone diff: one file's hunks, from its first @@, with the whole diff's sha" ($pdf.ok -and $pdf.data.hunks -match '^@@ ' -and $pdf.data.hunks -match '(?m)^\+added line for J982$' -and $pdf.data.hunks -notmatch 'diff --git' -and $pdf.data.sha -eq $pdl.data.sha -and -not $pdf.data.cut)
    $pdLong = Invoke-RestMethod "$base/api/job/J982/diff?file=long.txt" -Headers $auth
    Check 'phone diff: a long file is capped at 1500 lines and says so' ($pdLong.data.cut -eq $true -and @($pdLong.data.hunks -split "`n").Count -le 1500)
    Check 'phone diff: a file not in the change is 404, a bad name 400, no key 401' ((Get-Code "$base/api/job/J982/diff?file=nope.txt" $auth) -eq 404 -and (Get-Code "$base/api/job/J982/diff?file=" $auth) -eq 400 -and (Get-Code "$base/api/job/J982/diff") -eq 401)
    New-Item -ItemType Directory -Force "$root\worktrees\J983\.kitchen" | Out-Null; Set-Content "$root\worktrees\J983\.kitchen\DIFF.patch" -Value "diff --git a/a.txt b/a.txt`n+private words"
    $pdp = Invoke-RestMethod "$base/api/job/J983/diff" -Headers $auth
    Check 'phone diff: a private order shows file names only (no counts, no lines: 403)' ($pdp.data.private -eq $true -and @($pdp.data.files.path) -contains 'a.txt' -and @($pdp.data.files | Where-Object { $null -ne $_.add -or $null -ne $_.del }).Count -eq 0 -and (Get-Code "$base/api/job/J983/diff?file=a.txt" $auth) -eq 403)
    $pdc = (Invoke-RestMethod "$base/api/job/J983" -Headers $auth).data.change
    Check 'phone diff: a private order never sends its code in the job sheet (file names only)' ($pdc.private -eq $true -and @($pdc.files) -contains 'a.txt' -and -not $pdc.diff)
    Check 'phone diff: an order not at a merge gate is refused (409)' ((Get-Code "$base/api/job/J1/diff" $auth) -eq 409)
    foreach ($pid_ in 'J982', 'J983') { Remove-Item (Join-Path $root "jobs\$pid_.json") -Force; Git-In branch -q -D "kitchen/$pid_" }; Remove-Item "$root\worktrees\J983" -Recurse -Force

    # Proof Card (Chef 2.10.0): a plated order's receipt from the kitchen's records; a field with no record is null ("unknown" on screen)
    $pfBefore = (& git -C $ir rev-parse main).Trim(); Set-Content "$ir\proof.txt" 'landed'; Git-In add -A; Git-In commit -q -m landed; $pfAfter = (& git -C $ir rev-parse main).Trim()
    $made = (Get-Date).ToUniversalTime().AddMinutes(-12).ToString('o'); $doneAt = (Get-Date).ToUniversalTime().ToString('o')
    $pfSteps = @(@{ script = (Join-Path $repo 'kitchen\stations\tests.ps1'); args = @{} }, @{ script = (Join-Path $repo 'kitchen\agent-step.ps1'); args = @{ Role = 'check' } }, @{ script = (Join-Path $repo 'kitchen\stations\merge.ps1'); args = @{ Repo = $ir } })
    @{ id = 'J984'; name = 'proof me'; status = 'done'; cursor = 3; attempt = 0; created = $made; costUsd = 1.25; history = @(@{ step = 2; attempt = 0; outcome = 'done'; at = $doneAt }); steps = $pfSteps } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J984.json') -Encoding utf8
    @{ id = 'J985'; name = 'proof unknown'; status = 'done'; cursor = 2; attempt = 0; created = $made; history = @(@{ step = 1; attempt = 0; outcome = 'done'; at = $doneAt }); steps = @($pfSteps[0], @{ script = (Join-Path $repo 'kitchen\agent-step.ps1'); args = @{ Role = 'do' } }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J985.json') -Encoding utf8
    New-Item -ItemType Directory -Force "$root\run", "$root\results" | Out-Null
    Set-Content "$root\run\J984-s0-a0.log" "tests: PASS  Test-A                             A tests: 4 passed, 0 failed (1s)`ntests: PASS  Test-B                             B tests: 2 passed, 0 failed (1s)`ntests: -     Test-C                             not run (not impacted)`ntests: ALL PASS"
    Set-Content "$root\run\J984-s1-a0.log" "reading the diff`nVERDICT: SHIP"; Set-Content "$root\run\J984-s1-a0.cost.json" '{"supplier":"claude","model":"opus","usd":1.25}'
    Set-Content "$root\results\J984.tests.json" ('{"job":"J984","sha":"' + $pfAfter + '","final":"ALL PASS","flaky":[]}')
    Set-Content "$root\results\J984.merge.json" ('{"job":"J984","before":"' + $pfBefore + '","after":"' + $pfAfter + '","via":"github","at":"' + $doneAt + '"}')
    $pfx = (Invoke-RestMethod "$base/api/job/J984" -Headers $auth).data.proof
    Check 'proof: tests passed/failed/not run counted from the tests log, final line and flaky from the record' ($pfx.tests.pass -eq 2 -and $pfx.tests.fail -eq 0 -and $pfx.tests.notRun -eq 1 -and $pfx.tests.final -eq 'ALL PASS' -and @($pfx.tests.flaky).Count -eq 0 -and $pfx.tests.commit -eq $pfAfter)
    Check 'proof: who said SHIP (the taster verdict and its cook)' ($pfx.taster.step -and $pfx.taster.verdict -eq 'SHIP' -and $pfx.taster.by -eq 'claude opus')
    $landedSha = (& node -e "const{execFileSync:x}=require('child_process');process.stdout.write(require('crypto').createHash('sha256').update(x('git',['-C',process.argv[1],'-c','core.quotepath=off','diff','--no-renames',process.argv[2],process.argv[3]],{encoding:'utf8'})).digest('hex'))" $ir $pfBefore $pfAfter)
    Check 'proof: the landed diff sha (sha256 of git diff before..after) and where it merged' ($pfx.landed.diffSha -match '^[0-9a-f]{64}$' -and $pfx.landed.via -eq 'github' -and $pfx.landed.commit -eq $pfAfter -and $pfx.landed.diffSha -eq $landedSha)
    Check 'proof: cost and minutes' ($pfx.usd -eq 1.25 -and $pfx.minutes -ge 11.9 -and $pfx.minutes -le 12.2)
    $pu = (Invoke-RestMethod "$base/api/job/J985" -Headers $auth).data.proof
    Check 'proof: missing records are null (unknown), never guessed; no taster step is said as such' ($null -eq $pu.tests -and $pu.taster.step -eq $false -and $null -eq $pu.landed -and $null -eq $pu.usd -and $pu.minutes -gt 0)
    Check 'proof: only plated orders carry a proof card' ($null -eq (Invoke-RestMethod "$base/api/job/J2" -Headers $auth).data.proof)
    Remove-Item (Join-Path $root 'jobs\J984.json'), (Join-Path $root 'jobs\J985.json'), "$root\run\J984-*", "$root\results\J984.*" -Force
    $pdJs = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw; $pdCss = Get-Content (Join-Path $repo 'pass-app\public\app.css') -Raw
    Check 'proof card + phone diff in app.js: unknown shown, lines set with textContent, wrapped (no sideways scroll), the yes sends the listed sha' ($pdJs -match "const UNK = '<span class=""unk"">unknown</span>'" -and $pdJs -match 'proofHtml\(j\.proof\)' -and $pdJs -match 'tx\.textContent = ' -and $pdJs -match 'const sha = pd\?\.sha \|\| det\?\.diffSha' -and $pdCss -match '\.pd-t\{white-space:pre-wrap;overflow-wrap:anywhere')

    # job detail, output per run, audit, history, health
    $jd = Invoke-RestMethod "$base/api/job/J1" -Headers $auth
    Check 'job detail: steps with runs and receipts' ($jd.ok -and @($jd.data.steps).Count -eq 1 -and @($jd.data.steps[0].runs).Count -ge 1 -and $jd.data.steps[0].runs[0].exit -eq 0 -and $jd.data.steps[0].state -eq 'done')
    Check 'job detail: unknown job 404, bad id 400' ((Get-Code "$base/api/job/J999" $auth) -eq 404 -and (Get-Code "$base/api/job/x1" $auth) -eq 400)
    $lr = Invoke-RestMethod "$base/api/log/J1?run=J1-s0-a0" -Headers $auth
    Check 'output of one exact run' ($lr.ok -and $lr.run -eq 'J1-s0-a0' -and ($lr.lines -join "`n") -match 'working 1/1')
    Check 'run id must belong to the job' ((Get-Code "$base/api/log/J1?run=J2-s0-a0" $auth) -eq 400 -and (Get-Code "$base/api/log/J1?run=..%2f" $auth) -eq 400)
    $au = Invoke-RestMethod "$base/api/audit" -Headers $auth
    Check 'audit trail lists actions, newest first' ($au.ok -and @($au.data | Where-Object { $_.op -eq 'approve' }).Count -ge 1 -and $au.data[0].ts -ge $au.data[-1].ts)
    Check 'audit trail needs the key' ((Get-Code "$base/api/audit") -eq 401)
    $ev = Invoke-RestMethod "$base/api/events?n=50" -Headers $auth
    Check 'event history for the feed' ($ev.ok -and @($ev.data).Count -ge 3)
    Check 'health check is open and shows no data' ((Invoke-RestMethod "$base/api/health").ok -and -not ((Invoke-WebRequest "$base/api/health").Content -match 'job'))
    $rc = Invoke-RestMethod "$base/api/recipes" -Headers $auth
    Check 'recipe book has every variable with its rules' (($rc.data | Where-Object name -eq 'improve').vars.Count -eq 3 -and @(($rc.data | Where-Object name -eq 'improve').vars.name) -contains 'github' -and (($rc.data | Where-Object name -eq 'improve').vars | Where-Object name -eq 'goal').required)

    # requeue a set-aside job
    & $k add -Name broken -Script $w -ScriptArgs @{ Behavior = 'fail'; Seconds = 1 } -Retries 0 | Out-Null
    & $k watch -Seconds 20 -BreakerMin 99 -Quiet | Out-Null
    $bid = (@((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object name -eq 'broken'))[0].id
    Check 'broken job set aside' ((Invoke-RestMethod "$base/api/job/$bid" -Headers $auth).data.status -eq 'quarantined')
    Check 'requeue puts it back on the rail' ((Act @{ op = 'requeue'; id = $bid }).ok -and (Get-Content "$root\jobs\$bid.json" -Raw | ConvertFrom-Json).status -eq 'pending')
    Check 'requeue refuses a job that is not set aside' (-not (Act @{ op = 'requeue'; id = 'J1' }).ok)

    # requeue an old recipe order (> 12 hours) re-cooks from today's recipe
    $recOrder = Act @{ op = 'cook'; recipe = 'research'; vars = @{ question = 'what is a cloche?' } }
    $recId = $recOrder.data.job
    & $k kill -Id $recId | Out-Null
    $recFile = Join-Path $root "jobs\$recId.json"
    $recJ = Get-Content $recFile -Raw | ConvertFrom-Json -AsHashtable
    $recJ.status = 'quarantined'
    $recJ.created = (Get-Date).AddHours(-13).ToUniversalTime().ToString('o')
    $recJ | ConvertTo-Json -Depth 12 | Set-Content $recFile -Encoding utf8

    $recDetail = (Invoke-RestMethod "$base/api/job/$recId" -Headers $auth).data
    Check 'job detail returns recipe and created' ($recDetail.recipe -eq 'research' -and $recDetail.created)

    $recRequeue = Act @{ op = 'requeue'; id = $recId }
    Check 'requeue on old recipe order succeeds and reorders' ($recRequeue.ok -and $recRequeue.data.reordered -and $recRequeue.data.job -match '^J\d+$' -and $recRequeue.data.job -ne $recId)
    $newRecId = $recRequeue.data.job
    $newRecJ = Get-Content (Join-Path $root "jobs\$newRecId.json") -Raw | ConvertFrom-Json
    Check 'old recipe job closed and replaced' ((Get-Content $recFile -Raw | ConvertFrom-Json).status -eq 'closed' -and (Get-Content $recFile -Raw | ConvertFrom-Json).replacedBy -eq $newRecId)
    Check 'new recipe job created with same recipe and vars' ($newRecJ.status -eq 'pending' -and $newRecJ.recipe -eq 'research' -and $newRecJ.vars.question -eq 'what is a cloche?')
    Check 'events has job.closed' ((Get-Content "$root\events.jsonl" -Raw) -match '"type":"job\.closed"')
    $appJs = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'app.js offers Order it again (current spec)' ($appJs -match 'Order it again \(current spec\)')
    & $k kill -Id $newRecId | Out-Null

    # sous chef preview (decides only)
    $pv = Invoke-RestMethod "$base/api/preview" -Method Post -Headers $auth -ContentType 'application/json' -Body '{"recipe":"ask","vars":{"question":"what is a cloche?"}}' -TimeoutSec 90
    Check 'preview returns the sous chef decision' ($pv.ok -and $pv.data.action -in 'cook', 'hold', 'wait' -and $pv.data.why)
    $pv2 = Invoke-RestMethod "$base/api/preview" -Method Post -Headers $auth -ContentType 'application/json' -Body '{"recipe":"ask","vars":{"question":"x","private":"yes"}}' -TimeoutSec 90
    Check 'preview honours private' ($pv2.ok -and $pv2.data.private)
    Check 'preview of a recipe that does not exist' (-not (Invoke-RestMethod "$base/api/preview" -Method Post -Headers $auth -ContentType 'application/json' -Body '{"recipe":"nope"}').ok)

    # hardening
    $big = Invoke-WebRequest "$base/api/action" -Method Post -Headers $auth -ContentType 'application/json' -Body ('{"op":"tick","pad":"' + ('x' * 70000) + '"}') -SkipHttpErrorCheck -TimeoutSec 15
    Check 'oversized body refused (413), never left hanging' ($big.StatusCode -eq 413)
    Check 'GET on an action is refused' ((Get-Code "$base/api/action" $auth) -eq 405)
    $hd = Invoke-WebRequest "$base/" -Headers $auth
    Check 'security headers' (($hd.Headers['Permissions-Policy'] -join '') -match 'camera=\(\)' -and ($hd.Headers['Cross-Origin-Opener-Policy'] -join '') -eq 'same-origin' -and ($hd.Headers['Content-Security-Policy'] -join '') -match "base-uri 'none'")
    Check 'server still up after bad requests' ((Invoke-RestMethod "$base/api/health").ok)
    $ch = Invoke-RestMethod "$base/api/cooks" -Headers $auth
    Check 'cook history: 7 days' ($ch.ok -and @($ch.data.days).Count -eq 7)
    Check 'offline shell (service worker) served' ((Get-Code "$base/sw.js" $auth) -eq 200)
    # every script, style and font in public/ is in the worker's SHELL (so /sprites.js keeps the pixel stage offline), derived from the folder
    $shell = if ((Get-Content (Join-Path $repo 'pass-app\public\sw.js') -Raw) -match 'const SHELL = \[([^\]]*)\]') { $Matches[1] } else { '' }
    $mustShell = @(Get-ChildItem (Join-Path $repo 'pass-app\public') -File | Where-Object { $_.Extension -in '.js', '.css', '.woff2' -and $_.Name -ne 'sw.js' } | ForEach-Object { "'/$($_.Name)'" })
    Check 'sw.js SHELL lists /sprites.js and every app script, style and font' ($shell.Contains("'/sprites.js'") -and @($mustShell | Where-Object { -not $shell.Contains($_) }).Count -eq 0)
    # a double tap runs once: three of the same action at the same moment -> one run, one audit line
    $before = @(Get-Content "$root\pass-actions.jsonl" | Where-Object { $_ -match '"op":"doctor"' }).Count
    $rs = 1..3 | ForEach-Object -Parallel { Invoke-RestMethod "$using:base/api/action" -Method Post -Headers $using:auth -ContentType 'application/json' -Body '{"op":"doctor"}' -TimeoutSec 90 } -ThrottleLimit 3
    $after = @(Get-Content "$root\pass-actions.jsonl" | Where-Object { $_ -match '"op":"doctor"' }).Count
    Check 'same action tapped 3 times at once runs once' (@($rs | Where-Object ok).Count -eq 3 -and @($rs | Where-Object duplicate).Count -eq 2 -and ($after - $before) -eq 1)
    $fr = Invoke-WebRequest "$base/jetbrains-mono.woff2" -Headers $auth
    Check 'mono font served from this PC as a font' ($fr.StatusCode -eq 200 -and ($fr.Headers['Content-Type'] -join '') -eq 'font/woff2')

    # the dish: the answer an AI step produced shows on the ticket
    New-Item -ItemType Directory -Force (Join-Path $root 'run') | Out-Null
    Set-Content (Join-Path $root 'run\J1-s0-a0.dish.md') "# Answer`n- point one" -Encoding utf8
    Set-Content (Join-Path $root 'run\J1-s0-a0.cost.json') '{"supplier":"antigravity","model":"claude-sonnet-5-5-medium","usd":0.01}'
    $dj = (Invoke-RestMethod "$base/api/job/J1" -Headers $auth).data
    Check 'ticket carries the dish and who cooked it' ($dj.dish.text -match '# Answer' -and $dj.dish.by -eq 'antigravity claude-sonnet-5-5-medium' -and $dj.dish.run -eq 'J1-s0-a0')

    # seamless updates
    $hl = Invoke-RestMethod "$base/api/health"
    $srvHash = (Get-FileHash (Join-Path $repo 'pass-app\server.mjs') -Algorithm SHA256).Hash.ToLower().Substring(0, 12)
    Check 'health names the app build and the server hash (for update.ps1)' ($hl.build -match '^[0-9a-f]{10}$' -and $hl.server -eq $srvHash)
    Check 'state carries the build (phones swap over when it changes)' ((Invoke-RestMethod "$base/api/state" -Headers $auth).build -eq $hl.build)
    $swr = Invoke-WebRequest "$base/sw.js" -Headers $auth
    Check 'service worker is stamped with the build (a new build replaces the old shell)' ($swr.Content -match "chef-shell-$($hl.build)" -and $swr.Content -notmatch '__BUILD__')
    $etag = ($swr.Headers['ETag'] -join '')
    $re = Invoke-WebRequest "$base/sw.js" -Headers ($auth + @{ 'If-None-Match' = $etag }) -SkipHttpErrorCheck
    Check 'unchanged app files answer 304 (cheap revalidation)' ($etag -and $re.StatusCode -eq 304 -and ($swr.Headers['Cache-Control'] -join '') -eq 'no-cache')
    $tsBye = (Invoke-WebRequest "$base/api/bye" -Method Post -Headers @{ 'Tailscale-User-Login' = 'chef@example.com'; Host = $tsHost } -SkipHttpErrorCheck).StatusCode
    Check 'restart notice needs the pass key and POST (a phone cannot send it)' ((Get-Code "$base/api/bye" $auth) -eq 403 -and $tsBye -eq 403)
    Check 'restart notice works for update.ps1' ((Invoke-RestMethod "$base/api/bye" -Method Post -Headers $auth).ok)
    $nonJson = Invoke-WebRequest "$base/api/action" -Method Post -Headers $auth -Body 'op=stop-all' -ContentType 'application/x-www-form-urlencoded' -SkipHttpErrorCheck
    Check 'form posts refused (no cross-site forms)' ($nonJson.StatusCode -eq 415)

    # talk: chats answered in the background; with AI cooks off and no local model here, the kitchen says nobody can take it
    function Talk($body) { Invoke-RestMethod "$base/api/talk" -Method Post -Headers $auth -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) }
    Check 'talk: no chats yet' ((Invoke-RestMethod "$base/api/talk" -Headers $auth).ok -and @((Invoke-RestMethod "$base/api/talk" -Headers $auth).data).Count -eq 0)
    Check 'talk: the app has a Talk tab and a message box' ($page.Content -match 'data-view="talk"' -and $page.Content -match 'id="talk-text"')
    $t1 = Talk @{ text = 'what is a closure in JavaScript? secret-words-xyz' }
    Check 'talk: a new chat starts as T1 and answers in the background' ($t1.ok -and $t1.thread -eq 'T1' -and $t1.pending)
    $t2 = Talk @{ thread = 'T1'; text = 'and again' }
    Check 'talk: one answer at a time per chat' (-not $t2.ok -and $t2.error -match 'still answering')
    for ($i = 0; $i -lt 90; $i++) { $th = (Invoke-RestMethod "$base/api/talk/T1" -Headers $auth).data; if (-not $th.busy -and @($th.messages).Count -ge 2) { break }; Start-Sleep -Milliseconds 500 }
    Check 'talk: the chat has your words and the kitchen''s answer' (@($th.messages).Count -eq 2 -and $th.messages[0].role -eq 'you' -and $th.messages[1].role -eq 'kitchen' -and $th.messages[1].text)
    Check 'talk: nothing was cooked with the AI cooks off' (-not $th.messages[1].cook -or $th.messages[1].cook -eq 'local')
    Check 'talk: listed with its title' ((Invoke-RestMethod "$base/api/talk" -Headers $auth).data[0].title -match 'closure')
    $threads = (Invoke-RestMethod "$base/api/talk" -Headers $auth).data
    Check 'talk: threads list includes lastCook field' ($threads[0].PSObject.Properties.Name -contains 'lastCook')
    Add-Content -LiteralPath (Join-Path $root 'talk\T1.jsonl') -Value '{"role":"kitchen","text":"done","cook":"gemini"}' -Encoding utf8
    Check 'talk: lastCook reflects the cook that answered last' ((Invoke-RestMethod "$base/api/talk" -Headers $auth).data[0].lastCook -eq 'gemini')
    Check 'talk: the audit trail notes the chat, never the words' ((Get-Content (Join-Path $root 'pass-actions.jsonl') -Raw) -match '"op":"talk"' -and (Get-Content (Join-Path $root 'pass-actions.jsonl') -Raw) -notmatch 'secret-words-xyz')
    Check 'talk: bad chat id 400, unknown chat 404' ((Get-Code "$base/api/talk/X1" $auth) -eq 400 -and (Get-Code "$base/api/talk/T99" $auth) -eq 404)
    Check 'talk: empty and over-long messages refused' (-not (Talk @{ text = '  ' }).ok -and -not (Talk @{ text = ('a' * 6001) }).ok -and -not (Talk @{ thread = '../x'; text = 'hi' }).ok)
    Check 'talk: needs the key' ((Get-Code "$base/api/talk") -eq 401)
    # chat privacy toggle: toggling lock on existing chat sets private: true, persists to disk, and keeps chat private
    $privResp = Talk @{ thread = 'T1'; text = 'keep this private'; private = $true }
    Check 'talk: toggle existing chat T1 to private accepted' ($privResp.ok -and $privResp.thread -eq 'T1')
    for ($i = 0; $i -lt 90; $i++) { $th = (Invoke-RestMethod "$base/api/talk/T1" -Headers $auth).data; if (-not $th.busy -and @($th.messages).Count -ge 5) { break }; Start-Sleep -Milliseconds 200 }
    $t1Meta = Get-Content (Join-Path $root 'talk\T1.json') -Raw | ConvertFrom-Json
    Check 'talk: T1 on disk has private true' ($t1Meta.private -eq $true)
    Check 'talk: API reports T1 private' ($th.private -eq $true)
    Check 'talk: private reply came from local cook or none' (-not $th.messages[-1].cook -or $th.messages[-1].cook -eq 'local')
    $privAgain = Talk @{ thread = 'T1'; text = 'stay private without flag' }
    Check 'talk: post to already-private chat accepted' ($privAgain.ok)
    for ($i = 0; $i -lt 90; $i++) { $th = (Invoke-RestMethod "$base/api/talk/T1" -Headers $auth).data; if (-not $th.busy -and @($th.messages).Count -ge 7) { break }; Start-Sleep -Milliseconds 200 }
    $t1MetaAfter = Get-Content (Join-Path $root 'talk\T1.json') -Raw | ConvertFrom-Json
    Check 'talk: already-private chat stays private without flag' ($t1MetaAfter.private -eq $true -and $th.private -eq $true)
    $t2Post = Talk @{ text = 'public chat question' }
    Check 'talk: new chat starts non-private without flag' ($t2Post.ok -and $t2Post.thread -eq 'T2')
    for ($i = 0; $i -lt 90; $i++) { $th2 = (Invoke-RestMethod "$base/api/talk/T2" -Headers $auth).data; if (-not $th2.busy -and @($th2.messages).Count -ge 2) { break }; Start-Sleep -Milliseconds 200 }
    $t2Meta = Get-Content (Join-Path $root 'talk\T2.json') -Raw | ConvertFrom-Json
    Check 'talk: non-private chat stays non-private' (-not $t2Meta.private -and -not $th2.private)
    $t2PrivResp = Talk @{ thread = 'T2'; text = 'make T2 private'; private = $true }
    Check 'talk: toggle existing chat T2 to private accepted' ($t2PrivResp.ok -and $t2PrivResp.thread -eq 'T2')
    for ($i = 0; $i -lt 90; $i++) { $th2 = (Invoke-RestMethod "$base/api/talk/T2" -Headers $auth).data; if (-not $th2.busy -and @($th2.messages).Count -ge 4) { break }; Start-Sleep -Milliseconds 200 }
    $t2MetaAfter = Get-Content (Join-Path $root 'talk\T2.json') -Raw | ConvertFrom-Json
    Check 'talk: existing chat toggled to private sends -Private and sets private true' ($t2MetaAfter.private -eq $true -and $th2.private -eq $true)
    $appjsContent = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'talk: app.js contains private: Boolean(S.talk.privateNext || S.talk.data?.private)' ($appjsContent -match 'private:\s*Boolean\(S\.talk\.privateNext\s*\|\|\s*S\.talk\.data\?\.private\)')
    Check 'talk: app.js resets privateNext on dispatch' ($appjsContent -match 'S\.talk\.privateNext\s*=\s*false')

    # job hunt
    function Hunt($body) { Invoke-RestMethod "$base/api/hunt" -Method Post -Headers $auth -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress -Depth 4) }
    $h0 = (Invoke-RestMethod "$base/api/hunt" -Headers $auth).data
    Check 'hunt: scout openings parsed (role, company, pay with a real dash, link)' (@($h0.openings.items).Count -eq 2 -and $h0.openings.items[0].company -eq 'Acme' -and $h0.openings.items[0].link -eq 'https://example.com/acme' -and $h0.openings.items[0].pay -match '–')
    $a1 = Hunt @{ op = 'add'; item = @{ company = 'Acme'; role = 'AI Engineer'; link = 'https://example.com/acme'; source = 'scout' } }
    Check 'hunt: save a role' ($a1.ok -and $a1.data.id -eq 'A1' -and $a1.data.status -eq 'saved')
    Check 'hunt: same link twice refused' (-not (Hunt @{ op = 'add'; item = @{ company = 'Acme'; role = 'x'; link = 'https://example.com/acme' } }).ok)
    Check 'hunt: needs company and role; link must be http' (-not (Hunt @{ op = 'add'; item = @{ role = 'x' } }).ok -and -not (Hunt @{ op = 'add'; item = @{ company = 'a'; role = 'b'; link = 'javascript:alert(1)' } }).ok)
    $u = Hunt @{ op = 'update'; id = 'A1'; change = @{ status = 'applied' } }
    Check 'hunt: applied sets today and a follow-up in 7 days' ($u.ok -and $u.data.appliedAt -eq (Get-Date -Format 'yyyy-MM-dd') -and $u.data.followUp -eq (Get-Date).AddDays(7).ToString('yyyy-MM-dd') -and $u.data.stage -eq 'initial')
    Check 'hunt: bad status and bad date refused' (-not (Hunt @{ op = 'update'; id = 'A1'; change = @{ status = 'hired!' } }).ok -and -not (Hunt @{ op = 'update'; id = 'A1'; change = @{ followUp = 'soon' } }).ok)
    Check 'hunt: unknown application refused' (-not (Hunt @{ op = 'update'; id = 'A9'; change = @{ notes = 'x' } }).ok)
    # tailored drafts: linked by job id, newest plain file in tailored/, never a path from the request
    New-Item -ItemType Directory -Force "$career\tailored" | Out-Null
    Set-Content "$career\tailored\J5-draft.md" "## Fit`nOld fit`n## Cover note`nOld cover" -Encoding utf8
    Set-Content "$career\tailored\J6-draft.md" "## Fit`nStrong match for Acme`n`n## Targeted bullets`n- Built things`n`n## Cover note`nDear Acme`n`n# Tailor check`n- Keyword coverage: 80.0% (4 of 5 posting terms)`n- Result: PASS" -Encoding utf8
    (Get-Item "$career\tailored\J5-draft.md").LastWriteTime = (Get-Date).AddHours(-2)
    Set-Content "$career\SECRET-marker.md" 'PLANTED-MARKER-TEXT' -Encoding utf8
    function Draft($id) { try { $r = Invoke-WebRequest "$base/api/hunt/draft/$id" -Headers $auth -SkipHttpErrorCheck -TimeoutSec 20; @{ code = $r.StatusCode; body = "$($r.Content)" } } catch { @{ code = -1; body = '' } } }
    Check 'draft: no draft linked yet is a 404' ((Draft 'A1').code -eq 404)
    Check 'draft: needs the key' ((Get-Code "$base/api/hunt/draft/A1") -eq 401)
    Check 'draft: a bad draft id is refused when linking' (-not (Hunt @{ op = 'update'; id = 'A1'; change = @{ draft = '..\..\SECRET-marker' } }).ok -and -not (Hunt @{ op = 'update'; id = 'A1'; change = @{ draft = 'J5.md' } }).ok)
    $null = Hunt @{ op = 'update'; id = 'A1'; change = @{ draft = 'J5' } }
    $null = Hunt @{ op = 'update'; id = 'A1'; change = @{ draft = 'J6' } }
    $dr = Draft 'A1'; $dj = $dr.body | ConvertFrom-Json
    Check 'draft: the newest linked draft is returned with its sections' ($dr.code -eq 200 -and $dj.data.job -eq 'J6' -and $dj.data.sections.fit -match 'Strong match' -and $dj.data.sections.bullets -match 'Built things' -and $dj.data.sections.cover -match 'Dear Acme')
    Check 'draft: the file path is never returned' ($dr.body -notmatch [regex]::Escape($career) -and $dr.body -notmatch 'tailored')
    Move-Item "$career\tailored\J6-draft.md" "$career\tailored\J6-draft.hold"; Move-Item "$career\tailored\J5-draft.md" "$career\tailored\J5-draft.hold"
    Check 'draft: linked drafts whose files are missing are a 404' ((Draft 'A1').code -eq 404)
    Move-Item "$career\tailored\J6-draft.hold" "$career\tailored\J6-draft.md"; Move-Item "$career\tailored\J5-draft.hold" "$career\tailored\J5-draft.md"
    Check 'draft: an unknown application is a 404' ((Draft 'A77').code -eq 404)
    $esc = @('..%2f..%2fSECRET-marker.md', 'J6', 'A1.md', 'A1%2f..%2fA1', '%zz', 'a1', '..')
    Check 'draft: escape attempts never return a file' (@($esc | Where-Object { $x = Draft $_; $x.code -eq 200 -or $x.body -match 'PLANTED-MARKER' }).Count -eq 0)
    $null = Hunt @{ op = 'update'; id = 'A1'; change = @{ followUp = (Get-Date -Format 'yyyy-MM-dd'); notes = 'called the recruiter' } }
    Check 'hunt: a follow-up due today shows on the pass' ((Invoke-RestMethod "$base/api/state" -Headers $auth).due -eq 1)
    Check 'hunt: saved to tracker.json in the career folder' ((Get-Content "$career\tracker.json" -Raw) -match 'called the recruiter')
    # auto-merge: the brief lists what merged on its own (and not what was undone); undo refuses a bad id
    Add-Content (Join-Path $root 'automerged.jsonl') ('{"at":"' + [DateTime]::UtcNow.ToString('o') + '","job":"J77","name":"improve: tidy","why":"tests all pass"}')
    Add-Content (Join-Path $root 'automerged.jsonl') ('{"at":"' + [DateTime]::UtcNow.ToString('o') + '","job":"J78","name":"improve: other","why":"tests all pass"}')
    Add-Content (Join-Path $root 'automerged.jsonl') ('{"at":"' + [DateTime]::UtcNow.ToString('o') + '","job":"J78","undone":"abc"}')
    $am = @((Invoke-RestMethod "$base/api/brief" -Headers $auth).data.autoMerged)
    Check 'brief: auto-merged changes listed, undone ones left out' ($am.Count -eq 1 -and $am[0].id -eq 'J77')
    Check 'undo-merge: a bad job id is refused' (-not (Act @{ op = 'undo-merge'; id = 'nope' }).ok)
    Check 'hunt: the brief leaves out saved roles' (@((Invoke-RestMethod "$base/api/brief" -Headers $auth).data.newRoles).Count -eq 1)
    $b = (Invoke-RestMethod "$base/api/brief" -Headers $auth).data
    Check 'brief: follow-ups, set aside, counts' (@($b.followUps).Count -eq 1 -and @($b.setAside | Where-Object { $_.name -eq 'flaky thing' }).Count -eq 1 -and $b.applied -eq 1)
    $a2 = Hunt @{ op = 'add'; item = @{ company = 'Beta'; role = 'Full Stack Dev'; link = 'https://example.com/beta'; source = 'scout'; status = 'applied' } }
    Check 'hunt: Mark applied adds a scout role as applied, today, follow-up in 7 days' ($a2.ok -and $a2.data.id -eq 'A2' -and $a2.data.status -eq 'applied' -and $a2.data.appliedAt -eq (Get-Date -Format 'yyyy-MM-dd') -and $a2.data.followUp -eq (Get-Date).AddDays(7).ToString('yyyy-MM-dd') -and $a2.data.stage -eq 'initial')
    $g = Hunt @{ op = 'add'; item = @{ company = 'Gamma'; role = 'Data Eng'; status = 'applied' } }
    $null = Hunt @{ op = 'update'; id = $g.data.id; change = @{ followUp = (Get-Date).AddDays(2).ToString('yyyy-MM-dd') } }
    $b2 = (Invoke-RestMethod "$base/api/brief" -Headers $auth).data
    $gu = @($b2.upcoming | Where-Object { $_.company -eq 'Gamma' })
    Check 'brief: an upcoming follow-up shows with in N days' ($gu.Count -eq 1 -and $gu[0].when -eq 'in 2 days' -and $gu[0].days -eq 2 -and @($b2.followUps).Count -eq 1 -and @($b2.followUps)[0].when -eq 'today' -and (Invoke-RestMethod "$base/api/state" -Headers $auth).due -eq 1)

    # application pack: queue pack job, fetch pdf and answers, check security and tracker
    $pk = Hunt @{ op = 'pack'; id = 'A1' }
    Check 'hunt: pack queues a job' ($pk.ok -and $pk.data.job -match '^J\d+$')
    & $k kill -Id $pk.data.job | Out-Null
    Check 'hunt: pack with bad id refused' (-not (Hunt @{ op = 'pack'; id = 'X99' }).ok)
    Check 'hunt: pack for unknown role refused' (-not (Hunt @{ op = 'pack'; id = 'A99' }).ok)

    New-Item -ItemType Directory -Force "$career\packs" | Out-Null
    Set-Content "$career\packs\A1-resume.pdf" "%PDF-1.4 test resume pdf content" -Encoding utf8
    Set-Content "$career\packs\A1-answers.md" "# Answers`n1. Verified automation background." -Encoding utf8

    $pdfResp = Invoke-WebRequest "$base/api/hunt/pdf?id=A1" -Headers $auth
    Check 'hunt: GET pdf returns 200 and application/pdf' ($pdfResp.StatusCode -eq 200 -and ($pdfResp.Headers['Content-Type'] -join '') -eq 'application/pdf' -and ($pdfResp.Headers['Content-Disposition'] -join '') -eq 'inline')
    Check 'hunt: GET pdf missing returns 404' ((Get-Code "$base/api/hunt/pdf?id=A99" $auth) -eq 404)
    Check 'hunt: GET pdf path traversal rejected' ((Get-Code "$base/api/hunt/pdf?id=..%2f..%2f" $auth) -eq 400)
    Check 'hunt: GET pdf unauthenticated rejected' ((Get-Code "$base/api/hunt/pdf?id=A1") -eq 401)

    $ansResp = Invoke-RestMethod "$base/api/hunt/answers?id=A1" -Headers $auth
    Check 'hunt: GET answers returns answers' ($ansResp.ok -and $ansResp.data.answers -match 'Verified automation background')
    Check 'hunt: GET answers missing returns 404' ((Get-Code "$base/api/hunt/answers?id=A99" $auth) -eq 404)
    Check 'hunt: GET answers path traversal rejected' ((Get-Code "$base/api/hunt/answers?id=..%2f..%2f" $auth) -eq 400)
    Check 'hunt: GET answers unauthenticated rejected' ((Get-Code "$base/api/hunt/answers?id=A1") -eq 401)

    # update tracker to reflect pack.ready
    $tr = Get-Content "$career\tracker.json" -Raw | ConvertFrom-Json -AsHashtable
    $tr.items[0].pack = @{ ready = $true; pdf = 'packs/A1-resume.pdf'; answers = 'packs/A1-answers.md' }
    $tr | ConvertTo-Json -Depth 6 | Set-Content "$career\tracker.json" -Encoding utf8
    $hAfter = (Invoke-RestMethod "$base/api/hunt" -Headers $auth).data
    Check 'hunt: tracker reflects pack.ready' ($hAfter.items[0].pack.ready -eq $true)
    $appJs = (Invoke-WebRequest "$base/app.js" -Headers $auth).Content
    Check 'hunt: app.js contains Pack ready and pack actions' ($appJs -match 'Pack ready' -and $appJs -match 'data-pack-app' -and $appJs -match 'data-copy-answers')
    # apply packet: listing, review data, the one-tap route's refusals, a fake auto-fill (PASS_APPLY_FILL) for fill and submit
    $ap = Hunt @{ op = 'add'; item = @{ company = 'Packet Co'; role = 'Agent Dev'; link = 'https://example.com/packet'; status = 'saved' } }
    $apId = $ap.data.id; $pd = "$career\packets\$apId"; New-Item -ItemType Directory -Force $pd | Out-Null
    function PacketHash { $sha = [Security.Cryptography.SHA256]::Create(); foreach ($f in 'answers.json', 'cover.txt', 'link.txt', 'resume.pdf') { $b = [IO.File]::ReadAllBytes("$pd\$f"); [void]$sha.TransformBlock($b, 0, $b.Length, $null, 0) }; [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0); ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant() }
    function Answers($list) { [IO.File]::WriteAllText("$pd\answers.json", (ConvertTo-Json -InputObject @($list) -Depth 5)) }
    $xss = '<img src=x onerror=alert(1)>'
    Answers @(@{ question = "Why us? $xss"; name = 'q1'; type = 'textarea'; required = $true; answer = "Because $xss"; source = 'resume'; needsJordan = $false; note = '' },
        @{ question = 'Salary?'; name = 'q2'; type = 'input_text'; required = $true; answer = ''; source = 'jordan'; needsJordan = $true; note = 'add salaryExpectation to profile.json' })
    [IO.File]::WriteAllText("$pd\cover.txt", "Hello Packet Co team,`n$xss"); [IO.File]::WriteAllText("$pd\link.txt", 'https://example.com/packet'); [IO.File]::WriteAllText("$pd\resume.pdf", '%PDF-1.4 locked')
    # the locked resume and its source, as apply-prep leaves them; packet.json records what the answers were drawn from
    function Sha($p) { if (Test-Path -LiteralPath $p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' } }
    [IO.File]::WriteAllText("$career\MASTER_RESUME.md", "# Test Resume`n- built things`n"); [IO.File]::WriteAllText("$career\resume-locked.pdf", '%PDF-1.4 locked')
    @{ sourceSha256 = (Sha "$career\MASTER_RESUME.md") } | ConvertTo-Json | Set-Content "$career\resume-locked.json" -Encoding utf8
    function FreshMeta { @{ id = $apId; company = 'Packet Co'; role = 'Agent Dev'; hash = 'stale-not-trusted'; profileHash = (Sha "$career\profile.json"); resumeSha256 = (Sha "$career\resume-locked.pdf"); resumeSourceSha256 = (Sha "$career\MASTER_RESUME.md") } | ConvertTo-Json | Set-Content "$pd\packet.json" -Encoding utf8 }
    FreshMeta
    Check 'packet: listed in /api/hunt' (@((Invoke-RestMethod "$base/api/hunt" -Headers $auth).data.packets) -contains $apId)
    $pv = (Invoke-RestMethod "$base/api/hunt/packet?id=$apId" -Headers $auth).data
    Check 'packet: review data with the hash recomputed from the files (not packet.json)' ($pv.hash -eq (PacketHash) -and $pv.company -eq 'Packet Co' -and @($pv.answers).Count -eq 2 -and $pv.missingRequired -eq 1 -and $pv.filler -eq $false -and $pv.resumeName -eq 'resume.pdf' -and @($pv.stale).Count -eq 0)
    Check 'packet: needs the key; bad id 400; no packet 404' ((Get-Code "$base/api/hunt/packet?id=$apId") -eq 401 -and (Get-Code "$base/api/hunt/packet?id=..%2fA1" $auth) -eq 400 -and (Get-Code "$base/api/hunt/packet?id=A1" $auth) -eq 404)
    $dl = Invoke-WebRequest "$base/api/hunt/packet/pdf?id=$apId" -Headers $auth
    Check 'packet: resume PDF downloads as an attachment' ($dl.StatusCode -eq 200 -and ($dl.Headers['Content-Type'] -join '') -eq 'application/pdf' -and ($dl.Headers['Content-Disposition'] -join '') -match '^attachment')
    $appJs2 = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'packet: every packet value Chef shows goes through esc()' ($appJs2 -match 'esc\(a\.question\)' -and $appJs2 -match 'esc\(a\.answer\)' -and $appJs2 -match 'esc\(a\.note\)' -and $appJs2 -match 'esc\(pk\.cover\)' -and $appJs2 -match 'esc\(pk\.role\)' -and $appJs2 -match 'esc\(pk\.company\)' -and $appJs2 -match 'esc\(pk\.link\)' -and $appJs2 -notmatch '\$\{(a\.answer|a\.question|pk\.cover)\}')
    Check 'packet: copy buttons copy the raw text (no HTML round trip), amber You answer these, Fill and Mark applied' ($appJs2 -match 'clipboard\.writeText\(text\)' -and $appJs2 -match 'You answer these' -and $appJs2 -match 'data-apply-fill' -and $appJs2 -match "op: 'apply-submit', id, hash: pk\.hash" -and $appJs2 -match 'Mark applied' -and (Get-Content (Join-Path $repo 'pass-app\public\app.css') -Raw) -match '\.apply-you\{[^}]*var\(--amber\)')
    $noPk = Hunt @{ op = 'apply-fill'; id = 'A1' }
    Check 'apply-fill: refused for a role with no packet' (-not $noPk.ok -and $noPk.error -match 'no apply packet')
    $miss = Hunt @{ op = 'apply-fill'; id = $apId }
    Check 'apply-fill: auto-fill script missing -> not installed yet' (-not $miss.ok -and $miss.error -eq 'auto-fill not installed yet')
    Check 'apply-submit: refused when the packet changed since shown' ((Hunt @{ op = 'apply-submit'; id = $apId; hash = ('0' * 64) }).error -match 'changed since you looked')
    Check 'apply-submit: refused while a required answer is empty' ((Hunt @{ op = 'apply-submit'; id = $apId; hash = (PacketHash) }).error -match '1 required answer is still empty')
    Check 'apply-submit: bad id refused' (-not (Hunt @{ op = 'apply-submit'; id = 'A1;x'; hash = 'x' }).ok)

    # My answers: profile.json from the phone (profile-get / profile-save), never logged, never written over when unreadable
    $pf = "$career\profile.json"
    $g0 = Hunt @{ op = 'profile-get' }
    Check 'profile-get: no file yet -> every field empty, 21 fields, none filled' ($g0.ok -and $g0.data.exists -eq $false -and $g0.data.filled -eq 0 -and $g0.data.total -eq 21 -and $g0.data.fields.email -eq '' -and $g0.data.eeo.gender -eq '' -and $g0.data.hash -eq '')
    $mine = @{ name = 'Zed Quokka'; email = 'zq-secret@example.com'; phone = '+1 (555) 010-9999'; city = 'Boise'; state = 'ID'; country = 'USA'; linkedin = 'https://linkedin.com/in/zq'; github = 'https://github.com/zq'; website = ''
        workAuthorization = 'US citizen'; needsSponsorship = 'No'; salaryExpectation = '150000 quokka-pay'; earliestStart = 'Two weeks'; willingToRelocate = 'Yes'; remotePreference = 'Remote'; yearsExperience = '8'; howDidYouHear = 'Company website'
        eeo = @{ gender = 'Decline to self-identify'; race = 'Decline to self-identify'; veteran = 'I am not a protected veteran'; disability = 'Decline to self-identify' } }
    $s1 = Hunt @{ op = 'profile-save'; profile = $mine; hash = '' }
    $onDisk = Get-Content $pf -Raw | ConvertFrom-Json -AsHashtable
    Check 'profile-save: saved, and the file holds exactly what was sent' ($s1.ok -and $onDisk.email -eq 'zq-secret@example.com' -and $onDisk.needsSponsorship -eq 'No' -and $onDisk.eeo.veteran -eq 'I am not a protected veteran' -and $onDisk.website -eq '' -and -not (Get-ChildItem $career -Filter 'profile.json.tmp-*'))
    $g1 = Hunt @{ op = 'profile-get' }
    Check 'profile-get: round trip, 20 of 21 filled, hash of the file' ($g1.data.exists -and $g1.data.fields.phone -eq '+1 (555) 010-9999' -and $g1.data.fields.willingToRelocate -eq 'Yes' -and $g1.data.eeo.gender -eq 'Decline to self-identify' -and $g1.data.filled -eq 20 -and $g1.data.hash -eq (Sha $pf))
    $before = Get-Content $pf -Raw
    $bad = [ordered]@{ 'bad email' = @{ email = 'not-an-email' }; 'name too long' = @{ name = ('x' * 121) }; 'yes/no only' = @{ needsSponsorship = 'maybe' }; 'links only http(s)' = @{ linkedin = 'javascript:alert(1)' }
        'text only (no numbers or objects)' = @{ name = 5 }; 'phone shape' = @{ phone = 'call me <b>' }; 'years shape' = @{ yearsExperience = 'lots' }; 'control characters' = @{ city = "a`nb" }
        'unknown key' = @{ ssn = '123' }; 'unknown eeo key' = @{ eeo = @{ religion = 'x' } }; 'eeo must be an object' = @{ eeo = 'x' } }
    foreach ($bk in $bad.Keys) { $r = Hunt @{ op = 'profile-save'; profile = $bad[$bk] }; Check "profile-save refused: $bk" (-not $r.ok -and $r.error -and (Get-Content $pf -Raw) -eq $before) }
    Check 'profile-save: an unknown key is named in the refusal' ((Hunt @{ op = 'profile-save'; profile = @{ ssn = '123' } }).error -match 'unknown field: ssn')
    Check 'profile-save: no answers sent is refused' (-not (Hunt @{ op = 'profile-save' }).ok)
    Check 'profile-save: a stale hash (edited elsewhere) is refused' ((Hunt @{ op = 'profile-save'; profile = @{ city = 'Elsewhere' }; hash = ('0' * 64) }).error -match 'reload first' -and (Get-Content $pf -Raw) -eq $before)
    $s2 = Hunt @{ op = 'profile-save'; profile = @{ city = 'Meridian' }; hash = $g1.data.hash }
    $onDisk = Get-Content $pf -Raw | ConvertFrom-Json -AsHashtable
    Check 'profile-save: a partial save changes only that field; hand-added keys are kept' ($s2.ok -and $onDisk.city -eq 'Meridian' -and $onDisk.email -eq 'zq-secret@example.com' -and (Test-Path "$pf.bak"))
    $hand = $onDisk; $hand.myNote = 'kept'; [IO.File]::WriteAllText($pf, ($hand | ConvertTo-Json -Depth 4))
    $null = Hunt @{ op = 'profile-save'; profile = @{ state = 'Idaho' } }
    Check 'profile-save: a key Jordan added by hand on the PC survives a save' ((Get-Content $pf -Raw | ConvertFrom-Json).myNote -eq 'kept')
    $audit = Get-Content (Join-Path $root 'pass-actions.jsonl') -Raw
    Check 'profile: the audit trail holds only the op, never a value' ($audit -match '"op":"hunt-profile-save"' -and $audit -match '"op":"hunt-profile-get"' -and $audit -notmatch 'zq-secret|Quokka|quokka-pay|Meridian|010-9999|not-an-email|javascript:')
    $good = Get-Content $pf -Raw
    [IO.File]::WriteAllText($pf, '{ "name": "half a fi')
    $gu = Hunt @{ op = 'profile-get' }; $su = Hunt @{ op = 'profile-save'; profile = @{ city = 'X' } }
    Check 'profile: an unreadable profile.json is reported and never written over' (-not $gu.ok -and $gu.error -match 'not valid' -and -not $su.ok -and $su.error -match 'not valid' -and (Get-Content $pf -Raw) -eq '{ "name": "half a fi')
    [IO.File]::WriteAllText($pf, $good)
    # stale packets: answers drawn from an older profile or resume ask for Rebuild instead of being sent
    $pv = (Invoke-RestMethod "$base/api/hunt/packet?id=$apId" -Headers $auth).data
    Check 'stale: a profile edit marks the packet stale (profile)' (@($pv.stale) -contains 'profile' -and (Hunt @{ op = 'profile-get' }).data.stalePackets -ge 1)
    Check 'stale: fill and submit refused with Rebuild' ((Hunt @{ op = 'apply-fill'; id = $apId }).error -match 'older profile.*Rebuild' -and (Hunt @{ op = 'apply-submit'; id = $apId; hash = (PacketHash) }).error -match 'Rebuild')
    FreshMeta
    Check 'stale: a packet built from the current profile is not stale' (@((Invoke-RestMethod "$base/api/hunt/packet?id=$apId" -Headers $auth).data.stale).Count -eq 0)
    Add-Content "$career\MASTER_RESUME.md" '- an edit' -Encoding utf8
    Check 'stale: an edited resume source (not rendered yet) marks the packet stale (resume)' (@((Invoke-RestMethod "$base/api/hunt/packet?id=$apId" -Headers $auth).data.stale) -contains 'resume')
    [IO.File]::WriteAllText("$career\MASTER_RESUME.md", "# Test Resume`n- built things`n")
    [IO.File]::WriteAllText("$career\resume-locked.pdf", '%PDF-1.4 re-rendered')
    Check 'stale: a re-rendered locked resume marks the packet stale (resume)' (@((Invoke-RestMethod "$base/api/hunt/packet?id=$apId" -Headers $auth).data.stale) -contains 'resume')
    [IO.File]::WriteAllText("$career\resume-locked.pdf", '%PDF-1.4 locked'); FreshMeta
    $appJs3 = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'My answers screen: every field, labels, phone keyboards, esc() on values, Rebuild when stale' ($appJs3 -match "op: 'profile-save'" -and $appJs3 -match 'My answers' -and $appJs3 -match 'inputmode="email"' -and $appJs3 -match 'inputmode="tel"' -and $appJs3 -match 'inputmode="url"' -and $appJs3 -match 'type="\$\{type\}"' -and $appJs3 -match "'email', 'Email', 'email'" -and $appJs3 -match "'phone', 'Phone', 'tel'" -and $appJs3 -match '<label class="hunt-field ans-field" for="ans-' -and $appJs3 -match 'inputmode="numeric"' -and $appJs3 -match 'Decline to self-identify' -and $appJs3 -match 'value="\$\{esc\(' -and $appJs3 -match 'pk\.stale' -and @('workAuthorization', 'needsSponsorship', 'salaryExpectation', 'earliestStart', 'willingToRelocate', 'remotePreference', 'yearsExperience', 'howDidYouHear', 'linkedin', 'disability' | Where-Object { $appJs3 -notmatch $_ }).Count -eq 0)
    Answers @(@{ question = 'Why us?'; name = 'q1'; type = 'textarea'; required = $true; answer = 'Because'; source = 'resume'; needsJordan = $false },
        @{ question = 'Salary?'; name = 'q2'; type = 'input_text'; required = $true; answer = '150000'; source = 'profile'; needsJordan = $false })
    Check 'apply-submit: script missing -> not installed yet (after the other checks pass)' ((Hunt @{ op = 'apply-submit'; id = $apId; hash = (PacketHash) }).error -eq 'auto-fill not installed yet')
    # the fake auto-fill: records its arguments, then reports like the real one (last JSON line on stdout)
    $fillDir = Split-Path $env:PASS_APPLY_FILL; New-Item -ItemType Directory -Force $fillDir | Out-Null
    Set-Content "$fillDir\mode.txt" 'slow' -Encoding ascii
    Set-Content $env:PASS_APPLY_FILL @'
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';
const dir = path.dirname(fileURLToPath(import.meta.url)); const mode = fs.readFileSync(path.join(dir, 'mode.txt'), 'utf8').trim();
fs.writeFileSync(path.join(dir, 'args.txt'), process.argv.slice(2).join(' ') + '\n' + (process.env.PASS_CAREER_DIR || ''));
setTimeout(() => console.log(JSON.stringify(mode === 'submit' ? { result: 'applied', confirmation: 'CONF-123' } : { result: 'filled' })), mode === 'slow' ? 2500 : 10);
'@ -Encoding utf8
    $f1 = Hunt @{ op = 'apply-fill'; id = $apId }
    $f2 = Hunt @{ op = 'apply-fill'; id = $apId }
    Check 'apply-fill: starts the script detached and says so' ($f1.ok -and $f1.started -eq $true)
    Check 'apply-fill: one at a time' (-not $f2.ok -and $f2.error -match 'one at a time')
    for ($i = 0; $i -lt 40 -and -not (Test-Path "$fillDir\args.txt"); $i++) { Start-Sleep -Milliseconds 250 }   # node takes a moment to start
    $args1 = Get-Content "$fillDir\args.txt" -Raw -ErrorAction SilentlyContinue
    Check 'apply-fill: runs node apply-fill.mjs --item <id>, no --submit, with the career folder' ($args1 -match "^--item $apId\s*\r?\n" -and $args1 -notmatch 'submit' -and $args1 -match [regex]::Escape($career))
    for ($i = 0; $i -lt 40 -and ((Get-Content "$career\tracker.json" -Raw | ConvertFrom-Json).items | Where-Object { $_.id -eq $apId }).apply.state -ne 'filled'; $i++) { Start-Sleep -Milliseconds 250 }
    $row = (Get-Content "$career\tracker.json" -Raw | ConvertFrom-Json).items | Where-Object { $_.id -eq $apId }
    Check 'apply-fill: a fill-only run ends as filled and leaves the status alone' ($row.apply.state -eq 'filled' -and $row.status -eq 'saved')
    Set-Content "$fillDir\mode.txt" 'submit' -Encoding ascii
    $h = PacketHash; $sub = Hunt @{ op = 'apply-submit'; id = $apId; hash = $h }
    Check 'apply-submit: right hash, complete answers, script present -> started' ($sub.ok -and $sub.started -eq $true)
    for ($i = 0; $i -lt 40 -and ((Get-Content "$career\tracker.json" -Raw | ConvertFrom-Json).items | Where-Object { $_.id -eq $apId }).status -ne 'applied'; $i++) { Start-Sleep -Milliseconds 250 }
    $row = (Get-Content "$career\tracker.json" -Raw | ConvertFrom-Json).items | Where-Object { $_.id -eq $apId }
    Check 'apply-submit: passes --submit and the packet hash it was shown' ((Get-Content "$fillDir\args.txt" -Raw) -match "^--item $apId --submit --packet-hash $h")
    Check 'apply-submit: a confirmed submit marks applied, today, follow-up in 7 days, with the confirmation' ($row.status -eq 'applied' -and $row.appliedAt -eq (Get-Date -Format 'yyyy-MM-dd') -and $row.followUp -eq (Get-Date).AddDays(7).ToString('yyyy-MM-dd') -and $row.apply.state -eq 'applied' -and $row.apply.confirmation -eq 'CONF-123')
    Check 'apply-submit: never twice' ((Hunt @{ op = 'apply-submit'; id = $apId; hash = $h }).error -eq 'already applied')
    $pp = Hunt @{ op = 'apply-prep'; id = $apId }
    Check 'apply-prep: queues the private, local apply-prep recipe for that role' ($pp.ok -and $pp.data.job -match '^J\d+$' -and (Get-Content (Join-Path $root "jobs\$($pp.data.job).json") -Raw | ConvertFrom-Json).steps.Where({ $_.script -match 'agent-step' })[0].args.Supplier -eq 'local')
    if ($pp.data.job) { & $k kill -Id $pp.data.job | Out-Null }
    Check 'apply-prep: bad or unknown id refused' (-not (Hunt @{ op = 'apply-prep'; id = 'X1' }).ok -and -not (Hunt @{ op = 'apply-prep'; id = 'A999' }).ok)
    # brief ready packs reporting (Idea I62)
    $packApp = Hunt @{ op = 'add'; item = @{ company = 'Delta AI'; role = 'Agent Architect'; link = 'https://example.com/delta'; status = 'saved' } }
    $null = Hunt @{ op = 'update'; id = $packApp.data.id; change = @{ draft = 'J6' } }
    $bp = (Invoke-RestMethod "$base/api/brief" -Headers $auth).data
    Check 'brief: ready packs reported for saved role with draft' (@($bp.packs).Count -eq 1 -and $bp.packCount -eq 1 -and $bp.packs[0].company -eq 'Delta AI' -and $bp.packs[0].role -eq 'Agent Architect' -and $bp.packs[0].draft -eq 'J6' -and $bp.packs[0].link -eq 'https://example.com/delta')
    # A saved role without a draft is not counted in packs
    $noDraftApp = Hunt @{ op = 'add'; item = @{ company = 'Echo Inc'; role = 'Prompt Engineer'; link = 'https://example.com/echo'; status = 'saved' } }
    $bp2 = (Invoke-RestMethod "$base/api/brief" -Headers $auth).data
    Check 'brief: saved role without draft is not in packs' (@($bp2.packs).Count -eq 1 -and $bp2.packCount -eq 1)
    # Marking the pack role applied removes it from ready packs
    $null = Hunt @{ op = 'update'; id = $packApp.data.id; change = @{ status = 'applied' } }
    $bp3 = (Invoke-RestMethod "$base/api/brief" -Headers $auth).data
    Check 'brief: applied role is excluded from ready packs' (@($bp3.packs).Count -eq 0 -and $bp3.packCount -eq 0)
    # the taster's verdict: a draft that failed the tailor check is never shown as a ready pack
    Set-Content "$career\tailored\J8-draft.md" "## Summary`nx`n`n# Tailor check`n- Keyword coverage: 42.9% (3 of 7 posting terms)`n- Result: FAIL" -Encoding utf8
    $failApp = Hunt @{ op = 'add'; item = @{ company = 'Foxtrot'; role = 'Dev'; link = 'https://example.com/fox'; status = 'saved' } }
    $null = Hunt @{ op = 'update'; id = $failApp.data.id; change = @{ draft = 'J8' } }
    $bp4 = (Invoke-RestMethod "$base/api/brief" -Headers $auth).data
    Check 'brief: a draft that failed the tailor check is not a ready pack' (@($bp4.packs | Where-Object { $_.company -eq 'Foxtrot' }).Count -eq 0 -and @($bp4.packsNeedLook | Where-Object { $_.company -eq 'Foxtrot' -and $_.check -eq 'fail' -and $_.coverage -match '42\.9' }).Count -eq 1)
    $fd = (Draft $failApp.data.id).body | ConvertFrom-Json
    Check 'draft: the check verdict and its card are returned' ($fd.data.check -eq 'fail' -and $fd.data.sections.check -match 'Result: FAIL')

    # hunt inspect
    Check 'hunt: inspect non-existent app refused' (-not (Hunt @{ op = 'inspect'; id = 'A999' }).ok)
    $noLink = Hunt @{ op = 'add'; item = @{ company = 'NoLinkCorp'; role = 'Tester' } }
    Check 'hunt: inspect without link refused' (-not (Hunt @{ op = 'inspect'; id = $noLink.data.id }).ok)
    $inspUnknown = Hunt @{ op = 'inspect'; id = 'A1' }
    Check 'hunt: inspect unknown site returns not supported' (-not $inspUnknown.ok -and $inspUnknown.error -eq 'not supported')
    Set-Content (Join-Path $root 'ats-fixture.json') '{"title":"Backend Dev","company_name":"GreenCorp","content":"<p>Job text</p>","questions":[{"id":1,"name":"q1","label":"Why us?","required":true,"type":"textarea"}]}' -Encoding utf8
    $ghApp = Hunt @{ op = 'add'; item = @{ company = 'GreenCorp'; role = 'Backend Dev'; link = 'https://boards.greenhouse.io/greencorp/jobs/999' } }
    $inspOk = Hunt @{ op = 'inspect'; id = $ghApp.data.id }
    Check 'hunt: inspect saves description and questions' ($inspOk.ok -and $inspOk.data.description -eq 'Job text' -and @($inspOk.data.questions).Count -eq 1 -and $inspOk.data.questions[0].label -eq 'Why us?' -and $inspOk.data.questions[0].required -eq $true)
    Check 'hunt: tracker.json has description and questions on disk' ((Get-Content "$career\tracker.json" -Raw) -match 'Why us\?' -and (Get-Content "$career\tracker.json" -Raw) -match 'Job text')
    Remove-Item (Join-Path $root 'ats-fixture.json') -ErrorAction SilentlyContinue
    # hunt follow-up cadence: applied = first (+7) then final (+7, two touches); interview = thank-you (+1) then check-in (+7)
    $day = { param($n) (Get-Date).AddDays($n).ToString('yyyy-MM-dd') }
    $c1 = Hunt @{ op = 'add'; item = @{ company = 'CadenceCo'; role = 'Cadence Dev'; status = 'applied'; notes = 'sent resume' } }
    Check 'cadence: applied starts at the first follow-up, +7, no touches' ($c1.ok -and $c1.data.stage -eq 'initial' -and $c1.data.touches -eq 0 -and $c1.data.followUp -eq (& $day 7))
    $l1 = Hunt @{ op = 'follow-up'; id = $c1.data.id }
    Check 'cadence: first log moves to final, +7 from today, one touch' ($l1.ok -and $l1.data.stage -eq 'final' -and $l1.data.touches -eq 1 -and $l1.data.followUp -eq (& $day 7))
    Check 'cadence: the log is a timestamped note line, old notes kept' ($l1.data.notes -match '^sent resume\n\d{4}-\d{2}-\d{2} \d{2}:\d{2} First follow-up sent$')
    $l2 = Hunt @{ op = 'follow-up'; id = $c1.data.id; notes = "sent resume`nrecruiter is Sam" }
    Check 'cadence: second log finishes (done, date cleared, two touches); typed notes kept and the line appended' ($l2.ok -and $l2.data.stage -eq 'done' -and $l2.data.touches -eq 2 -and $l2.data.followUp -eq '' -and $l2.data.notes -match '^sent resume\nrecruiter is Sam\n\d{4}-\d{2}-\d{2} \d{2}:\d{2} Final follow-up sent$')
    $l3 = Hunt @{ op = 'follow-up'; id = $c1.data.id }
    Check 'cadence: a third touch is refused and changes nothing' (-not $l3.ok -and (@((Hunt @{ op = 'update'; id = $c1.data.id; change = @{ notes = $l2.data.notes } }).data.touches) -eq 2))
    $c2 = Hunt @{ op = 'add'; item = @{ company = 'CadenceCo'; role = 'Cadence Int' } }
    Check 'cadence: a saved job cannot log a follow-up' (-not (Hunt @{ op = 'follow-up'; id = $c2.data.id }).ok)
    $m = Hunt @{ op = 'update'; id = $c2.data.id; change = @{ status = 'interview' } }
    Check 'cadence: interviewing starts the thank-you note, +1 day' ($m.ok -and $m.data.stage -eq 'thanks' -and $m.data.followUp -eq (& $day 1))
    $t1 = Hunt @{ op = 'follow-up'; id = $c2.data.id }
    Check 'cadence: thank-you logged moves to the check-in, +7, note line added' ($t1.ok -and $t1.data.stage -eq 'checkin' -and $t1.data.followUp -eq (& $day 7) -and $t1.data.notes -match 'Thank-you note sent$')
    $t2 = Hunt @{ op = 'follow-up'; id = $c2.data.id }
    Check 'cadence: check-in logged finishes the cadence' ($t2.ok -and $t2.data.stage -eq 'done' -and $t2.data.followUp -eq '' -and $t2.data.notes -match 'Status check-in sent$')
    $c3 = Hunt @{ op = 'add'; item = @{ company = 'CadenceCo'; role = 'Cadence Own'; status = 'applied' } }
    $keep = & $day 3
    $o = Hunt @{ op = 'update'; id = $c3.data.id; change = @{ followUp = $keep } }
    $o2 = Hunt @{ op = 'update'; id = $c3.data.id; change = @{ status = 'interview'; followUp = $keep } }
    Check 'cadence: a date typed in by Jordan wins over the cadence date' ($o.ok -and $o2.ok -and $o2.data.followUp -eq $keep -and $o2.data.stage -eq 'thanks')
    $c4 = Hunt @{ op = 'add'; item = @{ company = 'CadenceCo'; role = 'Cadence Full'; status = 'applied'; notes = ('x' * 1990) } }
    $f = Hunt @{ op = 'follow-up'; id = $c4.data.id }
    Check 'cadence: full notes refuse the log rather than cut text' (-not $f.ok -and $f.error -match 'notes are full' -and (Hunt @{ op = 'update'; id = $c4.data.id; change = @{ status = 'applied' } }).data.touches -eq 0)
    Check 'cadence: unknown application refused' (-not (Hunt @{ op = 'follow-up'; id = 'A9999' }).ok)
    # an unreadable tracker is never treated as empty: the list says so, writes refuse, and the file is left byte-for-byte alone
    $goodT = [IO.File]::ReadAllText("$career\tracker.json")
    Check 'tracker: writes keep tracker.json.bak and leave no lock or temp file' ((Test-Path "$career\tracker.json.bak") -and -not (Test-Path "$career\tracker.json.lock") -and -not @(Get-ChildItem $career -Filter 'tracker.json.tmp*').Count)
    $badT = '{ "items": [ { "id": "A1", "status": "applied" } ' + "`n<<<<<<< HEAD`n"
    [IO.File]::WriteAllText("$career\tracker.json", $badT)
    $hb = Invoke-RestMethod "$base/api/hunt" -Headers $auth
    $addBad = Hunt @{ op = 'add'; item = @{ company = 'Wipe'; role = 'Wiper' } }
    $updBad = Hunt @{ op = 'update'; id = 'A1'; change = @{ notes = 'x' } }
    Check 'tracker unreadable: the list is an error, not an empty list' (-not $hb.ok -and $hb.error -match 'tracker\.json')
    Check 'tracker unreadable: add and update refuse; the file is untouched' (-not $addBad.ok -and -not $updBad.ok -and $addBad.error -match 'tracker\.json' -and [IO.File]::ReadAllText("$career\tracker.json") -eq $badT)
    [IO.File]::WriteAllText("$career\tracker.json", $goodT)
    # a crashed writer's stale lock is cleared; an edit made from an old copy (another phone) is refused
    Set-Content "$career\tracker.json.lock" 'old'; (Get-Item "$career\tracker.json.lock").LastWriteTime = (Get-Date).AddMinutes(-5)
    $afterStale = Hunt @{ op = 'update'; id = 'A1'; change = @{ notes = 'after a stale lock' } }
    Check 'tracker: a stale lock is cleared and the write goes through' ($afterStale.ok -and -not (Test-Path "$career\tracker.json.lock"))
    $staleEdit = Hunt @{ op = 'update'; id = 'A1'; changedAt = '2000-01-01T00:00:00.000Z'; change = @{ notes = 'from an old copy' } }
    Check 'tracker: an edit from an old copy is refused' (-not $staleEdit.ok -and $staleEdit.error -match 'another phone')
    Check 'cadence: the audit trail logs the action, never the note text' ((Get-Content (Join-Path $root 'pass-actions.jsonl') -Raw) -match '"op":"hunt-follow-up"' -and (Get-Content (Join-Path $root 'pass-actions.jsonl') -Raw) -notmatch 'recruiter is Sam')
    Check 'cadence: the app has a Log follow-up button wired to the follow-up action' ((Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw) -match 'data-log-fu' -and (Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw) -match "op: 'follow-up'" -and (Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw) -match 'Log follow-up')
    # fix what breaks
    $flaky = @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object { $_.name -eq 'flaky thing' })[0]
    Check 'fix: the failing job was set aside' ($flaky.status -eq 'quarantined')
    Check 'fix: only set-aside jobs get a diagnosis' (-not (Act @{ op = 'diagnose'; id = 'J1' }).ok)
    $dg = Act @{ op = 'diagnose'; id = $flaky.id }
    Check 'fix: Find the fix places a diagnosis order' ($dg.ok -and $dg.data.job -match '^J\d+$')
    $dj = (Invoke-RestMethod "$base/api/job/$($dg.data.job)" -Headers $auth).data
    Check 'fix: the diagnosis is read-only and carries the failure' ($dj.name -like "diagnose: $($flaky.id)*" -and $dj.steps[0].prompt -match 'flaky thing' -and $dj.steps[0].summary -notmatch 'Edit|Write')
    Check 'fix: the set-aside job links to its diagnosis' ((Invoke-RestMethod "$base/api/job/$($flaky.id)" -Headers $auth).data.diagnosis -eq $dg.data.job)
    Check 'fix: no diagnosis of a diagnosis' (-not (Act @{ op = 'diagnose'; id = $dg.data.job }).ok)
    New-Item -ItemType Directory -Force (Join-Path $root 'run') | Out-Null
    Set-Content (Join-Path $root "run\$($dg.data.job)-s0-a0.dish.md") "# What broke`nIt fails.`n`nFIX GOAL: make the flaky check retry once on a network error" -Encoding utf8
    Check 'fix: a diagnosis that ends in FIX GOAL offers it' ((Invoke-RestMethod "$base/api/job/$($dg.data.job)" -Headers $auth).data.fixGoal -eq 'make the flaky check retry once on a network error')

    # push alerts
    Check 'push: off by default; test refused while off' (-not (Invoke-RestMethod "$base/api/push" -Headers $auth).data.on -and -not (Act @{ op = 'push-test' }).ok)
    $po = Act @{ op = 'push-on' }
    Check 'push: on makes a random private topic' ($po.ok -and $po.data.topic -match '^chef-[0-9a-f]{24}$' -and (Invoke-RestMethod "$base/api/state" -Headers $auth).push)
    $null = Act @{ op = 'push-test' }; for ($i = 0; $i -lt 30 -and -not (Test-Path "$root-notify.txt"); $i++) { Start-Sleep -Milliseconds 300 }
    Check 'push: a test goes to that topic' ((Get-Content "$root-notify.txt" -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape("|$($po.data.topic)|Test from the Board"))
    & (Join-Path $repo 'kitchen\notify.ps1') -Level HIGH -Text 'J12 tailor: my secret resume words: needs your yes' | Out-Null
    $last = (Get-Content "$root-notify.txt" | Select-Object -Last 1)
    Check 'push: only the ticket and the kind of news leave the PC' ($last -eq "HIGH|$($po.data.topic)|J12 needs your sign-off")
    # the classifier knows the new words (Failed, Stop-work, sign-off) and still the old ones the callers write (RT-M11)
    $kinds = foreach ($kt in 'J13 Failed the tests: my secret words', 'J14 x quarantined after 3 attempts (last: fail)', 'Stop-work order: 9 of 10 steps failed', 'Circuit breaker open: 90% of the last 10 steps failed. No new work starts for 60s.', 'J15 my secret words: needs your sign-off', 'Chef update failed for J16: boom') {
        & (Join-Path $repo 'kitchen\notify.ps1') -Level HIGH -Text $kt | Out-Null; (Get-Content "$root-notify.txt" | Select-Object -Last 1) -replace '^HIGH\|[^|]+\|', '' }
    Check 'push: a text with Failed maps to the failed (set-aside) kind; quarantined still does' ($kinds[0] -eq 'J13 Failed; the Board has the details' -and $kinds[1] -eq 'J14 Failed; the Board has the details')
    Check 'push: a text with Stop-work maps to the breaker kind; breaker still does' ($kinds[2] -eq 'Kitchen: the kitchen paused new work (many failures)' -and $kinds[3] -eq $kinds[2])
    Check 'push: sign-off is a needs-you text; a lower-case "failed" keeps its old kind' ($kinds[4] -eq 'J15 needs your sign-off' -and $kinds[5] -eq 'Kitchen: something needs a look')
    Check 'push: off again' ((Act @{ op = 'push-off' }).ok -and -not (Invoke-RestMethod "$base/api/push" -Headers $auth).data.on)

    # auto-merge on the order page: the job detail says whether it merged on its own or was undone; 8pm push is a count only
    $nowAm = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($amId in 'J77', 'J78') {
        @{ id = $amId; name = 'improve: fixture'; recipe = 'improve'; status = 'done'; cursor = 1; attempt = 0; created = $nowAm; history = @();
            steps = @(@{ script = 'merge.ps1'; args = @{} }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$amId.json") -Encoding utf8
    }
    $d77 = (Invoke-RestMethod "$base/api/job/J77" -Headers $auth).data; $d78 = (Invoke-RestMethod "$base/api/job/J78" -Headers $auth).data
    Check 'automerge: job detail flags a change that merged on its own' ($d77.autoMerged -eq $true -and $d77.undone -eq $false)
    Check 'automerge: job detail flags an undone merge' ($d78.undone -eq $true -and $d78.autoMerged -eq $false)
    # the order's pull request: the kitchen's record (results\<id>.pr.json) becomes a small "PR #n" link, only ever to a github.com PR
    New-Item -ItemType Directory -Force (Join-Path $root 'results') | Out-Null
    @{ job = 'J77'; repo = 'JVonBorstel/brain-monitor'; number = 7; url = 'https://github.com/JVonBorstel/brain-monitor/pull/7' } | ConvertTo-Json | Set-Content (Join-Path $root 'results\J77.pr.json')
    @{ job = 'J78'; repo = 'x/y'; number = 8; url = 'javascript:alert(1)//github.com/x/y/pull/8' } | ConvertTo-Json | Set-Content (Join-Path $root 'results\J78.pr.json')
    $p77 = (Invoke-RestMethod "$base/api/job/J77" -Headers $auth).data.pr; $p78 = (Invoke-RestMethod "$base/api/job/J78" -Headers $auth).data.pr
    Check 'pr link: the job sheet gets the PR number and its github.com link' ($p77.number -eq 7 -and $p77.url -eq 'https://github.com/JVonBorstel/brain-monitor/pull/7')
    Check 'pr link: anything but a github.com PR page is dropped' ($null -eq $p78 -and $null -eq (Invoke-RestMethod "$base/api/job/J1" -Headers $auth).data.pr)
    $appJsPr = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'pr link: app.js shows "PR #n" opening github.com in a new tab, escaped' ($appJsPr -match 'const prLink = ' -and $appJsPr -match '\^https:\\/\\/github\\.com\\/' -and $appJsPr -match 'href="\$\{esc\(p\.url\)\}" target="_blank" rel="noopener noreferrer">PR #\$\{p\.number\}' -and $appJsPr -match '\$\{prLink\(j\.pr\)\}')
    Check 'automerge: push refused while push alerts are off' (-not (Act @{ op = 'push-automerge' }).ok)
    $null = Act @{ op = 'push-on' }; Remove-Item "$root-notify.txt" -ErrorAction SilentlyContinue
    $pa = Act @{ op = 'push-automerge' }
    for ($i = 0; $i -lt 30 -and -not (Test-Path "$root-notify.txt"); $i++) { Start-Sleep -Milliseconds 300 }
    $amLog = Get-Content "$root-notify.txt" -Raw -ErrorAction SilentlyContinue
    Check 'automerge: the push says how many, with no order titles' ($pa.ok -and $amLog -match '1 change merged on their own today' -and $amLog -notmatch 'fixture|tidy|improve')
    $null = Act @{ op = 'push-off' }

    # the dead-supervisor alarm: no tick for 10+ min -> ONE generic push (no content) and a stalled flag; Jordan's PAUSED marker silences it
    # the daily morning brief (server.mjs, 60 s timer after 8:00) also says "stopped ticking"; mark today's as sent so it cannot land in this window
    Set-Content (Join-Path $root 'brief-sent.txt') (Get-Date -Format 'yyyy-MM-dd') -NoNewline
    $supP = Join-Path $root 'supervisor.json'; $supKeep = Get-Content $supP -Raw -ErrorAction SilentlyContinue
    $sm = if ($supKeep) { $supKeep | ConvertFrom-Json -AsHashtable } else { @{} }; $sm.lastTick = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o'); $sm | ConvertTo-Json -Depth 8 | Set-Content $supP
    $null = Act @{ op = 'push-on' }; Remove-Item "$root-notify.txt" -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30 -and -not (Test-Path "$root-notify.txt"); $i++) { Start-Sleep -Milliseconds 300 }
    Start-Sleep 3   # more stall checks run: still one push
    $stLog = @(Get-Content "$root-notify.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -match 'stopped ticking' })
    Check 'stall: one generic push, nothing else in it' ($stLog.Count -eq 1 -and $stLog[0] -match '^HIGH\|[^|]+\|The Yard stopped ticking\. Open the Board\.$')
    Check 'stall: the pass shows it' ((Invoke-RestMethod "$base/api/state" -Headers $auth).stalled -eq $true)
    Set-Content (Join-Path $root 'PAUSED') 'test'; Start-Sleep 2
    $stP = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'stall: paused by Jordan is shown, not an alarm' ($stP.paused -eq $true -and $stP.stalled -eq $false -and -not (Test-Path (Join-Path $root 'stall-sent.txt')))
    Check 'stall: Resume removes the PAUSED marker' ((Act @{ op = 'kitchen-resume' }).ok -and -not (Test-Path (Join-Path $root 'PAUSED')))
    $appJsSt = (Invoke-WebRequest "$base/app.js" -Headers $auth).Content
    Check 'stall: app.js shows Paused by you and the stopped-ticking banner' ($appJsSt -match 'Paused by you' -and $appJsSt -match 'stopped ticking' -and $appJsSt -match 'data-set="kitchen-resume"')
    if ($supKeep) { Set-Content $supP $supKeep -NoNewline } else { Remove-Item $supP }
    Start-Sleep 2; $null = Act @{ op = 'push-off' }; Remove-Item (Join-Path $root 'stall-sent.txt') -ErrorAction SilentlyContinue
    $appJsAm =(Invoke-WebRequest "$base/app.js" -Headers $auth).Content
    Check 'automerge: app.js shows Merged on its own and an Undo button wired to undo-merge with a confirm' ($appJsAm -match 'Merged on its own' -and $appJsAm -match 'data-do="undo-merge"' -and $appJsAm -match "kind === 'undo-merge'" -and $appJsAm -match "op: 'undo-merge', id \}")
    Check 'automerge: activity feed has words for approval.auto and merge.undone' ($appJsAm -match "'approval\.auto'" -and $appJsAm -match 'merged on its own</b>' -and $appJsAm -match "'merge\.undone'")
    Check 'automerge: app.js only offers Undo on a done improve order that is not already undone' ($appJsAm -match "j\.status === 'done' && isImprove\(j\) && !j\.undone\) \? ``<button class=""btn"" data-do=""undo-merge""")
    Check 'automerge: app.js labels only improve orders that merged on their own' ($appJsAm -match "const isImprove = \(j\) => j\.recipe === 'improve' \|\| /\^improve:/i\.test\(j\.name \|\| ''\);" -and $appJsAm -match "j\.autoMerged && isImprove\(j\) \? 'Merged on its own · ' : ''" -and $appJsAm -match "j\.status === 'done' && isImprove\(j\) && j\.autoMerged \? '<p class=""why-line"">Merged on its own</p>' : ''")
    # a normal order is neither merged on its own nor undone
    $d1 = (Invoke-RestMethod "$base/api/job/J1" -Headers $auth).data
    Check 'automerge: a normal order is not flagged as merged on its own or undone' ($d1.autoMerged -eq $false -and $d1.undone -eq $false)
    # a real undo against a throwaway git repo: succeeds, flags the order undone and logs a merge.undone event
    $amRepo = Join-Path $root 'amrepo'
    New-Item -ItemType Directory -Force $amRepo | Out-Null
    $gitq = { param($a) & git -C $amRepo -c user.name=t -c user.email=t@localhost @a 2>&1 | Out-Null }
    & $gitq @('init', '-q', '-b', 'main'); Set-Content (Join-Path $amRepo 'a.txt') 'a'; & $gitq @('add', '-A'); & $gitq @('commit', '-q', '-m', 'base')
    $amMain = (& git -C $amRepo rev-parse --abbrev-ref HEAD).Trim()
    & $gitq @('checkout', '-q', '-b', 'kitchen/J79'); Set-Content (Join-Path $amRepo 'b.txt') 'b'; & $gitq @('add', '-A'); & $gitq @('commit', '-q', '-m', 'change')
    & $gitq @('checkout', '-q', $amMain); & $gitq @('merge', '--no-ff', '-q', '-m', 'Merge kitchen/J79 fixture', 'kitchen/J79')
    @{ id = 'J79'; name = 'improve: fixture undo'; recipe = 'improve'; status = 'done'; cursor = 1; attempt = 0; created = $nowAm; history = @();
        steps = @(@{ script = 'merge.ps1'; args = @{ Repo = $amRepo } }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J79.json') -Encoding utf8
    $evPath = Join-Path $root 'events.jsonl'
    $evBefore = if (Test-Path $evPath) { @(Get-Content $evPath | Where-Object { $_ -match '"merge\.undone"' }).Count } else { 0 }
    $ua = Act @{ op = 'undo-merge'; id = 'J79' }
    $evAfter = if (Test-Path $evPath) { @(Get-Content $evPath | Where-Object { $_ -match '"merge\.undone"' -and $_ -match '"J79"' }).Count } else { 0 }
    Check 'automerge: a successful undo reverts the merge and writes a merge.undone event' ($ua.ok -and $evAfter -eq 1 -and -not (Test-Path (Join-Path $amRepo 'b.txt')))
    Check 'automerge: a failed undo (already undone) writes no second event' ((-not (Act @{ op = 'undo-merge'; id = 'J79' }).ok) -and @(Get-Content $evPath | Where-Object { $_ -match '"merge\.undone"' -and $_ -match '"J79"' }).Count -eq 1)
    Check 'automerge: the undone order is flagged undone and no longer merged on its own' ((Invoke-RestMethod "$base/api/job/J79" -Headers $auth).data.undone -eq $true)
    Check 'TD-EH-10: a Board undo of an order that never went through GitHub writes no undoPushed (nothing to push)' (@(Get-Content $evPath | Where-Object { $_ -match '"merge\.undone"' -and $_ -match '"J79"' -and $_ -notmatch 'undoPushed' }).Count -eq 1)
    # TD-EH-10 / TD-EH-11 on the Board: the state carries each undo that is still only on this PC (<kitchen>\undo-unpushed\<job>.json) and
    # the auto-merge pause while it lasts (<kitchen>\automerge-paused.json); public/undo-pause.js turns them into banners
    $stE0 = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'TD-EH-10/11 state: nothing recorded = no undo banners and no pause' ($stE0.PSObject.Properties.Name -contains 'undoUnpushed' -and @($stE0.undoUnpushed).Count -eq 0 -and $stE0.PSObject.Properties.Name -contains 'automergePause' -and $null -eq $stE0.automergePause)
    $uuDir = Join-Path $root 'undo-unpushed'; New-Item -ItemType Directory -Force $uuDir | Out-Null
    $uuAt = [DateTime]::UtcNow.AddMinutes(-20).ToString('o')
    @{ job = 'J209'; tower = 'brain-monitor'; repo = (Join-Path $root 'no-such-tower'); slug = 'JVonBorstel/brain-monitor'; sha = 'a' * 40; at = $uuAt; why = 'GitHub could not be reached' } | ConvertTo-Json | Set-Content (Join-Path $uuDir 'J209.json') -Encoding utf8
    Set-Content (Join-Path $uuDir 'J210.json') '{ torn' -Encoding utf8
    $amUntil = [DateTime]::UtcNow.AddHours(20).ToString('o')
    @{ until = $amUntil; since = [DateTime]::UtcNow.AddHours(-4).ToString('o'); flaky = 2; suites = @('Test-PassApp', 'Test-Sandbox'); jobs = @('J211', 'J212'); at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $root 'automerge-paused.json') -Encoding utf8
    $stE = Invoke-RestMethod "$base/api/state" -Headers $auth
    $uu209 = @($stE.undoUnpushed | Where-Object { $_.job -eq 'J209' })[0]
    Check 'TD-EH-10 state: an unpushed undo comes through with its Tower, GitHub repo, reason and time; a torn record as unreadable' ($uu209.state -eq 'unpushed' -and $uu209.tower -eq 'brain-monitor' -and $uu209.slug -eq 'JVonBorstel/brain-monitor' -and $uu209.why -eq 'GitHub could not be reached' -and $null -ne $uu209.at -and @($stE.undoUnpushed | Where-Object { $_.job -eq 'J210' -and $_.state -eq 'unreadable' }).Count -eq 1 -and @($stE.undoUnpushed).Count -eq 2)
    Check 'TD-EH-11 state: the pause comes through with until, the count of flaky checks and the suites' ($null -ne $stE.automergePause -and $stE.automergePause.flaky -eq 2 -and (@($stE.automergePause.suites) -join ',') -eq 'Test-PassApp,Test-Sandbox' -and ([DateTime]$stE.automergePause.until).ToUniversalTime() -gt [DateTime]::UtcNow.AddHours(19))
    # "Check now" runs kitchen/undo-push-check.ps1: no proof that GitHub has the undo (here: its repository folder is not there) = kept, and said
    $chk = Act @{ op = 'undo-push-check' }
    Check 'TD-EH-10 Check now: the check runs and keeps what it cannot prove, saying why' ($chk.ok -and -not @($chk.data.cleared).Count -and @($chk.data.left | Where-Object { $_.job -eq 'J209' -and $_.why -eq 'its repository folder is not there' }).Count -eq 1 -and @($chk.data.left | Where-Object { $_.job -eq 'J210' -and $_.why -eq 'its record cannot be read' }).Count -eq 1 -and (Test-Path (Join-Path $uuDir 'J209.json')))
    # a pause that is over shows nothing
    @{ until = [DateTime]::UtcNow.AddMinutes(-1).ToString('o'); since = [DateTime]::UtcNow.AddHours(-25).ToString('o'); flaky = 1; suites = @('Test-X') } | ConvertTo-Json | Set-Content (Join-Path $root 'automerge-paused.json') -Encoding utf8
    Check 'TD-EH-11 state: a pause that is over is not shown' ($null -eq (Invoke-RestMethod "$base/api/state" -Headers $auth).automergePause)
    # TD-11: the chores' CI count (<kitchen>\ci-budget.json) reaches the state; an unknown count stays null (never 0); last month's file is not shown
    $cbP = Join-Path $root 'ci-budget.json'; $cbM = [DateTime]::UtcNow.ToString('yyyy-MM')
    @{ month = $cbM; at = [DateTime]::UtcNow.ToString('o'); monthEnds = [DateTime]::UtcNow.AddDays(5).ToString('o'); poolLimit = 2000; pool = @{ state = 'unknown'; minutesAtLeast = 1200 }; problems = @(); sites = @(@{ code = 'TD'; state = 'ok'; runs = 300; minutes = 1200; minutesAtLeast = 1200; budget = 1000; over = $true }, @{ code = 'GW'; state = 'unknown'; why = 'gh is not signed in'; runs = $null; minutes = $null; minutesAtLeast = $null; budget = 'unlimited'; over = $false }) } | ConvertTo-Json -Depth 5 | Set-Content $cbP -Encoding utf8
    # review #11 F2: no Sites registry = no "CI this month" banner, even with a file of this month on disk
    $cbKj = Join-Path $root 'kitchen.json'; $cbKj0 = if (Test-Path $cbKj) { Get-Content $cbKj -Raw } else { $null }
    $cbNoReg = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'CiBudget_NoRegistry: no Sites registry = no CI count in the state (no banner), though ci-budget.json is this month''s' ($cbNoReg.PSObject.Properties.Name -contains 'ciBudget' -and $null -eq $cbNoReg.ciBudget)
    $cbH = if ($cbKj0) { $cbKj0 | ConvertFrom-Json -AsHashtable } else { @{} }; $cbH.sites = @{ GW = @{}; TD = @{} }; $cbH | ConvertTo-Json -Depth 10 | Set-Content $cbKj -Encoding utf8
    $cbS = (Invoke-RestMethod "$base/api/state" -Headers $auth).ciBudget; $cbGw = @($cbS.sites | Where-Object { $_.code -eq 'GW' })[0]
    Check 'TD-11 state: per-Site runs, minutes, budget and over come through; unknown stays null with its reason' ($cbS.month -eq $cbM -and @($cbS.sites | Where-Object { $_.code -eq 'TD' -and $_.runs -eq 300 -and $_.minutes -eq 1200 -and $_.budget -eq 1000 -and $_.over }).Count -eq 1 -and $cbGw.state -eq 'unknown' -and $null -eq $cbGw.runs -and $null -eq $cbGw.minutes -and $cbGw.why -eq 'gh is not signed in' -and $cbGw.budget -eq 'unlimited')
    (Get-Content $cbP -Raw) -replace $cbM, '1999-01' | Set-Content $cbP -Encoding utf8
    Check 'TD-11 state: a count from another month is not shown' ($null -eq (Invoke-RestMethod "$base/api/state" -Headers $auth).ciBudget)
    Remove-Item $cbP
    if ($null -ne $cbKj0) { Set-Content $cbKj $cbKj0 -Encoding utf8 } else { Remove-Item $cbKj -Force }
    # the banner words (public/undo-pause.js, pure, run in node)
    $eIn = Join-Path $root 'eh1011-in.json'; @{ undo = @($stE.undoUnpushed); pause = $stE.automergePause } | ConvertTo-Json -Depth 6 | Set-Content $eIn -Encoding utf8
    $eMjs = Join-Path $root 'eh1011-banner.mjs'
    Set-Content $eMjs @"
import fs from 'node:fs';
import { undoPushBanners, autoMergePauseBanner } from '$(([Uri](Join-Path $repo 'pass-app\public\undo-pause.js')).AbsoluteUri)';
const v = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, ''));
const when = () => 'Fri 1:14 PM'; const p = v.pause;
console.log(JSON.stringify({ undo: undoPushBanners(v.undo, { when }), none: undoPushBanners(undefined), pause: autoMergePauseBanner(p, { when }),
  one: autoMergePauseBanner({ ...p, flaky: 1, suites: ['Test-A'] }, { when }), over: autoMergePauseBanner(p, { when, now: new Date(p.until).getTime() + 1 }), nopause: autoMergePauseBanner(null),
  escaped: undoPushBanners([{ job: 'J5', state: 'unpushed', tower: '<t>', slug: 'not a slug', why: '<b>x</b>', at: null }], { when }) }));
"@ -Encoding utf8
    $eOut = (& node $eMjs $eIn 2>$null | Out-String) | ConvertFrom-Json
    $eBtn = '<button class="btn" data-set="undo-push-check">Check now</button>'
    Check 'TD-EH-10 banner: "Undo not pushed: main on this PC is ahead of GitHub", the work order, when, why, what holds and what to do, in the existing banner style' (@($eOut.undo)[0] -eq ('<div class="banner" data-undo-push="J209">Undo not pushed: main on this PC is ahead of GitHub. Work order WO-0209 was undone here (Fri 1:14 PM), but not on GitHub: GitHub could not be reached. GitHub still has the change, and later merges into brain-monitor hold until main is pushed. What to do: on this PC, check that main has nothing private, then push main of brain-monitor to GitHub by hand (git push https://github.com/JVonBorstel/brain-monitor.git main). This goes away once GitHub has the undo.' + $eBtn + '</div>'))
    Check 'TD-EH-10 banner: a record that cannot be read is a banner too; none recorded = none' (@($eOut.undo).Count -eq 2 -and @($eOut.undo)[1] -eq ('<div class="banner" data-undo-push="unreadable">Undo not pushed: main on this PC may be ahead of GitHub. Work order WO-0210''s record cannot be read, so whether its undo reached GitHub is unknown.' + $eBtn + '</div>') -and @($eOut.none).Count -eq 0)
    Check 'TD-EH-10 banner: every value is escaped; a bad repo name gives no command' (@($eOut.escaped)[0] -match 'into &lt;t&gt; hold' -and @($eOut.escaped)[0] -match 'not on GitHub: &lt;b&gt;x&lt;/b&gt;\.' -and @($eOut.escaped)[0] -notmatch 'git push' -and @($eOut.escaped)[0] -match 'was undone here, but')
    Check 'TD-EH-11 banner: "Auto-merge paused until <time> after N flaky checks" naming the suites, the calm banner style' ($eOut.pause -eq '<div class="banner calm" data-automerge-pause>Auto-merge paused until Fri 1:14 PM after 2 flaky checks: Test-PassApp, Test-Sandbox. Each passed on main only on a retry, so AI changes wait for your sign-off until then.</div>')
    Check 'TD-EH-11 banner: one check reads "1 flaky check"; over or none = nothing' ($eOut.one -eq '<div class="banner calm" data-automerge-pause>Auto-merge paused until Fri 1:14 PM after 1 flaky check: Test-A. It passed on main only on a retry, so AI changes wait for your sign-off until then.</div>' -and $eOut.over -eq '' -and $eOut.nopause -eq '')
    $upSrc = Get-Content (Join-Path $repo 'pass-app\public\undo-pause.js') -Raw
    Check 'TD-EH-10/11 wiring: app.js imports public/undo-pause.js, shows both right after main status, Check now runs the check; no new style' ($app -match "import \{ undoPushBanners, autoMergePauseBanner \} from './undo-pause\.js'" -and $app -match '(?s)b\.push\(\.\.\.mainStatusBanners\(s\?\.mainStatus\)\);[^\n]*\r?\n\s*b\.push\(\.\.\.undoPushBanners\(s\?\.undoUnpushed\)\); const amp = autoMergePauseBanner\(s\?\.automergePause\); if \(amp\) b\.push\(amp\);' -and $app -match "a === 'undo-push-check'\) \{ const r = await act\(\{ op: 'undo-push-check' \}" -and $upSrc -notmatch 'style=|data-css|<style' -and @([regex]::Matches($upSrc, 'class="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin 'banner', 'banner calm', 'btn' }).Count -eq 0)
    Remove-Item $uuDir -Recurse -Force; Remove-Item (Join-Path $root 'automerge-paused.json') -Force

    # TD-8: per-Site stops on the Board. No Sites registry = no Site state and no Site taps; with one, the taps run kitchen.ps1 pause /
    # resume -Site (same sign-in as every action) and the state says which Sites are stopped and whose Stop-work order is open.
    $kjP = Join-Path $root 'kitchen.json'; $kj0 = if (Test-Path $kjP) { Get-Content $kjP -Raw } else { $null }
    $smP = Join-Path $root 'supervisor.json'; $sm0 = if (Test-Path $smP) { Get-Content $smP -Raw } else { $null }
    $smH = if ($sm0) { $sm0 | ConvertFrom-Json -AsHashtable } else { @{} }; $smH.siteBreakers = @{ TD = @{ tripped = $true; n = 1; openUntil = [DateTime]::UtcNow.AddMinutes(5).ToString('o') }; '?' = @{ tripped = $true; n = 1; openUntil = [DateTime]::UtcNow.AddMinutes(5).ToString('o') } }; $smH | ConvertTo-Json -Depth 10 | Set-Content $smP -Encoding utf8
    $ss0 = Invoke-RestMethod "$base/api/state" -Headers $auth
    $sp0 = Act @{ op = 'site-pause'; site = 'GW' }
    Check 'TD-8 state: no Sites registered = no Site stops (not even a left-over Unassigned one), and a Site tap is refused' ($ss0.PSObject.Properties.Name -contains 'siteStops' -and @($ss0.siteStops).Count -eq 0 -and -not $sp0.ok -and -not (Test-Path (Join-Path $root 'PAUSED-GW')))
    $kjH = if ($kj0) { $kj0 | ConvertFrom-Json -AsHashtable } else { @{} }; $kjH.sites = @{ GW = @{}; TD = @{} }; $kjH | ConvertTo-Json -Depth 10 | Set-Content $kjP -Encoding utf8
    $sp1 = Act @{ op = 'site-pause'; site = 'GW' }
    $ss1 = Invoke-RestMethod "$base/api/state" -Headers $auth
    $gw1 = @($ss1.siteStops | Where-Object code -eq 'GW')[0]; $td1 = @($ss1.siteStops | Where-Object code -eq 'TD')[0]; $un1 = @($ss1.siteStops | Where-Object code -eq '?')[0]
    Check 'SiteStop_Unassigned_State: with a registry, the open Stop-work order of work with no Site comes through as code ? (last, stopWork, until)' ($un1 -and $un1.stopWork -eq $true -and $un1.stopped -eq $false -and $null -ne $un1.stopWorkUntil -and @($ss1.siteStops)[-1].code -eq '?') { $ss1.siteStops | ConvertTo-Json -Compress }
    $spQ = Act @{ op = 'site-pause'; site = '?' }
    Check 'SiteStop_Unassigned_NoTap: ? is not a Site code a tap can stop' (-not $spQ.ok -and -not (Test-Path (Join-Path $root 'PAUSED-?')))
    Check 'TD-8 tap: Stop work on a Site writes PAUSED-<code> through kitchen.ps1 and logs it' ($sp1.ok -and (Test-Path (Join-Path $root 'PAUSED-GW')) -and -not (Test-Path (Join-Path $root 'PAUSED')) -and $sp1.data -match 'Site GW stopped' -and (Get-Content (Join-Path $root 'events.jsonl') -Raw) -match '"type":"site\.paused"[^\n]*"site":"GW"') { $sp1 | ConvertTo-Json -Compress }
    Check "TD-8 state: the stopped Site and the other Site's own Stop-work order come through" ($gw1.stopped -eq $true -and $gw1.stopWork -eq $false -and $td1.stopped -eq $false -and $td1.stopWork -eq $true -and $null -ne $td1.stopWorkUntil -and $ss1.paused -eq $false) { $ss1.siteStops | ConvertTo-Json -Compress }
    $spBad = Act @{ op = 'site-pause'; site = '-Action' }; $spUnk = Act @{ op = 'site-pause'; site = 'ZG' }
    $sr1 = Act @{ op = 'site-resume'; site = 'GW' }
    Check 'TD-8 tap: Resume lifts that Site only; a bad or unlisted code is refused' ($sr1.ok -and -not (Test-Path (Join-Path $root 'PAUSED-GW')) -and -not $spBad.ok -and -not $spUnk.ok -and -not (Test-Path (Join-Path $root 'PAUSED-ZG'))) { $sr1 | ConvertTo-Json -Compress }
    if ($null -ne $kj0) { Set-Content $kjP $kj0 -Encoding utf8 } else { Remove-Item $kjP -Force }
    if ($null -ne $sm0) { Set-Content $smP $sm0 -Encoding utf8 } else { Remove-Item $smP -Force }
    # the banner and row words (public/site-stop.js, pure, run in node)
    $sMjs = Join-Path $root 'td8-site-stop.mjs'
    Set-Content $sMjs @"
import { siteStopBanners, siteStopRows } from '$(([Uri](Join-Path $repo 'pass-app\public\site-stop.js')).AbsoluteUri)';
const when = () => '1:14 PM';
const items = [{ code: 'GW', stopped: true, stopWork: false }, { code: 'TD', stopped: false, stopWork: true, stopWorkUntil: '2026-10-24T20:14:00Z' }, { code: '<x>', stopped: true }];
const un = [{ code: 'GW', stopped: false, stopWork: false }, { code: '?', stopped: true, stopWork: true, stopWorkUntil: '2026-10-24T20:14:00Z' }];
console.log(JSON.stringify({ banners: siteStopBanners(items, { when }), rows: siteStopRows(items), none: siteStopBanners(undefined), norows: siteStopRows([]),
  un: siteStopBanners(un, { when }), unrows: siteStopRows(un), unclosed: siteStopBanners([{ code: '?', stopWork: false }]) }));
"@ -Encoding utf8
    $sOut = (& node $sMjs 2>$null | Out-String) | ConvertFrom-Json
    Check 'TD-8 banner: a Site stopped by you is a calm line with Resume; a Site''s Stop-work order says the other Sites carry on' (@($sOut.banners).Count -eq 2 -and @($sOut.banners)[0] -eq '<div class="banner calm" data-site-stop="GW">Site GW stopped by you: none of its new work starts. Its running work, the watchers and the other Sites carry on.<button class="btn" data-set="site-resume" data-site="GW">Resume GW</button></div>' -and @($sOut.banners)[1] -eq '<div class="banner" data-site-breaker="TD">Stop-work order on TD: most of its recent steps failed, so its new work waits until about 1:14 PM, then one trial step runs first. The other Sites carry on.</div>') { $sOut | ConvertTo-Json -Compress }
    Check 'SiteStop_Unassigned_Banner: an open Stop-work order on work with no Site is a banner (no tap); closed = nothing' (@($sOut.un).Count -eq 1 -and @($sOut.un)[0] -eq '<div class="banner" data-site-breaker="unassigned">Stop-work order on work with no Site: most of its recent steps failed, so new work with no Site waits until about 1:14 PM, then one trial step runs first. The Sites carry on.</div>' -and @($sOut.unclosed).Count -eq 0) { $sOut.un | ConvertTo-Json -Compress }
    Check 'SiteStop_Unassigned_Rows: no Stop or Resume row for work with no Site' ($sOut.unrows -match 'data-site="GW"' -and $sOut.unrows -notmatch 'data-site="\?"|Site \?') { $sOut.unrows }
    Check 'TD-8 rows: one tap per Site (Resume when stopped, else Stop work); none = nothing; a bad code is dropped' ($sOut.rows -match 'data-set="site-resume" data-site="GW"' -and $sOut.rows -match 'data-set="site-pause" data-site="TD"[^>]*>.*Stop work on Site TD' -and $sOut.rows -notmatch '&lt;x&gt;|<x>' -and $sOut.rows -match '<h3 class="set-label">Sites</h3>' -and @($sOut.none).Count -eq 0 -and $sOut.norows -eq '') { $sOut.rows }
    $ssSrc = Get-Content (Join-Path $repo 'pass-app\public\site-stop.js') -Raw; $swSrc = Get-Content (Join-Path $repo 'pass-app\public\sw.js') -Raw
    Check 'TD-8 wiring: app.js shows the Site banners after the global pause, the Sites rows in settings, both taps; cached offline; no new style' ($app -match "import \{ siteStopBanners, siteStopRows \} from './site-stop\.js'" -and $app -match '(?s)data-set="kitchen-resume">Resume</button></div>`\);.*?b\.push\(\.\.\.siteStopBanners\(s\?\.siteStops\)\);' -and $app -match '\$\{siteStopRows\(s\.siteStops\)\}' -and $app -match "a === 'site-pause'\) \{ const c = b\.dataset\.site; if \(await confirmBox" -and $app -match "a === 'site-resume'\) \{ const r = await act\(\{ op: 'site-resume', site: b\.dataset\.site \}" -and $swSrc -match "'/site-stop\.js'" -and $ssSrc -notmatch 'style=|data-css|<style' -and @([regex]::Matches($ssSrc, 'class="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin 'banner', 'banner calm', 'btn', 'set-row', 'set-ic', 'set-label', 'set-group' }).Count -eq 0)

    # plain names: an order built from an idea carries the idea's short title (label); a private order never does
    $nowL = (Get-Date).ToUniversalTime().ToString('o')
    @{ id = 'J81'; name = 'improve: In kitchen/kitchen.ps1 rewrite the thing'; recipe = 'improve'; status = 'done'; cursor = 1; attempt = 0; created = $nowL; history = @()
        vars = @{ goal = 'In kitchen/kitchen.ps1 rewrite the thing. (Idea I9: Switch cooks when one rests. Saves days.)' }; steps = @(@{ script = 'merge.ps1'; args = @{} }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J81.json') -Encoding utf8
    @{ id = 'J82'; name = 'improve: private thing'; recipe = 'improve'; status = 'done'; cursor = 1; attempt = 0; created = $nowL; history = @()
        vars = @{ goal = 'my health notes (Idea I10: Secret title. x)'; private = 'yes' }; steps = @(@{ script = 'merge.ps1'; args = @{} }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J82.json') -Encoding utf8
    $stL = @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs)
    Check 'plain names: an idea-built order shows the idea title' (@($stL | Where-Object id -eq 'J81')[0].label -eq 'Switch cooks when one rests')
    Check 'plain names: a private order never gets a label' (-not @($stL | Where-Object id -eq 'J82')[0].label)
    $appJsP = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'brief: count chips and at most 3 orders per group, with "and N more"' ($appJsP -match 'brief-chips' -and $appJsP -match 'list\.slice\(0, 3\)' -and $appJsP -match 'and \$\{list\.length - 3\} more')
    Check 'cooking: live cards with a step strip, kitchen words and what the cook is doing' ($appJsP -match 'function cookCard' -and $appJsP -match 'class="strip"' -and $appJsP -match 'stepWord\(j\)' -and $appJsP -match 'activityWord\(j\)')
    Remove-Item (Join-Path $root 'jobs\J81.json'), (Join-Path $root 'jobs\J82.json') -Force

    # live activity: the last 25 tool lines of a running job; private jobs keep only ts, kind, tool, status
    New-Item -ItemType Directory -Force (Join-Path $root 'runs') | Out-Null
    $actBase = Join-Path $root 'runs\J900-s0-a0'
    $nowIso = (Get-Date).ToUniversalTime().ToString('o')
    $job900 = @{ id = 'J900'; name = 'activity fixture'; status = 'running'; cursor = 0; attempt = 0; created = $nowIso; history = @();
        steps = @(@{ script = 'agent-step.ps1'; args = @{ Role = 'build' } }); run = @{ base = $actBase; startedAt = $nowIso } }
    $job900 | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J900.json') -Encoding utf8
    $actLines = @(1..30 | ForEach-Object { '{"ts":"t' + $_ + '","kind":"tool","tool":"Edit","status":"ok","target":"C:\\x\\SECRET-TARGET-' + $_ + '\\app.js","out":"SECRET-OUT-' + $_ + '"}' })
    $actLines[27] = '{not json'
    Set-Content "$actBase.activity.jsonl" $actLines -Encoding utf8
    $a900 = @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object { $_.id -eq 'J900' })[0]
    Check 'activity: last 25 lines, malformed line skipped' (@($a900.activity).Count -eq 24 -and $a900.activity[-1].ts -eq 't30' -and $a900.activity[0].ts -eq 't6')
    Check 'activity: a public job keeps target and out' ($a900.activity[-1].target -match 'SECRET-TARGET-30' -and $a900.activity[-1].out -eq 'SECRET-OUT-30')
    Check 'live: a running job carries its plan for the Live tree (order -> steps -> cook): station and role per step, nothing else' (@($a900.plan).Count -eq 1 -and $a900.plan[0].station -eq 'agent' -and $a900.plan[0].role -eq 'build' -and ((@($a900.plan[0].PSObject.Properties.Name) | Sort-Object) -join ',') -eq 'role,station')
    '{"action":"cook","supplier":"gemini","private":true}' | Set-Content "$actBase.sous.json" -Encoding utf8
    $rawPriv = (Invoke-WebRequest "$base/api/state" -Headers $auth -UseBasicParsing).Content
    $p900 = @(($rawPriv | ConvertFrom-Json).jobs | Where-Object { $_.id -eq 'J900' })[0]
    Check 'activity: a private job keeps only ts, kind, tool, status' (@($p900.activity).Count -eq 24 -and ((@($p900.activity[0].PSObject.Properties.Name) | Sort-Object) -join ',') -eq 'kind,status,tool,ts')
    Check 'activity: private target and out never leave the server' ($rawPriv -notmatch 'SECRET-TARGET|SECRET-OUT')
    Check 'live: a private job keeps its plan as step kinds only (the tree shows no words)' (@($p900.plan).Count -eq 1 -and ((@($p900.plan[0].PSObject.Properties.Name) | Sort-Object) -join ',') -eq 'role,station')
    # a private order's log (the cook's whole answer) never rides the live stream: by the sous chef's call or by the order's own flag
    Set-Content "$actBase.log" @('line one', 'SECRET-LOG-TAIL resume words') -Encoding utf8
    Check 'private: the sous chef private call empties the log tail' (@(@((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object id -eq 'J900')[0].tail).Count -eq 0)
    Remove-Item "$actBase.sous.json"
    Check 'private: a public running job shows its log tail' ((@((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object id -eq 'J900')[0].tail -join ' ') -match 'SECRET-LOG-TAIL')
    $job900.vars = @{ private = 'yes' }; $job900 | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J900.json') -Encoding utf8
    $rawP2 = (Invoke-WebRequest "$base/api/state" -Headers $auth -UseBasicParsing).Content
    Check "private: vars.private 'yes' (cook.ps1's string) keeps the tail off the stream" ($rawP2 -notmatch 'SECRET-LOG-TAIL' -and @(($rawP2 | ConvertFrom-Json).jobs | Where-Object id -eq 'J900')[0].private -eq $true)
    $job900.Remove('vars')
    # a step marked Private (no sous.json, no vars) is private too, in /api/state and on the live stream
    $job900.steps[0].args.Private = $true; $job900 | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J900.json') -Encoding utf8
    $rawP3 = (Invoke-WebRequest "$base/api/state" -Headers $auth -UseBasicParsing).Content
    Check 'private: a Private step keeps the tail out of /api/state' ($rawP3 -notmatch 'SECRET-LOG-TAIL' -and @(($rawP3 | ConvertFrom-Json).jobs | Where-Object id -eq 'J900')[0].private -eq $true)
    $hc3 = [Net.Http.HttpClient]::new(); $hc3.Timeout = [TimeSpan]::FromSeconds(10); $hc3.DefaultRequestHeaders.Add('Authorization', "Bearer $key")
    $rd3 = [IO.StreamReader]::new($hc3.GetStreamAsync("$base/api/stream").GetAwaiter().GetResult())
    $got3 = ''; $sw3 = [Diagnostics.Stopwatch]::StartNew()
    while ($sw3.Elapsed.TotalSeconds -lt 8 -and $got3 -notmatch '(?m)^data: ') { $got3 += $rd3.ReadLine() + "`n" }
    $rd3.Dispose(); $hc3.Dispose()
    $st3 = try { ((($got3 -split "`n" | Where-Object { $_ -like 'data: *' } | Select-Object -First 1) -replace '^data: ') | ConvertFrom-Json) } catch { $null }
    $s3 = @($st3.jobs | Where-Object id -eq 'J900')[0]
    Check 'private: /api/stream state frame has no log tail for a running private job' ($got3 -match 'event: state' -and $got3 -notmatch 'SECRET-LOG-TAIL' -and $s3.private -eq $true -and @($s3.tail).Count -eq 0)
    $job900.steps[0].args.Remove('Private'); Remove-Item "$actBase.log"
    '{"action":"cook","supplier":"gemini","private":true}' | Set-Content "$actBase.sous.json" -Encoding utf8
    Remove-Item "$actBase.activity.jsonl"
    $e900 = @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object { $_.id -eq 'J900' })[0]
    Check 'activity: no activity file gives an empty list' ($null -ne $e900.PSObject.Properties['activity'] -and @($e900.activity).Count -eq 0)
    $job900.status = 'done'; $job900.Remove('run')
    $job900 | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J900.json') -Encoding utf8
    $d900 = @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object { $_.id -eq 'J900' })[0]
    Check 'activity: a job that is not running has none' ($null -eq $d900.PSObject.Properties['activity'])
    Remove-Item (Join-Path $root 'jobs\J900.json') -Force

    # redact-private-sse: a private running order sends no log tail and only whitelisted activity over /api/state, /api/stream and the job sheet
    New-Item -ItemType Directory -Force (Join-Path $root 'run') | Out-Null
    $leakRx = 'SECRET-TARGET|SECRET-OUT|SECRET-LOG-TAIL'
    function New-SseJob($id, $vars, $stepArgs, $cursor = 0) {
        $b = Join-Path $root "run\$id-s$cursor-a0"
        $steps = @(@{ script = 'agent-step.ps1'; args = @{ Role = 'build' } }, @{ script = 'agent-step.ps1'; args = $stepArgs })
        $jb = @{ id = $id; name = 'sse fixture'; status = 'running'; cursor = $cursor; attempt = 0; created = $nowIso; history = @(); steps = $steps; run = @{ base = $b; startedAt = $nowIso } }
        if ($vars) { $jb.vars = $vars }
        $jb | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$id.json") -Encoding utf8
        '{"ts":"t1","kind":"tool","tool":"Edit","status":"ok","target":"C:\\x\\SECRET-TARGET\\app.js","out":"SECRET-OUT"}' | Set-Content "$b.activity.jsonl" -Encoding utf8
        Set-Content "$b.log" @('line one', 'SECRET-LOG-TAIL resume words') -Encoding utf8
    }
    function Get-SseJob($id) { @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object id -eq $id)[0] }
    New-SseJob 'J902' @{ private = 'yes' } @{ Role = 'build' }
    $rawS = (Invoke-WebRequest "$base/api/state" -Headers $auth -UseBasicParsing).Content
    $s902 = Get-SseJob 'J902'
    Check 'sse private: /api/state has none of the three secrets' ($rawS -notmatch $leakRx)
    Check 'sse private: tail empty and activity keys are only kind,status,tool,ts' (@($s902.tail).Count -eq 0 -and @($s902.activity).Count -eq 1 -and ((@($s902.activity[0].PSObject.Properties.Name) | Sort-Object) -join ',') -eq 'kind,status,tool,ts')
    $sc2 = [Net.Http.HttpClient]::new(); $sc2.Timeout = [TimeSpan]::FromSeconds(10); $sc2.DefaultRequestHeaders.Add('Authorization', "Bearer $key")
    $rd2 = [IO.StreamReader]::new($sc2.GetStreamAsync("$base/api/stream").GetAwaiter().GetResult())
    $gotS = ''; $swS = [Diagnostics.Stopwatch]::StartNew(); $sawState = $false
    while ($swS.Elapsed.TotalSeconds -lt 8 -and -not $sawState) { $ln = $rd2.ReadLine(); $gotS += $ln + "`n"; if ($gotS -match 'event: state' -and $ln -like 'data:*' -and $ln -match 'J902') { $sawState = $true } }
    $rd2.Dispose(); $sc2.Dispose()
    Check 'sse private: /api/stream state carries the job with none of the secrets' ($sawState -and $gotS -notmatch $leakRx)
    Check 'sse private: the job sheet has none of the secrets' ((Invoke-WebRequest "$base/api/job/J902" -Headers $auth -UseBasicParsing).Content -notmatch 'SECRET-LOG-TAIL')
    Check 'sse private: the timeline redacts target and out' ((Invoke-WebRequest "$base/api/job/J902/timeline" -Headers $auth -UseBasicParsing).Content -notmatch 'SECRET-TARGET|SECRET-OUT')
    New-SseJob 'J903' $null @{ Role = 'build'; Private = 'yes' } 0
    Check "sse private: a step Private 'yes' with no vars is redacted" ((Invoke-WebRequest "$base/api/state" -Headers $auth -UseBasicParsing).Content -notmatch $leakRx)
    Remove-Item (Join-Path $root 'jobs\J903.json') -Force
    New-SseJob 'J904' $null @{ Role = 'build'; Private = $true } 0
    Check 'sse private: Private on a later step redacts while step 1 runs' ((Invoke-WebRequest "$base/api/state" -Headers $auth -UseBasicParsing).Content -notmatch $leakRx)
    Remove-Item (Join-Path $root 'jobs\J904.json') -Force
    Remove-Item (Join-Path $root 'jobs\J902.json') -Force
    New-SseJob 'J905' $null @{ Role = 'build' } 1
    '{"action":"cook","supplier":"gemini","private":true}' | Set-Content (Join-Path $root 'run\J905-s0-a0.sous.json') -Encoding utf8
    Check 'sse private: an earlier step sous.json private call redacts the running step' ((Invoke-WebRequest "$base/api/state" -Headers $auth -UseBasicParsing).Content -notmatch $leakRx)
    Remove-Item (Join-Path $root 'jobs\J905.json'), (Join-Path $root 'run\J905-s0-a0.sous.json') -Force
    New-SseJob 'J906' $null @{ Role = 'build' } 0
    $s906 = Get-SseJob 'J906'
    Check 'sse private: a public control job still shows its tail and target' ((@($s906.tail) -join ' ') -match 'SECRET-LOG-TAIL' -and $s906.activity[0].target -match 'SECRET-TARGET')
    Remove-Item (Join-Path $root 'jobs\J906.json') -Force
    $appJs = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    $sceneJs = Get-Content (Join-Path $repo 'pass-app\public\scene.js') -Raw; $liveJs = Get-Content (Join-Path $repo 'pass-app\public\live.js') -Raw
    Check 'activity: the Live desks and the scene bubble show it' ($liveJs -match 'tagOf\(k, s\.private, word\)' -and $sceneJs -match 'activityWord\(j\) \|\|')

    # replay: GET /api/job/<id>/timeline (runs with start/end, cook, tokens, outcome, activity; private orders redacted)
    $runPath = Join-Path $root 'run'; New-Item -ItemType Directory -Force $runPath | Out-Null
    $tlJob = @{ id = 'J901'; name = 'replay fixture'; status = 'done'; cursor = 1; attempt = 0; created = $nowIso; history = @();
        steps = @(@{ script = 'agent-step.ps1'; args = @{ Role = 'build' } }) }
    $tlJob | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J901.json') -Encoding utf8
    $tlBase = Join-Path $runPath 'J901-s0-a0'
    '{"ts":"2026-10-15T10:00:01Z","kind":"tool","tool":"Edit","status":"ok","target":"C:\\x\\PLAN-TARGET-1\\app.js","out":"PLAN-OUT-1"}' | Set-Content "$tlBase.activity.jsonl" -Encoding utf8
    '0' | Set-Content "$tlBase.exit" -Encoding ascii
    'log' | Set-Content "$tlBase.log" -Encoding utf8
    '{"supplier":"claude","model":"sonnet","inputTokens":100,"outputTokens":20,"cacheReadTokens":5,"cacheWriteTokens":1}' | Set-Content "$tlBase.cost.json" -Encoding utf8
    Check 'timeline: no key gives 401' ((Get-Code "$base/api/job/J901/timeline") -eq 401)
    Check 'timeline: bad job id gives 400' ((Get-Code "$base/api/job/x1/timeline" $auth) -eq 400)
    Check 'timeline: unknown job gives 404' ((Get-Code "$base/api/job/J999/timeline" $auth) -eq 404)
    $tl = Invoke-RestMethod "$base/api/job/J901/timeline" -Headers $auth
    $tr = @($tl.runs)[0]
    Check 'timeline: run has step, attempt, cook, tokens, outcome' ($tl.ok -eq $true -and $tl.id -eq 'J901' -and $tr.run -eq 'J901-s0-a0' -and $tr.step -eq 0 -and $tr.attempt -eq 0 -and $tr.cook -eq 'claude sonnet' -and $tr.tokens -eq 126 -and $tr.outcome -eq 'done')
    Check 'timeline: run has start, end and activity' ($tr.start -and $tr.end -and @($tr.activity).Count -eq 1)
    Check 'timeline: a public job keeps target and out' ($tr.activity[0].target -match 'PLAN-TARGET-1' -and $tr.activity[0].out -eq 'PLAN-OUT-1')
    '{"action":"cook","supplier":"gemini","private":true}' | Set-Content "$tlBase.sous.json" -Encoding utf8
    $rawTl = (Invoke-WebRequest "$base/api/job/J901/timeline" -Headers $auth -UseBasicParsing).Content
    $ptr = @(($rawTl | ConvertFrom-Json).runs)[0]
    Check 'timeline: a private job keeps only ts, kind, tool, status' (((@($ptr.activity[0].PSObject.Properties.Name) | Sort-Object) -join ',') -eq 'kind,status,tool,ts')
    Check 'timeline: private target and out never leave the server' ($rawTl -notmatch 'PLAN-TARGET|PLAN-OUT')
    Remove-Item (Join-Path $root 'jobs\J901.json'), "$tlBase.*" -Force
    $appJsTl = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    Check 'timeline: app.js has the Replay section, scrubber and recap card' ($appJsTl -match '/timeline' -and $appJsTl -match 'timeline-bar' -and $appJsTl -match 'replay-slider' -and $appJsTl -match 'recap-card' -and $appJsTl -match 'Busiest crew' -and $appJsTl -match 'Files changed')
    Check 'timeline: Copy as Markdown writes the standup report' ($appJsTl -match 'Copy as Markdown' -and $appJsTl -match 'data-copy-recap' -and $appJsTl -match 'Standup Recap')
    Check 'timeline: app.css styles the replay parts' ((Get-Content (Join-Path $repo 'pass-app\public\app.css') -Raw) -match '\.timeline-bar[\s\S]*\.replay-slider[\s\S]*\.recap-card')

    # scene 2.0 part 1: living stage diorama
    $sceneOut = & node (Join-Path $repo 'pass-app\test-scene.mjs')
    $sceneExit = $LASTEXITCODE
    $sceneTest = $null
    try { $sceneTest = ($sceneOut -join "`n") | ConvertFrom-Json } catch { $sceneTest = $null }
    Check 'scene 2.0: test-scene.mjs exits 0 (a node crash is a failure, not silence)' ($sceneExit -eq 0)
    Check 'scene 2.0: test-scene.mjs reported at least 20 checks' ($null -ne $sceneTest -and @($sceneTest).Count -ge 20)
    # City G4: the Board tab's top is the City (city.js), not the compact scene; the scene stays whole on the Live tab
    $cityHtml = Get-Content (Join-Path $repo 'pass-app\public\index.html') -Raw; $cityCss = Get-Content (Join-Path $repo 'pass-app\public\app.css') -Raw
    Check 'City_Home: the Board tab opens on the City and the Live tab keeps the scene (renderScene mounts only #scene-live)' ($appJs -match "import\('\./city\.js'\)\.then" -and $appJs -match 'S\.city\?\.update\(\)' -and $appJs -match "const el = S\.view === 'cooks' \? \`$\('scene-live'\) : null" -and $cityHtml -match '<div class="city" id="city"' -and $cityHtml -notmatch 'id="scene-pass"')
    Check 'City_LoadsAlone: city.js is imported on its own (a failure leaves the Board working), and both City files are in the offline shell' ($appJs -match "import\('\./city\.js'\)[^\r\n]*" -and $appJs -match '\}\)\.catch\(\(\) => \{\}\);' -and (Get-Content (Join-Path $repo 'pass-app\public\sw.js') -Raw) -match "'/city\.js', '/city-art\.js'")
    Check 'City_Strip: the horizon strip sits under the header, is a 44 px button, and city.js shows it only off the Board tab' ($cityHtml -match '<button class="city-strip" id="city-strip" type="button" hidden></button>\s*<div id="banners"' -and $cityCss -match '\.city-strip\{[^}]*min-height:44px' -and (Get-Content (Join-Path $repo 'pass-app\public\city.js') -Raw) -match 'o\.strip\.hidden = home \|\| !s')
    Check 'City_Css: crisp pixels, the (i) key 44 px, tokens only (no new colours) in the City block' ($cityCss -match '\.city-canvas\{[^}]*image-rendering:pixelated' -and $cityCss -match '\.city-key\{[^}]*min-width:44px;min-height:44px' -and $cityCss.Substring($cityCss.IndexOf('/* The City (public/city.js')) -notmatch '#[0-9a-fA-F]{3,6}\b')
    $cityJs = Get-Content (Join-Path $repo 'pass-app\public\city.js') -Raw
    Check 'City_Nav: the City reads its level from the hash (Back zooms out), names and crumbs are 44 px links, a sideways move replaces the route, Esc goes up, the canvas keeps the page scrolling' ($cityJs.Contains("from './city-nav.js'") -and $cityJs.Contains('routeOf(location.hash)') -and $cityJs.Contains('location.replace(hashOf(to))') -and $cityJs.Contains("e.key === 'Escape'") -and $cityCss -match '\.city-names a\{[^}]*min-height:44px' -and $cityCss -match '\.city-crumbs a\{[^}]*min-height:44px' -and (Get-Content (Join-Path $repo 'pass-app\public\city-nav.js') -Raw).Contains("el.style.touchAction = 'pan-y'") -and (Get-Content (Join-Path $repo 'pass-app\public\sw.js') -Raw).Contains("'/city-nav.js'"))
    foreach ($t in @($sceneTest)) {
        if ($null -eq $t) { continue }
        Check "scene 2.0: $($t.name)" ($t.pass -eq $true)
    }
    $appCss = Get-Content (Join-Path $repo 'pass-app\public\app.css') -Raw

    # the City (plans/city-god-mode-2026-10-26.md): pass-app/test-city.mjs (towers.mjs on throwaway state folders and a fake git), then the live route
    $cityOut = & node (Join-Path $repo 'pass-app\test-city.mjs') 2>$null
    $cityExit = $LASTEXITCODE; $cityTest = $null
    try { $cityTest = ($cityOut -join "`n") | ConvertFrom-Json } catch { $cityTest = $null }
    Check 'city: test-city.mjs exits 0 (a node crash is a failure, not silence)' ($cityExit -eq 0)
    Check 'city: test-city.mjs reported at least 25 checks' (@($cityTest).Count -ge 25)
    foreach ($t in @($cityTest)) { if ($t) { Check "city: $($t.name)" ($t.pass -eq $true) } }
    Check 'City_TowersNeedsKey: /api/towers needs the key' ((Get-Code "$base/api/towers") -eq 401)
    $twRaw = (Invoke-WebRequest "$base/api/towers" -Headers $auth).Content; $tw = $twRaw | ConvertFrom-Json
    Check 'City_TowersRoute: ok, this repo as its one building (no bootRepos here), with a 12-hex version' ($tw.ok -and @($tw.towers).Count -eq 1 -and $tw.v -match '^[0-9a-f]{12}$' -and @($tw.towers)[0].kind -in @('tower', 'lot'))
    Check 'City_NoLocalPaths: /api/towers carries no folder path from this PC' ($twRaw -notmatch [regex]::Escape(($repo -replace '\\', '\\')) -and $twRaw -notmatch [regex]::Escape(($root -replace '\\', '\\')))
    Check 'City_TowersV_InState: the state carries towersV, the same as /api/towers v' ((Invoke-RestMethod "$base/api/state" -Headers $auth).towersV -eq $tw.v)
    $citySlug = [string](Get-Content (Join-Path $repo 'kitchen.repo.json') -Raw | ConvertFrom-Json).github
    Add-Content -LiteralPath (Join-Path $root 'merges.jsonl') -Value (@{ pr = 77; repo = $citySlug; sha = ('7' * 40); actor = 'claude-session'; why = 'batch-run integrate-city: test'; at = [DateTime]::UtcNow.ToString('o'); ok = $true } | ConvertTo-Json -Compress) -Encoding utf8
    # towers.mjs looks at its inputs at most every 3 s: wait for the floor, then check all of it
    for ($i = 0; $i -lt 60; $i++) { $tw2 = Invoke-RestMethod "$base/api/towers" -Headers $auth; if (@(@($tw2.towers)[0].floors | Where-Object { $_.pr -eq 77 }).Count) { break }; Start-Sleep -Milliseconds 250 }
    $fl77 = @(@($tw2.towers)[0].floors | Where-Object { $_.pr -eq 77 })
    Check 'City_TowersV_MovesOnMerge: a merge line raises a floor (pr, sha, by session, its Pour) and moves towersV' ($tw2.v -ne $tw.v -and $fl77.Count -eq 1 -and $fl77[0].by -eq 'session' -and $fl77[0].pour -eq 'city' -and @($tw2.towers)[0].kind -eq 'tower' -and (Invoke-RestMethod "$base/api/state" -Headers $auth).towersV -eq $tw2.v)
    @{ id = 'J950'; name = 'improve: city tower probe'; status = 'pending'; cursor = 0; attempt = 0; created = [DateTime]::UtcNow.ToString('o'); history = @(); steps = @(@{ script = 'agent-step.ps1'; args = @{} }, @{ script = 'merge.ps1'; args = @{ Repo = $repo } }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J950.json') -Encoding utf8
    @{ id = 'J951'; name = 'research: city yard probe'; status = 'pending'; cursor = 0; attempt = 0; created = [DateTime]::UtcNow.ToString('o'); history = @(); steps = @(@{ script = 'agent-step.ps1'; args = @{} }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J951.json') -Encoding utf8
    $sJT = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'City_JobViewTower: a work order with a merge Repo carries its Tower key; one with no Repo carries none (the Yard lot)' (@($sJT.jobs | Where-Object id -eq 'J950')[0].tower -eq @($tw2.towers)[0].key -and $null -eq @($sJT.jobs | Where-Object id -eq 'J951')[0].tower)
    Remove-Item (Join-Path $root 'jobs\J950.json'), (Join-Path $root 'jobs\J951.json') -Force
    # G2: GitHub (the fake gh above, read every 5 s): every merged and open PR, CI from the checks, the last good read kept on a failure.
    # The reads are held (Hold-GhRead) while the City is read and the answers turn to a failure: a read used to finish between the
    # suite's look at githubAt and the switch, so the failed read kept a later good read's githubAt than the one the suite saw
    # (City_GitHubFail; a harness on towers.mjs and this fake gh: 8 of 40 failed reading every 1 s, 28 of 40 every 0.3 s; 0 of 80 held)
    for ($i = 0; $i -lt 60 -and -not (Invoke-RestMethod "$base/api/state" -Headers $auth).githubAt; $i++) { Start-Sleep -Milliseconds 250 }
    $ghHeld = Hold-GhRead
    Check 'City_GitHubHold: the suite holds the next GitHub read (the fake gh waits for it)' $ghHeld
    # towers.mjs looks at its inputs at most every 3 s: wait for GitHub's floor and crane, then check all of it
    for ($i = 0; $i -lt 60; $i++) { $twG = Invoke-RestMethod "$base/api/towers" -Headers $auth; $tG = @($twG.towers)[0]; if (@($tG.floors | Where-Object { $_.pr -eq 5 }).Count -and @($tG.open | Where-Object { $_.pr -eq 6 }).Count) { break }; Start-Sleep -Milliseconds 250 }
    $sG = Invoke-RestMethod "$base/api/state" -Headers $auth
    $fl5 = @($tG.floors | Where-Object { $_.pr -eq 5 }); $cr6 = @($tG.open | Where-Object { $_.pr -eq 6 })
    Check 'City_GitHubRead: a merged PR from GitHub is a floor with its title; an open PR is a crane with its CI (red) and work order (its file is not found, so no title); the state carries githubAt' ($fl5.Count -eq 1 -and $fl5[0].title -eq 'City floor from GitHub' -and $fl5[0].by -eq 'github' -and $cr6.Count -eq 1 -and $cr6[0].ci -eq 'red' -and $cr6[0].job -eq 'J952' -and $null -eq $cr6[0].title -and $sG.githubAt -and $twG.githubAt -eq $sG.githubAt -and $null -eq $twG.githubError)
    Check 'City_GitHubCache: the last good read is kept in the state folder (towers-github.json)' ((Test-Path (Join-Path $root 'towers-github.json')) -and (Get-Content (Join-Path $root 'towers-github.json') -Raw) -match 'City floor from GitHub')
    Set-GhAnswers $true; Release-GhRead   # the held read goes on and sees only the failure
    for ($i = 0; $i -lt 60 -and -not (Invoke-RestMethod "$base/api/towers" -Headers $auth).githubError; $i++) { Start-Sleep -Milliseconds 250 }
    $twF = Invoke-RestMethod "$base/api/towers" -Headers $auth; $tF = @($twF.towers)[0]
    Check 'City_GitHubFail: a failed read says so in plain words, keeps githubAt at the last good read and drops no floor or crane' ($twF.githubError -match 'gh is not signed in$' -and $twF.githubAt -eq $sG.githubAt -and @($tF.floors | Where-Object { $_.pr -eq 5 }).Count -eq 1 -and @($tF.open | Where-Object { $_.pr -eq 6 }).Count -eq 1 -and $twF.v -ne $twG.v)
    Set-GhAnswers $false

    # listen (I40): the spoken-text builder and speaker live between the speak:start/speak:end markers in app.js; run them in node
    $speakBlock = [regex]::Match($appJs, '(?s)// speak:start\r?\n(.*?)// speak:end').Groups[1].Value
    Check 'listen: app.js has the speak block, Listen buttons and speaker icon' ($speakBlock.Length -gt 200 -and $appJs -match 'data-listen="brief"' -and $appJs -match 'job-listen' -and (Get-Content (Join-Path $repo 'pass-app\public\index.html') -Raw) -match 'id="i-speaker"[\s\S]*id="job-listen"')
    Check 'listen: app.css styles the playing state' ($appCss -match '\.listen-btn\[aria-pressed="true"\]')
    $speakTest = @'
const checks = [];
const ok = (name, pass) => checks.push({ name, pass: !!pass });
const fake = () => { const log = { spoken: [], cancels: 0, utts: [] }; return { log, SpeechSynthesisUtterance: function (t) { this.text = t; log.utts.push(this); }, speechSynthesis: { speak: (u) => log.spoken.push(u.text), cancel: () => { log.cancels++; } } }; };
const b = { needsYou: [{ name: 'a' }, { name: 'b' }], followUps: [{ company: 'Acme', role: 'Cook' }], newRoles: [{ role: 'Chef', company: 'Zed' }, { role: 'Baker', company: 'Yo' }], newRoleCount: 2, plated: [], setAside: [] };
const t = briefSpeech(b, 'Good morning');
ok('strips tags and script', stripMarkup('<b>Hi</b> <a href="x">there</a><script>alert(1)</script> &amp; &lt;ok&gt;') === 'Hi there & <ok>');
ok('stripMarkup survives null, undefined and numbers', stripMarkup(null) === '' && stripMarkup(undefined) === '' && stripMarkup(5) === '');
ok('brief mentions counts and names', /2 work orders are waiting/.test(t) && /Cook at Acme|Follow up on Cook/.test(t) && /2 new roles/.test(t) && /Chef at Zed/.test(t));
ok('brief has no markup or undefined', !/[<>]|&amp;|undefined/.test(t));
ok('brief has natural pauses', /\. /.test(t) && t.endsWith('.') && !/  /.test(t));
ok('more than three says and N more', /and 2 more/.test(briefSpeech({ needsYou: [1, 2, 3, 4, 5].map((i) => ({ name: 'o' + i })) }, 'Hello')));
ok('singular forms', /1 work order is waiting/.test(briefSpeech({ needsYou: [{ name: 'x' }] }, 'Hi')));
ok('empty brief is a quiet night', /quiet night/.test(briefSpeech({}, 'Hi')) && /quiet night/.test(briefSpeech(null, 'Hi')));
ok('hostile name is plain text', !/[<>]/.test(briefSpeech({ needsYou: [{ name: '<img onerror=x>Pie' }] }, 'Hi')));
ok('job speech strips html', jobSpeech({ status: 'running' }, 'Fix it', 'Cooking step <b>2</b> of 3.') === 'Fix it. Cooking step 2 of 3.');
ok('private job never speaks its sentence', !/secret/.test(jobSpeech({ status: 'done', private: true }, 'Tailor', 'secret target.')));
ok('private job says its status from the label table', jobSpeech({ status: 'pending', private: true }, 'Tailor', 'x') === 'Tailor. It is queued.' && jobSpeech({ status: 'done', private: true }, 'Tailor', 'x') === 'Tailor. It is handed over.');
ok('unsupported is false and safe', !speechOK({}) && !speechOK({ speechSynthesis: undefined }) && !speechOK({ get speechSynthesis() { throw new Error('no'); } }) && speechOK(fake()));
const w = fake(); let changes = 0; const sp = createSpeaker(w, () => changes++);
ok('toggle speaks', sp.toggle('One. Two.', 'brief') === true && sp.key === 'brief' && w.log.spoken.length === 1);
ok('same key again stops', sp.toggle('One. Two.', 'brief') === false && sp.key === null && w.log.cancels >= 2);
sp.toggle('One.', 'brief'); sp.toggle('Other.', 'job:J1');
ok('different key restarts', sp.key === 'job:J1' && w.log.spoken.at(-1) === 'Other.');
w.log.utts.at(-1).onend();
ok('onend clears the state', sp.key === null);
sp.toggle('Again.', 'brief'); w.log.utts.at(-1).onerror();
ok('onerror clears the state', sp.key === null);
const w2 = fake(); createSpeaker(w2).toggle(('A sentence that is fairly long. ').repeat(30), 'brief');
ok('long text is chunked', w2.log.spoken.length > 1 && w2.log.spoken.every((s) => s.length <= 260));
const w3 = createSpeaker({}, () => {});
ok('unsupported toggle returns false', w3.toggle('x', 'k') === false);
console.log(JSON.stringify(checks));
'@
    $speakFile = Join-Path ([IO.Path]::GetTempPath()) "speak-test-$PID.mjs"
    $labelLines = @($appJs -split "`r?`n" | Where-Object { $_ -match '^const (STATUS_LABEL|statusLabel) = ' }) -join "`n"
    ($labelLines + "`n" + $speakBlock + "`n" + $speakTest) | Set-Content $speakFile -Encoding utf8
    $speakOut = & node $speakFile
    $speakExit = $LASTEXITCODE
    Remove-Item $speakFile -Force -ErrorAction SilentlyContinue
    $speakRes = $null
    try { $speakRes = ($speakOut -join "`n") | ConvertFrom-Json } catch { $speakRes = $null }
    Check 'listen: speak tests exit 0 and report at least 15 checks' ($speakExit -eq 0 -and $null -ne $speakRes -and @($speakRes).Count -ge 15)
    foreach ($t in @($speakRes)) { if ($null -ne $t) { Check "listen: $($t.name)" ($t.pass -eq $true) } }

    Check 'scene: the header comment in scene.js names the still fallback card and its budget' ($sceneJs -match '(?m)^// Fallback: a still card \(no animation, at most 25 KB of markup')
    Check 'scene: exports mountScene, sceneHtml, and activityWord' ($sceneJs -match 'export function mountScene\b' -and $sceneJs -match 'export function sceneHtml\b' -and $sceneJs -match 'export function activityWord\b')
    Check 'scene: renderScene in app.js calls mountScene' ($appJs -match 'mountScene\(el, s')
    Check 'scene: the still card in app.css never moves (no animation, transition or keyframes; rename S7a)' ($appCss -match '/\* ---- the scene before the pixel stage loads' -and ([regex]::Match($appCss, '/\* ---- the scene before the pixel stage loads[\s\S]*?(?=/\* ----)').Value -notmatch 'animation|transition|@keyframes'))
    Check 'scene: the kitchen SVG and its styles are gone (no .scene-stage.paused, no sc- keyframes)' ($appCss -notmatch '\.scene-stage\.paused' -and $appCss -notmatch '@keyframes sc-' -and $sceneJs -notmatch '<svg')

    # when Claude is away: lead.json notes, the mode from the plan reading, Jordan's manual "out", the boot pack line
    # clients: income leads (the station writes leads.json; Chef shows them and keeps Jordan's marks, under the same lock)
    function ClPost($body) { Invoke-RestMethod "$base/api/clients" -Method Post -Headers $auth -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) }
    Check 'clients: needs the key' ((Get-Code "$base/api/clients") -eq 401)
    $cv = (Invoke-RestMethod "$base/api/clients" -Headers $auth).data
    Check 'clients: leads listed' (@($cv.items).Count -eq 2 -and $cv.items[0].title -eq 'Chatbot for a dentist')
    Check 'clients: a javascript: link never reaches the page' (($cv.items | Where-Object id -eq 'L2').link -eq '')
    Check 'clients: state counts new leads with a pitch' ((Invoke-RestMethod "$base/api/state" -Headers $auth).leads -eq 2)
    Check 'clients: mark sent' ((ClPost @{ op = 'mark'; id = 'L1'; status = 'sent' }).ok -and ((Get-Content "$income\leads.json" -Raw | ConvertFrom-Json).items | Where-Object id -eq 'L1').status -eq 'sent')
    Check 'clients: bad mark refused' (-not (ClPost @{ op = 'mark'; id = 'L1'; status = 'deleted' }).ok)
    Check 'clients: bad id refused' (-not (ClPost @{ op = 'mark'; id = '../x'; status = 'sent' }).ok)
    Check 'clients: Jordan edits a pitch' ((ClPost @{ op = 'pitch'; id = 'L1'; text = 'My own words for this one.' }).ok -and ((Get-Content "$income\leads.json" -Raw | ConvertFrom-Json).items | Where-Object id -eq 'L1').pitch -eq 'My own words for this one.')
    Set-Content "$income\leads.json.lock" 'station'
    $busy = ClPost @{ op = 'mark'; id = 'L1'; status = 'won' }
    Check 'clients: lock held by the station -> busy, nothing saved' (-not $busy.ok -and $busy.error -match 'busy' -and ((Get-Content "$income\leads.json" -Raw | ConvertFrom-Json).items | Where-Object id -eq 'L1').status -eq 'sent')
    [IO.File]::Delete("$income\leads.json.lock")
    $keep = Get-Content "$income\leads.json" -Raw; Set-Content "$income\leads.json" '{ broken'
    Check 'clients: unreadable leads.json is an error, never replaced' (-not (Invoke-RestMethod "$base/api/clients" -Headers $auth).ok -and -not (ClPost @{ op = 'mark'; id = 'L1'; status = 'won' }).ok -and (Get-Content "$income\leads.json" -Raw).Trim() -eq '{ broken')
    Set-Content "$income\leads.json" $keep
    $sc = ClPost @{ op = 'scout' }
    Check 'clients: Find leads queues the lead scout' ($sc.ok -and (@(Get-ChildItem (Join-Path $root 'jobs') -Filter 'J*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.name -match '^leadscout:' }).Count -ge 1))
    function LeadPost($body) { Invoke-RestMethod "$base/api/lead" -Method Post -Headers $auth -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) }
    $lv = (Invoke-RestMethod "$base/api/lead" -Headers $auth).data
    Check 'lead: no plan reading means Claude is here' ($lv.mode -eq 'here' -and @($lv.notes).Count -eq 0)
    Check 'lead: needs the key' ((Get-Code "$base/api/lead") -eq 401)
    $ln = LeadPost @{ op = 'note'; text = 'Look at the J76 harvester first' }
    Check 'lead: a note is saved with an id' ($ln.ok -and $ln.data.id -eq 'N1' -and $ln.data.status -eq 'open')
    Check 'lead: an empty note is refused' (-not (LeadPost @{ op = 'note'; text = ' ' }).ok)
    $reset = (Get-Date).ToUniversalTime().AddDays(2).ToString('o')
    @{ claude = @{ at = (Get-Date).ToUniversalTime().ToString('o'); status = 'allowed_warning'; window = 'seven_day'; fiveHour = @{ used = 0.1; resetsAt = $reset }; sevenDay = @{ used = 0.9; resetsAt = $reset } } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'plan-usage.json')
    Check 'lead: 90% of the week reads as low' ((Invoke-RestMethod "$base/api/lead" -Headers $auth).data.mode -eq 'low')
    Check 'lead: Jordan can mark Claude out' ((LeadPost @{ op = 'away'; on = $true }).ok -and (Invoke-RestMethod "$base/api/lead" -Headers $auth).data.mode -eq 'away')
    Check 'lead: the stream state carries the lead' ((Invoke-RestMethod "$base/api/state" -Headers $auth).lead.mode -eq 'away')
    Check 'lead: and back' ((LeadPost @{ op = 'away'; on = $false }).ok -and (Invoke-RestMethod "$base/api/lead" -Headers $auth).data.mode -eq 'low')
    @{ claude = @{ at = (Get-Date).ToUniversalTime().AddDays(-9).ToString('o'); sevenDay = @{ used = 1.0; resetsAt = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o') } } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'plan-usage.json')
    Check 'lead: a reading from before the reset says nothing (here)' ((Invoke-RestMethod "$base/api/lead" -Headers $auth).data.mode -eq 'here')
    Check 'lead: a note can be removed' ((LeadPost @{ op = 'drop'; id = 'N1' }).ok -and @((Invoke-RestMethod "$base/api/lead" -Headers $auth).data.notes).Count -eq 0)
    Check 'lead: the words are not in the audit trail' (-not ((Get-Content (Join-Path $root 'pass-actions.jsonl') -Raw) -match 'harvester'))
    $leadPs = Join-Path $repo 'kitchen\lead.ps1'
    [void](LeadPost @{ op = 'note'; text = 'Second note for the boot pack' })
    Check 'lead.ps1: lists open notes' ((& pwsh -NoProfile -File $leadPs notes) -match 'N2 .*Second note')
    Check 'lead.ps1: saves a handoff that Chef shows' ((& pwsh -NoProfile -File $leadPs handoff -Text 'Working on the Chef style pass') -match 'saved' -and (Invoke-RestMethod "$base/api/lead" -Headers $auth).data.handoff.text -match 'style pass')
    $bootOut = Join-Path $root 'BOOT-test.md'
    & pwsh -NoProfile -File (Join-Path $repo 'scripts\handoff.ps1') -BrainPath $root -Repos $repo -OutPath $bootOut -KitchenTimeoutSeconds 5 *> $null
    Check 'boot pack opens with Jordan''s notes' ((Test-Path $bootOut) -and (Get-Content $bootOut -Raw) -match "Jordan's notes from (Chef|the Board)[\s\S]*N2 .*Second note")
    Check 'lead.ps1: done clears a note' ((& pwsh -NoProfile -File $leadPs done -Id N2) -match 'done' -and @((Invoke-RestMethod "$base/api/lead" -Headers $auth).data.notes).Count -eq 0)
    # Jordan's rule: push alerts (ntfy.sh, a public service) never carry the tailnet address or a link to it, only the ticket and the kind of news
    $notifySrc = Get-Content (Join-Path $repo 'kitchen\notify.ps1') -Raw; $serverSrc = Get-Content (Join-Path $repo 'pass-app\server.mjs') -Raw
    Check 'ideas: only Chef''s own call may file an idea as Jordan''s (KITCHEN_FROM_CHEF on the ideas.ps1 call)' ($serverSrc -match "ps\(ideasPs, \[\.\.\.args, '-Json'\], 90000, \{ KITCHEN_FROM_CHEF: '1' \}\)" -and $serverSrc -match '\.\.\.extraEnv, BRAIN_KITCHEN: root')
    Check 'push guard: no tailnet address or deep-link headers in what goes to ntfy' ($notifySrc -notmatch '(?i)ts\.net|tailscale-host|\bClick\b|\bActions\b' -and $serverSrc -notmatch '(?i)\.ts\.net')
    # the Live call (live.js, pass-app/SCENE.md "The Live call"); its node checks run here through test-live.mjs
    $liveJs = Get-Content (Join-Path $repo 'pass-app\public\live.js') -Raw; $indexHtml = Get-Content (Join-Path $repo 'pass-app\public\index.html') -Raw
    Check 'live: app.js starts the call and draws it only on the Live tab (live.js keeps the memory)' ($appJs -match "import \{ startLive, floorStep \} from './live\.js'" -and $appJs -match "startLive\(\{ root: \`$\('live-call'\)" -and $appJs -match "isVisible: \(\) => S\.view === 'cooks'" -and $appJs -match "if \(S\.view === 'cooks'\) liveCall\.update\(\)" -and $appJs -notmatch 'function liveHtml\(')
    Check 'live: index.html has the call under the kitchen stage and the desk sheet' ($indexHtml -match 'id="scene-live"></div><div id="live-call"></div><div id="cooks-body">' -and $indexHtml -match '<dialog class="sheet" id="agent-sheet" aria-labelledby="agent-title">' -and $indexHtml -match 'id="agent-body"')
    Check 'live: stuck after 60 s, quiet after 3 min, leave 2 min after the step ends (the numbers in one place)' ($liveJs -match 'stuckSec: 60, quietSec: 180, leaveSec: 120')
    Check 'live: the server sends the plan (station and role per step) for running jobs, next to the activity' ($serverSrc -match [regex]::Escape("v.plan = (j.steps || []).map((x) => ({ station: stationOf(x), role: String(x.args?.Role || '').slice(0, 24) }))"))
    $liveOut = & node (Join-Path $repo 'pass-app\test-live.mjs') 2>$null
    $liveExit = $LASTEXITCODE
    $liveTest = $null
    try { $liveTest = ($liveOut -join "`n") | ConvertFrom-Json } catch { $liveTest = $null }
    Check 'live: test-live.mjs exits 0 (a node crash is a failure, not silence)' ($liveExit -eq 0)
    Check 'live: test-live.mjs reported at least 60 checks' ($null -ne $liveTest -and @($liveTest).Count -ge 60)
    foreach ($t in @($liveTest)) { if ($null -ne $t) { Check "live: $($t.name)" ($t.pass -eq $true) } }
    # TD-4 the Site on the Board (public/sites.js): chip, Floor id, filter, count line and their wiring, through test-sites.mjs
    $siteTest = $null; try { $siteTest = ((& node (Join-Path $repo 'pass-app\test-sites.mjs') 2>$null) -join "`n") | ConvertFrom-Json } catch { $siteTest = $null }
    Check 'TD-4 sites: test-sites.mjs exits 0 and reported at least 30 checks' ($LASTEXITCODE -eq 0 -and @($siteTest).Count -ge 30)
    foreach ($t in @($siteTest)) { if ($null -ne $t) { Check "TD-4 sites: $($t.name)" ($t.pass -eq $true) } }
    # the World view (ZG-09, public/lobe.js); its node checks (synthetic frames, throwaway servers) run here through test-lobe.mjs
    Check 'world: a World tab in the bar, its view, and app.js draws it from state.lobe with lobe.js' ($indexHtml -match '<a href="#/world" data-view="world">' -and $indexHtml -match 'id="view-world"' -and $appJs -match "import \{ worldHtml, paintWorld \} from './lobe\.js'" -and $appJs -match "world: 'World'" -and $appJs -match 'worldHtml\(S\.state\.lobe')
    $lobeOut = & node (Join-Path $repo 'pass-app\test-lobe.mjs') 2>$null
    $lobeExit = $LASTEXITCODE
    $lobeTest = $null
    try { $lobeTest = ($lobeOut -join "`n") | ConvertFrom-Json } catch { $lobeTest = $null }
    Check 'world: test-lobe.mjs exits 0 and reported at least 60 checks' ($lobeExit -eq 0 -and $null -ne $lobeTest -and @($lobeTest).Count -ge 60)
    foreach ($t in @($lobeTest)) { if ($null -ne $t) { Check "world: $($t.name)" ($t.pass -eq $true) } }
    # the Trust card (ZG-40), split from test-lobe.mjs at the 600-line standard; both share pass-app/test-lobe-kit.mjs
    $trustOut = & node (Join-Path $repo 'pass-app\test-lobe-trust.mjs') 2>$null
    $trustExit = $LASTEXITCODE
    $trustTest = $null
    try { $trustTest = ($trustOut -join "`n") | ConvertFrom-Json } catch { $trustTest = $null }
    Check 'trust: test-lobe-trust.mjs exits 0 and reported at least 25 checks' ($trustExit -eq 0 -and $null -ne $trustTest -and @($trustTest).Count -ge 25)
    foreach ($t in @($trustTest)) { if ($null -ne $t) { Check "trust: $($t.name)" ($t.pass -eq $true) } }
    # the Self card (ZG-45, public/lobe-self.js), pure checks in its own file beside the Trust card's
    $selfOut = & node (Join-Path $repo 'pass-app\test-lobe-self.mjs') 2>$null
    $selfExit = $LASTEXITCODE
    $selfTest = $null
    try { $selfTest = ($selfOut -join "`n") | ConvertFrom-Json } catch { $selfTest = $null }
    Check 'self: test-lobe-self.mjs exits 0 and reported at least 20 checks' ($selfExit -eq 0 -and $null -ne $selfTest -and @($selfTest).Count -ge 20)
    foreach ($t in @($selfTest)) { if ($null -ne $t) { Check "self: $($t.name)" ($t.pass -eq $true) } }
    Check 'app: lead card, countdown and order-up sparks' ($appJs -match 'function renderLead\(' -and $appJs -match 'data-until' -and $appJs -match 'function celebrate\(')
    # ZG-17: the brief's World line (public/world-line.js, pure, run in node) and its skip counts (server.mjs lobeSkips, from <lobe home>\yard-counts.json)
    $wlMjs = Join-Path $root 'world-line.mjs'
    Set-Content $wlMjs @"
import { worldLine } from '$(([Uri](Join-Path $repo 'pass-app\public\world-line.js')).AbsoluteUri)';
console.log(JSON.stringify({
  full: worldLine({ decisionsReady: 2, calibrationQuestions: 1, signals24h: 14, skips: { sweep: 3, rem: 0, ram: 3, ollama: 0, gpu: 0 } }),
  push: worldLine({ decisionsReady: 2, calibrationQuestions: null, signals24h: 14, skips: { sweep: 3, ram: 3 } }),
  zero: worldLine({ decisionsReady: 0, calibrationQuestions: null, postMortemsDue: 4, signals24h: 0, csfAgeMin: 30, skipped: null, skips: { sweep: 0, rem: 0, ram: 0 } }),
  none: worldLine(null), noSkipFile: worldLine({ decisionsReady: 1, signals24h: null, skips: null }),
  mixed: worldLine({ skips: { sweep: 2, rem: 1, ram: 1, ollama: 2, gpu: 0 } }), remOnly: worldLine({ skips: { rem: 1, gpu: 1 } }),
  words: worldLine({ decisionsReady: '2 <b>x</b>', signals24h: -3, skips: { sweep: 1.5, ram: 'RAM 100 MB' } }) }));
"@ -Encoding utf8
    $wl = (& node $wlMjs 2>$null | Out-String) | ConvertFrom-Json
    Check 'ZG17-1 World line: the acceptance example, word for word' ($wl.full -eq 'World: 2 decisions ready, 1 question, 14 signals since yesterday; sweeps skipped 3x (RAM)') $wl.full
    Check 'ZG17-1 World line: the same words as the push (lobe.ps1 Format-WorldLine, pinned in Test-LobeStation)' ($wl.push -eq 'World: 2 decisions ready, 14 signals since yesterday; sweeps skipped 3x (RAM)') $wl.push
    Check 'ZG17-1 World line: zero counts show nothing; all zero, no lobe or no file is no line' ($wl.zero -eq '' -and $wl.none -eq '' -and $wl.noSkipFile -eq 'World: 1 decision ready')
    Check 'ZG17-1 World line: kinds by count, then RAM, Ollama, graphics card; rem alone says rem runs' ($wl.mixed -eq 'World: runs skipped 3x (Ollama, RAM)' -and $wl.remOnly -eq 'World: rem runs skipped 1x (graphics card)') "$($wl.mixed) | $($wl.remOnly)"
    Check 'ZG17-1 World line: anything but a whole positive number says nothing (no words pass through)' ($wl.words -eq '') $wl.words
    Check 'ZG17-1 app.js: the brief shows the World line from brief().lobe and lobeSkips, escaped, and the red ZG-13 line only when the frame is skipped' ($appJs -match "import \{ worldLine \} from './world-line\.js'" -and $appJs -match 'const wl = worldLine\(\{ \.\.\.b\.lobe, skips: b\.lobeSkips \}\); if \(wl\) lines\.push\(`<li[^\n]*<b>World:</b> \$\{esc\(wl\.slice\(7\)\)\}' -and $appJs -match 'if \(b\.lobe\?\.skipped\) \{ const lobeLine = briefLobeLine\(b\.lobe\)' -and (Get-Content (Join-Path $repo 'pass-app\public\sw.js') -Raw) -match "'/world-line\.js'")
    if ($env:ZEITGEISTD_HOME) { Write-Host 'SKIP: ZG17-1 brief skips: ZEITGEISTD_HOME is set here, so the server reads a lobe home this test must not write' }
    else {
        $ycDir = Join-Path $root 'lobe'; New-Item -ItemType Directory -Force -Path $ycDir | Out-Null; $ycFile = Join-Path $ycDir 'yard-counts.json'
        $nowU = [DateTime]::UtcNow
        @{ skips = @(
                @{ at = $nowU.AddHours(-1).ToString('o'); cmd = 'sweep'; kind = 'ram' }, @{ at = $nowU.AddHours(-3).ToString('o'); cmd = 'sweep'; kind = 'ram' },
                @{ at = $nowU.AddHours(-2).ToString('o'); cmd = 'rem'; kind = 'gpu'; why = 'ZG17-REASON-TEXT free RAM 100 MB' },
                @{ at = $nowU.AddHours(-25).ToString('o'); cmd = 'sweep'; kind = 'ram' }, @{ at = $nowU.ToString('o'); cmd = 'sweep'; kind = 'disk' }, @{ at = 'not a time'; cmd = 'sweep'; kind = 'ram' })
            push = @{ line = 'World: 1 decision ready'; at = $nowU.ToString('o') } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ycFile -Encoding utf8
        $bRaw = (Invoke-WebRequest "$base/api/brief" -Headers $auth).Content; $bSk = ($bRaw | ConvertFrom-Json).data.lobeSkips
        Check 'ZG17-1 brief(): skips in the last 24 h by command and kind; old, unknown-kind and timeless lines are left out' ($bSk.sweep -eq 2 -and $bSk.rem -eq 1 -and $bSk.ram -eq 2 -and $bSk.gpu -eq 1 -and $bSk.ollama -eq 0) ($bSk | ConvertTo-Json -Compress)
        Check 'ZG17-1 brief(): only numbers go out (no reason text from the file)' ($bRaw -notmatch 'ZG17-REASON-TEXT' -and $bRaw -notmatch 'free RAM 100')
        Set-Content -LiteralPath $ycFile -Value 'not json'
        Check 'ZG17-1 brief(): an unreadable counts file is null, never made-up zeros' ($null -eq ((Invoke-RestMethod "$base/api/brief" -Headers $auth).data.lobeSkips))
    }

    # approve all: plain step gates are never batched, each needs its own look
    $ga = [regex]::Match((& $k add -Name 'batch a' -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } -Approve) -join ' ', 'added (J\d+)').Groups[1].Value
    $gb = [regex]::Match((& $k add -Name 'batch b' -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } -Approve) -join ' ', 'added (J\d+)').Groups[1].Value
    & $k tick -Quiet | Out-Null
    $stB = (Invoke-RestMethod "$base/api/state" -Headers $auth).jobs
    $items = @($gb, $ga | ForEach-Object { $x = $_; @{ id = $x; approval = [string]@($stB | Where-Object id -eq $x)[0].approval.id } })
    $all = Act @{ op = 'approve-all'; items = $items }
    Check 'approve all: step gates are skipped, never signed off in a batch' (-not $all.ok -and @($all.data.approved).Count -eq 0 -and @($all.data.skipped).Count -eq 2)
    Check 'approve all: each step gate still signs off on its own, with its ask id' ((Act @{ op = 'approve'; id = $ga; approval = $items[1].approval }).ok)

    # merge gates: the state says which gate it is and what the change touches; a protected file is never batched
    $nowM = (Get-Date).ToUniversalTime().ToString('o')
    # Chef measures the change with git (main's merge base to kitchen/<id>), never the worktree's DIFF.patch, which AI code can rewrite:
    # each gate gets a real branch in a scratch repo, and a DIFF.patch that lies (it always claims README.md only)
    $gr = "$root-gate-repo"
    if (-not (Test-Path $gr)) {
        New-Item -ItemType Directory -Force "$gr\kitchen" | Out-Null; & git -C $gr init -q -b main 2>&1 | Out-Null
        foreach ($p in 'kitchen/automerge.ps1', 'README.md') { [IO.File]::WriteAllText((Join-Path $gr $p), "old`n") }
        & git -C $gr -c user.name=t -c user.email=t@localhost add -A 2>&1 | Out-Null; & git -C $gr -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    }
    function Gate($id, $file, $script, $text) {
        & git -C $gr checkout -q -B "kitchen/$id" main 2>&1 | Out-Null; [IO.File]::WriteAllText((Join-Path $gr $file), "new`nmore`n")
        & git -C $gr -c user.name=t -c user.email=t@localhost commit -q -am "change $id" 2>&1 | Out-Null; & git -C $gr checkout -q main 2>&1 | Out-Null
        $wk = Join-Path $root "worktrees\$id\.kitchen"; New-Item -ItemType Directory -Force $wk | Out-Null
        Set-Content (Join-Path $wk 'DIFF.patch') "diff --git a/README.md b/README.md`n--- a/README.md`n+++ b/README.md`n@@ -1 +1 @@`n-old`n+new" -Encoding utf8
        @{ id = $id; name = "improve: $id"; status = 'waiting-approval'; cursor = 0; attempt = 0; created = $nowM; history = @();
           steps = @(@{ script = $script; args = @{ Repo = $gr } }); approval = @{ id = 'A' + $id.Substring(1); text = $text; kind = 'gate' } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$id.json") -Encoding utf8
    }
    Gate 'J950' 'kitchen/automerge.ps1' 'C:\k\stations\merge.ps1' 'improve: J950: start step 1 of 1 (merge)'
    Gate 'J951' 'README.md' 'C:\k\stations\merge.ps1' 'improve: J951: start step 1 of 1 (merge)'
    Gate 'J952' 'README.md' 'C:\k\agent-step.ps1' 'improve: J952: start step 1 of 2'
    # git measures a gate in the background (it never stalls the live loop), so the first look can still say unknown: wait for it
    for ($i = 0; $i -lt 40; $i++) {
        $stG = (Invoke-RestMethod "$base/api/state" -Headers $auth).jobs
        $g950 = @($stG | Where-Object id -eq 'J950')[0]; $g951 = @($stG | Where-Object id -eq 'J951')[0]; $g952 = @($stG | Where-Object id -eq 'J952')[0]
        if ($g950.change -and -not $g950.change.unknown -and $g951.change -and -not $g951.change.unknown) { break }; Start-Sleep -Milliseconds 250
    }
    Check 'merge gate: state marks it and lists the protected file it touches' ($g950.approval.gate -eq 'merge' -and @($g950.change.protected) -contains 'kitchen/automerge.ps1' -and $g950.change.add -eq 2 -and $g950.change.del -eq 1)
    Check 'merge gate: an ordinary change has no protected file' ($g951.approval.gate -eq 'merge' -and @($g951.change.protected).Count -eq 0 -and $g951.change.files -eq 1 -and -not $g951.change.unknown)
    Check 'step gate: marked step, no change summary' ($g952.approval.gate -eq 'step' -and $null -eq $g952.change)
    # TD-EH-15: a merge gate whose last CI look failed shows why (results\<job>.ci.json {state error, error, at}); a good look shows nothing,
    # and a new look is seen without the job file changing
    New-Item -ItemType Directory -Force (Join-Path $root 'results') | Out-Null
    @{ job = 'J951'; state = 'error'; error = 'gh is not signed in to GitHub (run gh auth login)'; at = $nowM } | ConvertTo-Json | Set-Content (Join-Path $root 'results\J951.ci.json') -Encoding utf8
    @{ job = 'J952'; state = 'error'; error = 'not a merge gate'; at = $nowM } | ConvertTo-Json | Set-Content (Join-Path $root 'results\J952.ci.json') -Encoding utf8
    for ($i = 0; $i -lt 20; $i++) { $stC = (Invoke-RestMethod "$base/api/state" -Headers $auth).jobs; $c951 = @($stC | Where-Object id -eq 'J951')[0]; if ($c951.approval.ciLook) { break }; Start-Sleep -Milliseconds 250 }
    Check 'TD-EH-15: the Board merge gate carries the failed CI look reason and time' ($c951.approval.ciLook.error -eq 'gh is not signed in to GitHub (run gh auth login)' -and $c951.approval.ciLook.at)
    Check 'TD-EH-15: a step gate and a gate with no failed look carry none' (-not @($stC | Where-Object id -eq 'J952')[0].approval.ciLook -and -not @($stC | Where-Object id -eq 'J950')[0].approval.ciLook)
    @{ job = 'J951'; number = 1; state = 'green'; head = 'x'; allSuccess = $true; at = $nowM } | ConvertTo-Json | Set-Content (Join-Path $root 'results\J951.ci.json') -Encoding utf8
    for ($i = 0; $i -lt 20; $i++) { $c951 = @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object id -eq 'J951')[0]; if (-not $c951.approval.ciLook) { break }; Start-Sleep -Milliseconds 250 }
    Check 'TD-EH-15: a good look replaces it and the reason goes' (-not $c951.approval.ciLook)
    Check "TD-EH-15: app shows it on the gate's row and in the Approve box" ($appJs -match 'const ciLookMark = ' -and $appJs -match '\$\{ciLookMark\(j\)\}<div class="row-buttons">' -and $appJs -match "Couldn't read GitHub's checks: ")
    Remove-Item (Join-Path $root 'results\J951.ci.json'), (Join-Path $root 'results\J952.ci.json') -Force
    $mixed = Act @{ op = 'approve-all'; items = @(@{ id = 'J950'; approval = 'A950' }, @{ id = 'J952'; approval = 'A952' }) }
    Check 'approve all: a protected-file merge and a step gate are both skipped' (-not $mixed.ok -and (@($mixed.data.skipped) -join ',') -eq 'J950,J952')
    # "also these": with everything = true, Jordan's ticked list of protected merges and step gates is signed off; a stale ask id still is not
    $stale = Act @{ op = 'approve-all'; everything = $true; items = @(@{ id = 'J950'; approval = 'A99999' }) }
    Check 'approve all, everything: an ask id that is not the one shown is still skipped' (-not $stale.ok -and @($stale.data.skipped) -contains 'J950')
    # the real step gate left waiting above (batch b): a plain approve-all skips it; with everything = true it is signed off
    $gbAsk = [string]@((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object id -eq $gb)[0].approval.id
    $every = Act @{ op = 'approve-all'; everything = $true; items = @(@{ id = $gb; approval = $gbAsk }) }
    Check 'approve all, everything: a step gate he ticked is approved' ($every.ok -and @($every.data.approved) -contains $gb)
    Check 'app: Approve all shows for any ask, lists closer-look items with why, opt-in checkbox' ($appJs -match 'id="aa-more"' -and $appJs -match 'const closerLook = ' -and $appJs -match "everything: all")
    Remove-Item (Join-Path $root 'jobs\J950.json'), (Join-Path $root 'jobs\J951.json'), (Join-Path $root 'jobs\J952.json') -Force

    # clear-aside: set-aside tickets older than 24 h are closed (reason kept); fresh ones and other statuses are left alone
    $tOld = (Get-Date).AddDays(-3).ToUniversalTime().ToString('o'); $tNew = (Get-Date).AddHours(-1).ToUniversalTime().ToString('o')
    foreach ($c in @(@('J960', 'quarantined', $tOld), @('J961', 'killed', $tOld), @('J962', 'quarantined', $tNew), @('J963', 'done', $tOld))) {
        @{ id = $c[0]; name = "improve: $($c[0])"; status = $c[1]; cursor = 0; attempt = 0; created = $c[2]; history = @(@{ outcome = 'fail'; at = $c[2] });
           steps = @(@{ script = 'C:\k\agent-step.ps1'; args = @{} }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root "jobs\$($c[0]).json") -Encoding utf8
    }
    $ca = Act @{ op = 'clear-aside'; ids = @('J960', 'J961', 'J962', 'J963') }
    Check 'clear aside: only the old set-aside tickets are closed' ($ca.ok -and (@($ca.data.closed) -join ',') -eq 'J960,J961' -and (@($ca.data.skipped) -join ',') -eq 'J962,J963')
    Check 'clear aside: closed jobs say so; the fresh and the plated ones are untouched' ((Get-Content (Join-Path $root 'jobs\J960.json') -Raw | ConvertFrom-Json).status -eq 'closed' -and (Get-Content (Join-Path $root 'jobs\J961.json') -Raw | ConvertFrom-Json).status -eq 'closed' -and (Get-Content (Join-Path $root 'jobs\J962.json') -Raw | ConvertFrom-Json).status -eq 'quarantined' -and (Get-Content (Join-Path $root 'jobs\J963.json') -Raw | ConvertFrom-Json).status -eq 'done')
    Check 'clear aside: a job.closed event with the reason is kept' (@(Get-Content (Join-Path $root 'events.jsonl') | Where-Object { $_ -match '"job.closed"' -and $_ -match 'J960' -and $_ -match 'cleared by Jordan' }).Count -ge 1)
    Check 'clear aside: an empty list and a bad id are refused' (-not (Act @{ op = 'clear-aside'; ids = @() }).ok -and -not (Act @{ op = 'clear-aside'; ids = @('J1; rm -rf') }).ok)
    $ca2 = Act @{ op = 'clear-aside'; ids = @('J960', 'J961') }
    Check 'clear aside: a repeat finds nothing left to clear' (-not $ca2.ok -and (@($ca2.data.skipped) -join ',') -eq 'J960,J961')
    Remove-Item (Join-Path $root 'jobs\J960.json'), (Join-Path $root 'jobs\J961.json'), (Join-Path $root 'jobs\J962.json'), (Join-Path $root 'jobs\J963.json') -Force

    # recipe var limits: a full tailor posting (max 12000) goes through; over the max says so
    $long = 'é' * 7000
    $tl = Act @{ op = 'cook'; recipe = 'tailor'; vars = @{ posting = $long } }
    Check 'cook: a 7,000-character posting is accepted (recipe max 12000)' ($tl.ok -and $tl.data.job -match '^J\d+$')
    if ($tl.data.job) { Remove-Item (Join-Path $root "jobs\$($tl.data.job).json") -Force -ErrorAction SilentlyContinue }
    $tl2 = Act @{ op = 'cook'; recipe = 'tailor'; vars = @{ posting = ('x' * 12001) } }
    Check 'cook: over the recipe max names the var and the limit' (-not $tl2.ok -and $tl2.error -match "'posting' is longer than 12,000")

    # a multi-byte character split across two TCP chunks stays whole (the body is decoded once)
    $tcp = [Net.Sockets.TcpClient]::new('127.0.0.1', $port); $ns = $tcp.GetStream()
    $bodyB = [Text.Encoding]::UTF8.GetBytes('{"op":"note","text":"café für Jordan"}')
    $hdrB = [Text.Encoding]::ASCII.GetBytes("POST /api/lead HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nAuthorization: Bearer $key`r`nContent-Type: application/json`r`nContent-Length: $($bodyB.Length)`r`nConnection: close`r`n`r`n")
    $cut = [Array]::IndexOf($bodyB, [byte]0xC3) + 1
    $ns.Write($hdrB, 0, $hdrB.Length); $ns.Write($bodyB, 0, $cut); $ns.Flush(); Start-Sleep -Milliseconds 300; $ns.Write($bodyB, $cut, $bodyB.Length - $cut); $ns.Flush()
    $null = [IO.StreamReader]::new($ns).ReadToEnd(); $tcp.Dispose()
    Check 'body: a character split across chunks is not garbled' (@((Invoke-RestMethod "$base/api/lead" -Headers $auth).data.notes | Where-Object { $_.text -eq 'café für Jordan' }).Count -eq 1)

    # lead.json: one writer at a time (lead.json.lock, shared with lead.ps1); an unreadable lead.json is refused, never replaced
    $lockP = Join-Path $root 'lead.json.lock'; Set-Content $lockP 'held'
    $lc = [Net.Http.HttpClient]::new(); $lc.DefaultRequestHeaders.Add('Authorization', "Bearer $key")
    $pending = $lc.PostAsync("$base/api/lead", [Net.Http.StringContent]::new('{"op":"note","text":"while locked"}', [Text.Encoding]::UTF8, 'application/json'))
    Start-Sleep -Milliseconds 900
    Check 'lead lock: Chef waits while lead.ps1 holds the lock' (-not $pending.IsCompleted)
    $lj = Start-Job { param($ps, $r) $env:BRAIN_KITCHEN = $r; & pwsh -NoProfile -File $ps handoff -Text 'handoff while locked' } -ArgumentList (Join-Path $repo 'kitchen\lead.ps1'), $root
    Start-Sleep -Milliseconds 1500
    Check 'lead lock: lead.ps1 waits too' ((Get-Content (Join-Path $root 'lead.json') -Raw) -notmatch 'handoff while locked')
    Remove-Item $lockP -Force
    $lr = $pending.GetAwaiter().GetResult().Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json; $null = Receive-Job $lj -Wait -AutoRemoveJob; $lc.Dispose()
    $lv2 = (Invoke-RestMethod "$base/api/lead" -Headers $auth).data
    Check 'lead lock: both writes land once the lock is free' ($lr.ok -and @($lv2.notes | Where-Object text -eq 'while locked').Count -eq 1 -and $lv2.handoff.text -eq 'handoff while locked')
    $leadGood = Get-Content (Join-Path $root 'lead.json') -Raw; Set-Content (Join-Path $root 'lead.json') '{ broken'
    Check 'lead: a broken lead.json is refused, never overwritten' (-not (LeadPost @{ op = 'note'; text = 'should not save' }).ok -and (Get-Content (Join-Path $root 'lead.json') -Raw).Trim() -eq '{ broken')
    Set-Content (Join-Path $root 'lead.json') $leadGood -NoNewline

    # live streams: a full house evicts the oldest instead of answering 503; the stream carries a real ping event
    Check 'stream: a ping event every 25 s (not only a comment)' ($serverSrc -match "broadcast\('ping'" -and $serverSrc -match 'SSE_MAX_BUFFER' -and $serverSrc -notmatch 'too many live connections')
    $sc = [Net.Http.HttpClient]::new(); $sc.DefaultRequestHeaders.Add('Authorization', "Bearer $key"); $sc.Timeout = [TimeSpan]::FromSeconds(30)
    $streams = @(1..21 | ForEach-Object { $req = [Net.Http.HttpRequestMessage]::new('GET', "$base/api/stream"); $sc.SendAsync($req, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult() })
    Check 'stream: the 21st phone gets in (200)' ([int]$streams[-1].StatusCode -eq 200)
    $first = $streams[0].Content.ReadAsStreamAsync().GetAwaiter().GetResult(); $bufS = [byte[]]::new(65536); $ended = $false; $swS = [Diagnostics.Stopwatch]::StartNew()
    while ($swS.Elapsed.TotalSeconds -lt 8) { $t = $first.ReadAsync($bufS, 0, $bufS.Length); try { if (-not $t.Wait(8000)) { break } } catch { $ended = $true; break }; if ($t.Result -eq 0) { $ended = $true; break } }   # a reset (destroyed socket) counts as closed
    Check 'stream: the oldest stream was closed to make room' $ended
    $streams | ForEach-Object { $_.Dispose() }; $sc.Dispose()

    # the phone app (pass-app/public): what it sends, what it shows, and what it never puts on a lock screen
    $appJs = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw; $swJs = Get-Content (Join-Path $repo 'pass-app\public\sw.js') -Raw
    $appCss = Get-Content (Join-Path $repo 'pass-app\public\app.css') -Raw; $mf = Get-Content (Join-Path $repo 'pass-app\public\manifest.webmanifest') -Raw | ConvertFrom-Json
    # the real helpers, run in node: ticket() can't carry markup; Approve all takes only clean merge gates
    $probe = Join-Path $root 'probe.mjs'
    $lines = @($appJs -split "`r?`n" | Where-Object { $_ -match '^const (esc|ticket|jobIdOf|STATUS_LABEL|statusLabel|jobLink|PROTECTED|BATCH|ASIDE|since|OLD_ASIDE|SNAP|HYDRATE|HYDRATE_BRIEF|BOOT|OFFLINE_TEXT) = ' })
    $notifyRe = [regex]::Match($appJs, 'showNotification\((/\^[^/]*\$/)\.test\(').Groups[1].Value
    $sceneUrl = ([uri](Join-Path $repo 'pass-app\public\scene.js')).AbsoluteUri
    Set-Content $probe ("import { activityWord } from '$sceneUrl';`n" + ($lines -join "`n") + "`nconst NOTIFY_RE = $notifyRe;" + @'

const g = (o) => ({ status: 'waiting-approval', approval: { id: 'A1', kind: 'gate', gate: 'merge' }, change: { files: 1, add: 1, del: 0, protected: [] }, ...o });
const out = {
  ticket: ticket('<button data-set="lead-toggle">x</button>'), link: jobLink('J7'), badLink: jobLink('x" onclick="y'),
  wo: [ticket('J207'), jobIdOf('WO-207'), jobIdOf('WO-0207'), jobIdOf('wo-0207'), jobIdOf('J207'), jobIdOf('WO-x'), jobIdOf('WO-')],
  labels: [['pending'], ['waiting-approval'], ['needs-human'], ['done'], ['quarantined'], ['failed'], ['killed'], ['closed'], ['weird'], ['running:inspection']].map(([s]) => statusLabel({ status: s })),
  running: [statusLabel({ status: 'running', station: 'agent', role: 'do' }), statusLabel({ status: 'running', station: 'tests' }), statusLabel({ status: 'running', station: 'verify' }), statusLabel({ status: 'running', station: 'agent', role: 'check' }),
    statusLabel({ status: 'running', step: 2, steps: [{ station: 'agent', role: 'do' }, { station: 'verify' }] }), statusLabel({ status: 'running', step: 1, steps: [{ station: 'agent', role: 'do' }, { station: 'verify' }] })],
  alert: [NOTIFY_RE.test(ticket('J207') + ' needs your sign-off'), NOTIFY_RE.test('WO-0207 needs your sign-off'), NOTIFY_RE.test('#0207 needs your sign-off'), NOTIFY_RE.test('<b>x</b> needs your sign-off'), NOTIFY_RE.test('WO-0207 my secret words needs your sign-off'), NOTIFY_RE.test('WO-0207 needs your sign-off<img src=x>')],
  clean: BATCH(g({})), prot: BATCH(g({ change: { files: 1, protected: ['kitchen/automerge.ps1'] } })), unknown: BATCH(g({ change: { unknown: true, protected: [] } })),
  step: BATCH(g({ approval: { id: 'A2', kind: 'gate', gate: 'step' } })), hold: BATCH(g({ approval: { id: 'A3', kind: 'hold', gate: 'merge' } })), noChange: BATCH(g({ change: null })),
  oldQ: OLD_ASIDE({ status: 'quarantined', updated: new Date(Date.now() - 3 * 864e5).toISOString() }), oldK: OLD_ASIDE({ status: 'killed', updated: new Date(Date.now() - 3 * 864e5).toISOString() }),
  freshQ: OLD_ASIDE({ status: 'quarantined', updated: new Date(Date.now() - 36e5).toISOString() }), oldDone: OLD_ASIDE({ status: 'done', updated: new Date(Date.now() - 3 * 864e5).toISOString() }),
  off5: OFFLINE_TEXT(Date.now() - 5 * 60000), off3h: OFFLINE_TEXT(Date.now() - 3 * 36e5), offNone: OFFLINE_TEXT(0), offNow: OFFLINE_TEXT(Date.now() - 5000),
  snap: SNAP({ at: 'x1', recvAt: 5, jobs: [{ id: 'J1', tail: ['a'], activity: [{ kind: 'b' }] }] }),
  hyd: [HYDRATE(null), HYDRATE('text'), HYDRATE({}), HYDRATE({ jobs: 'x' })].map((v) => v === null), hydOk: HYDRATE({ jobs: [] }) !== null,
  corrupt: (() => { let v; try { v = HYDRATE(JSON.parse('{oops')); } catch { v = null; } return v === null; })(),
  badJobs: [HYDRATE({ jobs: [null] }), HYDRATE({ jobs: [{ name: 'no id' }] }), HYDRATE({ jobs: ['J1'] })].map((v) => v === null),
  briefBad: [HYDRATE_BRIEF(null), HYDRATE_BRIEF({}), HYDRATE_BRIEF({ needsYou: [] }), HYDRATE_BRIEF('x')].map((v) => v === null),
  briefOk: HYDRATE_BRIEF({ needsYou: [], plated: [], setAside: [], followUps: [] }) !== null,
  // the boot with a fake storage and no fetch at all: the board and the brief are there before anything is asked of the server
  bootNoFetch: (() => { const had = globalThis.fetch; globalThis.fetch = () => { throw new Error('fetch at boot'); };
    try { const st = { lastState: { jobs: [{ id: 'J1', status: 'running' }] }, lastStateAt: 123, lastBrief: { needsYou: [], plated: [], setAside: [], followUps: [] } };
      const b = BOOT((k, d) => (k in st ? st[k] : d)); return { jobs: b.state.jobs.length, at: b.savedAt, stale: b.stale, brief: b.brief !== null }; } finally { globalThis.fetch = had; } })(),
  bootEmpty: (() => { const b = BOOT((k, d) => d); return { state: b.state, stale: b.stale, brief: b.brief }; })(),
  // a hydrated job has no tail and no activity: the cook's activity line must not throw
  actNone: [activityWord({ id: 'J1', status: 'running' }), activityWord({ activity: null }), activityWord({ activity: [] }), activityWord(undefined)],
};
console.log(JSON.stringify(out));
'@) -Encoding utf8
    $pr = (& node $probe | Out-String) | ConvertFrom-Json
    Check 'app: ticket() output carries no markup' ($pr.ticket -notmatch '[<>"''= ]' -and $pr.link -eq '<a href="#/job/J7">WO-0007</a>' -and $pr.badLink -notmatch '<a|"')
    Check 'app: ticket J207 shows WO-0207; WO-207, WO-0207 and J207 all open J207; anything else passes through to the J check' ((@($pr.wo) -join ',') -eq 'WO-0207,J207,J207,J207,J207,WO-x,WO-')
    Check 'app: route() maps a WO- number to J before the J-number check' ($appJs -match "const \[a, b0\] = location\.hash" -and $appJs -match "const b = a === 'job' \? jobIdOf\(b0\) : b0;" -and $appJs -match "if \(a === 'job' && /\^J\\d\+\$/\.test\(b \|\| ''\)\)")
    Check 'labels: one table for every stored job status; failed and unknown values handled' ((@($pr.labels) -join ',') -eq 'Queued,Needs sign-off,Needs sign-off,Handed over,Failed,Failed,Stopped,Closed out,weird,running:inspection')
    Check 'labels: running shows Inspection on the tests, verify and taster (check) steps, Building otherwise' ((@($pr.running) -join ',') -eq 'Building,Inspection,Inspection,Inspection,Inspection,Building')
    Check 'labels: lanes, pill, verdict and summary read the table; no old lane words left' ($appJs -match "title: L\['waiting-approval'\]" -and $appJs -match 'title: L\.running' -and $appJs -match 'title: L\.pending' -and $appJs -match 'title: L\.done' -and $appJs -match 'esc\(statusLabel\(j\)\)\}`\];' -and $appJs -match "const verdict = j\.status === 'done' && j\.autoMerged \? 'Merged on its own' : statusLabel\(j\);" -and $appJs -notmatch "'✓ Plated'|title: 'Plated'|title: 'Set aside'|title: 'On the rail'|title: 'Cooking'|'Still cooking'")
    Check 'labels: the job-hunt statuses keep their own words (not the job table)' ($appJs -match "const STATUS_WORD = \{ saved: 'Saved', applied: 'Applied', interview: 'Interviewing', offer: 'Offer', rejected: 'Not this time', closed: 'Closed' \};" -and $appJs -match 'STATUS_WORD\[x\.status\] \|\| x\.stat' -and $appJs -notmatch 'statusLabel\(x\)')
    Check 'alerts: the filter lets WO-0207 sign-off titles through and drops markup or extra words' ((@($pr.alert) -join ',') -eq 'True,True,True,False,False,False')
    Check 'app: Approve all takes a clean merge gate only (not protected, unreadable, step gates or holds)' ($pr.clean -and -not $pr.prot -and -not $pr.unknown -and -not $pr.step -and -not $pr.hold -and -not $pr.noChange)
    Check 'app: approve sends the approval id shown; approve all sends items with it' ($appJs -match "op: 'approve', id, approval: asked" -and $appJs -match "op: 'approve-all', items: (list|pick)\.map\(\(j\) => \(\{ id: j\.id, approval: j\.approval\.id \}\)\)" -and $appJs -notmatch "ids: list\.map")
    Check 'app: Clear old takes set-aside tickets older than a day only' ($pr.oldQ -and $pr.oldK -and -not $pr.freshQ -and -not $pr.oldDone)
    Check 'app: Clear old button confirms, then sends the ids shown' ($appJs -match 'id="clear-aside"' -and $appJs -match "op: 'clear-aside', ids\b" -and $appJs -match 'Clear old \(' -and $appJs -match '(?s)async function clearAside.*?confirmBox')
    Check 'app: protected-file changes are marked in the confirm list and on the row' ($appJs -match 'const protectedMark = ' -and ([regex]::Matches($appJs, 'protectedMark\(j\)')).Count -ge 3 -and $appCss -match '\.prot-mark\{')
    Check 'app: event numbers are coerced before they reach the markup' ($appJs -match 'Number\(e\.inSec\)' -and $appJs -match 'Number\(e\.step\)' -and $appJs -notmatch '\$\{e\.inSec\}' -and $appJs -notmatch '\$\{e\.step \+ 1\}')
    # Android has no new Notification(): alerts go through the service worker, with no order words on the lock screen
    Check 'alerts: through the service worker, generic body, no new Notification' ($appJs -match 'serviceWorker\?\.ready\.then\(\(r\) => r\.showNotification\(' -and $appJs -match "body: 'Open the Board'" -and $appJs -notmatch 'new Notification\(' -and $appJs -notmatch 'notify\([^)]*approval\?\.text' -and $appJs -notmatch "notify\('Kitchen', e\.text")
    # the lock-screen title is a generic ticket notice: the caller never passes ask text, names or private fields, and notify() whitelists the title
    $needsCall = [regex]::Match($appJs, 'notify\(`\$\{ticket\(j\.id\)\} needs your sign-off`, ''need-'' \+ j\.id\)')
    Check 'alerts: the needs-approval caller passes only the ticket and generic sign-off words' ($needsCall.Success)
    Check 'alerts: notify() drops any title that is not a ticket sign-off notice' ($appJs -match [regex]::Escape('/^[\w# -]{1,20} needs your sign-off$/.test(String(title)) ? String(title) : ''The Board needs your sign-off''') -and $appJs -notmatch 'showNotification\(String\(title\)\.slice')
    Check 'alerts: a tap opens Chef (notificationclick)' ($swJs -match "addEventListener\('notificationclick'" -and $swJs -match "openWindow\('/#/pass'\)")
    # a dead stream is noticed and replaced; missed events are fetched; an offline first load says so
    Check 'stream: the app listens for ping, watches for silence, reconnects on wake and backfills' ($appJs -match "addEventListener\('ping'" -and $appJs -match '> 60000' -and $appJs -match "addEventListener\('visibilitychange', wake\)" -and $appJs -match "addEventListener\('pageshow', wake\)" -and $appJs -match "api\('/api/events\?n=400'\)" -and $appJs -match 'clearTimeout\(S\.retryT\)')
    Check 'offline: a clear card instead of an endless skeleton; the pulse does not claim a board it never had' ($appJs -match 'function offlineCard\(' -and $appJs -match 'offlineCard\(\) \|\| ''<div class="skeleton"' -and $appJs -match 'S\.state \? OFFLINE_TEXT\(S\.savedAt\) : ''Offline''')
    Check 'offline: the pulse says how old the saved board is' ($pr.off5 -match 'board from 5m ago' -and $pr.off3h -match '3h ago' -and $pr.offNow -match 'just now' -and $pr.offNone -match '^Offline.*showing the last known board$' -and $pr.offNone -notmatch 'board from')
    Check 'offline: the stored snapshot drops tails, activity and recvAt but keeps the board' ($pr.snap.at -eq 'x1' -and $pr.snap.jobs[0].id -eq 'J1' -and $null -eq $pr.snap.jobs[0].tail -and $null -eq $pr.snap.jobs[0].activity -and $null -eq $pr.snap.recvAt)
    Check 'offline: stored junk or a corrupt value boots to no board, a real one hydrates' ((@($pr.hyd | Where-Object { $_ }).Count -eq 4) -and $pr.hydOk -and $pr.corrupt -and (@($pr.badJobs | Where-Object { $_ }).Count -eq 3))
    Check 'offline: a stored brief missing a list it renders is dropped, a whole one is kept' ((@($pr.briefBad | Where-Object { $_ }).Count -eq 4) -and $pr.briefOk)
    Check 'offline: boot with no fetch fills the board (stale, with its age) and the brief; empty storage fills nothing' ($pr.bootNoFetch.jobs -eq 1 -and $pr.bootNoFetch.at -eq 123 -and $pr.bootNoFetch.stale -and $pr.bootNoFetch.brief -and $null -eq $pr.bootEmpty.state -and -not $pr.bootEmpty.stale -and $null -eq $pr.bootEmpty.brief)
    Check 'offline: a hydrated job with no tail or activity cannot throw (activity word, floor line, live call, cook tile all guard it)' ((@($pr.actNone | Where-Object { $_ -ne '' }).Count -eq 0) -and $liveJs -match 'Array\.isArray\(j\.tail\) \? j\.tail : \[\]' -and $liveJs -match "\(j\?\.activity \|\| \[\]\)\.filter" -and $appJs -match "\(j\.activity \|\| \[\]\)\.slice\(-1\)\[0\]")
    Check 'offline: the boot hydrates from storage, then the first renderAll draws the pass and the brief (no fetch needed)' ($appJs -match "Object\.assign\(S, BOOT\(\(k, d\) => store\.get\(k, d\)\)\)" -and $appJs.IndexOf('Object.assign(S, BOOT(') -ge 0 -and $appJs.IndexOf('Object.assign(S, BOOT(') -lt $appJs.IndexOf('route(); renderAll(); connect()') -and $appJs -match "(?s)function renderAll\(\).*?changed\('brief', \[S\.brief, S\.briefOpen\]\)\) renderBrief\(\)")
    Check 'offline: each receipt is saved for the next cold start' ($appJs -match "store\.set\('lastState', SNAP\(s\)\)" -and $appJs -match "store\.set\('lastStateAt'" -and $appJs -match "store\.set\('lastBrief', r\.data\)")

    Check 'offline: a stale board shows no supervisor banners and the 8 s timer still reaches offline' ($appJs -match 'const s = S\.stale \? null : S\.state' -and $appJs -match '\(!S\.state \|\| S\.stale\) && S\.conn')
    Check 'offline: the service worker answers from the cache after 3 s of no reply' ($swJs -match 'setTimeout\(resolve, 3000\)' -and $swJs -match 'Promise\.race\(\[net, slow\]\)')
    Check 'manifest: the install keeps its id and scope (a changed id would be a new app on the phone); the name is The Board' ($mf.id -eq '/' -and $mf.scope -eq '/' -and $mf.name -eq 'The Board' -and $mf.short_name -eq 'The Board')
    Check 'manifest: start_url and shortcuts are real routes' ($mf.start_url -eq '/#/pass' -and (@($mf.shortcuts.url) -join ',') -eq '/#/pass/needs,/#/talk,/#/cooks,/#/activity' -and $appJs -match "b === 'needs'")
    Check 'touch: one-tap actions are at least 44px; the status picker confirms' ($appCss -match '\.seg button,\.banner \.btn,\.toast button,\.lock-chip,\.dish-head \.text-btn\{min-height:44px\}' -and $appCss -match '\.headline-sub a\{min-height:44px\}' -and $appJs -match 'title: `Mark \$\{STATUS_WORD\[st\.dataset\.st\]')
    # the job hunt: wave 1's server fields reach the screen
    Check 'hunt: a failed or unchecked draft shows a red banner, never ready' ($appJs -match "chk === 'fail' \? 'This draft failed the tailor check\.'" -and $appJs -match 'It is not ready to send' -and $appJs -match "\['check', 'Tailor check'\]")
    Check 'hunt: the brief lists drafts that need a look' ($appJs -match 'b\.packsNeedLook\?\.length')
    Check 'hunt: a draft order that could not be placed says so' ($appJs -match 'x\.draftError')
    Check 'hunt: edits send changedAt (no overwriting another phone)' (([regex]::Matches($appJs, 'changedAt: changedAt\(')).Count -ge 4)
    Check 'hunt: an unreadable tracker shows the error and drops the old list' ($appJs -match "S\.hunt\.data = r\.ok \? r\.data : null" -and $appJs -match "The job list can't be read right now")
    # a second Chef on a taken port exits (code 1) instead of staying alive with no listener
    $psi2 = [Diagnostics.ProcessStartInfo]::new('node', "`"$(Join-Path $repo 'pass-app\server.mjs')`""); $psi2.UseShellExecute = $false; $psi2.CreateNoWindow = $true; $psi2.RedirectStandardError = $true; $psi2.RedirectStandardOutput = $true
    $dup = [Diagnostics.Process]::Start($psi2)
    $exited = $dup.WaitForExit(15000); if (-not $exited) { $dup.Kill() }
    Check 'listen: a taken port makes Chef exit with code 1' ($exited -and $dup.ExitCode -eq 1)

    # the pass key: replacing pass-key.txt cuts the old key off at once, with no restart; a malformed file accepts no key
    $newKey = -join (1..64 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
    Set-Content (Join-Path $root 'pass-key.txt') $newKey -NoNewline
    Check 'key: the old key stops working without a restart' ((Get-Code "$base/api/state" $auth) -eq 401 -and (Get-Code "$base/api/state" @{ Authorization = "Bearer $newKey" }) -eq 200)
    Set-Content (Join-Path $root 'pass-key.txt') 'not-a-key' -NoNewline
    Check 'key: a malformed key file accepts nothing (fail closed)' ((Get-Code "$base/api/state" @{ Authorization = "Bearer $newKey" }) -eq 401)
    Set-Content (Join-Path $root 'pass-key.txt') $key -NoNewline

    # only localhost
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Select-Object -First 1).IPAddress
    if ($ip) { Check 'not reachable on the LAN address' ((Get-Code "http://${ip}:$port/manifest.webmanifest") -eq -1) }

    # speed (10-22): compressed app files and answers, one compressor per live stream, job files read again only when they change
    $hh = [Net.Http.HttpClientHandler]::new(); $hh.AutomaticDecompression = [Net.DecompressionMethods]::None; $hc = [Net.Http.HttpClient]::new($hh)
    function Raw($p, $enc) {
        $m = [Net.Http.HttpRequestMessage]::new('GET', "$base$p"); [void]$m.Headers.TryAddWithoutValidation('Authorization', "Bearer $key"); if ($enc) { [void]$m.Headers.TryAddWithoutValidation('Accept-Encoding', $enc) }
        $r = $hc.SendAsync($m).GetAwaiter().GetResult()
        @{ enc = [string]($r.Content.Headers.ContentEncoding -join ','); vary = [string]($r.Headers.Vary -join ','); bytes = $r.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() }
    }
    function Unbr([byte[]]$b) { $s = [IO.Compression.BrotliStream]::new([IO.MemoryStream]::new($b), [IO.Compression.CompressionMode]::Decompress); $o = [IO.MemoryStream]::new(); $s.CopyTo($o); , $o.ToArray() }
    function Ungz([byte[]]$b) { $s = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new($b), [IO.Compression.CompressionMode]::Decompress); $o = [IO.MemoryStream]::new(); $s.CopyTo($o); , $o.ToArray() }
    $plainJs = [IO.File]::ReadAllBytes((Join-Path $repo 'pass-app\public\app.js')); $b64 = [Convert]::ToBase64String($plainJs)
    $brJs = Raw '/app.js' 'gzip, deflate, br'
    Check 'speed: app.js is sent brotli to a browser that takes it, under half the size, and unpacks to the exact file' ($brJs.enc -eq 'br' -and $brJs.bytes.Length -lt $plainJs.Length / 2 -and [Convert]::ToBase64String((Unbr $brJs.bytes)) -eq $b64 -and $brJs.vary -match 'Accept-Encoding')
    Start-Sleep -Milliseconds 1500; $brJs2 = Raw '/app.js' 'br'
    Check 'speed: the smallest copy made in the background replaces the fast one and is still the exact file' ($brJs2.bytes.Length -le $brJs.bytes.Length -and [Convert]::ToBase64String((Unbr $brJs2.bytes)) -eq $b64)
    $gzJs = Raw '/app.js' 'gzip'; $none = Raw '/app.js' $null
    Check 'speed: gzip for a gzip-only browser, the plain file when none is offered' ($gzJs.enc -eq 'gzip' -and [Convert]::ToBase64String((Ungz $gzJs.bytes)) -eq $b64 -and $none.enc -eq '' -and $none.bytes.Length -eq $plainJs.Length)
    Check 'speed: the font (compressed already) is sent as it is' ((Raw '/jetbrains-mono.woff2' 'br').enc -eq '')
    $stRaw = Raw '/api/state' 'br'; $stJson = [Text.Encoding]::UTF8.GetString((Unbr $stRaw.bytes)) | ConvertFrom-Json
    Check 'speed: the state answer is compressed and unpacks to whole JSON' ($stRaw.enc -eq 'br' -and @($stJson.jobs).Count -ge 1)
    $hc.Dispose()
    $sseJs = "import http from 'node:http'; import zlib from 'node:zlib'; const t = setTimeout(() => { console.log('timeout'); process.exit(0); }, 8000);" +
        "http.get('$base/api/stream', { headers: { Authorization: 'Bearer $key', 'Accept-Encoding': 'br' } }, (res) => { const enc = res.headers['content-encoding']; let s = '';" +
        "res.pipe(zlib.createBrotliDecompress()).on('data', (d) => { s += d; if (s.includes('event: state') && s.includes('\n\n', s.indexOf('event: state'))) { console.log(enc + ' ' + (s.indexOf('`"jobs`"') > 0)); clearTimeout(t); process.exit(0); } }); });"
    $sseOut = ($sseJs | & node --input-type=module - 2>&1 | Select-Object -Last 1)
    Check 'speed: the live stream is brotli, flushed per message (the first state arrives whole without closing the stream)' ([string]$sseOut -eq 'br True')
    # job cache: a new, changed or deleted job file shows in the state; the live loop hears of it from Windows, the state call stats
    $jf = Join-Path $root 'jobs\J900.json'
    function J900 { @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs | Where-Object id -eq 'J900') }
    @{ id = 'J900'; name = 'cache probe one'; status = 'done'; cursor = 0; steps = @(); history = @() } | ConvertTo-Json -Depth 4 | Set-Content $jf -Encoding utf8
    $seen = $false; for ($i = 0; $i -lt 20 -and -not $seen; $i++) { $seen = (J900).name -eq 'cache probe one'; if (-not $seen) { Start-Sleep -Milliseconds 250 } }
    Check 'job cache: a new job file is in the state' $seen
    @{ id = 'J900'; name = 'cache probe two'; status = 'done'; cursor = 0; steps = @(); history = @() } | ConvertTo-Json -Depth 4 | Set-Content $jf -Encoding utf8
    $seen = $false; for ($i = 0; $i -lt 20 -and -not $seen; $i++) { $seen = (J900).name -eq 'cache probe two'; if (-not $seen) { Start-Sleep -Milliseconds 250 } }
    Check 'job cache: a changed job file is read again' $seen
    Remove-Item $jf
    $gone = $false; for ($i = 0; $i -lt 20 -and -not $gone; $i++) { $gone = @(J900).Count -eq 0; if (-not $gone) { Start-Sleep -Milliseconds 250 } }
    Check 'job cache: a deleted job file leaves the state' $gone

    # Since You Looked (2.6.1): counts from events.jsonl since the phone's last look; the events here are 10+ minutes ahead of the
    # rest of this run, so nothing earlier in the suite falls inside the window
    $sjDir = Join-Path $root 'jobs'; $ev = Join-Path $root 'events.jsonl'; $t0 = [DateTime]::UtcNow.AddMinutes(10)
    function SJob($id, $status, $hist = @(), $more = @{}) { (@{ id = $id; name = "since probe $id"; status = $status; cursor = 1; attempt = 0; created = $t0.ToString('o'); history = $hist; steps = @(@{ script = 'pr.ps1'; args = @{} }, @{ script = 'ci-wait.ps1'; args = @{} }) } + $more) | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $sjDir "$id.json") -Encoding utf8 }
    function SEv($sec, $type, $job, $extra = '') { Add-Content -LiteralPath $ev -Value ('{"ts":"' + $t0.AddSeconds($sec).ToString('o') + '","type":"' + $type + '","job":"' + $job + '"' + $extra + '}') -Encoding utf8 }
    SJob 'J601' 'done'; SJob 'J602' 'quarantined'; SJob 'J603' 'waiting-approval'; SJob 'J604' 'pending'
    SJob 'J605' 'needs-human' @() @{ vars = @{ goal = 'my secret health note'; private = 'yes' } }
    SEv -5 'job.done' 'J600'                                   # before the look: not counted
    SEv 1 'job.done' 'J601'; SEv 2 'job.quarantined' 'J602'; SEv 3 'job.quarantined' 'J602'   # set aside twice: one ticket
    SEv 4 'approval.requested' 'J603' ',"text":"merge it?"'; SEv 5 'approval.requested' 'J604' ',"text":"old ask"'   # J604 no longer waits
    SEv 6 'step.hold' 'J605' ',"detail":"my secret health note"'
    $tq = [uri]::EscapeDataString($t0.ToString('o'))
    $sv = (Invoke-RestMethod "$base/api/since?t=$tq" -Headers $auth).data
    Check 'since: plated, set aside and needs-you since the look, each ticket once, nothing from before' ($sv.known -and (@($sv.plated) -join ',') -eq 'J601' -and (@($sv.setAside) -join ',') -eq 'J602' -and (@($sv.needsYou | Sort-Object) -join ',') -eq 'J603,J605')
    Check 'since: an ask that no longer waits is not counted as needing you' (@($sv.needsYou) -notcontains 'J604')
    Check 'since: a private order shows its ticket only, never its words' ((Invoke-WebRequest "$base/api/since?t=$tq" -Headers $auth).Content -notmatch 'secret')
    $old = (Invoke-RestMethod ("$base/api/since?t=" + [uri]::EscapeDataString('2001-01-01T00:00:00Z')) -Headers $auth).data
    Check 'since: a look older than the log is unknown, not zero' ($old.known -eq $false -and $null -eq $old.plated -and $old.from)
    Check 'since: a bad time is refused (400)' ((Get-Code "$base/api/since?t=yesterday" $auth) -eq 400 -and (Get-Code "$base/api/since" $auth) -eq 400)
    [IO.File]::AppendAllText($ev, '{"ts":"' + $t0.AddSeconds(7).ToString('o') + '","type":"job.done","job":"J606"')   # still being written
    Check 'since: a line still being written is not counted yet' (@((Invoke-RestMethod "$base/api/since?t=$tq" -Headers $auth).data.plated).Count -eq 1)
    [IO.File]::AppendAllText($ev, "}`n")
    Check 'since: new events count on the next call' ((@((Invoke-RestMethod "$base/api/since?t=$tq" -Headers $auth).data.plated) -join ',') -eq 'J601,J606')
    # only new bytes are read: an old line overwritten in place (same length) is not read again, so J601 still counts
    $raw = [IO.File]::ReadAllText($ev); $j601 = '"job.done","job":"J601"'; [IO.File]::WriteAllText($ev, $raw.Replace($j601, '"job.xxxx","job":"J601"'))
    SEv 8 'job.done' 'J607'
    Check 'since: only the bytes added since the last read are read (no re-scan of the log)' ((@((Invoke-RestMethod "$base/api/since?t=$tq" -Headers $auth).data.plated) -join ',') -eq 'J601,J606,J607')
    $bs = (Invoke-RestMethod "$base/api/brief?since=$tq" -Headers $auth).data
    Check 'brief: carries the same since counts when given the look' ($bs.since.known -and (@($bs.since.plated) -join ',') -eq 'J601,J606,J607' -and $null -eq (Invoke-RestMethod "$base/api/brief" -Headers $auth).data.since)

    # Stuck-loop alarm: the current step failed twice since it last finished; the Retry reason is the last failure (kind only if private)
    $f1 = @{ step = 1; attempt = 0; outcome = 'fail'; detail = 'exit 1: ci-wait: CI failed on PR #45'; at = $t0.ToString('o') }
    $f2 = @{ step = 1; attempt = 1; outcome = 'fail'; detail = 'exit 1: ci-wait: CI failed on PR #45'; at = $t0.ToString('o') }
    $d1 = @{ step = 1; attempt = 0; outcome = 'done'; at = $t0.ToString('o') }
    $w1 = @{ step = 1; attempt = 0; outcome = 'wait'; detail = 'ci still running'; at = $t0.ToString('o') }
    SJob 'J610' 'quarantined' @($f1, $w1, $f2); SJob 'J611' 'quarantined' @($f1); SJob 'J612' 'pending' @($f1, $f2, $d1)
    SJob 'J613' 'quarantined' @($f1, $f2) @{ vars = @{ goal = 'secret'; private = 'yes' } }; SJob 'J614' 'done' @($f1, $f2)
    $stS = @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs); $sj = { param($id) @($stS | Where-Object id -eq $id)[0] }
    $s610 = (& $sj 'J610').stuck
    Check 'stuck: the same step failed twice is flagged with step, station, count and reason' ($s610.times -eq 2 -and $s610.step -eq 2 -and $s610.station -eq 'ci-wait' -and $s610.kind -eq 'fail' -and $s610.detail -match 'CI failed' -and $s610.same -eq $true)
    Check 'stuck: one failure is not a loop' ($null -eq (& $sj 'J611').stuck)
    Check 'stuck: a step that finished after failing is not stuck' ($null -eq (& $sj 'J612').stuck)
    Check 'stuck: a plated order is never stuck' ($null -eq (& $sj 'J614').stuck)
    Check 'stuck: a private order gives the count and station, never the words' ((& $sj 'J613').stuck.times -eq 2 -and -not (& $sj 'J613').stuck.detail -and (& $sj 'J613').retryWhy -eq 'fail')
    Check 'retry reason: the last failure, with its detail' ((& $sj 'J610').retryWhy -eq 'fail: exit 1: ci-wait: CI failed on PR #45' -and -not (& $sj 'J612').retryWhy)
    Check 'stuck: the brief lists stuck orders' (@((Invoke-RestMethod "$base/api/brief" -Headers $auth).data.stuck | Where-Object id -eq 'J610').Count -eq 1)
    Check 'stuck: the job sheet carries the alarm and the retry reason' ((Invoke-RestMethod "$base/api/job/J610" -Headers $auth).data.stuck.times -eq 2)
    # TD-4: jobView.site (the stored vars.site, else the Tower's kitchen.repo.json "site" read from its main checkout) and jobView.floor
    # (vars.item as people see it, by the Tower's Blueprint site block). No Site = no key, so the row is exactly as before.
    $twGw = Join-Path $root 'tw-gw'; $twWt = Join-Path $root 'tw-gw-wt'; $twBad = Join-Path $root 'tw-bad'; $twTd = Join-Path $root 'tw-td'; $twNoGit = Join-Path $root 'tw-nogit'
    foreach ($d in "$twGw\.git\worktrees\x", "$twGw\map", $twWt, "$twBad\.git", "$twTd\.git", $twNoGit) { New-Item -ItemType Directory -Force $d | Out-Null }
    Set-Content "$twGw\kitchen.repo.json" '{"site":"GW","roadmap":"map/roadmap.json"}'; Set-Content "$twGw\map\roadmap.json" '{"site":{"code":"GW","id_prefix":"B"},"waves":[]}'
    Set-Content "$twGw\.git\worktrees\x\commondir" '../..'; Set-Content "$twWt\.git" "gitdir: $twGw\.git\worktrees\x"   # a worktree reads its main checkout's file
    Set-Content "$twBad\kitchen.repo.json" '{ not json'; Set-Content "$twTd\kitchen.repo.json" '{"site":"TD"}'; Set-Content "$twNoGit\kitchen.repo.json" '{"site":"TD"}'
    SJob 'J620' 'pending' @() @{ vars = @{ site = 'TD'; item = 'B-53'; repo = $twGw } }; SJob 'J622' 'pending' @() @{ vars = @{ repo = $twWt; item = 'B-7' } }
    SJob 'J623' 'pending' @() @{ vars = @{ repo = $twBad } }; SJob 'J624' 'pending'; SJob 'J625' 'pending' @() @{ vars = @{ site = 'gw'; repo = $twTd } }
    SJob 'J626' 'pending' @() @{ vars = @{ repo = $twNoGit } }; SJob 'J627' 'pending' @() @{ vars = @{ site = 'GW'; item = 'B-9'; private = 'yes'; repo = $twGw } }
    @{ id = 'J621'; name = 'old order'; status = 'pending'; cursor = 0; attempt = 0; created = $t0.ToString('o'); history = @(); steps = @(@{ script = 'pr.ps1'; args = @{ Repo = '{{repo}}' } }, @{ script = 'ci-wait.ps1'; args = @{ Repo = $twGw } }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $sjDir 'J621.json') -Encoding utf8
    $stS = @((Invoke-RestMethod "$base/api/state" -Headers $auth).jobs); $noKey = { param($id, $k) $null -eq (& $sj $id).PSObject.Properties[$k] }
    Check 'TD-4 site: the stored vars.site wins; the Floor shows by its Tower''s Blueprint (B-53 as GW-53)' ((& $sj 'J620').site -eq 'TD' -and (& $sj 'J620').floor -eq 'GW-53')
    Check 'TD-4 site: an order from before TD-3 gets its Tower''s Site (first step Repo that is not a {{template}})' ((& $sj 'J621').site -eq 'GW' -and (& $noKey 'J621' 'floor'))
    Check 'TD-4 site: a worktree Tower reads its main checkout''s kitchen.repo.json and Blueprint' ((& $sj 'J622').site -eq 'GW' -and (& $sj 'J622').floor -eq 'GW-7')
    Check 'TD-4 site: no Tower, a config that will not read, or no git checkout is no Site and no key (the row as before)' ((& $noKey 'J623' 'site') -and (& $noKey 'J624' 'site') -and (& $noKey 'J626' 'site') -and (& $noKey 'J624' 'floor'))
    Check 'TD-4 site: a stored code that is not exact capitals is not a Site; the Tower''s is used' ((& $sj 'J625').site -eq 'TD')
    Check 'TD-4 site: a private order keeps its Site code but sends no Floor id' ((& $sj 'J627').site -eq 'GW' -and (& $noKey 'J627' 'floor'))
    Check 'TD-4 site: the job sheet carries the Site too' ((Invoke-RestMethod "$base/api/job/J622" -Headers $auth).data.site -eq 'GW')
    foreach ($id in 'J601', 'J602', 'J603', 'J604', 'J605', 'J610', 'J611', 'J612', 'J613', 'J614', 'J620', 'J621', 'J622', 'J623', 'J624', 'J625', 'J626', 'J627') { Remove-Item (Join-Path $sjDir "$id.json") -ErrorAction SilentlyContinue }

    # the phone side: the words in node (since block of app.js), and the wiring
    $appS = Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw
    $sinceBlock = [regex]::Match($appS, '(?s)// since:start\r?\n(.*?)// since:end').Groups[1].Value
    $ticketLine = [regex]::Match($appS, '(?m)^const ticket = .*$').Value
    $sinceTest = @'
const checks = []; const ok = (name, pass) => checks.push({ name, pass: !!pass });
const now = new Date(2026, 9, 22, 21, 0); const at = (d, h, m) => new Date(2026, 9, d, h, m).toISOString();
ok('strip: counts in words', sinceText({ since: at(22, 19, 40), known: true, plated: ['J1', 'J2'], setAside: ['J3'], needsYou: ['J4'] }, now) === 'Since 19:40: 2 handed over, 1 failed, 1 needs sign-off');
ok('strip: plural need you, zero groups left out', sinceText({ since: at(22, 19, 40), known: true, plated: [], setAside: [], needsYou: ['J4', 'J5'] }, now) === 'Since 19:40: 2 need sign-off');
ok('strip: nothing new', sinceText({ since: at(22, 19, 40), known: true, plated: [], setAside: [], needsYou: [] }, now) === 'Since 19:40: nothing new');
ok('strip: unknown when the log does not reach back', /^Since 19:40: unknown/.test(sinceText({ since: at(22, 19, 40), known: false }, now)));
ok('strip: first visit is unknown', /unknown \(first visit/.test(sinceText({ first: true }, now)));
ok('strip: no data, no strip', sinceText(null, now) === '' && sinceText({}, now) === '');
ok('clock: yesterday, weekday, date', sinceClock(at(21, 7, 5), now) === 'yesterday 07:05' && sinceClock(at(19, 7, 5), now) === 'Mon 07:05' && sinceClock(at(1, 7, 5), now) === 'Oct 1 07:05' && sinceClock('x', now) === 'unknown');
ok('alarm: twice and N times, station named', stuckText('J193', { times: 2, station: 'ci-wait', step: 13 }) === 'WO-0193 failed the same step twice (ci-wait)' && stuckText('J7', { times: 3, station: '', step: 2 }) === 'WO-0007 failed the same step 3 times (step 2)');
ok('retry: count then reason', retryWhy({ stuck: { times: 2 }, retryWhy: 'fail: x' }) === 'failed 2x on this step: fail: x' && retryWhy({ retryWhy: 'timeout' }) === 'timeout' && retryWhy({}) === '');
ok('retry: long reasons are cut', retryWhy({ retryWhy: 'y'.repeat(300) }).length === 90);
console.log(JSON.stringify(checks));
'@
    $sinceFile = Join-Path ([IO.Path]::GetTempPath()) "since-test-$PID.mjs"
    $labelLinesS = @($appS -split "`r?`n" | Where-Object { $_ -match '^const (STATUS_LABEL|statusLabel) = ' }) -join "`n"
    ($ticketLine + "`n" + $labelLinesS + "`n" + $sinceBlock + "`n" + $sinceTest) | Set-Content $sinceFile -Encoding utf8
    $sinceOut = & node $sinceFile; $sinceExit = $LASTEXITCODE; Remove-Item $sinceFile -Force -ErrorAction SilentlyContinue
    $sinceRes = $null; try { $sinceRes = ($sinceOut -join "`n") | ConvertFrom-Json } catch { }
    Check 'since words: the node check ran (exit 0, 10 results)' ($sinceExit -eq 0 -and @($sinceRes).Count -eq 10)
    foreach ($r in @($sinceRes)) { Check "since words: $($r.name)" $r.pass }
    Check 'since wiring: the phone keeps chef.lastSeen when Chef goes out of sight and asks /api/since' ($appS -match "store\.set\('lastSeen'" -and $appS -match "document\.hidden\) markSeen\(\)" -and $appS -match "api\('/api/since\?t='" -and (Get-Content (Join-Path $repo 'pass-app\public\index.html') -Raw) -match 'id="since"')
    Check 'stuck wiring: alarm on the Pass, chip on the row, Retry buttons say why' ($appS -match 'const stuck = stuckAlarm\(jobs\);' -and $appS -match 'stuckChip\(j\)\]' -and ([regex]::Matches($appS, 'retryLabel\(j\)')).Count -ge 2)

    # TD-EH-04 "Sent or not": while phone alerts are off the Board counts the alerts that did not reach the phone (alerts.jsonl `sent`)
    $apP = Join-Path $root 'alerts.jsonl'; $apKeep = Get-Content $apP -Raw -ErrorAction SilentlyContinue
    Set-Content $apP @('{"ts":"2026-10-22T07:00:00Z","level":"MED","job":"","text":"before the record"}',
        '{"ts":"2026-10-23T07:00:00Z","level":"HIGH","job":"J1","text":"x","sent":"ok"}',
        '{"ts":"2026-10-23T08:00:00Z","level":"HIGH","job":"J2","text":"SECRET-ALERT-WORDS","sent":"off","why":"phone alerts are off"}',
        '{"ts":"2026-10-23T08:30:00Z", torn',
        '{"ts":"2026-10-23T09:00:00Z","level":"MED","job":"J3","text":"y","sent":"off","why":"phone alerts are off"}') -Encoding utf8
    $stU = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'SentOrNot_Board: state counts the unsent alerts since the last sent one (torn line skipped) with push off' ($stU.push -eq $false -and $stU.alertsUnsent.n -eq 2 -and ([DateTime]$stU.alertsUnsent.since).ToUniversalTime() -eq [DateTime]::new(2026, 10, 23, 8, 0, 0, [DateTimeKind]::Utc))
    Add-Content $apP '{"ts":"2026-10-23T10:00:00Z","level":"HIGH","job":"J4","text":"z","sent":"held","why":"sent when the Walkround lets go of the lock"}'
    Check 'SentOrNot_Board: a held alert ends the count (its send is not known yet)' ((Invoke-RestMethod "$base/api/state" -Headers $auth).alertsUnsent.n -eq 0)
    Add-Content $apP '{"ts":"2026-10-23T11:00:00Z","level":"HIGH","job":"J5","text":"w","sent":"failed","why":"ntfy error (HTTP 503)","http":503}'
    $stU2 = Invoke-RestMethod "$base/api/state" -Headers $auth
    Check 'SentOrNot_Board: a failed send counts as not sent; state carries a count and a time, no alert words' ($stU2.alertsUnsent.n -eq 1 -and (($stU2.alertsUnsent | ConvertTo-Json -Compress) -notmatch 'SECRET|ntfy|text'))
    if ($null -ne $apKeep) { Set-Content $apP $apKeep -NoNewline } else { Remove-Item $apP }
    # the banner words in node (alertsOffBanner and alertNotSent from app.js, with app.js's own dayTime and an escaper)
    $aoFn = [regex]::Match($appS, '(?ms)^function alertsOffBanner\(s\) \{.*?^\}').Value
    $nsFn = [regex]::Match($appS, '(?m)^function alertNotSent\(e\) .*$').Value; $dtFn = [regex]::Match($appS, '(?m)^function dayTime\(iso\) .*$').Value
    $aoTest = @'
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const checks = []; const ok = (name, pass) => checks.push({ name, pass: !!pass });
const since = '2026-10-23T08:00:00Z'; const when = esc(dayTime(since)); const link = '<a class="btn" href="#/activity">See alerts</a>';
ok('banner: "Phone alerts are off: N alerts since <time> were not sent", plain banner, link to the alerts list', alertsOffBanner({ push: false, alertsUnsent: { n: 3, since } }) === `<div class="banner">Phone alerts are off: 3 alerts since ${when} were not sent.${link}</div>`);
ok('banner: one alert reads "1 alert ... was not sent"', alertsOffBanner({ push: false, alertsUnsent: { n: 1, since } }) === `<div class="banner">Phone alerts are off: 1 alert since ${when} was not sent.${link}</div>`);
ok('banner: off with nothing unsent yet still shows, plainly', alertsOffBanner({ push: false, alertsUnsent: { n: 0, since: null } }) === `<div class="banner">Phone alerts are off: new alerts will not reach your phone.${link}</div>`);
ok('banner: none while phone alerts are on, or before the state arrives', alertsOffBanner({ push: true, alertsUnsent: { n: 4, since } }) === '' && alertsOffBanner(null) === '' && alertsOffBanner({}) === '');
ok('activity: an unsent alert is marked with its reason; a sent or held one is not', alertNotSent({ sent: 'off', why: 'phone alerts are off' }) === ' · <b>not sent</b> (phone alerts are off)' && alertNotSent({ sent: 'limited', why: '<x>' }) === ' · <b>not sent</b> (&lt;x&gt;)' && alertNotSent({ sent: 'ok' }) === '' && alertNotSent({ sent: 'held' }) === '' && alertNotSent({}) === '');
console.log(JSON.stringify(checks));
'@
    $aoFile = Join-Path ([IO.Path]::GetTempPath()) "alerts-off-test-$PID.mjs"
    ($dtFn + "`n" + $nsFn + "`n" + $aoFn + "`n" + $aoTest) | Set-Content $aoFile -Encoding utf8
    $aoOut = & node $aoFile; $aoExit = $LASTEXITCODE; Remove-Item $aoFile -Force -ErrorAction SilentlyContinue
    $aoRes = $null; try { $aoRes = ($aoOut -join "`n") | ConvertFrom-Json } catch { }
    Check 'SentOrNot_Board: the banner node check ran (exit 0, 5 results)' ($aoExit -eq 0 -and @($aoRes).Count -eq 5)
    foreach ($r in @($aoRes)) { Check "SentOrNot_Board: $($r.name)" $r.pass }
    Check 'SentOrNot_Board wiring: renderBanners shows it on every view, Activity marks alerts, the link uses the existing a.btn rule' ($appS -match 'const ao = alertsOffBanner\(s\); if \(ao\) b\.push\(ao\);' -and $appS -match "'alert': \[[^\]]*alertNotSent\(e\)" -and (Get-Content (Join-Path $repo 'pass-app\public\app.css') -Raw) -match '\.pack-actions a\.btn,\.banner a\.btn\{text-decoration:none')
} finally {
    if ($srv -and -not $srv.HasExited) { & taskkill.exe /PID $srv.Id /T /F 2>&1 | Out-Null }
    $env:BRAIN_KITCHEN = $null; $env:PASS_PORT = $null; $env:PASS_NO_TAILSCALE = $null; $env:PASS_HOSTS = $null; $env:PASS_NO_KICK = $null; $env:KITCHEN_OLLAMA_URL = $null; $env:KITCHEN_AGY_EXE = $null
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains((Split-Path $root -Leaf)) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }  # only this run's GUID root: a concurrent run of this suite (another job's tests station, verify) must keep its workers
    $env:PASS_CAREER_DIR = $null; $env:PASS_APPLY_FILL = $null; $env:KITCHEN_NOTIFY_LOG = $null; $env:KITCHEN_NO_DIAGNOSE = $null; $env:PASS_STALL_CHECK_MS = $null; $env:PASS_HOSTS = $null; $env:PASS_INCOME_DIR = $null
    Remove-Item -Recurse -Force $root, "$root-gate-repo", "$root-out.txt", "$root-err.txt", "$root-career", "$root-fill", "$root-notify.txt", "$root-income", "$root-gh" -ErrorAction SilentlyContinue
}
# the pixel stage and the pixel interface skin (sprites.js; the node checks for it run above through test-scene.mjs)
$pxScene = Get-Content (Join-Path $repo 'pass-app\public\scene.js') -Raw
$pxSprites = Get-Content (Join-Path $repo 'pass-app\public\sprites.js') -Raw
$pxCss = Get-Content (Join-Path $repo 'pass-app\public\app.css') -Raw
$pxSkin = $pxCss.Substring([Math]::Max(0, $pxCss.IndexOf('Chef pixel skin')))
Check 'pixel: scene.js loads sprites.js lazily and keeps the still card if it cannot' ($pxScene -match "import\('\./sprites\.js'\)\.then" -and $pxScene -match '\.catch\(\(\) => \{ /\* no sprites' -and $pxScene -match 'if \(PX && canvasOk\(\)\) \{ el\._card = null; mountPixel\(el, L\); return; \}')
Check 'pixel: sprites.js is art as code: the two-line header, no fetch, no image files, no network' (($pxSprites -split "`n")[0] -match '^// ' -and ($pxSprites -split "`n")[1] -match '^// ' -and $pxSprites -notmatch '\bfetch\(|new Image\(|https?://|\.png\b')
Check 'pixel: the canvas is drawn crisp (pixelated, whole-number scale)' ($pxSkin -match '\.px-canvas\{[^}]*image-rendering:pixelated' -and $pxScene -match 'export function pixelScale' -and $pxScene -match 'imageSmoothingEnabled = false')
Check 'pixel: the stage stops while hidden, scrolled off screen (IntersectionObserver) or under reduced motion' ($pxScene -match "ok: \(\) => stageOk\(sc, document, reduced\(\)\)" -and (Get-Content (Join-Path $repo 'pass-app\public\frame.js') -Raw) -match "sc\.visible !== false" -and $pxScene -match "new IntersectionObserver\(" -and $pxScene -match "addEventListener\('visibilitychange'")
Check 'pixel chrome: everything waits for html.px (no sprites = the old look)' (([regex]::Matches($pxSkin, '(?m)^html\.px')).Count -ge 20 -and $pxScene -match "root\.classList\.add\('px'\)")
Check 'pixel chrome: tabs wear pixel icons, plain and lit' ((@('pass', 'talk', 'activity', 'cooks', 'ledger') | Where-Object { $pxSkin -notmatch "data-view=$_\] svg\{background-image:var\(--px-tab-$_\)\}" -or $pxSkin -notmatch "data-view=$_\]\[aria-current=page\] svg\{background-image:var\(--px-tab-$_-on\)\}" }).Count -eq 0)
Check 'pixel chrome: chips and pills have stepped corners and keep their words' ($pxSkin -match 'html\.px :is\(\.brief-chips \.chip,[^)]*\)\{[^}]*clip-path:var\(--px-notch-s\)' -and $pxSkin -match 'html\.px :is\(\.status-pill,[^)]*\)\{[^}]*clip-path:var\(--px-notch-s\)')
Check 'pixel chrome: cards and dialogs use the 9-slice panel' ($pxSkin -match 'html\.px :is\(\.sec,[^)]*\.confirm\)\{[^}]*border-image:var\(--px-frame\) 3 fill' -and $pxSkin -match 'html\.px \.sheet\{[^}]*border-image:var\(--px-frame\)')
Check 'pixel chrome: loading, offline and empty states show their crew (site art)' ($pxSkin -match 'html\.px \.skeleton::before\{background-image:var\(--px-load\)' -and $pxSkin -match 'html\.px \.quiet\.offline::before\{background-image:var\(--px-off\)' -and $pxSkin -match 'html\.px \.quiet::before\{background-image:var\(--px-empty\)')
Check 'pixel chrome: dark mode swaps in the dark panel and dark tokens' ($pxSkin -match '@media \(prefers-color-scheme:dark\)\{:root\{--px-ol:#0d0a09;--px-card:#2b211d;[^}]*--px-frame:var\(--px-panel-dark\)\}\}')
Check 'pixel chrome: reduced motion holds the chrome sprites still' ($pxSkin -match '@media \(prefers-reduced-motion:reduce\)\{html\.px \.skeleton::before,html\.px \.quiet::before\{animation:none\}\}')
# the building-site theme (rename S6a): old token names kept with new values, the phone's bars match the page, the site touches wait for html.px and hold still under reduced motion
$pxIdx = Get-Content (Join-Path $repo 'pass-app\public\index.html') -Raw; $pxMf = Get-Content (Join-Path $repo 'pass-app\public\manifest.webmanifest') -Raw | ConvertFrom-Json
Check 'site theme: the old token names still resolve in light and dark (--ember, --ember-grad, --ember-wash, --on-ember, --live, --amber, --sky)' ((@('--ember', '--ember-grad', '--ember-wash', '--on-ember', '--live', '--amber') | Where-Object { ([regex]::Matches($pxCss, "(?m)[\s{;]$_\s*:")).Count -lt 2 }).Count -eq 0 -and $pxCss -match 'html\[data-daypart=night\]\{--sky:#4F86C6\}' -and ([regex]::Matches($pxCss, '@media \(prefers-color-scheme:dark\)\{:root\{')).Count -ge 3)
Check 'site theme: the theme-color metas and the manifest colours are the site paper (light) and the night site (dark)' ($pxIdx -match '<meta name="theme-color" content="#1A1412" media="\(prefers-color-scheme: dark\)">' -and $pxIdx -match '<meta name="theme-color" content="#EFE6D4" media="\(prefers-color-scheme: light\)">' -and $pxCss -match '--bg:#EFE6D4;' -and $pxCss -match '--bg:#1A1412;' -and $pxMf.background_color -eq '#1A1412' -and $pxMf.theme_color -eq '#1A1412' -and $pxMf.id -eq '/' -and $pxMf.start_url -eq '/#/pass')
Check 'site theme: hazard tape, hard hat and beacon wear the tokens, wait for html.px and stop under reduced motion' ($pxSkin -match 'html\.px \.top::after\{[^}]*background:var\(--px-hazard\)' -and $pxSkin -match 'html\.px \.sec\.hot \.sec-head::after\{[^}]*background:var\(--px-hazard\)' -and $pxSkin -match 'html\.px \.top h1::before\{[^}]*background:var\(--cloche\)' -and $pxSkin -match '@media \(prefers-reduced-motion:reduce\)\{html\.px \.top h1::before,html\.px \.sec\.hot \.sec-head::after,html\.px \.sec\.hot \.sec-head>span::before\{animation:none\}\}')
# the icons (rename S6b): the app icon is pixel art from the palette with its art inside the maskable safe zone, at the same path everywhere;
# the symbol ids app.js builds stay; the tab icons hop and nod only under html.px, never scale, and hold still under reduced motion; New work order fits a phone
$icoSvg = Get-Content (Join-Path $repo 'pass-app\public\icon.svg') -Raw; $icoArt = [regex]::Match($icoSvg, '<g id="art">([\s\S]*?)</g>').Groups[1].Value; $icoFar = 0
foreach ($m in [regex]::Matches($icoArt, 'M(\d+) (\d+)h(\d+)v(\d+)')) { $x0 = [int]$m.Groups[1].Value; $y0 = [int]$m.Groups[2].Value; $x1 = $x0 + [int]$m.Groups[3].Value; $y1 = $y0 + [int]$m.Groups[4].Value
  foreach ($p in @(@($x0, $y0), @($x1, $y0), @($x0, $y1), @($x1, $y1))) { $d = [Math]::Sqrt([Math]::Pow($p[0] - 256, 2) + [Math]::Pow($p[1] - 256, 2)); if ($d -gt $icoFar) { $icoFar = $d } } }
$icoHex = @([regex]::Matches($icoSvg, '#[0-9a-fA-F]{6}') | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique)
Check 'site icons: the app icon is pixel art from the sprites.js palette, full bleed, its art inside the maskable safe zone (the 80% circle)' ($icoSvg -match 'viewBox="0 0 512 512"' -and $icoSvg -match 'shape-rendering="crispEdges"' -and $icoSvg -notmatch '<(text|image|script|use|linearGradient|radialGradient)\b|href=' -and $icoArt.Length -gt 200 -and $icoFar -gt 150 -and $icoFar -le 204.8 -and $icoHex.Count -ge 6 -and @($icoHex | Where-Object { $pxSprites -notmatch "'$_'" }).Count -eq 0)
Check 'site icons: one icon path everywhere (manifest "any maskable", both links, the shell cache, served before sign-in, push)' (@($pxMf.icons).Count -eq 1 -and $pxMf.icons[0].src -eq '/icon.svg' -and $pxMf.icons[0].purpose -eq 'any maskable' -and $pxIdx -match '<link rel="icon" href="/icon\.svg">' -and $pxIdx -match '<link rel="apple-touch-icon" href="/icon\.svg">' -and (Get-Content (Join-Path $repo 'pass-app\public\sw.js') -Raw) -match "'/icon\.svg'" -and (Get-Content (Join-Path $repo 'pass-app\server.mjs') -Raw) -match "url\.pathname === '/icon\.svg'" -and (Get-Content (Join-Path $repo 'pass-app\public\app.js') -Raw) -match "icon: '/icon\.svg'")
Check 'site icons: every symbol id app.js and the page use is still defined (i-pass, i-cooks, i-talk ...)' ((@('pass', 'activity', 'ledger', 'cooks', 'talk', 'send', 'lock', 'hunt', 'plus', 'screen', 'speaker', 'settings', 'x', 'back', 'more', 'chev', 'down', 'cloche') | Where-Object { $pxIdx -notmatch "<symbol id=`"i-$_`"" }).Count -eq 0)
Check 'site icons: the tab you land on hops once and Live nods while a crew works, stepped, under html.px, never scaled, still under reduced motion' ($pxSkin -match 'html\.px \.bar a\[aria-current="page"\] svg\{animation:px-hop [^}]*steps\(1\) 1\}' -and $pxSkin -match 'html\.px \.bar a\[data-view=cooks\]:has\(\.live-count:not\(\[hidden\]\)\) svg\{animation:px-nod [^}]*steps\(1\)' -and $pxSkin -match 'html\.px \.bar a svg,html\.px \.bar a\[aria-current="page"\] svg\{transform:none' -and $pxSkin -match '@media \(prefers-reduced-motion:reduce\)\{html\.px \.bar a svg,html\.px \.order-btn svg\{animation:none!important\}\}')
Check 'site icons: New work order stacks into two lines on a phone (it wrapped onto three at 375 px) and keeps its words' ($pxCss -match '@media \(max-width:440px\)\{\.order-btn\{flex-direction:column;[^}]*\}\.order-btn span\{text-wrap:balance\}\}' -and $pxIdx -match '<span>New work order</span></button>' -and $pxSkin -match 'html\.px \.order-btn::after\{[^}]*background:var\(--px-hazard\)')
# the W4 node checks started at the top (a crash, a hang past 180 s or a missing result is a failure, never silence)
if (-not $w4.WaitForExit(180000)) { & taskkill.exe /PID $w4.Id /T /F 2>&1 | Out-Null }
$w4Res = $null; try { $w4Res = (Get-Content $w4Out -Raw) | ConvertFrom-Json } catch { }
Check 'W4: test-patch.mjs finished within 180 s with exit 0 and its results' ($w4.HasExited -and $w4.ExitCode -eq 0 -and @($w4Res).Count -ge 15)
foreach ($t in @($w4Res)) { if ($t) { Check "W4: $($t.name)" ($t.pass -eq $true) } }
if (-not $w4Res) { Write-Host (Get-Content "$root-w4-err.txt" -Raw -ErrorAction SilentlyContinue) }
Remove-Item -Force $w4Out, "$root-w4-err.txt" -ErrorAction SilentlyContinue
Write-Host "PassApp tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
