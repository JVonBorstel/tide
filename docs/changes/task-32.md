# Failure care: every failure gets a reason, a next step and an end

## The map (what existed before this change, read from the code)

Every place the Yard or the Board handled a failure before task 32, and what each one did with it.

| Piece | Where | What it did | What was missing |
|---|---|---|---|
| Retries and back-off | `kitchen/kitchen.ps1` `Fail-Step`, `kitchen/backoff-lib.ps1` | A failed step is retried up to its `retries` with a real wait: 30 s to 30 min for the step's own failures, 5 to 60 min when it waited on CI, the network, GitHub or a rate limit. The split came from regexes hard-coded in `Get-FailureClass`. | One split only (wait or code). No class, no next step, no plain words. |
| Quarantine | `Fail-Step` | After its retries the order is `quarantined` (shown as Failed), with an alert ("quarantined after N attempts ... Look at it when you can"). Also after 200 cook waits (`Check-Running`). | No end: a quarantined order sat in `jobs\` forever (43 on 10-27). |
| Repair rounds and reworks | `stations/repair.ps1`, `Fail-Step` (`reworkTo`) | The repair station gives a cook the failing tests up to 2 rounds; a reviewer's REWORK sends the order back to repair once (`step.rework`). An explicit REWORK after that goes to Jordan (`review.rejected`). | Good as it is; reused unchanged. |
| Hiccups and cook waits | `Check-Running` (exit 11, `.hiccup`, `.wait`) | A cloud hiccup or every cook resting is a wait, not a failure; 5 hiccups on a step count as a failure, 200 waits set the order aside. A pinned cook resting over 2 h switches to the fallback cook. | Reused unchanged: it is the "wait for the window" action. |
| Merge conflict | `Check-Running` (`merge: needs freshen`) | A merge that finds main moved and conflicting goes back to the freshen step, twice at most; the old sign-off is dropped. | Reused unchanged: it is the "freshen" action. |
| Privacy hold | `Check-Running` (exit 10, `.hold`) | The order waits for Jordan's sign-off (`needs-human`), with the whole reason. | Reused unchanged: it is the "ask Jordan" action. |
| Unsafe replay, unverified merge | `Fail-Step` | A crash or timeout of an unsafe step, and a verify cut short after a merge, go to Jordan, never retried quietly. | Reused unchanged. |
| The Stop-work order (breaker) and failRate | `backoff-lib.ps1` `Update-BreakerState`, `kitchen.ps1` `Breaker-State`, `status -Json` `failRate` | Opens when 5 of the last 10 steps failed; stays at least 5 min; one HIGH alert per episode. | Swarm-wide; not per order. Reused unchanged. |
| Diagnose | `kitchen/diagnose.ps1`, chores | A newly quarantined order gets a read-only diagnosis (AI crews on, 3 a day, never one older than 24 h); the Board's Find the fix places one by hand. | Explains, but never ends the order. |
| Doctor | `kitchen.ps1 doctor [-FindOnly]` (hourly from the chores) | Damaged files, backups, prunes, worktrees, and the archive: only `done` and `closed` orders untouched for 3 days move to `jobs\archive\`. `-FindOnly` (and always while paused) changes nothing. | Killed (31), quarantined (43) and closed-without-a-reason (36) orders were never touched. |
| Close and requeue | `kitchen.ps1 close`, `requeue` | Close needs an ending (`-ReplacedBy`, `-Proof`, or `-Why "dropped: ..."`), but the ending lived only in the `job.closed` event. Requeue restarts in place, or (an order over 12 h old) re-cooks it from today's recipe and closes the old one with `replacedBy`. | The ending was not on the order; a re-cook was not marked as a retry. |
| The clash rule | `kitchen/clash.ps1` | An order naming a file a started order names waits (`WAIT: ...`). | Not a failure; unchanged. |
| Duplicates | `kitchen.ps1 add` | None: the same goal could be added again and again (9 re-queued duplicates found 10-27). | |
| Alerts | `kitchen.ps1 Alert`, `alerts.jsonl`, `kitchen/notify.ps1` | Every alert line says whether it reached the phone; the push carries only fixed words ("J12 Failed; the Board has the details"), never a log line. | Unchanged; the alert line now carries the plain sentence. |
| Main status | `kitchen/main-status.ps1`, Board red bar | A red main is a red bar (truth rule, D-1). | Unchanged: red bars stay for broken things. |
| Board: the failed list | `pass-app/public/app.js` `renderPass`, `server.mjs` `jobView`, `stuckOf`, `retryWhyOf`, `clear-aside` | The home's sub line counted every failed or stopped order of any age ("47 failed or stopped"); one "Failed or stopped" section with the raw last history line ("fail: exit 1: ..."), Retry, Find the fix, and "Clear old" (closes orders older than 24 h as dropped). | Counted days-old things; raw stack as the main text; no grouping; no end. |
| Board: the brief and Since you looked | `server.mjs` `briefView`, `sinceView` | Counts `job.quarantined` events since the last look. | Unchanged (events since the last look are new by definition). |

What task 32 builds on top, as one system (one policy table, one lifecycle, the doctor as the one place that ends things):

- `kitchen/failure-policy.json` + its reader `kitchen/failure-policy.ps1` replace the hard-coded regexes in `backoff-lib.ps1 Get-FailureClass` (the back-off split is now a field of each class) and the raw last line on the Board.
- The existing mechanisms above are the actions: freshen is the merge-conflict loop, wait for the window is the hiccup and cook waits, ask Jordan is the hold and sign-off, retry once on fresh main is a requeue from the freshen step (or a re-cook), stop and say why is quarantine with the plain sentence.
- The doctor (already hourly, already the archiver, already `-FindOnly`) is where every not-done order ends.

## What

**The policy table** (`kitchen/failure-policy.json`, read only by `kitchen/failure-policy.ps1`):

- Known failure signatures map to a class and each class to one action:

  | Class | Action | Back-off |
  |---|---|---|
  | flaky timing (a timeout, a hang, a crash) | retry once on fresh main | code |
  | merge conflict | freshen | code |
  | stale base | retry once on fresh main | code |
  | crews resting / usage cap | wait for the window | wait |
  | privacy hold | ask Jordan | code |
  | real test or code failure | stop and say why | code |
  | infrastructure (GitHub, CI, the network) | wait for the window | wait |
  | stopped by hand | ask Jordan | code |

- An unknown failure is "real failure, needs a look": never retried by itself.
- `backoff-lib.ps1 Get-FailureClass` now reads the back-off from the table. Its hard-coded regexes are gone, and its 48 tests pass unchanged.

**Plain words:**

- `Fail-Step` writes `j.failure`: the class, the action, one sentence of what happened and the next step, and the raw detail.
  - Example: "The tests failed at step 4 of 15 (tests); next: it needs a look (See why has the detail), then Retry or Close."
  - The step event, the history line, `job.quarantined` and the alert carry the same sentence.
- `kill` writes one too: "It was stopped by hand ...".
- The doctor gives the words to an order that failed before this change.

**The lifecycle** (`Set-JobCleared`, `Get-CarePlan`): every order that is not done ends in exactly one cleared state. The state, its reason, the time and what it was before go on the order (`j.cleared`) and into `events.jsonl` (`job.cleared`).

- **retried**: `requeue` made it again from today's recipe on fresh main. The new order carries `retryOf`.
- **superseded**: `close -ReplacedBy J12`, `close -Proof <PR or commit>`, or the same goal handed over by another order.
- **duplicate**: the same goal is open as another order (`close -ReplacedBy J12 -Why "duplicate ..."`, or found by the doctor).
- **stale**: killed, failed or closed with no human action for 3 days. When git shows it, the reason names the files its brief named that main changed since.
- **dropped**: `close -Why "dropped: ..."`, or Close on the Board.

Killed, quarantined and closed are working states: the doctor clears them. `doctor -FindOnly` (and the paused doctor) lists what it would clear and changes nothing. `kitchen.ps1 reopen -Id J5` puts a cleared order back as it was, from the archive too.

**The one action, once** (doctor):

- A fresh failure (under 24 h, never an old one) whose class says retry or freshen goes back to its freshen step, which merges fresh main.
- If it has no freshen step behind it and is a recipe order that has not committed yet, it is made again from today's recipe on fresh main.
- A wait class is requeued once after 30 min.
- Never twice, never a retry of a retry, never a real failure.

**Duplicates at the door:**

- `kitchen.ps1 add` refuses a goal that matches an open order and prints `DUPLICATE: J12 is open with the same goal ...` (exit 4). An open order is one in play: queued, building or waiting for Jordan. A failed or stopped order does not block a new attempt; the doctor clears it as a duplicate of the new one.
- It matches on normalized text, on the same files and the same title, or on the same roadmap item (`jobs-lib.ps1 Get-OrderDupKeys`). The keys are kept in `jobs-index.json`, so the check opens no job file.
- `-Force` adds it anyway and notes `forcedOver`. `cook.ps1 -Force` passes it through, and `cook.ps1 -Json` returns `duplicate`.

**The Board** (`pass-app/public/app.js`, `plain.js`, `app.css`, `server.mjs`):

- The home's number is the failures that need Jordan now, in plain words ("5 failures need you"): failed or stopped, not cleared, last 72 h.
- The Failures list is grouped by class, real failures first:
  - each row shows its one sentence (wrapped, never cut) with Retry, Close and See why;
  - See why opens the raw line in the row;
  - Close ends it as dropped, with the reason, through the new `close` action and `kitchen.ps1 close`.
- "Older and cleared" (one tap) lists days-old failures and every cleared order, with its end and the Yard's reason.
- The job sheet leads with the same sentence and keeps the raw line under "The full detail".
- No failure is a red bar: red bars stay for broken things (D-1).

Pictures at 412 x 900 (`docs/changes/task-32/`, a throwaway Board with made-up orders, `node pass-app/test-failures.mjs --shots`): home, Failures list and Older, in dark, and the list in light, before and after, plus See why open.

**Not in this change:**

- Running the doctor for real on the live Yard, so the old killed, quarantined and closed orders get cleared with reasons (item 6). The lead does this after the merge: run `kitchen.ps1 doctor -FindOnly` first, then `kitchen.ps1 doctor -Json`. Its `care` block has the counts by state.
- The Brief and Since you looked still count `job.quarantined` events since the last look, unchanged.

## Why

On 10-27 the Yard had 31 killed, 43 quarantined and 36 closed orders sitting forever, and 9 re-queued duplicates. The Board's home said "47 failed or stopped" about days-old things. D-14 asks for one failure-care system: a reason, a plain next step and an end for every failure, built on the parts the map above shows already exist (one policy, not a second system). D-11 asks for plain words on every screen; D-1 keeps red bars for broken things only.

## Tests

One check per acceptance line, named after it:

- `tests/Test-KitchenCare.ps1` (new), 23 checks:
  - each cleared state written with reason (retried, superseded twice, duplicate twice, stale, dropped, on the order and in events);
  - a 3-day-old quarantined order cleared as stale and reopenable;
  - -FindOnly clears nothing;
  - policy table maps each class and an unknown failure to "needs a look";
  - failure sentences read cleanly: one colon after "next:", and a button name (Retry, Close, See why) keeps its capital;
  - add refuses a duplicate and the force flag works (a failed or stopped twin does not block a new attempt);
  - every failure has a plain sentence (a real failing run, a stopped order, an older order given words by the doctor);
  - plus the one action once (flaky back to freshen; a real failure left alone), and the stale reason naming files main changed (a real git repo).
- `pass-app/test-failures.mjs` (new, run by `tests/Test-PassApp.ps1`), 12 checks:
  - `Home_CountIgnoresClearedAndOld`;
  - `FailuresList_GroupedByClass`, `FailuresList_PlainSentence`, `FailuresList_OneTapActions`;
  - `FailuresList_SeeWhy` (two checks), `FailuresList_Retry`, `FailuresList_Close` (the real `kitchen.ps1` on the throwaway folder);
  - `OlderList_HasCleared`, `RedBars_StayForBroken`, `NoHScroll360`;
  - `SpeedBudget_NotWorse`: no canvas, animation or frame loop added, a few nodes per row. The budget itself is measured by CI's report-only `speed` job on the pull request.
- `pass-app/test-readable.mjs` (task 30): its home-count checks now expect the task 32 words and window.
- `tests/Test-KitchenApi.ps1`: its second cook of the same question now asks another one, and a new check proves the duplicate is refused over the API.
- Run one at a time, bounded (`scripts/run-bounded.ps1`), on this branch:

  | Suite | Result |
  |---|---|
  | `Test-KitchenCare` | 23 passed, 0 failed |
  | `Test-Backoff` | 48 passed, 0 failed |
  | `Test-JobsIndex` | 13 passed, 0 failed |
  | `Test-KitchenApi` | 64 passed, 0 failed |
  | `Test-Kitchen` | 70 passed, 0 failed |
  | `Test-KitchenCooks` | 59 passed, 0 failed |
  | `Test-KitchenFreshen` | 85 passed, 0 failed |
  | `Test-KitchenIdeas` | 49 passed, 0 failed |
  | `Test-KitchenMap` | 16 passed, 0 failed |
  | `Test-KitchenMerge` | 59 passed, 0 failed |
  | `Test-KitchenRecipes` | 87 passed, 0 failed |
  | `Test-KitchenSupervisor` | 245 passed, 0 failed |
  | `Test-PassApp` | 1384 passed, 0 failed |
  | `Test-Standards` | 20 passed, 0 failed |
  | `Test-Work` | 118 passed, 0 failed |

- Two flakes seen while other suites or screen tests ran at the same time on this PC; both were green when run again alone:
  - `test-status-line.mjs` `BrokenBar_NotClearable_ShrinksTo28` (once in 4 runs here, 0 in 2 on main);
  - `Test-KitchenSupervisor` "kill stops the worker" (the 30 s wait for a pid).
- Code-quality ratchet (`scripts/quality/metrics.ps1 -ChangedSince origin/main`): 0 new violations. Five long functions grew, which is a warning only: `Check-Running`, `act` and `handle` in this change; `Read-RepoConfig` and `startLive` were already over on main.
- Speed budget: `SpeedBudget_NotWorse` is checked in the screen test above. CI's `speed` job (report only) measures the budget itself on the pull request.

**L1-L4:**
- Person: every failure on the Board says what happened and what comes next, and only what needs Jordan now is counted.
- Business, MSP, community: none.
