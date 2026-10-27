# Dot-source from a station: how suites are launched (kitchen.json "sandbox"), and one call that runs a suite that way.
# Modes: "low" = kitchen-sandbox.exe at Low integrity (job object + private TEMP/HOME/APPDATA + no writes to Jordan's Medium files);
# "medium" = the same without the Low label (job object and private folders only); "off" = the old run-bounded.ps1 path;
# "auto" (the default) = "low" when the exe is built, "off" when it is not. "low" or "medium" with no exe HOLDS (exit 10): a config
# that asks for the sandbox never silently runs AI-written tests uncontained. The state-folder kitchen.json wins over the repo copy.
# What Low integrity does NOT stop (see src/main.rs): reading Medium files (pass-key.txt, the career folder) and network access.
# sandboxMedium keyed by Tower (TD-10): an entry whose value is a list is global, as before ("Test-Rgb": [files]); an entry whose value is
# an object is a Tower block, named by the Tower's main checkout folder (any case): "demo-project": { "Test-Phase0": [files] }. A
# suite listed in its Tower's block uses that list (it wins over a global entry of the same name); a Tower block never reaches another
# Tower. A block entry that is not a list of file names is dropped (that suite runs Low). No Tower blocks = exactly the old behaviour.
function Get-KitchenSandbox([string]$KitchenDir, [string]$StateDir) {
    $mode = 'auto'; $med = @{}; $towers = @{}
    foreach ($cp in (Join-Path $KitchenDir 'kitchen.json'), (Join-Path $StateDir 'kitchen.json')) {
        # an unreadable config is doubt: ask for the sandbox (fail closed), never fall back to off
        if (Test-Path -LiteralPath $cp) {
            try {
                $j = Get-Content -LiteralPath $cp -Raw | ConvertFrom-Json; if ($j.sandbox) { $mode = "$($j.sandbox)".ToLower() }
                if ($j.sandboxMedium) {
                    $med = @{}; $towers = @{}
                    foreach ($q in $j.sandboxMedium.PSObject.Properties) {
                        if ($q.Value -isnot [pscustomobject]) { $med[$q.Name] = @($q.Value); continue }
                        $tb = @{}; foreach ($s in $q.Value.PSObject.Properties) { $v = @($s.Value); if ($v.Count -and -not @($v | Where-Object { $_ -isnot [string] }).Count) { $tb[$s.Name] = $v } }
                        $towers[$q.Name.ToLowerInvariant()] = $tb
                    }
                }
            } catch { $mode = 'low'; $med = @{}; $towers = @{} }
        }
    }
    if ($mode -notin 'auto', 'low', 'medium', 'off') { $mode = 'low' }
    $exe = Join-Path $KitchenDir '..\rust\kitchen-sandbox\target\release\kitchen-sandbox.exe'
    $have = Test-Path -LiteralPath $exe -PathType Leaf
    if ($mode -eq 'auto') { $mode = if ($have) { 'low' } else { 'off' } }
    $hold = if ($mode -ne 'off' -and -not $have) { "kitchen.json asks for sandbox '$mode' but $exe is not built (run rust/kitchen-sandbox/build.ps1); held, nothing run unsandboxed" } else { '' }
    [pscustomobject]@{ mode = $mode; medium = $med; towers = $towers; exe =$(if ($have) { (Resolve-Path -LiteralPath $exe).Path } else { $exe }); hold = $hold }
}
# Runs one suite and returns its output; $LASTEXITCODE is the suite's code (124 timeout, 125 memory). $Kitchen is the suite's private
# BRAIN_KITCHEN folder (under TEMP): it is labelled Low so the suite can write there, and a sibling "<Kitchen>.sbx" holds its TEMP/HOME.
# $Changed: the files this job changed. A suite on the kitchen.json "sandboxMedium" list (it needs what Low denies by design, e.g. Test-Rgb
# registers real scheduled tasks) runs at Medium, still in the job with private folders, but only while none of its listed files is
# among them: a job that edits such a suite or the script it drives gets Low like any other (it fails there, and a person looks).
# An entry ending in "/" lists a whole folder. A global entry's suite name holds in every Tower; a Tower block's only in its Tower (TD-10),
# and either way a suite file the job itself added or changed always runs Low, whatever its name.
# $Tower: the suite's Tower (main checkout folder name or path); empty = worked out from $Dir's git common dir, only when a Tower block exists.
function Invoke-KitchenSuite($Sb, [string]$Script, [string]$Dir, [string]$Kitchen, [int]$TimeoutSec, [int]$MaxMB, [string]$Bounded, [string[]]$Changed = @(), [string]$Tower = '') {
    if ($Sb.mode -eq 'off') { return (& pwsh -NoProfile -File $Bounded -Script $Script -TimeoutSeconds $TimeoutSec -MaxMB $MaxMB 2>&1 | Out-String) }
    $c = Get-KitchenSuiteCommand $Sb $Script $Dir $Kitchen $TimeoutSec $MaxMB $Changed $Tower
    try { & $c.exe @($c.args) 2>&1 | Out-String }
    finally { $code = $LASTEXITCODE; Remove-Item -LiteralPath $c.scratch -Recurse -Force -ErrorAction SilentlyContinue; $global:LASTEXITCODE = $code }
}
# Which sandboxMedium list a suite gets: {hit, files}. Its Tower's block first, then the global entry; hit = $false = not listed (Low).
function Get-KitchenMediumList($Sb, [string]$Name, [string]$Dir, [string]$Tower) {
    if ($Sb.towers -and $Sb.towers.Count) {
        $t = "$Tower".Trim().TrimEnd('\', '/')
        if (-not $t) { $common = try { & git -C $Dir rev-parse --path-format=absolute --git-common-dir 2>$null } catch { $null }; if ($LASTEXITCODE -eq 0 -and "$common".Trim()) { $t = Split-Path "$common".Trim() -Parent } }
        $t = if ($t) { (Split-Path $t -Leaf).ToLowerInvariant() } else { '' }
        if ($t -and $Sb.towers.ContainsKey($t) -and $Sb.towers[$t].ContainsKey($Name)) { return @{ hit = $true; files = @($Sb.towers[$t][$Name]) } }
    }
    if ($Sb.medium.ContainsKey($Name)) { return @{ hit = $true; files = @($Sb.medium[$Name]) } }
    @{ hit = $false; files = @() }
}
# The sandboxed command for one suite, {exe, args, scratch}, without running it: Invoke-KitchenSuite runs it in place, and the tests
# station hands it to run-bounded (-CommandFile) to run several suites at once and record each one's time and memory. The caller
# removes the scratch folder afterwards. Only for a sandbox mode ($Sb.mode 'low' or 'medium'); 'off' runs the suite through run-bounded.
function Get-KitchenSuiteCommand($Sb, [string]$Script, [string]$Dir, [string]$Kitchen, [int]$TimeoutSec, [int]$MaxMB, [string[]]$Changed = @(), [string]$Tower = '') {
    $scratch = "$Kitchen.sbx"
    # the job cap counts the whole tree's committed memory, run-bounded only the top process's working set: twice the old number
    $a = @('--timeout', $TimeoutSec, '--mem', [math]::Max(1024, $MaxMB * 2), '--procs', 200, '--scratch', $scratch, '--label-low', $Kitchen, '--cwd', $Dir, '--path-first', $PSHOME)
    $name = [IO.Path]::GetFileNameWithoutExtension($Script); $ch = @($Changed | ForEach-Object { "$_".Replace('\', '/').ToLower() })
    $m = Get-KitchenMediumList $Sb $name $Dir $Tower
    # a listed entry is a file, or a whole folder when it ends in "/" (a suite that drives another repo's hooks and scripts)
    $touched = $false
    foreach ($e in @($m.files | ForEach-Object { "$_".Replace('\', '/').ToLower() })) {
        if ($e.EndsWith('/')) { if (@($ch | Where-Object { $_.StartsWith($e) }).Count) { $touched = $true } } elseif ($e -in $ch) { $touched = $true }
    }
    # the suite file itself new or edited by this job: always Low. The list is keyed by bare name, so without this a cook could add a
    # same-named suite (tests/Test-Phase0.ps1 in another repo) and have its own code run at Medium
    $rel = try { [IO.Path]::GetRelativePath($Dir, $Script).Replace('\', '/').ToLower() } catch { '' }
    if ($rel -and $rel -in $ch) { $touched = $true }
    $medOk = $m.hit -and -not $touched
    if ($Sb.mode -eq 'medium' -or $medOk) { $a += '--medium' }
    [pscustomobject]@{ exe = $Sb.exe; args = @($a + @('--', (Join-Path $PSHOME 'pwsh.exe'), '-NoProfile', '-File', $Script) | ForEach-Object { "$_" }); scratch = $scratch }
}
