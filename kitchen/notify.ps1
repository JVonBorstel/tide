# Phone channel for kitchen alerts (ntfy). OFF unless Jordan turned push alerts on in the Board (<kitchen>\push-on + the random
# topic in <kitchen>\ntfy-topic.txt) or BRAIN_NTFY_TOPIC is set. Only short words leave this PC: a ticket number and what kind of
# news it is ("J12 needs your sign-off"), never an order's name, a log or a chat. -Safe = the caller already wrote a contents-free line.
# Failures never throw: an alert must never break the supervisor. Every call says whether the push went out (TD-EH-04 "Sent or not"):
# one JSON line on stdout, {sent, why?, http?}, and the exit code: 0 ok (sent), 3 off (phone alerts are off), 4 failed (ntfy error, or
# no valid topic), 5 limited (ntfy's rate limit, HTTP 429). The why is fixed words and a status code, never the text, the topic or an
# exception message (that can carry the topic's URL). kitchen.ps1 Alert writes it on the alerts.jsonl line. -Check answers off or ready
# without sending anything. Tests: KITCHEN_NOTIFY_LOG writes instead of sending; with it, KITCHEN_NOTIFY_FAIL=<HTTP status> makes the
# send fail as if ntfy had answered that status (still no network).
param([string]$Level = 'INFO', [string]$Text = '', [switch]$Safe, [switch]$Check)
function Done([string]$sent, [string]$why = '', [int]$http = 0) {
    $r = [ordered]@{ sent = $sent }; if ($why) { $r.why = $why }; if ($http) { $r.http = $http }
    $r | ConvertTo-Json -Compress
    exit $(switch ($sent) { 'ok' { 0 } 'ready' { 0 } 'off' { 3 } 'limited' { 5 } default { 4 } })
}
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$topic = $env:BRAIN_NTFY_TOPIC
if (-not $topic -and (Test-Path -LiteralPath (Join-Path $root 'push-on'))) { $topic = (Get-Content -LiteralPath (Join-Path $root 'ntfy-topic.txt') -Raw -ErrorAction SilentlyContinue); if (-not "$topic".Trim()) { Done 'failed' 'push is on but the ntfy topic file is missing or empty' } }
$topic = "$topic".Trim()   # ("$x", not [string]$x: an empty Get-Content is AutomationNull, which [string] keeps null)
if (-not $topic) { Done 'off' 'phone alerts are off' }
if ($topic -notmatch '^[A-Za-z0-9_-]{12,64}$') { Done 'failed' 'the ntfy topic is not valid' }
if ($Check) { Done 'ready' }
$Text = $Text.Trim()
if (-not $Safe) {
    $id = if ($Text -match '^(J\d{1,6})\b') { $Matches[1] } else { '' }
    # The caller texts keep their old words (kitchen.ps1, verify.ps1); the new words (sign-off, Failed, Stop-work) are matched too.
    # 'Failed' is case-sensitive, so the existing lower-case "... failed" texts (backup, update, breaker) keep the kind they had.
    # The output phrases are fixed words in the Board's terms (S2-TASKNAMES); Test-Privacy.ps1, Test-PassApp.ps1 and Test-KitchenSupervisor.ps1 pin them.
    $what = if ($Text -match '(?i)needs? your yes|approv|sign-off|run step .* again') { 'needs your sign-off' }
            elseif ($Text -match '(?i)quarantin|set aside' -or $Text -cmatch '\bFailed\b') { 'Failed; the Board has the details' }
            elseif ($Text -match '(?i)stop-work order lifted') { 'new work starts again (the Stop-work order was lifted)' }   # TD-EH-07: the one closed note
            elseif ($Text -match '(?i)breaker|stop-work') { 'the kitchen paused new work (many failures)' }
            elseif ($Text -match '(?i)budget|cap reached') { 'today''s spending cap was reached' }
            else { 'something needs a look' }
    $Text = if ($id) { "$id $what" } else { "Kitchen: $what" }
}
if ($Text.Length -gt 200) { $Text = $Text.Substring(0, 200) }
$priority = switch ($Level) { 'HIGH' { 'high' } 'MED' { 'default' } default { 'low' } }
if ($env:KITCHEN_NOTIFY_LOG -and $env:KITCHEN_NOTIFY_FAIL -notmatch '^\d{3}$') { Add-Content -LiteralPath $env:KITCHEN_NOTIFY_LOG -Value "$Level|$topic|$Text"; '{"sent":"ok"}'; exit 0 }   # tests: write instead of send
$status = -1   # -1 = sent; 0 = ntfy not reached (no answer); else the HTTP status ntfy answered
# tests: ntfy's answer, no network. The status is set straight from KITCHEN_NOTIFY_FAIL. Throwing pwsh's HttpResponseException here
# raced a fresh pwsh's start-up: its module was not always loaded yet, the type did not resolve, and the answer read
# "could not be reached" (1 of 30 direct runs in the CI diagnosis of 2026-10-24). A real send is unaffected: the send's cmdlet loads that module itself.
if ($env:KITCHEN_NOTIFY_LOG) { $status = [int]$env:KITCHEN_NOTIFY_FAIL }
else {
    try {
        Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$topic" -Body ([Text.Encoding]::UTF8.GetBytes($Text)) -Headers @{ Title = 'The Board'; Priority = $priority; Tags = 'fork_and_knife' } -TimeoutSec 10 | Out-Null
    } catch { $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 } }
}
if ($status -lt 0) { Done 'ok' }
if ($status -eq 429) { Done 'limited' 'ntfy rate limit (HTTP 429)' 429 }
if ($status -gt 0) { Done 'failed' "ntfy error (HTTP $status)" $status }
Done 'failed' 'ntfy could not be reached'
