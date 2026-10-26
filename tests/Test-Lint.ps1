# Tests for the free checks (kitchen/stations/lint.ps1): broken PowerShell, JavaScript and JSON are caught, the traps that set
# J21 and J28 aside are caught by name, clean files pass, and with a base commit only the job's changed files are read. Self-cleaning.
$ErrorActionPreference = 'Stop'
$lint = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\lint.ps1')).Path
$d = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-lint-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Lint { $o = & pwsh -NoProfile -File $lint @args 2>&1 | Out-String; @{ out = $o; code = $LASTEXITCODE } }
try {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content (Join-Path $d 'switch.ps1') "param([switch]`$Json)`n`$json = Get-Content x.json | ConvertFrom-Json"
    Set-Content (Join-Path $d 'url.ps1') "`$id = 1`n`$u = `"https://h/jobs/`$id?questions=true`""
    Set-Content (Join-Path $d 'andarg.ps1') "`$p = 'a'`nif (Test-Path -LiteralPath `$p -PathType Leaf -and 1) { }"
    Set-Content (Join-Path $d 'broken.ps1') "`$x = `"no end"
    Set-Content (Join-Path $d 'broken.mjs') 'const a = ;'
    Set-Content (Join-Path $d 'broken.json') '{"a":'
    Set-Content (Join-Path $d 'clean.ps1') "param([switch]`$Json)`n`$id = 1`nif (`$Json) { `"https://h/`${id}?q=1`" }"
    Set-Content (Join-Path $d 'clean.mjs') 'export const a = 1;'
    Set-Content (Join-Path $d 'clean.json') '{"a":1}'
    $r = Lint -Dir $d -Files 'switch.ps1,url.ps1,broken.ps1,broken.mjs,broken.json'
    Check 'switch trap named ($json vs -Json)' ($r.out -match 'switch\.ps1:2 \$json is the same variable as the -Json switch')
    Check 'string trap named ("$id?" reads id?...)' ($r.out -match "url\.ps1:2 .*reads a variable named 'id\?questions'")
    $r2 = Lint -Dir $d -Files 'andarg.ps1'
    Check '-and inside a command''s arguments (J28)' ($r2.out -match "andarg\.ps1:2 '-and' sits inside a command's arguments")
    Check 'PowerShell parse error' ($r.out -match 'broken\.ps1:1 does not parse')
    Check 'JavaScript parse error' ($r.out -match 'broken\.mjs does not parse')
    Check 'bad JSON' ($r.out -match 'broken\.json is not valid JSON')
    Check 'problems -> exit 1 with a count' ($r.code -eq 1 -and $r.out -match 'Lint: 0 passed, 5 failed')
    $r = Lint -Dir $d -Files 'clean.ps1,clean.mjs,clean.json'
    Check 'clean files pass, exit 0' ($r.code -eq 0 -and $r.out -match 'Lint: 3 passed, 0 failed')
    # a job worktree: only files changed since the base commit are read
    $g = Join-Path $d 'repo'; New-Item -ItemType Directory -Force -Path (Join-Path $g '.kitchen') | Out-Null
    & git -C $g init -q 2>&1 | Out-Null
    Set-Content (Join-Path $g 'old.ps1') "`$x = `"left broken before this job"
    & git -C $g add old.ps1 2>&1 | Out-Null; & git -C $g -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    Set-Content (Join-Path $g '.kitchen\BASE') ((& git -C $g rev-parse HEAD).Trim())
    Set-Content (Join-Path $g 'new.mjs') 'const = 2;'
    & git -C $g add new.mjs 2>&1 | Out-Null; & git -C $g -c user.name=t -c user.email=t@localhost commit -q -m change 2>&1 | Out-Null
    Set-Content (Join-Path $g 'C') 'stray'
    & git -C $g add C 2>&1 | Out-Null; & git -C $g -c user.name=t -c user.email=t@localhost commit -q -m stray 2>&1 | Out-Null
    $r = Lint -Dir $g
    Check 'base mode: the changed file is checked, untouched old files are not' ($r.out -match 'new\.mjs does not parse' -and $r.out -notmatch 'old\.ps1' -and $r.code -eq 1)
    Check 'base mode: a new extension-less file at the top is flagged as stray (J28)' ($r.out -match 'FAIL: C is a new file with no extension')
    # house rules judge only the lines a job adds: a supervisor's existing Process.Start does not fail every later change to that file
    $g2 = Join-Path $d 'repo2'; New-Item -ItemType Directory -Force -Path (Join-Path $g2 '.kitchen') | Out-Null
    & git -C $g2 init -q 2>&1 | Out-Null
    Set-Content (Join-Path $g2 'sup.ps1') "`$p = [Diagnostics.Process]::Start('pwsh')`n`$a = 1"
    & git -C $g2 add sup.ps1 2>&1 | Out-Null; & git -C $g2 -c user.name=t -c user.email=t@localhost commit -q -m base 2>&1 | Out-Null
    Set-Content (Join-Path $g2 '.kitchen\BASE') ((& git -C $g2 rev-parse HEAD).Trim())
    Set-Content (Join-Path $g2 'sup.ps1') "`$p = [Diagnostics.Process]::Start('pwsh')`n`$a = 2"
    $r = Lint -Dir $g2
    Check 'house rules: an existing spawn on an untouched line is not flagged' ($r.code -eq 0)
    Set-Content (Join-Path $g2 'sup.ps1') "`$p = [Diagnostics.Process]::Start('pwsh')`n`$a = 2`n`$q = [Diagnostics.Process]::Start('cmd')"
    $r = Lint -Dir $g2
    Check 'house rules: a newly added spawn is flagged on its line' ($r.code -eq 1 -and $r.out -match 'sup\.ps1:3 unmonitored process spawn' -and $r.out -notmatch 'sup\.ps1:1 ')
} finally {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Lint tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
