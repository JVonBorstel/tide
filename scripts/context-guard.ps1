# Context Guard: Claude Code hook (UserPromptSubmit / PostToolUse). Reads the hook payload on stdin,
# measures context from the transcript's last MAIN-THREAD usage entry, warns at 50% and requests handoff at 65%.
# Also runs kitchen-check.ps1 at most every -KitchenEveryMin minutes (mid-session watch for runaway processes,
# low RAM/disk, huge temp files) and surfaces only NEW warnings. Fails LOUD if it cannot measure. Always exits 0.
# Window: -WindowTokens, else env BRAIN_GUARD_WINDOW, else 1,000,000. -KitchenEveryMin -1 disables the kitchen watch.
param([int]$WindowTokens = 0, [int]$Warn = 50, [int]$Stop = 65, [string]$KitchenScript = '', [double]$KitchenEveryMin = 10)
$ErrorActionPreference = 'Stop'
if ($WindowTokens -le 0) { $WindowTokens = if ($env:BRAIN_GUARD_WINDOW -match '^\d+$') { [int]$env:BRAIN_GUARD_WINDOW } else { 1000000 } }
if (-not $KitchenScript) { $KitchenScript = Join-Path $PSScriptRoot 'kitchen-check.ps1' }

function Emit($event, $context, $user) {
    $o = @{ hookSpecificOutput = @{ hookEventName = $event; additionalContext = ($context -join "`n") } }
    if ($user) { $o.systemMessage = ($user -join ' | ') }
    $o | ConvertTo-Json -Depth 5 -Compress
}

$event = 'UserPromptSubmit'
$ctx = New-Object System.Collections.Generic.List[string]
$usr = New-Object System.Collections.Generic.List[string]
try {
    $reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    $p = $raw | ConvertFrom-Json
    if ($p.hook_event_name) { $event = [string]$p.hook_event_name }
    $sid = ([string]$p.session_id) -replace '[^A-Za-z0-9_-]', '_'
    if (-not $sid) { throw 'no session_id' }
    $stateDir = if ($env:BRAIN_GUARD_STATE) { $env:BRAIN_GUARD_STATE } else { Join-Path $env:LOCALAPPDATA 'brain-guard' }
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

    $tp = [string]$p.transcript_path
    if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { throw 'transcript not found' }

    # read the tail (last 4 MB) and find the newest usage entry on the main thread
    $fs = [IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
    try {
        $len = $fs.Length; $start = [math]::Max(0, $len - 4MB)
        $fs.Seek($start, 'Begin') | Out-Null
        $buf = New-Object byte[] ($len - $start); [void]$fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Dispose() }
    $lines = [Text.Encoding]::UTF8.GetString($buf) -split "`n"
    $tokens = $null
    for ($i = $lines.Count - 1; $i -ge 0 -and $null -eq $tokens; $i--) {
        if ($lines[$i] -notmatch '"usage"') { continue }
        try {
            $e = $lines[$i] | ConvertFrom-Json
            if ($e.isSidechain) { continue }
            $u = $e.message.usage
            if ($u -and $null -ne $u.input_tokens) {
                $tokens = [int64]$u.input_tokens + [int64]$u.cache_creation_input_tokens + [int64]$u.cache_read_input_tokens
            }
        } catch { }
    }
    $estimated = $false
    if ($null -eq $tokens) { $tokens = [int64]($len / 4); $estimated = $true }   # chars/4 fallback, flagged
    $pct = [math]::Round(100.0 * $tokens / $WindowTokens, 1)

    @{ session_id = $sid; pct = $pct; tokens = $tokens; window = $WindowTokens; estimated = $estimated; ts = (Get-Date).ToString('o') } |
        ConvertTo-Json -Compress | Set-Content -Path (Join-Path $stateDir "ctx_$sid.json") -Encoding utf8

    $tag = if ($estimated) { ' (estimated)' } else { '' }
    # markers reset when the context drops (e.g. after /compact), so warnings can fire again
    if ($pct -lt $Stop) { Remove-Item -LiteralPath (Join-Path $stateDir "$sid.stop") -ErrorAction SilentlyContinue }
    if ($pct -lt $Warn) { Remove-Item -LiteralPath (Join-Path $stateDir "$sid.warn") -ErrorAction SilentlyContinue }
    $level = if ($pct -ge $Stop) { 'stop' } elseif ($pct -ge $Warn) { 'warn' } else { $null }
    if ($level) {
        $marker = Join-Path $stateDir "$sid.$level"
        if (-not (Test-Path $marker)) {
            Set-Content -Path $marker -Value (Get-Date).ToString('o')
            if ($level -eq 'stop') {
                $ctx.Add("CONTEXT GUARD: context is at $pct%$tag (limit $Stop%). Automatic compaction is close. Make the handoff safe now, then CONTINUE the task without stopping or asking Jordan: write the Shift handover, memory/PICKUP.md (the /handoff steps: what is running, what is done with proof, the exact next step), then run brain-monitor\scripts\refresh-boot.ps1 (rebuilds the Toolbox talk, memory/BOOT.md), update memory/NOW.md with the current step, avoid large reads (delegate them to subagents). The Toolbox talk is auto-loaded after compaction or in any new session.")
                $usr.Add("Context at $pct%$tag. Auto-compaction is close; the Toolbox talk is being refreshed. Work continues.")
            } else {
                $ctx.Add("CONTEXT GUARD: context is at $pct%$tag (warn $Warn%). Keep working, but avoid large reads (delegate them to subagents), keep replies short, and run brain-monitor\scripts\refresh-boot.ps1 soon so the handoff is current before compaction near $Stop%. Cost grows with context on every turn: at a clean stopping point (no background workflow running) run /handoff and tell Jordan a fresh session will pick up from the Shift handover (memory/PICKUP.md).")
                $usr.Add("Context at $pct%$tag. Keeping the handoff current; work continues.")
            }
        }
    }

    # mid-session kitchen watch: throttled, surfaces only new/changed warnings (or the same one after 60 min)
    if ($KitchenEveryMin -ge 0 -and (Test-Path -LiteralPath $KitchenScript)) {
        try {
            $kf = Join-Path $stateDir 'kitchen.json'
            $last = $null; if (Test-Path $kf) { $last = Get-Content $kf -Raw | ConvertFrom-Json }
            $due = (-not $last) -or (((Get-Date) - [datetime]$last.ts).TotalMinutes -ge $KitchenEveryMin)
            if ($due) {
                $out = & (Get-Process -Id $PID).Path -NoProfile -File $KitchenScript 2>&1 | Out-String
                $warns = @($out -split "`r?`n" | Where-Object { $_ -match '^WARN' })
                $hash = ''; if ($warns.Count) { $hash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($warns -join '|')))) }
                $emitTs = if ($last -and $last.emitted) { [datetime]$last.emitted } else { [datetime]::MinValue }
                $emitted = $emitTs
                if ($warns.Count -and (($hash -ne [string]$last.hash) -or (((Get-Date) - $emitTs).TotalMinutes -ge 60))) {
                    $ctx.Add("SITE CHECK (kitchen-check.ps1, mid-session): " + ($warns -join ' ; ') + " -- tell Jordan, do not kill anything without Jordan's yes unless it is a process this session started.")
                    $usr.Add("Site check: " + ($warns -join ' ; '))
                    $emitted = Get-Date
                }
                @{ ts = (Get-Date).ToString('o'); hash = $hash; emitted = $emitted.ToString('o') } | ConvertTo-Json -Compress | Set-Content -Path $kf -Encoding utf8
            }
        } catch { }   # the kitchen watch must never break the guard
    }
} catch {
    $ctx.Clear(); $usr.Clear()
    $ctx.Add("CONTEXT GUARD BLIND: cannot measure context ($($_.Exception.Message)). Assume it may be high; write a handoff soon and tell Jordan the guard is not working.")
    $usr.Add("Context Guard BLIND: $($_.Exception.Message)")
}
if ($ctx.Count) { Emit $event $ctx $usr }
exit 0
