# Rename S7d: the site around the crew (the Board's scene, building site slice 4)

## In plain words
The room on the Board's stage is no longer a kitchen:
- **Walls:** blockwork above, plywood hoarding below (no white kitchen tile).
- **Floor:** a concrete slab with saw-cut joints and a hairline crack (no stone checker floor).
- **Shelf:** paint tins in red, blue and green instead of spice jars, and tools on pegboards instead of hanging frying pans.
- **Job board:** the ticket rail is a hazard-taped bar, and each work order is a **work-order card**: paper on a clipboard with the
  same two digits and the same step bar.
- **Sign-off window:** the pass is a site-cabin hatch with hazard tape over it. The runners carry **clipboards** to it (no cloches),
  and up to 3 clipboards wait on its ledge.
- **Work light:** a caged work light hangs over the window. A stop-work order still puts it out.

The window, sky, door and bell stay as they were. Not in this slice: the world props and the legend (S7e), moments (S7f) and the
chrome (S7g).

## What changed
- `pass-app/public/sprites.js`, redrawn in place (same names, sizes and frame counts):
  - `wall`, `subway` (the hoarding), `floor-a`, `floor-b`;
  - `jar` (paint tins, 3 frames), `pan` (pegboard tools);
  - `rail` (the job board), `ticket` (the card);
  - `pass` (the sign-off window), `cloche` (the clipboard), `lamp` and `lamp-off` (the work light).
  - Two small helpers, `hazard` and `workLight`. The kitchen `PAN` and `CLOCHE` pixel lists are gone.
- `pass-app/test-scene.mjs`: 4 new checks.
- `scene.js` is unchanged: every prop keeps its size and place, so the bubbles still avoid the props and the draws do not move.

## Bytes
| | stage brotli | this slice |
|---|---|---|
| S7c | 30,842 | |
| S7d | 31,352 | +510 (the brief planned +800) |

The ceiling stays at 34,615 (3,263 left).

## L1-L4
- **L1 (person):** the whole room reads as a site on the phone, and the work-order numbers on the job board still read at 15.6:1.
- **L2 (business):** one vocabulary everywhere: job board, work-order card, sign-off window.
- **L3 (MSP):** the same draws (busy floor 73, busiest 71 of 120) and the same prop rectangles; +510 bytes.
- **L4 (community):** original pixel art as code.

## Tests
- `node pass-app/test-scene.mjs`: 139 checks, 0 failed (135 before). New:
  - SiteRoom: a concrete slab, not a checker floor; plywood hoarding, not white tile; blockwork above.
  - SiteRoom: the runners carry clipboards (paper on a board, no steel dome), tools hang on pegboards, a caged work light that the
    stop-work order puts out.
  - SiteRoom: the card's digits and step bar land on paper and read (digits 15.6:1, bar 5.0:1); the card is still 11x13.
  - SiteRoom: the job board and the sign-off window wear hazard tape.
- Unchanged and passing: BubblesOffProps (the same prop sizes), the busy and busiest draw caps, the truth rules.
- `node pass-app/test-live.mjs`: 63 checks, 0 failed.
- `tests/Test-PassApp.ps1` (bounded, 1200 s): 1029 passed, 0 failed.

## Seen in a browser
A look-only harness (made-up work orders, never the live Board) at a true 375 px phone width, light and dark. The shots are in the
private notes and wait for Jordan's yes.
