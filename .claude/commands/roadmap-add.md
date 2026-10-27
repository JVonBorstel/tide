---
description: Add a roadmap milestone to the local task store; the orchestrator's plan step raises its tasks when it comes up in roadmap order
argument-hint: "<milestone brief>"
---
Add one roadmap milestone from this brief: $ARGUMENTS

The task store is local and private (`node tools/task.mjs where`). Do not raise its tasks now: the orchestrator's plan step raises
them, milestone by milestone in roadmap order, when nothing else is ready.
1. `node tools/task.mjs roadmap` to see the current order. Pick `--order` (after the last one unless the brief says otherwise) and
   any milestones it needs first (`--depends <numbers>`; `jordan` when it waits on his decision).
2. Write the body to a temp file: `## Goal`, `## Why` (L1-L4), `## Sources` (plan files and sections the plan step must read),
   `## Done when` (what "milestone done" means), `## Out of scope`.
3. `node tools/task.mjs new --kind milestone --title "<private title>" --public-title "<neutral title>" --order <n> [--depends <...>] --body-file <temp file>`,
   delete the temp file, run `node tools/task.mjs check`, and reply with the number, its place in the roadmap, and what it waits on.
