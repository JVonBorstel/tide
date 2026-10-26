# Polish S7h: open stations and a poured slab (the live floor stops reading as a kitchen line)

## In plain words
After rename S7 the crews wear hard hats, but on Jordan's phone the stations still looked like a kitchen: cabinet fronts, an oven-like
recess with a red block, an oven display with orange LEDs, and a floor with a tile seam every 16 px. This slice redraws the stations
and the floor in place (board concept 2026-10-26, section 5, items 1-4):
- **Survey table and Inspection desk:** a **trestle table**, a plank top on two A-frame trestles, open underneath (was a steel drawer cabinet).
- **Workbench:** a heavy top on **steel legs** with a lower shelf and a **yellow toolbox** (handle and latch) on it, open air around it
  (was a dark recess with a red block). The weld flash stays blue-white; the sparks are **white and yellow only** (no orange).
- **Test rig:** an **open test rack**: a scope screen with a green trace, an LED strip, a cable coil on the bottom shelf. The busy LEDs
  that chase along the strip are **green** (they were orange "+" marks, which read as a hob or an oven display).
- **Handover bay:** a **crate on a pallet** standing on the slab (new sprite `pallet`), no table.
- **The floor:** a **poured slab**: one colour, a few specks and a hairline crack, **no seams** (every tile had a right and bottom seam).

The meaning is unchanged: the same stations host the same Steps, the same crews walk to them, the busy effects cost the same draws,
and every truth rule and sprite key stays. The room around them (wall, window, door, shelf, sign-off window) is S7i.

## What changed
- `pass-app/public/sprites.js`: `counter`, `stove`, `sink` redrawn in place (same 28x20); new `pallet` (28x20); `floor-a`, `floor-b`
  (same 16x16); the `flame` and `bubble` particles recoloured (same sizes and frames). Comments.
- `pass-app/public/scene.js`: `STATION_ART.plate` is `pallet` (was `counter`); one comment.
- `pass-app/SCENE.md`: the stations and the slab described as drawn.
- `pass-app/test-scene.mjs`: the SiteStations food check allows green only on the Test rig (its trace and LEDs) and covers `pallet`;
  6 new checks.

## Bytes (the stage files, brotli, as git stores them: LF)
| | stage | this slice |
|---|---|---|
| S7g (#22 head, with the two-word fix) | 32,263 | |
| S7h | 32,586 | +323 |

The ceiling stays at 34,615 (2,029 left). The concept's plan for S7h-S7j together is about +200: S7i cuts the paint tins, pegboards,
shelf and window frame (about -250). The world (City G6 15,749 + stage 32,586 = 48,335) stays under the shared 50,615.
On this Windows PC the test prints the bytes of the files as checked out (CRLF): 32,376 -> 32,626.

## L1-L4
- **L1 (person):** Jordan's floor reads as a building site at a glance: open tables, a workbench with a toolbox, a test rack, a pallet,
  a concrete slab. No cabinet, oven or tiled floor.
- **L2 (business):** the polish lands under the same sprite keys, so the open S7 chain (#14-#22) does not move.
- **L3 (MSP):** +323 bytes; no new state, requests or per-frame draws (busy floor still 73 of 120; the stations are in the baked layer).
- **L4 (community):** the public repo's scene spec says what is drawn.

## Tests
- `node pass-app/test-scene.mjs`: 154 checks, 0 failed (148 before). New:
  - SiteOpenStations: the trestle tables are at most 25 % filled under the top (16 %), the Workbench at most 50 % (45 %), the Test rig
    open between its panel and shelf; the old cabinets were 100 %.
  - SiteWorkbench (2): no red in the Workbench; a yellow toolbox with a handle and a latch on the lower shelf. The weld sparks are
    white and yellow only; the weld flash stays blue-white.
  - SiteTestRig: green LEDs and a green scope trace; each chasing LED lands on the dark LED strip.
  - SiteHandoverBay: the floor bakes 2 trestle tables and 1 pallet.
  - SiteSlab: both floor tiles one colour with a few specks, no seam row or column.
  Against S7g's sprites these checks fail (the `pallet` sprite does not exist there and the cabinets are 100 % filled).
- `node pass-app/test-live.mjs`: 63 checks, 0 failed.
- `tests/Test-PassApp.ps1` (bounded, 1200 s): see the PR.

## Seen in a browser
A look-only harness (made-up work orders, never the live Board) at 375 and 411 px, light and dark, before and after. The shots are in
the private notes and wait for Jordan's yes. Not seen on Jordan's phone yet.
