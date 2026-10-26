# Tests for scripts/weekly-line.ps1: the weekly performance line from a FAKE scoreboard's JSON (synthetic numbers) into a scratch plan file,
# and ZG-45's self line from a synthetic lobe home (csf.json in zeitgeistd csf.py's shape). Run by the kitchen tests station (tests\Test-*.ps1)
# and by hand; never touches the real plan, the real scoreboard or the real lobe (every run passes -LobeHome). Self-cleaning.
$ErrorActionPreference = 'Stop'
$wl = Join-Path $PSScriptRoot '..\scripts\weekly-line.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('weekly-line-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c, $show = '') { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n"; if ($show) { Write-Host "  got: $show" } } }
function Run([string[]]$a) { $o = & pwsh -NoProfile -File $wl @a 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }
# a csf.json in csf.py's exact key order; $s2 = shadow_blindspots, $meta overrides
function Frame([string]$dir, [string[]]$shadow = @(), [hashtable]$meta = @{}) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $m = [ordered]@{ version = '1.0'; state = 'ok'; charter = 'EXAMPLE'; compiled_utc = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ'); last_sweep_utc = $null; csf_age_min = 2
        ttc_median_hours = $null; loop_state = 'NEAR_THE_LOOP'; trust = 'foreman brier 0.08 (trust 0.92) over 3 claims; 5 unproven bullets'
        counts = [ordered]@{ items_24h = 3; world_signals_24h = 1; open_loops = 2; decisions_ready = 0; post_mortems_due = 1 }; trimmed = 0; chars = 900; tokens_est = 225 }
    foreach ($k in $meta.Keys) { $m[$k] = $meta[$k] }
    $f = [ordered]@{ meta = $m; '1_normative_charter' = [ordered]@{ north_star_objectives = @(); hard_guardrails = @() }
        '2_endogenous_self_state' = [ordered]@{ active_open_loops = @('PRIVATE-LOOP-TEXT'); shadow_blindspots = @($shadow); yard_signals = @('WO-1 SECRET-CLIENT') }
        '3_exogenous_world_deltas' = [ordered]@{ actionable_signal = @() }; '4_epistemic_tensions' = [ordered]@{ unresolved_dialectics = @() }; '5_decision_ready_nodes' = [ordered]@{ unlocked_choices = @(); pending_post_mortems = @('D-1: SECRET-DECISION') } }
    [IO.File]::WriteAllText((Join-Path $dir 'csf.json'), ($f | ConvertTo-Json -Depth 6))
}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $plan = Join-Path $root 'performance.md'; $fake = Join-Path $root 'fake-scoreboard.ps1'; $bad = Join-Path $root 'bad-scoreboard.ps1'; $old = Join-Path $root 'old-scoreboard.ps1'
    $lobe = Join-Path $root 'lobe'; $noLobe = Join-Path $root 'no-lobe'
    $std = '"standard":{"brokenMains":0,"falseUndos":null,"silentFailures":null,"floorMinutes":32.46,"floors":4,"missing":{"falseUndos":"1 of 2 merge.undone events in events.jsonl have no preMergeSha (no blame check ran)","silentFailures":"nothing records yet when a failure reached the Board"}}'
    Set-Content $fake "param([double]`$Days, [switch]`$Json); '{`"days`":7.0,`"firstTryPct`":40.0,`"merged`":13,`"tokensPerMerged`":1372691,`"minOrderToMerge`":1034.4,$std}'"
    Set-Content $old "param([double]`$Days, [switch]`$Json); '{`"days`":7.0,`"firstTryPct`":40.0,`"merged`":13,`"tokensPerMerged`":1372691,`"minOrderToMerge`":1034.4}'"
    Set-Content $bad "'scoreboard broke'; exit 1"
    Frame $lobe @('GW W4: 0 of 10 floors touched in 14 days; 2 merged, 0 cooking, 8 with no order', 'DEMO P2: 1 of 3 floors touched in 14 days; 0 merged, 1 cooking, 2 with no order', 'JH roadmap: unreadable (missing)', 'INCOME_TRACK: 0 h in 14 d; unmet SYSTEM')
    [IO.File]::WriteAllText($plan, "# Plan`n## Steps`n1. one`n")
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $want = "- ${today}: order to merge 1,034 min (mean) · tokens per merge 1,372,691 · first try 40% · last 7 days, 13 merged"
    $stdWant = 'broken mains 0 · false undos unknown (1 of 2 merge.undone events in events.jsonl have no preMergeSha (no blame check ran)) · silent failures unknown (nothing records yet when a failure reached the Board) · minutes Floor start to merge 32.5 over 4 Floors'
    $self = "- ${today}: self · $stdWant · shadow pours: 2, post-mortems due: 1, foreman brier: 0.08 · Charter: not written yet (the shadow uses the example)"
    $lobeBefore = (Get-FileHash (Join-Path $lobe 'csf.json')).Hash; $filesBefore = @(Get-ChildItem -Recurse -File $root | ForEach-Object FullName | Sort-Object)

    $r = Run @('-PlanPath', $plan, '-Scoreboard', $fake, '-LobeHome', $lobe)
    $t = [IO.File]::ReadAllText($plan)
    Check 'first run adds the heading, the dated line and the self line (ZG45-2)' ($r.Code -eq 0 -and $t.EndsWith("1. one`n`n## Weekly line`n$want`n$self`n")) $t
    Check 'ZG45-2 counts only: no loop, decision, Yard or Pour text from the frame' ($t -notmatch 'PRIVATE|SECRET|GW W4|DEMO|INCOME_TRACK|JH')
    Check 'ZG45-3 nothing else written: the lobe home unchanged, no new file beside the plan' ((Get-FileHash (Join-Path $lobe 'csf.json')).Hash -eq $lobeBefore -and (@(Get-ChildItem -Recurse -File $root | ForEach-Object FullName | Sort-Object) -join '|') -eq ($filesBefore -join '|'))
    $r = Run @('-PlanPath', $plan, '-Scoreboard', $fake, '-LobeHome', $lobe)
    Check 'same week: not due, nothing written' ($r.Code -eq 0 -and $r.Out -match 'not due' -and [IO.File]::ReadAllText($plan) -eq $t)
    # a later section after the heading: -Force puts the new lines at the end of the Weekly line section, not after the later section
    [IO.File]::WriteAllText($plan, $t + "`n## Later`ntext`n")
    $r = Run @('-PlanPath', $plan, '-Scoreboard', $fake, '-LobeHome', $lobe, '-Force')
    Check '-Force adds a second pair inside the section' ($r.Code -eq 0 -and [IO.File]::ReadAllText($plan).Contains("## Weekly line`n$want`n$self`n$want`n$self`n`n## Later"))
    $before = [IO.File]::ReadAllText($plan)
    $r = Run @('-PlanPath', $plan, '-Scoreboard', $bad, '-LobeHome', $lobe, '-Force')
    Check 'scoreboard without numbers: exit 1, says so, nothing written' ($r.Code -eq 1 -and $r.Out -match 'no numbers' -and [IO.File]::ReadAllText($plan) -eq $before)
    $r = Run @('-PlanPath', (Join-Path $root 'missing.md'), '-Scoreboard', $fake, '-LobeHome', $lobe)
    Check 'missing plan file: exit 2, says so' ($r.Code -eq 2 -and $r.Out -match 'not found')

    # ZG45-2: unknown with the reason, never a guessed 0
    $selfOf = { param($a) $p2 = Join-Path $root ('p-' + [guid]::NewGuid().ToString('N') + '.md'); [IO.File]::WriteAllText($p2, "# P`n"); $null = Run (@('-PlanPath', $p2) + $a); ([IO.File]::ReadAllText($p2) -split "`n" | Where-Object { $_ -match ': self · ' }) -join '' }
    $s = & $selfOf @('-Scoreboard', $fake, '-LobeHome', $noLobe)
    Check 'ZG45-2 no lobe frame: all three unknown, with the reason' ($s.EndsWith(" · shadow pours: unknown, post-mortems due: unknown, foreman brier: unknown (no csf.json in the lobe home)")) $s
    $s = & $selfOf @('-Scoreboard', $old, '-LobeHome', $lobe)
    Check 'ZG45-2 a scoreboard with no build standard: unknown, said once' ($s -match ': self · build standard unknown \(the scoreboard sent no build standard numbers\) · shadow pours: 2,') $s
    $d = Join-Path $root 'lobe-none'; Frame $d @() @{ trust = $null; counts = [ordered]@{ open_loops = 0 }; charter = 'LOCKED' }
    $s = & $selfOf @('-Scoreboard', $fake, '-LobeHome', $d)
    Check 'ZG45-2 no Blueprint line, no count, no Foreman claim: each unknown with its reason; a locked Charter is not mentioned' ($s.EndsWith('shadow pours: unknown (no Blueprint line in the frame: every Pour got hours, or no Blueprint was read), post-mortems due: unknown (the frame has no post-mortem count), foreman brier: unknown (the lobe has no Foreman claim yet)')) $s
    $d = Join-Path $root 'lobe-hours'; Frame $d @('GW W4: 0 of 10 floors touched in 14 days; 2 merged, 0 cooking, 8 with no order', 'roadmap shadow: yard events missing; Yard hours unknown, no pour called shadow') @{ trust = 'foreman brier unknown (0 of 10 claims resolved); 7 unproven bullets'; trimmed = 2 }
    $s = & $selfOf @('-Scoreboard', $fake, '-LobeHome', $d)
    Check 'ZG45-2 Yard hours unknown: shadow pours unknown; the Foreman unknown with how many resolved' ($s -match 'shadow pours: unknown \(the Yard''s events could not be read, so no Pour is called shadow\), post-mortems due: 1, foreman brier: unknown \(0 of 10 claims resolved\)') $s
    $d = Join-Path $root 'lobe-trim'; Frame $d @('GW W4: 0 of 10 floors touched in 14 days; 2 merged, 0 cooking, 8 with no order') @{ trimmed = 2; trust = 'foreman brier <b>x</b>' }
    $s = & $selfOf @('-Scoreboard', $fake, '-LobeHome', $d)
    Check 'ZG45-2 a trimmed frame says at least; a trust line in another shape is unknown, its text never copied' ($s -match 'shadow pours: at least 1,' -and $s -match "foreman brier: unknown \(the frame's trust line is not one this script reads\)" -and $s -notmatch '<b>') $s
    $d = Join-Path $root 'lobe-unread'; Frame $d @('JH roadmap: unreadable (missing)')
    $s = & $selfOf @('-Scoreboard', $fake, '-LobeHome', $d)
    Check 'ZG45-2 only an unreadable Blueprint: unknown, never 0' ($s -match 'shadow pours: unknown \(1 Blueprint not read\),') $s
    $d = Join-Path $root 'lobe-stale'; Frame $d @('GW W4: 0 of 10 floors touched in 14 days; 2 merged, 0 cooking, 8 with no order') @{ compiled_utc = (Get-Date).ToUniversalTime().AddHours(-6).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $s = & $selfOf @('-Scoreboard', $fake, '-LobeHome', $d)
    Check 'ZG45-2 a stale frame is not counted' ($s -match 'foreman brier: unknown \(csf.json is stale \(6 h old; the limit is 4 h\)\)') $s
    # ZG45-3: the script names no memory file and no push helper
    $src = Get-Content -Raw $wl
    Check 'ZG45-3 the script writes only the plan file (no memory path, no notify, no push)' ($src -notmatch '(?i)memory\.(md|json|db)|MEMORY\.md|notify\.ps1|ntfy' -and @([regex]::Matches($src, 'WriteAllText|Set-Content|Add-Content|Out-File')).Count -eq 1)
} finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
Write-Host "WeeklyLine tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
