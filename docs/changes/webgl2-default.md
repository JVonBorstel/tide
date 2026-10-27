# The WebGL2 renderer is on by default

**What:** the Board's pixel scene now draws with the WebGL2 renderer from task 10 (#56) on every phone, without `?gl` or a Settings tap. `glWanted` is true unless the phone kept it off (Settings > About > WebGL2 renderer, stored as `board.webgl2 = '0'`) or the address has `?gl=0`; `?gl` still turns a kept-off phone on for one visit. The fallback is unchanged: with no WebGL2, or only a software one (`failIfMajorPerformanceCaveat`), the stage draws with Canvas2D and Settings > About says why. This supersedes "behind a flag, off by default" in `docs/changes/task-10.md`.

**Why:** Jordan asked for it on (D-4 WebGL2 renderer, D-6 performance first, 120 fps target). Task 10's own numbers: WebGL2 frame work about half of Canvas2D's on the throttled phone profile (`docs/changes/task-10.md`, speed table), and the same picture pixel for pixel.

**Tests:**
- `pass-app/test-scene-gl.mjs` GlFlag: 10 cases, default on (nothing kept, `?glow` is not `?gl`), kept `'0'` off, `?gl=0` off, `?gl` on over a kept off.
- `pass-app/test-scene-gl-screen.mjs` GlScreen_DefaultOn (replaces GlScreen_SwitchKept): with nothing kept the stage draws with WebGL2 (or the fallback where the machine has none) and the switch is on; `?gl=0` turns it off for the visit; the switch turned off keeps Canvas2D on that phone; `?gl` turns it back on for the visit. The same-scene and software-fallback checks now compare against `?gl=0` (Canvas2D) explicitly.

**L1-L4:** person: smoother scene on the phone with no setting to find. Business, MSP, community: none.
