// The scene's frame meter (pass-app/SCENE.md "Frame rate"): a small box over the page with the frames a second the screen gives while
// something moves (120 on a 120 Hz phone), the screen's own rate, each frame's work (tick + draw; the 120 Hz budget is 8.3 ms) at p50,
// p95 and worst, draws a second and the frames over budget. Off by default: ?hud in the address, or Settings > About > Frame meter.
// scene.js loads this file only then (or for ?fps, which times frames for Settings > About without the box), so the stage never
// carries it. Ring buffers: a frame allocates nothing. "Run 5 s" draws every frame for 5 s, so a calm Yard can show the rate too.
import { METER } from './frame.js';

const RING = 240;
export const meterNew = (paint = null) => ({ work: new Float64Array(RING), wi: 0, wn: 0, gap: new Float64Array(RING), gi: 0, gn: 0,
  frames: 0, draws: 0, slow: 0, t0: 0, prev: 0, paint, line: '' });
// one frame: its work in ms, whether it drew, and the wait it asked for; twice a second (and when the loop stops) the line is new
export function meterNote(now, work, drew, wait, M) {
  M.work[M.wi] = work; M.wi = (M.wi + 1) % RING; if (M.wn < RING) M.wn++;
  if (M.prev) { M.gap[M.gi] = now - M.prev; M.gi = (M.gi + 1) % RING; if (M.gn < RING) M.gn++; }   // only between back-to-back frames
  M.prev = wait < 12 ? now : 0; if (work > 8.3) M.slow++;
  if (!M.t0) M.t0 = now; else { M.frames++; if (drew) M.draws++; }
  if (now - M.t0 >= 500 || !(wait < Infinity)) { M.line = meterLine(M, now, wait); M.frames = M.draws = 0; M.t0 = now; M.paint?.(M.line); }
}
const sorted = (a, n) => Array.from(a.subarray(0, n)).sort((x, y) => x - y);
const q = (s, p) => (s.length ? Math.round(s[Math.min(s.length - 1, Math.floor(p * s.length))] * 100) / 100 : 0);
export function meterLine(M, now, wait) {
  const s = now > M.t0 ? (now - M.t0) / 1000 : 1, w = sorted(M.work, M.wn), g = sorted(M.gap, M.gn);
  const head = !(wait < Infinity) ? 'idle: nothing moves, no frames' : wait >= 12 ? `waiting ${Math.round(wait)} ms for the next step` : `${Math.round(M.frames / s)} fps`;
  return `${head}\nscreen ${g.length ? Math.round(1000 / q(g, 0.5)) : '-'} Hz (p95 gap ${q(g, 0.95)} ms)\nwork p50 ${q(w, 0.5)} · p95 ${q(w, 0.95)} · max ${q(w, 1)} ms\n`
    + `${Math.round(M.draws / s)} draws/s · ${M.slow} frames over 8.3 ms`;
}

// the page's meter: timing starts when this file loads; the box shows while METER.on
const M = meterNew();
METER.note = (now, work, drew, wait) => meterNote(now, work, drew, wait, M);
METER.samples = () => sorted(M.work, M.wn);
let box = null;
export function meterBox(on) {
  if (!on) { box?.remove(); box = null; M.paint = null; return; }
  if (box || !document.body) return;
  const txt = document.createElement('div'), run = document.createElement('button');
  box = document.createElement('div'); box.className = 'px-meter';
  Object.assign(box.style, { position: 'fixed', top: 'calc(env(safe-area-inset-top, 0px) + 4px)', right: '4px', zIndex: '9999', padding: '6px 8px', borderRadius: '6px',
    font: '11px/1.4 ui-monospace, Menlo, Consolas, monospace', whiteSpace: 'pre', background: '#1a1412e6', color: '#fffaf0' });
  Object.assign(run.style, { marginTop: '4px', minHeight: '32px', padding: '0 10px', font: 'inherit', background: '#ffd36b', color: '#1a1412', border: '0', borderRadius: '4px' });
  txt.textContent = M.line || 'Frame meter: no frame yet (nothing moves)'; run.type = 'button'; run.textContent = 'Run 5 s';
  run.addEventListener('click', () => { METER.test = performance.now() + 5000; METER.wake?.(); });
  box.append(txt, run); document.body.append(box);
  M.paint = (s) => { txt.textContent = s; };
}
