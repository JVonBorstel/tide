# The Board restarts when any server module changes

**What:** `pass-app/server-id.mjs` computes one fingerprint over `server.mjs` and every local module it imports, static and dynamic (`towers.mjs`, `work/`, and the `core/` modules they reach), plus the `*.schema.json` files beside those modules (the contract validator loads and caches them). The server reports it in `/api/health` as `server`; `pass-app/update.ps1` computes the same value with `node pass-app/server-id.mjs` and restarts only when the two differ.

**Why:** the fingerprint used to be a hash of `server.mjs` alone. A merge that changed only an imported module (the City's `towers.mjs`, the Work API in `work/api.mjs`) printed "server unchanged, no restart needed", and the live Board kept running the old code until something forced a restart.

**Tests:**
- `tests/Test-BoardDeploy.ps1`: 20 passed, 0 failed. Seven new checks:
  - update.ps1 uses server-id.mjs;
  - the fingerprint is stable;
  - a change to a static import changes it;
  - a change to a dynamic import in another folder changes it;
  - a change to an unrelated file does not;
  - a change to a `*.schema.json` beside a reached module changes it;
  - the real server's fingerprint covers towers.mjs, work/api.mjs and core.
- `tests/Test-PassApp.ps1`: the health check now compares against server-id.mjs.

**L1-L4:** person: merged fixes reach the phone without a manual forced restart. Business, MSP, community: none.
