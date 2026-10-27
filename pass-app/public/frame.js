// The stage's frame loop (pass-app/SCENE.md "Frame rate"; art critique S7 12c.1): requestAnimationFrame at the screen's own rate with
// delta time, one draw a frame and only for a new picture, no callback while nothing moves, the page is hidden or the stage off screen.
// No imports: scene.js, moments.js, live.js and the tests use it.

// The frame clock: a time-driven pixel takes its step from tk()/at(), which note when its next step is due; due(t) notes an expiry.
// Reset for each draw, CLOCK.next is then the first moment the picture can change by itself.
export const CLOCK = { next: Infinity };
export function tk(ms, t, off = 0) {
  const k = Math.floor((t + off) / ms); let nx = (k + 1) * ms - off;
  if (nx <= t) nx += ms;   // float rounding on a step's edge
  if (nx < CLOCK.next) CLOCK.next = nx;
  return k;
}
export const at = (n, ms, t, off = 0) => tk(ms, t, off) % n;
export const due = (t) => { if (t < CLOCK.next) CLOCK.next = t; };

// What the loop asks of a stage (scene.js: st.rev counts changes, st.drawn is the rev on screen, st.next the next due step).
// A tween (a moment, confetti, the Approve hit-stop) moves every frame, so it draws every frame.
export const stageAnim = (st) => { const fx = st.fx; return !!fx && (fx.live.length > 0 || fx.parts.length > 0 || fx.hit !== null); };
// something moves (a walk, a crouch, a tween, a queued moment): ask for the next frame
export function stageMoving(st) {
  if (stageAnim(st) || st.fx?.queue.length) return true;
  for (let i = 0; i < st.list.length; i++) if (st.list[i].path.length || st.list[i].cr > 0) return true;
  return false;
}
export const stageDirty = (st) => st.drawn !== st.rev || st.t >= st.next || stageAnim(st);
// how long the loop may wait: 0 = the next frame, n = ms to the next step, Infinity = stop (nothing changes by itself)
export const stageWait = (st) => (stageMoving(st) ? 0 : Math.max(0, st.next - st.t));

// drawn only while seen: page shown, motion allowed, in the page and on screen (an IntersectionObserver sets visible)
export const stageOk = (sc, doc = globalThis.document, reducedMotion = false) => !doc?.hidden && !reducedMotion && !!sc.root?.isConnected && sc.visible !== false && !!sc.root.offsetParent;

// The loop. frame(dt, now) returns the wait (undefined = the next frame): under 12 ms it asks for the next frame, longer it sleeps on a
// timer and then lines up with a frame, Infinity stops it until start(). fps (optional) caps it. Nothing is asked while ok() is false.
// dt is clamped to 100 ms (after a planned sleep, to the sleep plus 100 ms: nothing walks then); a stop restarts at dt 0.
export function makeLoop({ raf, ok, frame, fps = 0, timer = globalThis.setTimeout, untimer = globalThis.clearTimeout }) {
  const L = { raf: 0, tm: 0, last: 0, max: 100, frames: 0 };
  const arm = () => { if (!L.raf) L.raf = raf(step); };
  const wake = () => { L.tm = 0; if (ok()) arm(); else L.last = 0; };
  function step(now) {
    L.raf = 0;
    if (!ok()) { L.last = 0; return; }
    if (fps && L.last && now - L.last < 1000 / fps - 1) { arm(); return; }
    const dt = L.last ? Math.min(L.max, now - L.last) : 0;
    L.last = now; L.frames++;
    const w = frame(dt, now) ?? 0;
    if (!(w < Infinity)) { L.last = 0; return; }
    L.max = 100 + w;
    if (w < 12) arm(); else L.tm = timer(wake, w - 4);
  }
  L.start = () => { if (L.tm) { untimer(L.tm); L.tm = 0; L.max = 100; } if (!L.raf && ok()) arm(); return L; };
  return L;
}

// The frame meter (frame-meter.js, loaded only when it is on or ?fps times frames): note(now, work ms, drew, wait) per frame,
// samples() the timed frames' work; test: run every frame until then (its "Run 5 s")
export const METER = { on: false, note: null, samples: () => [], test: 0, wake: null };
// p50 and p95 of the timed frames' work (Settings > About); none timed: null
export function frameStats(list = METER.samples()) {
  const s = [...list].sort((a, b) => a - b), p = (x) => Math.round(s[Math.floor(x * s.length)] * 100) / 100;
  return s.length ? { n: s.length, p50: p(0.5), p95: p(0.95) } : null;
}
