# Dot-source: what the tests station knows about each suite from <kitchen>\suite-times.jsonl, and the rules it runs suites by.
# One line per suite run, written by scripts/run-bounded.ps1 -TimesFile: {repo, suite, sec, cpuSec, procs, peakMB, sampled, ok, code,
# parallel, sha, at}. Lines are per repo (the folder name of the repo's main checkout), so two repos with a Test-X never mix.
# The rules (each is a measured number from the 2026-10-22 audit, gemini-brain projects/tide/arch-10-22/tests-ci.md):
# - how many at once: at most min(4, logical cores / 2); one at a time while the repo has no history yet (nothing measured = no guess)
# - memory budget: a suite starts only while (recorded peaks of the running suites + its own peak + 1,024 MB reserve) < free RAM MB.
#   Free RAM is read live, so a running suite's present use is counted twice (in free RAM and in its peak): on the safe side.
#   A suite with no record counts as 1,200 MB (the largest peak measured, Test-KitchenSupervisor 1,185 MB).
# - order: longest first by recorded median seconds (LPT), suites with no record first (they may be long)
# - limit per suite: clamp(3 x p90 of its last 20 passing runs, 60 s, the repo's testTimeoutSec); no passing run yet = testTimeoutSec
$script:SuiteUnknownPeakMB = 1200
$script:SuiteReserveMB = 1024

function Get-SuiteRepoName([string]$Dir) {
    # a worktree's common git dir is the main checkout's .git: every worktree of one repo shares its history
    $common = try { & git -C $Dir rev-parse --path-format=absolute --git-common-dir 2>$null } catch { $null }
    if ($LASTEXITCODE -eq 0 -and "$common".Trim()) { return (Split-Path (Split-Path "$common".Trim() -Parent) -Leaf) }
    Split-Path $Dir -Leaf
}

# The last $Keep records of each suite of $Repo, as a hashtable suite -> records (oldest first). Reads only the file's last 4 MB
# (about 20,000 lines: 20 runs of 60 suites in 15 repos) and parses only this repo's lines, so the cost stays flat as the file grows.
function Read-SuiteTimes([string]$File, [string]$Repo, [int]$Keep = 20) {
    $by = @{}
    if (-not $File -or -not (Test-Path -LiteralPath $File)) { return $by }
    $text = ''
    try {
        $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
        try { $n = [math]::Min($fs.Length, 4MB); $null = $fs.Seek(-$n, 'End'); $buf = [byte[]]::new($n); $r = 0; while ($r -lt $n) { $k = $fs.Read($buf, $r, $n - $r); if ($k -le 0) { break }; $r += $k }; $text = [Text.Encoding]::UTF8.GetString($buf, 0, $r) }
        finally { $fs.Dispose() }
    } catch { return $by }
    $needle = '"repo":' + ($Repo | ConvertTo-Json -Compress) + ','
    foreach ($line in $text -split "`n") {
        if (-not $line.Contains($needle)) { continue }
        $o = try { $line | ConvertFrom-Json } catch { $null }   # a torn first line (cut by the 4 MB window) or a half-written one is skipped
        if (-not $o -or -not $o.suite) { continue }
        if (-not $by.ContainsKey($o.suite)) { $by[$o.suite] = [Collections.Generic.List[object]]::new() }
        $by[$o.suite].Add($o); if ($by[$o.suite].Count -gt $Keep) { $by[$o.suite].RemoveAt(0) }
    }
    $by
}

# keeps the file from growing without end: past $MaxMB it becomes suite-times.old.jsonl (one old generation kept)
function Limit-SuiteTimesFile([string]$File, [int]$MaxMB = 32) {
    try { if ((Test-Path -LiteralPath $File) -and (Get-Item -LiteralPath $File).Length -gt $MaxMB * 1MB) { Move-Item -LiteralPath $File -Destination ([IO.Path]::ChangeExtension($File, '.old.jsonl')) -Force } } catch { }
}

function Get-SuiteLimitSec($Records, [int]$CeilingSec) {
    $secs = @($Records | Where-Object { $_.ok -eq $true -and $null -ne $_.sec } | ForEach-Object { [double]$_.sec } | Sort-Object)
    if (-not $secs.Count) { return $CeilingSec }
    $p90 = $secs[[math]::Max(0, [int][math]::Ceiling(0.9 * $secs.Count) - 1)]
    [int][math]::Min($CeilingSec, [math]::Max(60, [math]::Ceiling(3 * $p90)))
}

function Get-SuitePeakMB($Records) {
    $peaks = @($Records | Where-Object { $null -ne $_.peakMB -and [double]$_.peakMB -gt 0 } | ForEach-Object { [double]$_.peakMB })
    if (-not $peaks.Count) { return $script:SuiteUnknownPeakMB }
    [int]($peaks | Measure-Object -Maximum).Maximum
}

function Get-SuiteMedianSec($Records) {
    $secs = @($Records | Where-Object { $null -ne $_.sec } | ForEach-Object { [double]$_.sec } | Sort-Object)
    if (-not $secs.Count) { return $null }
    $secs[[int][math]::Floor(($secs.Count - 1) / 2)]
}

function Get-SuiteParallelCap([int]$Cores = [Environment]::ProcessorCount) { [math]::Max(1, [math]::Min(4, [int][math]::Floor($Cores / 2))) }

# True when one more suite of $NextPeakMB fits next to the running ones ($RunningPeaksMB) with the reserve left over
function Test-SuiteBudget([double[]]$RunningPeaksMB, [double]$NextPeakMB, [double]$FreeMB, [double]$ReserveMB = $script:SuiteReserveMB) {
    (($RunningPeaksMB | Measure-Object -Sum).Sum + $NextPeakMB + $ReserveMB) -lt $FreeMB
}

# Longest first (LPT): suites with no record first, then by median seconds, slowest first; ties keep the given order
function Get-SuiteRunOrder($Suites, [hashtable]$History) {
    $i = 0
    @($Suites | ForEach-Object { $m = Get-SuiteMedianSec $History[$_.BaseName]; [pscustomobject]@{ s = $_; known = [int]($null -ne $m); m = $(if ($null -ne $m) { $m } else { 0 }); i = $i++ } } |
        Sort-Object known, @{ Expression = 'm'; Descending = $true }, i | ForEach-Object { $_.s })
}

function Get-FreeMemoryMB { try { [double](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1KB } catch { 0 } }
