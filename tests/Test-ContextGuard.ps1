# Tests for scripts/context-guard.ps1. Self-cleaning: everything lives under one temp folder removed at the end.
$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot '..\scripts\context-guard.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('cg-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$script:pass = 0; $script:fail = 0
function Check($name, $cond) { if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $name" } }

function New-Transcript($tokens, [switch]$Garbage) {
    $p = Join-Path $root ([guid]::NewGuid().ToString('N') + '.jsonl')
    if ($Garbage) { Set-Content -Path $p -Value ('x' * 4000) -Encoding utf8; return $p }
    $old = '{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":999999,"output_tokens":9}}}'
    $last = '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":' + [int]($tokens / 2) + ',"cache_read_input_tokens":' + ($tokens - 1 - [int]($tokens / 2)) + ',"output_tokens":50}}}'
    Set-Content -Path $p -Value @($old, '{"type":"user","message":"hi"}', $last) -Encoding utf8
    $p
}
function Run-Guard($payload, $window = 1000000) {
    $env:BRAIN_GUARD_STATE = Join-Path $root 'state'
    $out = $payload | ConvertTo-Json -Compress | pwsh -NoProfile -File $guard -WindowTokens $window -KitchenEveryMin -1
    $script:lastExit = $LASTEXITCODE
    if ($out) { ($out -join "`n") } else { '' }
}
function Payload($sid, $tp) { @{ session_id = $sid; transcript_path = $tp; hook_event_name = 'UserPromptSubmit'; prompt = 'hello' } }

# 1. below threshold: silent, exit 0
$o = Run-Guard (Payload 's1' (New-Transcript 100000))
Check 'low usage silent' ($o -eq ''); Check 'low exit 0' ($lastExit -eq 0)

# 2. 55%: warn once, then silent
$t = New-Transcript 550000
$o = Run-Guard (Payload 's2' $t)
$j = $o | ConvertFrom-Json
Check 'warn emits json' ($null -ne $j.hookSpecificOutput.additionalContext)
Check 'warn mentions 55' ($j.hookSpecificOutput.additionalContext -match '55')
Check 'warn event name echoed' ($j.hookSpecificOutput.hookEventName -eq 'UserPromptSubmit')
Check 'warn once only' ((Run-Guard (Payload 's2' $t)) -eq '')

# 3. 70%: stop message, once; uses LAST usage entry not the old 999999 one
$t = New-Transcript 700000
$j = (Run-Guard (Payload 's3' $t)) | ConvertFrom-Json
Check 'stop mentions handoff' ($j.hookSpecificOutput.additionalContext -match 'HANDOFF')
Check 'stop has user message' ($j.systemMessage -match '70')
Check 'stop once only' ((Run-Guard (Payload 's3' $t)) -eq '')
# automation protocol: at the limit the agent refreshes the pack and KEEPS WORKING; it never stops or asks Jordan to start a new session
Check 'stop says keep working' ($j.hookSpecificOutput.additionalContext -match 'CONTINUE' -and $j.hookSpecificOutput.additionalContext -match 'refresh-boot')
Check 'stop does not demand a manual new session' ($j.hookSpecificOutput.additionalContext -notmatch 'STOP new work' -and $j.hookSpecificOutput.additionalContext -notmatch 'tell Jordan' -and $j.systemMessage -notmatch 'Start a fresh session')
Check 'stop mentions auto-compact' ($j.hookSpecificOutput.additionalContext -match 'compact')

# 4. state file written with pct
$sf = Get-ChildItem (Join-Path $root 'state') -Filter 'ctx_s3.json' -ErrorAction SilentlyContinue
Check 'state file exists' ($null -ne $sf)
if ($sf) { $s = Get-Content $sf.FullName -Raw | ConvertFrom-Json; Check 'state pct' ([math]::Round($s.pct) -eq 70) }

# 5. window override: 200k window, 150k tokens = 75% -> stop
$j = (Run-Guard (Payload 's5' (New-Transcript 150000)) 200000) | ConvertFrom-Json
Check 'window override' ($j.systemMessage -match '75')

# 6. fail loud: missing transcript
$j = (Run-Guard (Payload 's6' (Join-Path $root 'nope.jsonl'))) | ConvertFrom-Json
Check 'blind message' ($j.hookSpecificOutput.additionalContext -match 'BLIND'); Check 'blind exit 0' ($lastExit -eq 0)

# 7. garbage transcript: estimated, flagged (4000 bytes ~1000 tokens = low, so silent but state says estimated)
$o = Run-Guard (Payload 's7' (New-Transcript 0 -Garbage))
$sf = Get-Content (Join-Path $root 'state\ctx_s7.json') -Raw | ConvertFrom-Json
Check 'garbage estimated flag' ($sf.estimated -eq $true)

# 8. malformed stdin: fail loud, exit 0
$env:BRAIN_GUARD_STATE = Join-Path $root 'state'
$out = 'not json' | pwsh -NoProfile -File $guard
Check 'bad stdin exit 0' ($LASTEXITCODE -eq 0); Check 'bad stdin blind' (($out -join '') -match 'BLIND')

# 9. session id sanitized (no path traversal)
$null = Run-Guard (Payload '..\..\evil' (New-Transcript 100000))
Check 'no traversal' (-not (Test-Path (Join-Path $root 'evil*')))
Check 'no escape file' (@(Get-ChildItem $root -Recurse -File | Where-Object FullName -notlike "$root\state\*" | Where-Object Extension -ne '.jsonl').Count -eq 0)

# 10. session ids never collide across sessions (s2 warned, new session warns again)
$j = (Run-Guard (Payload 's2b' (New-Transcript 550000))) | ConvertFrom-Json
Check 'new session warns' ($null -ne $j.hookSpecificOutput)

# 11. sidechain (subagent) usage lines are ignored: main thread 100k, newer sidechain line claims 900k
$p = Join-Path $root 'side.jsonl'
Set-Content $p -Encoding utf8 -Value @(
  '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":99999,"output_tokens":5}}}',
  '{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":899999,"output_tokens":5}}}')
Check 'sidechain ignored' ((Run-Guard (Payload 's11' $p)) -eq '')

# 12. markers reset after the context drops (e.g. /compact): warn, drop, warn again
$null = Run-Guard (Payload 's12' (New-Transcript 550000))
$null = Run-Guard (Payload 's12' (New-Transcript 100000))
$j = (Run-Guard (Payload 's12' (New-Transcript 550000))) | ConvertFrom-Json
Check 'warn again after drop' ($null -ne $j.hookSpecificOutput.additionalContext)

# 13. mid-session kitchen watch: fake kitchen script that warns; throttled; hash-deduped
$fakeK = Join-Path $root 'fakek.ps1'
Set-Content $fakeK 'Write-Output "KITCHEN fake"; Write-Output "WARN busy: python3.13 pid 1 used 5000 CPU-seconds"; exit 1'
$env:BRAIN_GUARD_STATE = Join-Path $root 'state13'
function Run-GuardK($payload, $extra) { $o = $payload | ConvertTo-Json -Compress | pwsh -NoProfile -File $guard @extra; if ($o) { $o -join "`n" } else { '' } }
$low = New-Transcript 100000
$o1 = Run-GuardK (Payload 's13' $low) @('-KitchenScript', $fakeK, '-KitchenEveryMin', '10')
$j = $o1 | ConvertFrom-Json
Check 'kitchen warn surfaced' ($j.hookSpecificOutput.additionalContext -cmatch 'SITE CHECK \(kitchen-check\.ps1, mid-session\)' -and $j.hookSpecificOutput.additionalContext -match 'busy')
Check 'kitchen warn user message' ($j.systemMessage -match 'busy')
Check 'kitchen throttled' ((Run-GuardK (Payload 's13' $low) @('-KitchenScript', $fakeK, '-KitchenEveryMin', '10')) -eq '')
# same warning again after the throttle window (0 min) is still suppressed (hash dedupe)
Check 'kitchen same warning deduped' ((Run-GuardK (Payload 's13' $low) @('-KitchenScript', $fakeK, '-KitchenEveryMin', '0')) -eq '')
# throttle is separate from dedupe: a DIFFERENT warning inside the 10-minute window must stay silent
$savedK = Get-Content $fakeK -Raw
Set-Content $fakeK 'Write-Output "WARN something brand new"; exit 1'
Check 'kitchen throttle holds even for a new warning' ((Run-GuardK (Payload 's13' $low) @('-KitchenScript', $fakeK, '-KitchenEveryMin', '10')) -eq '')
Set-Content $fakeK $savedK
# a different warning gets through
Set-Content $fakeK 'Write-Output "WARN low RAM (0.3 GB free)"; exit 1'
$o4 = Run-GuardK (Payload 's13' $low) @('-KitchenScript', $fakeK, '-KitchenEveryMin', '0')
Check 'kitchen new warning surfaced' ($o4 -match 'low RAM')
# healthy kitchen is silent; a crashing kitchen script is silent (guard must never break on it)
Set-Content $fakeK 'Write-Output "OK"; exit 0'
Check 'kitchen ok silent' ((Run-GuardK (Payload 's13' $low) @('-KitchenScript', $fakeK, '-KitchenEveryMin', '0')) -eq '')
Set-Content $fakeK 'throw "boom"'
$o6 = Run-GuardK (Payload 's13' $low) @('-KitchenScript', $fakeK, '-KitchenEveryMin', '0')
Check 'kitchen crash does not break guard' ($LASTEXITCODE -eq 0)
# guard + kitchen messages are merged into ONE json document
Set-Content $fakeK 'Write-Output "WARN heavy: java pid 2 9000 MB"; exit 1'
$o7 = Run-GuardK (Payload 's13b' (New-Transcript 700000)) @('-KitchenScript', $fakeK, '-KitchenEveryMin', '0')
$j7 = $o7 | ConvertFrom-Json
Check 'merged single json' ($j7.hookSpecificOutput.additionalContext -match 'HANDOFF' -and $j7.hookSpecificOutput.additionalContext -match 'heavy')

Remove-Item -Recurse -Force $root
Remove-Item Env:BRAIN_GUARD_STATE -ErrorAction SilentlyContinue
Write-Host "ContextGuard tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
