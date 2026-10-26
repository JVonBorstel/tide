# Station: file the research team's IDEA lines (saved by the step before into <kitchen>\ideas\<job>.md) in the idea list.
param([string]$Source = 'research')
$kroot = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
$job = $env:KITCHEN_JOB; if ($job -notmatch '^J\d+$') { Write-Output 'ideas: no kitchen job'; exit 2 }
if ($Source.Length -gt 80) { $Source = $Source.Substring(0, 77) + '...' }
& (Join-Path $PSScriptRoot '..\ideas.ps1') harvest -From (Join-Path $kroot "ideas\$job.md") -Source $Source
exit $LASTEXITCODE
