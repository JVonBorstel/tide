# Tests for the house rules in kitchen/STANDARDS.md: scripts/check-standards.ps1 (ratchet), scripts/make-map.ps1, scripts/dead-code.ps1, PR template.
# Run by the kitchen tests station on every order (it globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Self-cleaning temp repos.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$chk = Join-Path $repo 'scripts\check-standards.ps1'
$map = Join-Path $repo 'scripts\make-map.ps1'
$dead = Join-Path $repo 'scripts\dead-code.ps1'
$d = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-standards-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Put([string]$rel, [string]$text) {
    $p = Join-Path $d $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    [IO.File]::WriteAllText($p, $text); & git -C $d add -- $rel 2>&1 | Out-Null
}
function Std([switch]$Write) {
    $o = & $chk -Root $d -AnalyzerModule 'No-Such-Analyzer-Module' -WriteBaseline:$Write 2>&1 | Out-String; @{ out = $o; code = $LASTEXITCODE }
}
$hdr = "# owns: test fixture`n# called by: Test-Standards`n"
try {
    # 1. today's repository is green and the baseline count is printed (the station runs this on every order)
    $o = & $chk -Root $repo 2>&1 | Out-String
    Check 'real repo: no new violations against kitchen/lint-baseline.json' ($LASTEXITCODE -eq 0 -and $o -match ', 0 new')
    Check 'real repo: the baseline count is printed' ($o -match 'Standards: baseline holds \d+ known violations')

    New-Item -ItemType Directory -Force -Path $d | Out-Null
    & git -C $d init -q 2>&1 | Out-Null
    Put 'kitchen/good.ps1' ($hdr + "function Use-Me { 1 }`nfunction Never-Called { 2 }`nUse-Me")
    Put 'pass-app/good.mjs' "// owns: fixture`n// called by: nobody`nexport function hello() { return 1; }`nconst arrow = (a) => a;"
    Put 'scripts/run.ps1' "#!/usr/bin/env pwsh`n# owns: shebang first is fine`n# called by: test`n'ok'"
    $r = Std
    Check 'clean files with # and // headers (and a #! line first) pass' ($r.code -eq 0 -and $r.out -match '0 violations')

    # 2. size: a new file over 600 lines fails
    Put 'kitchen/big.ps1' ($hdr + (("'x'`n") * 600))
    $r = Std
    Check 'a new file over 600 lines fails (size)' ($r.code -eq 1 -and $r.out -match 'FAIL: size kitchen/big\.ps1 is over 600 lines')

    # 3. ratchet: once baselined it passes; growing past the recorded size fails
    $r = Std -Write
    Check '-WriteBaseline records today''s violations' ($r.out -match 'baseline written with 1 known violations' -and (Test-Path (Join-Path $d 'kitchen\lint-baseline.json')))
    $r = Std
    Check 'a baselined violation passes and counts as baselined' ($r.code -eq 0 -and $r.out -match 'baseline holds 1 known' -and $r.out -match '\(1 baselined\), 0 grew, 0 new')
    Put 'kitchen/big.ps1' ($hdr + (("'x'`n") * 601))
    $r = Std
    Check 'a baselined oversize file that grows warns (file, baseline, now) and passes' ($r.code -eq 0 -and $r.out -match 'WARN: size kitchen/big\.ps1 grew: baseline 602 lines, now 603' -and $r.out -match '1 grew, 0 new' -and $r.out -notmatch 'FAIL:')

    # 4. a fixed baselined file is reported, not failed
    Put 'kitchen/big.ps1' ($hdr + "'small'")
    $r = Std
    Check 'a fixed baselined file prints NOTE and passes' ($r.code -eq 0 -and $r.out -match 'NOTE: size kitchen/big\.ps1 is fixed')

    # 5. header: one comment line, #requires first, or // missing in JavaScript all fail
    Put 'kitchen/one.ps1' "# only one line`n'x'"
    Put 'kitchen/req.ps1' "#requires -Version 7`n# owns: x`n'x'"
    Put 'pass-app/nohead.js' "const a = 1;`n"
    $r = Std
    Check 'a file without the two-line header fails (header)' ($r.code -eq 1 -and $r.out -match 'FAIL: header kitchen/one\.ps1' -and $r.out -match 'FAIL: header kitchen/req\.ps1' -and $r.out -match 'FAIL: header pass-app/nohead\.js')
    foreach ($f in 'kitchen/one.ps1', 'kitchen/req.ps1', 'pass-app/nohead.js') { & git -C $d rm -q -f -- $f 2>&1 | Out-Null }

    # 6. bare python fails; uv run passes
    Put 'scripts/py.ps1' ($hdr + "python -c 1")
    Put 'scripts/uv.ps1' ($hdr + "uv run python -c 1")
    $r = Std
    Check 'bare python fails (python), uv run does not' ($r.code -eq 1 -and $r.out -match 'FAIL: python scripts/py\.ps1' -and $r.out -notmatch 'scripts/uv\.ps1')
    & git -C $d rm -q -f -- scripts/py.ps1 2>&1 | Out-Null

    # 7. a literal credential in a URL query fails; a variable there passes (fixture strings are assembled, never written whole)
    $q = '?' + 'api' + '_key='
    Put 'scripts/url.ps1' ($hdr + "`$u = 'https://h.example/v1" + $q + 'abc' + '123456' + "'")
    Put 'scripts/urlvar.ps1' ($hdr + "`$u = `"https://h.example/v1" + $q + "`$k`"")
    $r = Std
    Check 'a literal secret in a URL query fails (urlsecret), a $variable does not' ($r.code -eq 1 -and $r.out -match 'FAIL: urlsecret scripts/url\.ps1' -and $r.out -notmatch 'urlvar')
    & git -C $d rm -q -f -- scripts/url.ps1 2>&1 | Out-Null

    # 8. PSScriptAnalyzer: missing -> one SKIP line naming it; installed -> an Error-severity finding fails
    $r = Std
    Check 'analyzer missing: one SKIP line naming the module' (([regex]::Matches($r.out, 'SKIP: No-Such-Analyzer-Module is not installed')).Count -eq 1 -and $r.code -eq 0)
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
        Put 'scripts/pa.ps1' ($hdr + "`$s = ConvertTo-SecureString -String 'x' -AsPlainText -Force")
        $o = & $chk -Root $d 2>&1 | Out-String
        Check 'analyzer installed: an Error-severity finding fails (analyzer)' ($LASTEXITCODE -eq 1 -and $o -match 'FAIL: analyzer scripts/pa\.ps1')
        & git -C $d rm -q -f -- scripts/pa.ps1 2>&1 | Out-Null
    } else { Write-Output 'SKIP: PSScriptAnalyzer is not installed; the analyzer-error test did not run' }

    # 9. make-map: path, line count, header line or "no header", functions
    Put 'kitchen/bare.ps1' "'no header here'"
    $mo = Join-Path $d 'kitchen\MAP.md'
    & $map -Root $d | Out-Null
    $m = if (Test-Path -LiteralPath $mo) { Get-Content -LiteralPath $mo -Raw } else { '' }
    Check 'make-map lists path, line count and header' ($m -match '- `kitchen/good\.ps1` \(5\) - owns: test fixture; called by: Test-Standards')
    Check 'make-map writes "no header" for a file without one' ($m -match '- `kitchen/bare\.ps1` \(1\) - no header')
    Check 'make-map lists PowerShell and JavaScript functions' ($m -match 'functions: Use-Me, Never-Called' -and $m -match 'functions: hello, arrow')

    # 10. dead-code: the never-called function is listed, the used one is not; report only
    $o = & $dead -Root $d 2>&1 | Out-String
    Check 'dead-code lists an unreferenced function and not a used one, exit 0' ($o -match 'kitchen/good\.ps1:4 Never-Called' -and $o -notmatch 'Use-Me' -and $o -match 'dead-code: 1 of 2' -and $LASTEXITCODE -eq 0)

    # 11. the committed pieces keep their shape
    $t = Get-Content -LiteralPath (Join-Path $repo '.github\pull_request_template.md')
    Check 'PR template starts with "# In plain words" and has Proof and L1-L4 sections' ($t[0] -eq '# In plain words' -and ($t -contains '## Proof') -and ($t -contains '## Effect (L1-L4)'))
    $s = Get-Content -LiteralPath (Join-Path $repo 'kitchen\STANDARDS.md') -Raw
    Check 'STANDARDS.md states the 600-line limit the script enforces' ($s -match 'over 600 lines' -and (Get-Content (Join-Path $repo 'scripts\standards-lib.ps1') -Raw) -match '\$script:StdMaxLines = 600')
    $cm = Join-Path $repo 'kitchen\MAP.md'
    Check 'kitchen/MAP.md is committed and made by make-map' ((Test-Path -LiteralPath $cm) -and (Get-Content -LiteralPath $cm -TotalCount 1) -match 'generated by scripts/make-map\.ps1')
} finally {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Standards tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
