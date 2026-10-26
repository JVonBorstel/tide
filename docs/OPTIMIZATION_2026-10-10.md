# Agent optimization: baseline, levers, how to prove it (2026-10-10)
Tool: `scripts/usage-report.ps1` (no model; numeric fields only). Baseline: `docs/USAGE_BASELINE_2026-10-10.md`. Weights are APPROXIMATE relative units, not dollars.

## Baseline (whole history, 1 main session + 24 subagents, 1,025 turns)
- 36.4M weighted units: main thread 25.6M (70%), subagents 10.8M (30%).
- 96.5% of all tokens are cache reads (the context re-read every turn): cost scales with context size x turns.
- 34.1% of units were spent while main context was above 50% of the 1M window, 25.6% above 65% (peak 917,741 tokens).
- Boot cost (first-turn context) 66,268 tokens; our always-loaded instruction files are only ~5k tokens of that. The rest is harness: tool lists, MCP names, plugin skill catalog.
- Most expensive subagents: general-purpose 2.57M (90 turns), general-purpose 1.14M (38), builder 1.10M (37).

## Levers (done = built and tested; gain is PROVEN only by re-measuring on new sessions)
1. DONE auto-compact at 650K + Guard (keep working) + PreCompact refresh-boot + SessionStart boot-inject: targets the 25.6% spent above 65% context.
2. DONE boot-cost trim: 22 unused plugin skills (data:*, engineering:*, cowork-plugin-management:*) set to `name-only` in ~/.claude/settings.json (still invocable; descriptions hidden). Backup: settings.json.bak-2026-10-10. Reversible by deleting `skillOverrides`.
3. DONE Gradle daemon idle timeout 10 min (RAM, not tokens).
4. POLICY (AGENTS.md): lean subagents, model chosen per task, reports to files (<=15 lines back), batch independent tool calls, one audit swarm per week.
5. LATER: local models for classify/summarize; trimming MCP connector names (needs Jordan's call: Gmail/Calendar/Drive are connectors he may use).

## How to prove the gain (run on any day after 2026-10-11)
`pwsh -File scripts/usage-report.ps1 -Since 2026-10-11 -OutPath <file>` and compare with the baseline: (a) boot cost per NEW session should fall below 66,268 (lever 2); (b) share of units above 65% context should fall toward 0 (lever 1); (c) subagent units per task. Rollback any lever that costs functionality.
