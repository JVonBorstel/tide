// Tests of the Board home's lists (task 29, D-11): every row shows a human title from the one helper (public/titles.js titleOf), never a
// bare id alone and never raw markdown; the brief's repeated-failure notes are rows in its Failed list; nothing sits under the bottom nav.
// Each check is named after an acceptance line. Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it.
//   node pass-app/test-board-rows.mjs [--shots <folder>] [--label before|after]
// The real Board server on a throwaway state folder (pass-app/speed/fixture.mjs plus made-up work orders whose names are only an id, or a
// markdown bullet) in headless Chrome or Edge (pass-app/test-browser-kit.mjs boardPage). No live state folder, no network beyond 127.0.0.1.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path';
import { makeYard } from './speed/fixture.mjs';
import { boardPage } from './test-browser-kit.mjs';

const argOf = (n) => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : ''; };
const shotsDir = argOf('shots') ? path.resolve(argOf('shots')) : ''; const label = argOf('label') || 'after';
const out = [];
const check = (name, pass, detail = '') => out.push({ name: detail && !pass ? `${name} (${String(detail).slice(0, 500)})` : name, pass: !!pass });
const iso = (ms) => new Date(ms).toISOString();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'board-rows-test-'));
const root = makeYard(tmp, 'calm'); const now = Date.now();

// ---- made-up work orders with the names that used to show badly: an id alone, a markdown bullet, a heading ----
const step = (role) => ({ script: 'k/agent-step.ps1', args: { Role: role, Supplier: 'claude' } });
const job = (id, name, status, o = {}) => ({ id, name, status, cursor: 1, attempt: 0, created: iso(now - 7200e3), costUsd: 0, steps: [step('plan'), step('do'), step('review')],
  history: [{ at: iso(now - 3000e3), step: 1, outcome: 'fail', detail: 'example failure' }], ...o });
const jobs = [
  job('J21', 'diagnose: J22', 'needs-human', { approval: { id: 'A-21', text: 'Look at the diagnosis', kind: 'gate' } }),
  job('J22', 'apply-prep: A9', 'quarantined', { vars: { private: 'true' } }),
  job('J23', 'tailor: - **Example Role** at Example Co (Remote, ...', 'quarantined'),
  job('J24', 'roadmap-item: B-48', 'killed'),
  job('J25', 'improve: # Tidy the example module\nand say why in the change note', 'pending', { history: [] }),
  job('J26', 'J26', 'pending', { history: [] }),
  // failed the same step twice: the stuck-loop note
  job('J27', 'improve: example order that keeps failing', 'quarantined', { history: [{ at: iso(now - 4000e3), step: 1, outcome: 'fail', detail: 'example failure' }, { at: iso(now - 3000e3), step: 1, outcome: 'fail', detail: 'example failure' }] }),
];
for (const j of jobs) fs.writeFileSync(path.join(root, 'jobs', j.id + '.json'), JSON.stringify(j));
fs.appendFileSync(path.join(root, 'events.jsonl'), ['J22', 'J23', 'J27'].map((id, i) => JSON.stringify({ ts: iso(now - (3 - i) * 600e3), type: 'job.quarantined', job: id })).join('\n') + '\n');
const towers = () => ({ ok: true, v: 'synthetic002', at: iso(Date.now()), githubAt: iso(Date.now()), towers: [
  { key: 'example', name: 'example-project', kind: 'tower', floors: [{ pr: 1, at: iso(now - 86400e3), by: 'session' }], open: [] },
  { key: 'notes', name: 'notes-sample', kind: 'office', floors: [], open: [], lastCommit: iso(now - 3600e3) }] });

// ---- public/titles.js on its own (pure): markdown, empty and very long titles, ids alone ----
if (label !== 'before') {
  const { titleOf, cleanTitle, firstLine, BARE_ID } = await import('./public/titles.js');
  const t = (name, o = {}) => titleOf({ id: 'J7', name, ...o }).text;
  check('TitleHelper_Markdown: bullets, **, #, links and code ticks are stripped (one helper)',
    t('tailor: - **Example Role** at Example Co') === 'Example Role at Example Co' && t('improve: # Tidy the module') === 'Tidy the module' && cleanTitle('1. See [the guide](https://example.com) and `run.ps1`') === 'See the guide and run.ps1'
      && cleanTitle('> *Quoted* __words__ here') === 'Quoted words here' && cleanTitle('snake_case_name stays') === 'snake_case_name stays' && firstLine('\n\nintro line\n## The heading\n') === '## The heading',
    JSON.stringify([t('tailor: - **Example Role** at Example Co'), cleanTitle('1. See [the guide](https://example.com) and `run.ps1`'), cleanTitle('> *Quoted* __words__ here')]));
  check('TitleHelper_Empty: an empty or missing name is "Work order <its number>", never blank; a Spec with nothing after it too',
    t('') === 'Work order WO-0007' && titleOf(null).text === 'Work order WO-0000' && t('research:') === 'Work order WO-0007' && t('- ** **') === 'Work order WO-0007' && cleanTitle(undefined) === '', JSON.stringify([t(''), t('research:'), t('- ** **')]));
  const long = 'improve: ' + 'make the example module much clearer '.repeat(12);
  check('TitleHelper_VeryLong: a very long title is cut at a word to at most 60 characters with an ellipsis; cleanTitle(max) the same',
    t(long).length <= 60 && t(long).endsWith('…') && !/\s…$/.test(t(long)) && cleanTitle('word '.repeat(50), 40).length <= 40 && cleanTitle('word '.repeat(50), 40).endsWith('…'), t(long));
  check('TitleHelper_CutNames: a name the Yard already cut loses its open bracket or half word ("Example Co (Remote, ..." reads "Example Co")',
    t('tailor: - **Example Role** at Example Co (Remote, ...') === 'Example Role at Example Co' && t('tailor: Example Role at Example Compa...') === 'Example Role at Example…', t('tailor: Example Role at Example Compa...'));
  check('TitleHelper_NeverBareId: an id alone reads as words by its Spec (diagnose, apply prep, roadmap item), else "Work order <id>"; an idea label wins',
    t('diagnose: J357') === 'Why WO-0357 failed' && t('apply-prep: A16') === 'Application prep A16' && t('roadmap-item: B-48') === 'Blueprint floor B-48' && t('J26') === 'Work order WO-0026'
      && t('improve: x', { label: 'fix-example-spend-rotation' }) === 'Fix example spend rotation' && ['J357', 'A16', 'B-48', 'GW-53', 'WO-0357'].every((x) => BARE_ID.test(x)) && !BARE_ID.test('Tidy 2 files'),
    JSON.stringify([t('diagnose: J357'), t('apply-prep: A16'), t('roadmap-item: B-48'), t('J26')]));
  // speed: the helper runs once per row on every board render; 10x the fixture Yard (2,890 orders) must stay far under a frame
  const many = Array.from({ length: 2890 }, (_, i) => ({ id: 'J' + i, name: i % 3 ? `improve: - **Example ${i}** in kitchen/stations/lint.ps1. More` : `diagnose: J${i}` }));
  const t0 = performance.now(); for (const j of many) titleOf(j); const ms = performance.now() - t0;
  check('SpeedBudget_NotWorse: titles for 2,890 orders take under 40 ms in node (one pass of plain string work per row; no new canvas, animation or loop on the page)', ms < 40, ms.toFixed(1) + ' ms');
}

// ---- the Board page ----
let page = null;
try {
  page = await boardPage({ root, tmp, towers, shotsDir }); const { ev, until, phone, open, shot } = page;
  const rows = () => ev(`[...document.querySelectorAll('#view-pass li')].filter((li) => li.getClientRects().length).map((li) => {
    const t = li.querySelector('.row-title'); if (t) { const c = t.cloneNode(true); c.querySelector('.kind')?.remove(); return c.textContent.trim(); }
    const b = li.querySelector('.brief-row .t'); return (b ? b.textContent : li.textContent).trim(); })`);
  const bottom = () => ev(`(async () => { scrollTo(0, document.scrollingElement.scrollHeight); await new Promise((r) => setTimeout(r, 300));
    const nav = document.querySelector('nav.bar').getBoundingClientRect(); const lis = [...document.querySelectorAll('#view-pass li')].filter((li) => li.getClientRects().length);
    const last = lis[lis.length - 1]; const kids = [...document.querySelectorAll('#board > *, #board .sec > *')].filter((e) => e.getClientRects().length && e.getBoundingClientRect().height > 0);
    const end = Math.max(...kids.map((e) => e.getBoundingClientRect().bottom));
    return { navTop: Math.round(nav.top), lastBottom: Math.round(last.getBoundingClientRect().bottom), lastText: last.textContent.trim().slice(0, 60), end: Math.round(end), vh: innerHeight,
      cover: getComputedStyle(document.documentElement).getPropertyValue('--nav-cover').trim(), measured: Math.ceil(innerHeight - nav.top), pad: getComputedStyle(document.querySelector('main')).paddingBottom }; })()`);
  await phone(412, 900, { hour: 9 }); await open('#/pass', 2);
  await until(`!!document.querySelector('#brief .brief-group.bad')`, 8000);
  await ev(`document.querySelector('#brief .brief-group.bad')?.scrollIntoView({ block: 'start' })`); await new Promise((r) => setTimeout(r, 300));
  await shot(`rows-412-dark-${label}.png`);
  await ev(`document.getElementById('sec-aside')?.scrollIntoView({ block: 'start' })`); await new Promise((r) => setTimeout(r, 300));
  await shot(`rows-412-dark-${label}-failed.png`);
  const b412 = await bottom(); await shot(`rows-412-dark-${label}-bottom.png`);
  if (label === 'before') throw null;

  const texts = await rows();
  const bad = texts.filter((x) => /^[A-Z]\d+$/.test(x) || x.includes('**') || /^- /.test(x));
  const want = ['Why WO-0022 failed', 'Example Role at Example Co', 'Blueprint floor B-48', 'Tidy the example module', 'Work order WO-0026'];
  check('RowTitles_NoBareIdNoMarkdown: no list row text matches ^[A-Z]\\d+$, contains ** or starts with "- " (Board lists and the brief)',
    texts.length >= 8 && bad.length === 0 && want.every((w) => texts.includes(w)), JSON.stringify({ bad, missing: want.filter((w) => !texts.includes(w)), texts }));
  const st = await ev(`({ rows: [...document.querySelectorAll('#brief .brief-group.bad .stuck-row')].map((a) => a.textContent.trim()), loose: [...document.querySelectorAll('#brief .brief-list li')].filter((li) => /same step/.test(li.textContent)).length })`);
  check('StuckNotes_AreRows: a repeated failure is a row in the brief\'s Failed list (number, then "Failed the same step twice"), not a loose bullet',
    st.rows.length === 1 && /^WO-0027\s*Failed the same step twice/.test(st.rows[0]) && st.loose === 0, JSON.stringify(st));
  for (const [w, h, b] of [[412, 900, b412], [360, 740, null]]) {
    let r = b; if (!r) { await phone(w, h, { hour: 9 }); await open('#/pass', 2); r = await bottom(); }
    check(`LastRow_AboveNav${w}x${h}: at ${w}x${h} the last list row (and the last thing on the Board) is fully visible above the nav; the bottom room is measured from the nav`,
      r.lastBottom <= r.navTop && r.end <= r.navTop && r.cover === r.measured + 'px', JSON.stringify(r));
    if (w === 360) await shot(`rows-360-dark-${label}-bottom.png`);
  }
  await phone(412, 900, { hour: 9, dark: false }); await open('#/pass', 2); await ev(`document.querySelector('#brief .brief-group.bad')?.scrollIntoView({ block: 'start' })`); await new Promise((r) => setTimeout(r, 300));
  await shot(`rows-412-light-${label}.png`);
} catch (e) { if (e !== null) check('the board rows tests ran to the end without a crash', false, e?.stack || e?.message || String(e)); }
finally {
  page?.stop();
  await new Promise((r) => setTimeout(r, 500)); try { fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { }
}
console.log(JSON.stringify(out));
process.exit(0);
