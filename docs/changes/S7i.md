# Polish S7i: the live floor is the tower's top floor, open to the sky

## In plain words
Jordan chose the look on 2026-10-26: the live floor is the **top floor of the tower**, open to the real sky, and nothing on it may
read as a kitchen. S7h redrew the stations and the slab; this slice redraws the room around them (board concept 2026-10-26,
section 5, items 5-9 and 11):
- **Sky, not a brick wall:** the whole back is the sky of the real hour (the same sky slots the window had, so dawn, day, dusk and
  night follow the clock, with the sun, the moon and stars). A steel shore stands every 16 px. The window frame is gone.
- **The open edge:** a yellow guard rail (top and mid rail) on its posts, debris netting, and a toe board a shade lighter than the
  slab, so it reads as further away. This replaces the plywood band, which read as a tiled backsplash.
- **The hoist cage** replaces the wooden house door. Crews step onto the floor from it, and the City's hoist rides up to here.
  Its mesh gate stands open, with the call lamp lit, **only while a crew is arriving** (a work order's Step started). It is still
  under reduced motion, where nobody walks.
- **The site cabin** replaces the serving hatch: corrugated steel under hazard tape and a framed window of dark glass. The window
  glows **amber only while a sign-off waits**, and is dark otherwise. The clipboards sit on its ledge.
- **Cut (no data behind them):** the paint tins, the pegboards with tools, and their shelf.
- **Depth:** a contact shadow under each station, a darker strip along the slab's front edge, and, at night, a warm pool of light
  on the slab under the cabin's work light. There is no pool when a stop-work order puts the light out.

The truth rules are unchanged: every World prop, the legend, the sprite keys the tests read (`wall`, `subway`, `door`, `pass`,
`pass-glow`) and the per-frame draws (busy floor 73 of 120; the room is baked once per sky). The only per-frame addition is the
open hoist gate, one draw while a crew arrives.
The Yard-wide signs (gate sign, clock, budget meter, power board, notice board, whiteboard, idea box) still hang over the sky in
this slice. S7j adds the floor-only option, which moves them to the City gate and the Office, once SHELL-1 and G4 are on main.

## What changed
- `pass-app/public/sprites.js`:
  - `wall` is the sky with a shore (now 16x40).
  - `subway` is the guard rail band (16x16).
  - `door` is the hoist cage (18x30); new `hoist-open` (18x30).
  - `pass` is the site cabin (40x34) and `pass-glow` is amber (32x20).
  - New `pool` (40x8) and `edge` (16x3).
  - `window`, `jar` (`JAR`, `FRAMES.jars`), `shelf` and `pan` are removed.
- `pass-app/public/scene.js`: the back layer draws the sky, the rail band, the slab, its edge, the hoist and the night pool, and no
  longer draws the window, tins, pegboards or shelf. The front layer draws the contact shadows. The stage opens the hoist gate
  while a crew arrives.
- `pass-app/SCENE.md`: the site paragraph and the byte line.
- `pass-app/test-scene.mjs`: the SiteRoom checks no longer look for brick, plywood or pegboards; 6 new checks.

## Bytes (the stage files, brotli, as git stores them: LF)
| | stage | this slice |
|---|---|---|
| S7h | 32,586 | |
| S7i | 32,988 | +402 |

- The ceiling stays 34,615 (1,627 left). On this Windows PC the test prints the checked-out (CRLF) bytes: 32,626 -> 33,028.
- World (City G6 15,749 + stage 32,988) = 48,737 of the shared 50,615.
- The concept planned about +200 for S7h-S7j together; S7h + S7i are +725. The cut freed less than the new cabin, hoist and depth
  art cost. G6b's move of the City comments (about -2,000) is still the room the world plan counts on for G8 and G9.

## L1-L4
- **L1 (person):** the floor Jordan zooms into is the tower's top floor under his own sky. The cabin window lights up only when he
  is needed, and a crew is seen arriving by the hoist.
- **L2 (business):** the polish lands under the same keys and truth rules, so the S7 chain stays reviewable as one stack.
- **L3 (MSP):** +402 bytes; no new state or requests. Per-frame draws are unchanged except one while a crew arrives.
- **L4 (community):** the scene spec in the public repo says what is drawn and why each thing is there.

## Tests
- `node pass-app/test-scene.mjs`: 160 checks, 0 failed (154 before). New:
  - SiteOpenSky: the back is only the hour's sky slots and steel shores, 40 rows. It changes with the hour and stays lit at night.
  - SiteGuardRail: a top rail and a mid rail in yellow, netting, sky behind, and a toe board lighter than the slab.
  - SiteHoist: a steel mesh cage with hazard bands and no wood. A stage with a crew arriving draws `hoist-open`; a still one does not.
  - SiteCut: `jar`, `pan`, `shelf` and `window` are no longer sprites, and the bake draws none of them.
  - SiteCabin: corrugated steel and dark glass (no cream lamp light). The amber glow is drawn only with a sign-off waiting.
  - SiteDepth: 2 contact shadows per station and the front-edge strip. The night pool is drawn at night with the light on, and not
    by day or when the light is out.
- `node pass-app/test-live.mjs`: 63 checks, 0 failed.
- `tests/Test-PassApp.ps1` (bounded, 1200 s): 1050 passed, 0 failed (1044 before: the 6 new scene checks).

## Seen in a browser
A look-only harness (made-up work orders, never the live Board) at 375 and 411 px, light and dark, by day and at night (the time
zone emulated), before and after. The shots are in the private notes and wait for Jordan's yes. Not seen on Jordan's phone yet.

## Art fix: the critic's 7 MUST items (2026-10-26, audits/art-critique-S7-2026-10-26.md)
Jordan's order: "change the art first then go". Five commits on this PR:
1. **Nothing floats** (MUST #1): a hazard-striped gantry beam spans the top of the sky. The gate sign and the budget meter hang
   by two chains each, and the power board hangs right under the beam. Positions are unchanged. The caged work light is drawn only
   when its field (`breaker`) exists.
2. **Words match the stations** (MUST #2): the Inspection desk says "inspecting" and the Test rig says "testing" (all lower case).
   A bubble stands at most one bubble height over its crew's head, or on the floor in front of its station.
3. **The Purpose Ledger is machine-checked** (MUST #3, new `pass-app/public/purpose.js`): one row per thing the stage draws, with
   its sprites, its state fields, its endpoint, its events, what changes it, what shows when it is absent, and its door. Ground
   (no field) is capped at 19 sprite names. The legend sheet is generated from it. Tests: PurposeNoUndeclared, PurposeBound,
   MomentsBound, PurposeDoors, PurposeFlips (9 flips), PurposeLegend.
4. **Every data mark is a door** (MUST #4): the cabin window and each sign-off light open their work order. The other data marks
   (14 on a full floor) open the legend sheet scrolled to their line. A runner carrying a crate out links its work order.
5. **Evidence** (MUST #5): shots of the hoist open (day, light 411, night), the warm, amber and red sign-off lights, and the
   greyscale 1-second panel (quiet, busy, needs you, paused) at 25 % in light and dark. They are in the private notes,
   `site-scene-shots/S7i-fix/`.
   - To tell quiet from paused at 25 %: paused strings hazard tape across every station and dims the floor more (DIM 0.34 -> 0.48;
     the sky keeps the hour).
   - The night pool shows only on a night shift (crews at work after dark, the light on).
6. **"Scene frame"** in Settings > About (MUST #6).
7. **No lost taps** (MUST #7): the link layer is rewritten only when its markup changes, and a replaced stage disconnects its
   observers.

Bytes (information only now; Jordan approved a phone speed budget instead of byte caps):
- Stage (5 files, LF) 32,988 -> 34,135.
- `purpose.js` 3,156 (not counted in the stage sum).

Files outside ART's own:
- `pass-app/public/sw.js`: `/purpose.js` is added to the offline shell. Test-PassApp requires every script there.
- `app.js`: two strings in the scene section.

SHOULD items left for the next slice:
- #8: the cabin still reads a little like a hatch, and the amber lamp is close to the glow.
- #9: the runners stand far from the cabin.
- #10: the stool.
- #12: the card digits and the moustache.
