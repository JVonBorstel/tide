# The Talk tab: one chat message in, one answer out. Jordan talks to the kitchen from the Chef app instead of a desktop app.
# Every message goes through the sous chef like any order: privacy first (personal -> the local cook, and the whole chat stays on this
# PC from then on), then the talk menu (claude / antigravity / gemini / local, moved by plan usage). The cook gets no tools and works
# in an empty folder: it can only talk. It may PROPOSE one order from the recipe book; the app shows that as a card and nothing is
# cooked until Jordan taps it. Chats live in <kitchen root>\talk (T<n>.jsonl = messages, T<n>.json = title and privacy).
#   talk.ps1 -Thread T1 -Message ' hello' [-Private] [-Json]      (a leading space keeps a message from being read as a parameter)
#   talk.ps1 -Thread T1 -Read [-Json]                             the chat so far
param([Parameter(Mandatory)][string]$Thread, [string]$Message = '', [switch]$Private, [switch]$Read, [switch]$Json)
$ErrorActionPreference = 'Stop'
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$dir = Join-Path $kroot 'talk'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
$sous = Join-Path $PSScriptRoot 'sous-chef.ps1'
$recipesDir = if ($env:KITCHEN_RECIPES) { $env:KITCHEN_RECIPES } else { Join-Path $PSScriptRoot 'recipes' }
function Out-Result($o) { if ($Json) { $o | ConvertTo-Json -Depth 8 -Compress } else { $o }; exit 0 }
function Fail([string]$why) { Out-Result @{ ok = $false; error = $why } }
if ($Thread -notmatch '^T\d{1,6}$') { Fail 'bad chat id' }
$logPath = Join-Path $dir "$Thread.jsonl"; $metaPath = Join-Path $dir "$Thread.json"
$meta = $null; if (Test-Path -LiteralPath $metaPath) { try { $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json -AsHashtable } catch { } }
if (-not $meta) { $meta = @{ id = $Thread; title = ''; private = $false; created = (Get-Date).ToUniversalTime().ToString('o') } }
$history = @(if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Encoding utf8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json -AsHashtable } catch { } } })
if ($Read) { Out-Result @{ ok = $true; meta = $meta; messages = $history } }

$msg = $Message.Trim()
if (-not $msg) { Fail 'say something first' }
if ($msg.Length -gt 6000) { Fail 'that message is too long (6,000 characters at most); place an order for long pastes' }
$now = { (Get-Date).ToUniversalTime().ToString('o') }
function Add-Line($o) { Add-Content -LiteralPath $logPath -Value ($o | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8 }
function Save-Meta { $meta.updated = & $now; $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metaPath -Encoding utf8 }
if ($Private) { $meta.private = $true }   # once private, always private: earlier messages travel with every new one
if (-not $meta.title) { $t = ($msg -replace '\s+', ' '); $meta.title = if ($t.Length -gt 60) { $t.Substring(0, 57) + '...' } else { $t } }
Add-Line @{ role = 'you'; text = $msg; at = (& $now) }

# ---- the recipe book, so the cook can suggest an order ----
$book = @{}
foreach ($f in @(Get-ChildItem -LiteralPath $recipesDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
    if ($f.BaseName -notmatch '^[\w-]{1,40}$' -or $f.BaseName -in 'ask', 'diagnose') { continue }   # 'ask' is what this chat already is; 'diagnose' needs a failure record
    try { $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { continue }
    $book[$f.BaseName] = $r
}
$menuLines = foreach ($n in ($book.Keys | Sort-Object)) {
    $vars = @(foreach ($v in $book[$n].vars.Keys) { "$v$(if ($book[$n].vars[$v].required) { ' (required)' })" }) -join ', '
    "- $n`: $([string]$book[$n].description)$(if ($vars) { " Fields: $vars." })"
}

# ---- the conversation so far (newest last, about 10,000 characters at most) ----
$past = [Collections.Generic.List[string]]::new(); $size = 0
$recent = @($history | Select-Object -Last 16)
for ($i = $recent.Count - 1; $i -ge 0; $i--) {
    $h = $recent[$i]; $line = "$(if ($h.role -eq 'you') { 'Jordan' } else { 'Kitchen' }): $([string]$h.text)"
    if ($size + $line.Length -gt 10000) { break }
    $past.Insert(0, $line); $size += $line.Length
}
$prompt = @"
You are the Kitchen: Jordan's own assistant, running on his PC and reached from his phone. Talk like a capable, warm friend: plain words, short answers (he reads on a phone), no filler. Be honest when you don't know.
You have no tools and can't run anything yourself. The kitchen can do bigger jobs as orders from this recipe book:
$($menuLines -join "`n")
Answer questions and talk things through yourself. Only when Jordan asks for a bigger job one of these recipes covers (a search, a tailored resume, a code change), answer briefly and end with ONE last line exactly like this (valid JSON, fields from that recipe only):
ORDER: {"recipe":"<name>","vars":{"<field>":"<value>"}}
He sees it as a card and decides; never say an order was placed or a job was done. Never use ORDER for anything outside the book.
$(if ($past.Count) { "`nThe conversation so far:`n$($past -join "`n")`n" })
Jordan's new message:
$msg
"@

# ---- the sous chef decides who answers ----
$live = $env:KITCHEN_LIVE -eq '1' -or (Test-Path -LiteralPath (Join-Path $kroot 'LIVE'))
# the privacy patterns read everything that would be sent (the chat so far plus the new message), the life judge reads the new message
$pickArgs = @{ Role = 'talk'; Prompt = ' ' + ((@($past) + $msg) -join "`n"); Order = ' ' + $msg; Tools = 'none'; Mode = 'plan'; Private = [bool]$meta.private; Json = $true }
if (-not $live) { $pickArgs.Supplier = 'local' }   # AI cooks switched off: the free local cook still talks
$t0 = [Diagnostics.Stopwatch]::StartNew()
$pickJson = & $sous pick @pickArgs | Out-String
try { $pick = $pickJson | ConvertFrom-Json -AsHashtable } catch { $pick = $null }
$reply = @{ role = 'kitchen'; text = ''; at = ''; ok = $false; cook = ''; model = ''; private = [bool]$meta.private; why = '' }
# the message is already in the history, so a private verdict marks the chat private whatever happens next (cook, hold or wait), and
# no verdict at all does too (fail closed): otherwise the next harmless message would carry this one to a cloud cook
if (-not $pick -or $pick.private) { $meta.private = $true; $reply.private = $true }
if (-not $pick) { $reply.text = 'The sous chef did not answer, so nothing was sent anywhere. Try again in a minute.' }
elseif ($pick.action -in 'hold', 'wait') { $reply.text = "Nobody can take this right now: $($pick.why)"; $reply.why = [string]$pick.why }
else {
    if ($pick.private) { $meta.private = $true; $reply.private = $true }
    $reply.why = if ($live) { [string]$pick.why } else { 'AI cooks are off, so the free local cook answered' }
    $work = Join-Path $dir 'work'; New-Item -ItemType Directory -Force -Path $work | Out-Null; Set-Location -LiteralPath $work   # nothing here to read
    $choices = @(@{ supplier = $pick.supplier; model = $pick.model; effort = $pick.effort; tier = $pick.tier }) + @($pick.fallbacks | Where-Object { $_ })
    $res = $null; $used = $null
    foreach ($c in $choices | Select-Object -First 3) {
        if ($meta.private -and $c.supplier -ne 'local') { continue }   # belt and braces: a private chat never leaves this PC
        $adapter = Join-Path $PSScriptRoot "cooks\$($c.supplier).ps1"; if (-not (Test-Path -LiteralPath $adapter)) { continue }
        $res = & $adapter -Prompt $prompt -Model ([string]$c.model) -Effort ([string]$c.effort) -Tools 'none' -Mode 'plan' -MaxTurns 2 -MaxBudgetUsd 0.5 -TimeoutSec 240 -Role 'talk' |
            Where-Object { $_ -is [Collections.IDictionary] } | Select-Object -Last 1
        if (-not $res) { $res = @{ ok = $false; error = 'the cook returned nothing' } }
        $used = $c
        if ($res.limit -or $res.signedOut) { & $sous rest -Name $c.supplier -ForMin $(if ($res.signedOut) { 30 } else { [math]::Max(5, [int]$res.restMin) }) -Why $(if ($res.signedOut) { 'signed out' } else { [string]$res.error }) | Out-Null; continue }
        break
    }
    if ($used) {
        $reply.cook = [string]$used.supplier; $reply.model = $(if ($res.model) { [string]$res.model } else { [string]$used.model })
        $ev = @{ ts = (& $now); job = 'talk'; step = 0; model = $reply.model; supplier = $reply.cook }
        $cost = $ev.Clone(); $cost.type = 'cost'; $cost.usd = [double]$res.usd; $cost.turns = [int]$res.turns
        $cost.inputTokens = [int]$res.inputTokens; $cost.outputTokens = [int]$res.outputTokens
        $cost.cacheReadTokens = [int]$res.cacheReadTokens; $cost.cacheWriteTokens = [int]$res.cacheWriteTokens
        $cook = $ev.Clone(); $cook.type = 'cook'; $cook.ok = [bool]$res.ok; $cook.kind = 'talk'; $cook.reason = "chat $Thread -> $($reply.cook) $($reply.model)"
        try { Add-Content -LiteralPath (Join-Path $kroot 'events.jsonl') -Value (($cost | ConvertTo-Json -Compress), ($cook | ConvertTo-Json -Compress)) -Encoding utf8 } catch { }
    }
    if ($res -and $res.ok -and $res.text) {
        $reply.ok = $true; $text = ([string]$res.text).Trim()
        # a proposed order: checked against the recipe book; anything that doesn't fit is dropped, never cooked
        $m = [regex]::Matches($text, '(?m)^[ \t>*`]*ORDER:\s*(\{.*\})[ \t`]*$')
        if ($m.Count) {
            $last = $m[$m.Count - 1]; $text = $text.Remove($last.Index, $last.Length).Trim()
            try { $o = $last.Groups[1].Value | ConvertFrom-Json -AsHashtable } catch { $o = $null }
            $rn = if ($o) { [string]$o.recipe } else { '' }
            if ($o -and $book.ContainsKey($rn)) {
                $vars = @{}; $okVars = $true
                foreach ($k in @($o.vars.Keys)) {
                    if (-not $book[$rn].vars -or -not $book[$rn].vars.ContainsKey($k) -or $o.vars[$k] -isnot [string] -or $o.vars[$k].Length -gt 6000) { $okVars = $false; break }
                    if ($o.vars[$k].Trim()) { $vars[$k] = $o.vars[$k].Trim() }
                }
                $missing = @(foreach ($k in @($book[$rn].vars.Keys)) { if ($book[$rn].vars[$k].required -and -not $vars[$k]) { $k } })
                if ($okVars) { $reply.proposal = @{ recipe = $rn; vars = $vars; about = [string]$book[$rn].description; missing = $missing } }
            }
        }
        $reply.text = $text
    }
    elseif ($res) { $reply.text = "That didn't work: $(if ($res.error) { $res.error } else { 'the cook gave no answer' }). Nothing else was sent; try again."; $reply.error = [string]$res.error }
    else { $reply.text = 'Every cook that could take this is resting or signed out right now. Try again soon.' }
}
$reply.at = & $now; $reply.ms = [int]$t0.ElapsedMilliseconds
Add-Line $reply; Save-Meta
Out-Result @{ ok = $true; reply = $reply; meta = $meta }
