# Rename S7g: the chrome and the words around the scene (the Board's scene, building site slice 7, the last)

## In plain words
This last slice finishes the building site:
- **Loading:** a crew member hammering at the vice, with dust rising. This already followed from S7b and S7c; the comment now says so.
- **Offline:** a crew member asleep on a crate by the site lantern.
- **Empty Board:** a crew member leaning on a shovel by an empty pallet (it was a chef by an empty cloche).
- **Words:** the empty Board says **"Nothing building."** (it said "Nothing on the stove."). The listen button on a work order says
  **"Listen to this work order"** (it said "ticket").
- **Comments and docs:** the comments in the five stage files, `pass-app/SCENE.md` and the scene parts of `pass-app/DESIGN.md` use
  site words. Code names that stay (`chef-*`, `stove`, `sous` ...) are named as code names.

After this slice, nothing a person reads or hears from the scene is a kitchen word. A new test checks this across every legend line,
both stage summaries, every tap label, the still card, the sign and banner words and the station names.

## What changed
- `pass-app/public/sprites.js`: the `empty` chrome sprite (32x32, 2 frames, the same size). Comments.
- `pass-app/public/scene.js`, `moments.js`, `frame.js`: comments only.
- `pass-app/public/app.js:381`: "Nothing on the stove." -> "Nothing building." (one string). This is outside ART's own files; it
  is the one line the brief names. Team CITY-BUILD's hooks in app.js are elsewhere.
- `pass-app/public/index.html:98`: the listen button's `aria-label`, one string (outside ART's files; the brief names this line).
- `pass-app/public/app.css`: one comment in the pixel skin.
- `tests/Test-PassApp.ps1`: one check name ("show their chefs" -> "show their crew (site art)"), with the same logic.
- `pass-app/SCENE.md`: the top half is rewritten for the site, with the station table in site names and the code names beside them.
  The world and moments tables use site words.
- `pass-app/DESIGN.md`: the scene lines.
- `pass-app/test-scene.mjs`: 2 new checks.

## Bytes
| | stage brotli | this slice |
|---|---|---|
| S7f | 32,327 | |
| S7g | 32,376 | +49 |

**S7 in total:**
- S7a freed 4,640 bytes (34,577 -> 29,937).
- S7b-S7g spent 2,439 of them (to 32,376).
- The ceiling stays at 34,615 (2,239 left).

## L1-L4
- **L1 (person):** Jordan's phone no longer shows a kitchen anywhere on the Board: no chefs, toques, stoves, ticket rail, cloches
  or CLOSED sign. The empty Board says "Nothing building."
- **L2 (business):** the Board, the glossary and every report use one language.
- **L3 (MSP):** +49 bytes; no new state, requests or draws.
- **L4 (community):** the public repo's docs describe the scene the way it now looks.

## Tests
- `node pass-app/test-scene.mjs`: 148 checks, 0 failed (146 before). New:
  - SiteWords: no toque, cloche, chef, ORDER UP or other kitchen word in what the scene shows or says (124 strings: the legend, the
    summaries, the tap labels, the still card, the sign and banner words, the station names). The empty Board says "Nothing
    building." and the listen button says "work order". A run against the old kitchen legend catches 7 of its 12 lines.
  - SiteChrome: loading, offline and empty are 32x32 site art (4, 2 and 2 frames), and the empty one holds no cloche.
- Unchanged and passing: the chrome checks (icons, palette, contrast 4.5:1, dark outlines 3:1).
- `node pass-app/test-live.mjs`: 63 checks, 0 failed.
- `tests/Test-PassApp.ps1` (bounded, 1200 s): 1038 passed, 0 failed.

## Seen in a browser
A look-only harness (made-up work orders, never the live Board) at a true 375 px phone width, light and dark, with the chrome sprites
shown at 2x. The shots are in the private notes and wait for Jordan's yes. After merge, the brief's final proof is Jordan's own phone:
the 1-second glance test (quiet, busy, needs you, broken) and a cold open with no kitchen flash.
