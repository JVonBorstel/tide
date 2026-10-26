# One-screen verification: run every configured test suite (bounded) across the repos, then the kitchen check.
# Config (JSON): { "suites": [ { "name", "dir", "glob" (relative to dir), "timeoutSeconds", "maxMB", "prependPath" (optional), "skip" (optional file names), "minSuites" (optional) } ] }
# A glob that matches nothing (or fewer than minSuites files: a dropped, renamed or skipped suite), or a missing dir, is a FAILURE (never silently green). Exit: 0 all pass, 1 any FAIL/TIMEOUT/MEMORY, 2 bad config.
# Sites (multi-site design TD-5): when the Sites registry exists (kitchen.json "sites" in -KitchenRoot, read by kitchen/site-registry.ps1),
# the suites run Site by Site: each registry Tower uses its entries in this config (matched by dir; a Tower with none runs tests\Test-*.ps1),
# and config entries no Site lists run last under UNASSIGNED (never dropped). No registry = this config's list, output exactly as before.
param([string]$ConfigPath = '', [switch]$NoKitchen, [string]$KitchenCheck = (Join-Path $PSScriptRoot 'kitchen-check.ps1'),
    [string]$KitchenRoot = $(if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }))
# The suite list is this PC's layout (which repos sit where), so a state-folder verify-all.json (BRAIN_KITCHEN, else
# %LOCALAPPDATA%\brain-kitchen) wins over this repo's copy, the same way the state-folder kitchen.json does; the repo copy is the default.
if (-not $ConfigPath) {
    $sv = Join-Path $(if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }) 'verify-all.json'
    if (Test-Path -LiteralPath $sv) { $ConfigPath = $sv; Write-Output "suites: $sv (this PC's list)" } else { $ConfigPath = Join-Path $PSScriptRoot 'verify-all.json' }
}
$ErrorActionPreference = 'Stop'
try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json; if (-not $cfg.suites) { throw 'no suites' } } catch { Write-Output "ERROR: bad config ($($_.Exception.Message))"; exit 2 }
. (Join-Path $PSScriptRoot '..\kitchen\site-registry.ps1')
try { $reg = Get-SiteList (Read-SiteRegistry $KitchenRoot) } catch { Write-Output "ERROR: bad Sites registry ($($_.Exception.Message))"; exit 2 }
# groups of suites: one unnamed group (no registry), or one per Site in code order, then UNASSIGNED for the config entries no Site lists
function Get-VerifyPlan($Suites, $Registry) {
    if (-not $Registry) { return , @([pscustomobject]@{ label = ''; suites = @($Suites) }) }
    $used = @{}; $plan = [Collections.Generic.List[object]]::new()
    foreach ($site in $Registry) {
        $ss = foreach ($tw in $site.towers) {
            $mine = @(for ($i = 0; $i -lt $Suites.Count; $i++) { if ((ConvertTo-SiteTowerKey ([string]$Suites[$i].dir)) -ieq $tw) { $used[$i] = $true; $Suites[$i] } })
            if ($mine.Count) { $mine } else { [pscustomobject]@{ name = (Split-Path $tw -Leaf); dir = $tw; glob = 'tests\Test-*.ps1' } }
        }
        $plan.Add([pscustomobject]@{ label = "SITE $($site.code)$(if ($site.name -cne $site.code) { ' ' + $site.name })"; suites = @($ss) })
    }
    $rest = @(for ($i = 0; $i -lt $Suites.Count; $i++) { if (-not $used[$i]) { $Suites[$i] } })
    if ($rest.Count) { $plan.Add([pscustomobject]@{ label = 'UNASSIGNED'; suites = $rest }) }
    , @($plan)
}
$plan = Get-VerifyPlan @($cfg.suites) $reg
$bounded = Join-Path $PSScriptRoot 'run-bounded.ps1'
$pwsh = (Get-Process -Id $PID).Path
$rows = New-Object System.Collections.Generic.List[object]
$basePath = $env:PATH
foreach ($g in $plan) {
    foreach ($s in $g.suites) {
        $dir = [Environment]::ExpandEnvironmentVariables([string]$s.dir)   # dirs may say %USERPROFILE%\...
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $rows.Add([pscustomobject]@{ st = 'FAIL'; name = $s.name; suite = '(dir missing)'; note = $dir; grp = $g.label }); continue }
        $files = @(Get-ChildItem -Path (Join-Path $dir $s.glob) -File -ErrorAction SilentlyContinue | Where-Object { $s.skip -notcontains $_.Name } | Sort-Object Name)
        if (-not $files.Count) { $rows.Add([pscustomobject]@{ st = 'FAIL'; name = $s.name; suite = '(none)'; note = "no suites matched $($s.glob)"; grp = $g.label }); continue }
        if ($s.minSuites -and $files.Count -lt [int]$s.minSuites) { $rows.Add([pscustomobject]@{ st = 'FAIL'; name = $s.name; suite = '(too few)'; note = "only $($files.Count) suites matched $($s.glob), expected at least $($s.minSuites)"; grp = $g.label }) }
        $env:PATH = if ($s.prependPath) { "$($s.prependPath);$basePath" } else { $basePath }
        foreach ($f in $files) {
            $to = if ($s.timeoutSeconds) { [int]$s.timeoutSeconds } else { 600 }; $mb = if ($s.maxMB) { [int]$s.maxMB } else { 2000 }
            Push-Location $dir
            try { $out = & $pwsh -NoProfile -File $bounded -Script $f.FullName -TimeoutSeconds $to -MaxMB $mb 2>&1 | Out-String; $code = $LASTEXITCODE } finally { Pop-Location }
            $last = (($out -split "`r?`n" | Where-Object { $_ -match 'passed' } | Select-Object -Last 1) -as [string]); if ($last) { $last = $last.Trim() }
            $st = switch ($code) { 0 { 'PASS' } 124 { 'TIMEOUT' } 125 { 'MEMORY' } default { 'FAIL' } }
            $rows.Add([pscustomobject]@{ st = $st; name = $s.name; suite = $f.BaseName; note = $last; grp = $g.label })
        }
    }
}
$env:PATH = $basePath
# a Site's header line before its rows (only with a registry: no label, no header)
$lastGrp = ''
foreach ($r in $rows) {
    if ($r.grp -and $r.grp -cne $lastGrp) { $gr = @($rows | Where-Object { $_.grp -ceq $r.grp }); Write-Output ('{0}: {1} suites, {2} not passing' -f $r.grp, $gr.Count, @($gr | Where-Object { $_.st -ne 'PASS' }).Count) }
    $lastGrp = $r.grp
    Write-Output ('{0,-7} {1,-14} {2,-26} {3}' -f $r.st, $r.name, $r.suite, $r.note)
}
$bad = @($rows | Where-Object { $_.st -ne 'PASS' }).Count
# the kitchen check is information, never a test result: its WARNs are resource state (a loaded local model, a big TEMP), and counting
# them made every green run read OVERALL: FAIL, which trains Jordan to ignore FAIL. Its warnings are shown beside the verdict instead.
$kw = 0
if (-not $NoKitchen) { $k = & $pwsh -NoProfile -File $KitchenCheck 2>&1 | Out-String; $kl = @($k -split "`r?`n" | Where-Object { $_.Trim() }); Write-Output ('KITCHEN ' + ($kl | Select-Object -Last 1)); $kw = @($kl | Where-Object { $_ -match '^WARN' }).Count; if ($LASTEXITCODE -ne 0 -and -not $kw) { $kw = 1 } }
Write-Output ("OVERALL: {0} ({1} suites, {2} not passing{3})" -f $(if ($bad) { 'FAIL' } else { 'PASS' }), $rows.Count, $bad, $(if ($kw) { "; kitchen: $kw warning$(if ($kw -ne 1) { 's' })" } else { '' }))
exit ([int]($bad -gt 0))
