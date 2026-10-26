# Tests for the agent-standup status section of scripts/handoff.ps1. Fake CLI in a temp folder; self-cleaning.
$ErrorActionPreference = 'Stop'
$ho = Join-Path $PSScriptRoot '..\scripts\handoff.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('hst-' + [guid]::NewGuid().ToString('N'))
$brain = Join-Path $root 'brain'; New-Item -ItemType Directory -Path (Join-Path $brain 'memory') -Force | Out-Null
Set-Content (Join-Path $brain 'memory\NOW.md') "# NOW`nfixture line"
$fakeK = Join-Path $root 'k.ps1'; Set-Content $fakeK 'Write-Output "OK"; exit 0'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function New-Cli($name, $js) { $d = Join-Path $root $name; New-Item -ItemType Directory -Path (Join-Path $d 'bin') -Force | Out-Null; Set-Content (Join-Path $d 'bin\agent-standup.js') $js; $d }
function Run-Ho($dir, [int]$to = 20) {
    $out = Join-Path $root ('out-' + [guid]::NewGuid().ToString('N') + '.md')
    $o = pwsh -NoProfile -File $ho -BrainPath $brain -Repos $root -OutPath $out -KitchenScript $fakeK -StandupDir $dir -StandupTimeoutSeconds $to 2>&1 | Out-String
    $script:ec = $LASTEXITCODE; $script:txt = if (Test-Path $out) { Get-Content $out -Raw } else { '' }; $script:o = $o
}

$good = New-Cli 'good' @'
console.log(JSON.stringify({needsYou:1,working:1,yourTurn:0,idle:2,sessions:[
 {project:"C--demo-proj",id:"abc123def456",state:"working",tool:"Bash",ageMs:1000,subAgentsActive:1,subAgents:3},
 {project:"C--other",id:"zzz",state:"blocked",tool:null,ageMs:5,subAgentsActive:0,subAgents:0}]}));
'@
Run-Ho $good; Check 'good exit 0' ($ec -eq 0)
Check 'summary line' ($txt -match 'Agent sessions: 1 working, 1 need you, 0 your turn, 2 idle')
Check 'session row' ($txt -match 'C--demo-proj abc123def456: working \(Bash\), sub-agents 1/3')
Check 'blocked row' ($txt -match 'C--other zzz: blocked, sub-agents 0/0')

Run-Ho (Join-Path $root 'nope'); Check 'missing dir ok' ($ec -eq 0 -and $txt -match 'Agent sessions: unavailable')

$hang = New-Cli 'hang' 'setTimeout(()=>{}, 60000);'
$sw = [Diagnostics.Stopwatch]::StartNew(); Run-Ho $hang 2
Check 'hung cli timed out' ($txt -match 'Agent sessions: timed out after 2s'); Check 'hung cli fast' ($sw.Elapsed.TotalSeconds -lt 30)
Start-Sleep -Milliseconds 500
Check 'hung cli killed' (@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like "*$root*" }).Count -eq 0)

$junk = New-Cli 'junk' 'console.log("not json");'
Run-Ho $junk; Check 'garbage handled' ($ec -eq 0 -and $txt -match 'Agent sessions: error')

$envp = New-Cli 'envp' 'console.log(JSON.stringify({needsYou:0,working:0,yourTurn:0,idle:0,sessions:[{project:"p",id:(process.env.ANTHROPIC_API_KEY?"KEYLEAK":"nokey"),state:"idle",tool:null,subAgentsActive:0,subAgents:0}]}));'
$env:ANTHROPIC_API_KEY = 'sk-test-not-real'; Run-Ho $envp; Remove-Item Env:ANTHROPIC_API_KEY
Check 'api key not passed to cli' ($txt -match 'nokey' -and $txt -notmatch 'KEYLEAK')

$ctl = New-Cli 'ctl' 'console.log(JSON.stringify({needsYou:0,working:0,yourTurn:0,idle:0,sessions:[{project:"bad\u0007​proj",id:"i",state:"idle",tool:null,subAgentsActive:0,subAgents:0}]}));'
Run-Ho $ctl; Check 'control chars stripped' ($txt -notmatch "[\x00-\x08\x0b\x0c\x0e-\x1f]" -and $txt -notmatch "​" -and $txt -match 'bad')

$sec = New-Cli 'sec' ('console.log(JSON.stringify({needsYou:0,working:0,yourTurn:0,idle:0,sessions:[{project:"AKIA' + 'ABCDEFGHIJKLMNOP",id:"i",state:"idle",tool:null,subAgentsActive:0,subAgents:0}]}));')
Run-Ho $sec; Check 'secret in cli output refused' ($ec -eq 2)

Remove-Item -Recurse -Force $root
Write-Host "HandoffStandup tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
