// Tests for the scene's world (public/world.js, plans/chef-art-2.md wave 1: the world tells the truth) and the frame loop (frame.js,
// frame-meter.js). Run by pass-app/test-scene.mjs, after test-scene-stage.mjs, whose fixtures it reads.
import fs from 'node:fs';
import { layoutScene, COOK_COLORS, STAGE, stageNew, stageSync, stageTick, drawStage, makeKit, makeLoop, hitItems, hitHtml, frameStats,
  paintStage, stageFrame } from './public/scene.js';
import { stageOk, stageDirty, stageWait, stageMoving, CLOCK, tk, METER } from './public/frame.js';
import { meterNote, meterNew } from './public/frame-meter.js';
import { WORLD, worldOf, worldWords, worldKey, legendRows, legendHtml, PLACE } from './public/world.js';
import * as P from './public/sprites.js';
import { tapChef } from './public/moments.js';
import { busy, check, errors, job, kit, mk } from './test-scene-stage.mjs';

// ---- the world (plans/chef-art-2.md wave 1: the world tells the truth) ----
export const T0 = Date.parse('2026-10-22T15:07:00'), iso = (ms) => new Date(ms).toISOString(), ago = (min) => iso(T0 - min * 60000);
export const fullJobs = () => [job('J70'), job('J71', { status: 'waiting-approval', approval: { id: 'A7' } }), job('J72', { status: 'needs-human', approval: { id: 'A8' } }),
  job('J73', { status: 'quarantined', name: 'improve: secret plan J73', private: true }), job('J74', { status: 'failed' }), ...Array.from({ length: 10 }, (_, i) => job('J' + (80 + i), { status: 'pending', step: 1 }))];
export const fullState = () => ({ jobs: fullJobs(), paused: false, live: true, stalled: false, lastTick: ago(0.5), breaker: false, spent: 7.5, budget: 20, due: 2, leads: 3, ideas: 5,
  cooks: { claude: { status: 'ready' }, gemini: { status: 'resting' }, local: { status: 'off' }, antigravity: { status: 'busy' } } });
export const fullEvents = () => [{ type: 'approval.requested', job: 'J71', approval: 'A7', ts: ago(70) }, { type: 'approval.requested', job: 'J72', approval: 'A8', ts: ago(250) },
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
export const rec = []; export const rkit = makeKit(P, (w, h) => { const c = mk(w, h), g = c.getContext; c.getContext = () => { const x = g(); const di = x.drawImage; x.drawImage = (img, ...a) => { if (img?._name) rec.push(img._name + ':' + (a.length === 8 ? a[0] / a[2] : 0)); return di(img, ...a); }; return x; }; return c; });
const rget = rkit.get; rkit.get = (name, o, f) => { const v = rget.call(rkit, name, o, f); v.img._name = name; return v; };
export const drawnW = (s, ev = [], opts = {}) => { rec.length = 0; rkit.layers.clear(); const st = stageNew(); stageSync(st, layoutScene(s, ev, {}, T0), opts); drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), st, rkit); return [...rec]; };
const WORLD_SPRITES = ['sign', 'clock', 'clock-min', 'clock-hour', 'coin-jar', 'jar-lock', 'stool', 'chair-up', 'chef-sit', 'fuse', 'lamp-off', 'heat', 'cork', 'letter', 'hooks', 'hat', 'chalk', 'tally', 'chalk-digit', 'recipes', 'aside-shelf', 'plate-aside', 'smoke', 'tag', 'plus'];
export const bare = drawnW({ jobs: [job('J1')] });
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
