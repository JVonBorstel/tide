# Cook a recipe: turn kitchen/recipes/<name>.json plus your values into a kitchen job.
#   cook.ps1 -Recipe improve -Vars @{ goal = 'add a doctor check for stale worktrees' } [-Gate]
#   cook.ps1 -List
# Every recipe also takes reserved vars: cook (auto or a supplier), private (yes = stays on this PC), size (S, M or L; L = strong tier)
# and night (yes = night shift: the order starts at the next 22:00 local time, or right away when ordered between 22:00 and 06:00;
# a gated order asks for its yes then), and priority (urgent, normal or low: which queued order starts first, kitchen/start-order.ps1). KITCHEN_COOK_NOW (local time) stands in for the clock in tests.
# A recipe is {name, description, vars: {v: {required|default|max}}, steps: [step, ...]}. A step names a station (or script) plus
# args and limits, exactly as kitchen.ps1 add -SpecPath takes them. {{var}} in any string is filled in here; {{job}} and
# {{worktree}} are left for the stations to fill at run time. -Gate makes the first step wait for Jordan (used for bot orders).
param([string]$Recipe = '', [hashtable]$Vars = @{}, [switch]$Gate, [switch]$List, [switch]$Json, [switch]$Force)   # Force: add it even when an open order asks the same (task 32)
$ErrorActionPreference = 'Stop'
$dir = if ($env:KITCHEN_RECIPES) { $env:KITCHEN_RECIPES } else { Join-Path $PSScriptRoot 'recipes' }   # override for tests
function Fail([string]$m) { if ($Json) { @{ ok = $false; error = $m } | ConvertTo-Json -Compress } else { Write-Output "ERROR: $m" }; exit 2 }
if ($List) {
    $all = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | ForEach-Object {
        $r = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable
        [ordered]@{ name = $_.BaseName; description = $r.description; vars = @($r.vars.Keys); steps = @($r.steps).Count } })
    if ($Json) { @{ ok = $true; recipes = $all } | ConvertTo-Json -Depth 5 -Compress } else { $all | ForEach-Object { "{0,-12} {1} (vars: {2})" -f $_.name, $_.description, ($_.vars -join ', ') } }
    exit 0
}
if ($Recipe -notmatch '^[\w-]{1,40}$') { Fail 'recipe name must be letters, digits, - or _' }
$path = Join-Path $dir "$Recipe.json"
if (-not (Test-Path -LiteralPath $path)) { Fail "no recipe named '$Recipe' (cook.ps1 -List)" }
try { $r = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable } catch { Fail "recipe $Recipe is not valid JSON" }

# {{home}}: the profile folder (from the account, so a rewritten USERPROFILE cannot move it); recipes use it for paths and defaults
$homeDir = [Environment]::GetFolderPath('UserProfile')
# kitchen.json "recipeDefaults" {"<recipe>": {"<var>": "value"}} replaces a variable's default (the state-folder copy wins), so
# personal values such as the job scout's location and skills live outside the repo; pass-app/server.mjs reads the same
$over = @{}
$kroot0 = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
foreach ($kp in (Join-Path $PSScriptRoot 'kitchen.json'), (Join-Path $kroot0 'kitchen.json')) {
    try { $kc = [IO.File]::ReadAllText($kp) | ConvertFrom-Json -AsHashtable } catch { continue }
    if ($kc.recipeDefaults -is [Collections.IDictionary] -and $kc.recipeDefaults[$Recipe] -is [Collections.IDictionary]) { foreach ($k in $kc.recipeDefaults[$Recipe].Keys) { $over[$k] = [string]$kc.recipeDefaults[$Recipe][$k] } }
}
$values = @{}
foreach ($v in @($r.vars.Keys)) {
    $def = $r.vars[$v]; $given = $Vars[$v]
    $dflt = if ($over.ContainsKey($v)) { $over[$v] } elseif ($null -ne $def.default) { ([string]$def.default).Replace('{{home}}', $homeDir) } else { $null }
    $val = if ($null -ne $given -and "$given" -ne '') { [string]$given } else { $dflt }
    if ($def.required -and -not $val) { Fail "recipe $Recipe needs '$v'" }
    if ($val -and $val.Contains('{{')) { Fail "'$v' may not contain {{ }}" }
    $max = if ($def.max) { [int]$def.max } else { 2000 }
    if ($val -and $val.Length -gt $max) { Fail "'$v' is longer than $max characters" }
    $values[$v] = $val
}
# {{resume}} and {{claims}}: Jordan's one resume source and claims file (kitchen.json "career"), full paths; never taken from an order
. (Join-Path $PSScriptRoot 'tracker-lib.ps1')
$cf = Get-CareerFiles; $values.resume = $cf.resume; $values.claims = $cf.claims; $values.home = $homeDir
# two order options every recipe takes: cook = which supplier its AI steps use (auto lets the sous chef pick), private = keep it on this PC
$reserved = @{ cook = 'auto'; private = 'no'; size = ''; night = 'no'; priority = 'normal'; site = '' }   # size L = a large order: the sous chef may use the strong tier for its plan and build (tide/08)
foreach ($v in $Vars.Keys) { if (-not $r.vars.ContainsKey($v) -and -not $reserved.ContainsKey($v)) { Fail "recipe $Recipe has no '$v'" } }
# site: the order's Site for an order with no Tower (TD-3; kitchen.ps1 add sets it from the Tower otherwise, and a requeue passes it back)
if ($Vars.site) { . (Join-Path $PSScriptRoot 'repo-config.ps1'); if ([string]$Vars.site -cnotin $script:RepoSiteCodes) { Fail "site must be one of $($script:RepoSiteCodes -join ', ')" } }
if ($Vars.cook) { $reserved.cook = [string]$Vars.cook; if ($reserved.cook -notmatch '^[\w-]{1,30}$') { Fail "cook must be auto or a supplier name" } }
if ($Vars.private) { $reserved.private = [string]$Vars.private; if ($reserved.private -notmatch '^(yes|no|true|false)$') { Fail 'private must be yes or no' } }
if ($Vars.night) { $reserved.night = ([string]$Vars.night).ToLowerInvariant(); if ($reserved.night -notmatch '^(yes|no|true|false)$') { Fail 'night must be yes or no' } }
# night shift (tide performance plan, step 11): the supervisor's tick skips a pending job until its notBefore (kitchen.ps1), so a night
# order gets notBefore = the next 22:00 local time; between 22:00 and 06:00 it is already night and the order may start now
$notBefore = $null
if ($reserved.night -in 'yes', 'true') {
    $nowLocal = if ($env:KITCHEN_COOK_NOW) { try { [DateTime]::Parse($env:KITCHEN_COOK_NOW, [Globalization.CultureInfo]::InvariantCulture) } catch { Fail "KITCHEN_COOK_NOW is not a time: $($env:KITCHEN_COOK_NOW)" } } else { Get-Date }
    $nowLocal = [DateTime]::SpecifyKind($nowLocal, [DateTimeKind]::Local)
    $nbLocal = if ($nowLocal.Hour -ge 22 -or $nowLocal.Hour -lt 6) { $nowLocal } else { $nowLocal.Date.AddHours(22) }
    $notBefore = $nbLocal.ToUniversalTime().ToString('o')
}
if ($Vars.priority) { $reserved.priority = ([string]$Vars.priority).ToLowerInvariant(); if ($reserved.priority -notmatch '^(urgent|normal|low)$') { Fail 'priority must be urgent, normal or low' } }   # read by kitchen/start-order.ps1
if ($Vars.size) { $reserved.size = ([string]$Vars.size).ToUpperInvariant(); if ($reserved.size -notmatch '^(S|M|L)$') { Fail 'size must be S, M or L' } }

function Fill($x) {
    if ($x -is [string]) { $s = $x; foreach ($k in $values.Keys) { $s = $s.Replace("{{$k}}", [string]$values[$k]) }; return $s }
    if ($x -is [hashtable]) { $h = @{}; foreach ($k in $x.Keys) { $h[$k] = Fill $x[$k] }; return $h }
    if ($x -is [array] -or $x -is [Collections.IList]) { return , @($x | ForEach-Object { Fill $_ }) }
    return $x
}
$steps = @(@($r.steps) | ForEach-Object { Fill $_ })
# what was actually asked (the required values) travels with every AI step, so the sous chef's privacy judge reads the order, not the recipe
$asked = (@($r.vars.Keys | Where-Object { $r.vars[$_].required -and $values[$_] } | ForEach-Object { $values[$_] }) -join "`n")
# a recipe that always works on code says so ("about"), so a goal like "security and safety" is read as code, not as Jordan's life;
# the privacy patterns (emails, money, health, private words...) still read every word
if ($asked -and $r.about) { $asked = "About: $($r.about).`nOrder: $asked" }
foreach ($s in $steps) {
    if ($s.station -ne 'agent' -and -not $s.ai) { continue }   # ai: a station that calls a cook itself (repair) gets the same order, cook and privacy
    if (-not $s.args) { $s.args = @{} }
    if ($asked -and -not $s.args.Order) { $s.args.Order = $asked }
    if ($reserved.cook -ne 'auto' -and -not $s.args.Supplier) { $s.args.Supplier = $reserved.cook }
    if ($reserved.private -in 'yes', 'true') { $s.args.Private = $true } elseif ($r.public -eq $true) { $s.args.Public = $true }
    if ($reserved.size -and $s.station -eq 'agent' -and -not $s.args.Size) { $s.args.Size = $reserved.size }   # only the agent station takes -Size; freshen/repair (ai stations) do not (J192-J194 failed on it, 2026-10-22)
}
if (-not $steps.Count) { Fail "recipe $Recipe has no steps" }
if ($Gate) { $steps[0].approve = $true }
$first = (@(@($r.vars.Keys | Where-Object { $r.vars[$_].required }) + @($r.vars.Keys)) | ForEach-Object { $values[$_] } | Where-Object { $_ } | Select-Object -First 1)   # what was asked, not a default path
$label = "$Recipe" + $(if ($first) { ': ' + (($first -replace '[|\r\n]+', ' ').Trim() | ForEach-Object { if ($_.Length -gt 48) { $_.Substring(0, 48) + '...' } else { $_ } }) } else { '' })
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$specDir = Join-Path $kroot 'specs'; New-Item -ItemType Directory -Force -Path $specDir | Out-Null
$spec = Join-Path $specDir ("{0:yyyyMMdd-HHmmss}-{1}-{2}.json" -f (Get-Date), $Recipe, (Get-Random -Maximum 99999))
@{ name = $label; steps = $steps; recipe = $Recipe; vars = $Vars } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $spec -Encoding utf8
$out = & (Join-Path $PSScriptRoot 'kitchen.ps1') add -SpecPath $spec -Force:$Force | Out-String
$m = [regex]::Match($out, 'added (J\d+)')
# task 32, duplicates at the door: the open order with the same goal comes back as duplicate (its id); -Force adds it anyway
$dm = [regex]::Match($out, 'DUPLICATE: (J\d+)(?: is open with the same goal \(([\w-]+)\))?')
if (-not $m.Success -and $dm.Success) {
    Remove-Item -LiteralPath $spec -Force -ErrorAction SilentlyContinue
    if ($Json) { @{ ok = $false; duplicate = $dm.Groups[1].Value; status = $dm.Groups[2].Value; error = $out.Trim() -replace '^DUPLICATE: ', '' } | ConvertTo-Json -Compress } else { Write-Output $out.Trim() }
    exit 2
}
if (-not $m.Success) { Fail ($out.Trim()) }
$jobId = $m.Groups[1].Value
$jobFile = Join-Path $kroot "jobs\$jobId.json"
$nightNote = ''
if (Test-Path -LiteralPath $jobFile) {
    try {
        $jData = Get-Content -LiteralPath $jobFile -Raw | ConvertFrom-Json -AsHashtable
        if (-not $jData.recipe) { $jData.recipe = $Recipe }
        if (-not $jData.vars) { $jData.vars = $Vars }
        # a tick may have started the job in the moment since add: never rewrite a started job's wait, say so instead
        if ($notBefore) { if ($jData.status -eq 'pending' -and -not $jData.run -and [int]$jData.cursor -eq 0) { $jData.notBefore = $notBefore } else { $nightNote = "night: $jobId started before its night wait was set (status $($jData.status))"; $notBefore = $null } }
        $jData | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jobFile -Encoding utf8
    } catch { if ($notBefore) { $nightNote = "night: could not set $jobId's night wait ($($_.Exception.Message)); it may start now"; $notBefore = $null } }
} elseif ($notBefore) { $nightNote = "night: job file for $jobId not found; it may start now"; $notBefore = $null }
if ($Json) { $o = @{ ok = $true; job = $jobId; recipe = $Recipe; vars = $Vars; steps = $steps.Count; gated = [bool]$Gate }; if ($reserved.night -in 'yes', 'true') { $o.notBefore = $notBefore; if ($nightNote) { $o.warning = $nightNote } }; $o | ConvertTo-Json -Compress }
else { Write-Output "cooking $jobId from recipe $Recipe ($($steps.Count) steps)$(if ($notBefore) { "; night shift: starts after $(([DateTime]::Parse($notBefore, [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().ToString('yyyy-MM-dd HH:mm')) local" })"; if ($nightNote) { Write-Output $nightNote } }
exit 0
