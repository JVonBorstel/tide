# Owns the old-names guard of the Tide rename: reports kitchen words (GLOSSARY.md old names) in display text that a change adds.
# Called by the ci.yml "quality" job (-Base HEAD^1, report only), tests/Test-Names.ps1 (temp git fixtures only) and by hand.
#   pwsh -File scripts/check-names.ps1 -Base <git ref> [-Root <repo>] [-Allow <json>] [-Baseline <json>] [-Summary <markdown file>]
#        [-Enforce] [-Branch <head ref>]          (check the lines added since -Base)
#   pwsh -File scripts/check-names.ps1 -WriteBaseline [-Root <repo>]   (record today's old words per file in scripts/names-baseline.json)
# Display text only: string and template text in pass-app/public/*.js and *.html (tag text and title/aria-label/alt/placeholder/content
# values), and Markdown prose outside code spans and fences. Identifiers, comments, regex literals and RegExp() sources, one-token
# lowercase literals (keys, stored statuses, event types), paths, dotted and kebab/snake names and the scripts/names-allow.json tokens
# are never matched. Words are whole words, case-insensitive. A hit in a file whose count of that word is not above names-baseline.json
# is KNOWN (an edited line that kept its word); any other hit is FOUND. Baseline entries only shrink, the same rule as lint-baseline.json.
# Exit: 0 report only (always, unless -Enforce); 1 with -Enforce and FOUND hits, unless -Branch is kitchen/J<n> with n <= exemptThrough;
# 2 bad input (no -Base, a ref git cannot resolve, not a git repository, unreadable allow or baseline file).
# A root commit (no parent) with -Base <ref>^1 is compared with the empty tree, with a NOTE line; a shallow clone's cut-off commit is not a root.
param([string]$Base = '', [string]$Root = '', [string]$Allow = '', [string]$Baseline = '', [string]$Summary = '', [switch]$Enforce,
    [string]$Branch = $env:GITHUB_HEAD_REF, [switch]$WriteBaseline)
$ErrorActionPreference = 'Stop'

# ---- the allowlist ----
function ConvertTo-NamesGlobRegex([string]$Glob) {
    $r = [regex]::Escape($Glob) -replace '\\\*\\\*/', '(?:.*/)?' -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*'
    "^$r$"
}
function Read-NamesAllow([string]$Path) {
    $j = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    $opt = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    $words = @(foreach ($w in $j.words) { [pscustomobject]@{ old = $w.old; new = $w.new; rx = [regex]::new("\b(?:$($w.pattern))\b", $opt) } })
    $tok = (@($j.tokens | ForEach-Object { "(?:$($_.pattern))" }) -join '|')
    [pscustomobject]@{
        words         = $words
        tokens        = if ($tok) { [regex]::new($tok, $opt) } else { $null }
        status        = [Collections.Generic.HashSet[string]]::new([string[]]@($j.statusValues))
        paths         = @($j.paths | ForEach-Object { [regex]::new((ConvertTo-NamesGlobRegex $_.glob), $opt) })
        exemptThrough = [int]$j.exemptThrough
    }
}
# 'js', 'html' or 'md' for a file the guard reads, $null for every other file and for the allowlisted paths.
function Get-NamesKind([string]$Rel, $A) {
    foreach ($p in $A.paths) { if ($p.IsMatch($Rel)) { return $null } }
    if ($Rel -match '^pass-app/public/.+\.js$') { return 'js' }
    if ($Rel -match '^pass-app/public/.+\.html$') { return 'html' }
    if ($Rel -match '\.md$') { return 'md' }
    $null
}

# ---- display text: a list of pieces @(index into the source, text); Get-NamesLines turns them into line -> text ----
# JavaScript is scanned, not matched with one regex: templates nest (${ `...${x}...` }) deeper than a regex can follow.
$script:OneToken = [regex]'^[a-z0-9][a-z0-9_.:/#-]*$'
$script:Selector = [regex]'^\S*[\[\]=#(){}<>/\\]\S*$'
$script:JsStops = [char[]]@("'", '"', '`', '/', '{', '}')
$script:TplStops = [char[]]@('`', '\', '$')
$script:RegexAfter = '(,=:[!&|?{};+-*%<>~^'
$script:RegexWords = @('return', 'typeof', 'case', 'in', 'of', 'delete', 'void', 'throw', 'new', 'instanceof', 'yield', 'await', 'else', 'do')

function Get-JsPieces([string]$Src, [int]$At, $A) {
    $st = @{ s = $Src; at = $At; out = [Collections.Generic.List[object]]::new(); A = $A }
    [void](Read-JsCode $st 0 $false)
    , $st.out
}
# Code from $i; strings, templates, comments and regex literals go to their readers. With $Stop it returns at the } closing a ${...}.
function Read-JsCode($St, [int]$i, [bool]$Stop) {
    $s = $St.s; $depth = 0
    while ($i -lt $s.Length) {
        $i = $s.IndexOfAny($script:JsStops, $i)
        if ($i -lt 0) { return $s.Length }
        $c = [string]$s[$i]
        if ($c -eq '{') { $depth++; $i++; continue }
        if ($c -eq '}') { if ($Stop -and $depth -eq 0) { return $i }; $depth--; $i++; continue }
        if ($c -eq '`') { $i = Read-JsTemplate $St ($i + 1); continue }
        if ($c -ne '/') { $i = Read-JsQuoted $St $i; continue }
        $n = if ($i + 1 -lt $s.Length) { [string]$s[$i + 1] } else { '' }
        if ($n -eq '/') { $i = $s.IndexOf("`n", $i); if ($i -lt 0) { return $s.Length }; continue }
        if ($n -eq '*') { $e = $s.IndexOf('*/', $i + 2); if ($e -lt 0) { return $s.Length }; $i = $e + 2; continue }
        if (Test-JsRegexStart $s $i) { $i = Read-JsRegex $s ($i + 1) } else { $i++ }
    }
    $s.Length
}
# A '...' or "..." string. Not display text: a RegExp('...') source, one lowercase token (a key, status or event type), a selector or path.
function Read-JsQuoted($St, [int]$i) {
    $s = $St.s; $stops = [char[]]@($s[$i], '\', "`n"); $j = $i + 1; $end = $s.Length
    while ($j -lt $s.Length) {
        $k = $s.IndexOfAny($stops, $j)
        if ($k -lt 0) { break }
        if ($s[$k] -eq '\') { $j = $k + 2; continue }
        $end = $k; break
    }
    $body = $s.Substring($i + 1, [Math]::Max(0, $end - $i - 1))
    $code = (Test-JsCodeContext $s $i) -or $script:OneToken.IsMatch($body) -or $script:Selector.IsMatch($body) -or $St.A.status.Contains($body)
    if (-not $code) { Add-JsPiece $St ($i + 1) $body }
    $end + 1
}
# A template literal: its text chunks are display text; each ${...} is code again (read by Read-JsCode up to its closing brace).
function Read-JsTemplate($St, [int]$i) {
    $s = $St.s; $chunks = [Collections.Generic.List[object]]::new(); $from = $i; $j = $i; $exprs = 0; $end = $s.Length
    $code = Test-JsCodeContext $s ($i - 1)
    while ($j -lt $s.Length) {
        $k = $s.IndexOfAny($script:TplStops, $j)
        if ($k -lt 0) { break }
        $c = [string]$s[$k]
        if ($c -eq '\') { $j = $k + 2; continue }
        if ($c -eq '`') { $end = $k; break }
        if ($k + 1 -ge $s.Length -or $s[$k + 1] -ne '{') { $j = $k + 1; continue }
        $chunks.Add(@($from, $s.Substring($from, $k - $from))); $exprs++
        $j = (Read-JsCode $St ($k + 2) $true) + 1; $from = $j
    }
    $from = [Math]::Min($from, $s.Length); $chunks.Add(@($from, $s.Substring($from, [Math]::Max(0, [Math]::Min($end, $s.Length) - $from))))
    # a template with no ${...} that is one lowercase token is a key, like a plain string
    if ($code -or ($exprs -eq 0 -and $script:OneToken.IsMatch($chunks[0][1]))) { return $end + 1 }
    foreach ($ch in $chunks) { if ($ch[1]) { Add-JsPiece $St $ch[0] $ch[1] } }
    $end + 1
}
# A string handed straight to a call that takes code, not words: a RegExp source, a selector, an element id, a class or id attribute.
$script:CodeCall = [regex]'(?:RegExp|querySelector(?:All)?|getElementById|closest|matches|addEventListener|classList\.(?:add|remove|toggle|contains)|\$)\(\s*$|className\s*\+?=\s*$|setAttribute\(\s*[''"](?:class|id|role|data-[\w-]+)[''"]\s*,\s*$'
function Test-JsCodeContext([string]$s, [int]$i) {
    $n = [Math]::Min(48, $i); $script:CodeCall.IsMatch($s.Substring($i - $n, $n))
}
# A / starts a regex literal after an operator, an opening bracket, a keyword like return, or at the start; otherwise it divides.
function Test-JsRegexStart([string]$s, [int]$i) {
    $p = $i - 1; while ($p -ge 0 -and [char]::IsWhiteSpace($s[$p])) { $p-- }
    if ($p -lt 0) { return $true }
    if ($script:RegexAfter.IndexOf($s[$p]) -ge 0) { return $true }
    $e = $p; while ($p -ge 0 -and [char]::IsLetter($s[$p])) { $p-- }
    $e -gt $p -and $script:RegexWords -ccontains $s.Substring($p + 1, $e - $p)
}
function Read-JsRegex([string]$s, [int]$j) {
    $class = $false
    while ($j -lt $s.Length) {
        $c = $s[$j]
        if ($c -eq '\') { $j += 2; continue }
        if ($c -eq "`n") { return $j }
        if ($c -eq '[') { $class = $true } elseif ($c -eq ']') { $class = $false } elseif ($c -eq '/' -and -not $class) { return $j + 1 }
        $j++
    }
    $j
}
# HTML written inside a string is markup, not words: a whole tag becomes its title/aria-label/alt/placeholder/content values, and a tag
# cut by ${...} (an open "<div class=" at the end, an attribute tail ending in "> at the start) is dropped. Newlines are kept.
function Add-JsPiece($St, [int]$i, [string]$Text) {
    $keep = { param($m) (@($script:HtmlAttr.Matches($m.Value) | ForEach-Object { $_.Groups['v'].Value }) -join ' ') + (' ' + ("`n" * ($m.Value.Split("`n").Count - 1))) }
    $t = [regex]::Replace($Text, '<[A-Za-z/!][^<>]*>', $keep)
    $t = [regex]::Replace($t, '<[A-Za-z/][^<>]*$', $keep)
    $t = [regex]::Replace($t, '^[^<>]*["''][^<>]*>', $keep)
    $St.out.Add(@(($St.at + $i), $t))
}
$script:HtmlTok = [regex]::new('(?<c><!--[\s\S]*?-->)|(?<s><(?<n>script|style)\b[^>]*>(?<b>[\s\S]*?)</\k<n>\s*>)|(?<t><[^>]*>)', 'IgnoreCase')
$script:HtmlAttr = [regex]::new('(?<![\w-])(?:title|aria-label|alt|placeholder|content)\s*=\s*(?:"(?<v>[^"]*)"|''(?<v>[^'']*)'')', 'IgnoreCase')
function Get-HtmlPieces([string]$Src, $A) {
    $out = [Collections.Generic.List[object]]::new(); $pos = 0
    foreach ($m in $script:HtmlTok.Matches($Src)) {
        if ($m.Index -gt $pos) { $out.Add(@($pos, $Src.Substring($pos, $m.Index - $pos))) }
        $pos = $m.Index + $m.Length
        if ($m.Groups['s'].Success -and $m.Groups['n'].Value -ieq 'script') {
            $b = $m.Groups['b']; foreach ($p in (Get-JsPieces $b.Value $b.Index $A)) { $out.Add($p) }
        } elseif ($m.Groups['t'].Success) {
            foreach ($v in $script:HtmlAttr.Matches($m.Value)) { $g = $v.Groups['v']; $out.Add(@(($m.Index + $g.Index), $g.Value)) }
        }
    }
    if ($pos -lt $Src.Length) { $out.Add(@($pos, $Src.Substring($pos))) }
    , $out
}
# Markdown prose: line by line, fenced blocks dropped, then code spans, link targets, URLs, comments and tags removed.
function Get-MdLines([string]$Src) {
    $lines = @{}; $fence = $false; $n = 0
    foreach ($l in ($Src -split "`n")) {
        $n++
        if ($l -match '^\s{0,3}(```|~~~)') { $fence = -not $fence; continue }
        if ($fence) { continue }
        $t = $l -replace '(`+).*?\1', ' ' -replace '\]\([^)]*\)', '] ' -replace '<!--.*?-->', ' ' -replace 'https?://\S+', ' ' -replace '<[^>]+>', ' '
        if ($t.Trim()) { $lines[$n] = $t }
    }
    $lines
}
# Line starts of a source, so a piece index maps to its 1-based line (pieces that span lines are split there).
function Get-NamesLines([string]$Src, $Pieces) {
    $starts = [Collections.Generic.List[int]]::new(); $starts.Add(0)
    $i = $Src.IndexOf("`n"); while ($i -ge 0) { $starts.Add($i + 1); $i = $Src.IndexOf("`n", $i + 1) }
    $arr = $starts.ToArray(); $lines = @{}
    foreach ($p in $Pieces) {
        $r = [Array]::BinarySearch($arr, [int]$p[0]); $line = if ($r -ge 0) { $r + 1 } else { -bnot $r }
        foreach ($part in ($p[1] -split "`n")) {
            if ($part.Trim()) { $lines[$line] = "$($lines[$line]) $part" }
            $line++
        }
    }
    $lines
}

# ---- matching ----
# Names that are not display words: allow tokens, anything with a slash, dotted names, lowercase-kebab and snake names.
function Find-NamesWords([string]$Text, $A) {
    $t = $Text -replace "`r", ' '
    if ($A.tokens) { $t = $A.tokens.Replace($t, ' ') }
    $t = $t -replace '\S*[/\\]\S*', ' ' -replace '(?<!\w)[.#][A-Za-z][\w-]*', ' ' -replace '\b[\w-]+(?:\.[\w-]+)+\b', ' ' -creplace '(?<![\w-])[a-z0-9]+(?:-[a-z0-9]+)+(?![\w-])', ' ' -replace '\b\w*_\w*\b', ' '
    foreach ($w in $A.words) {
        $ms = $w.rx.Matches($t)
        if ($ms.Count -eq 0) { continue }
        for ($k = 0; $k -lt $ms.Count; $k++) { $w }
        $t = $w.rx.Replace($t, ' ')
    }
}
# Every old word in one file: a list of @{ line; old; new; text }.
function Get-NamesFileHits([string]$Path, [string]$Kind, $A) {
    $src = [IO.File]::ReadAllText($Path)
    $lines = switch ($Kind) {
        'js' { Get-NamesLines $src (Get-JsPieces $src 0 $A) }
        'html' { Get-NamesLines $src (Get-HtmlPieces $src $A) }
        default { Get-MdLines $src }
    }
    foreach ($n in ($lines.Keys | Sort-Object)) {
        foreach ($w in (Find-NamesWords $lines[$n] $A)) { [pscustomobject]@{ line = $n; old = $w.old; new = $w.new; text = $lines[$n].Trim() } }
    }
}
# The lines a change adds: rel path -> set of new-side line numbers, from git diff -U0 <Base> (the working tree against Base).
function Get-NamesAddedLines([string]$Root, [string]$Base) {
    $out = @(& git -C $Root -c core.quotepath=false diff -U0 --no-color --no-ext-diff $Base -- 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "git diff against $Base failed" }
    $added = [ordered]@{}; $cur = $null
    foreach ($l in $out) {
        if ($l.StartsWith('+++ ')) { $cur = if ($l -eq '+++ /dev/null') { $null } else { ($l.Substring(4).Trim('"')) -replace '^b/', '' }; continue }
        if ($null -eq $cur -or $l -notmatch '^@@ -\S+ \+(\d+)(?:,(\d+))? @@') { continue }
        $start = [int]$Matches[1]; $count = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
        if (-not $added.Contains($cur)) { $added[$cur] = [Collections.Generic.HashSet[int]]::new() }
        for ($k = 0; $k -lt $count; $k++) { [void]$added[$cur].Add($start + $k) }
    }
    $added
}
function Get-NamesCounts($Hits, [string]$Rel) {
    $c = @{}; foreach ($h in $Hits) { $k = "$($h.old)|$Rel"; $c[$k] = 1 + [int]$c[$k] }; $c
}

# ---- run ----
function Stop-Names([string]$Msg) { Write-Output "names: $Msg"; exit 2 }
if (-not $WriteBaseline -and -not $Base) { Stop-Names '-Base <git ref> is required: the commit the change is compared with (CI passes HEAD^1)' }
if (-not $Root) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not (Test-Path -LiteralPath $Root)) { Stop-Names "folder not found: $Root" }
if (-not $Allow) { $Allow = Join-Path $Root 'scripts/names-allow.json' }
if (-not $Baseline) { $Baseline = Join-Path $Root 'scripts/names-baseline.json' }
& git -C $Root rev-parse --show-toplevel 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-Names "$Root is not a git repository" }
try { $A = Read-NamesAllow $Allow } catch { Stop-Names "allow file missing or not valid: $Allow ($($_.Exception.Message))" }

if ($WriteBaseline) {
    $all = @{}
    foreach ($rel in @(& git -C $Root -c core.quotepath=false ls-files)) {
        $kind = Get-NamesKind $rel $A; $p = Join-Path $Root $rel
        if (-not $kind -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $c = Get-NamesCounts @(Get-NamesFileHits $p $kind $A) $rel; foreach ($k in $c.Keys) { $all[$k] = $c[$k] }
    }
    $sorted = [ordered]@{}; foreach ($k in ($all.Keys | Sort-Object)) { $sorted[$k] = $all[$k] }
    [ordered]@{
        note  = 'Old display words per file today, recorded by scripts/check-names.ps1 -WriteBaseline. word|file -> hits. Only shrink it: a line may be lowered or removed once the words are renamed; adding one needs Jordan''s review.'
        words = $sorted
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Baseline -Encoding utf8
    Write-Output "Names: baseline written with $($all.Count) word|file entries to $Baseline"
    exit 0
}

& git -C $Root rev-parse --verify --quiet "$Base^{commit}" 2>$null | Out-Null
$rootNote = ''
if ($LASTEXITCODE -ne 0) {
    # -Base <ref>^1 (also ^, ~, ~1) where <ref> is a root commit (a repo's first commit has no parent): compare with the empty tree, so
    # every line of the commit counts as added. The oldest commit of a shallow clone also shows no parent but has one: still bad input.
    $stem = if ($Base -match '^(.+?)(?:\^1?|~1?)$') { $Matches[1] } else { '' }
    $sha = if ($stem) { ([string](& git -C $Root rev-parse --verify --quiet "$stem^{commit}" 2>$null)).Trim() } else { '' }
    $isRoot = $false
    if ($sha) {
        $isRoot = @(([string](& git -C $Root rev-list --parents -n 1 $sha 2>$null)).Trim() -split '\s+').Count -eq 1
        $shallow = ([string](& git -C $Root rev-parse --git-path shallow 2>$null)).Trim()
        if ($shallow -and -not [IO.Path]::IsPathRooted($shallow)) { $shallow = Join-Path $Root $shallow }
        if ($isRoot -and $shallow -and (Test-Path -LiteralPath $shallow) -and @(Get-Content -LiteralPath $shallow) -contains $sha) { $isRoot = $false }
    }
    if (-not $isRoot) { Stop-Names "git cannot resolve -Base $Base (CI needs fetch-depth 2 for HEAD^1)" }
    $empty = [IO.Path]::GetTempFileName()   # a 0-byte file: its tree hash is the empty tree in this repo's hash format
    try { $tree = ([string](& git -C $Root hash-object -t tree $empty 2>$null)).Trim() } finally { Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue }
    if (-not $tree) { Stop-Names "git cannot resolve -Base $Base, and the empty tree could not be made for the root commit $stem" }
    $rootNote = "$stem ($($sha.Substring(0, 7))) is a root commit with no parent: -Base $Base is compared as the empty tree, so every line counts as added"
    Write-Output "NOTE: $rootNote"
    $Base = $tree
}
$was = @{}
if (Test-Path -LiteralPath $Baseline) {
    try { $bj = Get-Content -LiteralPath $Baseline -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { Stop-Names "baseline is not valid JSON: $Baseline" }
    if ($bj.words) { foreach ($k in $bj.words.Keys) { $was[$k] = [int]$bj.words[$k] } }
}
try { $added = Get-NamesAddedLines $Root $Base } catch { Stop-Names $_.Exception.Message }

$found = [Collections.Generic.List[object]]::new(); $known = 0; $files = 0; $lineCount = 0
foreach ($rel in $added.Keys) {
    $kind = Get-NamesKind $rel $A; $p = Join-Path $Root $rel
    if (-not $kind -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
    $files++; $lineCount += $added[$rel].Count
    $hits = @(Get-NamesFileHits $p $kind $A); $now = Get-NamesCounts $hits $rel
    foreach ($h in ($hits | Where-Object { $added[$rel].Contains($_.line) })) {
        $k = "$($h.old)|$rel"; $snip = if ($h.text.Length -gt 90) { $h.text.Substring(0, 90) + '...' } else { $h.text }
        if ($was.ContainsKey($k) -and $now[$k] -le $was[$k]) { $known++; Write-Output "KNOWN: ${rel}:$($h.line) `"$($h.old)`" (file has $($now[$k]), baseline $($was[$k])): $snip"; continue }
        $found.Add([pscustomobject]@{ rel = $rel; line = $h.line; old = $h.old; new = $h.new }); Write-Output "FOUND: ${rel}:$($h.line) `"$($h.old)`" (new name: $($h.new)): $snip"
    }
    foreach ($k in @($was.Keys | Where-Object { $_.EndsWith("|$rel") })) {
        if ([int]$now[$k] -lt $was[$k]) { Write-Output "NOTE: $($k -replace '\|', ' in ') is down from $($was[$k]) to $([int]$now[$k]); lower names-baseline.json" }
    }
}

$mode = 'report only'; $fail = $false
if ($Enforce) {
    $mode = 'enforce'; $fail = $found.Count -gt 0
    if ($Branch -match '^kitchen/J(\d+)$' -and [int]$Matches[1] -le $A.exemptThrough) {
        $mode = "report only ($Branch is at or below exemptThrough $($A.exemptThrough))"; $fail = $false
    }
}
$line = "Names: $mode; $files files and $lineCount added lines checked, $($found.Count + $known) old words ($known baselined), $($found.Count) new"
Write-Output $line
if ($Summary) {
    $md = @('', '## Old names (scripts/check-names.ps1)', '', "- $line")
    if ($rootNote) { $md += "- Note: $rootNote" }
    $md += @($found | Select-Object -First 30 | ForEach-Object { "- ``$($_.rel):$($_.line)`` ""$($_.old)"" -> $($_.new)" })
    Add-Content -LiteralPath $Summary -Value $md -Encoding utf8
}
exit ([int]$fail)
