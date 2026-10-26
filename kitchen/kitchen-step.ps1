# Worker wrapper started by kitchen.ps1 for one step. Runs the step script in this process, sends all its output to the step log,
# and writes the exit code to the .exit file. No .exit file after the process is gone means the worker crashed.
param([Parameter(Mandatory)][string]$Spec)
$s = Get-Content -LiteralPath $Spec -Raw | ConvertFrom-Json -AsHashtable
$a = if ($s.args) { $s.args } else { @{} }
$code = 1
try {
    $global:LASTEXITCODE = 0
    & $s.script @a *>> $s.log
    $code = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
} catch {
    "kitchen-step: $_" | Add-Content -LiteralPath $s.log
    $code = 1
}
# a hold (exit 10) keeps its whole reason in <run>.hold, before the .exit file the supervisor waits for (TD-EH-06): the step's own file
# when it wrote one, else its last non-empty output line in full. The supervisor used to cut that line at 200 characters, mid-word.
if ($code -eq 10) {
    $hold = $s.exit -replace '\.exit$', '.hold'
    if (-not (Test-Path -LiteralPath $hold)) {
        try {
            $last = @(Get-Content -LiteralPath $s.log -Tail 5 -ErrorAction Stop | Where-Object { $_.Trim() }) | Select-Object -Last 1
            if ($last) { Set-Content -LiteralPath $hold -Value ([string]$last).Trim() -Encoding utf8 }
        } catch { }
    }
}
Set-Content -LiteralPath $s.exit -Value $code
# wake the supervisor: a tick that is running (or waiting out its minute) sees run\WAKE and takes its next pass now, so the next step
# starts within seconds instead of at the next minute (TARGET W2, J252). Best effort: a missed wake costs only the old minute.
try { [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $s.exit) 'WAKE'), [DateTime]::UtcNow.ToString('o')) } catch { }
exit $code
