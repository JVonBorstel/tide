# core/engine: the durable engine (Tide upgrade, lane L2)

The engine carries each work order (WO) from build to closed. It retries, waits and asks for Jordan's yes, without a chat holding the state. It is built next to the live Yard and does not replace it yet: `kitchen.json` `upgrade.engine.*` stays `"old"`.

## The parts

| File | What it does |
|---|---|
| `wo.mjs` | The WO lifecycle as data: the stage edges of build-way 2.1 (`EDGES`), `reduce(events)` to get a state and `next(state)` to get the one next command. Pure code (no files, no clock), so the same code runs inside Temporal. |
| `activity.mjs` | The activity contract (`core/contracts/activity*.schema.json`). `once()` never runs a finished step again (one result per idempotency key). It checks before rerunning a step that changes things (see below). Yard stations run as activities through `scripts/run-bounded.ps1`; the stations themselves are never edited. |
| `driver.mjs` | Carries out one command: run an activity, ask a card, close or drop. It writes the contract events that record it. Both engines use it. |
| `events.mjs` | The event sink. `fileSink` writes `<state>\engine\events.jsonl` (append-only, contract-checked, locked). `memorySink` is for tests. |
| `cards.mjs` | Decision cards (`decision.schema.json`) and the standing-yes lookup. |
| `governor.mjs` | May a crew start now? It reads `<state>\plan-usage.json`. Unknown readings, including a missing weekly number, mean hold. The week: from 85 % hold, from 95 % stop. In the last 60 min before the 5-hour window resets: run until 100 %, because what is left is lost at the reset. Otherwise: below 70 % run, from 70 % hold, from 85 % stop. |
| `engine.mjs` | The adapter interface (`start`, `signal`, `query`, `close`), `openEngine()` and `temporalStatus()`. |
| `fake.mjs` | The in-process engine. It needs no install and keeps everything in files in its own folder. It is used by the tests and as the stand-in until Temporal runs. |
| `temporal/` | The Temporal engine: the workflow, the activities, the worker and the client. It needs Jordan's two installs (`temporal/INSTALL.md`). |
| `cli.mjs` | Read-only looks (see below). |
| `converge/` | The convergence workflows (build-way 3.6): freshen-pr, re-review, retry (a fresh crew, at most 2, then a card), re-cook from intent, the PICKUP archive, worktree tidy, close-superseded, the contradiction finder and the morning card. Each is a pure plan over a snapshot; `run.mjs` carries the actions out or only prints them (dry run). An action that needs Jordan's yes only creates a card, unless a standing yes is in the log. `schedule.mjs` says when each one runs. |

## Safety lines (each one has a named test)

- **Merge only after Jordan's yes.** The merge command exists only after a `decision.answered` "Yes" from Jordan. The Yes must be on this WO's own merge card, for the head that card asked about.
  - A head that moves cancels that yes.
  - The merge station also refuses to run unless the log confirms that Yes.
  - While the switch is `shadow`, the merge station does not run at all.
- **Retries stop at 2.** After 2 retries (each with a fresh crew), the order is stuck. It asks one card: "Re-plan or drop?"
- **Stations that change things only run when the switch is `new`.** In `shadow`, only read-only stations (ci-wait) run.
  - The worker's `--mode new` is refused unless `kitchen.json` says `engine.adopted: "new"`.
  - Each repo's local checkout comes from `--repos`. A repo with no checkout listed waits (exit 127).
- **The reviewer is never the builder.** A verdict moves the order only when it names a crew reviewer and a different crew builder. This holds even in a log edited by hand.
- **A finished step never runs twice.** A crash mid-step resumes it under the same key and records it once: one `step.started`, one `step.done`. A result that was already stored is replayed, not rerun.
  - A read-only step (ci-wait) interrupted mid-run just runs again.
  - A step that changes things (merge, freshen, verify) writes an intent before it starts. After a crash, a probe checks the outside world first. For merge, it asks GitHub whether the PR is merged.
  - Done: recorded, not run again. Not done: run. Unknown, or no probe: held for Jordan with a card, never a blind second run.

## Commands

```
node core/engine/cli.mjs governor [--state <folder>]      # may a crew start now? exit 0 run, 1 hold/stop
node core/engine/cli.mjs show <WO-id> [--state <folder>]  # stage, state and the next command, from <state>\engine\events.jsonl
node core/engine/cli.mjs temporal                         # is Temporal installed? names what is missing
node core/engine/converge/run.mjs <workflow> --snapshot <json> [--events <log>]   # dry run of one convergence workflow; does nothing
node core/engine/temporal/worker.mjs --state <folder>     # the Temporal worker (after INSTALL.md); 127.0.0.1 only
node core/engine/adopt.mjs --brief <BRIEF.md> --streams <file> [--pr <repo#n> --head <sha>] [--files <f> | --repo-dir <checkout>] [--decisions <log>] [--write <log>]
                                                          # a pushed branch or PR + its BRIEF -> a WO; refusals named; writes only with --write
```

`--state` defaults to `$BRAIN_KITCHEN`, else `%LOCALAPPDATA%\brain-kitchen`. The commands only read.

## Tests

`pwsh -File scripts/run-bounded.ps1 -Script tests/Test-Engine.ps1 -TimeoutSeconds 600 -MaxMB 3000`

This runs `tests/core/engine/test-engine.mjs`. The suites are wo, activity, runner, governor, converge and temporal. `adopt` has its own suite: `tests/Test-Adopt.ps1`. Each test is named after an acceptance line. The Temporal suite skips its three live tests, saying why, until the installs are done.

## Not here yet (later slices, each its own PR)

- The actions the convergence workflows call. Today each one is an activity name the engine does not have yet:
  - `freshen-pr` and the merge queue (lane L4);
  - `review`, `retry`, `recook` and `pick` (lane L3 crews);
  - `pickup-archive`, `worktree-remove`, `pr-close` and `contradiction-finder`.
- The snapshots the convergence workflows read: open PRs, rows, worktrees and PICKUP entries. They come from lane L1's ledger once it lands.
- The build and review crews (lane L3) and the docs station (lane L4). Until they land, the steps that need them wait with exit 127 ("not built yet"). They do not use up retries.
