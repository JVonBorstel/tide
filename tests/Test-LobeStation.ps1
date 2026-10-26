# Tests for kitchen/stations/lobe.ps1 (the lobe Step) and its Specs kitchen/recipes/lobe-sweep.json and lobe-rem.json (ZG-07; the ZG-42 night: sleep[]), with the
# suite registration in scripts/verify-all.json. Run by the tests Step (it globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1.
# A temp kitchen, a temp lobe home, a fake zeitgeistd checkout and a fake python (KITCHEN_LOBE_PYTHON) that records what it was given; a
# fake Ollama answers on a loopback port inside this process. One real call to the zeitgeistd checkout's health proves the wiring (SKIP
# when this PC has no checkout or no uv). Self-cleaning. ZG-17: the skip counts and the rem push (KITCHEN_NOTIFY_LOG, never the network).
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$station = Join-Path $repoRoot 'kitchen\stations\lobe.ps1'
$bounded = Join-Path $repoRoot 'scripts\run-bounded.ps1'
$pwshExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('lobe-st-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$envNames = @('BRAIN_KITCHEN', 'ZEITGEISTD_REPO', 'ZEITGEISTD_HOME', 'KITCHEN_LOBE_PYTHON', 'KITCHEN_FAKE_FREE_MB', 'KITCHEN_OLLAMA_URL', 'KITCHEN_RUN',
    'LOBE_FAKE_LOG', 'LOBE_FAKE_FAIL', 'LOBE_FAKE_CODES', 'KITCHEN_LOBE_SCRIPTS', 'LOBE_FAKE_MEM_EXIT', 'LOBE_FAKE_MEM_SLEEP', 'LOBE_FAKE_MEM_LOG',
    'LOBE_FAKE_HEALTH_EXIT', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'GEMINI_API_KEY', 'ZG07_TEST_API_KEY',
    'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'GOOGLE_CLOUD_PROJECT', 'KITCHEN_RECIPES', 'KITCHEN_UNDER_TEST', 'BRAIN_NTFY_TOPIC', 'KITCHEN_JOB',
    'KITCHEN_NOTIFY_LOG', 'KITCHEN_NOTIFY_FAIL', 'LOBE_FAKE_DUE', 'LOBE_FAKE_REFUSE', 'BRAIN_AGENT_DEPTH')
$saved = @{}; foreach ($n in $envNames) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Show = '') {
    if ($Ok) { $script:pass++; return }
    $script:fail++; Write-Host "FAIL: $Name"
    if ($Show) { Write-Host (($Show -split "`r?`n" | Select-Object -Last 15) -join "`n") }
}

# The fake zeitgeistd checkout: the files the Step looks for, nothing else. rem.py is added by the rem tests.
$fakeRepo = Join-Path $tmp 'repo'
foreach ($f in 'pyproject.toml', 'zeitgeistd\__init__.py', 'zeitgeistd\db.py', 'zeitgeistd\connectors\yard.py', 'zeitgeistd\connectors\git.py',
    'zeitgeistd\actions.py', 'zeitgeistd\csf.py', 'zeitgeistd\gate.py', 'zeitgeistd\health.py') {
    $p = Join-Path $fakeRepo $f; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null; Set-Content -LiteralPath $p -Value ''
}
# The fake python: one JSON line per call (argv, folder, environment, whether the GPU lock is held by someone else), then a line in the
# module's own shape. LOBE_FAKE_FAIL names a module that exits 1; LOBE_FAKE_HEALTH_EXIT is health's exit code.
$fakePy = Join-Path $tmp 'fake-python.ps1'
Set-Content -LiteralPath $fakePy -Value @'
$a = @($args); $mod = if ($a.Count -ge 3) { [string]$a[2] } else { '' }; $rest = @($a | Select-Object -Skip 3)
$gpu = 'free'
try {
    $m = [Threading.Mutex]::OpenExisting('Global\brain-kitchen-gpu')
    try { if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $gpu = 'held' } } catch [Threading.AbandonedMutexException] { } finally { $m.Dispose() }
} catch { }
$keys = @(Get-ChildItem Env: | Where-Object { $_.Name -match '(?i)(API_KEY|AUTH_TOKEN|USE_BEDROCK|USE_VERTEX|USE_VERTEXAI|CLOUD_PROJECT)$' } | ForEach-Object Name)
$rec = [ordered]@{ argv = $a; mod = $mod; rest = $rest; cwd = (Get-Location).Path; home = $env:ZEITGEISTD_HOME; ollama = $env:KITCHEN_OLLAMA_URL
    uvpref = $env:UV_PYTHON_PREFERENCE; keys = $keys; gpu = $gpu }
Add-Content -LiteralPath $env:LOBE_FAKE_LOG -Value ($rec | ConvertTo-Json -Compress -Depth 4)
if ($env:LOBE_FAKE_FAIL -and $env:LOBE_FAKE_FAIL -eq $mod) { [Console]::Error.WriteLine("zeitgeistd: $mod FAIL injected"); exit 1 }
foreach ($pair in @(([string]$env:LOBE_FAKE_CODES) -split ',' | Where-Object { $_ })) { $kv = $pair -split '='; if ($kv[0] -eq $mod) { "zeitgeistd: $mod exit $($kv[1]) injected"; exit ([int]$kv[1]) } }   # ZG-42: module=code,...
switch ($mod) {
    'zeitgeistd.governor' { 'zeitgeistd: governor run' }
    'zeitgeistd.gate' { 'zeitgeistd: sweep ok processed=4 scored=3 dropped=1 dlq=0 refused=0 throttled=0 tokens=10 today=10 stage2_max_ms=5 ms=7 stop: queue empty' }
    'zeitgeistd.rem' { 'zeitgeistd: rem ok items=7 dropped=shorts:1,hype:2 ms=3' }
    'zeitgeistd.claims' {   # ZG-21: due prints LOBE_FAKE_DUE (a file); resolve exits 3 for the claim:status pairs in LOBE_FAKE_REFUSE
        if ($rest[0] -eq 'run') { 'zeitgeistd: claims ok'; exit 0 }   # ZG-42: the night's claims run (the Owner's taps)
        if ($rest[0] -eq 'due') { Get-Content -LiteralPath $env:LOBE_FAKE_DUE -Raw; exit 0 }
        if ($rest[0] -eq 'resolve') {
            if ("$($rest[1]):$($rest[2])" -in @("$env:LOBE_FAKE_REFUSE" -split ',')) { [Console]::Error.WriteLine("zeitgeistd: claims refused: no evidence for $($rest[2])"); exit 3 }
            "zeitgeistd: claims resolved $($rest[1]) $($rest[2]) by=auto privacy=P0 brier=auto"; exit 0
        }
        exit 2
    }
    'zeitgeistd.health' { if ($rest -contains '--skip') { "zeitgeistd: heartbeat written, skipped: $($rest[1])" }; 'zeitgeistd: health ok checked=12'; exit ([int]$env:LOBE_FAKE_HEALTH_EXIT) }
    default { "zeitgeistd: $($mod -replace '^zeitgeistd\.', '') ok" }
}
exit 0
'@

# A fake Ollama on a loopback port: answers every request with an empty model list, in a runspace of this process (stops with $ol.Stop()).
$ol = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $ol.Start(); $olPort = $ol.LocalEndpoint.Port
$olRs = [powershell]::Create().AddScript({
        param($l)
        while ($true) {
            try { $c = $l.AcceptTcpClient() } catch { break }
            try {
                $s = $c.GetStream(); $buf = [byte[]]::new(8192); [void]$s.Read($buf, 0, $buf.Length)
                $body = '{"models":[]}'; $msg = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"
                $bytes = [Text.Encoding]::ASCII.GetBytes($msg); $s.Write($bytes, 0, $bytes.Length); $s.Flush()
            } catch { $null = $_ } finally { $c.Close() }   # a client that hung up early: answer the next one
        }
    }).AddArgument($ol)
$olHandle = $olRs.BeginInvoke()
$closed = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $closed.Start(); $closedPort = $closed.LocalEndpoint.Port; $closed.Stop()

$kitchen = Join-Path $tmp 'k'
$script:runN = 0
# Runs the Step in a child pwsh with the test environment plus $Env (a $null value removes a variable). Returns { out; code; calls }.
function Invoke-Station([string[]]$StepArgs, [hashtable]$Env = @{}) {
    $script:runN++
    $log = Join-Path $tmp "fake-$($script:runN).jsonl"
    $base = @{ BRAIN_KITCHEN = $kitchen; ZEITGEISTD_REPO = $fakeRepo; ZEITGEISTD_HOME = $null; KITCHEN_LOBE_PYTHON = $fakePy; KITCHEN_FAKE_FREE_MB = '8000'
        KITCHEN_OLLAMA_URL = "http://127.0.0.1:$olPort"; KITCHEN_RUN = (Join-Path $tmp "run-$($script:runN)"); LOBE_FAKE_LOG = $log; LOBE_FAKE_FAIL = $null; LOBE_FAKE_CODES = $null; KITCHEN_JOB = $null
        LOBE_FAKE_HEALTH_EXIT = $null; ANTHROPIC_API_KEY = 'placeholder-1'; OPENAI_API_KEY = 'placeholder-2'; GEMINI_API_KEY = 'placeholder-3'
        ZG07_TEST_API_KEY = 'placeholder-4'; ANTHROPIC_AUTH_TOKEN = 'placeholder-5'; CLAUDE_CODE_USE_BEDROCK = '1'; GOOGLE_CLOUD_PROJECT = 'placeholder-6'
        BRAIN_NTFY_TOPIC = $null; KITCHEN_NOTIFY_LOG = (Join-Path $tmp "notify-$($script:runN).txt"); KITCHEN_NOTIFY_FAIL = $null; LOBE_FAKE_REFUSE = $null }   # ZG-17: a rem run never reaches ntfy
    foreach ($k in $Env.Keys) { $base[$k] = $Env[$k] }
    foreach ($k in $base.Keys) { [Environment]::SetEnvironmentVariable($k, $base[$k]) }
    $out = & $pwshExe -NoProfile -File $station @StepArgs 2>&1 | Out-String; $code = $LASTEXITCODE
    $calls = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } })
    [pscustomobject]@{ out = $out; code = $code; calls = $calls; run = $base.KITCHEN_RUN }
}
function Get-Mods($r) { , @($r.calls | ForEach-Object { (@($_.mod) + @($_.rest)) -join ' ' }) }   # always an array, even of one

try {
    $lobeHome = Join-Path $kitchen 'lobe'; $beat = Join-Path $kitchen 'watch\lobe.json'; $cfgPath = Join-Path $lobeHome 'config.json'

    # ---- ZG07-1: finds the checkout, runs the module with the lobe home, no API keys, the Ollama address, the GPU lock, the done line ----
    $r = Invoke-Station @('-Cmd', 'csf')
    $c0 = $r.calls | Select-Object -First 1
    Check 'ZG07-1 csf: exit 0 and the done line the spec matches' ($r.code -eq 0 -and $r.out -match '(?m)^lobe: csf done items=0 dropped=0 ms=\d+') $r.out
    Check 'ZG07-1 runs python -I -m zeitgeistd.csf in the checkout' ($r.calls.Count -eq 1 -and ($c0.argv -join ' ') -eq '-I -m zeitgeistd.csf' -and $c0.cwd -eq $fakeRepo)
    Check 'ZG07-1 ZEITGEISTD_HOME is <kitchen>\lobe and uv is told to use its own python' ($c0.home -eq $lobeHome -and $c0.uvpref -eq 'only-managed')
    Check 'ZG07-1 API key variables are stripped (named list and any *_API_KEY / *_AUTH_TOKEN)' (@($c0.keys).Count -eq 0) ($c0.keys -join ',')
    Check 'ZG07-1 KITCHEN_OLLAMA_URL is passed through' ($c0.ollama -eq "http://127.0.0.1:$olPort")
    Check 'ZG07-1 csf only reads: the GPU lock is not taken' ($c0.gpu -eq 'free')
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    Check 'ZG07-1 config.json points heartbeat_path at <kitchen>\watch\lobe.json (the Watch reads it)' ($cfg.heartbeat_path -eq $beat) $r.out
    Check 'ZG07-1 the checkout is named with where it came from' ($r.out -match [regex]::Escape("checkout at $fakeRepo (from env ZEITGEISTD_REPO)"))

    $r = Invoke-Station @('-Cmd', 'sweep')
    $mods = Get-Mods $r
    Check 'ZG07-1 sweep: db init, yard, git, actions run, csf, then gate sweep (last: its heartbeat keeps the stop reasons)' (($mods -join '|') -eq 'zeitgeistd.db init|zeitgeistd.connectors.yard|zeitgeistd.connectors.git|zeitgeistd.actions run|zeitgeistd.csf|zeitgeistd.gate sweep') ($mods -join '|')
    Check 'ZG07-1 sweep holds the GPU lock while every module runs' (@($r.calls | Where-Object { $_.gpu -ne 'held' }).Count -eq 0 -and $r.calls.Count -eq 6)
    Check 'ZG07-1 sweep: items and dropped come from the gate''s own line' ($r.code -eq 0 -and $r.out -match '(?m)^lobe: sweep done items=4 dropped=1 ms=\d+') $r.out
    $after = [Threading.Mutex]::new($false, 'Global\brain-kitchen-gpu'); $free = $after.WaitOne(0); if ($free) { $after.ReleaseMutex() }; $after.Dispose()
    Check 'ZG07-1 the GPU lock is released when the sweep ends' $free

    $r = Invoke-Station @('-Cmd', 'sweep') @{ LOBE_FAKE_FAIL = 'zeitgeistd.connectors.git' }
    Check 'ZG07-1 a failed step: the rest still run, exit 1, FAILED names it, no done line' ($r.code -eq 1 -and (Get-Mods $r).Count -eq 6 -and $r.out -match 'lobe: sweep FAILED \(connectors\.git exit 1\)' -and $r.out -notmatch 'lobe: sweep done') $r.out
    $r = Invoke-Station @('-Cmd', 'sweep') @{ LOBE_FAKE_FAIL = 'zeitgeistd.db' }
    Check 'ZG07-1 a failed db init stops the sweep (nothing works without the store)' ($r.code -eq 1 -and (Get-Mods $r).Count -eq 1) ((Get-Mods $r) -join '|')
    $r = Invoke-Station @('-Cmd', 'health') @{ LOBE_FAKE_HEALTH_EXIT = '3' }
    Check 'ZG07-1 health NOT OK keeps its exit 3 and gets no done line' ($r.code -eq 3 -and $r.out -notmatch 'lobe: health done' -and (Get-Mods $r)[0] -eq 'zeitgeistd.health') $r.out
    $r = Invoke-Station @('-Cmd', 'health') @{ LOBE_FAKE_HEALTH_EXIT = '11' }
    Check 'ZG07-1 a module exit 11 is a failure (1), never read as a wait' ($r.code -eq 1) $r.out

    $r = Invoke-Station @('-Cmd', 'rem')
    Check 'ZG07-1 rem before ZG-28: refused, nothing run, the missing module named' ($r.code -eq 1 -and $r.calls.Count -eq 0 -and $r.out -match 'zeitgeistd\.rem is not in the checkout') $r.out
    Set-Content -LiteralPath (Join-Path $fakeRepo 'zeitgeistd\rem.py') -Value ''
    $r = Invoke-Station @('-Cmd', 'rem')
    Check 'ZG07-1 rem: runs zeitgeistd.rem under the GPU lock; dropped sums rule:count pairs' ($r.code -eq 0 -and (Get-Mods $r) -contains 'zeitgeistd.rem' -and @($r.calls | Where-Object { $_.mod -eq 'zeitgeistd.rem' })[0].gpu -eq 'held' -and $r.out -match '(?m)^lobe: rem done items=7 dropped=3 ms=\d+') $r.out

    # where the checkout comes from: env, else the state kitchen.json lobe.repo, else the default under the user profile
    $alt = Join-Path $tmp 'alt-repo'; Copy-Item -LiteralPath $fakeRepo -Destination $alt -Recurse
    Set-Content -LiteralPath (Join-Path $kitchen 'kitchen.json') -Value (@{ lobe = @{ repo = $alt } } | ConvertTo-Json)
    $r = Invoke-Station @('-Cmd', 'csf') @{ ZEITGEISTD_REPO = $null }
    Check 'ZG07-1 no env: kitchen.json lobe.repo in the state folder is used' ($r.code -eq 0 -and $r.calls[0].cwd -eq $alt -and $r.out -match 'from kitchen\.json lobe\.repo') $r.out
    $r = Invoke-Station @('-Cmd', 'csf')
    Check 'ZG07-1 env ZEITGEISTD_REPO wins over kitchen.json' ($r.calls[0].cwd -eq $fakeRepo)
    Remove-Item -LiteralPath (Join-Path $kitchen 'kitchen.json')
    $r = Invoke-Station @('-Cmd', 'csf') @{ ZEITGEISTD_REPO = $null }
    $def = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), 'source', 'repos', 'zeitgeistd')
    Check 'ZG07-1 neither: the default checkout under the user profile' ($r.out -match [regex]::Escape("$def (from default)")) $r.out
    $r = Invoke-Station @('-Cmd', 'csf') @{ ZEITGEISTD_REPO = (Join-Path $tmp 'not-a-checkout') }
    Check 'ZG07-1 a folder that is not a zeitgeistd checkout: exit 1, nothing run' ($r.code -eq 1 -and $r.calls.Count -eq 0 -and $r.out -match 'no zeitgeistd checkout at') $r.out

    # config.json: other keys kept, a wrong heartbeat_path corrected, a broken file never overwritten
    Set-Content -LiteralPath $cfgPath -Value '{"models.fast": "m-fast", "heartbeat_path": "C:\\elsewhere\\hb.json", "gate.blacklist": ["a"]}'
    $r = Invoke-Station @('-Cmd', 'csf'); $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    Check 'ZG07-1 config.json: other keys kept, heartbeat_path corrected and said' ($r.code -eq 0 -and $cfg.'models.fast' -eq 'm-fast' -and @($cfg.'gate.blacklist')[0] -eq 'a' -and $cfg.heartbeat_path -eq $beat -and $r.out -match 'was ''C:\\elsewhere\\hb\.json''') $r.out
    Set-Content -LiteralPath $cfgPath -Value '{"models.fast": '; $before = Get-Content -LiteralPath $cfgPath -Raw
    $r = Invoke-Station @('-Cmd', 'csf')
    Check 'ZG07-1 config.json that is not JSON: exit 1, nothing run, file unchanged' ($r.code -eq 1 -and $r.calls.Count -eq 0 -and (Get-Content -LiteralPath $cfgPath -Raw) -eq $before) $r.out
    Remove-Item -LiteralPath $cfgPath

    # ---- ZG07-2: free RAM and the Ollama probe gate sweep and rem; a stop is exit 11 with a heartbeat skip ----
    $r = Invoke-Station @('-Cmd', 'sweep') @{ KITCHEN_FAKE_FREE_MB = '2499' }
    $mods = Get-Mods $r
    Check 'ZG07-2 under 2,500 MB free: exit 11, the RAM gate named, no module run but the skip' ($r.code -eq 11 -and $r.out -match 'free RAM 2499 MB is under 2500 MB' -and $mods.Count -eq 1) $r.out
    Check 'ZG07-2 the skip goes to the heartbeat through health --skip <why> --run sweep' ($mods[0] -eq 'zeitgeistd.health --skip free RAM 2499 MB is under 2500 MB --run sweep' -and $r.out -match 'heartbeat skip written') ($mods -join '|')
    Check 'ZG07-2 the wait is written for the Yard (no retry used)' ((Test-Path -LiteralPath "$($r.run).wait") -and (Get-Content -LiteralPath "$($r.run).wait" -Raw).Trim() -eq '900')
    $r = Invoke-Station @('-Cmd', 'rem') @{ KITCHEN_FAKE_FREE_MB = '2500' }
    Check 'ZG07-2 exactly 2,500 MB free passes the RAM gate (rem: the same gates)' ($r.code -eq 0 -and $r.out -match 'free RAM 2500 MB' -and (Get-Mods $r) -contains 'zeitgeistd.rem') $r.out
    $r = Invoke-Station @('-Cmd', 'sweep') @{ KITCHEN_OLLAMA_URL = "http://127.0.0.1:$closedPort" }
    Check 'ZG07-2 Ollama down: exit 11, the Ollama gate named, skip recorded, nothing else run' ($r.code -eq 11 -and $r.out -match 'Ollama: Ollama is not running' -and ((Get-Mods $r) -join '|') -match '^zeitgeistd\.health --skip Ollama: Ollama is not running --run sweep$') $r.out
    $r = Invoke-Station @('-Cmd', 'rem') @{ KITCHEN_OLLAMA_URL = 'off' }
    Check 'ZG07-2 Ollama switched off: rem waits too (exit 11)' ($r.code -eq 11 -and ((Get-Mods $r) -join '|') -match '--run rem$') $r.out
    $r = Invoke-Station @('-Cmd', 'sweep') @{ KITCHEN_OLLAMA_URL = 'http://192.168.1.50:11434' }
    Check 'ZG07-2 an Ollama address off this PC is refused: exit 1, no sweep module' ($r.code -eq 1 -and $r.out -match 'not this PC' -and @(Get-Mods $r | Where-Object { $_ -notmatch '^zeitgeistd\.health --skip' }).Count -eq 0) $r.out
    $r = Invoke-Station @('-Cmd', 'csf') @{ KITCHEN_FAKE_FREE_MB = '100'; KITCHEN_OLLAMA_URL = "http://127.0.0.1:$closedPort" }
    Check 'ZG07-2 csf only reads: no gate stops it' ($r.code -eq 0 -and (Get-Mods $r)[0] -eq 'zeitgeistd.csf') $r.out
    $hold = [Threading.Mutex]::new($false, 'Global\brain-kitchen-gpu'); [void]$hold.WaitOne(0)
    try { $r = Invoke-Station @('-Cmd', 'sweep', '-GpuWaitSec', '1') } finally { $hold.ReleaseMutex(); $hold.Dispose() }
    Check 'ZG07-2 GPU busy with another local model: exit 11 and a skip, no sweep module' ($r.code -eq 11 -and $r.out -match 'graphics card is busy' -and ((Get-Mods $r) -join '|') -match '^zeitgeistd\.health --skip the graphics card is busy') $r.out

    # ---- ZG07-3: the specs have no agent step; the standing lines are in the change note, not in kitchen.json; bounded runs ----
    foreach ($nm in @('lobe-sweep')) {   # lobe-rem is four Steps since ZG-42: linted in the ZG-42 block below
        $raw = Get-Content -LiteralPath (Join-Path $repoRoot "kitchen\recipes\$nm.json") -Raw; $rj = $raw | ConvertFrom-Json -AsHashtable
        $cmdName = $nm -replace '^lobe-', ''
        $agentish = @($rj.steps | Where-Object { $_.station -ne 'lobe' -or $_.ai -or $_.script -or $_.args.Keys.Count -ne 1 -or $_.args.Cmd -ne $cmdName })
        Check "ZG07-3 $nm has only lobe steps with Cmd $cmdName (no agent, no cook, no ai station)" (@($rj.steps).Count -eq 1 -and $agentish.Count -eq 0)
        Check "ZG07-3 $nm names no prompt, crew, model or tools anywhere" ($raw -notmatch '(?i)"(prompt|order|supplier|cook|model|tools|role|context|private|public|about)"\s*:')
        $mm = [string]$rj.steps[0].mustMatch; $other = if ($cmdName -eq 'sweep') { 'rem' } else { 'sweep' }
        Check "ZG07-3 $nm mustMatch takes the Step's done line and not a failure or the other command" ("x`nlobe: $cmdName done items=3 dropped=0 ms=41`n" -match $mm -and "lobe: $cmdName FAILED (x) ms=1" -notmatch $mm -and "lobe: $other done items=1 dropped=0 ms=1" -notmatch $mm)
    }
    $kj = Get-Content -LiteralPath (Join-Path $repoRoot 'kitchen\kitchen.json') -Raw | ConvertFrom-Json
    Check 'ZG07-3 kitchen.json has no lobe standing order (Jordan applies them; the Yard stays as it is)' (@(@($kj.standing) + @($kj.standingPaused) | Where-Object { $_.recipe -like 'lobe-*' }).Count -eq 0)
    $note = Get-Content -LiteralPath (Join-Path $repoRoot 'docs\changes\ZG-07.md') -Raw
    Check 'ZG07-3 the change note holds the lobe-sweep standing line (every 2 hours)' ($note -match [regex]::Escape('{ "name": "lobe sweep", "recipe": "lobe-sweep", "everyHours": 2 }'))
    Check 'ZG07-3 the change note holds the lobe-rem standing line (daily at 4, inside the 4-5 am window)' ($note -match [regex]::Escape('{ "name": "lobe rem", "recipe": "lobe-rem", "everyHours": 24, "atHour": 4 }'))
    # the specs turn into Yard work: a temp kitchen, KITCHEN_UNDER_TEST, nothing started
    $ck = Join-Path $tmp 'cook-k'; New-Item -ItemType Directory -Force -Path $ck | Out-Null
    foreach ($kv in @{ BRAIN_KITCHEN = $ck; KITCHEN_RECIPES = (Join-Path $repoRoot 'kitchen\recipes'); KITCHEN_UNDER_TEST = '1'; BRAIN_NTFY_TOPIC = $null; KITCHEN_JOB = $null }.GetEnumerator()) { [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value) }
    $cj = & $pwshExe -NoProfile -File (Join-Path $repoRoot 'kitchen\cook.ps1') -Recipe lobe-sweep -Json 2>&1 | Out-String
    $job = try { $cj | ConvertFrom-Json } catch { $null }
    $jf = if ($job.job) { Get-Content -LiteralPath (Join-Path $ck "jobs\$($job.job).json") -Raw | ConvertFrom-Json } else { $null }
    Check 'ZG07-3 lobe-sweep cooks into one Step running stations\lobe.ps1 -Cmd sweep' ($job.ok -and @($jf.steps).Count -eq 1 -and $jf.steps[0].script -match 'stations[\\/]lobe\.ps1$' -and $jf.steps[0].args.Cmd -eq 'sweep') $cj
    # under scripts/run-bounded.ps1 with a 120 s limit, as the Yard runs a Step
    [Environment]::SetEnvironmentVariable('LOBE_FAKE_LOG', (Join-Path $tmp 'bounded.jsonl'))
    [Environment]::SetEnvironmentVariable('BRAIN_KITCHEN', $kitchen); [Environment]::SetEnvironmentVariable('KITCHEN_UNDER_TEST', $null)
    $bo = & $pwshExe -NoProfile -Command "& '$bounded' -Script '$station' -TimeoutSeconds 120 -MaxMB 1500 -ScriptArgs @('-Cmd', 'rem'); exit `$LASTEXITCODE" 2>&1 | Out-String; $bc = $LASTEXITCODE
    Check 'ZG07-3 rem (gates, GPU lock, one module) under run-bounded (120 s): exit 0 and the done line' ($bc -eq 0 -and $bo -match '(?m)^lobe: rem done items=7 dropped=3') $bo

    # ---- ZG-17: skips are counted by kind; after rem, one push with counts only (KITCHEN_NOTIFY_LOG writes instead of sending) ----
    $k17 = Join-Path $tmp 'k17'; $yc = Join-Path $k17 'lobe\yard-counts.json'; $topic17 = 'zg17-test-topic-0001'
    $readYc = { if (Test-Path -LiteralPath $yc) { Get-Content -LiteralPath $yc -Raw | ConvertFrom-Json -AsHashtable } else { $null } }
    foreach ($i in 1..3) { $r = Invoke-Station @('-Cmd', 'sweep') @{ BRAIN_KITCHEN = $k17; KITCHEN_FAKE_FREE_MB = '100' } }
    $r = Invoke-Station @('-Cmd', 'sweep') @{ BRAIN_KITCHEN = $k17; KITCHEN_OLLAMA_URL = 'http://192.168.1.50:11434' }
    $ycRaw = Get-Content -LiteralPath $yc -Raw; $y = & $readYc
    Check 'ZG17-2 three RAM stops are three sweep skips of kind ram; an off-PC refusal is not a skip' (@($y.skips).Count -eq 3 -and @($y.skips | Where-Object { $_.cmd -eq 'sweep' -and $_.kind -eq 'ram' }).Count -eq 3) $ycRaw
    Check 'ZG17-2 the counts file holds kinds, never the reason text' ($ycRaw -notmatch 'MB|free RAM|192\.168') $ycRaw
    # a fresh frame with words that must never leave this PC
    $frame17 = Join-Path $k17 'lobe\csf.json'
    $nowIso = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $leak = @('ZG17-TITLE Acme merger talks', 'https://example.com/zg17-leak', 'ZG17-SOURCE nytimes.com', 'ZG17-LOOP keep asking about the move')
    $writeFrame = {
        param($dec, $sig, $at)
        [ordered]@{ meta = [ordered]@{ state = 'ok'; compiled_utc = $at; last_sweep_utc = $at; counts = [ordered]@{ decisions_ready = $dec; world_signals_24h = $sig; post_mortems_due = 1 } }
            '1_normative_charter' = @{ note = $leak[3] }; '2_endogenous_self_state' = @{}
            '3_exogenous_world_deltas' = @{ signals = @(@{ title = $leak[0]; url = $leak[1]; source = $leak[2] }) }
            '4_epistemic_tensions' = @{ loops = @(@{ text = $leak[3] }) }; '5_decision_ready_nodes' = @(@{ title = $leak[0] }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $frame17 -Encoding utf8
    }
    & $writeFrame 2 14 $nowIso
    $n17 = Join-Path $tmp 'notify-17.txt'
    $r = Invoke-Station @('-Cmd', 'rem') @{ BRAIN_KITCHEN = $k17; KITCHEN_NOTIFY_LOG = $n17; BRAIN_NTFY_TOPIC = $null }
    Check 'ZG17-2 push off (no push-on, no topic): rem is done, nothing is written or sent, nothing is recorded' ($r.code -eq 0 -and $r.out -match '(?m)^lobe: rem done items=7' -and $r.out -match 'lobe: push not sent \(off\)' -and -not (Test-Path -LiteralPath $n17) -and -not (& $readYc).push.line) $r.out
    $r = Invoke-Station @('-Cmd', 'rem') @{ BRAIN_KITCHEN = $k17; KITCHEN_NOTIFY_LOG = $n17; BRAIN_NTFY_TOPIC = $topic17 }
    $pl = @(if (Test-Path -LiteralPath $n17) { Get-Content -LiteralPath $n17 })
    Check 'ZG17-2 push on: one line through notify.ps1 -Safe with the World line, the done line last' ($r.code -eq 0 -and $r.out -match 'lobe: push sent' -and $pl.Count -eq 1 -and $pl[0] -ceq "INFO|$topic17|World: 2 decisions ready, 14 signals since yesterday; sweeps skipped 3x (RAM)" -and $r.out.TrimEnd() -match 'lobe: rem done items=7 dropped=3 ms=\d+$') "$($r.out)`n$($pl -join "`n")"
    $pushText = if ($pl.Count) { ($pl[0] -split '\|', 3)[2] } else { '' }
    Check 'ZG17-3 the push carries no title, URL, source name, loop text or skip reason' ($pl.Count -eq 1 -and @($leak | Where-Object { $pl[0].Contains($_) -or $pl[0].Contains(($_ -split ' ')[0]) }).Count -eq 0 -and $pl[0] -notmatch 'http|\.com|MB|Acme|merger|nytimes|asking|free RAM') ($pl -join "`n")
    Check 'ZG17-3 the push text is only numbers and fixed words' ($pushText -cmatch '^World: (\d+ (decisions? ready|questions?|signals? since yesterday)(, |; |$))*((sweeps|rem runs|runs) skipped \d+x( \(((RAM|Ollama|graphics card)(, )?)+\))?)?$') $pushText
    $y = & $readYc
    Check 'ZG17-2 the push is recorded (line and time) in yard-counts.json, not in watch\lobe.json' ([string]$y.push.line -eq 'World: 2 decisions ready, 14 signals since yesterday; sweeps skipped 3x (RAM)' -and $null -ne $y.push.at -and -not (Test-Path -LiteralPath (Join-Path $k17 'watch\lobe.json') -PathType Leaf)) (Get-Content -LiteralPath $yc -Raw)
    & $writeFrame 5 20 $nowIso
    $r = Invoke-Station @('-Cmd', 'rem') @{ BRAIN_KITCHEN = $k17; KITCHEN_NOTIFY_LOG = $n17; BRAIN_NTFY_TOPIC = $topic17 }
    Check 'ZG17-2 at most once a day: new counts the same day send nothing' ($r.code -eq 0 -and $r.out -match 'push not sent \(one already went out today\)' -and @(Get-Content -LiteralPath $n17).Count -eq 1) $r.out
    # yesterday's push with the same line: unchanged counts send nothing; a different line sends the next day
    $y = & $readYc; $y.push.at = [DateTime]::UtcNow.AddDays(-1).AddHours(-1).ToString('o'); $y.push.line = 'World: 5 decisions ready, 20 signals since yesterday; sweeps skipped 3x (RAM)'
    $y | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $yc -Encoding utf8
    $r = Invoke-Station @('-Cmd', 'rem') @{ BRAIN_KITCHEN = $k17; KITCHEN_NOTIFY_LOG = $n17; BRAIN_NTFY_TOPIC = $topic17 }
    Check 'ZG17-2 only when counts changed: the same line as the last push sends nothing' ($r.code -eq 0 -and $r.out -match 'push not sent \(the counts have not changed' -and @(Get-Content -LiteralPath $n17).Count -eq 1) $r.out
    & $writeFrame 6 20 $nowIso
    $r = Invoke-Station @('-Cmd', 'rem') @{ BRAIN_KITCHEN = $k17; KITCHEN_NOTIFY_LOG = $n17; BRAIN_NTFY_TOPIC = $topic17; KITCHEN_NOTIFY_FAIL = '502' }
    Check 'ZG17-2 a failed send: rem is still done (exit 0), the push says not sent, nothing is recorded' ($r.code -eq 0 -and $r.out -match 'lobe: push not sent \(failed\)' -and $r.out -match '(?m)^lobe: rem done' -and [string](& $readYc).push.line -match '^World: 5 ') $r.out
    $r = Invoke-Station @('-Cmd', 'rem') @{ BRAIN_KITCHEN = $k17; KITCHEN_NOTIFY_LOG = $n17; BRAIN_NTFY_TOPIC = $topic17 }
    $pl = @(Get-Content -LiteralPath $n17)
    Check 'ZG17-2 the next day with changed counts: one more push' ($r.out -match 'lobe: push sent' -and $pl.Count -eq 2 -and $pl[1] -ceq "INFO|$topic17|World: 6 decisions ready, 20 signals since yesterday; sweeps skipped 3x (RAM)") ($pl -join "`n")
    # a stale frame (5 h) gives no counts; zero everywhere is no push at all
    $k17b = Join-Path $tmp 'k17b'; $frame17 = Join-Path $k17b 'lobe\csf.json'; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $frame17) | Out-Null
    & $writeFrame 0 0 $nowIso
    $r = Invoke-Station @('-Cmd', 'rem') @{ BRAIN_KITCHEN = $k17b; KITCHEN_NOTIFY_LOG = (Join-Path $tmp 'notify-17b.txt'); BRAIN_NTFY_TOPIC = $topic17 }
    Check 'ZG17-2 every count zero: no push' ($r.code -eq 0 -and $r.out -match 'push not sent \(every count is zero\)' -and -not (Test-Path -LiteralPath (Join-Path $tmp 'notify-17b.txt'))) $r.out
    & $writeFrame 9 9 ([DateTime]::UtcNow.AddHours(-5).ToString('yyyy-MM-ddTHH:mm:ssZ'))
    $r = Invoke-Station @('-Cmd', 'rem') @{ BRAIN_KITCHEN = $k17b; KITCHEN_NOTIFY_LOG = (Join-Path $tmp 'notify-17b.txt'); BRAIN_NTFY_TOPIC = $topic17 }
    Check 'ZG17-2 a stale frame (over 240 min) gives no counts, never old numbers as today''s' ($r.out -match 'push not sent \(every count is zero\)') $r.out
    [Environment]::SetEnvironmentVariable('BRAIN_NTFY_TOPIC', $null)   # no later run may see the test topic

    # ---- ZG-21: the verify bridge. Due PUBLIC claims become lobe-verify work orders (real cook.ps1, a temp Yard); answers go back ----
    $r = Invoke-Station @('-Cmd', 'verify')
    Check 'ZG21-1 verify before ZG-20: refused, nothing run, the missing module named' ($r.code -eq 1 -and $r.calls.Count -eq 0 -and $r.out -match 'zeitgeistd\.claims is not in the checkout') $r.out
    Set-Content -LiteralPath (Join-Path $fakeRepo 'zeitgeistd\claims.py') -Value ''
    $k21 = Join-Path $tmp 'k21'; $due21 = Join-Path $tmp 'due21.json'; $orders21 = Join-Path $k21 'lobe\verify-orders.json'
    # P1, P2 and a claim with no privacy come FIRST in the list, as if --public had let them through: the Step must still drop them
    $secret = @('ZG21-PRIVATE my landlord will raise the rent in March', 'ZG21-P1 the Yard job runner says the build passes', 'ZG21-NOPRIV a claim with no class')
    $mk = { param($id, $st, $pv, $i) $c = [ordered]@{ id = $id; statement = $st; source = "rss-zg21-$i"; source_name = "ZG21-SRCNAME wire $i"; band = 3; ingested = "2026-07-0$($i)T10:00:00+00:00"
            due = "2026-09-2$($i)T00:00:00+00:00"; status = 'PENDING'; overdue = $true; overdue_days = 20.0; signal = 60; law3_capped = $true; primary_artifact_url = "https://example.com/zg21-item-$i" }
        if ($pv) { $c.privacy = $pv }; $c }
    $claims21 = @((& $mk 'clm-zg21-p2' $secret[0] 'P2' 1), (& $mk 'clm-zg21-p1' $secret[1] 'P1' 2), (& $mk 'clm-zg21-np' $secret[2] $null 3))
    foreach ($i in 1..4) { $claims21 += & $mk "clm-zg21-$i" "ZG21 Acme will ship the X$i model by September" 'P0' $i }
    [ordered]@{ now = '2026-10-24T12:00:00+00:00'; public = $true; claims = $claims21; counts = @{ due = 7; not_yet_due = 0; undated = 0 } } | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $due21 -Encoding utf8
    $env21 = @{ BRAIN_KITCHEN = $k21; LOBE_FAKE_DUE = $due21; KITCHEN_RECIPES = (Join-Path $repoRoot 'kitchen\recipes'); KITCHEN_UNDER_TEST = '1'; BRAIN_AGENT_DEPTH = $null; KITCHEN_JOB = $null }
    $r = Invoke-Station @('-Cmd', 'verify') $env21
    $mods = Get-Mods $r
    $jobs21 = @(Get-ChildItem -LiteralPath (Join-Path $k21 'jobs') -Filter 'J*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable })
    Check 'ZG21-1 verify reads claims due --public --json and nothing else' ($r.code -eq 0 -and ($mods -join '|') -eq 'zeitgeistd.claims due --public --json') "$($r.out)`n$($mods -join '|')"
    Check 'ZG21-1 at most 3 work orders a day, each on Spec lobe-verify; the 4th claim waits' ($jobs21.Count -eq 3 -and @($jobs21 | Where-Object { $_.recipe -eq 'lobe-verify' }).Count -eq 3 -and $r.out -match 'lobe: verify filed=3 resolved=0 unknown=0 waiting=1 expired=0 not_public=3' -and $r.out -match '(?m)^lobe: verify done items=3 dropped=3 ms=\d+') $r.out
    $want = foreach ($i in 1..3) { "Claim: ZG21 Acme will ship the X$i model by September`nMade: 2026-07-0$i`nDue: 2026-09-2$i" }
    $got = @($jobs21 | ForEach-Object { [string]$_.vars.question })
    Check 'ZG21-1 the question is the claim statement and its two dates, exactly' ((@($got | Sort-Object) -join '#') -ceq (@($want | Sort-Object) -join '#')) ($got -join "`n---`n")
    $orderOk = @($jobs21 | Where-Object { $a0 = $_.steps[0].args; [string]$a0.Order -ceq [string]$_.vars.question -and ([string]$a0.Prompt).Contains([string]$_.vars.question) -and $a0.Public -eq $true -and $a0.Role -eq 'research' })
    Check 'ZG21-1 the work order''s goal (Order) is that question alone, and the Cloud crew''s prompt carries it' ($orderOk.Count -eq 3) ($jobs21 | ForEach-Object { $_.steps[0].args.Order })
    $jobRaw = (@(Get-ChildItem -LiteralPath (Join-Path $k21 'jobs'), (Join-Path $k21 'specs') -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n")
    Check 'ZG21-1 no claim id, source, source name, item URL, Charter, loop or history in any work order' ($jobRaw.Length -gt 0 -and $jobRaw -notmatch 'clm-zg21|rss-zg21|ZG21-SRCNAME|zg21-item|overdue|signal|law3|charter|loop|brier') ''
    $everywhere = (@(Get-ChildItem -LiteralPath $k21 -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n") + $r.out
    Check 'ZG21 privacy: a P1, P2 or unclassed claim never becomes a work order, nor is its text written anywhere (state or Step log)' (@($secret | Where-Object { $everywhere.Contains($_) -or $everywhere.Contains(($_ -split ' ')[0]) }).Count -eq 0 -and @($jobs21 | Where-Object { $_.vars.question -match 'ZG21-(PRIVATE|P1|NOPRIV)' }).Count -eq 0) ''
    $o21 = (Get-Content -LiteralPath $orders21 -Raw | ConvertFrom-Json -AsHashtable).orders
    Check 'ZG21-1 the work-order list keeps claim id, work order and state, never the statement' (@($o21).Count -eq 3 -and @($o21 | Where-Object { $_.state -eq 'filed' -and $_.job -match '^J\d+$' }).Count -eq 3 -and (Get-Content -LiteralPath $orders21 -Raw) -notmatch 'Acme') (Get-Content -LiteralPath $orders21 -Raw)
    $r = Invoke-Station @('-Cmd', 'verify') $env21
    Check 'ZG21-1 the same day again: nothing new filed (cap), nothing filed twice' ($r.code -eq 0 -and @(Get-ChildItem -LiteralPath (Join-Path $k21 'jobs') -Filter 'J*.json').Count -eq 3 -and $r.out -match 'filed=0 .*waiting=1') $r.out
    # the Spec: a copy of research (Cloud crew, web tools, SOURCES required), saving the answer where the Step reads it, then the collect Step
    $sp = Get-Content -LiteralPath (Join-Path $repoRoot 'kitchen\recipes\lobe-verify.json') -Raw | ConvertFrom-Json -AsHashtable; $s0 = $sp.steps[0]
    $vars = @([regex]::Matches([string]$s0.args.Prompt, '\{\{(\w+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    Check 'ZG21-1 lobe-verify: research step (web tools, SOURCES required), public, one var, answer saved to lobe\verify\<job>.md' ($sp.public -eq $true -and @($sp.vars.Keys) -join ',' -eq 'question' -and $s0.station -eq 'agent' -and $s0.args.Role -eq 'research' -and $s0.args.Tools -match 'WebSearch' -and $s0.mustMatch -eq 'SOURCES' -and $s0.args.SaveTo -eq '{{kitchen}}\lobe\verify\{{job}}.md' -and ($vars -join ',') -eq 'question')
    Check 'ZG21-2 lobe-verify then runs the lobe Step to collect the answer (no new filing from inside a work order)' (@($sp.steps).Count -eq 2 -and $sp.steps[1].station -eq 'lobe' -and $sp.steps[1].args.Cmd -eq 'verify' -and $sp.steps[1].args.Only -eq 'collect' -and "lobe: verify done items=1 dropped=0 ms=3" -match $sp.steps[1].mustMatch)

    # ---- ZG21-2: saved answers go back through claims resolve --by auto; zeitgeistd decides what counts as evidence ----
    $jobOf = @{}; foreach ($o in $o21) { $jobOf[[string]$o.claim] = [string]$o.job }
    $ansDir = Join-Path $k21 'lobe\verify'; $f = @{}; foreach ($i in 1..3) { $f[$i] = Join-Path $ansDir "$($jobOf["clm-zg21-$i"]).md" }
    Set-Content -LiteralPath $f[1] -Encoding utf8 -Value "It shipped on 2026-09-15 (see https://example.org/body-link).`n**VERDICT:** VERIFIED`n`n## SOURCES`n- https://example.org/a.`n- <https://example.org/b>`n- https://user:pw@example.org/c`n- https://EXAMPLE.org/a"
    Set-Content -LiteralPath $f[2] -Encoding utf8 -Value "VERDICT: VERIFIED`nOn second thought`nVERDICT: REFUTED`nSOURCES`nhttps://example.org/x"
    Set-Content -LiteralPath $f[3] -Encoding utf8 -Value "VERDICT: REFUTED`nSOURCES`nhttps://example.com/zg21-item-3"
    $r = Invoke-Station @('-Cmd', 'verify', '-Only', 'collect') ($env21 + @{ LOBE_FAKE_REFUSE = 'clm-zg21-3:REFUTED' })
    $mods = Get-Mods $r
    $wantMods = @("zeitgeistd.claims resolve clm-zg21-1 VERIFIED --by auto --sources https://example.org/a https://example.org/b $($f[1])",
        "zeitgeistd.claims resolve clm-zg21-2 UNKNOWN --by auto --sources $($f[2])",
        "zeitgeistd.claims resolve clm-zg21-3 REFUTED --by auto --sources https://example.com/zg21-item-3 $($f[3])",
        "zeitgeistd.claims resolve clm-zg21-3 UNKNOWN --by auto --sources $($f[3])")
    Check 'ZG21-2 a VERDICT and its SOURCES URLs (not body links, no user:pw, no repeats) go to claims resolve --by auto with the answer file' ($mods[0] -ceq $wantMods[0]) "$($mods -join "`n")"
    Check 'ZG21-2 two different VERDICT lines are unparseable: UNKNOWN with the file path kept' ($mods[1] -ceq $wantMods[1]) "$($mods -join "`n")"
    Check 'ZG21-2 a verdict zeitgeistd refuses as evidence (exit 3) is never forced: UNKNOWN with the file path kept' ($mods.Count -eq 4 -and $mods[2] -ceq $wantMods[2] -and $mods[3] -ceq $wantMods[3]) "$($mods -join "`n")"
    Check 'ZG21-2 collect: no due list, no new work order, never --by owner' ($r.code -eq 0 -and @($mods | Where-Object { $_ -match ' due |--by owner' }).Count -eq 0 -and @(Get-ChildItem -LiteralPath (Join-Path $k21 'jobs') -Filter 'J*.json').Count -eq 3 -and $r.out -match '(?m)^lobe: verify done items=3 dropped=0') $r.out
    $o21 = (Get-Content -LiteralPath $orders21 -Raw | ConvertFrom-Json -AsHashtable).orders; $st = @{}; foreach ($o in $o21) { $st[[string]$o.claim] = "$($o.state)/$($o.status)" }
    Check 'ZG21-2 the list records each result (resolved VERIFIED, UNKNOWN, UNKNOWN) with its answer file' ($st['clm-zg21-1'] -eq 'resolved/VERIFIED' -and $st['clm-zg21-2'] -eq 'resolved/UNKNOWN' -and $st['clm-zg21-3'] -eq 'resolved/UNKNOWN' -and @($o21 | Where-Object { $_.answer }).Count -eq 3) (Get-Content -LiteralPath $orders21 -Raw)
    $r = Invoke-Station @('-Cmd', 'verify', '-Only', 'collect') $env21
    Check 'ZG21-2 an answer is handed back once' ($r.code -eq 0 -and (Get-Mods $r).Count -eq 0) $r.out
    # the next day: rem files the waiting claim (the cap is per day); claims already answered are not filed again; rem's result is its own
    $oj = Get-Content -LiteralPath $orders21 -Raw | ConvertFrom-Json -AsHashtable; foreach ($o in $oj.orders) { $o.filed = [DateTime]::UtcNow.AddDays(-1).AddHours(-1).ToString('o') }
    $oj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $orders21 -Encoding utf8
    $r = Invoke-Station @('-Cmd', 'rem') $env21
    $jobs21 = @(Get-ChildItem -LiteralPath (Join-Path $k21 'jobs') -Filter 'J*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable })
    Check 'ZG21-1 the next day, after rem: the waiting claim is filed, no answered claim again, rem done line last' ($r.code -eq 0 -and $jobs21.Count -eq 4 -and @($jobs21 | Where-Object { $_.vars.question -match 'X4 model' }).Count -eq 1 -and $r.out -match 'lobe: verify filed=1 ' -and $r.out.TrimEnd() -match 'lobe: rem done items=7 dropped=3 ms=\d+$') $r.out
    # a work order with no answer after 7 days is let go and its claim may be filed again
    $oj = Get-Content -LiteralPath $orders21 -Raw | ConvertFrom-Json -AsHashtable; foreach ($o in $oj.orders) { $o.filed = [DateTime]::UtcNow.AddDays(-8).ToString('o') }
    $oj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $orders21 -Encoding utf8
    $r = Invoke-Station @('-Cmd', 'verify') $env21
    Check 'ZG21-1 no answer after 7 days: let go and filed again' ($r.code -eq 0 -and $r.out -match 'expired=1' -and $r.out -match 'filed=1 ' -and @(Get-ChildItem -LiteralPath (Join-Path $k21 'jobs') -Filter 'J*.json').Count -eq 5) $r.out
    # a list that does not say it is public files nothing
    [ordered]@{ public = $false; claims = $claims21 } | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $due21 -Encoding utf8
    Remove-Item -LiteralPath $orders21
    $r = Invoke-Station @('-Cmd', 'verify') $env21
    Check 'ZG21 privacy: a due list without public=true files nothing (exit 1)' ($r.code -eq 1 -and $r.out -match 'gave no public list' -and @(Get-ChildItem -LiteralPath (Join-Path $k21 'jobs') -Filter 'J*.json').Count -eq 5) $r.out
    foreach ($n in 'KITCHEN_RECIPES', 'KITCHEN_UNDER_TEST', 'LOBE_FAKE_DUE') { [Environment]::SetEnvironmentVariable($n, $null) }

    # ---- ZG07-4: the suites are registered where verify-all and the Yard look ----
    $va = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\verify-all.json') -Raw | ConvertFrom-Json
    $bm = @($va.suites | Where-Object { $_.name -eq 'brain-monitor' })[0]
    $listed = @(Get-ChildItem -Path (Join-Path $repoRoot $bm.glob) -File | Where-Object { $bm.skip -notcontains $_.Name } | ForEach-Object Name)
    Check 'ZG07-4 verify-all.json: the brain-monitor entry lists Test-LobeStation.ps1 (its glob, nothing skipped)' ($listed -contains 'Test-LobeStation.ps1')
    $zg = @($va.suites | Where-Object { $_.name -eq 'zeitgeistd' })
    Check 'ZG07-4 verify-all.json: the lobe''s own suite (zeitgeistd scripts\test.ps1) is an entry with limits' ($zg.Count -eq 1 -and $zg[0].glob -eq 'scripts\test.ps1' -and [int]$zg[0].timeoutSeconds -gt 0 -and [int]$zg[0].maxMB -gt 0 -and $zg[0].dir -match 'zeitgeistd$')

    # ---- ZG-42 Sleep: the night in four Steps, every Step's exit code and ms in watch\lobe.json sleep[], night steps wired and guarded ----
    $r42 = Join-Path $tmp 'repo42'; Copy-Item -LiteralPath $fakeRepo -Destination $r42 -Recurse
    foreach ($m in 'governor', 'claims', 'edges', 'trust', 'decisions', 'causal', 'brief') { Set-Content -LiteralPath (Join-Path $r42 "zeitgeistd\$m.py") -Value '' }
    # stand-ins for scripts/memory-check.ps1 and memory-truth.ps1: each logs its name and args, sleeps LOBE_FAKE_MEM_SLEEP s, exits by LOBE_FAKE_MEM_EXIT ("memory-truth=3")
    $memDir = Join-Path $tmp 'mem-scripts'; New-Item -ItemType Directory -Force -Path $memDir | Out-Null
    foreach ($nm in 'memory-check', 'memory-truth') {
        Set-Content -LiteralPath (Join-Path $memDir "$nm.ps1") -Value (@'
$me = '@NAME@'; Add-Content -LiteralPath $env:LOBE_FAKE_MEM_LOG -Value "$me $($args -join ' ')"; "$me ran"
if ($env:LOBE_FAKE_MEM_SLEEP) { Start-Sleep -Seconds ([int]$env:LOBE_FAKE_MEM_SLEEP) }
foreach ($pair in @(([string]$env:LOBE_FAKE_MEM_EXIT) -split ',' | Where-Object { $_ })) { $kv = $pair -split '='; if ($kv[0] -eq $me) { exit ([int]$kv[1]) } }
exit 0
'@ -replace '@NAME@', $nm)
    }
    $k42 = Join-Path $tmp 'k42'; $memLog = Join-Path $tmp 'mem.log'
    $hb42 = Join-Path $k42 'watch\lobe.json'; $sleep42 = Join-Path $k42 'lobe\sleep.json'; $cfg42 = Join-Path $k42 'lobe\config.json'
    $due42 = Join-Path $tmp 'due42.json'; Set-Content -LiteralPath $due42 -Value '{"now":"2026-10-24T12:00:00+00:00","public":true,"claims":[],"counts":{"due":0}}'   # ZG-21's verify after rem: nothing due
    $night = @{ BRAIN_KITCHEN = $k42; ZEITGEISTD_REPO = $r42; KITCHEN_JOB = 'WO-T1'; LOBE_FAKE_DUE = $due42; KITCHEN_LOBE_SCRIPTS = $memDir; LOBE_FAKE_MEM_LOG = $memLog; LOBE_FAKE_MEM_EXIT = $null; LOBE_FAKE_MEM_SLEEP = $null }
    function Night([string[]]$StepArgs, [hashtable]$More = @{}) { $e = @{}; foreach ($k in $night.Keys) { $e[$k] = $night[$k] }; foreach ($k in $More.Keys) { $e[$k] = $More[$k] }; Invoke-Station $StepArgs $e }
    function Put-Beat { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $hb42) | Out-Null; Set-Content -LiteralPath $hb42 -Value '{"name":"lobe","lastRun":"2026-10-24T04:00:00Z","everyMin":120,"error":"csf failed: x","skipped":[]}' }
    function Read-Sleep42 { Get-Content -LiteralPath $sleep42 -Raw | ConvertFrom-Json }
    New-Item -ItemType Directory -Force -Path $k42 | Out-Null; Put-Beat
    Set-Content -LiteralPath (Join-Path $k42 'events.jsonl') -Value @('{"ts":"2026-10-24T03:58:00Z","type":"doctor","job":"","ok":true,"problems":"","archived":2}', '{"ts":"2026-10-24T09:58:00Z","type":"doctor","job":"","ok":true,"problems":"","archived":4}', '{"ts":"2026-10-24T09:59:00Z","type":"step.done","job":"WO-9"}')

    # A: a whole night, models.strong unset, memory-truth finds drift (exit 3)
    $r = Night @('-Cmd', 'rem'); $mods = Get-Mods $r
    Check 'ZG42-1 rem: exit 0 and the done line the Spec matches' ($r.code -eq 0 -and $r.out -match '(?m)^lobe: rem done items=7 dropped=3 ms=\d+') $r.out
    Check 'ZG42-1 rem runs governor check, actions, claims, edges, trust, rem (the core), then ZG-21''s verify (claims due), in that order' (($mods -join '|') -eq 'zeitgeistd.governor check --run rem|zeitgeistd.actions run|zeitgeistd.claims run|zeitgeistd.edges run|zeitgeistd.trust run|zeitgeistd.rem|zeitgeistd.claims due --public --json') ($mods -join '|')
    Check 'ZG42-1 decisions prepare and causal run are off without models.strong, and say so' ($mods -notcontains 'zeitgeistd.decisions prepare' -and $r.out -match 'decisions prepare is off: the lobe''s config\.json has no models\.strong' -and $r.out -match 'causal run is off')
    $vz = @($r.calls | Where-Object { $_.mod -eq 'zeitgeistd.claims' -and $_.rest[0] -eq 'due' })
    Check 'ZG42-1 the governor is asked before the GPU lock; every night step runs under it; verify runs after the lock is released' (@($r.calls | Where-Object { $_.mod -eq 'zeitgeistd.governor' })[0].gpu -eq 'free' -and @($r.calls | Where-Object { $_.mod -ne 'zeitgeistd.governor' -and -not ($_.mod -eq 'zeitgeistd.claims' -and $_.rest[0] -eq 'due') -and $_.gpu -ne 'held' }).Count -eq 0 -and $vz.Count -eq 1 -and $vz[0].gpu -eq 'free')
    $s = Read-Sleep42
    Check 'ZG42-1 rem opens the night for its work order' ($s.job -eq 'WO-T1' -and -not $s.closed -and (Get-Content -LiteralPath $sleep42 -Raw) -match '"night": "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"') (Get-Content -LiteralPath $sleep42 -Raw)
    $r = Night @('-Cmd', 'memory-check')
    Check 'ZG42-1 memory-check: scripts/memory-check.ps1 -Quiet under run-bounded, exit 0 and the done line' ($r.code -eq 0 -and $r.out -match '(?m)^lobe: memory-check done exit=0 ms=\d+' -and (Get-Content -LiteralPath $memLog) -contains 'memory-check -Quiet') $r.out
    $r = Night @('-Cmd', 'memory-truth') @{ LOBE_FAKE_MEM_EXIT = 'memory-truth=3' }
    Check 'ZG42-1 a failing memory Step (drift, exit 3) still exits 0 so the frame Step runs; it is named' ($r.code -eq 0 -and $r.out -match '(?m)^lobe: memory-truth done exit=3 ms=\d+' -and $r.out -match 'memory-truth FAILED inside the night: drift found') $r.out
    $r = Night @('-Cmd', 'csf'); $mods = Get-Mods $r
    Check 'ZG42-1 csf: the frame, then brief (FRAME.md); exit 0 and the done line' ($r.code -eq 0 -and ($mods -join '|') -eq 'zeitgeistd.csf|zeitgeistd.brief' -and $r.out -match '(?m)^lobe: csf done items=0 dropped=0 ms=\d+') (($mods -join '|') + "`n" + $r.out)
    Check 'ZG42-2 the archive is read from the doctor''s LAST report, never run' ($r.out -match 'archive: done by Site cleanup at 2026-10-24T09:58:00Z \(archived 4 work orders' -and @($mods | Where-Object { $_ -match 'archive|prune|backup' }).Count -eq 0) $r.out
    $s = Read-Sleep42; $names = @($s.steps | ForEach-Object step)
    Check 'ZG42-1 sleep.json: every step of the night in order, and the night closed' (($names -join '|') -eq 'governor check|actions run|claims run|edges run|trust run|decisions prepare|rem|causal run|verify|memory-check|memory-truth|csf|brief|archive' -and $s.closed) ($names -join '|')
    $hb = Get-Content -LiteralPath $hb42 -Raw | ConvertFrom-Json
    $hs = @($hb.sleep); $mt = @($hs | Where-Object step -eq 'memory-truth')[0]; $dp = @($hs | Where-Object step -eq 'decisions prepare')[0]
    Check 'ZG42-1 watch\lobe.json sleep[] carries each step''s exit code and ms' ($hs.Count -eq 14 -and $mt.exit -eq 3 -and $mt.state -eq 'failed' -and @($hs | Where-Object { $_.ms -isnot [long] -and $_.ms -isnot [int] }).Count -eq 0 -and @($hs | Where-Object step -eq 'rem')[0].exit -eq 0) (Get-Content -LiteralPath $hb42 -Raw)
    Check 'ZG42-1 a step that did not run says why (off), with no exit code' ($dp.state -eq 'off' -and $null -eq $dp.exit -and $dp.why -match 'models\.strong')
    Check 'ZG42-1 the failed step is named in sleepFailed and in the heartbeat error (the Watch reads it); zeitgeistd''s own error is kept' ((@($hb.sleepFailed) -join '|') -eq 'memory-truth (exit 3)' -and $hb.error -match '^csf failed: x; sleep: memory-truth \(exit 3\) failed$') $hb.error
    Check 'ZG42-1 the heartbeat''s own fields are kept as written (lastRun stays the same string)' ((Get-Content -LiteralPath $hb42 -Raw) -match '"lastRun":"2026-10-24T04:00:00Z"' -and $hb.name -eq 'lobe' -and $hb.everyMin -eq 120)
    # zeitgeistd rewrites the heartbeat on its next run; the next station run puts sleep[] back, and its error words are not doubled
    Put-Beat; $r = Night @('-Cmd', 'health') @{ KITCHEN_JOB = $null }; $raw = Get-Content -LiteralPath $hb42 -Raw
    Check 'ZG42-1 any later station run puts sleep[] back into a rewritten heartbeat' ($raw -match '"sleep":\[' -and $raw -match '"sleepClosed":"\d{4}-' -and ([regex]::Matches($raw, 'sleep: memory-truth')).Count -eq 1) $raw

    # B: models.strong set: decisions prepare runs under the lock; causal gets --lock-held; causal's exit 11 is "waits", not a failure
    Set-Content -LiteralPath $cfg42 -Value (@{ heartbeat_path = $hb42; 'models.strong' = 'm-strong' } | ConvertTo-Json)
    $r = Night @('-Cmd', 'rem') @{ LOBE_FAKE_CODES = 'zeitgeistd.causal=11' }; $mods = Get-Mods $r
    $cz = @($r.calls | Where-Object { $_.mod -eq 'zeitgeistd.causal' })[0]
    Check 'ZG42 decisions prepare runs (models.strong set) before rem, holding the GPU lock' ($mods -contains 'zeitgeistd.decisions prepare' -and [array]::IndexOf($mods, 'zeitgeistd.decisions prepare') -lt [array]::IndexOf($mods, 'zeitgeistd.rem') -and @($r.calls | Where-Object { $_.mod -eq 'zeitgeistd.decisions' })[0].gpu -eq 'held') ($mods -join '|')
    Check 'ZG42 causal run comes right after rem with --lock-held (before verify), while the station holds the lock' ($mods[-2] -eq 'zeitgeistd.causal run --lock-held' -and $mods[-3] -eq 'zeitgeistd.rem' -and $mods[-1] -eq 'zeitgeistd.claims due --public --json' -and $cz.gpu -eq 'held') ($mods -join '|')
    $cs = @((Read-Sleep42).steps | Where-Object step -eq 'causal run')[0]
    Check 'ZG42 causal exit 11 = waits (named), rem still done' ($r.code -eq 0 -and $cs.state -eq 'waits' -and $cs.exit -eq 11 -and $r.out -match 'causal run waits' -and $r.out -match 'lobe: rem done') $r.out

    # C: a night step fails: named, the rest still run, rem's exit unchanged
    $r = Night @('-Cmd', 'rem') @{ LOBE_FAKE_CODES = 'zeitgeistd.edges=1' }; $mods = Get-Mods $r
    $es = @((Read-Sleep42).steps | Where-Object step -eq 'edges run')[0]
    Check 'ZG42 a failed night step (edges run) is named and never stops trust run, rem or causal' ($r.code -eq 0 -and $mods -contains 'zeitgeistd.trust run' -and $mods -contains 'zeitgeistd.rem' -and $r.out -match 'edges run FAILED with exit 1' -and $es.state -eq 'failed' -and $es.exit -eq 1) $r.out
    # C2: ZG-21's verify after rem fails (claims due gives no public list): named in sleep[] as verify failed; rem is still done; the push still runs
    $r = Night @('-Cmd', 'rem') @{ LOBE_FAKE_DUE = (Join-Path $tmp 'no-such-due.json') }
    $vs42 = @((Read-Sleep42).steps | Where-Object step -eq 'verify')[0]
    Check 'ZG42 a failed verify after rem is a named night step (failed), rem is still done, the push line still comes' ($r.code -eq 0 -and $vs42.state -eq 'failed' -and $vs42.why -match 'claims due' -and $r.out -match 'lobe: verify FAILED' -and $r.out -match 'lobe: push ' -and $r.out -match 'lobe: rem done') $r.out
    # D: the core rem fails: exit 1, FAILED, still in sleep[]
    $r = Night @('-Cmd', 'rem') @{ LOBE_FAKE_CODES = 'zeitgeistd.rem=4' }
    Check 'ZG42 the core rem failing: FAILED with its exit code, named in sleep[]' ($r.code -eq 4 -and $r.out -match 'lobe: rem FAILED \(rem exit 4\)' -and @((Read-Sleep42).steps | Where-Object step -eq 'rem')[0].state -eq 'failed') $r.out
    # E/F: the governor
    $r = Night @('-Cmd', 'rem') @{ LOBE_FAKE_CODES = 'zeitgeistd.governor=11' }; $mods = Get-Mods $r
    Check 'ZG42 governor exit 11: rem waits (exit 11), nothing else runs, the governor''s own heartbeat skip is not overwritten' ($r.code -eq 11 -and ($mods -join '|') -eq 'zeitgeistd.governor check --run rem' -and $r.out -match 'heartbeat skip written by the governor' -and (Get-Content -LiteralPath "$($r.run).wait" -Raw).Trim() -eq '900') (($mods -join '|') + "`n" + $r.out)
    Check 'ZG42 governor wait is in sleep[] (governor check waits, rem waits)' ((@((Read-Sleep42).steps | ForEach-Object { "$($_.step):$($_.state)" }) -join '|') -eq 'governor check:waits|rem:waits')
    $r = Night @('-Cmd', 'rem') @{ LOBE_FAKE_CODES = 'zeitgeistd.governor=3' }
    Check 'ZG42 governor refused (exit 3): rem is refused (exit 1) and runs nothing' ($r.code -eq 1 -and (Get-Mods $r).Count -eq 1 -and $r.out -match 'governor check --run rem exit 3') $r.out
    # G: a memory Step that hangs is cut at -StepSec and named; the Step still exits 0
    $r = Night @('-Cmd', 'rem'); $r = Night @('-Cmd', 'memory-check', '-StepSec', '2') @{ LOBE_FAKE_MEM_SLEEP = '20' }
    Check 'ZG42 a hung memory Step is cut at its limit (run-bounded 124), named, exit 0' ($r.code -eq 0 -and $r.out -match 'lobe: memory-check done exit=124' -and @((Read-Sleep42).steps | Where-Object step -eq 'memory-check')[0].why -match 'timed out after 2 s') $r.out
    # H: another work order's Step does not write into this night; a missing memory script is named
    $before = Get-Content -LiteralPath $sleep42 -Raw
    $r = Night @('-Cmd', 'memory-truth') @{ KITCHEN_JOB = 'WO-OTHER' }
    Check 'ZG42 a Step of another work order: no night open, sleep.json unchanged' ($r.code -eq 0 -and $r.out -match 'no night open for this work order' -and (Get-Content -LiteralPath $sleep42 -Raw) -eq $before) $r.out
    $r = Night @('-Cmd', 'memory-truth') @{ KITCHEN_LOBE_SCRIPTS = (Join-Path $tmp 'nowhere') }
    Check 'ZG42 a memory script that is missing is a named failure, not silence' ($r.code -eq 0 -and $r.out -match 'done exit=none' -and @((Read-Sleep42).steps | Where-Object step -eq 'memory-truth')[-1].state -eq 'failed') $r.out
    # J: the archive note: unknown with no report, failed when the doctor reported an archive problem
    Rename-Item -LiteralPath (Join-Path $k42 'events.jsonl') -NewName 'events.old'
    $r = Night @('-Cmd', 'csf')
    Check 'ZG42-2 no doctor report: archive unknown (named, not a failure)' ($r.code -eq 0 -and $r.out -match 'archive: unknown \(no Site cleanup report' -and @((Read-Sleep42).steps | Where-Object step -eq 'archive')[0].state -eq 'unknown') $r.out
    Set-Content -LiteralPath (Join-Path $k42 'events.jsonl') -Value '{"ts":"2026-10-24T10:00:00Z","type":"doctor","job":"","ok":false,"problems":"x; archive: disk full","archived":0}'
    $r = Night @('-Cmd', 'rem'); $r = Night @('-Cmd', 'csf')
    Check 'ZG42-2 an archive problem in the doctor''s report is a named failure in sleep[]' ($r.out -match 'archive: Site cleanup at 2026-10-24T10:00:00Z reported: archive: disk full' -and @((Read-Sleep42).steps | Where-Object step -eq 'archive')[0].state -eq 'failed') $r.out
    # a by-hand csf (no work order) leaves the closed night alone
    $before = Get-Content -LiteralPath $sleep42 -Raw; $r = Night @('-Cmd', 'csf') @{ KITCHEN_JOB = $null }
    Check 'ZG42 csf by hand does not reopen or change the night' ($r.code -eq 0 -and (Get-Content -LiteralPath $sleep42 -Raw) -eq $before) $r.out
    # M: a heartbeat that is not JSON is never overwritten
    Set-Content -LiteralPath $hb42 -Value '{"name": '; $before = Get-Content -LiteralPath $hb42 -Raw
    $r = Night @('-Cmd', 'health') @{ KITCHEN_JOB = $null }
    Check 'ZG42 a heartbeat that is not JSON is left as it is, and that is said' ((Get-Content -LiteralPath $hb42 -Raw) -eq $before -and $r.out -match 'sleep\[\] NOT written') $r.out

    # K: the Spec: four lobe Steps in order, bounded, no agent, no delete flag; the memory Steps' mustMatch takes a failing exit
    $raw = Get-Content -LiteralPath (Join-Path $repoRoot 'kitchen\recipes\lobe-rem.json') -Raw; $rj = $raw | ConvertFrom-Json -AsHashtable
    Check 'ZG42-1 lobe-rem: rem, memory-check, memory-truth, csf; each its own lobe Step with only Cmd' ((@($rj.steps | ForEach-Object { $_.args.Cmd }) -join '|') -eq 'rem|memory-check|memory-truth|csf' -and @($rj.steps | Where-Object { $_.station -ne 'lobe' -or $_.ai -or $_.script -or $_.args.Keys.Count -ne 1 }).Count -eq 0)
    Check 'ZG42-1 every Step is bounded (timeoutSec, maxMB) with no retry' (@($rj.steps | Where-Object { [int]$_.timeoutSec -le 0 -or [int]$_.maxMB -le 0 -or [int]$_.retries -ne 0 }).Count -eq 0)
    Check 'ZG42-2 no Step carries a delete flag (nothing outside the lobe database is deleted by rem)' ($raw -notmatch '(?i)delete|prune|purge|remove|wipe|clean|archive"\s*:' -and @($rj.steps | ForEach-Object { $_.args.Values } | Where-Object { "$_" -match '(?i)delete|prune|purge|remove|wipe' }).Count -eq 0)
    $src = Get-Content -LiteralPath $station -Raw; $remLine = ([regex]::Match($src, '(?ms)^\s+rem\s+= @\(.*?\)\)\s*$')).Value
    Check 'ZG42-2 the rem plan passes no delete, prune or restore argument to any module' ($remLine -match 'zeitgeistd\.rem' -and $remLine -notmatch '(?i)delete|prune|purge|restore|remove|--force') $remLine
    Check 'ZG07-3 lobe-rem names no prompt, crew, model or tools anywhere' ($raw -notmatch '(?i)"(prompt|order|supplier|cook|model|tools|role|context|private|public|about)"\s*:')
    $mm = @($rj.steps | ForEach-Object { [string]$_.mustMatch })
    Check 'ZG42-1 mustMatch: memory Steps match a failing exit (3) but not a FAILED line; rem and csf take only their done line' ("lobe: memory-truth done exit=3 ms=9" -match $mm[2] -and "lobe: memory-check done exit=none ms=9" -match $mm[1] -and "lobe: memory-truth FAILED (x) ms=1" -notmatch $mm[2] -and "lobe: rem done items=1 dropped=0 ms=1" -match $mm[0] -and "lobe: csf done items=0 dropped=0 ms=1" -match $mm[3] -and "lobe: csf FAILED (x) ms=1" -notmatch $mm[3])
    $cj = & $pwshExe -NoProfile -Command "`$env:BRAIN_KITCHEN='$ck'; `$env:KITCHEN_UNDER_TEST='1'; & '$(Join-Path $repoRoot 'kitchen\cook.ps1')' -Recipe lobe-rem -Json" 2>&1 | Out-String
    $job = try { $cj | ConvertFrom-Json } catch { $null }
    Check 'ZG42-1 lobe-rem cooks into four Steps' ($job.ok -and $job.steps -eq 4) $cj
    # ZG42-3 and the wiring record: the change note
    $note42 = Get-Content -LiteralPath (Join-Path $repoRoot 'docs\changes\ZG-42.md') -Raw
    Check 'ZG42-3 the change note says what wrap, not replace means and what still runs on its own schedule' ($note42 -match '(?i)wrap, not replace' -and $note42 -match 'memory-truth' -and $note42 -match '(?i)hourly' -and $note42 -match 'Kitchen-Chores' -and $note42 -match '(?i)every 2 minutes')
    foreach ($w in 'claims run', 'decisions prepare', 'causal run', 'edges run', 'trust run', 'brief', 'governor') {
        Check "ZG42 the change note records whether '$w' was wired or left out, and why" ($note42 -match "(?m)^\| ``[^``]*$([regex]::Escape($w))[^``]*`` \| (wired|left out)")
    }
    Check 'ZG42 the change note holds the standing line (unchanged: daily at 4)' ($note42 -match [regex]::Escape('{ "name": "lobe rem", "recipe": "lobe-rem", "everyHours": 24, "atHour": 4 }'))

    # ---- the one real call: the zeitgeistd checkout's health, through uv, against a temp kitchen ----
    $realRepo = if ($saved.ZEITGEISTD_REPO) { $saved.ZEITGEISTD_REPO } else { $def }
    $hasUv = [bool](Get-Command uv -ErrorAction SilentlyContinue); $skipWhy = ''
    if (-not $hasUv -or -not (Test-Path -LiteralPath (Join-Path $realRepo 'zeitgeistd\health.py'))) { $skipWhy = "it needs uv and a zeitgeistd checkout at $realRepo (here: $(if ($hasUv) { 'uv but no checkout' } else { 'no uv' }))" }
    else {
        # uv run syncs the checkout's .venv. Where uv cannot see the managed python the .venv was made with (the Yard's sandboxed tests
        # Step gives a suite a private APPDATA), uv tries to delete and rebuild that .venv (measured 2026-10-23 at Low: "failed to remove
        # file ...\.venv\.gitignore: Access is denied"). So the real call only runs where uv sees that python; anywhere else it is a SKIP.
        $pv = Join-Path $realRepo '.venv\pyvenv.cfg'
        $vh = if (Test-Path -LiteralPath $pv) { [string](@(Select-String -LiteralPath $pv -Pattern '^home\s*=\s*(.+)$').Matches | Select-Object -First 1 | ForEach-Object { $_.Groups[1].Value.Trim() }) } else { '' }
        $uvDir = if ($env:UV_PYTHON_INSTALL_DIR) { $env:UV_PYTHON_INSTALL_DIR } elseif ($env:APPDATA) { Join-Path $env:APPDATA 'uv\python' } else { '' }
        if (-not $vh) { $skipWhy = "the checkout has no .venv yet (scripts\test.ps1 in $realRepo makes it)" }
        elseif (-not $uvDir -or -not $vh.StartsWith($uvDir, [StringComparison]::OrdinalIgnoreCase)) { $skipWhy = "the checkout's .venv python ($vh) is not under $uvDir, where uv looks from here; uv would try to rebuild that .venv" }
    }
    if ($skipWhy) { Write-Host "SKIP: the real health call: $skipWhy" }
    else {
        $rk = Join-Path $tmp 'real-k'
        $r = Invoke-Station @('-Cmd', 'sweep') @{ KITCHEN_LOBE_PYTHON = $null; ZEITGEISTD_REPO = $realRepo; BRAIN_KITCHEN = $rk; KITCHEN_FAKE_FREE_MB = '100' }
        $hb = try { Get-Content -LiteralPath (Join-Path $rk 'watch\lobe.json') -Raw | ConvertFrom-Json } catch { $null }
        Check 'real: a RAM stop runs the real health --skip; the Watch''s watch\lobe.json carries the skip' ($r.code -eq 11 -and $r.out -match 'zeitgeistd: heartbeat written, skipped: free RAM 100 MB' -and $hb.name -eq 'lobe' -and @($hb.skipped)[0] -eq 'sweep: free RAM 100 MB is under 2500 MB') $r.out
        $r = Invoke-Station @('-Cmd', 'health') @{ KITCHEN_LOBE_PYTHON = $null; ZEITGEISTD_REPO = $realRepo; BRAIN_KITCHEN = $rk }
        Check 'real: -Cmd health runs the real health and reads that heartbeat (exit 0 or 3, never a crash)' ($r.code -in 0, 3 -and $r.out -match '(?m)^zeitgeistd: health (ok|NOT OK)' -and $r.out -match 'heartbeat: last run \d+ min ago, skipped: sweep: free RAM') $r.out
    }
}
finally {
    try { $ol.Stop() } catch { Write-Host "note: the fake Ollama did not stop cleanly ($($_.Exception.Message))" }
    try { [void]$olRs.EndInvoke($olHandle) } catch { $null = $_ }; $olRs.Dispose()   # its accept loop ends by throwing when the listener stops
    foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "LobeStation tests: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
exit 0
