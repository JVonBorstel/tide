# Free checks (no AI, no tokens): every file this job changed is parsed before any test runs, and the traps that set changes aside
# before are caught by name. The tests station runs this first as the "Lint" suite, so the repair cook sees these failures too.
#   PowerShell: parse errors; assigning to a [switch] parameter under another case ($json vs -Json, J21); "$name?" in a string,
#               which PowerShell reads as a variable named 'name?' (J21's URLs).
#   JavaScript: node --check.   JSON: must parse.
# Prints "FAIL: <file>:<line> <what>" per problem and "Lint: N passed, M failed". Exit 0 clean, 1 problems, 2 bad input.
param([Parameter(Mandatory)][string]$Dir, [string]$Base = '', [string[]]$Files = @())
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Dir)) { Write-Output "lint: folder not found: $Dir"; exit 2 }
$secScript = Join-Path $PSScriptRoot '..\..\scripts\secret-patterns.ps1'
if (-not (Test-Path -LiteralPath $secScript)) { $secScript = Join-Path $Dir 'scripts\secret-patterns.ps1' }
if (Test-Path -LiteralPath $secScript) { . (Resolve-Path -LiteralPath $secScript).Path }
if (-not ($Files | Where-Object { $_ }).Count) {
    if (-not $Base) { $bf = Join-Path $Dir '.kitchen\BASE'; if (Test-Path -LiteralPath $bf) { $Base = (Get-Content -LiteralPath $bf -Raw).Trim() } }
    if (-not $Base) { Write-Output 'Lint: 0 passed, 0 failed (no base commit, nothing to compare)'; exit 0 }
    $Files = @(& git -C $Dir diff --name-only --diff-filter=ACMR $Base HEAD -- . ':(exclude).kitchen' 2>$null) + @(& git -C $Dir diff --name-only --diff-filter=ACMR -- . ':(exclude).kitchen' 2>$null)
}
$Files = @($Files | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
$fails = [Collections.Generic.List[string]]::new(); $ok = 0
# a new file with no extension at the top of the repo is almost always a stray artifact (J28 committed one named "C")
if ($Base) {
    foreach ($nf in @(& git -C $Dir diff --name-only --diff-filter=A $Base HEAD -- . ':(exclude).kitchen' 2>$null)) {
        if ($nf -and $nf -notmatch '[/\\]' -and $nf -notmatch '\.' -and $nf -notin 'LICENSE', 'Makefile', 'Dockerfile') { $fails.Add("FAIL: $nf is a new file with no extension at the top of the repository (a stray artifact?); remove it") }
    }
}
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
# house rules (bare python, unmonitored spawns) judge only the lines this change adds: code already on main was approved as it is
function Pol([int]$n, [string]$msg) { if ($null -eq $script:added -or $script:added.Contains($n)) { $fails.Add($msg) } }
function Added-Lines([string]$rel) {
    if (-not $Base) { return $null }
    if ((& git -C $Dir status --porcelain -- $rel 2>$null) -match '^\?\?') { return $null }
    $set = [Collections.Generic.HashSet[int]]::new(); $cur = 0
    foreach ($d in @(& git -C $Dir diff -U0 $Base -- $rel 2>$null)) {
        if ($d -match '^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@') { $cur = [int]$Matches[1] }
        elseif ($d.StartsWith('+') -and -not $d.StartsWith('+++')) { [void]$set.Add($cur); $cur++ }
    }
    , $set   # the comma keeps an empty or one-line set a set
}
foreach ($rel in $Files) {
    $p = Join-Path $Dir $rel; if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
    $before = $fails.Count; $script:added = Added-Lines $rel
    switch -Regex ($rel) {
        '\.(ps1|psm1)$' {
            $tokens = $null; $errs = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errs)
            foreach ($e in $errs) { $fails.Add("FAIL: ${rel}:$($e.Extent.StartLineNumber) does not parse: $($e.Message)") }
            if ($errs.Count) { break }
            # every param block in the file (script and functions): switch names, compared without case
            foreach ($pb in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.ParamBlockAst] }, $true)) {
                $sw = @{}; foreach ($pp in $pb.Parameters) { if ($pp.StaticType -eq [switch] -or $pp.StaticType -eq [Management.Automation.SwitchParameter]) { $sw[$pp.Name.VariablePath.UserPath.ToLowerInvariant()] = $pp.Name.VariablePath.UserPath } }
                if (-not $sw.Count) { continue }
                $scope = $pb.Parent
                foreach ($as in $scope.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                    $l = $as.Left; if ($l -is [Management.Automation.Language.ConvertExpressionAst]) { $l = $l.Child }
                    if ($l -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
                    $nm = $l.VariablePath.UserPath
                    if ($sw.ContainsKey($nm.ToLowerInvariant()) -and $nm -cne $sw[$nm.ToLowerInvariant()]) {
                        $fails.Add("FAIL: ${rel}:$($as.Extent.StartLineNumber) `$$nm is the same variable as the -$($sw[$nm.ToLowerInvariant()]) switch (PowerShell ignores case); rename it")
                    }
                }
            }
            # "-and" / "-or" written as a command's argument (Test-Path $p -PathType Leaf -and ...) is read as a parameter named 'and' (J28)
            foreach ($cp in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -in 'and', 'or', 'not', 'xor', 'band', 'bor' }, $true)) {
                $fails.Add("FAIL: ${rel}:$($cp.Extent.StartLineNumber) '-$($cp.ParameterName)' sits inside a command's arguments, so PowerShell reads it as a parameter; wrap the command in parentheses: (Test-Path ...) -$($cp.ParameterName) ...")
            }
            foreach ($v in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and $n.Parent -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
                if ($v.VariablePath.UserPath -match '\?' -and $v.Extent.Text -notmatch '^\$\{') { $fails.Add("FAIL: ${rel}:$($v.Extent.StartLineNumber) `"$($v.Extent.Text)`" in a string reads a variable named '$($v.VariablePath.UserPath)'; write `${$(($v.VariablePath.UserPath -split '\?')[0])}?...") }
            }
            # bare python / python3 commands (AGENTS.md rule) and unmonitored background process spawns
            foreach ($cmd in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
                $cname = $cmd.GetCommandName()
                if ($cname -and $cname -match '^(?i)(python|python3)(\.exe)?$') {
                    Pol $cmd.Extent.StartLineNumber ("FAIL: ${rel}:$($cmd.Extent.StartLineNumber) bare python/python3 invocation is forbidden (AGENTS.md rule); use uv run or a bounded script")
                }
                elseif ($cname -and $cname -match '^(?i)(Start-Process|saps|start)$') {
                    $target = $null
                    $prevParam = $null
                    for ($i = 1; $i -lt $cmd.CommandElements.Count; $i++) {
                        $el = $cmd.CommandElements[$i]
                        if ($el -is [Management.Automation.Language.CommandParameterAst]) {
                            $prevParam = $el.ParameterName
                            if ($el.Argument) {
                                if ($el.ParameterName -match '^(?i)File(Path)?$') {
                                    $target = $el.Argument.Extent.Text.Trim("'`"")
                                    break
                                }
                                $prevParam = $null
                            }
                        } else {
                            if ($prevParam -and $prevParam -match '^(?i)File(Path)?$') {
                                $target = $el.Extent.Text.Trim("'`"")
                                break
                            } elseif (-not $prevParam -or $prevParam -in 'Wait', 'NoNewWindow', 'PassThru') {
                                $target = $el.Extent.Text.Trim("'`"")
                                break
                            }
                            $prevParam = $null
                        }
                    }
                    if ($target -and $target -match '^(?i)(python|python3)(\.exe)?$') {
                        Pol $cmd.Extent.StartLineNumber ("FAIL: ${rel}:$($cmd.Extent.StartLineNumber) bare python/python3 invocation is forbidden (AGENTS.md rule); use uv run or a bounded script")
                    }
                }
                if ($cname -and $cname -match '^(?i)(Start-Job|sjob)$') {
                    Pol $cmd.Extent.StartLineNumber ("FAIL: ${rel}:$($cmd.Extent.StartLineNumber) unmonitored background job spawn ('Start-Job' is forbidden); use run-bounded.ps1 or run-registry.ps1")
                }
                # other ways out of run-bounded's job object: a scheduled task (also a standing change Jordan never said yes to), a WMI/CIM
                # Win32_Process Create (the new process is the WMI service's child) and cmd's 'start' (detached on purpose)
                if ($cname -and $cname -match '^(?i)(schtasks(\.exe)?|Register-ScheduledTask|Register-ScheduledJob)$') {
                    Pol $cmd.Extent.StartLineNumber ("FAIL: ${rel}:$($cmd.Extent.StartLineNumber) scheduled task registration ('$cname') is forbidden; a scheduled task needs Jordan's yes")
                }
                if ($cname -and $cname -match '^(?i)(Invoke-CimMethod|Invoke-WmiMethod|icim|iwmi)$' -and $cmd.Extent.Text -match '(?i)Win32_Process') {
                    Pol $cmd.Extent.StartLineNumber ("FAIL: ${rel}:$($cmd.Extent.StartLineNumber) unmonitored process spawn (Win32_Process Create is forbidden); use run-bounded.ps1")
                }
                if ($cname -and $cname -match '^(?i)cmd(\.exe)?$' -and $cmd.Extent.Text -match '(?i)/c\s+"?start\b') {
                    Pol $cmd.Extent.StartLineNumber ("FAIL: ${rel}:$($cmd.Extent.StartLineNumber) unmonitored process spawn ('cmd /c start' is forbidden); use run-bounded.ps1")
                }
                if ($cname -and $cname -match '^(?i)(Start-Process|saps)$') {
                    $hasWait = $false
                    foreach ($el in $cmd.CommandElements) {
                        if ($el -is [Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -match '^(?i)w(ait)?$') {
                            if ($el.Argument -and $el.Argument.Extent.Text -match '^(?i)\$?false$') { } else { $hasWait = $true }
                        }
                    }
                    if (-not $hasWait) {
                        Pol $cmd.Extent.StartLineNumber ("FAIL: ${rel}:$($cmd.Extent.StartLineNumber) unmonitored background process spawn ('Start-Process' without -Wait is forbidden)")
                    }
                }
            }
            # unmonitored background pipeline operator '&'
            foreach ($pipe in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.PipelineAst] -and $n.Background }, $true)) {
                Pol $pipe.Extent.StartLineNumber ("FAIL: ${rel}:$($pipe.Extent.StartLineNumber) unmonitored background pipeline operator '&' is forbidden")
            }
            # [System.Diagnostics.Process]::Start
            foreach ($ime in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
                $mem = if ($ime.Member -is [Management.Automation.Language.StringConstantExpressionAst]) { $ime.Member.Value } else { $ime.Member.Extent.Text }
                if ($mem -match '^(?i)Start$') {
                    if ($ime.Expression -is [Management.Automation.Language.TypeExpressionAst]) {
                        $tname = $ime.Expression.TypeName.FullName
                        if ($tname -match '^(?i)(System\.)?(Diagnostics\.)?Process$' -or $ime.Expression.Extent.Text -match '(?i)Process') {
                            Pol $ime.Extent.StartLineNumber ("FAIL: ${rel}:$($ime.Extent.StartLineNumber) unmonitored process spawn ('[Diagnostics.Process]::Start' is forbidden); use run-bounded.ps1")
                        }
                    }
                }
            }
        }
        '\.(js|mjs|cjs)$' {
            if ($node) { $o = & $node --check $p 2>&1 | Out-String; if ($LASTEXITCODE) { $fails.Add("FAIL: ${rel} does not parse: $((($o -split "`r?`n") | Where-Object { $_ -match 'Error' } | Select-Object -First 1))") } }
            $lines = @(Get-Content -LiteralPath $p)
            for ($lineNum = 1; $lineNum -le $lines.Count; $lineNum++) {
                $line = $lines[$lineNum - 1]
                if ($line -match '\b(exec|execSync|spawn|spawnSync|execFile|execFileSync|fork)\s*\(\s*[''"`](?:python|python3)(?:\.exe)?\b') {
                    Pol $lineNum ("FAIL: ${rel}:${lineNum} bare python/python3 invocation is forbidden (AGENTS.md rule); use uv run or a bounded script")
                }
                if ($line -match '\bdetached\s*:\s*true\b|\.unref\s*\(\s*\)') {
                    Pol $lineNum ("FAIL: ${rel}:${lineNum} unmonitored background process spawn ('detached: true' or 'unref()' is forbidden)")
                }
            }
        }
        '\.json$' {
            try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -Depth 64 | Out-Null } catch { $fails.Add("FAIL: ${rel} is not valid JSON: $($_.Exception.Message)") }
        }
    }
    # secret pattern diff verification (code and comments)
    if (Get-Command Find-SecretPattern -ErrorAction SilentlyContinue) {
        $linesToCheck = [Collections.Generic.List[hashtable]]::new()
        $isGit = $false
        if ($Base) {
            $isGit = (& git -C $Dir rev-parse --is-inside-work-tree 2>$null) -eq 'true'
        }
        if ($isGit) {
            $diffLines = @(& git -C $Dir diff -U0 $Base -- $rel 2>$null)
            if ($diffLines.Count -gt 0) {
                $curLine = 0
                $inHunk = $false
                foreach ($dline in $diffLines) {
                    if ($dline -match '^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@') {
                        $curLine = [int]$Matches[1]
                        $inHunk = $true
                    }
                    elseif ($inHunk -and $dline.StartsWith('+') -and -not $dline.StartsWith('+++')) {
                        $linesToCheck.Add(@{ LineNum = $curLine; Text = $dline.Substring(1) })
                        $curLine++
                    }
                }
            } elseif ((& git -C $Dir status --porcelain -- $rel 2>$null) -match '^\?\?') {
                $allLines = @(Get-Content -LiteralPath $p)
                for ($idx = 0; $idx -lt $allLines.Count; $idx++) {
                    $linesToCheck.Add(@{ LineNum = $idx + 1; Text = $allLines[$idx] })
                }
            }
        } else {
            $allLines = @(Get-Content -LiteralPath $p)
            for ($idx = 0; $idx -lt $allLines.Count; $idx++) {
                $linesToCheck.Add(@{ LineNum = $idx + 1; Text = $allLines[$idx] })
            }
        }
        foreach ($item in $linesToCheck) {
            $txt = $item.Text
            if ($txt -and $txt.Length -le 2000) {
                $hit = Find-SecretPattern $txt
                if ($hit) {
                    $fails.Add("FAIL: ${rel}:$($item.LineNum) introduces secret-shaped string ($hit); value not shown")
                }
            }
        }
    }
    if ($fails.Count -eq $before) { $ok++ }
}
$fails | ForEach-Object { Write-Output $_ }
Write-Output "Lint: $ok passed, $($fails.Count) failed"
exit ([int]($fails.Count -gt 0))
