# Put a new Chef live without breaking anything.
#   App files only (public/): nothing to do; the server picks them up within 2 s and phones swap over when idle.
#   Server changed: syntax check -> a trial server on a spare port against the real kitchen (read-only) -> phones told "restart"
#   -> swap -> health check. The live server is touched only after the trial passes. Usage: pwsh pass-app/update.ps1 [-Force]
#   Test hooks (tests/Test-BoardDeploy.ps1): -TrialOnly stops after the trial (the live server is never touched); -ShowTaskName prints the
#   Board's scheduled task name and exits; -CheckPage <file> runs the served-page check on a file and exits.
param([int]$Port = 7878, [int]$TrialPort = 7979, [switch]$Force, [switch]$DryRun, [switch]$TrialOnly, [switch]$ShowTaskName, [string]$CheckPage = '',
  [string]$TaskNamesPath = (Join-Path $PSScriptRoot '..\scripts\task-names.json'))
$ErrorActionPreference = 'Stop'
$srv = Join-Path $PSScriptRoot 'server.mjs'
function Health($p) { try { Invoke-RestMethod "http://127.0.0.1:$p/api/health" -TimeoutSec 3 } catch { $null } }
function Fail($msg) { Write-Host "NOT UPDATED: $msg" -ForegroundColor Red; exit 1 }
# The served page must carry two markers that are not display text, so a renamed page title never blocks a deploy:
# the Pass view's id (route #/pass stays) and the app's module script tag. Returns the markers that are missing.
function Get-MissingMarkers([string]$html) {
  @('id="view-pass"', '<script src="/app.js" type="module">') | Where-Object { -not $html.Contains($_) }
}
# The Board's scheduled task: from scripts/task-names.json ("board": [old, new]) when that file exists, else Kitchen-Pass.
# Of the listed names, the newest one registered on this PC wins; if none is registered, the first (old) name.
function Get-BoardTaskName([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return 'Kitchen-Pass' }
  try { $names = @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).board | Where-Object { $_ -is [string] -and $_.Trim() }) } catch { Fail "task-names.json is not valid JSON: $path" }
  if (-not $names.Count) { Fail "task-names.json has no board name: $path" }
  for ($i = $names.Count - 1; $i -gt 0; $i--) { if (Get-ScheduledTask -TaskName $names[$i] -ErrorAction SilentlyContinue) { return $names[$i] } }
  $names[0]
}

if ($CheckPage) {
  $miss = @(Get-MissingMarkers (Get-Content -LiteralPath $CheckPage -Raw))
  if ($miss.Count) { Fail "the page lacks $($miss -join ' and ')" }
  'page ok: both markers present'; exit 0
}
$boardTask = Get-BoardTaskName $TaskNamesPath
if ($ShowTaskName) { "board task: $boardTask"; exit 0 }

# 1. syntax
foreach ($f in @($srv, (Join-Path $PSScriptRoot 'public\app.js'), (Join-Path $PSScriptRoot 'public\sw.js'))) {
  $out = & node --check $f 2>&1; if ($LASTEXITCODE) { Fail "syntax error in $(Split-Path $f -Leaf): $out" }
}
if ($DryRun) {
  "Chef update dry-run ok: syntax valid for server.mjs"
  exit 0
}
# the same fingerprint the server reports: server.mjs plus every local module it imports (a change to towers.mjs alone needs a restart too)
$want = "$(& node (Join-Path $PSScriptRoot 'server-id.mjs') $srv)".Trim()
if ($LASTEXITCODE -or $want -notmatch '^[0-9a-f]{12}$') { Fail "could not compute the server fingerprint: $want" }
$live = Health $Port
if ($live -and $live.server -eq $want -and -not $Force -and -not $TrialOnly) {
  Start-Sleep -Seconds 3; $live = Health $Port
  "Chef $($live.version): server unchanged, no restart needed. App build $($live.build) is live; phones switch over when idle."; exit 0
}

# 2. trial run on a spare port, reading the real kitchen
Get-NetTCPConnection -LocalPort $TrialPort -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
$env:PASS_PORT = "$TrialPort"; $env:PASS_NO_KICK = '1'
$trial = Start-Process node -ArgumentList "`"$srv`"" -PassThru -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\chef-trial-out.txt" -RedirectStandardError "$env:TEMP\chef-trial-err.txt"
$env:PASS_PORT = $null; $env:PASS_NO_KICK = $null
try {
  $h = $null; foreach ($i in 1..25) { $h = Health $TrialPort; if ($h) { break }; Start-Sleep -Milliseconds 200 }
  if (-not $h) { Fail "the new server did not start: $((Get-Content "$env:TEMP\chef-trial-err.txt" -Raw -ErrorAction SilentlyContinue))" }
  $root = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
  $key = (Get-Content (Join-Path $root 'pass-key.txt') -Raw).Trim(); $auth = @{ Authorization = "Bearer $key" }
  $st = Invoke-RestMethod "http://127.0.0.1:$TrialPort/api/state" -Headers $auth -TimeoutSec 10
  if ($null -eq $st.jobs) { Fail 'the new server could not read the kitchen' }
  $page = Invoke-WebRequest "http://127.0.0.1:$TrialPort/" -Headers $auth -TimeoutSec 10
  $miss = if ($page.StatusCode -eq 200) { @(Get-MissingMarkers ([string]$page.Content)) } else { @('a 200 answer') }
  if ($miss.Count) { Fail "the new server did not serve the app (missing $($miss -join ' and '))" }
  "trial ok: Chef $($h.version), build $($h.build), $(@($st.jobs).Count) jobs read"
} finally { if (-not $trial.HasExited) { Stop-Process -Id $trial.Id -Force } }
if ($TrialOnly) { 'trial only: the live server was not touched'; exit 0 }

# 3. swap: tell the phones, stop the old one, start the task, wait for health
$sw = [Diagnostics.Stopwatch]::StartNew()
try { Invoke-RestMethod "http://127.0.0.1:$Port/api/bye" -Method Post -Headers $auth -TimeoutSec 3 | Out-Null; Start-Sleep -Milliseconds 300 } catch {}
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
Start-ScheduledTask -TaskName $boardTask
$new = $null; foreach ($i in 1..60) { $new = Health $Port; if ($new -and $new.server -eq $want) { break }; Start-Sleep -Milliseconds 250 }
if (-not $new -or $new.server -ne $want) {
  Start-ScheduledTask -TaskName $boardTask; Start-Sleep 3; $new = Health $Port
  if (-not $new) { Fail 'Chef did not come back; the supervisor watchdog will keep trying every minute. Check pass-app logs.' }
}
"Chef $($new.version) live (build $($new.build)); offline for $([Math]::Round($sw.Elapsed.TotalSeconds,1)) s; phones reconnect on their own."
