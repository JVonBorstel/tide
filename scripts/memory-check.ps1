# Brain Monitor v0: deterministic health check of long-term and short-term memory. No model, no network, READ-ONLY on the brain.
#   pwsh -File scripts/memory-check.ps1 [-BrainPath <home>\gemini-brain] [-DataDir <dir>] [-Quiet]
# Exit 0 = no FAIL (WARNs may exist), 1 = at least one FAIL. A report is written to <DataDir>\reports\ (this repo's data\, git-ignored).
# Safety: never opens protected paths (their names are only counted), never prints a secret value (file:line + pattern name only),
# never writes into the brain, never follows links, never goes online.
param(
    [string]$BrainPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain'),
    [string]$DataDir = '',
    [int]$NowWarnDays = 3,
    [int]$NowFailDays = 7,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $repo 'data' }
$brain = (Resolve-Path $BrainPath).Path.TrimEnd('\')

# Paths named in the brain's own rules as off-limits (plus the employer firewall). Matched on relative path, forward slashes.
$protected = 'memory/evie', 'memory/user/finances', 'projects/life_admin', 'projects/evie_admin', 'memory/user/USER_IDENTITY.md', 'projects/naf'
$pruneDirs = '.git', 'node_modules', '.venv', 'venv', 'dist', 'build', '__pycache__', '.next'
$textExt = '.md', '.txt', '.json', '.yml', '.yaml', '.toml', '.ps1', '.py', '.js', '.ts', '.cfg', '.ini', '.sh'

function Test-Protected([string]$Rel) {
    foreach ($x in $protected) { if ($Rel -ieq $x -or $Rel.StartsWith("$x/", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

# ---------- enumerate (protected paths are skipped, never opened or listed) ----------
$files = [Collections.Generic.List[object]]::new(); $skipped = 0
$fileRel = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)   # plain files seen by the walk (the only ones ever read)
$dirRel = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)    # plain folders seen (pruned ones are listed, never entered)
$links = [Collections.Generic.List[string]]::new()                                            # reparse points (file or folder links): counted, never followed
$stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($brain)
while ($stack.Count) {
    $dir = $stack.Pop()
    foreach ($e in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
        $name = [IO.Path]::GetFileName($e)
        $rel = $e.Substring($brain.Length + 1).Replace('\', '/')
        if (Test-Protected $rel) { $skipped++; continue }
        if ([IO.File]::GetAttributes($e) -band [IO.FileAttributes]::ReparsePoint) { $links.Add($rel); continue }
        if ([IO.Directory]::Exists($e)) {
            [void]$dirRel.Add($rel)
            if ($name -in $pruneDirs) { continue }
            $stack.Push($e)
        } else { [void]$fileRel.Add($rel); $files.Add([pscustomobject]@{ Path = $e; Rel = $rel; Name = $name }) }
    }
}

$results = [Collections.Generic.List[object]]::new()
function Add-Result([string]$Level, [string]$Check, [string]$Message) { $results.Add([pscustomobject]@{ Level = $Level; Check = $Check; Message = $Message }) }
# Only reads a file the walk saw as a plain file; a link (or anything missing) gives $null and is never opened.
function Read-Lines([string]$Rel) { if ($fileRel.Contains($Rel)) { [IO.File]::ReadAllLines((Join-Path $brain $Rel)) } else { $null } }
if ($links.Count) { Add-Result 'WARN' 'link' "$($links.Count) link(s) in the brain not followed: $((($links | Select-Object -First 5)) -join ', ')" }

# ---------- C1 context budget ----------
$ctx = Read-Lines 'AGENT_CONTEXT.md'
if ($null -eq $ctx) { Add-Result 'FAIL' 'context' 'AGENT_CONTEXT.md is missing or a link (not read)' }
else {
    $bytes = (Get-Item (Join-Path $brain 'AGENT_CONTEXT.md')).Length
    if ($ctx.Count -gt 100) { Add-Result 'FAIL' 'context' "AGENT_CONTEXT.md has $($ctx.Count) lines (hard limit 100; it must stay about one page)" }
    elseif ($ctx.Count -gt 60 -or $bytes -gt 8000) { Add-Result 'WARN' 'context' "AGENT_CONTEXT.md is getting long ($($ctx.Count) lines, $bytes bytes; target under 60 lines)" }
    else { Add-Result 'OK' 'context' "AGENT_CONTEXT.md within budget ($($ctx.Count) lines, $bytes bytes)" }
}

# ---------- C2 short-term memory (NOW.md) ----------
$now = Read-Lines 'memory/NOW.md'
if ($null -eq $now) { Add-Result 'FAIL' 'now' 'memory/NOW.md is missing or a link (not read) (short-term memory)' }
else {
    $nowText = $now -join "`n"
    $m = [regex]::Match($nowText, 'Last updated:\s*(\d{4}-\d{2}-\d{2})')
    if (-not $m.Success) { Add-Result 'FAIL' 'now' 'NOW.md has no "Last updated: YYYY-MM-DD" stamp' }
    else {
        $age = ([datetime]::Today - [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $null)).Days
        if ($age -gt $NowFailDays) { Add-Result 'FAIL' 'now' "NOW.md is $age days old (limit $NowFailDays): short-term memory is stale" }
        elseif ($age -gt $NowWarnDays) { Add-Result 'WARN' 'now' "NOW.md is $age days old (refresh within $NowWarnDays)" }
        else { Add-Result 'OK' 'now' "NOW.md is fresh ($age day(s) old)" }
    }
    if ($now.Count -gt 40) { Add-Result 'WARN' 'now' "NOW.md has $($now.Count) lines (target 40 or fewer; trim finished items)" }
    foreach ($h in 'Directive', 'Active threads', 'Waiting on') { if ($nowText -notmatch "(?im)^#+\s*$h") { Add-Result 'WARN' 'now' "NOW.md has no '$h' section" } }
}

# ---------- C3 pointers in the two always-loaded files must resolve ----------
foreach ($src in 'AGENT_CONTEXT.md', 'memory/NOW.md') {
    $lines = Read-Lines $src; if ($null -eq $lines) { continue }
    $seen = @{}; $unsafe = 0
    foreach ($tok in [regex]::Matches(($lines -join "`n"), '`([^`\r\n]+)`') | ForEach-Object { $_.Groups[1].Value.Trim() }) {
        if ($tok -notmatch '^(memory|projects|knowledge_base|meta_cognition|agents|docs)/' -or $tok -match '[*\s<>]' -or $seen[$tok]) { continue }
        $seen[$tok] = $true
        # a pointer may not climb or leave the brain: '.'/'..' parts, backslashes and drive colons are counted, never echoed or checked
        if ($tok -match '[\\:]' -or @($tok.Split('/') | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count) { $unsafe++; continue }
        $relTok = $tok.TrimEnd('/')
        if (Test-Protected $relTok) { continue }
        # existence comes only from the walk's allow-lists; nothing on disk is probed
        if (-not ($fileRel.Contains($relTok) -or $dirRel.Contains($relTok))) { Add-Result 'WARN' 'pointer' "$src points to '$tok' which does not exist" }
    }
    if ($unsafe) { Add-Result 'WARN' 'pointer' "$src has $unsafe pointer(s) with unsafe path parts (., .., backslash or colon); not checked" }
}

# ---------- C4 secrets (value never printed) and secret-named files (never opened) ----------
. (Join-Path $PSScriptRoot 'secret-patterns.ps1')   # shared patterns: Find-SecretPattern
$secretHits = 0; $scanned = 0
foreach ($f in $files) {
    if ($f.Name -match '(?i)^\.env(\..+)?$' -and $f.Name -notmatch '(?i)^\.env\.(example|sample|template)$' -or $f.Name -match '(?i)\.(pem|pfx|p12|jks|keystore)$' -or $f.Name -match '^id_(rsa|ed25519|ecdsa)') {
        Add-Result 'FAIL' 'secret-file' "secret-type file present in the brain (not opened): $($f.Rel)"; $secretHits++; continue
    }
    if ([IO.Path]::GetExtension($f.Name).ToLowerInvariant() -notin $textExt) { continue }
    if ((Get-Item -LiteralPath $f.Path).Length -gt 1MB) { continue }
    $scanned++
    $i = 0
    foreach ($line in [IO.File]::ReadLines($f.Path)) {
        $i++
        if ($line.Length -gt 2000) { continue }
        $hit = Find-SecretPattern $line
        if ($hit) { Add-Result 'FAIL' 'secret' "$($f.Rel):$i looks like a secret ($hit); value not shown"; $secretHits++ }
    }
}
if (-not $secretHits) { Add-Result 'OK' 'secret' "no secret-looking content in $scanned text files" }

# ---------- C5 protected paths should be git-ignored (reads .gitignore only) ----------
$gi = Read-Lines '.gitignore'
if ($null -eq $gi) { Add-Result 'WARN' 'protected' 'brain has no .gitignore' }
else {
    $giText = $gi -join "`n"
    $missing = @($protected | Where-Object { $_ -ne 'projects/naf' -and $giText -notmatch [regex]::Escape($_) })
    if ($missing) { Add-Result 'WARN' 'protected' "not listed in .gitignore: $($missing -join ', ')" } else { Add-Result 'OK' 'protected' 'protected paths are listed in .gitignore' }
}

# ---------- C6 git hygiene ----------
if (Test-Path (Join-Path $brain '.git')) {
    $remotes = @(git -C $brain remote 2>$null)
    if ($remotes.Count) { Add-Result 'FAIL' 'git' "brain has git remote(s): $($remotes -join ', '); the brain must stay local-only" } else { Add-Result 'OK' 'git' 'brain has no git remote (local-only)' }
    $dirty = @(git -C $brain status --short 2>$null | Where-Object { $_ -notmatch '^\?\?' })
    if ($dirty.Count) { Add-Result 'WARN' 'git' "$($dirty.Count) tracked file(s) with uncommitted changes (commit after meaningful changes)" }
} else { Add-Result 'WARN' 'git' 'brain is not a git repository' }

# ---------- C7 stale long-term files ----------
$stale = @($files | Where-Object { $_.Rel -match '^memory/' -and [IO.Path]::GetExtension($_.Name) -eq '.md' } |
        Where-Object { ([datetime]::Today - (Get-Item -LiteralPath $_.Path).LastWriteTime.Date).Days -gt 60 })
if ($stale.Count) { Add-Result 'WARN' 'stale' "$($stale.Count) memory file(s) untouched for 60+ days, review: $((($stale | Select-Object -First 5).Rel) -join ', ')" } else { Add-Result 'OK' 'stale' 'no memory file untouched for 60+ days' }

# ---------- report ----------
$fail = @($results | Where-Object Level -eq 'FAIL').Count; $warn = @($results | Where-Object Level -eq 'WARN').Count
$summary = "SUMMARY: $fail FAIL, $warn WARN | scanned $scanned text files, skipped $skipped protected path(s) | brain: $brain"
$text = @("Brain Monitor v0 check, $((Get-Date).ToString('yyyy-MM-dd HH:mm'))") + ($results | ForEach-Object { '[{0}] {1}: {2}' -f $_.Level, $_.Check, $_.Message }) + $summary
$rd = Join-Path $DataDir 'reports'; New-Item -ItemType Directory -Force $rd | Out-Null
[IO.File]::WriteAllText((Join-Path $rd ("check-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))), ($text -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
if (-not $Quiet) { $text | ForEach-Object { Write-Host $_ } }
if ($fail) { exit 1 } else { exit 0 }
