# One-screen verification: run every configured test suite (bounded) across the repos, then the kitchen check.
# Config (JSON): { "suites": [ { "name", "dir", "glob" (relative to dir), "timeoutSeconds", "maxMB", "prependPath" (optional), "skip" (optional file names), "minSuites" (optional) } ] }
# A glob that matches nothing (or fewer than minSuites files: a dropped, renamed or skipped suite), or a missing dir, is a FAILURE (never silently green). Exit: 0 all pass, 1 any FAIL/TIMEOUT/MEMORY, 2 bad config.
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'verify-all.json'), [switch]$NoKitchen, [string]$KitchenCheck = (Join-Path $PSScriptRoot 'kitchen-check.ps1'))
$ErrorActionPreference = 'Stop'
try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json; if (-not $cfg.suites) { throw 'no suites' } } catch { Write-Output "ERROR: bad config ($($_.Exception.Message))"; exit 2 }
$bounded = Join-Path $PSScriptRoot 'run-bounded.ps1'
$pwsh = (Get-Process -Id $PID).Path
$rows = New-Object System.Collections.Generic.List[object]
$basePath = $env:PATH
foreach ($s in $cfg.suites) {
    $dir = [Environment]::ExpandEnvironmentVariables([string]$s.dir)   # dirs may say %USERPROFILE%\...
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $rows.Add([pscustomobject]@{ st = 'FAIL'; name = $s.name; suite = '(dir missing)'; note = $dir }); continue }
    $files = @(Get-ChildItem -Path (Join-Path $dir $s.glob) -File -ErrorAction SilentlyContinue | Where-Object { $s.skip -notcontains $_.Name } | Sort-Object Name)
    if (-not $files.Count) { $rows.Add([pscustomobject]@{ st = 'FAIL'; name = $s.name; suite = '(none)'; note = "no suites matched $($s.glob)" }); continue }
    if ($s.minSuites -and $files.Count -lt [int]$s.minSuites) { $rows.Add([pscustomobject]@{ st = 'FAIL'; name = $s.name; suite = '(too few)'; note = "only $($files.Count) suites matched $($s.glob), expected at least $($s.minSuites)" }) }
    $env:PATH = if ($s.prependPath) { "$($s.prependPath);$basePath" } else { $basePath }
    foreach ($f in $files) {
        $to = if ($s.timeoutSeconds) { [int]$s.timeoutSeconds } else { 600 }; $mb = if ($s.maxMB) { [int]$s.maxMB } else { 2000 }
        Push-Location $dir
        try { $out = & $pwsh -NoProfile -File $bounded -Script $f.FullName -TimeoutSeconds $to -MaxMB $mb 2>&1 | Out-String; $code = $LASTEXITCODE } finally { Pop-Location }
        $last = (($out -split "`r?`n" | Where-Object { $_ -match 'passed' } | Select-Object -Last 1) -as [string]); if ($last) { $last = $last.Trim() }
        $st = switch ($code) { 0 { 'PASS' } 124 { 'TIMEOUT' } 125 { 'MEMORY' } default { 'FAIL' } }
        $rows.Add([pscustomobject]@{ st = $st; name = $s.name; suite = $f.BaseName; note = $last })
    }
}
$env:PATH = $basePath
foreach ($r in $rows) { Write-Output ('{0,-7} {1,-14} {2,-26} {3}' -f $r.st, $r.name, $r.suite, $r.note) }
$bad = @($rows | Where-Object { $_.st -ne 'PASS' }).Count
# the kitchen check is information, never a test result: its WARNs are resource state (a loaded local model, a big TEMP), and counting
# them made every green run read OVERALL: FAIL, which trains Jordan to ignore FAIL. Its warnings are shown beside the verdict instead.
$kw = 0
if (-not $NoKitchen) { $k = & $pwsh -NoProfile -File $KitchenCheck 2>&1 | Out-String; $kl = @($k -split "`r?`n" | Where-Object { $_.Trim() }); Write-Output ('KITCHEN ' + ($kl | Select-Object -Last 1)); $kw = @($kl | Where-Object { $_ -match '^WARN' }).Count; if ($LASTEXITCODE -ne 0 -and -not $kw) { $kw = 1 } }
Write-Output ("OVERALL: {0} ({1} suites, {2} not passing{3})" -f $(if ($bad) { 'FAIL' } else { 'PASS' }), $rows.Count, $bad, $(if ($kw) { "; kitchen: $kw warning$(if ($kw -ne 1) { 's' })" } else { '' }))
exit ([int]($bad -gt 0))
