# Station: writes what this kitchen cooks with today (local models, CLI versions, graphics card, the sous chef's menu) to a text file
# the model scout reads. Read-only on the machine. Safe to re-run? Yes.
#   step: {"station":"inventory","args":{"Out":"{{kitchen}}\\scout\\{{job}}-inventory.txt"}}
param([string]$Out = '')
$ErrorActionPreference = 'Continue'
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
if (-not $Out) { $Out = Join-Path $kroot "scout\$env:KITCHEN_JOB-inventory.txt" }
$Out = $Out.Replace('{{kitchen}}', $kroot).Replace('{{job}}', [string]$env:KITCHEN_JOB)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
$url = if ($env:KITCHEN_OLLAMA_URL) { $env:KITCHEN_OLLAMA_URL.TrimEnd('/') } else { 'http://127.0.0.1:11434' }
$lines = @("Kitchen inventory $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '')
try { $g = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null; $lines += "Graphics card: $g" } catch { $lines += 'Graphics card: unknown' }
$lines += ("System memory: {0:N0} GB" -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB))
try { $lines += "Ollama: $((Invoke-RestMethod "$url/api/version" -TimeoutSec 5).version)"; $lines += 'Local models (name, size):'
      foreach ($m in (Invoke-RestMethod "$url/api/tags" -TimeoutSec 5).models) { $lines += ("  {0}  {1:N1} GB  {2} {3}" -f $m.name, ($m.size / 1GB), $m.details.parameter_size, $m.details.quantization_level) } }
catch { $lines += 'Ollama: not running' }
foreach ($c in 'claude', 'gemini') { $v = try { (& $c --version 2>$null | Select-Object -First 1) } catch { 'not installed' }; $lines += "$c CLI: $v" }
$lines += '', 'Sous chef settings (kitchen.json):'
foreach ($cp in (Join-Path $PSScriptRoot '..\kitchen.json'), (Join-Path $kroot 'kitchen.json')) {
    if (Test-Path -LiteralPath $cp) {
        $k = Get-Content -LiteralPath $cp -Raw | ConvertFrom-Json -AsHashtable
        foreach ($sec in 'suppliers', 'menu', 'sous') { if ($k[$sec]) { $x = $k[$sec]; if ($sec -eq 'sous') { $x = @{} + $x; $x.Remove('privateWords') }; $lines += "  $sec ($([IO.Path]::GetFileName((Split-Path -Parent $cp)))): $($x | ConvertTo-Json -Depth 6 -Compress)" } }
    }
}
Set-Content -LiteralPath $Out -Value $lines -Encoding utf8
Write-Output "inventory: wrote $Out ($($lines.Count) lines)"
exit 0
