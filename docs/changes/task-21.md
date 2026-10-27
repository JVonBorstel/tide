# Task orchestrator: first live run (2026-10-27)

**What:** the first real run of `.claude/workflows/task-orchestrate.js`. Before this, it had only run against a fake `agent()` in the tests. In this run the pick took the store's lock and handed one task to a builder, which built this change. The change fixes four things that run showed in the builder's prompt, plus one in the plan's prompt:

1. **The new branch no longer tracks main.** `git worktree add <wt> -b task/<n> origin/main` set the new branch's upstream to `origin/main`. Until the first `push -u`, a plain `git push` or `git pull` in the worktree would have gone to main. It is now `worktree add --no-track`: the branch gets its own upstream at its first push.
2. **Test names are public, so they use public words.** The prompt said "every acceptance line gets a test named after it", but acceptance lines live in the private task body and test names are public. Now each acceptance line gets a test named in public words for the behaviour it checks. A task with no acceptance lines tests what its goal asks and says so in its change note. The plan's prompt also asks for "Done means" lines in public words.
3. **The change note is always in scope.** Every task must add `docs/changes/task-<n>.md`, but that path was not in its declared paths, so it looked like an outside path. The prompt now says the note is part of every task's paths.
4. **The PR title is shell-safe.** The `public_title` went into `--title "..."` unchanged. A quote, `$`, backtick or backslash in it would break the command or be expanded by the shell. Those characters are now replaced, as is already done for note text. Apostrophes stay.
5. **No orchestrator inside an orchestrator.** A builder must not start `/task-start`, `/task-orchestrate` or the Workflow tool from inside a run, because the lock refuses it. When a task asks for a live run of the orchestrator, the run working that task is the live run.

**Why:** the fake agent never creates a branch, never names a test and never meets a title with a quote, so the tests could not catch these.

**Tests:** Task 138/0 (`tests/Test-TaskCli.ps1`, through `scripts/run-bounded.ps1`), up from 132/0 on main. The 6 new checks are named `wf live: ...`: the `--no-track` worktree and `push -u`, public test names and the no-acceptance-lines case, the change note in scope, no nested orchestrator, the plan's "Done means" lines, and a shell-safe PR title (a public title with `"`, `$`, a backtick, a backslash and an apostrophe). All 6 failed (132 passed, 6 failed) with main's workflow file and pass after the change. Neighbouring suites, all through `scripts/run-bounded.ps1`: Standards 20/0, Task-name 40/0, Privacy 31/0, Lint 12/0, Jobs index 13/0, BoardDeploy 13/0. `scripts/verify-all.ps1` as a whole did not finish inside the 600 s bound, so its total is unknown.

**Not verified live:** this run covered pick and build only. Verify, merge, gate and plan have still only run against the fake agent. Whether they work live is unknown until this PR goes through them.

**L1-L4:** person: Jordan's tasks reach a PR without a branch that points at main or a title that breaks the command. Business and MSP: the same prompts keep private task text out of public test names in any repo. Community: a generic task runner whose prompts were checked against a real run.
