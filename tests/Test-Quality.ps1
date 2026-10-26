# Tests for the code-quality ratchet: scripts/quality/metrics.ps1 (long functions, nesting, duplicates, analyzer) and scripts/quality/js-metrics.mjs.
# Run by the kitchen tests station on every order (it globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Self-cleaning temp repos.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$q = Join-Path $repo 'scripts/quality/metrics.ps1'
$d = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-quality-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Put([string]$rel, [string]$text) {
    $p = Join-Path $d $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    [IO.File]::WriteAllText($p, $text); & git -C $d add -- $rel 2>&1 | Out-Null
}
function Drop([string]$rel) { & git -C $d rm -q -f -- $rel 2>&1 | Out-Null }
function Q([switch]$Write, [string]$Since = '', [string]$Module = 'No-Such-Analyzer-Module', [string]$Summary = '') {
    $o = & $q -Root $d -WriteBaseline:$Write -ChangedSince $Since -AnalyzerModule $Module -Summary $Summary 2>&1 | Out-String; @{ out = $o; code = $LASTEXITCODE }
}
# A PowerShell function with $n body lines, and an if-nest $n deep. Fixture lines differ per $tag so they are not duplicates of each other.
function PsFn([string]$name, [int]$n, [string]$tag) { "function $name {`n" + ((1..$n | ForEach-Object { "    `$v$_ = '$tag$_'" }) -join "`n") + "`n}`n" }
function PsNest([int]$n) { ((1..$n | ForEach-Object { "if (`$a -eq $_) {" }) -join "`n") + "`n'deep'`n" + ('}' * $n) + "`n" }
$hdr = "# owns: test fixture`n# called by: Test-Quality`n"
$jhdr = "// owns: fixture`n// called by: Test-Quality`n"
try {
    # 1. today's repository is green against the committed baseline, and the baseline count is printed
    $o = & $q -Root $repo 2>&1 | Out-String
    Check 'real repo: no new violations against kitchen/quality-baseline.json' ($LASTEXITCODE -eq 0 -and $o -match ', 0 new')
    Check 'real repo: the baseline count and the measured totals are printed' ($o -match 'Quality: baseline holds \d+ known violations' -and $o -match 'Quality: \d+ files, \d+ functions')

    New-Item -ItemType Directory -Force -Path $d | Out-Null
    & git -C $d init -q 2>&1 | Out-Null
    & git -C $d config user.email t@t.invalid; & git -C $d config user.name t
    Put 'kitchen/ok.ps1' ($hdr + (PsFn 'Use-Small' 10 'a') + (PsNest 5))
    $r = Q
    Check 'a function of 80 lines or less and nesting of 5 pass' ($r.code -eq 0 -and $r.out -match '0 violations')

    # 2. long functions: PowerShell (parser) and JavaScript (tokenizer) over 80 lines fail with file and function name
    Put 'kitchen/long.ps1' ($hdr + (PsFn 'Get-Long' 85 'b'))
    $r = Q
    Check 'a new PowerShell function over 80 lines fails (longfn, file, name, lines)' ($r.code -eq 1 -and $r.out -match 'FAIL: longfn kitchen/long\.ps1 Get-Long is over 80 lines.*\(now 87\)')
    Drop 'kitchen/long.ps1'
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $body = (1..85 | ForEach-Object { "  const c$_ = 'c$_';" }) -join "`n"
        Put 'pass-app/long.mjs' ($jhdr + "export const big = async (x) => {`n$body`n};`n")
        $r = Q
        Check 'a new JavaScript function over 80 lines fails (arrow function named from its const)' ($r.code -eq 1 -and $r.out -match 'FAIL: longfn pass-app/long\.mjs big is over 80 lines.*\(now 87\)')
        Drop 'pass-app/long.mjs'

        # 3. the tokenizer: braces inside strings, comments, regex literals and templates do not count; template ${} code does
        $tricky = $jhdr + @'
const re = /\{+[}{]/g; // a { in a comment
const s = '{{' + "}" + `x ${ {a: 1}.a } {`;
/* { */
function outer(a) {
  if (a) {
    for (const k of [1]) {
      while (false) { switch (k) { case 1: try { if (k) { if (k) { return 1; } } } catch { } } }
    }
  }
  return a / 2 / 1;
}
class K { method(x) { return x; } }
'@
        Put 'pass-app/tricky.js' $tricky
        $j = & node (Join-Path $repo 'scripts/quality/js-metrics.mjs') (Join-Path $d 'pass-app/tricky.js') | ConvertFrom-Json
        $fn = @($j[0].functions | Where-Object name -eq 'outer')
        Check 'tokenizer: braces in strings, comments, regex and templates are skipped (outer is 8 lines, all balanced)' ($fn.Count -eq 1 -and $fn[0].lines -eq 8 -and $j[0].unbalanced -eq 0 -and @($j[0].functions.name) -contains 'method')
        Check 'JavaScript nesting counts if/for/while/switch/try/if/if (7 deep) and fails over 5' ($j[0].maxNesting -eq 7 -and (Q).out -match 'FAIL: nesting pass-app/tricky\.js .*\(now 7\)')
        Drop 'pass-app/tricky.js'
    } else { Write-Output 'SKIP: node is not on PATH; the JavaScript tests did not run' }

    # 4. nesting: PowerShell over 5 fails; a ForEach-Object { } block starts again at 0 (like a callback in JavaScript)
    Put 'kitchen/deep.ps1' ($hdr + (PsNest 6))
    Put 'kitchen/pipe.ps1' ($hdr + (PsNest 3) -replace "'deep'", ("1..2 | ForEach-Object {`n" + (PsNest 4) + "}"))
    $r = Q
    Check 'PowerShell nesting deeper than 5 fails (nesting, file, depth)' ($r.code -eq 1 -and $r.out -match 'FAIL: nesting kitchen/deep\.ps1 .*\(now 6\)')
    Check 'a ForEach-Object block restarts the nesting count (3 + 4 is not 7)' ($r.out -notmatch 'nesting kitchen/pipe\.ps1')
    Drop 'kitchen/deep.ps1'; Drop 'kitchen/pipe.ps1'

    # 5. duplicates: the same 6 code lines in two files fail and name the other copy; 5 shared lines, blank lines and comments do not count
    $six = (1..6 | ForEach-Object { "`$shared$_ = Get-Thing -Name 'n$_'" }) -join "`n"
    Put 'scripts/one.ps1' ($hdr + "'one'`n" + $six + "`n")
    Put 'scripts/two.ps1' ($hdr + "'two'`n" + ($six -replace "`n", "`n`n# a comment`n") + "`n")
    $r = Q
    Check 'a 6-line block in two files fails in both and names the other copy (blank lines and comments ignored)' ($r.code -eq 1 -and $r.out -match 'FAIL: dup scripts/one\.ps1 .*\(now 6\) \(line 4 repeats scripts/two\.ps1:4\)' -and $r.out -match 'FAIL: dup scripts/two\.ps1')
    Put 'scripts/two.ps1' ($hdr + "'two'`n" + (($six -split "`n")[0..4] -join "`n") + "`n")
    $r = Q
    Check 'five shared lines are not a duplicate' ($r.code -eq 0 -and $r.out -notmatch 'dup scripts')
    Drop 'scripts/two.ps1'

    # 6. ratchet: -WriteBaseline records; baselined passes; growth warns and passes; a fixed one prints NOTE
    Put 'kitchen/long.ps1' ($hdr + (PsFn 'Get-Long' 85 'b'))
    $r = Q -Write
    Check '-WriteBaseline records today''s violations' ($r.out -match 'baseline written with 1 known violations' -and (Test-Path (Join-Path $d 'kitchen/quality-baseline.json')))
    $r = Q
    Check 'a baselined violation passes and counts as baselined' ($r.code -eq 0 -and $r.out -match 'baseline holds 1 known' -and $r.out -match '1 violations \(1 baselined\), 0 grew, 0 new')
    Put 'kitchen/long.ps1' ($hdr + (PsFn 'Get-Long' 90 'b'))
    $r = Q
    Check 'a baselined function that grows warns (baseline, now) and passes' ($r.code -eq 0 -and $r.out -match 'WARN: longfn kitchen/long\.ps1 Get-Long grew: baseline 87, now 92' -and $r.out -notmatch 'FAIL:')
    Put 'kitchen/long.ps1' ($hdr + (PsFn 'Get-Long' 5 'b'))
    $r = Q
    Check 'a fixed baselined function prints NOTE and passes' ($r.code -eq 0 -and $r.out -match 'NOTE: longfn kitchen/long\.ps1 Get-Long is fixed')

    # 7. a missing node skips the JavaScript files with a reason and keeps their baselined lines (no false "fixed")
    Put 'pass-app/x.mjs' ($jhdr + "export function f() { return 1; }`n")
    $gitDir = Split-Path -Parent (Get-Command git).Source; $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd -and (Split-Path -Parent $nodeCmd.Source) -eq $gitDir) { Write-Output 'SKIP: node and git share one folder here, so PATH cannot hide node; the no-node test did not run' }
    else {
        $saved = $env:PATH
        try { $env:PATH = $gitDir; $r = Q } finally { $env:PATH = $saved }
        Check 'no node on PATH: one SKIP line naming the JavaScript file count' ($r.out -match 'SKIP: node is not on PATH, so 1 JavaScript files were not measured' -and $r.code -eq 0)
    }
    Drop 'pass-app/x.mjs'

    # 8. analyzer: no -ChangedSince or no module -> SKIP with the reason; installed -> a rule with more findings than the base fails
    $r = Q
    Check 'analyzer without -ChangedSince: SKIP line says why' ($r.out -match 'SKIP: analyzer regression check needs -ChangedSince')
    & git -C $d commit -q -m base 2>&1 | Out-Null
    $r = Q -Since 'HEAD'
    Check 'analyzer module missing: SKIP line names it' ($r.out -match 'SKIP: No-Such-Analyzer-Module is not installed here')
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
        Put 'kitchen/ok.ps1' ($hdr + (PsFn 'Use-Small' 10 'a') + "if (`$x -eq `$null) { 1 }`n")
        & git -C $d commit -q -m change 2>&1 | Out-Null
        $sum = Join-Path $d 'summary.md'
        $r = Q -Since 'HEAD~1' -Module 'PSScriptAnalyzer' -Summary $sum
        Check 'analyzer: a new $null-on-the-right comparison in a changed file fails (rule, before, after, line)' ($r.code -eq 1 -and $r.out -match 'FAIL: analyzer kitchen/ok\.ps1 PSPossibleIncorrectComparisonWithNull went from 0 to 1 \(first finding: line 15' -and $r.out -match 'Analyzer: 1 changed PowerShell files')
        $m = if (Test-Path -LiteralPath $sum) { Get-Content -LiteralPath $sum -Raw } else { '' }
        Check '-Summary appends the heading, closing line, FAIL lines and the longest-function table' ($m -match '## Code quality' -and $m -match 'Quality: \d+ files' -and $m -match '- FAIL: analyzer' -and $m -match '\| Longest functions \| Lines \|')
    } else { Write-Output 'SKIP: PSScriptAnalyzer is not installed; the analyzer regression tests did not run' }
} finally {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Quality tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
