# The Board's phone speed budget

The Board must look its best **and** run at the phone's full rate: 120 frames a second on a 120 Hz phone, a steady 60 elsewhere, and no work at all when nothing moves. Byte caps were a stand-in for that; this budget measures the speed itself. It runs in CI on every pull request that touches `pass-app/` (`.github/workflows/speed.yml`) and by hand.

**Status: report only.** Numbers over budget show as warnings on the pull request and in the job summary; they never fail the check yet, because the frame-loop fix (one draw per frame, no frames while calm, no 60 fps cap) is landing in parallel. A run that cannot measure (the server or the browser did not start) does fail, so a broken gate is noticed.

## What it does

`pass-app/speed/run.mjs` starts two throwaway Board servers (`server.mjs`) on fixture Yards written by `pass-app/speed/fixture.mjs` (made-up work orders only, never real data), then drives headless Chrome through `playwright-core` (Apache-2.0, pinned in `pass-app/speed/package-lock.json`; it uses the Chrome already installed, nothing else is downloaded):

- **Phone profile:** 412 x 915 CSS px at 3x, touch, CPU **4x slower** (Chrome DevTools throttling), the tailnet's network (40 ms round trip, 10 Mbps), service worker off (a cold open every run).
- **Busy Yard** (6 crews at work, 2 sign-offs waiting, 6 queued cards, one handed over, one failed): cold open, 8 s of the scene at work, taps (the scene's (i) legend, a crew member, the Live tab, back to the Board), a view change (World tab and back: today a View Transition, later the drone-camera flight), a pinch zoom in and out over the scene, then the JS heap after a garbage collection.
- **The stage** is whatever the Board home shows: the pixel scene (`#scene-pass`) on main, the City (`#city`, its canvas) on the City home, which replaces the scene slot. The scenario finds it on the page, taps its legend chip, and pinches over it; on the City home the pinch is also reported as "City pinch zoom" (n/a on main). A stage or first paint that never appears is a warning annotation and an unmeasured metric, never a failed job.
- **Calm Yard** (nothing building or waiting): after it settles, 10 s of counting how often the page wakes for a frame and how much it scripts.
- **The probe** (`pass-app/speed/probe.js`) is injected before the Board's own scripts. It wraps `requestAnimationFrame` and times every callback, summed per vsync (the frame's JS work), counts canvas draws, and keeps Chrome's own paint, layout-shift, Event Timing (INP) and long-animation-frame entries. It reads nothing from the app's code, so the same numbers carry over when the renderer changes. The scenario opens the Board without a flag, so it measures Canvas2D, the default; the WebGL2 renderer (`?gl`, SCENE.md "Renderer") is not measured here yet; `pass-app/test-scene-gl-screen.mjs` times both renderers with the frame meter in headless Chrome (CPU 4x slower) and checks the WebGL2 p95 against `frameP95Ms`.
- Each run is repeated (3 by default) and the **median** of each metric is judged. The full numbers of every run go to `speed-report.json` (a CI artifact for 30 days).

## The budget (`pass-app/speed/budget.json`)

`target` is the goal (over it: a warning). `hard` is the limit (over it: fails the check once enforcing).

| Metric | Target | Hard | Why |
|---|---|---|---|
| Scene frame work p95, busy Yard | **8.3 ms** | **16.7 ms** | 8.3 ms is one frame at 120 Hz; 16.7 ms at 60 Hz |
| Scene frame work p99, busy Yard | 16.7 ms | 33.3 ms | no visible hitch |
| Scene frames over 33 ms in 8 s busy | 0 | 3 | |
| Frame work p95 during a pinch zoom | 8.3 ms | 16.7 ms | zoom must hold 120 Hz |
| Frame work p95 during a view change | 8.3 ms | 16.7 ms | the drone-camera flight is measured here when it lands |
| **INP** (slowest tap) | 100 ms | **200 ms** | Google's "good" line is 200 ms |
| First useful paint (status line, scene or its still card, first number) | 1.5 s | 2.0 s | the app may set `performance.mark('board-first-useful')`; the probe uses it when present |
| Largest paint (LCP) | 2.0 s | 2.5 s | |
| Cumulative layout shift | 0.02 | 0.05 | catches the card-to-canvas jump |
| JS heap after the session (after a GC) | 15 MB | 25 MB | catches leaking observers |
| Frame callbacks per second, calm Yard | 1 | 12 | the loop must stop when nothing moves (battery) |
| Scripting, calm Yard | 0.5 % | 1 % of one core | |

Also reported, not judged: frame p50, painted-frame p95, frames over 16.7 ms, long animation frames, most canvas draws in one frame, DOM nodes, canvases, FCP.

**Size report (information only):** raw and brotli size of every shipped file in `public/`, with a warning when the scripts pass 300 KB brotli. It replaces nothing yet: the byte caps in `test-scene.mjs` and `test-city.mjs` stay until Jordan decides to drop them (their owners change those files).

## First numbers (one local run, 2026-10-26, main at ac2afb9, Chrome 155, 4x throttle)

Scene frame work p95 10.9 ms (p50 8.0, p99 14.3), during a view change 16.1 ms, during a pinch 9.0 ms; INP 328 ms (the legend chip and the crew tap); first useful paint 2.06 s, LCP 2.14 s, CLS 0; heap 4.2 MB; **calm Yard: 144 frame callbacks a second and 7 % of a core** (the loop is re-armed every vsync while nothing moves; the parallel frame-loop fix should take this to about 0). A CI runner is slower and noisier than a desktop; read the trend, not one run.

## Run it by hand

```
cd pass-app/speed && npm ci --ignore-scripts
node run.mjs --runs 1            # prints the table; CHROME_PATH=... to pick a browser
node run.mjs --out report.json --summary summary.md
```

## Flip to enforcing

When the frame-loop fix has landed and main's numbers sit inside the hard limits for a few runs: set `"enforce": true` in `pass-app/speed/budget.json` in its own small PR (say why in the PR). From then on a metric over its **hard** limit fails the `speed` check; over **target** stays a warning. To make it block merges, add the `speed / board` check to the branch's required checks. `--enforce` or `SPEED_ENFORCE=1` enforces one run without changing the file. Tighten a limit by editing its `hard` value; never loosen one to make a red run green without saying why in the PR.

## What CI cannot tell you about 120 Hz

Headless Chrome on a runner does not present at 120 Hz and does not measure the compositor, GPU raster, heat throttling or the phone's adaptive refresh. CI measures the **CPU work per frame** on a slowed-down CPU, the part the code controls; 8.3 ms p95 there is a conservative stand-in for a flagship phone. The real proof is on the phone itself: open the Board with `?fps` in the address and read the frame p95 in Settings > About (a fuller on-phone overlay is planned).
