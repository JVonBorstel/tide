# Cook adapter: Gemini on Jordan's Google AI Pro plan, through the Antigravity CLI (agy). The Gemini CLI stopped serving personal
# accounts on 2026-06-18 ("This client is no longer supported..."), so this cook now runs on agy; see cooks/agy.ps1 for the money
# guard (subscription only, stops at the quota) and the locked-down tool settings. Same contract as cooks/claude.ps1.
param([switch]$Probe, [string]$Prompt = '', [string]$Model = '', [string]$Effort = '', [string]$Tools = 'Read,Grep,Glob', [string]$Mode = 'plan',
      [int]$MaxTurns = 15, [double]$MaxBudgetUsd = 2, [int]$TimeoutSec = 1500, [string]$Role = 'do')
& (Join-Path $PSScriptRoot 'agy.ps1') @PSBoundParameters -Label 'Gemini'
