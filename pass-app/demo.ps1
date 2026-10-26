# Chef demo: a throwaway kitchen with sample jobs, served on its own port, for looking at the app without touching the real one.
# The real kitchen state and the live server (7878) are never touched. Stop with -Stop.
param([int]$Port = 7999, [switch]$Stop)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP 'chef-ui-demo'
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
# the demo's own workers too (a 'slow' sample job would otherwise outlive the demo)
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { [string]$_.CommandLine -match 'chef-ui-demo' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if ($Stop) { 'demo stopped'; return }
if (Test-Path $root) { Get-ChildItem $root -Recurse -File | Where-Object Name -ne 'pass-key.txt' | Remove-Item -Force -ErrorAction SilentlyContinue }   # the key stays, so a signed-in browser stays signed in
New-Item -ItemType Directory -Force $root | Out-Null

$env:BRAIN_KITCHEN = $root
$k = Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1'; $w = Join-Path $PSScriptRoot '..\kitchen\demo-worker.ps1'
& $k add -Name 'improve: split kitchen.ps1 into modules' -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } -Approve | Out-Null
& $k add -Name 'research: best local models for 8 GB' -Script $w -ScriptArgs @{ Behavior = 'slow'; Seconds = 600 } -TimeoutSec 900 | Out-Null
& $k add -Name 'review: security of the Chef app' -Script $w -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } | Out-Null
& $k add -Name 'flaky nightly check' -Script $w -ScriptArgs @{ Behavior = 'fail'; Seconds = 1 } -Retries 0 | Out-Null
& $k watch -Seconds 12 -BreakerMin 99 -Quiet | Out-Null
$board = [ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); spentToday = 3.42; dailyBudgetUsd = 20
  suppliers = [ordered]@{
    claude = @{ status = 'signed-out'; why = 'not signed in (run claude once on the PC and sign in)'; plan = 'subscription'; runs = 0; maxRuns = 40; windowHours = 5; models = @('opus', 'sonnet', 'haiku'); track = @{} }
    gemini = @{ status = 'ready'; why = 'ready'; plan = 'subscription'; runs = 12; maxRuns = 150; windowHours = 24; models = @('(default)'); track = @{ research = '5/6'; write = '3/3' } }
    local  = @{ status = 'ready'; why = 'ready'; plan = 'free'; runs = 7; maxRuns = 1000; windowHours = 1; models = @('qwen3.5:9b', 'qwen2.5:3b'); track = @{ check = '4/4'; write = '2/3' } } }
  judge = @{ decider = 'tev1:0.8b'; privateAt = 0.3; fallback = 'qwen2.5:3b'; privateWords = 2 } }
$board | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'suppliers-board.json')

# a sample chat for the Talk tab (new messages here are answered by the local cook only: AI cooks are off in the demo)
$td = Join-Path $root 'talk'; New-Item -ItemType Directory -Force $td | Out-Null; $t0 = (Get-Date).ToUniversalTime().AddMinutes(-6)
@{ id = 'T1'; title = 'Which of the scout jobs should I go for first?'; private = $false; created = $t0.ToString('o'); updated = $t0.AddMinutes(2).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $td 'T1.json')
@(@{ role = 'you'; text = 'Which of the scout jobs should I go for first?'; at = $t0.ToString('o') },
  @{ role = 'kitchen'; ok = $true; cook = 'claude'; model = 'sonnet'; ms = 14200; at = $t0.AddMinutes(1).ToString('o'); private = $false
     text = "**ExampleCo, Software Engineer AI.** It fits best:`n- TypeScript and React, which you know`n- they build LLM eval pipelines, which you've done`n- Springfield hybrid`n`nWant a tailored resume for it?" },
  @{ role = 'you'; text = 'yes do it'; at = $t0.AddMinutes(2).ToString('o') },
  @{ role = 'kitchen'; ok = $true; cook = 'claude'; model = 'sonnet'; ms = 9100; at = $t0.AddMinutes(2).AddSeconds(9).ToString('o'); private = $false; text = 'Here is the order. It runs on your PC with the local cook, so your resume never leaves it.'
     proposal = @{ recipe = 'tailor'; vars = @{ posting = 'ExampleCo - Software Engineer, AI (Springfield hybrid). TypeScript, React, LLM evals, document parsing.' }; about = 'Tailor: paste a job posting; the local cook drafts a tailored summary, resume bullets and a short cover note.'; missing = @() } }
) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } | Set-Content (Join-Path $td 'T1.jsonl') -Encoding utf8
# the job hunt reads a copy of the newest scout file (your real tracker is never touched by the demo)
$cd = Join-Path $root 'career'; New-Item -ItemType Directory -Force (Join-Path $cd 'scout') | Out-Null
Get-ChildItem (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain\projects\career\scout') -Filter '*-openings.md' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1 | Copy-Item -Destination (Join-Path $cd 'scout')
@{ items = @(@{ id = 'A1'; company = 'ExampleCo'; role = 'Software Engineer, AI'; where = 'Springfield hybrid'; link = 'https://example.com/a'; status = 'applied'; appliedAt = (Get-Date).AddDays(-8).ToString('yyyy-MM-dd'); followUp = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd'); notes = ''; savedAt = (Get-Date).AddDays(-9).ToString('o') }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $cd 'tracker.json')
$env:PASS_CAREER_DIR = $cd
$env:PASS_PORT = "$Port"; $env:PASS_NO_KICK = '1'
Start-Process node -ArgumentList ('"' + (Join-Path $PSScriptRoot 'server.mjs') + '"') -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $root 'srv-out.txt') -RedirectStandardError (Join-Path $root 'srv-err.txt')
foreach ($i in 1..20) { try { $h = Invoke-RestMethod "http://127.0.0.1:$Port/api/health" -TimeoutSec 2; break } catch { Start-Sleep -Milliseconds 300 } }
"demo up on http://127.0.0.1:$Port (Chef $($h.version)); open /login once and paste the key from $root\pass-key.txt"
