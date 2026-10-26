# Scheduled tasks that run pwsh without ever flashing a console window, and keep pwsh's exit code (dot-source this file).
# pwsh -WindowStyle Hidden in an interactive task still opens a console for a moment before it hides it: Jordan saw a flash every
# minute from Tide-Yard. On 2026-10-26 the Foreman first changed the live Tide-Yard and Tide-Cleanup to conhost.exe --headless; that
# hides the console but exits 0 whatever pwsh returns (measured), so a task's Last Run Result (kitchen/watch.ps1) went blind.
# This form keeps both: wscript.exe //B //NoLogo "<scripts>\run-hidden.vbs" "<pwsh>" <args>. wscript has no console, run-hidden.vbs
# starts pwsh hidden, waits, and returns pwsh's exit code (or the start error, e.g. 0x80070002 for a missing pwsh, never 0).
#   Get-HeadlessAction -Program <exe> -Arguments <args>   -> { Execute = ...\System32\wscript.exe; Args = //B //NoLogo "<vbs>" "<exe>" <args> }
#   Get-TaskProgram -Execute <exe> -Arguments <args>      -> the program a task really runs: the one run-hidden.vbs (or the older
#                                                            conhost --headless) starts, else Execute
$HeadlessLauncher = Join-Path $PSScriptRoot 'run-hidden.vbs'
function Get-HeadlessAction([string]$Program, [string]$Arguments, [string]$Launcher = $HeadlessLauncher) {
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    [pscustomobject]@{ Execute = $wscript; Args = ("//B //NoLogo `"$Launcher`" `"$Program`" $Arguments").TrimEnd() }
}
function Get-TaskProgram([string]$Execute, [string]$Arguments) {
    $exe = [Environment]::ExpandEnvironmentVariables($Execute.Trim().Trim('"'))
    $lead = switch (Split-Path $exe -Leaf) {
        'conhost.exe' { '^\s*--headless\s+' }                                                    # the 2026-10-26 hand-set form
        'wscript.exe' { '^\s*(?://\S+\s+)*(?:"[^"]*run-hidden\.vbs"|\S*run-hidden\.vbs)\s+' }   # this file's form (not the Board's start-hidden.vbs)
        default { return $exe }
    }
    if ([string]$Arguments -match ($lead + '(?:"([^"]+)"|(\S+))')) { return [Environment]::ExpandEnvironmentVariables($(if ($Matches[1]) { $Matches[1] } else { $Matches[2] })) }
    $exe
}
