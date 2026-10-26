# Tests for kitchen/stations/lint.ps1 invariant checks (bare python, unmonitored background spawns, secret patterns).
# Free checks before running tests. Self-cleaning. Secret values are assembled dynamically from fragments.
$ErrorActionPreference = 'Stop'
$lint = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\lint.ps1')).Path
$d = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-lintstation-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Lint { $o = & pwsh -NoProfile -File $lint @args 2>&1 | Out-String; @{ out = $o; code = $LASTEXITCODE } }

$a36 = 'A1b2C3d4' * 5
$tokGh = 'gh' + 'p_' + $a36
$tokOa = 's' + 'k-' + $a36
$tokSlack = 'xo' + 'xb-' + '1234567890-abcdef'
$valSec = 'Zx9Qw8Er7' + 'Ty6Ui5O'
$valPw = 'super' + 'Secret99'

try {
    New-Item -ItemType Directory -Force -Path $d | Out-Null

    # ---- 1. Bare Python Invocations ----
    # 1a. PowerShell direct command
    $pyDirectContent = @(
        '# Header comment'
        'python app.py'
        'python3 -c "print(1)"'
        'python.exe script.py'
    ) -join "`n"
    Set-Content (Join-Path $d 'py_direct.ps1') $pyDirectContent
    $r = Lint -Dir $d -Files 'py_direct.ps1'
    Check 'bare python direct: exit code 1' ($r.code -eq 1)
    Check 'bare python direct: flags line 2 python' ($r.out -match "py_direct\.ps1:2 bare python/python3 invocation is forbidden")
    Check 'bare python direct: flags line 3 python3' ($r.out -match "py_direct\.ps1:3 bare python/python3 invocation is forbidden")
    Check 'bare python direct: flags line 4 python.exe' ($r.out -match "py_direct\.ps1:4 bare python/python3 invocation is forbidden")

    # 1b. PowerShell Start-Process python
    $pySapsContent = @(
        'Start-Process python -Wait'
        'Start-Process -FilePath "python3.exe" -Wait'
        'saps -FilePath python -Wait'
    ) -join "`n"
    Set-Content (Join-Path $d 'py_saps.ps1') $pySapsContent
    $r = Lint -Dir $d -Files 'py_saps.ps1'
    Check 'bare python Start-Process: exit code 1' ($r.code -eq 1)
    Check 'bare python Start-Process: flags line 1' ($r.out -match "py_saps\.ps1:1 bare python/python3 invocation is forbidden")
    Check 'bare python Start-Process: flags line 2' ($r.out -match "py_saps\.ps1:2 bare python/python3 invocation is forbidden")
    Check 'bare python saps: flags line 3' ($r.out -match "py_saps\.ps1:3 bare python/python3 invocation is forbidden")

    # 1c. Node child process with bare python
    $pyNodeContent = @(
        "const { exec } = require('child_process');"
        "exec('python script.py');"
        "const { spawn } = require('child_process');"
        "spawn('python3', ['app.py']);"
        "execSync('python.exe -m test');"
    ) -join "`n"
    Set-Content (Join-Path $d 'py_node.js') $pyNodeContent
    $r = Lint -Dir $d -Files 'py_node.js'
    Check 'bare python Node: exit code 1' ($r.code -eq 1)
    Check 'bare python Node: flags line 2 exec' ($r.out -match "py_node\.js:2 bare python/python3 invocation is forbidden")
    Check 'bare python Node: flags line 4 spawn' ($r.out -match "py_node\.js:4 bare python/python3 invocation is forbidden")
    Check 'bare python Node: flags line 5 execSync' ($r.out -match "py_node\.js:5 bare python/python3 invocation is forbidden")

    # 1d. Clean commands pass cleanly
    $cleanCmdsPs1 = @(
        'uv run python app.py'
        'pwsh -NoProfile -File script.ps1'
        'Start-Process -FilePath "uv" -ArgumentList "run python app.py" -Wait'
    ) -join "`n"
    Set-Content (Join-Path $d 'clean_cmds.ps1') $cleanCmdsPs1
    $cleanCmdsJs = @(
        "const { execFile } = require('child_process');"
        "execFile('node', ['index.js']);"
    ) -join "`n"
    Set-Content (Join-Path $d 'clean_cmds.js') $cleanCmdsJs
    $r = Lint -Dir $d -Files 'clean_cmds.ps1,clean_cmds.js'
    Check 'clean commands: exit code 0' ($r.code -eq 0 -and $r.out -match 'Lint: 2 passed, 0 failed')

    # ---- 2. Unmonitored Process Spawns ----
    # 2a. PowerShell Start-Job and sjob
    $jobContent = @(
        'Start-Job -ScriptBlock { Get-Process }'
        'sjob { Get-Service }'
    ) -join "`n"
    Set-Content (Join-Path $d 'spawn_job.ps1') $jobContent
    $r = Lint -Dir $d -Files 'spawn_job.ps1'
    Check 'unmonitored Start-Job: exit code 1' ($r.code -eq 1)
    Check 'unmonitored Start-Job: flags line 1' ($r.out -match "spawn_job\.ps1:1 unmonitored background job spawn \('Start-Job' is forbidden\)")
    Check 'unmonitored sjob: flags line 2' ($r.out -match "spawn_job\.ps1:2 unmonitored background job spawn \('Start-Job' is forbidden\)")

    # 2a2. ways out of run-bounded's job object: scheduled tasks, Win32_Process Create, cmd /c start
    $escape = @(
        'schtasks /Create /TN x /TR "pwsh -File a.ps1" /SC DAILY'
        'Register-ScheduledTask -TaskName x -Action $a -Trigger $t'
        'Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "pwsh -File a.ps1" }'
        'cmd /c start /b pwsh -File helper.ps1'
        'cmd /c dir'
    ) -join "`n"
    Set-Content (Join-Path $d 'spawn_escape.ps1') $escape
    $r = Lint -Dir $d -Files 'spawn_escape.ps1'
    Check 'escape: schtasks flagged' ($r.out -match "spawn_escape\.ps1:1 scheduled task registration")
    Check 'escape: Register-ScheduledTask flagged' ($r.out -match "spawn_escape\.ps1:2 scheduled task registration")
    Check 'escape: Win32_Process Create flagged' ($r.out -match "spawn_escape\.ps1:3 unmonitored process spawn \(Win32_Process")
    Check 'escape: cmd /c start flagged' ($r.out -match "spawn_escape\.ps1:4 unmonitored process spawn \('cmd /c start'")
    Check 'escape: a plain cmd /c is fine' ($r.code -eq 1 -and $r.out -notmatch 'spawn_escape\.ps1:5 ')

    # 2b. PowerShell Start-Process without -Wait
    $sapsNoWaitContent = @(
        'Start-Process notepad.exe'
        'saps -FilePath "calc.exe"'
    ) -join "`n"
    Set-Content (Join-Path $d 'spawn_saps.ps1') $sapsNoWaitContent
    $r = Lint -Dir $d -Files 'spawn_saps.ps1'
    Check 'unmonitored Start-Process without -Wait: exit code 1' ($r.code -eq 1)
    Check 'unmonitored Start-Process: flags line 1' ($r.out -match "spawn_saps\.ps1:1 unmonitored background process spawn \('Start-Process' without -Wait is forbidden\)")
    Check 'unmonitored saps: flags line 2' ($r.out -match "spawn_saps\.ps1:2 unmonitored background process spawn \('Start-Process' without -Wait is forbidden\)")

    # 2c. PowerShell background pipeline operator '&'
    $bgPipeContent = 'Get-Process &'
    Set-Content (Join-Path $d 'spawn_bg.ps1') $bgPipeContent
    $r = Lint -Dir $d -Files 'spawn_bg.ps1'
    Check 'unmonitored background pipeline &: exit code 1' ($r.code -eq 1)
    Check 'unmonitored background pipeline &: flags line 1' ($r.out -match "spawn_bg\.ps1:1 unmonitored background pipeline operator '&' is forbidden")

    # 2d. [System.Diagnostics.Process]::Start
    $procContent = @(
        '[System.Diagnostics.Process]::Start("notepad.exe")'
        '[Diagnostics.Process]::Start("calc.exe")'
    ) -join "`n"
    Set-Content (Join-Path $d 'spawn_proc.ps1') $procContent
    $r = Lint -Dir $d -Files 'spawn_proc.ps1'
    Check 'unmonitored Process::Start: exit code 1' ($r.code -eq 1)
    Check 'unmonitored Process::Start: flags line 1' ($r.out -match "spawn_proc\.ps1:1 unmonitored process spawn \('\[Diagnostics\.Process\]::Start' is forbidden\)")
    Check 'unmonitored Process::Start: flags line 2' ($r.out -match "spawn_proc\.ps1:2 unmonitored process spawn \('\[Diagnostics\.Process\]::Start' is forbidden\)")

    # 2e. Node detached / unref
    $nodeSpawnContent = @(
        "const { spawn } = require('child_process');"
        "const child = spawn('node', ['worker.js'], { detached: true });"
        "child.unref();"
    ) -join "`n"
    Set-Content (Join-Path $d 'spawn_node.js') $nodeSpawnContent
    $r = Lint -Dir $d -Files 'spawn_node.js'
    Check 'unmonitored Node detached/unref: exit code 1' ($r.code -eq 1)
    Check 'unmonitored Node: flags line 2 detached' ($r.out -match "spawn_node\.js:2 unmonitored background process spawn \('detached: true' or 'unref\(\)' is forbidden\)")
    Check 'unmonitored Node: flags line 3 unref' ($r.out -match "spawn_node\.js:3 unmonitored background process spawn \('detached: true' or 'unref\(\)' is forbidden\)")

    # 2f. Clean process spawns pass cleanly
    $cleanSpawnPs1 = 'Start-Process notepad.exe -Wait'
    Set-Content (Join-Path $d 'clean_spawn.ps1') $cleanSpawnPs1
    $cleanSpawnJs = "const { execFile } = require('child_process'); execFile('node', ['app.js'], { timeout: 1000 });"
    Set-Content (Join-Path $d 'clean_spawn.js') $cleanSpawnJs
    $r = Lint -Dir $d -Files 'clean_spawn.ps1,clean_spawn.js'
    Check 'clean spawns: exit code 0' ($r.code -eq 0 -and $r.out -match 'Lint: 2 passed, 0 failed')

    # ---- 3. Secret-Token Shapes ----
    # 3a. Secrets in code
    $secCodeContent = @(
        "`$gh = `"$tokGh`""
        "`$oa = `"$tokOa`""
        "`$sl = `"$tokSlack`""
    ) -join "`n"
    Set-Content (Join-Path $d 'sec_code.ps1') $secCodeContent
    $r = Lint -Dir $d -Files 'sec_code.ps1'
    Check 'secret token in code: exit code 1' ($r.code -eq 1)
    Check 'secret token in code: flags github-token on line 1' ($r.out -match "sec_code\.ps1:1 introduces secret-shaped string \(github-token\); value not shown")
    Check 'secret token in code: flags openai-style-key on line 2' ($r.out -match "sec_code\.ps1:2 introduces secret-shaped string \(openai-style-key\); value not shown")
    Check 'secret token in code: flags slack-token on line 3' ($r.out -match "sec_code\.ps1:3 introduces secret-shaped string \(slack-token\); value not shown")
    Check 'secret token in code: never prints gh token value' ($r.out -notmatch [regex]::Escape($tokGh))
    Check 'secret token in code: never prints openai key value' ($r.out -notmatch [regex]::Escape($tokOa))
    Check 'secret token in code: never prints slack token value' ($r.out -notmatch [regex]::Escape($tokSlack))

    # 3b. Secrets in comments
    $secCommentContent = @(
        "# gh token for testing: $tokGh"
        "// openai key: $tokOa"
    ) -join "`n"
    Set-Content (Join-Path $d 'sec_comment.ps1') $secCommentContent
    $r = Lint -Dir $d -Files 'sec_comment.ps1'
    Check 'secret token in comment: exit code 1' ($r.code -eq 1)
    Check 'secret token in comment: flags line 1' ($r.out -match "sec_comment\.ps1:1 introduces secret-shaped string \(github-token\); value not shown")
    Check 'secret token in comment: flags line 2' ($r.out -match "sec_comment\.ps1:2 introduces secret-shaped string \(openai-style-key\); value not shown")
    Check 'secret token in comment: never prints gh token value' ($r.out -notmatch [regex]::Escape($tokGh))
    Check 'secret token in comment: never prints openai key value' ($r.out -notmatch [regex]::Escape($tokOa))

    # 3c. Secret assignment
    $secAssignContent = "const apiKey = `"$valSec`";`nlet password = `"$valPw`";"
    Set-Content (Join-Path $d 'sec_assign.js') $secAssignContent
    $r = Lint -Dir $d -Files 'sec_assign.js'
    Check 'secret assignment: exit code 1' ($r.code -eq 1)
    Check 'secret assignment: flags line 1' ($r.out -match "sec_assign\.js:1 introduces secret-shaped string \(secret-assignment\); value not shown")
    Check 'secret assignment: flags line 2' ($r.out -match "sec_assign\.js:2 introduces secret-shaped string \(secret-assignment\); value not shown")
    Check 'secret assignment: never prints secret value' ($r.out -notmatch [regex]::Escape($valSec) -and $r.out -notmatch [regex]::Escape($valPw))

    # 3d. Clean prose, env vars and placeholders pass cleanly
    $secCleanContent = @(
        '# Context window tokens: unlimited'
        '$api_key = "<your key here>"'
        '$password = $env:DB_PASSWORD'
        'export const maxTokens = 8000;'
    ) -join "`n"
    Set-Content (Join-Path $d 'sec_clean.ps1') $secCleanContent
    $r = Lint -Dir $d -Files 'sec_clean.ps1'
    Check 'prose and placeholders: exit code 0' ($r.code -eq 0 -and $r.out -match 'Lint: 1 passed, 0 failed')

    # ---- 4. Git diff verification mode ----
    $g = Join-Path $d 'repo'; New-Item -ItemType Directory -Force -Path (Join-Path $g '.kitchen') | Out-Null
    & git -C $g init -q 2>&1 | Out-Null
    Set-Content (Join-Path $g 'file.ps1') "Write-Host 'baseline'`n`$x = 10"
    & git -C $g add file.ps1 2>&1 | Out-Null
    & git -C $g -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    Set-Content (Join-Path $g '.kitchen\BASE') ((& git -C $g rev-parse HEAD).Trim())
    # Modify line 2 to introduce secret, line 1 unchanged
    Set-Content (Join-Path $g 'file.ps1') "Write-Host 'baseline'`n`$token = `"$tokGh`""
    & git -C $g add file.ps1 2>&1 | Out-Null
    & git -C $g -c user.name=t -c user.email=t@localhost commit -q -m "added token" 2>&1 | Out-Null
    $r = Lint -Dir $g
    Check 'git diff mode: flags introduced secret on line 2' ($r.code -eq 1 -and $r.out -match "file\.ps1:2 introduces secret-shaped string \(github-token\); value not shown")
    Check 'git diff mode: never prints secret value' ($r.out -notmatch [regex]::Escape($tokGh))

} finally {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "LintStation tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
