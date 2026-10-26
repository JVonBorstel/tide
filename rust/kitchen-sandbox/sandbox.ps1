# Dot-source from a station: how suites are launched (kitchen.json "sandbox"), and one call that runs a suite that way.
# Modes: "low" = kitchen-sandbox.exe at Low integrity (job object + private TEMP/HOME/APPDATA + no writes to Jordan's Medium files);
# "medium" = the same without the Low label (job object and private folders only); "off" = the old run-bounded.ps1 path;
# "auto" (the default) = "low" when the exe is built, "off" when it is not. "low" or "medium" with no exe HOLDS (exit 10): a config
# that asks for the sandbox never silently runs AI-written tests uncontained. The state-folder kitchen.json wins over the repo copy.
# What Low integrity does NOT stop (see src/main.rs): reading Medium files (pass-key.txt, the career folder) and network access.
function Get-KitchenSandbox([string]$KitchenDir, [string]$StateDir) {
    $mode = 'auto'; $med = @{}
    foreach ($cp in (Join-Path $KitchenDir 'kitchen.json'), (Join-Path $StateDir 'kitchen.json')) {
        # an unreadable config is doubt: ask for the sandbox (fail closed), never fall back to off
        if (Test-Path -LiteralPath $cp) { try { $j = Get-Content -LiteralPath $cp -Raw | ConvertFrom-Json; if ($j.sandbox) { $mode = "$($j.sandbox)".ToLower() }; if ($j.sandboxMedium) { $med = @{}; foreach ($q in $j.sandboxMedium.PSObject.Properties) { $med[$q.Name] = @($q.Value) } } } catch { $mode = 'low'; $med = @{} } }
    }
    if ($mode -notin 'auto', 'low', 'medium', 'off') { $mode = 'low' }
    $exe = Join-Path $KitchenDir '..\rust\kitchen-sandbox\target\release\kitchen-sandbox.exe'
    $have = Test-Path -LiteralPath $exe -PathType Leaf
    if ($mode -eq 'auto') { $mode = if ($have) { 'low' } else { 'off' } }
    $hold = if ($mode -ne 'off' -and -not $have) { "kitchen.json asks for sandbox '$mode' but $exe is not built (run rust/kitchen-sandbox/build.ps1); held, nothing run unsandboxed" } else { '' }
    [pscustomobject]@{ mode = $mode; medium = $med; exe = $(if ($have) { (Resolve-Path -LiteralPath $exe).Path } else { $exe }); hold = $hold }
}
# Runs one suite and returns its output; $LASTEXITCODE is the suite's code (124 timeout, 125 memory). $Kitchen is the suite's private
# BRAIN_KITCHEN folder (under TEMP): it is labelled Low so the suite can write there, and a sibling "<Kitchen>.sbx" holds its TEMP/HOME.
# $Changed: the files this job changed. A suite on the kitchen.json "sandboxMedium" list (it needs what Low denies by design, e.g. Test-Rgb
# registers real scheduled tasks) runs at Medium, still in the job with private folders, but only while none of its listed files is
# among them: a job that edits such a suite or the script it drives gets Low like any other (it fails there, and a person looks).
# An entry ending in "/" lists a whole folder. The suite name is global to the kitchen, not per repo (see "Test-Phase0" in kitchen.json),
# so a suite file the job itself added or changed always runs Low, whatever its name.
function Invoke-KitchenSuite($Sb, [string]$Script, [string]$Dir, [string]$Kitchen, [int]$TimeoutSec, [int]$MaxMB, [string]$Bounded, [string[]]$Changed = @()) {
    if ($Sb.mode -eq 'off') { return (& pwsh -NoProfile -File $Bounded -Script $Script -TimeoutSeconds $TimeoutSec -MaxMB $MaxMB 2>&1 | Out-String) }
    $c = Get-KitchenSuiteCommand $Sb $Script $Dir $Kitchen $TimeoutSec $MaxMB $Changed
    try { & $c.exe @($c.args) 2>&1 | Out-String }
    finally { $code = $LASTEXITCODE; Remove-Item -LiteralPath $c.scratch -Recurse -Force -ErrorAction SilentlyContinue; $global:LASTEXITCODE = $code }
}
# The sandboxed command for one suite, {exe, args, scratch}, without running it: Invoke-KitchenSuite runs it in place, and the tests
# station hands it to run-bounded (-CommandFile) to run several suites at once and record each one's time and memory. The caller
# removes the scratch folder afterwards. Only for a sandbox mode ($Sb.mode 'low' or 'medium'); 'off' runs the suite through run-bounded.
function Get-KitchenSuiteCommand($Sb, [string]$Script, [string]$Dir, [string]$Kitchen, [int]$TimeoutSec, [int]$MaxMB, [string[]]$Changed = @()) {
    $scratch = "$Kitchen.sbx"
    # the job cap counts the whole tree's committed memory, run-bounded only the top process's working set: twice the old number
    $a = @('--timeout', $TimeoutSec, '--mem', [math]::Max(1024, $MaxMB * 2), '--procs', 200, '--scratch', $scratch, '--label-low', $Kitchen, '--cwd', $Dir, '--path-first', $PSHOME)
    $name = [IO.Path]::GetFileNameWithoutExtension($Script); $ch = @($Changed | ForEach-Object { "$_".Replace('\', '/').ToLower() })
    # a listed entry is a file, or a whole folder when it ends in "/" (a suite that drives another repo's hooks and scripts)
    $touched = $false
    foreach ($e in @($(if ($Sb.medium.ContainsKey($name)) { $Sb.medium[$name] }) | ForEach-Object { "$_".Replace('\', '/').ToLower() })) {
        if ($e.EndsWith('/')) { if (@($ch | Where-Object { $_.StartsWith($e) }).Count) { $touched = $true } } elseif ($e -in $ch) { $touched = $true }
    }
    # the suite file itself new or edited by this job: always Low. The list is keyed by bare name, so without this a cook could add a
    # same-named suite (tests/Test-Phase0.ps1 in another repo) and have its own code run at Medium
    $rel = try { [IO.Path]::GetRelativePath($Dir, $Script).Replace('\', '/').ToLower() } catch { '' }
    if ($rel -and $rel -in $ch) { $touched = $true }
    $medOk = $Sb.medium.ContainsKey($name) -and -not $touched
    if ($Sb.mode -eq 'medium' -or $medOk) { $a += '--medium' }
    [pscustomobject]@{ exe = $Sb.exe; args = @($a + @('--', (Join-Path $PSHOME 'pwsh.exe'), '-NoProfile', '-File', $Script) | ForEach-Object { "$_" }); scratch = $scratch }
}
