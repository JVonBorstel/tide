# Internal RGB control for this OMEN rig via the OMEN Light Studio window (UI Automation) + optional daily schedule.
# Needs HP OMEN Gaming Hub installed (it is) and the user logged in. Local only: no network, no admin, no secrets.
#   rgb.ps1 -Action set -Brightness 0..100 [-KeepOpen] [-DryRun]
#   rgb.ps1 -Action install-schedule [-OffAt 22:00] [-OnAt 07:00] [-OnBrightness 100] [-TaskPrefix Rig-RGB] [-PlanOnly]
#   -PlanOnly builds the exact task objects and prints them as JSON without registering (what the tests check, so a test run never leaves real tasks)
#   rgb.ps1 -Action status | remove-schedule [-TaskPrefix Rig-RGB]
# Exit: 0 ok, 1 failed (see log), 2 bad arguments. Log: %LOCALAPPDATA%\brain-rgb\rgb.log
param(
    [ValidateSet('set', 'install-schedule', 'remove-schedule', 'status')][string]$Action = 'status',
    [ValidateRange(0, 100)][int]$Brightness = -1,
    [string]$OffAt = '22:00', [string]$OnAt = '07:00',
    [ValidateRange(0, 100)][int]$OnBrightness = 100,
    [string]$TaskPrefix = 'Rig-RGB',
    [switch]$KeepOpen, [switch]$DryRun, [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:LOCALAPPDATA 'brain-rgb'; $logFile = Join-Path $logDir 'rgb.log'
function Log($m) { try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null; Add-Content -LiteralPath $logFile -Value ("{0} {1}" -f (Get-Date -Format 's'), $m) } catch { } }
function BadTime($t) { -not ($t -match '^([01]\d|2[0-3]):[0-5]\d$') }
$appId = 'AD2F1837.OMENLightStudio_v10z8vjag6ke6!AD2F1837.OMENLightStudio'

switch ($Action) {
    'set' {
        if ($Brightness -lt 0) { Write-Output 'ERROR: -Brightness 0..100 is required for -Action set'; exit 2 }
        if ($DryRun) { Write-Output "DRY RUN: would open OMEN Light Studio, set brightness $Brightness, then close it"; exit 0 }
        try {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            $A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]
            $findWin = { $A::RootElement.FindAll($TS::Children, [Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.Name -eq 'OMEN Light Studio' } | Select-Object -First 1 }
            $win = & $findWin; $startedByUs = $false
            if (-not $win) { Start-Process "shell:AppsFolder\$appId"; $startedByUs = $true; for ($i = 0; $i -lt 30 -and -not $win; $i++) { Start-Sleep 2; $win = & $findWin } }
            if (-not $win) { Log 'FAIL: Light Studio window did not appear'; Write-Output 'ERROR: Light Studio window did not appear'; exit 1 }
            Start-Sleep 4
            $find = { param($id) $c = New-Object Windows.Automation.PropertyCondition($A::AutomationIdProperty, $id); $win.FindFirst($TS::Descendants, $c) }
            $cb = & $find 'CloseButton'; if ($cb -and -not $cb.Current.IsOffscreen) { try { ($cb.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke(); Start-Sleep 1 } catch { } }
            $sl = & $find 'speedSlider'
            if (-not $sl) { Log 'FAIL: brightness slider not found'; Write-Output 'ERROR: brightness slider not found'; exit 1 }
            $rv = $sl.GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern)
            $rv.SetValue([double]$Brightness); Start-Sleep 1
            $now = [int]$rv.Current.Value
            if ($now -ne $Brightness) { Log "FAIL: wanted $Brightness got $now"; Write-Output "ERROR: slider reads $now, wanted $Brightness"; exit 1 }
            Log "OK: brightness $Brightness"; Write-Output "rgb: brightness set to $Brightness"
            if (-not $KeepOpen) { try { ($win.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern)).Close() } catch { } }
            exit 0
        } catch { Log "FAIL: $($_.Exception.Message)"; Write-Output "ERROR: $($_.Exception.Message)"; exit 1 }
    }
    'install-schedule' {
        if ((BadTime $OffAt) -or (BadTime $OnAt)) { Write-Output 'ERROR: times must be HH:mm (24h)'; exit 2 }
        if ($OffAt -eq $OnAt) { Write-Output 'ERROR: off and on times must differ'; exit 2 }
        # the update-proof pwsh (not this process's versioned Store path, which the next PowerShell update deletes: Rig-RGB-* then failed 0x80070002)
        . (Join-Path $PSScriptRoot 'headless-task-lib.ps1')
        $pwsh = & (Join-Path $PSScriptRoot 'stable-pwsh.ps1') 2>$null; if ($LASTEXITCODE -ne 0 -or -not $pwsh) { Write-Output 'ERROR: no update-proof pwsh.exe found'; exit 1 }
        if ($DryRun) { Write-Output "DRY RUN: would register $TaskPrefix-Off at $OffAt (brightness 0) and $TaskPrefix-On at $OnAt (brightness $OnBrightness), running $pwsh"; exit 0 }
        $plan = @()
        foreach ($t in @(@('Off', $OffAt, 0), @('On', $OnAt, $OnBrightness))) {
            $name = "$TaskPrefix-$($t[0])"
            $arg = '-NoProfile -WindowStyle Hidden -File "{0}" -Action set -Brightness {1}' -f $PSCommandPath, $t[2]
            $h = Get-HeadlessAction $pwsh $arg   # hidden, exit code kept: no console flash at the off and on times (scripts/headless-task-lib.ps1)
            $taskAction = New-ScheduledTaskAction -Execute $h.Execute -Argument $h.Args
            $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($t[1], 'HH:mm', $null))
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries
            if ($PlanOnly) { $plan += [pscustomobject]@{ name = $name; execute = $taskAction.Execute; arguments = $taskAction.Arguments; at = ([datetime]$trigger.StartBoundary).ToString('HH:mm'); logonType = [string]$principal.LogonType; runLevel = [string]$principal.RunLevel; timeLimit = $settings.ExecutionTimeLimit; multipleInstances = [string]$settings.MultipleInstances }; continue }
            Register-ScheduledTask -TaskName $name -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            Log "registered $name at $($t[1]) brightness $($t[2])"
        }
        if ($PlanOnly) { $plan | ConvertTo-Json -Depth 3; exit 0 }
        Write-Output "rgb: scheduled $TaskPrefix-Off at $OffAt (0) and $TaskPrefix-On at $OnAt ($OnBrightness)"; exit 0
    }
    'remove-schedule' {
        foreach ($n in 'Off', 'On') { $name = "$TaskPrefix-$n"; if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $name -Confirm:$false; Log "removed $name" } }
        Write-Output "rgb: schedule removed ($TaskPrefix)"; exit 0
    }
    'status' {
        $found = 0
        foreach ($n in 'Off', 'On') {
            $name = "$TaskPrefix-$n"; $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($t) { $found++; $i = Get-ScheduledTaskInfo -TaskName $name; Write-Output ("{0,-4} {1} next={2} last={3} result={4}" -f $n, $t.State, $i.NextRunTime, $i.LastRunTime, $i.LastTaskResult) }
            else { Write-Output "$n  not scheduled" }
        }
        if (Test-Path $logFile) { Write-Output ("last log: " + (Get-Content $logFile -Tail 1)) }
        exit 0
    }
}
