# Tests for kitchen/start-order.ps1 (which pending order the supervisor starts first) and cook.ps1's priority var.
# Pure function checks plus one cook.ps1 refusal; no kitchen root is touched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\kitchen\start-order.ps1')
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function J($id, $cursor = 0, $prio = $null) { $v = @{}; if ($prio) { $v.priority = $prio }; [pscustomobject]@{ id = $id; cursor = $cursor; vars = [pscustomobject]$v } }

$ids = { param($list) (Sort-ForStart $list | ForEach-Object id) -join ' ' }
Check 'oldest first when nothing else differs' ((& $ids @((J 'J12'), (J 'J3'), (J 'J7'))) -eq 'J3 J7 J12')
Check 'numbers sort as numbers, not text (J9 before J10)' ((& $ids @((J 'J10'), (J 'J9'))) -eq 'J9 J10')
Check 'an order already under way starts before a new one' ((& $ids @((J 'J1'), (J 'J5' 4))) -eq 'J5 J1')
Check 'urgent before normal before low among new orders' ((& $ids @((J 'J1' 0 'low'), (J 'J2'), (J 'J3' 0 'urgent'))) -eq 'J3 J2 J1')
Check 'an urgent new order never jumps an order under way' ((& $ids @((J 'J9' 0 'urgent'), (J 'J4' 2))) -eq 'J4 J9')
Check 'priority is case-insensitive; an unknown word counts as normal' ((& $ids @((J 'J2' 0 'bogus'), (J 'J1' 0 'LOW'), (J 'J3' 0 'Urgent'))) -eq 'J3 J2 J1')
Check 'no vars at all is normal' ((Get-StartRank ([pscustomobject]@{ id = 'J1'; cursor = 0 })).priority -eq 1)
Check 'an empty queue sorts to nothing' (@(Sort-ForStart @()).Count -eq 0)
# 1,000 orders rank in well under a tick (the same path for 10 orders or 1,000)
$many = 1..1000 | ForEach-Object { J "J$_" ($_ % 3) @('urgent', 'normal', 'low')[$_ % 3] }
$t = [Diagnostics.Stopwatch]::StartNew(); $sorted = Sort-ForStart $many; $t.Stop()
Check "1,000 orders sort in under 5 s (took $($t.ElapsedMilliseconds) ms)" ($sorted.Count -eq 1000 -and $t.ElapsedMilliseconds -lt 5000)
# cook.ps1 takes priority as a reserved var and refuses anything but urgent, normal or low
$cook = Join-Path $PSScriptRoot '..\kitchen\cook.ps1'
# a private kitchen root, so even a wrongly accepted order could never reach the real queue
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-startorder-' + [guid]::NewGuid().ToString('N'))
$bad = & pwsh -NoProfile -Command "`$env:BRAIN_KITCHEN = '$tmpRoot'; & '$cook' -Recipe improve -Vars @{ goal = 'x'; priority = 'asap' }" 2>&1 | Out-String
Check 'cook.ps1 refuses an unknown priority before filing anything' ($bad -match 'priority must be urgent, normal or low' -and -not (Test-Path (Join-Path $tmpRoot 'jobs')))
Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
$src = Get-Content $cook -Raw
Check 'cook.ps1 lists priority among the reserved vars' ($src -match "priority = 'normal'")
$ks = Get-Content (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1') -Raw
Check 'the supervisor start loop walks Sort-ForStart' ($ks -match 'foreach \(\$j in \(Sort-ForStart \$jobs\)\)')
Write-Host "StartOrder tests: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
