# Port #133: Scheduled tasks run hidden and keep pwsh's exit code (no console flash)

Ported on 2026-10-26 by `scripts/port-private.ps1` from JVonBorstel/brain-monitor#133 (https://github.com/JVonBorstel/brain-monitor/pull/133) at `71ae78e03329250f405293fd16e8229382dcc255`, onto tide `main` at `8af1796`. The private repo is on a GitHub billing hold, so its work lands here; the private PR stays open.

## What it does (the private PR's description, cleaned)

Scheduled tasks run hidden with **no console flash**, and they still report pwsh's real exit code.

- `scripts/run-hidden.vbs` (new) runs a program hidden through `wscript //B //NoLogo` (no console of its own), waits for it, and returns its exit code. A program that cannot start returns the start error, never 0. For example, a missing pwsh returns `0x80070002`, the code from the earlier 2-day outage.
- Why not `conhost --headless`? It was set by hand on the live Tide-Yard and Tide-Cleanup on 2026-10-26. It hides the console but **always exits 0** (measured), so the task's Last Run Result, which `kitchen/watch.ps1` reads, stopped showing failures.
- `install-tasks.ps1` registers the tick and chores tasks in the new form, and `rgb.ps1` does the same for Rig-RGB-Off and Rig-RGB-On. The Board stays on `wscript start-hidden.vbs`.
- `kitchen-check.ps1` reads the pwsh inside either form (`Get-TaskProgram`) for the missing or version-pinned warning.
- `-WhatIf` prints the action it would build. Test-Kitchen now accepts the Tide task names.

**Tests (local, 2026-10-26):**
- Test-TaskNames: 40 passed, 0 failed. This includes running the launcher for real: exit codes 5 and 0 come back, a missing program gives 0x80070002, and no program gives 2.
- Test-Kitchen: 70 passed, 0 failed.
- Test-Rgb: not run, because it registers real tasks.

**After merge:** run `scripts/install-tasks.ps1 -WhatIf`, then run it for real, to move the live tasks from the hand-set conhost form to this one.

L1-L4: person, no flashing window; business and MSP, a failing task is visible again; community, no change.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

## How it was ported

The private branch's changes since its merge-base `d37031d` with the old private main, with the public cleaning (R1-R9) applied to both sides, applied with `git apply -3`. Only those changes are applied, so tide-only commits stay. The changed files, the commit message and the PR text passed the privacy scan (no live hit; any other new hit needs a person's -Allow, named in the PR).

## L1-L4

The effects are the private PR's own (its description above). The port itself only moves finished work to the public home: nothing changes for a person, the business, an MSP or the community beyond that.