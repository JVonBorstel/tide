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
- **`pass-app/SPEED.md`**: it said the probe would measure "WebGL later". It now says the speed job opens the Board without the flag, so it measures Canvas2D; the WebGL2 renderer is not measured there yet.

## Tests

`pass-app/test-scene.mjs`: 189 checks, 189 pass (181 before, 8 new). The new checks are named after the acceptance lines:

- **GlSameScene** (renders the same scene as Canvas2D on a fixture): 8 cases (a busy floor at 4 hours of the day, every prop, paused, a stop-work order, every moment), 90 frames compared pixel by pixel, 0 pixels differ. The WebGL2 side runs on a stand-in that keeps the buffers and the atlas and rasterizes each draw call (pixel centres, one owner per shared-edge pixel, `texelFetch`, premultiplied blending).
- **GlFallback** (falls back when WebGL2 is missing): 4 cases (no WebGL2, `getContext` throws, shaders do not build, textures under 2048 px). Each gives null with its reason, and the stage gets a working Canvas2D context (a fresh canvas in 2 of the 4).
- **GlFrameBudget** (frame time inside the speed budget): 600 frames of a busy floor, tick + draw through gl.js, p95 about 0.06 ms in node against the 8.3 ms target read from `pass-app/speed/budget.json`. 1 draw call a frame, each strip uploaded once, 0 atlas restarts.
- **GlOneDraw**: every compared frame clears once and is 1 draw call (90 of 90).
- **GlAtlasFull**: the atlas filling mid-frame (1 restart) and a frame over 2048 quads both still match Canvas2D (0 pixels differ).
- **GlContextLost**: a lost context calls the fallback once, later stages get Canvas2D, and drawing on the lost context throws nothing.
- **GlFlag**: 8 flag cases, gl.js imported only behind the flag, the switch and the About line are wired.
- **GlShaders**: `texelFetch`, highp, the pixel-to-clip mapping, no antialiasing, premultiplied blending, software WebGL2 refused.
- **budget: the stage files**: the ceiling moved from 37,015 to 37,215 bytes brotli (D-6). The hook in scene.js measured +388 bytes (LF). gl.js is its own file, loaded only behind its flag, and is not counted (like frame-meter.js).

**The tests can fail.** Each change below was put into gl.js, the suite was run, and the file was restored:

| Change | Result |
|---|---|
| source x off by one in the 9-argument `drawImage` | GlSameScene failed |
| every quad 1 px lower | GlSameScene and GlAtlasFull failed |

**In a real browser** (desktop Chrome 152, not throttled; a scratch page, not committed). The real shaders were compared with Canvas2D on a busy floor at 4 hours, 20 frames each: 501,760 pixels per hour compared, 0 differ. Tick + draw over 570 frames: WebGL2 p95 0.1 ms (worst 0.5 ms), Canvas2D p95 0.2 ms (worst 5.4 ms). The timer's resolution there is 0.1 ms. In the same page, `?gl` mounted WebGL2, the switch turned it off and on, and a forced context loss (`WEBGL_lose_context`) brought the stage back on Canvas2D, with the reason in the About line.

## L1-L4 effect

- **L1 (person):** the scene can run on the graphics chip, which leaves more CPU and battery headroom for 120 frames a second on a phone. Nothing changes for anyone who does not turn the flag on.
- **L2 (business):** none. No new service, no new dependency, no cost.
- **L3 (MSP):** none.
- **L4 (community):** the renderer is small, plain WebGL2 with no library. Its tests run in node with no GPU and no browser.

## Unknown or not verified

- **Phone numbers.** Unknown. It has not been run on a phone. The CI speed job measures Canvas2D only, because it opens the Board without `?gl`.
- **The live Board.** It was not opened with the flag. The real-browser check used a scratch page that imports the same files.
- **GPU cost.** The timings above are JS work per frame. Time on the GPU and the compositor was not measured.
