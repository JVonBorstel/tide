# Tests for scripts/standup.ps1 (supervised launcher for the pinned agent-standup clone). Self-cleaning.
$ErrorActionPreference = 'Stop'
$su = Join-Path $PSScriptRoot '..\scripts\standup.ps1'
# the launcher runs Jordan's pinned agent-standup clone; a machine without it (the CI box) has nothing to launch
if (-not (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'source\repos\agent-standup\package.json'))) { Write-Host 'SKIP: no agent-standup clone on this machine'; Write-Host 'Standup tests: 0 passed, 0 failed'; exit 0 }
$root = Join-Path ([IO.Path]::GetTempPath()) ('sut-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$env:BRAIN_STANDUP_STATE = Join-Path $root 'state'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function FreePort { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p }
function PortOpen($p) { try { $c = [Net.Sockets.TcpClient]::new(); $a = $c.BeginConnect('127.0.0.1', $p, $null, $null); $ok = $a.AsyncWaitHandle.WaitOne(800) -and $c.Connected; $c.Close(); $ok } catch { $false } }
function Get-Http($port, $path) { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$port$path"; [pscustomobject]@{ code = [int]$r.StatusCode; body = $r.Content } } catch { [pscustomobject]@{ code = -1; body = '' } } }
function Su { param([string[]]$a) $o = pwsh -NoProfile -File $su @a 2>&1 | Out-String; $script:o = $o; $script:ec = $LASTEXITCODE }
function StateObj { $f = Join-Path $env:BRAIN_STANDUP_STATE 'run.json'; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } }

# 1. nothing running
Su @('-Action', 'status'); Check 'status not running' ($ec -eq 1)

# 2. demo start; API key must NOT reach the server even if set in the launching shell
$port = FreePort
$env:ANTHROPIC_API_KEY = 'sk-test-not-real-0000'
Su @('-Action', 'start', '-Mode', 'demo', '-Port', $port, '-MaxMinutes', '5')
Remove-Item Env:ANTHROPIC_API_KEY
Check 'demo start exit 0' ($ec -eq 0)
Check 'port open' (PortOpen $port)
$st = StateObj; Check 'state has pids' ($st.node -gt 0 -and $st.supervisor -gt 0)
$h = Get-Http $port '/api/health'; Check 'health 200' ($h.code -eq 200)
Check 'api key stripped' (($h.body | ConvertFrom-Json).apiKey -eq $false)
Su @('-Action', 'status'); Check 'status running' ($ec -eq 0 -and $o -match "127.0.0.1:$port")

# 3. demo mode exposes no real projects, but the built-in fictional session works
$pr = Get-Http $port '/api/projects'
Check 'projects 200' ($pr.code -eq 200)
Check 'no real project names' ($pr.body -notmatch 'C--Users' -and $pr.body -notmatch 'scratch')
Check 'demo session 200' ((Get-Http $port '/api/session?proj=_demo&id=demo').code -eq 200)

# 4. second start refused; foreign Host header rejected
Su @('-Action', 'start', '-Mode', 'demo', '-Port', (FreePort)); Check 'second start refused' ($ec -eq 3)
$c = [Net.Sockets.TcpClient]::new('127.0.0.1', $port); $s = $c.GetStream()
$req = [Text.Encoding]::ASCII.GetBytes("GET /api/health HTTP/1.1`r`nHost: evil.example`r`nConnection: close`r`n`r`n"); $s.Write($req, 0, $req.Length)
$buf = New-Object byte[] 512; $n = $s.Read($buf, 0, 512); $c.Close()
Check 'foreign Host -> 403' ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -match '403')

# 5. stop cleans everything
$nodePid = $st.node; $supPid = $st.supervisor
Su @('-Action', 'stop'); Check 'stop exit 0' ($ec -eq 0)
Start-Sleep -Milliseconds 800
Check 'port closed' (-not (PortOpen $port))
Check 'state removed' ($null -eq (StateObj))
Check 'node gone' ($null -eq (Get-Process -Id $nodePid -ErrorAction SilentlyContinue))
Check 'supervisor gone' ($null -eq (Get-Process -Id $supPid -ErrorAction SilentlyContinue))
Su @('-Action', 'stop'); Check 'stop when idle is ok' ($ec -eq 0)

# 6. auto-expire
$port = FreePort
Su @('-Action', 'start', '-Mode', 'demo', '-Port', $port, '-MaxMinutes', '0.1'); Check 'expire start' ($ec -eq 0)
$st = StateObj; $nodePid = $st.node
Start-Sleep 11
Check 'auto-expired: port closed' (-not (PortOpen $port))
Check 'auto-expired: node gone' ($null -eq (Get-Process -Id $nodePid -ErrorAction SilentlyContinue))
Check 'auto-expired: state removed' ($null -eq (StateObj))

# 7. pin check refuses a different commit; nothing listens
$port = FreePort
Su @('-Action', 'start', '-Port', $port, '-PinnedSha', 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'); Check 'wrong pin refused' ($ec -eq 5)
Check 'wrong pin: nothing listening' (-not (PortOpen $port))

# 8. port in use refused
$l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $busy = $l.LocalEndpoint.Port
Su @('-Action', 'start', '-Port', $busy); Check 'busy port refused' ($ec -eq 4)
$l.Stop()

# 9. supervisor killed hard: status reaps the orphaned node
$port = FreePort
Su @('-Action', 'start', '-Mode', 'demo', '-Port', $port, '-MaxMinutes', '5')
$st = StateObj; $nodePid = $st.node
Stop-Process -Id $st.supervisor -Force
Start-Sleep -Milliseconds 800
Su @('-Action', 'status'); Check 'status after supervisor death = not running' ($ec -eq 1)
Start-Sleep -Milliseconds 500
Check 'orphan node reaped' ($null -eq (Get-Process -Id $nodePid -ErrorAction SilentlyContinue))
Check 'state cleared after reap' ($null -eq (StateObj))

# 10. live mode works end to end (status codes only; no transcript content is read or printed)
$port = FreePort
Su @('-Action', 'start', '-Mode', 'live', '-Port', $port, '-MaxMinutes', '5'); Check 'live start' ($ec -eq 0)
Check 'live projects 200' ((Get-Http $port '/api/projects').code -eq 200)
Check 'live warns about exposure' ($o -match 'LIVE')
Su @('-Action', 'stop'); Start-Sleep -Milliseconds 800
Check 'live stopped' (-not (PortOpen $port))

Remove-Item Env:BRAIN_STANDUP_STATE -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $root
Write-Host "Standup tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
