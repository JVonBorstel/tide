# Live worker: one AI step. The Sous Chef (sous-chef.ps1) picks the cook (claude / gemini / local, and which model) and says why;
# this station runs that cook through its adapter (kitchen/cooks/<supplier>.ps1), falls through to the next able cook if one hits its
# plan's usage limit or is signed out, and writes the answer to the step log plus a receipt (<run>.cost.json) the supervisor adds to the
# job's ledger and the sous chef learns from.
# OFF by default: it only cooks when KITCHEN_LIVE=1 or the switch file <kitchen root>\LIVE exists; otherwise it shows what it would do.
# Bounded by the supervisor (time, memory tree, log size); here also by max turns, a per-run dollar cap, read-only by default, and no tool
# beyond what the job grants. The prompt is the job's data; it never changes these limits.
# Exit: 0 done, 1 failed (retried; the sous chef picks a different cook), 10 held for Jordan, 11 no cook free now or a cloud hiccup (waits, no retry used).
#   kitchen.ps1 add -Name review -Script agent -ScriptArgs @{ Prompt = '...'; Role = 'check'; Tools = 'Read,Grep,Glob' }
#   args: Prompt, Role (plan|do|research|check), WorkDir, Tools, MaxTurns, MaxBudgetUsd, Mode (plan|default|acceptEdits), SaveTo,
#         Supplier (auto|claude|gemini|local|...), Model, Effort, Private, Order (what was asked; the privacy judge reads it),
#         Context ('a.txt;b.patch': files pasted into the order), Goal
param([Parameter(Mandatory)][string]$Prompt, [ValidateSet('plan', 'do', 'research', 'check')][string]$Role = 'do',
      [string]$WorkDir = '', [string]$Tools = 'Read,Grep,Glob', [int]$MaxTurns = 15, [double]$MaxBudgetUsd = 2,
      [ValidateSet('plan', 'default', 'acceptEdits')][string]$Mode = 'plan', [string]$Model = '', [string]$Effort = '', [string]$SaveTo = '',
      [string]$Supplier = 'auto', [switch]$Private, [switch]$Public, [string]$Order = '', [string]$Context = '', [int]$TimeoutSec = 0,
      [string]$Goal = '', [ValidateSet('', 'S', 'M', 'L')][string]$Size = '')
if (-not $TimeoutSec) { $TimeoutSec = if ($env:KITCHEN_TIMEOUT) { [int]$env:KITCHEN_TIMEOUT } else { 1500 } }   # the supervisor's limit for this step
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$sous = Join-Path $PSScriptRoot 'sous-chef.ps1'
# Runtime tokens: {{job}}, {{worktree}} (this job's branch folder, made by the worktree station) and {{kitchen}} (the state folder).
$tok = @{ '{{job}}' = [string]$env:KITCHEN_JOB; '{{worktree}}' = (Join-Path $kroot "worktrees\$env:KITCHEN_JOB"); '{{kitchen}}' = $kroot }
foreach ($k in $tok.Keys) { $Prompt = $Prompt.Replace($k, $tok[$k]); $WorkDir = $WorkDir.Replace($k, $tok[$k]); $SaveTo = $SaveTo.Replace($k, $tok[$k]); $Context = $Context.Replace($k, $tok[$k]); if ($Goal) { $Goal = $Goal.Replace($k, $tok[$k]) } }
if ($Supplier -notmatch '^[\w-]{1,30}$') { Write-Output 'agent-step: bad supplier name'; exit 2 }
# workers start in whatever folder the supervisor has (C:\Windows\System32 under the scheduled task, the code repo by hand): a relative
# SaveTo with no WorkDir would lose the answer or drop a private draft into the repo
if ($SaveTo -and -not $WorkDir -and -not [IO.Path]::IsPathRooted($SaveTo)) { Write-Output "agent-step: SaveTo must be an absolute path when there is no WorkDir ($SaveTo)"; exit 2 }

# attached files: read-only copies pasted into the order (so a cook without tools, like the local one, can work on them)
$ctx = [Text.StringBuilder]::new()
foreach ($f in @($Context -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    if (-not [IO.Path]::IsPathRooted($f) -and $WorkDir) { $f = Join-Path $WorkDir $f }
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { [void]$ctx.Append("`n`n=== $([IO.Path]::GetFileName($f)) (missing) ===`n"); continue }
    $body = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue; if ($null -eq $body) { $body = '' }
    if ($body.Length -gt 200000) { $body = $body.Substring(0, 200000) + "`n[... cut at 200,000 characters ...]" }
    if ($ctx.Length + $body.Length -gt 600000) { [void]$ctx.Append("`n`n=== $([IO.Path]::GetFileName($f)) (left out: attachments over 600,000 characters) ===`n"); continue }
    [void]$ctx.Append("`n`n=== $([IO.Path]::GetFileName($f)) ===`n$body")
}
if (-not $Goal -and $Prompt -match '(?ms)^(.*?)(?:\r?\n\r?\n)?(Goal:\s*[\s\S]+)$') {
    $basePrompt = $matches[1].TrimEnd()
    $goalTail = $matches[2].Trim()
} else {
    $basePrompt = $Prompt
    $goalTail = if ($Goal) { if ($Goal -match '(?i)^goal:\s*') { $Goal } else { "Goal: $Goal" } } else { '' }
}
$parts = [Collections.Generic.List[string]]::new()
# the Creed goes in front of EVERY cook's prompt (kitchen/CREED.md: no guessing, fully fleshed out, nothing silent, Jordan's taps are his).
# It is not part of what the sous chef's privacy judge reads (that reads the order only). Missing creed = loud, not silent.
$creedPath = Join-Path $PSScriptRoot 'CREED.md'
if (Test-Path -LiteralPath $creedPath -PathType Leaf) { $parts.Add((Get-Content -LiteralPath $creedPath -Raw).Trim()) } else { Write-Output "agent-step: WARNING kitchen/CREED.md is missing; this cook runs without the creed" }
if ($basePrompt) { $parts.Add($basePrompt) }
if ($ctx.Length) { $parts.Add("Attached files (read-only copies):$ctx") }
if ($goalTail) { $parts.Add($goalTail) }
$full = $parts -join "`n`n"
if ($env:KITCHEN_PROMPT_OUT) { Set-Content -LiteralPath $env:KITCHEN_PROMPT_OUT -Value $full -Encoding utf8 }   # tests and debugging: the exact prompt a cook would get

$promptOnly = (@($basePrompt, $goalTail) | Where-Object { $_ }) -join "`n`n"
$sousPrompt = if ($promptOnly) { $promptOnly } else { $Order }
$pickJson = & $sous pick -Role $Role -Prompt $sousPrompt -Tools $Tools -Mode $Mode -Supplier $Supplier -Model $Model -Private:$Private -Public:($Public -and -not $Private) -Order $Order -ContextChars $ctx.Length -Size $Size -Json | Out-String
try { $pick = $pickJson | ConvertFrom-Json -AsHashtable } catch { Write-Output "agent-step: the sous chef gave no decision: $($pickJson.Trim())"; exit 1 }
Write-Output "sous chef: $($pick.action) - $($pick.why)"
if ($env:KITCHEN_RUN) {   # keep the decision (and the -Private switch) next to the run for the Chef app, even if the sous chef's own write failed
    try { $pick.private = [bool]($pick.private -or $Private); $pick | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$env:KITCHEN_RUN.sous.json" -Encoding utf8 } catch {}
}

if ($env:KITCHEN_LIVE -ne '1' -and -not (Test-Path -LiteralPath (Join-Path $kroot 'LIVE'))) { Write-Output 'agent-step: live agents are off (just live-on). Dry run only; nothing was sent to any cook.'; exit 0 }
if ($pick.action -eq 'hold') {   # the whole reason next to the run (TD-EH-06): it becomes the Sign-off text, never cut mid-word
    if ($env:KITCHEN_RUN) { try { Set-Content -LiteralPath "$env:KITCHEN_RUN.hold" -Value "HOLD: $($pick.why)" -Encoding utf8 } catch { } }
    Write-Output "HOLD: $($pick.why)"; exit 10
}
if ($pick.action -eq 'wait') {
    if ($env:KITCHEN_RUN) { Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value ([int]$pick.waitSec) }
    Write-Output "WAIT: $($pick.why)"; exit 11
}
if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
else {   # no work folder: an empty one, never the inherited cwd (the profile or the kitchen folder holds the pass key and private chats)
    $empty = if ($env:KITCHEN_RUN) { "$env:KITCHEN_RUN.work" } else { Join-Path ([IO.Path]::GetTempPath()) "kitchen-work-$PID" }
    New-Item -ItemType Directory -Force -Path $empty | Out-Null; Set-Location -LiteralPath $empty
}
# In a kitchen worktree, agent config an earlier cook wrote (.claude/, CLAUDE.md, .mcp.json, .gemini/, GEMINI.md) is put back to the
# branch start before any cook runs, so it can't add hooks or permissions or steer the next cook (the commit station refuses it too)
$baseFile = if ($WorkDir) { Join-Path $WorkDir '.kitchen\BASE' } else { '' }
if ($baseFile -and (Test-Path -LiteralPath $baseFile)) {
    $base = (Get-Content -LiteralPath $baseFile -Raw).Trim()
    foreach ($g in '.claude', 'CLAUDE.md', 'CLAUDE.local.md', '.mcp.json', '.gemini', 'GEMINI.md') {
        $gp = Join-Path $WorkDir $g; $inBase = [bool](& git -C $WorkDir ls-tree --name-only $base -- $g 2>$null)
        if ($inBase) { & git -C $WorkDir checkout $base -- $g 2>&1 | Out-Null; & git -C $WorkDir clean -fdq -- $g 2>&1 | Out-Null }
        elseif (Test-Path -LiteralPath $gp) { Remove-Item -LiteralPath $gp -Recurse -Force; Write-Output "agent-step: removed $g that a cook wrote in the worktree (agent config is never taken from a cook)" }
    }
}

$choices = @(@{ supplier = $pick.supplier; model = $pick.model; effort = $pick.effort; tier = $pick.tier }) + @($pick.fallbacks | Where-Object { $_ })
$tried = @(); $res = $null; $used = $null; $allLimits = $true
# a short-lived provider error (5xx, unavailable, API or connection timeout) is a wait, not a failure
$hiccup = '(?i)\b50[0234]\b|UNAVAILABLE|overloaded|\b429\b|rate.?limit|too many requests|DEADLINE_EXCEEDED|ETIMEDOUT|ECONNRESET|ECONNREFUSED|socket hang up|(api|request|connection|network)\W+(error|timed?\s?out)|timed out (talking|connecting)'
foreach ($c in $choices | Select-Object -First 3) {
    if ($env:KITCHEN_HEARTBEAT) { for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::WriteAllText($env:KITCHEN_HEARTBEAT, "$(Get-Date -Format o) quiet=$($TimeoutSec + 120)"); break } catch [IO.IOException] { Start-Sleep -Milliseconds 50 } } }   # the cook may run silent up to its own time limit
    $ef = if ($Effort -and $c.supplier -eq 'claude') { $Effort } else { [string]$c.effort }
    Write-Output ("agent-step: role $Role -> $($c.supplier) $(if ($c.model) { $c.model } else { '(its default model)' })$(if ($ef) { " ($ef effort)" }), budget `$$MaxBudgetUsd, max $MaxTurns turns")
    $adapter = Join-Path $PSScriptRoot "cooks\$($c.supplier).ps1"
    if (-not (Test-Path -LiteralPath $adapter)) { Write-Output "agent-step: no adapter for $($c.supplier)"; $allLimits = $false; continue }
    $res = & $adapter -Prompt $full -Model ([string]$c.model) -Effort $ef -Tools $Tools -Mode $Mode -MaxTurns $MaxTurns -MaxBudgetUsd $MaxBudgetUsd -TimeoutSec $TimeoutSec -Role $Role |
        Where-Object { $_ -is [Collections.IDictionary] } | Select-Object -Last 1
    if (-not $res) { $res = @{ ok = $false; error = 'the adapter returned nothing' } }
    $tried += @{ supplier = $c.supplier; model = [string]$c.model; ok = [bool]$res.ok; error = [string]$res.error }
    $used = $c
    if ($res.limit -or $res.signedOut) {
        $why = if ($res.signedOut) { 'signed out' } else { [string]$res.error }
        & $sous rest -Name $c.supplier -ForMin $(if ($res.signedOut) { 30 } else { [int]$res.restMin }) -Why $why | Out-Null
        Write-Output "agent-step: $($c.supplier) can't cook now ($why); it rests and the next cook takes over"
        continue
    }
    $allLimits = $false
    break
}
if ($res -and ($res.limit -or $res.signedOut) -and $allLimits) {
    if ($env:KITCHEN_RUN) { Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value 900 }
    Write-Output 'WAIT: every able cook is at its usage limit or signed out; trying again later'; exit 11
}
if ($res.text) { Write-Output ([string]$res.text) }
if ($res.ok -and $env:KITCHEN_RUN -and $res.text) { Set-Content -LiteralPath "$env:KITCHEN_RUN.dish.md" -Value ([string]$res.text) -Encoding utf8 }   # the answer itself, for the Chef app
if ($res.ok -and $SaveTo) {   # a failed save is a failed step: the next step would otherwise read a missing or stale file
    try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SaveTo) -ErrorAction Stop | Out-Null; Set-Content -LiteralPath $SaveTo -Value ([string]$res.text) -Encoding utf8 -ErrorAction Stop }
    catch { Write-Output "agent-step: could not save the answer to $SaveTo ($($_.Exception.Message))"; exit 1 }
}
if ($env:KITCHEN_RUN -and $used) {
    @{ usd = [double]$res.usd; turns = [int]$res.turns; model = $(if ($res.model) { [string]$res.model } else { [string]$used.model }); role = $Role
       supplier = $used.supplier; tier = $used.tier; kind = $pick.kind; reason = [string]$pick.why; private = [bool]$pick.private; tried = $tried
       inputTokens = [int]$res.inputTokens; outputTokens = [int]$res.outputTokens
       cacheReadTokens = [int]$res.cacheReadTokens; cacheWriteTokens = [int]$res.cacheWriteTokens
       isError = -not $res.ok; subtype = [string]$res.error } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$env:KITCHEN_RUN.cost.json" -Encoding utf8
}
if (-not $res.ok -and $used -and -not $res.limit -and -not $res.signedOut -and [string]$res.error -match $hiccup -and [string]$res.error -notmatch 'took longer than') {
    $err = [string]$res.error; if ($err.Length -gt 200) { $err = $err.Substring(0, 200) }
    $changed = $false
    if ($Mode -ne 'plan' -and $WorkDir) {
        $st = & git -C $WorkDir status --porcelain -- . ':(exclude).kitchen' 2>$null
        $changed = [bool](@($st | Where-Object { $_ }).Count)
    }
    if ($changed) {
        Write-Output "agent-step: $($used.supplier) hit a cloud hiccup ($err) after changing files; keeping the changes and moving on (tests and the taster still check them)"
        exit 0
    }
    $sec = Get-Random -Minimum 60 -Maximum 301   # jittered, so a crowd of waiting jobs doesn't hit the provider together
    if ($env:KITCHEN_RUN) {
        Set-Content -LiteralPath "$env:KITCHEN_RUN.wait" -Value $sec
        Set-Content -LiteralPath "$env:KITCHEN_RUN.hiccup" -Value $err
    }
    Write-Output "WAIT: $($used.supplier) hit a cloud hiccup ($err); trying again in about $([math]::Round($sec / 60)) min"; exit 11
}
if (-not $res.ok) { Write-Output "agent-step: $($used.supplier) failed: $($res.error)"; exit 1 }
exit 0
