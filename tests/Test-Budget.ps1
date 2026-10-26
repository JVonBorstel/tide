# Tests for scripts/budget-check.ps1. Self-cleaning temp folder.
$ErrorActionPreference = 'Stop'
$bc = Join-Path $PSScriptRoot '..\scripts\budget-check.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('bt-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function New-B($name, $ctx, $now, $hand, $boot, $org) {
    $b = Join-Path $root $name; New-Item -ItemType Directory -Force "$b\memory" | Out-Null
    function W($rel, $n, $chars) { if ($n -ge 0) { Set-Content "$b\$rel" ((1..[math]::Max($n,1) | % { 'line' }) -join "`n") } ; if ($chars -ge 0) { [IO.File]::WriteAllText("$b\$rel", ('x' * $chars)) } }
    if ($null -ne $ctx) { W 'AGENT_CONTEXT.md' $ctx -1 }
    if ($null -ne $now) { W 'memory\NOW.md' $now -1 }
    if ($null -ne $hand) { W 'memory\HANDOFF.md' $hand -1 }
    if ($null -ne $boot) { W 'memory\BOOT.md' -1 $boot }
    if ($null -ne $org) { W 'memory\ORG.md' $org -1 }
    $b
}
function Run($b) { $o = & pwsh -NoProfile -File $bc -BrainPath $b 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    # at the limits: all OK
    $r = Run (New-B 'ok' 40 40 120 8000 80)
    Check 'at limits exit 0' ($r.Code -eq 0); Check 'at limits no WARN' ($r.Out -notmatch 'WARN')
    # each file one over
    $r = Run (New-B 'ctx' 41 1 1 1 1); Check 'context over -> exit 1' ($r.Code -eq 1); Check 'context WARN names file' ($r.Out -match 'WARN.*AGENT_CONTEXT\.md')
    $r = Run (New-B 'now' 1 41 1 1 1); Check 'now over' ($r.Code -eq 1 -and $r.Out -match 'WARN.*NOW\.md')
    $r = Run (New-B 'hand' 1 1 121 1 1); Check 'handoff over' ($r.Code -eq 1 -and $r.Out -match 'WARN.*HANDOFF\.md')
    $r = Run (New-B 'boot' 1 1 1 10001 1); Check 'boot over' ($r.Code -eq 1 -and $r.Out -match 'WARN.*BOOT\.md')
    $r = Run (New-B 'org' 1 1 1 1 81); Check 'org over' ($r.Code -eq 1 -and $r.Out -match 'WARN.*ORG\.md')
    # only offender flagged
    $r = Run (New-B 'one' 41 40 120 8000 80); Check 'only ctx flagged' (([regex]::Matches($r.Out, 'WARN')).Count -eq 1)
    # missing files are not failures
    $r = Run (New-B 'missing' 5 5 $null $null $null); Check 'missing files exit 0' ($r.Code -eq 0)
    # bad brain path: loud
    $o = & pwsh -NoProfile -File $bc -BrainPath (Join-Path $root 'nope') 2>&1 | Out-String
    Check 'bad path exit 2' ($LASTEXITCODE -eq 2)
    # never modifies the brain
    $b = New-B 'ro' 50 1 1 1 1; $h1 = (Get-FileHash "$b\AGENT_CONTEXT.md").Hash; $null = Run $b
    Check 'read only' ($h1 -eq (Get-FileHash "$b\AGENT_CONTEXT.md").Hash)
    # FROZEN per ORG.md: header and README say so (no new features)
    Check 'FROZEN note in budget-check.ps1 header' (@(Get-Content (Join-Path $PSScriptRoot '..\scripts\budget-check.ps1') -TotalCount 12) -cmatch 'FROZEN')
    Check 'FROZEN note in README row for budget-check.ps1' ((Get-Content (Join-Path $PSScriptRoot '..\README.md') -Raw) -match '(?m)^\|[^\n]*budget-check\.ps1[^\n]*FROZEN')
} finally { if (Test-Path $root) { Remove-Item -Recurse -Force $root } }
Write-Host "Budget tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
