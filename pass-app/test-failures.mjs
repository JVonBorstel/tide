// Failure care on the Board (task 32, D-1, D-11, D-14): the home count shows only the failures that need Jordan now (open, not cleared,
// last 72 h) in plain words; the Failures list is grouped by class with one-tap Retry, Close and See why; cleared orders sit in Older.
// Each check is named after an acceptance line. Prints a JSON list of {name, pass}; tests/Test-PassApp.ps1 runs it.
//   node pass-app/test-failures.mjs [--shots <folder>] [--label before|after]
// The real Board server on a throwaway state folder (pass-app/speed/fixture.mjs 'calm' plus made-up failed, stopped and cleared orders) in
// headless Chrome or Edge (pass-app/test-browser-kit.mjs boardPage); Retry and Close run the real kitchen.ps1 on that folder. Nothing private.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { makeYard } from './speed/fixture.mjs'; import { boardPage } from './test-browser-kit.mjs';

const out = [];   // one {name, pass} per check, printed as JSON at the end
const flag = (n) => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : ''; };
const shotsDir = flag('shots') ? path.resolve(flag('shots')) : '', label = flag('label') || 'after';
const check = (name, pass, detail = '') => out.push({ name: detail && !pass ? `${name} (${String(detail).slice(0, 600)})` : name, pass: !!pass });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const iso = (ms) => new Date(ms).toISOString();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'failures-test-'));
const now = Date.now(); const root = makeYard(tmp, 'calm', now);
const H = 3600e3, D = 24 * H;

// ---- made-up orders: what the Yard's failure care writes on them (kitchen/failure-policy.ps1 New-FailureRecord, Set-JobCleared) ----
const steps = [{ script: 'k/agent-step.ps1', args: { Role: 'plan' } }, { script: 'k/stations/freshen.ps1', args: {} }, { script: 'k/stations/tests.ps1', args: {} }];
const F = (cls, label, action, text, at) => ({ class: cls, label, action, text, at: iso(at), kind: 'fail', detail: 'raw' });
const job = (id, name, status, at, o = {}) => ({ id, name, status, cursor: 2, attempt: 0, created: iso(at - H), costUsd: 0.1, steps,
  history: [{ at: iso(at), step: 2, outcome: 'fail', detail: `exit 1: tests: FAILED: Test-Example (${id})` }], stateAt: iso(at), ...o });
const real = (at) => F('real', 'Real failure', 'stop', 'The tests failed at step 3 of 3 (tests); next: it needs a look (See why has the detail), then Retry or Close.', at);
const orders = [
  job('J60', 'improve: Make the example sky warmer at dusk', 'quarantined', now - 2 * H, { failure: real(now - 2 * H) }),
  job('J61', 'improve: Example clock in the corner', 'quarantined', now - 5 * H, { failure: F('conflict', 'Merge conflict', 'freshen', 'Main moved and its change conflicts with main at step 2 of 3 (freshen); next: the Yard freshens it from main once; if it still conflicts, Retry or Close.', now - 5 * H), history: [{ at: iso(now - 5 * H), step: 1, outcome: 'fail', detail: 'exit 1: freshen: CONFLICT merging main into kitchen/J61 in: example/file.txt' }] }),
  job('J62', 'improve: Example order stopped by hand', 'killed', now - H, { failure: F('stopped', 'Stopped', 'ask', 'It was stopped by hand at step 3 of 3 (tests); next: Retry puts it back in the queue; Close ends it.', now - H), history: [] }),
  job('J63', 'improve: Example retry after a slow step', 'quarantined', now - 30 * H, { failure: F('flaky', 'Flaky timing', 'retry', 'The step ran out of time at step 3 of 3 (tests); next: the Yard tries it once more on fresh main; if it fails again, Retry or Close.', now - 30 * H) }),
  job('J67', 'improve: Example failure from before failure care', 'quarantined', now - 3 * H),   // no failure record yet: the raw line in plain words
  // not counted: days old (in Older), and two cleared ones (in Older, with their end and reason)
  job('J64', 'improve: Example days-old failure', 'quarantined', now - 5 * D, { failure: real(now - 5 * D) }),
  job('J65', 'improve: Example cleared as stale', 'closed', now - 4 * D, { failure: real(now - 4 * D), cleared: { state: 'stale', reason: 'no human action for 4 days since it failed', at: iso(now - H), from: 'quarantined' } }),
  // open (queued): a new order with the same goal is refused at the door and named in plain words (the duplicate check below)
  job('J68', 'improve: Example order already in the queue', 'pending', now - 20 * 60e3, { cursor: 0, history: [], recipe: 'improve', vars: { goal: 'Example order already in the queue' } }),
  job('J66', 'improve: Make the example sky warmer at dusk again', 'closed', now - 2 * H, { cleared: { state: 'duplicate', reason: 'the same goal is open as J60 (quarantined)', at: iso(now - 90 * 60e3), by: 'J60', from: 'quarantined' } }),
];
for (const j of orders) fs.writeFileSync(path.join(root, 'jobs', j.id + '.json'), JSON.stringify(j));
fs.writeFileSync(path.join(root, 'jobs', 'next-id.txt'), '70');
const fileJob = (id) => JSON.parse(fs.readFileSync(path.join(root, 'jobs', id + '.json'), 'utf8').replace(/^﻿/, ''));

const towers = (t = Date.now()) => ({ ok: true, v: 'synthetic-failures', at: iso(t), githubAt: iso(t), towers: ['example-a', 'example-b', 'example-c', 'example-d', 'example-e', 'example-f'].map((k, i) => ({ key: k, name: k, kind: 'tower', floors: Array.from({ length: 4 + i }, (_, n) => ({ pr: n + 1, at: iso(t - (n + 1) * D), by: 'session' })), open: [] })) });

let page = null;
try {
  page = await boardPage({ root, tmp, towers, shotsDir }); const { ev, until, phone, open, shot, send } = page;
  const settle = (ms = 500) => sleep(ms);
  const view = () => ev(`(() => { const t = (el) => (el?.textContent || '').replace(/\\s+/g, ' ').trim();
    const stat = [...document.querySelectorAll('#summary .home-stats a')].find((a) => a.dataset.jump === 'aside');
    const lis = [...document.querySelectorAll('#sec-aside .rows > li')];
    return { stat: t(stat), statBad: !!stat?.classList.contains('bad'), head: t(document.querySelector('#sec-aside .sec-head')),
      items: lis.map((li) => li.classList.contains('fail-grp') ? { grp: t(li.querySelector('span')) } : { id: li.dataset.row, say: t(li.querySelector('.fail-say')), why: t(li.querySelector('.why-detail')), btns: [...li.querySelectorAll('.fail-acts button')].map(t), cleared: li.classList.contains('cleared') }),
      older: t(document.querySelector('#sec-aside [data-older]')), redbars: document.querySelectorAll('#banners .redbar').length, vw: innerWidth, sw: document.documentElement.scrollWidth }; })()`);
  const toAside = async () => { await ev(`document.getElementById('sec-aside')?.scrollIntoView({ block: 'start' })`); await settle(400); };

  // ---------- before/after screenshots at 412 x 900: the home count, the Failures list, Older (dark, and the list in light) ----------
  await phone(412, 900); await open(); await shot(`home-412-dark-${label}.png`);
  await toAside(); await shot(`failures-412-dark-${label}.png`);
  await ev(`document.querySelector('#sec-aside [data-older]')?.click()`); await settle(500); await toAside();
  await ev(`(() => { const li = [...document.querySelectorAll('#sec-aside .rows > li')].find((x) => /older/i.test(x.textContent) && x.classList.contains('fail-grp')) || [...document.querySelectorAll('#sec-aside .rows > li')].find((x) => x.dataset.row === 'J64'); li?.scrollIntoView({ block: 'start' }); window.scrollBy(0, -120); })()`); await settle(400);
  await shot(`older-412-dark-${label}.png`);
  await phone(412, 900, { dark: false }); await open(); await toAside(); await shot(`failures-412-light-${label}.png`);
  if (label === 'before') throw null;

  // ---------- Board home count ignores cleared and old ----------
  await phone(412, 900); await open();
  const v1 = await view(); const rows1 = v1.items.filter((x) => x.id);
  check('Home_CountIgnoresClearedAndOld: the home count shows only failures that need Jordan now (open, not cleared, last 72 h: J60, J61, J62, J63, J67), in plain words, not the days-old J64 or the cleared J65 and J66',
    v1.stat === '5 failures need you' && v1.statBad && rows1.map((x) => x.id).sort().join() === 'J60,J61,J62,J63,J67' && /^Failures\s*5$/.test(v1.head), JSON.stringify({ stat: v1.stat, head: v1.head, rows: rows1.map((x) => x.id) }));
  check('RedBars_StayForBroken: failures are a count and a list, never a red bar (the truth rule keeps red bars for broken things)', v1.redbars === 0, String(v1.redbars));

  // ---------- Failures list grouped by class, each failure in one plain sentence ----------
  const order = v1.items.map((x) => x.grp || x.id).join('|');
  check('FailuresList_GroupedByClass: the list is grouped by class, the ones that need a person first (Real failure, Stopped, Merge conflict, Flaky timing, then the ones with no class yet)',
    order === 'Real failure|J60|Stopped|J62|Merge conflict|J61|Flaky timing|J63|Failed|J67', order);
  const r60 = rows1.find((x) => x.id === 'J60'), r67 = rows1.find((x) => x.id === 'J67');
  check('FailuresList_PlainSentence: every failure shows one plain sentence of what happened and the next step, never the raw line as the main text',
    r60?.say === 'The tests failed at step 3 of 3 (tests); next: it needs a look (See why has the detail), then Retry or Close.' && rows1.every((x) => x.say && !/^exit \d|^fail: exit/.test(x.say)) && !!r67?.say, JSON.stringify(rows1.map((x) => [x.id, x.say])));
  check('FailuresList_OneTapActions: every failure row has Retry, Close and See why on the row', rows1.every((x) => x.btns.join('|') === 'Retry|Close|See why'), JSON.stringify(rows1.map((x) => x.btns)));

  // ---------- Failures list actions work: See why, Retry, Close ----------
  await ev(`document.querySelector('#sec-aside li[data-row="J60"] [data-do="why"]').click()`); await settle(400);
  const v2 = await view(); const w60 = v2.items.find((x) => x.id === 'J60');
  check('FailuresList_SeeWhy: See why opens the raw detail in the row with one tap (and says Hide why)', w60?.why === 'fail: exit 1: tests: FAILED: Test-Example (J60)' && w60.btns[2] === 'Hide why' && v2.sw <= v2.vw, JSON.stringify(w60));
  await ev(`(() => { document.querySelector('#sec-aside li[data-row="J60"]')?.scrollIntoView({ block: 'start' }); window.scrollBy(0, -120); })()`); await settle(400);
  await shot(`why-412-dark-${label}.png`);
  await ev(`document.querySelector('#sec-aside li[data-row="J60"] [data-do="why"]').click()`); await settle(300);
  check('FailuresList_SeeWhy: a second tap closes it', !(await view()).items.find((x) => x.id === 'J60')?.why);

  await ev(`document.querySelector('#sec-aside li[data-row="J60"] [data-do="retry"]').click()`);
  await until(`document.getElementById('confirm').open`, 4000); await ev(`document.getElementById('confirm-yes').click()`);
  let retried = false; for (let i = 0; i < 150 && !retried; i++) { retried = fileJob('J60').status === 'pending'; if (!retried) await sleep(200); }
  const goneRetry = await until(`!document.querySelector('#sec-aside li[data-row="J60"]')`, 15000);
  check('FailuresList_Retry: Retry puts the order back in the queue (the real kitchen.ps1 requeue) and it leaves the Failures list', retried && goneRetry, JSON.stringify({ status: fileJob('J60').status, goneRetry }));

  await ev(`document.querySelector('#sec-aside li[data-row="J61"] [data-do="close"]').click()`);
  await until(`document.getElementById('confirm').open`, 4000);
  const ask = await ev(`document.getElementById('confirm-text').textContent.replace(/\\s+/g, ' ')`);
  await ev(`document.getElementById('confirm-yes').click()`);
  let closed = null; for (let i = 0; i < 150 && !closed; i++) { const j = fileJob('J61'); if (j.status === 'closed') closed = j; else await sleep(200); }
  const goneClose = await until(`!document.querySelector('#sec-aside li[data-row="J61"]')`, 15000);
  const v3 = await view();
  check('FailuresList_Close: Close ends it as dropped with the reason (kitchen.ps1 close), it leaves the list and the count drops to 3',
    /ends as dropped/.test(ask) && closed?.cleared?.state === 'dropped' && /closed by Jordan on the Board/.test(closed?.cleared?.reason || '') && goneClose && v3.stat === '3 failures need you', JSON.stringify({ ask, cleared: closed?.cleared, stat: v3.stat }));

  // ---------- cleared ones in an Older list ----------
  await ev(`document.querySelector('#sec-aside [data-older]').click()`); await settle(500);
  const v4 = await view(); const olderIds = v4.items.slice(v4.items.findIndex((x) => x.grp === 'Older and cleared') + 1).map((x) => x.id);
  const c65 = v4.items.find((x) => x.id === 'J65'), c66 = v4.items.find((x) => x.id === 'J66'), c61 = v4.items.find((x) => x.id === 'J61');
  check('OlderList_HasCleared: one tap on "Older and cleared" lists the days-old failure and every cleared order with its end and reason (no actions on a cleared row)',
    /^Show older and cleared \(\d+\)$/.test(v1.older) && ['J64', 'J65', 'J66', 'J61'].every((id) => olderIds.includes(id)) && c65?.cleared && c65.say === 'Cleared as stale: no human action for 4 days since it failed'
      && c66?.say === 'Duplicate (J60): the same goal is open as J60 (quarantined)' && /^Dropped: closed by Jordan on the Board$/.test(c61?.say || '') && c65.btns.length === 0, JSON.stringify({ olderIds, c65, c66, c61 }));

  // ---------- duplicates at the door: a refused order names the open one in plain words, with Open (review round 4, D-11) ----------
  const dupGoal = 'Example order already in the queue';
  const jobFiles = () => fs.readdirSync(path.join(root, 'jobs')).filter((n) => /^J\d+\.json$/.test(n)).length; const dupBefore = jobFiles();
  const dupApi = await ev(`fetch('/api/action', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ op: 'cook', recipe: 'improve', vars: { goal: ${JSON.stringify(dupGoal)} } }) }).then((r) => r.json())`);
  await ev(`(() => { const b = document.createElement('button'); b.type = 'button'; b.dataset.quietOrder = ''; document.getElementById('board').append(b); b.click(); b.remove(); })()`);
  await until(`!!document.querySelector('input[name=recipe][value=improve]')`, 15000);
  await ev(`(() => { const r = document.querySelector('input[name=recipe][value=improve]'); r.checked = true; r.dispatchEvent(new Event('change', { bubbles: true })); })()`); await settle(300);
  await ev(`(() => { const g = document.getElementById('v-goal'); g.value = ${JSON.stringify(dupGoal)}; g.dispatchEvent(new Event('input', { bubbles: true })); document.getElementById('order-form').requestSubmit(); })()`);
  await until(`[...document.querySelectorAll('#toasts .toast.bad')].some((t) => /already asks/.test(t.textContent))`, 30000);
  const dupToast = await ev(`(() => { const t = [...document.querySelectorAll('#toasts .toast.bad')].find((x) => /already asks/.test(x.textContent)); return { msg: t?.querySelector('.msg')?.textContent || '', btn: t?.querySelector('[data-a]')?.textContent || '' }; })()`);
  await ev(`[...document.querySelectorAll('#toasts .toast.bad')].find((x) => /already asks/.test(x.textContent))?.querySelector('[data-a]')?.click()`); await settle(400);
  const dupHash = await ev('location.hash'); const dupFiles = jobFiles();
  check('DuplicateAtTheDoor_PlainWords: a new order whose goal is already open is not added; the phone says which work order already asks for it in plain words (WO-0068, its state, its title) with an Open button, never a bare J-id or a CLI flag',
    dupApi.ok === false && dupApi.sameAs === 'J68' && dupApi.error === 'WO-0068 already asks for this (queued)'
      && dupToast.msg === 'Not added: WO-0068 already asks for this (queued) · Example order already in the queue' && dupToast.btn === 'Open' && dupHash === '#/job/J68'
      && !/-Force|\bJ68\b|DUPLICATE/.test(dupApi.error + dupToast.msg) && dupFiles === dupBefore, JSON.stringify({ dupApi, dupToast, dupHash, dupFiles, dupBefore }));
  await ev(`(() => { document.getElementById('order-sheet')?.close?.(); location.hash = ''; })()`); await settle(300);
  // ---------- a long list: the window counts failure rows only (review round 3, D-11 and the truth rule) ----------
  // 22 more recent failures in two more classes (11 Real failure, 11 Infrastructure), so 25 need Jordan in 5 classes and the window of 20
  // cuts through a group; the old count took the group heads as rows ("Showing 20 of 29") and could leave a head last with no rows under it
  for (let i = 0; i < 22; i++) {
    const id = 'J' + (100 + i), at = now - (10 + i) * 60e3;
    const f = i % 2 ? F('infra', 'Infrastructure', 'wait', 'GitHub, CI or the network did not answer at step 3 of 3 (tests); next: it waits for GitHub, CI or the network and tries again by itself.', at) : real(at);
    fs.writeFileSync(path.join(root, 'jobs', id + '.json'), JSON.stringify(job(id, `improve: Example long-list failure ${i + 1}`, 'quarantined', at, { failure: f })));
  }
  const winView = () => ev(`(() => { const t = (el) => (el?.textContent || '').replace(/\\s+/g, ' ').trim(); const sec = document.getElementById('sec-aside');
    const lis = [...sec.querySelectorAll('.rows > li')]; const m = /Showing (\\d+) of (\\d+)/.exec(t(sec.querySelector('.win-more')));
    return { stat: t([...document.querySelectorAll('#summary .home-stats a')].find((a) => a.dataset.jump === 'aside')), more: m ? [+m[1], +m[2]] : null,
      rows: sec.querySelectorAll('.rows > li.row').length, heads: sec.querySelectorAll('.rows > li.fail-grp').length, lastIsHead: !!lis[lis.length - 1]?.classList.contains('fail-grp'),
      headAlone: lis.some((li, i) => li.classList.contains('fail-grp') && !lis[i + 1]?.classList.contains('row')), older: t(sec.querySelector('[data-older]')) }; })()`);
  await phone(412, 900); await open(); await until(`document.querySelectorAll('#sec-aside .rows > li.row').length >= 20`, 15000); await settle(400);
  const w1 = await winView();
  check('FailuresWindow_CountsRowsOnly: 25 failures in 5 classes show "Showing 20 of 25": both numbers are failure rows (li.row), never the group heads, and no group head is the last item or stands without a row under it',
    w1.stat === '25 failures need you' && w1.more?.[0] === 20 && w1.more?.[1] === 25 && w1.rows === 20 && w1.heads === 4 && !w1.lastIsHead && !w1.headAlone, JSON.stringify(w1));
  if (shotsDir) {   // the end of the window: the last shown rows and the "Showing 20 of 25" line (for the picture the line must not load
    // more as it scrolls into view, so its data-more goes for the shot; the Older tap below draws the line again with it)
    await ev(`(() => { const b = document.querySelector('#sec-aside .win-more'); b?.removeAttribute('data-more'); b?.scrollIntoView({ block: 'end' }); window.scrollBy(0, 160); })()`); await settle(300);
    await shot(`failures-window-412-dark-${label}.png`); await ev(`window.scrollTo(0, 0)`); await settle(300);
  }
  await ev(`document.querySelector('#sec-aside [data-older]').click()`); await settle(500);
  const w2 = await winView(); const nOlder = Number((/\((\d+)\)/.exec(w2.older) || [])[1]);
  check('FailuresWindow_OlderOpen: with Older open the total is every failure row (25 recent plus the older and cleared ones), the shown number is the rows on screen, and no head stands last',
    nOlder >= 4 && w2.more?.[0] === w2.rows && w2.rows === 20 && w2.more?.[1] === 25 + nOlder && !w2.lastIsHead && !w2.headAlone, JSON.stringify({ ...w2, nOlder }));
  await ev(`document.querySelector('#sec-aside .win-more')?.click()`); await settle(600);
  const w3 = await winView();
  check('FailuresWindow_ShowMore: "show more" brings every row (25 recent plus Older), the line goes away, and every head (5 classes and Older) has its rows under it',
    !w3.more && w3.rows === 25 + nOlder && w3.heads === 6 && !w3.lastIsHead && !w3.headAlone, JSON.stringify(w3));

  // ---------- no sideways scroll; speed budget not worse ----------
  await phone(360, 800); await open(); await toAside();
  const v5 = await view();
  check('NoHScroll360: no horizontal page scroll at 360 px with the Failures list and its buttons', v5.sw <= v5.vw, JSON.stringify({ vw: v5.vw, sw: v5.sw }));
  const sp = await ev(`(() => { const sec = document.getElementById('sec-aside'); const els = [...sec.querySelectorAll('*')]; return { canvases: document.querySelectorAll('canvas').length, cityCanvases: document.querySelectorAll('#city canvas').length, moving: els.filter((e) => getComputedStyle(e).animationName !== 'none' || e.getAnimations().length).length, perRow: Math.round(els.length / Math.max(1, sec.querySelectorAll('li.row').length)) }; })()`);
  check('SpeedBudget_NotWorse: the Failures list adds no canvas, no animation and no frame loop (one City canvas; nothing moves at rest; a few nodes a row)', sp.cityCanvases === sp.canvases && sp.moving === 0 && sp.perRow <= 30, JSON.stringify(sp));
  await send('Emulation.clearDeviceMetricsOverride').catch(() => { });
} catch (e) { if (e !== null) check('the failure-care Board tests ran to the end without a crash', false, e?.stack || e?.message || String(e)); }
finally {
  page?.stop();
  await sleep(500); try { fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { }
}
console.log(JSON.stringify(out));
process.exit(0);
