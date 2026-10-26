// Moments and juice on the pixel stage, and where chefs and speech bubbles stand (Chef 2.9.1; plans/chef-art-2.md wave 2;
// pass-app/SCENE.md "Moments and juice"). Pure state on the stage model (st.fx), tested by pass-app/test-scene.mjs. No storage.
import { STAGE, STATIONS, ticket, sx } from './scene.js';
import { PLACE, bakeWorld } from './world.js';
// event type -> moment (every one is an event kitchen.ps1 writes; step.<kind> are its step failures)
export const MOMENTS = { 'step.done': 'flip', 'step.rework': 'puff', 'job.quarantined': 'aside', 'approval.requested': 'bell', 'job.done': 'orderup',
  ...Object.fromEntries(['fail', 'crash', 'timeout', 'memcap', 'logflood', 'hung', 'taster'].map((k) => ['step.' + k, 'puff'])) };
export const FX = { fresh: 2 * 60 * 1000, atOnce: 2, pool: 48, crouch: 80, say: 10000, wave: 3000, hitStop: 80 };
const LONG = { flip: 700, sparkle: 900, puff: 1100, aside: 1500, bell: 800, orderup: 1500 };
const LINE = { flip: 'finished a step', sparkle: 'passed inspection', puff: 'a step went back for another try', aside: 'failed', bell: 'needs your sign-off', orderup: 'is handed over' };
const idOf = (e) => e.id || [e.type, e.job, e.ts, e.step ?? ''].join('|');
// events -> new moments (pure): each id once (`seen` is memory only), none over 2 min old or from the future; a
// step.done on a tests step (the order's plan) is ALL PASS (the tests station's mustMatch)
export function momentsFrom(events, seen, now = Date.now(), plans = new Map()) {
  const out = [];
  for (const e of Array.isArray(events) ? events : []) {
    const kind = e && MOMENTS[e.type]; if (!kind) continue;
    const id = idOf(e); if (seen.has(id)) continue;
    seen.add(id); if (seen.size > 2000) seen.delete(seen.values().next().value);
    const t = new Date(e.ts).getTime(); if (!(now - t <= FX.fresh && t <= now + 5000)) continue;
    out.push({ id, kind: kind === 'flip' && plans.get(e.job)?.[e.step]?.station === 'tests' ? 'sparkle' : kind, job: String(e.job || ''), ts: t });
  }
  return out;
}
// tweens (p from 0 to 1)
export const easeOutBack = (p) => 1 + 2.70158 * (p - 1) ** 3 + 1.70158 * (p - 1) ** 2;
export const easeInOutCubic = (p) => (p < 0.5 ? 4 * p * p * p : 1 - (-2 * p + 2) ** 3 / 2);
const clamp01 = (v) => Math.max(0, Math.min(1, v));
export const fxNew = () => ({ seen: new Set(), plans: new Map(), queue: [], live: [], parts: [], after: [], said: -Infinity, line: null, wave: null, hit: null });
const wall = (st) => (st.L?.now ?? 0) + st.t - st.syncT;
// a polite line for the #announce region, at most one per 10 s; ticket numbers only (private orders say nothing more)
const tell = (fx, m, now) => { if (now - fx.said >= FX.say) { fx.said = now; fx.line = `${ticket(m.job)} ${LINE[m.kind]}`; } };
// on each state: new moments queue (the first state of a page only marks what it saw: a reload never replays); reduced motion
// (still) keeps an "after" frame instead: the check over the sink, the banner; the plate already stands on the set-aside shelf
export function fxSync(st, L, first, still) {
  const fx = (st.fx ||= fxNew());
  for (const j of L.src?.jobs || []) if (j?.plan) { fx.plans.set(j.id, j.plan); if (fx.plans.size > 60) fx.plans.delete(fx.plans.keys().next().value); }
  const got = momentsFrom(L.src?.ev, fx.seen, L.now, fx.plans);
  if (first) return;
  if (still) {
    fx.after = [...fx.after.filter((a) => a.until > L.now), ...got.filter((m) => m.kind === 'sparkle' || m.kind === 'orderup').map((m) => ({ ...m, until: L.now + 10000 }))].slice(-FX.atOnce);
    if (got.length) tell(fx, got[got.length - 1], L.now);
    return;
  }
  fx.queue.push(...got);
}
// a stage particle, from one shared pool of at most 48
export function spawn(fx, p) { if (fx.parts.length >= FX.pool) return false; fx.parts.push(p); return true; }
// one tick: hit-stop (Jordan's Approve) freezes the floor for 80 ms; moments end, the queue fills the free slots with fresh ones
export function fxTick(st, dt) {
  const fx = (st.fx ||= fxNew()), now = wall(st);
  if (fx.hit !== null && st.t - fx.hit > 400) fx.hit = null;
  if (fx.wave && st.t > fx.wave.until) fx.wave = null;
  fx.live = fx.live.filter((m) => st.t - m.t0 < LONG[m.kind]);
  while (fx.live.length < FX.atOnce && fx.queue.length) {
    const m = fx.queue.shift(); if (now - m.ts > FX.fresh) continue;   // went stale in the queue (or while the tab was hidden)
    m.t0 = st.t; fx.live.push(m); tell(fx, m, now);
    if (m.kind === 'orderup') for (let i = 0; i < 10; i++) spawn(fx, { x: 140 + i * 2.2, y: 24, vx: (i - 4.5) * 9, vy: -40 - (i % 3) * 12, c: i % 3, t0: st.t });
  }
  fx.parts = fx.parts.filter((p) => st.t - p.t0 < 1200);
  return fx.hit !== null && st.t - fx.hit < FX.hitStop ? 0 : dt;   // the floor's own time step
}
export const fxBusy = (st) => !!st.fx && (st.fx.live.length > 0 || st.fx.queue.length > 0 || st.fx.parts.length > 0 || !!st.fx.wave || st.fx.hit !== null);
export function approveFx(st) { (st.fx ||= fxNew()).hit = st.t; }
export function tapChef(st, key) { (st.fx ||= fxNew()).wave = { key, until: st.t + FX.wave }; }
// how a chef is drawn right now: the anticipation crouch, a hop with a landing squash (its pan flips), or plain
export function chefPose(st, a) {
  if (a.cr > 0) return { name: 'chef-crouch', dy: 0 };
  const m = st.fx?.live.find((x) => x.job === a.key && x.kind === 'flip'); if (!m) return null;
  const e = st.t - m.t0;
  return e < FX.crouch ? { name: 'chef-crouch', dy: 0 } : e < 480 ? { dy: -Math.round(4 * Math.sin(Math.PI * (e - FX.crouch) / 400)) } : e < 560 ? { name: 'chef-squash', dy: 0 } : null;
}
// the pass after Jordan's Approve: a 1 px shake; the bell bounces when a plate needs him
export const passFx = (st) => {
  const fx = st.fx, e = fx?.hit === null || !fx ? Infinity : st.t - fx.hit, b = fx?.live.find((m) => m.kind === 'bell');
  return { dx: e >= FX.hitStop && e < 240 ? (Math.floor(e / 40) % 2 ? 1 : -1) : 0, bell: b ? -Math.round(3 * (1 - easeOutBack(clamp01((st.t - b.t0) / LONG.bell)))) : 0 };
};
// the moments' own sprites (each at most 20 draws; d is drawStage's counted draw)
export function drawFx(st, kit, d, room) {
  const fx = st.fx; if (!fx) return;
  const g = (n) => kit.get(n, room), t = st.t, sink = sx(STATIONS.sink.x), A = st.actors;
  for (const a of fx.after) a.kind === 'sparkle' ? d(g('check'), 0, sink - 3, STAGE.top - 14) : d(g('banner'), 0, 130, 20);
  for (const m of fx.live) {
    const e = t - m.t0, p = clamp01(e / LONG[m.kind]), a = A.get(m.job), ax = a ? a.x : sx(STATIONS.plate.x), ay = a ? a.y : STAGE.aisle;
    if (m.kind === 'flip' && a && e >= FX.crouch) { d(g('pan-flip'), Math.floor((e - FX.crouch) / 100), ax + 4, ay - 30 + (chefPose(st, a)?.dy || 0)); if (e < 400) d(g('flame'), Math.floor(e / 110), ax + 5, ay - 22); }
    if (m.kind === 'sparkle') { for (let i = 0; i < 3; i++) d(g('sparkle'), Math.floor(e / 90) + i, sink - 10 + i * 7, STAGE.top - 12 - (i % 2) * 4); d(g('check'), 0, sink - 3, STAGE.top - 8 - Math.round(6 * easeOutBack(p))); }
    if (m.kind === 'puff') { d(g('puff'), Math.min(3, Math.floor(e / 150)), ax - 4, ay - 34); if (e > 450 && a) d(g('mitt'), 0, ax + 3, ay - 24 + (Math.floor(e / 120) % 2)); }
    if (m.kind === 'aside') {
      const shelf = st.L?.world?.aside?.shelf || [], i = Math.max(0, shelf.indexOf(m.job)), q = easeInOutCubic(p);
      const tx = PLACE.aside[0] + 1 + i * 5, ty = PLACE.aside[1] - 3;
      d(g('smoke-dark'), Math.floor(e / 120), ax - 4, ay - 36);
      d(g('plate-aside'), 0, ax + (tx - ax) * q, ay - 12 + (ty - ay + 12) * q - Math.round(6 * Math.sin(Math.PI * q)));
    }
    if (m.kind === 'orderup') d(g('banner'), 0, 130, Math.round(-12 + 32 * easeOutBack(clamp01(e / 500))));
  }
  for (const pt of fx.parts) { const s = (t - pt.t0) / 1000; d(g('confetti'), pt.c, pt.x + pt.vx * s, pt.y + pt.vy * s + 60 * s * s); }
  if (fx.wave) { const a = A.get(fx.wave.key); if (a) d(g('mitt'), 0, a.x + 6, a.y - 20 - (Math.floor(t / 150) % 2) * 2); }
}
// ---- where things stand ----
// chefs one body (16 px) apart, never sharing a pixel column: each crowd is centred on the stations it wants, inside the floor
export function spread(want, gap = 16, lo = 8, hi = STAGE.exitX - 8) {
  const at = (c) => Math.round(Math.min(hi - (c.ids.length - 1) * gap, Math.max(lo, c.sum / c.ids.length - ((c.ids.length - 1) * gap) / 2)));
  const cl = [];
  for (const i of want.map((_, i) => i).sort((a, b) => want[a] - want[b] || a - b)) {
    cl.push({ ids: [i], sum: want[i] });
    while (cl.length > 1 && at(cl[cl.length - 2]) + cl[cl.length - 2].ids.length * gap > at(cl[cl.length - 1])) { const b = cl.pop(), a = cl.pop(); cl.push({ ids: [...a.ids, ...b.ids], sum: a.sum + b.sum }); }
  }
  const out = []; for (const c of cl) c.ids.forEach((i, k) => { out[i] = at(c) + k * gap; });
  return out;
}
export const chefSpots = (L) => { const xs = spread(L.chefs.map((c) => sx(c.x))); return new Map(L.chefs.map((c, i) => [c.key, xs[i]])); };
// the WORLD props' rectangles on the stage (from the same bake that draws them, plus the heat lamps and the seated sous chef), from sprites.js sizes
export function propRects(world, P) {
  const R = [], S = P?.SPRITES || {};
  if (world) bakeWorld(world, (name, x, y) => S[name] && R.push({ x, y, w: S[name].w, h: S[name].h }));
  for (const h of world?.heat || []) R.push({ x: PLACE.heat[0] + h.i * 11, y: PLACE.heat[1], w: 8, h: 6 });
  if (world?.sous?.here) R.push({ x: PLACE.sous - 8, y: STAGE.front - 26, w: 16, h: 26 });   // the sous chef on his stool
  return R;
}
const hits = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
// speech bubbles: over the chef's head, then higher, then sideways, then on the floor in front of the counter: the first spot that covers no WORLD prop and
// no other bubble; k = CSS px per art px (the bubble is 9 px text: about 5.4 px a letter plus 12 px of padding, 14 px tall)
export function placeSays(items, rects, k = 1.5, W = STAGE.w) {
  const taken = [...rects], lo = -((W - STAGE.w) >> 1), hi = STAGE.w - lo, out = [];
  for (const it of [...items].sort((a, b) => !!b.show - !!a.show)) {   // a tapped chef's first; no free spot: no bubble
    const w = (it.word.length * 5.4 + 12) / k, h = 14 / k, top = STAGE.aisle - 24;
    const spots = [];
    for (const r of [0, 1, 2]) for (const dx of [0, -10, 10, -20, 20]) spots.push([it.x + dx, top - h - r * (h + 1)]);
    for (const r of [0, 1, 2, 3]) for (const dx of [0, -10, 10, -20, 20]) spots.push([it.x + dx, STAGE.aisle + 2 + r * (h + 1)]);
    for (const [cx, y] of spots) {
      const b = { x: Math.max(lo, Math.min(hi - w, cx - w / 2)), y, w, h };
      if (!taken.some((t) => hits(t, b))) { taken.push(b); out.push({ ...it, bx: b.x + w / 2, by: y, rect: b }); break; }
    }
  }
  return out;
}
