# Tests for repository map exemplar extraction (kitchen/stations/map.ps1) and evolutionary exemplar archive in kitchen/kitchen.ps1.
# Asserts EXEMPLARS.md is created and properly formatted when exemplars.jsonl exists, ranks by relevance, handles missing files,
# and verifies supervisor merge exemplar recording and the 30-entry retention window. Self-cleaning.
$ErrorActionPreference = 'Stop'
$mapStation = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\map.ps1')).Path
$kitchenPs = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\kitchen.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-map-' + [guid]::NewGuid().ToString('N'))
$saveEnv = @{
    BRAIN_KITCHEN = $env:BRAIN_KITCHEN
    KITCHEN_JOB = $env:KITCHEN_JOB
    KITCHEN_GOAL = $env:KITCHEN_GOAL
    KITCHEN_AGY_EXE = $env:KITCHEN_AGY_EXE
}

$script:pass = 0; $script:fail = 0
function Check([string]$n, [bool]$c) {
    if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" }
}

try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $env:BRAIN_KITCHEN = $root
    $env:KITCHEN_AGY_EXE = 'off'
    $env:KITCHEN_JOB = $null
    $env:KITCHEN_GOAL = $null

    # 1. Exemplar extraction and file formatting
    $repo1 = Join-Path $root 'repo1'
    New-Item -ItemType Directory -Force -Path (Join-Path $repo1 'src'), (Join-Path $repo1 'tests'), (Join-Path $repo1 '.kitchen') | Out-Null
    & git -C $repo1 init -q 2>&1 | Out-Null
    Set-Content (Join-Path $repo1 'src\service.ps1') "function Start-Service { 'running' }"
    Set-Content (Join-Path $repo1 'tests\Test-Service.ps1') "Write-Output 'Service tests: 1 passed, 0 failed'; exit 0"
    & git -C $repo1 -c user.name=t -c user.email=t@t add -A 2>&1 | Out-Null
    & git -C $repo1 -c user.name=t -c user.email=t@t commit -q -m "initial commit" 2>&1 | Out-Null

    $synthExemplar = @{
        at = [DateTime]::UtcNow.ToString('o')
        job = 'J40'
        goal = 'add service health check endpoint'
        files = @('src/service.ps1', 'tests/Test-Service.ps1')
        testPattern = 'tests/Test-Service.ps1'
    }
    ($synthExemplar | ConvertTo-Json -Compress) | Set-Content (Join-Path $root 'exemplars.jsonl') -Encoding utf8

    $out1 = Join-Path $repo1 '.kitchen\MAP.md'
    $mapOut = & pwsh -NoProfile -File $mapStation -Dir $repo1 -Out $out1 2>&1 | Out-String
    $exPath1 = Join-Path $repo1 '.kitchen\EXEMPLARS.md'

    Check 'map station reports exemplars in stdout' ($mapOut -match '\b1 exemplars\b')
    Check 'EXEMPLARS.md is created alongside MAP.md' (Test-Path -LiteralPath $exPath1)
    $exText1 = if (Test-Path -LiteralPath $exPath1) { Get-Content -LiteralPath $exPath1 -Raw } else { '' }
    Check 'contains exemplars header' ($exText1 -match '^# Exemplars: proven patterns from successful improvements')
    Check 'properly formats goal and job' ($exText1 -match '- add service health check endpoint \(J40\)')
    Check 'properly formats files list' ($exText1 -match '  - Files: src/service\.ps1, tests/Test-Service\.ps1')
    Check 'properly formats test pattern' ($exText1 -match '  - Tests: tests/Test-Service\.ps1')

    # 2. Relevance selection (goal keyword matching and ranking)
    $exemplarsData = @(
        @{ at = [DateTime]::UtcNow.AddMinutes(-30).ToString('o'); job = 'J10'; goal = 'unrelated billing invoice export'; files = @('src/billing.ps1'); testPattern = 'tests/Test-Billing.ps1' },
        @{ at = [DateTime]::UtcNow.AddMinutes(-20).ToString('o'); job = 'J20'; goal = 'optimize database connection pool'; files = @('src/db.ps1'); testPattern = 'tests/Test-Db.ps1' },
        @{ at = [DateTime]::UtcNow.AddMinutes(-10).ToString('o'); job = 'J30'; goal = 'fix database retry loop on timeout'; files = @('src/db.ps1', 'tests/Test-Db.ps1'); testPattern = 'tests/Test-Db.ps1' }
    )
    $exLines = @($exemplarsData | ForEach-Object { $_ | ConvertTo-Json -Compress })
    Set-Content (Join-Path $root 'exemplars.jsonl') -Value ($exLines -join "`n") -Encoding utf8

    New-Item -ItemType Directory -Force -Path (Join-Path $root 'jobs') | Out-Null
    @{
        id = 'J50'
        name = 'improve: database retry timeout handling'
        vars = @{ goal = 'database retry timeout handling' }
        steps = @()
    } | ConvertTo-Json | Set-Content (Join-Path $root 'jobs\J50.json') -Encoding utf8

    $env:KITCHEN_JOB = 'J50'
    try {
        & pwsh -NoProfile -File $mapStation -Dir $repo1 -Out $out1 | Out-Null
    } finally {
        $env:KITCHEN_JOB = $null
    }

    $exText2 = Get-Content -LiteralPath $exPath1 -Raw
    $idxJ30 = $exText2.IndexOf('(J30)')
    $idxJ20 = $exText2.IndexOf('(J20)')
    $idxJ10 = $exText2.IndexOf('(J10)')
    Check 'most relevant exemplar (J30, matching database retry timeout) ranked first' ($idxJ30 -ge 0 -and $idxJ30 -lt $idxJ20)
    Check 'partially relevant exemplar (J20, matching database) ranked before unrelated (J10)' ($idxJ20 -ge 0 -and $idxJ20 -lt $idxJ10)

    # 3. Graceful handling when exemplars.jsonl does not exist
    Remove-Item -LiteralPath (Join-Path $root 'exemplars.jsonl') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $exPath1 -Force -ErrorAction SilentlyContinue
    $outMissing = $null; $threwMissing = $false
    try {
        $outMissing = & pwsh -NoProfile -File $mapStation -Dir $repo1 -Out $out1 2>&1 | Out-String
        $ecMissing = $LASTEXITCODE
    } catch {
        $threwMissing = $true
    }
    Check 'map.ps1 completes without error when exemplars.jsonl missing' (-not $threwMissing -and $ecMissing -eq 0)
    Check 'EXEMPLARS.md is not created when exemplars.jsonl does not exist' (-not (Test-Path -LiteralPath $exPath1))

    # 4. Supervisor merge recording & retention window (capped at 30 entries)
    # Populate exemplars.jsonl with 32 historical entries
    $historyEntries = [Collections.Generic.List[string]]::new()
    for ($i = 1; $i -le 32; $i++) {
        $e = @{
            at = [DateTime]::UtcNow.AddHours(- (40 - $i)).ToString('o')
            job = "J$i"
            goal = "historical improvement $i"
            files = @("file$i.txt")
            testPattern = "tests/Test-$i.ps1"
        }
        $historyEntries.Add(($e | ConvertTo-Json -Compress))
    }
    Set-Content (Join-Path $root 'exemplars.jsonl') -Value ($historyEntries -join "`n") -Encoding utf8

    # Set up a target repo with a merge commit
    $mergeRepo = Join-Path $root 'mergerepo'
    New-Item -ItemType Directory -Force -Path (Join-Path $mergeRepo 'src'), (Join-Path $mergeRepo 'tests') | Out-Null
    & git -C $mergeRepo init -q -b main 2>&1 | Out-Null
    Set-Content (Join-Path $mergeRepo 'src\calc.ps1') "function Add-Num { 1 }"
    & git -C $mergeRepo -c user.name=t -c user.email=t@t add -A 2>&1 | Out-Null
    & git -C $mergeRepo -c user.name=t -c user.email=t@t commit -q -m "initial main" 2>&1 | Out-Null

    & git -C $mergeRepo checkout -q -b feature 2>&1 | Out-Null
    Set-Content (Join-Path $mergeRepo 'src\calc.ps1') "function Add-Num { 2 }"
    Set-Content (Join-Path $mergeRepo 'tests\Test-Calc.ps1') "Write-Output 'Calc tests: 1 passed, 0 failed'; exit 0"
    & git -C $mergeRepo -c user.name=t -c user.email=t@t add -A 2>&1 | Out-Null
    & git -C $mergeRepo -c user.name=t -c user.email=t@t commit -q -m "feat: updated calc and added test" 2>&1 | Out-Null

    & git -C $mergeRepo checkout -q main 2>&1 | Out-Null
    & git -C $mergeRepo -c user.name=t -c user.email=t@t merge --no-ff -q -m "Merge feature branch" feature 2>&1 | Out-Null

    # Configure mock job J99 on the improve recipe: merged, and its verify just passed (only a verified merge becomes an exemplar)
    $mergeStation = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\stations\merge.ps1')).Path
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'jobs'), (Join-Path $root 'run') | Out-Null
    $base99 = Join-Path $root 'run\J99-s1-a0'
    Set-Content "$base99.exit" "0`n"
    Set-Content "$base99.log" "verify: ALL PASS on the repo`n"

    $job99 = @{
        id = 'J99'
        name = 'improve: support advanced calculation modes'
        recipe = 'improve'
        vars = @{ goal = 'support advanced calculation modes'; repo = $mergeRepo }
        status = 'running'
        cursor = 1
        attempt = 0
        depth = 0
        steps = @(
            @{ script = $mergeStation; args = @{ Repo = $mergeRepo } },
            @{ script = (Join-Path (Split-Path $mergeStation) 'verify.ps1'); args = @{ Repo = $mergeRepo } }
        )
        run = @{ pid = $PID; startMs = 0; base = $base99; startedAt = [DateTime]::UtcNow.ToString('o') }
    }
    $job99 | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'jobs\J99.json') -Encoding utf8

    # Run supervisor tick
    & pwsh -NoProfile -File $kitchenPs tick | Out-Null

    $recordedLines = @(Get-Content -LiteralPath (Join-Path $root 'exemplars.jsonl'))
    Check 'exemplars.jsonl capped at newest 30 entries' ($recordedLines.Count -eq 30)

    $lastRec = $recordedLines[-1] | ConvertFrom-Json
    Check 'new exemplar recorded with correct job id' ($lastRec.job -eq 'J99')
    Check 'new exemplar recorded with correct goal' ($lastRec.goal -eq 'support advanced calculation modes')
    Check 'new exemplar includes modified code and test files' (@($lastRec.files) -contains 'src/calc.ps1' -and @($lastRec.files) -contains 'tests/Test-Calc.ps1')
    Check 'new exemplar extracts test pattern from modified test file' ($lastRec.testPattern -match 'Test-Calc\.ps1')

    # Verify event emission
    $events = @(Get-Content (Join-Path $root 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $exEvent = $events | Where-Object { $_.type -eq 'exemplar.recorded' -and $_.job -eq 'J99' } | Select-Object -First 1
    Check 'supervisor emitted exemplar.recorded event' ($null -ne $exEvent -and $exEvent.files -ge 1)
} finally {
    foreach ($k in $saveEnv.Keys) { Set-Item "env:$k" $saveEnv[$k] }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "KitchenMap tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
