# Faster verify when no suite maps to a change (2026-10-27)

**What:** `kitchen/stations/tests.ps1 -Impacted` maps a changed file the fixed table does not cover by ownership instead of running
every suite:
- A file is owned by the suites that name it by its full path (`/` or `\`) and by its own `Test-<Name>` suite (`rebase-orders` ->
  `Test-RebaseOrders`). Before, only `pass-app/**`, `scripts/memory-check.ps1` and `kitchen/**` files were looked up this way; any
  other file ran all suites.
- A file with no owner runs the owners of the other files in its folder (shared core files such as `scripts/run-bounded.ps1` left
  out, since every suite runs through them). The run prints `impacted map: no suite names <file>; running the suites that own other
  files in <folder>/ (...)`.
- Only a file with no owner and no folder owner (or one at the top of the repo) runs all suites, with the reason printed as before.
- Shared core files, `tests/` helpers and an unknown change list still run all suites. Runs without `-Impacted` are unchanged.
- Each suite's text is read once per run (the score and the owner lookup share it).

**Why:** a change to `scripts/rebase-orders.ps1` and `pass-app/towers.mjs` had no mapped suite for the first file, so the impacted
run fell back to all 94 suites.

**Tests:** (all through `scripts/run-bounded.ps1`)
- `tests/Test-TestImpact.ps1` 35/0 (was 26/0; 9 new checks: a file named by a suite's path or by its `Test-<Name>` runs that
  suite only, mixed with a table file both owners run, an unowned file runs its folder's owners, a shared core file in the folder
  does not pull in its owners, no folder owner or a top-level file runs all, and a change to the rebase-orders script mapped against
  this repo's 94 real suite texts runs 1 suite, 2 with the towers module). With main's `tests.ps1` 8 of the 9 new checks fail and
  the suite hits its 600 s limit (it runs all 94 stub suites).
- The real station on this branch with `-Impacted -ChangedFiles scripts/rebase-orders.ps1,pass-app/towers.mjs`: `impacted run: 2 of
  94 suites` (PassApp 1270/0 in 162 s, RebaseOrders 25/0 in 25 s), 188 s in all.
- `tests/Test-TestsStation.ps1` 85/0, `tests/Test-Standards.ps1` 20/0, `tests/Test-Sandbox.ps1` (copies the station) 44/0.

**L1-L4:** person: a change to a script with its own suite is checked in minutes instead of the hours a full run
takes. Business: fewer bounded-run minutes per change. MSP: the safety rule is unchanged (a narrowed run is `PARTIAL PASS`,
never `ALL PASS`, and CI still runs every suite). Community: the owner rule (a suite that names a file owns it) is plain and
documented in `kitchen/BUILDING.md`, "Which suites run".
