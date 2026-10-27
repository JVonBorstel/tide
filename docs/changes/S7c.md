# Rename S7c: the stations become a site (the Board's scene, building site slice 3)

## In plain words
The five stations on the Board's stage are redrawn as site places (Jordan's answer 5):
- **Survey table** (plan, map, research ...): a drawing with a ruler and a paper roll; the crew member draws with a pencil.
- **Workbench** (do, build, repair, anything unknown): a heavy top with a vice holding a block and a red toolbox on the shelf. Busy:
  the hammer comes down, a weld flash at the vice, sparks and dust.
- **Inspection desk** (check, review): a clipboard and a desk lamp. Busy: the magnifier looks and the lamp glints.
- **Test rig** (tests, lint, verify): a panel with a gauge and an LED strip. Busy: the probe moves along and the LEDs chase.
- **Handover bay** (commit, merge ...): a taped crate on a pallet. Busy: a label goes on the crate.

The counters are now steel drawer cabinets with plywood tops (no wooden kitchen doors). Which step goes to which station did not
change. Not in this slice: the room around them, the world props, moments and chrome (S7d-S7g).

## What changed
- `pass-app/public/sprites.js`, redrawn in place (same names, sizes and frame counts):
  - stations `counter`, `stove`, `sink`;
  - props `board`, `pot`, `bowl`, `plates`;
  - the busy effects `oven-glow` (the weld flash), `flame` (sparks), `steam` (dust), `bubble` (an LED), and `smoke` (follows the
    dust, a shade darker);
  - the tools in the work loops (pencil, hammer, magnifier, probe, label instead of knife, spoon, taster, sponge, leaf).
- `pass-app/public/scene.js`: where the busy effects stand. The weld flash and sparks are at the vice instead of the oven door. The
  Inspection desk glints (the `sparkle` sprite, 1 draw) instead of steaming. The LEDs chase along the rig's panel instead of
  bubbling up. The draw counts are the same.
- `pass-app/test-scene.mjs`: the 6 station check names use the site names (same logic); 2 new checks.

## Bytes
| | stage brotli | this slice |
|---|---|---|
| S7b | 30,180 | |
| S7c | 30,842 | +662 (the brief planned +800) |

The ceiling stays at 34,615 (3,773 left).

## L1-L4
- **L1 (person):** at a glance Jordan sees where each work order stands, by place: drawing, building, inspecting, testing or handing over.
- **L2 (business):** the Board matches the site words used in every report and in the glossary.
- **L3 (MSP):** the draws do not change (busy floor 73, busiest 71 of 120); +662 bytes.
- **L4 (community):** original pixel art as code.

## Tests
- `node pass-app/test-scene.mjs`: 135 checks, 0 failed (133 before). New:
  - SiteStations: the station art and props carry no kitchen food or water, and the station labels are the site names.
  - SiteStations: a busy station costs the same draws as the kitchen did (work loop and effects: Workbench 6, Inspection desk 2,
    Test rig 4, Survey table 1, Handover bay 1).
- `node pass-app/test-live.mjs`: 63 checks, 0 failed.
- `tests/Test-PassApp.ps1` (bounded, 1200 s): 1025 passed, 0 failed.

## Seen in a browser
A look-only harness (made-up work orders, never the live Board) at a true 375 px phone width, light and dark. The shots are in the
private notes and wait for Jordan's yes.
