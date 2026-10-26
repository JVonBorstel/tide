# Tests for ZG-38: scripts/memory-truth.ps1 wraps the lobe. The lobe's tensions file (<kitchen>\lobe\tensions.json, zeitgeistd ZG-37) becomes
# drift findings with both sources (file:line); the WARN count is written to watch\memory.json as `unproven`. Present / absent / malformed
# tensions files. Synthetic only: a scratch Yard, a scratch memory folder and a scratch Office in TEMP, made-up services and numbers. No AI.
$ErrorActionPreference = 'Stop'
$truth = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\memory-truth.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-memlobe-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Put([string]$path, [string]$text) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null; [IO.File]::WriteAllText($path, $text) }
function Run([string[]]$more) { $o = & pwsh -NoProfile -File $truth @more 2>&1 | Out-String; [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE; J = $(try { ($o.Trim() -split "`r?`n")[-1] | ConvertFrom-Json } catch { $null }) } }
function Beat { Get-Content -LiteralPath (Join-Path $kr 'watch\memory.json') -Raw | ConvertFrom-Json }
function LobeFound($r) { @($r.J.findings | Where-Object { $_.source -eq 'lobe' }) }
$saved = $env:BRAIN_KITCHEN
try {
    $kr = Join-Path $root 'yard'; New-Item -ItemType Directory -Force -Path $kr | Out-Null
    $env:BRAIN_KITCHEN = $kr
    $mem = Join-Path $root 'memory'; $brain = Join-Path $root 'office'
    $fm = { param($n) "---`nname: $n`ndescription: about $n`nmetadata:`n  type: project`n---`n" }
    Put (Join-Path $mem 'a.md') ((& $fm 'a') + 'The gizmo service builds fast.')
    Put (Join-Path $mem 'b.md') ((& $fm 'b') + 'The widget queue is small.')
    Put (Join-Path $mem 'MEMORY.md') "- [A](a.md) - a`n- [B](b.md) - b"
    # two fact bullets with no proof (the WARN baseline = 2), one with proof, one with no fact
    Put (Join-Path $brain 'memory\NOW.md') "- build time 47 s`n- merged on 2026-01-02`n- 3 suites in C:\x\y`n- no fact here"
    Put (Join-Path $brain 'memory\BOOT.md') 'boot'
    $args0 = @('-MemoryDir', $mem, '-BrainPath', $brain, '-Json')
    $tens = Join-Path $kr 'lobe\tensions.json'

    # ---- absent: one line, not a failure ------------------------------------------------------------------------------------------
    $r = Run $args0
    Check 'absent: exit 0, ok, no findings' ($r.Code -eq 0 -and $r.J.ok -and -not @($r.J.findings).Count)
    Check 'absent: the JSON says absent and the summary is the one line' ($r.J.lobe.state -eq 'absent' -and $r.J.lobe.summary -eq 'lobe: no tensions file' -and $r.J.lobe.tensions -eq 0)
    $t = Run @('-MemoryDir', $mem, '-BrainPath', $brain)
    Check 'absent: text output has exactly one lobe line, "lobe: no tensions file"' ($t.Code -eq 0 -and @(($t.Out -split "`r?`n") | Where-Object { $_ -match '^lobe:' }).Count -eq 1 -and $t.Out -match '(?m)^lobe: no tensions file\r?$')
    $hb = Beat
    Check 'absent: heartbeat lobe=absent, tensions 0' ($hb.lobe -eq 'absent' -and $hb.tensions -eq 0 -and $hb.found -eq 0)

    # ---- unproven: the WARN count in the heartbeat ---------------------------------------------------------------------------------
    Check 'unproven: memory.json carries unproven = the WARN count (2), next to warn' ($hb.unproven -eq 2 -and $hb.warn -eq 2 -and @($hb.warnings).Count -eq 2)
    Check 'unproven: the JSON output carries it too' ($r.J.unproven -eq 2 -and $r.J.proofLint.warn -eq 2)
    Put (Join-Path $brain 'memory\NOW.md') "- build time 47 s`n- 3 suites in C:\x\y"
    Check 'unproven: one bullet fixed, the count goes down to 1 (a trend, not a constant)' ((Run $args0).Code -eq 0 -and (Beat).unproven -eq 1)
    Put (Join-Path $brain 'memory\NOW.md') "- build time 47 s`n- merged on 2026-01-02`n- 3 suites in C:\x\y`n- no fact here"

    # ---- present: each tension is a drift finding with both sources --------------------------------------------------------------
    $two = @'
[
 {"id": "aaaa1111bbbb2222", "subject": "build time for gizmo service = ?",
  "a": {"node": "n1", "value": "47", "statement": "Build time for the gizmo service is 47", "source": "memory:a.md", "at": "a.md:7", "t_valid_from": "2026-01-01", "trust": 0.5},
  "b": {"node": "n2", "value": "52", "statement": "Build time for the gizmo service is 52", "source": "memory:b.md", "at": "b.md:9", "t_valid_from": "2026-01-03", "trust": 0.5},
  "since": "2026-01-03", "weight": 0.9, "reviewed": false},
 {"id": "cccc3333dddd4444", "subject": "widget queue = ?",
  "a": {"node": "n3", "value": "4", "source": "memory:b.md", "at": "b.md:2", "t_valid_from": "2026-01-01", "trust": 0.8},
  "b": {"node": "n4", "value": "9", "source": "memory:a.md", "at": "a.md:3", "t_valid_from": "2026-01-01", "trust": 0.8},
  "since": "2026-01-01", "weight": 0.4, "reviewed": true}
]
'@
    Put $tens $two
    $before = [IO.File]::ReadAllBytes($tens)
    $r = Run $args0; $lf = LobeFound $r
    Check 'present: drift exit 3, not ok, two lobe findings' ($r.Code -eq 3 -and -not $r.J.ok -and $lf.Count -eq 2)
    $f1 = $lf | Where-Object { $_.tension -eq 'aaaa1111bbbb2222' }
    Check 'present: the finding names both sources as file:line, both values and since' ($f1.say -match [regex]::Escape('47 (a.md:7)') -and $f1.say -match [regex]::Escape('52 (b.md:9)') -and $f1.say -match 'since 2026-01-03' -and $f1.a -eq 'a.md:7' -and $f1.b -eq 'b.md:9')
    Check 'present: the finding file is the older side''s memory file' ($f1.file -eq 'a.md')
    Check 'present: plain words: memory disagrees with itself, and what settles it' ($f1.say -match '^memory disagrees with itself: build time for gizmo service' -and $f1.say -match "a proof or the Owner's decision settles it")
    $f2 = $lf | Where-Object { $_.tension -eq 'cccc3333dddd4444' }
    Check 'present: a reviewed tension (the Owner said unknown) is still drift, and says so' ($f2.say -match 'the Owner looked and said unknown' -and $f2.file -eq 'b.md')
    Check 'present: the JSON lobe block counts 2, state read' ($r.J.lobe.state -eq 'read' -and $r.J.lobe.tensions -eq 2 -and $r.J.lobe.unreadable -eq 0)
    $hb = Beat
    Check 'present: heartbeat found 2, tensions 2, lobe read, findings carry both' ($hb.found -eq 2 -and $hb.tensions -eq 2 -and $hb.lobe -eq 'read' -and @($hb.findings | Where-Object { $_.source -eq 'lobe' }).Count -eq 2)
    Check 'present: the WARN baseline is unchanged by tensions (unproven still 2)' ($hb.unproven -eq 2 -and $r.J.unproven -eq 2)
    Check 'present: memory-truth never writes the lobe''s file' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($tens)) -eq [Convert]::ToBase64String($before))
    $t = Run @('-MemoryDir', $mem, '-BrainPath', $brain)
    Check 'present: text output lists each tension under its file, and the lobe line counts them' ($t.Code -eq 3 -and $t.Out -match '(?m)^  a\.md: memory disagrees with itself' -and $t.Out -match '(?m)^  b\.md: memory disagrees with itself' -and $t.Out -match 'lobe: 2 tension\(s\) from ')

    # ---- wraps, never replaces: the own checks still find their drift next to the lobe's --------------------------------------------
    Put (Join-Path $mem 'MEMORY.md') "- [A](a.md) - a`n- [B](b.md) - b`n- [Gone](gone.md) - x"
    $r = Run $args0
    Check 'wraps: an index drift and both tensions are all reported (the lobe adds, never removes)' ($r.Code -eq 3 -and @($r.J.findings).Count -eq 3 -and @($r.J.findings | Where-Object { $_.say -match 'gone\.md' }).Count -eq 1 -and (LobeFound $r).Count -eq 2)
    Put (Join-Path $mem 'MEMORY.md') "- [A](a.md) - a`n- [B](b.md) - b"

    # ---- present but empty list: no tensions, not drift ----------------------------------------------------------------------------
    Put $tens '[]'
    $r = Run $args0
    Check 'empty list: exit 0, ok, lobe read with 0 tensions' ($r.Code -eq 0 -and $r.J.ok -and $r.J.lobe.state -eq 'read' -and $r.J.lobe.tensions -eq 0 -and $r.J.lobe.summary -match '^lobe: 0 tension')

    # ---- malformed: a damaged file is drift, never read as "no tensions" -------------------------------------------------------------
    Put $tens '[ {"id": "x", broken'
    $r = Run $args0
    Check 'malformed (not JSON): exit 3, one finding on lobe\tensions.json that says damaged and unknown' ($r.Code -eq 3 -and @($r.J.findings | Where-Object { $_.file -eq 'lobe\tensions.json' -and $_.say -match 'damaged \(it is not JSON' -and $_.say -match 'unknown' }).Count -eq 1 -and $r.J.lobe.state -eq 'damaged')
    Check 'malformed: the heartbeat says damaged' ((Beat).lobe -eq 'damaged' -and (Beat).found -eq 1)
    Put $tens ''
    Check 'malformed (empty file): drift, it is empty' (@((Run $args0).J.findings | Where-Object { $_.say -match 'damaged \(it is empty\)' }).Count -eq 1)
    Put $tens '{"subject": "x"}'
    Check 'malformed (an object, not a list): drift, it is not a list' (@((Run $args0).J.findings | Where-Object { $_.say -match 'damaged \(it is not a list\)' }).Count -eq 1)
    Put $tens '"just a string"'
    Check 'malformed (a bare string): drift, it is not a list' ((Run $args0).Code -eq 3)
    $t = Run @('-MemoryDir', $mem, '-BrainPath', $brain)
    Check 'malformed: the text lobe line points at the finding' ($t.Out -match 'lobe: the tensions file is damaged')
    # entries that cannot be read: counted in one finding; the good ones still reported
    $mixed = '[{"id":"good1","subject":"gauge = ?","a":{"value":"1","at":"a.md:1"},"b":{"value":"2","source":"memory:b.md"}},' +
        '{"id":"nob","subject":"s = ?","a":{"value":"1","at":"a.md:1"}},' +
        '{"id":"nosrc","subject":"s = ?","a":{"value":"1"},"b":{"value":"2","at":"b.md:1"}},' +
        '{"id":"nosubj","a":{"value":"1","at":"a.md:1"},"b":{"value":"2","at":"b.md:1"}}, 42, "text"]'
    Put $tens $mixed
    $r = Run $args0; $lf = LobeFound $r
    Check 'mixed: the readable tension is a finding; a side with only a source names that source' ($lf.Count -eq 1 -and $lf[0].say -match [regex]::Escape('2 (memory:b.md)') -and $lf[0].b -eq 'memory:b.md')
    Check 'mixed: 5 unreadable entries are one finding that says unknown, never dropped silently' ($r.J.lobe.unreadable -eq 5 -and @($r.J.findings | Where-Object { $_.file -eq 'lobe\tensions.json' -and $_.say -match '^5 tension\(s\).*could not be read.*unknown' }).Count -eq 1 -and $r.Code -eq 3)

    # ---- hostile text: control characters stripped, long text clipped ---------------------------------------------------------------
    $long = 'z' * 400
    Put $tens ('[{"id":"h1","subject":"evil\u001b[31m\u202esubject","a":{"value":"' + $long + '","at":"a.md:1"},"b":{"value":"2\r\nINJECT","at":"b.md:2"}}]')
    $r = Run $args0; $s = (LobeFound $r)[0].say
    Check 'hostile: no control or bidi characters reach the finding' ($s -and $s -notmatch '[\x00-\x1f\u202e]' -and $s -match 'evil \[31m subject' -and $s -match '2  INJECT')
    Check 'hostile: a long value is clipped to 60 characters' ($s -match ('z{60}\.\.\.') -and $s -notmatch 'z{61}')

    # ---- source checks: read-only on the lobe, and the old checks are all still there ------------------------------------------------
    $src = Get-Content -LiteralPath $truth -Raw
    Check 'source: the tensions file is only read (no Set-Content / WriteAll / Remove on it)' ($src -notmatch '(Set-Content|Out-File|WriteAll\w+|Remove-Item|Move-Item)[^\n]*\$tensPath')
    Check 'source: the own checks are all still there (index, frontmatter, paths, mode claims, ages, proof lint)' ($src -match 'the index links to' -and $src -match 'no frontmatter with a name' -and $src -match 'which does not exist' -and $src -match 'says the kitchen is paused' -and $src -match 'NOW\.md \(short-term memory\)' -and $src -match "states a fact with no proof and no 'unknown'")
} finally {
    $env:BRAIN_KITCHEN = $saved
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "Memory lobe tests: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
