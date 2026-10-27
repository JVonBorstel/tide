# WO-UPG-L2-3: the convergence workflows (2026-10-26)

**What:**
- New `core/engine/converge/`:
  - `workflows.mjs` holds the plans. Each one turns a snapshot into a list of actions:
    - freshen-pr;
    - re-review;
    - retry: a fresh crew for a stale row, at most 2, then one re-plan-or-drop card;
    - re-cook from intent: a conflict fix and a rebuild from the BRIEF in parallel, then a verifier pick;
    - the PICKUP archive (older than 48 h; moved, never deleted);
    - worktree tidy (merged, clean, idle 24 h; branches kept);
    - close-superseded (private PRs whose tide port is merged);
    - the nightly contradiction finder;
    - the morning card (one card, at most 3 taps).
  - `run.mjs` carries the actions out or, in a dry run, only prints them.
  - `schedule.mjs` sets the timing: every 2 h, every 6 h, nightly at 02:00, and 07:00.
- **The yes rule.** An action that needs Jordan's yes only creates one card, unless the log holds a standing yes (a standing card of that kind and topic, answered Yes) or a one-off Yes on that exact card.
  - A No skips the action.
  - A later standing No withdraws the standing yes.
  - A second run never makes a second card for the same action.
- **The governor.** Heavy and bulk actions ask it first. Since the #33 review fix, it has the burn window and the weekly limit.
- **Interrupted actions.** An action that changes things (freshen-pr, worktree-remove, pr-close, pickup-archive) writes an `x.converge.intent` first. If an earlier run was interrupted after its intent, a probe looks before any rerun:
  - done: recorded, not run again;
  - not done: run;
  - unknown, or no probe: one card, never a blind second run.
  This is the same rule as #33's steps.
- **The command line is a dry run only:** `node core/engine/converge/run.mjs <workflow> --snapshot <json> [--events <log>]`.
- **Cards about no single order** are filed under `WO-HOUSEKEEPING`, because the event contract needs a `wo` on decision events. A card for L0 asks to allow `null` there, as `decision.schema.json` already does.
- No Yard file is touched, and the switches stay `"old"`.

**Why:**
- Build-way 3.6: cleanup and re-queueing happen on a schedule, not when someone remembers.
- Jordan's standing yeses in section 9 are honoured only as events in the log, never as a chat's word.

**Tests:**
- Engine 164/0 with 4 skipped (Temporal). Converge 45/0 of them:
  - all 9 workflows dry-run with nothing called and nothing written;
  - the yes rule tested both ways for 4 yes-needing actions (freshen-pr, worktree-remove, private PR close, recook's freshen);
  - no duplicate cards; a one-off Yes; a No; a withdrawn standing yes; a standing yes on another topic does not count;
  - the governor hold, the schedules, the morning card's limits and the command line;
  - interrupted actions: done, not done, unknown and no probe, plus the intent-before-run order.

**L1-L4:**
- **Person:** Jordan taps once (a standing yes) instead of every time, and can withdraw it.
- **Business:** held PRs stop rotting.
- **MSP:** the same rules apply to any repo.
- **Community:** public code with synthetic data.
