# Simulated agent for demos and tests. Each behaviour is one way a real agent goes wrong; the supervisor must catch every one.
#   ok       works, heartbeats, exits 0          slow     keeps working past its time limit
#   crash    dies abruptly (no exit code)         hog      eats memory until capped
#   flaky    fails the first attempt, then works   fail     always exits 1 (should end quarantined)
#   flood    floods its log                        hang     stops heartbeating but stays alive
#   spawner  tries to add 20 child jobs (caps must refuse most of them)
#   skipper  says it passed but quietly skipped tests (the taster must catch it)
#   costly   finishes but reports a $5 bill (the daily budget must stop new work)
param([ValidateSet('ok', 'slow', 'crash', 'hog', 'flaky', 'fail', 'flood', 'hang', 'spawner', 'skipper', 'costly')][string]$Behavior = 'ok', [int]$Seconds = 3)
function Beat { if ($env:KITCHEN_HEARTBEAT) { for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::WriteAllText($env:KITCHEN_HEARTBEAT, (Get-Date -Format o)); break } catch [IO.IOException] { Start-Sleep -Milliseconds 50 } } } }
Write-Output "demo-worker $Behavior starting (job $env:KITCHEN_JOB, depth $env:BRAIN_AGENT_DEPTH)"
switch ($Behavior) {
    'ok' { for ($i = 1; $i -le $Seconds; $i++) { Beat; Write-Output "working $i/$Seconds"; Start-Sleep 1 }; exit 0 }
    'slow' { while ($true) { Beat; Start-Sleep 1 } }
    'crash' { Beat; Start-Sleep 1; Stop-Process -Id $PID -Force }
    'hog' { $keep = [Collections.Generic.List[byte[]]]::new(); while ($true) { Beat; $b = New-Object byte[] 50MB; for ($i = 0; $i -lt $b.Length; $i += 4096) { $b[$i] = 1 }; $keep.Add($b); Start-Sleep -Milliseconds 200 } }
    'flaky' {
        $mark = "$env:KITCHEN_RUN.flaky"; $first = Join-Path (Split-Path $env:KITCHEN_RUN) "$env:KITCHEN_JOB.flaky-seen"
        Beat; Start-Sleep 1
        if (-not (Test-Path -LiteralPath $first)) { Set-Content -LiteralPath $first -Value 1; Write-Output 'flaky: failing this time'; exit 1 }
        Write-Output 'flaky: worked on retry'; exit 0
    }
    'fail' { Beat; Start-Sleep 1; Write-Output 'fail: something is broken'; exit 1 }
    'flood' { $line = 'x' * 1000; while ($true) { Beat; for ($i = 0; $i -lt 2000; $i++) { Write-Output $line } } }
    'hang' { Beat; Start-Sleep 3600 }
    'skipper' { Beat; Write-Output 'migration fixed'; Write-Output '48 passed, 2 skipped'; Write-Output 'marking task done'; exit 0 }
    'costly' { Beat; if ($env:KITCHEN_RUN) { @{ usd = 5.0; turns = 12; model = 'sonnet'; role = 'do' } | ConvertTo-Json | Set-Content -LiteralPath "$env:KITCHEN_RUN.cost.json" }; Write-Output 'expensive work done'; exit 0 }
    'spawner' {
        $k = Join-Path $PSScriptRoot 'kitchen.ps1'; $okCount = 0; $refused = 0
        for ($i = 1; $i -le 20; $i++) {
            $out = & $k add -Name "child-$i" -Script (Join-Path $PSScriptRoot 'demo-worker.ps1') -ScriptArgs @{ Behavior = 'ok'; Seconds = 1 } 2>&1 | Out-String
            if ($out -match '^added') { $okCount++ } else { $refused++ }
            Beat   # a working agent heartbeats as it goes: 20 adds took over 6 s on a loaded PC, and a silent spawner was killed as hung
        }
        Write-Output "spawner: $okCount children added, $refused refused"; Beat; exit 0
    }
}
