// Screen tests of the Board home's status line (pass-app/public/app.js renderBanners, index.html #status-line and #notice-sheet, app.css):
// notices are small chips under the header, a tap opens the full text and its action in a sheet, only a broken thing keeps a full-width red
// bar, push alerts that are off by choice say nothing on the home, and the City gets the freed space (full width, every name whole).
// Each check is named after an acceptance line. Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it.
//   node pass-app/test-status-line.mjs [--shots <folder>] [--label before|after]
// It drives the real Board server (a throwaway state folder from pass-app/speed/fixture.mjs, made-up work orders only) in headless Chrome or
// Edge over the DevTools protocol (Node's own WebSocket; no package). The City's /api/towers answer is replaced in the browser by a synthetic
// one (made-up project names, long on purpose); nothing else is faked. No live state folder, no network beyond 127.0.0.1.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path';
import { makeYard } from './speed/fixture.mjs';
import { boardPage } from './test-browser-kit.mjs';
import { noticeKey, markNotices, keysOf, steady } from './public/notices.js';

const argOf = (n) => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : ''; };
const shotsDir = argOf('shots') ? path.resolve(argOf('shots')) : ''; const label = argOf('label') || 'after';
const out = [];
const check = (name, pass, detail = '') => out.push({ name: detail && !pass ? `${name} (${String(detail).slice(0, 400)})` : name, pass: !!pass });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const iso = (ms) => new Date(ms).toISOString();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'status-line-test-'));
const root = makeYard(tmp, 'calm');

// ---- the state folder's notices, one scene at a time (the files the Yard's own scripts write) ----
const put = (f, v) => fs.writeFileSync(path.join(root, f), typeof v === 'string' ? v : JSON.stringify(v));
const drop = (f) => fs.rmSync(path.join(root, f), { recursive: true, force: true });
function scene(name, now = Date.now()) {
  for (const f of ['automerge-paused.json', 'freeze.json', 'alerts.jsonl', 'PAUSED', 'PAUSED-GW', 'kitchen.json', 'ci-budget.json', 'main-status', 'LIVE', 'push-on', 'ntfy-topic.txt']) drop(f);
  put('supervisor.json', { lastTick: iso(now - 20e3) });
  put('LIVE', 'on (test)');
  // phone alerts off by choice, with three that did not reach the phone: never said on the home (D-10)
  put('alerts.jsonl', [1, 2, 3].map((i) => JSON.stringify({ ts: iso(now - i * 600e3), level: 'INFO', text: 'example alert ' + i, sent: 'off' })).join('\n') + '\n');
  if (name === 'quiet') return;
  // four notices at once: auto-merge paused, supervisor quiet, a site closed, phone alerts off
  put('automerge-paused.json', { until: iso(now + 3 * 3600e3), since: iso(now - 600e3), flaky: 2, suites: ['Test-Example'] });
  put('freeze.json', { at: iso(now), repos: [{ name: 'example-tower', windows: [{ from: iso(now - 3600e3), to: iso(now + 86400e3), why: 'release week', fromText: 'Mon 9:00', toText: 'Tue 9:00' }] }], errors: [] });
  put('supervisor.json', { lastTick: iso(now - 200e3) });
  if (name === 'down') put('supervisor.json', { lastTick: iso(now - 1500e3) });   // the supervisor stopped: 25 min without a pass
  if (name === 'many') {   // every calm and warn notice at once: a Site stopped by you, its CI over budget, AI crews off, a window ahead
    drop('LIVE'); put('PAUSED-GW', 'test'); put('kitchen.json', { sites: { GW: { name: 'Example site' } } });
    const month = new Date().toISOString().slice(0, 7);
    put('ci-budget.json', { month, at: iso(now), monthEnds: iso(now + 5 * 86400e3), poolLimit: 2000, pool: { state: 'ok', minutesAtLeast: 300 },
      sites: [{ code: 'GW', state: 'ok', runs: 40, minutes: 450, minutesAtLeast: 450, budget: 400, over: true }], problems: [] });
    put('freeze.json', { at: iso(now), repos: [{ name: 'example-tower', windows: [{ from: iso(now + 86400e3), to: iso(now + 2 * 86400e3), why: 'audit', fromText: 'Wed 9:00', toText: 'Thu 9:00' }] }], errors: [] });
  }
}

// ---- the City's answer, synthetic: made-up projects with long names (names this long used to end in an ellipsis) ----
const floors = (n, now) => Array.from({ length: n }, (_, i) => ({ pr: i + 1, at: iso(now - (n - i) * 3 * 3600e3), by: 'session' }));
function towers(now = Date.now()) {
  const T = (key, name, kind, n, extra = {}) => ({ key, name, kind, floors: kind === 'tower' ? floors(n, now) : [], open: [], ...extra });
  return { ok: true, v: 'synthetic001', at: iso(now), githubAt: iso(now), towers: [
    T('private', 'Private project', 'tower', 40, { private: true }), T('private-2', 'Private project 2', 'tower', 12, { private: true }),
    T('sample-agent-stage', 'sample-agent-stage', 'tower', 25), T('tide', 'tide', 'tower', 60),
    T('reporting-service-demo', 'reporting-service-demo', 'lot', 0), T('notes-archive-sample', 'notes-archive-sample', 'office', 0, { lastCommit: iso(now - 3600e3) })] };
}

// ---- public/notices.js on its own (pure): the keys a clear is kept under ----
{
  const q = (min) => ({ tone: 'warn', chip: 'Supervisor quiet', text: `Supervisor quiet for ${min} min.` });
  const bar = { tone: 'broken', chip: 'The Yard stopped', text: 'The Yard stopped ticking 25 min ago.' };
  check('NoticeKey_ClockIsNotAChange: "quiet for 3 min" and "quiet for 4 min" share a key; new words, a new tone or another chip do not',
    noticeKey(q(3)) === noticeKey(q(4)) && noticeKey(q(3)) !== noticeKey({ ...q(3), text: 'Supervisor quiet: the PC slept.' }) && noticeKey(q(3)) !== noticeKey({ ...q(3), tone: 'calm' })
      && noticeKey(q(3)) !== noticeKey({ ...q(3), chip: 'Site closed' }) && steady('Main is red since Fri 1:14 PM (3.5 h).') === 'Main is red since Fri 1:14 PM (#).');
  const m = markNotices([q(3), bar], new Set([noticeKey(q(3)), noticeKey(bar)]), new Set([noticeKey(bar)]));
  check('NoticeKey_RedBarNeverCleared: a broken notice is never marked cleared, even with its key in the cleared list; it can be thin',
    m[0].cleared && !m[0].thin && !m[1].cleared && m[1].thin && m[1].id === 'bar:The Yard stopped');
  const many = keysOf(Array.from({ length: 70 }, (_, i) => 'k' + i));
  check('NoticeKey_MemoryBounded: the kept list holds the newest 60 keys; a bad stored value is no memory',
    many.length === 60 && many[59] === 'k69' && many[0] === 'k10' && keysOf('x').length === 0 && keysOf([1, 'a', null]).join() === 'a');
}

// ---- the real Board server and its page in headless Chrome / Edge (pass-app/test-browser-kit.mjs boardPage) ----
let page = null;

try {
  page = await boardPage({ root, tmp, towers, shotsDir }); const { send, ev, until, phone, open, shot, server } = page; const cdp = page.cdp;
  // what the home shows: banner cards (the old look), red bars, chips, and the words anywhere on the home
  const home = () => ev(`(() => { const vis = (el) => !!el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden';
    const bars = [...document.querySelectorAll('#banners .redbar')].filter(vis);
    return { cards: [...document.querySelectorAll('.banner')].filter(vis).length, bars: bars.length, barText: bars.map((b) => b.textContent.trim()),
      barBox: bars.map((b) => { const r = b.getBoundingClientRect(); return [Math.round(r.left), Math.round(r.width)]; }), barTone: bars.map((b) => getComputedStyle(b).backgroundColor),
      chips: [...document.querySelectorAll('#status-line .notice-chip')].filter(vis).map((c) => ({ words: c.textContent.trim(), tone: c.dataset.tone, h: Math.round(c.getBoundingClientRect().height) })),
      text: document.body.innerText, vw: innerWidth, sw: document.documentElement.scrollWidth, bw: document.body.scrollWidth }; })()`);

  // ---------- before/after screenshots at 412 px: the phone's four notices, dark, by day and at night ----------
  scene('jordan'); await phone(412, 900); await open();
  await shot(`home-412-dark-${label}.png`);
  if (shotsDir) fs.writeFileSync(path.join(shotsDir, `measure-${label}.json`), JSON.stringify(await ev(`(() => { const c = document.getElementById('city').getBoundingClientRect(); const cv = document.querySelector('#city canvas').getBoundingClientRect(); return { cityTop: Math.round(c.top), canvasW: Math.round(cv.width), canvasH: Math.round(cv.height), cards: document.querySelectorAll('.banner').length, clipped: [...document.querySelectorAll('#city-names b')].filter((b) => b.scrollWidth > b.clientWidth).length }; })()`)));
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }, { name: 'prefers-reduced-motion', value: 'reduce' }] }); await sleep(300);
  await shot(`home-412-light-${label}.png`);
  await phone(412, 900, { hour: 23 }); await open(); await shot(`home-412-night-${label}.png`);
  if (label === 'before') { cdp.close(); throw null; }

  // ---------- home at 412x900 shows 0 banner cards when nothing is broken ----------
  await phone(412, 900); await open();
  const j = await home();
  check('Home412_NoBannerCards: home at 412x900 shows 0 banner cards when nothing is broken (paused merges, a closed site, a quiet supervisor and alerts off are chips or nothing)',
    j.cards === 0 && j.bars === 0 && j.chips.length === 3, JSON.stringify({ cards: j.cards, bars: j.bars, chips: j.chips }));
  check('Home412_ChipsAreSmall: each chip is one short line (icon + 2-4 words, 24-28 px tall, so the line stays within 32 px: D-12)',
    j.chips.length > 0 && j.chips.every((c) => c.words.split(/\s+/).length >= 2 && c.words.split(/\s+/).length <= 4 && c.h >= 24 && c.h <= 28), JSON.stringify(j.chips));
  check('Home412_ChipWords: the chips say Auto-merge paused, Site closed and Supervisor quiet, in the order the notices come',
    j.chips.map((c) => c.words).join('|') === 'Auto-merge paused|Supervisor quiet|Site closed', j.chips.map((c) => c.words).join('|'));

  // ---------- speed budget (pass-app/speed/budget.json) not worse: CI's speed job measures it; here, the parts this change can cost ----------
  const sp = await ev(`(() => { const els = [...document.querySelectorAll('#status-line .notice-chip, #banners .redbar')]; return { canvases: document.querySelectorAll('canvas').length, cityCanvases: document.querySelectorAll('#city canvas').length, moving: els.filter((e) => getComputedStyle(e).animationName !== 'none' || e.getAnimations().length).length, nodes: document.querySelectorAll('#status-line *, #banners *').length }; })()`);
  check('SpeedBudget_NotWorse: the status line adds no canvas, no animation and no frame loop (one City canvas; no animation runs on a chip or bar at rest; a few nodes)', sp.cityCanvases === 1 && sp.moving === 0 && sp.nodes <= 14, JSON.stringify(sp));

  // ---------- each current notice appears as a chip with its full text one tap away ----------
  const full = [
    { words: 'Auto-merge paused', text: /^Auto-merge paused until .+ after 2 flaky checks: Test-Example\. Each passed on main only on a retry, so AI changes wait for your sign-off until then\.$/, act: null },
    { words: 'Supervisor quiet', text: /^Supervisor quiet for \d+ min\.$/, act: 'tick' },
    { words: 'Site closed', text: /^Site closed: example-tower takes no merges until Tue 9:00: release week\. Building, testing and pull requests go on\.$/, act: null }];
  for (const [i, f] of full.entries()) {
    await ev(`document.querySelectorAll('#status-line .notice-chip')[${i}].click()`);
    const opened = await until(`document.getElementById('notice-sheet').open`, 3000);
    const s = await ev(`({ title: document.getElementById('notice-title').textContent, text: document.querySelector('#notice-body .notice-text')?.textContent || '', act: document.querySelector('#notice-body [data-set]')?.dataset.set || null, focus: document.activeElement?.closest('#notice-sheet') ? 1 : 0 })`);
    check(`Chip_FullTextOneTap: "${f.words}" opens its full text${f.act ? ' and its action (' + f.act + ')' : ''} in a sheet with one tap`, opened && s.title === f.words && f.text.test(s.text) && s.act === f.act, JSON.stringify(s));
    await ev(`document.querySelector('#notice-sheet [data-close]').click()`); await until(`!document.getElementById('notice-sheet').open`, 3000);
  }
  // the action in the sheet is the notice's own: Run now runs the supervisor (an audited act) and closes the sheet
  await ev(`document.querySelectorAll('#status-line .notice-chip')[1].click()`); await until(`document.getElementById('notice-sheet').open`, 3000);
  await ev(`document.querySelector('#notice-body [data-set="tick"]').click()`);
  const closed = await until(`!document.getElementById('notice-sheet').open`, 3000);
  const tickAt = () => { try { return Date.parse(JSON.parse(fs.readFileSync(path.join(root, 'supervisor.json'), 'utf8')).lastTick) || 0; } catch { return 0; } };
  let ran = false; for (let i = 0; i < 300 && !ran; i++) { ran = Date.now() - tickAt() < 120e3; if (!ran) await sleep(200); }   // the pass itself runs a few seconds; wait so it cannot land in a later scene
  // and let the whole pass finish (it also rewrites freeze.json): the state folder's files still for 5 s, at most 60 s
  const sig = () => fs.readdirSync(root).map((f) => { try { return f + fs.statSync(path.join(root, f)).mtimeMs; } catch { return f; } }).join('|');
  for (let i = 0, last = sig(), still = 0; i < 300 && still < 25; i++) { await sleep(200); const now = sig(); still = now === last ? still + 1 : 0; last = now; }
  check('Chip_ActionWorks: Run now in the sheet is the same tap as before (the sheet closes and the supervisor makes a pass)', closed && ran, JSON.stringify({ closed, ran, lastTick: new Date(tickAt()).toISOString() }));
  // every notice is a chip: the "many" scene (a Site stopped by you, its CI over budget, the month's CI count, AI crews off, a window ahead)
  scene('many'); await open();
  const m = await home();
  const mWords = m.chips.map((c) => c.words);
  check('Chip_EveryNotice: every calm or warn notice is a chip, none dropped (auto-merge, quiet supervisor, Site stopped, closing ahead, CI over, CI count, AI crews off)',
    m.cards === 0 && m.bars === 0 && ['Auto-merge paused', 'Supervisor quiet', 'Site GW stopped', 'Site closing ahead', 'CI budget over', 'CI this month', 'AI crews off'].every((w) => mWords.includes(w)) && m.chips.length === 7, JSON.stringify(mWords));
  check('Chip_Tone: a limit that holds work (CI over budget, a quiet supervisor) is a warn chip; the rest are calm', m.chips.filter((c) => c.tone === 'warn').map((c) => c.words).sort().join('|') === 'CI budget over|Supervisor quiet', JSON.stringify(m.chips));
  await ev(`[...document.querySelectorAll('#status-line .notice-chip')].find((c) => c.textContent.trim() === 'Site GW stopped').click()`); await until(`document.getElementById('notice-sheet').open`, 3000);
  const gw = await ev(`({ text: document.querySelector('#notice-body .notice-text')?.textContent || '', act: document.querySelector('#notice-body [data-set]')?.dataset.set || null, site: document.querySelector('#notice-body [data-set]')?.dataset.site || null })`);
  check('Chip_FullTextOneTap: "Site GW stopped" opens its full text and its Resume GW action', /^Site GW stopped by you: none of its new work starts\./.test(gw.text) && gw.act === 'site-resume' && gw.site === 'GW', JSON.stringify(gw));
  await ev(`document.querySelector('#notice-sheet [data-close]').click()`); await until(`!document.getElementById('notice-sheet').open`, 3000);
  await phone(360, 800); await open();
  const m360 = await home();
  check('NoHScroll360_ManyChips: no horizontal page scroll at 360 px with seven chips (they scroll sideways inside the one-row line, D-12)', m360.sw <= m360.vw && m360.bw <= m360.vw && m360.chips.length === 7, JSON.stringify({ vw: m360.vw, sw: m360.sw, bw: m360.bw, chips: m360.chips.map((x) => x.words) }));
  await shot('home-360-many-chips.png');

  // ---------- a broken supervisor shows one red bar ----------
  scene('down'); await phone(412, 900); await open();
  const d = await home();
  check('BrokenSupervisor_OneRedBar: a broken supervisor (no pass for 25 min) shows one full-width red bar with Run now; the rest stay chips',
    d.bars === 1 && d.cards === 0 && /^The Yard stopped ticking .+ ago\./.test(d.barText[0] || '') && d.barBox[0]?.[0] === 0 && d.barBox[0]?.[1] === d.vw && d.chips.length === 2
      && await ev(`!!document.querySelector('#banners .redbar [data-set="tick"]')`), JSON.stringify({ bars: d.barText, box: d.barBox, chips: d.chips }));
  check('BrokenSupervisor_RedTone: the bar is the fault colour, not a card', d.barTone[0] && d.barTone[0] !== 'rgba(0, 0, 0, 0)' && await ev(`(() => { const c = getComputedStyle(document.querySelector('#banners .redbar')); return c.borderRadius === '0px' && c.boxShadow === 'none'; })()`), JSON.stringify(d.barTone));
  await shot('home-412-broken-supervisor.png');
  // a failed deploy (a Tower's main is red) is broken too: its own red bar
  scene('jordan'); fs.mkdirSync(path.join(root, 'main-status'), { recursive: true }); put('main-status/0123456789ab.json', { tower: 'example-tower', state: 'red', since: iso(Date.now() - 3600e3), suites: ['Test-Example'], why: 'example failure', sha: 'a'.repeat(40), job: '' });
  await open();
  const r = await home();
  check('BrokenMain_OneRedBar: a red main (a failed deploy) is one red bar; paused merges and the closed site stay chips', r.bars === 1 && /^Main is red: example-tower/.test(r.barText[0] || '') && r.chips.length === 3, JSON.stringify({ bars: r.barText, chips: r.chips }));
  drop('main-status');

  // ---------- push-off shows nothing on home ----------
  scene('quiet'); await open();
  const q = await home();
  check('PushOff_NothingOnHome: phone alerts off by choice (3 not sent) show no banner, bar or chip on the home', q.cards === 0 && q.bars === 0 && q.chips.length === 0 && !/Phone alerts are off|not sent/i.test(q.text) && await ev(`document.getElementById('status-line').hidden`), JSON.stringify({ chips: q.chips, hit: (q.text.match(/.{0,40}(Phone alerts are off|not sent).{0,40}/i) || [''])[0] }));
  for (const v of ['activity', 'ledger', 'world', 'cooks']) { await open('#/' + v); }
  check('PushOff_NothingOnAnyTab: no other tab says it either (it was on every view)', !/Phone alerts are off/.test(await ev('document.body.innerText')), '');
  await open(); await ev(`document.getElementById('menu-btn').click()`); await until(`/Push alerts/.test(document.getElementById('menu-body').textContent)`, 4000);
  const set = await ev(`document.getElementById('menu-body').textContent.replace(/\\s+/g, ' ')`);
  check('PushOff_InSettings: Settings still says push alerts are off and how many alerts did not reach the phone', /Push alerts\s*Off\./.test(set) && /3 alerts since .+ were not sent/.test(set), set.slice(0, 300));
  await ev(`document.querySelector('#menu-sheet [data-close]').click()`); await sleep(300);

  // ---------- the City gets the space back ----------
  scene('jordan'); await phone(412, 900); await open();
  const c412 = await ev(`(() => { const c = document.getElementById('city').getBoundingClientRect(); const cv = document.querySelector('#city canvas').getBoundingClientRect(); return { left: c.left, width: c.width, top: c.top, cvw: cv.width, cvh: cv.height, vw: innerWidth }; })()`);
  check('City_FullWidth: at 412 px the City is edge to edge and its picture fills the width (no side gutters)', c412.left === 0 && c412.width === c412.vw && c412.cvw >= c412.vw - 4, JSON.stringify(c412));
  check('City_Higher: with the notices as chips the City starts in the top 200 px (below the four banner cards it started past the middle)', c412.top <= 200, JSON.stringify(c412));
  check('City_Taller: the City picture is at least 200 px tall at 412 px (full width gives the pixels a bigger whole-number scale)', c412.cvh >= 200, JSON.stringify(c412));
  for (const w of [360, 412]) {
    await phone(w, 800); await open();
    const lab = await ev(`[...document.querySelectorAll('#city-names b')].map((b) => { const r = b.getBoundingClientRect(); return { t: b.textContent, sw: b.scrollWidth, cw: b.clientWidth, right: r.right, lines: Math.round(r.height / parseFloat(getComputedStyle(b).lineHeight)) }; })`);
    const names = towers().towers.map((t) => t.name);
    check(`TowerLabels${w}_NoEllipsis: no tower label ends in an ellipsis at ${w} px (every name whole, inside the screen)`,
      lab.length === names.length && lab.every((l, i) => l.t === names[i] && !/(…|\.\.\.)$/.test(l.t) && l.sw <= l.cw + 1 && l.right <= w), JSON.stringify(lab));
    const sc = await ev(`({ vw: innerWidth, sw: document.documentElement.scrollWidth, bw: document.body.scrollWidth })`);
    check(`NoHScroll${w}: no horizontal scroll at ${w} px on the home`, sc.sw <= sc.vw && sc.bw <= sc.vw, JSON.stringify(sc));
    if (w === 360) await shot('home-360-dark.png');
  }

  // ---------- Look A by day, B lighting at night (D-3) ----------
  await phone(412, 900, { hour: 13 }); await open();
  const day = await ev(`({ sky: document.getElementById('city').dataset.sky, glow: getComputedStyle(document.querySelector('#city canvas')).filter })`);
  await phone(412, 900, { hour: 23 }); await open();
  const night = await ev(`({ sky: document.getElementById('city').dataset.sky, glow: getComputedStyle(document.querySelector('#city canvas')).filter })`);
  check('City_LookAByDay_BAtNight: the City frame follows the City\'s own sky: day is Look A (plain crisp pixels), night lights it (B)', day.sky === 'day' && day.glow === 'none' && night.sky === 'night' && night.glow !== 'none', JSON.stringify({ day, night }));

  // ---------- D-12: the line is one row and clearable; a cleared notice stays hidden until it changes; red bars only shrink ----------
  const line = () => ev(`(() => { const l = document.getElementById('status-line'); const r = l.getBoundingClientRect(); const chips = [...l.querySelectorAll('.notice-chip, .clear-all')];
    return { hidden: l.hidden, h: Math.round(r.height * 10) / 10, rows: new Set(chips.map((c) => Math.round(c.getBoundingClientRect().top))).size, chips: [...l.querySelectorAll('.notice-chip')].map((c) => c.textContent.trim()),
      clearAll: !!l.querySelector('[data-clear-all]'), wraps: l.scrollHeight > l.clientHeight + 1, vw: innerWidth, sw: document.documentElement.scrollWidth, bw: document.body.scrollWidth,
      badge: document.getElementById('notices-btn').hidden ? null : document.getElementById('count-notices').textContent, cityTop: Math.round(document.getElementById('city').getBoundingClientRect().top) }; })()`);
  const fresh = async () => { await ev('localStorage.clear()'); await open(); };
  const tapChip = async (words) => { await ev(`[...document.querySelectorAll('#status-line .notice-chip')].find((c) => c.textContent.trim() === ${JSON.stringify(words)}).click()`); return until(`document.getElementById('notice-sheet').open`, 3000); };
  const clearInSheet = () => ev(`document.querySelector('#notice-body [data-clear-notice]').click()`);
  scene('jordan');
  for (const [w, h] of [[412, 900], [360, 740]]) {
    await phone(w, h); await fresh(); const l = await line();
    check(`OneRow${w}x${h}_ThreeNotices: with 3 notices at ${w}x${h} the line is one row, at most 32 px tall, no horizontal page scroll`,
      !l.hidden && l.chips.length === 3 && l.clearAll && l.rows === 1 && !l.wraps && l.h > 0 && l.h <= 32 && l.sw <= l.vw && l.bw <= l.vw, JSON.stringify(l));
  }
  await phone(412, 900); await fresh(); const top0 = (await line()).cityTop;
  // clearing one hides it and survives a reload (localStorage); the header count says 1
  await tapChip('Site closed');
  const sheetClear = await ev(`!!document.querySelector('#notice-body [data-clear-notice]')`);
  await shot(`notice-sheet-412-dark-${label}.png`);
  await clearInSheet(); await until(`![...document.querySelectorAll('#status-line .notice-chip')].some((c) => /Site closed/.test(c.textContent))`, 3000);
  await open(); const c1 = await line();
  check('ClearOne_SurvivesReload: Clear in a chip\'s sheet hides it, it stays hidden after a reload, and the header count says 1',
    sheetClear && c1.chips.join('|') === 'Auto-merge paused|Supervisor quiet' && c1.badge === '1', JSON.stringify(c1));
  // a clock that ticks is not a change: the supervisor quiet one more minute stays cleared
  await tapChip('Supervisor quiet'); await clearInSheet(); await until(`document.querySelectorAll('#status-line .notice-chip').length === 1`, 3000);
  put('supervisor.json', { lastTick: iso(Date.now() - 290e3) }); await sleep(2500);
  const tick = await line();
  check('TickingClock_StaysCleared: a cleared notice whose only change is its clock (quiet for 3 min, then 4) stays hidden', tick.chips.join('|') === 'Auto-merge paused' && tick.badge === '2', JSON.stringify(tick));
  // a changed notice reappears: the closed site gives a new reason
  const fz = JSON.parse(fs.readFileSync(path.join(root, 'freeze.json'), 'utf8')); fz.repos[0].windows[0].why = 'release week, extended'; put('freeze.json', fz);
  const back = await until(`[...document.querySelectorAll('#status-line .notice-chip')].some((c) => c.textContent.trim() === 'Site closed')`, 15000);
  check('ChangedNotice_Reappears: when a cleared notice changes (the closed site gives a new reason) its chip shows again', back && (await line()).badge === '1', JSON.stringify(await line()));
  // a swipe up on a chip clears it
  await ev(`(() => { const c = document.querySelector('#status-line .notice-chip'); const r = c.getBoundingClientRect(); const x = r.left + 20, y = r.top + 10;
    const p = (t, yy) => c.dispatchEvent(new PointerEvent(t, { bubbles: true, pointerId: 7, pointerType: 'touch', clientX: x, clientY: yy, isPrimary: true }));
    p('pointerdown', y); p('pointermove', y - 12); p('pointermove', y - 40); p('pointerup', y - 40); })()`);
  const swiped = await until(`![...document.querySelectorAll('#status-line .notice-chip')].some((c) => c.textContent.trim() === 'Auto-merge paused')`, 3000);
  check('SwipeUp_ClearsChip: a swipe up on a chip clears it (sideways stays the line\'s own scroll)', swiped && (await line()).badge === '2', JSON.stringify(await line()));
  // Clear all: the line folds to 0 px, smoothly (sampled every frame: the City moves up step by step, never one jump); the count says 3
  await phone(412, 900, { motion: true }); await fresh();
  const fold = await ev(`new Promise((ok) => { const city = document.getElementById('city'), l = document.getElementById('status-line'); const tops = [], hs = [];
    document.querySelector('#status-line [data-clear-all]').click(); const t0 = performance.now();
    const f = () => { tops.push(Math.round(city.getBoundingClientRect().top * 10) / 10); hs.push(Math.round(l.getBoundingClientRect().height * 10) / 10); if (performance.now() - t0 < 500) requestAnimationFrame(f); else ok({ tops, hs }); }; requestAnimationFrame(f); })`);
  const ca = await line(); const mid = fold.hs.filter((x) => x > 0.5 && x < 31.5).length; const mono = fold.tops.every((t, i) => i === 0 || t <= fold.tops[i - 1] + 0.5);
  check('ClearAll_LineGone_BadgeCount: Clear all leaves the line at 0 px and the header count shows 3', ca.hidden && ca.h === 0 && ca.chips.length === 0 && ca.badge === '3', JSON.stringify(ca));
  check('Clear_Animates_NoJump: the line folds over several frames and the City moves up with it, never down and never in one jump (D-6)', mid >= 2 && mono && ca.cityTop < top0, JSON.stringify({ fold, top0, cityTop: ca.cityTop }));
  await phone(412, 900); await sleep(200); await shot(`home-412-dark-${label}-cleared.png`);
  // the header count's sheet lists every current notice with its actions; Restore brings one back, Restore all the rest
  await ev(`document.getElementById('notices-btn').click()`); const listed = await until(`document.getElementById('notices-sheet').open`, 3000);
  const ls = await ev(`[...document.querySelectorAll('#notices-body .notice-item')].map((li) => ({ chip: li.querySelector('b').textContent, state: li.querySelector('.ni-state').textContent, restore: !!li.querySelector('[data-restore]'), act: [...li.querySelectorAll('[data-set]')].map((b) => b.dataset.set) }))`);
  await sleep(300); await shot(`notices-sheet-412-dark-${label}.png`);
  await ev(`[...document.querySelectorAll('#notices-body .notice-item')].find((li) => li.querySelector('b').textContent === 'Supervisor quiet').querySelector('[data-restore]').click()`);
  const one = await until(`[...document.querySelectorAll('#status-line .notice-chip')].map((c) => c.textContent.trim()).join('|') === 'Supervisor quiet'`, 3000);
  await ev(`document.querySelector('#notices-body [data-restore-all]').click()`);
  const all = await until(`document.querySelectorAll('#status-line .notice-chip').length === 3 && document.getElementById('notices-btn').hidden`, 3000);
  check('BadgeSheet_ListsAndRestores: one tap on the count lists all 3 notices (cleared, with their actions: Run now); Restore brings one back, Restore all the rest and the count goes',
    listed && ls.length === 3 && ls.every((x) => x.state === 'Cleared' && x.restore) && !!ls.find((x) => x.chip === 'Supervisor quiet')?.act.includes('tick') && one && all, JSON.stringify(ls));
  await ev(`document.querySelector('#notices-sheet [data-close]').click()`); await until(`!document.getElementById('notices-sheet').open`, 3000);
  // a broken supervisor bar cannot be cleared, but shrinks to one thin line (<= 28 px) with the full text one tap away
  scene('down'); await fresh();
  await ev(`document.querySelector('#status-line [data-clear-all]').click()`); await sleep(300);
  const kept = await home();
  await ev(`document.querySelector('#banners [data-thin]').click()`); await sleep(200);
  const thin = await ev(`(() => { const b = document.querySelector('#banners .redbar'); const r = b.getBoundingClientRect(); return { thin: b.classList.contains('thin'), h: r.height, w: r.width, text: b.textContent.trim() }; })()`);
  await shot(`home-412-dark-${label}-thin-bar.png`);
  await ev(`document.querySelector('#banners .redbar.thin').click()`); const opened = await until(`document.getElementById('notice-sheet').open`, 3000);
  const bs = await ev(`({ text: document.querySelector('#notice-body .notice-text')?.textContent || '', act: document.querySelector('#notice-body [data-set]')?.dataset.set || null, clear: !!document.querySelector('#notice-body [data-clear-notice]') })`);
  await ev(`document.querySelector('#notice-sheet [data-close]').click()`); await until(`!document.getElementById('notice-sheet').open`, 3000);
  await open(); const thinAgain = await ev(`!!document.querySelector('#banners .redbar.thin')`);
  check('BrokenBar_NotClearable_ShrinksTo28: a broken supervisor bar survives Clear all, has no Clear, and shrinks to one line of at most 28 px whose tap opens the full text and Run now (kept after a reload)',
    kept.bars === 1 && kept.chips.length === 0 && thin.thin && thin.h > 0 && thin.h <= 28 && /^The Yard stopped ticking/.test(thin.text) && opened && /^The Yard stopped ticking .+ ago\./.test(bs.text) && bs.act === 'tick' && !bs.clear && thinAgain,
    JSON.stringify({ kept: kept.barText, thin, bs, thinAgain }));
  fs.mkdirSync(path.join(root, 'main-status'), { recursive: true }); put('main-status/0123456789ab.json', { tower: 'example-tower', state: 'red', since: iso(Date.now() - 3600e3), suites: ['Test-Example'], why: 'example failure', sha: 'a'.repeat(40), job: '' });
  const newBar = await until(`(() => { const b = [...document.querySelectorAll('#banners .redbar')]; return b.length === 2 && b.some((x) => /^Main is red/.test(x.textContent) && !x.classList.contains('thin')) && b.some((x) => x.classList.contains('thin')); })()`, 15000);
  check('NewBreakage_FullSize: a new breakage (a red main) shows as a full bar while the thin one stays thin', newBar, JSON.stringify((await home()).barText));
  drop('main-status');
  // works with storage blocked: the page loads, a chip clears for this visit, nothing throws
  scene('jordan'); await ev('localStorage.clear()');
  const blockId = (await send('Page.addScriptToEvaluateOnNewDocument', { source: `Object.defineProperty(window, 'localStorage', { get() { throw new DOMException('blocked', 'SecurityError'); } });` })).identifier;
  const errs = []; cdp.on((m) => { if (m.method === 'Runtime.exceptionThrown') errs.push(m.params.exceptionDetails?.exception?.description || m.params.exceptionDetails?.text); });
  await send('Runtime.enable'); await open();
  const sb0 = await line(); const blocked = await ev(`(() => { try { localStorage.length; return false; } catch { return true; } })()`);
  await tapChip('Site closed'); await clearInSheet(); await sleep(400);
  const sb1 = await line();
  check('StorageBlocked_StillWorks: with storage blocked the line shows, a chip still clears (for this visit) and the count says 1, with no error',
    blocked && sb0.chips.length === 3 && sb1.chips.length === 2 && sb1.badge === '1' && errs.length === 0, JSON.stringify({ sb0: sb0.chips, sb1: sb1.chips, badge: sb1.badge, errs }));
  await send('Page.removeScriptToEvaluateOnNewDocument', { identifier: blockId }); await ev('localStorage.clear()').catch(() => { });

  // ---------- the Yard cannot be reached: a red bar, not a card ----------
  scene('quiet'); await phone(412, 900); await open();
  server.kill();
  const downBar = await until(`[...document.querySelectorAll('#banners .redbar')].some((b) => /Can't reach the Yard/.test(b.textContent))`, 90000);
  check('Unreachable_RedBar: the Yard unreachable is a red bar (broken), never a chip', downBar && (await home()).cards === 0, JSON.stringify(await home().catch(() => null)));
  cdp.close();
} catch (e) { if (e !== null) check('the status line tests ran to the end without a crash', false, e?.stack || e?.message || String(e)); }
finally {
  page?.stop();
  await sleep(500); try { fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { }
}
console.log(JSON.stringify(out));
process.exit(0);
