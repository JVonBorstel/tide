# Cook adapter: Claude Code CLI, headless, on Jordan's own sign-in (Claude plan usage; the $ figure is the API-equivalent estimate).
# Every adapter takes the same parameters and returns one hashtable:
#   @{ ok; text; usd; turns; inputTokens; outputTokens; cacheReadTokens; cacheWriteTokens; model; limit (usage limit hit); signedOut; restMin; error }
# -Probe returns @{ ready; why; hard } quickly (hard = only Jordan can fix it, e.g. sign in).
# Output is stream-json, read as it arrives: with env KITCHEN_RUN set, each tool call is logged to <KITCHEN_RUN>.activity.jsonl for the live view.
# Env KITCHEN_CLAUDE_EXE points at another executable (tests use a scripted fake).
param([switch]$Probe, [string]$Prompt = '', [string]$Model = '', [string]$Effort = '', [string]$Tools = 'Read,Grep,Glob', [string]$Mode = 'plan',
      [int]$MaxTurns = 15, [double]$MaxBudgetUsd = 2, [int]$TimeoutSec = 1500, [string]$Role = 'do')
$exe = $env:KITCHEN_CLAUDE_EXE
if (-not $exe) { $exe = (Get-Command claude -ErrorAction SilentlyContinue).Source }
if (-not $exe) { $c2 = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\claude.exe'; if (Test-Path -LiteralPath $c2) { $exe = $c2 } }
if ($Probe) {
    if (-not $exe) { return @{ ready = $false; why = 'claude CLI not installed'; hard = $true } }
    try { $a = & $exe auth status 2>$null | Out-String | ConvertFrom-Json } catch { $a = $null }
    if (-not $a) { return @{ ready = $false; why = 'could not read claude sign-in status'; hard = $false } }
    if (-not $a.loggedIn) { return @{ ready = $false; why = 'not signed in (run claude once on the PC and sign in)'; hard = $true } }
    # MONEY: only a Claude subscription sign-in counts; an API key or Console (pay per token) sign-in is refused
    if ([string]$a.authMethod -match '(?i)api|console' -or [string]$a.apiProvider -notin '', 'firstParty') { return @{ ready = $false; why = "signed in with $($a.authMethod) (billed per token): sign in with your Claude subscription instead (claude auth login --claudeai)"; hard = $true } }
    return @{ ready = $true; why = "signed in with your Claude subscription ($($a.authMethod))" }
}
$r = @{ ok = $false; text = ''; usd = 0.0; turns = 0; inputTokens = 0; outputTokens = 0; cacheReadTokens = 0; cacheWriteTokens = 0; model = $Model; limit = $false; signedOut = $false; restMin = 0; error = '' }
if (-not $exe) { $r.signedOut = $true; $r.error = 'claude CLI not installed'; return $r }
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
# MONEY pre-flight: the plan reading says paid extra usage is on or in use -> do not run at all (an overage reading whose window has reset is ignored)
try {
    $pc = (Get-Content -LiteralPath (Join-Path $kroot 'plan-usage.json') -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable)['claude']
    if ($pc -and ($pc.usingOverage -or [string]$pc.overage -match '(?i)^allowed$')) {
        $ends = @(foreach ($w in $pc.fiveHour, $pc.sevenDay) { if ($w -and $w.resetsAt) { [DateTime]::Parse([string]$w.resetsAt).ToUniversalTime() } }) | Where-Object { $_ -gt [DateTime]::UtcNow } | Sort-Object
        $ended = ($pc.fiveHour -or $pc.sevenDay) -and -not $ends
        if (-not $ended) {
            $r.limit = $true; $r.restMin = if ($ends) { [int][math]::Max(1, ($ends[0] - [DateTime]::UtcNow).TotalMinutes) } else { 300 }
            $r.error = 'Claude is in paid extra usage per plan-usage.json; not run so nothing is billed'; return $r
        }
    }
} catch { }
if ($Tools -notmatch '^[A-Za-z]+(,[A-Za-z]+)*$') { $r.error = 'Tools must be a comma list of tool names'; return $r }
if ($Model -and $Model -notmatch '^[\w.:-]{2,60}$') { $r.error = 'bad model name'; return $r }
if ($Effort -and $Effort -notmatch '^(low|medium|high|xhigh|max)$') { $r.error = 'bad effort'; return $r }
# A kitchen cook is not Jordan's own Claude Code, and the work folder is not trusted (an earlier cook may have written in it):
#  --restricted   ignores user, project and local settings files, so a cook-written .claude/settings.json can't add hooks, env,
#                 apiKeyHelper (per-token billing) or permissions; keeps the file tools inside the working folder
#  --safe-mode    no CLAUDE.md, skills, plugins or hooks (a planted CLAUDE.md can't steer the taster to SHIP)
#  --tools        exactly the tools the step grants (a web-only step gets no Read; 'none' = not even reading files)
#  --settings + --disallowedTools   the kitchen's own rules: hooks off, Jordan's private files denied by path whatever the cwd
# The subscription sign-in is unaffected.
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$px = { param($p) $f = [IO.Path]::GetFullPath($p) -replace '\\', '/'; if ($f -match '^([A-Za-z]):(.*)$') { '//' + $Matches[1].ToLowerInvariant() + $Matches[2] } else { $f } }   # Windows paths match in POSIX form: C:\x -> //c/x
$secret = @(foreach ($d in (Join-Path $env:USERPROFILE '.ssh'), (Join-Path $env:USERPROFILE '.claude'), (Join-Path $env:USERPROFILE '.config'), (Join-Path $env:USERPROFILE '.aws'), (Join-Path $env:USERPROFILE '.gnupg'),
        (Join-Path $env:USERPROFILE 'gemini-brain\projects\career'), (Join-Path $env:LOCALAPPDATA 'Google'), (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge'), (Join-Path $env:APPDATA 'Mozilla'), (Join-Path $kroot 'talk')) { "$(& $px $d)/**" }) +
    @((& $px (Join-Path $kroot 'pass-key.txt')), (& $px (Join-Path $kroot 'pass-users.txt')), '**/pass-key.txt', '**/pass-users.txt', '**/*.pem', '**/.env', '~/.ssh/**', '~/.claude/**')
$deny = @(foreach ($s in $secret) { "Read($s)"; "Edit($s)" }) + @('Edit(.claude/**)', 'Edit(**/.claude/**)', 'Edit(CLAUDE.md)', 'Edit(**/CLAUDE.md)', 'Edit(CLAUDE.local.md)', 'Edit(**/CLAUDE.local.md)', 'Edit(.mcp.json)', 'Edit(**/.mcp.json)')
$setFile = Join-Path $kroot 'claude-cook-settings.json'
$setJson = [ordered]@{ disableAllHooks = $true; enableAllProjectMcpServers = $false; permissions = [ordered]@{ deny = $deny } } | ConvertTo-Json -Depth 4
try { if (-not (Test-Path -LiteralPath $setFile) -or (Get-Content -LiteralPath $setFile -Raw) -ne $setJson) { New-Item -ItemType Directory -Force -Path $kroot | Out-Null; Set-Content -LiteralPath $setFile -Value $setJson -NoNewline -Encoding utf8 } }   # rewritten whenever it differs: the rules can't drift
catch { $r.error = "could not write the kitchen's claude settings: $($_.Exception.Message)"; return $r }   # fail closed: no run without the deny rules
$cli = @('--restricted', '--safe-mode', '--strict-mcp-config', '--settings', $setFile, '--tools', $(if ($Tools -eq 'none') { '' } else { $Tools }), '--allowedTools', $Tools,
         '--max-turns', $MaxTurns, '--max-budget-usd', $MaxBudgetUsd, '--permission-mode', $Mode, '--output-format', 'stream-json', '--verbose', '--disallowedTools') + $deny
if ($Model) { $cli += @('--model', $Model) }
if ($Effort) { $cli += @('--effort', $Effort) }
# MONEY: never an API key (that bills per token); the CLI must use the subscription sign-in
foreach ($k in 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX') { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $OutputEncoding = [Text.UTF8Encoding]::new($false)   # the CLI speaks UTF-8: dashes and quotes arrive intact
# long orders go in on standard input (the command line has a length limit)
# events are read as they arrive; with KITCHEN_RUN set, each tool call is appended to <run base>.activity.jsonl (start, then ok/error)
$actFile = if ($env:KITCHEN_RUN) { "$($env:KITCHEN_RUN).activity.jsonl" } else { '' }
$act = @{ open = @{}; seen = @{}; tokens = 0 }
$clip = { param($s, $n) $s = [string]$s; if ($s.Length -gt $n) { $s.Substring(0, $n) } else { $s } }
$note = {
    param([string]$line)
    if (-not $actFile -or -not $line.StartsWith('{') -or $line -notmatch '"(tool_use|tool_result)"') { return }
    try {
        $e = $line | ConvertFrom-Json
        $items = @($e.message.content)
        if ($e.type -eq 'assistant') {
            $mid = [string]$e.message.id; $u = $e.message.usage
            if ($u -and (-not $mid -or -not $act.seen[$mid])) {
                if ($mid) { $act.seen[$mid] = $true }
                $act.tokens += [int]$u.input_tokens + [int]$u.output_tokens + [int]$u.cache_read_input_tokens + [int]$u.cache_creation_input_tokens
            }
        }
        foreach ($it in $items) {
            if ($e.type -eq 'assistant' -and $it.type -eq 'tool_use') {
                $inp = $it.input; $t = ''
                foreach ($p in 'file_path', 'path', 'command', 'pattern', 'url') { if ($inp -and $inp.$p) { $t = [string]$inp.$p; break } }
                $act.open[[string]$it.id] = @{ sw = [Diagnostics.Stopwatch]::StartNew(); tool = [string]$it.name; target = (& $clip $t 200) }
                $o = [ordered]@{ ts = [DateTime]::UtcNow.ToString('o'); kind = 'tool'; tool = [string]$it.name; target = (& $clip $t 200); status = 'start'; tokens = $act.tokens }
                Add-Content -LiteralPath $actFile -Value ($o | ConvertTo-Json -Compress) -Encoding utf8
            } elseif ($e.type -eq 'user' -and $it.type -eq 'tool_result') {
                $s = $act.open[[string]$it.tool_use_id]
                if (-not $s) { continue }
                $act.open.Remove([string]$it.tool_use_id)
                $c = $it.content; if ($c -isnot [string]) { $c = (@($c) | ForEach-Object { if ($_.text) { $_.text } else { [string]$_ } }) -join "`n" }
                $o = [ordered]@{ ts = [DateTime]::UtcNow.ToString('o'); kind = 'tool'; tool = $s.tool; target = $s.target; status = $(if ($it.is_error) { 'error' } else { 'ok' }); ms = [int]$s.sw.ElapsedMilliseconds; out = (& $clip $c 800); tokens = $act.tokens }
                Add-Content -LiteralPath $actFile -Value ($o | ConvertTo-Json -Compress) -Encoding utf8
            }
        }
    } catch { }   # logging must never fail a run
}
if ($Prompt.Length -lt 20000) { $lines = & $exe -p $Prompt @cli 2>&1 | ForEach-Object { $s = [string]$_; & $note $s; $s } }
else { $lines = $Prompt | & $exe -p 'Carry out the task given on standard input.' @cli 2>&1 | ForEach-Object { $s = [string]$_; & $note $s; $s } }
$code = $LASTEXITCODE
$raw = (@($lines) -join "`n") + "`n"
# stream-json: one event per line. The result line is the answer; rate_limit_event is Anthropic's own reading of Jordan's plan
# (5-hour and weekly use, reset times, whether paid extra usage is on). It is saved to plan-usage.json for the sous chef and the app.
$j = $null; $rl = $null
foreach ($line in ($raw -split "`r?`n")) {
    if (-not $line.StartsWith('{')) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    if ($e.type -eq 'result') { $j = $e } elseif ($e.type -eq 'rate_limit_event') { $rl = $e.rate_limit_info }
}
if (-not $j) { $i = $raw.IndexOf('{'); if ($i -ge 0) { try { $j = $raw.Substring($i) | ConvertFrom-Json } catch { } } }   # plain json (older CLI, tests)
if ($rl) {
    $w = $rl.unifiedWindows
    $epoch = { param($s) if ($s) { [DateTimeOffset]::FromUnixTimeSeconds([long]$s).UtcDateTime.ToString('o') } }
    $r.plan = [ordered]@{ at = [DateTime]::UtcNow.ToString('o'); status = [string]$rl.status; window = [string]$rl.rateLimitType
        fiveHour = [ordered]@{ used = [double]$w.five_hour.utilization; resetsAt = & $epoch $w.five_hour.resetsAt }
        sevenDay = [ordered]@{ used = [double]$w.seven_day.utilization; resetsAt = & $epoch $w.seven_day.resetsAt }
        overage = [string]$rl.overageStatus; usingOverage = [bool]$rl.isUsingOverage }
    $kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
    try {
        $pu = Join-Path $kroot 'plan-usage.json'; $all = @{}; if (Test-Path -LiteralPath $pu) { try { $all = Get-Content -LiteralPath $pu -Raw | ConvertFrom-Json -AsHashtable } catch { } }
        $all['claude'] = $r.plan; $tmp = "$pu.tmp-$PID"; $all | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding utf8; Move-Item -LiteralPath $tmp -Destination $pu -Force
    } catch { }
}
$text = if ($j) { [string]$j.result } else { $raw.Trim() }
if ($j) {
    $r.usd = [double]$j.total_cost_usd; $r.turns = [int]$j.num_turns; $r.inputTokens = [int]$j.usage.input_tokens; $r.outputTokens = [int]$j.usage.output_tokens
    $r.cacheReadTokens = [int]$j.usage.cache_read_input_tokens; $r.cacheWriteTokens = [int]$j.usage.cache_creation_input_tokens
}
$r.text = $text
# MONEY: Anthropic says this run went into paid extra usage -> stop Claude until the window resets (the answer is still kept)
if ($rl -and $rl.isUsingOverage) {
    $r.limit = $true; $r.ok = $false; $r.error = 'Claude went into paid extra usage; stopped so nothing is billed beyond your plan'
    $r.restMin = if ($rl.resetsAt) { [math]::Max(1, [int](([DateTimeOffset]::FromUnixTimeSeconds([long]$rl.resetsAt).UtcDateTime - [DateTime]::UtcNow).TotalMinutes) + 1) } else { 300 }
    return $r
}
# the plan's window is used up (Anthropic's own status) -> rest exactly until it resets
if ($rl -and $rl.status -eq 'rejected') {
    $r.limit = $true; $r.ok = $false; $r.error = "Claude plan limit reached ($($rl.rateLimitType))"
    $r.restMin = if ($rl.resetsAt) { [math]::Max(1, [int](([DateTimeOffset]::FromUnixTimeSeconds([long]$rl.resetsAt).UtcDateTime - [DateTime]::UtcNow).TotalMinutes) + 1) } else { 60 }
    return $r
}
$bad = (-not $j) -or $j.is_error -or $code
# A limit is read from the CLI's own words only: lines that are not JSON (stderr) and the result text of an API-error result
# (subtype success + is_error), never the model's answer in an error_max_turns / budget result (a change about rate limiting is not a
# limit). Generic rate-limit words count only when the plan did not just say 'allowed'; 'overloaded' (529) is a hiccup, not a limit.
$cliSays = (@($raw -split "`r?`n") | Where-Object { $_ -and -not $_.StartsWith('{') }) -join "`n"
if ($j -and $j.is_error -and [string]$j.subtype -in '', 'success') { $cliSays += "`n" + [string]$j.result }
$planOk = $rl -and [string]$rl.status -match '^allowed'
if ($bad -and ($cliSays -match '(?i)usage limit|limit reached|hit your (usage )?limit' -or (-not $planOk -and $cliSays -match '(?i)rate.?limit|\b429\b|too many requests'))) {
    $r.limit = $true; $r.error = 'Claude usage limit'
    $m = [regex]::Match($cliSays, '\|(\d{10})\b')   # "...limit reached|<reset epoch>"
    if ($m.Success) { $r.restMin = [math]::Max(1, [int](([DateTimeOffset]::FromUnixTimeSeconds([long]$m.Groups[1].Value).UtcDateTime - [DateTime]::UtcNow).TotalMinutes) + 1) }
    else {
        $m = [regex]::Match($cliSays, '(?i)resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)')
        if ($m.Success) {
            $h = [int]$m.Groups[1].Value % 12; if ($m.Groups[3].Value -match '(?i)pm') { $h += 12 }
            $at = (Get-Date).Date.AddHours($h).AddMinutes($(if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 })); if ($at -le (Get-Date)) { $at = $at.AddDays(1) }
            $r.restMin = [int]($at - (Get-Date)).TotalMinutes + 1
        }
    }
    return $r
}
if ($bad -and $cliSays -match '(?i)not logged in|please run /login|invalid api key|authentication (failed|error)|oauth token') { $r.signedOut = $true; $r.error = 'not signed in'; return $r }
if ($bad) {
    $r.error = "agent ended with $(if ($j) { $j.subtype } else { "exit $code" })"
    $ex = ([string]$cliSays -replace '\s+', ' ').Trim(); if ($ex.Length -gt 160) { $ex = $ex.Substring(0, 160) }   # so a provider 5xx or timeout reaches the hiccup check (the CLI's words only, never the answer)
    if ($ex) { $r.error += ": $ex" }
    return $r
}
$r.ok = $true
$r
