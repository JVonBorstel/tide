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
