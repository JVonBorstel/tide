// Screen tests of the Board home's status line (pass-app/public/app.js renderBanners, index.html #status-line and #notice-sheet, app.css):
// notices are small chips under the header, a tap opens the full text and its action in a sheet, only a broken thing keeps a full-width red
// bar, push alerts that are off by choice say nothing on the home, and the City gets the freed space (full width, every name whole).
// Each check is named after an acceptance line. Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it.
//   node pass-app/test-status-line.mjs [--shots <folder>] [--label before|after]
// It drives the real Board server (a throwaway state folder from pass-app/speed/fixture.mjs, made-up work orders only) in headless Chrome or
// Edge over the DevTools protocol (Node's own WebSocket; no package). The City's /api/towers answer is replaced in the browser by a synthetic
// one (made-up project names, long on purpose); nothing else is faked. No live state folder, no network beyond 127.0.0.1.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import http from 'node:http'; import crypto from 'node:crypto';
import { spawn } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { makeYard } from './speed/fixture.mjs';
import { cdpConnect } from './test-browser-kit.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const argOf = (n) => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : ''; };
const shotsDir = argOf('shots') ? path.resolve(argOf('shots')) : ''; const label = argOf('label') || 'after';
const out = [];
const check = (name, pass, detail = '') => out.push({ name: detail && !pass ? `${name} (${String(detail).slice(0, 400)})` : name, pass: !!pass });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const iso = (ms) => new Date(ms).toISOString();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'status-line-test-'));
const root = makeYard(tmp, 'calm');
const empty = path.join(root, 'empty');

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

// ---- the real Board server ----
const port = 21000 + Math.floor(Math.random() * 18000); const base = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, [path.join(here, 'server.mjs')], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true,
  env: { ...process.env, BRAIN_KITCHEN: root, PASS_PORT: String(port), PASS_NO_TAILSCALE: '1', BRAIN_NTFY_TOPIC: '', PASS_NO_KICK: '1', PASS_GITHUB: 'off',
    KITCHEN_NOTIFY_LOG: path.join(tmp, 'notify.txt'), PASS_INCOME_DIR: empty, PASS_CAREER_DIR: empty, PASS_HOSTS: '' } });
let serverErr = ''; server.stderr.on('data', (d) => { serverErr = (serverErr + d).slice(-4000); });
const health = () => new Promise((ok) => { const r = http.get(`${base}/api/health`, (res) => { res.resume(); ok(res.statusCode === 200); }); r.on('error', () => ok(false)); });

// ---- headless Chrome / Edge over the DevTools protocol (pass-app/test-browser-kit.mjs) ----
let browser = null;

try {
  for (let i = 0; i < 160 && !(await health()); i++) await sleep(150);
  const key = fs.readFileSync(path.join(root, 'pass-key.txt'), 'utf8').trim();
  const cdp = await cdpConnect(path.join(tmp, 'profile')); browser = cdp.proc; const { send } = cdp;
  const ev = async (expr) => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text); return r.result.value; };
  const until = async (expr, ms = 10000) => { const end = Date.now() + ms; while (Date.now() < end) { try { if (await ev(expr)) return true; } catch { } await sleep(120); } return false; };
  // a signed session cookie, as /login would give (the pass key never goes in a URL)
  const exp = Math.floor(Date.now() / 1000) + 3600; const nonce = crypto.randomBytes(16).toString('hex');
  const mac = crypto.createHmac('sha256', Buffer.from(key)).update(`chef-session|${exp}|${nonce}`).digest('hex');
  await send('Network.enable'); await send('Page.enable');
  await send('Network.setCookie', { name: 'pass', value: `${exp}.${nonce}.${mac}`, url: base, httpOnly: true });
  await send('Fetch.enable', { patterns: [{ urlPattern: '*/api/towers*', requestStage: 'Request' }, { urlPattern: '*/sw.js', requestStage: 'Request' }] });
  cdp.on((m) => {
    if (m.method !== 'Fetch.requestPaused') return; const p = m.params;
    if (/\/sw\.js$/.test(p.request.url)) return void send('Fetch.failRequest', { requestId: p.requestId, errorReason: 'BlockedByClient' }).catch(() => { });   // no service worker: every open is fresh
    send('Fetch.fulfillRequest', { requestId: p.requestId, responseCode: 200, responseHeaders: [{ name: 'Content-Type', value: 'application/json' }], body: Buffer.from(JSON.stringify(towers())).toString('base64') }).catch(() => { });
  });
  const hourTz = (h) => { const now = new Date(); let off = h - now.getUTCHours(); if (off > 14) off -= 24; if (off < -12) off += 24; return off === 0 ? 'Etc/GMT' : `Etc/GMT${off > 0 ? '-' : '+'}${Math.abs(off)}`; };
  const phone = async (width, height = 900, { dark = true, hour = 13 } = {}) => {
    await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2.625, mobile: true });
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: dark ? 'dark' : 'light' }, { name: 'prefers-reduced-motion', value: 'reduce' }] });
    await send('Emulation.setTimezoneOverride', { timezoneId: hourTz(hour) });
  };
  const open = async (hash = '#/pass') => {
    await send('Page.navigate', { url: 'about:blank' }); await sleep(80); await send('Page.navigate', { url: `${base}/${hash}` });
    await until('document.readyState === "complete" && location.href.startsWith("http")');
    await until(`!/Connecting/.test(document.getElementById('pulse-text')?.textContent || 'Connecting') && document.querySelectorAll('#city-names a').length >= 6`, 15000);
    await sleep(700);
  };
  const shot = async (name) => { if (!shotsDir) return; fs.mkdirSync(shotsDir, { recursive: true }); const r = await send('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(shotsDir, name), Buffer.from(r.data, 'base64')); };
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
  check('Home412_ChipsAreSmall: each chip is one short line (icon + 2-4 words, at least 44 px to tap, at most 48 px tall)',
    j.chips.length > 0 && j.chips.every((c) => c.words.split(/\s+/).length >= 2 && c.words.split(/\s+/).length <= 4 && c.h >= 44 && c.h <= 48), JSON.stringify(j.chips));
  check('Home412_ChipWords: the chips say Auto-merge paused, Site closed and Supervisor quiet, in the order the notices come',
    j.chips.map((c) => c.words).join('|') === 'Auto-merge paused|Supervisor quiet|Site closed', j.chips.map((c) => c.words).join('|'));

  // ---------- speed budget (pass-app/speed/budget.json) not worse: CI's speed job measures it; here, the parts this change can cost ----------
  const sp = await ev(`(() => { const els = [...document.querySelectorAll('#status-line .notice-chip, #banners .redbar')]; return { canvases: document.querySelectorAll('canvas').length, cityCanvases: document.querySelectorAll('#city canvas').length, moving: els.filter((e) => getComputedStyle(e).animationName !== 'none' || e.getAnimations().length).length, nodes: document.querySelectorAll('#status-line *, #banners *').length }; })()`);
  check('SpeedBudget_NotWorse: the status line adds no canvas, no animation and no frame loop (one City canvas; no animation runs on a chip or bar at rest; a few nodes)', sp.cityCanvases === 1 && sp.moving === 0 && sp.nodes <= 12, JSON.stringify(sp));

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
  check('NoHScroll360_ManyChips: no horizontal scroll at 360 px with seven chips (they wrap)', m360.sw <= m360.vw && m360.bw <= m360.vw && m360.chips.length === 7, JSON.stringify({ vw: m360.vw, sw: m360.sw, bw: m360.bw, chips: m360.chips.map((x) => x.words) }));
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

  // ---------- the Yard cannot be reached: a red bar, not a card ----------
  scene('quiet'); await phone(412, 900); await open();
  server.kill();
  const downBar = await until(`[...document.querySelectorAll('#banners .redbar')].some((b) => /Can't reach the Yard/.test(b.textContent))`, 90000);
  check('Unreachable_RedBar: the Yard unreachable is a red bar (broken), never a chip', downBar && (await home()).cards === 0, JSON.stringify(await home().catch(() => null)));
  cdp.close();
} catch (e) { if (e !== null) check('the status line tests ran to the end without a crash', false, e?.stack || e?.message || String(e)); }
finally {
  try { browser?.kill(); } catch { } try { server.kill(); } catch { }
  await sleep(500); try { fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { }
}
console.log(JSON.stringify(out));
process.exit(0);
