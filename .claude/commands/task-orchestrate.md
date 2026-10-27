---
description: Work the local task store in a loop (pick, build each to a PR, verify independently, merge, gate, plan) until paused, out of work or out of usage
argument-hint: "[--lanes 1-4] [--max N] [--gate-every N] [--rounds N] [--no-plan]"
---
Start the task orchestrator. Docs: README "Task orchestrator".

1. Check the store first (read-only): `node tools/task.mjs where`, `node tools/task.mjs check`, `node tools/task.mjs state`, `node tools/task.mjs lock status`.
   If `check` reports problems, show them and stop: a malformed task is never worked. If the store is paused, say so and stop
   (Jordan resumes with `node tools/task.mjs resume`). If another run holds the lock, say so and stop (never release it yourself).
2. Run the saved workflow with the Workflow tool: name `task-orchestrate`, args `"$ARGUMENTS"` (the text exactly as given; empty is fine).
   Do not rewrite the workflow's steps by hand and do not run a second orchestrator beside a running one.
3. When it returns, tell Jordan in at most 8 plain lines: merged (task number, PR, Board redeployed or not), tasks now waiting on
   him and why, held merges, why it stopped, and the gate results (privacy live hits, suites). Never quote a task's private text in
   anything public; in this chat, the task numbers and public titles are enough.

The orchestrator stops by itself on: `node tools/task.mjs pause --reason "..."` (at its next pick), weekly usage at 95%, a full
5-hour window (state stays in the task files; running `/task-orchestrate` again resumes in-flight tasks), a privacy problem, or
nothing left that can start.
