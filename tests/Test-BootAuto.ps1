# Tests for scripts/boot-inject.ps1 (SessionStart: load the boot pack) and scripts/refresh-boot.ps1 (PreCompact: rebuild it).
# Both are hooks: they must NEVER fail or block (always exit 0) and never emit secrets. Fixtures only; self-cleaning.
$ErrorActionPreference = 'Stop'
$bi = Join-Path $PSScriptRoot '..\scripts\boot-inject.ps1'
$rb = Join-Path $PSScriptRoot '..\scripts\refresh-boot.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ba-' + [guid]::NewGuid().ToString('N'))
$brain = Join-Path $root 'brain'; New-Item -ItemType Directory -Path (Join-Path $brain 'memory') -Force | Out-Null
$boot = Join-Path $brain 'memory\BOOT.md'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Bi($payload = '{"hook_event_name":"SessionStart","source":"startup"}', [string[]]$extra = @()) { $o = $payload | pwsh -NoProfile -File $bi -BootPath $boot @extra 2>&1 | Out-String; $script:ec = $LASTEXITCODE; $script:o = $o }

# --- boot-inject ---
Set-Content $boot "# BOOT PACK fixture`nNOW: do the thing`n" -Encoding utf8
Bi; Check 'fresh pack exit 0' ($ec -eq 0)
$j = $o | ConvertFrom-Json
Check 'emits SessionStart additionalContext' ($j.hookSpecificOutput.hookEventName -eq 'SessionStart' -and $j.hookSpecificOutput.additionalContext -match 'do the thing')
Check 'framed as data, not instructions' ($j.hookSpecificOutput.additionalContext -match 'DATA')
Check 'SessionStart shows the Toolbox talk header' ($j.hookSpecificOutput.additionalContext.StartsWith('TOOLBOX TALK (memory/BOOT.md'))

# stale pack is flagged, not silently trusted
(Get-Item $boot).LastWriteTime = (Get-Date).AddDays(-3)
Bi; $j = $o | ConvertFrom-Json
Check 'stale flagged' ($j.hookSpecificOutput.additionalContext -match 'STALE' -and $j.hookSpecificOutput.additionalContext -match 'refresh-boot')
Check 'stale user message' ($j.systemMessage -match 'stale')
(Get-Item $boot).LastWriteTime = (Get-Date).AddHours(-13)
Bi; $j = $o | ConvertFrom-Json
Check 'a 13-hour-old pack is already stale (it hides what waits for a yes)' ($j.hookSpecificOutput.additionalContext -match 'STALE')

# missing pack is flagged, exit 0
Remove-Item $boot; Bi; $j = $o | ConvertFrom-Json
Check 'missing flagged' ($ec -eq 0 -and $j.hookSpecificOutput.additionalContext -match 'MISSING')

# oversize pack is capped
Set-Content $boot ('x' * 20000) -Encoding utf8
Bi; $j = $o | ConvertFrom-Json
Check 'oversize capped' ($j.hookSpecificOutput.additionalContext.Length -lt 10500 -and $j.hookSpecificOutput.additionalContext -match 'truncated')

# a pack containing a secret shape is never injected
Set-Content $boot ('leak AKIA' + 'ABCDEFGHIJKLMNOP end') -Encoding utf8
Bi; Check 'secret not injected' ($o -notmatch 'AKIAABCDEFGHIJKLMNOP' -and $ec -eq 0 -and $o -match 'secret')

# garbage stdin never breaks the hook
Set-Content $boot "# ok" -Encoding utf8
Bi 'not json'; Check 'garbage stdin exit 0' ($ec -eq 0)

# --- refresh-boot ---
Remove-Item $boot -ErrorAction SilentlyContinue
Set-Content (Join-Path $brain 'memory\NOW.md') "# NOW`nfixture"
$fakeK = Join-Path $root 'k.ps1'; Set-Content $fakeK 'Write-Output "OK"; exit 0'
$o2 = '{"hook_event_name":"PreCompact","trigger":"auto"}' | pwsh -NoProfile -File $rb -BrainPath $brain -Repos $root -KitchenScript $fakeK -StandupDir (Join-Path $root 'none') 2>&1 | Out-String
Check 'refresh exit 0' ($LASTEXITCODE -eq 0)
Check 'refresh wrote pack' ((Test-Path $boot) -and ((Get-Content $boot -Raw) -match 'fixture'))
Check 'refresh output small' ($o2.Length -lt 600)

# refresh never blocks compaction, even when handoff fails (bad brain path)
$o3 = '{}' | pwsh -NoProfile -File $rb -BrainPath (Join-Path $root 'does-not-exist') -Repos $root 2>&1 | Out-String
Check 'refresh failure still exit 0' ($LASTEXITCODE -eq 0)

# refresh bounded: a hung kitchen script cannot hold up compaction beyond the timeout
$hangK = Join-Path $root 'hang.ps1'; Set-Content $hangK 'Start-Sleep 60'
$sw = [Diagnostics.Stopwatch]::StartNew()
$o4 = '{}' | pwsh -NoProfile -File $rb -BrainPath $brain -Repos $root -KitchenScript $hangK -KitchenTimeoutSeconds 2 -StandupDir (Join-Path $root 'none') 2>&1 | Out-String
Check 'hung kitchen bounded' ($LASTEXITCODE -eq 0 -and $sw.Elapsed.TotalSeconds -lt 40)

Remove-Item -Recurse -Force $root
Write-Host "BootAuto tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
