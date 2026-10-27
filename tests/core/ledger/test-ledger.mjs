// Owns the tests of the ledger (core/ledger): the event store, the three importers, the view and its queries, the ledger.json export,
// the CLI and parity. Every test is named after an acceptance line of WO-UPG-L1 (prompts/upgrade-L1-ledger.md, work breakdown).
// Called by tests/Test-CoreLedger.ps1 (the Yard's tests Step, verify-all) and by hand: node tests/core/ledger/test-ledger.mjs
// node:sqlite needs --experimental-sqlite on Node 22: this file starts itself again with the flag only when the module is missing.
// All data is synthetic and made at run time in a temp folder (WO-2001, example-owner/example-repo, dates in 2030); nothing is read from
// the live state folder.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';

let hasSqlite = true; try { await import('node:sqlite'); } catch { hasSqlite = false; }
if (!hasSqlite && !process.env.LEDGER_SQLITE_RESPAWNED) {
  const r = spawnSync(process.execPath, ['--experimental-sqlite', '--disable-warning=ExperimentalWarning', fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit', env: { ...process.env, LEDGER_SQLITE_RESPAWNED: '1' } });
  process.exit(r.status ?? 1);
}
const { openStore, StoreError, SCHEMA_VERSION } = await import('../../../core/ledger/store.mjs');
const { importYard } = await import('../../../core/ledger/import-yard.mjs');
const { importGithub } = await import('../../../core/ledger/import-github.mjs');
const { importLocal } = await import('../../../core/ledger/import-local.mjs');
const { buildView, exportLedgerJson, flagProjection } = await import('../../../core/ledger/view.mjs');
const { compareLedgers } = await import('../../../core/ledger/parity.mjs');
const { main } = await import('../../../core/ledger/commands.mjs');
const { validate } = await import('../../../core/contracts/validate.mjs');

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const results = [];
const check = (name, pass, detail = '') => results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass });
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ledger-test-'));
const NOW = new Date('2030-01-10T12:00:00Z');
const W = (p, v) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, typeof v === 'string' ? v : JSON.stringify(v)); };
const V = '1.0';
const ev = (seq, kind, wo, data, at, extra = {}) => ({ v: V, seq, at: at || `2030-01-0${Math.min(9, 1 + Math.floor(seq / 10))}T0${seq % 10}:00:00Z`, actor: 'engine', kind, wo, data, proof: null, ...extra });
const catchCode = (f) => { try { f(); return null; } catch (e) { return e?.code || String(e); } };
const catchCodeAsync = async (f) => { try { await f(); return null; } catch (e) { return e?.code || String(e); } };

// ---- a synthetic Yard state folder: 209 jobs, an archive, the event log ----
const STATUSES = ['pending', 'running', 'done', 'closed', 'killed', 'quarantined', 'waiting-approval', 'needs-human'];
function makeState(dir, n = 209) {
  const index = { v: 1, jobs: {} };
  for (let i = 1; i <= n; i++) {
    const status = STATUSES[i % STATUSES.length];
    const merge = i % 3 === 0;
    W(path.join(dir, 'jobs', `J${i}.json`), { id: `J${i}`, name: `improve: synthetic order ${i}`, status, recipe: merge ? 'improve' : 'review', created: `2030-01-0${1 + (i % 5)}T08:00:00Z`, attempt: 1, cursor: 0,
      parent: i === 8 ? 'J6' : '', depth: 0, vars: { goal: `Synthetic goal number ${i}` }, approval: null, notBefore: null, run: null,
      steps: [{ script: merge ? 'stations/merge.ps1' : 'stations/tests.ps1' }], history: [{ outcome: 'ok', at: `2030-01-06T0${i % 10}:00:00Z`, step: 0, attempt: 1 }] });
    index.jobs[`J${i}`] = { s: status, t: i, n: 0, p: '', c: 0 };
  }
  W(path.join(dir, 'jobs-index.json'), index);
  W(path.join(dir, 'jobs', 'archive', 'index.jsonl'), [{ id: 'J900', status: 'closed', name: 'an archived order', recipe: 'improve', created: '2029-12-01T00:00:00Z', ended: '2029-12-02T00:00:00Z', replacedBy: 'J4', code: true, archivedAt: '2029-12-03T00:00:00Z' }].map((x) => JSON.stringify(x)).join('\n') + '\n');
  W(path.join(dir, 'events.jsonl'), [
    { ts: '2030-01-06T10:00:00Z', type: 'job.closed', job: 'J3', reason: 're-cooked fresh as J11' },
    { ts: '2030-01-06T10:00:00Z', type: 'job.closed', job: 'J11', reason: 'done another way: integrated by hand' },
    { ts: '2030-01-06T10:00:00Z', type: 'job.closed', job: 'J19', reason: 'dropped: too big', dropped: true, by: 'cli' },
    { ts: '2030-01-06T10:00:00Z', type: 'job.quarantined', job: 'J5', reason: 'tests failed twice' },
  ].map((x) => JSON.stringify(x)).join('\n') + '\n');
  return dir;
}

// ---- store ----
async function testStore() {
  const dbf = path.join(tmp, 'store', 'tide.db');
  const s = await openStore(dbf);
  const add = s.append([{ ...ev(1, 'wo.created', 'WO-2001', { goal: 'Paint the sunrise', stream: 'ART' }), key: 'k1' }]);
  check('store: an event is appended and gets seq 1', add.added === 1 && add.lastSeq === 1);
  // an outside writer with its own connection (the store hands out no raw SQL: no exec, no db handle)
  const { DatabaseSync } = await import('node:sqlite'); const raw = new DatabaseSync(dbf); raw.exec('PRAGMA busy_timeout = 2000');
  const rawErr = (sql) => { try { raw.exec(sql); return 'accepted'; } catch (e) { return /append-only/.test(String(e.message)) ? 'append-only' : String(e.message); } };
  check('store: append-only: an UPDATE of an event is refused', rawErr("UPDATE events SET kind = 'closed'") === 'append-only');
  check('store: append-only: a DELETE of an event is refused', rawErr('DELETE FROM events') === 'append-only');
  check('store: append-only: INSERT OR REPLACE of an existing seq is refused', rawErr("INSERT OR REPLACE INTO events (seq, v, at, actor, kind, wo, data, proof) VALUES (1, '1.0', '2030-01-01T00:00:00Z', 'engine', 'closed', 'WO-2001', '{}', 'x')") === 'append-only');
  check('store: append-only: INSERT OR REPLACE on a stored source key changes nothing', rawErr("INSERT OR REPLACE INTO events (v, at, actor, kind, wo, data, proof, source_key) VALUES ('1.0', '2030-01-01T00:00:00Z', 'engine', 'closed', 'WO-2001', '{}', 'x', 'k1')") === 'accepted' && s.info().events === 1);
  check('store: the store object exposes no raw SQL (no exec, no db)', typeof s.exec === 'undefined' && typeof s.db === 'undefined');
  check('store: append-only: the refused writes changed nothing', s.events().length === 1 && s.events()[0].kind === 'wo.created');
  const info = s.info();
  check('store: WAL journal on a file store', info.journal === 'wal', info.journal);
  check(`store: schema version ${SCHEMA_VERSION} is stamped (PRAGMA user_version)`, info.version === SCHEMA_VERSION);
  check('store: tables are STRICT', info.strict === true);
  check('store: the append-only triggers are in place (update, delete, replace)', ['events_no_delete', 'events_no_replace', 'events_no_update'].every((t) => info.triggers.includes(t)));
  check('store: a rerun with the same source key adds 0 events', s.append([{ ...ev(1, 'wo.created', 'WO-2001', { goal: 'Paint the sunrise', stream: 'ART' }), key: 'k1' }]).added === 0);
  check('store: an event read back carries the contract version', s.events()[0].v === V && validate('event', s.events()[0]).ok, JSON.stringify(validate('event', s.events()[0]).errors));
  const bad = catchCode(() => s.append([{ ...ev(2, 'stage.entered', 'WO-2001', { stage: 'build' }), key: 'k2' }, { ...ev(3, 'stage.entered', 'WO-2001', { stage: 'nowhere' }), key: 'k3' }]));
  check('store: an event that breaks the contract is refused and its batch writes nothing', bad === 'bad-event' && s.info().events === 1, String(bad));
  // locked: another connection holds the write lock
  raw.exec('BEGIN EXCLUSIVE');
  const s2 = await openStore(dbf, { busyMs: 50 });
  check('store: a locked file says locked (one writer)', catchCode(() => s2.append([{ ...ev(2, 'stage.entered', 'WO-2001', { stage: 'review' }), key: 'k4' }])) === 'locked');
  raw.exec('ROLLBACK'); raw.close(); s2.close();
  // observations: written only when the value changes, so A -> B -> A keeps all three and A, A keeps one
  const o = await openStore(':memory:'); const st = (stage) => ({ ...ev(1, 'stage.entered', 'WO-2001', { stage }), family: 'f:WO-2001:stage', value: stage });
  const a1 = o.append([st('build'), st('build')]).added, a2 = o.append([st('jordan')]).added, a3 = o.append([st('build')]).added, a4 = o.append([st('build')]).added;
  check('store: an observation is written once per change: A, A -> 1; A -> B -> A -> 3; A again -> 0', a1 === 1 && a2 === 1 && a3 === 1 && a4 === 0 && o.lastValue('f:WO-2001:stage') === 'build');
  check('store: a family without a value is refused', catchCode(() => o.append([{ ...ev(1, 'stage.entered', 'WO-2001', { stage: 'build' }), family: 'x' }])) === 'bad-event'); o.close();
  // backup
  const copy = path.join(tmp, 'store', 'backup', 'tide-copy.db'); s.backup(copy);
  const c = await openStore(copy, { readOnly: true });
  check('store: the nightly copy (VACUUM INTO) holds every event', c.info().events === 1); c.close();
  check('store: a backup never overwrites a file', catchCode(() => s.backup(copy)) === 'exists');
  s.close();
  // corrupt and newer files
  const junk = path.join(tmp, 'store', 'junk.db'); W(junk, 'this is not a database file at all, just text that is long enough to have a header....');
  check('store: a corrupt file says corrupt', await catchCodeAsync(() => openStore(junk)) === 'corrupt');
  const newer = path.join(tmp, 'store', 'newer.db'); (await openStore(newer)).close(); { const n = new DatabaseSync(newer); n.exec('PRAGMA user_version = 99'); n.close(); }
  const v1 = path.join(tmp, 'store', 'v1.db'); { const n = new DatabaseSync(v1); n.exec("CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT NOT NULL, at TEXT NOT NULL, actor TEXT NOT NULL, kind TEXT NOT NULL, wo TEXT, data TEXT NOT NULL, proof TEXT, source_key TEXT UNIQUE) STRICT; PRAGMA user_version = 1"); n.close(); }
  check('store: a schema 1 file is refused read-only and brought to schema 2 when opened for writing', await catchCodeAsync(() => openStore(v1, { readOnly: true })) === 'older-schema' && (await (async () => { const m = await openStore(v1); const i = m.info(); m.close(); return i.version === 2; })()));
  check('store: a file from newer code is refused by name (newer-schema)', await catchCodeAsync(() => openStore(newer)) === 'newer-schema');
  check('store: a read of a missing file says missing', await catchCodeAsync(() => openStore(path.join(tmp, 'none.db'), { readOnly: true })) === 'missing');
}

// ---- import-yard ----
async function testYard() {
  const state = makeState(path.join(tmp, 'state'));
  const r = importYard(state, { now: NOW });
  const created = r.events.filter((e) => e.kind === 'wo.created');
  check('import-yard: every J* job becomes a work order (209 jobs + 1 archived)', r.report.jobs === 209 && r.report.archived === 1 && created.length === 210, `${r.report.jobs}/${r.report.archived}/${created.length}`);
  check('import-yard: each work order has the alias id (J12 -> WO-12, alias J12)', created.every((e) => e.wo === `WO-${e.data.alias.slice(1)}`) && created.some((e) => e.wo === 'WO-12' && e.data.alias === 'J12'));
  check('import-yard: the index count is read (209)', r.report.indexJobs === 209);
  const s = await openStore(':memory:');
  const first = s.append(r.events);
  check('import-yard: every event passes the event contract', first.added === r.events.length);
  check('import-yard: 209 jobs import idempotently (a rerun adds 0 events)', s.append(importYard(state, { now: NOW }).events).added === 0);
  const j = JSON.parse(fs.readFileSync(path.join(state, 'jobs', 'J9.json'), 'utf8')); j.status = 'waiting-approval'; j.history.push({ outcome: 'hold', at: '2030-01-07T00:00:00Z', step: 0, attempt: 1 });
  W(path.join(state, 'jobs', 'J9.json'), j);
  const again = importYard(state, { now: NOW }); const before = s.info().events; const third = s.append(again.events);
  const newOnes = s.events({ afterSeq: before });
  check('import-yard: a changed job adds events for that job only', third.added > 0 && newOnes.every((e) => e.wo === 'WO-9'), JSON.stringify(newOnes.map((e) => e.wo)));
  const v = buildView(s.events(), { now: NOW });
  const row = (id) => v.rows.find((x) => x.id === id);
  check('import-yard: a close reason naming another order replaces it (J3 -> WO-11)', row('WO-3')?.state === 'replaced' && row('WO-3')?.next === 'continues as WO-11');
  check('import-yard: an archived order with replacedBy is replaced', row('WO-900')?.state === 'replaced');
  check('import-yard: "done another way" with no proof is lost, with the reason', row('WO-11')?.state === 'lost' && /done another way/.test(row('WO-11')?.blockedOn || ''));
  check('import-yard: a drop not made by Jordan is dropped and becomes a question for him', row('WO-19')?.state === 'dropped' && v.flags.some((f) => f.wo === 'WO-19' && f.flag === 'no-decision'));
  check('import-yard: a quarantined order is stuck with its reason', row('WO-5')?.state === 'stuck' && /tests failed twice/.test(row('WO-5')?.blockedOn || ''));
  check('import-yard: waiting-approval waits on Jordan', row('WO-9')?.state === 'waiting-on-jordan' && row('WO-9')?.owner === 'jordan');
  check('import-yard: a sub-order shows under its parent (no row of its own)', !row('WO-8'));
  check('import-yard: a finished non-code order is shipped with proof', row('WO-2')?.state === 'shipped' && /order finished/.test(row('WO-2')?.proof || ''));
  check('import-yard: a finished code order with no commit on main is lost (never trusted alone)', row('WO-42') ? row('WO-42').state === 'lost' && /no commit on main/.test(row('WO-42').blockedOn) : false, JSON.stringify(row('WO-42')));
  check('import-yard: a missing jobs folder says so', /no jobs folder/.test(catchCode(() => importYard(path.join(tmp, 'nothing'))) || ''));
  s.close();
  return state;
}

// ---- import-github (a fake gh; no network) ----
function fakeGh(lists) {
  const calls = [];
  const run = (args) => { calls.push(args.join(' ')); const slug = args[args.indexOf('-R') + 1]; const st = args[args.indexOf('--state') + 1]; const f = lists[`${slug}|${st}`]; return typeof f === 'function' ? f() : f || { ok: true, data: [] }; };
  return { run, calls };
}
const SHA1 = 'a'.repeat(40), SHA2 = 'b'.repeat(40), SHA3 = 'c'.repeat(40);
const openList = [
  { number: 41, title: 'WO-2001: paint the sunrise', headRefName: 'art-sunrise', baseRefName: 'main', headRefOid: SHA1, createdAt: '2030-01-09T00:00:00Z', updatedAt: '2030-01-10T06:00:00Z', mergeable: 'MERGEABLE', statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }] },
  { number: 42, title: 'A hand PR with no work order', headRefName: 'city-g9', baseRefName: 'main', headRefOid: SHA2, createdAt: '2030-01-09T00:00:00Z', updatedAt: '2030-01-10T06:00:00Z', mergeable: 'CONFLICTING', statusCheckRollup: [] },
  { number: 43, title: 'Stacked slice', headRefName: 'city-g10', baseRefName: 'city-g9', headRefOid: SHA3, createdAt: '2030-01-09T00:00:00Z', updatedAt: '2030-01-10T06:00:00Z', mergeable: 'MERGEABLE', statusCheckRollup: [{ status: 'IN_PROGRESS', conclusion: '' }] },
];
const mergedList = [{ number: 40, title: 'Yard order', headRefName: 'kitchen/J6', mergedAt: '2030-01-08T00:00:00Z', mergeCommit: { oid: SHA2 } }];
async function testGithub() {
  const out = path.join(tmp, 'gh-out'); const state = path.join(tmp, 'gh-state'); fs.mkdirSync(state, { recursive: true });
  const slug = 'example-owner/example-repo', priv = 'example-owner/example-private';
  const extra = [{ ...openList[0], number: 44, title: 'Port #132: the private feature', headRefName: 'port/x', headRefOid: SHA3 }];
  const gh1 = fakeGh({ [`${slug}|open`]: { ok: true, data: [...openList, ...extra] }, [`${slug}|merged`]: { ok: true, data: mergedList },
    [`${priv}|open`]: { ok: true, data: [{ number: 132, title: 'old private PR', headRefName: 'feature-x', baseRefName: 'main', headRefOid: SHA1, createdAt: '2030-01-01T00:00:00Z', updatedAt: '2030-01-01T00:00:00Z', mergeable: 'MERGEABLE' }] },
    [`${priv}|merged`]: { ok: true, data: [] } });
  const r1 = importGithub({ repos: [slug, priv], state, out, run: gh1.run, now: NOW });
  check('import-github: open PRs of every Tower are read (4 + 1)', r1.report.repos[0].open === 4 && r1.report.repos[1].open === 1 && r1.report.state === 'ok', JSON.stringify(r1.report));
  check('import-github: merged PRs are read (kitchen/J6 -> WO-6 merged with its sha)', r1.events.some((e) => e.kind === 'merged' && e.wo === 'WO-6' && e.data.sha === SHA2));
  const s = await openStore(':memory:'); s.append(importYard(makeState(path.join(tmp, 'gh-yard'), 10), { now: NOW }).events); s.append(r1.events);
  const v = buildView(s.events(), { now: NOW }); const row = (id) => v.rows.find((x) => x.id === id);
  check('import-github: the WO id comes from the title prefix (WO-2001)', row('WO-2001')?.pr === 'example-repo#41' && row('WO-2001')?.stage === 'merge-ready');
  check('import-github: a PR with no work order gets its own row (WO-PR-EXAMPLE-REPO-42)', !!row('WO-PR-EXAMPLE-REPO-42') && row('WO-PR-EXAMPLE-REPO-42').stream === 'CITY');
  check('import-github: CONFLICTING is stale with "conflict with main"', row('WO-PR-EXAMPLE-REPO-42')?.state === 'stale' && row('WO-PR-EXAMPLE-REPO-42')?.blockedOn === 'conflict with main');
  check('import-github: a PR based on another PR\'s branch is stacked on it', row('WO-PR-EXAMPLE-REPO-43')?.stackParent === 'WO-PR-EXAMPLE-REPO-42');
  check('import-github: a merged Yard order is shipped with the merge proof', row('WO-6')?.state === 'shipped' && row('WO-6')?.proof?.includes(SHA2));
  check('import-github: a "Port #132" PR replaces the open private PR 132', row('WO-PR-EXAMPLE-PRIVATE-132')?.state === 'replaced');
  check('import-github: a rerun of the same read adds 0 events', s.append(importGithub({ repos: [slug, priv], state, out, run: gh1.run, now: NOW }).events).added === 0);
  // the G2 cached read: fresh -> no merged call; old -> gh is asked
  W(path.join(state, 'towers-github.json'), { at: new Date(NOW.getTime() - 120000).toISOString(), repos: { [slug]: { merged: [{ n: 40, t: 'Yard order', at: '2030-01-08T00:00:00Z', sha: SHA2, job: 'J6' }], open: [] } } });
  const gh2 = fakeGh({ [`${slug}|open`]: { ok: true, data: openList } });
  const r2 = importGithub({ repos: [slug], state, out, run: gh2.run, now: NOW });
  check('import-github: reuses the G2 cached read when fresh (no merged call)', !gh2.calls.some((c) => c.includes('merged')) && r2.report.repos[0].mergedFrom === 'cache' && r2.events.some((e) => e.kind === 'merged' && e.wo === 'WO-6'));
  const gh3 = fakeGh({ [`${slug}|open`]: { ok: true, data: openList }, [`${slug}|merged`]: { ok: true, data: mergedList } });
  importGithub({ repos: [slug], state, out, run: gh3.run, now: new Date(NOW.getTime() + 3600000) });
  check('import-github: an old cached read is not used (gh is asked)', gh3.calls.some((c) => c.includes('merged')));
  // rate limit and offline keep the last good read
  const lastBefore = JSON.parse(fs.readFileSync(path.join(out, 'github-last.json'), 'utf8')).at;
  const ghRL = fakeGh({ [`${slug}|open`]: { ok: false, why: 'rate-limited', rateLimited: true }, [`${slug}|merged`]: { ok: false, why: 'rate-limited', rateLimited: true } });
  const rRL = importGithub({ repos: [slug], out, run: ghRL.run, now: new Date(NOW.getTime() + 7200000) });
  check('import-github: a rate limit keeps the last good read (same PRs, state rate-limited)', rRL.report.state === 'rate-limited' && rRL.report.repos[0].openFrom === 'last-good' && rRL.events.filter((e) => e.kind === 'pr.opened').length === 3);
  check('import-github: a failed read does not move the last good time', JSON.parse(fs.readFileSync(path.join(out, 'github-last.json'), 'utf8')).at === lastBefore);
  const ghOff = fakeGh({ [`${slug}|open`]: { ok: false, why: 'offline (GitHub could not be reached)' }, [`${slug}|merged`]: { ok: false, why: 'offline (GitHub could not be reached)' } });
  const rOff = importGithub({ repos: [slug], out, run: ghOff.run, now: new Date(NOW.getTime() + 7200000) });
  check('import-github: offline keeps the last good read and says why', rOff.report.state === 'offline' && /offline/.test(rOff.report.repos[0].error) && rOff.events.some((e) => e.kind === 'merged'));
  // closed without merging
  const ghC = fakeGh({ [`${slug}|open`]: { ok: true, data: openList.slice(1) }, [`${slug}|merged`]: { ok: true, data: mergedList } });
  const rC = importGithub({ repos: [slug], out, run: ghC.run, now: new Date(NOW.getTime() + 9000000) });
  s.append(rC.events); const v2 = buildView(s.events(), { now: new Date(NOW.getTime() + 9000000) });
  check('import-github: a PR closed without merging is lost (nothing ends silently)', v2.rows.find((x) => x.id === 'WO-2001')?.state === 'lost');
  s.close();
}

// ---- import-local (a real temp git repo) ----
function git(cwd, ...args) {
  return spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8', env: { ...process.env, GIT_AUTHOR_NAME: 'Test', GIT_AUTHOR_EMAIL: 'test@example.invalid', GIT_COMMITTER_NAME: 'Test', GIT_COMMITTER_EMAIL: 'test@example.invalid' } });
}
async function testLocal() {
  const r = path.join(tmp, 'repo'); fs.mkdirSync(r, { recursive: true });
  git(r, 'init', '-q', '-b', 'main'); W(path.join(r, 'a.txt'), '1'); git(r, 'add', '.'); git(r, 'commit', '-q', '-m', 'J1: the first order');
  W(path.join(r, 'a.txt'), '2'); git(r, 'commit', '-q', '-am', 'WO-2001: paint the sunrise');
  git(r, 'commit', '-q', '--allow-empty', '-m', 'Revert "J4: a bad one"'); git(r, 'branch', 'done-branch');
  const wt = path.join(tmp, 'wt-sunrise'); git(r, 'worktree', 'add', '-q', '-b', 'art-sunrise', wt);
  const plans = path.join(tmp, 'notes', 'plans'); W(path.join(plans, 'sunrise.md'), '---\nwo: WO-2001, WO-2002\n---\n# Sunrise\nSlice G4 and S7b.\n');
  W(path.join(plans, 'other.md'), '# Other\nAlso names S7b.\n');
  const work = path.join(tmp, 'notes', 'work'); W(path.join(work, 'WO-2003', 'BRIEF.md'), '---\nwo: WO-2003\nstream: ART\nplan: plans/sunrise.md#g4\n---\n# Goal\n');
  W(path.join(work, 'WO-2003', 'REPORT.md'), '---\nwo: WO-2003\nstatus: done\n---\n');
  const imp = importLocal({ repos: [{ path: r, name: 'example-repo' }], plans, work, now: NOW });
  const repoEv = imp.events.find((e) => e.kind === 'x.local.repo').data;
  check('import-local: worktrees are listed with their branch', repoEv.worktrees.some((w) => w.branch === 'art-sunrise') && repoEv.worktrees.length === 2);
  check('import-local: ids named on main are found (J1, WO-2001)', !!repoEv.ids.J1 && !!repoEv.ids['WO-2001']);
  check('import-local: a revert naming an id marks it undone', repoEv.reverted.includes('J4'));
  check('import-local: branches merged into main are listed', repoEv.mergedBranches.includes('done-branch'));
  const pl = imp.events.find((e) => e.kind === 'x.local.plans').data.plans;
  check('import-local: plan files: wo: front matter and slice tokens', pl.find((p) => p.file === 'plans/sunrise.md')?.wo.join() === 'WO-2001,WO-2002' && pl.find((p) => p.file === 'plans/sunrise.md').tokens.includes('G4'));
  const br = imp.events.find((e) => e.kind === 'x.local.briefs').data.items;
  check('import-local: BRIEF and REPORT front matter are read', br[0]?.wo === 'WO-2003' && br[0].brief === 'work/WO-2003/BRIEF.md' && br[0].report === 'work/WO-2003/REPORT.md' && br[0].plan === 'plans/sunrise.md#g4');
  const s = await openStore(':memory:'); s.append(imp.events);
  check('import-local: a rerun with nothing changed adds 0 events', s.append(importLocal({ repos: [{ path: r, name: 'example-repo' }], plans, work, now: NOW }).events).added === 0);
  s.append([
    { ...ev(1, 'wo.created', 'WO-2001', { goal: 'Paint the sunrise', stream: 'ART' }), key: 'a' },
    { ...ev(1, 'wo.created', 'WO-2003', { goal: 'Sunrise mock-ups', stream: 'ART' }), key: 'b' },
    { ...ev(1, 'wo.created', 'WO-2004', { goal: 'City slice G4 polish', stream: 'CITY' }), key: 'c' },
    { ...ev(1, 'wo.created', 'WO-2005', { goal: 'Art slice S7b', stream: 'ART' }), key: 'd' },
  ]);
  const v = buildView(s.events(), { now: NOW }); const row = (id) => v.rows.find((x) => x.id === id);
  check('import-local: a plan that names the WO in wo: is the row\'s plan', row('WO-2001')?.plan === 'plans/sunrise.md');
  check('import-local: the brief\'s plan and paths reach the row', row('WO-2003')?.plan === 'plans/sunrise.md#g4' && row('WO-2003')?.brief === 'work/WO-2003/BRIEF.md' && row('WO-2003')?.report === 'work/WO-2003/REPORT.md');
  check('import-local: a slice token named by exactly one plan gives the plan', row('WO-2004')?.plan === 'plans/sunrise.md');
  check('import-local: a token named by two plans gives no plan and a no-plan flag that says why', row('WO-2005')?.plan === null && v.flags.some((f) => f.wo === 'WO-2005' && f.flag === 'no-plan' && /2 plans name S7b/.test(f.detail)));
  const missing = importLocal({ repos: [{ path: path.join(tmp, 'no-repo'), name: 'gone' }], now: NOW });
  check('import-local: a missing checkout says so (not a crash)', missing.report.repos[0].ok === false && /does not exist/.test(missing.report.repos[0].why));
  s.close();
}

// ---- view + queries ----
function stageRun() {
  const D = (id, at, ask) => ({ v: V, id, wo: 'WO-2001', kind: 'merge', ask, options: ['Yes', 'Hold', 'No'], recommended: 'Yes', why: null, answer: null, note: null, at, answeredAt: null, via: null });
  return [
    ev(1, 'wo.created', 'WO-2001', { goal: 'Paint the sunrise', stream: 'ART', plan: 'plans/sunrise.md' }, '2030-01-07T08:00:00Z'),
    ev(2, 'stage.entered', 'WO-2001', { stage: 'build' }, '2030-01-07T08:00:00Z'),
    ev(3, 'step.started', 'WO-2001', { step: 'build', attempt: 2 }, '2030-01-07T08:10:00Z'),
    ev(4, 'pr.opened', 'WO-2001', { pr: 'example#41', branch: 'art-sunrise', base: 'main', head: SHA1 }, '2030-01-10T09:00:00Z'),
    ev(5, 'ci.result', 'WO-2001', { pr: 'example#41', head: SHA1, conclusion: 'pending' }, '2030-01-10T09:05:00Z'),
    ev(6, 'ci.result', 'WO-2001', { pr: 'example#41', head: SHA1, conclusion: 'success' }, '2030-01-10T09:20:00Z'),
    ev(7, 'decision.asked', 'WO-2001', { decision: D('D-2', '2030-01-10T09:30:00Z', 'Merge example#41?') }, '2030-01-10T09:30:00Z'),
    ev(8, 'decision.asked', 'WO-2001', { decision: D('D-1', '2030-01-09T09:30:00Z', 'Look at the shots?') }, '2030-01-09T09:30:00Z'),
    ev(9, 'decision.asked', 'WO-2001', { decision: D('D-3', '2030-01-10T10:00:00Z', 'Publish?') }, '2030-01-10T10:00:00Z'),
  ];
}
function testView() {
  const evs = stageRun(); const at = (n) => buildView(evs.slice(0, n), { now: NOW }).rows[0];
  check('view: the stage machine: wo.created -> build, moving', at(2).stage === 'build' && at(2).state === 'moving' && at(2).owner === 'crew');
  check('view: the stage machine: pr.opened -> review', at(4).stage === 'review' && at(4).pr === 'example#41');
  check('view: the stage machine: CI pending -> ci, success -> merge-ready', at(5).stage === 'ci' && at(6).stage === 'merge-ready');
  check('view: the stage machine: an open card -> jordan, waiting-on-jordan, owner jordan', at(7).stage === 'jordan' && at(7).state === 'waiting-on-jordan' && at(7).owner === 'jordan' && at(7).decision === 'D-2');
  check('view: attempts come from the steps', at(3).attempts === 2);
  const v = buildView(evs, { now: NOW });
  check('view: the queue is oldest first (D-1, D-2, D-3)', v.queue.map((c) => c.decision.id).join() === 'D-1,D-2,D-3');
  const answered = [...evs, ev(10, 'decision.answered', 'WO-2001', { decision: 'D-1', answer: 'Yes', via: 'board' }, '2030-01-10T11:00:00Z', { actor: 'jordan' })];
  const v2 = buildView(answered, { now: NOW });
  check('view: an answered card leaves the queue', v2.queue.map((c) => c.decision.id).join() === 'D-2,D-3' && v2.queueTotal === 2);
  const done = [...evs, ...['D-1', 'D-2', 'D-3'].map((d, i) => ev(10 + i, 'decision.answered', 'WO-2001', { decision: d, answer: 'Yes', via: 'board' }, '2030-01-10T11:00:00Z', { actor: 'jordan' })),
    ev(13, 'merged', 'WO-2001', { pr: 'example#41', sha: SHA1, decision: 'D-2' }, '2030-01-10T11:10:00Z', { proof: SHA1 })];
  const m = buildView(done, { now: NOW }).rows[0];
  check('view: the stage machine: merged -> shipped with the merge proof, docs next', m.stage === 'merged' && m.state === 'shipped' && m.proof.includes(SHA1) && /docs station/.test(m.next));
  const docs = [...done, ev(14, 'docs.done', 'WO-2001', { dod: { 'change-note': 'yes', tests: 'yes', map: 'yes' } }, '2030-01-10T11:20:00Z'), ev(15, 'closed', 'WO-2001', { sha: SHA1 }, '2030-01-10T11:30:00Z', { proof: SHA1 })];
  const d = buildView(docs, { now: NOW }).rows[0];
  check('view: the stage machine: docs.done then closed', d.stage === 'closed' && d.dod.tests === 'yes' && d.next === null);
  // every row and the whole Work answer meet the contracts
  const full = buildView([...answered, ev(20, 'wo.created', 'WO-2002', { goal: 'Second', stream: 'CITY' }), ev(21, 'step.failed', 'WO-2002', { step: 'tests', attempt: 1, reason: 'red', retry: false })], { now: NOW });
  const bad = full.rows.map((r) => [r.id, validate('row', r)]).filter((x) => !x[1].ok);
  check('view: every row meets the row contract', !bad.length, JSON.stringify(bad.map((b) => [b[0], b[1].errors.slice(0, 2)])));
  const work = { ok: true, at: full.at, top: full.top, queue: full.queue, queueTotal: full.queueTotal, streams: full.streams, rows: full.rows, flags: full.flags };
  const wv = validate('api-work', work);
  check('view: the queue, streams, rows and flags meet the GET /api/work contract', wv.ok, wv.errors.slice(0, 3).join('; '));
  check('view: a failed step with no retry is stuck with its reason', full.rows.find((r) => r.id === 'WO-2002')?.state === 'stuck');
  // WIP: 5 build streams, a stack on ART, 3 cards in one stream
  const wip = []; let seq = 1;
  for (const s of ['ART', 'CITY', 'PORT', 'RENAME', 'DOCS']) wip.push(ev(seq++, 'wo.created', `WO-${s}-1`, { goal: `${s} work`, stream: s }, '2030-01-10T00:00:00Z'));
  wip.push(ev(seq++, 'pr.opened', 'WO-ART-1', { pr: 'example#1', branch: 'art-a', base: 'main', head: SHA1 }, '2030-01-10T10:00:00Z'));
  wip.push(ev(seq++, 'wo.created', 'WO-ART-2', { goal: 'ART stacked', stream: 'ART' }, '2030-01-10T01:00:00Z'));
  wip.push(ev(seq++, 'pr.opened', 'WO-ART-2', { pr: 'example#2', branch: 'art-b', base: 'art-a', head: SHA2 }, '2030-01-10T10:00:00Z'));
  for (let i = 1; i <= 3; i++) {
    wip.push(ev(seq++, 'wo.created', `WO-CITY-${i + 1}`, { goal: `City card ${i}`, stream: 'CITY' }, '2030-01-10T02:00:00Z'));
    wip.push(ev(seq++, 'decision.asked', `WO-CITY-${i + 1}`, { decision: { v: V, id: `D-${10 + i}`, wo: `WO-CITY-${i + 1}`, kind: 'look', ask: `Look ${i}?`, options: ['Yes', 'No'], recommended: 'Yes', answer: null, note: null, at: '2030-01-10T03:00:00Z', answeredAt: null, via: null } }, '2030-01-10T03:00:00Z'));
  }
  const w = buildView(wip, { now: NOW });
  check('view: WIP: more than 4 build streams is flagged over-wip', w.flags.some((f) => f.flag === 'over-wip' && /5 build streams/.test(f.detail)) && w.streams.filter((s) => s.overLimit).length >= 1);
  check('view: WIP: a stack in a no-stack stream (ART) is flagged', w.flags.some((f) => f.flag === 'stack-too-deep' && f.wo === 'WO-ART-2') && w.rows.find((r) => r.id === 'WO-ART-2').stackParent === 'WO-ART-1');
  check('view: WIP: 3 cards waiting in one stream puts it over its limit', w.streams.find((s) => s.stream === 'CITY')?.cards === 3 && w.streams.find((s) => s.stream === 'CITY').overLimit === true);
  // feature flags: L4's defaults, then flag.set events
  const fp = flagProjection({ flags: { 'board.sunrise': { default: false }, 'city.night': { default: true } } }, new Map([['board.sunrise', { on: true, decision: 'D-7', at: '2030-01-10T00:00:00Z' }]]));
  check('view: flag values: a flag.set event turns a flag on over its default', fp.find((f) => f.flag === 'board.sunrise')?.on === true && fp.find((f) => f.flag === 'board.sunrise').decision === 'D-7');
  check('view: flag values: the default holds with no event; an unknown flag is off', fp.find((f) => f.flag === 'city.night')?.on === true && flagProjection(null, new Map()).length === 0);
  const fv = buildView([ev(1, 'flag.set', null, { flag: 'board.sunrise', on: true, decision: 'D-7' })], { now: NOW, flagDefaults: { flags: [{ name: 'board.sunrise', default: false }] } });
  check('view: flag values come from the event log', fv.flagValues[0]?.on === true && fv.flagValues[0].from === 'event');
  check('view: the same events give the same view (a pure fold)', JSON.stringify(buildView(evs, { now: NOW })) === JSON.stringify(buildView(evs, { now: NOW })));
}

// ---- the ledger.json export against the Board's reader ----
function testExport() {
  const v = buildView([...stageRun(), ev(20, 'wo.created', 'WO-12', { goal: 'Yard order', stream: 'YARD', alias: 'J12' })], { now: NOW });
  const l = exportLedgerJson(v);
  // pass-app/server.mjs ledgerView(): the items line, copied word for word; the drift check below fails when the Board's reader changes
  const READER = "const items = (l?.items || []).slice(0, 400).map((x) => ({ id: x.id, kind: x.kind, title: x.title, from: x.from, jordans: !!x.jordans, state: x.state, owner: x.owner, why: x.why, proof: x.proof, ageDays: x.ageDays, listed: x.listed,";
  const server = fs.readFileSync(path.join(repo, 'pass-app', 'server.mjs'), 'utf8');
  check('export: the Board\'s ledger reader is unchanged since this test was written (drift check)', server.includes(READER) && server.includes("chain: (x.chain || []).slice(0, 12).map((c) => ({ id: c.id, status: c.status, proof: c.proof, note: String(c.note || '').slice(0, 200), replacedBy: c.replacedBy }))"));
  const items = (l?.items || []).slice(0, 400).map((x) => ({ id: x.id, kind: x.kind, title: x.title, from: x.from, jordans: !!x.jordans, state: x.state, owner: x.owner, why: x.why, proof: x.proof, ageDays: x.ageDays, listed: x.listed,
    chain: (x.chain || []).slice(0, 12).map((c) => ({ id: c.id, status: c.status, proof: c.proof, note: String(c.note || '').slice(0, 200), replacedBy: c.replacedBy })) }));
  const view = { updated: l?.updated || null, top: l?.top || '', counts: l?.counts || {}, programs: l?.programs || [], flags: (l?.flags || []).slice(0, 60), items };
  check('export: the Board reads every item (id, title, state, owner, chain)', items.length === 2 && items.every((x) => typeof x.id === 'string' && typeof x.title === 'string' && typeof x.state === 'string' && typeof x.owner === 'string' && Array.isArray(x.chain) && x.chain.length === 1));
  check('export: the Yard order keeps its old id (J12) for the Board', items.some((x) => x.id === 'J12'));
  check('export: top, counts, programs and flags have the old types', typeof view.top === 'string' && typeof view.counts.waitingOnJordan === 'number' && Array.isArray(view.programs) && view.flags.every((f) => typeof f.say === 'string' && typeof f.rule === 'string'));
  check('export: Jordan\'s cards are waiting-on-you flags, owner Jordan', view.flags.filter((f) => f.rule === 'waiting-on-you' && f.owner === 'Jordan').length === 3);
  // the keys kitchen/ledger.ps1 writes for an order item and the top-level document
  const OLD_ITEM = ['id', 'kind', 'title', 'from', 'jordans', 'score', 'size', 'state', 'owner', 'why', 'proof', 'listed', 'since', 'ageDays', 'chain'];
  const OLD_DOC = ['ok', 'updated', 'top', 'counts', 'programs', 'flags', 'drift', 'items'];
  check('export: every key kitchen/ledger.ps1 writes is present (document and items)', OLD_DOC.every((k) => k in l) && l.items.every((x) => OLD_ITEM.every((k) => k in x)));
  const ps = fs.readFileSync(path.join(repo, 'kitchen', 'ledger.ps1'), 'utf8');
  check('export: the old key list matches kitchen/ledger.ps1 (drift check)', /\$doc = \[ordered\]@\{ ok = \$true; updated = .*; top = \$top; counts = \$counts; lobe = \$lobe; programs = .*; flags = .*; drift = .*\s+items =/.test(ps) && ps.includes("kind = 'order'; title = "));
}

// ---- the CLI ----
async function testCli() {
  const cli = path.join(repo, 'core', 'ledger', 'cli.mjs');
  const state = makeState(path.join(tmp, 'cli-state'), 12);
  const db = path.join(tmp, 'cli-out', 'tide.db');
  const plain = spawnSync(process.execPath, [cli, 'build', '--state', state, '--db', db, '--no-github', '--repo', `example=${path.join(tmp, 'repo')}`, '--now', NOW.toISOString()], { encoding: 'utf8', env: { ...process.env, LEDGER_SQLITE_RESPAWNED: '', LEDGER_LIVE_STATE: path.join(tmp, 'live') }, timeout: 60000 });
  const needsFlag = Number(process.versions.node.split('.')[0]) < 23;
  check(`cli: works on Node ${process.versions.node} with no flag given (it adds --experimental-sqlite only when needed: ${needsFlag ? 'needed' : 'not needed'})`, plain.status === 0 && /^Work: /m.test(plain.stdout), (plain.stderr || plain.stdout).slice(0, 300));
  check('cli: build writes work.json and ledger.next.json next to the store', fs.existsSync(path.join(tmp, 'cli-out', 'work.json')) && fs.existsSync(path.join(tmp, 'cli-out', 'ledger.next.json')));
  const lines = []; const say = (s) => lines.push(s);
  check('cli: show WO-3 prints the row and its events', await main(['show', 'J4', '--db', db, '--now', NOW.toISOString()], { out: say }) === 0 && lines.some((l) => l.startsWith('WO-4 (J4)')) && lines.some((l) => /wo\.created/.test(l)));
  lines.length = 0;
  check('cli: show of an unknown id says so (exit 1)', await main(['show', 'WO-999', '--db', db], { out: say }) === 1 && /nothing named WO-999/.test(lines[0]));
  lines.length = 0;
  check('cli: queue lists the orders waiting on Jordan', await main(['queue', '--db', db, '--now', NOW.toISOString()], { out: say }) === 0 && /cards for Jordan/.test(lines[0]) && lines.some((l) => /no card/.test(l)));
  lines.length = 0;
  check('cli: streams prints the top line and the YARD stream', await main(['streams', '--db', db, '--now', NOW.toISOString()], { out: say }) === 0 && lines.some((l) => /^YARD: /.test(l)));
  lines.length = 0;
  check('cli: --json answers are JSON', await main(['queue', '--db', db, '--json'], { out: say }) === 0 && JSON.parse(lines[0]).ok === true);
  lines.length = 0;
  check('cli: a missing --db is a usage error (exit 2)', await main(['queue'], { out: say }) === 2 && /--db/.test(lines[0]));
  lines.length = 0;
  check('cli: an unknown command is a usage error (exit 2)', await main(['frobnicate'], { out: say }) === 2);
  // the live state folder is never written while the switch is old
  const live = path.join(tmp, 'live'); W(path.join(live, 'kitchen.json'), { upgrade: { ledger: 'old' } });
  process.env.LEDGER_LIVE_STATE = live; lines.length = 0;
  const refused = await main(['build', '--state', state, '--db', path.join(live, 'tide.db'), '--no-github'], { out: say });
  check('cli: a build into the live state folder is refused while the switch is "old"', refused === 2 && /refused/.test(lines[0]) && !fs.existsSync(path.join(live, 'tide.db')));
  W(path.join(live, 'kitchen.json'), { upgrade: { ledger: 'shadow' } }); lines.length = 0;
  check('cli: with the switch at shadow the same build is allowed', await main(['build', '--state', state, '--db', path.join(live, 'tide.db'), '--no-github', '--repo', `example=${path.join(tmp, 'repo')}`], { out: say }) === 0);
  delete process.env.LEDGER_LIVE_STATE;
  const bk = path.join(tmp, 'cli-out', 'copy.db'); lines.length = 0;
  check('cli: backup makes the VACUUM INTO copy', await main(['backup', '--db', db, '--to', bk], { out: say }) === 0 && fs.existsSync(bk));
  return db;
}

// ---- parity ----
async function testParity(db) {
  const s = await openStore(db, { readOnly: true }); const events = s.events(); s.close();
  const v = buildView(events, { now: NOW });
  const st = (id) => v.rows.find((r) => r.alias === id)?.state;
  const old = { items: [
    { id: 'J1', kind: 'order', state: st('J1') },
    { id: 'J11', kind: 'order', state: 'claimed' },
    { id: 'I5', kind: 'idea', state: 'not-started', chain: [] },
    { id: 'B-01', kind: 'roadmap', state: 'stuck' },
    { id: 'J8', kind: 'order', state: 'moving' },
    { id: 'I9', kind: 'idea', state: 'shipped', proof: 'J2: order finished', chain: [{ id: 'J2', proof: 'order finished' }, { id: 'J4', proof: '' }] },
    { id: 'J4', kind: 'order', state: 'stuck' },
  ], flags: [{ rule: 'decision-ready' }] };
  const p = compareLedgers(old, v, events);
  const item = (id) => p.items.find((i) => i.old === id);
  check('parity: a row with the same state is "same"', item('J1')?.verdict === 'same');
  check('parity: claimed -> lost is explained (no claimed state in the row contract)', item('J11')?.verdict === 'explained');
  check('parity: an idea never built is explained', item('I5')?.verdict === 'explained');
  check('parity: a roadmap item is explained', item('B-01')?.verdict === 'explained');
  check('parity: a sub-order is explained (shown under its parent)', item('J8')?.verdict === 'explained');
  check('parity: an idea shipped through an earlier order is explained', item('I9')?.verdict === 'explained' && /shipped through J2/.test(item('I9').reason));
  check('parity: a state difference with no known reason is unexplained and listed', item('J4')?.verdict === 'unexplained' && p.ok === false && p.unexplained === 1);
  check('parity: rows only in the new ledger are counted with their reason', p.newOnly > 0 && Object.keys(p.newOnlyWhy).length > 0);
  const oldFile = path.join(tmp, 'old-ledger.json'); W(oldFile, old); const lines = [];
  check('parity: the CLI exits 3 when any item is unexplained', await main(['parity', '--db', db, '--old', oldFile, '--now', NOW.toISOString()], { out: (x) => lines.push(x) }) === 3 && lines.some((l) => /^UNEXPLAINED J4/.test(l)));
  W(oldFile, { items: old.items.filter((i) => i.id !== 'J4') }); lines.length = 0;
  check('parity: every row the old ledger has is present or explained -> exit 0', await main(['parity', '--db', db, '--old', oldFile, '--now', NOW.toISOString()], { out: (x) => lines.push(x) }) === 0 && /0 unexplained/.test(lines[0]));
}

// ---- WO-UPG-L1-2: ideas, manual links, Jordan's drops, roadmaps, the lobe's decisions, and the old ledger's items rebuilt ----
// the lobe part of WO-UPG-L1-2: a missing, a changing and an unreadable flags.json
async function testLegacyLobe(state, base, lobeDir, importLobe) {
  const noLobe = importLobe(state, { now: NOW, home: path.join(base, 'none') });
  check('l2: lobe: no flags.json is unknown (null counts), never a made-up zero', noLobe.report.ok === false && noLobe.events[0].data.missing === true);
  const lo = await openStore(':memory:'); const lobeRead = (home) => lo.append(importLobe(state, { now: NOW, home }).events).added;
  check('l2: lobe flags present -> missing -> present again records 3 changes (A -> B -> A), and a rerun adds 0', lobeRead(lobeDir) + lobeRead(path.join(base, 'none')) + lobeRead(lobeDir) === 3 && lobeRead(lobeDir) === 0); lo.close();
  W(path.join(base, 'bad', 'flags.json'), '{ not json');
  const bad = importLobe(state, { now: NOW, home: path.join(base, 'bad') }); const s2 = await openStore(':memory:'); s2.append(bad.events);
  check('l2: lobe: an unreadable flags.json is a flag for Claude', exportLedgerJson(buildView(s2.events(), { now: NOW })).flags.some((f) => f.rule === 'lobe-flags-unreadable')); s2.close();
}

// WO-UPG-L1-2: parity item for item, no cap on the export, nothing local through share.mjs
async function testLegacyShare(v, s) {
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

async function testLegacy() {
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
async function testReview31() {
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
async function testShare() {
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
async function testShare37() {
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
async function testSecrets() {
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
async function testRedactionHardening() {
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

try {
  await testSecrets();
  await testRedactionHardening();
  await testShare37();
  await testShare();
  await testLegacy();
  await testReview31();
  await testStore(); await testYard(); await testGithub(); await testLocal(); testView(); testExport();
  const db = await testCli(); await testParity(db);
} catch (e) { check(`the suite ran to the end (${String(e?.stack || e).split('\n').slice(0, 3).join(' | ')})`, false); }
finally { try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { } }
for (const r of results) if (!r.pass) console.log(`FAIL: ${r.name}`);
const failed = results.filter((r) => !r.pass).length;
console.log(`Ledger tests: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
