# Fix what breaks: places a Diagnose order for a set-aside job (read-only: a cook explains why it failed and what would fix it).
# Used by the supervisor (-Auto: newly set-aside jobs, only while the AI cooks are live, 3 a day at most, never a diagnosis of a
# diagnosis) and by the Chef app's "Find the fix" button. A job that ran private steps gets a private diagnosis (stays on this PC).
#   diagnose.ps1 -Id J5 [-Json]      |      diagnose.ps1 -Auto [-Json]
param([string]$Id = '', [switch]$Auto, [switch]$Json)
$ErrorActionPreference = 'Stop'
$root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$jobsDir = Join-Path $root 'jobs'; $runDir = Join-Path $root 'run'; $markPath = Join-Path $root 'diagnosed.json'
function Out-Result($o) { if ($Json) { $o | ConvertTo-Json -Depth 5 -Compress } else { $o }; exit 0 }
$marks = @{}; if (Test-Path -LiteralPath $markPath) { try { $marks = Get-Content -LiteralPath $markPath -Raw | ConvertFrom-Json -AsHashtable } catch { $marks = @{} } }
function Save-Marks { $marks | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $markPath -Encoding utf8 }

function Failure-Text($j) {
    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine("Order: $($j.name)"); [void]$sb.AppendLine("Status: $($j.status), step $([int]$j.cursor + 1) of $(@($j.steps).Count)")
    $s = @($j.steps)[[int]$j.cursor]
    if ($s) { [void]$sb.AppendLine("Station: $([IO.Path]::GetFileNameWithoutExtension([string]$s.script)), timeout $($s.timeoutSec)s, retries $($s.retries)") }
    foreach ($h in @($j.history | Select-Object -Last 4)) { [void]$sb.AppendLine("- step $([int]$h.step + 1) try $([int]$h.attempt + 1): $($h.outcome)$(if ($h.detail) { ': ' + $h.detail })") }
    $log = Get-ChildItem -LiteralPath $runDir -Filter "$($j.id)-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($log) {
        $tail = @(Get-Content -LiteralPath $log.FullName -Tail 50 -ErrorAction SilentlyContinue) -join "`n"
        $room = 5500 - $sb.Length; if ($tail.Length -gt $room) { $tail = $tail.Substring($tail.Length - [math]::Max(0, $room)) }
        [void]$sb.AppendLine("End of the log ($($log.Name)):"); [void]$sb.Append($tail)
    }
    # recipes refuse a var holding "{{" or "}}" (template injection), and a failure log quoting recipe code or a {{job}} path often does:
    # the braces are split apart so the diagnosis can still be ordered (it used to fail every tick, never marked)
    $t = $sb.ToString().Replace('{{', '{ {').Replace('}}', '} }'); if ($t.Length -gt 6000) { $t = $t.Substring(0, 6000) }
    $t
}
function Diagnose($j) {
    $vars = @{ ticket = [string]$j.id; failure = (Failure-Text $j) }
    if (@($j.steps | Where-Object { $_.args -and $_.args.Private }).Count) { $vars.private = 'yes' }   # its private words stay here
    $o = & (Join-Path $PSScriptRoot 'cook.ps1') -Recipe diagnose -Vars $vars -Json | Out-String
    try { $r = ($o.Trim() -split "`r?`n")[-1] | ConvertFrom-Json -AsHashtable } catch { $r = @{ ok = $false; error = $o.Trim() } }
    $nid = if ($r.data -and $r.data.job) { [string]$r.data.job } elseif ($r.job) { [string]$r.job } else { '' }
    if ($r.ok -and $nid) { $marks[$j.id] = @{ by = $nid; at = (Get-Date).ToUniversalTime().ToString('o') }; Save-Marks }
    # -Auto: a diagnosis that could not be ordered is marked too (by empty), or it was tried again every tick; Find the fix still works by hand
    elseif ($Auto) { $e = [string]$r.error; if ($e.Length -gt 200) { $e = $e.Substring(0, 200) }; $marks[$j.id] = @{ by = ''; at = (Get-Date).ToUniversalTime().ToString('o'); error = $e }; Save-Marks }
    @{ ok = [bool]$r.ok; job = $j.id; diagnosis = $nid; error = [string]$r.error }
}
function Load($jid) { try { Get-Content -LiteralPath (Join-Path $jobsDir "$jid.json") -Raw | ConvertFrom-Json -AsHashtable } catch { $null } }

if ($Id) {
    if ($Id -notmatch '^J\d{1,6}$') { Out-Result @{ ok = $false; error = 'bad job id' } }
    $j = Load $Id; if (-not $j) { Out-Result @{ ok = $false; error = "no job $Id" } }
    if ($j.status -notin 'quarantined', 'failed', 'killed') { Out-Result @{ ok = $false; error = "$Id is $($j.status); only set-aside orders get a diagnosis" } }
    if ($j.name -like 'diagnose:*') { Out-Result @{ ok = $false; error = 'that is a diagnosis itself; retry it instead' } }
    Out-Result (Diagnose $j)
}
if ($Auto) {
    if ($env:KITCHEN_LIVE -ne '1' -and -not (Test-Path -LiteralPath (Join-Path $root 'LIVE'))) { Out-Result @{ ok = $true; started = @(); why = 'AI cooks are off' } }
    $today = (Get-Date).ToUniversalTime().Date
    # only diagnoses actually placed count toward the 3 a day: orders that could not be ordered must not starve every other set-aside one
    $usedToday = @($marks.Values | Where-Object { $_.by -and $_.at -and ([DateTime]$_.at).ToUniversalTime().Date -eq $today }).Count
    $started = @()
    . (Join-Path $PSScriptRoot 'jobs-lib.ps1')
    foreach ($j in (Get-KitchenJobs $root -Live)) {   # set-aside orders are always in the live set (only done and closed are archived)
        if ($usedToday -ge 3) { break }
        if (-not $j -or $j.status -ne 'quarantined' -or $marks.ContainsKey($j.id) -or $j.name -like 'diagnose:*') { continue }
        $last = @($j.history)[-1]; if ($last -and $last.at -and ((Get-Date).ToUniversalTime() - ([DateTime]$last.at).ToUniversalTime()).TotalHours -gt 24) { $marks[$j.id] = @{ by = ''; at = '' }; continue }   # old: never surprise-run
        $d = Diagnose $j; $started += $d; if ($d.ok) { $usedToday++ }
    }
    Save-Marks
    Out-Result @{ ok = $true; started = $started }
}
Out-Result @{ ok = $false; error = 'give -Id J5 or -Auto' }
