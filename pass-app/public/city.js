// The City (the Board's home, God mode): what each building shows, from /api/towers plus the live state and events (cityOf, pure).
// Loaded by public/app.js; tested by pass-app/test-city.mjs. Truth rule: every mark comes from one field; a missing field draws nothing.
import { cookOf, stationFor, skyAt } from './scene.js';

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
