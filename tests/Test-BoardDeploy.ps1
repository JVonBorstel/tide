# Tests for pass-app/update.ps1's deploy guard: the served-page check uses markers, not the page title, and the Board task name lookup.
# Called by the kitchen tests station (it globs tests\Test-*.ps1) and by hand through scripts/run-bounded.ps1. Private temp root; self-cleaning.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$upd = Join-Path $repo 'pass-app\update.ps1'
$index = Join-Path $repo 'pass-app\public\index.html'
$pwshBin = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-deploy-' + [guid]::NewGuid().ToString('N'))
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Run([string]$script, [string[]]$a) { $o = & $pwshBin -NoProfile -NonInteractive -File $script @a 2>&1 | Out-String; [pscustomobject]@{ code = $LASTEXITCODE; out = $o } }
function Retitle([string]$src, [string]$dst, [string]$title) { Set-Content -LiteralPath $dst -Value ((Get-Content -LiteralPath $src -Raw) -replace '<title>[^<]*</title>', "<title>$title</title>") -NoNewline -Encoding utf8 }
$saved = @{}; foreach ($n in 'BRAIN_KITCHEN', 'PASS_NO_TAILSCALE', 'PASS_HOSTS', 'BRAIN_NTFY_TOPIC', 'KITCHEN_OLLAMA_URL', 'KITCHEN_AGY_EXE', 'TEMP', 'TMP') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
try {
    New-Item -ItemType Directory -Force $root | Out-Null
    $src = Get-Content -LiteralPath $upd -Raw

    # 1. the deploy check does not look at the page title
    Check 'update.ps1 has no <title> match' ($src -notmatch '<title>')

    # 2. both markers are in the real page
    $html = Get-Content -LiteralPath $index -Raw
    Check 'index.html carries id="view-pass" and the app.js module script tag' ($html.Contains('id="view-pass"') -and $html.Contains('<script src="/app.js" type="module">'))

    # 3. dry run unchanged (same match as tests/Test-KitchenSupervisor.ps1 9.1)
    $r = Run $upd @('-DryRun')
    Check 'update.ps1 -DryRun still prints the dry-run line' ($r.code -eq 0 -and $r.out -match 'Chef update dry-run ok: syntax valid')

    # 4. task name: no task-names.json -> Kitchen-Pass; a file -> its board name; a broken file stops before anything is touched
    $r = Run $upd @('-ShowTaskName', '-TaskNamesPath', (Join-Path $root 'no-such\task-names.json'))
    Check 'with no task-names.json the task name resolves to Kitchen-Pass' ($r.code -eq 0 -and $r.out -match '(?m)^board task: Kitchen-Pass\s*$')
    $tn = Join-Path $root 'task-names.json'; $g = [guid]::NewGuid().ToString('N').Substring(0, 8)
    Set-Content -LiteralPath $tn -Value "{`"board`":[`"BoardTestOld-$g`",`"BoardTestNew-$g`"]}"
    $r = Run $upd @('-ShowTaskName', '-TaskNamesPath', $tn)
    Check 'task-names.json board name is used (first name when none is registered)' ($r.code -eq 0 -and $r.out -match "(?m)^board task: BoardTestOld-$g\s*$")
    Set-Content -LiteralPath $tn -Value '{not json'
    $r = Run $upd @('-DryRun', '-TaskNamesPath', $tn)
    Check 'a broken task-names.json fails the deploy before the swap' ($r.code -eq 1 -and $r.out -match 'NOT UPDATED: task-names\.json is not valid JSON')

    # 5. page check on files: old title, new title, and a page without the markers
    $r = Run $upd @('-CheckPage', $index)
    Check 'page check passes with the old title' ($r.code -eq 0 -and $r.out -match 'page ok')
    $newPage = Join-Path $root 'new-title.html'; Retitle $index $newPage 'The Board'
    $r = Run $upd @('-CheckPage', $newPage)
    Check 'page check passes with a new title' ($r.code -eq 0 -and $r.out -match 'page ok' -and (Get-Content $newPage -Raw) -match '<title>The Board</title>')
    $badPage = Join-Path $root 'no-markers.html'; Set-Content -LiteralPath $badPage -Value ($html.Replace('id="view-pass"', 'id="view-x"')) -NoNewline
    $r = Run $upd @('-CheckPage', $badPage)
    Check 'page check fails when a marker is gone' ($r.code -eq 1 -and $r.out -match 'NOT UPDATED: the page lacks id="view-pass"')

    # 6. the real trial (a copy of pass-app on spare ports against a private kitchen root; the live Board is never touched)
    $app = Join-Path $root 'pass-app'; Copy-Item -LiteralPath (Join-Path $repo 'pass-app') -Destination $app -Recurse
    # the server loads modules from outside pass-app (pass-app/work/*.mjs imports ../../core/...) and reads the repo's flags.json, so the
    # copy also carries every top folder that pass-app's relative imports reach (derived from the code, never a hand list) and flags.json
    $reach = @(foreach ($f in Get-ChildItem (Join-Path $repo 'pass-app') -Recurse -File -Include '*.mjs', '*.js' | Where-Object { $_.FullName -notmatch '\\node_modules\\' }) {
            foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f.FullName), '(?:\bfrom|\bimport\()\s*[''"]((?:\.\./)+[^''"]+)[''"]')) {
                $to = [IO.Path]::GetFullPath((Join-Path $f.DirectoryName $m.Groups[1].Value))
                if ($to.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) { $to.Substring($repo.Length + 1).Split('\')[0] }
            }
        }) | Where-Object { $_ -ne 'pass-app' } | Sort-Object -Unique
    foreach ($d in $reach) { Copy-Item -LiteralPath (Join-Path $repo $d) -Destination (Join-Path $root $d) -Recurse }
    Copy-Item -LiteralPath (Join-Path $repo 'flags.json') -Destination (Join-Path $root 'flags.json')
    Check "the trial copy carries what the server loads from outside pass-app (folders: $($reach -join ', '); flags.json)" ($reach -contains 'core' -and (Test-Path -LiteralPath (Join-Path $root 'core\ship\flags.mjs')) -and (Test-Path -LiteralPath (Join-Path $root 'flags.json')))
    $kr = Join-Path $root 'kitchen'; New-Item -ItemType Directory -Force (Join-Path $kr 'jobs') | Out-Null
    $env:BRAIN_KITCHEN = $kr; $env:PASS_NO_TAILSCALE = '1'; $env:PASS_HOSTS = 'board-test.tailnet-test.example'; $env:BRAIN_NTFY_TOPIC = $null
    $env:KITCHEN_OLLAMA_URL = 'off'; $env:KITCHEN_AGY_EXE = 'off'; $env:TEMP = $root; $env:TMP = $root
    $cUpd = Join-Path $app 'update.ps1'; $cIdx = Join-Path $app 'public\index.html'
    $p = Get-Random -Minimum 40001 -Maximum 50000
    $trial = { param($t) Run $cUpd @('-TrialOnly', '-Port', "$p", '-TrialPort', "$t") }
    $r = & $trial ($p + 1)
    Check 'real trial passes with the old title' ($r.code -eq 0 -and $r.out -match 'trial ok:' -and $r.out -match 'trial only: the live server was not touched')
    Retitle $cIdx $cIdx 'The Board'
    $r = & $trial ($p + 2)
    Check 'real trial passes with a new title' ($r.code -eq 0 -and $r.out -match 'trial ok:' -and (Get-Content $cIdx -Raw) -match '<title>The Board</title>')
    Set-Content -LiteralPath $cIdx -Value ((Get-Content -LiteralPath $cIdx -Raw).Replace('<script src="/app.js" type="module">', '<script src="/app.js">')) -NoNewline
    $r = & $trial ($p + 3)
    Check 'real trial fails when the app script tag is gone' ($r.code -eq 1 -and $r.out -match 'did not serve the app \(missing <script src="/app\.js" type="module">\)' -and $r.out -notmatch 'trial ok:')

    # 7. the restart decision: the server fingerprint covers every local module server.mjs reaches, not server.mjs alone
    #    (a merge that changed only towers.mjs or work/api.mjs once left the live Board on old code)
    $sid = Join-Path $repo 'pass-app\server-id.mjs'
    Check 'update.ps1 asks server-id.mjs for the fingerprint, never hashes server.mjs alone' ($src -match 'server-id\.mjs' -and $src -notmatch 'Get-FileHash \$srv')
    $fp = Join-Path $root 'fp'; New-Item -ItemType Directory -Force (Join-Path $fp 'app'), (Join-Path $fp 'lib') | Out-Null
    Set-Content (Join-Path $fp 'app\entry.mjs') "import { a } from './a.mjs';`nconst b = await import('../lib/b.mjs');`nimport x from './missing.mjs';"
    foreach ($f in 'app\a.mjs', 'lib\b.mjs', 'app\other.mjs') { Set-Content (Join-Path $fp $f) "export const v = 1;" }
    $id = { "$(& node $sid (Join-Path $fp 'app\entry.mjs'))".Trim() }
    $id0 = & $id
    Check 'fingerprint is 12 hex and stable across runs' ($id0 -match '^[0-9a-f]{12}$' -and (& $id) -eq $id0)
    Add-Content (Join-Path $fp 'app\a.mjs') '// changed'; $id1 = & $id
    Check 'a change to a statically imported module changes the fingerprint' ($id1 -ne $id0)
    Add-Content (Join-Path $fp 'lib\b.mjs') '// changed'; $id2 = & $id
    Check 'a change to a dynamically imported module in another folder changes the fingerprint' ($id2 -ne $id1)
    Add-Content (Join-Path $fp 'app\other.mjs') '// changed'
    Check 'a change to a file the entry never imports leaves the fingerprint alone' ((& $id) -eq $id2)
    $files = & node --input-type=module -e "import { serverFiles } from '$(([Uri]$sid).AbsoluteUri)'; console.log(serverFiles(process.argv[1]).join('\n'))" (Join-Path $repo 'pass-app\server.mjs')
    Check 'the real server fingerprint covers towers.mjs, work/api.mjs and the core modules it reaches' ((@($files) -match 'pass-app[\\/]towers\.mjs$').Count -eq 1 -and (@($files) -match 'work[\\/]api\.mjs$').Count -eq 1 -and (@($files) -match '[\\/]core[\\/]').Count -ge 1)
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "BoardDeploy tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -gt 0))
