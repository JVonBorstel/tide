// The Purpose Ledger of the Board's scene (board concept 2026-10-26, P8 "nothing decorative"; critic audits/art-critique-S7 #3 and #4):
// one row per thing the stage draws. Nothing may be drawn that no row declares, every data row names the real field it shows and where
// that field comes from, and every data mark has a door (a tap that opens its work order, or its line in the legend sheet).
// pass-app/test-scene.mjs enforces it: undeclared sprites, unknown fields or events, marks without a door and pictures that do not
// change when their field does all fail the tests. A new prop is one row here plus its sprite.
// kind: 'data' (bound to a field; its legend line and its door), 'ground' (structure with no field: the sky, slab, rail, stations; capped
// by the tests so decoration cannot creep back). Coordinates are art pixels on the 192-wide stage (the same ones the bake uses).
import { ticket } from './scene.js';
import { WORLD, PLACE, plural } from './world.js';

const STATE = '/api/state';   // GET /api/state and its SSE stream /api/stream carry every field below (server.mjs)
const world = (prop, sprites, fields, extra = {}) => ({ id: prop, kind: 'data', world: prop, sprites, fields, endpoint: STATE, tap: 'legend',
  changes: 'its fields change: ' + fields.join(', '), absent: 'nothing (world.js WORLD: a missing field draws nothing)', ...extra });
export const PURPOSE = [
  // the people: each crew member is a running work order (its station, its crew's hat, its work loop and busy effect); its face is the
  // work order's id (the same order always looks the same)
  { id: 'crew', kind: 'data', sprites: ['chef-down', 'chef-up', 'chef-side', 'chef-idle', 'stache', 'work-board', 'work-stove', 'work-taste', 'work-sink', 'work-plate', 'oven-glow', 'flame', 'steam', 'sparkle', 'bubble'],
    fields: ['jobs'], endpoint: STATE, changes: 'a work order starts or ends a step (status, step, station, role, cook)', absent: 'no crew', tap: 'job',
    legend: (L) => L.chefs.length ? `Crew at the stations: ${plural(L.chefs.length, 'work order')} building; the hard hat is the crew (Claude orange, Gemini blue, Claude via Google purple, Home crew green, Yard hands grey) and a face is its work order.` : null },
  { id: 'hoist', kind: 'data', sprites: ['hoist-open'], fields: ['jobs'], endpoint: STATE, changes: 'a work order starts a step: its crew arrives by the hoist', absent: 'the gate stays shut',
    tap: 'legend', box: (L) => (L.chefs.length ? [0, 26, 18, 30] : null), legend: (L) => L.chefs.length ? 'Hoist cage: its gate stands open while a crew arrives for a step.' : null },
  { id: 'cards', kind: 'data', sprites: ['ticket', 'digit'], fields: ['jobs'], endpoint: STATE, changes: 'a work order is queued, starts or moves a step', absent: 'an empty job board', tap: 'job',
    legend: (L) => L.tickets.length ? `Job board: ${plural(L.tickets.length, 'work-order card')}; a card shows the last two digits of its number and its step bar (empty: next up).` : null },
  // the site cabin: its window glows while a sign-off waits, runners bring the clipboards, the bell rings; a tap opens the oldest wait
  { id: 'signoff', kind: 'data', sprites: ['pass-glow', 'cloche', 'bell', 'waiter-side', 'waiter-idle'], fields: ['jobs'], events: ['approval.requested'], endpoint: STATE,
    changes: 'a work order waits for sign-off (waiting-approval, needs-human)', absent: 'dark glass, no runners', tap: 'job',
    box: (L) => (L.pass ? [156, 18, 32, 20] : null), href: (L) => oldestWait(L),
    legend: (L) => L.pass ? `Site cabin: ${plural(L.pass, 'work order')} waiting for your sign-off; its window glows only while one waits.` : null },
  { id: 'handed', kind: 'data', sprites: ['waiter-side', 'cloche', 'sparkle'], fields: [], events: ['job.done'], endpoint: STATE, changes: 'a work order is handed over (job.done, the last 3 minutes)',
    absent: 'nobody carries a crate out', tap: 'job', legend: (L) => L.runners.length ? `Handed over in the last 3 minutes: ${L.runners.map((r) => ticket(r.id)).join(', ')}.` : null },
  { id: 'idle', kind: 'data', sprites: ['crate', 'chef-sleep', 'zz'], fields: ['jobs'], endpoint: STATE, changes: 'no work order is building', absent: 'nobody asleep', tap: 'legend',
    box: (L) => (L.idle ? [6, 82, 22, 26] : null), legend: (L) => L.idle ? 'Asleep on a crate: nothing is building.' : null },
  // night shift: the work light throws a pool on the slab only while crews work after dark and the light is on
  { id: 'pool', kind: 'data', sprites: ['pool'], fields: ['jobs', 'breaker'], endpoint: STATE, changes: 'crews at work after dark (the phone\'s hour) with the work light on', absent: 'no pool',
    tap: 'legend', box: (L) => (nightShift(L) ? [152, 57, 40, 8] : null), legend: (L) => nightShift(L) ? 'Warm light on the slab: crews at work after dark.' : null },
  // the world props (world.js WORLD: field, absent, meaning); each door opens its legend line, the sign-off lights open their own wait
  world('sign', ['sign', 'chain', 'chair-up', 'tape'], ['paused', 'live'], { box: () => [...PLACE.sign, 25, 12] }),
  world('clock', ['clock', 'clock-min', 'clock-hour'], ['lastTick', 'stalled'], { box: () => [...PLACE.clock, 13, 13] }),
  world('sous', ['chef-sit', 'chef-side', 'cloche', 'stool'], ['lastTick', 'stalled'], { box: () => [PLACE.sous - 8, 82, 16, 26] }),
  world('fuse', ['fuse', 'lamp', 'lamp-off', 'sparkle'], ['breaker'], { box: () => [...PLACE.fuse, 10, 12] }),
  world('jar', ['coin-jar', 'jar-lock', 'chain'], ['spent', 'budget'], { events: ['budget.stop'], box: () => [...PLACE.jar, 9, 10] }),
  world('aside', ['aside-shelf', 'plate-aside', 'plus', 'digit', 'smoke'], ['jobs'], { events: ['job.quarantined'], tap: 'job', box: (L) => (L.world.aside.ids.length ? null : [...PLACE.aside, 27, 12]) }),   // an empty bench: its legend line; a full one links its newest
  world('spike', ['tag', 'plus', 'digit'], ['jobs'], { box: () => [...PLACE.tag, 15, 9] }),
  world('heat', ['heat'], ['jobs'], { events: ['approval.requested'], tap: 'job' }),
  world('letters', ['cork', 'letter'], ['due'], { box: () => [...PLACE.cork, 18, 12] }),
  world('specials', ['chalk', 'tally', 'chalk-digit'], ['leads'], { box: () => [...PLACE.chalk, 19, 13] }),
  world('recipes', ['recipes'], ['ideas'], { box: () => [...PLACE.recipes, 9, 8] }),
  world('hats', ['hooks', 'hat'], ['cooks'], { box: () => [...PLACE.hooks, 22, 10] }),
  // the moments (moments.js MOMENTS): each plays once for a real event under 2 minutes old, at the crew member or the cabin it is about
  { id: 'moments', kind: 'data', sprites: ['pan-flip', 'chef-crouch', 'chef-squash', 'puff', 'mitt', 'smoke-dark', 'check', 'confetti', 'banner', 'sparkle', 'crate'], fields: [],
    events: ['step.done', 'step.rework', 'job.quarantined', 'approval.requested', 'job.done'], endpoint: STATE, changes: 'a real Yard event under 2 minutes old', absent: 'no moment',
    tap: 'crew', legend: () => null },
  // ground: structure with no field (allowed by P8, capped by the tests). The sky's colours are the phone's real hour
  { id: 'sky', kind: 'ground', sprites: ['wall', 'sun', 'moon'], why: 'the real hour\'s sky over the open top floor' },
  { id: 'site', kind: 'ground', sprites: ['subway', 'floor-a', 'floor-b', 'edge', 'door', 'rail', 'pass', 'shadow'], why: 'the guard rail, slab, hoist cage, gantry and job-board beam, site cabin, shadows' },
  { id: 'stations', kind: 'ground', sprites: ['counter', 'stove', 'sink', 'pallet', 'board', 'pot', 'bowl', 'plates'], why: 'the five stations where steps happen (crews make them data)' },
];
const oldestWait = (L) => { const h = [...(L.world?.heat || [])].sort((a, b) => b.mins - a.mins)[0]; return h?.id || L.waiters[0]?.id || null; };
export const nightShift = (L) => L.sky === 'night' && !!L.world?.fuse && !L.world.fuse.tripped && Object.keys(L.busy || {}).length > 0;
export const purposeOf = (id) => PURPOSE.find((r) => r.id === id);

// ---- the City's Purpose Ledger (public/city.js, the Board's home; review F7): one row per mark the City draws ----
// A data row names the model fields it shows (city.js cityOf: k, band, lots.*, gate.*, yard.*), where they come from (/api/towers or the
// live state), its legend line (the start of a city.js legendRows line; null: a mark with no line yet) and what a missing field draws.
// A ground row is structure with no field (capped by the tests); a words row is said in the caption, never drawn; a route row is drawn
// from the City's own route (the hash), not from a record. pass-app/test-city.mjs
// enforces it: every model field and every City sprite (city-art.js) has a row, every legend line is a row's, and every data row's
// field changes the picture.
const TW = 'GET /api/towers (towers.mjs)';
const city = (id, art, fields, from, legend, absent) => ({ id, kind: 'data', art, fields, from, legend, absent });
export const CITY_PURPOSE = [
  city('building', ['RAMPS'], ['k', 'band', 'lots.key', 'lots.kind', 'lots.name', 'lots.floors', 'lots.rows'], TW + ': its floors (merged PRs)', '1 row = ', 'no building'),
  city('base', [], ['lots.plinth'], TW + ': git commit counts', 'Stone base', 'no stone base'),
  city('lit', [], ['lots.lit'], TW + ': floors merged in the last 24 h (the Office: its last commit)', 'Yellow windows', 'dark windows'),
  city('public', [], ['lots.publicAt'], TW + ': publicFrom', 'Dashed line', 'no line'),
  city('blueprint', [], ['lots.blueprint'], TW + ': blueprint (ledger.json)', 'Dashed outline', 'no outline'),
  city('crane', ['CI', 'PAINT'], ['lots.cranes', 'lots.craneMore'], TW + ': open PRs and their CI', 'A level on the roof', 'no crane'),
  city('crew', ['WORKER', 'TOOLS'], ['lots.crews', 'lots.crewMore', 'yard.running'], STATE + ': jobs (running)', 'Hard hats', 'no crew'),
  city('pallets', ['PALLET'], ['lots.pallets', 'lots.palletMore', 'yard.queued'], STATE + ': jobs (pending)', 'Pallets', 'no pallet'),
  city('beacon', ['BEACON'], ['lots.beacon', 'lots.waiting', 'yard.beacon', 'yard.waiting'], STATE + ': jobs waiting for sign-off, approval.requested', 'Beacon', 'no beacon'),
  city('scaffold', [], ['lots.scaffold'], STATE + ': mainStatus', 'Scaffolding', 'no scaffolding'),
  city('tape', [], ['lots.tape', 'lots.closes'], STATE + ': freeze', 'Striped barrier', 'no barrier'),
  city('skip', ['SKIP'], ['lots.skip'], TW + ': floors taken down; ' + STATE + ': undoUnpushed', 'Skip', 'no skip'),
  city('flag', ['FLAG'], ['lots.fresh'], TW + ': floors since the phone last looked', 'Flag on a roof', 'no flag'),
  city('private', ['LOCK'], ['lots.private', 'yard.private'], TW + ': private (the repo\'s GitHub visibility); ' + STATE + ': private work orders', 'Padlock over a building', 'no padlock'),
  city('manual', [], ['lots.manual'], STATE + ': automergePause', null, 'no tag'),
  city('sign', ['GL'], ['gate.paused', 'gate.live'], STATE + ': paused, live', 'Gate sign', 'no sign'),
  city('meter', [], ['gate.budget'], STATE + ': spent, budget; budget.stop', 'Meter on the cabin', 'no meter'),
  city('breaker', [], ['gate.breaker'], STATE + ': breaker', null, 'no stop tag'),
  city('clock', [], ['gate.stalled'], STATE + ': stalled', null, 'no clock'),
  city('github', [], ['gate.github'], TW + ': githubAt, githubError', 'GH sign', 'no sign'),
  city('yard', [], ['yard.running', 'yard.queued', 'yard.waiting'], STATE + ': jobs with no Tower', 'Workshop by the gate', 'an empty workshop'),
  { id: 'focus', kind: 'route', fields: [], from: 'the location hash (city-nav.js routeOf)', why: 'the building the route is on: dotted guides and an underline, at once on a tap' },
  { id: 'caption', kind: 'words', fields: ['loading', 'error'], why: 'said in the caption under the City (reading, could not be read), never drawn' },
  { id: 'sky', kind: 'ground', art: [], fields: ['sky'], why: 'the real hour\'s sky with the sun or the moon and stars' },
  { id: 'street', kind: 'ground', art: [], fields: [], why: 'the street, its kerb and dashes' },
  { id: 'lot', kind: 'ground', art: [], fields: [], why: 'a lot\'s fence and sign (a project with no floors yet)' },
  { id: 'office', kind: 'ground', art: [], fields: [], why: 'the Office building, its window frames and door' },
  { id: 'cabin', kind: 'ground', art: [], fields: [], why: 'the gate cabin and its door, the workshop shell' },
];
// the legend sheet: one line per data row the stage shows now, in ledger order (the world props say their line from WORLD)
export const legendRows = (L) => PURPOSE.filter((r) => r.kind === 'data').map((r) => {
  if (r.world) { const w = L?.world?.[r.world], row = WORLD.find((x) => x.prop === r.world); return w ? { key: r.id, text: row.meaning(w) } : null; }
  const text = L && r.legend?.(L); return text ? { key: r.id, text } : null;
}).filter(Boolean);
// the doors for the marks that have no link of their own: one per data row on the stage with a box; a sign-off light or the cabin
// opens its work order, the rest open the mark's legend line (rect in art px: x, y, w, h)
export function markItems(L, ox = 0) {
  const out = [];
  for (const r of PURPOSE) {
    if (r.kind !== 'data' || !r.box || (r.world && !L.world?.[r.world])) continue;
    const b = r.box(L); if (!b) continue;
    const id = r.href?.(L), line = legendRows(L).find((x) => x.key === r.id);
    out.push({ kind: 'mark', key: 'm-' + r.id, row: r.id, id, x: b[0] + b[2] / 2 + ox, y: b[1] + b[3], w: b[2], h: b[3], label: id ? `${ticket(id)} needs your sign-off, open it` : `${line?.text || r.id} Tap for the legend.` });
  }
  for (const h of L.world?.heat || []) out.push({ kind: 'mark', key: 'm-heat' + h.i, row: 'heat', id: h.id, x: PLACE.heat[0] + h.i * 11 + 4 + ox, y: PLACE.heat[1] + 6, w: 8, h: 6, label: `${ticket(h.id)} waiting for sign-off, open it` });
  return out;
}
