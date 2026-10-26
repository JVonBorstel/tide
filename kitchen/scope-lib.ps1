# Dot-source: scope control for roadmap-item orders (station scope-check, the commit and pr stations; tests/Test-ScopeCheck.ps1).
# The scope record says which files outside its roadmap owns an order may change because scope-check widened them. Its trusted copy
# lives in the kitchen (<kitchen>\scope\<job>.json), outside the job's worktree, where the cooks cannot edit it; the worktree's
# .kitchen\SCOPE.json is the same record for people and the taster to read. The commit station trusts only the kitchen copy.
# No dependencies: pure helpers plus small file reads and writes.

$script:ScopeSizes = @('S', 'M', 'L')

function Get-ScopeRecordPath([string]$KitchenRoot, [string]$Job) { Join-Path $KitchenRoot "scope\$Job.json" }

# The kitchen copy of a job's scope record, or $null when there is none (or it cannot be read: then nothing is widened).
function Read-ScopeRecord([string]$KitchenRoot, [string]$Job) {
    $p = Get-ScopeRecordPath $KitchenRoot $Job
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json } catch { $null }
}

# An order's size: its own size var (S, M or L), else its roadmap item's size, else M. From = order | roadmap | default.
function Get-OrderSize($JobJson, $Item = $null) {
    $v = if ($JobJson -and $JobJson.vars) { "$($JobJson.vars.size)".Trim().ToUpperInvariant() } else { '' }
    if ($v -in $script:ScopeSizes) { return [pscustomobject]@{ Size = $v; From = 'order' } }
    $r = if ($Item) { "$($Item.size)".Trim().ToUpperInvariant() } else { '' }
    if ($r -in $script:ScopeSizes) { return [pscustomobject]@{ Size = $r; From = 'roadmap' } }
    [pscustomobject]@{ Size = 'M'; From = 'default' }
}

# The files a plan says it will change: the list under its "## Files to change" heading (any heading level), one repo-relative path
# per list line ("- `src/a.py` - why"; the first word, backticks dropped). Throws when the heading is missing, the list is empty, or a
# line names a glob or a path outside the repo: the station must stop loudly, never guess the files from the prose.
function Get-PlanFiles([string]$Text) {
    $lines = @($Text -split "`r?`n"); $at = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*#{1,6}\s*Files to change\b') { $at = $i; break } }
    if ($at -lt 0) { throw "the plan has no '## Files to change' section (one repo-relative path per line); nothing checked" }
    $out = [Collections.Generic.List[string]]::new()
    for ($i = $at + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*#{1,6}\s') { break }
        if ($l -notmatch '^\s*(?:[-*+]|\d+[.)])\s+(.+)$') { continue }
        $rest = $Matches[1].Trim()
        $tok = if ($rest -match '^`([^`]+)`') { $Matches[1].Trim() } else { ($rest -split '\s+')[0].TrimEnd(':', ',', ';') }
        if ($tok -match '^\(?none\)?$') { continue }
        if ($tok -match '[*?]') { throw "the plan's 'Files to change' names a glob ($tok); name each file" }
        $n = $tok.Replace('\', '/')
        if ($n.StartsWith('/') -or $n.Contains(':') -or @($n.Split('/') | Where-Object { $_ -ne '.' -and $_.Length -gt 0 -and $_.TrimEnd(' ', '.').Length -eq 0 }).Count) {
            throw "the plan's 'Files to change' names a path outside the repository ($tok)"
        }
        $n = (@($n.Split('/') | Where-Object { $_ -and $_ -ne '.' }) -join '/')
        if ($n -and -not ($out | Where-Object { $_ -ieq $n })) { $out.Add($n) }
    }
    if (-not $out.Count) { throw "the plan's 'Files to change' section lists no files; nothing checked" }
    $out.ToArray()
}

# The roadmap text with $Add appended to item $Id's "owns" list, edited in place so the diff is only the new lines (the file's own
# layout and line endings are kept). Throws when the item or its owns list cannot be found exactly once.
function Add-RoadmapOwnsText([string]$Text, [string]$Id, [string[]]$Add) {
    $m = [regex]::Matches($Text, '"id"\s*:\s*"' + [regex]::Escape($Id) + '"', 'IgnoreCase')
    if ($m.Count -ne 1) { throw "item $Id appears $($m.Count) times as an id in the roadmap text" }
    # the object that holds that id: walk the braces outside strings
    $stack = [Collections.Generic.Stack[int]]::new(); $inStr = $false; $objStart = -1; $objEnd = -1
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inStr) { if ($c -eq '\') { $i++ } elseif ($c -eq '"') { $inStr = $false }; continue }
        if ($c -eq '"') { if ($i -eq $m[0].Index -and $stack.Count) { $objStart = $stack.Peek() }; $inStr = $true; continue }
        if ($c -eq '{') { $stack.Push($i) }
        elseif ($c -eq '}') { if (-not $stack.Count) { break }; if ($stack.Pop() -eq $objStart) { $objEnd = $i; break } }
    }
    if ($objStart -lt 0 -or $objEnd -lt 0) { throw "item $Id's object could not be found in the roadmap text" }
    $ow = [regex]::Matches($Text.Substring($objStart, $objEnd - $objStart + 1), '"owns"\s*:\s*\[')
    if ($ow.Count -ne 1) { throw "item $Id has $($ow.Count) 'owns' lists in the roadmap text" }
    $open = $objStart + $ow[0].Index + $ow[0].Length - 1; $close = -1; $inStr = $false
    for ($i = $open + 1; $i -lt $objEnd; $i++) {
        $c = $Text[$i]
        if ($inStr) { if ($c -eq '\') { $i++ } elseif ($c -eq '"') { $inStr = $false }; continue }
        if ($c -eq '"') { $inStr = $true } elseif ($c -eq ']') { $close = $i; break }
    }
    if ($close -lt 0) { throw "item $Id's 'owns' list is not closed in the roadmap text" }
    $last = $close - 1; while ($last -gt $open -and [char]::IsWhiteSpace($Text[$last])) { $last-- }
    if ($last -le $open) { throw "item $Id's 'owns' list is empty in the roadmap text" }
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $multi = $Text.Substring($open, $close - $open).Contains("`n")
    $lineStart = $Text.LastIndexOf("`n", $last) + 1
    $indent = ([regex]::Match($Text.Substring($lineStart), '^[ \t]*')).Value
    $ins = foreach ($a in $Add) { $q = ConvertTo-Json -InputObject ([string]$a) -Compress; if ($multi) { ",$nl$indent$q" } else { ", $q" } }
    $Text.Substring(0, $last + 1) + ($ins -join '') + $Text.Substring($last + 1)
}

# One line in the kitchen's events.jsonl (append-only): scope.widen / scope.stop, so later plans can learn from them. Best effort.
function Write-ScopeEvent([string]$KitchenRoot, [string]$Type, [string]$Job, [hashtable]$Data) {
    $ev = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); type = $Type; job = $Job }
    foreach ($k in $Data.Keys) { $ev[$k] = $Data[$k] }
    try { Add-Content -LiteralPath (Join-Path $KitchenRoot 'events.jsonl') -Value ($ev | ConvertTo-Json -Compress -Depth 5) -Encoding utf8 } catch { }
}
