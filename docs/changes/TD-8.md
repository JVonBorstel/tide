# TD-8: Stop work and pause per Site

Floor TD-8 of Site TD (TD Pour 2), from `projects/tide/plans/multi-site-design-2026-10-23.md` section 5 and the Floor table.
Built in the private repo (PR #128), merged into the multi-site stack and ported to tide in #11 (`docs/changes/port-132.md`).
This note was written after the port, from the code and tests on the #11 branch (review #11 F8: the port carried no TD-8 note).

## What it does

Only with a Sites registry (kitchen.json `sites`). With none, the one Yard-wide Stop-work order works exactly as before and there
are no Site pauses. Machine-level stops (the global `PAUSED`, the RAM guard, the daily budget) stay global and still win.

- **Pause one Site:** `kitchen.ps1 pause -Site GW` writes `<kitchen>\PAUSED-GW` (the operator's file: delete it, or
  `kitchen.ps1 resume -Site GW`, to lift it). None of that Site's new work starts; its running work, the watchers and the other
  Sites carry on. The code must be 2-3 capitals and in the registry, so a typo never stops nothing quietly. A `PAUSED-<code>` file
  for a code not in the registry is not read. Logged as `site.paused` / `site.resumed`.
- **A Stop-work order per Site** (`Step-SiteBreakers` in `kitchen/kitchen.ps1`): step outcomes are bucketed by their order's Site,
  with the same hysteresis as the Yard-wide one (TD-EH-07), so one Site's failures never stop another. State:
  `supervisor.json` `siteBreakers.<code>`. Orders with no Site have their own order under the key `?` (Unassigned).
- **Status:** `kitchen.ps1 status` lists each Site stopped by the Owner or under its own Stop-work order (`status -Json`:
  `siteStops`).
- **The Board** (`pass-app/public/site-stop.js`): a calm banner with Resume for a Site the Owner stopped, an alarm banner for a
  Site whose Stop-work order is open, and Stop / Resume rows per Site in the settings sheet (`site-pause` / `site-resume` actions,
  code checked against the registry before `kitchen.ps1` runs).
- Since review #11 (F4): the Unassigned (`?`) Stop-work order is shown too, as a banner only ("Stop-work order on work with no
  Site"); there is no Stop or Resume tap for it.

## Proof

- `tests/Test-KitchenSupervisor.ps1` (14 TD-8 checks: pause -Site, refusal of an unlisted code, running work finishes, the other
  Site starts, the global pause wins, per-Site Stop-work isolation, the alert, status lines), `tests/Test-PassApp.ps1` (7 TD-8
  checks plus the review #11 `SiteStop_Unassigned_*` checks).

## Not covered yet (review #11 F7)

- A registry added while the Yard-wide Stop-work order is open: `Step-SiteBreakers` clears `breakerTripped` with no "lifted" note.

## L1-L4

- Person (the Owner): one bad Site no longer stops the whole Yard; he can stop one Site from the phone.
- Business: work for one client keeps moving while another's is held.
- MSP: per-client stop and pause, the basic control for running several clients' work on one machine.
- Community: none.
