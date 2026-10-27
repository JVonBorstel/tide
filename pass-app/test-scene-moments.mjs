// Tests for the scene's moments and juice (public/moments.js, wave 2), the crew spacing and bubbles, the site art (renames S7c-S7i)
// and the words around the scene (S7g, the critic's MUST items). Run by pass-app/test-scene.mjs, after the stage and world tests.
import fs from 'node:fs';
import { layoutScene, sceneHtml, stationFor, STATIONS, STAGE, stageNew, stageSync, stageTick, drawStage, hitItems, hitHtml, stepWord,
  writeHits, dropStage } from './public/scene.js';
import { worldOf, legendRows, PLACE, HANG, bakeWorld } from './public/world.js';
import * as P from './public/sprites.js';
import { MOMENTS, FX, momentsFrom, fxNew, spawn, easeOutBack, easeInOutCubic, chefPose, passFx, approveFx, tapChef, fxBusy, spread,
  propRects } from './public/moments.js';
import { busy, check, job, kit, lum, mk, ratio } from './test-scene-stage.mjs';
import { T0, bare, drawnW, fullEvents, fullJobs, fullState, rec, rkit } from './test-scene-world.mjs';

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
export const hoistOf = (key) => { const st = stageNew(); stageSync(st, layoutScene({ jobs: [] }, [], {}, T0)); if (key) stageSync(st, layoutScene({ jobs: [job(key, { role: 'plan' })] }, [], {}, T0)); rec.length = 0; drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), st, rkit); return [...rec]; };
const cageArt = one1('door'), cageOpen = one1('hoist-open');
check('SiteHoist: the crews arrive by the hoist: a steel mesh cage between hazard bands (no wooden door); its gate stands open with the call lamp lit only while a crew is arriving',
  !/[bcde]/.test(cageArt.join('')) && /H/.test(cageArt[1]) && /H/.test(cageArt[27]) && /t/.test(cageOpen[0]) && !/t/.test(cageArt.join(''))
  && hoistOf('J61').includes('hoist-open:0') && !hoistOf(null).includes('hoist-open:0'));
check('SiteCut: the paint tins, the pegboards, their shelf and the window frame are gone (no data: decoration, P8); the bake draws none of them',
  ['jar', 'pan', 'shelf', 'window'].every((k) => !P.SPRITES[k] && !bare.some((r) => r.startsWith(k + ':'))) && !('jars' in P.FRAMES));
export const cabin = one1('pass'), glow = one1('pass-glow').join(''), needsOne = { jobs: [job('J80', { status: 'waiting-approval', approval: { id: 'A80' } })] };
check('SiteCabin: the sign-off window is the site cabin: corrugated steel, a framed window of dark glass that glows amber only while a sign-off waits',
  cabin.slice(4, 26).every((r) => /^a[gh]{2}/.test(r)) && !/[DEFIt]/.test(cabin.join('')) && /N/.test(cabin.slice(5, 24).join(''))
  && (glow.match(/[ts]/g) || []).length > glow.length * 0.8 && !drawnW({ jobs: [] }).includes('pass-glow:0') && drawnW(needsOne).includes('pass-glow:0'));
export const NIGHT = new Date(2026, 9, 22, 23, 0).getTime(), drawnAt = (s, now) => { rec.length = 0; rkit.layers.clear(); const st = stageNew(); stageSync(st, layoutScene(s, [], {}, now), {}); drawStage(rkit.mk(STAGE.w, STAGE.h).getContext(), st, rkit); return [...rec]; };
check('SiteDepth: a contact shadow under each station (2 each), a darker strip along the slab\'s front edge, and a warm pool under the work light only on a night shift (crews at work after dark with the light on: none idle, by day, with the light out or without its field)',
  bare.filter((r) => r === 'shadow:0').length >= 10 && bare.filter((r) => r === 'edge:0').length >= 12 && /I/.test(one1('pool').join('')) && /I/.test(P.EMISSIVE)
  && drawnAt({ jobs: [job('J1')], breaker: false }, NIGHT).includes('pool:0') && !drawnAt({ jobs: [], breaker: false }, NIGHT).includes('pool:0') && !drawnAt({ jobs: [job('J1')], breaker: false }, T0).includes('pool:0')
  && !drawnAt({ jobs: [job('J1')], breaker: true }, NIGHT).includes('pool:0') && !drawnAt({ jobs: [job('J1')] }, NIGHT).includes('pool:0'));
// the words around the scene (rename S7g): nothing a person reads or hears from the scene is a kitchen word any more
export const KITCHEN_WORDS = /\b(toques?|cloches?|chefs?|order up|kitchen|cooks?|cooking|stove|sink|plates?|tickets?|rail|waiters?|sous|pass|coin jar|chalkboard|cork board|recipes?|fuse box|heat lamps?|hatch|window sign|closed)\b/i;
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
