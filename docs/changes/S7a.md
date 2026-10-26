# Rename S7a: the Board's scene makes room: the SVG kitchen becomes a still card

## In plain words
The Board's pixel scene is still a kitchen. Rename S7 redraws it as a building site, slice by slice. The stage had only 38 bytes
left in its size budget, so this first slice makes room without raising the cap (Jordan's answer 1, 2026-10-26).

The old backup drawing, an animated SVG kitchen with chefs, a stove and a "PASS" sign, is gone. It showed only while the pixel art
was loading, or for good when it could not load, and it could flash a kitchen for a moment when the app opened. In its place is a
**still card**. It has no people and no motion, and it keeps every link the stage has:
- **Crew**: one link per crew member, with its work order, its station (Survey table, Workbench, Inspection desk, Test rig,
  Handover bay) and what it is doing.
- **Job board**: one work-order card per queued or running work order, with its step (3/9) or "next up".
- **Sign-off window**: one link per work order waiting for your sign-off, and "+N" beyond 3.
- **Handed over**: work orders handed over in the last 3 minutes.
- "Nothing building." when no crew is at work.

The pixel stage itself is unchanged in this slice; S7b to S7g redraw it.

## What changed
- `pass-app/public/scene.js`: the SVG actors, room, `mountScene` SVG path and its walking code (about 220 lines) are replaced by
  `cardHtml` (about 15 lines). `sceneHtml(s, events, opts, now)` returns the card (it takes an optional `now`, so tests can fix the
  time). `mountScene` shows the card until sprites.js loads and rebuilds it only when its words change. `STATIONS` labels are the
  site names (the `word` field, used only by the SVG fixtures, is gone). `ANIMATED` (the SVG's animated classes) is gone. The header
  comment says what the fallback is now. `layoutScene`, the pixel stage and every export the rest of the app uses are unchanged.
- `pass-app/public/app.css`: the SVG kitchen styles and its 18 keyframes (lines 509-594) are replaced by 9 lines for the card. It uses
  tokens only, so light and dark both work, and every link is at least 44 px tall.
- `pass-app/test-scene.mjs`: the SVG checks are rewritten for the card (see Tests). The budget line now prints the exact brotli bytes.
- `tests/Test-PassApp.ps1`: 4 checks follow the card: the header comment, "the still card never moves" (no animation, transition or
  keyframes in its CSS), "the kitchen SVG and its styles are gone", and the lazy-load line (`el._card = null`).
- `pass-app/SCENE.md`: the rules, `mountScene`, the fallback and the budget lines.

## Bytes (the stage budget, brotli, as test-scene.mjs measures it on this PC's checkout)
| | scene.js | stage total | ceiling | left |
|---|---|---|---|---|
| main before (S6b) | 16,367 | 34,577 | 34,615 | 38 |
| S7a | 11,727 | 29,937 | 34,615 | 4,678 |

S7a frees 4,640 bytes. The ceiling stays at 34,615. Each later S7 slice states what it spends.

## L1-L4
- **L1 (person):** Jordan no longer sees a kitchen flash on a cold open. A phone without the pixel art still gets every work order, crew
  and sign-off as a tappable link in site words.
- **L2 (business):** none directly. This is room in the budget for the site redraw Jordan asked for.
- **L3 (MSP):** a smaller, simpler fallback: about 4.6 KB less to send, and no animation to run on a slow phone.
- **L4 (community):** the public repo's Board shows the screen-reader-first fallback pattern: the same links as the art, no motion.

## Tests
- `node pass-app/test-scene.mjs`: 128 checks, 0 failed (127 before; the 6 SVG checks became 7 card checks).
  New: StillCardLinks, StillCardSite, StillCardStill (markup), StillCardStill (CSS, 44 px), the 25 KB markup budget, StillCardPrivate,
  and "Nothing building." in the idle check.
- `tests/Test-PassApp.ps1` through `scripts/run-bounded.ps1 -TimeoutSeconds 1200`: 1018 passed, 0 failed.

## Seen in a browser
A look-only harness (made-up work orders, no keys, never the live Board) at a true 375 px phone width, light and dark: the card wraps
inside 375 px and the pixel stage is unchanged. The shots are kept in the private notes.
