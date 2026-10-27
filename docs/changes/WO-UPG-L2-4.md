# WO-UPG-L2-4: Temporal for real (pinned packages; the live tests run and pass) (2026-10-26)

**What:**
- Jordan's install taps are done:
  - the Temporal CLI 1.9.1 (winget);
  - Node 24.22.1 next to the system Node 22.12.
- This PR pins the four `@temporalio/*` packages at 1.24.0 in `core/engine/temporal/package.json` and `package-lock.json`. That is the latest; `npm view @temporalio/worker version` said 1.24.0 on 2026-10-26.
  - They were installed with Node 24's npm and `--save-exact`.
  - npm 11 skipped the install scripts of `protobufjs` and `@swc/core`. The tests pass without them, so the reinstall line is `npm ci --ignore-scripts`.
- `.gitignore` gains `core/engine/temporal/node_modules/`.
- **Fixes from the first real run:**
  - `events.mjs` now creates the log's folder before it takes the lock. A first append into a new state folder failed with ENOENT.
  - The test double's ci-wait exit codes are now a queue. The timer test had passed without ever polling.
- **Docs:** `core/engine/temporal/INSTALL.md` now says what is installed and how to install it again. README, `engine.mjs` and the headers of `workflows.mjs` and `test-temporal.mjs` drop their UNVERIFIED notes.

**Why:**
- Build-way 10.2: Temporal is the engine. Its spike (kill the worker mid-wait, restart, resume) had only been written. Now it has run.

**Tests (runs read on this PC):**
- **Node 22.12** (the system Node, through `tests/Test-Engine.ps1` and run-bounded): Engine 122 passed, 0 failed, 0 skipped.
- **Node 24.22:** the same 122/0/0.
- The 4 live Temporal tests each start `temporal server start-dev` on a free 127.0.0.1 port, with its database in a scratch folder. All 4 pass, in about 2.5 min:
  - kill the worker mid-wait, restart it, the order resumes;
  - a timer fires after a worker restart;
  - a signal wakes a waiting order;
  - signals sent back to back are not lost.
- No temporal process was left running afterwards (tasklist).

**CI:**
- `ci.yml` is lane L4's file, so this PR does not edit it. Today CI runs none of the engine suites, so nothing in CI changes.
- On a box without the CLI or the packages (a CI runner, the weekly Windows suite), the 4 live tests SKIP and print why. They are counted apart from passes, never as passes.
- A card for L4 proposes a CI step that runs them for real, with the CLI pinned and checksum-checked (see the PR body).

**L1-L4:**
- **Person:** Jordan's taps now have a durable engine under them. A merge waits for him across restarts.
- **Business:** orders survive a crashed worker. This is proven by the kill test.
- **MSP:** the same pinned versions install from the lock file on any PC.
- **Community:** public code; the pins are visible.
