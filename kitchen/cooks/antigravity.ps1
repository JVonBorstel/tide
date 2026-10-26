# Cook adapter: the other models on Jordan's Google AI Pro plan through Antigravity (agy): Claude Opus / Sonnet 5.5 and GPT-OSS.
# A second Claude on the subscription he already pays for; no Anthropic sign-in needed. Same money guard and locked-down tools as
# cooks/gemini.ps1 (both run cooks/agy.ps1). Same contract as cooks/claude.ps1.
param([switch]$Probe, [string]$Prompt = '', [string]$Model = '', [string]$Effort = '', [string]$Tools = 'Read,Grep,Glob', [string]$Mode = 'plan',
      [int]$MaxTurns = 15, [double]$MaxBudgetUsd = 2, [int]$TimeoutSec = 1500, [string]$Role = 'do')
& (Join-Path $PSScriptRoot 'agy.ps1') @PSBoundParameters -Label 'Antigravity'
