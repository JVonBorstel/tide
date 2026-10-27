# Rename S7f: the moments become site moments (the Board's scene, building site slice 6)

## In plain words
The short moments that play on real Yard events are site moments now. Which event plays which moment, the 2-minute freshness rule,
the 2-at-once cap and the announce lines are all unchanged.

| Event | Was | Now |
|---|---|---|
| a step done | a pan flip and a flame | **a brick laid**: a brick rises and lands on a small stack on the station top, with a spark |
| a step sent back or failed | a grey puff and an oven mitt | a **dust puff** and a head scratch in a **work glove** |
| a work order handed over | "ORDER UP!" and confetti | **"HANDED OVER"** (the status word) and confetti |
| tests pass, a sign-off asked, failed or stopped | the sink sparkle, the bell, the plate to the shelf | the check over the Test rig, the bell at the sign-off window, the crate to the bench (follow from S7c-S7e) |

A tapped crew member waves in the work glove too.

## What changed
- `pass-app/public/sprites.js`, redrawn in place: `pan-flip` (the brick; 12x12, 4 frames) and `mitt` (the glove; 5x4).
  - `banner` now says "HANDED OVER" and is **51 px wide (was 41)**, as the brief planned, because the 11 letters need the room. It is
    still 1 frame, and the atlas stays 512x98.
  - New export `BANNER_WORDS`.
  - The spark (`flame`) and the dust (`puff`) were already site art from S7c.
- `pass-app/public/moments.js`:
  - the brick lands on the station top instead of flying over the head;
  - the banner stands at x 125 so it stays centred at its new width;
  - comments use site words.
  - The event map, timings and caps are unchanged.
- `pass-app/test-scene.mjs`: 3 new checks.

## Bytes
| | stage brotli | this slice |
|---|---|---|
| S7e | 32,157 | |
| S7f | 32,327 | +170 (the brief planned +300) |

The ceiling stays at 34,615 (2,288 left).

## L1-L4
- **L1 (person):** a finished work order says "HANDED OVER", the same words as its status everywhere else.
- **L2 (business):** one status vocabulary on every screen.
- **L3 (MSP):** the same draw counts per moment (flip 2, sparkle 4, puff 2, aside 3, bell 0, handed over 17; cap 20); +170 bytes.
- **L4 (community):** original pixel art as code.

## Tests
- `node pass-app/test-scene.mjs`: 146 checks, 0 failed (143 before). New:
  - SiteMoments: a finished step lays a brick: it rises and lands on a small stack (4 frames), with no pan and no food.
  - SiteMoments: the HANDED OVER banner is spelled pixel by pixel, sits inside the stage, and "ORDER" is gone from sprites.js.
  - SiteMoments: the head scratch and the wave wear a work glove (no bare skin).
- Unchanged and passing: MomentOnce, MomentFresh, MomentCap, MomentHidden, MomentReal, MomentTests, MomentPool, MomentDraws (at most
  20), MomentStill, MomentAnnounce, JuiceTweens, JuiceApprove, TapWave, and the moment frame counts.
- `node pass-app/test-live.mjs`: 63 checks, 0 failed.
- `tests/Test-PassApp.ps1` (bounded, 1200 s): 1036 passed, 0 failed.

## Seen in a browser
A look-only harness (made-up work orders, never the live Board) at a true 375 px phone width, light and dark. A moments section plays
a handed-over work order, a step sent back and a step done. The shots are in the private notes and wait for Jordan's yes.
