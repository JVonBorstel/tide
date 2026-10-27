# WO-UPG-L2-1: the engine core, engine-neutral, with the Temporal binding behind one interface (2026-10-26)

**What:**
- New folder `core/engine/` (lane L2 of the Tide upgrade). It holds:
  - the work order lifecycle as data (`wo.mjs`);
  - the activity contract wrapper over today's stations, run through `scripts/run-bounded.ps1` (`activity.mjs`);
  - one command runner that both engines share (`driver.mjs`);
  - an append-only event sink checked against the contract (`events.mjs`), and decision cards (`cards.mjs`);
  - the capacity governor (`governor.mjs`);
  - the adapter interface (`engine.mjs`) and an in-process engine (`fake.mjs`);
  - the Temporal workflow, worker and client (`temporal/`);
  - a read-only command line (`cli.mjs`).
- The Temporal part needs Jordan's two installs. They are listed with their exact commands in `core/engine/temporal/INSTALL.md`.
- New suite `tests/Test-Engine.ps1`, which runs `tests/core/engine/test-engine.mjs`.
- No station, recipe, `kitchen.ps1` or live state file is touched. `upgrade.engine.adopted` and `improve` stay `"old"`.

**Why:**
- Build-way 2.1 and 2.2: a durable record that finishes the work, so no chat has to remember a retry, a freshen or Jordan's tap.
- Jordan picked Temporal (build-way 10.2). The parts that do not depend on the engine come first. Temporal plugs in behind the same interface after the installs.

**Tests:**
- Engine 95/0 with 3 skipped. The 3 skipped are Temporal's live tests (CLI and packages not installed). Run through run-bounded on Windows.
- **wo:** every stage edge has a named test (26 edges, plus a check that none lacks one). Merge only after a "Yes" on this WO's own card for this head: named cases, plus 3,000 seeded random event orders, 72 of which reached a merge. After 2 retries the order is stuck and asks one re-plan-or-drop card.
- **runner:** two real kill tests. A child process is killed mid-step, after the result is stored and during the step. It resumes exactly once. A timer fires after a restart, in a new process. A signal from another process wakes a waiting order. Backoff caps at 3600 s.
- **governor:** it holds heavy crews at and above 70 %, stops at 85 %, and treats 7 kinds of unknown reading as hold.
- **activity:** one call per key, on disk too. The station refusals are tested. One real station double runs through `run-bounded.ps1`: its exit 11 is kept, and a time limit comes back as 124.
- **Not run:** the 3 Temporal live tests. They have never run on this PC: UNVERIFIED until the installs.

**L1-L4:**
- **Person:** Jordan's tap stays the only way to merge. The engine cannot merge without a Yes on the card for that exact head.
- **Business:** finished work stops waiting on a chat to push it along. Retries and waits survive restarts.
- **MSP:** the same engine runs any repo's orders. Its stations are the Yard's, through the same bounded runner.
- **Community:** the lifecycle, the contracts and the tests are public code with synthetic data only.
