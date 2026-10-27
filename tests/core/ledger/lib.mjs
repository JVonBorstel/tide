// Owns the ledger tests' shared pieces: a check() that counts, the temp folder, the synthetic Yard state folder, a fake gh and a git runner.
// Called by tests/core/ledger/test-ledger.mjs (which removes the temp folder at the end) and the ledger-*.mjs suites beside it.
// All data is synthetic and made at run time in a temp folder (WO-2001, example-owner/example-repo, dates in 2030).
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { spawnSync } from 'node:child_process'; import { fileURLToPath } from 'node:url';

export const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
export const results = [];
export const check = (name, pass, detail = '') => results.push({ name: detail && !pass ? `${name} (${detail})` : name, pass: !!pass });
export const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ledger-test-'));
export const NOW = new Date('2030-01-10T12:00:00Z');
export const W = (p, v) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, typeof v === 'string' ? v : JSON.stringify(v)); };
export const V = '1.0';
export const ev = (seq, kind, wo, data, at, extra = {}) => ({ v: V, seq, at: at || `2030-01-0${Math.min(9, 1 + Math.floor(seq / 10))}T0${seq % 10}:00:00Z`, actor: 'engine', kind, wo, data, proof: null, ...extra });
export const catchCode = (f) => { try { f(); return null; } catch (e) { return e?.code || String(e); } };
export const catchCodeAsync = async (f) => { try { await f(); return null; } catch (e) { return e?.code || String(e); } };

// ---- a synthetic Yard state folder: 209 jobs, an archive, the event log ----
export const STATUSES = ['pending', 'running', 'done', 'closed', 'killed', 'quarantined', 'waiting-approval', 'needs-human'];
export function makeState(dir, n = 209) {
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

// ---- import-github (a fake gh; no network) ----
export function fakeGh(lists) {
  const calls = [];
  const run = (args) => { calls.push(args.join(' ')); const slug = args[args.indexOf('-R') + 1]; const st = args[args.indexOf('--state') + 1]; const f = lists[`${slug}|${st}`]; return typeof f === 'function' ? f() : f || { ok: true, data: [] }; };
  return { run, calls };
}
export const SHA1 = 'a'.repeat(40), SHA2 = 'b'.repeat(40), SHA3 = 'c'.repeat(40);

// ---- import-local (a real temp git repo) ----
export function git(cwd, ...args) {
  return spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8', env: { ...process.env, GIT_AUTHOR_NAME: 'Test', GIT_AUTHOR_EMAIL: 'test@example.invalid', GIT_COMMITTER_NAME: 'Test', GIT_COMMITTER_EMAIL: 'test@example.invalid' } });
}
