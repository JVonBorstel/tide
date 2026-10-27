# Kitchen API: one JSON contract for every front end. Channels: chef = Jordan (the only one who signs off), rail = bots clip ticket files,
# pass = MCP clients call orders in, expo = phone (reserved). Same rules everywhere, so Jordan can drive the kitchen from this chat, another orchestration bot,
# an MCP client or a phone bridge, and they all behave the same.
#   kitchen-api.ps1 -RequestJson '{"op":"status"}' [-Channel chef|rail|pass]   one JSON response on stdout
#   kitchen-api.ps1 -ProcessInbox                                               <root>\rail\*.json -> <root>\window\<same name>
# Request : {"id":"any","op":"status|add|kill|approve|report|doctor|tick","args":{...}}
# Response: {"id":..,"ok":true|false,"op":..,"channel":..,"data":..,"error":..}
# Requests are UNTRUSTED DATA. Only the ops a channel is allowed run (channels.json, else the defaults below), nothing in a request is
# ever executed as code, and a bot channel can never approve: only the chef (Jordan's own channel) signs off. Jobs from bot channels may only
# run scripts inside the allowed roots, and every bot job waits for Jordan's yes unless its script is on the autoApprove list.
param([string]$RequestJson = '', [ValidateSet('chef', 'rail', 'pass')][string]$Channel = 'chef', [switch]$ProcessInbox, [int]$MaxInbox = 20)
$ErrorActionPreference = 'Stop'
$k = Join-Path $PSScriptRoot 'kitchen.ps1'
. (Join-Path $PSScriptRoot 'id-alias.ps1')   # ConvertFrom-TideId: WO-0207 / #0207 -> J207, SO-104 -> A104 (stored IDs never change)
$root = [IO.Path]::GetFullPath($(if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }))
$defaults = @{
    channels    = @{ chef = @('status', 'add', 'cook', 'recipes', 'kill', 'approve', 'requeue', 'report', 'doctor', 'tick'); rail = @('status', 'add', 'cook', 'recipes', 'kill', 'report', 'doctor'); pass = @('status', 'add', 'cook', 'recipes', 'kill', 'report', 'doctor') }
    allowedRoots = @($PSScriptRoot)
    autoApprove = @('demo-worker.ps1')
}
function Load-Config {
    $p = Join-Path $root 'channels.json'
    $c = $defaults
    if (Test-Path -LiteralPath $p) {
        try {
            $u = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -AsHashtable
            if ($u.channels) { foreach ($ch in $u.channels.Keys) { if ($ch -ne 'chef') { $c.channels[$ch] = @($u.channels[$ch] | Where-Object { $_ -ne 'approve' }) } } }   # approve stays cli-only
            if ($u.allowedRoots) { $c.allowedRoots = @($u.allowedRoots) }
            if ($u.autoApprove) { $c.autoApprove = @($u.autoApprove) }
        } catch { }   # a broken config falls back to the safe defaults
    }
    $c
}
function Reply($req, [bool]$ok, $data, [string]$err = '') {
    [ordered]@{ id = $req.id; ok = $ok; op = $req.op; channel = $Channel; data = $data; error = $err } | ConvertTo-Json -Depth 12 -Compress
}
function Run-Kitchen([string]$action, [hashtable]$named = @{}) {
    $global:LASTEXITCODE = 0   # a script that ends without exit keeps the previous code; never let an old failure leak into this answer
    $out = & $k $action @named 2>&1 | Out-String
    @{ code = $LASTEXITCODE; text = $out.Trim() }
}
function Under-Root([string]$path, $roots) {
    try { $full = [IO.Path]::GetFullPath($path) } catch { return $false }
    foreach ($r in $roots) { $rf = [IO.Path]::GetFullPath($r).TrimEnd('\') + '\'; if ($full.StartsWith($rf, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}

function Invoke-Request([string]$json) {
    $req = $null
    try { $req = $json | ConvertFrom-Json -AsHashtable } catch { return Reply @{ id = $null; op = $null } $false $null 'request is not valid JSON' }
    if ($req -isnot [hashtable] -or -not $req.op) { return Reply @{ id = $null; op = $null } $false $null 'request needs an "op"' }
    $req.id = [string]$req.id; $op = [string]$req.op; $a = if ($req.args -is [hashtable]) { $req.args } else { @{} }
    $cfg = Load-Config
    if ($op -notin $cfg.channels[$Channel]) { return Reply $req $false $null "op '$op' is not allowed on channel '$Channel'" }
    switch ($op) {
        'status' { $r = Run-Kitchen 'status' @{ Json = $true }; try { return Reply $req $true ($r.text | ConvertFrom-Json) } catch { return Reply $req $false $null $r.text } }
        'doctor' { $r = Run-Kitchen 'doctor' @{ Json = $true }; try { return Reply $req $true ($r.text | ConvertFrom-Json) } catch { return Reply $req $false $null $r.text } }
        'tick' { $r = Run-Kitchen 'tick' @{ Quiet = $true }; return Reply $req ($r.code -eq 0) $null $r.text }
        'report' {
            $path = Join-Path $root 'status.html'; $r = Run-Kitchen 'report' @{ HtmlPath = $path }
            return Reply $req ($r.code -eq 0) @{ path = $path } $(if ($r.code) { $r.text } else { '' })
        }
        'kill' {
            $id = ConvertFrom-TideId ([string]$a.id) -Kind Job
            if ($a.all -eq $true) { $r = Run-Kitchen 'kill' @{ All = $true } }
            elseif ($id -match '^J\d+$') { $r = Run-Kitchen 'kill' @{ Id = $id } }
            else { return Reply $req $false $null 'kill needs args.id like "WO-0003" (or "J3") or args.all = true' }
            return Reply $req ($r.code -eq 0) $r.text
        }
        'approve' {
            $id = ConvertFrom-TideId ([string]$a.id) -Kind Job
            if ($id -notmatch '^J\d+$') { return Reply $req $false $null 'approve needs args.id like "WO-0003" (or "J3")' }
            # args.approval (optional, like "SO-12" or "A12"): sign off only if that is still the job's ask (Chef always sends the one it showed)
            $named = @{ Id = $id }
            if ($null -ne $a.approval) { $ap = ConvertFrom-TideId ([string]$a.approval) -Kind SignOff; if ($ap -notmatch '^A\d{1,8}$') { return Reply $req $false $null 'approve: args.approval must look like "SO-12" (or "A12")' }; $named.ApprovalId = $ap }
            $r = Run-Kitchen 'approve' $named; return Reply $req ($r.code -eq 0) $r.text $(if ($r.code) { $r.text } else { '' })
        }
        'requeue' {
            $id = ConvertFrom-TideId ([string]$a.id) -Kind Job
            if ($id -notmatch '^J\d+$') { return Reply $req $false $null 'requeue needs args.id like "WO-0003" (or "J3")' }
            $r = Run-Kitchen 'requeue' @{ Id = $id }; return Reply $req ($r.code -eq 0) $r.text $(if ($r.code) { $r.text } else { '' })
        }
        'add' {
            $name = [string]$a.name; $script = [string]$a.script
            if (-not $name -or $name.Length -gt 60 -or $name -notmatch '^[\w .:-]+$') { return Reply $req $false $null 'add needs args.name (letters, digits, space, . : - _; max 60)' }
            if (-not $script) { return Reply $req $false $null 'add needs args.script' }
            if (-not [IO.Path]::IsPathRooted($script)) { $script = Join-Path $PSScriptRoot $script }
            if ($Channel -ne 'chef' -and -not (Under-Root $script $cfg.allowedRoots)) { return Reply $req $false $null "script must be inside the allowed roots for channel '$Channel'" }
            $named = @{ Name = $name; Script = $script }
            if ($a.args -is [hashtable]) {
                foreach ($key in $a.args.Keys) { if ($key -notmatch '^\w{1,40}$' -or ($a.args[$key] -isnot [string] -and $a.args[$key] -isnot [ValueType])) { return Reply $req $false $null "script arg '$key' must be a simple name with a string or number value" } }
                $named.ScriptArgs = $a.args
            }
            foreach ($p in @(@('timeoutSec', 'TimeoutSec', 5, 86400), @('maxMB', 'MaxMB', 50, 16000), @('retries', 'Retries', 0, 10), @('hungSec', 'HungSec', 0, 3600), @('maxLogMB', 'MaxLogMB', 1, 1000))) {
                if ($null -ne $a[$p[0]]) { $v = 0; if (-not [int]::TryParse([string]$a[$p[0]], [ref]$v) -or $v -lt $p[2] -or $v -gt $p[3]) { return Reply $req $false $null "$($p[0]) must be $($p[2])-$($p[3])" }; $named[$p[1]] = $v }
            }
            if ($a.replay -eq 'unsafe') { $named.Replay = 'unsafe' }
            $gate = [bool]$a.approve
            if ($Channel -ne 'chef' -and [IO.Path]::GetFileName($script) -notin $cfg.autoApprove) { $gate = $true }   # bot work waits for Jordan
            if ($gate) { $named.Approve = $true }
            $r = Run-Kitchen 'add' $named
            $m = [regex]::Match($r.text, '^added (J\d+)')
            if ($m.Success) { return Reply $req $true @{ job = $m.Groups[1].Value; needsApproval = $gate } }
            return Reply $req $false $null $r.text
        }
        'recipes' {
            $out = & (Join-Path $PSScriptRoot 'cook.ps1') -List -Json | Out-String
            try { return Reply $req $true (($out | ConvertFrom-Json).recipes) } catch { return Reply $req $false $null $out.Trim() }
        }
        'cook' {
            $name = [string]$a.recipe
            if ($name -notmatch '^[\w-]{1,40}$') { return Reply $req $false $null 'cook needs args.recipe (a recipe name)' }
            $vars = @{}
            if ($a.vars -is [hashtable]) {
                foreach ($key in $a.vars.Keys) {
                    if ($key -notmatch '^\w{1,40}$' -or ($a.vars[$key] -isnot [string] -and $a.vars[$key] -isnot [ValueType])) { return Reply $req $false $null "recipe value '$key' must be a simple name with a string or number" }
                    $vars[$key] = [string]$a.vars[$key]
                }
            }
            # bot orders always wait for Jordan before the first step; the chef's own orders start right away
            $out = & (Join-Path $PSScriptRoot 'cook.ps1') -Recipe $name -Vars $vars -Gate:($Channel -ne 'chef') -Json | Out-String
            try { $c = $out | ConvertFrom-Json; return Reply $req ([bool]$c.ok) $(if ($c.ok) { @{ job = $c.job; recipe = $c.recipe; needsApproval = [bool]$c.gated } } elseif ($c.duplicate) { @{ duplicate = [string]$c.duplicate; status = [string]$c.status } } else { $null }) $(if (-not $c.ok) { $c.error } else { '' }) }   # a refused duplicate names the open order (task 32)
            catch { return Reply $req $false $null $out.Trim() }
        }
        default { return Reply $req $false $null "unknown op '$op'" }
    }
}

if ($ProcessInbox) {
    $in = Join-Path $root 'rail'; $out = Join-Path $root 'window'; $done = Join-Path $root 'spiked'
    New-Item -ItemType Directory -Force -Path $in, $out, $done | Out-Null
    $Channel = 'rail'
    $files = @(Get-ChildItem -LiteralPath $in -Filter '*.json' -File | Sort-Object LastWriteTime | Select-Object -First $MaxInbox)
    foreach ($f in $files) {
        $body = if ($f.Length -gt 64KB) { '' } else { Get-Content -LiteralPath $f.FullName -Raw }
        $resp = if ($body) { Invoke-Request $body } else { Reply @{ id = $null; op = $null } $false $null 'request empty or over 64 KB' }
        Set-Content -LiteralPath (Join-Path $out $f.Name) -Value $resp -Encoding utf8
        Move-Item -LiteralPath $f.FullName -Destination (Join-Path $done ("{0:yyyyMMddHHmmss}-{1}" -f (Get-Date), $f.Name)) -Force
    }
    Write-Output "processed $($files.Count) ticket(s) from the rail"
    exit 0
}
if (-not $RequestJson) { $RequestJson = [Console]::In.ReadToEnd() }
Invoke-Request $RequestJson
