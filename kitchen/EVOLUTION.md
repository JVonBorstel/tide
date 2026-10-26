# How the Yard evolves (the foundation)

The Yard (code: `kitchen`) changes itself through Improve work orders. This file says how fast it should evolve, how we measure that, and the five
leaps it climbs. `kitchen/scoreboard.ps1` measures; the coach and the research teams propose; the autopilot builds; Jordan merges.

## The rate of evolution
One number, measured every day by the scoreboard (7-day window):

    rate = merged changes per day x first-try pass rate x (1 - failed rate)

Supporting numbers (each must not get worse when the rate goes up):
- **tokens per merged change** (all plans; dollars only as a pay-per-use estimate)
- **minutes per merged change** (order to merge)
- **Jordan's taps per merged change** (approvals and holds he had to answer)
- **repaired rate** (fixed by the repair round) and **runner faults** (crashes, floods, races: target zero)

To grow at the degree we want, we set a target rate and the Yard tunes its own dials to reach it:
parallel builds (`maxConcurrent`), autopilot daily cap (`autopilot.perDay`), and how much it waits for Jordan (`maxWaiting`).
Raise the target only when the supporting numbers hold.

## Rules every evolution step keeps
1. Guardrails never loosen: merges only with Jordan's yes, private data stays on the PC, nothing billed per token, no installs or downloads without his yes.
2. Every pipeline change is an experiment: it names the scoreboard number it should move, and is reverted if that number gets worse.
3. Scripts before tokens: anything a script can decide (parse, lint, map, score, route) is not given to a model.
4. Every failure teaches: repaired failures go to the lesson book (lessons.jsonl), repeated ones become lint rules.
5. Jordan-facing first: when two ideas tie, the one he can use in the Board wins.

## The five leaps
Each leap has exit numbers. The scoreboard reports which leap the Yard is on.

**Leap 1 - A reliable line.** Changes come out right without babysitting.
Exit: first try >= 70%, failed (quarantined or failed; code: `asidePct`) <= 10%, runner faults = 0 for 7 days.
Built: lint (free checks), repair round, lesson book, merge lock (J31), test runner fixes. Pending: cloud hiccups (J33), retry from today's Spec (J35).

**Leap 2 - Measured and lean.** Every token is counted and routed to the right model.
Exit: tokens tracked on every run, tokens per merged change down 30% from the first week, test time per change down 40%.
Orders: tokens everywhere (J42), right model per job (J44), run only the tests a change touches first (fail fast), plan reuse.

**Leap 3 - Visible.** Jordan can watch, replay and understand any order from his phone.
Exit: Live view with Agent Standup's abilities, replay and recap for every order, push alerts working.
Orders: live activity stream (J43), Live view 2 (I57), replay and recap (I58).

**Leap 4 - Useful end to end.** The Yard does real work for Jordan while he rests.
Exit: every morning, ranked openings with tailored resume packs ready to review; follow-ups due shown; nothing submitted without him.
Orders: overnight job-hunt run (scout -> rank -> tailor -> pack), application tracker follow-ups, morning brief with the packs.

**Leap 5 - Self-directed evolution.** The Yard sets its own next experiments and keeps only the winners.
Exit: the coach files experiments with a target number, results are judged automatically after N builds, losers revert,
and the rate of evolution rises week over week with the supporting numbers holding. Auto-merge of small safe changes with an
Undo stays Jordan's decision.
