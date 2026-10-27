# Task orchestrator: a task CLI, a looping workflow and four commands (2026-10-26)

**What:**
- `tools/task.mjs`: a dependency-free CLI over a local, private folder of numbered task files (dev tasks and roadmap milestones) with front matter: list, show, next (lanes that never share a path, WIP limit 4, claim, resume), roadmap, new, set, note, pause/resume, usage, check.
- `.claude/workflows/task-orchestrate.js`: pick -> work (own worktree, PR) -> verify (impacted suites, CI, an independent reviewer) -> merge (`scripts/merge-pr.ps1`) -> gate (privacy scan, suites, one tidy-up task) -> plan (next milestone), until paused, out of work or out of usage.
- `.claude/commands/`: `/task-orchestrate`, `/task-start`, `/task-new`, `/roadmap-add`.
- `core/ship/gates.json`: `tests/Test-TaskCli.ps1` joins the CI Core step's suites.

**Why:** the work list and its state live in files, not in a chat, so a cut-off run continues where it stopped, and tasks can be added at any time.

**Tests:** Task 102/0 (`tests/Test-TaskCli.ps1`): front matter, malformed files, order, dependencies incl. `jordan`, path clashes and lanes, WIP, pause/resume, usage verdicts, new/set/note, roadmap, store choice; the workflow against a fake agent (fix rounds, escalation, one merge at a time, gate, plan, privacy pause, usage stop, single task, a repo that is not public refused).

**L1-L4:** person: Jordan adds a task and the loop works it to a merged PR. Business and MSP: the same loop runs any repo's backlog. Community: a small, generic task runner with no packages.
