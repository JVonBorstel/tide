# MCP server (stdio, JSON-RPC 2.0, one message per line) so any MCP-capable orchestrator can drive the kitchen.
# Every tool call goes through kitchen-api.ps1 on the 'pass' channel: same rules as the inbox, and no approve tool exists here.
# Register (Jordan's yes; it changes a client's config):  claude mcp add kitchen -- pwsh -NoProfile -File <this file>
$ErrorActionPreference = 'Stop'
$api = Join-Path $PSScriptRoot 'kitchen-api.ps1'
$tools = @(
    @{ name = 'kitchen_status'; description = 'List the Yard''s work orders, their status, the recent failure rate and recent alerts.'; inputSchema = @{ type = 'object'; properties = @{} } }
    @{ name = 'kitchen_add'; description = 'Queue a work order with one step (a script). Scripts must live in the Yard''s allowed folders. Work orders from MCP wait for the Owner''s (Jordan''s) sign-off unless the script is pre-approved.'
       inputSchema = @{ type = 'object'; required = @('name', 'script'); properties = @{
            name = @{ type = 'string'; description = 'Short work order name' }; script = @{ type = 'string'; description = 'Step script, relative to the Yard''s kitchen/ folder or absolute' }
            args = @{ type = 'object'; description = 'Named string/number arguments for the script' }; timeoutSec = @{ type = 'integer' }; maxMB = @{ type = 'integer' }
            retries = @{ type = 'integer' }; replay = @{ type = 'string'; enum = @('safe', 'unsafe') } } } }
    @{ name = 'kitchen_kill'; description = 'Stop one work order (id like J3) or all work orders.'; inputSchema = @{ type = 'object'; properties = @{ id = @{ type = 'string' }; all = @{ type = 'boolean' } } } }
    @{ name = 'kitchen_report'; description = 'Write the HTML status page and return its path.'; inputSchema = @{ type = 'object'; properties = @{} } }
    @{ name = 'kitchen_recipes'; description = 'List the specs (ready-made multi-step work orders) the Yard can start. Pass a spec''s name as ''recipe'' to kitchen_cook.'; inputSchema = @{ type = 'object'; properties = @{} } }
    @{ name = 'kitchen_cook'; description = 'Start a work order from a spec, e.g. ''recipe'' improve with vars {goal}. Work orders from MCP wait for the Owner''s (Jordan''s) sign-off before the first step.'; inputSchema = @{ type = 'object'; required = @('recipe'); properties = @{ recipe = @{ type = 'string' }; vars = @{ type = 'object'; description = 'Spec values, e.g. {"goal": "..."}' } } } }
    @{ name = 'kitchen_doctor'; description = 'Run the Yard self-check (damaged files, stuck work orders, backups, disk space).'; inputSchema = @{ type = 'object'; properties = @{} } }
)
function Send($o) { [Console]::Out.WriteLine(($o | ConvertTo-Json -Depth 20 -Compress)); [Console]::Out.Flush() }
function Result($id, $r) { Send ([ordered]@{ jsonrpc = '2.0'; id = $id; result = $r }) }
function RpcError($id, [int]$code, [string]$msg) { Send ([ordered]@{ jsonrpc = '2.0'; id = $id; error = @{ code = $code; message = $msg } }) }

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if (-not $line.Trim()) { continue }
    try { $m = $line | ConvertFrom-Json -AsHashtable } catch { RpcError $null -32700 'parse error'; continue }
    $id = $m.id; $method = [string]$m.method
    switch ($method) {
        'initialize' {
            $ver = if ($m.params.protocolVersion) { [string]$m.params.protocolVersion } else { '2025-06-18' }
            Result $id @{ protocolVersion = $ver; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'kitchen'; version = '1.0.0' }
                          instructions = 'The Yard supervisor for the Owner (Jordan). Queue work orders with kitchen_add or kitchen_cook; check them with kitchen_status. You cannot sign off work orders; the Owner does.' }
        }
        'ping' { Result $id @{} }
        'tools/list' { Result $id @{ tools = $tools } }
        'tools/call' {
            $name = [string]$m.params.name; $args0 = if ($m.params.arguments -is [hashtable]) { $m.params.arguments } else { @{} }
            $op = @{ kitchen_status = 'status'; kitchen_add = 'add'; kitchen_kill = 'kill'; kitchen_report = 'report'; kitchen_doctor = 'doctor'; kitchen_recipes = 'recipes'; kitchen_cook = 'cook' }[$name]
            if (-not $op) { RpcError $id -32602 "unknown tool: $name"; break }
            $req = @{ id = [string]$id; op = $op; args = $args0 } | ConvertTo-Json -Depth 10 -Compress
            $resp = & $api -Channel pass -RequestJson $req | Out-String
            $ok = $false; try { $ok = [bool]($resp | ConvertFrom-Json).ok } catch { }
            Result $id @{ content = @(@{ type = 'text'; text = $resp.Trim() }); isError = (-not $ok) }
        }
        default { if ($null -ne $id) { RpcError $id -32601 "method not found: $method" } }   # notifications (no id) need no reply
    }
}
