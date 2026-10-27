---
description: Raise a new task in the local task store from a short brief (it joins the pool; a running orchestrator picks it up)
argument-hint: "<brief>"
---
Raise one task from this brief: $ARGUMENTS

The task store is local and private (`node tools/task.mjs where`). Do not build anything now; only write the task.
1. Look just enough to make it workable: which files it will touch (`paths`: narrow globs or files; lanes run tasks side by side only
   when their paths do not clash, and no paths means it always runs alone), which existing tasks it needs first
   (`node tools/task.mjs list`), and which milestone it belongs to (`node tools/task.mjs roadmap`).
2. Write the body to a temp file: `## Goal`, `## Why` (L1 person / L2 business / L3 MSP / L4 community), `## Done means` (each line
   becomes a named test), `## Do not touch`, `## Stop and ask when`. Keep Jordan's own words from the brief.
3. `node tools/task.mjs new --title "<short private title>" --public-title "<neutral title, safe for a public PR: no private names>" --paths <a,b> [--depends <numbers or jordan>] [--milestone <n>] [--priority 1-9] --body-file <temp file>`,
   then delete the temp file. Anything that needs Jordan (a decision, an install, a setting, money, a publish) gets `--depends jordan`.
4. `node tools/task.mjs check`, then reply with the task number, its public title, paths, and whether it is ready now.
