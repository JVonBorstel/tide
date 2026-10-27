// Tests for the scene's stage (pass-app/public/scene.js and sprites.js, pass-app/SCENE.md): stations, placement, looks, privacy,
// the still card, the pixel stage, motion, the loop, crisp pixels, the tap layer and the chrome. Run by pass-app/test-scene.mjs (first).
import fs from 'node:fs';
import { layoutScene, sceneHtml, stationFor, cookOf, lookOf, skyAt, hashId, activityWord, STATIONS, COOK_COLORS, STAGE, pixelScale,
  stageNew, stageSync, stageTick, drawStage, makeKit, makeLoop, hitItems, hitHtml } from './public/scene.js';
import * as P from './public/sprites.js';

export const out = [];
export const check = (name, pass) => out.push({ name, pass: !!pass });
export const job = (id, o = {}) => ({ id, name: `improve: secret plan ${id}`, status: 'running', step: 3, steps: 11, station: 'agent', role: 'do', cook: 'claude sonnet', ...o });
const at = (L, id) => L.chefs.find((c) => c.id === id);

// stations follow the step
check('station: plan at the Survey table', stationFor(job('J1', { role: 'plan' })) === 'board');
check('station: code at the Workbench', stationFor(job('J1', { role: 'do' })) === 'stove' && stationFor(job('J1', { station: 'repair', role: '' })) === 'stove');
check('station: review at the Inspection desk', stationFor(job('J1', { role: 'check' })) === 'taste');
check('station: tests, lint and mutation at the Test rig', ['tests', 'lint', 'mutate'].every((s) => stationFor(job('J1', { station: s, role: '' })) === 'sink'));
check('station: commit, freshen and merge at the Handover bay', ['commit', 'freshen', 'merge'].every((s) => stationFor(job('J1', { station: s, role: '' })) === 'plate'));
check('station: anything unknown is built at the Workbench', stationFor(job('J1', { station: 'something-new', role: '' })) === 'stove');
check('cook: colour by the cook that took it; non-AI steps are the kitchen hand', cookOf(job('J1')) === 'claude' && cookOf(job('J1', { station: 'tests', cook: '' })) === 'hand' && cookOf(job('J1', { cook: '' })) === 'sous');

// placement
const two = layoutScene({ jobs: [job('J1'), job('J2')] });
check('place: two chefs at one station stand apart, centred on it', at(two, 'J1').x < at(two, 'J2').x && Math.abs((at(two, 'J1').x + at(two, 'J2').x) / 2 - STATIONS.stove.x) < 0.2);
const between = layoutScene({ jobs: [job('J3', { status: 'pending', step: 5 }), job('J4', { status: 'pending', step: 1 })] });
check('place: an order between steps keeps its chef (no walking out and back every step)', at(between, 'J3') && !at(between, 'J3').busy);
check('place: an order not started yet is only a ticket on the rail', !at(between, 'J4') && between.tickets.some((t) => t.id === 'J4' && t.queued));
const many = layoutScene({ jobs: Array.from({ length: 10 }, (_, i) => job('J' + (10 + i))) });
check('place: at most 6 chefs on the floor and 8 tickets on the rail', many.chefs.length === 6 && many.tickets.length === 8);
check('place: compact (Pass tab) keeps 4 chefs and no words', layoutScene({ jobs: many.chefs.map((c) => job(c.id)) }, [], { compact: true }).chefs.every((c) => !c.word) && layoutScene({ jobs: Array.from({ length: 10 }, (_, i) => job('J' + i)) }, [], { compact: true }).chefs.length === 4);
const wait = layoutScene({ jobs: [job('J5', { status: 'waiting-approval' }), job('J6', { status: 'needs-human' }), job('J7', { status: 'waiting-approval' }), job('J8', { status: 'waiting-approval' })] });
check('pass: a waiter at the pass for each order waiting for Jordan (3 at most), and the count', wait.waiters.length === 3 && wait.pass === 4 && wait.waiters.every((w) => w.x >= 320));
check('nothing cooking: the sleepy chef is on his crate; the still card says Nothing building.', wait.idle && /<p class="sc-idle" data-key="idle">Nothing building\.<\/p>/.test(sceneHtml({ jobs: [] }, [])));
const now = Date.parse('2026-10-15T12:00:00Z');
const ev = [{ type: 'job.done', job: 'J9', ts: '2026-10-15T11:59:00Z' }, { type: 'job.done', job: 'J10', ts: '2026-10-15T11:40:00Z' }];
const run = layoutScene({ jobs: [] }, ev, {}, now);
check('served: a finished plate in the last 3 minutes is run out; older news is not', run.runners.length === 1 && run.runners[0].id === 'J9');

// stationFor with a plain step name as well as a job
check('station: a step name string maps directly (any case)', stationFor('plan') === 'board' && stationFor('TESTS') === 'sink' && stationFor('commit') === 'plate' && stationFor('check') === 'taste' && stationFor('nope') === 'stove');
// busy stations
const bz = layoutScene({ jobs: [job('J1'), job('J3', { role: 'plan', status: 'pending', step: 4 })] });
check('busy: a running chef lights its station; a chef between steps does not', bz.busy.stove === true && !bz.busy.board && !at(bz, 'J1').word.startsWith('next') && at(bz, 'J1').busy === true);
// bubble words
const wz = layoutScene({ jobs: [job('J1'), job('J3', { role: 'plan', status: 'pending', step: 4 })] });
check('words: running chef says what it does; between steps says what is next', at(wz, 'J1').word === 'building' && at(wz, 'J3').word === 'next: planning');
// exact looks
const lk = (id) => { const h = hashId(id); return { hat: 6 + ((h >>> 4) % 4) * 1.5, stache: ((h >>> 8) & 3) === 0, delay: ((h >>> 11) % 40) / 10 }; };
const ids = Array.from({ length: 24 }, (_, i) => 'J' + i);
check('look: hat height, moustache and delay follow the id hash exactly', ids.every((id) => { const l = lookOf(id), e = lk(id); return l.hat === e.hat && l.stache === e.stache && l.delay === e.delay && /^#[0-9a-f]{6}$/.test(l.skin); }));
check('look: some orders wear a moustache and some do not', ids.some((id) => lookOf(id).stache) && ids.some((id) => !lookOf(id).stache));

// looks and sky
check('look: the same order always looks the same', JSON.stringify(lookOf('J42')) === JSON.stringify(lookOf('J42')) && hashId('J42') === hashId('J42'));
check('look: different orders look different', new Set(['J1', 'J2', 'J3', 'J4', 'J5', 'J6', 'J7', 'J8'].map((id) => JSON.stringify(lookOf(id)))).size >= 6);
check('sky: dawn, day, dusk and night by the hour', skyAt(6) === 'dawn' && skyAt(12) === 'day' && skyAt(19) === 'dusk' && skyAt(23) === 'night' && skyAt(3) === 'night');

// privacy: no words from a private order anywhere
const priv = job('J11', { private: true, activity: [{ tool: 'Edit', target: 'C:/secret/diary.md' }] });
const ph = sceneHtml({ jobs: [priv] }, []);
check('private: no bubble words, no target, no order name', !/diary|secret/.test(ph) && !at(layoutScene({ jobs: [priv] }), 'J11').word && /a private work order/.test(ph));
check('private: activityWord gives the tool word only', activityWord(priv) === 'Editing');
check('words: a public order shows what the cook is doing', /Editing app\.js/.test(sceneHtml({ jobs: [job('J12', { activity: [{ tool: 'Edit', target: 'pass-app/public/app.js' }] })] }, [])));
check('words: order names never appear in the scene', !/secret plan/.test(sceneHtml({ jobs: [job('J13')] }, [])));
check('escape: odd ids cannot break the markup', !/<script/.test(sceneHtml({ jobs: [job('J1"><script>')] }, [])));

// the still card (rename S7a): before sprites.js loads, or for good if it cannot, the scene is a card with the same links and no motion
const full = sceneHtml({ jobs: [...Array.from({ length: 8 }, (_, i) => job('J' + (20 + i), { role: ['plan', 'do', 'check', 'do', 'plan', 'do', 'do', 'do'][i] })),
  job('J30', { status: 'waiting-approval' }), job('J31', { status: 'waiting-approval' }), job('J32', { status: 'waiting-approval' }), job('J33', { status: 'needs-human' })] }, ev, {}, now);
const links = full.match(/<a [^>]*>/g) || [];
check('StillCardLinks: every crew member, work-order card, runner and handed-over work order is a link to its order, with its words', /<a class="sc-crew cook-claude" href="#\/job\/J20"[^>]*aria-label="WO-0020 planning, open it, crew claude"/.test(full)
  && /<a class="sc-card" href="#\/job\/J20"/.test(full) && /<a class="sc-wait" href="#\/job\/J30"[^>]*aria-label="WO-0030 needs your sign-off, open it"/.test(full)
  && /<a class="sc-done" href="#\/job\/J9"/.test(full) && links.length === 6 + 8 + 3 + 1 && links.every((t) => /href="#\/job\/[^"]+" data-key="[^"]+" aria-label="[^"]+"/.test(t)) && /<span class="sc-more">\+1<\/span>/.test(full));
check('StillCardSite: the card speaks site words (Survey table, Workbench, Inspection desk; Job board, Sign-off window) and no kitchen words',
  /Survey table/.test(full) && /Workbench/.test(full) && /Inspection desk/.test(full) && /Job board/.test(full) && /Sign-off window/.test(full)
  && !/chef|cook\b|toque|stove|sink|pass\b|PASS|plate|ticket|rail|cloche|kitchen/i.test(full.replace(/cook-\w+|--cook:/g, '')));
check('StillCardStill: no SVG, no animation, no transform and no style attribute in the card (0 animated parts)', !/<svg|animat|transform|style=|class="[^"]*\b(actor|bob|walking|flame|bell)\b/.test(full));
const stillCss = (() => { const css = fs.readFileSync(new URL('./public/app.css', import.meta.url), 'utf8'), i = css.indexOf('/* ---- the scene before the pixel stage'); return i < 0 ? '' : css.slice(i, css.indexOf('/* ----', i + 10)); })();
check('StillCardStill: its CSS (app.css) has no animation, transition or keyframes, and every link is 44 px to tap', stillCss.length > 100 && !/animation|transition|@keyframes/.test(stillCss) && /\.scene-stage a\{[^}]*min-height:44px/.test(stillCss));
check(`budget: the still card is at most 25 KB of markup on a busy floor (${full.length} bytes)`, full.length <= 25600);
const cardPriv = sceneHtml({ jobs: [priv, job('J12', { activity: [{ tool: 'Edit', target: 'pass-app/public/app.js' }] })] }, [], { compact: true });
check('StillCardPrivate: a private work order gives its number only; the compact card (Board tab) shows no bubble words', !/diary|secret/.test(cardPriv) && !/<i>Editing/.test(cardPriv) && /WO-0011 a private work order, open it"/.test(cardPriv));
// ---- the pixel stage (sprites.js + the canvas renderer in scene.js) ----
// a recording canvas: it checks every write lands inside it on whole pixels, and counts draws
export const errors = [];
export function mk(w, h) {
  const c = { width: w, height: h, draws: 0, rects: 0 };
  const inside = (x, y, ww, hh, what) => { if (![x, y, ww, hh].every(Number.isInteger)) errors.push(`${what} off the pixel grid ${x},${y}`); };
  c.getContext = () => ({
    imageSmoothingEnabled: true, fillStyle: '#000',
    createImageData: (ww, hh) => ({ width: ww, height: hh, data: new Uint8ClampedArray(ww * hh * 4) }),
    putImageData: (img, x, y) => { inside(x, y, img.width, img.height, 'put'); if (x < 0 || y < 0 || x + img.width > c.width || y + img.height > c.height) errors.push(`put outside ${x},${y}`); },
    drawImage: (img, ...a) => { c.draws++; if (!img || !img.getContext) errors.push('drawImage of nothing'); const [sx0, sy0, sw, sh, dx, dy] = a.length === 8 ? a : [0, 0, img.width, img.height, a[0], a[1]]; inside(dx, dy, sw, sh, 'draw'); if (sx0 < 0 || sy0 < 0 || sx0 + sw > img.width || sy0 + sh > img.height) errors.push('source outside its strip'); },
    fillRect: (x, y, ww, hh) => { c.rects++; inside(x, y, ww, hh, 'fillRect'); },
  });
  return c;
}
const names = Object.keys(P.SPRITES);
const atlas = P.buildAtlas(mk);
check(`atlas: every sprite decodes into one atlas no wider than 512 px (${names.length} sprites, ${atlas.w}x${atlas.h})`, names.every((n) => atlas.at[n]) && atlas.w <= 512 && atlas.h <= 512 && errors.length === 0);
check('atlas: every sprite is its declared size, every frame', names.every((n) => P.framesOf(n).every((f) => f.length === P.SPRITES[n].h && f.every((r) => r.length === P.SPRITES[n].w))));
const used = new Set(names.flatMap((n) => P.framesOf(n).flat().join('').split('')));
check(`atlas: every palette index used is defined (${used.size - 1} indexes)`, [...used].every((c) => c === '.' || /^#[0-9a-f]{6}$/.test(P.PALETTE[c])));
let swapOk = true;
for (const sky of Object.keys(P.SKIES)) for (const cook of Object.values(COOK_COLORS)) for (const id of ['J1', 'J2', 'J3', 'J4', 'J5', 'J6']) {
  const pal = P.paletteFor({ skin: lookOf(id).skin, cook, hair: hashId(id) % 4, sky });
  if (!Object.values(pal).every((v) => /^#[0-9a-f]{6}$/.test(v))) swapOk = false;
  try { for (const n of ['chef-side', 'chef-idle', 'waiter-idle', 'work-stove']) for (const f of P.framesOf(n)) P.toRGBA(f, pal, true); } catch { swapOk = false; }
}
check('atlas: every palette swap (6 skins x 6 cooks x 4 skies) decodes', swapOk);
const declared = { 'chef-down': 4, 'chef-up': 4, 'chef-side': 4, 'chef-idle': 2, 'chef-sleep': 2, 'waiter-side': 4, 'waiter-idle': 2, 'work-board': 4, 'work-stove': 4, 'work-taste': 4, 'work-sink': 4, 'work-plate': 4, flame: 3, steam: 4, sparkle: 4, 'oven-glow': 3, bell: 2, lantern: 2, digit: 10, icon: 6 };
check('frames: walk 4 in each direction, idle 2, work loops 4, particles as declared', Object.entries(declared).every(([n, k]) => P.framesOf(n).length === k && P.FRAMES[P.SPRITES[n].anim] === k));
check('frames: walking frames differ (the legs move) and idle frames differ (the bob)', ['chef-down', 'chef-side', 'waiter-side', 'chef-idle'].every((n) => new Set(P.framesOf(n).map((f) => f.join())).size >= 2));
const apron = (cook) => P.paletteFor({ cook })[5];
check('palette: each crew wears its own hard-hat colour', new Set(['claude', 'gemini', 'antigravity', 'local', 'sous', 'hand'].map((c) => apron(COOK_COLORS[c]))).size === 6);
// the crew (rename S7b): hard hats in the crew's colour, hi-vis vests, no chef whites left
const CREW_SLOT = /[456]/g, WHITES = /[pWon]/;
const hatRows = (n, top) => P.framesOf(n).every((f) => { const r = f.slice(0, top).join(''); return (r.match(CREW_SLOT) || []).length >= 12 && !WHITES.test(r); });
check('CrewHardHat: every crew head (walk down, up, side, idle, seated, asleep, crouch, squash) carries the crew colour in its top rows and no white toque',
  ['chef-down', 'chef-up', 'chef-side', 'chef-idle', 'chef-sit', 'chef-crouch', 'chef-squash'].every((n) => hatRows(n, 10)) && hatRows('chef-sleep', 11));
check('CrewHardHat: the hat on the hook is a hard hat in the crew colour (no white cloth)', (P.framesOf('hat')[0].join('').match(CREW_SLOT) || []).length >= 12 && !WHITES.test(P.framesOf('hat')[0].join('')));
const vest = (n) => P.framesOf(n).every((f) => { const t = f.slice(12, 18).join(''); return /[GHJ]/.test(t) && /i/.test(t) && !/[pWo]/.test(t); });
check('CrewHiVis: crew members and runners wear a hi-vis vest with a reflective stripe (no chef coat, no waiter bow tie)', ['chef-down', 'chef-up', 'chef-side', 'chef-idle', 'waiter-side', 'waiter-idle'].every(vest) && !/B/.test(P.framesOf('waiter-idle')[0].join('')));
check('CrewHiVis: the vest yellow is not a light source, so it dims at night and when the Yard is paused', ['G', 'H', 'J'].every((k) => !P.EMISSIVE.includes(k) && P.paletteFor({ dim: true })[k] !== P.PALETTE[k] && P.paletteFor({ sky: 'night' })[k] !== P.PALETTE[k]));
check('CrewHiVis: runners wear a hi-vis hard hat, not a crew colour (they carry sign-offs for every crew)', P.framesOf('waiter-idle').every((f) => /[GHJ]/.test(f.slice(0, 9).join('')) && !/[456]/.test(f.slice(0, 9).join(''))));
check('palette: night is a palette shift (darker wall), flames stay bright', P.paletteFor({ sky: 'night' }).E !== P.PALETTE.E && P.paletteFor({ sky: 'night' }).s === P.PALETTE.s);

// the stage
export const busy = { jobs: [...['plan', 'do', 'check', 'do', 'plan', 'do'].map((r, i) => job('J' + (40 + i), { role: r, cook: ['claude', 'gemini', 'local', 'antigravity'][i % 4] })),
  job('J50', { station: 'tests', role: '', cook: '' }), job('J51', { status: 'pending', step: 1 }),
  job('J52', { status: 'waiting-approval' }), job('J53', { status: 'waiting-approval' }), job('J54', { status: 'needs-human' })] };
export const kit = makeKit(P, mk);
let worst = 0, drawErr = false;
for (const hour of [6, 12, 19, 23]) {
  const st = stageNew(); st.W = 224; const Lb = layoutScene(busy, [{ type: 'job.done', job: 'J39', ts: new Date(Date.parse('2026-10-22T12:00:00Z')).toISOString() }], {}, Date.parse(`2026-10-22T${String(hour).padStart(2, '0')}:00:00`));
  stageSync(st, Lb); stageSync(st, { ...Lb, runners: [{ key: 'oJ55@x', id: 'J55' }] });
  const c = mk(st.W, STAGE.h);
  try { for (let i = 0; i < 40; i++) { stageTick(st, 50); worst = Math.max(worst, drawStage(c.getContext(), st, kit)); } } catch (e) { drawErr = e.message; }
}
check(`render: the stage draws every sky with 0 errors on the pixel grid${drawErr ? ' (' + drawErr + ')' : ''}${errors.length ? ' (' + errors[0] + ')' : ''}`, !drawErr && errors.length === 0 && worst > 20);
check(`budget: a busy floor is at most ${STAGE.maxDraws} sprite draws a frame (${worst})`, worst <= STAGE.maxDraws);
const srcBytes = fs.statSync(new URL('./public/sprites.js', import.meta.url)).size;
check(`budget: the atlas source is under 200 KB (${Math.round(srcBytes / 1024)} KB)`, srcBytes < 200 * 1024);
check('fps: no cap in the stage settings (the stage runs at the screen\'s own rate: 120 on a 120 Hz phone)', STAGE.fps === undefined && !/fps:\s*\d/.test(fs.readFileSync(new URL('./public/scene.js', import.meta.url), 'utf8')));
// the stations (rename S7c): site art, and a busy station costs exactly the draws it did as a kitchen
// leaf, water, soup glow, blush, carrot: none of it on a station any more; green (u, w) only on the Test rig, its scope trace and LEDs (S7h)
const KITCHEN_FOOD = /[wuxKCs]/, onlyRigGreen = (n) => (n === 'sink' ? /[xKCs]/ : KITCHEN_FOOD);
check('SiteStations: the station art and props carry no kitchen food or water (Survey table, Workbench, Inspection desk, Test rig, Handover bay); green only on the Test rig',
  ['counter', 'stove', 'sink', 'pallet', 'board', 'pot', 'bowl', 'plates'].every((n) => P.framesOf(n).every((f) => !onlyRigGreen(n).test(f.join('')))) && STATIONS.board.label === 'Survey table' && STATIONS.plate.label === 'Handover bay');
const stationDraws = (role, busyOn) => { const st = stageNew(); st.W = 224; stageSync(st, layoutScene({ jobs: [job('J1', { ...role, ...(busyOn ? {} : { status: 'pending', step: 4 }) })] }, [], {}, Date.parse('2026-10-22T12:00:00'))); return drawStage(mk(224, STAGE.h).getContext(), st, kit); };
const extra = Object.fromEntries([['board', { role: 'plan' }], ['stove', { role: 'do' }], ['taste', { role: 'check' }], ['sink', { station: 'tests', role: '' }], ['plate', { station: 'merge', role: '' }]].map(([k, r]) => [k, stationDraws(r, true) - stationDraws(r, false)]));
check(`SiteStations: a busy station costs what it did (work loop + effects: Workbench 6, Inspection desk 2, Test rig 4, Survey table 1, Handover bay 1; ${JSON.stringify(extra)})`,
  extra.stove === 6 && extra.taste === 2 && extra.sink === 4 && extra.board === 1 && extra.plate === 1);

// motion: chefs walk in from the door, between stations and out to the pass
const s1 = stageNew(); stageSync(s1, layoutScene({ jobs: [] }));
stageSync(s1, layoutScene({ jobs: [job('J60', { role: 'plan' })] }));
const a60 = s1.actors.get('J60');
check('walk: a new chef appears at the door and has a path to its station', a60.x === STAGE.doorX && a60.y === STAGE.doorY && a60.path.length >= 2);
for (let i = 0; i < 200; i++) stageTick(s1, 50);
check('walk: after walking it stands at its station in the aisle', a60.x === Math.round(STATIONS.board.x * 0.48) && a60.y === STAGE.aisle && !a60.path.length);
stageSync(s1, layoutScene({ jobs: [job('J60', { role: 'do' })] })); stageTick(s1, 100);
check('walk: a new step walks it sideways (side frames, facing the stove)', s1.actors.get('J60').dir === 'side' && !s1.actors.get('J60').flip && s1.actors.get('J60').path.length > 0);
stageSync(s1, layoutScene({ jobs: [] })); for (let i = 0; i < 300; i++) stageTick(s1, 50);
check('walk: a finished chef walks to the pass and leaves; the sleepy chef comes back', !s1.actors.has('J60') && s1.actors.has('idle'));
const s2 = stageNew(); stageSync(s2, layoutScene({ jobs: [job('J61')] }));
check('walk: the first paint puts everyone in place (no walk-in on opening the app)', s2.actors.get('J61').path.length === 0);

// reduced motion and the loop
const rm = stageNew(); stageSync(rm, layoutScene({ jobs: [] })); stageSync(rm, layoutScene({ jobs: [job('J62'), job('J63', { status: 'waiting-approval' })] }), { still: true });
const ca = mk(STAGE.w, STAGE.h), cb = mk(STAGE.w, STAGE.h); drawStage(ca.getContext(), rm, kit); drawStage(cb.getContext(), rm, kit);
check('reduced motion: everyone is placed at once (no paths) and two paints are the same still frame', [...rm.actors.values()].every((a) => !a.path.length) && ca.draws === cb.draws && rm.t === 0);
let asked = 0;
makeLoop({ raf: () => { asked++; return 1; }, ok: () => false, frame: () => {} }).start();
check('reduced motion or a hidden page: the loop asks for no frame at all', asked === 0);
const q = []; let drawn = 0;
const lp = makeLoop({ raf: (f) => { q.push(f); return q.length; }, ok: () => true, frame: () => { drawn++; } }).start();
for (let t = 0; t <= 1000; t += 1000 / 120) q.shift()(t);   // a 120 Hz screen for one second
check(`fps: while something moves a 120 Hz screen gets every frame, 120 a second (${drawn})`, drawn >= 120 && drawn <= 121);
let hide = false; drawn = 0; const q2 = [];
makeLoop({ raf: (f) => { q2.push(f); return 1; }, ok: () => !hide, frame: () => { drawn++; } }).start();
q2.shift()(0); q2.shift()(17); hide = true; q2.shift()(34);
check('hidden: the loop stops when the page hides and asks for nothing more', drawn === 2 && q2.length === 0);
void lp;

// crisp pixels at phone widths
const scales = [360, 390, 412, 430].flatMap((w) => [2, 2.625, 3].map((d) => ({ w, d, r: pixelScale(w - 28, d, 320) })));
check('crisp: whole-number scale at 360-430 px phones (dpr 2 to 3), the room fills the width, centred on a device pixel', scales.every(({ w, d, r }) => Number.isInteger(r.scale) && r.scale >= 2 && r.w >= STAGE.w && r.w * r.scale <= Math.floor((w - 28) * d) && Number.isInteger(r.left * d)));
check('crisp: the Pass diorama keeps its height cap', pixelScale(390, 3, 200).cssH <= 200);

// the tap layer: links, words, privacy
const hl = layoutScene({ jobs: [job('J64', { activity: [{ tool: 'Edit', target: 'app.css' }] }), job('J65', { private: true, activity: [{ tool: 'Edit', target: 'C:/secret/diary.md' }] }), job('J66', { status: 'waiting-approval' })] });
const hh = hitItems(hl).map((it) => hitHtml(it)).join('');
check('tap: every chef, waiter and ticket is a link to its order', /href="#\/job\/J64"/.test(hh) && /px-waiter[^>]*href="#\/job\/J66"/.test(hh) && /px-ticket[^>]*href="#\/job\/J65"/.test(hh));
check('private: the pixel stage shows no words, no target and no name of a private order', !/diary|secret plan/.test(hh) && /a private work order/.test(hh) && /Editing app\.css/.test(hh));

// interface chrome
const chrome = P.chromeSprites(mk);
check('chrome: tab icons (plain and lit), loading, offline, empty and both panels are drawn', P.TAB_ICONS.every((k) => chrome['tab-' + k] && chrome['tab-' + k + '-on']) && ['load', 'off', 'empty', 'panel', 'panel-dark'].every((k) => chrome[k]) && chrome.load.width === 128);
const css = fs.readFileSync(new URL('./public/app.css', import.meta.url), 'utf8'), skin = css.slice(css.indexOf('Chef pixel skin'));
const hexes = [...new Set((skin.match(/#[0-9a-fA-F]{6}\b/g) || []).map((h) => h.toLowerCase()))];
const inPal = new Set([...Object.values(P.PALETTE), ...Object.values(P.SKIES).flat()].map((h) => h.toLowerCase()));
check(`chrome: every colour of the pixel skin in app.css is a sprites.js palette colour (${hexes.length})`, hexes.length > 5 && hexes.every((h) => h === '#ffffff' || inPal.has(h)));
export const lum = (h) => { const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
export const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
check('chrome: text on the pixel cards reads at 4.5:1 or better, light and dark', ratio('#1C1B19', P.PALETTE.p) >= 4.5 && ratio('#F4F0E9', P.PALETTE.O) >= 4.5 && ratio(P.PALETTE.a, P.PALETTE.p) >= 4.5);

check('chrome: dark-mode tab icons are drawn, plain and lit', P.TAB_ICONS.every((k) => chrome['tab-' + k + '-dark'] && chrome['tab-' + k + '-on-dark']));
check('chrome: dark-mode tab icon outlines read on the dark bar (3:1 or better; the light outline there was 1.0:1)', ratio(P.TAB_DARK.a, P.PALETTE.O) >= 3 && ratio(P.TAB_DARK.a, P.TAB_DARK.p) >= 3 && ratio(P.PALETTE.a, P.PALETTE.O) < 1.5);
const tabArt = P.framesOf('icon');
check('chrome: the tab icons (rename S6b) are 12x12 site things, one per tab, each different', tabArt.length === P.TAB_ICONS.length && tabArt.every((f) => f.length === 12 && f.every((r) => r.length === 12)) && new Set(tabArt.map((f) => f.join(''))).size === tabArt.length && P.TAB_ICONS.every((k) => chrome['tab-' + k].width === 12));

