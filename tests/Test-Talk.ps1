# Tests for the Talk tab's engine (kitchen/talk.ps1): routing through the sous chef, private chats staying on this PC for good,
# chat memory, proposed orders checked against the recipe book (never cooked), the AI-off switch, and the empty work folder.
# Scripted fakes only (claude CLI, agy, Ollama); nothing leaves the machine. Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$talk = Join-Path $kd 'talk.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-talk-' + [guid]::NewGuid().ToString('N'))
$fk = "$root-fakes"; $rec = "$root-recipes"
$saveEnv = @{}; foreach ($n in 'BRAIN_KITCHEN', 'KITCHEN_CLAUDE_EXE', 'KITCHEN_AGY_EXE', 'KITCHEN_OLLAMA_URL', 'KITCHEN_NVSMI', 'KITCHEN_LIVE', 'KITCHEN_RECIPES', 'KITCHEN_APPROVED') { $saveEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
$env:BRAIN_KITCHEN = $root; $env:KITCHEN_APPROVED = $null; $env:KITCHEN_RECIPES = $rec
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Say([string]$t, [string]$msg, [switch]$Private) { (& $talk -Thread $t -Message (' ' + $msg) -Private:$Private -Json | Out-String) | ConvertFrom-Json }
function Mode([string]$claude = 'ok') { Set-Content "$fk\modes.txt" $claude }
function Calls { @(Get-Content "$fk\claude-calls.txt" -ErrorAction SilentlyContinue) }
$node = $null
try {
    New-Item -ItemType Directory -Force -Path $root, $fk, $rec | Out-Null
    Set-Content "$rec\tailor.json" '{"description":"Tailor a resume to a posting.","vars":{"posting":{"required":true}},"steps":[{"station":"agent","args":{"Prompt":"x"}}]}'
    Set-Content "$fk\claude.ps1" @'
$m = @(Get-Content "$PSScriptRoot\modes.txt")
if ($args[0] -eq 'auth') { '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; exit 0 }
$model = ''; $p = ''; for ($i = 0; $i -lt $args.Count; $i++) { if ($args[$i] -eq '--model') { $model = $args[$i + 1] }; if ($args[$i] -eq '-p') { $p = $args[$i + 1] } }
Add-Content "$PSScriptRoot\claude-calls.txt" ("$model|$((Get-Location).Path)|" + ($p -replace "`r?`n", ' '))
$ti = [array]::IndexOf($args, '--tools'); Add-Content "$PSScriptRoot\claude-tools.txt" $(if ($ti -ge 0) { "tools=[$($args[$ti + 1])]" } else { 'tools=unset' })
$text = switch ($m[0]) {
  'order'    { "Sure, I can set that up.`nORDER: {""recipe"":""tailor"",""vars"":{""posting"":""Acme TypeScript dev""}}" }
  'badorder' { "Okay.`nORDER: {""recipe"":""wipe-disk"",""vars"":{}}" }
  'extra'    { "Okay.`nORDER: {""recipe"":""tailor"",""vars"":{""posting"":""x"",""Tools"":""Bash""}}" }
  'limit'    { $null }
  default    { "claude says hi from $model" }
}
if ($null -eq $text) { @{ type = 'result'; is_error = $true; result = 'Claude AI usage limit reached|' + ([DateTimeOffset]::UtcNow.AddMinutes(90).ToUnixTimeSeconds()) } | ConvertTo-Json -Compress; exit 1 }
@{ type = 'result'; is_error = $false; result = $text; total_cost_usd = 0.01; num_turns = 1; usage = @{ input_tokens = 100; output_tokens = 20 } } | ConvertTo-Json -Compress
'@
    Set-Content "$fk\ollama.mjs" @'
import http from 'node:http';
const models = [{ name: 'qwen3.5:9b', model: 'qwen3.5:9b', size: 6e9 }, { name: 'qwen2.5:3b', model: 'qwen2.5:3b', size: 1.9e9 }];
http.createServer((req, res) => {
  let b = ''; req.on('data', (d) => b += d); req.on('end', () => {
    const j = (o) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); };
    if (req.url === '/api/tags') return j({ models });
    if (req.url === '/api/ps') return j({ models: [] });
    if (req.url === '/v1/systemone') {
      const text = JSON.parse(b).state.order; const p = /landlord|sister|lonely/.test(text) ? 0.97 : 0.02;
      return j({ answers: { about: { type: 'choice', choice: p > 0.5 ? 'personal' : 'technical', probabilities: { personal: p, technical: 1 - p, general: 0 } }, kind: { type: 'choice', choice: 'write', probabilities: { write: 0.9 } } } });
    }
    if (req.url === '/api/chat') {
      const q = JSON.parse(b); const user = q.messages[q.messages.length - 1].content;
      if (q.format) return j({ message: { content: JSON.stringify({ about: /landlord|sister|lonely/.test(user) ? 'personal' : 'technical', kind: 'write' }) } });
      return j({ message: { content: `local answer from ${q.model} remembers=${/sister/.test(user)}` }, prompt_eval_count: 5, eval_count: 3 });
    }
    res.writeHead(404); res.end();
  });
}).listen(0, '127.0.0.1', function () { console.log(this.address().port); });
'@
    $psi = [Diagnostics.ProcessStartInfo]::new('node', "`"$fk\ollama.mjs`""); $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $node = [Diagnostics.Process]::Start($psi); $port = $node.StandardOutput.ReadLine()
    $env:KITCHEN_CLAUDE_EXE = "$fk\claude.ps1"; $env:KITCHEN_AGY_EXE = 'off'
    $env:KITCHEN_OLLAMA_URL = "http://127.0.0.1:$port"; $env:KITCHEN_NVSMI = 'none'; $env:KITCHEN_LIVE = '1'
    Set-Content (Join-Path $root 'kitchen.json') '{"sous":{"judgeTimeoutSec":2}}'
    Mode

    # ---- 1. a plain technical message: Claude (Sonnet) answers, in an empty folder, with no tools ----
    $r = Say 'T1' 'how do I debounce a React input?'
    Check 'answered ok' ($r.ok -and $r.reply.ok)
    Check 'talk menu: claude sonnet first' ($r.reply.cook -eq 'claude' -and $r.reply.model -eq 'sonnet')
    Check 'reply text from the cook' ($r.reply.text -match 'claude says hi')
    Check 'not private' (-not $r.reply.private -and -not $r.meta.private)
    Check 'title from the first message' ($r.meta.title -eq 'how do I debounce a React input?')
    $c = @(Calls)[-1]
    Check 'cook ran in the empty talk work folder' ($c -match [regex]::Escape((Join-Path $root 'talk\work')))
    Check 'cook saw the recipe book' ($c -match 'tailor: Tailor a resume')
    Check 'claude gets no tools at all (--tools empty)' ((Get-Content "$fk\claude-tools.txt" | Select-Object -Last 1) -eq 'tools=[]')
    Check 'no tools granted' ((Get-Content "$fk\claude-calls.txt" -Raw) -notmatch 'Bash|Edit|Write')
    $ev = @(Get-Content (Join-Path $root 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.job -eq 'talk' })
    Check 'cook and cost events counted against the plan' (@($ev | Where-Object type -eq 'cook').Count -eq 1 -and @($ev | Where-Object type -eq 'cost').Count -eq 1 -and $ev[0].supplier -eq 'claude')

    # ---- 2. memory: the next message carries the conversation ----
    $r = Say 'T1' 'and with a custom hook?'
    $c = @(Calls)[-1]
    Check 'history goes with the next message' ($c -match 'Jordan: how do I debounce' -and $c -match 'Kitchen: claude says hi')
    $h = (& $talk -Thread T1 -Read -Json | Out-String) | ConvertFrom-Json
    Check 'read: 4 messages in order' ($h.messages.Count -eq 4 -and $h.messages[0].role -eq 'you' -and $h.messages[3].role -eq 'kitchen')

    # ---- 3. a personal message: local cook, and the chat stays private for good ----
    $r = Say 'T2' 'my sister and my landlord are fighting'
    Check 'personal -> local cook' ($r.reply.cook -eq 'local' -and $r.reply.private -and $r.meta.private)
    $n = @(Calls).Count
    $r = Say 'T2' 'explain TCP slow start'
    Check 'later technical message in a private chat stays local' ($r.reply.cook -eq 'local' -and @(Calls).Count -eq $n)
    Check 'local cook got the history' ($r.reply.text -match 'remembers=True')
    $r = Say 'T3' 'just a normal question about css grid' -Private
    Check 'Jordan can mark a chat private' ($r.reply.cook -eq 'local' -and $r.meta.private)
    # the local cook resting: a personal message gets a wait, but the chat is private from then on, so the next harmless message
    # (which carries this one in its history) never reaches a cloud cook
    & (Join-Path $kd 'sous-chef.ps1') rest -Name local -ForMin 30 -Why 'test' | Out-Null
    $r = Say 'T8' 'my sister and my landlord want my offer letter'
    Check 'personal message while local rests -> no cook, but the chat is marked private' (-not $r.reply.ok -and $r.reply.private -and $r.meta.private)
    & (Join-Path $kd 'sous-chef.ps1') wake -Name local | Out-Null
    $n = @(Calls).Count
    $r = Say 'T8' 'ok, any thoughts?'
    Check 'next harmless message in that chat stays on this PC' ($r.reply.cook -eq 'local' -and @(Calls).Count -eq $n)
    # the patterns read the history that would be sent, not only the new message
    $r = Say 'T9' 'note for later: my card 4111 1111 1111 1111' -Private
    $meta9 = Join-Path $root 'talk\T9.json'; $m9 = Get-Content $meta9 -Raw | ConvertFrom-Json -AsHashtable; $m9.private = $false; $m9 | ConvertTo-Json | Set-Content $meta9
    $n = @(Calls).Count
    $r = Say 'T9' 'what is a monad?'
    Check 'a card number in the history keeps the next message local' ($r.reply.cook -eq 'local' -and @(Calls).Count -eq $n)

    # ---- 4. proposed orders: a card, never cooked, checked against the book ----
    Mode 'order'
    $r = Say 'T4' 'tailor my resume for the Acme posting'
    Check 'proposal: recipe and vars' ($r.reply.proposal.recipe -eq 'tailor' -and $r.reply.proposal.vars.posting -eq 'Acme TypeScript dev')
    Check 'ORDER line removed from the text' ($r.reply.text -eq 'Sure, I can set that up.')
    Check 'no job was created' (-not (Test-Path (Join-Path $root 'jobs')))
    Mode 'badorder'
    $r = Say 'T4' 'wipe it all'
    Check 'unknown recipe -> no card' (-not $r.reply.proposal -and $r.reply.text -eq 'Okay.')
    Mode 'extra'
    $r = Say 'T4' 'tailor with extras'
    Check 'unknown field -> no card' (-not $r.reply.proposal)

    # ---- 5. limits and switches ----
    Mode 'limit'
    $r = Say 'T5' 'what is a monad?'
    Check 'claude at its limit -> rests, nothing crashes' ($r.ok -and (Get-Content (Join-Path $root 'suppliers-state.json') -Raw) -match 'claude')
    Mode
    Remove-Item (Join-Path $root 'suppliers-state.json') -Force
    $env:KITCHEN_LIVE = $null
    $r = Say 'T6' 'what is a monad?'
    Check 'AI cooks off -> the local cook still talks' ($r.reply.cook -eq 'local' -and $r.reply.ok)
    $env:KITCHEN_LIVE = '1'

    # ---- 6. bad input ----
    $r = (& $talk -Thread 'X1; rm' -Message ' hi' -Json | Out-String) | ConvertFrom-Json
    Check 'bad chat id refused' (-not $r.ok)
    $r = Say 'T7' '   '
    Check 'empty message refused' (-not $r.ok)
    $r = Say 'T7' ('a' * 6001)
    Check 'over-long message refused' (-not $r.ok -and -not (Test-Path (Join-Path $root 'talk\T7.jsonl')))
}
finally {
    if ($node -and -not $node.HasExited) { $node.Kill() }
    foreach ($n in $saveEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $saveEnv[$n]) }
    Remove-Item -Recurse -Force $root, $fk, $rec -ErrorAction SilentlyContinue
}
Write-Host "Talk: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
