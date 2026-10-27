# Task 10: Board: WebGL2 renderer with Canvas2D fallback

Decisions named: D-4 (our own WebGL2 renderer, Canvas2D kept as the fallback), D-6 (performance over size), D-3 (the Board's look: unchanged here, the same pixels are drawn).

## In plain words

The Board's pixel scene can now be drawn by a WebGL2 renderer of our own. It is behind a flag and off by default:

- `?gl` in the address turns it on for one visit; `?gl=0` turns it off for one visit.
- Settings > About > **WebGL2 renderer** turns it on for this phone (kept in the phone's storage).
- Settings > About > **Scene renderer** says which renderer draws, and why WebGL2 is off when it is.

The picture is the same as Canvas2D's, pixel for pixel. When WebGL2 cannot be used, the scene draws with Canvas2D as before.

## What changed

- **`pass-app/public/gl.js` (new).** A context that takes the same calls as Canvas2D (`drawImage` with 3, 5 or 9 arguments, `fillRect` with `fillStyle`), so `drawStage` in scene.js did not change. Each sprite strip and baked layer is copied once into one 2048 px atlas texture (shelf-packed; started again when it is full, after drawing what is queued). A frame is quads in one buffer and one `drawElements`. The fragment shader uses `texelFetch` at whole texels, so pixels stay crisp; blending is premultiplied source-over, as Canvas2D draws. `glStage` returns null, with its reason, when there is no WebGL2, only a software WebGL2 (`failIfMajorPerformanceCaveat`), the shaders do not build, or textures are under 2048 px. When it gives up after taking the canvas's context, it puts a fresh canvas in its place so Canvas2D can draw there. A lost context switches the page to Canvas2D for the rest of the visit.
- **`pass-app/public/scene.js`.** `glWanted` (the flag), `sceneGl` (the Settings switch), `sceneRenderer` (the About line), a `remount` that rebuilds every pixel stage, `ctx.flush?.()` at the end of `paintStage`, and `mountPixel` asks gl.js first when it is loaded. gl.js is imported only when the flag is on.
- **`pass-app/public/app.js`.** The switch and the About line, next to the Frame meter.
- **`pass-app/public/sw.js`.** `/gl.js` is in the offline shell (Test-PassApp.ps1 requires every app script there).

## Shared files changed (minimal, with the reason)

- **`pass-app/SCENE.md`**: a "Renderer" line next to the frame meter and the still fallback, where the neighbouring options are documented, and the new byte ceiling.
- **`pass-app/SPEED.md`**: it said the probe would measure "WebGL later". It now says the speed job opens the Board without the flag, so it measures Canvas2D, and that `test-scene-gl-screen.mjs` times both renderers in headless Chrome.
- **`pass-app/test-browser-kit.mjs`**: `cdpConnect(dir, { gpu: true })` leaves out `--disable-gpu`, so the screen test can get a hardware WebGL2. The other screen tests keep the default.
- **`tests/Test-PassApp.ps1`**: runs `pass-app/test-scene-gl-screen.mjs`, the same way it runs `test-status-line.mjs`.
- **Merged with main.** Task 25 split `test-scene.mjs` by topic, so the WebGL2 checks now live in their own `pass-app/test-scene-gl.mjs`, which `test-scene.mjs` runs last. The stage byte budget check moved with the budget into `test-scene-purpose.mjs`. `app.js` imports `skyAt` (task 28) and `sceneGl`, `sceneRenderer` (this task).

## Tests

`pass-app/test-scene.mjs` (with `test-scene-gl.mjs`): 189 checks, 189 pass (181 on main, 8 new). The new checks are named after the acceptance lines:

- **GlSameScene** (renders the same scene as Canvas2D on a fixture): 8 cases (a busy floor at 4 hours of the day, every prop, paused, a stop-work order, every moment), 90 frames compared pixel by pixel, 0 pixels differ. The WebGL2 side runs on a stand-in that keeps the buffers and the atlas and rasterizes each draw call (pixel centres, one owner per shared-edge pixel, `texelFetch`, premultiplied blending).
- **GlFallback** (falls back when WebGL2 is missing): 4 cases (no WebGL2, `getContext` throws, shaders do not build, textures under 2048 px). Each gives null with its reason, and the stage gets a working Canvas2D context (a fresh canvas in 2 of the 4).
- **GlFrameBudget** (frame time inside the speed budget): 600 frames of a busy floor, tick + draw through gl.js, p95 about 0.06 ms in node against the 8.3 ms target read from `pass-app/speed/budget.json`. 1 draw call a frame, each strip uploaded once, 0 atlas restarts.
- **GlOneDraw**: every compared frame clears once and is 1 draw call (90 of 90).
- **GlAtlasFull**: the atlas filling mid-frame (1 restart) and a frame over 2048 quads both still match Canvas2D (0 pixels differ).
- **GlContextLost**: a lost context calls the fallback once, later stages get Canvas2D, and drawing on the lost context throws nothing.
- **GlFlag**: 8 flag cases, gl.js imported only behind the flag, the switch and the About line are wired.
- **GlShaders**: `texelFetch`, highp, the pixel-to-clip mapping, no antialiasing, premultiplied blending, software WebGL2 refused.
- **budget: the stage files**: the ceiling moved from 37,015 to 37,215 bytes brotli (D-6). The hook in scene.js measured +388 bytes (LF). gl.js is its own file, loaded only behind its flag, and is not counted (like frame-meter.js).

**The tests can fail** (from the first run of this branch; not repeated after the merge). Each change below was put into gl.js, the suite was run, and the file was restored:

| Change | Result |
|---|---|
| source x off by one in the 9-argument `drawImage` | GlSameScene failed |
| every quad 1 px lower | GlSameScene and GlAtlasFull failed |

**In a scratch page, first run of this branch** (desktop Chrome, not throttled; not committed). The real shaders were compared with Canvas2D on a busy floor at 4 hours, 20 frames each: 501,760 pixels per hour compared, 0 differ. Tick + draw over 570 frames: WebGL2 p95 0.1 ms (worst 0.5 ms), Canvas2D p95 0.2 ms (worst 5.4 ms). The timer's resolution there is 0.1 ms. In the same page, `?gl` mounted WebGL2, the switch turned it off and on, and a forced context loss (`WEBGL_lose_context`) brought the stage back on Canvas2D, with the reason in the About line.

## The real Board in headless Chrome (`pass-app/test-scene-gl-screen.mjs`)

This drives the real Board server on a throwaway state folder (the speed fixture's busy Yard, made-up work orders) at 412 x 900. It uses two browsers: one with the graphics chip (a desktop graphics card through ANGLE on this machine) and one without it (only a software WebGL2). 6 checks, all pass on this machine. `tests/Test-PassApp.ps1` runs it.

- **GlScreen_WebGL2Draws**: with `?gl`, Settings > About says "WebGL2".
- **GlScreen_SameScene** (renders the same scene as Canvas2D on a fixture): the Live tab's stage, 201 x 112 art pixels, each compared at the centre of its block on screen. The page's clocks (`Date.now`, `performance.now`, the frame time) are held still, so both opens draw the same animation step and the same moments. Each side is captured once two shots 400 ms apart match, because the live state can still be arriving on a busy machine. The page elements over the canvas are hidden for the shot. Result: 0 art pixels differ, on 4 runs at once. Without the held clocks and the wait, two Canvas2D opens also differed from each other by a few pixels, so the renderer was not the cause. Device pixels are not compared one by one: at a fractional edge, the compositor scales a WebGL2 layer and a 2D layer from different corners, so one row of device pixels can land on the neighbouring art pixel.
- **GlScreen_FallbackNoWebGL2** (falls back when WebGL2 is missing): `getContext('webgl2')` gives null, the stage draws with Canvas2D, and About says why.
- **GlScreen_FallbackSoftware**: with no graphics chip (as on the CI runners), the software WebGL2 is refused. The stage draws with Canvas2D, and the picture matches the one without the flag (0 pixels differ).
- **GlScreen_SwitchKept**: the Settings switch keeps WebGL2 on without `?gl`, and `?gl=0` turns it off for the visit.
- **GlScreen_FrameBudget** (frame time inside the speed budget): the speed numbers are below.

On a machine with no hardware WebGL2 (the CI runners), the WebGL2Draws and SameScene checks say "not checked here" in their names. Only the fallback is checked there.

### Speed numbers

These are the frame meter's own numbers (`?hud`, then "Run 5 s", so the stage draws every frame for 5 s). Each number is the work per frame: tick + draw, plus the WebGL2 flush. Setup: CPU 4x slower (the speed budget's phone profile), the busy fixture Yard, 412 px, 3 runs of 5 s each. The budget is `frameP95Ms`, 8.3 ms.

| | p50 per run (ms) | p95 per run (ms) | max per run (ms) | median p95 |
|---|---|---|---|---|
| main, Canvas2D (before) | 1.1 / 1.5 / 0.9 | 2.0 / 4.7 / 1.4 | 2.5 / 23.7 / 2.0 | 2.0 ms |
| this branch, Canvas2D (`?gl=0`) | 1.0 / 1.0 / 0.9 | 1.5 / 1.5 / 1.2 | 2.9 / 5.1 / 1.6 | 1.5 ms |
| this branch, WebGL2 (`?gl`) | 0.5 / 0.4 / 0.4 | 0.9 / 0.6 / 0.7 | 1.4 / 0.7 / 2.4 | 0.7 ms |

Canvas2D is not worse than on main, because without the flag it runs the same code. WebGL2 takes about half the frame work of Canvas2D. GPU time is not in these numbers.

### Screenshots (412 x 900, in `docs/changes/task-10/`)

- `scene-412-dark-before.png`, `scene-412-light-before.png`: main, Canvas2D.
- `scene-412-dark-webgl2.png`, `scene-412-light-webgl2.png`: this branch with `?gl`, drawn by WebGL2.
- `scene-412-dark-fallback.png`, `scene-412-light-fallback.png`: this branch with `?gl` and no WebGL2, drawn by Canvas2D.
- `settings-412-dark-webgl2.png`, `settings-412-dark-fallback.png`: Settings > About, with the renderer line and the switch.

The pictures differ only where the scene moves by itself, such as the handover sign and a crew member's work step.

## L1-L4 effect

- **L1 (person):** the scene can run on the graphics chip, which leaves more CPU and battery headroom for 120 frames a second on a phone. Nothing changes for anyone who does not turn the flag on.
- **L2 (business):** none. No new service, no new dependency, no cost.
- **L3 (MSP):** none.
- **L4 (community):** the renderer is small, plain WebGL2 with no library. Its tests run in node with no GPU and no browser.

## Unknown or not verified

- **Phone numbers.** Unknown. It has not been run on a phone; the numbers above come from a desktop browser with the CPU slowed 4x. The CI speed job measures Canvas2D only, because it opens the Board without `?gl`.
- **The live Board.** It was not opened with the flag. The real-browser checks used the real Board server on a throwaway state folder.
- **GPU cost.** The timings above are JS work per frame. Time on the GPU and the compositor was not measured.
