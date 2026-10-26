# Owns the Foreman's merge batch (scripts over tokens): PR branches merged on fetched main, every suite run, flakes told apart, a verdict.
# Called by the Foreman by hand, and by tests/Test-BatchRun.ps1 (temp git repos, stubbed merge-pr and gh, no network). Read-only toward the Yard.
#   pwsh -File scripts/batch-run.ps1 -Prs 12,13 [-Branches a,b] [-Name x] [-Repo <live checkout>] [-Worktree <path>] [-OutDir <path>]
#        [-RemoteUrl <git url>] [-Slug owner/name] [-TimeoutSeconds 1200] [-Reruns 3] [-Merge]
#        [-Gh gh] [-MergePrScript scripts/merge-pr.ps1] [-RunBounded scripts/run-bounded.ps1] [-PassAppUpdate <Repo>/pass-app/update.ps1]
#        [-MaxCpuPercent 70] [-MinFreeMB 2500] [-LoadProbe <script that returns {cpu, freeMB}>]
# Load (lesson 10-24: an overloaded PC gave false reds): CPU load % and free RAM MB are sampled at the start and before every suite run
# (reruns too), into the stage lines and summary.json's load. Average CPU over -MaxCpuPercent, or average free RAM under -MinFreeMB,
# marks the run LOADED in the verdict; a RED then reads "RED (loaded: re-run on a quiet PC)". -Merge still refuses on any RED.
# A probe that fails counts as unknown (not loaded). -LoadProbe replaces the Windows probe (CIM) in tests.
# What it does, in order (lessons-2026-10-24 #1 and #5: one red suite is not a bad batch; Floors that share files go in one batch):
#  1. Fetches main and each PR's branch (-Branches, else `gh pr view` names it) by URL into refs/batch-run/<Name>/*.
#  2. In the integration worktree (default <Repo>\..\wt\integrate-<Name>; made if missing, must be clean, never the live checkout):
#     `git checkout -B integrate-<Name> <fetched main>`, then each PR branch in order with --no-ff --no-edit. A conflict stops the run,
#     names the files and aborts that merge (exit 2).
#  3. Runs every tests\Test-*.ps1, sorted, one at a time through run-bounded.ps1 -TimeoutSeconds N; one log per suite in -OutDir and a
#     line each: name, exit code, seconds, passed/failed.
#  4. Reruns each red suite alone -Reruns times, and checks whether the batch's diff (git diff --name-only <main> HEAD) touches what the
#     suite covers: its own file and every path it names (dot-sourced, copied or run), and the paths those .ps1 files name in turn. A path
#     built from a variable or a wildcard matches loosely; a suite that cannot be read counts as touched.
#  5. Verdict: GREEN (all passed); GREEN-WITH-FLAKE (every red one passed every rerun alone and the batch does not touch it: listed as
#     flakes to fix); RED (anything else).
#  6. -Merge on GREEN or GREEN-WITH-FLAKE only: refuses if main moved since the test; merge-pr.ps1 per PR in order (-Why names the run;
#     stops at the first refusal); fast-forwards the live checkout (fetch, merge --ff-only; only when it is on main); compares main's
#     tree with the tested tree; runs pass-app/update.ps1 when a pass-app file changed. Never merges on RED.
# Writes <OutDir>\summary.json (the stage lines, suites, verdict, flakes, merges) and one plain line per stage.
# Exit: 0 green (and landed, with -Merge), 1 red (or -Merge refused on RED, a merge refused, main's tree not the tested one), 2 refused.
param(
    [string[]]$Prs = @(),
    [string[]]$Branches = @(),
    [string]$Name = '',
    [string]$Repo = '',
    [string]$Worktree = '',
    [string]$OutDir = '',
    [string]$RemoteUrl = '',   # default: https://github.com/<kitchen.repo.json "github">.git of -Repo (the repo's home moves with its config)
    [string]$Slug = '',
    [int]$TimeoutSeconds = 1200,
    [int]$Reruns = 3,
    [switch]$Merge,
    [string]$Gh = 'gh',
    [string]$MergePrScript = '',
    [string]$RunBounded = '',
    [string]$PassAppUpdate = '',
    [int]$MaxCpuPercent = 70,
    [int]$MinFreeMB = 2500,
    [string]$LoadProbe = ''
)
$ErrorActionPreference = 'Stop'
$pwsh = [Environment]::ProcessPath
$script:lines = [Collections.Generic.List[string]]::new()
$script:sum = [ordered]@{ name = $Name; verdict = ''; exit = $null; main = ''; head = ''; prs = @(); suites = @(); flakes = @(); merged = @(); lines = @() }
$script:logDir = ''; $script:ns = ''; $script:repoDir = ''
$script:samples = [Collections.Generic.List[object]]::new()

# ---- machine load: CPU % and free RAM MB, sampled at the start and before every suite run ----
function Get-Load {
    try {
        $l = if ($LoadProbe) { & $LoadProbe } else {
            [pscustomobject]@{ cpu = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object LoadPercentage -Average).Average
                freeMB = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1KB }
        }
        [pscustomobject]@{ cpu = [math]::Round([double]$l.cpu); freeMB = [math]::Round([double]$l.freeMB) }
    } catch { [pscustomobject]@{ cpu = $null; freeMB = $null } }
}
function Add-LoadSample([string]$at) {
    $l = Get-Load
    $script:samples.Add([ordered]@{ at = $at; cpu = $l.cpu; freeMB = $l.freeMB })
    if ($null -eq $l.cpu) { 'load unknown' } else { "cpu $($l.cpu)%, free $($l.freeMB) MB" }
}
function Get-LoadVerdict {
    $known = @($script:samples | Where-Object { $null -ne $_.cpu })
    $avgCpu = if ($known.Count) { [math]::Round(($known | ForEach-Object { $_.cpu } | Measure-Object -Average).Average) } else { $null }
    $avgFree = if ($known.Count) { [math]::Round(($known | ForEach-Object { $_.freeMB } | Measure-Object -Average).Average) } else { $null }
    $why = @()
    if ($known.Count -and $avgCpu -gt $MaxCpuPercent) { $why += "average CPU $avgCpu% is over $MaxCpuPercent%" }
    if ($known.Count -and $avgFree -lt $MinFreeMB) { $why += "average free RAM $avgFree MB is under $MinFreeMB MB" }
    [ordered]@{ loaded = [bool]$why.Count; why = ($why -join '; '); avgCpu = $avgCpu; avgFreeMB = $avgFree; maxCpuPercent = $MaxCpuPercent
        minFreeMB = $MinFreeMB; samples = @($script:samples) }
}

function Say([string]$stage, [string]$text) { $l = "batch-run: ${stage}: $text"; $script:lines.Add($l); Write-Host $l }
function Invoke-Git([string]$dir, [string[]]$GitArgs) {
    $o = & git -C $dir @GitArgs 2>&1 | Out-String
    [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); out = $o.Trim() }
}
function Get-Short([string]$s) { if ($s.Length -gt 12) { $s.Substring(0, 12) } else { $s } }
function Get-LastLine([string]$s) { @($s -split "\r?\n" | Where-Object { $_.Trim() })[-1] }
function Split-List([string[]]$items) { @($items | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Finish([int]$code, [string]$verdict) {
    if ($verdict) { $script:sum.verdict = $verdict }
    if (-not $script:sum.Contains('load')) { $script:sum.load = Get-LoadVerdict }
    $script:sum.exit = $code; $script:sum.at = [DateTime]::UtcNow.ToString('o')
    if ($script:ns -and $script:repoDir) {
        foreach ($r in @((Invoke-Git $script:repoDir @('for-each-ref', '--format=%(refname)', $script:ns)).out -split "\r?\n" | Where-Object { $_ })) {
            $null = Invoke-Git $script:repoDir @('update-ref', '-d', $r)
        }
    }
    if ($script:logDir) {
        $path = Join-Path $script:logDir 'summary.json'
        Say 'summary' "written to $path"
        $script:sum.lines = @($script:lines)
        New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null
        [IO.File]::WriteAllText($path, ($script:sum | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    }
    exit $code
}
function Stop-Batch([string]$stage, [string]$text) { Say $stage "REFUSED: $text"; Finish 2 'REFUSED' }

# ---- what a suite covers, and whether the batch touches it ----
function Get-PathRefs([string]$file) {
    $text = try { Get-Content -LiteralPath $file -Raw -ErrorAction Stop } catch { return }
    $rx = '[A-Za-z0-9_.$*{}\-\\/]+\.(?:ps1|psm1|psd1|mjs|cjs|js|json|jsonl|py|html|css|txt|md|vbs|cmd|rs|toml|yml)\b'
    @([regex]::Matches([string]$text, $rx) | ForEach-Object { ($_.Value -replace '\\', '/') -replace '^(\.\.?/)+', '' } | Select-Object -Unique)
}
function Get-Pattern([string]$ref) { ($ref -replace '\$\{?\w+\}?', '*').TrimStart('/') }
function Test-RefHit([string]$file, [string]$ref) {
    $pat = Get-Pattern $ref; $leaf = ($pat -split '/')[-1]
    if ($file -like "*$pat") { return $true }
    $leaf -notmatch '[*?]' -and ($file -split '/')[-1] -eq $leaf
}
# The suite's own file, every path it names, and every path the .ps1 files it names (found in the batch) name in turn: two levels.
function Get-SuiteCover([string]$root, [string]$suiteRel, [string[]]$tracked) {
    $refs = [Collections.Generic.List[string]]::new(); $refs.Add($suiteRel)
    if (-not (Test-Path -LiteralPath (Join-Path $root $suiteRel) -PathType Leaf)) { return [pscustomobject]@{ refs = @($refs); unsure = $true } }
    $first = @(Get-PathRefs (Join-Path $root $suiteRel))
    foreach ($r in $first) { if (-not $refs.Contains($r)) { $refs.Add($r) } }
    $next = @($first | Where-Object { $_ -match '\.ps1$' -and $_ -notmatch '[*$]' } | ForEach-Object { $r = $_; $tracked | Where-Object { Test-RefHit $_ $r } } | Select-Object -Unique)
    foreach ($f in $next) { foreach ($r in @(Get-PathRefs (Join-Path $root $f))) { if ($r -and -not $refs.Contains($r)) { $refs.Add($r) } } }
    [pscustomobject]@{ refs = @($refs); unsure = $false }
}
function Find-Touch($cover, [string[]]$diff) {
    if ($cover.unsure) { return @('(the suite could not be read, so it counts as touched)') }
    @(foreach ($d in $diff) { foreach ($r in $cover.refs) { if (Test-RefHit $d $r) { "$d (via $r)"; break } } })
}

# ---- running a suite ----
function Invoke-Suite([string]$wt, [string]$suitePath, [string]$log) {
    $load = Add-LoadSample ([IO.Path]::GetFileNameWithoutExtension($log))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Push-Location -LiteralPath $wt
    try { $o = & $pwsh -NoProfile -File $RunBounded -Script $suitePath -TimeoutSeconds $TimeoutSeconds 2>&1 | Out-String; $code = $LASTEXITCODE }
    finally { Pop-Location }
    [IO.File]::WriteAllText($log, $o, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ code = $code; sec = [math]::Round($sw.Elapsed.TotalSeconds, 1); load = $load }
}

# ---- 1. input ----
if (-not $Name) { $Name = Get-Date -Format 'MMdd-HHmm'; $script:sum.name = $Name }
if ($Name -notmatch '^[A-Za-z0-9._-]{1,60}$' -or $Name -match '\.\.') { Stop-Batch 'input' "-Name '$Name' is not a plain name (letters, digits, . _ -)" }
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { Stop-Batch 'input' "$Repo is not a git checkout" }
$Repo = (Resolve-Path -LiteralPath $Repo).Path
if (-not $Worktree) { $Worktree = Join-Path (Split-Path -Parent $Repo) "wt\integrate-$Name" }
if (-not $OutDir) { $OutDir = "$Worktree-logs" }
$script:logDir = $OutDir
if (-not $MergePrScript) { $MergePrScript = Join-Path $PSScriptRoot 'merge-pr.ps1' }
if (-not $RunBounded) { $RunBounded = Join-Path $PSScriptRoot 'run-bounded.ps1' }
if (-not $PassAppUpdate) { $PassAppUpdate = Join-Path $Repo 'pass-app\update.ps1' }
if (-not $RemoteUrl) {
    $homeSlug = try { [string](Get-Content -LiteralPath (Join-Path $Repo 'kitchen.repo.json') -Raw -ErrorAction Stop | ConvertFrom-Json).github } catch { '' }
    if ($homeSlug -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Stop-Batch 'input' "no -RemoteUrl given and $Repo\kitchen.repo.json names no github owner/name" }
    $RemoteUrl = "https://github.com/$homeSlug.git"
}
if (-not $Slug -and $RemoteUrl -match 'github\.com[/:]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?$') { $Slug = $Matches[1] }
$prList = @(Split-List $Prs); $brList = @(Split-List $Branches)
if (-not $prList.Count) { Stop-Batch 'input' 'no PRs given (-Prs 12,13, in merge order)' }
$badPr = @($prList | Where-Object { $_ -notmatch '^[1-9]\d{0,5}$' })
if ($badPr.Count) { Stop-Batch 'input' "not PR numbers: $($badPr -join ', ')" }
if (@($prList | Select-Object -Unique).Count -ne $prList.Count) { Stop-Batch 'input' "a PR is named twice: $($prList -join ', ')" }
if ($brList.Count -and $brList.Count -ne $prList.Count) { Stop-Batch 'input' "$($prList.Count) PR(s) but $($brList.Count) branch(es); give one branch per PR, in the same order" }
if ($TimeoutSeconds -lt 1 -or $Reruns -lt 1) { Stop-Batch 'input' '-TimeoutSeconds and -Reruns must be 1 or more' }
if ($MaxCpuPercent -lt 1 -or $MaxCpuPercent -gt 100 -or $MinFreeMB -lt 0) { Stop-Batch 'input' '-MaxCpuPercent must be 1 to 100 and -MinFreeMB 0 or more' }
if ($LoadProbe -and -not (Test-Path -LiteralPath $LoadProbe)) { Stop-Batch 'input' "the load probe is not at $LoadProbe" }
if (-not (Test-Path -LiteralPath $RunBounded)) { Stop-Batch 'input' "run-bounded.ps1 not found at $RunBounded" }
if ($Merge -and -not $Slug) { Stop-Batch 'input' "-Merge needs -Slug owner/name (not readable from $RemoteUrl)" }
if ($Merge -and -not (Test-Path -LiteralPath $MergePrScript)) { Stop-Batch 'input' "merge-pr.ps1 not found at $MergePrScript" }
if (-not $brList.Count) {
    if (-not $Slug) { Stop-Batch 'input' "no -Branches, and no -Slug to ask GitHub for each PR's branch" }
    $brList = @(foreach ($n in $prList) {
            $o = & $Gh pr view $n -R $Slug --json headRefName -q .headRefName 2>&1 | Out-String
            if ($LASTEXITCODE -or -not $o.Trim()) { Stop-Batch 'input' "could not read PR #$n's branch from GitHub ($(Get-LastLine $o))" }
            $o.Trim()
        })
}
$badBr = @($brList | Where-Object { $_ -notmatch '^[A-Za-z0-9._/-]+$' -or $_ -match '\.\.|^[-/]|/$' })
if ($badBr.Count) { Stop-Batch 'input' "not plain branch names: $($badBr -join ', ')" }
$script:sum.prs = @(for ($i = 0; $i -lt $prList.Count; $i++) { [ordered]@{ pr = [int]$prList[$i]; branch = $brList[$i]; sha = '' } })
Say 'input' "PRs $(($script:sum.prs | ForEach-Object { "#$($_.pr) ($($_.branch))" }) -join ', '), in that order; run integrate-$Name; logs in $OutDir"
Say 'load' "at start: $(Add-LoadSample 'start'); LOADED if the run averages CPU over $MaxCpuPercent% or free RAM under $MinFreeMB MB"

# ---- 2. fetch main and every PR branch by URL ----
$script:ns = "refs/batch-run/$Name"; $script:repoDir = $Repo
$specs = @("+refs/heads/main:$($script:ns)/main") + @(for ($i = 0; $i -lt $prList.Count; $i++) { "+refs/heads/$($brList[$i]):$($script:ns)/pr-$($prList[$i])" })
$f = Invoke-Git $Repo (@('fetch', '-q', '--no-tags', $RemoteUrl) + $specs)
if (-not $f.ok) { Stop-Batch 'fetch' "could not fetch main and the PR branches from $RemoteUrl ($(Get-LastLine $f.out))" }
$mainSha = (Invoke-Git $Repo @('rev-parse', "$($script:ns)/main")).out
$script:sum.main = $mainSha
foreach ($p in $script:sum.prs) { $p.sha = (Invoke-Git $Repo @('rev-parse', "$($script:ns)/pr-$($p.pr)")).out }
Say 'fetch' "main is at $(Get-Short $mainSha); $($prList.Count) PR branch(es) fetched from $RemoteUrl"

# ---- 3. the integration worktree, then each PR branch in order ----
$common = { param($d) $c = Invoke-Git $d @('rev-parse', '--path-format=absolute', '--git-common-dir'); if ($c.ok) { $c.out.TrimEnd('/', '\').Replace('\', '/').ToLowerInvariant() } else { '' } }
if (Test-Path -LiteralPath $Worktree) {
    $Worktree = (Resolve-Path -LiteralPath $Worktree).Path
    if ($Worktree.TrimEnd('\', '/') -eq $Repo.TrimEnd('\', '/')) { Stop-Batch 'integrate' "the integration worktree cannot be the live checkout ($Repo)" }
    if ((& $common $Worktree) -ne (& $common $Repo) -or -not (& $common $Worktree)) { Stop-Batch 'integrate' "$Worktree is not a worktree of $Repo" }
    $st = Invoke-Git $Worktree @('status', '--porcelain')
    if ($st.out) { Stop-Batch 'integrate' "$Worktree has uncommitted or untracked files; clean it or pick another -Worktree" }
} else {
    $a = Invoke-Git $Repo @('worktree', 'add', '--detach', $Worktree, $mainSha)
    if (-not $a.ok) { Stop-Batch 'integrate' "could not make the worktree $Worktree ($(Get-LastLine $a.out))" }
}
$co = Invoke-Git $Worktree @('checkout', '-q', '-B', "integrate-$Name", $mainSha)
if (-not $co.ok) { Stop-Batch 'integrate' "could not start integrate-$Name at $(Get-Short $mainSha) ($(Get-LastLine $co.out))" }
foreach ($p in $script:sum.prs) {
    $m = Invoke-Git $Worktree @('merge', '--no-ff', '--no-edit', '-m', "Merge PR #$($p.pr) ($($p.branch)) into integrate-$Name", "$($script:ns)/pr-$($p.pr)")
    if ($m.ok) { continue }
    $files = @((Invoke-Git $Worktree @('diff', '--name-only', '--diff-filter=U')).out -split "\r?\n" | Where-Object { $_ })
    $null = Invoke-Git $Worktree @('merge', '--abort')
    $what = if ($files.Count) { "conflicts in $($files -join ', ')" } else { "git did not merge it ($(Get-LastLine $m.out))" }
    $script:sum.conflict = [ordered]@{ pr = $p.pr; branch = $p.branch; files = $files }
    Stop-Batch 'integrate' "PR #$($p.pr) ($($p.branch)) $what; that merge was aborted, nothing tested"
}
$head = (Invoke-Git $Worktree @('rev-parse', 'HEAD')).out; $script:sum.head = $head
$diff = @((Invoke-Git $Worktree @('diff', '--name-only', $mainSha, 'HEAD')).out -split "\r?\n" | Where-Object { $_ })
$script:sum.diff = $diff
Say 'integrate' "integrate-$Name at $(Get-Short $head) in $Worktree; $($prList.Count) PR(s) merged with no conflict; the batch changes $($diff.Count) file(s)"

# ---- 4. every suite, sorted, one at a time ----
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$suiteFiles = @(Get-ChildItem -LiteralPath (Join-Path $Worktree 'tests') -Filter 'Test-*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $suiteFiles.Count) { Stop-Batch 'tests' "no tests\Test-*.ps1 in $Worktree" }
$results = @(foreach ($s in $suiteFiles) {
        $n = $s.BaseName; $r = Invoke-Suite $Worktree $s.FullName (Join-Path $OutDir "$n.log")
        $word = if ($r.code -eq 0) { 'passed' } else { 'failed' }
        Say 'suite' "$n exit $($r.code), $($r.sec) s, $word; $($r.load)"
        [ordered]@{ name = $n; code = $r.code; sec = $r.sec; ok = ($r.code -eq 0); log = (Join-Path $OutDir "$n.log"); reruns = @(); touched = @() }
    })
$red = @($results | Where-Object { -not $_.ok })
Say 'tests' "$($results.Count - $red.Count) of $($results.Count) suites passed$(if ($red.Count) { "; red: $(($red | ForEach-Object { $_.name }) -join ', ')" })"

# ---- 5. each red suite alone, and whether the batch touches it ----
if ($red.Count) {
    $tracked = @((Invoke-Git $Worktree @('ls-files')).out -split "\r?\n" | Where-Object { $_ })
    foreach ($s in $red) {
        $s.reruns = @(for ($k = 1; $k -le $Reruns; $k++) { (Invoke-Suite $Worktree (Join-Path $Worktree "tests\$($s.name).ps1") (Join-Path $OutDir "$($s.name).rerun$k.log")).code })
        $s.touched = @(Find-Touch (Get-SuiteCover $Worktree "tests/$($s.name).ps1" $tracked) $diff)
        $alone = @($s.reruns | Where-Object { $_ -eq 0 }).Count
        $t = if ($s.touched.Count) { "the batch touches it: $($s.touched -join ', ')" } else { 'the batch does not touch it' }
        Say 'rerun' "$($s.name) passed $alone of $Reruns alone; $t"
    }
}

# ---- verdict (a LOADED run says so: its reds may be the PC, not the batch) ----
$flaky = @($red | Where-Object { @($_.reruns | Where-Object { $_ -ne 0 }).Count -eq 0 -and -not $_.touched.Count })
$lv = Get-LoadVerdict; $script:sum.load = $lv; $script:sum.loaded = $lv.loaded
$tag = if (-not $lv.loaded) { '' } elseif ($red.Count -and $flaky.Count -ne $red.Count) { ' (loaded: re-run on a quiet PC)' } else { ' (LOADED)' }
$avg = if ($null -eq $lv.avgCpu) { 'load unknown (the probe gave nothing)' } else { "average CPU $($lv.avgCpu)%, free RAM $($lv.avgFreeMB) MB over $($lv.samples.Count) samples" }
Say 'load' $(if ($lv.loaded) { "LOADED: $($lv.why)" } else { "not loaded: $avg" })
$script:sum.suites = $results
if (-not $red.Count) { $verdict = 'GREEN'; Say 'verdict' "GREEN${tag}: all $($results.Count) suites passed" }
elseif ($flaky.Count -eq $red.Count) {
    $verdict = 'GREEN-WITH-FLAKE'; $script:sum.flakes = @($flaky | ForEach-Object { $_.name })
    Say 'verdict' "GREEN-WITH-FLAKE${tag}: the only red suites passed $Reruns of $Reruns alone and the batch does not touch them; flakes to fix: $($script:sum.flakes -join ', ')"
} else {
    $verdict = 'RED'
    Say 'verdict' "RED${tag}: $(@($red | Where-Object { $_ -notin $flaky } | ForEach-Object { $_.name }) -join ', ') failed for real (failed alone, or the batch touches it)"
}
$script:sum.verdict = $verdict; $script:sum.verdictText = "$verdict$tag"
$code = if ($verdict -eq 'RED') { 1 } else { 0 }
if (-not $Merge) { Say 'land' 'not asked (-Merge lands a green batch)'; Finish $code $verdict }
if ($verdict -eq 'RED') { Say 'land' 'REFUSED: the verdict is RED; nothing merged'; Finish 1 $verdict }

# ---- 6. land it: main must not have moved, then merge-pr per PR in order ----
$nf = Invoke-Git $Repo @('fetch', '-q', '--no-tags', $RemoteUrl, "+refs/heads/main:$($script:ns)/now")
if (-not $nf.ok) { Stop-Batch 'land' "could not fetch main again to check it has not moved ($(Get-LastLine $nf.out)); nothing merged" }
$nowSha = (Invoke-Git $Repo @('rev-parse', "$($script:ns)/now")).out
if ($nowSha -ne $mainSha) { Stop-Batch 'land' "main moved from $(Get-Short $mainSha) to $(Get-Short $nowSha) since the batch was tested; nothing merged, run the batch again" }
$why = "batch-run integrate-${Name}: tested together as $(Get-Short $head) on main $(Get-Short $mainSha), verdict $verdict$(if ($script:sum.flakes.Count) { " (flakes to fix: $($script:sum.flakes -join ', '))" })"
foreach ($p in $script:sum.prs) {
    $o = & $pwsh -NoProfile -File $MergePrScript -Repo $Slug -Pr $p.pr -Why $why 2>&1 | Out-String; $mc = $LASTEXITCODE
    [IO.File]::AppendAllText((Join-Path $OutDir 'merge-pr.log'), $o, [Text.UTF8Encoding]::new($false))
    if ($mc -ne 0) {
        $so = if ($script:sum.merged.Count) { "merged before it: #$($script:sum.merged -join ', #')" } else { 'nothing merged' }
        Say 'land' "merge-pr did not merge PR #$($p.pr) (exit ${mc}: $(Get-LastLine $o)); stopped, $so"; Finish 1 $verdict
    }
    $script:sum.merged = @($script:sum.merged) + $p.pr
}
Say 'land' "merged in order: #$($script:sum.merged -join ', #')"

# fast-forward the live checkout, compare trees, update the Board when a pass-app file changed
$lf = Invoke-Git $Repo @('fetch', '-q', '--no-tags', $RemoteUrl, "+refs/heads/main:$($script:ns)/landed")
if (-not $lf.ok) { Say 'fast-forward' "could not fetch the landed main ($(Get-LastLine $lf.out)); live checkout not moved"; Finish 1 $verdict }
$landed = (Invoke-Git $Repo @('rev-parse', "$($script:ns)/landed")).out
$branch = (Invoke-Git $Repo @('rev-parse', '--abbrev-ref', 'HEAD')).out
$ffOk = $false
if ($branch -ne 'main') { Say 'fast-forward' "the live checkout is on '$branch', not main; not fast-forwarded" }
else {
    $ff = Invoke-Git $Repo @('merge', '--ff-only', '-q', "$($script:ns)/landed")
    $ffOk = $ff.ok
    Say 'fast-forward' $(if ($ffOk) { "live checkout fast-forwarded to $(Get-Short $landed)" } else { "the live checkout could not fast-forward ($(Get-LastLine $ff.out))" })
}
$tTested = (Invoke-Git $Worktree @('rev-parse', 'HEAD^{tree}')).out; $tMain = (Invoke-Git $Repo @('rev-parse', "$landed^{tree}")).out
$sameTree = $tTested -eq $tMain
$script:sum.tree = [ordered]@{ tested = $tTested; main = $tMain; same = $sameTree }
if ($sameTree) { Say 'tree' "main's tree is the tested tree ($(Get-Short $tMain))" }
else { Say 'tree' "main's tree differs from the tested tree in: $(((Invoke-Git $Repo @('diff', '--name-only', $head, $landed)).out -split "\r?\n" | Where-Object { $_ }) -join ', ')" }
$passFiles = @((Invoke-Git $Repo @('diff', '--name-only', $mainSha, $landed, '--', 'pass-app')).out -split "\r?\n" | Where-Object { $_ })
$upOk = $true
if (-not $passFiles.Count) { Say 'pass-app' 'no pass-app file changed; nothing to update' }
elseif (-not $ffOk) { Say 'pass-app' "$($passFiles.Count) pass-app file(s) changed, but the live checkout did not move; run pass-app/update.ps1 after it does"; $upOk = $false }
else {
    $uo = & $pwsh -NoProfile -File $PassAppUpdate 2>&1 | Out-String; $upOk = $LASTEXITCODE -eq 0
    [IO.File]::WriteAllText((Join-Path $OutDir 'pass-app-update.log'), $uo, [Text.UTF8Encoding]::new($false))
    Say 'pass-app' "$($passFiles.Count) pass-app file(s) changed; update.ps1 $(if ($upOk) { 'ran' } else { 'failed' }): $(Get-LastLine $uo)"
}
Finish $(if ($ffOk -and $sameTree -and $upOk) { 0 } else { 1 }) $verdict
