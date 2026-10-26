# Tests for cache-friendly prompt assembly in kitchen/agent-step.ps1 and kitchen/recipes/improve.json (Idea I77).
# Verifies prompt prefix stability across varying goals, context placement before dynamic variables,
# explicit/implicit goal handling, and backwards compatibility. Self-cleaning.
$ErrorActionPreference = 'Stop'
$kd = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen')).Path
$agentStep = Join-Path $kd 'agent-step.ps1'
$improveJson = Join-Path $kd 'recipes\improve.json'

$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-cooks-' + [guid]::NewGuid().ToString('N'))
$fk = Join-Path $root 'fake-cli'
$wt = Join-Path $root 'worktree'

$saveEnv = @{}
foreach ($n in 'BRAIN_KITCHEN', 'KITCHEN_CLAUDE_EXE', 'KITCHEN_AGY_EXE', 'KITCHEN_OLLAMA_URL', 'KITCHEN_LIVE', 'KITCHEN_JOB', 'KITCHEN_RECIPES', 'KITCHEN_RUN') {
    $saveEnv[$n] = [Environment]::GetEnvironmentVariable($n)
}

$script:pass = 0; $script:fail = 0
function Check($n, $c) {
    if ($c) {
        $script:pass++
    } else {
        $script:fail++
        Write-Host "FAIL: $n"
    }
}

try {
    New-Item -ItemType Directory -Force -Path $root, $fk, $wt | Out-Null
    $env:BRAIN_KITCHEN = $root
    $env:KITCHEN_LIVE = '1'
    $env:KITCHEN_JOB = 'J99'
    $env:KITCHEN_AGY_EXE = 'off'
    $env:KITCHEN_OLLAMA_URL = 'off'

    # Setup fake Claude CLI adapter that records the exact prompt received
    $capturedPromptFile = Join-Path $fk 'captured-prompt.txt'
    Set-Content (Join-Path $fk 'claude.ps1') @'
$in = @($input) -join "`n"
if ($args[0] -eq 'auth') {
    @{ loggedIn = $true; authMethod = 'claude.ai'; apiProvider = 'firstParty' } | ConvertTo-Json -Compress
    exit 0
}
$p = if ($in) {
    $in
} else {
    $pIdx = [array]::IndexOf($args, '-p')
    if ($pIdx -ge 0 -and $pIdx + 1 -lt $args.Count) { $args[$pIdx + 1] } else { '' }
}
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'captured-prompt.txt') -Value $p -Encoding utf8
@{
    type = 'result'
    is_error = $false
    result = 'PLAN READY VERDICT: SHIP'
    total_cost_usd = 0.05
    num_turns = 1
    usage = @{ input_tokens = 500; output_tokens = 50; cache_read_input_tokens = 450; cache_creation_input_tokens = 10 }
} | ConvertTo-Json -Compress
exit 0
'@
    $env:KITCHEN_CLAUDE_EXE = Join-Path $fk 'claude.ps1'

    # Create realistic reference files in worktree for context testing
    $mapContent = "# Repository Map`n" + ((1..60 | ForEach-Object { "kitchen/module$_.ps1 ($_0) - Functionality for module $_. Functions: Get-Mod$_, Set-Mod$_" }) -join "`n")
    $lessonsContent = "# Lessons: failures earlier changes had to repair`n" + ((1..25 | ForEach-Object { "- FAIL: module $_ crashed on edge case (J$_)" }) -join "`n")
    Set-Content -LiteralPath (Join-Path $wt 'MAP.md') -Value $mapContent -Encoding utf8
    Set-Content -LiteralPath (Join-Path $wt 'LESSONS.md') -Value $lessonsContent -Encoding utf8

    # agent-step puts the Creed (kitchen/CREED.md) in front of every prompt; "at the front" below means right after it
    $creedText = ((Get-Content -LiteralPath (Join-Path $kd 'CREED.md') -Raw) -replace "`r`n", "`n").Trim()
    function Strip-Creed([string]$p) {
        $n = $p -replace "`r`n", "`n"
        if ($n.TrimStart().StartsWith($creedText)) { $n.TrimStart().Substring($creedText.Length).TrimStart() } else { $n }
    }

    # Helper function to run agent-step.ps1 in an isolated process and return captured prompt
    function Invoke-AgentStep([hashtable]$params) {
        if (Test-Path -LiteralPath $capturedPromptFile) { Remove-Item -LiteralPath $capturedPromptFile -Force }
        # always the fake claude cook: a test must never wake a real cook (slow, and it would spend Jordan's plan)
        if (-not $params.ContainsKey('Supplier')) { $params.Supplier = 'claude' }
        # these prompts are kitchen-written (-Public, passed bare): with the local judge off, a non-public tool order holds (fail closed)
        if (-not $params.ContainsKey('Public')) { $params.Public = '' }
        $cmdArgs = @('-NoProfile', '-File', $agentStep)
        foreach ($k in $params.Keys) {
            $cmdArgs += "-$k"
            if ($null -ne $params[$k] -and "$($params[$k])" -ne '') {
                $cmdArgs += "$($params[$k])"
            }
        }
        $out = & pwsh @cmdArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
        $captured = if (Test-Path -LiteralPath $capturedPromptFile) { Get-Content -LiteralPath $capturedPromptFile -Raw -Encoding utf8 } else { '' }
        return @{ ExitCode = $code; Output = $out; Prompt = $captured }
    }

    # =========================================================================
    # 1. Recipe Layout Check: improve.json
    # =========================================================================
    Check 'improve.json exists' (Test-Path -LiteralPath $improveJson)
    $recipe = Get-Content -LiteralPath $improveJson -Raw | ConvertFrom-Json
    $steps = @($recipe.steps)

    $planStep = $steps | Where-Object { $_.station -eq 'agent' -and $_.args.Role -eq 'plan' } | Select-Object -First 1
    $doStep = $steps | Where-Object { $_.station -eq 'agent' -and $_.args.Role -eq 'do' } | Select-Object -First 1
    $checkStep = $steps | Where-Object { $_.station -eq 'agent' -and $_.args.Role -eq 'check' } | Select-Object -First 1

    Check 'plan step found in improve.json' ($null -ne $planStep)
    Check 'do step found in improve.json' ($null -ne $doStep)
    Check 'check step found in improve.json' ($null -ne $checkStep)

    # Check plan step layout
    $planPrompt = [string]$planStep.args.Prompt
    $planFirstPara = ($planPrompt -split "(\r?\n){2,}")[0]
    Check 'plan step: opening paragraph has no {{goal}}' ($planFirstPara -notmatch '\{\{goal\}\}')
    Check 'plan step: ends strictly with Goal: {{goal}}' ($planPrompt.TrimEnd() -match '(?ms)Goal:\s*\{\{goal\}\}$')
    Check 'plan step: mentions lint.ps1' ($planPrompt -match 'lint\.ps1')

    # Check do step layout
    $doPrompt = [string]$doStep.args.Prompt
    $doFirstPara = ($doPrompt -split "(\r?\n){2,}")[0]
    Check 'do step: opening paragraph has no {{goal}}' ($doFirstPara -notmatch '\{\{goal\}\}')
    Check 'do step: ends strictly with Goal: {{goal}}' ($doPrompt.TrimEnd() -match '(?ms)Goal:\s*\{\{goal\}\}$')
    Check 'do step: mentions lint.ps1' ($doPrompt -match 'lint\.ps1')

    # Check check step layout
    $checkPrompt = [string]$checkStep.args.Prompt
    $checkFirstPara = ($checkPrompt -split "(\r?\n){2,}")[0]
    Check 'check step: opening paragraph has no {{goal}}' ($checkFirstPara -notmatch '\{\{goal\}\}')
    Check 'check step: ends strictly with Goal: {{goal}}' ($checkPrompt.TrimEnd() -match '(?ms)Goal:\s*\{\{goal\}\}$')

    # =========================================================================
    # 2. Prompt Prefix Stability across Varying Goals (Goal A vs Goal B)
    # =========================================================================
    $goalA = 'Add memory monitor check'
    $goalB = 'Refactor parser loop'

    $promptTmpl = [string]$planStep.args.Prompt
    $promptA = $promptTmpl.Replace('{{goal}}', $goalA)
    $promptB = $promptTmpl.Replace('{{goal}}', $goalB)

    $resA = Invoke-AgentStep @{
        Prompt = $promptA
        Role = 'plan'
        WorkDir = $wt
        Context = 'MAP.md;LESSONS.md'
    }
    Check 'agent-step runs for Goal A with exit code 0' ($resA.ExitCode -eq 0)

    $resB = Invoke-AgentStep @{
        Prompt = $promptB
        Role = 'plan'
        WorkDir = $wt
        Context = 'MAP.md;LESSONS.md'
    }
    Check 'agent-step runs for Goal B with exit code 0' ($resB.ExitCode -eq 0)

    $fullA = $resA.Prompt
    $fullB = $resB.Prompt

    Check 'assembled prompt A contains Goal A' ($fullA -match [regex]::Escape("Goal: $goalA"))
    Check 'assembled prompt B contains Goal B' ($fullB -match [regex]::Escape("Goal: $goalB"))

    $splitMarker = "Goal: "
    $idxA = $fullA.LastIndexOf($splitMarker)
    $idxB = $fullB.LastIndexOf($splitMarker)
    Check 'split marker Goal: found in prompt A' ($idxA -gt 0)
    Check 'split marker Goal: found in prompt B' ($idxB -gt 0)

    $prefixA = $fullA.Substring(0, $idxA)
    $prefixB = $fullB.Substring(0, $idxB)

    # 100% byte-identical prefix check
    Check 'prefix before Goal: is 100% byte-identical between Goal A and Goal B' ($prefixA -ceq $prefixB)

    # Prefix accounts for >90% of total prompt length
    $ratioA = [double]$prefixA.Length / [double]$fullA.Length
    $ratioB = [double]$prefixB.Length / [double]$fullB.Length
    Check 'prefix accounts for >90% of total prompt A length' ($ratioA -gt 0.90)
    Check 'prefix accounts for >90% of total prompt B length' ($ratioB -gt 0.90)

    # 2b. Line Cook (do step) prompt prefix stability across varying goals
    $doPromptTmpl = [string]$doStep.args.Prompt
    $doPromptA = $doPromptTmpl.Replace('{{goal}}', $goalA)
    $doPromptB = $doPromptTmpl.Replace('{{goal}}', $goalB)

    $resDoA = Invoke-AgentStep @{
        Prompt = $doPromptA
        Role = 'do'
        WorkDir = $wt
        Context = 'LESSONS.md'
    }
    Check 'line cook: agent-step runs for Goal A with exit code 0' ($resDoA.ExitCode -eq 0)

    $resDoB = Invoke-AgentStep @{
        Prompt = $doPromptB
        Role = 'do'
        WorkDir = $wt
        Context = 'LESSONS.md'
    }
    Check 'line cook: agent-step runs for Goal B with exit code 0' ($resDoB.ExitCode -eq 0)

    $doFullA = $resDoA.Prompt
    $doFullB = $resDoB.Prompt

    Check 'line cook: assembled prompt A contains Goal A' ($doFullA -match [regex]::Escape("Goal: $goalA"))
    Check 'line cook: assembled prompt B contains Goal B' ($doFullB -match [regex]::Escape("Goal: $goalB"))

    $doIdxA = $doFullA.LastIndexOf($splitMarker)
    $doIdxB = $doFullB.LastIndexOf($splitMarker)
    Check 'line cook: split marker Goal: found in prompt A' ($doIdxA -gt 0)
    Check 'line cook: split marker Goal: found in prompt B' ($doIdxB -gt 0)

    $doPrefixA = $doFullA.Substring(0, $doIdxA)
    $doPrefixB = $doFullB.Substring(0, $doIdxB)

    # 100% byte-identical prefix check
    Check 'line cook: prefix before Goal: is 100% byte-identical between Goal A and Goal B' ($doPrefixA -ceq $doPrefixB)

    # Prefix accounts for >80% of total prompt length
    $doRatioA = [double]$doPrefixA.Length / [double]$doFullA.Length
    $doRatioB = [double]$doPrefixB.Length / [double]$doFullB.Length
    Check 'line cook: prefix accounts for >80% of total prompt A length' ($doRatioA -gt 0.80)
    Check 'line cook: prefix accounts for >80% of total prompt B length' ($doRatioB -gt 0.80)

    # =========================================================================
    # 3. Attached Reference Context Placement
    # =========================================================================
    Check 'the creed comes first in the assembled prompt' ((($fullA -replace "`r`n", "`n").TrimStart()).StartsWith($creedText))
    $bodyA = Strip-Creed $fullA
    $posHeadChef = $bodyA.IndexOf('You are the head chef planning one change')
    $posAttached = $bodyA.IndexOf('Attached files (read-only copies):')
    $posMap = $bodyA.IndexOf('=== MAP.md ===')
    $posLessons = $bodyA.IndexOf('=== LESSONS.md ===')
    $posGoalTail = $bodyA.IndexOf("Goal: $goalA")

    Check 'instruction text is present at the front' ($posHeadChef -eq 0)
    Check 'attached context appears after invariant instructions' ($posHeadChef -lt $posAttached)
    Check 'MAP.md content appears in attached context' ($posAttached -lt $posMap)
    Check 'LESSONS.md content appears in attached context' ($posMap -lt $posLessons)
    Check 'attached context appears before dynamic goal string' ($posLessons -lt $posGoalTail)
    Check 'dynamic goal is strictly at the tail end of the assembled prompt' ($fullA.TrimEnd().EndsWith("Goal: $goalA"))

    # =========================================================================
    # 4. Parameter Handling & Backwards Compatibility
    # =========================================================================
    # Case 4a: Explicit -Goal parameter support with separate -Prompt
    $baseInstruction = "You are a line cook carrying out a planned change.`nRead PLAN.md."
    $explicitGoal = "Add timeout guard to runner"
    $resExplicit = Invoke-AgentStep @{
        Prompt = $baseInstruction
        Goal = $explicitGoal
        Role = 'plan'
        WorkDir = $wt
        Context = 'LESSONS.md'
    }
    Check 'explicit -Goal: agent-step runs successfully' ($resExplicit.ExitCode -eq 0)
    if ($resExplicit.ExitCode) { Write-Host ($resExplicit.Output.Trim() -split "`r?`n" | Select-Object -Last 8 | Out-String) }
    $fullExplicit = $resExplicit.Prompt
    Check 'explicit -Goal: base instructions come before attached context' ($fullExplicit.IndexOf($baseInstruction) -lt $fullExplicit.IndexOf('Attached files (read-only copies):'))
    Check 'explicit -Goal: attached context comes before goal' ($fullExplicit.IndexOf('Attached files (read-only copies):') -lt $fullExplicit.IndexOf("Goal: $explicitGoal"))
    Check 'explicit -Goal: assembled prompt ends with Goal: <goal>' ($fullExplicit.TrimEnd().EndsWith("Goal: $explicitGoal"))

    # Case 4b: Explicit -Goal already prefixed with "Goal:" does not duplicate prefix
    $resExplicitPrefixed = Invoke-AgentStep @{
        Prompt = $baseInstruction
        Goal = "Goal: $explicitGoal"
        Role = 'plan'
    }
    Check 'explicit -Goal already prefixed: no duplicate Goal: Goal:' ($resExplicitPrefixed.Prompt -notmatch 'Goal:\s*Goal:')
    Check 'explicit -Goal already prefixed: ends with single Goal: <goal>' ($resExplicitPrefixed.Prompt.TrimEnd().EndsWith("Goal: $explicitGoal"))

    # Case 4c: Implicit Goal: ... extraction from tail of -Prompt
    $tailPrompt = "$baseInstruction`n`nGoal: Implicitly extracted task"
    $resImplicit = Invoke-AgentStep @{
        Prompt = $tailPrompt
        Role = 'plan'
        WorkDir = $wt
        Context = 'LESSONS.md'
    }
    Check 'implicit goal extraction: runs successfully' ($resImplicit.ExitCode -eq 0)
    $fullImplicit = $resImplicit.Prompt
    Check 'implicit goal extraction: context moved ahead of goal' ($fullImplicit.IndexOf('Attached files (read-only copies):') -lt $fullImplicit.IndexOf('Goal: Implicitly extracted task'))
    Check 'implicit goal extraction: instructions at front' ((Strip-Creed $fullImplicit).StartsWith($baseInstruction))
    Check 'implicit goal extraction: goal at tail' ($fullImplicit.TrimEnd().EndsWith('Goal: Implicitly extracted task'))

    # Case 4d: Prompts without any goal (legacy compatibility)
    $resNoGoal = Invoke-AgentStep @{
        Prompt = "Review codebase security"
        Role = 'check'
        WorkDir = $wt
        Context = 'MAP.md'
    }
    Check 'no goal prompt: runs successfully' ($resNoGoal.ExitCode -eq 0)
    $fullNoGoal = $resNoGoal.Prompt
    Check 'no goal prompt: starts with prompt' ((Strip-Creed $fullNoGoal).StartsWith('Review codebase security'))
    Check 'no goal prompt: contains attached context' ($fullNoGoal -match 'Attached files \(read-only copies\):')
    Check 'no goal prompt: contains no Goal: label' ($fullNoGoal -notmatch '(?m)^Goal:')

    # Case 4e: Prompt without goal and without attached context
    $resSimple = Invoke-AgentStep @{
        Prompt = "Simple question about prime numbers"
        Role = 'plan'
    }
    Check 'simple prompt without context or goal: byte-identical to input' ((Strip-Creed $resSimple.Prompt).Trim() -eq "Simple question about prime numbers")

    # Case 4f: Token replacement in -Goal parameter
    $resToken = Invoke-AgentStep @{
        Prompt = $baseInstruction
        Goal = "Job {{job}} in {{worktree}}"
        Role = 'plan'
    }
    Check 'token replacement in -Goal: {{job}} is replaced' ($resToken.Prompt -match 'Job J99')
    Check 'token replacement in -Goal: {{worktree}} is replaced' ($resToken.Prompt -notmatch '\{\{worktree\}\}')

    # Case 5: agent-step itself keeps the sous chef's decision (and -Private) next to the run for the Chef app
    $runBase = Join-Path $root 'run-private'
    $sousFile = "$runBase.sous.json"
    $env:KITCHEN_RUN = $runBase
    $resPriv = Invoke-AgentStep @{ Prompt = 'Tailor my resume'; Role = 'plan'; Private = '' }
    $privSaved = if (Test-Path -LiteralPath $sousFile) { try { Get-Content -LiteralPath $sousFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
    Check 'agent-step -Private: .sous.json is written by agent-step' ($null -ne $privSaved)
    Check 'agent-step -Private: .sous.json says private true' ($privSaved.private -eq $true)

    # a public run still saves its decision, marked not private
    Remove-Item -LiteralPath $sousFile -Force -ErrorAction SilentlyContinue
    $resPub = Invoke-AgentStep @{ Prompt = 'Summarise the repo layout'; Role = 'plan' }
    $pubSaved = if (Test-Path -LiteralPath $sousFile) { try { Get-Content -LiteralPath $sousFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
    Check 'agent-step public: .sous.json is written by agent-step' ($null -ne $pubSaved)
    Check 'agent-step public: .sous.json says private false' ($null -ne $pubSaved -and $pubSaved.private -ne $true)

    # without KITCHEN_RUN nothing is written
    Remove-Item -LiteralPath $sousFile -Force -ErrorAction SilentlyContinue
    Remove-Item Env:KITCHEN_RUN -ErrorAction SilentlyContinue
    $null = Invoke-AgentStep @{ Prompt = 'Tailor my resume'; Role = 'plan'; Private = '' }
    Check 'agent-step without KITCHEN_RUN writes no .sous.json' (-not (Test-Path -LiteralPath $sousFile))

} finally {
    foreach ($n in $saveEnv.Keys) {
        [Environment]::SetEnvironmentVariable($n, $saveEnv[$n])
    }
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "KitchenCooks tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
