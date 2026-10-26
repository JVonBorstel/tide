# One-command swarm demo: 10 simulated agents, each misbehaving a different way, and the supervisor catching every one.
# Safe to run anywhere: private state under TEMP, simulated workers only, no network, nothing left running.
#   pwsh -File kitchen/demo.ps1 [-Open]      (-Open shows the status page in the browser when done)
param([switch]$Open)
$ErrorActionPreference = 'Stop'
$k = Join-Path $PSScriptRoot 'kitchen.ps1'
$w = Join-Path $PSScriptRoot 'demo-worker.ps1'
$env:BRAIN_KITCHEN = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-demo-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$env:BRAIN_NTFY_TOPIC = $null
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
$cast = @(
    @('researcher', 'ok', 'does its job and finishes'),
    @('flaky-api', 'flaky', 'fails once, should succeed on retry'),
    @('broken-tool', 'fail', 'always fails, should be quarantined'),
    @('crasher', 'crash', 'dies without a word'),
    @('memory-hog', 'hog', 'eats RAM until stopped'),
    @('chatterbox', 'flood', 'floods its log'),
    @('frozen', 'hang', 'stops responding but stays alive'),
    @('slowpoke', 'slow', 'never finishes on its own'),
    @('deployer', 'ok', 'risky step: must wait for a human yes'),
    @('recruiter', 'spawner', 'tries to spawn 20 more agents')
)
Say "`nJORDAN'S KITCHEN: swarm demo" 'Cyan'
Say "10 agents. Each one shows a different way agents go wrong. The supervisor has to catch all of them.`n"
foreach ($c in $cast) {
    $extra = @{}
    if ($c[0] -eq 'deployer') { $extra.Approve = $true }
    if ($c[1] -eq 'slow') { $extra.TimeoutSec = 6 }
    & $k add -Name $c[0] -Script $w -ScriptArgs @{ Behavior = $c[1]; Seconds = 2 } -TimeoutSec ($extra.TimeoutSec ?? 30) -MaxMB 400 -MaxLogMB 5 -HungSec 6 -Retries 1 -Approve:([bool]$extra.Approve) | Out-Null
    Say ("  {0,-12} {1}" -f $c[0], $c[2])
}
Say "`nRunning the swarm. Halfway through, the supervisor itself is 'crashed' and restarted from disk.`n" 'Cyan'
& $k watch -Seconds 7 -MaxConcurrent 6 -BackoffBaseSec 1 -BreakerMin 99
Say "`n  >> supervisor stopped. Workers keep running; nothing is lost. Restarting...`n" 'Yellow'
& $k watch -Seconds 60 -MaxConcurrent 6 -BackoffBaseSec 1 -BreakerMin 99
Say "`nThe deployer is waiting for a human. Approving it now (in real life: a tap on Jordan's phone).`n" 'Cyan'
& $k approve -Id J9
& $k watch -Seconds 20 -BreakerMin 99 -Quiet
Say "`nRESULT" 'Cyan'
& $k status
$html = Join-Path $env:BRAIN_KITCHEN 'status.html'
& $k report -HtmlPath $html | Out-Null
Say "`nStatus page: $html" 'Green'
Say "Full audit trail: $(Join-Path $env:BRAIN_KITCHEN 'events.jsonl')" 'Green'
& $k kill -All | Out-Null
if ($Open) { Invoke-Item $html }
