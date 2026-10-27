// Owns the ledger tests of the old ledger's items rebuilt (WO-UPG-L1-2), the review findings on #31 and #37, and everything that leaves
// through share.mjs: pages, the private words list, secrets and private remotes redacted by pattern (WO-UPG-L1-3, L1-4). Called by tests/core/ledger/test-ledger.mjs.
import fs from 'node:fs'; import path from 'node:path';
import { openStore } from '../../../core/ledger/store.mjs';
import { importYard } from '../../../core/ledger/import-yard.mjs';
import { importGithub } from '../../../core/ledger/import-github.mjs';
import { importLocal } from '../../../core/ledger/import-local.mjs';
import { buildView, exportLedgerJson } from '../../../core/ledger/view.mjs';
import { compareLedgers } from '../../../core/ledger/parity.mjs';
import { main } from '../../../core/ledger/commands.mjs';
import { validate } from '../../../core/contracts/validate.mjs';
import { repo, check, tmp, NOW, W, V, ev, catchCode, makeState, fakeGh, SHA1, git } from './lib.mjs';

// ---- WO-UPG-L1-2: ideas, manual links, Jordan's drops, roadmaps, the lobe's decisions, and the old ledger's items rebuilt ----
// the lobe part of WO-UPG-L1-2: a missing, a changing and an unreadable flags.json
export async function testLegacyLobe(state, base, lobeDir, importLobe) {
  const noLobe = importLobe(state, { now: NOW, home: path.join(base, 'none') });
  check('l2: lobe: no flags.json is unknown (null counts), never a made-up zero', noLobe.report.ok === false && noLobe.events[0].data.missing === true);
  const lo = await openStore(':memory:'); const lobeRead = (home) => lo.append(importLobe(state, { now: NOW, home }).events).added;
  check('l2: lobe flags present -> missing -> present again records 3 changes (A -> B -> A), and a rerun adds 0', lobeRead(lobeDir) + lobeRead(path.join(base, 'none')) + lobeRead(lobeDir) === 3 && lobeRead(lobeDir) === 0); lo.close();
  W(path.join(base, 'bad', 'flags.json'), '{ not json');
  const bad = importLobe(state, { now: NOW, home: path.join(base, 'bad') }); const s2 = await openStore(':memory:'); s2.append(bad.events);
  check('l2: lobe: an unreadable flags.json is a flag for Claude', exportLedgerJson(buildView(s2.events(), { now: NOW })).flags.some((f) => f.rule === 'lobe-flags-unreadable')); s2.close();
}

// WO-UPG-L1-2: parity item for item, no cap on the export, nothing local through share.mjs
export async function testLegacyShare(v, s) {
  // parity compares ideas and roadmap items item for item
  const old = { items: [{ id: 'I2', kind: 'idea', state: 'moving', chain: [{ id: 'J2' }] }, { id: 'I8', kind: 'idea', state: 'shipped', chain: [{ id: 'J51' }] }, { id: 'B-02', kind: 'roadmap', state: 'not-started', from: 'roadmap-repo' }, { id: 'I4', kind: 'idea', state: 'lost' }, { id: 'B-09', kind: 'roadmap', state: 'stuck', from: 'other-repo' }] };
  const p = compareLedgers(old, v, s.events()); const pi = (id) => p.items.find((i) => i.old === id);
  check('l2: parity: an idea and a roadmap item are compared with the export\'s own item', pi('I2')?.verdict === 'same' && pi('B-02')?.verdict === 'same');
  check('l2: parity: a different idea state with no reason is unexplained', pi('I4')?.verdict === 'unexplained');
  check('l2: parity: the same state with a different chain is unexplained', pi('I8')?.verdict === 'unexplained' && /chain differs: old J51, new J50/.test(pi('I8').reason));
  // review 36 F2: no silent cap on the export
  const many = Array.from({ length: 450 }, (_, i) => ev(i + 1, 'wo.created', `WO-${3000 + i}`, { goal: `Order ${i}`, stream: 'CITY' }));
  check('l2: the export keeps every item (450 rows, no 400 cap)', exportLedgerJson(buildView(many, { now: NOW })).items.length === 450);
  // review 36 F3: x.* data and local paths never leave the PC through share.mjs
  const { publicEvent, publicRow } = await import('../../../core/ledger/share.mjs');
  const repoEv = s.events().find((e) => e.kind === 'x.local.repo'); const pe = publicEvent(repoEv);
  check('l2: publicEvent drops an x.* event\'s local data (repo paths) and stays a valid event', JSON.stringify(pe.doc.data) === '{}' && pe.stripped.includes('/data') && validate('event', pe.doc).ok);
  const localProof = ['C:', 'Users', 'someone', 'work', 'proof.txt'].join('\\');
  const pp = publicEvent({ ...ev(1, 'stage.entered', 'WO-2001', { stage: 'closed' }), proof: `closed with ${localProof}` });
  check('l2: publicEvent strips a local path from proof', !pp.doc.proof.includes('someone') && pp.stripped.includes('/proof'));
  const pr0 = v.rows[0]; check('l2: publicRow keeps a row valid', validate('row', publicRow(pr0).doc).ok);
  check('l2: parity: a roadmap of a repo that was not imported is explained', pi('B-09')?.verdict === 'explained');
  const { streamOf } = await import('../../../core/ledger/ids.mjs');
  check('l2: a PR with no work order and no branch rule is in OTHER, which is not a build stream (was PR-TIDE)', streamOf('frame-loop', 'WO-PR-TIDE-5') === 'OTHER' && streamOf('x', 'WO-UPG-L1-3') === 'UPG-L1');
}

export async function testLegacy() {
  const { importIdeas } = await import('../../../core/ledger/import-ideas.mjs');
  const { importRoadmaps, importLobe } = await import('../../../core/ledger/import-roadmap.mjs');
  const base = path.join(tmp, 'l2'); const state = path.join(base, 'state'); const r = path.join(base, 'roadmap-repo');
  // a repo that opts in to a roadmap; B-01 has its change note on main; J5 is named on main; J6 was reverted
  fs.mkdirSync(r, { recursive: true }); git(r, 'init', '-q', '-b', 'main');
  W(path.join(r, 'kitchen.repo.json'), { roadmap: 'map/roadmap.json' });
  W(path.join(r, 'map', 'roadmap.json'), { waves: [{ id: 'W1', goal: 'first', items: [
    { id: 'B-01', title: 'Shipped item', why: 'x', depends_on: [], owns: ['a'], acceptance: ['a'], size: 'S' },
    { id: 'B-02', title: 'Blocked item', why: 'x', depends_on: ['B-03'], owns: ['a'], acceptance: ['a'] },
    { id: 'B-03', title: 'Owner item', why: 'x', depends_on: [], owns: ['a'], acceptance: ['a'], owner_only: true },
    { id: 'B-04', title: 'Set aside item', why: 'x', depends_on: [], owns: ['a'], acceptance: ['a'] }] }] });
  W(path.join(r, 'docs', 'changes', 'B-01.md'), 'note'); git(r, 'add', '.'); git(r, 'commit', '-q', '-m', 'B-01: shipped item');
  git(r, 'commit', '-q', '--allow-empty', '-m', 'J5: a code order'); git(r, 'commit', '-q', '--allow-empty', '-m', 'Revert "J6: undone order"');
  const job = (id, status, extra = {}) => W(path.join(state, 'jobs', `${id}.json`), { id, name: `order ${id}`, status, recipe: 'improve', created: '2030-01-01T00:00:00Z', attempt: 1, cursor: 0, parent: '', vars: { goal: `Goal of ${id}`, repo: r }, steps: [{ script: 'stations/merge.ps1' }], history: [], ...extra });
  job('J1', 'done', { recipe: 'review', steps: [], vars: { goal: 'Build it (Idea I1: first idea)', repo: r } });   // a finished non-code order: shipped
  job('J2', 'pending', { vars: { goal: 'Build it (Idea I2: second)', repo: r } });
  job('J3', 'closed', { vars: { goal: 'Build it (Idea I3: third)', repo: r } });
  job('J4', 'quarantined', { recipe: 'roadmap-item', vars: { goal: 'B-04', item: 'B-04', repo: r } });
  job('J5', 'done'); job('J7', 'done');
  W(path.join(state, 'jobs-index.json'), { v: 1, jobs: {} });
  // an archived order: its summary line has no goal, only its idea (review 36 F1)
  W(path.join(state, 'jobs', 'archive', 'index.jsonl'), JSON.stringify({ id: 'J50', status: 'done', name: 'archived order', recipe: 'review', created: '2029-12-01T00:00:00Z', ended: '2029-12-02T00:00:00Z', code: false, idea: 'I8', archivedAt: '2029-12-03T00:00:00Z' }) + '\n');
  W(path.join(state, 'events.jsonl'), [{ ts: '2030-01-02T00:00:00Z', type: 'job.closed', job: 'J3', reason: 'done another way: integrated by hand' }, { ts: '2030-01-03T00:00:00Z', type: 'merge.undone', job: 'J7' }].map((x) => JSON.stringify(x)).join('\n') + '\n');
  W(path.join(state, 'ideas.json'), { updated: '2030-01-01T00:00:00Z', nextId: 9, items: [
    { id: 'I1', title: 'First idea', status: 'merged', source: 'Jordan (phone)', score: 50, size: 'S', at: '2030-01-01T00:00:00Z', job: 'J1' },
    { id: 'I2', title: 'Second idea', status: 'building', source: 'coach', score: 95, size: 'M', at: '2030-01-01T00:00:00Z', job: 'J2' },
    { id: 'I3', title: 'Third idea', status: 'failed', source: 'coach', score: 10, size: 'M', at: '2030-01-01T00:00:00Z', job: 'J3' },
    { id: 'I4', title: 'Never built', status: 'new', source: 'Jordan (chat)', score: 10, size: 'M', at: '2029-12-01T00:00:00Z' },
    { id: 'I5', title: 'Dropped in Chef', status: 'dropped', source: 'coach', score: 10, size: 'M', at: '2030-01-01T00:00:00Z' },
    { id: 'I6', title: 'Dropped, not by Jordan', status: 'dropped', source: 'coach', score: 10, size: 'M', at: '2030-01-01T00:00:00Z' },
    { id: 'I8', title: 'Built by an archived order', status: 'merged', source: 'coach', score: 10, size: 'M', at: '2029-12-01T00:00:00Z' },
    { id: 'I7', title: 'Linked by hand', status: 'new', source: 'coach', score: 10, size: 'M', at: '2030-01-01T00:00:00Z' }] });
  W(path.join(state, 'ledger-links.json'), { I7: { proof: 'abc1234', why: 'built in a session', at: '2030-01-02T00:00:00Z', by: 'cli' } });
  W(path.join(state, 'pass-actions.jsonl'), JSON.stringify({ ts: '2030-01-02T00:00:00Z', op: 'ideas-drop', id: 'I5', ok: true }) + '\n');
  const lobeDir = path.join(base, 'lobe');
  W(path.join(lobeDir, 'flags.json'), { updated: '2030-01-05T00:00:00Z', decisionReady: [{ id: 'D-lobe-1', ready_at: '2030-01-05T00:00:00Z' }],
    postMortemDue: [{ id: 'S-J5-a', day: 30, due_at: '2030-01-05T00:00:00Z', expires_at: '2030-01-20T00:00:00Z' }, { id: 'S-J7-b', day: 60, due_at: '2030-01-05T00:00:00Z', expires_at: '2030-01-20T00:00:00Z' },
      { id: 'S-J99-c', day: 90, due_at: '2030-01-05T00:00:00Z', expires_at: '2030-01-20T00:00:00Z' }, { id: 'S-J5-d', day: 45, due_at: '2030-01-05T00:00:00Z' }] });
  const s = await openStore(':memory:');
  const all = () => [...importYard(state, { now: NOW }).events, ...importLocal({ repos: [{ path: r, name: 'roadmap-repo' }], now: NOW }).events, ...importIdeas(state, { now: NOW }).events,
    ...importRoadmaps({ repos: [{ path: r, name: 'roadmap-repo' }], now: NOW }).events, ...importLobe(state, { now: NOW, home: lobeDir }).events];
  s.append(all());
  check('l2: ideas, links, drops, roadmaps and the lobe import idempotently (a rerun adds 0 events)', s.append(all()).added === 0);
  const v = buildView(s.events(), { now: NOW }); const ex = exportLedgerJson(v); const item = (id) => ex.items.find((i) => i.id === id);
  check('l2: an idea shipped through its order (a finished non-code order)', item('I1')?.state === 'shipped' && /J1: order finished/.test(item('I1').proof));
  check('l2: an idea whose order is pending is moving, owner kitchen', item('I2')?.state === 'moving' && item('I2').owner === 'kitchen');
  check('l2: "done another way" with no proof is claimed (old rule), owner Claude', item('I3')?.state === 'claimed' && item('I3').owner === 'Claude' && ex.flags.some((f) => f.id === 'I3' && f.rule === 'claimed-no-proof'));
  check('l2: an idea never built is not-started; Jordan\'s idea waiting 3+ days is flagged', item('I4')?.state === 'not-started' && ex.flags.some((f) => f.id === 'I4' && f.rule === 'your-idea-waiting'));
  check('l2: Jordan\'s drop in Chef (pass-actions.jsonl) drops the idea', item('I5')?.state === 'dropped' && item('I5').why === 'you dropped it in Chef');
  check('l2: a drop not by Jordan and never built is lost', item('I6')?.state === 'lost' && /not by you, and never built/.test(item('I6').why));
  check('l2: an archived order keeps its idea link (summary line field idea), so the idea is shipped through it', item('I8')?.state === 'shipped' && item('I8').chain.map((c) => c.id).join() === 'J50');
  check('l2: a manual link (ledger-links.json) ships the idea', item('I7')?.state === 'shipped' && /^linked: abc1234/.test(item('I7').proof));
  check('l2: drift: the idea list says failed, but... (I3 claimed: no drift); a finished code order with no commit on main is drift', !ex.drift.some((d) => d.id === 'I3') && ex.drift.some((d) => d.id === 'J7' && /no commit on main in roadmap-repo/.test(d.what)) && !ex.drift.some((d) => d.id === 'J5'));
  check('l2: roadmap: an item with its change note on main is shipped (counted, not listed)', !item('B-01') && ex.programs[0]?.repo === 'roadmap-repo' && ex.programs[0].total === 4 && ex.programs[0].shipped === 1);
  check('l2: roadmap: blocked, owner-only and set-aside items have the old states and words', item('B-02')?.why === 'waits for B-03' && item('B-03')?.why === 'an owner step (protected files)' && item('B-04')?.state === 'stuck' && item('B-04').why === 'order J4 is set aside' && ex.programs[0].stuck === 1);
  const lf = (id) => ex.flags.find((f) => f.id === id);
  check('l2: lobe: a decision ready is a flag for Jordan', lf('D-lobe-1')?.rule === 'decision-ready' && lf('D-lobe-1').owner === 'Jordan' && ex.counts.decisionsReady === 1);
  check('l2: lobe: a post-mortem carries the proof: still on main', lf('S-J5-a')?.proofKind === 'on-main' && /still on main: commit/.test(lf('S-J5-a').proof));
  check('l2: lobe: a post-mortem of an undone merge says undone', lf('S-J7-b')?.proofKind === 'undone');
  check('l2: lobe: an order with no file is unknown; a day that is not 30/60/90 is skipped', lf('S-J99-c')?.proofKind === 'unknown' && !lf('S-J5-d') && ex.counts.postMortemsDue === 3);
  check('l2: counts keep the old meaning; the new rows are counted under work', ex.counts.claimed === 1 && ex.counts.notStarted >= 3 && typeof ex.work.rows === 'number');
  await testLegacyLobe(state, base, lobeDir, importLobe);
  const none = importRoadmaps({ repos: [{ path: path.join(tmp, 'repo'), name: 'plain' }], now: NOW });
  check('l2: a repo with no roadmap adds nothing', none.events.length === 0 && /no (kitchen\.repo\.json|roadmap)/.test(none.report[0].why));
  W(path.join(base, 'broken', 'kitchen.repo.json'), { roadmap: 'map/roadmap.json' }); W(path.join(base, 'broken', 'map', 'roadmap.json'), { waves: [{ id: 'W1', items: [{ id: 'not an id' }] }] });
  const broken = importRoadmaps({ repos: [{ path: path.join(base, 'broken'), name: 'broken' }], now: NOW });
  check('l2: a broken roadmap says why and guesses no items (fail closed)', broken.events[0]?.data.ok === false && broken.events[0].data.items.length === 0 && /not like B-01/.test(broken.report[0].why));
  check('l2: a missing ideas.json says so', importIdeas(path.join(tmp, 'nowhere'), { now: NOW }).report.ideas.why === 'missing');
  await testLegacyShare(v, s);
  s.close();
}

// ---- the verifier's findings on #31 (audits/review-tide-31-2026-10-26.md): A -> B -> A, the export's words, Node, the guard ----
export async function testReview31() {
  const { nodeHasSqlite } = await import('../../../core/ledger/store.mjs');
  const { liveStateDirs, guardLive } = await import('../../../core/ledger/commands.mjs');
  // F1.1 a Yard job: running -> waiting-approval -> running (same attempt)
  const state = path.join(tmp, 'r31-state'); makeState(state, 3);
  const setJob = (status) => { const f = path.join(state, 'jobs', 'J1.json'); const j = JSON.parse(fs.readFileSync(f, 'utf8')); j.status = status; W(f, j); };
  const s = await openStore(':memory:'); const yard = () => s.append(importYard(state, { now: NOW }).events);
  setJob('running'); yard(); setJob('waiting-approval'); yard(); setJob('running'); yard();
  const r1 = buildView(s.events(), { now: NOW }).rows.find((r) => r.id === 'WO-1');
  check('review31: a Yard job running -> waiting-approval -> running is back at build, moving, owner crew', r1?.stage === 'build' && r1.state === 'moving' && r1.owner === 'crew', JSON.stringify(r1 && [r1.stage, r1.state, r1.owner]));
  // F1.2 PAUSED, then resumed, then paused again
  W(path.join(state, 'PAUSED'), '2030-01-08T00:00:00Z'); yard(); const p1 = buildView(s.events(), { now: NOW }).paused;
  fs.rmSync(path.join(state, 'PAUSED')); yard(); const p2 = buildView(s.events(), { now: NOW });
  check('review31: the Yard paused, then resumed, is recorded as resumed', p1 === true && p2.paused === false && !/paused/.test(p2.top));
  s.close();
  // F1.3-5 GitHub: CI fail -> pass -> fail; mergeable CONFLICTING -> UNKNOWN -> CONFLICTING; closed -> reopened
  const out = path.join(tmp, 'r31-gh'); const slug = 'example-owner/example-repo';
  const pr = (over) => ({ number: 41, title: 'WO-2001: paint the sunrise', headRefName: 'art-sunrise', baseRefName: 'main', headRefOid: SHA1, createdAt: '2030-01-10T05:00:00Z', updatedAt: '2030-01-10T06:00:00Z', mergeable: 'MERGEABLE', statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }], ...over });
  const g = await openStore(':memory:');
  const read = (open, at) => g.append(importGithub({ repos: [slug], out, now: new Date(at), last: (f) => g.lastValue(f), run: fakeGh({ [`${slug}|open`]: { ok: true, data: open }, [`${slug}|merged`]: { ok: true, data: [] } }).run }).events);
  const fail = [{ status: 'COMPLETED', conclusion: 'FAILURE' }];
  read([pr({ statusCheckRollup: fail })], '2030-01-10T07:00:00Z'); read([pr({})], '2030-01-10T07:10:00Z'); read([pr({ statusCheckRollup: fail })], '2030-01-10T07:20:00Z');
  const c = buildView(g.events(), { now: NOW }).rows.find((r) => r.id === 'WO-2001');
  check('review31: CI fail -> pass -> fail on the same head shows CI failed, not merge-ready', c?.stage === 'ci' && /CI failed/.test(c.blockedOn || ''), JSON.stringify(c && [c.stage, c.blockedOn]));
  read([pr({ mergeable: 'CONFLICTING' })], '2030-01-10T07:30:00Z'); read([pr({ mergeable: 'UNKNOWN' })], '2030-01-10T07:40:00Z'); read([pr({ mergeable: 'CONFLICTING' })], '2030-01-10T07:50:00Z');
  const m = buildView(g.events(), { now: NOW }).rows.find((r) => r.id === 'WO-2001');
  check('review31: mergeable CONFLICTING -> UNKNOWN -> CONFLICTING is stale again', m?.state === 'stale' && m.blockedOn === 'conflict with main', JSON.stringify(m && [m.state, m.blockedOn]));
  read([], '2030-01-10T08:00:00Z'); const closed = buildView(g.events(), { now: NOW }).rows.find((r) => r.id === 'WO-2001');
  read([pr({})], '2030-01-10T08:10:00Z'); const reopened = buildView(g.events(), { now: NOW }).rows.find((r) => r.id === 'WO-2001');
  check('review31: a PR closed, then reopened, is lost then open again (a reopened event)', closed?.state === 'lost' && reopened?.state !== 'lost' && g.events().some((e) => e.kind === 'pr.updated' && e.data.why === 'reopened'), JSON.stringify([closed?.state, reopened?.state]));
  check('review31: a rerun of the same GitHub read adds 0 events', read([pr({})], '2030-01-10T08:20:00Z').added === 0);
  g.close();
  // F3: the export carries no card question text
  const D = { v: V, id: 'D-5', wo: 'WO-2001', kind: 'merge', ask: 'A private question text', options: ['Yes', 'No'], recommended: 'Yes', answer: null, note: null, at: '2030-01-10T00:00:00Z', answeredAt: null, via: null };
  const ex = exportLedgerJson(buildView([ev(1, 'wo.created', 'WO-2001', { goal: 'Paint', stream: 'ART' }), ev(2, 'decision.asked', 'WO-2001', { decision: D })], { now: NOW }));
  check('review31: ledger.next.json keeps a card\'s question out (ids and goal only)', !JSON.stringify(ex).includes('A private question text') && ex.flags.some((f) => f.id === 'D-5' && f.rule === 'waiting-on-you'));
  // F4: Node below 22.5 is named in plain words
  check('review31: node:sqlite needs Node 22.5 or later (20.18.1 no, 22.4.0 no, 22.5.0 yes, 24.0.0 yes)', !nodeHasSqlite('20.18.1') && !nodeHasSqlite('22.4.0') && nodeHasSqlite('22.5.0') && nodeHasSqlite('24.0.0'));
  // F5: an extra guarded folder never removes the default one
  const saved = process.env.LEDGER_LIVE_STATE; process.env.LEDGER_LIVE_STATE = path.join(tmp, 'elsewhere');
  const dirs = liveStateDirs([path.join(tmp, 'injected')]);
  check('review31: LEDGER_LIVE_STATE and an injected folder add guards; the Yard\'s own folder stays guarded', dirs.length === 3 && dirs.some((d) => /brain-kitchen$/.test(d)));
  const def = dirs.find((d) => /brain-kitchen$/.test(d));
  check('review31: the default live folder is still refused with LEDGER_LIVE_STATE set elsewhere', catchCode(() => guardLive([path.join(def, 'tide.db')])) === undefined ? false : /refused/.test(String((() => { try { guardLive([path.join(def, 'tide.db')]); return ''; } catch (e) { return e.message; } })())));
  if (saved === undefined) delete process.env.LEDGER_LIVE_STATE; else process.env.LEDGER_LIVE_STATE = saved;
}

// ---- WO-UPG-L1-3: every export goes through share.mjs; needs-you first, then newest; pages, never a silent cut ----
export async function testShare() {
  const { makeRedactor, MARK } = await import('../../../core/ledger/share.mjs');
  const { pageLedger } = await import('../../../core/ledger/view.mjs');
  // private-looking values are built at run time (CREED 8), and are synthetic
  const userPath = ['C:', 'Users', 'someone', 'notes', 'plan.md'].join('\\'); const mail = ['someone', 'example.invalid'].join('@');
  const host = ['box', 'tail0000', 'ts', 'net'].join('.'); const ip = ['192', '168', '7', '9'].join('.');
  const r = makeRedactor({ privateWords: ['Acme Widgets'] });
  const red = r(`see ${userPath}, mail ${mail}, host ${host} at ${ip}, apply to acme widgets; tide#21 stays`);
  check('l3: free text loses paths, emails, private hosts and addresses, and private words (any case)', !red.includes('someone') && !red.includes('tail0000') && !red.includes(ip) && !/acme/i.test(red)
    && red.includes(MARK.path) && red.includes(MARK.email) && red.includes(MARK.host) && red.includes(MARK.word) && red.includes('tide#21'), red);
  // a synthetic state: a job whose goal names a path, an email and a private word; a private job; the private words list
  const state = path.join(tmp, 'l3-state'); makeState(state, 6);
  const setJob = (id, f) => { const p = path.join(state, 'jobs', `${id}.json`); const j = JSON.parse(fs.readFileSync(p, 'utf8')); f(j); W(p, j); };
  setJob('J1', (j) => { j.vars.goal = `Fix ${userPath} for ${mail} at Acme Widgets`; j.status = 'waiting-approval'; });
  setJob('J2', (j) => { j.vars.goal = 'A secret goal text'; j.vars.private = 'yes'; j.status = 'pending'; });   // as the Yard writes it (kitchen/cook.ps1)
  setJob('J3', (j) => { j.vars.goal = 'Another secret goal'; j.steps = [{ script: 'stations/tests.ps1', args: { Private: true } }]; });
  W(path.join(state, 'ledger-private-words.json'), ['Acme Widgets']);
  const db = path.join(tmp, 'l3-out', 'tide.db'); const lines = [];
  check('l3: build writes the shared files', await main(['build', '--state', state, '--db', db, '--no-github', '--repo', `example=${path.join(tmp, 'repo')}`, '--now', NOW.toISOString()], { out: (x) => lines.push(x) }) === 0);
  const work = fs.readFileSync(path.join(tmp, 'l3-out', 'work.json'), 'utf8'); const led = fs.readFileSync(path.join(tmp, 'l3-out', 'ledger.next.json'), 'utf8');
  for (const [name, text] of [['work.json', work], ['ledger.next.json', led]]) {
    check(`l3: ${name} has no path, email or private word, and no private order's goal`, !text.includes('someone') && !/acme widgets/i.test(text) && !text.includes('A secret goal text') && !text.includes('Another secret goal'));
  }
  check('l3: a private order shows "a private work order" in work.json and ledger.next.json', JSON.parse(work).rows.find((x) => x.id === 'WO-2')?.goal === MARK.order && JSON.parse(led).items.find((x) => x.id === 'J2')?.title === MARK.order);
  const s = await openStore(db, { readOnly: true }); const raw = s.events({ wo: 'WO-2' }).find((e) => e.kind === 'wo.created'); s.close();
  check('l3: tide.db keeps the raw facts (it never leaves the PC)', raw?.data.goal === 'A secret goal text');
  lines.length = 0; await main(['show', 'J2', '--db', db, '--json', '--state', state, '--now', NOW.toISOString()], { out: (x) => lines.push(x) });
  const shown = JSON.parse(lines[0]);
  check('l3: show --json hides a private order\'s goal and drops x.* event data', shown.row.goal === MARK.order && shown.events.filter((e) => /^x\./.test(e.kind)).every((e) => JSON.stringify(e.data) === '{}'));
  lines.length = 0; await main(['queue', '--db', db, '--json', '--state', state, '--now', NOW.toISOString()], { out: (x) => lines.push(x) });
  check('l3: queue --json is redacted (the waiting order\'s goal loses its path, email and private word)', !lines[0].includes('someone') && !/acme widgets/i.test(lines[0]) && /WO-1/.test(lines[0]));
  // order: needs-you first, then newest
  const rows = JSON.parse(work).rows; const items = JSON.parse(led).items;
  const rNot = rows.findIndex((x) => x.state !== 'waiting-on-jordan');
  check('l3: work.json rows: needs-you first, then newest first', rows[0].state === 'waiting-on-jordan' && rows.slice(rNot).every((x) => x.state !== 'waiting-on-jordan') && rows.slice(rNot).every((x, i, a) => i === 0 || a[i - 1].ageH <= x.ageH));
  const firstNot = items.findIndex((x) => x.state !== 'waiting-on-jordan');
  check('l3: ledger.next.json items: needs-you first, then newest first', items[0].state === 'waiting-on-jordan' && items.slice(firstNot).every((x, i, a) => i === 0 || String(a[i - 1].since || '') >= String(x.since || '')));
  // pages, never a silent cut
  const doc = { ok: true, updated: NOW.toISOString(), items: Array.from({ length: 950 }, (_, i) => ({ id: `I${i}` })) };
  const pages = pageLedger(doc);
  check('l3: 950 items make 3 pages of 400, 400 and 150, each saying the page count and the total', pages.length === 3 && pages.map((p) => p.items.length).join() === '400,400,150' && pages.every((p) => p.paging.pages === 3 && p.paging.itemsTotal === 950));
  check('l3: the pages hold every item once, in order', pages.flatMap((p) => p.items.map((x) => x.id)).join() === doc.items.map((x) => x.id).join());
  check('l3: an empty export is one page with 0 items', pageLedger({ ok: true, items: [] }).length === 1);
  const big = path.join(tmp, 'l3-big'); makeState(big, 420);
  await main(['build', '--state', big, '--db', path.join(big, 'out', 'tide.db'), '--no-github', '--repo', `example=${path.join(tmp, 'repo')}`, '--now', NOW.toISOString()], { out: () => { } });
  const p1 = JSON.parse(fs.readFileSync(path.join(big, 'out', 'ledger.next.json'), 'utf8')); const p2f = path.join(big, 'out', 'ledger.next.page-2.json');
  check('l3: build writes page 2 when there are over 400 items, and page 1 says how many there are', p1.items.length === 400 && p1.paging.itemsTotal > 400 && fs.existsSync(p2f) && JSON.parse(fs.readFileSync(p2f, 'utf8')).items.length === p1.paging.itemsTotal - 400);
}

// ---- review 37 (audits/review-tide-37-2026-10-26.md): event payloads, flags and cards of private orders; the error line; path shapes;
// stale pages; the private words example and a missing list ----
export async function testShare37() {
  const { makeRedactor, MARK, readPrivateWords } = await import('../../../core/ledger/share.mjs');
  const r = makeRedactor({ privateWords: [] });
  const u = (...p) => p.join('\\'); const home = ['', 'home', 'someone', 'x'].join('/');
  const cases = [
    ['after a colon', `cwd:${u('C:', 'Users', 'someone', 'x')}`],
    ['a file:/// URL', `open file:///C:/Users/someone/x.txt now`],
    ['a path with spaces', `${u('C:', 'Users', 'someone', 'my docs', 'a.txt')}`],
    ['Program Files', `${u('C:', 'Program Files', 'someone tool', 'x.exe')}`],
    ['a home path', `in ${home} now`],
    ['a share', `${u('', '', 'server', 'share', 'someone')}`],
  ];
  for (const [name, text] of cases) { const out = r(text); check(`l3-37: a path ${name} is fully redacted`, !/someone/.test(out) && out.includes(MARK.path), out); }
  check('l3-37: a tailnet IPv6 address is redacted', !r(`at ${['fd7a', '115c', 'a1e0', '', '1'].join(':')} now`).includes('fd7a'));
  check('l3-37: a file name like appsettings.local.json is kept', r('edit appsettings.local.json') === 'edit appsettings.local.json');
  const long = 'a'.repeat(200000); const t0 = Date.now(); r(long);
  check('l3-37: a long run of letters is redacted in linear time (200 000 chars under 1 s)', Date.now() - t0 < 1000);
  // a private order with a card and a failed step
  const state = path.join(tmp, 'l37-state'); makeState(state, 4);
  const p2 = path.join(state, 'jobs', 'J2.json'); const j2 = JSON.parse(fs.readFileSync(p2, 'utf8'));
  Object.assign(j2, { status: 'quarantined' }); j2.vars = { goal: 'Private goal words', private: 'yes' }; W(p2, j2);
  fs.appendFileSync(path.join(state, 'events.jsonl'), JSON.stringify({ ts: '2030-01-06T11:00:00Z', type: 'job.quarantined', job: 'J2', reason: 'Private reason words' }) + '\n');
  const db = path.join(tmp, 'l37-out', 'tide.db'); const out = path.dirname(db);
  const lines = []; const say = (x) => lines.push(x);
  await main(['build', '--state', state, '--db', db, '--no-github', '--repo', `example=${path.join(tmp, 'repo')}`, '--now', NOW.toISOString()], { out: say });
  check('l3-37: a missing private words list is a loud warning in the output and in work.json; paths are still redacted', lines.some((l) => /^WARNING: no private words list/.test(l)) && JSON.parse(fs.readFileSync(path.join(out, 'work.json'), 'utf8')).warnings.length === 1);
  const s = await openStore(db); s.append([{ ...ev(1, 'decision.asked', 'WO-2', { decision: { v: V, id: 'D-9', wo: 'WO-2', kind: 'merge', ask: 'Private ask words', options: ['Yes', 'No'], recommended: 'Yes', why: 'Private why words', answer: null, note: null, at: '2030-01-09T00:00:00Z', answeredAt: null, via: null } }), key: 'd9' }]); s.close();
  lines.length = 0; await main(['show', 'J2', '--db', db, '--json', '--now', NOW.toISOString()], { out: say });
  check('l3-37: show <private> --json carries no goal, reason or card text in its events', !/Private (goal|reason|ask|why) words/.test(lines[0]) && JSON.parse(lines[0]).events.every((e) => JSON.stringify(e.data) === '{}'));
  lines.length = 0; await main(['queue', '--db', db, '--json', '--now', NOW.toISOString()], { out: say });
  check('l3-37: queue --json carries no private card question', !/Private (goal|ask|why) words/.test(lines[0]) && lines[0].includes(MARK.ask));
  await main(['build', '--state', state, '--db', db, '--no-github', '--repo', `example=${path.join(tmp, 'repo')}`, '--now', NOW.toISOString()], { out: () => { } });
  const files = ['work.json', 'ledger.next.json'].map((f) => fs.readFileSync(path.join(out, f), 'utf8')).join('\n');
  check('l3-37: work.json and ledger.next.json flags and cards carry no private goal, reason or question', !/Private (goal|reason|ask|why) words/.test(files) && JSON.parse(fs.readFileSync(path.join(out, 'ledger.next.json'), 'utf8')).flags.some((f) => f.id === 'D-9'));
  // the --json error line
  lines.length = 0; await main(['queue', '--db', path.join(['C:', 'Users', 'someone', 'nowhere'].join('\\'), 'x.db'), '--json'], { out: say });
  check('l3-37: the --json error line is redacted (no path)', /"ok":false/.test(lines[0]) && !/someone/.test(lines[0]), lines[0]);
  // stale pages of this writer go; other files stay
  W(path.join(out, 'ledger.next.page-5.json'), '{}'); W(path.join(out, 'notes-page-5.json'), '{}');
  await main(['build', '--state', state, '--db', db, '--no-github', '--repo', `example=${path.join(tmp, 'repo')}`, '--now', NOW.toISOString()], { out: () => { } });
  check('l3-37: a page file above the new page count is removed; a file not made by this writer stays', !fs.existsSync(path.join(out, 'ledger.next.page-5.json')) && fs.existsSync(path.join(out, 'notes-page-5.json')));
  // the example list
  const ex = readPrivateWords(path.join(repo, 'core', 'ledger', 'ledger-private-words.example.json'));
  check('l3-37: the example private words list reads, with neutral placeholders only', ex.warning === null && ex.words.length === 2 && ex.words.every((w) => /^example/i.test(w)));
}

// ---- WO-UPG-L1-4: secrets, tailnet names and private remotes are redacted by pattern, without the private words list ----
// every secret-shaped value is built at run time from parts (CREED 8; the CI secret scan reads this file), and is synthetic
export async function testSecrets() {
  const { makeRedactor, MARK } = await import('../../../core/ledger/share.mjs');
  const r = makeRedactor(); const rep = (n, c = 'A1b2') => c.repeat(n);
  const secrets = [
    ['a GitHub classic token', ['ghp', rep(9)].join('_')], ['a GitHub OAuth token', ['gho', rep(9)].join('_')], ['a GitHub app token', ['ghs', rep(9)].join('_')],
    ['a GitHub fine-grained token', ['github', 'pat', rep(6), rep(8)].join('_')], ['an Anthropic-style key', ['sk', 'ant', 'api03', rep(8)].join('-')],
    ['an OpenAI-style key', ['sk', 'proj', rep(8)].join('-')], ['a Slack token', ['xoxb', '1234567890', rep(4)].join('-')],
    ['a JWT', ['eyJhbGciOiJIUzI1NiJ9', 'eyJzdWIiOiIxMjM0NTY3ODkwIn0', 'c2lnbmF0dXJlLXNpZ25hdHVyZQ'].join('.')],
  ];
  for (const [name, value] of secrets) { const out = r(`use ${value} now`); check(`l4: ${name} is redacted`, !out.includes(value) && out.includes(MARK.secret), out); }
  const bearer = r(['Authorization:', 'Bearer', rep(5)].join(' '));
  check('l4: a Bearer header keeps the word and loses the value', bearer === `Authorization: Bearer ${MARK.secret}`, bearer);
  const hex = 'f00d'.repeat(10), b64 = 'QUJD'.repeat(12);
  check('l4: a long hex value in key=value form is redacted, the key stays', r(`session=${hex}`) === `session=${MARK.secret}`);
  check('l4: a long base64 value in key: value form is redacted', r(`blob: ${b64}`) === `blob: ${MARK.secret}`);
  check('l4: a value given to a key named like a secret is redacted (api_key=..., password: "...")', !r(`api_key=${rep(3)}xyz`).includes(rep(3)) && !r(`password: "${rep(3)}"`).includes(rep(3)));
  const pwReq = ['password', 'required'].join(': ');   // built at run time: the CI secret scan reads this file
  check('l4: ordinary words stay ("token expired", a password field that is required, "the auth flow", a merge sha in a sentence)',
    r('token expired after a while') === 'token expired after a while' && r(pwReq) === pwReq && r('the auth flow') === 'the auth flow'
    && r(`merge commit ${'a1'.repeat(20)} on main`) === `merge commit ${'a1'.repeat(20)} on main`);
  // tailnet names and addresses
  for (const [name, value] of [['a tailnet name', ['tail', '1a2b3c'].join('')], ['a tailnet name with a dash', ['tail', '1a2b3c'].join('-')], ['a MagicDNS name', ['desk', ['tail', '1a2b3c'].join(''), 'ts', 'net'].join('.')],
    ['a 100.64/10 address (low end)', ['100', '64', '0', '1'].join('.')], ['a 100.64/10 address (high end)', ['100', '127', '255', '254'].join('.')]]) {
    const out = r(`reach ${value} now`); check(`l4: ${name} is redacted`, !out.includes(value) && out.includes(MARK.host), out);
  }
  check('l4: a public 100.x address outside 100.64/10 stays', r('dns 100.128.0.1') === 'dns 100.128.0.1');
  // git remotes: a private repo loses owner/name; the public repo stays
  const priv = ['Some' + 'Owner', 'hidden-thing'];
  const remotes = [`git@github.com:${priv.join('/')}.git`, `ssh://git@github.com/${priv.join('/')}.git`, `https://github.com/${priv.join('/')}`, `https://github.com/${priv.join('/')}/pull/7`,
    `https://${['user', 'pw'].join(':')}@github.com/${priv.join('/')}.git`, `https://git.example.org/team/${priv[1]}.git`];
  for (const value of remotes) { const out = r(`remote ${value} here`); check(`l4: a private remote is redacted (${value.split(':')[0]}, ${value.length} chars)`, !out.includes(priv[1]) && !out.includes(priv[0]) && out.includes(MARK.repo), out); }
  const pub = 'https://github.com/JVonBorstel/tide/pull/31';
  check('l4: the public repo\'s remotes stay (https and git@)', r(pub) === pub && r('git@github.com:JVonBorstel/tide.git') === 'git@github.com:JVonBorstel/tide.git');
  check('l4: an ordinary web link stays', r('see https://docs.example.org/guide/start') === 'see https://docs.example.org/guide/start');
  // neutral words in public text
  const src = ['core/ledger/share.mjs', 'core/ledger/ledger-private-words.example.json', 'core/ledger/README.md'].map((f) => fs.readFileSync(path.join(repo, f), 'utf8')).join('\n');
  check('l4: public code, warning and example use neutral words ("private topics", no job-search words)', /private topics/.test(src) && !/job[- ]?(hunt|search)/i.test(src));
}

// ---- WO-UPG-L1-4 follow-up (review of #38): git ids, more remote shapes, JSON-quoted keys, tailnet-like words ----
// fixtures are synthetic and built at run time; repo names are placeholders (Example/private-repo), never a real private name
export async function testRedactionHardening() {
  const { makeRedactor, MARK } = await import('../../../core/ledger/share.mjs');
  const r = makeRedactor(); const at = '@', tsnet = ['ts', 'net'].join('.'); const sha1 = 'a1b2c3d4e5'.repeat(4), sha256 = 'f00dcafe'.repeat(8), short = 'a1b2c3d', mid = 'a1b2c3d4e5f6';
  // F1: a git id stays under every key that names one
  const keep = [`merged at ${sha1} (head: ${sha1})`, `sha=${sha1}`, `commit: ${sha1}`, `tree: ${sha1}`, `head=${sha1}`, `HEAD: ${sha1}`, `merge_sha=${sha1}`, `headSha: ${sha1}`, `rev=${sha256}`,
    `sha256:${sha256}`, `{"head":"${sha1}"}`, `{"commit": "${sha256}"}`, `commit: ${short}`, `sha=${mid}`, `tree: ${mid}`, `see commit ${sha1} on main`];
  for (const t of keep) check(`l4f: a git id stays (${t.slice(0, 18)})`, r(t) === t, r(t));
  const odd = [`session=${sha1}`, `sha=${'a1b2c3d4e5'.repeat(5)}`, `commit: ${'a1b2c3d4e5'.repeat(3)}ab`, `nonce:${sha1}`];   // not a git id: wrong key or wrong length
  for (const t of odd) check(`l4f: a hex value that is not a git id is still a secret (${t.slice(0, 14)})`, r(t).includes(MARK.secret) && !r(t).includes('a1b2c3d4e5a1b2c3d4e5'), r(t));
  // F2: remotes followed by punctuation, nested paths, ssh with a port
  for (const [name, t] of [['comma', 'see https://github.com/Example/private-repo, then'], ['gt', '<https://github.com/Example/private-repo>'], ['semicolon', 'a https://github.com/Example/private-repo; b'],
    ['star', '*https://github.com/Example/private-repo*'], ['pipe', 'https://github.com/Example/private-repo|x'], ['brace', '{"u":"https://github.com/Example/private-repo"}'], ['period', 'clone https://github.com/Example/private-repo.'],
    ['colon', 'url https://github.com/Example/private-repo:'], ['git@ nested', `git${at}gitlab.com:grp/sub/private-repo.git`], ['git@ deep', `git${at}host.example:a/b/c/private-repo`], ['ssh port', `ssh://git${at}host.example:2222/team/private-repo.git`],
    ['ssh port no user', 'ssh://host.example:2222/team/private-repo.git'], ['git://', 'git://host.example/team/private-repo.git'], ['git+https', 'git+https://host.example/team/private-repo.git#v1'], ['gitlab nested', 'https://gitlab.com/grp/sub/private-repo/-/issues/3'],
    ['azure', 'https://dev.azure.com/org/proj/_git/private-repo'], ['userinfo', `https://someuser:pw${at}github.com/Example/private-repo.git`], ['scp semicolon', `git${at}github.com:Example/private-repo.git;`]]) {
    const out = r(t); check(`l4f: private remote redacted (${name})`, !out.includes('private-repo') && !out.includes('Example') && out.includes(MARK.repo), out);
  }
  check('l4f: a private remote keeps its tail and punctuation', r('see https://github.com/Example/private-repo/pull/7, ok') === `see https://github.com/${MARK.repo}/pull/7, ok`, r('see https://github.com/Example/private-repo/pull/7, ok'));
  check('l4f: ssh port is not read as the owner', r('ssh://git@host.example:2222/team/private-repo.git') === `ssh://git@host.example:2222/${MARK.repo}.git`, r('ssh://git@host.example:2222/team/private-repo.git'));
  // F3: case, api and raw hosts, bare owner/repo
  for (const [name, t] of [['HTTPS GITHUB', 'HTTPS://GITHUB.COM/Example/private-repo'], ['GIT@', 'GIT@GITHUB.COM:Example/private-repo.git'], ['mixed', 'Git+SSH://Git@Host.Test/team/private-repo.git'],
    ['api', 'https://api.github.com/repos/Example/private-repo/pulls/4'], ['API upper', 'HTTPS://API.GITHUB.COM/REPOS/Example/private-repo'], ['raw', 'https://raw.githubusercontent.com/Example/private-repo/main/a.md'],
    ['codeload', 'https://codeload.github.com/Example/private-repo/zip/main'],
    ['gh clone', 'gh repo clone Example/private-repo'], ['--repo', 'gh pr view 3 --repo Example/private-repo'], ['--repo=', '--repo=Example/private-repo'], ['-R', 'gh issue list -R Example/private-repo'],
    ['repo:', 'repo: Example/private-repo'], ['issue ref', 'fixes Example/private-repo#12'], ['commit ref', 'Example/private-repo@a1b2c3d'], ['bare shape', 'pushed to Example/private-repo today'], ['bare sentence end', 'pushed to Example/private-repo.'],
    ['bare in parens', '(Example/private-repo)'], ['public owner, other repo', 'JVonBorstel/other-repo'], ['public owner lower', 'jvonborstel/Other_Repo'], ['public owner, tide lookalike', 'JVonBorstel/tide-private']]) {
    const out = r(t); check(`l4f: ${name} is redacted`, !out.includes('private-repo') && !out.includes('Example') && !/other-repo|other_repo|tide-private/i.test(out) && out.includes(MARK.repo), out);
  }
  for (const t of ['https://github.com/JVonBorstel/tide', 'HTTPS://GITHUB.COM/JVONBORSTEL/TIDE.git', 'GIT@GITHUB.COM:JVonBorstel/tide.git', 'git@github.com:jvonborstel/tide.git', 'ssh://git@github.com/JVonBorstel/tide.git',
    'https://api.github.com/repos/JVonBorstel/tide/pulls/38', 'https://raw.githubusercontent.com/JVonBorstel/tide/main/README.md', 'gh pr view 38 --repo JVonBorstel/tide', 'JVonBorstel/tide', 'JVonBorstel/tide#38', 'jvonborstel/Tide.',
    'https://github.com/JVonBorstel/tide/pull/38', 'see https://github.com/JVonBorstel/tide, then']) check(`l4f: the public repo stays (${t.slice(0, 40)})`, r(t) === t, r(t));
  check('l4f: a user part is dropped from a public https remote, "git@" is kept', r(`https://someuser${at}github.com/JVonBorstel/tide.git`) === 'https://github.com/JVonBorstel/tide.git' && r(`ssh://git${at}github.com/JVonBorstel/tide.git`) === `ssh://git${at}github.com/JVonBorstel/tide.git`);
  // near misses: paths, files, ordinary words and links are not repos
  for (const t of ['core/ledger/share.mjs', 'see tests/core/ledger/test-ledger.mjs', 'docs/changes/WO-UPG-L1-4.md', 'ART/CITY/BOARD', 'ART/CITY', 'and/or', 'N/A', 'TCP/IP', 'Notes/README.md', 'Docs/guide.md', 'WO-UPG-L1-4/L1-5',
    'https://docs.example.org/guide/start', 'https://example.org/Guide/start-here', 'https://api.github.com/rate_limit', 'see Example in docs/Example-notes', 'a/b/c']) check(`l4f: not a repo, stays (${t})`, r(t) === t, r(t));
  // F4: secret keys inside JSON text
  const v = ['abc123', 'def456', 'ghi789', 'jkl012'].join(''), pw = ['Sup3r', 'S3cret', '!'].join('');
  for (const [name, t, bad] of [['token', `{"token": "${v}"}`, v], ['apiKey', `{"apiKey":"${v}"}`, v], ['API_KEY', `{"API_KEY": "${v}", "x": 1}`, v], ['password', `{"password":"${pw}"}`, pw], ['client_secret', `{'client_secret': '${v}'}`, v],
    ['escaped', `{"body":"{\\"token\\":\\"${v}\\",\\"n\\":1}"}`, v], ['nested', `{"a":{"b":{"accessToken":"${v}"}}}`, v], ['hex value', `{"session":"${'f00d'.repeat(10)}"}`, 'f00d'.repeat(10)], ['spaces', `{ "secret" : "${v}" }`, v]]) {
    const out = r(t); check(`l4f: JSON-quoted ${name} is redacted`, !out.includes(bad) && out.includes(MARK.secret), out);
  }
  check('l4f: JSON keeps its shape around a redacted secret', r(`{"token": "${v}", "n": 1}`) === `{"token": "${MARK.secret}", "n": 1}`, r(`{"token": "${v}", "n": 1}`));
  check('l4f: JSON words that are not secrets stay', r('{"token":"expired","auth":"required","note":"password policy"}') === '{"token":"expired","auth":"required","note":"password policy"}');
  // F6: tailnet words
  for (const t of ['tail-fade', 'tail-dead', 'tailadded', 'tail-beef', 'tailface', 'tail-cafe is open', 'tailwind', 'tail -f log', 'tailored', 'detail1a2b3c', 'tail-latency', 'tail-base']) check(`l4f: ordinary word is not a tailnet (${t})`, r(t) === t, r(t));
  for (const t of ['tail1a2b3c', 'tail-1a2b3c', 'Tail-1A2B3C', 'tail-9f8e7d', 'tail-deadbeef0', `tail-fade.${tsnet}`, `host.tail1a2b3c.${tsnet}`]) check(`l4f: tailnet shape is redacted (${t})`, !r(t).includes('1a2b3c') && !r(t).includes('9f8e7d') && !r(t).includes('deadbeef') && !r(t).includes(tsnet) && r(t).includes(MARK.host), r(t));
  // a proof string with ids and the public link stays whole
  const proof = `merged https://github.com/JVonBorstel/tide/pull/38 at ${sha1} (tree: ${sha1}, sha=${sha1}); branch wo/upg-l1-4-secrets`;
  check('l4f: a proof string with ids and the public link is untouched', r(proof) === proof, r(proof));
  // idempotent: redacting twice changes nothing more
  const mixed = `see https://github.com/Example/private-repo, ${'ghp'}_${'A1b2'.repeat(9)} {"token":"${v}"} tail1a2b3c Example/private-repo#3`;
  check('l4f: redacting twice equals redacting once', r(r(mixed)) === r(mixed), r(r(mixed)));
  // linear time on long single tokens for the new rules
  for (const [name, s] of [['slashes', 'a/'.repeat(30000)], ['git@ path', `git@h.example:${'a/'.repeat(10000)}`], ['long url', `https://github.com/${'a'.repeat(50000)}`], ['quotes', 'token"'.repeat(10000)], ['backslashes', `token=${'\\'.repeat(20000)}`], ['Caps', 'Aa/'.repeat(10000)], ['gh', 'gh repo clone '.repeat(3000)]]) {
    const t0 = Date.now(); r(s); check(`l4f: long input is fast (${name})`, Date.now() - t0 < 1500, `${Date.now() - t0} ms`);
  }
}
