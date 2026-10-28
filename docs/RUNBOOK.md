# Runbook

Short answers for when something is wrong. Repo: `VonBorstel-J/tide` (public).

## Roll back a bad change
Pick the lightest one that fits. All of them add a new commit; none delete history.

1. **A merge on `main` (any change):** revert the merge commit.
   ```powershell
   git switch main; git pull
   git revert -m 1 <merge-sha>        # -m 1 keeps main's side; for a squash commit, drop -m 1
   ```
   Put it through a PR like any other change (branch, PR, CI green, Jordan's sign-off). In an emergency, revert locally on `main` and tell Jordan.
2. **A merged Yard work order (code: job, Spec `improve`):** the Yard reverts it for you.
   ```powershell
   pwsh -NoProfile -File kitchen\undo-merge.ps1 -Job J123      # or the Undo button on the Board (code: Chef)
   ```
   It runs `git revert -m 1` on the work order's merge, refuses if the checkout is dirty or later work builds on it (then nothing changes), and pauses auto-merge for 24 h.
3. **The Board (code: `pass-app/`) server change:** revert the commit (step 1), then run `pwsh pass-app\update.ps1` (or `just pass-update`).
   `update.ps1` syntax-checks, trials the server on a spare port, and only then swaps, so a bad server never replaces the live one; it does not keep the old version for you, so a bad one that already went live needs the revert plus `update.ps1 -Force`. App files under `pass-app/public/` need no restart; phones pick them up on their own.
4. **A release you do not want to use:** a release is only a tag on a commit. Fix forward or revert (step 1); the next green `main` gets a new tag. To delete a tag and release, ask Jordan.

## Read a CI failure
Open the run in the Actions tab. Two jobs:

- **checks** (ubuntu, minutes): the log shows `FAIL: <file>:<line> <what>` for a PowerShell parse error, a `node --check` failure, bad JSON, or a secret-shaped string (the value is never printed; fix by removing it and rotating if it was real). A Rust `cargo check` error is real; `clippy` is advisory only. Reproduce locally: `pwsh -NoProfile -File scripts/ci-quick-checks.ps1`.
- **windows-suite** (windows, ~28 min, its own workflow): the full sandboxed suite on a clean box. Weekly (Sunday), by hand from the Actions tab, and on `ci/**` branches; not per PR, because the Yard (code: `kitchen`) runs the whole suite on the PC before every PR and again on main after the merge, and Windows minutes bill double on the free plan.
  1. Open the run, scroll to Artifacts, download **tests-report** (kept 30 days). It is `.kitchen/TESTS.txt`.
  2. Each suite has one line: `PASS` / `FAIL`, the suite name, its summary, and seconds. Lines under a `FAIL` are its first failing checks. The last line is `ALL PASS` or `FAILED: <suites>`.
  3. Re-run the failed suite locally: `pwsh -NoProfile -File scripts\run-bounded.ps1 -Script tests\Test-X.ps1 -TimeoutSeconds 600`.
  4. A suite that failed once and passed on retry is reported as flaky in the Yard; CI treats a final FAIL as a failure. Re-run the workflow once to tell a flake from a real failure.
- No `tests-report` artifact means the CI job died before the tests Step (code: station) ran (sandbox build or checkout). Read the step logs.

## Releases and tags
- Every green push to `main` (ci succeeded) gets a tag and a GitHub Release with auto-generated notes. Workflow: `.github/workflows/release.yml`.
- Scheme: `vYYYY.MM.DD.N`, UTC date, `N` counting from 1 within the day (`v2026.10.20.1`, `v2026.10.20.2`).
- One release per commit: a commit that already has a `v*` tag is skipped, so re-running is safe.
- The first release only appears after `release.yml` is on `main` (workflow_run workflows run from the default branch).
- Find the version running: `git describe --tags --always`.
