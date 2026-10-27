# WO-UPG-L2-2: adopt, turning a pushed branch or PR plus its BRIEF into a work order (2026-10-26)

**What:**
- New `core/engine/adopt.mjs`, with its limits in `core/engine/adopt.json`. It reads a branch's `BRIEF.md`, checks it against the brief contract, checks the WIP and decide-before-build rules, and gives the contract events that start the work order:
  - `wo.created`, then `pr.opened` for a PR;
  - for a pushed branch with no PR yet, a finished `build` step instead.
- **Refusals.** Every reason is named at once, exit 3:
  - no BRIEF, or one that fails the contract, or one with no goal line;
  - a 5th open build stream;
  - a stream with 3 cards waiting on Jordan;
  - Board files on a branch not based on main;
  - art files with `decision: none`;
  - art files with a decision id but no decisions log to check it against;
  - art files with a decision Jordan has not answered;
  - open streams or changed files that are unknown.
- **The command line:**
  ```
  node core/engine/adopt.mjs --brief <BRIEF.md> --streams <file> [--pr <repo#n> --head <sha>] [--files <file> | --repo-dir <checkout>] [--alias J<n>] [--decisions <events.jsonl>] [--write <events.jsonl>]
  ```
  - It prints one JSON line.
  - It writes only with `--write`, and only through the engine's event sink from WO-UPG-L2-1. Until that merges, `--write` refuses and writes nothing.
  - Changed files come from local git (`base...branch`). No network is used.
- `adoptActivity()` runs the same checks as an engine activity and returns an activity-result.
- New suite: `tests/Test-Adopt.ps1`, which runs `tests/core/engine/test-adopt.mjs`.
- No Yard file or state file is touched. `upgrade.engine.adopted` stays `"old"`.

**Why:**
- Build-way 2.3: session and ultracode work has to become a WO, so the engine (not a chat) finishes it.
- Build-way 3.3 and Jordan's answers in section 9: WIP limits and "decide before build" are enforced in code.

**Tests:**
- Adopt 31/0, run through run-bounded on Windows.
- Review fixes (verifier, 2026-10-26):
  - art files with a decision id and no decisions log are refused, not adopted unchecked;
  - path globs match without regard to case;
  - `--write` uses the sink's one-lock `appendAll` when it has one.
- The 3 refusal kinds each have named tests (no BRIEF: 5; WIP: 6; art: 5).
- Event shape: 4 tests, and every event is checked against the contract.
- The command line, the activity and the git path have their own tests.
- `--write` was also run with WO-UPG-L2-1's `events.mjs` copied in: it appends 2 events. Its test checks whichever case applies.

**L1-L4:**
- **Person:** a chat's finished branch stops depending on someone remembering it. Art work cannot start without Jordan's answer.
- **Business:** a 5th stream is refused instead of half-done.
- **MSP:** the same limits apply to any repo's work.
- **Community:** public code with synthetic data.
