# Tests for the kitchen front ends (kitchen-api.ps1, inbox, kitchen-mcp.ps1) and the redundancy layer (doctor, damaged files, backups).
# Private kitchen root under TEMP; self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$k = Join-Path $kd 'kitchen.ps1'; $api = Join-Path $kd 'kitchen-api.ps1'; $mcp = Join-Path $kd 'kitchen-mcp.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-api-' + [guid]::NewGuid().ToString('N'))
$env:BRAIN_KITCHEN = $root; $env:KITCHEN_AGY_EXE = 'off'; $env:BRAIN_NTFY_TOPIC = $null; $env:BRAIN_AGENT_DEPTH = $null; $env:KITCHEN_JOB = $null
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Api([string]$json, [string]$ch = 'chef') { (& $api -Channel $ch -RequestJson $json | Out-String) | ConvertFrom-Json }
function Job($id) { Get-Content (Join-Path $root "jobs\$id.json") -Raw | ConvertFrom-Json }
$outside = Join-Path $root 'outside.ps1'
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Set-Content $outside 'exit 0'

    # 1. contract basics
    $r = Api '{"id":"r1","op":"status"}'
    Check 'status ok with id echoed' ($r.ok -and $r.id -eq 'r1' -and $null -ne $r.data)
    Check 'bad json -> ok:false' (-not (Api 'not json').ok)
    Check 'missing op -> ok:false' (-not (Api '{"id":"x"}').ok)
    Check 'unknown op refused' (-not (Api '{"op":"format-disk"}').ok)

    # 2. add via cli
    $r = Api '{"op":"add","args":{"name":"cli job","script":"demo-worker.ps1","args":{"Behavior":"ok","Seconds":1}}}'
    Check 'cli add ok' ($r.ok -and $r.data.job -eq 'J1' -and -not $r.data.needsApproval)
    Check 'bad name refused' (-not (Api '{"op":"add","args":{"name":"x|y","script":"demo-worker.ps1"}}').ok)
    Check 'nested arg value refused' (-not (Api '{"op":"add","args":{"name":"n","script":"demo-worker.ps1","args":{"Behavior":{"a":1}}}}').ok)
    Check 'out-of-range timeout refused' (-not (Api '{"op":"add","args":{"name":"n","script":"demo-worker.ps1","timeoutSec":999999}}').ok)

    # 3. bot channels: no approve, scripts confined, work gated
    Check 'mcp cannot approve' (-not (Api '{"op":"approve","args":{"id":"J1"}}' 'pass').ok)
    Check 'inbox cannot approve' (-not (Api '{"op":"approve","args":{"id":"J1"}}' 'rail').ok)
    Check 'bots cannot requeue' (-not (Api '{"op":"requeue","args":{"id":"J1"}}' 'pass').ok -and -not (Api '{"op":"requeue","args":{"id":"J1"}}' 'rail').ok)
    Check 'requeue needs a job id' (-not (Api '{"op":"requeue","args":{"id":"x; rm"}}').ok)
    $req = @{ op = 'add'; args = @{ name = 'escape'; script = $outside } } | ConvertTo-Json -Compress
    Check 'mcp script outside allowed roots refused' (-not (Api $req 'pass').ok)
    Check 'path traversal refused' (-not (Api '{"op":"add","args":{"name":"t","script":"..\\scripts\\approvals.ps1"}}' 'pass').ok)
    $r = Api '{"op":"add","args":{"name":"bot agent","script":"agent-step.ps1","args":{"Prompt":"hi"}}}' 'pass'
    Check 'bot job outside autoApprove is gated' ($r.ok -and $r.data.needsApproval -and (Job $r.data.job).steps[0].approve)
    $gated = [string]$r.data.job   # section 8 signs it off by its WO- and SO- names, after kill all has stopped it
    $r = Api '{"op":"add","args":{"name":"bot demo","script":"demo-worker.ps1","args":{"Behavior":"ok","Seconds":1}}}' 'pass'
    Check 'autoApprove script runs without a gate' ($r.ok -and -not $r.data.needsApproval)
    Set-Content (Join-Path $root 'channels.json') '{"channels":{"pass":["status","approve"]}}'
    Check 'config cannot grant approve to a bot channel' (-not (Api '{"op":"approve","args":{"id":"J1"}}' 'pass').ok)
    Set-Content (Join-Path $root 'channels.json') '{ broken'
    Check 'broken config falls back to safe defaults' ((Api '{"op":"status"}' 'pass').ok -and -not (Api '{"op":"approve","args":{"id":"J1"}}' 'pass').ok)
    Remove-Item (Join-Path $root 'channels.json')

    # 4. inbox transport (processed on tick)
    $in = Join-Path $root 'rail'; New-Item -ItemType Directory -Force -Path $in | Out-Null
    Set-Content (Join-Path $in 'a.json') '{"id":"in1","op":"add","args":{"name":"from inbox","script":"demo-worker.ps1","args":{"Behavior":"ok","Seconds":1}}}'
    Set-Content (Join-Path $in 'b.json') '{"id":"in2","op":"approve","args":{"id":"J3"}}'
    Set-Content (Join-Path $in 'c.json') 'garbage'
    & $k tick -Quiet | Out-Null
    $oa = Get-Content (Join-Path $root 'window\a.json') -Raw | ConvertFrom-Json
    $ob = Get-Content (Join-Path $root 'window\b.json') -Raw | ConvertFrom-Json
    $oc = Get-Content (Join-Path $root 'window\c.json') -Raw | ConvertFrom-Json
    Check 'inbox add answered in outbox' ($oa.ok -and $oa.id -eq 'in1' -and $oa.channel -eq 'rail')
    Check 'inbox approve refused' (-not $ob.ok)
    Check 'inbox garbage answered, not crashed' (-not $oc.ok)
    Check 'inbox emptied' (@(Get-ChildItem $in -Filter *.json).Count -eq 0)
    & $k watch -Seconds 30 -Quiet -BreakerMin 99 | Out-Null
    Check 'inbox job ran to done' ((Job $oa.data.job).status -eq 'done')

    # 5. MCP over stdio
    $msgs = @(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}',
        '{"jsonrpc":"2.0","method":"notifications/initialized"}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"kitchen_status","arguments":{}}}',
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"kitchen_approve","arguments":{"id":"J3"}}}',
        '{"jsonrpc":"2.0","id":5,"method":"nope"}'
    ) -join "`n"
    $lines = @($msgs | pwsh -NoProfile -File $mcp | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'mcp answers each request (not notifications)' ($lines.Count -eq 5)
    Check 'mcp initialize' ($lines[0].result.serverInfo.name -eq 'kitchen' -and $lines[0].result.protocolVersion -eq '2025-06-18')
    Check 'mcp lists 7 tools, none approve' (@($lines[1].result.tools).Count -eq 7 -and -not (@($lines[1].result.tools.name) -match 'approve'))
    Check 'mcp status call works' (-not $lines[2].result.isError -and ($lines[2].result.content[0].text | ConvertFrom-Json).ok)
    Check 'mcp unknown tool is an error' ($lines[3].error.code -eq -32602)
    Check 'mcp unknown method is an error' ($lines[4].error.code -eq -32601)

    # 6. redundancy: damaged job file, stuck job, backup
    Set-Content (Join-Path $root 'jobs\J50.json') '{ this is not json'
    $s = Api '{"op":"status"}'
    Check 'damaged job file does not break status' ($s.ok)
    Check 'damaged file set aside' (@(Get-ChildItem (Join-Path $root 'corrupt') -Filter 'J50-*.json').Count -eq 1 -and -not (Test-Path (Join-Path $root 'jobs\J50.json')))
    Check 'damaged file alerted' ((Get-Content (Join-Path $root 'alerts.jsonl') -Raw) -match 'J50.json was damaged')
    $r = Api '{"op":"add","args":{"name":"after damage","script":"demo-worker.ps1"}}'
    Check 'new ids never reuse a damaged id' ([int]$r.data.job.Substring(1) -gt 50)
    $d = Api '{"op":"doctor"}'
    Check 'doctor reports the damaged file' ($d.ok -and -not $d.data.ok -and ($d.data.problems -join ' ') -match 'damaged')
    Check 'doctor made a backup' (@(Get-ChildItem -LiteralPath ([string]$d.data.backup) -Filter 'J*.json').Count -ge 1)

    # 6b. recipes over every channel; bots are gated
    $rl = Api '{"op":"recipes"}' 'pass'
    Check 'recipes listed for bots' ($rl.ok -and @($rl.data.name) -contains 'research')
    $bc = Api '{"op":"cook","args":{"recipe":"research","vars":{"question":"test question"}}}' 'rail'
    Check 'bot recipe order is gated' ($bc.ok -and $bc.data.needsApproval -and (Job $bc.data.job).steps[0].approve)
    $cc = Api '{"op":"cook","args":{"recipe":"research","vars":{"question":"test question"}}}'
    Check 'chef recipe order starts without a gate' ($cc.ok -and -not $cc.data.needsApproval)
    Check 'cook with a missing value refused' (-not (Api '{"op":"cook","args":{"recipe":"improve","vars":{}}}').ok)
    Check 'cook with a bad recipe refused' (-not (Api '{"op":"cook","args":{"recipe":"../x"}}').ok)
    Check 'a failed order does not poison the next answer' ((Api '{"op":"status"}').ok -and (Api '{"op":"doctor"}').ok)

    # 7. kill via api, report via api
    Check 'kill all via api' ((Api '{"op":"kill","args":{"all":true}}').ok)
    $rep = Api '{"op":"report"}' 'pass'
    Check 'report via mcp channel' ($rep.ok -and (Test-Path $rep.data.path))

    # 8. Tide input aliases (S2-IDALIAS): WO-0207 / #0207 -> J207 and SO-104 -> A104 before the checks; stored IDs never change
    function Num([string]$id) { [int]$id.Substring(1) }
    function Read-JobFile([string]$id) { Get-Content (Join-Path $root "jobs\$id.json") -Raw | ConvertFrom-Json }   # the suite's Job helper, named so the analyzer does not read it as Get-Job
    $g = Num $gated; $ga = [string](Read-JobFile $gated).approval.id
    Check 'gated job has a stored A approval id' ($ga -match '^A\d+$')
    $kw = Api ('{"op":"kill","args":{"id":"WO-' + $g + '"}}') 'pass'
    Check 'kill WO-n accepted on a bot channel' ($kw.ok)
    Check 'kill WO-0n (zero padded) accepted' ((Api ('{"op":"kill","args":{"id":"WO-' + $g.ToString('0000') + '"}}')).ok)
    Check 'kill #0n accepted' ((Api ('{"op":"kill","args":{"id":"#' + $g.ToString('0000') + '"}}')).ok)
    Check 'kill J-n still accepted' ((Api ('{"op":"kill","args":{"id":"J' + $g + '"}}')).ok)
    $bad = Api '{"op":"kill","args":{"id":"x; rm"}}'
    Check 'kill garbage refused with the same message' (-not $bad.ok -and $bad.error -eq 'kill needs args.id like "WO-0003" (or "J3") or args.all = true')
    $so = Api '{"op":"kill","args":{"id":"SO-104"}}'
    Check 'kill SO- (a sign-off) is never read as a work order' (-not $so.ok -and $so.error -eq 'kill needs args.id like "WO-0003" (or "J3") or args.all = true')
    $ap = Api '{"op":"approve","args":{"id":"A104"}}'
    Check 'approve A104 (an application or sign-off id) is never read as a work order' (-not $ap.ok -and $ap.error -eq 'approve needs args.id like "WO-0003" (or "J3")')
    $ap = Api '{"op":"approve","args":{"id":"WO-1","approval":"WO-104"}}'
    Check 'approve WO- as the sign-off refused with the same message' (-not $ap.ok -and $ap.error -eq 'approve: args.approval must look like "SO-12" (or "A12")')
    $ap = Api '{"op":"approve","args":{"id":"WO-1","approval":"A-1001"}}'
    Check 'a job-hunt style A-1001 is not a sign-off' (-not $ap.ok -and $ap.error -eq 'approve: args.approval must look like "SO-12" (or "A12")')
    $ap = Api '{"op":"approve","args":{"id":"WO-207x"}}'
    Check 'approve garbage refused with the same message' (-not $ap.ok -and $ap.error -eq 'approve needs args.id like "WO-0003" (or "J3")')
    Check 'bots still cannot approve with WO-/SO-' (-not (Api ('{"op":"approve","args":{"id":"WO-' + $g + '","approval":"SO-' + (Num $ga) + '"}}') 'pass').ok)
    $wrong = Api ('{"op":"approve","args":{"id":"WO-' + $g.ToString('0000') + '","approval":"SO-99999"}}')
    Check 'approve WO-0n reaches the kitchen; a stale SO- is refused there' (-not $wrong.ok -and $wrong.error -match [regex]::Escape("now asks something else ($ga)"))
    Check 'stale SO- left the stored ask alone' (-not (Read-JobFile $gated).approval.granted -and [string](Read-JobFile $gated).approval.id -eq $ga)
    $yes = Api ('{"op":"approve","args":{"id":"WO-' + $g.ToString('0000') + '","approval":"SO-' + (Num $ga).ToString('0000') + '"}}')
    Check 'approve WO-0n with SO-0n signs off the stored A id' ($yes.ok -and [string]$yes.data -match [regex]::Escape("approved $ga for $gated"))
    $ap = Api ('{"op":"approve","args":{"id":"J' + $g + '","approval":"' + $ga + '"}}')
    Check 'approve J-n with A-n still reaches the kitchen' ([string]$ap.data + [string]$ap.error -match [regex]::Escape($ga))
    $ap = Api ('{"op":"approve","args":{"id":"WO-' + $g + '","approval":"SO-' + (Num $ga) + '"}}')
    Check 'approve WO-n with SO-n (no zero padding) reaches the kitchen as the stored A id' ($ap.error -ne 'approve: args.approval must look like "SO-12" (or "A12")' -and $ap.error -ne 'approve needs args.id like "WO-0003" (or "J3")' -and ([string]$ap.data + [string]$ap.error) -match ('\b' + [regex]::Escape($ga) + '\b'))
    Check 'stored job id unchanged' ((Read-JobFile $gated).id -eq $gated)
    $rq = Api '{"op":"requeue","args":{"id":"WO-0001"}}'
    Check 'requeue WO-0001 reaches the kitchen as J1' (-not $rq.ok -and $rq.error -match '\bJ1 is done;')
    $rq = Api '{"op":"requeue","args":{"id":"SO-1"}}'
    Check 'requeue SO- refused with the same message' (-not $rq.ok -and $rq.error -eq 'requeue needs args.id like "WO-0003" (or "J3")')
} finally {
    $env:BRAIN_KITCHEN = $null; $env:KITCHEN_AGY_EXE = $null
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains((Split-Path $root -Leaf)) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }  # only this run's GUID root: a concurrent run of this suite (another job's tests station, verify) must keep its workers
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
Write-Host "KitchenApi tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
