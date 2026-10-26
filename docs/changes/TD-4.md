# TD-4: the Board shows each order's Site

Floor TD-4 of Site TD (TD Pour 1), from `projects/tide/plans/multi-site-design-2026-10-23.md` section 3 and the Floor table.
Built in the private repo (PR #123), merged into the multi-site stack and ported to tide in #11 (`docs/changes/port-132.md`).
This note was written after the port, from the code and tests on the #11 branch (review #11 F8: the port carried no TD-4 note).

## What it does

- **Live stream:** `pass-app/server.mjs` `jobView` adds `site` (a Site code, from `Get-KitchenJobSite`'s rule: the order's own
  `vars.site`, else its Tower's `kitchen.repo.json` `site`) and `floor` (a Blueprint item id). Codes and ids only, never words. No
  Site = no key, so an order with no Site looks exactly as before.
- **The Board** (`pass-app/public/sites.js`, pure, wired in `app.js`): a Site chip after the ticket of every order that has a known
  Site code (no chip for an order with no Site), the Floor next to the ticket ("WO-0294 · GW-53"), a Site filter (`All` plus each
  Site with orders on the board; a remembered choice whose Site has no orders falls back to All, so it never hides the board), and
  one count line ("GW 3 building, 1 needs sign-off · TD 2 queued"). With no order carrying a Site, none of it is drawn.
- `sw.js` caches `sites.js` for offline.

## Proof

- `tests/Test-PassApp.ps1`: 9 TD-4 checks (the `site` / `floor` keys, no key without a Site, the chip, filter and count line, the
  wiring and the offline cache), plus `pass-app/test-sites.mjs` (31 checks of the pure helpers, run by Test-PassApp).

## L1-L4

- Person (the Owner): sees at a glance which Site each order belongs to on the phone, and can look at one Site at a time.
- Business: none directly; it is the view every later per-Site control (stop, pause, CI) builds on.
- MSP: one Board for several clients' work, each order tagged with its Site.
- Community: none.
