# Rename S7e: the world props become site props, and the legend speaks site words (the Board's scene, slice 5)

## In plain words
Every prop that carries a real number or state is redrawn as a site thing. What each one means, which field it reads and when it is
missing are all unchanged. The legend sheet ("What am I looking at?") uses the new names.

| Prop (what it shows) | Was | Now |
|---|---|---|
| paused / AI crews on | door sign OPEN / CLOSED, stools on the counters | **Gate sign** OPEN, OPEN lit, **PAUSED** in hazard yellow (never CLOSED: "Site closed" is the merge freeze; Jordan's answer 2), and a striped **barrier** with a beacon across two stations |
| walkrounds | sous chef on a stool | **the Dispatcher** in a **white hard hat** with a **clipboard** (on the knee; in hand on the lap), on a folding stool by the gate, one lap per walkround (Jordan's answer 3) |
| stop-work order | fuse box | **Power board**: sparks and a red STOP tag; the work light goes out |
| today's spend | coin jar, padlock | **Budget meter**: 8 segments, green, then amber, then red; a **chain and padlock** when the cap stopped work |
| failed / stopped | plates on a shelf | **The bench** with a parked crate each, dust for the last 2 minutes |
| more queued | rail tag | **Job board tag** in hi-vis |
| sign-off waiting | heat lamps | **Sign-off lights**: beacons, warm, **amber** from 1 h, red from 4 h |
| follow-ups, leads, ideas | cork board, chalkboard, recipe box | **Notice board**, **Whiteboard** (blue marker tally), **Idea box** (slips in a red box) |
| crews resting | hats on hooks | **Hard hats on hooks** (since S7b) |
| the clock | wall clock | **Site clock** (steel rim) |

## What changed
- `pass-app/public/sprites.js`, redrawn in place (same names, sizes and frame counts; the tests read these keys):
  `sign` (3), `chair-up`, `stool`, `chef-sit` (2), `fuse` (2), `coin-jar` (9), `jar-lock`, `heat` (3), `cork`, `chalk`, `tally` (11),
  `chalk-digit` (10), `recipes` (5), `plate-aside`, `tag`, and the `clock` rim.
  - New: glyphs `A`, `H`, `V` (`H` and `V` are for S7f's "HANDED OVER"); the exports `SIGN_WORDS` (OPEN, OPEN, PAUSED) and
    `DISPATCHER` (the white of the Dispatcher's hard hat).
  - `LEGEND_ICONS` entries take an optional crew colour, so the Dispatcher's legend icon is white too. No glyph or export was removed
    (the City view reads them).
- `pass-app/public/scene.js`:
  - the Dispatcher is drawn in white and carries a clipboard on the lap (1 draw, only while walking: busiest floor 71 -> 72 of 120);
  - the legend icons honour the optional colour;
  - one comment.
- `pass-app/public/world.js`: the legend lines (`meaning`) and the header comment only. The fields, the truth rules, the absent cases,
  `worldOf`, `PLACE` and the stored state names (`closed`, `lit`, `open`) are unchanged.
- `pass-app/test-scene.mjs`: 8 checks reworded (CLOSED -> PAUSED, ember -> amber, the sous chef -> the Dispatcher) with the same
  logic; 4 new checks.

## Bytes
| | stage brotli | this slice |
|---|---|---|
| S7d | 31,352 | |
| S7e | 32,157 | +805 (the brief planned +800) |

The ceiling stays at 34,615 (2,458 left).

## L1-L4
- **L1 (person):** the paused Yard no longer says CLOSED (which now means a merge freeze). Every prop says what it is in the
  glossary's words, on the stage and in the legend.
- **L2 (business):** budget, stop-work and sign-off waits read as a site manager would read them.
- **L3 (MSP):** the same fields and truth rules, +1 draw only while the Dispatcher walks, +805 bytes.
- **L4 (community):** original pixel art as code; the legend is the text twin of every prop.

## Tests
- `node pass-app/test-scene.mjs`: 143 checks, 0 failed (139 before). New:
  - GateSign: paused, the sign spells PAUSED pixel by pixel and never CLOSED, and the legend says the same.
  - Dispatcher: a white hard hat seated and on the lap, a clipboard on the knee and in hand, and a white legend icon.
  - SiteProps: the legend speaks site words and no kitchen words; the job board tag line.
  - SiteProps: the budget meter fills green, then amber, then red; the chain and padlock.
- Unchanged and passing: every truth and draw check with the same keys (`sign:2` + `chair-up:0` when paused, `fuse:1` + `lamp-off:0`,
  `stool:0`, `chef-sit`, and the full-world list), the frame counts (sign 3, hands 12, jar 9, heat 3, fuse 2, tally 11, cards 5).
- `node pass-app/test-live.mjs`: 63 checks, 0 failed.
- `tests/Test-PassApp.ps1` (bounded, 1200 s): 1033 passed, 0 failed.

## Seen in a browser
A look-only harness (made-up work orders, never the live Board) at a true 375 px phone width, light and dark, including a state that
is paused, stalled, at its cap and under a stop-work order. The shots are in the private notes and wait for Jordan's yes.
