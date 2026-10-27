// The Board's scene (pass-app/SCENE.md): the Yard as a small building site on the Board and Live tabs: a crew member per work order at the
// station its step needs, work-order cards on the job board, runners at the sign-off window, a window sky that follows the hour.
// Fallback: a still card (no animation, at most 25 KB of markup; checked by pass-app/test-scene.mjs) until sprites.js loads, or for good
// if it cannot. The pixel stage (SCENE.md): once sprites.js loads, layoutScene drives a canvas; frame.js runs its loop, moments.js its
// moments. Private work orders show no words anywhere.
import { WORLD, worldOf, worldWords, legendRows, legendHtml, PLACE, worldKey, bakeWorld, plural } from './world.js';
import { stageOk, makeLoop, at, tk, due, CLOCK, stageDirty, stageWait, METER, frameStats } from './frame.js';
import { markItems, nightShift } from './purpose.js';
import { fxSync, fxTick, drawFx, chefPose, passFx, chefSpots, propRects, placeSays, approveFx, tapChef, FX } from './moments.js';
export { makeLoop, frameStats };
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const ticket = (id) => 'WO-' + String(id || '').replace(/^J/, '').padStart(4, '0');
const r1 = (n) => Math.round(n * 10) / 10;
// Inline styles under a strict CSP (style-src 'self', no 'unsafe-inline'): a browser drops a style attribute written in markup, but styles
// set from script are allowed. So markup carries data-css="name:value;..." and applyCss copies each one in with
// style.setProperty. An element is styled once per data-css value (a later script move is never undone).
// The scene calls it as it inserts; app.js also runs it on every node any renderer adds (a MutationObserver).
export function applyCss(root) {
  if (!root || root.nodeType !== 1) return;
  for (const el of [root, ...root.querySelectorAll('[data-css]')]) {
    const css = el.getAttribute('data-css'); if (css === null || el._css === css) continue; el._css = css;
    for (const d of css.split(';')) { const i = d.indexOf(':'); if (i > 0) el.style.setProperty(d.slice(0, i).trim(), d.slice(i + 1).trim()); }
  }
}

// ---- where things are (a 400-wide room; sx() puts it on the 192-pixel stage). Code names stay (board, stove ...); labels are site words ----
export const STATIONS = {
  board: { x: 44, label: 'Survey table' },
  stove: { x: 104, label: 'Workbench' },
  taste: { x: 164, label: 'Inspection desk' },
  sink: { x: 224, label: 'Test rig' },
  plate: { x: 284, label: 'Handover bay' },
};
const CHEF_Y = 174, WAITER_Y = 204, PASS_X = 334, RAIL_X = 104, RAIL_W = 196;
const STEP_AT = {
  plan: 'board', map: 'board', research: 'board', worktree: 'board', diagnose: 'board', slice: 'board', talk: 'board', ask: 'board', scout: 'board',
  do: 'stove', build: 'stove', repair: 'stove', check: 'taste', review: 'taste', tests: 'sink', lint: 'sink', mutate: 'sink', verify: 'sink',
  commit: 'plate', freshen: 'plate', merge: 'plate', ideas: 'plate', 'pack-render': 'plate', inventory: 'plate',
};
export const COOK_COLORS = { claude: '#d97757', gemini: '#4f8cf7', antigravity: '#a46cf0', local: '#3fa66b', sous: '#d6a531', hand: '#8b939e' };

const stepKey = (j) => String((j?.station === 'agent' ? j.role : j?.station) || '').toLowerCase();
export function stationFor(j) { return STEP_AT[typeof j === 'string' ? j.toLowerCase() : stepKey(j)] || 'stove'; }
export function cookOf(j) {
  const c = String(j?.cook || j?.supplier || '').split(' ')[0].toLowerCase();
  return COOK_COLORS[c] && c !== 'hand' ? c : j?.station === 'agent' ? 'sous' : 'hand';
}
export function hashId(id) { let h = 2166136261; for (const ch of String(id || '')) { h ^= ch.codePointAt(0); h = Math.imul(h, 16777619); } return h >>> 0; }
const SKIN = ['#f6d5bd', '#eab98f', '#d39a6a', '#b0784c', '#8a5634', '#5e3a22'];
// the same order always looks the same; different orders mostly look different
export function lookOf(id) { const h = hashId(id); return { skin: SKIN[h % SKIN.length], hat: 6 + ((h >>> 4) % 4) * 1.5, stache: ((h >>> 8) & 3) === 0, delay: ((h >>> 11) % 40) / 10 }; }
export function skyAt(hour) { return hour >= 5 && hour < 8 ? 'dawn' : hour >= 8 && hour < 18 ? 'day' : hour >= 18 && hour < 21 ? 'dusk' : 'night'; }

const STEP_WORD = { plan: 'planning', do: 'building', build: 'building', check: 'inspecting', review: 'inspecting', research: 'researching', talk: 'chatting', diagnose: 'diagnosing',
  tests: 'testing', repair: 'fixing it', commit: 'saving', freshen: 'resurveying', merge: 'handing over', map: 'mapping', worktree: 'setting up', lint: 'checking',
  mutate: 'testing hard', verify: 'double-checking', slice: 'splitting up' };
const TOOL_WORD = { edit: 'Editing', write: 'Editing', multiedit: 'Editing', notebookedit: 'Editing', read: 'Reading', bash: 'Running', shell: 'Running', powershell: 'Running',
  grep: 'Searching', glob: 'Searching', websearch: 'Searching', webfetch: 'Fetching', task: 'Delegating', agent: 'Delegating' };
// the cook's latest tool use as a short phrase ("Editing app.js", "Running tests"); a private order gives the tool word only, never the target
export function activityWord(j) {
  const a = Array.isArray(j?.activity) ? j.activity[j.activity.length - 1] : null;
  if (!a || typeof a !== 'object') return '';
  const word = TOOL_WORD[String(a.tool || '').toLowerCase()] || (a.tool ? 'Using ' + String(a.tool) : '');
  if (!word || j.private) return word;
  const target = String(a.target || '');
  if (word === 'Running' && /\b(tests?|pester|jest|pytest)\b|Test-/i.test(target)) return 'Running tests';
  const base = target.split(/[\\/]/).pop().slice(0, 40);
  return base && word !== 'Running' ? word + ' ' + base : word;
}
const doing = (j) => activityWord(j) || STEP_WORD[stepKey(j)] || 'working';
// what a step is, in site words ("inspecting" at the Inspection desk, "testing" at the Test rig); the Board's crew cards use it too
export const stepWord = (j) => STEP_WORD[stepKey(j)] || 'working';

// ---- what is on the floor right now (pure: tested in node) ----
export function layoutScene(s, events = [], opts = {}, now = Date.now()) {
  const jobs = s?.jobs || [];
  const compact = !!opts.compact;
  // on the floor: running, or between two steps of a work order already started (so a crew member does not walk out and back every step)
  const line = jobs.filter((j) => j.status === 'running' || (j.status === 'pending' && (j.step || 1) > 1));
  const queued = jobs.filter((j) => j.status === 'pending' && (j.step || 1) <= 1);
  const onFloor = line.slice(0, compact ? 4 : 6);
  const at = {};
  for (const j of onFloor) (at[stationFor(j)] ||= []).push(j.id);
  const chefs = onFloor.map((j) => {
    const st = stationFor(j), ids = at[st], k = ids.indexOf(j.id), n = ids.length;
    const x = STATIONS[st].x + (n > 1 ? (k - (n - 1) / 2) * Math.min(17, 40 / (n - 1)) : 0);
    const priv = !!j.private, act = priv ? '' : (j.status === 'running' ? doing(j) : 'next: ' + (STEP_WORD[stepKey(j)] || 'a step')).slice(0, 22);
    return { key: j.id, id: j.id, x: r1(x), y: CHEF_Y, st, slot: k, cook: cookOf(j), look: lookOf(j.id), busy: j.status === 'running', priv, act, word: compact ? '' : act,
      label: `${ticket(j.id)} ${priv ? 'a private work order' : j.status === 'running' ? doing(j) : 'between steps'}, open it` };
  });
  const rail = [...line, ...queued].slice(0, 8);
  const gap = Math.min(28, RAIL_W / Math.max(1, rail.length));
  const tickets = rail.map((j, i) => ({ key: j.id, id: j.id, x: r1(RAIL_X + 12 + i * gap), step: j.step || 1, steps: j.steps || 1, queued: !line.includes(j) }));
  const waiting = jobs.filter((j) => j.status === 'waiting-approval' || j.status === 'needs-human');
  const waiters = waiting.slice(0, 3).map((j, i) => ({ key: 'w' + j.id, id: j.id, x: PASS_X + i * 21, y: WAITER_Y, label: `${ticket(j.id)} needs your sign-off, open it` }));
  const runners = (events || []).filter((e) => e && e.type === 'job.done' && now - new Date(e.ts).getTime() < 3 * 60 * 1000).slice(-2)
    .map((e) => ({ key: `o${e.job}@${e.ts}`, id: e.job }));
  const busy = {}; for (const c of chefs) if (c.busy) busy[c.st] = true;
  const world = worldOf(s, events, now), ww = worldWords(world);
  return { compact, now, src: { ev: events, jobs }, sky: skyAt(new Date(now).getHours()), chefs, tickets, waiters, runners, busy, pass: waiting.length, idle: !chefs.length, world,
    queue: line.length + queued.length, summary: `${chefs.length} building, ${waiting.length} waiting for your sign-off${ww ? '; ' + ww : ''}` };
}

// ---- the still card: shown until sprites.js loads, or for good if it cannot (no canvas, offline before the first visit) ----
// No people and no motion: the same links as the pixel stage (crew, work-order cards on the job board, runners at the sign-off window)
// and the same words, so a screen reader and a phone without the art still get the whole picture.
const link = (cls, id, key, label, inner, css = '') => `<a class="${cls}" href="#/job/${esc(id)}" data-key="${esc(key)}" aria-label="${esc(label)}"${css ? ` data-css="${css}"` : ''}>${inner}</a>`;
const woNo = (id) => `<b>${esc(ticket(id).slice(3))}</b>`;
function cardHtml(L) {
  const row = (cls, title, items) => (items.length ? `<div class="sc-row ${cls}"><span class="sc-h">${title}</span>${items.join('')}</div>` : '');
  const crew = L.chefs.map((c) => link(`sc-crew cook-${c.cook}`, c.id, c.key, c.label + (c.priv || c.cook === 'hand' || c.cook === 'sous' ? '' : ', crew ' + c.cook),
    `${woNo(c.id)} ${STATIONS[c.st].label}${c.word ? ` <i>${esc(c.word)}</i>` : ''}`, `--cook:${COOK_COLORS[c.cook]}`));
  const cards = L.tickets.map((t) => link(`sc-card${t.queued ? ' queued' : ''}`, t.id, t.key, `${ticket(t.id)}, open it`, `${woNo(t.id)} <i>${t.queued ? 'next up' : `${Number(t.step)}/${Number(t.steps)}`}</i>`));
  const wait = L.waiters.map((w) => link('sc-wait', w.id, w.key, w.label, `${woNo(w.id)} <i>sign off</i>`));
  const done = L.runners.map((r) => link('sc-done', r.id, r.key, `${ticket(r.id)} handed over, open it`, `${woNo(r.id)} <i>handed over</i>`));
  return `<div class="scene-stage scene-card${L.compact ? ' compact' : ''}" role="group" aria-label="${esc(L.summary)}"><p class="sc-sum" aria-hidden="true">${esc(L.summary)}</p>`
    + (L.idle ? '<p class="sc-idle" data-key="idle">Nothing building.</p>' : row('sc-crews', 'Crew', crew))
    + row('sc-board', 'Job board', cards) + row('sc-signoff', 'Sign-off window', wait.concat(L.pass > 3 ? [`<span class="sc-more">+${L.pass - 3}</span>`] : [])) + row('sc-out', 'Handed over', done) + '</div>';
}
// the whole scene as markup (first paint, tests and old callers)
export function sceneHtml(s, events, opts = {}, now = Date.now()) { return s ? cardHtml(layoutScene(s, events, opts, now)) : ''; }
// the pixel stage once sprites.js has loaded; the still card until then (rebuilt only when its words change: nothing in it moves)
export function mountScene(el, s, events, opts = {}) {
  if (!el) return;
  if (!s) { dropStage(el._px); el.innerHTML = ''; el._card = null; el._px = null; return; }
  const L = layoutScene(s, events, opts);
  el._args = [s, events, opts]; mounted.add(el);
  if (PX && canvasOk()) { el._card = null; mountPixel(el, L); return; }
  const html = cardHtml(L); dropStage(el._px); el._px = null;
  if (el._card !== html || !el.firstElementChild) { el._card = html; el.innerHTML = html; applyCss(el); }
}

// ---- the pixel stage: layoutScene drives a canvas of sprites.js art (the still card above is the fallback) ----
export const STAGE = { w: 192, h: 112, aisle: 76, front: 108, top: 70, doorX: 9, doorY: 56, exitX: 150, speed: 30, maxDraws: 120 };   // no fps cap: the screen's rate
export const sx = (x) => Math.round(x * 0.48);          // the 400-wide room onto the 192-pixel stage
const TICKET_DX = 5;                                    // work-order cards hang clear of the window
const waiterX = (i) => 146 + i * 15;                    // runners at the sign-off window stand a body apart
const STATION_ART = { board: 'counter', stove: 'stove', taste: 'counter', sink: 'sink', plate: 'pallet' };   // code names: the Survey table, Workbench ...
const PROP = { board: 'board', stove: 'pot', taste: 'bowl', sink: null, plate: 'plates' };
// the largest whole-number scale that fits (crisp: every art pixel is exactly `scale` device pixels), centred on a device pixel;
// w is the room's width in art pixels at that scale (192 to 256): the site sits in the middle, wall and floor fill the sides
export function pixelScale(cssW, dpr = 1, maxCssH = Infinity, w = STAGE.w, h = STAGE.h, maxW = 256) {
  const dev = Math.floor(cssW * dpr); let s = Math.max(1, Math.floor(dev / w));
  while (s > 1 && (h * s) / dpr > maxCssH) s--;
  const room = Math.max(w, Math.min(maxW, Math.floor(dev / s)));   // the room widens to fill the phone (more wall and floor), never the art
  return { scale: s, w: room, cssW: (room * s) / dpr, cssH: (h * s) / dpr, left: Math.max(0, Math.floor((dev - room * s) / 2)) / dpr };
}
// the stage model (pure: tested in node): one actor per crew member and runner (code: chef, waiter), keyed like the card's links, walking along axis paths
// rev counts changes to the picture, drawn is the rev last drawn, next the stage time of the next animation step (frame.js); list holds
// the actors as an array and room the stage's palette, so a frame allocates nothing
export function stageNew() { return { W: STAGE.w, actors: new Map(), list: [], t: 0, syncT: 0, first: true, L: null, played: new Set(), sparks: [], ticks: new Set(), rounds: 0, sousNext: false, rev: 0, drawn: -1, next: Infinity, room: null, night: false }; }
// a palette (skin, crew colour, hair, sky, dim) with its strip-cache key, made once per sync instead of once per draw
const palOf = (o) => { o.pk = [o.skin, o.cook, o.hair, o.sky, !!o.dim].join(); return o; };
const relist = (st) => { st.list.length = 0; for (const a of st.actors.values()) st.list.push(a); };
const sousRound = (st, a) => { a.path = [[PLACE.round, STAGE.front], [PLACE.sous, STAGE.front]]; st.rounds++; };
export function stageSync(st, L, { still = false } = {}) {
  const A = st.actors, seen = new Set(), opening = st.first, first = st.first || still; st.first = false; st.L = L;
  const edgeL = -(((st.W || STAGE.w) - STAGE.w) >> 1) - 16, edgeR = STAGE.w - edgeL;   // just off the (widened) room
  const want = (key, kind, tx, ty, from, extra) => {
    seen.add(key); let a = A.get(key);
    if (!a) { a = { key, kind, x: first ? tx : from[0][0], y: first ? ty : from[0][1], path: first ? [] : [...from.slice(1), [tx, ty]], dir: 'down', flip: false }; A.set(key, a); }
    else { const end = a.path.length ? a.path[a.path.length - 1] : [a.x, a.y]; if (a.leaving || end[0] !== tx || end[1] !== ty) a.path = [[tx, a.y], [tx, ty]]; }
    if (still) { a.x = tx; a.y = ty; a.path = []; }
    a.leaving = false; return Object.assign(a, extra);
  };
  const spots = chefSpots(L); fxSync(st, L, opening, still);
  for (const c of L.chefs) want(c.key, 'chef', spots.get(c.key), STAGE.aisle, [[STAGE.doorX, STAGE.doorY], [STAGE.doorX, STAGE.aisle]], { st: c.st, busy: c.busy, cook: c.cook, look: c.look, hair: (hashId(c.id) >>> 14) % 4 });
  for (const [i, w] of L.waiters.entries()) want(w.key, 'waiter', waiterX(i), STAGE.front, [[edgeL, STAGE.front]], { look: lookOf(w.id + 'w'), hair: hashId(w.id) % 4 });
  if (L.idle) want('idle', 'sleepy', 16, STAGE.front, [[16, STAGE.front]], { look: lookOf('idle') });
  // the Dispatcher (code: sous) walks one lap per new lastTick (on opening the app: only if under 2 min old)
  const sv = L.world?.sous;
  if (sv) {
    const isNew = !st.ticks.has(sv.tick); if (isNew) { if (st.ticks.size > 50) st.ticks.clear(); st.ticks.add(sv.tick); }
    if (sv.here) {
      const a = want('sous', 'sous', PLACE.sous, STAGE.front, [[edgeL, STAGE.front]], { look: lookOf('sous'), cook: 'sous', hair: 1 });
      if (isNew && !still && (!first || sv.fresh)) { if (a.path.length) st.sousNext = true; else sousRound(st, a); }
    }
  }
  st.syncT = st.t;
  for (const r of L.runners) {
    seen.add(r.key); if (st.played.has(r.key)) continue;
    st.played.add(r.key); if (first) continue;   // a page opened later does not replay old news
    A.set(r.key, { key: r.key, kind: 'runner', x: 166, y: STAGE.front, path: [[edgeL, STAGE.front]], dir: 'side', flip: true, leaving: true, look: lookOf(r.id + 'r'), hair: hashId(r.id) % 4 });
    st.sparks.push({ x: 170, y: 30, t: st.t });
  }
  for (const a of [...A.values()]) {
    if (seen.has(a.key) || a.leaving) continue;
    if (still || a.kind === 'sleepy') { A.delete(a.key); continue; }
    a.leaving = true; a.path = a.kind === 'chef' ? [[STAGE.exitX, a.y]] : a.kind === 'sous' ? [[edgeL, a.y]] : [[edgeR, a.y]];   // crew carry the crate to the window, runners walk out, the Dispatcher leaves
  }
  relist(st);
  const sky = L.sky, dim = L.world?.sign?.state === 'closed';
  st.room = palOf({ sky, dim }); st.night = nightShift(L);
  for (const a of st.list) { a.po = palOf({ skin: a.look?.skin, cook: COOK_COLORS[a.cook || 'hand'], hair: a.hair || 0, sky, dim }); a.pz = palOf({ ...a.po, cook: COOK_COLORS.sous }); a.pw = null; }
  st.rev++;
  return st;
}
// one tick of the stage clock; st.rev moves only when the picture does (a whole pixel of walk, a turn, a crouch, an arrival, a leave)
export function stageTick(st, dt) {
  st.t += dt; const step = (STAGE.speed * fxTick(st, dt)) / 1000;   // 0 during the Approve hit-stop
  if (st.list.length !== st.actors.size) relist(st);
  let moved = false, gone = false;
  for (let i = 0; i < st.list.length; i++) {
    const a = st.list[i], x0 = Math.round(a.x), y0 = Math.round(a.y), d0 = a.dir, f0 = a.flip, c0 = a.cr > 0, w0 = a.path.length;
    if (a.path.length && !a.go) { a.go = 1; a.cr = FX.crouch; }   // anticipation: one 80 ms crouch before a walk
    if (a.cr > 0 && step) a.cr -= dt;
    else {
      let left = step;
      while (left > 0 && a.path.length) {
        const p = a.path[0], tx = p[0], ty = p[1], dx = tx - a.x, dy = ty - a.y, d = Math.abs(dx) + Math.abs(dy);
        if (a.path.length === 1 && d < 6) left *= Math.max(0.35, d / 6);   // ease-out on arrival
        if (dx) { a.dir = 'side'; a.flip = dx < 0; } else if (dy) a.dir = dy > 0 ? 'down' : 'up';
        if (d <= left) { a.x = tx; a.y = ty; a.path.shift(); left -= d; } else { if (dx) a.x += Math.sign(dx) * left; else a.y += Math.sign(dy) * left; left = 0; }
      }
      if (!a.path.length) a.go = 0;
      if (!a.path.length && a.leaving) { st.actors.delete(a.key); gone = true; }
      else if (!a.path.length && a.kind === 'sous' && st.sousNext) { st.sousNext = false; sousRound(st, a); }   // a tick that came mid-round
    }
    if (Math.round(a.x) !== x0 || Math.round(a.y) !== y0 || a.dir !== d0 || a.flip !== f0 || a.cr > 0 !== c0 || !a.path.length !== !w0) moved = true;
  }
  if (gone) relist(st);
  let j = 0; for (let i = 0; i < st.sparks.length; i++) if (st.t - st.sparks[i].t < 900) st.sparks[j++] = st.sparks[i];
  if (j < st.sparks.length) { st.sparks.length = j; moved = true; }
  if (moved || gone) st.rev++;
  return st;
}
// sprite strips, cached per palette (skin, cook, hair, sky, dim) and name; mk(w, h) makes a canvas (or a test mock). A palette made by
// palOf carries its key, so a cached look-up builds no string
export function makeKit(P, mk) {
  const c = new Map(); let size = 0;
  return { P, mk, layers: new Map(), get(name, o = {}, flip = false) {
    const k = o.pk ?? [o.skin, o.cook, o.hair, o.sky, !!o.dim].join(); let m = c.get(k);
    if (!m) { if (size > 400) { c.clear(); size = 0; } c.set(k, (m = new Map())); }
    let v = m.get(name); if (!v) m.set(name, (v = [null, null]));
    const i = flip ? 1 : 0; if (!v[i]) { v[i] = P.stripOf(mk, name, P.paletteFor(o), !!flip); size++; }
    return v[i];
  } };
}
const bobOf = (P, anim, f) => { const b = P.BOB[anim]; return b ? b[f % b.length] : 0; };
const CHEF_DIR = { down: 'chef-down', up: 'chef-up', side: 'chef-side' }, WORK = Object.fromEntries(Object.keys(STATIONS).map((k) => [k, 'work-' + k]));
const SX = Object.fromEntries(Object.entries(STATIONS).map(([k, s]) => [k, sx(s.x)]));   // each station's x on the stage
// a work-order card's two digits (the last two of its number), read without building a string
const digit = (id, k) => { for (let i = id.length - 1, n = 0; i >= 0; i--) { const c = id.charCodeAt(i) - 48; if (c >= 0 && c <= 9 && n++ === k) return c; } return 0; };
// the still site, drawn once per sky: the top floor open to the sky (S7i): sky and shores, the guard rail, the slab and its front edge,
// the hoist cage, job board, site cabin, the night work-light pool (back); or the stations, their contact shadows and props (front);
// (the newest bake per sky, dim and width is re-used while its world key holds)
// (the keys are made once per world and per room and width, not once per frame: worldKey is a JSON walk)
const WKEYS = new WeakMap(), wkOf = (w) => { let k = WKEYS.get(w); if (k === undefined) WKEYS.set(w, (k = worldKey(w))); return k; };
function layer(kit, which, room, W = STAGE.w, world = {}) {
  if (room.preW !== W) { const s = room.sky + (room.dim ? '-dim' : '') + W; room.pre = ['bg' + s, 'fg' + s]; room.preW = W; }
  const sky = room.sky, pre = room.pre[which === 'bg' ? 0 : 1], wk = which === 'bg' ? wkOf(world) : String(world.sign?.state === 'closed');
  const have = kit.layers.get(pre); if (have && have.key === wk) return have.c;
  const c = kit.mk(W, STAGE.h); kit.bakes = (kit.bakes || 0) + 1;
  const ctx = c.getContext('2d'), o = { sky, dim: room.dim }, P = kit.P, ox = (W - STAGE.w) >> 1;
  const d = (name, x, y, f = 0, extra) => { const s = kit.get(name, extra ? { ...o, ...extra } : o); ctx.drawImage(s.img, f * s.w, 0, s.w, s.h, x + ox, y, s.w, s.h); };
  const tiles = (y0, y1, pick) => { for (let y = y0; y < y1; y += 16) for (let x = (ox % 16) - 16 - ox; x < W - ox; x += 16) d(pick(y, (((x / 16 + y / 16) % 2) + 2) % 2), x, y); };
  if (which === 'bg') {
    tiles(0, 1, () => 'wall'); tiles(40, 41, () => 'subway'); tiles(56, STAGE.h, (y, odd) => (odd ? 'floor-b' : 'floor-a')); tiles(STAGE.h - 3, STAGE.h, () => 'edge');
    d('door', 0, 26);
    if (sky === 'night') { d('moon', 28, 7); ctx.fillStyle = P.PALETTE.I; for (const [x, y] of [[42, 9], [47, 15], [26, 17], [40, 19], [12, 6], [57, 24], [101, 23], [129, 27], [143, 21], [188, 33]]) ctx.fillRect(x + ox, y, 1, 1); }
    else d('sun', sky === 'day' ? 43 : 26, sky === 'day' ? 7 : 9);
    for (let x = -ox; x < W - ox; x += 100) d('rail', x, 0);   // the gantry beam across the top: the job board, the signs and the power board hang from it
    d('rail', 60, 3); d('pass', 152, 14); if (world.fuse) d(world.fuse.tripped ? 'lamp-off' : 'lamp', 168, 4);   // the work light only with its field (breaker)
    bakeWorld(world, d);
  } else {
    for (const [st, s] of Object.entries(STATIONS)) {
      const cx = sx(s.x); d('shadow', cx - 14, STAGE.top + 18); d('shadow', cx, STAGE.top + 18); d(STATION_ART[st], cx - 14, STAGE.top);   // a contact shadow under each
      if (PROP[st]) d(PROP[st], cx - 8, STAGE.top - (st === 'stove' ? 6 : 5));
    }
    if (world.sign?.state === 'closed') {   // PAUSED: hazard tape strung across every station on its posts, and the barriers on two of them
      const xs = Object.values(STATIONS).map((s) => sx(s.x)), x0 = xs[0] - 18, x1 = xs[xs.length - 1] + 18;
      for (let x = x0; x < x1; x += 16) d('tape', x, STAGE.top + 6);
      for (const st of ['taste', 'plate']) d('chair-up', sx(STATIONS[st].x) - 5, STAGE.top - 8);
    }
  }
  kit.layers.set(pre, { key: wk, c }); return c;
}
// one frame of the stage; returns the number of draw calls (the budget test counts them). Nothing is allocated per frame: actors keep
// their palettes from stageSync, strips come from the kit's cache, and every time-driven pixel takes its step from the frame clock
// (frame.js), which notes when the next one is due. Calm is still (art critique P3): a crew between steps, a runner at the window and
// the seated Dispatcher hold one frame; the bell rings only as its moment.
const D = { ctx: null, n: 0, ox: 0 };
function put(s, f, x, y) { D.ctx.drawImage(s.img, (f % s.n) * s.w, 0, s.w, s.h, Math.round(x) + D.ox, Math.round(y), s.w, s.h); D.n++; }
const byDepth = (a, b) => Math.round(a.y) - Math.round(b.y) || Math.round(a.x) - Math.round(b.x);   // on whole pixels: the order changes only with the picture
export function drawStage(ctx, st, kit) {
  const L = st.L; if (!L) return 0;
  if (st.list.length !== st.actors.size) relist(st);
  const t = st.t, WD = L.world || {}, room = st.room || palOf({ sky: L.sky, dim: WD.sign?.state === 'closed' }), P = kit.P, W = st.W || STAGE.w, A = st.list.sort(byDepth), d = put;
  D.ctx = ctx; D.n = 0; D.ox = (W - STAGE.w) >> 1;
  const ox = D.ox;
  ctx.drawImage(layer(kit, 'bg', room, W, WD), 0, 0); D.n++;
  for (let i = 0; i < A.length; i++) if (A[i].kind === 'chef' && A[i].path.length && Math.round(A[i].x) < STAGE.doorX + 15) { d(kit.get('hoist-open', room), 0, 0, 26); break; }   // a crew is arriving: the hoist gate stands open
  if (st.night) d(kit.get('pool', room), 0, 152, 57);   // night shift: the work light's pool on the slab
  const pf = passFx(st);   // a 1 px shake after Jordan's Approve; the bell bounces when a work order needs him (its moment)
  if (L.pass) { d(kit.get('pass-glow', room), 0, 156 + pf.dx, 18); for (let i = 0; i < Math.min(3, L.pass); i++) d(kit.get('cloche', room), 0, 155 + pf.dx + i * 11, 33); d(kit.get('bell', room), 0, 183 + pf.dx, 35 + pf.bell); }
  if (WD.heat) for (const h of WD.heat) d(kit.get('heat', room), h.level, PLACE.heat[0] + h.i * 11, PLACE.heat[1]);
  if (WD.fuse?.tripped) d(kit.get('sparkle', room), (at(4, 90, t) + 2) % 4, PLACE.fuse[0] + 3 + (at(2, 360, t) ? -3 : 2), PLACE.fuse[1] + 8);
  const sm = WD.aside?.smoke;   // the set-aside smoke while under 2 minutes old (real time: the last sync plus the stage clock since)
  if (sm) for (let j = 0, base = (L.now ?? 0) - st.syncT; j < sm.length; j++) {
    const end = sm[j].until - base; if (t >= end) continue; due(end);
    const i = WD.aside.shelf.indexOf(sm[j].id); d(kit.get('smoke', room), at(4, 260, t, i * 300), PLACE.aside[0] + i * 5, PLACE.aside[1] - 9 - at(3, 160, t, i * 480));
  }
  ctx.fillStyle = P.PALETTE.r;
  for (const tc of L.tickets) {
    const x = sx(tc.x) + TICKET_DX - 5, id = String(tc.id || '');
    d(kit.get('ticket', room), 0, x, 4); d(kit.get('digit', room), digit(id, 1), x + 2, 7); d(kit.get('digit', room), digit(id, 0), x + 6, 7);
    if (!tc.queued) { ctx.fillRect(x + 2 + ox, 14, Math.max(1, Math.round((7 * tc.step) / Math.max(1, tc.steps))), 1); D.n++; }
  }
  for (let i = 0; i < A.length; i++) {
    const a = A[i]; if (a.kind !== 'chef') continue;
    const o = a.po, still = !a.path.length, ps = chefPose(st, a), nm = ps && ps.name;   // a crouch, a hop or a landing squash
    const f = still ? (a.busy ? at(2, 450, t, a.look.delay * 1000) : 0) : at(4, 140, t), x = a.x - 8, y = a.y - 23 + (ps ? ps.dy : 0);
    d(kit.get(nm || (still ? 'chef-idle' : CHEF_DIR[a.dir]), o, !nm && !still && a.dir === 'side' && a.flip), nm ? 0 : f, x, y);
    if (a.look.stache && (still || a.dir === 'down')) d(kit.get('stache', o), 0, x + 6, y + 10 + (nm ? 2 : bobOf(P, still ? 'idle' : 'walk', f)));
  }
  ctx.drawImage(layer(kit, 'fg', room, W, WD), 0, 0); D.n++;
  for (let i = 0; i < A.length; i++) { const a = A[i]; if (a.kind === 'chef' && !a.path.length && a.busy) d(kit.get(WORK[a.st], a.po), at(4, 120, t, a.look.delay * 1000), a.x - 8, STAGE.top - 6); }
  if (L.busy.stove) {
    d(kit.get('oven-glow', room), at(3, 110, t), SX.stove - 11, STAGE.top - 6); d(kit.get('flame', room), at(3, 110, t), SX.stove - 4, STAGE.top - 9);   // the weld flash at the vice, sparks
    for (let i = 0; i < 3; i++) d(kit.get('steam', room), at(4, 260, t, i * 300), SX.stove - 7 + i * 4, STAGE.top - 12 - at(8, 90, t, i * 450));   // dust
  }
  if (L.busy.taste) d(kit.get('sparkle', room), at(4, 260, t), SX.taste, STAGE.top - 7);   // the inspection desk lamp glints
  if (L.busy.sink) for (let i = 0; i < 3; i++) d(kit.get('bubble', room), 0, SX.sink - 10 + ((i + at(4, 300, t)) % 4) * 3, STAGE.top + 10);   // the test rig's green LEDs chase along its strip
  drawFx(st, kit, d, room);   // the moments (moments.js)
  for (const s of st.sparks) { const f = tk(90, t, -s.t); due(s.t + 900); for (let i = 0; i < 3; i++) d(kit.get('sparkle', room), f + i, s.x - 8 + i * 8, s.y - (i % 2) * 6 - Math.floor(f / 2)); }
  for (let i = 0; i < A.length; i++) {
    const a = A[i]; if (a.kind === 'chef') continue;
    const o = a.po, x = a.x - 8, y = a.y - 23, walking = a.path.length > 0;
    d(kit.get('shadow', room), 0, x + 1, a.y - 1);
    if (a.kind === 'sleepy') {   // nothing building: the snore is the stage's one calm motion, a step every 900 ms
      d(kit.get('crate', room), 0, x - 2, a.y - 11); d(kit.get('chef-sleep', a.pz), at(2, 900, t), x, y - 8);
      d(kit.get('zz', room), 0, x + 14 + at(3, 900, t), y - 12 - at(3, 900, t) * 2); continue;
    }
    if (a.kind === 'sous') {
      const w = (a.pw ||= palOf({ ...o, cook: P.DISPATCHER }));   // the Dispatcher: a white hard hat and a clipboard (Jordan, 10-26)
      if (walking) { const f = at(4, 140, t); d(kit.get('chef-side', w, a.flip), f, x, y); d(kit.get('cloche', room), 0, a.flip ? x - 4 : x + 10, y + 7 + bobOf(P, 'walk', f)); } else d(kit.get('chef-sit', w), 0, x, y - 3);
      continue;
    }
    const f = walking ? at(4, 140, t) : 0;
    d(kit.get(walking ? 'waiter-side' : 'waiter-idle', o, walking && a.flip), f, x, y);
    d(kit.get('cloche', room), 0, walking ? (a.flip ? x - 4 : x + 10) : x + 3, y + (walking ? 7 : 9) + bobOf(P, walking ? 'walk' : 'idle', f));
  }
  return D.n;
}
// a frame for the loop: one draw, then the stage notes the picture it shows and when the next step is due (stageDirty, stageWait)
export function paintStage(ctx, st, kit) { CLOCK.next = Infinity; const n = drawStage(ctx, st, kit); st.next = CLOCK.next; st.drawn = st.rev; return n; }
// the tap targets and the words: real links over the canvas, one per work-order card, crew member and runner (the canvas is aria-hidden)
// o: P = sprites.js (the props' sizes), k = CSS px per art px, W = the room's width, wave = the tapped crew member (its words show for 3 s)
export function hitItems(L, ox = 0, o = {}) {
  const ids = L.world?.aside?.ids || [], id = ids[ids.length - 1], spots = chefSpots(L);   // the set-aside shelf: one link, to the newest
  const chefs = L.chefs.map((c) => ({ c, x: spots.get(c.key), word: o.wave === c.key ? c.act : c.word })).sort((a, b) => a.x - b.x);
  const says = placeSays(chefs.filter((h) => h.word).map((h) => ({ kind: 'say', key: 's' + h.c.key, word: h.word.length > 11 ? h.word.slice(0, 10) + '…' : h.word, x: h.x, show: o.wave === h.c.key })), propRects(L.world, o.P), o.k, o.W);
  // the doors first (underneath): every data mark with no link of its own (purpose.js); then the work orders' own links on top
  return [...markItems(L, ox), ...L.tickets.map((t) => ({ kind: 'ticket', key: 't' + t.key, id: t.id, x: sx(t.x) + TICKET_DX + ox, y: 17, label: `${ticket(t.id)}, open it` })),
    ...chefs.map(({ c, x }) => ({ kind: 'chef', key: c.key, id: c.id, x: x + ox, y: STAGE.aisle - 6, label: c.label + (c.priv || c.cook === 'hand' || c.cook === 'sous' ? '' : ', crew ' + c.cook) })),
    ...says.map((s) => ({ ...s, x: s.bx + ox, y: s.by })),
    ...L.waiters.map((w, i) => ({ kind: 'waiter', key: w.key, id: w.id, x: waiterX(i) + ox, y: STAGE.front, label: w.label })),
    ...L.runners.map((r) => ({ kind: 'waiter', key: 'h' + r.key, id: r.id, x: 166 + ox, y: STAGE.front, label: `${ticket(r.id)} handed over, open it` })),
    ...(id ? [{ kind: 'aside', key: 'aside', id, x: PLACE.aside[0] + 13 + ox, y: PLACE.aside[1] + 4, label: `${plural(ids.length, 'work order')} failed or stopped; the newest is ${ticket(id)}, open it` }] : [])];
}
export function hitHtml(it, W = STAGE.w) {
  const [w, h] = it.w ? [it.w, it.h] : { ticket: [11, 13], aside: [27, 12] }[it.kind] || [16, 24], pc = (v, of) => ((v / of) * 100).toFixed(2) + '%';
  if (it.kind === 'say') return `<span class="px-say" aria-hidden="true" data-key="${esc(it.key)}" data-css="left:${pc(it.x, W)};top:${pc(it.y, STAGE.h)};bottom:auto;margin:0;pointer-events:none${it.show ? ';display:block' : ''}">${esc(it.word)}</span>`;
  const at = `data-key="${esc(it.key)}" aria-label="${esc(it.label)}" data-css="left:${pc(it.x, W)};top:${pc(it.y - h, STAGE.h)};width:${pc(w, W)};height:${pc(h, STAGE.h)}"`;
  if (it.kind === 'mark' && !it.id) return `<button class="px-a px-mark" type="button" data-legend="${esc(it.row)}" ${at}></button>`;   // its line in the legend sheet
  return `<a class="px-a px-${it.kind}" href="#/job/${esc(it.id)}" data-key="${esc(it.key)}" aria-label="${esc(it.label)}" data-css="left:${pc(it.x, W)};top:${pc(it.y - h, STAGE.h)};width:${pc(w, W)};height:${pc(h, STAGE.h)}"></a>`;
}

// ---- in the page ----
let PX = null, KIT = null, CANVAS_OK = null;
const mounted = new Set();
// the legend sheet for a mounted scene
export const sceneLegend = (el) => legendHtml(legendRows(el?._px?.st.L || (el?._args && layoutScene(...el._args))));
const RM = typeof matchMedia === 'function' ? matchMedia('(prefers-reduced-motion: reduce)') : null, reduced = () => !!RM?.matches;   // one query, read each frame
// the frame meter (frame-meter.js, loaded only when used): ?hud in the address for this visit, or Settings > About > Frame meter
// (kept on this phone); ?fps times frames for Settings > About without the box
export function sceneMeter(on) {
  if (on === undefined) return METER.on;
  try { localStorage.setItem('board.frameMeter', on ? '1' : '0'); } catch { /* private mode: on for this visit */ }
  meter(!!on); return !!on;
}
const meter = (on) => { METER.on = on; import('./frame-meter.js').then((m) => m.meterBox(METER.on)).catch(() => { /* not loaded: no meter */ }); };
const mkCanvas = (w, h) => { const c = document.createElement('canvas'); c.width = w; c.height = h; return c; };
function canvasOk() { if (CANVAS_OK === null) { try { CANVAS_OK = !!mkCanvas(1, 1).getContext('2d'); } catch { CANVAS_OK = false; } } return CANVAS_OK; }
function fit(sc) {
  // the frame hugs the canvas (2px border each side), placed on a whole device pixel
  const r = pixelScale(Math.max(0, (sc.root.parentElement?.clientWidth || 364) - 4), globalThis.devicePixelRatio || 1, sc.compact ? 200 : 320);
  for (const e of [sc.canvas, sc.hit]) Object.assign(e.style, { width: r.cssW + 'px', height: r.cssH + 'px' });
  if (sc.canvas.width !== r.w) { sc.canvas.width = r.w; sc.ctx.imageSmoothingEnabled = false; sc.st.rev++; }
  sc.st.W = r.w; sc.k = r.scale / (globalThis.devicePixelRatio || 1);
  sc.root.style.width = r.cssW + 4 + 'px'; sc.root.style.marginLeft = r.left + 'px';
}
function paint(sc) {
  if (!sc.st.L) return;
  hits(sc); paintStage(sc.ctx, sc.st, KIT);   // drawn now: the loop draws again only when the picture changes
}
// one frame of the loop (pure, tested): tick, at most one draw and only for a new picture (every frame while `every`: the meter's test
// run), then how long the loop may sleep (frame.js stageWait); st.drew says whether it drew
export function stageFrame(st, ctx, kit, dt, every = false) {
  stageTick(st, dt);
  st.drew = every || stageDirty(st); if (st.drew) paintStage(ctx, st, kit);
  return every ? 0 : stageWait(st);
}
function frameOf(sc, dt, now) {
  const st = sc.st, note = METER.note, t0 = note ? performance.now() : 0, wait = stageFrame(st, sc.ctx, KIT, dt, METER.test > now);
  if (st.fx?.line || st.fx?.wave?.key !== sc.wave) hits(sc);
  if (note) note(now, performance.now() - t0, st.drew, wait);
  return wait;
}
// a display change with no resize (a window moved to another screen, a phone's display-size setting): fit again at the new ratio
function watchDpr() {
  const m = typeof matchMedia === 'function' && matchMedia(`(resolution: ${globalThis.devicePixelRatio || 1}dppx)`);
  m?.addEventListener?.('change', () => { for (const el of mounted) if (el._px) { fit(el._px); paint(el._px); el._px.loop.start(); } watchDpr(); }, { once: true });
}
// the links and bubbles over the canvas (again when a tapped crew member's wave starts or ends); a moment's line goes to #announce
function hits(sc) {
  sc.wave = sc.st.fx?.wave?.key; const fx = sc.st.fx, a = fx?.line && document.getElementById('announce'); if (a) a.textContent = fx.line; if (fx) fx.line = null;
  writeHits(sc, hitItems(sc.st.L, (sc.st.W - STAGE.w) >> 1, { P: KIT.P, k: sc.k, W: sc.st.W, wave: sc.wave }).map((it) => hitHtml(it, sc.st.W)).join(''));
}
// the link layer is written only when its markup changes: a state render that changes nothing never replaces the link under a finger
// mid-tap (a lost tap); returns whether it wrote (tested)
export function writeHits(sc, html) { if (sc.hitHtml === html) return false; sc.hitHtml = html; sc.hit.innerHTML = html; applyCss(sc.hit); return true; }
// a stage that is replaced or leaves the page lets go of its observers (they held the old stage alive for as long as the page was open)
export function dropStage(sc) { if (!sc) return; sc.io?.disconnect?.(); sc.ro?.disconnect?.(); sc.io = sc.ro = null; }
function mountPixel(el, L) {
  let sc = el._px;
  if (!sc || !el.contains(sc.root) || sc.compact !== L.compact) {
    dropStage(sc);
    el.innerHTML = `<div class="px-stage${L.compact ? ' compact' : ''}" role="group"><canvas class="px-canvas" width="${STAGE.w}" height="${STAGE.h}" aria-hidden="true"></canvas><div class="px-hit"></div>`
      + '<button class="px-info" type="button" aria-haspopup="dialog" aria-label="What am I looking at?">i</button></div>';
    const root = el.firstElementChild, canvas = root.querySelector('canvas');
    sc = el._px = { root, canvas, ctx: canvas.getContext('2d'), hit: root.querySelector('.px-hit'), st: stageNew(), compact: L.compact };
    sc.ctx.imageSmoothingEnabled = false;
    // the (i) chip: app.js opens the legend sheet
    root.querySelector('.px-info').addEventListener('click', () => el.dispatchEvent(new CustomEvent('scene-legend', { bubbles: true })));
    sc.hit.addEventListener('click', (e) => {   // a tapped crew member waves and says what they do for 3 s, then the work order opens (a second tap: now)
      const m = e.target.closest?.('[data-legend]');   // a mark's door: the legend sheet, scrolled to its line
      if (m) { el.dispatchEvent(new CustomEvent('scene-legend', { bubbles: true, detail: { row: m.dataset.legend } })); setTimeout(() => { const li = document.getElementById('wl-' + m.dataset.legend); li?.classList.add('wl-on'); li?.scrollIntoView?.({ block: 'center' }); }, 60); return; }
      const a = e.target.closest?.('.px-chef'), key = a?.getAttribute('data-key'); if (!a || reduced() || sc.st.fx?.wave?.key === key) return;
      e.preventDefault(); sc.tap = key; tapChef(sc.st, key); hits(sc); sc.loop.start(); setTimeout(() => { if (sc.tap === key) location.hash = a.getAttribute('href'); }, FX.wave);
    });
    sc.loop = makeLoop({ raf: (f) => requestAnimationFrame(f), ok: () => stageOk(sc, document, reduced()), frame: (dt, now) => frameOf(sc, dt, now) });
    if (typeof IntersectionObserver === 'function') (sc.io = new IntersectionObserver((es) => { const v = es.some((e) => e.isIntersecting); sc.visible = v; if (v) sc.loop.start(); })).observe(root);
    if (typeof ResizeObserver === 'function') (sc.ro = new ResizeObserver(() => { fit(sc); paint(sc); })).observe(el);
    fit(sc);
  }
  sc.root.setAttribute('aria-label', L.summary);
  stageSync(sc.st, L, { still: reduced() });
  paint(sc);
  sc.loop.start();
}
export function sceneApproved() { for (const el of mounted) if (el._px) { approveFx(el._px.st); el._px.loop.start(); } }
// the interface chrome: the sprites become CSS variables (--px-load, --px-tab-pass, --px-panel ...) and <html class="px"> turns them on.
// Tab icons follow the colour scheme: in dark mode --px-tab-<name>(-on) holds the -dark sprite (cream outline), switched live.
function installChrome(P) {
  const root = document.documentElement, url = {};
  for (const [k, c] of Object.entries(P.chromeSprites(mkCanvas))) { url[k] = `url("${c.toDataURL()}")`; root.style.setProperty('--px-' + k, url[k]); }
  const dark = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null;
  const tabs = () => { for (const k of Object.keys(url)) if (k.startsWith('tab-') && !k.endsWith('-dark')) root.style.setProperty('--px-' + k, dark?.matches ? url[k + '-dark'] : url[k]); };
  tabs(); dark?.addEventListener?.('change', tabs);
  // legend icons (--px-lg-<key>)
  for (const [k, [name, f, cook]] of Object.entries(P.LEGEND_ICONS)) {
    const s = P.stripOf(mkCanvas, name, cook ? P.paletteFor({ cook }) : P.PALETTE), c = mkCanvas(s.w, s.h);
    c.getContext('2d').drawImage(s.img, f * s.w, 0, s.w, s.h, 0, 0, s.w, s.h); root.style.setProperty('--px-lg-' + k, `url("${c.toDataURL()}")`);
  }
  root.classList.add('px');
}
if (typeof document !== 'undefined' && typeof window !== 'undefined') {
  let keep = false; try { keep = localStorage.getItem('board.frameMeter') === '1'; } catch { /* no storage: off */ }
  METER.wake = () => { for (const el of mounted) el._px?.loop.start(); };
  if (keep || /[?&](hud|fps=hud)\b/.test(location.search)) (document.body ? meter(true) : addEventListener('DOMContentLoaded', () => meter(true), { once: true }));
  else if (/[?&]fps\b/.test(location.search)) import('./frame-meter.js').catch(() => {});
  watchDpr();
  import('./sprites.js').then((P) => {
    PX = P; KIT = makeKit(P, mkCanvas); installChrome(P);
    for (const el of mounted) if (el.isConnected && el._args) mountScene(el, ...el._args);
  }).catch(() => { /* no sprites (offline before the first load): the still card stays */ });
  document.addEventListener('visibilitychange', () => { for (const el of mounted) if (!el.isConnected) { dropStage(el._px); mounted.delete(el); } else el._px?.loop.start(); });
}
