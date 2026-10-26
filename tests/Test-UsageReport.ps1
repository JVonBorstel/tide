# Tests for scripts/usage-report.ps1 using small SYNTHETIC transcripts (no real data). Self-cleaning temp folder.
$ErrorActionPreference = 'Stop'
$ur = if ($env:UR_SCRIPT) { $env:UR_SCRIPT } else { Join-Path $PSScriptRoot '..\scripts\usage-report.ps1' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('ur-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Near($a, $b) { [math]::Abs([double]$a - [double]$b) -lt 0.011 }
$SECRET = 'SECRET_PROMPT_TEXT'

# One assistant line. Text/tool input carry the sentinel and must never reach the output.
function A($id, $ts, $model, $in, $cw, $cr, $out, $side = 'false', $agent = $null, $extra = '') {
    $ag = if ($agent) { ",`"agentId`":`"$agent`"" } else { '' }
    "{`"type`":`"assistant`",`"isSidechain`":$side$ag,`"timestamp`":`"$ts`",`"message`":{`"id`":`"$id`",`"model`":`"$model`",`"role`":`"assistant`",`"content`":[{`"type`":`"text`",`"text`":`"$SECRET $extra`"},{`"type`":`"tool_use`",`"input`":{`"file_path`":`"C:\\private\\$SECRET.txt`"}}],`"usage`":{`"input_tokens`":$in,`"cache_creation_input_tokens`":$cw,`"cache_read_input_tokens`":$cr,`"output_tokens`":$out}}}"
}
function W($rel, $lines) {
    $p = Join-Path $root "projects\$rel"; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
    [IO.File]::WriteAllLines($p, [string[]]$lines)
}
function Run($a) { $o = & pwsh -NoProfile -File $ur @a 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }

try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $huge = 'HUGEHUGE' * 20000   # 160 KB of text in one line
    # sess1: sidechain line FIRST (must not become boot), duplicate of msg1, malformed line, non-usage line, attachment with usage
    W 'projA\sess1.jsonl' @(
        (A 'side1m' '2026-10-01T09:59:00.000Z' 'm-b' 1 1000 0 1 'true' 'side1'),
        (A 'msg1' '2026-10-01T10:00:00.000Z' 'm-a' 10 200 0 20),
        (A 'msg1' '2026-10-01T10:00:01.000Z' 'm-a' 10 200 0 20),
        '{"type":"assistant","usage": BROKEN {{ ',
        "{`"type`":`"user`",`"message`":{`"content`":`"$SECRET`"}}",
        "{`"type`":`"attachment`",`"isSidechain`":false,`"timestamp`":`"2026-10-01T10:02:00.000Z`",`"message`":{`"usage`":{`"input_tokens`":999999,`"output_tokens`":999999}}}",
        (A 'msg2' '2026-10-01T10:05:00.000Z' 'm-a' 5 100 300 50),
        (A 'msg3' '2026-10-02T09:00:00.000Z' 'm-b' 2 0 700 10),
        (A 'msg4' '2026-10-02T09:30:00.000Z' 'm-b' 1 0 600 100),
        (A 'msg5' '2026-10-02T12:00:00.000Z' 'm-a' 1 0 0 1 'false' $null $huge)
    )
    W 'projA\sess1\subagents\agent-abc.jsonl' @(
        (A 'abc1' '2026-10-02T10:00:00.000Z' 'm-b' 3 500 0 10 'true' 'abc'),
        (A 'abc2' '2026-10-02T10:00:05.000Z' 'm-b' 1 0 500 20 'true' 'abc')
    )
    W 'projA\sess1\subagents\agent-abc.meta.json' @("{`"agentType`":`"builder`",`"description`":`"$SECRET`"}")
    # no agentId field: id comes from the file name; not flagged sidechain in the line itself but lives in subagents\
    W 'projA\sess1\subagents\agent-def.jsonl' @((A 'def1' '2026-10-02T11:00:00.000Z' 'm-a' 10 0 0 100 'false'))
    # nested under subagents\workflows\...: still belongs to sess2 as a subagent; journal.jsonl has a non-assistant "usage" line
    W 'projA\sess2\subagents\workflows\wf_1\agent-ghi.jsonl' @((A 'ghi1' '2026-10-03T01:00:00.000Z' 'm-a' 0 0 100 0 'true' 'ghi'))
    W 'projA\sess2\subagents\workflows\wf_1\journal.jsonl' @("{`"type`":`"journal`",`"usage`":`"$SECRET`"}")
    W 'projA\sess2.jsonl' @((A 's2m1' '2026-10-03T00:00:00.000Z' 'm-a' 100 0 900 0))
    W 'projA\sess3.jsonl' @("{`"type`":`"user`",`"message`":{`"content`":`"$SECRET`"}}", '{"type":"summary"}')
    W 'projB\sess4.jsonl' @((A 's4m1' '2026-09-01T08:00:00.000Z' 'm-a' 1 0 0 1))
    $proj = Join-Path $root 'projects'
    $before = (Get-ChildItem $proj -Recurse -File | Sort-Object FullName | % { (Get-FileHash $_.FullName).Hash }) -join ','

    # ---- JSON, all data, window 1000
    $r = Run @('-ProjectsDir', $proj, '-Window', '1000', '-Json')
    Check 'json run exit 0' ($r.Code -eq 0)
    $j = $null; try { $j = $r.Out | ConvertFrom-Json } catch { }
    Check 'json parses' ($null -ne $j)
    if ($j) {
        $t = $j.total
        Check 'total turns 12 (dedupe, malformed, attachment ignored)' ($t.turns -eq 12)
        Check 'total input 135' ($t.input -eq 135)
        Check 'total cache write 1800' ($t.cacheWrite -eq 1800)
        Check 'total cache read 3100' ($t.cacheRead -eq 3100)
        Check 'total output 313' ($t.output -eq 313)
        Check 'total weighted units 4260' (Near $t.units 4260)
        Check 'main units 1655' (Near $t.mainUnits 1655)
        Check 'sub units 2605' (Near $t.subUnits 2605)
        Check 'cache read share 57.97%' (Near $t.cacheReadSharePct 57.97)
        Check 'malformed lines 1' ($j.malformedLines -eq 1)
        Check 'sessions listed 3 (no-usage session omitted)' (@($j.sessions).Count -eq 3)
        $s1 = @($j.sessions | ? { $_.id -eq 'sess1' })[0]; $s2 = @($j.sessions | ? { $_.id -eq 'sess2' })[0]; $s4 = @($j.sessions | ? { $_.id -eq 'sess4' })[0]
        Check 'sess1 turns 9 (5 main + 4 sidechain)' ($s1.turns -eq 9)
        Check 'sess1 main turns 5' ($s1.mainTurns -eq 5)
        Check 'sess1 main units 1459' (Near $s1.mainUnits 1459)
        Check 'sess1 sub units 2595' (Near $s1.subUnits 2595)
        Check 'sess2 turns 2 (main + nested workflow subagent), main 1' ($s2.turns -eq 2 -and $s2.mainTurns -eq 1 -and $s2.subTurns -eq 1)
        Check 'sess1 total units 4054' (Near $s1.units 4054)
        Check 'sess1 boot 210 (first MAIN entry, not sidechain)' ($s1.boot -eq 210)
        Check 'sess1 peak main context 702' ($s1.peakContext -eq 702)
        Check 'sess1 above50 units 683' (Near $s1.unitsAbove50 683)
        Check 'sess1 above65 units 122' (Near $s1.unitsAbove65 122)
        Check 'sess1 share50 46.81%' (Near $s1.share50Pct 46.81)
        Check 'sess1 share65 8.36%' (Near $s1.share65Pct 8.36)
        Check 'sess2 boot 1000 peak 1000' ($s2.boot -eq 1000 -and $s2.peakContext -eq 1000)
        Check 'sess2 share 100/100' ((Near $s2.share50Pct 100) -and (Near $s2.share65Pct 100))
        Check 'sess4 boot 1' ($s4.boot -eq 1)
        Check 'boot min 1' ($j.boot.min -eq 1)
        Check 'boot median 210' ($j.boot.median -eq 210)
        Check 'boot max 1000' ($j.boot.max -eq 1000)
        Check 'overall share50 52.75%' (Near $j.above.share50Pct 52.75)
        Check 'overall share65 18.85%' (Near $j.above.share65Pct 18.85)
        $sa = @($j.subagents)
        Check 'subagents 4' ($sa.Count -eq 4)
        Check 'top subagent side1 1256' ($sa[0].id -eq 'side1' -and (Near $sa[0].units 1256) -and $sa[0].turns -eq 1 -and $sa[0].peakContext -eq 1001 -and $sa[0].model -eq 'm-b')
        Check 'second subagent abc builder 829' ($sa[1].id -eq 'abc' -and (Near $sa[1].units 829) -and $sa[1].turns -eq 2 -and $sa[1].peakContext -eq 503 -and $sa[1].agentType -eq 'builder')
        Check 'third subagent def (id from filename) 510' ($sa[2].id -eq 'def' -and (Near $sa[2].units 510) -and $sa[2].peakContext -eq 10 -and $sa[2].model -eq 'm-a')
        Check 'fourth subagent ghi (nested workflows dir, session sess2) 10' ($sa[3].id -eq 'ghi' -and $sa[3].session -eq 'sess2' -and (Near $sa[3].units 10) -and $sa[3].peakContext -eq 100)
        $ma = @($j.models | ? { $_.model -eq 'm-a' })[0]; $mb = @($j.models | ? { $_.model -eq 'm-b' })[0]
        Check 'model m-a units 1492 turns 7' ((Near $ma.units 1492) -and $ma.turns -eq 7)
        Check 'model m-b units 2768 turns 5' ((Near $mb.units 2768) -and $mb.turns -eq 5)
        $d = @{}; foreach ($x in $j.days) { $d[$x.day] = $x }
        Check 'day 2026-10-01 2026' ((Near $d['2026-10-01'].units 2026))
        Check 'day 2026-10-02 2028' ((Near $d['2026-10-02'].units 2028))
        Check 'day 2026-10-03 200' ((Near $d['2026-10-03'].units 200))
        Check 'day 2026-09-01 6' ((Near $d['2026-09-01'].units 6))
    }

    # ---- custom weights (all 1) -> units are plain token sums
    $r = Run @('-ProjectsDir', $proj, '-Window', '1000', '-Json', '-WCacheWrite', '1', '-WCacheRead', '1', '-WOutput', '1')
    $j2 = $null; try { $j2 = $r.Out | ConvertFrom-Json } catch { }
    Check 'custom weights: units = 5348' ($j2 -and (Near $j2.total.units 5348))

    # ---- Since filter drops the 2026-09-01 entry
    $r = Run @('-ProjectsDir', $proj, '-Window', '1000', '-Json', '-Since', '2026-10-01')
    $j3 = $null; try { $j3 = $r.Out | ConvertFrom-Json } catch { }
    Check 'since: units 4254' ($j3 -and (Near $j3.total.units 4254) -and @($j3.sessions).Count -eq 2)
    Check 'since: boot median of two = 605' ($j3 -and $j3.boot.median -eq 605 -and $j3.boot.min -eq 210)

    # ---- default window is 1,000,000: nothing above 50%
    $r = Run @('-ProjectsDir', $proj, '-Json')
    $j4 = $null; try { $j4 = $r.Out | ConvertFrom-Json } catch { }
    Check 'default window 1M: share50 0' ($j4 -and (Near $j4.above.share50Pct 0) -and $j4.params.window -eq 1000000)

    # ---- Markdown
    $out = Join-Path $root 'report.md'
    $r = Run @('-ProjectsDir', $proj, '-Window', '1000', '-OutPath', $out)
    Check 'md exit 0' ($r.Code -eq 0)
    $md = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    $mdLines = @(Get-Content $out).Count
    Check 'md <= 60 lines' ($mdLines -gt 5 -and $mdLines -le 60)
    Check 'md says APPROXIMATE not dollars' ($md -match 'APPROXIMATE' -and $md -match 'NOT dollars')
    Check 'md has total units' ($md -match '4,260')
    Check 'md has boot line' ($md -match '(?i)boot' -and $md -match '1,000')
    Check 'md names top subagent' ($md -match 'side1' -and $md -match 'builder')
    Check 'md has per-day and model sections' ($md -match '2026-10-02' -and $md -match 'm-a' -and $md -match 'm-b')
    Check 'md notes malformed' ($md -match '(?i)malformed')
    Check 'md has no dollar sign' ($md -notmatch '\$')

    # ---- privacy: sentinel and huge text never appear anywhere
    $all = $md + $r.Out + (Run @('-ProjectsDir', $proj, '-Json')).Out + (Run @('-ProjectsDir', $proj)).Out
    Check 'privacy: no sentinel in any output' ($all -notmatch 'SECRET_PROMPT_TEXT')
    Check 'privacy: no private path text' ($all -notmatch 'private')
    Check 'privacy: no huge text' ($all -notmatch 'HUGEHUGE')
    Check 'privacy: no message/content words' ($all -notmatch '(?i)tool_use|file_path')
    Check 'privacy: output is small' ($all.Length -lt 20000)

    # ---- read only
    $after = (Get-ChildItem $proj -Recurse -File | Sort-Object FullName | % { (Get-FileHash $_.FullName).Hash }) -join ','
    Check 'read only: fixtures unchanged' ($before -eq $after)

    # ---- errors are loud
    $r = Run @('-ProjectsDir', (Join-Path $root 'nope')); Check 'missing dir exit 2' ($r.Code -eq 2)
    $r = Run @('-ProjectsDir', $proj, '-Since', 'yesterday'); Check 'bad Since exit 2' ($r.Code -eq 2)
    $empty = Join-Path $root 'empty'; New-Item -ItemType Directory $empty | Out-Null
    $r = Run @('-ProjectsDir', $empty); Check 'empty dir exit 0 no crash' ($r.Code -eq 0)
    $r = Run @('-ProjectsDir', $empty, '-Json'); Check 'empty dir json parses' ($null -ne ($r.Out | ConvertFrom-Json -ErrorAction SilentlyContinue))

    # ---- README lists the script
    Check 'README mentions usage-report.ps1' ((Get-Content (Join-Path $PSScriptRoot '..\README.md') -Raw) -match 'usage-report\.ps1')
} finally { if (Test-Path $root) { Get-ChildItem $root -Recurse -Force | % { $_.Attributes = 'Normal' }; Remove-Item -Recurse -Force $root } }
Write-Host "UsageReport tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
