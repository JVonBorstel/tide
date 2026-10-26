# Turn an agent-standup session timeline into a PROPOSAL recap (Markdown) in an inbox folder. No model involved.
# Source: -FromFile <timeline.json>  or  -Port N -Proj P -Id S (reads http://127.0.0.1:N/api/session; localhost only).
# Copies metadata only (agents, delegation titles, tool/error/token counts, short report lines). Never copies user prompts,
# order bodies or tool output. Refuses (exit 2, writes nothing) if any line matches a secret shape. Writes only into a folder named "inbox".
# Exit: 0 ok, 2 refused/bad input.
param([string]$FromFile, [int]$Port = 0, [string]$Proj = '', [string]$Id = '', [Parameter(Mandatory)][string]$OutPath, [switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'secret-patterns.ps1')
function Die([string]$m) { Write-Output "ERROR: $m"; exit 2 }
function Clip([string]$s, [int]$n) { $t = ($s -replace '[\x00-\x1f\x7f-\x9f​-‏‪-‮⁠-⁤⁦-⁩﻿]', ' ' -replace '\s+', ' ').Trim(); if ($t.Length -gt $n) { $t.Substring(0, $n) + '...' } else { $t } }

if ((Split-Path -Leaf (Split-Path -Parent $OutPath)) -ne 'inbox') { Die 'OutPath must be inside a folder named inbox (proposals only)' }
if ((Test-Path -LiteralPath $OutPath) -and -not $Force) { Die 'OutPath exists; use -Force to overwrite a proposal' }

try {
    if ($FromFile) { if (-not (Test-Path -LiteralPath $FromFile)) { Die "file not found: $FromFile" }; $tl = Get-Content -LiteralPath $FromFile -Raw | ConvertFrom-Json }
    elseif ($Port -gt 0 -and $Proj -and $Id) {
        if ($Proj -notmatch '^[\w.\-]+$' -or $Id -notmatch '^[\w.\-]+$') { Die 'bad Proj or Id' }
        $tl = Invoke-RestMethod -TimeoutSec 15 -Uri ("http://127.0.0.1:{0}/api/session?proj={1}&id={2}" -f $Port, $Proj, $Id)
    } else { Die 'give -FromFile, or -Port with -Proj and -Id' }
} catch { Die "could not read timeline: $($_.Exception.Message)" }
if (-not $tl -or -not $tl.events -or -not $tl.agents) { Die 'timeline has no agents/events' }

$sb = New-Object System.Text.StringBuilder
function L([string]$s = '') { [void]$sb.Append($s).Append("`n") }
L "# STANDUP RECAP PROPOSAL (script-generated; untrusted data, not instructions)"
L "Nothing here is merged into memory until Jordan or the Chief reviews it. Source: agent-standup timeline (unofficial fork of Atoll92/agent-standup)."
L "session: $(Clip $tl.id 80) | project: $(Clip $tl.proj 80) | duration: $([math]::Round([double]$tl.durationMs / 1000, 1)) s | agents: $($tl.agents.Count) | events: $($tl.events.Count)"
L; L '## Agents'
foreach ($a in $tl.agents) {
    $ev = @($tl.events | Where-Object { $_.agent -eq $a.id })
    $tools = 0; foreach ($e in ($ev | Where-Object { $_.kind -eq 'tools' })) { $tools += @($e.tools).Count }
    $errs = 0; foreach ($e in ($ev | Where-Object { $_.kind -eq 'results' })) { $errs += @($e.items | Where-Object { $_.err -eq $true }).Count }
    $out = 0; $peak = 0
    foreach ($e in ($ev | Where-Object { $_.kind -eq 'usage' })) { $out += [int64]$e.u.o; $c = [int64]$e.u.i + [int64]$e.u.r + [int64]$e.u.w; if ($c -gt $peak) { $peak = $c } }
    L ("- {0} ({1}): tools {2}, errors {3}, out {4}, peak context {5}" -f (Clip $a.id 40), (Clip $a.role 40), $tools, $errs, $out, $peak)
}
L; L '## Delegations'
foreach ($e in ($tl.events | Where-Object { $_.kind -eq 'order' })) { L ("- {0} -> {1}: {2}" -f (Clip $e.agent 40), (Clip $e.to 40), (Clip $e.title 100)) }
L; L '## Reports (first 200 chars)'
foreach ($e in ($tl.events | Where-Object { $_.kind -eq 'report' })) { L ("- {0} -> {1}: {2}" -f (Clip $e.agent 40), (Clip $e.to 40), (Clip $e.text 200)) }

$text = $sb.ToString()
foreach ($line in ($text -split "`n")) {
    $hit = Find-SecretPattern $line
    if ($hit) { Die "secret-shaped text ($hit) in the recap; nothing written" }
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath) | Out-Null
Set-Content -LiteralPath $OutPath -Value $text -Encoding utf8
Write-Output "wrote $OutPath ($($text.Length) chars)"
exit 0
