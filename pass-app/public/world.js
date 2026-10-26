// The world of the kitchen (plans/chef-art-2.md wave 1): every prop in the pixel room is one real state field, mapped in WORLD.
// Pure and tested in node (pass-app/test-scene.mjs); scene.js draws it, app.js shows the legend sheet. No network, no storage.
import { COOK_COLORS, esc, ticket } from './scene.js';

// where the world props stand (wall, shelf and floor space the room already had)
export const PLACE = { clock: [3, 12], sign: [24, 15], cork: [20, 32], hooks: [39, 33], chalk: [61, 32], jar: [80, 16], recipes: [91, 18], fuse: [181, 2],
  aside: [124, 45], tag: [149, 4], stool: [36, 100], sous: 41, round: 128, heat: [156, 18] };
// ---- the world map (plans/chef-art-2.md wave 1): one real field per prop; a missing field draws nothing; motion only for a real
// change or an event under 2 min old; private orders give numbers only. meaning(w) is its line in the legend sheet ----
const money = (v) => '$' + (Math.round(v * 100) / 100).toFixed(2).replace(/\.00$/, '');
export const plural = (n, one, many = one + 's') => `${n} ${n === 1 ? one : many}`;
const waitWords = (m) => m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`;
const clockWords = (t) => new Date(t).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
export const RESTING = ['resting', 'capped', 'off', 'signed-out'];
export const WORLD = [
  { prop: 'sign', from: 'paused, live', absent: 'either', meaning: (w) => ({ closed: 'Window sign CLOSED: you paused the Yard.', lit: 'Window sign OPEN, lit: AI crews on.', open: "Window sign OPEN, not lit: AI crews off (AI steps only show what they'd do)." })[w.state] },
  { prop: 'clock', from: 'lastTick, stalled', absent: 'either', meaning: (w) => w.frozen ? `Clock stopped at ${clockWords(w.at)}: no walkround for 10+ min.` : 'Clock: real time; it stops if the walkrounds stop.' },
  { prop: 'sous', from: 'lastTick, stalled', absent: 'either', meaning: (w) => w.here ? 'Dispatcher on the stool: one lap of the line per walkround.' : 'Empty stool: the walkrounds stopped.' },
  { prop: 'fuse', from: 'breaker', absent: 'breaker', meaning: (w) => w.tripped ? 'Fuse box sparking: stop-work order (too many steps failed), new work waits; hatch lamp out.' : 'Fuse box shut: no stop-work order.' },
  { prop: 'jar', from: 'spent, budget, budget.stop', absent: 'spent or budget', meaning: (w) => `Coin jar: ${money(w.spent)} of today's ${money(w.budget)} cap (pay-per-use estimate), ${w.level} of 8.${w.locked ? ' Padlock: the cap stopped new work today.' : ''}` },
  { prop: 'aside', from: 'jobs, job.quarantined', absent: 'jobs', meaning: (w) => w.ids.length ? `The bench: ${plural(w.ids.length, 'work order')} failed or stopped (${w.shelf.map(ticket).join(', ')}${w.more ? ` +${w.more}` : ''})${w.smoke.length ? ', smoke = in the last 2 min' : ''}.` : 'The bench: empty, nothing failed or stopped.' },
  { prop: 'spike', from: 'jobs', absent: 'jobs (or 8 tickets or fewer)', meaning: (w) => `Rail tag: ${w.n} more queued.` },
  { prop: 'heat', from: 'jobs, approval.requested', absent: 'its event', meaning: (w) => 'Heat lamps: ' + w.map((h) => `${ticket(h.id)} ${waitWords(h.mins)}${['', ' (ember, 1 h+)', ' (red, 4 h+)'][h.level]}`).join(', ') + ' waiting for sign-off.' },
  { prop: 'letters', from: 'due', absent: 'due', meaning: (w) => `Cork board: ${plural(w.n, 'job-hunt follow-up')} due.` },
  { prop: 'specials', from: 'leads', absent: 'leads', meaning: (w) => `Chalkboard: ${plural(w.n, 'new client lead')}.` },
  { prop: 'recipes', from: 'ideas', absent: 'ideas', meaning: (w) => `Idea box: ${plural(w.n, 'new idea')}.` },
  { prop: 'hats', from: 'cooks', absent: 'cooks', meaning: (w) => w.length ? 'Hats on hooks: ' + w.map((h) => h.name + ' ' + h.status.replace('-', ' ')).join(', ') + '.' : 'Hooks empty: no crew resting.' },
];
const num = (v) => typeof v === 'number' && Number.isFinite(v);
const bool = (v) => typeof v === 'boolean';
const tsOf = (v) => { const t = typeof v === 'string' || num(v) ? new Date(v).getTime() : NaN; return Number.isFinite(t) ? t : null; };
const ASIDE_AT = ['quarantined', 'killed', 'failed'];
// state + events -> props (pure, tested in node)
export function worldOf(s, events = [], now = Date.now()) {
  const W = {}; if (!s || typeof s !== 'object') return W;
  const ev = Array.isArray(events) ? events.filter((e) => e && typeof e === 'object') : [];
  if (bool(s.paused) && (s.paused || bool(s.live))) W.sign = { state: s.paused ? 'closed' : s.live ? 'lit' : 'open' };
  const tick = tsOf(s.lastTick);
  if (tick !== null && bool(s.stalled)) {
    const shown = s.stalled ? tick : now, d = new Date(shown);
    W.clock = { frozen: s.stalled, at: shown, min: Math.floor(d.getMinutes() / 5), hour: d.getHours() % 12 };
    W.sous = { here: !s.stalled, tick: String(s.lastTick), fresh: now - tick < 2 * 60 * 1000 };
  }
  if (bool(s.breaker)) W.fuse = { tripped: s.breaker };
  if (num(s.spent) && num(s.budget) && s.budget > 0) {
    const today = new Date(now).toDateString();
    W.jar = { spent: s.spent, budget: s.budget, level: Math.max(0, Math.min(8, Math.floor((8 * s.spent) / s.budget))),
      locked: ev.some((e) => e.type === 'budget.stop' && tsOf(e.ts) !== null && new Date(e.ts).toDateString() === today) };
  }
  if (Array.isArray(s.jobs)) {
    const jobs = s.jobs.filter((j) => j && typeof j === 'object');
    const aside = jobs.filter((j) => ASIDE_AT.includes(j.status)).map((j) => j.id).sort((a, b) => idNo(a) - idNo(b));
    const smoke = new Map();
    for (const e of ev) if (e.type === 'job.quarantined' && aside.includes(e.job)) { const t = tsOf(e.ts); if (t !== null && now - t < 2 * 60 * 1000 && now >= t) smoke.set(e.job, t + 2 * 60 * 1000); }
    const shelf = aside.slice(-5);   // the newest five stand on the shelf
    W.aside = { ids: aside, shelf, more: aside.length - shelf.length, smoke: shelf.filter((id) => smoke.has(id)).slice(-2).map((id) => ({ id, until: smoke.get(id) })) };
    const rail = jobs.filter((j) => j.status === 'running' || j.status === 'pending').length;
    if (rail > 8) W.spike = { n: rail - 8 };
    const asks = jobs.filter((j) => j.status === 'waiting-approval' || j.status === 'needs-human').slice(0, 3);
    const heat = asks.map((j, i) => {
      const want = j.approval?.id; let t = null;
      for (const e of ev) if (e.type === 'approval.requested' && e.job === j.id && (!want || !e.approval || e.approval === want)) { const x = tsOf(e.ts); if (x !== null && (t === null || x > t)) t = x; }
      if (t === null) return null;
      const mins = Math.max(0, Math.floor((now - t) / 60000));
      return { i, id: j.id, mins, level: mins >= 240 ? 2 : mins >= 60 ? 1 : 0 };
    }).filter(Boolean);
    if (heat.length) W.heat = heat;
  }
  if (num(s.due)) W.letters = { n: Math.max(0, s.due) };
  if (num(s.leads)) W.specials = { n: Math.max(0, s.leads) };
  if (num(s.ideas)) W.recipes = { n: Math.max(0, s.ideas) };
  if (s.cooks && typeof s.cooks === 'object' && !Array.isArray(s.cooks)) {
    W.hats = Object.entries(s.cooks).filter(([, c]) => RESTING.includes(c?.status)).map(([name, c]) => ({ name, status: c.status, color: COOK_COLORS[name] || COOK_COLORS.hand }));
  }
  return W;
}
const idNo = (id) => Number(String(id || '').replace(/\D/g, '')) || 0;
// the stage's aria-label words
export const worldWords = (W = {}) => [W.sign && 'the Yard ' + { closed: 'paused', lit: 'open, AI crews on', open: 'open, AI crews off' }[W.sign.state], W.clock?.frozen && 'the walkrounds stopped',
  W.fuse?.tripped && 'stop-work order', W.jar && `${money(W.jar.spent)} of ${money(W.jar.budget)} spent${W.jar.locked ? ', daily cap reached' : ''}`, W.aside?.ids.length && `${W.aside.ids.length} failed or stopped`].filter(Boolean).join(', ');
// the legend sheet: one row per world prop in the room
export const legendRows = (L) => WORLD.filter((r) => L?.world?.[r.prop]).map((r) => ({ key: r.prop, text: r.meaning(L.world[r.prop]) }));
export function legendHtml(rows) {
  if (!rows?.length) return '<p class="empty-line">The Yard has not sent its state yet.</p>';
  return `<ul class="wl-list">${rows.map((r) => `<li><span class="wl-ico" aria-hidden="true" data-css="background-image:var(--px-lg-${esc(r.key)}, none)"></span><span>${esc(r.text)}</span></li>`).join('')}</ul>`;
}
// the still props' levels as one key: the cached layers bake again only when one changes (not for the clock's ms or a lamp's minutes)
export const worldKey = (W = {}) => JSON.stringify(W, (k, v) => (['at', 'tick', 'fresh', 'heat', 'smoke', 'ids', 'name', 'status', 'spent', 'budget'].includes(k) ? undefined : v));
export function bakeWorld(W, d) {
  const num = (name, n, x, y) => [...String(Math.min(99, n))].forEach((c, i) => d(name, x + i * 4, y, +c)), [cx, cy] = PLACE.cork, [ax, ay] = PLACE.aside;
  if (W.clock) { d('clock', ...PLACE.clock); d('clock-hour', ...PLACE.clock, W.clock.hour); d('clock-min', ...PLACE.clock, W.clock.min); }
  if (W.sign) d('sign', ...PLACE.sign, { open: 0, lit: 1, closed: 2 }[W.sign.state]);
  if (W.letters) { d('cork', cx, cy); for (let i = 0; i < Math.min(6, W.letters.n); i++) d('letter', cx + 1 + (i % 3) * 5 + (i % 3 ? 1 : 0), cy + 1 + Math.floor(i / 3) * 5); }
  if (W.hats) { d('hooks', ...PLACE.hooks); W.hats.slice(0, 4).forEach((h, i) => d('hat', PLACE.hooks[0] + i * 5, PLACE.hooks[1] + 2, 0, { cook: h.color })); }
  if (W.specials) { const [x, y] = PLACE.chalk, n = W.specials.n; d('chalk', x, y); if (n <= 10) d('tally', x + 1, y + 4, n); else num('chalk-digit', n, x + 5, y + 4); }
  if (W.jar) { d('coin-jar', ...PLACE.jar, W.jar.level); if (W.jar.locked) d('jar-lock', PLACE.jar[0], PLACE.jar[1] - 2); }
  if (W.recipes) d('recipes', ...PLACE.recipes, Math.min(4, W.recipes.n));
  if (W.fuse) d('fuse', ...PLACE.fuse, +W.fuse.tripped);
  if (W.aside) { d('aside-shelf', ax, ay); W.aside.shelf.forEach((_, i) => d('plate-aside', ax + 1 + i * 5, ay - 3)); if (W.aside.more) { d('plus', ax + 2, ay + 4); num('digit', W.aside.more, ax + 6, ay + 4); } }
  if (W.spike) { const [x, y] = PLACE.tag; d('tag', x, y); d('plus', x + 2, y + 3); num('digit', W.spike.n, x + 6, y + 3); }
  if (W.sous) d('stool', ...PLACE.stool);
}
