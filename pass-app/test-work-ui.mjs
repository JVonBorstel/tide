// Owns the screen tests of the Work tab (pass-app/public/work, lane L5, WO-UPG-L5-4, look A). Each test is named after an acceptance line
// of the L5 brief (queue UI: one tap per card; empty, loading and error states; screen reader labels; light and dark shots at 375 px.
// choose + morning: A/B/C writes the choice and note; the morning card has at most 3 taps. replay: reduced motion becomes still day
// snapshots) or Jordan's bar (WCAG AA contrast, light and dark; behind its flag; a tap is live and confirmed, never queued offline).
// Called by tests/Test-Work.ps1 (CI's Core step) and by hand: node pass-app/test-work-ui.mjs [--shots <folder>]
// It drives the real Board server (throwaway state folder, synthetic event store) in headless Chrome or Edge over the DevTools protocol
// (Node's own WebSocket; no package). No live state folder, no network beyond 127.0.0.1.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import http from 'node:http'; import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';
import { cdpConnect } from './test-browser-kit.mjs';

let hasSqlite = true; try { await import('node:sqlite'); } catch { hasSqlite = false; }
if (!hasSqlite && !process.env.WORK_SQLITE_RESPAWNED) {
  const r = spawnSync(process.execPath, ['--experimental-sqlite', '--disable-warning=ExperimentalWarning', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit', env: { ...process.env, WORK_SQLITE_RESPAWNED: '1' } });
  process.exit(r.status ?? 1);
}
const serverArgs = process.env.WORK_SQLITE_RESPAWNED ? ['--experimental-sqlite', '--disable-warning=ExperimentalWarning'] : [];
const { openStore } = await import('../core/ledger/store.mjs');

const here = path.dirname(fileURLToPath(import.meta.url));
const shotsDir = (() => { const i = process.argv.indexOf('--shots'); return i > 0 ? path.resolve(process.argv[i + 1]) : process.env.WORK_UI_SHOTS || ''; })();
const results = [];
const check = (name, pass, detail = '') => results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'work-ui-test-'));
const root = path.join(tmp, 'state'); fs.mkdirSync(path.join(root, 'jobs'), { recursive: true });
const dbFile = path.join(root, 'tide.db');
const ago = (h) => new Date(Date.now() - h * 3600e3).toISOString();
const SHA1 = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';

// ---- a synthetic event store: 8 open cards (D-1 merge on a PR, D-2 choose A/B/C, D-3..D-8 look), two orders shipped overnight ----
const dec = (id, wo, kind, at, extra = {}) => ({ v: '1.0', id, wo, kind, ask: `Example question ${id}?`, options: kind === 'choose' ? ['A', 'B', 'C'] : ['Yes', 'Hold', 'No'],
  recommended: kind === 'choose' ? 'A' : 'Yes', why: 'The example checks are green.', answer: null, note: null, at, answeredAt: null, via: null, ...extra });
const E = (kind, wo, data, at, actor = 'engine', proof = null) => ({ at, actor, kind, wo, data, proof });
const seed = [
  E('wo.created', 'WO-3001', { goal: 'Example: a sunrise colour in the demo sky', stream: 'DEMO' }, ago(80)),
  E('pr.opened', 'WO-3001', { pr: 'example#41', branch: 'wo/example-41', base: 'main', head: SHA1 }, ago(79)),
  E('decision.asked', 'WO-3001', { decision: dec('D-1', 'WO-3001', 'merge', ago(70)) }, ago(70)),
  E('wo.created', 'WO-3002', { goal: 'Example: pick the demo sky look', stream: 'DEMO' }, ago(60)),
  E('decision.asked', 'WO-3002', { decision: dec('D-2', 'WO-3002', 'choose', ago(50), { variants: ['A', 'B', 'C'].map((o) => ({ option: o, title: `Look ${o}`, preview: `mockups/WO-3002/${o.toLowerCase()}.png` })) }) }, ago(50)),
];
for (let i = 3; i <= 8; i++) { const wo = `WO-${3000 + i}`; seed.push(E('wo.created', wo, { goal: `Example order ${i}`, stream: i % 2 ? 'DEMO' : 'SAMPLE' }, ago(48 - i)), E('decision.asked', wo, { decision: dec(`D-${i}`, wo, 'look', ago(40 - i)) }, ago(40 - i))); }
for (const [i, h] of [[20, 9], [21, 7]]) seed.push(E('wo.created', `WO-${3000 + i}`, { goal: `Example shipped order ${i}`, stream: 'SAMPLE' }, ago(h + 20)), E('merged', `WO-${3000 + i}`, { pr: `example#${i}`, sha: 'c0ffee1' + i }, ago(h), 'github', `example#${i} merged`));
for (let i = 30; i < 34; i++) seed.push(E('wo.created', `WO-${3000 + i}`, { goal: `Example moving order ${i}`, stream: 'SAMPLE' }, ago(30 - i / 2)), E('stage.entered', `WO-${3000 + i}`, { stage: 'review', from: 'build' }, ago(26 - i / 2)));
{ const s = await openStore(dbFile); s.append(seed); s.close(); }
const appendNow = async (evs) => { const s = await openStore(dbFile); try { return s.append(evs); } finally { s.close(); } };
const answered = async (id) => { const s = await openStore(dbFile, { readOnly: true }); try { return s.events().filter((e) => e.kind === 'decision.answered' && (!id || e.data.decision === id)); } finally { s.close(); } };
const flag = (on) => appendNow([{ at: new Date().toISOString(), actor: 'jordan', kind: 'flag.set', wo: null, data: { flag: 'board.work', on, decision: on ? 'D-900' : null }, proof: null }]);

// ---- the real Board server ----
const port = 21000 + Math.floor(Math.random() * 18000); const base = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, [...serverArgs, path.join(here, 'server.mjs')], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true,
  env: { ...process.env, BRAIN_KITCHEN: root, PASS_PORT: String(port), PASS_NO_TAILSCALE: '1', BRAIN_NTFY_TOPIC: '', PASS_NO_KICK: '1', KITCHEN_NOTIFY_LOG: path.join(tmp, 'notify.txt'),
    PASS_INCOME_DIR: path.join(tmp, 'empty'), PASS_CAREER_DIR: path.join(tmp, 'empty'), PASS_HOSTS: '', TIDE_DB: '', PASS_WORK_POLL_MS: '200' } });
let serverErr = ''; server.stderr.on('data', (d) => { serverErr += d; });
const health = () => new Promise((ok) => { const r = http.get(`${base}/api/health`, (res) => { res.resume(); ok(res.statusCode === 200); }); r.on('error', () => ok(false)); });

// ---- headless Chrome / Edge over the DevTools protocol (pass-app/test-browser-kit.mjs) ----
let browser = null;

try {
  for (let i = 0; i < 120 && !(await health()); i++) await sleep(150);
  const key = fs.readFileSync(path.join(root, 'pass-key.txt'), 'utf8').trim();
  const cdp = await cdpConnect(path.join(tmp, 'profile')); browser = cdp.proc;
  const { send } = cdp;
  const ev = async (expr) => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text); return r.result.value; };
  const until = async (expr, ms = 8000) => { const end = Date.now() + ms; while (Date.now() < end) { try { if (await ev(expr)) return true; } catch { } await sleep(100); } return false; };
  // a signed session cookie, as /login would give (the pass key never goes in a URL)
  const exp = Math.floor(Date.now() / 1000) + 3600; const nonce = crypto.randomBytes(16).toString('hex');
  const mac = crypto.createHmac('sha256', Buffer.from(key)).update(`chef-session|${exp}|${nonce}`).digest('hex');
  await send('Network.enable');
  await send('Network.setCookie', { name: 'pass', value: `${exp}.${nonce}.${mac}`, url: base, httpOnly: true });
  await send('Emulation.setDeviceMetricsOverride', { width: 375, height: 812, deviceScaleFactor: 2, mobile: true });
  const now = new Date(); let off = 9 - now.getUTCHours(); if (off > 14) off -= 24; if (off < -12) off += 24;
  await send('Emulation.setTimezoneOverride', { timezoneId: off === 0 ? 'Etc/GMT' : `Etc/GMT${off > 0 ? '-' : '+'}${Math.abs(off)}` });   // 9 in the morning on the phone
  const media = (scheme, motion = 'no-preference') => send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }, { name: 'prefers-reduced-motion', value: motion }] });
  await media('light');
  const open = async (hash) => { await send('Page.enable'); await send('Page.navigate', { url: 'about:blank' }); await sleep(100); await send('Page.navigate', { url: `${base}/${hash}` }); await until('document.readyState === "complete" && location.href.startsWith("http")'); };

  // ---- behind its flag ----
  await open('#/work');
  await sleep(1500);
  const offState = await ev(`({ label: document.querySelector('.bar a[data-view="ledger"] span')?.textContent, hash: location.hash, view: !!document.getElementById('view-work') })`);
  check('behind its flag: with board.work off the tab stays "Ledger" and #/work goes back to the Ledger', offState.label === 'Ledger' && offState.hash === '#/ledger', JSON.stringify(offState));
  await flag(true);
  await open('#/work');
  const shown = await until(`document.querySelectorAll('#wk-queue .wk-card').length > 0`);
  const onState = await ev(`({ label: document.querySelector('.bar a[data-view="ledger"] span')?.textContent, cur: document.querySelector('.bar a[data-view="ledger"]').getAttribute('aria-current'), title: document.getElementById('screen-title').textContent, visible: !document.getElementById('view-work').hidden })`);
  check('with board.work on, the Ledger tab becomes Work and opens the Work screen', shown && onState.label === 'Work' && onState.cur === 'page' && onState.title === 'Work' && onState.visible, JSON.stringify(onState) + ' ' + (shown ? '' : await ev(`(document.getElementById('view-work').textContent || '').slice(0, 300)`)));
  const badge = await ev(`({ work: document.getElementById('count-work')?.textContent, hidden: document.getElementById('count-work')?.hidden, ledger: getComputedStyle(document.getElementById('count-ledger')).display })`);
  check('the tab counts the cards waiting on Jordan (not the Ledger count)', badge.work === '8' && badge.hidden === false && badge.ledger === 'none', JSON.stringify(badge));
  check('the Board still runs beside it (its home view is in the page and the bar keeps its tabs)', await ev(`!!document.getElementById('view-pass') && document.querySelectorAll('.bar a[data-view]').length >= 6`));

  // ---- the queue, real data ----
  const q = await ev(`[...document.querySelectorAll('#wk-queue .wk-card')].map((n) => n.dataset.card)`);
  check('the Needs-you queue shows at most 7 cards, oldest first, from the API', q.length === 7 && q[0] === 'D-1' && q[1] === 'D-2' && q.join() === 'D-1,D-2,D-3,D-4,D-5,D-6,D-7', q.join());
  check('the queue says how many wait in all', /7 of 8/.test(await ev(`document.getElementById('wk-needs-meta').textContent`)));
  await until(`document.querySelector('#wk-queue .wk-card[data-card="D-1"] .wk-head')?.textContent.includes('a1b2c3d')`);
  check('a PR card shows the code (head sha) it is about', await ev(`document.querySelector('#wk-queue .wk-card[data-card="D-1"] .wk-head').textContent.includes('a1b2c3d')`));

  // ---- screen reader labels ----
  const a11y = await ev(`(() => { const c = document.querySelector('#wk-queue .wk-card[data-card="D-1"]'); const g = c.querySelector('[role=group]'); const b = c.querySelector('[data-answer="Yes"]');
    const ask = document.getElementById(b.getAttribute('aria-describedby'));
    const range = document.getElementById('wk-range');
    return { list: document.getElementById('wk-queue').getAttribute('role'), item: c.getAttribute('role'), labelled: document.getElementById(c.getAttribute('aria-labelledby'))?.textContent, group: g.getAttribute('aria-label'), name: b.textContent.trim(), desc: ask?.textContent,
      rec: b.querySelector('.sr-only')?.textContent, note: !!c.querySelector('label[for^="wk-note-t-"]'), noteBtn: c.querySelector('.wk-note-btn').getAttribute('aria-expanded'), range: range.getAttribute('aria-label'), rangeText: range.getAttribute('aria-valuetext'),
      sw: document.querySelector('.wk-switch').getAttribute('aria-label'), status: document.getElementById('wk-status').getAttribute('role'), unnamed: [...document.querySelectorAll('#view-work button')].filter((x) => !(x.textContent.trim() || x.getAttribute('aria-label'))).length }; })()`);
  check('screen reader labels: list and items, each answer named and described by its question, recommended said in words', a11y.list === 'list' && a11y.item === 'listitem' && a11y.labelled === 'Example question D-1?' && a11y.group === 'Answer card D-1' && a11y.name.startsWith('Yes') && a11y.desc === 'Example question D-1?' && /recommended/.test(a11y.rec), JSON.stringify(a11y));
  check('screen reader labels: the note has a label and its toggle says if it is open; the day slider says the day and its count; no unnamed button', a11y.note && a11y.noteBtn === 'false' && a11y.range === 'Day to replay' && /Today: \d+ events?/.test(a11y.rangeText || '') && a11y.sw && a11y.status === 'status' && a11y.unnamed === 0, JSON.stringify(a11y));

  // ---- the morning card: at most 3 taps ----
  const morning = await ev(`(() => { const m = document.querySelector('.wk-morning'); return m ? { buttons: m.querySelectorAll('button').length, text: m.textContent.replace(/\\s+/g, ' ').trim() } : null; })()`);
  check('the morning card has at most 3 taps: what landed overnight, what waits, one recommendation', morning && morning.buttons <= 3 && morning.buttons >= 1 && /2 landed overnight/.test(morning.text) && /8 cards wait/.test(morning.text) && /Recommended: Yes on D-1/.test(morning.text), JSON.stringify(morning));

  // ---- WCAG AA contrast, light and dark ----
  const contrastJs = `(() => { const lum = (c) => { const m = c.match(/[\\d.]+/g).map(Number); const [r, g, b] = m.slice(0, 3).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
    const bgOf = (el) => { while (el) { const c = getComputedStyle(el).backgroundColor; const a = c.match(/[\\d.]+/g); if (a && (a.length < 4 || Number(a[3]) > 0.9)) return c; if (getComputedStyle(el).backgroundImage !== 'none' && el.classList.contains('primary')) return null; el = el.parentElement; } return getComputedStyle(document.body).backgroundColor; };
    const bad = [];
    for (const el of document.querySelectorAll('#view-work .wk-ask, #view-work .wk-why, #view-work .wk-facts, #view-work .wk-meta, #view-work .wk-kind, #view-work .wk-btn:not(.primary), #view-work .wk-goal, #view-work .wk-l2, #view-work .wk-switch a, #view-work .wk-top, #view-work .wk-days span, #view-work .wk-snap-h, #view-work .wk-tile-t, #view-work .wk-note-btn')) {
      if (!el.getClientRects().length) continue; const bg = bgOf(el); if (!bg) continue;
      const a = lum(getComputedStyle(el).color), b = lum(bg); const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
      const big = parseFloat(getComputedStyle(el).fontSize) >= 24 || (parseFloat(getComputedStyle(el).fontSize) >= 18.66 && Number(getComputedStyle(el).fontWeight) >= 700);
      if (ratio < (big ? 3 : 4.5)) bad.push(el.className + ' ' + ratio.toFixed(2));
    }
    const p = document.querySelector('#view-work .wk-btn.primary'); const pr = p ? (() => { const a = lum(getComputedStyle(p).color), b = lum(getComputedStyle(document.documentElement).getPropertyValue('--ember').trim().startsWith('#') ? (() => { const h = getComputedStyle(document.documentElement).getPropertyValue('--ember').trim(); return 'rgb(' + [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16)).join(',') + ')'; })() : getComputedStyle(p).backgroundColor); return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05); })() : 99;
    if (pr < 4.5) bad.push('primary ' + pr.toFixed(2));
    return { bad, bg: getComputedStyle(document.body).backgroundColor }; })()`;
  const light = await ev(contrastJs);
  check('WCAG AA in light: every text on the Work screen has at least 4.5:1 contrast (3:1 large)', light.bad.length === 0, light.bad.join('; '));
  const shot = async (name) => { const r = await send('Page.captureScreenshot', { format: 'png' }); const b = Buffer.from(r.data, 'base64'); if (shotsDir) { fs.mkdirSync(shotsDir, { recursive: true }); fs.writeFileSync(path.join(shotsDir, name), b); } return b; };
  const pngL = await shot('work-ui-light-375.png');
  if (shotsDir) { await ev(`document.getElementById('wk-h-streams').scrollIntoView()`); await sleep(400); await shot('work-ui-light-375-streams.png'); await ev(`scrollTo(0, 0)`); await sleep(200); }
  if (shotsDir) { const r = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(path.join(shotsDir, 'work-ui-light-375-full.png'), Buffer.from(r.data, 'base64')); }
  await media('dark'); await sleep(300);
  const dark = await ev(contrastJs);
  check('WCAG AA in dark: every text on the Work screen has at least 4.5:1 contrast (3:1 large)', dark.bad.length === 0 && dark.bg !== light.bg, dark.bad.join('; ') + ' ' + dark.bg);
  const pngD = await shot('work-ui-dark-375.png');
  check('light and dark shots at 375 px', pngL.length > 20000 && pngD.length > 20000 && pngL.readUInt32BE(16) === 750 && pngD.readUInt32BE(16) === 750, `${pngL.length} ${pngD.length} ${pngL.readUInt32BE(16)}`);
  await media('light');

  // ---- one tap per card ----
  await ev(`(() => { const b = document.querySelector('#wk-queue .wk-card[data-card="D-1"] [data-answer="Yes"]'); b.click(); b.click(); b.click(); })()`);
  const gone1 = await until(`!document.querySelector('#wk-queue .wk-card[data-card="D-1"]')`);
  const evs1 = await answered('D-1');
  check('one tap per card: three quick taps on Yes write exactly one decision, and the card folds away', gone1 && evs1.length === 1 && evs1[0].data.answer === 'Yes' && evs1[0].data.via === 'board', `${gone1} ${evs1.length}`);
  check('the tap was bound to the code the row showed (the PR head in its proof)', evs1[0]?.proof === `example#41 head ${SHA1}`, String(evs1[0]?.proof));
  check('the queue fills up again from the API (D-8 comes in as the 7th)', await until(`!!document.querySelector('#wk-queue .wk-card[data-card="D-8"]')`));

  // ---- A/B/C writes the choice and the note ----
  await ev(`(() => { const c = document.querySelector('#wk-queue .wk-card[data-card="D-2"]'); c.querySelector('.wk-note-btn').click(); c.querySelector('textarea').value = 'B reads best at night.'; c.querySelector('[data-answer="B"]').click(); })()`);
  await until(`!document.querySelector('#wk-queue .wk-card[data-card="D-2"]')`);
  const evs2 = await answered('D-2');
  check('A/B/C writes the choice and the note', evs2.length === 1 && evs2[0].data.answer === 'B' && evs2[0].data.note === 'B reads best at night.', JSON.stringify(evs2[0]?.data));

  // ---- live: a new card arrives without a reload ----
  await appendNow([E('wo.created', 'WO-3040', { goal: 'Example live order', stream: 'DEMO' }, new Date().toISOString()), E('decision.asked', 'WO-3040', { decision: dec('D-40', 'WO-3040', 'look', new Date().toISOString()) }, new Date().toISOString())]);
  check('live: a card asked now shows up without a reload (the stream)', await until(`/of 7/.test(document.getElementById('wk-needs-meta').textContent)`, 6000), await ev(`document.getElementById('wk-needs-meta').textContent`));

  // ---- never queued offline ----
  await send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  await until(`/Offline/.test(document.getElementById('wk-status').textContent)`, 4000);
  await ev(`document.querySelector('#wk-queue .wk-card[data-card="D-3"] [data-answer="Yes"]').click()`);
  await sleep(400);
  const offMsg = await ev(`document.querySelector('#wk-queue .wk-card[data-card="D-3"] .wk-msg').textContent`);
  await send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  await sleep(1500);
  check('offline: the screen says so, a tap is refused with the reason and nothing is queued or sent later', /needs? a live connection|nothing is queued/i.test(offMsg) && (await answered('D-3')).length === 0, offMsg);

  // ---- the week replay; reduced motion becomes still day snapshots ----
  const week = await ev(`(() => { const r = document.getElementById('wk-range'); r.value = '6'; r.dispatchEvent(new Event('input')); return { snap: document.getElementById('wk-snap').textContent, bars: document.querySelectorAll('.wk-bar').length, play: !document.getElementById('wk-play').hidden }; })()`);
  check('the week replay: 7 day bars, a day snapshot in words, Play when motion is welcome', week.bars === 7 && /Today/.test(week.snap) && /taps?/.test(week.snap) && week.play, JSON.stringify(week));
  await media('light', 'reduce'); await sleep(200);
  const still = await ev(`(() => { const r = document.getElementById('wk-range'); r.value = '3'; r.dispatchEvent(new Event('input')); const s = document.getElementById('wk-snap');
    return { play: !document.getElementById('wk-play').hidden, swap: s.classList.contains('swap'), cardT: getComputedStyle(document.querySelector('#wk-queue .wk-card')).transitionProperty, text: s.textContent.slice(0, 60) }; })()`);
  check('reduced motion becomes still day snapshots: no Play, no cross-fade, cards only fade', !still.play && !still.swap && !/grid-template-rows|transform/.test(still.cardT) && /·/.test(still.text), JSON.stringify(still));
  await media('light');

  // ---- loading, empty and error states (the answers are replaced in the browser only) ----
  await send('Fetch.enable', { patterns: [{ urlPattern: '*/api/work?page=*', requestStage: 'Request' }] });
  let mode = 'empty'; const held = [];
  cdp.on((m) => {
    if (m.method !== 'Fetch.requestPaused') return;
    const p = m.params; if (mode === 'hold') { held.push(p.requestId); return; }
    const body = mode === 'empty' ? JSON.stringify({ ok: true, at: new Date().toISOString(), top: 'Work: nothing waits on Jordan', queue: [], queueTotal: 0, streams: [], rows: [], flags: [] }) : JSON.stringify({ ok: false, code: 'unavailable', error: 'the example store is down' });
    send('Fetch.fulfillRequest', { requestId: p.requestId, responseCode: mode === 'empty' ? 200 : 503, responseHeaders: [{ name: 'Content-Type', value: 'application/json' }, { name: 'X-Rows-Total', value: '0' }, { name: 'X-Rows-Pages', value: '1' }], body: Buffer.from(body).toString('base64') }).catch(() => { });
  });
  await ev(`localStorage.clear()`); await open('#/work');
  check('empty state: "Nothing waits on you." when the queue is empty', await until(`/Nothing waits on you/.test(document.getElementById('wk-queue').textContent)`), await ev(`document.getElementById('wk-queue').textContent`));
  mode = 'hold'; await ev(`localStorage.clear()`); await open('#/work');
  check('loading state: placeholder rows and "Loading…" until the answer comes', await until(`!!document.querySelector('#wk-queue .wk-skel') && /Loading/.test(document.getElementById('wk-needs-meta').textContent)`), '');
  mode = 'error'; for (const r of held.splice(0)) await send('Fetch.continueRequest', { requestId: r }).catch(() => { });
  await ev(`localStorage.clear()`); await open('#/work');
  check('error state: the reason in words and a Try again button', await until(`/Could not load the Work tab: the example store is down/.test(document.getElementById('wk-queue').textContent) && !!document.querySelector('#wk-queue [data-wk-retry], #wk-queue [data-wk-probe]')`), await ev(`document.getElementById('wk-queue').textContent`));
  await send('Fetch.disable');
  cdp.close();
  check('the server wrote no error line', !/work api:|uncaught|unhandled/.test(serverErr), serverErr.slice(0, 300));
} catch (e) { check('the Work screen tests ran to the end without a crash', false, e.stack || e.message); }
finally {
  try { browser?.kill(); } catch { } try { server.kill(); } catch { }
  await sleep(500); try { fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { }
}

const failed = results.filter((r) => !r.pass);
for (const r of results) console.log(`${r.pass ? 'PASS' : 'FAIL'}: ${r.name}`);
console.log(`Work tests: ${results.length - failed.length} passed, ${failed.length} failed (screen, ${Math.round((Date.now() - t0) / 1000)} s)`);
process.exit(failed.length ? 1 : 0);
