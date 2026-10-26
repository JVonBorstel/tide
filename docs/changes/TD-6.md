# TD-6: fair share between Sites in the start order

Floor TD-6 of Site TD (TD Pour 2), from `projects/tide/plans/multi-site-design-2026-10-23.md` section 2.3 and the Floor table,
with the Owner's answer Q4 = A (equal share). Branch `ms-td6-fair-share`, stacked on TD-3 (`ms-td3-order-site`, PR #122) at
`4ceb56b`, built 2026-10-24 MT. Merges after #118, #120 and #122.

## What it does

`Sort-ForStart` (`kitchen/start-order.ps1`) ranks the pending orders the supervisor's start loop walks (`kitchen/kitchen.ps1`,
`foreach ($j in (Sort-ForStart $jobs))`). Before: under way first, then `vars.priority`, then oldest. Now:

1. **Under way first** (an order past its first step), as before.
2. **Then priority** (urgent, normal, low), as before.
3. **Then the fair share (new):** inside one band of equal "under way" and priority, the next place goes to the Site with the
   lowest load. Load = the Site's orders running now, plus the places already handed out in this list (every Site weighs 1:
   equal share). A tie goes to the Site whose next order is oldest. So a Site with nothing running always gets the next place in
   its band, and two Sites with equal queues alternate.
4. **Inside a Site: oldest first**, as before.

- **Site of an order:** `Get-KitchenJobSite` (TD-3: the stored `vars.site`, else its Tower's). Orders with no Site are one group,
  which shares like any Site. A Site lookup that throws counts as no Site; it never stops the start loop.
- **One Site, or none:** the list is exactly the old one (the function returns the old sort before any fair-share step).
- Orders the loop will not start (running, waiting on a yes) follow the startable ones in their old order. The loop skips them
  either way (`if ($j.status -ne 'pending') { continue }`).

## Where priority and holds still win over fairness

- **Priority and under way:** they are sort keys 1 and 2; fairness is only key 3, applied inside a band of equal keys 1 and 2
  (`Sort-ForStart`, the inner `while` that builds `$queues` breaks when `started` or `priority` changes). An urgent order from a
  busy Site starts before a normal order from an idle Site; a half-built order of one Site starts before a new order of another.
- **Holds:** fairness only reorders the list. The start loop in `kitchen/kitchen.ps1` still checks each order in turn and skips a
  held one: the live cap (`$underWay -ge $MaxLive`), `notBefore`, admission (`Test-KitchenAdmit`), the clash rule
  (`Hold-ForClash`, oldest owns the file, decided by age, not list place), and the Stop-work order, budget and RAM guard, which
  stop the loop. A held order never gives its Site a start it could not take; the next order in the list is tried.

Not in this Floor: per-Site `share` weights and `maxHeavy` (TD-7 registry), counting heavy steps only (needs station weights).

## Proof

- `tests/Test-StartOrder.ps1`, 33 checks (14 before, 19 new): one Site and no Site give exactly the old order (300 random mixed
  orders each, compared with the old sort kept in the test); two Sites alternate; the no-Site group shares; a Site with nothing
  running goes first; running orders count; urgent and low still win or wait; under way still wins; each Site keeps its old
  order; every order comes back once; hashtable orders; a throwing Site lookup; 1,000 orders over 3 Sites; with `jobs-lib.ps1`
  loaded; the start loop still checks the holds in turn.
- Broke the code 3 ways, each caught: no fair share (8 checks fail), fairness above priority (3), running orders ignored (2).

## Amended after review #11 (2026-10-26, F3): registry only, priority first (the Owner's choice), heavy-step load

- **Only with a Sites registry.** The review showed tide's own `kitchen.repo.json` `"site": "TD"` turned fair share on with no
  registry at all (pending J10, J11, J12 of a TD Tower and J13 with no Tower started J10 J13 J11 J12 instead of J10 J11 J12 J13).
  Now `Sort-ForStart` shares only when the start loop passes the registry's weights (`Get-KitchenSiteShares`, which gives every
  registered Site one). No registry = no weights = exactly the order from before TD-6, whatever a Tower's own `site` says.
- **Priority first: Jordan's decision, 2026-10-26.** The design draft (section 2.3) put fairness between "under way" and
  priority ("across Sites fairness wins"); this note's first version put it after priority, with no recorded decision. The review
  asked; Jordan chose **priority first**: urgent work always goes next, whatever its Site, and Sites take turns (fair share) only
  among orders of equal priority. That is the order above (under way, priority, then the fair share, then oldest), now a recorded
  decision; the design doc says so too.
- **Load = running heavy steps.** As the design says ("running heavy steps for the Site divided by `share`"): the start loop counts
  each Site's running heavy steps with the scaler's weights (light steps left out, as admission does) and passes them as
  `-HeavyLoad`. Without `-HeavyLoad` (tests, other callers) the load is still the Site's running orders.
- Tests (`tests/Test-StartOrder.ps1`, 53 checks): `NoRegistry_J10_J13` and `NoRegistry_Mixed` (no registry = the old order),
  `Registry_J10_J13`, `PriorityFirst_*` (an urgent GW order goes ahead of TD's waiting turn; equal-priority orders still
  interleave), `PriorityInsideSite`, `Load_*`; the TD-6/TD-7 checks now pass registry weights.
