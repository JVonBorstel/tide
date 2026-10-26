# Deterministic (no model) token-usage report over Claude Code session transcripts. READ-ONLY.
#   pwsh -File scripts/usage-report.ps1 [-ProjectsDir <home>\.claude\projects] [-Since yyyy-MM-dd]
#       [-OutPath file.md] [-Json] [-Window 1000000] [-WInput 1 -WCacheWrite 1.25 -WCacheRead 0.1 -WOutput 5]
# Privacy: reads ONLY numeric usage fields, timestamp, model, message id, agentId, isSidechain and the
# agentType of agent-*.meta.json. Never message text, tool input/output, prompts or file names. Output holds numbers
# plus sanitised model / agent / role ids. Weighted units are APPROXIMATE relative weights, NOT dollars.
# Exit: 0 ok, 2 bad argument. Days are UTC dates from the transcript timestamps.
param(
    [string]$ProjectsDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude\projects'),
    [string]$Since = '',
    [string]$OutPath = '',
    [switch]$Json,
    [double]$Window = 1000000,
    [double]$WInput = 1, [double]$WCacheWrite = 1.25, [double]$WCacheRead = 0.1, [double]$WOutput = 5
)
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
if (-not (Test-Path -LiteralPath $ProjectsDir -PathType Container)) { Write-Output "ERROR projects dir not found: $ProjectsDir"; exit 2 }
if ($Since -and $Since -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Output 'ERROR -Since must be yyyy-MM-dd'; exit 2 }
if ($Window -le 0) { Write-Output 'ERROR -Window must be > 0'; exit 2 }

function Get-Safe([string]$s, [string]$fallback) { if ($s -and $s -match '^[A-Za-z0-9._:\-]{1,64}$') { $s } else { $fallback } }
function Get-Num($el, [string]$name) {
    $v = [Text.Json.JsonElement]::new()
    if ($el.TryGetProperty($name, [ref]$v) -and $v.ValueKind -eq 'Number') { return [long]$v.GetInt64() }
    return [long]0
}
function Get-Str($el, [string]$name) {
    $v = [Text.Json.JsonElement]::new()
    if ($el.TryGetProperty($name, [ref]$v) -and $v.ValueKind -eq 'String') { return $v.GetString() }
    return ''
}
function Get-Median($vals) {
    $a = @($vals | Sort-Object); if ($a.Count -eq 0) { return $null }
    $m = [int][math]::Floor($a.Count / 2)
    if ($a.Count % 2 -eq 1) { return $a[$m] }
    return ($a[$m - 1] + $a[$m]) / 2
}
function R2($x) { [math]::Round([double]$x, 2) }
function Pct($a, $b) { if ($b -gt 0) { R2 (100.0 * $a / $b) } else { 0 } }
function N0($x) { ([double]$x).ToString('N0', $inv) }

# ---- scan (streaming; lines without "usage" are skipped before any parsing)
$records = New-Object System.Collections.Generic.List[object]
$malformed = 0; $fileCount = 0; $seq = 0
$agentTypes = @{}
$root0 = (Get-Item -LiteralPath $ProjectsDir).FullName   # never walk above the scanned folder
foreach ($f in (Get-ChildItem -LiteralPath $ProjectsDir -Recurse -File -Filter '*.jsonl' | Sort-Object FullName)) {
    $fileCount++
    # session = folder above the nearest 'subagents' ancestor (handles subagents\workflows\wf_x\agent-*.jsonl); else the file's own name
    $anc = $f.Directory
    while ($anc -and $anc.Name -ne 'subagents' -and $anc.FullName -ne $root0) { $anc = $anc.Parent }
    $inSub = [bool]($anc -and $anc.Name -eq 'subagents' -and $anc.FullName -ne $root0)
    $ses = Get-Safe $(if ($inSub) { $anc.Parent.Name } else { $f.BaseName }) 'session'
    $fileAgent = if ($f.BaseName -match '^agent-(.+)$') { Get-Safe $Matches[1] '' } else { '' }
    if ($inSub -and $fileAgent) {
        $meta = Join-Path $f.DirectoryName ($f.BaseName + '.meta.json')
        if (Test-Path -LiteralPath $meta) {
            try {
                $md = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($meta))
                $agentTypes[$fileAgent] = Get-Safe (Get-Str $md.RootElement 'agentType') 'n/a'
                $md.Dispose()
            } catch { }
        }
    }
    $byId = @{}
    foreach ($line in [IO.File]::ReadLines($f.FullName)) {
        if (-not $line.Contains('"usage"')) { continue }
        $doc = $null
        try { $doc = [Text.Json.JsonDocument]::Parse($line) } catch { $malformed++; continue }
        try {
            $root = $doc.RootElement
            if ($root.ValueKind -ne 'Object' -or (Get-Str $root 'type') -ne 'assistant') { continue }
            $msg = [Text.Json.JsonElement]::new(); $usage = [Text.Json.JsonElement]::new()
            if (-not $root.TryGetProperty('message', [ref]$msg) -or $msg.ValueKind -ne 'Object') { continue }
            if (-not $msg.TryGetProperty('usage', [ref]$usage) -or $usage.ValueKind -ne 'Object') { continue }
            $ts = Get-Str $root 'timestamp'
            $day = if ($ts.Length -ge 10 -and $ts.Substring(0, 10) -match '^\d{4}-\d{2}-\d{2}$') { $ts.Substring(0, 10) } else { 'unknown' }
            if ($Since -and ($day -eq 'unknown' -or [string]::CompareOrdinal($day, $Since) -lt 0)) { continue }
            $sv = [Text.Json.JsonElement]::new()
            $side = $inSub -or ($root.TryGetProperty('isSidechain', [ref]$sv) -and $sv.ValueKind -eq 'True')
            $agent = ''
            if ($side) {
                $agent = Get-Safe (Get-Str $root 'agentId') ''
                if (-not $agent) { $agent = if ($fileAgent) { $fileAgent } else { 'sidechain' } }
            }
            $rec = [pscustomobject]@{
                Ses = $ses; Side = $side; Agent = $agent; Model = (Get-Safe (Get-Str $msg 'model') 'other'); Day = $day
                In = (Get-Num $usage 'input_tokens'); Cw = (Get-Num $usage 'cache_creation_input_tokens')
                Cr = (Get-Num $usage 'cache_read_input_tokens'); Out = (Get-Num $usage 'output_tokens')
            }
            # the same API message is logged once per content block: keep one record per message id (last wins, first position)
            $mid = Get-Str $msg 'id'
            if ($mid -and $byId.ContainsKey($mid)) {
                $old = $byId[$mid]; $old.In = $rec.In; $old.Cw = $rec.Cw; $old.Cr = $rec.Cr; $old.Out = $rec.Out
            } else {
                if ($mid) { $byId[$mid] = $rec } else { $seq++ }
                $records.Add($rec)
            }
        } finally { $doc.Dispose() }
    }
}

# ---- aggregate
foreach ($r in $records) {
    $r | Add-Member Ctx ($r.In + $r.Cw + $r.Cr)
    $r | Add-Member Units ($r.In * $WInput + $r.Cw * $WCacheWrite + $r.Cr * $WCacheRead + $r.Out * $WOutput)
}
function Sum-Of($rs, [string]$p) { $s = 0.0; foreach ($x in $rs) { $s += $x.$p }; $s }
function New-Agg($rs) {
    [pscustomobject]@{
        turns = @($rs).Count; input = [long](Sum-Of $rs 'In'); cacheWrite = [long](Sum-Of $rs 'Cw')
        cacheRead = [long](Sum-Of $rs 'Cr'); output = [long](Sum-Of $rs 'Out'); units = R2 (Sum-Of $rs 'Units')
    }
}
$all = $records.ToArray()
$main = @($all | Where-Object { -not $_.Side })
$sub = @($all | Where-Object { $_.Side })
$t = New-Agg $all
$tokens = $t.input + $t.cacheWrite + $t.cacheRead + $t.output
$total = [pscustomobject]@{
    turns = $t.turns; input = $t.input; cacheWrite = $t.cacheWrite; cacheRead = $t.cacheRead; output = $t.output; units = $t.units
    mainUnits = R2 (Sum-Of $main 'Units'); subUnits = R2 (Sum-Of $sub 'Units'); cacheReadSharePct = (Pct $t.cacheRead $tokens)
}
$hi50 = $Window * 0.5; $hi65 = $Window * 0.65

$sessions = foreach ($g in ($all | Group-Object Ses | Sort-Object Name)) {
    $rs = @($g.Group); $m = @($rs | Where-Object { -not $_.Side }); $s = @($rs | Where-Object { $_.Side })
    $a = New-Agg $rs; $mu = Sum-Of $m 'Units'
    $u50 = Sum-Of @($m | Where-Object { $_.Ctx -gt $hi50 }) 'Units'
    $u65 = Sum-Of @($m | Where-Object { $_.Ctx -gt $hi65 }) 'Units'
    $peak = $null; $boot = $null
    if ($m.Count -gt 0) { $peak = [long](($m | Measure-Object Ctx -Maximum).Maximum); $boot = [long]$m[0].Ctx }
    [pscustomobject]@{
        id = $g.Name; turns = $a.turns; input = $a.input; cacheWrite = $a.cacheWrite; cacheRead = $a.cacheRead; output = $a.output; units = $a.units
        mainTurns = $m.Count; mainUnits = R2 $mu; subTurns = $s.Count; subUnits = R2 (Sum-Of $s 'Units')
        boot = $boot; peakContext = $peak; unitsAbove50 = R2 $u50; unitsAbove65 = R2 $u65
        share50Pct = (Pct $u50 $mu); share65Pct = (Pct $u65 $mu)
    }
}
$sessions = @($sessions)
$bootVals = @($sessions | Where-Object { $null -ne $_.boot } | ForEach-Object { $_.boot })
$boot = [pscustomobject]@{
    count = $bootVals.Count
    min = $(if ($bootVals.Count) { ($bootVals | Measure-Object -Minimum).Minimum } else { $null })
    median = (Get-Median $bootVals)
    max = $(if ($bootVals.Count) { ($bootVals | Measure-Object -Maximum).Maximum } else { $null })
}
$mainU = Sum-Of $main 'Units'
$above = [pscustomobject]@{
    mainUnits = R2 $mainU
    unitsAbove50 = R2 (Sum-Of @($main | Where-Object { $_.Ctx -gt $hi50 }) 'Units')
    unitsAbove65 = R2 (Sum-Of @($main | Where-Object { $_.Ctx -gt $hi65 }) 'Units')
}
$above | Add-Member share50Pct (Pct $above.unitsAbove50 $mainU)
$above | Add-Member share65Pct (Pct $above.unitsAbove65 $mainU)

$subagents = @(& { foreach ($g in ($sub | Group-Object { $_.Ses + '/' + $_.Agent })) {
    $rs = @($g.Group); $a = New-Agg $rs
    [pscustomobject]@{
        id = $rs[0].Agent; session = $rs[0].Ses; agentType = $(if ($agentTypes.ContainsKey($rs[0].Agent)) { $agentTypes[$rs[0].Agent] } else { 'n/a' })
        model = $rs[0].Model; turns = $a.turns; units = $a.units; peakContext = [long](($rs | Measure-Object Ctx -Maximum).Maximum)
    }
} } | Sort-Object @{Expression = 'units'; Descending = $true }, id)
$models = @(& { foreach ($g in ($all | Group-Object Model)) {
    $a = New-Agg $g.Group
    [pscustomobject]@{ model = $g.Name; turns = $a.turns; input = $a.input; cacheWrite = $a.cacheWrite; cacheRead = $a.cacheRead; output = $a.output; units = $a.units }
} } | Sort-Object @{Expression = 'units'; Descending = $true }, model)
$days = @(& { foreach ($g in ($all | Group-Object Day)) {
    $a = New-Agg $g.Group
    [pscustomobject]@{ day = $g.Name; turns = $a.turns; units = $a.units; cacheRead = $a.cacheRead }
} } | Sort-Object day)

$report = [pscustomobject]@{
    params = [pscustomobject]@{ window = $Window; since = $Since; weights = [pscustomobject]@{ input = $WInput; cacheWrite = $WCacheWrite; cacheRead = $WCacheRead; output = $WOutput }
        note = 'weighted units are APPROXIMATE relative weights, NOT dollars' }
    files = $fileCount; malformedLines = $malformed
    total = $total; boot = $boot; above = $above
    sessions = $sessions; subagents = $subagents; models = $models; days = $days
}

if ($Json) {
    $text = $report | ConvertTo-Json -Depth 6
    if ($OutPath) { Set-Content -LiteralPath $OutPath -Value $text -Encoding utf8; Write-Output "wrote $OutPath" } else { Write-Output $text }
    exit 0
}

# ---- Markdown (<= 60 lines)
function F1($x) { ([double]$x).ToString('F1', $inv) }
function Short($id) { if ($id.Length -gt 12) { $id.Substring(0, 12) } else { $id } }
$L = New-Object System.Collections.Generic.List[string]
$L.Add('# Usage report')
$L.Add(("Scanned {0} transcript files{1}; malformed lines skipped: {2}. Days are UTC." -f $fileCount, $(if ($Since) { " since $Since" } else { '' }), $malformed))
$L.Add(("Weighted units = input*{0} + cache_write*{1} + cache_read*{2} + output*{3}: APPROXIMATE relative weights, NOT dollars. Window = {4}." -f $WInput, $WCacheWrite, $WCacheRead, $WOutput, (N0 $Window)))
$L.Add('## Totals')
$L.Add(("- Turns {0}; weighted units {1} (main {2}, subagent {3})" -f (N0 $total.turns), (N0 $total.units), (N0 $total.mainUnits), (N0 $total.subUnits)))
$L.Add(("- Fresh input {0}; cache write {1}; cache read {2}; output {3}" -f (N0 $total.input), (N0 $total.cacheWrite), (N0 $total.cacheRead), (N0 $total.output)))
$L.Add(("- Cache-read share of all tokens: {0}%" -f (F1 $total.cacheReadSharePct)))
$L.Add('## Boot cost (context of first main-thread turn per session)')
if ($boot.count) { $L.Add(("- Sessions {0}: min {1}, median {2}, max {3} tokens" -f $boot.count, (N0 $boot.min), (N0 $boot.median), (N0 $boot.max))) } else { $L.Add('- no main-thread sessions') }
$L.Add('## Main-thread units spent at high context')
$L.Add(("- Above 50% of window: {0}% of main units; above 65%: {1}%" -f (F1 $above.share50Pct), (F1 $above.share65Pct)))
$L.Add('## Sessions (top 6 by units; id, turns, units, boot, peak ctx, %>50, %>65)')
foreach ($s in ($sessions | Sort-Object @{Expression = 'units'; Descending = $true }, id | Select-Object -First 6)) {
    $L.Add(("- {0}: {1} turns, {2} units, boot {3}, peak {4}, {5}%, {6}%" -f (Short $s.id), $s.turns, (N0 $s.units), $(if ($null -ne $s.boot) { N0 $s.boot } else { '-' }), $(if ($null -ne $s.peakContext) { N0 $s.peakContext } else { '-' }), (F1 $s.share50Pct), (F1 $s.share65Pct)))
}
$L.Add(("## Top subagents by units ({0} total)" -f $subagents.Count))
foreach ($a in ($subagents | Select-Object -First 10)) {
    $L.Add(("- {0} [{1}, {2}]: {3} turns, {4} units, peak ctx {5}" -f (Short $a.id), $a.agentType, $a.model, $a.turns, (N0 $a.units), (N0 $a.peakContext)))
}
$L.Add('## Per model (turns, units)')
foreach ($m in ($models | Select-Object -First 5)) { $L.Add(("- {0}: {1} turns, {2} units" -f $m.model, $m.turns, (N0 $m.units))) }
$L.Add('## Per day (UTC; latest 12)')
foreach ($d in ($days | Select-Object -Last 12)) { $L.Add(("- {0}: {1} turns, {2} units" -f $d.day, $d.turns, (N0 $d.units))) }
$text = ($L -join "`n")
if ($OutPath) { Set-Content -LiteralPath $OutPath -Value $text -Encoding utf8; Write-Output "wrote $OutPath" } else { Write-Output $text }
exit 0
