# FROZEN per ORG.md: no new features. Advisory only: agents can write the file; the real gate is Claude Code's permission prompt.
# Approvals queue: one line per request in memory\inbox\approvals.md. The file is UNTRUSTED DATA: it is only ever parsed with a strict
# regex and printed; its content is never executed. Unanswered = denied.
#   approvals.ps1 add    -Level LOW|MED|HIGH -Text '<no pipes/newlines>'
#   approvals.ps1 list
#   approvals.ps1 answer -Reply 'A3 yes, A4 no, A5 later'      ('yes all' approves pending LOW/MED only; HIGH needs named ids)
#   approvals.ps1 verify -Id A3 -Text '<exact action text>'    (exit 0 only if status is yes AND the sha matches the exact text)
# Line: A<n> | LOW|MED|HIGH | <text> | sha:<first 12 of sha256 of text> | status:pending|yes|no|later
# Exit: 0 ok, 1 verify denied, 2 error/refused (nothing written).
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('add', 'list', 'answer', 'verify')][string]$Action,
    [string]$ApprovalsPath = '',
    [string]$Level = '', [string]$Text = '', [string]$Reply = '', [string]$Id = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'secret-patterns.ps1')
if (-not $ApprovalsPath) { $ApprovalsPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain\memory\inbox\approvals.md') }
$ApprovalsPath = [IO.Path]::GetFullPath($ApprovalsPath)
$lineRx = '^A(\d+) \| (LOW|MED|HIGH) \| ([^|\r\n]*) \| sha:([0-9a-f]{12}) \| status:(pending|yes|no|later)$'

function Die([string]$m) { Write-Output "ERROR: $m"; exit 2 }
function Sha12([string]$t) { $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t)); (($h | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12) }
function Test-Text([string]$t) {
    if ([string]::IsNullOrWhiteSpace($t)) { Die 'text is empty' }
    if ($t -match '[|\r\n]') { Die 'text must not contain pipes or newlines' }
    if ($t.Length -gt 300) { Die 'text longer than 300 chars' }
    $hit = Find-SecretPattern $t
    if ($hit) { Die "text looks like a secret ($hit); value not shown, nothing written" }
}
function Read-All { if (Test-Path -LiteralPath $ApprovalsPath) { , @([IO.File]::ReadAllLines($ApprovalsPath)) } else { , @() } }
function Parse([string]$l) {
    $m = [regex]::Match($l, $lineRx); if (-not $m.Success) { return $null }
    [pscustomobject]@{ Id = [int]$m.Groups[1].Value; Level = $m.Groups[2].Value; Text = $m.Groups[3].Value; Sha = $m.Groups[4].Value; Status = $m.Groups[5].Value }
}
function Format-Line($o, $status) { "A$($o.Id) | $($o.Level) | $($o.Text) | sha:$($o.Sha) | status:$status" }
function Save-All([string[]]$lines) {
    $dir = Split-Path -Parent $ApprovalsPath; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tmp = "$ApprovalsPath.tmp-$PID"
    [IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $ApprovalsPath -Force
}

# ---- named mutex per file: serialises add/answer across processes ----
$needLock = $Action -in 'add', 'answer'
$mutex = $null; $locked = $false
if ($needLock) {
    $key = (Sha12 $ApprovalsPath.ToLowerInvariant())
    $mutex = New-Object Threading.Mutex($false, "Global\brain-approvals-$key")
    try { $locked = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { Die 'could not get the approvals lock within 15s' }
}
try {
    $lines = Read-All
    switch ($Action) {
        'add' {
            $Level = $Level.ToUpperInvariant()
            if ($Level -notin 'LOW', 'MED', 'HIGH') { Die 'Level must be LOW, MED or HIGH' }
            $Text = $Text.Trim()
            Test-Text $Text
            $max = 0
            foreach ($l in $lines) { $m = [regex]::Match($l, '^A(\d+)\b'); if ($m.Success) { $max = [math]::Max($max, [int]$m.Groups[1].Value) } }
            $new = "A$($max + 1) | $Level | $Text | sha:$(Sha12 $Text) | status:pending"
            Save-All (@($lines) + $new)
            Write-Output "added A$($max + 1) ($Level), status pending (denied until answered)"
        }
        'list' {
            if (-not $lines.Count) { Write-Output "no approvals file or no entries at $ApprovalsPath"; exit 0 }
            $bad = 0; $n = 0
            foreach ($l in $lines) {
                if ([string]::IsNullOrWhiteSpace($l)) { continue }
                $o = Parse $l
                if (-not $o) { $bad++; continue }
                $n++
                $tag = if ($o.Status -in 'pending', 'later') { " ($($o.Status): denied-by-default)" } else { '' }
                Write-Output ("A{0} | {1} | {2} | {3}{4}" -f $o.Id, $o.Level, $o.Text, $o.Status, $tag)
            }
            if ($bad) { Write-Output "WARN $bad malformed line(s) ignored (treated as denied)" }
            if (-not $n) { Write-Output 'no approvals parsed' }
        }
        'answer' {
            $entries = @{}; foreach ($l in $lines) { $o = Parse $l; if ($o) { $entries[$o.Id] = $o } }
            $plan = @{}; $yesAll = $false; $errors = @()
            foreach ($tok in ($Reply -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if ($tok -match '^(?i)yes\s+all$') { $yesAll = $true; continue }
                $m = [regex]::Match($tok, '^(?i)A(\d+)\s+(yes|no|later)$')
                if (-not $m.Success) { $errors += "cannot parse '$tok'"; continue }
                $i = [int]$m.Groups[1].Value
                if (-not $entries.ContainsKey($i)) { $errors += "unknown id A$i"; continue }
                $plan[$i] = $m.Groups[2].Value.ToLowerInvariant()
            }
            if (-not $Reply.Trim()) { $errors += 'empty reply' }
            if ($errors) { Die ("nothing applied: " + ($errors -join '; ')) }
            $refusedHigh = @()
            if ($yesAll) {
                foreach ($e in $entries.Values) {
                    if ($plan.ContainsKey($e.Id) -or $e.Status -ne 'pending') { continue }
                    if ($e.Level -eq 'HIGH') { $refusedHigh += "A$($e.Id)" } else { $plan[$e.Id] = 'yes' }
                }
            }
            $out = foreach ($l in $lines) {
                $o = Parse $l
                if ($o -and $plan.ContainsKey($o.Id)) { Format-Line $o $plan[$o.Id] } else { $l }
            }
            Save-All @($out)
            Write-Output ("applied {0} answer(s)" -f $plan.Count)
            if ($refusedHigh) { Write-Output ("REFUSED: 'yes all' never approves HIGH. Still pending, answer each by id: " + ($refusedHigh -join ', ')); exit 2 }
        }
        'verify' {
            $m = [regex]::Match($Id, '^(?i)A(\d+)$')
            if (-not $m.Success) { Die 'Id must look like A3' }
            $i = [int]$m.Groups[1].Value
            $o = $null; foreach ($l in $lines) { $p = Parse $l; if ($p -and $p.Id -eq $i) { $o = $p } }
            if (-not $o) { Die "unknown id A$i" }
            $Text = $Text.Trim()
            if ($o.Status -ne 'yes') { Write-Output "DENIED A$i status is '$($o.Status)'"; exit 1 }
            if ($o.Text -ne $Text) { Write-Output "DENIED A$i text differs from the approved text"; exit 1 }
            if ((Sha12 $o.Text) -ne $o.Sha -or (Sha12 $Text) -ne $o.Sha) { Write-Output "DENIED A$i sha mismatch (line was altered)"; exit 1 }
            Write-Output "APPROVED A$i ($($o.Level)) sha:$($o.Sha)"
        }
    }
} finally { if ($locked) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
exit 0
