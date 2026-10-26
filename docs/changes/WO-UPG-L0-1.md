# WO-UPG-L0-1: shared contracts for the Tide upgrade (2026-10-26)

**What:**
- New `core/contracts/`: 13 JSON Schema (2020-12) contracts plus shared pieces (`common.schema.json`). They cover:
  - the event, the ledger row and the decision;
  - the brief and report front matter;
  - the activity and its result;
  - the 5 Board API shapes (`/api/work`, `/api/work/:id`, `/api/decide` body and answer, the `/api/work/stream` message);
  - the `upgrade` switch block.

  The fields follow `plans/build-way-2026-10-26.md` 3.1, 3.7 and 4.2.
- **`validate.mjs`:** checks any object against a contract (`validate('event', obj)`) or every fixture (`node core/contracts/validate.mjs`).
  It uses `jsonschema.mjs`, a zero-package checker for exactly the keywords the contracts use; any other keyword is refused, never skipped.
  Cross-field rules: a card's recommended answer and answer are among its options; a choose card has one mock-up per option; the queue
  is open cards, oldest first.
- **`frontmatter.mjs`:** the BRIEF.md / REPORT.md front matter format (parse and write), so the ledger (L1) and the crews (L3) read it the same way.
- **`upgrade.mjs`:** `switchOf(kitchenJson, piece)` reads a switch. A missing block, a missing piece or an unknown value reads as `old`.
- **122 fixtures, all invented:**
  - one event per kind (17), one decision per kind (8) and one row per stage (8);
  - valid examples for every other contract;
  - 55 invalid fixtures, each with the reason it must be refused.
- **`kitchen/kitchen.json`:** a new `upgrade` block with all 8 pieces `"old"` (ledger, engine.adopted, engine.improve, crews, ship.gates,
  ship.queue, board.work, continuity.boot). Nothing reads it yet; moving a switch on the live PC is one card for the Owner.
- **`.github/workflows/ci.yml`:** one step in the `checks` job runs the fixtures and the suite, and writes the counts to the run summary.

**States:**
- An unreadable file, a broken schema or a usage error exits 2.
- An invalid document exits 1 and names each reason with its path.
- An unreadable kitchen.json reads as all `old`, with the reason.

**Tests:** `tests/Test-Contracts.ps1` (`tests/core/contracts/test-contracts.mjs`), one test per acceptance line of the L0 brief. Counts are in the PR.

**L1-L4:**
- Person: none yet. This is the groundwork that lets the Work tab, the queue and the engine be built in parallel.
- Business: none.
- MSP: none.
- Community: the contracts are plain JSON Schema with examples, readable by anyone who wants to build a piece of Tide.
