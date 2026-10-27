// Readable everywhere (task 30, D-11 with D-3 and D-9): every tab and sheet of the Board, crawled at phone sizes against a throwaway Board
// with made-up data. Each check is named after an acceptance line of the task (and the seven items Jordan's phone showed on 10-27).
// Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it.
//   node pass-app/test-readable.mjs [--shots <folder>] [--label before|after] [--audit <file.json>]
// --label before only takes the pictures and writes the audit (what the crawl finds on each screen), then stops.
// The real Board server on a throwaway state folder (pass-app/speed/fixture.mjs 'busy' plus made-up orders, events, a chat, a Ledger and a
// Work store) in headless Chrome or Edge (pass-app/test-browser-kit.mjs boardPage); /api/towers is a synthetic answer. Nothing private.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';

// the Work tab's store is node:sqlite, behind --experimental-sqlite on node 22: run again with the flag (as test-work-ui.mjs does)
if (!process.env.READABLE_SQLITE && !process.execArgv.includes('--experimental-sqlite')) {
  const r = spawnSync(process.execPath, ['--experimental-sqlite', '--disable-warning=ExperimentalWarning', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit', env: { ...process.env, READABLE_SQLITE: '1' } });
  process.exit(r.status ?? 1);
}
const { makeYard } = await import('./speed/fixture.mjs');
const { boardPage } = await import('./test-browser-kit.mjs');
const { openStore } = await import('../core/ledger/store.mjs');
const { buildTowers } = await import('./towers.mjs');
const { cutawayHtml } = await import('./public/city-nav.js');
const { homeStats, floorWords, openWords } = await import('./public/plain.js').catch(() => ({}));

const argOf = (n) => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : ''; };
const shotsDir = argOf('shots') ? path.resolve(argOf('shots')) : ''; const label = argOf('label') || 'after'; const auditFile = argOf('audit');
const out = [];
const check = (name, pass, detail = '') => out.push({ name: detail && !pass ? `${name} (${String(detail).slice(0, 700)})` : name, pass: !!pass });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const iso = (ms) => new Date(ms).toISOString();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'readable-test-'));
const now = Date.now(); const root = makeYard(tmp, 'busy', now);
const H = 3600e3, D = 24 * H;

// ---- made-up work orders on top of the busy fixture: the names that used to read badly, recent and days-old failures ----
const step = (role) => ({ script: 'k/agent-step.ps1', args: { Role: role, Supplier: 'claude' } });
const job = (id, name, status, at, o = {}) => ({ id, name, status, cursor: 1, attempt: 0, created: iso(at - H), costUsd: 0.2, steps: [step('plan'), step('do'), step('review')],
  history: [{ at: iso(at), step: 1, outcome: 'fail', detail: 'exit 1: example check failed' }], ...o });
const extra = [
  // seven days-old failed or stopped orders (killed, quarantined): not what needs Jordan now (item 2)
  ...Array.from({ length: 7 }, (_, i) => job('J' + (40 + i), i % 2 ? `improve: - **Example cleanup ${i}** of the sample module` : `diagnose: J${30 + i}`, i % 3 ? 'killed' : 'quarantined', now - (3 + i) * D)),
  // two recent failures: these are what the number counts
  job('J50', 'improve: Make the example sky warmer at dusk', 'quarantined', now - 40 * 60e3, { history: [{ at: iso(now - 40 * 60e3), step: 1, outcome: 'fail', detail: 'exit 1: C:\\example\\repo\\kitchen\\stations\\lint.ps1 threw {"code":1,"rule":"no-tabs"} at line 12' }] }),
  job('J51', 'roadmap-item: B-48', 'quarantined', now - 3 * H),
  job('J52', 'J52', 'pending', now - H, { history: [] }),
  // one order stopped by hand inside the last day: a stopped order is counted too, so the number's words must say "or stopped" (round 1)
  job('J53', 'improve: Example order stopped by hand', 'killed', now - 2 * H),
];
for (const j of extra) fs.writeFileSync(path.join(root, 'jobs', j.id + '.json'), JSON.stringify(j));
// one sign-off, so the headline has one order to open (the fixture's J7 and J8: make J8 a plain step so the headline reads 2)
const ev = (s, type, o = {}) => JSON.stringify({ ts: iso(now - s * 1000), type, ...o });
fs.appendFileSync(path.join(root, 'events.jsonl'), [
  ev(2400, 'step.fail', { job: 'J50', step: 1, detail: 'exit 1: C:\\example\\repo\\kitchen\\stations\\lint.ps1 threw {"code":1,"rule":"no-tabs"}' }),
  ev(2390, 'job.quarantined', { job: 'J50', reason: 'fail x2' }),
  ev(1800, 'alert', { level: 'INFO', text: 'pass-app/public/app.js: example alert with a path', sent: 'off' }),
  ev(900, 'job.added', { job: 'J52', name: 'J52' }),
  ev(600, 'watchdog', { detail: 'restarted kitchen/kitchen-api.ps1 after 3 min' }),
  ev(300, 'merge.undone', { job: 'J15', detail: '**undo** of the example change' }),
].join('\n') + '\n');
// a chat with the Yard (made-up words)
fs.mkdirSync(path.join(root, 'talk'), { recursive: true });
fs.writeFileSync(path.join(root, 'talk', 'T1.json'), JSON.stringify({ title: 'Example chat about the demo sky', created: iso(now - 2 * H), updated: iso(now - H) }));
fs.writeFileSync(path.join(root, 'talk', 'T1.jsonl'), [{ role: 'you', text: 'What did the Yard finish today?', at: iso(now - 2 * H) },
  { role: 'cook', cook: 'claude', text: 'Two example orders were handed over this morning, and one is waiting for your sign-off.', at: iso(now - 2 * H + 30e3), ms: 4200 }].map((m) => JSON.stringify(m)).join('\n') + '\n');
// the Ledger (kitchen/ledger.ps1 writes it): made-up items, one titled in markdown, one with only an id
fs.writeFileSync(path.join(root, 'ledger.json'), JSON.stringify({ updated: iso(now - 3 * 60e3), top: '', counts: { waitingOnJordan: 1, moving: 2, stuck: 1, shipped: 3, notStarted: 1 },
  programs: [{ repo: 'example-project', total: 12, shipped: 5, stuck: 1 }], flags: [],
  items: [
    { id: 'I-12', kind: 'idea', title: '**Example idea**: a warmer dusk sky', from: 'coach', jordans: true, state: 'waiting-on-jordan', ageDays: 2, why: 'needs your yes', chain: [{ id: 'J7', status: 'waiting-approval' }] },
    { id: 'I-13', kind: 'idea', title: 'I-13', state: 'stuck', ageDays: 5, why: 'failed twice', chain: [{ id: 'J50', status: 'quarantined', note: 'exit 1' }] },
    { id: 'O-3', kind: 'order', title: '- Example order that moves', state: 'moving', ageDays: 1, chain: [{ id: 'J2', status: 'running' }] },
    { id: 'I-14', kind: 'idea', title: 'Example shipped idea', state: 'shipped', ageDays: 3, proof: 'merged as PR #12', chain: [{ id: 'J15', status: 'done' }] }] }));
fs.mkdirSync(path.join(root, 'watch'), { recursive: true });
fs.writeFileSync(path.join(root, 'watch', 'example-watch.json'), JSON.stringify({ name: 'example-watch', lastRun: iso(now - 5 * 60e3), everyMin: 30, found: 0 }));
// the Work tab's store: two open asks and a moving order (made-up), and its flag on (turned on after the Ledger is looked at)
const dbFile = path.join(root, 'tide.db');
{
  const dec = (id, wo, at) => ({ v: '1.0', id, wo, kind: 'look', ask: `Example question ${id}?`, options: ['Yes', 'Hold', 'No'], recommended: 'Yes', why: 'The example checks are green.', answer: null, note: null, at, answeredAt: null, via: null });
  const E = (kind, wo, data, at) => ({ at, actor: 'engine', kind, wo, data, proof: null });
  const s = await openStore(dbFile); s.append([E('wo.created', 'WO-3001', { goal: 'Example: a sunrise colour in the demo sky', stream: 'DEMO' }, iso(now - 30 * H)),
    E('decision.asked', 'WO-3001', { decision: dec('D-901', 'WO-3001', iso(now - 20 * H)) }, iso(now - 20 * H)),
    E('wo.created', 'WO-3002', { goal: 'Example: tidy the sample notes', stream: 'SAMPLE' }, iso(now - 10 * H)),
    E('stage.entered', 'WO-3002', { stage: 'review', from: 'build' }, iso(now - 5 * H))]); s.close();
}
const flagWork = async () => { const s = await openStore(dbFile); try { s.append([{ at: new Date().toISOString(), actor: 'jordan', kind: 'flag.set', wo: null, data: { flag: 'board.work', on: true, decision: 'D-900' }, proof: null }]); } finally { s.close(); } };

// ---- the City's answer, synthetic: a public tower with long PR titles and open PRs, and a private one (before: how the server aliased it) ----
const LONG = ['ci: bump actions/upload-artifact from 4 to 5 in the github-actions group', 'The app is called Tide, everywhere: the Board, the docs and the install name',
  'Board notices: one line and clearable, with readable list titles', 'Example: a warmer dusk sky over the sample tower', 'Example: fix the sample spend rotation'];
const floorsOf = (n, titled, o = {}) => Array.from({ length: n }, (_, i) => ({ pr: i + 1, at: iso(now - (n - i) * 7 * H), by: 'github', ...(titled ? { title: LONG[i % LONG.length] } : {}),
  ...(i === n - 3 ? { undone: iso(now - (n - i) * 7 * H + H) } : {}), ...(o.job && i % 4 === 0 ? { job: 'J' + (100 + i) } : {}) }));
function towers() {
  const before = label === 'before';
  const priv = { key: 'private', name: before ? 'Private project' : 'Example private app', private: true, kind: 'tower', floors: floorsOf(34, !before, { job: true }).map((f, i) => (!before && i % 4 === 0 ? (({ title, ...r }) => r)(f) : f)), open: [] };
  return { ok: true, v: 'synthetic030' + label, at: iso(Date.now()), githubAt: iso(Date.now()), towers: [priv,
    { key: 'tide', name: 'Tide', kind: 'tower', repo: 'example-owner/tide', floors: floorsOf(60, true), open: [{ pr: 61, title: LONG[0], draft: false, ci: 'green', createdAt: iso(now - 5 * H) },
      { pr: 62, title: LONG[1], draft: false, ci: 'pending', createdAt: iso(now - 2 * H) }, { pr: 63, title: LONG[2], draft: true, ci: 'red', createdAt: iso(now - H) }] },
    { key: 'sample-apps', name: 'sample-apps', kind: 'lot', floors: [], open: [], plinth: { commits: 40 } },
    { key: 'notes', name: 'notes-sample', kind: 'office', floors: [], open: [], lastCommit: iso(now - H) }] };
}

// ---- in the page: the crawl. Every visible text on the screen (and every open sheet), with what it breaks ----
const CRAWL = `((scope) => {
  const isVis = (el) => { if (!el.getClientRects().length) return false; for (let e = el; e && e.nodeType === 1; e = e.parentElement) { const cs = getComputedStyle(e); if (cs.visibility === 'hidden' || cs.display === 'none') return false; if (e.parentElement?.tagName === 'DETAILS' && !e.parentElement.open && e.tagName !== 'SUMMARY') return false; } const r = el.getBoundingClientRect(); return r.width > 1 && r.height > 1; };
  const exempt = (el) => !!el.closest('pre, code, textarea, input, select, script, style, #log-sheet, .sr-only, [data-detail]');
  const rootEl = scope ? document.querySelector(scope) : document.body;
  const ID = /(#\\d{1,6}\\b|\\bWO-\\d{1,6}\\b|\\b[A-Z]{1,3}-?\\d{1,6}\\b)/;
  const FILL = /(#\\d{1,6}|\\bWO-[\\w-]+|\\b[A-Z]{1,3}-?\\d{1,6}\\b|\\b\\d{1,2}:\\d{2}\\b|\\b\\d{1,4}(-\\d{1,2}){1,2}\\b|\\d+|[^\\p{L}]+)/gu;
  const PATH = /(?:\\b[A-Za-z]:\\\\|\\\\[\\w.-]+\\\\[\\w.-]+|(?:^|[\\s(\`'"])(?:\\.{1,2}\\/)?(?:[\\w@.-]+\\/)+[\\w.-]+\\.(?:ps1|psm1|mjs|cjs|js|ts|json|jsonl|md|css|html|py|txt|yml|yaml|log)\\b)/;
  const JSONISH = /\\{\\s*"[^"]*"\\s*:/;
  // the line an id sits on: its list row, sentence, heading or cell, else the nearest box that is not inline text (an id inside a sentence or
  // a meta line next to words is secondary text; an id that is a row or a line on its own is bare)
  const CONT = 'li, [role="listitem"], p, h1, h2, h3, h4, h5, dt, dd, button, summary, label, td, th, figcaption, .row-main, .sheet-bar, .msg-meta, .lg-prog';
  const lineOf = (el) => { const c = el.closest(CONT); if (c) return c; for (let e = el; e; e = e.parentElement) if (!/^(inline|contents)$/.test(getComputedStyle(e).display)) return e; return el; };
  const issues = []; const texts = [];
  const walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT);
  const seenCont = new Set();
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const t = n.nodeValue.replace(/\\s+/g, ' ').trim(); if (!t) continue; const el = n.parentElement; if (!el || exempt(el) || !isVis(el)) continue;
    const where = (el.id ? '#' + el.id : el.tagName.toLowerCase() + (el.className && typeof el.className === 'string' ? '.' + el.className.split(' ')[0] : '')) + ' in ' + (el.closest('section[id], dialog[id], nav, header')?.id || el.closest('nav, header')?.tagName || '?');
    texts.push(t);
    if (t.includes('**')) issues.push({ rule: 'markdown **', text: t.slice(0, 90), where });
    if (/^- /.test(t)) issues.push({ rule: 'leading "- "', text: t.slice(0, 90), where });
    const noUrl = t.replace(/https?:\\/\\/\\S+/g, '');
    if (PATH.test(noUrl)) issues.push({ rule: 'file path', text: t.slice(0, 90), where });
    if (JSONISH.test(t)) issues.push({ rule: 'raw JSON', text: t.slice(0, 90), where });
    const c = lineOf(el); if (seenCont.has(c)) continue; seenCont.add(c);
    const all = (c.innerText || c.textContent || '').replace(/\\s+/g, ' ').trim();
    if (ID.test(all) && !all.replace(FILL, '').trim()) issues.push({ rule: 'bare id', text: all.slice(0, 90), where });
  }
  return { issues, texts: texts.length, vw: innerWidth, sw: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth) };
})`;
// WCAG AA (1.4.3): every visible text against what is behind it (the composited backgrounds up the tree); 4.5:1, 3:1 for large text
const CONTRAST = `((scope) => {
  const rootEl = scope ? document.querySelector(scope) : document.body; const bad = []; let n = 0;
  const parse = (c) => { c = String(c || ''); let m = /rgba?\\(([^)]+)\\)/.exec(c); if (m) { const p = m[1].split(/[\\s,\\/]+/).filter(Boolean).map(Number); return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1]; }
    m = /color\\(srgb ([^)]+)\\)/.exec(c); if (m) { const p = m[1].split(/[\\s\\/]+/).filter(Boolean).map(Number); return [p[0] * 255, p[1] * 255, p[2] * 255, p.length > 3 ? p[3] : 1]; } return null; };
  const over = (top, under) => { const a = top[3]; return [top[0] * a + under[0] * (1 - a), top[1] * a + under[1] * (1 - a), top[2] * a + under[2] * (1 - a), 1]; };
  const lum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
  const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const bgOf = (el) => { const layers = []; for (let e = el; e; e = e.parentElement) { const cs = getComputedStyle(e); let c = parse(cs.backgroundColor);
      if ((!c || !c[3]) && /gradient/.test(cs.backgroundImage)) { const g = /(rgba?\\([^)]+\\)|color\\(srgb[^)]+\\))/.exec(cs.backgroundImage); if (g) c = parse(g[1]); }
      if (c && c[3] > 0) { layers.push(c); if (c[3] >= 1) break; } if (e.tagName === 'DIALOG' && e.open) break; }
    let base = parse(getComputedStyle(document.body).backgroundColor) || [255, 255, 255, 1]; if (base[3] < 1) base = over(base, [255, 255, 255, 1]);
    return layers.reverse().reduce((acc, l) => over(l, acc), layers.length && layers[0][3] >= 1 ? layers[0] : base); };
  const isVis = (el) => { if (!el.getClientRects().length) return false; for (let e = el; e && e.nodeType === 1; e = e.parentElement) { const cs = getComputedStyle(e); if (cs.visibility === 'hidden' || cs.display === 'none') return false; if (e.parentElement?.tagName === 'DETAILS' && !e.parentElement.open && e.tagName !== 'SUMMARY') return false; } const r = el.getBoundingClientRect(); return r.width > 1 && r.height > 1; };
  const done = new Set(); const walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT);
  for (let t = walker.nextNode(); t; t = walker.nextNode()) {
    const el = t.parentElement; if (!t.nodeValue.trim() || !el || done.has(el) || el.closest('[disabled], [aria-disabled="true"], .sr-only, canvas, svg') || !isVis(el)) continue; done.add(el);
    const cs = getComputedStyle(el); let fg = parse(cs.color); if (!fg || parseFloat(cs.fontSize) < 1) continue; let op = 1; for (let e = el; e; e = e.parentElement) op *= Number(getComputedStyle(e).opacity);
    if (op < 0.05) continue; const clip = /text/.test(cs.backgroundClip || cs.webkitBackgroundClip || '') && (parse(cs.webkitTextFillColor) || [0, 0, 0, 1])[3] === 0;
    const bg = bgOf(clip ? el.parentElement : el); const fgs = clip ? [...cs.backgroundImage.matchAll(/(rgba?\([^)]+\)|color\(srgb[^)]+\))/g)].map((m) => parse(m[1])).filter(Boolean) : [fg];
    const size = parseFloat(cs.fontSize), bold = Number(cs.fontWeight) >= 700; const need = size >= 24 || (bold && size >= 18.66) ? 3 : 4.5;
    const r = Math.min(...fgs.map((c) => ratio(over([c[0], c[1], c[2], c[3] * op], bg), bg))); n++;
    if (r + 0.005 < need) bad.push({ text: t.nodeValue.trim().slice(0, 50), ratio: Math.round(r * 100) / 100, need, where: (el.id ? '#' + el.id : el.tagName.toLowerCase() + '.' + String(el.className || '').split(' ')[0]) + ' in ' + (el.closest('section[id], dialog[id]')?.id || el.closest('nav, header')?.tagName || '?') });
  }
  return { n, bad };
})`;
// body text size: the main words of rows, sentences and sheets at least 14 px; headings that are small labels, ids, times and counts at least 12 px
const SIZES = `((scope) => {
  const rootEl = scope ? document.querySelector(scope) : document.body; const small = [];
  const walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT);
  for (let t = walker.nextNode(); t; t = walker.nextNode()) { const el = t.parentElement; if (!t.nodeValue.trim() || !el || !el.getClientRects().length || el.closest('.sr-only, svg, pre, code')) continue;
    const r = el.getBoundingClientRect(); if (r.width <= 1 || r.height <= 1) continue; const cs = getComputedStyle(el); if (cs.visibility === 'hidden') continue;
    const px = parseFloat(cs.fontSize); if (px < 1) continue; const body = /^(P|DD|LI|SUMMARY)$/.test(el.tagName) || el.matches('.row-title, .say, .lg-row b, .city-cut .city-t, .city-cut .city-m, .md *, .bubble');
    if (px < (body ? 14 : 12)) small.push({ text: t.nodeValue.trim().slice(0, 40), px, where: el.tagName.toLowerCase() + '.' + String(el.className || '').split(' ')[0] }); }
  return small;
})`;
// nothing clipped in a button (D-3): every visible .btn's last text line ends above its padding box's bottom minus 3 px (a pixel-look
// primary button draws a 3 px edge there, inset 0 -3px); measured on the text's own boxes (Range rects), so tall glyphs like "(" count
const BTNCLIP = `((scope) => {
  const rootEl = scope ? document.querySelector(scope) : document.body; const bad = [];
  for (const b of rootEl.querySelectorAll('.btn')) { if (!b.getClientRects().length || getComputedStyle(b).visibility === 'hidden') continue; const br = b.getBoundingClientRect(); if (br.width <= 1 || br.height <= 1) continue;
    const limit = br.bottom - parseFloat(getComputedStyle(b).borderBottomWidth) - 3; let low = -Infinity;
    const w = document.createTreeWalker(b, NodeFilter.SHOW_TEXT); for (let t = w.nextNode(); t; t = w.nextNode()) { if (!t.nodeValue.trim() || !t.parentElement.getClientRects().length) continue;
      const r = document.createRange(); r.selectNodeContents(t); for (const q of r.getClientRects()) if (q.width > 0 && q.height > 0) low = Math.max(low, q.bottom); }
    if (low > limit + 0.5) bad.push({ text: b.textContent.replace(/\\s+/g, ' ').trim().slice(0, 60), textBottom: Math.round(low * 10) / 10, limit: Math.round(limit * 10) / 10 }); }
  return bad;
})`;
// the gutter (D-3): visible text in a sheet's body starts at least 12 px from either edge of the screen (the house gutter is 16 px); text
// inside a box that scrolls sideways is left out (it may run past the edge on purpose)
const GUTTER = `((id) => {
  const bad = []; const vw = innerWidth;
  for (const body of document.querySelectorAll('#' + id + ' .sheet-scroll')) { const w = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
    for (let t = w.nextNode(); t; t = w.nextNode()) { const el = t.parentElement; if (!t.nodeValue.trim() || !el || !el.getClientRects().length || el.closest('.sr-only')) continue;
      let side = false; for (let e = el; e && e !== body; e = e.parentElement) { const cs = getComputedStyle(e); if (cs.visibility === 'hidden' || cs.display === 'none') { side = true; break; } if (/auto|scroll/.test(cs.overflowX) && e.scrollWidth > e.clientWidth + 1) { side = true; break; } } if (side) continue;
      const r = document.createRange(); r.selectNodeContents(t);
      for (const q of r.getClientRects()) if (q.width > 0 && q.height > 0 && (q.left < 12 || q.right > vw - 12)) { bad.push({ text: t.nodeValue.trim().slice(0, 50), left: Math.round(q.left), right: Math.round(q.right), vw, where: el.tagName.toLowerCase() + '.' + String(el.className || '').split(' ')[0] }); break; } } }
  return bad;
})`;
// the last thing on a tab, scrolled to the bottom: fully above the nav (and nothing under the header at the top)
const BOTTOM = `(async (scope) => { scrollTo(0, document.scrollingElement.scrollHeight); await new Promise((r) => setTimeout(r, 350));
  const nav = document.querySelector('nav.bar').getBoundingClientRect(); const rootEl = document.querySelector(scope);
  const els = [...rootEl.querySelectorAll('*')].filter((e) => e.getClientRects().length && !e.children.length && getComputedStyle(e).visibility !== 'hidden' && getComputedStyle(e).position !== 'fixed' && e.getBoundingClientRect().height > 0);
  const last = els.reduce((a, e) => (!a || e.getBoundingClientRect().bottom > a.getBoundingClientRect().bottom ? e : a), null);
  const lb = last ? last.getBoundingClientRect().bottom : 0;
  return { navTop: Math.round(nav.top), lastBottom: Math.round(lb), last: last ? (last.textContent || last.tagName).trim().slice(0, 50) : '', vh: innerHeight }; })`;

const TABS = [['Board', '#/pass', '#view-pass'], ['Tower', '#/city/tide', '#view-pass'], ['Floors', '#/city/private', '#view-pass'], ['Talk', '#/talk/T1', '#view-talk'], ['Activity', '#/activity', '#view-activity'],
  ['Live', '#/cooks', '#view-cooks'], ['Ledger', '#/ledger', '#view-ledger'], ['World', '#/world', '#view-world']];
const audit = { label, screens: {} };
let page = null;
try {
  page = await boardPage({ root, tmp, towers, shotsDir, nodeArgs: ['--experimental-sqlite', '--disable-warning=ExperimentalWarning'], env: { TIDE_DB: '', PASS_WORK_POLL_MS: '500' } });
  const { ev, until, phone, open, shot, send } = page;
  const crawl = (scope = '') => ev(`${CRAWL}(${JSON.stringify(scope)})`);
  const contrast = (scope = '') => ev(`${CONTRAST}(${JSON.stringify(scope)})`);
  const sizes = (scope = '') => ev(`${SIZES}(${JSON.stringify(scope)})`);
  const settle = async (ms = 500) => { await sleep(ms); };
  const goTo = async (hash) => { await ev(`location.hash = ${JSON.stringify(hash)}`); await settle(700); await ev('scrollTo(0, 0)'); await settle(200); };
  const sheet = async (id, openExpr) => { await ev(openExpr); await until(`document.getElementById(${JSON.stringify(id)})?.open`, 5000); await settle(900); };
  const closeSheets = async () => { await ev(`document.querySelectorAll('dialog[open]').forEach((d) => d.close())`); await settle(200); };
  const SHEETS = [['Work order', 'job-sheet', `location.hash = '#/job/J50'`], ['Settings', 'menu-sheet', `document.getElementById('menu-btn').click()`],
    ['New work order', 'order-sheet', `document.getElementById('order-btn').click()`], ['Notice', 'notice-sheet', `document.querySelector('#status-line .notice-chip')?.click()`]];
  // the notice sheet needs a notice: auto-merge paused (a chip)
  fs.writeFileSync(path.join(root, 'automerge-paused.json'), JSON.stringify({ until: iso(now + 3 * H), since: iso(now - 600e3), flaky: 2, suites: ['Test-Example'] }));

  // ---------- every tab and sheet: 412x900 dark and light, 360x740 dark. Pictures (412), what the crawl finds, contrast, sizes ----------
  // The Ledger first (the Work tab takes the Ledger's place once board.work is on), then the Work tab with its flag on.
  const CONFIGS = [[412, 900, true], [412, 900, false], [360, 740, true]];
  const found = { 412: [], 360: [] }, hs = [], bottoms = [], contrastBad = [], small = [], clipped = [], gutter = [];
  const record = async (w, dark, name, scope, isSheet) => {
    const look = dark ? 'dark' : 'light'; const c = await crawl(scope); const k = await contrast(scope); const z = dark && w === 412 ? await sizes(scope) : [];
    for (const b of await ev(`${BTNCLIP}(${JSON.stringify(scope)})`)) clipped.push({ screen: `${name} ${w} ${look}`, ...b });
    if (w === 360 && isSheet) for (const g of await ev(`${GUTTER}(${JSON.stringify(scope.slice(1))})`)) gutter.push({ screen: name, ...g });
    audit.screens[`${name} ${w} ${look}`] = { issues: c.issues, contrast: k.bad, small: z };
    if (dark) for (const i of c.issues) found[w].push({ screen: name, ...i });
    if (w === 412) for (const b of k.bad) contrastBad.push({ look, screen: name, ...b });
    for (const s of z) small.push({ screen: name, ...s });
    if (w === 360) {
      if (c.sw > c.vw) hs.push(`${name}: ${c.sw} > ${c.vw}`);
      if (isSheet) { const sw = await ev(`[...document.querySelector(${JSON.stringify(scope)}).querySelectorAll('*')].filter((e) => e.scrollWidth > e.clientWidth + 1 && /auto|scroll/.test(getComputedStyle(e).overflowX) && !e.closest('.seg, pre')).map((e) => String(e.className)).slice(0, 4)`); if (sw.length) hs.push(`${name} scrolls sideways inside: ${sw.join(', ')}`); }
      else bottoms.push({ name, ...(await ev(`${BOTTOM}(${JSON.stringify(scope)})`)) });
    }
  };
  const tab = async (w, dark, name, hash, scope) => {
    await goTo(hash); if (name === 'Tower' || name === 'Floors') { await until(`!!document.querySelector('.city-cut')`, 5000); await settle(400); }
    if (name === 'Work') { await until(`!!document.getElementById('view-work') && !document.getElementById('view-work').hidden`, 8000); await settle(800); }
    if (w === 412) {
      const look = dark ? 'dark' : 'light';
      if (name === 'Floors') { await ev(`document.querySelector('.city-cut')?.scrollIntoView({ block: 'start' }); scrollBy(0, -120)`); await settle(300); }
      await shot(`${name.toLowerCase()}-412-${look}-${label}.png`);
      if (name === 'Tower') { await ev(`scrollTo(0, document.scrollingElement.scrollHeight)`); await settle(400); await shot(`tower-412-${look}-${label}-bottom.png`); await ev('scrollTo(0, 0)'); }
      if (name === 'Board') { await ev(`document.getElementById('summary')?.scrollIntoView({ block: 'start' }); scrollBy(0, -140)`); await settle(300); await shot(`home-412-${look}-${label}-stats.png`); await ev('scrollTo(0, 0)'); }
    }
    await record(w, dark, name, scope, false);
  };
  for (const [w, h, dark] of CONFIGS) {
    await phone(w, h, { dark, hour: 13 }); await open('#/pass', 4);
    for (const [name, hash, scope] of TABS) await tab(w, dark, name, hash, scope);
    for (const [name, id, expr] of SHEETS) {
      await goTo('#/pass'); await sheet(id, expr); if (w === 412) await shot(`${id.replace('-sheet', '')}-sheet-412-${dark ? 'dark' : 'light'}-${label}.png`);
      await record(w, dark, name + ' sheet', '#' + id, true);
      await closeSheets(); if (id === 'job-sheet') await ev(`history.replaceState(null, '', '#/pass')`);
    }
    for (const sc of ['header', 'nav.bar']) { const k = await contrast(sc); if (w === 412) for (const b of k.bad) contrastBad.push({ look: dark ? 'dark' : 'light', screen: sc, ...b }); }
  }
  await flagWork();
  for (const [w, h, dark] of CONFIGS) { await phone(w, h, { dark, hour: 13 }); await open('#/pass', 4); await tab(w, dark, 'Work', '#/work', '#view-work'); }
  if (auditFile) fs.writeFileSync(auditFile, JSON.stringify(audit, null, 1));
  if (label === 'before') throw null;

  const SCREENS = [...TABS, ['Work', '#/work', '#view-work']];
  for (const w of [412, 360]) {
    const by = (r) => found[w].filter((i) => i.rule === r); const sz = w === 412 ? '412x900' : '360x740';
    check(`Crawl${w}_NoBareId: every tab and sheet at ${sz}: no visible text is a bare id (#55, WO-0359, J357, A16) without words next to it`, !by('bare id').length, JSON.stringify(by('bare id').slice(0, 6)));
    check(`Crawl${w}_NoMarkdown: every tab and sheet at ${sz}: no visible "**" and no text starting with "- "`, !by('markdown **').length && !by('leading "- "').length, JSON.stringify([...by('markdown **'), ...by('leading "- "')].slice(0, 6)));
    check(`Crawl${w}_NoPathNoJson: every tab and sheet at ${sz}: no Windows or repo path and no "{" JSON shown as text (the detail is one tap away)`, !by('file path').length && !by('raw JSON').length, JSON.stringify([...by('file path'), ...by('raw JSON')].slice(0, 6)));
  }
  const uniq = [...new Map(contrastBad.map((b) => [b.look + b.where + b.text, b])).values()];
  check('ContrastAA_BothLooks: every visible text element on every tab and sheet meets WCAG AA (4.5:1, 3:1 for large text) in the dark and the light look', !uniq.length, JSON.stringify(uniq.slice(0, 8)));
  check('NoHScroll360: at 360x740 no tab or sheet scrolls sideways (the page, or a box inside a sheet)', !hs.length, hs.join('; '));
  const under = bottoms.filter((b) => b.lastBottom > b.navTop);
  check('LastItem_AboveNav360: at 360x740, scrolled to the bottom, the last item on every tab is fully visible above the nav', bottoms.length === SCREENS.length && !under.length, JSON.stringify(under.length ? under : bottoms.slice(0, 2)));
  check('BodyText14: body text on every tab and sheet is at least 14 px (ids, times and counts at least 12 px)', !small.length, JSON.stringify(small.slice(0, 8)));
  check('Buttons_NothingClipped: on every tab and sheet, in both looks and both sizes, every button\'s last text line ends above its bottom edge (padding box minus 3 px), so the Retry button\'s reason line is never cut',
    !clipped.length, JSON.stringify(clipped.slice(0, 6)));
  check('SheetGutter360: at 360x740 visible text in every sheet\'s body starts at least 12 px from the screen edge (the notice sheet too)', !gutter.length, JSON.stringify(gutter.slice(0, 6)));
  await phone(412, 900, { dark: true, hour: 13 }); await open('#/pass', 4);

  // ---------- Jordan's phone, 10-27: the seven items ----------
  await goTo('#/pass'); await settle(300);
  const hs1 = await ev(`(() => { const s = document.querySelector('#summary .home-stats'); const note = document.querySelector('#summary .home-note'); if (!s) return null;
    const cells = [...s.children].filter((c) => c.getClientRects().length).map((c) => { const r = c.getBoundingClientRect(); return { t: c.textContent.trim(), top: Math.round(r.top), h: Math.round(r.height), w: Math.round(r.width), left: Math.round(r.left) }; });
    const nr = note?.getBoundingClientRect(); const sr = s.getBoundingClientRect();
    return { cells, display: getComputedStyle(s).display, note: note?.textContent.trim(), noteTop: nr ? Math.round(nr.top) : null, statsBottom: Math.round(sr.bottom), noteInside: !!note && s.contains(note) }; })()`);
  const rowsOf = (cells) => [...new Set((cells || []).map((c) => c.top))].length;
  const sameW = (cells) => { const byRow = new Map(); for (const c of cells || []) byRow.set(c.top, [...(byRow.get(c.top) || []), c.w]); return [...byRow.values()].every((ws) => Math.max(...ws) - Math.min(...ws) <= 2); };
  check('Home_StatsOneGrid: home stats sit in one grid of equal cells (no ragged second row), and the plain-words line ("Nothing handed over today") is on its own line under them',
    !!hs1 && hs1.display === 'grid' && hs1.cells.length >= 4 && sameW(hs1.cells) && rowsOf(hs1.cells) <= 2 && !hs1.noteInside && hs1.noteTop >= hs1.statsBottom && /handed over/.test(hs1.note || ''), JSON.stringify(hs1));
  const fail = await ev(`(() => { const a = [...document.querySelectorAll('#summary .home-stats a, #summary .home-stats button')].find((x) => /fail|stop/i.test(x.textContent)); const older = document.querySelector('#sec-aside [data-older]');
    return { stat: a?.textContent.replace(/\\s+/g, ' ').trim() || '', older: older?.textContent.replace(/\\s+/g, ' ').trim() || '', asideRows: document.querySelectorAll('#sec-aside .rows > li').length,
      head: document.querySelector('#sec-aside .sec-head')?.textContent.replace(/\\s+/g, ' ').trim() || '', stopped: [...document.querySelectorAll('#sec-aside .rows > li')].some((li) => /stopped by hand/i.test(li.textContent)) }; })()`);
  // the label and the count agree: the number is every row of the section it opens (failed, and stopped by hand, in the last day: J50, J51,
  // the fixture's recent one and the killed J53), and its words name both, as the section's own heading does
  const failN = Number((/^(\d+) /.exec(fail.stat) || [])[1]);
  check('Home_FailedMeansNow: the red number counts only recent failed or stopped orders not dealt with (4 here, a stopped one among them, not the 7 days-old ones), its words say "failed or stopped in the last day" like the section it opens, and the older ones are one tap away in "Cleared / older"',
    /^4 failed or stopped in the last day$/i.test(fail.stat) && failN === fail.asideRows && fail.stopped && /^failed or stopped/i.test(fail.head) && /older/i.test(fail.older) && /7/.test(fail.older), JSON.stringify(fail));
  await ev(`document.querySelector('#sec-aside [data-older]')?.click()`); await settle(400);
  const olderOpen = await ev(`document.querySelectorAll('#sec-aside .rows > li').length`);
  check('Home_OlderOneTap: one tap on "Cleared / older" lists the days-old failed or stopped orders (4 recent + 7 older)', olderOpen === 11, String(olderOpen));
  await ev(`document.querySelector('#sec-aside [data-older]')?.click()`); await settle(200);
  const signBtn = await ev(`(() => { const b = document.querySelector('#summary [data-signoff]'); return b ? { text: b.textContent.trim(), tag: b.tagName } : null; })()`);
  await ev(`document.querySelector('#summary [data-signoff]')?.click()`); await settle(900);
  const signed = await ev(`({ hash: location.hash, sheet: document.getElementById('job-sheet').open, needsTop: Math.round(document.getElementById('sec-needs')?.getBoundingClientRect().top ?? -1) })`);
  check('Home_SignOffAction: the headline "N work orders need your sign-off" has a direct action under it that opens the sign-off (one order: its sheet; more: the Needs sign-off list)',
    !!signBtn && /sign-off/i.test(signBtn.text) && (signed.sheet || (signed.needsTop >= 0 && signed.needsTop < 300)), JSON.stringify({ signBtn, signed }));
  await closeSheets(); await ev(`history.replaceState(null, '', '#/pass')`);

  await goTo('#/city/tide'); await until(`!!document.querySelector('.city-cut')`, 5000); await settle(300);
  const tw = await ev(`(() => { const rows = [...document.querySelectorAll('.city-cut li a')].slice(0, 4).map((a) => { const t = a.querySelector('.city-t'); const n = a.querySelector('.city-n');
      return { title: t?.textContent.trim(), cut: t ? (getComputedStyle(t).textOverflow === 'ellipsis' && getComputedStyle(t).whiteSpace === 'nowrap') || t.scrollWidth > t.clientWidth + 1 : true, lines: t ? Math.round(t.getBoundingClientRect().height / parseFloat(getComputedStyle(t).lineHeight)) : 0,
        num: n?.textContent.trim(), numPx: n ? parseFloat(getComputedStyle(n).fontSize) : 0, titlePx: t ? parseFloat(getComputedStyle(t).fontSize) : 0, meta: a.querySelector('.city-m')?.textContent.trim() }; });
    return { rows, text: document.querySelector('.city-cut').innerText }; })()`);
  check('Tower_TitlesWrap_PlainStatus: tower rows show the whole title (wrapped, never an ellipsis), the status in plain words ("open, checks passed"), the PR number as small secondary text',
    tw.rows.length === 4 && tw.rows.every((r) => r.title && !r.cut && !r.title.endsWith('…') && /^#\d+$/.test(r.num) && r.numPx < r.titlePx) && tw.rows[0].lines >= 2 && tw.rows[0].meta === 'open, checks passed' && tw.rows[1].meta === 'open, checks running' && tw.rows[2].meta === 'draft, checks failed' && !/\bCI\b|building/.test(tw.text),
    JSON.stringify(tw.rows));
  for (const [w, h] of [[412, 900], [360, 740]]) {
    await phone(w, h, { dark: true, hour: 13 }); await open('#/city/tide', 4); await until(`!!document.querySelector('.city-cut')`, 5000);
    await ev(`document.querySelector('[data-city-more]')?.click()`); await settle(300);
    const b = await ev(`(async () => { scrollTo(0, document.scrollingElement.scrollHeight); await new Promise((r) => setTimeout(r, 350)); const nav = document.querySelector('nav.bar').getBoundingClientRect();
      const rows = [...document.querySelectorAll('.city-cut li, .city-names li, [data-city-more]')].filter((e) => e.getClientRects().length); const last = rows[rows.length - 1].getBoundingClientRect();
      const under = document.elementFromPoint(innerWidth / 2, Math.min(innerHeight - 2, nav.bottom + 4)); const fill = getComputedStyle(document.querySelector('.bar-floor') || document.body);
      return { navTop: Math.round(nav.top), navBottom: Math.round(nav.bottom), lastBottom: Math.round(last.bottom), vh: innerHeight, underNav: under ? (under.closest('nav.bar, .bar-floor') ? 'nav' : under.closest('main') ? 'content' : under.tagName) : 'none' }; })()`);
    check(`Tower_LastRowAboveNav${w}x${h}: in a tower view the last row is fully above the nav, and nothing shows through below or beside the nav (same nav-height + safe-area room as everywhere)`,
      b.lastBottom <= b.navTop && b.underNav !== 'content', JSON.stringify(b));
  }
  await phone(412, 900, { dark: true, hour: 13 }); await open('#/city/private', 4); await until(`!!document.querySelector('.city-cut')`, 5000); await settle(300);
  const fl = await ev(`[...document.querySelectorAll('.city-cut li a')].map((a) => ({ title: a.querySelector('.city-t')?.textContent.trim() || '', meta: a.querySelector('.city-m')?.textContent.trim() || '', num: a.querySelector('.city-n')?.textContent.trim() || '' }))`);
  const words = /^(merged|taken down) [A-Z][a-z]{2} \d{1,2}$/;
  check('Floors_TitleWhatWhen: every floor row has a title, what it was (merged, taken down) and the date in words ("Oct 23"); a floor whose order is private reads "Private work order", never a bare "#55 10-23"',
    fl.length >= 20 && fl.every((r) => r.title && !/^#?\d+$/.test(r.title) && words.test(r.meta) && /^#\d+$/.test(r.num)) && fl.some((r) => r.title === 'Private work order') && fl.some((r) => /^taken down /.test(r.meta)), JSON.stringify(fl.slice(0, 5)));
  // the server: on Jordan's own signed-in Board a private repo keeps its real name and its PR titles; the alias only in demo or fixture mode
  {
    const sites = [{ key: 'td', name: 'Tide', folder: 'tide', slug: 'example-owner/tide' }, { key: 'pv', name: 'Example private app', folder: 'example-private', slug: 'example-owner/example-private' }];
    const rec = { floors: new Map([['td', [{ pr: 1, at: iso(now - D), by: 'github', title: 'Public change' }]], ['pv', [{ pr: 7, at: iso(now - D), by: 'github', title: 'Private change' }, { pr: 8, at: iso(now - H), by: 'github', title: 'Private order change', job: 'J9' }]]]), open: new Map() };
    const vis = (slug) => slug.includes('private');
    const own = buildTowers({ sites }, rec, new Map(), { repoPrivate: vis, isPrivateJob: (id) => id === 'J9' });
    const demo = buildTowers({ sites }, rec, new Map(), { repoPrivate: vis, isPrivateJob: (id) => id === 'J9', alias: true });
    const p = own.towers.find((t) => t.private), q = demo.towers.find((t) => t.private);
    check('Floors_RealNamesOnOwnBoard: on the signed-in Board a private repo shows its real name and PR titles (a private work order\'s title still stays out); "Private project" only in demo or fixture mode (alias)',
      p?.name === 'Example private app' && p.floors[0].title === 'Private change' && !('title' in p.floors[1]) && q?.name === 'Private project' && !q.floors.some((f) => f.title), JSON.stringify({ own: p, demo: q }));
  }
  const sc = await ev(`(() => { const cv = document.querySelector('#city canvas').getBoundingClientRect(); const cut = document.querySelector('.city-crumbs')?.getBoundingClientRect(); return { canvasH: Math.round(cv.height), listTop: Math.round(cut?.top ?? 9999), vh: innerHeight }; })()`);
  await goTo('#/pass'); await settle(300);
  const home = await ev(`Math.round(document.querySelector('#city canvas').getBoundingClientRect().height)`);
  check('Tower_SceneFitsContent: a tower view sizes its scene to the tower and its crew (no big empty sky): the picture is at most 45% of the screen and the list starts in the top 60%',
    sc.canvasH <= 0.45 * sc.vh && sc.listTop <= 0.6 * sc.vh, JSON.stringify({ ...sc, home }));

  // ---------- times read in words, with the exact time on tap ----------
  const tm = await ev(`(() => { const t = [...document.querySelectorAll('#board time[data-ago]')].filter((x) => x.getClientRects().length); const a = t[0]; if (!a) return null; const before = a.textContent; a.click(); const after = a.textContent; a.click();
    return { n: t.length, before, after, all: t.every((x) => /^(just now|\\d+ (min|h|days?) ago)$/.test(x.textContent.trim()) && x.getAttribute('datetime')) }; })()`);
  check('Times_WordsExactOnTap: times on the Board read "3 min ago" / "2 h ago", and a tap shows the exact time', !!tm && tm.n > 0 && tm.all && tm.before !== tm.after && /\d{1,2}:\d{2}/.test(tm.after), JSON.stringify(tm));

  // ---------- speed budget not worse ----------
  const sp = await ev(`({ canvases: document.querySelectorAll('canvas').length, cityCanvases: document.querySelectorAll('#city canvas').length, moving: [...document.querySelectorAll('#summary *, #board *')].filter((e) => e.getAnimations().length).length, nodes: document.querySelectorAll('#summary *').length })`);
  check('SpeedBudget_NotWorse: no canvas, animation or frame loop added (one City canvas; the stats grid and its rows are plain markup, a few nodes)', sp.cityCanvases === 1 && sp.moving === 0 && sp.nodes <= 40, JSON.stringify(sp));
  {
    const T = towers().towers.find((t) => t.key === 'tide'); const many = { ...T, floors: Array.from({ length: 2000 }, (_, i) => ({ pr: i + 1, at: iso(now - i * H), by: 'github', title: LONG[i % 5] })) };
    const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`); const t0 = performance.now(); for (let i = 0; i < 20; i++) cutawayHtml(many, esc, 70); const ms = (performance.now() - t0) / 20;
    check('SpeedBudget_Cutaway: a tower view of 2,000 floors builds its 70 shown rows in under 5 ms in node', ms < 5, ms.toFixed(2) + ' ms');
  }
  // the pure words, in node
  check('PlainWords_Status: open PRs and floors read in plain words (floorWords, openWords)',
    openWords({ ci: 'green' }) === 'open, checks passed' && openWords({ ci: 'pending' }) === 'open, checks running' && openWords({ ci: 'red', draft: true }) === 'draft, checks failed' && openWords({}) === 'open'
      && floorWords({ at: '2026-10-23T12:00:00Z' }) === 'merged Oct 23' && floorWords({ at: '2026-10-22T12:00:00Z', undone: '2026-10-23T12:00:00Z' }) === 'taken down Oct 23', JSON.stringify([openWords({ ci: 'green' }), floorWords({ at: '2026-10-23T12:00:00Z' })]));
  if (homeStats) {
    const j = (status, ageH) => ({ id: 'J1', status, updated: iso(now - ageH * H) });
    const st = homeStats([j('quarantined', 1), j('killed', 2), j('quarantined', 30), j('killed', 200), j('done', 1)], now);
    check('HomeStats_RecentOnly: homeStats counts failed or stopped orders of the last day as "need you", the rest as older', st.recent.length === 2 && st.older.length === 2, JSON.stringify({ r: st.recent.length, o: st.older.length }));
  } else check('HomeStats_RecentOnly: public/plain.js exists and exports homeStats', false);
} catch (e) { if (e !== null) check('the readable tests ran to the end without a crash', false, e?.stack || e?.message || String(e)); }
finally {
  page?.stop();
  await sleep(500); try { fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { }
}
console.log(JSON.stringify(out));
process.exit(0);
