# Owns the weekly performance line: appends one dated line (order to merge, tokens per merge, first try %) under "## Weekly line" in the tide performance plan.
# Called by the Watch (or by hand); no scheduled task of its own. Reads kitchen/scoreboard.ps1 -Json (read-only; never -Record) under run-bounded.
#   weekly-line.ps1 [-PlanPath <performance.md>] [-Scoreboard <scoreboard.ps1>] [-LobeHome <dir>] [-Days 7] [-Force]
# Safe to call every hour: it writes only when the newest line is 7 or more days old (-Force writes anyway). Exit: 0 written or not due,
# 1 the scoreboard gave no numbers (nothing written), 2 the plan file is missing.
# Note: the scoreboard reports order-to-merge as a MEAN (minOrderToMerge), not a median; the line says "mean" so nobody reads it as one.
# ZG-45: a second dated line, the self line: the build standard's four numbers (scoreboard `standard`) plus "shadow pours: N, post-mortems due: N,
# foreman brier: X" from the lobe's csf.json (read only; <LobeHome> = ZEITGEISTD_HOME, else <kitchen>\lobe, as server.mjs lobeFile). Counts and
# fixed words only, never the frame's text; "unknown (why)" where data is missing. It writes only the plan file, never a memory file, never a push.
param(
    [string]$PlanPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain\projects\tide\plans\performance.md'),
    [string]$Scoreboard = (Join-Path $PSScriptRoot '..\kitchen\scoreboard.ps1'),
    [string]$LobeHome = '',
    [double]$Days = 7,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
if (-not $LobeHome) {
    $zh = ([string]$env:ZEITGEISTD_HOME).Trim(); if ($zh -match '^~(?=$|[\\/])') { $zh = $env:USERPROFILE + $zh.Substring(1) }
    $kitchen = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
    $LobeHome = if ($zh) { $zh } else { Join-Path $kitchen 'lobe' }
}
# the lobe's frame: @{ f = <csf> } or @{ why = <fixed words> }; a frame older than 4 h (zeitgeistd health.py: 2 x every 120 min) is not counted
function Read-Frame([string]$dir) {
    $p = Join-Path $dir 'csf.json'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ why = 'no csf.json in the lobe home' } }
    if ((Get-Item -LiteralPath $p).Length -gt 65536) { return @{ why = 'csf.json is over 64 KB' } }
    $f = $null; try { $f = [IO.File]::ReadAllText($p) | ConvertFrom-Json -AsHashtable } catch { $f = $null }
    if ($f -isnot [hashtable] -or $f['meta'] -isnot [hashtable]) { return @{ why = 'csf.json is not the lobe''s frame' } }
    $c = $f.meta.compiled_utc; $t = $null
    if ($c -is [DateTime]) { $t = $c.ToUniversalTime() } else { try { $t = [DateTime]::Parse([string]$c, $inv, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') } catch { $t = $null } }
    if (-not $t) { return @{ why = 'the frame''s compiled time cannot be read' } }
    $age = ((Get-Date).ToUniversalTime() - $t).TotalMinutes
    if ($age -gt 240) { return @{ why = "csf.json is stale ($([math]::Floor($age / 60)) h old; the limit is 4 h)" } }
    return @{ f = $f }
}
# "shadow pours: N, post-mortems due: N, foreman brier: X" (+ the Charter, said plainly while it is not written); the same line shapes lobe-self.js reads
function Format-SelfLobe($fr) {
    if (-not $fr.f) { return "shadow pours: unknown, post-mortems due: unknown, foreman brier: unknown ($($fr.why))" }
    $m = $fr.f.meta; $s2 = $fr.f['2_endogenous_self_state']
    $pours = 0; $bad = 0; $noHours = $false
    foreach ($l in @(if ($s2 -is [hashtable]) { $s2['shadow_blindspots'] })) {
        $l = [string]$l
        if ($l -cmatch '^.+?: \d+ of \d+ floors touched in \d+ days; \d+ merged, \d+ cooking, \d+ with no order$') { $pours++ }
        elseif ($l -cmatch '^.+? roadmap: (unreadable|stale) \(.*\)$') { $bad++ }
        elseif ($l -cmatch '^roadmap shadow: yard events .+?; Yard hours unknown') { $noHours = $true }
    }
    $least = if ($m.trimmed -is [ValueType] -and [double]$m.trimmed -gt 0) { 'at least ' } else { '' }
    $sp = if ($noHours) { 'unknown (the Yard''s events could not be read, so no Pour is called shadow)' }
    elseif (-not $pours -and $bad) { "unknown ($bad $(if ($bad -eq 1) { 'Blueprint' } else { 'Blueprints' }) not read)" }
    elseif (-not $pours) { 'unknown (no Blueprint line in the frame: every Pour got hours, or no Blueprint was read)' }
    else { "$least$pours" }
    $pmN = if ($m.counts -is [hashtable]) { $m.counts['post_mortems_due'] } else { $null }
    $pm = if ($pmN -is [ValueType] -and $pmN -isnot [bool]) { [string][int64]$pmN } else { 'unknown (the frame has no post-mortem count)' }
    $tl = [string]$m.trust
    $fb = if ($tl -cmatch '^foreman brier (\d+(?:\.\d+)?) ') { $Matches[1] } elseif ($tl -cmatch '^foreman brier unknown \((\d+) of (\d+) claims resolved\)') { "unknown ($($Matches[1]) of $($Matches[2]) claims resolved)" }
    elseif (-not $tl) { 'unknown (the lobe has no Foreman claim yet)' } else { 'unknown (the frame''s trust line is not one this script reads)' }
    $ch = if ([string]$m.charter -ne 'LOCKED') { ' · Charter: not written yet (the shadow uses the example)' } else { '' }
    "shadow pours: $sp, post-mortems due: $pm, foreman brier: $fb$ch"
}
# the build standard's four numbers (scoreboard.ps1 `standard`, ZG-22), each "unknown (the scoreboard's reason)" when null
function Format-Standard($std) {
    if ($null -eq $std) { return 'build standard unknown (the scoreboard sent no build standard numbers)' }
    $sv = { param($k) $x = $std.$k; if ($null -ne $x) { [string]::Format($inv, '{0:0.#}', [double]$x) } else { "unknown ($(if ($std.missing.$k) { $std.missing.$k } else { 'no reason given' }))" } }
    "broken mains $(& $sv 'brokenMains') · false undos $(& $sv 'falseUndos') · silent failures $(& $sv 'silentFailures') · minutes Floor start to merge $(& $sv 'floorMinutes')$(if ($null -ne $std.floorMinutes -and $std.floors) { " over $($std.floors) Floors" })"
}
$heading = '## Weekly line'
if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) { Write-Output "weekly-line: plan file not found: $PlanPath; nothing written"; exit 2 }
$text = [IO.File]::ReadAllText($PlanPath)
$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = [Collections.Generic.List[string]]::new([string[]]($text -split '\r?\n'))
if ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
$h = $lines.IndexOf($heading)
# the section ends at the next "## " heading or the end of the file
$end = $lines.Count; if ($h -ge 0) { for ($i = $h + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^## ') { $end = $i; break } } }
$today = (Get-Date).Date
if ($h -ge 0 -and -not $Force) {
    $last = @($lines.GetRange($h + 1, $end - $h - 1) | ForEach-Object { if ($_ -match '^- (\d{4}-\d{2}-\d{2}):') { [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) } } | Sort-Object | Select-Object -Last 1)
    if ($last.Count -and ($today - $last[0]).TotalDays -lt 7) { Write-Output "weekly-line: not due (last line $($last[0].ToString('yyyy-MM-dd'))); nothing written"; exit 0 }
}
$bounded = Join-Path $PSScriptRoot 'run-bounded.ps1'
$q = { param([string]$s) "'" + $s.Replace("'", "''") + "'" }   # -Command, not -File: -File cannot pass run-bounded's -ScriptArgs array
$out = & pwsh -NoProfile -NonInteractive -Command "& $(& $q $bounded) -Script $(& $q $Scoreboard) -TimeoutSeconds 180 -MaxMB 1500 -ScriptArgs '-Days','$([string]$Days)','-Json'; exit `$LASTEXITCODE" 2>&1 | Out-String
$code = $LASTEXITCODE
$sb = $null; try { $sb = (@($out -split '\r?\n' | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1) | ConvertFrom-Json } catch { $sb = $null }
if ($code -ne 0 -or -not $sb) { Write-Output "weekly-line: the scoreboard gave no numbers (exit $code): $(($out.Trim() -split '\r?\n' | Select-Object -Last 1)); nothing written"; exit 1 }
$v = { param($x, $suffix = '') if ($null -eq $x) { '-' } else { [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N0}{1}', [double]$x, $suffix) } }
$line = "- $($today.ToString('yyyy-MM-dd')): order to merge $(& $v $sb.minOrderToMerge ' min') (mean) · tokens per merge $(& $v $sb.tokensPerMerged) · first try $(& $v $sb.firstTryPct '%') · last $Days days, $(& $v $sb.merged) merged"
$self = "- $($today.ToString('yyyy-MM-dd')): self · $(Format-Standard $sb.standard) · $(Format-SelfLobe (Read-Frame $LobeHome))"
if ($h -lt 0) { if ($lines.Count -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }; $lines.Add($heading); $lines.Add($line); $lines.Add($self) }
else { $at = $end; while ($at -gt $h + 1 -and $lines[$at - 1] -eq '') { $at-- }; $lines.Insert($at, $self); $lines.Insert($at, $line) }
$tmp = "$PlanPath.tmp"
[IO.File]::WriteAllText($tmp, (($lines -join $nl) + $nl), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tmp -Destination $PlanPath -Force
Write-Output "weekly-line: wrote $line"
Write-Output "weekly-line: wrote $self"
exit 0
