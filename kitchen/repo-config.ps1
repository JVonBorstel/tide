# Dot-source from a station: per-repo kitchen settings, so the kitchen can build changes in repositories other than brain-monitor.
# A repository opts in with kitchen.repo.json at its root (no file = brain-monitor's own layout, nothing changes):
#   { "tests": ["tests/phase0/Test-Phase0.ps1", "tests/**/Test-*.ps1"],   suites to run (relative globs, each ending in .ps1; default tests/Test-*.ps1)
#     "testTimeoutSec": 900,                                            per-suite time limit, 1..3600 (default: the station's own)
#     "github": "owner/name",                                           the repo's GitHub name (for the PR stations)
#     "protected": [".claude/**", "scripts/lock-guardrails.ps1"],      files auto-merge must never take without Jordan's yes
#     "commitBudget": { "files": 10, "lines": 600 },                     one order's size limit outside tests/ (default 4 files, 150 lines)
#        "exclude": ["fixtures", "evals"] inside commitBudget: up to 20 more folders or globs not counted (data, not code; tests/ never is)
#        "bySize": { "S": { "files": 6, "lines": 300 }, "L": { "files": 20, "lines": 1600 } } inside commitBudget: limits by the order's
#        size (its size var, else its roadmap item's size, else M; Get-RepoCommitBudget). A size or key it leaves out uses files/lines above.
#     "roadmap": "map/roadmap.json",                                    the repo's roadmap (kitchen/roadmap-lib.ps1, recipe roadmap-item)
#     "freeze": [{ "from": "2026-10-27T00:00", "to": "2026-10-28T18:00", "why": "release demo" }] }
#        merge freeze windows (up to 50): nothing merges into the repo from 'from' until 'to' (this PC's local time; an ISO offset
#        such as -06:00 or Z is honoured when given). The merge station and scripts/merge-pr.ps1 wait or refuse with the 'why'
#        (kitchen/freeze-lib.ps1); building, testing and opening pull requests go on.
# Globs: * = any characters but /, ** = anything including /, ? = one character; \ and / both work; matched without regard to case.
# Unknown keys are ignored; a wrong type, an absolute path or a '..' is an ERROR, never a fall-back to the defaults (fail closed).
#
# WHY THE CONFIG IS READ FROM THE MAIN CHECKOUT, NEVER FROM THE JOB'S WORKTREE: a line cook edits the worktree. If the worktree's own
# kitchen.repo.json decided which suites run, a cook could set "tests" to [] (or to one trivial suite) and every check would pass.
# The main checkout is the merge target and only changes through a merge Jordan said yes to, so its file is the one that counts.
# (A change to kitchen.repo.json is itself protected: Get-RepoProtected always lists it.) The suites are then FOUND in the worktree,
# so a test file the cook adds still runs; only the list of patterns comes from main.
$script:RepoConfigFile = 'kitchen.repo.json'
$script:RepoDefaultTests = @('tests/Test-*.ps1')
# folders a suite search never enters: git's own, dependencies, the kitchen's notes
$script:RepoWalkSkip = @('.git', 'node_modules', '.kitchen')

# Why a glob is not acceptable, or '' when it is. Relative and inside the repo: no drive letters or streams (':'), no leading slash,
# no segment that is '..' (also '.. ' or '...': Windows drops trailing dots and spaces, so those mean the same thing).
function Get-RepoGlobProblem([object]$Glob) {
    if ($Glob -isnot [string]) { return 'is not a string' }
    if ([string]::IsNullOrWhiteSpace($Glob)) { return 'is empty' }
    if ($Glob.Length -gt 260) { return 'is longer than 260 characters' }
    if ($Glob -match '[\x00-\x1f]') { return 'contains a control character' }
    $n = $Glob.Replace('\', '/')
    if ($n.StartsWith('/')) { return 'is an absolute path; globs are relative to the repository root' }
    if ($n.Contains(':')) { return "contains ':' (a drive letter or a stream name); globs are relative to the repository root" }
    foreach ($seg in $n.Split('/')) {
        if ($seg -ne '.' -and $seg.Length -gt 0 -and $seg.TrimEnd(' ', '.').Length -eq 0) { return "has a '..' segment (or one made of dots and spaces); a glob must stay inside the repository" }
    }
    ''
}

# '/'-separated, no leading './', no empty segments: one spelling for matching
function ConvertTo-RepoGlob([string]$Glob) { (@($Glob.Replace('\', '/').Split('/') | Where-Object { $_ -and $_ -ne '.' }) -join '/') + $(if ($Glob.Replace('\', '/').EndsWith('/')) { '/' } else { '' }) }

# glob -> anchored regex (case-insensitive: NTFS is). A trailing / means "everything under it".
function ConvertTo-RepoGlobRegex([string]$Glob) {
    $g = ConvertTo-RepoGlob $Glob; if ($g.EndsWith('/')) { $g += '**' }
    $sb = [Text.StringBuilder]::new('(?i)^')
    for ($i = 0; $i -lt $g.Length; $i++) {
        $c = $g[$i]
        if ($c -eq '*' -and $i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
            $i++
            if ($i + 1 -lt $g.Length -and $g[$i + 1] -eq '/') { $i++; [void]$sb.Append('(?:.*/)?') } else { [void]$sb.Append('.*') }
        }
        elseif ($c -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
    }
    [void]$sb.Append('$'); $sb.ToString()
}

# The main checkout a path belongs to: the folder itself when it is a main checkout (or not a git folder at all, as in a test
# fixture), the checkout the worktree was made from when it is a linked worktree. Asked of git, not of a file inside the worktree
# (.kitchen\REPO is the cook's to edit; git's common dir sits in the real repository's .git, which the cook's tools do not reach).
# Throws when git cannot say: the caller must not guess a place to read the policy from.
function Get-RepoMainCheckout([string]$Dir) {
    $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath (Join-Path $full '.git'))) { return $full }
    $gd = [string](& git -C $full rev-parse --path-format=absolute --git-dir 2>$null); $c1 = $LASTEXITCODE
    $cd = [string](& git -C $full rev-parse --path-format=absolute --git-common-dir 2>$null); $c2 = $LASTEXITCODE
    if ($c1 -or $c2 -or -not $gd -or -not $cd) { throw "repo-config: git could not tell where the main checkout of $full is; nothing guessed" }
    $norm = { param($p) [IO.Path]::GetFullPath(($p.Trim() -replace '/', '\')).TrimEnd('\').ToLowerInvariant() }
    if ((& $norm $gd) -eq (& $norm $cd)) { return $full }   # not a linked worktree: this is the main checkout
    $commonFull = [IO.Path]::GetFullPath(($cd.Trim() -replace '/', '\')).TrimEnd('\')
    if ((Split-Path -Leaf $commonFull) -ne '.git') { throw "repo-config: the main checkout of $full is not next to its git folder ($commonFull); nothing guessed" }
    Split-Path -Parent $commonFull
}

# commitBudget.bySize -> @{ S|M|L = @{ Files; Lines } } (0 = not set); $Bad throws the config's own error message.
function Read-RepoBySize($Value, [scriptblock]$Bad) {
    if ($Value -isnot [pscustomobject]) { & $Bad "'commitBudget.bySize' must be an object with S, M and/or L, each { ""files"", ""lines"" }" }
    $out = @{}
    foreach ($sp in $Value.PSObject.Properties) {
        $sz = $sp.Name.ToUpperInvariant()
        if ($sz -notin 'S', 'M', 'L') { & $Bad "'commitBudget.bySize' key '$($sp.Name)' must be S, M or L" }
        if ($sp.Value -isnot [pscustomobject]) { & $Bad "'commitBudget.bySize.$sz' must be an object with whole-number 'files' and/or 'lines'" }
        $lim = @{ Files = 0; Lines = 0 }
        foreach ($k in @(@('files', 50), @('lines', 3000))) {
            $v = $sp.Value.PSObject.Properties | Where-Object { $_.Name -ieq $k[0] } | Select-Object -First 1
            if (-not $v) { continue }
            $x = $v.Value; $ok = ($x -is [int] -or $x -is [long] -or ($x -is [double] -and $x -eq [math]::Floor($x)))
            if (-not $ok -or $x -lt 1 -or $x -gt $k[1]) { & $Bad "'commitBudget.bySize.$sz.$($k[0])' must be a whole number from 1 to $($k[1]) (got '$x')" }
            if ($k[0] -eq 'files') { $lim.Files = [int]$x } else { $lim.Lines = [int]$x }
        }
        if (-not $lim.Files -and -not $lim.Lines) { & $Bad "'commitBudget.bySize.$sz' needs 'files' and/or 'lines'" }
        $out[$sz] = $lim
    }
    $out
}
# Reads and validates <Root>\kitchen.repo.json. Throws a message naming the file and the key on anything wrong. Absent file = defaults.
function Read-RepoConfig([string]$Root) {
    $path = Join-Path $Root $script:RepoConfigFile
    $cfg = [pscustomobject]@{ Present = $false; Path = $path; Root = $Root; Tests = @($script:RepoDefaultTests); TestsGiven = $false; TestTimeoutSec = 0; Github = ''; Protected = @(); CommitFiles = 0; CommitLines = 0; CommitExclude = @(); CommitBySize = @{}; Roadmap = ''; Freeze = @() }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $cfg }
    $bad = { param($msg) throw "$($script:RepoConfigFile) ($path): $msg" }
    try { $j = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop } catch { & $bad "is not valid JSON ($($_.Exception.Message))" }
    if ($j -isnot [pscustomobject]) { & $bad 'must be a JSON object' }
    $get = { param($name) $p = $j.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1; if ($p) { , $p.Value } else { $null } }
    $cfg.Present = $true
    $tests = & $get 'tests'
    if ($null -ne $tests) {
        $t = @($tests)
        if ($tests -is [string] -or $t.Count -eq 0 -or $t.Count -gt 50) { & $bad "'tests' must be a list of 1 to 50 relative paths or globs" }
        $norm = foreach ($g in $t) {
            $why = Get-RepoGlobProblem $g; if ($why) { & $bad "'tests' entry '$g' $why" }
            $n = ConvertTo-RepoGlob $g
            if ($n -notmatch '(?i)\.ps1$') { & $bad "'tests' entry '$g' must end in .ps1 (suites are run with pwsh -File)" }
            $n
        }
        $cfg.Tests = @($norm | Select-Object -Unique); $cfg.TestsGiven = $true
    }
    $to = & $get 'testTimeoutSec'
    if ($null -ne $to) {
        $ok = ($to -is [int] -or $to -is [long] -or ($to -is [double] -and $to -eq [math]::Floor($to)))
        if (-not $ok -or $to -lt 1 -or $to -gt 3600) { & $bad "'testTimeoutSec' must be a whole number of seconds from 1 to 3600 (got '$to')" }
        $cfg.TestTimeoutSec = [int]$to
    }
    $gh = & $get 'github'
    if ($null -ne $gh) {
        if ($gh -isnot [string] -or $gh -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { & $bad "'github' must look like owner/name (got '$gh')" }
        $cfg.Github = $gh
    }
    $pr = & $get 'protected'
    if ($null -ne $pr) {
        if ($pr -is [string]) { & $bad "'protected' must be a list of relative paths or globs" }
        $p = @($pr); if ($p.Count -gt 200) { & $bad "'protected' has more than 200 entries" }
        $norm = foreach ($g in $p) { $why = Get-RepoGlobProblem $g; if ($why) { & $bad "'protected' entry '$g' $why" }; ConvertTo-RepoGlob $g }
        $cfg.Protected = @($norm | Select-Object -Unique)
    }
    $cb = & $get 'commitBudget'
    if ($null -ne $cb) {
        if ($cb -isnot [pscustomobject]) { & $bad "'commitBudget' must be an object with whole-number 'files' and 'lines'" }
        foreach ($k in @(@('files', 50), @('lines', 3000))) {
            $v = $cb.PSObject.Properties | Where-Object { $_.Name -ieq $k[0] } | Select-Object -First 1
            if (-not $v) { continue }
            $x = $v.Value; $ok = ($x -is [int] -or $x -is [long] -or ($x -is [double] -and $x -eq [math]::Floor($x)))
            if (-not $ok -or $x -lt 1 -or $x -gt $k[1]) { & $bad "'commitBudget.$($k[0])' must be a whole number from 1 to $($k[1]) (got '$x')" }
            if ($k[0] -eq 'files') { $cfg.CommitFiles = [int]$x } else { $cfg.CommitLines = [int]$x }
        }
        $ex = $cb.PSObject.Properties | Where-Object { $_.Name -ieq 'exclude' } | Select-Object -First 1
        if ($ex) {
            $e = @($ex.Value); if ($ex.Value -is [string] -or $null -eq $ex.Value -or $e.Count -gt 20) { & $bad "'commitBudget.exclude' must be a list of up to 20 relative folders or globs" }
            $norm = foreach ($g in $e) { $why = Get-RepoGlobProblem $g; if ($why) { & $bad "'commitBudget.exclude' entry '$g' $why" }; ConvertTo-RepoGlob $g }
            $cfg.CommitExclude = @($norm | Where-Object { $_ } | Select-Object -Unique)
        }
        $bs = $cb.PSObject.Properties | Where-Object { $_.Name -ieq 'bySize' } | Select-Object -First 1
        if ($bs) { $cfg.CommitBySize = Read-RepoBySize $bs.Value $bad }
    }
    $rm = & $get 'roadmap'
    if ($null -ne $rm) {
        $why = Get-RepoGlobProblem $rm; if ($why) { & $bad "'roadmap' '$rm' $why" }
        if ($rm -match '[*?]' -or $rm -notmatch '(?i)\.json$') { & $bad "'roadmap' must be one relative path to a .json file, no wildcards (got '$rm')" }
        $cfg.Roadmap = ConvertTo-RepoGlob $rm
    }
    $fz = & $get 'freeze'
    if ($null -ne $fz) {
        if ($fz -is [string] -or $fz -is [pscustomobject]) { & $bad "'freeze' must be a list of windows, each {""from"", ""to"", ""why""}" }
        $w = @($fz); if ($w.Count -gt 50) { & $bad "'freeze' has more than 50 windows" }
        $cfg.Freeze = @(for ($i = 0; $i -lt $w.Count; $i++) {
                $e = $w[$i]; $at = "'freeze[$i]"
                if ($e -isnot [pscustomobject]) { & $bad "$at' must be an object with ""from"", ""to"" and ""why""" }
                $ev = @{}; foreach ($k in 'from', 'to', 'why') { $p = $e.PSObject.Properties | Where-Object { $_.Name -ieq $k } | Select-Object -First 1; $ev[$k] = if ($p) { $p.Value } else { $null } }
                $t = @{}
                foreach ($k in 'from', 'to') {
                    if ($null -eq $ev[$k]) { & $bad "$at.$k' is missing (a local date and time like 2026-10-27T00:00)" }
                    $t[$k] = ConvertTo-FreezeTime $ev[$k]
                    if ($null -eq $t[$k]) { & $bad "$at.$k' must be a date and time like 2026-10-27T00:00 (got '$($ev[$k])')" }
                }
                if ($t.to -le $t.from) { & $bad "$at.to' ($($ev.to)) must be after its 'from' ($($ev.from))" }
                $why = $ev.why
                if ($why -isnot [string] -or [string]::IsNullOrWhiteSpace($why) -or $why.Length -gt 200 -or $why -match '[\x00-\x1f]') { & $bad "$at.why' must be a short reason, 1 to 200 characters on one line" }
                [pscustomobject]@{ From = $t.from; To = $t.to; Why = $why.Trim() }
            })
    }
    $cfg
}

# A freeze window's time as a DateTimeOffset, or $null when it is not one. Strings: yyyy-MM-ddTHH:mm[:ss] in this PC's local time,
# or with an offset (-06:00, Z). ConvertFrom-Json may already have made a DateTime of it (with seconds): Unspecified = local time.
function ConvertTo-FreezeTime($Value) {
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new($Value) }
    if ($Value -isnot [string]) { return $null }
    $out = [DateTimeOffset]::MinValue
    $fmts = [string[]]@('yyyy-MM-ddTHH:mm', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mmK', 'yyyy-MM-ddTHH:mm:ssK')
    if ([DateTimeOffset]::TryParseExact($Value.Trim(), $fmts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$out)) { return $out }
    $null
}

# The config that governs <Dir> (a main checkout or any worktree of it): read from the main checkout (see the top of this file).
function Get-RepoConfig([string]$Dir) {
    $main = Get-RepoMainCheckout $Dir
    $cfg = Read-RepoConfig $main
    $cfg | Add-Member -NotePropertyName Main -NotePropertyValue $main -Force
    $cfg
}

# One order's commit budget from a config (Read-RepoConfig/Get-RepoConfig) and its size (S, M or L; anything else counts as M):
# bySize[size] first, then the flat files/lines (which are the M default), then 0 = the station's own default. From = where it came from.
function Get-RepoCommitBudget($Cfg, [string]$Size) {
    $sz = "$Size".Trim().ToUpperInvariant(); if ($sz -notin 'S', 'M', 'L') { $sz = 'M' }
    $by = if ($Cfg -and $Cfg.CommitBySize) { $Cfg.CommitBySize[$sz] } else { $null }
    $files = if ($by -and $by.Files) { $by.Files } else { [int]$Cfg.CommitFiles }
    $lines = if ($by -and $by.Lines) { $by.Lines } else { [int]$Cfg.CommitLines }
    [pscustomobject]@{ Size = $sz; Files = $files; Lines = $lines; From = $(if ($by) { "commitBudget.bySize.$sz" } elseif ($files -or $lines) { 'commitBudget' } else { 'station default' }) }
}

function Test-RepoReparse($Info) { [bool]($Info.Attributes -band [IO.FileAttributes]::ReparsePoint) }

# Files under <Root>\<StartRel>, skipping links (a junction could lead out of the repo) and the folders in RepoWalkSkip.
# MaxDepth = how many levels below the start a file may sit (-1 = any).
function Get-RepoWalk([string]$Root, [string]$StartRel, [int]$MaxDepth) {
    $start = if ($StartRel) { Join-Path $Root $StartRel } else { $Root }
    if (-not (Test-Path -LiteralPath $start -PathType Container)) { return }
    $stack = [Collections.Generic.Stack[object]]::new(); $stack.Push(@([IO.DirectoryInfo]::new($start), 1))
    while ($stack.Count) {
        $top = $stack.Pop(); $di = $top[0]; $depth = $top[1]
        foreach ($e in $di.EnumerateFileSystemInfos()) {
            if (Test-RepoReparse $e) { continue }
            if ($e -is [IO.DirectoryInfo]) { if ($e.Name -notin $script:RepoWalkSkip -and ($MaxDepth -lt 0 -or $depth -lt $MaxDepth)) { $stack.Push(@($e, ($depth + 1))) } }
            else { $e }
        }
    }
}

# The suite files the patterns name inside <Dir> (the job's worktree, or main). Returns @{ Suites = FileInfo[] (each with .Rel, '/'-separated);
# Unmatched = patterns that matched nothing }. A pattern with no match is reported, never skipped: a cook that deletes a suite must
# make the run fail, not shrink it.
function Resolve-RepoSuites([string]$Dir, [string[]]$Patterns) {
    $root = [IO.Path]::GetFullPath($Dir).TrimEnd('\', '/'); $rootSlash = $root + '\'
    $found = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase); $unmatched = @()
    foreach ($pat in $Patterns) {
        $g = ConvertTo-RepoGlob $pat; $segs = $g.Split('/'); $hits = 0
        $firstWild = -1; for ($i = 0; $i -lt $segs.Count; $i++) { if ($segs[$i] -match '[*?]') { $firstWild = $i; break } }
        if ($firstWild -lt 0) {
            $full = [IO.Path]::GetFullPath((Join-Path $root ($g -replace '/', '\')))
            if ($full.StartsWith($rootSlash, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Leaf)) {
                $fi = [IO.FileInfo]::new($full); if (-not (Test-RepoReparse $fi)) { $cand = @($fi) } else { $cand = @() }
            } else { $cand = @() }
        } else {
            $startRel = ($segs[0..($firstWild - 1)] -join '\'); if ($firstWild -eq 0) { $startRel = '' }
            $depth = if ($g.Contains('**')) { -1 } else { $segs.Count - $firstWild }
            $re = [regex]::new((ConvertTo-RepoGlobRegex $g))
            $cand = @(Get-RepoWalk $root $startRel $depth | Where-Object { $re.IsMatch($_.FullName.Substring($rootSlash.Length).Replace('\', '/')) })
        }
        foreach ($f in $cand) {
            if (-not $f.FullName.StartsWith($rootSlash, [StringComparison]::OrdinalIgnoreCase)) { continue }   # never outside the repo
            $hits++
            if (-not $found.ContainsKey($f.FullName)) { $f | Add-Member -NotePropertyName Rel -NotePropertyValue $f.FullName.Substring($rootSlash.Length).Replace('\', '/') -Force; $found[$f.FullName] = $f }
        }
        if (-not $hits) { $unmatched += $pat }
    }
    @{ Suites = @($found.Values | Sort-Object Name, FullName); Unmatched = @($unmatched) }
}

# The repo's protected globs: its own list from kitchen.repo.json (read from the main checkout) plus the file itself, which is
# always protected: it decides which tests run and what auto-merge may take. Throws on a bad config (auto-merge must then ASK).
function Get-RepoProtected([string]$Repo) {
    $cfg = Get-RepoConfig $Repo
    @(@($script:RepoConfigFile) + @($cfg.Protected) | Select-Object -Unique)
}

# The same as regexes for `$path -match $re` on git's '/'-separated paths. A glob also covers everything below a folder it names.
function Get-RepoProtectedRegex([string]$Repo) {
    @(Get-RepoProtected $Repo | ForEach-Object { $r = ConvertTo-RepoGlobRegex ($_.TrimEnd('/')); $r.Substring(0, $r.Length - 1) + '(?:/.*)?$' })
}

# The branch merges land on: origin/HEAD when the repo has one and the local branch exists, else main, else master. '' when none of
# those exist (callers refuse: never merge into a branch the kitchen only guessed).
function Get-RepoDefaultBranch([string]$Repo) {
    $o = [string](& git -C $Repo symbolic-ref --short refs/remotes/origin/HEAD 2>$null)
    if ($o -match '^origin/(.+)$') { $b = $Matches[1].Trim(); if (& git -C $Repo rev-parse --verify --quiet "refs/heads/$b" 2>$null) { return $b } }
    foreach ($b in 'main', 'master') { if (& git -C $Repo rev-parse --verify --quiet "refs/heads/$b" 2>$null) { return $b } }
    ''
}
