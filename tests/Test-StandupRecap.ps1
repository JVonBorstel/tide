# Tests for scripts/standup-recap.ps1 (timeline JSON -> PROPOSAL recap in an inbox folder). Self-cleaning. Fixtures are fictional.
$ErrorActionPreference = 'Stop'
$rc = Join-Path $PSScriptRoot '..\scripts\standup-recap.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('src-' + [guid]::NewGuid().ToString('N'))
$inbox = Join-Path $root 'inbox'; New-Item -ItemType Directory -Path $inbox | Out-Null
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Rc { param([string[]]$a) $o = pwsh -NoProfile -File $rc @a 2>&1 | Out-String; $script:o = $o; $script:ec = $LASTEXITCODE }
function Write-Fixture($name, $reportText = 'Login is slow because fetchProfile runs twice.') {
    $tl = @{
        id = 'demo'; proj = '_demo'; durationMs = 46800
        agents = @(@{ id = 'main'; role = 'Lead'; type = 'main' }, @{ id = 'ada'; role = 'Profiler'; type = 'sub' })
        events = @(
            @{ ts = 1; agent = 'user'; kind = 'user'; text = 'secret private user prompt that must not be copied' },
            @{ ts = 2; agent = 'main'; to = 'ada'; kind = 'order'; title = "Profile the login flow`u{0007}`u{200B}"; text = 'long order body' },
            @{ ts = 3; agent = 'ada'; kind = 'tools'; tools = @(@{ id = 't1'; name = 'Read'; arg = 'a.js' }, @{ id = 't2'; name = 'Grep'; arg = 'x' }) },
            @{ ts = 4; agent = 'ada'; kind = 'results'; items = @(@{ id = 't1'; err = $false; out = 'x' }, @{ id = 't2'; err = $true; out = 'boom' }) },
            @{ ts = 5; agent = 'ada'; kind = 'usage'; u = @{ i = 5; o = 100; r = 17000; w = 0 }; model = 'demo' },
            @{ ts = 6; agent = 'ada'; kind = 'usage'; u = @{ i = 5; o = 50; r = 18000; w = 1000 }; model = 'demo' },
            @{ ts = 7; agent = 'main'; kind = 'usage'; u = @{ i = 2; o = 10; r = 5000; w = 0 }; model = 'demo' },
            @{ ts = 8; agent = 'ada'; to = 'main'; kind = 'report'; text = $reportText }
        )
    }
    $p = Join-Path $root "$name.json"; $tl | ConvertTo-Json -Depth 8 | Set-Content $p -Encoding utf8; $p
}

# 1. happy path
$f = Write-Fixture 'ok'; $out = Join-Path $inbox 'standup_recap_demo.md'
Rc @('-FromFile', $f, '-OutPath', $out); Check 'ok exit 0' ($ec -eq 0)
$t = Get-Content $out -Raw
Check 'marked as proposal' ($t -match 'PROPOSAL' -and $t -match 'untrusted')
Check 'lists agents' ($t -match 'ada' -and $t -match 'Profiler')
Check 'delegation shown' ($t -match 'main -> ada' -and $t -match 'Profile the login flow')
Check 'tool counts' ($t -match 'ada[^\n]*tools 2')
Check 'error counted' ($t -match 'ada[^\n]*errors 1')
Check 'output tokens summed' ($t -match 'ada[^\n]*out 150')
Check 'peak context' ($t -match 'ada[^\n]*peak context 19005')
Check 'report shown' ($t -match 'fetchProfile')
Check 'user prompt NOT copied' ($t -notmatch 'secret private user prompt')
Check 'order body NOT copied' ($t -notmatch 'long order body')
Check 'tool output NOT copied' ($t -notmatch 'boom')
Check 'control chars stripped' ($t -notmatch "[\x00-\x08\x0b\x0c\x0e-\x1f]" -and $t -notmatch "​")

# 2. secrets: refuse, write nothing
$f2 = Write-Fixture 'sec' ('key is AKIA' + 'ABCDEFGHIJKLMNOP here'); $out2 = Join-Path $inbox 'standup_recap_sec.md'
Rc @('-FromFile', $f2, '-OutPath', $out2); Check 'secret refused exit 2' ($ec -eq 2)
Check 'secret: nothing written' (-not (Test-Path $out2))
Check 'secret value not echoed' ($o -notmatch 'AKIAABCDEFGHIJKLMNOP')

# 3. only inbox folders are writable
$out3 = Join-Path $root 'elsewhere.md'
Rc @('-FromFile', $f, '-OutPath', $out3); Check 'non-inbox refused exit 2' ($ec -eq 2); Check 'non-inbox: nothing written' (-not (Test-Path $out3))

# 4. does not overwrite an existing proposal unless -Force
Rc @('-FromFile', $f, '-OutPath', $out); Check 'no silent overwrite' ($ec -eq 2)
Rc @('-FromFile', $f, '-OutPath', $out, '-Force'); Check 'force overwrites' ($ec -eq 0)

# 5. bad input fails cleanly
Set-Content (Join-Path $root 'bad.json') 'not json'
Rc @('-FromFile', (Join-Path $root 'bad.json'), '-OutPath', (Join-Path $inbox 'x.md')); Check 'bad json exit 2' ($ec -eq 2)
Rc @('-FromFile', (Join-Path $root 'missing.json'), '-OutPath', (Join-Path $inbox 'y.md')); Check 'missing file exit 2' ($ec -eq 2)

# 6. long report text is capped
$f6 = Write-Fixture 'long' ('word ' * 400); $out6 = Join-Path $inbox 'standup_recap_long.md'
Rc @('-FromFile', $f6, '-OutPath', $out6); Check 'long ok' ($ec -eq 0)
Check 'report capped' ((Get-Content $out6 -Raw).Length -lt 3000)

Remove-Item -Recurse -Force $root
Write-Host "StandupRecap tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
