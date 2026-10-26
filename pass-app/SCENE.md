# The Board's scene: design spec

The Live tab and the Board tab (route `#/pass`) of the Board (code: `pass-app/`, first called Chef) show the Yard as a small building site (pass-app/public/scene.js, sprites.js, world.js, moments.js, frame.js and app.css).
It was a kitchen until rename S7 (2026-10-26; plan: gemini-brain projects/tide/plans/site-scene-S7.md; names: projects/tide/naming/GLOSSARY.md, "The Board's scene"). Each crew member stands for a crew working a Step; each work-order card on the job board stands for a work order. The code keeps its old names (sprite keys `chef-*`, `waiter-*`, `cloche`, `coin-jar`, stations `board`, `stove`, `taste`, `sink`, `plate`, the stage kinds `chef`, `waiter`, `sous`): they are code names, not what Jordan reads.
It should feel like a tiny living game, not a status widget.

## Rules
- No libraries, no new dependencies. The art is the pixel stage below; before it loads the scene is a still card (rename S7a).
- Pause all animation when `document.hidden`. Keep `prefers-reduced-motion`: one still frame, no movement.
- Private work orders show no words anywhere in the scene.
- Keep the exports `sceneHtml` and `activityWord` working for existing callers and tests, and the sprite exports the City view reads.
- Tests for every new function (tests/Test-PassApp.ps1, or a node test file it runs).
- Budget: the still card has no animation and at most 25 KB of markup; the pixel stage has its own budgets below. Documented at the top of scene.js and tested.
- Must stay smooth on a mid-range Android phone.

## The still card and the layout
- `mountScene(el, state, events, opts)` (`renderScene` in app.js calls it) draws the pixel stage once sprites.js has loaded. Until then it shows the **still card** (`cardHtml` in scene.js, rename S7a): the same links as the stage, one per crew member (its station and what it does), work-order card on the job board, runner at the sign-off window and work order handed over in the last 3 minutes, each opening its work order; no people and no motion, rebuilt only when its words change. It replaced the first animated SVG kitchen diorama.
- `layoutScene` (pure, tested) decides who is where. Stations along the floor (drawn places; the Steps they host are `kitchen/stations/*.ps1`; labels in `STATIONS`):

  | Station | Code name | Steps |
  |---|---|---|
  | Survey table | `board` | plan, map, research, worktree, diagnose, slice, talk, ask, scout |
  | Workbench | `stove` | do, build, repair, and any step it does not know |
  | Inspection desk | `taste` | check, review |
  | Test rig | `sink` | tests, lint, mutate, verify |
  | Handover bay | `plate` | commit, freshen, merge, ideas, pack-render, inventory |

- Each crew member walks to the station of its current Step. It looks the same for a given work order (a hash picks skin tone, hair and a moustache or not) and wears a **hard hat in its crew's colour** (Claude orange, Gemini blue, Claude via Google purple, Home crew green, Yard hands grey) with a hi-vis vest.
- **Runners** in hi-vis bring a clipboard to the **sign-off window** for each work order waiting for sign-off (3 at most, and the count), and carry a crate out for one handed over in the last 3 minutes. A crew member asleep on a crate, hard hat over the eyes, means nothing is building.
- Tapping a crew member makes it wave and shows its words for 3 seconds, then opens the work order.

## The pixel stage
Once `public/sprites.js` loads, `layoutScene` drives a canvas of original pixel art (spec: gemini-brain projects/tide/specs/chef-art.md). Checked by `test-scene.mjs` and tests/Test-PassApp.ps1.
- **The site:** blockwork above plywood hoarding, a concrete slab, paint tins and tools on pegboards, the job board (a hazard-taped bar with work-order cards: two digits and a step bar), the sign-off window (a site-cabin hatch under hazard tape, a caged work light, a bell), the window and its sky, the gate.
- **Busy stations:** a weld flash, sparks and dust at the Workbench; a lamp glint at the Inspection desk; chasing LEDs on the Test rig. Each busy station costs the same draws as the kitchen did.
- **Palette**: one palette in sprites.js (`PALETTE`), one character per pixel, `.` transparent. 3-4 shade ramps per material, a warm near-black outline (`a`), light from the top left. Swap slots are replaced per character (skin, hair), per crew (the hard hat and the vest badge) and per sky (the window). Light sources (`EMISSIVE`) keep their colour under the sky tint (dawn, dusk, night); the hi-vis yellow (`G H J`) is not one, so it dims at night and when paused. Every colour the pixel skin in app.css uses is a palette colour.
- **Sprites as code**: every sprite is palette-indexed strings or a tiny drawing recipe in sprites.js, packed into one atlas at load. No image files, no fetch, no network. Tiles are 16x16, characters 16x24 with walk, idle and work cycles.
- **Frame rate (Chef 2.8.0, TD Pour 4, then called W4)**: 60 frames a second only while someone walks, 30 while only sprites animate, 10 when nothing moves; at most 120 sprite draws a frame (`STAGE` in scene.js, `stageFps` in frame.js). Each frame first records the draw calls it would make (`frameKey`, about 0.1 ms); the same key as the last drawn frame is the same picture, so the canvas is left alone. Drawn crisp: whole-number scale, image smoothing off, `image-rendering: pixelated`.
- **Hidden pause**: the loop stops while the page is hidden or the stage is scrolled out of view (an IntersectionObserver; `offsetParent` alone kept a scrolled-away stage drawing 210 frames in 10 s), and starts again on `visibilitychange` or when the stage scrolls back in.
- **Reduced motion**: under `prefers-reduced-motion` the stage draws one still frame and the chrome sprites hold still.
- **Still fallback**: scene.js imports sprites.js lazily; if it cannot load (offline before the first visit) or the browser has no canvas, the still card stays (it replaced the animated SVG kitchen in rename S7a, which also flashed for a moment on a cold open). The service worker keeps `/sprites.js` in its offline shell, so a phone that has opened the Board once keeps the pixel stage offline.
- **Tapping**: a layer of plain links over the canvas, one per crew member, runner and work-order card, each opens its work order; private work orders show no words.
- **Interface skin**: sprites.js also draws the tab icons, the loading (a crew member hammering at the vice), offline (asleep on a crate by the site lantern) and empty (leaning on a shovel by an empty pallet) sprites and the 9-slice panel; scene.js turns them into CSS variables (`--px-*`) and adds `<html class="px">`. Dark mode swaps in the dark panel and tab icons with a cream outline (the near-black one vanished on the dark bar), switched live when the phone changes theme.

## The Live call
The Live tab under the stage is a team call (the idea comes from Agent Standup; the code and art are the Board's own): `public/live.js`, styled in app.css "Live: the call", checked by `test-live.mjs` and tests/Test-PassApp.ps1.
- **Agents**: every running Step is an agent: its crew (Claude, Gemini, Claude via Google, Local, the Yard hands for script Steps) sits at a desk drawn in the pixel art of sprites.js (`desk`, `laptop`, `work-type`, `desk-wall`, the chef sprites in the crew's palette). Crews not on the call keep a dimmed desk with their status (Idle, Resting, Signed out); the Yard hands always have one.
- **Join and leave**: an agent joins when its Step starts (state `since`) and leaves 2 minutes after the Step ends, marked ✓ done or ✗ failed with its real duration (from the `step.done` / `step.fail` events), then fades out. A page opened mid-shift shows who finished in the last 2 minutes from the event stream (the `cook` event names the crew; a Step without one is the Yard hands').
- **On each desk**: the activity tag (Reading app.js, Editing foo.ts, Running tests, Searching “x”), the ticker (the current tool with a spinner and a live timer, then ✓ / ✗ and the real duration), tokens (⚡) and failed calls (✗). **Stuck**: a tool running over 60 s pulses amber (⏳). **Quiet**: a crew that reports tool by tool and has said nothing for 3 minutes sleeps at its desk (💤); a crew that never reports is never called quiet (we can't know).
- **Spotlight and shared screen**: the agent with the newest activity shares its screen (a tapped desk keeps the spotlight 25 s): a terminal with the last calls, each command and the first lines of its output (errors red, "… +N lines"), or an editor with the file it reads or edits and line numbers; the presenter's camera in the corner; a footer `✓ Bash · 1.2 s` or `Bash · running 0:03`. Crews that do not report tool by tool show their own log lines.
- **Header**: Live / Off air, how many are on the call, calls, failures, stuck and quiet counts, tokens on the call and today, and two opt-in toggles (both off by default, stored on the phone): **notify me when the team goes quiet** (a chime made in the browser and a notice with no content, which reads "The Yard went quiet" / "Open the Board" (live.js:389-390), once a minute after the last busy crew stops) and **voice lines** (speechSynthesis says who joins and leaves; shown only where the browser can speak).
- **Tree**: work order -> Steps -> crew: each work order on the call with its Steps (done, now, failed, waiting) and which crew built or builds each one (the server sends `jobs[].plan`, station and role per step, for running jobs).
- **Tap a desk**: a sheet with the Step's prompt summary (from the job sheet's data), the tools used with counts, the recent calls (status, duration, expandable command and output) and the last report.
- **Private work orders**: no target, output, log, prompt or report anywhere on the call or in the voice: the desk says only the kind of tool, the screen says it is private. The server already strips them (ts, kind, tool, status only); live.js keeps the same whitelist again.
- **Motion**: the desk canvases draw at 8 frames a second at most, never while the page is hidden or the call is off screen, one still frame under reduced motion; CSS animations stop under reduced motion and pause while hidden.

## The world (Chef 2.7.0, plan: gemini-brain projects/tide/plans/chef-art-2.md wave 1)
Every new thing in the room is one row of `WORLD` in `public/world.js` (the pure world model; scene.js draws it): the real field it comes from, when it is absent, and `meaning(w)`, its plain-words line in the legend sheet. `worldOf(state, events, now)` is pure and turns state into props; a missing field draws nothing (never a default).
| Prop | From | What it shows |
|---|---|---|
| gate sign | `paused`, `live` | OPEN lit = AI crews on, OPEN = AI crews off, PAUSED = paused (never CLOSED: "Site closed" is the merge freeze; the site dims as a palette shift, barriers across two stations) |
| site clock | `lastTick`, `stalled` | the real time; frozen at the last Walkround (code: tick) when the Yard stalls |
| the Dispatcher (white hard hat, clipboard) and the folding stool by the gate | `lastTick`, `stalled` | one lap of the site per new Walkround (a Walkround seen on opening the Board walks only if under 2 min old); empty stool when stalled |
| power board | `breaker` (the stop-work order) | shut, or sparking with a red STOP tag and the work light out |
| budget meter | `spent`, `budget`, `budget.stop` events | `floor(8 x spent / budget)` of 8 segments (green, amber, red); a chain and padlock after a `budget.stop` today |
| the bench | job status, `job.quarantined` events | a parked crate per Failed or Stopped work order (5, then +N), dust for one that failed under 2 min ago; one link to the newest |
| job board tag | job status | +N work orders beyond the 8 cards the job board shows |
| sign-off lights | `approval.requested` events | a beacon per waiting work order: warm, amber after 1 h, red after 4 h of real waiting |
| notice board, whiteboard, idea box | `due`, `leads`, `ideas` | a note per follow-up due, a marker tally of new client leads, slips for new ideas |
| hard hats on hooks | `cooks[].status` | a hard hat in the crew's colour for each crew resting, capped, off or signed out |
- **Legend**: the (i) chip in the stage's corner opens "What am I looking at?" (index.html `#legend-sheet`), one row per prop with its number in words; the stage's `aria-label` adds the short version (for example "the Yard open, AI crews on, $3 of $20 spent"; `worldWords` in world.js).
- **Cost**: still props are baked into the cached back layer, baked again only when a level changes (`worldKey`); per frame only sign-off lights, sparks, dust and the Dispatcher draw. The loop drops to 10 fps while nothing moves. `?fps` in the address times every frame; Settings > About shows the p95.
- **Budgets** (test-scene.mjs): at most 120 draws a frame on the busiest floor with every prop; the bytes are under "Moments and juice" below.

## Moments and juice (Chef 2.9.1, plan: gemini-brain projects/tide/plans/chef-art-2.md wave 2)
Real Yard events play short moments on the pixel stage (`public/moments.js`, pure, checked by test-scene.mjs). Each event plays once (seen ids live in memory only; the first state a page opens on is only marked seen, so a reload never replays), never when it is over 2 minutes old (also checked when a queued moment's turn comes, so nothing plays late after a hidden tab), at most 2 at once (the rest queue).
| Event (as kitchen.ps1 writes it) | Moment |
|---|---|
| `step.done` | the crew member crouches (80 ms) and hops, a brick rises and lands on a stack on the station top with a spark, a 1 px squash on landing |
| `step.done` on a tests Step, the Inspection (the work order's `plan` says `tests`: ALL PASS) | sparkle over the Test rig and a check mark |
| `step.rework`, `step.fail` / crash / timeout / memcap / logflood / hung / `taster` (the Inspector sent it back) | a dust puff and a head scratch in a work glove |
| `job.quarantined` | dark smoke; the crate travels (ease-in-out) to the bench |
| `approval.requested` | the bell at the sign-off window bounces (ease-out-back) |
| `job.done` | a "HANDED OVER" banner drops in with confetti in 3 colours (from one particle pool of at most 48) |
- **Juice**: every walk starts with one 80 ms anticipation crouch and eases out on arrival. Jordan's Approve (app.js calls `sceneApproved()` after their sign-off is sent) holds the floor for 80 ms and shakes the sign-off window 1 px; no screen shake ever.
- **Tapping a crew member**: it waves and its words show for 3 s (on the compact Board stage too; a private work order shows none), then the work order opens; a second tap opens it at once; under reduced motion it opens at once.
- **Reduced motion**: a moment is a still "after" frame (the check over the Test rig, the banner; the crate already stands on the bench) for 10 s; nothing moves.
- **Announce**: each moment is one polite line in `#announce` (for example "WO-0071 is handed over"), at most one per 10 s, work-order numbers only.
- **Cost**: a moment adds at most 20 draws a frame; the stage stays at 30 fps while one plays and stops while hidden or off screen as before.
- **Crews apart**: crew members stand one body (16 px) apart, never sharing a pixel column; a crowd at one station centres on it (`spread`).
- **Speech bubbles** are their own spans over the stage, placed (`placeSays`) over the head, higher, sideways or at the feet: the first spot that covers no WORLD prop (rectangles from the same bake that draws them) and no other bubble.
- **Budget** (test-scene.mjs): the stage files (scene, sprites, world, frame, moments) at most 34,615 bytes brotli; measured 34.6 KB (+13.0 KB): wave 1 + TD Pour 4 +7.5 KB (after a 0.3 KB trim), wave 2 +5.5 KB, so about 2 KB over the plan's +6 and +5 KB together. Rename S7a retired the SVG kitchen: 29,937 bytes (-4,640); the building-site redraw S7b-S7g spent +2,439 of that room, to 32,376 (2,239 left); the ceiling did not move.
