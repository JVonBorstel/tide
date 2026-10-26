// The City (the Board's home, God mode): what each building shows (cityOf, pure) and the pixel City drawn from it (paintCity, mountCity).
// Loaded by public/app.js; tested by pass-app/test-city.mjs. Truth rule: every mark comes from one field; a missing field draws nothing.
import { cookOf, stationFor, skyAt, COOK_COLORS, makeLoop } from './scene.js';
import { paletteFor, PALETTE } from './sprites.js';
import { GL, PAINT, WORKER, TOOLS, PALLET, LOCK, FLAG, SKIP, RAMPS, BEACON, CI } from './city-art.js';
import { routeOf, hashOf, upOf, crumbsHtml, gestureTo, attachGestures, cameraMove } from './city-nav.js';

const MS = { min: 6e4, hour: 36e5, day: 864e5 };
const t = (v) => { const n = Date.parse(v); return Number.isFinite(n) ? n : null; };
const NEEDS = (j) => j.status === 'waiting-approval' || j.status === 'needs-human';
// the station a crew stands at, in site words (scene.js stations: board, stove, taste, sink, plate)
export const TOOL = { board: 'survey', stove: 'build', taste: 'inspect', sink: 'test', plate: 'handover' };
export const CAP = { cranes: 3, crews: 3, pallets: 5, cityPx: 80, full: 22, bands: 20 };
// one shared height scale for every tower on a level, so heights compare: the City packs k floors in each 2 px row, the smallest k
// of 1, 2, 5, 10, 20, 50, 100 that keeps the tallest within 80 art px (the Board's City is 136 art px tall); a Tower draws its newest 22 floors whole and older ones in bands of k
const live = (T) => (T?.floors || []).filter((f) => !f.undone);
export function scaleOf(towers) {
  const max = Math.max(0, ...(towers || []).filter((x) => x.kind === 'tower').map((x) => live(x).length));
  return [1, 2, 5, 10, 20, 50, 100].find((k) => Math.ceil(max / k) * 2 <= CAP.cityPx) || 200;
}
export function bandOf(towers) {
  const extra = Math.max(0, ...(towers || []).filter((x) => x.kind === 'tower').map((x) => live(x).length - CAP.full));
  return [5, 10, 20, 50, 100].find((k) => Math.ceil(extra / k) <= CAP.bands) || 200;
}
// a beacon's colour from how long the sign-off has waited: warm, amber at 1 h, red at 4 h
export const beaconOf = (since, now) => { const a = since === null ? 0 : now - since; return a >= 4 * MS.hour ? 'red' : a >= MS.hour ? 'amber' : 'warm'; };
// when Jordan was asked: the newest approval.requested event for that order, else the order's last change
function askedAt(j, ev) {
  for (let i = ev.length - 1; i >= 0; i--) if (ev[i]?.type === 'approval.requested' && ev[i].job === j.id) return t(ev[i].ts);
  return t(j.updated);
}
const crewOf = (j) => ({ id: j.id, cook: cookOf(j), tool: TOOL[stationFor(j)] || 'build', lift: Math.max(0, Math.min(1, (Number(j.step) || 1) / (Number(j.steps) || 1))), private: !!j.private, moving: j.status === 'running' });
// a crane's rank: a sign-off waiting on it, then a crew on it, then red CI, then the newest (the prototype's order)
const craneRank = (c) => (c.beacon ? 8 : 0) + (c.crew ? 4 : 0) + (c.ci === 'red' ? 2 : 0);
const nameOf = (x) => String(x || '').toLowerCase();
// a record about a Tower (main status, freeze, an undo) names its folder or its GitHub name
const isMine = (T, name) => !!name && [T.key, T.folder, String(T.repo || '').split('/')[1]].some((k) => k && nameOf(k) === nameOf(name));

function towerOf(T, s, ev, now, k, opts) {
  const jobs = (s?.jobs || []).filter((j) => j.tower === T.key);
  const floors = live(T); const byJob = new Map(jobs.map((j) => [j.id, j]));
  const cranes = (T.open || []).map((o) => {
    const j = o.job && byJob.get(o.job);
    return { pr: o.pr, ci: ['red', 'pending', 'green'].includes(o.ci) ? o.ci : null, draft: !!o.draft, at: t(o.createdAt) || 0,
      crew: j && j.status === 'running' ? crewOf(j) : null, beacon: j && NEEDS(j) ? beaconOf(askedAt(j, ev), now) : null, job: o.job || null };
  }).sort((a, b) => craneRank(b) - craneRank(a) || b.at - a.at);
  const onCranes = new Set(cranes.map((c) => c.job).filter(Boolean));
  const roof = jobs.filter((j) => j.status === 'running' && !onCranes.has(j.id)).map(crewOf);
  const waits = jobs.filter((j) => NEEDS(j) && !onCranes.has(j.id)).map((j) => askedAt(j, ev)).filter((x) => x !== null).sort((a, b) => a - b);
  const pallets = jobs.filter((j) => j.status === 'pending').length;
  const main = (s?.mainStatus || []).find((m) => isMine(T, m.tower));
  const fz = (s?.freeze?.repos || []).find((r) => isMine(T, r.name));
  const winNow = fz?.windows?.find((w) => t(w.from) <= now && now < t(w.to)); const ahead = fz?.windows?.find((w) => t(w.from) > now);
  const unpushed = new Set((s?.undoUnpushed || []).map((u) => u.job));
  const skip = (T.floors || []).filter((f) => f.undone && now - t(f.undone) < MS.day).map((f) => ({ pr: f.pr || null, job: f.job || null, unknown: !!(f.job && unpushed.has(f.job)) }));
  const lastSeen = t(opts.lastSeen);
  const m = {
    key: T.key, kind: T.kind, name: T.name, floors: floors.length, rows: Math.ceil(floors.length / k),
    lit: floors.filter((f) => t(f.at) <= now && now - t(f.at) < MS.day).length,
    fresh: lastSeen === null ? 0 : floors.filter((f) => t(f.at) > lastSeen).length,
    plinth: T.plinth && Number(T.plinth.commits) > 0 ? Number(T.plinth.commits) : 0,
    publicAt: T.publicFrom ? floors.filter((f) => f.past).length : null,
    blueprint: T.blueprint && T.blueprint.total > 0 ? { total: T.blueprint.total, shipped: T.blueprint.shipped } : null,
    cranes: cranes.slice(0, CAP.cranes), craneMore: Math.max(0, cranes.length - CAP.cranes),
    crews: roof.slice(0, CAP.crews), crewMore: Math.max(0, roof.length - CAP.crews),
    pallets: Math.min(CAP.pallets, pallets), palletMore: Math.max(0, pallets - CAP.pallets),
    beacon: waits.length ? beaconOf(waits[0], now) : null, waiting: waits.length + cranes.filter((c) => c.beacon).length,
    scaffold: main?.state === 'red' ? 'red' : main?.state === 'unreadable' ? '?' : null,
    tape: winNow ? 'now' : null, closes: !winNow && ahead ? String(ahead.fromText || ahead.from) : null,
    skip, manual: !!(s?.automergePause && t(s.automergePause.until) > now && cranes.length),
  };
  if (T.kind === 'lot') Object.assign(m, { floors: 0, rows: 0, lit: 0 });
  if (T.kind === 'office') m.lit = t(T.lastCommit) !== null && now - t(T.lastCommit) < MS.day && t(T.lastCommit) <= now ? 1 : 0;
  return m;
}
// the gate, the cabin and the GitHub sign (by the gate)
function gateOf(s, towers, ev, now) {
  const g = { paused: typeof s?.paused === 'boolean' ? s.paused : null, live: !!s?.live, breaker: !!s?.breaker, stalled: !!s?.stalled, budget: null, github: null };
  const b = Number(s?.budget); const sp = Number(s?.spent);
  if (b > 0 && Number.isFinite(sp)) g.budget = { level: Math.max(0, Math.min(8, Math.floor(8 * sp / b))), stop: ev.some((e) => e?.type === 'budget.stop' && new Date(e.ts).toDateString() === new Date(now).toDateString()) };
  const at = t(s?.githubAt ?? towers?.githubAt); const err = towers?.githubError || null; const age = at === null ? null : Math.max(0, now - at);
  if (err) g.github = { err: true, text: at === null ? 'GitHub read failed' : `GitHub read failed; showing the read from ${Math.round(age / MS.min)} min ago` };
  else if (age !== null && age > 10 * MS.min) g.github = { err: false, text: `GitHub read ${age < MS.hour * 2 ? Math.round(age / MS.min) + ' min' : Math.round(age / MS.hour) + ' h'} ago` };
  return g;
}
// cityOf: the whole City at one moment. towers = GET /api/towers; s = the live state; ev = recent events; opts.lastSeen = the phone's last look
export function cityOf(towers, s, ev = [], now = Date.now(), opts = {}) {
  const list = Array.isArray(towers?.towers) ? towers.towers : []; const k = scaleOf(list);
  const keys = new Set(list.map((x) => x.key)); const yard = (s?.jobs || []).filter((j) => !j.tower || !keys.has(j.tower));
  const lots = list.map((T) => towerOf(T, s, ev || [], now, k, opts));
  const yw = yard.filter(NEEDS).map((j) => askedAt(j, ev || [])).filter((x) => x !== null).sort((a, b) => a - b);
  return {
    k, band: bandOf(list), sky: skyAt(new Date(now).getHours()), lots, gate: gateOf(s, towers, ev || [], now),
    yard: { running: yard.filter((j) => j.status === 'running').length, queued: yard.filter((j) => j.status === 'pending').length,
      waiting: yard.filter(NEEDS).length, beacon: yw.length ? beaconOf(yw[0], now) : null, private: yard.some((j) => j.private) },
    loading: !towers, error: towers && towers.ok === false ? String(towers.error || 'the City could not be read') : null,
  };
}
// ---- moments due: only from real changes and events under 2 minutes old; at most 2 at once, one announce line each ----
export const FRESH_MS = 2 * MS.min;
const EVENT_MOMENT = { 'approval.requested': 'beacon-on', 'approval.granted': 'beacon-off', 'merge.undone': 'take-down', 'step.started': 'hoist', 'job.quarantined': 'crate' };
export function momentsDue(prev, next, ev = [], now = Date.now(), jobs = []) {
  const out = []; const was = new Map((prev?.lots || []).map((l) => [l.key, l])); const towerOfJob = new Map(jobs.map((j) => [j.id, j.tower]));
  for (const l of next?.lots || []) {
    const p = was.get(l.key); if (!p || l.kind !== 'tower') continue;
    const n = l.floors - p.floors;
    if (n > 0) out.push({ key: l.key, type: n > 1 ? 'pour' : 'floor', n, say: `${l.name}: ${n > 1 ? `Pour: ${n} floors` : 'floor ' + l.floors}` });
    if (l.cranes.length + l.craneMore > p.cranes.length + p.craneMore) out.push({ key: l.key, type: 'crane', say: `${l.name}: a new crane` });
    if (l.scaffold !== p.scaffold && (l.scaffold === 'red' || p.scaffold === 'red')) out.push({ key: l.key, type: l.scaffold === 'red' ? 'scaffold-up' : 'scaffold-down', say: `${l.name}: main is ${l.scaffold === 'red' ? 'red' : 'green again'}` });
  }
  for (const e of ev || []) {
    const type = EVENT_MOMENT[e?.type]; const at = t(e?.ts); const key = towerOfJob.get(e?.job);
    if (!type || at === null || now - at > FRESH_MS || now < at || !key) continue;
    out.push({ key, type, job: e.job, say: null });
  }
  return out;
}
// the horizon strip on the other tabs: quiet unless something needs Jordan (a beacon, a red main, PAUSED)
export const needsYou = (c) => !!(c && (c.gate.paused || c.yard.waiting || c.lots.some((l) => l.waiting || l.scaffold === 'red')));
// the text twin of the canvas: one sentence per building, numbers only (a screen reader reads these; the canvas is aria-hidden)
const plural = (n, one, many = one + 's') => `${n} ${n === 1 ? one : many}`;
export function sentence(l) {
  if (l.kind === 'office') return `${l.name}: the Office${l.lit ? ', a commit in the last day' : ''}`;
  if (l.kind === 'lot') return `${l.name}: a lot${l.plinth ? ' of ' + plural(l.plinth, 'commit') : ''}, no floors yet`;
  const bits = [plural(l.floors, 'floor')];
  const crane = l.cranes.length + l.craneMore; if (crane) bits.push(`${crane} under construction`);
  if (l.lit) bits.push(`${l.lit} new today`);
  const crew = l.crews.length + l.crewMore + l.cranes.filter((c) => c.crew).length; if (crew) bits.push(plural(crew, 'crew') + ' at work');
  if (l.waiting) bits.push(plural(l.waiting, 'sign-off') + ' waiting');
  if (l.scaffold === 'red') bits.push('main is red'); if (l.tape) bits.push('site closed'); else if (l.closes) bits.push('closes ' + l.closes);
  return `${l.name}: ${bits.join(', ')}`;
}

// ---- drawing: one pixel buffer per frame, put on the canvas with one drawImage (far under the stage's 120 draws) ----
export const ART = { H: 136, GROUND: 122, tw: 26, lobby: 3, level: 4, plinthDiv: 20, mast: 9, jib: 13 };
const SLOT = { gate: 30, yard: 24, tower: 36, lot: 22, office: 28 };
export const minWidth = (c) => 2 + SLOT.gate + SLOT.yard + (c?.lots || []).reduce((n, l) => n + (SLOT[l.kind] || 24), 0);
// left to right: the gate and cabin, the Yard lot, then every building in its fixed order; the spare width is shared out
export function layoutCity(c, W) {
  const items = [{ kind: 'gate', key: 'gate' }, { kind: 'yard', key: 'yard' }, ...(c?.lots || []).map((l) => ({ kind: l.kind, key: l.key, l }))];
  const min = items.reduce((n, it) => n + (SLOT[it.kind] || 24), 0); const gap = Math.max(0, Math.floor((W - min) / items.length)); let x = Math.max(0, Math.floor((W - min - gap * items.length) / 2));
  for (const it of items) { it.w = SLOT[it.kind] || 24; it.x = x + (gap >> 1); it.slot = [x, x + it.w + gap]; x += it.w + gap; }
  return items;
}
const pack = (h) => { const n = parseInt(String(h).slice(1), 16); return ((255 << 24) | ((n & 255) << 16) | (n & 0xff00) | (n >> 16)) >>> 0; };
// the palette for the hour (sprites.js paletteFor: the sky in X Y Z, the dusk and night tint) and one per crew colour
export function palettes(sky) {
  const p = { ...paletteFor({ sky }), ...PAINT }; const out = {}; for (const k of Object.keys(p)) out[k] = pack(p[k]);
  out.crew = {}; for (const [n, c] of Object.entries(COOK_COLORS)) { const q = paletteFor({ sky, cook: c }); out.crew[n] = { 4: pack(q[4]), 5: pack(q[5]), 6: pack(q[6]), 2: pack(q[2]) }; }
  out.sky = [p.X, p.Y, p.Z]; out.night = sky === 'night' || sky === 'dusk'; return out;
}
// a painter over one buffer: P pixel, R rect, S sprite rows (map = palette overrides), T text (3x5 glyphs)
export function painter(W, H, pal) {
  const buf = new Uint32Array(W * H);
  const P = (x, y, k) => { if (k === '.' || k == null || x < 0 || y < 0 || x >= W || y >= H) return; buf[y * W + x] = typeof k === 'number' ? k : pal[k]; };
  const R = (x, y, w, h, k) => { for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) P(x + i, y + j, k); };
  const S = (rows, x, y, map) => rows.forEach((r, j) => [...r].forEach((c, i) => P(x + i, y + j, map && map[c] != null ? map[c] : c)));
  const T = (str, x, y, k) => [...String(str)].forEach((ch, i) => { const g = GL[ch]; if (g) S(g, x + i * 4, y, { a: k }); });
  return { buf, W, H, pal, P, R, S, T, tw: (str) => String(str).length * 4 - 1 };
}
const hash = (s) => { let h = 2166136261; for (const ch of String(s)) { h ^= ch.codePointAt(0); h = Math.imul(h, 16777619); } return h >>> 0; };
function sky(g, hour) {
  const { W, R, P, pal } = g; const G = ART.GROUND; const [X, Y, Z] = pal.sky;
  for (let b = 0; b < 12; b++) { const y0 = Math.floor(G * b / 12), y1 = Math.floor(G * (b + 1) / 12); R(0, y0, W, y1 - y0, pack(b < 6 ? mixHex(X, Y, b / 6) : mixHex(Y, Z, (b - 6) / 6))); }
  if (pal.night) for (let i = 0; i < W / 6; i++) { const r = hash('star' + i); P(r % W, (r >>> 9) % 70, (r >>> 20) & 1 ? 'p' : 'n'); }
  const q = hour >= 7 && hour < 19 ? (hour - 7) / 12 : ((hour + 24 - 19) % 24) / 12; const x = Math.round(8 + (W - 16) * q), y = Math.round(44 - 34 * Math.sin(Math.PI * q));
  if (hour >= 7 && hour < 19) { R(x - 2, y - 3, 5, 7, 't'); R(x - 3, y - 2, 7, 5, 't'); R(x - 1, y - 2, 3, 5, 'I'); } else { R(x - 2, y - 2, 5, 5, 'p'); R(x - 1, y - 3, 3, 7, 'p'); R(x, y - 3, 4, 5, pack(Y)); }
}
const mixHex = (a, b, t) => '#' + [1, 3, 5].map((i) => Math.round(parseInt(a.slice(i, i + 2), 16) * (1 - t) + parseInt(b.slice(i, i + 2), 16) * t).toString(16).padStart(2, '0')).join('');
function street(g) {
  const { W, R, H } = g; const G = ART.GROUND;
  R(0, G, W, 2, 'm'); R(0, G + 2, W, 1, 'l'); R(0, G + 3, W, H - G - 3, 'j'); for (let x = 2; x < W; x += 10) R(x, G + 8, 5, 1, 'n');
}
function crew(g, c, x, feet, step) {
  g.S(WORKER[c.moving ? step : 0], x, feet - 6, g.pal.crew[c.cook] || g.pal.crew.hand);
  g.S(c.private ? LOCK : TOOLS[c.tool] || TOOLS.build, x + 6, feet - 4);
}
function beacon(g, x, y, kind, on) { const k = on ? BEACON[kind] : 'q'; g.R(x, y, 3, 3, k); g.R(x, y + 3, 3, 1, 'a'); if (on) { g.P(x - 1, y + 1, k); g.P(x + 3, y + 1, k); } }
function plus(g, n, x, y) { if (n > 0) { const s = '+' + n; g.R(x - 1, y - 1, g.tw(s) + 2, 7, 'p'); g.T(s, x, y, 'r'); } }
// a tower at the City level: stone base, lobby, rows of k floors (lit windows: merged in the last 24 h), roof, the "public from" line,
// the planned outline, then cranes (one scaffold level each), crews, the beacon, pallets, scaffolding, tape, the skip
function tower(g, it, l, i, c, ph) {
  const { R, P, S } = g; const G = ART.GROUND; const w = ART.tw; const x = it.x + ((it.w - w) >> 1); const [d0, d1, d2] = RAMPS[i % RAMPS.length];
  const pl = l.plinth ? Math.max(1, Math.ceil(l.plinth / ART.plinthDiv)) : 0;
  if (pl) { R(x - 2, G - pl, w + 4, pl, 'k'); R(x - 2, G - pl, w + 4, 1, 'a'); for (let y = G - pl + 1; y < G; y++) for (let xx = x - 1 + (y & 1) * 2; xx < x + w + 2; xx += 4) P(xx, y, 'j'); }
  let y = G - pl - ART.lobby; R(x, y, w, ART.lobby, d1); R(x, y, w, 1, d0); R(x + (w >> 1) - 2, y + 1, 4, 2, 'a');
  const litRows = Math.ceil(l.lit / c.k); const pubRow = l.publicAt === null ? -1 : Math.floor(l.publicAt / c.k);
  for (let r = 0; r < l.rows; r++) {
    y -= 2; R(x, y, w, 2, d1); R(x, y, 1, 2, 'a'); R(x + w - 1, y, 1, 2, 'a'); R(x + 1, y, w - 2, 1, d0);
    const lit = r >= l.rows - litRows; for (let xx = x + 3; xx < x + w - 3; xx += 2) P(xx, y + 1, lit ? 't' : g.pal.night ? 'E' : 'Y');
    if (r === pubRow) for (let xx = x - 2; xx < x + w + 2; xx += 2) P(xx, y + 2, 't');
  }
  R(x, y - 1, w, 1, 'a'); const roof = y - 1;
  if (l.blueprint) { const left = Math.min(10, Math.ceil((l.blueprint.total - l.blueprint.shipped) / c.k)) * 2; for (let yy = roof - left; yy < roof; yy += 2) { P(x, yy, 'h'); P(x + w - 1, yy, 'h'); } for (let xx = x; xx < x + w; xx += 2) P(xx, roof - left, 'h'); }
  if (l.fresh) S(FLAG, x + 1, roof - 5);
  if (l.scaffold) { R(x - 2, roof, 1, 6, 'h'); R(x + w + 1, roof, 1, 6, 'h'); for (let xx = x - 2; xx <= x + w + 1; xx++) P(xx, roof + 2, ((xx >> 1) & 1) ? 'a' : 't'); if (l.scaffold === '?') g.T('?', x + w + 3, roof, 'a'); }
  let top = roof;
  l.cranes.slice().reverse().forEach((cr) => {
    top -= ART.level; R(x, top + ART.level - 1, w, 1, 'l'); for (const cx of [x + 1, x + (w >> 1), x + w - 2]) R(cx, top, 1, ART.level - 1, cr.draft ? 'n' : 'm');
    if (cr.ci) R(x + w + 1, top + 1, 2, 2, CI[cr.ci]); if (cr.beacon) beacon(g, x + w - 4, top - 4, cr.beacon, ph.blink); if (cr.crew) crew(g, cr.crew, x + 2, top + ART.level - 2, ph.step);
  });
  if (l.cranes.length) {   // the crane: mast at the right, jib to the left; parked (no load) when the Yard is paused
    const mx = x + w - 6, jy = top - ART.mast; R(mx, jy, 2, top - jy, 'H'); for (let yy = jy + 1; yy < top; yy += 3) P(mx, yy, 'G');
    R(Math.max(it.slot[0] + 1, mx - ART.jib), jy, Math.min(it.slot[1] - 2, mx + 6) - Math.max(it.slot[0] + 1, mx - ART.jib), 1, 'G'); R(mx + 3, jy + 1, 3, 2, 'k');
    if (!c.gate.paused) { R(mx - 8, jy + 1, 1, 4, 'a'); R(mx - 9, jy + 5, 3, 1, 'h'); }
    if (l.manual) R(mx - 1, jy + 3, 2, 2, 'p');
    plus(g, l.craneMore, x + 1, jy - 7);
  }
  l.crews.forEach((cw, j) => crew(g, cw, x + 1 + j * 9, top - 1, ph.step)); plus(g, l.crewMore, x + w - 6, top - 14);
  if (l.beacon) beacon(g, x - 3, top - 5, l.beacon, ph.blink);
  for (let j = 0; j < l.pallets; j++) S(PALLET, x + w + 3, G - 3 - j * 3); plus(g, l.palletMore, x + w + 2, G - 22);
  if (l.tape) for (let xx = x - 3; xx <= x + w + 2; xx++) R(xx, G - pl - 5, 1, 2, ((xx + 3) >> 1) & 1 ? 'p' : 'B');
  if (l.closes) { R(x - 3, G - pl - 7, 1, 7, 'a'); R(x - 5, G - pl - 9, 5, 3, 'B'); }
  if (l.skip.length) { S(SKIP, x - 9, G - 4); if (l.skip.some((s) => s.unknown)) g.T('?', x - 8, G - 11, 'a'); }
  return { x, w, top };
}
function lot(g, it, l) {
  const { R, P } = g; const G = ART.GROUND; const x = it.x + 2, w = it.w - 4; const pl = l.plinth ? Math.max(1, Math.ceil(l.plinth / ART.plinthDiv)) : 0;
  if (pl) { R(x, G - pl, w, pl, 'k'); R(x, G - pl, w, 1, 'a'); for (let y = G - pl + 1; y < G; y++) for (let xx = x + 1 + (y & 1) * 2; xx < x + w - 1; xx += 4) P(xx, y, 'j'); }
  for (let xx = x; xx < x + w; xx += 3) R(xx, G - pl - 5, 1, 5, 'h'); R(x, G - pl - 5, w, 1, 'h');
  R(x + 3, G - pl - 13, 1, 8, 'c'); R(x + 1, G - pl - 15, 11, 6, 'a'); R(x + 2, G - pl - 14, 9, 4, 'o');
}
function office(g, it, l) {
  const { R } = g; const G = ART.GROUND; const x = it.x + 1, w = it.w - 2, top = G - 18;
  R(x, top, w, 18, 'a'); R(x + 1, top + 1, w - 2, 17, 'e'); R(x - 1, top - 1, w + 2, 2, 'b');
  for (const yy of [top + 4, top + 10]) for (let xx = x + 3; xx < x + w - 4; xx += 5) { R(xx, yy, 3, 3, 'a'); R(xx + 1, yy + 1, 1, 1, l.lit ? 't' : 'Z'); }
  R(x + w - 6, G - 6, 4, 6, 'c');
}
function gate(g, it, c, ph) {
  const { R, T, P } = g; const G = ART.GROUND; const x = it.x, cy = G - 12; const gt = c.gate;
  R(x + 1, cy, 26, 12, 'a'); R(x + 2, cy + 1, 24, 10, 'o'); R(x + 1, cy - 1, 26, 1, 'g'); R(x + 21, cy + 5, 3, 6, 'c');
  if (gt.budget) { R(x + 10, cy + 2, 10, 7, 'a'); for (let s = 0; s < 8; s++) R(x + 11 + s, cy + 3, 1, 5, s >= gt.budget.level ? 'j' : s < 4 ? 'v' : s < 6 ? 's' : 'B'); if (gt.budget.stop) R(x + 13, cy + 5, 4, 4, 't'); }
  if (gt.paused !== null) { const word = gt.paused ? 'PAUSED' : 'OPEN'; R(x, cy - 13, 28, 9, 'a'); R(x + 1, cy - 12, 26, 7, 'D'); T(word, x + 1 + ((26 - g.tw(word)) >> 1), cy - 11, gt.paused ? 'B' : gt.live ? 't' : 'n'); }
  if (gt.breaker) { R(x + 2, cy + 8, 7, 3, 'B'); P(x + 4, cy + 9, 'p'); P(x + 6, cy + 9, 'p'); }
  R(x + 4, cy + 2, 5, 5, 'p'); R(x + 6, cy + 3, 1, 2, 'a'); if (!gt.stalled) R(x + 6, cy + 4, 2, 1, 'a');   // the site clock (stopped: one hand)
  if (gt.github) { const s = gt.github.err ? 'GH!' : 'GH'; const bw = g.tw(s) + 4, by = G - 34; R(x + 3, by + 8, 1, 4, 'f'); R(x + 1, by, bw, 8, 'a'); R(x + 2, by + 1, bw - 2, 6, gt.github.err ? 'B' : 't'); T(s, x + 3, by + 2, gt.github.err ? 'p' : 'a'); }
}
function yard(g, it, c, ph) {
  const { R, S } = g; const G = ART.GROUND; const x = it.x + 1, w = 20, top = G - 13; const y = c.yard;
  R(x, top, w, 13, 'a'); R(x + 1, top + 1, w - 2, 12, 'n'); R(x + 3, top + 4, 14, 9, 'a'); for (let yy = top + 5; yy < G; yy += 2) R(x + 4, yy, 12, 1, 'h');
  for (let i = 0; i < Math.min(3, y.running); i++) S(WORKER[0].slice(0, 3), x + 4 + i * 4, top + 7, g.pal.crew.hand);
  for (let i = 0; i < Math.min(5, y.queued); i++) S(PALLET, x + w + 1, G - 3 - i * 3);
  if (y.beacon) beacon(g, x + w - 5, top - 5, y.beacon, ph.blink); if (y.private) S(LOCK, x + 1, top - 6);
}
// the whole City into a fresh buffer; ph = { blink, step, focus } (blink and step still under reduced motion: the beacon steady and lit;
// focus: the building the route is on, marked at once so a tap feels instant)
export function paintCity(c, W, hour, ph = { blink: 1, step: 0 }, pal = palettes(c.sky)) {
  const g = painter(W, ART.H, pal); sky(g, hour); const items = layoutCity(c, W); const boxes = {};
  let i = 0;
  for (const it of items) {
    if (it.kind === 'gate') gate(g, it, c, ph); else if (it.kind === 'yard') yard(g, it, c, ph);
    else if (it.kind === 'tower') boxes[it.key] = tower(g, it, it.l, i++, c, ph); else if (it.kind === 'lot') lot(g, it, it.l); else if (it.kind === 'office') office(g, it, it.l);
  }
  street(g);
  const f = items.find((it) => it.key === ph.focus);
  if (f) { for (let y = 8; y < ART.GROUND; y += 2) { g.P(f.slot[0], y, 't'); g.P(f.slot[1] - 1, y, 't'); } g.R(f.x + (f.w >> 1) - 3, ART.GROUND + 1, 7, 1, 't'); }
  return { g, items, boxes };
}
// the horizon strip (40 CSS px on the other tabs): every building's height on one scale, a lit top for today's floors, a beacon, red
// tape for a red main, PAUSED at the left; quiet (no beacon, no tape, no word) when nothing needs Jordan
export function paintStrip(c, W, ph = { blink: 1 }, pal = palettes(c.sky)) {
  const g = painter(W, 20, pal); const [X, Y] = pal.sky; g.R(0, 0, W, 10, pack(X)); g.R(0, 10, W, 9, pack(Y)); g.R(0, 19, W, 1, 'k');
  const max = Math.max(1, ...c.lots.map((l) => l.floors)); if (c.gate.paused) { g.R(1, 6, 27, 9, 'a'); g.T('PAUSED', 2, 8, 'B'); }
  let x = 34;
  for (const l of c.lots) {
    const w = l.kind === 'tower' ? 7 : 5, h = l.kind === 'tower' ? Math.max(2, Math.round(15 * l.floors / max)) : l.kind === 'office' ? 4 : 1;
    if (x + w > W) break;
    g.R(x, 19 - h, w, h, 'g'); g.R(x, 19 - h, w, 1, 'a'); if (l.lit && l.kind === 'tower') g.R(x + 1, 20 - h, w - 2, 1, 't');
    if (l.waiting) g.R(x + 2, 15 - h, 3, 3, ph.blink ? 's' : 'q'); if (l.scaffold === 'red') for (let j = 0; j < w; j++) g.P(x + j, 21 - h, j & 1 ? 'a' : 't');
    x += w + 8;
  }
  if (c.yard.waiting) g.R(30, 12, 3, 3, 's');
  return g;
}

// ---- in the page: the City at the top of the Board tab, the strip under the header on the other tabs ----
// o: { home, strip, names, cap, api, get: () => ({ s, ev, view, lastSeen }), legend(html), go(hash) }. The canvas is aria-hidden; the
// names row and the caption carry the words. Drawn only while seen; one still frame (redrawn each minute) under reduced motion.
const reducedMotion = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
export function legendRows(c) {
  if (!c || c.loading) return [];
  const any = (f) => c.lots.some(f); const rows = [[`1 row = ${c.k} ${c.k === 1 ? 'floor' : 'floors'}: one merged PR is one floor`, true],
    ['Stone base: the commits before the records (1 row = 20 commits)', any((l) => l.plinth)], ['Yellow windows: merged in the last 24 h', any((l) => l.lit && l.kind === 'tower')],
    ['Dashed line: public from here up', any((l) => l.publicAt !== null)], ['Dashed outline: planned floors (Blueprint)', any((l) => l.blueprint)],
    ['A level on the roof: an open PR (grey: a draft); its tag is CI (red, amber pending, green)', any((l) => l.cranes.length)], ['Hard hats: crews at work (the colour is the crew)', any((l) => l.crews.length || l.cranes.some((x) => x.crew))],
    ['Pallets at the base: queued work orders', any((l) => l.pallets)], ['Beacon: a sign-off waiting (amber after 1 h, red after 4 h)', any((l) => l.beacon || l.cranes.some((x) => x.beacon)) || c.yard.beacon],
    ['Scaffolding and tape: main is red ("?": its record cannot be read)', any((l) => l.scaffold)], ['Striped barrier: site closed now; red flag: it closes soon', any((l) => l.tape || l.closes)],
    ['Skip: a floor taken down in the last day', any((l) => l.skip.length)], ['Flag on a roof: new floors since you last looked', any((l) => l.fresh)],
    ['Gate sign: PAUSED or OPEN (lit: AI crews on)', c.gate.paused !== null], ['Meter on the cabin: today\'s spend against the cap', !!c.gate.budget],
    ['GH sign: GitHub was last read a while ago, or the read failed', !!c.gate.github], ['Workshop by the gate: work orders with no Tower', c.yard.running + c.yard.queued + c.yard.waiting > 0]];
  return rows.filter((r) => r[1]).map((r) => r[0]);
}
export function mountCity(o) {
  const M = { towers: null, v: null, busy: false, c: null, key: '', canvas: null, visible: true, failed: null, r: routeOf(''), items: [], W: 1, depth: 0, moving: false };
  const ctx2d = (cv) => { const x = cv.getContext('2d'); x.imageSmoothingEnabled = false; return x; };
  function blit(cv, g, scale, dpr) {
    if (cv.width !== g.W * scale || cv.height !== g.H * scale) { cv.width = g.W * scale; cv.height = g.H * scale; cv.style.width = g.W * scale / dpr + 'px'; cv.style.height = g.H * scale / dpr + 'px'; }
    const off = document.createElement('canvas'); off.width = g.W; off.height = g.H; const ox = off.getContext('2d'); const img = ox.createImageData(g.W, g.H);
    new Uint32Array(img.data.buffer).set(g.buf); ox.putImageData(img, 0, 0); ctx2d(cv).drawImage(off, 0, 0, g.W * scale, g.H * scale);
  }
  function fetchTowers() {
    M.busy = true;
    o.api('/api/towers').then((r) => { if (r?.ok) { M.towers = r; M.failed = null; } else M.failed = r?.error || 'the City could not be read'; }).finally(() => { M.busy = false; M.key = ''; update(); });
  }
  function frame() {
    if (M.moving) return;
    const { s, ev, view, lastSeen } = o.get(); const now = Date.now(); const rm = reducedMotion(); const rt = M.r;
    const c = M.c = cityOf(M.towers, s, ev || [], now, { lastSeen }); const ph = { blink: rm ? 1 : Math.floor(now / 500) % 2, step: rm ? 0 : Math.floor(now / 260) % 2 };
    const dpr = globalThis.devicePixelRatio || 1; const home = view === 'pass';
    const key = [home, hashOf(rt), M.v, M.towers?.at && M.c.k, JSON.stringify(c.lots), JSON.stringify(c.gate), JSON.stringify(c.yard), ph.blink, ph.step, Math.floor(now / 6e4), o.home.clientWidth, o.strip.clientWidth].join('|');
    if (key === M.key) return; M.key = key;
    o.strip.hidden = home || !s; o.home.hidden = !home;
    if (home) {
      const box = o.home.clientWidth || 343; const dev = Math.max(200, Math.floor(box * dpr)); const scale = Math.max(1, Math.floor(dev / minWidth(c))); const W = Math.floor(dev / scale);
      const cv = o.home.querySelector('canvas') || o.home.insertBefore(Object.assign(document.createElement('canvas'), { className: 'city-canvas' }), o.home.firstChild); cv.setAttribute('aria-hidden', 'true');
      const p = paintCity(c, W, new Date(now).getHours() + new Date(now).getMinutes() / 60, { ...ph, focus: rt.key }); M.items = p.items; M.W = W; blit(cv, p.g, scale, dpr);
      const cap = c.loading ? (M.failed ? 'The City could not be read: ' + M.failed : 'Reading the City…') : M.failed ? `Showing the last read: ${M.failed}` : c.gate.github ? c.gate.github.text : '';
      const nameOf = (k) => c.lots.find((l) => l.key === k)?.name || (k === 'yard' ? 'Yard lot' : k); const on = c.lots.find((l) => l.key === rt.key);
      const html = crumbsHtml(rt, nameOf, esc) + (on ? `<p class="city-cap">${esc(sentence(on))}</p>` : '') + `<ul class="city-names">${c.lots.map((l) => `<li data-kind="${l.kind}"><a href="#/city/${esc(l.key)}"${l.key === rt.key ? ' aria-current="page"' : ''} aria-label="${esc(sentence(l))}"><b>${esc(l.name)}</b><span aria-hidden="true">${l.kind === 'tower' ? l.floors : l.kind === 'lot' ? 'lot' : 'office'}</span></a></li>`).join('')}</ul>`
        + `<p class="city-cap"${cap ? '' : ' hidden'} role="status">${esc(cap)}</p>` + (!c.loading && !c.lots.length ? '<p class="city-cap">No projects yet: the City fills in as work merges.</p>' : '');
      if (o.names.innerHTML !== html) o.names.innerHTML = html;
    } else if (s && !c.loading) {
      const cv = o.strip.querySelector('canvas') || o.strip.appendChild(Object.assign(document.createElement('canvas'), { className: 'city-canvas' })); cv.setAttribute('aria-hidden', 'true');
      const W0 = Math.floor((o.strip.clientWidth || 343) * dpr); const scale = Math.max(1, Math.floor(40 * dpr / 20)); blit(cv, paintStrip(c, Math.floor(W0 / scale), ph), scale, dpr);
      o.strip.classList.toggle('needs', needsYou(c)); o.strip.setAttribute('aria-label', needsYou(c) ? 'The City: something needs you. Open the Board' : 'The City: all quiet. Open the Board');
    }
  }
  const loop = makeLoop({ raf: (f) => requestAnimationFrame(f), fps: () => (M.c && (needsYou(M.c) || M.c.lots.some((l) => l.crews.length || l.cranes.some((x) => x.crew || x.beacon)) || M.c.yard.beacon) ? 10 : 1),
    ok: () => !document.hidden && !reducedMotion() && M.visible, frame });
  // a new route: the camera moves toward the building (in) or away from it (out), then the new level is drawn crisp
  function follow() {
    const r = routeOf(location.hash); const was = M.r; if (hashOf(r) === hashOf(was)) return;
    if (r.level !== was.level) M.depth = r.level > was.level ? M.depth + 1 : Math.max(0, M.depth - 1); M.r = r;
    const it = M.items.find((x) => x.key === (r.key || was.key)); const cv = o.home.querySelector('canvas');
    if (o.get().view !== 'pass' || !it || !cv || r.level === was.level) { M.key = ''; return; }
    M.moving = true; cameraMove(cv, (it.x + it.w / 2) / M.W, r.level > was.level, reducedMotion(), () => { M.moving = false; M.key = ''; frame(); });
  }
  // one level up: Back where the City put the level above in the history, else that level in its place
  const up = () => { const u = hashOf(upOf(M.r)); if (M.depth > 0) history.back(); else location.replace(u); };
  function update() {
    follow(); const s = o.get().s; const v = s?.towersV ?? null; if (v && v !== M.v && !M.busy) { M.v = v; fetchTowers(); }
    frame(); loop.start();
  }
  o.strip.addEventListener('click', () => o.go('#/pass'));
  const hitAt = (x) => M.items.find((it) => x * M.W >= it.slot[0] && x * M.W < it.slot[1])?.key || null;
  attachGestures(o.home, { at: hitAt, buzz: o.buzz, onLong: o.onLong, onGesture: (g) => { if (g.gesture === 'pinch-in' || (g.gesture === 'tap' && hitAt(g.at) === M.r.key)) { if (g.gesture === 'pinch-in' && M.r.level) up(); return; } const to = gestureTo(g, M.r, hitAt(g.at), M.c.lots.map((l) => l.key)); if (to && to.level === M.r.level) location.replace(hashOf(to)); else if (to) o.go(hashOf(to)); } });   // a sideways move replaces the route: Back still zooms out
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && M.r.level && o.get().view === 'pass' && !document.querySelector('dialog[open]')) up(); });
  o.cap?.addEventListener('click', () => o.legend(`<ul class="city-legend">${legendRows(M.c).map((r) => `<li>${esc(r)}</li>`).join('')}</ul>`));
  if (typeof IntersectionObserver === 'function') new IntersectionObserver((es) => { M.visible = es.some((e) => e.isIntersecting); if (M.visible) loop.start(); }).observe(o.home);
  if (typeof ResizeObserver === 'function') new ResizeObserver(() => { M.key = ''; frame(); }).observe(o.home);
  setInterval(() => { if (reducedMotion()) { M.key = ''; frame(); } }, 60000);
  return { update, model: () => M.c, route: () => M.r };
}
