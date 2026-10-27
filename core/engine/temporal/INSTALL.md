# Temporal for the engine: installed (2026-10-26), and how to install it again

**Status:** Jordan's two taps are done on this PC:
- the Temporal CLI 1.9.1, through winget;
- the four `@temporalio/*` packages at 1.24.0, pinned by `core/engine/temporal/package-lock.json`.

The engine's Temporal tests run for real here: 4/4 pass.

## Install on a new PC or a fresh clone

1. **The Temporal CLI** (`temporal.exe`, which includes the local dev server):
   ```
   winget install Temporal.TemporalCLI
   temporal --version     # temporal version 1.9.1 (Server 1.32.0, UI 2.54.1) on 2026-10-26
   ```
2. **The packages, from the lock file** (no version choice, nothing newer):
   ```
   cd core/engine/temporal
   npm ci --ignore-scripts
   ```
   - `--ignore-scripts`: the tests pass without the install scripts of `protobufjs` and `@swc/core`. npm 11 skipped those scripts on the first install, and the tests passed anyway.
   - The Windows x64 native binary ships inside `@temporalio/core-bridge` (`releases/x86_64-pc-windows-msvc/index.node`).
   - `node_modules` is ignored by git (`.gitignore`).
3. **Check:**
   ```
   node core/engine/cli.mjs temporal                        # temporal: available (temporal version 1.9.1 ...)
   pwsh -File scripts/run-bounded.ps1 -Script tests/Test-Engine.ps1 -TimeoutSeconds 900 -MaxMB 4000
   ```
   The temporal part takes about 2.5 min, and its counts must show 0 skipped.

## Updating the packages

Change all four to one new version in `package.json`, run `npm install --ignore-scripts`, and commit `package.json` and `package-lock.json` together, with the engine tests passing.

## What does not change

- The live Yard keeps running. `kitchen.json` `upgrade.engine.adopted` and `improve` stay `"old"`.
- The worker refuses `--mode new` until that switch is `"new"`.
- Running the worker at logon is a separate card (build-way 10.3).
- **Moving a switch to `shadow` is a card.** Before shadow, this parity check must pass: for every order the engine adopts, the stage and state from `node core/engine/cli.mjs show <WO>` match the Yard's ledger row for 24 hours.
