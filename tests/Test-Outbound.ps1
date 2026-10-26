# Owns the outbound proofs of privacy plan step 2: what each cloud cook adapter hands its CLI, and that the local cook only talks to this PC.
# Run by the kitchen tests station (every tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. No network: fake CLIs record what they get.
# Cloud adapters (kitchen/cooks/claude.ps1, kitchen/cooks/agy.ps1) run against a fake CLI (KITCHEN_CLAUDE_EXE / KITCHEN_AGY_EXE) that writes
# its arguments, standard input and a few environment readings to a file. The test then proves: the prompt goes out once and unchanged, every
# other argument is a flag, a model/effort/limit value or a deny rule; no pass key, no environment value, no career path outside a deny rule;
# the per-token API keys are gone from the CLI's environment. Local cook: kitchen/loopback.ps1 and cooks/local.ps1 refuse a non-loopback address.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cooks = Join-Path $repo 'kitchen\cooks'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('outbound-test-' + [guid]::NewGuid().ToString('N'))
$envNames = 'BRAIN_KITCHEN', 'KITCHEN_CLAUDE_EXE', 'KITCHEN_AGY_EXE', 'KITCHEN_OLLAMA_URL', 'KITCHEN_RUN', 'KITCHEN_NVSMI', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'OPENAI_API_KEY', 'OUTBOUND_TEST_MARK'
$saveEnv = @{}; foreach ($n in $envNames) { $saveEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
try {
    $kroot = Join-Path $tmp 'kitchen'; New-Item -ItemType Directory -Force -Path $kroot | Out-Null
    $env:BRAIN_KITCHEN = $kroot; $env:KITCHEN_RUN = $null; $env:KITCHEN_OLLAMA_URL = 'off'
    # secret-looking values are built at runtime (CREED 8): a pass key in the kitchen folder, planted API keys and an unrelated env value
    $passKey = 'pk' + [guid]::NewGuid().ToString('N'); Set-Content -LiteralPath (Join-Path $kroot 'pass-key.txt') -Value $passKey -NoNewline
    $apiMark = 'ak' + [guid]::NewGuid().ToString('N'); $envMark = 'em' + [guid]::NewGuid().ToString('N')
    $env:ANTHROPIC_API_KEY = $apiMark; $env:GEMINI_API_KEY = $apiMark; $env:GOOGLE_API_KEY = $apiMark; $env:OPENAI_API_KEY = $apiMark; $env:OUTBOUND_TEST_MARK = $envMark
    $career = (Join-Path $env:USERPROFILE 'gemini-brain\projects\career')
    $careerRx = '(?i)projects[\\/]+career'

    # ---- the fake CLIs: record args, stdin and env readings as JSON, answer with a minimal success ----
    $rec = Join-Path $tmp 'rec.json'
    $recordBody = @"
`$o = [ordered]@{ args = @(`$args | ForEach-Object { [string]`$_ }); stdin = `$stdin; env = [ordered]@{}; home = [string]`$env:HOME }
foreach (`$k in 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'OPENAI_API_KEY', 'OUTBOUND_TEST_MARK') { `$o.env[`$k] = [string][Environment]::GetEnvironmentVariable(`$k) }
`$o | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath '$rec' -Encoding utf8
"@
    # claude.ps1 calls a .ps1 fake in-process (& `$exe ...), so standard input arrives as pipeline input
    $fakeClaude = Join-Path $tmp 'fake-claude.ps1'
    Set-Content -LiteralPath $fakeClaude -Encoding utf8 -Value ("`$stdin = @(`$input) -join ""``n""`n" + $recordBody + "`n'{""type"":""result"",""is_error"":false,""result"":""ok"",""num_turns"":1,""total_cost_usd"":0,""usage"":{}}'")
    # agy.ps1 starts a .ps1 fake as its own pwsh process, so standard input is the console stream
    $fakeAgy = Join-Path $tmp 'fake-agy.ps1'
    Set-Content -LiteralPath $fakeAgy -Encoding utf8 -Value ("`$stdin = [Console]::In.ReadToEnd()`n" + $recordBody + "`n'{""event"":""result"",""result"":{""status"":""SUCCESS"",""response"":""ok"",""num_turns"":1,""usage"":{}}}'")
    $env:KITCHEN_CLAUDE_EXE = $fakeClaude; $env:KITCHEN_AGY_EXE = $fakeAgy

    # each adapter runs in its own pwsh (claude.ps1 strips keys from its own process environment, which must not touch this suite's)
    $driver = Join-Path $tmp 'drive.ps1'
    Set-Content -LiteralPath $driver -Encoding utf8 -Value @'
param([string]$Adapter, [string]$PromptFile, [string]$Model, [string]$Effort, [string]$Tools, [string]$Mode)
$r = & $Adapter -Prompt ([IO.File]::ReadAllText($PromptFile)) -Model $Model -Effort $Effort -Tools $Tools -Mode $Mode -TimeoutSec 60
"RESULT ok=$($r.ok) error=$($r.error)"
'@
    function Send([string]$adapter, [string]$prompt, [string]$model, [string]$effort, [string]$tools = 'Read,Grep,Glob', [string]$mode = 'plan') {
        Remove-Item -LiteralPath $rec -ErrorAction SilentlyContinue
        $pf = Join-Path $tmp 'prompt.txt'; [IO.File]::WriteAllText($pf, $prompt)
        $out = @(& pwsh -NoProfile -File $driver -Adapter (Join-Path $cooks $adapter) -PromptFile $pf -Model $model -Effort $effort -Tools $tools -Mode $mode 2>&1) -join "`n"
        $j = if (Test-Path -LiteralPath $rec) { Get-Content -LiteralPath $rec -Raw | ConvertFrom-Json } else { $null }
        @{ out = $out; rec = $j }
    }
    # an argument is allowed out when it is a flag, a short plain value (model, effort, mode, tool list, number, timeout), the kitchen's own
    # settings file, or a deny rule Read(...)/Edit(...). Anything else (a stray path, a file's text, an env value) is named in the failure.
    $settingsFile = Join-Path $kroot 'claude-cook-settings.json'
    function Stray($argList, [string]$prompt) {
        @($argList | Where-Object { $_ -ne $prompt -and $_ -ne $settingsFile -and $_ -notmatch '^--?[a-z][a-z-]*=?$' -and $_ -notmatch '^[\w.:,-]{0,60}$' -and $_ -notmatch '^(Read|Edit)\([^()]+\)$' })
    }
    function Leaks($rec) {   # the pass key, a planted API key or env value anywhere in what went out; a career path outside a deny rule
        $all = @($rec.args) + @([string]$rec.stdin)
        @($all | Where-Object { $_ -match [regex]::Escape($passKey) -or $_ -match [regex]::Escape($apiMark) -or $_ -match [regex]::Escape($envMark) -or ($_ -match $careerRx -and $_ -notmatch '^(Read|Edit)\(') })
    }

    # ---- claude.ps1 ----
    $prompt = 'Summarise the build log in three lines. ' + [guid]::NewGuid().ToString('N')
    $s = Send 'claude.ps1' $prompt 'sonnet' 'medium'
    $a = @($s.rec.args)
    Check 'claude adapter: the fake CLI ran and the adapter read its answer' ($s.rec -and $s.out -match 'RESULT ok=True')
    Check 'claude adapter: the prompt goes out exactly once, unchanged, as the -p value' (@($a | Where-Object { $_ -eq $prompt }).Count -eq 1 -and $a[[array]::IndexOf($a, '-p') + 1] -eq $prompt -and -not [string]$s.rec.stdin)
    Check 'claude adapter: model and effort go out as --model / --effort' ($a[[array]::IndexOf($a, '--model') + 1] -eq 'sonnet' -and $a[[array]::IndexOf($a, '--effort') + 1] -eq 'medium')
    $st = Stray $a $prompt
    Check "claude adapter: every other argument is a flag, a plain value, the kitchen settings file or a deny rule (stray: $($st -join ' | '))" ($st.Count -eq 0)
    $lk = Leaks $s.rec
    Check "claude adapter: no pass key, no env value, no career path except as a deny rule (leaks: $($lk.Count))" ($lk.Count -eq 0)
    Check 'claude adapter: the career folder and the pass key file are denied to the CLI' (@($a | Where-Object { $_ -match '^Read\(' -and $_ -match $careerRx }).Count -ge 1 -and @($a | Where-Object { $_ -match '^Read\(' -and $_ -match 'pass-key\.txt' }).Count -ge 1)
    Check 'claude adapter: per-token API keys are removed from the CLI environment' (-not $s.rec.env.ANTHROPIC_API_KEY -and -not $s.rec.env.OPENAI_API_KEY)
    $sf = if (Test-Path -LiteralPath $settingsFile) { Get-Content -LiteralPath $settingsFile -Raw } else { '' }
    Check 'claude adapter: the settings file it hands the CLI holds rules only (no pass key, no env value)' ($sf -and $sf -notmatch [regex]::Escape($passKey) -and $sf -notmatch [regex]::Escape($envMark) -and $sf -notmatch [regex]::Escape($apiMark))
    # long orders go on standard input with a fixed -p line
    $long = 'Long order. ' + ('x' * 20100) + [guid]::NewGuid().ToString('N')
    $s = Send 'claude.ps1' $long '' ''
    $a = @($s.rec.args)
    Check 'claude adapter: a long prompt goes out once on standard input, the -p line is fixed text' ($s.rec -and ([string]$s.rec.stdin).Trim() -eq $long -and $a[[array]::IndexOf($a, '-p') + 1] -eq 'Carry out the task given on standard input.' -and -not @($a | Where-Object { $_ -match 'x{100}' }).Count)
    $st = Stray $a 'Carry out the task given on standard input.'; $lk = Leaks $s.rec
    Check "claude adapter: a long prompt adds no stray argument and no leak (stray: $($st -join ' | '); leaks: $($lk.Count))" ($st.Count -eq 0 -and $lk.Count -eq 0)

    # ---- agy.ps1 (cooks/gemini.ps1 and cooks/antigravity.ps1 both run through it) ----
    $prompt = 'List three risks in this plan. ' + [guid]::NewGuid().ToString('N')
    $s = Send 'agy.ps1' $prompt 'gemini-3.8-flash-medium' 'high'
    $a = @($s.rec.args)
    Check 'agy adapter: the fake CLI ran and the adapter read its answer' ($s.rec -and $s.out -match 'RESULT ok=True')
    $msg = try { ([string]$s.rec.stdin).Trim() | ConvertFrom-Json } catch { $null }
    Check 'agy adapter: the prompt goes out once, as one stdin message {event:user, message.content} and nothing else' ($msg -and $msg.event -eq 'user' -and $msg.message.content -eq $prompt -and @($msg.PSObject.Properties).Count -eq 2 -and @($msg.message.PSObject.Properties).Count -eq 1)
    Check 'agy adapter: the prompt is not on the command line' (-not @($a | Where-Object { $_ -match [regex]::Escape($prompt.Substring(0, 20)) }).Count)
    Check 'agy adapter: model and effort go out as --model / --effort' ($a[[array]::IndexOf($a, '--model') + 1] -eq 'gemini-3.8-flash-medium' -and $a[[array]::IndexOf($a, '--effort') + 1] -eq 'high')
    $st = Stray $a $prompt
    Check "agy adapter: every argument is a flag or a plain value (stray: $($st -join ' | '))" ($st.Count -eq 0 -and -not @($a | Where-Object { $_ -match '^(Read|Edit)\(' }).Count)
    $lk = Leaks $s.rec
    Check "agy adapter: no pass key, no env value, no career path (leaks: $($lk.Count))" ($lk.Count -eq 0 -and -not @(@($a) + @([string]$s.rec.stdin) | Where-Object { $_ -match $careerRx }).Count)
    Check 'agy adapter: per-token API keys are removed from the CLI environment' (-not $s.rec.env.GEMINI_API_KEY -and -not $s.rec.env.GOOGLE_API_KEY -and -not $s.rec.env.ANTHROPIC_API_KEY -and -not $s.rec.env.OPENAI_API_KEY)
    Check 'agy adapter: the CLI runs with the kitchen''s own settings home, not Jordan''s' ([string]$s.rec.home -like (Join-Path $kroot 'agy-home-*'))
    $ags = @(Get-ChildItem -LiteralPath $kroot -Recurse -Filter settings.json -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
    Check 'agy adapter: the settings it writes hold rules only (no pass key, no env value)' ($ags.Count -ge 1 -and -not @($ags | Where-Object { $_ -match [regex]::Escape($passKey) -or $_ -match [regex]::Escape($envMark) }).Count)

    # ---- local cook: the Ollama address must be this PC ----
    . (Join-Path $repo 'kitchen\loopback.ps1')
    $okForms = 'http://127.0.0.1:11434', 'http://localhost:11434', 'http://[::1]:11434', 'http://127.0.0.1:11434/', 'HTTP://LOCALHOST:8080'
    Check "local cook: allowed loopback forms pass ($($okForms -join ', '))" (-not @($okForms | Where-Object { -not (Test-LoopbackUrl $_) }).Count)
    $badForms = 'http://192.168.1.20:11434', 'http://100.101.102.103:11434', 'http://chef-box.tailnet-test.example:11434', 'http://10.0.0.5:11434', 'https://127.0.0.1:11434',
                'http://127.0.0.1.example.com:11434', ('http://localhost:11434' + '@' + '192.168.1.20'), 'http://127.0.0.1:11434/../x', 'http://0.0.0.0:11434', ''
    Check 'local cook: LAN, tailnet, internet and look-alike addresses are refused' (-not @($badForms | Where-Object { Test-LoopbackUrl $_ }).Count)
    $env:KITCHEN_NVSMI = 'none'
    $env:KITCHEN_OLLAMA_URL = 'http://100.101.102.103:11434'
    $p = & (Join-Path $cooks 'local.ps1') -Probe -Model 'qwen2.5:3b'
    Check 'local cook: a tailnet address fails the probe as hard, with a plain reason' ($p.ready -eq $false -and $p.hard -eq $true -and $p.why -match 'not this PC' -and $p.why -match '100\.101\.102\.103')
    $env:KITCHEN_OLLAMA_URL = 'http://192.168.1.20:11434'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = & (Join-Path $cooks 'local.ps1') -Prompt 'hello' -Model 'qwen2.5:3b' -TimeoutSec 60
    Check 'local cook: a LAN address refuses the run before any request (ok false, plain error, under 2 s)' ($r.ok -eq $false -and $r.error -match '^local cook refused: .*not this PC' -and $sw.Elapsed.TotalSeconds -lt 2)
    # a closed loopback port: the guard lets it through, so the answer is the ordinary "not running"
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    $env:KITCHEN_OLLAMA_URL = "http://127.0.0.1:$port"
    $p = & (Join-Path $cooks 'local.ps1') -Probe
    Check 'local cook: a loopback address passes the guard (probe says Ollama is not running, not refused)' ($p.ready -eq $false -and $p.why -eq 'Ollama is not running')
    $env:KITCHEN_OLLAMA_URL = 'off'
    $p = & (Join-Path $cooks 'local.ps1') -Probe
    Check 'local cook: off still means switched off' ($p.why -match 'switched off')
}
finally {
    foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $saveEnv[$n]) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Test-Outbound: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
exit 0
