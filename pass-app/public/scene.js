// The kitchen, animated (pass-app/SCENE.md): a small diorama on the Pass and Live tabs: a chef per order on the line at the station
// its step needs, tickets on the rail, waiters carrying plates to the pass, a window sky that follows the hour, a sleepy chef when idle.
// Budget: at most 60 animated elements and about 25 KB of SVG markup (checked by pass-app/test-scene.mjs).
// SVG: mountScene keeps one element per actor, keyed by job id, so no animation restarts; an actor's place lives on its outer <a> (a
// CSS transition = walking), its motion on inner groups. Only transform and opacity animate; paused while hidden; still under reduced
// motion. The pixel stage (SCENE.md): once sprites.js loads, layoutScene drives a canvas; frame.js runs its loop, moments.js its
// moments. Private orders show no words anywhere.
import { WORLD, worldOf, worldWords, legendRows, legendHtml, PLACE, worldKey, bakeWorld, plural } from './world.js';
import { stageOk, stageFps, frameKey, makeLoop } from './frame.js';
import { fxSync, fxTick, fxBusy, drawFx, chefPose, passFx, chefSpots, propRects, placeSays, approveFx, tapChef, FX } from './moments.js';
export { makeLoop };
const NS = 'http://www.w3.org/2000/svg';
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const ticket = (id) => 'WO-' + String(id || '').replace(/^J/, '').padStart(4, '0');
const r1 = (n) => Math.round(n * 10) / 10;
// Inline styles under a strict CSP (style-src 'self', no 'unsafe-inline'): a browser drops a style attribute written in markup, but styles
// set from script are allowed. So markup carries data-css="name:value;..." and applyCss copies each one in with
// style.setProperty. An element is styled once per data-css value (a later script move, like a chef's walk, is never undone).
// The scene calls it as it inserts; app.js also runs it on every node any renderer adds (a MutationObserver).
export function applyCss(root) {
  if (!root || root.nodeType !== 1) return;
  for (const el of [root, ...root.querySelectorAll('[data-css]')]) {
    const css = el.getAttribute('data-css'); if (css === null || el._css === css) continue; el._css = css;
    for (const d of css.split(';')) { const i = d.indexOf(':'); if (i > 0) el.style.setProperty(d.slice(0, i).trim(), d.slice(i + 1).trim()); }
  }
}

// ---- where things are (viewBox 400 x 210) ----
export const STATIONS = {
  board: { x: 44, label: 'cutting board', word: 'prep' },
  stove: { x: 104, label: 'stove', word: 'stove' },
  taste: { x: 164, label: 'tasting counter', word: 'taste' },
  sink: { x: 224, label: 'sink', word: 'wash' },
  plate: { x: 284, label: 'plating counter', word: 'plate' },
};
const CHEF_Y = 174, WAITER_Y = 204, DOOR_X = -26, PASS_X = 334, RAIL_X = 104, RAIL_W = 196;
const STEP_AT = {
  plan: 'board', map: 'board', research: 'board', worktree: 'board', diagnose: 'board', slice: 'board', talk: 'board', ask: 'board', scout: 'board',
  do: 'stove', build: 'stove', repair: 'stove', check: 'taste', review: 'taste', tests: 'sink', lint: 'sink', mutate: 'sink', verify: 'sink',
  commit: 'plate', freshen: 'plate', merge: 'plate', ideas: 'plate', 'pack-render': 'plate', inventory: 'plate',
};
export const COOK_COLORS = { claude: '#d97757', gemini: '#4f8cf7', antigravity: '#a46cf0', local: '#3fa66b', sous: '#d6a531', hand: '#8b939e' };
// the classes app.css animates; the budget test counts them
export const ANIMATED = ['bob', 'eyes', 'arm-r', 'flame', 'puff', 'bub', 'star', 'bell', 'zz'];

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

const STEP_WORD = { plan: 'planning', do: 'building', build: 'building', check: 'Inspection', research: 'researching', talk: 'chatting', diagnose: 'diagnosing',
  tests: 'inspecting', repair: 'fixing it', commit: 'saving', freshen: 'resurveying', merge: 'handing over', map: 'mapping', worktree: 'setting up', lint: 'checking',
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
// what a step is, in site words ("inspecting" for tests); the Board's crew cards use it too
export const stepWord = (j) => STEP_WORD[stepKey(j)] || 'working';

// ---- what is on the floor right now (pure: tested in node) ----
export function layoutScene(s, events = [], opts = {}, now = Date.now()) {
  const jobs = s?.jobs || [];
  const compact = !!opts.compact;
  // on the line: running, or between two steps of an order already started (so a chef does not walk out and back every step)
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

// ---- the actors (feet at 0,0; the outer <a> carries the place, inner groups carry the motion) ----
const TOOL = {
  board: '<path class="steel" d="M9 -13 l7 -1.6 l.6 1.4 l-7.4 1.4z"/><rect class="wood" x="7.6" y="-13.8" width="2.6" height="1.8" rx=".6"/>',
  stove: '<rect class="wood" x="9.2" y="-21" width="1.3" height="10" rx=".6"/><circle class="steel" cx="9.9" cy="-11" r="2.1"/>',
  taste: '<rect class="steel" x="9.3" y="-19" width="1" height="7" rx=".5"/><ellipse class="steel" cx="9.8" cy="-19.6" rx="1.6" ry="1.1"/>',
  sink: '<rect class="sponge" x="7.6" y="-14" width="5" height="3.2" rx="1"/>',
  plate: '<ellipse class="sc-dish" cx="12" cy="-12.4" rx="5" ry="1.4"/>',
};
function chefBody(c) {
  const L = c.look, hand = c.cook === 'hand', top = -38.5 - L.hat;
  const hat = hand
    ? '<path class="ck" d="M-6.6 -35 a6.6 6 0 0 1 13.2 0z"/><rect class="ck" x="3" y="-36" width="8" height="2" rx="1"/>'
    : `<rect class="hat" x="-6" y="${r1(top + 2)}" width="12" height="${r1(L.hat + 1)}" rx="2"/><circle class="hat" cx="-3.6" cy="${r1(top + 1)}" r="3.6"/><circle class="hat" cx="3.6" cy="${r1(top + 1)}" r="3.6"/><circle class="hat" cx="0" cy="${r1(top - 0.6)}" r="4.3"/><rect class="ck" x="-6.2" y="-38.6" width="12.4" height="3" rx="1"/>`;
  return `<g class="bob"><rect class="leg l" x="-5" y="-11" width="3.6" height="11" rx="1.5"/><rect class="leg r" x="1.4" y="-11" width="3.6" height="11" rx="1.5"/>`
    + `<rect class="arm" x="-11" y="-24" width="4" height="11" rx="2"/><rect class="coat" x="-8" y="-25.5" width="16" height="16" rx="4.5"/><rect class="apron" x="-5.5" y="-19" width="11" height="10" rx="1.5"/>`
    + `<path class="ck" d="M-5.2 -25.5 h10.4 l-2.4 4 h-5.6z"/><g class="arm-r"><rect class="arm" x="7" y="-24" width="4" height="11" rx="2"/>${TOOL[c.st] || ''}</g>`
    + `<circle class="skin" cx="0" cy="-31" r="6.3"/><circle class="blush" cx="-3.7" cy="-29.1" r="1.1"/><circle class="blush" cx="3.7" cy="-29.1" r="1.1"/>`
    + `<g class="eyes"><circle cx="-2.2" cy="-31.6" r=".85"/><circle cx="2.2" cy="-31.6" r=".85"/></g>`
    + (L.stache ? '<path class="stache" d="M-3.2 -29.2 q1.6 -1.2 3.2 0 q1.6 -1.2 3.2 0 q-1.6 1.5 -3.2 .4 q-1.6 1.1 -3.2 -.4z"/>' : '<path class="mouth" d="M-1.6 -28.3 q1.6 1.3 3.2 0"/>')
    + `${hat}</g>`;
}
const sayTop = (hat, slot) => -44 - hat - (slot || 0) * 12;   // chefs sharing a station stack their bubbles
// a speech bubble over the chef at x; it slides sideways to stay inside the room, its tip still points at the chef
function sayHtml(word, hatTop, x = 200) {
  if (!word) return '';
  if (word.length > 13) word = word.slice(0, 12) + '…';   // 13 characters at most: bubbles at neighbouring stations never touch
  const w = r1(8 + word.length * 3.9);
  const dx = r1(Math.max(3 - (x - w / 2), Math.min(0, 397 - (x + w / 2))));
  return `<g class="sc-say" transform="translate(0 ${r1(hatTop - 8)})"><rect x="${r1(dx - w / 2)}" y="-9" width="${w}" height="11" rx="4"/><path d="M-2.2 1.8 h4.4 l-2.2 3z"/><text x="${dx}" y="-1.4">${esc(word)}</text></g>`;
}
function chefHtml(c) {
  const style = `--skin:${c.look.skin};--cook:${COOK_COLORS[c.cook]};--d:${c.look.delay}s;transform:translate(${c.x}px,${c.y}px)`;
  return `<a class="actor chef st-${c.st} cook-${c.cook}${c.busy ? '' : ' rest'}" href="#/job/${esc(c.id)}" data-key="${esc(c.key)}" data-x="${c.x}" data-st="${c.st}" data-cook="${c.cook}" data-hat="${c.look.hat}" aria-label="${esc(c.label)}" data-css="${style}">`
    + `<g class="flip">${chefBody(c)}</g>${sayHtml(c.word, sayTop(c.look.hat, c.slot), c.x)}${c.cook === 'hand' || c.cook === 'sous' ? '' : `<text class="sc-tag" y="${9 + ((c.slot || 0) % 2) * 7}">${c.cook}</text>`}</a>`;
}
function waiterBody(cloche) {
  return `<g class="bob"><rect class="leg l" x="-4.6" y="-12" width="3.4" height="12" rx="1.4"/><rect class="leg r" x="1.2" y="-12" width="3.4" height="12" rx="1.4"/>`
    + `<rect class="shirt" x="-7" y="-27" width="14" height="16" rx="4"/><path class="vest" d="M-7 -22 h3 l4 6 l4 -6 h3 v10 h-14z"/><path class="tie" d="M-2.6 -26.6 l2.6 1.4 l2.6 -1.4 v2.8 l-2.6 -1.4 l-2.6 1.4z"/>`
    + `<rect class="shirt" x="-10.4" y="-25" width="3.6" height="10" rx="1.8"/><rect class="shirt" x="6.6" y="-33" width="3.6" height="10" rx="1.8"/>`
    + `<circle class="skin" cx="0" cy="-32.5" r="5.8"/><path class="sc-hair" d="M-5.8 -33.5 a5.8 5.8 0 0 1 11.6 0 q-3 -2.2 -6 -1.6 q-3 -.6 -5.6 1.6z"/>`
    + `<g class="eyes"><circle cx="-2" cy="-32.6" r=".8"/><circle cx="2" cy="-32.6" r=".8"/></g><path class="mouth" d="M-1.4 -30 q1.4 1.1 2.8 0"/>`
    + `<rect class="tray" x="2.4" y="-35.2" width="16" height="1.6" rx=".8"/>${cloche ? '<path class="cloche" d="M4.4 -35.2 a6 5.4 0 0 1 12 0z"/><circle class="cloche" cx="10.4" cy="-41" r=".9"/>' : '<ellipse class="sc-dish" cx="10.4" cy="-36.2" rx="5.4" ry="1.3"/><circle class="food" cx="10.4" cy="-37.6" r="2.2"/>'}</g>`;
}
function waiterHtml(w, x) {
  const look = lookOf(w.id + 'w');
  return `<a class="actor waiter" href="#/job/${esc(w.id)}" data-key="${esc(w.key)}" data-x="${x}" aria-label="${esc(w.label)}" data-css="--skin:${look.skin};--d:${look.delay}s;transform:translate(${x}px,${WAITER_Y}px)"><g class="flip"><g class="big" transform="scale(1.15)">${waiterBody(true)}</g></g></a>`;
}
function runnerHtml(r) {
  const look = lookOf(r.id + 'r');
  return `<g class="actor waiter runner" data-key="${esc(r.key)}" data-x="${PASS_X}" aria-hidden="true" data-css="--skin:${look.skin};--d:0s;transform:translate(${PASS_X}px,${WAITER_Y}px)"><g class="flip"><g class="big" transform="scale(1.15)">${waiterBody(false)}</g></g></g>`;
}
function ticketInner(t) { return `<g class="paper"><rect class="clip" x="-2.5" y="-2" width="5" height="4" rx="1"/><rect class="sc-sheet" x="-11" y="1" width="22" height="19" rx="1.5"/><text class="tno" y="9">${esc(ticket(t.id).slice(3))}</text><text class="tstep" y="16">${t.queued ? 'next up' : `${t.step}/${t.steps}`}</text></g>`; }
function ticketHtml(t) { return `<a class="sc-ticket${t.queued ? ' queued' : ''}" href="#/job/${esc(t.id)}" data-key="${esc(t.key)}" data-step="${t.step}" data-q="${t.queued}" aria-label="${esc(`${ticket(t.id)}, open it`)}" data-css="transform:translate(${t.x}px,16px)">${ticketInner(t)}</a>`; }
const IDLE = `<g class="actor idle" data-key="idle" aria-hidden="true" data-css="--skin:${SKIN[1]};--cook:${COOK_COLORS.sous};--d:0s;transform:translate(30px,${CHEF_Y}px)">`
  + `<rect class="crate" x="-9" y="-12" width="18" height="12" rx="1"/><g class="flip sleep">${chefBody({ look: { ...lookOf('idle'), stache: true }, cook: 'sous', st: 'rest' })}</g>`
  + `<text class="zz" x="7" y="-46">z</text><text class="zz" x="11" y="-52">z</text><text class="zz" x="15" y="-58">Z</text></g>`;

// ---- the room (static; mountScene only flips classes on it) ----
function fixture(st, inner, label) {
  return `<g class="fx fx-${st}" transform="translate(${STATIONS[st].x - 26} 120)"><rect class="body" x="0" y="8" width="52" height="30" rx="2"/><rect class="sc-top" x="-1" y="5" width="54" height="4" rx="1"/>${inner}<text class="engr" x="26" y="31">${label}</text></g>`;
}
function roomHtml(L, actors) {
  const defs = '<defs><linearGradient id="sc-dawn" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f08a6a"/><stop offset="1" stop-color="#ffe2b0"/></linearGradient>'
    + '<linearGradient id="sc-day" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5aa9e6"/><stop offset="1" stop-color="#bfe3fb"/></linearGradient>'
    + '<linearGradient id="sc-dusk" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3d2e5c"/><stop offset="1" stop-color="#e2805a"/></linearGradient>'
    + '<linearGradient id="sc-night" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0b1022"/><stop offset="1" stop-color="#1f2a48"/></linearGradient>'
    + '<pattern id="sc-floor" width="16" height="16" patternUnits="userSpaceOnUse"><rect width="16" height="16" class="fl-a"/><rect width="8" height="8" class="fl-b"/><rect x="8" y="8" width="8" height="8" class="fl-b"/></pattern>'
    + '<pattern id="sc-tile" width="10" height="7" patternUnits="userSpaceOnUse"><rect width="10" height="7" class="tile"/><path d="M0 .3 H10 M.3 0 V7" class="grout"/></pattern></defs>';
  const win = `<g class="win ${L.sky}"><rect class="sky" x="14" y="12" width="58" height="40" rx="3"/><circle class="sun" cx="58" cy="24" r="5"/><path class="moon" d="M30 17 a6 6 0 1 0 6 9 a5 5 0 1 1 -6 -9z"/>`
    + '<g class="stars"><circle class="star" cx="44" cy="20" r=".8"/><circle class="star" cx="55" cy="30" r=".7"/><circle class="star" cx="65" cy="17" r=".8"/><circle class="star" cx="22" cy="40" r=".6"/><circle class="star" cx="48" cy="44" r=".6"/></g>'
    + '<path class="frame" d="M14 12 h58 v40 h-58z M43 12 v40 M14 32 h58"/><rect class="sill" x="10" y="51" width="66" height="4" rx="1"/></g>';
  const shelf = '<rect class="wood" x="84" y="58" width="222" height="3.5" rx="1"/><rect class="jar" x="92" y="47" width="7" height="11" rx="2"/><rect class="jar b" x="102" y="50" width="6" height="8" rx="2"/>'
    + '<rect class="jar c" x="276" y="46" width="8" height="12" rx="2"/><rect class="jar" x="287" y="49" width="6" height="9" rx="2"/><rect class="jar b" x="296" y="47" width="6" height="11" rx="2"/>'
    + [74, 134, 194, 254].map((x, i) => `<path class="hook" d="M${x} 61.5 v7"/><circle class="${i % 2 ? 'pan' : 'pan copper'}" cx="${x}" cy="76" r="${i % 2 ? 6 : 7}"/><rect class="hook" x="${x - 1}" y="66" width="2" height="5"/>`).join('');
  const rail = `<rect class="rail" x="${RAIL_X}" y="12" width="${RAIL_W + 4}" height="3" rx="1.5"/>`;
  const fx = fixture('board', '<rect class="wood" x="12" y="1" width="26" height="4.5" rx="1"/><circle class="veg g" cx="18" cy="0" r="2.2"/><circle class="veg r" cx="23" cy=".4" r="1.8"/><circle class="veg o" cx="32" cy="0" r="2"/>', 'prep')
    + fixture('stove', '<rect class="steel" x="14" y="-6" width="24" height="11" rx="2"/><path class="hook" d="M12 -3 h2 M38 -3 h2"/>'
      + '<path class="flame" d="M17 6 q2 -5 3 0z"/><path class="flame" d="M24.5 6 q2 -6 3 0z"/><path class="flame" d="M32 6 q2 -5 3 0z"/>'
      + '<circle class="puff" cx="20" cy="-8" r="2"/><circle class="puff" cx="26" cy="-9" r="2.4"/><circle class="puff" cx="32" cy="-8" r="1.9"/><rect class="door" x="9" y="14" width="34" height="11" rx="1.5"/>', 'stove')
    + fixture('taste', '<ellipse class="sc-dish" cx="15" cy="4" rx="7" ry="2"/><ellipse class="soup" cx="15" cy="3.6" rx="5" ry="1.2"/><rect class="jar b" x="31" y="-3" width="5" height="8" rx="1"/><rect class="jar" x="38" y="-1" width="5" height="6" rx="1"/>', 'taste')
    + fixture('sink', '<rect class="basin" x="8" y="5" width="36" height="5" rx="1.5"/><path class="faucet" d="M30 5 v-7 q0 -2.5 3 -2.5 q3 0 3 2.5 v1.5"/>'
      + '<circle class="bub" cx="16" cy="3" r="1.6"/><circle class="bub" cx="22" cy="2" r="2"/><circle class="bub" cx="27" cy="3" r="1.4"/>', 'wash')
    + fixture('plate', '<ellipse class="sc-dish" cx="14" cy="4.4" rx="7" ry="1.6"/><ellipse class="sc-dish" cx="14" cy="3" rx="7" ry="1.6"/><path class="cloche" d="M28 5 a8 7 0 0 1 16 0z"/><circle class="cloche" cx="36" cy="-2.6" r="1"/>', 'plate');
  const pass = `<g class="pass${L.pass ? ` on n${Math.min(3, L.pass)}` : ''}"><text class="sign" x="355" y="26">PASS</text><rect class="hatch" x="318" y="32" width="74" height="62" rx="3"/><rect class="glow" x="322" y="36" width="66" height="54" rx="2"/>`
    + `<rect class="steel" x="312" y="94" width="86" height="5" rx="1.5"/><g class="bell"><path d="M376 93 a6 6 0 0 1 12 0z"/><circle cx="382" cy="86" r="1.2"/></g>`
    + `<g class="pl1"><path class="cloche" d="M322 94 a7 6 0 0 1 14 0z"/></g><g class="pl2"><path class="cloche" d="M340 94 a7 6 0 0 1 14 0z"/></g><g class="pl3"><path class="cloche" d="M358 94 a7 6 0 0 1 14 0z"/></g>`
    + `<text class="pass-n" x="355" y="114">${L.pass ?`${L.pass} to sign off` : 'all clear'}</text></g>`;
  return `<svg class="scene-stage${L.compact ? ' compact' : ''}" viewBox="0 0 400 210" role="group" aria-label="${esc(L.summary)}">${defs}`
    + `<rect class="wall" width="400" height="152"/><rect x="0" y="92" width="312" height="30" fill="url(#sc-tile)"/>${win}${shelf}${rail}`
    + `<rect class="sc-floor" y="150" width="400" height="60" fill="url(#sc-floor)"/><rect class="base" y="149" width="400" height="3"/>${fx}${pass}`
    + `<g class="layer tickets">${actors.tickets}</g><g class="layer chefs">${actors.chefs}</g><g class="layer waiters">${actors.waiters}</g></svg>`;
}

// the whole scene as markup (first paint, tests and old callers)
export function sceneHtml(s, events, opts = {}) {
  if (!s) return '';
  const L = layoutScene(s, events, opts);
  return roomHtml(L, {
    tickets: L.tickets.map(ticketHtml).join(''),
    chefs: (L.idle ? IDLE : '') + L.chefs.map(chefHtml).join(''),
    waiters: L.waiters.map((w) => waiterHtml(w, w.x)).join('') + L.runners.map(runnerHtml).join(''),
  });
}

// ---- keep it alive in the page: one element per actor, moved, never rebuilt ----
const SPEED = 70;                      // viewBox units per second: a calm walk
const played = new Set();              // finished plates already run out (memory only)
function node(html) { const g = document.createElementNS(NS, 'g'); g.innerHTML = html; applyCss(g.firstElementChild); return g.firstElementChild; }
function walkTo(el, x, y, after) {
  const from = parseFloat(el.getAttribute('data-x'));
  const dist = Math.abs(x - from);
  clearTimeout(el._walk);
  if (dist < 0.5) { el.style.transform = `translate(${x}px,${y}px)`; if (after) after(); return; }
  const sec = Math.max(0.4, dist / SPEED);
  el.style.transition = `transform ${sec}s linear, opacity .5s`;
  el.classList.toggle('left', x < from);
  el.classList.add('walking');
  el.setAttribute('data-x', x);
  el.style.transform = `translate(${x}px,${y}px)`;
  el._walk = setTimeout(() => { el.classList.remove('walking', 'left'); if (after) after(); }, sec * 1000);
}
function sync(layer, items, make, update, leave) {
  const have = new Map();
  for (const el of [...layer.children]) if (!el.classList.contains('gone')) have.set(el.getAttribute('data-key'), el);
  for (const it of items) {
    const el = have.get(it.key);
    if (el) { have.delete(it.key); update(el, it); } else { const n = make(it); if (n) layer.appendChild(n); }
  }
  for (const el of have.values()) leave(el);
}
// after the new element has painted once (so its walk is a transition); a timer backs up animation frames, which a hidden tab never gets
const later = (fn) => { let done = false; const go = () => { if (!done) { done = true; fn(); } }; if (typeof requestAnimationFrame === 'function') requestAnimationFrame(() => requestAnimationFrame(go)); setTimeout(go, 80); };
// the bubble is rebuilt only when its words, its stack slot or the chef's spot change (it is not animated, so nothing restarts)
function setSay(el, word, slot, x) {
  const key = `${slot}@${x}|${word}`;
  if (el.getAttribute('data-say') === key) return;
  el.setAttribute('data-say', key);
  el.querySelector('.sc-say')?.remove();
  const tag = el.querySelector('.sc-tag'); if (tag) tag.setAttribute('y', 9 + (slot % 2) * 7);
  if (word) { const s = node(sayHtml(word, sayTop(parseFloat(el.getAttribute('data-hat') || '8'), slot), x)); if (s) el.appendChild(s); }
}

export function mountScene(el, s, events, opts = {}) {
  if (!el) return;
  if (!s) { el.innerHTML = ''; el._scene = null; el._px = null; return; }
  const L = layoutScene(s, events, opts);
  el._args = [s, events, opts]; mounted.add(el);
  if (PX && canvasOk()) { el._scene = null; mountPixel(el, L); return; }
  el._px = null;
  let sc = el._scene;
  if (!sc || sc.compact !== L.compact || !el.contains(sc.svg)) {
    el.innerHTML = roomHtml(L, { tickets: '', chefs: '', waiters: '' }); applyCss(el);
    const svg = el.querySelector('svg');
    sc = el._scene = { svg, compact: L.compact, tickets: svg.querySelector('.tickets'), chefs: svg.querySelector('.chefs'), waiters: svg.querySelector('.waiters'),
      win: svg.querySelector('.win'), pass: svg.querySelector('.pass'), passN: svg.querySelector('.pass-n'), fx: {}, lastPass: L.pass, first: true };
    for (const st of Object.keys(STATIONS)) sc.fx[st] = svg.querySelector('.fx-' + st);
    svg.classList.toggle('paused', typeof document !== 'undefined' && document.hidden);
  }
  const first = sc.first; sc.first = false;
  sc.svg.setAttribute('aria-label', L.summary);
  sc.win.setAttribute('class', `win ${L.sky}`);
  for (const st of Object.keys(STATIONS)) sc.fx[st]?.classList.toggle('on', !!L.busy[st]);
  sc.pass.classList.toggle('on', L.pass > 0); for (const k of [1, 2, 3]) sc.pass.classList.toggle('n' + k, Math.min(3, L.pass) === k);
  sc.passN.textContent = L.pass ? `${L.pass} to sign off` : 'all clear';
  if (L.pass > sc.lastPass) { sc.pass.classList.remove('ring'); void sc.pass.getBoundingClientRect(); sc.pass.classList.add('ring'); setTimeout(() => sc.pass.classList.remove('ring'), 1400); }
  sc.lastPass = L.pass;

  // chefs walk in from the door on their first appearance (straight to their spot on the first paint), and between stations
  sync(sc.chefs, [...(L.idle ? [{ key: 'idle' }] : []), ...L.chefs], (c) => {
    if (c.key === 'idle') return node(IDLE);
    const n = node(chefHtml({ ...c, x: first ? c.x : DOOR_X }));
    if (!first) later(() => walkTo(n, c.x, c.y));
    return n;
  }, (n, c) => {
    if (c.key === 'idle') return;
    if (n.getAttribute('data-st') !== c.st || n.getAttribute('data-cook') !== c.cook) {   // new station or cook: new tool and colours, same chef
      n.querySelector('.flip').innerHTML = chefBody(c); applyCss(n.querySelector('.flip'));
      n.setAttribute('class', `actor chef st-${c.st} cook-${c.cook}${c.busy ? '' : ' rest'}${n.classList.contains('walking') ? ' walking' : ''}`);
      n.setAttribute('data-st', c.st); n.setAttribute('data-cook', c.cook); n.style.setProperty('--cook', COOK_COLORS[c.cook]);
      n.querySelector('.sc-tag')?.remove();   // the hand and the not-yet-picked cook wear no name
      if (c.cook !== 'hand' && c.cook !== 'sous') n.appendChild(node(`<text class="sc-tag" y="${9 + ((c.slot || 0) % 2) * 7}">${c.cook}</text>`));
    }
    n.classList.toggle('rest', !c.busy);
    n.setAttribute('aria-label', c.label);
    setSay(n, c.word, c.slot || 0, c.x);
    walkTo(n, c.x, c.y);
  }, (n) => {
    n.classList.add('gone');
    if (n.getAttribute('data-key') === 'idle') { setTimeout(() => n.remove(), 600); return; }
    walkTo(n, 330, CHEF_Y, () => n.remove());   // off to the pass with the plate
    setTimeout(() => n.remove(), 6000);
  });

  sync(sc.tickets, L.tickets, (t) => {
    const n = node(ticketHtml(t)); n.classList.add('flutter'); setTimeout(() => n.classList.remove('flutter'), 900); return n;
  }, (n, t) => {
    n.style.transform = `translate(${t.x}px,16px)`;
    n.classList.toggle('queued', t.queued);
    if (n.getAttribute('data-step') !== String(t.step) || n.getAttribute('data-q') !== String(t.queued)) {
      n.setAttribute('data-step', t.step); n.setAttribute('data-q', t.queued);
      n.innerHTML = ticketInner(t); applyCss(n);
      n.classList.remove('flutter'); void n.getBoundingClientRect(); n.classList.add('flutter'); setTimeout(() => n.classList.remove('flutter'), 900);
    }
  }, (n) => { n.classList.add('gone'); setTimeout(() => n.remove(), 600); });

  // waiters bring each plate to the pass; finished plates are run out once each
  const fresh = L.runners.filter((r) => !played.has(r.key));
  sync(sc.waiters, [...L.waiters, ...fresh], (w) => {
    if (w.key.startsWith('o')) {
      played.add(w.key);
      if (first) return null;   // a page opened later does not replay old news
      const n = node(runnerHtml(w)); later(() => walkTo(n, DOOR_X, WAITER_Y, () => n.remove())); setTimeout(() => n.remove(), 8000); return n;
    }
    const n = node(waiterHtml(w, first ? w.x : DOOR_X));
    if (!first) later(() => walkTo(n, w.x, w.y));
    return n;
  }, (n, w) => { if (!n.classList.contains('runner')) walkTo(n, w.x, w.y); }, (n) => {
    if (n.classList.contains('runner')) return;   // it leaves by itself
    n.classList.add('gone'); walkTo(n, 420, WAITER_Y, () => n.remove()); setTimeout(() => n.remove(), 6000);
  });
}

if (typeof document !== 'undefined') document.addEventListener('visibilitychange', () => { for (const svg of document.querySelectorAll('.scene-stage')) svg.classList.toggle('paused', document.hidden); });

// ---- the pixel stage: layoutScene drives a canvas of sprites.js art (the SVG above is the fallback) ----
export const STAGE = { w: 192, h: 112, aisle: 76, front: 108, top: 70, doorX: 9, doorY: 56, exitX: 150, speed: 30, fps: 60, maxDraws: 120 };
export const sx = (x) => Math.round(x * 0.48);
const TICKET_DX = 5;                                    // tickets hang clear of the window
const waiterX = (i) => 146 + i * 15;                    // waiters at the pass stand a body apart                 // the SVG's 400-wide room onto the 192-pixel stage
const STATION_ART = { board: 'counter', stove: 'stove', taste: 'counter', sink: 'sink', plate: 'counter' };
const PROP = { board: 'board', stove: 'pot', taste: 'bowl', sink: null, plate: 'plates' };
// the largest whole-number scale that fits (crisp: every art pixel is exactly `scale` device pixels), centred on a device pixel;
// w is the room's width in art pixels at that scale (192 to 256): the kitchen sits in the middle, wall and floor fill the sides
export function pixelScale(cssW, dpr = 1, maxCssH = Infinity, w = STAGE.w, h = STAGE.h, maxW = 256) {
  const dev = Math.floor(cssW * dpr); let s = Math.max(1, Math.floor(dev / w));
  while (s > 1 && (h * s) / dpr > maxCssH) s--;
  const room = Math.max(w, Math.min(maxW, Math.floor(dev / s)));   // the room widens to fill the phone (more wall and floor), never the art
  return { scale: s, w: room, cssW: (room * s) / dpr, cssH: (h * s) / dpr, left: Math.max(0, Math.floor((dev - room * s) / 2)) / dpr };
}
// the stage model (pure: tested in node): one actor per chef, waiter and runner, keyed like the SVG, walking along axis paths
export function stageNew() { return { W: STAGE.w, actors: new Map(), t: 0, syncT: 0, first: true, L: null, played: new Set(), sparks: [], ticks: new Set(), rounds: 0, sousNext: false }; }
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
  // the sous chef walks one round per new lastTick (on opening the app: only if under 2 min old)
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
    a.leaving = true; a.path = a.kind === 'chef' ? [[STAGE.exitX, a.y]] : a.kind === 'sous' ? [[edgeL, a.y]] : [[edgeR, a.y]];   // chefs carry the plate to the pass, waiters walk out, the sous chef leaves
  }
  return st;
}
export function stageTick(st, dt) {
  st.t += dt; const step = (STAGE.speed * fxTick(st, dt)) / 1000;   // 0 during the Approve hit-stop
  for (const a of [...st.actors.values()]) {
    if (a.path.length && !a.go) { a.go = 1; a.cr = FX.crouch; }   // anticipation: one 80 ms crouch before a walk
    if (a.cr > 0 && step) { a.cr -= dt; continue; }
    let left = step;
    while (left > 0 && a.path.length) {
      const [tx, ty] = a.path[0], dx = tx - a.x, dy = ty - a.y, d = Math.abs(dx) + Math.abs(dy);
      if (a.path.length === 1 && d < 6) left *= Math.max(0.35, d / 6);   // ease-out on arrival
      if (dx) { a.dir = 'side'; a.flip = dx < 0; } else if (dy) a.dir = dy > 0 ? 'down' : 'up';
      if (d <= left) { a.x = tx; a.y = ty; a.path.shift(); left -= d; } else { if (dx) a.x += Math.sign(dx) * left; else a.y += Math.sign(dy) * left; left = 0; }
    }
    if (!a.path.length) a.go = 0;
    if (!a.path.length && a.leaving) st.actors.delete(a.key);
    else if (!a.path.length && a.kind === 'sous' && st.sousNext) { st.sousNext = false; sousRound(st, a); }   // a tick that came mid-round
  }
  st.sparks = st.sparks.filter((s) => st.t - s.t < 900);
  return st;
}
// sprite strips, cached per palette (skin, cook, hair, sky); mk(w, h) makes a canvas (or a test mock)
export function makeKit(P, mk) {
  const c = new Map();
  return { P, mk, layers: new Map(), get(name, o = {}, flip = false) {
    const k = name + '|' + [o.skin, o.cook, o.hair, o.sky].join() + flip; let v = c.get(k);
    if (!v) { if (c.size > 400) c.clear(); v = P.stripOf(mk, name, P.paletteFor(o), flip); c.set(k, v); }
    return v;
  } };
}
const at = (n, ms, t, off = 0) => Math.floor((t + off) / ms) % n;
const bobOf = (P, anim, f) => (P.BOB[anim] || [0])[f % (P.BOB[anim] || [0]).length];
// the still room, drawn once per sky: wall, tiles, window, door, shelf, rail, pass (back), or the counters and their props (front);
// (the newest bake per sky, dim and width is re-used while its world key holds)
function layer(kit, which, room, W = STAGE.w, world = {}) {
  const sky = room.sky, pre = which + sky + (room.dim ? '-dim' : '') + W, wk = which === 'bg' ? worldKey(world) : String(world.sign?.state === 'closed');
  const have = kit.layers.get(pre); if (have && have.key === wk) return have.c;
  const c = kit.mk(W, STAGE.h); kit.bakes = (kit.bakes || 0) + 1;
  const ctx = c.getContext('2d'), o = { sky, dim: room.dim }, P = kit.P, ox = (W - STAGE.w) >> 1;
  const d = (name, x, y, f = 0, extra) => { const s = kit.get(name, extra ? { ...o, ...extra } : o); ctx.drawImage(s.img, f * s.w, 0, s.w, s.h, x + ox, y, s.w, s.h); };
  const tiles = (y0, y1, pick) => { for (let y = y0; y < y1; y += 16) for (let x = (ox % 16) - 16 - ox; x < W - ox; x += 16) d(pick(y, (((x / 16 + y / 16) % 2) + 2) % 2), x, y); };
  if (which === 'bg') {
    tiles(0, 56, (y) => (y >= 32 ? 'subway' : 'wall')); tiles(56, STAGE.h, (y, odd) => (odd ? 'floor-b' : 'floor-a'));
    d('window', 20, 3); d('door', 0, 26);
    if (sky === 'night') { d('moon', 28, 7); ctx.fillStyle = P.PALETTE.I; for (const [x, y] of [[42, 9], [47, 15], [26, 17], [40, 19]]) ctx.fillRect(x + ox, y, 1, 1); }
    else d('sun', sky === 'day' ? 43 : 26, sky === 'day' ? 7 : 9);
    d('shelf', 62, 26); [0, 1, 2, 0, 2].forEach((f, i) => d('jar', [66, 73, 140, 147, 154][i], 19, f));
    for (const x of [82, 98, 114]) d('pan', x, 30);
    d('rail', 60, 3); d('pass', 152, 14); d(world.fuse?.tripped ? 'lamp-off' : 'lamp', 168, 4);
    bakeWorld(world, d);
  } else {
    for (const [st, s] of Object.entries(STATIONS)) {
      const cx = sx(s.x); d(STATION_ART[st], cx - 14, STAGE.top);
      if (PROP[st]) d(PROP[st], cx - 8, STAGE.top - (st === 'stove' ? 6 : 5));
    }
    if (world.sign?.state === 'closed') for (const st of ['taste', 'plate']) d('chair-up', sx(STATIONS[st].x) - 5, STAGE.top - 8);   // CLOSED: stools up on the counters
  }
  kit.layers.set(pre, { key: wk, c }); return c;
}
// one frame of the stage; returns the number of draw calls (the budget test counts them)
export function drawStage(ctx, st, kit) {
  const L = st.L; if (!L) return 0;
  const t = st.t, sky = L.sky, WD = L.world || {}, dim = WD.sign?.state === 'closed', room = { sky, dim }, P = kit.P, W = st.W || STAGE.w, ox = (W - STAGE.w) >> 1; let n = 0;
  const d = (s, f, x, y) => { ctx.drawImage(s.img, (f % s.n) * s.w, 0, s.w, s.h, Math.round(x) + ox, Math.round(y), s.w, s.h); n++; };
  const pal = (a) => ({ skin: a.look?.skin, cook: COOK_COLORS[a.cook || 'hand'], hair: a.hair || 0, sky, dim });
  ctx.drawImage(layer(kit, 'bg', room, W, WD), 0, 0); n++;
  const pf = passFx(st);   // a 1 px shake after Jordan's Approve; the bell bounces when a plate needs him
  if (L.pass) { d(kit.get('pass-glow', room), 0, 156 + pf.dx, 18); for (let i = 0; i < Math.min(3, L.pass); i++) d(kit.get('cloche', room), 0, 155 + pf.dx + i * 11, 33); d(kit.get('bell', room), t % 4000 < 640 ? at(2, 160, t) : 0, 183 + pf.dx, 35 + pf.bell); }
  for (const h of WD.heat || []) d(kit.get('heat', room), h.level, PLACE.heat[0] + h.i * 11, PLACE.heat[1]);
  if (WD.fuse?.tripped) d(kit.get('sparkle', room), (at(4, 90, t) + 2) % 4, PLACE.fuse[0] + 3 + (at(2, 360, t) ? -3 : 2), PLACE.fuse[1] + 8);
  for (const s of smoking(st)) { const i = WD.aside.shelf.indexOf(s.id); d(kit.get('smoke', room), at(4, 260, t, i * 300), PLACE.aside[0] + i * 5, PLACE.aside[1] - 9 - Math.floor((t / 160 + i * 3) % 3)); }
  ctx.fillStyle = P.PALETTE.r;
  for (const tk of L.tickets) {
    const x = sx(tk.x) + TICKET_DX - 5, no = String(tk.id || '').replace(/\D/g, '').slice(-2).padStart(2, '0');
    d(kit.get('ticket', room), 0, x, 4); d(kit.get('digit', room), +no[0], x + 2, 7); d(kit.get('digit', room), +no[1], x + 6, 7);
    if (!tk.queued) { ctx.fillRect(x + 2 + ox, 14, Math.max(1, Math.round((7 * tk.step) / Math.max(1, tk.steps))), 1); n++; }
  }
  const actors = [...st.actors.values()].sort((a, b) => a.y - b.y || a.x - b.x);
  for (const a of actors) if (a.kind === 'chef') {
    const o = pal(a), still = !a.path.length, delay = a.look.delay * 1000, ps = chefPose(st, a);   // a crouch, a hop or a landing squash
    const f = still ? at(2, 450, t, delay) : at(4, 140, t), x = a.x - 8, y = a.y - 23 + (ps?.dy || 0);
    d(kit.get(ps?.name || (still ? 'chef-idle' : 'chef-' + a.dir), o, !ps?.name && !still && a.dir === 'side' && a.flip), ps?.name ? 0 : f, x, y);
    if (a.look.stache && (still || a.dir === 'down')) d(kit.get('stache', o), 0, x + 6, y + 10 + (ps?.name ? 2 : bobOf(P, still ? 'idle' : 'walk', f)));
  }
  ctx.drawImage(layer(kit, 'fg', room, W, WD), 0, 0); n++;
  for (const a of actors) if (a.kind === 'chef' && !a.path.length && a.busy) d(kit.get('work-' + a.st, pal(a)), at(4, 120, t, a.look.delay * 1000), a.x - 8, STAGE.top - 6);
  const cx = (k) => sx(STATIONS[k].x);
  if (L.busy.stove) {
    d(kit.get('oven-glow', room), at(3, 110, t), cx('stove') - 9, STAGE.top + 10); d(kit.get('flame', room), at(3, 110, t), cx('stove') - 3, STAGE.top - 1);
    for (let i = 0; i < 3; i++) d(kit.get('steam', room), at(4, 260, t, i * 300), cx('stove') - 7 + i * 4, STAGE.top - 12 - Math.floor((t / 90 + i * 5) % 8));
  }
  if (L.busy.taste) d(kit.get('steam', room), at(4, 260, t), cx('taste') - 7, STAGE.top - 10 - Math.floor((t / 120) % 5));
  if (L.busy.sink) for (let i = 0; i < 3; i++) d(kit.get('bubble', room), 0, cx('sink') - 8 + ((i * 7 + Math.floor(t / 150)) % 14), STAGE.top - 2 - Math.floor((t / 110 + i * 3) % 6));
  drawFx(st, kit, d, room);   // the moments (moments.js)
  for (const s of st.sparks) { const f = Math.floor((t - s.t) / 90); for (let i = 0; i < 3; i++) d(kit.get('sparkle', room), f + i, s.x - 8 + i * 8, s.y - (i % 2) * 6 - Math.floor(f / 2)); }
  for (const a of actors) if (a.kind !== 'chef') {
    const o = pal(a), x = a.x - 8, y = a.y - 23, walking = a.path.length > 0;
    d(kit.get('shadow', room), 0, x + 1, a.y - 1);
    if (a.kind === 'sleepy') {
      d(kit.get('crate', room), 0, x - 2, a.y - 11); d(kit.get('chef-sleep', { ...o, cook: COOK_COLORS.sous }), at(2, 900, t), x, y - 8);
      d(kit.get('zz', room), 0, x + 14 + at(3, 900, t), y - 12 - at(3, 900, t) * 2); continue;
    }
    if (a.kind === 'sous') {
      if (walking) d(kit.get('chef-side', o, a.flip), at(4, 140, t), x, y); else d(kit.get('chef-sit', o), at(2, 450, t), x, y - 3);
      continue;
    }
    const f = walking ? at(4, 140, t) : at(2, 450, t, a.look.delay * 1000);
    d(kit.get(walking ? 'waiter-side' : 'waiter-idle', o, walking && a.flip), f, x, y);
    d(kit.get('cloche', room), 0, walking ? (a.flip ? x - 4 : x + 10) : x + 3, y + (walking ? 7 : 9) + bobOf(P, walking ? 'walk' : 'idle', f));
  }
  return n;
}
// the tap targets and the words: real links over the canvas, one per ticket, chef and waiter (the canvas itself is aria-hidden)
// o: P = sprites.js (the props' sizes), k = CSS px per art px, W = the room's width, wave = the tapped chef (its words show for 3 s)
export function hitItems(L, ox = 0, o = {}) {
  const ids = L.world?.aside?.ids || [], id = ids[ids.length - 1], spots = chefSpots(L);   // the set-aside shelf: one link, to the newest
  const chefs = L.chefs.map((c) => ({ c, x: spots.get(c.key), word: o.wave === c.key ? c.act : c.word })).sort((a, b) => a.x - b.x);
  const says = placeSays(chefs.filter((h) => h.word).map((h) => ({ kind: 'say', key: 's' + h.c.key, word: h.word.length > 11 ? h.word.slice(0, 10) + '…' : h.word, x: h.x, show: o.wave === h.c.key })), propRects(L.world, o.P), o.k, o.W);
  return [...L.tickets.map((t) => ({ kind: 'ticket', key: 't' + t.key, id: t.id, x: sx(t.x) + TICKET_DX + ox, y: 17, label: `${ticket(t.id)}, open it` })),
    ...chefs.map(({ c, x }) => ({ kind: 'chef', key: c.key, id: c.id, x: x + ox, y: STAGE.aisle - 6, label: c.label + (c.priv || c.cook === 'hand' || c.cook === 'sous' ? '' : ', crew ' + c.cook) })),
    ...says.map((s) => ({ ...s, x: s.bx + ox, y: s.by })),
    ...L.waiters.map((w, i) => ({ kind: 'waiter', key: w.key, id: w.id, x: waiterX(i) + ox, y: STAGE.front, label: w.label })),
    ...(id ? [{ kind: 'aside', key: 'aside', id, x: PLACE.aside[0] + 13 + ox, y: PLACE.aside[1] + 4, label: `${plural(ids.length, 'work order')} failed or stopped; the newest is ${ticket(id)}, open it` }] : [])];
}
// nothing moves (no walk, busy station, sparkle, smoke or spark): 10 fps is enough
export const stageCalm = (st) => !st.L || (![...st.actors.values()].some((a) => a.path.length) && !Object.keys(st.L.busy).length && !st.sparks.length && !st.L.world?.fuse?.tripped && !smoking(st).length && !fxBusy(st));
// the set-aside smoke still under 2 minutes old (real time: the last sync plus the stage clock since)
const smoking = (st) => (st.L.world?.aside?.smoke || []).filter((s) => (st.L.now ?? 0) + st.t - st.syncT < s.until);
export function hitHtml(it, W = STAGE.w) {
  const [w, h] = { ticket: [11, 13], aside: [27, 12] }[it.kind] || [16, 24], pc = (v, of) => ((v / of) * 100).toFixed(2) + '%';
  if (it.kind === 'say') return `<span class="px-say" aria-hidden="true" data-key="${esc(it.key)}" data-css="left:${pc(it.x, W)};top:${pc(it.y, STAGE.h)};bottom:auto;margin:0;pointer-events:none${it.show ? ';display:block' : ''}">${esc(it.word)}</span>`;
  return `<a class="px-a px-${it.kind}" href="#/job/${esc(it.id)}" data-key="${esc(it.key)}" aria-label="${esc(it.label)}" data-css="left:${pc(it.x, W)};top:${pc(it.y - h, STAGE.h)};width:${pc(w, W)};height:${pc(h, STAGE.h)}"></a>`;
}

// ---- in the page ----
let PX = null, KIT = null, CANVAS_OK = null;
const mounted = new Set();
// ?fps in the address times each frame (tick + draw); Settings > About shows the p95
const FPS_ON = /[?&]fps\b/.test(globalThis.location?.search), FRAMES_MS = [];
const frameNote = (ms) => FRAMES_MS.push(ms) > 600 && FRAMES_MS.shift();
export function frameStats(list = FRAMES_MS) {
  const s = [...list].sort((a, b) => a - b), q = (p) => Math.round(s[Math.floor(p * s.length)] * 100) / 100;
  return s.length ? { n: s.length, p50: q(0.5), p95: q(0.95) } : null;
}
// the legend sheet for a mounted scene
export const sceneLegend = (el) => legendHtml(legendRows(el?._px?.st.L || (el?._args && layoutScene(...el._args))));
const reduced = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
const mkCanvas = (w, h) => { const c = document.createElement('canvas'); c.width = w; c.height = h; return c; };
function canvasOk() { if (CANVAS_OK === null) { try { CANVAS_OK = !!mkCanvas(1, 1).getContext('2d'); } catch { CANVAS_OK = false; } } return CANVAS_OK; }
function fit(sc) {
  // the frame hugs the canvas (2px border each side), placed on a whole device pixel
  const r = pixelScale(Math.max(0, (sc.root.parentElement?.clientWidth || 364) - 4), globalThis.devicePixelRatio || 1, sc.compact ? 200 : 320);
  for (const e of [sc.canvas, sc.hit]) Object.assign(e.style, { width: r.cssW + 'px', height: r.cssH + 'px' });
  if (sc.canvas.width !== r.w) { sc.canvas.width = r.w; sc.ctx.imageSmoothingEnabled = false; }
  sc.st.W = r.w; sc.k = r.scale / (globalThis.devicePixelRatio || 1);
  sc.root.style.width = r.cssW + 4 + 'px'; sc.root.style.marginLeft = r.left + 'px';
}
function paint(sc) {
  if (!sc.st.L) return;
  hits(sc); drawStage(sc.ctx, sc.st, KIT); sc.key = frameKey(sc.st, KIT);   // drawn now: the loop draws again only when the picture changes
}
// the links and bubbles over the canvas (again when a tapped chef's wave starts or ends); a moment's line goes to #announce
function hits(sc) {
  sc.wave = sc.st.fx?.wave?.key; const fx = sc.st.fx, a = fx?.line && document.getElementById('announce'); if (a) a.textContent = fx.line; if (fx) fx.line = null;
  sc.hit.innerHTML = hitItems(sc.st.L, (sc.st.W - STAGE.w) >> 1, { P: KIT.P, k: sc.k, W: sc.st.W, wave: sc.wave }).map((it) => hitHtml(it, sc.st.W)).join(''); applyCss(sc.hit);
}
function mountPixel(el, L) {
  let sc = el._px;
  if (!sc || !el.contains(sc.root) || sc.compact !== L.compact) {
    el.innerHTML = `<div class="px-stage${L.compact ? ' compact' : ''}" role="group"><canvas class="px-canvas" width="${STAGE.w}" height="${STAGE.h}" aria-hidden="true"></canvas><div class="px-hit"></div>`
      + '<button class="px-info" type="button" aria-haspopup="dialog" aria-label="What am I looking at?">i</button></div>';
    const root = el.firstElementChild, canvas = root.querySelector('canvas');
    sc = el._px = { root, canvas, ctx: canvas.getContext('2d'), hit: root.querySelector('.px-hit'), st: stageNew(), compact: L.compact };
    sc.ctx.imageSmoothingEnabled = false;
    // the (i) chip: app.js opens the legend sheet
    root.querySelector('.px-info').addEventListener('click', () => el.dispatchEvent(new CustomEvent('scene-legend', { bubbles: true })));
    sc.hit.addEventListener('click', (e) => {   // a tapped chef waves and says what they do for 3 s, then the order opens (a second tap: now)
      const a = e.target.closest?.('.px-chef'), key = a?.getAttribute('data-key'); if (!a || reduced() || sc.st.fx?.wave?.key === key) return;
      e.preventDefault(); sc.tap = key; tapChef(sc.st, key); hits(sc); sc.loop.start(); setTimeout(() => { if (sc.tap === key) location.hash = a.getAttribute('href'); }, FX.wave);
    });
    sc.loop = makeLoop({ raf: (f) => requestAnimationFrame(f), ok: () => stageOk(sc, document, reduced()), fps: () => stageFps(sc.st),
      frame: (dt) => { const t0 = FPS_ON ? performance.now() : 0; stageTick(sc.st, dt); const k = frameKey(sc.st, KIT); if (sc.st.fx?.line || sc.st.fx?.wave?.key !== sc.wave) hits(sc);
        if (k !== sc.key) { sc.key = k; drawStage(sc.ctx, sc.st, KIT); } if (FPS_ON) frameNote(performance.now() - t0); } });   // the same picture is not drawn again
    if (typeof IntersectionObserver === 'function') new IntersectionObserver((es) => { const v = es.some((e) => e.isIntersecting); sc.visible = v; if (v) sc.loop.start(); }).observe(root); if (typeof ResizeObserver === 'function') new ResizeObserver(() => { fit(sc); paint(sc); }).observe(el);
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
  for (const [k, [name, f]] of Object.entries(P.LEGEND_ICONS)) {
    const s = P.stripOf(mkCanvas, name, P.PALETTE), c = mkCanvas(s.w, s.h);
    c.getContext('2d').drawImage(s.img, f * s.w, 0, s.w, s.h, 0, 0, s.w, s.h); root.style.setProperty('--px-lg-' + k, `url("${c.toDataURL()}")`);
  }
  root.classList.add('px');
}
if (typeof document !== 'undefined' && typeof window !== 'undefined') {
  import('./sprites.js').then((P) => {
    PX = P; KIT = makeKit(P, mkCanvas); installChrome(P);
    for (const el of mounted) if (el.isConnected && el._args) mountScene(el, ...el._args);
  }).catch(() => { /* no sprites (offline before the first load): the SVG scene stays */ });
  document.addEventListener('visibilitychange', () => { for (const el of mounted) if (!el.isConnected) mounted.delete(el); else el._px?.loop.start(); });
}
