# Kitchen scene 2.0: design spec

The Live tab and the Board tab (route `#/pass`) of the Board (code: `pass-app/`, first called Chef) show the Yard as a small animated kitchen diorama (pass-app/public/scene.js + app.css).
The kitchen art is kept until S6, when it is redrawn as a building site (Jordan's decision 2026-10-23; gemini-brain projects/tide/naming/GLOSSARY.md). So the drawn things below (chefs, stations, the pass, the waiter, the cat) keep their kitchen names: they are the art, not the system's names. Each chef stands for a crew working a Step; each paper ticket stands for a work order.
It should feel like a tiny living game, not a status widget. Built in three parts, in order.

## Rules for every part
- Pure SVG and CSS, no libraries, no new dependencies. Animate only `transform` and `opacity`.
- Pause all animation when `document.hidden`. Keep `prefers-reduced-motion`: static scene, no movement.
- Private work orders show no words anywhere in the scene.
- Keep the exports `sceneHtml` and `activityWord` working for existing callers and tests.
- Tests for every new function (tests/Test-PassApp.ps1, or a node test file it runs).
- Budget: at most 60 animated elements and about 25 KB of SVG markup. Document it at the top of scene.js and test it.
- Must stay smooth on a mid-range Android phone.

## Part 1: living stage
- `mountScene(el, state, events, opts)` keeps one DOM element per job, keyed by job id across updates. It creates new ones, updates changed ones and animates out removed ones. It never replaces innerHTML wholesale, so animations never restart on refresh. `renderScene` in app.js calls it.
- The diorama:
  - back wall with shelves and hanging pans;
  - a ticket rail with one paper ticket per running work order, clipped on, fluttering when it changes;
  - a window whose sky follows the local hour (dawn, day, dusk, night with stars);
  - a checker floor.
- Named stations along the line (drawn places; the Steps they host are `kitchen/stations/*.ps1`):

  | Station (art) | Steps |
  |---|---|
  | cutting board | plan, map |
  | stove | do, build, repair |
  | tasting counter | check |
  | sink | tests, lint |
  | plating counter | commit, freshen, merge |

- Each crew is drawn as a chef who WALKS to the station matching their current Step when the Step changes: a leg cycle and body bob, using transforms with transition.
- Each chef looks unique but stays the same for a given job id. A hash picks skin tone, hat height, and moustache or not. The crew's colour is the scarf and the hat band.

## Part 2: moments (driven by events; each plays once per event, skipped if older than 2 minutes)
| Event | Moment |
|---|---|
| step.done | the chef flips the pan with a flame burst and a little hop |
| step.failed / step.rework | a puff of smoke; the chef scratches their head, then walks to the stove to fix it |
| tests ALL PASS | a sparkle over the sink |
| approval.requested | a waiter walks a covered plate along the aisle to the pass; the bell rings with a bounce and a ripple |
| approval.auto | the waiter carries it straight out with a small green check |
| job.done | an "Order up!" banner with a few confetti pieces |

- Seen event ids are kept in memory only, not in storage.
- Tapping a chef makes them wave and shows a speech bubble with the activity word for 3 seconds, then opens the work order.
- Idle life: blink every few seconds, glance around, wipe brow, tap foot. Timing differs per chef so they never move in sync.

## Part 3: ambience and polish
- Steam particles rise from busy pots with random drift.
- Pendant lamps flicker with a soft glow.
- A wall clock shows the real local time.
- A kitchen cat naps and wanders to a new spot about every minute.
- A dish pile at the sink grows with queued Inspection (test) runs.
- Gentle depth: back characters are slightly smaller and darker.
- The compact Board-tab version uses a calm subset: no cat, fewer particles.
- A legend chip row under the scene shows the crew colours with names.

## The pixel stage
Once `public/sprites.js` loads, the same `layoutScene` drives a canvas of original pixel art instead of the SVG (spec: gemini-brain projects/tide/specs/chef-art.md). Checked by `test-scene.mjs` and tests/Test-PassApp.ps1.
- **Palette**: one palette in sprites.js (`PALETTE`), one character per pixel, `.` transparent. 3-4 shade ramps per material, a warm near-black outline (`a`), light from the top left. Swap slots are replaced per chef (skin, hair), per crew (apron, neckerchief, hat band) and per sky (the window). Light sources (`EMISSIVE`) keep their colour under the sky tint (dawn, dusk, night). Every colour the pixel skin in app.css uses is a palette colour.
- **Sprites as code**: every sprite is palette-indexed strings or a tiny drawing recipe in sprites.js, packed into one atlas at load. No image files, no fetch, no network. Tiles are 16x16, characters 16x24 with walk, idle and work cycles.
- **Frame rate (Chef 2.8.0, TD Pour 4, then called W4)**: 60 frames a second only while a chef walks, 30 while only sprites animate, 10 when nothing moves; at most 120 sprite draws a frame (`STAGE` in scene.js, `stageFps` in frame.js). Each frame first records the draw calls it would make (`frameKey`, about 0.1 ms); the same key as the last drawn frame is the same picture, so the canvas is left alone. Drawn crisp: whole-number scale, image smoothing off, `image-rendering: pixelated`.
- **Hidden pause**: the loop stops while the page is hidden or the stage is scrolled out of view (an IntersectionObserver; `offsetParent` alone kept a scrolled-away stage drawing 210 frames in 10 s), and starts again on `visibilitychange` or when the stage scrolls back in.
- **Reduced motion**: under `prefers-reduced-motion` the stage draws one still frame and the chrome sprites hold still.
- **SVG fallback**: scene.js imports sprites.js lazily; if it cannot load (offline before the first visit) or the browser has no canvas, the SVG scene above stays. The service worker keeps `/sprites.js` in its offline shell, so a phone that has opened the Board once keeps the pixel stage offline.
- **Tapping**: a layer of plain links over the canvas, one per chef, waiter and ticket, each opens its work order; private work orders show no words.
- **Interface skin**: sprites.js also draws the tab icons, the loading, offline and empty chefs and the 9-slice panel; scene.js turns them into CSS variables (`--px-*`) and adds `<html class="px">`. Dark mode swaps in the dark panel and tab icons with a cream outline (the near-black one vanished on the dark bar), switched live when the phone changes theme.

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
| sign in the window | `paused`, `live` | OPEN lit = AI crews on, OPEN = AI crews off, CLOSED = paused (room dimmed as a palette shift, stools up on the counters) |
| wall clock | `lastTick`, `stalled` | the real time; frozen at the last Walkround (code: tick) when the Yard stalls |
| sous chef and stool (the Dispatcher, drawn) | `lastTick`, `stalled` | one round of the line per new Walkround (a Walkround seen on opening the Board walks only if under 2 min old); empty stool when stalled |
| fuse box | `breaker` (the stop-work order) | shut, or sparking with the pass lamp out |
| coin jar | `spent`, `budget`, `budget.stop` events | `floor(8 x spent / budget)` of 8; lid and padlock after a `budget.stop` today |
| the bench (drawn as a shelf) | job status, `job.quarantined` events | a burnt plate per Failed or Stopped work order (5, then +N), smoke for one that failed under 2 min ago; one link to the newest |
| rail tag | job status | +N tickets beyond the 8 the rail shows |
| heat lamps | `approval.requested` events | over each covered plate: warm, ember after 1 h, red after 4 h of real waiting |
| cork board, chalkboard, recipe box (the art; Specs are `recipes/`) | `due`, `leads`, `ideas` | a letter per follow-up due, a tally of new client leads, recipe cards for new ideas |
| hats on hooks | `cooks[].status` | a hat in the crew's colour for each crew resting, capped, off or signed out |
- **Legend**: the (i) chip in the stage's corner opens "What am I looking at?" (index.html `#legend-sheet`), one row per prop with its number in words; the stage's `aria-label` adds the short version (for example "the Yard open, AI crews on, $3 of $20 spent"; `worldWords` in world.js).
- **Cost**: still props are baked into the cached back layer, baked again only when a level changes (`worldKey`); per frame only heat lamps, sparks, smoke and the sous chef draw. The loop drops to 10 fps while nothing moves. `?fps` in the address times every frame; Settings > About shows the p95.
- **Budgets** (test-scene.mjs): at most 120 draws a frame on the busiest floor with every prop; the bytes are under "Moments and juice" below.

## Moments and juice (Chef 2.9.1, plan: gemini-brain projects/tide/plans/chef-art-2.md wave 2)
Real Yard events play short moments on the pixel stage (`public/moments.js`, pure, checked by test-scene.mjs). Each event plays once (seen ids live in memory only; the first state a page opens on is only marked seen, so a reload never replays), never when it is over 2 minutes old (also checked when a queued moment's turn comes, so nothing plays late after a hidden tab), at most 2 at once (the rest queue).
| Event (as kitchen.ps1 writes it) | Moment |
|---|---|
| `step.done` | the chef crouches (80 ms), hops and flips the pan with a flame burst, lands with a 1 px squash |
| `step.done` on a tests Step, the Inspection (the work order's `plan` says `tests`: ALL PASS) | sparkle over the sink and a check mark |
| `step.rework`, `step.fail` / crash / timeout / memcap / logflood / hung / `taster` (the Inspector sent it back) | a grey puff and a head scratch |
| `job.quarantined` | dark smoke; the plate travels (ease-in-out) to the bench (the drawn shelf) |
| `approval.requested` | the pass bell bounces (ease-out-back) |
| `job.done` | an "ORDER UP!" banner drops in with confetti in 3 colours (from one particle pool of at most 48) |
- **Juice**: every walk starts with one 80 ms anticipation crouch and eases out on arrival. Jordan's Approve (app.js calls `sceneApproved()` after their sign-off is sent) holds the floor for 80 ms and shakes the pass 1 px; no screen shake ever.
- **Tapping a chef**: it waves and its words show for 3 s (on the compact Board stage too; a private work order shows none), then the work order opens; a second tap opens it at once; under reduced motion it opens at once.
- **Reduced motion**: a moment is a still "after" frame (the check over the sink, the banner; the plate already stands on the bench) for 10 s; nothing moves.
- **Announce**: each moment is one polite line in `#announce` (today "#0071 is done: order up"; moments.js words change in S1-BOARD-SCENE), at most one per 10 s, work-order numbers only.
- **Cost**: a moment adds at most 20 draws a frame; the stage stays at 30 fps while one plays and stops while hidden or off screen as before.
- **Crews apart**: chefs stand one body (16 px) apart, never sharing a pixel column; a crowd at one station centres on it (`spread`).
- **Speech bubbles** are their own spans over the stage, placed (`placeSays`) over the head, higher, sideways or at the feet: the first spot that covers no WORLD prop (rectangles from the same bake that draws them) and no other bubble.
- **Budget** (test-scene.mjs): the stage files (scene, sprites, world, frame, moments) at most 34.6 KB brotli; measured 34.6 KB (+13.0 KB): wave 1 + TD Pour 4 +7.5 KB (after a 0.3 KB trim), wave 2 +5.5 KB, so about 2 KB over the plan's +6 and +5 KB together.
