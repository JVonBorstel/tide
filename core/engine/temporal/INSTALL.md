# Card for Jordan: install Temporal (2 taps)

**Why:** you picked Temporal as Tide's durable engine on 2026-10-26 (build-way 10.2 item 1). The engine code is written. Its Temporal tests skip until these two installs are done. Everything else in `core/engine` already runs and is tested without them.

**Recommended:** Yes, both. They are free and open source (MIT) and run only on this PC. No account and no cloud.

## Tap 1: the Temporal CLI (`temporal.exe`, which includes the local dev server)

In PowerShell:

```
winget install Temporal.TemporalCLI
temporal --version
```

- UNVERIFIED: the winget package id `Temporal.TemporalCLI`. Check it first with `winget search temporal`.
- The other way is the Windows zip from https://docs.temporal.io/cli/setup-cli. Put `temporal.exe` on PATH.

## Tap 2: the pinned `@temporalio/*` packages (your yes to adding packages to tide)

In PowerShell, from the tide checkout:

```
cd core/engine/temporal
npm init -y
npm install --save-exact @temporalio/client@1.24.0 @temporalio/worker@1.24.0 @temporalio/workflow@1.24.0 @temporalio/activity@1.24.0
```

- Version 1.24.0 comes from the tech scan. It verified the Windows x64 native binary of `@temporalio/core-bridge@1.24.0`. The others at 1.24.0 are UNVERIFIED: run `npm view @temporalio/worker version` first and use one version for all four.
- `node_modules` must not be committed. `.gitignore` is not in this lane's files, so a small follow-up PR adds `core/engine/temporal/node_modules/`. `package.json` and `package-lock.json` go into that PR too, so CI and Dependabot see the pins.

## Check (after both taps)

```
node core/engine/cli.mjs temporal                        # expect: temporal: available (<version>)
pwsh -File scripts/run-bounded.ps1 -Script tests/Test-Engine.ps1 -TimeoutSeconds 900 -MaxMB 4000
```

The Temporal part then runs the spike for real. It starts a dev server on a free local port in a scratch folder. Then it checks three things:
- It kills the worker while the order waits for your tap, restarts it, and the order resumes.
- A timer fires after a worker restart. This takes about 2 minutes, because ci-wait polls every 2 minutes.
- A signal (your Yes) wakes the waiting order.

The counts line must read `0 failed, 0 skipped`.

## What does not change

- The live Yard keeps running. `kitchen.json` `upgrade.engine.adopted` and `improve` stay `"old"`.
- Running the worker at logon is a separate card (build-way 10.3). It would be one at-logon task that starts the Temporal server, the worker and the Board.
- Moving a switch to `shadow` is a separate card too. Before shadow, this parity check must pass: for every order the engine adopts, the stage and state from `node core/engine/cli.mjs show <WO>` must match the Yard's ledger row for 24 hours.
- If you say no to Temporal, the fallback is the in-process engine (`core/engine/fake.mjs`) plus build-way's own SQLite runner. Nothing else changes.
