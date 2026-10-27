---
description: Work one task from the local task store to a merged PR (build in its own worktree, independent review, merge on SHIP + green CI)
argument-hint: "<task number>"
---
Work task $ARGUMENTS with the task orchestrator, one task only (no planning, no other tasks). Docs: README "Task orchestrator".

1. `node tools/task.mjs show $ARGUMENTS` to see it exists and what it waits on (read it yourself; it is private: never paste its text
   into a commit, PR, branch name or any public place; only its public_title may appear there). If it is malformed, waits on
   another task, or waits on "jordan", say so and stop; do not work around a dependency.
2. Run the saved workflow with the Workflow tool: name `task-orchestrate`, args `"$ARGUMENTS"` (a bare number means single-task mode).
3. Report in at most 5 plain lines: PR and merge commit, or why it waits on Jordan or was held, and the gate result.
