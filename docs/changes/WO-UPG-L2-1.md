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

**Review fixes** (from the verifier, 2026-10-26: `audits/review-tide-33-34-2026-10-26.md`):
- **Governor.**
  - Within 60 min of the 5-hour reset, it uses everything that is left: 90 % used 30 min before the reset runs. Otherwise the bands apply.
  - The weekly limit is now enforced: hold from 85 %, stop from 95 %.
  - A missing weekly number is unknown, which means hold.
- **Steps that change things** write an intent before the effect. After a crash, a probe decides: done is recorded, not done is rerun, and unknown is held with a card. Merge's probe asks GitHub.
- **A verdict** with no builder, no reviewer, or the same crew in both now moves nothing, even in a log edited by hand.
- **Stale commands.** A command that is no longer the order's next one is not carried out, so a retried Temporal activity cannot ask a second card.
- **The Temporal workflow** counts a wake before each read of the log, so a signal that lands during a read is not lost.
- **The worker** takes `--repos` (each repo's local checkout). It refuses `--mode new` unless the switch `engine.adopted` is `"new"`.
- **Exit 3** (adopt's refusal) is now held, not retried.
- **`appendAll`** writes several events all or none.

**Tests:**
- **Totals:** Engine 119/0 with 4 skipped. The 4 skipped are Temporal's live tests (the CLI and packages are not installed). KitchenSupervisor 222/0. Both ran through run-bounded on Windows.
- **wo:**
  - every stage edge has a named test (26 edges), plus a check that none lacks one;
  - merge only after a "Yes" on this WO's own card for this head: named cases plus 3,000 seeded random event orders;
  - 5 hand-edited verdicts move nothing;
  - after 2 retries, one card.
- **runner:**
  - real kill tests on a child process. The read-only step is killed after its result is stored, and during the step;
  - the merge is killed after its effect, before its effect, and with no probe. In all three it merges once in total, and the no-probe case holds with a card;
  - a timer fires after a restart;
  - a signal wakes a waiting order;
  - backoff caps at 3600 s;
  - appendAll writes all or none.
- **governor:** the burn window, the week, the bands, and 9 kinds of unknown reading.
- **activity:**
  - intent and probe: done, not done, unknown, and no probe;
  - ghMergeProbe's answers;
  - the station refusals, including a repo with no checkout;
  - one real station double through run-bounded.
- **temporal, always run:**
  - the workflow raced under a stand-in for `@temporalio/workflow`, with a wake sent during `loadEvents`. The old code waited forever; the fixed code ships;
  - the stale retry;
  - the switch check.
- **Not run:** the 4 Temporal live tests. They have never run on this PC: UNVERIFIED until the installs.

**L1-L4:**
- **Person:** Jordan's tap stays the only way to merge. The engine cannot merge without a Yes on the card for that exact head.
- **Business:** finished work stops waiting on a chat to push it along. Retries and waits survive restarts.
- **MSP:** the same engine runs any repo's orders. Its stations are the Yard's, through the same bounded runner.
- **Community:** the lifecycle, the contracts and the tests are public code with synthetic data only.
