# Station: synthesize deterministic single-token mutants on changed lines in the git diff,
# execute the impacted test suite, and assert that at least one test fails (mutant killed).
# If any mutant survives, its location and description go to .kitchen\MUTANTS.txt for the taster (a weak test is a review finding).
#   step: {"station":"mutate","timeoutSec":1200,"maxMB":4000,"retries":0}
# -Soft: always exit 0 (survivors still go to MUTANTS.txt for the taster)
param(
    [string]$Dir = '',
    [string]$Base = '',
    [string]$Glob = 'tests\Test-*.ps1',
    [string]$Skip = '',
    [int]$SuiteTimeoutSec = 60,
    [int]$MaxMB = 2000,
    [int]$MaxMutants = 30,
    [int]$BudgetSec = 840,   # stop starting new mutants after this long: the step's own timeout must never kill it mid-mutant (the file would stay mutated)
    [switch]$Soft
)
$ErrorActionPreference = 'Stop'

$job = $env:KITCHEN_JOB
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
if (-not $Dir) {
    if ($job -match '^J\d+$') { $Dir = Join-Path $kroot "worktrees\$job" }
}
if (-not $Dir) { Write-Output 'mutate: no kitchen job and no -Dir'; exit 2 }
if (-not (Test-Path -LiteralPath $Dir)) { Write-Output "mutate: folder not found: $Dir"; exit 2 }
# an old MUTANTS.txt goes first, before any early exit: after a rework with no mutants left, the taster must not see last round's survivors
Remove-Item -LiteralPath (Join-Path $Dir '.kitchen\MUTANTS.txt') -Force -ErrorAction SilentlyContinue

if (-not $Base) {
    $bf = Join-Path $Dir '.kitchen\BASE'
    if (Test-Path -LiteralPath $bf) { $Base = (Get-Content -LiteralPath $bf -Raw).Trim() }
}
if (-not $Base) {
    $hasParent = & git -C $Dir rev-parse --verify HEAD~1 2>$null
    if ($LASTEXITCODE -eq 0 -and $hasParent) {
        $Base = 'HEAD~1'
    } else {
        $hasHead = & git -C $Dir rev-parse --verify HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $hasHead) {
            $Base = 'HEAD'
        }
    }
}

$bounded = Join-Path $PSScriptRoot '..\..\scripts\run-bounded.ps1'
if (-not (Test-Path -LiteralPath $bounded)) { $bounded = Join-Path $Dir 'scripts\run-bounded.ps1' }
# suites run contained like the tests station (rust/kitchen-sandbox/sandbox.ps1); asked for and not built: hold, never run uncontained
. (Join-Path $PSScriptRoot '..\..\rust\kitchen-sandbox\sandbox.ps1'); $sb = Get-KitchenSandbox (Join-Path $PSScriptRoot '..') $kroot
if ($sb.hold) { Write-Output "mutate: $($sb.hold)"; exit 10 }

$skipList = @($Skip -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# the same suites the tests station runs: -Glob when named, else the repo's kitchen.repo.json "tests" (read from the MAIN checkout, never
# this worktree: see repo-config.ps1), else tests\Test-*.ps1. A bad config stops here rather than judging mutants against other suites.
. (Join-Path $PSScriptRoot '..\repo-config.ps1')
try { $rc = Get-RepoConfig $Dir } catch { Write-Output "mutate: $($_.Exception.Message)"; exit 2 }
$patterns = if ($Glob -ne 'tests\Test-*.ps1') { @($Glob) } elseif ($rc.TestsGiven) { @($rc.Tests) } else { @($Glob) }
$allSuites = @((Resolve-RepoSuites $Dir $patterns).Suites | Where-Object { $_.Name -notin $skipList } | Sort-Object Name)
$suiteRels = @($allSuites | ForEach-Object { $_.Rel.ToLowerInvariant() })

# Diff gathering
function Get-GitLines([string[]]$GitArgs) {
    # stderr is dropped; a git failure yields no lines instead of stopping the station
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $r = & git -C $Dir @GitArgs 2>$null
        return @($r | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
    } finally { $ErrorActionPreference = $prev }
}
$diffLines = [Collections.Generic.List[string]]::new()
$specs = @('--', '.', ':(exclude).kitchen', ':(exclude)tests')
if ($Base -and $Base -ne 'HEAD') {
    foreach ($gl in (Get-GitLines (@('diff', '-U0', $Base, 'HEAD') + $specs))) { $diffLines.Add($gl) }
}
foreach ($gl in (Get-GitLines (@('diff', '-U0', 'HEAD') + $specs))) { $diffLines.Add($gl) }

# Track test suites modified in diff for impact resolution
$diffTestSuites = [Collections.Generic.List[string]]::new()
$allDiffFiles = [Collections.Generic.List[string]]::new()
if ($Base -and $Base -ne 'HEAD') {
    foreach ($gl in (Get-GitLines @('diff', '--name-only', $Base, 'HEAD'))) { $allDiffFiles.Add($gl) }
}
foreach ($gl in (Get-GitLines @('diff', '--name-only', 'HEAD'))) { $allDiffFiles.Add($gl) }
foreach ($f in $allDiffFiles) {
    $norm = $f.Trim() -replace '/', '\'
    # a changed suite: any file the configured test patterns name (brain-monitor: tests\Test-*.ps1; another repo may nest them deeper)
    if ($norm -match '^tests[\/\\]Test-.*\.ps1$' -or $norm.Replace('\', '/').ToLowerInvariant() -in $suiteRels) {
        $diffTestSuites.Add($norm)
    }
}

# Parse unified diff into modified lines per file
$fileLines = @{}
$currentFile = $null
$isCodeFile = $false

foreach ($line in $diffLines) {
    if ($line -match '^\+\+\+\s+b/(.*)$') {
        $rawPath = $Matches[1].Trim()
        $currentFile = $rawPath -replace '/', '\'
        if ($currentFile -notmatch '^(\.kitchen|tests)[\/\\]' -and $currentFile -match '\.(ps1|psm1|js|mjs|cjs)$') {
            $isCodeFile = $true
            if (-not $fileLines.ContainsKey($currentFile)) {
                $fileLines[$currentFile] = [Collections.Generic.HashSet[int]]::new()
            }
        } else {
            $isCodeFile = $false
        }
        continue
    }

    if ($isCodeFile -and $line -match '^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@') {
        $start = [int]$Matches[1]
        $count = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
        for ($i = 0; $i -lt $count; $i++) {
            $null = $fileLines[$currentFile].Add($start + $i)
        }
    }
}

# Operator replacement mappings
$psOpMap = [ordered]@{
    '-cnotcontains' = '-ccontains'
    '-ccontains'    = '-cnotcontains'
    '-notcontains'  = '-contains'
    '-contains'     = '-notcontains'
    '-cnotlike'     = '-clike'
    '-clike'        = '-cnotlike'
    '-notlike'      = '-like'
    '-like'         = '-notlike'
    '-cnotmatch'    = '-cmatch'
    '-cmatch'       = '-cnotmatch'
    '-notmatch'     = '-match'
    '-match'        = '-notmatch'
    '-cnotin'       = '-cin'
    '-cin'          = '-cnotin'
    '-notin'        = '-in'
    '-in'           = '-notin'
    '-ceq'          = '-cne'
    '-cne'          = '-ceq'
    '-cle'          = '-cgt'
    '-cgt'          = '-cle'
    '-cge'          = '-clt'
    '-clt'          = '-cge'
    '-eq'           = '-ne'
    '-ne'           = '-eq'
    '-le'           = '-gt'
    '-gt'           = '-le'
    '-ge'           = '-lt'
    '-lt'           = '-ge'
}
$psOpPattern = '(?<![\w-])-(cnotcontains|notcontains|ccontains|contains|cnotlike|notlike|clike|like|cnotmatch|notmatch|cmatch|match|cnotin|notin|cin|in|ceq|cne|cle|cgt|cge|clt|eq|ne|le|gt|ge|lt)\b'

$jsOpMap = [ordered]@{
    '===' = '!=='
    '!==' = '==='
    '=='  = '!='
    '!='  = '=='
    '<='  = '>'
    '>='  = '<'
}

# Synthesize deterministic candidate mutants
$allCandidates = [Collections.Generic.List[PSCustomObject]]::new()

foreach ($relPath in ($fileLines.Keys | Sort-Object)) {
    $fullPath = Join-Path $Dir $relPath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }

    $lines = [IO.File]::ReadAllLines($fullPath)
    $isPs = ($relPath -match '\.(ps1|psm1)$')
    $isJs = ($relPath -match '\.(js|mjs|cjs)$')

    foreach ($ln in ($fileLines[$relPath] | Sort-Object)) {
        if ($ln -lt 1 -or $ln -gt $lines.Length) { continue }
        $lineText = $lines[$ln - 1]
        $trimmed = $lineText.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#') -or $trimmed.StartsWith('//') -or $trimmed.StartsWith('/*') -or $trimmed.StartsWith('*')) {
            continue
        }

        # Analyze line for string and comment boundaries
        $len = $lineText.Length
        $inString = [bool[]]::new($len)
        $commentStart = $len
        $inSingle = $false
        $inDouble = $false
        $inTick = $false   # a JavaScript template literal (HTML lives here: '</b>' is not a comparison)

        for ($i = 0; $i -lt $len; $i++) {
            $c = $lineText[$i]
            if ($inSingle) {
                $inString[$i] = $true
                if ($c -eq "'") {
                    if ($isPs -and ($i + 1 -lt $len) -and $lineText[$i + 1] -eq "'") {
                        $i++; $inString[$i] = $true
                    } else {
                        $inSingle = $false
                    }
                }
            } elseif ($inTick) {
                $inString[$i] = $true
                if ($c -eq '\' -and ($i + 1 -lt $len)) { $i++; $inString[$i] = $true } elseif ($c -eq '`') { $inTick = $false }
            } elseif ($inDouble) {
                $inString[$i] = $true
                if ($c -eq '`' -and $isPs -and ($i + 1 -lt $len)) {
                    $i++; $inString[$i] = $true
                } elseif ($c -eq '\' -and $isJs -and ($i + 1 -lt $len)) {
                    $i++; $inString[$i] = $true
                } elseif ($c -eq '"') {
                    $inDouble = $false
                }
            } else {
                if ($c -eq "'") {
                    $inSingle = $true; $inString[$i] = $true
                } elseif ($c -eq '"') {
                    $inDouble = $true; $inString[$i] = $true
                } elseif ($isJs -and $c -eq '`') {
                    $inTick = $true; $inString[$i] = $true
                } elseif ($isPs -and $c -eq '#') {
                    $commentStart = $i; break
                } elseif ($isJs -and $c -eq '/' -and ($i + 1 -lt $len) -and ($lineText[$i + 1] -eq '/' -or $lineText[$i + 1] -eq '*')) {
                    $commentStart = $i; break
                }
            }
        }

        $lineMutants = [Collections.Generic.List[PSCustomObject]]::new()
        $addCandidate = {
            param($col, $tokLen, $oldTok, $newTok)
            if ($col -ge $commentStart -or $inString[$col]) { return }
            # Avoid duplicate mutants starting at same column
            foreach ($m in $lineMutants) { if ($m.Col -eq $col) { return } }
            $lineMutants.Add([PSCustomObject]@{
                File = $relPath
                Line = $ln
                Col  = $col
                Old  = $oldTok
                New  = $newTok
                Len  = $tokLen
            })
        }

        if ($isPs -or (-not $isJs)) {
            # PowerShell comparison operators
            foreach ($m in [regex]::Matches($lineText, $psOpPattern)) {
                $val = $m.Value.ToLowerInvariant()
                if ($psOpMap.Contains($val)) {
                    & $addCandidate $m.Index $m.Length $m.Value $psOpMap[$val]
                }
            }
            # PowerShell booleans
            foreach ($m in [regex]::Matches($lineText, '(?<![\w$])\$true\b')) {
                & $addCandidate $m.Index $m.Length '$true' '$false'
            }
            foreach ($m in [regex]::Matches($lineText, '(?<![\w$])\$false\b')) {
                & $addCandidate $m.Index $m.Length '$false' '$true'
            }
            # Truthy inversion
            foreach ($m in [regex]::Matches($lineText, '(?<![\w-])-not\s+')) {
                & $addCandidate $m.Index $m.Length $m.Value ' '
            }
            foreach ($m in [regex]::Matches($lineText, '(?<![\w$!])!(?![=!\s])')) {
                & $addCandidate $m.Index $m.Length $m.Value ' '
            }
        }

        if ($isJs) {
            # JavaScript comparison operators
            foreach ($m in [regex]::Matches($lineText, '(?<![=!])===|(?<![=!])!==|(?<![=!])==(?!=)|(?<![=!])!=(?!=)|<=|>=')) {
                if ($jsOpMap.Contains($m.Value)) {
                    & $addCandidate $m.Index $m.Length $m.Value $jsOpMap[$m.Value]
                }
            }
            foreach ($m in [regex]::Matches($lineText, '(?<=\s)<(?=\s)')) {
                & $addCandidate $m.Index $m.Length '<' '>='
            }
            foreach ($m in [regex]::Matches($lineText, '(?<=\s)>(?=\s)')) {
                & $addCandidate $m.Index $m.Length '>' '<='
            }
            # JavaScript booleans
            foreach ($m in [regex]::Matches($lineText, '(?<![\w$])\btrue\b')) {
                & $addCandidate $m.Index $m.Length 'true' 'false'
            }
            foreach ($m in [regex]::Matches($lineText, '(?<![\w$])\bfalse\b')) {
                & $addCandidate $m.Index $m.Length 'false' 'true'
            }
            # Truthy inversion
            foreach ($m in [regex]::Matches($lineText, '(?<![\w$!])!(?![=!\s])')) {
                & $addCandidate $m.Index $m.Length $m.Value ' '
            }
        }

        foreach ($cand in $lineMutants) {
            $allCandidates.Add($cand)
        }
    }
}

$candidates = @($allCandidates | Sort-Object File, Line, Col)
if ($candidates.Count -gt $MaxMutants) {
    $candidates = @($candidates | Select-Object -First $MaxMutants)
}

if ($candidates.Count -eq 0) {
    Write-Output 'mutate: 0 mutants generated (no eligible tokens on changed lines)'
    exit 0
}

function Get-ImpactedSuites([string]$targetRel, [string[]]$diffSuites, [IO.FileInfo[]]$availableSuites) {
    $matched = [Collections.Generic.List[IO.FileInfo]]::new()
    $baseName = [IO.Path]::GetFileNameWithoutExtension($targetRel)
    $fileName = [IO.Path]::GetFileName($targetRel)

    # 1. Test suites modified in the same diff
    foreach ($ds in $diffSuites) {
        $s = $availableSuites | Where-Object { $_.FullName -eq $ds -or $_.Rel -eq ($ds -replace '\\', '/') -or $_.Name -eq [IO.Path]::GetFileName($ds) } | Select-Object -First 1
        if ($s -and $s -notin $matched) { $matched.Add($s) }
    }

    # 2. Test suites named after the target
    $candidateNames = @(
        "Test-$baseName.ps1",
        "Test-${baseName}Station.ps1",
        "Test-Kitchen$baseName.ps1",
        "Test-Kitchen${baseName}Station.ps1"
    )
    foreach ($s in $availableSuites) {
        if ($candidateNames -contains $s.Name -and $s -notin $matched) {
            $matched.Add($s)
        }
    }

    # 3. Test suites referencing changed file name
    foreach ($s in $availableSuites) {
        if ($s -notin $matched) {
            try {
                $content = Get-Content -LiteralPath $s.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -and ($content -match [regex]::Escape($fileName) -or $content -match [regex]::Escape($targetRel))) {
                    $matched.Add($s)
                }
            } catch { }
        }
    }

    # 4. Fallback: all matching suites
    if ($matched.Count -eq 0) {
        return @($availableSuites | Sort-Object Name)
    }

    return @($matched | Sort-Object Name)
}

$survived = [Collections.Generic.List[PSCustomObject]]::new()
$killedCount = 0
$saved = @{ k = $env:BRAIN_KITCHEN; j = $env:KITCHEN_JOB; h = $env:KITCHEN_HEARTBEAT; r = $env:KITCHEN_RUN; a = $env:KITCHEN_APPROVED; s = $env:KITCHEN_AGENT_STEP; u = $env:KITCHEN_UNDER_TEST }

# crash safety: the file being mutated is named in .kitchen\MUTANT.txt until it is restored; a run that was killed mid-mutant
# leaves that note, and the next run restores the file from the job's last commit before doing anything else
$mutNote = Join-Path $Dir '.kitchen\MUTANT.txt'
if (Test-Path -LiteralPath $mutNote) { foreach ($mf in @(Get-Content -LiteralPath $mutNote | Where-Object { $_ })) { & git -C $Dir checkout -- $mf 2>&1 | Out-Null; Write-Output "mutate: restored $mf left mutated by an earlier run" }; Remove-Item -LiteralPath $mutNote -Force }
# each suite's time limit comes from how long it took in this job's own test run (TESTS.txt): twice that, at least -SuiteTimeoutSec,
# at most 600 s (a repo's kitchen.repo.json testTimeoutSec replaces that cap). A fixed 60 s cut the 80-130 s kitchen suites short, and a
# cut-short suite was counted as a killed mutant.
$suiteSec = @{}
$capSec = if ($rc.TestTimeoutSec) { $rc.TestTimeoutSec } else { 600 }
$tt = Join-Path $Dir '.kitchen\TESTS.txt'
if (Test-Path -LiteralPath $tt) { foreach ($tl in Get-Content -LiteralPath $tt) { if ($tl -match '^(PASS|FAIL)\s+(\S+)\s.*\((\d+(?:\.\d+)?)s\)\s*$') { $suiteSec[$Matches[2]] = [math]::Min($capSec, [math]::Max($SuiteTimeoutSec, [int][math]::Ceiling(2 * [double]$Matches[3]))) } } }
function Suite-Limit($suite) { if ($suiteSec.ContainsKey($suite.BaseName)) { $suiteSec[$suite.BaseName] } else { $SuiteTimeoutSec } }
# a mutant is only started when all its suites fit before the step's own limit (less 2 minutes to restore the file and report)
$hardSec = if ([int]$env:KITCHEN_TIMEOUT -gt 0) { [int]$env:KITCHEN_TIMEOUT - 120 } else { [int]::MaxValue }
$unjudged = [Collections.Generic.List[PSCustomObject]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew(); $tried = 0
foreach ($mutant in $candidates) {
    if ($clock.Elapsed.TotalSeconds -ge $BudgetSec) { Write-Output "mutate: time budget ($BudgetSec s) used; tried $tried of $($candidates.Count) mutants"; break }
    $suites = Get-ImpactedSuites -targetRel $mutant.File -diffSuites $diffTestSuites -availableSuites $allSuites
    $cost = 0; foreach ($su in $suites) { $cost += Suite-Limit $su }
    if ($clock.Elapsed.TotalSeconds + $cost -gt $hardSec) { continue }   # would not finish before the step is stopped (counted as not tried)
    $tried++
    $targetPath = Join-Path $Dir $mutant.File
    $originalBytes = [IO.File]::ReadAllBytes($targetPath)
    if (Test-Path -LiteralPath (Split-Path $mutNote)) { Set-Content -LiteralPath $mutNote -Value $mutant.File -Encoding utf8 }
    try {
        $lines = [IO.File]::ReadAllLines($targetPath)
        $lineText = $lines[$mutant.Line - 1]
        $newLineText = $lineText.Substring(0, $mutant.Col) + $mutant.New + $lineText.Substring($mutant.Col + $mutant.Len)
        $lines[$mutant.Line - 1] = $newLineText
        [IO.File]::WriteAllLines($targetPath, $lines)

        $isKilled = $false; $cutShort = $false

        foreach ($suite in $suites) {
            if ($env:KITCHEN_HEARTBEAT) { for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::WriteAllText($env:KITCHEN_HEARTBEAT, "$(Get-Date -Format o) quiet=$((Suite-Limit $suite) + 120)"); break } catch [IO.IOException] { Start-Sleep -Milliseconds 50 } } }   # silent up to the suite's own limit
            # a fresh empty kitchen per suite run, never a blank BRAIN_KITCHEN (blank falls back to Jordan's live kitchen); see tests.ps1
            $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('kt-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
            $env:BRAIN_KITCHEN = $sandbox; $env:KITCHEN_UNDER_TEST = '1'; $env:KITCHEN_JOB = $null; $env:KITCHEN_HEARTBEAT = $null; $env:KITCHEN_RUN = $null; $env:KITCHEN_APPROVED = $null; $env:KITCHEN_AGENT_STEP = $null
            Push-Location -LiteralPath $Dir
            $code = 1; $out = ''
            try {
                if ($sb.mode -ne 'off') { $out = Invoke-KitchenSuite $sb $suite.FullName $Dir $sandbox (Suite-Limit $suite) $MaxMB $bounded (@($allDiffFiles) + @($mutant.File)); $code = $LASTEXITCODE }   # every file the job changed decides Low vs Medium
                elseif (Test-Path -LiteralPath $bounded) {
                    $out = & pwsh -NoProfile -File $bounded -Script $suite.FullName -TimeoutSeconds (Suite-Limit $suite) -MaxMB $MaxMB 2>&1 | Out-String
                    $code = $LASTEXITCODE
                } else {
                    $out = & pwsh -NoProfile -File $suite.FullName 2>&1 | Out-String
                    $code = $LASTEXITCODE
                }
            }
            catch {
                $out = "FAIL: $_"
                $code = 1
            }
            finally {
                Pop-Location
                $env:BRAIN_KITCHEN = $saved.k; $env:KITCHEN_JOB = $saved.j; $env:KITCHEN_HEARTBEAT = $saved.h; $env:KITCHEN_RUN = $saved.r; $env:KITCHEN_APPROVED = $saved.a; $env:KITCHEN_AGENT_STEP = $saved.s; $env:KITCHEN_UNDER_TEST = $saved.u
                Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($null -eq $code) { $code = 1 }

            # run-bounded's 124 (timeout) / 125 (memory cap) say nothing about the mutant: the next suite may still kill it
            if ($code -in 124, 125) { $cutShort = $true; continue }
            if ($code -ne 0 -or $out -match '(?m)^\s*FAIL\b') {
                $isKilled = $true
                break
            }
        }

        if ($isKilled) {
            $killedCount++
        } elseif ($cutShort) {
            $unjudged.Add($mutant)
        } else {
            $survived.Add($mutant)
        }
    }
    finally {
        [IO.File]::WriteAllBytes($targetPath, $originalBytes)
        Remove-Item -LiteralPath $mutNote -Force -ErrorAction SilentlyContinue
    }
}

$notes = @(); if ($unjudged.Count) { $notes += "$($unjudged.Count) not judged (a suite ran out of time)" }; if ($tried -lt $candidates.Count) { $notes += "$($candidates.Count - $tried) not tried in the time budget" }
$noteText = if ($notes.Count) { ', ' + ($notes -join ', ') } else { '' }
$unjudgedLines = @($unjudged | ForEach-Object { "      NOTE: $($_.File):$($_.Line) ($($_.Old.Trim()) -> $($_.New.Trim())) not judged: suite too slow" })
if ($survived.Count -eq 0) {
    Write-Output "mutate: ALL PASS ($killedCount/$tried mutants killed$noteText)"
    if ($unjudgedLines.Count -and (Test-Path -LiteralPath (Join-Path $Dir '.kitchen'))) { Set-Content -LiteralPath (Join-Path $Dir '.kitchen\MUTANTS.txt') -Value ($unjudgedLines -join "`n") -Encoding utf8 }
    exit 0
}

$reportLines = [Collections.Generic.List[string]]::new()
$header = "{0,-5} {1,-34} {2}" -f 'FAIL', 'Mutate', "$($survived.Count) mutants survived"
$reportLines.Add($header)
foreach ($s in $survived) {
    $oldDesc = $s.Old.Trim()
    $newDesc = $s.New.Trim()
    $reportLines.Add("      FAIL: $($s.File):$($s.Line) ($oldDesc -> $newDesc) survived (impacted test passed)")
}
foreach ($ul in $unjudgedLines) { $reportLines.Add($ul) }
$reportLines.Add('FAILED: Mutate')

$kdir = Join-Path $Dir '.kitchen'
if (Test-Path -LiteralPath $kdir) {
    # survivors go to MUTANTS.txt for the taster (who can send the change back for stronger tests), not into TESTS.txt:
    # a weak test is a review finding, and TESTS.txt must keep saying what the test suites said
    $testsTxt = Join-Path $kdir 'MUTANTS.txt'
    $reportBlock = ($reportLines -join "`n")
    Set-Content -LiteralPath $testsTxt -Value $reportBlock -Encoding utf8
}

foreach ($l in $reportLines) {
    Write-Output "mutate: $l"
}

exit ([int]($survived.Count -gt 0 -and -not $Soft))
