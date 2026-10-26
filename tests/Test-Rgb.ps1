# Tests for scripts/rgb.ps1 (internal RGB control via OMEN Light Studio UI Automation + scheduled tasks).
# The UI-driving part needs the real app and is verified by hand; everything else (argument rules, dry-run plans, the schedule
# plan via -PlanOnly, status, removal) is tested here. Real task registration only runs by hand with RGB_TEST_REAL=1.
$ErrorActionPreference = 'Stop'
$rgb = Join-Path $PSScriptRoot '..\scripts\rgb.ps1'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Rgb { param([string[]]$a) $o = pwsh -NoProfile -File $rgb @a 2>&1 | Out-String; $script:o = $o; $script:ec = $LASTEXITCODE }

# argument rules
Rgb @('-Action', 'set', '-Brightness', '150', '-DryRun'); Check 'brightness >100 rejected' ($ec -ne 0)
Rgb @('-Action', 'set', '-Brightness', '-5', '-DryRun'); Check 'brightness <0 rejected' ($ec -ne 0)
Rgb @('-Action', 'set', '-DryRun'); Check 'set without brightness rejected' ($ec -eq 2)
Rgb @('-Action', 'bogus'); Check 'unknown action rejected' ($ec -ne 0)

# dry run never touches the app
Rgb @('-Action', 'set', '-Brightness', '0', '-DryRun'); Check 'dry run ok' ($ec -eq 0 -and $o -match 'DRY RUN' -and $o -match 'brightness 0')
Check 'dry run opened no window' (-not (Get-Process -Name 'LightStudio*' -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -gt (Get-Date).AddSeconds(-20) }))

# time rules
Rgb @('-Action', 'install-schedule', '-OffAt', '25:99', '-OnAt', '07:00', '-TaskPrefix', 'RigRgbTest', '-DryRun'); Check 'bad time rejected' ($ec -eq 2)
Rgb @('-Action', 'install-schedule', '-OffAt', '22:00', '-OnAt', '22:00', '-TaskPrefix', 'RigRgbTest', '-DryRun'); Check 'same on/off time rejected' ($ec -eq 2)

# schedule plan: the exact task objects install-schedule would register, printed instead of registered. A test run never
# creates real scheduled tasks: under the kitchen this file runs from a job worktree, and a task left behind by a timeout or a
# killed job would run AI-edited code every day without Jordan's yes.
Rgb @('-Action', 'install-schedule', '-OffAt', '22:00', '-OnAt', '07:00', '-OnBrightness', '60', '-TaskPrefix', 'RigRgbPlan', '-PlanOnly')
Check 'plan exit 0' ($ec -eq 0)
$plan = @(try { $o | ConvertFrom-Json } catch { }); $off = $plan | Where-Object name -eq 'RigRgbPlan-Off'; $on = $plan | Where-Object name -eq 'RigRgbPlan-On'
Check 'plan has both tasks' ($null -ne $off -and $null -ne $on)
Check 'plan registered nothing' ($null -eq (Get-ScheduledTask -TaskName 'RigRgbPlan-*' -ErrorAction SilentlyContinue))
if ($off -and $on) {
    Check 'off task time 22:00' ($off.at -eq '22:00')
    Check 'on task time 07:00' ($on.at -eq '07:00')
    Check 'off task runs rgb.ps1 set 0' (($off.arguments -match 'rgb\.ps1') -and ($off.arguments -match '-Brightness 0'))
    Check 'on task uses brightness 60' ($on.arguments -match '-Brightness 60')
    Check 'headless: runs wscript //B run-hidden.vbs "<pwsh>" (no console flash, exit code kept)' ($off.execute -eq (Join-Path $env:SystemRoot 'System32\wscript.exe') -and $off.arguments -match '^//B //NoLogo "[^"]*\\scripts\\run-hidden\.vbs" "[^"]*\\pwsh\.exe" -NoProfile ' -and $on.execute -eq $off.execute)
    Check 'runs as current user, interactive, not elevated' ($off.logonType -eq 'Interactive' -and $off.runLevel -eq 'Limited')
    Check 'time limit set' ($off.timeLimit -match 'PT[0-9]+M')
    Check 'no overlapping runs' ($off.multipleInstances -eq 'IgnoreNew')
}
Rgb @('-Action', 'remove-schedule', '-TaskPrefix', ('RigRgbNone' + [guid]::NewGuid().ToString('N'))); Check 'removing a schedule that is not there is fine' ($ec -eq 0)
Rgb @('-Action', 'status', '-TaskPrefix', ('RigRgbNone' + [guid]::NewGuid().ToString('N'))); Check 'status with nothing scheduled' ($ec -eq 0 -and $o -match 'not scheduled')

# real Task Scheduler lifecycle: only when Jordan runs it by hand with RGB_TEST_REAL=1, never inside the kitchen. GUID prefix
# (no collisions between runs) and try/finally (the tasks go even when a check throws).
if ($env:RGB_TEST_REAL -eq '1' -and -not $env:KITCHEN_JOB -and -not $env:KITCHEN_RUN) {
    $pfx = 'RigRgbTest' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    try {
        Rgb @('-Action', 'install-schedule', '-OffAt', '22:00', '-OnAt', '07:00', '-OnBrightness', '60', '-TaskPrefix', $pfx)
        Check 'real: install-schedule exit 0' ($ec -eq 0)
        Check 'real: both tasks exist' ($null -ne (Get-ScheduledTask -TaskName "$($pfx)-Off" -ErrorAction SilentlyContinue) -and $null -ne (Get-ScheduledTask -TaskName "$($pfx)-On" -ErrorAction SilentlyContinue))
        Rgb @('-Action', 'status', '-TaskPrefix', $pfx); Check 'real: status lists both' ($ec -eq 0 -and $o -match 'Off' -and $o -match 'On')
    } finally {
        Rgb @('-Action', 'remove-schedule', '-TaskPrefix', $pfx); Check 'real: remove exit 0' ($ec -eq 0)
        Check 'real: tasks removed' ($null -eq (Get-ScheduledTask -TaskName "$($pfx)-*" -ErrorAction SilentlyContinue))
    }
}

Write-Host "Rgb tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
