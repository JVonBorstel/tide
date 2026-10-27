// Tests for the scene's Purpose Ledger (public/purpose.js): every drawn thing has a row bound to a real field and event, doors, flips;
// no kitchen word on screen; the site chrome; the stage bytes budget. Run by pass-app/test-scene.mjs, last.
import fs from 'node:fs';
import { layoutScene, STAGE, stageNew, stageSync, stageTick, drawStage, hitItems, hitHtml } from './public/scene.js';
import { legendRows, legendHtml } from './public/world.js';
import { PURPOSE } from './public/purpose.js';
import { kitchenHits } from './site-words.mjs';
import zlib from 'node:zlib';
import * as P from './public/sprites.js';
import { MOMENTS } from './public/moments.js';
import { busy, check, job, mk, out } from './test-scene-stage.mjs';
import { T0, ago, drawnW, fullEvents, fullState, iso, rec, rkit } from './test-scene-world.mjs';
import { KITCHEN_WORDS, drawnAt, hoistOf, needsOne } from './test-scene-moments.mjs';

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
export const mEv = [fresh({ type: 'step.done', job: 'J40', step: 3 }), fresh({ type: 'step.rework', job: 'J41', step: 3 }), fresh({ type: 'job.quarantined', job: 'J74' }), fresh({ type: 'approval.requested', job: 'J71', approval: 'A7' }), fresh({ type: 'job.done', job: 'J39' }), fresh({ type: 'step.crash', job: 'J42', step: 3 })];
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
