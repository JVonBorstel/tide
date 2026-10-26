# Station: render tailored application pack (locked HTML print template -> headless Edge -> PDF) and update tracker.json.
#   step: {"station":"pack-render","args":{"AppId":"A1","DraftFile":"C:\\Users\\<you>\\gemini-brain\\projects\\career\\packs\\A1-draft.md"}}
# The resume HTML comes from the local model, which read employer-controlled text (posting, questions): it is treated as hostile.
# It is reduced to plain layout tags, the template carries a no-network Content-Security-Policy, and Edge prints it with scripts off,
# a throwaway profile and a dead proxy, so nothing on the page can reach the web or a local file. Nothing is ever submitted anywhere.
# -LockedFrom <canonical resume .md>: render Jordan's one locked resume (<career>\resume-locked.pdf) straight from his own markdown, no
#   model involved. resume-locked.json beside it records the source's sha256: while the source is unchanged the PDF is never re-rendered
#   (every apply packet carries its hash, so it must not drift); an edited source is rendered again (to a temp file, then swapped in),
#   so the edit reaches the next packet. -Locked alone uses kitchen.json "career".resume (Get-CareerFiles).
param([string]$AppId = '', [string]$DraftFile = '', [string]$LockedFrom = '', [switch]$Locked)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tracker-lib.ps1')
if ($Locked -and -not $LockedFrom) { $LockedFrom = (Get-CareerFiles).resume }

if (-not $LockedFrom -and $AppId -notmatch '^A\d{1,5}$') {
    Write-Output "pack-render: invalid AppId '$AppId'"
    $global:LASTEXITCODE = 2
    exit 2
}

$careerDir = if ($env:PASS_CAREER_DIR) { [IO.Path]::GetFullPath($env:PASS_CAREER_DIR) } else { (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'gemini-brain\projects\career') }

# Plain markdown -> plain layout HTML: every character is HTML-escaped first, then only headings, bullets, rules, bold and italics
# become tags. Links keep their words (and the address, so LinkedIn/GitHub stay readable on paper); the sanitizer below runs anyway.
function ConvertFrom-ResumeMarkdown([string]$md) {
    $out = [Collections.Generic.List[string]]::new(); $inList = $false
    $inline = { param([string]$t)
        $t = [Net.WebUtility]::HtmlEncode($t)
        $t = [regex]::Replace($t, '\[([^\]]+)\]\((?:https?://|mailto:)?([^)\s]+)\)', { param($m) if ($m.Groups[1].Value -like "*$($m.Groups[2].Value.Split('/')[0])*") { $m.Groups[1].Value } else { "$($m.Groups[1].Value) ($($m.Groups[2].Value))" } })
        $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '<strong>$1</strong>')
        [regex]::Replace($t, '(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', '<em>$1</em>') }
    foreach ($l in ($md -split '\r?\n')) {
        if ($l -match '^\s*[-*+]\s+(.*)$') { if (-not $inList) { $out.Add('<ul>'); $inList = $true }; $out.Add("<li>$(& $inline $Matches[1])</li>"); continue }
        if ($inList) { $out.Add('</ul>'); $inList = $false }
        if ($l -match '^\s*$') { continue }
        if ($l -match '^\s*(-{3,}|\*{3,}|_{3,})\s*$') { $out.Add('<hr>'); continue }
        if ($l -match '^(#{1,6})\s+(.*)$') { $n = [Math]::Min(3, $Matches[1].Length); $out.Add("<h$n>$(& $inline $Matches[2].Trim())</h$n>"); continue }
        $out.Add("<p>$(& $inline $l.Trim())</p>")
    }
    if ($inList) { $out.Add('</ul>') }
    $out -join "`n"
}
if ($LockedFrom) {
    if (-not (Test-Path -LiteralPath $LockedFrom -PathType Leaf)) { Write-Output "pack-render: canonical resume not found: $LockedFrom"; $global:LASTEXITCODE = 1; exit 1 }
    # one render of the locked resume at a time: two apply-preps at once (J162/J163, 2026-10-21) wrote the same draft and fought over
    # Edge's output. The second waits here, then finds the PDF up to date. Held until this process exits (an abandoned mutex counts).
    $script:lockedRender = [Threading.Mutex]::new($false, 'Global\brain-kitchen-resume-locked-render')
    $gotRender = $false; try { $gotRender = $script:lockedRender.WaitOne(180000) } catch [Threading.AbandonedMutexException] { $gotRender = $true }
    if (-not $gotRender) { Write-Output 'pack-render: another render of the locked resume is still running after 3 minutes; try again'; $global:LASTEXITCODE = 1; exit 1 }
    $srcSha = (Get-FileHash -LiteralPath $LockedFrom -Algorithm SHA256).Hash.ToLowerInvariant()
    $lockMeta = Join-Path $careerDir 'resume-locked.json'
    $was = try { [IO.File]::ReadAllText($lockMeta) | ConvertFrom-Json } catch { $null }
    if ((Test-Path -LiteralPath (Join-Path $careerDir 'resume-locked.pdf') -PathType Leaf) -and $was -and [string]$was.sourceSha256 -eq $srcSha) { Write-Output 'pack-render: the locked resume is up to date with its source; not re-rendered'; $global:LASTEXITCODE = 0; exit 0 }
    New-Item -ItemType Directory -Force -Path $careerDir | Out-Null
    $DraftFile = Join-Path $careerDir 'resume-locked-draft.md'; $AppId = 'resume-locked'
    Set-Content -LiteralPath $DraftFile -Encoding utf8 -Value ("# Resume HTML`n" + (ConvertFrom-ResumeMarkdown (Get-Content -LiteralPath $LockedFrom -Raw -Encoding utf8)))
}

# Resolve the draft. A named draft must exist; never fall back to another file (that could render the wrong resume).
# A relative name resolves only under the career folder, never against the worker's current folder (C:\Windows\System32 under the
# scheduled supervisor, or the code repo when run by hand).
$draftPath = $null
if ($DraftFile) {
    $sub = $DraftFile -replace '^[/\\]*(projects[/\\]career[/\\]|career[/\\])', ''
    $cands = if ([IO.Path]::IsPathRooted($DraftFile)) { @($DraftFile) } else { @((Join-Path $careerDir $DraftFile), (Join-Path $careerDir $sub)) }
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { $draftPath = (Resolve-Path -LiteralPath $c).Path; break }
    }
} else {
    $candidate = Join-Path $careerDir "packs\$AppId-draft.md"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $draftPath = (Resolve-Path -LiteralPath $candidate).Path }
}

if (-not $draftPath -or -not (Test-Path -LiteralPath $draftPath -PathType Leaf)) {
    Write-Output "pack-render: draft file not found: '$DraftFile'"
    $global:LASTEXITCODE = 1
    exit 1
}

$raw = Get-Content -LiteralPath $draftPath -Raw -Encoding utf8
# The taster (tailor-check) appends a "# Tailor check" scorecard. A failed check never becomes a ready pack, and the card is not an answer.
$card = ''
if ($raw -match '(?ms)^# Tailor check[^\n]*\n.*\z') { $card = $Matches[0]; $raw = $raw.Substring(0, $raw.Length - $card.Length) }
if ($card -match '(?m)^- Result:\s*FAIL') {
    Write-Output "pack-render: the draft failed the tailor check; not rendering it as a ready pack"
    $global:LASTEXITCODE = 1
    exit 1
}
$html = ''
$answers = ''

if ($raw -match '(?si)#\s*Resume\s*(HTML)?\s*\r?\n(.*?)(?=\r?\n#\s*(Draft\s*)?Answers|\Z)') {
    $html = $Matches[2].Trim()
}
if ($raw -match '(?si)#\s*(Draft\s*)?Answers\s*\r?\n(.*)') {
    $answers = $Matches[2].Trim()
}

if (-not $html) {
    if ($raw -match '(?s)```html\s*\r?\n(.*?)\r?\n```') {
        $html = $Matches[1].Trim()
    } else {
        # no Resume HTML section and no html block: the cook did not follow the contract. Printing its raw markdown as the resume
        # (and marking the pack ready) would put a broken page in front of an employer
        Write-Output 'pack-render: the draft has no Resume HTML section; not rendering it as a ready pack'
        $global:LASTEXITCODE = 1
        exit 1
    }
} else {
    if ($html -match '(?s)^```html\s*\r?\n(.*?)\r?\n```$') {
        $html = $Matches[1].Trim()
    }
}

if (-not $answers) {
    $answers = "No draft answers provided."
}

# Keep only plain text-layout tags, each rebuilt with at most a class (and, on <a>, a mailto: or #anchor href). Everything else goes:
# script-like elements with their contents, every other tag, on* handlers, style (url() fetches), src, and web or file: links. Text
# that is left keeps its words but any stray < or > is escaped, so leftovers can never re-form a tag.
function Get-SafeHtml([string]$h) {
    $ph1 = [char]0xE000; $ph2 = [char]0xE001
    $h = $h.Replace([string]$ph1, '').Replace([string]$ph2, '')
    $h = [regex]::Replace($h, '(?s)<!--.*?(-->|\z)', '')
    $h = [regex]::Replace($h, '(?is)<(script|style|iframe|frame|frameset|object|embed|applet|svg|math|template|noscript|noembed|noframes|textarea|select|title|head|video|audio|canvas|xmp|plaintext)\b.*?(</\1\s*>|\z)', '')
    $allowed = '^(h[1-6]|p|ul|ol|li|div|span|section|header|footer|article|main|strong|b|em|i|u|small|a|br|hr|table|thead|tbody|tr|td|th|dl|dt|dd|blockquote|sup|sub)$'
    $kept = [Collections.Generic.List[string]]::new()
    $h = [regex]::Replace($h, '<(/?)([A-Za-z][A-Za-z0-9-]*)([^>]*)>|<[!?][^>]*>', {
        param($m)
        if (-not $m.Groups[2].Success) { return '' }
        $tag = $m.Groups[2].Value.ToLowerInvariant()
        if ($tag -notmatch $allowed) { return '' }
        $out = if ($m.Groups[1].Value) { "</$tag>" } else {
            $attrs = $m.Groups[3].Value
            $cm = [regex]::Match($attrs, '(?i)(?:^|\s)class\s*=\s*(?:"([\w\s-]{0,200})"|''([\w\s-]{0,200})''|([\w-]{1,100}))')
            $cls = if ($cm.Success) { ($cm.Groups[1].Value + $cm.Groups[2].Value + $cm.Groups[3].Value).Trim() -replace '\s+', ' ' } else { '' }
            $href = ''
            if ($tag -eq 'a') { $hm = [regex]::Match($attrs, '(?i)(?:^|\s)href\s*=\s*"(mailto:[\w.+@%-]{1,200}|#[\w-]{0,100})"'); if ($hm.Success) { $href = ' href="' + $hm.Groups[1].Value + '"' } }
            $c = if ($cls) { ' class="' + $cls + '"' } else { '' }
            "<$tag$c$href>"
        }
        $kept.Add($out); "$ph1$($kept.Count - 1)$ph2"
    })
    $h = $h.Replace('<', '&lt;').Replace('>', '&gt;')
    [regex]::Replace($h, "$ph1(\d+)$ph2", { param($m) $kept[[int]$m.Groups[1].Value] })
}

# Wrap in locked resume print template
$templatePath = Join-Path $PSScriptRoot '..\templates\resume.html'
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    Write-Output "pack-render: print template not found at $templatePath"
    $global:LASTEXITCODE = 1
    exit 1
}
$template = Get-Content -LiteralPath $templatePath -Raw -Encoding utf8
if ($template -notmatch "(?i)http-equiv=`"Content-Security-Policy`"[^>]*default-src 'none'") {
    Write-Output 'pack-render: the print template lost its Content-Security-Policy; refusing to render'
    $global:LASTEXITCODE = 1
    exit 1
}
$innerBody = $html
if ($html -match '(?si)<body[^>]*>(.*?)<\/body>') {
    $innerBody = $Matches[1].Trim()
}
$finalHtml = $template.Replace('{{body}}', (Get-SafeHtml $innerBody))

$packsDir = if ($LockedFrom) { $careerDir } else { Join-Path $careerDir 'packs' }
New-Item -ItemType Directory -Force -Path $packsDir | Out-Null
$htmlFile = Join-Path $packsDir $(if ($LockedFrom) { 'resume-locked.html' } else { "$AppId-resume.html" })
$answersFile = Join-Path $packsDir "$AppId-answers.md"
Set-Content -LiteralPath $htmlFile -Value $finalHtml -Encoding utf8
if (-not $LockedFrom) { Set-Content -LiteralPath $answersFile -Value $answers -Encoding utf8 }

# Locate Microsoft Edge executable
$edge = $null
if ($env:KITCHEN_EDGE_EXE -and (Test-Path -LiteralPath $env:KITCHEN_EDGE_EXE)) {
    $edge = $env:KITCHEN_EDGE_EXE
} else {
    $cmd = Get-Command msedge -ErrorAction SilentlyContinue
    if ($cmd) {
        $edge = $cmd.Source
    } else {
        $candidates = @(
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
            "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
            "${env:LocalAppData}\Microsoft\Edge\Application\msedge.exe"
        )
        foreach ($c in $candidates) {
            if ($c -and (Test-Path -LiteralPath $c)) { $edge = $c; break }
        }
    }
}

if (-not $edge) {
    Write-Output 'pack-render: Microsoft Edge executable not found for headless PDF printing'
    $global:LASTEXITCODE = 1
    exit 1
}

$pdfFile = Join-Path $packsDir $(if ($LockedFrom) { 'resume-locked.next.pdf' } else { "$AppId-resume.pdf" })   # locked: swapped in only once it rendered
Remove-Item -LiteralPath $pdfFile -Force -ErrorAction SilentlyContinue

# A throwaway profile (no cookies, extensions or sign-ins of Jordan's), scripts off, and a dead proxy so no web request can leave.
$edgeProfile = Join-Path ([IO.Path]::GetTempPath()) ('pack-edge-' + [guid]::NewGuid().ToString('N'))
$edgeArgs = @(
    '--headless',
    '--disable-gpu',
    '--no-pdf-header-footer',
    '--blink-settings=scriptEnabled=false',
    "--user-data-dir=$edgeProfile",
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-extensions',
    '--disable-sync',
    '--disable-background-networking',
    '--disable-component-update',
    '--proxy-server=http://127.0.0.1:9',
    "--print-to-pdf=$pdfFile",
    $htmlFile
)

$p = $null
if ($edge -match '\.(cmd|bat)$') {
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList (@('/c', $edge) + $edgeArgs) -PassThru -NoNewWindow
} elseif ($edge -match '\.ps1$') {
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList (@('-NoProfile', '-File', $edge) + $edgeArgs) -PassThru -NoNewWindow
} else {
    $p = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -NoNewWindow
}

$exited = $p.WaitForExit(45000)
if (-not $exited) { try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch { } }
Remove-Item -LiteralPath $edgeProfile -Recurse -Force -ErrorAction SilentlyContinue
if (-not $exited) {
    Write-Output 'pack-render: Edge timed out rendering PDF after 45s'
    $global:LASTEXITCODE = 1
    exit 1
}
if ($p.ExitCode -ne 0) {
    Write-Output "pack-render: Edge failed with exit code $($p.ExitCode)"
    $global:LASTEXITCODE = 1
    exit 1
}
if (-not (Test-Path -LiteralPath $pdfFile -PathType Leaf)) {
    Write-Output "pack-render: output PDF was not created at $pdfFile"
    $global:LASTEXITCODE = 1
    exit 1
}
if ((Get-Item -LiteralPath $pdfFile).Length -le 0) {
    Write-Output 'pack-render: output PDF is empty (0 bytes)'
    $global:LASTEXITCODE = 1
    exit 1
}

# Update tracker.json under the shared lock: re-read fresh, change only this item, keep a .bak, temp + rename.
# An unreadable tracker is left alone (never rewritten from nothing).
$trackerPath = Join-Path $careerDir 'tracker.json'
if ($LockedFrom) {
    Remove-Item -LiteralPath $draftPath -Force -ErrorAction SilentlyContinue
    $final = Join-Path $careerDir 'resume-locked.pdf'
    Move-Item -LiteralPath $pdfFile -Destination $final -Force
    $meta = [ordered]@{ source = $LockedFrom; sourceSha256 = $srcSha; pdfSha256 = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant(); renderedAt = (Get-Date).ToUniversalTime().ToString('o') }
    $tmp = "$lockMeta.tmp-$PID"; [IO.File]::WriteAllText($tmp, ($meta | ConvertTo-Json), [Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $tmp -Destination $lockMeta -Force
    Write-Output "pack-render: locked resume rendered from $(Split-Path -Leaf $LockedFrom) (PDF: $final)"; $global:LASTEXITCODE = 0; exit 0
}
if (Test-Path -LiteralPath $trackerPath -PathType Leaf) {
    try {
        Update-Tracker $trackerPath {
            param($items)
            $it = $items | Where-Object { $_.id -eq $AppId } | Select-Object -First 1
            if (-not $it) { return $false }
            $now = (Get-Date).ToUniversalTime().ToString('o')
            $it.pack = [ordered]@{ ready = $true; pdf = "packs/$AppId-resume.pdf"; html = "packs/$AppId-resume.html"; answers = "packs/$AppId-answers.md"; generatedAt = $now }
            $it.changedAt = $now
            $true
        }
    } catch {
        Write-Output "pack-render: warning: failed to update tracker.json ($($_.Exception.Message))"
    }
}
# The rendered draft is moved aside, so a later Pack order whose cook writes nothing finds no draft and stops, instead of
# re-rendering this one as if it were new.
try { Move-Item -LiteralPath $draftPath -Destination ($draftPath -replace '\.md$', '.rendered.md') -Force } catch { Write-Output "pack-render: warning: could not move the rendered draft aside ($($_.Exception.Message))" }

Write-Output "pack-render: successfully generated pack for $AppId (PDF: $pdfFile, answers: $answersFile)"
$global:LASTEXITCODE = 0
exit 0
