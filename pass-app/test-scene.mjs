// Tests for the animated kitchen (pass-app/public/scene.js and sprites.js, pass-app/SCENE.md). Pure layout, markup and pixel data;
// the canvas is a recording mock (no browser, no node canvas). Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it.
import fs from 'node:fs';
import { layoutScene, sceneHtml, stationFor, cookOf, lookOf, skyAt, hashId, activityWord, STATIONS, COOK_COLORS,
  STAGE, pixelScale, stageNew, stageSync, stageTick, drawStage, makeKit, makeLoop, hitItems, hitHtml,
  frameStats, stepWord, writeHits, dropStage, paintStage, stageFrame, glWanted } from './public/scene.js';
import * as GL from './public/gl.js';
import { stageOk, stageDirty, stageWait, stageMoving, CLOCK, tk, METER } from './public/frame.js';
import { meterNote, meterNew } from './public/frame-meter.js';
import { WORLD, worldOf, worldWords, worldKey, legendRows, legendHtml, PLACE, HANG, bakeWorld } from './public/world.js';
import { PURPOSE } from './public/purpose.js';
import { kitchenHits } from './site-words.mjs';
import zlib from 'node:zlib';
import * as P from './public/sprites.js';
import { MOMENTS, FX, momentsFrom, fxNew, spawn, easeOutBack, easeInOutCubic, chefPose, passFx, approveFx, tapChef, fxBusy, spread, propRects } from './public/moments.js';

const out = [];
const check = (name, pass) => out.push({ name, pass: !!pass });
const job = (id, o = {}) => ({ id, name: `improve: secret plan ${id}`, status: 'running', step: 3, steps: 11, station: 'agent', role: 'do', cook: 'claude sonnet', ...o });
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
const errors = [];
function mk(w, h) {
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
const busy = { jobs: [...['plan', 'do', 'check', 'do', 'plan', 'do'].map((r, i) => job('J' + (40 + i), { role: r, cook: ['claude', 'gemini', 'local', 'antigravity'][i % 4] })),
  job('J50', { station: 'tests', role: '', cook: '' }), job('J51', { status: 'pending', step: 1 }),
  job('J52', { status: 'waiting-approval' }), job('J53', { status: 'waiting-approval' }), job('J54', { status: 'needs-human' })] };
const kit = makeKit(P, mk);
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
const lum = (h) => { const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
check('chrome: text on the pixel cards reads at 4.5:1 or better, light and dark', ratio('#1C1B19', P.PALETTE.p) >= 4.5 && ratio('#F4F0E9', P.PALETTE.O) >= 4.5 && ratio(P.PALETTE.a, P.PALETTE.p) >= 4.5);

check('chrome: dark-mode tab icons are drawn, plain and lit', P.TAB_ICONS.every((k) => chrome['tab-' + k + '-dark'] && chrome['tab-' + k + '-on-dark']));
check('chrome: dark-mode tab icon outlines read on the dark bar (3:1 or better; the light outline there was 1.0:1)', ratio(P.TAB_DARK.a, P.PALETTE.O) >= 3 && ratio(P.TAB_DARK.a, P.TAB_DARK.p) >= 3 && ratio(P.PALETTE.a, P.PALETTE.O) < 1.5);
const tabArt = P.framesOf('icon');
check('chrome: the tab icons (rename S6b) are 12x12 site things, one per tab, each different', tabArt.length === P.TAB_ICONS.length && tabArt.every((f) => f.length === 12 && f.every((r) => r.length === 12)) && new Set(tabArt.map((f) => f.join(''))).size === tabArt.length && P.TAB_ICONS.every((k) => chrome['tab-' + k].width === 12));

// ---- the world (plans/chef-art-2.md wave 1: the world tells the truth) ----
const T0 = Date.parse('2026-10-22T15:07:00'), iso = (ms) => new Date(ms).toISOString(), ago = (min) => iso(T0 - min * 60000);
const fullJobs = () => [job('J70'), job('J71', { status: 'waiting-approval', approval: { id: 'A7' } }), job('J72', { status: 'needs-human', approval: { id: 'A8' } }),
  job('J73', { status: 'quarantined', name: 'improve: secret plan J73', private: true }), job('J74', { status: 'failed' }), ...Array.from({ length: 10 }, (_, i) => job('J' + (80 + i), { status: 'pending', step: 1 }))];
const fullState = () => ({ jobs: fullJobs(), paused: false, live: true, stalled: false, lastTick: ago(0.5), breaker: false, spent: 7.5, budget: 20, due: 2, leads: 3, ideas: 5,
  cooks: { claude: { status: 'ready' }, gemini: { status: 'resting' }, local: { status: 'off' }, antigravity: { status: 'busy' } } });
const fullEvents = () => [{ type: 'approval.requested', job: 'J71', approval: 'A7', ts: ago(70) }, { type: 'approval.requested', job: 'J72', approval: 'A8', ts: ago(250) },
  { type: 'job.quarantined', job: 'J73', ts: ago(1) }, { type: 'budget.stop', job: '', ts: ago(30) }];
const Wf = worldOf(fullState(), fullEvents(), T0);
check(`world: a full state draws every WORLD row (${WORLD.length} rows: ${WORLD.map((r) => r.prop).join(', ')})`, WORLD.every((r) => Wf[r.prop] !== undefined) && Object.keys(Wf).every((k) => WORLD.some((r) => r.prop === k)));
check('world: every WORLD row says its field, its meaning and when it is absent', WORLD.every((r) => r.prop && r.from && r.meaning && r.absent));
// truth: take each row's field away in turn and that prop is gone (never a default value)
const strip = (o, k) => { const c = { ...o }; delete c[k]; return c; };
const TAKE = { sign: [(s) => strip(s, 'paused'), (s) => strip(s, 'live')], clock: [(s) => strip(s, 'lastTick'), (s) => strip(s, 'stalled'), (s) => ({ ...s, lastTick: 'not a date' })],
  sous: [(s) => strip(s, 'lastTick'), (s) => strip(s, 'stalled')], fuse: [(s) => strip(s, 'breaker'), (s) => ({ ...s, breaker: 'yes' })],
  jar: [(s) => strip(s, 'spent'), (s) => strip(s, 'budget'), (s) => ({ ...s, budget: 0 }), (s) => ({ ...s, spent: null })], aside: [(s) => strip(s, 'jobs')], spike: [(s) => strip(s, 'jobs'), (s) => ({ ...s, jobs: s.jobs.slice(0, 8) })],
  heat: [(s) => strip(s, 'jobs')], letters: [(s) => strip(s, 'due')], specials: [(s) => strip(s, 'leads')], recipes: [(s) => strip(s, 'ideas')], hats: [(s) => strip(s, 'cooks'), (s) => ({ ...s, cooks: [] })] };
check('truth: every WORLD row has a missing-field case in this test', WORLD.every((r) => TAKE[r.prop]?.length));
const leaks = [];
for (const r of WORLD) for (const [i, take] of TAKE[r.prop].entries()) if (worldOf(take(fullState()), fullEvents(), T0)[r.prop] !== undefined) leaks.push(`${r.prop}#${i}`);
check(`truth: a missing field draws no prop, for every row of WORLD${leaks.length ? ' (drawn anyway: ' + leaks.join(', ') + ')' : ''}`, leaks.length === 0);
check('truth: the heat lamp needs the approval.requested event of that very ask (no event, or another ask id: no lamp)', !worldOf(fullState(), [], T0).heat
  && !worldOf(fullState(), [{ type: 'approval.requested', job: 'J71', approval: 'A1', ts: ago(5) }], T0).heat && worldOf(fullState(), [{ type: 'approval.requested', job: 'J71', approval: 'A7', ts: ago(5) }], T0).heat.length === 1);
check('truth: an empty state, null and garbage give an empty world', [worldOf({}), worldOf(null), worldOf('x'), worldOf({ jobs: 'x', cooks: 5, spent: '3', budget: '20' })].every((w) => Object.keys(w).length === 0));
// the coin jar: floor(8 * spent / budget), clamped to 0..8; the padlock only for a budget.stop today
const JAR = [[0, 20, 0], [2.49, 20, 0], [2.5, 20, 1], [10, 20, 4], [17.5, 20, 7], [19.99, 20, 7], [20, 20, 8], [35, 20, 8], [-1, 20, 0], [0.01, 0.08, 1]];
check(`jar: level = floor(8 x spent / budget), clamped (${JAR.length} cases)`, JAR.every(([spent, budget, lv]) => worldOf({ spent, budget }, [], T0).jar.level === lv));
check('jar: padlock iff a budget.stop today (yesterday, another event or none: no lid)', worldOf({ spent: 20, budget: 20 }, [{ type: 'budget.stop', ts: ago(1) }], T0).jar.locked === true
  && worldOf({ spent: 20, budget: 20 }, [{ type: 'budget.stop', ts: iso(T0 - 26 * 3600000) }], T0).jar.locked === false && worldOf({ spent: 20, budget: 20 }, [{ type: 'job.done', ts: ago(1) }], T0).jar.locked === false && worldOf({ spent: 20, budget: 20 }, [], T0).jar.locked === false);
// door sign, clock
check('sign: PAUSED iff paused (stored state: closed); OPEN lit iff live; OPEN unlit when running with AI crews off', worldOf({ paused: true, live: true }).sign.state === 'closed' && worldOf({ paused: true }).sign.state === 'closed'
  && worldOf({ paused: false, live: true }).sign.state === 'lit' && worldOf({ paused: false, live: false }).sign.state === 'open');
const tickAt = T0 - 14 * 60000, cl = (stalled) => worldOf({ lastTick: iso(tickAt), stalled }, [], T0).clock, at5 = (ms) => Math.floor(new Date(ms).getMinutes() / 5);
check('clock: frozen iff stalled: stalled shows the last tick time, running shows now', cl(true).frozen && cl(true).at === tickAt && cl(true).min === at5(tickAt) && !cl(false).frozen && cl(false).at === T0 && cl(false).min === at5(T0) && cl(false).hour === new Date(T0).getHours() % 12);
// a recording kit: which world sprite (and frame) each draw used
const rec = []; const rkit = makeKit(P, (w, h) => { const c = mk(w, h), g = c.getContext; c.getContext = () => { const x = g(); const di = x.drawImage; x.drawImage = (img, ...a) => { if (img?._name) rec.push(img._name + ':' + (a.length === 8 ? a[0] / a[2] : 0)); return di(img, ...a); }; return x; }; return c; });
const rget = rkit.get; rkit.get = (name, o, f) => { const v = rget.call(rkit, name, o, f); v.img._name = name; return v; };
const drawnW = (s, ev = [], opts = {}) => { rec.length = 0; rkit.layers.clear(); const st = stageNew(); stageSync(st, layoutScene(s, ev, {}, T0), opts); drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), st, rkit); return [...rec]; };
const WORLD_SPRITES = ['sign', 'clock', 'clock-min', 'clock-hour', 'coin-jar', 'jar-lock', 'stool', 'chair-up', 'chef-sit', 'fuse', 'lamp-off', 'heat', 'cork', 'letter', 'hooks', 'hat', 'chalk', 'tally', 'chalk-digit', 'recipes', 'aside-shelf', 'plate-aside', 'smoke', 'tag', 'plus'];
const bare = drawnW({ jobs: [job('J1')] });
check('truth: with only jobs the stage draws no world sprite but the (empty) set-aside shelf', bare.length > 5 && bare.includes('aside-shelf:0') && !bare.some((r) => r !== 'aside-shelf:0' && WORLD_SPRITES.includes(r.split(':')[0])));
const dFull = drawnW(fullState(), fullEvents());
check('draw: the full world draws its props (sign, clock, jar + lock, shelf plates, tag, heat lamps, board, hats, chalkboard, recipes, fuse, stool)',
  ['sign:1', 'clock:0', 'coin-jar:3', 'jar-lock:0', 'plate-aside:0', 'tag:0', 'heat:1', 'heat:2', 'cork:0', 'letter:0', 'hat:0', 'chalk:0', 'tally:3', 'recipes:4', 'fuse:0', 'stool:0'].every((k) => dFull.includes(k)));
check('draw: gate sign frames follow the state (PAUSED 2, OPEN 0) and PAUSED puts the barriers up', drawnW({ jobs: [], paused: true }).includes('sign:2') && drawnW({ jobs: [], paused: true }).includes('chair-up:0') && drawnW({ jobs: [], paused: false, live: false }).includes('sign:0') && !drawnW({ jobs: [], paused: false, live: false }).includes('chair-up:0'));
check('draw: the clock hands show the frozen tick when stalled', drawnW({ jobs: [], lastTick: iso(tickAt), stalled: true }).includes(`clock-min:${at5(tickAt)}`) && drawnW({ jobs: [], lastTick: iso(tickAt), stalled: false }).includes(`clock-min:${at5(T0)}`));
check('draw: a stop-work order sparks the power board (frame 1) and puts the work light out', drawnW({ jobs: [], breaker: true }).includes('fuse:1') && drawnW({ jobs: [], breaker: true }).includes('lamp-off:0') && drawnW({ jobs: [], breaker: false }).includes('lamp:0'));
check('draw: the paused site is dimmed (a palette shift, light sources keep their colour)', P.paletteFor({ dim: true }).E !== P.PALETTE.E && P.paletteFor({ dim: true }).t === P.PALETTE.t && P.paletteFor({ dim: true, sky: 'night' }).E !== P.paletteFor({ sky: 'night' }).E);
// set aside, the rail tag, heat lamps
const sh = (n, extra = []) => worldOf({ jobs: [...Array.from({ length: n }, (_, i) => job('J' + (100 + i), { status: ['quarantined', 'killed', 'failed'][i % 3] })), ...extra] }, [{ type: 'job.quarantined', job: 'J100', ts: ago(1) }, { type: 'job.quarantined', job: 'J101', ts: ago(3) }], T0).aside;
check('aside: one plate per set-aside order, 5 on the shelf then +N; smoke only for one set aside under 2 min ago', sh(3).shelf.length === 3 && sh(3).more === 0 && sh(7).shelf.length === 5 && sh(7).more === 2 && sh(0).ids.length === 0
  && sh(3).smoke.length === 1 && sh(3).smoke[0].id === 'J100' && sh(3, [job('J1')]).ids.length === 3);
check('spike: +N only beyond the 8 tickets the rail shows', worldOf({ jobs: Array.from({ length: 11 }, (_, i) => job('J' + i, { status: 'pending' })) }).spike.n === 3 && !worldOf({ jobs: Array.from({ length: 8 }, (_, i) => job('J' + i)) }).spike);
const hw = (min) => worldOf({ jobs: [job('J71', { status: 'waiting-approval', approval: { id: 'A7' } })] }, [{ type: 'approval.requested', job: 'J71', approval: 'A7', ts: ago(min) }], T0).heat[0].level;
check('heat: the sign-off light is warm under 1 h, amber from 1 h, red from 4 h of real waiting', hw(5) === 0 && hw(59) === 0 && hw(60) === 1 && hw(239) === 1 && hw(240) === 2 && hw(600) === 2);
check('hats: one hat per cook resting, at its cap, off or signed out (ready and busy cooks are on the line)', Wf.hats.map((h) => h.name).join() === 'gemini,local' && Wf.hats[0].color === COOK_COLORS.gemini);
check('counts: letters, specials and recipes carry the real counts (0 is an empty board, not a missing one)', Wf.letters.n === 2 && Wf.specials.n === 3 && Wf.recipes.n === 5 && worldOf({ due: 0 }).letters.n === 0);
// the sous chef walks one round per real tick, never more
const sousSt = stageNew(), tickState = (t) => layoutScene({ jobs: [], lastTick: iso(t), stalled: false }, [], {}, T0);
stageSync(sousSt, tickState(T0 - 30000)); for (let i = 0; i < 400; i++) stageTick(sousSt, 50);
stageSync(sousSt, tickState(T0 - 30000)); for (let i = 0; i < 400; i++) stageTick(sousSt, 50);
stageSync(sousSt, tickState(T0 - 5000)); for (let i = 0; i < 400; i++) stageTick(sousSt, 50);
check(`sous: 3 states with 2 real ticks walk 2 rounds (${sousSt.rounds}), and he is back on his stool`, sousSt.rounds === 2 && sousSt.ticks.size === 2 && sousSt.actors.get('sous').x === PLACE.sous && !sousSt.actors.get('sous').path.length);
const oldSt = stageNew(); stageSync(oldSt, tickState(T0 - 10 * 60000));
check('sous: a tick seen on opening the app walks only if under 2 minutes old (old news is not replayed)', oldSt.rounds === 0 && oldSt.actors.get('sous').path.length === 0);
const burst = stageNew(); stageSync(burst, tickState(T0 - 9 * 60000)); for (const k of [1, 2, 3, 4]) stageSync(burst, tickState(T0 - 9 * 60000 + k * 1000)); for (let i = 0; i < 1200; i++) stageTick(burst, 50);
check(`sous: ticks arriving mid-round never add more rounds than ticks (${burst.rounds} rounds for 4 new ticks)`, burst.rounds >= 1 && burst.rounds <= 4);
const stillSous = stageNew(); stageSync(stillSous, tickState(T0 - 9 * 60000)); stageSync(stillSous, tickState(T0 - 1000), { still: true });
check('sous: reduced motion: no round, he stays seated', stillSous.rounds === 0 && !stillSous.actors.get('sous').path.length);
const stl = drawnW({ jobs: [], lastTick: iso(tickAt), stalled: true });
check('sous: stalled = an empty stool (the stool is drawn, the Dispatcher is not)', stl.includes('stool:0') && !stl.some((r) => r.startsWith('chef-sit')) && !worldOf({ lastTick: iso(tickAt), stalled: true }).sous.here);
check('sous: the Dispatcher sits on the stool while the walkrounds run', drawnW({ jobs: [], lastTick: iso(T0 - 9 * 60000), stalled: false }).some((r) => r.startsWith('chef-sit')));
// the world props as a site (rename S7e)
const signRows = P.framesOf('sign')[2], spelled = (word, x0, y0) => [...word].every((ch, i) => P.GLYPHS[ch].every((r, gy) => [...r].every((px, gx) => (px === 'a') === (signRows[y0 + gy][x0 + i * 4 + gx] === 'a'))));
check('GateSign: paused, the gate sign spells PAUSED, never CLOSED ("Site closed" is the merge freeze), and the legend says the same',
  spelled('PAUSED', 1, 5) && !spelled('CLOSED', 1, 5) && P.SIGN_WORDS.join() === 'OPEN,OPEN,PAUSED' && WORLD[0].meaning({ state: 'closed' }) === 'Gate sign PAUSED: you paused the Yard.'
  && WORLD.every((r) => ['closed', 'lit', 'open'].every((state) => !/CLOSED/.test(String(r.prop === 'sign' ? r.meaning({ state }) : '')))));
const seen = [], g0 = rkit.get; rkit.get = (n, o, f) => { if (/^chef-(sit|side)$/.test(n)) seen.push(n + '|' + o?.cook); return g0.call(rkit, n, o, f); };
drawnW({ jobs: [], lastTick: iso(T0 - 9 * 60000), stalled: false });
const lap = stageNew(); stageSync(lap, tickState(T0 - 5000)); for (let i = 0; i < 10; i++) stageTick(lap, 50); rec.length = 0; drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), lap, rkit); const lapDraws = [...rec];
rkit.get = g0;
const knee = P.framesOf('chef-sit').every((f) => /p/.test(f.slice(14, 19).map((r) => r.slice(10, 14)).join('')));
check('Dispatcher: a white hard hat (seated and on the lap) and a clipboard (on the knee, in hand while walking), its legend icon too',
  seen.includes('chef-sit|' + P.DISPATCHER) && seen.includes('chef-side|' + P.DISPATCHER) && !seen.some((s) => !s.endsWith('|' + P.DISPATCHER)) && lapDraws.includes('cloche:0') && knee && P.LEGEND_ICONS.sous[2] === P.DISPATCHER);
const siteRows = legendRows(layoutScene(fullState(), fullEvents(), {}, T0));
check('SiteProps: the legend speaks site words (gate sign, site clock, power board, budget meter, the bench, job board, sign-off lights, notice board, whiteboard, idea box, hard hats) and no kitchen words',
  ['Gate sign', 'Site clock', 'Dispatcher', 'Power board', 'Budget meter', 'The bench', 'Sign-off lights', 'Notice board', 'Whiteboard', 'Idea box', 'Hard hats on hooks'].every((w) => siteRows.some((r) => r.text.startsWith(w)))
  && !/kitchen|chef|cook|coin|jar|plate|rail|heat lamp|ember|cork|chalk|recipe|fuse|hatch|window sign/i.test(siteRows.map((r) => r.text).join(' ')) && WORLD.find((r) => r.prop === 'spike').meaning({ n: 3 }) === 'Job board tag: 3 more queued.');
check('SiteProps: the budget meter fills green, then amber, then red, one segment per level; a chain and padlock when the cap stopped work', P.framesOf('coin-jar')[8].join('').includes('B') && P.framesOf('coin-jar')[4].join('').includes('v') && !/[sB]/.test(P.framesOf('coin-jar')[4].join('')) && /h/.test(P.framesOf('jar-lock')[0][1]));
// the legend sheet, the words and privacy
const Lf =layoutScene(fullState(), fullEvents(), {}, T0), rows = legendRows(Lf);
check(`legend: one row per prop in the room (${rows.length} rows), each a plain sentence`, Object.keys(Lf.world).every((k) => rows.some((r) => r.key === k)) && rows.every((r) => /^[A-Z].*\.$/.test(r.text)) && rows.every((r) => P.LEGEND_ICONS[r.key]));
const txt = (k) => rows.find((r) => r.key === k).text;
check('legend: numbers in words ($7.50 of $20, 3 of 8, waiting 1 h 10 min, 2 follow-ups, 2 set aside)', txt('jar').includes("$7.50 of today's $20 cap") && txt('jar').includes('3 of 8.')
  && txt('heat').includes('WO-0071 1 h 10 min (amber') && txt('heat').includes('WO-0072 4 h 10 min (red') && txt('letters').includes('2 job-hunt follow-ups due') && txt('aside').includes('The bench: 2 work orders failed or stopped (WO-0073, WO-0074)'));
const lh = legendHtml(rows), hp = hitItems(Lf).map((it) => hitHtml(it)).join('');
check('private: legend, hit labels and aria words carry no order words (numbers and ticket numbers only)', !/secret|improve/.test(lh + hp + Lf.summary) && /WO-0073/.test(lh) && !/<script/.test(legendHtml([{ key: 'x"><script>', text: '<script>' }])));
check('legend: no state yet is an empty line, never a blank sheet', /has not sent its state/.test(legendHtml(legendRows(null))));
check('aria: the stage label says the world in words', /the Yard open, AI crews on, \$7\.50 of \$20 spent, daily cap reached, 2 failed or stopped/.test(Lf.summary) && worldWords({}) === '');
check('tap: the set-aside shelf is one link to the newest set-aside order', /px-aside[^>]*href="#\/job\/J74"[^>]*aria-label="2 work orders failed or stopped; the newest is WO-0074/.test(hp));
// cached bakes: still props re-bake only when a level changes
const bk = makeKit(P, mk), bst = stageNew(); stageSync(bst, layoutScene(fullState(), fullEvents(), {}, T0));
for (let i = 0; i < 60; i++) { stageTick(bst, 16); drawStage(mk(STAGE.w, STAGE.h).getContext(), bst, bk); }
const bakes1 = bk.bakes; stageSync(bst, layoutScene({ ...fullState(), spent: 12 }, fullEvents(), {}, T0)); drawStage(mk(STAGE.w, STAGE.h).getContext(), bst, bk);
check(`bake: 60 frames of the same world bake the layers once (${bakes1}), a new coin level bakes the back layer once more`, bakes1 === 2 && bk.bakes === 3 && worldKey(Wf) !== worldKey({ ...Wf, jar: { ...Wf.jar, level: 4 } }));
// budget: the busiest world still draws at most 120 sprites a frame
const busyWorld = { ...busy, ...strip(fullState(), 'jobs'), breaker: true, jobs: [...busy.jobs, ...fullJobs().slice(3)] };
let worstW = 0; const bw = stageNew(); bw.W = 256; stageSync(bw, layoutScene(busyWorld, fullEvents(), {}, T0)); stageSync(bw, layoutScene({ ...busyWorld, lastTick: iso(T0 - 1000) }, fullEvents(), {}, T0));
for (let i = 0; i < 80; i++) { stageTick(bw, 50); worstW = Math.max(worstW, drawStage(mk(256, STAGE.h).getContext(), bw, kit)); }
check(`budget: the busiest floor with every world prop is at most ${STAGE.maxDraws} draws a frame (${worstW}), 0 off-grid writes`, worstW <= STAGE.maxDraws && worstW > 40 && errors.length === 0);
// ---- the frame loop (art critique S7 12c.1, frame.js): one draw a frame and only for a new picture, no callback while nothing moves ----
check('fps: frame stats give p50 and p95 of the timed frames (none timed: null)', frameStats([]) === null && frameStats([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]).p95 === 10 && frameStats([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]).p50 === 6);
// W4 (chef.md: 5,816 ms of frame CPU per 30 s, and still drawing while scrolled away): seen-only
const scOn = { root: { isConnected: true, offsetParent: {} }, visible: true }, scOff = { ...scOn, visible: false }, docShown = { hidden: false };
let offDraws = 0, offAsked = 0;
makeLoop({ raf: () => { offAsked++; return 1; }, ok: () => stageOk(scOff, docShown), frame: () => { offDraws++; } }).start();
check('SceneOffscreen_NoDraw: a stage scrolled out of view asks for no frame and draws nothing; on screen, shown and in the page it may draw',
  offDraws === 0 && offAsked === 0 && stageOk(scOn, docShown) && !stageOk(scOn, { hidden: true }) && !stageOk(scOn, docShown, true) && !stageOk({ ...scOn, root: { isConnected: false, offsetParent: {} } }, docShown) && stageOk({ root: scOn.root }, docShown));
// a fake screen: vsync every 1000/hz ms, timers on the same clock (a timer that falls due lines up with the next vsync, as in a browser)
function screen(hz = 120) {
  const S = { now: 0, q: [], timers: new Map(), id: 0, rafs: 0, sets: 0 };
  S.raf = (f) => { S.q.push(f); S.rafs++; return ++S.id; };
  S.timer = (f, ms) => { S.timers.set(++S.id, { at: S.now + ms, f }); S.sets++; return S.id; };
  S.untimer = (id) => S.timers.delete(id);
  S.run = (ms) => {
    for (const end = S.now + ms; S.now < end - 1e-9;) {
      S.now += 1000 / hz;
      for (const [id, x] of [...S.timers]) if (x.at <= S.now) { S.timers.delete(id); x.f(); }
      const q = S.q; S.q = []; for (const f of q) f(S.now);
    }
  };
  return S;
}
// the oracle: the old frame key (every draw call drawStage would make, recorded), used only here to prove no picture is missed
const imgIds = new WeakMap(); let imgN = 0;
const imgId = (img) => { if (!imgIds.has(img)) imgIds.set(img, ++imgN); return imgIds.get(img); };
const oracle = (st, k) => { const parts = []; drawStage({ set fillStyle(v) { parts.push('f' + v); }, get fillStyle() { return ''; }, drawImage: (img, ...a) => { parts.push(imgId(img) + ':' + a.join()); }, fillRect: (...a) => { parts.push('r' + a.join()); } }, st, k); return parts.join('|'); };
// a canvas that counts drawStage passes (each pass draws the two cached layers whole: drawImage with 2 numbers)
const passCtx = () => { const x = mk(224, STAGE.h).getContext(), di = x.drawImage; let layers = 0; x.drawImage = (img, ...a) => { if (a.length === 2) layers++; return di(img, ...a); }; return { x, passes: () => layers / 2 }; };
{
  // a scripted 20 s on a 120 Hz screen: the sleeper alone, crews walk in, a busy Workbench, a step.done moment, a tapped crew member's wave,
  // then every work order between steps (nothing moves: the loop must stop)
  const scr = screen(120), pc = passCtx(), st = stageNew(); st.W = 224;
  const L0 = (jobs, ev = [], ms = 0) => layoutScene({ jobs }, ev, {}, T0 + ms);
  stageSync(st, L0([])); paintStage(pc.x, st, kit);
  let frames = 0, drawn = 0, missed = 0, twice = 0, same = 0, last = oracle(st, kit), ok = true;
  const loop = makeLoop({ raf: scr.raf, timer: scr.timer, untimer: scr.untimer, ok: () => ok, frame: (dt) => {
    const p0 = pc.passes(), w = stageFrame(st, pc.x, kit, dt), n = pc.passes() - p0, k = oracle(st, kit);
    frames++; if (n > 1) twice++; if (n) drawn++;
    if (k !== last && !st.drew) missed++; else if (st.drew && k === last) same++;
    if (st.drew) last = k;
    return w;
  } }).start();
  const phase = (ms) => { const r0 = scr.rafs, f0 = frames, d0 = drawn, s0 = scr.sets; scr.run(ms); return { rafs: scr.rafs - r0, frames: frames - f0, drawn: drawn - d0, timers: scr.sets - s0 }; };
  const sleeper = phase(3000);
  const jobs = [job('J70', { role: 'do' }), job('J71', { role: 'plan', cook: 'gemini' })];
  stageSync(st, L0(jobs, [], 3000)); loop.start();
  const walk = phase(1000); phase(4000);
  stageSync(st, L0(jobs, [{ type: 'step.done', job: 'J70', step: 3, ts: iso(T0 + 7900) }], 8000)); loop.start();
  phase(2000);
  tapChef(st, 'J70'); loop.start(); phase(4000);
  stageSync(st, L0(jobs.map((j) => ({ ...j, status: 'pending', step: 4 })), [], 14000)); loop.start();
  phase(1000); const idle = phase(3000), idleWait = stageWait(st);
  ok = false; stageSync(st, L0([...jobs, job('J72', { role: 'check' })], [], 18000)); loop.start(); const hidden = phase(1000);
  ok = true; loop.start(); const back = phase(500);
  check(`SingleDraw: every frame runs drawStage at most once (${twice} frames twice) and never just to compare; ${drawn} draws in ${frames} frames`, twice === 0 && drawn > 0 && drawn < frames);
  check(`NoMissedPicture: over 20 s (walks, a busy Workbench, a moment, a wave) every frame whose picture changed was drawn (${missed} missed; ${same} drawn unchanged, tweens)`, missed === 0 && frames > 500);
  check(`120 Hz: while crews walk the loop takes every frame of a 120 Hz screen (${walk.frames} frames in 1 s) and draws only new pictures (${walk.drawn})`, walk.frames >= 118 && walk.drawn < walk.frames);
  check(`IdleSleep: with only the sleeper's 900 ms snore the loop sleeps on a timer between steps (${sleeper.rafs} frames asked, ${sleeper.drawn} draws in 3 s)`, sleeper.rafs <= 8 && sleeper.drawn >= 3 && sleeper.drawn <= 5 && sleeper.timers >= 3);
  check(`IdleStop: nothing moves (every crew between steps): no frame, no timer, no draw for 3 s (${idle.rafs} frames, ${idle.timers} timers)`, idle.rafs === 0 && idle.timers === 0 && idle.drawn === 0 && idleWait === Infinity);
  check(`IdleStop: hidden, it stays stopped even when the state changes (${hidden.rafs} frames); shown again it restarts and walks (${back.frames} frames)`, hidden.rafs <= 1 && hidden.drawn === 0 && back.frames >= 55);
}
{
  // calm is still (critique P3): a crew between steps, runners at the window and the seated Dispatcher hold one frame, nothing is due
  const st = stageNew(); stageSync(st, layoutScene({ jobs: [job('J80', { status: 'pending', step: 4 }), job('J81', { status: 'waiting-approval' })], lastTick: iso(T0 - 9 * 60000), stalled: false }, [], {}, T0));
  const pics = [0, 450, 900, 1350, 4100].map((t) => { st.t = t; return oracle(st, kit); });
  paintStage(mk(STAGE.w, STAGE.h).getContext(), st, kit);
  check('CalmStill: a calm floor draws the same picture at any time and schedules nothing (no idle breathing, no looping bell): the loop stops', new Set(pics).size === 1 && st.next === Infinity && !stageMoving(st) && stageWait(st) === Infinity);
  const bz = stageNew(); stageSync(bz, layoutScene({ jobs: [job('J82')] }, [], {}, T0)); paintStage(mk(STAGE.w, STAGE.h).getContext(), bz, kit);
  check(`CalmStill: a busy station still animates (its work loop is data): the next step is due in ${stageWait(bz)} ms, then a new picture`, stageWait(bz) > 0 && stageWait(bz) <= 120 && (bz.t = bz.next, stageDirty(bz)));
}
// the frame clock: a step's index and when it changes
CLOCK.next = Infinity; const k3 = tk(90, 200);
check('clock: tk gives the step and notes the next step\'s time (90 ms steps at 200 ms: step 2, the next at 270 ms)', k3 === 2 && CLOCK.next === 270);
const dk = makeKit(P, mk);
check('kit: a paused (dim) palette is cached apart from the lit one (the dim floor never reuses lit crew strips)', dk.get('chef-idle', { sky: 'day' }) !== dk.get('chef-idle', { sky: 'day', dim: true }) && dk.get('chef-idle', { sky: 'day' }) === dk.get('chef-idle', { sky: 'day' }));
// the frame meter: off by default; ?hud or Settings > About > Frame meter; fps, the screen's rate and the p95 of frame work, from ring buffers
{
  const lines = [], M = meterNew((s) => lines.push(s));
  for (let i = 1; i <= 130; i++) meterNote(i * 1000 / 120, i === 50 || i === 90 ? 12 : 1, i % 4 === 0, 0, M);
  const run = lines[lines.length - 1]; meterNote(131 * 1000 / 120, 1, true, Infinity, M); const stop = lines[lines.length - 1];
  check(`FrameMeter: 120 fps on a 120 Hz screen, its rate, the work p95 and frames over 8.3 ms (${JSON.stringify(run)})`, /^120 fps\n/.test(run) && /screen 120 Hz/.test(run) && /p95 1 /.test(run) && /max 12 ms/.test(run) && /2 frames over 8\.3 ms/.test(run) && /30 draws\/s/.test(run));
  check('FrameMeter: says idle when the loop stops', /^idle: nothing moves/.test(stop));
  const scSrc = fs.readFileSync(new URL('./public/scene.js', import.meta.url), 'utf8'), apSrc = fs.readFileSync(new URL('./public/app.js', import.meta.url), 'utf8');
  check('FrameMeter: off by default and not loaded with the stage (frame-meter.js comes only with ?hud, ?fps or the Settings switch, kept on this phone)',
    METER.on === false && /\[\?&\]\(hud\|fps=hud\)/.test(scSrc) && /'board\.frameMeter'/.test(scSrc) && /import\('\.\/frame-meter\.js'\)/.test(scSrc) && !/from '\.\/frame-meter\.js'/.test(scSrc) && /id="meter-switch"/.test(apSrc) && /sceneMeter\(e\.target\.checked\)/.test(apSrc));
}
// reduced motion: the world is a still frame too (no walk, two paints alike)
const rw = stageNew(); stageSync(rw, layoutScene(fullState(), fullEvents(), {}, T0), { still: true });
const r1c = mk(STAGE.w, STAGE.h), r2c = mk(STAGE.w, STAGE.h); drawStage(r1c.getContext(), rw, kit); drawStage(r2c.getContext(), rw, kit);
check('reduced motion: the world draws one still frame (no paths, the same draws twice)', [...rw.actors.values()].every((a) => !a.path.length) && r1c.draws === r2c.draws && rw.rounds === 0);
// sprites for the world: declared frames
const wdecl = { sign: 3, 'clock-min': 12, 'clock-hour': 12, 'coin-jar': 9, heat: 3, fuse: 2, tally: 11, recipes: 5, 'chef-sit': 2, smoke: 4, 'chalk-digit': 10 };
check('frames: world sprites have their declared frames (sign 3, hands 12, jar 9, heat 3, fuse 2, tally 11, cards 5)', Object.entries(wdecl).every(([n, k]) => P.framesOf(n).length === k && P.FRAMES[P.SPRITES[n].anim] === k));
check('frames: the coin jar fills one row per level and the hands point 12 ways', new Set(P.framesOf('coin-jar').map((f) => f.join())).size === 9 && new Set(P.framesOf('clock-min').map((f) => f.join())).size === 12);
// ---- wave 2: moments and juice (plans/chef-art-2.md; public/moments.js) ----
const Tm = T0, isoM = (ms) => new Date(ms).toISOString();
const evOf = (type, job, secAgo, o = {}) => ({ type, job, ts: isoM(Tm - secAgo * 1000), ...o });
const lay = (jobs, ev, now = Tm, compact = false) => layoutScene({ jobs }, ev, { compact }, now);
// an opened stage (its first state seen), then a state with new events: what plays
const opened = (jobs = [job('J1')]) => { const s = stageNew(); stageSync(s, lay(jobs, [])); return s; };
const seen1 = new Set(), ev1 = [evOf('job.done', 'J1', 10), evOf('step.done', 'J2', 5, { step: 2 })];
const m1 = momentsFrom(ev1, seen1, Tm), m2 = momentsFrom(ev1, seen1, Tm);
const reload = stageNew(); stageSync(reload, lay([job('J1')], ev1)); stageTick(reload, 16);
const mSrc = fs.readFileSync(new URL('./public/moments.js', import.meta.url), 'utf8');
check('MomentOnce: the same events twice give one moment each; a reload (a new stage) plays none of what it opened on; seen is memory only',
  m1.length === 2 && m2.length === 0 && reload.fx.live.length === 0 && reload.fx.queue.length === 0 && reload.fx.seen.size === 2 && !/localStorage|sessionStorage|indexedDB/.test(mSrc));
const fr = (sec) => momentsFrom([evOf('job.done', 'J1', sec)], new Set(), Tm).length;
check('MomentFresh: an event over 2 min old never plays (119 s plays, 121 s does not, a future one does not)', fr(119) === 1 && fr(121) === 0 && fr(-60) === 0);
const cap = opened(); stageSync(cap, lay([job('J1')], [1, 2, 3, 4, 5].map((i) => evOf('job.done', 'J' + (80 + i), 100 - i))));
stageTick(cap, 16); const live1 = cap.fx.live.length, q1 = cap.fx.queue.length; let maxLive = 0;
for (let i = 0; i < 30000 / 50; i++) { stageTick(cap, 50); maxLive = Math.max(maxLive, cap.fx.live.length); }
check(`MomentCap: at most 2 moments at once, the rest queue (${live1} live, ${q1} queued); the queue drains in order`,
  live1 === 2 && q1 === 3 && maxLive <= 2 && cap.fx.queue.length === 0 && cap.fx.said > -Infinity);
const hid = opened(); stageSync(hid, lay([job('J1')], [evOf('job.done', 'J90', 10)], Tm)); stageSync(hid, lay([job('J1')], [evOf('job.done', 'J90', 10)], Tm + 180000)); stageTick(hid, 16);
check('MomentHidden: a moment that waited while the tab was hidden (no frames for 3 min) is stale when frames start again: it does not play', hid.fx.live.length === 0 && hid.fx.queue.length === 0);
// every moment comes from a real event: an Emit '<type>' in kitchen.ps1, or one of its step failure kinds (Fail-Step's step.<kind>)
const kps = fs.readFileSync(new URL('../kitchen/kitchen.ps1', import.meta.url), 'utf8'), failKinds = (/\^step\\\.\(([a-z|]+)\)\$/.exec(kps) || [, ''])[1].split('|');
check(`MomentReal: every moment maps to an event type the kitchen writes (${Object.keys(MOMENTS).length} types)`, Object.keys(MOMENTS).every((k) => kps.includes(`Emit '${k}'`) || (k.startsWith('step.') && failKinds.includes(k.slice(5)))) && failKinds.length >= 5 && kps.includes('Emit "step.$kind"'));
const plans = new Map([['J2', [{ station: 'agent' }, { station: 'worktree' }, { station: 'tests' }]]]);
check('MomentTests: a step.done is the sink sparkle only when the plan says that step was tests (ALL PASS); otherwise the pan flip',
  momentsFrom([evOf('step.done', 'J2', 5, { step: 2 })], new Set(), Tm, plans)[0].kind === 'sparkle' && momentsFrom([evOf('step.done', 'J2', 5, { step: 1 })], new Set(), Tm, plans)[0].kind === 'flip'
  && momentsFrom([evOf('step.done', 'J3', 5, { step: 2 })], new Set(), Tm, plans)[0].kind === 'flip');
// the particle pool: 50 events at once never take it over 48
const storm = opened(); stageSync(storm, lay([job('J1')], Array.from({ length: 50 }, (_, i) => evOf('job.done', 'J' + (200 + i), 60 - i))));
let maxParts = 0; for (let i = 0; i < 2000; i++) { stageTick(storm, 16); maxParts = Math.max(maxParts, storm.fx.parts.length); }
const pool = fxNew(); let took = 0; for (let i = 0; i < 100; i++) took += spawn(pool, { t0: 0 }) ? 1 : 0;
check(`MomentPool: 50 events at once keep the particle pool at most ${FX.pool} live (${maxParts}); the pool refuses the 49th`, maxParts > 0 && maxParts <= FX.pool && took === FX.pool && pool.parts.length === FX.pool);
// a moment adds at most 20 draws, at any time of its run
const fxRec = (kind) => {
  const jobs = [job('J1', { plan: [{ station: 'tests' }] }), job('J5', { status: 'quarantined' })], s = opened(jobs), type = { flip: 'step.done', sparkle: 'step.done', puff: 'step.rework', aside: 'job.quarantined', bell: 'approval.requested', orderup: 'job.done' }[kind];
  const base = drawStage(mk(STAGE.w, STAGE.h).getContext(), s, kit);
  stageSync(s, lay(jobs, [evOf(type, kind === 'aside' ? 'J5' : 'J1', 3, { step: kind === 'sparkle' ? 0 : 3 })]));
  let worst = 0, kinds = new Set(); for (let i = 0; i < 100; i++) { stageTick(s, 20); s.fx.live.forEach((m) => kinds.add(m.kind)); worst = Math.max(worst, drawStage(mk(STAGE.w, STAGE.h).getContext(), s, kit) - base); }
  return { worst, played: kinds.has(kind) };
};
const per = Object.fromEntries(['flip', 'sparkle', 'puff', 'aside', 'bell', 'orderup'].map((k) => [k, fxRec(k)]));
check(`MomentDraws: each moment plays and adds at most 20 draws a frame (${Object.entries(per).map(([k, v]) => k + ' ' + v.worst).join(', ')})`, Object.values(per).every((v) => v.played && v.worst <= 20 && v.worst >= 0));
// reduced motion: a still "after" frame (the check over the sink, the banner), nothing moves, nothing queues
const rs = stageNew(); stageSync(rs, lay([job('J1', { plan: [{ station: 'tests' }] })], []), { still: true });
stageSync(rs, lay([job('J1', { plan: [{ station: 'tests' }] })], [evOf('step.done', 'J1', 3, { step: 0 }), evOf('job.done', 'J7', 2)]), { still: true });
rkit.layers.clear(); drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), rs, rkit);   // (the first draw bakes the layers)
const rA = (rec.length = 0, drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), rs, rkit), [...rec]), rB = (rec.length = 0, drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), rs, rkit), [...rec]);
check('MomentStill: reduced motion shows the after frame (check mark, banner), the same draws twice, no particles, no queue, one announce line',
  rA.includes('check:0') && rA.includes('banner:0') && rA.join() === rB.join() && !rs.fx.parts.length && !rs.fx.queue.length && !rs.fx.live.length && /^WO-0007 is handed over/.test(rs.fx.line || '') && [...rs.actors.values()].every((a) => !a.path.length));
// announce: one polite line per 10 s, ticket numbers only
const an = opened([job('J1', { name: 'improve: secret plan' })]); stageSync(an, lay([job('J1')], [evOf('job.done', 'J1', 2), evOf('approval.requested', 'J2', 1)])); stageTick(an, 16);
const line1 = an.fx.line; an.fx.line = null; for (let i = 0; i < 40; i++) stageTick(an, 50);
check('MomentAnnounce: a moment lands as one #announce line, at most 1 per 10 s, with ticket numbers only', line1 === 'WO-0001 is handed over' && an.fx.line === null && !/secret|improve/.test(line1));
// juice: tweens, anticipation crouch, hit-stop and the pass shake on Approve only, never a screen shake
const near = (a, b) => Math.abs(a - b) < 1e-9;
const wk = opened([]); stageSync(wk, lay([job('J64', { role: 'plan' })], [])); const a64 = wk.actors.get('J64'), x0 = [a64.x, a64.y].join();
stageTick(wk, 50); const crouched = [a64.x, a64.y].join() === x0 && chefPose(wk, a64)?.name === 'chef-crouch'; stageTick(wk, 50); stageTick(wk, 50);
check('JuiceTweens: easeOutBack and easeInOutCubic start at 0 and end at 1; a walk starts with one 80 ms crouch (no step), then moves',
  near(easeOutBack(0), 0) && near(easeOutBack(1), 1) && easeOutBack(0.7) > 1 && near(easeInOutCubic(0), 0) && near(easeInOutCubic(0.5), 0.5) && near(easeInOutCubic(1), 1) && crouched && [a64.x, a64.y].join() !== x0);
const ap = opened([]); stageSync(ap, lay([job('J65', { role: 'plan' })], [])); stageTick(ap, 100); const a65 = ap.actors.get('J65'); approveFx(ap);
const xA = [a65.x, a65.y].join(); stageTick(ap, 40); const frozen = [a65.x, a65.y].join() === xA; stageTick(ap, 60); const shk = passFx(ap).dx; for (let i = 0; i < 10; i++) stageTick(ap, 50);
check('JuiceApprove: Approve holds the floor still for 80 ms (hit-stop), then the pass shakes 1 px, then stops; nothing else is shaken',
  frozen && Math.abs(shk) === 1 && passFx(ap).dx === 0 && passFx(stageNew()).dx === 0 && /sceneApproved\(\); await act\(\{ op: 'approve'/.test(fs.readFileSync(new URL('./public/app.js', import.meta.url), 'utf8')));
// tapping a chef: it waves and says its words for 3 s, on the compact stage too; a private order waves with no words
const tp = opened([job('J66', { activity: [{ tool: 'Edit', target: 'app.css' }] }), job('J67', { private: true })]); const Lc = lay([job('J66', { activity: [{ tool: 'Edit', target: 'app.css' }] }), job('J67', { private: true })], [], Tm, true);
stageSync(tp, Lc); tapChef(tp, 'J66'); const sayOn = hitItems(Lc, 0, { P, wave: tp.fx.wave.key }).filter((i) => i.kind === 'say');
for (let i = 0; i < 70; i++) stageTick(tp, 50); tapChef(tp, 'J67'); const sayPriv = hitItems(Lc, 0, { P, wave: 'J67' }).filter((i) => i.kind === 'say');
check('TapWave: a tapped chef waves and its words show for 3 s even on the compact stage (then stop); a private order shows none',
  sayOn.length === 1 && sayOn[0].word === 'Editing ap…' && sayOn[0].show && hitItems(Lc, 0, { P }).every((i) => i.kind !== 'say') && sayPriv.length === 0 && tp.fx.wave.key === 'J67' && fxBusy(tp));
// ---- J288 follow-ups: cooks never overlap; speech bubbles never cover a WORLD prop ----
const cols = (st) => [...st.actors.values()].filter((a) => a.kind === 'chef').map((a) => { const e = a.path.length ? a.path[a.path.length - 1] : [a.x]; return e[0]; }).sort((a, b) => a - b);
const crowd = (roles) => { const s = stageNew(); stageSync(s, lay(roles.map((r, i) => job('J' + (300 + i), { role: r })), [])); return cols(s); };
const apart = (xs) => xs.every((x, i) => i === 0 || x - xs[i - 1] >= 16);
const cr = [['do', 'do'], ['do', 'do', 'do'], ['plan', 'plan', 'do', 'do', 'check', 'check'], ['tests', 'tests', 'commit', 'commit', 'commit', 'merge']].map(crowd);
check(`CooksApart: two or more cooks at one station never share a pixel column (16 px bodies: ${cr.map((x) => x.join('/')).join(' | ')}), all on the floor`,
  cr.every(apart) && cr.every((xs) => xs[0] >= 8 && xs[xs.length - 1] <= STAGE.exitX - 8) && crowd(['do'])[0] === Math.round(STATIONS.stove.x * 0.48) && spread([50, 50]).join() === '42,58');
const busyLive = [...['plan', 'plan', 'do', 'do', 'check', 'tests'].map((r, i) => job('J' + (400 + i), { role: r, activity: [{ tool: 'Edit', target: 'something-long.js' }] }))];
const sayCase = (k, W) => { const L = layoutScene({ ...fullState(), jobs: [...busyLive, ...fullJobs().slice(1)] }, fullEvents(), {}, T0), R = propRects(L.world, P);
  const says = hitItems(L, (W - STAGE.w) >> 1, { P, k, W }).filter((i) => i.kind === 'say'); return { R, says }; };
const hit2 = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
const cases = [[1.5, 192], [1.9, 216], [3, 256]].map(([k, W]) => sayCase(k, W));
check(`BubblesOffProps: on the Live tab no speech bubble covers a WORLD prop (cork board, hooks, chalkboard, shelf ...) or another bubble; one with no free spot is left out, a tapped chef's always shows (${cases.map((c) => c.says.length + ' bubbles / ' + c.R.length + ' props').join(', ')})`,
  cases.every((c) => c.R.length >= 10 && c.says.length >= 3 && c.says.every((s, i) => !c.R.some((r) => hit2(r, s.rect)) && !c.says.some((t, j) => j !== i && hit2(t.rect, s.rect)))) && busyLive.every((j) => hitItems(layoutScene({ ...fullState(), jobs: busyLive }, fullEvents(), {}, T0), 0, { P, k: 1.5, wave: j.id }).some((i) => i.kind === 'say' && i.key === 's' + j.id)));
check('BubblesOffProps: the bubble is its own aria-hidden span (the chef link keeps its label), placed by left/top on the stage',
  /<span class="px-say" aria-hidden="true"[^>]*data-css="left:[\d.]+%;top:[\d.]+%;bottom:auto;margin:0;pointer-events:none">Editing so…<\/span>/.test(hitItems(layoutScene({ jobs: busyLive }, [], {}, T0)).map((it) => hitHtml(it)).join('')));
// sprites for the moments: declared frames
// the moments as a site (rename S7f): a brick laid, a work glove, the HANDED OVER banner
const spellsIn = (rows, word, x0, y0) => [...word].every((ch, i) => P.GLYPHS[ch].every((r, gy) => [...r].every((px, gx) => (px === 'a') === (rows[y0 + gy][x0 + i * 4 + gx] === 'p'))));
const bricks = P.framesOf('pan-flip');
check('SiteMoments: a finished step lays a brick: it rises and lands on a small stack (4 frames: up, up, top, landed), no pan and no food',
  bricks.every((f) => f.slice(10).join('') === bricks[0].slice(10).join('') && /B/.test(f.slice(0, 8).join(''))) && bricks[3].slice(6, 8).join('').includes('B') && !bricks[0].slice(6, 8).join('').includes('B') && !/[ghiI]/.test(bricks.flat().join('')));
check(`SiteMoments: a handed-over work order raises a HANDED OVER banner (the status word, spelled pixel by pixel), inside the stage (${P.SPRITES.banner.w} px at x 125)`,
  P.BANNER_WORDS === 'HANDED OVER' && spellsIn(P.framesOf('banner')[0], 'HANDED OVER', 4, 3) && 125 + P.SPRITES.banner.w <= STAGE.w && !/ORDER/.test(fs.readFileSync(new URL('./public/sprites.js', import.meta.url), 'utf8')));
check('SiteMoments: the head scratch and the wave wear a work glove (no bare skin, no oven mitt)', !/[123]/.test(P.framesOf('mitt')[0].join('')) && /e/.test(P.framesOf('mitt')[0].join('')));
const mdecl = { 'pan-flip': 4, 'chef-crouch': 1, 'chef-squash': 1, puff: 4, 'smoke-dark': 6, check: 1, confetti: 3, banner: 1, mitt: 1 };
check('frames: moment sprites have their declared frames (flip 4, crouch 1, squash 1, puff 4, smoke 6, check 1, confetti 3 colours, banner 1)',
  Object.entries(mdecl).every(([n, k]) => P.framesOf(n).length === k) && new Set(P.framesOf('confetti').map((f) => f.join())).size === 3 && P.framesOf('banner')[0].join('').includes('p'));
// bytes after brotli (node's own brotli, as the server sends them) of the stage files, against the plan's budgets
// the site around the crew (rename S7d): the room, the job board and the sign-off window
const one1 = (n) => P.framesOf(n)[0], most = (rows) => { const c = {}; for (const ch of rows.join('')) c[ch] = (c[ch] || 0) + 1; return Object.entries(c).sort((a, b) => b[1] - a[1])[0][0]; };
check('SiteRoom: a concrete slab, not a checker floor (both floor tiles share one base colour); no white tile and no brick anywhere in the room',
  most(one1('floor-a')) === most(one1('floor-b')) && !/[oDEF]/.test(one1('subway').join('') + one1('wall').join('')));
check('SiteRoom: the runners carry clipboards (paper on a board, no steel dome), a caged work light burns over the sign-off window',
  /p/.test(one1('cloche').join('')) && /[bd]/.test(one1('cloche').join('')) && !/i/.test(one1('cloche').join('')) && one1('lamp')[5].startsWith('.a') && /I/.test(one1('lamp').join('')) && !/[IW]/.test(one1('lamp-off').join('')));
const card = one1('ticket'), onPaper = (x0, x1, rows) => rows.every((y) => card[y].slice(x0, x1 + 1).split('').every((c) => c === 'p'));
check(`SiteRoom: the work-order card's digits and step bar land on paper and read (digits ${ratio(P.PALETTE.a, P.PALETTE.p).toFixed(1)}:1, bar ${ratio(P.PALETTE.r, P.PALETTE.p).toFixed(1)}:1)`,
  onPaper(2, 8, [3, 4, 5, 6, 7, 10]) && ratio(P.PALETTE.a, P.PALETTE.p) >= 4.5 && ratio(P.PALETTE.r, P.PALETTE.p) >= 3 && P.SPRITES.ticket.w === 11 && P.SPRITES.ticket.h === 13);
check('SiteRoom: the job board and the sign-off window wear hazard tape (yellow and black)', /H/.test(one1('rail').join('')) && /H/.test(one1('pass').slice(0, 3).join('')));
// the polish (S7h, board concept 2026-10-26 section 5 items 1-4): open stations, a poured slab; nothing reads as a cabinet, an oven or a tiled floor
const fill = (rows) => rows.join('').replace(/\./g, '').length / rows.join('').length;
check(`SiteOpenStations: the Survey table and Inspection desk are trestle tables and the Workbench stands on legs: open under the top (filled ${Math.round(fill(one1('counter').slice(5)) * 100)} % and ${Math.round(fill(one1('stove').slice(5)) * 100)} %; the old cabinets 100 %), the Test rig is open between its panel and its shelf`,
  fill(one1('counter').slice(5)) <= 0.25 && fill(one1('stove').slice(5)) <= 0.5 && fill(one1('sink').slice(14, 17)) <= 0.5 && one1('counter').slice(5).every((r) => /^\.{3}/.test(r)));
const bench = one1('stove');
check('SiteWorkbench: no dark recess with a red block (no red in the Workbench); a yellow toolbox with a handle above it and a latch on it sits on the lower shelf',
  !/[qAB]/.test(bench.join('')) && /H/.test(bench.slice(10, 15).join('')) && /a{6}/.test(bench[8]) && /f/.test(bench[12].slice(8, 20)) && /^\.\.g+\.\.$/.test(bench[15]));
check('SiteWorkbench: the weld sparks are white and yellow only (no orange: orange over a bench read as a hob); the weld flash stays blue-white',
  P.framesOf('flame').every((f) => /^[.Wt]+$/.test(f.join(''))) && P.framesOf('oven-glow').every((f) => /^[.WIz]+$/.test(f.join(''))));
const rig = one1('sink'), led = one1('bubble');
check('SiteTestRig: a scope screen with a green trace, and the busy LEDs are green (not the orange of an oven display); each chasing LED lands on the dark LED strip',
  /^[.vw]+$/.test(led.join('')) && /w/.test(rig.slice(2, 9).join('')) && [0, 1, 2, 3].every((k) => led.every((r, y) => [...r].every((c, x) => c === '.' || /[Nu]/.test(rig[10 + y][4 + k * 3 + x])))));
check('SiteHandoverBay: the Handover bay is a crate on a pallet on the slab, not a table (the floor bakes 2 trestle tables, 1 pallet)',
  bare.filter((r) => r === 'counter:0').length === 2 && bare.filter((r) => r === 'pallet:0').length === 1 && /^[.a]+$/.test(one1('pallet')[19]) && /\.{3}/.test(one1('pallet')[19]));
const seamless = (rows) => rows.every((r) => /n/.test(r)) && rows[0].split('').every((_, x) => rows.some((r) => r[x] === 'n'));
check('SiteSlab: a poured slab: both floor tiles are one colour with a few specks (a crack on one), and no tile seam (no row or column of another colour)',
  most(one1('floor-a')) === 'n' && most(one1('floor-b')) === 'n' && seamless(one1('floor-a')) && seamless(one1('floor-b')) && ['floor-a', 'floor-b'].every((n) => one1(n).join('').replace(/n/g, '').length <= 8));
// the polish (S7i, section 5 items 5-9 and 11): the live floor is the tower's top floor, open to the real sky
const sky = one1('wall'), edgeBand = one1('subway');
check('SiteOpenSky: the back is the real sky (only the hour\'s sky slots X/Y/Z and steel shores, 40 rows), which changes with the hour and stays lit at night',
  P.SPRITES.wall.h === 40 && /^[XYZfgh]+$/.test(sky.join('')) && sky.filter((r) => /^[XYZ]+$/.test(r.replace(/[fgh]/g, ''))).length === 40 && sky.every((r) => /[fg]/.test(r))
  && P.paletteFor({ sky: 'night' }).X !== P.paletteFor({ sky: 'day' }).X && /X/.test(P.EMISSIVE) && /Z/.test(P.EMISSIVE));
check(`SiteGuardRail: at the open edge a yellow top rail and mid rail on posts, debris netting, the sky behind, and a toe board a shade lighter than the slab (luminance ${lum(P.PALETTE.m).toFixed(2)} vs ${lum(P.PALETTE.n).toFixed(2)})`,
  edgeBand.filter((r) => /^H+$/.test(r)).length === 2 && /z/.test(edgeBand.slice(4, 7).join('')) && /Z/.test(edgeBand[0]) && /^m+$/.test(edgeBand[13]) && lum(P.PALETTE.m) > lum(P.PALETTE.n) && /[fg]/.test(edgeBand[5]));
const hoistOf = (key) => { const st = stageNew(); stageSync(st, layoutScene({ jobs: [] }, [], {}, T0)); if (key) stageSync(st, layoutScene({ jobs: [job(key, { role: 'plan' })] }, [], {}, T0)); rec.length = 0; drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), st, rkit); return [...rec]; };
const cageArt = one1('door'), cageOpen = one1('hoist-open');
check('SiteHoist: the crews arrive by the hoist: a steel mesh cage between hazard bands (no wooden door); its gate stands open with the call lamp lit only while a crew is arriving',
  !/[bcde]/.test(cageArt.join('')) && /H/.test(cageArt[1]) && /H/.test(cageArt[27]) && /t/.test(cageOpen[0]) && !/t/.test(cageArt.join(''))
  && hoistOf('J61').includes('hoist-open:0') && !hoistOf(null).includes('hoist-open:0'));
check('SiteCut: the paint tins, the pegboards, their shelf and the window frame are gone (no data: decoration, P8); the bake draws none of them',
  ['jar', 'pan', 'shelf', 'window'].every((k) => !P.SPRITES[k] && !bare.some((r) => r.startsWith(k + ':'))) && !('jars' in P.FRAMES));
const cabin = one1('pass'), glow = one1('pass-glow').join(''), needsOne = { jobs: [job('J80', { status: 'waiting-approval', approval: { id: 'A80' } })] };
check('SiteCabin: the sign-off window is the site cabin: corrugated steel, a framed window of dark glass that glows amber only while a sign-off waits',
  cabin.slice(4, 26).every((r) => /^a[gh]{2}/.test(r)) && !/[DEFIt]/.test(cabin.join('')) && /N/.test(cabin.slice(5, 24).join(''))
  && (glow.match(/[ts]/g) || []).length > glow.length * 0.8 && !drawnW({ jobs: [] }).includes('pass-glow:0') && drawnW(needsOne).includes('pass-glow:0'));
const NIGHT = new Date(2026, 9, 22, 23, 0).getTime(), drawnAt = (s, now) => { rec.length = 0; rkit.layers.clear(); const st = stageNew(); stageSync(st, layoutScene(s, [], {}, now), {}); drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), st, rkit); return [...rec]; };
check('SiteDepth: a contact shadow under each station (2 each), a darker strip along the slab\'s front edge, and a warm pool under the work light only on a night shift (crews at work after dark with the light on: none idle, by day, with the light out or without its field)',
  bare.filter((r) => r === 'shadow:0').length >= 10 && bare.filter((r) => r === 'edge:0').length >= 12 && /I/.test(one1('pool').join('')) && /I/.test(P.EMISSIVE)
  && drawnAt({ jobs: [job('J1')], breaker: false }, NIGHT).includes('pool:0') && !drawnAt({ jobs: [], breaker: false }, NIGHT).includes('pool:0') && !drawnAt({ jobs: [job('J1')], breaker: false }, T0).includes('pool:0')
  && !drawnAt({ jobs: [job('J1')], breaker: true }, NIGHT).includes('pool:0') && !drawnAt({ jobs: [job('J1')] }, NIGHT).includes('pool:0'));
// the words around the scene (rename S7g): nothing a person reads or hears from the scene is a kitchen word any more
const KITCHEN_WORDS = /\b(toques?|cloches?|chefs?|order up|kitchen|cooks?|cooking|stove|sink|plates?|tickets?|rail|waiters?|sous|pass|coin jar|chalkboard|cork board|recipes?|fuse box|heat lamps?|hatch|window sign|closed)\b/i;
const busyL = layoutScene(busy, [{ type: 'job.done', job: 'J39', ts: new Date(T0 - 60000).toISOString() }], {}, T0), cardHtml = sceneHtml(busy, [{ type: 'job.done', job: 'J39', ts: new Date(T0 - 60000).toISOString() }], {}, T0);
const heard = [...legendRows(layoutScene(fullState(), fullEvents(), {}, T0)).map((r) => r.text), busyL.summary, layoutScene(fullState(), fullEvents(), {}, T0).summary,
  ...hitItems(busyL).map((it) => it.label || it.word || ''), ...[...cardHtml.matchAll(/aria-label="([^"]*)"|>([^<>]+)</g)].map((m) => m[1] || m[2]), ...P.SIGN_WORDS, P.BANNER_WORDS,
  ...Object.values(STATIONS).map((s) => s.label)];
const appSrc = fs.readFileSync(new URL('./public/app.js', import.meta.url), 'utf8'), pageSrc = fs.readFileSync(new URL('./public/index.html', import.meta.url), 'utf8');
const said = heard.filter((w) => KITCHEN_WORDS.test(w));
check(`SiteWords: no toque, cloche, chef, ORDER UP or other kitchen word in what the scene shows or says (${heard.length} strings${said.length ? '; found: ' + said.slice(0, 3).join(' | ') : ''}); the empty Board says "Nothing building."; the listen button says "work order"; the hand-over toast says "Handed over: WO-…" (no "Order up!"); Clear old asks about "work orders"`,
  said.length === 0 && heard.length > 40 && /<p>Nothing building\.<\/p>/.test(appSrc) && !/Nothing on the stove/.test(appSrc) && /aria-label="Listen to this work order"/.test(pageSrc) && !/Listen to this ticket/.test(pageSrc)
  && appSrc.includes('toast(`${STATUS_LABEL.done}: ${ticket(e.job)}.`)') && !/Order up/i.test(appSrc)
  && appSrc.includes("old ${list.length === 1 ? 'work order' : 'work orders'}?") && !/old tickets/.test(appSrc));
// the critic's MUST items (audits/art-critique-S7-2026-10-26.md, 2026-10-26): words that match the stations, bubbles that stay with their crew
const sw = (k) => stepWord({ station: 'agent', role: k }), swS = (k) => stepWord({ station: k });
check('StationWords: the Inspection desk says "inspecting" (check, review) and the Test rig says "testing" (tests); every step word is lower case',
  sw('check') === 'inspecting' && sw('review') === 'inspecting' && swS('tests') === 'testing' && stationFor('review') === 'taste' && stationFor('tests') === 'sink'
  && ['plan', 'do', 'check', 'review', 'tests', 'lint', 'mutate', 'verify', 'commit', 'merge', 'freshen', 'map', 'diagnose'].every((k) => { const w = sw(k); return w === w.toLowerCase(); }));
const bubK = 1.5, bubH = 14 / bubK, bubCases = [busy, fullState()].map((s) => hitItems(layoutScene(s, [], {}, T0), 0, { P, k: bubK, W: STAGE.w }).filter((i) => i.kind === 'say'));
check(`BubbleNear: a speech bubble stands at most one bubble height over its crew member's head, or on the floor in front of its station (never up by the job board; ${bubCases.map((c) => c.length).join(' and ')} bubbles)`,
  bubCases.every((c) => c.length > 0 && c.every((b) => b.y >= STAGE.aisle - 24 - bubH - 0.01)));
check('SceneFrameWord: Settings > About says "Scene frame", never "Kitchen frame"', appSrc.includes('<dt>Scene frame</dt>') && !/Kitchen frame/i.test(appSrc));
// nothing floats: the gate sign and the budget meter hang by two chains from a gantry beam across the top; the power board hangs under it
const fullBake = drawnW(fullState(), fullEvents()), chainsAt = []; bakeWorld(worldOf(fullState(), fullEvents(), T0), (n, x, y) => n === 'chain' && chainsAt.push([x, y]));
check(`GantryHang: a gantry beam spans the sky (${fullBake.filter((r) => r === 'rail:0').length} beam tiles with the job board) and the gate sign and budget meter hang by 2 chains each that reach their tops; the power board touches the beam`,
  fullBake.filter((r) => r === 'rail:0').length >= 3 && fullBake.filter((r) => r === 'chain:0').length === 4 && chainsAt.every(([x, y]) => y === 3 || y === 4)
  && HANG.sign.every((dx) => chainsAt.some(([x, y]) => x === PLACE.sign[0] + dx && y + 12 === PLACE.sign[1])) && HANG.jar.every((dx) => chainsAt.some(([x, y]) => x === PLACE.jar[0] + dx && y + 12 === PLACE.jar[1]))
  && PLACE.fuse[1] <= 3 && !drawnW({ jobs: [] }).includes('chain:0'));
check('WorkLightTruth: the work light is drawn only with its field (breaker): none without it, lit when false, out when true',
  !drawnW({ jobs: [] }).some((r) => /^lamp/.test(r)) && drawnW({ jobs: [], breaker: false }).includes('lamp:0') && drawnW({ jobs: [], breaker: true }).includes('lamp-off:0') && !drawnW({ jobs: [], breaker: true }).includes('lamp:0'));
// no lost taps: the link layer is written only when its markup changes; a replaced stage lets go of its observers
let hitWrites = 0; const fakeSc = { hit: { set innerHTML(v) { hitWrites++; } } }, sameHtml = hitItems(layoutScene(busy, [], {}, T0), 0, { P }).map((it) => hitHtml(it)).join('');
const w1 = writeHits(fakeSc, sameHtml), w2 = writeHits(fakeSc, sameHtml), w3 = writeHits(fakeSc, sameHtml + ' ');
let disc = 0; const obs = () => ({ disconnect: () => disc++ }), oldSc = { io: obs(), ro: obs() }; dropStage(oldSc); dropStage(oldSc); dropStage(null);
check(`HitsStable: the same links twice write the layer once (${hitWrites} writes for 3 renders, 2 different); a dropped stage disconnects both observers once (${disc})`,
  w1 && !w2 && w3 && hitWrites === 2 && disc === 2 && oldSc.io === null && /dropStage\(sc\);\s*el\.innerHTML/.test(fs.readFileSync(new URL('./public/scene.js', import.meta.url), 'utf8')));
// ---- the Purpose Ledger (purpose.js): nothing drawn without a row, every row bound to a real field and event, every data mark a door ----
const rowsWith = (name) => PURPOSE.filter((r) => r.sprites.includes(name));
const drawnNames = new Set(), noteDrawn = (list) => { for (const r of list) drawnNames.add(r.split(':')[0]); return list; };
const NIGHTJ = new Date(2026, 9, 22, 23, 30).getTime(), DAWN = new Date(2026, 9, 22, 6, 30).getTime(), DUSK = new Date(2026, 9, 22, 19, 30).getTime();
const ledgerStates = [{ jobs: [] }, busy, fullState(), { ...fullState(), paused: true }, { ...fullState(), stalled: true, lastTick: ago(14) }, { ...fullState(), breaker: true }, { ...busy, breaker: false }];
for (const s of ledgerStates) for (const now of [T0, NIGHTJ, DAWN, DUSK]) noteDrawn(drawnAt(s, now));
for (const s of ledgerStates) noteDrawn(drawnW(s, fullEvents()));
noteDrawn(hoistOf('J61'));
// every moment, played: a stage opened on a busy floor, then fresh events of every kind arrive, then frames over 2 s
const mSt = stageNew(); stageSync(mSt, layoutScene({ ...busy, ...fullState(), jobs: busy.jobs }, [], {}, T0)); const fresh = (o) => ({ ...o, ts: iso(T0) });
const mEv = [fresh({ type: 'step.done', job: 'J40', step: 3 }), fresh({ type: 'step.rework', job: 'J41', step: 3 }), fresh({ type: 'job.quarantined', job: 'J74' }), fresh({ type: 'approval.requested', job: 'J71', approval: 'A7' }), fresh({ type: 'job.done', job: 'J39' }), fresh({ type: 'step.crash', job: 'J42', step: 3 })];
stageSync(mSt, layoutScene({ ...busy, jobs: [...busy.jobs, job('J71', { status: 'waiting-approval', approval: { id: 'A7' } }), job('J74', { status: 'quarantined' })] }, mEv, {}, T0));
for (let i = 0; i < 40; i++) { stageTick(mSt, 60); rec.length = 0; drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), mSt, rkit); noteDrawn(rec); }
const undeclared = [...drawnNames].filter((n) => !rowsWith(n).length), groundNames = PURPOSE.filter((r) => r.kind === 'ground').flatMap((r) => r.sprites);
check(`PurposeNoUndeclared: every sprite the stage draws (${drawnNames.size} names over 7 states x 4 skies, the hoist and every moment) has a Purpose Ledger row${undeclared.length ? '; undeclared: ' + undeclared.join(', ') : ''}; ground (no field) is capped at 19 names (${groundNames.length})`,
  undeclared.length === 0 && drawnNames.size > 60 && groundNames.length <= 19 && PURPOSE.every((r) => r.sprites.every((n) => P.SPRITES[n])));
const serverSrc = fs.readFileSync(new URL('./server.mjs', import.meta.url), 'utf8'), kitchenDir = new URL('../kitchen/', import.meta.url);
const kitchenSrc = fs.readdirSync(kitchenDir).filter((f) => f.endsWith('.ps1')).map((f) => fs.readFileSync(new URL(f, kitchenDir), 'utf8')).join('\n');
const stepKinds = (kitchenSrc.match(/'\^step\\\.\(([a-z|]+)\)\$'/) || [, ''])[1].split('|').filter(Boolean);
const emitted = (ev) => kitchenSrc.includes(`Emit '${ev}'`) || (ev.startsWith('step.') && stepKinds.includes(ev.slice(5)) && kitchenSrc.includes('Emit "step.$kind"'));
const unbound = PURPOSE.filter((r) => r.kind === 'data').flatMap((r) => [...r.fields.filter((f) => !new RegExp(`\\b${f}\\b`).test(serverSrc)).map((f) => r.id + '.' + f),
  ...(r.events || []).filter((e) => !emitted(e)).map((e) => r.id + ':' + e), ...(serverSrc.includes(`'${r.endpoint}'`) ? [] : [r.id + ' ' + r.endpoint])]);
check(`PurposeBound: every data row names state fields the server sends (server.mjs), an endpoint it serves, and events the Yard emits (kitchen/*.ps1; step kinds ${stepKinds.join('/')})${unbound.length ? '; unbound: ' + unbound.join(', ') : ''}`,
  unbound.length === 0 && stepKinds.length >= 7 && PURPOSE.filter((r) => r.kind === 'data').every((r) => r.changes && r.absent && r.tap && (r.fields.length || r.events?.length)));
check(`MomentsBound: every moment plays for an event the Yard really emits (${Object.keys(MOMENTS).length} event types)`, Object.keys(MOMENTS).every(emitted));
// doors: every data row on the stage has one (its work order's link, or a button to its legend line), and every door leads somewhere real
const doorCases = [layoutScene(fullState(), fullEvents(), {}, T0), layoutScene({ ...busy, breaker: false }, [{ type: 'job.done', job: 'J39', ts: ago(1) }], {}, NIGHTJ), layoutScene({ jobs: [], due: 1 }, [], {}, T0)];
const dead = [];
for (const L of doorCases) {
  const items = hitItems(L, 0, { P }), lines = legendRows(L).map((r) => r.key), ids = new Set([...L.src.jobs.map((j) => j.id), ...L.runners.map((r) => r.id)]);
  for (const key of lines) {
    const r = PURPOSE.find((x) => x.id === key), byLink = { crew: 'chef', cards: 'ticket', aside: 'aside', handed: 'waiter', signoff: 'waiter' }[key];
    if (!items.some((it) => it.row === key || (byLink && it.kind === byLink))) dead.push(key);
    if (!r) dead.push('no ledger row ' + key);
  }
  for (const it of items.filter((i) => i.kind !== 'say')) if (it.id ? !ids.has(it.id) : !lines.includes(it.row)) dead.push('door to nothing ' + it.key);
}
const markHtml = hitItems(doorCases[0], 0, { P }).filter((i) => i.kind === 'mark').map((i) => hitHtml(i)).join('');
check(`PurposeDoors: every data mark on the stage is a door (${hitItems(doorCases[0], 0, { P }).filter((i) => i.kind === 'mark').length} marks on a full floor: legend buttons, the cabin and each sign-off light open their work order), and every door leads to a real work order or legend line${dead.length ? '; dead: ' + dead.join(', ') : ''}`,
  dead.length === 0 && /<button class="px-a px-mark" type="button" data-legend="sign"/.test(markHtml) && /px-mark" href="#\/job\/J72"/.test(markHtml) && /id="wl-sign"/.test(legendHtml(legendRows(doorCases[0]))));
// flips: the picture changes when (and because) the field does
const has = (list, n) => list.includes(n), FLIPS = [
  ['a crew arrives: the hoist gate opens', hoistOf(null), hoistOf('J61'), ['hoist-open:0']],
  ['a sign-off waits: the cabin window glows, a runner brings the clipboard', drawnW({ jobs: [job('J1')] }), drawnW({ jobs: [job('J1'), job('J9', { status: 'waiting-approval', approval: { id: 'A9' } })] }, [{ type: 'approval.requested', job: 'J9', approval: 'A9', ts: ago(5) }]), ['pass-glow:0', 'cloche:0', 'heat:0']],
  ['the wait passes 1 h: the sign-off light turns amber', drawnW(needsOne, [{ type: 'approval.requested', job: 'J80', approval: 'A80', ts: ago(5) }]), drawnW(needsOne, [{ type: 'approval.requested', job: 'J80', approval: 'A80', ts: ago(70) }]), ['heat:1']],
  ['the wait passes 4 h: the sign-off light turns red', drawnW(needsOne, [{ type: 'approval.requested', job: 'J80', approval: 'A80', ts: ago(70) }]), drawnW(needsOne, [{ type: 'approval.requested', job: 'J80', approval: 'A80', ts: ago(250) }]), ['heat:2']],
  ['paused: the gate sign says PAUSED and tape runs across the stations', drawnW(fullState()), drawnW({ ...fullState(), paused: true }), ['sign:2', 'tape:0', 'chair-up:0']],
  ['a stop-work order: the power board sparks and the work light goes out', drawnW(fullState()), drawnW({ ...fullState(), breaker: true }), ['fuse:1', 'lamp-off:0']],
  ['the spend rises: the budget meter fills', drawnW(fullState()), drawnW({ ...fullState(), spent: 15 }), ['coin-jar:6']],
  ['the walkrounds stop: the clock freezes and the Dispatcher is gone', drawnW(fullState()), drawnW({ ...fullState(), stalled: true, lastTick: ago(14) }), []],
  ['a work order fails: a crate on the bench, dust for 2 minutes', drawnW({ jobs: [job('J1')] }), drawnW({ jobs: [job('J1'), job('J5', { status: 'quarantined' })] }, [{ type: 'job.quarantined', job: 'J5', ts: ago(1) }]), ['plate-aside:0', 'smoke:0']],
];
const flat = FLIPS.filter(([, a, b, want]) => a.join() === b.join() || !want.every((n) => has(b, n) && !has(a, n)));
check(`PurposeFlips: each field change changes the picture with the sprites it should (${FLIPS.length} flips: ${FLIPS.map((f) => f[0].split(':')[0]).join('; ')})${flat.length ? '; flat: ' + flat.map((f) => f[0]).join(' | ') : ''}`,
  flat.length === 0 && drawnW(fullState()).some((r) => /^chef-s(it|ide):/.test(r)) && !drawnW({ ...fullState(), stalled: true, lastTick: ago(14) }).some((r) => /^chef-s(it|ide):/.test(r)));
check('PurposeLegend: the legend sheet is the ledger (every line is a data row; every data row with a line has its icon; no kitchen words)',
  doorCases.every((L) => legendRows(L).every((r) => PURPOSE.some((x) => x.id === r.key && x.kind === 'data') && P.LEGEND_ICONS[r.key] && /^[A-Z].*\.$/.test(r.text) && !KITCHEN_WORDS.test(r.text))));
// no kitchen word anywhere on screen (chain review 2026-10-26): every string a person can read in the Board's scripts and index.html
// (site-words.mjs: string literals and template text with markup plumbing and file names taken out; comments never count). sw.js is
// left out: the service worker shows nothing (its one hit is the cache name 'chef-shell-...', a code name the old stored caches use)
const pubDir = new URL('./public/', import.meta.url), screenFiles = fs.readdirSync(pubDir).filter((f) => /\.(js|html)$/.test(f) && f !== 'sw.js');
const onScreen = screenFiles.flatMap((f) => kitchenHits(fs.readFileSync(new URL(f, pubDir), 'utf8'), f));
const catches = kitchenHits("x = ['open', 'Open ticket']; toast(`Order up! ${t}`); h = `<h3 id=\"dish-h\">The dish</h3>`; // a ticket in a comment\nconst ticket = (id) => id; c = 'chef.' + k; d = `<div class=\"dish-head ${a}\">Recap</div>`;", 'probe.js');
check(`SiteWordsEverywhere: no chef, toque, kitchen, ticket, dish or ORDER UP in any string a person can read (${screenFiles.length} files: app.js, index.html, live.js, scene.js ...)${onScreen.length ? '; found: ' + onScreen.join(', ') : ''}; the probe catches the old words (${catches.length}) and skips comments, code names and classes`,
  onScreen.length === 0 && screenFiles.includes('app.js') && screenFiles.includes('index.html') && catches.length === 3 && catches.every((h) => /"(ticket|Order up|dish)"/i.test(h)));
const siteChrome = P.chromeSprites(mk);
check('SiteChrome: loading, offline and empty are drawn as site art (32x32: 4, 2 and 2 frames) and the empty one holds no clipboard or cloche (a shovel and an empty pallet)',
  siteChrome.load.width === 128 && siteChrome.off.width === 64 && siteChrome.empty.width === 64 && !/cloche/.test(fs.readFileSync(new URL('./public/sprites.js', import.meta.url), 'utf8').match(/one\('empty'[^\n]*/)[0]));
// ---- the WebGL2 renderer (gl.js, SCENE.md "Renderer"): the same scene as Canvas2D, a fallback without WebGL2, the frame budget ----
// a canvas with real pixels (RGBA, Canvas2D's source-over, whole pixels), so the two renderers can be compared pixel by pixel
const rgbOf = (css) => { const n = parseInt(String(css).slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; };
function pxCanvas(w, h) {
  const c = { width: w, height: h, data: new Uint8ClampedArray(w * h * 4) };
  const put = (X, Y, r, g, b, a) => { if (X < 0 || Y < 0 || X >= c.width || Y >= c.height || !a) return; const D = c.data, i = (Y * c.width + X) * 4, k = a / 255;
    D[i] = r * k + D[i] * (1 - k); D[i + 1] = g * k + D[i + 1] * (1 - k); D[i + 2] = b * k + D[i + 2] * (1 - k); D[i + 3] = a + D[i + 3] * (1 - k); };
  const ctx = {
    imageSmoothingEnabled: true, fillStyle: '#000000',
    createImageData: (ww, hh) => ({ width: ww, height: hh, data: new Uint8ClampedArray(ww * hh * 4) }),
    putImageData: (img, x, y) => { for (let j = 0; j < img.height; j++) for (let i = 0; i < img.width; i++) { const X = x + i, Y = y + j; if (X >= 0 && Y >= 0 && X < c.width && Y < c.height) c.data.set(img.data.subarray((j * img.width + i) * 4, (j * img.width + i) * 4 + 4), (Y * c.width + X) * 4); } },
    drawImage: (img, ...a) => {
      const [sx0, sy0, sw, sh, dx, dy, dw, dh] = a.length === 8 ? a : a.length === 4 ? [0, 0, img.width, img.height, ...a] : [0, 0, img.width, img.height, a[0], a[1], img.width, img.height], S = img.data;
      for (let j = 0; j < dh; j++) for (let i = 0; i < dw; i++) { const s = ((sy0 + Math.floor(((j + 0.5) * sh) / dh)) * img.width + sx0 + Math.floor(((i + 0.5) * sw) / dw)) * 4; put(dx + i, dy + j, S[s], S[s + 1], S[s + 2], S[s + 3]); }
    },
    fillRect: (x, y, ww, hh) => { const [r, g, b] = rgbOf(ctx.fillStyle); for (let j = 0; j < hh; j++) for (let i = 0; i < ww; i++) put(x + i, y + j, r, g, b, 255); },
  };
  c.getContext = (kind = '2d') => (kind === '2d' ? ctx : null);
  return c;
}
// a WebGL2 stand-in that really draws: it keeps the buffers, the atlas texture and a framebuffer, and rasterizes each drawElements as a
// GPU does (pixel centres, one owner for a pixel on an edge two triangles share, texelFetch, premultiplied source-over). The vertex
// shader's job (p in canvas pixels from the top left) is taken as gl.js writes it; the shaders themselves run only in a browser.
// o: none (no WebGL2), throws, compiles: false, maxTex, raster: false (count calls only, for the timing run)
const GLK = Object.fromEntries(['VERTEX_SHADER', 'FRAGMENT_SHADER', 'COMPILE_STATUS', 'LINK_STATUS', 'ARRAY_BUFFER', 'ELEMENT_ARRAY_BUFFER', 'DYNAMIC_DRAW', 'STATIC_DRAW', 'FLOAT', 'UNSIGNED_BYTE',
  'UNSIGNED_SHORT', 'TRIANGLES', 'TEXTURE0', 'TEXTURE_2D', 'RGBA8', 'RGBA', 'TEXTURE_MIN_FILTER', 'TEXTURE_MAG_FILTER', 'NEAREST', 'TEXTURE_WRAP_S', 'TEXTURE_WRAP_T', 'CLAMP_TO_EDGE',
  'UNPACK_PREMULTIPLY_ALPHA_WEBGL', 'BLEND', 'ONE', 'ONE_MINUS_SRC_ALPHA', 'COLOR_BUFFER_BIT', 'MAX_TEXTURE_SIZE'].map((k, i) => [k, 0x9000 + i]));
function fakeGl(o = {}) {
  const K = GLK, raster = o.raster !== false, LOC = { p: 0, t: 1, c: 2 };
  const g = { ...K, n: { draw: 0, upload: 0, clear: 0 }, bound: {}, attrs: {}, uni: {}, tex: null, texW: 0, pre: false, fb: null, fbW: 0, fbH: 0, clearC: [0, 0, 0, 0], shaders: [] };
  const vert = (i) => {
    const b = g.bound[K.ARRAY_BUFFER].bytes, dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const A = (l) => { const a = g.attrs[l], at = i * a.stride + a.off; return Array.from({ length: a.size }, (_, k) => (a.type === K.FLOAT ? dv.getFloat32(at + k * 4, true) : dv.getUint8(at + k) / (a.norm ? 255 : 1))); };
    return { p: A(0), t: A(1), c: A(2) };
  };
  // a pixel centre exactly on an edge belongs to the triangle that walks that edge downwards (or leftwards when flat): the two triangles
  // of a quad walk their shared diagonal in opposite directions, so each such pixel is drawn once
  const E = (ax, ay, bx, by, px, py) => (bx - ax) * (py - ay) - (by - ay) * (px - ax);
  function tri(a, b, c) {
    const [x0, y0] = a.p, [x1, y1] = b.p, [x2, y2] = c.p, area = E(x0, y0, x1, y1, x2, y2); if (!area) return;
    const s = Math.sign(area), den = s * area, own = (ux, uy, vx, vy) => { const dx = (vx - ux) * s, dy = (vy - uy) * s; return dy > 0 || (dy === 0 && dx < 0); };
    const o0 = own(x1, y1, x2, y2), o1 = own(x2, y2, x0, y0), o2 = own(x0, y0, x1, y1), T = [a.t, b.t, c.t], C = [a.c, b.c, c.c], tex = g.tex, fb = g.fb;
    const Y0 = Math.max(0, Math.floor(Math.min(y0, y1, y2))), Y1 = Math.min(g.fbH, Math.ceil(Math.max(y0, y1, y2))), X0 = Math.max(0, Math.floor(Math.min(x0, x1, x2))), X1 = Math.min(g.fbW, Math.ceil(Math.max(x0, x1, x2)));
    for (let Y = Y0; Y < Y1; Y++) for (let X = X0; X < X1; X++) {
      const px = X + 0.5, py = Y + 0.5;
      const w0 = s * E(x1, y1, x2, y2, px, py); if (w0 < 0 || (w0 === 0 && !o0)) continue;
      const w1 = s * E(x2, y2, x0, y0, px, py); if (w1 < 0 || (w1 === 0 && !o1)) continue;
      const w2 = s * E(x0, y0, x1, y1, px, py); if (w2 < 0 || (w2 === 0 && !o2)) continue;
      const lerp = (V, k) => (w0 * V[0][k] + w1 * V[1][k] + w2 * V[2][k]) / den;
      const ti = (Math.floor(lerp(T, 1)) * g.texW + Math.floor(lerp(T, 0))) * 4, d = (Y * g.fbW + X) * 4, sa = (tex[ti + 3] / 255) * lerp(C, 3); if (!sa) continue;
      for (let k = 0; k < 3; k++) fb[d + k] = Math.round(tex[ti + k] * lerp(C, k) + fb[d + k] * (1 - sa));
      fb[d + 3] = Math.round(sa * 255 + fb[d + 3] * (1 - sa));
    }
  }
  return Object.assign(g, {
    getParameter: (k) => (k === K.MAX_TEXTURE_SIZE ? (o.maxTex ?? 4096) : 0),
    createShader: (type) => ({ type }), shaderSource: (sh, src) => { sh.src = src; g.shaders.push(src); }, compileShader: () => {}, getShaderParameter: () => o.compiles !== false,
    createProgram: () => ({}), attachShader: () => {}, linkProgram: () => {}, getProgramParameter: () => true, useProgram: () => {},
    createVertexArray: () => ({}), bindVertexArray: () => {}, createBuffer: () => ({ bytes: null }), bindBuffer: (t, b) => { g.bound[t] = b; },
    bufferData: (t, d) => { g.bound[t].bytes = typeof d === 'number' ? new Uint8Array(d) : new Uint8Array(d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength)); },
    bufferSubData: (t, off, src, so = 0, len = src.length - so) => { const k = src.BYTES_PER_ELEMENT; if (raster) g.bound[t].bytes.set(new Uint8Array(src.buffer, src.byteOffset + so * k, len * k), off); },
    getAttribLocation: (p, name) => LOC[name], enableVertexAttribArray: () => {}, vertexAttribPointer: (l, size, type, norm, stride, off) => { g.attrs[l] = { size, type, norm, stride, off }; },
    activeTexture: () => {}, bindTexture: () => {}, createTexture: () => ({}), texParameteri: () => {},
    texStorage2D: (t, lv, f, w, h) => { g.texW = w; g.tex = raster ? new Uint8Array(w * h * 4) : null; },
    pixelStorei: (k, v) => { if (k === K.UNPACK_PREMULTIPLY_ALPHA_WEBGL) g.pre = !!v; },
    texSubImage2D: (t, lv, x, y, ...r) => {
      g.n.upload++; if (!raster) return;
      const [w, h, px] = r.length === 5 ? [r[0], r[1], r[4]] : [r[2].width, r[2].height, r[2].data];
      for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) { const s = (j * w + i) * 4, d = ((y + j) * g.texW + x + i) * 4, al = px[s + 3] / 255; for (let k = 0; k < 3; k++) g.tex[d + k] = g.pre ? Math.round(px[s + k] * al) : px[s + k]; g.tex[d + 3] = px[s + 3]; }
    },
    getUniformLocation: (p, name) => name, uniform1i: (l, v) => { g.uni[l] = v; }, uniform2f: (l, a, b) => { g.uni[l] = [a, b]; },
    enable: () => {}, blendFunc: (sf, df) => { g.blend = [sf, df]; },
    viewport: (x, y, w, h) => { if (w !== g.fbW || h !== g.fbH) { g.fbW = w; g.fbH = h; g.fb = new Uint8ClampedArray(w * h * 4); } },
    clearColor: (...c) => { g.clearC = c.map((v) => Math.round(v * 255)); }, clear: () => { g.n.clear++; if (raster && g.fb) for (let i = 0; i < g.fb.length; i += 4) g.fb.set(g.clearC, i); },
    drawElements: (mode, count, type, off) => { g.n.draw++; if (!raster) return; const ix = g.bound[K.ELEMENT_ARRAY_BUFFER].bytes, I = new Uint16Array(ix.buffer, ix.byteOffset, ix.byteLength / 2); for (let q = off / 2; q < off / 2 + count; q += 3) tri(vert(I[q]), vert(I[q + 1]), vert(I[q + 2])); },
  });
}
// a page canvas that can give WebGL2 (the fake) or Canvas2D, never both, as a browser's canvas does; gl.js may swap it for a fresh one
function glCanvas(w, h, o = {}) {
  const c = pxCanvas(w, h), two = c.getContext; let gl = null;
  Object.assign(c, { listeners: {}, parentNode: {}, addEventListener: (k, f) => { c.listeners[k] = f; }, cloneNode: () => glCanvas(w, h), replaceWith: (n) => { c.replacedBy = n; } });
  c.getContext = (kind, opts) => {
    if (kind !== 'webgl2') return gl ? null : two(kind);
    if (o.throws) throw new Error('no WebGL2'); if (o.none) return null;
    if (opts) c.opts = opts; return (gl ||= fakeGl(o));
  };
  return c;
}
// pixels that differ between a Canvas2D canvas and the fake's framebuffer (both opaque or clear here: the art has no part-transparent pixel)
const pxDiff = (a, b) => { let n = 0; for (let i = 0; i < a.length; i += 4) if (a[i] !== b[i] || a[i + 1] !== b[i + 1] || a[i + 2] !== b[i + 2] || a[i + 3] !== b[i + 3]) n++; return n; };
GL.INFO.lost = false;
const pxKit = makeKit(P, pxCanvas);
// one case: two stages built the same way (one per renderer), ticked together, every frame compared
const GL_SAME = [];
function sameScene(name, build, frames, dt) {
  const s2 = build(), sg = build(), c2 = pxCanvas(s2.W, STAGE.h), cg = glCanvas(sg.W, STAGE.h), R = GL.glStage(cg, () => {}), gl = cg.getContext('webgl2');
  const row = { name, frames: 0, diff: 0, calls: [], lit: 1 };
  for (let f = 0; f < frames; f++) {
    if (f) { stageTick(s2, dt); stageTick(sg, dt); }
    const d0 = gl.n.draw, c0 = gl.n.clear; paintStage(c2.getContext('2d'), s2, pxKit); paintStage(R, sg, pxKit);
    row.frames++; row.diff += pxDiff(c2.data, gl.fb); row.calls.push(gl.n.draw - d0 + 10 * (gl.n.clear - c0));
    let lit = 0; for (let i = 3; i < gl.fb.length; i += 4) if (gl.fb[i]) lit++; row.lit = Math.min(row.lit, lit / (gl.fb.length / 4));
  }
  GL_SAME.push(row); return row;
}
const runnerEv = [{ type: 'job.done', job: 'J39', ts: new Date(Date.parse('2026-10-22T12:00:00Z')).toISOString() }];
for (const hour of [6, 12, 19, 23]) sameScene(`busy floor at ${hour}:00`, () => {
  const st = stageNew(); st.W = 224; const Lb = layoutScene(busy, runnerEv, {}, Date.parse(`2026-10-22T${String(hour).padStart(2, '0')}:00:00`));
  stageSync(st, Lb); stageSync(st, { ...Lb, runners: [{ key: 'oJ55@x', id: 'J55' }] }); return st;
}, 12, 50);
for (const [name, s] of [['every prop', fullState()], ['paused', { ...fullState(), paused: true }], ['stop-work order', { ...fullState(), breaker: true }]]) sameScene(name, () => { const st = stageNew(); st.W = 256; stageSync(st, layoutScene(s, fullEvents(), {}, T0)); return st; }, 4, 120);
sameScene('every moment', () => {
  const st = stageNew(); st.W = 192; stageSync(st, layoutScene({ ...busy, ...fullState(), jobs: busy.jobs }, [], {}, T0));
  stageSync(st, layoutScene({ ...busy, jobs: [...busy.jobs, job('J71', { status: 'waiting-approval', approval: { id: 'A7' } }), job('J74', { status: 'quarantined' })] }, mEv, {}, T0)); return st;
}, 30, 60);
const sameFrames = GL_SAME.reduce((n, r) => n + r.frames, 0), sameDiff = GL_SAME.reduce((n, r) => n + r.diff, 0);
check(`GlSameScene: renders the same scene as Canvas2D on a fixture (${GL_SAME.length} cases: ${GL_SAME.map((r) => r.name).join(', ')}; ${sameFrames} frames compared pixel by pixel, ${sameDiff} pixels differ)`,
  sameDiff === 0 && sameFrames >= 70 && GL_SAME.every((r) => r.lit > 0.95));
check(`GlOneDraw: each frame clears once and is one draw call (${GL_SAME.flatMap((r) => r.calls).filter((n) => n === 11).length} of ${sameFrames} frames)`,
  GL_SAME.every((r) => r.calls.every((n) => n === 11)));   // 10 x clears + draws
// the atlas filling up mid-frame, and a frame over MAX_QUADS: the queued quads are drawn first, so the picture still matches
const slabs = Array.from({ length: 50 }, (_, i) => { const c = pxCanvas(300, 300); c.getContext().fillStyle = '#' + ((Math.imul(i + 1, 2654435761) >>> 8) & 0xffffff).toString(16).padStart(6, '0'); c.getContext().fillRect(0, 0, 300, 300); return c; });
const ref = pxCanvas(420, 320), fc = glCanvas(420, 320), glFR = GL.glStage(fc), fgl = fc.getContext('webgl2');
for (const [i, c] of slabs.entries()) for (const x of [ref.getContext(), glFR]) { x.drawImage(c, i * 2, i); x.drawImage(c, 10, 10, 40, 30, 300 + (i % 3) * 5, 200 + i, 40, 30); }
glFR.flush();
const glCrowd = pxCanvas(64, 48), cc = glCanvas(64, 48), glCR = GL.glStage(cc), cgl = cc.getContext('webgl2');
for (let i = 0; i < GL.MAX_QUADS + 300; i++) for (const x of [glCrowd.getContext(), glCR]) { x.fillStyle = '#' + ((i * 40503) & 0xffffff).toString(16).padStart(6, '0'); x.fillRect(i % 61, (i * 7) % 45, 3, 3); }
glCR.flush();
check(`GlAtlasFull: when the atlas fills mid-frame (${glFR.resets} restart, ${fgl.n.draw} draw calls) and when a frame passes ${GL.MAX_QUADS} quads (${cgl.n.draw} draw calls), the picture still matches Canvas2D (${pxDiff(ref.data, fgl.fb)} and ${pxDiff(glCrowd.data, cgl.fb)} pixels differ)`,
  glFR.resets >= 1 && fgl.n.draw >= 2 && cgl.n.draw >= 2 && pxDiff(ref.data, fgl.fb) === 0 && pxDiff(glCrowd.data, cgl.fb) === 0);
// no WebGL2: glStage says so and the canvas can still draw with Canvas2D (a fresh one when gl.js gave up after taking the context)
const FALL = [['no WebGL2', { none: true }, /no WebGL2/], ['getContext throws', { throws: true }, /no WebGL2/], ['the shaders do not build', { compiles: false }, /shaders/], ['textures under 2048 px', { maxTex: 1024 }, /2048/]]
  .map(([name, o, why]) => { const c = glCanvas(32, 16, o), r = GL.glStage(c), two = (c.replacedBy || c).getContext('2d'); return { name, ok: r === null && why.test(GL.INFO.why) && !GL.INFO.on && !!two && two.fillRect !== undefined, swapped: !!c.replacedBy }; });
const sceneSrc = fs.readFileSync(new URL('./public/scene.js', import.meta.url), 'utf8');
check(`GlFallback: falls back when WebGL2 is missing (${FALL.length} cases: ${FALL.map((f) => f.name + (f.ok ? '' : ' FAILED')).join(', ')}): glStage gives null, says why, and the stage draws with Canvas2D (a fresh canvas when the context was already taken: ${FALL.filter((f) => f.swapped).length})`,
  FALL.every((f) => f.ok) && FALL.filter((f) => f.swapped).length === 2 && /gl = GLM\?\.glStage\(root\.querySelector\('canvas'\), remount\), canvas = root\.querySelector\('canvas'\)/.test(sceneSrc) && /ctx: gl \|\| canvas\.getContext\('2d'\)/.test(sceneSrc));
const glLc = glCanvas(32, 16); let lostCalls = 0; const LR = GL.glStage(glLc, () => lostCalls++); glLc.listeners.webglcontextlost?.({});
let lostThrew = false; try { LR.drawImage(slabs[0], 0, 0); LR.fillRect(0, 0, 1, 1); LR.flush(); } catch { lostThrew = true; }
const afterLost = GL.glStage(glCanvas(32, 16)), lostWhy = GL.INFO.why;
check(`GlContextLost: a lost WebGL2 context falls back to Canvas2D for the rest of the visit (onLost ran ${lostCalls} time; later stages get null: "${lostWhy}"); drawing on the lost context throws nothing`,
  lostCalls === 1 && LR.lost && GL.INFO.lost && !lostThrew && afterLost === null && /lost/.test(lostWhy) && /const remount = \(\) => \{ for \(const el of mounted\) if \(el\._px\) \{ dropStage\(el\._px\); el\._px = null;/.test(sceneSrc));
GL.INFO.lost = false;
// behind a flag: ?gl (or ?gl=1) for this visit, Settings > About kept on this phone, ?gl=0 turns a kept one off; without it gl.js is never loaded
const FLAGS = [['', null, false], ['?gl', null, true], ['?hud&gl=1', null, true], ['', '1', true], ['?gl=0', '1', false], ['?glow', null, false], ['', '0', false], ['?fps&gl', '0', true]];
const appGl = fs.readFileSync(new URL('./public/app.js', import.meta.url), 'utf8');
check(`GlFlag: the WebGL2 renderer is behind a flag, off by default (${FLAGS.length} cases); gl.js is imported only when the flag is on, and Settings > About has its switch and says which renderer draws`,
  FLAGS.every(([q, k, want]) => glWanted(q, k) === want) && (sceneSrc.match(/import\('\.\/gl\.js'\)/g) || []).length === 2 && /glWanted\(location\.search, glk\) \? import\('\.\/gl\.js'\)/.test(sceneSrc) && /\(on \? import\('\.\/gl\.js'\) : Promise\.resolve\(null\)\)/.test(sceneSrc)
  && /id="gl-switch" \$\{sceneGl\(\) \? 'checked' : ''\}/.test(appGl) && /if \(e\.target\.id === 'gl-switch'\) return void sceneGl\(e\.target\.checked\);/.test(appGl) && /<dt>Scene renderer<\/dt>/.test(appGl));
const okC = glCanvas(8, 8); GL.glStage(okC); const okGl = okC.getContext('webgl2');
check('GlShaders: crisp pixels as on the Canvas2D stage (texelFetch at whole texels, nearest, no antialiasing), premultiplied source-over, and a software-only WebGL2 is refused (failIfMajorPerformanceCaveat)',
  /texelFetch\(tex, ivec2\(vt\), 0\) \* vc/.test(GL.FS) && /precision highp float/.test(GL.FS) && /p\.x \* 2\.0 \/ view\.x - 1\.0, 1\.0 - p\.y \* 2\.0 \/ view\.y/.test(GL.VS) && okGl.shaders.length === 2
  && okC.opts.antialias === false && okC.opts.failIfMajorPerformanceCaveat === true && okC.opts.premultipliedAlpha === true && okGl.blend.join() === [GLK.ONE, GLK.ONE_MINUS_SRC_ALPHA].join() && okGl.pre === true && GL.colorOf('#c2410c') === (0xc2 | 0x41 << 8 | 0x0c << 16 | 255 << 24) >>> 0 && GL.colorOf('nope') === (255 << 24) >>> 0);
// the frame budget (pass-app/speed/budget.json, the scene's frame work p95): a busy floor drawn every frame for 600 frames at 120 Hz
// steps, tick + draw through gl.js (the work the frame meter and the speed probe time); node has no GPU, so the GL calls cost nothing
// here: this is the CPU side the code controls. Every frame is one draw call and each strip is uploaded once (the -1: the white block for fillRect).
const target = JSON.parse(fs.readFileSync(new URL('./speed/budget.json', import.meta.url), 'utf8')).metrics.frameP95Ms.target;
const glBst = stageNew(); glBst.W = 256; stageSync(glBst, layoutScene({ ...busy, ...fullState(), jobs: busy.jobs }, runnerEv, {}, T0));
const bc = glCanvas(256, STAGE.h, { raster: false }), glBR = GL.glStage(bc), bgl = bc.getContext('webgl2'), work = [];
const seenImg = new Set(), drawImg = glBR.drawImage; glBR.drawImage = function (img) { seenImg.add(img); return drawImg.apply(this, arguments); };   // the strips and layers it was given
for (let f = 0; f < 600; f++) { const t0 = performance.now(); stageTick(glBst, 1000 / 120); paintStage(glBR, glBst, pxKit); work.push(performance.now() - t0); }
const fs95 = frameStats(work.slice(30));
check(`GlFrameBudget: frame time inside the speed budget (tick + draw p95 ${fs95.p95} ms, p50 ${fs95.p50} ms over ${fs95.n} warm frames; budget ${target} ms, a 120 Hz frame); ${bgl.n.draw} draw calls for 600 frames; ${bgl.n.upload - 1} uploads for ${seenImg.size} strips and layers drawn (each once; ${glBR.resets} atlas restarts)`,
  fs95.p95 <= target && bgl.n.draw === 600 && bgl.n.upload - 1 === seenImg.size && glBR.resets === 0);
const br = (f) => zlib.brotliCompressSync(fs.readFileSync(new URL('./public/' + f, import.meta.url))).length;
const stageBr = ['scene.js', 'sprites.js', 'world.js', 'frame.js', 'moments.js'].reduce((n, f) => n + br(f), 0);
// main before wave 1 (with the Live call art): 21,615 bytes. Plan: wave 1 +6 KB, wave 2 +5 KB. Measured 10-22: wave 1 + W4 (frame key,
// frame.js) +7,822; Chef 2.9.1 trims 332 of it (scene.js and world.js share esc/ticket, a shorter scene.js header): +7,490; wave 2
// (moments.js, the moment sprites, the cook spread, the bubble placement) +5,486. Ceiling +13,000 (was +8,000 for wave 1 + W4
// alone): about 2 KB over the two plan budgets together (1.5 from wave 1 + W4, 0.5 from wave 2); the PR says so.
// The frame loop (art critique S7 12c.1, 2026-10-26): main stood at 34,135 (LF); the dirty-flag loop, idle stop, frame clock and
// allocation-free draw measured 36,730 (+2,595, with plain comments: the critique's section 5 says stop trimming for bytes; the frame
// meter is its own file, frame-meter.js, loaded only when it is on). Ceiling +15,400; the phone speed budget (frame work p95) is the
// gate that replaces this one when Jordan taps it (critique section 11).
// The WebGL2 renderer (decisions D-4 and D-6: performance over size, byte caps stop being merge gates): main stood at 36,728 (LF);
// its hook in scene.js (the flag, the switch, the fallback, the remount) measured 37,116 (+388). gl.js itself is its own file, loaded
// only behind its flag, and not counted here (as frame-meter.js). Ceiling +15,600.
check(`budget: the stage files (scene, sprites, world, frame, moments) are at most 37,215 bytes brotli (${stageBr}; 21.6 KB before wave 1; plan +6 KB wave 1, +5 KB wave 2; ceiling +15.6 KB with the frame loop and the WebGL2 hook)`, stageBr <= 21615 + 15600);
console.log(JSON.stringify(out));
