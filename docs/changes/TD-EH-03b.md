# TD-EH-03b: Night inspection

Error-handling audit 2026-10-23, row EH-03b (Critical): nothing verifies main between Yard merges. A Foreman merge needs only the quick
checks, so main sat red for 8.5 hours with CI green on every commit. This adds a nightly full run of main on this PC: no GitHub minutes.

Built 2026-10-24 on brain-monitor main `6416a7c`, branch `td-eh-03b-night-inspection`. It reuses TD-EH-03a (main status), TD-EH-03c
(closed when red) and TD-EH-03d (`scripts/recheck-main.ps1`); none of their behaviour changes.

## Turn it on (the Owner's line)

It ships **off**. To turn it on, add this one line to the live `%LOCALAPPDATA%\brain-kitchen\kitchen.json` (inside the top-level `{ }`):

```json
"standingOn": ["night inspection"],
```

Nothing else changes in the live config: the order itself is defined in the repo's `kitchen/kitchen.json` `standing` list. The live file
has no `standing` key today, so the repo's list is the one the Yard reads, and `standingOn` only switches named orders on. To turn it off
again, remove the line.

## What runs

- **The order** (`kitchen/kitchen.json`): `{ "name": "night inspection", "watcher": "night-inspection", "atHour": 2, "off": true }`.
  Once a day, at or after 02:00 local time, like the overnight hunt's `atHour`.
- **The script** (`scripts/night-inspection.ps1`) adds no test logic. It runs `scripts/recheck-main.ps1 -Repo <brain-monitor> -All
  -SkipUnchanged` inside `scripts/run-bounded.ps1` (90 min and 10,000 MB for the whole tree by default; `-TimeoutSeconds`, `-MaxMB`).
  recheck-main does what it already does by hand: finds current main (this PC's or GitHub's, whichever is ahead; split apart or GitHub
  unreachable records nothing), checks it out in a throwaway worktree under TEMP, runs `kitchen/stations/tests.ps1` (each suite through
  run-bounded), removes the worktree, and writes the main status through `Set-MainStatus`. So the Board's red banner (03a) and the
  merge refusal (03c) follow the night's result with no new code.
- **Skipped when main is unchanged**: new `recheck-main.ps1 -SkipUnchanged`. When the main status is green from a full run (the verify
  Step, or a recheck `-All`) at the same commit, or a commit with the same tree, nothing runs and it exits 3 with
  `skipped: brain-monitor main is unchanged since its last green full run (<sha>, checked at <time>); nothing run, nothing recorded`.
  A green from a recheck of only the red suites proves only those suites, so it never counts. Red, no status, or a moved main: every
  suite runs.
- **One line a night** in `<kitchen>\night-inspection.jsonl`: `{at, repo, result, exit, sec, said}`, where result is green, red,
  skipped, no-verdict, timeout, memory or error, and `said` is recheck-main's last line. A timeout says "main is not proven either way";
  the status is left as it was, and the throwaway worktree is swept by the next recheck.

## Watcher orders, and the paused Yard

A standing order with `"watcher": "<name>"` in place of `"recipe"` (new in `Invoke-ChoreStanding`, `kitchen/kitchen.ps1`):

- runs `scripts\<name>.ps1 -KitchenRoot <kitchen>` on this PC, started detached (hidden), so neither the chores nor the Walkround wait on
  a run that takes many minutes. The stamp moves once it has started (`standing.started` event); no second copy starts while the last
  one is alive (`standingPid`: pid plus start time, so a reused pid does not count). A launch failure keeps the old 15-minute retry and
  the alert after 3 failures in a row.
- needs no `LIVE` file (no AI cook) and **starts while the Yard is paused**: the paused Walkround (`Invoke-Tick -Paused`) now calls
  `Invoke-ChoreStanding -WatchersOnly`. This is the TD-EH-26 rule: paused means start no work, still watch. The night inspection only
  reads main and writes the main status, the same file the verify Step writes. Recipe orders still cook nothing while paused.
- `"off": true` keeps an order off unless kitchen.json `standingOn` names it.

**Does it need #110 (`td-eh-26-watch-while-paused`, not merged)?** No. #110 keeps the doctor, the Watch and memory-truth running while
paused, through `Invoke-ChoresPaused` in the `chores` action and the paused `tick`. It says outright that no standing orders run there. The
night inspection is started from `Invoke-Tick -Paused`, which every paused Walkround runs on main today, with or without the
Kitchen-Chores task. #110 does not touch that function, so the two do not overlap and neither depends on the other. While the Yard is
live, the night inspection starts from the normal chores (`Invoke-Chores`), like every standing order.

## Known limit

The kitchen.json note says Windows Update has restarted this PC around 02:15 (10/12, 10/17), which is why the other night orders moved to
04:00-05:00. A night inspection that is still running at a restart is lost for that night (the stamp moved when it started), and the next
night runs. Most nights should be skipped in seconds (main unchanged); a moved main runs the full suite. The live `suite-times.jsonl` puts the
72 brain-monitor suites at about 49 minutes one at a time (each suite's longest recorded run, added up). The tests Step runs up to 4 at
once, so a real night's length is unknown until the first one runs; the 90-minute limit covers even the one-at-a-time figure. If restarts keep cutting it short, change `atHour` to 3 in the repo's kitchen.json.

## Proof

- `tests/Test-RecheckMain.ps1` section 7: `-SkipUnchanged` skips a green full run at the same commit (exit 3, nothing run, nothing
  written); a partial green does not count; the night inspection runs every suite on a moved main and records green with one line; the
  next night is skipped and the line says why; a run past its limit is stopped (124), and the line says main is not proven.
- `tests/Test-KitchenSupervisor.ps1` (watcher standing orders): started while PAUSED and not LIVE, with the kitchen root; an off order
  that `standingOn` does not name never starts; a recipe order cooks nothing while paused; once a day; no second copy while alive.
- `tests/Test-KitchenRecipes.ps1`: the repo order is a watcher at 2 am, off, not turned on in the repo; the script runs recheck-main
  `-All -SkipUnchanged` through run-bounded with a time limit.
- Broken on purpose, each caught: the skip disabled (RecheckMain, 3 fails), a partial green counted (RecheckMain, 1 fail), the paused hook
  removed (KitchenSupervisor, 3 fails), `-SkipUnchanged` dropped from the script (KitchenRecipes, 1 fail).
