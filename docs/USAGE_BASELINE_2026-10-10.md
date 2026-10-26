# Usage baseline 2026-10-10

Numbers only; no transcript text. Produced read-only by `pwsh -File scripts\usage-report.ps1` over `%USERPROFILE%\.claude\projects` (all transcripts present on this machine on 2026-10-10, including this working session's own transcript, which was still growing while measured; later runs will be higher). Re-run the same command later and compare: that is the before/after yardstick.

Caveats: the history is ONE long main session plus its 24 subagents, so the boot cost has a single sample (min = median = max). Weighted units are APPROXIMATE relative weights (input 1, cache write 1.25, cache read 0.1, output 5), NOT dollars; no prices are assumed. Boot cost = input + cache write + cache read of the first main-thread assistant turn. Subagent ids are Claude Code agent ids; roles are the agentType from each agent's metadata file.

## Report output (scripts\usage-report.ps1, default arguments)
Scanned 26 transcript files; malformed lines skipped: 0. Days are UTC.
Weighted units = input*1 + cache_write*1.25 + cache_read*0.1 + output*5: APPROXIMATE relative weights, NOT dollars. Window = 1,000,000.
## Totals
- Turns 1,025; weighted units 36,407,238 (main 25,568,239, subagent 10,838,998)
- Fresh input 2,134; cache write 7,275,805; cache read 224,209,977; output 977,870
- Cache-read share of all tokens: 96.5%
## Boot cost (context of first main-thread turn per session)
- Sessions 1: min 66,268, median 66,268, max 66,268 tokens
## Main-thread units spent at high context
- Above 50% of window: 34.1% of main units; above 65%: 25.6%
## Sessions (top 6 by units; id, turns, units, boot, peak ctx, %>50, %>65)
- 2cde2945-494: 1025 turns, 36,407,238 units, boot 66,268, peak 917,741, 34.1%, 25.6%
## Top subagents by units (24 total)
- aee8934b2244 [general-purpose, claude-sonnet-5-5]: 90 turns, 2,567,780 units, peak ctx 275,180
- a3d82efd77c6 [general-purpose, claude-sonnet-5-5]: 38 turns, 1,138,254 units, peak ctx 211,033
- afa236152c50 [builder, claude-sonnet-5-5]: 37 turns, 1,101,908 units, peak ctx 187,700
- a28b6e2f0a58 [general-purpose, claude-sonnet-5-5]: 60 turns, 896,099 units, peak ctx 156,348
- ac08141012eb [general-purpose, claude-sonnet-5-5]: 21 turns, 586,117 units, peak ctx 153,285
- a8d242c1c1de [general-purpose, claude-sonnet-5-5]: 20 turns, 513,878 units, peak ctx 104,443
- ac71c49779d2 [builder, claude-sonnet-5-5]: 38 turns, 484,216 units, peak ctx 120,867
- ae3390da8bb5 [general-purpose, claude-sonnet-5-5]: 36 turns, 466,395 units, peak ctx 114,514
- a27b51634836 [builder, claude-sonnet-5-5]: 31 turns, 429,610 units, peak ctx 89,311
- a80e2db12d0b [general-purpose, claude-sonnet-5-5]: 22 turns, 426,122 units, peak ctx 148,462
## Per model (turns, units)
- claude-sonnet-5-5: 1014 turns, 36,217,306 units
- claude-haiku-5-5: 9 turns, 189,932 units
- other: 2 turns, 0 units
## Per day (UTC; latest 12)
- 2026-10-08: 119 turns, 3,101,419 units
- 2026-10-09: 668 turns, 24,099,309 units
- 2026-10-10: 172 turns, 6,365,420 units
- 2026-10-11: 66 turns, 2,841,091 units

## Always-loaded instruction surface (static character counts)

Counted with a plain file-length read of only these files (no content recorded). Characters / 4 is a rough token guess only.

| File | Characters |
|---|---|
| gemini-brain\AGENT_CONTEXT.md | 2,399 |
| gemini-brain\memory\NOW.md | 4,690 |
| gemini-brain\memory\ORG.md | 2,321 |
| gemini-brain\CLAUDE.md (pointer) | 44 |
| gemini-brain\AGENTS.md (pointer) | 90 |
| my-apps\AGENTS.md | 7,450 |
| my-apps\CLAUDE.md (pointer) | 167 |
| brain-monitor\AGENTS.md | 2,240 |
| Total | 19,401 |

Reading: the instruction files total about 19,400 characters (roughly 5,000 tokens), while the measured boot cost is about 66,000 tokens. So most of the fixed boot prompt is not these files (system prompt, tool and skill definitions, memory index, hooks), and trimming the files above can move boot cost by at most a few thousand tokens.