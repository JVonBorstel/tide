# Fix three failing suites on main: Standards, JobsIndex, BoardDeploy (2026-10-27)

**What:**
- `pass-app/test-scene.mjs` (689 lines) is split by topic into `test-scene-stage.mjs` (212), `test-scene-world.mjs` (217),
  `test-scene-moments.mjs` (196) and `test-scene-purpose.mjs` (93). The slices are the old file's lines in their old order: each one
  exports the fixtures a later one reads and imports what it reads from an earlier one. `test-scene.mjs` (9) imports them in order and
  prints the same JSON list, so `tests/Test-PassApp.ps1` runs it unchanged.
- `tests/core/ledger/test-ledger.mjs` (763 lines) is split the way `tests/core/engine` already is: `lib.mjs` (shared check, temp folder,
  synthetic state folder, fake gh, git runner; 51), `ledger-core.mjs` (store, importers, view, export, CLI, parity; 337) and
  `ledger-share.mjs` (old items rebuilt, the review findings, share.mjs and redaction; 368). `test-ledger.mjs` (31) keeps the Node 22
  restart and runs the suites in the old order, so `tests/Test-CoreLedger.ps1` runs it unchanged.
- `scripts/rebase-orders.ps1` reads its orders through the job store (`kitchen/jobs-lib.ps1` `Update-KitchenJobs ... 'live'`, oldest
  first, an unreadable file still said and skipped) instead of listing `jobs\` itself.
- `pass-app/towers.mjs` finds an archived order's month in the archive's own index (`jobs\archive\index.jsonl`, a later line wins, as
  `Read-KitchenJobArchive` reads it) instead of listing `jobs\archive\`. `pass-app/test-city.mjs` writes its archived fixtures the way
  the store does (the index line, then the file).
- `tests/Test-BoardDeploy.ps1`: the real trial copied only `pass-app\` to a temp folder, but the server now loads
  `pass-app/work/flags.mjs`, which imports `../../core/ship/flags.mjs`, so the copied server could not start
  (`ERR_MODULE_NOT_FOUND`) and all three trial checks failed. The copy now also carries every top folder that pass-app's relative
  imports reach (derived from the code: today `core`) and `flags.json`. `pass-app/update.ps1` is unchanged: the live deploy runs the
  server in place, where `core\` exists.

**Why:** on main, Standards failed its size rule (`test-scene.mjs` 689 and `test-ledger.mjs` 763 lines, cap 600), JobsIndex failed
its listing lint (`rebase-orders.ps1:67`, `towers.mjs:126` and `:354` read the jobs folder past the store) and BoardDeploy failed its
3 real-trial checks (the copied server could not start). The size cap, the listing lint and the trial checks are unchanged.

**Tests:** (all through `scripts/run-bounded.ps1`)
- Standards 20/0 (was 19/1). JobsIndex 13/0 (was 12/1). BoardDeploy 13/0 (was 9/3; 1 new check: the trial copy carries what the
  server loads from outside pass-app).
- Ledger 343/0, the same 343 check names in the same order before and after the split. Scene: 181 checks, the same JSON list
  (names, order, results) before and after the split.
- PassApp 1270/0 (runs the scene and City checks; City has 1 new check, `LocalFloors_ArchiveIndex`: an archived order is read by its
  month in the archive index, and a file with no line there is not read). RebaseOrders 25/0. Quality 20/0.

**L1-L4:** person: Jordan's main is green again, so a red suite means a real break. Business and MSP: none. Community: the test
files are smaller and split by topic, so they are easier to read.
