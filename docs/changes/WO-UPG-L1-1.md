# WO-UPG-L1-1: the ledger (event store, importers, view, CLI, parity) (2026-10-26)

**What:**
- `core/ledger/`: the record of truth of the Tide upgrade (build-way 3.1). An append-only event log in SQLite (`tide.db`, through Node's
  built-in `node:sqlite`; no package), three importers (the Yard's jobs and log, GitHub PRs, worktrees + plans + BRIEF/REPORT front
  matter), the ledger view (rows, stage machine, states), Jordan's decision queue (oldest first), streams with WIP limits, feature flag
  values, a `ledger.json` export in the shape the Board reads, and parity against `kitchen/ledger.ps1`.
- One command: `node core/ledger/cli.mjs build|show|queue|streams|flags|parity|backup` (see `core/ledger/README.md`).
- Nothing reads it yet. The switch `upgrade.ledger` stays `old`, and the command refuses to write into the live state folder while it is.
  `kitchen/ledger.ps1` is untouched and stays the fallback.

**Covers the lane's builder rows** (one PR, one commit history; titled WO-UPG-L1-1): store (L1-1), import-yard (L1-2), import-github
(L1-3), import-local (L1-4), view + queries (L1-5), parity (L1-6).

**Measured on this PC (2026-10-26, a scratch copy of the state folder, real read-only `gh`):**
- 209 job files + 135 archived orders -> 344 work orders, 910 events; a rerun added 0 events.
- With GitHub (tide + the private history repo: 22 open, 124 merged PRs read): 332 more events, 4.6 s for the whole build.
- Parity against `kitchen/ledger.ps1` run on the same scratch copy: 312 old items; 112 same, 200 explained, **0 unexplained**.
  The explained ones: ideas never built (ideas are not work orders), roadmap items (not imported yet), ideas that shipped through an
  earlier order or a manual link, `claimed` (the row contract calls it lost), and new proof from GitHub merges.
- Node 22.12's bundled SQLite is 3.47.0 and has **no FTS5** ("no such module: fts5"). STRICT tables and WAL work.

**Cutover (each step is a card for Jordan; nothing here moves a switch):**
- **Before shadow:** on a fresh scratch copy of the live state folder, run `kitchen/ledger.ps1 build` with `BRAIN_KITCHEN=<scratch>`,
  then `node core/ledger/cli.mjs build --state <scratch> --db <scratch>\tide.db` and
  `node core/ledger/cli.mjs parity --db <scratch>\tide.db --old <scratch>\ledger.json`. It must exit 0 (0 unexplained items), and
  `tests/Test-CoreLedger.ps1` must pass.
- **Before new:** the same parity command, run against the shadow's own `<state>\tide.db` and that hour's `ledger.json`, exits 0 on every
  run for 24 h (build-way 4.3 cutover step 2), and the Board reads `ledger.next.json` with no change to its tests.

**Review fixes (verifier: SHIP AFTER FIXES, audits/review-tide-31-2026-10-26.md):**
- F1: observations (Yard stage and status, paused, PR head/mergeable, CI, open/closed) are written when their value changes, not once per
  value, so A -> B -> A is kept (5 tests: running/waiting/running, paused/resumed, CI fail/pass/fail, conflict/unknown/conflict,
  closed/reopened). Store schema 2 (a schema 1 file is brought up when opened for writing).
- F2: no raw SQL from the store; a trigger refuses REPLACE of an event and `recursive_triggers` is on (tests from an outside connection).
- F3: `ledger.next.json` and row `blockedOn` carry a card's id and kind, never its question text.
- F4: below Node 22.5 the command says it needs Node 22.5 in plain words.
- F5: `LEDGER_LIVE_STATE` adds a guarded folder; the Yard's own folder is always guarded.

**L1-L4:**
- Person: none yet (switched off). When it serves, Jordan's queue and the state of every piece of work come from one place, with proof.
- Business: none.
- MSP: none.
- Community: an event-sourced work ledger in plain Node with no packages, readable and testable by anyone.

**Tests:** `tests/core/ledger/test-ledger.mjs` (via `tests/Test-CoreLedger.ps1`): 124/0. Contracts suites unchanged: fixtures 132/0,
tests 133/0.
