# TD-7: the Sites registry and a per-Site heavy limit

Floor TD-7 of Site TD (TD Pour 2), from `projects/tide/plans/multi-site-design-2026-10-23.md` section 2.2 and the Floor table,
with the Owner's answers Q1 = A (`sites` in `kitchen.json`) and Q4 = A (equal share). Branch `ms-td7-registry`, stacked on TD-6
(`ms-td6-fair-share`, PR #124) at `dd149bc`, built 2026-10-24 MT. Merges after #124 (which merges after #122 and #120).

## What it does

- **The registry:** `kitchen.json` key `sites`, one entry per Site code: `{ "maxHeavy": n, "share": w }`, both optional.
  `Get-KitchenSites` (`kitchen/scaler.ps1`) reads it. The repo template carries an empty `"sites": {}` with a `_sites` note; the
  real entries go in the state-folder copy (`%LOCALAPPDATA%\brain-kitchen\kitchen.json`), whose `sites` replaces the template's.
- **Per-Site `maxHeavy` in admission:** `Get-Admission` (`kitchen/kitchen.ps1`) tags each running step with its order's Site and
  hands the registry to the start loop. `Test-KitchenAdmit` (`kitchen/scaler.ps1`) gets the order's Site and that Site's
  `maxHeavy`: a heavy step waits while its Site already runs that many heavy steps ("Site TD: all 2 of its heavy slots busy").
  The global limit (`maxConcurrent`, the RAM scaler, the free-RAM math) is checked first and still wins. Light steps never count.
- **Per-Site `share` in the start order:** TD-6's `Sort-ForStart` (`kitchen/start-order.ps1`) now ranks a Site by load / share
  instead of load. The start loop passes the registry's weights (`Sort-ForStart $jobs $adm.shares`). Default 1 = equal (Q4 = A).
- **Site of an order:** `Get-KitchenJobSite` (TD-3: stored `vars.site`, else its Tower's `kitchen.repo.json` `site`). Orders with
  no Site have no Site limit and weigh 1.
- **Bad values never stop the Yard and are never silent:** a wrong code, a non-object entry, a `maxHeavy` that is not a whole
  number of 1 or more, or a `share` that is not over 0 is left out (that Site keeps the old rule) and named in
  `supervisor.json` `admission.siteProblems` and in the doctor's notes. The doctor's slots line adds "Sites: GW heavy 2, share 1; ...".

## No `sites` block: exactly as today

`Get-AdmitSite` returns '' without looking anything up when the registry is empty, so `Test-KitchenAdmit` gets no Site and skips
the Site check; `Sort-ForStart` with no weights is the TD-6 order. Proof in the tests below.

**Amended after review #11 (F3):** "the TD-6 order" with no weights turned out to be a change for tide, whose own
`kitchen.repo.json` names Site TD: fair share was on with no registry. Now no weights (no registry, or an empty one) = no fair share
at all, the order from before TD-6. The start loop also passes the running heavy steps per Site
(`Sort-ForStart $jobs $adm.shares $adm.siteLoad`); see `TD-6.md`.

## The block Jordan would add (live kitchen.json, his edit; not done by this PR)

In `%LOCALAPPDATA%\brain-kitchen\kitchen.json`, one new top-level key:

```json
  "sites": {
    "TD": { "maxHeavy": 2, "share": 1 },
    "GW": { "maxHeavy": 2, "share": 1 }
  },
```

- Equal shares (Q4 = A). `maxHeavy` 2 each keeps either Site from taking every heavy slot (global `maxConcurrent` is 4; the RAM
  scaler runs 1-3 heavy steps on this PC's ~2 GB free). Omit `maxHeavy` for no Site limit.
- GW orders count as GW only once Demo Project's `kitchen.repo.json` says `"site": "GW"` (the Owner's step after 2026-10-28 18:00 MT,
  TD-2) or the order carries `vars.site` GW. Until then they are Unassigned: no Site limit, weight 1.
- Check after the edit: `kitchen.ps1 doctor` shows "Sites: GW heavy 2, share 1; TD heavy 2, share 1" and no `kitchen.json sites` note.

Not in this Floor: registry `towers`, `privacy`, `yard`, `closed`, `ciMinutesPerMonth` (TD-9, TD-11, TD-13); Tower lookup through the
registry's `towers` (GW's tag comes from its `kitchen.repo.json`).

## Proof

- `tests/Test-Scaler.ps1`, 59 checks (36 before, 23 new): the registry read (no block, empty block, the repo template, valid,
  defaults, bad values, bad entries, not an object); the Site check (holds at the limit, another Site starts, under the limit,
  light ignored both ways, global cap and RAM still win); **NoSitesBlock_AdmissionUnchanged** (2,000 random passes: no registry
  gives the same answer as the call from before TD-7); in the tick, **NoSitesBlock_TickUnchanged** (6 tagged orders, no block:
  4 start, as before), **SiteMaxHeavy_Tick** (TD maxHeavy 1: 1 TD and 3 GW start), the bad value in `supervisor.json`, and the doctor line.
- `tests/Test-StartOrder.ps1`, 42 checks (33 before, 9 new): no weights, all 1 and an empty table all give the TD-6 order (also on
  900 mixed orders); GW share 2 gets two places per TD place; an unlisted Site and bad weights weigh 1; running load is divided by share.
- Broke the code 3 ways, each caught: the Site check never refusing (2 fails), no registry acting as a per-Site cap of 1
  (NoSitesBlock_AdmissionUnchanged and the tick check), share weights inverted (2 fails).
- Also run: Test-KitchenSupervisor, Test-Standards, Test-Names, Test-Quality, Test-BrainMonitor; `scripts/check-standards.ps1`: 0 new.
