# Rename S7b: the crew wear hard hats and hi-vis (the Board's scene, building site slice 2)

## In plain words
The people on the Board's stage are no longer chefs. Each crew member wears a **hard hat in its crew's own colour** (Claude orange,
Gemini blue, Claude via Google purple, Home crew green, Yard hands grey; Jordan's answer 4), a blue work shirt, a **hi-vis vest**
with a reflective stripe and a tool belt. The vest's chest badge is the crew colour too. The **runners** at the sign-off window
(the old waiters) wear a hi-vis yellow hard hat and vest over a grey shirt: they carry sign-offs for every crew. The crew member
asleep on the crate when nothing is building has the hard hat tipped over the eyes. The hats on the hooks are hard hats in the
crew colour. The Live tab's desks show the same people by themselves (they draw the same sprites).

Not in this slice: stations, room, world props, moments and the chrome sprites (S7c-S7g). The Dispatcher's white hard hat and
clipboard come with the world props (S7e); until then the Dispatcher wears the "picking a crew" gold.

## What changed
- `pass-app/public/sprites.js`:
  - `HEAD` (down, up, side, asleep, runner down and side) and `TORSO` (down, up, side, runner down and side) redrawn in place. The
    sprite names, sizes (16x24) and frame counts are unchanged (walk 4, idle 2), and so are `body()`, the moustache spot and the bob.
  - `hat` (6x7) redrawn as a hard hat.
  - 3 new palette keys `G H J` (hi-vis yellow). They are not light sources (`EMISSIVE`), so the vests dim at night and when the
    Yard is paused (the brief's open point 4, decided this way).
  - Comments: the crew-colour slot is "hard hat, vest badge"; the header says the still card stays if sprites cannot load.
- `pass-app/test-scene.mjs`: 5 new checks (below); one check renamed (apron -> hard-hat colour).

## Bytes
| | stage brotli | ceiling | this slice |
|---|---|---|---|
| after S7a (main) | 29,937 | 34,615 | |
| S7b | 30,180 | 34,615 | +243 (brief's plan: +300) |

## L1-L4
- **L1 (person):** Jordan's phone shows a crew in hard hats instead of chefs in toques; each crew still reads by its colour at a glance.
- **L2 (business):** the Board now speaks the same building-site language as every other screen, so nothing needs translating.
- **L3 (MSP):** no new state, no new requests, +243 bytes; the draw counts did not move (busy floor 73, busiest 71 of 120).
- **L4 (community):** original pixel art, written as code in the public repo.

## Tests
- `node pass-app/test-scene.mjs`: 133 checks, 0 failed (128 before). New:
  - CrewHardHat: every crew head (walk down, up, side, idle, seated, asleep, crouch, squash) carries the crew colour in its top rows
    and no white toque.
  - CrewHardHat: the hat on the hook is a hard hat in the crew colour.
  - CrewHiVis: crew members and runners wear a hi-vis vest with a reflective stripe (no chef coat, no bow tie).
  - CrewHiVis: the vest yellow is not a light source, so it dims at night and when paused.
  - CrewHiVis: runners wear a hi-vis hard hat, not a crew colour.
- Unchanged and passing: atlas (89 sprites, 512x98), every palette index defined, every swap (6 skins x 6 crews x 4 skies), frames,
  draws, reduced motion, truth rules, bubbles off props.
- `node pass-app/test-live.mjs`: 63 checks, 0 failed.
- `tests/Test-PassApp.ps1` (bounded, 1200 s): 1023 passed, 0 failed.

## Seen in a browser
A look-only harness (made-up work orders, never the live Board) at a true 375 px phone width, light and dark. The shots are in the
private notes and wait for Jordan's yes.
