# Tests for the old-names guard scripts/check-names.ps1 (Tide rename, RENAME-PLAN.md v2 section 4) and its names-allow.json / names-baseline.json.
# Run by the kitchen tests station on every order (it globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Temp git fixtures only:
# it never reads the order's own diff, so an order's goal text or changed files cannot fail it. Self-cleaning.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$guard = Join-Path $repo 'scripts\check-names.ps1'
$realAllow = Join-Path $repo 'scripts\names-allow.json'
$fx = Join-Path ([IO.Path]::GetTempPath()) ('tide-test-names-' + [guid]::NewGuid().ToString('N'))
$env:GITHUB_HEAD_REF = $null   # a CI branch name must not change the mode under test
$script:ok = 0; $script:bad = 0
function Expect([string]$what, [bool]$cond, [string]$show = '') {
    if ($cond) { $script:ok++; return }
    $script:bad++; Write-Host "FAIL: $what"; if ($show) { Write-Host ($show.Trim() -split "`n" | Select-Object -First 25 | Out-String) }
}
function Invoke-Guard([string[]]$GuardArgs) {
    $text = & pwsh -NoProfile -File $guard @GuardArgs 2>&1 | Out-String
    [pscustomobject]@{ text = $text; code = $LASTEXITCODE }
}
function Save-Fixture([string]$rel, [string]$body) {
    $full = Join-Path $fx $rel
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full))
    [IO.File]::WriteAllText($full, $body.Replace("`r`n", "`n"))
}
function Save-Commit([string]$msg) {
    & git -C $fx add -A 2>&1 | Out-Null
    & git -C $fx -c user.email=names@test.invalid -c user.name=names commit -q --allow-empty -m $msg 2>&1 | Out-Null
    (& git -C $fx rev-parse HEAD).Trim()
}
function Test-Hit($r, [string]$where, [string]$word) { $r.text -match ('(?m)^FOUND: ' + [regex]::Escape($where) + ' "' + [regex]::Escape($word) + '"') }
function Test-NoHitOn($r, [string]$where) { $r.text -notmatch ('(?m)^(FOUND|KNOWN): ' + [regex]::Escape($where) + ' ') }

try {
    # 1. input checks: -Base is required (exit 2), and a ref git cannot resolve is bad input too
    $r = Invoke-Guard @('-Root', $repo)
    Expect 'no -Base: exit 2 and says -Base is required' ($r.code -eq 2 -and $r.text -match '-Base <git ref> is required') $r.text

    [void](New-Item -ItemType Directory -Force -Path $fx)
    & git -C $fx init -q 2>&1 | Out-Null
    Save-Fixture 'scripts/names-allow.json' ([IO.File]::ReadAllText($realAllow))
    Save-Fixture 'pass-app/public/ui.js' "// owns: fixture`n// called by: Test-Names`nexport const x = 1;`n"
    $base = Save-Commit 'base'
    $r = Invoke-Guard @('-Root', $fx, '-Base', 'no-such-ref-here')
    Expect 'a -Base git cannot resolve: exit 2' ($r.code -eq 2 -and $r.text -match 'cannot resolve -Base no-such-ref-here') $r.text
    # 1b. a root commit (a repo's first commit, as on the public repo's first push): -Base HEAD^1 has no parent, so it is compared with the
    # empty tree and every line counts as added, with a NOTE saying so (it used to stop with "git cannot resolve -Base HEAD^1")
    $rootSum = Join-Path $fx 'root-summary.md'
    $r = Invoke-Guard @('-Root', $fx, '-Base', 'HEAD^1', '-Summary', $rootSum)
    Expect 'root commit, -Base HEAD^1: exit 0, a NOTE names the empty tree, and every line of the commit is checked' ($r.code -eq 0 -and $r.text -match '(?m)^NOTE: HEAD \([0-9a-f]{7}\) is a root commit with no parent: -Base HEAD\^1 is compared as the empty tree' -and $r.text -match '(?m)^Names: report only; 1 files and 3 added lines checked, 0 old words') $r.text
    $rs = if (Test-Path -LiteralPath $rootSum) { Get-Content -LiteralPath $rootSum -Raw } else { '' }
    Expect 'root commit: the step summary carries the note' ($rs -match '- Note: HEAD \([0-9a-f]{7}\) is a root commit') $rs
    Remove-Item -LiteralPath $rootSum -Force -ErrorAction SilentlyContinue
    $r = Invoke-Guard @('-Root', $fx, '-Base', 'HEAD~2')
    Expect 'root commit, -Base HEAD~2: still bad input (only one step back from a root is the empty tree)' ($r.code -eq 2 -and $r.text -match 'cannot resolve -Base HEAD~2') $r.text

    # 2. the fixture change: display text with old words, and code that must never match
    Save-Fixture 'pass-app/public/ui.js' (@'
// owns: fixture
// called by: Test-Names
export const x = 1;
el.textContent = 'Plated just now';
const s = 'done'; const p = 'plated'; const q = `cooking`;
const r = j.recipe; const o = STATUS_ORDER;
// the head chef left a note here
if (/the pass/.test(t) || new RegExp('head chef').test(t)) go('#/pass', 'kitchen.repo.json', 'kitchen/kitchen.ps1');
const line = `${n} cooking now`;
const nest = `${a ? `<b>${b}</b> on the rail` : ''}`;
const box = `<div class="msg kitchen">Hi</div>`;
const lab = `<p aria-label="Open the pass">x</p>`;
const w1 = 'Waveform view'; const w2 = 'One wave left';
n.setAttribute('class', `actor chef st-${c}`); const sel = document.querySelector('.chefs');
'@)
    Save-Fixture 'pass-app/public/index.html' "<!doctype html>`n<title>Chef</title>`n<section id=`"view-pass`"></section>`n"
    Save-Fixture 'docs/changes/I1.md' "# I1`nThe sous chef plated it.`n"
    Save-Fixture 'README.md' ("# Fixture`nThe sous chef plated it.`n" + '```' + "`nkitchen cook`n" + '```' + "`nRun ``kitchen`` now.`n")
    Save-Fixture 'kitchen/notes.ps1' "# owns: fixture`n# called by: Test-Names`n'Plated'`n"
    $head = Save-Commit 'change'
    $sum = Join-Path $fx 'summary.md'
    $r = Invoke-Guard @('-Root', $fx, '-Base', $base, '-Summary', $sum)
    Expect '"Plated" added to a .js UI literal is reported' (Test-Hit $r 'pass-app/public/ui.js:4' 'Plated') $r.text
    Expect 'stored status literals (''done'', ''plated'', `cooking`) pass' (Test-NoHitOn $r 'pass-app/public/ui.js:5') $r.text
    Expect 'j.recipe and STATUS_ORDER identifiers pass' (Test-NoHitOn $r 'pass-app/public/ui.js:6') $r.text
    Expect 'a comment passes' (Test-NoHitOn $r 'pass-app/public/ui.js:7') $r.text
    Expect 'regex literals, RegExp() sources, #/pass and paths pass' (Test-NoHitOn $r 'pass-app/public/ui.js:8') $r.text
    Expect 'template text around ${...} is display text' (Test-Hit $r 'pass-app/public/ui.js:9' 'Cooking') $r.text
    Expect 'a template nested in ${...} is read too' (Test-Hit $r 'pass-app/public/ui.js:10' 'On the rail') $r.text
    Expect 'a class name inside markup in a string passes' (Test-NoHitOn $r 'pass-app/public/ui.js:11') $r.text
    Expect 'an aria-label inside markup in a string is display text' (Test-Hit $r 'pass-app/public/ui.js:12' 'the pass') $r.text
    Expect 'whole words only: "Waveform" passes, "wave" is reported' ((Test-Hit $r 'pass-app/public/ui.js:13' 'wave') -and ([regex]::Matches($r.text, 'ui\.js:13 ')).Count -eq 1) $r.text
    Expect 'a class attribute and a selector pass' (Test-NoHitOn $r 'pass-app/public/ui.js:14') $r.text
    Expect 'HTML tag text is display text; id="view-pass" passes' ((Test-Hit $r 'pass-app/public/index.html:2' 'Chef') -and (Test-NoHitOn $r 'pass-app/public/index.html:3')) $r.text
    Expect 'a line in docs/changes/ passes' (Test-NoHitOn $r 'docs/changes/I1.md:2') $r.text
    Expect 'Markdown prose is checked (sous chef, Plated)' ((Test-Hit $r 'README.md:2' 'sous chef') -and (Test-Hit $r 'README.md:2' 'Plated')) $r.text
    Expect 'Markdown fences and code spans pass' ((Test-NoHitOn $r 'README.md:4') -and (Test-NoHitOn $r 'README.md:6')) $r.text
    Expect 'PowerShell files are not scanned' (Test-NoHitOn $r 'kitchen/notes.ps1:3') $r.text
    Expect 'report only: exit 0 with findings, and the closing line says so' ($r.code -eq 0 -and $r.text -match '(?m)^Names: report only; 3 files .*, 8 old words \(0 baselined\), 8 new') $r.text
    $s = if (Test-Path -LiteralPath $sum) { Get-Content -LiteralPath $sum -Raw } else { '' }
    Expect 'the summary file gets the heading, the closing line and the findings' ($s -match '## Old names' -and $s -match 'Names: report only' -and $s -match '`pass-app/public/ui\.js:4` "Plated" -> Handed over') $s
    $r = Invoke-Guard @('-Root', $fx, '-Base', 'HEAD^1')
    Expect 'a commit with a parent: -Base HEAD^1 is that parent, no root NOTE' ($r.code -eq 0 -and $r.text -notmatch 'root commit' -and $r.text -match '8 new') $r.text
    # a shallow clone's oldest commit shows no parent but has one: that is still "cannot resolve" (CI needs fetch-depth 2), never the empty tree
    $shallowFx = "$fx-shallow"
    & git clone -q --depth 1 ('file:///' + ($fx -replace '\\', '/')) $shallowFx 2>&1 | Out-Null
    $r = Invoke-Guard @('-Root', $shallowFx, '-Base', 'HEAD^1')
    Expect 'shallow clone, depth 1: -Base HEAD^1 is bad input (exit 2), not a root commit' ((Test-Path -LiteralPath (Join-Path $shallowFx '.git\shallow')) -and $r.code -eq 2 -and $r.text -match 'cannot resolve -Base HEAD\^1' -and $r.text -notmatch 'root commit') $r.text
    Remove-Item -LiteralPath $shallowFx -Recurse -Force -ErrorAction SilentlyContinue

    # 3. enforce mode, and the exemptThrough rule for older work orders
    $r = Invoke-Guard @('-Root', $fx, '-Base', $base, '-Enforce', '-Branch', '')
    Expect 'enforce: the same findings exit 1' ($r.code -eq 1 -and $r.text -match 'Names: enforce;') $r.text
    $allow2 = Join-Path $fx 'allow-304.json'
    $aj = Get-Content -LiteralPath $realAllow -Raw | ConvertFrom-Json; $aj.exemptThrough = 304
    $aj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $allow2 -Encoding utf8
    $r = Invoke-Guard @('-Root', $fx, '-Base', $base, '-Allow', $allow2, '-Enforce', '-Branch', 'kitchen/J250')
    Expect 'branch kitchen/J250 with exemptThrough 304 stays report-only (exit 0)' ($r.code -eq 0 -and $r.text -match 'report only \(kitchen/J250 is at or below exemptThrough 304\)') $r.text
    $r = Invoke-Guard @('-Root', $fx, '-Base', $base, '-Allow', $allow2, '-Enforce', '-Branch', 'kitchen/J305')
    Expect 'branch kitchen/J305 above exemptThrough 304 is enforced (exit 1)' ($r.code -eq 1) $r.text

    # 4. the baseline ratchet: an edited line that keeps its word is KNOWN; one more of the word is new; a drop prints NOTE
    $bl = Join-Path $fx 'names-baseline.json'
    $r = Invoke-Guard @('-Root', $fx, '-WriteBaseline', '-Baseline', $bl)
    $bj = if (Test-Path -LiteralPath $bl) { Get-Content -LiteralPath $bl -Raw | ConvertFrom-Json -AsHashtable } else { @{ words = @{} } }
    Expect '-WriteBaseline records word|file counts and skips history paths' ($r.code -eq 0 -and $bj.words['Plated|pass-app/public/ui.js'] -eq 1 -and $bj.words['Chef|pass-app/public/index.html'] -eq 1 -and -not $bj.words.ContainsKey('Plated|docs/changes/I1.md')) $r.text
    $js = [IO.File]::ReadAllText((Join-Path $fx 'pass-app/public/ui.js'))
    Save-Fixture 'pass-app/public/ui.js' ($js.Replace("'Plated just now'", "'Plated a moment ago'"))
    $r = Invoke-Guard @('-Root', $fx, '-Base', $head, '-Baseline', $bl, '-Enforce', '-Branch', '')
    Expect 'an edited line that keeps a baselined word is KNOWN and passes enforce' ($r.code -eq 0 -and $r.text -match '(?m)^KNOWN: pass-app/public/ui\.js:4 "Plated"' -and $r.text -match '\(1 baselined\), 0 new') $r.text
    Save-Fixture 'pass-app/public/ui.js' ($js.Replace("'Plated just now'", "'Plated, and Plated again'"))
    $r = Invoke-Guard @('-Root', $fx, '-Base', $head, '-Baseline', $bl, '-Enforce', '-Branch', '')
    Expect 'one more of a baselined word in that file is new and fails enforce' ($r.code -eq 1 -and $r.text -match '(?m)^FOUND: pass-app/public/ui\.js:4 "Plated"') $r.text
    Save-Fixture 'pass-app/public/ui.js' ($js.Replace("'Plated just now'", "'Handed over just now'"))
    $r = Invoke-Guard @('-Root', $fx, '-Base', $head, '-Baseline', $bl)
    Expect 'a word renamed away prints NOTE to lower the baseline' ($r.code -eq 0 -and $r.text -match 'NOTE: Plated in pass-app/public/ui\.js is down from 1 to 0') $r.text

    # 5. the committed pieces: word list, baseline, the CI step (quality job, -Base HEAD^1, summary) and quick checks untouched
    $a = Get-Content -LiteralPath $realAllow -Raw | ConvertFrom-Json
    $olds = @($a.words | ForEach-Object { $_.old })
    $plan = 'Chef', 'Plated', 'Set aside', 'On the rail', 'Cooking', 'sous chef', 'head chef', 'line cook', 'taster', 'boot pack', 'the pass', 'recipe', 'wave', 'kitchen'
    Expect 'names-allow.json lists every word of the plan, exemptThrough is a number' (@($plan | Where-Object { $olds -notcontains $_ }).Count -eq 0 -and $a.exemptThrough -is [long]) ($olds -join ', ')
    $cb = Get-Content -LiteralPath (Join-Path $repo 'scripts\names-baseline.json') -Raw | ConvertFrom-Json -AsHashtable
    $odd = @($cb.words.Keys | Where-Object { $olds -notcontains ($_ -split '\|')[0] })
    Expect 'names-baseline.json parses and holds only listed words' ($cb.words.Count -gt 0 -and $odd.Count -eq 0) ($odd -join ', ')
    $ci = Get-Content -LiteralPath (Join-Path $repo '.github\workflows\ci.yml') -Raw
    $quality = if ($ci -match '(?s)\n  quality:(.*?)\n  checks:') { $Matches[1] } else { '' }
    Expect 'ci.yml quality job runs check-names with -Base HEAD^1 and the step summary' ($quality -match 'scripts/check-names\.ps1 -Base HEAD\^1 -Summary \$env:GITHUB_STEP_SUMMARY' -and $quality -match 'fetch-depth: 2')
    Expect 'ci-quick-checks.ps1 does not run check-names' ((Get-Content -LiteralPath (Join-Path $repo 'scripts\ci-quick-checks.ps1') -Raw) -notmatch 'check-names')
} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$fx-shallow" -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Names tests: $script:ok passed, $script:bad failed"
exit ([int]($script:bad -gt 0))
