# Cook adapter core: Google Antigravity CLI (agy), headless, on Jordan's own Google AI Pro sign-in. Gemini CLI stopped serving
# personal accounts on 2026-06-18; agy replaced it. One sign-in gives Gemini, Claude and GPT-OSS models on the subscription.
# Used by cooks/gemini.ps1 and cooks/antigravity.ps1 (same contract as cooks/claude.ps1).
#
# MONEY: subscription only. The kitchen never sets an API key. If a run reports the plan's quota is used up, or mentions AI credits
# or overage, the cook stops (limit) and rests: it never carries on into paid usage. Jordan keeps "AI Credit Overages" on Never in the
# Antigravity app (an account setting the PC cannot see).
# SAFETY: agy runs with the kitchen's own settings (HOME = <kitchen>\agy-home-<tool set>: none, ro, web, ro-web, edit, edit-web), whatever Jordan's own agy settings
# say. By default agy may read AND WRITE anything in its workspace without asking, so both profiles carry explicit deny rules:
#   read-only steps: writes, commands, unsandboxed runs, browser actions and MCP tools denied; reading files (inside the workspace only:
#   allowNonWorkspaceAccess is off) and the web allowed. Without read_file allowed, a planning cook asked for it and gave up (J11).
#   edit steps: file edits in the work folder only (accept-edits); commands, unsandboxed runs, browser actions and MCP tools denied.
# The sign-in comes from the Windows credential store, so it works under either profile.# Env: KITCHEN_AGY_EXE (another executable, tests).
param([switch]$Probe, [string]$Prompt = '', [string]$Model = '', [string]$Effort = '', [string]$Tools = 'Read,Grep,Glob', [string]$Mode = 'plan',
      [int]$MaxTurns = 15, [double]$MaxBudgetUsd = 2, [int]$TimeoutSec = 1500, [string]$Role = 'do', [string]$Label = 'Antigravity')
$exe = $env:KITCHEN_AGY_EXE
if ($exe -eq 'off') {   # tests that must not reach Google
    if ($Probe) { return @{ ready = $false; why = 'Antigravity is off here (KITCHEN_AGY_EXE=off)'; hard = $true } }
    return @{ ok = $false; text = ''; usd = 0.0; turns = 0; inputTokens = 0; outputTokens = 0; cacheReadTokens = 0; cacheWriteTokens = 0; model = $Model; limit = $false; signedOut = $true; restMin = 0; error = 'Antigravity is off here' }
}
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'; if (-not (Test-Path -LiteralPath $exe)) { $exe = (Get-Command agy -ErrorAction SilentlyContinue).Source } }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$edits = $Mode -eq 'acceptEdits' -or $Tools -match '\b(Edit|Write)\b'
# the step's Tools decide what agy may do, like --tools for claude: 'none' = no file or web tool at all (a chat), file tools only with
# Read/Grep/Glob, the web only with WebSearch/WebFetch (a planning step must not be able to send the worktree out)
$noTools = -not $Probe -and $Tools -eq 'none'; $web = -not $Probe -and $Tools -match '\b(WebSearch|WebFetch)\b'; $files = -not $Probe -and -not $noTools -and ($edits -or $Tools -match '\b(Read|Grep|Glob)\b')
$fileTools = @('read_file(*)', 'list_dir(*)', 'view_file(*)', 'grep_search(*)', 'find_by_name(*)', 'codebase_search(*)'); $webTools = @('read_url(*)', 'search_web(*)')
# one profile per tool set, so concurrent runs never rewrite each other's settings file
$agyHome = Join-Path $kroot ('agy-home-' + $(if ($Probe) { 'probe' } elseif ($noTools) { 'none' } elseif ($edits) { 'edit' } elseif ($files) { 'ro' } else { 'web' }) + $(if ($web -and ($files -or $edits)) { '-web' } else { '' }))
$cfgDir = Join-Path $agyHome '.gemini\antigravity-cli'
$deny = @('command(*)', 'unsandboxed(*)', 'execute_url(*)', 'mcp(*)') + $(if ($edits -and -not $Probe) { @() } else { @('write_file(*)') }) + $(if ($files) { @() } else { $fileTools }) + $(if ($web) { @() } else { $webTools })
$settings = [ordered]@{ toolPermission = 'ask'; allowNonWorkspaceAccess = $false; notifications = $false; showFeedbackSurvey = $false; verbosity = 'low'
    permissions = [ordered]@{ allow = @($(if ($files) { $fileTools }) + $(if ($web) { $webTools }) | Where-Object { $_ }); deny = $deny; ask = @() } } | ConvertTo-Json -Depth 4
$sp = Join-Path $cfgDir 'settings.json'
if (-not (Test-Path -LiteralPath $sp) -or (Get-Content -LiteralPath $sp -Raw) -ne $settings) {   # rewritten whenever it differs: the rules can't drift
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null; Set-Content -LiteralPath $sp -Value $settings -NoNewline -Encoding utf8
}function Run-Agy([string[]]$cliArgs, [string]$stdin, [int]$sec) {
    if ($exe -like '*.ps1') { $psi = [Diagnostics.ProcessStartInfo]::new('pwsh'); foreach ($a in '-NoProfile', '-File', $exe) { $psi.ArgumentList.Add($a) } }   # a test fake
    else { $psi = [Diagnostics.ProcessStartInfo]::new($exe) }
    foreach ($a in $cliArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $utf8 = [Text.UTF8Encoding]::new($false); $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8; $psi.StandardInputEncoding = $utf8   # dashes and quotes arrive intact
    $psi.Environment['USERPROFILE'] = $agyHome; $psi.Environment['HOME'] = $agyHome
    foreach ($k in 'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GOOGLE_GENAI_USE_VERTEXAI', 'GOOGLE_CLOUD_PROJECT', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY') { [void]$psi.Environment.Remove($k) }   # never pay-per-token
    if ($WorkDirForRun) { $psi.WorkingDirectory = $WorkDirForRun }
    $p = [Diagnostics.Process]::Start($psi)
    $outT = $p.StandardOutput.ReadToEndAsync(); $errT = $p.StandardError.ReadToEndAsync()
    if ($stdin) { $p.StandardInput.Write($stdin) }; $p.StandardInput.Close()
    if (-not $p.WaitForExit($sec * 1000)) { try { $p.Kill($true) } catch { }; return @{ code = -1; out = $outT.Result; err = 'timed out'; timeout = $true } }
    @{ code = $p.ExitCode; out = $outT.Result; err = $errT.Result }
}
$WorkDirForRun = (Get-Location).Path

if ($Probe) {
    if (-not $exe) { return @{ ready = $false; why = 'Antigravity CLI (agy) not installed'; hard = $true } }
    # "agy models" asks Google for the models this sign-in may use: it proves the sign-in without spending any quota
    $r = Run-Agy @('models') '' 45
    if ($r.timeout) { return @{ ready = $false; why = 'Antigravity did not answer (network?)'; hard = $false } }
    $all = "$($r.out)`n$($r.err)"
    if ($r.code -eq 0 -and $all -match '(?m)^\s*(gemini|claude|gpt)[\w.-]*\s') {
        try {   # the plan's model list, for the sous chef's upgrade watch (e.g. Gemini 4 Argon the day the plan gets it)
            $slugs = @([regex]::Matches($r.out, '(?m)^\s*((?:gemini|claude|gpt)[\w.-]*)\s') | ForEach-Object { $_.Groups[1].Value })
            @{ at = [DateTime]::UtcNow.ToString('o'); models = $slugs } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $kroot 'agy-models.json') -Encoding utf8
        } catch { }
        if ($Model -and $all -notmatch [regex]::Escape($Model)) { return @{ ready = $false; why = "model $Model is not on your plan"; hard = $true } }
        return @{ ready = $true; why = 'signed in with Google (AI Pro, via Antigravity)' }
    }
    # offline first: a PC waking before Wi-Fi fails with 'dial tcp ... oauth2.googleapis.com: no such host', which is not a sign-out
    if ($all -match '(?i)no such host|dial tcp|connection (refused|reset)|timed? ?out|\bEOF\b|unreachable|network is|getaddrinfo|ENOTFOUND|ECONN') { return @{ ready = $false; why = "Antigravity could not reach Google (network?): $(($all.Trim() -split "`n")[0])"; hard = $false } }
    if (($all -replace '(?i)\S*oauth2?\.googleapis\.com\S*', '') -match '(?i)auth|sign.?in|log.?in|credential') { return @{ ready = $false; why = 'not signed in (open the Antigravity app or run agy once on the PC and sign in with Google)'; hard = $true } }
    return @{ ready = $false; why = "Antigravity check failed: $(($all.Trim() -split "`n")[0])"; hard = $false }
}

$r = @{ ok = $false; text = ''; usd = 0.0; turns = 0; inputTokens = 0; outputTokens = 0; cacheReadTokens = 0; cacheWriteTokens = 0; model = $Model; limit = $false; signedOut = $false; restMin = 0; error = ''; raw = '' }
. (Join-Path $PSScriptRoot '..\..\scripts\secret-patterns.ps1')
# the provider's words with every secret shape (and the value of every secret-looking assignment) masked, then cut to 300 characters
# (masked first: a cut could leave half a token the patterns no longer see)
function Hide-Secrets([string]$t) {
    foreach ($s in $script:SecretShapes) { $t = [regex]::Replace($t, "(?-i)$($s[1])", "[masked $($s[0])]") }
    foreach ($re in $script:SecretAssignRes) {
        $t = [regex]::Replace($t, $re, { param($m) $v = $m.Groups['v']; if ($v.Value -match $script:SecretPlaceholder -or $v.Value -match $script:SecretCodeRef) { $m.Value } else { $m.Value.Substring(0, $v.Index - $m.Index) + '[masked]' + $m.Value.Substring($v.Index - $m.Index + $v.Length) } })
    }
    $t = ($t -replace '\s+', ' ').Trim(); if ($t.Length -gt 300) { $t.Substring(0, 300) } else { $t }
}
# when a limit text names its reset: an ISO date/time ("2026-10-28T00:48Z", "2026-10-28"), a month and day ("Oct 28", "October 28,
# 2026 at 5:00 PM"), or a clock time ("at 17:30 UTC", "at 5 PM"). No zone named = this PC's local time (agy's wording UNVERIFIED: no
# saved limit text existed on 10-22). Returns the UTC time, or $null when the text names none or only a time already past.
function Find-ResetTime([string]$t) {
    $now = [DateTime]::UtcNow; $inv = [Globalization.CultureInfo]::InvariantCulture
    $toUtc = { param([DateTime]$d, [string]$z) if ($z -match '(?i)^(Z|UTC|GMT)$') { [DateTime]::SpecifyKind($d, 'Utc') } elseif ($z -match '^[+-]\d{2}:?\d{2}$') { [DateTimeOffset]::Parse($d.ToString('yyyy-MM-ddTHH:mm:ss', $inv) + ($z -replace '^([+-]\d{2})(\d{2})$', '$1:$2'), $inv).UtcDateTime } else { [DateTime]::SpecifyKind($d, 'Local').ToUniversalTime() } }
    $clock = { param([string]$h, [string]$mi, [string]$ap) $hh = [int]$h; if ($ap -match '(?i)^p' -and $hh -lt 12) { $hh += 12 } elseif ($ap -match '(?i)^a' -and $hh -eq 12) { $hh = 0 }; if ($hh -gt 23 -or [int]$mi -gt 59) { $null } else { [TimeSpan]::new($hh, [int]$mi, 0) } }
    $zone = '\s*(Z|UTC|GMT|[+-]\d{2}:?\d{2})?'
    $m = [regex]::Match($t, '\b(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{1,2}):(\d{2})(?::\d{2}(?:\.\d+)?)?' + $zone + ')?')
    if ($m.Success) {
        try { $d = [DateTime]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value); if ($m.Groups[4].Success) { $d = $d.Add([TimeSpan]::new([int]$m.Groups[4].Value, [int]$m.Groups[5].Value, 0)) }
              $u = & $toUtc $d $(if ($m.Groups[6].Success) { $m.Groups[6].Value } elseif ($m.Groups[4].Success) { '' } else { 'Z' }); if ($u -gt $now) { return $u } } catch { }
    }
    $mon = '(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?'; $tm = '(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?'
    $m = [regex]::Match($t, "(?i)\b$mon\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?(?:,?\s+(?:at\s+)?$tm)?$zone")
    if ($m.Success) {
        try { $mo = [array]::IndexOf(@('jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'), $m.Groups[1].Value.Substring(0, 3).ToLowerInvariant()) + 1
              $y = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { $now.Year }; $d = [DateTime]::new($y, $mo, [int]$m.Groups[2].Value)
              if ($m.Groups[4].Success -and ($m.Groups[5].Success -or $m.Groups[6].Success)) { $ts = & $clock $m.Groups[4].Value $m.Groups[5].Value $m.Groups[6].Value; if ($ts) { $d = $d.Add($ts) } }
              $u = & $toUtc $d $m.Groups[7].Value; if ($u -le $now -and -not $m.Groups[3].Success) { $u = & $toUtc $d.AddYears(1) $m.Groups[7].Value }; if ($u -gt $now) { return $u } } catch { }
    }
    $m = [regex]::Match($t, "(?i)\b(?:at|until|after|resets?)\s+(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?$zone(?![\w:])")
    if ($m.Success -and ($m.Groups[2].Success -or $m.Groups[3].Success)) {
        $ts = & $clock $m.Groups[1].Value $m.Groups[2].Value $m.Groups[3].Value
        if ($ts) { $z = $m.Groups[4].Value; $today = if ($z -match '(?i)^(Z|UTC|GMT)$') { $now.Date } else { [DateTime]::Now.Date }
                   $u = & $toUtc $today.Add($ts) $z; if ($u -le $now) { $u = & $toUtc $today.AddDays(1).Add($ts) $z }; return $u }
    }
    $null
}
if (-not $exe) { $r.signedOut = $true; $r.error = 'Antigravity CLI (agy) not installed'; return $r }
if ($Model -and $Model -notmatch '^[\w.:-]{2,60}$') { $r.error = 'bad model name'; return $r }
$edits = $Mode -eq 'acceptEdits' -or $Tools -match '\b(Edit|Write)\b'
# agy's 'plan' mode means 'write a plan and wait for approval' (it never does the work), so read-only steps run in the normal mode:
# the kitchen's own settings soft-deny every write and command headless. Edit steps add accept-edits (file edits only).
$cli = @('--print=', '--input-format', 'stream-json', '--output-format', 'stream-json', '--print-timeout', "$([math]::Max(30, $TimeoutSec - 15))s")
if ($edits) { $cli += @('--mode', 'accept-edits') }
if ($Model) { $cli += @('--model', $Model) }
if ($Effort -in 'low', 'medium', 'high', 'xhigh', 'max') { $cli += @('--effort', $Effort) }
# the whole order goes in as one message on standard input (no command-line length limit)
$msg = @{ event = 'user'; message = @{ content = $Prompt } } | ConvertTo-Json -Compress -Depth 5
$run = Run-Agy $cli ($msg + "`n") $TimeoutSec
$res = $null; $status = [Collections.Generic.List[string]]::new()   # agy's own words (not the answer): what the money guard reads
$act = if ($env:KITCHEN_RUN) { "$env:KITCHEN_RUN.activity.jsonl" }   # live-activity lines for the Chef's Live view; never fails a cook
function Add-Act([string]$kind, [string]$out) {
    if (-not $act) { return }
    try {
        if ($out.Length -gt 400) { $out = $out.Substring(0, 400) }
        $l = [ordered]@{ ts = [DateTime]::UtcNow.ToString('o'); kind = $kind; out = $out } | ConvertTo-Json -Compress
        [IO.File]::AppendAllText($act, $l + "`n", [Text.UTF8Encoding]::new($false))
    } catch { }
}
foreach ($line in ($run.out -split "`r?`n")) {
    if (-not $line.Trim().StartsWith('{')) { if ($line.Trim()) { $status.Add($line) }; continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    try {
        if ($e.event -in 'message', 'assistant', 'text', 'delta') {
            foreach ($c in $e.text, $e.delta, $e.message.content, $e.content) { if ($c -and "$c".Trim()) { Add-Act 'text' ([string]$c); break } }
        } elseif ($e.event -eq 'step_update') {
            $tn = foreach ($c in $e.step.tool, $e.tool, $e.name) { if ($c) { [string]$c; break } }
            if ($tn) {
                $ta = foreach ($c in $e.step.args, $e.args, $e.step.input, $e.input) { if ($c) { if ($c -is [string]) { $c } else { $c | ConvertTo-Json -Compress -Depth 3 }; break } }
                Add-Act 'tool' ("$tn $ta".Trim())
            }
        }
    } catch { }
    if ($e.event -eq 'result') { $res = $e.result; $status.Add([string]$e.result.error); if ($e.result.PSObject.Properties['overage_info'] -or $e.result.PSObject.Properties['ai_credits']) { $status.Add('ai credits') } }
    elseif ($e.event -eq 'init') { if (-not $Model) { $r.model = [string]$e.init.model } }
    elseif ($e.event -notin 'step_update', 'message', 'assistant', 'text', 'delta') { $status.Add($line) }
}
if ($res) { Add-Act 'result' ("$($res.status): $($res.response)") }
$all = "$($status -join "`n")`n$($run.err)"
if ($res) {
    $r.text = [string]$res.response; $r.turns = [int]$res.num_turns
    $r.inputTokens = [int]$res.usage.input_tokens; $r.outputTokens = [int]$res.usage.output_tokens + [int]$res.usage.thinking_tokens
    $r.cacheReadTokens = if ($res.usage.cache_read_input_tokens) { [int]$res.usage.cache_read_input_tokens } elseif ($res.usage.cached_content_token_count) { [int]$res.usage.cached_content_token_count } else { 0 }
    $r.cacheWriteTokens = if ($res.usage.cache_creation_input_tokens) { [int]$res.usage.cache_creation_input_tokens } else { 0 }
    # API-equivalent estimate only (nothing is billed per token on the plan); edit "prices" in kitchen.json
    $price = @(1.25, 10.0)
    try {
        $kc = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'kitchen.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($kc.prices) { foreach ($k in $kc.prices.Keys) { if ($r.model -match $k) { $price = @($kc.prices[$k]); break } } }
    } catch { }
    $r.usd = [math]::Round(($r.inputTokens * [double]$price[0] + $r.outputTokens * [double]$price[1]) / 1e6, 4)
}
$errText = "$(if ($res) { $res.error }) $($run.err)"
# A limit answer carries the provider's own words (.raw: the first 300 characters, secrets masked by scripts/secret-patterns.ps1), so
# a long rest can be checked later. The sous chef's rest stores it on the supplier's state; it also lands in
# <kitchen>\last-limit-<cook>.json, which the rest reads when its caller did not pass it (agent-step.ps1, talk.ps1).
function Save-Limit([string]$text, [int]$parsedMin, [bool]$dated) {
    $r.raw = Hide-Secrets $text
    try {
        $lf = Join-Path $kroot "last-limit-$($Label.ToLowerInvariant()).json"
        [ordered]@{ at = [DateTime]::UtcNow.ToString('o'); raw = $r.raw; restMin = $r.restMin; parsedMin = $parsedMin; dated = $dated } | ConvertTo-Json -Compress | Set-Content -LiteralPath "$lf.tmp" -Encoding utf8
        Move-Item -LiteralPath "$lf.tmp" -Destination $lf -Force
    } catch { }
}
# money guard first: quota used up, or any sign of AI credits / overage -> stop this cook and rest; never continue into paid usage
if ($all -match '(?i)ai.?credits?|overage') {
    $r.limit = $true; $r.restMin = 360; $r.error = "$Label mentioned AI credits or overage; stopped so nothing is ever billed beyond your plan"; Save-Limit $all.Trim() 0 $false; return $r
}
if ((-not $res -or $res.status -ne 'SUCCESS') -and $errText -match '(?i)quota|rate.?limit|\b429\b|RESOURCE_EXHAUSTED|usage limit|exhausted|too many requests|limit reached') {
    $r.limit = $true; $r.error = "$Label plan limit reached"
    # a calendar date or clock time in the text is the reset itself: rest until then. A bare number ("retry in 164 hours") is capped at
    # sous.maxParsedRestHours (24 h): on 10-22 Gemini rested 164 h and Antigravity 148 h on one number, and both answered OK that day.
    $capH = 24; try { $kc = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'kitchen.json') -Raw | ConvertFrom-Json -AsHashtable; if ($kc.sous -and [double]$kc.sous.maxParsedRestHours -gt 0) { $capH = [double]$kc.sous.maxParsedRestHours } } catch { }
    $at = Find-ResetTime $errText
    $m = [regex]::Match($errText, '(?i)(?:retry|reset|refresh)\w*\s+(?:in|after)\s+(\d+)\s*(s|sec|seconds|m|min|minutes|h|hours|d|days)')
    $parsed = if ($m.Success) { $n = [int]$m.Groups[1].Value; switch -regex ($m.Groups[2].Value) { '^d' { $n * 1440 } '^h' { $n * 60 } '^m' { $n } default { [math]::Max(1, [math]::Ceiling($n / 60)) } } } else { 0 }
    if ($at) {
        $r.restMin = [int][math]::Max(1, [math]::Ceiling(($at - [DateTime]::UtcNow).TotalMinutes)); $r.error += " (its text names the reset: $($at.ToString('yyyy-MM-dd HH:mm'))Z)"
    } elseif ($parsed -gt $capH * 60) {
        $r.restMin = [int]($capH * 60); $r.error += " (its text said $([math]::Round($parsed / 60, 1)) h; capped at $capH h because it names no date or time)"
    } else { $r.restMin = if ($parsed) { $parsed } else { 60 } }
    Save-Limit $errText.Trim() $parsed ([bool]$at)
    return $r
}
if ((-not $res -or $res.status -ne 'SUCCESS') -and $errText -match '(?i)authenticat|sign.?in|log.?in|credential') { $r.signedOut = $true; $r.error = 'not signed in'; return $r }
if ($run.timeout) { $r.error = "$Label took longer than $TimeoutSec s"; return $r }
if (-not $res -or $res.status -ne 'SUCCESS') { $r.error = "$Label ended with $(if ($res) { $res.status + ': ' + $res.error } else { 'exit ' + $run.code })".Trim(); return $r }
if (-not $r.text.Trim()) { $r.error = "$Label gave an empty answer$(if ($res.denied_actions) { ' (it wanted a tool the kitchen does not allow: ' + (@($res.denied_actions | ForEach-Object { $_.action }) -join ', ') + ')' })"; return $r }
$r.ok = $true
$r
