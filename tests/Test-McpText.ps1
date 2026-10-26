# Tests for the words the kitchen MCP server (kitchen/kitchen-mcp.ps1) shows a Claude session (rename slice S1-MCP-TEXT).
# The tool names and serverInfo.name stay the same, because sessions call them; the descriptions and instructions use the
# approved site words (Yard, work order, spec, Owner, sign-off). Starts the server over stdio only; reads no Yard state.
$ErrorActionPreference = 'Stop'
$mcp = (Resolve-Path (Join-Path $PSScriptRoot '..\kitchen\kitchen-mcp.ps1')).Path
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }

$msgs = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}',
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
) -join "`n"
$lines = @($msgs | pwsh -NoProfile -File $mcp | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
Check 'server answers initialize and tools/list' ($lines.Count -eq 2)
$init = $lines[0].result; $tools = @($lines[1].result.tools)

# Names Claude sessions call: unchanged.
Check 'serverInfo.name stays kitchen' ($init.serverInfo.name -ceq 'kitchen')
$want = @('kitchen_status', 'kitchen_add', 'kitchen_kill', 'kitchen_report', 'kitchen_recipes', 'kitchen_cook', 'kitchen_doctor')
Check 'tools/list returns the same 7 names, in order' (($tools.name -join ',') -ceq ($want -join ','))
Check 'no approve tool' (-not (@($tools.name) -match 'approve'))
$add = $tools | Where-Object name -eq 'kitchen_add'; $cook = $tools | Where-Object name -eq 'kitchen_cook'
Check 'kitchen_add input keys unchanged' ((@($add.inputSchema.properties.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'args,maxMB,name,replay,retries,script,timeoutSec')
Check 'kitchen_add required unchanged' ((@($add.inputSchema.required) -join ',') -ceq 'name,script')
Check 'kitchen_cook input keys unchanged' ((@($cook.inputSchema.properties.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'recipe,vars')

# Words a session reads: new.
$ins = [string]$init.instructions
Check 'instructions say Yard' ($ins -cmatch '\bYard\b')
Check 'instructions say work orders' ($ins -match '\bwork orders?\b')
Check 'instructions say sign off' ($ins -match '\bsign off\b')
Check 'instructions name the Owner' ($ins -cmatch '\bOwner\b')
foreach ($t in $tools) { Check "$($t.name) has a description" ([string]$t.description).Trim() }
Check 'descriptions say Yard' ((@($tools.description) -join ' ') -cmatch '\bYard\b')
Check 'recipes tool says spec' ((($tools | Where-Object name -eq 'kitchen_recipes').description) -match '\bspecs?\b')

# Old display words are gone. Kept on purpose: tool names (kitchen_*), the 'recipe' key callers pass, the kitchen/ path.
$texts = @($ins) + @($tools.description) + @($tools | ForEach-Object { $_.inputSchema.properties.PSObject.Properties.Value.description } | Where-Object { $_ })
$old = '\b(kitchen|jobs?|cook|cooks|chef|recipes?|approval|approve)\b'
foreach ($x in $texts) {
    $clean = ([string]$x) -replace '\bkitchen_\w+', '' -replace "'recipe'", '' -replace '\bkitchen/', '' -replace '\bpre-approved\b', ''
    Check "no old words in: $x" (-not ($clean -match $old))
}

Write-Host "McpText tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
