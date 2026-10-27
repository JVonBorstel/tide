# Task orchestrator: a task CLI, a looping workflow and four commands (2026-10-26)

**What:**
- `tools/task.mjs`: a dependency-free CLI over a local, private folder of numbered task files (dev tasks and roadmap milestones) with front matter: list, show, next (lanes that never share a path, WIP limit 4, claim, resume), roadmap, new, set, note, pause/resume, usage, check.
- `.claude/workflows/task-orchestrate.js`: pick -> work (own worktree, PR) -> verify (impacted suites, CI, an independent reviewer) -> merge (`scripts/merge-pr.ps1`) -> gate (privacy scan, suites, one tidy-up task) -> plan (next milestone), until paused, out of work or out of usage.
- `.claude/commands/`: `/task-orchestrate`, `/task-start`, `/task-new`, `/roadmap-add`.
- `core/ship/gates.json`: `tests/Test-TaskCli.ps1` joins the CI Core step's suites.

**Why:** the work list and its state live in files, not in a chat, so a cut-off run continues where it stopped, and tasks can be added at any time.

**Tests:** Task 102/0 (`tests/Test-TaskCli.ps1`): front matter, malformed files, order, dependencies incl. `jordan`, path clashes and lanes, WIP, pause/resume, usage verdicts, new/set/note, roadmap, store choice; the workflow against a fake agent (fix rounds, escalation, one merge at a time, gate, plan, privacy pause, usage stop, single task, a repo that is not public refused).

**L1-L4:** person: Jordan adds a task and the loop works it to a merged PR. Business and MSP: the same loop runs any repo's backlog. Community: a small, generic task runner with no packages.

## Review fixes (2026-10-27, independent review of PR #43: SHIP AFTER FIXES)
1. Privacy counts the scanner's `hits` array, never its `live` object (the number of private values it loaded), in the builder's pre-push scan and in the gate.
2. While CI is pending, a re-check updates only the CI result and head; a failed suite stays failed and goes to the builder before any merge.
3. `/task-start` runs `node tools/task.mjs start <n>`, which checks pause, usage and the lock exactly as `next` does.
4. A merge held for a freeze, a red main or CI that never finished makes the task `blocked` + `depends: jordan` with a note, so a rerun does not rebuild it.
5. `--rounds N` gives N fix rounds (default 3: up to 4 reviews).
6. One orchestrator at a time: `.orchestrator.lock` in the store with a run id and a heartbeat (`lock acquire|heartbeat|release|status`; `next`/`start --run new|<id>`); a lock silent for 90 minutes is taken over and said so.
7. Every agent prompt forbids closing, reopening or approving a PR.
8. "pass-app changed" comes from the merged diff (`gh pr diff --name-only`), not the builder; a skipped redeploy leaves a note on the task.
9. The reviewer records the head it reviewed; checks and review must agree on it, and the merge passes it as `scripts/merge-pr.ps1 -ExpectHead <sha>`, which refuses when the PR is anywhere else.
Also: note text is made shell-safe; a merge sha of digits stays text; `--max` defaults to 40 (the 1000-agent cap).

**Tests:** Task 130/0 (28 new: start, lock, rounds, held merges, pending CI, head pin, Board from the diff, hits). MergePr 46/0 (2 new: `-ExpectHead` merges at the head, refuses elsewhere).
